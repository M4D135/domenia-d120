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
function Get-DomeniaSetting {param($Name,$Default)if($null -ne $script:SettingValues -and $script:SettingValues.ContainsKey([string]$Name)){return $script:SettingValues[[string]$Name]};return $Default}
function New-DomeniaObservationReader {return [pscustomobject]@{Fixture=$true}}
function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel)$script:Confirm=$OnConfirm;$script:Cancel=$OnCancel;$script:Message=$Message}
function Start-UiTask {
 param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TimeoutSeconds,$HardTimeoutSeconds,$TaskClass)
 $id='job-'+$script:Calls.Count
 $call=[pscustomobject]@{Id=$id;Payload=$Payload;State=$CallbackState;OperationId=$OperationId;TimeoutSeconds=$TimeoutSeconds;HardTimeoutSeconds=$HardTimeoutSeconds};$script:Calls.Add($call);$script:AsyncJobs[$id]=$call;return $id
}
# Points 20 and 159: preference files and settings of the operator, in memory only.
function Write-DomeniaPreference {param([string]$FileName,[string]$Value)$script:Prefs[$FileName]=$Value;return $true}
function Read-DomeniaPreference {param([string]$FileName)if($null -ne $script:Prefs -and $script:Prefs.ContainsKey($FileName)){return [string]$script:Prefs[$FileName]};return ''}
function Queue-DomeniaMetadata {throw 'Ancien writer brut interdit.'}
function Write-AppLog {param($Text,$Level)}
function New-DomeniaTimer {param($Owner,$IntervalMs,[switch]$RunWhenHidden,$Tick)$timer=[pscustomobject]@{IsEnabled=$false};$timer|Add-Member ScriptMethod Start {$this.IsEnabled=$true};$timer|Add-Member ScriptMethod Stop {$this.IsEnabled=$false};return $timer}
function Submit-DomeniaStoreBatch {
 param($Context,$BatchId,$Sequence,$Changes,$SuccessHandler,$ErrorHandler,$CallbackState)
 $script:Saves.Add([pscustomobject]@{Context=$Context;BatchId=$BatchId;Changes=$Changes;CallbackState=$CallbackState;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler})
 return [pscustomobject]@{Accepted=$true;Backpressure=$false}
}
function Commit-Saved {param([int]$Index=0)
 $saved=$script:Saves[$Index];$state=$saved.CallbackState.State
 $row=[pscustomobject]@{Version=1;Key=$state.StoreDn;Guid=$state.StoreGuid;Computer=$state.Target.Computer;Presence='En ligne';PresenceCheckedUtc='2026-10-13T10:00:00Z';Outcome='Observed';CurrentUser='EXAMPLE\COMMITTED';LastUser='EXAMPLE\COMMITTED';RawAccount='EXAMPLE\COMMITTED';ObservedUtc='2026-10-13T10:00:00Z';CheckedUtc='2026-10-13T10:00:00Z';Probes=$null;Revision=17}
 $receipt=[pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$saved.Context.StoreId;RequestId=$saved.Context.RequestId;BatchId=$saved.BatchId;ObservationRows=@($row);Observations=@();Revision=17;SnapshotRevision=17}
 & $saved.SuccessHandler -Result $receipt -State $saved.CallbackState
}

