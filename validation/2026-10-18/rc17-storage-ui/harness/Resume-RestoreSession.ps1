param([ValidateSet('Auto','Restore')][string]$Stage='Restore',[switch]$Interactive)
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
try{
 $prior=Get-Content (Join-Path $out 'Restore-Result.json') -Raw|ConvertFrom-Json;Save-Json 'Restore-Attempt.json' $prior
 foreach($p in $prior.PSObject.Properties){if($p.Name -notin @('Error','Stack','FinishedUtc')){$result[$p.Name]=$p.Value}}
 $script:app=Get-Process -Id $result.AppId
 Require ((Get-CimInstance Win32_Process -Filter ('ProcessId='+$result.AppId)).CommandLine -like ('*'+$install+'*')) 'Expected isolated application'
 $ready=$false
 for($i=0;$i -lt 60;$i++){try{Update-Window;$nav=ById 'TabApplicationTools';if($nav -and $nav.Current.IsEnabled){$ready=$true;break}}catch{};Start-Sleep -Milliseconds 500}
 Require $ready 'Main window not available'
 Trace 'Attached to same running recovery session after login-window transition'
  Storage-Page;$c=ById 'LblStorageMaintenance';Require ((ById 'BtnStorageRestore').Current.IsEnabled -and -not (ById 'BtnStorageMove').Current.IsEnabled) 'Recovery controls not restricted to restore'
  Trace 'Recovery UI remains available on corrupt DB'
  # Invoke a modal-producing button on a separate UIA thread so the controller can inspect the native picker.
  $handle=$script:window.Current.NativeWindowHandle;$driver=[powershell]::Create();[void]$driver.AddScript("Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes;`$w=[Windows.Automation.AutomationElement]::FromHandle([intptr]$handle);`$tabs=`$w.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'WorkspaceTabs'));`$page=([Windows.Automation.SelectionPattern]`$tabs.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)).Current.GetSelection()[0];`$c=`$page.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'BtnStorageRestore'));([Windows.Automation.InvokePattern]`$c.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()");$pending=$driver.BeginInvoke()
  Start-Sleep -Seconds 2
  $windows=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$script:app.Id))
  $items=@();foreach($w in $windows){$items+=@([pscustomobject]@{Id=$w.Current.AutomationId;Name=$w.Current.Name;Type=$w.Current.ControlType.ProgrammaticName});foreach($el in $w.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)){if(-not $el.Current.IsPassword -and -not $el.Current.IsOffscreen){$items+=@([pscustomobject]@{Id=$el.Current.AutomationId;Name=$el.Current.Name;Type=$el.Current.ControlType.ProgrammaticName})}}}
  Save-Json 'Restore-FilePicker.json' $items;$result.AwaitingFileSelection=$true;Trace 'Native restore file picker open'
  # The Invoke provider returns on opening the modal. Do not close the application; continuation uses its UI.
}catch{$result.Error=$_.Exception.Message;$result.Stack=$_.ScriptStackTrace;try{if($script:app){Snapshot ($Stage+'-Failure')}}catch{} }
finally{$result.FinishedUtc=[datetime]::UtcNow.ToString('o');Save-Json ($Stage+'-Result.json') $result}
if(-not $result.AwaitingFileSelection){exit 1}
