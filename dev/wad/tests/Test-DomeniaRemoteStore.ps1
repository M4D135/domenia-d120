#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($module in @('Common.Model','Collection.Model','ProbeDetails.Model','Store.Model','Live.Model','Park.Model','Park.UI')){. (Join-Path $modules ('Domenia-'+$module+'.ps1'))}
$worker=[scriptblock]::Create((Get-DomeniaLiveProbeCode))
$script:checks=[Collections.Generic.List[object]]::new()
function Check($name,[scriptblock]$body){try{&$body;$script:checks.Add([pscustomobject]@{Name=$name;Passed=$true})}catch{$script:checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=$_.Exception.Message})}}
function Assert($value,$why){if(-not $value){throw $why}}
function New-Object {param([string]$TypeName)if($TypeName -eq 'Collections.ArrayList'){return ,([Collections.ArrayList]::new())};if($TypeName -match 'Ping'){$script:PingCalls++;throw 'Network blocked by fixture'};throw ('Unexpected New-Object '+$TypeName)}
function Enter-WCredentialAttempt {param($Context,$Channel)$script:Leases++;return [pscustomobject]@{Fixture=$true}}
function Exit-WCredentialAttempt {param($Lease)$script:LeaseReleases++}
function Assert-WCredentialAllowed {param($Context,$Channel)if($script:Paused){throw 'CredentialPaused'}}
function Register-WCredentialFailure {param($Context,$ErrorValue,$Channel)if($ErrorValue.Exception.Message -match 'fixture-bad-credential|CredentialPaused'){$script:Paused=$true;return $true};return $false}
function Get-WMachineCredential {param($Context)return $null}
function New-CimSessionOption {[CmdletBinding()]param($Protocol)return [pscustomobject]@{Protocol=$Protocol}}
function New-CimSession {[CmdletBinding()]param($ComputerName,$SessionOption,$OperationTimeoutSec,$Credential)$script:Sessions++;return [pscustomobject]@{Fixture=$true}}
function Remove-CimSession {[CmdletBinding()]param($CimSession)$script:Disposed++}
function Get-CimInstance {
 [CmdletBinding()]param($CimSession,$Namespace,$ClassName,$Property,$Filter,$OperationTimeoutSec)
 $script:Calls.Add([pscustomobject]@{Class=$ClassName;Properties=@($Property);Filter=$Filter})
 if($script:FailAuth){throw 'fixture-bad-credential'}
 if($script:FailConsole -and @($Property) -contains 'UserName'){throw 'UserName not readable'}
 switch($ClassName){
 'Win32_ComputerSystem'{[pscustomobject]@{UserName='';Manufacturer='Fixture';Model='Example';TotalPhysicalMemory=8589934592}}
 'Win32_OperatingSystem'{[pscustomobject]@{Caption='Windows fixture';BuildNumber='26100';LastBootUpTime=[datetime]'2026-10-12';ProductType=1}}
 'Win32_LogicalDisk'{[pscustomobject]@{Size=100GB;FreeSpace=40GB}}
 'MSFT_MpComputerStatus'{[pscustomobject]@{AntivirusEnabled=$true;RealTimeProtectionEnabled=$true}}
 default{throw ('Unknown fixture class '+$ClassName)}
 }
}
function Reset-Fixture {$script:Leases=0;$script:LeaseReleases=0;$script:Paused=$false;$script:FailAuth=$false;$script:Sessions=0;$script:Disposed=0;$script:PingCalls=0;$script:FailConsole=$false;$script:Calls=[Collections.Generic.List[object]]::new()}
function Invoke-Fixture($payload){$Context=[pscustomobject]@{UseCim=$true;Domain='';Netbios=''};$Payload=$payload;return & $worker}
function New-Payload {return [pscustomobject]@{Computer='PC-FIXTURE';Key='cn=pc,ou=test,dc=example,dc=invalid';Guid='00000000-0000-0000-0000-000000000001';CollectPing=$false;ProbeUser=$true;Inventory=$true;Probes=@();ValidateConsoleIdentity=$false;MethodSeconds=4}}
Check 'WMI-only skips ICMP and shares ComputerSystem read' {
 Reset-Fixture;$p=New-Payload;$r=Invoke-Fixture $p
 Assert ($script:PingCalls -eq 0) 'ICMP was attempted'
 Assert ($script:Sessions -eq 1 -and $script:Disposed -eq 1) 'CIM session not bounded/disposed'
 Assert ($script:Leases -eq 1 -and $script:LeaseReleases -eq 1) 'Authentication lease not released after first successful read'
 Assert (@($script:Calls|Where-Object Class -eq Win32_ComputerSystem).Count -eq 1) 'ComputerSystem read duplicated'
 Assert ($null -ne $r.Inventory -and -not $r.PingAttempted -and -not $r.PresenceCheckedUtc) 'WMI refreshed ping'
}
Check 'Console failure does not prevent inventory' {
 Reset-Fixture;$script:FailConsole=$true;$r=Invoke-Fixture (New-Payload)
 Assert ($r.Outcome -eq 'Unavailable' -and $null -ne $r.Inventory) 'Inventory blocked by console failure'
 Assert ($script:PingCalls -eq 0 -and $script:Disposed -eq 1) 'Unexpected network/session lifecycle'
}
Check 'Inventory can run without console request' {
 Reset-Fixture;$p=New-Payload;$p.ProbeUser=$false;$r=Invoke-Fixture $p
 Assert (-not $r.ConsoleAttempted -and $null -ne $r.Inventory) 'Inventory incorrectly gated by console'
 Assert (@($script:Calls|Where-Object {@($_.Properties) -contains 'UserName'}).Count -eq 0) 'Console still collected'
}
Check 'Catalog probes share one class call and one session' {
 Reset-Fixture;$p=New-Payload;$p.Inventory=$false;$p.ProbeUser=$false
 $p.Probes=@([pscustomobject]@{Id='sec.defender';Namespace='root\Microsoft\Windows\Defender';Class='MSFT_MpComputerStatus';Properties=@('AntivirusEnabled');Filter='';Mode='First';Skip=''},[pscustomobject]@{Id='sec.realtime';Namespace='root\Microsoft\Windows\Defender';Class='MSFT_MpComputerStatus';Properties=@('RealTimeProtectionEnabled');Filter='';Mode='First';Skip=''})
 $p|Add-Member AllowedClasses @('MSFT_MpComputerStatus');$r=Invoke-Fixture $p
 Assert ($script:Calls.Count -eq 1 -and $script:Calls[0].Properties.Count -eq 2) 'Probe calls not shared'
 Assert ($r.Probes.'sec.defender'.Count -eq 1 -and $r.Probes.'sec.realtime'.Count -eq 1) 'Probe result absent'
 Assert ($script:PingCalls -eq 0 -and $script:Sessions -eq 1 -and $script:Disposed -eq 1) 'Unexpected transport calls'
}

