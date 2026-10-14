#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
# W08, navigation lot (points 52 to 60): breadcrumb, OU labels, tree filter, exact history, search workspace (saved
# views, filter chips, collective scope, side preview, comparison) and the shared OU picker. Real modules are
# dot-sourced, core functions are extracted by AST and real WPF controls are used. Directory, workstations, SQLite,
# clipboard and dialogs are explicit doubles: no LDAP, CIM, ping, file or clipboard write.
# Each case fails when the wiring it names is removed (see the comment above each case).
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
if($null -eq ('Domenia.Live.ResultRow' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia-Live.Types.cs') -ErrorAction Stop}

# Real application code.
$coreNames=@('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSearchMode','Set-DomeniaSearchMode','Get-DomeniaSearchText','Export-CurrentResults')
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $wad 'Domenia-Core.ps1') $coreNames)))
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Experience.Model.ps1','Domenia-Continuity.Model.ps1','Domenia-SearchWorkspace.Model.ps1','Domenia-Continuity.UI.ps1','Domenia-Search.UI.ps1','Domenia-SearchWorkspace.UI.ps1')){
    . (Join-Path $modules $file)
}
. ([scriptblock]::Create((Import-AstFunctions (Join-Path $modules 'Domenia-UX.UI.ps1') @('Get-DomeniaUxOuDisplay','Update-DomeniaUxOuScope','Copy-DomeniaUxOuPath'))))
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
function Apply-DomeniaPresenceFilter { }
function Update-DomeniaSearchMoreButton {param($Search)}
function Start-UiTask {$script:Tasks++;return 'task-fixture'}
function New-DomeniaStoreContext {param([string]$RequestId) return [pscustomobject]@{RequestId=$RequestId;StoreId='store-fixture';Path=[string]$script:DatabaseScopedPath;DomainDn='DC=example,DC=invalid'}}
function Request-DomeniaStoreRead {param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState) $script:StoreReads.Add([pscustomobject]@{Context=$Context;Query=$Query;SuccessHandler=$SuccessHandler;CallbackState=$CallbackState});return ('read-'+$script:StoreReads.Count)}
function Show-DomeniaEmbeddedWindow {param($Window) $script:Embedded++;if($null -ne $script:OnEmbedded){return (& $script:OnEmbedded $Window)};return $true}
function Start-DomeniaOnlinePark {param([switch]$DisplayedResults,[switch]$PingOnly,[switch]$WmiOnly,[switch]$Inventory,[object[]]$ScopeTargets=$null,[string]$ScopeLabel='',[object[]]$Probes=$null)
    $script:ParkCalls.Add([pscustomobject]@{Kind=$(if($Inventory){'Analyze'}elseif($PingOnly){'Ping'}else{'Detect'});Displayed=[bool]$DisplayedResults;PingOnly=[bool]$PingOnly;Targets=$ScopeTargets;Label=$ScopeLabel})
}
function Start-DomeniaParkAnalysis {param([object[]]$ScopeTargets=$null,[string]$ScopeLabel='') Start-DomeniaOnlinePark -DisplayedResults:($null -eq $ScopeTargets) -Inventory -ScopeTargets $ScopeTargets -ScopeLabel $ScopeLabel}
function Export-DomeniaCsv {param($Rows,$Grid,$Subject) $script:PendingExport=@($Rows);return [pscustomobject]@{RowCount=@($Rows).Count;Path='C:\DomeniaFixture\export.csv'}}
function Show-DomeniaExportResult {param($Result,[string]$Scope='',[string]$Also='') $script:Exports.Add([pscustomobject]@{Rows=$script:PendingExport;Scope=$Scope;Also=$Also})}
function Get-DomeniaSearchExportSubject {return 'fixture'}
function Show-ErrorBox {param($Text) throw ('Fenêtre dʼerreur : '+[string]$Text)}

