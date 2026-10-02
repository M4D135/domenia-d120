#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
# D120, lot recherche (D012, D031-D040): proves that the application functions really call the search rules.
# Real core functions are extracted by AST, real modules are dot-sourced and real WPF controls are used.
# Directory, workstation, network and disk are replaced by explicit doubles: no LDAP, CIM, ping or file write.
# Each case fails when the corresponding wiring is removed (see the comment above each case).
$ErrorActionPreference='Stop'
$edition=if($PSVersionTable.ContainsKey('PSEdition')){[string]$PSVersionTable.PSEdition}else{'Desktop'}
$native=($env:OS -eq 'Windows_NT' -and $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
if(-not $native){throw 'Windows PowerShell 5.1 requis : une autre execution ne vaut pas preuve.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Utiliser powershell.exe -STA.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Ok,[string]$Reason='Assertion fausse');if(-not $Ok){throw $Reason}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{Reset-Fixture;& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=($_.Exception.Message+' @ '+$_.ScriptStackTrace)})}
}
function Import-AstFunctions {param([string]$Path,[string[]]$Names)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ('Syntaxe : '+$Path+' : '+$errors[0].Message)}
    $bodies=[Collections.Generic.List[string]]::new()
    foreach($name in $Names){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if($nodes.Count -ne 1){throw ('Definition absente ou ambigue : '+$name)}
        $bodies.Add($nodes[0].Extent.Text)
    }
    return ($bodies.ToArray() -join "`n")
}

# Immutable C# 5 types, compiled as the closed loader and Initialize-DomeniaLive do.
if($null -eq ('Domenia.SelectionIdentity' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia-Identity.Types.cs') -ErrorAction Stop}
if($null -eq ('Domenia.Live.ResultRow' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia-Live.Types.cs') -ErrorAction Stop}

# Real application code.
$coreNames=@('Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSearchMode','Set-DomeniaSearchMode','Get-DomeniaSearchText',
    'Get-DomeniaSearchScope','Get-GlobalSelectedTypeFilter','Get-TypeLdapFilter','Test-DomeniaSearchStateCurrent','Invoke-GlobalSearch','Escape-LdapValue',
    'Set-DomeniaItemsSource','Get-BranchQueryData','Get-SearchLdapFilter','Start-DomeniaSearchFor','Get-DomeniaEffectiveWorkerResult',
    'Invalidate-DomeniaSearchResults','Update-DomeniaSearchScopeUi','Get-DomeniaSelectedGridRow','Get-DomeniaSelectedGridRows','Select-DomeniaWorkspace',
    'Set-SelectedBranch','Invoke-DomeniaSearchFilterChanged','Clear-DomeniaCurrentObjectRequest','Test-DomeniaObjectCallbackIsCurrent',
    'Test-DomeniaGridSelectionMatches','Queue-DomeniaSelectedObjectOpen','Invoke-DomeniaPendingSelectionOpen','Open-AdObject',
    'Complete-DomeniaOpenObjectTaskUi','Fail-DomeniaOpenObjectTaskUi')
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $wad 'Domenia-Core.ps1') $coreNames)))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-UX.UI.ps1') @('Get-DomeniaUxOuDisplay','Update-DomeniaUxOuScope'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Guard.UI.ps1') @('Get-DomeniaFavouriteSearches','Save-DomeniaFavouriteSearch','Load-DomeniaFavouriteSearch'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Guard.Model.ps1') @('ConvertTo-DomeniaSavedSearch'))))
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Search.Model.ps1','Domenia-Experience.Model.ps1','Domenia-Live.Model.ps1','Domenia-Live.UI.ps1','Domenia-Continuity.Model.ps1','Domenia-Continuity.UI.ps1','Domenia-Selection.UI.ps1','Domenia-Search.UI.ps1')){
    . (Join-Path $modules $file)
}

# Explicit doubles: none can reach a directory, a workstation, the network, the database or a dialog window.
function Get-CfgValue {param($Section,$Name,$Default) $key=[string]$Section+'/'+[string]$Name;if($script:CfgOverrides.ContainsKey($key)){return $script:CfgOverrides[$key]};return $Default}
function Test-DomeniaAccessBusyWrite {return [bool]$script:WriteBlocked}
function Test-DomeniaDraftNavigation {param($DN,[switch]$Refresh) return $true}
function Get-DomeniaDirtyFields {return @($script:DirtyFields)}
function Stop-DomeniaSelectionOpenTimer { }
function Reset-DomeniaSelectionBoundViews { }
function Add-DomeniaUiLog {param($Area,$Level,$Text)}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level='INFO') $script:LastStatus=[string]$Text;$script:LastStatusLevel=[string]$Level}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException,[switch]$NoPopup)
    $m=if($ErrorRecordOrException -is [Management.Automation.ErrorRecord]){$ErrorRecordOrException.Exception.Message}elseif($ErrorRecordOrException -is [Exception]){$ErrorRecordOrException.Message}else{[string]$ErrorRecordOrException}
    $script:OperationErrors.Add($m)
}
function Show-DomeniaFormDialog {throw 'Fenetre modale interdite dans ce parcours.'}
function Show-InfoBox {param($Text) throw ('Fenetre modale interdite : '+[string]$Text)}
function Update-Dashboard { }
function Request-DomeniaDashboardRefresh { }
function Apply-DomeniaUiProfile {param($Profile)}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason) $script:Stops++}
function Set-RowAssociationMetadata {param($Rows) return $Rows}
function Get-DomeniaRunningComputerUserProbe {param($Computer) return $null}
function Get-CurrentSelectedComputerName {return ''}
function Get-ExistingLinkForComputer {param($Computer) return $null}
function Merge-DomeniaLiveLinkMemory {param($Observation)}
function Get-DomeniaDatabasePath {return 'C:\DomeniaTest\aucune-base.db'}
function Get-DomeniaSetting {param($Name,$Default) if($script:Settings.ContainsKey([string]$Name)){return $script:Settings[[string]$Name]};return $Default}
function Set-DomeniaSetting {param($Name,$Value) $script:Settings[[string]$Name]=$Value}
function Save-DomeniaSettings {param([switch]$Immediate)}
function Clear-Secrets { }
function Set-VisibleTabsForType {param($Type,[switch]$PreserveWorkspace)}
function Set-DomeniaRelationsGridSelection { }
function Get-DomeniaSafeObjectPropertyNames {return @('name','objectGUID','distinguishedName','objectClass')}
function Get-VisitCacheValue {param($Key) return $null}
function Complete-DomeniaOpenObjectUi {param($Result,$CacheKey,$Dn,$Type,[switch]$NoNavigate,[switch]$SuppressRemoteProbes)
    $script:SelectedObject=[pscustomobject]@{DN=$Dn;Type=$Type;Name=[string]@($Result.Properties.name)[0];Entry=$Result;Safety=[pscustomobject]@{Guid=[string]@($Result.Properties.objectGUID)[0]}}
}
function Fail-DomeniaOpenObjectUi {param($Message,$Dn) $script:OpenFailure=[string]$Message}
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable)
    $id='task-'+[guid]::NewGuid().ToString('N')
    $job=[pscustomobject]@{Id=$id;OperationId=[string]$OperationId;Payload=$Payload;CallbackState=$CallbackState;ReplaceKey=[string]$ReplaceKey;IsWrite=$false;Code=[string]$Code}
    $script:Tasks.Add($job);$script:AsyncJobs[$id]=$job
    return $id
}