# Point 13: console, light inventory and catalog probes of the same class share one CIM read; the worker counts the
# queries avoided. Point 17: every finished CIM query advances the progress channel of a campaign.
function New-SharedProbe {param([string]$Id,[string]$Class,[string]$Property,[string]$Skip='',[string]$Namespace='root\cimv2')[pscustomobject]@{Id=$Id;Namespace=$Namespace;Class=$Class;Properties=@($Property);Filter='';Mode='First';Skip=$Skip}}
Check 'Console, inventory and same-class probes share their reads; avoided queries are counted' {
 Reset-Fixture;$p=New-Payload
 $p.Probes=@((New-SharedProbe 'hw.maker' 'Win32_ComputerSystem' 'Manufacturer'),(New-SharedProbe 'hw.threads' 'Win32_ComputerSystem' 'NumberOfLogicalProcessors'),(New-SharedProbe 'os.caption' 'Win32_OperatingSystem' 'Caption'))
 $p|Add-Member AllowedClasses @('Win32_ComputerSystem','Win32_OperatingSystem');$r=Invoke-Fixture $p
 Assert (@($script:Calls|Where-Object Class -eq Win32_ComputerSystem).Count -eq 1) 'ComputerSystem read twice'
 Assert (@($script:Calls|Where-Object Class -eq Win32_OperatingSystem).Count -eq 1) 'OperatingSystem read twice'
 Assert (@(@($script:Calls|Where-Object Class -eq Win32_ComputerSystem)[0].Properties) -contains 'NumberOfLogicalProcessors') 'Probe property not joined'
 Assert ($r.Probes.'hw.maker'.Count -eq 1 -and -not $r.Probes.'hw.maker'.Error -and $r.Probes.'os.caption'.Count -eq 1) 'Probe not served by the shared read'
 Assert ($r.CimQueries.Executed -eq 3 -and $r.CimQueries.Consumers -eq 7 -and $r.CimQueries.Avoided -eq 4) ('Counters '+$r.CimQueries.Executed+'/'+$r.CimQueries.Consumers+'/'+$r.CimQueries.Avoided)
}
Check 'A joined read refused as invalid falls back to the console read; the probe keeps its own failure' {
 Reset-Fixture
 function Get-CimInstance {
  [CmdletBinding()]param($CimSession,$Namespace,$ClassName,$Property,$Filter,$OperationTimeoutSec)
  $script:Calls.Add([pscustomobject]@{Class=$ClassName;Properties=@($Property);Filter=$Filter})
  if(@($Property) -contains 'NumberOfLogicalProcessors'){throw 'Invalid query'}
  switch($ClassName){
   'Win32_ComputerSystem'{[pscustomobject]@{UserName='EXAMPLE\alice';Manufacturer='Fixture';Model='Example';TotalPhysicalMemory=8589934592}}
   'Win32_OperatingSystem'{[pscustomobject]@{Caption='Windows fixture';BuildNumber='26100';LastBootUpTime=[datetime]'2026-10-12';ProductType=1}}
   'Win32_LogicalDisk'{[pscustomobject]@{Size=100GB;FreeSpace=40GB}}
   default{throw ('Unknown fixture class '+$ClassName)}
  }
 }
 $p=New-Payload;$p.Probes=@(New-SharedProbe 'hw.threads' 'Win32_ComputerSystem' 'NumberOfLogicalProcessors');$p|Add-Member AllowedClasses @('Win32_ComputerSystem');$r=Invoke-Fixture $p
 Assert ($r.Outcome -eq 'Observed' -and $r.User -eq 'EXAMPLE\alice' -and $null -ne $r.Inventory) ('Console lost because of a probe: '+$r.Outcome)
 Assert ([string]$r.Probes.'hw.threads'.Error) 'Probe failure hidden'
 Assert (@($script:Calls|Where-Object Class -eq Win32_ComputerSystem).Count -eq 3) 'Expected joined read, base read and probe read'
 Assert ($r.CimQueries.Executed -eq 5) ('Executed '+$r.CimQueries.Executed)
}
Check 'Controller check reuses the system type of the inventory read' {
 Reset-Fixture;$p=New-Payload
 $p.Probes=@(New-SharedProbe 'sec.defender' 'MSFT_MpComputerStatus' 'AntivirusEnabled' 'DomainController' 'root\Microsoft\Windows\Defender')
 $p|Add-Member AllowedClasses @('MSFT_MpComputerStatus');$r=Invoke-Fixture $p
 $os=@($script:Calls|Where-Object Class -eq Win32_OperatingSystem)
 Assert ($os.Count -eq 1 -and @($os[0].Properties) -contains 'ProductType') 'System type read separately'
 Assert ($r.Probes.'sec.defender'.Count -eq 1 -and -not $r.Probes.'sec.defender'.Skipped) 'Workstation probe skipped'
}
Check 'Each finished CIM query advances the progress channel of a campaign' {
 Reset-Fixture;$progress=[hashtable]::Synchronized(@{StartedTimestamp=1L;LastRowTimestamp=0L;RowsRead=0L})
 $p=New-Payload;$p|Add-Member ReadProgress $progress;[void](Invoke-Fixture $p)
 Assert ([long]$progress.RowsRead -eq 3 -and [long]$progress.LastRowTimestamp -gt 0) ('Steps '+$progress.RowsRead)
}

