@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0wad\maintenance\Preview-DomeniaUi.ps1" -Progressive
if errorlevel 1 pause
endlocal
