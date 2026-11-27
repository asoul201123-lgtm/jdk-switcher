#requires -Version 5.1
# Loads add-on windows without showing them, so malformed XAML fails in CI.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\App.ps1'))

$download = [regex]::Match($source, '(?s)\[xml\]\$downloadXaml = @''(.*?)''@')
if (-not $download.Success) { throw 'Download dialog XAML was not found.' }
$reader = New-Object Xml.XmlNodeReader([xml]$download.Groups[1].Value)
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($name in @('VersionBox', 'DownloadScopeText', 'DownloadProgressBar', 'DownloadDetailText', 'DownloadCloseButton', 'DownloadNowButton')) {
    if ($null -eq $window.FindName($name)) { throw "Download dialog is missing $name." }
}
$window.Close()
Write-Output 'UI tests passed: main XAML and download dialog XAML are readable.'
