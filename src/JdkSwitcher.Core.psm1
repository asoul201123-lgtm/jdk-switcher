Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JdkDataDirectory {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SafeJdkSwitcher'
}

function Test-JdkAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-JdkRegistryStore {
    # Injection is used by the tests; production always uses these raw registry reads.
    [pscustomobject]@{
        Read = {
            $values = @()
            foreach ($scope in @('Machine', 'User')) {
                $root = if ($scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
                $keyPath = if ($scope -eq 'User') { 'Environment' } else { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
                $key = $root.OpenSubKey($keyPath, $false)
                try {
                    foreach ($name in @('JAVA_HOME', 'Path')) {
                        $exists = $null -ne $key -and @($key.GetValueNames()) -contains $name
                        $value = $null
                        $kind = 'String'
                        if ($exists) {
                            $kind = $key.GetValueKind($name).ToString()
                            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                            if ($kind -notin @('String', 'ExpandString')) { throw "Unsupported registry type for $scope/$name : $kind" }
                        }
                        $values += [pscustomobject]@{ Scope = $scope; Name = $name; Exists = [bool]$exists; Kind = $kind; Value = $value }
                    }
                } finally { if ($null -ne $key) { $key.Dispose() } }
            }
            [pscustomobject]@{ Values = @($values) }
        }
        Write = {
            param($entry)
            $root = if ($entry.Scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
            $keyPath = if ($entry.Scope -eq 'User') { 'Environment' } else { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
            $key = $root.CreateSubKey($keyPath)
            try {
                if ($entry.Exists) {
                    $key.SetValue($entry.Name, [string]$entry.Value, [Microsoft.Win32.RegistryValueKind]$entry.Kind)
                } else { $key.DeleteValue($entry.Name, $false) }
            } finally { $key.Dispose() }
        }
    }
}

function Get-JdkSnapshot {
    param($Store = (New-JdkRegistryStore))
    & $Store.Read
}

function Copy-JdkObject {
    param($Value)
    $Value | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
}

function Get-JdkEntry {
    param($Snapshot, [string]$Scope, [string]$Name)
    $entries = @($Snapshot.Values | Where-Object { $_.Scope -eq $Scope -and $_.Name -eq $Name })
    if ($entries.Count -ne 1) { throw "Invalid environment snapshot: $Scope/$Name" }
    $entries[0]
}

function Test-JdkEntryEqual {
    param($Left, $Right)
    ($Left.Scope -ceq $Right.Scope) -and ($Left.Name -ceq $Right.Name) -and
        ($Left.Exists -eq $Right.Exists) -and ($Left.Kind -ceq $Right.Kind) -and
        ([string]$Left.Value -ceq [string]$Right.Value)
}

function Test-JdkSnapshotEqual {
    param($Left, $Right)
    if (@($Left.Values).Count -ne 4 -or @($Right.Values).Count -ne 4) { return $false }
    foreach ($entry in $Left.Values) {
        if (-not (Test-JdkEntryEqual $entry (Get-JdkEntry $Right $entry.Scope $entry.Name))) { return $false }
    }
    return $true
}

function Get-JdkInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.Contains(';') -or $Path.Contains('"') -or $Path -match '[\r\n%]') {
        throw 'JDK 路径包含环境变量不支持的字符（分号、引号、百分号或换行）。'
    }
    $home = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($home -notmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $home -PathType Container)) {
        throw '请选择本地磁盘上存在的 JDK 根目录。'
    }
    $release = Join-Path $home 'release'
    if (-not (Test-Path -LiteralPath $release -PathType Leaf)) { throw '缺少 release 元数据，无法安全识别该 JDK。' }
    if ((Get-Item -LiteralPath $release).Length -gt 1MB) { throw 'release 文件过大，已拒绝读取。' }
    $metadata = @{}
    foreach ($line in [IO.File]::ReadAllLines($release)) {
        if ($line -match '^([A-Z_]+)="([^"\r\n]*)"$') { $metadata[$matches[1]] = $matches[2] }
    }
    if (-not $metadata.ContainsKey('JAVA_VERSION') -or $metadata['JAVA_VERSION'] -notmatch '^\d+[.\w+\-]*$') {
        throw 'release 中缺少有效的 JAVA_VERSION。'
    }
    $firstMachine = $null
    foreach ($exe in @('java.exe', 'javac.exe')) {
        $file = Join-Path $home ('bin\' + $exe)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "缺少 $exe；该目录不是完整 JDK。" }
        # Read the PE header only. Discovery never executes an unknown binary.
        $stream = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        $reader = New-Object IO.BinaryReader($stream)
        try {
            if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "$exe 不是有效的 Windows 可执行文件。" }
            $stream.Position = 0x3c
            $offset = $reader.ReadInt32()
            if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw "$exe 的 PE 头无效。" }
            $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x00004550) { throw "$exe 的 PE 签名无效。" }
            $machine = $reader.ReadUInt16()
            if ($machine -notin @(0x14c, 0x8664, 0xaa64)) { throw "$exe 的处理器架构不受支持。" }
            if ($null -ne $firstMachine -and $machine -ne $firstMachine) { throw 'java.exe 与 javac.exe 的处理器架构不一致。' }
            $firstMachine = $machine
        } finally { $reader.Dispose() }
    }
    $version = $metadata['JAVA_VERSION']
    $major = if ($version -match '^1\.(\d+)') { [int]$matches[1] } else { [int]($version.Split('.')[0].Split('-')[0].Split('+')[0]) }
    $vendor = if ($metadata.ContainsKey('IMPLEMENTOR')) { $metadata['IMPLEMENTOR'] } else { 'Unknown vendor' }
    $arch = switch ($machine) { 0x14c { 'x86' }; 0x8664 { 'x64' }; 0xaa64 { 'ARM64' } }
    [pscustomobject]@{ Home = $home; Version = $version; Major = $major; Vendor = $vendor; Architecture = $arch }
}

