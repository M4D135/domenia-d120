#requires -Version 5.1
# Pure, deterministic deadline checks. No Windows UI, AD, sleeping or network calls.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($name in @('Common.Model','Engine.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:Checks=[Collections.Generic.List[object]]::new();$script:Assertions=0
function Expect([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{& $Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}}
function Progress([long]$Start=100000,[long]$Last=0,[long]$Rows=0){return [hashtable]::Synchronized(@{StartedTimestamp=$Start;LastRowTimestamp=$Last;RowsRead=$Rows})}
function Search($Progress=(Progress),[double]$Idle=120,[double]$Total=900){
 return [pscustomobject]@{OperationId='GlobalSearch';Name='Recherche dans l annuaire';State='Running';IsWrite=$false;CancelRequested=$false;Superseded=$false;TimeoutSeconds=$Idle;HardTimeoutSeconds=$Total;SearchReadProgress=$Progress}
}
function Read-State($Job,[double]$Seconds,[double]$Legacy=$Seconds){Get-DomeniaReadTimeoutState -Job $Job -ElapsedSeconds $Legacy -NowTimestamp ([long](100000+$Seconds*1000)) -TimestampFrequency 1000}

Case 'The former 45-second wall limit does not stop an advancing LDAP search' {
 $state=Read-State (Search (Progress 100000 144000 746)) 46
 Expect (-not $state.Expired -and $state.ElapsedSeconds -eq 46 -and $state.IdleSeconds -eq 2 -and $state.RowsRead -eq 746) 'Advancing search cancelled at former limit'
}
Case '5000 raw arrivals over ten minutes remain admissible while progressing' {
 $progress=Progress;$job=Search $progress
 for($i=1;$i -le 5000;$i++){
  $progress.LastRowTimestamp=[long](100000+$i*120);$progress.RowsRead=[long]$i
  if(($i % 500) -eq 0){$state=Read-State $job ($i*0.12+1);Expect (-not $state.Expired -and $state.RowsRead -eq $i -and $state.IdleSeconds -eq 1) ('Search stopped after '+$i+' actual arrivals')}
 }
}
Case 'Idle deadline starts at dispatch when no first row has arrived' {
 $job=Search
 Expect (-not (Read-State $job 119).Expired) 'Slow first response stopped too early'
 $state=Read-State $job 121
 Expect ($state.Expired -and $state.Reason -eq 'Idle' -and $state.RowsRead -eq 0 -and $state.IdleSeconds -eq 121) 'No-first-row stall has no bounded timeout'
}
Case 'A stalled search expires after the last raw arrival and retains the diagnostic count' {
 $job=Search (Progress 100000 160000 746)
 Expect (-not (Read-State $job 179).Expired) 'Idle budget not relative to last LDAP result'
 $state=Read-State $job 181
 Expect ($state.Expired -and $state.Reason -eq 'Idle' -and $state.ElapsedSeconds -eq 181 -and $state.IdleSeconds -eq 121 -and $state.RowsRead -eq 746) 'Stall did not expire'
 Expect ($state.Message -like '*Timeout*181 s*121 s*746*partiels*') 'Search diagnostic omits elapsed, idle, received count or partial result warning'
}
Case 'Strict greater-than comparison preserves the former deadline boundary' {
 $job=Search
 Expect (-not (Read-State $job 120).Expired) 'Search expires at rather than after its bound'
 Expect ((Read-State $job 120.001).Expired) 'Search does not expire just beyond its bound'
}
Case 'The hard total cap wins even with a fresh row on every tick' {
 $job=Search (Progress 100000 1001000 5000)
 $state=Read-State $job 901
 Expect ($state.Expired -and $state.Reason -eq 'Total' -and $state.IdleSeconds -eq 0) 'Fresh arrivals bypassed hard total duration'
 Expect ($state.Message -like '*durée totale maximale*5000*partiels*') 'Hard deadline diagnostic is ambiguous'
}
Case 'The total cap wins when both idle and total deadlines are exceeded' {
 $state=Read-State (Search (Progress 100000 101000 1)) 901
 Expect ($state.Expired -and $state.Reason -eq 'Total') 'Idle reason hides a hard-cap expiration'
}
Case 'Configured total duration replaces the default and remains an absolute cap' {
 $job=Search (Progress 100000 1901000 5000) 180 1800
 $state=Read-State $job 1801
 Expect ($state.Expired -and $state.Reason -eq 'Total' -and $state.ElapsedSeconds -eq 1801) 'Configured hard cap ignored'
}
Case 'Missing total duration defaults to 900 seconds' {
 $job=Search (Progress 100000 1001000 5000);$job.PSObject.Properties.Remove('HardTimeoutSeconds')
 Expect ((Read-State $job 901).Reason -eq 'Total') 'Missing cap became unbounded'
}
Case 'A missing idle duration defaults to 120 seconds for searches' {
 $job=Search;$job.PSObject.Properties.Remove('TimeoutSeconds')
 Expect (-not (Read-State $job 119).Expired) 'Default idle duration too short'
 Expect ((Read-State $job 121).Reason -eq 'Idle') 'Default idle duration not applied'
}
Case 'Zero or non-finite deadline settings do not disable bounded operation' {
 foreach($bad in @(0,-1,[double]::NaN,[double]::PositiveInfinity)){
  $job=Search (Progress 100000 1001000 5000) $bad $bad
  Expect ((Read-State $job 901).Reason -eq 'Total') 'Malformed hard duration became unbounded'
  $job=Search (Progress) $bad $bad
  Expect ((Read-State $job 121).Reason -eq 'Idle') 'Malformed idle duration became unbounded'
 }
}
Case 'Cached queue growth is never treated as raw LDAP progress' {
 $job=Search;$job|Add-Member NoteProperty Rows ([Collections.ArrayList]::new());$job|Add-Member NoteProperty Queue ([Collections.Queue]::new())
 for($i=0;$i -lt 5000;$i++){[void]$job.Rows.Add($i);$job.Queue.Enqueue($i)}
 $state=Read-State $job 121
 Expect ($state.Expired -and $state.RowsRead -eq 0 -and $state.IdleSeconds -eq 121) 'Queue/cache activity kept a blocked LDAP call alive'
}
Case 'Missing or wrong-type progress uses the old elapsed timeout' {
 foreach($progress in @($null,'invalid',[pscustomobject]@{StartedTimestamp=100000;LastRowTimestamp=399000;RowsRead=5000},@{})){
  $job=Search $progress 45
  $state=Read-State $job 46
  Expect ($state.Expired -and $state.Reason -eq 'Timeout' -and $state.ElapsedSeconds -eq 46) 'Legacy deadline lost without a valid shared clock'
 }
}
Case 'Malformed, missing and fractional progress fields fail back to a bounded legacy deadline' {
 foreach($field in @('StartedTimestamp','LastRowTimestamp','RowsRead')){
  foreach($bad in @($null,'broken','1.5','9223372036854775808',-1)){
   $progress=Progress 100000 200000 123;$progress[$field]=$bad
   $state=Read-State (Search $progress) 300
   Expect ($state.Expired -and $state.Reason -eq 'Timeout' -and $state.ElapsedSeconds -eq 300) ('Malformed '+$field+' extends the read')
  }
 }
}
Case 'Future start and future last-row clocks do not reset the deadline' {
 foreach($progress in @((Progress 500000 0 0),(Progress 100000 500000 12))){
  $state=Read-State (Search $progress) 300
  Expect ($state.Expired -and $state.Reason -eq 'Timeout' -and $state.IdleSeconds -eq 300) 'Future clock made search fresh'
 }
}
Case 'Backwards last-row clocks and inconsistent count/timestamp pairs use bounded fallback' {
 foreach($progress in @((Progress 100000 99999 12),(Progress 100000 0 12),(Progress 100000 399000 0))){
  $state=Read-State (Search $progress) 300
  Expect ($state.Expired -and $state.Reason -eq 'Timeout') 'Inconsistent progress extended deadline'
 }
}
Case 'Invalid monotonic now or frequency uses elapsed fallback' {
 $job=Search (Progress 100000 100100 12)
 foreach($now in @(-1,0,99999)){
  $state=Get-DomeniaReadTimeoutState $job 300 $now 1000
  Expect ($state.Expired -and $state.Reason -eq 'Timeout') 'Clock moving before dispatch disabled timeout'
 }
 foreach($frequency in @(-1,0)){
  $state=Get-DomeniaReadTimeoutState $job 300 400000 $frequency
  Expect ($state.Expired -and $state.Reason -eq 'Timeout') 'Invalid frequency disabled timeout'
 }
}
Case 'The monotonic dispatch clock supersedes wall-clock jumps while valid' {
 $job=Search (Progress 100000 199000 1200)
 foreach($legacy in @(-1000,10000,[double]::NaN,[double]::PositiveInfinity)){
  $state=Read-State $job 100 $legacy
  Expect (-not $state.Expired -and $state.ElapsedSeconds -eq 100 -and $state.IdleSeconds -eq 1) 'Wall-clock jump overrode valid dispatch clock'
 }
}
Case 'A raw arrival during the snapshot cannot be mistaken for a future clock' {
 # The getter advances the observed arrival beyond the function-entry timestamp.
 # This deterministically models the worker winning the lock after UI call entry,
 # without threads, network timing, waiting or changing an explicitly injected clock.
 if(-not ('DomeniaSearchProgressDuringSnapshot' -as [type])){
  Add-Type -TypeDefinition @'
public sealed class DomeniaSearchProgressDuringSnapshot : System.Collections.Hashtable {
    public override object this[object key] {
        get {
            if (System.String.Equals(key as string, "LastRowTimestamp", System.StringComparison.Ordinal)) {
                long entered = System.Diagnostics.Stopwatch.GetTimestamp();
                long observed;
                do { observed = System.Diagnostics.Stopwatch.GetTimestamp(); } while (observed <= entered);
                return observed;
            }
            return base[key];
        }
        set { base[key] = value; }
    }
}
'@
 }
 $progress=[DomeniaSearchProgressDuringSnapshot]::new()
 $progress.StartedTimestamp=[Diagnostics.Stopwatch]::GetTimestamp()-200*[Diagnostics.Stopwatch]::Frequency
 $progress.RowsRead=1L
 $state=Get-DomeniaReadTimeoutState -Job (Search $progress) -ElapsedSeconds 200
 Expect (-not $state.Expired -and $state.Reason -eq '' -and $state.RowsRead -eq 1 -and $state.ElapsedSeconds -ge 200 -and $state.IdleSeconds -ge 0) 'An actual arrival after function entry triggered the legacy timeout'
}
Case 'Actual dispatch timing excludes time previously spent in the scheduler queue' {
 $job=Search (Progress 900000 0 0)
 $state=Get-DomeniaReadTimeoutState $job 800 910000 1000
 Expect (-not $state.Expired -and $state.ElapsedSeconds -eq 10 -and $state.IdleSeconds -eq 10) 'Time before dispatch counted against the search'
}
Case 'Ordinary jobs retain the former total elapsed deadline and exact message' {
 $job=Search (Progress 100000 999999 5000) 45 900;$job.OperationId='TreeChildren';$job.Name='Sous-branches'
 Expect (-not (Read-State $job 45).Expired) 'Ordinary job changed deadline boundary'
 $state=Read-State $job 46
 Expect ($state.Expired -and $state.Reason -eq 'Timeout' -and $state.Message -ceq 'Timeout apres 46s : Sous-branches') 'Ordinary timeout behavior or message changed'
}
Case 'Writes, queued, cancelled and completed work receive no new expiration effect' {
 foreach($stateName in @('Queued','Withdrawn','Completed','StopRequested','Cleanup','Cancelled','Canceled')){
  $job=Search;$job.State=$stateName;$state=Read-State $job 10000
  Expect (-not $state.Expired -and $state.Message -eq '') ('Unexpected timeout side effect for '+$stateName)
 }
 foreach($flag in @('IsWrite','CancelRequested','Superseded')){
  $job=Search;$job.$flag=$true;$state=Read-State $job 10000
  Expect (-not $state.Expired -and $state.Message -eq '') ('Unexpected timeout side effect for '+$flag)
 }
}
Case 'The shared progress dictionary is read-only to the decision function' {
 $progress=Progress 100000 260000 1234;$before=$progress|ConvertTo-Json -Compress
 $null=Read-State (Search $progress) 181
 Expect (($progress|ConvertTo-Json -Compress) -ceq $before) 'Deadline helper modified worker progress'
}
Case 'Concurrent session progress dictionaries remain independent' {
 $first=Progress 100000 100100 1;$second=Progress 100000 399000 5000
 $state1=Read-State (Search $first) 300;$state2=Read-State (Search $second) 300
 Expect ($state1.Expired -and -not $state2.Expired -and $state1.RowsRead -eq 1 -and $state2.RowsRead -eq 5000) 'One session extended another session deadline'
 $second.LastRowTimestamp=[long]499000;$second.RowsRead=[long]6000
 Expect ((Read-State (Search $first) 400).Expired -and $first.LastRowTimestamp -eq 100100) 'New session arrival mutated old session clock'
}
Case 'Generic dictionaries and synchronized hashtables follow the same rule' {
 $progress=[Collections.Generic.Dictionary[string,object]]::new();$progress['StartedTimestamp']=[long]100000;$progress['LastRowTimestamp']=[long]399000;$progress['RowsRead']=[long]5000
 $state=Read-State (Search $progress) 300
 Expect (-not $state.Expired -and $state.IdleSeconds -eq 1 -and $state.RowsRead -eq 5000) 'IDictionary contract not supported'
}
Case 'A null job is inert and progress is not inferred from unrelated job members' {
 Expect (-not (Read-State $null 10000).Expired) 'Null job throws or expires'
 $job=Search $null;$job|Add-Member NoteProperty LastRowTimestamp ([long]399000);$job|Add-Member NoteProperty RowsRead ([long]5000)
 Expect ((Read-State $job 300).Reason -eq 'Timeout') 'Unrelated members substitute for dispatch-owned progress'
}

$failed=@($script:Checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='SearchTimeout';Passed=($failed -eq 0);Total=$script:Checks.Count;Failed=$failed;Assertions=$script:Assertions;PowerShellVersion=[string]$PSVersionTable.PSVersion;Cases=$script:Checks.ToArray();Limitations=@('Deterministic pure deadline rules only. No Windows UI, live LDAP, network timing, cancellation or worker integration executed.')}
if($ReportPath){$parent=Split-Path -Parent $ReportPath;if($parent){[void][IO.Directory]::CreateDirectory($parent)};$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$report|ConvertTo-Json -Depth 9
if($failed){exit 1};exit 0
