#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\JdkSwitcher.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\JdkSwitcher.Download.psm1') -Force
$script:passed = 0
$script:failed = 0

function Assert-True { param([bool]$Condition, [string]$Message = 'Assertion failed') if (-not $Condition) { throw $Message } }
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
function New-FixtureJdk {
    param([string]$Directory, [string]$Version)
    [void][IO.Directory]::CreateDirectory((Join-Path $Directory 'bin'))
    [IO.File]::WriteAllText((Join-Path $Directory 'release'), "JAVA_VERSION=`"$Version`"`nIMPLEMENTOR=`"Eclipse Adoptium`"`n")
    foreach ($name in @('java.exe', 'javac.exe')) {
        $bytes = New-Object byte[] 256
        $bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[60] = 0x80
        $bytes[128] = 0x50; $bytes[129] = 0x45; $bytes[132] = 0x64; $bytes[133] = 0x86
        [IO.File]::WriteAllBytes((Join-Path $Directory ('bin\' + $name)), $bytes)
    }
    $Directory
}
function Get-Hash { param([string]$File) (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant() }
function New-TestPackage {
    param([string]$Archive)
    [pscustomobject]@{
        Major = 21; Version = '21.0.1+1'; ReleaseName = 'jdk-21.0.1+1'; Vendor = 'Eclipse Temurin'
        Architecture = 'x64'; Name = 'jdk.zip'; Uri = 'https://example.invalid/jdk.zip'
        Sha256 = (Get-Hash $Archive); Size = (Get-Item -LiteralPath $Archive).Length; ArchiveType = 'zip'
    }
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $workspace ('.local\download-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $source = Join-Path $testRoot 'source'
    [void][IO.Directory]::CreateDirectory($source)
    $null = New-FixtureJdk (Join-Path $source 'jdk-21.0.1+1') '21.0.1'
    $archive = Join-Path $testRoot 'jdk.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($source, $archive)
    $script:archiveSource = $archive
    $copyDownloader = {
        param($Package, $Destination, $Token, $Progress)
        $Token.ThrowIfCancellationRequested()
        [IO.File]::Copy($script:archiveSource, $Destination)
        & $Progress ([pscustomobject]@{ Stage='Downloading'; Percent=100; Message='copied' })
    }

    Test-Case 'Parses available releases and marks LTS versions' {
        $loader = { [pscustomobject]@{ available_releases=@(8,17,21,25); available_lts_releases=@(8,17,21,25) } }
        $catalog = @(Get-JdkDownloadCatalog -MetadataLoader $loader)
        Assert-True ($catalog.Count -eq 4 -and $catalog[0].Major -eq 25 -and $catalog[0].IsLts)
    }
    Test-Case 'Selects the Windows ZIP and checksum from official metadata' {
        $asset = [pscustomobject]@{
            release_name = 'jdk-21.0.1+1'; version = [pscustomobject]@{ semver='21.0.1+1'; openjdk_version='21.0.1' }
            binary = [pscustomobject]@{ package = [pscustomobject]@{
                name='OpenJDK21U-jdk_x64_windows_hotspot.zip'; link='https://example.invalid/jdk.zip'; checksum=('a' * 64); size=1234
            } }
        }
        $loader = { $asset }.GetNewClosure()
        $package = Get-JdkDownloadPackage -Major 21 -Architecture x64 -MetadataLoader $loader
        Assert-True ($package.ArchiveType -eq 'zip' -and $package.Size -eq 1234 -and $package.Major -eq 21)
    }
    Test-Case 'Installs a verified JDK into the managed root' {
        $installed = Install-JdkDownload -Package (New-TestPackage $archive) -DestinationRoot (Join-Path $testRoot 'managed') -Downloader $copyDownloader
        Assert-True ($installed.Version -eq '21.0.1' -and $installed.Architecture -eq 'x64' -and -not $installed.AlreadyInstalled)
        Assert-True (Test-Path -LiteralPath (Join-Path $installed.Home 'bin\java.exe'))
        $script:installed = $installed
    }
    Test-Case 'Reuses an existing installation without downloading again' {
        $installed = Install-JdkDownload -Package (New-TestPackage $archive) -DestinationRoot (Join-Path $testRoot 'managed') -Downloader { throw 'Must not download' }
        Assert-True ($installed.AlreadyInstalled -and $installed.Home -eq $script:installed.Home)
    }
    Test-Case 'Rejects a checksum mismatch and leaves no installation' {
        $package = New-TestPackage $archive
        $package.Sha256 = '0' * 64
        Assert-Throws { Install-JdkDownload -Package $package -DestinationRoot (Join-Path $testRoot 'bad-hash') -Downloader $copyDownloader } '*SHA-256*'
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'bad-hash') -Directory).Count -eq 0)
    }
    Test-Case 'Blocks ZIP path traversal' {
        $malicious = Join-Path $testRoot 'malicious.zip'
        $zip = [IO.Compression.ZipFile]::Open($malicious, 'Create')
        try { $entry = $zip.CreateEntry('..\escape.txt'); $writer = New-Object IO.StreamWriter($entry.Open()); try { $writer.Write('bad') } finally { $writer.Dispose() } }
        finally { $zip.Dispose() }
        $script:archiveSource = $malicious
        Assert-Throws { Install-JdkDownload -Package (New-TestPackage $malicious) -DestinationRoot (Join-Path $testRoot 'bad-zip') -Downloader $copyDownloader } '*越界路径*'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'escape.txt')))
        $script:archiveSource = $archive
    }
    Test-Case 'Rejects archives without a complete JDK' {
        $invalid = Join-Path $testRoot 'invalid.zip'
        $zip = [IO.Compression.ZipFile]::Open($invalid, 'Create')
        try { $null = $zip.CreateEntry('jdk\readme.txt') } finally { $zip.Dispose() }
        $script:archiveSource = $invalid
        Assert-Throws { Install-JdkDownload -Package (New-TestPackage $invalid) -DestinationRoot (Join-Path $testRoot 'invalid-jdk') -Downloader $copyDownloader } '*完整 Windows JDK*'
        $script:archiveSource = $archive
    }
    Test-Case 'Honors cancellation without publishing a partial installation' {
        $source = New-Object Threading.CancellationTokenSource
        $source.Cancel()
        try { Assert-Throws { Install-JdkDownload -Package (New-TestPackage $archive) -DestinationRoot (Join-Path $testRoot 'cancelled') -CancellationToken $source.Token -Downloader $copyDownloader } }
        finally { $source.Dispose() }
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'cancelled') -Directory).Count -eq 0)
    }
    Test-Case 'Installed JDK plugs directly into the existing switch transaction' {
        $state = [pscustomobject]@{ Values = @(
            [pscustomobject]@{ Scope='Machine'; Name='JAVA_HOME'; Exists=$false; Kind='String'; Value=$null },
            [pscustomobject]@{ Scope='Machine'; Name='Path'; Exists=$true; Kind='ExpandString'; Value='C:\Windows\System32' },
            [pscustomobject]@{ Scope='User'; Name='JAVA_HOME'; Exists=$false; Kind='String'; Value=$null },
            [pscustomobject]@{ Scope='User'; Name='Path'; Exists=$true; Kind='String'; Value='C:\Tools\Keep' }
        ) }
        $store = [pscustomobject]@{ State=$state }
        $store | Add-Member -MemberType NoteProperty -Name Read -Value { $store.State | ConvertTo-Json -Depth 12 | ConvertFrom-Json }.GetNewClosure()
        $store | Add-Member -MemberType NoteProperty -Name Write -Value {
            param($entry)
            $target = $store.State.Values | Where-Object { $_.Scope -eq $entry.Scope -and $_.Name -eq $entry.Name }
            $target.Exists=$entry.Exists; $target.Kind=$entry.Kind; $target.Value=$entry.Value
        }.GetNewClosure()
        $plan = New-JdkSwitchPlan -Home $script:installed.Home -Scope User -Snapshot (Get-JdkSnapshot $store)
        $result = Invoke-JdkTransaction $plan -Store $store -BackupWriter { 'offline-backup' } -Notifier { } -AdministratorCheck { $true }
        Assert-True ($result.Changed -and ($store.State.Values | Where-Object { $_.Scope -eq 'User' -and $_.Name -eq 'JAVA_HOME' }).Value -eq $script:installed.Home)
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath((Join-Path $workspace '.local')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output "Download tests: $script:passed passed, $script:failed failed. No network or real registry writes were used."
if ($script:failed -gt 0) { exit 1 }
