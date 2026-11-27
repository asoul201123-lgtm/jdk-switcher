#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http, System.IO.Compression, System.IO.Compression.FileSystem

function Get-JdkManagedRoot {
    Join-Path (Get-JdkDataDirectory) 'jdks'
}

function Get-JdkDownloadArchitecture {
    $value = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
    if ([string]::IsNullOrWhiteSpace($value)) { throw '无法识别本机处理器架构。' }
    switch ($value.ToUpperInvariant()) {
        'AMD64' { 'x64' }
        'ARM64' { 'aarch64' }
        default { throw "暂不支持自动下载 $value 架构的 JDK；可通过『添加目录』使用已有安装。" }
    }
}

function New-JdkHttpClient {
    param([int]$TimeoutSeconds = 45)
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 5
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('SafeJdkSwitcher/1.2')
    $client
}

function Invoke-JdkWebJson {
    param([Parameter(Mandatory)][string]$Uri)
    if (([uri]$Uri).Scheme -ne 'https') { throw '版本目录只允许使用 HTTPS。' }
    $client = New-JdkHttpClient
    try {
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            [void]$response.EnsureSuccessStatusCode()
            if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw '版本目录重定向到了非 HTTPS 地址。' }
            if ($response.Content.Headers.ContentLength -gt 4MB) { throw '版本目录响应过大。' }
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($text.Length -gt 4MB) { throw '版本目录响应过大。' }
            $text | ConvertFrom-Json
        } finally { $response.Dispose() }
    } catch {
        throw "无法获取 JDK 版本信息：$($_.Exception.Message)"
    } finally { $client.Dispose() }
}

function Get-JdkDownloadCatalog {
    [CmdletBinding()]
    param([scriptblock]$MetadataLoader = { param($Uri) Invoke-JdkWebJson $Uri })
    $info = & $MetadataLoader 'https://api.adoptium.net/v3/info/available_releases'
    $lts = @($info.available_lts_releases)
    @($info.available_releases) | ForEach-Object {
        $major = [int]$_
        [pscustomobject]@{
            Major = $major
            Label = if ($major -in $lts) { "JDK $major LTS" } else { "JDK $major" }
            IsLts = $major -in $lts
            Vendor = 'Eclipse Temurin'
        }
    } | Sort-Object Major -Descending
}

function Get-JdkDownloadPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(6, 999)][int]$Major,
        [ValidateSet('x64', 'aarch64')][string]$Architecture = (Get-JdkDownloadArchitecture),
        [scriptblock]$MetadataLoader = { param($Uri) Invoke-JdkWebJson $Uri }
    )
    $uri = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot?architecture=$Architecture&image_type=jdk&os=windows&vendor=eclipse"
    $assets = @(& $MetadataLoader $uri)
    $packages = @($assets | Where-Object {
        $_.binary.package -and $_.binary.package.name -like '*.zip' -and
        $_.binary.package.link -and $_.binary.package.checksum
    })
    if ($packages.Count -ne 1) { throw "未找到 JDK $Major ($Architecture) 的唯一 Windows ZIP 下载包。" }
    $asset = $packages[0]
    $package = $asset.binary.package
    if (([uri]$package.link).Scheme -ne 'https') { throw 'JDK 下载地址必须使用 HTTPS。' }
    if ([string]$package.checksum -notmatch '^[0-9a-fA-F]{64}$') { throw '发行方返回了无效的 SHA-256。' }
    $version = if ($asset.version.openjdk_version) { [string]$asset.version.openjdk_version } else { [string]$asset.version.semver }
    [pscustomobject]@{
        Major = $Major
        Version = $version
        ReleaseName = [string]$asset.release_name
        Vendor = 'Eclipse Temurin'
        Architecture = $Architecture
        Name = [string]$package.name
        Uri = [string]$package.link
        Sha256 = ([string]$package.checksum).ToLowerInvariant()
        Size = [long]$package.size
        ArchiveType = 'zip'
    }
}

function Write-JdkDownloadProgress {
    param([scriptblock]$Progress, [string]$Stage, [int]$Percent, [string]$Message)
    if ($Progress) { & $Progress ([pscustomobject]@{ Stage = $Stage; Percent = $Percent; Message = $Message }) }
}