Check 'The pinned body carries the CIM grouping rule itself, with no prelude added at run time' {
 # The worker hash covers the composed code: a function copied from the session at run time would make the reviewed
 # contract (update_worker_contracts.py mirrors the ProbeDetails prelude only) differ from the code really sent.
 $code=Get-DomeniaLiveProbeCode
 Assert ($code.StartsWith((Get-DomeniaProbeDetailWorkerPrelude)+[Environment]::NewLine,[StringComparison]::Ordinal)) 'Unexpected prelude'
 Assert (-not $code.Contains('function Get-DomeniaCimGroupKey')) 'Model function copied at run time'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WCimGroupKey'},$true)
 Assert ($null -ne $fn) 'Grouping rule absent from the pinned body'
 . ([scriptblock]::Create($fn.Extent.Text))
 foreach($case in @(@('root\cimv2','Win32_LogicalDisk',"DeviceID='C:'"),@('ROOT\CIMV2','win32_service',"Name='a'"),@('root\Microsoft\Windows\Defender','MSFT_MpComputerStatus',''))){
  Assert ((Get-WCimGroupKey $case[0] $case[1] $case[2]) -ceq (Get-DomeniaCimGroupKey $case[0] $case[1] $case[2])) ('Worker and model rules differ for '+$case[1])
 }
}

