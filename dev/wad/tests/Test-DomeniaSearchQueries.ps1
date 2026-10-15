#requires -Version 5.1
# Actual query DLL/worker with local fixtures. UI ports and the SQLite dispatch are simulated, not AD or WPF.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','Boards.Model','BoardFleet.Model','Probes.Model','Query.Model','Query.Worker','Search.Model','Search.UI','Query.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:Checks=[Collections.Generic.List[object]]::new()
function Case([string]$Name,[scriptblock]$Body){try{& $Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$true;Error=''})}catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$false;Error=$_.Exception.Message})}}
function Expect([bool]$Ok,[string]$Message='Assertion failed'){if(-not $Ok){throw $Message}}
$saved=New-DomeniaQueryRecipe -Id 'fixture.saved' -Name 'Postes du support'
$catalog=@(Get-DomeniaSearchQueryCatalog -Saved @($saved) -Favorites @('ad:expiring','local:fixture.saved'))
Case 'Catalog: 13 LDAP views (5 original, 8 account reviews of points 101-102), 152 local models, one saved recipe' {Expect ($catalog.Count -eq 166);Expect (@($catalog|Where-Object SourceId -eq Ad).Count -eq 13);Expect (@($catalog|Where-Object SourceId -eq Local).Count -eq 153)}
Case 'Catalog: account review views are user views of the chosen OU, listed under Utilisateurs' {foreach($id in @('expiredaccounts','lockedusers','inactiveusers','neverloggedusers','pwdneverexpires','pwdnotrequired','pwdold','pwdmustchange')){$entry=@($catalog|Where-Object Id -eq ('ad:'+$id));Expect ($entry.Count -eq 1) ('Vue absente : '+$id);Expect ($entry[0].TypeLabel -eq 'Utilisateurs' -and $null -eq $entry[0].Recipe -and [string]$entry[0].Description) $id;$view=@(Get-DomeniaWorkViews|Where-Object Id -eq $id)[0];Expect ([bool]$view.NeedsOu -and $view.Filter.StartsWith('(&(objectCategory=person)(objectClass=user)')) $id}}
Case 'Catalog: identifiers unique and both favorites preserved' {Expect (@($catalog.Id|Sort-Object -Unique).Count -eq $catalog.Count);Expect (@($catalog|Where-Object Favorite).Count -eq 2)}
Case 'Catalog: user disable view remains separate from computer disable recipe' {$ad=@($catalog|Where-Object Id -eq 'ad:disabled')[0];$local=@($catalog|Where-Object Id -eq 'local:template.disabled')[0];Expect ($ad.TypeLabel -eq 'Utilisateurs' -and $local.TypeLabel -eq 'Postes');Expect ($null -eq $ad.Recipe)}
Case 'Catalog: LDAP stale retains absent lastLogonTimestamp and no active-only clause' {$view=@(Get-DomeniaWorkViews|Where-Object Id -eq stalecomputers)[0];Expect ($view.Filter.Contains('(!(lastLogonTimestamp=*))'));Expect (-not $view.Filter.Contains('userAccountControl'))}
Case 'Catalog: local stale keeps existing active, known-date semantics' {$recipe=@($catalog|Where-Object Id -eq 'local:template.stale')[0].Recipe;Expect ($recipe.Clauses.Count -eq 3 -and $recipe.Clauses[0].Field -eq 'active')}
Case 'Catalog: accent-insensitive local filtering does not execute a query' {$rows=@(Find-DomeniaSearchQuery -Entries $catalog -Text 'desactives');Expect ($rows.Count -ge 2);Expect (@($rows|Where-Object Id -eq 'ad:disabled').Count -eq 1)}
Case 'Catalog: favorites filter intersects text' {Expect (@(Find-DomeniaSearchQuery -Entries $catalog -FavoritesOnly -Text 'support').Count -eq 1);Expect (@(Find-DomeniaSearchQuery -Entries $catalog -FavoritesOnly -Text 'absentxyz').Count -eq 0)}
Case 'Catalog: every local entry compiles through the actual shared DLL' {foreach($entry in $catalog){if($entry.SourceId -eq 'Local'){[void](ConvertTo-DomeniaCompiledQuery $entry.Recipe)}}}
$now=[datetime]::UtcNow
$guid1='11111111-1111-1111-1111-111111111111';$guid2='22222222-2222-2222-2222-222222222222';$guid3='33333333-3333-3333-3333-333333333333'
$dn='OU=Recherche,DC=example,DC=test'
$fleet=[pscustomobject]@{Scope=$dn;Subtree=$false;Busy=$false;Missing=$false;Groups=@([pscustomobject]@{gid='a';os='Windows 11';ver='26100';lb=0;cr='R';pw='R';lk='N';bk='U'},[pscustomobject]@{gid='d';os='Windows 10';ver='19045';lb=5;cr='';pw='';lk='';bk='U'});Machines=@(
    [pscustomobject]@{name='PC-C';object_guid=$guid1;distinguished_name=('CN=PC-C,'+$dn);gid='a';st='A';logon='2026-10-10'},
    [pscustomobject]@{name='PC-B';object_guid=$guid2;distinguished_name=('CN=PC-B,'+$dn);gid='a';st='A';logon='2026-10-10'},
    [pscustomobject]@{name='PC-A';object_guid=$guid3;distinguished_name=('CN=PC-A,'+$dn);gid='d';st='D';logon=''});Presence=@(
    [pscustomobject]@{object_key=('CN=PC-C,'+$dn).ToLowerInvariant();observation=[pscustomobject]@{Guid=$guid1;CheckedUtc=$now.ToString('o');Inventory=[pscustomobject]@{CheckedUtc=$now.ToString('o');RamBytes=4GB}}},
    [pscustomobject]@{object_key=('CN=PC-B,'+$dn).ToLowerInvariant();observation=[pscustomobject]@{Guid=$guid2;CheckedUtc=$now.ToString('o');Inventory=[pscustomobject]@{CheckedUtc=$now.ToString('o');RamBytes=16GB}}})}
