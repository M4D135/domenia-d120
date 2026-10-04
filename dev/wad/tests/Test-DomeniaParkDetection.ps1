#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'Domenia-Modules.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaEffectiveWorkerResult','Get-MainXaml','Start-DomeniaParkSweep','Request-DomeniaParkSweepAtStartup')){
 $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
 . ([scriptblock]::Create($f.Extent.Text))
}
function Assert {param($Value,[string]$Why='Assertion fausse')if(-not $Value){throw $Why}}
$checks=[Collections.Generic.List[object]]::new()
function Case {param($Name,[scriptblock]$Body)try{& $Body|Out-Null;$status='Passed';$detail=''}catch{$status='Failed';$detail=$_.Exception.Message+' '+$_.ScriptStackTrace};$checks.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail});if($status -eq 'Failed'){Write-Host ($Name+': '+$detail)}}
function Set-Status {param($Text,$Level)$script:Status=$Text}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
function Initialize-DomeniaWinSqliteNative {}
function Get-DomeniaSetting {param($Name,$Default)return $true}
function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel)$script:Confirm=$OnConfirm;$script:Cancel=$OnCancel;$script:Message=$Message}
function Start-UiTask {
 param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TimeoutSeconds,$TaskClass)
 $id='job-'+$script:Calls.Count
 $call=[pscustomobject]@{Id=$id;Payload=$Payload;State=$CallbackState;OperationId=$OperationId};$script:Calls.Add($call);$script:AsyncJobs[$id]=$call;return $id
}
function Queue-DomeniaMetadata {param($Kind,$Key,$Row)$script:Saves.Add($Row);return $true}
function Request-DomeniaLinkPersistence {$script:LinkSaves++}
function Get-ExistingLinkForComputer {param($Computer)return $script:Existing}
function Add-DomeniaRelation {param($Relation,[switch]$NoSave,[switch]$Quiet)$script:RelationsAdded.Add($Relation);return [pscustomobject]@{StoredChanged=$true}}
function Set-RowAssociationMetadata {param($Rows)}
function Reset-Fixture {
 if($null -ne $script:ParkRun -and $null -ne $script:ParkRun.Timer){$script:ParkRun.Timer.Stop()}
 $script:ParkRun=$null;$script:SessionEpoch=1L;$script:DatabaseScopedPath='C:\fixture\domain.db';$script:DemoMode=$false;$script:AsyncEngineClosing=$false;$script:WriteState='Idle';$script:ActiveWriteTaskId='';$script:Persistence=$null;$script:Live=$null;$script:Existing=$null
 $script:Conn=[pscustomobject]@{Domain='example.invalid'};$script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@()
 $script:Calls=[Collections.Generic.List[object]]::new();$script:Saves=[Collections.Generic.List[object]]::new();$script:RelationsAdded=[Collections.Generic.List[object]]::new();$script:LinkSaves=0;$script:Confirm=$null;$script:Cancel=$null
 $script:Ctrl=@{DgObjects=[Windows.Controls.DataGrid]::new();LblParkStatus=[Windows.Controls.TextBlock]::new();LblParkDetectionStatus=[Windows.Controls.TextBlock]::new()}
 $script:Ctrl.DgObjects.CanUserAddRows=$false
}
function New-Target {param([int]$N=1) [pscustomobject]@{Computer=('PC-'+$N);Key=('cn=pc-'+$N+',dc=example,dc=invalid');Guid=('00000000-0000-0000-0000-'+$N.ToString('d12'));Previous=$null}}
function Ready-Run {param([int]$Count=10)
 Start-DomeniaOnlinePark;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(for($i=1;$i -le $Count;$i++){New-Target $i});Busy=$false}) $call.State
 $script:AsyncJobs.Remove($call.Id)
 $script:ParkRun.Approved=$true
}
function New-Result {param($Target,[string]$User='alice')
 [pscustomobject]@{Key=$Target.Key;Guid=$Target.Guid;Computer=$Target.Computer;Outcome='Observed';User=('EXAMPLE\'+$User);LinkUser=$User;UserDn=('CN='+$User+',DC=example,DC=invalid');UserGuid='00000000-0000-0000-0001-000000000001';UserUsn='5';CacheReused=$false;DirectoryAuthRejected=$false;Presence='En ligne';PresenceCheckedUtc=[datetime]::UtcNow.ToString('o');Detail='fixture';Source='Console'}
}
Case 'Parc : aucun demarrage ni mode silencieux ne contacte les postes' {
 Reset-Fixture;Request-DomeniaParkSweepAtStartup;Start-DomeniaParkSweep -Silent;Assert ($script:Calls.Count -eq 0)
}
Case 'Resultats : seuls les postes affiches apres filtre sont figes' {
 Reset-Fixture
 $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
 foreach($n in 1..3){$row=New-DomeniaLiveResultRow;$row.Type=$(if($n -eq 3){'Utilisateur'}else{'Machine'});$row.Name='PC-'+$n;$row.DN='CN=PC-'+$n+',DC=example,DC=invalid';$row.Guid=(New-Target $n).Guid;$rows.Add($row)}
 $script:Ctrl.DgObjects.ItemsSource=$rows;$script:Ctrl.DgObjects.Items.Filter=[Predicate[object]]{param($x)$x.Name -ne 'PC-2'}
 Start-DomeniaOnlinePark -DisplayedResults
 $p=$script:Calls[0].Payload;Assert ($p.Scope -eq 'Results' -and $p.Targets.Count -eq 1 -and $p.Targets[0].name -eq 'PC-1')
 $script:Ctrl.DgObjects.Items.Filter=$null;Assert ($p.Targets.Count -eq 1)
}
Case 'Resultats : vide ne retombe jamais sur tout le parc' {Reset-Fixture;Start-DomeniaOnlinePark -DisplayedResults;Assert ($script:Calls.Count -eq 0)}
Case 'Parc : lecture locale avant confirmation et aucun poste sans confirmation' {Reset-Fixture;Ready-Run;Assert ($script:Calls.Count -eq 1 -and $null -ne $script:Confirm -and $null -eq $script:ParkRun.Timer);& $script:Cancel;Assert $script:ParkRun.Completed;Assert ($script:Calls.Count -eq 1)}
Case 'Parc : timer ne peut pas commencer avant approbation du perimetre' {Reset-Fixture;Ready-Run;$script:ParkRun.Approved=$false;Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 1)}
Case 'Parc : ancienne annulation ne peut pas arreter un nouveau releve' {Reset-Fixture;Ready-Run;$cancel=$script:Cancel;$script:ParkRun.Id='new-run';& $cancel;Assert (-not $script:ParkRun.Stopping)}
Case 'Parc : quatre lectures au maximum et un depart par tick' {Reset-Fixture;Ready-Run 151;1..10|ForEach-Object{Invoke-DomeniaParkRunTick};Assert ($script:ParkRun.Pending.Count -eq 4 -and $script:ParkRun.Next -eq 4 -and $script:ParkRun.Targets.Count -eq 151)}
Case 'Parc : arret ne lance plus rien et garde le resultat en vol' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;Stop-DomeniaOnlinePark;Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 2);Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:Saves.Count -eq 1 -and $script:RelationsAdded.Count -eq 1);Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed}
Case 'Parc : meme callback ne peut pas etre applique deux fois' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$packet=New-Result $state.Target;Complete-DomeniaParkSession $packet $state;Complete-DomeniaParkSession $packet $state;Assert ($script:Saves.Count -eq 1 -and $script:ParkRun.Done -eq 1)}
Case 'Parc : ancien contexte ignore sans ecriture ni association' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$script:SessionEpoch++;Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:Saves.Count -eq 0 -and $script:RelationsAdded.Count -eq 0);Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed}
Case 'Parc : association manuelle ou importee protegee meme si changee pendant lecture' {
 foreach($source in @(' Manual ','import csv','Saisie manuelle')){Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$script:Existing=[pscustomobject]@{Source=$source;UserLogin='bob'};Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:RelationsAdded.Count -eq 0 -and $script:Saves.Count -eq 1)}
}
Case 'Parc : utilisateur inchange ne reecrit pas association ni historique' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$p=New-Result $state.Target;$p.CacheReused=$true;$script:Existing=[pscustomobject]@{Source='Console';UserLogin='alice';UserGuid=$p.UserGuid;ComputerGuid=$p.Guid};Complete-DomeniaParkSession $p $state;Assert ($script:RelationsAdded.Count -eq 0 -and $script:LinkSaves -eq 0 -and $script:ParkRun.Reused -eq 1)}
Case 'Parc : poste inaccessible conserve le dernier utilisateur et son instant' {
 Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$previous=ConvertTo-DomeniaParkSession (New-Result $state.Target) $null '2000-01-01T00:00:00Z';$state.Target.Previous=$previous
 Fail-DomeniaParkSession 'timeout fixture' $state
 Assert ($script:Saves[0].RawAccount -eq 'EXAMPLE\alice' -and $script:Saves[0].ObservedUtc -eq '2000-01-01T00:00:00Z' -and $script:Saves[0].Outcome -eq 'Unavailable' -and $script:RelationsAdded.Count -eq 0)
}
Case 'Parc : compte refuse arrete les nouvelles lectures sans rejeu' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$p=New-Result $state.Target;$p.Outcome='AuthRejected';Complete-DomeniaParkSession $p $state;Invoke-DomeniaParkRunTick;Assert ($script:ParkRun.Stopping -and $script:Calls.Count -eq 2 -and $script:RelationsAdded.Count -eq 0)}
Case 'Parc : annulation centrale ou disparition du worker arrete la suite' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$script:AsyncJobs.Clear();Invoke-DomeniaParkRunTick;Assert ($script:ParkRun.Stopping -and $script:Calls.Count -eq 2)}
Case 'Parc : pression du stockage suspend les nouvelles lectures' {Reset-Fixture;Ready-Run;$script:Persistence=[pscustomobject]@{Pending=@{};LinkBusy=$true;Failures=0;Conflicts=@{}};Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 1)}
Case 'Interface : les deux actions et leurs arrets sont cables aux bons perimetres' {
 $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 try{
  $script:ClickScope='';function Start-DomeniaOnlinePark {param([switch]$DisplayedResults)$script:ClickScope=$(if($DisplayedResults){'Results'}else{'Park'})};function Stop-DomeniaOnlinePark {$script:ClickScope='Stop'}
  $script:Ctrl=@{};foreach($name in @('BtnParkSweep','BtnParkResults','BtnParkSweepStop','BtnParkResultsStop')){$script:Ctrl[$name]=$window.FindName($name);Assert ($null -ne $script:Ctrl[$name])}
  foreach($n in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Click'},$true))){if($n.Expression.Extent.Text -match '^\$script:Ctrl\["(BtnParkSweep|BtnParkResults|BtnParkSweepStop|BtnParkResultsStop)"\]$'){. ([scriptblock]::Create($n.Extent.Text))}}
  foreach($pair in @(@('BtnParkSweep','Park'),@('BtnParkResults','Results'),@('BtnParkSweepStop','Stop'),@('BtnParkResultsStop','Stop'))){$script:Ctrl[$pair[0]].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Assert ($script:ClickScope -eq $pair[1]) $pair[0]}
 }finally{$window.Close()}
}
if($null -ne $script:ParkRun -and $null -ne $script:ParkRun.Timer){$script:ParkRun.Timer.Stop()}
$failed=@($checks|Where-Object Status -eq 'Failed').Count
$report=[ordered]@{Kind='ParkDetection';NativeWindowsPowerShell51=$true;LiveAD=$false;MockedNetwork=$true;Passed=$checks.Count-$failed;Failed=$failed;Tests=$checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path $env:TEMP 'domenia-park-tests.json'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ($report.Passed.ToString()+' reussis, '+$failed+' echecs. '+$ReportPath)
if($failed){exit 1}
