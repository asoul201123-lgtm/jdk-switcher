#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$')][string]$Version = '1.1.0',
    [ValidatePattern('^JdkSwitcher(?:-[0-9.]+)?[.]exe$')][string]$FileName = 'JdkSwitcher.exe'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stageParent = Join-Path $root '.local'
$stage = Join-Path $stageParent ('exe-build-' + [guid]::NewGuid().ToString('N'))
$dist = Join-Path $root 'dist'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
$automationRoot = Join-Path $env:SystemRoot 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation'
$automation = @(Get-ChildItem -LiteralPath $automationRoot -Filter System.Management.Automation.dll -Recurse -File | Select-Object -First 1)
if (-not (Test-Path -LiteralPath $compiler) -or $automation.Count -ne 1) { throw 'Windows .NET Framework compiler and Windows PowerShell 5.1 are required.' }
& (Join-Path $PSScriptRoot 'Check-Privacy.ps1') -Root $root
try {
    [void][IO.Directory]::CreateDirectory($stage)
    $assemblyVersion = $Version.Split('-')[0] + '.0'
    $assemblyInfo = @"
using System.Reflection;
[assembly: AssemblyTitle("JDK Switcher")]
[assembly: AssemblyProduct("JDK Switcher")]
[assembly: AssemblyCompany("JDK Switcher contributors")]
[assembly: AssemblyCopyright("Copyright (c) 2026 JDK Switcher contributors")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$Version")]
"@
    $infoFile = Join-Path $stage 'AssemblyInfo.cs'
    [IO.File]::WriteAllText($infoFile, $assemblyInfo, (New-Object Text.UTF8Encoding($true)))
    $built = Join-Path $stage 'JdkSwitcher.exe'
    $arguments = @(
        '/nologo', '/utf8output', '/target:winexe', '/platform:anycpu', '/optimize+', '/debug-',
        ('/out:' + $built), ('/reference:' + $automation[0].FullName),
        '/reference:System.Core.dll', '/reference:System.Windows.Forms.dll',
        ('/win32manifest:' + (Join-Path $root 'src\app.manifest')),
        ('/resource:' + (Join-Path $root 'src\App.ps1') + ',App.ps1'),
        ('/resource:' + (Join-Path $root 'src\JdkSwitcher.Core.psm1') + ',JdkSwitcher.Core.psm1'),
        (Join-Path $root 'src\ExecutableHost.cs'), $infoFile
    )
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $built)) { throw 'EXE compilation failed.' }
    & (Join-Path $PSScriptRoot 'Check-Privacy.ps1') -Root $stage -Files @($built)
    # Smoke tests exercise the actual compiled host and embedded resources.
    # Both runs only read the environment; neither executes a transaction.
    foreach ($options in @('--smoke-test --demo', '--smoke-test')) {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $built
        $startInfo.WorkingDirectory = $stage
        $startInfo.Arguments = $options
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            if (-not $process.WaitForExit(45000)) { $process.Kill(); throw 'EXE read-only smoke test timed out.' }
            $errorText = $process.StandardError.ReadToEnd()
            if ($process.ExitCode -ne 0) { throw ('EXE read-only smoke test failed: ' + $errorText) }
        } finally { $process.Dispose() }
    }
    [void][IO.Directory]::CreateDirectory($dist)
    $target = Join-Path $dist $FileName
    [IO.File]::Copy($built, $target, $true)
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(($target + '.sha256'), ($hash + '  ' + $FileName + "`n"), [Text.Encoding]::ASCII)
    Write-Output ('Built dist/' + $FileName + ' (' + (Get-Item -LiteralPath $target).Length + ' bytes); compiled-host smoke tests passed.')
} finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($stageParent) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe build cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
