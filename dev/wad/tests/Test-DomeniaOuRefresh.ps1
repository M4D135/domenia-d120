#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
# Cache.Model: verified backup before an AD read (FI-13). Park.Model: rules of a survey; Live.Model: presence keys.
# Boards.Model: paused widgets left out of the WMI refresh of the OU (decision David 2026-10-14).
foreach($name in @('Common.Model','Cache.Model','Live.Model','Park.Model','Boards.Model','Storage.UI','Park.UI','Refresh.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Core parse failure'}
foreach($name in @('Test-DomeniaIndexWriteReady','Start-DomeniaIndexScopeBuild','Update-DomeniaIndexDatabaseRows','Complete-DomeniaIndexScopeUi','Fail-DomeniaIndexBuildUi')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if($null -eq $node){throw ('Core hook absent: '+$name)}
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect([bool]$Ok,[string]$Message='Assertion failed'){if(-not $Ok){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{Reset-Fixture;&$Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$true;Error=''})}catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$false;Error=$_.Exception.Message})}}
function Get-DomeniaControl($Name){return $script:Controls[$Name]}
function Set-DomeniaControlText($Name,$Text){if($script:Controls.ContainsKey($Name)){$script:Controls[$Name].Text=[string]$Text};return $true}
function Set-Status {param($Text,$Level);$script:Status=[string]$Text}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
function Get-DomeniaSetting {param($Name,$Default);if($Name -eq 'Collection.CacheMinutes'){return '15'};if($Name -eq 'Query.Library'){return 'fixture library'};return $Default}
function New-DomeniaTimer {
    param($Owner,$IntervalMs,$Tick,[switch]$RunWhenHidden)
    $t=[pscustomobject]@{Owner=$Owner;IsEnabled=$false;Tick=$Tick}
    $t|Add-Member -MemberType ScriptMethod -Name Start -Value {$this.IsEnabled=$true}
    $t|Add-Member -MemberType ScriptMethod -Name Stop -Value {$this.IsEnabled=$false}
    return $t
}
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler,$TaskClass,[switch]$NonCancellable)
    if($script:RefuseAdmission){return ''}
    $id='fixture-'+($script:Jobs.Count+1)
    $j=[pscustomobject]@{Id=$id;OperationId=$OperationId;Payload=$Payload;State=$CallbackState;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler}
    $script:Jobs.Add($j);$script:AsyncJobs[$id]=$j;return $id
}
function Stop-UiTask {param($Id,[switch]$Silent);$script:Stopped.Add([string]$Id);[void]$script:AsyncJobs.Remove($Id)}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);foreach($x in @($Result)){if($null -eq $x){continue};$valid=$true;foreach($name in $RequiredProperties){if($null -eq $x.PSObject.Properties[$name]){$valid=$false}};if($valid){return $x}};return $null}
function Get-DomeniaIndexLimits {return [pscustomobject]@{MaxObjects=0;BudgetMs=30000;TimeoutSeconds=120}}
function Set-DomeniaIndexProgress {param($Mode,$Message)}
function New-DomeniaIndexProgressChannel {return $null}
function Get-DomeniaIndexWorkerCode {return 'fixture AD dispatch'}
function Get-DomeniaLocalIndexReadWorkerCode {return 'fixture SQLite dispatch'}
function Get-DomeniaIndexCut {param($Effective);return [pscustomobject]@{Reason='temps';Limit=30000}}
function Set-DomeniaIndexPartial {param($BaseDn,$Count,$Reason,$Limit,[switch]$Clear)}
function Request-DomeniaStorageWork {$script:StorageRequests++}
function Request-DomeniaIndexMetadata {param([switch]$StartupChecks,[int]$Attempt=0)}
function Update-DomeniaIndexStats {}
function Request-DomeniaFleetRefresh {param([switch]$Force);$script:FleetRequests++}
function Get-DomeniaPersistenceLabel {param($Pending,$Failed,$Suspended,$Unavailable,$Conflicts);return 'fixture'}
function Get-DomeniaFleetQueryPlan {param($Now,$ObservationMaxAgeDays);return [pscustomobject]@{NowUtc=$Now.ToUniversalTime().ToString('o')}}
function Get-DomeniaObservationMaxAgeDays {return 30}
function Get-DomeniaBoardProbeIds {return @($script:ProbeIds)}
function Get-DomeniaBoardLayout {param($Board);return @($script:BoardWidgets[$Board])}
function ConvertFrom-DomeniaQueryLibrary {param($Json);$script:LibraryReads++;if($script:BadLibrary){throw 'fixture invalid library'};return @($script:SavedRecipes)}
function Get-DomeniaQueryProbeIds {param($Recipe);return @($Recipe.ProbeIds)}
function ConvertTo-DomeniaProbePayload {param($Ids);foreach($id in $Ids){[pscustomobject]@{Id=[string]$id;Class='Win32_OperatingSystem';Property='Caption'}}}
function Initialize-DomeniaWinSqliteNative {return $true}
function New-DomeniaObservationReader {return [pscustomobject]@{Fixture=$true}}
function Clear-DomeniaParkTargetBuffers {param($Targets)}
function Get-DomeniaSelectedGridRows {return @()}
function Write-AppLog {param($Text,$Level)}
# FI-18: the surveys of an OU refresh run in the scope of the lists.
function Get-ListRun {return (Get-DomeniaParkRun -Slot 'List')}
function Request-DomeniaInlineConfirmation {param($Title,$Target,$Message,$ConfirmText,$CancelText,$OnConfirm,$OnCancel);$script:Confirmation=[pscustomobject]@{Message=$Message;Confirm=$OnConfirm;Cancel=$OnCancel}}
function Reset-Fixture {
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test';Domain='example.test'};$script:DatabaseScopedPath='/fixture/local.sqlite';$script:SessionEpoch=4;$script:GlobalSearchGeneration=6
    $script:SelectedBranchDn='OU=Recherche,DC=example,DC=test';$script:FleetScopeDn='OU=Dashboard,DC=example,DC=test';$script:IndexScopeDn='OU=Base,DC=example,DC=test';$script:SearchMode='Global'
    $script:DomeniaOuRefresh=$null;$script:ParkRuns=$null;$script:IndexWalk=$null;$script:Live=$null;$script:DemoMode=$false;$script:AsyncEngineClosing=$false;$script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@();$script:SelectedObject=$null
    $script:DomeniaQueryState=$null;$script:BoardWidgets=@{Fleet=@();Computer=@()};$script:SavedRecipes=@();$script:BadLibrary=$false;$script:LibraryReads=0
    $script:Persistence=[pscustomobject]@{Pending=([ordered]@{});Job='';Next=[datetime]::MinValue;Fault='';Failures=0;LinkBusy=$false;LinkRequestTimer=$null;LinkPersistenceMore=$false;InFlight=0;InFlightItems=@();Conflicts=@{};LegacyImportJob='';LastSavedAt=$null}
    $script:Jobs=[Collections.Generic.List[object]]::new();$script:Stopped=[Collections.Generic.List[string]]::new();$script:RefuseAdmission=$false;$script:StorageRequests=0;$script:FleetRequests=0;$script:Confirmation=$null;$script:Status='';$script:DashboardModuleRoot=$modules;$script:ProbeIds=@('fixture.os')
    $script:Controls=@{}
    foreach($name in @('LblSearchOuRefreshScope','LblSearchOuRefreshStatus','LblFleetOuRefreshStatus','LblIndexOuRefreshStatus','BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth','BtnSearchRefreshStop','BtnFleetIndexScope','BtnFleetRefreshPostes','BtnFleetRefreshBoth','BtnFleetRefreshStop','BtnIndexScopeUpdate','LblParkStatus','LblParkDetectionStatus','LblLiveState','BtnParkResultsStop')){$script:Controls[$name]=[pscustomobject]@{Text='';IsEnabled=$true}}
    $script:Controls.ChkSubtree=[pscustomobject]@{IsChecked=$false};$script:Controls.DgObjects=[pscustomobject]@{Items=@()}
}
function Complete-Ad([bool]$Partial=$false){
    $job=$script:Jobs[0];[void]$script:AsyncJobs.Remove($job.Id)
    $result=[pscustomobject]@{Rows=@([pscustomobject]@{Type='Machine';DN='CN=PC,'+$job.State.SearchBase});RowCount=1;Server='fixture';DurationMs=10;SearchBase=$job.State.SearchBase;InvocationId='fixture';Truncated=$Partial;Reconcile=$null}
    Complete-DomeniaIndexScopeUi -Result $result -State $job.State
    return @($script:Persistence.Pending.Values)[0]
}
function Commit-Item($Item){[void]$script:Persistence.Pending.Remove($Item.QueueKey);$script:Persistence.InFlight=1;Complete-DomeniaStorageWork -Result ([pscustomobject]@{Saved=$true;Conflicts=@();Count=1}) -State ([pscustomobject]@{Items=@($Item)})}
function Complete-Targets([int]$Count=1){
    $job=$script:Jobs[$script:Jobs.Count-1];[void]$script:AsyncJobs.Remove($job.Id)
    $targets=@(for($i=0;$i -lt $Count;$i++){[pscustomobject]@{name=('PC-'+$i);distinguished_name=('CN=PC-'+$i+','+$script:DomeniaOuRefresh.Dn);object_guid=([guid]::NewGuid().ToString('D'))}})
    Complete-DomeniaOuRefreshTargets -State $job.State -Result ([pscustomobject]@{Targets=$targets;Busy=$false;Missing=$false;Scope=$job.State.Dn;Subtree=$true})
}
Case 'Three independent OU sources; Search Global and unchecked subtrees do not widen to domain or mutate controls' {
    foreach($source in @('Fleet','Search','Index')){$c=Get-DomeniaOuRefreshContext $source;Expect ($c.Subtree -and $c.Source -eq $source)}
    Expect ((Get-DomeniaOuRefreshContext Search).Dn -eq $script:SelectedBranchDn);Expect (-not $script:Controls.ChkSubtree.IsChecked -and $script:SearchMode -eq 'Global')
}
Case 'Missing OU and domain root refused before any job' {$script:SelectedBranchDn=$script:Conn.BaseDn;Invoke-DomeniaOuRefresh Search Both;Expect ($script:Jobs.Count -eq 0 -and $null -eq $script:DomeniaOuRefresh)}
Case 'Foreign OU refused' {$script:SelectedBranchDn='OU=Other,DC=elsewhere,DC=test';Expect ($null -eq (Get-DomeniaOuRefreshContext Search))}
Case 'Escaped commas in the OU remain inside the exact domain' {$script:SelectedBranchDn='OU=Paris\, Est,DC=example,DC=test';Expect ($null -ne (Get-DomeniaOuRefreshContext Search))}
Case 'Core dispatch carries operation identity and full OU payload' {Invoke-DomeniaOuRefresh Search Both;$j=$script:Jobs[0];Expect ($j.State.RefreshOperationId -ceq $script:DomeniaOuRefresh.Id -and $j.Payload.SearchBase -eq $script:SelectedBranchDn -and $j.State.Path -ceq $script:DatabaseScopedPath)}
Case 'Core callback queues operation identity and does not collect before receipt' {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad;Expect ($item.Row.RefreshOperationId -ceq $script:DomeniaOuRefresh.Id -and $item.Row.Complete -and $script:DomeniaOuRefresh.Phase -eq 'Saving' -and $script:Jobs.Count -eq 1)}
Case 'Exact storage receipt starts Both only on subsequent tick' {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad;Commit-Item $item;Expect ($script:DomeniaOuRefresh.BaseCommitted -and $script:DomeniaOuRefresh.Phase -eq 'WaitingCollection' -and $script:Jobs.Count -eq 1);Invoke-DomeniaOuRefreshTick;Expect ($script:Jobs.Count -eq 2 -and $script:Jobs[1].Payload.Subtree -and $script:Jobs[1].Payload.Scope -eq $script:SelectedBranchDn -and -not $script:Jobs[1].Payload.ComputeBoard)}
Case 'Base mode ends at confirmed save without remote collection' {Invoke-DomeniaOuRefresh Index Base;$item=Complete-Ad;Commit-Item $item;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Completed -and $script:DomeniaOuRefresh.Phase -eq 'Complete' -and $script:Jobs.Count -eq 1)}
Case 'Partial AD can save rows but never chains collection' {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad $true;Commit-Item $item;Invoke-DomeniaOuRefreshTick;Expect (-not $item.Row.Complete -and $script:DomeniaOuRefresh.Phase -eq 'Error' -and $script:Jobs.Count -eq 1)}
Case 'Null AD result fails the chain' {Invoke-DomeniaOuRefresh Search Both;try{Complete-DomeniaIndexScopeUi -Result $null -State $script:Jobs[0].State}catch{};Expect ($script:DomeniaOuRefresh.Completed -and $script:DomeniaOuRefresh.Phase -eq 'Error')}
Case 'AD error callback fails chain' {Invoke-DomeniaOuRefresh Search Both;Fail-DomeniaIndexBuildUi 'fixture denied' $script:Jobs[0].State;Expect ($script:DomeniaOuRefresh.Phase -eq 'Error')}
Case 'Refused AD admission releases UI state' {$script:RefuseAdmission=$true;Invoke-DomeniaOuRefresh Search Both;Expect ($script:DomeniaOuRefresh.Completed -and $script:DomeniaOuRefresh.Phase -eq 'Error' -and $script:Controls.BtnSearchRefreshBase.IsEnabled)}
Case 'Storage failure latches before automatic retries' {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad;Fail-DomeniaStorageWork 'fixture busy' ([pscustomobject]@{Items=@($item)});Commit-Item $item;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Phase -eq 'Error' -and $script:Jobs.Count -eq 1)}
Case 'Cancellation during storage prevents later success from collecting' {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad;Stop-DomeniaOuRefresh -Source Search;Commit-Item $item;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Cancelled -and $script:Jobs.Count -eq 1)}
Case 'Foreign operation receipt ignored' {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad;$item.Row.RefreshOperationId='other';Commit-Item $item;Expect (-not $script:DomeniaOuRefresh.BaseCommitted -and $script:DomeniaOuRefresh.Phase -eq 'Saving')}
Case 'Old receipt from same OU cannot advance a new operation' {Invoke-DomeniaOuRefresh Search Both;$old=Complete-Ad;Stop-DomeniaOuRefresh -Source Search;$script:Persistence.Pending.Clear();Invoke-DomeniaOuRefresh Search Both;Complete-DomeniaOuRefreshCommit $old;Expect (-not $script:DomeniaOuRefresh.BaseCommitted -and $script:DomeniaOuRefresh.Phase -eq 'Directory')}
foreach($field in @('Epoch','Path')){Case ('Foreign storage '+$field+' ignored') {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad;if($field -eq 'Epoch'){$item.Epoch=99}else{$item.Path='/other.sqlite'};Complete-DomeniaOuRefreshCommit $item;Expect (-not $script:DomeniaOuRefresh.BaseCommitted)}}
Case 'Changing source OU cancels pending handoff' {Invoke-DomeniaOuRefresh Search Both;$item=Complete-Ad;$script:SelectedBranchDn='OU=Other,DC=example,DC=test';Invoke-DomeniaOuRefreshTick;Commit-Item $item;Expect ($script:DomeniaOuRefresh.Cancelled -and $script:Jobs.Count -eq 1)}
Case 'Changing another page OU does not alter the operation' {Invoke-DomeniaOuRefresh Search Both;$script:FleetScopeDn='OU=Other,DC=example,DC=test';Expect (Test-DomeniaOuRefreshCurrent $script:DomeniaOuRefresh.Id)}
Case 'Session or database drift stops the chain' {Invoke-DomeniaOuRefresh Search Postes;$script:SessionEpoch++;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Cancelled -and $script:Jobs.Count -eq 0)}
Case 'Busy local target response does not prepare remote workers' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;$s=$script:Jobs[0].State;Complete-DomeniaOuRefreshTargets ([pscustomobject]@{Targets=@();Busy=$true;Missing=$false;Scope=$s.Dn;Subtree=$true}) $s;Expect ($script:DomeniaOuRefresh.Phase -eq 'Error' -and $null -eq (Get-ListRun))}
Case 'Empty scoped base is explicit and sends no ping' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 0;Expect ($script:DomeniaOuRefresh.Completed -and $script:Jobs.Count -eq 1 -and $null -eq (Get-ListRun))}
Case '5001 active targets ignore empty displayed grid and force fresh measurements only for this run' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 5001;Expect ($script:Jobs.Count -eq 2 -and @($script:Jobs[1].Payload.Targets).Count -eq 5001 -and (Get-ListRun).CacheMinutes -eq 0 -and (Get-ListRun).Inventory -and -not (Get-ListRun).Approved);Expect ((Get-DomeniaSetting Collection.CacheMinutes 0) -eq '15')}
Case 'Confirmation precedes ping and names the captured OU' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 1;$j=$script:Jobs[1];Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@([pscustomobject]@{Computer='PC-0'});Busy=$false}) $j.State;Expect ($null -ne $script:Confirmation -and $script:Confirmation.Message.Contains($script:SelectedBranchDn) -and -not (Get-ListRun).Approved -and $null -eq (Get-ListRun).Timer)}
Case 'Changing OU before confirmation cannot start the timer' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 1;Complete-DomeniaParkTargets ([pscustomobject]@{Rows=@([pscustomobject]@{Computer='PC-0'});Busy=$false}) $script:Jobs[1].State;$script:SelectedBranchDn='OU=Changed,DC=example,DC=test';& $script:Confirmation.Confirm;Expect (-not (Get-ListRun).Approved -and (Get-ListRun).Stopping -and $null -eq (Get-ListRun).Timer)}
Case 'Cancelled AD job cannot leave the flow waiting forever' {Invoke-DomeniaOuRefresh Search Both;$script:AsyncJobs.Clear();Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Phase -eq 'Error')}
Case 'Closing engine prevents any phase transition' {Invoke-DomeniaOuRefresh Search Postes;$script:AsyncEngineClosing=$true;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Cancelled -and $script:Jobs.Count -eq 0)}
Case 'Existing collection blocks another refresh before AD dispatch' {$script:ParkRuns=@{List=[pscustomobject]@{Id='other';Slot='List';Completed=$false}};Invoke-DomeniaOuRefresh Search Both;Expect ($script:Jobs.Count -eq 0 -and $null -eq $script:DomeniaOuRefresh)}
Case 'Storage preparation failure becomes explicit flow error' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 1;Fail-DomeniaParkTargets 'fixture SQL busy' $script:Jobs[1].State;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Phase -eq 'Error')}
Case 'Finished collection with suspended storage never reports persisted success' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 1;(Get-ListRun).Completed=$true;(Get-ListRun).Approved=$true;(Get-ListRun).Done=1;$script:Persistence.Failures=3;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Phase -eq 'Error' -and $script:DomeniaOuRefresh.Status.Contains('non confirmé'))}
Case 'Successful collection reports completion only after local persistence drained' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 1;(Get-ListRun).Completed=$true;(Get-ListRun).Approved=$true;(Get-ListRun).Done=1;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Phase -eq 'Complete' -and $script:DomeniaOuRefresh.Status.Contains('enregistrées'))}
Case 'Index button still opens its picker when no OU has been chosen' {$script:IndexScopeDn='';Update-DomeniaOuRefreshUi;Expect $script:Controls.BtnIndexScopeUpdate.IsEnabled}
Case 'Old operation status identifies its original OU after scope selection changes' {Invoke-DomeniaOuRefresh Search Base;$old=$script:SelectedBranchDn;$script:SelectedBranchDn='OU=New,DC=example,DC=test';Update-DomeniaOuRefreshUi;Expect ($script:Controls.LblSearchOuRefreshStatus.Text.Contains('Précédente OU') -and $script:Controls.LblSearchOuRefreshStatus.Text.Contains($old))}
Case 'Fleet controls become enabled after choosing their own OU' {$script:FleetScopeDn='';Update-DomeniaOuRefreshUi;Expect (-not $script:Controls.BtnFleetRefreshPostes.IsEnabled);$script:FleetScopeDn='OU=Chosen,DC=example,DC=test';Update-DomeniaOuRefreshUi;Expect $script:Controls.BtnFleetRefreshPostes.IsEnabled}
Case 'Selected dashboard probes are snapshotted before AD and forced in remote plan' {Invoke-DomeniaOuRefresh Search Both;$script:ProbeIds=@('fixture.changed');$item=Complete-Ad;Commit-Item $item;Invoke-DomeniaOuRefreshTick;Complete-Targets 1;Expect ((Get-ListRun).Probes.Count -eq 1 -and (Get-ListRun).Probes[0].Id -eq 'fixture.os' -and (Get-ListRun).CacheMinutes -eq 0)}
Case 'First click includes saved query widget probes on both boards without opening the workshop' {
    $script:BoardWidgets.Fleet=@([pscustomobject]@{Source='Query';Key='saved.one'});$script:BoardWidgets.Computer=@([pscustomobject]@{Source='Query';Key='saved.two'})
    $script:SavedRecipes=@([pscustomobject]@{Id='saved.one';ProbeIds=@('fixture.os','fixture.ram')},[pscustomobject]@{Id='saved.two';ProbeIds=@('fixture.ram','fixture.disk')})
    Invoke-DomeniaOuRefresh Search Both
    Expect ($null -eq $script:DomeniaQueryState -and $script:LibraryReads -eq 1 -and $script:DomeniaOuRefresh.Probes.Count -eq 3)
    $script:SavedRecipes=@();$script:BoardWidgets.Fleet=@();$item=Complete-Ad;Commit-Item $item;Invoke-DomeniaOuRefreshTick;Complete-Targets 1
    Expect ((Get-ListRun).Probes.Count -eq 3 -and (Get-ListRun).CacheMinutes -eq 0)
}
Case 'Loaded query library is used without rereading or changing its draft' {
    $script:BoardWidgets.Computer=@([pscustomobject]@{Source='Query';Key='saved.one'})
    $script:DomeniaQueryState=[pscustomobject]@{Saved=@([pscustomobject]@{Id='saved.one';ProbeIds=@('fixture.ram')});LibraryError='';Recipe='fixture draft'}
    Invoke-DomeniaOuRefresh Search Postes
    Expect ($script:LibraryReads -eq 0 -and $script:DomeniaOuRefresh.Probes.Count -eq 2 -and $script:DomeniaQueryState.Recipe -eq 'fixture draft')
}
foreach($failure in @('Unreadable','Missing','Duplicate')){Case ('Configured query widget '+$failure+' refuses collection before any worker') {
    $script:BoardWidgets.Fleet=@([pscustomobject]@{Source='Query';Key='saved.one'})
    if($failure -eq 'Unreadable'){$script:BadLibrary=$true}
    if($failure -eq 'Duplicate'){$script:SavedRecipes=@([pscustomobject]@{Id='saved.one';ProbeIds=@()},[pscustomobject]@{Id='saved.one';ProbeIds=@()})}
    Invoke-DomeniaOuRefresh Search Both;Expect ($null -eq $script:DomeniaOuRefresh -and $script:Jobs.Count -eq 0 -and $script:Status.Contains('non lancée'))
}}
Case 'Paused query widget is left out of the WMI refresh of the OU (decision David 2026-10-14)' {
    # Probe widgets come from Get-DomeniaBoardProbeIds (paused ones already left out there): none here.
    $script:ProbeIds=@()
    $script:BoardWidgets.Fleet=@([pscustomobject]@{Source='Query';Key='saved.one';Paused=$true});$script:BoardWidgets.Computer=@([pscustomobject]@{Source='Query';Key='saved.two'})
    $script:SavedRecipes=@([pscustomobject]@{Id='saved.one';ProbeIds=@('fixture.os')},[pscustomobject]@{Id='saved.two';ProbeIds=@('fixture.disk')})
    Invoke-DomeniaOuRefresh Search Both
    Expect (($script:DomeniaOuRefresh.Probes.Count -eq 1) -and ([string]$script:DomeniaOuRefresh.Probes[0].Id -eq 'fixture.disk')) ('Sondes : '+(@($script:DomeniaOuRefresh.Probes|ForEach-Object{$_.Id}) -join ','))
}
Case 'Base-only refresh is independent of a damaged query library' {$script:BoardWidgets.Fleet=@([pscustomobject]@{Source='Query';Key='saved.one'});$script:BadLibrary=$true;Invoke-DomeniaOuRefresh Search Base;Expect ($script:Jobs.Count -eq 1 -and $script:LibraryReads -eq 0)}
Case 'Failed workstation measurements never announce full ping and WMI success' {Invoke-DomeniaOuRefresh Search Postes;Invoke-DomeniaOuRefreshTick;Complete-Targets 1;(Get-ListRun).Completed=$true;(Get-ListRun).Approved=$true;(Get-ListRun).Done=1;(Get-ListRun).Failed=1;Invoke-DomeniaOuRefreshTick;Expect ($script:DomeniaOuRefresh.Phase -eq 'Partial' -and -not $script:DomeniaOuRefresh.Status.Contains('Ping et WMI relus'))}
Case 'FI-13 : la relecture AD de l OU attend la sauvegarde verifiee de la base ; ping, refus et echec ne lisent rien' {
    # A real base file makes the backup due; the StorageBackup worker is the fixture transport, its receipt the release.
    function Get-DomeniaStorageBackupWorkerCode {return 'fixture backup'}
    function Set-DomeniaSetting {param($Name,$Value);$script:BackupSettings[[string]$Name]=$Value}
    function Write-AppLog {param($Text,$Level)}
    $script:BackupSettings=@{};$script:StorageGestureBackup=$null
    $file=Join-Path ([IO.Path]::GetTempPath()) ('domenia-x06-'+[guid]::NewGuid().ToString('N')+'.db')
    [IO.File]::WriteAllBytes($file,[byte[]]@(0))
    try{
        $script:DatabaseScopedPath=$file
        Invoke-DomeniaOuRefresh Search Ping
        Expect (@($script:Jobs|Where-Object{$_.OperationId -eq 'StorageBackup'}).Count -eq 0 -and $null -ne $script:DomeniaOuRefresh) 'Sauvegarde lancee pour un simple ping'
        Stop-DomeniaOuRefresh -Source Search
        $script:ParkRuns=@{List=[pscustomobject]@{Id='other';Slot='List';Completed=$false}}
        Invoke-DomeniaOuRefresh Index AD
        Expect ($script:Jobs.Count -eq 0) 'Sauvegarde lancee pour une actualisation refusee'
        $script:ParkRuns=$null
        Invoke-DomeniaOuRefresh Index AD
        Expect ($script:Jobs.Count -eq 1 -and $script:Jobs[0].OperationId -eq 'StorageBackup' -and $script:Jobs[0].Payload.Database -ceq $file -and $script:DomeniaOuRefresh.Completed) 'La sauvegarde ne precede pas la lecture AD'
        $backup=$script:Jobs[0];[void]$script:AsyncJobs.Remove($backup.Id)
        Complete-DomeniaGestureBackup -Result ([pscustomobject]@{Backup=(Join-Path ([IO.Path]::GetTempPath()) 'Domenia-fixture.db');CopiedTo='';Verified=$true;VerifiedAtUtc=[datetime]::UtcNow.ToString('o')}) -State $backup.State
        Expect ($script:Jobs.Count -eq 2 -and $script:Jobs[1].OperationId -eq 'IndexBuild' -and $script:Jobs[1].Payload.SearchBase -eq $script:IndexScopeDn -and $script:DomeniaOuRefresh.Source -eq 'Index' -and $script:DomeniaOuRefresh.Phase -eq 'Directory') 'Lecture AD non lancee apres la sauvegarde verifiee'
        # A failed backup starts nothing; the explicit choice to continue without a backup is offered in the page.
        Stop-DomeniaOuRefresh -Source Index;$script:AsyncJobs.Clear();$script:BackupSettings=@{}
        Invoke-DomeniaOuRefresh Fleet AD
        $backup=$script:Jobs[2];Expect ($backup.OperationId -eq 'StorageBackup') 'Sauvegarde absente avant la mise a jour du tableau de bord'
        [void]$script:AsyncJobs.Remove($backup.Id)
        Fail-DomeniaGestureBackup -Message 'fixture disque plein' -State $backup.State
        Expect ($script:Jobs.Count -eq 3 -and $null -ne $script:Confirmation -and $script:Confirmation.Message.Contains('Rien nʼa été lancé')) 'Lecture AD lancee malgre l echec de la sauvegarde'
        & $script:Confirmation.Confirm
        Expect ($script:Jobs.Count -eq 4 -and $script:Jobs[3].OperationId -eq 'IndexBuild' -and $script:DomeniaOuRefresh.Source -eq 'Fleet') 'Continuer sans sauvegarde ne lance pas la lecture AD'
    }finally{Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}
}
Case 'FI-13 : une OU choisie pendant la sauvegarde n est jamais lue sans son propre clic' {
    function Get-DomeniaStorageBackupWorkerCode {return 'fixture backup'}
    function Set-DomeniaSetting {param($Name,$Value);$script:BackupSettings[[string]$Name]=$Value}
    function Write-AppLog {param($Text,$Level)}
    $script:BackupSettings=@{};$script:StorageGestureBackup=$null
    $file=Join-Path ([IO.Path]::GetTempPath()) ('domenia-x06-'+[guid]::NewGuid().ToString('N')+'.db')
    [IO.File]::WriteAllBytes($file,[byte[]]@(0))
    try{
        $script:DatabaseScopedPath=$file;$clicked=$script:SelectedBranchDn
        $receipt=[pscustomobject]@{Backup=(Join-Path ([IO.Path]::GetTempPath()) 'Domenia-fixture.db');CopiedTo='';Verified=$true;VerifiedAtUtc=[datetime]::UtcNow.ToString('o')}
        # Another OU picked in Rechercher while the copy runs: nothing is read, neither OU.
        Invoke-DomeniaOuRefresh Search AD
        $backup=$script:Jobs[0];Expect ($backup.OperationId -eq 'StorageBackup') 'Sauvegarde absente avant la lecture AD'
        $script:SelectedBranchDn='OU=Autre,DC=example,DC=test'
        [void]$script:AsyncJobs.Remove($backup.Id)
        Complete-DomeniaGestureBackup -Result $receipt -State $backup.State
        Expect (($script:Jobs.Count -eq 1) -and ($null -eq $script:DomeniaOuRefresh) -and $script:Status.Contains('a changé pendant la sauvegarde')) ('OU non confirmee lue apres la sauvegarde : '+$script:Status)
        # « Continuer sans sauvegarde » after a failed copy keeps the same rule.
        $script:SelectedBranchDn=$clicked;$script:BackupSettings=@{};$script:Confirmation=$null
        Invoke-DomeniaOuRefresh Search AD
        $backup=$script:Jobs[1];[void]$script:AsyncJobs.Remove($backup.Id)
        Fail-DomeniaGestureBackup -Message 'fixture disque plein' -State $backup.State
        $script:SelectedBranchDn='OU=Autre,DC=example,DC=test'
        & $script:Confirmation.Confirm
        Expect (($script:Jobs.Count -eq 2) -and ($null -eq $script:DomeniaOuRefresh)) 'OU non confirmee lue apres Continuer sans sauvegarde'
        # Same OU: the read starts, with the probe plan captured at the click (legacy Both mode).
        $script:SelectedBranchDn=$clicked;$script:BackupSettings=@{}
        Invoke-DomeniaOuRefresh Search Both
        $backup=$script:Jobs[2];$script:ProbeIds=@('fixture.changed')
        [void]$script:AsyncJobs.Remove($backup.Id)
        Complete-DomeniaGestureBackup -Result $receipt -State $backup.State
        Expect (($script:Jobs.Count -eq 4) -and ($script:Jobs[3].OperationId -eq 'IndexBuild') -and ($script:Jobs[3].Payload.SearchBase -eq $clicked)) 'Lecture AD de l OU confirmee non lancee'
        Expect ((@($script:DomeniaOuRefresh.Probes).Count -eq 1) -and ($script:DomeniaOuRefresh.Probes[0].Id -eq 'fixture.os')) 'Plan de releve recalcule apres la sauvegarde'
        # A direct continuation without the confirmed OU reads nothing.
        Stop-DomeniaOuRefresh -Source Search;$script:AsyncJobs.Clear();$count=$script:Jobs.Count
        Invoke-DomeniaOuRefresh Search AD -BackupDone
        Expect (($script:Jobs.Count -eq $count) -and $script:Status.Contains('a changé pendant la sauvegarde')) 'Continuation sans OU confirmee acceptee'
    }finally{Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}
}
$failed=@($script:Checks|Where-Object{-not $_.Pass})
$report=[pscustomobject]@{Suite='Domenia.OuRefresh';Platform=[Environment]::OSVersion.Platform.ToString();PowerShell=$PSVersionTable.PSVersion.ToString();Pass=$script:Checks.Count-$failed.Count;Fail=$failed.Count;Tests=$script:Checks.ToArray();Limitations='Actual orchestration, Core AST hooks, storage receipt and collection UI with mocked workers/timers/controls; no AD, WMI, SQLite IO, WPF or Windows qualification.'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