function Get-JdkVariableMap {
    param($Snapshot, [switch]$MachineOnly)
    $map = @{}
    $targets = if ($MachineOnly) { @('Process', 'Machine') } else { @('Process', 'Machine', 'User') }
    foreach ($target in $targets) {
        foreach ($pair in [Environment]::GetEnvironmentVariables($target).GetEnumerator()) { $map[[string]$pair.Key] = [string]$pair.Value }
    }
    $machine = Get-JdkEntry $Snapshot 'Machine' 'JAVA_HOME'
    $user = Get-JdkEntry $Snapshot 'User' 'JAVA_HOME'
    $map.Remove('JAVA_HOME')
    if ($machine.Exists) { $map['JAVA_HOME'] = [string]$machine.Value }
    if ($user.Exists -and -not $MachineOnly) { $map['JAVA_HOME'] = [string]$user.Value }
    return $map
}

function Expand-JdkVariables {
    param([string]$Value, [hashtable]$Variables)
    $expanded = $Value
    for ($i = 0; $i -lt 10; $i++) {
        $previous = $expanded
        $expanded = [regex]::Replace($expanded, '%([^%]+)%', {
            param($match)
            if ($Variables.ContainsKey($match.Groups[1].Value)) { return [string]$Variables[$match.Groups[1].Value] }
            $match.Value
        }.GetNewClosure())
        if ($expanded -ceq $previous) { break }
    }
    $expanded
}

