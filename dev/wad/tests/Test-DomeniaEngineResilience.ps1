#requires -Version 5.1
# Synthetic callback/queue tests. No WPF window, LDAP, workstation, VM or network.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
foreach($name in @('Common.Model','Probes.Model','Live.Model','Live.UI','Storage.UI','Engine.UI','Park.Model','Park.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
if(-not ('Domenia.Native.ProbeResult' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')}
$checks=[Collections.Generic.List[object]]::new()
function Assert {param($Value,[string]$Why='Assertion fausse')if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)try{& $Body|Out-Null;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
# Closed substitutes: admission and UI are observed; no worker code is executed.
function Get-DomeniaControl {param($Name)return $null}
function Set-DomeniaControlText {param($Name,$Text)$script:Texts[$Name]=$Text;return $true}
function Reset-DomeniaLiveIdentity {}
function Write-AppLog {param($Message,$Level)}
function Set-Status {param($Text,$Level)$script:Status=$Text}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
function Get-DomeniaLiveWorkerCount {param($Operation='')return 0}
function Get-CfgValue {param($Section,$Name,$Default)return $Default}
function Test-DomeniaLiveBackgroundAllowed {param($Source)return $true}
function Get-DomeniaLiveDatabasePath {return '/synthetic/domain.db'}
function Test-DomeniaLiveSearchActive {return $script:SearchActive}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties)return $Result}
function Get-DomeniaIndexScope {return [pscustomobject]@{IsDomain=$true;BaseDn='DC=example,DC=invalid'}}
function Get-DomeniaLocalDatabasePathForRead {return '/synthetic/domain.db'}
function Get-DomeniaStorageWorkerCode {return 'throw "Synthetic worker must never execute"'}
function Get-DomeniaLocalIndexReadWorkerCode {return 'throw "Synthetic worker must never execute"'}
function Start-UiTask {
 param($Name,$OperationId,$Code,$Payload,$CallbackState,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TaskClass,$ReplaceKey)
 $script:Dispatched=[pscustomobject]@{Payload=$Payload;State=$CallbackState;Operation=$OperationId}
 return $script:Admission
}
function New-FixtureTimer {
 $timer=[pscustomobject]@{Starts=0;Stops=0;IsEnabled=$false}
 $timer|Add-Member ScriptMethod Start {$this.Starts++;$this.IsEnabled=$true}
 $timer|Add-Member ScriptMethod Stop {$this.Stops++;$this.IsEnabled=$false}
 return $timer
}
function Reset-Fixture {
 $script:Texts=@{};$script:Status='';$script:Admission='';$script:SearchActive=$false;$script:Dispatched=$null
 $script:SessionEpoch=7L;$script:AsyncEngineClosing=$false;$script:DemoMode=$false;$script:ActiveWriteTaskId='';$script:WriteState='Idle'
 $script:AsyncJobs=[ordered]@{};$script:DetachedReadJobs=@();$script:IndexWalk=$null;$script:IndexProgressTimer=$null
 $script:DatabaseScopedPath='/synthetic/domain.db';$script:Conn=[pscustomobject]@{Server='example.invalid'}
 $script:Live=[pscustomobject]@{NextStart=[datetime]::MinValue;CacheReady=$true;Identity='reader';Scope='scope';Search=$null;SaveQueue=@{};QueryToSave=$null;SaveAfter=[datetime]::MinValue;SaveInFlight=0;SaveJob='';SaveBatch=$null;SaveFault='';Busy=@{};Deferred=[Collections.Generic.Queue[object]]::new();Refresh=[Collections.Generic.Queue[object]]::new();IdentityRows=[Collections.Generic.Queue[object]]::new();PresenceEvents=[Collections.Concurrent.ConcurrentQueue[object]]::new();PendingKeys=@{};Pending=[Collections.Generic.Queue[object]]::new();ProbeSelection=$null;ObservationsLoaded=$false}
 $script:Persistence=[pscustomobject]@{Pending=[ordered]@{};Timer=(New-FixtureTimer);Failures=0;Conflicts=@{};InFlight=0;LinkRequestTimer=$null;LinkPersistenceMore=$false;LinkBusy=$false;Job='';Next=[datetime]::MinValue;Fault='';LegacyImportJob='';InFlightItems=@()}
}
Case 'LiveCache refused write keeps observations and query queued' {
 Reset-Fixture;$row=[pscustomobject]@{Key='pc1'};$query=[pscustomobject]@{QueryKey='q1'};$script:Live.SaveQueue.pc1=$row;$script:Live.QueryToSave=$query
 $thrown=$false;try{Start-DomeniaLiveBackgroundWork}catch{$thrown=$true}
 Assert $thrown;Assert ($script:Live.SaveQueue.Count -eq 1);Assert ([object]::ReferenceEquals($script:Live.QueryToSave,$query));Assert ($script:Live.SaveInFlight -eq 0)
}
Case 'LiveCache admitted write moves exact items into the in-flight batch' {
 Reset-Fixture;$script:Admission='job1';$row=[pscustomobject]@{Key='pc1'};$script:Live.SaveQueue.pc1=$row;$script:Live.QueryToSave=[pscustomobject]@{QueryKey='q1'}
 Start-DomeniaLiveBackgroundWork
 Assert ($script:Live.SaveQueue.Count -eq 0 -and $null -eq $script:Live.QueryToSave);Assert ($script:Live.SaveInFlight -eq 2);Assert ([object]::ReferenceEquals($script:Dispatched.State.Observations[0],$row))
}
Case 'LiveCache refused read remains eligible for later admission' {
 Reset-Fixture;$script:SearchActive=$true
 $script:Live.Search=[pscustomobject]@{CacheRequested=$false;Identity='reader';Epoch=7L;QueryKey='q';State=[pscustomobject]@{Limit=200};CacheProgress=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
 $thrown=$false;try{Start-DomeniaLiveBackgroundWork}catch{$thrown=$true}
 Assert $thrown;Assert (-not $script:Live.Search.CacheRequested)
 $script:Admission='job2';Start-DomeniaLiveBackgroundWork;Assert $script:Live.Search.CacheRequested
}
Case 'AD success detaches stale cache queue and allows the idle heartbeat' {
 Reset-Fixture;$script:SearchActive=$true;$old=[Collections.Concurrent.ConcurrentQueue[object]]::new();$old.Enqueue('old')
 $s=[pscustomobject]@{Final=$null;Ended=$false;Error='';CacheProgress=$old;Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();Finalized=$true;Prune=$null;CacheRequested=$true};$script:Live.Search=$s
 $state=[pscustomobject]@{LiveState=$s;BaseDn='DC=example,DC=invalid';Scope='Subtree'}
 Complete-DomeniaLiveSearch ([pscustomobject]@{Rows=@();BaseDn=$state.BaseDn;Scope=$state.Scope;Partial=$false}) $state
 Assert (-not [object]::ReferenceEquals($old,$s.CacheProgress));Assert $s.CacheProgress.IsEmpty
 $old.Enqueue('late');Assert $s.CacheProgress.IsEmpty;Assert (-not (Test-DomeniaLiveTickNeeded))
}
Case 'AD partial result keeps cached fallback rows' {
 Reset-Fixture;$script:SearchActive=$true;$old=[Collections.Concurrent.ConcurrentQueue[object]]::new();$old.Enqueue('old')
 $s=[pscustomobject]@{Final=$null;Ended=$false;Error='';CacheProgress=$old};$script:Live.Search=$s;$state=[pscustomobject]@{LiveState=$s;BaseDn='DC=x';Scope='Subtree'}
 Complete-DomeniaLiveSearch ([pscustomobject]@{Rows=@();BaseDn='DC=x';Scope='Subtree';Partial=$true;Failure='interrupted'}) $state
 Assert ([object]::ReferenceEquals($old,$s.CacheProgress));Assert ($s.Error -eq 'interrupted')
}
Case 'Full index queue accepts replacement and refuses a new identity' {
 Reset-Fixture;$row=[pscustomobject]@{Guid='g';DN='CN=one'};Assert (Add-DomeniaIndexPersistence $row)
 for($i=1;$i -lt 256;$i++){$script:Persistence.Pending['filler'+$i]=$i}
 $new=[pscustomobject]@{Guid='g';DN='CN=one';Name='updated'};Assert (Add-DomeniaIndexPersistence $new)
 $key='Index|'+$script:DatabaseScopedPath+'|g|CN=one';Assert ([object]::ReferenceEquals($script:Persistence.Pending[$key].Row,$new));Assert ($script:Persistence.Pending.Count -eq 256)
 Assert (-not (Add-DomeniaIndexPersistence ([pscustomobject]@{Guid='g2';DN='CN=two'})))
}
Case 'Index persistence refuses a missing database context' {
 Reset-Fixture;$script:DatabaseScopedPath='';Assert (-not (Add-DomeniaIndexPersistence ([pscustomobject]@{Guid='g';DN='CN=one'})));Assert ($script:Persistence.Pending.Count -eq 0)
}
Case 'Base debounce invalidates older callbacks immediately' {
 Reset-Fixture;$script:DomeniaIndexSearchGeneration=10L;$script:DomeniaIndexSearchTimer=New-FixtureTimer
 Request-DomeniaIndexSearch;Assert ($script:DomeniaIndexSearchGeneration -eq 11);Assert ($script:DomeniaIndexSearchTimer.Starts -eq 1)
 Complete-DomeniaIndexSearchUi ([pscustomobject]@{Rows=@();Busy=$false}) ([pscustomobject]@{Generation=10L;Epoch=7L})
 Assert ($script:Texts.Count -eq 0)
}
Case 'Base errors from a previous context cannot replace current status' {
 Reset-Fixture;$script:DomeniaIndexSearchGeneration=11L
 Fail-DomeniaIndexSearchUi 'old failure' ([pscustomobject]@{Generation=11L;Epoch=6L});Assert ($script:Texts.Count -eq 0)
}
Case 'Base page size and offset are the same in callback and worker' {
 Reset-Fixture;$script:DomeniaIndexSearchTimer=$null;$script:DomeniaIndexSearchGeneration=0L;$script:Admission='j'
 [void](Start-DomeniaIndexSearch -Limit 9999 -Offset -1)
 Assert ($script:Dispatched.State.Limit -eq 500 -and $script:Dispatched.Payload.Limit -eq 500);Assert ($script:Dispatched.State.Offset -eq 0 -and $script:Dispatched.Payload.Offset -eq 0)
}
Case 'Obsolete collection releases the lazy cache buffers' {
 Reset-Fixture;$target=[pscustomobject]@{PreviousJson='large';Previous=[pscustomobject]@{large='data'}}
 $script:ParkRun=[pscustomobject]@{Epoch=6L;Path=$script:DatabaseScopedPath;Stopping=$false;Completed=$false;Targets=@($target);Timer=(New-FixtureTimer)}
 Invoke-DomeniaParkRunTick;Assert $script:ParkRun.Completed;Assert ($null -eq $target.Previous -and $target.PreviousJson -eq '');Assert ($script:ParkRun.Timer.Stops -eq 1)
}
Case 'Lazy collection decode validates GUID and clears consumed JSON' {
 Reset-Fixture;$target=[pscustomobject]@{Key='cn=one';Guid='g';Previous=$null;PreviousJson='{"Key":"cn=one","Guid":"g","Inventory":{"Rows":[1,2]}}'}
 Expand-DomeniaParkPrevious $target;Assert ($target.Previous.Inventory.Rows.Count -eq 2);Assert ($target.PreviousJson -eq '' -and -not $target.Previous.DirectoryChanged)
 $target.PreviousJson='{"Key":"cn=one","Guid":"other"}';$thrown=$false;try{Expand-DomeniaParkPrevious $target}catch{$thrown=$true};Assert $thrown;Assert ($target.PreviousJson -eq '')
}
Case 'One-level OU scope honors escaped backslash parity' {
 $base='OU=Target,DC=example,DC=invalid'
 Assert (Test-DomeniaLiveRowInScope ('CN=One\, Last,'+$base) $base 'OneLevel')
 Assert (Test-DomeniaLiveRowInScope ('CN=One\\\, Last,'+$base) $base 'OneLevel')
 Assert (-not (Test-DomeniaLiveRowInScope ('CN=One\\,OU=Nested,'+$base) $base 'OneLevel'))
 Assert (-not (Test-DomeniaLiveRowInScope ('CN=One\\,OU=Nested\\,'+$base) $base 'OneLevel'))
}
Case 'Memory query cache bounds total rows, preserving the newest full snapshot' {
 $cache=@{};$rows=@(1..5000)
 foreach($n in 1..10){Add-DomeniaLiveMemoryQuery $cache ([pscustomobject]@{QueryKey=('q'+$n);ObservedUtc=([datetime]'2026-10-12').AddMinutes($n).ToString('o');Rows=$rows})}
 Assert ($cache.Count -eq 4 -and $cache.ContainsKey('q10') -and -not $cache.ContainsKey('q6'))
 $all=0;foreach($q in $cache.Values){$all+=@($q.Rows).Count};Assert ($all -eq 20000)
 Add-DomeniaLiveMemoryQuery $cache ([pscustomobject]@{QueryKey='q10';ObservedUtc='2026-10-13';Rows=@(1..3)})
 Assert ($cache.Count -eq 4 -and $cache.q10.Rows.Count -eq 3)
}
Case 'Memory query cache retains at most twenty small queries' {
 $cache=@{};foreach($n in 1..30){Add-DomeniaLiveMemoryQuery $cache ([pscustomobject]@{QueryKey=('q'+$n);ObservedUtc=([datetime]'2026-10-12').AddMinutes($n).ToString('o');Rows=@($n)})}
 Assert ($cache.Count -eq 20 -and $cache.ContainsKey('q30') -and -not $cache.ContainsKey('q1'))
}
function Invoke-CollectionFixture {
 param([switch]$FailStream,[object[]]$Probes=$null,[int]$Rows=10000,[switch]$LongDetail,[switch]$LongAfterFirst,[int]$ProductType=1)
 $script:ProductTypeReads=0;$script:FixtureProductType=$ProductType;$script:ReadCount=0;$script:Union=@();$script:Closed=0;$script:Opened=0;$script:GroupCalls=[Collections.Generic.List[object]]::new()
 $Context=[pscustomobject]@{UseCim=$true;Domain='example.invalid';Netbios='EXAMPLE';BaseDn='DC=example,DC=invalid'}
 $Payload=[pscustomobject]@{Computer='127.0.0.1';Key='cn=fixture';Guid='g';MethodSeconds=4;ProbeUser=$true;Inventory=$true;AllowedClasses=@('Fixture_Class');Probes=@([pscustomobject]@{Id='count';Class='Fixture_Class';Namespace='root\cimv2';Properties=@('Name');Filter='';Mode='Count';Skip=''},[pscustomobject]@{Id='all';Class='Fixture_Class';Namespace='root\cimv2';Properties=@('Value');Filter='';Mode='All';Skip=''})}
 if($null -ne $Probes){$Payload.Probes=$Probes}
 function Get-WMachineCredential {param($Context)return $null}
 function New-Object {param($TypeName)if($TypeName -ne 'Net.NetworkInformation.Ping'){throw 'Unexpected construction'};$o=[pscustomobject]@{};$o|Add-Member ScriptMethod Send {param($a,$b)return [pscustomobject]@{Status='TimedOut'}};$o|Add-Member ScriptMethod Dispose {};return $o}
 function New-CimSessionOption {param($Protocol,$ErrorAction)return [pscustomobject]@{Protocol=$Protocol}}
 function New-CimSession {param($ComputerName,$SessionOption,$OperationTimeoutSec,$ErrorAction)$script:Opened++;return [pscustomobject]@{Fixture=$true}}
 function Remove-CimSession {param($CimSession,$ErrorAction)$script:Closed++}
 function Get-CimInstance {
  param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction,$Namespace,$Filter)
  if($ClassName -eq 'Win32_ComputerSystem'){return [pscustomobject]@{UserName='';Manufacturer='';Model='';TotalPhysicalMemory=$null}}
  if($ClassName -eq 'Win32_OperatingSystem'){if(@($Property) -contains 'ProductType'){$script:ProductTypeReads++};return [pscustomobject]@{Caption='';BuildNumber='';LastBootUpTime=$null;ProductType=$script:FixtureProductType}}
  if($ClassName -eq 'Win32_LogicalDisk'){return $null}
  if($ClassName -ne 'Fixture_Class'){throw 'Unexpected provider'}
  $script:ReadCount++;$script:Union=@($Property);$script:GroupCalls.Add([pscustomobject]@{Filter=$Filter;Properties=@($Property);Session=$CimSession})
  foreach($i in 1..$Rows){[pscustomobject]@{Name=$(if($LongDetail -and (-not $LongAfterFirst -or $i -gt 1)){'x'*300}else{'n'+$i});Value=$(if($LongDetail){@(1,2)}else{$i});DNSServerSearchOrder=@('192.0.2.10','192.0.2.20')};if($FailStream -and $i -eq 100){throw 'Synthetic interrupted enumeration'}}
 }
 return (& ([scriptblock]::Create((Get-DomeniaLiveProbeCode))))
}
Case 'Shared CIM stream counts 10000 instances and retains twenty detail rows' {
 $result=Invoke-CollectionFixture
 Assert ($result.Probes.count.Error -eq '' -and $result.Probes.all.Error -eq '')
 Assert ($result.Probes.count.Count -eq 10000 -and $result.Probes.count.Rows.Count -eq 20 -and -not $result.Probes.count.Truncated)
 Assert ($result.Probes.all.Count -eq 10000 -and $result.Probes.all.Rows.Count -eq 20 -and $result.Probes.all.Truncated)
 Assert ($script:ReadCount -eq 1 -and $script:Union.Count -eq 2 -and $script:Closed -eq 1 -and $script:Opened -eq 1)
 Assert ($null -eq $result.Inventory.RamBytes -and $null -eq $result.Inventory.DiskSize -and $null -eq $result.Inventory.DiskFree)
}
Case 'Interrupted CIM enumeration never becomes a successful partial count' {
 $result=Invoke-CollectionFixture -FailStream
 Assert ($result.Probes.count.Error -like '*Synthetic interrupted*' -and $result.Probes.all.Error -like '*Synthetic interrupted*')
 Assert ($result.Probes.count.Count -eq 0 -and $result.Probes.count.Rows.Count -eq 0 -and $script:ReadCount -eq 1)
}
function New-CollectionProbe {
 param([string]$Id,[string[]]$Properties=@('Name'),[string]$Filter='', [string]$Skip='', [string]$Class='Fixture_Class',[string]$Namespace='root\cimv2',[string]$Mode='All')
 return [pscustomobject]@{Id=$Id;Class=$Class;Namespace=$Namespace;Properties=$Properties;Filter=$Filter;Mode=$Mode;Skip=$Skip}
}
Case 'Shared probe plan deduplicates case-insensitive names and preserves case-sensitive filter literals' {
 $probes=@((New-CollectionProbe a @('Name') "Name='a'"),(New-CollectionProbe b @('name','Value') "Name='a'" -Class 'fixture_class' -Namespace 'ROOT\CIMV2'),(New-CollectionProbe c @('Value') "Name='A'"),(New-CollectionProbe d @('Value') "Name='b'"))
 $r=Invoke-CollectionFixture -Probes $probes -Rows 2
 Assert ($script:ReadCount -eq 3 -and $script:Opened -eq 1 -and $script:Closed -eq 1)
 Assert ($script:GroupCalls[0].Properties.Count -eq 2 -and $script:GroupCalls[1].Filter -ceq "Name='A'")
 foreach($id in @('a','b','c','d')){Assert ($r.Probes.$id.Count -eq 2 -and -not $r.Probes.$id.Error)}
 Assert ([object]::ReferenceEquals($script:GroupCalls[0].Session,$script:GroupCalls[2].Session))
 Assert ($r.Probes.a.CheckedUtc -eq $r.Probes.b.CheckedUtc)
}
Case 'Shared stream errors are recorded once with one session and no successful partial count' {
 $r=Invoke-CollectionFixture -FailStream
 Assert ($script:ReadCount -eq 1 -and $script:Opened -eq 1 -and $script:Closed -eq 1)
 Assert ($r.Probes.count.Error -eq $r.Probes.all.Error -and $r.Probes.count.CheckedUtc -eq $r.Probes.all.CheckedUtc)
 Assert ($r.Probes.count.Count -eq 0 -and $r.Probes.all.Count -eq 0)
}
Case 'Complete Count is not marked truncated by clipped text or array details' {
 $p=@((New-CollectionProbe count @('Name','Value') -Mode Count),(New-CollectionProbe all @('Name','Value')))
 $r=Invoke-CollectionFixture -Probes $p -Rows 2 -LongDetail
 Assert ($r.Probes.count.Count -eq 2 -and -not $r.Probes.count.Truncated -and $r.Probes.all.Truncated)
 Assert ($r.Probes.count.Rows[0][0].Length -eq 200 -and $r.Probes.count.Rows[0][1] -eq '1')
}
Case 'First DNS selects the first array value without losing a valid observation' {
 $first=New-CollectionProbe first @('DNSServerSearchOrder') -Mode First
 $all=New-CollectionProbe all @('DNSServerSearchOrder') -Mode All
 $r=Invoke-CollectionFixture -Probes @($first,$all) -Rows 2
 Assert ($script:ReadCount -eq 1 -and $r.Probes.first.Count -eq 2 -and $r.Probes.first.Rows.Count -eq 1)
 Assert (-not $r.Probes.first.Truncated -and -not $r.Probes.first.Error)
 $values=@(Get-DomeniaProbeValues $first $r.Probes.first)
 Assert ($values.Count -eq 1 -and $values[0] -eq '192.0.2.10')
 Assert ($r.Probes.all.Truncated -and @(Get-DomeniaProbeValues $all $r.Probes.all).Count -eq 0)
}
Case 'First ignores later instances but keeps the selected text length guard' {
 $first=New-CollectionProbe first @('Name') -Mode First
 $r=Invoke-CollectionFixture -Probes @($first) -Rows 2 -LongDetail -LongAfterFirst
 Assert ($r.Probes.first.Count -eq 2 -and $r.Probes.first.Rows.Count -eq 1 -and -not $r.Probes.first.Truncated)
 Assert (@(Get-DomeniaProbeValues $first $r.Probes.first)[0] -eq 'n1')
 $r=Invoke-CollectionFixture -Probes @($first) -Rows 2 -LongDetail
 Assert ($r.Probes.first.Truncated -and $r.Probes.first.Rows[0][0].Length -eq 200)
 Assert (@(Get-DomeniaProbeValues $first $r.Probes.first).Count -eq 0)
}
Case 'Rejected and controller-skipped probes never widen the property union' {
 $p=@((New-CollectionProbe ok @('Name')),(New-CollectionProbe dc @('Sensitive') -Skip DomainController),(New-CollectionProbe empty @('bad-name')),(New-CollectionProbe missing @('Other') -Class 'Unlisted_Class'),(New-CollectionProbe ns @('Other') -Namespace 'root;bad'))
 $r=Invoke-CollectionFixture -Probes $p -Rows 2 -ProductType 2
 Assert ($script:ReadCount -eq 1 -and $script:Union.Count -eq 1 -and $script:Union[0] -eq 'Name')
 Assert ($r.Probes.dc.Skipped -eq 'DomainController' -and -not $r.Probes.dc.Error)
 foreach($id in @('empty','missing','ns')){Assert ([bool]$r.Probes.$id.Error)}
 Assert ($r.Probes.ok.Count -eq 2)
}
Case 'Unknown controller type refuses only protected probes and reads the guard once' {
 $p=@((New-CollectionProbe ok @('Name')),(New-CollectionProbe dc1 @('Sensitive') -Skip DomainController),(New-CollectionProbe dc2 @('Other') -Skip DomainController))
 $r=Invoke-CollectionFixture -Probes $p -Rows 2 -ProductType 0
 Assert ($script:ReadCount -eq 1 -and $script:ProductTypeReads -eq 1 -and $script:Union.Count -eq 1)
 Assert ($r.Probes.dc1.Error -like '*Type de systeme non lu*' -and $r.Probes.dc2.Error -eq $r.Probes.dc1.Error -and $r.Probes.ok.Count -eq 2)
}
Case 'Backup export cannot target the active database or any SQLite journal' {
 $root=[IO.Path]::GetTempPath();$path=Join-Path $root 'active.db'
 foreach($suffix in @('','-wal','-shm','-journal')){$blocked=$false;try{Assert-DomeniaBackupDestination $path ($path+$suffix)}catch{$blocked=$true};Assert $blocked $suffix}
 Assert-DomeniaBackupDestination $path (Join-Path $root 'archive.db')
 Assert-DomeniaBackupDestination $path ''
}
Case 'Old backup callbacks cannot label a new context as backed up' {
 Reset-Fixture;$state=[pscustomobject]@{Path=$script:DatabaseScopedPath;Epoch=6L;CopyTo=''}
 Complete-DomeniaIndexBackupUi ([pscustomobject]@{Backup='/old.db';CopiedTo=''}) $state
 Fail-DomeniaIndexBackupUi 'old' $state;Assert ($script:Status -eq '')
}
Case 'Unconfirmed backup payload cannot report success' {
 Reset-Fixture;$state=[pscustomobject]@{Path=$script:DatabaseScopedPath;Epoch=7L;CopyTo=''}
 Complete-DomeniaIndexBackupUi ([pscustomobject]@{Backup='';CopiedTo=''}) $state
 Assert ($script:Status -like '*non confirmé*')
}
Case 'Storage preserves older rows before a bulk rebuild in FIFO order' {
 Reset-Fixture;$script:Admission='storage1'
 foreach($kind in @('Index','ParkSession','IndexBulk','Index')){$n=$script:Persistence.Pending.Count;$item=[pscustomobject]@{QueueKey=('q'+$n);Kind=$kind;Path=$script:DatabaseScopedPath;Row=[pscustomobject]@{RowCount=5000};Epoch=7L};$script:Persistence.Pending[$item.QueueKey]=$item}
 Start-DomeniaStorageWork
 Assert ($script:Dispatched.Payload.Items.Count -eq 2 -and $script:Dispatched.Payload.Items[0].Kind -eq 'Index' -and $script:Dispatched.Payload.Items[1].Kind -eq 'ParkSession')
 Assert ($script:Persistence.InFlightItems.Count -eq 2 -and $script:Persistence.Pending.Count -eq 2)
}
Case 'Storage isolates a bulk rebuild when it reaches the front' {
 Reset-Fixture;$script:Admission='storage2'
 foreach($kind in @('IndexBulk','Index')){$n=$script:Persistence.Pending.Count;$item=[pscustomobject]@{QueueKey=('q'+$n);Kind=$kind;Path=$script:DatabaseScopedPath;Row=[pscustomobject]@{RowCount=5000};Epoch=7L};$script:Persistence.Pending[$item.QueueKey]=$item}
 Start-DomeniaStorageWork
 Assert ($script:Dispatched.Payload.Items.Count -eq 1 -and $script:Dispatched.Payload.Items[0].Kind -eq 'IndexBulk');Assert ($script:Persistence.Pending.Count -eq 1)
}
Case 'Lost save callback preserves its lot and suspends automatic replay' {
 Reset-Fixture;$item=[pscustomobject]@{QueueKey='lost';Kind='ParkSession';Path=$script:DatabaseScopedPath;Row=[pscustomobject]@{Raw='original'}}
 $script:Persistence.Job='vanished';$script:Persistence.InFlight=1;$script:Persistence.InFlightItems=@($item)
 Start-DomeniaStorageWork
 Assert ($script:Persistence.Pending.Count -eq 1 -and [object]::ReferenceEquals($item,$script:Persistence.Pending.lost))
 Assert ($script:Persistence.Failures -ge 3 -and $script:Persistence.InFlight -eq 0 -and $script:Persistence.InFlightItems.Count -eq 0)
 Assert ($null -eq $script:Dispatched)
}
Case 'Detached save still owns its slot and is never replayed' {
 Reset-Fixture;$script:Persistence.Job='detached';$script:Persistence.InFlight=1;$script:Persistence.InFlightItems=@([pscustomobject]@{QueueKey='q';Kind='Index'})
 $script:DetachedReadJobs=@([pscustomobject]@{Id='detached';OperationId='LocalStore'})
 Start-DomeniaStorageWork
 Assert ($script:Persistence.Job -eq 'detached' -and $script:Persistence.InFlight -eq 1 -and $script:Persistence.Pending.Count -eq 0)
}
Case 'Lost LiveCache callback requeues the exact batch without false saved state' {
 Reset-Fixture;$entry=[pscustomobject]@{Key='pc1'}
 $script:Live.SaveJob='vanished';$script:Live.SaveInFlight=1;$script:Live.SaveBatch=[pscustomobject]@{Mode='Write';Identity='reader';Epoch=7L;Observations=@($entry);Query=$null}
 Start-DomeniaLiveBackgroundWork
 Assert ($script:Live.SaveInFlight -eq 0 -and $null -eq $script:Live.SaveBatch -and $script:Live.SaveJob -eq '')
 Assert ($script:Live.SaveQueue.Count -eq 1 -and [object]::ReferenceEquals($entry,$script:Live.SaveQueue.pc1))
 Assert ($script:Live.SaveAfter -gt [datetime]::UtcNow -and $script:Live.SaveFault -like '*non reçu*')
 Assert ($null -eq $script:Dispatched)
}
# Exercise the core retry dispatcher itself: a matching term alone cannot carry an old page
# into another OU or another connection epoch.
$coreTokens=$null;$coreErrors=$null;$coreAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$coreTokens,[ref]$coreErrors)
$searchUi=@($coreAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Search-DomeniaIndexUi'},$true))[0]
. ([scriptblock]::Create($searchUi.Extent.Text))
function Get-DomeniaControl {param($Name)if($Name -eq 'TxtIndexSearch'){return [pscustomobject]@{Text='pc'}};return $null}
function Get-DomeniaIndexScope {return [pscustomobject]@{IsDomain=$false;BaseDn='OU=Current,DC=example,DC=invalid'}}
function Start-DomeniaIndexSearch {param($Term,$Limit,$Attempt,$Offset)$script:RetryRequest=[pscustomobject]@{Term=$Term;Limit=$Limit;Attempt=$Attempt;Offset=$Offset}}
Case 'Index retry resumes the exact page only inside the same scope and epoch' {
 Reset-Fixture;$script:DomeniaIndexSearchGeneration=42L;$script:DomeniaIndexSearchRetry=[pscustomobject]@{Term='pc';Scope='OU=Current,DC=example,DC=invalid';Epoch=7L;Attempt=1;Offset=400;Limit=200;Generation=42L}
 Search-DomeniaIndexUi
 Assert ($script:RetryRequest.Offset -eq 400 -and $script:RetryRequest.Attempt -eq 1);Assert ($null -eq $script:DomeniaIndexSearchRetry)
}
Case 'Index retry from another OU starts from the first page' {
 Reset-Fixture;$script:DomeniaIndexSearchGeneration=42L;$script:DomeniaIndexSearchRetry=[pscustomobject]@{Term='pc';Scope='OU=Old,DC=example,DC=invalid';Epoch=7L;Attempt=1;Offset=400;Limit=200;Generation=42L}
 Search-DomeniaIndexUi
 Assert ($script:RetryRequest.Offset -eq 0 -and $script:RetryRequest.Attempt -eq 0)
}
Case 'Index retry from a previous connection starts from the first page' {
 Reset-Fixture;$script:DomeniaIndexSearchGeneration=42L;$script:DomeniaIndexSearchRetry=[pscustomobject]@{Term='pc';Scope='OU=Current,DC=example,DC=invalid';Epoch=6L;Attempt=1;Offset=400;Limit=200;Generation=42L}
 Search-DomeniaIndexUi
 Assert ($script:RetryRequest.Offset -eq 0 -and $script:RetryRequest.Attempt -eq 0)
}
Case 'Typing during a busy retry resets the page even if the same term returns' {
 Reset-Fixture;$script:DomeniaIndexSearchGeneration=44L;$script:DomeniaIndexSearchRetry=[pscustomobject]@{Term='pc';Scope='OU=Current,DC=example,DC=invalid';Epoch=7L;Attempt=1;Offset=400;Limit=200;Generation=42L}
 Search-DomeniaIndexUi
 Assert ($script:RetryRequest.Offset -eq 0 -and $script:RetryRequest.Attempt -eq 0)
}
# A present search map is authoritative even when the collected workstation is
# absent. Grid fallback is reserved for a missing map, not an empty lookup.
function Invoke-ParkRowMapFixture {
 param([bool]$MapAvailable,[bool]$InMap)
 $script:ParkGridReads=0;$script:ParkUpdated=[Collections.Generic.List[string]]::new()
 $guid='00000000-0000-0000-0000-000000000001';$dn='cn=pc1,dc=example,dc=invalid'
 $row=[pscustomobject]@{Type='Machine';DN=$dn;Guid=$guid;Association=''}
 $script:ParkFixtureRows=@($row,[pscustomobject]@{Type='Machine';DN=$dn;Guid='recreated-other';Association=''},[pscustomobject]@{Type='Machine';DN='cn=pc2,dc=example,dc=invalid';Guid=$guid;Association=''})
 $script:ParkGrid=[pscustomobject]@{ItemsSource=$null}
 $script:ParkGrid|Add-Member ScriptProperty Items {$script:ParkGridReads++;return $script:ParkFixtureRows}
 $map=$null;if($MapAvailable){$map=@{};if($InMap){$map[$dn]=$row}}
 $script:Live=[pscustomobject]@{Observations=@{};Search=[pscustomobject]@{Map=$map}}
 function Get-DomeniaControl {param($Name);return $script:ParkGrid}
 function ConvertTo-DomeniaLiveObservation {param($Packet,$Previous,$NowUtc);return [pscustomobject]@{LastUser='';ObservedUtc=''}}
 function Set-DomeniaLiveObservationOnRow {param($Row,$Observation);$script:ParkUpdated.Add([string]$Row.Guid)}
 function Set-RowAssociationMetadata {param($Rows)}
 $observation=[pscustomobject]@{Key=$dn;Guid=$guid;CheckedUtc=[datetime]::UtcNow;ObservedUtc=[datetime]::UtcNow;RawAccount=''}
 Update-DomeniaParkResultRows ([pscustomobject]@{}) $observation
}
Case 'Park observation absent from a present search map never scans the grid' {
 Invoke-ParkRowMapFixture -MapAvailable $true -InMap $false
 Assert ($script:ParkGridReads -eq 0 -and $script:ParkUpdated.Count -eq 0)
}
Case 'Park singleton map hit updates exactly one row without scanning the grid' {
 Invoke-ParkRowMapFixture -MapAvailable $true -InMap $true
 Assert ($script:ParkGridReads -eq 0 -and $script:ParkUpdated.Count -eq 1)
}
Case 'Park without a search map scans once and retains DN and GUID identity guards' {
 Invoke-ParkRowMapFixture -MapAvailable $false -InMap $false
 Assert ($script:ParkGridReads -eq 1 -and $script:ParkUpdated.Count -eq 1)
 Assert ($script:ParkUpdated[0] -eq '00000000-0000-0000-0000-000000000001')
}
Case 'Park partial measurements count as failed while complete observations are queued' {
 foreach($kind in @('InventoryError','ProbeError','Truncated','Success')){
  Reset-Fixture;$script:SelectedObject=$null;$script:FleetLast=$null;$script:FleetObservations=@{};$script:QueuedObservation=$null
  $target=[pscustomobject]@{Key='dn';Guid='g';Computer='PC';Previous=$null;PreviousJson=''}
  $script:ParkRun=[pscustomobject]@{Id='r';Pending=@{j=$true};PingOnly=$false;CachedMeasurements=0;Done=0;Online=0;Failed=0;Stopping=$false;Reused=0;Changed=0}
  $state=[pscustomobject]@{RunId='r';Epoch=7L;Path=$script:DatabaseScopedPath;Job='j';Target=$target}
  $probe=[pscustomobject]@{Error=$(if($kind -eq 'ProbeError'){'failed'}else{''});Truncated=($kind -eq 'Truncated');Rows=@(,@('raw'));CheckedUtc=[datetime]::UtcNow.ToString('o')}
  $packet=[pscustomobject]@{Key='dn';Guid='g';Computer='PC';Outcome='NoConsole';Presence='En ligne';InventoryError=$(if($kind -eq 'InventoryError'){'denied'}else{''});Probes=[pscustomobject]@{fixture=$probe}}
  function Queue-DomeniaMetadata {param($Kind,$Key,$Row)$script:QueuedObservation=$Row;return $true}
  function Get-ExistingLinkForComputer {param($Computer)return $null}
  function Update-DomeniaParkResultRows {param($Packet,$Observation)}
  function Update-DomeniaParkRunStatus {}
  Complete-DomeniaParkSession $packet $state
  Assert ($script:ParkRun.Done -eq 1 -and $script:ParkRun.Online -eq 1 -and $script:ParkRun.Pending.Count -eq 0) $kind
  Assert ($script:ParkRun.Failed -eq $(if($kind -eq 'Success'){0}else{1})) ('failure count '+$kind)
  Assert ($null -ne $script:QueuedObservation -and $script:QueuedObservation.Probes.fixture.Rows[0][0] -eq 'raw') ('full persisted observation '+$kind)
  if($kind -eq 'InventoryError'){Assert ($script:QueuedObservation.InventoryError -eq 'denied' -and $script:QueuedObservation.InventoryAttemptUtc)}
 }
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{Kind='EngineResilience';Passed=$checks.Count-$failed;Failed=$failed;NativeWindowsPowerShell51=($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5);WpfExecuted=$false;NetworkAccessed=$false;Tests=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Host ($report.Passed.ToString()+' passed, '+$failed+' failed. No WPF or network.');$checks|Where-Object{-not $_.Passed}|ForEach-Object{Write-Host ($_.Name+': '+$_.Error)}
if($failed){exit 1};exit 0
