#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
# Native isolated tests: actual parser, WPF collections and Windows SQLite, no domain access.
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Utiliser Windows PowerShell 5.1 x64 avec -STA.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw $errors[0].Message}
$defs=[Collections.Generic.List[string]]::new()
foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSearchMode','Get-DomeniaSearchText','Set-DomeniaSearchMode','Get-DomeniaSearchScope','Test-DomeniaSearchStateCurrent','Get-GlobalSelectedTypeFilter','Get-TypeLdapFilter','Get-DomeniaEffectiveWorkerResult','Normalize-LinkComputer','Normalize-LinkUser','Get-DomeniaWorkerCodeHash','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerRegistry','Assert-DomeniaWorkerOperationCode','Initialize-DomeniaWinSqliteNative','Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbExec','Invoke-DomeniaDbQuery','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','ConvertTo-DomeniaSqlLiteral')){
    $found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($found.Count -ne 1){throw ('Fonction absente ou ambiguë : '+$name)}
    [void]$defs.Add($found[0].Extent.Text)
}
. ([scriptblock]::Create(($defs.ToArray() -join "`n")))
# D120 resync: Live.UI now relies on Test-DomeniaAccessBusyWrite (Access.UI) and on other modules of the
# closed plan. Import the real plan (definitions only, verified origin) rather than two isolated files.
. (Join-Path $wad 'Domenia-Modules.ps1')
# The scheduler body is loaded but not allowed to contact anything in these tests.
function Start-DomeniaLiveBackgroundWork { }
function Write-AppLog {param($Text,$Level)}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
function Set-Status {param($Text,$Level)}
function Get-CfgValue {param($Section,$Name,$Default) return $Default}
function Request-UiTaskStop {param($Id,$Reason,[switch]$Silent) $script:Stops++}
function Set-RowAssociationMetadata {param($Rows) return $Rows}
function Get-DomeniaSelectedGridRow {return $script:Ctrl.DgObjects.SelectedItem}
function Get-CurrentSelectedComputerName {return ''}
function Get-DomeniaRunningComputerUserProbe {param($Computer) return $null}
function Get-ExistingLinkForComputer {param($Computer) return $null}
function Merge-DomeniaLiveLinkMemory {param($Observation)}
$script:Cases=[Collections.Generic.List[object]]::new()
function Assert-Live {param([bool]$Condition,[string]$Message='Assertion non satisfaite') if(-not $Condition){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Action)
    try{& $Action|Out-Null;$passed=$true;$detail=''}catch{$passed=$false;$detail=$_.Exception.ToString()}
    [void]$script:Cases.Add([pscustomobject]@{Name=$Name;Passed=$passed;Detail=$detail})
    if(-not $Quiet -or -not $passed){Write-Host "$passed | $Name | $detail"}
}
function New-FixtureRow {
    param([string]$Name='PC-01',[string]$Guid='00000000-0000-0000-0000-000000000001')
    return [pscustomobject]@{Type='Machine';Name=$Name;Login=$Name;UPN=($Name.ToLowerInvariant()+'.example.invalid');DN=('CN='+$Name+',OU=Test,DC=example,DC=invalid');Guid=$Guid}
}
function Reset-LiveFixture {
    if($null -ne $script:Window){$script:Window.Close();$script:Window=$null}
    if($null -ne $script:Live -and $null -ne $script:Live.Timer){$script:Live.Timer.Stop()}
    $script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@();$script:AsyncEngineClosing=$false;$script:DirectoryCredentialFaulted=$false
    $script:ActiveWriteTaskId='';$script:WriteState='Idle';$script:SessionEpoch=1L;$script:GlobalSearchGeneration=1
    $script:ProcessIdentity='EXAMPLE\technicien';$script:MachineCredential=$null;$script:RemoteAdminCredential=$null
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server='dc.example.invalid';Netbios='EXAMPLE';UseCredential=$false;BindUser='';Credential=$null}
    $script:SelectedBranchDn='OU=Test,DC=example,DC=invalid';$script:CurrentPresenceFilter='Tous';$script:SuppressGridSelectionEvents=$false
    $script:Ctrl=@{DgObjects=[Windows.Controls.DataGrid]::new();TxtGlobalSearch=[Windows.Controls.TextBox]::new();TxtSuiteResultFilter=[Windows.Controls.TextBox]::new();ChkSubtree=[Windows.Controls.CheckBox]::new();CmbGlobalType=[Windows.Controls.ComboBox]::new()}
    $script:Ctrl.ChkSubtree.IsChecked=$true;$choice=[Windows.Controls.ComboBoxItem]::new();$choice.Content='Tous';[void]$script:Ctrl.CmbGlobalType.Items.Add($choice);$script:Ctrl.CmbGlobalType.SelectedIndex=0
    $script:Ctrl.DgObjects.AutoGenerateColumns=$false;$script:Ctrl.DgObjects.IsReadOnly=$true;$script:Ctrl.DgObjects.CanUserAddRows=$false
    $script:Window=[Windows.Window]::new();$script:Window.Content=$script:Ctrl.DgObjects
    $script:Live=$null;$script:Stops=0
    Initialize-DomeniaLive
    if($null -eq $script:Live){throw 'Initialisation de la fixture impossible.'}
    $script:Live.Timer.Stop()
    $script:State=[pscustomobject]@{BaseDn=$script:SelectedBranchDn;Scope='Subtree';TypeFilter=Get-GlobalSelectedTypeFilter;Search='';Limit=100;Generation=$script:GlobalSearchGeneration;PreserveSelectionDn=''}
    $script:Payload=[pscustomobject]@{}
    [void](Begin-DomeniaLiveSearch $script:State $script:Payload)
}
function Feed-Live {param($Row,[string]$Kind='Row') $script:Payload.Progress.Enqueue([pscustomobject]@{Kind=$Kind;Row=$Row;ObservedUtc='2026-09-30T10:00:00.0000000Z'})}
function End-Live {param([bool]$Partial=$false)
    $r=[pscustomobject]@{Rows=@();BaseDn=$script:State.BaseDn;Scope=$script:State.Scope;Partial=$Partial;Failure=$(if($Partial){'Interruption fictive'}else{''});LimitReached=$false}
    Complete-DomeniaLiveSearch $r $script:State
    for($i=0;$i -lt 150 -and -not $script:Live.Search.Finalized;$i++){Invoke-DomeniaLiveTick}
}
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-R1.12-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
try{
Case 'D024 : une observation rechargee depuis JSON reste utilisable par Add-DomeniaLiveRow' {
    Reset-LiveFixture
    $source=New-FixtureRow 'PC-CACHED';$key=Get-DomeniaLiveObjectKey $source
    $when=[datetime]::UtcNow.AddDays(-3)
    $observation=[pscustomobject]@{Guid=$source.Guid;LastUser='alice';ObservedUtc=$when.ToString('o');UserCheckedUtc=$when.ToString('o');Presence='En ligne';PresenceCheckedUtc=$when.ToString('o')}
    [void](Set-DomeniaObservationTime $observation 'Console' $when)
    [void](Set-DomeniaObservationTime $observation 'Presence' $when)
    $script:Live.Observations[$key]=($observation | ConvertTo-Json -Depth 3 -Compress | ConvertFrom-Json)
    Add-DomeniaLiveRow ([pscustomobject]@{Kind='CachedRow';Row=$source;ObservedUtc=$when.ToString('o')})
    Assert-Live ($script:Live.Search.Rows.Count -eq 1)
    $row=$script:Live.Search.Rows[0]
    Assert-Live ($row.SessionDisplay -eq 'alice (cache)' -and $row.SessionDetail -match 'Session console.+a relire')
    Assert-Live ($row.PresenceDetail -match 'Presence reseau.+a relire')
}
Case 'D023 : 2000 lignes restent bornees a 500 et les lignes AD remplacent le cache' {
    Reset-LiveFixture
    $script:State.Limit=500
    $script:Ctrl.LblBranchCount=[Windows.Controls.TextBlock]::new();$script:Ctrl.BtnSearchMore=[Windows.Controls.Button]::new()
    [void](Begin-DomeniaLiveSearch $script:State $script:Payload)
    for($i=0;$i -lt 2000;$i++){
        Add-DomeniaLiveRow ([pscustomobject]@{Kind='CachedRow';Row=(New-FixtureRow ('OLD-'+$i));ObservedUtc='2026-01-01T00:00:00Z'})
    }
    Assert-Live ($script:Live.Search.Rows.Count -eq 500)
    for($i=0;$i -lt 2000;$i++){Feed-Live (New-FixtureRow ('NEW-'+$i))}
    Complete-DomeniaLiveSearch ([pscustomobject]@{Rows=@();BaseDn=$script:State.BaseDn;Scope=$script:State.Scope;Partial=$false;Failure='';LimitReached=$true}) $script:State
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not $script:Live.Search.Finalized -and $watch.Elapsed.TotalSeconds -lt 60){Invoke-DomeniaLiveTick}
    Assert-Live $script:Live.Search.Finalized 'Le flux ne se termine pas'
    Assert-Live ($script:Live.Search.Rows.Count -eq 500 -and $script:Live.Search.Fresh.Count -eq 500)
    Assert-Live (@($script:Live.Search.Rows | Where-Object{$_.Name -notlike 'NEW-*'}).Count -eq 0) 'Le cache ancien consomme encore le quota'
    Assert-Live ($script:Ctrl.LblBranchCount.Text -match 'limitée à 500') $script:Ctrl.LblBranchCount.Text
    # Decision David 2026-10-05: the safety maximum is 20 000 rows, so a list limited at 500 may still be continued.
    Assert-Live ($script:Ctrl.BtnSearchMore.IsEnabled) 'Charger la suite refuse sous le plafond de 20 000'
}
Case 'D023 : vingt-cinq recherches conservent seulement vingt caches de requete' {
    Reset-LiveFixture
    $script:Ctrl.TxtBranchSearch=[Windows.Controls.TextBox]::new()
    for($i=0;$i -lt 25;$i++){
        $script:State.Search='query-'+$i;$script:Ctrl.TxtBranchSearch.Text=$script:State.Search
        [void](Begin-DomeniaLiveSearch $script:State $script:Payload)
        Feed-Live (New-FixtureRow ('QUERY-'+$i));End-Live
        Assert-Live $script:Live.Search.Finalized ("Recherche $i non finalisee")
        Assert-Live ($script:Live.MemoryQueries.Count -le 20) ("Trop de caches apres la recherche $i")
    }
    Assert-Live ($script:Live.MemoryQueries.Count -eq 20)
}
Case 'Parseur natif de tous les scripts du paquet' {
    foreach($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e);Assert-Live (@($e).Count -eq 0) ($file.Name+': '+(@($e)|Out-String))}
}
Case 'Parseur natif des deux opérations nouvelles' {
    foreach($body in @((Get-DomeniaLiveProbeCode),(Get-DomeniaLiveCacheCode))){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($body,[ref]$t,[ref]$e);Assert-Live (@($e).Count -eq 0) (@($e)|Out-String)}
}
Case 'Registre fermé conforme au contrat DEV' {
    # Count derived from tools/operation-contracts.json (two-step parse for 5.1), never a constant (48 at R1.12).
    $c=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))|ConvertFrom-Json
    Assert-Live ((Assert-DomeniaWorkerRegistry) -eq @($c).Count) ('Registre non conforme au contrat : '+@($c).Count)
}
Case 'Empreinte du worker console réelle' {[void](Assert-DomeniaWorkerOperationCode 'LiveConsole' (Get-DomeniaLiveProbeCode))}
Case 'Empreinte du worker cache réelle' {[void](Assert-DomeniaWorkerOperationCode 'LiveCache' (Get-DomeniaLiveCacheCode))}
Case 'Worker console altéré refusé' {$failed=$false;try{Assert-DomeniaWorkerOperationCode 'LiveConsole' ((Get-DomeniaLiveProbeCode)+'#change')}catch{$failed=$true};Assert-Live $failed}
Case 'Projection exclut les propriétés secrets inattendues' {$r=New-FixtureRow;Add-Member -InputObject $r NoteProperty Password 'secret-fixture';$v=ConvertTo-DomeniaLiveSnapshot $r;Assert-Live ($null -eq $v.PSObject.Properties['Password'] -and $v.DN -eq $r.DN)}
Case 'Projection borne les champs volumineux' {$r=New-FixtureRow;Add-Member -InputObject $r NoteProperty Description ('a'*10000);Assert-Live ((ConvertTo-DomeniaLiveSnapshot $r).Description.Length -eq 4096)}
Case 'Clé machine utilise le DN complet' {Assert-Live ((Get-DomeniaLiveObjectKey (New-FixtureRow)) -eq 'cn=pc-01,ou=test,dc=example,dc=invalid')}
Case 'Périmètres de comptes distincts ne partagent pas la clé' {Assert-Live ((Get-DomeniaLiveHash 'domaine|a') -ne (Get-DomeniaLiveHash 'domaine|b'))}
$observed=[pscustomobject]@{Key='cn=pc-01,ou=test,dc=example,dc=invalid';Computer='pc-01.example.invalid';Guid='00000000-0000-0000-0000-000000000001';Outcome='Observed';User='EXAMPLE\alice';Source='CIM/DCOM';Presence='En ligne';Detail='Fixture';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='00000000-0000-0000-0000-000000000002'}
$known=ConvertTo-DomeniaLiveObservation $observed $null '2026-09-30T09:00:00.0000000Z'
Case 'Observation réussie conserve le compte et sa date' {Assert-Live ($known.CurrentUser -eq 'EXAMPLE\alice' -and $known.ObservedUtc -eq '2026-09-30T09:00:00.0000000Z')}
foreach($outcome in @('Denied','AuthRejected','Timeout','Unavailable')){
    Case ('Echec '+$outcome+' conserve la dernière observation sans rafraîchir sa date') {
        $failure=[pscustomobject]@{Key=$observed.Key;Guid=$observed.Guid;Computer=$observed.Computer;Outcome=$outcome;User=''}
        $o=ConvertTo-DomeniaLiveObservation $failure $known '2026-09-30T10:00:00.0000000Z'
        Assert-Live ($o.LastUser -eq 'EXAMPLE\alice' -and -not $o.CurrentUser -and $o.ObservedUtc -eq $known.ObservedUtc -and $o.CheckedUtc -ne $o.ObservedUtc)
    }
}
Case 'Pas de console ne signifie pas absence de RDP' {$r=[pscustomobject]@{Outcome='NoConsole';Guid=$observed.Guid};$o=ConvertTo-DomeniaLiveObservation $r $known;$v=Get-DomeniaLiveObservationView $o;Assert-Live ($o.LastUser -eq 'EXAMPLE\alice' -and $v.Display -eq 'Aucun compte console' -and $v.Detail.Contains('RDP'))}
Case 'Observation en cache explicitement marquée cache' {$v=Get-DomeniaLiveObservationView $known -Cached;Assert-Live ($v.Display.Contains('(cache)') -and $v.State -eq 'À vérifier')}
Case 'Objet recréé ne reçoit pas le dernier compte du précédent GUID' {$r=[pscustomobject]@{Outcome='Denied';Guid='00000000-0000-0000-0000-000000000009'};Assert-Live (-not (ConvertTo-DomeniaLiveObservation $r $known).LastUser)}
Case 'Observation vide ne devient pas un succès' {$r=[pscustomobject]@{Outcome='Observed';User=''};Assert-Live ((ConvertTo-DomeniaLiveObservation $r $null).Outcome -eq 'Unavailable')}
Case 'Jeton d identité périmé rejeté' {Assert-Live (-not (Test-DomeniaLiveIdentity ([pscustomobject]@{Epoch=1;Identity='old'}) 1 'new'))}
Case 'Epoch périmée rejetée' {Assert-Live (-not (Test-DomeniaLiveIdentity ([pscustomobject]@{Epoch=1;Identity='same'}) 2 'same'))}
Case 'Collection observable et choix de notification cohérent avec le runtime' {Reset-LiveFixture;Assert-Live ($script:Live.Search.Rows -is [Collections.ObjectModel.ObservableCollection[object]] -and $script:Live.Notifying -eq ($null -ne ('Domenia.Live.ResultRow' -as [type])))}
Case 'Le producteur ne modifie pas directement la grille' {Reset-LiveFixture;Feed-Live (New-FixtureRow);Assert-Live ($script:Live.Search.Rows.Count -eq 0 -and $script:Payload.Progress.Count -eq 1)}
Case 'Ajout par budget, jamais 100 lignes dans un seul tick' {Reset-LiveFixture;foreach($n in 1..100){Feed-Live (New-FixtureRow ('PC-'+$n))};Invoke-DomeniaLiveTick;Assert-Live ($script:Live.Search.Rows.Count -gt 0 -and $script:Live.Search.Rows.Count -le 12 -and $script:Payload.Progress.Count -gt 0)}
Case 'Vidage progressif conserve la même collection' {$before=$script:Ctrl.DgObjects.ItemsSource;for($n=0;$n -lt 150 -and $script:Live.Search.Rows.Count -lt 100;$n++){Invoke-DomeniaLiveTick};Assert-Live ([object]::ReferenceEquals($before,$script:Ctrl.DgObjects.ItemsSource) -and $script:Live.Search.Rows.Count -eq 100)}
Case 'La finalisation attend le drainage puis prépare un cache' {End-Live;Assert-Live ($script:Live.Search.Finalized -and $script:Live.QueryToSave.Rows.Count -eq 100)}
Case 'Deux publications du même objet n ajoutent pas deux lignes' {Reset-LiveFixture;Feed-Live (New-FixtureRow);Feed-Live (New-FixtureRow);for($n=0;$n -lt 5;$n++){Invoke-DomeniaLiveTick};Assert-Live ($script:Live.Search.Rows.Count -eq 1)}
Case 'Les nouveaux résultats AD remplacent un cache plein' {Reset-LiveFixture;$script:State.Limit=2;Feed-Live (New-FixtureRow 'OLD1') 'CachedRow';Feed-Live (New-FixtureRow 'OLD2') 'CachedRow';for($n=0;$n -lt 5;$n++){Invoke-DomeniaLiveTick};Feed-Live (New-FixtureRow 'NEW1');Feed-Live (New-FixtureRow 'NEW2');End-Live;Assert-Live ($script:Live.Search.Rows.Count -eq 2 -and $script:Live.Search.Fresh.Count -eq 2 -and $script:Live.Search.Rows[0].Name -like 'NEW*')}
Case 'Résultat vide valide retire les lignes du cache' {Reset-LiveFixture;Feed-Live (New-FixtureRow) 'CachedRow';Invoke-DomeniaLiveTick;End-Live;Assert-Live ($script:Live.Search.Rows.Count -eq 0 -and $script:Live.QueryToSave.Rows.Count -eq 0)}
Case 'Une liste partielle n est pas enregistrée comme complète' {Reset-LiveFixture;Feed-Live (New-FixtureRow);End-Live $true;Assert-Live ($script:Live.Search.Rows.Count -eq 1 -and $null -eq $script:Live.QueryToSave)}
Case 'Erreur conserve une ligne connue et son origine cache' {Reset-LiveFixture;Feed-Live (New-FixtureRow) 'CachedRow';Fail-DomeniaLiveSearch 'Fixture inaccessible' $script:State;for($n=0;$n -lt 4;$n++){Invoke-DomeniaLiveTick};Assert-Live ($script:Live.Search.Rows.Count -eq 1 -and $script:Live.Search.Rows[0].DirectoryState.Contains('Cache'))}
Case 'Changer de génération invalide le flux précédent' {Reset-LiveFixture;$oldPayload=$script:Payload;$oldState=$script:State;$script:GlobalSearchGeneration++;$script:State.Generation=$script:GlobalSearchGeneration;$script:Payload=[pscustomobject]@{};[void](Begin-DomeniaLiveSearch $script:State $script:Payload);$oldPayload.Progress.Enqueue([pscustomobject]@{Kind='Row';Row=New-FixtureRow});Invoke-DomeniaLiveTick;Assert-Live ($script:Live.Search.Rows.Count -eq 0 -and $oldPayload.StopToken.IsCancellationRequested)}
Case 'Filtre local recherche le compte observé sans changer OU' {Reset-LiveFixture;Feed-Live (New-FixtureRow);Invoke-DomeniaLiveTick;$script:Live.Search.Rows[0].SessionDisplay='EXAMPLE\alice';$script:Ctrl.TxtSuiteResultFilter.Text='alice';Update-DomeniaLiveFilter;Assert-Live ($script:Ctrl.DgObjects.Items.Count -eq 1 -and $script:SelectedBranchDn -like 'OU=Test,*')}
Case 'Filtre littéral ne traite pas les crochets en regex' {$script:Ctrl.TxtSuiteResultFilter.Text='[alice]';Update-DomeniaLiveFilter;Assert-Live ($script:Ctrl.DgObjects.Items.Count -eq 0)}
Case 'Vérification dédupliquée dans la file' {
    # Since RC1.10.7 a probe needs the selection intent of the single selected machine (no collective ping):
    # select the row through the real Select-DomeniaLiveResult, then ask twice more for the same row.
    Reset-LiveFixture;Feed-Live (New-FixtureRow);Invoke-DomeniaLiveTick;$row=$script:Live.Search.Rows[0]
    $script:Ctrl.DgObjects.SelectedItem=$row
    Assert-Live (@($script:Ctrl.DgObjects.SelectedItems).Count -eq 1) 'Selection de la ligne de fixture non prise en compte par la grille.'
    Select-DomeniaLiveResult
    Assert-Live ($null -ne $script:Live.ProbeSelection) 'Aucune intention de sondage pour la machine selectionnee.'
    Request-DomeniaLiveProbe $row;Request-DomeniaLiveProbe $row
    Assert-Live ($script:Live.PendingKeys.Count -eq 1 -and $script:Live.Pending.Count -eq 1) ('File : '+$script:Live.PendingKeys.Count+' cle(s), '+$script:Live.Pending.Count+' entree(s)')
}
Case 'Sans intention de sélection, aucune vérification n est mise en file' {Reset-LiveFixture;Feed-Live (New-FixtureRow);Invoke-DomeniaLiveTick;$row=$script:Live.Search.Rows[0];Request-DomeniaLiveProbe $row;Assert-Live ($script:Live.PendingKeys.Count -eq 0 -and $script:Live.Pending.Count -eq 0)}
Case 'Désactiver la détection n empêche pas le chargement AD' {Reset-LiveFixture;$script:Live.AutoDetect=$false;Feed-Live (New-FixtureRow);Invoke-DomeniaLiveTick;Assert-Live ($script:Live.Search.Rows.Count -eq 1 -and $script:Live.PendingKeys.Count -eq 0)}
Case 'Appel annulé compte toujours dans les ressources occupées' {Reset-LiveFixture;$script:AsyncJobs['a']=[pscustomobject]@{OperationId='LiveConsole';CancelRequested=$true};$script:DetachedReadJobs=@([pscustomobject]@{OperationId='LiveConsole'});Assert-Live ((Get-DomeniaLiveWorkerCount 'LiveConsole') -eq 2)}
Case 'Ecriture en cours suspend le rendu des lignes reçues' {Reset-LiveFixture;Feed-Live (New-FixtureRow);$script:ActiveWriteTaskId='write';Invoke-DomeniaLiveTick;Assert-Live ($script:Live.Search.Rows.Count -eq 0);$script:ActiveWriteTaskId='';Invoke-DomeniaLiveTick;Assert-Live ($script:Live.Search.Rows.Count -eq 1)}
Case 'Etat inconnu d ecriture suspend également le rendu' {Reset-LiveFixture;Feed-Live (New-FixtureRow);$script:WriteState='Unknown';Invoke-DomeniaLiveTick;Assert-Live ($script:Live.Search.Rows.Count -eq 0)}
Case 'Réponse d un ancien compte ne réenregistre aucune observation' {Reset-LiveFixture;$state=[pscustomobject]@{Identity=$script:Live.Identity;Epoch=1;Key=$observed.Key;Guid=$observed.Guid;Computer=$observed.Computer;Generation=1};$script:ProcessIdentity='EXAMPLE\autre';Complete-DomeniaLiveProbe $observed $state;Assert-Live ($script:Live.Observations.Count -eq 0 -and $script:Live.SaveQueue.Count -eq 0)}
Case 'Succès de session notifie la ligne et prépare la persistance' {Reset-LiveFixture;Feed-Live (New-FixtureRow);Invoke-DomeniaLiveTick;$state=[pscustomobject]@{Identity=$script:Live.Identity;Epoch=1;Key=$observed.Key;Guid=$observed.Guid;Computer=$observed.Computer;Generation=1};Complete-DomeniaLiveProbe $observed $state;Assert-Live ($script:Live.Search.Rows[0].SessionDisplay -eq 'EXAMPLE\alice' -and $script:Live.SaveQueue.Count -eq 1)}
Case 'Rejet distant coupe les nouvelles sondes, conserve le compte connu' {$r=[pscustomobject]@{Key=$observed.Key;Computer=$observed.Computer;Guid=$observed.Guid;Outcome='AuthRejected';User=''};$probeState=[pscustomobject]@{Identity=$script:Live.Identity;Epoch=1;Key=$observed.Key;Guid=$observed.Guid;Computer=$observed.Computer;Generation=1};Complete-DomeniaLiveProbe $r $probeState;Assert-Live ($script:Live.RemoteFaulted -and $script:Live.PendingKeys.Count -eq 0 -and $script:Live.Search.Rows[0].SessionDisplay.Contains('alice'))}
# Actual SQLite roundtrips use only a newly created temporary database.
$dbPath=Join-Path $testDirectory 'fixture.db';$scope=Get-DomeniaLiveHash 'fixture-scope';$queryKey=Get-DomeniaLiveHash 'fixture-query'
function Invoke-FixtureCache {param($Payload) & ([scriptblock]::Create((Get-DomeniaLiveCacheCode)))}
function Read-FixtureSql {param($Sql) $h=Open-DomeniaDatabase -Path $dbPath;try{return @(Invoke-DomeniaDbQuery $Sql $h)}finally{Close-DomeniaDatabase $h}}
function Exec-FixtureSql {param($Sql) $h=Open-DomeniaDatabase -Path $dbPath;try{[void](Invoke-DomeniaDbExec $Sql $h)}finally{Close-DomeniaDatabase $h}}
Case 'Lecture du cache manquant ne crée pas le fichier' {$pay=[pscustomobject]@{Mode='Read';Path=$dbPath;Scope=$scope;QueryKey=$queryKey;LoadObservations=$false};Invoke-FixtureCache $pay;Assert-Live (-not [IO.File]::Exists($dbPath))}
$query=[pscustomobject]@{QueryKey=$queryKey;ObservedUtc=[datetime]::UtcNow.ToString('o');Rows=@((ConvertTo-DomeniaLiveSnapshot (New-FixtureRow "PC-D'ESSAI")))}
$known.CheckedUtc=[datetime]::UtcNow.ToString('o')
Case 'Cache SQLite écrit les projections et observations' {Invoke-FixtureCache ([pscustomobject]@{Mode='Write';Path=$dbPath;Scope=$scope;Observations=@($known);Query=$query});Assert-Live (@(Read-FixtureSql 'SELECT * FROM adcc_live_queries;').Count -eq 1)}
Case 'Cache SQLite roundtrip apostrophe et périmètre exact' {$queue=[Collections.Concurrent.ConcurrentQueue[object]]::new();$store=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new();Invoke-FixtureCache ([pscustomobject]@{Mode='Read';Path=$dbPath;Scope=$scope;QueryKey=$queryKey;LoadObservations=$true;Progress=$queue;ObservationStore=$store;Limit=100});$event=$null;[void]$queue.TryDequeue([ref]$event);Assert-Live ($event.Row.Name -eq "PC-D'ESSAI" -and $store.Count -eq 1)}
Case 'Compte différent ne récupère pas le cache' {$queue=[Collections.Concurrent.ConcurrentQueue[object]]::new();Invoke-FixtureCache ([pscustomobject]@{Mode='Read';Path=$dbPath;Scope=(Get-DomeniaLiveHash 'another');QueryKey=$queryKey;LoadObservations=$false;Progress=$queue;Limit=100});Assert-Live ($queue.Count -eq 0)}
Case 'Chargement cache ne remplace pas une observation déjà présente' {$queue=[Collections.Concurrent.ConcurrentQueue[object]]::new();$store=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new();$store[$known.Key]=[pscustomobject]@{CurrentUser='EXAMPLE\nouveau'};Invoke-FixtureCache ([pscustomobject]@{Mode='Read';Path=$dbPath;Scope=$scope;QueryKey=$queryKey;LoadObservations=$true;Progress=$queue;ObservationStore=$store;Limit=100});Assert-Live ($store[$known.Key].CurrentUser -eq 'EXAMPLE\nouveau')}
Case 'Transaction SQLite annulée si observation invalide' {$before=@(Read-FixtureSql 'SELECT * FROM adcc_live_queries;').Count;$badQuery=[pscustomobject]@{QueryKey=(Get-DomeniaLiveHash 'not-commit');ObservedUtc=[datetime]::UtcNow.ToString('o');Rows=@()};$bad=[pscustomobject]@{Key='bad';Detail=('x'*20000)};$failed=$false;try{Invoke-FixtureCache ([pscustomobject]@{Mode='Write';Path=$dbPath;Scope=$scope;Query=$badQuery;Observations=@($bad)})}catch{$failed=$true};Assert-Live ($failed -and @(Read-FixtureSql 'SELECT * FROM adcc_live_queries;').Count -eq $before)}
Case 'Cache expire sans supprimer une table métier' {Exec-FixtureSql "CREATE TABLE business_fixture(id INTEGER); INSERT INTO business_fixture VALUES(1); UPDATE adcc_live_queries SET observed_utc='2000-01-01T00:00:00Z';";Invoke-FixtureCache ([pscustomobject]@{Mode='Write';Path=$dbPath;Scope=$scope;Query=$null;Observations=@()});Assert-Live (@(Read-FixtureSql 'SELECT * FROM adcc_live_queries;').Count -eq 0 -and @(Read-FixtureSql 'SELECT * FROM business_fixture;').Count -eq 1)}
# These doubles intercept every network boundary, including the optional ping.
function Invoke-ProbeFixture {
    param([string]$User='EXAMPLE\alice',[string]$ErrorKind='', [switch]$AdError,$Previous=$null,[bool]$AllowIdentityCache=$true)
    $script:ProbeCalls=@{Sessions=0;Reads=0;Closes=0;Ldap=0;Credential=$null}
    $Context=[pscustomobject]@{MachineCredential=$script:RemoteFixture;Credential=$script:AdFixture;Domain='example.invalid';Netbios='EXAMPLE';BaseDn='DC=example,DC=invalid';UseCim=$true}
    $Payload=[pscustomobject]@{Computer='pc-01.example.invalid';Key=$observed.Key;Guid=$observed.Guid;MethodSeconds=4;Previous=$Previous;AllowIdentityCache=$AllowIdentityCache}
    function Get-WMachineCredential {param($Context) return $Context.MachineCredential}
    function New-Object {
        param($TypeName)
        if($TypeName -ne 'Net.NetworkInformation.Ping'){throw ('Construction inattendue : '+$TypeName)}
        $o=[pscustomobject]@{}
        Add-Member -InputObject $o ScriptMethod Send {param($target,$ms) [pscustomobject]@{Status='TimedOut'}}
        Add-Member -InputObject $o ScriptMethod Dispose { }
        return $o
    }
    function New-CimSessionOption {param($Protocol,$ErrorAction) Assert-Live ($Protocol -eq 'Dcom');return [pscustomobject]@{Protocol=$Protocol}}
    function New-CimSession {
        param($ComputerName,$SessionOption,$OperationTimeoutSec,$Credential,$ErrorAction)
        $script:ProbeCalls.Sessions++;$script:ProbeCalls.Credential=$Credential
        if($ErrorKind -eq 'Denied'){throw [UnauthorizedAccessException]::new('Fixture refusée')}
        if($ErrorKind -eq 'Auth'){throw [Runtime.InteropServices.COMException]::new('Fixture authentification',-2147023570)}
        return [pscustomobject]@{Fake=$true}
    }
    function Get-CimInstance {param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction) $script:ProbeCalls.Reads++;Assert-Live ($ClassName -eq 'Win32_ComputerSystem');return [pscustomobject]@{UserName=$User}}
    function Remove-CimSession {param($CimSession,$ErrorAction) $script:ProbeCalls.Closes++}
    function Get-WPropFirst {param($Props,$Name,$Default) if($null -ne $Props -and $Props.ContainsKey($Name)){return $Props[$Name]};return $Default}
    function Convert-WGuid {param($Value) return [string]$Value}
    function New-WSearcher {
        param($Ctx,$BaseDn,$Filter,$Properties,$Scope,$Limit)
        $script:ProbeCalls.Ldap++
        Assert-Live ([object]::ReferenceEquals($Ctx.Credential,$script:AdFixture)) 'Compte AD distinct requis'
        if($AdError){throw [Runtime.InteropServices.COMException]::new('Fixture rejet AD',-2147023570)}
        $o=[pscustomobject]@{SearchRoot=$null;ServerTimeLimit=[TimeSpan]::Zero;ClientTimeout=[TimeSpan]::Zero}
        Add-Member -InputObject $o ScriptMethod FindAll {return ,([object[]]@([pscustomobject]@{Properties=@{samaccountname='alice';distinguishedname='CN=Alice,DC=example,DC=invalid';objectguid='00000000-0000-0000-0000-000000000002'}}))}
        Add-Member -InputObject $o ScriptMethod Dispose { }
        return $o
    }
    & ([scriptblock]::Create((Get-DomeniaLiveProbeCode)))
}
$script:RemoteFixture=[pscustomobject]@{UserName='EXAMPLE\postes'}
$script:AdFixture=[pscustomobject]@{UserName='EXAMPLE\annuaire'}
Case 'Sonde réelle sur doubles : un compte poste, un transport et nettoyage' {$r=Invoke-ProbeFixture;Assert-Live ($r.Outcome -eq 'Observed' -and $r.User -eq 'EXAMPLE\alice' -and $script:ProbeCalls.Sessions -eq 1 -and $script:ProbeCalls.Reads -eq 1 -and $script:ProbeCalls.Closes -eq 1 -and [object]::ReferenceEquals($script:ProbeCalls.Credential,$script:RemoteFixture))}
Case 'L utilisateur AD vérifié devient une association, pas un compte local deviné' {$r=Invoke-ProbeFixture;Assert-Live ($r.LinkUser -eq 'alice' -and $r.UserDn -eq 'CN=Alice,DC=example,DC=invalid')}
Case 'Parc incremental : meme console une lecture legere et aucune requete LDAP' {
 $previous=[pscustomobject]@{Version=1;Key=$observed.Key;Guid=$observed.Guid;RawAccount='EXAMPLE\alice';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='cached-guid';UserUsn='5';DirectoryChanged=$false;IdentityCheckedUtc=[datetime]::UtcNow.ToString('o')}
 $r=Invoke-ProbeFixture -Previous $previous
 Assert-Live ($r.CacheReused -and $script:ProbeCalls.Ldap -eq 0 -and $script:ProbeCalls.Reads -eq 1 -and $r.UserGuid -eq 'cached-guid' -and $r.IdentityCheckedUtc -ceq $previous.IdentityCheckedUtc)
}
Case 'Parc incremental : identite modifiee ou machine recreee oblige une resolution' {
 foreach($change in @('RawAccount','Guid','Key','DirectoryChanged','UserGuid')){
  $p=[pscustomobject]@{Version=1;Key=$observed.Key;Guid=$observed.Guid;RawAccount='EXAMPLE\alice';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='cached-guid';UserUsn='5';DirectoryChanged=$false;IdentityCheckedUtc=[datetime]::UtcNow.ToString('o')}
  switch($change){RawAccount{$p.RawAccount='EXAMPLE\bob'}Guid{$p.Guid='recreated'}Key{$p.Key='another-domain'}DirectoryChanged{$p.DirectoryChanged=$true}UserGuid{$p.UserGuid=''}}
  $r=Invoke-ProbeFixture -Previous $p;Assert-Live (-not $r.CacheReused -and $script:ProbeCalls.Ldap -eq 1) $change
 }
}
Case 'Parc incremental : identite absente, invalide, expiree ou future relue dans AD' {
 foreach($stamp in @('', 'broken', [datetime]::UtcNow.AddMinutes(-6).ToString('o'), [datetime]::UtcNow.AddMinutes(2).ToString('o'))){
  $p=[pscustomobject]@{Version=1;Key=$observed.Key;Guid=$observed.Guid;RawAccount='EXAMPLE\alice';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='cached-guid';UserUsn='5';DirectoryChanged=$false;IdentityCheckedUtc=$stamp}
  $r=Invoke-ProbeFixture -Previous $p
  Assert-Live (-not $r.CacheReused -and $script:ProbeCalls.Ldap -eq 1 -and $r.IdentityCheckedUtc -and $r.IdentityCheckedUtc -ne $stamp) ('Identity timestamp '+$stamp)
 }
}
Case 'Parc incremental : Forcer contourne meme une identite recente' {
 $p=[pscustomobject]@{Version=1;Key=$observed.Key;Guid=$observed.Guid;RawAccount='EXAMPLE\alice';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='cached-guid';UserUsn='5';DirectoryChanged=$false;IdentityCheckedUtc=[datetime]::UtcNow.ToString('o')}
 $r=Invoke-ProbeFixture -Previous $p -AllowIdentityCache $false
 Assert-Live (-not $r.CacheReused -and $script:ProbeCalls.Ldap -eq 1)
}
Case 'Parc incremental : un cache ne transforme pas un compte local en compte AD' {
 $p=[pscustomobject]@{Version=1;Key=$observed.Key;Guid=$observed.Guid;RawAccount='PC-01\alice';LinkUser='alice';UserDn='CN=Alice,DC=example,DC=invalid';UserGuid='cached-guid'}
 $r=Invoke-ProbeFixture -User 'PC-01\alice' -Previous $p;Assert-Live (-not $r.CacheReused -and -not $r.LinkUser -and $script:ProbeCalls.Ldap -eq 0)
}
Case 'Nom de compte local jamais interprété comme un compte du domaine' {$r=Invoke-ProbeFixture -User 'PC-01\alice';Assert-Live ($r.Outcome -eq 'Observed' -and -not $r.LinkUser -and $script:ProbeCalls.Ldap -eq 0)}
Case 'Nom nu jamais réinterprété comme identité AD' {$r=Invoke-ProbeFixture -User 'alice';Assert-Live ($script:ProbeCalls.Ldap -eq 0 -and -not $r.LinkUser)}
Case 'Console vide ne déclenche pas de recherche de profils historique' {$r=Invoke-ProbeFixture -User '';Assert-Live ($r.Outcome -eq 'NoConsole' -and $script:ProbeCalls.Reads -eq 1 -and $script:ProbeCalls.Ldap -eq 0)}
Case 'Refus de droits classé séparément du rejet de credential' {$r=Invoke-ProbeFixture -ErrorKind 'Denied';Assert-Live ($r.Outcome -eq 'Denied' -and $script:ProbeCalls.Sessions -eq 1)}
Case 'Rejet de credential conserve son état sans autre essai' {$r=Invoke-ProbeFixture -ErrorKind 'Auth';Assert-Live ($r.Outcome -eq 'AuthRejected' -and $script:ProbeCalls.Sessions -eq 1 -and $script:ProbeCalls.Reads -eq 0)}
Case 'Rejet LDAP ne transforme pas un compte console observé en absence' {$r=Invoke-ProbeFixture -AdError;Assert-Live ($r.Outcome -eq 'Observed' -and $r.DirectoryAuthRejected -and -not $r.LinkUser)}
# SE-03 : le worker des widgets ne connait aucune classe interdite, il ne lit que le catalogue transmis.
function Invoke-ProbeCatalogFixture {
    param([string[]]$AllowedClasses=$null,[string]$Class='CIM_Product')
    $script:CatalogCalls=@()
    $Context=[pscustomobject]@{MachineCredential=$script:RemoteFixture;Credential=$script:AdFixture;Domain='example.invalid';Netbios='EXAMPLE';BaseDn='DC=example,DC=invalid';UseCim=$true}
    $Payload=[pscustomobject]@{Computer='pc-01.example.invalid';Key=$observed.Key;Guid=$observed.Guid;MethodSeconds=4;ProbeUser=$true;Probes=@([pscustomobject]@{Id='sonde';Class=$Class;Namespace='root\cimv2';Properties=@('Name');Filter='';Skip=''})}
    if($PSBoundParameters.ContainsKey('AllowedClasses')){$Payload | Add-Member -NotePropertyName AllowedClasses -NotePropertyValue @($AllowedClasses)}
    function Get-WMachineCredential {param($Context) return $Context.MachineCredential}
    function New-Object {param($TypeName) $o=[pscustomobject]@{};Add-Member -InputObject $o ScriptMethod Send {param($t,$ms) $null};Add-Member -InputObject $o ScriptMethod Dispose { };return $o}
    function New-CimSessionOption {param($Protocol,$ErrorAction) return [pscustomobject]@{Protocol=$Protocol}}
    function New-CimSession {param($ComputerName,$SessionOption,$OperationTimeoutSec,$Credential,$ErrorAction) return [pscustomobject]@{Fake=$true}}
    function Get-CimInstance {param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction,$Namespace,$Filter) $script:CatalogCalls+=[string]$ClassName;if($ClassName -eq 'Win32_ComputerSystem'){return [pscustomobject]@{UserName=''}};return [pscustomobject]@{Name='fixture'}}
    function Remove-CimSession {param($CimSession,$ErrorAction) }
    & ([scriptblock]::Create((Get-DomeniaLiveProbeCode)))
}
Case 'Sonde hors catalogue refusee par le worker des widgets' {$r=Invoke-ProbeCatalogFixture -AllowedClasses @('Win32_ComputerSystem');Assert-Live ($r.Probes.sonde.Error -match 'catalogue de sondes' -and $script:CatalogCalls -notcontains 'CIM_Product')}
Case 'Sonde sans catalogue transmis refusee par le worker des widgets' {$r=Invoke-ProbeCatalogFixture;Assert-Live ($r.Probes.sonde.Error -match 'Catalogue de sondes absent' -and $script:CatalogCalls -notcontains 'CIM_Product')}
Case 'Sonde du catalogue traverse la garde et atteint le poste' {$r=Invoke-ProbeCatalogFixture -Class 'Win32_BIOS' -AllowedClasses @('Win32_ComputerSystem','Win32_BIOS');Assert-Live ($r.Probes.sonde.Error -eq '' -and $script:CatalogCalls -contains 'Win32_BIOS')}

