$ErrorActionPreference='Stop';$root='C:\Windows\Temp\Domenia-RC22-Final';$out=Join-Path $root 'proof';[void][IO.Directory]::CreateDirectory($out)
Expand-Archive -LiteralPath (Join-Path $root 'Domenia_DEV.zip') -DestinationPath $root -Force
Expand-Archive -LiteralPath (Join-Path $root 'Domenia_PROD.zip') -DestinationPath $root -Force
$lab=Join-Path $root 'dev\engineering\d120\lab';[void][IO.Directory]::CreateDirectory($lab)
Copy-Item (Join-Path $root 'Invoke-DomeniaGuiJourney.ps1') $lab -Force;Copy-Item (Join-Path $root 'gui-journeys.json') $lab -Force
$p=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'prod\wad\Domenia-Start.ps1'),'-CheckOnly') -Wait -PassThru -RedirectStandardOutput (Join-Path $out 'Startup.log') -RedirectStandardError (Join-Path $out 'Startup.stderr')
$m=Get-Content (Join-Path $root 'prod\wad\package-manifest.json') -Raw|ConvertFrom-Json
if($m.Build -ne '2026.10.18-DOMENIA-1.0-RC1.17.22-D120'){throw 'Unexpected archive build'}
$hashes=@('Domenia_PROD.zip','Domenia_DEV.zip')|ForEach-Object {[pscustomobject]@{File=$_;SHA256=(Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash}}
[pscustomobject]@{Build=$m.Build;Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell51=($PSVersionTable.PSEdition -eq 'Desktop');CheckOnlyExitCode=$p.ExitCode;Passed=($p.ExitCode -eq 0);RuntimeFiles=@($m.Files|Where-Object {$_.Runtime}).Count;Archives=$hashes;CompletedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'Startup.json') -Encoding UTF8
if($p.ExitCode -ne 0){throw 'Pack startup CheckOnly failed'}
& "$PSHOME\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'dev\wad\tests\Test-DomeniaRules.ps1') -TestFileFilter GuiJourney.Tests.ps1 -ReportPath (Join-Path $out 'GuiRules.json') -Quiet
if($LASTEXITCODE -ne 0){throw 'GUI rules failed'}
$user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'No interactive user'}
$action=New-ScheduledTaskAction -Execute "$PSHOME\powershell.exe" -Argument '-NoProfile -STA -ExecutionPolicy Bypass -File C:\Windows\Temp\Domenia-RC22-Final\Run-Gui-RC22.ps1'
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'Domenia-RC22-FinalGui' -Action $action -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName 'Domenia-RC22-FinalGui'
