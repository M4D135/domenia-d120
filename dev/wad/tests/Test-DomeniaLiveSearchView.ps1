#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[string]$Wad='',[Parameter(DontShow=$true)][switch]$ApplicationScope)
$ErrorActionPreference='Stop'
if(-not $Wad){$Wad=Split-Path $PSScriptRoot -Parent}
$Wad=[IO.Path]::GetFullPath($Wad)
# Domenia.exe launches -File Domenia-Start.ps1, which invokes & Domenia-Core.ps1.
# Preserve BOTH script scopes. A top-level -File test alone masks private-function lookup bugs.
if(-not $ApplicationScope){$global:LASTEXITCODE=0;& $PSCommandPath -Wad $Wad -ReportPath $ReportPath -ApplicationScope;exit $LASTEXITCODE}
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows WPF is required.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run powershell.exe -STA -File, not a global dot-source.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:Results=[Collections.Generic.List[object]]::new();$script:Assertions=0;$script:Logs=[Collections.Generic.List[object]]::new();$script:Snapshots=[Collections.Generic.List[object]]::new();$script:Waits=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Condition,[string]$Message)$script:Assertions++;if(-not $Condition){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
 $watch=[Diagnostics.Stopwatch]::StartNew();$failure='';try{& $Body}catch{$failure=$_.Exception.ToString()};$watch.Stop()
 $script:Results.Add([pscustomobject]@{Name=$Name;Passed=(-not $failure);Milliseconds=$watch.ElapsedMilliseconds;Error=$failure});Write-Host ($(if($failure){'FAIL '}else{'PASS '})+$Name)
}
# Critical regression condition: the real closed loader is dot-sourced at SCRIPT scope in a -File
# process. Exporting these functions globally or importing in AddScript's top scope masks the bug.
$script:RootDir=$Wad
. (Join-Path $Wad 'Domenia-Modules.ps1')
$script:LoadedFunctions=@(foreach($name in @('Initialize-DomeniaLive','Begin-DomeniaLiveSearch','Update-DomeniaLiveFilter','Add-DomeniaLiveRow','Invoke-DomeniaLiveTick','New-DomeniaTimer','Invoke-DomeniaTimerTick','Test-DomeniaSearchQueryRow','Get-DomeniaBoardSelectHandler','Show-DomeniaFleetWidgetDetails')){
 $command=Get-Command $name -CommandType Function -ErrorAction Stop
 [pscustomobject]@{Name=$name;File=$command.ScriptBlock.File}
})
# Import only inert core function definitions, preserving script scope. No application entry point.
$tokens=$null;$errors=$null;$core=Join-Path $Wad 'Domenia-Core.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Core parse error.'}
foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSearchMode','Get-DomeniaSearchText','Get-DomeniaSearchScope','Get-TypeLdapFilter','Get-GlobalSelectedTypeFilter','Test-DomeniaSearchStateCurrent','Apply-DomeniaPresenceFilter')){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw ('Missing core definition '+$name)}
 . ([scriptblock]::Create($nodes[0].Extent.Text))
}
# I/O boundaries only. Filtering, native query evaluation, identity checks, queue insertion,
# CollectionView, real timer protection and Dispatcher heartbeat are not substituted.
function Get-CfgValue {param($Section,$Key,$Default)return $Default}
function Get-DomeniaSetting {param($Key,$Default)return $Default}
function Initialize-DomeniaWinSqliteNative {return $true}
function Set-RowAssociationMetadata {param($Rows)}
function Start-DomeniaLiveBackgroundWork {}
# Storage is an inert I/O boundary here. This suite supplies committed-event fixtures
# directly; Test-DomeniaDirectoryStore covers the real producer/COMMIT ordering separately.
function New-DomeniaDirectoryReadPipe {
 param($Context,$ReadyQueue,$Search)
 return [pscustomobject]@{Context=$Context;Ready=$ReadyQueue;Search=$Search;Input=[Collections.Concurrent.ConcurrentQueue[object]]::new();Collector=[hashtable]::Synchronized(@{Started=$false;Done=$false;Final=$null;Error=''});Stop=$Search.Stop;Closed=$false;Completed=$false}
}
function Complete-DomeniaDirectoryReadPipe {param($Pipe,$Final,[string]$Error='')if($null -ne $Pipe){$Pipe.Completed=$true}}
function Update-DomeniaSearchMoreButton {param($Search)}
function Get-DomeniaPersistenceState {return [pscustomobject]@{Label='Synthetic fixture: disk persistence disabled'}}
function Write-AppLog {param($Text,$Level)$script:Logs.Add([pscustomobject]@{Level=[string]$Level;Text=[string]$Text})}
function Set-Status {param($Text,$Level)Write-AppLog $Text $Level}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:LastWorkspace=$Workspace;$script:LastInner=$Inner;$script:LastTab=$Tab}
function Start-DomeniaQueryEvaluation {$script:EvaluationRequests++}
function Start-UiTask {throw 'No background task, AD, CIM or network operation is authorized by this fixture.'}
$script:SessionEpoch=1;$script:GlobalSearchGeneration=1;$script:SearchMode='OU';$script:CurrentPresenceFilter='Tous'
$script:SelectedBranchDn='OU=Lab,DC=example,DC=invalid';$script:ActiveSearchViewId=''
$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';UseCredential=$false;Credential=$null;BindUser='';Connected=$false}
$script:ProcessIdentity='synthetic-fixture';$script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:WriteState='Idle';$script:DemoMode=$false
$script:Ctrl=@{};$script:Window=[Windows.Window]::new();$script:Window.Title='Domenia live search regression - synthetic data';$script:Window.Width=1000;$script:Window.Height=650
$panel=[Windows.Controls.StackPanel]::new();$script:Window.Content=$panel
$grid=[Windows.Controls.DataGrid]::new();$grid.AutoGenerateColumns=$true;$grid.IsReadOnly=$true;$grid.CanUserAddRows=$false;$grid.Height=420;$script:Ctrl.DgObjects=$grid;[void]$panel.Children.Add($grid)
foreach($name in @('TxtSuiteResultFilter','TxtBranchSearch','TxtGlobalSearch','TxtFleetQueryName','TxtFleetMachineFilter')){$script:Ctrl[$name]=[Windows.Controls.TextBox]::new()}
foreach($name in @('LblSuiteResultCount','LblBranchCount','LblLiveState','LblSearchQuery','LblQueryStatus','LblQuerySegment')){$script:Ctrl[$name]=[Windows.Controls.TextBlock]::new()}
foreach($name in @('CmbQueryJunction','CmbQueryGroupField','CmbFleetMachineState','CmbQueryResult')){$script:Ctrl[$name]=[Windows.Controls.ComboBox]::new()}
$script:Window.Show()
$script:Ids=@('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444')
function New-FixtureEvent {param([string]$Name,[string]$Guid,[string]$Type='Machine')
 [pscustomobject]@{Kind='Row';DataSource='SQLite';ObservedUtc=[datetime]::UtcNow.ToString('o');Row=[pscustomobject]@{Type=$Type;Name=$Name;Guid=$Guid;DN=('CN='+$Name+',OU=Lab,DC=example,DC=invalid');Login=$Name;UPN='';Description='Synthetic regression fixture';State='Actif';OS='Windows 11'}}
}
function Pump-Fixture {param([int]$Milliseconds=550)
 $frame=[Windows.Threading.DispatcherFrame]::new();$watch=[Windows.Threading.DispatcherTimer]::new();$watch.Interval=[timespan]::FromMilliseconds($Milliseconds);$watch.Tag=$frame
 $watch.Add_Tick({param($sender,$e)$sender.Stop();$sender.Tag.Continue=$false});$watch.Start()
 try{[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$watch.Stop()}
}
function Wait-FixtureState {
 param([string]$Stage,[scriptblock]$Condition,[int]$TimeoutMs=5000,[int]$MinimumTicks=1)
 # Wait for observable state through the REAL Dispatcher. A loaded VM may deliver fewer ticks than
 # a fixed sleep suggests; this never invokes a runtime tick/filter directly or changes its clock.
 $watch=[Diagnostics.Stopwatch]::StartNew();$startRuns=[long]$script:Live.Timer.Runs;$complete=$false
 while($true){
  $ticks=[long]$script:Live.Timer.Runs-$startRuns
  if((& $Condition) -and $ticks -ge $MinimumTicks){$complete=$true;break}
  if($watch.ElapsedMilliseconds -ge $TimeoutMs -or $script:Live.Timer.Errors -gt 0 -or -not $script:Live.Timer.IsEnabled){break}
  Pump-Fixture 50
 }
 $watch.Stop()
 $script:Waits.Add([pscustomobject]@{Stage=$Stage;Completed=$complete;Milliseconds=$watch.ElapsedMilliseconds;GuardMilliseconds=$TimeoutMs;MinimumTicks=$MinimumTicks;TimerTicks=([long]$script:Live.Timer.Runs-$startRuns)})
 Snapshot-Fixture ('wait-'+$Stage)
 $s=$script:Live.Search
 Expect $complete ("Dispatcher state not reached: $Stage; rows=$($s.Rows.Count), visible=$($script:Ctrl.DgObjects.Items.Count), queued=$($s.Progress.Count), filterPending=$($s.FilterPending), ticks=$([long]$script:Live.Timer.Runs-$startRuns), elapsed=$($watch.ElapsedMilliseconds)ms, timerError=$($script:Live.Timer.LastError)")
}
function Snapshot-Fixture {param([string]$Stage)
 $t=$script:Live.Timer;$s=$script:Live.Search
 $script:Snapshots.Add([pscustomobject]@{Stage=$Stage;Rows=$s.Rows.Count;Visible=$script:Ctrl.DgObjects.Items.Count;Queued=$s.Progress.Count;TimerRuns=$t.Runs;TimerErrors=$t.Errors;TimerFailures=$t.Failures;TimerEnabled=$t.IsEnabled;FaultStopped=$t.FaultStopped;LastError=$t.LastError;HeartbeatWakeups=$script:DomeniaPulse.Wakeups;Counter=$script:Ctrl.LblSuiteResultCount.Text;FilterPending=[bool]$s.FilterPending;RefreshNeeded=[bool]$s.RefreshNeeded;LastFilterUtc=$script:Live.LastFilter.ToString('o');VisibleNames=@($script:Ctrl.DgObjects.Items|Select-Object -First 8|ForEach-Object{[string]$_.Name})})
}
function Expect-HealthyTimer {
 Expect ($script:Live.Timer.Errors -eq 0) ('Timer:Live errors: '+$script:Live.Timer.LastError)
 Expect ($script:Live.Timer.IsEnabled -and -not $script:Live.Timer.FaultStopped) 'Timer:Live stopped'
 Expect ($script:DomeniaPulse.Wakeups -gt 0 -and $script:Live.Timer.Runs -gt 0) 'Real Dispatcher heartbeat did not run'
}
try {
 Case 'Real loader keeps application functions private to the script' {
  Expect ($null -ne ${function:Test-DomeniaSearchQueryRow}) 'Query helper not loaded'
  Expect ($null -eq (Get-Item Function:\global:Test-DomeniaSearchQueryRow -ErrorAction SilentlyContinue)) 'Fixture exported helper globally and would mask the regression'
  Expect (@($script:LoadedFunctions|Where-Object{-not $_.File -or $_.File -notlike ($Wad+'*')}).Count -eq 0) 'Target functions were not imported by the real module loader'
 }
 Case 'Progressive arrivals without query survive three timer ticks' {
  Expect ($null -eq $script:DomeniaQueryState) 'Expected absent query state at startup'
  $scope=Get-DomeniaSearchScope
  $state=[pscustomobject]@{Generation=$script:GlobalSearchGeneration;SearchMode='OU';BaseDn=$scope.BaseDn;Scope=$scope.Scope;TypeFilter=(Get-GlobalSelectedTypeFilter);Search='';Limit=10000;PreserveSelectionDn='';ViewId=''}
  $payload=[pscustomobject]@{};$search=Begin-DomeniaLiveSearch -State $state -Payload $payload
  Expect ($null -ne $script:Live.Timer -and $script:Live.Timer.Owner -eq 'Timer:Live') 'Real Live timer missing'
  foreach($event in @((New-FixtureEvent 'PC-ALPHA' $script:Ids[0]),(New-FixtureEvent 'PC-BETA' $script:Ids[1]),(New-FixtureEvent 'USER-GAMMA' $script:Ids[2] 'Utilisateur'))){$search.Progress.Enqueue($event)}
  Invoke-DomeniaTimerSoon -Owner 'Timer:Live'
  Wait-FixtureState -Stage 'initial-three-arrivals' -MinimumTicks 3 -Condition {$search.Progress.IsEmpty -and $search.Rows.Count -eq 3 -and $grid.Items.Count -eq 3}
  Snapshot-Fixture 'no-query-three-arrivals'
  Expect-HealthyTimer
  Expect ($search.Rows.Count -eq 3 -and $grid.Items.Count -eq 3) 'Progressive search lost or hid rows without a query'
  Expect ($grid.ItemsSource -is [Collections.ObjectModel.ObservableCollection[object]]) 'ObservableCollection was replaced'
  Expect ($script:Ctrl.LblSuiteResultCount.Text -match '^Chargement… · 3 / 3 lignes visibles(?: ·|$)') ('Loading state or visible counter differs from real grid: '+$script:Ctrl.LblSuiteResultCount.Text)
 }
 if($script:Live.Timer.Errors -eq 0){
  Case 'Real ApplySearch intersects native matching GUIDs and object types' {
   Initialize-DomeniaQueryWorkshop;$q=$script:DomeniaQueryState
   $records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
   for($i=0;$i -lt 2;$i++){$v=[Collections.Generic.Dictionary[string,object]]::new();$v['name']=@('PC-ALPHA','PC-BETA')[$i];$records.Add([M4D.Admin.Common.Query.QueryRecord]::new($script:Ids[$i],$v))}
   $q.Records=$records;$q.At=[datetime]::UtcNow;$q.SnapshotKey='fixture-snapshot';$script:FleetQuerySnapshotKey='fixture-snapshot'
   Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Name 'Only beta' -Clauses @([pscustomobject]@{Field='name';Operator='Equal';Value='PC-BETA'}))
   Invoke-DomeniaQueryAction 'ApplySearch'
   Expect ($null -ne $q.SearchRecipe -and $q.SearchRecords.Count -eq 1 -and $q.SearchRecords.ContainsKey($script:Ids[1])) 'Real ApplySearch did not calculate one matching GUID'
   Expect ($grid.Items.Count -eq 1 -and $grid.Items[0].Name -eq 'PC-BETA') 'Applied query failed to refresh existing rows'
   Expect ($script:LastWorkspace -eq 'WsSearch') 'ApplySearch did not select Search'
   Snapshot-Fixture 'applied-query'
  }
  Case 'GUID normalization and later arrivals use the active predicate' {
   $q=$script:DomeniaQueryState;$q.SearchRecords[$script:Ids[3]]=$true
   $s=$script:Live.Search;$s.Progress.Enqueue((New-FixtureEvent 'PC-DELTA' (' {'+$script:Ids[3].ToUpperInvariant()+'} ')))
   $s.Progress.Enqueue((New-FixtureEvent 'GROUP-DELTA' $script:Ids[3] 'Groupe'))
   Invoke-DomeniaTimerSoon -Owner 'Timer:Live'
   Wait-FixtureState -Stage 'filtered-incremental-arrivals' -Condition {$s.Progress.IsEmpty -and $s.Rows.Count -eq 5 -and $grid.Items.Count -eq 2}
   Expect-HealthyTimer
   Expect ($s.Rows.Count -eq 5 -and $grid.Items.Count -eq 2) 'Incremental matching GUID, excluded type, or normalization failed'
   Expect (@($grid.Items|Where-Object{$_.Type -ne 'Machine'}).Count -eq 0) 'Non-machine object admitted by query filter'
   Snapshot-Fixture 'filtered-incremental-arrivals'
  }
  Case 'Reapply recomputes GUID selection and explicit refresh preserves it' {
   $q=$script:DomeniaQueryState
   Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Name 'Only alpha' -Clauses @([pscustomobject]@{Field='name';Operator='Equal';Value='PC-ALPHA'}))
   Invoke-DomeniaQueryAction 'ApplySearch';Update-DomeniaLiveFilter
   Expect ($q.SearchRecords.Count -eq 1 -and $grid.Items.Count -eq 1 -and $grid.Items[0].Name -eq 'PC-ALPHA') 'Reapply retained stale query selection'
   $s=$script:Live.Search;$event=New-FixtureEvent 'PC-BETA-REFRESHED' $script:Ids[1];$event.Row.DN='CN=PC-BETA,OU=Lab,DC=example,DC=invalid';$s.Progress.Enqueue($event);Invoke-DomeniaTimerSoon -Owner 'Timer:Live'
   Wait-FixtureState -Stage 'excluded-row-refresh' -Condition {$s.Progress.IsEmpty -and $s.Rows.Count -eq 5 -and @($s.Rows|Where-Object{$_.Name -eq 'PC-BETA-REFRESHED'}).Count -eq 1 -and $grid.Items.Count -eq 1}
   Expect-HealthyTimer;Expect ($s.Rows.Count -eq 5 -and $grid.Items.Count -eq 1) 'Refreshing an excluded row changed visible population'
  }
  Case 'Active selection with empty or missing map fails closed' {
   $q=$script:DomeniaQueryState;$map=$q.SearchRecords
   try{$q.SearchRecords=@{};Apply-DomeniaPresenceFilter;Expect ($grid.Items.Count -eq 0) 'Empty selection displayed all objects';$q.SearchRecords=$null;Apply-DomeniaPresenceFilter;Expect ($grid.Items.Count -eq 0) 'Active selection with missing map displayed all objects'}finally{$q.SearchRecords=$map;Apply-DomeniaPresenceFilter}
  }
  Case 'Disabled grid defers ApplySearch and ClearSearch until the next real tick' {
   $q=$script:DomeniaQueryState;Invoke-DomeniaQueryAction 'ClearSearch'
   Expect ($grid.Items.Count -eq 5) 'Initial ClearSearch failed'
   $grid.IsEnabled=$false
   Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Name 'Delayed beta' -Clauses @([pscustomobject]@{Field='name';Operator='Equal';Value='PC-BETA'}))
   Invoke-DomeniaQueryAction 'ApplySearch'
   Expect ($null -ne $q.SearchRecipe -and $q.SearchRecords.Count -eq 1) 'Disabled grid discarded the requested query'
   Expect ($script:Live.Search.FilterPending -and $grid.Items.Count -eq 5) 'ApplySearch was not deferred while the grid was disabled'
   $grid.IsEnabled=$true;Invoke-DomeniaTimerSoon -Owner 'Timer:Live'
   Wait-FixtureState -Stage 'enabled-grid-pending-apply' -Condition {-not $script:Live.Search.FilterPending -and $grid.Items.Count -eq 1 -and $grid.Items[0].Name -eq 'PC-BETA-REFRESHED'}
   Expect-HealthyTimer;Expect ($grid.Items.Count -eq 1 -and $grid.Items[0].Name -eq 'PC-BETA-REFRESHED') 'Pending ApplySearch was not rebuilt after enabling grid'
   $grid.IsEnabled=$false;Invoke-DomeniaQueryAction 'ClearSearch'
   Expect ($null -eq $q.SearchRecipe -and $script:Live.Search.FilterPending -and $grid.Items.Count -eq 1) 'ClearSearch was not deferred while the grid was disabled'
   $grid.IsEnabled=$true;Invoke-DomeniaTimerSoon -Owner 'Timer:Live'
   Wait-FixtureState -Stage 'enabled-grid-pending-clear' -Condition {-not $script:Live.Search.FilterPending -and $grid.Items.Count -eq 5}
   Expect-HealthyTimer;Expect ($grid.Items.Count -eq 5) 'Pending ClearSearch was not rebuilt after enabling grid'
   Snapshot-Fixture 'disabled-grid-apply-and-clear'
  }
  Case 'Real ClearSearch restores rows then local text and presence filters work' {
   Invoke-DomeniaQueryAction 'ClearSearch'
   Expect ($null -eq $script:DomeniaQueryState.SearchRecipe -and $grid.Items.Count -eq 5) 'ClearSearch left the old captured selection active'
   $script:Ctrl.TxtSuiteResultFilter.Text='beta';Apply-DomeniaPresenceFilter
   Expect ($grid.Items.Count -eq 1 -and $grid.Items[0].Name -eq 'PC-BETA-REFRESHED') 'Local text filter failed after clearing query'
   $script:CurrentPresenceFilter='En ligne';Apply-DomeniaPresenceFilter;Expect ($grid.Items.Count -eq 0) 'Presence filter failed'
   $script:CurrentPresenceFilter='Tous';$script:Ctrl.TxtSuiteResultFilter.Text='';Apply-DomeniaPresenceFilter
   Expect ($grid.Items.Count -eq 5) 'Clearing local filters failed';Expect-HealthyTimer;Snapshot-Fixture 'all-filters-cleared'
  }
  Case 'DS-15 / FI-16 : la ligne porte la cle de presence et son age, le filtre lit la cle et non le libelle' {
   $s=$script:Live.Search
   $machine=@($s.Rows|Where-Object{$_.Type -eq 'Machine'})[0];$other=@($s.Rows|Where-Object{$_.Type -ne 'Machine'})[0]
   Expect ([string]$machine.PresenceState -eq 'Unknown' -and [string]$other.PresenceState -eq 'None') ('Cles initiales : '+[string]$machine.PresenceState+' / '+[string]$other.PresenceState)
   $observation=[pscustomobject]@{Key=([string]$machine.DN).ToLowerInvariant();Guid=[string]$machine.Guid;Computer=[string]$machine.Name;Outcome='NotRequested';Presence='En ligne';PresenceCheckedUtc=[datetime]::UtcNow.AddHours(-2).AddMinutes(-1).ToString('o');PresenceDetail='Reponse ICMP synthetique'}
   Set-DomeniaLiveObservationOnRow $machine $observation -Cached
   Expect ([string]$machine.Presence -eq 'En ligne' -and [string]$machine.PresenceState -eq 'Online' -and [string]$machine.PresenceAge -eq 'il y a 2 h' -and [string]$machine.PresenceCached -eq '1') ('Pastille : '+[string]$machine.Presence+' / '+[string]$machine.PresenceAge)
   Expect (-not ([string]$machine.Presence).Contains('(cache)')) 'Le suffixe (cache) est revenu dans le libelle.'
   # The label is reworded: the presence filter still finds the row by its key.
   $machine.Presence='Joignable (libelle de test)'
   $script:CurrentPresenceFilter='En ligne';Apply-DomeniaPresenceFilter
   Expect ($grid.Items.Count -eq 1 -and [object]::ReferenceEquals($grid.Items[0],$machine)) ('Filtre par cle : '+$grid.Items.Count+' ligne(s)')
   $script:CurrentPresenceFilter='Tous';Apply-DomeniaPresenceFilter
   Expect ($grid.Items.Count -eq 5) 'Filtre de presence non retire.'
  }
  Case 'Five thousand machines plus other object types remain complete and filterable' {
   $s=$script:Live.Search;$clock=[Diagnostics.Stopwatch]::StartNew()
   for($i=1;$i -le 4997;$i++){$id='55555555-5555-4555-8555-'+$i.ToString('D12');$s.Progress.Enqueue((New-FixtureEvent ('SCALE-'+$i.ToString('D5')) $id))}
   Invoke-DomeniaTimerSoon -Owner 'Timer:Live'
   while(-not $s.Progress.IsEmpty -and $clock.Elapsed.TotalSeconds -lt 120 -and $script:Live.Timer.IsEnabled){Pump-Fixture 200}
   Snapshot-Fixture '5000-machines-plus-user-and-group'
   Expect-HealthyTimer;Expect ($s.Progress.IsEmpty) '5000-machine fixture did not drain within the 120-second fixture guard'
   Expect ($s.Rows.Count -eq 5002 -and $grid.Items.Count -eq 5002) 'Complete population or visible count differs at scale'
   Expect (@($s.Rows|Where-Object{$_.Type -eq 'Machine'}).Count -eq 5000) '5000 machines were not retained'
   Expect (@($s.Rows|Group-Object DN|Where-Object{$_.Count -gt 1}).Count -eq 0) 'Duplicate DNs present in the result collection'
   $records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new();$ids=[Collections.Generic.List[string]]::new()
   foreach($row in $s.Rows){if($row.Type -ne 'Machine'){continue};$v=[Collections.Generic.Dictionary[string,object]]::new();$v['name']=$row.Name;$id=$row.Guid.Trim().Trim('{','}').ToLowerInvariant();$records.Add([M4D.Admin.Common.Query.QueryRecord]::new($id,$v));if($ids.Count -lt 2500){$ids.Add($id)}}
   $q=$script:DomeniaQueryState;$q.Records=$records;$q.At=[datetime]::UtcNow
   Set-DomeniaQueryDraft (New-DomeniaQueryRecipe -Name '2500 selected GUIDs' -ObjectIds $ids.ToArray())
   Invoke-DomeniaQueryAction 'ApplySearch'
   Expect ($q.SearchRecords.Count -eq 2500 -and $grid.Items.Count -eq 2500) 'Scale query did not display every one of its 2500 selected GUIDs'
   Snapshot-Fixture '2500-of-5000-machine-query'
   Invoke-DomeniaQueryAction 'ClearSearch';Expect ($grid.Items.Count -eq 5002) 'Scale ClearSearch failed';Expect-HealthyTimer
  }
  Case 'A fresh global search restarts and ignores residual local text and presence' {
   $script:SearchMode='Global';$script:GlobalSearchGeneration++;$script:Ctrl.TxtSuiteResultFilter.Text='NO LOCAL MATCH';$script:CurrentPresenceFilter='En ligne'
   $scope=Get-DomeniaSearchScope;$state=[pscustomobject]@{Generation=$script:GlobalSearchGeneration;SearchMode='Global';BaseDn=$scope.BaseDn;Scope=$scope.Scope;TypeFilter=(Get-GlobalSelectedTypeFilter);Search='';Limit=10000;PreserveSelectionDn='';ViewId=''}
   $script:Live.Timer.Stop();$s=Begin-DomeniaLiveSearch $state ([pscustomobject]@{})
   $s.Progress.Enqueue((New-FixtureEvent 'GLOBAL-ALPHA' $script:Ids[0]));$s.Progress.Enqueue((New-FixtureEvent 'GLOBAL-USER' $script:Ids[2] 'Utilisateur'))
   Invoke-DomeniaTimerSoon -Owner 'Timer:Live'
   Wait-FixtureState -Stage 'fresh-global-search' -Condition {$s.Progress.IsEmpty -and $s.Rows.Count -eq 2 -and $grid.Items.Count -eq 2}
   Expect-HealthyTimer;Expect ($s.Rows.Count -eq 2 -and $grid.Items.Count -eq 2) 'New global search inherited local filters or failed to restart'
   Snapshot-Fixture 'fresh-global-search'
  }
 }else{$script:Results.Add([pscustomobject]@{Name='Filter apply/refresh/clear scenarios';Passed=$false;Error='Blocked by reproduced Timer:Live failure; no success inferred.'})}
 Case 'Explicit Fleet chrome button opens the script-local workshop; chart click stays inert' {
  Initialize-DomeniaQueryWorkshop;$script:EvaluationRequests=0
  $item=New-DomeniaBoardItem -Source Builtin -Key 'fleet.disabled' -Visual Kpi -Size M -Group 'Synthese' -Title 'Disabled synthetic machines'
  $state=Get-DomeniaBoardState Fleet;$state.Layout=@($item)
  $script:TestFleetItem=$item
  function script:Get-DomeniaBoardLayout {param($Board)return @($script:TestFleetItem)}
  Expect ($null -eq (Get-DomeniaBoardSelectHandler -Board Fleet -Item $item)) 'Fleet charts still open the workshop'
  $button=New-DomeniaBoardChromeButton ([string][char]0xE8A1) 'Ouvrir dans lʼatelier' @{Board='Fleet';Id=$item.Id;Action='Details'}
  [void]$panel.Children.Add($button);Pump-Fixture 50
  $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Expect ($script:EvaluationRequests -eq 1) 'Explicit chrome button did not call real Show-DomeniaFleetWidgetDetails'
  $clauses=@($script:DomeniaQueryState.Recipe.Clauses)
  Expect ($clauses.Count -eq 1 -and $clauses[0].Field -eq 'active' -and $clauses[0].Operator -eq 'Equal' -and $clauses[0].Value -eq $false) 'Wrong query after explicit details click'
  Expect ($script:LastWorkspace -eq 'TabApplicationTools' -and $script:LastInner -eq 'ApplicationToolTabs' -and $script:LastTab -eq 'WsQueryWorkshop') 'The dedicated workshop did not open'
 }

}finally{
 if($null -ne $script:Live){Stop-DomeniaLive -Closing}
 if($null -ne $script:DomeniaPulse){$script:DomeniaPulse.Timer.Stop()}
 $script:Window.Close()
}
$failed=@($script:Results|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='DomeniaLiveSearchView';Passed=($failed -eq 0);Failed=$failed;Cases=$script:Results.Count;Assertions=$script:Assertions;PowerShell=$PSVersionTable.PSVersion.ToString();SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;Sta=([Threading.Thread]::CurrentThread.ApartmentState.ToString());SyntheticOnly=$true;RealDispatcher=$true;LoaderScope='-File launcher then & application script (same as Domenia-Start)';LoadedFunctions=$script:LoadedFunctions;Hashes=@(foreach($relative in @('Domenia-Modules.ps1','Domenia-Core.ps1','modules/Domenia-Live.UI.ps1','modules/Domenia-Query.UI.ps1','modules/Domenia-Widgets.UI.ps1')){[pscustomobject]@{Path=$relative;Sha256=(Get-FileHash (Join-Path $Wad $relative) -Algorithm SHA256).Hash}});Results=$script:Results.ToArray();Snapshots=$script:Snapshots.ToArray();Waits=$script:Waits.ToArray();Logs=$script:Logs.ToArray()}
if($ReportPath){$parent=Split-Path $ReportPath -Parent;if($parent -and -not (Test-Path $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)};[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
Write-Host ('LiveSearchView: '+$script:Results.Count+' cases / '+$script:Assertions+' assertions / '+$failed+' failed')
if($failed){exit 1};exit 0
