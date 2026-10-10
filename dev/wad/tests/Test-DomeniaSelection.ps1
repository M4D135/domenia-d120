#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$SkipWpf)
$ErrorActionPreference='Stop'
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
. (Join-Path $wad 'modules\Domenia-Experience.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Live.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
# D027: Live.UI builds its negative cache with the cache rules.
. (Join-Path $wad 'modules\Domenia-Cache.Model.ps1')
# FI-05 / PF-06: the progressive search and the layouts take their timers from the protected factory of the engine.
. (Join-Path $wad 'modules\Domenia-Engine.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Engine.UI.ps1')
. (Join-Path $wad 'modules\Domenia-Live.UI.ps1')
. (Join-Path $wad 'modules\Domenia-Continuity.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Continuity.UI.ps1')
function Get-DomeniaLiveIdentitySignal {return [pscustomobject]@{Signal=$script:Live.Identity}}
function Test-DomeniaSearchStateCurrent {param($State);return $State.Generation -eq $script:GlobalSearchGeneration}
function Test-DomeniaAccessBusyWrite {return ($script:WriteState -in @('Unknown','UnknownPending') -or [bool]$script:ActiveWriteTaskId)}
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
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
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:Stopped.Add([string]$Id)}
function Invoke-GlobalSearch {param([switch]$AllowEmpty,[switch]$SilentError,[switch]$PreserveSelection,[string]$SearchMode)
    $script:SearchCalls.Add([pscustomobject]@{DN=$script:SelectedBranchDn;Scope=(Get-DomeniaSearchScope).Scope;Preserve=[bool]$PreserveSelection})
    $script:GlobalSearchGeneration++
}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable)
    if($OperationId -notin @('LiveConsole','LiveSelectedPing')){throw ('Unexpected operation: '+$OperationId)}
    $id='fake-'+[guid]::NewGuid().ToString('N')
    $job=[pscustomobject]@{Id=$id;OperationId=$OperationId;Payload=$Payload;CallbackState=$CallbackState}
    $script:AsyncJobs[$id]=$job;$script:Calls.Add($job)
    return $id
}
function Reset-Fixture {
    $script:SearchMode='OU';$script:AccessState=$null;$script:SelectedObject=$null
    $script:SessionEpoch=7L;$script:GlobalSearchGeneration=11;$script:WriteState='Idle';$script:ActiveWriteTaskId=''
    $script:SuppressGridSelectionEvents=$false;$script:SuppressBranchAutoLoad=$false;$script:RestoringSettings=$false
    $script:AsyncEngineClosing=$false;$script:DirectoryCredentialFaulted=$false
    $script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:DetailedProbe=$null
    $script:Calls=[Collections.Generic.List[object]]::new();$script:Stopped=[Collections.Generic.List[string]]::new();$script:SearchCalls=[Collections.Generic.List[object]]::new()
    $script:FixtureContext='test-domain-reader';$script:FixtureType='(objectClass=*)';$script:FixtureNodes=@()
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Connected=$true}
    $script:SelectedBranchDn='OU=Test,DC=example,DC=invalid'
    $script:Ctrl=@{
        DgObjects=[pscustomobject]@{IsEnabled=$true;SelectedItem=$null;SelectedItems=@();SelectedIndex=-1}
        TxtGlobalSearch=[pscustomobject]@{Text=''};TxtBranchSearch=[pscustomobject]@{Text=''};ChkSubtree=[pscustomobject]@{IsChecked=$true}
        LblLinkProbeStatus=[pscustomobject]@{Text=''}
    }
    $state=[pscustomobject]@{Limit=500;PreserveSelectionDn='';Generation=11}
    $script:Live=[pscustomobject]@{
        PresenceEvents=[Collections.Concurrent.ConcurrentQueue[object]]::new();PresenceSeen=@{};Identity='reader-7';Epoch=7L;AutoDetect=$true;ProbeSelection=$null;RemoteFaulted=$false
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
    Expect ($script:Live.SaveQueue.Count -eq 1 -and $a.SessionDisplay -eq 'TEST\person' -and $b.SessionDisplay -ne 'TEST\person')
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
    [xml]$xml=Get-MainXaml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('p','http://schemas.microsoft.com/winfx/2006/xaml/presentation');$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    $cols=@($xml.SelectNodes("//p:DataGrid[@x:Name='DgObjects']/p:DataGrid.Columns/*",$ns))
    Expect ($cols.Count -eq 18)
    foreach($c in $cols){Expect (-not [string]::IsNullOrWhiteSpace([string]$c.GetAttribute('Header'))) ('Blank header: '+$c.OuterXml)}
}
if($env:OS -eq 'Windows_NT' -and -not $SkipWpf){
    Case 'Native WPF headers remain visible after reorder and narrow layout' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml));$window=$null
        try{
            $window=[Windows.Markup.XamlReader]::Load($reader);$grid=$window.FindName('DgObjects')
# DgObjects porte EnableColumnVirtualization (Domenia-Core.ps1): WPF ne realise les en-tetes que des
# colonnes qui recoupent le viewport, et la mesure de ce banc fait 294 px de large pour 18 colonnes.
# L'en-tete hors viewport n'est donc jamais realise, ce qui ne dit rien du produit: on coupe la
# virtualisation pour verifier le contenu des en-tetes, pas le mecanisme de virtualisation de WPF.
$grid.EnableColumnVirtualization=$false
            $window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.Show()
            $window.FindName('WorkspaceTabs').SelectedItem=$window.FindName('WsSearch')
            $window.Measure([Windows.Size]::new(1280,800));$window.Arrange([Windows.Rect]::new(0,0,1280,800));$window.UpdateLayout()
            $association=@($grid.Columns|Where-Object{$_.SortMemberPath -eq 'Association'})[0]
            Expect ($association.Header -is [string] -and $association.Header -eq 'Association mémorisée')
            $association.DisplayIndex=2;$association.Width=150;$window.UpdateLayout()
            Expect ($association.Header -eq 'Association mémorisée')
            $q=[Collections.Generic.Queue[Windows.DependencyObject]]::new();$q.Enqueue($grid);$found=$false;$budget=0
            while($q.Count -gt 0 -and $budget++ -lt 10000){
                $v=$q.Dequeue()
                if($v -is [Windows.Controls.Primitives.DataGridColumnHeader] -and [object]::ReferenceEquals($v.Column,$association)){
                    Expect ($v.ActualWidth -gt 0 -and $v.ActualHeight -gt 0 -and $v.IsVisible -and [string]$v.Content -eq 'Association mémorisée');$found=$true
                }
                for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($v);$i++){$q.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($v,$i))}
            }
            Expect $found 'Association header was not realized.'
            foreach($c in $grid.Columns){Expect (-not [string]::IsNullOrWhiteSpace([string]$c.Header))}
        }finally{$reader.Close();if($null -ne $window){$window.Close()}}
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