function New-TestControls {
    $c=@{}
    foreach($n in @('TxtGlobalSearch','TxtBranchSearch','TxtGlobalLimit','TxtSuiteResultFilter','TxtBranchDn')){$c[$n]=[Windows.Controls.TextBox]::new()}
    foreach($n in @('LblBranchCount','LblSuiteResultCount','LblSearchScope','LblSearchHint','LblLiveState','LblOuRestoreMessage','LblSelectionReadState','LblOuScopeName','LblOuScopePath')){$c[$n]=[Windows.Controls.TextBlock]::new()}
    foreach($n in @('BtnSearchMore','BtnNavBack','BtnNavForward','BtnWorkView','BtnOuRestoreRetry','BtnOuRestoreDismiss')){$c[$n]=[Windows.Controls.Button]::new()}
    $c.TxtGlobalLimit.Text='100'
    $c.ChkSubtree=[Windows.Controls.CheckBox]::new();$c.ChkSubtree.IsChecked=$false
    $c.CmbGlobalType=[Windows.Controls.ComboBox]::new()
    foreach($t in @('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')){$i=[Windows.Controls.ComboBoxItem]::new();$i.Content=$t;[void]$c.CmbGlobalType.Items.Add($i)}
    $c.CmbGlobalType.SelectedIndex=2
    $c.CmbWorkView=[Windows.Controls.ComboBox]::new()
    $c.OuRestoreBanner=[Windows.Controls.Border]::new();$c.OuRestoreBanner.Visibility='Collapsed'
    $c.SearchBrowserLayout=[Windows.Controls.Grid]::new()
    $grid=[Windows.Controls.DataGrid]::new();$grid.IsReadOnly=$true;$grid.CanUserAddRows=$false;$grid.AutoGenerateColumns=$false
    $c.DgObjects=$grid
    $tabs=[Windows.Controls.TabControl]::new()
    foreach($n in @('TabDashboard','WsSearch','WsObject','WsComputer')){$t=[Windows.Controls.TabItem]::new();$t.Name=$n;$t.Header=$n;[void]$tabs.Items.Add($t);$c[$n]=$t}
    $tabs.SelectedItem=$c.TabDashboard
    $c.WorkspaceTabs=$tabs
    $detail=[Windows.Controls.TabControl]::new()
    foreach($n in @('TabGeneric','TabUser')){$t=[Windows.Controls.TabItem]::new();$t.Name=$n;$t.Header=$n;[void]$detail.Items.Add($t);$c[$n]=$t}
    $c.DetailTabs=$detail
    $c.TvDirectory=[Windows.Controls.TreeView]::new()
    return $c
}
function Reset-Fixture {
    if($null -ne $script:Live -and $null -ne $script:Live.Timer){$script:Live.Timer.Stop()}
    if($null -ne $script:Continuity -and $null -ne $script:Continuity.Timer){$script:Continuity.Timer.Stop()}
    $script:Live=$null;$script:Continuity=$null
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server='dc.example.invalid';Netbios='EXAMPLE';BindUser='EXAMPLE\lecteur';Credential=$null;UseCredential=$false;PageSize=100}
    $script:ProcessIdentity='EXAMPLE\lecteur';$script:MachineCredential=$null;$script:RemoteAdminCredential=$null;$script:AccessState=$null
    $script:SessionEpoch=5L;$script:GlobalSearchGeneration=40;$script:SelectedObjectGeneration=0L
    $script:SearchMode='OU';$script:SelectedBranchDn='OU=Postes,DC=example,DC=invalid';$script:CurrentPresenceFilter='Tous'
    $script:ActiveSearchViewId='';$script:DemoMode=$false
    $script:WriteBlocked=$false;$script:ActiveWriteTaskId='';$script:WriteState='Idle';$script:AsyncEngineClosing=$false;$script:DirectoryCredentialFaulted=$false
    $script:SuppressGridSelectionEvents=$false;$script:SuppressBranchAutoLoad=$false;$script:RestoringSettings=$false
    $script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@();$script:VisitCache=@{};$script:LiveSearchTimer=$null
    $script:SelectedObject=$null;$script:SelectionLoad=$null;$script:PendingObjectSelection=$null;$script:SelectionOpenTimer=$null
    $script:CurrentObjectRequestId='';$script:CurrentObjectRequestDn='';$script:CurrentObjectRequestState=$null;$script:SelectionResetDn='';$script:DraftState=$null
    $script:BranchObjects=@();$script:BranchCountLabel='';$script:LastObjectOpenError='';$script:OpenFailure=''
    $script:Tasks=[Collections.Generic.List[object]]::new();$script:OperationErrors=[Collections.Generic.List[string]]::new();$script:Stops=0
    $script:LastStatus='';$script:LastStatusLevel='';$script:DirtyFields=@();$script:CfgOverrides=@{};$script:Settings=@{}
    $script:SearchUiInitialized=$false;$script:NavHistory=$null;$script:NavRestoring=$false;$script:NavSearchLaunching=$false
    $script:Ctrl=New-TestControls
    $script:Window=[Windows.Window]::new()
    Initialize-DomeniaLive
    if($null -eq $script:Live){throw 'Initialisation progressive impossible dans la fixture.'}
    $script:Live.Timer.Stop()
}
function Get-LastTask {param([string]$Operation) $t=@($script:Tasks|Where-Object{$_.OperationId -eq $Operation});if($t.Count){return $t[$t.Count-1]};return $null}
function Get-TaskCount {param([string[]]$Operation) return @($script:Tasks|Where-Object{$Operation -contains $_.OperationId}).Count}
function Search-Global {param([string]$Text) $script:Ctrl.TxtGlobalSearch.Text=$Text;Invoke-GlobalSearch -SearchMode Global;return (Get-LastTask 'GlobalSearch')}
function New-ResultRow {param([string]$Name,[string]$Login,[string]$Type='Utilisateur',[string]$Guid='',[string]$Ou='OU=Lyon')
    if(-not $Guid){$Guid=[guid]::NewGuid().ToString('D')}
    return [pscustomobject]@{Type=$Type;Name=$Name;Login=$Login;UPN=($Login+'@example.invalid');Mail='';Description='';Changed='';DN=('CN='+$Name+','+$Ou+',DC=example,DC=invalid');State='';OS='';LastLogon='';Guid=$Guid}
}
function Feed-Live {param($Row) $script:Live.Search.Progress.Enqueue([pscustomobject]@{Kind='Row';Row=$Row;ObservedUtc='2026-10-02T08:00:00.0000000Z'})}
function Pump-Live {param([int]$Ticks=60) for($i=0;$i -lt $Ticks;$i++){Invoke-DomeniaLiveTick;if($null -eq $script:Live.Search -or ($script:Live.Search.Progress.IsEmpty -and ($script:Live.Search.Finalized -or -not $script:Live.Search.Ended))){if($i -gt 2){break}}}}
function Finish-Live {param($Task,[bool]$LimitReached=$false)
    $s=$script:Live.Search
    Complete-DomeniaLiveSearch -Result ([pscustomobject]@{Rows=@();BaseDn=$s.State.BaseDn;Scope=$s.State.Scope;Partial=$false;Failure='';LimitReached=$LimitReached}) -State $Task.CallbackState
    for($i=0;$i -lt 150 -and -not $script:Live.Search.Finalized;$i++){Invoke-DomeniaLiveTick}
}
function Get-GridNames {return @($script:Ctrl.DgObjects.Items|Where-Object{$_ -ne [Windows.Data.CollectionView]::NewItemPlaceholder}|ForEach-Object{[string]$_.Name})}
function Result-For {param($Row) return [pscustomobject]@{DN=$Row.DN;Type=$Row.Type;Live=$true;Properties=@{name=@($Row.Name);objectGUID=@($Row.Guid);distinguishedName=@($Row.DN)}}}
function New-TreeNode {param([string]$Dn,[bool]$Loaded)
    $n=[Windows.Controls.TreeViewItem]::new();$n.Header=$Dn;$n.Tag=[pscustomobject]@{DN=$Dn;Loaded=$Loaded};return $n
}
function Start-Continuity {Initialize-DomeniaContinuity;if($null -ne $script:Continuity.Timer){$script:Continuity.Timer.Stop()}}

