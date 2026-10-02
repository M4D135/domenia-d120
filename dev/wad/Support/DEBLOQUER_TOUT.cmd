@echo off
setlocal
for %%I in ("%~dp0..\..") do set "DOMENIA_PACKAGE_ROOT=%%~fI"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; try { $root=$env:DOMENIA_PACKAGE_ROOT; $m=Get-Content -LiteralPath (Join-Path $root 'wad\package-manifest.json') -Raw | ConvertFrom-Json; $e=@($m.Files | Where-Object {$_.Path -eq 'wad/Support/Debloquer-Paquet.ps1' -and $_.Runtime -eq $true}); if($e.Count -ne 1){throw 'Helper de deblocage absent du manifeste.'}; $p=Join-Path $root 'wad\Support\Debloquer-Paquet.ps1'; if((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ine $e[0].Sha256){throw 'Empreinte du helper invalide.'}; Unblock-File -LiteralPath $p; & $p } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }"
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