function Get-JdkPathResolution {
    param($Snapshot, [string]$Executable = 'java.exe', [hashtable]$Variables = (Get-JdkVariableMap $Snapshot))
    foreach ($scope in @('Machine', 'User')) {
        $entry = Get-JdkEntry $Snapshot $scope 'Path'
        if (-not $entry.Exists -or [string]::IsNullOrEmpty([string]$entry.Value)) { continue }
        # System variables can be expanded before user variables are overlaid at
        # sign-in. Never promise that a user JAVA_HOME overrides a system Path.
        $scopeVariables = if ($scope -eq 'Machine') { Get-JdkVariableMap $Snapshot -MachineOnly } else { $Variables }
        foreach ($part in ([string]$entry.Value).Split(';')) {
            $expanded = if ($entry.Kind -eq 'ExpandString') { Expand-JdkVariables $part $scopeVariables } else { $part }
            $expanded = $expanded.Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($expanded)) { continue }
            if ($expanded -notmatch '^[A-Za-z]:\\' -or $expanded.Contains('%')) {
                return [pscustomobject]@{ File = $null; Scope = $scope; Uncertain = $true; Reason = '生效前序 Path 存在相对路径、网络路径或未解析变量，无法可靠验证。' }
            }
            $file = Join-Path $expanded $Executable
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                return [pscustomobject]@{ File = [IO.Path]::GetFullPath($file); Scope = $scope; Uncertain = $false; Reason = '' }
            }
        }
    }
    [pscustomobject]@{ File = $null; Scope = ''; Uncertain = $false; Reason = '' }
}

function Find-JdkInstallations {
    [CmdletBinding()]
    param($Snapshot = (Get-JdkSnapshot), [string[]]$AdditionalRoots = @())
    $candidates = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $roots = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $variables = Get-JdkVariableMap $Snapshot
    foreach ($entry in $Snapshot.Values) {
        if (-not $entry.Exists) { continue }
        if ($entry.Name -eq 'JAVA_HOME') { [void]$candidates.Add((Expand-JdkVariables ([string]$entry.Value) $variables)) }
        if ($entry.Name -eq 'Path') {
            foreach ($part in ([string]$entry.Value).Split(';')) {
                $expanded = (Expand-JdkVariables $part $variables).Trim().Trim('"').TrimEnd('\')
                if ($expanded -match '^[A-Za-z]:\\.*\\bin$') { [void]$candidates.Add((Split-Path $expanded -Parent)) }
            }
        }
    }
    $processHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Process')
    if ($processHome) { [void]$candidates.Add($processHome) }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE)) {
        if (-not $base) { continue }
        foreach ($suffix in @('Java', 'Eclipse Adoptium', 'Microsoft', 'Amazon Corretto', 'Zulu', 'BellSoft', 'Semeru', 'Programs\Eclipse Adoptium', 'Programs\Java', '.jdks', '.jabba\jdk', 'scoop\apps', '.sdkman\candidates\java')) {
            [void]$roots.Add((Join-Path $base $suffix))
        }
    }
    foreach ($root in $AdditionalRoots) { [void]$roots.Add($root); [void]$candidates.Add($root) }
    foreach ($keyPath in @('HKLM:\SOFTWARE\JavaSoft', 'HKLM:\SOFTWARE\WOW6432Node\JavaSoft', 'HKCU:\SOFTWARE\JavaSoft')) {
        if (-not (Test-Path -LiteralPath $keyPath)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $keyPath -Recurse -ErrorAction SilentlyContinue)) {
            $home = $key.GetValue('JavaHome')
            if ($home -is [string] -and $home) { [void]$candidates.Add($home) }
        }
    }
    # Bounded breadth scan: no drive-wide recursion, no descent into junctions.
    foreach ($root in $roots) {
        if ($root -notmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        [void]$candidates.Add($root)
        $level = @($root)
        for ($depth = 0; $depth -lt 2; $depth++) {
            $next = @()
            foreach ($folder in $level) {
                foreach ($child in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue | Select-Object -First 250)) {
                    [void]$candidates.Add($child.FullName)
                    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $child.FullName 'release') -PathType Leaf)) { $next += $child.FullName }
                }
            }
            $level = $next
        }
    }
    $found = @()
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try { $found += Get-JdkInstallation -Path $candidate } catch { <# Incomplete JREs and unrelated folders are intentionally ignored. #> }
    }
    $found | Sort-Object @{ Expression = 'Major'; Descending = $true }, Home -Unique
}

