@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
pushd "%~dp0"
"%PS%" -NoLogo -NoProfile -File "%~dp0wad\tests\Test-DomeniaLogin.ps1" %*
set "RC=%ERRORLEVEL%"
popd
pause
exit /b %RC%
