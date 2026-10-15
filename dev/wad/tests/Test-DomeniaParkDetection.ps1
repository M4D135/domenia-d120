#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'Domenia-Modules.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaEffectiveWorkerResult','Get-MainXaml','Start-DomeniaParkSweep','Request-DomeniaParkSweepAtStartup','Get-DomeniaSearchMode','Get-DomeniaSelectedGridRows','Show-DomeniaBatchNetworkReport')){
 $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
 . ([scriptblock]::Create($f.Extent.Text))
}
function Assert {param($Value,[string]$Why='Assertion fausse')if(-not $Value){throw $Why}}
$checks=[Collections.Generic.List[object]]::new()
function Case {param($Name,[scriptblock]$Body)try{& $Body|Out-Null;$status='Passed';$detail=''}catch{$status='Failed';$detail=$_.Exception.Message+' '+$_.ScriptStackTrace};$checks.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail});if($status -eq 'Failed'){Write-Host ($Name+': '+$detail)}}
function Set-Status {param($Text,$Level)$script:Status=$Text}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
function Initialize-DomeniaWinSqliteNative {}
function Get-DomeniaSetting {param($Name,$Default)return $Default}
# SE-05: the ceiling is read from the configuration (Park.MaxTargets).
function Get-CfgValue {param($Section,$Name,$Default)$key=[string]$Section+'.'+[string]$Name;if($script:Cfg.ContainsKey($key)){return $script:Cfg[$key]};return $Default}
function New-DomeniaObservationReader {return [pscustomobject]@{Fixture=$true}}
function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel,$Risk,[string[]]$Changes,$Details,$DetailsTitle,[switch]$DetailsExpertOnly,$TypedConfirmation,$TypedPrompt)$script:Confirm=$OnConfirm;$script:Cancel=$OnCancel;$script:Message=$Message;$script:ConfirmTitle=$Title;$script:ConfirmTarget=$Target;$script:ConfirmButton=$ConfirmText;$script:ConfirmText=$ConfirmText;$script:Preview=[pscustomobject]@{Changes=@($Changes);Details=[string]$Details;Typed=[string]$TypedConfirmation;DetailsExpertOnly=[bool]$DetailsExpertOnly}}
function Start-UiTask {
 param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TimeoutSeconds,$TaskClass,$ReplaceKey,$StatusText)
 $id='job-'+$script:Calls.Count
 $call=[pscustomobject]@{Id=$id;Name=$Name;Payload=$Payload;State=$CallbackState;OperationId=$OperationId;TimeoutSeconds=$TimeoutSeconds;TaskClass=$TaskClass;Code=$Code};$script:Calls.Add($call);$script:AsyncJobs[$id]=$call;return $id
}
# A stopped worker leaves the engine: the next tick sees it gone.
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason)$script:StopRequests.Add([string]$Id);[void]$script:AsyncJobs.Remove([string]$Id)}
function Apply-DomeniaPresenceFilter {$script:PresenceFilterApplied.Add([string]$script:CurrentPresenceFilter)}
function Queue-DomeniaMetadata {throw 'Ancien writer brut interdit.'}
function Write-AppLog {param($Text,$Level)}
function New-DomeniaTimer {param($Owner,$IntervalMs,[switch]$RunWhenHidden,$Tick)$script:TimerOwners.Add([string]$Owner);$timer=[pscustomobject]@{IsEnabled=$false};$timer|Add-Member ScriptMethod Start {$this.IsEnabled=$true};$timer|Add-Member ScriptMethod Stop {$this.IsEnabled=$false};return $timer}
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
# MO-08: one store batch carries several workstations; the receipt returns one committed row per workstation.
function Commit-PingSaved {param([int]$Index=0,[hashtable]$Presence=@{})
 $saved=$script:Saves[$Index];$state=$saved.CallbackState.State
 $rows=@(foreach($target in @($state.Targets)){$value=if($Presence.ContainsKey([string]$target.Computer)){[string]$Presence[[string]$target.Computer]}else{'En ligne'};[pscustomobject]@{Version=1;Key=[string]$target.Key;Guid=[string]$target.Guid;Computer=[string]$target.Computer;Presence=$value;PresenceCheckedUtc='2026-10-13T10:00:00Z';Outcome='PresenceOnly';Revision=18}})
 $receipt=[pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$saved.Context.StoreId;RequestId=$saved.Context.RequestId;BatchId=$saved.BatchId;ObservationRows=$rows;Observations=@();Revision=18;SnapshotRevision=18}
 & $saved.SuccessHandler -Result $receipt -State $saved.CallbackState
}

