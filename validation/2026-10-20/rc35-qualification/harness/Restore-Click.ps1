param([switch]$Interactive)
$root='C:\DomeniaLab\RC35-qualification';$out=Join-Path $root 'ui-out'
if(-not $Interactive){
 foreach($name in @('Domenia-RC35-RestoreVerified','Domenia-RC35-RestoreNow')){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue}
 $a=New-ScheduledTaskAction -Execute "$PSHOME\powershell.exe" -Argument ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Interactive')
 Register-ScheduledTask -TaskName 'Domenia-RC35-RestoreClick' -Action $a -Principal (New-ScheduledTaskPrincipal -UserId 'CNAMTS\Administrateur' -LogonType Interactive) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force|Out-Null
 Start-ScheduledTask -TaskName 'Domenia-RC35-RestoreClick';exit
}
$ErrorActionPreference='Stop';$r=[ordered]@{StartedUtc=[datetime]::UtcNow.ToString('o');Passed=$false;Steps=@()}
function Trace($s){$r.Steps+=@($s);$r|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'RestoreClick.json') -Encoding UTF8}
try{
 Trace 'Started';Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
 $p=Get-Process -Id 3624;Trace 'Process found'
 $w=[Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle);Trace 'Window peer found'
 $id=[Windows.Automation.AutomationElement]::AutomationIdProperty
 $msg=$w.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new($id,'LblInlineRequestMessage'))
 $r.Preview=$msg.Current.Name
 if($r.Preview -notmatch 'Domenia-20261020-135629-908-cfe616c3.db' -or $r.Preview -notmatch 'Domenia-20261020-140219.db'){throw 'Unexpected restore preview'}
 Trace 'Preview checked'
 $b=$w.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new($id,'BtnInlineRequestConfirm'))
 ([Windows.Automation.InvokePattern]$b.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()
 $r.Passed=$true;Trace 'Restore confirmed through the actual UI'
}catch{$r.Error=$_.Exception.Message;Trace 'Failed'}