function Invoke-JdkArchiveDownload {
    param($Package, [string]$Destination, [Threading.CancellationToken]$CancellationToken, [scriptblock]$Progress)
    if (([uri]$Package.Uri).Scheme -ne 'https') { throw 'JDK 下载地址必须使用 HTTPS。' }
    if ($Package.Size -gt 1GB) { throw '下载包超过 1 GB 安全限制。' }
    $client = New-JdkHttpClient -TimeoutSeconds 1800
    try {
        $response = $client.GetAsync($Package.Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $CancellationToken).GetAwaiter().GetResult()
        try {
            [void]$response.EnsureSuccessStatusCode()
            if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw '下载重定向到了非 HTTPS 地址。' }
            $length = $response.Content.Headers.ContentLength
            if ($length -gt 1GB -or ($Package.Size -gt 0 -and $length -gt $Package.Size)) { throw '下载响应超过发行方声明的大小。' }
            $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $output = [IO.File]::Open($Destination, 'CreateNew', 'Write', 'None')
                try {
                    $buffer = New-Object byte[] 81920
                    $total = [long]0
                    while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $CancellationToken.ThrowIfCancellationRequested()
                        $total += $read
                        if ($total -gt 1GB -or ($Package.Size -gt 0 -and $total -gt $Package.Size)) { throw '下载内容超过允许的大小。' }
                        $output.Write($buffer, 0, $read)
                        $expected = if ($Package.Size -gt 0) { [long]$Package.Size } else { $length }
                        $percent = if ($expected -gt 0) { [Math]::Min(99, [int]($total * 100 / $expected)) } else { 0 }
                        Write-JdkDownloadProgress $Progress 'Downloading' $Percent ("正在下载：{0:N1} MB" -f ($total / 1MB))
                    }
                    $output.Flush($true)
                } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        } finally { $response.Dispose() }
    } catch [OperationCanceledException] { throw '下载已取消。' }
}