function Request-DomeniaLinkPersistence {$script:LinkSaves++}
function Get-ExistingLinkForComputer {param($Computer)return $script:Existing}
function Add-DomeniaRelation {param($Relation,[switch]$NoSave,[switch]$Quiet)$script:RelationsAdded.Add($Relation);return [pscustomobject]@{StoredChanged=$true}}
function Set-RowAssociationMetadata {param($Rows)}
function Run {param([string]$Slot='List') Get-DomeniaParkRun -Slot $Slot}
function Reset-Fixture {
 if($null -ne $script:ParkRuns){foreach($old in @($script:ParkRuns.Values)){if($null -ne $old -and $null -ne $old.Timer){$old.Timer.Stop()}}}
 $script:DomeniaRemoteStoreQueue=$null;$script:DomeniaRemoteStoreTimer=$null;$script:DomeniaAccountGeneration=1L;$script:GlobalSearchGeneration=1L;$script:ListSurveyBlocked=$false;$script:ParkRuns=$null;$script:ParkDefaultMode=$null;$script:SessionEpoch=1L;$script:DatabaseScopedPath='C:\fixture\domain.db';$script:DemoMode=$false;$script:AsyncEngineClosing=$false;$script:WriteState='Idle';$script:ActiveWriteTaskId='';$script:Persistence=$null;$script:Live=$null;$script:Existing=$null;$script:FleetLast=$null;$script:FleetObservations=@{};$script:SelectedObject=$null
 $script:SearchMode='OU';$script:SelectedBranchDn='OU=Postes,dc=example,dc=invalid';$script:CurrentPresenceFilter='Tous';$script:DomeniaQueryState=$null;$script:SearchListHasMachine=$true;$script:Cfg=@{}
 $script:Conn=[pscustomobject]@{Domain='example.invalid';BaseDn='dc=example,dc=invalid'};$script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@()
 $script:Calls=[Collections.Generic.List[object]]::new();$script:Saves=[Collections.Generic.List[object]]::new();$script:RelationsAdded=[Collections.Generic.List[object]]::new();$script:LinkSaves=0;$script:Confirm=$null;$script:Cancel=$null;$script:Message='';$script:ConfirmTitle='';$script:ConfirmTarget='';$script:ConfirmButton='';$script:Status=''
 $script:StopRequests=[Collections.Generic.List[string]]::new();$script:TimerOwners=[Collections.Generic.List[string]]::new();$script:PresenceFilterApplied=[Collections.Generic.List[string]]::new()
 $script:Ctrl=@{DgObjects=[Windows.Controls.DataGrid]::new();LblParkStatus=[Windows.Controls.TextBlock]::new();LblParkDetectionStatus=[Windows.Controls.TextBlock]::new()}
 $script:Ctrl.DgObjects.CanUserAddRows=$false
}
function Add-SurveyControls {
 # UI-23 / UX-12 / CO-19 / FI-18: the real control types of the survey of the list and of the open workstation.
 foreach($name in @('BtnParkVerify','BtnParkVerifyMenu','BtnParkOutcomeOnline','BtnParkOutcomeNoReply','BtnParkOutcomeError','BtnSelectionPing','BtnSelectionConsole','BtnComputerParkStop')){$script:Ctrl[$name]=[Windows.Controls.Button]::new()}
 foreach($name in @('LblParkProgress','LblLiveState','LblSelectionBar','LblSelectionReadState','LblComputerParkStatus')){$script:Ctrl[$name]=[Windows.Controls.TextBlock]::new()}
 foreach($name in @('UxParkProgress','PnlParkOutcome','UxSelectionBar','UxComputerParkRun')){$panel=[Windows.Controls.StackPanel]::new();$panel.Visibility='Collapsed';$script:Ctrl[$name]=$panel}
 $bar=[Windows.Controls.ProgressBar]::new();$bar.Visibility='Collapsed';$script:Ctrl.PbParkProgress=$bar
 $box=[Windows.Controls.ComboBox]::new();foreach($label in @('Tous','En ligne','Sans réponse au ping','Non vérifié','Erreur de ping')){$item=[Windows.Controls.ComboBoxItem]::new();$item.Content=$label;[void]$box.Items.Add($item)};$box.SelectedIndex=0;$script:Ctrl.CmbPresenceFilter=$box
}
function New-Target {param([int]$N=1) [pscustomobject]@{Computer=('PC-'+$N);Key=('cn=pc-'+$N+',dc=example,dc=invalid');Guid=('00000000-0000-0000-0000-'+$N.ToString('d12'));Previous=$null}}
function New-ScopeTarget {param([int]$N=1) $t=New-Target $N;[pscustomobject]@{name=$t.Computer;distinguished_name=$t.Key;object_guid=$t.Guid}}
# Widget collections: a workstation whose stored probe (Park projection) is Days old, and a run of N workstations
# of the OU shown on Accueil (scope of the lists, FI-18), added to the board (-Preapproved) unless -Confirmed.
function New-MeasuredTarget {param([int]$N,[string]$Hash,[int]$Days=3) $t=New-Target $N;$t.Previous=[pscustomobject]@{Guid=$t.Guid;Key=$t.Key;Probes=[pscustomobject]@{'disk.cfree'=[pscustomobject]@{CheckedUtc=[datetime]::UtcNow.AddDays(-$Days).ToString('o');Error='';DefinitionHash=$Hash;Succeeded=$true}}};return $t}
function Start-WidgetFixtureRun {param([int]$Count,[switch]$Confirmed)
 $probe=[pscustomobject]@{Id='disk.cfree';Namespace='root\cimv2';Class='Win32_LogicalDisk';Properties=@('FreeSpace','Size');Filter="DeviceID='C:'";Mode='First';Skip=''}
 $targets=@(for($i=1;$i -le $Count;$i++){[pscustomobject]@{name=('PC-'+$i);distinguished_name=('cn=pc-'+$i+',dc=example,dc=invalid');object_guid=(New-Target $i).Guid}})
 return [string](Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel 'Postes' -WmiOnly -NoConsole -Probes @($probe) -ReuseMaxAgeDays 30 -Preapproved:(-not $Confirmed) -Slot 'List' -WidgetBoard 'Fleet' -WidgetIds @('w1') -PassThru)
}
function Add-DisplayedMachine {[void]$script:Ctrl.DgObjects.Items.Add([pscustomobject]@{Type='Machine';Name='PC-SHOWN';DN='cn=pc-shown,dc=example,dc=invalid';Guid='00000000-0000-0000-0000-000000000999'})}
function Add-DisplayedMachines {param([int]$Count,[int]$WithoutGuid=0)
 for($i=1;$i -le $Count;$i++){$t=New-Target $i;[void]$script:Ctrl.DgObjects.Items.Add([pscustomobject]@{Type='Machine';Name=$t.Computer;DN=$t.Key;Guid=$(if($i -le $WithoutGuid){''}else{$t.Guid})})}
}
function Add-ResultRows {param([int]$Count)
 for($i=1;$i -le $Count;$i++){$t=New-Target $i;$row=New-DomeniaLiveResultRow;$row.Type='Machine';$row.Name=$t.Computer;$row.DN=$t.Key;$row.Guid=$t.Guid;[void]$script:Ctrl.DgObjects.Items.Add($row)}
}
function Ready-Run {param([int]$Count=10,[switch]$PingOnly)
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults -PingOnly:$PingOnly;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(for($i=1;$i -le $Count;$i++){New-Target $i});Busy=$false}) $call.State
 $script:AsyncJobs.Remove($call.Id)
 (Run).Approved=$true
}
function New-Result {param($Target,[string]$User='alice')
 [pscustomobject]@{Key=$Target.Key;Guid=$Target.Guid;Computer=$Target.Computer;Outcome='Observed';ConsoleAttempted=$true;ConsoleCheckedUtc=[datetime]::UtcNow.ToString('o');User=('EXAMPLE\'+$User);LinkUser=$User;UserDn=('CN='+$User+',DC=example,DC=invalid');UserGuid='00000000-0000-0000-0001-000000000001';UserUsn='5';CacheReused=$false;DirectoryAuthRejected=$false;Presence='En ligne';PresenceCheckedUtc=[datetime]::UtcNow.ToString('o');Detail='fixture';Source='Console'}
}
function New-PingResult {param($Target,[string]$Presence,[string]$Detail='fixture')
 [pscustomobject]@{Key=$Target.Key;Guid=$Target.Guid;Computer=$Target.Computer;Presence=$Presence;PresenceDetail=$Detail;PresenceCheckedUtc='2026-10-13T10:00:00Z'}
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
Case 'Point 48 : apercu exact des cibles, exclusions motivees, confirmation proportionnee' {
 Reset-Fixture
 $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
 foreach($n in 1..4){$row=New-DomeniaLiveResultRow;$row.Type=$(if($n -eq 4){'Utilisateur'}else{'Machine'});$row.Name='PC-'+$n;$row.DN='CN=PC-'+$n+',DC=example,DC=invalid';$row.Guid=$(if($n -eq 3){''}else{(New-Target $n).Guid});$rows.Add($row)}
 $script:Ctrl.DgObjects.ItemsSource=$rows
 Start-DomeniaOnlinePark -DisplayedResults -PingOnly
 $call=$script:Calls[0];Assert ($call.Payload.Targets.Count -eq 2) ('Cibles demandees : '+$call.Payload.Targets.Count)
 # The local base returns PC-1 only: PC-2 is left out by it, with its reason.
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@([pscustomobject]@{Computer='PC-1';Key='cn=pc-1,dc=example,dc=invalid';Guid=(New-Target 1).Guid;Previous=$null});Busy=$false}) $call.State
 $p=$script:Preview
 Assert ($null -ne $p) 'Aucun apercu transmis a la confirmation'
 Assert ((@($p.Changes) -join ' ') -match '1 cible exacte') ('Nombre absent : '+(@($p.Changes) -join ' | '))
 Assert ((@($p.Changes) -join ' ') -match 'PC-1 : ping ICMP') 'Changement par cible absent'
 Assert ((@($p.Changes) -join ' ') -match '3 exclue') 'Exclusions non comptees'
 Assert ($p.Details.Contains('CN=PC-1,DC=example,DC=invalid') -and $p.Details.Contains('PC-2') -and $p.Details.Contains('PC-3') -and $p.Details.Contains('PC-4')) 'Liste exacte incomplete'
 Assert ($p.Details -match 'Type Utilisateur' -and $p.Details -match 'Identité incomplète' -and $p.Details -match 'base locale') 'Motifs d exclusion absents'
 Assert (-not $p.DetailsExpertOnly) 'Liste des cibles reservee au profil Expert'
 Assert ($p.Typed -eq '') 'Saisie exigee pour une lecture de 1 poste'
 & $script:Cancel
}
Case 'Point 48 : un GUID present sous deux DN de la base, une seule cible interrogee et comptee' {
 Reset-Fixture
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults;$call=$script:Calls[0]
 # The local base can keep two active rows of one object (old and new DN): the preview lists it once, the run follows.
 $old=New-Target 1;$old.Key='cn=pc-1-ancien,ou=anciens,dc=example,dc=invalid'
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@((New-Target 1),$old,(New-Target 2));Busy=$false}) $call.State
 [void]$script:AsyncJobs.Remove($call.Id)
 $lines=(@($script:Preview.Changes) -join ' ')
 Assert ($lines -match '2 cibles exactes') $lines
 Assert ($script:Preview.Details -match 'Doublon') $script:Preview.Details
 Assert (@((Run).Targets).Count -eq 2) ('Cibles du releve : '+@((Run).Targets).Count)
 Assert ((@((Run).Targets|ForEach-Object{[string]$_.Key}) -join '|') -eq 'cn=pc-1,dc=example,dc=invalid|cn=pc-2,dc=example,dc=invalid') 'Ancien DN garde dans le releve'
 Assert ($script:Message -match '^2 postes') $script:Message
 & $script:Confirm
 foreach($i in 1..6){Invoke-DomeniaParkRunTick}
 $probed=@($script:Calls|Select-Object -Skip 1)
 Assert ($probed.Count -eq 2) ('Postes contactes : '+$probed.Count)
}
Case 'Point 48 : au-dela de 200 postes, la lecture demande de saisir le nombre de cibles' {
 Reset-Fixture;Ready-Run 201
 Assert ($script:Preview.Typed -eq '201') ('Saisie : '+$script:Preview.Typed)
 Assert ((@($script:Preview.Changes) -join ' ') -match 'Confirmation renforcée')
}
Case 'Point 48 : diagnostic reseau groupe, liste exacte de la selection, exclusions motivees, rien avant confirmation' {
 Reset-Fixture;$script:Preview=$null
 function Get-CfgValue {param($Section,$Name,$Default)return $Default}
 $rows=@(
  [pscustomobject]@{Type='Machine';Name='PC-1';DN='CN=PC-1,DC=example,DC=invalid';Guid=(New-Target 1).Guid},
  [pscustomobject]@{Type='Machine';Name='PC-2';DN='CN=PC-2,DC=example,DC=invalid';Guid=(New-Target 2).Guid},
  [pscustomobject]@{Type='Machine';Name='PC-1';DN='CN=PC-1,DC=example,DC=invalid';Guid=(New-Target 1).Guid},
  [pscustomobject]@{Type='Machine';Name='';DN='CN=SANSNOM,DC=example,DC=invalid';Guid=(New-Target 3).Guid},
  [pscustomobject]@{Type='Utilisateur';Name='alice';DN='CN=alice,DC=example,DC=invalid';Guid=(New-Target 4).Guid}
 )
 Show-DomeniaBatchNetworkReport -Rows @()
 Assert (($script:Calls.Count -eq 0) -and ($null -eq $script:Preview) -and ($script:Status -match 'Aucun poste')) 'Selection vide mal traitee'
 Show-DomeniaBatchNetworkReport -Rows $rows
 Assert ($script:Calls.Count -eq 0) 'Diagnostic lance avant confirmation'
 $p=$script:Preview;Assert ($null -ne $p) 'Aucun apercu transmis a la confirmation'
 $lines=(@($p.Changes) -join ' ')
 Assert ($lines -match '2 cibles exactes') $lines
 Assert ($lines -match 'PC-1 : écho ICMP puis ports TCP 445, 135, 5985 et 5986') $lines
 Assert ($lines -match '3 exclue') $lines
 Assert ($lines -match 'Impact : un poste après lʼautre') $lines
 Assert ($p.Details -match 'Doublon' -and $p.Details -match 'Nom de poste absent' -and $p.Details -match 'Type Utilisateur') $p.Details
 Assert ($p.Typed -eq '') 'Saisie exigee pour une lecture de 2 postes'
 & $script:Confirm
 Assert ($script:Calls.Count -eq 1 -and $script:Calls[0].OperationId -eq 'BatchNetworkDiag') 'Diagnostic non lance apres confirmation'
 $names=(@($script:Calls[0].Payload.Rows|ForEach-Object{$_.Name}) -join ',')
 Assert ($names -eq 'PC-1,PC-2') ('Cibles envoyees : '+$names)
}
Case 'Point 48 : diagnostic reseau groupe borne a 50 postes, les suivants nommes' {
 Reset-Fixture;$script:Preview=$null
 function Get-CfgValue {param($Section,$Name,$Default)return $Default}
 $rows=@(for($i=1;$i -le 52;$i++){[pscustomobject]@{Type='Machine';Name=('PC-'+$i);DN=('CN=PC-'+$i+',DC=example,DC=invalid');Guid=(New-Target $i).Guid}})
 Show-DomeniaBatchNetworkReport -Rows $rows
 Assert ($script:Preview.Details -match 'PC-51 — Au-delà de la limite de 50' -and $script:Preview.Details -match 'PC-52 — Au-delà') $script:Preview.Details
 & $script:Confirm
 Assert (@($script:Calls[0].Payload.Rows).Count -eq 50) 'Limite de 50 postes non appliquee'
}
Case 'Resultats : vide ne retombe jamais sur tout le parc' {Reset-Fixture;Start-DomeniaOnlinePark -DisplayedResults;Assert ($script:Calls.Count -eq 0 -and $null -eq (Run))}
Case 'Parc : lecture locale avant confirmation et aucun poste sans confirmation' {Reset-Fixture;Ready-Run;Assert ($script:Calls.Count -eq 1 -and $null -ne $script:Confirm -and $null -eq (Run).Timer);& $script:Cancel;Assert (Run).Completed;Assert ($script:Calls.Count -eq 1)}
Case 'Parc : timer ne peut pas commencer avant approbation du perimetre' {Reset-Fixture;Ready-Run;(Run).Approved=$false;Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 1)}
Case 'Parc : ancienne annulation ne peut pas arreter un nouveau releve' {Reset-Fixture;Ready-Run;$cancel=$script:Cancel;(Run).Id='new-run';& $cancel;Assert (-not (Run).Stopping)}
Case 'Parc : quatre lectures au maximum et un depart par tick' {Reset-Fixture;Ready-Run 151;1..10|ForEach-Object{Invoke-DomeniaParkRunTick};Assert ((Run).Pending.Count -eq 4 -and (Run).Next -eq 4 -and (Run).Targets.Count -eq 151)}
Case 'Parc : arret ne lance plus rien et garde le resultat en vol' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;Stop-DomeniaOnlinePark;Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 2);Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:Saves.Count -eq 1 -and $script:RelationsAdded.Count -eq 0 -and (Run).Done -eq 0);Invoke-DomeniaParkRunTick;Assert (-not (Run).Completed);Commit-Saved;Invoke-DomeniaParkRunTick;Assert (Run).Completed}
Case 'Parc : meme callback ne peut pas etre applique deux fois' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$packet=New-Result $state.Target;Complete-DomeniaParkSession $packet $state;Complete-DomeniaParkSession $packet $state;Assert ($script:Saves.Count -eq 1 -and (Run).Done -eq 0);Commit-Saved;Commit-Saved;Assert ((Run).Done -eq 1)}
Case 'Parc : ancien contexte enregistre sans publication ni association' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$script:SessionEpoch++;Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:Saves.Count -eq 1 -and $script:RelationsAdded.Count -eq 0);Commit-Saved;Assert ((Run).Done -eq 0);Invoke-DomeniaParkRunTick;Assert (Run).Completed}
Case 'Parc : association manuelle ou importee protegee meme si changee pendant lecture' {
 foreach($source in @(' Manual ','import csv','Saisie manuelle')){Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$script:Existing=[pscustomobject]@{Source=$source;UserLogin='bob'};Complete-DomeniaParkSession (New-Result $state.Target) $state;Assert ($script:RelationsAdded.Count -eq 0 -and $script:Saves.Count -eq 1)}
}
Case 'Parc : utilisateur inchange ne reecrit pas association ni historique' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$p=New-Result $state.Target;$p.CacheReused=$true;$script:Existing=[pscustomobject]@{Source='Console';UserLogin='alice';UserGuid=$p.UserGuid;ComputerGuid=$p.Guid};Complete-DomeniaParkSession $p $state;Assert ($script:RelationsAdded.Count -eq 0 -and $script:LinkSaves -eq 0 -and (Run).Done -eq 0 -and $script:Saves.Count -eq 1)}
Case 'Parc : echec date de la tentative sans fausse nouvelle reussite' {
 Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$previous=ConvertTo-DomeniaParkSession (New-Result $state.Target) $null '2000-01-01T00:00:00Z';$state.Target.Previous=$previous
 Fail-DomeniaParkSession 'timeout fixture' $state
 Assert ($script:Saves[0].Changes.Count -eq 2 -and @($script:Saves[0].Changes|Where-Object{$_.Status -ne 'Error' -or $_.ObservedAtUtc}).Count -eq 0 -and $script:RelationsAdded.Count -eq 0 -and $previous.ObservedUtc -eq '2000-01-01T00:00:00Z')
}
Case 'Parc : compte refuse arrete les nouvelles lectures sans rejeu' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;$p=New-Result $state.Target;$p.Outcome='AuthRejected';Complete-DomeniaParkSession $p $state;Invoke-DomeniaParkRunTick;Assert ((Run).Stopping -and $script:Calls.Count -eq 2 -and $script:RelationsAdded.Count -eq 0)}
Case 'Parc : annulation centrale ou disparition du worker arrete la suite' {Reset-Fixture;Ready-Run;Invoke-DomeniaParkRunTick;$script:AsyncJobs.Clear();Invoke-DomeniaParkRunTick;Assert ((Run).Stopping -and $script:Calls.Count -eq 2)}
Case 'Parc : pression du stockage suspend les nouvelles lectures' {Reset-Fixture;Ready-Run;$script:Persistence=[pscustomobject]@{Pending=@{};LinkBusy=$true;Failures=0;Conflicts=@{}};Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 1)}
Case 'Parc : console reconfirmee maintenant meme si identite LDAP reutilisee' {
 Reset-Fixture;$target=New-Target;$packet=New-Result $target
 $previous=ConvertTo-DomeniaParkSession $packet $null '2026-01-01T00:00:00Z';$packet.CacheReused=$true
 $next=ConvertTo-DomeniaParkSession $packet $previous '2026-10-05T00:00:00Z'
 Assert ($next.ObservedUtc -eq '2026-10-05T00:00:00Z' -and $previous.ObservedUtc -eq '2026-01-01T00:00:00Z')
}
Case 'Parc : fin attend aussi le timer de sauvegarde des associations' {
 Reset-Fixture;Ready-Run 1;(Run).Next=1
 $script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=0;Conflicts=@{};LinkBusy=$false;LinkRequestTimer=[pscustomobject]@{IsEnabled=$true};LinkPersistenceMore=$false}
 Invoke-DomeniaParkRunTick;Assert (-not (Run).Completed) 'Releve termine avant la file des associations.'
 $script:Persistence.LinkRequestTimer.IsEnabled=$false;Invoke-DomeniaParkRunTick;Assert (Run).Completed
}
Case 'Parc : arret attend la sauvegarde deja demandee' {
 Reset-Fixture;Ready-Run 1;(Run).Next=1
 $script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=0;Conflicts=@{};LinkBusy=$false;LinkRequestTimer=[pscustomobject]@{IsEnabled=$true};LinkPersistenceMore=$false}
 Stop-DomeniaOnlinePark;Assert (-not (Run).Completed -and (Run).Stopping)
 $script:Persistence.LinkRequestTimer.IsEnabled=$false;Invoke-DomeniaParkRunTick;Assert (Run).Completed
}
Case 'Parc : nouveau releve attend une association encore dans le timer de sauvegarde' {
 Reset-Fixture;$script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=0;Conflicts=@{};LinkBusy=$false;LinkRequestTimer=[pscustomobject]@{IsEnabled=$true};LinkPersistenceMore=$false}
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults;Assert ($script:Calls.Count -eq 0)
}
Case 'Parc entier : retire, aucune lecture sans la liste affichee (decision 2026-10-05)' {Reset-Fixture;Add-DisplayedMachine;Start-DomeniaOnlinePark;Start-DomeniaParkSweep;Assert ($script:Calls.Count -eq 0 -and $null -eq (Run))}

