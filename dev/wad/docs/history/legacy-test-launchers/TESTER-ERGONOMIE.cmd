@echo off
setlocal
cd /d "%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0wad\tests\Test-DomeniaCompactUi.ps1"
set "rc=%errorlevel%"
if not "%rc%"=="0" echo Echec : consultez le message ci-dessus.
pause
exit /b %rc%
