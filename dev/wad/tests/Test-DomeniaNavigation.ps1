#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet,[string]$Filter='')
# W08, navigation lot (points 52 to 60): breadcrumb, OU labels, tree filter, exact history, search workspace (saved
# views, filter chips, collective scope, side preview, comparison) and the shared OU picker. Real modules are
# dot-sourced, core functions are extracted by AST and real WPF controls are used. Directory, workstations, SQLite,
# clipboard and dialogs are explicit doubles: no LDAP, CIM, ping, file or clipboard write.
# Each case fails when the wiring it names is removed (see the comment above each case).
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
# PF-24 (lot Z04): a catalogued control carries its help in Domenia-UX.help.json only (the XAML keeps it for the
# other controls); this reads the effective tool tip or help text of a node of the main XAML.
$script:TestHelpCatalogue=$null
function Get-TestCatalogueHelp {
    param($Node,[string]$Attribute)
    $value=[string]$Node.GetAttribute($Attribute)
    if($value){return $value}
    if($null -eq $script:TestHelpCatalogue){
        $script:TestHelpCatalogue=@{}
        $catalogue=Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules') 'Domenia-UX.help.json'
        # PowerShell 5.1 emits a JSON array as one pipeline object: assign it before enumeration.
        $entries=[IO.File]::ReadAllText($catalogue,[Text.Encoding]::UTF8)|ConvertFrom-Json
        foreach($entry in $entries){$script:TestHelpCatalogue[[string]$entry.Name]=$entry}
    }
    $name=[string]$Node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
    if($script:TestHelpCatalogue.ContainsKey($name)){return [string]$script:TestHelpCatalogue[$name].Text}
    return ''
}
$edition=if($PSVersionTable.ContainsKey('PSEdition')){[string]$PSVersionTable.PSEdition}else{'Desktop'}
$native=($env:OS -eq 'Windows_NT' -and $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
if(-not $native){throw 'Windows PowerShell 5.1 requis : une autre execution ne vaut pas preuve.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Utiliser powershell.exe -STA.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
. (Join-Path $modules 'Domenia-DirectoryTree.UI.ps1')
Add-DomeniaDirectoryTreeTypes
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Ok,[string]$Reason='Assertion fausse');if(-not $Ok){throw $Reason}}
function Case {param([string]$Name,[scriptblock]$Body)
    if($Filter -and $Name -notmatch $Filter -and $Name -ne 'Suite interrompue'){return}
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
if($null -eq ('Domenia.Live.ResultRow' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia-Live.Types.cs') -ErrorAction Stop}

# Real application code.
$coreNames=@('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSearchMode','Set-DomeniaSearchMode','Get-DomeniaSearchText','Export-CurrentResults','Get-DomeniaGridExportColumns','Get-DomeniaSelectedGridRows','Get-DomeniaEffectiveWorkerResult')
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $wad 'Domenia-Core.ps1') $coreNames)))
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Experience.Model.ps1','Domenia-Continuity.Model.ps1','Domenia-SearchWorkspace.Model.ps1','Domenia-Continuity.UI.ps1','Domenia-Search.UI.ps1','Domenia-SearchWorkspace.UI.ps1','Domenia-Embedded.UI.ps1')){
    . (Join-Path $modules $file)
}
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-UX.UI.ps1') @('Get-DomeniaUxOuDisplay','Update-DomeniaUxOuScope','Copy-DomeniaUxOuPath'))))
# X01 (UI-23, FO-18) with point 60: « Vérifier la liste ▾ », the surveys of the selection and the export columns (DS-20).
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Park.UI.ps1') @('Invoke-DomeniaParkVerify','Start-DomeniaParkSelectionSurvey','Get-DomeniaParkSelectionTargets','Start-DomeniaParkAnalysis','Test-DomeniaParkListStoppable','Get-DomeniaParkVerifyButtonText'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Park.Model.ps1') @('Get-DomeniaParkVerifyModes'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Shell.Model.ps1') @('Expand-DomeniaResultExportColumns'))))
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Guard.UI.ps1') @('Read-DomeniaOuFavouriteStore','Write-DomeniaOuFavouriteStore','Import-DomeniaFavouriteSearchesOnce','Get-DomeniaFavouriteSearches','Update-DomeniaOuFavouritesUi'))))

# Explicit doubles: none reaches a directory, a workstation, the network, the database, the clipboard or a window.
function Get-CfgValue {param($Section,$Name,$Default) return $Default}
function Test-DomeniaAccessBusyWrite {return [bool]$script:WriteBlocked}
function Test-DomeniaDraftNavigation {param($DN,[switch]$Refresh) return $true}
function Get-DomeniaDirtyFields {return @()}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level='INFO') $script:LastStatus=[string]$Text;$script:LastStatusLevel=[string]$Level}
function Get-DomeniaSetting {param($Name,$Default) if($script:Settings.ContainsKey([string]$Name)){return $script:Settings[[string]$Name]};return $Default}
function Set-DomeniaSetting {param($Name,$Value) $script:Settings[[string]$Name]=$Value}
function Save-DomeniaSettings {param([switch]$Immediate,[switch]$ThrowOnFailure) if($script:SaveFails -and $ThrowOnFailure){throw 'Disque indisponible (double).'};$script:Saves++}
function Invoke-GlobalSearch {param([string]$SearchMode='',[string]$ViewId='',[switch]$SilentError,[switch]$AllowEmpty,[string]$ViewScope='') $script:Searches.Add([pscustomobject]@{Mode=$SearchMode;Dn=[string]$script:SelectedBranchDn;ViewId=$ViewId})}
function Start-DomeniaFavouriteTreeReveal {param([string]$Dn) $script:Reveals.Add($Dn)}
function Update-DomeniaSearchScopeUi { $script:ScopeUpdates++ }
function Set-DomeniaContextHint {param($Title,$Text) $script:Hint=[string]$Text}
function Invalidate-DomeniaSearchResults {param([switch]$KeepSelection) $script:Invalidations++}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab) $script:Workspace=[string]$Workspace}
function Update-DomeniaLoginColumnFromRows {param($Rows)}
function Update-Dashboard { }
function New-DomeniaTimer {param([string]$Owner,[int]$IntervalMs,[scriptblock]$Tick,[switch]$Standalone,[string]$Priority='Background',[int]$IdleIntervalMs=0,[switch]$SessionBound)
    $timer=[pscustomobject]@{Owner=$Owner;Tick=$Tick;IsEnabled=$false;Interval=[TimeSpan]::FromMilliseconds($IntervalMs)}
    $timer|Add-Member -MemberType ScriptMethod -Name Start -Value {$this.IsEnabled=$true}
    $timer|Add-Member -MemberType ScriptMethod -Name Stop -Value {$this.IsEnabled=$false}
    $script:Timers.Add($timer)
    return $timer
}

function Show-DomeniaFormDialog {param($Title,$Message,$Fields,$AcceptText) return [pscustomobject]@{Name=[string]$script:FormName}}
function Test-DomeniaLiveSearchActive {return $false}
function Reset-DomeniaLiveIdentity { }
function Apply-DomeniaPresenceFilter { $script:PresenceFilters++ }
function Update-DomeniaSearchMoreButton {param($Search)}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,$TaskClass) $script:Tasks++;$script:UiTasks.Add([pscustomobject]@{OperationId=[string]$OperationId;Payload=$Payload;State=$CallbackState});return ('task-'+$script:Tasks)}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason)}
function Test-DomeniaEmbeddedHost {return $true}
function New-DomeniaStoreContext {param([string]$RequestId) return [pscustomobject]@{RequestId=$RequestId;StoreId='store-fixture';Path=[string]$script:DatabaseScopedPath;DomainDn='DC=example,DC=invalid'}}
function Request-DomeniaStoreRead {param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState) $script:StoreReads.Add([pscustomobject]@{Context=$Context;Query=$Query;SuccessHandler=$SuccessHandler;CallbackState=$CallbackState});return ('read-'+$script:StoreReads.Count)}
function Show-DomeniaEmbeddedWindow {param($Window) $script:Embedded++;if($null -ne $script:OnEmbedded){return (& $script:OnEmbedded $Window)};return $true}
function Start-DomeniaOnlinePark {param([switch]$DisplayedResults,[switch]$Selection,[switch]$PingOnly,[switch]$WmiOnly,[switch]$PingBeforeWmi,[switch]$Inventory,[object[]]$ScopeTargets=$null,[string]$ScopeLabel='',[object[]]$Probes=$null,[int]$SkippedTargets=0)
    $script:ParkCalls.Add([pscustomobject]@{Kind=$(if($Inventory){'Analyse'}elseif($PingBeforeWmi){'Console'}elseif($PingOnly){'Ping'}else{'Console'});Displayed=[bool]$DisplayedResults;Selection=[bool]$Selection;PingOnly=[bool]$PingOnly;Targets=$ScopeTargets;Skipped=$SkippedTargets})
}
function Get-DomeniaParkRun {param([string]$Slot='List') return $null}
function Update-DomeniaParkControls { $script:ParkControlUpdates++ }
function Open-DomeniaParkVerifyMenu {param($Anchor) $script:ParkMenus++}
function Get-DomeniaBoardProbeIds {return @()}
function Export-DomeniaCsv {param($Rows,$Columns,$Grid,$Subject) $script:PendingExport=@($Rows);$script:PendingColumns=@($Columns);return [pscustomobject]@{RowCount=@($Rows).Count;Path='C:\DomeniaFixture\export.csv'}}
function Show-DomeniaExportResult {param($Result,[string]$Scope='',[string]$Also='') $script:Exports.Add([pscustomobject]@{Rows=$script:PendingExport;Scope=$Scope;Also=$Also})}
function Get-DomeniaSearchExportSubject {return 'fixture'}
function Show-ErrorBox {param($Text) throw ('Fenêtre dʼerreur : '+[string]$Text)}