Case 'WMI seul : aucune presence ICMP ni validation LDAP implicite' {
 Reset-Fixture;Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults -WmiOnly -Inventory
 $call=$script:Calls[0];Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target);Busy=$false}) $call.State;$script:AsyncJobs.Remove($call.Id);(Run).Approved=$true
 Invoke-DomeniaParkRunTick;$payload=$script:Calls[1].Payload
 Assert (-not $payload.CollectPing -and -not $payload.ValidateConsoleIdentity -and $payload.Inventory -and $payload.ProbeUser)
}
Case 'Widget : sondes seules, sans console ni ping, lancees au geste sous la limite ; poste deja mesure non contacte' {
 Reset-Fixture
 $id=Start-WidgetFixtureRun 2
 Assert ([string]$id -and (Run).NoConsole -and (Run).Preapproved -and (Run).ReuseMaxAgeDays -eq 30 -and (Run).Slot -eq 'List' -and (Run).ScopeKind -eq 'Scope') 'Releve du widget mal prepare'
 Assert ((@($script:Calls[0].Payload.ObservationFamilies) -join ',') -eq 'Probe:disk.cfree') ('Familles relues : '+(@($script:Calls[0].Payload.ObservationFamilies) -join ','))
 $hash=[string]@((Run).Probes)[0].DefinitionHash
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@((New-MeasuredTarget 1 $hash),(New-Target 2));Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 # The stored measurements are checked first, by the run timer of the scope, before any approval or read.
 Assert (((Run).Planning) -and (-not (Run).Approved) -and ($null -ne (Run).Timer) -and ((Run).Timer.IsEnabled) -and ($null -eq $script:Confirm) -and ($script:TimerOwners -contains 'Timer:ParkRun:List')) 'Mesures enregistrees non verifiees avant le releve'
 Invoke-DomeniaParkRunTick
 Assert ((-not (Run).Planning) -and ((Run).Approved) -and ($null -eq $script:Confirm)) 'Geste du widget redemande une confirmation sous la limite'
 Assert (($script:Calls.Count -eq 1) -and ((Run).AlreadyFresh -eq 1) -and ((Run).Done -eq 0) -and ((Run).Targets.Count -eq 1) -and ([string](Run).Targets[0].Computer -eq 'PC-2')) 'Poste deja mesure contacte'
 Assert ([string]$script:Status -like 'Collecte du widget lancée : 1 poste de Postes · 1 poste déjà à jour, non contacté. Ce qui sera lu : 1 requête du widget, en lecture seule.') ([string]$script:Status)
 Invoke-DomeniaParkRunTick
 $payload=$script:Calls[1].Payload
 Assert ([string]$payload.Computer -eq 'PC-2' -and $script:Calls[1].State.Slot -eq 'List') ('Poste lu : '+[string]$payload.Computer)
 Assert (-not $payload.CollectPing -and -not $payload.ProbeUser -and -not $payload.Inventory -and @($payload.Probes).Count -eq 1) 'Lecture du widget : console, ping ou inventaire en trop'
 Fail-DomeniaParkSession 'delai fixture' $script:Calls[1].State
 Assert (@($script:Saves[0].Changes).Count -eq 1 -and [string]$script:Saves[0].Changes[0].Family -eq 'Probe:disk.cfree' -and [string]$script:Saves[0].Changes[0].Status -eq 'Error') 'Echec de sonde non date ou console inventee'
}
Case 'Widget : au-dela de la limite, le nombre de postes est confirme avant toute lecture, avec le texte en trois lignes' {
 Reset-Fixture
 $targets=@(for($i=1;$i -le 201;$i++){New-ScopeTarget $i})
 [void](Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel 'Postes' -PingOnly -Preapproved -Slot 'List' -WidgetBoard 'Fleet' -WidgetIds @('w2') -PassThru)
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(for($i=1;$i -le 201;$i++){New-Target $i});Busy=$false}) $script:Calls[0].State
 Assert ($null -ne $script:Confirm -and -not (Run).Approved) 'Grand perimetre lance sans confirmation'
 $lines=@([string]$script:Message -split "`r`n")
 Assert ($lines.Count -eq 3 -and $lines[0] -eq '201 postes de Postes · plus de 200 postes à lire : nombre confirmé avant toute lecture') ([string]$script:Message)
 Assert ($lines[1] -eq 'Ce qui sera lu : présence, en lecture seule.') $lines[1]
 # The button names the reads of the widget and carries the count, never a console session it does not read.
 Assert ($script:ConfirmButton -eq 'Collecter 201 postes' -and $script:ConfirmTitle -eq 'Collecter pour le widget' -and $script:ConfirmTarget -eq 'Postes') ($script:ConfirmButton+' | '+$script:ConfirmTitle+' | '+$script:ConfirmTarget)
}
Case 'Widget : postes deja mesures comptes avant l admission, par tranches bornees, sans aucune lecture' {
 Reset-Fixture;Add-SurveyControls
 [void](Start-WidgetFixtureRun 260)
 $hash=[string]@((Run).Probes)[0].DefinitionHash
 # 250 workstations already measured, 10 never measured: 10 to read, under the limit, so no confirmation.
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(@(for($i=1;$i -le 250;$i++){New-MeasuredTarget $i $hash})+@(for($i=251;$i -le 260;$i++){New-Target $i}));Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 Assert (((Run).Planning) -and ($null -eq $script:Confirm)) 'Admission avant la verification des mesures'
 # One slice is bounded in count (and in time by default): many workstations per tick, never the whole OU at once.
 Invoke-DomeniaParkPlanStep -Run (Run) -MaxTargets 100 -BudgetMs 600000
 Assert (((Run).Planning) -and ([int](Run).PlanNext -eq 100) -and ([int](Run).AlreadyFresh -eq 100)) ('Tranche : '+(Run).PlanNext)
 Assert ([string]$script:Ctrl.LblParkStatus.Text -like 'Préparation de la collecte : 100/260*') ([string]$script:Ctrl.LblParkStatus.Text)
 # FI-18: the survey of the OU of Accueil shows beside Vérifier la liste what it does, and stops from there.
 Assert ([string]$script:Ctrl.LblParkProgress.Text -like 'Relevé de Postes · Recherche des mesures manquantes · 100/260 poste(s) · 100 déjà à jour') ([string]$script:Ctrl.LblParkProgress.Text)
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Annuler le relevé' -and $script:Ctrl.BtnParkVerify.IsEnabled) ([string]$script:Ctrl.BtnParkVerify.Content)
 Invoke-DomeniaParkPlanStep -Run (Run) -BudgetMs 600000
 Assert ((-not (Run).Planning) -and ((Run).Approved) -and ($null -eq $script:Confirm)) 'Reste sous la limite : confirmation demandee'
 Assert (([int](Run).AlreadyFresh -eq 250) -and ((Run).Targets.Count -eq 10) -and ([string](Run).Targets[0].Computer -eq 'PC-251') -and ((Run).TargetsByKey.Count -eq 10)) ('A lire : '+(Run).Targets.Count)
 Assert ($script:Calls.Count -eq 1) 'Poste contacte pendant la verification'
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Arrêter (0/10)') ([string]$script:Ctrl.BtnParkVerify.Content)
 # With the default budget the timer goes through every slice, never more ticks than workstations.
 Reset-Fixture
 [void](Start-WidgetFixtureRun 50)
 $hash=[string]@((Run).Probes)[0].DefinitionHash
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(for($i=1;$i -le 50;$i++){New-MeasuredTarget $i $hash});Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 $ticks=0;while(((Run).Planning) -and ($ticks -lt 50)){Invoke-DomeniaParkRunTick;$ticks++}
 Assert ((-not (Run).Planning) -and ($ticks -lt 50)) ('Verification non terminee en '+$ticks+' ticks')
}
Case 'Widget : chaque poste deja mesure, le releve se termine sans contact ni approbation ; au-dela de la limite apres verification, confirmation' {
 Reset-Fixture
 [void](Start-WidgetFixtureRun 3)
 $hash=[string]@((Run).Probes)[0].DefinitionHash
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(for($i=1;$i -le 3;$i++){New-MeasuredTarget $i $hash});Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 Invoke-DomeniaParkRunTick
 Assert (((Run).Completed) -and (-not (Run).Approved) -and ((Run).AlreadyFresh -eq 3) -and ($script:Calls.Count -eq 1) -and (-not (Run).Timer.IsEnabled)) 'Releve du widget a jour non termine'
 Assert ([string]$script:Status -like 'Widget à jour : 3 poste(s) de Postes*aucun poste contacté.') ([string]$script:Status)
 Assert ($null -eq $script:Confirm -and -not (Test-DomeniaParkRunActive -Slot 'List')) 'Confirmation demandee sans lecture, ou liste bloquee'
 # 201 workstations left to read once the measured ones are set aside: the count to read is confirmed.
 Reset-Fixture
 [void](Start-WidgetFixtureRun 211)
 $hash=[string]@((Run).Probes)[0].DefinitionHash
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(@(for($i=1;$i -le 10;$i++){New-MeasuredTarget $i $hash})+@(for($i=11;$i -le 211;$i++){New-Target $i}));Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 Invoke-DomeniaParkPlanStep -Run (Run) -BudgetMs 600000
 Assert (($null -ne $script:Confirm) -and (-not (Run).Approved) -and (-not (Run).Timer.IsEnabled)) 'Plus de 200 postes a lire sans confirmation'
 $lines=@([string]$script:Message -split "`r`n")
 Assert ($lines[0] -eq '201 postes de Postes · 10 postes déjà à jour, non contactés · plus de 200 postes à lire : nombre confirmé avant toute lecture') $lines[0]
 Assert ($lines[1] -eq 'Ce qui sera lu : 1 requête du widget, en lecture seule.' -and $lines[2] -like '*Seules les mesures absentes, en erreur ou de plus de 30 jours sont relues.') ($lines[1]+' | '+$lines[2])
 Assert ($script:ConfirmButton -eq 'Collecter 201 postes') $script:ConfirmButton
 & $script:Confirm
 Assert (((Run).Approved) -and ((Run).Timer.IsEnabled)) 'Confirmation sans reprise du releve'
 Invoke-DomeniaParkRunTick
 Assert (($script:Calls.Count -eq 2) -and ([string]$script:Calls[1].Payload.Computer -eq 'PC-11')) 'Premier poste a lire'
}
Case 'Widget : plafond du releve (Park.MaxTargets) sur les postes a lire, meme apres le geste d ajout ; rien n est lu au-dela' {
 # Collect only what is missing: 8 workstations, 2 already measured, 6 left to read over a ceiling of 5.
 Reset-Fixture;$script:Cfg['Park.MaxTargets']=5
 [void](Start-WidgetFixtureRun 8)
 $hash=[string]@((Run).Probes)[0].DefinitionHash
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(@(for($i=1;$i -le 2;$i++){New-MeasuredTarget $i $hash})+@(for($i=3;$i -le 8;$i++){New-Target $i}));Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 Invoke-DomeniaParkPlanStep -Run (Run) -BudgetMs 600000
 Assert (((Run).Completed) -and (-not (Run).Approved) -and ($null -eq $script:Confirm) -and ($script:Calls.Count -eq 1) -and (-not (Run).Timer.IsEnabled)) 'Releve du widget lance au-dela du plafond'
 Assert ([string]$script:Status -eq 'Collecte du widget non lancée : 6 postes à lire pour ce widget : plafond 5 (réglage Park.MaxTargets). Choisissez une OU plus petite dans Rechercher.') ([string]$script:Status)
 Assert (-not (Test-DomeniaParkRunActive -Slot 'List')) 'Releve refuse encore actif'
 # Under the ceiling once the measured ones are set aside: 5 to read, started at once (added widget).
 Reset-Fixture;$script:Cfg['Park.MaxTargets']=5
 [void](Start-WidgetFixtureRun 8)
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(@(for($i=1;$i -le 3;$i++){New-MeasuredTarget $i ([string]@((Run).Probes)[0].DefinitionHash)})+@(for($i=4;$i -le 8;$i++){New-Target $i}));Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 Invoke-DomeniaParkPlanStep -Run (Run) -BudgetMs 600000
 Assert (((Run).Approved) -and ((Run).Targets.Count -eq 5) -and ($null -eq $script:Confirm)) 'Sous le plafond apres verification : collecte refusee'
 # A refresh reads every workstation again: the population itself is refused before any local read.
 Reset-Fixture;$script:Cfg['Park.MaxTargets']=5
 [void](Start-DomeniaOnlinePark -ScopeTargets @(for($i=1;$i -le 6;$i++){New-ScopeTarget $i}) -ScopeLabel 'Postes' -WmiOnly -NoConsole -Probes @([pscustomobject]@{Id='disk.cfree';Class='Win32_LogicalDisk';Properties=@('FreeSpace')}) -ForceRefresh -Slot 'List' -WidgetBoard 'Fleet' -WidgetIds @('w1') -PassThru)
 Assert ($script:Calls.Count -eq 0 -and $null -eq (Run) -and [string]$script:Status -like '*6 postes à lire pour ce widget : plafond 5*') ([string]$script:Status)
}
Case 'Widget : actualisation ou reprise, le nombre est toujours confirme ; le poste ouvert a sa propre portee (FI-18)' {
 # Refresh and resume of a widget are not the add gesture: one workstation is confirmed too.
 Reset-Fixture;Add-SurveyControls
 [void](Start-WidgetFixtureRun 2 -Confirmed)
 $hash=[string]@((Run).Probes)[0].DefinitionHash
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@((New-MeasuredTarget 1 $hash),(New-Target 2));Busy=$false}) $script:Calls[0].State
 $script:AsyncJobs.Remove($script:Calls[0].Id)
 Invoke-DomeniaParkRunTick
 Assert ($null -ne $script:Confirm -and -not (Run).Approved -and $script:ConfirmButton -eq 'Collecter 1 poste' -and $script:Calls.Count -eq 1) ('Reprise lancee sans confirmation : '+$script:ConfirmButton)
 Assert ([string]$script:Ctrl.LblParkProgress.Text -eq 'Relevé de Postes · Confirmation en attente · 1 poste') ([string]$script:Ctrl.LblParkProgress.Text)
 # A widget of the open workstation reads in the scope of that workstation, beside the survey of the list.
 $open=New-ScopeTarget 77
 $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-77';DN=$open.distinguished_name;Safety=[pscustomobject]@{Guid=$open.object_guid}}
 $id=[string](Start-DomeniaOnlinePark -ScopeTargets @($open) -ScopeLabel 'PC-77' -WmiOnly -NoConsole -Probes @([pscustomobject]@{Id='disk.cfree';Class='Win32_LogicalDisk';Properties=@('FreeSpace')}) -ForceRefresh -Slot 'Computer' -WidgetBoard 'Computer' -WidgetIds @('c1') -PassThru)
 Assert ($id -and (Run 'Computer').Id -eq $id -and -not (Run).Stopping -and $script:Calls.Count -eq 2 -and $script:Calls[1].State.Slot -eq 'Computer') 'Widget du poste bloque ou remplace par la liste'
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 77);Busy=$false}) $script:Calls[1].State
 Assert ($script:ConfirmButton -eq 'Collecter 1 poste' -and $script:ConfirmTarget -eq 'PC-77' -and -not (Run 'Computer').Planning) ($script:ConfirmButton+' | '+$script:ConfirmTarget)
}
# Point 60 (W08) with UI-23 / FO-18 (X01): « Vérifier la liste ▾ » reads the scope chosen beside the results. With
# « Lignes sélectionnées », its three readings go through the survey of the selection (same ceiling, same three-line
# confirmation naming the selection); nothing is contacted before the confirmation.
Case 'Portee choisie : Verifier la liste lit les lignes selectionnees, avec la confirmation et le plafond de la selection' {
 function Set-ResultScope {param([int]$Index)$box=[Windows.Controls.ComboBox]::new();foreach($tag in @('Visible','Selected')){$item=[Windows.Controls.ComboBoxItem]::new();$item.Tag=$tag;[void]$box.Items.Add($item)};$box.SelectedIndex=$Index;$script:Ctrl.CmbResultScope=$box}
 $readings=@(
  @{Mode='Ping';Title='Vérifier la sélection : qui répond ?';Button='Pinger 2 postes';Inventory=$false},
  @{Mode='Console';Title='Vérifier la sélection : qui est connecté ?';Button='Vérifier 2 postes';Inventory=$false},
  @{Mode='Analyse';Title='Vérifier la sélection : matériel et widgets';Button='Analyser 2 postes';Inventory=$true}
 )
 foreach($case in $readings){
  Reset-Fixture;Add-SurveyControls;Add-DisplayedMachines 4;Set-ResultScope 1
  $rows=@($script:Ctrl.DgObjects.Items)
  [void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[3]);[void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[1])
  $script:ConfirmTitle='';$script:ConfirmTarget='';$script:ConfirmButton=''
  Invoke-DomeniaParkVerify -Mode $case.Mode
  Assert ($script:Calls.Count -eq 1 -and [string](Run).ScopeKind -eq 'Selection' -and [bool](Run).Inventory -eq [bool]$case.Inventory) ('Releve de la selection absent pour '+$case.Mode)
  $names=(@($script:Calls[0].Payload.Targets|ForEach-Object{[string]$_.name}) -join ',')
  Assert ($names -eq 'PC-2,PC-4') ('Postes envoyes (ordre affiche attendu) : '+$names)
  Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@((New-Target 2),(New-Target 4));Busy=$false}) $script:Calls[0].State
  Assert ($script:ConfirmTitle -ceq $case.Title -and $script:ConfirmTarget -eq 'la sélection' -and $script:ConfirmButton -ceq $case.Button) ($script:ConfirmTitle+' | '+$script:ConfirmTarget+' | '+$script:ConfirmButton)
  Assert ($null -eq (Run).Timer -and $script:Calls.Count -eq 1) 'Un poste a ete contacte avant la confirmation.'
 }
 Assert ((Get-DomeniaParkVerifyButtonText) -eq 'Vérifier la sélection : Matériel et widgets') (Get-DomeniaParkVerifyButtonText)
 # Nothing selected: the statement of the scope says so and nothing is read.
 Reset-Fixture;Add-SurveyControls;Add-DisplayedMachines 2;Set-ResultScope 1
 Invoke-DomeniaParkVerify -Mode Ping
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like 'Aucune ligne sélectionnée*') ([string]$script:Status)
 # The list as shown stays the default scope.
 Reset-Fixture;Add-SurveyControls;Add-DisplayedMachines 2;Set-ResultScope 0
 [void]$script:Ctrl.DgObjects.SelectedItems.Add(@($script:Ctrl.DgObjects.Items)[0])
 Invoke-DomeniaParkVerify -Mode Ping
 Assert ($script:Calls.Count -eq 1 -and [string](Run).ScopeKind -eq 'Results' -and @($script:Calls[0].Payload.Targets).Count -eq 2) 'La liste affichee nʼest plus la portee par defaut.'
}
Case 'Ping et WMI exclusifs : demande ambigue refusee avant cible' {
 Reset-Fixture;Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults -PingOnly -WmiOnly
 Assert ($script:Calls.Count -eq 0 -and $null -eq (Run))
}

