@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
pushd "%~dp0"
"%PS%" -NoLogo -NoProfile -STA -File "%~dp0wad\tests\Test-DomeniaSupport.ps1" -Wpf %*
set "RC=%ERRORLEVEL%"
popd
pause
exit /b %RC%