function Expand-JdkSafeZip {
    param([string]$Archive, [string]$Destination, [Threading.CancellationToken]$CancellationToken)
    $root = [IO.Path]::GetFullPath($Destination)
    [void][IO.Directory]::CreateDirectory($root)
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 20000) { throw 'ZIP 条目过多，已停止解压。' }
        $total = [long]0
        foreach ($entry in $zip.Entries) {
            $CancellationToken.ThrowIfCancellationRequested()
            $normalized = $entry.FullName.Replace('\', '/')
            if ($normalized.StartsWith('/') -or $normalized.Contains(':') -or ($normalized.Split('/') -contains '..')) {
                throw 'ZIP 包含越界路径，已拒绝解压。'
            }
            $target = [IO.Path]::GetFullPath((Join-Path $root $normalized))
            if ($target -ne $root -and -not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ZIP 包含越界路径，已拒绝解压。'
            }
            if (-not $paths.Add($target)) { throw 'ZIP 包含重复路径，已拒绝解压。' }
            $isDirectory = $normalized.EndsWith('/')
            if ($isDirectory) { [void][IO.Directory]::CreateDirectory($target); continue }
            if ($entry.Length -gt 1GB -or ($total + $entry.Length) -gt 2GB) { throw 'ZIP 解压后超过安全限制。' }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $input = $entry.Open()
            try {
                $output = [IO.File]::Open($target, 'CreateNew', 'Write', 'None')
                try {
                    $buffer = New-Object byte[] 81920
                    $written = [long]0
                    while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $CancellationToken.ThrowIfCancellationRequested()
                        $written += $read
                        $total += $read
                        if ($written -gt 1GB -or $total -gt 2GB) { throw 'JDK 解压后超过安全限制。' }
                        $output.Write($buffer, 0, $read)
                    }
                } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Install-JdkDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [string]$DestinationRoot = (Get-JdkManagedRoot),
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [scriptblock]$Progress = {},
        [scriptblock]$Downloader = { param($p, $d, $t, $callback) Invoke-JdkArchiveDownload $p $d $t $callback }
    )
    if ($Package.ArchiveType -ne 'zip' -or [string]$Package.Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw '下载包信息无效。' }
    $safeName = ([string]$Package.ReleaseName -replace '[^A-Za-z0-9._+-]', '-').Trim('.')
    if (-not $safeName) { throw '发行方版本名无效。' }
    $root = [IO.Path]::GetFullPath($DestinationRoot)
    [void][IO.Directory]::CreateDirectory($root)
    if (((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'JDK 托管目录不能是符号链接或目录联接。' }
    $target = Join-Path $root ("temurin-$safeName-$($Package.Architecture)")
    if (Test-Path -LiteralPath $target) {
        try {
            $existing = Get-JdkInstallation $target
            Write-JdkDownloadProgress $Progress 'Installed' 100 '该版本已经安装，无需重复下载。'
            $existing | Add-Member -NotePropertyName AlreadyInstalled -NotePropertyValue $true
            return $existing
        } catch { throw "目标目录已存在但不是有效 JDK，未覆盖：$target" }
    }
    if ($Package.Size -gt 0) {
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
        if ($drive.AvailableFreeSpace -lt (2 * [long]$Package.Size + 256MB)) { throw '磁盘可用空间不足，无法下载并解压该 JDK。' }
    }
    # Stage beside the managed root so the final move stays on one volume.
    $tempBase = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + '.installing'
    [void][IO.Directory]::CreateDirectory($tempBase)
    if (((Get-Item -LiteralPath $tempBase).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '下载临时目录不能是符号链接或目录联接。' }
    $temp = Join-Path $tempBase ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    if (((Get-Item -LiteralPath $temp).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '下载临时目录不能是符号链接或目录联接。' }
    $archive = Join-Path $temp 'jdk.zip.partial'
    $extract = Join-Path $temp 'extract'
    try {
        Write-JdkDownloadProgress $Progress 'Downloading' 0 '正在连接发行方下载服务器…'
        & $Downloader $Package $archive $CancellationToken $Progress
        $CancellationToken.ThrowIfCancellationRequested()
        $file = Get-Item -LiteralPath $archive
        if ($Package.Size -gt 0 -and $file.Length -ne [long]$Package.Size) { throw '下载文件大小与发行方目录不一致。' }
        Write-JdkDownloadProgress $Progress 'Verifying' 0 '正在校验 SHA-256…'
        $stream = [IO.File]::OpenRead($archive)
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
        } finally { $stream.Dispose() }
        if ($actual -cne ([string]$Package.Sha256).ToLowerInvariant()) { throw 'SHA-256 校验失败，下载文件已丢弃。' }
        Write-JdkDownloadProgress $Progress 'Extracting' 0 '正在安全解压并验证 JDK…'
        Expand-JdkSafeZip $archive $extract $CancellationToken
        $installations = @()
        $candidates = @($extract) + @(Get-ChildItem -LiteralPath $extract -Directory | Select-Object -ExpandProperty FullName)
        foreach ($candidate in $candidates) {
            if (-not (Test-Path -LiteralPath (Join-Path $candidate 'release') -PathType Leaf)) { continue }
            try { $installations += Get-JdkInstallation $candidate }
            catch { throw "下载包中的 JDK 校验失败：$($_.Exception.Message)" }
        }
        if ($installations.Count -ne 1) { throw '压缩包中未找到唯一的完整 Windows JDK。' }
        $jdk = $installations[0]
        $expectedArch = if ($Package.Architecture -eq 'aarch64') { 'ARM64' } else { 'x64' }
        if ($jdk.Architecture -ne $expectedArch) { throw "下载包架构不匹配：预期 $expectedArch，实际 $($jdk.Architecture)。" }
        $CancellationToken.ThrowIfCancellationRequested()
        if (Test-Path -LiteralPath $target) { throw '目标安装目录已被其他进程创建，未覆盖。' }
        [IO.Directory]::Move($jdk.Home, $target)
        $installed = Get-JdkInstallation $target
        $installed | Add-Member -NotePropertyName AlreadyInstalled -NotePropertyValue $false
        Write-JdkDownloadProgress $Progress 'Installed' 100 "JDK $($installed.Version) 已安装。"
        $installed
    } finally {
        if (Test-Path -LiteralPath $temp) {
            $resolved = [IO.Path]::GetFullPath($temp)
            $allowed = [IO.Path]::GetFullPath($tempBase) + [IO.Path]::DirectorySeparatorChar
            if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe download cleanup path' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

Export-ModuleMember -Function Get-JdkManagedRoot, Get-JdkDownloadArchitecture, Get-JdkDownloadCatalog, Get-JdkDownloadPackage, Install-JdkDownload
