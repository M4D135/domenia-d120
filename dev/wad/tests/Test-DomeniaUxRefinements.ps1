#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path $PSScriptRoot -Parent;$script:RootDir=$wad
. (Join-Path $wad 'Domenia-Modules.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse errors'}
foreach($name in @('Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaEffectiveWorkerResult','Get-DomeniaDefaultSettings','Get-DomeniaXamlControlNames')){
 $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
 . ([scriptblock]::Create(($node.Extent.Text -replace ('^function\s+'+[regex]::Escape($name)+'\b'),('function script:'+$name))))
}
$script:Results=[Collections.Generic.List[object]]::new();$script:Checks=0;$script:SettingsFixture=@{};$script:Ctrl=@{}
function Expect {param([bool]$Value,[string]$Why)$script:Checks++;if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)try{&$Body;$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Get-DomeniaSetting {param($Name,$Default)if($script:SettingsFixture.ContainsKey($Name)){return $script:SettingsFixture[$Name]};return $Default}
function Set-DomeniaSetting {param($Name,$Value)$script:SettingsFixture[$Name]=$Value}
function Save-DomeniaSettings {param([switch]$Immediate,[switch]$ThrowOnFailure)}
function Set-Status {param($Text,$Level)}
function Write-AppLog {param($Text,$Level)}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
$script:FixtureTasks=[Collections.Generic.List[object]]::new()
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass)
 if($OperationId -notin @('LocalIndexRead','LocalQuery','EmbeddedDirectoryLookup')){throw ('Network forbidden in fixture: '+$OperationId)}
 $script:FixtureTasks.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;Code=$Code;State=$CallbackState})
 return ('fixture-'+$script:FixtureTasks.Count)
}
function Initialize-DomeniaWinSqliteNative {return $true}
function Get-DomeniaIndexPartialText {return ''}
function Get-DomeniaSearchScope {param($Mode);if(-not [string]$script:Conn.BaseDn){throw 'No session base'};return [pscustomobject]@{BaseDn=[string]$script:SelectedBranchDn;Scope=$(if([bool](Get-DomeniaControl 'ChkSubtree').IsChecked){'Subtree'}else{'OneLevel'})}}
function Invalidate-DomeniaSearchResults {param([switch]$KeepSelection);$script:GlobalSearchGeneration++;(Get-DomeniaControl 'DgObjects').ItemsSource=@()}
function Apply-DomeniaPresenceFilter {}
function Update-DomeniaSearchMoreButton {param($Search)}
function Save-DomeniaFleetSnapshot {param($Scope,$Board)return $false}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);(Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl $Workspace;if($Inner -and $Tab){(Get-DomeniaControl $Inner).SelectedItem=Get-DomeniaControl $Tab}}
$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Connected=$false};$script:SessionEpoch=1
$xaml=Get-MainXaml;$script:Window=[Windows.Markup.XamlReader]::Parse($xaml);foreach($name in @(Get-DomeniaXamlControlNames -XamlText $xaml)){$control=$script:Window.FindName($name);if($null -ne $control){$script:Ctrl[$name]=$control}};$script:Window.Width=1280;$script:Window.Height=720;$script:Window.ShowInTaskbar=$false
try{
 $script:Window.Show();$script:Window.UpdateLayout()
 Case 'The query editor occupies its own workspace, outside the dashboard' {
  Initialize-DomeniaQueryWorkshop
  Expect ($null -eq (Get-DomeniaControl 'ExpFleetMachines')) 'Old dashboard query expander remains'
  $view=Get-DomeniaControl 'DomeniaQueryView';$dashboard=Get-DomeniaControl 'TabDashboard'
  Expect ($null -ne $view -and -not $dashboard.IsAncestorOf($view)) 'Query editor remains in dashboard'
  (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
  Show-DomeniaQueryWorkshop
  Expect ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabApplicationTools' -and (Get-DomeniaControl 'ApplicationToolTabs').SelectedItem.Name -eq 'WsQueryWorkshop') 'Workshop route failed'
  (Get-DomeniaControl 'BtnQueryBack').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Expect ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'WsSearch') 'Back did not restore origin'
  $before=$script:Ctrl.Count;Initialize-DomeniaQueryWorkshop;Expect ($script:Ctrl.Count -eq $before) 'Duplicate query initialization'
  (Get-DomeniaControl 'BtnQueryNew').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Expect ((Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem.Name -eq 'TabQueryCompose') 'New does not open composer'
  (Get-DomeniaControl 'BtnQueryRun').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Expect ((Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem.Name -eq 'TabQueryResults') 'Run does not open results'
 }
 Case 'Returning to the already selected workshop refreshes only its current Fleet scope label' {
  $oldFleet=$script:FleetScopeDn;$oldBranch=$script:SelectedBranchDn
  try{
   $script:FleetScopeDn='OU=Atelier-A,DC=example,DC=invalid';$script:SelectedBranchDn='OU=Recherche-A,DC=example,DC=invalid'
   (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
   Show-DomeniaQueryWorkshop;$script:Window.UpdateLayout()
   Expect ((Get-DomeniaControl 'DomeniaQueryView').IsVisible -and (Get-DomeniaControl 'LblQueryScope').Text.Contains('OU=Atelier-A,')) 'Initial workshop scope absent'
   (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch';$script:Window.UpdateLayout()
   Expect (-not (Get-DomeniaControl 'DomeniaQueryView').IsVisible -and (Get-DomeniaControl 'ApplicationToolTabs').SelectedItem.Name -eq 'WsQueryWorkshop') 'Fixture did not hide the selected inner tab'
   $script:FleetScopeDn='OU=Atelier-B,DC=example,DC=invalid';$script:SelectedBranchDn='OU=Recherche-B,DC=example,DC=invalid'
   $route=$script:DomeniaQueryReturnRoute;$inner=$script:DomeniaQueryReturnInner;$tab=$script:DomeniaQueryReturnTab;$returnFocus=$script:DomeniaQueryReturnFocus
   $recipe=$script:DomeniaQueryState.Recipe|ConvertTo-Json -Depth 10 -Compress;$before=$script:FixtureTasks.Count
   # Direct outer-tab selection reproduces the sidebar route; the inner SelectionChanged does not run.
   (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabApplicationTools';$script:Window.UpdateLayout()
   $label=[string](Get-DomeniaControl 'LblQueryScope').Text
   Expect ((Get-DomeniaControl 'DomeniaQueryView').IsVisible -and $label.Contains('OU=Atelier-B,') -and -not $label.Contains('Recherche-B')) 'Visible workshop retained an old scope or adopted Search scope'
   Expect ($script:FixtureTasks.Count -eq $before -and ($script:DomeniaQueryState.Recipe|ConvertTo-Json -Depth 10 -Compress) -eq $recipe) 'Visibility refreshed data or changed the draft'
   Expect ($script:DomeniaQueryReturnRoute -ceq $route -and $script:DomeniaQueryReturnInner -ceq $inner -and $script:DomeniaQueryReturnTab -ceq $tab -and [object]::ReferenceEquals($script:DomeniaQueryReturnFocus,$returnFocus)) 'Visibility rewrote the return route/focus'
   $focused=[Windows.Input.Keyboard]::FocusedElement;Update-DomeniaQueryScopeLabel
   Expect ([object]::ReferenceEquals([Windows.Input.Keyboard]::FocusedElement,$focused)) 'Scope label stole keyboard focus'
   (Get-DomeniaControl 'BtnQueryBack').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   Expect ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'WsSearch') 'Visibility broke the original return route'
  }finally{$script:FleetScopeDn=$oldFleet;$script:SelectedBranchDn=$oldBranch;Update-DomeniaQueryScopeLabel}
 }
 Case 'Catalog is exhaustive, locally searchable and prepares a field without changing a recipe' {
  $entries=@(Get-DomeniaQueryCatalog);$fields=@(Get-DomeniaQueryFields)
  # The probe catalog grows with documented projections (points 81-99): the expectation follows it, never a frozen count.
  $probeCount=@(Get-DomeniaProbeCatalog).Count
  Expect (($entries.Count -eq $fields.Count) -and ($entries.Count -eq (27+$probeCount))) 'Catalog field coverage differs from engine'
  Expect (@(Compare-Object @($fields.Id|Sort-Object) @($entries.Id|Sort-Object)).Count -eq 0) 'Catalog identifiers differ'
  $accent=@(Find-DomeniaQueryCatalogEntries -Entries $entries -Text 'mémoire');$plain=@(Find-DomeniaQueryCatalogEntries -Entries $entries -Text 'MEMOIRE')
  Expect ($accent.Count -gt 0 -and @(Compare-Object @($accent.Id) @($plain.Id)).Count -eq 0) 'Accent/case-insensitive search differs'
  Expect (@(Find-DomeniaQueryCatalogEntries -Entries $entries -Text 'Win32_QuickFixEngineering').Count -eq 1) 'Technical class lookup differs'
  Expect (@(Find-DomeniaQueryCatalogEntries -Entries $entries -SourceId Probe).Count -eq $probeCount) 'Probe source filter differs'
  $category=$entries[0].Category;$categoryRows=@(Find-DomeniaQueryCatalogEntries -Entries $entries -Category $category)
  Expect ($categoryRows.Count -gt 0 -and @($categoryRows|Where-Object{$_.Category -ne $category}).Count -eq 0) 'Category filter differs'
  $beforeTasks=$script:FixtureTasks.Count;$beforeRecipe=$script:DomeniaQueryState.Recipe|ConvertTo-Json -Depth 10 -Compress
  (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryCatalog'
  $grid=Get-DomeniaControl 'DgQueryCatalog';$search=Get-DomeniaControl 'TxtQueryCatalogSearch'
  Expect ($grid.Items.Count -eq $entries.Count) 'Real WPF catalog not filled'
  $search.Text='zzzz_no_synthetic_match';Expect ($grid.Items.Count -eq 0 -and -not (Get-DomeniaControl 'BtnQueryCatalogUse').IsEnabled) 'Empty catalog keeps selectable stale row'
  $search.Text='diskFreePercent';Expect ($grid.Items.Count -eq 1) 'Local field lookup not unique'
  (Get-DomeniaControl 'BtnQueryCatalogUse').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Expect ((Get-DomeniaControl 'CmbQueryField').SelectedItem.Id -eq 'diskFreePercent' -and (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem.Name -eq 'TabQueryCompose') 'Use does not prepare composer field'
  Expect ((Get-DomeniaControl 'TxtQueryValue').Text -eq '' -and $null -ne (Get-DomeniaControl 'CmbQueryOperator').SelectedItem) 'Prepared value/operator wrong'
  Expect (($script:DomeniaQueryState.Recipe|ConvertTo-Json -Depth 10 -Compress) -eq $beforeRecipe -and $script:FixtureTasks.Count -eq $beforeTasks) 'Catalog changed conditions or launched collection'
  $search.Text=''
 }
 Case 'Ready library filters models and saved recipes locally and loads only after Use' {
  $q=$script:DomeniaQueryState;$oldSaved=$q.Saved;$oldRecipe=$q.Recipe;$before=$script:FixtureTasks.Count
  try{
   $recipe=New-DomeniaQueryRecipe -Id 'fixture.library' -Name 'Mémoire de test' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=8})
   $q.Saved=@($recipe);Update-DomeniaQueryLibraryControls
   (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryLibrary'
   $grid=Get-DomeniaControl 'DgQueryLibrary';$source=Get-DomeniaControl 'CmbQueryLibrarySource';$category=Get-DomeniaControl 'CmbQueryLibraryCategory';$search=Get-DomeniaControl 'TxtQueryLibrarySearch'
   $templateCount=@(Get-DomeniaQueryTemplates).Count
   Expect ($templateCount -ge 150 -and $grid.Items.Count -eq ($templateCount+1)) 'Ready library model count differs'
   $source.SelectedIndex=1;Expect ($grid.Items.Count -eq $templateCount) 'Template filter differs'
   $category.SelectedIndex=1;Expect ($grid.Items.Count -gt 0 -and @($grid.ItemsSource|Where-Object{$_.Category -ne [string]$category.SelectedItem.Id}).Count -eq 0) 'Category filter differs'
   $category.SelectedIndex=0;$source.SelectedIndex=2;$search.Text='MEMOIRE'
   Expect ($grid.Items.Count -eq 1 -and $grid.Items[0].Id -eq 'fixture.library') 'Saved/accent-insensitive filter differs'
   $grid.SelectedIndex=0
   Expect ((Get-DomeniaControl 'BtnQueryLibraryUse').IsEnabled -and $q.Recipe.Id -eq $oldRecipe.Id) 'Selection prematurely loads recipe'
   (Get-DomeniaControl 'BtnQueryLibraryUse').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   Expect ($q.Recipe.Id -eq $recipe.Id -and @($q.Recipe.Clauses).Count -eq 1 -and $q.Recipe.Clauses[0].Field -eq 'ramGB' -and (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem.Name -eq 'TabQueryCompose') 'Use does not load template into composer'
   $search.Text='zzzz_no_synthetic_match';Expect ($grid.Items.Count -eq 0 -and -not (Get-DomeniaControl 'BtnQueryLibraryUse').IsEnabled) 'Empty library keeps stale selection'
   Expect ($script:FixtureTasks.Count -eq $before) 'Library dispatched a worker'
  }finally{
   $q.Saved=$oldSaved;Set-DomeniaQueryDraft $oldRecipe
   (Get-DomeniaControl 'TxtQueryLibrarySearch').Text='';(Get-DomeniaControl 'CmbQueryLibrarySource').SelectedIndex=0;(Get-DomeniaControl 'CmbQueryLibraryCategory').SelectedIndex=0
   Update-DomeniaQueryLibraryControls
  }
 }
 Case 'Search selector unifies LDAP and local recipes without implicit execution' {
  $beforeTasks=$script:FixtureTasks.Count;$oldBranch=$script:SelectedBranchDn;$oldSettings=$script:SettingsFixture.Clone()
  try{
   $script:SelectedBranchDn='OU=Recherche,DC=example,DC=invalid'
   $saved=New-DomeniaQueryRecipe -Id 'fixture.searchselector' -Name 'Mémoire sélectionnée'
   $script:SettingsFixture['Query.Library']=ConvertTo-DomeniaQueryLibraryJson @($saved)
   (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
   Initialize-DomeniaSearchQuerySelector
   $combo=Get-DomeniaControl 'CmbWorkView';$filter=Get-DomeniaControl 'TxtSearchQueryFilter';$favorites=Get-DomeniaControl 'ChkSearchQueryFavorites'
   Expect ($combo.Items.Count -eq 158 -and $combo.SelectedIndex -eq -1 -and -not (Get-DomeniaControl 'BtnWorkView').IsEnabled) 'Unified catalog count or empty initial selection differs'
   $combo.SelectedItem=@($combo.Items|Where-Object Id -eq 'ad:disabled')[0]
   Expect ((Get-DomeniaControl 'LblSearchQueryDetails').Text -like '*Annuaire en direct*Utilisateurs*OU=Recherche*') 'AD source, type or Search OU not visible'
   Expect (-not (Get-DomeniaControl 'CmbSearchQueryResult').IsEnabled -and (Get-DomeniaControl 'CmbSearchQueryResult').Visibility -eq 'Collapsed') 'Unknown selection offered for LDAP view'
   $filter.Text='MEMOIRE SELECTIONNEE'
   Expect ($combo.Items.Count -eq 1 -and $combo.SelectedIndex -eq -1) 'Local text filter retains hidden former selection'
   $combo.SelectedIndex=0
   Expect ((Get-DomeniaControl 'CmbSearchQueryResult').IsEnabled -and (Get-DomeniaControl 'CmbSearchQueryResult').Visibility -eq 'Visible' -and (Get-DomeniaControl 'LblSearchQueryDetails').Text -like '*Base locale*Postes*') 'Local source/type/result selection missing'
   $base=$script:Conn.BaseDn
   try{$script:Conn.BaseDn='';Update-DomeniaSearchQueryDetails;Expect (-not (Get-DomeniaControl 'BtnWorkView').IsEnabled -and (Get-DomeniaControl 'LblSearchQueryDetails').Text -like '*Connectez-vous*') 'Selector fails or executes without a session'}finally{$script:Conn.BaseDn=$base;Update-DomeniaSearchQueryDetails}
   (Get-DomeniaControl 'BtnSearchQueryFavorite').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   $filter.Text='';$favorites.IsChecked=$true
   Expect ($combo.Items.Count -eq 1 -and $combo.Items[0].Id -eq 'local:fixture.searchselector') 'Favorite persisted/filter failed'
   $combo.SelectedIndex=0
   (Get-DomeniaControl 'BtnSearchQueryWorkshop').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   Expect ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabApplicationTools' -and (Get-DomeniaControl 'ApplicationToolTabs').SelectedItem.Name -eq 'WsQueryWorkshop') 'Search edit did not open Tools/Workshop'
   Expect ($script:DomeniaQueryState.Recipe.Id -eq 'fixture.searchselector' -and (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem.Name -eq 'TabQueryCompose') 'Edit did not load selected recipe'
   (Get-DomeniaControl 'BtnQueryBack').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   Expect ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'WsSearch') 'Search edit return failed'
   $script:ActiveSearchViewId='local:fixture.searchselector';$script:SearchQueryRun=[pscustomobject]@{Id=$script:ActiveSearchViewId};$generation=[int]$script:GlobalSearchGeneration
   (Get-DomeniaControl 'BtnQueryClearSearch').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   Expect ($null -eq $script:SearchQueryRun -and -not $script:ActiveSearchViewId -and [int]$script:GlobalSearchGeneration -gt $generation -and $combo.SelectedIndex -eq -1) 'Real clear button did not invalidate local query'
   Expect ($script:FixtureTasks.Count -eq $beforeTasks) 'Selection/filter/favorite/edit executed a query or collection'
  }finally{$script:SelectedBranchDn=$oldBranch;$script:SettingsFixture=$oldSettings;(Get-DomeniaControl 'TxtSearchQueryFilter').Text='';(Get-DomeniaControl 'ChkSearchQueryFavorites').IsChecked=$false;Update-DomeniaWorkViewList}
 }
 Case 'Selected computer preview and widget use the shared workshop through actual buttons' {
  $oldSelected=$script:SelectedObject;$oldRecipe=$script:DomeniaQueryState.Recipe;$oldSaved=$script:DomeniaQueryState.Saved;$before=$script:FixtureTasks.Count
  try{
   $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-FIXTURE';DN='CN=PC-FIXTURE,OU=Postes,DC=example,DC=invalid';Safety=[pscustomobject]@{Guid='00000000-0000-4000-8000-000000000042'};Entry=[pscustomobject]@{Properties=@{userAccountControl=@(4096)}}}
   $recipe=New-DomeniaQueryRecipe -Id 'fixture.wpf-computer' -Name 'Compte actif du poste'
   $recipe.Clauses=@([pscustomobject]@{Field='active';Operator='Equal';Value=$true})
   Set-DomeniaQueryDraft $recipe
   Show-DomeniaComputerQueryWorkshop
   Expect ((Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name -eq 'TabApplicationTools' -and (Get-DomeniaControl 'ApplicationToolTabs').SelectedItem.Name -eq 'WsQueryWorkshop' -and (Get-DomeniaControl 'CmbQueryWidgetDestination').SelectedItem.Tag -eq 'Computer') 'Computer route/destination wrong'
   (Get-DomeniaControl 'BtnQueryPreviewComputer').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   Expect ((Get-DomeniaControl 'LblQueryComputerPreview').Text -like 'PC-FIXTURE : correspond*') 'Real preview button did not evaluate the selected computer'
   $visual=Get-DomeniaControl 'CmbQueryWidgetVisual';$visual.SelectedItem=@($visual.Items|Where-Object{$_.Tag -eq 'Pie'})[0]
   (Get-DomeniaControl 'BtnQueryWidget').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   $items=@(Get-DomeniaBoardLayout Computer|Where-Object{$_.Source -eq 'Query' -and $_.Key -eq 'fixture.wpf-computer'})
   Expect ($items.Count -eq 1 -and $items[0].Visual -eq 'Pie') 'Real widget button did not persist Computer pie'
   Expect ($script:FixtureTasks.Count -eq $before) 'Computer preview/widget dispatched a worker'
  }finally{
   $script:SelectedObject=$oldSelected;$script:DomeniaQueryState.Saved=$oldSaved;Set-DomeniaQueryDraft $oldRecipe
   $script:SettingsFixture.Remove('Dashboard.Computer.Layout');$script:SettingsFixture.Remove('Query.Library');$script:DomeniaComputerQueryRecords=$null
   (Get-DomeniaControl 'CmbQueryWidgetDestination').SelectedIndex=0
  }
 }
 Case 'Zoom has bounded persistent steps and controls outside the transformed shell' {
  Initialize-DomeniaUiZoom;Initialize-DomeniaUiZoom
  (Get-DomeniaControl 'BtnUiZoomIn').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Expect ($script:DomeniaUiZoomPercent -eq 110 -and $script:SettingsFixture['Ui.ZoomPercent'] -eq 110) 'Zoom step/persistence or duplicate handler'
  foreach($percent in @(80,100,150)){
   Set-DomeniaUiZoom $percent;$script:Window.UpdateLayout()
   $shell=Get-DomeniaControl 'UxShellGrid';$reset=Get-DomeniaControl 'BtnUiZoomReset'
   Expect ($shell.LayoutTransform.ScaleX -eq $percent/100.0) 'Wrong scale'
   Expect ($reset.IsVisible -and $reset.ActualHeight -gt 0 -and -not $shell.IsAncestorOf($reset)) 'Zoom controls clipped/scaled'
  }
  Set-DomeniaUiZoom 300;Expect (-not (Get-DomeniaControl 'BtnUiZoomIn').IsEnabled) 'Upper bound not guarded'
  Set-DomeniaUiZoom 20;Expect (-not (Get-DomeniaControl 'BtnUiZoomOut').IsEnabled) 'Lower bound not guarded'
  (Get-DomeniaControl 'BtnUiZoomReset').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Expect ($script:DomeniaUiZoomPercent -eq 100) 'Reset failed'
  $settings=ConvertTo-DomeniaExperienceSettings -Values @{'Ui.ZoomPercent'=140} -Defaults (Get-DomeniaDefaultSettings)
  Expect ($settings['Ui.ZoomPercent'] -eq 140) 'Persisted zoom lost by settings sanitation'
 }
 Case 'Tools use separate tabs and whole-domain shortcut buttons are absent' {
  foreach($name in @('TabIndexUpdate','TabIndexData','TabIndexStorage')){Expect ($null -ne (Get-DomeniaControl $name)) ('Missing tab '+$name)}
  foreach($name in @('BtnFleetScopeReset','BtnIndexScopeReset','BtnIndexBuild','BtnIndexWalk','BtnDashRoot','BtnIndexRefresh','BtnSearchAllDomain')){Expect ($null -eq (Get-DomeniaControl $name)) ('Global shortcut remains '+$name)}
  Expect (@(Get-DomeniaLogicalControls (Get-DomeniaControl 'TabIndexStorage').Content|Where-Object{[object]::ReferenceEquals($_,(Get-DomeniaControl 'ExpStorageMaintenance'))}).Count -eq 1) 'Storage maintenance not routed to storage tab'
 }
 Case 'OU tree loads direct branches, filters with context, restores navigation and verifies GUID' {
  $script:FixtureTasks.Clear();$script:FixtureStops=[Collections.Generic.List[string]]::new()
  function script:Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason)$script:FixtureStops.Add([string]$Id)}
  function script:Show-DomeniaEmbeddedWindow {param($Window)
   $record=Get-DomeniaSurfaceRecord $Window;$record.Embedded=$true
   $Window.ShowInTaskbar=$false;$Window.Show();$Window.UpdateLayout()
   try{
    & $record.Ready
    $call=$script:FixtureTasks[$script:FixtureTasks.Count-1];$owner=$call.State.Owner;$tree=$owner.Tree
    Expect ($tree -is [Windows.Controls.TreeView] -and $call.Payload.Mode -eq 'Children' -and $call.Payload.DN -eq $script:Conn.BaseDn) 'Opening does not read direct root branches'
    Expect ([Windows.Controls.ScrollViewer]::GetVerticalScrollBarVisibility($tree) -eq 'Visible' -and [Windows.Controls.VirtualizingPanel]::GetIsVirtualizing($tree) -and $tree.MaxHeight -le 520) 'Tree scrolling/virtualization not bounded'
    $base=$script:Conn.BaseDn
    $alpha=[pscustomobject]@{Type='OU';Name='Alpha';DN=('OU=Alpha,'+$base);Guid='00000000-0000-4000-8000-000000000001'}
    $zulu=[pscustomobject]@{Type='OU';Name='Zulu';DN=('OU=Zulu,'+$base);Guid='00000000-0000-4000-8000-000000000002'}
    $container=[pscustomobject]@{Type='Conteneur';Name='Users';DN=('CN=Users,'+$base);Guid='00000000-0000-4000-8000-000000000003'}
    Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@($zulu,$container,$alpha);RequestId=$call.State.RequestId;Verified=$false;Capped=$true}) $call.State
    $root=$tree.Items[0]
    Expect ($root.Items.Count -eq 3 -and ($root.Items.Header -join ',') -eq 'Alpha,Users,Zulu' -and $owner.Status.Text -like '*Limite atteinte*') 'Children not sorted or cap warning missing'
    $root.IsSelected=$true;Expect (-not $owner.Accept.IsEnabled) 'Domain root selectable'
    $root.Items[1].IsSelected=$true;Expect (-not $owner.Accept.IsEnabled) 'Container selectable as an OU'
    $alphaNode=$root.Items[0];$alphaNode.IsExpanded=$true;$Window.UpdateLayout()
    $childCall=$script:FixtureTasks[$script:FixtureTasks.Count-1]
    Expect ($childCall.Payload.Mode -eq 'Children' -and $childCall.Payload.DN -eq $alpha.DN) 'Expansion does not request OneLevel children'
    Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@();RequestId=$call.State.RequestId;Verified=$false;Capped=$false}) $call.State
    Expect ($root.Items.Count -eq 3) 'Late replaced response changed tree'
    $child=[pscustomobject]@{Type='OU';Name='Postes';DN=('OU=Postes,'+$alpha.DN);Guid='00000000-0000-4000-8000-000000000004'}
    Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@($child,$zulu);RequestId=$childCall.State.RequestId;Verified=$false;Capped=$false}) $childCall.State
    Expect ($alphaNode.Items.Count -eq 1 -and $alphaNode.Items[0].Tag.DN -eq $child.DN) 'Expansion accepted a non-child row'
    $owner.Box.Text='Postes';$owner.Go.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    $search=$script:FixtureTasks[$script:FixtureTasks.Count-1]
    Expect ($search.Payload.Mode -eq 'Search') 'Search does not use its explicit mode'
    Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@($child);RequestId=$search.State.RequestId;Verified=$false;Capped=$false}) $search.State
    $context=$tree.Items[0].Items[0];$context.IsSelected=$true
    Expect ($context.Tag.Context -and -not $owner.Accept.IsEnabled) 'Context-only ancestor selectable'
    $context.Items[0].IsSelected=$true
    Expect ($owner.Accept.IsEnabled -and $owner.Path.Text -eq $child.DN -and $owner.Path.IsReadOnly) 'Search OU cannot be chosen with visible full DN'
    $count=$script:FixtureTasks.Count;$owner.Box.Text=''
    Expect ([object]::ReferenceEquals($tree.Items[0],$root) -and $script:FixtureTasks.Count -eq $count) 'Clearing search does not restore cached navigation'
    $alphaNode.Items[0].IsSelected=$true
    $owner.Accept.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    $verify=$script:FixtureTasks[$script:FixtureTasks.Count-1]
    Expect ($verify.Payload.Verify -and $verify.State.Guid -eq $child.Guid -and $verify.Payload.DN -eq $child.DN) 'Choice not verified by DN and GUID'
    $epoch=$verify.State.Epoch;$verify.State.Epoch=0
    Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@($child);RequestId=$verify.State.RequestId;Verified=$true;Capped=$false}) $verify.State
    Expect ($null -eq $owner.Selected) 'Previous session verification accepted'
    $verify.State.Epoch=$epoch
    Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@($child);RequestId=$verify.State.RequestId;Verified=$true;Capped=$false}) $verify.State
    Expect ($owner.Selected.Guid -eq $child.Guid) 'Verified identity not returned'
    return $true
   }finally{if($Window.IsVisible){$Window.Close()}}
  }
  $selected=Show-DomeniaInlinePicker -Kind OU -Title 'Fixture' -Prompt 'Synthetic only'
  Expect ($selected.Guid -eq '00000000-0000-4000-8000-000000000004') 'Modal result lost'
  $late=$script:FixtureTasks[$script:FixtureTasks.Count-1];$chosen=$late.State.Owner.Selected
  Complete-DomeniaEmbeddedLookup ([pscustomobject]@{Rows=@();RequestId=$late.State.RequestId;Verified=$true;Capped=$false}) $late.State
  Expect ([object]::ReferenceEquals($chosen,$late.State.Owner.Selected) -and $late.State.Owner.Closed) 'Closed picker accepted a late callback'
 }
 Case 'Freshness uses successful covering OU and excludes child, sibling, malformed and partial sync' {
  $base='DC=example,DC=invalid';$ou='OU=Postes,'+$base;$now=[datetimeoffset]::Parse('2026-10-13T00:00:00Z').UtcDateTime
  $states=@{
   directory=[pscustomobject]@{scope='directory';base_dn=$base;last_sync='2026-10-12T08:00:00Z';details='complete'}
   ou=[pscustomobject]@{scope=('ou:'+$ou);base_dn=$ou;last_sync='2026-10-12T14:00:00Z';details='complete;depth=Subtree'}
   child=[pscustomobject]@{scope=('ou:OU=Enfant,'+$ou);base_dn=('OU=Enfant,'+$ou);last_sync='2026-10-12T15:00:00Z';details='complete;depth=Subtree'}
   sibling=[pscustomobject]@{scope=('ou:OU=Autre,'+$base);base_dn=('OU=Autre,'+$base);last_sync='2026-10-12T16:00:00Z';details='complete;depth=Subtree'}
   partial=[pscustomobject]@{scope=('attempt:ou:'+$ou);base_dn=$ou;last_sync='2026-10-12T17:00:00Z';details='partial;depth=Subtree'}
  }
  $f=Get-DomeniaFleetFreshness $ou $base $states -NowUtc $now;Expect ($f.SourceDn -eq $ou -and $f.At.Hour -eq 14 -and $f.Partial) 'OU success or partial warning wrong'
  $f=Get-DomeniaFleetFreshness ('OU=Child,'+$ou) $base $states -NowUtc $now;Expect ($f.At.Hour -eq 14) 'Parent coverage not inherited'
  $f=Get-DomeniaFleetFreshness '' $base $states -NowUtc $now;Expect ($f.At.Hour -eq 8 -and -not $f.Partial) 'OU pass rejuvenates whole domain'
  $states.legacy=[pscustomobject]@{scope=('ou:'+$base);base_dn=$base;last_sync='2026-10-12T18:00:00Z';details='complete'}
  $f=Get-DomeniaFleetFreshness $ou $base $states -NowUtc $now;Expect ($f.At.Hour -eq 14) 'Legacy root OneLevel read rejuvenates descendants'
  $f=Get-DomeniaFleetFreshness '' $base $states -NowUtc $now;Expect ($f.At.Hour -eq 8) 'Legacy root OneLevel read replaces full directory success'
  $states.ou.last_sync='broken';$f=Get-DomeniaFleetFreshness $ou $base $states -NowUtc $now;Expect ($f.At.Hour -eq 8) 'Malformed date accepted'
 }
 Case 'Workshop refresh invalidates prepared records and receives a fresh local snapshot' {
  $script:FixtureTasks.Clear();$script:AsyncJobs=@{};$script:FleetJobId='';$script:FleetPendingKey='';$script:FleetScopeDn='OU=Postes,DC=example,DC=invalid'
  $script:DatabaseScopedPath='fixture-only-no-file.db';$script:SelectedObject=$null
  Show-DomeniaQueryWorkshop
  $q=$script:DomeniaQueryState;$q.Records=[object[]]@('stale');$q.SnapshotKey='stale';$q.At=[datetime]::UtcNow;$q.Result=[pscustomobject]@{Matched=99};$generation=$q.Generation
  Request-DomeniaFleetRefresh -Force
  Expect ($null -eq $q.Records -and $null -eq $q.Result -and $q.Generation -gt $generation) 'Stale query result survives forced refresh'
  Expect ($script:FixtureTasks.Count -eq 1 -and $script:FixtureTasks[0].OperationId -eq 'LocalIndexRead') 'Workshop does not refresh its visible OU'
  $call=$script:FixtureTasks[0]
  Expect ($call.Payload.Action -eq 'FleetStats' -and $call.Payload.Scope -eq $script:FleetScopeDn) 'Refresh scope or operation wrong'
  $result=[pscustomobject]@{Busy=$false;Links=0;LinkSources=@();Types=@();Machines=@();Groups=@();Presence=@();Parents=@();History=@();Coverage=[pscustomobject]@{FactsFresh=0;FactsStale=0;BitLockerRead=0;BitLockerAt=''}}
  $result|Add-Member -NotePropertyName Board -NotePropertyValue (Get-DomeniaFleetBoardData -Result $result -Scope $script:FleetScopeDn -Subtree $true -Lifecycle (Get-DomeniaWindowsLifecycleTable))
  Complete-DomeniaFleetDashboard -Result $result -State $call.State
  if($null -ne $q.Timer){$q.Timer.Stop()}
  Start-DomeniaQueryEvaluation
  $queryCall=$script:FixtureTasks[$script:FixtureTasks.Count-1]
  Expect ($queryCall.OperationId -eq 'LocalQuery') 'Updated workshop snapshot not evaluated locally'
  $Payload=$queryCall.Payload;$queryResult=& ([scriptblock]::Create([string]$queryCall.Code))
  Complete-DomeniaQueryEvaluation -Result $queryResult -State $queryCall.State
  Expect ($null -ne $q.Result -and $q.Result.Matched -eq 0 -and @($q.Records).Count -eq 0 -and $q.SnapshotKey -ne 'stale') 'New empty snapshot does not replace stale records'
  $script:DatabaseScopedPath=''
 }
}finally{if($null -ne $script:DomeniaQueryState -and $null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()};$script:Window.Close()}
$failed=@($script:Results|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{PowerShell=$PSVersionTable.PSVersion.ToString();Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Synthetic=$true;ADAccessed=$false;Passed=($script:Results.Count-$failed);Failed=$failed;Assertions=$script:Checks;Results=$script:Results.ToArray()}
$json=$report|ConvertTo-Json -Depth 6;if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))};$json
if($failed){exit 1}
