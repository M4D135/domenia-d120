param([switch]$Interactive)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live';$out=Join-Path $root 'critical-out'
$task='Domenia-RC11717-Critical-UI-Resume'
if(-not $Interactive -and (Test-Path (Join-Path $out 'InteractiveResume.json'))){Copy-Item (Join-Path $out 'InteractiveResume.json') (Join-Path $out 'InteractiveResumeAttempt1.json') -Force}
if(-not $Interactive){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'No interactive Windows user'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Interactive')
 $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
 Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 4)) -Force|Out-Null
 Start-ScheduledTask -TaskName $task;Write-Output 'Interactive UI dispatched';exit 0
}
[void][IO.Directory]::CreateDirectory($out)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type 'using System;using System.Runtime.InteropServices;public static class RC17Window{[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);}'
$result=[ordered]@{Build='RC1.17.17';Passed=$false;SessionId=(Get-Process -Id $PID).SessionId;WindowsLoginInvoked=$false;Steps=@();AppId=0}
function Find-Control($Id){return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id))}
function Save-View($Name){
 $app.Refresh();$script:window=[Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
 [void][RC17Window]::SetForegroundWindow($app.MainWindowHandle);Start-Sleep -Milliseconds 500
 $rect=$script:window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$rect.Width,[int]$rect.Height);$g=[Drawing.Graphics]::FromImage($bitmap)
 try{$g.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $out ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()}
 $items=@();foreach($c in $script:window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)){
  if(-not $c.Current.IsPassword -and -not $c.Current.IsOffscreen -and ($c.Current.AutomationId -or $c.Current.ControlType.ProgrammaticName -in @('ControlType.Button','ControlType.TabItem'))){$items+=@([pscustomobject]@{Id=$c.Current.AutomationId;Name=$c.Current.Name;Type=$c.Current.ControlType.ProgrammaticName;Enabled=$c.Current.IsEnabled;Bounds=$c.Current.BoundingRectangle.ToString()})}
 }
 [IO.File]::WriteAllText((Join-Path $out ($Name+'.json')),($items|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
 $result.Steps+=@($Name)
}
$app=$null
try{
 if($result.SessionId -le 0){throw 'Interactive session required'}
 $hash=(Get-FileHash "$root\Domenia_PROD.zip" -Algorithm SHA256).Hash
 if($hash -ine '0393c1b7fd23e732209d3f96c4c91196afcb57ba26f02e86d79bbbc7eb4e908a'){throw 'Wrong PROD zip'}
 $prior=Get-Content (Join-Path $out 'InteractiveUI.json') -Raw|ConvertFrom-Json
 $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$prior.AppId)
 if(-not $process -or $process.CommandLine -notlike ('*'+$root+'\prod\*')){throw 'Prior app is not running from exact PROD directory'}
 $app=Get-Process -Id $prior.AppId;$result.AppId=$app.Id;$result.WindowsLoginInvoked=$prior.WindowsLoginInvoked
 $result.ContinuationOf='InteractiveUI.json';$result.DateUtc=[datetime]::UtcNow.ToString('o')
 Start-Sleep -Seconds 2;Save-View 'Home'
 foreach($id in @('WsSearch','TabApplicationTools','TabDashboard')){
  $c=Find-Control $id;if(-not $c -or -not $c.Current.IsEnabled){throw ('Control unavailable '+$id)}
  ([Windows.Automation.InvokePattern]$c.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke();Start-Sleep -Milliseconds 900;Save-View $id
 }
 $result.Title=$app.MainWindowTitle;$result.Passed=$true
}catch{$result.Error=$_.Exception.Message;$result.Passed=$false}
finally{[IO.File]::WriteAllText((Join-Path $out 'InteractiveResume.json'),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
if(-not $result.Passed){exit 1}