$ramRecipe=New-DomeniaQueryRecipe -Name 'RAM < 8' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=8})
function Invoke-FixtureWorker($Recipe=$ramRecipe,[string]$Selection='Match',[int]$Limit=100,$Records=$null){
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Records=$Records;Recipe=$Recipe;Saved=@();Fleet=$fleet;Observations=@{};Offset=0;Selection=$Selection;TextFilter='';StateFilter='';MaxAgeDays=30;Lifecycle=$null;SearchOutput=$true;Limit=$Limit;SortField='name';Descending=$false}
    & ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
}
foreach($selection in @('Match','Unknown','NoMatch')){
    Case ('Worker: '+$selection+' selects one row with complete totals') {$result=Invoke-FixtureWorker -Selection $selection;Expect ($result.Rows.Count -eq 1 -and $result.Matched -eq 1 -and $result.Unknown -eq 1 -and $result.NotMatched -eq 1 -and $result.ScopeTotal -eq 3);Expect ($result.Scope -eq $dn -and -not $result.Subtree);Expect ($result.Rows[0].Type -eq 'Machine')}
}
Case 'Worker: all local computers include disabled and keep GUID/DN identities' {$result=Invoke-FixtureWorker -Recipe (New-DomeniaQueryRecipe);Expect ($result.Rows.Count -eq 3 -and $result.Rows[0].Name -eq 'PC-A' -and $result.Rows[0].State -eq 'Désactivé' -and $result.Rows[0].Guid -eq $guid3)}
Case 'Worker: limit truncates rows only, not population counts' {$result=Invoke-FixtureWorker -Recipe (New-DomeniaQueryRecipe) -Limit 1;Expect ($result.Rows.Count -eq 1 -and $result.Total -eq 3 -and $result.Matched -eq 3 -and $result.Limit -eq 1)}
Case 'Worker: invalid limit rejected' {$failed=$false;try{Invoke-FixtureWorker -Limit 0|Out-Null}catch{$failed=$true};Expect $failed}
Case 'Worker: different GUID at reused DN stays unknown' {$original=$fleet.Presence[0].observation.Guid;try{$fleet.Presence[0].observation.Guid=$guid3;$result=Invoke-FixtureWorker;Expect ($result.Matched -eq 0 -and $result.Unknown -eq 2)}finally{$fleet.Presence[0].observation.Guid=$original}}
Case 'Worker: expired inventory stays unknown despite recent ping' {$original=$fleet.Presence[0].observation.Inventory.CheckedUtc;try{$fleet.Presence[0].observation.Inventory.CheckedUtc=$now.AddDays(-40).ToString('o');$result=Invoke-FixtureWorker;Expect ($result.Matched -eq 0 -and $result.Unknown -eq 2)}finally{$fleet.Presence[0].observation.Inventory.CheckedUtc=$original}}
Case 'Worker: second DLL page preserves 10002 rows and global ordering' {
    $records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    for($i=10001;$i -ge 0;$i--){$values=[Collections.Generic.Dictionary[string,object]]::new();$values['name']='PC-'+$i.ToString('D5');$values['dn']='CN='+$values['name']+','+$dn;$values['active']=$true;$records.Add([M4D.Admin.Common.Query.QueryRecord]::new([guid]::NewGuid().ToString('D'),$values))}
    $result=Invoke-FixtureWorker -Recipe (New-DomeniaQueryRecipe) -Records $records -Limit 20000
    Expect ($result.Rows.Count -eq 10002 -and $result.Total -eq 10002 -and $result.Limit -eq 20000);Expect ($result.Rows[0].Name -eq 'PC-00000' -and $result.Rows[10001].Name -eq 'PC-10001');Expect (@($result.Rows.Guid|Sort-Object -Unique).Count -eq 10002)
}

