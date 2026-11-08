#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path $PSScriptRoot -Parent;$script:RootDir=$wad
. (Join-Path $wad 'Domenia-Modules.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse errors'}
foreach($name in @('Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaEffectiveWorkerResult','Get-DomeniaDefaultSettings','Get-DomeniaXamlControlNames','Set-DomeniaContextHint')){
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
$xaml=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot);$script:Window=[Windows.Markup.XamlReader]::Parse($xaml);foreach($name in @(Get-DomeniaXamlControlNames -XamlText $xaml)){$control=$script:Window.FindName($name);if($null -ne $control){$script:Ctrl[$name]=$control}};$script:Window.Width=1280;$script:Window.Height=720;$script:Window.ShowInTaskbar=$false
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
  $beforeTasks=$script:FixtureTasks.Count;$oldBranch=$script:SelectedBranchDn;$oldSettings=$script:SettingsFixture.Clone();$oldTemplates=$script:DomeniaQueryTemplateRows;$oldPreparation=$script:DomeniaQueryTemplatePreparation
  try{
   $script:SelectedBranchDn='OU=Recherche,DC=example,DC=invalid'
   $saved=New-DomeniaQueryRecipe -Id 'fixture.searchselector' -Name 'Mémoire sélectionnée'
   $script:SettingsFixture['Query.Library']=ConvertTo-DomeniaQueryLibraryJson @($saved)
   (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
   # Point 61: the initial list holds the AD views and the saved recipes; the delivered models join it once the
   # QueryLibrary worker has prepared them (its result is simulated here, no worker runs in this fixture).
   $script:DomeniaQueryTemplateRows=$null;$script:DomeniaQueryTemplatePreparation=$null
   Initialize-DomeniaSearchQuerySelector
   $combo=Get-DomeniaControl 'CmbWorkView';$filter=Get-DomeniaControl 'TxtSearchQueryFilter';$favorites=Get-DomeniaControl 'ChkSearchQueryFavorites'
   $initialCount=@(Get-DomeniaWorkViews).Count+@(Get-DomeniaSavedQueryRecipes).Count
   Expect ($combo.Items.Count -eq $initialCount -and $combo.SelectedIndex -eq -1 -and -not (Get-DomeniaControl 'BtnWorkView').IsEnabled) 'Initial catalog must list the AD views and saved recipes only, without selection'
   Set-DomeniaPreparedQueryTemplateRows -Rows @(Get-DomeniaQueryTemplates|ForEach-Object{[pscustomobject]@{SourceId='Template';Recipe=$_}});Update-DomeniaWorkViewList
   Expect ($combo.Items.Count -eq ($initialCount+@(Get-DomeniaQueryTemplates).Count) -and $combo.SelectedIndex -eq -1) 'Prepared delivered models are missing from the unified catalog'
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
  }finally{$script:SelectedBranchDn=$oldBranch;$script:SettingsFixture=$oldSettings;$script:DomeniaQueryTemplateRows=$oldTemplates;$script:DomeniaQueryTemplatePreparation=$oldPreparation;(Get-DomeniaControl 'TxtSearchQueryFilter').Text='';(Get-DomeniaControl 'ChkSearchQueryFavorites').IsChecked=$false;Update-DomeniaWorkViewList}
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

 # UI-11: the help panel starts closed, its useful card comes first with the chapter of the guide, the static steps and
 # the reassurance left it, and a dot on « ? » marks the first launch only.
 Case 'UI-11 : panneau d aide ferme au depart, carte utile en tete, pastille au premier lancement seulement' {
  $defaults=Get-DomeniaDefaultSettings
  Expect (-not [bool]$defaults.UxHelpVisible) 'Aide ouverte par defaut'
  Expect ($defaults.Contains('UxHelpIntroSeen') -and -not [bool]$defaults.UxHelpIntroSeen) 'Preference de la pastille absente'
  [xml]$doc=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot);$ns=New-Object Xml.XmlNamespaceManager($doc.NameTable);$ns.AddNamespace('w','http://schemas.microsoft.com/winfx/2006/xaml/presentation');$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
  Expect ([string]$doc.SelectSingleNode("//w:ColumnDefinition[@x:Name='UxHelpColumn']",$ns).GetAttribute('Width') -eq '0') 'Colonne d aide ouverte avant le premier calcul'
  $cards=@($doc.SelectNodes("//w:Border[@x:Name='UxHelpPanel']//w:ScrollViewer/w:StackPanel/w:Border",$ns))
  Expect ($cards.Count -eq 3) ('Cartes du panneau : '+$cards.Count)
  Expect ($null -ne $cards[0].SelectSingleNode(".//*[@x:Name='LblContextTitle']",$ns) -and $null -ne $cards[0].SelectSingleNode(".//*[@x:Name='BtnUxHelpGuide']",$ns)) 'La carte « À quoi sert cet élément ? » n est pas en tete'
  Expect ([string]$cards[2].GetAttribute('Visibility') -eq 'Collapsed' -and $null -ne $cards[2].SelectSingleNode(".//*[@x:Name='BtnUxStep1']",$ns)) 'Etapes statiques encore affichees'
  Expect (-not $doc.OuterXml.Contains('Aucune action n'+[char]0x2019+'est lancée par ce panneau.')) 'Phrase de reassurance encore presente'
  Expect ($null -ne $cards[1].SelectSingleNode(".//*[@x:Name='BtnUxHelpAccounts']",$ns)) 'Lien vers les comptes perdu'
  $script:SettingsFixture=@{};$script:UxHelpVisible=$false
  Initialize-DomeniaUxHelpBadge
  $badge=Get-DomeniaControl 'UxHelpBadge';$toggle=Get-DomeniaControl 'BtnUxHelpToggle'
  Expect ($badge.Visibility -eq [Windows.Visibility]::Visible) 'Pastille absente au premier lancement'
  Expect ([Windows.Automation.AutomationProperties]::GetItemStatus($toggle) -ceq 'Nouveau : aide disponible') 'Pastille non annoncee'
  Expect ([bool]$script:SettingsFixture['UxHelpIntroSeen']) 'Premier lancement non retenu'
  Initialize-DomeniaUxHelpBadge
  Expect ($badge.Visibility -eq [Windows.Visibility]::Collapsed) 'Pastille revenue au lancement suivant'
  # The fixture window is 720 units high, a short screen (D006): the viewport is pinned so that each branch of
  # Switch-DomeniaUxHelp is the one tested.
  $realSize=${function:Get-DomeniaUxAvailableSize}
  try{
   $script:FixtureUxSize=[pscustomobject]@{Width=1600.0;Height=1000.0}
   Set-Item function:script:Get-DomeniaUxAvailableSize {return $script:FixtureUxSize}
   $script:SettingsFixture=@{};Initialize-DomeniaUxHelpBadge
   $script:UxShortScreen=$false;$script:UxLayoutSignature=''
   Switch-DomeniaUxHelp
   Expect (($badge.Visibility -eq [Windows.Visibility]::Collapsed) -and ([string][Windows.Automation.AutomationProperties]::GetItemStatus($toggle) -eq '')) 'Ouvrir l aide ne retire pas la pastille'
   Expect (([bool]$script:UxHelpVisible) -and ([bool]$script:SettingsFixture['UxHelpVisible'])) 'Ouverture de l aide non retenue'
   Switch-DomeniaUxHelp
   Expect (-not [bool]$script:UxHelpVisible) 'Fermeture de l aide non retenue'
   # Short screen: the help opens for the session only, and opening it removes the dot there too.
   $script:FixtureUxSize=[pscustomobject]@{Width=1600.0;Height=720.0}
   $script:SettingsFixture=@{};$script:UxHelpVisible=$false;$script:UxLayoutSignature='';Update-DomeniaUxLayout
   Expect (([bool]$script:UxShortScreen) -and (-not [bool]$script:UxShortHelpOpen)) 'Ecran court non reconnu'
   Initialize-DomeniaUxHelpBadge
   Expect ($badge.Visibility -eq [Windows.Visibility]::Visible) 'Pastille absente sur un ecran court'
   Switch-DomeniaUxHelp
   Expect (([bool]$script:UxShortHelpOpen) -and ((Get-DomeniaControl 'UxHelpPanel').Visibility -eq [Windows.Visibility]::Visible)) 'Aide non ouverte sur un ecran court'
   Expect (($badge.Visibility -eq [Windows.Visibility]::Collapsed) -and ([string][Windows.Automation.AutomationProperties]::GetItemStatus($toggle) -eq '')) 'Ouvrir l aide sur un ecran court ne retire pas la pastille'
   Expect ((-not [bool]$script:UxHelpVisible) -and (-not $script:SettingsFixture.ContainsKey('UxHelpVisible'))) 'Ecran court : le choix enregistre de l aide a change'
   Switch-DomeniaUxHelp
   Expect ((-not [bool]$script:UxShortHelpOpen) -and ($badge.Visibility -eq [Windows.Visibility]::Collapsed)) 'Pastille revenue a la fermeture de l aide'
  }finally{Set-Item function:script:Get-DomeniaUxAvailableSize $realSize;$script:UxShortScreen=$false;$script:UxShortHelpOpen=$false;$script:UxLayoutSignature=''}
 }
 Case 'UI-11 : chapitre du guide de la page et ouverture du PDF sur demande, sans fichier invente' {
  (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabDashboard'
  Update-DomeniaUxHelpGuide
  Expect ((Get-DomeniaControl 'LblUxHelpGuide').Text -ceq (Get-DomeniaHelpGuideChapter -Page 'TabDashboard').Text) 'Chapitre de l Accueil absent'
  (Get-DomeniaControl 'WorkspaceTabs').SelectedItem=Get-DomeniaControl 'WsSearch'
  Update-DomeniaUxHelpGuide
  Expect ((Get-DomeniaControl 'LblUxHelpGuide').Text -like 'Guide du technicien, chapitre 1 :*') 'Chapitre de Rechercher absent'
  $empty=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-guide-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory((Join-Path $empty 'wad'))
  $oldRoot=$script:RootDir
  try{
   $script:RootDir=Join-Path $empty 'wad'
   Open-DomeniaHelpGuide
   Expect ((Get-DomeniaControl 'LblContextTitle').Text -like '*introuvable') ('Guide absent non signale : '+(Get-DomeniaControl 'LblContextTitle').Text)
   Expect ((Get-DomeniaControl 'LblContextHint').Text.Contains('Domenia-1.0-Guide-technicien.pdf')) 'Emplacement du guide non indique'
   # The query workshop is an inner tab of Outils with its own chapter, in the administrator guide.
   Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'WsQueryWorkshop'
   Open-DomeniaHelpGuide
   Expect ((Get-DomeniaControl 'LblContextHint').Text.Contains('Domenia-1.0-Guide-administrateur.pdf')) 'Guide de l Atelier de requetes non designe'
  }finally{$script:RootDir=$oldRoot;Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue}
  Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'WsQueryWorkshop'
  Update-DomeniaUxHelpGuide
  $workshop=[string](Get-DomeniaHelpGuideChapter -Page 'WsQueryWorkshop').Text
  Expect (([string](Get-DomeniaControl 'LblUxHelpGuide').Text -ceq $workshop) -and $workshop.Contains('chapitre 8')) ('Chapitre de l Atelier de requetes : '+[string](Get-DomeniaControl 'LblUxHelpGuide').Text)
  (Get-DomeniaControl 'ApplicationToolTabs').SelectedItem=Get-DomeniaControl 'TabIndex'
  Update-DomeniaUxHelpGuide
  Expect ([string](Get-DomeniaControl 'LblUxHelpGuide').Text -ceq [string](Get-DomeniaHelpGuideChapter -Page 'TabApplicationTools').Text) 'Un autre outil garde le chapitre de l Atelier'
 }

 # PF-24 / UI-10: the catalogue is the only source of the help of its controls, a container has no tool tip and an
 # icon button a one-line tool tip; the help text stays the whole catalogue text.
 Case 'PF-24 : aides du catalogue seulement, aucune infobulle de conteneur, une ligne pour un bouton-icone' {
  [xml]$doc=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot);$x='http://schemas.microsoft.com/winfx/2006/xaml'
  $catalogue=@{};foreach($entry in @([IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-UX.help.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json)){$catalogue[[string]$entry.Name]=$entry}
  $carriers=@($doc.SelectNodes('//*')|Where-Object{$catalogue.ContainsKey([string]$_.GetAttribute('Name',$x)) -and ($_.HasAttribute('ToolTip') -or $_.HasAttribute('AutomationProperties.HelpText') -or $_.HasAttribute('ToolTipService.ShowOnDisabled'))}|ForEach-Object{$_.GetAttribute('Name',$x)})
  Expect ($carriers.Count -eq 0) ('Aides encore dans le XAML : '+(($carriers|Select-Object -First 8) -join ', '))
  foreach($style in @('DataGridColumnHeader','DataGridRow','TreeViewItem','MenuItem')){
   $setters=@($doc.SelectNodes("//*[local-name()='Window.Resources']/*[local-name()='Style'][@TargetType='$style']/*[local-name()='Setter'][@Property='ToolTip']"))
   Expect ($setters.Count -eq 0) ('Infobulle generique dans le style '+$style)
  }
  Initialize-DomeniaUxWindowHelp -Window $script:Window -XamlText (Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot))
  foreach($name in @('WorkspaceTabs','TxtUiLog','DgObjects','TvDirectory')){
   $c=Get-DomeniaControl $name
   Expect ($null -eq $c.ToolTip) ($name+' : infobulle sur un conteneur')
   Expect ([string][Windows.Automation.AutomationProperties]::GetHelpText($c) -ceq [string]$catalogue[$name].Text) ($name+' : aide du lecteur d ecran absente')
  }
  $help=Get-DomeniaControl 'BtnUxHelpToggle'
  Expect ([string]$help.ToolTip -ceq [string](Get-DomeniaHelpPresentation -Text ([string]$catalogue['BtnUxHelpToggle'].Text) -Role IconButton).ToolTip) ('Bouton-icone : '+[string]$help.ToolTip)
  Expect (-not ([string]$help.ToolTip).Contains('. ')) 'Infobulle du bouton-icone sur plusieurs phrases'
  Expect ([string][Windows.Automation.AutomationProperties]::GetHelpText($help) -ceq [string]$catalogue['BtnUxHelpToggle'].Text) 'Aide entiere du bouton-icone perdue'
  # The layout then names the state the button switches to, on one line too, help open and closed (as the application
  # shows it: Update-DomeniaUxLayout runs after the catalogue at start-up and on every resize).
  $realSize=${function:Get-DomeniaUxAvailableSize}
  try{
   Set-Item function:script:Get-DomeniaUxAvailableSize {return [pscustomobject]@{Width=1600.0;Height=1000.0}}
   foreach($open in @($true,$false)){
    $script:UxShortScreen=$false;$script:UxHelpVisible=$open;$script:UxHelpCompactOpen=$open;$script:UxLayoutSignature=''
    Update-DomeniaUxLayout
    $tip=[string]$help.ToolTip
    $wanted=$(if($open){'Réduire le panneau d'+[char]0x02BC+'aide.'}else{'Afficher le panneau d'+[char]0x02BC+'aide.'})
    Expect (($tip -ceq $wanted) -and (-not $tip.Contains('. '))) ('Bouton-icone apres la mise en page ('+$open+') : '+$tip)
    Expect ([string][Windows.Automation.AutomationProperties]::GetHelpText($help) -ceq [string]$catalogue['BtnUxHelpToggle'].Text) 'La mise en page remplace l aide entiere'
   }
  }finally{Set-Item function:script:Get-DomeniaUxAvailableSize $realSize;$script:UxHelpVisible=$false;$script:UxHelpCompactOpen=$false;$script:UxLayoutSignature=''}
  $subtree=Get-DomeniaControl 'ChkSubtree'
  Expect ([string]$subtree.ToolTip -ceq [string]$catalogue['ChkSubtree'].Text) 'Controle ordinaire : texte du catalogue'
  Expect ([Windows.Controls.ToolTipService]::GetShowOnDisabled($subtree)) 'ShowOnDisabled non pose par le catalogue'
  Restore-DomeniaUxBaseToolTip -Name 'DgObjects'
  Expect ($null -eq (Get-DomeniaControl 'DgObjects').ToolTip) 'La restauration redonne une infobulle au conteneur'
 }
}finally{if($null -ne $script:DomeniaQueryState -and $null -ne $script:DomeniaQueryState.Timer){$script:DomeniaQueryState.Timer.Stop()};$script:Window.Close()}
$failed=@($script:Results|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{PowerShell=$PSVersionTable.PSVersion.ToString();Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Synthetic=$true;ADAccessed=$false;Passed=($script:Results.Count-$failed);Failed=$failed;Assertions=$script:Checks;Results=$script:Results.ToArray()}
$json=$report|ConvertTo-Json -Depth 6;if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))};$json
if($failed){exit 1}