# ---------------------------------------------------------------- D031 strict global contract
# Unwired if Set-DomeniaItemsSource stops reading the search mode: the global user is hidden again.
Case 'D031 Global repaint ignores the local OU text filter' {
    $script:Ctrl.TxtSuiteResultFilter.Text='PC-ONLY'
    $a=New-ResultRow 'Alex' 'alex';$p=New-ResultRow 'PC-ONLY' 'pc' 'Machine'
    foreach($r in @($a,$p)){Add-Member -InputObject $r -NotePropertyName Association -NotePropertyValue '';Add-Member -InputObject $r -NotePropertyName Presence -NotePropertyValue '';Add-Member -InputObject $r -NotePropertyName SessionDisplay -NotePropertyValue '';Add-Member -InputObject $r -NotePropertyName SessionState -NotePropertyValue ''}
    Set-DomeniaSearchMode Global;[void](Set-DomeniaItemsSource -Name DgObjects -Rows @($a,$p))
    $names=Get-GridNames
    Expect ($names -contains 'Alex' -and $names.Count -eq 2) 'Un utilisateur global est masque par le filtre local.'
    Expect ($script:Ctrl.LblSuiteResultCount.Text.Contains('recherche globale sans filtre local'))
    Set-DomeniaSearchMode OU;[void](Set-DomeniaItemsSource -Name DgObjects -Rows @($a,$p))
    $names=Get-GridNames
    Expect ($names.Count -eq 1 -and $names[0] -eq 'PC-ONLY') 'Le filtre local doit rester actif en OU.'
}
# Unwired if Invoke-DomeniaObjectChanges uses Get-BranchQueryData for a global list: BaseDn becomes the OU.
Case 'D031 Revalidation of a global list keeps the whole domain and asks the rest policy' {
    function Test-DomeniaBackgroundWorkAllowed {param([string]$Source) $script:BackgroundAsked.Add($Source);return $true}
    $script:BackgroundAsked=[Collections.Generic.List[string]]::new()
    $script:Ctrl.DgObjects=[pscustomobject]@{IsEnabled=$true;IsVisible=$true;ItemsSource=$null;SelectedIndex=-1;SelectedItem=$null;SelectedItems=@();Items=@()}
    $script:Ctrl.TxtBranchSearch.Text='PC';$script:Ctrl.ChkSubtree.IsChecked=$false
    $t=Search-Global 'alex'
    $s=$script:Live.Search;Expect ($null -ne $s) 'Recherche progressive absente.'
    $row=New-DomeniaLiveResultRow;$row.Type='Utilisateur';$row.Name='Alex';$row.DN='CN=Alex,OU=Lyon,DC=example,DC=invalid';$row.Guid='11111111-1111-1111-1111-111111111111'
    [void]$s.Rows.Add($row);$s.Map['cn=alex,ou=lyon,dc=example,dc=invalid']=$row;$s.Finalized=$true;$s.Error=''
    Start-Continuity
    Invoke-DomeniaObjectChanges
    $script:Continuity.ChangeNext=[datetime]::MinValue
    Invoke-DomeniaObjectChanges
    $check=Get-LastTask 'LiveDirectoryCheck';Expect ($null -ne $check) 'Aucune revalidation demandee.'
    Expect ([string]$check.Payload.BaseDn -eq $script:Conn.BaseDn) ('Base heritee : '+[string]$check.Payload.BaseDn)
    Expect ([string]$check.Payload.Scope -eq 'Subtree' -and [string]$check.Payload.Filter -ceq (Get-TypeLdapFilter 'Tous')) 'Perimetre ou filtre local herite.'
    Expect ($script:BackgroundAsked -contains 'ObjectChanges') 'La politique de repos (C1) nʼest pas consultee.'
}
Case 'D031 Revalidation of an OU list keeps its own perimeter' {
    function Test-DomeniaBackgroundWorkAllowed {param([string]$Source) return $true}
    $script:Ctrl.DgObjects=[pscustomobject]@{IsEnabled=$true;IsVisible=$true;ItemsSource=$null;SelectedIndex=-1;SelectedItem=$null;SelectedItems=@();Items=@()}
    $script:Ctrl.TxtBranchSearch.Text='PC'
    Invoke-GlobalSearch -SearchMode OU
    $s=$script:Live.Search
    $row=New-DomeniaLiveResultRow;$row.Type='Machine';$row.Name='PC-01';$row.DN='CN=PC-01,OU=Postes,DC=example,DC=invalid';$row.Guid='33333333-3333-3333-3333-333333333333'
    [void]$s.Rows.Add($row);$s.Map['cn=pc-01,ou=postes,dc=example,dc=invalid']=$row;$s.Finalized=$true;$s.Error=''
    Start-Continuity;Invoke-DomeniaObjectChanges;$script:Continuity.ChangeNext=[datetime]::MinValue;Invoke-DomeniaObjectChanges
    $check=Get-LastTask 'LiveDirectoryCheck'
    Expect ($null -ne $check -and [string]$check.Payload.BaseDn -eq $script:SelectedBranchDn -and [string]$check.Payload.Scope -eq 'OneLevel')
}
# Unwired if the contract check before Begin-DomeniaLiveSearch is removed: the inherited OU search is sent.
Case 'D031 An inherited perimeter is refused before any request' {
    function Get-DomeniaSearchScope {param([string]$Mode='Global') return [pscustomobject]@{BaseDn='OU=Postes,DC=example,DC=invalid';Scope='OneLevel';IsDomain=$false;Mode=$Mode}}
    [void](Search-Global 'alex')
    Expect ((Get-TaskCount 'GlobalSearch') -eq 0) 'Une recherche au perimetre herite a ete envoyee.'
    Expect (@($script:OperationErrors|Where-Object{$_ -match 'Contrat de recherche globale'}).Count -eq 1) 'Refus non explique.'
}
Case 'D031 Same input, same logical perimeter from every page' {
    $seen=[Collections.Generic.List[string]]::new()
    foreach($case in @(@('TabDashboard','OU=Postes,DC=example,DC=invalid','Tous',''),@('WsObject','OU=Lyon,DC=example,DC=invalid','En ligne','PC'),@('WsComputer','OU=Sites,DC=example,DC=invalid','Sans réponse au ping','zz'))){
        $script:Ctrl.WorkspaceTabs.SelectedItem=$script:Ctrl[$case[0]];$script:SelectedBranchDn=$case[1];$script:CurrentPresenceFilter=$case[2];$script:Ctrl.TxtSuiteResultFilter.Text=$case[3]
        $script:Ctrl.CmbGlobalType.SelectedIndex=([array]::IndexOf(@('TabDashboard','WsObject','WsComputer'),$case[0])+1)
        $t=Search-Global 'dupont'
        $seen.Add(([string]$t.Payload.BaseDn+'|'+$t.Payload.Scope+'|'+$t.Payload.PrefixFilter+'|'+$t.Payload.ExactFilter+'|'+$t.Payload.BroadFilter+'|'+$t.CallbackState.TypeFilter))
    }
    Expect (@($seen|Select-Object -Unique).Count -eq 1) 'Le perimetre depend de la page ou des filtres locaux.'
    Expect ($seen[0].StartsWith($script:Conn.BaseDn+'|Subtree|'))
}