# ---------------------------------------------------------------- SE-05: ceiling of a survey of the list
Case 'SE-05 : 501 postes affiches refuses avant toute tache' {
 Reset-Fixture;Add-DisplayedMachines 501;Start-DomeniaOnlinePark -DisplayedResults -PingOnly
 Assert ($script:Calls.Count -eq 0 -and $null -eq (Run)) 'Releve prepare au-dela du plafond.'
 Assert ([string]$script:Status -like '*501 postes affichés : plafond 500. Filtrez la liste.*') ([string]$script:Status)
}
Case 'SE-05 : plafond regle par Park.MaxTargets' {
 Reset-Fixture;$script:Cfg['Park.MaxTargets']=2;Add-DisplayedMachines 3;Start-DomeniaOnlinePark -DisplayedResults
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like '*3 postes affichés : plafond 2.*') ([string]$script:Status)
 Reset-Fixture;$script:Cfg['Park.MaxTargets']=2;Add-DisplayedMachines 2;Start-DomeniaOnlinePark -DisplayedResults
 Assert ($script:Calls.Count -eq 1 -and @($script:Calls[0].Payload.Targets).Count -eq 2) 'Liste sous le plafond refusee.'
}
Case 'SE-05 : racine du domaine sans filtre et recherche globale sans terme refusees, aucune tache' {
 Reset-Fixture;$script:SelectedBranchDn=$script:Conn.BaseDn;Add-DisplayedMachines 3;Start-DomeniaOnlinePark -DisplayedResults
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like '*racine du domaine*') ([string]$script:Status)
 Reset-Fixture;$script:SearchMode='Global';$script:Ctrl.TxtGlobalSearch=[Windows.Controls.TextBox]::new();Add-DisplayedMachines 3;Start-DomeniaOnlinePark -DisplayedResults
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like '*Recherche globale sans terme*') ([string]$script:Status)
 Reset-Fixture;$script:SearchMode='Global';$script:Ctrl.TxtGlobalSearch=[Windows.Controls.TextBox]::new();$script:Ctrl.TxtGlobalSearch.Text='PC-';Add-DisplayedMachines 3;Start-DomeniaOnlinePark -DisplayedResults
 Assert ($script:Calls.Count -eq 1) 'Recherche globale avec terme refusee.'
}

