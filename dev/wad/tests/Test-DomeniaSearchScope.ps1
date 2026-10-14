#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
# Tests isoles : extraction AST et doubles en memoire. Aucun annuaire ni fichier de donnees ouvert.
$ErrorActionPreference='Stop'
$core=Join-Path (Split-Path -Parent $PSScriptRoot) 'Domenia-Core.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count -gt 0){throw ('Syntaxe du coeur : '+$parseErrors[0].Message)}
$names=@('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSearchMode','Get-DomeniaSearchText','Set-DomeniaSearchMode','Get-DomeniaSearchScope','Update-DomeniaSearchScopeUi',
    # Get-DomeniaSearchScope appelle Update-DomeniaNewOuParentUi (CO-27) : non declaree ici, chaque cas qui resout
    # une portee rend une erreur de resolution, pas une regle fausse (mesure campagne r8, 34 + 28 cas).
    'Update-DomeniaNewOuParentUi',
    'Invalidate-DomeniaSearchResults','Test-DomeniaSearchStateCurrent','Invoke-DomeniaSearchFilterChanged',
    'Reset-DomeniaSearchScope','Set-SelectedBranch','Get-TypeLdapFilter','Get-GlobalSelectedTypeFilter',
    'Invoke-GlobalSearch','Complete-DomeniaGlobalSearchUi','Fail-DomeniaGlobalSearchUi','Clear-DomeniaGlobalSearch',
    'Get-DomeniaEffectiveWorkerResult','Load-BranchObjects','Go-RootBranch','Escape-LdapValue',
    'Get-DomeniaWorkerCodeHash','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerOperationHashes')