# ---------------------------------------------------------------- D032 search and browse kept apart
# Unwired if the restoration guard reads TxtGlobalSearch again: the OU search is cancelled.
Case 'D032 Upper-bar text does not cancel a pending OU restoration' {
    $root=New-TreeNode $script:Conn.BaseDn $true;$ou=New-TreeNode 'OU=Postes,DC=example,DC=invalid' $true;[void]$root.Items.Add($ou);[void]$script:Ctrl.TvDirectory.Items.Add($root)
    $script:Settings['OuBookmarksJson']=''
    Start-Continuity
    $script:Continuity.Bookmarks[(Get-DomeniaTreeContextKey)]=[pscustomobject]@{Selected='OU=Postes,DC=example,DC=invalid';Expanded=@();Subtree=$false}
    $script:Continuity.RestoreToken='';Start-DomeniaTreeBookmarkRestore;Invoke-DomeniaTreeBookmarkRestore
    Expect ($null -ne $script:Continuity.RestoreSearch) 'Restauration non preparee.'
    $script:Ctrl.TxtGlobalSearch.Text='autre recherche du bandeau'
    Invoke-DomeniaRestoredOuSearch
    $t=Get-LastTask 'GlobalSearch'
    Expect ($null -ne $t -and $t.CallbackState.SearchMode -eq 'OU' -and $t.Payload.BaseDn -eq 'OU=Postes,DC=example,DC=invalid') 'Le texte du bandeau a annule la restauration de lʼOU.'
}
Case 'D032 OU text change still cancels a pending OU restoration' {
    $root=New-TreeNode $script:Conn.BaseDn $true;$ou=New-TreeNode 'OU=Postes,DC=example,DC=invalid' $true;[void]$root.Items.Add($ou);[void]$script:Ctrl.TvDirectory.Items.Add($root)
    Start-Continuity
    $script:Continuity.Bookmarks[(Get-DomeniaTreeContextKey)]=[pscustomobject]@{Selected='OU=Postes,DC=example,DC=invalid';Expanded=@();Subtree=$false}
    $script:Continuity.RestoreToken='';Start-DomeniaTreeBookmarkRestore;Invoke-DomeniaTreeBookmarkRestore
    $script:Ctrl.TxtBranchSearch.Text='nouveau terme'
    Invoke-DomeniaRestoredOuSearch
    Expect ((Get-TaskCount 'GlobalSearch') -eq 0 -and $null -eq $script:Continuity.RestoreSearch)
}
Case 'D032 Clicking an OU after a user search browses the OU without the user name' {
    [void](Search-Global 'dupont')
    Expect ($script:Ctrl.LblSearchScope.Text.Contains('Domaine entier'))
    Set-SelectedBranch ([pscustomobject]@{Tag=[pscustomobject]@{DN='OU=Lyon,DC=example,DC=invalid'}})
    $t=Get-LastTask 'GlobalSearch'
    Expect ($t.CallbackState.SearchMode -eq 'OU' -and $t.CallbackState.Search -eq '' -and $t.Payload.BaseDn -eq 'OU=Lyon,DC=example,DC=invalid')
    Expect (-not ([string]$t.Payload.BroadFilter + [string]$t.Payload.PrefixFilter).Contains('dupont')) 'LʼOU est filtree par le texte du bandeau.'
    Expect ($script:Ctrl.TxtGlobalSearch.Text -eq 'dupont') 'Le texte du bandeau doit etre conserve.'
    Expect ($script:Ctrl.LblSearchScope.Text.StartsWith('Dans cette OU : Lyon')) ('Libelle : '+$script:Ctrl.LblSearchScope.Text)
}

