#requires -Version 5.1
param([string]$ReportPath='',[switch]$Scale,[ValidateSet(5000,10000,20000)][int]$ScaleObjects=20000)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$t=$null;$e=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse failed'}
$native=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DomeniaWinSqliteNative'},$true))[0].Extent.Text
if($PSVersionTable.PSEdition -eq 'Core'){
    $native=$native.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$native=$native.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
    elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$native=$native.Replace('winsqlite3.dll','libsqlite3.so.0')}
}
. ([scriptblock]::Create($native));[void](Initialize-DomeniaWinSqliteNative)
. (Join-Path $wad 'modules/Domenia-QueryLibrary.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Store.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Cache.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Storage.Worker.ps1')
. (Join-Path $wad 'modules/Domenia-Engine.Worker.ps1')
$worker=Get-DomeniaStorageWorkerCode;$reader=Get-DomeniaLocalIndexReadWorkerCode
$ast=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$t,[ref]$e)
if($e.Count){throw 'Worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-store-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder);$path=Join-Path $folder 'test.sqlite'
$context=[pscustomobject]@{Version=1;Path=$path;DomainDn='dc=test';StoreId=(Get-DomeniaStoreId $path 'dc=test');RequestId='test';Generation=1;SessionEpoch=1;ScopeDn='ou=parc,dc=test';Subtree=$true}
$cases=[Collections.Generic.List[object]]::new();$script:checks=0
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
function Case {param([string]$Name,[scriptblock]$Code);try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Read-TestDb {param([string]$Sql);$db=Open-DomeniaDatabase $path;try{return @(Invoke-DomeniaDbQuery $Sql $db)}finally{Close-DomeniaDatabase $db}}
function Commit {param([object[]]$Changes,[string]$Id=([guid]::NewGuid().ToString()),$Ctx=$context)
    $batch=ConvertTo-DomeniaStoreBatch -Context $Ctx -BatchId $Id -Sequence 1 -Changes $Changes
    $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$batch.Json;Hash=$batch.Hash})}
    return & ([scriptblock]::Create($worker))
}
function Read-Store {param($Query,$Ctx=$context)
    $Payload=[pscustomobject]@{Action='StoreRead';Path=$path;StoreId=$Ctx.StoreId;DomainDn=$Ctx.DomainDn;Query=$Query;BusyTimeoutMs=1000}
    return & ([scriptblock]::Create($reader))
}
$guid='00000000-0000-0000-0000-000000000001';$dn='CN=PC-1,OU=Parc,DC=test';$at='2026-01-01T00:00:00Z'
function Directory {param([string]$Id=$guid,[string]$Name='PC-1',[string]$At=$at)
 return [pscustomobject]@{Kind='DirectoryObject';Guid=$Id;DN=('CN='+$Name+',OU=Parc,DC=test');ObservedAtUtc=$At;Source='dc.test';Fields=@('Type','Name','State','Details');Data=[pscustomobject]@{Type='Machine';Name=$Name;State='Actif';Details=[pscustomobject]@{department='IT';member=@('one','two')}};Facts=[pscustomobject]@{OsVersion='26100';WhenCreated=$At}}
}
function Observation {param([string]$Family='Presence',[string]$At=$at,[string]$Status='Success',$Data=([pscustomobject]@{Computer='PC-1';Presence='En ligne'}))
 return [pscustomobject]@{Kind='Observation';Guid=$guid;DN=$dn;Family=$Family;AttemptedAtUtc=$At;ObservedAtUtc=$(if($Status -eq 'Success'){$At}else{''});Status=$Status;Error=$(if($Status -eq 'Error'){'denied'}else{''});Data=$Data}
}
try{
 $schema=@($core.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true)|Where-Object{$_.Value -match '^PRAGMA journal_mode=WAL;' -and $_.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'})
 if($schema.Count -ne 1){throw 'Schema count'}
 # The AST keeps the here-string unexpanded: the query library tables are inserted exactly as the core does at run time.
 $schemaSql=[string]$schema[0].Value;if($schemaSql.Contains('$(Get-DomeniaQueryLibrarySchema)')){$schemaSql=$schemaSql.Replace('$(Get-DomeniaQueryLibrarySchema)',(Get-DomeniaQueryLibrarySchema))}
 $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schemaSql $db);$script:sqliteVersion=[string](@(Invoke-DomeniaDbQuery 'SELECT sqlite_version() AS v;' $db)[0].v)}finally{Close-DomeniaDatabase $db}
 Case 'Directory commit returns persisted canonical row and durable revision' {
  $r=Commit @((Directory));Expect ($r.Saved -and $r.DataSource -eq 'SQLite' -and $r.Rows.Count -eq 1) 'receipt/readback';Expect ($r.Revision -eq 1 -and $r.SnapshotRevision -eq 1) 'revision';Expect ($r.SQLiteVersion -eq $script:sqliteVersion) 'actual sqlite version';Expect ($r.Rows[0].Details.department -eq 'IT') 'attributes';Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_store_batches;')[0].n -eq 1) 'durable receipt'
 }
 Case 'Same id/hash deduplicates, changed content refuses' {
  $id=[guid]::NewGuid().ToString();$c=Directory;$r1=Commit @($c) $id;$r2=Commit @($c) $id
  Expect ($r2.Already -and $r1.Revision -eq $r2.Revision) 'same receipt';$c.Data.Name='different';$refused=$false;try{Commit @($c) $id|Out-Null}catch{$refused=$true};Expect $refused 'conflicting reuse refused'
 }
 Case 'Masked partial AD update preserves other columns and detail keys' {
  $change=[pscustomobject]@{Kind='DirectoryObject';Guid=$guid;DN=$dn;ObservedAtUtc='2026-01-02T00:00:00Z';Source='dc.test';Fields=@('Name','Description','Details');Data=[pscustomobject]@{Name='PC-1';Description='new';Details=[pscustomobject]@{location='Paris'}}}
  $r=Commit @($change);Expect ($r.Rows[0].Name -eq 'PC-1' -and $r.Rows[0].Description -eq 'new') 'column mask';Expect ($r.Rows[0].Details.department -eq 'IT' -and $r.Rows[0].Details.location -eq 'Paris') 'detail mask'
  $old=Directory;$old.Data.Name='old';$r=Commit @($old);Expect ($r.Rows[0].Name -eq 'PC-1') 'old attribute refused'
 }
 Case 'Families merge; failure preserves success payload and timestamp' {
  $r=Commit @((Observation));Expect ($r.ObservationRows[0].Presence -eq 'En ligne') 'presence projection'
  $r=Commit @((Observation 'Inventory' '2026-01-02T00:00:00Z' 'Success' ([pscustomobject]@{Computer='PC-1';Inventory=[pscustomobject]@{OS='Win11'}})))
  Expect ($r.Observations.Count -eq 2 -and $r.ObservationRows[0].Presence -eq 'En ligne') 'independent families'
  $r=Commit @((Observation 'Inventory' '2026-01-03T00:00:00Z' 'Error' ([pscustomobject]@{Computer='PC-1';Inventory=$null;InventoryError='denied'})))
  $inv=@($r.Observations|Where-Object Family -eq Inventory)[0];Expect ($inv.Data.Inventory.OS -eq 'Win11' -and $inv.LastSuccessAtUtc -like '2026-01-02*') 'last success intact';Expect ($inv.Status -eq 'Error' -and $inv.AttemptData.InventoryError -eq 'denied') 'attempt independent';Expect ($r.ObservationRows[0].Inventory.OS -eq 'Win11') 'projection keeps last known inventory'
  Expect ($r.ObservationRows[0].Times.Presence.LastAttemptUtc -like '2026-01-01*') 'another family not rejuvenated'
  $cache=Read-TestDb 'SELECT payload FROM park_session_cache;';Expect ($cache.Count -eq 0) 'no duplicate materialized WMI payload';Expect ((Read-TestDb ("SELECT count(*) n FROM domenia_legacy_observation_imports WHERE object_guid='$guid';"))[0].n -eq 1) 'canonical read precedence confirmed by migration marker'
 }
 Case 'Late observation does not replace newer family' {
  $r=Commit @((Observation 'Presence' '2026-01-03T00:00:00Z' 'Success' ([pscustomobject]@{Presence='Sans reponse'})))
  $r=Commit @((Observation 'Presence' '2026-01-02T00:00:00Z'));Expect ($r.ObservationRows[0].Presence -eq 'Sans reponse') 'monotonic family'
 }
 Case 'Probe projection unwraps family payload' {
  $entry=[pscustomobject]@{Rows=@(,@('10.0.0.1'));CheckedUtc=$at;Succeeded=$true}
  $r=Commit @((Observation 'Probe:net.dns' $at 'Success' ([pscustomobject]@{Computer='PC-1';Probes=[pscustomobject]@{'net.dns'=$entry}})))
  Expect ($r.ObservationRows[0].Probes.'net.dns'.Rows[0][0] -eq '10.0.0.1') 'probe entry'
 }
 Case 'Failed probe retains known rows with an explicit failed-attempt flag' {
  $r=Commit @((Observation 'Probe:net.dns' '2026-01-03T00:00:00Z' 'Error' ([pscustomobject]@{Probes=[pscustomobject]@{'net.dns'=[pscustomobject]@{Rows=@();Count=0;Error='denied'}}})))
  $p=$r.ObservationRows[0].Probes.'net.dns';Expect ($p.Rows[0][0] -eq '10.0.0.1') 'known probe values';Expect ($p.Error -eq 'denied' -and $p.CheckedUtc -like '2026-01-01*' -and $p.AttemptedUtc -like '2026-01-03*') 'failed attempt is separate'
 }
 Case 'Detail result roundtrip and failed attempt retention' {
  $change=[pscustomobject]@{Kind='DetailResult';Guid=$guid;DN=$dn;ResultKind='WmiExplorer';RequestKey='win32_os';AttemptedAtUtc=$at;ObservedAtUtc=$at;Status='Success';Data=[pscustomobject]@{Rows=@([pscustomobject]@{Caption='Windows'})}}
  $r=Commit @($change);Expect ($r.Details[0].Data.Rows[0].Caption -eq 'Windows') 'detail stored'
  $change.Status='Error';$change.AttemptedAtUtc='2026-01-04T00:00:00Z';$change.ObservedAtUtc='';$change.Data=$null;$r=Commit @($change);Expect ($r.Details[0].Data.Rows[0].Caption -eq 'Windows' -and $r.Details[0].Status -eq 'Error') 'detail prior value'
 }
 Case 'Read path is SQLite, paginated, scoped and revision fenced' {
  $r=Read-Store ([pscustomobject]@{Kind='Directory';ScopeDn='OU=Parc,DC=test';Subtree=$true;Types=@('Machine');Limit=1;Offset=0;Term='pc-1'})
  Expect ($r.DataSource -eq 'SQLite' -and $r.Total -eq 1 -and $r.Rows.Count -eq 1) 'read canonical';$r=Read-Store ([pscustomobject]@{Kind='Observation';Guids=@($guid);Family='Inventory'});Expect ($r.Observations.Count -eq 1 -and $r.Observations[0].Status -eq 'Error') 'family read'
  $refused=$false;try{Read-Store ([pscustomobject]@{Kind='Directory';MinimumRevision=9999})|Out-Null}catch{$refused=$true};Expect $refused 'minimum revision'
 }
 Case 'Points 81-99: a reading reads its named families only, and disk volumes keep a bounded history' {
  $volumes={param([string]$At,[double]$Free) [pscustomobject]@{Computer='PC-1';Probes=[pscustomobject]@{'disk.volumes'=[pscustomobject]@{CheckedUtc=$At;Truncated=$false;Count=1;CountComplete=$true;Instances=@([pscustomobject]@{Id='';Index=1;Values=[pscustomobject]@{DeviceID='C:';Size=107374182400;FreeSpace=$Free};IncompleteProperties=@()});Rows=@(,@('C:'))}}}}
  [void](Commit @((Observation 'Probe:disk.volumes' '2026-02-01T12:00:00Z' 'Success' (& $volumes '2026-02-01T12:00:00Z' 53687091200))))
  [void](Commit @((Observation 'Probe:disk.volumes' '2026-02-08T12:00:00Z' 'Success' (& $volumes '2026-02-08T12:00:00Z' 42949672960))))
  $read=Read-Store ([pscustomobject]@{Kind='Observation';Guids=@($guid);Families=@('Probe:disk.volumes','Probe:net.dns');Limit=1})
  Expect ((@($read.Observations).Count -eq 2) -and (@($read.Observations|Where-Object{$_.Family -notin @('Probe:disk.volumes','Probe:net.dns')}).Count -eq 0)) 'families outside the list returned'
  $history=@(@($read.Observations|Where-Object{$_.Family -eq 'Probe:disk.volumes'})[0].Data.Probes.'disk.volumes'.History)
  Expect (($history.Count -eq 2) -and ([double]@($history[1].Items)[0].Free -eq 42949672960)) 'history not built from the previous committed payload'
  $summary=@(Read-TestDb "SELECT summary_payload FROM domenia_observations WHERE family='Probe:disk.volumes';")[0].summary_payload
  Expect (-not ([string]$summary).Contains('History')) 'history copied into the fleet summary'
  $refused=$false;try{Read-Store ([pscustomobject]@{Kind='Observation';Guids=@($guid);Families=@('Probe:x; DROP')})|Out-Null}catch{$refused=$true};Expect $refused 'invalid family accepted'
 }
 Case 'Account preference has closed fields and no secret' {
  $change=[pscustomobject]@{Kind='AccountPreference';Scope='Remote';UserName='LAB\reader';DomainDn='dc=test';UpdatedAtUtc=$at}
  $r=Commit @($change);Expect ($r.AccountPreferences[0].UserName -eq 'LAB\reader') 'identifier persisted';$r=Read-Store ([pscustomobject]@{Kind='AccountPreference';Scope='Remote'});Expect ($r.AccountPreferences.Count -eq 1) 'preference read'
 }
 Case 'Local account preference is bound to one normalized workstation and supports forgetting' {
  $changes=@([pscustomobject]@{Kind='AccountPreference';Scope='RemoteLocal:pc-a';UserName='PC-A\reader';DomainDn='dc=test';UpdatedAtUtc=$at},[pscustomobject]@{Kind='AccountPreference';Scope='RemoteLocal:pc-b';UserName='PC-B\other';DomainDn='dc=test';UpdatedAtUtc=$at})
  $r=Commit $changes;$r=Read-Store ([pscustomobject]@{Kind='AccountPreference';Scope='RemoteLocal:pc-a'})
  Expect ($r.AccountPreferences.Count -eq 1 -and $r.AccountPreferences[0].UserName -eq 'PC-A\reader') 'no cross-machine suggestion'
  $changes[0].UserName='';$changes[0].UpdatedAtUtc='2026-02-01T00:00:00Z';$r=Commit @($changes[0]);$r=Read-Store ([pscustomobject]@{Kind='AccountPreference';Scope='RemoteLocal:pc-a'})
  Expect ($r.AccountPreferences.Count -eq 1 -and $r.AccountPreferences[0].UserName -eq '') 'forget tombstone'
  $changes[0].Scope='RemoteLocal:PC-A';$refused=$false;try{Commit @($changes[0])|Out-Null}catch{$refused=$true};Expect $refused 'unnormalized local scope refused'
 }
 Case 'Wrong store/domain, secret, malformed data are refused without writes' {
  $before=(Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision
  $bad=[pscustomobject]@{Path=$path;DomainDn='dc=other';StoreId=(Get-DomeniaStoreId $path 'dc=other');RequestId='wrong'}
  $change=Directory;$change.DN='CN=PC,DC=other';$refused=$false;try{Commit @($change) -Ctx $bad|Out-Null}catch{$refused=$true};Expect $refused 'domain refusal'
  $secret=Directory;$secret.Data.Details|Add-Member -NotePropertyName 'ms-Mcs-AdmPwd' -NotePropertyValue 'fixture-secret';$refused=$false;try{Commit @($secret)|Out-Null}catch{$refused=$true};Expect $refused 'secret refused'
  Expect ((Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision -eq $before) 'no partial commit'
 }
 Case 'Failure midtransaction rolls back rows and receipt' {
  $first=Directory '00000000-0000-0000-0000-000000000099' 'New';$second=Directory '00000000-0000-0000-0000-000000000098' 'Broken';$second.Data.Type='unsupported';$before=(Read-TestDb 'SELECT count(*) n FROM ad_objects;')[0].n
  $refused=$false;try{Commit @($first,$second)|Out-Null}catch{$refused=$true};Expect $refused 'failed transaction';Expect ((Read-TestDb 'SELECT count(*) n FROM ad_objects;')[0].n -eq $before) 'rollback rows'
 }
 Case 'Immutable wire snapshot survives producer mutation' {
  $change=Directory;$batch=ConvertTo-DomeniaStoreBatch $context ([guid]::NewGuid().ToString()) 10 @($change);$hash=$batch.Hash;$change.Data.Name='modified'
  Expect (($batch.Json|ConvertFrom-Json).Changes[0].Data.Name -eq 'PC-1') 'wire detached';Expect ((Get-DomeniaStoreHash $batch.Json) -eq $hash) 'wire hash'
 }
 Case 'Database trigger proves callback data is a SELECT, not collector echo' {
  $db=Open-DomeniaDatabase $path
  try{[void](Invoke-DomeniaDbExec "CREATE TRIGGER test_store_readback AFTER INSERT ON ad_objects WHEN NEW.name='TriggerMe' BEGIN UPDATE ad_objects SET name='FromSQLite' WHERE object_key=NEW.object_key; END;" $db)}finally{Close-DomeniaDatabase $db}
  try{$r=Commit @((Directory '00000000-0000-0000-0000-000000000080' 'TriggerMe'));Expect ($r.Rows[0].Name -eq 'FromSQLite') 'SELECT witness'}finally{$db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec 'DROP TRIGGER test_store_readback;' $db)}finally{Close-DomeniaDatabase $db}}
 }
 Case 'Receipt failure rolls back changes already written in transaction' {
  $db=Open-DomeniaDatabase $path
  try{[void](Invoke-DomeniaDbExec "CREATE TRIGGER test_store_rollback BEFORE INSERT ON domenia_store_batches BEGIN SELECT RAISE(ABORT,'test failure after writes'); END;" $db)}finally{Close-DomeniaDatabase $db}
  $before=(Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision
  try{$refused=$false;try{Commit @((Directory '00000000-0000-0000-0000-000000000081' 'MustRollback'))|Out-Null}catch{$refused=$true};Expect $refused 'receipt failure propagated';Expect ((Read-TestDb "SELECT count(*) n FROM ad_objects WHERE name='MustRollback';")[0].n -eq 0) 'actual SQL writes rolled back';Expect ((Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision -eq $before) 'revision rolled back'}finally{$db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec 'DROP TRIGGER test_store_rollback;' $db)}finally{Close-DomeniaDatabase $db}}
 }
 Case 'Explicit empty identity list is empty, not whole directory' {
  $r=Read-Store ([pscustomobject]@{Kind='Directory';Guids=@()});Expect ($r.Total -eq 0 -and $r.Rows.Count -eq 0) 'empty selection'
 }
 Case 'Null field and empty/singleton attribute arrays keep their shape' {
  $change=[pscustomobject]@{Kind='DirectoryObject';Guid=$guid;DN=$dn;ObservedAtUtc='2026-02-01T00:00:00Z';Source='dc.test';Fields=@('Description','Details');Data=[pscustomobject]@{Description=$null;Details=[pscustomobject]@{empty=@();single=@('one')}}}
  $r=Commit @($change);Expect ($r.Rows[0].Description -eq '') 'explicit null accepted';Expect ($r.Rows[0].Details.empty -is [array] -and $r.Rows[0].Details.empty.Count -eq 0) 'empty array';Expect ($r.Rows[0].Details.single -is [array] -and $r.Rows[0].Details.single.Count -eq 1) 'single array'
 }
 Case 'Late success fills last-success without hiding a newer failed attempt' {
  $r=Commit @((Observation 'Console' '2026-03-02T00:00:00Z' 'Error' ([pscustomobject]@{Outcome='Denied';Detail='denied';LastUser='';CurrentUser='';RawAccount=''})))
  $r=Commit @((Observation 'Console' '2026-03-01T00:00:00Z' 'Success' ([pscustomobject]@{Outcome='Observed';User='LAB\reader';LastUser='LAB\reader';CurrentUser='LAB\reader';RawAccount='LAB\reader'})))
  $console=@($r.Observations|Where-Object Family -eq Console)[0]
  Expect ($console.Status -eq 'Error' -and $console.LastAttemptAtUtc -like '2026-03-02*') 'latest failure retained'
  Expect ($console.Data.User -eq 'LAB\reader' -and $console.LastSuccessAtUtc -like '2026-03-01*') 'older success still useful'
  Expect ($r.ObservationRows[0].Outcome -eq 'Denied' -and $r.ObservationRows[0].Revision -gt 0) 'projection failure and revision';Expect ($r.ObservationRows[0].LastUser -eq 'LAB\reader' -and $r.ObservationRows[0].RawAccount -eq 'LAB\reader') 'failed console does not erase known identity'
 }
 Case 'GUID move preserves measurements and late old-DN collection cannot move them back' {
  $moved='CN=PC-1,OU=Moved,DC=test';$change=Directory;$change.DN=$moved;$change.ObservedAtUtc='2026-04-01T00:00:00Z'
  $r=Commit @($change);Expect ($r.ObservationRows[0].Key -ieq $moved) 'projection follows GUID location'
  Expect ((Read-TestDb ('SELECT count(*) n FROM park_session_cache WHERE object_key='+(ConvertTo-DomeniaSqlLiteral $dn.ToLowerInvariant())+';'))[0].n -eq 0) 'old location projection removed'
  $r=Commit @((Observation 'Presence' '2026-04-02T00:00:00Z'));Expect ($r.ObservationRows[0].Key -ieq $moved) 'stale location cannot override canonical DN'
  $r=Read-Store ([pscustomobject]@{Kind='Observation';ScopeDn='OU=Moved,DC=test';Subtree=$true;Limit=250})
  Expect ($r.Total -eq 1 -and $r.ObservationRows.Count -eq 1 -and $r.Observations.Count -gt 1) 'page unit is GUID, not family'
  Expect ($r.ObservationRows[0].Times.Console.LastAttemptUtc -like '2026-03-02*') 'move does not rejuvenate console'
 }
 Case 'SQLite busy refuses the batch without a receipt or partial row' {
  $before=(Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision
  $db=Open-DomeniaDatabase $path
  try{
   [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db)
   $message='';try{Commit @((Directory '00000000-0000-0000-0000-000000000082' 'BusyRefused'))|Out-Null}catch{$message=$_.Exception.Message}
   Expect ($message -match 'SQLite code 5') 'actual SQLITE_BUSY'
  }finally{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db);Close-DomeniaDatabase $db}
  Expect ((Read-TestDb "SELECT count(*) n FROM ad_objects WHERE name='BusyRefused';")[0].n -eq 0) 'no partial row'
  Expect ((Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision -eq $before) 'no revision'
 }
 Case 'SQLite page-limit full error rolls back the batch and receipt' {
  # Engine-level fault injection on a private worker copy, not a claim about an actual full physical disk.
  $before=(Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision
  $pages=[int]((Read-TestDb 'PRAGMA page_count;')[0].page_count)+2
  $faultWorker=$worker.Replace("[void](Invoke-DomeniaDbExec 'PRAGMA synchronous=FULL;' `$db)",("[void](Invoke-DomeniaDbExec 'PRAGMA synchronous=FULL;PRAGMA max_page_count="+$pages+";' `$db)"))
  $change=Directory '00000000-0000-0000-0000-000000000083' 'FullRefused';$change.Data.Details=[pscustomobject]@{description=('X'*524288)}
  $id=[guid]::NewGuid().ToString();$b=ConvertTo-DomeniaStoreBatch $context $id 1 @($change);$Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$b.Json;Hash=$b.Hash})}
  $message='';try{& ([scriptblock]::Create($faultWorker))|Out-Null}catch{$message=$_.Exception.Message}
  Expect ($message -match 'SQLite code 13') 'actual SQLITE_FULL'
  Expect ((Read-TestDb "SELECT count(*) n FROM ad_objects WHERE name='FullRefused';")[0].n -eq 0) 'no partial row'
  Expect ((Read-TestDb ('SELECT count(*) n FROM domenia_store_batches WHERE batch_id='+(ConvertTo-DomeniaSqlLiteral $id)+';'))[0].n -eq 0) 'no receipt'
  Expect ((Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision -eq $before) 'no revision'
 }
 Case 'Lost postcommit readback retries the exact batch once without a second write' {
  $faultWorker=$worker.Replace('  $read=Read-StoreWCommitted $db @($commit.Batch.Changes.Guid)',"  throw 'test lost postcommit readback'`n  `$read=Read-StoreWCommitted `$db @(`$commit.Batch.Changes.Guid)")
  $change=Directory '00000000-0000-0000-0000-000000000084' 'CommittedOnce';$id=[guid]::NewGuid().ToString()
  $b=ConvertTo-DomeniaStoreBatch $context $id 1 @($change);$Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$b.Json;Hash=$b.Hash})}
  $message='';try{& ([scriptblock]::Create($faultWorker))|Out-Null}catch{$message=$_.Exception.Message}
  Expect ($message -eq 'test lost postcommit readback') 'readback failure propagated'
  $before=(Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision
  $r=Commit @($change) $id;Expect ($r.Already -and $r.Revision -eq $before -and $r.Rows[0].Name -eq 'CommittedOnce') 'retry reselects existing commit'
 }
 Case 'Fleet snapshot preserves unknown state and excludes it from active populations' {
  Add-Type -Path (Join-Path $wad 'modules/Domenia.Native.dll')
  foreach($name in @('Common.Model','Boards.Model','BoardFleet.Model','Probes.Model','HealthRules.Model')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
  $now=[datetime]::UtcNow;$stamp=$now.AddMinutes(-1).ToString('o');$scope='OU=StateFixture,DC=test';$keys=@()
  $changes=@(for($n=1;$n -le 3;$n++){
   $id='20000000-0000-0000-0000-'+$n.ToString('000000000000');$c=Directory $id ('State-'+$n) $stamp;$c.DN='CN=State-'+$n+','+$scope
   $c.Data.State=@('Actif','Desactive','')[($n-1)];$keys+=$c.DN;$c
   [pscustomobject]@{Kind='Observation';Guid=$id;DN=$c.DN;Family='Presence';AttemptedAtUtc=$stamp;ObservedAtUtc=$stamp;Status='Success';Data=[pscustomobject]@{Computer=('State-'+$n);Presence='En ligne';PresenceCheckedUtc=$stamp}}
  })
  [void](Commit $changes)
  $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;ModuleRoot=(Join-Path $wad 'modules');BusyTimeoutMs=1000;Scope=$scope;Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=$keys;ScopeKey=$scope;DomainDn='dc=test'}
  $r=& ([scriptblock]::Create($reader))
  Expect (($r.Machines.st -join ',') -eq 'A,D,U') 'unknown has its own persisted state'
  Expect ($r.MachineCount -eq 1 -and $r.Targets.Count -eq 1 -and $r.Targets[0].st -eq 'A') 'only proven active targets'
  Expect (@($r.Types|Where-Object {$_.t -eq 'Machine' -and $_.s -eq 'Inconnu'}).Count -eq 1) 'unknown type count retained'
  Expect ($r.Parents.Count -eq 1 -and $r.Parents[0].n -eq 1 -and $r.Coverage.FactsFresh -eq 1) 'active coverage and parent counts'
  Expect ($r.Presence.Count -eq 1 -and $r.Presence[0].object_guid -eq '20000000-0000-0000-0000-000000000001') 'explicit requested keys do not turn unknown into active'
  $read=Read-Store ([pscustomobject]@{Kind='Directory';ScopeDn=$scope;Subtree=$true;Limit=250})
  Expect ($read.Total -eq 3 -and $read.Rows.Count -eq 3) 'inactive and unknown remain queryable in canonical store'
 }
 Case 'Canonical queue runs promptly and keeps legacy debounce' {
  . (Join-Path $wad 'modules/Domenia-Storage.UI.ps1')
  function Set-DomeniaTimerInterval {param($Timer,$Interval);$Timer.IntervalMs=[int]$Interval.TotalMilliseconds}
  function Invoke-DomeniaTimerSoon {param($Owner);$script:soon=$Owner}
  $timer=[pscustomobject]@{IntervalMs=1000;IsEnabled=$false};$timer|Add-Member -MemberType ScriptMethod -Name Start -Value {$this.IsEnabled=$true}
  $script:Persistence=[pscustomobject]@{Pending=([ordered]@{one=[pscustomobject]@{Kind='StoreBatch'}});Job='';Failures=0;Timer=$timer}
  Request-DomeniaStorageWork;Expect ($timer.IntervalMs -eq 20 -and $timer.IsEnabled -and $script:soon -eq 'Timer:Storage') 'canonical bounded prompt tick'
  $script:Persistence.Pending.one.Kind='Link';Request-DomeniaStorageWork;Expect ($timer.IntervalMs -eq 1000) 'legacy debounce'
  $script:Persistence.Pending.one.Kind='StoreBatch';$script:Persistence.Failures=1;Request-DomeniaStorageWork;Expect ($timer.IntervalMs -eq 1000) 'failure backoff preserved'
 }
 Case 'Commit callback invalidates only the matching current store after validation' {
  . (Join-Path $wad 'modules/Domenia-Storage.UI.ps1')
  function Request-DomeniaStorageWork {}
  function Get-DomeniaEffectiveWorkerResult {param($Result,$Required);return $Result}
  function Complete-TestStore {param($Result,$State);$script:callbackSawStale=$script:FleetStale;$script:callbackCount++}
  function Write-AppLog {param($Text,$Level)}
  $script:Persistence=[pscustomobject]@{Job='job';InFlight=1;InFlightItems=@();Fault='';Failures=0;LastSavedAt=$null}
  $script:SessionEpoch=1;$script:DatabaseScopedPath=$path;$script:StoreSnapshotRevision=0L;$script:FleetStale=$false;$script:callbackCount=0
  $item=[pscustomobject]@{Kind='StoreBatch';Epoch=1;Path=$path;Context=$context;BatchId='test';SuccessHandler='Complete-TestStore';CallbackState=$null}
  $state=[pscustomobject]@{Items=@($item)};$r=[pscustomobject]@{Saved=$true;DataSource='SQLite';BatchId='test';StoreId=$context.StoreId;SnapshotRevision=12;CommittedAtUtc=$at;Rows=@([pscustomobject]@{Guid=$guid});Observations=@();Details=@()}
  Complete-DomeniaStorageWork $r $state;Expect ($script:callbackCount -eq 1 -and $script:callbackSawStale -and $script:StoreSnapshotRevision -eq 12) 'invalidate before callback'
  $script:FleetStale=$false;$item.Epoch=0;$r.SnapshotRevision=13;Complete-DomeniaStorageWork $r $state;Expect (-not $script:callbackSawStale -and $script:StoreSnapshotRevision -eq 12) 'stale epoch persists but no current notification'
  $item.Epoch=1;$r.Rows=@();Complete-DomeniaStorageWork $r $state;Expect (-not $script:FleetStale -and $script:StoreSnapshotRevision -eq 13) 'preferences only do not recalculate Fleet'
 }
 Case 'Admission detaches data, deduplicates and applies byte/object backpressure' {
  . (Join-Path $wad 'modules/Domenia-Storage.UI.ps1')
  function Request-DomeniaStorageWork {}
  $script:Persistence=[pscustomobject]@{Pending=([ordered]@{});InFlightItems=@();Failures=0}
  $change=Directory;$id=[guid]::NewGuid().ToString()
  $a=Submit-DomeniaStoreBatch $context $id 1 @($change) 'Complete-TestStore' 'Fail-TestStore' ([pscustomobject]@{Marker='exact'})
  Expect ($a.Accepted -and -not $a.Backpressure -and $script:Persistence.Pending.Count -eq 1) 'accepted only'
  $again=Submit-DomeniaStoreBatch $context $id 1 @($change) 'Complete-TestStore' 'Fail-TestStore' $null
  Expect ($again.Accepted -and $script:Persistence.Pending.Count -eq 1) 'queue deduplicates'
  $change.Data.Name='mutated';$item=@($script:Persistence.Pending.Values)[0];Expect (($item.Json|ConvertFrom-Json).Changes[0].Data.Name -eq 'PC-1') 'producer cannot mutate accepted row'
  $script:Persistence.Pending['full']=[pscustomobject]@{Kind='StoreBatch';Bytes=33554432L;ChangeCount=4096;QueueKey='full';Hash='x'}
  $a=Submit-DomeniaStoreBatch $context ([guid]::NewGuid().ToString()) 2 @($change) 'Complete-TestStore' 'Fail-TestStore' $null
  Expect (-not $a.Accepted -and $a.Backpressure -and $script:Persistence.Pending.Count -eq 2) 'no discard, explicit backpressure'
 }

 Case 'Explicit family projection reads only requested committed measurements' {
  $db=Open-DomeniaDatabase $path
  try{
   $r=Read-StoreWCommitted $db @($guid) -IncludeDirectoryDetails:$false -IncludeDetails:$false -ObservationFamilies @('Presence')
   Expect ($r.Observations.Count -eq 1 -and $r.Observations[0].Family -eq 'Presence') 'family SQL selection'
   Expect ($null -eq $r.ObservationRows[0].Inventory -and $r.ObservationRows[0].Times.Count -eq 1) 'no unnecessary WMI graph'
   $r=Read-StoreWCommitted $db @($guid) -ObservationFamilies @();Expect ($r.Observations.Count -eq 0) 'explicit empty families'
   $r=Read-StoreWCommitted $db @($guid);Expect ($r.Observations.Count -gt 1) 'default projection still complete'
  }finally{Close-DomeniaDatabase $db}
 }
 Case 'Low disk preflight refuses before COMMIT and preserves retry admission' {
  $before=(Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision
  $faultWorker=$worker.Replace(' $minimumBytes=33554432L+(4L*$incomingBytes)'," `$availableBytes=0L`n `$minimumBytes=33554432L+(4L*`$incomingBytes)")
  Expect ($faultWorker -cne $worker) 'fault injection matched worker preflight'
  $b=ConvertTo-DomeniaStoreBatch $context ([guid]::NewGuid().ToString()) 1 @((Directory));$Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$b.Json;Hash=$b.Hash})}
  $message='';try{& ([scriptblock]::Create($faultWorker))|Out-Null}catch{$message=$_.Exception.Message}
  Expect ($message -like 'StorageInsufficientSpace*') 'specific disk admission failure'
  Expect ((Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision -eq $before) 'no commit on low disk'
 }
 Case 'First canonical ping imports legacy WMI atomically without rewriting its payload' {
  $id='00000000-0000-0000-0000-000000000091';$change=Directory $id 'Legacy91';[void](Commit @($change))
  $legacy=[pscustomobject]@{Version=1;Guid=$id;Key=$change.DN.ToLowerInvariant();Computer='Legacy91';Presence='Hors ligne';PresenceCheckedUtc='2026-01-01T00:00:00Z';Inventory=[pscustomobject]@{CheckedUtc='2026-01-02T00:00:00Z';Model='Old inventory retained';RamBytes=8589934592};Probes=[pscustomobject]@{fixture=[pscustomobject]@{CheckedUtc='2026-01-03T00:00:00Z';Rows=@(@('42'));Count=1}}}
  $json=$legacy|ConvertTo-Json -Depth 12 -Compress;$db=Open-DomeniaDatabase $path
  try{[void](Invoke-DomeniaDbExec ("DELETE FROM domenia_legacy_observation_imports WHERE object_guid='$id';INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES("+((@($legacy.Key,'2026-01-03T00:00:00Z',$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+");CREATE TRIGGER no_cache_rewrite BEFORE INSERT ON park_session_cache BEGIN SELECT RAISE(ABORT,'unnecessary cache write'); END;") $db)}finally{Close-DomeniaDatabase $db}
  $ping=Observation 'Presence' '2026-02-01T00:00:00Z';$ping.Guid=$id;$ping.DN=$change.DN
  try{
   $r=Commit @($ping);Expect ($r.ObservationRows[0].Inventory.Model -eq 'Old inventory retained') 'legacy inventory remains visible'
   Expect ($r.ObservationRows[0].InventoryCheckedUtc -like '2026-01-02*' -and $r.ObservationRows[0].PresenceCheckedUtc -like '2026-02-01*') 'independent family clocks'
   Expect ([datetimeoffset]$r.ObservationRows[0].Probes.fixture.CheckedUtc -eq [datetimeoffset]'2026-01-03T00:00:00Z') 'legacy probe date unchanged'
   Expect ((Read-TestDb ("SELECT payload FROM park_session_cache WHERE object_key="+(ConvertTo-DomeniaSqlLiteral $legacy.Key)+';'))[0].payload -ceq $json) 'no full WMI payload rewrite'
   Expect ((Read-TestDb "SELECT count(*) n FROM domenia_legacy_observation_imports WHERE object_guid='$id';")[0].n -eq 1) 'migration marker committed'
   $Payload=[pscustomobject]@{Action='ParkTargets';Path=$path;Scope='Results';Targets=@([pscustomobject]@{name='Legacy91';distinguished_name=$change.DN;object_guid=$id});BusyTimeoutMs=1000}
   $targets=& ([scriptblock]::Create($reader));$previous=$targets.Rows[0].PreviousJson|ConvertFrom-Json
   Expect ($previous.Inventory.Model -eq 'Old inventory retained' -and $previous.Presence -eq 'En ligne') 'Park reads the same migrated canonical families'
   foreach($name in @('Common.Model','Boards.Model','BoardFleet.Model','Probes.Model','HealthRules.Model')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
   $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;ModuleRoot=(Join-Path $wad 'modules');BusyTimeoutMs=1000;Scope='OU=Parc,DC=test';Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now ([datetime]::UtcNow));Keys=@($change.DN);ScopeKey='OU=Parc,DC=test';DomainDn='dc=test'}
   $fleet=& ([scriptblock]::Create($reader));$stored=@($fleet.Presence|Where-Object object_guid -eq $id)
   Expect ($stored.Count -eq 1 -and $stored[0].observation.Inventory.Model -eq 'Old inventory retained' -and $stored[0].observation.PresenceCheckedUtc -like '2026-02-01*') 'Fleet and callback show the same families and dates'
  }finally{$db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec 'DROP TRIGGER no_cache_rewrite;' $db)}finally{Close-DomeniaDatabase $db}}
 }
 Case 'Invalid legacy family rolls back migration, new ping and receipt together' {
  $id='00000000-0000-0000-0000-000000000092';$change=Directory $id 'Legacy92';[void](Commit @($change))
  $legacy=[pscustomobject]@{Guid=$id;Key=$change.DN.ToLowerInvariant();Presence='Hors ligne';PresenceCheckedUtc=$at;Inventory=[pscustomobject]@{Model='No invented date'}}
  $json=$legacy|ConvertTo-Json -Depth 8 -Compress;$db=Open-DomeniaDatabase $path
  try{[void](Invoke-DomeniaDbExec ("DELETE FROM domenia_legacy_observation_imports WHERE object_guid='$id';INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES("+((@($legacy.Key,$at,$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)}finally{Close-DomeniaDatabase $db}
  $ping=Observation 'Presence' '2026-02-01T00:00:00Z';$ping.Guid=$id;$ping.DN=$change.DN;$before=(Read-TestDb 'SELECT count(*) n FROM domenia_store_batches;')[0].n
  $message='';try{Commit @($ping)|Out-Null}catch{$message=$_.Exception.Message};Expect ($message -like '*Date propre absente*') 'invalid migration explicitly refused'
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_legacy_observation_imports WHERE object_guid='$id';")[0].n -eq 0) 'no misleading migration marker'
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_observations WHERE object_guid='$id';")[0].n -eq 0) 'neither old partial nor new ping committed'
  Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_store_batches;')[0].n -eq $before) 'no receipt on failed migration'
  Expect ((Read-TestDb ("SELECT payload FROM park_session_cache WHERE object_key="+(ConvertTo-DomeniaSqlLiteral $legacy.Key)+';'))[0].payload -ceq $json) 'legacy fallback preserved exactly'
 }
 Case 'Legacy success fills a failed canonical family without hiding its newer failure' {
  $id='00000000-0000-0000-0000-000000000093';$change=Directory $id 'Legacy93';[void](Commit @($change))
  $failedPing=Observation 'Presence' '2026-03-01T00:00:00Z' 'Error' ([pscustomobject]@{Presence='Erreur de ping';PresenceDetail='denied'});$failedPing.Guid=$id;$failedPing.DN=$change.DN;[void](Commit @($failedPing))
  $legacy=[pscustomobject]@{Guid=$id;Key=$change.DN.ToLowerInvariant();Presence='En ligne';PresenceCheckedUtc=$at};$json=$legacy|ConvertTo-Json -Compress;$db=Open-DomeniaDatabase $path
  try{[void](Invoke-DomeniaDbExec ("DELETE FROM domenia_legacy_observation_imports WHERE object_guid='$id';INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES("+((@($legacy.Key,$at,$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)}finally{Close-DomeniaDatabase $db}
  $r=Commit @($change);$family=@($r.Observations|Where-Object Family -eq Presence)[0]
  Expect ($family.Status -eq 'Error' -and $family.LastAttemptAtUtc -like '2026-03-01*') 'new canonical attempt remains authoritative'
  Expect ($family.Data.Presence -eq 'En ligne' -and $family.LastSuccessAtUtc -like '2026-01-01*') 'real old success retained'
  Expect ($r.ObservationRows[0].Presence -eq 'Erreur de ping' -and $r.ObservationRows[0].PresenceCheckedUtc -like '2026-01-01*') 'error is not a fresh success'
 }
 Case 'Old receipt compaction preserves idempotence and rejects a changed replay' {
  $id=[guid]::NewGuid().ToString();$change=Directory '00000000-0000-0000-0000-000000000089' 'OldReceipt';$first=Commit @($change) $id
  $db=Open-DomeniaDatabase $path
  try{[void](Invoke-DomeniaDbExec ("UPDATE domenia_store_batches SET committed_at='2020-01-01T00:00:00.0000000Z' WHERE batch_id="+(ConvertTo-DomeniaSqlLiteral $id)+";UPDATE domenia_store_state SET revision=2303 WHERE id=1;") $db)}finally{Close-DomeniaDatabase $db}
  [void](Commit @((Directory)))
  $receipt=(Read-TestDb ('SELECT * FROM domenia_store_batches WHERE batch_id='+(ConvertTo-DomeniaSqlLiteral $id)+';'))[0]
  Expect ($receipt.changes_json -eq '[]' -and [long]$receipt.revision -eq $first.Revision -and $receipt.payload_hash.Length -eq 64) 'compact only descriptive identities'
  $again=Commit @($change) $id;Expect ($again.Already -and $again.Revision -eq $first.Revision -and $again.Rows[0].Name -eq 'OldReceipt') 'same old batch still idempotent'
  $change.Data.Name='Different';$refused=$false;try{Commit @($change) $id|Out-Null}catch{$refused=$true};Expect $refused 'changed old batch refused after compaction'
 }
 Case 'Maintenance includes canonical data and preserves preferences and receipts' {
  $Payload=[pscustomobject]@{Path=$path};$usage=& ([scriptblock]::Create((Get-DomeniaStorageUsageWorkerCode)))
  Expect (@($usage.Categories|Where-Object Category -eq Observations)[0].Tables.Table -contains 'domenia_observations') 'canonical measurements measured'
  Expect ($usage.ReceiptCount -gt 0 -and $usage.CompactedReceiptCount -gt 0 -and $usage.DiskFreeBytes -ge -1) 'receipt and actual disk counters'
  $before=(Read-TestDb 'SELECT count(*) n FROM domenia_store_batches;')[0].n;$prefs=(Read-TestDb 'SELECT count(*) n FROM domenia_account_preferences;')[0].n
  $Payload=[pscustomobject]@{Path=$path;Selection=@('Observations','Index');DryRun=$true};$preview=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))
  foreach($name in @('domenia_observations','domenia_details','domenia_directory_data')){Expect ($preview.Counts.Table -contains $name) ('purge preview '+$name)}
  $expected=@((Get-DomeniaPurgeTargets Observations)+(Get-DomeniaPurgeTargets Index)|ForEach-Object{$_.Table}|Sort-Object)
  Expect (($expected -join '|') -ceq (@($preview.Counts.Table|Sort-Object) -join '|')) 'pure plan and worker exact parity'
  [void](Commit @((Directory)));$Payload=[pscustomobject]@{Path=$path;Selection=@('Observations','Index');DryRun=$false;ExpectedFingerprint=$preview.Fingerprint}
  $refused=$false;try{& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))|Out-Null}catch{$refused=$true};Expect $refused 'same row counts but changed revision invalidates confirmation'
  $Payload.DryRun=$true;$preview=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)));$Payload.DryRun=$false;$Payload.ExpectedFingerprint=$preview.Fingerprint
  $result=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)));Expect $result.Committed 'confirmed purge committed'
  foreach($name in @('domenia_observations','domenia_details','domenia_directory_data')){Expect ((Read-TestDb ('SELECT count(*) n FROM '+$name+';'))[0].n -eq 0) ('canonical table cleared '+$name)}
  Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_store_batches;')[0].n -ge $before) 'receipts never purged'
  Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_account_preferences;')[0].n -eq $prefs) 'account preferences never purged'
 }
 Case 'Point 39: operator text is bound, quotes and LIKE characters match literally' {
  [void](Commit @((Directory '00000000-0000-0000-0000-000000000391' "PC-O'Brien"),(Directory '00000000-0000-0000-0000-000000000392' 'PC-100%'),(Directory '00000000-0000-0000-0000-000000000393' 'PC-1000')))
  $r=Read-Store ([pscustomobject]@{Kind='Directory';Term="o'brien";Limit=50;Projection='List'})
  Expect ($r.Total -eq 1 -and $r.Rows[0].Name -ceq "PC-O'Brien") 'quote bound as text'
  $r=Read-Store ([pscustomobject]@{Kind='Directory';Term='100%';Limit=50;Projection='List'})
  Expect ($r.Total -eq 1 -and $r.Rows[0].Name -ceq 'PC-100%') 'percent is not a wildcard'
  Expect (($r.SqlStats.Executed -ge 3) -and ($r.SqlStats.Prepared -ge 1) -and ($r.SqlStats.SqlMs -ge 0)) 'reads are measured'
  $r=Read-Store ([pscustomobject]@{Kind='Observation';Guids=@($guid);Family="Presence' OR '1'='1"})
  Expect ($r.Observations.Count -eq 0) 'family is a value, never SQL'
 }
 Case 'Point 39: detail filters are bound after the GUID slots and keep only the requested result' {
  $id='00000000-0000-0000-0000-000000000395'
  $kinds=@(@('WmiExplorer',"win32_o'neil"),@('WmiExplorer','win32_bios'),@('Registry',"win32_o'neil"))
  [void](Commit @(foreach($pair in $kinds){[pscustomobject]@{Kind='DetailResult';Guid=$id;DN='CN=PC-D,OU=Parc,DC=test';ResultKind=$pair[0];RequestKey=$pair[1];AttemptedAtUtc=$at;ObservedAtUtc=$at;Status='Success';Data=[pscustomobject]@{Key=$pair[1]}}}))
  $both=Read-Store ([pscustomobject]@{Kind='Detail';Guids=@($id);ResultKind='WmiExplorer';RequestKey="win32_o'neil"})
  Expect (($both.Total -eq 1) -and (@($both.Details).Count -eq 1) -and ($both.Details[0].ResultKind -ceq 'WmiExplorer') -and ($both.Details[0].RequestKey -ceq "win32_o'neil")) 'quote in a bound request key'
  $kind=Read-Store ([pscustomobject]@{Kind='Detail';Guids=@($id);ResultKind='WmiExplorer'})
  Expect ((@($kind.Details|ForEach-Object{$_.RequestKey}|Sort-Object) -join ',') -ceq "win32_bios,win32_o'neil") 'result kind alone'
  $key=Read-Store ([pscustomobject]@{Kind='Detail';Guids=@($id);RequestKey="win32_o'neil"})
  Expect ((@($key.Details|ForEach-Object{$_.ResultKind}|Sort-Object) -join ',') -ceq 'Registry,WmiExplorer') 'request key alone'
  $none=Read-Store ([pscustomobject]@{Kind='Detail';Guids=@($id);ResultKind="WmiExplorer' OR '1'='1"})
  Expect (($none.Total -eq 0) -and (@($none.Details).Count -eq 0)) 'a result kind is a value, never SQL'
  $all=Read-Store ([pscustomobject]@{Kind='Detail';Guids=@($id)})
  Expect (@($all.Details).Count -eq 3) 'no filter, every detail of the page'
 }
 Case 'Point 39: slices of up to 32 GUIDs reuse one prepared statement with the same rows as a literal page' {
  $ids=@(1..40|ForEach-Object{'00000000-0000-0000-0000-0000000004'+$_.ToString('00')})
  [void](Commit @($ids|ForEach-Object{Directory $_ ('SLOT-'+$_.Substring(34))}))
  $all=Read-Store ([pscustomobject]@{Kind='Directory';Guids=$ids;Limit=100;Projection='List'})
  $first=Read-Store ([pscustomobject]@{Kind='Directory';Guids=@($ids[0..19]);Limit=100;Projection='List'})
  $second=Read-Store ([pscustomobject]@{Kind='Directory';Guids=@($ids[20..39]);Limit=100;Projection='List'})
  Expect ($all.Rows.Count -eq 40) 'literal page of 40'
  Expect (((@($first.Rows)+@($second.Rows)|ForEach-Object{$_.Guid}|Sort-Object) -join ',') -ceq ((@($all.Rows)|ForEach-Object{$_.Guid}|Sort-Object) -join ',')) 'bound slices return the same rows'
  $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;BusyTimeoutMs=1000}
  $db=[IntPtr]::Zero;$ptr=New-DomeniaUtf8Ptr $path;try{[void][Domenia.WinSqliteNative]::sqlite3_open_v2($ptr,[ref]$db,1,[IntPtr]::Zero)}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)}
  try{
   $functions=[Management.Automation.Language.Parser]::ParseInput($reader,[ref]$t,[ref]$e)
   foreach($fn in @($functions.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -in @('Get-IdxWLiteral','Invoke-IdxWQuery','Get-IdxWGuidSlots','Get-IdxWStatsSnapshot'))},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
   $IdxWStats=[pscustomobject]@{Prepared=0;Reused=0;Executed=0;Rows=0L;SqlMs=[double]0};$IdxWStatements=@{};$IdxWColumns=@{}
   foreach($slice in @(@($ids[0..31]),@($ids[32..39]))){$slots=Get-IdxWGuidSlots $slice;[void](Invoke-IdxWQuery $db ('SELECT object_guid FROM ad_objects WHERE object_guid IN ('+$slots.Sql+');') -Parameters $slots.Parameters -Cached:([bool]$slots.Cached))}
   Expect (($IdxWStats.Prepared -eq 1) -and ($IdxWStats.Reused -eq 1) -and ($IdxWStats.Rows -eq 40)) 'one statement for both slices, NULL padding matches nothing'
   $wrong=$false;try{[void](Invoke-IdxWQuery $db 'SELECT ?1 AS v;' -Parameters @('a','b'))}catch{$wrong=$true};Expect $wrong 'parameter count must match'
   # One binding rule with the prepared writes of LocalStore (PF-07): UTF-16 text of exact length, booleans and integral
   # numbers as INTEGER, other numbers as REAL, $null as NULL.
   $text='Été ʼ'+[char]::ConvertFromUtf32(0x1D11E)+' x''y'
   $echo=@(Invoke-IdxWQuery $db 'SELECT ?1 AS t,typeof(?1) AS tt,?2 AS b,typeof(?2) AS bt,?3 AS d,typeof(?3) AS dt,?4 AS i,typeof(?4) AS it,?5 AS w,typeof(?5) AS wt,typeof(?6) AS nt;' -Parameters @($text,$true,1.5,[long]42,[double]7,$null))
   Expect (($echo.Count -eq 1) -and ([string]$echo[0].t -ceq $text) -and ([string]$echo[0].tt -ceq 'text')) 'text bound as exact UTF-16'
   Expect (([long]$echo[0].b -eq 1) -and ([string]$echo[0].bt -ceq 'integer') -and ([double]$echo[0].d -eq 1.5) -and ([string]$echo[0].dt -ceq 'real')) 'boolean and real bound like LocalStore'
   Expect (([long]$echo[0].i -eq 42) -and ([string]$echo[0].it -ceq 'integer') -and ([long]$echo[0].w -eq 7) -and ([string]$echo[0].wt -ceq 'integer') -and ([string]$echo[0].nt -ceq 'null')) 'integers and NULL bound like LocalStore'
  }finally{foreach($cached in @($IdxWStatements.Values)){[void][Domenia.WinSqliteNative]::sqlite3_finalize([IntPtr]$cached)};[void][Domenia.WinSqliteNative]::sqlite3_close($db)}
 }
 # Points 4, 5 and 10: scope clocks of the explicit OU collections (domenia_domain_metadata).
 Case 'Scope clocks keep the last success beside a newer failed attempt and read back from SQLite' {
  . (Join-Path $wad 'modules/Domenia-Common.Model.ps1');. (Join-Path $wad 'modules/Domenia-Collection.Model.ps1')
  $scope='OU=Parc,DC=test'
  $ok=New-DomeniaCollectionRunChange -Family Presence -DomainDn 'dc=test' -ScopeDn $scope -Status Success -AttemptedAtUtc '2026-01-03T08:00:00Z' -FinishedAtUtc '2026-01-03T08:05:00Z' -Targets 4 -Done 4 -Succeeded 4 -Failed 0 -CollectorVersion 'fixture-build'
  $r=Commit @($ok);Expect (($r.Saved) -and (@($r.CollectionRuns).Count -eq 1)) 'run receipt read back'
  $run=@($r.CollectionRuns)[0]
  Expect (($run.Status -eq 'Success') -and ($run.LastSuccessAtUtc -eq $run.LastAttemptAtUtc) -and ([string]$run.Data.RecordedAtUtc -eq [string]$r.CommittedAtUtc) -and ($null -eq $run.AttemptData)) 'success clock and recorded time'
  Expect (([string]$run.Data.CollectorVersion -eq 'fixture-build') -and ([string]$run.Data.Provider -eq 'ICMP') -and ([long]$run.Data.Done -eq 4)) 'provenance kept'
  $bad=New-DomeniaCollectionRunChange -Family Presence -DomainDn 'dc=test' -ScopeDn $scope -Status Error -AttemptedAtUtc '2026-01-03T09:00:00Z' -FinishedAtUtc '2026-01-03T09:01:00Z' -ErrorText 'Identifiants refuses'
  $r=Commit @($bad);$run=@($r.CollectionRuns)[0]
  Expect (($run.Status -eq 'Error') -and ($run.Error -eq 'Identifiants refuses') -and ($run.LastSuccessAtUtc -like '2026-01-03T08:00:00*') -and ([long]$run.Data.Done -eq 4) -and ([string]$run.AttemptData.StartedAtUtc -like '2026-01-03T09:00:00*')) 'failure kept beside the success'
  $late=New-DomeniaCollectionRunChange -Family Presence -DomainDn 'dc=test' -ScopeDn $scope -Status Success -AttemptedAtUtc '2026-01-03T07:00:00Z' -FinishedAtUtc '2026-01-03T07:01:00Z' -Done 1
  $r=Commit @($late);$run=@($r.CollectionRuns)[0]
  Expect (($run.Status -eq 'Error') -and ($run.LastSuccessAtUtc -like '2026-01-03T08:00:00*') -and ([long]$run.Data.Done -eq 4)) 'late older success cannot hide the newer state'
  $clock=Get-DomeniaCollectionClock -Runs @($r.CollectionRuns) -Family Presence -ScopeDn $scope -DomainDn 'DC=test' -NowUtc ([datetime]::UtcNow)
  Expect (($clock.State -eq 'SuccessThenFailure') -and ($clock.Success.AtUtc.Hour -eq 8) -and ($clock.Attempt.Error -eq 'Identifiants refuses')) 'model reads the committed receipt'
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_domain_metadata WHERE family='Presence';")[0].n -eq 1) 'one row per scope and family'
 }
 Case 'StoreRead dates each measure with the commit of the batch that wrote it' {
  $id='00000000-0000-0000-0000-000000000097';$c=Directory $id 'Recorded-1';[void](Commit @($c))
  $o=Observation Presence '2026-01-05T08:00:00Z';$o.Guid=$id;$o.DN=$c.DN;$r=Commit @($o)
  $read=Read-Store ([pscustomobject]@{Kind='Observation';Guids=@($id);Family='Presence';Limit=1})
  $row=@($read.Observations)[0]
  Expect (([string]$row.RecordedAtUtc -eq [string]$r.CommittedAtUtc) -and ([string]$row.LastSuccessAtUtc -like '2026-01-05T08:00:00*')) 'recorded time of the measure'
 }
 Case 'Scope clock admission refuses forged keys, foreign scopes and errors on success without writes' {
  . (Join-Path $wad 'modules/Domenia-Common.Model.ps1');. (Join-Path $wad 'modules/Domenia-Collection.Model.ps1')
  $before=(Read-TestDb 'SELECT count(*) n FROM domenia_domain_metadata;')[0].n
  $data=[pscustomobject]@{Format='Domenia.CollectionRun/1';Family='Inventory';ScopeDn='OU=Parc,DC=test';Subtree=$true;Provider='CIM/DCOM'}
  $base=@{Kind='CollectionRun';Family='Inventory';DomainDn='dc=test';ScopeDn='OU=Parc,DC=test';Subtree=$true;RequestKey='subtree:ou=parc,dc=test';Status='Success';AttemptedAtUtc='2026-01-04T08:00:00Z';FinishedAtUtc='2026-01-04T08:00:00Z';Error='';Data=$data}
  foreach($variant in @(@{RequestKey='subtree:ou=autre,dc=test'},@{RequestKey='onelevel:ou=parc,dc=test'},@{ScopeDn='OU=X,DC=other';RequestKey='subtree:ou=x,dc=other'},@{Error='refus'},@{Status='Error'},@{FinishedAtUtc='2026-01-04T07:00:00Z'},@{AttemptedAtUtc='2099-01-01T00:00:00Z';FinishedAtUtc='2099-01-01T00:00:00Z'},@{Family='Console'})){
   $change=@{};foreach($k in $base.Keys){$change[$k]=$base[$k]};foreach($k in $variant.Keys){$change[$k]=$variant[$k]}
   $refused=$false;try{[void](Commit @([pscustomobject]$change))}catch{$refused=$true}
   Expect $refused ('forged run admitted: '+(($variant.Keys|ForEach-Object{$_+'='+$variant[$_]}) -join ','))
  }
  Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_domain_metadata;')[0].n -eq $before) 'refused runs wrote rows'
 }
 Case 'FleetStats reads only the requested scope clocks inside its snapshot and dates the board with them' {
  Add-Type -Path (Join-Path $wad 'modules/Domenia.Native.dll')
  foreach($name in @('Common.Model','Collection.Model','Boards.Model','BoardFleet.Model','Probes.Model','HealthRules.Model')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
  $now=[datetime]::UtcNow;$scope='OU=Parc,DC=test'
  $other=New-DomeniaCollectionRunChange -Family Presence -DomainDn 'dc=test' -ScopeDn 'OU=Autre,DC=test' -Status Success -AttemptedAtUtc $now.AddMinutes(-5) -FinishedAtUtc $now.AddMinutes(-4) -Done 9
  [void](Commit @($other))
  $keys=@(Get-DomeniaCollectionRunKeys -ScopeDn $scope -DomainDn 'DC=test' -Subtree $true)
  $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;ModuleRoot=(Join-Path $wad 'modules');BusyTimeoutMs=1000;Scope=$scope;Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey=$scope;DomainDn='DC=test';RunKeys=$keys;ComputeBoard=$true;ObservationMaxAgeDays=30}
  $r=& ([scriptblock]::Create($reader))
  Expect ((@($r.CollectionRuns).Count -eq 1) -and ([string]@($r.CollectionRuns)[0].RequestKey -eq 'subtree:ou=parc,dc=test')) 'scope filter of collection runs'
  $runs=$r.Board.Freshness.Runs
  Expect (($runs.Presence.State -eq 'SuccessThenFailure') -and ($runs.Presence.Success.AtUtc.Hour -eq 8) -and ($runs.Inventory.State -eq 'NeverRecorded')) 'board clocks from the snapshot'
  $text=Format-DomeniaOuFreshnessSummary -IndexFreshness $r.Board.Freshness.Index -Observations $r.Board.Freshness.Observations -ComputedAtUtc $r.Board.Freshness.ComputedAtUtc -Runs $runs
  Expect (($text.RunsText -like '*ping relevé réussi le *dernière tentative le *Identifiants refuses*') -and ($text.RunsDetail -like '*version de collecte fixture-build*')) 'three clocks text and provenance'
  $Payload.PSObject.Properties.Remove('RunKeys');$plain=& ([scriptblock]::Create($reader))
  Expect (($null -eq $plain.CollectionRuns) -and ($null -eq $plain.Board.Freshness.Runs)) 'clocks read or invented without an explicit scope request'
  Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_domain_metadata;')[0].n -eq 2) 'read-only worker changed scope clocks'
 }
 Case 'Secret metadata recorded before the computer now holding the name stays unknown (point 9)' {
  Add-Type -Path (Join-Path $wad 'modules/Domenia.Native.dll')
  foreach($name in @('Common.Model','Relations.Model','Boards.Model','BoardFleet.Model','Probes.Model','HealthRules.Model')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
  $now=[datetime]::UtcNow;$scope='OU=SecretFixture,DC=test';$stamp=$now.AddMinutes(-1).ToString('o')
  $recycled='30000000-0000-0000-0000-000000000001';$kept='30000000-0000-0000-0000-000000000002'
  $changes=@(foreach($fixture in @(@($recycled,'Recycled-1','2026-02-01T00:00:00Z'),@($kept,'Kept-1','2025-06-01T00:00:00Z'))){
   $c=Directory $fixture[0] $fixture[1] $stamp;$c.DN='CN='+$fixture[1]+','+$scope;$c.Facts.WhenCreated=$fixture[2];$c
  })
  [void](Commit $changes)
  # Same read date for both names: before the creation of RECYCLED-1 (former holder), after the creation of KEPT-1.
  $db=Open-DomeniaDatabase $path
  try{
   foreach($row in @(@('RECYCLED-1','Recycled-1',2),@('KEPT-1','Kept-1',1))){
    [void](Invoke-DomeniaDbExec ("INSERT OR REPLACE INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail) VALUES('"+$row[0]+"','"+$row[1]+"','2026-01-15T00:00:00.0000000Z',"+$row[2]+",'','','','','');") $db)
   }
  }finally{Close-DomeniaDatabase $db}
  $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;ModuleRoot=(Join-Path $wad 'modules');BusyTimeoutMs=1000;Scope=$scope;Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey=$scope;DomainDn='dc=test'}
  $r=& ([scriptblock]::Create($reader))
  $bitlocker=@{};foreach($group in @($r.Groups)){$bitlocker[[string]$group.gid]=[string]$group.bk}
  $byName=@{};foreach($machine in @($r.Machines)){$byName[[string]$machine.name]=$bitlocker[[string]$machine.gid]}
  Expect (($byName['Recycled-1'] -ceq 'U') -and ($byName['Kept-1'] -ceq 'K')) ('BitLocker state by name: '+((@($byName.Keys)|Sort-Object|ForEach-Object{$_+'='+$byName[$_]}) -join ','))
  Expect ($r.Coverage.BitLockerRead -eq 1) ('metadata of a former holder counted as read: '+$r.Coverage.BitLockerRead)
  # Same rule on the fiche, read off the Dispatcher (FI-19): LocalIndexRead SecretIndexEntry reads the creation date by
  # the GUID of the displayed computer and Complete-DomeniaSecretIndexSummaryUi applies Test-DomeniaRecordPredatesObject.
  $secret={param([string]$Computer,[string]$Guid)
   $Payload=[pscustomobject]@{Action='SecretIndexEntry';Path=$path;BusyTimeoutMs=1000;Computer=$Computer}
   if($Guid){$Payload|Add-Member -NotePropertyName Guid -NotePropertyValue $Guid}
   & ([scriptblock]::Create($reader))
  }
  $hidden={param($Answer) return ((@($Answer.Rows).Count -eq 1) -and (Test-DomeniaRecordPredatesObject -RecordedUtc ([string]@($Answer.Rows)[0].checked_at) -CreatedUtc ([string]$Answer.CreatedUtc)))}
  $former=& $secret 'Recycled-1' $recycled
  Expect (([string]$former.CreatedUtc) -and (& $hidden $former)) ('metadata of a former holder shown on the fiche: '+[string]$former.CreatedUtc)
  $shown=& $secret 'Kept-1' $kept.ToUpperInvariant()
  Expect (([string]$shown.CreatedUtc) -and (-not (& $hidden $shown)) -and ([int]@($shown.Rows)[0].bitlocker_keys -eq 1)) 'metadata of the current holder hidden'
  $unproven=& $secret 'Recycled-1' ''
  Expect ((-not [string]$unproven.CreatedUtc) -and (-not (& $hidden $unproven)) -and ([int]@($unproven.Rows)[0].bitlocker_keys -eq 2)) 'without the GUID nothing is proven, so nothing is hidden'
  $refused=$false;try{[void](& $secret 'Kept-1' "x' OR 1=1 --")}catch{$refused=$true}
  Expect $refused 'malformed GUID read'
 }
 Case 'Explicit purge removes the scope clocks of the purged families only' {
  . (Join-Path $wad 'modules/Domenia-Common.Model.ps1');. (Join-Path $wad 'modules/Domenia-Collection.Model.ps1')
  $now=[datetime]::UtcNow
  [void](Commit @(foreach($family in @('Directory','Inventory')){New-DomeniaCollectionRunChange -Family $family -DomainDn 'dc=test' -ScopeDn 'OU=Parc,DC=test' -Status Success -AttemptedAtUtc $now.AddMinutes(-3) -FinishedAtUtc $now.AddMinutes(-2) -Done 3}))
  $count={param([string]$Where) [long](Read-TestDb ('SELECT count(*) n FROM domenia_domain_metadata WHERE '+$Where+';'))[0].n}
  Expect (((& $count "family IN ('Presence','Inventory')") -ge 2) -and ((& $count "family='Directory'") -eq 1)) 'scope clock fixture'
  foreach($category in @('Observations','Index')){
   $Payload=[pscustomobject]@{Path=$path;Selection=@($category);DryRun=$true};$preview=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))
   $planned=@($preview.Counts|Where-Object{$_.Table -eq 'domenia_domain_metadata'})
   Expect (($planned.Count -eq 1) -and ([long]$planned[0].Rows -ge 1)) ('scope clocks absent from the dry run: '+$category)
   $Payload=[pscustomobject]@{Path=$path;Selection=@($category);DryRun=$false;ExpectedFingerprint=$preview.Fingerprint};$result=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))
   Expect ($result.Committed) ('purge not committed: '+$category)
   if($category -eq 'Observations'){Expect (((& $count "family IN ('Presence','Inventory')") -eq 0) -and ((& $count "family='Directory'") -eq 1)) 'measure purge must remove the ping and WMI clocks and keep the AD clock'}
   else{Expect ((& $count '1=1') -eq 0) 'index purge must remove the AD clock'}
  }
 }
 # P-CD-08: one SQLite layer (Get-DomeniaSqliteWorkerCommon) composed by every worker of the local base, never copied.
 Case 'P-CD-08: every worker of the local base composes the one SQLite layer exactly once, without a copy' {
  foreach($module in @('Live.Model','AdAudit.Worker','Migration.Worker')){. (Join-Path $wad ('modules/Domenia-'+$module+'.ps1'))}
  $layer=Get-DomeniaSqliteWorkerCommon;$tokens=$null;$errors=$null
  $layerAst=[Management.Automation.Language.Parser]::ParseInput($layer,[ref]$tokens,[ref]$errors)
  Expect (@($errors).Count -eq 0) 'shared layer parses'
  $names=@($layerAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|ForEach-Object{$_.Name})
  foreach($name in @('Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbExec','Invoke-DomeniaDbQuery','Invoke-DomeniaSqliteRead','Set-DomeniaSqliteBindings','New-StoreWStatement','Test-DomeniaSqliteSchemaRows')){Expect ($names -ccontains $name) ('shared layer without '+$name)}
  $generators=[ordered]@{LocalStore='Get-DomeniaStorageWorkerCode';StorageUsage='Get-DomeniaStorageUsageWorkerCode';StoragePurge='Get-DomeniaStoragePurgeWorkerCode';StorageBackup='Get-DomeniaStorageBackupWorkerCode';StorageMaintenance='Get-DomeniaStorageMaintenanceWorkerCode';StorageRetention='Get-DomeniaStorageRetentionWorkerCode';StorageIntegrity='Get-DomeniaStorageIntegrityWorkerCode';LiveCache='Get-DomeniaLiveCacheCode';LegacyMigration='Get-DomeniaMigrationWorkerCode';LocalIndexRead='Get-DomeniaLocalIndexReadWorkerCode';RelationHistoryRead='Get-DomeniaRelationHistoryReadWorkerCode'}
  foreach($operation in @($generators.Keys)){
   $code=& $generators[$operation]
   $first=$code.IndexOf($layer,[StringComparison]::Ordinal)
   Expect (($first -ge 0) -and ($first -eq $code.LastIndexOf($layer,[StringComparison]::Ordinal))) ('shared layer not composed exactly once: '+$operation)
   $ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
   Expect (@($errors).Count -eq 0) ('worker does not parse: '+$operation)
   foreach($name in $names){
    $count=@($ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $name)},$true)).Count
    Expect ($count -eq 1) ($operation+' defines '+$name+' '+$count+' time(s)')
   }
  }
 }
 Case 'P-CD-08: the shared open creates a base only when allowed; the shared read keeps parameters, cache and BUSY marker' {
  $missing=Join-Path $folder ('absent-'+[guid]::NewGuid().ToString('N')+'.db');$refused=$false
  try{$db=Open-DomeniaDatabase -Path $missing -NoCreate;Close-DomeniaDatabase $db}catch{$refused=$true}
  Expect ($refused -and (-not [IO.File]::Exists($missing))) 'an open with -NoCreate created a base'
  $db=Open-DomeniaDatabase -Path $missing
  try{Expect ([IO.File]::Exists($missing)) 'the default open (writer) did not create the base'}finally{Close-DomeniaDatabase $db}
  $db=Open-DomeniaDatabase -Path $missing -ReadOnly -BusyTimeoutMs 50
  try{
   $echo=@(Invoke-DomeniaSqliteRead -Db $db -Sql 'SELECT ?1 AS t,typeof(?2) AS n;' -Parameters @('Été ʼx''y',$null) -CheckParameters)
   Expect (($echo.Count -eq 1) -and ([string]$echo[0].t -ceq 'Été ʼx''y') -and ([string]$echo[0].n -ceq 'null')) 'bound text and NULL'
   $wrong=$false;try{[void](Invoke-DomeniaSqliteRead -Db $db -Sql 'SELECT ?1 AS v;' -CheckParameters)}catch{$wrong=($_.Exception.Message -like 'Parametres SQL incoherents*')}
   Expect $wrong 'a missing parameter must be refused when the caller checks them'
   # Without -CheckParameters an unbound parameter reads as NULL, as Invoke-DomeniaDbQuery always did.
   Expect ($null -eq @(Invoke-DomeniaSqliteRead -Db $db -Sql 'SELECT ?1 AS v;')[0].v) 'unbound parameter must read NULL'
   $stats=[pscustomobject]@{Prepared=0;Reused=0;Executed=0;Rows=0L;SqlMs=[double]0};$cache=@{}
   foreach($value in @(1,2)){[void](Invoke-DomeniaSqliteRead -Db $db -Sql 'SELECT ?1 AS v;' -Parameters @($value) -Cache $cache -Stats $stats -CheckParameters)}
   Expect (($stats.Prepared -eq 1) -and ($stats.Reused -eq 1) -and ($stats.Executed -eq 2) -and ($stats.Rows -eq 2) -and ($cache.Count -eq 1)) 'one cached statement for both reads'
  }finally{foreach($handle in @($cache.Values)){[void][Domenia.WinSqliteNative]::sqlite3_finalize([IntPtr]$handle)};Close-DomeniaDatabase $db}
  $writerDb=Open-DomeniaDatabase -Path $missing;$readerDb=[IntPtr]::Zero
  try{
   [void](Invoke-DomeniaDbExec 'PRAGMA journal_mode=DELETE;CREATE TABLE IF NOT EXISTS t(v INTEGER);BEGIN EXCLUSIVE;INSERT INTO t(v) VALUES(1);' $writerDb)
   $readerDb=Open-DomeniaDatabase -Path $missing -ReadOnly -BusyTimeoutMs 50
   $marker='';try{[void](Invoke-DomeniaSqliteRead -Db $readerDb -Sql 'SELECT count(*) AS n FROM t;' -ReportBusy)}catch{$marker=$_.Exception.Message}
   Expect ($marker -ceq 'SQLITE_BUSY') ('locked base read without the BUSY marker: '+$marker)
   $plain='';try{[void](Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM t;' $readerDb)}catch{$plain=$_.Exception.Message}
   Expect ($plain -match '^SQLite (?:prepare |step )?code 5 ') ('locked base read without the SQLite code: '+$plain)
  }finally{if($readerDb -ne [IntPtr]::Zero){Close-DomeniaDatabase $readerDb};try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $writerDb)}finally{Close-DomeniaDatabase $writerDb}}
 }
 Case 'P-CD-08: the schema of this version (11/1) comes from one constant of the shared layer' {
  $target=Get-DomeniaSqliteSchemaTarget
  Expect (($target.SchemaVersion -ceq '11') -and ($target.DomeniaSchema -ceq '1') -and ($target.Label -ceq '11/1')) 'schema target'
  $row={param([string]$Key,[string]$Value) [pscustomobject]@{key=$Key;value=$Value}}
  Expect (Test-DomeniaSqliteSchemaRows @((& $row 'schema_version' '11'),(& $row 'domenia_schema' '1'))) 'current schema refused'
  Expect (-not (Test-DomeniaSqliteSchemaRows @((& $row 'schema_version' '12'),(& $row 'domenia_schema' '1')))) 'newer schema accepted'
  Expect (-not (Test-DomeniaSqliteSchemaRows @((& $row 'schema_version' '11'),(& $row 'domenia_schema' '2')))) 'newer revision accepted'
  Expect (-not (Test-DomeniaSqliteSchemaRows @((& $row 'schema_version' '11')))) 'missing revision accepted'
  Expect (-not (Test-DomeniaSqliteSchemaRows @((& $row 'schema_version' '11'),(& $row 'schema_version' '11'),(& $row 'domenia_schema' '1')))) 'duplicate version accepted'
  Expect (-not (Test-DomeniaSqliteSchemaRows @())) 'empty schema accepted'
  Expect (Test-DomeniaSqliteSchemaRows @(Read-TestDb "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');")) 'the schema script of the core is not this version'
 }
 # P-CD-08: the stored history (point 107) runs its rewritten body on the shared layer against a real base: one user
 # or one workstation, any case, most recent first, key bound as a SQL literal, Busy without rows under a writer lock.
 Case 'P-CD-08: RelationHistoryRead reads one user or one workstation on the shared layer and answers Busy under a lock' {
  . (Join-Path $wad 'modules/Domenia-AdAudit.Worker.ps1')
  $code=Get-DomeniaRelationHistoryReadWorkerCode
  $history=Join-Path $folder ('history-'+[guid]::NewGuid().ToString('N')+'.db')
  $read={param([string]$Kind,[string]$Key,[int]$Limit,[string]$Base=$history)
   $Payload=[pscustomobject]@{Kind=$Kind;Key=$Key;Limit=$Limit;Path=$Base;BusyTimeoutMs=50}
   return (& ([scriptblock]::Create($code)))
  }
  # The schema script of the core, then the rollback journal: an exclusive writer then really keeps a reader out.
  $db=Open-DomeniaDatabase $history
  try{
   [void](Invoke-DomeniaDbExec $schemaSql $db);[void](Invoke-DomeniaDbExec 'PRAGMA journal_mode=DELETE;' $db)
   foreach($row in @(@('o''brien','PC-01','2026-01-01T08:00:00Z'),@('O''Brien','PC-02','2026-01-03T08:00:00Z'),@('jdupont','PC-01','2026-01-02T08:00:00Z'),@('o''brien','PC-03','2026-01-02T08:00:00Z'))){
    [void](Invoke-DomeniaSqliteRead -Db $db -Sql 'INSERT INTO user_machine_history(user_login,computer_key,computer,source,verified_in_ad,observed_at) VALUES(?1,?2,?2,''Test'',1,?3);' -Parameters $row -CheckParameters)
   }
  }finally{Close-DomeniaDatabase $db}
  $user=& $read 'User' 'O''BRIEN' 2
  Expect ((-not $user.Busy) -and (-not $user.Missing) -and ($user.Total -eq 3) -and (@($user.Rows).Count -eq 2)) 'user history: every case of the login counted, Limit rows returned'
  Expect (([string]$user.Rows[0].computer_key -ceq 'PC-02') -and ([string]$user.Rows[1].computer_key -ceq 'PC-03')) 'user history: most recent first'
  $computer=& $read 'Computer' 'pc-01' 10
  Expect ((-not $computer.Busy) -and ($computer.Total -eq 2) -and (@($computer.Rows).Count -eq 2)) 'workstation history: any case of the key'
  Expect (([string]$computer.Rows[0].user_login -ceq 'jdupont') -and ([string]$computer.Rows[1].user_login -ceq 'o''brien')) 'workstation history: most recent first, apostrophe kept'
  $quoted=& $read 'User' 'x'' OR 1=1 --' 10
  Expect ((-not $quoted.Busy) -and ($quoted.Total -eq 0) -and (@($quoted.Rows).Count -eq 0)) 'a quote in the key stays inside the SQL literal'
  $writer=Open-DomeniaDatabase $history
  try{
   [void](Invoke-DomeniaDbExec 'BEGIN EXCLUSIVE;' $writer)
   $busy=& $read 'User' 'jdupont' 10
   Expect ($busy.Busy -and (-not $busy.Missing) -and ($busy.Total -eq 0) -and (@($busy.Rows).Count -eq 0)) 'locked base: Busy without rows'
  }finally{try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $writer)}finally{Close-DomeniaDatabase $writer}}
  $empty=Join-Path $folder ('history-empty-'+[guid]::NewGuid().ToString('N')+'.db')
  $db=Open-DomeniaDatabase $empty
  try{[void](Invoke-DomeniaDbExec 'CREATE TABLE other(v INTEGER);' $db)}finally{Close-DomeniaDatabase $db}
  $none=& $read 'User' 'jdupont' 10 $empty
  Expect ($none.Missing -and (-not $none.Busy) -and (@($none.Rows).Count -eq 0)) 'base without the history table: Missing, no row invented'
 }
 if($Scale){Case ($ScaleObjects.ToString()+' objects committed in bounded batches and paginated exactly') {
  $watch=[Diagnostics.Stopwatch]::StartNew();$writeWatch=[Diagnostics.Stopwatch]::StartNew();$batchTimes=[Collections.Generic.List[long]]::new()
  for($page=0;$page -lt ($ScaleObjects/250);$page++){$changes=@(for($n=1;$n -le 250;$n++){$index=$page*250+$n;Directory ('10000000-0000-0000-0000-'+$index.ToString('000000000000')) ('Scale-'+$index.ToString('00000'))});$bw=[Diagnostics.Stopwatch]::StartNew();$r=Commit $changes;$bw.Stop();$batchTimes.Add($bw.ElapsedMilliseconds);Expect ($r.Rows.Count -eq 250) 'batch count'}
  $writeWatch.Stop();$readWatch=[Diagnostics.Stopwatch]::StartNew();$seen=[Collections.Generic.HashSet[string]]::new();$pageTimes=[Collections.Generic.List[long]]::new()
  for($offset=0;$offset -lt $ScaleObjects;$offset+=250){$rw=[Diagnostics.Stopwatch]::StartNew();$r=Read-Store ([pscustomobject]@{Kind='Directory';ScopeDn='OU=Parc,DC=test';Subtree=$true;Term='scale-';Limit=250;Offset=$offset;Projection='List'});$rw.Stop();$pageTimes.Add($rw.ElapsedMilliseconds);Expect ($r.Total -eq $ScaleObjects -and $r.Rows.Count -eq 250) 'exact page count';foreach($row in $r.Rows){Expect ($seen.Add([string]$row.Guid)) 'unique paged GUID'}}
  Expect ($seen.Count -eq $ScaleObjects) 'all rows recovered';$readWatch.Stop();$watch.Stop();$script:scaleMs=$watch.ElapsedMilliseconds
  $script:scaleMetrics=[pscustomobject]@{WriteMs=$writeWatch.ElapsedMilliseconds;ReadMs=$readWatch.ElapsedMilliseconds;BatchMs=$batchTimes.ToArray();PageMs=$pageTimes.ToArray();DatabaseBytes=([IO.FileInfo]::new($path).Length);ProcessWorkingSetBytes=[Diagnostics.Process]::GetCurrentProcess().WorkingSet64}
 }}
}finally{if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder,$true)}}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='DomeniaStore';Passed=($failed -eq 0);Total=$cases.Count;Failed=$failed;Assertions=$script:checks;SQLiteVersion=$script:sqliteVersion;Platform=[Environment]::OSVersion.ToString();ScaleObjects=$(if($Scale){$ScaleObjects}else{0});ScaleDurationMs=$script:scaleMs;ScaleMetrics=$script:scaleMetrics;Limitations='Disposable SQLite only; no AD, no remote host, no WPF; non-Windows ABI does not qualify winsqlite3. WorkingSet is a process snapshot, not a measured peak.';Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
Write-Output ('Store: '+($cases.Count-$failed)+'/'+$cases.Count+' cases, '+$script:checks+' assertions')
if($failed){exit 1};exit 0