function New-FixtureNode {param([string]$Dn,[string]$Name,[bool]$Loaded,[string]$Kind='OU')
    $node=[Windows.Controls.TreeViewItem]::new()
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
    foreach($n in @('LblBranchCount','LblSearchScope','LblSearchHint','LblSearchQuery','LblOuScopeName','LblOuScopePath','LblTreeStatus','LblSearchFilterSummary','LblResultScope','LblSearchPreview')){$c[$n]=[Windows.Controls.TextBlock]::new()}
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
    $c.DgObjects=$grid
    $tabs=[Windows.Controls.TabControl]::new()
    foreach($n in @('WsSearch','WsObject')){$t=[Windows.Controls.TabItem]::new();$t.Name=$n;$t.Header=$n;[void]$tabs.Items.Add($t);$c[$n]=$t}
    $tabs.SelectedItem=$c.WsSearch;$c.WorkspaceTabs=$tabs
    $c.TvDirectory=[Windows.Controls.TreeView]::new()
    return $c
}
function Reset-Fixture {
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server='dc.example.invalid'}
    $script:SessionEpoch=5L;$script:GlobalSearchGeneration=40;$script:SearchMode='OU'
    $script:SelectedBranchDn='OU=Postes,DC=example,DC=invalid';$script:CurrentPresenceFilter='Tous';$script:ActiveSearchViewId=''
    $script:WriteBlocked=$false;$script:AsyncEngineClosing=$false;$script:RestoringSettings=$false;$script:SuppressBranchAutoLoad=$false;$script:SuppressGridSelectionEvents=$false
    $script:Settings=@{};$script:Saves=0;$script:SaveFails=$false;$script:LastStatus='';$script:LastStatusLevel='';$script:Hint=''
    $script:Searches=[Collections.Generic.List[object]]::new();$script:Reveals=[Collections.Generic.List[string]]::new();$script:Timers=[Collections.Generic.List[object]]::new()
    $script:ScopeUpdates=0;$script:Invalidations=0;$script:Workspace=''
    $script:BranchObjects=@();$script:BranchCountLabel='';$script:Live=$null;$script:LiveSearchTimer=$null;$script:SearchQueryRun=$null;$script:DomeniaQueryState=$null
    $script:NavHistory=$null;$script:NavRestoring=$false;$script:NavSearchLaunching=$false;$script:NavHistoryRows=$null;$script:NavHistoryState=$null;$script:NavListShape=$null
    $script:OuTreeFilterWork=$null;$script:OuTreeFilterTimer=$null;$script:OuTreeFilterStatus='';$script:PendingFilterChange=$null;$script:FilterChangeTimer=$null
    $script:OuFavouriteKeys=$null;$script:Continuity=$null;$script:ExperienceRestoring=$false;$script:SearchQueryCatalog=@();$script:ListSurveyBlocked=$false
    $script:SearchWorkspaceBound=$false;$script:SearchWorkspaceUndo=$null;$script:SearchWorkspaceTimer=$null;$script:SearchWorkspacePendingSort=$null;$script:SearchPreviewToken='';$script:SearchPreviewPending=$false
    $script:Exports=[Collections.Generic.List[object]]::new();$script:ParkCalls=[Collections.Generic.List[object]]::new();$script:StoreReads=[Collections.Generic.List[object]]::new()
    $script:Embedded=0;$script:OnEmbedded=$null;$script:FormName='';$script:DatabaseScopedPath='';$script:Tasks=0;$script:PendingExport=@()
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
Case 'P52 Deux OU de même nom restent distinctes dans la portée et les favoris' {
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
Case 'P53 Filtre de lʼarbre : parents conservés, groupe système seulement pour un conteneur trouvé, aucune lecture' {
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
# Unwired if the history keeps only one selected row, loses the sort, or ignores the branches open at that step.
Case 'P55 Précédent rend le tri, toutes les lignes sélectionnées et les branches ouvertes, sans lecture' {
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
    $script:NavHistory=New-DomeniaNavHistory -Capacity 10
    [void](Push-DomeniaNavState $script:NavHistory (Get-DomeniaNavSnapshot -Page 'WsSearch'))
    $first=$script:NavHistory.Current
    Expect (@($first.Sort).Count -eq 1 -and [string]$first.Sort[0].Field -eq 'Name' -and @($first.SelectionKeys).Count -eq 2) 'Tri ou sélection multiple non mémorisés.'
    Expect (@($first.TreeExpanded) -contains ('OU=Sites,'+$base) -and @($first.TreeExpanded) -notcontains ('OU=Paris,'+$base)) 'Branches ouvertes non mémorisées.'
    # Another OU, another list, another tree shape.
    $script:SelectedBranchDn=('OU=Paris,'+$base)
    $rowsB=@((New-FixtureRow 'SRV-01' 'Machine' '33333333-3333-4333-8333-333333333333' 'OU=Paris'))
    $grid.ItemsSource=$rowsB;$script:BranchObjects=$rowsB;$sites.IsExpanded=$false;$paris.IsExpanded=$true
    [void](Push-DomeniaNavState $script:NavHistory (Get-DomeniaNavSnapshot -Page 'WsSearch'))
    $step=Invoke-DomeniaNavStep -Direction Back
    Expect ($step.Moved -and [object]::ReferenceEquals($grid.ItemsSource,$rowsA)) 'La liste mémorisée nʼest pas rendue.'
    Expect ($grid.Items.SortDescriptions.Count -eq 1 -and [string]$grid.Items.SortDescriptions[0].PropertyName -eq 'Name' -and $grid.Items.SortDescriptions[0].Direction -eq 'Descending' -and $grid.Columns[1].SortDirection -eq 'Descending') 'Le tri nʼest pas rendu.'
    $selected=@($grid.SelectedItems)
    Expect ($selected.Count -eq 2 -and @($selected|Where-Object{[object]::ReferenceEquals($_,$rowsA[0])}).Count -eq 1 -and @($selected|Where-Object{[object]::ReferenceEquals($_,$rowsA[2])}).Count -eq 1) ('Sélection rendue : '+$selected.Count)
    Expect ($sites.IsExpanded -and -not $paris.IsExpanded -and $lyon.IsSelected) 'Les branches ouvertes ou lʼOU de lʼétape ne sont pas rendues.'
    Expect ($script:Searches.Count -eq 0 -and $script:SelectedBranchDn -eq ('OU=Lyon,OU=Sites,'+$base)) 'Le retour a relu lʼannuaire ou changé de périmètre.'
}
# Unwired if a remembered branch that is no longer read is opened (which would read it) instead of being reported.
Case 'P55 Une branche mémorisée mais non lue nʼest jamais relue par lʼhistorique' {
    $base='DC=example,DC=invalid'
    $root=New-FixtureNode $base 'example.invalid' $true 'domainDNS';$gone=New-FixtureNode ('OU=Archives,'+$base) 'Archives' $false
    [void]$gone.Items.Add('Chargement...');[void]$root.Items.Add($gone);[void]$script:Ctrl.TvDirectory.Items.Add($root);$root.IsExpanded=$true
    $plan=Restore-DomeniaTreeNavState -Expanded @(('OU=Archives,'+$base),('OU=Absente,'+$base)) -SelectedDn ('OU=Absente,'+$base)
    Expect (-not $gone.IsExpanded -and $plan.UnreadCount -eq 2) 'Une branche non lue a été dépliée ou nʼest pas comptée.'
    Expect ($null -eq $script:Ctrl.TvDirectory.SelectedItem -or -not ($script:Ctrl.TvDirectory.SelectedItem -is [Windows.Controls.TreeViewItem])) 'Lʼarbre montre une autre OU que la liste.'
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
    Expect ($script:Ctrl.TxtSuiteResultFilter.Text -eq 'pc' -and $script:Ctrl.TxtGlobalLimit.Text -eq '500' -and -not [bool]$script:Ctrl.ChkSubtree.IsChecked -and [int]$script:Ctrl.DgObjects.Columns[1].Width.Value -eq 310) 'Filtre, limite, profondeur ou largeur non rendus.'
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
# Unwired if the export or a survey silently takes the selection or the list, or if the label hides what is excluded.
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
    Start-DomeniaResultSurvey -Kind Ping
    Expect ($script:ParkCalls.Count -eq 1 -and $script:ParkCalls[0].Displayed -and $script:ParkCalls[0].PingOnly) 'Pinger la liste ne vise pas la liste affichée.'
    $script:Ctrl.CmbResultScope.SelectedIndex=1
    Export-CurrentResults
    Expect (@($script:Exports[1].Rows).Count -eq 2 -and [string]$script:Exports[1].Scope -eq 'lignes sélectionnées' -and [object]::ReferenceEquals(@($script:Exports[1].Rows)[0],$rows[0])) 'La sélection nʼest pas exportée seule.'
    Start-DomeniaResultSurvey -Kind Analyze
    $call=$script:ParkCalls[1]
    Expect ($call.Kind -eq 'Analyze' -and @($call.Targets).Count -eq 1 -and [string]$call.Targets[0].object_guid -eq '11111111-1111-4111-8111-111111111111' -and ([string]$call.Label).Contains('sélection')) 'Analyser ne vise pas les seuls postes sélectionnés.'
    $script:ListSurveyBlocked=$true;Start-DomeniaResultSurvey -Kind Detect
    Expect ($script:ParkCalls.Count -eq 2 -and $script:LastStatusLevel -eq 'WARN') 'Une liste du domaine entier a été relevée.'
    $script:ListSurveyBlocked=$false;$script:Ctrl.DgObjects.SelectedItems.Clear();Export-CurrentResults
    Expect ($script:Exports.Count -eq 2 -and ([string]$script:LastStatus).Contains('Aucune ligne')) 'Une sélection vide a exporté quelque chose.'
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

$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-navigation-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{
    Kind='Wiring';Lot='W08-navigation';Points=@('52','53','54','55','56','57','58','59','60')
    Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell51=$native;Wpf=$true;LiveAD=$false;LiveCIM=$false;LivePing=$false;SQLite=$false
    Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0)
    Limitation='Raccordement prouve par les vraies fonctions et de vrais controles WPF ; annuaire, postes, base SQLite, presse-papiers et fenetres sont des doubles. Ne prouve ni un acces a un domaine reel ni le rendu final a lʼecran.'
    Tests=$script:Checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed reussi(s), $failed en echec. Rapport : "+$ReportPath);$script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
