@echo off
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -File "%~dp0wad\tests\Test-DomeniaEmbeddedUi.ps1"
set "rc=%errorlevel%"
echo.
echo Code de retour : %rc%
pause
exit /b %rc%
