param([string]$Stage='RestoreFinish',[switch]$Interactive)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11717-live';$install=Join-Path $root 'storage-ui-prod';$out=Join-Path $root 'storage-ui-out';$task='Domenia-RC17-Storage-'+$Stage
[void][IO.Directory]::CreateDirectory($out)
function Save-Json($name,$data){[IO.File]::WriteAllText((Join-Path $out $name),($data|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
if(-not $Interactive){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'Interactive Windows session required'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Stage '+$Stage+' -Interactive')
 Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 8)) -Force|Out-Null
 Start-ScheduledTask -TaskName $task;Write-Output ('Dispatched '+$Stage);exit
}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
$result=[ordered]@{Build='RC1.17.17';Stage=$Stage;Passed=$false;StartedUtc=[datetime]::UtcNow.ToString('o');Session=(Get-Process -Id $PID).SessionId;PSVersion=$PSVersionTable.PSVersion.ToString();Steps=@();AppId=0}
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
 try{$g.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bmp.Size);$bmp.Save((Join-Path $out ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bmp.Dispose()}
 $items=@();foreach($c in $script:window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)){if(-not $c.Current.IsPassword -and -not $c.Current.IsOffscreen -and ($c.Current.AutomationId -or $c.Current.ControlType.ProgrammaticName -in @('ControlType.Button','ControlType.Window','ControlType.Edit'))){$items+=@([pscustomobject]@{Id=$c.Current.AutomationId;Name=$c.Current.Name;Type=$c.Current.ControlType.ProgrammaticName;Enabled=$c.Current.IsEnabled})}}
 Save-Json ($name+'.json') $items
}
function Start-App{
 $launcher=Start-Process (Join-Path $install 'Domenia.exe') -WorkingDirectory $install -PassThru
 $sw=[Diagnostics.Stopwatch]::StartNew();$loginInvoked=$false;$script:app=$null
 while($sw.Elapsed.TotalSeconds -lt 150){
  if(-not $script:app){$child=Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$launcher.Id)|Where-Object Name -eq 'powershell.exe'|Select-Object -First 1;if($child){$script:app=Get-Process -Id $child.ProcessId;$result.AppId=$script:app.Id}}
  if($script:app){$script:app.Refresh();Require (-not $script:app.HasExited) 'App exited during startup';if($script:app.MainWindowHandle -ne 0){Update-Window;$nav=ById 'TabDashboard';if($nav -and -not $nav.Current.IsOffscreen){Trace 'Authenticated main window visible';return};$login=ById 'BtnWindowsLogin';if($login -and $login.Current.IsEnabled -and -not $login.Current.IsOffscreen -and -not $loginInvoked){Click 'BtnWindowsLogin';$loginInvoked=$true;Trace 'Windows account login invoked'}}}
  Start-Sleep -Milliseconds 700
 }
 throw 'Main window not reached in 150 seconds'
}
function Stop-App{if($script:app){Update-Window;([Windows.Automation.WindowPattern]$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern)).Close();Require ($script:app.WaitForExit(15000)) 'App did not close normally'}}
function Storage-Page{Click 'TabApplicationTools';Start-Sleep -Milliseconds 700;Select-Tab 'TabIndexStorage';Snapshot ($Stage+'-Storage')}
# Load native SQLite helper functions only for independent fixture preparation/readback.
$wad=Join-Path $root 'prod\wad';$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','Invoke-DomeniaDbQuery','Invoke-DomeniaDbExec')){$fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));Require ($fn.Count -eq 1) ('Missing helper '+$name);. ([scriptblock]::Create($fn[0].Extent.Text))}
[void](Initialize-DomeniaWinSqliteNative)
function Open-DomeniaDatabase {param($Path,[switch]$ReadOnly);$h=[IntPtr]::Zero;$flags=6;if($ReadOnly){$flags=1};$ptr=New-DomeniaUtf8Ptr $Path;try{$rc=[Domenia.WinSqliteNative]::sqlite3_open_v2($ptr,[ref]$h,$flags,[IntPtr]::Zero)}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)};if($rc -ne 0){throw ('SQLite open '+$rc)};[void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($h,5000);return $h}
function Write-DomeniaSwallowed {param($Category,$Operation,$ErrorRecord)}
function Close-DomeniaDatabase($h){if($h -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_close($h)}}
function Query($path,$sql,[switch]$Write){$h=Open-DomeniaDatabase $path -ReadOnly:(-not $Write);try{if($Write){[void](Invoke-DomeniaDbExec $sql $h)}else{return @(Invoke-DomeniaDbQuery $sql $h)}}finally{Close-DomeniaDatabase $h}}

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