# In-memory ports let actual UI callbacks run without WPF or remote calls.
$script:Settings=@{};$script:Controls=@{};$script:Jobs=[Collections.Generic.List[object]]::new();$script:Shown=@();$script:Status='';$script:AdCalls=0
function Get-DomeniaSetting($Name,$Default){if($script:Settings.ContainsKey($Name)){return $script:Settings[$Name]};return $Default}
function Set-DomeniaSetting($Name,$Value){$script:Settings[$Name]=$Value}
function Save-DomeniaSettings {param([switch]$Immediate,[switch]$ThrowOnFailure)}
function Get-DomeniaControl($Name){return $script:Controls[$Name]}
function Set-DomeniaControlText($Name,$Text){if($script:Controls.ContainsKey($Name)){$script:Controls[$Name].Text=[string]$Text};return $true}
function Get-DomeniaSearchScope {param($Mode);if(-not [string]$script:Conn.BaseDn){throw 'Session sans base AD'};return $script:FixtureScope}
function Get-DomeniaSearchMode {return $script:SearchMode}
function Set-DomeniaSearchMode {param($Mode);$script:SearchMode=$Mode}
function Get-DomeniaSearchText {param($Mode);return [string]$script:Controls.TxtBranchSearch.Text}
function Get-DomeniaObservationMaxAgeDays {return 30}
function Get-DomeniaWindowsLifecycleTable {return $null}
function Test-DomeniaAccessBusyWrite {return $false}
function Test-DomeniaDraftNavigation {param($DN);return $true}
function Enter-DomeniaNavSearch {}
function Stop-DomeniaPendingFilterChange {}
function Invalidate-DomeniaSearchResults {$script:GlobalSearchGeneration++;$script:Shown=@()}
function Initialize-DomeniaWinSqliteNative {return $true}
function Update-DomeniaSearchMoreButton {param($Search)}
function Set-Status {param($Text,$Level);$script:Status=[string]$Text}
function Apply-DomeniaPresenceFilter {$script:AppliedFilters++}
function Show-ObjectRows {param($Rows,$Label,[switch]$SkipPresenceScan,[switch]$NoAutoOpen);Expect ($SkipPresenceScan -and $NoAutoOpen);$script:Shown=@($Rows);$script:ShownLabel=$Label}
function Invoke-GlobalSearch {param($ViewId,$ViewScope);$script:AdCalls++;$script:LastAdView=$ViewId;$script:LastAdScope=$ViewScope}
function Get-DomeniaLocalIndexReadWorkerCode {return 'fixture read worker'}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass);$script:Jobs.Add([pscustomobject]@{Operation=$OperationId;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey});return ('fixture-'+$script:Jobs.Count)}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);foreach($candidate in @($Result)){$good=$true;foreach($p in $RequiredProperties){if($null -eq $candidate.PSObject.Properties[$p]){$good=$false;break}};if($good){return $candidate}};return $null}
function Reset-Fixture {
    $script:Controls=@{}
    foreach($name in @('LblSearchQuery','LblSearchHint','LblSearchQueryDetails','TxtSuiteResultFilter','TxtBranchSearch')){$script:Controls[$name]=[pscustomobject]@{Text='old'}}
    foreach($name in @('CmbPresenceFilter','CmbGlobalType')){$script:Controls[$name]=[pscustomobject]@{SelectedIndex=2}}
    $script:Controls.TxtGlobalLimit=[pscustomobject]@{Text='100'};$script:Controls.CmbSearchQueryResult=[pscustomobject]@{SelectedItem=[pscustomobject]@{Tag='Unknown'};IsEnabled=$true;Visibility='Collapsed'}
    $script:Controls.CmbWorkView=[pscustomobject]@{SelectedItem=$null;SelectedIndex=-1};$script:Controls.BtnWorkView=[pscustomobject]@{IsEnabled=$true}
    $script:FixtureScope=[pscustomobject]@{BaseDn=$dn;Scope='OneLevel'};$script:SelectedBranchDn=$dn;$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test'};$script:SessionEpoch=7;$script:GlobalSearchGeneration=10;$script:DatabaseScopedPath='/fixture/search.sqlite';$script:SearchMode='Global';$script:IndexSyncStates=@{}
    $script:DomeniaQueryState=[pscustomobject]@{SearchRecipe='old';SearchRefinement='old';SearchRecords=@{old=$true}}
    $script:SearchQueryCatalog=$catalog;$script:SearchQueryRun=$null;$script:Shown=@();$script:Jobs.Clear();$script:AdCalls=0;$script:AppliedFilters=0;$script:ActiveSearchViewId=''
    $script:Entry=@($catalog|Where-Object Id -eq 'local:template.ram')[0]
    $script:FleetLast=[pscustomobject]@{Scope='OU=Dashboard,DC=example,DC=test';Machines=@('sentinel')};$script:FleetObservations=@{sentinel='unchanged'}
}
Case 'Dispatch: reads Search OU and OneLevel, never dashboard scope or remote data' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;Expect ($script:Jobs.Count -eq 1);$j=$script:Jobs[0];Expect ($j.Operation -eq 'LocalIndexRead' -and $j.Payload.Scope -eq $dn -and -not $j.Payload.Subtree -and -not $j.Payload.ComputeBoard);Expect ($script:FleetLast.Machines[0] -eq 'sentinel' -and $script:FleetObservations.sentinel -eq 'unchanged' -and $script:AdCalls -eq 0)}
Case 'Dispatch: clears hidden text, presence, type and frozen GUID filters' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;Expect (-not $script:Controls.TxtSuiteResultFilter.Text -and -not $script:Controls.TxtBranchSearch.Text);Expect ($script:CurrentPresenceFilter -eq 'Tous' -and $script:Controls.CmbGlobalType.SelectedIndex -eq 0 -and $script:DomeniaQueryState.SearchRecords.Count -eq 0 -and $null -eq $script:DomeniaQueryState.SearchRecipe)}
Case 'Dispatch: no selected OU refuses without job' {Reset-Fixture;$script:SelectedBranchDn='';$failed=$false;try{Start-DomeniaSearchLocalQuery $script:Entry}catch{$failed=$true};Expect ($failed -and $script:Jobs.Count -eq 0)}
Case 'Dispatch: missing database refuses without job' {Reset-Fixture;$script:DatabaseScopedPath='';$failed=$false;try{Start-DomeniaSearchLocalQuery $script:Entry}catch{$failed=$true};Expect ($failed -and $script:Jobs.Count -eq 0)}
Case 'Dispatch: read callback starts independent actual-query phase' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;$state=$script:SearchQueryRun;Complete-DomeniaSearchLocalRead $fleet $state;Expect ($script:Jobs.Count -eq 2 -and $script:Jobs[1].Operation -eq 'LocalQuery');Expect ($script:Jobs[1].Payload.SearchOutput -and $script:Jobs[1].Payload.Fleet.Scope -eq $dn -and $script:Jobs[1].Payload.Selection -eq 'Unknown');Expect ($script:FleetLast.Scope -like 'OU=Dashboard*')}
foreach($change in @('Epoch','Generation','Path','OU','Depth','View','Text','Replacement','Mode')){
    Case ('Callback: rejects stale '+$change) {
        Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;$state=$script:SearchQueryRun
        switch($change){'Epoch'{$script:SessionEpoch++};'Generation'{$script:GlobalSearchGeneration++};'Path'{$script:DatabaseScopedPath='/other.sqlite'};'OU'{$script:FixtureScope.BaseDn='OU=Other,DC=example,DC=test'};'Depth'{$script:FixtureScope.Scope='Subtree'};'View'{$script:ActiveSearchViewId='ad:disabled'};'Text'{$script:Controls.TxtBranchSearch.Text='new'};'Replacement'{$script:SearchQueryRun=$null};'Mode'{$script:SearchMode='Global'}}
        Complete-DomeniaSearchLocalRead $fleet $state;Expect ($script:Jobs.Count -eq 1 -and $script:Shown.Count -eq 0)
    }
}
Case 'Callback: busy/missing read is failure, not empty success' {foreach($property in @('Busy','Missing')){Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;$data=[pscustomobject]@{Busy=$false;Missing=$false};$data.$property=$true;Complete-DomeniaSearchLocalRead $data $script:SearchQueryRun;Expect ($script:Jobs.Count -eq 1 -and $script:Controls.LblSearchQuery.Text -like 'Requête locale non terminée*')}}
Case 'Callback: refuses wrong returned scope' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;$original=$fleet.Scope;try{$fleet.Scope='OU=Wrong,DC=example,DC=test';Complete-DomeniaSearchLocalRead $fleet $script:SearchQueryRun;Expect ($script:Jobs.Count -eq 1 -and $script:Status -like '*périmètre*')}finally{$fleet.Scope=$original}}
Case 'Callback: local rows shown without probes and with explicit incomplete coverage' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;$result=Invoke-FixtureWorker -Selection Unknown;Complete-DomeniaSearchLocalQuery $result $script:SearchQueryRun;Expect ($script:Shown.Count -eq 1 -and $script:ShownLabel -like '*3 postes recensés*');Expect ($script:Controls.LblSearchQuery.Text -like '*Couverture AD complète non attestée*')}
Case 'Callback: failure never reuses old rows' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;Fail-DomeniaSearchLocalQuery 'annulée' $script:SearchQueryRun;Expect ($script:Shown.Count -eq 0 -and $script:Status -like '*annulée*')}
Case 'Clear: pending local query is invalidated and its late response rejected without opening workshop' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;$state=$script:SearchQueryRun;$generation=$script:GlobalSearchGeneration;Clear-DomeniaSearchQuery;Complete-DomeniaSearchLocalRead $fleet $state;Expect ($script:GlobalSearchGeneration -gt $generation -and $null -eq $script:SearchQueryRun -and -not $script:ActiveSearchViewId -and $script:Jobs.Count -eq 1 -and $script:Shown.Count -eq 0)}
Case 'Clear: old local run cannot erase a later ordinary LDAP list' {Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry;$script:ActiveSearchViewId='';$script:Shown=@('later-list');$generation=$script:GlobalSearchGeneration;Clear-DomeniaSearchQuery;Expect ($script:GlobalSearchGeneration -eq $generation -and $script:Shown.Count -eq 1 -and $script:AppliedFilters -eq 1)}
Case 'Selector: details safe before login, execute disabled, chosen local result modes visible' {Reset-Fixture;$script:Conn.BaseDn='';$script:Controls.CmbWorkView.SelectedItem=$script:Entry;Update-DomeniaSearchQueryDetails;Expect (-not $script:Controls.BtnWorkView.IsEnabled -and $script:Controls.LblSearchQueryDetails.Text -like '*Connectez-vous*' -and $script:Controls.CmbSearchQueryResult.Visibility -eq 'Visible')}
Case 'Selector: local result modes shown and LDAP result modes hidden' {Reset-Fixture;$script:Controls.CmbWorkView.SelectedItem=$script:Entry;Update-DomeniaSearchQueryDetails;Expect ($script:Controls.CmbSearchQueryResult.Visibility -eq 'Visible' -and $script:Controls.BtnWorkView.IsEnabled);$script:Controls.CmbWorkView.SelectedItem=@($catalog|Where-Object SourceId -eq Ad)[0];Update-DomeniaSearchQueryDetails;Expect ($script:Controls.CmbSearchQueryResult.Visibility -eq 'Collapsed' -and -not $script:Controls.CmbSearchQueryResult.IsEnabled)}
Case 'LDAP: original view executes explicitly and clears local intersections' {Reset-Fixture;Invoke-DomeniaWorkView 'ad:stalecomputers';Expect ($script:AdCalls -eq 1 -and $script:LastAdView -eq 'stalecomputers' -and $script:LastAdScope -eq 'OU' -and $script:Jobs.Count -eq 0);Expect ($script:DomeniaQueryState.SearchRecords.Count -eq 0)}
Case 'LDAP: old view identifier remains callable for saved views' {Reset-Fixture;Invoke-DomeniaWorkView 'expiring';Expect ($script:LastAdView -eq 'expiring')}
Case 'Coverage: successful covering read and later partial attempt stay distinct' {Reset-Fixture;$script:IndexSyncStates=@{a=[pscustomobject]@{scope=('ou:'+$dn);base_dn=$dn;last_sync='2026-10-12T10:00:00Z';details='complete'};b=[pscustomobject]@{scope=('attempt:'+$dn);base_dn=$dn;last_sync='2026-10-12T11:00:00Z';details='partial'}};$text=Get-DomeniaSearchQueryCoverageText $dn;Expect ($text -like '*Dernière lecture complète*' -and $text -like '*tentative incomplète*')}
Case 'History: snapshot preserves local definition, selected result set and visible provenance' {
    Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry
    $script:NavHistoryRows=$null;$script:Live=$null;$script:NavListShape=$null;$script:Controls.ChkSubtree=[pscustomobject]@{IsChecked=$false}
    $state=Get-DomeniaNavSnapshot -Page WsSearch
    Expect ($state.ViewId -eq $script:Entry.Id -and $state.LocalQuery.Recipe.Id -eq $script:Entry.Recipe.Id -and $state.QuerySelection -eq 'Unknown' -and $state.QueryLabel -like 'Lecture locale*')
}
Case 'History: local refresh replays its definition without LDAP or current selector state' {
    Reset-Fixture;Start-DomeniaSearchLocalQuery $script:Entry
    $original=$script:SearchQueryRun;$script:NavHistoryState=[pscustomobject]@{LocalQuery=[pscustomobject]@{Id=$original.Id;Name=$original.Name;Recipe=$original.Recipe;Selection='NoMatch';Limit=42}}
    $script:BranchObjects=[object[]]@([pscustomobject]@{Name='Old'});$script:NavHistoryRows=$script:BranchObjects
    Invoke-DomeniaHistoryRefresh
    Expect ($script:Jobs.Count -eq 2 -and $script:SearchQueryRun.Selection -eq 'NoMatch' -and $script:SearchQueryRun.Limit -eq 42 -and $script:AdCalls -eq 0)
    $script:NavHistoryRows=$null;$script:NavHistoryState=$null
}
Case 'History: different query or result selection creates a distinct location' {
    $a=[pscustomobject]@{Page='WsSearch';ViewId='local:template.all';QuerySelection='Match'};$b=[pscustomobject]@{Page='WsSearch';ViewId='local:template.all';QuerySelection='Unknown'};$c=[pscustomobject]@{Page='WsSearch';ViewId='ad:disabled';QuerySelection=''}
    Expect ((Get-DomeniaNavStateKey $a) -cne (Get-DomeniaNavStateKey $b));Expect ((Get-DomeniaNavStateKey $a) -cne (Get-DomeniaNavStateKey $c))
}

