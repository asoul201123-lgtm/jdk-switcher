#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = (Join-Path $PSScriptRoot '..'), [string[]]$Files)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
if (-not $Files) {
    $rootNames = @('Start.cmd', 'README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md', '.gitignore', '.gitattributes')
    $Files = @($rootNames | ForEach-Object { Join-Path $rootPath $_ })
    foreach ($name in @('src', 'tests', 'scripts', 'docs', '.github', 'linux')) {
        $directory = Join-Path $rootPath $name
        if (Test-Path -LiteralPath $directory) { $Files += @(Get-ChildItem -LiteralPath $directory -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](__pycache__|[.]pytest_cache)[\\/]' -and $_.Extension -notin @('.pyc', '.pyo') } | ForEach-Object FullName) }
    }
}
$privateStrings = @($env:USERPROFILE, $rootPath, [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
if ($env:USERNAME -and $env:USERNAME.Length -ge 3) { $privateStrings += $env:USERNAME }
if ($env:COMPUTERNAME -and $env:COMPUTERNAME.Length -ge 4) { $privateStrings += $env:COMPUTERNAME }
if ($env:OS -eq 'Windows_NT') {
    $privateStrings += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try { $privateStrings += (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid } catch { }
}
$patterns = @(
    '(?i)[A-Z]:[\\/]+Users[\\/]+(?!Public[\\/]|Default[\\/])[^\\/\s<>%]+',
    '(?i)/(?:home|Users)/[a-z0-9_.-]+/',
    '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    '\bgh[pousr]_[A-Za-z0-9]{30,}\b',
    '\bgithub_pat_[A-Za-z0-9_]{30,}\b',
    '\bAKIA[0-9A-Z]{16}\b',
    '\bsk-[A-Za-z0-9_-]{32,}\b'
)
$issues = @()
foreach ($file in $Files) {
    $fullPath = [IO.Path]::GetFullPath($file)
    if (-not $fullPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Privacy check input escapes the release root.' }
    $relative = $fullPath.Substring($rootPath.Length + 1)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Missing release file: $relative" }
    if ([IO.Path]::GetExtension($fullPath) -eq '.png') {
        # Public screenshots must have no textual or EXIF metadata chunks.
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $offset = 8
        while ($offset + 12 -le $bytes.Length) {
            $length = [uint32]$bytes[$offset] * 16777216 + [uint32]$bytes[$offset+1] * 65536 + [uint32]$bytes[$offset+2] * 256 + [uint32]$bytes[$offset+3]
            $kind = [Text.Encoding]::ASCII.GetString($bytes, $offset + 4, 4)
            if ($kind -in @('tEXt','iTXt','zTXt','eXIf')) { $issues += "$relative (image metadata)"; break }
            $offset += [int64]$length + 12
        }
        continue
    }
    if ([IO.Path]::GetExtension($fullPath) -eq '.exe') {
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $content = [Text.Encoding]::UTF8.GetString($bytes) + "`n" + [Text.Encoding]::Unicode.GetString($bytes)
        if ($bytes.Length -gt 1) { $content += "`n" + [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1) }
    } else { $content = [IO.File]::ReadAllText($fullPath) }
    $found = $false
    foreach ($private in $privateStrings) {
        if ($private -and $content.IndexOf($private, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found = $true; break }
    }
    foreach ($pattern in $patterns) { if ($content -match $pattern) { $found = $true; break } }
    if ($found) { $issues += "$relative (possible private path, identifier or secret)" }
}
if ($issues.Count -gt 0) {
    # Never echo matched secrets or full environment values into CI logs.
    throw ("Privacy check failed:`n" + ($issues -join "`n"))
}
Write-Output ('Privacy check passed: ' + $Files.Count + ' release files; no matched private identifiers or secrets.')