Case 'SE-05 : Ctrl+A sur la racine du domaine sans filtre puis Pinger est refuse, aucune tache' {
 Reset-Fixture;Add-SurveyControls;$script:SelectedBranchDn=$script:Conn.BaseDn;Add-DisplayedMachines 4
 function Get-DomeniaSelectedGridRows {return @($script:Picked)}
 $script:Picked=@($script:Ctrl.DgObjects.Items)
 Start-DomeniaParkSelectionSurvey -Mode Ping
 Assert ($script:Calls.Count -eq 0 -and $null -eq (Run)) 'Toute la racine du domaine relevee par la selection.'
 Assert ([string]$script:Status -like '*Toute la liste est sélectionnée*racine du domaine*') ([string]$script:Status)
 # A real choice among the rows stays its own filter.
 $script:Picked=@(@($script:Ctrl.DgObjects.Items)[0..1])
 Start-DomeniaParkSelectionSurvey -Mode Ping
 Assert ($script:Calls.Count -eq 1 -and @($script:Calls[0].Payload.Targets).Count -eq 2) 'Choix de deux postes refuse.'
 # A global search without a term: selecting every row is refused the same way.
 Reset-Fixture;$script:SearchMode='Global';$script:Ctrl.TxtGlobalSearch=[Windows.Controls.TextBox]::new();Add-DisplayedMachines 3
 $script:Picked=@($script:Ctrl.DgObjects.Items)
 Start-DomeniaParkSelectionSurvey -Mode Console
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like '*Toute la liste est sélectionnée*Recherche globale sans terme*') ([string]$script:Status)
}

# ---------------------------------------------------------------- UX-24: three-line confirmation
Case 'UX-24 : confirmation en trois lignes, cible lisible, ecart explique, bouton chiffre' {
 Reset-Fixture;Add-DisplayedMachines 3 -WithoutGuid 1;Start-DomeniaOnlinePark -DisplayedResults -PingOnly
 $call=$script:Calls[0];Assert (@($call.Payload.Targets).Count -eq 2) 'Ligne sans identifiant envoyee.'
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 2;New-Target 3);Busy=$false}) $call.State
 $lines=@([string]$script:Message -split "`r`n")
 Assert ($lines.Count -eq 3) ([string]$script:Message)
 Assert ($lines[0] -eq '2 postes affichés (OU Postes) · 1 ligne sans identifiant AD ignorée') $lines[0]
 Assert ($lines[1] -eq 'Ce qui sera lu : présence, en lecture seule.') $lines[1]
 Assert ($script:ConfirmButton -eq 'Pinger 2 postes' -and $script:ConfirmTarget -eq 'OU Postes' -and $script:ConfirmTitle -eq 'Vérifier la liste : qui répond ?') ($script:ConfirmButton+' | '+$script:ConfirmTarget+' | '+$script:ConfirmTitle)
 Assert ([string]$script:ConfirmTarget -notmatch 'example') 'La cible annonce le domaine.'
 Assert ($null -eq (Run).Timer -and -not (Run).Approved) 'Releve lance avant la confirmation.'
}

