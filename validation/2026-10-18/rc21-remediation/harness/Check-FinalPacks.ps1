$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11721-validation'
$r=[ordered]@{Build='RC1.17.21';Checks=@();Passed=$false;VMRetained=$true}
try{

$zip=Join-Path $root 'Final-prod.zip'
if((Get-FileHash $zip -Algorithm SHA256).Hash -ne 'FAE656FBB5BB245F774DE7FEA1B4526DDCADC5946488A77C5EDEBC51E5DACE79'){throw 'Archive hash mismatch'}
Expand-Archive $zip ($root+'\final-pack') -Force
$base=$root+'\final-pack\prod'
$m=Get-Content ($base+'\wad\package-manifest.json') -Raw|ConvertFrom-Json
$bad=@(foreach($e in $m.Files){$p=Join-Path $base $e.Path;if((Get-FileHash $p -Algorithm SHA256).Hash -ne $e.Sha256){$e.Path}})
if($bad.Count){throw ($bad -join ',')}
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File ($base+'\wad\Domenia-Start.ps1') -CheckOnly *> ($root+'\out\Final-prod-Startup.log')
if($LASTEXITCODE -ne 0){throw 'Final prod startup failed'}
$r.Checks+=@{Edition='prod';ArchiveSHA256='FAE656FBB5BB245F774DE7FEA1B4526DDCADC5946488A77C5EDEBC51E5DACE79';ManifestFiles=$m.Files.Count;CheckOnlyExitCode=$LASTEXITCODE}

$zip=Join-Path $root 'Final-dev.zip'
if((Get-FileHash $zip -Algorithm SHA256).Hash -ne 'DD0386B01E0FD2FFB49D12AA699678682B9525C200B878346FF6BEC760F3D27B'){throw 'Archive hash mismatch'}
Expand-Archive $zip ($root+'\final-pack') -Force
$base=$root+'\final-pack\dev'
$m=Get-Content ($base+'\wad\package-manifest.json') -Raw|ConvertFrom-Json
$bad=@(foreach($e in $m.Files){$p=Join-Path $base $e.Path;if((Get-FileHash $p -Algorithm SHA256).Hash -ne $e.Sha256){$e.Path}})
if($bad.Count){throw ($bad -join ',')}
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File ($base+'\wad\Domenia-Start.ps1') -CheckOnly *> ($root+'\out\Final-dev-Startup.log')
if($LASTEXITCODE -ne 0){throw 'Final dev startup failed'}
$r.Checks+=@{Edition='dev';ArchiveSHA256='DD0386B01E0FD2FFB49D12AA699678682B9525C200B878346FF6BEC760F3D27B';ManifestFiles=$m.Files.Count;CheckOnlyExitCode=$LASTEXITCODE}

$tasks=@(Get-ScheduledTask -TaskName 'Domenia-RC21-*' -ErrorAction SilentlyContinue)
if(@($tasks|Where-Object State -eq Running).Count){throw 'A qualification task is still active'}
$r.RemovedTasks=@($tasks.TaskName)
$tasks|Unregister-ScheduledTask -Confirm:$false
$r.RemainingQualificationProcesses=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'rc11721[^ ]*.*Run-(Rules|Geometry|Installer|Viewport|Followup|Last)\.ps1'})
if($r.RemainingQualificationProcesses.Count){throw 'Qualification process still active'}
$r.Passed=$true
}catch{$r.Error=$_.Exception.Message}
finally{$r.UTC=[datetime]::UtcNow.ToString('o');[IO.File]::WriteAllText(($root+'\out\PackCheck.json'),($r|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
$r|Select-Object Passed,Error
if(-not $r.Passed){exit 1}
