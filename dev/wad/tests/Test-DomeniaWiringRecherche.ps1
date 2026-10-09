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
    'Complete-DomeniaOpenObjectTaskUi','Fail-DomeniaOpenObjectTaskUi',
    # L03: OU tree, favourites, background revalidation default and targeted reread.
    'Refresh-SelectedObject','New-DefaultConfig','New-TreeItem','New-DomeniaTreeRowItem','New-DomeniaTreeSystemGroup','Get-DomeniaTreeRenderRows',
    'Get-DomeniaTreeHeaderTemplate','New-DomeniaTreeLoadingItem','Add-DomeniaTreeRowsToNode','Queue-DomeniaTreeRowsToNode','Stop-DomeniaTreeRenderForNode',
    'Initialize-DomeniaTreeRenderTimer','Load-TreeChildren',
    # UX-25: the local filter and the presence repaint the grid with a filtered copy of the list.
    'Apply-DomeniaPresenceFilter','Set-DomeniaGridRows')
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $wad 'Domenia-Core.ps1') $coreNames)))
# PF-14 / UX-25: the real handler of the object type, as Wire-Events attaches it (no copy of its text in this file).
function Get-WireEventsHandler {param([string]$Control,[string]$Event)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
    $wire=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wire-Events'},$true))
    if($wire.Count -ne 1){throw 'Wire-Events absent.'}
    $calls=@($wire[0].Body.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq $Event -and $n.Expression.Extent.Text -match [regex]::Escape('"'+$Control+'"')},$true))
    if($calls.Count -ne 1){throw ('Raccordement absent de Wire-Events : '+$Control+'.'+$Event)}
    return $calls[0].Extent.Text
}
$script:TypeWiring=Get-WireEventsHandler 'CmbGlobalType' 'Add_SelectionChanged'
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-UX.UI.ps1') @('Get-DomeniaUxOuDisplay','Update-DomeniaUxOuScope'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Guard.UI.ps1') @('Read-DomeniaOuFavouriteStore','Write-DomeniaOuFavouriteStore','Import-DomeniaFavouriteSearchesOnce','Get-DomeniaFavouriteSearches','Test-DomeniaOuFavourite','Save-DomeniaFavouriteSearch','Load-DomeniaFavouriteSearch','Update-DomeniaOuFavouritesUi','Remove-DomeniaFavouriteSearch'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Guard.Model.ps1') @('ConvertTo-DomeniaSavedSearch'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Park.UI.ps1') @('Start-DomeniaOnlinePark'))))
# Worker helpers live in the WorkerCommon text of the core: the row builder of the list is read from it, not copied.
$coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
$workerCommon=[regex]::Match($coreText,'(?ms)^\$script:WorkerCommon = @''\r?\n(.*?)\r?\n''@').Groups[1].Value
$workerTokens=$null;$workerErrors=$null
$workerAst=[Management.Automation.Language.Parser]::ParseInput($workerCommon,[ref]$workerTokens,[ref]$workerErrors)
foreach($name in @('Convert-WLargeInteger','Convert-WFileTime')){
    $node=@($workerAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($node.Count -ne 1){throw ('Fonction worker absente : '+$name)}
    . ([scriptblock]::Create($node[0].Extent.Text))
}
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Cache.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Search.Model.ps1','Domenia-Experience.Model.ps1','Domenia-Live.Model.ps1','Domenia-Engine.UI.ps1','Domenia-Storage.UI.ps1','Domenia-Live.UI.ps1','Domenia-Continuity.Model.ps1','Domenia-Continuity.UI.ps1','Domenia-Selection.UI.ps1','Domenia-Search.UI.ps1')){
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
# L03: the home overview reads the OU of Rechercher; the double records the OU it is asked to follow.
function Request-DomeniaFleetRefresh {param([switch]$Force) if($null -ne $script:FleetScopes){$script:FleetScopes.Add([string]$script:SelectedBranchDn)}}
function Update-DomeniaParkControls { }
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
    foreach($n in @('LblBranchCount','LblSuiteResultCount','LblSearchScope','LblSearchHint','LblLiveState','LblOuRestoreMessage','LblSelectionReadState','LblOuScopeName','LblOuScopePath','LblTreeStatus')){$c[$n]=[Windows.Controls.TextBlock]::new()}
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
    # L03 controls (OU menu, filter and favourites, view chip, history banner, revalidation switch, survey buttons).
    $c.TxtOuFilter=[Windows.Controls.TextBox]::new()
    foreach($n in @('BtnOuMenu','BtnOuFavouriteToggle','BtnHistoryRefresh','BtnParkResults','BtnParkPing','BtnParkAnalyze')){$c[$n]=[Windows.Controls.Button]::new()}
    foreach($n in @('UxOuMenuPanel','UxOuFavourites','UxHistoryBanner')){$c[$n]=[Windows.Controls.Border]::new();$c[$n].Visibility='Collapsed'}
    $c.PnlOuFavourites=[Windows.Controls.StackPanel]::new()
    $c.UxListRevalidation=[Windows.Controls.StackPanel]::new();$c.UxListRevalidation.Visibility='Collapsed'
    $c.ChkListRevalidation=[Windows.Controls.CheckBox]::new();$c.ChkListRevalidation.IsChecked=$true
    $c.LblListRevalidation=[Windows.Controls.TextBlock]::new()
    $c.CmbWorkViewScope=[Windows.Controls.ComboBox]::new()
    foreach($pair in @(@('OU','Vues dans : OU choisie'),@('Domain','Vues sur tout le domaine, sans relevé'))){$i=[Windows.Controls.ComboBoxItem]::new();$i.Tag=$pair[0];$i.Content=$pair[1];[void]$c.CmbWorkViewScope.Items.Add($i)}
    $c.CmbWorkViewScope.SelectedIndex=0
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
    $script:NavHistoryRows=$null;$script:NavHistoryState=$null;$script:NavListShape=$null;$script:OuTreeFilterStatus='';$script:TreeSelectionSource='Mouse';$script:WorkViewScopeOu='';$script:ListSurveyBlocked=$false;$script:ListRevalidationPaused=$false
    if($null -ne $script:FilterChangeTimer){$script:FilterChangeTimer.Stop()};$script:FilterChangeTimer=$null;$script:PendingFilterChange=$null
    if($null -ne $script:TreeRenderTimer){$script:TreeRenderTimer.Stop()};$script:TreeRenderTimer=$null;$script:TreeRenderJobs=@{}
    $script:OuFavouriteKeys=$null;$script:FleetScopes=[Collections.Generic.List[string]]::new();$script:SearchListHasMachine=$false;$script:ParkRun=$null
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
function Send-TreeKey {param($Tree)
    # A real PreviewKeyDown needs a presentation source: a hidden HWND source, disposed at once.
    $parameters=[Windows.Interop.HwndSourceParameters]::new('Domenia test clavier');$parameters.WindowStyle=0
    $source=[Windows.Interop.HwndSource]::new($parameters)
    try{$key=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,$source,0,[Windows.Input.Key]::Down);$key.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$Tree.RaiseEvent($key)}
    finally{$source.Dispose()}
}
function Send-TreeMouse {param($Tree)
    $mouse=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left);$mouse.RoutedEvent=[Windows.UIElement]::PreviewMouseDownEvent;$Tree.RaiseEvent($mouse)
}