# ---------------------------------------------------------------- D033 optional explicit syntax
# Unwired if Invoke-GlobalSearch ignores Get-DomeniaGlobalSearchPlan: the token is searched as a name.
Case 'D033 Explicit token refines the global search only' {
    $t=Search-Global 'poste:PC-01'
    Expect ($t.Payload.PrefixFilter.Contains('(objectCategory=computer)') -and $t.Payload.PrefixFilter.Contains('PC-01*')) ('Filtre : '+$t.Payload.PrefixFilter)
    Expect (-not $t.Payload.FastFilter -and -not $t.Payload.ExactFilter -and -not $t.Payload.AnrFilter -and -not $t.Payload.BroadFilter) 'Un filtre cache a ete ajoute.'
    Expect ($t.Payload.BaseDn -eq $script:Conn.BaseDn -and $t.Payload.Scope -eq 'Subtree')
    Expect ($script:Ctrl.LblSearchHint.Text.Contains('Machine : PC-01')) ('Jeton non visible : '+$script:Ctrl.LblSearchHint.Text)
}
Case 'D033 Unknown prefix stays a plain, explained text' {
    $t=Search-Global 'service:compta'
    Expect ($t.Payload.AnrFilter.Contains('(anr=service:compta)') -and $t.Payload.PrefixFilter.Contains('(name=service:compta*)'))
    Expect ($script:Ctrl.LblSearchHint.Text.Contains('pas un jeton reconnu'))
}
Case 'D033 Features.SearchSyntax off keeps the former filters' {
    $script:CfgOverrides['Features/SearchSyntax']=$false
    $t=Search-Global 'poste:PC-01'
    Expect ($t.Payload.PrefixFilter.Contains('(name=poste:PC-01*)') -and -not $t.Payload.PrefixFilter.Contains('(objectCategory=computer)(&'))
}
Case 'D033 Typing updates the hint without any request' {
    Initialize-DomeniaSearchUi
    $script:Ctrl.TxtGlobalSearch.Text='groupe:Compta'
    Expect ($script:Ctrl.LblSearchHint.Text.Contains('Groupe : Compta')) ('Indice : '+$script:Ctrl.LblSearchHint.Text)
    Expect ($script:Tasks.Count -eq 0) 'La saisie a lance une requete.'
}

# ---------------------------------------------------------------- D034 ranking and administration accounts
# Unwired if Begin-DomeniaLiveSearch / Add-DomeniaLiveRow stop ranking: arrival order shows the broad match first.
Case 'D034 Exact account first, then whole name; administration account identifiable' {
    $t=Search-Global 'dupont'
    Feed-Live (New-ResultRow 'Dupontel Marc' 'mdupontel')
    Feed-Live (New-ResultRow 'Jean Dupont' 'jdupont')
    Feed-Live (New-ResultRow 'Dupont' 'dupont')
    Feed-Live (New-ResultRow 'Zed Admin' 'adm-zed')
    # A protected account (adminCount=1, projected by the GlobalSearch worker) without an administration name.
    $protected=New-ResultRow 'Paul Dupontier' 'pdupontier';Add-Member -InputObject $protected -NotePropertyName AdminCount -NotePropertyValue '1'
    Feed-Live $protected
    Pump-Live
    $items=@($script:Ctrl.DgObjects.Items)
    Expect ($items.Count -eq 5) ('Lignes : '+$items.Count)
    Expect ($items[0].Login -eq 'dupont' -and $items[1].Login -eq 'jdupont' -and $items[2].Login -eq 'mdupontel') ('Ordre : '+(($items|ForEach-Object{$_.Login}) -join ','))
    $admin=@($items|Where-Object{$_.Login -eq 'adm-zed'})[0]
    Expect ($admin.Admin -eq 'Compte admin' -and $items[0].Admin -eq '') 'Compte dʼadministration non signale.'
    $marked=@($items|Where-Object{$_.Login -eq 'pdupontier'})[0]
    Expect ($marked.Admin -eq 'Compte admin') 'Compte protege (adminCount=1) non signale.'
    Expect (@((Get-LastTask 'GlobalSearch').Payload.Properties) -contains 'adminCount') 'adminCount nʼest pas demande a lʼannuaire.'
}

# ---------------------------------------------------------------- D035 compound names and special characters
# Unwired if the multi-word fallback is not taken from the plan: one prefix on the whole string comes back.
Case 'D035 Several words each match, no implicit leading wildcard' {
    $t=Search-Global "Jean-Marc O'Neil"
    Expect ($t.Payload.BroadFilter.StartsWith('(&'+(Get-TypeLdapFilter 'Tous')+'(|(cn=Jean-Marc*)')) ('Repli : '+$t.Payload.BroadFilter)
    Expect ($t.Payload.BroadFilter.Contains(")(|(cn=O'Neil*)") -and $t.Payload.BroadFilter.Contains("(sn=O'Neil*)"))
    Expect (-not ($t.Payload.BroadFilter -match '=\*')) 'Joker initial implicite.'
    Expect ($t.Payload.PrefixFilter.Contains("(anr=Jean-Marc O'Neil)")) 'La premiere passe epinglee doit rester.'
}
Case 'D035 Runtime escaping equals the rule escaping for every byte' {
    for($i=0;$i -le 255;$i++){
        $ch=[string][char]$i
        Expect ((Escape-LdapValue -Value $ch) -ceq (ConvertTo-DomeniaLdapLiteral $ch)) ('Ecart sans joker : '+$i)
        Expect ((Escape-LdapValue -Value $ch -KeepWildcard) -ceq (ConvertTo-DomeniaLdapLiteral $ch -KeepWildcard)) ('Ecart avec joker : '+$i)
    }
    $t=Search-Global 'x)(objectClass=*'
    Expect (-not $t.Payload.BroadFilter.Contains('(objectClass=*)')) 'Injection de filtre.'
}