function Request-DomeniaLinkPersistence {$script:LinkSaves++}
function Get-ExistingLinkForComputer {param($Computer)return $script:Existing}
function Add-DomeniaRelation {param($Relation,[switch]$NoSave,[switch]$Quiet)$script:RelationsAdded.Add($Relation);return [pscustomobject]@{StoredChanged=$true}}
function Set-RowAssociationMetadata {param($Rows)}
function Reset-Fixture {
 if($null -ne $script:ParkRun -and $null -ne $script:ParkRun.Timer){$script:ParkRun.Timer.Stop()}
 $script:DomeniaRemoteStoreQueue=$null;$script:DomeniaRemoteStoreTimer=$null;$script:DomeniaAccountGeneration=1L;$script:GlobalSearchGeneration=1L;$script:ListSurveyBlocked=$false;$script:ParkRun=$null;$script:SessionEpoch=1L;$script:DatabaseScopedPath='C:\fixture\domain.db';$script:DemoMode=$false;$script:AsyncEngineClosing=$false;$script:WriteState='Idle';$script:ActiveWriteTaskId='';$script:Persistence=$null;$script:Live=$null;$script:Existing=$null;$script:FleetLast=$null;$script:FleetObservations=@{};$script:SelectedObject=$null
 $script:Conn=[pscustomobject]@{Domain='example.invalid';BaseDn='dc=example,dc=invalid'};$script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@()
 $script:Calls=[Collections.Generic.List[object]]::new();$script:Saves=[Collections.Generic.List[object]]::new();$script:RelationsAdded=[Collections.Generic.List[object]]::new();$script:LinkSaves=0;$script:Confirm=$null;$script:Cancel=$null
 $script:Ctrl=@{DgObjects=[Windows.Controls.DataGrid]::new();LblParkStatus=[Windows.Controls.TextBlock]::new();LblParkDetectionStatus=[Windows.Controls.TextBlock]::new()}
 $script:Ctrl.DgObjects.CanUserAddRows=$false
 $script:DomeniaTargetAddresses=$null;$script:DomeniaCapabilityMemory=$null;$script:Prefs=@{};$script:SettingValues=@{};$script:DomeniaCollectionWindowCache=$null;$script:DomeniaFreshnessCache=$null;$script:Resumed=$null
}
function New-Target {param([int]$N=1) [pscustomobject]@{Computer=('PC-'+$N);Key=('cn=pc-'+$N+',dc=example,dc=invalid');Guid=('00000000-0000-0000-0000-'+$N.ToString('d12'));Previous=$null}}
function Add-DisplayedMachine {[void]$script:Ctrl.DgObjects.Items.Add([pscustomobject]@{Type='Machine';Name='PC-SHOWN';DN='cn=pc-shown,dc=example,dc=invalid';Guid='00000000-0000-0000-0000-000000000999'})}
function Ready-Run {param([int]$Count=10)
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(for($i=1;$i -le $Count;$i++){New-Target $i});Busy=$false}) $call.State
 $script:AsyncJobs.Remove($call.Id)
 $script:ParkRun.Approved=$true
}
function New-Result {param($Target,[string]$User='alice')
 [pscustomobject]@{Key=$Target.Key;Guid=$Target.Guid;Computer=$Target.Computer;Outcome='Observed';ConsoleAttempted=$true;ConsoleCheckedUtc=[datetime]::UtcNow.ToString('o');User=('EXAMPLE\'+$User);LinkUser=$User;UserDn=('CN='+$User+',DC=example,DC=invalid');UserGuid='00000000-0000-0000-0001-000000000001';UserUsn='5';CacheReused=$false;DirectoryAuthRejected=$false;Presence='En ligne';PresenceCheckedUtc=[datetime]::UtcNow.ToString('o');Detail='fixture';Source='Console'}
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
Case 'Parc : arret ne lance plus rien et garde le resultat en vol' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;Stop-DomeniaOnlinePark;Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 2);Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:Saves.Count -eq 1 -and $script:RelationsAdded.Count -eq 0 -and $script:ParkRun.Done -eq 0);Invoke-DomeniaParkRunTick;Assert (-not $script:ParkRun.Completed);Commit-Saved;Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed}
Case 'Parc : meme callback ne peut pas etre applique deux fois' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$packet=New-Result $state.Target;Complete-DomeniaParkSession $packet $state;Complete-DomeniaParkSession $packet $state;Assert ($script:Saves.Count -eq 1 -and $script:ParkRun.Done -eq 0);Commit-Saved;Commit-Saved;Assert ($script:ParkRun.Done -eq 1)}
Case 'Parc : ancien contexte enregistre sans publication ni association' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$script:SessionEpoch++;Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:Saves.Count -eq 1 -and $script:RelationsAdded.Count -eq 0);Commit-Saved;Assert ($script:ParkRun.Done -eq 0);Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed}
Case 'Parc : association manuelle ou importee protegee meme si changee pendant lecture' {
 foreach($source in @(' Manual ','import csv','Saisie manuelle')){Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$script:Existing=[pscustomobject]@{Source=$source;UserLogin='bob'};Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:RelationsAdded.Count -eq 0 -and $script:Saves.Count -eq 1)}
}
Case 'Parc : utilisateur inchange ne reecrit pas association ni historique' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$p=New-Result $state.Target;$p.CacheReused=$true;$script:Existing=[pscustomobject]@{Source='Console';UserLogin='alice';UserGuid=$p.UserGuid;ComputerGuid=$p.Guid};Complete-DomeniaParkSession $p $state;Assert ($script:RelationsAdded.Count -eq 0 -and $script:LinkSaves -eq 0 -and $script:ParkRun.Done -eq 0 -and $script:Saves.Count -eq 1)}
Case 'Parc : echec date de la tentative sans fausse nouvelle reussite' {
 Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$previous=ConvertTo-DomeniaParkSession (New-Result $state.Target) $null '2000-01-01T00:00:00Z';$state.Target.Previous=$previous
 Fail-DomeniaParkSession 'timeout fixture' $state
 Assert ($script:Saves[0].Changes.Count -eq 2 -and @($script:Saves[0].Changes|Where-Object{$_.Status -ne 'Error' -or $_.ObservedAtUtc}).Count -eq 0 -and $script:RelationsAdded.Count -eq 0 -and $previous.ObservedUtc -eq '2000-01-01T00:00:00Z')
}
Case 'Parc : compte refuse arrete les nouvelles lectures sans rejeu' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$p=New-Result $state.Target;$p.Outcome='AuthRejected';Complete-DomeniaParkSession $p $state;Invoke-DomeniaParkRunTick;Assert ($script:ParkRun.Stopping -and $script:Calls.Count -eq 2 -and $script:RelationsAdded.Count -eq 0)}
Case 'Parc : annulation centrale ou disparition du worker arrete la suite' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$script:AsyncJobs.Clear();Invoke-DomeniaParkRunTick;Assert ($script:ParkRun.Stopping -and $script:Calls.Count -eq 2)}
Case 'Parc : pression du stockage suspend les nouvelles lectures' {Reset-Fixture;Ready-Run;$script:Persistence=[pscustomobject]@{Pending=@{};LinkBusy=$true;Failures=0;Conflicts=@{}};Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 1)}
Case 'Parc : console reconfirmee maintenant meme si identite LDAP reutilisee' {
 Reset-Fixture;$target=New-Target;$packet=New-Result $target
 $previous=ConvertTo-DomeniaParkSession $packet $null '2026-01-01T00:00:00Z';$packet.CacheReused=$true
 $next=ConvertTo-DomeniaParkSession $packet $previous '2026-10-05T00:00:00Z'
 Assert ($next.ObservedUtc -eq '2026-10-05T00:00:00Z' -and $previous.ObservedUtc -eq '2026-01-01T00:00:00Z')
}
Case 'Parc : fin attend aussi le timer de sauvegarde des associations' {
 Reset-Fixture;Ready-Run 1;$script:ParkRun.Next=1
 $script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=0;Conflicts=@{};LinkBusy=$false;LinkRequestTimer=[pscustomobject]@{IsEnabled=$true};LinkPersistenceMore=$false}
 Invoke-DomeniaParkRunTick;Assert (-not $script:ParkRun.Completed) 'Releve termine avant la file des associations.'
 $script:Persistence.LinkRequestTimer.IsEnabled=$false;Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed
}
Case 'Parc : arret attend la sauvegarde deja demandee' {
 Reset-Fixture;Ready-Run 1;$script:ParkRun.Next=1
 $script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=0;Conflicts=@{};LinkBusy=$false;LinkRequestTimer=[pscustomobject]@{IsEnabled=$true};LinkPersistenceMore=$false}
 Stop-DomeniaOnlinePark;Assert (-not $script:ParkRun.Completed -and $script:ParkRun.Stopping)
 $script:Persistence.LinkRequestTimer.IsEnabled=$false;Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed
}
Case 'Parc : nouveau releve attend une association encore dans le timer de sauvegarde' {
 Reset-Fixture;$script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=0;Conflicts=@{};LinkBusy=$false;LinkRequestTimer=[pscustomobject]@{IsEnabled=$true};LinkPersistenceMore=$false}
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults;Assert ($script:Calls.Count -eq 0)
}
Case 'Parc entier : retire, aucune lecture sans la liste affichee (decision 2026-10-05)' {Reset-Fixture;Add-DisplayedMachine;Start-DomeniaOnlinePark;Start-DomeniaParkSweep;Assert ($script:Calls.Count -eq 0 -and $null -eq $script:ParkRun)}