function New-JdkSwitchPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Home, [ValidateSet('User', 'Machine')][string]$Scope = 'User', $Snapshot = (Get-JdkSnapshot))
    $jdk = Get-JdkInstallation $Home
    $after = Copy-JdkObject $Snapshot
    $homeEntry = Get-JdkEntry $after $Scope 'JAVA_HOME'
    $homeEntry.Exists = $true; $homeEntry.Kind = 'String'; $homeEntry.Value = $jdk.Home
    $pathEntry = Get-JdkEntry $after $Scope 'Path'
    $bin = Join-Path $jdk.Home 'bin'
    # Preserve every existing Path entry and its order. Only an exact duplicate
    # of the target bin is moved to the front; no Java shim or old JDK is deleted.
    $parts = @()
    if ($pathEntry.Exists -and -not [string]::IsNullOrEmpty([string]$pathEntry.Value)) {
        $parts = @(([string]$pathEntry.Value).Split(';') | Where-Object { $_.Trim().Trim('"').TrimEnd('\') -ine $bin })
    }
    $pathEntry.Value = (@($bin) + $parts) -join ';'
    $pathEntry.Exists = $true
    # Preserve REG_SZ/REG_EXPAND_SZ exactly for existing values.
    if (-not (Get-JdkEntry $Snapshot $Scope 'Path').Exists) { $pathEntry.Kind = 'ExpandString' }
    if ($Scope -eq 'Machine') {
        $userHome = Get-JdkEntry $after 'User' 'JAVA_HOME'
        if ($userHome.Exists) { $userHome.Value = $jdk.Home; $userHome.Kind = 'String' }
    }
    foreach ($entry in $after.Values) {
        if ($entry.Exists -and ([string]$entry.Value).Length -gt 30000) { throw '环境变量过长，已停止以避免接近 Windows 长度限制。' }
    }
    $variables = Get-JdkVariableMap $after
    foreach ($exe in @('java.exe', 'javac.exe')) {
        $resolution = Get-JdkPathResolution $after $exe $variables
        if ($resolution.Uncertain) { throw $resolution.Reason }
        if ($resolution.File -ine (Join-Path $bin $exe)) {
            throw '系统 Path 中的 Java 优先于用户 Path。请使用“系统级”模式预览；需要管理员权限。'
        }
    }
    $changes = @()
    foreach ($entry in $after.Values) {
        $before = Get-JdkEntry $Snapshot $entry.Scope $entry.Name
        if (-not (Test-JdkEntryEqual $before $entry)) { $changes += [pscustomobject]@{ Before = $before; After = $entry } }
    }
    [pscustomobject]@{ Type = 'Switch'; Home = $jdk.Home; Version = $jdk.Version; Scope = $Scope; Before = (Copy-JdkObject $Snapshot); After = $after; Changes = @($changes) }
}

function Initialize-JdkBackupDirectory {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { [void][IO.Directory]::CreateDirectory($Directory) }
    $item = Get-Item -LiteralPath $Directory
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '备份目录不能是符号链接或目录联接。' }
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')), (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$security.AddAccessRule($rule)
    }
    # Set-Acl may request SACL privileges on existing directories. Apply only the
    # modified DACL via the framework, without requiring SeSecurityPrivilege.
    if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::SetAccessControl($item, $security) }
    else { $item.SetAccessControl($security) }
}

function Write-JdkBackup {
    param($Plan, [string]$Directory)
    Initialize-JdkBackupDirectory $Directory
    $document = [pscustomobject]@{
        Schema = 1
        Id = [guid]::NewGuid().ToString('N')
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        MachineId = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
        Plan = $Plan
    }
    $file = Join-Path $Directory ($document.CreatedUtc.Replace(':', '-').Replace('.', '-') + '-' + $document.Id + '.json')
    $json = $document | ConvertTo-Json -Depth 14
    $stream = [IO.File]::Open($file, 'CreateNew', 'Write', 'None')
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    # A durable, readable backup is a hard prerequisite for touching the registry.
    $check = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if (-not (Test-JdkSnapshotEqual $check.Plan.Before $Plan.Before) -or -not (Test-JdkSnapshotEqual $check.Plan.After $Plan.After)) {
        throw '备份回读校验失败，环境未修改。'
    }
    $file
}

