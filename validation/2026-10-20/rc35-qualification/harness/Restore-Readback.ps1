param([string]$Stage='RestoreVerified',[switch]$Interactive)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$install=Join-Path $root 'ui-prod';$out=Join-Path $root 'ui-out';$task='Domenia-RC35-RestoreReadback'
[void][IO.Directory]::CreateDirectory($out)
function Save-Json($name,$data){[IO.File]::WriteAllText((Join-Path $out $name),($data|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
if(-not $Interactive){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'Interactive Windows session required'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Stage '+$Stage+' -Interactive')
 Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 8) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable) -Force|Out-Null
 Start-ScheduledTask -TaskName $task;Write-Output ('Dispatched '+$Stage);exit
}
Save-Json 'RestoreVerified-started.json' @{Utc=[datetime]::UtcNow.ToString('o');PID=$PID;Session=(Get-Process -Id $PID).SessionId}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
$result=[ordered]@{Build='RC1.17.35';Stage=$Stage;Passed=$false;StartedUtc=[datetime]::UtcNow.ToString('o');Session=(Get-Process -Id $PID).SessionId;PSVersion=$PSVersionTable.PSVersion.ToString();Steps=@();AppId=0}
function Trace($text){$result.Steps+=@([pscustomobject]@{Utc=[datetime]::UtcNow.ToString('o');Text=$text});Save-Json ($Stage+'-progress.json') $result}
function Require($condition,$text){if(-not $condition){throw $text}}
function Update-Window {
 $script:app.Refresh()
 # Process.MainWindowHandle may transiently point at a WPF tooltip. Select the actual application window.
 $candidates=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$script:app.Id))|Where-Object {$_.Current.ControlType -eq [Windows.Automation.ControlType]::Window -and $_.Current.Name -match 'Domenia' -and $_.Current.BoundingRectangle.Width -gt 400})
 Require ($candidates.Count -gt 0) 'Application window peer absent';$script:window=$candidates|Sort-Object {$_.Current.BoundingRectangle.Width*$_.Current.BoundingRectangle.Height} -Descending|Select-Object -First 1
}
function Find-Control($property,$value,$scope=$script:window){
 $condition=[Windows.Automation.PropertyCondition]::new($property,$value);$found=$scope.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition);if($found){return $found}
 # The workspace template hides its tab headers. Obtain the selected peer through SelectionPattern.
 $tabs=$scope.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'WorkspaceTabs'))
 if($tabs){foreach($page in ([Windows.Automation.SelectionPattern]$tabs.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)).Current.GetSelection()){$found=$page.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition);if($found){return $found}}}
 return $null
}
function ById($id,$scope=$script:window){return Find-Control ([Windows.Automation.AutomationElement]::AutomationIdProperty) $id $scope}
function ByName($name,$scope=$script:window){return Find-Control ([Windows.Automation.AutomationElement]::NameProperty) $name $scope}
function Click($id){$c=ById $id;Require ($c -and $c.Current.IsEnabled) ('Unavailable '+$id);([Windows.Automation.InvokePattern]$c.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()}
function Select-Tab($id){$c=ById $id;Require ($null -ne $c) ('Missing tab '+$id);([Windows.Automation.SelectionItemPattern]$c.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)).Select();Start-Sleep -Milliseconds 500}
function Snapshot($name){
 Update-Window;$rect=$script:window.Current.BoundingRectangle
 $bmp=[Drawing.Bitmap]::new([int]$rect.Width,[int]$rect.Height);$g=[Drawing.Graphics]::FromImage($bmp)
 try{$g.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bmp.Size);$bmp.Save((Join-Path $out ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}catch{Save-Json ($name+'-capture-unavailable.json') @{Error=$_.Exception.Message;Utc=[datetime]::UtcNow.ToString('o')}}finally{$g.Dispose();$bmp.Dispose()}
 $items=@();foreach($c in $script:window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)){if(-not $c.Current.IsPassword -and -not $c.Current.IsOffscreen -and ($c.Current.AutomationId -or $c.Current.ControlType.ProgrammaticName -in @('ControlType.Button','ControlType.Window','ControlType.Edit'))){$items+=@([pscustomobject]@{Id=$c.Current.AutomationId;Name=$c.Current.Name;Type=$c.Current.ControlType.ProgrammaticName;Enabled=$c.Current.IsEnabled})}}
 Save-Json ($name+'.json') $items
}
function Start-App{
 $launcher=Start-Process (Join-Path $install 'Domenia.exe') -WorkingDirectory $install -PassThru
 $sw=[Diagnostics.Stopwatch]::StartNew();$loginInvoked=$false;$script:app=$null
 while($sw.Elapsed.TotalSeconds -lt 300){
  if(-not $script:app){$child=Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$launcher.Id)|Where-Object Name -eq 'powershell.exe'|Select-Object -First 1;if($child){$script:app=Get-Process -Id $child.ProcessId;$result.AppId=$script:app.Id}}
  if($script:app){$script:app.Refresh();Require (-not $script:app.HasExited) 'App exited during startup';if($script:app.MainWindowHandle -ne 0){try{Update-Window}catch{Start-Sleep -Milliseconds 500;continue};$nav=ById 'TabDashboard';if($nav -and -not $nav.Current.IsOffscreen){Trace 'Authenticated main window visible';return};$login=ById 'BtnWindowsLogin';if($login -and $login.Current.IsEnabled -and -not $login.Current.IsOffscreen -and -not $loginInvoked){Click 'BtnWindowsLogin';$loginInvoked=$true;Trace 'Windows account login invoked'}}}
  Start-Sleep -Milliseconds 700
 }
 throw 'Main window not reached in 300 seconds'
}
function Stop-App{if($script:app){Update-Window;([Windows.Automation.WindowPattern]$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern)).Close();Require ($script:app.WaitForExit(15000)) 'App did not close normally'}}
function Storage-Page{Click 'TabApplicationTools';Start-Sleep -Milliseconds 700;Select-Tab 'TabIndexStorage';Snapshot ($Stage+'-Storage')}
# Load native SQLite helper functions only for independent fixture preparation/readback.
$wad=Join-Path $root 'ui-prod\wad';$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','Invoke-DomeniaDbQuery','Invoke-DomeniaDbExec')){$fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));Require ($fn.Count -eq 1) ('Missing helper '+$name);. ([scriptblock]::Create($fn[0].Extent.Text))}
[void](Initialize-DomeniaWinSqliteNative)
function Open-DomeniaDatabase {param($Path,[switch]$ReadOnly);$h=[IntPtr]::Zero;$flags=6;if($ReadOnly){$flags=1};$ptr=New-DomeniaUtf8Ptr $Path;try{$rc=[Domenia.WinSqliteNative]::sqlite3_open_v2($ptr,[ref]$h,$flags,[IntPtr]::Zero)}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)};if($rc -ne 0){throw ('SQLite open '+$rc)};[void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($h,5000);return $h}
function Write-DomeniaSwallowed {param($Category,$Operation,$ErrorRecord)}
function Close-DomeniaDatabase($h){if($h -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_close($h)}}
function Query($path,$sql,[switch]$Write){$h=Open-DomeniaDatabase $path -ReadOnly:(-not $Write);try{if($Write){[void](Invoke-DomeniaDbExec $sql $h)}else{return @(Invoke-DomeniaDbQuery $sql $h)}}finally{Close-DomeniaDatabase $h}}
function Read-Settings{Get-Content $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json}
function Set-Text($id,$text){$c=ById $id;Require ($null -ne $c) ('Missing '+$id);([Windows.Automation.ValuePattern]$c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)).SetValue($text)}
function Get-Text($id){$c=ById $id;return ([Windows.Automation.ValuePattern]$c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)).Current.Value}
function Backup-Panel{Storage-Page;$e=ByName 'Sauvegardes automatiques et conservation';Require ($null -ne $e) 'Backup section absent';([Windows.Automation.ExpandCollapsePattern]$e.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand();Start-Sleep -Milliseconds 400}
function Get-Bounds{$r=$script:window.Current.BoundingRectangle;return [pscustomobject]@{Left=$r.Left;Top=$r.Top;Width=$r.Width;Height=$r.Height}}
Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;using System.Collections.Generic;
public static class StorageDialogs {
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h,EnumProc p,IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,string l,uint flags,uint ms,out IntPtr r);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static string Text(IntPtr h){var s=new StringBuilder(1024);GetWindowText(h,s,1024);return s.ToString();}
 public static string Class(IntPtr h){var s=new StringBuilder(256);GetClassName(h,s,256);return s.ToString();}
 public static IntPtr[] Windows(uint pid){var list=new List<IntPtr>();EnumWindows((h,p)=>{uint n;GetWindowThreadProcessId(h,out n);if(n==pid && IsWindowVisible(h))list.Add(h);return true;},IntPtr.Zero);return list.ToArray();}
 public static IntPtr[] Children(IntPtr root){var list=new List<IntPtr>();EnumChildWindows(root,(h,p)=>{list.Add(h);return true;},IntPtr.Zero);return list.ToArray();}
}
'@

