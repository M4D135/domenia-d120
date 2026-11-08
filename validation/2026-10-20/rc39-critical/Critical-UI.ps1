param([string]$Stage='CriticalUI',[switch]$Interactive)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\RC35-qualification';$install=Join-Path $root 'RC39-critical-ui\prod';$out=Join-Path $root 'rc39-ui';$task='Domenia-RC39-'+$Stage
[void][IO.Directory]::CreateDirectory($out)
function Save-Json($name,$data){[IO.File]::WriteAllText((Join-Path $out $name),($data|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
if(-not $Interactive){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'Interactive Windows session required'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Stage '+$Stage+' -Interactive')
 Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -Priority 4 -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force|Out-Null
 Start-ScheduledTask -TaskName $task;Write-Output ('Dispatched '+$Stage);exit
}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
$result=[ordered]@{Build='RC1.17.39';Stage=$Stage;Passed=$false;StartedUtc=[datetime]::UtcNow.ToString('o');Session=(Get-Process -Id $PID).SessionId;PSVersion=$PSVersionTable.PSVersion.ToString();Steps=@();AppId=0}
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
$wad=Join-Path $install 'wad';$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
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

$drivers=[Collections.Generic.List[object]]::new()
function Click-Async($id){
 $handle=$script:window.Current.NativeWindowHandle
 $p=[powershell]::Create()
 [void]$p.AddScript("Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes;`$w=[Windows.Automation.AutomationElement]::FromHandle([intptr]$handle);`$cond=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'$id');`$c=`$w.FindFirst([Windows.Automation.TreeScope]::Descendants,`$cond);if(-not `$c){`$tabs=`$w.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'WorkspaceTabs'));`$page=([Windows.Automation.SelectionPattern]`$tabs.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)).Current.GetSelection()[0];`$c=`$page.FindFirst([Windows.Automation.TreeScope]::Descendants,`$cond)};([Windows.Automation.InvokePattern]`$c.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()")
 [void]$p.BeginInvoke();$drivers.Add($p)
}
function Label($id){$c=ById $id;if(-not $c){return ''};$p=$null;if($c.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern,[ref]$p)){return $p.DocumentRange.GetText(-1)};return $c.Current.Name}
function Wait-Control($id,[int]$seconds=45){$timer=[Diagnostics.Stopwatch]::StartNew();while($timer.Elapsed.TotalSeconds -lt $seconds){Update-Window;$c=ById $id;if($c -and $c.Current.IsEnabled -and -not $c.Current.IsOffscreen){return $c};Start-Sleep -Milliseconds 500};throw ('Control not ready: '+$id)}
try{
 Require (Test-Path (Join-Path $install 'Domenia.exe')) 'RC39 pack not extracted'
 $result.CoreSha256=(Get-FileHash (Join-Path $wad 'Domenia-Core.ps1') -Algorithm SHA256).Hash;$result.ReleaseSha256=(Get-FileHash (Join-Path $wad 'Domenia.release.json') -Algorithm SHA256).Hash
 $script:settingsPath=Join-Path $install 'wad\data\Preferences\Domenia.settings.json'
 $dn='OU=Domain Controllers,DC=cnamts,DC=local'
 Start-App;Click 'TabDashboard';Start-Sleep -Seconds 1
 $databases=@(Get-ChildItem (Join-Path $install 'wad\data') -Recurse -Filter '*.db' -File)
 Require ($databases.Count -eq 1) 'Isolated domain database not unique'
 $db=$databases[0].FullName;$result.Database=$db
 Snapshot 'BroadUI-Home'
 Require ((Label 'LblFirstStepOuMark') -eq '2') 'Expected untouched OU step'
 Require ((Query $db "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine';")[0].n -eq 0) 'Expected empty qualification index'
 Click-Async 'BtnFirstStepOu';[void](Wait-Control 'EmbeddedObjectTerm')
 Set-Text 'EmbeddedObjectTerm' 'Domain Controllers';Click 'EmbeddedObjectSearch'
 $item=$null
 for($i=0;$i -lt 80;$i++){
  Start-Sleep -Milliseconds 500;Update-Window;$tree=ById 'EmbeddedObjectResults'
  if($tree){$item=@($tree.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::TreeItem))|Where-Object {$_.Current.Name -match 'Domain Controllers'})|Select-Object -First 1;if($item){break}}
 }
 Require ($null -ne $item) 'Target OU not found in picker'
 ([Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)).Select()
 [void](Wait-Control 'EmbeddedObjectAccept');Require ((Get-Text 'EmbeddedOuPath') -ieq $dn) 'Wrong OU selection'
 Click 'EmbeddedObjectAccept'
 for($i=0;$i -lt 30;$i++){Start-Sleep -Milliseconds 500;Update-Window;if((Label 'LblFirstStepOuMark') -eq ([string][char]0x2713)){break}}
 Require ((Label 'LblFirstStepOuMark') -eq ([string][char]0x2713)) 'OU mark not updated immediately'
 Require ((Label 'LblFirstStepBaseMark') -eq '3') 'Unread OU incorrectly marked complete'
 Require ((Query $db "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine';")[0].n -eq 0) 'OU selection collected AD objects implicitly'
 Snapshot 'FirstSteps-OU-Selected';Trace 'OU accepted through picker; step 2 checked immediately, index still empty and step 3 pending'
 Click 'BtnFirstStepBase';[void](Wait-Control 'BtnIndexScopeUpdate');Click-Async 'BtnIndexScopeUpdate'
 $confirmed=$false;$complete=$false
 for($i=0;$i -lt 160;$i++){
  Start-Sleep -Milliseconds 500;Update-Window
  $confirm=ById 'BtnInlineRequestConfirm'
  if(-not $confirmed -and $confirm -and $confirm.Current.IsEnabled -and -not $confirm.Current.IsOffscreen){$message=Label 'LblInlineRequestMessage';Require ($message -match 'Domain Controllers') 'AD confirmation does not name selected OU';$result.Confirmation=$message;Click 'BtnInlineRequestConfirm';$confirmed=$true}
  $rows=@(Query $db "SELECT scope,details,last_sync,item_count FROM sync_state WHERE scope LIKE '%domain controllers%';")
  if(@($rows|Where-Object {$_.details -match 'complete'}).Count){$complete=$true;$result.Coverage=$rows;break}
 }
 Require $complete 'Selected OU read did not reach complete SQLite coverage'
 $result.DirectoryRows=@(Query $db "SELECT name,object_guid,distinguished_name FROM ad_objects WHERE object_type='Machine';")
 Require ($result.DirectoryRows.Count -eq 1 -and $result.DirectoryRows[0].name -eq 'DC01' -and $result.DirectoryRows[0].distinguished_name -ieq ('CN=DC01,'+$dn)) 'OU read escaped expected one-computer scope'
 Click 'TabDashboard';[void](Wait-Control 'BtnFirstStepDashboard' 60)
 Require ((Label 'LblFirstStepBaseMark') -eq ([string][char]0x2713)) 'Completed OU still marked unread'
 $result.BeforeDashboard=Label 'LblFirstStepDashboard';Snapshot 'FirstSteps-Read-Complete';Trace 'Real AD read of Domain Controllers persisted one DC and complete coverage; step 3 checked'
 Click 'BtnFirstStepDashboard'
 for($i=0;$i -lt 120;$i++){
  Start-Sleep -Milliseconds 500;Update-Window;$settings=Read-Settings
  if([bool]$settings.'Home.FirstStepsDone') {break}
  $b=ById 'BtnFirstStepDashboard'
  if($b -and $b.Current.IsEnabled -and -not $b.Current.IsOffscreen -and (Label 'LblFirstStepDashboard') -match 'prête'){Click 'BtnFirstStepDashboard'}
 }
 Require ([bool]$settings.'Home.FirstStepsDone' -and [bool][string]$settings.'Home.DashboardSeen') 'First steps did not finish after local dashboard preparation'
 $result.DashboardText=Label 'LblFleetDashboard';$result.ScopeText=Label 'LblFleetScope';Snapshot 'FirstSteps-Complete'
 Trace 'First steps completed with actual AD collection and local dashboard'
 Trace 'Critical UI scope: first steps, AD search, selected object and workstation health'
 Set-Text 'TxtGlobalSearch' 'DC01';Click 'BtnGlobalSearch';$sw=[Diagnostics.Stopwatch]::StartNew();$item=$null
 while($sw.Elapsed.TotalSeconds -lt 60){
  Update-Window;$grid=ById 'DgObjects'
  if($grid){$item=@($grid.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::DataItem)))|Select-Object -First 1;if($item){break}}
  Start-Sleep -Milliseconds 150
 }
 Require ($null -ne $item) 'DC01 search yielded no rendered row';$result.SearchFirstRowMs=$sw.ElapsedMilliseconds
 ([Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)).Select()
 Snapshot 'BroadUI-Search'
 Click 'WsObject';$readWatch=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 250;Update-Window;$result.ObjectReadStatus=Label 'LblObjectReadStatus'}while($readWatch.Elapsed.TotalSeconds -lt 75 -and $result.ObjectReadStatus -notmatch 'Fiche lue[.]')
 $result.ObjectReadMs=$readWatch.ElapsedMilliseconds
 Require ($result.ObjectReadStatus -match 'Fiche lue[.]') ('Selected object did not finish: '+$result.ObjectReadStatus)
 Snapshot 'BroadUI-Object'
 Click 'WsComputer';Start-Sleep -Seconds 1;Snapshot 'BroadUI-Computer'
 Select-Tab 'TabComputerHealth';Snapshot 'BroadUI-Health'
 Click 'TabDashboard';Snapshot 'BroadUI-Dashboard'
 Stop-App;Trace 'Selected AD workstation, fiche, workstation and health pages opened; normal close'
 $result.Passed=$true
}catch{$result.Error=$_.Exception.Message;$result.Stack=$_.ScriptStackTrace;try{if($script:app){Snapshot 'BroadUI-Failure'}}catch{}}
finally{$result.FinishedUtc=[datetime]::UtcNow.ToString('o');Save-Json 'CriticalUI-Result.json' $result}
if(-not $result.Passed){exit 1}
