#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
# Actual GlobalSearch body and dispatch, with inert directory/UI adapters. The 5,000-row
# fixture exercises conversion/streaming only: it is not a Windows or live AD benchmark.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$corePath=Join-Path $root 'Domenia-Core.ps1'
$enginePath=Join-Path $root 'modules/Domenia-Engine.UI.ps1'
function Read-FixtureAst {
    param([string]$Path)
    $tokens=$null;$errors=$null
    $parsed=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ('Parse error: '+$Path+': '+$errors[0].Message)}
    return $parsed
}
function Get-FixtureFunction {
    param($Ast,[string]$Name)
    $matches=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($matches.Count -ne 1){throw ('Missing/ambiguous function: '+$Name)}
    return $matches[0]
}
$core=Read-FixtureAst $corePath
$engine=Read-FixtureAst $enginePath
$searchFunction=Get-FixtureFunction $core 'Invoke-GlobalSearch'
$bodies=@($searchFunction.Body.FindAll({param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $n.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString -and
    $n.Value -match 'New-WSearcher' -and $n.Value -match 'RawCount='
},$true))
if($bodies.Count -ne 1){throw 'Expected one literal GlobalSearch worker body.'}
$script:WorkerBody=[string]$bodies[0].Value
$script:WorkerBlock=[scriptblock]::Create($script:WorkerBody)
$commonBodies=@($core.FindAll({param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $n.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString -and
    $n.Value -match 'function New-WBranchRow' -and $n.Value -match 'function New-WSearcher'
},$true))
if($commonBodies.Count -ne 1){throw 'Expected one literal WorkerCommon body.'}
$commonTokens=$null;$commonErrors=$null
$common=[Management.Automation.Language.Parser]::ParseInput($commonBodies[0].Value,[ref]$commonTokens,[ref]$commonErrors)
if(@($commonErrors).Count){throw 'WorkerCommon parse error.'}
foreach($name in @('Get-WPropFirst','Get-WPropAll','Convert-WLargeInteger','Convert-WFileTime','Convert-WDate','Convert-WGuid','Get-WObjectType','Get-WUacState','Convert-WDirectoryValue')){
    . ([scriptblock]::Create((Get-FixtureFunction $common $name).Extent.Text))
}
$branchText=(Get-FixtureFunction $common 'New-WBranchRow').Extent.Text -replace '^function New-WBranchRow','function Invoke-ProductionBranchRow'
. ([scriptblock]::Create($branchText))
$guard=Read-FixtureAst (Join-Path $root 'modules/Domenia-Guard.Model.ps1')
. ([scriptblock]::Create((Get-FixtureFunction $guard 'Get-DomeniaStructuredError').Extent.Text))
. ([scriptblock]::Create((Get-FixtureFunction $engine 'Invoke-DomeniaUiTaskDispatch').Extent.Text))
. (Join-Path $root 'modules/Domenia-Common.Model.ps1')
. (Join-Path $root 'modules/Domenia-Engine.Model.ps1')
. (Join-Path $root 'modules/Domenia-DirectoryStore.Model.ps1')
. ([scriptblock]::Create((Get-DomeniaDirectoryStoreWorkerPrelude)))
function Register-WCredentialFailure {param($Context,$ErrorValue,$Channel)return $false}