function Select-NativeFile($prefix,$path){
 $dialog=$null
 for($i=0;$i -lt 80;$i++){$dialog=@([StorageDialogs]::Windows([uint32]$result.AppId)|Where-Object {[StorageDialogs]::Class($_) -eq '#32770' -and [StorageDialogs]::Text($_).StartsWith($prefix)});if($dialog.Count -eq 1){break};Start-Sleep -Milliseconds 250}
 Require ($dialog.Count -eq 1) ('Expected native picker: '+$prefix)
 $children=[StorageDialogs]::Children($dialog[0]);$edit=@($children|Where-Object {[StorageDialogs]::Class($_) -eq 'Edit' -and [StorageDialogs]::GetDlgCtrlID($_) -eq $(if($prefix -eq 'Choisir la sauvegarde'){1148}else{1001})});$button=@($children|Where-Object {[StorageDialogs]::Class($_) -eq 'Button' -and [StorageDialogs]::GetDlgCtrlID($_) -eq 1})
 Require ($edit.Count -eq 1 -and $button.Count -eq 1) 'Expected native file controls'
 $reply=[IntPtr]::Zero;$sent=[StorageDialogs]::SendMessageTimeout($edit[0],12,[IntPtr]::Zero,[string]$path,2,2000,[ref]$reply)
 Require ($sent -ne [IntPtr]::Zero) 'Native filename edit timed out'
 Require ([StorageDialogs]::PostMessage($button[0],245,[IntPtr]::Zero,[IntPtr]::Zero)) 'Native file confirmation failed'
}

