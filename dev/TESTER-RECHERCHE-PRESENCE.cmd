@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0wad\tests\Test-DomeniaSearchPresence.ps1"
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
