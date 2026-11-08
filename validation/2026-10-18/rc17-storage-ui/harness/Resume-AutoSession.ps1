param([ValidateSet('Auto','Restore')][string]$Stage='Auto',[switch]$Interactive)
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
 $hash=(Get-FileHash "$root\Domenia_PROD.zip" -Algorithm SHA256).Hash.ToLowerInvariant();Require ($hash -eq '0393c1b7fd23e732209d3f96c4c91196afcb57ba26f02e86d79bbbc7eb4e908a') 'Wrong RC17 archive';$result.ArchiveSha256=$hash
 if($Stage -eq 'Auto'){
  $prior=Get-Content (Join-Path $out 'Auto-Result.json') -Raw|ConvertFrom-Json
  Copy-Item (Join-Path $out 'Auto-Result.json') (Join-Path $out ('Auto-Attempt-'+[datetime]::UtcNow.ToString('HHmmss')+'.json')) -Force
  $proc=Get-CimInstance Win32_Process -Filter ('ProcessId='+$prior.AppId);Require ($proc.CommandLine -like ('*'+$install+'*')) 'Wrong isolated process'
  $script:app=Get-Process -Id $prior.AppId;$result.AppId=$script:app.Id;Update-Window;$script:window.SetFocus();Storage-Page
  Trace 'Continuing same isolated app; selected workspace peer used for UI controls'
  $dbs=@(Get-ChildItem "$install\wad\data\Domains" -Filter Domenia.db -Recurse);Require ($dbs.Count -eq 1) 'Expected one isolated domain DB';$db=$dbs[0].FullName
  $token='RC17-AUTO-UI-'+[guid]::NewGuid().ToString('N');Query $db ("CREATE TABLE qualification_marker(value TEXT);INSERT INTO qualification_marker VALUES('$token');") -Write
  $settings="$install\wad\data\Preferences\Domenia.settings.json"
  $exp=ByName 'Sauvegardes automatiques et conservation';Require ($null -ne $exp) 'Backup expander absent';([Windows.Automation.ExpandCollapsePattern]$exp.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand();Start-Sleep -Milliseconds 400
  $check=ById 'ChkStorageAutoBackup';$toggle=[Windows.Automation.TogglePattern]$check.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);Require ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Automatic backup must start disabled';$toggle.Toggle();Click 'BtnStoragePolicySave'
  $enabledAt=[datetime]::UtcNow;Trace 'Automatic policy enabled and saved through UI; waiting for unchanged 60000 ms timer'
  $watch=[Diagnostics.Stopwatch]::StartNew();$detail=$null;$backup=$null
  while($watch.Elapsed.TotalSeconds -lt 150){
   Start-Sleep -Seconds 2
   if(Test-Path $settings){$s=Get-Content $settings -Raw|ConvertFrom-Json;$entry=@($s.PSObject.Properties|Where-Object Name -like 'Storage.Backup.LastDetail.*'|Select-Object -First 1);if($entry.Count){$detail=$entry[0].Value|ConvertFrom-Json;if($detail.Automatic -and $detail.Origin -eq 'Scheduled'){$backup=Join-Path (Join-Path $dbs[0].DirectoryName 'Backups') $detail.File;if(Test-Path $backup){break}}}}
  }
  Require ($detail -and $detail.Automatic -and $backup -and (Test-Path $backup)) 'No Scheduled verified receipt within 150 seconds'
  $backupHash=(Get-FileHash $backup -Algorithm SHA256).Hash.ToLowerInvariant();Require ($backupHash -eq $detail.Sha256.ToLowerInvariant()) 'Backup receipt hash mismatch';Require ((Query $backup 'PRAGMA quick_check;')[0].quick_check -eq 'ok') 'Backup integrity';Require ((Query $backup 'SELECT value FROM qualification_marker;')[0].value -eq $token) 'Backup marker missing'
  Snapshot 'Auto-Success';$result.Database=$db;$result.Backup=$backup;$result.BackupSha256=$backupHash;$result.Marker=$token;$result.Settings=$settings;$result.ElapsedAfterEnableMs=[int]([datetime]::UtcNow-$enabledAt).TotalMilliseconds;$result.Receipt=$detail
  # Disable by UI; a following real timer interval must not produce an additional copy.
  ([Windows.Automation.TogglePattern](ById 'ChkStorageAutoBackup').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)).Toggle();Click 'BtnStoragePolicySave';$countBefore=@(Get-ChildItem ([IO.Path]::GetDirectoryName($backup)) -Filter '*.db').Count
  Trace 'Scheduled backup verified; disabled through UI, observing next timer interval'
  Start-Sleep -Seconds 65;$countAfter=@(Get-ChildItem ([IO.Path]::GetDirectoryName($backup)) -Filter '*.db').Count;Require ($countAfter -eq $countBefore) 'Backup still ran after disabling';$result.DisabledNextIntervalNoBackup=$true
  Stop-App;Trace 'Automatic cycle complete and app closed normally';$result.Passed=$true
 }else{throw 'Restore stage not yet configured'}
}catch{$result.Error=$_.Exception.Message;$result.Stack=$_.ScriptStackTrace;try{if($script:app){Snapshot ($Stage+'-Failure')}}catch{} }
finally{$result.FinishedUtc=[datetime]::UtcNow.ToString('o');Save-Json ($Stage+'-Result.json') $result}
if(-not $result.Passed){exit 1}
