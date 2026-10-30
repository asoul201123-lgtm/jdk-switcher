#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$')][string]$Version = '1.1.0',
    [ValidatePattern('^JdkSwitcher(?:-[0-9.]+)?[.]exe$')][string]$ExeFileName = 'JdkSwitcher.exe'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
$dist = Join-Path $root 'dist'
$stageParent = Join-Path $root '.local'
$stage = Join-Path $stageParent ('package-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stage 'jdk-switcher'
$files = @()
foreach ($name in @('Start.cmd', 'README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md', '.gitignore', '.gitattributes')) {
    $files += Join-Path $root $name
}
# Explicit directories, refused links, and known extensions only. Runtime data,
# personal settings, Git history and unrelated workspace files cannot enter.
foreach ($name in @('src', 'tests', 'scripts', 'docs', '.github', 'linux')) {
    $queue = New-Object 'Collections.Generic.Queue[string]'
    $queue.Enqueue((Join-Path $root $name))
    while ($queue.Count -gt 0) {
        $current = Get-Item -LiteralPath $queue.Dequeue() -Force
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Release inputs cannot contain symbolic links or junctions.' }
        foreach ($item in @(Get-ChildItem -LiteralPath $current.FullName -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Release inputs cannot contain symbolic links or junctions.' }
            if ($item.PSIsContainer) { if ($item.Name -notin @('__pycache__', '.pytest_cache')) { $queue.Enqueue($item.FullName) } }
            elseif ($item.Extension -in @('.ps1','.psm1','.cs','.manifest','.md','.png','.yml','.py','.sh')) { $files += $item.FullName }
            else { throw ('Unexpected release input: ' + $item.Name) }
        }
    }
}
foreach ($file in $files) {
    $item = Get-Item -LiteralPath $file -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Release inputs cannot contain symbolic links.' }
}
& (Join-Path $PSScriptRoot 'Check-Privacy.ps1') -Root $root -Files $files
try {
    & (Join-Path $PSScriptRoot 'Build-Exe.ps1') -Version $Version -FileName $ExeFileName
    [void][IO.Directory]::CreateDirectory($packageRoot)
    foreach ($file in $files) {
        $relative = $file.Substring($root.Length + 1)
        $target = Join-Path $packageRoot $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($file, $target, $false)
    }
    [IO.File]::Copy((Join-Path $dist $ExeFileName), (Join-Path $packageRoot 'JdkSwitcher.exe'), $false)
    $exeHash = (Get-FileHash -LiteralPath (Join-Path $packageRoot 'JdkSwitcher.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $packageRoot 'JdkSwitcher.exe.sha256'), ($exeHash + '  JdkSwitcher.exe' + "`n"), [Text.Encoding]::ASCII)
    & (Join-Path $PSScriptRoot 'Check-Privacy.ps1') -Root $packageRoot
    & (Join-Path $PSScriptRoot 'Check-Privacy.ps1') -Root $packageRoot -Files @((Join-Path $packageRoot 'JdkSwitcher.exe'))
    [void][IO.Directory]::CreateDirectory($dist)
    $zip = Join-Path $dist ("jdk-switcher-$Version-windows.zip")
    if (Test-Path -LiteralPath $zip) { throw 'Release ZIP already exists. Remove it explicitly or select a new version.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    # Verify actual archive entries, including dotfiles, rather than trusting staging.
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entries = @($archive.Entries | Where-Object { $_.Name -ne '' })
        if ($entries.Count -ne ($files.Count + 2)) { throw 'Release archive file count mismatch.' }
        $expected = @($files | ForEach-Object { 'jdk-switcher/' + $_.Substring($root.Length + 1).Replace('\','/') })
        $expected += @('jdk-switcher/JdkSwitcher.exe', 'jdk-switcher/JdkSwitcher.exe.sha256')
        foreach ($entry in $entries) {
            if ($entry.FullName.Replace('\','/') -cnotin $expected) { throw 'Unexpected release archive entry.' }
        }
    } finally { $archive.Dispose() }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(($zip + '.sha256'), ($hash + '  ' + [IO.Path]::GetFileName($zip) + "`n"), [Text.Encoding]::ASCII)
    Write-Output ('Created dist/' + [IO.Path]::GetFileName($zip))
    Write-Output ('SHA256 ' + $hash)
} finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($stageParent) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe staging cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
