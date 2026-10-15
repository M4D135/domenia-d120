#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'Domenia-Modules.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaEffectiveWorkerResult','Get-MainXaml','Start-DomeniaParkSweep','Request-DomeniaParkSweepAtStartup','Show-DomeniaBatchNetworkReport')){
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
function New-DomeniaObservationReader {return [pscustomobject]@{Fixture=$true}}
function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel,$Risk,[string[]]$Changes,$Details,$DetailsTitle,[switch]$DetailsExpertOnly,$TypedConfirmation,$TypedPrompt)$script:Confirm=$OnConfirm;$script:Cancel=$OnCancel;$script:Message=$Message;$script:Preview=[pscustomobject]@{Changes=@($Changes);Details=[string]$Details;Typed=[string]$TypedConfirmation;DetailsExpertOnly=[bool]$DetailsExpertOnly}}
function Start-UiTask {
 param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TimeoutSeconds,$TaskClass,$ReplaceKey,$StatusText)
 $id='job-'+$script:Calls.Count
 $call=[pscustomobject]@{Id=$id;Payload=$Payload;State=$CallbackState;OperationId=$OperationId};$script:Calls.Add($call);$script:AsyncJobs[$id]=$call;return $id
}
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
 Assert (@($script:ParkRun.Targets).Count -eq 2) ('Cibles du releve : '+@($script:ParkRun.Targets).Count)
 Assert ((@($script:ParkRun.Targets|ForEach-Object{[string]$_.Key}) -join '|') -eq 'cn=pc-1,dc=example,dc=invalid|cn=pc-2,dc=example,dc=invalid') 'Ancien DN garde dans le releve'
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
if($null -ne $script:ParkRun -and $null -ne $script:ParkRun.Timer){$script:ParkRun.Timer.Stop()}
$failed=@($checks|Where-Object Status -eq 'Failed').Count
$report=[ordered]@{Kind='ParkDetection';Expected=28;Complete=($checks.Count -eq 28 -and $failed -eq 0);NativeWindowsPowerShell51=$true;LiveAD=$false;MockedNetwork=$true;Passed=$checks.Count-$failed;Failed=$failed;Tests=$checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path $env:TEMP 'domenia-park-tests.json'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ($report.Passed.ToString()+' reussis, '+$failed+' echecs. '+$ReportPath)
if($failed -or -not $report.Complete){exit 1};exit 0