# ---------------------------------------------------------------- D036 pasted identifiers
# Unwired if the identifier plan is ignored: the SID is searched as a name prefix.
Case 'D036 Pasted SID and GUID become exact searches, nothing opens automatically' {
    $t=Search-Global 'S-1-5-21-1-2-3-1104'
    Expect ($t.Payload.PrefixFilter -ceq ('(&'+(Get-TypeLdapFilter 'Tous')+'(objectSid=S-1-5-21-1-2-3-1104))')) ('Filtre : '+$t.Payload.PrefixFilter)
    Expect (-not $t.Payload.AnrFilter -and -not $t.Payload.BroadFilter -and [string]$t.CallbackState.PreserveSelectionDn -eq '')
    Expect ((Get-TaskCount 'OpenAdObject') -eq 0 -and $null -eq $script:SelectionLoad) 'Une fiche a ete ouverte automatiquement.'
    Expect ($script:Ctrl.LblSearchHint.Text.Contains('SID reconnu'))
    $g=Search-Global '{F4DC5A91-C11B-46B5-893D-9A2CBBAD31AD}'
    Expect ($g.Payload.PrefixFilter -match '\(objectGUID=(\\[0-9a-f]{2}){16}\)\)$') ('Filtre GUID : '+$g.Payload.PrefixFilter)
}
Case 'D036 Address is explained but keeps the prefix search' {
    $t=Search-Global 'jdupont@example.invalid'
    Expect ($t.Payload.PrefixFilter.Contains('(mail=jdupont@example.invalid*)')) 'La recherche par prefixe a ete remplacee.'
    Expect ($script:Ctrl.LblSearchHint.Text.Contains('Adresse reconnue'))
}
Case 'D036 A pasted DN is not cut at its commas' {
    $dn='CN=Dupont\, Jean,OU=Lyon,DC=example,DC=invalid'
    Start-DomeniaSearchFor -Term $dn
    $t=Get-LastTask 'GlobalSearch'
    Expect ($script:Ctrl.TxtGlobalSearch.Text -ceq $dn) ('Texte tronque : '+$script:Ctrl.TxtGlobalSearch.Text)
    Expect ($t.Payload.PrefixFilter.Contains('(distinguishedName=CN=Dupont\5c, Jean,OU=Lyon,DC=example,DC=invalid)')) ('Filtre : '+$t.Payload.PrefixFilter)
}

# ---------------------------------------------------------------- D037 explicit continuation
# Unwired if Invoke-DomeniaLiveTick keeps the former label or the button is not driven: the expectations fail.
Case 'D037 Limited list says so and offers the next load; a new load discards the old context' {
    $script:Ctrl.TxtGlobalLimit.Text='1'
    $t=Search-Global 'alex'
    Feed-Live (New-ResultRow 'Alex' 'alex')
    Finish-Live $t $true
    Expect ($script:Ctrl.LblBranchCount.Text -match 'limitée à 1') ('Compteur : '+$script:Ctrl.LblBranchCount.Text)
    Expect ($script:Ctrl.BtnSearchMore.IsEnabled) 'Charger la suite indisponible.'
    $before=Get-TaskCount 'GlobalSearch'
    Invoke-DomeniaSearchMore
    $next=Get-LastTask 'GlobalSearch'
    Expect ((Get-TaskCount 'GlobalSearch') -eq ($before+1) -and [int]$next.Payload.Limit -eq 2 -and [string]$next.CallbackState.Search -eq 'alex') 'La suite ne relance pas la meme recherche.'
    Expect ($script:Ctrl.TxtGlobalLimit.Text -eq '1') 'La limite saisie par lʼoperateur a ete modifiee.'
    Expect (-not (Test-DomeniaSearchStateCurrent $t.CallbackState)) 'Lʼancien contexte reste accepte.'
}
Case 'D037 Complete list says so and offers nothing more' {
    $t=Search-Global 'alex'
    Feed-Live (New-ResultRow 'Alex' 'alex')
    Finish-Live $t $false
    Expect ($script:Ctrl.LblBranchCount.Text -match 'liste complète') ('Compteur : '+$script:Ctrl.LblBranchCount.Text)
    Expect (-not $script:Ctrl.BtnSearchMore.IsEnabled)
}

# ---------------------------------------------------------------- D038 favourites and work views
# Unwired if the view is not applied by Invoke-GlobalSearch: the broad filter is the bare type filter.
Case 'D038 A work view runs read-only, without account, right or write mode' {
    Update-DomeniaWorkViewList
    $item=@($script:Ctrl.CmbWorkView.Items|Where-Object{[string]$_.Tag -eq 'disabled'})[0];$script:Ctrl.CmbWorkView.SelectedItem=$item
    Invoke-DomeniaWorkView
    $t=Get-LastTask 'GlobalSearch'
    Expect ($null -ne $t -and $t.Payload.BroadFilter.Contains('userAccountControl:1.2.840.113556.1.4.803:=2')) 'Vue non appliquee.'
    Expect (-not $t.Payload.PrefixFilter -and -not $t.Payload.AnrFilter -and $t.Payload.BaseDn -eq $script:Conn.BaseDn -and $t.CallbackState.ViewId -eq 'disabled')
    foreach($bag in @($t.Payload,$t.CallbackState)){foreach($p in $bag.PSObject.Properties){Expect ($p.Name -notmatch '(?i)credential|password|secret|iswrite|readonlymode|admin') ('Propriete sensible : '+$p.Name)}}
    Expect (Test-DomeniaSearchStateCurrent $t.CallbackState)
    [void](Search-Global 'dupont')
    Expect (-not (Test-DomeniaSearchStateCurrent $t.CallbackState)) 'Un retour tardif de vue serait accepte.'
}
Case 'D038 An OU view keeps the selected OU' {
    Invoke-DomeniaWorkView -ViewId 'oucomputers'
    $t=Get-LastTask 'GlobalSearch'
    Expect ($t.CallbackState.SearchMode -eq 'OU' -and $t.Payload.BaseDn -eq $script:SelectedBranchDn -and $t.Payload.BroadFilter.Contains('(objectCategory=computer)'))
}
Case 'D038 Saving a favourite opens no window and keeps no account' {
    [void](Search-Global 'dupont')
    Save-DomeniaFavouriteSearch
    $saved=@($script:Settings['SavedSearches'])
    Expect ($saved.Count -eq 1 -and $saved[0].Name -eq 'Domaine entier : dupont' -and $saved[0].SearchMode -eq 'Global') ('Favori : '+($saved|ConvertTo-Json -Compress))
    $names=@($saved[0].PSObject.Properties|ForEach-Object{$_.Name}|Sort-Object)
    Expect (($names -join ',') -eq 'DN,Limit,Name,Query,SearchMode,Subtree,Type') ('Champs : '+($names -join ','))
    Invoke-DomeniaWorkView -ViewId 'disabled'
    Save-DomeniaFavouriteSearch
    Expect (@($script:Settings['SavedSearches']).Count -eq 1 -and $script:LastStatus -match 'vue de travail')
}

