@echo off
setlocal
cd /d "%~dp0"
set "JDK_SWITCHER_HOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "JDK_SWITCHER_HOST=%ProgramFiles%\PowerShell\7\pwsh.exe"
set "JDK_SWITCHER_APP=%~dp0src\App.ps1"
start "" "%JDK_SWITCHER_HOST%" -NoLogo -NoProfile -STA -WindowStyle Hidden -Command "try { & $env:JDK_SWITCHER_APP } catch { Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'JDK Switcher - Startup error') }"