# ---------------------------------------------------------------- MO-08 / CO-19: batch ping and distinct counters
Case 'MO-08 : un seul job ParkPing pour 200 postes, echos par lots de 32, aucune lecture de console' {
 Reset-Fixture;Ready-Run 200 -PingOnly
 1..5|ForEach-Object{Invoke-DomeniaParkRunTick}
 Assert ($script:Calls.Count -eq 2) ('Taches : '+$script:Calls.Count)
 $ping=$script:Calls[1]
 Assert ($ping.OperationId -eq 'ParkPing' -and $ping.TaskClass -eq 'Explicit' -and @($ping.Payload.Targets).Count -eq 200 -and [int]$ping.Payload.BatchSize -eq 32 -and [int]$ping.Payload.TimeoutMs -eq 1000) 'Charge du ping de liste'
 # 7 batches of 32, each up to 2.5 s of name resolution + 2 s of echoes + 1 s of work, plus 20 s.
 Assert ([int]$ping.TimeoutSeconds -eq 62) ('Delai du job : '+$ping.TimeoutSeconds)
 Assert ($ping.Code -ceq (Get-DomeniaParkPingWorkerCode)) 'Corps epingle ParkPing non utilise.'
 Assert (@($script:Calls|Where-Object{$_.OperationId -eq 'LiveConsole'}).Count -eq 0) 'Lecture de console pendant un ping.'
 Assert ($null -ne $ping.Payload.Progress -and [object]::ReferenceEquals($ping.Payload.Progress,(Run).PingQueue)) 'File de progression absente.'
}
Case 'CO-19 : en ligne, sans reponse et erreur DNS comptes a part, stockes en un lot' {
 Reset-Fixture;Ready-Run 3 -PingOnly;Invoke-DomeniaParkRunTick
 $ping=$script:Calls[1];$t1=New-Target 1;$t2=New-Target 2;$t3=New-Target 3
 (Run).PingQueue.Enqueue([pscustomobject]@{Results=@((New-PingResult $t1 'En ligne'),(New-PingResult $t2 'Sans réponse au ping'))})
 Complete-DomeniaParkPingJob ([pscustomobject]@{Results=@((New-PingResult $t1 'En ligne'),(New-PingResult $t2 'Sans réponse au ping'),(New-PingResult $t3 'Erreur de ping' 'Résolution DNS impossible : hote inconnu'));Count=3;Completed=$true}) $ping.State
 Invoke-DomeniaParkRunTick
 Assert ($script:Saves.Count -eq 1 -and @($script:Saves[0].Changes).Count -eq 3) ('Lots : '+$script:Saves.Count)
 Commit-PingSaved 0 @{'PC-1'='En ligne';'PC-2'='Sans réponse au ping';'PC-3'='Erreur de ping'}
 Invoke-DomeniaParkRunTick
 $r=Run
 Assert ($r.Completed -and $r.Done -eq 3 -and $r.Online -eq 1 -and $r.NoReply -eq 1 -and $r.Errors -eq 1) ('Compteurs : '+$r.Done+'/'+$r.Online+'/'+$r.NoReply+'/'+$r.Errors)
 Assert ($r.ShortText -eq '3/3 · 1 en ligne · 1 sans réponse · 1 erreur') $r.ShortText
 Assert ([string]$r.StatusText -like 'Ping terminé : 3/3*') ([string]$r.StatusText)
}
Case 'CO-19 : echec du worker de console compte en erreur, jamais comme poste muet' {
 Reset-Fixture;Ready-Run 1;Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State
 Fail-DomeniaParkSession 'RPC indisponible' $state
 $saved=$script:Saves[0];$row=[pscustomobject]@{Version=1;Key=$state.StoreDn;Guid=$state.StoreGuid;Computer=$state.Target.Computer;Presence='Erreur de ping';PresenceCheckedUtc='2026-10-13T10:00:00Z';Outcome='Unavailable';Revision=19}
 & $saved.SuccessHandler -Result ([pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$saved.Context.StoreId;RequestId=$saved.Context.RequestId;BatchId=$saved.BatchId;ObservationRows=@($row);Observations=@();Revision=19;SnapshotRevision=19}) -State $saved.CallbackState
 Assert ((Run).Errors -eq 1 -and (Run).NoReply -eq 0 -and (Run).Online -eq 0) ('Erreurs : '+(Run).Errors+' muets : '+(Run).NoReply)
}
Case 'MO-08 : arret du ping garde les echos deja recus, les autres restent non verifies' {
 Reset-Fixture;Ready-Run 3 -PingOnly;Invoke-DomeniaParkRunTick
 $ping=$script:Calls[1]
 (Run).PingQueue.Enqueue([pscustomobject]@{Results=@(New-PingResult (New-Target 1) 'En ligne')})
 Stop-DomeniaOnlinePark
 Assert ($script:StopRequests.Count -eq 1 -and $script:StopRequests[0] -eq $ping.Id -and -not (Run).Completed) 'Worker de ping non arrete.'
 Invoke-DomeniaParkRunTick
 Assert ($script:Saves.Count -eq 1 -and @($script:Saves[0].Changes).Count -eq 1 -and (Run).Unchecked -eq 2) ('Non verifies : '+(Run).Unchecked)
 Commit-PingSaved 0;Invoke-DomeniaParkRunTick
 Assert ((Run).Completed -and (Run).Done -eq 1 -and $script:Calls.Count -eq 2) 'Releve non termine ou relance.'
 Assert ([string](Run).ShortText -like 'Arrêté à 1/3 ·*2 postes non vérifiés') ([string](Run).ShortText)
}
Case 'MO-08 : stockage suspendu, les echos en attente sont comptes non enregistres et le releve se termine' {
 Reset-Fixture;Add-SurveyControls;Ready-Run 3 -PingOnly;Invoke-DomeniaParkRunTick
 $ping=$script:Calls[1];$r=Run
 $r.PingQueue.Enqueue([pscustomobject]@{Results=@((New-PingResult (New-Target 1) 'En ligne'),(New-PingResult (New-Target 2) 'Sans réponse au ping'))})
 $script:Persistence=[pscustomobject]@{Pending=@{};InFlight=0;Failures=3;Conflicts=@{};LinkBusy=$false;LinkRequestTimer=$null;LinkPersistenceMore=$false}
 Invoke-DomeniaParkRunTick
 Assert ($script:Saves.Count -eq 0 -and $null -eq $script:DomeniaRemoteStoreQueue) 'Echos confies a un stockage suspendu.'
 Assert ($script:StopRequests -contains $ping.Id -and $r.Stopping) 'Ping de la liste non arrete.'
 Invoke-DomeniaParkRunTick
 Assert ($r.Completed -and $r.Done -eq 0 -and $r.Failed -eq 2 -and $r.Unchecked -eq 1) ('Fin : '+$r.Completed+' non enregistres '+$r.Failed+' non verifies '+$r.Unchecked)
 Assert ([string]$r.ShortText -like 'Arrêté à 0/3 ·*2 lectures non confirmées · 1 poste non vérifié') ([string]$r.ShortText)
 Assert ([string]$r.StatusText -like '*Stockage à vérifier dans Fiabilité*') ([string]$r.StatusText)
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -ne 'Arrêt en cours…' -and $script:Ctrl.BtnParkVerify.IsEnabled -and -not (Test-DomeniaParkRunActive -Slot 'List')) 'La liste reste bloquee par le releve.'
}
Case 'MO-08 : file dʼenregistrement bloquee par un lot refuse, le releve se termine sans attendre les lots derriere' {
 Reset-Fixture;Ready-Run 3 -PingOnly;Invoke-DomeniaParkRunTick
 $r=Run;$t1=New-Target 1
 # A batch refused by the storage heads the queue; one batch of this survey already waits behind it.
 $script:DomeniaRemoteStoreQueue=[Collections.Generic.Queue[object]]::new()
 $script:DomeniaRemoteStoreQueue.Enqueue([pscustomobject]@{BatchId='refused';State=[pscustomobject]@{RunId='other'};Failed=$true;Delivered=$false})
 $script:DomeniaRemoteStoreQueue.Enqueue([pscustomobject]@{BatchId='behind';State=[pscustomobject]@{RunId=$r.Id;Job='ping-behind';Targets=@([pscustomobject]@{Key=$t1.Key;Guid=$t1.Guid;Computer=$t1.Computer})};Failed=$false;Delivered=$false})
 $r.StorePending['ping-behind']=$true;$r.PingReported[$t1.Key]=$true
 $r.PingQueue.Enqueue([pscustomobject]@{Results=@(New-PingResult (New-Target 2) 'En ligne')})
 Invoke-DomeniaParkRunTick;Invoke-DomeniaParkRunTick
 Assert ($r.Completed -and $r.StorePending.Count -eq 0 -and $r.Failed -eq 2 -and $r.Unchecked -eq 1 -and $script:Saves.Count -eq 0) ('Fin : '+$r.Completed+' en attente '+$r.StorePending.Count+' non enregistres '+$r.Failed+' non verifies '+$r.Unchecked)
 Assert ($script:DomeniaRemoteStoreQueue.Count -eq 2) 'Un lot de la file a ete jete.'
}
Case 'MO-08 : la liste est actualisee une fois par lot enregistre, jamais une fois par poste' {
 Reset-Fixture;$rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
 foreach($n in 1..3){$t=New-Target $n;$row=New-DomeniaLiveResultRow;$row.Type='Machine';$row.Name=$t.Computer;$row.DN=$t.Key;$row.Guid=$t.Guid;$rows.Add($row)}
 $script:Ctrl.DgObjects.ItemsSource=$rows
 # A refresh of the view evaluates its filter once per row.
 $script:FilterCalls=0;$script:Ctrl.DgObjects.Items.Filter=[Predicate[object]]{param($x)$script:FilterCalls++;return $true}
 Start-DomeniaOnlinePark -DisplayedResults -PingOnly;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 1;New-Target 2;New-Target 3);Busy=$false}) $call.State;$script:AsyncJobs.Remove($call.Id);& $script:Confirm
 Invoke-DomeniaParkRunTick;$ping=$script:Calls[1]
 Complete-DomeniaParkPingJob ([pscustomobject]@{Results=@((New-PingResult (New-Target 1) 'En ligne'),(New-PingResult (New-Target 2) 'En ligne'),(New-PingResult (New-Target 3) 'Sans réponse au ping'));Count=3;Completed=$true}) $ping.State
 Invoke-DomeniaParkRunTick
 Assert ($script:Saves.Count -eq 1) ('Lots : '+$script:Saves.Count)
 $before=$script:FilterCalls
 Commit-PingSaved 0 @{'PC-3'='Sans réponse au ping'}
 Assert (($script:FilterCalls-$before) -eq 3 -and (Run).Done -eq 3) ('Evaluations du filtre pour un lot de 3 postes : '+($script:FilterCalls-$before))
 Invoke-DomeniaParkRunTick
 Assert ((Run).Completed -and ($script:FilterCalls-$before) -eq 3) 'Liste actualisee de nouveau a la fin du releve.'
}
Case 'MO-08 : corps ParkPing hors reseau : nom invalide en erreur sans echo, lots rapportes un par un' {
 $queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
 $Payload=[pscustomobject]@{Targets=@(for($i=1;$i -le 70;$i++){[pscustomobject]@{Key=('cn=x'+$i);Guid=('g'+$i);Computer=('nom invalide '+$i)}});TimeoutMs=250;BatchSize=32;Progress=$queue}
 $result=@(& ([scriptblock]::Create((Get-DomeniaParkPingWorkerCode))))
 Assert ($result.Count -eq 1 -and [int]$result[0].Count -eq 70 -and $result[0].Completed) 'Resultat final du worker'
 Assert (@($result[0].Results|Where-Object{$_.Presence -ne 'Erreur de ping' -or $_.PresenceDetail -notlike '*aucun écho envoyé*'}).Count -eq 0) 'Nom invalide compte comme muet ou sonde.'
 $sizes=@();$packet=$null;while($queue.TryDequeue([ref]$packet)){$sizes+=@($packet.Results).Count}
 Assert (($sizes -join ',') -eq '32,32,6') ('Lots rapportes : '+($sizes -join ','))
 Assert (@($result[0].Results|Select-Object -ExpandProperty Key -Unique).Count -eq 70) 'Identite des postes perdue.'
}