Check 'Authentication refusal stops remaining CIM calls on the same host' {
 Reset-Fixture;$script:FailAuth=$true;$r=Invoke-Fixture (New-Payload)
 Assert ($script:Paused -and $r.Outcome -eq 'AuthRejected') 'Authentication circuit did not trip'
 Assert ($script:Calls.Count -eq 1 -and $script:Disposed -eq 1) 'A rejected credential was retried by another family'
 Assert ($script:Leases -eq 1 -and $script:LeaseReleases -eq 1) 'Authentication lease leaked after rejection'
}
Check 'Ping-only never opens CIM or creates console freshness' {
 Reset-Fixture;$p=New-Payload;$p.CollectPing=$true;$p.ProbeUser=$false;$p.Inventory=$false;$r=Invoke-Fixture $p
 Assert ($script:Sessions -eq 0 -and -not $r.ConsoleCheckedUtc -and $r.Outcome -eq 'PresenceOnly') 'Ping started WMI or fabricated its timestamp'
 Assert ($r.Presence -eq 'Erreur de ping' -and $r.PresenceCheckedUtc) 'Fixture ping failure not represented independently'
}
Check 'Source observations preserve independent family dates' {
 Reset-Fixture;$r=Invoke-Fixture (New-Payload);$changes=@(ConvertTo-DomeniaRemoteObservationChanges $r $r.Guid $r.Key)
 Assert ($changes.Count -eq 2 -and $changes.Family -notcontains 'Presence') 'WMI-only included Ping'
 foreach($c in $changes){Assert ($c.ObservedAtUtc -eq $c.AttemptedAtUtc -and $c.Status -eq 'Success') 'Callback freshness invented'}
}
Check 'Rejected identity and missing source time cannot enter the writer' {
 Reset-Fixture;$r=Invoke-Fixture (New-Payload);$failed=$false
 try{ConvertTo-DomeniaRemoteObservationChanges $r '00000000-0000-0000-0000-000000000099' $r.Key|Out-Null}catch{$failed=$true};Assert $failed 'Wrong GUID accepted'
 $r.ConsoleCheckedUtc='bad';$failed=$false
 try{ConvertTo-DomeniaRemoteObservationChanges $r $r.Guid $r.Key|Out-Null}catch{$failed=$true};Assert $failed 'Invalid time accepted'
}
Check 'Probe schema hash changes when the query definition changes' {
 $a=[pscustomobject]@{Id='test';Class='Example';Namespace='root\cimv2';Properties=@('A');Mode='First';Filter='';Skip=''}
 $ha=@(Add-DomeniaRemoteProbeDefinitionHash @($a))[0].DefinitionHash
 $a.Properties=@('B');$hb=@(Add-DomeniaRemoteProbeDefinitionHash @($a))[0].DefinitionHash
 Assert ($ha -and $hb -and $ha -cne $hb) 'Changed query reuses stale values'
}
# The pipeline fixtures do not load WPF or open a database/network connection.
function New-DomeniaTimer {param($Owner,$IntervalMs,[switch]$RunWhenHidden,$Tick)$o=[pscustomobject]@{};$o|Add-Member ScriptMethod Start {};$o|Add-Member ScriptMethod Stop {};return $o}
function Write-AppLog {param($Message,$Level)}
function Submit-DomeniaStoreBatch {
 param($Context,$BatchId,$Sequence,$Changes,$SuccessHandler,$ErrorHandler,$CallbackState)
 $script:Admissions.Add([pscustomobject]@{Context=$Context;BatchId=$BatchId;Changes=$Changes;CallbackState=$CallbackState;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler})
 if($script:Backpressure){return [pscustomobject]@{Accepted=$false;Backpressure=$true}}
 return [pscustomobject]@{Accepted=$true;Backpressure=$false}
}
function Record-Published {param($Result,$State)$script:Published.Add((Get-DomeniaCommittedObservation $Result $State))}
function Record-Failed {param($Message,$State)$script:Failures.Add([string]$Message)}
function Reset-Pipeline {
 $script:SessionEpoch=8L;$script:DomeniaAccountGeneration=2L;$script:DatabaseScopedPath=Join-Path ([IO.Path]::GetTempPath()) 'domenia-remote-fixture.db';$script:Conn=[pscustomobject]@{BaseDn='dc=example,dc=invalid'}
 $script:AsyncEngineClosing=$false;$script:DomeniaRemoteStoreQueue=$null;$script:DomeniaRemoteStoreTimer=$null;$script:Backpressure=$false
 $script:Admissions=[Collections.Generic.List[object]]::new();$script:Published=[Collections.Generic.List[object]]::new();$script:Failures=[Collections.Generic.List[string]]::new()
 $context=[pscustomobject]@{Version=1;StoreId=(Get-DomeniaStoreId $script:DatabaseScopedPath $script:Conn.BaseDn);Path=$script:DatabaseScopedPath;DomainDn=$script:Conn.BaseDn;SessionEpoch=8L;RequestId='remote-test';Generation=3L;ScopeDn='cn=pc,ou=test,dc=example,dc=invalid';Subtree=$false}
 return [pscustomobject]@{StoreContext=$context;AccountGeneration=2L;StoreGuid='00000000-0000-0000-0000-000000000001';StoreDn=$context.ScopeDn}
}
function Canonical-Receipt($admission,[string]$Value='committed value'){
 [pscustomobject]@{Saved=$true;DataSource='SQLite';BatchId=$admission.BatchId;RequestId=$admission.Context.RequestId;StoreId=$admission.Context.StoreId;ObservationRows=@([pscustomobject]@{Key=$admission.Context.ScopeDn;Guid='00000000-0000-0000-0000-000000000001';Presence=$Value;Revision=17})}
}
Check 'Admission does not publish; callback uses canonical SQL SELECT only' {
 $state=Reset-Pipeline;Reset-Fixture;$r=Invoke-Fixture (New-Payload)
 [void](Submit-DomeniaRemoteObservations $r $state 'Record-Published' 'Record-Failed')
 Assert ($script:Published.Count -eq 0 -and $script:Admissions.Count -eq 1) 'Raw data published on admission'
 $a=$script:Admissions[0];Complete-DomeniaRemoteStoreBatch (Canonical-Receipt $a) $a.CallbackState
 Assert ($script:Published.Count -eq 1 -and $script:Published[0].Presence -eq 'committed value') 'Worker result bypassed canonical readback'
 Complete-DomeniaRemoteStoreBatch (Canonical-Receipt $a) $a.CallbackState
 [void](Submit-DomeniaRemoteObservations $r $state 'Record-Published' 'Record-Failed')
 Assert ($script:Published.Count -eq 1 -and $script:Admissions.Count -eq 1) 'Duplicate worker/callback delivery applied a measurement twice'
}
Check 'Backpressure retains immutable batch identity and contents' {
 $state=Reset-Pipeline;Reset-Fixture;$r=Invoke-Fixture (New-Payload);$script:Backpressure=$true
 [void](Submit-DomeniaRemoteObservations $r $state 'Record-Published' 'Record-Failed');$first=$script:Admissions[0];$json=$first.Changes|ConvertTo-Json -Depth 20 -Compress
 $r.Inventory.Model='mutated after enqueue';$script:Backpressure=$false;Invoke-DomeniaRemoteStoreQueue
 Assert ($script:Admissions.Count -eq 2 -and $script:Admissions[1].BatchId -ceq $first.BatchId) 'Backpressure created new batch'
 Assert (($script:Admissions[1].Changes|ConvertTo-Json -Depth 20 -Compress) -ceq $json) 'Queued batch mutated'
 Assert ($script:Published.Count -eq 0 -and $script:DomeniaRemoteStoreQueue.Count -eq 0) 'Admission treated as commit'
}
Check 'Storage failure and false receipt never publish values' {
 $state=Reset-Pipeline;Reset-Fixture;$r=Invoke-Fixture (New-Payload)
 [void](Submit-DomeniaRemoteObservations $r $state 'Record-Published' 'Record-Failed');$a=$script:Admissions[0]
 Fail-DomeniaRemoteStoreBatch 'disk full fixture' $a.CallbackState
 $receipt=Canonical-Receipt $a;$receipt.Saved=$false;Complete-DomeniaRemoteStoreBatch $receipt $a.CallbackState
 Assert ($script:Published.Count -eq 0 -and $script:Failures.Count -eq 2) 'Failed commit reached view'
}
Check 'Committed old account/session cannot publish into new UI context' {
 $state=Reset-Pipeline;$r=Canonical-Receipt ([pscustomobject]@{BatchId='x';Context=$state.StoreContext})
 Assert (Test-DomeniaRemoteStoreContext $state $r) 'Valid original context rejected'
 $script:DomeniaAccountGeneration++;Assert (-not (Test-DomeniaRemoteStoreContext $state $r)) 'Account change not fenced'
 $script:DomeniaAccountGeneration=2;$script:SessionEpoch++;Assert (-not (Test-DomeniaRemoteStoreContext $state $r)) 'Session change not fenced'
}

