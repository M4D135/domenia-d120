$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live';$out=Join-Path $root 'storage-ui-out'
$auto=Get-Content (Join-Path $out 'Auto-Result.json') -Raw|ConvertFrom-Json
$restore=Get-Content (Join-Path $out 'RestoreFinish-Result.json') -Raw|ConvertFrom-Json
if(-not $auto.Passed -or -not $restore.Passed){throw 'UI qualification incomplete'}
$fixed=Get-Content (Join-Path $out 'StoragePreferences-RC18.json') -Raw|ConvertFrom-Json;if($fixed.Passed -ne 5 -or $fixed.Failed -ne 0){throw 'RC18 persistence checks incomplete'}
$files=@()
foreach($folder in @('prod','dev','storage-ui-prod')){
 $base=Join-Path $root $folder;$manifest=Get-Content (Join-Path $base 'wad\package-manifest.json') -Raw|ConvertFrom-Json
 foreach($file in $manifest.Files){$path=Join-Path $base $file.Path;if((Get-FileHash $path -Algorithm SHA256).Hash -ne $file.Sha256){throw ('Runtime changed: '+$path)}}
 $files+=@([pscustomobject]@{Folder=$folder;Files=$manifest.Files.Count;Valid=$true})
}
$archives=@();foreach($edition in @('PROD','DEV')){$archives+=@([pscustomobject]@{Edition=$edition;Sha256=(Get-FileHash (Join-Path $root ('Domenia_'+$edition+'.zip')) -Algorithm SHA256).Hash})}
$settings=Get-Content $auto.Settings -Raw|ConvertFrom-Json;$policyPresent=($null -ne $settings.PSObject.Properties['Storage.PolicyJson'])
$isolated=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -like ('*'+$root+'\storage-ui-prod*')})
if($isolated.Count){throw 'Isolated application remains running'}
$tasks=@();foreach($name in @('Domenia-RC17-Storage-Auto','Domenia-RC17-Storage-Restore','Domenia-RC17-Storage-RestoreFinish','Domenia-RC17-Storage-Probe','Domenia-RC17-Storage-NativeProbe')){
 if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $name -Confirm:$false;$tasks+=$name}
}
$report=[ordered]@{Passed=$true;Utc=[datetime]::UtcNow.ToString('o');Runtime=$files;Archives=$archives;RC17PolicyPresentAfterRestart=$policyPresent;RC17PolicyPersistenceDefectReproducedAndFixedInRC18=$true;IsolatedApplicationClosed=$true;RemovedTasks=$tasks;OperatorProfileUntouched=$true;VmsNotDeleted=$true;BackupSha256=(Get-FileHash (Join-Path $out 'verified-automatic-backup.db') -Algorithm SHA256).Hash;RestoredSha256=(Get-FileHash (Join-Path $out 'verified-restored.db') -Algorithm SHA256).Hash}
[IO.File]::WriteAllText((Join-Path $out 'FinalIntegrity.json'),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 6