# ---------------------------------------------------------------- D031 strict global contract
# Unwired if Set-DomeniaItemsSource stops reading the search mode: the global user is hidden again.
Case 'D031 Global repaint ignores the local OU text filter' {
    $script:Ctrl.TxtSuiteResultFilter.Text='PC-ONLY'
    $a=New-ResultRow 'Alex' 'alex';$p=New-ResultRow 'PC-ONLY' 'pc' 'Machine'
    foreach($r in @($a,$p)){Add-Member -InputObject $r -NotePropertyName Association -NotePropertyValue '';Add-Member -InputObject $r -NotePropertyName Presence -NotePropertyValue '';Add-Member -InputObject $r -NotePropertyName SessionDisplay -NotePropertyValue '';Add-Member -InputObject $r -NotePropertyName SessionState -NotePropertyValue ''}
    Set-DomeniaSearchMode Global;[void](Set-DomeniaItemsSource -Name DgObjects -Rows @($a,$p))
    $names=@(Get-GridNames)
    Expect ($names -contains 'Alex' -and $names.Count -eq 2) 'Un utilisateur global est masque par le filtre local.'
    Expect ($script:Ctrl.LblSuiteResultCount.Text.Contains('recherche globale sans filtre local'))
    Set-DomeniaSearchMode OU;[void](Set-DomeniaItemsSource -Name DgObjects -Rows @($a,$p))
    $names=@(Get-GridNames)
    Expect ($names.Count -eq 1 -and $names[0] -eq 'PC-ONLY') 'Le filtre local doit rester actif en OU.'
}
# Unwired if Invoke-DomeniaObjectChanges uses Get-BranchQueryData for a global list: BaseDn becomes the OU.
Case 'D031 Revalidation of a global list keeps the whole domain and asks the rest policy' {
    function Test-DomeniaBackgroundWorkAllowed {param([string]$Source) $script:BackgroundAsked.Add($Source);return $true}
    # SE-13: off by default since L03; an administrator enables it explicitly.
    $script:CfgOverrides['Streaming/RevalidateListedObjects']=$true
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
    $script:CfgOverrides['Streaming/RevalidateListedObjects']=$true
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
# Unwired if 'Charger la suite' plans the view again with the chip as it is now: another perimeter would be read.
Case 'D037 / UX-33 Charger la suite relit le perimetre de la vue, pas celui de la puce' {
    Update-DomeniaSearchScopeUi
    $script:Ctrl.TxtGlobalLimit.Text='1'
    $script:Ctrl.CmbWorkViewScope.SelectedIndex=1
    Invoke-DomeniaWorkView -ViewId 'stalecomputers'
    $t=Get-LastTask 'GlobalSearch'
    Expect ($t.CallbackState.SearchMode -eq 'Global' -and $t.CallbackState.ViewChoice -eq 'Domain') 'Vue sur tout le domaine non lancee.'
    Feed-Live (New-ResultRow 'PC-OLD' 'pcold' 'Machine' '' 'OU=Lyon');Finish-Live $t $true
    # The chip comes back to the OU (by hand, or another OU chosen): the continuation keeps the whole domain.
    $script:Ctrl.CmbWorkViewScope.SelectedIndex=0
    Invoke-DomeniaSearchMore
    $next=Get-LastTask 'GlobalSearch'
    Expect (-not [object]::ReferenceEquals($next,$t) -and [int]$next.Payload.Limit -eq 2) 'Suite non lancee.'
    Expect ($next.CallbackState.SearchMode -eq 'Global' -and $next.Payload.BaseDn -eq $script:Conn.BaseDn -and $next.Payload.Scope -eq 'Subtree' -and $next.CallbackState.ViewId -eq 'stalecomputers' -and -not [bool]$next.CallbackState.SurveyAllowed) ('La suite lit un autre perimetre : '+$next.Payload.BaseDn)
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
    # UX-33: the view applies to the OU chosen in the tree, not to the whole domain.
    Expect (-not $t.Payload.PrefixFilter -and -not $t.Payload.AnrFilter -and $t.Payload.BaseDn -eq $script:SelectedBranchDn -and $t.CallbackState.SearchMode -eq 'OU' -and $t.CallbackState.ViewId -eq 'disabled')
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
Case 'D038 / FO-04 Pinning an OU opens no window and keeps no account' {
    [void](Search-Global 'dupont')
    Expect ((Save-DomeniaFavouriteSearch) -eq $true) ('Epinglage refuse : '+$script:LastStatus)
    $saved=@(Read-DomeniaOuFavouriteStore)
    Expect ($saved.Count -eq 1 -and $saved[0].DN -eq $script:SelectedBranchDn -and $saved[0].Name -eq 'Postes') ('Favori : '+($saved|ConvertTo-Json -Compress))
    $names=@($saved[0].PSObject.Properties|ForEach-Object{$_.Name}|Sort-Object)
    Expect (($names -join ',') -eq 'DN,Name,Subtree,Term,Type') ('Champs : '+($names -join ','))
    Expect ([string]$script:Settings['OuFavouritesJson'] -notmatch '(?i)dupont|credential|password|secret') 'Le texte du bandeau ou un secret a ete memorise.'
    Expect ($null -eq $script:Settings['SavedSearches']) 'Les recherches enregistrees ne sont plus ecrites.'
    Expect ($script:Ctrl.UxOuFavourites.Visibility -eq 'Visible' -and $script:Ctrl.PnlOuFavourites.Children.Count -eq 1) 'Favori absent du haut de lʼarbre.'
    Expect ([string]$script:Ctrl.BtnOuFavouriteToggle.Content -eq 'Retirer des favoris')
    Expect ((Remove-DomeniaFavouriteSearch -Dn $script:SelectedBranchDn) -eq $true -and @(Read-DomeniaOuFavouriteStore).Count -eq 0 -and $script:Ctrl.UxOuFavourites.Visibility -eq 'Collapsed')
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

# ---------------------------------------------------------------- D028 save state from the rule (lot cache F2)
# Unwired if Invoke-DomeniaLiveTick keeps its own texts or the write in flight is not counted: the label differs from the rule.
Case 'D028 LblLiveState porte le libelle de la regle' {
    $script:Persistence=$null
    $texts=[Collections.Generic.List[string]]::new()
    $read={param([string]$Expected,[string]$Why)
        Invoke-DomeniaLiveTick
        $text=[string]$script:Ctrl.LblLiveState.Text;$texts.Add($text)
        $state=(Get-DomeniaPersistenceState).Label
        Expect ($text.EndsWith(' · '+$state)) ($Why+' : la ligne ne finit pas par le libelle de la regle : '+$text)
        Expect ($state -ceq $Expected) ($Why+' : attendu '+$Expected+', obtenu '+$state)
    }
    $script:Live.CacheReady=$true
    & $read 'Enregistre.' 'Rien en attente'
    # Two observations wait while the writer is held back.
    $script:Live.SaveAfter=[datetime]::UtcNow.AddHours(1)
    $script:Live.SaveQueue['a']=[pscustomobject]@{Key='a'};$script:Live.SaveQueue['b']=[pscustomobject]@{Key='b'}
    & $read 'En memoire : 2 modification(s) a enregistrer.' 'Deux observations en file'
    # The real tick starts the write: SaveQueue empties, the two observations are still counted (SaveInFlight).
    $script:Live.SaveAfter=[datetime]::MinValue
    & $read 'En memoire : 2 modification(s) a enregistrer.' 'Ecriture en cours'
    $write=Get-LastTask 'LiveCache'
    Expect ($null -ne $write -and $script:Live.SaveQueue.Count -eq 0 -and [int]$script:Live.SaveInFlight -eq 2) 'Ecriture non lancee ou non comptee.'
    # The write fails: requeued, SaveFault with work waiting.
    [void]$script:AsyncJobs.Remove([string]$write.Id)
    Fail-DomeniaLiveCache 'SQLite code 5 : database is locked' $write.CallbackState
    & $read 'En memoire : 1 enregistrement(s) en echec, nouvel essai prevu.' 'Echec d ecriture'
    # The next write succeeds.
    $script:Live.SaveAfter=[datetime]::MinValue
    Invoke-DomeniaLiveTick
    $retry=Get-LastTask 'LiveCache'
    Expect ($null -ne $retry -and -not [object]::ReferenceEquals($retry,$write)) 'Nouvel essai non lance.'
    [void]$script:AsyncJobs.Remove([string]$retry.Id)
    Complete-DomeniaLiveCache $null $retry.CallbackState
    & $read 'Enregistre.' 'Apres ecriture confirmee'
    # A failed read with nothing waiting is not a save failure.
    $script:Live.SaveFault='Lecture du cache impossible'
    & $read 'Enregistre.' 'Echec de lecture sans attente'
    $script:Live.CacheReady=$false
    & $read 'En memoire uniquement : stockage local indisponible, rien n est enregistre.' 'Stockage indisponible'
    foreach($text in $texts){foreach($old in @('cache uniquement en mémoire','mémoire locale non enregistrée','aucun enregistrement en attente')){Expect (-not $text.Contains($old)) ('Ancien libelle : '+$text)}}
}

# ---------------------------------------------------------------- L03 OU tree, perimeter and work views
# Unwired if the stale view keeps the former filter: a workstation without lastLogonTimestamp is never listed.
Case 'CO-20 Postes sans connexion inclut les jamais connectes, affiches Jamais' {
    Invoke-DomeniaWorkView -ViewId 'stalecomputers'
    $t=Get-LastTask 'GlobalSearch'
    Expect ($null -ne $t -and $t.Payload.BroadFilter.Contains('(|(lastLogonTimestamp<=') -and $t.Payload.BroadFilter.Contains('(!(lastLogonTimestamp=*))')) ('Filtre : '+$t.Payload.BroadFilter)
    Expect ((Convert-WFileTime 0) -eq 'Jamais' -and (Convert-WFileTime $null) -eq 'Jamais') 'Un poste sans lastLogonTimestamp doit afficher Jamais.'
}
# Unwired if Invoke-GlobalSearch keeps NeedsOu or ignores the chip: the view reads the whole domain, or a survey is offered.
Case 'UX-33 Vue de travail appliquee a lʼOU par defaut, releve refuse en domaine entier' {
    Update-DomeniaSearchScopeUi
    Expect ([string]$script:Ctrl.CmbWorkViewScope.Items[0].Content -eq 'Vues dans : Postes') ('Puce : '+[string]$script:Ctrl.CmbWorkViewScope.Items[0].Content)
    Invoke-DomeniaWorkView -ViewId 'expiring'
    $ou=Get-LastTask 'GlobalSearch'
    Expect ($ou.CallbackState.SearchMode -eq 'OU' -and $ou.Payload.BaseDn -eq 'OU=Postes,DC=example,DC=invalid' -and [bool]$ou.CallbackState.SurveyAllowed -and -not $script:ListSurveyBlocked) 'La vue ne sʼapplique pas a lʼOU choisie.'
    Expect ($script:Ctrl.LblSearchHint.Text.Contains('Dans : Postes')) ('Indice : '+$script:Ctrl.LblSearchHint.Text)
    $script:Ctrl.CmbWorkViewScope.SelectedIndex=1
    Invoke-DomeniaWorkView -ViewId 'stalecomputers'
    $domain=Get-LastTask 'GlobalSearch'
    Expect ($domain.CallbackState.SearchMode -eq 'Global' -and $domain.Payload.BaseDn -eq $script:Conn.BaseDn -and $domain.Payload.Scope -eq 'Subtree') 'Le choix explicite du domaine entier nʼest pas applique.'
    Expect (-not [bool]$domain.CallbackState.SurveyAllowed -and $script:ListSurveyBlocked -and $script:Ctrl.LblSearchHint.Text.Contains('aucun relev')) 'Le releve nʼest pas refuse sur le domaine entier.'
    Expect ($script:SelectedBranchDn -eq 'OU=Postes,DC=example,DC=invalid') 'Une vue sur le domaine a change lʼOU choisie.'
    $script:SearchListHasMachine=$true
    Update-DomeniaSearchActionStates
    foreach($n in @('BtnParkResults','BtnParkPing','BtnParkAnalyze')){Expect (-not $script:Ctrl[$n].IsEnabled) ('Releve propose : '+$n)}
    $before=$script:Tasks.Count
    Start-DomeniaOnlinePark -DisplayedResults
    Expect ($script:Tasks.Count -eq $before -and $null -eq $script:ParkRun -and $script:LastStatus -match 'tout le domaine') ('Releve lance : '+$script:LastStatus)
    # Choosing another OU in the tree brings the chip back to that OU.
    Set-SelectedBranch ([pscustomobject]@{Tag=[pscustomobject]@{DN='OU=Lyon,DC=example,DC=invalid'}})
    Expect ($script:Ctrl.CmbWorkViewScope.SelectedIndex -eq 0 -and [string]$script:Ctrl.CmbWorkViewScope.Items[0].Content -eq 'Vues dans : Lyon' -and -not $script:ListSurveyBlocked) 'La puce ne suit pas lʼOU choisie.'
    $script:SearchListHasMachine=$true
    Update-DomeniaSearchActionStates
    Expect ($script:Ctrl.BtnParkResults.IsEnabled) 'Le releve reste refuse sur une liste dʼOU.'
    # DS-07: on the root with its sub-OU, the chip does not offer the same whole domain twice.
    $script:SelectedBranchDn=$script:Conn.BaseDn;$script:Ctrl.ChkSubtree.IsChecked=$true;Update-DomeniaSearchScopeUi
    Expect ($script:Ctrl.CmbWorkViewScope.Items[1].Visibility -eq 'Collapsed' -and [string]$script:Ctrl.CmbWorkViewScope.Items[0].Content -eq 'Vues dans : tout le domaine') 'Deux entrees disent tout le domaine a la racine.'
    $script:Ctrl.ChkSubtree.IsChecked=$false;Update-DomeniaSearchScopeUi
    Expect ($script:Ctrl.CmbWorkViewScope.Items[1].Visibility -eq 'Visible') 'Le domaine entier manque sous la racine sans sous-OU.'
}
# Unwired if Set-SelectedBranch reads the OU at each arrow key (one request per node walked), if the tree no longer
# records whether the keyboard or the mouse drives it, or if Wire-Events sends a change of type without the pause.
Case 'PF-14 Parcours clavier temporise (300 ms) sans requete par noeud, souris immediate' {
    Initialize-DomeniaSearchUi
    . ([scriptblock]::Create($script:TypeWiring))
    Send-TreeKey $script:Ctrl.TvDirectory
    Expect ((Get-DomeniaTreeSelectionSource) -eq 'Keyboard') 'Le clavier de lʼarbre nʼest pas pris en compte.'
    foreach($dn in @('OU=A,DC=example,DC=invalid','OU=B,DC=example,DC=invalid','OU=C,DC=example,DC=invalid')){Set-SelectedBranch ([pscustomobject]@{Tag=[pscustomobject]@{DN=$dn}})}
    Expect ((Get-TaskCount 'GlobalSearch') -eq 0) 'Une requete par noeud parcouru au clavier.'
    Expect ($null -ne $script:PendingFilterChange -and $script:PendingFilterChange.Dn -eq 'OU=C,DC=example,DC=invalid' -and $script:FilterChangeTimer.Interval.TotalMilliseconds -eq 300 -and $script:FilterChangeTimer.IsEnabled) 'Temporisation absente.'
    Invoke-DomeniaPendingFilterChange
    $t=Get-LastTask 'GlobalSearch'
    Expect ((Get-TaskCount 'GlobalSearch') -eq 1 -and $t.Payload.BaseDn -eq 'OU=C,DC=example,DC=invalid') 'Seul le dernier arret doit etre lu.'
    Expect ($script:FleetScopes.Count -gt 0 -and $script:FleetScopes[$script:FleetScopes.Count-1] -eq 'OU=C,DC=example,DC=invalid') 'LʼAccueil ne suit pas lʼOU choisie.'
    # The real handler of the object type: the change waits for its pause, then the chosen type is read.
    $script:Ctrl.CmbGlobalType.SelectedIndex=3
    Expect ((Get-TaskCount 'GlobalSearch') -eq 1 -and $null -ne $script:PendingFilterChange -and $script:PendingFilterChange.Source -eq 'Type') 'Un changement de type part sans pause.'
    Invoke-DomeniaPendingFilterChange
    Expect ((Get-TaskCount 'GlobalSearch') -eq 2 -and [string](Get-LastTask 'GlobalSearch').CallbackState.TypeFilter -ceq (Get-TypeLdapFilter 'Groupes')) 'Le type choisi nʼest pas lu apres la pause.'
    Send-TreeMouse $script:Ctrl.TvDirectory
    Expect ((Get-DomeniaTreeSelectionSource) -eq 'Mouse') 'La souris de lʼarbre nʼest pas prise en compte.'
    Set-SelectedBranch ([pscustomobject]@{Tag=[pscustomobject]@{DN='OU=D,DC=example,DC=invalid'}})
    Expect ((Get-TaskCount 'GlobalSearch') -eq 3 -and (Get-LastTask 'GlobalSearch').Payload.BaseDn -eq 'OU=D,DC=example,DC=invalid' -and $null -eq $script:PendingFilterChange) 'Un clic souris doit lire tout de suite, et annuler la pause.'
    Invoke-DomeniaPendingFilterChange
    Expect ((Get-TaskCount 'GlobalSearch') -eq 3) 'Une lecture differee perimee est partie.'
}
# Unwired if the former saved searches are not taken over, or taken over at every start.
Case 'FO-04 Favoris repris une fois de SavedSearches, donnees conservees' {
    $old=@([pscustomobject]@{SearchMode='OU';Name='Postes : PC';DN='OU=Postes,DC=example,DC=invalid';Query='PC';Type='Machines';Limit=100;Subtree=$false},[pscustomobject]@{SearchMode='Global';Name='Domaine entier : dupont';DN='DC=example,DC=invalid';Query='dupont';Type='Tous';Limit=100;Subtree=$true})
    $script:Settings['SavedSearches']=$old
    Update-DomeniaOuFavouritesUi
    $favs=@(Get-DomeniaFavouriteSearches)
    Expect ($favs.Count -eq 1 -and $favs[0].DN -eq 'OU=Postes,DC=example,DC=invalid' -and $favs[0].Term -eq 'PC' -and -not $favs[0].Subtree -and $favs[0].Type -eq 'Machines') ('Favoris : '+($favs|ConvertTo-Json -Compress))
    Expect ([bool]$script:Settings['OuFavouritesImported'] -and [object]::ReferenceEquals($script:Settings['SavedSearches'],$old) -and @($script:Settings['SavedSearches']).Count -eq 2) 'Les recherches enregistrees ont ete modifiees.'
    Expect ($script:Ctrl.UxOuFavourites.Visibility -eq 'Visible' -and $script:Ctrl.PnlOuFavourites.Children.Count -eq 1) 'Section Favoris absente en haut de lʼarbre.'
    [void](Remove-DomeniaFavouriteSearch -Dn 'OU=Postes,DC=example,DC=invalid')
    Update-DomeniaOuFavouritesUi
    Expect (@(Get-DomeniaFavouriteSearches).Count -eq 0) 'La reprise a ete rejouee : un favori retire revient.'
    $root=New-TreeItem -Name 'OU  Lyon' -Dn 'OU=Lyon,DC=example,DC=invalid' -Kind 'OU';[void]$script:Ctrl.TvDirectory.Items.Add($root)
    [void](Save-DomeniaFavouriteSearch -Dn 'OU=Lyon,DC=example,DC=invalid' -Toggle)
    Expect ([string][Windows.Automation.AutomationProperties]::GetItemStatus($root) -eq 'Favori' -and $null -ne $root.HeaderTemplate) 'Lʼetoile de la branche ne suit pas le favori.'
    Expect ((Get-TaskCount @('GlobalSearch','TreeChildren','OpenAdObject')) -eq 0) 'Un favori a lu lʼannuaire sans geste.'
}
# Unwired if a favourite fills the hidden OU field again: the list is filtered by a term nobody sees.
Case 'CO-21 Un favori ne remplit plus de champ cache : son terme va au filtre local visible' {
    Write-DomeniaOuFavouriteStore -Favourites @([pscustomobject]@{DN='OU=Lyon,DC=example,DC=invalid';Name='Lyon';Subtree=$true;Type='Groupes';Term='compta'})
    $script:Ctrl.TxtBranchSearch.Text='ancien'
    Load-DomeniaFavouriteSearch -Dn 'OU=Lyon,DC=example,DC=invalid'
    $t=Get-LastTask 'GlobalSearch'
    Expect ($script:Ctrl.TxtBranchSearch.Text -eq '' -and $script:Ctrl.TxtSuiteResultFilter.Text -eq 'compta') ('Champs : cache='+$script:Ctrl.TxtBranchSearch.Text+' visible='+$script:Ctrl.TxtSuiteResultFilter.Text)
    Expect ($null -ne $t -and $t.CallbackState.Search -eq '' -and $t.Payload.BaseDn -eq 'OU=Lyon,DC=example,DC=invalid' -and $t.Payload.Scope -eq 'Subtree') 'La recherche porte un terme invisible ou un autre perimetre.'
    Expect ([string]$script:Ctrl.CmbGlobalType.SelectedItem.Content -eq 'Groupes' -and -not ([string]$script:Ctrl.LblSearchScope.Text).Contains('Terme')) ('Portee : '+$script:Ctrl.LblSearchScope.Text)
    Expect (([string]$script:Ctrl.LblSearchHint.Text).Contains('compta') -and ([string]$script:Ctrl.LblSearchHint.Text).Contains('lignes lues seulement')) ('Le filtre local nʼest pas annonce : '+$script:Ctrl.LblSearchHint.Text)
}
# Unwired if the root rows are added as they come, if a branch read without sub-branch keeps its fake child, or if
# the worker probes every sub-branch again (more than one directory request per unfold).
Case 'UI-16 Conteneurs systeme regroupes, chevron retire apres lecture sans sous-OU, noeud jamais grise' {
    $root=New-TreeItem -Name 'example.invalid' -Dn $script:Conn.BaseDn -Kind 'domainDNS';[void]$script:Ctrl.TvDirectory.Items.Add($root)
    $rows=@(
        [pscustomobject]@{Name='Computers';DN='CN=Computers,DC=example,DC=invalid';Kind='Conteneur'}
        [pscustomobject]@{Name='Postes';DN='OU=Postes,DC=example,DC=invalid';Kind='OU'}
        [pscustomobject]@{Name='Program Data';DN='CN=Program Data,DC=example,DC=invalid';Kind='Conteneur'}
        [pscustomobject]@{Name='Serveurs';DN='OU=Serveurs,DC=example,DC=invalid';Kind='OU'}
        [pscustomobject]@{Name='System';DN='CN=System,DC=example,DC=invalid';Kind='Conteneur'}
        [pscustomobject]@{Name='Users';DN='CN=Users,DC=example,DC=invalid';Kind='Conteneur'}
    )
    $root.Items.Clear();$count=Add-DomeniaTreeRowsToNode -Node $root -Rows $rows
    $items=@($root.Items)
    Expect ($count -eq 6 -and $items.Count -eq 5) ('Noeuds : '+$items.Count)
    Expect ((@($items|ForEach-Object{[string]$_.Header}) -join '|') -eq 'CN  Computers|OU  Postes|OU  Serveurs|CN  Users|Conteneurs système (2)') ('Ordre : '+(@($items|ForEach-Object{[string]$_.Header}) -join '|'))
    $group=$items[4];Expect ([string]$group.Tag.DN -eq '' -and -not $group.IsExpanded -and $group.Items.Count -eq 2) 'Groupe systeme incorrect.'
    Expect (@($items[0..3]|Where-Object{$_.Items.Count -ne 1 -or [bool]$_.Tag.Loaded}).Count -eq 0) 'Une branche non lue doit garder son chevron jusquʼa sa lecture.'
    # One unfold, one request: the node is never greyed and a second unfold during the read starts nothing.
    $postes=$items[1]
    Load-TreeChildren -Node $postes;Load-TreeChildren -Node $postes
    $task=Get-LastTask 'TreeChildren'
    Expect ((Get-TaskCount 'TreeChildren') -eq 1 -and $postes.IsEnabled -and [string]$postes.Items[0].Tag -eq 'Loading') 'Noeud grise ou double lecture.'
    Expect ([regex]::Matches([string]$task.Code,'\.Find(All|One)\(').Count -eq 1 -and $null -eq $task.Payload.PSObject.Properties['ProbeMax']) 'Le worker sonde chaque sous-branche : plusieurs requetes par depliage.'
    Queue-DomeniaTreeRowsToNode -Node $postes -Rows @() -DisplayName 'Postes'
    Expect ($postes.Items.Count -eq 0 -and [bool]$postes.Tag.Loaded -and -not [bool]$postes.Tag.Loading -and $postes.IsEnabled) 'Branche lue sans enfant : le chevron reste.'
    Queue-DomeniaTreeRowsToNode -Node $root -Rows $rows -DisplayName 'example.invalid'
    $job=@($script:TreeRenderJobs.Values)[0]
    Expect ($root.IsEnabled -and $null -ne $job -and @($job.Rows).Count -eq 5 -and [string]@($job.Rows)[4].Kind -eq 'SystemGroup') 'Affichage progressif sans regroupement, ou racine grisee.'
    Expect ((Get-TaskCount 'GlobalSearch') -eq 0) 'Le regroupement a lance une recherche.'
}
# Unwired if the OU filter reads the directory or unfolds a branch never read.
Case 'DS-07 Filtrer les OU : local, sans lecture ni depliage dʼune branche non lue' {
    $root=New-TreeItem -Name 'example.invalid' -Dn $script:Conn.BaseDn -Kind 'domainDNS';[void]$script:Ctrl.TvDirectory.Items.Add($root)
    $root.Items.Clear();[void](Add-DomeniaTreeRowsToNode -Node $root -Rows @([pscustomobject]@{Name='Comptabilité';DN='OU=Comptabilite,DC=example,DC=invalid';Kind='OU'},[pscustomobject]@{Name='Postes';DN='OU=Postes,DC=example,DC=invalid';Kind='OU'}))
    $root.Tag.Loaded=$true
    $script:Ctrl.TxtOuFilter.Text='compta';Update-DomeniaOuTreeFilter
    $items=@($root.Items)
    Expect ($root.Visibility -eq 'Visible' -and $items[0].Visibility -eq 'Visible' -and $items[1].Visibility -eq 'Collapsed') 'Filtre des OU incorrect.'
    Expect (-not $items[0].IsExpanded -and (Get-TaskCount @('TreeChildren','GlobalSearch')) -eq 0) 'Le filtre a lu lʼannuaire ou deplie une branche non lue.'
    Expect (([string]$script:Ctrl.LblTreeStatus.Text).Contains('compta')) ('Statut du filtre : '+$script:Ctrl.LblTreeStatus.Text)
    $script:Ctrl.TxtOuFilter.Text='';Update-DomeniaOuTreeFilter
    Expect ($items[1].Visibility -eq 'Visible') 'Effacer le filtre ne reaffiche pas tout.'
    Expect (-not ([string]$script:Ctrl.LblTreeStatus.Text).Contains('compta')) ('Le statut decrit un filtre efface : '+$script:Ctrl.LblTreeStatus.Text)
}
# Unwired if the default comes back to true: the listed objects are reread in AD without any gesture.
Case 'SE-13 RevalidateListedObjects faux par defaut : aucune lecture AD sans geste' {
    function Test-DomeniaBackgroundWorkAllowed {param([string]$Source) return $true}
    Expect (-not [bool](New-DefaultConfig).Streaming.RevalidateListedObjects) 'Defaut de configuration vrai.'
    $script:Ctrl.DgObjects=[pscustomobject]@{IsEnabled=$true;IsVisible=$true;ItemsSource=$null;SelectedIndex=-1;SelectedItem=$null;SelectedItems=@();Items=@()}
    Invoke-GlobalSearch -SearchMode OU
    $s=$script:Live.Search
    $row=New-DomeniaLiveResultRow;$row.Type='Machine';$row.Name='PC-01';$row.DN='CN=PC-01,OU=Postes,DC=example,DC=invalid';$row.Guid='33333333-3333-3333-3333-333333333333'
    [void]$s.Rows.Add($row);$s.Map['cn=pc-01,ou=postes,dc=example,dc=invalid']=$row;$s.Finalized=$true;$s.Error=''
    Start-Continuity
    Expect ($script:Ctrl.UxListRevalidation.Visibility -eq 'Collapsed') 'Interrupteur affiche alors que la revalidation est coupee.'
    Invoke-DomeniaObjectChanges;$script:Continuity.ChangeNext=[datetime]::MinValue;Invoke-DomeniaObjectChanges
    Expect ((Get-TaskCount 'LiveDirectoryCheck') -eq 0) 'Revalidation de fond lancee sans geste.'
    # Enabled by an administrator: the switch shows, stops it for the session, and the page says when it checked.
    $script:CfgOverrides['Streaming/RevalidateListedObjects']=$true
    Update-DomeniaListRevalidationUi
    Expect ($script:Ctrl.UxListRevalidation.Visibility -eq 'Visible' -and $script:Ctrl.LblListRevalidation.Text -eq 'Liste non encore revérifiée') ('Libelle : '+$script:Ctrl.LblListRevalidation.Text)
    $script:Ctrl.ChkListRevalidation.IsChecked=$false
    $script:Continuity.ChangeNext=[datetime]::MinValue;Invoke-DomeniaObjectChanges
    Expect ((Get-TaskCount 'LiveDirectoryCheck') -eq 0 -and $script:Ctrl.LblListRevalidation.Text -match 'arrêtée') 'Lʼinterrupteur nʼarrete pas la revalidation.'
    $script:Ctrl.ChkListRevalidation.IsChecked=$true
    $script:Continuity.ChangeNext=[datetime]::MinValue;Invoke-DomeniaObjectChanges
    $check=Get-LastTask 'LiveDirectoryCheck'
    Expect ($null -ne $check) 'Revalidation activee non lancee.'
    [void]$script:AsyncJobs.Remove([string]$check.Id)
    Complete-DomeniaObjectChanges -Result ([pscustomobject]@{Rows=@();Server='dc.example.invalid'}) -State $check.CallbackState
    Expect ($script:Ctrl.LblListRevalidation.Text -match '^Liste vérifiée à \d\d:\d\d$') ('Libelle : '+$script:Ctrl.LblListRevalidation.Text)
}
# Unwired if 'Relire l objet' empties the whole cache or reloads the list.
Case 'FI-21 Relire lʼobjet invalide seulement son GUID et ne relance pas la liste' {
    $guid='11111111-1111-1111-1111-111111111111'
    $script:SelectedObject=[pscustomobject]@{DN='CN=Alex,OU=Lyon,DC=example,DC=invalid';Type='Utilisateur';Name='Alex';Safety=[pscustomobject]@{Guid=$guid}}
    $script:VisitCache=@{}
    $script:VisitCache['cache-v3|example.invalid|'+$guid+'|hash|dc1||Object|object']='obj'
    $script:VisitCache['cache-v3|example.invalid|'+$guid.Replace('-','')+'|groups']='groupes'
    $script:VisitCache['cache-v3|example.invalid|22222222-2222-2222-2222-222222222222|hash|dc1||Object|object']='autre'
    $script:VisitCache['scope-v214|OU|dc|ou=lyon,dc=example,dc=invalid|Subtree|x||100']='liste'
    $before=Get-TaskCount 'GlobalSearch'
    Refresh-SelectedObject
    Expect ($script:VisitCache.Count -eq 2 -and $script:VisitCache.ContainsKey('cache-v3|example.invalid|22222222-2222-2222-2222-222222222222|hash|dc1||Object|object') -and $script:VisitCache.ContainsKey('scope-v214|OU|dc|ou=lyon,dc=example,dc=invalid|Subtree|x||100')) ('Cles restantes : '+(@($script:VisitCache.Keys) -join ' ; '))
    Expect ((Get-TaskCount 'GlobalSearch') -eq $before) 'La liste a ete relancee.'
    Expect ((Get-TaskCount 'OpenAdObject') -eq 1) 'La fiche nʼa pas ete relue.'
}
# Unwired if the restored list does not say it comes from the history, if the banner follows the grid instead of the
# list (a local filter repaints the grid), or if the list being left is recorded with the type or the local filter
# that the launching gesture (type change, favourite) already put in the controls.
Case 'UX-25 Liste de lʼhistorique : bandeau, Actualiser, type, presence et filtre local memorises' {
    Initialize-DomeniaSearchUi
    . ([scriptblock]::Create($script:TypeWiring))
    $script:Ctrl.TxtSuiteResultFilter.Text='PC'
    Invoke-GlobalSearch -SearchMode OU;$first=Get-LastTask 'GlobalSearch'
    Feed-Live (New-ResultRow 'PC-01' 'pc01' 'Machine' '' 'OU=Postes');Finish-Live $first $false
    $firstRows=$script:Ctrl.DgObjects.ItemsSource
    $script:Ctrl.DgObjects.SelectedItem=@($script:Ctrl.DgObjects.Items)[0]
    # The type change really launches the next list, after its pause.
    $script:Ctrl.CmbGlobalType.SelectedIndex=3
    Invoke-DomeniaPendingFilterChange
    $second=Get-LastTask 'GlobalSearch'
    Expect (-not [object]::ReferenceEquals($second,$first) -and [string]$second.CallbackState.TypeFilter -ceq (Get-TypeLdapFilter 'Groupes')) 'Le changement de type ne relance pas la liste.'
    Feed-Live (New-ResultRow 'G-Compta' 'gcompta' 'Groupe' '' 'OU=Postes');Finish-Live $second $false
    Expect ($script:Ctrl.UxHistoryBanner.Visibility -eq 'Collapsed') 'Bandeau affiche sur une liste suivie.'
    # A favourite changes the type and the local filter before its own search.
    $script:Ctrl.TxtSuiteResultFilter.Text='G'
    Write-DomeniaOuFavouriteStore -Favourites @([pscustomobject]@{DN='OU=Lyon,DC=example,DC=invalid';Name='Lyon';Subtree=$true;Type='Utilisateurs';Term='compta'})
    Load-DomeniaFavouriteSearch -Dn 'OU=Lyon,DC=example,DC=invalid'
    $third=Get-LastTask 'GlobalSearch'
    Expect ($third.Payload.BaseDn -eq 'OU=Lyon,DC=example,DC=invalid' -and -not [bool]$script:NavSearchLaunching) 'Favori non lance, ou lancement laisse ouvert.'
    Feed-Live (New-ResultRow 'Alice Compta' 'acompta' 'Utilisateur' '' 'OU=Lyon');Finish-Live $third $false
    $tasks=$script:Tasks.Count
    [void](Invoke-DomeniaNavStep -Direction Back)
    Expect ($script:SelectedBranchDn -eq 'OU=Postes,DC=example,DC=invalid' -and [string]$script:Ctrl.CmbGlobalType.SelectedItem.Content -eq 'Groupes' -and $script:Ctrl.TxtSuiteResultFilter.Text -eq 'G') ('Liste quittee par le favori : type='+[string]$script:Ctrl.CmbGlobalType.SelectedItem.Content+' local='+$script:Ctrl.TxtSuiteResultFilter.Text)
    [void](Invoke-DomeniaNavStep -Direction Back)
    Expect ([object]::ReferenceEquals($script:Ctrl.DgObjects.ItemsSource,$firstRows) -and $script:Tasks.Count -eq $tasks -and $null -eq $script:PendingFilterChange) 'Liste non restituee, relue, ou lecture differee lancee.'
    Expect ($script:Ctrl.UxHistoryBanner.Visibility -eq 'Visible') 'Bandeau Liste de lʼhistorique absent.'
    Expect ([string]$script:Ctrl.CmbGlobalType.SelectedItem.Content -eq 'Machines' -and $script:Ctrl.TxtSuiteResultFilter.Text -eq 'PC' -and $script:Ctrl.TxtBranchSearch.Text -eq '') ('Liste quittee par le type : type='+[string]$script:Ctrl.CmbGlobalType.SelectedItem.Content+' local='+$script:Ctrl.TxtSuiteResultFilter.Text)
    # The local filter repaints the grid with a filtered copy: the list is still the history list.
    $script:Ctrl.TxtSuiteResultFilter.Text='PC-0';Apply-DomeniaPresenceFilter
    Expect (-not [object]::ReferenceEquals($script:Ctrl.DgObjects.ItemsSource,$firstRows) -and $script:Ctrl.UxHistoryBanner.Visibility -eq 'Visible' -and (Test-DomeniaHistoryListShown)) 'Le bandeau disparait au filtre local.'
    $script:Ctrl.DgObjects.SelectedItem=@($script:Ctrl.DgObjects.Items)[0]
    Select-DomeniaLiveResult
    Expect ($script:LastStatus -match 'historique' -and $script:Tasks.Count -eq $tasks) ('Clic sur une liste de lʼhistorique : '+$script:LastStatus)
    $searches=Get-TaskCount 'GlobalSearch'
    Invoke-DomeniaHistoryRefresh
    $again=Get-LastTask 'GlobalSearch'
    Expect ((Get-TaskCount 'GlobalSearch') -eq ($searches+1) -and $again.CallbackState.SearchMode -eq 'OU' -and $again.Payload.BaseDn -eq 'OU=Postes,DC=example,DC=invalid' -and [string]$again.CallbackState.TypeFilter -ceq (Get-TypeLdapFilter 'Machines')) 'Actualiser ne relit pas la meme liste.'
    Expect ((Get-TaskCount @('ComputerPing','LiveSelectedPing','LiveConsole','PresenceScan','ParkSweep')) -eq 0) 'Actualiser a lance un ping ou un releve.'
    Expect ($script:Ctrl.UxHistoryBanner.Visibility -eq 'Collapsed') 'Bandeau toujours affiche apres Actualiser.'
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
        # UX-33: a waiting entry 'Vues prêtes…' comes first and is selected; it starts nothing.
        Expect ($script:Ctrl.CmbWorkView.Items.Count -eq (@(Get-DomeniaWorkViews).Count + 1) -and -not $script:Ctrl.BtnNavBack.IsEnabled)
        Expect ($script:Ctrl.CmbWorkView.SelectedIndex -eq 0 -and [string]$script:Ctrl.CmbWorkView.SelectedItem.Tag -eq '' -and ([string]$script:Ctrl.CmbWorkView.SelectedItem.Content).StartsWith('Vues prêtes')) 'Texte dʼattente des vues absent.'
        # DS-07: the tree fills the OU column; filter, header menu and favourites above it; the former scope card is gone.
        foreach($n in @('TxtOuFilter','BtnOuMenu','UxOuMenuPanel','PnlOuFavourites','UxOuFavourites','BtnOuFavouriteToggle','CmbWorkViewScope','UxHistoryBanner','BtnHistoryRefresh','ChkListRevalidation','LblListRevalidation','UxListRevalidation')){Expect ($null -ne $window.FindName($n)) ('Controle L03 absent : '+$n)}
        foreach($n in @('BtnSearchInOu','UxOuScopeCard','LblOuScopeName','LblOuScopePath','UxOuIntro','LstGuardSearches','BtnGuardSaveSearch','BtnGuardLoadSearch')){Expect ($null -eq $window.FindName($n)) ('Controle retire encore present : '+$n)}
        $tree=$window.FindName('TvDirectory');$dock=$tree.Parent
        Expect ($dock -is [Windows.Controls.DockPanel] -and [object]::ReferenceEquals($dock.Children[$dock.Children.Count-1],$tree) -and $dock.LastChildFill) 'Lʼarbre nʼoccupe pas toute la hauteur restante.'
        Expect ($window.FindName('UxOuMenuPanel').Visibility -eq 'Collapsed' -and $window.FindName('UxHistoryBanner').Visibility -eq 'Collapsed' -and $window.FindName('UxListRevalidation').Visibility -eq 'Collapsed') 'Un panneau L03 est ouvert par defaut.'
        foreach($n in @('ChkSubtree','BtnSearchAllDomain','UxOuPathDetails','BtnOuFavouriteToggle')){
            $parent=$window.FindName($n);$inMenu=$false
            while($null -ne $parent){if([object]::ReferenceEquals($parent,$window.FindName('UxOuMenuPanel'))){$inMenu=$true;break};$parent=[Windows.LogicalTreeHelper]::GetParent($parent)}
            Expect $inMenu ('Hors du menu dʼen-tete : '+$n)
        }
        Expect ($window.FindName('CmbWorkViewScope').SelectedIndex -eq 0 -and [string]$window.FindName('CmbWorkViewScope').Items[1].Tag -eq 'Domain') 'La vue ne sʼapplique pas a lʼOU par defaut.'
        $script:Ctrl.BtnOuMenu.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Expect ($window.FindName('UxOuMenuPanel').Visibility -eq 'Visible' -and $script:Tasks.Count -eq 0) 'Le menu ne sʼouvre pas, ou lance une lecture.'
    }finally{$reader.Close();if($null -ne $window){$window.Close()}}
}

if($null -ne $script:Live -and $null -ne $script:Live.Timer){$script:Live.Timer.Stop()}
if($null -ne $script:Continuity -and $null -ne $script:Continuity.Timer){$script:Continuity.Timer.Stop()}
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-recherche-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{
    Kind='Wiring';Lot='recherche';Points=@('D012','D031','D032','D033','D034','D035','D036','D037','D038','D039','D040','CO-20','CO-21','DS-07','FI-21','FO-04','PF-14','SE-13','UI-16','UX-25','UX-33')
    Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell51=$native;Wpf=$true;LiveAD=$false;LiveCIM=$false;LivePing=$false
    Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0)
    Limitation='Raccordement prouve par les vraies fonctions et de vrais controles WPF, reseau double. Ne prouve pas un acces a un domaine reel.'
    Tests=$script:Checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed reussi(s), $failed en echec. Rapport : "+$ReportPath);$script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
