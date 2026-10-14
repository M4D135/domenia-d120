#requires -Version 5.1
param([string]$ReportPath='',[switch]$Scale,[ValidateSet(5000,10000,20000)][int]$ScaleObjects=20000)
$ErrorActionPreference='Stop'
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
 $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schema[0].Value $db);$script:sqliteVersion=[string](@(Invoke-DomeniaDbQuery 'SELECT sqlite_version() AS v;' $db)[0].v)}finally{Close-DomeniaDatabase $db}
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
