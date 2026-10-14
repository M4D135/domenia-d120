#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($module in @('Common.Model','Directory.Model','Store.Model','DirectoryStore.Model','DirectoryStore.UI','Demo.Worker')){. (Join-Path $root ('modules/Domenia-'+$module+'.ps1'))}
$core=Join-Path $root 'Domenia-Core.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$errors)
if($errors){throw 'Core parse failure'}
foreach($name in @('Get-DomeniaSafeObjectPropertyNames','Test-DomeniaSensitiveAttributeName','Remove-DomeniaSensitiveProperties','Invoke-DomeniaStartupCacheWarmup','Assert-DomeniaStartupReadiness','Get-DomeniaDatabasePath')){
 $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($f.Count -ne 1){throw ('Function not unique: '+$name)}
 . ([scriptblock]::Create($f[0].Extent.Text))
}
$common=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'function New-WBranchRow' -and $n.Value -match 'function New-WSearcher'},$true))[0]
$commonAst=[Management.Automation.Language.Parser]::ParseInput($common.Value,[ref]$tokens,[ref]$errors)
foreach($name in @('Convert-WDirectoryValue','Get-WPropFirst','Get-WPropAll','Convert-WGuid','Convert-WLargeInteger','Convert-WDate','Convert-WFileTime','Get-WUacState','Get-WObjectType','New-WBranchRow')){
 $f=@($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))[0]
 . ([scriptblock]::Create($f.Extent.Text))
}
. ([scriptblock]::Create((Get-DomeniaDirectoryStoreWorkerPrelude)))
$script:Checks=[Collections.Generic.List[object]]::new();$script:Assertions=0
function Assert-Fixture {param([bool]$Value,[string]$Why)$script:Assertions++;if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)try{Reset-Fixture;&$Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true})}catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString();Stack=$_.ScriptStackTrace})}}
function New-DomeniaTimer {param($Owner,$IntervalMs,[switch]$RunWhenHidden,$Tick)$timer=[pscustomobject]@{IsEnabled=$false};$timer|Add-Member ScriptMethod Start {$this.IsEnabled=$true};$timer|Add-Member ScriptMethod Stop {$this.IsEnabled=$false};return $timer}
function Write-AppLog {param($Message,$Level)}
function Invoke-DomeniaTimerSoon {param($Owner)}
function Test-DomeniaLiveSearchActive {return ($null -ne $script:Live.Search -and -not $script:Live.Search.Stopped)}
function Request-DomeniaStoreRead {param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState)$script:TreeReads.Add([pscustomobject]@{Context=$Context;Query=$Query;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler;CallbackState=$CallbackState});return 'fixture-sql-read'}
function Queue-DomeniaTreeRowsToNode {param($Node,$Rows,$DisplayName)$script:TreeRenders.Add([pscustomobject]@{Node=$Node;Rows=$Rows;DisplayName=$DisplayName})}
function Fail-DomeniaTreeChildrenUi {param($Message,$State)$script:TreeErrors.Add($Message)}
function Set-Status {param($Text,$Level)}
function Submit-DomeniaStoreBatch {
 param($Context,$BatchId,$Sequence,$Changes,$SuccessHandler,$ErrorHandler,$CallbackState)
 $script:Admissions.Add([pscustomobject]@{Context=$Context;BatchId=$BatchId;Sequence=$Sequence;Changes=$Changes;CallbackState=$CallbackState;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler})
 return [pscustomobject]@{Accepted=(-not $script:Backpressure);Backpressure=$script:Backpressure;Reason='fixture pressure'}
}
function Reset-Fixture {
 $script:DomeniaDirectoryReads=@{};$script:DomeniaDirectoryStoreTimer=$null;$script:Backpressure=$false
 $script:Admissions=[Collections.Generic.List[object]]::new();$script:SessionEpoch=4L
 $script:TreeReads=[Collections.Generic.List[object]]::new();$script:TreeRenders=[Collections.Generic.List[object]]::new();$script:TreeErrors=[Collections.Generic.List[string]]::new()
 $script:Context=[pscustomobject]@{RequestId=[guid]::NewGuid().ToString('D');StoreId='store-original';SessionEpoch=4L;Path='original.db';Generation=17L;ScopeDn='OU=Site,DC=example,DC=invalid';Subtree=$true}
 $script:Search=[pscustomobject]@{Stopped=$false;Stop=[Threading.CancellationTokenSource]::new();Final=$null;Ended=$false;Error=''}
 $script:Live=[pscustomobject]@{Search=$script:Search}
 $script:Ready=[Collections.Concurrent.ConcurrentQueue[object]]::new()
 $script:Pipe=New-DomeniaDirectoryReadPipe -Context $script:Context -ReadyQueue $script:Ready -Search $script:Search
}
function New-Record {
 param([int]$Index=1,[string]$Type='Machine')
 $class=switch($Type){Machine{'computer'} Utilisateur{'user'} Groupe{'group'} OU{'organizationalUnit'} Conteneur{'container'}}
 $prefix=if($Type -eq 'OU'){'OU'}else{'CN'}
 [pscustomobject]@{Properties=@{objectguid=@(([guid]::new($Index,0,0,[byte[]](0,0,0,0,0,0,0,1))).ToString('D'));distinguishedname=@($prefix+'=OBJ'+$Index+',OU=Site,DC=example,DC=invalid');name=@('RAW'+$Index);objectclass=@('top',$class);samaccountname=@('PC'+$Index+'$');useraccountcontrol=@(4096);whenchanged=@('2026-10-01T12:00:00Z');description=@('Source description')};Type=$Type;ObservedUtc='2026-10-13T12:00:00Z';Source='dc.example.invalid'}
}
function Admit-Next {
 $limit=[Diagnostics.Stopwatch]::StartNew()
 while(-not $script:Pipe.InFlight -and -not $script:Pipe.Failure -and $limit.Elapsed.TotalSeconds -lt 5){$script:Pipe.LastAdmission=[datetime]::MinValue;Invoke-DomeniaDirectoryStoreTick}
 Assert-Fixture $script:Pipe.InFlight 'Batch not admitted'
 return $script:Admissions[$script:Admissions.Count-1]
}
function Complete-Receipt {
 param($Admission,[string]$CanonicalName='SQL-NEWER')
 $rows=@(foreach($change in $Admission.Changes){$details=ConvertTo-DomeniaDirectoryPropertyMap $change.Data.Details;$details.name=@($CanonicalName);[pscustomobject]@{Guid=$change.Guid;DN=$change.DN;Type=$change.Data.Type;Name=$CanonicalName;Details=$details;ObservedAtUtc='2026-10-13T12:01:00Z';Source='dc-new.example.invalid'}})
 $result=[pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$Admission.Context.StoreId;BatchId=$Admission.BatchId;SnapshotRevision=92L;Rows=$rows}
 & $Admission.SuccessHandler -Result $result -State $Admission.CallbackState
 return $result
}
Case 'Admission alone cannot publish raw LDAP values' {
 $script:Pipe.Input.Enqueue((New-Record));$a=Admit-Next
 Assert-Fixture ($script:Ready.Count -eq 0 -and $script:Pipe.Saved -eq 0) 'Raw values published before COMMIT'
 [void](Complete-Receipt $a)
 $row=$null;[void]$script:Ready.TryDequeue([ref]$row)
 Assert-Fixture ($row.Row.Name -ceq 'SQL-NEWER' -and $row.DataSource -ceq 'SQLite' -and $row.ObservedUtc -ceq '2026-10-13T12:01:00Z') 'Worker echo or callback time published instead of SQL readback'
}
Case 'SQLite failure retains batch and stops collector without displaying it' {
 $script:Pipe.Input.Enqueue((New-Record));$a=Admit-Next
 & $a.ErrorHandler -Message 'fixture SQLite write denied' -State $a.CallbackState
 Invoke-DomeniaDirectoryStoreTick
 Assert-Fixture ($script:Ready.Count -eq 0 -and $script:Pipe.Batch.Id -ceq $a.BatchId -and $script:Pipe.Stop.IsCancellationRequested) 'Write failure lost the payload or leaked raw rows'
 Assert-Fixture (-not $script:DomeniaDirectoryStoreTimer.IsEnabled -and $script:Search.Ended -and $script:Search.Error) 'Failed writer spins or reports successful search'
}
Case 'A renderer failure after COMMIT cannot block the remaining harvest or claim a failed write' {
 function Invoke-FixtureBrokenRenderer {param($Result,$State)throw 'fixture display unavailable'}
 $script:Pipe.CommitHandler='Invoke-FixtureBrokenRenderer'
 $script:Pipe.Input.Enqueue((New-Record));$a=Admit-Next;[void](Complete-Receipt $a)
 Assert-Fixture ($script:Pipe.Saved -eq 1 -and -not $script:Pipe.InFlight -and $null -eq $script:Pipe.Batch -and -not $script:Pipe.Failure -and $script:Pipe.DisplayError) 'Confirmed batch retained or classified as failed storage'
 $script:Pipe.Input.Enqueue((New-Record 2));$b=Admit-Next;[void](Complete-Receipt $b)
 Complete-DomeniaDirectoryReadPipe -Pipe $script:Pipe;Invoke-DomeniaDirectoryStoreTick
 Assert-Fixture ($b.BatchId -cne $a.BatchId -and $script:Pipe.Saved -eq 2 -and $script:Pipe.Closed -and $script:Search.Error -like 'Donnees enregistrees*') 'Remaining harvest blocked or renderer failure hidden'
}
Case 'Backpressure retries exact batch ID and bytes' {
 $script:Pipe.Input.Enqueue((New-Record));$script:Backpressure=$true;Invoke-DomeniaDirectoryStoreTick
 $first=$script:Admissions[0];$bytes=$first.Changes|ConvertTo-Json -Depth 16 -Compress
 Assert-Fixture ($script:Ready.Count -eq 0 -and -not $script:Pipe.InFlight -and $script:Pipe.Batch) 'Temporary refusal discarded data'
 $script:Backpressure=$false;$a=Admit-Next
 Assert-Fixture ($a.BatchId -ceq $first.BatchId -and ($a.Changes|ConvertTo-Json -Depth 16 -Compress) -ceq $bytes) 'Retry changed idempotency payload'
}
Case 'Old search persists into captured database but cannot repaint new selection' {
 $script:Pipe.Input.Enqueue((New-Record));$a=Admit-Next
 $script:Search.Stopped=$true;$script:Live.Search=[pscustomobject]@{Stopped=$false};$script:SessionEpoch=5L
 [void](Complete-Receipt $a)
 Assert-Fixture ($a.Context.Path -ceq 'original.db' -and $script:Pipe.Saved -eq 1 -and $script:Ready.Count -eq 0) 'Old-context harvest discarded or displayed in another view'
}
Case 'Cancelled read waits for final producer exit and preserves partial data' {
 $script:Pipe.Collector.Started=$true;$script:Pipe.Input.Enqueue((New-Record))
 Complete-DomeniaDirectoryReadPipe -Pipe $script:Pipe -Error 'cancelled fixture'
 $a=Admit-Next;[void](Complete-Receipt $a);Invoke-DomeniaDirectoryStoreTick
 Assert-Fixture (-not $script:Pipe.Closed -and -not $script:Search.Ended) 'Pipe finalized while producer could still enqueue'
 $script:Pipe.Input.Enqueue((New-Record 2));$script:Pipe.Collector.Done=$true
 $a=Admit-Next;[void](Complete-Receipt $a);Invoke-DomeniaDirectoryStoreTick
 Assert-Fixture ($script:Pipe.Closed -and $script:Search.Ended -and $script:Search.Error -ceq 'cancelled fixture' -and $script:Ready.Count -eq 2) 'Partial cancellation lost last harvested row or claimed complete coverage'
}
Case 'Producer completion closes the pipe even if an obsolete task callback was discarded' {
 $script:Pipe.Collector.Started=$true;$script:Pipe.Input.Enqueue((New-Record));$script:Pipe.Collector.Final=[pscustomobject]@{Rows=1};$script:Pipe.Collector.Done=$true
 $a=Admit-Next;[void](Complete-Receipt $a);Invoke-DomeniaDirectoryStoreTick
 Assert-Fixture ($script:Pipe.Closed -and $script:Search.Ended -and $script:Search.Final.Rows -eq 1) 'Completion still depends on discarded old-epoch callback'
}
Case 'Wrong store receipt is rejected' {
 $script:Pipe.Input.Enqueue((New-Record));$a=Admit-Next
 Complete-DomeniaDirectoryStoreBatch -Result ([pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId='other-store';BatchId=$a.BatchId;Rows=@()}) -State $script:Pipe
 Assert-Fixture ($script:Ready.Count -eq 0 -and $script:Pipe.Failure) 'Receipt for another database accepted'
}
Case 'Tree displays SQL pages only after the entire committed child selection is read' {
 $node=[pscustomobject]@{Tag=[pscustomobject]@{DirectoryReadId=$script:Context.RequestId}}
 $tree=[pscustomobject]@{Node=$node;StoreContext=$script:Context;DN=$script:Context.ScopeDn;Name='Site';ReadGuids=@(1..300|ForEach-Object{([guid]::new($_,0,0,[byte[]](0,0,0,0,0,0,0,1))).ToString('D')})}
 Request-DomeniaDirectoryTreeSnapshot $tree
 $read=$script:TreeReads[0]
 Assert-Fixture ($read.Query.Limit -eq 250 -and -not $read.Query.Subtree -and $read.Query.Guids.Count -eq 300 -and $script:TreeRenders.Count -eq 0) 'Tree bypassed SQL or changed one-level membership'
 $rows=@(1..300|ForEach-Object{[pscustomobject]@{Guid=$tree.ReadGuids[$_-1];Name=('SQL-{0:d3}' -f (301-$_));Type='OU';DN=('OU=SQL'+$_+','+$tree.DN);Details=@{}}})
 Complete-DomeniaDirectoryTreeSnapshot -Result ([pscustomobject]@{DataSource='SQLite';Rows=$rows[0..249];Total=300}) -State $read.CallbackState
 Assert-Fixture ($script:TreeReads.Count -eq 2 -and $script:TreeReads[1].Query.Offset -eq 250 -and $script:TreeRenders.Count -eq 0) 'Tree published a partial SQL page'
 Complete-DomeniaDirectoryTreeSnapshot -Result ([pscustomobject]@{DataSource='SQLite';Rows=$rows[250..299];Total=300}) -State $script:TreeReads[1].CallbackState
 Assert-Fixture ($script:TreeRenders.Count -eq 1 -and $script:TreeRenders[0].Rows.Count -eq 300 -and $script:TreeRenders[0].Rows[0].Name -ceq 'SQL-001') 'Tree lost SQL children or failed name sorting'
}
Case 'Tree rejects an obsolete read and never substitutes older rows for an empty AD enumeration' {
 $node=[pscustomobject]@{Tag=[pscustomobject]@{DirectoryReadId='replaced'}}
 $tree=[pscustomobject]@{Node=$node;StoreContext=$script:Context;DN=$script:Context.ScopeDn;Name='Site';ReadGuids=@()}
 Request-DomeniaDirectoryTreeSnapshot $tree
 Assert-Fixture ($script:TreeReads.Count -eq 0 -and $script:TreeRenders.Count -eq 0) 'Old node request can repaint current tree'
 $node.Tag.DirectoryReadId=$script:Context.RequestId;Request-DomeniaDirectoryTreeSnapshot $tree
 Assert-Fixture ($script:TreeReads.Count -eq 0 -and $script:TreeRenders.Count -eq 1 -and $script:TreeRenders[0].Rows.Count -eq 0) 'Empty AD children replaced by stale SQL data'
 Complete-DomeniaDirectoryTreeSnapshot -Result ([pscustomobject]@{DataSource='SQLite';Busy=$true;Rows=@();Total=0}) -State ([pscustomobject]@{Tree=$tree;Offset=0})
 Assert-Fixture ($script:TreeErrors.Count -eq 1 -and $script:TreeRenders.Count -eq 1) 'Busy SQL response silently interpreted as an empty successful tree'
}
Case 'Field masks preserve omitted fields and exclude secrets or unknown attributes' {
 $r=New-Record;$r.Properties.Remove('useraccountcontrol');$r.Properties['msLAPS-Password']=@('fixture-secret');$r.Properties['unknownPrivateData']=@('ignored')
 $change=ConvertTo-DomeniaDirectoryStoreChange $r.Properties $r.Type $r.ObservedUtc $r.Source
 Assert-Fixture ($change.Fields -notcontains 'State' -and $change.Fields -notcontains 'Extra' -and $change.Fields -contains 'Description') 'Partial fields manufactured active/composite values'
 Assert-Fixture (-not $change.Data.Details.ContainsKey('mslaps-password') -and -not $change.Data.Details.ContainsKey('unknownprivatedata')) 'Unpermitted attribute admitted'
 $change.Data.Details.description=@('');$again=ConvertTo-DomeniaDirectoryStoreChange $change.Data.Details $r.Type $r.ObservedUtc $r.Source
 Assert-Fixture ($again.Fields -contains 'Description' -and $again.Data.Description -ceq '') 'Explicit empty value cannot clear old permitted data'
}
Case 'Groups, OU and containers retain typed metadata and memberships' {
 foreach($type in @('Utilisateur','Machine','Groupe','OU','Conteneur')){
  $r=New-Record 1 $type;$r.Properties['member']=@('CN=A,DC=example,DC=invalid','CN=B,DC=example,DC=invalid');$r.Properties['__memberComplete']=@($true)
  $change=ConvertTo-DomeniaDirectoryStoreChange $r.Properties $r.Type $r.ObservedUtc $r.Source
  Assert-Fixture ($change.Data.Type -ceq $type -and $change.Data.Details.member.Count -eq 2 -and $change.Data.Details.__membercomplete[0]) ('Lost typed metadata for '+$type)
 }
}
Case 'Worker projection preserves GUID bytes, multivalues and explicit permitted mask' {
 $guid=[guid]::NewGuid();$raw=@{objectGUID=$guid.ToByteArray();name=@('Machine');member=@('A','B');unicodePwd=@('forbidden');unknown=@('ignored')}
 $safe=New-WDirectoryStoreProperties $raw @('objectGUID','name','member','unicodePwd')
 Assert-Fixture ($safe.objectguid[0] -ceq $guid.ToString('D') -and $safe.member.Count -eq 2) 'Worker projection unrolled a binary GUID or a membership list'
 Assert-Fixture (-not $safe.ContainsKey('unicodepwd') -and -not $safe.ContainsKey('unknown')) 'Worker leaked a secret or unrequested field'
}
Case 'Directory changes are accepted by the actual foundation wire validator' {
 $r=New-Record;$change=ConvertTo-DomeniaDirectoryStoreChange $r.Properties $r.Type $r.ObservedUtc $r.Source
 $context=[pscustomobject]@{Path=(Join-Path ([IO.Path]::GetTempPath()) 'directory-wire-fixture.db');DomainDn='DC=example,DC=invalid';RequestId=[guid]::NewGuid().ToString('D');SessionEpoch=1L;Generation=1L;ScopeDn='OU=Site,DC=example,DC=invalid';Subtree=$true}
 $context|Add-Member NoteProperty StoreId (Get-DomeniaStoreId $context.Path $context.DomainDn)
 $batch=ConvertTo-DomeniaStoreBatch -Context $context -BatchId ([guid]::NewGuid().ToString('D')) -Sequence 1 -Changes @($change)
 Assert-Fixture ($batch.Count -eq 1 -and $batch.Bytes -lt 4194304 -and $batch.Json -like '*DirectoryObject*') 'Producer and foundation disagree on wire format'
}
Case 'Partial reads do not refresh facts not collected; AD file times become canonical UTC facts' {
 $r=New-Record;$change=ConvertTo-DomeniaDirectoryStoreChange $r.Properties $r.Type $r.ObservedUtc $r.Source
 Assert-Fixture ($null -eq $change.Facts) 'Empty fact mask fabricated a fresh facts record'
 $at=[datetime]'2025-04-01T12:00:00Z';$r.Properties.pwdlastset=@($at.ToFileTimeUtc());$r.Properties.whencreated=@($at)
 $change=ConvertTo-DomeniaDirectoryStoreChange $r.Properties $r.Type $r.ObservedUtc $r.Source
 Assert-Fixture ($change.Facts.PwdLastSet -ceq $at.ToUniversalTime().ToString('o') -and $change.Facts.WhenCreated -ceq $at.ToUniversalTime().ToString('o')) 'A FILETIME was stored as an unparseable SQL date'
}
Case 'Legacy startup warmup never launches a second uncommitted directory collector' {
 function Get-CfgValue {param($Section,$Name,$Default)return $true}
 function Write-StartupTrace {param($Stage,$Status,$Detail)}
 function Start-UiTask {throw 'Unexpected directory task during legacy warmup'}
 $script:AsyncEngineReady=$true;$script:StartupWarmCache=[pscustomobject]@{TreeRows=@('uncommitted')}
 Invoke-DomeniaStartupCacheWarmup;Assert-DomeniaStartupReadiness
 Assert-Fixture ($script:StartupWarmupDone -and $script:StartupReady -and $null -eq $script:StartupWarmCache) 'Old warm snapshot still crosses startup barrier'
 $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Load-TreeRoot'},$true))[0]
 Assert-Fixture ($fn.Extent.Text -notmatch '\$warm\.TreeRows|\$warm\.ObjectRows') 'Tree still publishes uncommitted warm values'
}
Case 'Demonstration uses a separate database and cannot select a real-domain path' {
 function Initialize-DomeniaDataStore {return $true}
 function Get-CfgValue {param($Section,$Name,$Default)return $Default}
 $folder=Join-Path ([IO.Path]::GetTempPath()) ('domenia-demo-store-test-'+[guid]::NewGuid().ToString('N'))
 try{
  [void][IO.Directory]::CreateDirectory($folder);$script:DataDir=$folder;$script:DemoMode=$true;$script:Conn=[pscustomobject]@{BaseDn='DC=demo,DC=invalid'}
  $path=Get-DomeniaDatabasePath
  Assert-Fixture ($path -ceq (Join-Path (Join-Path $folder 'Demonstration') 'Domenia-demo.db')) 'Demo reused a production database'
  $script:Conn.BaseDn='DC=production,DC=example';$failed=$false;try{Get-DomeniaDatabasePath|Out-Null}catch{$failed=$true}
  Assert-Fixture $failed 'Demo accepted a real domain context'
 }finally{$script:DemoMode=$false;if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder,$true)}}
}
Case 'Actual demonstration collectors use the same raw/store pipeline with explicit synthetic provenance' {
 $base='DC=demo,DC=invalid';$ou='OU=Site,'+$base;$dn='CN=PC1,'+$ou;$objects=[Collections.Generic.List[object]]::new()
 foreach($entry in @(@($ou,'organizationalUnit','Site'),@($dn,'computer','PC1'))){$attrs=@{name=@($entry[2]);objectclass=@('top',$entry[1]);distinguishedname=@($entry[0]);objectguid=@([guid]::NewGuid().ToString('D'));samaccountname=@('PC1$');useraccountcontrol=@(4096)};$objects.Add([pscustomobject]@{DN=$entry[0];Attributes=$attrs;DeniedFor=@()})}
 $directory=[pscustomobject]@{Format='DomeniaDemoDirectory/1';BaseDn=$base;Objects=$objects.ToArray();LatencyMs=0}
 $Context=[pscustomobject]@{DemoMode=$true;OperationId='DemoDirectory';Credential=$null;BindUser='DEMO\operator'}
 foreach($op in @('TreeChildren','GlobalSearch','OpenAdObject')){
  $queue=[Collections.Concurrent.ConcurrentQueue[object]]::new();$state=[hashtable]::Synchronized(@{Started=$false;Done=$false;Final=$null;Error=''})
  $req=[pscustomobject]@{DN=$(if($op -eq 'TreeChildren'){$base}else{$dn});Type='Machine';BaseDn=$base;Scope='Subtree';BroadFilter='(objectClass=computer)';Limit=100;Properties=@('name','objectClass','objectGUID','distinguishedName','samaccountname');Progress=$queue;DirectoryReadState=$state;StopToken=$script:Search.Stop.Token}
  $Payload=[pscustomobject]@{Operation=$op;Request=$req;Directory=$directory}
  $out=& ([scriptblock]::Create((Get-DomeniaDemoDirectoryWorkerCode)))
  Assert-Fixture ($state.Done -and $state.Final.Demo -and $queue.Count -eq 1) ('Demo collector not routed through persistence: '+$op)
  $event=$null;[void]$queue.TryDequeue([ref]$event)
  Assert-Fixture ($event.Source -ceq 'Demonstration' -and $event.ObservedUtc -and $event.Properties.objectguid) ('Demo source/date/GUID absent: '+$op)
 }
}
Case '5000 rows use bounded batches and all displayed values are committed readbacks' {
 for($i=1;$i -le 5000;$i++){$script:Pipe.Input.Enqueue((New-Record $i))}
 Complete-DomeniaDirectoryReadPipe -Pipe $script:Pipe -Final ([pscustomobject]@{Rows=5000})
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while(-not $script:Pipe.Closed -and $watch.Elapsed.TotalSeconds -lt 90){
  $a=Admit-Next
  Assert-Fixture (@($a.Changes).Count -le 100) 'Batch exceeded producer bound'
  [void](Complete-Receipt $a);Invoke-DomeniaDirectoryStoreTick
 }
 Assert-Fixture ($script:Pipe.Closed -and $script:Pipe.Saved -eq 5000 -and $script:Ready.Count -eq 5000) 'Large scope dropped a row or stopped early'
 Assert-Fixture ($script:Admissions.Count -ge 50) 'Expected bounded batches'
}
Case 'Cached user and object renderers do not write to the index' {
 foreach($name in @('Fill-UserObject','Show-AdObjectResult')){
  $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))[0]
  $calls=@($fn.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Sync-DomeniaIndexEntry','Submit-DomeniaStoreBatch','Add-DomeniaIndexPersistence')},$true))
  Assert-Fixture ($calls.Count -eq 0) ($name+' writes while rendering')
 }
}
Case 'Legacy callbacks and object renderers fail closed on results without SQLite readback' {
 function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties)return $Result}
 function Test-DomeniaSearchStateCurrent {param($State)return $true}
 function Get-DomeniaControl {param($Name)return $null}
 $script:GlobalSearchGeneration=1
 $state=[pscustomobject]@{Generation=1;Search='';BaseDn='OU=Site,DC=example,DC=invalid';Scope='Subtree'}
 foreach($name in @('Complete-DomeniaBranchObjectsUi','Complete-DomeniaGlobalSearchUi','Complete-DomeniaOpenObjectUi','Show-AdObjectResult')){
  $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))[0]
  . ([scriptblock]::Create($fn.Extent.Text))
  $raw=[pscustomobject]@{Rows=@();Properties=@{};DataSource='LDAP';BaseDn=$state.BaseDn;Scope=$state.Scope}
  $caught=$false
  try{switch($name){
   'Complete-DomeniaOpenObjectUi'{& $name -Result $raw -CacheKey 'fixture' -Dn 'CN=Fixture,DC=invalid' -Type Machine}
   'Show-AdObjectResult'{& $name -Result $raw -Dn 'CN=Fixture,DC=invalid' -Type Machine}
   default{& $name -Result $raw -State $state}
  }}catch{$caught=$_.Exception.Message -like 'Affichage refuse*base locale*'}
  Assert-Fixture $caught ('Raw result accepted by '+$name)
 }
}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{Status=$(if($failed.Count){'FAIL'}else{'PASS'});Scope='Actual AD mapping and producer pipeline; inert async SQLite port, no AD/Windows/WPF';RealDirectoryAccessed=$false;RealSqliteAccessed=$false;Platform=[Environment]::OSVersion.Platform.ToString();PowerShell=$PSVersionTable.PSVersion.ToString();Cases=$script:Checks.Count;Assertions=$script:Assertions;Failed=$failed.Count;Results=$script:Checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 12
if($failed.Count){exit 1}