# ---------------------------------------------------------------- D039 readable and restorable OU
# Unwired if the expiry keeps the former status only: no page warning, no explicit choice.
Case 'D039 OU absent under its read parent: warning in the page, no substitution' {
    $root=New-TreeNode $script:Conn.BaseDn $true;$sites=New-TreeNode 'OU=Sites,DC=example,DC=invalid' $true;[void]$root.Items.Add($sites);[void]$script:Ctrl.TvDirectory.Items.Add($root)
    Start-Continuity
    $saved='OU=Absente,OU=Sites,DC=example,DC=invalid'
    $script:Continuity.Bookmarks[(Get-DomeniaTreeContextKey)]=[pscustomobject]@{Selected=$saved;Expanded=@();Subtree=$true}
    $script:Continuity.RestoreToken='';Start-DomeniaTreeBookmarkRestore
    $script:Continuity.RestoreDeadline=[datetime]::UtcNow.AddSeconds(-1)
    Invoke-DomeniaTreeBookmarkRestore;Invoke-DomeniaRestoredOuSearch
    $expected=(Resolve-DomeniaOuRestore -SavedDn $saved -Exists $false -MovedToDn '' -ReadFailed $false).Message
    Expect ($script:Ctrl.LblOuRestoreMessage.Text -ceq $expected) ('Message : '+$script:Ctrl.LblOuRestoreMessage.Text)
    Expect ($script:Ctrl.OuRestoreBanner.Visibility -eq 'Visible') 'Avertissement absent de la page.'
    Expect ($expected.Contains('example.invalid / Sites / Absente'))
    Expect ($script:SelectedBranchDn -eq 'OU=Postes,DC=example,DC=invalid' -and (Get-TaskCount 'GlobalSearch') -eq 0) 'Un autre perimetre a ete applique.'
}
Case 'D039 Parent not read in time: a retry is asked, never an absence' {
    $root=New-TreeNode $script:Conn.BaseDn $false;[void]$script:Ctrl.TvDirectory.Items.Add($root)
    Start-Continuity
    $saved='OU=Absente,OU=Sites,DC=example,DC=invalid'
    $script:Continuity.Bookmarks[(Get-DomeniaTreeContextKey)]=[pscustomobject]@{Selected=$saved;Expanded=@();Subtree=$true}
    $script:Continuity.RestoreToken='';Start-DomeniaTreeBookmarkRestore
    $script:Continuity.RestoreDeadline=[datetime]::UtcNow.AddSeconds(-1)
    Invoke-DomeniaTreeBookmarkRestore
    Expect ($script:Ctrl.LblOuRestoreMessage.Text -ceq (Resolve-DomeniaOuRestore -SavedDn $saved -Exists $false -MovedToDn '' -ReadFailed $true).Message)
    Expect (-not $script:Ctrl.LblOuRestoreMessage.Text.Contains('introuvable')) 'Un delai est presente comme une absence.'
    Invoke-DomeniaOuRestoreRetry
    Expect ($script:Continuity.Restoring -and $script:Ctrl.OuRestoreBanner.Visibility -ne 'Visible' -and (Get-TaskCount 'GlobalSearch') -eq 0) 'Relire doit relancer seulement la restauration.'
}

# ---------------------------------------------------------------- D040 back and forward
# Unwired if the WorkspaceTabs handler is not registered: there is no history and Back does not move.
Case 'D040 Back restores the remembered list without a new search or a probe, keeping its freshness' {
    Initialize-DomeniaSearchUi
    $first=Search-Global 'dupont';Feed-Live (New-ResultRow 'Jean Dupont' 'jdupont');Finish-Live $first $false
    $firstRows=$script:Ctrl.DgObjects.ItemsSource;$freshness=$script:Ctrl.LblBranchCount.Text
    Select-DomeniaWorkspace -Workspace 'WsObject'
    $second=Search-Global 'martin';Feed-Live (New-ResultRow 'Paul Martin' 'pmartin');Finish-Live $second $false
    Expect ($script:Ctrl.BtnNavBack.IsEnabled) 'Precedent indisponible.'
    $tasks=$script:Tasks.Count
    $step=Invoke-DomeniaNavStep -Direction Back
    Expect ($step.Moved -and $script:Ctrl.WorkspaceTabs.SelectedItem.Name -eq 'WsObject') 'Pas de retour a lʼetape precedente.'
    $step=Invoke-DomeniaNavStep -Direction Back
    Expect ($step.Moved -and $script:Ctrl.WorkspaceTabs.SelectedItem.Name -eq 'WsSearch' -and $script:Ctrl.TxtGlobalSearch.Text -eq 'dupont')
    Expect ([object]::ReferenceEquals($script:Ctrl.DgObjects.ItemsSource,$firstRows)) 'La liste memorisee nʼest pas restituee.'
    Expect ($script:Tasks.Count -eq $tasks) 'Le retour a lance une lecture, une recherche ou une sonde.'
    Expect ($script:Ctrl.LblBranchCount.Text.StartsWith($freshness) -and $script:Ctrl.LblBranchCount.Text.Contains('historique')) ('Fraicheur : '+$script:Ctrl.LblBranchCount.Text)
    Expect ($script:Ctrl.BtnNavForward.IsEnabled)
    $step=Invoke-DomeniaNavStep -Direction Forward
    Expect ($step.Moved -and $script:Ctrl.WorkspaceTabs.SelectedItem.Name -eq 'WsObject' -and $script:Tasks.Count -eq $tasks)
}
Case 'D040 An unsaved draft blocks back and forward' {
    Initialize-DomeniaSearchUi
    Select-DomeniaWorkspace -Workspace 'WsSearch';Select-DomeniaWorkspace -Workspace 'WsObject'
    $script:DirtyFields=@('TxtUserMail')
    $step=Invoke-DomeniaNavStep -Direction Back
    Expect ($step.Blocked -and -not $step.Moved -and $script:Ctrl.WorkspaceTabs.SelectedItem.Name -eq 'WsObject' -and $script:LastStatusLevel -eq 'WARN')
}

