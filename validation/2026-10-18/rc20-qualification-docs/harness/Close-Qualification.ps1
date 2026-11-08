$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11720-qualification'
$out=Join-Path $root 'out';$history=Join-Path $out 'capture-history'
[void][IO.Directory]::CreateDirectory($history)
foreach($dir in @(Get-ChildItem $out -Directory -Filter 'capture-attempt*')){
 foreach($f in @(Get-ChildItem $dir.FullName -File -Recurse | Where-Object {$_.Extension -in @('.json','.txt')})){
  $rel=$f.FullName.Substring($out.Length+1);$to=Join-Path $history $rel
  [void][IO.Directory]::CreateDirectory((Split-Path $to));Copy-Item $f.FullName $to -Force
 }
}
foreach($name in @('Captures-Result.json','Captures.stdout.txt','Captures.stderr.txt')){Copy-Item (Join-Path $out $name) $history -Force}
$tasks=@('Domenia-RC20-Targeted','Domenia-RC20-GuideCaptures','Domenia-RC20-DisposableProfile','Domenia-RC20-TimingFixed','Domenia-RC20-UxFixed')
$removed=@()
foreach($name in $tasks){
 $t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($t){if($t.State -eq 'Running'){throw ('Task still active: '+$name)};Unregister-ScheduledTask -TaskName $name -Confirm:$false;$removed+=$name}
}
$manifest=Get-Content (Join-Path $root 'dev\tools\prod-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$mismatch=@(foreach($f in $manifest.Files){$file=Join-Path (Join-Path $root 'dev') $f.Path;if(-not(Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $f.Sha256){$f.Path}})
$users=@(Get-LocalUser -Name 'DomeniaRC20Test' -ErrorAction SilentlyContinue)
$profiles=@(Get-CimInstance Win32_UserProfile | Where-Object {$_.LocalPath -match '\\DomeniaRC20Test(?:\.|$)'})
$processes=@(Get-CimInstance Win32_Process | Where-Object {$_.CommandLine -like '*d120-rc11720-qualification*' -and $_.ProcessId -ne $PID} | Select-Object ProcessId,Name)
$r=[ordered]@{UTC=[datetime]::UtcNow.ToString('o');Host=[Environment]::MachineName;RemovedTasks=$removed;RuntimeFiles=@($manifest.Files).Count;RuntimeMismatches=$mismatch;DevArchiveSHA256=(Get-FileHash (Join-Path $root 'Domenia_DEV.zip') -Algorithm SHA256).Hash;ProdArchiveSHA256=(Get-FileHash 'C:\DomeniaLab\d120-rc11720-final\Domenia_PROD.zip' -Algorithm SHA256).Hash;DisposableUserCount=$users.Count;DisposableProfileCount=$profiles.Count;OtherQualificationProcesses=$processes;VMRetained=$true}
$r.Passed=($mismatch.Count -eq 0 -and $users.Count -eq 0 -and $profiles.Count -eq 0 -and $processes.Count -eq 0)
[IO.File]::WriteAllText((Join-Path $history 'Cleanup.json'),($r|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$r|ConvertTo-Json -Depth 5
