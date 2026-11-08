@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -File "%~dp0wad\tests\Test-DomeniaAcl.ps1"
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
