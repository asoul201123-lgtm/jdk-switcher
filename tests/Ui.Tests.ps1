#requires -Version 5.1
# Exercises both tabs and their download handoff with an offline worker.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\App.ps1') -Demo -SmokeTest

if ($controls.MainTabs.SelectedItem -ne $controls.LocalTab -or $controls.PreviewDetails.Visibility -ne 'Visible') {
    throw 'The app must start on the local tab with the selected demo JDK preview.'
}
foreach ($width in @(650, 950)) {
    $controls.LayoutRoot.Measure([Windows.Size]::new($width, 500))
    $controls.LayoutRoot.Arrange([Windows.Rect]::new(0, 0, $width, 500))
    Update-Layout
    $detailsRow = if ($width -lt 760) { 2 } else { 0 }
    $detailsColumn = if ($width -lt 760) { 0 } else { 2 }
    foreach ($details in @($controls.LocalDetails, $controls.DownloadDetails)) {
        if ([Windows.Controls.Grid]::GetRow($details) -ne $detailsRow -or [Windows.Controls.Grid]::GetColumn($details) -ne $detailsColumn) {
            throw 'Both pages must stack their panels at narrow widths and use two columns at wide widths.'
        }
    }
}
$controls.MainTabs.SelectedItem = $controls.DownloadTab
if ($controls.VersionList.SelectedItem.Major -ne 21 -or $controls.DownloadNowButton.IsEnabled -or $null -ne $script:downloadJob) {
    throw 'The demo download tab must show a selected LTS with network operations disabled.'
}
$controls.MainTabs.SelectedItem = $controls.LocalTab

$script:downloadModuleText = @'
function Get-JdkDownloadCatalog {
    [pscustomobject]@{ Major = 22; IsLts = $false }
    [pscustomobject]@{ Major = 17; IsLts = $true }
}
function Get-JdkDownloadPackage {
    param($Major, $Architecture)
    [pscustomobject]@{ Major = $Major }
}
function Install-JdkDownload {
    param($Package, $CancellationToken, $Progress)
    $CancellationToken.ThrowIfCancellationRequested()
    & $Progress ([pscustomobject]@{ Stage = 'Downloading'; Percent = 70; Message = 'Offline progress' })
    [pscustomobject]@{ Home = 'C:\Java\jdk-17'; Version = "$($Package.Major).0.1" }
}
'@

function Get-JdkDownloadArchitecture { 'x64' }
function Update-Scan { Reset-Preview }
function New-JdkSwitchPlan {
    param([Alias('Home')][string]$JdkHome, [string]$Scope)
    $script:requestedScope = $Scope
    [pscustomobject]@{ Type = 'Switch'; Changes = @() }
}
function Invoke-JdkTransaction {
    param($Plan)
    $script:switchCount++
    [pscustomobject]@{ Changed = $true; Warning = ''; Backup = 'C:\Java\demo-backup.json' }
}
function Wait-OfflineDownloadJob {
    if ($null -eq $script:downloadJob -or -not $script:downloadJob.Handle.AsyncWaitHandle.WaitOne(15000)) {
        throw 'The offline download job did not finish.'
    }
}
function Click-DownloadButton {
    $controls.DownloadNowButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}

$Demo = $false
$SmokeTest = $false
$script:admin = $false
$script:switchCount = 0
$script:requestedScope = ''
$controls.MainTabs.SelectedItem = $controls.DownloadTab
Wait-OfflineDownloadJob
Update-DownloadJob
if ($controls.VersionList.Items.Count -ne 2 -or $controls.VersionList.SelectedItem.Major -ne 17 -or -not $controls.DownloadNowButton.IsEnabled) {
    throw 'Opening the download tab must load the offline catalog and select the LTS.'
}

$controls.DownloadScopeBox.SelectedIndex = 1
if ($controls.DownloadNowButton.IsEnabled -or $controls.DownloadElevateButton.Visibility -ne 'Visible') {
    throw 'System-level download and switch must require administrator privileges.'
}
$script:admin = $true
Update-DownloadActions
Click-DownloadButton
Wait-OfflineDownloadJob
Stop-DownloadWorker
Update-DownloadJob
if ($script:switchCount -ne 0 -or -not $controls.DownloadNowButton.IsEnabled -or $controls.DownloadProgressBar.Visibility -ne 'Collapsed') {
    throw 'Cancelling after installation must skip auto-switch and allow retry.'
}

Click-DownloadButton
Wait-OfflineDownloadJob
Update-DownloadJob
if ($script:switchCount -ne 1 -or $script:requestedScope -ne 'Machine' -or
    $controls.DownloadProgressBar.Value -ne 100 -or $controls.DownloadDetailText.Text -notlike '*demo-backup.json*' -or
    $controls.MainTabs.SelectedItem -ne $controls.DownloadTab) {
    throw 'A completed download must use the chosen scope and leave the result in the download tab.'
}
Write-Output 'UI tests passed: local preview, catalog, permissions, cancellation, and offline auto-switch.'