Check 'Cancellation suppresses publication without invalidating captured persistence context' {
 $state=Reset-Pipeline;$state|Add-Member SuppressPublish $true
 $receipt=Canonical-Receipt ([pscustomobject]@{BatchId='x';Context=$state.StoreContext})
 Assert (-not (Test-DomeniaRemoteStoreContext $state $receipt)) 'Cancelled collection published to UI'
 $state|Add-Member ResultKind 'ComputerLastUser';$state|Add-Member RequestKey 'last-user-v1';$state|Add-Member PublishHandler 'Record-Published';$state|Add-Member PublishErrorHandler 'Record-Failed'
 [void](Submit-DomeniaRemoteDetail -Data ([pscustomobject]@{Success=$true;Computer='PC-FIXTURE'}) -State $state -Succeeded $true -SourceCompletedUtc '2026-10-13T10:00:00Z')
 Assert ($script:Admissions.Count -eq 1 -and $script:Published.Count -eq 0) 'Suppressed publication also discarded collected data'
}
function Record-Detail {param($Result,$State)$script:DetailPublished.Add($Result)}
Check 'A failed detail read publishes committed AttemptData instead of old success' {
 $state=Reset-Pipeline;$script:DetailPublished=[Collections.Generic.List[object]]::new()
 $state|Add-Member ResultKind 'ComputerLastUser';$state|Add-Member RequestKey 'last-user-v1';$state|Add-Member PublishHandler 'Record-Detail';$state|Add-Member PublishErrorHandler 'Record-Failed'
 $r=Canonical-Receipt ([pscustomobject]@{BatchId='x';Context=$state.StoreContext})
 $r|Add-Member SnapshotRevision 25
 $r|Add-Member Details @([pscustomobject]@{Guid=$state.StoreGuid;ResultKind='ComputerLastUser';RequestKey='last-user-v1';Status='Error';LastAttemptAtUtc='2026-10-13T10:00:00Z';Data=[pscustomobject]@{Success=$true;UserLogin='old-success'};AttemptData=[pscustomobject]@{Success=$false;UserLogin='';Details='error from SELECT'}})
 Complete-DomeniaRemoteDetailStored $r $state
 Assert ($script:DetailPublished.Count -eq 1 -and -not $script:DetailPublished[0].Success -and $script:DetailPublished[0].Details -eq 'error from SELECT') 'Previous success masquerades as fresh result'
 Assert ($script:DetailPublished[0].DataSource -eq 'SQLite' -and $script:DetailPublished[0].SourceCompletedUtc -eq '2026-10-13T10:00:00Z') 'Detail lost SQL/source provenance'
}
Check 'Wrong detail key is refused before renderer' {
 $state=Reset-Pipeline;$script:DetailPublished=[Collections.Generic.List[object]]::new()
 $state|Add-Member ResultKind 'ComputerLastUser';$state|Add-Member RequestKey 'expected';$state|Add-Member PublishHandler 'Record-Detail';$state|Add-Member PublishErrorHandler 'Record-Failed'
 $r=Canonical-Receipt ([pscustomobject]@{BatchId='x';Context=$state.StoreContext});$r|Add-Member Details @([pscustomobject]@{Guid=$state.StoreGuid;ResultKind='ComputerLastUser';RequestKey='different';Status='Success';Data=[pscustomobject]@{Success=$true}})
 Complete-DomeniaRemoteDetailStored $r $state
 Assert ($script:DetailPublished.Count -eq 0 -and $script:Failures.Count -eq 1) 'Wrong query result published'
}

