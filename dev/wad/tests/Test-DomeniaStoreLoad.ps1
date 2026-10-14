#requires -Version 5.1
param([string]$ReportPath='',[ValidateSet(10000,20000)][int]$Objects=20000,[ValidateRange(1,78)][int]$ProbeCount=4)
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
$sourceHashes=@{};foreach($name in @('Domenia-Store.Model.ps1','Domenia-Storage.Worker.ps1','Domenia-Engine.Worker.ps1')){$sourceHashes[$name]=(Get-FileHash (Join-Path $wad ('modules/'+$name)) -Algorithm SHA256).Hash}
$executedWorkerHash=Get-DomeniaStoreHash $worker;$executedReaderHash=Get-DomeniaStoreHash $reader
$ast=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$t,[ref]$e)
if($e.Count){throw 'Worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-store-load-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder);$path=Join-Path $folder 'test.sqlite'
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
 $db=Open-DomeniaDatabase $path
 try{
  [void](Invoke-DomeniaDbExec $schema[0].Value $db)
  $script:sqliteVersion=[string](@(Invoke-DomeniaDbQuery 'SELECT sqlite_version() AS v;' $db)[0].v)
  [void](Invoke-DomeniaDbExec ('INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,'+(ConvertTo-DomeniaSqlLiteral $context.StoreId)+",'dc=test',1);CREATE TABLE IF NOT EXISTS domenia_legacy_observation_imports(object_guid TEXT PRIMARY KEY,payload_hash TEXT NOT NULL,imported_at TEXT NOT NULL);CREATE TABLE IF NOT EXISTS park_session_cache(object_key TEXT PRIMARY KEY,checked_utc TEXT NOT NULL,payload TEXT NOT NULL);") $db)
 }finally{Close-DomeniaDatabase $db}
 $stamp=[datetime]::UtcNow.AddMinutes(-5).ToString('o');$fresh=[datetime]::UtcNow.AddMinutes(-1).ToString('o')
 Case 'Representative fixture seeded outside measured production write path' {
  $db=Open-DomeniaDatabase $path
  try{
   for($offset=0;$offset -lt $Objects;$offset+=250){
    $sql=[Text.StringBuilder]::new();[void]$sql.AppendLine('BEGIN IMMEDIATE;')
    for($n=1;$n -le 250;$n++){
     $index=$offset+$n;$id='10000000-0000-0000-0000-'+$index.ToString('000000000000');$name='Load-'+$index.ToString('00000');$dn='CN='+$name+',OU=Parc,DC=test'
     $v=@($id,$id,'Machine',$name,'Actif',$dn,$name.ToLowerInvariant(),$stamp)
     [void]$sql.AppendLine('INSERT INTO ad_objects(object_key,object_guid,object_type,name,state,distinguished_name,search_key,synced_at) VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
     [void]$sql.AppendLine("INSERT INTO domenia_legacy_observation_imports(object_guid,payload_hash,imported_at) VALUES('$id','',"+(ConvertTo-DomeniaSqlLiteral $stamp)+');')
     $families=[ordered]@{Presence=[pscustomobject]@{Presence='En ligne'};Inventory=[pscustomobject]@{Inventory=[pscustomobject]@{CheckedUtc=$stamp;Model='Fixture';RamBytes=17179869184;Notes=('representative payload '*180)}}}
     for($probe=1;$probe -le $ProbeCount;$probe++){$map=[ordered]@{};$map['fixture.'+$probe]=[pscustomobject]@{CheckedUtc=$stamp;Rows=@(,@('42'));Count=1};$families['Probe:fixture.'+$probe]=[pscustomobject]@{Probes=[pscustomobject]$map}}
     foreach($family in $families.Keys){$data=$families[$family]|ConvertTo-Json -Depth 10 -Compress;$v=@($id,$family,$dn,$stamp,'Success',$stamp,$data,1);[void]$sql.AppendLine('INSERT INTO domenia_observations(object_guid,family,dn,attempt_at,status,success_at,payload,revision) VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')}
    }
    [void]$sql.AppendLine('COMMIT;');[void](Invoke-DomeniaDbExec $sql.ToString() $db)
   }
   # Any rewrite of a stored inventory/probe is a hard failure, not a timing assertion.
   [void](Invoke-DomeniaDbExec "CREATE TRIGGER fixture_no_wmi_insert BEFORE INSERT ON domenia_observations WHEN NEW.family<>'Presence' BEGIN SELECT RAISE(ABORT,'unexpected WMI rewrite'); END;CREATE TRIGGER fixture_no_wmi_update BEFORE UPDATE ON domenia_observations WHEN OLD.family<>'Presence' BEGIN SELECT RAISE(ABORT,'unexpected WMI rewrite'); END;CREATE TRIGGER fixture_no_cache BEFORE INSERT ON park_session_cache BEGIN SELECT RAISE(ABORT,'unexpected full projection persistence'); END;" $db)
  }finally{Close-DomeniaDatabase $db}
  Expect ((Read-TestDb 'SELECT count(*) n FROM ad_objects;')[0].n -eq $Objects) 'exact seeded objects'
  Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_observations;')[0].n -eq $Objects*($ProbeCount+2)) 'exact seeded families'
 }
 Case 'Production Presence batches commit without touching WMI and return canonical readback' {
  $watch=[Diagnostics.Stopwatch]::StartNew();$times=[Collections.Generic.List[long]]::new()
  for($offset=0;$offset -lt $Objects;$offset+=250){
   $changes=@(for($n=1;$n -le 250;$n++){$index=$offset+$n;$id='10000000-0000-0000-0000-'+$index.ToString('000000000000');$name='Load-'+$index.ToString('00000');[pscustomobject]@{Kind='Observation';Guid=$id;DN=('CN='+$name+',OU=Parc,DC=test');Family='Presence';Status='Success';AttemptedAtUtc=$fresh;ObservedAtUtc=$fresh;Data=[pscustomobject]@{Presence='Sans reponse'}}})
   $slice=[Diagnostics.Stopwatch]::StartNew();$r=Commit $changes;$slice.Stop();$times.Add($slice.ElapsedMilliseconds)
   Expect ($r.ObservationRows.Count -eq 250) 'all batch rows selected after commit'
   foreach($row in $r.ObservationRows){Expect ($row.Presence -eq 'Sans reponse' -and $row.Inventory.Model -eq 'Fixture' -and $row.Inventory.CheckedUtc -eq $stamp) 'new presence and unchanged real inventory date'}
  }
  $watch.Stop();$script:writeMs=$watch.ElapsedMilliseconds;$script:batchMs=$times.ToArray()
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_observations WHERE family<>'Presence' AND revision<>1;")[0].n -eq 0) 'no WMI revision rewritten'
  Expect ((Read-TestDb 'SELECT count(*) n FROM park_session_cache;')[0].n -eq 0) 'no duplicate projection payload'
 }
 Case 'Paged canonical reads recover every object exactly once' {
  $watch=[Diagnostics.Stopwatch]::StartNew();$times=[Collections.Generic.List[long]]::new();$seen=[Collections.Generic.HashSet[string]]::new()
  for($offset=0;$offset -lt $Objects;$offset+=250){
   $slice=[Diagnostics.Stopwatch]::StartNew();$r=Read-Store ([pscustomobject]@{Kind='Observation';Family='Presence';ScopeDn='OU=Parc,DC=test';Subtree=$true;Limit=250;Offset=$offset;Projection='List'});$slice.Stop();$times.Add($slice.ElapsedMilliseconds)
   Expect ($r.Total -eq $Objects -and $r.Observations.Count -eq 250) 'exact total and family page'
   foreach($row in $r.Observations){Expect ($seen.Add([string]$row.Guid) -and $row.Data.Presence -eq 'Sans reponse') 'unique committed presence'}
  }
  $watch.Stop();$script:readMs=$watch.ElapsedMilliseconds;$script:pageMs=$times.ToArray();Expect ($seen.Count -eq $Objects) 'complete paged coverage'
 }
 $script:dbBytes=[IO.FileInfo]::new($path).Length;$script:workingSet=[Diagnostics.Process]::GetCurrentProcess().WorkingSet64
}finally{if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder,$true)}}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$unchanged=$true;foreach($name in $sourceHashes.Keys){if((Get-FileHash (Join-Path $wad ('modules/'+$name)) -Algorithm SHA256).Hash -cne $sourceHashes[$name]){$unchanged=$false}}
$report=[pscustomobject]@{Suite='DomeniaStoreLoad';Passed=($failed -eq 0);Total=$cases.Count;Failed=$failed;Assertions=$script:checks;Objects=$Objects;FamiliesPerObject=($ProbeCount+2);SQLiteVersion=$script:sqliteVersion;Platform=[Environment]::OSVersion.ToString();PowerShell=$PSVersionTable.PSVersion.ToString();WriteMs=$script:writeMs;ReadMs=$script:readMs;BatchMs=$script:batchMs;PageMs=$script:pageMs;DatabaseBytes=$script:dbBytes;ProcessWorkingSetSnapshotBytes=$script:workingSet;SourceHashes=$sourceHashes;ExecutedWorkerSHA256=$executedWorkerHash;ExecutedReaderSHA256=$executedReaderHash;CurrentSourcesUnchanged=$unchanged;Limitations='Disposable local SQLite; direct SQL seeds the starting fixture outside timed paths. Timed writes/reads execute real Store workers. No AD, network, WPF or Windows qualification. WorkingSet is a snapshot, not peak memory.';Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
Write-Output ('StoreLoad: '+($cases.Count-$failed)+'/'+$cases.Count+' cases, '+$script:checks+' assertions')
if($failed){exit 1};exit 0