# ---------------------------------------------------------------- UX-12 / UI-23: progress, stop and graduated readings
Case 'UX-12 : Arreter (n/N), barre fine, lignes marquees pendant le releve puis bilan court' {
 Reset-Fixture;Add-SurveyControls;Add-ResultRows 3
 Start-DomeniaOnlinePark -DisplayedResults;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 1;New-Target 2;New-Target 3);Busy=$false}) $call.State;$script:AsyncJobs.Remove($call.Id)
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Annuler la vérification' -and $script:Ctrl.PbParkProgress.Visibility -ne 'Visible') ('Avant confirmation : '+[string]$script:Ctrl.BtnParkVerify.Content)
 Assert ([string]$script:Ctrl.LblParkProgress.Text -eq 'Confirmation en attente · 3 postes') ([string]$script:Ctrl.LblParkProgress.Text)
 & $script:Confirm
 $rows=@($script:Ctrl.DgObjects.Items)
 Assert ((Run).Approved -and @($rows|Where-Object{$_.ProbePending -eq '1'}).Count -eq 3) 'Lignes non marquees.'
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Arrêter (0/3)' -and $script:Ctrl.BtnParkVerify.IsEnabled) ([string]$script:Ctrl.BtnParkVerify.Content)
 Assert ($script:Ctrl.PbParkProgress.Visibility -eq 'Visible' -and $script:Ctrl.UxParkProgress.Visibility -eq 'Visible' -and $script:Ctrl.LblLiveState.Visibility -eq 'Collapsed') 'Barre ou etat court absent.'
 Assert ([string]$script:Ctrl.LblParkProgress.Text -eq '0/3 · 0 joignable') ([string]$script:Ctrl.LblParkProgress.Text)
 Assert ($script:TimerOwners -contains 'Timer:ParkRun:List') 'Minuteur de la liste absent.'
 Invoke-DomeniaParkRunTick;$state=$script:Calls[1].State;Complete-DomeniaParkSession (New-Result $state.Target) $state;Commit-Saved
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Arrêter (1/3)' -and [int][Math]::Round($script:Ctrl.PbParkProgress.Value) -eq 33) ([string]$script:Ctrl.BtnParkVerify.Content)
 Assert ([string]$rows[0].ProbePending -eq '' -and [string]$rows[1].ProbePending -eq '1') 'Marque de la ligne lue non retiree.'
 Invoke-DomeniaParkVerify -Anchor $script:Ctrl.BtnParkVerify
 Assert ((Run).Completed -and (Run).Stopping) 'Le bouton nʼa pas arrete le releve.'
 Assert (@($rows|Where-Object{$_.ProbePending -eq '1'}).Count -eq 0) 'Marque restee apres lʼarret.'
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Vérifier la liste' -and $script:Ctrl.PbParkProgress.Visibility -eq 'Collapsed') ([string]$script:Ctrl.BtnParkVerify.Content)
 Assert ([string]$script:Ctrl.LblParkProgress.Text -eq 'Arrêté à 1/3 · 1 en ligne · 0 sans réponse · 0 erreur') ([string]$script:Ctrl.LblParkProgress.Text)
}
Case 'UX-12 : Annuler la verification retire aussi la demande affichee, aucun Pinger N postes orphelin' {
 Reset-Fixture;Add-SurveyControls;Add-ResultRows 3
 $script:InlinePending=$null;$script:InlineDismissed=0
 function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel,$Risk,[string[]]$Changes,$Details,$DetailsTitle,[switch]$DetailsExpertOnly,$TypedConfirmation,$TypedPrompt)$script:Confirm=$OnConfirm;$script:Cancel=$OnCancel;$script:ConfirmButton=$ConfirmText;$script:InlinePending=[pscustomobject]@{Id='req-1';Title=$Title};return [pscustomobject]@{Id='req-1';Title=$Title;Target=$Target;Answered=$false;Confirmed=$false;Presentation='Inline'}}
 function Get-DomeniaInlinePendingRequest {return $script:InlinePending}
 function Complete-DomeniaInlineRequest {param([switch]$Confirm,[switch]$Dismiss,[string]$Reason='')if($null -eq $script:InlinePending){return};$script:InlinePending=$null;$script:InlineDismissed++;if($Dismiss){& $script:Cancel}else{& $script:Confirm}}
 Start-DomeniaOnlinePark -DisplayedResults -PingOnly;$call=$script:Calls[0]
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 1;New-Target 2;New-Target 3);Busy=$false}) $call.State;$script:AsyncJobs.Remove($call.Id)
 Assert ([string](Run).InlineRequestId -eq 'req-1' -and $script:ConfirmButton -eq 'Pinger 3 postes') 'Demande du releve non retenue.'
 Invoke-DomeniaParkVerify -Anchor $script:Ctrl.BtnParkVerify
 Assert ($null -eq $script:InlinePending -and $script:InlineDismissed -eq 1) 'La demande Pinger 3 postes reste affichee.'
 Assert ((Run).Completed -and -not (Run).Approved -and $script:Calls.Count -eq 1) 'Releve non arrete, ou lance.'
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Vérifier la liste' -and $script:Ctrl.BtnParkVerify.IsEnabled) ([string]$script:Ctrl.BtnParkVerify.Content)
 & $script:Confirm
 Assert ($null -eq (Run).Timer -and $script:Calls.Count -eq 1) 'Une ancienne confirmation a relance le releve.'
}
Case 'UI-23 : Verifier la liste ouvre les choix, retient le dernier pour la session, arrete un releve en cours' {
 Reset-Fixture;Add-SurveyControls
 $script:Opened=0;$script:Started=[Collections.Generic.List[string]]::new();$script:Stopped=0;$script:SettingsSaved=[Collections.Generic.List[string]]::new()
 function Set-DomeniaSetting {param($Name,$Value)$script:SettingsSaved.Add([string]$Name)}
 function Open-DomeniaParkVerifyMenu {param($Anchor)$script:Opened++}
 function Start-DomeniaOnlinePark {param([switch]$DisplayedResults,[switch]$PingOnly,[switch]$Inventory,$Probes)$script:Started.Add($(if($PingOnly){'Ping'}else{'Console'})+$(if($DisplayedResults){':liste'}else{''}))}
 function Start-DomeniaParkAnalysis {$script:Started.Add('Analyse:liste')}
 function Stop-DomeniaOnlinePark {param([string]$RunId='',[string]$Slot='List')$script:Stopped++}
 Invoke-DomeniaParkVerify;Assert ($script:Opened -eq 1 -and $script:Started.Count -eq 0) 'Sans choix, le bouton doit ouvrir les trois verifications.'
 Invoke-DomeniaParkVerify -Mode Ping;Invoke-DomeniaParkVerify
 Assert (($script:Started -join ',') -eq 'Ping:liste,Ping:liste' -and $script:ParkDefaultMode -eq 'Ping') ($script:Started -join ',')
 Assert ((Get-DomeniaParkVerifyButtonText) -eq 'Vérifier : Qui répond ?') (Get-DomeniaParkVerifyButtonText)
 Invoke-DomeniaParkVerify -Mode Analyse;Invoke-DomeniaParkVerify -Mode Console
 Assert (($script:Started -join ',') -eq 'Ping:liste,Ping:liste,Analyse:liste,Console:liste' -and $script:ParkDefaultMode -eq 'Console') ($script:Started -join ',')
 Invoke-DomeniaParkVerify -Mode 'Tout';Assert ($script:Started.Count -eq 4 -and $script:ParkDefaultMode -eq 'Console') 'Lecture inconnue acceptee.'
 $script:ParkRuns=@{List=[pscustomobject]@{Id='r';Slot='List';ScopeKind='Results';Completed=$false}}
 Invoke-DomeniaParkVerify;Assert ($script:Stopped -eq 1 -and $script:Started.Count -eq 4) 'Pendant un releve, le bouton doit lʼarreter.'
 # An OU refresh in the scope of the lists keeps its own Arrêter beside its refresh buttons: the button only waits.
 $script:SearchListHasMachine=$true;$script:ParkRuns=@{List=[pscustomobject]@{Id='ou';Slot='List';ScopeKind='Scope';RefreshOperationId='refresh-1';Completed=$false;Approved=$true;Epoch=1L}}
 Update-DomeniaParkControls
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Vérifier : Qui est connecté ?' -and -not $script:Ctrl.BtnParkVerify.IsEnabled -and -not $script:Ctrl.BtnParkVerifyMenu.IsEnabled) ([string]$script:Ctrl.BtnParkVerify.Content)
 Invoke-DomeniaParkVerify;Assert ($script:Stopped -eq 1) 'Le bouton de la liste a arrete un releve de perimetre.'
 Assert ($script:SettingsSaved.Count -eq 0) 'Choix de lecture enregistre au-dela de la session.'
}
Case 'CO-19 : pastilles du dernier ping, filtre local de presence, second clic retire le filtre' {
 Reset-Fixture;Add-SurveyControls
 $script:ParkRuns=@{List=[pscustomobject]@{Id='r';Slot='List';ScopeKind='Results';Epoch=1L;Generation=1L;Completed=$true;Approved=$true;Stopping=$false;Loading=$false;WmiOnly=$false;PingOnly=$true;Targets=@(1,2,3,4,5,6);Requested=6;Done=6;Online=3;NoReply=2;Errors=1;ShortText='6/6 · 3 en ligne · 2 sans réponse · 1 erreur'}}
 Update-DomeniaParkControls
 Assert ($script:Ctrl.PnlParkOutcome.Visibility -eq 'Visible') 'Pastilles absentes en fin de ping.'
 Assert ([string]$script:Ctrl.BtnParkOutcomeOnline.Content -eq '3 en ligne' -and [string]$script:Ctrl.BtnParkOutcomeNoReply.Content -eq '2 sans réponse' -and [string]$script:Ctrl.BtnParkOutcomeError.Content -eq '1 erreur') 'Libelles des pastilles'
 Assert ($script:Ctrl.BtnParkOutcomeError.IsEnabled) 'Pastille non cliquable en mode OU.'
 Set-DomeniaParkOutcomeFilter -Outcome NoReply
 Assert ([string]$script:CurrentPresenceFilter -eq 'Sans réponse au ping' -and [string]$script:Ctrl.CmbPresenceFilter.SelectedItem.Content -eq 'Sans réponse au ping' -and $script:PresenceFilterApplied.Count -eq 1) 'Filtre non pose.'
 Set-DomeniaParkOutcomeFilter -Outcome NoReply
 Assert ([string]$script:CurrentPresenceFilter -eq 'Tous' -and $script:PresenceFilterApplied.Count -eq 2) 'Second clic sans effet.'
 $script:SearchMode='Global';Update-DomeniaParkControls
 Assert (-not $script:Ctrl.BtnParkOutcomeError.IsEnabled) 'Filtre local propose sur une recherche globale.'
 $script:GlobalSearchGeneration++;Update-DomeniaParkControls
 Assert ($script:Ctrl.PnlParkOutcome.Visibility -eq 'Collapsed' -and $script:Ctrl.UxParkProgress.Visibility -eq 'Collapsed') 'Bilan affiche sur une nouvelle liste.'
}