Check 'Classic projection preserves required software fields and excludes secret WMI rows' {
 $packet=[pscustomobject]@{Computer='PC-FIXTURE';Success=$true;Rows=@([pscustomobject]@{Name='Tool';Size='12 Mo';UninstallString='remove-tool.exe';Unexpected='not persisted'});Schema=@([pscustomobject]@{Property='Password';Type='String'},[pscustomobject]@{Property='Model';Type='String'});Instances=@([pscustomobject]@{Instance=1;Property='Password';Value='must not persist'},[pscustomobject]@{Instance=1;Property='Model';Value='Model X'})}
 $safe=ConvertTo-DomeniaClassicStoreData $packet 'WmiExplorer'
 Assert ($safe.Rows[0].Size -eq '12 Mo' -and $safe.Rows[0].UninstallString -eq 'remove-tool.exe') 'Required software fields lost'
 Assert ($safe.Instances.Count -eq 1 -and $safe.Schema.Count -eq 1 -and $safe.RedactedSecretRows -eq 2) 'Secret property rows persisted'
 Assert (-not ($safe|ConvertTo-Json -Depth 10 -Compress).Contains('must not persist') -and $null -eq $safe.Rows[0].PSObject.Properties['Unexpected']) 'Unknown or secret field escaped projection'
}
Check 'Classic renderer fence rejects same DN replaced by a new GUID' {
 $state=Reset-Pipeline;$script:SelectedObject=[pscustomobject]@{DN=$state.StoreDn;Safety=[pscustomobject]@{Guid=$state.StoreGuid}}
 $result=[pscustomobject]@{DataSource='SQLite'}
 Assert (Test-DomeniaClassicResultCurrent $result $state) 'Valid committed selected result rejected'
 $script:SelectedObject.Safety.Guid='00000000-0000-0000-0000-000000000099'
 Assert (-not (Test-DomeniaClassicResultCurrent $result $state)) 'Reused DN accepted as old object identity'
}
$core=Join-Path (Split-Path -Parent $PSScriptRoot) 'Domenia-Core.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$errors)
foreach($factoryName in @('Get-DomeniaInventoryWorkerCode','Get-DomeniaSoftwareWorkerCode','Get-DomeniaWmiNamespacesWorkerCode','Get-DomeniaWmiClassesWorkerCode','Get-DomeniaWmiQueryWorkerCode')){
 $definition=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $factoryName},$true))[0]
 . ([scriptblock]::Create($definition.Extent.Text))
 Check ('Generated worker parses: '+$factoryName) { $errors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseInput((& $factoryName),[ref]$tokens,[ref]$errors);Assert (@($errors).Count -eq 0) (@($errors)|Out-String) }
}
function New-WDomeniaCimSession {param($Context,$Computer,$Credential,$Timeout)return [pscustomobject]@{Fixture=$true}}
function Remove-WDomeniaCimSession {param($Session)}
function Get-CimClass {[CmdletBinding()]param($CimSession,$Namespace,$ClassName)if($script:FailClass){throw 'fixture-bad-credential'};return [pscustomobject]@{CimClassName='FixtureClass';CimClassQualifiers=@();CimClassProperties=@();CimClassMethods=@()}}
function Invoke-WRemoteTaskScript {param($Context,$Computer,$Code,$Payload,$Timeout,$Reason)$script:FallbackCalls++;throw 'No fallback allowed in fixture'}
Check 'WMI class source timestamp survives its early success return' {
 Reset-Fixture;$script:FailClass=$false;$script:FallbackCalls=0;$Payload=[pscustomobject]@{Computer='PC-FIXTURE';Namespace='root\cimv2'};$Context=[pscustomobject]@{}
 $r=& ([scriptblock]::Create((Get-DomeniaWmiClassesWorkerCode)))
 Assert ($r.Success -and $r.SourceCompletedUtc -and $r.Classes.Count -eq 1 -and $script:FallbackCalls -eq 0) 'Early return omitted producer completion time'
}
Check 'WMI class bad credential stops before PsExec/task fallback' {
 Reset-Fixture;$script:FailClass=$true;$script:FallbackCalls=0;$Payload=[pscustomobject]@{Computer='PC-FIXTURE';Namespace='root\cimv2'};$Context=[pscustomobject]@{};$refused=$false
 try{& ([scriptblock]::Create((Get-DomeniaWmiClassesWorkerCode)))|Out-Null}catch{$refused=$true}
 Assert ($refused -and $script:Paused -and $script:FallbackCalls -eq 0) 'Rejected credential reached fallback transport'
}
foreach($name in @('Get-DomeniaEffectiveWorkerResult','Normalize-LinkComputer')){
 $definition=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
 if($null -ne $definition){. ([scriptblock]::Create($definition.Extent.Text))}
}
Check 'Failed classic collection records attempt without replacing the valid view' {
 $state=Reset-Pipeline;$script:DetailPublished=[Collections.Generic.List[object]]::new()
 $state|Add-Member Computer 'PC-FIXTURE';$state|Add-Member ResultKind 'ClassicSoftware';$state|Add-Member RequestKey 'software';$state|Add-Member PublishHandler 'Record-Detail';$state|Add-Member PublishErrorHandler 'Record-Failed'
 $packet=[pscustomobject]@{Computer='PC-FIXTURE';Success=$false;Rows=@();Access=@();SourceCompletedUtc='2026-10-13T10:00:00Z'}
 Complete-DomeniaClassicCollected $packet $state
 Assert ($script:Admissions.Count -eq 1) 'Failed attempt not persisted'
 $a=$script:Admissions[0];$change=$a.Changes[0];Assert ($change.Status -eq 'Error' -and $change.Data.CollectionError) 'Failure allowed a replacement renderer'
 $receipt=Canonical-Receipt $a;$receipt|Add-Member Details @([pscustomobject]@{Guid=$state.StoreGuid;ResultKind=$state.ResultKind;RequestKey=$state.RequestKey;Status='Error';Data=[pscustomobject]@{Rows=@('previous good value')};AttemptData=$change.Data;LastAttemptAtUtc=$change.AttemptedAtUtc})
 Complete-DomeniaRemoteStoreBatch $receipt $a.CallbackState
 Assert ($script:DetailPublished.Count -eq 0 -and $script:Failures.Count -eq 1) 'Failed refresh cleared previous view'
}
Check 'Classic error renderer is fenced after selecting another object' {
 $state=Reset-Pipeline;$script:SelectedObject=[pscustomobject]@{DN='cn=other,dc=example,dc=invalid';Safety=[pscustomobject]@{Guid=$state.StoreGuid}}
 Assert (-not (Test-DomeniaClassicResultCurrent -State $state -ContextOnly)) 'Late failure overwrote another machine status'
}
$result=[pscustomobject]@{Suite='RemoteStore';Passed=(@($script:checks|Where-Object{-not $_.Passed}).Count -eq 0);Total=$script:checks.Count;Checks=$script:checks.ToArray()}
if($ReportPath){$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$script:checks|Format-Table -AutoSize|Out-String|Write-Output
if(-not $result.Passed){exit 1}