foreach($name in $names){
    $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente/ambigue : '+$name)}
    Invoke-Expression $nodes[0].Extent.Text
}
# Production injects exactly this function into every worker (New-DomeniaWorkerRunspace): the pinned
# GlobalSearch body calls it in its catch block before falling back to the next context.
$guardModel=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-Guard.Model.ps1'
$guardTokens=$null;$guardErrors=$null
$guardAst=[Management.Automation.Language.Parser]::ParseFile($guardModel,[ref]$guardTokens,[ref]$guardErrors)
if(@($guardErrors).Count -gt 0){throw ('Syntaxe de Guard.Model : '+$guardErrors[0].Message)}
$structured=@($guardAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DomeniaStructuredError'},$true))
if($structured.Count -ne 1){throw 'Fonction absente/ambigue : Get-DomeniaStructuredError'}
Invoke-Expression $structured[0].Extent.Text
# D120: the global search uses the pure search rules, as the closed loader provides them.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-Common.Model.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-Search.Model.ps1')
# D021: the global search asks the list projection of the cache rules.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-Cache.Model.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-DirectoryStore.Model.ps1')
Invoke-Expression (Get-DomeniaDirectoryStoreWorkerPrelude)
function Test-DomeniaAccessBusyWrite {return $false}
function Test-DomeniaDraftNavigation {param($DN);return $true}
function Get-CfgValue {param($Section,$Name,$Default) return $Default}
# R1.12: this suite isolates scope semantics. The real progressive renderer has its own native suite.
function Stop-DomeniaLiveSearch { }
function Stop-DomeniaFavouriteTreeReveal { }
function Begin-DomeniaLiveSearch {
    param($State,$Payload)
    $script:StreamStarts++
    Add-Member -InputObject $Payload -NotePropertyName StreamPageSize -NotePropertyValue ([int](Get-DomeniaMember $Payload 'StreamPageSize' 250)) -Force
    Add-Member -InputObject $Payload -NotePropertyName Progress -NotePropertyValue ([Collections.Concurrent.ConcurrentQueue[object]]::new()) -Force
    Add-Member -InputObject $Payload -NotePropertyName StopToken -NotePropertyValue ([Threading.CancellationToken]::None) -Force
}
function Get-WPropFirst {param($Props,$Name,$Default) return $Default}
function Convert-WGuid {param($Value) return [string]$Value}
function Stop-DomeniaSelectionOpenTimer { }
function Clear-DomeniaSelectionEverywhere { $script:SelectionClearedEverywhere=[int]$script:SelectionClearedEverywhere+1 }
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab) $script:CurrentPage=$Workspace}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded) [void]$script:Stopped.Add($Id)}
function Set-DomeniaItemsSource {param($Name,$Rows) $script:Ctrl[$Name].ItemsSource=@($Rows);return $true}
function Add-DomeniaUiLog {param($Area,$Level,$Text)}
function Write-AppLog {param($Text,$Level)}
function Write-DomeniaTrace {param($Area,$Text)}
function Set-Status {param($Text,$Level) $script:LastStatus=$Text}
function Update-Dashboard { }
function Request-DomeniaDashboardRefresh { }
function Reset-DomeniaSelectionBoundViews { }
function Clear-DomeniaCurrentObjectRequest {param($RequestId)}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException,[switch]$NoPopup) throw $ErrorRecordOrException}
function Get-VisitCacheValue {param($Key) return $null}
function Set-VisitCacheValue {param($Key,$Value) $script:CacheStores++}
function Get-DomeniaDatabaseObjectCount {return 2}
function Find-DomeniaIndexMatches {param($Term,$Limit) $script:LocalReads++;return @()}
function Show-ObjectRows {param($Rows,$Label,[switch]$SkipPresenceScan,[switch]$NoAutoOpen,[string]$PreserveSelectionDn) $script:Rendered=@($Rows)}
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$HardTimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
    $script:LastTask=[pscustomobject]@{Code=$Code;Payload=$Payload;State=$CallbackState;OperationId=$OperationId;ReplaceKey=$ReplaceKey}
}
function Reset-TestState {
    $script:SearchMode='OU'
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE';BindUser='test';Credential=$null;UseCredential=$false;PageSize=100}
    $script:SelectedBranchDn='OU=Site,DC=example,DC=invalid'
    $script:GlobalSearchGeneration=100;$script:LastTask=$null;$script:LastStatus='';$script:CurrentPage=''
    $script:SelectedObject=$null;$script:CurrentObjectRequestId='';$script:PendingObjectSelection=$null
    $script:VisitCache=@{};$script:AsyncJobs=@{};$script:LiveSearchTimer=$null
    $script:RestoringSettings=$false;$script:SuppressBranchAutoLoad=$false;$script:SuppressGridSelectionEvents=$false
    $script:IndexInfo=$null;$script:LocalReads=0;$script:StreamStarts=0;$script:CacheStores=0;$script:Rendered=@()
    $script:Stopped=New-Object System.Collections.ArrayList
    $script:Ctrl=@{}
    foreach($n in @('TxtGlobalSearch','TxtBranchSearch','TxtGlobalLimit','TxtBranchDn','LblSearchScope','LblBranchCount')){
        $script:Ctrl[$n]=[pscustomobject]@{Name=$n;Text='';ToolTip=''}
    }
    $script:Ctrl['TxtGlobalLimit'].Text='100'
    $script:Ctrl['CmbGlobalType']=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='Tous'}}
    $script:Ctrl['ChkSubtree']=[pscustomobject]@{IsChecked=$true}
    $script:Ctrl['TvDirectory']=[pscustomobject]@{Items=@([pscustomobject]@{IsSelected=$false})}
    $script:Ctrl['DgObjects']=[pscustomobject]@{ItemsSource=@();SelectedItem=$null;SelectedIndex=-1}
    $script:BranchObjects=@();$script:BranchCountLabel=''
    $script:FakeRows=@();$script:FailBoundServer=$false;$script:FailEveryCall=$false
    $script:WorkerCalls=New-Object System.Collections.ArrayList
}
function Assert-Test {param([bool]$Condition,[string]$Message='Condition non verifiee') if(-not $Condition){throw $Message}}
$script:Checks=New-Object System.Collections.ArrayList
function Test-Case {
    param([string]$Name,[scriptblock]$Action)
    Reset-TestState
    try{& $Action;[void]$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{[void]$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
# Doubles du worker : les appels sont memorises, jamais transmis a LDAP.
function New-WSearcher {
    param($Ctx,$BaseDn,$Filter,$Properties,$Scope,$Limit)
    [void]$script:WorkerCalls.Add([pscustomobject]@{Server=$Ctx.Server;BaseDn=$BaseDn;Scope=$Scope;Filter=$Filter;Limit=$Limit})
    if($script:FailEveryCall -or ($script:FailBoundServer -and $Ctx.Server)){throw 'Echec simule du serveur'}
    $o=[pscustomobject]@{ServerTimeLimit=[TimeSpan]::Zero;ClientTimeout=[TimeSpan]::Zero;PageSize=0;CacheResults=$true;Asynchronous=$false;SearchRoot=$null}
    $o | Add-Member -MemberType ScriptMethod -Name FindAll -Value {return ,([object[]]@($script:FakeRows))}
    $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    return $o
}
function New-WBranchRow {param($Result) return $Result}
function Invoke-TestWorker {
    $Context=$script:Conn;$Payload=$script:LastTask.Payload
    return (& ([scriptblock]::Create([string]$script:LastTask.Code)))
}
Test-Case 'OU explicite et sous-arbre' { $s=Get-DomeniaSearchScope;Assert-Test ($s.BaseDn -eq $script:SelectedBranchDn -and $s.Scope -eq 'Subtree' -and -not $s.IsDomain) }
Test-Case 'Aucune selection utilise la racine de session' { $script:SelectedBranchDn='';Assert-Test ((Get-DomeniaSearchScope).IsDomain) }
Test-Case 'Enfants directs respectes' { $script:Ctrl.ChkSubtree.IsChecked=$false;Assert-Test ((Get-DomeniaSearchScope).Scope -eq 'OneLevel') }
Test-Case 'DN echappe transmis sans transformation' { $script:SelectedBranchDn='OU=Paris\, Est,DC=example,DC=invalid';Assert-Test ((Get-DomeniaSearchScope).BaseDn -ceq $script:SelectedBranchDn) }
Test-Case 'Base de session absente refusee' { $script:Conn.BaseDn='';$failed=$false;try{Get-DomeniaSearchScope}catch{$failed=$true};Assert-Test $failed }
Test-Case 'Texte conserve dans la recherche OU' { $script:Ctrl.TxtBranchSearch.Text='PC-';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LastTask.Payload.BaseDn -eq $script:SelectedBranchDn -and $script:LastTask.State.Search -eq 'PC-') }
Test-Case 'Recherche vide lit le contenu sans ajouter une etoile au champ' { Invoke-GlobalSearch -SearchMode OU;Assert-Test ($null -ne $script:LastTask -and $script:Ctrl.TxtBranchSearch.Text -eq '' -and $script:LastTask.Payload.BroadFilter -eq (Get-GlobalSelectedTypeFilter)) }
Test-Case 'Groupes proposes et filtres cote requete' { $script:Ctrl.CmbGlobalType.SelectedItem.Content='Groupes';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LastTask.Payload.BroadFilter -eq '(objectCategory=group)') }
Test-Case 'OU et conteneurs proposes' { $script:Ctrl.CmbGlobalType.SelectedItem.Content='OU et conteneurs';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LastTask.Payload.BroadFilter -match 'organizationalUnit') }
Test-Case 'Limite bornee a 20000' { $script:Ctrl.TxtGlobalLimit.Text='99999';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LastTask.Payload.Limit -eq 20000) }
Test-Case 'Limite negative revient a 100' { $script:Ctrl.TxtGlobalLimit.Text='-2';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LastTask.Payload.Limit -eq 100) }
Test-Case 'Pas d apercu local global sous une OU' { $script:Ctrl.TxtBranchSearch.Text='Alex';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LocalReads -eq 0) }
Test-Case 'Pas d apercu local global en OneLevel' { $script:SelectedBranchDn=$script:Conn.BaseDn;$script:Ctrl.ChkSubtree.IsChecked=$false;$script:Ctrl.TxtBranchSearch.Text='Alex';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LocalReads -eq 0) }
Test-Case 'Cache delegue au flux sans lecture SQL sur le thread appelant' { $script:SelectedBranchDn=$script:Conn.BaseDn;$script:Ctrl.TxtBranchSearch.Text='Alex';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LocalReads -eq 0 -and $script:StreamStarts -eq 1) }
Test-Case 'Cle cache differente pour deux OU' { Invoke-GlobalSearch -SearchMode OU;$a=$script:LastTask.State.CacheKey;$script:SelectedBranchDn='OU=Autre,DC=example,DC=invalid';Invoke-GlobalSearch -SearchMode OU;Assert-Test ($a -ne $script:LastTask.State.CacheKey) }
Test-Case 'Cle cache differente selon la profondeur' { Invoke-GlobalSearch -SearchMode OU;$a=$script:LastTask.State.CacheKey;$script:Ctrl.ChkSubtree.IsChecked=$false;Invoke-GlobalSearch -SearchMode OU;Assert-Test ($a -ne $script:LastTask.State.CacheKey) }
Test-Case 'Etat courant accepte' { Invoke-GlobalSearch -SearchMode OU;Assert-Test (Test-DomeniaSearchStateCurrent $script:LastTask.State) }
Test-Case 'Ancienne generation rejetee' { Invoke-GlobalSearch -SearchMode OU;$a=$script:LastTask.State;$script:GlobalSearchGeneration++;Assert-Test (-not (Test-DomeniaSearchStateCurrent $a)) }
Test-Case 'OU differente rejette le retour tardif' { Invoke-GlobalSearch -SearchMode OU;$a=$script:LastTask.State;$script:SelectedBranchDn=$script:Conn.BaseDn;Complete-DomeniaGlobalSearchUi $null $a;Assert-Test ($script:CacheStores -eq 0) }
Test-Case 'Type modifie rejette le retour tardif' { Invoke-GlobalSearch -SearchMode OU;$a=$script:LastTask.State;$script:Ctrl.CmbGlobalType.SelectedItem.Content='Machines';Assert-Test (-not (Test-DomeniaSearchStateCurrent $a)) }
Test-Case 'Texte modifie rejette le retour tardif' { Invoke-GlobalSearch -SearchMode OU;$a=$script:LastTask.State;$script:Ctrl.TxtBranchSearch.Text='autre';Assert-Test (-not (Test-DomeniaSearchStateCurrent $a)) }
Test-Case 'Profondeur modifiee rejette le retour tardif' { Invoke-GlobalSearch -SearchMode OU;$a=$script:LastTask.State;$script:Ctrl.ChkSubtree.IsChecked=$false;Assert-Test (-not (Test-DomeniaSearchStateCurrent $a)) }
Test-Case 'Navigation dans une OU conserve la saisie' { $script:Ctrl.TxtGlobalSearch.Text='PC-';Set-SelectedBranch ([pscustomobject]@{Tag=[pscustomobject]@{DN='OU=Autre,DC=example,DC=invalid';Name='Autre'}});Assert-Test ($script:LastTask.Payload.BaseDn -eq 'OU=Autre,DC=example,DC=invalid' -and $script:Ctrl.TxtGlobalSearch.Text -eq 'PC-') }
Test-Case 'Initialisation de l arbre ne lance pas de recherche' { $script:SuppressBranchAutoLoad=$true;Set-SelectedBranch ([pscustomobject]@{Tag=[pscustomobject]@{DN=$script:Conn.BaseDn;Name='Domaine'}});Assert-Test ($null -eq $script:LastTask) }
Test-Case 'Restauration des reglages sans recherche' { $script:RestoringSettings=$true;Invoke-DomeniaSearchFilterChanged;Assert-Test ($null -eq $script:LastTask) }
Test-Case 'Tout le domaine conserve le texte et inclut les sous-OU' { $script:Ctrl.TxtGlobalSearch.Text='PC-';$script:Ctrl.ChkSubtree.IsChecked=$false;Reset-DomeniaSearchScope;Assert-Test ($script:LastTask.Payload.BaseDn -eq $script:Conn.BaseDn -and $script:LastTask.Payload.Scope -eq 'Subtree' -and $script:Ctrl.TxtGlobalSearch.Text -eq 'PC-') }
Test-Case 'Reset sans recherche utilisable en initialisation' { Reset-DomeniaSearchScope -NoSearch;Assert-Test ($null -eq $script:LastTask -and $script:SelectedBranchDn -eq $script:Conn.BaseDn) }
Test-Case 'Effacer conserve le filtre OU' { $a=$script:SelectedBranchDn;$script:Ctrl.TxtGlobalSearch.Text='PC-';Clear-DomeniaGlobalSearch;Assert-Test ($script:SelectedBranchDn -eq $a -and $script:Ctrl.TxtGlobalSearch.Text -eq '' -and $script:CurrentPage -eq 'WsSearch') }
Test-Case 'Ancien chargeur de branche utilise le moteur commun' { Load-BranchObjects;Assert-Test ($script:LastTask.OperationId -eq 'GlobalSearch' -and $script:LastTask.ReplaceKey -eq 'global') }
Test-Case 'Annulation ne touche pas une ecriture' { $script:AsyncJobs=@{a=[pscustomobject]@{ReplaceKey='global';IsWrite=$false};b=[pscustomobject]@{ReplaceKey='branch';IsWrite=$false};c=[pscustomobject]@{ReplaceKey='global';IsWrite=$true}};Invalidate-DomeniaSearchResults;Assert-Test ($script:Stopped.Count -eq 2 -and -not $script:Stopped.Contains('c')) }
Test-Case 'Terme OU trop court ne lance pas de requete' { $script:Ctrl.TxtBranchSearch.Text='a';$script:Ctrl.DgObjects.ItemsSource=@(1);Invoke-DomeniaSearchFilterChanged;Assert-Test ($null -eq $script:LastTask -and $script:Ctrl.DgObjects.ItemsSource.Count -eq 1) }
Test-Case 'Empreinte worker recalculee et epinglee' { Invoke-GlobalSearch -SearchMode OU;Assert-Test ((Get-DomeniaWorkerCodeHash $script:LastTask.Code) -ceq (Get-DomeniaWorkerOperationHashes)['GlobalSearch']) }
Test-Case 'Worker transmet la racine OU et OneLevel' { $script:Ctrl.ChkSubtree.IsChecked=$false;Invoke-GlobalSearch -SearchMode OU;$out=Invoke-TestWorker;Assert-Test ($script:WorkerCalls[0].BaseDn -eq $script:SelectedBranchDn -and $script:WorkerCalls[0].Scope -eq 'OneLevel' -and $out.BaseDn -eq $script:SelectedBranchDn) }
Test-Case 'Repli serveur garde la meme OU et profondeur' { $script:FailBoundServer=$true;$script:Ctrl.ChkSubtree.IsChecked=$false;Invoke-GlobalSearch -SearchMode OU;$out=Invoke-TestWorker;Assert-Test ($script:WorkerCalls.Count -eq 2);foreach($c in $script:WorkerCalls){Assert-Test ($c.BaseDn -eq $script:SelectedBranchDn -and $c.Scope -eq 'OneLevel')} }
Test-Case 'Worker refuse une base vide' { Invoke-GlobalSearch -SearchMode OU;$script:LastTask.Payload.BaseDn='';$failed=$false;try{Invoke-TestWorker}catch{$failed=$true};Assert-Test ($failed -and $script:WorkerCalls.Count -eq 0) }
Test-Case 'Worker refuse une portee inconnue' { Invoke-GlobalSearch -SearchMode OU;$script:LastTask.Payload.Scope='Unknown';$failed=$false;try{Invoke-TestWorker}catch{$failed=$true};Assert-Test ($failed -and $script:WorkerCalls.Count -eq 0) }
Test-Case 'Echec serveur reste une erreur, pas un resultat vide valide' { $script:FailEveryCall=$true;Invoke-GlobalSearch -SearchMode OU;$failed=$false;try{Invoke-TestWorker}catch{$failed=($_.Exception.Message -match 'a echoue sur tous les contextes')};Assert-Test $failed 'Echec attendu : tous les contextes essayes, pas une fonction absente' }
Test-Case 'Worker conserve les groupes et les conteneurs' { Invoke-GlobalSearch -SearchMode OU;$script:FakeRows=@([pscustomobject]@{Type='Groupe';Name='G';DN='CN=G,OU=Site,DC=example,DC=invalid'},[pscustomobject]@{Type='OU';Name='Sous';DN='OU=Sous,OU=Site,DC=example,DC=invalid'});$out=Invoke-TestWorker;Assert-Test ($out.Rows.Count -eq 2) }
Test-Case 'Exactement la limite ne prouve pas une troncature' { $script:Ctrl.TxtGlobalLimit.Text='1';Invoke-GlobalSearch -SearchMode OU;$script:FakeRows=@([pscustomobject]@{Type='Machine';Name='PC';DN='CN=PC,OU=Site,DC=example,DC=invalid'});$out=Invoke-TestWorker;Assert-Test (-not [bool]$out.LimitReached -and $out.Rows.Count -eq 1) }
foreach($boundary in @(9999,10000,10001,19999,20000,20001)){
    Test-Case ('Complétude à '+$boundary+' objets') {
        $limit=if($boundary -le 10001){10000}else{20000}
        $script:Ctrl.TxtGlobalLimit.Text=[string]$limit
        Invoke-GlobalSearch -SearchMode OU
        $script:LastTask.Payload.Progress=$null
        $script:FakeRows=@(for($i=0;$i -lt $boundary;$i++){[pscustomobject]@{Type='Machine';Name=('PC'+$i);DN=('CN=PC'+$i+',OU=Site,DC=example,DC=invalid')}})
        $out=Invoke-TestWorker
        Assert-Test ($out.Rows.Count -eq [Math]::Min($boundary,$limit))
        Assert-Test ([bool]$out.LimitReached -eq ($boundary -gt $limit))
        Assert-Test (-not $out.Partial)
        Assert-Test ($script:WorkerCalls[0].Limit -eq $limit+1)
    }
}
Test-Case 'Racine inattendue dans le resultat refusee' { Invoke-GlobalSearch -SearchMode OU;$out=[pscustomobject]@{Rows=@();BaseDn=$script:Conn.BaseDn;Scope='Subtree'};$failed=$false;try{Complete-DomeniaGlobalSearchUi $out $script:LastTask.State}catch{$failed=$true};Assert-Test $failed }
Test-Case 'Rafraichissement conserve uniquement une vraie selection' { $script:Ctrl.DgObjects.SelectedItem=[pscustomobject]@{DN='CN=PC,OU=Site,DC=example,DC=invalid'};Load-BranchObjects;Assert-Test ($script:LastTask.State.PreserveSelectionDn -eq 'CN=PC,OU=Site,DC=example,DC=invalid') }
Test-Case 'Nouvelle recherche ne reselecte pas la fiche precedente' { $script:Ctrl.DgObjects.SelectedItem=[pscustomobject]@{DN='CN=PC,OU=Site,DC=example,DC=invalid'};Invoke-GlobalSearch -SearchMode OU;Assert-Test ($script:LastTask.State.PreserveSelectionDn -eq '') }
$failed=@($script:Checks | Where-Object {-not $_.Passed}).Count
$release=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'Domenia.release.json') -Raw | ConvertFrom-Json
$report=[pscustomobject]@{Build=[string]$release.Build;CoreSha256=(Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash.ToLowerInvariant();Runtime=$PSVersionTable.PSVersion.ToString();Kind='PowerShell mocks; no LDAP/WPF';Passed=($script:Checks.Count-$failed);Failed=$failed;Checks=@($script:Checks)}
if([string]::IsNullOrWhiteSpace($ReportPath)){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-OU-search-'+[guid]::NewGuid().ToString('N')+'.json')}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if(-not $Quiet){Write-Host ('Tests : '+$report.Passed+' OK, '+$failed+' echec(s). Rapport : '+$ReportPath)}
if($failed -gt 0){throw ('Tests recherche OU en echec : '+$ReportPath)}
