$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live'
$out=Join-Path $root 'critical-out'
[void][IO.Directory]::CreateDirectory($out)
function Save-Json($Name,$Value){[IO.File]::WriteAllText((Join-Path $out $Name),($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
if($env:COMPUTERNAME -ne 'W11-01' -or $PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Wrong test environment'}
$expected=@{prod='0393c1b7fd23e732209d3f96c4c91196afcb57ba26f02e86d79bbbc7eb4e908a';dev='001ae72db21059bda3ad5ac72e810d8c69e20b948e2fc18c224f5b070a2eb04b'}
$packs=@()
foreach($edition in @('prod','dev')){
 $zip=Join-Path $root ('Domenia_'+$edition.ToUpper()+'.zip');$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
 if($hash -ne $expected[$edition]){throw ('Wrong archive '+$edition)}
 if(-not (Test-Path (Join-Path $root ($edition+'\wad\package-manifest.json')))){Expand-Archive -LiteralPath $zip -DestinationPath $root -Force}
 $base=Join-Path $root $edition;$m=Get-Content (Join-Path $base 'wad\package-manifest.json') -Raw|ConvertFrom-Json
 foreach($f in $m.Files){$path=Join-Path $base $f.Path;if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $f.Sha256){throw ('Manifest mismatch '+$f.Path)}}
 $packs+=@([pscustomobject]@{Edition=$edition;Build=$m.Build;ArchiveSha256=$hash;ManifestFilesVerified=@($m.Files).Count;RuntimeFiles=@($m.Files|Where-Object Runtime).Count})
}
$prod=Get-Content (Join-Path $root 'prod\wad\package-manifest.json') -Raw|ConvertFrom-Json
foreach($f in $prod.Files|Where-Object Runtime){if((Get-FileHash (Join-Path $root ('dev\'+$f.Path)) -Algorithm SHA256).Hash -ne $f.Sha256){throw ('Runtime differs between PROD and DEV: '+$f.Path)}}
Save-Json 'FinalEnvironment.json' ([ordered]@{DateUtc=[datetime]::UtcNow.ToString('o');Computer=$env:COMPUTERNAME;PSVersion=$PSVersionTable.PSVersion.ToString();PSEdition=$PSVersionTable.PSEdition;Is64Bit=[Environment]::Is64BitProcess;Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();SessionId=(Get-Process -Id $PID).SessionId;FreeGB=[math]::Round((Get-PSDrive C).Free/1GB,1);SourceCommit='f7a3ee73461588f29b094f9a4810c09eeac6406a';Packs=$packs;IdenticalRuntime=$true;LiveAD=$false;Scope='Final archive and extracted-file integrity after targeted UI, health and backup checks; no tests rerun.'})

$task='Domenia-RC11717-Critical-UI'
$t=Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if($t -and $t.State -eq 'Running'){throw 'Interactive test still running; do not clean up yet'}
$resume=Get-ScheduledTask -TaskName ($task+'-Resume') -ErrorAction SilentlyContinue
if($resume -and $resume.State -eq 'Running'){throw 'Interactive continuation still running'}
$r=Get-Content (Join-Path $out 'InteractiveUI.json') -Raw|ConvertFrom-Json
if($r.AppId){$proc=Get-CimInstance Win32_Process -Filter ('ProcessId='+$r.AppId);if($proc -and $proc.CommandLine -like ('*'+$root+'\prod\*')){$app=Get-Process -Id $r.AppId;[void]$app.CloseMainWindow();if(-not $app.WaitForExit(8000)){Stop-Process -Id $app.Id -Force}}}
if($t){Unregister-ScheduledTask -TaskName $task -Confirm:$false}
Unregister-ScheduledTask -TaskName ($task+'-Resume') -Confirm:$false -ErrorAction SilentlyContinue
Save-Json 'Cleanup.json' ([ordered]@{DateUtc=[datetime]::UtcNow.ToString('o');TemporaryTaskRemoved=(-not [bool](Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue));TemporaryResumeTaskRemoved=(-not [bool](Get-ScheduledTask -TaskName ($task+'-Resume') -ErrorAction SilentlyContinue));VMsDeleted=$false;OperatorProfileDeleted=$false})
Write-Output 'Final PROD/DEV integrity and temporary task cleanup passed'