# ---------------------------------------------------------------- D012 single selection identity (C5)
# Unwired if the selection context carries no typed identity: the label and a tampered request field win.
Case 'D012 A label change never changes the target of the fiche read' {
    $a=New-ResultRow 'Alex' 'alex' 'Utilisateur' '11111111-1111-1111-1111-111111111111'
    $grid=$script:Ctrl.DgObjects;[void]$grid.Items.Add($a);$grid.SelectedItem=$a
    Queue-DomeniaSelectedObjectOpen -Immediate
    $identity=Get-DomeniaCurrentSelectionIdentity -Workspace 'WsSearch'
    Expect ($identity -is [Domenia.SelectionIdentity] -and $identity.Guid -eq '11111111-1111-1111-1111-111111111111') 'Identite typee absente.'
    Expect ($script:SelectionLoad.SelectionIdentity -is [Domenia.SelectionIdentity]) 'La fiche ne conserve pas lʼidentite capturee.'
    $request=Get-LastTask 'OpenAdObject';Expect ($null -ne $request -and $request.CallbackState.ExpectedGuid -eq $identity.Guid)
    $a.Name='Libelle modifie';$script:SelectionLoad.Context.Name='Autre cible';$script:Ctrl.LblSelectionReadState.Text='autre'
    Update-DomeniaSelectionReadUi
    Expect ($script:Ctrl.LblSelectionReadState.Text.StartsWith('Utilisateur : Alex')) ('Libelle : '+$script:Ctrl.LblSelectionReadState.Text)
    Expect (Test-DomeniaSelectionLoadCurrent) 'Un changement de libelle a change la cible.'
    $original=New-ResultRow 'Alex' 'alex' 'Utilisateur' '11111111-1111-1111-1111-111111111111'
    Complete-DomeniaOpenObjectTaskUi (Result-For $original) $request.CallbackState
    Expect ($script:SelectionLoad.Phase -eq 'Ready') ('Phase : '+$script:SelectionLoad.Phase+' '+$script:OpenFailure)
    $fiche=Get-DomeniaCurrentSelectionIdentity -Workspace 'WsObject'
    Expect ($null -ne $fiche -and $fiche.SameContext($identity) -and $fiche.Name -eq 'Alex') 'La fiche ne publie pas la meme identite.'
    $tampered=$request.CallbackState.PSObject.Copy();$tampered.ExpectedGuid='22222222-2222-2222-2222-222222222222'
    $other=New-ResultRow 'Alex' 'alex' 'Utilisateur' '22222222-2222-2222-2222-222222222222'
    $refused=$false;try{Assert-DomeniaObjectResultIdentity -Result (Result-For $other) -State $tampered}catch{$refused=$true}
    Expect $refused 'Un champ de requete modifie a redirige la lecture.'
}
Case 'D012 A recreated object under the same DN is another selection' {
    $a=New-ResultRow 'Alex' 'alex' 'Utilisateur' '11111111-1111-1111-1111-111111111111'
    $grid=$script:Ctrl.DgObjects;[void]$grid.Items.Add($a);$grid.SelectedItem=$a
    Queue-DomeniaSelectedObjectOpen -Immediate
    $b=New-ResultRow 'Alex' 'alex' 'Utilisateur' '22222222-2222-2222-2222-222222222222'
    $grid.SelectedItem=$null;$grid.Items.Clear();[void]$grid.Items.Add($b);$grid.SelectedItem=$b
    Expect (-not (Test-DomeniaSelectionLoadCurrent)) 'Un objet recree herite de la selection.'
    Expect ((Get-DomeniaCurrentSelectionIdentity -Workspace 'WsSearch').Guid -eq '22222222-2222-2222-2222-222222222222')
    $grid.SelectedItem=$null
    Expect ($null -eq (Get-DomeniaCurrentSelectionIdentity -Workspace 'WsSearch'))
}

# ---------------------------------------------------------------- C1 / C2 before background work
Case 'Rest policy (C1) and demonstration (C2) gate the live background work' {
    function Test-DomeniaBackgroundWorkAllowed {param([string]$Source) $script:BackgroundAsked.Add($Source);return [bool]$script:PolicyAllows}
    $script:BackgroundAsked=[Collections.Generic.List[string]]::new();$script:PolicyAllows=$false
    $script:Live.CacheReady=$true;$script:Live.SaveQueue['k']=[pscustomobject]@{Key='k'}
    Start-DomeniaLiveBackgroundWork
    Expect ((Get-TaskCount 'LiveCache') -eq 0 -and $script:BackgroundAsked -contains 'Live') 'Travail de fond lance malgre la politique de repos.'
    $script:PolicyAllows=$true;$script:DemoMode=$true
    Start-DomeniaLiveBackgroundWork
    Expect ((Get-TaskCount 'LiveCache') -eq 0) 'Travail de fond lance en demonstration.'
    $script:DemoMode=$false
    Start-DomeniaLiveBackgroundWork
    Expect ((Get-TaskCount 'LiveCache') -eq 1) 'Le travail autorise nʼa pas ete lance.'
}

# ---------------------------------------------------------------- real main XAML
Case 'Main XAML carries the search controls wired by the code' {
    $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));$window=$null
    try{
        $window=[Windows.Markup.XamlReader]::Load($reader)
        foreach($n in @('LblSearchHint','BtnSearchMore','CmbWorkView','BtnWorkView','BtnNavBack','BtnNavForward','OuRestoreBanner','LblOuRestoreMessage','BtnOuRestoreRetry','BtnOuRestoreDismiss')){Expect ($null -ne $window.FindName($n)) ('Controle absent : '+$n)}
        $grid=$window.FindName('DgObjects')
        Expect ($grid.Columns.Count -eq 18) 'Colonnes de resultats modifiees.'
        $trigger=@($grid.RowStyle.Triggers|Where-Object{$_ -is [Windows.DataTrigger] -and [string]$_.Value -eq 'Compte admin'})
        Expect ($trigger.Count -eq 1) 'Marque des comptes dʼadministration absente.'
        $script:Ctrl=@{}
        foreach($match in [regex]::Matches((Get-MainXaml),'x:Name="([^"]+)"')){$control=$window.FindName($match.Groups[1].Value);if($null -ne $control){$script:Ctrl[$match.Groups[1].Value]=$control}}
        $script:Window=$window
        Initialize-DomeniaSearchUi
        Expect ($script:Ctrl.CmbWorkView.Items.Count -eq @(Get-DomeniaWorkViews).Count -and -not $script:Ctrl.BtnNavBack.IsEnabled)
    }finally{$reader.Close();if($null -ne $window){$window.Close()}}
}

if($null -ne $script:Live -and $null -ne $script:Live.Timer){$script:Live.Timer.Stop()}
if($null -ne $script:Continuity -and $null -ne $script:Continuity.Timer){$script:Continuity.Timer.Stop()}
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-recherche-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{
    Kind='Wiring';Lot='recherche';Points=@('D012','D031','D032','D033','D034','D035','D036','D037','D038','D039','D040')
    Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell51=$native;Wpf=$true;LiveAD=$false;LiveCIM=$false;LivePing=$false
    Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0)
    Limitation='Raccordement prouve par les vraies fonctions et de vrais controles WPF, reseau double. Ne prouve pas un acces a un domaine reel.'
    Tests=$script:Checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed reussi(s), $failed en echec. Rapport : "+$ReportPath);$script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