function New-FixtureNode {param([string]$Dn,[string]$Name,[bool]$Loaded,[string]$Kind='OU')
    $node=[Domenia.Tree.DomeniaTreeItem]::new()
    $node.Header=$(if($Kind -eq 'SystemGroup'){$Name}elseif($Kind -eq 'OU'){'OU  '+$Name}else{'CN  '+$Name})
    $node.Tag=[pscustomobject]@{Name=$Name;DN=$Dn;Kind=$Kind;Loaded=$Loaded;RenderId='';Loading=$false}
    return $node
}
function New-FixtureRow {param([string]$Name,[string]$Type='Machine',[string]$Guid='',[string]$Ou='OU=Postes')
    $row=[Domenia.Live.ResultRow]::new();$row.Name=$Name;$row.Type=$Type;$row.Guid=$Guid
    $row.DN=$(if($Type -eq 'Machine'){'CN='}else{'CN='})+$Name+','+$Ou+',DC=example,DC=invalid'
    return $row
}
function New-TestControls {
    $c=@{}
    foreach($n in @('TxtGlobalSearch','TxtBranchSearch','TxtGlobalLimit','TxtSuiteResultFilter','TxtBranchDn','TxtOuFilter')){$c[$n]=[Windows.Controls.TextBox]::new()}
    foreach($n in @('LblBranchCount','LblSearchScope','LblSearchHint','LblSearchQuery','LblOuScopeName','LblOuScopePath','LblTreeStatus','LblSearchFilterSummary','LblResultScope','LblSearchPreview','LblSuiteResultCount')){$c[$n]=[Windows.Controls.TextBlock]::new()}
    foreach($n in @('BtnNavBack','BtnNavForward','BtnOuFavouriteToggle','BtnSearchWorkspaceSave','BtnSearchWorkspaceOpen','BtnSearchWorkspaceRemove','BtnSearchWorkspaceUndo','BtnSearchCompare','BtnSearchPreview','BtnSearchPreviewClose')){$c[$n]=[Windows.Controls.Button]::new();$c[$n].Name=$n}
    $c.TxtGlobalLimit.Text='100'
    $c.ChkSubtree=[Windows.Controls.CheckBox]::new();$c.ChkSubtree.IsChecked=$true
    foreach($pair in @(@('CmbGlobalType',@('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')),@('CmbPresenceFilter',@('Tous','En ligne','Sans réponse au ping','Non vérifié','Erreur de ping')))){
        $combo=[Windows.Controls.ComboBox]::new();foreach($t in $pair[1]){$i=[Windows.Controls.ComboBoxItem]::new();$i.Content=$t;[void]$combo.Items.Add($i)};$combo.SelectedIndex=0;$c[$pair[0]]=$combo
    }
    $c.CmbSearchWorkspace=[Windows.Controls.ComboBox]::new()
    $c.CmbResultScope=[Windows.Controls.ComboBox]::new()
    foreach($pair in @(@('Visible','Liste affichée'),@('Selected','Lignes sélectionnées'))){$i=[Windows.Controls.ComboBoxItem]::new();$i.Tag=$pair[0];$i.Content=$pair[1];[void]$c.CmbResultScope.Items.Add($i)};$c.CmbResultScope.SelectedIndex=0
    $c.CmbWorkViewScope=[Windows.Controls.ComboBox]::new()
    $c.SearchBrowserLayout=[Windows.Controls.Grid]::new()
    $c.PnlOuBreadcrumb=[Windows.Controls.WrapPanel]::new()
    $c.PnlSearchFilterChips=[Windows.Controls.WrapPanel]::new()
    $c.PnlOuFavourites=[Windows.Controls.StackPanel]::new()
    foreach($n in @('UxOuFavourites','UxHistoryBanner')){$c[$n]=[Windows.Controls.Border]::new();$c[$n].Visibility='Collapsed'}
    $c.PnlSearchPreview=[Windows.Controls.Grid]::new();$c.PnlSearchPreview.Visibility='Collapsed'
    $c.SearchPreviewSplitter=[Windows.Controls.GridSplitter]::new();$c.SearchPreviewSplitter.Visibility='Collapsed'
    $c.DgSearchPreview=[Windows.Controls.DataGrid]::new()
    $grid=[Windows.Controls.DataGrid]::new();$grid.IsReadOnly=$true;$grid.CanUserAddRows=$false;$grid.AutoGenerateColumns=$false;$grid.SelectionMode='Extended'
    foreach($spec in @(@('Type','Type'),@('Nom','Name'),@('Etat','State'),@('Chemin complet','DN'))){$col=[Windows.Controls.DataGridTextColumn]::new();$col.Header=$spec[0];$col.Binding=[Windows.Data.Binding]::new($spec[1]);$col.SortMemberPath=$spec[1];[void]$grid.Columns.Add($col)}
    # Unshown WPF columns keep DisplayIndex=-1 until layout; provide the visible-grid order.
    for($columnIndex=0;$columnIndex -lt $grid.Columns.Count;$columnIndex++){$grid.Columns[$columnIndex].DisplayIndex=$columnIndex}
    $c.DgObjects=$grid
    $tabs=[Windows.Controls.TabControl]::new()
    foreach($n in @('WsSearch','WsObject')){$t=[Windows.Controls.TabItem]::new();$t.Name=$n;$t.Header=$n;[void]$tabs.Items.Add($t);$c[$n]=$t}
    $tabs.SelectedItem=$c.WsSearch;$c.WorkspaceTabs=$tabs
    $c.TvDirectory=[Windows.Controls.TreeView]::new()
    return $c
}
function Reset-Fixture {
    Stop-DomeniaTreeItemReveal;$script:DomeniaTreeSelectedNode=$null
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server='dc.example.invalid'}
    $script:SessionEpoch=5L;$script:GlobalSearchGeneration=40;$script:SearchMode='OU'
    $script:SelectedBranchDn='OU=Postes,DC=example,DC=invalid';$script:CurrentPresenceFilter='Tous';$script:ActiveSearchViewId=''
    $script:WriteBlocked=$false;$script:AsyncEngineClosing=$false;$script:RestoringSettings=$false;$script:SuppressBranchAutoLoad=$false;$script:SuppressGridSelectionEvents=$false
    $script:Settings=@{};$script:Saves=0;$script:SaveFails=$false;$script:LastStatus='';$script:LastStatusLevel='';$script:Hint=''
    $script:Searches=[Collections.Generic.List[object]]::new();$script:Reveals=[Collections.Generic.List[string]]::new();$script:Timers=[Collections.Generic.List[object]]::new()
    $script:ScopeUpdates=0;$script:Invalidations=0;$script:PresenceFilters=0;$script:Workspace=''
    $script:BranchObjects=@();$script:BranchCountLabel='';$script:Live=$null;$script:LiveSearchTimer=$null;$script:SearchQueryRun=$null;$script:DomeniaQueryState=$null
    $script:NavHistory=$null;$script:NavRestoring=$false;$script:NavSearchLaunching=$false;$script:NavHistoryRows=$null;$script:NavHistoryState=$null;$script:NavListShape=$null
    $script:OuTreeFilterWork=$null;$script:OuTreeFilterTimer=$null;$script:OuTreeFilterStatus='';$script:PendingFilterChange=$null;$script:FilterChangeTimer=$null
    $script:OuFavouriteKeys=$null;$script:Continuity=$null;$script:ExperienceRestoring=$false;$script:SearchQueryCatalog=@();$script:ListSurveyBlocked=$false
    $script:SearchWorkspaceBound=$false;$script:SearchWorkspaceUndo=$null;$script:SearchWorkspaceTimer=$null;$script:SearchWorkspacePendingSort=$null;$script:SearchPreviewToken='';$script:SearchPreviewPending=$false
    $script:Exports=[Collections.Generic.List[object]]::new();$script:ParkCalls=[Collections.Generic.List[object]]::new();$script:StoreReads=[Collections.Generic.List[object]]::new()
    $script:ParkControlUpdates=0;$script:ParkMenus=0;$script:ParkDefaultMode=$null;$script:PendingColumns=@();$script:SearchBarScope='Everywhere';$script:SearchBarType='Tous'
    $script:Embedded=0;$script:OnEmbedded=$null;$script:FormName='';$script:DatabaseScopedPath='';$script:Tasks=0;$script:PendingExport=@();$script:UiTasks=[Collections.Generic.List[object]]::new();$script:DomeniaSurfaceRecords=@{};$script:DomeniaSurfaceState=$null
    $script:Ctrl=New-TestControls
}

# ---------------------------------------------------------------- Point 52: navigable breadcrumb
# Unwired if the intermediate levels are not buttons, if the domain becomes a shortcut, or if the copy does not carry
# the exact DN of the path shown.
Case 'P52 Fil dʼAriane : chaque niveau intermédiaire remonte, le domaine reste un contexte, la copie porte le DN exact' {
    $dn='OU=Postes,OU=Lyon,OU=Sites,DC=example,DC=invalid'
    $script:SelectedBranchDn=$dn
    Update-DomeniaOuBreadcrumb -Dn $dn
    $children=@($script:Ctrl.PnlOuBreadcrumb.Children)
    $buttons=@($children|Where-Object{$_ -is [Windows.Controls.Button]})
    Expect ($buttons.Count -eq 3) ('Boutons du fil : '+$buttons.Count)
    Expect ($children[0] -is [Windows.Controls.TextBlock] -and [string]$children[0].Text -eq 'example.invalid') 'Le domaine est devenu un bouton ou a disparu.'
    Expect ([string]$buttons[0].Tag.DN -eq 'OU=Sites,DC=example,DC=invalid' -and [string]$buttons[1].Tag.DN -eq 'OU=Lyon,OU=Sites,DC=example,DC=invalid') 'Niveaux intermédiaires incorrects.'
    Expect (([string]$buttons[1].ToolTip).Contains('example.invalid / Sites / Lyon') -and [Windows.Automation.AutomationProperties]::GetHelpText($buttons[1]) -ceq [string]$buttons[1].ToolTip) 'Le niveau ne nomme pas son chemin complet.'
    $copy=$buttons[2]
    Expect ([string]$copy.Tag -ceq $dn -and ([string]$copy.ToolTip).Contains($dn) -and [Windows.Automation.AutomationProperties]::GetName($copy)) 'La copie ne porte pas le DN exact du fil.'
    $leaf=@($children|Where-Object{$_ -is [Windows.Controls.TextBlock] -and [string]$_.Text -eq 'Postes'})
    Expect ($leaf.Count -eq 1 -and ([string]$leaf[0].ToolTip).Contains('Sites / Lyon / Postes')) 'La feuille ne montre pas son chemin.'
    $buttons[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Expect ($script:SelectedBranchDn -eq 'OU=Lyon,OU=Sites,DC=example,DC=invalid' -and $script:Searches.Count -eq 1 -and $script:Reveals.Count -eq 1) 'Remonter ne lit pas une seule fois la branche choisie.'
    # A breadcrumb of another session never navigates.
    $stale=[pscustomobject]@{DN='OU=Sites,DC=example,DC=invalid';BaseDn='DC=example,DC=invalid';Epoch=4L}
    Open-DomeniaOuBreadcrumb -Target $stale
    Expect ($script:Searches.Count -eq 1) 'Un fil dʼune autre session a lancé une lecture.'
}
# Unwired if the scope line or the favourites name an OU by its leaf only when another OU has the same name.
Case 'Programme 8 / P52 Deux OU de même nom restent distinctes dans la portée et les favoris' {
    $lyon='OU=Postes,OU=Lyon,DC=example,DC=invalid';$paris='OU=Postes,OU=Paris,DC=example,DC=invalid'
    Update-DomeniaUxOuScope ([pscustomobject]@{BaseDn=$lyon;Scope='Subtree';IsDomain=$false})
    Expect (([string]$script:Ctrl.LblSearchScope.Text).Contains('Postes (dans Lyon)')) ('Portée : '+$script:Ctrl.LblSearchScope.Text)
    $script:Settings['OuFavouritesImported']=$true
    Write-DomeniaOuFavouriteStore -Favourites @([pscustomobject]@{DN=$lyon;Name='Postes';Subtree=$true;Type='Tous';Term=''},[pscustomobject]@{DN=$paris;Name='Postes';Subtree=$true;Type='Tous';Term=''},[pscustomobject]@{DN='OU=Serveurs,DC=example,DC=invalid';Name='Serveurs';Subtree=$true;Type='Tous';Term=''})
    Update-DomeniaOuFavouritesUi
    $texts=@($script:Ctrl.PnlOuFavourites.Children|ForEach-Object{@($_.Children|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Content -is [Windows.Controls.TextBlock]})[0].Content.Text})
    Expect ($texts.Count -eq 3 -and ($texts -join '|') -ceq ([string][char]0x2605+' Postes (Lyon)|'+[string][char]0x2605+' Postes (Paris)|'+[string][char]0x2605+' Serveurs')) ('Favoris : '+($texts -join '|'))
}