# The enumerable throws during MoveNext, just as a streamed LDAP search can fail after
# some results. It also allows cancellation exactly before a row is handed to the worker.
if($null -eq ('Domenia.SearchProgressFixture.Rows' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Threading;
namespace Domenia.SearchProgressFixture {
    // The fixture consumes raw records concurrently just like the independent store pump.
    // It archives them for assertions without changing the production 1,000-row bound.
    public sealed class Consumer : IDisposable {
        public readonly ConcurrentQueue<object> Input = new ConcurrentQueue<object>();
        public readonly ConcurrentQueue<object> Captured = new ConcurrentQueue<object>();
        private readonly Thread thread; private volatile bool stopped;
        public Consumer() { thread = new Thread(Run); thread.IsBackground = true; thread.Start(); }
        private void Run() { while(!stopped) { Drain(); Thread.Sleep(1); } Drain(); }
        private void Drain() { object item; while(Input.TryDequeue(out item)) Captured.Enqueue(item); }
        public void Dispose() { stopped = true; if(!thread.Join(5000)) throw new Exception("Fixture consumer failed to stop"); }
    }
    public sealed class Rows : IEnumerable, IDisposable {
        public object[] Values = new object[0];
        public int ThrowBeforeIndex = -1;
        public int CancelBeforeIndex = -1;
        public CancellationTokenSource Stop;
        public bool Disposed;
        public IEnumerator GetEnumerator() { return new Cursor(this); }
        public void Dispose() { Disposed = true; }
        private sealed class Cursor : IEnumerator {
            private readonly Rows owner; private int index = -1;
            public Cursor(Rows value) { owner = value; }
            public object Current { get { return owner.Values[index]; } }
            public bool MoveNext() {
                int next = index + 1;
                if (next == owner.ThrowBeforeIndex) throw new InvalidOperationException("Fixture LDAP stream interrupted");
                if (next >= owner.Values.Length) return false;
                if (next == owner.CancelBeforeIndex && owner.Stop != null) owner.Stop.Cancel();
                index = next; return true;
            }
            public void Reset() { index = -1; }
        }
    }
}
'@
}
$script:Checks=[Collections.Generic.List[object]]::new();$script:Assertions=0
function Expect {param([bool]$Condition,[string]$Message)$script:Assertions++;if(-not $Condition){throw $Message}}
function New-FixtureResult {
    param([int]$Index=1,[string]$Class='computer',[string]$Dn='')
    if(-not $Dn){$Dn='CN=PC'+$Index+',OU=Site,DC=example,DC=invalid'}
    return [pscustomobject]@{Properties=@{
        objectclass=@('top',$Class);name=@('PC'+$Index);samaccountname=@('PC'+$Index+'$')
        dnshostname=@('pc'+$Index+'.example.invalid');distinguishedname=@($Dn)
        useraccountcontrol=@(4096);objectguid=@([guid]::NewGuid());admincount=@('0')
    }}
}
function Reset-Fixture {
    $script:Tracker=[hashtable]::Synchronized(@{StartedTimestamp=[Diagnostics.Stopwatch]::GetTimestamp();LastRowTimestamp=0L;RowsRead=0L})
    $script:Stop=[Threading.CancellationTokenSource]::new()
    $script:Collection=[Domenia.SearchProgressFixture.Rows]::new();$script:Collection.Stop=$script:Stop
    $script:Searchers=[Collections.Generic.List[object]]::new();$script:Calls=[Collections.Generic.List[object]]::new()
    $script:Converted=0;$script:FailEveryCall=$false;$script:FailBoundServer=$false;$script:ConversionFailureAt=-1
    $script:Context=[pscustomobject]@{Server='dc.example.invalid';BaseDn='DC=example,DC=invalid';Domain='example.invalid';Netbios='EXAMPLE';BindUser='';Credential=$null;UseCredential=$false;PageSize=300}
    $script:Payload=[pscustomobject]@{
        BaseDn='OU=Site,DC=example,DC=invalid';Scope='Subtree';PrefixFilter='';FastFilter='';ExactFilter='';AnrFilter='';BroadFilter='(objectClass=computer)'
        Limit=10000;Properties=@('objectClass','name','distinguishedName','objectGUID','samaccountname');ServerTimeLimitSeconds=60;ClientTimeoutSeconds=90;StreamPageSize=250
        SearchReadProgress=$script:Tracker;Progress=[Collections.Concurrent.ConcurrentQueue[object]]::new();StopToken=$script:Stop.Token
        DirectoryReadState=[hashtable]::Synchronized(@{Started=$false;Done=$false;Final=$null;Error=''})
    }
}
function Case {
    param([string]$Name,[scriptblock]$Body)
    Reset-Fixture
    try{& $Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}
    finally{$script:Stop.Dispose()}
}
function New-WSearcher {
    param($Ctx,$BaseDn,$Filter,$Properties,$Scope,$Limit)
    $script:Calls.Add([pscustomobject]@{Server=$Ctx.Server;BaseDn=$BaseDn;Scope=$Scope;Filter=$Filter;Limit=$Limit})
    if($script:FailEveryCall -or ($script:FailBoundServer -and $Ctx.Server)){throw 'Fixture LDAP transport unavailable'}
    $searcher=[pscustomobject]@{ServerTimeLimit=[timespan]::Zero;ClientTimeout=[timespan]::Zero;PageSize=0;CacheResults=$true;Asynchronous=$false;SearchRoot=$null;Disposed=$false}
    $searcher|Add-Member ScriptMethod FindAll {return ,$script:Collection}
    $searcher|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $script:Searchers.Add($searcher)
    return $searcher
}
function New-WBranchRow {
    param($Result)
    $script:Converted++
    if($null -ne $script:Payload.SearchReadProgress){
        if([long]$script:Tracker.RowsRead -ne $script:Converted){throw 'Progress count was not advanced before row conversion.'}
        if([long]$script:Tracker.LastRowTimestamp -lt [long]$script:Tracker.StartedTimestamp){throw 'Progress timestamp was not advanced before row conversion.'}
    }
    if($script:Converted -eq $script:ConversionFailureAt){throw 'Fixture conversion rejected'}
    return (Invoke-ProductionBranchRow $Result)
}
function Invoke-FixtureWorker {
    $Context=$script:Context;$Payload=$script:Payload
    $consumer=[Domenia.SearchProgressFixture.Consumer]::new()
    $item=$null;while($Payload.Progress.TryDequeue([ref]$item)){$consumer.Input.Enqueue($item);$item=$null}
    $Payload.Progress=$consumer.Input
    try{return (& $script:WorkerBlock)}finally{$consumer.Dispose();$Payload.Progress=$consumer.Captured}
}
Case '5000 actual row conversions are streamed and counted as real LDAP progress' {
    $script:Collection.Values=@(for($i=1;$i -le 5000;$i++){New-FixtureResult $i})
    $out=Invoke-FixtureWorker
    Expect ($out.Rows.Count -eq 5000 -and $out.RawCount -eq 5000 -and -not $out.Partial -and -not $out.LimitReached) 'Large fixture was truncated or incorrectly marked partial.'
    Expect ($script:Tracker.RowsRead -eq 5000 -and $script:Converted -eq 5000 -and $script:Payload.Progress.Count -eq 5000) 'Rows were not all converted, streamed and counted.'
    Expect ($script:Searchers[0].PageSize -eq 250) 'Production worker still overrides the configured page size with the former 100-row cap.'
    Expect ($script:Collection.Disposed -and $script:Searchers[0].Disposed) 'Directory resources were not disposed.'
    $event=$null;[void]$script:Payload.Progress.TryDequeue([ref]$event)
    Expect ($event.Kind -ceq 'DirectoryRead' -and $event.Type -ceq 'Machine' -and $event.Properties.samaccountname[0] -ceq 'PC1$' -and $event.Properties.objectguid[0]) 'Typed raw record or explicit attribute mask was lost before storage.'
}
Case 'Empty successful LDAP responses do not manufacture row progress' {
    $out=Invoke-FixtureWorker
    Expect ($out.Rows.Count -eq 0 -and -not $out.Partial -and $script:Tracker.RowsRead -eq 0 -and $script:Tracker.LastRowTimestamp -eq 0) 'Empty result was treated as observed-row activity.'
}
Case 'Cached queue contents cannot count as LDAP activity' {
    $script:Payload.Progress.Enqueue([pscustomobject]@{Kind='CachedRow';Row=(New-FixtureResult);ObservedUtc=[datetime]::UtcNow.AddDays(1).ToString('o')})
    $out=Invoke-FixtureWorker
    Expect ($script:Tracker.RowsRead -eq 0 -and $script:Tracker.LastRowTimestamp -eq 0 -and $out.RawCount -eq 0) 'Cached queued data or its future wall-clock date extended the LDAP budget.'
}
Case 'Duplicate LDAP rows count as activity without duplicate display rows' {
    $script:Collection.Values=@((New-FixtureResult 1),(New-FixtureResult 1))
    $out=Invoke-FixtureWorker
    Expect ($script:Tracker.RowsRead -eq 2 -and $out.RawCount -eq 2 -and $out.Rows.Count -eq 1 -and $script:Payload.Progress.Count -eq 1) 'Deduplication and raw progress are conflated.'
}
Case 'Ignored object types still prove a real LDAP response' {
    $script:Collection.Values=@((New-FixtureResult 1 'unknown'),(New-FixtureResult 2))
    $out=Invoke-FixtureWorker
    Expect ($script:Tracker.RowsRead -eq 2 -and $out.Rows.Count -eq 1 -and $script:Payload.Progress.Count -eq 1) 'Raw activity depends on accepting the object for display.'
}
Case 'Result limit stops reading and keeps its distinct limit marker' {
    $script:Collection.Values=@((New-FixtureResult 1),(New-FixtureResult 2),(New-FixtureResult 3));$script:Payload.Limit=2
    $out=Invoke-FixtureWorker
    Expect ($out.Rows.Count -eq 2 -and $out.LimitReached -and -not $out.Partial -and $script:Tracker.RowsRead -eq 2) 'Limit path consumed a third row or lost its marker.'
}
Case 'Cancellation before the first received row does not report progress' {
    $script:Collection.Values=@((New-FixtureResult));$script:Stop.Cancel();$failed=$false
    try{Invoke-FixtureWorker}catch{$failed=$true}
    Expect ($failed -and $script:Tracker.RowsRead -eq 0 -and $script:Tracker.LastRowTimestamp -eq 0 -and $script:Converted -eq 0) 'Cancelled response counted or converted a row.'
    Expect ($script:Calls.Count -eq 0 -and $script:Payload.DirectoryReadState.Done) 'Already cancelled search opened LDAP or failed to close its producer state.'
}
Case 'Midstream cancellation keeps prior streamed rows and ignores the cancelled response' {
    $script:Collection.Values=@((New-FixtureResult 1),(New-FixtureResult 2),(New-FixtureResult 3));$script:Collection.CancelBeforeIndex=2;$failed=$false
    try{Invoke-FixtureWorker}catch{$failed=$true}
    Expect ($failed -and $script:Tracker.RowsRead -eq 2 -and $script:Payload.Progress.Count -eq 2 -and $script:Converted -eq 2) 'Cancellation advanced progress after the cancellation check.'
    Expect ($script:Calls.Count -eq 1 -and $script:Collection.Disposed) 'Cancelled stream retried or leaked.'
}
Case 'LDAP enumeration failure preserves partial rows without inventing completion' {
    $script:Collection.Values=@((New-FixtureResult 1),(New-FixtureResult 2),(New-FixtureResult 3));$script:Collection.ThrowBeforeIndex=2
    $out=Invoke-FixtureWorker
    Expect ($out.Partial -and $out.Failure -like '*Fixture LDAP stream interrupted*' -and $out.Rows.Count -eq 2) 'Midstream transport failure was reported as complete.'
    Expect ($script:Tracker.RowsRead -eq 2 -and $script:Payload.Progress.Count -eq 2 -and $script:Calls.Count -eq 1) 'Failure manufactured activity or retried a partially emitted result.'
}
Case 'A row received before failed conversion is counted as progress but never emitted' {
    $script:Collection.Values=@((New-FixtureResult 1),(New-FixtureResult 2));$script:ConversionFailureAt=2
    $out=Invoke-FixtureWorker
    Expect ($out.Partial -and $out.Rows.Count -eq 1 -and $script:Tracker.RowsRead -eq 2 -and $script:Payload.Progress.Count -eq 1) 'Progress timestamp only advances after successful conversion.'
}
Case 'Failed bind retries do not extend observed-row progress' {
    $script:FailEveryCall=$true;$failed=$false
    try{Invoke-FixtureWorker}catch{$failed=($_.Exception.Message -like '*echoue sur tous les contextes*')}
    Expect ($failed -and $script:Calls.Count -eq 2 -and $script:Tracker.RowsRead -eq 0 -and $script:Tracker.LastRowTimestamp -eq 0) 'Unsuccessful context attempts manufactured row progress.'
}
Case 'Successful fallback observes exactly its own rows in the original OU and depth' {
    $script:FailBoundServer=$true;$script:Payload.Scope='OneLevel';$script:Collection.Values=@((New-FixtureResult 1),(New-FixtureResult 2))
    $out=Invoke-FixtureWorker
    Expect ($script:Calls.Count -eq 2 -and $script:Tracker.RowsRead -eq 2 -and -not $out.Partial) 'Fallback did not complete with real progress.'
    foreach($call in $script:Calls){Expect ($call.BaseDn -ceq $script:Payload.BaseDn -and $call.Scope -ceq 'OneLevel') 'Fallback widened the selected OU.'}
}
Case 'Worker still supports callers without a progress tracker' {
    $script:Payload.SearchReadProgress=$null;$script:Collection.Values=@((New-FixtureResult))
    $out=Invoke-FixtureWorker
    Expect ($out.Rows.Count -eq 1 -and -not $out.Partial -and $script:Tracker.RowsRead -eq 0) 'Optional tracker became a mandatory worker dependency.'
}
Case 'LDAP page size honors a configured value above the previous cap' {
    $script:Payload.StreamPageSize=750;[void](Invoke-FixtureWorker)
    Expect ($script:Searchers[0].PageSize -eq 750) 'Configured page size was reduced silently.'
}
Case 'Configured LDAP request budgets reach the actual searcher' {
    $script:Payload.ServerTimeLimitSeconds=75;$script:Payload.ClientTimeoutSeconds=105;[void](Invoke-FixtureWorker)
    Expect ($script:Searchers[0].ServerTimeLimit.TotalSeconds -eq 75 -and $script:Searchers[0].ClientTimeout.TotalSeconds -eq 105) 'LDAP time budgets did not reach the directory adapter.'
}
Case 'GlobalSearch retains the in-process shared-object dispatch contract' {
    $digest=Get-DomeniaPayloadDigest $script:Payload
    $decision=Get-DomeniaIsolationDecision -OperationId GlobalSearch -Enabled $true -IsWrite $false -HasCredential $false -PayloadDigest $digest
    Expect (-not $decision.Isolate -and -not $digest) 'Live progress references would cross an unsupported JSON process boundary.'
}

# Execute the production caller's budget/payload assignments and Start-UiTask command.
# The rest of the search navigation/UI is intentionally outside this fixture.
$assignmentNames=@('searchIdleSeconds','searchMaxSeconds','searchServerSeconds','searchClientSeconds','payload')
$script:CallerAssignments=@($searchFunction.Body.FindAll({param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $assignmentNames -contains $n.Left.VariablePath.UserPath
},$true)|Sort-Object {$_.Extent.StartOffset})
if($script:CallerAssignments.Count -ne $assignmentNames.Count){throw 'Expected one production assignment for each search budget and payload.'}
$startCalls=@($searchFunction.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Start-UiTask'},$true))
if($startCalls.Count -ne 1){throw 'Expected one GlobalSearch Start-UiTask call.'}
$script:CallerStart=[scriptblock]::Create($startCalls[0].Extent.Text)
function Get-CfgValue {param($Section,$Name,$Default)$key=$Section+'.'+$Name;if($script:ConfigOverrides.ContainsKey($key)){return $script:ConfigOverrides[$key]};return $Default}
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$HardTimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
    $script:CapturedCall=[pscustomobject]@{OperationId=$OperationId;Payload=$Payload;TimeoutSeconds=$TimeoutSeconds;HardTimeoutSeconds=$HardTimeoutSeconds}
}
function Invoke-FixtureCaller {
    param([hashtable]$Overrides=@{})
    $script:ConfigOverrides=$Overrides;$script:CapturedCall=$null
    $scope=[pscustomobject]@{BaseDn='OU=Site,DC=example,DC=invalid';Scope='Subtree'}
    $prefixFilter='';$fastFilter='';$exactFilter='';$anrFilter='';$broadFilter='(objectClass=computer)';$limit=10000;$props=@('name')
    $code=$script:WorkerBody;$callbackState=[pscustomobject]@{Scope=$scope.Scope;BaseDn=$scope.BaseDn}
    foreach($assignment in $script:CallerAssignments){. ([scriptblock]::Create($assignment.Extent.Text))}
    & $script:CallerStart
    return $script:CapturedCall
}
Case 'Actual caller supplies 120-second inactivity, 900-second hard cap and 250-row pages by default' {
    $call=Invoke-FixtureCaller
    Expect ($call.OperationId -ceq 'GlobalSearch' -and $call.TimeoutSeconds -eq 120 -and $call.HardTimeoutSeconds -eq 900) 'Default task budgets are not wired to the production command.'
    Expect ($call.Payload.ServerTimeLimitSeconds -eq 60 -and $call.Payload.ClientTimeoutSeconds -eq 90 -and $call.Payload.StreamPageSize -eq 250) 'Default LDAP budgets or page size are not wired to the payload.'
    Expect ($call.Payload.SearchReadProgress.IsSynchronized -and $call.Payload.SearchReadProgress.StartedTimestamp -eq 0 -and $call.Payload.SearchReadProgress.LastRowTimestamp -eq 0 -and $call.Payload.SearchReadProgress.RowsRead -eq 0) 'Caller did not create a clean synchronized tracker.'
}
Case 'Legacy saved 45/8/12-second budgets are lifted to the safe new floors' {
    $call=Invoke-FixtureCaller @{'Async.SearchTimeoutSeconds'=45;'Browser.SearchServerTimeLimitSeconds'=8;'Browser.SearchClientTimeoutSeconds'=12;'Browser.SearchPageSize'=40}
    Expect ($call.TimeoutSeconds -eq 120 -and $call.HardTimeoutSeconds -eq 900 -and $call.Payload.ServerTimeLimitSeconds -eq 60 -and $call.Payload.ClientTimeoutSeconds -eq 90 -and $call.Payload.StreamPageSize -eq 100) 'An old saved setting preserves the old short deadline or excessive pagination.'
}
Case 'Supported longer budgets and page size remain configurable' {
    $call=Invoke-FixtureCaller @{'Async.SearchTimeoutSeconds'=180;'Async.SearchMaxDurationSeconds'=1200;'Browser.SearchServerTimeLimitSeconds'=120;'Browser.SearchClientTimeoutSeconds'=150;'Browser.SearchPageSize'=750}
    Expect ($call.TimeoutSeconds -eq 180 -and $call.HardTimeoutSeconds -eq 1200 -and $call.Payload.ServerTimeLimitSeconds -eq 120 -and $call.Payload.ClientTimeoutSeconds -eq 150 -and $call.Payload.StreamPageSize -eq 750) 'Supported configuration values were discarded.'
}
Case 'Total cap cannot precede idle timeout and LDAP client receives server plus 30 seconds' {
    $call=Invoke-FixtureCaller @{'Async.SearchTimeoutSeconds'=300;'Async.SearchMaxDurationSeconds'=1;'Browser.SearchServerTimeLimitSeconds'=180;'Browser.SearchClientTimeoutSeconds'=10}
    Expect ($call.TimeoutSeconds -eq 300 -and $call.HardTimeoutSeconds -eq 300 -and $call.Payload.ClientTimeoutSeconds -eq 210) 'Inconsistent configuration was passed through without normalization.'
}
Case 'All configurable budgets and LDAP page size retain a finite ceiling' {
    $call=Invoke-FixtureCaller @{'Async.SearchTimeoutSeconds'=99999;'Async.SearchMaxDurationSeconds'=99999;'Browser.SearchServerTimeLimitSeconds'=99999;'Browser.SearchClientTimeoutSeconds'=99999;'Browser.SearchPageSize'=99999}
    Expect ($call.TimeoutSeconds -eq 600 -and $call.HardTimeoutSeconds -eq 3600 -and $call.Payload.ServerTimeLimitSeconds -eq 300 -and $call.Payload.ClientTimeoutSeconds -eq 600 -and $call.Payload.StreamPageSize -eq 1000) 'Configuration bypasses a finite production bound.'
}
$livePath=Join-Path $root 'modules/Domenia-Live.UI.ps1'
$live=Read-FixtureAst $livePath
$beginLive=Get-FixtureFunction $live 'Begin-DomeniaLiveSearch'
$pageCalls=@($beginLive.Body.FindAll({param($n)
    $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Add-Member' -and
    @($n.CommandElements|Where-Object{$_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -ceq 'StreamPageSize'}).Count -eq 1
},$true))
if($pageCalls.Count -ne 1){throw 'Expected one live-search page-size assignment.'}
$script:PageCall=[scriptblock]::Create($pageCalls[0].Extent.Text)
Case 'Actual live-search preparation preserves the caller page size instead of overriding it with 40' {
    $Payload=[pscustomobject]@{StreamPageSize=750};[void](& $script:PageCall)
    Expect ($Payload.StreamPageSize -eq 750) 'Live-search initialization discarded the configured page size.'
    $Payload=[pscustomobject]@{};[void](& $script:PageCall)
    Expect ($Payload.StreamPageSize -eq 250) 'Live-search standalone default differs from the main caller.'
    $Payload=[pscustomobject]@{StreamPageSize=40};[void](& $script:PageCall)
    Expect ($Payload.StreamPageSize -eq 100) 'Live-search initialization retained a legacy undersized page.'
}

# The production dispatcher is executed against a real, short-lived PowerShell runspace.
# Only the submitted command is inert; there is no LDAP, WPF, subprocess or network call.
function Initialize-DomeniaEngineState {}
function Set-DomeniaTargetCredentialContext {param($Context,$Payload)return $Context}
function Set-DomeniaCredentialGuardContext {param($Context)return $Context}
function Assert-WCredentialAllowed {param($Context,$Channel)}
function Get-WorkerContext {param($OperationId)return [pscustomobject]@{OperationId=$OperationId}}
function Get-DomeniaContextCredentialIdentity {param($Context,$Provider)return 'fixture'}
function Get-DomeniaDispatchIsolation {param($Job,$Context)return [pscustomobject]@{Isolate=$false}}
function Set-ControlsBusy {param($Names,$Busy)}
function Set-Status {param($Text)}
function Register-DomeniaJobResources {param($Job)}
function New-DomeniaWorkerRunspace {
    param($OperationId,$Code,[switch]$IsWrite)
    $initial=[Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $entry=[Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Invoke-InertSearchRead',@'
param($Context,$Payload)
$p=$Payload.SearchReadProgress
if($null -eq $p -or [long]$p.StartedTimestamp -le 0 -or [long]$p.RowsRead -ne 0){throw 'Tracker not initialized before worker start.'}
$p.RowsRead=3L
$p.LastRowTimestamp=[Diagnostics.Stopwatch]::GetTimestamp()
[pscustomobject]@{StartedTimestamp=[long]$p.StartedTimestamp;RowsRead=[long]$p.RowsRead}
'@)
    $initial.Commands.Add($entry)
    $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initial);$runspace.Open()
    return [pscustomobject]@{Runspace=$runspace;CommandName='Invoke-InertSearchRead';CodeHash='inert-fixture'}
}
Case 'Actual dispatch resets a queued tracker, retains it on the job and shares it with the runspace' {
    $script:DemoMode=$false;$script:Tracker.StartedTimestamp=1L;$script:Tracker.LastRowTimestamp=1L;$script:Tracker.RowsRead=99L
    $job=[pscustomobject]@{
        OperationId='GlobalSearch';IsWrite=$false;Payload=$script:Payload;Provider='Directory';CredentialIdentity='';SchedulerManaged=$false;Code='inert';TimeoutSeconds=120
        BusyApplied=$false;DisableControls=@();StatusText='';PowerShell=$null;Runspace=$null;Handle=$null;CodeHash='';ExecutedOperationId='';Demo=$false;Isolated=$false;State='Queued';Started=[datetime]::UtcNow.AddMinutes(-5)
    }
    $before=[Diagnostics.Stopwatch]::GetTimestamp()
    try{
        [void](Invoke-DomeniaUiTaskDispatch $job)
        if(-not $job.Handle.AsyncWaitHandle.WaitOne(5000)){throw 'Inert runspace did not complete in five seconds.'}
        $out=@($job.PowerShell.EndInvoke($job.Handle))
        Expect ($job.PowerShell.Streams.Error.Count -eq 0 -and $out.Count -eq 1) 'Dispatch worker reported an error.'
        Expect ([object]::ReferenceEquals($job.SearchReadProgress,$script:Tracker) -and $null -eq $job.Payload) 'Job discarded the shared tracker when clearing its payload.'
        Expect ($script:Tracker.RowsRead -eq 3 -and $job.SearchReadProgress.RowsRead -eq 3) 'Runspace modifications were copied rather than shared.'
        Expect ($script:Tracker.StartedTimestamp -ge $before -and $script:Tracker.LastRowTimestamp -ge $script:Tracker.StartedTimestamp) 'Queued duration or previous activity leaked into the dispatched budget.'
    }finally{
        if($null -ne $job.PowerShell){$job.PowerShell.Dispose()}
        if($null -ne $job.Runspace){$job.Runspace.Dispose()}
    }
}
Case 'Actual dispatch fixes the response-time series of a local search before releasing the request (point 122)' {
    $script:DemoMode=$false
    $tracker=[hashtable]::Synchronized(@{StartedTimestamp=1L;LastRowTimestamp=0L;RowsRead=0L})
    $job=[pscustomobject]@{
        OperationId='LocalIndexRead';IsWrite=$false;Payload=[pscustomobject]@{Action='Search';SearchReadProgress=$tracker};Provider='Storage';CredentialIdentity='';SchedulerManaged=$false;Code='inert';TimeoutSeconds=20
        BusyApplied=$false;DisableControls=@();StatusText='';PowerShell=$null;Runspace=$null;Handle=$null;CodeHash='';ExecutedOperationId='';Demo=$false;Isolated=$false;State='Queued';Started=[datetime]::UtcNow
    }
    try{
        [void](Invoke-DomeniaUiTaskDispatch $job)
        Expect ($null -eq $job.Payload) 'Dispatch kept the request on the job.'
        Expect ([string]$job.MetricKey -ceq 'LocalIndexRead:Search') ('Series key not fixed before the request was released: '+[string]$job.MetricKey)
        if(-not $job.Handle.AsyncWaitHandle.WaitOne(5000)){throw 'Inert runspace did not complete in five seconds.'}
    }finally{
        if($null -ne $job.PowerShell){$job.PowerShell.Dispose()}
        if($null -ne $job.Runspace){$job.Runspace.Dispose()}
    }
}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{
    Status=$(if($failed.Count){'FAIL'}else{'PASS'});Scope='Actual GlobalSearch body and dispatch; inert LDAP/UI ports and a local runspace; not Windows/AD qualification'
    PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.Platform.ToString();NetworkAccessed=$false;WpfExecuted=$false;RealDirectoryAccessed=$false
    CoreSha256=(Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash.ToLowerInvariant();EngineSha256=(Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
    LiveSha256=(Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Cases=$script:Checks.Count;Assertions=$script:Assertions;Failed=$failed.Count;Results=$script:Checks.ToArray()
}
if($ReportPath){$parent=Split-Path -Parent $ReportPath;if($parent -and -not (Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)};[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
