param([switch]$Run)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11720-qualification';$out=Join-Path $root 'out';$task='Domenia-RC20-GuideCaptures'
if(-not $Run){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'Interactive user absent'}
 $saved=Join-Path $root 'Run-Captures.ps1';if($PSCommandPath -ne $saved){Copy-Item $PSCommandPath $saved -Force}
 $action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$saved+'" -Run')
 Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 6)) -Force|Out-Null
 Start-ScheduledTask $task;'Captures dispatched';exit
}
$r=[ordered]@{Build='RC1.17.20';StartedUtc=[datetime]::UtcNow.ToString('o');Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Passed=$false}
try{
 $p=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'capture-guides.ps1'),'-Dev',(Join-Path $root 'dev'),'-Out',(Join-Path $out 'guide-captures')) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out 'Captures.stdout.txt') -RedirectStandardError (Join-Path $out 'Captures.stderr.txt')
 $null=$p.Handle;if(-not $p.WaitForExit(300000)){$p.Kill();throw 'Capture script exceeded 300 seconds'};$p.WaitForExit();$r.ExitCode=$p.ExitCode
 if($p.ExitCode -ne 0){throw ('Capture script exited '+$p.ExitCode)}
 $prov=Get-Content (Join-Path $out 'guide-captures\capture-provenance.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $checks=Get-Content (Join-Path $out 'guide-captures\capture-checks.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $r.Images=@($prov.Images).Count;$r.Checks=@($checks.Checks).Count
 if(@($checks.Checks|Where-Object {-not $_.Passed}).Count){throw 'Capture layout check failure'}
 $r.Passed=$true
}catch{$r.Error=$_.Exception.Message;$r.Stack=$_.ScriptStackTrace}
finally{$r.FinishedUtc=[datetime]::UtcNow.ToString('o');[IO.File]::WriteAllText((Join-Path $out 'Captures-Result.json'),($r|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
if(-not $r.Passed){exit 1}