# ---------------------------------------------------------------- Point 53: tree filter keeping the path
# Unwired if the filter hides the parents of a match, reads an unread branch, or shows the system group for its label.
Case 'Programme 8 / P53 Filtre de lʼarbre : parents conservés, groupe système seulement pour un conteneur trouvé, aucune lecture' {
    $root=New-FixtureNode 'DC=example,DC=invalid' 'example.invalid' $true 'domainDNS'
    $sites=New-FixtureNode 'OU=Sites,DC=example,DC=invalid' 'Sites' $true;$lyon=New-FixtureNode 'OU=Comptabilite,OU=Sites,DC=example,DC=invalid' 'Comptabilité' $true
    $other=New-FixtureNode 'OU=Serveurs,DC=example,DC=invalid' 'Serveurs' $true;$unread=New-FixtureNode 'OU=Archives,DC=example,DC=invalid' 'Archives' $false
    $group=New-FixtureNode '' 'Conteneurs système (1)' $true 'SystemGroup';$system=New-FixtureNode 'CN=System,DC=example,DC=invalid' 'System' $true 'Container'
    [void]$sites.Items.Add($lyon);[void]$group.Items.Add($system);[void]$unread.Items.Add('Chargement...')
    foreach($n in @($sites,$other,$unread,$group)){[void]$root.Items.Add($n)};[void]$script:Ctrl.TvDirectory.Items.Add($root)
    $script:Ctrl.TxtOuFilter.Text='compta';Update-DomeniaOuTreeFilter
    $guard=0;while($null -ne $script:OuTreeFilterWork -and $guard -lt 100){Invoke-DomeniaOuTreeFilterSlice;$guard++}
    Expect ($sites.Visibility -eq 'Visible' -and $lyon.Visibility -eq 'Visible' -and $sites.IsExpanded) 'Le parent dʼune correspondance est masqué ou replié.'
    Expect ($other.Visibility -eq 'Collapsed' -and $unread.Visibility -eq 'Collapsed' -and -not $unread.IsExpanded -and $group.Visibility -eq 'Collapsed') 'Une branche sans correspondance reste visible ou une branche non lue a été dépliée.'
    Expect (([string]$script:Ctrl.LblTreeStatus.Text).Contains('1 branche(s) lue(s)')) ('Statut : '+$script:Ctrl.LblTreeStatus.Text)
    $script:Ctrl.TxtOuFilter.Text='conteneurs';Update-DomeniaOuTreeFilter
    $guard=0;while($null -ne $script:OuTreeFilterWork -and $guard -lt 100){Invoke-DomeniaOuTreeFilterSlice;$guard++}
    Expect ($group.Visibility -eq 'Collapsed') 'Le groupe système correspond à son propre libellé.'
    $script:Ctrl.TxtOuFilter.Text='syst';Update-DomeniaOuTreeFilter
    $guard=0;while($null -ne $script:OuTreeFilterWork -and $guard -lt 100){Invoke-DomeniaOuTreeFilterSlice;$guard++}
    Expect ($group.Visibility -eq 'Visible' -and $system.Visibility -eq 'Visible') 'Le conteneur trouvé nʼest pas montré dans son groupe.'
    Expect ($script:Searches.Count -eq 0) 'Le filtre a lancé une lecture.'
}

# ---------------------------------------------------------------- Point 55: exact return to the previous view
# Unwired if the history keeps only one selected row, loses the sort or the list size, or ignores the branches open
# at that step.
Case 'Programme 8 / P55 Précédent rend le tri, la taille de la liste, toutes les lignes sélectionnées et les branches ouvertes, sans lecture' {
    $base='DC=example,DC=invalid'
    $root=New-FixtureNode $base 'example.invalid' $true 'domainDNS';$sites=New-FixtureNode ('OU=Sites,'+$base) 'Sites' $true
    $lyon=New-FixtureNode ('OU=Lyon,OU=Sites,'+$base) 'Lyon' $true;$paris=New-FixtureNode ('OU=Paris,'+$base) 'Paris' $true
    [void]$sites.Items.Add($lyon);[void]$root.Items.Add($sites);[void]$root.Items.Add($paris);[void]$script:Ctrl.TvDirectory.Items.Add($root)
    $root.IsExpanded=$true;$sites.IsExpanded=$true;$paris.IsExpanded=$false
    $script:SelectedBranchDn=('OU=Lyon,OU=Sites,'+$base)
    $grid=$script:Ctrl.DgObjects
    $rowsA=@((New-FixtureRow 'PC-01' 'Machine' '11111111-1111-4111-8111-111111111111' 'OU=Lyon,OU=Sites'),(New-FixtureRow 'PC-02' 'Machine' '22222222-2222-4222-8222-222222222222' 'OU=Lyon,OU=Sites'),(New-FixtureRow 'PC-03' 'Machine' '' 'OU=Lyon,OU=Sites'))
    $grid.ItemsSource=$rowsA;$script:BranchObjects=$rowsA
    $grid.Items.SortDescriptions.Add([ComponentModel.SortDescription]::new('Name',[ComponentModel.ListSortDirection]::Descending))
    [void]$grid.SelectedItems.Add($rowsA[0]);[void]$grid.SelectedItems.Add($rowsA[2])
    $script:Ctrl.TxtGlobalLimit.Text='250'
    $script:NavHistory=New-DomeniaNavHistory -Capacity 10
    [void](Push-DomeniaNavState $script:NavHistory (Get-DomeniaNavSnapshot -Page 'WsSearch'))
    $first=$script:NavHistory.Current
    Expect (@($first.Sort).Count -eq 1 -and [string]$first.Sort[0].Field -eq 'Name' -and @($first.SelectionKeys).Count -eq 2) 'Tri ou sélection multiple non mémorisés.'
    Expect (@($first.TreeExpanded) -contains ('OU=Sites,'+$base) -and @($first.TreeExpanded) -notcontains ('OU=Paris,'+$base)) 'Branches ouvertes non mémorisées.'
    Expect ([int]$first.Limit -eq 250) ('Taille de liste mémorisée : '+[string]$first.Limit)
    # Another OU, another list, another tree shape.
    $script:SelectedBranchDn=('OU=Paris,'+$base)
    $rowsB=@((New-FixtureRow 'SRV-01' 'Machine' '33333333-3333-4333-8333-333333333333' 'OU=Paris'))
    $grid.ItemsSource=$rowsB;$script:BranchObjects=$rowsB;$sites.IsExpanded=$false;$paris.IsExpanded=$true;$script:Ctrl.TxtGlobalLimit.Text='100'
    [void](Push-DomeniaNavState $script:NavHistory (Get-DomeniaNavSnapshot -Page 'WsSearch'))
    $step=Invoke-DomeniaNavStep -Direction Back
    Expect ($step.Moved -and [object]::ReferenceEquals($grid.ItemsSource,$rowsA)) 'La liste mémorisée nʼest pas rendue.'
    Expect ($grid.Items.SortDescriptions.Count -eq 1 -and [string]$grid.Items.SortDescriptions[0].PropertyName -eq 'Name' -and $grid.Items.SortDescriptions[0].Direction -eq 'Descending' -and $grid.Columns[1].SortDirection -eq 'Descending') 'Le tri nʼest pas rendu.'
    $selected=@($grid.SelectedItems)
    Expect ($selected.Count -eq 2 -and @($selected|Where-Object{[object]::ReferenceEquals($_,$rowsA[0])}).Count -eq 1 -and @($selected|Where-Object{[object]::ReferenceEquals($_,$rowsA[2])}).Count -eq 1) ('Sélection rendue : '+$selected.Count)
    Expect ($sites.IsExpanded -and -not $paris.IsExpanded -and $lyon.IsSelected) 'Les branches ouvertes ou lʼOU de lʼétape ne sont pas rendues.'
    Expect ([string]$script:Ctrl.TxtGlobalLimit.Text -ceq '250') ('La taille de la liste nʼest pas rendue : '+$script:Ctrl.TxtGlobalLimit.Text)
    Expect ($script:Searches.Count -eq 0 -and $script:SelectedBranchDn -eq ('OU=Lyon,OU=Sites,'+$base)) 'Le retour a relu lʼannuaire ou changé de périmètre.'
}
# Unwired if a remembered branch that is no longer read is opened (which would read it) instead of being reported.
Case 'Programme 8 / P55 Une branche mémorisée mais non lue nʼest jamais relue par lʼhistorique' {
    $base='DC=example,DC=invalid'
    $root=New-FixtureNode $base 'example.invalid' $true 'domainDNS';$gone=New-FixtureNode ('OU=Archives,'+$base) 'Archives' $false
    [void]$gone.Items.Add('Chargement...');[void]$root.Items.Add($gone);[void]$script:Ctrl.TvDirectory.Items.Add($root);$root.IsExpanded=$true
    $plan=Restore-DomeniaTreeNavState -Expanded @(('OU=Archives,'+$base),('OU=Absente,'+$base)) -SelectedDn ('OU=Absente,'+$base)
    Expect (-not $gone.IsExpanded -and $plan.UnreadCount -eq 1 -and [string]@($plan.Unread)[0] -eq ('OU=Archives,'+$base)) 'Une branche non lue a été dépliée ou nʼest pas comptée.'
    # An OU absent from its read parent branch is not an unread branch: it is counted apart.
    Expect ($plan.MissingCount -eq 1 -and [string]@($plan.Missing)[0] -eq ('OU=Absente,'+$base)) 'Une OU absente de sa branche lue est comptée comme non lue.'
    Expect ($null -eq $script:Ctrl.TvDirectory.SelectedItem -or -not ($script:Ctrl.TvDirectory.SelectedItem -is [Windows.Controls.TreeViewItem])) 'Lʼarbre montre une autre OU que la liste.'
}
# Unwired if the history only sees the first 600 tree items or the first 128 open branches: in a large directory a
# read branch would be called unread, the OU of the step would not be selected and open branches would be folded.
Case 'Programme 8 / P55 Grand annuaire : toutes les branches ouvertes et lʼOU de lʼétape sont retrouvées, sans lecture' {
    $base='DC=example,DC=invalid'
    $root=New-FixtureNode $base 'example.invalid' $true 'domainDNS';[void]$script:Ctrl.TvDirectory.Items.Add($root);$root.IsExpanded=$true
    $children=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt 700;$i++){
        $child=New-FixtureNode ('OU=Site'+$i.ToString('000')+','+$base) ('Site'+$i.ToString('000')) $true
        [void]$child.Items.Add((New-FixtureNode ('OU=Postes,OU=Site'+$i.ToString('000')+','+$base) 'Postes' $true))
        [void]$root.Items.Add($child);$children.Add($child)
    }
    # 150 open branches, the last ones beyond the first 600 items of the tree.
    for($i=550;$i -lt 700;$i++){$children[$i].IsExpanded=$true}
    $remembered=@(Get-DomeniaTreeExpandedDns)
    Expect ($remembered.Count -eq 151 -and $remembered -contains ('OU=Site699,'+$base)) ('Branches ouvertes mémorisées : '+$remembered.Count)
    # The operator folds everything, then goes back to that step.
    foreach($child in $children){$child.IsExpanded=$false}
    $target=('OU=Postes,OU=Site699,'+$base)
    $plan=Restore-DomeniaTreeNavState -Expanded $remembered -SelectedDn $target
    Expect ($plan.UnreadCount -eq 0 -and $plan.MissingCount -eq 0) ('Branches lues annoncées non lues : '+$plan.UnreadCount+' / absentes : '+$plan.MissingCount)
    Expect ($children[699].IsExpanded -and $children[550].IsExpanded -and -not $children[549].IsExpanded) 'Une branche ouverte à cette étape reste repliée, ou une autre sʼouvre.'
    Expect ($children[699].Items[0].IsSelected) 'LʼOU de lʼétape, au-delà des 600 premiers éléments, nʼest pas sélectionnée.'
    Expect ($script:Searches.Count -eq 0) 'Le retour a lancé une lecture.'
}

