@echo off
setlocal
for %%I in ("%~dp0..\..") do set "DOMENIA_PACKAGE_ROOT=%%~fI"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "FORGE="
if /I "%~1"=="FORCER" set "FORGE=-PasserOutreEmpreintes"
"%PS%" -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; try { $root=$env:DOMENIA_PACKAGE_ROOT; $m=Get-Content -LiteralPath (Join-Path $root 'wad\package-manifest.json') -Raw | ConvertFrom-Json; $e=@($m.Files | Where-Object {$_.Path -eq 'wad/Support/Debloquer-Paquet.ps1' -and $_.Runtime -eq $true}); if($e.Count -ne 1){throw 'Helper de deblocage absent du manifeste.'}; $p=Join-Path $root 'wad\Support\Debloquer-Paquet.ps1'; $b=[IO.File]::ReadAllBytes($p); $sha=[Security.Cryptography.SHA256]::Create(); $t=([Text.Encoding]::UTF8.GetString($b)).Replace([string][char]13+[char]10,[string][char]10).Replace([string][char]13,[string][char]10); $ok=$false; foreach($c in @($b,[Text.Encoding]::UTF8.GetBytes($t),[Text.Encoding]::UTF8.GetBytes([string][char]0xFEFF+$t))){ if(([BitConverter]::ToString($sha.ComputeHash($c)).Replace('-','')) -ieq $e[0].Sha256){$ok=$true} }; if(-not $ok){throw ('Empreinte du helper invalide : '+$p+' attendue '+$e[0].Sha256)}; Unblock-File -LiteralPath $p; & $p %FORGE% } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }"
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
