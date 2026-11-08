param([switch]$Run)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11720-qualification';$out=Join-Path $root 'out';$task='Domenia-RC20-Targeted';$shell=Join-Path $PSHOME 'powershell.exe'
if(-not $Run){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'Interactive user absent'}
 $saved=Join-Path $root 'Run-Targeted.ps1';if($PSCommandPath -ne $saved){Copy-Item $PSCommandPath $saved -Force}
 $action=New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$saved+'" -Run')
 Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 35)) -Force|Out-Null
 Start-ScheduledTask $task;'Targeted suites dispatched';exit
}
$tests=Join-Path $root 'dev\wad\tests';$results=Join-Path $out 'targeted';[void][IO.Directory]::CreateDirectory($results)
$plan=@(
 @{Name='Rules';Args=@('-Quiet');Limit=120},
 @{Name='QueryScale';Args=@();Limit=120},
 @{Name='StorageFaults';Args=@();Limit=180},
 @{Name='NetworkFaults';Args=@();Limit=120},
 @{Name='VaultQualification';Args=@('-NativeWindows');Limit=120},
 @{Name='CredentialGuard';Args=@();Limit=120},
 @{Name='Installer';Args=@('-Quiet');Limit=240},
 @{Name='UxQualification';Args=@();Limit=180},
 @{Name='Geometry';Args=@();Limit=180},
 @{Name='QueryLibraryTiming';Args=@();Limit=120}
)
$r=[ordered]@{Build='RC1.17.20';StartedUtc=[datetime]::UtcNow.ToString('o');Host=[Environment]::MachineName;PowerShell=$PSVersionTable.PSVersion.ToString();Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;ArchiveSha256=(Get-FileHash (Join-Path $root 'Domenia_DEV.zip') -Algorithm SHA256).Hash;Suites=@();Passed=$false}
function Save-Run{[IO.File]::WriteAllText((Join-Path $results 'Summary.json'),($r|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
foreach($spec in $plan){
 $name=[string]$spec.Name;$scriptPath=Join-Path $tests ('Test-Domenia'+$name+'.ps1');$report=Join-Path $results ($name+'.json');$r.Current=$name;Save-Run
 $row=[ordered]@{Name=$name;ExitCode=$null;TimedOut=$false;ReportWritten=$false};$p=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
 try{
  if(-not(Test-Path $scriptPath)){throw ('Missing suite '+$scriptPath)}
  $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$scriptPath,'-ReportPath',$report)+$spec.Args
  $p=Start-Process $shell -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $results ($name+'.stdout.txt')) -RedirectStandardError (Join-Path $results ($name+'.stderr.txt'));$null=$p.Handle
  if(-not $p.WaitForExit([int]$spec.Limit*1000)){$row.TimedOut=$true;$p.Kill();throw 'Suite budget exceeded'}
  $p.WaitForExit();$row.ExitCode=$p.ExitCode;$row.ReportWritten=Test-Path $report
 }catch{$row.Error=$_.Exception.Message}
 $watch.Stop();$row.DurationMs=$watch.ElapsedMilliseconds;$row.Passed=($row.ExitCode -eq 0 -and $row.ReportWritten -and -not $row.TimedOut);$r.Suites+=,[pscustomobject]$row;Save-Run
}
$r.Current='Finished';$r.FinishedUtc=[datetime]::UtcNow.ToString('o');$r.Passed=(@($r.Suites|Where-Object {-not $_.Passed}).Count -eq 0);Save-Run
if(-not $r.Passed){exit 1}
