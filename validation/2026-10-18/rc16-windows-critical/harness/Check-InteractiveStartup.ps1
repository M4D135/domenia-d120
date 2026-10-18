param([switch]$Interactive)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11716-critical'
$out=Join-Path $root 'out'
$task='Domenia-RC11716-Critical-Startup'
if(-not $Interactive){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName
 if(-not $user){throw 'No interactive Windows user'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Interactive')
 $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
 $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
 Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force|Out-Null
 Start-ScheduledTask -TaskName $task
 Write-Output 'Interactive startup check dispatched';exit 0
}
$app=$null;$launcher=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
$result=[ordered]@{Build='RC1.17.16';Passed=$false;SessionId=(Get-Process -Id $PID).SessionId;PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Exact PROD launcher, visible login only. No credentials submitted; no AD authentication.'}
try{
 if($result.SessionId -le 0){throw 'Interactive session required'}
 $result.ProdZipSha256=(Get-FileHash (Join-Path $root 'Domenia_PROD.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
 if($result.ProdZipSha256 -ne 'fdfd170c74823f318731e581fec7504dd47a0363933d10aa5fc0366361e95f2a'){throw 'Wrong PROD archive'}
 Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
 Add-Type 'using System;using System.Runtime.InteropServices;public static class RC16StartupWindow{[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);}'
 $launcher=Start-Process -FilePath (Join-Path $root 'prod\Domenia.exe') -WorkingDirectory (Join-Path $root 'prod') -PassThru
 $login=$null;$password=$null
 while($watch.Elapsed.TotalSeconds -lt 75){
  if(-not $app){$child=Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$launcher.Id)|Where-Object Name -eq 'powershell.exe'|Select-Object -First 1;if($child){$app=Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue}}
  if($app){
   $app.Refresh()
   if($app.HasExited){throw ('Application exited: '+$app.ExitCode)}
   if($app.MainWindowHandle -ne 0){
    $window=[Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
    $login=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'BtnLogin'))
    if($login){
     $other=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'BtnLoginOtherAccount'))
     if($other -and -not $other.Current.IsOffscreen){([Windows.Automation.InvokePattern]$other.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke();Start-Sleep -Milliseconds 400}
     $password=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::IsPasswordProperty,$true))
     if($password){break}
    }
   }
  }
  Start-Sleep -Milliseconds 700
 }
 $result.Title=$(if($app){$app.MainWindowTitle}else{''})
 $result.LoginButtonFound=($null -ne $login);$result.PasswordControlFound=($null -ne $password)
 $result.Passed=($null -ne $login -and $null -ne $password -and $result.Title -like '*Connexion*' -and -not $window.Current.IsOffscreen)
 if($app -and $app.MainWindowHandle -ne 0){
  [void][RC16StartupWindow]::SetForegroundWindow($app.MainWindowHandle);Start-Sleep -Milliseconds 400
  $rect=$window.Current.BoundingRectangle
  $bitmap=[Drawing.Bitmap]::new([int]$rect.Width,[int]$rect.Height);$g=[Drawing.Graphics]::FromImage($bitmap)
  try{$g.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $out 'login.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()}
 }
 if(-not $result.Passed){throw 'Login window not confirmed'}
}catch{$result.Error=$_.Exception.Message;$result.Passed=$false}
finally{
 $result.DurationMs=$watch.ElapsedMilliseconds
 if($app){try{[void]$app.CloseMainWindow();if(-not $app.WaitForExit(8000)){Stop-Process -Id $app.Id -Force}}catch{}}
 [IO.File]::WriteAllText((Join-Path $out 'InteractiveStartup.json'),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
}
if(-not $result.Passed){exit 1}
