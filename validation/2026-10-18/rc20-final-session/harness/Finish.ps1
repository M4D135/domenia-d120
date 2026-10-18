$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11720-final';$out=Join-Path $root 'final-out'
$r=Get-Content (Join-Path $out 'Final-Result.json') -Raw -Encoding UTF8|ConvertFrom-Json
if(-not $r.Passed -or -not $r.RuntimeUnchanged){throw 'Final run incomplete'}
foreach($id in @($r.FirstProcess,$r.SecondProcess)){if(Get-Process -Id $id -ErrorAction SilentlyContinue){throw ('Test process remains: '+$id)}}
$task='Domenia-RC20-Final';$info=Get-ScheduledTaskInfo -TaskName $task
if($info.LastTaskResult -ne 0){throw ('Controller did not exit cleanly: '+$info.LastTaskResult)}
Unregister-ScheduledTask -TaskName $task -Confirm:$false
$final=[ordered]@{Passed=$true;Utc=[datetime]::UtcNow.ToString('o');ControllerExitCode=$info.LastTaskResult;ApplicationProcessesClosed=$true;ScheduledTaskRemoved=$true;VmsDeleted=$false;ProdSha256=(Get-FileHash (Join-Path $root 'Domenia_PROD.zip') -Algorithm SHA256).Hash;BackupSha256=(Get-FileHash (Join-Path $out 'verified-automatic-backup.db') -Algorithm SHA256).Hash}
[IO.File]::WriteAllText((Join-Path $out 'Cleanup.json'),($final|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$final|ConvertTo-Json