# ---------------------------------------------------------------- FI-18: one survey per scope
Case 'FI-18 : releve du poste ouvert pendant un releve de la liste, chacun son arret' {
 Reset-Fixture;Add-SurveyControls;Ready-Run 4
 $list=Run;$open=New-ScopeTarget 77
 $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-77';DN=$open.distinguished_name.ToUpperInvariant();Safety=[pscustomobject]@{Guid=$open.object_guid}}
 Start-DomeniaOnlinePark -ScopeTargets @($open) -ScopeLabel 'PC-77' -Inventory
 $computer=Run 'Computer'
 Assert ($null -ne $computer -and $script:Calls.Count -eq 2 -and [object]::ReferenceEquals((Run),$list)) 'Le releve du poste a remplace ou bloque celui de la liste.'
 Assert ($script:Calls[1].State.Slot -eq 'Computer' -and -not $list.Stopping) 'Portee du poste absente.'
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 77);Busy=$false}) $script:Calls[1].State;$script:AsyncJobs.Remove($script:Calls[1].Id)
 Assert ($script:ConfirmTarget -eq 'PC-77' -and $script:ConfirmTitle -eq 'Relevé des postes : matériel et widgets') ($script:ConfirmTarget+' | '+$script:ConfirmTitle)
 & $script:Confirm
 Assert ($computer.Approved -and $script:TimerOwners -contains 'Timer:ParkRun:Computer') 'Minuteur du poste absent.'
 Assert ($script:Ctrl.UxComputerParkRun.Visibility -eq 'Visible' -and $script:Ctrl.BtnComputerParkStop.IsEnabled) 'Etat du releve du poste absent du tableau.'
 $before=$script:Calls.Count
 Start-DomeniaOnlinePark -ScopeTargets @($open) -ScopeLabel 'PC-77' -Inventory
 Assert ($script:Calls.Count -eq $before -and [string]$script:Status -like '*relevé de ce poste est déjà en cours*') ([string]$script:Status)
 Add-DisplayedMachine;Start-DomeniaOnlinePark -DisplayedResults
 Assert ($script:Calls.Count -eq $before -and [string]$script:Status -like '*relevé de la liste est déjà en cours*') ([string]$script:Status)
 Invoke-DomeniaParkRunTick -Slot 'Computer'
 Assert (@($script:Calls|Where-Object{$_.State.Slot -eq 'Computer' -and $_.OperationId -eq 'LiveConsole'}).Count -eq 1) 'Le releve du poste ne part pas a cote de la liste.'
 Stop-DomeniaOnlinePark -Slot 'Computer'
 Assert ($computer.Stopping -and -not $list.Stopping) 'Arreter le poste a arrete la liste.'
 # Running, the survey of PC-77 stays shown and stoppable beside another board, named; finished, only beside its own.
 $other=New-ScopeTarget 78
 $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-78';DN=$other.distinguished_name;Safety=[pscustomobject]@{Guid=$other.object_guid}}
 Update-DomeniaParkControls
 Assert ($script:Ctrl.UxComputerParkRun.Visibility -eq 'Visible' -and [string]$script:Ctrl.LblComputerParkStatus.Text -like 'PC-77 · *') ([string]$script:Ctrl.LblComputerParkStatus.Text)
 Start-DomeniaOnlinePark -ScopeTargets @($other) -ScopeLabel 'PC-78' -Inventory
 Assert ([string]$script:Status -like '*relevé du poste PC-77 est déjà en cours*') ([string]$script:Status)
 $computer.Completed=$true;Update-DomeniaParkControls
 Assert ($script:Ctrl.UxComputerParkRun.Visibility -eq 'Collapsed') 'Le bilan de PC-77 sʼaffiche sur le tableau de PC-78.'
 $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-77';DN=$open.distinguished_name;Safety=[pscustomobject]@{Guid=$open.object_guid}}
 Update-DomeniaParkControls
 Assert ($script:Ctrl.UxComputerParkRun.Visibility -eq 'Visible' -and [string]$script:Ctrl.LblComputerParkStatus.Text -notlike 'PC-77 · *') 'Bilan absent du tableau du poste releve.'
}
Case 'FI-18 : un releve du tableau de parc sʼarrete depuis Verifier la liste ; une actualisation dʼOU attend son propre arret' {
 Reset-Fixture;Add-SurveyControls
 # The fleet board (Widgets.UI CollectFleet) starts its survey with explicit targets of the perimeter.
 Start-DomeniaOnlinePark -ScopeTargets @((New-ScopeTarget 1),(New-ScopeTarget 2),(New-ScopeTarget 3)) -ScopeLabel 'Postes' -Inventory
 $call=$script:Calls[0];$r=Run
 Assert ($null -ne $r -and $r.ScopeKind -eq 'Scope' -and $r.Slot -eq 'List') 'Releve du tableau hors de la portee des listes.'
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 1;New-Target 2;New-Target 3);Busy=$false}) $call.State;$script:AsyncJobs.Remove($call.Id)
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Annuler le relevé' -and $script:Ctrl.BtnParkVerify.IsEnabled) ([string]$script:Ctrl.BtnParkVerify.Content)
 & $script:Confirm
 Assert ([string]$script:Ctrl.BtnParkVerify.Content -eq 'Arrêter (0/3)' -and $script:Ctrl.BtnParkVerify.IsEnabled) ([string]$script:Ctrl.BtnParkVerify.Content)
 Assert ($script:Ctrl.UxParkProgress.Visibility -eq 'Visible' -and $script:Ctrl.PbParkProgress.Visibility -eq 'Visible' -and [string]$script:Ctrl.LblParkProgress.Text -eq 'Relevé de Postes · 0/3 · 0 joignable') ([string]$script:Ctrl.LblParkProgress.Text)
 Assert ($script:Ctrl.PnlParkOutcome.Visibility -ne 'Visible') 'Pastilles de la liste sur un releve de perimetre.'
 Invoke-DomeniaParkRunTick;Assert ($script:Calls.Count -eq 2) 'Lecture du tableau non partie.'
 Invoke-DomeniaParkVerify -Anchor $script:Ctrl.BtnParkVerify
 Assert ($r.Stopping) 'Le releve du tableau nʼest pas arrete depuis Rechercher.'
 1..3|ForEach-Object{Invoke-DomeniaParkRunTick};Assert ($script:Calls.Count -eq 2) 'Lecture lancee apres lʼarret.'
 Reset-Fixture;Add-SurveyControls
 $script:ParkRuns=@{List=[pscustomobject]@{Id='ou';Slot='List';ScopeKind='Scope';ScopeLabel='OU Postes';RefreshOperationId='refresh-1';Completed=$false;Approved=$true;Loading=$false;Stopping=$false;Epoch=1L;Generation=1L;Targets=@(1,2);Requested=2;Done=1;ShortText='1/2 · 1 joignable'}}
 Update-DomeniaParkControls
 Assert (-not $script:Ctrl.BtnParkVerify.IsEnabled -and [string]$script:Ctrl.LblParkProgress.Text -eq 'Actualisation de OU Postes · 1/2 · 1 joignable · arrêt avec lʼactualisation') ([string]$script:Ctrl.LblParkProgress.Text)
}

# ---------------------------------------------------------------- FO-18: surveys of a multiple selection
Case 'FO-18 : selection, meme plafond et meme confirmation que la liste' {
 Reset-Fixture
 Start-DomeniaOnlinePark -Selection -ScopeTargets @(for($i=1;$i -le 501;$i++){New-ScopeTarget $i}) -PingOnly
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like '*501 postes sélectionnés : plafond 500. Réduisez la sélection.*') ([string]$script:Status)
 # Three of the five displayed workstations of the domain root: a real choice, its own filter.
 Reset-Fixture;$script:SelectedBranchDn=$script:Conn.BaseDn;Add-DisplayedMachines 5
 Start-DomeniaOnlinePark -Selection -ScopeTargets @((New-ScopeTarget 1),(New-ScopeTarget 2),(New-ScopeTarget 3)) -SkippedTargets 1 -PingOnly
 Assert ($script:Calls.Count -eq 1 -and @($script:Calls[0].Payload.Targets).Count -eq 3 -and $script:Calls[0].State.Slot -eq 'List') 'Selection a la racine refusee ou mal portee.'
 Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@(New-Target 1;New-Target 2;New-Target 3);Busy=$false}) $script:Calls[0].State
 $lines=@([string]$script:Message -split "`r`n")
 Assert ($lines[0] -eq '3 postes sélectionnés · 1 ligne sans identifiant AD ignorée' -and $script:ConfirmTarget -eq 'la sélection' -and $script:ConfirmButton -eq 'Pinger 3 postes' -and $script:ConfirmTitle -eq 'Vérifier la sélection : qui répond ?') ($lines[0]+' | '+$script:ConfirmTarget+' | '+$script:ConfirmButton)
 Reset-Fixture;$script:ListSurveyBlocked=$true
 Start-DomeniaOnlinePark -Selection -ScopeTargets @(New-ScopeTarget 1)
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like '*tout le domaine*') 'Selection dʼune vue sur tout le domaine relevee.'
 Reset-Fixture
 Start-DomeniaOnlinePark -Selection -ScopeTargets @() -SkippedTargets 2
 Assert ($script:Calls.Count -eq 0 -and [string]$script:Status -like '*sans identifiant AD*') ([string]$script:Status)
}

Case 'Interface : un seul bouton Verifier la liste, ses choix, pastilles, selection et poste cables ; anciens boutons retires' {
 $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 try{
  $script:Clicks=[Collections.Generic.List[string]]::new()
  function Invoke-DomeniaParkVerify {param($Mode,$Anchor)$script:Clicks.Add('Verify')}
  function Open-DomeniaParkVerifyMenu {param($Anchor)$script:Clicks.Add('Menu')}
  function Set-DomeniaParkOutcomeFilter {param($Outcome)$script:Clicks.Add('Pill:'+$Outcome)}
  function Start-DomeniaParkSelectionSurvey {param($Mode)$script:Clicks.Add('Selection:'+$Mode)}
  function Copy-DomeniaSelectedRowsForTicket {$script:Clicks.Add('Copy')}
  function Export-CurrentResults {param([string]$Mode='')$script:Clicks.Add('Export'+$(if($Mode){':'+$Mode}else{''}))}
  function Stop-DomeniaOnlinePark {param([string]$RunId='',[string]$Slot='List')$script:Clicks.Add('Stop:'+$Slot)}
  foreach($name in @('BtnParkSweep','BtnParkSweepStop','BtnParkResults','BtnParkPing','BtnParkAnalyze','BtnParkResultsStop')){Assert ($null -eq $window.FindName($name)) ($name+' encore present')}
  $names=@('BtnParkVerify','BtnParkVerifyMenu','BtnParkOutcomeOnline','BtnParkOutcomeNoReply','BtnParkOutcomeError','BtnSelectionPing','BtnSelectionConsole','BtnSelectionCopy','BtnSelectionExport','BtnComputerParkStop')
  $script:Ctrl=@{};foreach($name in $names){$script:Ctrl[$name]=$window.FindName($name);Assert ($null -ne $script:Ctrl[$name]) ($name+' absent')}
  foreach($name in @('PbParkProgress','UxParkProgress','LblParkProgress','PnlParkOutcome','UxSelectionBar','LblSelectionBar','UxComputerParkRun','LblComputerParkStatus')){Assert ($null -ne $window.FindName($name)) ($name+' absent')}
  Assert ([object]::ReferenceEquals($script:Ctrl.BtnParkVerify.Style,$window.FindResource('SecondaryButton')) -and -not [object]::ReferenceEquals($script:Ctrl.BtnParkVerify.Style,$window.FindResource('RunButton'))) 'Le bouton de verification doit rester secondaire (Rechercher seul est principal).'
  $pattern='^\$script:Ctrl\["('+($names -join '|')+')"\]$'
  foreach($n in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Click'},$true))){if($n.Expression.Extent.Text -match $pattern){. ([scriptblock]::Create($n.Extent.Text))}}
  foreach($name in $names){$script:Ctrl[$name].IsEnabled=$true;$script:Ctrl[$name].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
  Assert (($script:Clicks -join ',') -eq 'Verify,Menu,Pill:Online,Pill:NoReply,Pill:Error,Selection:Ping,Selection:Console,Copy,Export:Selected,Stop:Computer') ($script:Clicks -join ',')
 }finally{$window.Close()}
}
if($null -ne $script:ParkRuns){foreach($old in @($script:ParkRuns.Values)){if($null -ne $old -and $null -ne $old.PSObject.Properties['Timer'] -and $null -ne $old.Timer){$old.Timer.Stop()}}}
$failed=@($checks|Where-Object Status -eq 'Failed').Count
$expected=56
$report=[ordered]@{Kind='ParkDetection';Expected=$expected;Complete=($checks.Count -eq $expected -and $failed -eq 0);NativeWindowsPowerShell51=$true;LiveAD=$false;MockedNetwork=$true;Passed=$checks.Count-$failed;Failed=$failed;Tests=$checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path $env:TEMP 'domenia-park-tests.json'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ($report.Passed.ToString()+' reussis, '+$failed+' echecs. '+$ReportPath)
if($failed -or -not $report.Complete){exit 1};exit 0
