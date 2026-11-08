#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$SkipWpf)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Ok,[string]$Reason='Assertion failed');if(-not $Ok){throw $Reason}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{Reset-Fixture;& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Error=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Error=$_.Exception.Message})}
}
$corePath=Join-Path $wad 'Domenia-Core.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($corePath,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw $errors[0].Message}
# Only definition-only code, never the production bootstrap or an AD worker.
foreach($name in @('Get-MainXaml','Get-DomeniaControl','Get-DomeniaSelectedGridRow','Set-DomeniaControlText','Normalize-LinkComputer','Get-DomeniaEffectiveWorkerResult','Get-DomeniaSearchMode','Get-DomeniaSearchText','Get-DomeniaSearchScope','Test-DomeniaGridSelectionMatches')){
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($nodes.Count -ne 1){throw ('Definition ambiguous: '+$name)}
    Invoke-Expression $nodes[0].Extent.Text
}
# Load the real definition-only module plan, including canonical store and probe dependencies.
. (Join-Path $wad 'Domenia-Modules.ps1')
function Get-DomeniaLiveIdentitySignal {return [pscustomobject]@{Signal=$script:Live.Identity}}
function Test-DomeniaSearchStateCurrent {param($State);return $State.Generation -eq $script:GlobalSearchGeneration}
function Test-DomeniaAccessBusyWrite {return ($script:WriteState -in @('Unknown','UnknownPending') -or [bool]$script:ActiveWriteTaskId)}
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
# UI-23 / FO-18: the survey buttons of the list belong to Park.UI, not loaded here (inert boundary).
function Update-DomeniaParkControls {}
function Set-RowAssociationMetadata {param($Rows)}
function Get-CurrentSelectedComputerName {return ''}
function Get-ExistingLinkForComputer {param($Computer);return $null}
function Merge-DomeniaLiveLinkMemory {param($Observation)}
function Get-DomeniaRunningComputerUserProbe {param($Computer);return $script:DetailedProbe}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level)}
function Update-DomeniaSearchScopeUi {}
function Get-DomeniaRealizedTreeNodes {return ,$script:FixtureNodes}
function Get-DomeniaTreeContextKey {return $script:FixtureContext}
function Get-GlobalSelectedTypeFilter {param($Mode);return $script:FixtureType}
function Get-DomeniaSelectedGridRows {return @($script:Ctrl.DgObjects.SelectedItems)}
function Set-DomeniaSetting {param($Name,$Value) $script:SavedSettings[[string]$Name]=$Value}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:Stopped.Add([string]$Id)}
function Invoke-GlobalSearch {param([switch]$AllowEmpty,[switch]$SilentError,[switch]$PreserveSelection,[string]$SearchMode)
    $script:SearchCalls.Add([pscustomobject]@{DN=$script:SelectedBranchDn;Scope=(Get-DomeniaSearchScope).Scope;Preserve=[bool]$PreserveSelection})
    $script:GlobalSearchGeneration++
}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable)
    if($OperationId -eq 'LocalIndexRead'){return $null} # This selection fixture has no persisted cache.
    if($OperationId -notin @('LiveConsole','LiveSelectedPing')){throw ('Unexpected operation: '+$OperationId)}
    $id='fake-'+[guid]::NewGuid().ToString('N')
    $job=[pscustomobject]@{Id=$id;OperationId=$OperationId;Payload=$Payload;CallbackState=$CallbackState}
    $script:AsyncJobs[$id]=$job;$script:Calls.Add($job)
    return $id
}
# Storage is an inert boundary here; transaction/receipt validation runs in RemoteStore.
function Submit-DomeniaRemoteObservations {
 param($Result,$State,$SuccessHandler,$ErrorHandler)
 $observation=ConvertTo-DomeniaLiveObservation $Result $null
 $receipt=[pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$State.StoreContext.StoreId;RequestId=$State.StoreContext.RequestId;ObservationRows=@($observation)}
 & $SuccessHandler -Result $receipt -State $State
}
function Reset-Fixture {
    $script:SearchMode='OU';$script:AccessState=$null;$script:SelectedObject=$null
    $script:SessionEpoch=7L;$script:GlobalSearchGeneration=11;$script:WriteState='Idle';$script:ActiveWriteTaskId=''
    $script:SuppressGridSelectionEvents=$false;$script:SuppressBranchAutoLoad=$false;$script:RestoringSettings=$false
    $script:AsyncEngineClosing=$false;$script:DirectoryCredentialFaulted=$false
    $script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:DetailedProbe=$null
    $script:Calls=[Collections.Generic.List[object]]::new();$script:Stopped=[Collections.Generic.List[string]]::new();$script:SearchCalls=[Collections.Generic.List[object]]::new();$script:SavedSettings=@{}
    $script:FixtureContext='test-domain-reader';$script:FixtureType='(objectClass=*)';$script:FixtureNodes=@()
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Connected=$true}
    $script:DatabaseScopedPath=Join-Path ([IO.Path]::GetTempPath()) 'domenia-selection-fixture.sqlite';$script:DomeniaAccountGeneration=1L
    $script:SelectedBranchDn='OU=Test,DC=example,DC=invalid'
    $script:Ctrl=@{
        DgObjects=[pscustomobject]@{IsEnabled=$true;SelectedItem=$null;SelectedItems=@();SelectedIndex=-1}
        TxtGlobalSearch=[pscustomobject]@{Text=''};TxtBranchSearch=[pscustomobject]@{Text=''};ChkSubtree=[pscustomobject]@{IsChecked=$true}
        LblLinkProbeStatus=[pscustomobject]@{Text=''}
    }
    $state=[pscustomobject]@{Limit=500;PreserveSelectionDn='';Generation=11;BaseDn=$script:SelectedBranchDn;Scope='Subtree'}
    $script:Live=[pscustomobject]@{
        PresenceEvents=[Collections.Concurrent.ConcurrentQueue[object]]::new();PresenceSeen=@{};Identity='reader-7';Epoch=7L;AutoDetect=$true;VerifyOnClick=$true;ProbeSelection=$null;RemoteFaulted=$false
        Pending=[Collections.Generic.Queue[object]]::new();PendingKeys=@{};Busy=@{};Done=@{}
        Observations=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new();SaveQueue=@{};QueryToSave=$null;SaveJob='';SaveFault=''
        CacheReady=$false;NextStart=[datetime]::MinValue;SaveAfter=[datetime]::MinValue
        Deferred=[Collections.Generic.Queue[object]]::new();MemoryQueries=@{}
        Search=[pscustomobject]@{Identity='reader-7';Epoch=7L;Stopped=$false;State=$state;Rows=[Collections.ObjectModel.ObservableCollection[object]]::new();Map=@{};Fresh=@{};FreshOrder=[Collections.Generic.List[object]]::new();CacheKeys=[Collections.Generic.Queue[string]]::new();RefreshNeeded=$false;SelectionRestored=$false;FirstMs=-1L;Started=[Diagnostics.Stopwatch]::StartNew();Error=''}
    }
    $script:Continuity=[pscustomobject]@{Context=$script:FixtureContext;Restoring=$false;Restore=$null;RestoreSearch=$null;RestoreToken='';RestoreGeneration=11;RestoreDeadline=[datetime]::UtcNow.AddSeconds(30);SelectedRestored=$false;Bookmarks=@{}}
}
function Add-FixtureRow {param([int]$Number,[switch]$Cached,[string]$Kind='Machine')
    $r=[pscustomobject]@{Type=$Kind;Name=('PC'+$Number);Login=('PC'+$Number);UPN=('pc'+$Number+'.example.invalid');DN=('CN=PC'+$Number+',OU=Test,DC=example,DC=invalid');Guid=('00000000-0000-0000-0000-'+$Number.ToString('000000000000'))}
    Add-DomeniaLiveRow ([pscustomobject]@{Kind=$(if($Cached){'CachedRow'}else{'Row'});Row=$r;ObservedUtc='2026-10-01T10:00:00Z'})
    return $script:Live.Search.Map[(Get-DomeniaLiveObjectKey $r)]
}
function Pick {param($Row)
    $script:Ctrl.DgObjects.SelectedItem=$Row
    $script:Ctrl.DgObjects.SelectedItems=if($null -eq $Row){@()}else{@($Row)}
    Select-DomeniaLiveResult
}
function Ready {
    if($null -ne $script:Live.ProbeSelection){$script:Live.ProbeSelection.ReadyAfter=[datetime]::MinValue}
    foreach($item in $script:Live.PendingKeys.Values){$item.ReadyAfter=[datetime]::MinValue}
}
function Restore-Request {
    $script:Continuity.RestoreSearch=[pscustomobject]@{DN=$script:SelectedBranchDn;Scope='Subtree';Context=$script:FixtureContext;Epoch=7L;Generation=11;Text='';TypeFilter=$script:FixtureType}
}
Case '100 AD rows do not queue any probe' {foreach($i in 1..100){$null=Add-FixtureRow $i};Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0 -and $script:Live.Pending.Count -eq 0)}
Case 'Cached rows do not queue a probe' {foreach($i in 1..30){$null=Add-FixtureRow $i -Cached};Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0 -and $null -eq $script:Live.ProbeSelection)}
Case 'Direct queue call without an explicit intent is refused' {$r=Add-FixtureRow 1;Request-DomeniaLiveProbe $r -Priority;Expect ($script:Live.Pending.Count -eq 0)}
Case 'One selection queues exactly one machine' {$a=Add-FixtureRow 1;$null=Add-FixtureRow 2;Pick $a;Expect ($script:Live.Pending.Count -eq 1 -and $script:Live.PendingKeys.Count -eq 1)}
Case 'One selection starts only its own probe' {$a=Add-FixtureRow 1;$null=Add-FixtureRow 2;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].Payload.Computer -eq $a.UPN)}
Case 'Duplicate event shares one intent' {$a=Add-FixtureRow 1;Pick $a;$id=$script:Live.ProbeSelection.RequestId;Pick $a;Expect ($script:Live.ProbeSelection.RequestId -ceq $id -and $script:Live.Pending.Count -eq 1)}
Case 'Selection respects debounce' {$a=Add-FixtureRow 1;Pick $a;$script:Live.PendingKeys[(Get-DomeniaLiveObjectKey $a)].ReadyAfter=[datetime]::UtcNow.AddHours(1);Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Fast A then B discards unsent A' {$a=Add-FixtureRow 1;$b=Add-FixtureRow 2;Pick $a;Pick $b;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].Payload.Computer -eq $b.UPN -and $a.SessionState -ne 'En attente de vérification')}
Case 'Non-machine selection clears pending machine' {$a=Add-FixtureRow 1;$b=Add-FixtureRow 2 -Kind Utilisateur;Pick $a;Pick $b;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'No selection does not start anything' {$a=Add-FixtureRow 1;Pick $a;Pick $null;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Multiple selection never becomes a batch probe' {$a=Add-FixtureRow 1;$b=Add-FixtureRow 2;Pick $a;$script:Ctrl.DgObjects.SelectedItems=@($a,$b);Select-DomeniaLiveResult;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Programmatic selection is suppressed' {$a=Add-FixtureRow 1;$script:SuppressGridSelectionEvents=$true;Pick $a;Expect ($null -eq $script:Live.ProbeSelection)}
Case 'Disabled grid does not probe' {$a=Add-FixtureRow 1;$script:Ctrl.DgObjects.IsEnabled=$false;Pick $a;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Write in progress blocks verification' {$a=Add-FixtureRow 1;$script:ActiveWriteTaskId='write';Pick $a;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Unknown write blocks verification' {$a=Add-FixtureRow 1;$script:WriteState='Unknown';Pick $a;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Unchecked user verification sends only one selected ping' {$a=Add-FixtureRow 1;$script:Live.AutoDetect=$false;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].OperationId -eq 'LiveSelectedPing' -and -not $script:Calls[0].Payload.ProbeUser)}
Case 'Manual recheck works for one selected row when unchecked' {$a=Add-FixtureRow 1;$null=Add-FixtureRow 2;$script:Live.AutoDetect=$false;Pick $a;Request-DomeniaLiveRecheck;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].Payload.Computer -eq $a.UPN)}
# SP-15: unchecked « Vérifier au clic » (the default) - a click preloads the AD fiche only; the ping needs a gesture.
Case 'SP-15 Unchecked check on click: a click sends no ping' {$a=Add-FixtureRow 1;$script:Live.VerifyOnClick=$false;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0 -and $null -eq $script:Live.ProbeSelection -and $script:Live.Pending.Count -eq 0 -and $a.SessionState -ne 'En attente de vérification')}
Case 'SP-15 Unchecked check on click: Reverifier ce poste stays the manual gesture' {$a=Add-FixtureRow 1;$script:Live.VerifyOnClick=$false;Pick $a;Request-DomeniaLiveRecheck;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].OperationId -eq 'LiveConsole' -and $script:Calls[0].Payload.Computer -eq $a.UPN)}
Case 'SP-15 Unchecked check on click: an explicit fiche opening pings, user per its option' {$a=Add-FixtureRow 1;$script:Live.VerifyOnClick=$false;$script:Live.AutoDetect=$false;Pick $a;Select-DomeniaLiveResult -Explicit;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].OperationId -eq 'LiveSelectedPing' -and -not $script:Calls[0].Payload.ProbeUser)}
Case 'SP-15 Turning the option off keeps the preference and drops an unsent click intent' {
    $a=Add-FixtureRow 1;Pick $a;Expect ($null -ne $script:Live.ProbeSelection) 'Le clic coche ne prepare pas le ping.'
    $script:Ctrl.ChkLiveVerifyOnClick=[pscustomobject]@{IsChecked=$false};$script:Ctrl.ChkLiveUsersOnClick=[pscustomobject]@{IsChecked=$true}
    Set-DomeniaLiveClickOptions;Ready;Start-DomeniaLiveBackgroundWork
    Expect ($script:Calls.Count -eq 0 -and $null -eq $script:Live.ProbeSelection -and -not [bool]$script:Live.VerifyOnClick) 'Une intention non envoyee a survecu.'
    Expect ($script:SavedSettings['LiveVerifyOnClick'] -eq $false -and $script:SavedSettings['LiveUserOnClick'] -eq $true) 'Preferences non enregistrees.'
}
Case 'Unselected manual recheck is harmless' {$null=Add-FixtureRow 1;Request-DomeniaLiveRecheck;Expect ($script:Calls.Count -eq 0 -and $script:Live.Pending.Count -eq 0)}
Case 'Cached selection waits for AD' {$a=Add-FixtureRow 1 -Cached;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;Expect ($null -ne $script:Live.ProbeSelection -and $script:Calls.Count -eq 0)}
Case 'AD confirmation serves a waiting selection only' {$a=Add-FixtureRow 1 -Cached;Pick $a;$null=Add-FixtureRow 2;$null=Add-FixtureRow 1;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].Payload.Computer -eq $a.UPN)}
Case 'Different GUID does not reuse old intent' {$a=Add-FixtureRow 1;Pick $a;$a.Guid=[guid]::NewGuid().ToString();Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Old search generation cannot start' {$a=Add-FixtureRow 1;Pick $a;$script:GlobalSearchGeneration++;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Old account identity cannot start' {$a=Add-FixtureRow 1;Pick $a;$script:Live.ProbeSelection.Identity='other';Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 0)}
Case 'Rejected remote identity permits one credential-free ping' {$a=Add-FixtureRow 1;Pick $a;$script:Live.RemoteFaulted=$true;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Calls[0].OperationId -eq 'LiveSelectedPing' -and -not $script:Calls[0].Payload.ProbeUser)}
Case 'An active same-machine probe is shared on recheck' {$a=Add-FixtureRow 1;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;Request-DomeniaLiveRecheck;Ready;Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1)}
Case 'Completed intent is not replayed by later ticks' {$a=Add-FixtureRow 1;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;$script:AsyncJobs.Clear();$script:Live.Busy.Clear();Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1)}
Case 'Arriving new AD row cannot expand a selection probe' {$a=Add-FixtureRow 1;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;foreach($n in 2..80){$null=Add-FixtureRow $n};Start-DomeniaLiveBackgroundWork;Expect ($script:Calls.Count -eq 1 -and $script:Live.Pending.Count -eq 0)}
Case 'Timeout keeps last observation with its old date' {
    $old=[pscustomobject]@{LastUser='TEST\person';ObservedUtc='2025-01-01T00:00:00Z';Guid='g';LastSource='old'}
    $r=ConvertTo-DomeniaLiveObservation ([pscustomobject]@{Guid='g';Outcome='Timeout';Computer='PC';Key='k'}) $old
    Expect ($r.LastUser -eq 'TEST\person' -and $r.ObservedUtc -eq $old.ObservedUtc)
}
Case 'A console result updates cache even after selecting another row' {
    $a=Add-FixtureRow 1;$b=Add-FixtureRow 2;Pick $a;Ready;Start-DomeniaLiveBackgroundWork;$state=$script:Calls[0].CallbackState;Pick $b
    Complete-DomeniaLiveProbe ([pscustomobject]@{Key=$state.Key;Computer=$state.Computer;Guid=$state.Guid;Outcome='Observed';User='TEST\person';Source='fixture';Presence='En ligne'}) $state
    Expect ($script:Live.Observations.ContainsKey($state.Key) -and $script:Live.SaveQueue.Count -eq 0 -and $a.SessionDisplay -eq 'TEST\person' -and $b.SessionDisplay -ne 'TEST\person')
}
Case 'Restored OU schedules a single search' {Restore-Request;Invoke-DomeniaRestoredOuSearch;Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 1 -and $script:SearchCalls[0].Preserve -and $null -eq $script:Continuity.RestoreSearch)}
Case 'Restoration is deferred while settings are applied' {Restore-Request;$script:RestoringSettings=$true;Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0 -and $null -ne $script:Continuity.RestoreSearch)}
Case 'Restoration is deferred during a write' {Restore-Request;$script:WriteState='Unknown';Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0 -and $null -ne $script:Continuity.RestoreSearch)}
Case 'Restoration waits for live infrastructure' {Restore-Request;$script:Live=$null;Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0 -and $null -ne $script:Continuity.RestoreSearch)}
Case 'Changed OU wins over a pending restoration' {Restore-Request;$script:SelectedBranchDn='OU=Other,DC=example,DC=invalid';Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0 -and $null -eq $script:Continuity.RestoreSearch)}
# D032 (lot recherche): the OU restoration is guarded by the OU search text, not by the global bar.
Case 'Changed text wins over a pending restoration' {Restore-Request;$script:Ctrl.TxtBranchSearch.Text='new';Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0 -and $null -eq $script:Continuity.RestoreSearch)}
Case 'Global text does not cancel an OU restoration' {Restore-Request;$script:Ctrl.TxtGlobalSearch.Text='new';Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 1 -and $null -eq $script:Continuity.RestoreSearch)}
Case 'Changed subtree wins over a pending restoration' {Restore-Request;$script:Ctrl.ChkSubtree.IsChecked=$false;Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0)}
Case 'Changed type wins over a pending restoration' {Restore-Request;$script:FixtureType='(objectClass=user)';Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0)}
Case 'Changed generation cancels the pending restore' {Restore-Request;$script:GlobalSearchGeneration++;Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0)}
Case 'Changed account cancels the pending restore' {Restore-Request;$script:SessionEpoch++;Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0)}
Case 'Duplicate ContentRendered does not restart bookmark restore' {
    $script:Continuity.Bookmarks[$script:FixtureContext]=[pscustomobject]@{Selected=$script:SelectedBranchDn;Expanded=@();Subtree=$true}
    Start-DomeniaTreeBookmarkRestore;$script:Continuity.SelectedRestored=$true;Start-DomeniaTreeBookmarkRestore
    Expect $script:Continuity.SelectedRestored
}
Case 'Missing bookmark does not trigger a domain scan' {Start-DomeniaTreeBookmarkRestore;Invoke-DomeniaTreeBookmarkRestore;Invoke-DomeniaRestoredOuSearch;Expect ($script:SearchCalls.Count -eq 0)}
Case 'Tree selection restores scope then loads without another click' {
    $node=[pscustomobject]@{Tag=[pscustomobject]@{DN=$script:SelectedBranchDn;Loaded=$true};IsExpanded=$false;IsEnabled=$true;IsSelected=$false}
    $node|Add-Member -MemberType ScriptMethod -Name BringIntoView -Value {}
    $script:FixtureNodes=@($node)
    $script:Continuity.Bookmarks[$script:FixtureContext]=[pscustomobject]@{Selected=$script:SelectedBranchDn;Expanded=@();Subtree=$false}
    Start-DomeniaTreeBookmarkRestore;Invoke-DomeniaTreeBookmarkRestore;Invoke-DomeniaRestoredOuSearch
    Expect ($node.IsSelected -and $script:SearchCalls.Count -eq 1 -and $script:SearchCalls[0].Scope -eq 'OneLevel' -and -not $script:SuppressBranchAutoLoad)
}
Case 'Other slow branches do not delay the restored OU search' {
    $node=[pscustomobject]@{Tag=[pscustomobject]@{DN=$script:SelectedBranchDn;Loaded=$true};IsExpanded=$false;IsEnabled=$true;IsSelected=$false}
    $node|Add-Member -MemberType ScriptMethod -Name BringIntoView -Value {}
    $other=[pscustomobject]@{Tag=[pscustomobject]@{DN='OU=Slow,DC=example,DC=invalid';Loaded=$false};IsExpanded=$true;IsEnabled=$false;IsSelected=$false}
    $script:FixtureNodes=@($node,$other)
    $script:Continuity.Bookmarks[$script:FixtureContext]=[pscustomobject]@{Selected=$script:SelectedBranchDn;Expanded=@($other.Tag.DN);Subtree=$true}
    Start-DomeniaTreeBookmarkRestore;Invoke-DomeniaTreeBookmarkRestore;Invoke-DomeniaRestoredOuSearch
    Expect ($script:SearchCalls.Count -eq 1 -and $script:Continuity.Restoring)
}
Case 'Expired missing bookmark has no broad fallback' {
    $script:Continuity.Restoring=$true;$script:Continuity.RestoreDeadline=[datetime]::UtcNow.AddSeconds(-1)
    Invoke-DomeniaTreeBookmarkRestore;Invoke-DomeniaRestoredOuSearch
    Expect (-not $script:Continuity.Restoring -and $script:SearchCalls.Count -eq 0)
}
Case 'Every results column has a plain stable header' {
    [xml]$xml=Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot);$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('p','http://schemas.microsoft.com/winfx/2006/xaml/presentation');$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    $cols=@($xml.SelectNodes("//p:DataGrid[@x:Name='DgObjects']/p:DataGrid.Columns/*",$ns))
    Expect ($cols.Count -eq 16) 'Expected compact result columns missing'
    Expect (@($cols|Where-Object{$_.GetAttribute('SortMemberPath') -eq 'DirectoryState'}).Count -eq 1) 'Freshness column missing'
    foreach($c in $cols){Expect (-not [string]::IsNullOrWhiteSpace([string]$c.GetAttribute('Header'))) ('Blank header: '+$c.OuterXml)}
}
if($env:OS -eq 'Windows_NT' -and -not $SkipWpf){
    Case 'Native WPF headers remain visible after reorder and narrow layout' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)));$window=$null
        try{
            $window=[Windows.Markup.XamlReader]::Load($reader);$grid=$window.FindName('DgObjects')
            $window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.Show()
            $window.FindName('WorkspaceTabs').SelectedItem=$window.FindName('WsSearch')
            # Le banc doit mesurer un rendu, pas une declaration. DgObjects porte EnableColumnVirtualization
            # (Domenia-Core.ps1): WPF ne realise que les en-tetes qui recoupent le viewport. Or l'ecran de la
            # VM de labo est en 1024x768 session 0 et la fenetre y est bornee a 1044x788 quelle que soit la
            # taille demandee; l'onglet Resultats y ecrase la zone du DataGrid a 294x0, ou 3 en-tetes sur 18
            # seulement existent. Verifier un en-tete realise dans ce viewport-la ne dirait rien du produit.
            # On donne donc au DataGrid le viewport qu'il a sur un poste de travail et des lignes, sans
            # toucher a la virtualisation: c'est elle qui est mesuree ici, pas coupee.
            $grid.ItemsSource=@(1..30|ForEach-Object{[pscustomobject]@{Name="PC-$_";Type='Machine';Association='assoc';Etat='Actif'}})
            $grid.Width=1200;$grid.Height=420
            $window.Measure([Windows.Size]::new(1280,800));$window.Arrange([Windows.Rect]::new(0,0,1280,800));$window.UpdateLayout()
            # Garde-fou: sans viewport, la recherche d'un en-tete realise est vide de sens et le cas passerait
            # sur un fantome. Il ne doit plus jamais mesurer un DataGrid ecrase comme celui de la VM.
            Expect ($grid.ActualWidth -ge 1000 -and $grid.ActualHeight -ge 400) ('Viewport mesure par le banc trop petit pour rendre un en-tete : '+[Math]::Round($grid.ActualWidth,0)+'x'+[Math]::Round($grid.ActualHeight,0))
            Expect ($grid.EnableColumnVirtualization) 'Le banc a perdu la virtualisation de colonnes du produit : il ne mesurerait plus le mecanisme qu il est cense verifier.'
            $association=@($grid.Columns|Where-Object{$_.SortMemberPath -eq 'Association'})[0]
            Expect ($association.Header -is [string] -and $association.Header -eq 'Association mémorisée')
            $association.DisplayIndex=2;$association.Width=150;$window.UpdateLayout()
            Expect ($association.Header -eq 'Association mémorisée')
            $q=[Collections.Generic.Queue[Windows.DependencyObject]]::new();$q.Enqueue($grid);$found=$false;$budget=0;$porteurs=0
            while($q.Count -gt 0 -and $budget++ -lt 20000){
                $v=$q.Dequeue()
                if($v -is [Windows.Controls.Primitives.DataGridColumnHeader] -and [string]$v.Content -eq 'Association mémorisée'){
                    $porteurs++
                    if([object]::ReferenceEquals($v.Column,$association)){
                        Expect ($v.ActualWidth -gt 0 -and $v.ActualHeight -gt 0 -and $v.IsVisible) ('En-tete realise mais non rendu : '+[Math]::Round($v.ActualWidth,0)+'x'+[Math]::Round($v.ActualHeight,0)+' visible='+$v.IsVisible)
                        $found=$true
                    }
                }
                for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($v);$i++){$q.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($v,$i))}
            }
            Expect $found 'Association header was not realized.'
            # Un seul en-tete doit porter ce libelle apres reorder: un second prouverait un en-tete fantome
            # laisse par WPF sur l'ancienne position de la colonne.
            Expect ($porteurs -eq 1) ("$porteurs en-tetes realises portent le libelle Association memorisee apres reorder, un seul est attendu.")
            Expect ($budget -lt 20000) "Budget de parcours de l'arbre visuel epuise : la recherche d'en-tete n'a rien pu conclure."
            foreach($c in $grid.Columns){Expect (-not [string]::IsNullOrWhiteSpace([string]$c.Header))}
        }finally{$reader.Close();if($null -ne $window){$window.Close()}}
    }
    # FO-18: actions of a multiple selection of the list (real Park.UI functions, real WPF controls).
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $parkTokens=$null;$parkErrors=$null
    $parkAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Park.UI.ps1'),[ref]$parkTokens,[ref]$parkErrors)
    foreach($name in @('Set-DomeniaParkControlVisible','Get-DomeniaParkSelectionTargets','Update-DomeniaParkSelectionBar','Start-DomeniaParkSelectionSurvey')){
        $node=@($parkAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if($node.Count -ne 1){throw ('Definition ambiguous: '+$name)}
        Invoke-Expression $node[0].Extent.Text
    }
    function Add-SelectionBarControls {
        $script:ListSurveyBlocked=$false;$script:DemoMode=$false
        $bar=[Windows.Controls.StackPanel]::new();$bar.Visibility='Collapsed';$script:Ctrl.UxSelectionBar=$bar
        foreach($name in @('LblSelectionBar','LblSelectionReadState')){$script:Ctrl[$name]=[Windows.Controls.TextBlock]::new()}
        foreach($name in @('BtnSelectionPing','BtnSelectionConsole')){$script:Ctrl[$name]=[Windows.Controls.Button]::new()}
    }
    # The selected rows are shown (Items): the surveys of the selection keep the selected rows still displayed (point 60).
    function Select-FixtureRows {param([object[]]$Rows,[object[]]$Shown=$null) $script:Ctrl.DgObjects.SelectedItems=@($Rows);$script:Ctrl.DgObjects.SelectedItem=$(if(@($Rows).Count){@($Rows)[0]}else{$null});$script:Ctrl.DgObjects|Add-Member -NotePropertyName Items -NotePropertyValue $(if($null -ne $Shown){@($Shown)}else{@($Rows)}) -Force}
    function New-SelectedRow {param([int]$Number,[string]$Kind='Machine',[switch]$NoGuid) [pscustomobject]@{Type=$Kind;Name=('PC'+$Number);DN=('CN=PC'+$Number+',OU=Test,DC=example,DC=invalid');Guid=$(if($NoGuid){''}else{'00000000-0000-0000-0000-'+$Number.ToString('000000000000')})}}
    Case 'FO-18 The selection bar appears from two rows and names what is selected' {
        Add-SelectionBarControls
        Select-FixtureRows @(New-SelectedRow 1);Update-DomeniaParkSelectionBar
        Expect ($script:Ctrl.UxSelectionBar.Visibility -eq 'Collapsed' -and $script:Ctrl.LblSelectionReadState.Visibility -eq 'Visible') 'Bar shown for a single row.'
        Select-FixtureRows @((New-SelectedRow 1),(New-SelectedRow 2),(New-SelectedRow 3));Update-DomeniaParkSelectionBar
        Expect ($script:Ctrl.UxSelectionBar.Visibility -eq 'Visible' -and $script:Ctrl.LblSelectionReadState.Visibility -eq 'Collapsed') 'Bar hidden for three rows.'
        Expect ([string]$script:Ctrl.LblSelectionBar.Text -eq '3 postes sélectionnés :') ([string]$script:Ctrl.LblSelectionBar.Text)
        Expect ($script:Ctrl.BtnSelectionPing.IsEnabled -and $script:Ctrl.BtnSelectionConsole.IsEnabled) 'Selection surveys disabled.'
        Select-FixtureRows @((New-SelectedRow 1 'Utilisateur'),(New-SelectedRow 2 'Utilisateur'),(New-SelectedRow 3));Update-DomeniaParkSelectionBar
        Expect ([string]$script:Ctrl.LblSelectionBar.Text -eq '3 lignes sélectionnées dont 1 poste :' -and $script:Ctrl.BtnSelectionPing.IsEnabled) ([string]$script:Ctrl.LblSelectionBar.Text)
        Select-FixtureRows @((New-SelectedRow 1 'Utilisateur'),(New-SelectedRow 2 'Groupe'));Update-DomeniaParkSelectionBar
        Expect ([string]$script:Ctrl.LblSelectionBar.Text -eq '2 lignes sélectionnées :' -and -not $script:Ctrl.BtnSelectionPing.IsEnabled -and -not $script:Ctrl.BtnSelectionConsole.IsEnabled) 'Workstation survey offered without workstation.'
    }
    Case 'FO-18 Selection surveys are refused while the list is surveyed, on a whole-domain view and in demonstration' {
        Add-SelectionBarControls;Select-FixtureRows @((New-SelectedRow 1),(New-SelectedRow 2))
        Update-DomeniaParkSelectionBar -ListRunning $true;Expect (-not $script:Ctrl.BtnSelectionPing.IsEnabled) 'Second survey offered during a survey.'
        Update-DomeniaParkSelectionBar;Expect $script:Ctrl.BtnSelectionPing.IsEnabled 'Survey not offered again after the survey.'
        $script:ListSurveyBlocked=$true;Update-DomeniaParkSelectionBar;Expect (-not $script:Ctrl.BtnSelectionConsole.IsEnabled) 'Survey of a whole-domain view offered.'
        $script:ListSurveyBlocked=$false;$script:DemoMode=$true;Update-DomeniaParkSelectionBar;Expect (-not $script:Ctrl.BtnSelectionPing.IsEnabled) 'Survey offered in demonstration.'
        $script:DemoMode=$false;$script:Ctrl.DgObjects.IsEnabled=$false;Update-DomeniaParkSelectionBar;Expect (-not $script:Ctrl.BtnSelectionPing.IsEnabled) 'Survey offered on a disabled list.'
    }
    Case 'FO-18 Selection surveys send only the selected workstations with their AD identity, through the list survey' {
        Add-SelectionBarControls;$script:SurveyCalls=[Collections.Generic.List[object]]::new();$script:SurveyStatus=''
        function Start-DomeniaOnlinePark {param([switch]$Selection,[switch]$PingOnly,[object[]]$ScopeTargets,[int]$SkippedTargets=0)$script:SurveyCalls.Add([pscustomobject]@{Selection=[bool]$Selection;PingOnly=[bool]$PingOnly;Targets=@($ScopeTargets);Skipped=$SkippedTargets})}
        function Set-Status {param($Text,$Level)$script:SurveyStatus=[string]$Text}
        Select-FixtureRows @((New-SelectedRow 1),(New-SelectedRow 2 -NoGuid),(New-SelectedRow 3 'Utilisateur'),(New-SelectedRow 4))
        Start-DomeniaParkSelectionSurvey -Mode Ping;Start-DomeniaParkSelectionSurvey -Mode Console
        Expect ($script:SurveyCalls.Count -eq 2 -and $script:SurveyCalls[0].Selection -and $script:SurveyCalls[0].PingOnly -and -not $script:SurveyCalls[1].PingOnly) 'Selection survey mode lost.'
        $first=$script:SurveyCalls[0]
        Expect ($first.Targets.Count -eq 2 -and $first.Skipped -eq 1) ('Targets '+$first.Targets.Count+' skipped '+$first.Skipped)
        Expect ((@($first.Targets|ForEach-Object{[string]$_.name}) -join ',') -eq 'PC1,PC4' -and [string]$first.Targets[1].distinguished_name -eq 'CN=PC4,OU=Test,DC=example,DC=invalid' -and [string]$first.Targets[1].object_guid -eq '00000000-0000-0000-0000-000000000004') 'AD identity of the selected workstations.'
        Select-FixtureRows @((New-SelectedRow 3 'Utilisateur'));Start-DomeniaParkSelectionSurvey -Mode Ping
        Expect ($script:SurveyCalls.Count -eq 2 -and $script:SurveyStatus -eq 'Aucun poste dans la sélection.') $script:SurveyStatus
        # Point 60 (W08): a selected row no longer shown (hidden by a filter) is not surveyed (same plan as the export).
        $shown=New-SelectedRow 1;$hidden=New-SelectedRow 4
        Select-FixtureRows @($shown,$hidden) -Shown @($shown);Start-DomeniaParkSelectionSurvey -Mode Ping
        Expect ($script:SurveyCalls.Count -eq 3 -and (@($script:SurveyCalls[2].Targets|ForEach-Object{[string]$_.name}) -join ',') -eq 'PC1') 'Selected row hidden by a filter surveyed.'
    }
}else{$script:Checks.Add([pscustomobject]@{Name='Native WPF headers';Status='Skipped';Error='Windows WPF required.'})}
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$skipped=@($script:Checks|Where-Object{$_.Status -eq 'Skipped'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-selection-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.4-SEARCH';HostVersion=$PSVersionTable.PSVersion.ToString();OS=[Environment]::OSVersion.VersionString;Passed=$passed;Failed=$failed;Skipped=$skipped;Complete=($failed -eq 0 -and $skipped -eq 0);LiveAD=$false;LiveCIM=$false;PersonalData=$false;Tests=$script:Checks.ToArray()}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed passed ; $failed failed ; $skipped skipped. $ReportPath");$script:Checks|Where-Object{$_.Status -ne 'Passed'}|Format-Table -AutoSize}
if($failed -or $skipped){exit 1}