# ---------------------------------------------------------------- Points 56 to 60: search workspace
function Set-FixtureList {param([object[]]$Rows)
    $grid=$script:Ctrl.DgObjects;$grid.ItemsSource=$Rows;$script:BranchObjects=$Rows
}
function New-FixtureStoreResult {param($Context,[object[]]$Rows,[object[]]$Observations=@())
    [pscustomobject]@{DataSource='SQLite';StoreId=[string]$Context.StoreId;Path=[string]$Context.Path;Busy=$false;Missing=$false;Rows=$Rows;Observations=$Observations;SnapshotRevision=42L}
}
# Unwired if the views library reads several saved views as one entry (Windows PowerShell 5.1 JSON arrays), if a
# view does not bring back its filters, columns and sort, or if opening a view reads the directory.
Case 'P57 Vues personnelles : enregistrer, retrouver, ouvrir sans lecture, retirer et annuler' {
    Initialize-DomeniaSearchWorkspace
    $script:SelectedBranchDn='OU=Postes,OU=Lyon,DC=example,DC=invalid'
    $script:Ctrl.CmbGlobalType.SelectedIndex=2;$script:Ctrl.CmbPresenceFilter.SelectedIndex=1;$script:CurrentPresenceFilter='En ligne'
    $script:Ctrl.TxtSuiteResultFilter.Text='pc';$script:Ctrl.TxtGlobalLimit.Text='500';$script:Ctrl.ChkSubtree.IsChecked=$false
    $script:Ctrl.DgObjects.Columns[1].Width=[Windows.Controls.DataGridLength]::new(310)
    Set-FixtureList @((New-FixtureRow 'PC-02'),(New-FixtureRow 'PC-01'))
    $script:Ctrl.DgObjects.Items.SortDescriptions.Add([ComponentModel.SortDescription]::new('Name',[ComponentModel.ListSortDirection]::Descending))
    $script:FormName='Parc Lyon';Save-DomeniaSearchWorkspace
    $script:FormName='Alpha';Save-DomeniaSearchWorkspace
    $views=@($script:Ctrl.CmbSearchWorkspace.ItemsSource)
    Expect ($views.Count -eq 2 -and [string]$views[0].Name -eq 'Alpha' -and [string]$views[1].Label -ceq 'Parc Lyon · Postes seulement · Machines') ('Vues relues : '+$views.Count+' / '+(@($views|ForEach-Object{$_.Label}) -join ' | '))
    Expect (([string]$script:Settings['Search.WorkspacesJson']) -notmatch 'PC-0') 'Une ligne de résultat a été enregistrée dans la vue.'
    # Everything changes, then the view is opened again.
    $script:Ctrl.CmbGlobalType.SelectedIndex=0;$script:Ctrl.CmbPresenceFilter.SelectedIndex=0;$script:CurrentPresenceFilter='Tous';$script:Ctrl.TxtSuiteResultFilter.Text='';$script:Ctrl.TxtGlobalLimit.Text='100';$script:Ctrl.ChkSubtree.IsChecked=$true
    $script:Ctrl.DgObjects.Columns[1].Width=[Windows.Controls.DataGridLength]::new(120);$script:SelectedBranchDn='OU=Autre,DC=example,DC=invalid'
    $script:Ctrl.CmbSearchWorkspace.SelectedItem=$views[1]
    Expect ($script:Ctrl.BtnSearchWorkspaceOpen.IsEnabled -and $script:Ctrl.BtnSearchWorkspaceRemove.IsEnabled) 'Ouvrir et Retirer restent grisés pour une vue choisie.'
    Open-DomeniaSearchWorkspace
    Expect ($script:SelectedBranchDn -eq 'OU=Postes,OU=Lyon,DC=example,DC=invalid' -and [string]$script:Ctrl.CmbGlobalType.SelectedItem.Content -eq 'Machines' -and [string]$script:Ctrl.CmbPresenceFilter.SelectedItem.Content -eq 'En ligne') 'Périmètre ou filtres non rendus.'
    Expect ($script:Ctrl.TxtSuiteResultFilter.Text -eq 'pc' -and $script:Ctrl.TxtGlobalLimit.Text -eq '500' -and -not [bool]$script:Ctrl.ChkSubtree.IsChecked -and [int]$script:Ctrl.DgObjects.Columns[1].Width.Value -eq 310) ('Filtre/limite/profondeur/largeur : '+$script:Ctrl.TxtSuiteResultFilter.Text+' / '+$script:Ctrl.TxtGlobalLimit.Text+' / '+$script:Ctrl.ChkSubtree.IsChecked+' / '+$script:Ctrl.DgObjects.Columns[1].Width.Value)
    Expect ($script:Searches.Count -eq 0 -and @($script:Ctrl.DgObjects.ItemsSource).Count -eq 0) 'Ouvrir une vue a lu lʼannuaire ou gardé lʼancienne liste.'
    # The next list receives the sort of the view.
    Set-FixtureList @((New-FixtureRow 'PC-01'),(New-FixtureRow 'PC-03'))
    Expect ($script:Ctrl.DgObjects.Items.SortDescriptions.Count -eq 1 -and [string]$script:Ctrl.DgObjects.Items.SortDescriptions[0].PropertyName -eq 'Name' -and [string]@($script:Ctrl.DgObjects.Items)[0].Name -eq 'PC-03') 'Le tri de la vue ne sʼapplique pas à la liste suivante.'
    $script:Ctrl.CmbSearchWorkspace.SelectedItem=@($script:Ctrl.CmbSearchWorkspace.ItemsSource)[0];Remove-DomeniaSearchWorkspace
    Expect (@($script:Ctrl.CmbSearchWorkspace.ItemsSource).Count -eq 1 -and $script:Ctrl.BtnSearchWorkspaceUndo.IsEnabled) 'Retrait non appliqué ou Annuler indisponible.'
    Undo-DomeniaSearchWorkspace
    Expect (@($script:Ctrl.CmbSearchWorkspace.ItemsSource).Count -eq 2) 'Annuler ne restaure pas la vue.'
    $before=[string]$script:Settings['Search.WorkspacesJson'];$script:SaveFails=$true;$script:FormName='Gamma';Save-DomeniaSearchWorkspace
    Expect ([string]$script:Settings['Search.WorkspacesJson'] -ceq $before -and $script:LastStatusLevel -eq 'WARN') 'Un échec dʼécriture laisse une vue non enregistrée en mémoire.'
}
# Unwired if a failed write during Annuler discards the removed view (no retry possible), or if Annuler restores a
# former text over views changed since the removal.
Case 'P57 Annuler un retrait : un échec dʼécriture garde lʼannulation, un changement des vues la termine' {
    Initialize-DomeniaSearchWorkspace
    $script:SelectedBranchDn='OU=Postes,DC=example,DC=invalid'
    $script:FormName='Parc';Save-DomeniaSearchWorkspace;$script:FormName='Autre';Save-DomeniaSearchWorkspace
    $script:Ctrl.CmbSearchWorkspace.SelectedItem=@($script:Ctrl.CmbSearchWorkspace.ItemsSource)[0];Remove-DomeniaSearchWorkspace
    $after=[string]$script:Settings['Search.WorkspacesJson']
    $script:SaveFails=$true;Undo-DomeniaSearchWorkspace
    Expect ($null -ne $script:SearchWorkspaceUndo -and $script:Ctrl.BtnSearchWorkspaceUndo.IsEnabled -and [string]$script:Settings['Search.WorkspacesJson'] -ceq $after) 'Un échec dʼécriture a perdu lʼannulation ou laissé un texte non enregistré.'
    Expect ($script:LastStatusLevel -eq 'WARN' -and ([string]$script:LastStatus).Contains('Réessayez')) ('Statut : '+$script:LastStatus)
    $script:SaveFails=$false;Undo-DomeniaSearchWorkspace
    Expect ($null -eq $script:SearchWorkspaceUndo -and @($script:Ctrl.CmbSearchWorkspace.ItemsSource).Count -eq 2) 'Le nouvel essai dʼAnnuler ne restaure pas la vue.'
    # Views changed since the removal: the undo ends without touching them.
    $script:Ctrl.CmbSearchWorkspace.SelectedItem=@($script:Ctrl.CmbSearchWorkspace.ItemsSource)[0];Remove-DomeniaSearchWorkspace
    $changed=[string]$script:Settings['Search.WorkspacesJson']+' ';$script:Settings['Search.WorkspacesJson']=$changed
    Undo-DomeniaSearchWorkspace
    Expect ($null -eq $script:SearchWorkspaceUndo -and [string]$script:Settings['Search.WorkspacesJson'] -ceq $changed -and $script:LastStatusLevel -eq 'WARN') 'Annuler a écrasé des vues changées depuis le retrait.'
}
# Unwired if a new session keeps listing the views of the former domain or the undo of a former removal, or if
# Changer de session does not list the views again once the tree of the new domain is prepared.
Case 'P57 Une nouvelle session liste les vues de son propre domaine, sans lecture' {
    Initialize-DomeniaSearchWorkspace
    $script:SelectedBranchDn='OU=Postes,DC=example,DC=invalid'
    $script:FormName='Parc';Save-DomeniaSearchWorkspace
    $script:FormName='Autre';Save-DomeniaSearchWorkspace
    $script:Ctrl.CmbSearchWorkspace.SelectedItem=@($script:Ctrl.CmbSearchWorkspace.ItemsSource)[0];Remove-DomeniaSearchWorkspace
    Expect (@($script:Ctrl.CmbSearchWorkspace.ItemsSource).Count -eq 1 -and $null -ne $script:SearchWorkspaceUndo) 'Préparation : retrait non appliqué.'
    $script:Ctrl.PnlSearchPreview.Visibility='Visible';$script:Ctrl.DgSearchPreview.ItemsSource=@([pscustomobject]@{Property='Nom';Value='PC-01';Date=''});$script:SearchPreviewToken='ancien'
    # Changer de session, towards another domain.
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=autre,DC=invalid';Domain='autre.invalid';Server='dc.autre.invalid'};$script:SessionEpoch=6L
    Reset-DomeniaSearchWorkspaceSession
    Expect (@($script:Ctrl.CmbSearchWorkspace.ItemsSource).Count -eq 0 -and $null -eq $script:Ctrl.CmbSearchWorkspace.SelectedItem) 'Les vues de lʼancien domaine restent proposées.'
    Expect ($null -eq $script:SearchWorkspaceUndo -and -not $script:Ctrl.BtnSearchWorkspaceUndo.IsEnabled) 'Annuler restaurerait une vue de lʼancienne session.'
    Expect ($script:SearchPreviewToken -eq '' -and @($script:Ctrl.DgSearchPreview.ItemsSource).Count -eq 0 -and ([string]$script:Ctrl.LblSearchPreview.Text).Contains('nouvelle session')) 'Lʼaperçu montre encore une ligne de lʼancienne session.'
    Expect ([string]$script:Settings['Search.WorkspacesJson'] -match 'Parc') 'La vue de lʼancien domaine a été effacée du stockage.'
    # Back to the first domain: its remaining view is listed again.
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server='dc.example.invalid'};$script:SessionEpoch=7L
    Reset-DomeniaSearchWorkspaceSession
    Expect (@($script:Ctrl.CmbSearchWorkspace.ItemsSource).Count -eq 1 -and [string]@($script:Ctrl.CmbSearchWorkspace.ItemsSource)[0].Name -eq 'Parc') 'La vue du domaine nʼest pas listée au retour.'
    Expect ($script:Searches.Count -eq 0 -and $script:StoreReads.Count -eq 0) 'La nouvelle session a lancé une lecture.'
    # Changer de session lists the views again after the tree of the new domain.
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
    $relogin=@($ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Start-DomeniaAccountRelogin')},$true))
    Expect ($relogin.Count -eq 1) 'Changer de session introuvable.'
    $text=$relogin[0].Extent.Text;$tree=$text.IndexOf('Load-TreeRoot');$reset=$text.IndexOf('Reset-DomeniaSearchWorkspaceSession')
    Expect (($tree -ge 0) -and ($reset -gt $tree)) 'Changer de session ne liste pas les vues du nouveau domaine après lʼarbre.'
}
# Unwired if a criterion of the list is hidden, if removing a list-level chip reads the directory, or if the scope
# chip can be removed.
Case 'P56 Critères visibles : chaque critère est une pastille, retirée par son propre contrôle, sans lecture' {
    Initialize-DomeniaSearchWorkspace
    $script:SelectedBranchDn='OU=Postes,OU=Lyon,DC=example,DC=invalid'
    Set-FixtureList @((New-FixtureRow 'PC-01'),(New-FixtureRow 'PC-02'))
    $script:Ctrl.CmbGlobalType.SelectedIndex=2;$script:Ctrl.CmbPresenceFilter.SelectedIndex=1;$script:CurrentPresenceFilter='En ligne';$script:Ctrl.TxtSuiteResultFilter.Text='pc'
    Invoke-DomeniaSearchWorkspaceRefresh
    $children=@($script:Ctrl.PnlSearchFilterChips.Children)
    Expect ($children.Count -eq 4 -and $children[0] -is [Windows.Controls.Border] -and @($children|Where-Object{$_ -is [Windows.Controls.Button]}).Count -eq 3) ('Pastilles : '+$children.Count)
    Expect (([string]$children[0].Child.Text).Contains('Postes') -and ([string]$children[0].ToolTip).Contains('example.invalid / Lyon / Postes')) 'La portée nʼest pas lisible.'
    $summary=[string]$script:Ctrl.LblSearchFilterSummary.Text
    Expect ($summary.Contains(' ET ') -and $summary.Contains('[Liste chargée] Contient : pc')) ('Combinaison : '+$summary)
    $local=@($children|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Tag -eq 'Local'})[0]
    Expect ([Windows.Automation.AutomationProperties]::GetHelpText($local) -ceq [string]$local.ToolTip) 'Lʼeffet de la pastille nʼest pas annoncé.'
    $local.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Expect ($script:Ctrl.TxtSuiteResultFilter.Text -eq '' -and $script:Searches.Count -eq 0) 'Le filtre local nʼest pas retiré, ou une lecture est partie.'
    $presence=@($script:Ctrl.PnlSearchFilterChips.Children|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Tag -eq 'Presence'})[0]
    $presence.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Expect ($script:Ctrl.CmbPresenceFilter.SelectedIndex -eq 0) 'La présence nʼest pas retirée par son contrôle.'
    $type=@($script:Ctrl.PnlSearchFilterChips.Children|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Tag -eq 'Type'})[0]
    Expect (([string]$type.ToolTip).Contains('relit')) 'Retirer le type ne dit pas quʼil relit lʼOU.'
    $type.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Expect ($script:Ctrl.CmbGlobalType.SelectedIndex -eq 0 -and @($script:Ctrl.PnlSearchFilterChips.Children).Count -eq 1) 'Le type nʼest pas retiré par son contrôle.'
}
# Unwired if removing the workshop selection also erases the query list it refines, or reads anything.
Case 'P56 Retirer la sélection de lʼatelier garde la liste de la requête et son critère' {
    Initialize-DomeniaSearchWorkspace
    Set-FixtureList @((New-FixtureRow 'PC-01' 'Machine' '11111111-1111-4111-8111-111111111111'),(New-FixtureRow 'PC-02' 'Machine' '22222222-2222-4222-8222-222222222222'))
    $script:ActiveSearchViewId='local:fixture.disques';$script:SearchQueryRun=[pscustomobject]@{Id='local:fixture.disques';Name='Disques pleins';Selection='Match';Limit=100;Job='';Total=2L;Shown=2L}
    $script:DomeniaQueryState=[pscustomobject]@{SearchRecipe=[pscustomobject]@{Name='Segment'};SearchRefinement=$null;SearchRecords=@{'11111111-1111-4111-8111-111111111111'=$true}}
    Invoke-DomeniaSearchWorkspaceRefresh
    $keys=@($script:Ctrl.PnlSearchFilterChips.Children|Where-Object{$_ -is [Windows.Controls.Button]}|ForEach-Object{[string]$_.Tag})
    Expect (($keys -contains 'Query') -and ($keys -contains 'Segment')) ('Pastilles : '+($keys -join ','))
    $segment=@($script:Ctrl.PnlSearchFilterChips.Children|Where-Object{$_ -is [Windows.Controls.Button] -and [string]$_.Tag -eq 'Segment'})[0]
    $segment.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Expect ($null -eq $script:DomeniaQueryState.SearchRecipe -and $script:DomeniaQueryState.SearchRecords.Count -eq 0 -and $script:PresenceFilters -eq 1) 'La sélection de lʼatelier nʼest pas retirée par son seul filtre.'
    Expect ($script:Invalidations -eq 0 -and $script:ActiveSearchViewId -eq 'local:fixture.disques' -and $null -ne $script:SearchQueryRun -and @($script:Ctrl.DgObjects.ItemsSource).Count -eq 2) 'Retirer la sélection a effacé la liste de la requête.'
    $keys=@($script:Ctrl.PnlSearchFilterChips.Children|Where-Object{$_ -is [Windows.Controls.Button]}|ForEach-Object{[string]$_.Tag})
    Expect (($keys -contains 'Query') -and ($keys -notcontains 'Segment')) ('Pastilles après retrait : '+($keys -join ','))
    Expect ($script:Searches.Count -eq 0 -and $script:StoreReads.Count -eq 0 -and $script:Tasks -eq 0) 'Retirer la sélection a lancé une lecture.'
}
# Unwired if a finished local query still names its criterion or its limit once another list is shown.
Case 'P56 Une requête locale terminée ne décrit plus une autre liste' {
    Initialize-DomeniaSearchWorkspace
    Set-FixtureList @((New-FixtureRow 'PC-01'),(New-FixtureRow 'PC-02'))
    $script:SearchQueryRun=[pscustomobject]@{Id='local:fixture.disques';Name='Disques pleins';Selection='Match';Limit=100;Job='';Total=120L;Shown=100L}
    # An ordinary OU list read since then: the run no longer owns the list.
    $script:ActiveSearchViewId=''
    Invoke-DomeniaSearchWorkspaceRefresh
    $keys=@($script:Ctrl.PnlSearchFilterChips.Children|Where-Object{$_ -is [Windows.Controls.Button]}|ForEach-Object{[string]$_.Tag})
    Expect ($keys -notcontains 'Query' -and -not ([string]$script:Ctrl.LblSearchFilterSummary.Text).Contains('Disques pleins')) 'La requête précédente reste un critère dʼune autre liste.'
    Expect ([string](Get-DomeniaSearchListCompleteness).State -ne 'Limited' -and -not ([string]$script:Ctrl.LblResultScope.Text).Contains('limitée')) ('Complétude dʼune autre liste : '+$script:Ctrl.LblResultScope.Text)
    # The same run while its list is shown: named, and limited.
    $script:ActiveSearchViewId='local:fixture.disques'
    Invoke-DomeniaSearchWorkspaceRefresh
    $keys=@($script:Ctrl.PnlSearchFilterChips.Children|Where-Object{$_ -is [Windows.Controls.Button]}|ForEach-Object{[string]$_.Tag})
    Expect ($keys -contains 'Query' -and ([string]$script:Ctrl.LblResultScope.Text).Contains('liste limitée à 100 lignes')) ('Requête affichée : '+$script:Ctrl.LblResultScope.Text)
}
# Unwired if the export or « Vérifier la liste ▾ » silently takes the selection or the list, if the bar of a multiple
# selection (X01) exports anything but the selected rows, or if the label hides what is excluded.
Case 'P60 Portée collective : liste affichée ou lignes sélectionnées, choisie et annoncée avant lʼexport ou le relevé' {
    Initialize-DomeniaSearchWorkspace
    $rows=@((New-FixtureRow 'PC-01' 'Machine' '11111111-1111-4111-8111-111111111111'),(New-FixtureRow 'PC-02' 'Machine' '22222222-2222-4222-8222-222222222222'),(New-FixtureRow 'PC-03' 'Machine' '33333333-3333-4333-8333-333333333333'),(New-FixtureRow 'Jean' 'Utilisateur' '44444444-4444-4444-8444-444444444444'))
    Set-FixtureList $rows
    $script:Ctrl.DgObjects.Items.Filter=[Predicate[object]]{param($item) [string]$item.Name -ne 'PC-03'}
    [void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[0]);[void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[3])
    Invoke-DomeniaSearchWorkspaceRefresh
    Expect (([string]$script:Ctrl.LblResultScope.Text).Contains('Liste affichée : 3 ligne(s)') -and ([string]$script:Ctrl.LblResultScope.Text).Contains('1 ligne(s) chargée(s) masquée(s)') -and ([string]$script:Ctrl.LblResultScope.Text).Contains('sélection de 2')) ('Portée : '+$script:Ctrl.LblResultScope.Text)
    Export-CurrentResults
    Expect (@($script:Exports[0].Rows).Count -eq 3 -and [string]$script:Exports[0].Scope -eq 'liste affichée' -and ([string]$script:Exports[0].Also).Contains('Liste affichée : 3')) 'La liste affichée nʼest pas exportée telle quelle.'
    Expect (((@($script:PendingColumns)|ForEach-Object{[string]$_.Property}) -join ',') -eq 'Type,Name,State,DN') 'Les colonnes visibles ne sont plus exportées.'
    Invoke-DomeniaParkVerify -Mode Ping
    Expect ($script:ParkCalls.Count -eq 1 -and $script:ParkCalls[0].Displayed -and $script:ParkCalls[0].PingOnly -and -not $script:ParkCalls[0].Selection) 'Vérifier la liste ne vise pas la liste affichée.'
    $script:Ctrl.CmbResultScope.SelectedIndex=1
    Invoke-DomeniaSearchWorkspaceRefresh
    Expect (([string]$script:Ctrl.LblResultScope.Text).Contains('Lignes sélectionnées : 2 lignes sélectionnées dont 1 poste sur 3 affichée(s)')) ('Portée choisie : '+$script:Ctrl.LblResultScope.Text)
    Expect ((Get-DomeniaParkVerifyButtonText) -eq 'Vérifier la sélection : Qui répond ?') (Get-DomeniaParkVerifyButtonText)
    Export-CurrentResults
    Expect (@($script:Exports[1].Rows).Count -eq 2 -and [string]$script:Exports[1].Scope -eq 'lignes sélectionnées' -and [object]::ReferenceEquals(@($script:Exports[1].Rows)[0],$rows[0])) 'La sélection nʼest pas exportée seule.'
    Invoke-DomeniaParkVerify -Mode Analyse
    $call=$script:ParkCalls[1]
    Expect ($call.Kind -eq 'Analyse' -and $call.Selection -and -not $call.Displayed -and @($call.Targets).Count -eq 1 -and [string]$call.Targets[0].object_guid -eq '11111111-1111-4111-8111-111111111111') 'Analyser ne vise pas les seuls postes sélectionnés, par le relevé de la sélection.'
    # The bar of a multiple selection always acts on the selected rows, whatever the scope chosen beside the results,
    # and states them as the scope line does.
    $script:Ctrl.CmbResultScope.SelectedIndex=0
    Export-CurrentResults -Mode Selected
    Expect (@($script:Exports[2].Rows).Count -eq 2 -and [string]$script:Exports[2].Scope -eq 'lignes sélectionnées' -and ([string]$script:Exports[2].Also).Contains('2 lignes sélectionnées dont 1 poste')) ('Export de la barre de sélection : '+[string]$script:Exports[2].Also)
    Start-DomeniaParkSelectionSurvey -Mode Console
    Expect ($script:ParkCalls.Count -eq 3 -and $script:ParkCalls[2].Selection -and $script:ParkCalls[2].Kind -eq 'Console' -and @($script:ParkCalls[2].Targets).Count -eq 1) 'Le relevé de la barre de sélection ne vise pas la sélection.'
    $script:Ctrl.CmbResultScope.SelectedIndex=1;$script:Ctrl.DgObjects.SelectedItems.Clear();Export-CurrentResults
    Expect ($script:Exports.Count -eq 3 -and ([string]$script:LastStatus).Contains('Aucune ligne')) 'Une sélection vide a exporté quelque chose.'
    Invoke-DomeniaParkVerify -Mode Ping
    Expect ($script:ParkCalls.Count -eq 3 -and ([string]$script:LastStatus).StartsWith('Aucune ligne sélectionnée')) ('Sélection vide relevée : '+$script:LastStatus)
}
# Unwired if the scope line keeps 'lecture en cours' once a live read ends without any grid event, if it does not
# follow a live filter pass (written to the result counter), or if a handler still runs for each appended row.
Case 'P60 Liste progressive : la ligne de portée suit la fin de la lecture, sans gestionnaire par ligne' {
    function Test-DomeniaLiveSearchActive {return ($null -ne $script:Live)}
    Initialize-DomeniaSearchWorkspace
    $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach($name in @('PC-01','PC-02','PC-03')){$rows.Add((New-FixtureRow $name))}
    $script:Live=[pscustomobject]@{Search=[pscustomobject]@{Rows=$rows;State=[pscustomobject]@{Limit=3};Error='';Finalized=$false;Final=$null}}
    $script:Ctrl.DgObjects.ItemsSource=$rows
    Invoke-DomeniaSearchWorkspaceRefresh
    Expect (([string]$script:Ctrl.LblResultScope.Text).Contains('lecture en cours') -and [bool]$script:SearchWorkspaceTimer.IsEnabled) ('Pendant la lecture : '+$script:Ctrl.LblResultScope.Text)
    # The read ends: rows already in place are updated, the collection does not change, no grid event is raised.
    $script:Live.Search.Finalized=$true;$script:Live.Search.Final=[pscustomobject]@{LimitReached=$true}
    & $script:SearchWorkspaceTimer.Tick
    Expect (([string]$script:Ctrl.LblResultScope.Text).Contains('liste limitée à 3 lignes')) ('Après la lecture : '+$script:Ctrl.LblResultScope.Text)
    Expect (-not [bool]$script:SearchWorkspaceTimer.IsEnabled) 'Le rafraîchissement continue après la fin de la lecture.'
    $rows.Add((New-FixtureRow 'PC-04'))
    Expect (-not [bool]$script:SearchWorkspaceTimer.IsEnabled) 'Une ligne ajoutée déclenche encore un gestionnaire par ligne.'
    # A live filter pass after the read (a local filter, or presence results under a presence filter): the live list
    # rewrites its counter, and the scope line follows the filtered list.
    $script:Ctrl.DgObjects.Items.Filter=[Predicate[object]]{param($item) [string]$item.Name -ne 'PC-01'}
    [void](Set-DomeniaControlText 'LblSuiteResultCount' 'Limite atteinte · 3 / 4 lignes visibles · filtre local')
    Expect ([bool]$script:SearchWorkspaceTimer.IsEnabled) 'La ligne de portée ne suit pas un passage du filtre de la liste progressive.'
    & $script:SearchWorkspaceTimer.Tick
    Expect (([string]$script:Ctrl.LblResultScope.Text).Contains('Liste affichée : 3 ligne(s) · 1 ligne(s) chargée(s) masquée(s)') -and -not [bool]$script:SearchWorkspaceTimer.IsEnabled) ('Après le filtre : '+$script:Ctrl.LblResultScope.Text)
}
# Unwired if « Vérifier la liste ▾ » or the export still names the displayed results only, if the bar of a multiple
# selection exports the chosen scope instead of the selection, or if a screen reader, the tooltip and the help of the
# page describe different scopes.
Case 'P60 Export et relevés nomment la portée choisie : infobulle, aide dʼautomation et aide de la page identiques' {
    . ([scriptblock]::Create((Import-AstFunctions (Join-Path $wad 'Domenia-Core.ps1') @('Get-MainXaml'))))
    [xml]$xaml=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)
    $aideBrutee=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-UX.help.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
    $aide=@($aideBrutee)
    foreach($name in @('BtnParkVerify','BtnExportResults','CmbResultScope','PnlOuBreadcrumb')){
        $node=@($xaml.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -eq $name})
        Expect ($node.Count -eq 1) ($name+' : '+$node.Count+' occurrence(s)')
        $tip=[string](Get-TestCatalogueHelp $node[0] 'ToolTip');$label=[string]$node[0].GetAttribute('AutomationProperties.Name')
        if($name -ne 'PnlOuBreadcrumb'){Expect ($tip.Contains('portée choisie') -or $tip.Contains('Portée de lʼexport')) ($name+' ne nomme pas la portée choisie.')}
        Expect ($tip -ceq [string](Get-TestCatalogueHelp $node[0] 'AutomationProperties.HelpText')) ($name+' : infobulle et aide dʼautomation divergent.')
        $entry=@($aide|Where-Object{[string]$_.Name -ceq $name})
        Expect ($entry.Count -eq 1 -and [string]$entry[0].Text -ceq $tip -and [string]$entry[0].Title -ceq $label) ($name+' : aide de la page absente ou différente.')
    }
    # One breadcrumb, in the header of the card (X02, DS-06); the three former survey buttons are gone (X01, UI-23).
    $header=@($xaml.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -eq 'UxSearchCardHeader'})
    Expect ($header.Count -eq 1 -and @($header[0].SelectNodes('.//*')|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -eq 'PnlOuBreadcrumb'}).Count -eq 1) 'Le fil dʼAriane nʼest pas dans lʼen-tête de la carte.'
    foreach($name in @('BtnParkPing','BtnParkResults','BtnParkAnalyze','BtnParkResultsStop')){
        Expect (@($xaml.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -eq $name}).Count -eq 0) ($name+' est revenu.')
    }
    # The export of the results menu names the scope it follows; the bar of a multiple selection exports the selection.
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
    $menu=@($ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Build-DomeniaObjectsContextMenu')},$true))
    Expect ($menu.Count -eq 1) 'Menu des résultats introuvable.'
    $text=$menu[0].Extent.Text
    Expect ($text.Contains('Get-DomeniaResultScopeMode') -and $text.Contains('Exporter les lignes sélectionnées en CSV') -and $text.Contains('Exporter la liste affichée en CSV') -and -not $text.Contains('"Exporter la liste en CSV"')) 'Le menu des résultats ne nomme pas la portée de lʼexport.'
    $wire=@($ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Wire-Events')},$true))
    Expect ($wire.Count -eq 1 -and $wire[0].Extent.Text.Contains('$script:Ctrl["BtnSelectionExport"].Add_Click({ Export-CurrentResults -Mode Selected })')) 'Lʼexport de la barre de sélection ne vise pas la sélection.'
}
# Unwired if the preview leaves the results, loses a multiple selection, or shows a late answer of another row.
Case 'P59 Aperçu latéral : la ligne courante est lue dans la base locale, la sélection de travail reste' {
    Initialize-DomeniaSearchWorkspace
    $script:DatabaseScopedPath='C:\DomeniaFixture\aucune-base.db'
    $rows=@((New-FixtureRow 'PC-01' 'Machine' '11111111-1111-4111-8111-111111111111'),(New-FixtureRow 'PC-02' 'Machine' '22222222-2222-4222-8222-222222222222'))
    Set-FixtureList $rows
    [void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[0]);[void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[1]);$script:Ctrl.DgObjects.CurrentItem=$rows[1]
    Switch-DomeniaSearchPreview
    Expect ($script:Ctrl.PnlSearchPreview.Visibility -eq 'Visible' -and $script:Ctrl.SearchPreviewSplitter.Visibility -eq 'Visible' -and $script:StoreReads.Count -eq 1) 'Lʼaperçu ne sʼouvre pas à côté des résultats.'
    $read=$script:StoreReads[0]
    Expect (@($read.Query.Guids)[0] -eq '22222222-2222-4222-8222-222222222222' -and $read.Query.Kind -eq 'Directory' -and $script:Ctrl.DgObjects.SelectedItems.Count -eq 2) 'Lʼaperçu ne lit pas la ligne courante, ou la sélection est perdue.'
    $stored=[pscustomobject]@{Guid='22222222-2222-4222-8222-222222222222';Name='PC-02';Type='Machine';DN='CN=PC-02,OU=Postes,DC=example,DC=invalid';State='Actif';Description='';Login='PC-02';Upn='';LastLogon='';ObservedAtUtc='2026-10-12T08:00:00Z';Details=[pscustomobject]@{operatingsystem=@('Windows 11 Pro')};FieldTimes=[pscustomobject]@{}}
    Complete-DomeniaSearchPreview (New-FixtureStoreResult $read.Context @($stored)) $read.CallbackState
    $shown=@($script:Ctrl.DgSearchPreview.ItemsSource)
    Expect (@($shown|Where-Object{$_.Property -eq 'Nom' -and $_.Value -eq 'PC-02'}).Count -eq 1 -and @($shown|Where-Object{$_.Property -eq 'Inventaire' -and $_.Value -eq 'Non lu'}).Count -eq 1) 'Fiche locale incomplète ou inventée.'
    Expect (([string]$script:Ctrl.LblSearchPreview.Text).Contains('révision 42') -and $script:Tasks -eq 0) 'Révision locale absente, ou une collecte est partie.'
    # A late answer for a row no longer consulted is ignored.
    $script:Ctrl.DgObjects.CurrentItem=$rows[0];Request-DomeniaSearchPreview
    Complete-DomeniaSearchPreview (New-FixtureStoreResult $read.Context @($stored)) $read.CallbackState
    Expect (@($script:Ctrl.DgSearchPreview.ItemsSource).Count -eq 0) 'Une réponse tardive dʼune autre ligne est affichée.'
    Switch-DomeniaSearchPreview
    Expect ($script:Ctrl.PnlSearchPreview.Visibility -eq 'Collapsed' -and $script:Ctrl.SearchPreviewSplitter.Visibility -eq 'Collapsed') 'Fermer ne masque pas lʼaperçu.'
}
# Unwired if the comparison opens a separate window, compares rows without their dates, or keeps an answer after it closed.
Case 'P58 Comparer des postes : feuille dans la page, différences surlignées, dates propres' {
    Initialize-DomeniaSearchWorkspace
    $script:DatabaseScopedPath='C:\DomeniaFixture\aucune-base.db'
    $g1='11111111-1111-4111-8111-111111111111';$g2='22222222-2222-4222-8222-222222222222'
    $rows=@((New-FixtureRow 'PC-01' 'Machine' $g1),(New-FixtureRow 'PC-02' 'Machine' $g2),(New-FixtureRow 'Jean' 'Utilisateur' '44444444-4444-4444-8444-444444444444'))
    Set-FixtureList $rows
    [void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[0]);[void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[2])
    Show-DomeniaSearchComparison
    Expect ($script:StoreReads.Count -eq 0 -and $script:LastStatusLevel -eq 'WARN') 'Un compte utilisateur a été comparé comme un poste.'
    $script:Ctrl.DgObjects.SelectedItems.Remove($rows[2]);[void]$script:Ctrl.DgObjects.SelectedItems.Add($rows[1])
    $script:OnEmbedded={param($Window)
        $read=$script:StoreReads[0]
        $r1=[pscustomobject]@{Guid=$g1;Name='PC-01';DN='CN=PC-01,DC=example,DC=invalid';State='Actif';Description='';LastLogon='';ObservedAtUtc='2026-10-10T08:00:00Z';Details=[pscustomobject]@{operatingsystem=@('Windows 11 Pro')};FieldTimes=[pscustomobject]@{'Details.operatingsystem'='2026-10-10T08:00:00Z'}}
        $r2=[pscustomobject]@{Guid=$g2;Name='PC-02';DN='CN=PC-02,DC=example,DC=invalid';State='Actif';Description='';LastLogon='';ObservedAtUtc='2026-10-10T08:00:00Z';Details=[pscustomobject]@{operatingsystem=@('Windows 10 Pro')};FieldTimes=[pscustomobject]@{'Details.operatingsystem'='2026-10-11T08:00:00Z'}}
        Complete-DomeniaSearchComparison (New-FixtureStoreResult $read.Context @($r1,$r2)) $read.CallbackState
        $script:ComparisonState=$read.CallbackState
        $table=$read.CallbackState.Table
        $script:ComparisonRows=@($table.ItemsSource);$script:ComparisonColumns=@($table.Columns|ForEach-Object{[string]$_.Header})
        $read.CallbackState.Only.IsChecked=$true;$script:ComparisonFiltered=@($table.ItemsSource)
        $script:ComparisonStyle=$table.RowStyle
        return $true
    }
    Show-DomeniaSearchComparison
    Expect ($script:Embedded -eq 1 -and @($script:StoreReads[0].Query.Guids).Count -eq 2) 'La comparaison nʼest pas une feuille de la page ou ne lit pas les deux postes.'
    $os=@($script:ComparisonRows|Where-Object{$_.Property -eq 'Système'})[0]
    Expect ($null -ne $os -and $os.Difference -eq 'Different' -and $os.T0 -ne $os.T1 -and $os.V0 -eq 'Windows 11 Pro') 'Valeurs ou dates mélangées.'
    Expect ($script:ComparisonColumns -contains 'PC-01 · valeur' -and $script:ComparisonColumns -contains 'PC-02 · date UTC') ('Colonnes : '+($script:ComparisonColumns -join ' | '))
    Expect (@($script:ComparisonFiltered|Where-Object{$_.Difference -eq 'Same'}).Count -eq 0 -and $script:ComparisonFiltered.Count -lt $script:ComparisonRows.Count) 'Différences seulement ne masque pas les lignes identiques.'
    Expect ($null -ne $script:ComparisonStyle -and @($script:ComparisonStyle.Triggers|Where-Object{[string]$_.Value -eq 'Different'}).Count -eq 1) 'Les différences ne sont pas surlignées.'
    Expect ($script:ComparisonState.Closed) 'La feuille fermée accepte encore une réponse.'
}

# ---------------------------------------------------------------- Point 54: one OU picker for every page
function Find-FixtureElement {param($Root,[string]$Name)
    foreach($element in @(Get-DomeniaLogicalControls $Root)){if(($element -is [Windows.FrameworkElement]) -and ([string]$element.Name -eq $Name)){return $element}}
    return $null
}
# Unwired if the picker loses the favourites of Rechercher, the depth, the confirmation line, or opens on the root
# instead of the current choice of the page; or if a choice is returned without its DN and GUID check.
Case 'P54 Sélecteur dʼOU commun : favoris distincts, profondeur, confirmation et ouverture sur le choix courant' {
    $base='DC=example,DC=invalid';$lyon='OU=Lyon,'+$base;$postes='OU=Postes,'+$lyon
    $script:Settings['OuFavouritesImported']=$true
    Write-DomeniaOuFavouriteStore -Favourites @([pscustomobject]@{DN=$postes;Name='Postes';Subtree=$true;Type='Tous';Term=''},[pscustomobject]@{DN=('OU=Postes,OU=Paris,'+$base);Name='Postes';Subtree=$true;Type='Tous';Term=''},[pscustomobject]@{DN=$base;Name='Domaine';Subtree=$true;Type='Tous';Term=''})
    $script:OnEmbedded={param($Window)
        $record=Get-DomeniaSurfaceRecord $Window;$record.Embedded=$true
        # The sheet is realized like the in-page host does, so that tree selection events really run.
        $Window.ShowInTaskbar=$false;$Window.Show();$Window.UpdateLayout()
        try{
        & $record.Ready;$Window.UpdateLayout()
        $root=$Window.Content
        $strip=Find-FixtureElement $root 'EmbeddedOuFavourites'
        $script:PickerChips=@($strip.Children|Where-Object{$_ -is [Windows.Controls.Button]}|ForEach-Object{[string]$_.Content})
        $script:PickerDepth=Find-FixtureElement $root 'EmbeddedOuSubtree'
        $summary=Find-FixtureElement $root 'EmbeddedOuSummary'
        $first=$script:UiTasks[$script:UiTasks.Count-1]
        $owner=$first.State.Owner;$script:PickerOwner=$owner
        Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@([pscustomobject]@{Type='OU';Name='Paris';DN=('OU=Paris,'+$base);Guid='00000000-0000-4000-8000-000000000002'},[pscustomobject]@{Type='OU';Name='Lyon';DN=$lyon;Guid='00000000-0000-4000-8000-000000000001'});RequestId=$first.State.RequestId;Verified=$false;Capped=$false}) $first.State
        $Window.UpdateLayout()
        $second=$script:UiTasks[$script:UiTasks.Count-1]
        $script:PickerSecondDn=[string]$second.Payload.DN
        Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@([pscustomobject]@{Type='OU';Name='Postes';DN=$postes;Guid='00000000-0000-4000-8000-000000000003'});RequestId=$second.State.RequestId;Verified=$false;Capped=$false}) $second.State
        $script:PickerSelected=[string]$owner.Tree.SelectedItem.Tag.DN
        $script:PickerSummary=[string]$summary.Text
        $script:PickerDepth.IsChecked=$true;$script:PickerSummaryAfter=[string]$summary.Text;$script:PickerDepth.IsChecked=$false
        $owner.Accept.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $verify=$script:UiTasks[$script:UiTasks.Count-1]
        $script:PickerVerify=$verify.Payload
        Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@([pscustomobject]@{Type='OU';Name='Postes';DN=$postes;Guid='00000000-0000-4000-8000-000000000003'});RequestId=$verify.State.RequestId;Verified=$true;Capped=$false}) $verify.State
        return $true
        }finally{if($Window.IsVisible){$Window.Close()}}
    }
    $picked=Show-DomeniaInlinePicker -Kind OU -Title 'Fixture' -Prompt 'Données fictives' -DepthMode Choice -Subtree $false -Purpose 'Effet : fixture.' -InitialDn $postes
    Expect (($script:PickerChips -join '|') -ceq ([string][char]0x2605+' Postes (Lyon)|'+[string][char]0x2605+' Postes (Paris)')) ('Favoris du sélecteur : '+($script:PickerChips -join '|'))
    Expect ($null -ne $script:PickerDepth -and $script:PickerSecondDn -eq $lyon -and $script:PickerSelected -eq $postes) 'Le sélecteur ne sʼouvre pas sur lʼOU courante en lisant ses parents un à un.'
    Expect ($script:PickerSummary.Contains('example.invalid / Lyon / Postes') -and $script:PickerSummary.Contains('sans ses sous-OU') -and $script:PickerSummary.Contains('Effet : fixture.') -and $script:PickerSummaryAfter.Contains('et ses sous-OU')) ('Confirmation : '+$script:PickerSummary)
    Expect ([bool]$script:PickerVerify.Verify -and [string]$script:PickerVerify.DN -eq $postes -and [string]$script:PickerVerify.Guid -eq '00000000-0000-4000-8000-000000000003') 'Le choix nʼest pas revérifié par DN et GUID.'
    Expect ($null -ne $picked -and [string]$picked.Guid -eq '00000000-0000-4000-8000-000000000003' -and $picked.Subtree -eq $false) 'La profondeur confirmée nʼaccompagne pas lʼOU choisie.'
    Expect (@($script:UiTasks|Where-Object{([string]$_.Payload.Mode -eq 'Search') -and (-not [bool]$_.Payload.Verify)}).Count -eq 0 -and $script:UiTasks.Count -eq 3) ('Lectures du sélecteur : '+$script:UiTasks.Count)
    Expect ($null -eq $script:PickerOwner.Reveal) 'Une révélation reste en attente après le choix.'
}
# Unwired if the picker contradicts itself on its initial place: the domain root reported outside the domain, or a
# container (CN=Computers) presented as a choice to confirm while Choisir stays disabled.
Case 'P54 Ouverture du sélecteur : racine silencieuse, conteneur annoncé comme tel' {
    $base='DC=example,DC=invalid'
    $root=[Windows.Controls.TreeViewItem]::new();$root.Tag=[pscustomobject]@{DN=$base;Row=$null;Loaded=$true;Context=$false;Loading=$false}
    $computers=[Windows.Controls.TreeViewItem]::new();$computers.Tag=[pscustomobject]@{DN=('CN=Computers,'+$base);Row=[pscustomobject]@{Type='Conteneur';Name='Computers';DN=('CN=Computers,'+$base);Guid='00000000-0000-4000-8000-0000000000c1'};Loaded=$true;Context=$false;Loading=$false}
    $postes=[Windows.Controls.TreeViewItem]::new();$postes.Tag=[pscustomobject]@{DN=('OU=Postes,'+$base);Row=[pscustomobject]@{Type='OU';Name='Postes';DN=('OU=Postes,'+$base);Guid='00000000-0000-4000-8000-0000000000c2'};Loaded=$true;Context=$false;Loading=$false}
    [void]$root.Items.Add($computers);[void]$root.Items.Add($postes)
    $owner=[pscustomobject]@{Closed=$false;Mode='Navigation';Job='';RootNode=$root;Reveal=$null;BaseDn=$base;Status=[Windows.Controls.TextBlock]::new();Box=[Windows.Controls.TextBox]::new()}
    Start-DomeniaOuPickerReveal -Owner $owner -Dn $base
    Expect ([string]$owner.Status.Text -eq '' -and $null -eq $owner.Reveal) ('Racine du domaine : '+$owner.Status.Text)
    Start-DomeniaOuPickerReveal -Owner $owner -Dn ('CN=Computers,'+$base)
    Expect ($computers.IsSelected -and ([string]$owner.Status.Text).Contains('conteneur') -and -not ([string]$owner.Status.Text).Contains('Choisir')) ('Conteneur : '+$owner.Status.Text)
    Start-DomeniaOuPickerReveal -Owner $owner -Dn ('OU=Postes,'+$base)
    Expect ($postes.IsSelected -and ([string]$owner.Status.Text).Contains('Choisir')) ('OU : '+$owner.Status.Text)
    Expect ($script:UiTasks.Count -eq 0) 'Une branche déjà lue a été relue.'
}
# Unwired if a page opens the OU picker without saying what the choice will do, or the dashboard drops the depth.
Case 'P54 Chaque page passe par le sélecteur commun avec son effet et sa profondeur' {
    $sources=@{Core=(Join-Path $wad 'Domenia-Core.ps1');Dashboard=(Join-Path $modules 'Domenia-Dashboard.UI.ps1')}
    $calls=[Collections.Generic.List[string]]::new()
    foreach($path in $sources.Values){
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        foreach($call in @($ast.FindAll({param($n)($n -is [Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Show-DomeniaInlinePicker') -and ($n.Extent.Text -match '-Kind OU')},$true))){$calls.Add($call.Extent.Text)}
    }
    Expect ($calls.Count -ge 4) ('Appels du sélecteur dʼOU : '+$calls.Count)
    foreach($text in $calls){Expect ($text.Contains('-Purpose')) ('Sélecteur sans effet annoncé : '+$text)}
    Expect (@($calls|Where-Object{$_.Contains('-DepthMode Choice')}).Count -eq 2 -and @($calls|Where-Object{$_.Contains('-DepthMode Subtree')}).Count -eq 2) 'Profondeur imposée ou choisie absente dʼune page.'
    [xml]$query=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Query.xaml'),[Text.Encoding]::UTF8)
    $button=@($query.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -eq 'BtnQueryScope'})
    Expect ($button.Count -eq 1 -and (Get-TestCatalogueHelp $button[0] 'ToolTip') -ceq (Get-TestCatalogueHelp $button[0] 'AutomationProperties.HelpText')) 'LʼAtelier nʼa pas de bouton vers le sélecteur commun.'
    . ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-Dashboard.UI.ps1') @('Get-DomeniaFleetScope','Get-DomeniaFleetScopeSettingKey','Restore-DomeniaFleetScopeChoice','Save-DomeniaFleetScopeChoice','Show-DomeniaFleetScopeSource','Select-DomeniaFleetScopeOu'))))
    function Request-DomeniaFleetRefresh {param([switch]$Force) $script:FleetRefreshes++}
    function Show-DomeniaInlinePicker {param($Kind,$Title,$Prompt,$InitialTerm,$DepthMode,$Subtree,$Purpose,$InitialDn) $script:PickerCall=[pscustomobject]@{DepthMode=$DepthMode;Subtree=$Subtree;InitialDn=$InitialDn};return [pscustomobject]@{DN='OU=B,DC=example,DC=invalid';Guid='00000000-0000-4000-8000-00000000000b';Subtree=$false}}
    $script:FleetScopeDn='OU=A,DC=example,DC=invalid';$script:FleetScopeSubtree=$true;$script:FleetRefreshes=0
    Show-DomeniaFleetScopeSource
    $scope=Get-DomeniaFleetScope
    Expect ($script:PickerCall.DepthMode -eq 'Choice' -and $script:PickerCall.InitialDn -eq 'OU=A,DC=example,DC=invalid' -and [bool]$script:PickerCall.Subtree) 'Le tableau de bord nʼouvre pas le sélecteur sur son choix courant.'
    Expect ($scope.Dn -eq 'OU=B,DC=example,DC=invalid' -and -not $scope.Subtree -and $scope.Key.EndsWith('|OneLevel') -and $script:FleetRefreshes -eq 1) 'La profondeur choisie nʼest pas appliquée au tableau de bord.'
    Select-DomeniaFleetScopeOu -Dn 'OU=C,DC=example,DC=invalid'
    Expect (-not (Get-DomeniaFleetScope).Subtree) 'Le fil du tableau de bord perd la profondeur choisie.'
    $script:FleetScopeDn='';Expect ((Get-DomeniaFleetScope).Subtree) 'Le domaine entier est lu sans ses sous-OU.'
}

Case 'Programme 31 Classement exact, prefixe et correspondance dans adresse avec jokers' {
    $rows=@(
        [pscustomobject]@{Guid='1';Name='Autre';Mail='service-alex@example.invalid'},
        [pscustomobject]@{Guid='2';Name='Autre';Mail='alexandre@example.invalid'},
        [pscustomobject]@{Guid='3';Name='Autre';Mail='alex@example.invalid';Login='alex'},
        [pscustomobject]@{Guid='4';Name='Alex';Mail='different@example.invalid'}
    )
    $ordered=@(Sort-DomeniaSearchResults $rows '*alex*')
    Expect (($ordered.Guid -join ',') -eq '3,4,2,1') 'Le joker ou le mail perd la pertinence exact/prefixe/contient.'
    Expect (@(Sort-DomeniaSearchResults $rows '*').Count -eq 4) 'Le classement retire des correspondances.'
}
Case 'Programme 32 Une absence explique filtres portee plafond et couverture inconnue' {
    $limited=Get-DomeniaSearchAbsenceHint -Scope 'OU=Support,DC=example,DC=invalid' -Type 'Machine' -LocalFilter 'Paris' -Completeness Limited -Limit 200
    Expect ($limited -like '*OU=Support*' -and $limited -like '*Machine*' -and $limited -like '*Paris*' -and $limited -like '*200*incomplète*') 'Contexte de la liste limitee perdu.'
    foreach($state in @('Partial','Unknown')){Expect ((Get-DomeniaSearchAbsenceHint -Completeness $state) -match 'aucune absence|ne prouve pas') 'Une liste inconnue prouve une absence.'}
    Expect ((Get-DomeniaSearchAbsenceHint -Completeness Complete) -like '*ne prouve pas une absence ailleurs*') 'La portee finie devient globale.'
}

Case 'Programme 32 Fin partielle sans erreur reste partielle dans les actions de liste' {
    function Test-DomeniaLiveSearchActive {return $true}
    $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
    (Get-DomeniaControl 'DgObjects').ItemsSource=$rows
    $script:Live=[pscustomobject]@{Search=[pscustomobject]@{Rows=$rows;Error='';Finalized=$true;State=[pscustomobject]@{Limit=100};Final=[pscustomobject]@{Partial=$true;LimitReached=$false}}}
    Expect ((Get-DomeniaSearchListCompleteness).State -eq 'Partial') 'Une fin partielle sans message d erreur devient complete.'
}

$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-navigation-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{
    Kind='Wiring';Lot='W08-navigation';Filter=$Filter;Points=@('52','53','54','55','56','57','58','59','60')
    Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell51=$native;Wpf=$true;LiveAD=$false;LiveCIM=$false;LivePing=$false;SQLite=$false
    Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0 -and -not $Filter);Filter=$Filter;Subset=([bool]$Filter)
    Limitation='Raccordement prouve par les vraies fonctions et de vrais controles WPF ; annuaire, postes, base SQLite, presse-papiers et fenetres sont des doubles. Ne prouve ni un acces a un domaine reel ni le rendu final a lʼecran.'
    Tests=$script:Checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed reussi(s), $failed en echec. Rapport : "+$ReportPath);$script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