Case 'Chemin de cache déjà résolu sans réinitialisation du stockage' {Reset-LiveFixture;$script:DatabaseScopeIdentity='dc=example,dc=invalid';$script:DatabaseScopedPath=Join-Path $testDirectory 'scope.db';Assert-Live ((Get-DomeniaLiveDatabasePath) -eq $script:DatabaseScopedPath)}
Case 'Identité de consultation changée invalide les informations de session visibles' {Reset-LiveFixture;Feed-Live (New-FixtureRow);Invoke-DomeniaLiveTick;$oldRow=$script:Live.Search.Rows[0];$script:ProcessIdentity='EXAMPLE\autre';Invoke-DomeniaLiveTick;Assert-Live ($oldRow.SessionState -eq 'Compte changé · à revérifier')}
Case 'Journal de test ne contient aucun secret de projection' {Assert-Live (-not (($script:Cases|ConvertTo-Json -Depth 5).Contains('secret-fixture')))}
}finally{
    if($null -ne $script:Live -and $null -ne $script:Live.Timer){$script:Live.Timer.Stop()}
    if($null -ne $script:Window){$script:Window.Close()}
}
$failed=@($script:Cases|Where-Object {-not $_.Passed}).Count
$report=[ordered]@{Build='2026.09.30-R1.12-PROGRESSIVE';Environment='Windows PowerShell 5.1 / WPF / SQLite temporaire';Executed=(Get-Date).ToString('o');Passed=($script:Cases.Count-$failed);Failed=$failed;Tests=$script:Cases.ToArray();FixtureDirectory=$testDirectory;NoADAccess=$true}
if(-not $ReportPath){$ReportPath=Join-Path $testDirectory 'results.json'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ('Rapport : '+$ReportPath)}
if($failed){throw ('Tests progressifs en échec : '+$failed+'. Rapport : '+$ReportPath)}
