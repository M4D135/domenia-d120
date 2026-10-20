$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$out=Join-Path $root 'startup38-final'
$r=[ordered]@{Passed=$false;Utc=[datetime]::UtcNow.ToString('o');Steps=@()}
function Save { $r|ConvertTo-Json -Depth 6|Set-Content (Join-Path $out 'Visual.json') -Encoding UTF8 }
try{
 if(Get-Process LogonUI -ErrorAction SilentlyContinue){throw 'Session locked'}
 $state=Get-Content (Join-Path $out 'AfterIdle2-progress.json') -Raw|ConvertFrom-Json
 $app=Get-Process -Id $state.AppId;$app.Refresh()
 if($app.MainWindowTitle -notmatch 'Accueil.*Domenia'){throw 'Unexpected main window'}
 Add-Type -AssemblyName System.Drawing,System.Windows.Forms,UIAutomationClient,UIAutomationTypes
 Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class VisualNative{
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int state);
}
'@
 function Capture($name){
  if(Get-Process LogonUI -ErrorAction SilentlyContinue){throw 'Session locked'}
  $b=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$bitmap=New-Object Drawing.Bitmap($b.Width,$b.Height);$g=[Drawing.Graphics]::FromImage($bitmap)
  try{$g.CopyFromScreen($b.Location,[Drawing.Point]::Empty,$b.Size);$bitmap.Save((Join-Path $out ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()}
  $r.Steps+=@(@{Screenshot=$name+'.png';Width=$b.Width;Height=$b.Height;Utc=[datetime]::UtcNow.ToString('o')});Save
 }
 function Click($id){
  $app.Refresh();$w=[Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
  $c=$w.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,$id))
  if(-not $c -or -not $c.Current.IsEnabled -or $c.Current.IsOffscreen){throw ('Control unavailable: '+$id)}
  ([Windows.Automation.InvokePattern]$c.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()
  $r.Steps+=@(@{Invoked=$id;Utc=[datetime]::UtcNow.ToString('o')});Save
 }
 [void][VisualNative]::SetForegroundWindow($app.MainWindowHandle)
 Capture 'visual-home'
 Click 'BtnUxNavTools';Start-Sleep -Seconds 3;Capture 'visual-tools'
 Click 'BtnUxNavHome';Start-Sleep -Seconds 3;Capture 'visual-home-return'
 [void][VisualNative]::ShowWindow($app.MainWindowHandle,3);Start-Sleep -Seconds 2;Capture 'visual-maximized'
 [void][VisualNative]::ShowWindow($app.MainWindowHandle,9);Start-Sleep -Seconds 2;Capture 'visual-restored'
 $r.Passed=$true
}catch{$r.Error=$_.Exception.Message;$r.Stack=$_.ScriptStackTrace}
finally{Save;if($r.Passed){'done'|Set-Content (Join-Path $out 'release-visual.flag')}}