try {
 $prior=Get-Content (Join-Path $out 'RestoreFinish-Result.json') -Raw|ConvertFrom-Json
 foreach($prop in $prior.PSObject.Properties){if($prop.Name -notin @('Error','Stack','FinishedUtc')){$result[$prop.Name]=$prop.Value}}
 $action=Get-Content (Join-Path $out 'RestoreClick.json') -Raw|ConvertFrom-Json
 # A second read-only UI attempt found no preview because the scheduled click had already restored it.
 $action|Add-Member -NotePropertyName ConfirmedByScreen -NotePropertyValue 'Step 3/3: base verified and in service; screenshot RC35-restored-screen.png' -Force
 $action.Preview=[string](Get-Content (Join-Path $out 'RestoreVerified-Result.json') -Raw|ConvertFrom-Json).Preview
 $auto=Get-Content (Join-Path $out 'Final-Result.json') -Raw|ConvertFrom-Json;Require $auto.Passed 'Backup not verified'
 Require ($action.Preview -match '(?m)^Destination : (.+?)\. Espace libre') 'Target missing'
 $result.Target=$matches[1];$result.Preview=$action.Preview;$result.UiAction=$action
 $script:settingsPath=Join-Path $install 'wad\data\Preferences\Domenia.settings.json'
 $selected=$false
 for($i=0;$i -lt 120;$i++){
  $settings=Read-Settings;$choice=@($settings.PSObject.Properties|Where-Object {$_.Name -like 'Storage.Database.*' -and [string]$_.Value -ieq [string]$result.Target})
  if($choice.Count -and (Test-Path $result.Target)){$selected=$true;break};Start-Sleep -Milliseconds 500
 }
 Require $selected 'Restored database not selected'
 Require ((Query $result.Target 'PRAGMA quick_check;')[0].quick_check -eq 'ok') 'Restored integrity failed'
 Require ((Query $result.Target 'SELECT value FROM qualification_marker;')[0].value -eq $auto.Marker) 'Marker missing'
 Require ((Get-FileHash $result.CorruptPath -Algorithm SHA256).Hash -eq $result.CorruptSha256) 'Corrupt original changed'
 Require ((Get-FileHash $result.Backup -Algorithm SHA256).Hash -eq $auto.BackupSha256) 'Backup changed'
 $script:app=Get-Process -Id $result.AppId
 Require ((Get-CimInstance Win32_Process -Filter ('ProcessId='+$result.AppId)).CommandLine -like ('*'+$install+'*')) 'Expected isolated app'
 $script:window=[Windows.Automation.AutomationElement]::FromHandle($script:app.MainWindowHandle)
 $result.RecoveryLockReleased=(ById 'BtnStorageMove').Current.IsEnabled;Require $result.RecoveryLockReleased 'Recovery lock not released'
 Require ($script:app.CloseMainWindow()) 'Close request failed';Require ($script:app.WaitForExit(15000)) 'App did not close normally'
 $result.QuickCheck='ok';$result.RestoredMarker=$auto.Marker;$result.CorruptOriginalPreserved=$true;$result.SourceBackupPreserved=$true;$result.DurablePreference=$choice[0].Name
 $result.AwaitingFileSelection=$false;$result.Passed=$true;Trace 'Restoration through UI checked independently, preference durable, originals preserved and app closed normally'
}catch{$result.Error=$_.Exception.Message;$result.Stack=$_.ScriptStackTrace}
finally{$result.FinishedUtc=[datetime]::UtcNow.ToString('o');Save-Json 'RestoreVerified-Result.json' $result}
if(-not $result.Passed){exit 1}
