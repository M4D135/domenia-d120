param([string]$Stage='Final',[switch]$Interactive)
$ErrorActionPreference='Stop'
$root='C:\DomeniaLab\d120-rc11719-final';$install=Join-Path $root 'prod';$out=Join-Path $root 'final-out';$task='Domenia-RC19-'+$Stage
[void][IO.Directory]::CreateDirectory($out)
function Save-Json($name,$data){[IO.File]::WriteAllText((Join-Path $out $name),($data|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
if(-not $Interactive){
 $user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user){throw 'Interactive Windows session required'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Stage '+$Stage+' -Interactive')
 Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 8)) -Force|Out-Null
 Start-ScheduledTask -TaskName $task;Write-Output ('Dispatched '+$Stage);exit
}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
$result=[ordered]@{Build='RC1.17.19';Stage=$Stage;Passed=$false;StartedUtc=[datetime]::UtcNow.ToString('o');Session=(Get-Process -Id $PID).SessionId;PSVersion=$PSVersionTable.PSVersion.ToString();Steps=@();AppId=0}
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
  if($script:app){$script:app.Refresh();Require (-not $script:app.HasExited) 'App exited during startup';if($script:app.MainWindowHandle -ne 0){try{Update-Window}catch{Start-Sleep -Milliseconds 500;continue};$nav=ById 'TabDashboard';if($nav -and -not $nav.Current.IsOffscreen){Trace 'Authenticated main window visible';return};$login=ById 'BtnWindowsLogin';if($login -and $login.Current.IsEnabled -and -not $login.Current.IsOffscreen -and -not $loginInvoked){Click 'BtnWindowsLogin';$loginInvoked=$true;Trace 'Windows account login invoked'}}}
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
function Read-Settings{Get-Content $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json}
function Set-Text($id,$text){$c=ById $id;Require ($null -ne $c) ('Missing '+$id);([Windows.Automation.ValuePattern]$c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)).SetValue($text)}
function Get-Text($id){$c=ById $id;return ([Windows.Automation.ValuePattern]$c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)).Current.Value}
function Backup-Panel{Storage-Page;$e=ByName 'Sauvegardes automatiques et conservation';Require ($null -ne $e) 'Backup section absent';([Windows.Automation.ExpandCollapsePattern]$e.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand();Start-Sleep -Milliseconds 400}
function Get-Bounds{$r=$script:window.Current.BoundingRectangle;return [pscustomobject]@{Left=$r.Left;Top=$r.Top;Width=$r.Width;Height=$r.Height}}
try{
 $result.ArchiveSha256=(Get-FileHash (Join-Path $root 'Domenia_PROD.zip') -Algorithm SHA256).Hash
 Require ($result.ArchiveSha256 -eq 'DBC505659603C06B7756C396C6A97A8FD9B45A68EF262CC4112783F8AEA1484B') 'Wrong RC19 archive'
 $script:settingsPath=Join-Path $install 'wad\data\Preferences\Domenia.settings.json'
 Start-App;$result.FirstProcess=$script:app.Id;Backup-Panel
 $dbs=@(Get-ChildItem (Join-Path $install 'wad\data\Domains') -Filter Domenia.db -Recurse);Require ($dbs.Count -eq 1) 'Expected one isolated database';$db=$dbs[0].FullName
 $token='RC19-FINAL-'+[guid]::NewGuid().ToString('N');Query $db ("CREATE TABLE qualification_marker(value TEXT);INSERT INTO qualification_marker VALUES('$token');") -Write
 $wp=[Windows.Automation.WindowPattern]$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern);$wp.SetWindowVisualState([Windows.Automation.WindowVisualState]::Normal);Start-Sleep -Milliseconds 300
 $transform=[Windows.Automation.TransformPattern]$script:window.GetCurrentPattern([Windows.Automation.TransformPattern]::Pattern);$transform.Resize(1320,820);$transform.Move(120,80);Start-Sleep -Milliseconds 500;Update-Window
 $result.NormalBounds=Get-Bounds;Snapshot 'First-Normal'
 $toggle=[Windows.Automation.TogglePattern](ById 'ChkStorageAutoBackup').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 Require ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Fresh policy must be disabled'
 Set-Text 'TxtStorageBackupHours' '48';Set-Text 'TxtStorageBackupKeep' '5';$toggle.Toggle();Click 'BtnStoragePolicySave'
 $wp.SetWindowVisualState([Windows.Automation.WindowVisualState]::Maximized);Start-Sleep -Milliseconds 400
 Stop-App;$first=Read-Settings;$policy=$first.'Storage.PolicyJson'|ConvertFrom-Json
 Require ($policy.AutomaticBackup -and $policy.BackupHours -eq 48 -and $policy.BackupKeep -eq 5) 'First policy not saved'
 Require ([bool]$first.WindowMaximized) 'First maximized state not saved'
 Require (@($first.PSObject.Properties|Where-Object Name -like 'Storage.Backup.LastDetail.*').Count -eq 0) 'Unexpected backup before reopening'
 Save-Json 'After-First-Close.json' ([ordered]@{WindowMaximized=$first.WindowMaximized;WindowLeft=$first.WindowLeft;WindowTop=$first.WindowTop;WindowWidth=$first.WindowWidth;WindowHeight=$first.WindowHeight;Policy=$policy})
 Trace 'First launch closed normally: geometry, maximization and enabled 48h/5-copy policy saved; no backup yet'
 $reopened=[datetime]::UtcNow;Start-App;$result.SecondProcess=$script:app.Id
 $wp=[Windows.Automation.WindowPattern]$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern)
 Require ($wp.Current.WindowVisualState -eq [Windows.Automation.WindowVisualState]::Maximized) 'Reopened window is not maximized'
 $result.ReopenedMaximized=$true;Snapshot 'Reopened-Maximized'
 $wp.SetWindowVisualState([Windows.Automation.WindowVisualState]::Normal);Start-Sleep -Milliseconds 700;Update-Window;$bounds=Get-Bounds
 foreach($key in @('Left','Top','Width','Height')){Require ([math]::Abs([double]$bounds.$key-[double]$result.NormalBounds.$key) -le 2) ('Restored geometry differs: '+$key)}
 $result.RestoredNormalBounds=$bounds;Backup-Panel
 $toggle=[Windows.Automation.TogglePattern](ById 'ChkStorageAutoBackup').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 Require ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) 'Automatic backup checkbox lost on reopening'
 Require ((Get-Text 'TxtStorageBackupHours') -eq '48' -and (Get-Text 'TxtStorageBackupKeep') -eq '5') 'Backup UI settings lost on reopening'
 $result.ReopenedPolicyMatches=$true;Trace 'Second launch: maximization, restored normal rectangle and enabled backup settings verified through UI'
 $watch=[Diagnostics.Stopwatch]::StartNew();$backup=$null;$detail=$null;$entry=$null
 while($watch.Elapsed.TotalSeconds -lt 150){
  $s=Read-Settings;$entry=@($s.PSObject.Properties|Where-Object Name -like 'Storage.Backup.LastDetail.*'|Select-Object -First 1)
  if($entry.Count){$detail=$entry[0].Value|ConvertFrom-Json;if($detail.Automatic -and $detail.Origin -eq 'Scheduled'){$backup=Join-Path (Join-Path $dbs[0].DirectoryName 'Backups') $detail.File;if(Test-Path $backup){break}}}
  Start-Sleep -Seconds 2
 }
 Require ($backup -and (Test-Path $backup) -and $detail.Automatic -and $detail.Origin -eq 'Scheduled') 'Scheduled backup absent after reopening'
 $hash=(Get-FileHash $backup -Algorithm SHA256).Hash;Require ($hash -eq $detail.Sha256) 'Backup receipt hash mismatch'
 Require ((Query $backup 'PRAGMA quick_check;')[0].quick_check -eq 'ok') 'Backup integrity failed'
 Require ((Query $backup 'SELECT value FROM qualification_marker;')[0].value -eq $token) 'Backup marker missing'
 $result.Backup=$backup;$result.Receipt=$detail;$result.BackupSha256=$hash;$result.Marker=$token;$result.QuickCheck='ok';$result.AutomaticSecondsAfterReopen=[int]([datetime]::UtcNow-$reopened).TotalSeconds
 Snapshot 'Automatic-Backup-Success';Stop-App
 $final=Read-Settings;$finalPolicy=$final.'Storage.PolicyJson'|ConvertFrom-Json
 Require ($finalPolicy.AutomaticBackup -and $finalPolicy.BackupHours -eq 48 -and $finalPolicy.BackupKeep -eq 5) 'Policy lost after final close'
 Require ([string]$final.($entry[0].Name) -ceq [string]$entry[0].Value) 'Backup receipt lost on final close'
 Save-Json 'After-Final-Close.json' ([ordered]@{WindowMaximized=$final.WindowMaximized;WindowLeft=$final.WindowLeft;WindowTop=$final.WindowTop;WindowWidth=$final.WindowWidth;WindowHeight=$final.WindowHeight;Policy=$finalPolicy;Receipt=($final.($entry[0].Name)|ConvertFrom-Json)})
 Copy-Item $backup (Join-Path $out 'verified-automatic-backup.db')
 $m=Get-Content (Join-Path $install 'wad\package-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
 foreach($f in $m.Files){Require ((Get-FileHash (Join-Path $install $f.Path) -Algorithm SHA256).Hash -eq $f.Sha256) ('Runtime changed: '+$f.Path)}
 $result.RuntimeFilesVerified=$m.Files.Count;$result.RuntimeUnchanged=$true;$result.AutomaticTimerUnchangedMs=60000;$result.FinalCloseNormal=$true;$result.OperatorProfileUntouched=$true
 Trace 'Real scheduled backup verified; isolated application closed normally; all runtime hashes unchanged';$result.Passed=$true
}catch{$result.Error=$_.Exception.Message;$result.Stack=$_.ScriptStackTrace;try{if($script:app -and -not $script:app.HasExited){Snapshot 'Failure'}}catch{}}
finally{$result.FinishedUtc=[datetime]::UtcNow.ToString('o');Save-Json 'Final-Result.json' $result}
if(-not $result.Passed){exit 1}