Case 'WMI seul : aucune presence ICMP ni validation LDAP implicite' {
 Reset-Fixture;Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults -WmiOnly -Inventory
 $call=$script:Calls[0];Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target);Busy=$false}) $call.State;$script:AsyncJobs.Remove($call.Id);$script:ParkRun.Approved=$true
 Invoke-DomeniaParkRunTick;$payload=$script:Calls[1].Payload
 Assert (-not $payload.CollectPing -and -not $payload.ValidateConsoleIdentity -and $payload.Inventory -and $payload.ProbeUser)
}
Case 'Ping et WMI exclusifs : demande ambigue refusee avant cible' {
 Reset-Fixture;Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults -PingOnly -WmiOnly
 Assert ($script:Calls.Count -eq 0 -and $null -eq $script:ParkRun)
}

Case 'Interface : detection et analyse de la liste et leur arret cables ; aucun bouton parc entier' {
 $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 try{
  $script:ClickScope='';function Start-DomeniaOnlinePark {param([switch]$DisplayedResults)$script:ClickScope=$(if($DisplayedResults){'Results'}else{'Park'})};function Stop-DomeniaOnlinePark {$script:ClickScope='Stop'};function Start-DomeniaParkAnalysis {$script:ClickScope='Analyze'}
  $script:Ctrl=@{};foreach($name in @('BtnParkSweep','BtnParkSweepStop')){Assert ($null -eq $window.FindName($name)) ($name+' encore present')}
  foreach($name in @('BtnParkResults','BtnParkAnalyze','BtnParkResultsStop')){$script:Ctrl[$name]=$window.FindName($name);Assert ($null -ne $script:Ctrl[$name])}
  foreach($n in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Click'},$true))){if($n.Expression.Extent.Text -match '^\$script:Ctrl\["(BtnParkResults|BtnParkAnalyze|BtnParkResultsStop)"\]$'){. ([scriptblock]::Create($n.Extent.Text))}}
  $script:Ctrl['BtnParkResultsStop'].IsEnabled=$true;$script:Ctrl['BtnParkResults'].IsEnabled=$true;$script:Ctrl['BtnParkAnalyze'].IsEnabled=$true
  foreach($pair in @(@('BtnParkResults','Results'),@('BtnParkAnalyze','Analyze'),@('BtnParkResultsStop','Stop'))){$script:Ctrl[$pair[0]].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Assert ($script:ClickScope -eq $pair[1]) $pair[0]}
 }finally{$window.Close()}
}
# ---------------------------------------------------------------- points 14 to 20 and 159: the campaign of a park run
function Approve-Run {param([int]$Count=3)
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(for($i=1;$i -le $Count;$i++){New-Target $i});Busy=$false}) $call.State
 $script:AsyncJobs.Remove($call.Id);& $script:Confirm
}
Case 'Campagne : un sous-réseau ralenti est différé, les autres postes continuent' {
 Reset-Fixture;Ready-Run 6
 $script:DomeniaTargetAddresses=@{'pc-1'='10.1.2.11';'pc-2'='10.1.2.12';'pc-3'='10.1.2.13';'pc-4'='10.9.9.14';'pc-5'='10.9.9.15';'pc-6'='10.9.9.16'}
 $entry=Get-DomeniaSourceEntry $script:ParkRun.Sources.Health 'site:10.1.2.0/24' $script:ParkRun.Sources.Policy;$entry.Limit=1
 1..6|ForEach-Object{Invoke-DomeniaParkRunTick}
 $sent=@($script:Calls|Select-Object -Skip 1|ForEach-Object{[string]$_.Payload.Computer})
 Assert (($sent -join ',') -eq 'PC-1,PC-4,PC-5,PC-6') ('Ordre : '+($sent -join ','))
 Assert ($script:ParkRun.Deferred.Count -eq 2 -and $script:ParkRun.Pending.Count -eq 4)
}
Case 'Campagne : délai sans progrès et durée totale transmis, canal de progression joint' {
 Reset-Fixture;Ready-Run 1;Invoke-DomeniaParkRunTick;$call=$script:Calls[1]
 Assert ($call.Payload.ReadProgress -is [Collections.IDictionary] -and $call.TimeoutSeconds -eq 20 -and $call.HardTimeoutSeconds -eq 30) ('Délais '+$call.TimeoutSeconds+'/'+$call.HardTimeoutSeconds)
}
Case 'Campagne : incident transitoire relu une seule fois plus tard et compté une fois' {
 Reset-Fixture;Ready-Run 1;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
 $p=New-Result $state.Target;$p.Outcome='Timeout';Complete-DomeniaParkSession $p $state
 Assert ($script:ParkRun.Retry.Count -eq 1 -and $script:ParkRun.Retried -eq 1)
 Commit-Saved;Assert ($script:ParkRun.Done -eq 0 -and $script:ParkRun.Failed -eq 0) 'Essai suivi dʼune reprise compté'
 Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 2 -and -not $script:ParkRun.Completed) 'Reprise avant son délai'
 $script:ParkRun.Retry[0].NotBeforeUtc=[datetime]::UtcNow.AddSeconds(-1)
 Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 3 -and $script:Calls[2].State.Attempt -eq 2)
 $second=$script:Calls[2].State;Complete-DomeniaParkSession (New-Result $second.Target) $second;Commit-Saved 1
 Assert ($script:ParkRun.Done -eq 1 -and $script:ParkRun.Retry.Count -eq 0)
 Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed
}
Case 'Campagne : compte rejeté ou droit refusé jamais relus automatiquement' {
 foreach($outcome in @('AuthRejected','Denied')){
  Reset-Fixture;Ready-Run 2;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
  $p=New-Result $state.Target;$p.Outcome=$outcome;Complete-DomeniaParkSession $p $state
  Assert ($script:ParkRun.Retry.Count -eq 0 -and $script:ParkRun.Retried -eq 0) $outcome
 }
}
Case 'Campagne : WMI refusé mémorisé, le relevé suivant du poste se limite au ping' {
 Reset-Fixture;Ready-Run 1;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
 $p=New-Result $state.Target;$p.Outcome='Denied';Complete-DomeniaParkSession $p $state
 $script:ParkRun.Completed=$true;$script:Calls.Clear();$script:AsyncJobs.Clear();$script:Ctrl.DgObjects.Items.Clear();$script:Saves.Clear()
 Ready-Run 1;Invoke-DomeniaParkRunTick;$payload=$script:Calls[1].Payload
 Assert (-not $payload.ProbeUser -and -not $payload.Inventory -and @($payload.Probes).Count -eq 0 -and $payload.CollectPing) 'Lecture WMI renvoyée malgré le refus mémorisé'
 Assert ($script:ParkRun.CimSkipped -eq 1)
 $script:ParkRun.Completed=$true;$script:Calls.Clear();$script:AsyncJobs.Clear();$script:Ctrl.DgObjects.Items.Clear()
 $script:SettingValues['Collection.CacheMinutes']='0'
 Ready-Run 1;Invoke-DomeniaParkRunTick
 Assert ([bool]$script:Calls[1].Payload.ProbeUser) 'Relecture forcée : mémoire ignorée'
}
Case 'Campagne : requêtes WMI évitées comptées pour le relevé et la session' {
 Reset-Fixture;$before=[long]$script:DomeniaCimQueriesAvoided;Ready-Run 1;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
 $p=New-Result $state.Target;$p|Add-Member -NotePropertyName CimQueries -NotePropertyValue ([pscustomobject]@{Consumers=9;Executed=4;Avoided=5})
 Complete-DomeniaParkSession $p $state
 Assert ($script:ParkRun.CimAvoided -eq 5 -and $script:ParkRun.CimExecuted -eq 4 -and ([long]$script:DomeniaCimQueriesAvoided - $before) -eq 5)
}
Case 'Campagne : plan durable, postes validés marqués, reprise des seuls postes restants' {
 Reset-Fixture;Approve-Run 3
 Assert ($script:ParkRun.Approved -and $script:Prefs.ContainsKey('Domenia.campaign-plan.json') -and $null -ne $script:ParkRun.CampaignProgress) 'Plan non enregistré à lʼapprobation'
 Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;Complete-DomeniaParkSession (New-Result $state.Target) $state;Commit-Saved
 Assert ($script:ParkRun.CampaignProgress.DoneCount -eq 1)
 Stop-DomeniaOnlinePark;Assert $script:ParkRun.Completed
 $progress=ConvertFrom-DomeniaCampaignProgressText $script:Prefs['Domenia.campaign-progress.json']
 Assert ($progress.State -eq 'Paused' -and $progress.DoneCount -eq 1)
 $status=Get-DomeniaCampaignResumeState -Progress $progress -DomainDn $script:Conn.BaseDn -DatabasePath $script:DatabaseScopedPath
 Assert ($status.Resumable -and $status.Remaining -eq 2)
 function Start-DomeniaOnlinePark {param([object[]]$ScopeTargets,[string]$ScopeLabel,[switch]$PingOnly,[switch]$WmiOnly,[switch]$Inventory,$Probes)$script:Resumed=[pscustomobject]@{Targets=@($ScopeTargets);Label=$ScopeLabel;PingOnly=[bool]$PingOnly}}
 Start-DomeniaCampaignResume
 Assert ($null -ne $script:Resumed -and $script:Resumed.Targets.Count -eq 2 -and $script:Resumed.Targets[0].name -eq 'PC-2' -and $script:Resumed.Targets[1].name -eq 'PC-3' -and $script:Resumed.Label -match 'reprise') 'Reprise incorrecte'
 Clear-DomeniaCampaignPlan;Assert (-not (Get-DomeniaCampaignResumeStatus).Resumable)
}
Case 'Campagne : la fermeture laisse le plan avec ses postes restants' {
 Reset-Fixture;Approve-Run 2;$script:AsyncEngineClosing=$true;Invoke-DomeniaParkRunTick
 $progress=ConvertFrom-DomeniaCampaignProgressText $script:Prefs['Domenia.campaign-progress.json']
 Assert ($script:ParkRun.Completed -and $progress.State -eq 'Closed' -and $progress.DoneCount -eq 0)
 $script:AsyncEngineClosing=$false
}
Case 'Campagne : un poste WMI seul non lu pour un refus mémorisé reste dans le plan, avec son motif' {
 Reset-Fixture
 [void](Register-DomeniaCapabilityFact -Memory (Get-DomeniaCapabilityMemory) -Target 'PC-1' -Capability 'cim' -Kind 'RightDenied' -AccountGeneration ([long]$script:DomeniaAccountGeneration))
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults -WmiOnly;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 1);Busy=$false}) $call.State
 $script:AsyncJobs.Remove($call.Id);& $script:Confirm
 Invoke-DomeniaParkRunTick
 Assert ($script:Calls.Count -eq 1 -and $script:ParkRun.SkippedTargets -eq 1) 'Lecture WMI envoyée malgré le refus mémorisé'
 Invoke-DomeniaParkRunTick
 $progress=ConvertFrom-DomeniaCampaignProgressText $script:Prefs['Domenia.campaign-progress.json']
 Assert ($script:ParkRun.Completed -and $progress.DoneCount -eq 0 -and $progress.State -eq 'Incident' -and $progress.Reason -match 'non lu') ('Motif : '+$progress.Reason)
}
Case 'Campagne : hors fenêtre de collecte, la confirmation le dit et le lancement explicite reste possible' {
 Reset-Fixture;$script:SettingValues['Collection.WindowsJson']='{"Standard":"jamais"}'
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 1);Busy=$false}) $call.State
 Assert ($script:Message -match 'Hors fenêtre de collecte' -and $null -ne $script:Confirm) 'Confirmation sans mention de la fenêtre'
 $script:AsyncJobs.Remove($call.Id);& $script:Confirm;Invoke-DomeniaParkRunTick
 Assert ($script:Calls.Count -eq 2) 'Relevé explicite bloqué par la fenêtre'
}
Case 'Campagne : WMI seul, un poste éteint (serveur RPC indisponible) nʼest ni relu ni compté contre son sous-réseau' {
 Reset-Fixture;Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults -WmiOnly;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@((New-Target 1),(New-Target 2));Busy=$false}) $call.State;$script:AsyncJobs.Remove($call.Id);$script:ParkRun.Approved=$true
 $script:DomeniaTargetAddresses=@{'pc-1'='10.1.2.11';'pc-2'='10.1.2.12'}
 Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
 Assert ($state.SourceKey -eq 'site:10.1.2.0/24') ('Source '+$state.SourceKey)
 $p=New-Result $state.Target;$p.Outcome='Unavailable';$p.Presence='Non vérifié';$p.PresenceCheckedUtc='';$p.User='';$p.Detail='Lecture CIM/DCOM non confirmée. Le serveur RPC nʼest pas disponible. (0x800706BA)'
 Complete-DomeniaParkSession $p $state
 Assert ($script:ParkRun.Retry.Count -eq 0 -and $script:ParkRun.Retried -eq 0) 'Poste éteint relu'
 $entry=Get-DomeniaSourceEntry $script:ParkRun.Sources.Health 'site:10.1.2.0/24' $script:ParkRun.Sources.Policy
 Assert ([int]$entry.Limit -eq [int]$script:ParkRun.Concurrency -and [int]$entry.ConsecutiveFailures -eq 0) 'Budget du sous-réseau réduit par un poste éteint'
}
Case 'Campagne : une lecture arrêtée par le moteur nʼest relue que si son ping a répondu' {
 foreach($presence in @('','Sans réponse au ping','En ligne')){
  Reset-Fixture;Ready-Run 1;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
  Assert ([object]::ReferenceEquals($state.ReadProgress,$script:Calls[1].Payload.ReadProgress)) 'Canal de progression absent de lʼétat'
  if($presence){$state.ReadProgress['Presence']=$presence}
  Fail-DomeniaParkSession 'Délai dépassé : Console du parc : PC-1 — aucune étape terminée pendant le délai' $state
  $expected=$(if($presence -eq 'En ligne'){1}else{0})
  Assert ($script:ParkRun.Retry.Count -eq $expected) ('Ping « '+$presence+' » : '+$script:ParkRun.Retry.Count+' reprise(s)')
 }
}
Case 'Campagne : un poste relu après un incident garde ses mesures réutilisables jusquʼau dernier essai' {
 Reset-Fixture;Ready-Run 1;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
 $previous=[pscustomobject]@{Key=$state.Target.Key;Guid=$state.Target.Guid;Inventory=[pscustomobject]@{Build='26100';CheckedUtc=[datetime]::UtcNow.ToString('o')}}
 $state.Target.Previous=$previous
 $p=New-Result $state.Target;$p.Outcome='Timeout';Complete-DomeniaParkSession $p $state;Commit-Saved
 Assert ([object]::ReferenceEquals($state.Target.Previous,$previous)) 'Observation précédente libérée avant la reprise'
 $script:ParkRun.Retry[0].NotBeforeUtc=[datetime]::UtcNow.AddSeconds(-1);Invoke-DomeniaParkRunTick
 Assert ($script:Calls.Count -eq 3 -and [object]::ReferenceEquals($script:Calls[2].Payload.Previous,$previous)) 'Reprise sans lʼobservation précédente'
 $second=$script:Calls[2].State;Complete-DomeniaParkSession (New-Result $second.Target) $second;Commit-Saved 1
 Assert ($null -eq $second.Target.Previous) 'Tampon conservé après le dernier essai'
}
Case 'Campagne : plus rien à envoyer, les dernières lectures en vol ne comptent pas comme attente' {
 Reset-Fixture;Ready-Run 1;Invoke-DomeniaParkRunTick
 Assert ($script:ParkRun.Pending.Count -eq 1 -and -not (Test-DomeniaParkWorkRemaining $script:ParkRun)) 'Préparation'
 $script:ParkRun.HeldSinceUtc=[datetime]::UtcNow.AddSeconds(-3)
 Invoke-DomeniaParkRunTick;Invoke-DomeniaParkRunTick
 Assert ([double]$script:ParkRun.HeldSeconds -eq 0 -and $null -eq $script:ParkRun.HeldSinceUtc) ('Attente comptée : '+$script:ParkRun.HeldSeconds)
}
Case 'Campagne : un changement de compte arrête le relevé avec ce motif, jamais « arrêté par lʼopérateur »' {
 Reset-Fixture;Approve-Run 2;$script:DomeniaAccountGeneration=2L;Invoke-DomeniaParkRunTick
 $progress=ConvertFrom-DomeniaCampaignProgressText $script:Prefs['Domenia.campaign-progress.json']
 Assert ($script:ParkRun.Completed -and $progress.State -eq 'Incident' -and $progress.Reason -match 'changement de compte') ('État '+$progress.State+' : '+$progress.Reason)
 Assert (-not ((Get-DomeniaCampaignResumeState -Progress $progress -DomainDn $script:Conn.BaseDn -DatabasePath $script:DatabaseScopedPath).Reason -match 'opérateur')) 'Motif attribué à lʼopérateur'
}
if($null -ne $script:ParkRun -and $null -ne $script:ParkRun.Timer){$script:ParkRun.Timer.Stop()}
$failed=@($checks|Where-Object Status -eq 'Failed').Count
$report=[ordered]@{Kind='ParkDetection';Expected=39;Complete=($checks.Count -eq 39 -and $failed -eq 0);NativeWindowsPowerShell51=$true;LiveAD=$false;MockedNetwork=$true;Passed=$checks.Count-$failed;Failed=$failed;Tests=$checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path $env:TEMP 'domenia-park-tests.json'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ($report.Passed.ToString()+' reussis, '+$failed+' echecs. '+$ReportPath)
if($failed -or -not $report.Complete){exit 1};exit 0
