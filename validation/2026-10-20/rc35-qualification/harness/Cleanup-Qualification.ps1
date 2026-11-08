$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification'
$r=Get-Content (Join-Path $root 'ui-out\FirstStepsReopen-Result.json') -Raw|ConvertFrom-Json
if(-not $r.Passed){throw 'Final UI qualification has not passed'}
$tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'Domenia-RC35-*'})
foreach($task in $tasks){Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false}
[pscustomobject]@{Utc=[datetime]::UtcNow.ToString('o');RemovedQualificationTasks=@($tasks.TaskName);VmRetained=$true;QualificationFilesRetained=$true}|ConvertTo-Json -Depth 3|Set-Content (Join-Path $root 'Cleanup.json') -Encoding UTF8