function Async-Invoke($element){
 $handle=$element.Current.NativeWindowHandle
 # Native dialog buttons expose stable HWNDs; Invoke can wait for the next modal, so use another runspace.
 Require ($handle -ne 0) 'Native button HWND unavailable'
 $p=[powershell]::Create();[void]$p.AddScript("Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes;`$e=[Windows.Automation.AutomationElement]::FromHandle([intptr]$handle);([Windows.Automation.InvokePattern]`$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()")
 [void]$p.BeginInvoke();$script:drivers+=@($p)
}
function Wait-Dialog($title){for($i=0;$i -lt 40;$i++){Update-Window;$d=ByName $title;if($d){return $d};Start-Sleep -Milliseconds 250};throw ('Dialog absent: '+$title)}
function Fill-File($dialog,$path){
 $field=ById '1148' $dialog
 Require ($null -ne $field) ('File name control unavailable in '+$dialog.Current.ControlType.ProgrammaticName+' '+$dialog.Current.Name)
 $value=$null
 if(-not $field.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$value)){
  $field=$field.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Edit))
  Require ($null -ne $field) 'File name child edit absent'
  $value=$field.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
 }
 ([Windows.Automation.ValuePattern]$value).SetValue($path)
 $button=ById '1' $dialog;Require ($button -and $button.Current.IsEnabled -and $button.Current.ControlType -eq [Windows.Automation.ControlType]::Button) 'File confirmation unavailable'
 Async-Invoke $button
}
$script:drivers=@()
try{
 if(Test-Path (Join-Path $out 'RestoreFinish-Result.json')){Copy-Item (Join-Path $out 'RestoreFinish-Result.json') (Join-Path $out 'RestoreFinish-Attempt.json')}
 $prior=Get-Content (Join-Path $out 'Restore-Result.json') -Raw|ConvertFrom-Json
 Require $prior.AwaitingFileSelection 'No prepared restore session'
 foreach($p in $prior.PSObject.Properties){if($p.Name -notin @('Error','Stack','FinishedUtc')){$result[$p.Name]=$p.Value}}
 $auto=Get-Content (Join-Path $out 'Auto-Result.json') -Raw|ConvertFrom-Json
 $script:app=Get-Process -Id $result.AppId
 Require ((Get-CimInstance Win32_Process -Filter ('ProcessId='+$result.AppId)).CommandLine -like ('*'+$install+'*')) 'Expected isolated application'
 Require (-not (Test-Path $result.Target)) 'Restore target must be new'
 $dialogs=@([StorageDialogs]::Windows([uint32]$result.AppId)|Where-Object {[StorageDialogs]::Class($_) -eq '#32770' -and [StorageDialogs]::Text($_).StartsWith('Choisir le nouveau fichier')})
 Require ($dialogs.Count -eq 1) 'Expected existing destination dialog'
 $children=[StorageDialogs]::Children($dialogs[0]);$edit=@($children|Where-Object {[StorageDialogs]::Class($_) -eq 'Edit' -and [StorageDialogs]::GetDlgCtrlID($_) -eq 1001});$save=@($children|Where-Object {[StorageDialogs]::Class($_) -eq 'Button' -and [StorageDialogs]::GetDlgCtrlID($_) -eq 1})
 Require ($edit.Count -eq 1 -and $save.Count -eq 1) 'Expected native file controls'
 $reply=[IntPtr]::Zero;$sent=[StorageDialogs]::SendMessageTimeout($edit[0],12,[IntPtr]::Zero,[string]$result.Target,2,2000,[ref]$reply)
 Require ($sent -ne [IntPtr]::Zero) 'Native filename edit timed out'
 Require ([StorageDialogs]::PostMessage($save[0],245,[IntPtr]::Zero,[IntPtr]::Zero)) 'Native Save button failed'
 Trace 'Source backup selected through UIA; new destination confirmed through native dialog controls'
 Start-Sleep -Seconds 2
 $confirm=$null
 for($i=0;$i -lt 100;$i++){Start-Sleep -Milliseconds 500;Update-Window;$confirm=ById 'BtnInlineRequestConfirm';if($confirm -and $confirm.Current.IsEnabled -and -not $confirm.Current.IsOffscreen){break}}
 Require ($confirm -and $confirm.Current.IsEnabled -and -not $confirm.Current.IsOffscreen) 'Restore preview confirmation unavailable'
 $message=ById 'LblInlineRequestMessage';$preview=[string]$message.Current.Name
 Require ($preview.Contains([IO.Path]::GetFileName($result.Backup)) -and $preview.Contains([IO.Path]::GetFileName($result.Target))) 'Preview did not identify source and destination'
 $result.Preview=$preview;Snapshot 'Restore-Preview'
 Click 'BtnInlineRequestConfirm';Trace 'Verified preview confirmed through UI'
 $selected=$false
 for($i=0;$i -lt 120;$i++){
  Start-Sleep -Milliseconds 500
  $settings=Get-Content $auto.Settings -Raw|ConvertFrom-Json
  $choice=@($settings.PSObject.Properties|Where-Object {$_.Name -like 'Storage.Database.*' -and [string]$_.Value -ieq [string]$result.Target})
  if($choice.Count -and (Test-Path $result.Target)){$selected=$true;break}
 }
 Require $selected 'Restored DB not selected durably'
 Require ((Query $result.Target 'PRAGMA quick_check;')[0].quick_check -eq 'ok') 'Restored integrity failed'
 Require ((Query $result.Target 'SELECT value FROM qualification_marker;')[0].value -eq $auto.Marker) 'Restored marker missing'
 Require ((Get-FileHash $result.CorruptPath -Algorithm SHA256).Hash -eq $result.CorruptSha256) 'Corrupt original modified'
 Require ((Get-FileHash $result.Backup -Algorithm SHA256).Hash -eq $auto.BackupSha256) 'Source backup modified'
 Update-Window;Require ((ById 'BtnStorageMove').Current.IsEnabled) 'Recovery lock not released'
 Snapshot 'Restore-Success';Stop-App
 Copy-Item $result.Backup (Join-Path $out 'verified-automatic-backup.db')
 $h=Open-DomeniaDatabase $result.Target
 try{$cp=@(Invoke-DomeniaDbQuery 'PRAGMA wal_checkpoint(TRUNCATE);' $h);Require ($cp[0].busy -eq 0) 'Restored fixture checkpoint busy'}finally{Close-DomeniaDatabase $h}
 Copy-Item $result.Target (Join-Path $out 'verified-restored.db')
 $result.RestoredSha256=(Get-FileHash (Join-Path $out 'verified-restored.db') -Algorithm SHA256).Hash
 $result.DurablePreference=$choice[0].Name;$result.RestoredMarker=$auto.Marker;$result.QuickCheck='ok';$result.CorruptOriginalPreserved=$true;$result.SourceBackupPreserved=$true;$result.RecoveryLockReleased=$true
 $result.AwaitingFileSelection=$false;Trace 'Restore verified, preference persisted, original preserved and isolated application closed normally';$result.Passed=$true
}catch{$result.Error=$_.Exception.Message;$result.Stack=$_.ScriptStackTrace;try{if($script:app){Snapshot ($Stage+'-Failure')}}catch{} }
finally{$result.FinishedUtc=[datetime]::UtcNow.ToString('o');Save-Json ($Stage+'-Result.json') $result}
if(-not $result.Passed){exit 1}