# Exercise navigation itself; WPF input is a minimal port only on non-Windows hosts.
if($null -eq ('Windows.Input.Keyboard' -as [type])){Add-Type 'namespace Windows.Input { public static class Keyboard { public static object FocusedElement { get; set; } } }'}
function Initialize-DomeniaQueryWorkshop {}
function Get-DomeniaFleetScope {return [pscustomobject]@{Name='Dashboard';Path='OU=Dashboard'}}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:NavGuardObserved=[bool]$script:DomeniaQueryNavigating;$script:Controls.WorkspaceTabs.SelectedItem=[pscustomobject]@{Name=$Workspace};if($Inner){$script:Controls[$Inner].SelectedItem=[pscustomobject]@{Name=$Tab}};$script:NavigationCalls++}
function Start-DomeniaQueryEvaluation {$script:EvaluationCalls++}
Case 'Navigation: Search opens Tools/Workshop and retains Search return without calculation' {
    Reset-Fixture;$script:NavigationCalls=0;$script:EvaluationCalls=0;$script:DomeniaQueryNavigating=$false
    $script:Controls.WorkspaceTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='WsSearch'}};$script:Controls.ApplicationToolTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabDatabase'}}
    Show-DomeniaQueryWorkshop
    Expect ($script:Controls.WorkspaceTabs.SelectedItem.Name -eq 'TabApplicationTools' -and $script:Controls.ApplicationToolTabs.SelectedItem.Name -eq 'WsQueryWorkshop');Expect ($script:DomeniaQueryReturnRoute -eq 'WsSearch' -and $script:NavGuardObserved -and -not $script:DomeniaQueryNavigating -and $script:EvaluationCalls -eq 0)
    Show-DomeniaQueryWorkshop;Expect ($script:NavigationCalls -eq 1 -and $script:DomeniaQueryReturnRoute -eq 'WsSearch')
}
Case 'Navigation: existing Tools tab captured, repeated Show preserves manual return' {
    Reset-Fixture;$script:NavigationCalls=0;$script:EvaluationCalls=0;$script:Controls.WorkspaceTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabApplicationTools'}};$script:Controls.ApplicationToolTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabDatabase'}}
    Show-DomeniaQueryWorkshop;Expect ($script:DomeniaQueryReturnRoute -eq 'TabApplicationTools' -and $script:DomeniaQueryReturnInner -eq 'ApplicationToolTabs' -and $script:DomeniaQueryReturnTab -eq 'TabDatabase')
    $script:DomeniaQueryReturnTab='TabDomain';Show-DomeniaQueryWorkshop;Expect ($script:DomeniaQueryReturnTab -eq 'TabDomain' -and $script:EvaluationCalls -eq 0)
}
$failed=@($script:Checks|Where-Object{-not $_.Pass})
$report=[pscustomobject]@{Suite='Domenia.SearchQueries';Platform=[Environment]::OSVersion.Platform.ToString();PowerShell=$PSVersionTable.PSVersion.ToString();Pass=$script:Checks.Count-$failed.Count;Fail=$failed.Count;Tests=$script:Checks.ToArray();Limitations='Actual shared query DLL and worker; mocked UI/SQLite dispatch; no WPF, AD, remote endpoints or Windows qualification.'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