function Get-JdkBackups {
    param([string]$Directory = (Join-Path (Get-JdkDataDirectory) 'backups'))
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File | Sort-Object Name -Descending
}

function New-JdkRestorePlan {
    param([Parameter(Mandatory)][string]$File, $Snapshot = (Get-JdkSnapshot))
    if ((Get-Item -LiteralPath $File).Length -gt 2MB) { throw '备份文件过大。' }
    $backup = [IO.File]::ReadAllText($File) | ConvertFrom-Json
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $machine = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    if ($backup.Schema -ne 1 -or $backup.OwnerSid -cne $sid -or $backup.MachineId -cne $machine) {
        throw '只允许恢复本机、当前账户创建的备份。'
    }
    foreach ($state in @($backup.Plan.Before, $backup.Plan.After)) {
        if (@($state.Values).Count -ne 4) { throw '备份结构无效。' }
        foreach ($scope in @('Machine', 'User')) {
            foreach ($name in @('JAVA_HOME', 'Path')) {
                $entry = Get-JdkEntry $state $scope $name
                if ($entry.Exists -isnot [bool] -or $entry.Kind -notin @('String', 'ExpandString') -or
                    ($entry.Exists -and ($entry.Value -isnot [string] -or $entry.Value.Length -gt 32766))) { throw '备份内容无效。' }
            }
        }
    }
    $changes = @()
    $after = Copy-JdkObject $Snapshot
    # Derive the write set from validated snapshots, never trust a serialized write set.
    foreach ($old in $backup.Plan.Before.Values) {
        $written = Get-JdkEntry $backup.Plan.After $old.Scope $old.Name
        if (Test-JdkEntryEqual $old $written) { continue }
        $current = Get-JdkEntry $Snapshot $old.Scope $old.Name
        if (Test-JdkEntryEqual $current $old) { continue }
        if (-not (Test-JdkEntryEqual $current $written)) { throw '备份后这些配置已被其他程序修改；为防止覆盖，拒绝恢复。' }
        $target = Get-JdkEntry $after $old.Scope $old.Name
        $target.Exists = $old.Exists; $target.Kind = $old.Kind; $target.Value = $old.Value
        $changes += [pscustomobject]@{ Before = (Copy-JdkObject $current); After = (Copy-JdkObject $target) }
    }
    [pscustomobject]@{ Type = 'Restore'; Home = ''; Version = ''; Scope = 'Restore'; Before = (Copy-JdkObject $Snapshot); After = $after; Changes = @($changes) }
}

function Send-JdkEnvironmentChanged {
    if (-not ('SafeJdkSwitcher.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SafeJdkSwitcher {
    public static class Native {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wparam,
            string lparam, uint flags, uint timeout, out UIntPtr result);
    }
}
'@
    }
    $result = [UIntPtr]::Zero
    $sent = [SafeJdkSwitcher.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 2000, [ref]$result)
    if ($sent -eq [IntPtr]::Zero) { throw '环境已保存，但部分程序未响应通知；请注销后重新登录。' }
}

