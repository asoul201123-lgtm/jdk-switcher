#requires -Version 5.1
# Dependency-free tests. Registry writes are replaced with an in-memory store.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\JdkSwitcher.Core.psm1') -Force
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Assertion failed')
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '*')
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notlike $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
    }
    if (-not $caught) { throw 'Expected an error but operation succeeded.' }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name : $($_.Exception.Message)" }
}
function Copy-State { param($State) $State | ConvertTo-Json -Depth 12 | ConvertFrom-Json }
function Find-Entry { param($State, $Scope, $Name) $State.Values | Where-Object { $_.Scope -eq $Scope -and $_.Name -eq $Name } }
function New-State {
    [pscustomobject]@{ Values = @(
        [pscustomobject]@{ Scope='Machine'; Name='JAVA_HOME'; Exists=$false; Kind='String'; Value=$null },
        [pscustomobject]@{ Scope='Machine'; Name='Path'; Exists=$true; Kind='ExpandString'; Value='C:\Windows\System32;C:\Tools\Shared;;' },
        [pscustomobject]@{ Scope='User'; Name='JAVA_HOME'; Exists=$false; Kind='String'; Value=$null },
        [pscustomobject]@{ Scope='User'; Name='Path'; Exists=$true; Kind='String'; Value='C:\Tools\User;C:\Tools\Keep' }
    ) }
}
function New-MemoryStore {
    param($State = (New-State))
    $holder = [pscustomobject]@{ State=(Copy-State $State); Writes=0; FailAt=0; FailAfter=$false; ExternalAt=0; ConflictAt=0 }
    $read = { $holder.State | ConvertTo-Json -Depth 12 | ConvertFrom-Json }.GetNewClosure()
    $write = {
        param($Entry)
        $holder.Writes++
        if ($holder.Writes -eq $holder.FailAt -and -not $holder.FailAfter) { throw 'Simulated write failure' }
        $target = $holder.State.Values | Where-Object { $_.Scope -eq $Entry.Scope -and $_.Name -eq $Entry.Name }
        $target.Exists=$Entry.Exists; $target.Kind=$Entry.Kind; $target.Value=$Entry.Value
        if ($holder.Writes -eq $holder.ExternalAt) { ($holder.State.Values | Where-Object { $_.Scope -eq 'User' -and $_.Name -eq 'Path' }).Value = 'C:\External\Concurrent' }
        if ($holder.Writes -eq $holder.ConflictAt) { $target.Value = 'C:\External\ChangedAgain' }
        if ($holder.Writes -eq $holder.FailAt -and $holder.FailAfter) { throw 'Simulated failure after write' }
    }.GetNewClosure()
    [pscustomobject]@{ Read=$read; Write=$write; Holder=$holder }
}
function New-FixtureJdk {
    param([string]$Directory, [string]$Version)
    [void][IO.Directory]::CreateDirectory((Join-Path $Directory 'bin'))
    [IO.File]::WriteAllText((Join-Path $Directory 'release'), "JAVA_VERSION=`"$Version`"`nIMPLEMENTOR=`"Test fixture`"`n")
    foreach ($name in @('java.exe', 'javac.exe')) {
        $bytes = New-Object byte[] 256
        $bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[60] = 0x80
        $bytes[128] = 0x50; $bytes[129] = 0x45; $bytes[132] = 0x64; $bytes[133] = 0x86
        [IO.File]::WriteAllBytes((Join-Path $Directory ('bin\' + $name)), $bytes)
    }
    $Directory
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $workspace ('.local\tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $jdkA = New-FixtureJdk (Join-Path $testRoot 'jdk-a') '17.0.1'
    $jdkB = New-FixtureJdk (Join-Path $testRoot 'jdk-b') '21.0.1'
    $backupDirectory = Join-Path $testRoot 'backups'
    $admin = { $true }; $notify = { }

    Test-Case 'Reads release and PE metadata without executing Java' {
        $jdk = Get-JdkInstallation $jdkA
        Assert-True ($jdk.Major -eq 17 -and $jdk.Architecture -eq 'x64')
    }
    Test-Case 'Rejects incomplete JRE and suspicious metadata' {
        $bad = Join-Path $testRoot 'bad'
        [void][IO.Directory]::CreateDirectory($bad)
        Assert-Throws { Get-JdkInstallation $bad }
        Assert-Throws { Get-JdkInstallation ($jdkA + ';injected') }
        $invalid = New-FixtureJdk (Join-Path $testRoot 'invalid-pe') '17.0.1'
        [IO.File]::WriteAllText((Join-Path $invalid 'bin\javac.exe'), 'not a PE')
        Assert-Throws { Get-JdkInstallation $invalid }
    }
    Test-Case 'Preserves all existing Path entries and registry kind' {
        $state = New-State
        $plan = New-JdkSwitchPlan $jdkA -Scope User -Snapshot $state
        $path = Find-Entry $plan.After 'User' 'Path'
        Assert-True ($path.Value -ceq ((Join-Path $jdkA 'bin') + ';C:\Tools\User;C:\Tools\Keep'))
        Assert-True ($path.Kind -eq 'String')
        Assert-True (Test-JdkSnapshotEqual $state (New-State)) 'Planning mutated the original snapshot'
    }
    Test-Case 'Blocks user switch when system Java takes precedence' {
        $state = New-State
        (Find-Entry $state 'Machine' 'JAVA_HOME').Exists = $true
        (Find-Entry $state 'Machine' 'JAVA_HOME').Value = $jdkA
        (Find-Entry $state 'Machine' 'Path').Value = '%JAVA_HOME%\bin;C:\Windows\System32'
        Assert-Throws { New-JdkSwitchPlan $jdkB -Scope User -Snapshot $state } '*系统 Path*'
    }
    Test-Case 'System switch explicitly aligns an existing user JAVA_HOME' {
        $state = New-State
        (Find-Entry $state 'User' 'JAVA_HOME').Exists = $true
        (Find-Entry $state 'User' 'JAVA_HOME').Value = $jdkA
        $plan = New-JdkSwitchPlan $jdkB -Scope Machine -Snapshot $state
        Assert-True ((Find-Entry $plan.After 'User' 'JAVA_HOME').Value -eq $jdkB)
        Assert-True ($plan.Changes.Count -eq 3)
    }
    Test-Case 'Creates durable backup then commits and reads back' {
        $store = New-MemoryStore
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        $result = Invoke-JdkTransaction $plan -Store $store -BackupDirectory $backupDirectory -Notifier $notify -AdministratorCheck $admin
        Assert-True $result.Changed
        Assert-True (Test-Path -LiteralPath $result.Backup)
        Assert-True (Test-JdkSnapshotEqual $store.Holder.State $plan.After)
        $script:restoreFile = $result.Backup
        $script:committedState = Copy-State $store.Holder.State
    }
    Test-Case 'Idempotent switch performs no writes or backups' {
        $store = New-MemoryStore $script:committedState
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        $result = Invoke-JdkTransaction $plan -Store $store -BackupWriter { throw 'Must not back up no-op' } -Notifier $notify -AdministratorCheck $admin
        Assert-True (-not $result.Changed -and $store.Holder.Writes -eq 0)
    }
    Test-Case 'Backup failure leaves environment untouched' {
        $store = New-MemoryStore
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        Assert-Throws { Invoke-JdkTransaction $plan -Store $store -BackupWriter { throw 'disk full' } -Notifier $notify -AdministratorCheck $admin } '*disk full*'
        Assert-True ($store.Holder.Writes -eq 0)
    }
    Test-Case 'Rejects system writes without administrator rights' {
        $store = New-MemoryStore
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        Assert-Throws { Invoke-JdkTransaction $plan -Store $store -BackupWriter { 'unused' } -Notifier $notify -AdministratorCheck { $false } } '*管理员*'
        Assert-True ($store.Holder.Writes -eq 0)
    }
    foreach ($afterWrite in @($false, $true)) {
        Test-Case "Rolls back partial writes (failure after write: $afterWrite)" {
            $store = New-MemoryStore
            $before = Get-JdkSnapshot $store
            $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot $before
            $store.Holder.FailAt = 2; $store.Holder.FailAfter = $afterWrite
            Assert-Throws { Invoke-JdkTransaction $plan -Store $store -BackupWriter { 'test-backup' } -Notifier $notify -AdministratorCheck $admin } '*已回滚*'
            Assert-True (Test-JdkSnapshotEqual $store.Holder.State $before)
        }
    }
    Test-Case 'Rejects stale preview without writing' {
        $store = New-MemoryStore
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        (Find-Entry $store.Holder.State 'User' 'Path').Value = 'C:\External'
        Assert-Throws { Invoke-JdkTransaction $plan -Store $store -BackupWriter { 'test-backup' } -Notifier $notify -AdministratorCheck $admin } '*重新预览*'
        Assert-True ($store.Holder.Writes -eq 0)
    }
    Test-Case 'Keeps unrelated concurrent edits while rolling back own writes' {
        $store = New-MemoryStore
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        $store.Holder.ExternalAt = 1
        Assert-Throws { Invoke-JdkTransaction $plan -Store $store -BackupWriter { 'test-backup' } -Notifier $notify -AdministratorCheck $admin } '*已回滚*'
        Assert-True (-not (Find-Entry $store.Holder.State 'Machine' 'JAVA_HOME').Exists)
        Assert-True ((Find-Entry $store.Holder.State 'User' 'Path').Value -eq 'C:\External\Concurrent')
    }
    Test-Case 'Never overwrites a concurrent edit to a value during rollback' {
        $store = New-MemoryStore
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        $store.Holder.ConflictAt = 1
        Assert-Throws { Invoke-JdkTransaction $plan -Store $store -BackupWriter { 'test-backup' } -Notifier $notify -AdministratorCheck $admin } '*无法自动回滚*'
        Assert-True ((Find-Entry $store.Holder.State 'Machine' 'JAVA_HOME').Value -eq 'C:\External\ChangedAgain')
    }
    Test-Case 'Notification failure is reported after a successful commit' {
        $store = New-MemoryStore
        $plan = New-JdkSwitchPlan $jdkA -Scope Machine -Snapshot (Get-JdkSnapshot $store)
        $result = Invoke-JdkTransaction $plan -Store $store -BackupWriter { 'test-backup' } -Notifier { throw 'timeout' } -AdministratorCheck $admin
        Assert-True ($result.Changed -and $result.Warning -eq 'timeout')
        Assert-True (Test-JdkSnapshotEqual $store.Holder.State $plan.After)
    }
    Test-Case 'Restores original values, absence, and registry types' {
        $store = New-MemoryStore $script:committedState
        $plan = New-JdkRestorePlan -File $script:restoreFile -Snapshot (Get-JdkSnapshot $store)
        $result = Invoke-JdkTransaction $plan -Store $store -BackupDirectory $backupDirectory -Notifier $notify -AdministratorCheck $admin
        Assert-True $result.Changed
        Assert-True (Test-JdkSnapshotEqual $store.Holder.State (New-State))
    }
    Test-Case 'Restore refuses to overwrite post-backup edits' {
        $state = Copy-State $script:committedState
        (Find-Entry $state 'Machine' 'Path').Value = 'C:\External'
        Assert-Throws { New-JdkRestorePlan -File $script:restoreFile -Snapshot $state } '*拒绝恢复*'
    }
    Test-Case 'Restore preserves unrelated post-backup edits' {
        $state = Copy-State $script:committedState
        (Find-Entry $state 'User' 'Path').Value = 'C:\External\Keep'
        $plan = New-JdkRestorePlan -File $script:restoreFile -Snapshot $state
        Assert-True ((Find-Entry $plan.After 'User' 'Path').Value -eq 'C:\External\Keep')
    }
    Test-Case 'Restore can recover a partially applied transaction after a crash' {
        $state = Copy-State $script:committedState
        (Find-Entry $state 'Machine' 'Path').Value = (Find-Entry (New-State) 'Machine' 'Path').Value
        $plan = New-JdkRestorePlan -File $script:restoreFile -Snapshot $state
        Assert-True ($plan.Changes.Count -eq 1)
        Assert-True (Test-JdkSnapshotEqual $plan.After (New-State))
    }
    Test-Case 'Restore rejects another owner and malformed backup structure' {
        $document = [IO.File]::ReadAllText($script:restoreFile) | ConvertFrom-Json
        $document.OwnerSid = 'S-1-0-0'
        $tampered = Join-Path $testRoot 'tampered.json'
        [IO.File]::WriteAllText($tampered, ($document | ConvertTo-Json -Depth 14))
        Assert-Throws { New-JdkRestorePlan -File $tampered -Snapshot $script:committedState } '*当前账户*'
    }
} finally {
    # Deletion stays inside the explicitly created test workspace.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath((Join-Path $workspace '.local')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output "Tests: $script:passed passed, $script:failed failed. No real environment variables were written."
if ($script:failed -gt 0) { exit 1 }
