@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -STA -File "%~dp0wad\tests\Test-DomeniaModules.ps1"
if errorlevel 1 goto failed
"%PS%" -NoLogo -NoProfile -STA -File "%~dp0wad\tests\Test-DomeniaCandidate.ps1" -Wpf
set "RC=%ERRORLEVEL%"
goto done
:failed
set "RC=%ERRORLEVEL%"
:done
pause
exit /b %RC%