function Invoke-JdkTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        $Store = (New-JdkRegistryStore),
        [string]$BackupDirectory = (Join-Path (Get-JdkDataDirectory) 'backups'),
        [scriptblock]$BackupWriter = { param($p, $d) Write-JdkBackup $p $d },
        [scriptblock]$Notifier = { Send-JdkEnvironmentChanged },
        [scriptblock]$AdministratorCheck = { Test-JdkAdministrator }
    )
    $mutex = New-Object Threading.Mutex($false, 'Global\SafeJdkSwitcher.Environment.v1')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw '另一个切换操作正在进行，请稍后重试。' }
        $current = Get-JdkSnapshot $Store
        if (-not (Test-JdkSnapshotEqual $current $Plan.Before)) { throw '预览后环境变量已改变，请重新预览。' }
        # Re-derive changes instead of trusting caller-supplied mutation records.
        $changes = @()
        if (@($Plan.After.Values).Count -ne 4) { throw '变更计划结构无效。' }
        foreach ($entry in $Plan.After.Values) {
            if ($entry.Scope -notin @('Machine', 'User') -or $entry.Name -notin @('JAVA_HOME', 'Path') -or $entry.Kind -notin @('String', 'ExpandString')) { throw '变更计划包含不允许的键。' }
            $before = Get-JdkEntry $current $entry.Scope $entry.Name
            if (-not (Test-JdkEntryEqual $before $entry)) { $changes += [pscustomobject]@{ Before = $before; After = $entry } }
        }
        if ($changes.Count -eq 0) { return [pscustomobject]@{ Changed = $false; Backup = ''; Warning = '' } }
        if (@($changes | Where-Object { $_.After.Scope -eq 'Machine' }).Count -gt 0 -and -not (& $AdministratorCheck)) { throw '系统级变更需要管理员权限。请以管理员身份重新打开工具并预览。' }
        if ($Plan.Type -eq 'Switch') {
            $null = Get-JdkInstallation $Plan.Home
            $verified = New-JdkSwitchPlan -Home $Plan.Home -Scope $Plan.Scope -Snapshot $current
            if (-not (Test-JdkSnapshotEqual $verified.After $Plan.After)) { throw 'JDK 或变更计划发生变化，请重新预览。' }
        }
        $backup = & $BackupWriter $Plan $BackupDirectory
        if ([string]::IsNullOrWhiteSpace([string]$backup)) { throw '未成功生成备份，已停止切换。' }
        $applied = @()
        $expected = Copy-JdkObject $current
        try {
            foreach ($change in $changes) {
                if (-not (Test-JdkSnapshotEqual (Get-JdkSnapshot $Store) $expected)) { throw '写入期间检测到环境配置被外部修改。' }
                # Track before writing, including a write that succeeds then reports an error.
                $applied += $change
                & $Store.Write $change.After
                $target = Get-JdkEntry $expected $change.After.Scope $change.After.Name
                $target.Exists = $change.After.Exists; $target.Kind = $change.After.Kind; $target.Value = $change.After.Value
                if (-not (Test-JdkSnapshotEqual (Get-JdkSnapshot $Store) $expected)) { throw '环境写入回读校验失败。' }
            }
        } catch {
            $failure = $_.Exception.Message
            $rollbackErrors = @()
            for ($i = $applied.Count - 1; $i -ge 0; $i--) {
                $change = $applied[$i]
                try {
                    $actual = Get-JdkEntry (Get-JdkSnapshot $Store) $change.After.Scope $change.After.Name
                    if (Test-JdkEntryEqual $actual $change.Before) { continue }
                    if (-not (Test-JdkEntryEqual $actual $change.After)) { throw '该值已被外部修改，未覆盖。' }
                    & $Store.Write $change.Before
                    $restored = Get-JdkEntry (Get-JdkSnapshot $Store) $change.Before.Scope $change.Before.Name
                    if (-not (Test-JdkEntryEqual $restored $change.Before)) { throw '回滚回读校验失败。' }
                } catch { $rollbackErrors += "$($change.Before.Scope)/$($change.Before.Name): $($_.Exception.Message)" }
            }
            try { & $Notifier } catch { }
            if ($rollbackErrors.Count -gt 0) { throw "操作失败：$failure 部分配置无法自动回滚：$($rollbackErrors -join '；') 备份：$backup" }
            throw "操作失败，已回滚本次写入：$failure 备份：$backup"
        }
        $warning = ''
        try { & $Notifier } catch { $warning = $_.Exception.Message }
        [pscustomobject]@{ Changed = $true; Backup = [string]$backup; Warning = $warning }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function Get-JdkDataDirectory, Test-JdkAdministrator, New-JdkRegistryStore, Get-JdkSnapshot, Get-JdkInstallation, Find-JdkInstallations, Get-JdkVariableMap, Get-JdkPathResolution, New-JdkSwitchPlan, Invoke-JdkTransaction, Get-JdkBackups, New-JdkRestorePlan, Test-JdkSnapshotEqual
