@echo off
setlocal
cd /d "%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0wad\maintenance\Preview-DomeniaUi.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo ECHEC : consultez les messages ci-dessus. Code %RESULT%.
pause
exit /b %RESULT%
