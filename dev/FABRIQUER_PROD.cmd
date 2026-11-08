@echo off
setlocal
set "DOMENIA_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "DOMENIA_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%DOMENIA_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Fabriquer-Prod.ps1" %*
set "DOMENIA_RESULT=%ERRORLEVEL%"
if not "%DOMENIA_RESULT%"=="0" echo Echec de fabrication. Aucun ancien PROD n'a ete remplace.
if "%~1"=="" pause
exit /b %DOMENIA_RESULT%
