#requires -Version 5.1
# Runs the actual storage worker against a disposable local SQLite database.
# macOS uses Apple's SQLite ABI; this does not qualify Windows winsqlite3 or WPF.
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Core parse failed'}
function Import-CoreFunction {
    param([string]$Name,[switch]$Native)
    $functions=@($core.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name},$true))
    if($functions.Count -ne 1){throw ('Ambiguous function '+$Name)}
    $text=$functions[0].Extent.Text
    if($Native -and $PSVersionTable.PSEdition -eq 'Core'){
        $text=$text.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
        if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$text=$text.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
        elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$text=$text.Replace('winsqlite3.dll','libsqlite3.so.0')}
    }
    . ([scriptblock]::Create(($text -replace ('^function '+[regex]::Escape($Name)),('function script:'+$Name))))
}
$script:checks=0
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
Import-CoreFunction Get-DomeniaSqliteSchemaText
Import-CoreFunction Initialize-DomeniaWinSqliteNative -Native
[void](Initialize-DomeniaWinSqliteNative)
. (Join-Path $wad 'modules/Domenia-Common.Model.ps1');. (Join-Path $wad 'modules/Domenia-Probes.Model.ps1')
. (Join-Path $wad 'modules/Domenia-QueryLibrary.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Storage.Worker.ps1')
$worker=Get-DomeniaStorageWorkerCode
$workerAst=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$tokens,[ref]$errors)
foreach($function in @($workerAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($function.Extent.Text))}
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-index-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
$path=Join-Path $folder 'test.sqlite'
function Read-TestDb {param([string]$Sql);$db=Open-DomeniaDatabase -Path $path;try{return @(Invoke-DomeniaDbQuery $Sql $db)}finally{Close-DomeniaDatabase $db}}
function New-IndexRow {param([string]$Guid,[string]$Name='PC');return [pscustomobject]@{Guid=$Guid;Type='Machine';Name=$Name;DN=('CN='+$Name+',DC=test');State='Actif';Facts=$true;OsVersion='26100';WhenCreated='2026-01-01T00:00:00Z';PwdLastSet='2026-10-01T00:00:00Z';LapsKind='None';Usn=1}}
function Write-Batch {param([object[]]$Rows,[string]$At,[string]$Scope='directory',[bool]$Complete=$true,[bool]$Replace=$false,[long]$Usn=10)
    $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=$Rows;At=$At;Server='dc.test';BaseDn='DC=test';SyncScope=$Scope;Complete=$Complete;ReplaceAll=$Replace;HighestUsn=$Usn;InvocationId='instance-1'}})}
    $answer=& ([scriptblock]::Create($worker))
    Expect ([bool]$answer.Saved) 'commit receipt'
}
try{
    # Invoke the production generator: AST.Value does not expand its shared schema call.
    $schema=Get-DomeniaSqliteSchemaText
    $db=Open-DomeniaDatabase -Path $path;try{[void](Invoke-DomeniaDbExec $schema $db)}finally{Close-DomeniaDatabase $db}
    Write-Batch @((New-IndexRow 'g1' 'PC-1'),(New-IndexRow 'g2' 'PC-2')) '2026-10-01T00:00:00Z' -Replace $true
    Write-Batch @((New-IndexRow 'g3' 'PC-3')) '2026-10-02T00:00:00Z' -Scope 'ou:ou=a,dc=test' -Usn 30
    $sync=Read-TestDb "SELECT * FROM sync_state WHERE scope='directory';"
    Expect ($sync[0].highest_usn -eq 10 -and $sync[0].last_sync -eq '2026-10-01T00:00:00Z') 'OU cannot advance domain checkpoint'
    Expect ((Read-TestDb "SELECT read_at FROM ad_computer_facts WHERE object_guid='g1';")[0].read_at -eq '2026-10-01T00:00:00Z') 'OU cannot rejuvenate unrelated facts'
    Write-Batch @((New-IndexRow 'g4' 'PC-4')) '2026-10-03T00:00:00Z' -Complete $false -Usn 40
    Expect ((Read-TestDb "SELECT highest_usn FROM sync_state WHERE scope='directory';")[0].highest_usn -eq 10) 'partial checkpoint preserved'
    Expect ((Read-TestDb "SELECT details FROM sync_state WHERE scope='attempt:directory';")[0].details -eq 'partial;depth=Subtree') 'partial attempt and explicit depth recorded'
    Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 4) 'partial merge preserves existing rows'
    Write-Batch @() '2026-10-04T00:00:00Z' -Usn 50
    Expect ((Read-TestDb "SELECT highest_usn FROM sync_state WHERE scope='directory';")[0].highest_usn -eq 50) 'empty complete delta advances checkpoint'
    Expect ((Read-TestDb "SELECT count(*) AS n FROM ad_computer_facts WHERE read_at='2026-10-04T00:00:00Z';")[0].n -eq 4) 'complete delta promotes known fresh facts'
    $refused=$false;try{Write-Batch @() '2026-10-05T00:00:00Z' -Complete $false -Replace $true}catch{$refused=$true};Expect $refused 'partial replacement refused'
    Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 4) 'refusal rolled back'
    Write-Batch @((New-IndexRow 'g5' 'PC-5')) '2026-10-06T00:00:00Z' -Replace $true -Usn 60
    Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 1) 'complete replacement reconciles removals'
    Expect ((Read-TestDb "SELECT count(*) AS n FROM sync_state WHERE scope LIKE 'ou:%';")[0].n -eq 0) 'old OU coverage removed by rebuild'

    # File transfer path: actual production stream, hash, batched inserts and rollback.
    $spool=Join-Path $folder 'index-spool';[void][IO.Directory]::CreateDirectory($spool)
    $spoolFile=Join-Path $spool ([guid]::NewGuid().ToString('N')+'.jsonl')
    $writer=[IO.StreamWriter]::new($spoolFile,$false,[Text.UTF8Encoding]::new($false))
    try{for($n=1;$n -le 600;$n++){$writer.WriteLine((New-IndexRow ('stream-'+$n) ('PC-'+$n)|ConvertTo-Json -Compress))}}finally{$writer.Dispose()}
    $transfer=[pscustomobject]@{Path=$spoolFile;Sha256=(Get-FileHash $spoolFile).Hash;RowCount=600}
    $bulk=[pscustomobject]@{Rows=@();Transfer=$transfer;At='2026-10-07T00:00:00Z';Server='dc.test';BaseDn='DC=test';Complete=$true;ReplaceAll=$true;HighestUsn=70}
    $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=$bulk})}
    $answer=& ([scriptblock]::Create($worker))
    Expect ([bool]$answer.Saved -and (Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 600) 'stream commits across 256-row SQL batches'
    Expect ((Read-TestDb "SELECT item_count FROM sync_state WHERE scope='attempt:directory';")[0].item_count -eq 600) 'stream receipt count truthful'
    $transfer.RowCount=601;$refused=$false
    try{& ([scriptblock]::Create($worker))|Out-Null}catch{$refused=$true}
    Expect $refused 'stream count mismatch refused'
    Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 600) 'stream count mismatch rolls back whole replacement'
    $transfer.RowCount=600;$transfer.Sha256='0'*64;$refused=$false
    try{& ([scriptblock]::Create($worker))|Out-Null}catch{$refused=$true}
    Expect $refused 'modified spool refused'
    $transfer.Sha256=(Get-FileHash $spoolFile).Hash;$transfer.Path=$path;$refused=$false
    try{& ([scriptblock]::Create($worker))|Out-Null}catch{$refused=$true}
    Expect $refused 'spool path anchored to DB staging directory'
    [IO.File]::Delete($spoolFile);[IO.Directory]::Delete($spool)

    # Collection uses lightweight identity metadata; directory changes still invalidate user reuse.
    Add-Type -Path (Join-Path $wad 'modules/Domenia.Native.dll')
    . (Join-Path $wad 'modules/Domenia-Engine.Worker.ps1')
    $user=[pscustomobject]@{Guid='user-current';Type='Utilisateur';Name='Alice';Login='alice';DN='CN=Alice,DC=test';State='Actif';Usn=5}
    Write-Batch @($user) '2026-10-08T00:00:00Z' -Scope 'ou:users' -Usn 80
    $cacheSchema=@($workerAst.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like 'CREATE TABLE IF NOT EXISTS park_session_cache*'},$true))[0].Value
    $db=Open-DomeniaDatabase $path
    try{
        [void](Invoke-DomeniaDbExec $cacheSchema $db)
        foreach($n in 1..4){
            $obs=[pscustomobject]@{Key=('cn=pc-'+$n+',dc=test');Guid=$(if($n -eq 3){'recreated'}else{'stream-'+$n});UserGuid=$(if($n -eq 2){'old-user'}else{'user-current'});UserDn='CN=Alice,DC=test';LinkUser='alice';UserUsn=$(if($n -eq 1){'1'}else{'5'});Probes=[pscustomobject]@{raw=[pscustomobject]@{Rows=@(,@('preserve'))}}}
            $json=$obs|ConvertTo-Json -Depth 8 -Compress
            [void](Invoke-DomeniaDbExec ('INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES('+(ConvertTo-DomeniaSqlLiteral $obs.Key)+','+(ConvertTo-DomeniaSqlLiteral '2026-10-08T00:00:00Z')+','+(ConvertTo-DomeniaSqlLiteral $json)+');') $db)
        }
    }finally{Close-DomeniaDatabase $db}
    $Payload=[pscustomobject]@{Action='ParkTargets';Path=$path;BusyTimeoutMs=250;Scope='Results';Targets=@(1..4|ForEach-Object{[pscustomobject]@{name=('PC-'+$_);distinguished_name=('CN=PC-'+$_+',DC=test');object_guid=('stream-'+$_)}})}
    $prepared=& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
    Expect ($prepared.Rows.Count -eq 4 -and @($prepared.Rows|Where-Object{$null -ne $_.Previous}).Count -eq 0) 'worker prepares JSON buffers without full probe graphs'
    Expect ($prepared.Rows[0].DirectoryChanged) 'changed user USN invalidates reuse'
    Expect ($prepared.Rows[1].DirectoryChanged) 'reused user DN and login invalidates old GUID'
    Expect (-not $prepared.Rows[2].PreviousJson) 'recreated computer cannot reuse old observations'
    Expect (-not $prepared.Rows[3].DirectoryChanged -and [bool]$prepared.Rows[3].PreviousJson) 'unchanged user keeps raw measurements for lazy merge'

    # Exact date boundaries from the real SQL, shared by dashboard and query templates.
    foreach($module in @('Domenia-Common.Model.ps1','Domenia-Boards.Model.ps1','Domenia-BoardFleet.Model.ps1','Domenia-Probes.Model.ps1')){. (Join-Path (Join-Path $wad 'modules') $module)}
    $today=[datetime]::Parse('2026-10-12T00:00:00Z').ToUniversalTime()
    $ages=@(6,7,29,30,89,90,179,180)
    $db=Open-DomeniaDatabase $path
    try{for($i=0;$i -lt $ages.Count;$i++){
        $date=$today.AddDays(-$ages[$i]).ToString('dd/MM/yyyy',[Globalization.CultureInfo]::InvariantCulture)
        [void](Invoke-DomeniaDbExec ("UPDATE ad_objects SET last_logon='"+$date+"' WHERE object_guid='stream-"+($i+1)+"';") $db)
    }}finally{Close-DomeniaDatabase $db}
    $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;BusyTimeoutMs=250;Scope='';Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $today);Keys=@();ScopeKey='*'}
    $fleet=& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
    $groups=@{};foreach($group in $fleet.Groups){$groups[[string]$group.gid]=$group}
    $expected=@(0,1,1,2,2,3,3,4)
    for($i=0;$i -lt $ages.Count;$i++){
        $machine=@($fleet.Machines|Where-Object{$_.object_guid -eq ('stream-'+($i+1))})[0]
        Expect ([int]$groups[[string]$machine.gid].lb -eq $expected[$i]) ('SQL logon boundary '+$ages[$i]+' days')
    }

    # Exercise the actual backup worker, including the boundary protecting the active DB.
    $backupDir=Join-Path $folder 'backups';$export=Join-Path $folder 'export.sqlite'
    $backupWorker=Get-DomeniaStorageBackupWorkerCode
    $backupPayload=[pscustomobject]@{Database=$path;BackupDirectory=$backupDir;CopyTo=$export;BudgetSeconds=15;Keep=7}
    $Payload=$backupPayload;$receipt=& ([scriptblock]::Create($backupWorker))
    Expect ([IO.File]::Exists($receipt.Backup) -and [IO.File]::Exists($export)) 'verified backup and new export produced'
    Expect ((Get-FileHash $receipt.Backup).Hash -eq (Get-FileHash $export).Hash) 'export matches verified SQLite snapshot'
    $restored=Open-DomeniaDatabase -Path $export
    try{
        Expect (@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM ad_objects;' $restored)[0].n -eq 601) 'restored exported copy preserves readable object count'
        Expect (@(Invoke-DomeniaDbQuery "SELECT highest_usn FROM sync_state WHERE scope='directory';" $restored)[0].highest_usn -eq 70) 'restored exported copy preserves directory checkpoint'
    }finally{Close-DomeniaDatabase $restored}
    [IO.File]::WriteAllText($export,'old export');$Payload=$backupPayload;$receipt=& ([scriptblock]::Create($backupWorker))
    Expect ((Get-FileHash $receipt.Backup).Hash -eq (Get-FileHash $export).Hash) 'existing export atomically replaced'
    foreach($suffix in @('','-wal','-shm','-journal')){
        $backupPayload.CopyTo=$path+$suffix;$Payload=$backupPayload;$refused=$false
        try{& ([scriptblock]::Create($backupWorker))|Out-Null}catch{$refused=$_.Exception.Message -like '*base active*'}
        Expect $refused ('worker refuses active database path '+$suffix)
    }
    Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 601) 'backup refusal preserves active rows'
    Expect (@(Get-ChildItem -LiteralPath $folder -Filter '*.partial' -Recurse).Count -eq 0) 'backup and export leave no partial file'
    [IO.File]::Delete($export);Remove-Item -LiteralPath $backupDir -Recurse -Force

    # Execute the real index serializer with inert directory doubles (no directory/network operation).
    Import-CoreFunction Get-DomeniaIndexWorkerCode
    function Get-WDirectoryVersionSource {param($Context);return ''}
    function New-WRootDse {throw 'No directory in this pure test'}
    function Get-WPropFirst {param($Props,$Name,$Default='');if($Props.ContainsKey($Name)){return $Props[$Name]};return $Default}
    function Convert-WLargeInteger {param($Value);return [long]$Value}
    function Convert-WGuid {param($Value);return [string]$Value}
    function Convert-WDate {param($Value);return [string]$Value}
    function Convert-WFileTime {param($Value);return ''}
    $script:streamSearchers=[Collections.Generic.List[object]]::new()
    function New-WSearcher {
        param($Context,$BaseDn,$Filter,$Properties,$Scope,$Limit)
        $searcher=[pscustomobject]@{PageSize=0;CacheResults=$true;ServerTimeLimit=$null;ClientTimeout=$null;Filter=$Filter}
        $searcher|Add-Member ScriptMethod FindAll {if($this.Filter -match 'objectCategory=computer'){return ,@([pscustomobject]@{Properties=@{name='PC-stream';distinguishedname='CN=PC-stream,DC=test';objectguid='11111111-1111-1111-1111-111111111111'}})};return ,@()}
        $searcher|Add-Member ScriptMethod Dispose {}
        $script:streamSearchers.Add($searcher);return $searcher
    }
    $Context=[pscustomobject]@{BaseDn='DC=test';Server='dc.test'}
    $progress=[hashtable]::Synchronized(@{Phase='Lecture';Count=0L})
    $Payload=[pscustomobject]@{Path=$path;Progress=$progress;MaxObjects=0;BudgetMs=30000;LastUsn=0;LastServer='';Since='';ComputerFirst=$true}
    $indexed=& ([scriptblock]::Create((Get-DomeniaIndexWorkerCode)))
    Expect (-not $indexed.Truncated -and $indexed.RowCount -eq 1 -and $indexed.Rows.Count -eq 0 -and $indexed.Transfer.RowCount -eq 1) 'index streams rows instead of accumulating RAM arrays'
    Expect ($indexed.LimitMaxObjects -eq 0 -and -not $script:streamSearchers[0].CacheResults) 'runtime has no artificial object quota and disables provider result cache'
    Expect ($indexed.Transfer.Sha256 -eq (Get-FileHash $indexed.Transfer.Path).Hash -and $progress.Count -eq 1) 'transfer hash and live progress receipt'
    [IO.File]::Delete($indexed.Transfer.Path);[IO.Directory]::Delete($spool)

    # Actual enqueue wrapper + cache functions, with external scheduling replaced by a recorder.
    foreach($function in @('Save-DomeniaIndex','Update-DomeniaIndexDatabaseRows','Set-VisitCacheValue','Get-VisitCacheValue')){Import-CoreFunction $function}
    $script:queued=[Collections.Generic.List[object]]::new()
    function Queue-DomeniaMetadata {param($Kind,$Row,$Key='');$script:queued.Add([pscustomobject]@{Kind=$Kind;Row=$Row;Key=$Key});return $true}
    [void](Update-DomeniaIndexDatabaseRows -Rows @() -SyncScope 'ou:a');[void](Update-DomeniaIndexDatabaseRows -Rows @() -SyncScope 'ou:b')
    Expect ($script:queued.Count -eq 2 -and -not $script:queued[0].Key -and -not $script:queued[1].Key) 'OU wrappers request unique queue keys'
    function Get-CfgValue {param($Section,$Key,$Default);if($Key -eq 'MaxEntries'){return 2};return $Default}
    $script:VisitCache=@{};$script:CacheStats=[pscustomobject]@{Hits=0;Misses=0;Evictions=0;Writes=0;Errors=0}
    Set-VisitCacheValue a 1;Set-VisitCacheValue b 2;Set-VisitCacheValue a 3
    Expect ($script:VisitCache.Count -eq 2 -and $script:VisitCache.ContainsKey('b')) 'updating cache does not evict another key'
    $script:VisitCache.b.Accessed=(Get-Date).AddDays(-1)
    [void](Get-VisitCacheValue a);Set-VisitCacheValue c 4
    Expect ($script:VisitCache.ContainsKey('a') -and $script:VisitCache.ContainsKey('c') -and -not $script:VisitCache.ContainsKey('b')) 'least recently used cache eviction'
    $script:VisitCache.a.Expires=(Get-Date).AddSeconds(-1);Expect ($null -eq (Get-VisitCacheValue a)) 'expired value never returned'
    # Reconciliation uses the real SQLite worker in a separate disposable database.
    $originalPath=$path;$path=Join-Path $folder 'reconcile.sqlite'
    $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schema $db)}finally{Close-DomeniaDatabase $db}
    function New-ReconcileRow {
        param([int]$Number,[string]$Dn,[string]$State='Actif')
        $r=New-IndexRow ('00000000-0000-0000-0000-'+$Number.ToString('000000000000')) ('PC-'+$Number)
        $r.DN=$Dn;$r.State=$State;return $r
    }
    function New-Identity {param($Row);return [pscustomobject]@{Kind='Identity';Guid=$Row.Guid;DN=$Row.DN}}
    function New-ReconcileBulk {
        param([object[]]$Rows=@(),[object[]]$Identities=@(),[string]$Scope='DC=test',[string]$SearchScope='Subtree',[string]$Mode='Census',[bool]$Complete=$true)
        $meta=[pscustomobject]@{Mode=$Mode;ScopeDn=$Scope;SearchScope=$SearchScope;Complete=$Complete;ExpectedCount=$(if($Mode -eq 'Census'){@($Identities).Count}else{@($Rows).Count});Identities=$Identities;StartedUtc='2026-10-05T00:00:00Z';Server='dc.test';InvocationId='instance-1'}
        return [pscustomobject]@{Rows=$Rows;Transfer=$null;Reconcile=$meta;Server='dc.test';BaseDn=$Scope;SyncScope=$(if($Mode -eq 'Census'){'directory'}else{'ou:'+$Scope.ToLowerInvariant()});Complete=$Complete;ReplaceAll=$false;HighestUsn=100;InvocationId='instance-1';At='2026-10-06T00:00:00Z'}
    }
    function Invoke-ReconcileBulk {param($Bulk);$Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=$Bulk})};return & ([scriptblock]::Create($worker))}
    function Expect-ReconcileRefused {param($Bulk,[string]$Name);$before=(Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n;$refused=$false;try{Invoke-ReconcileBulk $Bulk|Out-Null}catch{$refused=$true};Expect $refused $Name;Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq $before) ($Name+' rolls back')}
    try{
        $first=New-ReconcileRow 1 'CN=PC-1,OU=A,DC=test';$gone=New-ReconcileRow 2 'CN=PC-2,OU=A,DC=test'
        Write-Batch @($first,$gone) '2026-10-01T00:00:00Z' -Replace $true
        $moved=New-ReconcileRow 1 'CN=PC-1,OU=B,DC=test' 'Desactive'
        $b=New-ReconcileBulk -Rows @($moved) -Identities @((New-Identity $moved))
        $r=Invoke-ReconcileBulk $b
        Expect ([bool]$r.Saved -and (Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 1) 'complete census removes absent cached objects'
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_computer_facts;')[0].n -eq 1) 'removed object facts removed atomically'
        $stored=(Read-TestDb 'SELECT * FROM ad_objects;')[0]
        Expect ($stored.distinguished_name -eq $moved.DN -and $stored.state -eq 'Desactive') 'moved and disabled objects remain with new state'
        Expect ((Read-TestDb "SELECT highest_usn FROM sync_state WHERE scope='directory';")[0].highest_usn -eq 100) 'complete census advances only supplied pre-read checkpoint'
        $b=New-ReconcileBulk -Identities @();Expect-ReconcileRefused $b 'empty domain census requires explicit full rebuild'
        Write-Batch @($first,$gone) '2026-10-01T00:00:00Z' -Replace $true
        $b=New-ReconcileBulk -Identities @((New-Identity $moved))
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT distinguished_name FROM ad_objects;')[0].distinguished_name -eq $moved.DN) 'census repairs DN without re-reading all attributes'
        Write-Batch @($first,$gone) '2026-10-01T00:00:00Z' -Replace $true
        $extra=New-ReconcileRow 3 'CN=PC-3,DC=test'
        $b=New-ReconcileBulk -Rows @($extra) -Identities @((New-Identity $first)) -Complete $false
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 3) 'partial census merges read rows without pruning'
        Expect ((Read-TestDb "SELECT highest_usn FROM sync_state WHERE scope='directory';")[0].highest_usn -eq 10) 'partial census preserves domain checkpoint'
        Expect ((Read-TestDb "SELECT last_sync FROM sync_state WHERE scope='directory';")[0].last_sync -eq '2026-10-01T00:00:00Z') 'partial census preserves completed freshness date'

        $direct=New-ReconcileRow 11 'CN=Old,OU=A,DC=test'
        $nested=New-ReconcileRow 12 'CN=Nested,OU=Child,OU=A,DC=test'
        $other=New-ReconcileRow 13 'CN=Other,OU=B,DC=test'
        $escaped=New-ReconcileRow 14 'CN=Trap\,OU=A,DC=test'
        $slashes=New-ReconcileRow 15 'CN=Slash\\,OU=A,DC=test'
        $escapedOu=New-ReconcileRow 16 'CN=Trap,OU=Child\,OU=A,DC=test'
        Write-Batch @($direct,$nested,$other,$escaped,$slashes,$escapedOu) '2026-10-01T00:00:00Z' -Replace $true
        $b=New-ReconcileBulk -Scope 'OU=A,DC=test' -SearchScope OneLevel -Mode Rows
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 4) 'OneLevel removes direct children including even escaped backslashes'
        Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_objects WHERE object_guid='"+$nested.Guid+"';"))[0].n -eq 1) 'OneLevel preserves nested OU objects'
        Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_objects WHERE object_guid IN ('"+$escaped.Guid+"','"+$escapedOu.Guid+"');"))[0].n -eq 2) 'escaped commas cannot masquerade as OU boundaries'
        $b=New-ReconcileBulk -Scope 'OU=A,DC=test' -Mode Rows
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 3) 'complete subtree removes absent descendants and preserves other scopes'
        Expect ((Read-TestDb "SELECT highest_usn FROM sync_state WHERE scope='directory';")[0].highest_usn -eq 10) 'OU reconciliation never changes domain checkpoint'
        $b=New-ReconcileBulk -Rows @($direct) -Scope 'OU=A,DC=test' -Mode Rows -Complete $false
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 4) 'partial OU merges without removing prior objects'

        $newer=New-ReconcileRow 20 'CN=Newer,OU=A,DC=test' 'Desactive'
        Write-Batch @($first) '2026-10-01T00:00:00Z' -Replace $true
        Write-Batch @($newer) '2026-10-09T00:00:00Z' -Scope 'ou:ou=a,dc=test'
        $b=New-ReconcileBulk -Identities @((New-Identity $first))
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 2) 'concurrent newer local read survives older census absence'
        $older=New-ReconcileRow 20 'CN=OldName,OU=B,DC=test'
        $b=New-ReconcileBulk -Rows @($older) -Identities @((New-Identity $first),(New-Identity $older))
        [void](Invoke-ReconcileBulk $b)
        $stored=(Read-TestDb ("SELECT * FROM ad_objects WHERE object_guid='"+$newer.Guid+"';"))[0]
        Expect ($stored.distinguished_name -eq $newer.DN -and $stored.state -eq 'Desactive') 'older queued delta does not overwrite a newer local read'
        Expect ((Read-TestDb ("SELECT read_at FROM ad_computer_facts WHERE object_guid='"+$newer.Guid+"';"))[0].read_at -eq '2026-10-09T00:00:00Z') 'older delta cannot downgrade newer facts freshness'

        # The domain-root walk uses ou:dc=test + OneLevel, exactly as the UI callback does.
        $rootRow=New-ReconcileRow 21 'CN=AtRoot,DC=test'
        Write-Batch @($first,$rootRow) '2026-10-01T00:00:00Z' -Replace $true
        $b=New-ReconcileBulk -Scope 'DC=test' -SearchScope OneLevel -Mode Rows
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 1) 'root OneLevel walk only removes direct root objects'
        Expect ((Read-TestDb "SELECT count(*) AS n FROM sync_state WHERE scope='ou:onelevel:dc=test';")[0].n -eq 1) 'root OneLevel checkpoint stored separately'

        # A full rebuild shares the same newer-row guard; it does not clear before merging.
        Write-Batch @($first,$gone) '2026-10-01T00:00:00Z' -Replace $true
        Write-Batch @($newer) '2026-10-09T00:00:00Z' -Scope 'ou:ou=a,dc=test'
        $b=New-ReconcileBulk -Rows @($first,$older) -Mode Rows
        $b.ReplaceAll=$true;$b.SyncScope='directory'
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 2) 'full rebuild reconciles absent old rows and retains newer rows'
        $stored=(Read-TestDb ("SELECT * FROM ad_objects WHERE object_guid='"+$newer.Guid+"';"))[0]
        Expect ($stored.distinguished_name -eq $newer.DN -and $stored.state -eq 'Desactive') 'full rebuild cannot overwrite newer search result'
        Expect ((Read-TestDb ("SELECT read_at FROM ad_computer_facts WHERE object_guid='"+$newer.Guid+"';"))[0].read_at -eq '2026-10-09T00:00:00Z') 'full rebuild preserves facts of newer local result'
        Expect ((Read-TestDb "SELECT count(*) AS n FROM sync_state WHERE scope LIKE 'ou:%';")[0].n -eq 0) 'full rebuild invalidates prior OU coverage'
        Write-Batch @($first) '2026-10-01T00:00:00Z' -Replace $true
        $b=New-ReconcileBulk -Mode Rows;$b.ReplaceAll=$true;$b.SyncScope='directory'
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 0) 'explicit complete full rebuild can confirm an empty directory'
        Write-Batch @($first,$gone) '2026-10-01T00:00:00Z' -Replace $true

        # UTF-8 boundaries are byte budgets, not a UTF-16 character count.
        $unicode=[string][char]0x00e9
        $observation=[pscustomobject]@{Version=1;Key='large';Guid='large-guid';CheckedUtc=[datetime]::UtcNow.ToString('o');Computer='LARGE';Outcome='Observed';Text=($unicode*140000)}
        $encoded=$observation|ConvertTo-Json -Depth 7 -Compress
        Expect ($encoded.Length -lt 262144 -and [Text.Encoding]::UTF8.GetByteCount($encoded) -gt 262144) 'park Unicode fixture crosses only byte budget'
        $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='ParkSession';Row=$observation})};$refused=$false
        try{& ([scriptblock]::Create($worker))|Out-Null}catch{$refused=$_.Exception.Message -like '*volumineuse*'}
        Expect $refused 'park observation UTF-8 byte limit enforced by actual storage worker'
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 2) 'oversize Unicode observation leaves AD index untouched'
        $liveAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules/Domenia-Live.Model.ps1'),[ref]$tokens,[ref]$errors)
        $liveFn=@($liveAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DomeniaLiveCacheCode'},$true))[0]
        . ([scriptblock]::Create($liveFn.Extent.Text))
        $small=[pscustomobject]@{Key='small';CheckedUtc=[datetime]::UtcNow.ToString('o');Text='small'}
        $large=[pscustomobject]@{Key='large';CheckedUtc=[datetime]::UtcNow.ToString('o');Text=($unicode*9000)}
        $encoded=$large|ConvertTo-Json -Compress
        Expect ($encoded.Length -lt 16384 -and [Text.Encoding]::UTF8.GetByteCount($encoded) -gt 16384) 'live Unicode fixture crosses only byte budget'
        $Payload=[pscustomobject]@{Path=$path;Mode='Write';Scope=('a'*64);Query=$null;Observations=@($small,$large)};$refused=$false
        try{& ([scriptblock]::Create((Get-DomeniaLiveCacheCode)))|Out-Null}catch{$refused=$_.Exception.Message -like '*volumineuse*'}
        Expect $refused 'live observation UTF-8 byte limit enforced by actual cache worker'
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM adcc_live_observations;')[0].n -eq 0) 'live Unicode overflow rolls back preceding valid observation'

        foreach($case in @('duplicate','invalid','outside','count','server','invocation','scope','complete','date')){
            $b=New-ReconcileBulk -Rows @($extra) -Identities @((New-Identity $first))
            switch($case){
                duplicate {$b.Reconcile.Identities=@((New-Identity $first),(New-Identity $first));$b.Reconcile.ExpectedCount=2}
                invalid {$b.Reconcile.Identities[0].Guid='bad-guid'}
                outside {$b.Reconcile.Identities[0].DN='CN=X,DC=other'}
                count {$b.Reconcile.ExpectedCount=2}
                server {$b.Reconcile.Server='other.test'}
                invocation {$b.Reconcile.InvocationId='other-instance'}
                scope {$b.Reconcile.ScopeDn='OU=Other,DC=test'}
                complete {$b.Reconcile.Complete=$false}
                date {$b.Reconcile.StartedUtc='not-a-date'}
            }
            Expect-ReconcileRefused $b ('reconciliation refuses '+$case)
        }
        # Mixed streamed rows and identities share one digest, with independent truthful counts.
        [void][IO.Directory]::CreateDirectory($spool)
        $spoolFile=Join-Path $spool ([guid]::NewGuid().ToString('N')+'.jsonl')
        $w=[IO.StreamWriter]::new($spoolFile,$false,[Text.UTF8Encoding]::new($false))
        try{$w.WriteLine(($extra|ConvertTo-Json -Compress));$w.WriteLine(((New-Identity $first)|ConvertTo-Json -Compress));$w.WriteLine(((New-Identity $extra)|ConvertTo-Json -Compress))}finally{$w.Dispose()}
        $b=New-ReconcileBulk -Identities @((New-Identity $first),(New-Identity $extra))
        $b.Reconcile.Identities=@();$b.Transfer=[pscustomobject]@{Path=$spoolFile;Sha256=(Get-FileHash $spoolFile).Hash;RowCount=1;CensusRowCount=2}
        [void](Invoke-ReconcileBulk $b)
        Expect ((Read-TestDb "SELECT item_count FROM sync_state WHERE scope='attempt:directory';")[0].item_count -eq 1) 'stream identity markers do not inflate object count'
        $b.Transfer.CensusRowCount=1;Expect-ReconcileRefused $b 'stream census marker count mismatch'
        $b.Transfer.CensusRowCount=2;$b.Transfer.RowCount=3;Expect-ReconcileRefused $b 'stream object count excludes identity markers'
        $b.Transfer.RowCount=1;$b.Transfer.Sha256='0'*64;Expect-ReconcileRefused $b 'stream census bytes protected by same hash'
        [IO.File]::Delete($spoolFile);[IO.Directory]::Delete($spool)
        # 5,000 real SQLite identities, complete stream and final-page identity checks.
        $scaleRows=@(for($n=1;$n -le 5000;$n++){New-ReconcileRow (10000+$n) ('CN=PC-'+$n+',OU=Scale,DC=test')})
        Write-Batch $scaleRows '2026-10-01T00:00:00Z' -Replace $true
        [void][IO.Directory]::CreateDirectory($spool)
        $spoolFile=Join-Path $spool ([guid]::NewGuid().ToString('N')+'.jsonl')
        $w=[IO.StreamWriter]::new($spoolFile,$false,[Text.UTF8Encoding]::new($false))
        try{for($n=0;$n -lt 4999;$n++){$id=New-Identity $scaleRows[$n];if($n -eq 0){$id.DN='CN=Moved,OU=Other,DC=test'};$w.WriteLine(($id|ConvertTo-Json -Compress))}}finally{$w.Dispose()}
        $b=New-ReconcileBulk;$b.Reconcile.ExpectedCount=4999
        $b.Transfer=[pscustomobject]@{Path=$spoolFile;Sha256=(Get-FileHash $spoolFile).Hash;RowCount=0;CensusRowCount=4999}
        $timer=[Diagnostics.Stopwatch]::StartNew();[void](Invoke-ReconcileBulk $b);$timer.Stop()
        Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 4999) '5000-object census retains all 4999 observed identities'
        Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_objects WHERE object_guid='"+$scaleRows[4998].Guid+"';"))[0].n -eq 1) '5000-object census includes the last retained identity'
        Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_objects WHERE object_guid='"+$scaleRows[4999].Guid+"';"))[0].n -eq 0) '5000-object census removes only absent final identity'
        Expect ((Read-TestDb ("SELECT distinguished_name FROM ad_objects WHERE object_guid='"+$scaleRows[0].Guid+"';"))[0].distinguished_name -eq 'CN=Moved,OU=Other,DC=test') '5000-object census repairs moved DN'
        Write-Output ('BENCH GUID census 5000 cached / 4999 identities: '+$timer.ElapsedMilliseconds+' ms; local SQLite only')
        [IO.File]::Delete($spoolFile);[IO.Directory]::Delete($spool)
        # Points 22, 23, 24 and 30: absences, census gap, verification results and snapshots with the real workers.
        $reconcilePath=$path;$path=Join-Path $folder 'directory-sync.sqlite'
        $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schema $db)}finally{Close-DomeniaDatabase $db}
        try{
            $kept=New-ReconcileRow 31 'CN=PC-31,OU=A,DC=test';$lost=New-ReconcileRow 32 'CN=PC-32,OU=A,DC=test';$away=New-ReconcileRow 33 'CN=PC-33,OU=A,DC=test'
            Write-Batch @($kept,$lost,$away) '2026-10-01T00:00:00Z' -Replace $true
            [void](Invoke-ReconcileBulk (New-ReconcileBulk -Rows @() -Scope 'OU=A,DC=test' -Mode Rows -Complete $false))
            Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_absences;')[0].n -eq 0 -and (Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 3) 'P24 partial read records no absence and removes nothing'
            [void](Invoke-ReconcileBulk (New-ReconcileBulk -Rows @($kept) -Scope 'OU=A,DC=test' -Mode Rows))
            $absent=@(Read-TestDb 'SELECT * FROM ad_absences ORDER BY object_guid;')
            Expect ($absent.Count -eq 2 -and @($absent|Where-Object{$_.status -ne 'NonVu'}).Count -eq 0) 'P24 complete OU read records absent objects as not seen, never as deleted'
            Expect ($absent[0].last_dn -eq $lost.DN -and $absent[0].scope_dn -eq 'OU=A,DC=test' -and $absent[0].noticed_at -eq '2026-10-06T00:00:00Z' -and $absent[0].object_type -eq 'Machine') 'P24 absence keeps last DN, scope, type and date'
            Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 1) 'P24 absent objects leave the local copy'
            Expect ((Read-TestDb "SELECT details FROM sync_state WHERE scope='ou:ou=a,dc=test';")[0].details -match ';absent=2(;|$)') 'P24 checkpoint counts the absences of this read'
            Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_computer_facts WHERE object_guid='"+$away.Guid+"';"))[0].n -eq 0) 'P24 facts leave with the row of an absent object'
            $record=[pscustomobject]@{Type='Machine';Guid=$away.Guid;Name='PC-33';Login='PC-33';Upn='';Display='';Description='';Extra='';State='Actif';DN='CN=PC-33,OU=B,DC=test';WhenChanged='';Usn=7;LastLogon='';Facts=$true;OsVersion='10.0 (22631)';WhenCreated='2024-03-01T08:00:00Z';PwdLastSet='2026-09-20T08:00:00Z';LapsKind='Legacy';LapsExpiry='2026-10-30T00:00:00Z'}
            $results=@(
                [pscustomobject]@{Guid=$away.Guid;Status='Deplace';FoundDn='CN=PC-33,OU=B,DC=test';Detail='Present ailleurs.';CheckedAt='2026-10-07T00:00:00.0000000Z';Server='dc.test';Record=$record}
                [pscustomobject]@{Guid=$lost.Guid;Status='Supprime';FoundDn='';Detail='Suppression constatee.';CheckedAt='2026-10-07T00:00:00.0000000Z';Server='dc.test';Record=$null}
            )
            $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='DirectoryAbsence';Row=[pscustomobject]@{Results=$results;Server='dc.test';At='2026-10-07T00:00:00Z'}})}
            Expect ([bool](& ([scriptblock]::Create($worker))).Saved) 'P24 verification results committed'
            $moved=@(Read-TestDb ("SELECT * FROM ad_objects WHERE object_guid='"+$away.Guid+"';"))
            Expect ($moved.Count -eq 1 -and $moved[0].distinguished_name -eq 'CN=PC-33,OU=B,DC=test' -and $moved[0].object_key -eq $away.Guid) 'P23 moved object takes its new DN under the same GUID key'
            Expect ((Read-TestDb ("SELECT status FROM ad_absences WHERE object_guid='"+$away.Guid+"';"))[0].status -eq 'Deplace') 'P23 move recorded with its new location'
            $awayFacts=@(Read-TestDb ("SELECT * FROM ad_computer_facts WHERE object_guid='"+$away.Guid+"';"))
            Expect ($awayFacts.Count -eq 1 -and $awayFacts[0].object_key -eq $away.Guid -and $awayFacts[0].os_version -eq '10.0 (22631)' -and $awayFacts[0].when_created -eq '2024-03-01T08:00:00Z' -and $awayFacts[0].pwd_last_set -eq '2026-09-20T08:00:00Z' -and $awayFacts[0].laps_kind -eq 'Legacy' -and $awayFacts[0].laps_expiry -eq '2026-10-30T00:00:00Z' -and $awayFacts[0].read_at -eq '2026-10-07T00:00:00.0000000Z') 'P23 computer found again gets its facts back, dated by the verification'
            Expect ((Read-TestDb ("SELECT status FROM ad_absences WHERE object_guid='"+$lost.Guid+"';"))[0].status -eq 'Supprime') 'P24 proven deletion recorded'
            Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_objects WHERE object_guid='"+$lost.Guid+"';"))[0].n -eq 0) 'P24 deleted object not re-inserted'
            $Payload.Items[0].Row.Results=@([pscustomobject]@{Guid=$away.Guid;Status='Deplace';FoundDn='CN=PC-33,OU=C,DC=test';Detail='x';CheckedAt='2026-10-07T00:00:00Z';Record=$record})
            $refused=$false;try{& ([scriptblock]::Create($worker))|Out-Null}catch{$refused=$true}
            Expect $refused 'P23 a re-read record whose DN differs from the found DN is refused'
            $Payload.Items[0].Row.Results=@([pscustomobject]@{Guid=$away.Guid;Status='Efface';FoundDn='';Detail='x';CheckedAt='2026-10-07T00:00:00Z';Record=$null})
            $refused=$false;try{& ([scriptblock]::Create($worker))|Out-Null}catch{$refused=$true}
            Expect ($refused -and (Read-TestDb ("SELECT status FROM ad_absences WHERE object_guid='"+$away.Guid+"';"))[0].status -eq 'Deplace') 'P24 unknown status refused, transaction rolled back'
            [void](Invoke-ReconcileBulk (New-ReconcileBulk -Rows @($kept,(New-ReconcileRow 33 'CN=PC-33,OU=A,DC=test')) -Scope 'OU=A,DC=test' -Mode Rows))
            Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_absences WHERE object_guid='"+$away.Guid+"';"))[0].n -eq 0) 'P24 an object read again is no longer absent'
            $unknown=New-ReconcileRow 34 'CN=PC-34,OU=A,DC=test'
            [void](Invoke-ReconcileBulk (New-ReconcileBulk -Identities @((New-Identity $kept),(New-Identity $unknown),(New-Identity (New-ReconcileRow 33 'CN=PC-33,OU=B,DC=test')))))
            Expect ((Read-TestDb "SELECT details FROM sync_state WHERE scope='directory';")[0].details -match ';gap=1(;|$)') 'P22 census identity unknown to the local copy recorded in the checkpoint'
            [void](Invoke-ReconcileBulk (New-ReconcileBulk -Identities @((New-Identity $kept),(New-Identity (New-ReconcileRow 33 'CN=PC-33,OU=B,DC=test')))))
            Expect ((Read-TestDb "SELECT details FROM sync_state WHERE scope='directory';")[0].details -notmatch 'gap=') 'P22 census without unknown identity clears the gap'
            Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_census_gaps;')[0].n -eq 0) 'P22 census without unknown identity empties the list of missing identities'
            # Point 22: the census gap is bounded by the USN captured before the pass and kept in the base for a read by GUID.
            $missing=New-ReconcileRow 37 'CN=PC-37,OU=C,DC=test';$early=New-ReconcileRow 38 'CN=PC-38,OU=C,DC=test';$late=New-ReconcileRow 36 'CN=PC-36,OU=C,DC=test'
            $earlyId=New-Identity $early;$earlyId|Add-Member -NotePropertyName Usn -NotePropertyValue 100
            $lateId=New-Identity $late;$lateId|Add-Member -NotePropertyName Usn -NotePropertyValue 101
            $known=@((New-Identity $kept),(New-Identity (New-ReconcileRow 33 'CN=PC-33,OU=B,DC=test')))
            [void](Invoke-ReconcileBulk (New-ReconcileBulk -Identities ($known+@((New-Identity $missing),$earlyId,$lateId))))
            Expect ((Read-TestDb "SELECT details FROM sync_state WHERE scope='directory';")[0].details -match ';gap=2(;|$)') 'P22 identity changed after the pass checkpoint (uSNChanged 101 > 100) is not a gap'
            $gapRows=@(Read-TestDb 'SELECT * FROM ad_census_gaps ORDER BY object_guid;')
            Expect ($gapRows.Count -eq 2 -and $gapRows[0].object_guid -eq $missing.Guid -and $gapRows[1].object_guid -eq $early.Guid -and $gapRows[1].usn -eq 100 -and $gapRows[0].dn -eq $missing.DN -and $gapRows[0].noticed_at -eq '2026-10-06T00:00:00Z') 'P22 missing identities kept with DN, USN and date; the late one left to the next delta'
            # A complete read of the domain that a limit cuts keeps the list and never blocks the next delta.
            $cut=New-ReconcileBulk -Rows @($kept) -Mode Rows -Complete $false;$cut.SyncScope='directory'
            [void](Invoke-ReconcileBulk $cut)
            Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_census_gaps;')[0].n -eq 2 -and (Read-TestDb "SELECT highest_usn FROM sync_state WHERE scope='directory';")[0].highest_usn -eq 100) 'P22 a cut complete read keeps the gaps and the domain checkpoint'
            $next=New-ReconcileBulk -Identities ($known+@((New-Identity $missing),$earlyId));$next.HighestUsn=120;$next.At='2026-10-07T00:00:00Z'
            [void](Invoke-ReconcileBulk $next)
            $sync=(Read-TestDb "SELECT highest_usn,last_sync,details FROM sync_state WHERE scope='directory';")[0]
            Expect ($sync.highest_usn -eq 120 -and $sync.last_sync -eq '2026-10-07T00:00:00Z' -and $sync.details -match ';gap=2(;|$)') 'P22 the next delta commits and advances its checkpoint while gaps remain'
            # Explicit read by GUID: a found identity is added with its facts; an unread one stays to read.
            $gapRecord=[pscustomobject]@{Type='Machine';Guid=$missing.Guid;Name='PC-37';Login='PC-37$';Upn='';Display='';Description='';Extra='';State='Actif';DN=$missing.DN;WhenChanged='';Usn=90;LastLogon='';Facts=$true;OsVersion='10.0 (26100)';WhenCreated='2025-01-02T08:00:00Z';PwdLastSet='2026-09-01T12:00:00Z';LapsKind='Windows';LapsExpiry='2026-11-01T00:00:00Z'}
            $gapResults=@(
                [pscustomobject]@{Guid=$missing.Guid;Status='Visible';FoundDn=$missing.DN;Detail='Lu par GUID.';CheckedAt='2026-10-08T00:00:00.0000000Z';Record=$gapRecord;Gap=$true}
                [pscustomobject]@{Guid=$early.Guid;Status='NonConfirme';FoundDn='';Detail='Non lu.';CheckedAt='2026-10-08T00:00:00.0000000Z';Record=$null;Gap=$true}
            )
            $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='DirectoryAbsence';Row=[pscustomobject]@{Results=$gapResults;Server='dc.test';At='2026-10-08T00:00:00Z';Source='CensusGap'}})}
            Expect ([bool](& ([scriptblock]::Create($worker))).Saved) 'P22 read of missing identities committed'
            $added=@(Read-TestDb ("SELECT * FROM ad_objects WHERE object_key='"+$missing.Guid+"';"))
            Expect ($added.Count -eq 1 -and $added[0].distinguished_name -eq $missing.DN -and $added[0].synced_at -eq '2026-10-08T00:00:00.0000000Z') 'P22 found identity added under its GUID key'
            $addedFacts=@(Read-TestDb ("SELECT * FROM ad_computer_facts WHERE object_guid='"+$missing.Guid+"';"))
            Expect ($addedFacts.Count -eq 1 -and $addedFacts[0].os_version -eq '10.0 (26100)' -and $addedFacts[0].laps_kind -eq 'Windows' -and $addedFacts[0].read_at -eq '2026-10-08T00:00:00.0000000Z') 'P22 found computer added with its facts'
            $left=@(Read-TestDb 'SELECT object_guid FROM ad_census_gaps;')
            Expect ($left.Count -eq 1 -and $left[0].object_guid -eq $early.Guid) 'P22 found identity leaves the list, unread one stays'
            Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_absences WHERE object_guid IN ('"+$missing.Guid+"','"+$early.Guid+"');"))[0].n -eq 0) 'P22 a gap read never writes an absence'
            $Payload=[pscustomobject]@{Action='DirectorySync';Path=$path;BusyTimeoutMs=250;DomainDn='DC=test'}
            $gapList=& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
            Expect ([long]$gapList.GapTotal -eq 1 -and @($gapList.Gaps).Count -eq 1 -and @($gapList.Gaps)[0].object_guid -eq $early.Guid -and @($gapList.Gaps)[0].dn -eq $early.DN) 'P22 local read lists the identities still missing, with an exact total'
            $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='DirectoryAbsence';Row=[pscustomobject]@{Results=@();Server='dc.test';At='2026-10-08T00:00:00Z';Source='CensusGap'}})}
            $Payload.Items[0].Row.Results=@([pscustomobject]@{Guid=$early.Guid;Status='Supprime';FoundDn='';Detail='x';CheckedAt='2026-10-08T00:00:00Z';Record=$null;Gap=$true})
            $refused=$false;try{& ([scriptblock]::Create($worker))|Out-Null}catch{$refused=$true}
            Expect ($refused -and (Read-TestDb 'SELECT count(*) AS n FROM ad_census_gaps;')[0].n -eq 1) 'P22 a deletion is never concluded from a gap read'
            # A complete read of the OU that holds a missing identity, without bringing it: it is no longer visible there.
            [void](Invoke-ReconcileBulk (New-ReconcileBulk -Rows @((New-ReconcileRow 37 'CN=PC-37,OU=C,DC=test')) -Scope 'OU=C,DC=test' -Mode Rows))
            Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_census_gaps;')[0].n -eq 0) 'P22 a complete OU read clears the missing identities of its scope'
            Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_absences WHERE object_guid='"+$missing.Guid+"';"))[0].n -eq 0) 'P22 the identity read by GUID stays in the local copy'
            function New-SnapshotItem {param([string]$Id,[string]$Label,[string]$At);return [pscustomobject]@{Kind='DirectorySnapshot';Row=[pscustomobject]@{Action='Capture';SnapshotId=$Id;Label=$Label;DomainDn='DC=test';ScopeDn='OU=A,DC=test';Subtree=$true;CapturedUtc=$At;CoverageState='Complete';CoverageAtUtc='2026-10-06T00:00:00.0000000Z';CoverageSource='OU=A,DC=test';CoverageText='Couverture : lecture complete.'}}}
            $Payload=[pscustomobject]@{Path=$path;Items=@((New-SnapshotItem ('a'*32) 'Avant' '2026-10-08T00:00:00.0000000Z'))}
            Expect ([bool](& ([scriptblock]::Create($worker))).Saved) 'P30 snapshot committed'
            $manifest=@(Read-TestDb ("SELECT * FROM ad_snapshots WHERE snapshot_id='"+('a'*32)+"';"))
            Expect ($manifest.Count -eq 1 -and $manifest[0].object_count -eq 1 -and $manifest[0].rows_sha256 -match '^[0-9A-F]{64}$' -and $manifest[0].coverage_state -eq 'Complete') 'P30 manifest with exact count, fingerprint and coverage'
            # The streamed fingerprint keeps its definition: SHA-256 of the copied values in GUID order, fields separated by
            # char 31, one line (char 10) per object.
            $snapRow=(Read-TestDb ("SELECT * FROM ad_snapshot_rows WHERE snapshot_id='"+('a'*32)+"';"))[0]
            $lineText=(@('object_guid','object_type','name','login','upn','display_name','description','extra','state','distinguished_name','when_changed','last_logon','source_dc','synced_at')|ForEach-Object{[string]$snapRow.$_}) -join [string][char]31
            $sha=[Security.Cryptography.SHA256]::Create();try{$expectedSha=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lineText+[string][char]10))).Replace('-','')}finally{$sha.Dispose()}
            Expect ($manifest[0].rows_sha256 -ceq $expectedSha) 'P30 fingerprint computed over the copied values in GUID order'
            Expect ($snapRow.object_guid -ceq $kept.Guid.ToLowerInvariant() -and $snapRow.distinguished_name -eq $kept.DN) 'P30 copied row keeps the lower-case GUID and the DN'
            $Payload=[pscustomobject]@{Path=$path;Items=@((New-SnapshotItem ('a'*32) 'Doublon' '2026-10-08T00:00:00.0000000Z'))}
            Expect ([bool](& ([scriptblock]::Create($worker))).Saved -and (Read-TestDb 'SELECT count(*) AS n FROM ad_snapshots;')[0].n -eq 1) 'P30 a retried capture does not copy twice and never blocks the queue'
            Write-Batch @((New-ReconcileRow 31 'CN=PC-31,OU=Sub,OU=A,DC=test' 'Desactive'),(New-ReconcileRow 35 'CN=PC-35,OU=A,DC=test')) '2026-10-09T00:00:00Z' -Scope 'ou:ou=a,dc=test'
            $Payload=[pscustomobject]@{Path=$path;Items=@((New-SnapshotItem ('b'*32) 'Apres' '2026-10-10T00:00:00.0000000Z'))}
            [void](& ([scriptblock]::Create($worker)))
            $Payload=[pscustomobject]@{Action='SnapshotCompare';Path=$path;BusyTimeoutMs=250;DomainDn='DC=test';Before=('a'*32);After=('b'*32);Limit=10}
            $cmp=& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
            Expect ([bool]$cmp.Found -and $cmp.Counts.Added -eq 1 -and $cmp.Counts.Disappeared -eq 0 -and $cmp.Counts.Common -eq 1 -and $cmp.Counts.Differing -eq 1) 'P30 exact totals computed by SQLite'
            $pair=@($cmp.Pairs)[0]
            Expect ($pair.Before.distinguished_name -eq 'CN=PC-31,OU=A,DC=test' -and $pair.After.distinguished_name -eq 'CN=PC-31,OU=Sub,OU=A,DC=test' -and $pair.After.state -eq 'Desactive') 'P30 move and changed value paired by GUID'
            Expect (@($cmp.Added)[0].name -eq 'PC-35') 'P30 added object listed'
            $Payload=[pscustomobject]@{Action='SnapshotCompare';Path=$path;BusyTimeoutMs=250;DomainDn='DC=test';Before=('a'*32);After=('c'*32);Limit=10}
            Expect (-not [bool](& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))).Found) 'P30 a missing snapshot is reported, not compared'
            $Payload=[pscustomobject]@{Action='DirectorySync';Path=$path;BusyTimeoutMs=250;DomainDn='DC=test'}
            $list=& ([scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode)))
            Expect (@($list.Snapshots).Count -eq 2 -and [long]$list.AbsenceTotal -eq 1 -and @($list.Absences)[0].status -eq 'Supprime') 'P24 and P30 local read lists absences and snapshots'
            $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='DirectorySnapshot';Row=[pscustomobject]@{Action='Delete';SnapshotId=('a'*32)}})}
            [void](& ([scriptblock]::Create($worker)))
            Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_snapshot_rows WHERE snapshot_id='"+('a'*32)+"';"))[0].n -eq 0 -and (Read-TestDb 'SELECT count(*) AS n FROM ad_snapshots;')[0].n -eq 1) 'P30 snapshot deleted with its rows only'
            # Points 22, 24 and 30: storage management sees the directory copies; they are measured and purged with the index.
            $directoryCopies=@('ad_absences','ad_census_gaps','ad_snapshots','ad_snapshot_rows')
            $Payload=[pscustomobject]@{Path=$path}
            $usage=& ([scriptblock]::Create((Get-DomeniaStorageUsageWorkerCode)))
            $indexUsage=@($usage.Categories|Where-Object{$_.Category -eq 'Index'})[0]
            foreach($table in $directoryCopies){
                $measured=@($indexUsage.Tables|Where-Object{$_.Table -eq $table})
                Expect ($measured.Count -eq 1 -and $measured[0].State -eq 'Mesure' -and $measured[0].Rows -eq (Read-TestDb ('SELECT count(*) AS n FROM '+$table+';'))[0].n) ('Index usage measures '+$table)
            }
            $Payload=[pscustomobject]@{Path=$path;Selection=@('Index');DryRun=$true}
            $preview=& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))
            foreach($table in $directoryCopies){
                $counted=@($preview.Counts|Where-Object{$_.Table -eq $table})
                Expect ($counted.Count -eq 1 -and $counted[0].Category -eq 'Index' -and [bool]$counted[0].Exists -and $counted[0].Rows -eq (Read-TestDb ('SELECT count(*) AS n FROM '+$table+';'))[0].n) ('Index purge dry run counts '+$table)
            }
            Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_snapshot_rows;')[0].n -gt 0 -and (Read-TestDb 'SELECT count(*) AS n FROM ad_absences;')[0].n -gt 0) 'Index purge dry run removes nothing'
            $Payload=[pscustomobject]@{Path=$path;Selection=@('Index');DryRun=$false;ExpectedFingerprint=$preview.Fingerprint}
            Expect ([bool](& ([scriptblock]::Create((Get-DomeniaStoragePurgeWorkerCode)))).Committed) 'Index purge committed'
            foreach($table in @('ad_objects')+$directoryCopies){Expect ((Read-TestDb ('SELECT count(*) AS n FROM '+$table+';'))[0].n -eq 0) ('Index purge empties '+$table)}
        }finally{
            $path=$reconcilePath
            foreach($suffix in @('','-wal','-shm')){$candidate=Join-Path $folder ('directory-sync.sqlite'+$suffix);if([IO.File]::Exists($candidate)){[IO.File]::Delete($candidate)}}
        }
        # Point 30: a domain-wide snapshot of 50 000 objects runs in its own storage batch, copied by SQLite and hashed in
        # one streamed read. Its time is measured; escaped commas never fake an RDN boundary.
        $benchPath=Join-Path $folder 'snapshot-bench.sqlite'
        $db=Open-DomeniaDatabase $benchPath;try{[void](Invoke-DomeniaDbExec $schema $db)}finally{Close-DomeniaDatabase $db}
        try{
            $columns='object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at'
            $generated="WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<50000) SELECT printf('50000000-0000-4000-8000-%012d',i),printf('50000000-0000-4000-8000-%012d',i),'Machine','PC-'||i,'PC-'||i||'$','pc-'||i||'.test','','Poste '||i,'Windows 11','Actif','CN=PC-'||i||',OU=Site-'||(i%50)||',OU=Bench,DC=test','',i,'','pc-'||i,'dc.test','2026-10-01T00:00:00Z' FROM n;"
            $edges="INSERT INTO ad_objects($columns) VALUES('60000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001','Machine','Trap','Trap$','','','','','Actif','CN=Trap\,OU=Bench,DC=test','',1,'','trap','dc.test','2026-10-01T00:00:00Z');"+
                "INSERT INTO ad_objects($columns) VALUES('60000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002','Machine','Slash','Slash$','','','','','Actif','CN=Slash\\,OU=Bench,DC=test','',1,'','slash','dc.test','2026-10-01T00:00:00Z');"+
                "INSERT INTO ad_objects($columns) VALUES('60000000-0000-4000-8000-000000000003','60000000-0000-4000-8000-000000000003','Machine','Comma','Comma$','','','','','Actif','CN=Comma\,Name,OU=Bench,DC=test','',1,'','comma','dc.test','2026-10-01T00:00:00Z');"+
                "INSERT INTO ad_objects($columns) VALUES('60000000-0000-4000-8000-000000000004','60000000-0000-4000-8000-000000000004','Machine','Other','Other$','','','','','Actif','CN=Other,OU=Bench2,DC=test','',1,'','other','dc.test','2026-10-01T00:00:00Z');"
            $db=Open-DomeniaDatabase $benchPath;try{[void](Invoke-DomeniaDbExec ("INSERT INTO ad_objects($columns) "+$generated+$edges) $db)}finally{Close-DomeniaDatabase $db}
            $savedPath=$path;$path=$benchPath
            try{
                Expect ((Read-TestDb 'SELECT count(*) AS n FROM ad_objects;')[0].n -eq 50004) 'P30 bench base holds 50 000 objects and four edge cases'
                $item=[pscustomobject]@{Kind='DirectorySnapshot';Row=[pscustomobject]@{Action='Capture';SnapshotId=('d'*32);Label='Bench';DomainDn='DC=test';ScopeDn='OU=Bench,DC=test';Subtree=$true;CapturedUtc='2026-10-11T00:00:00.0000000Z';CoverageState='Complete';CoverageAtUtc='2026-10-10T00:00:00.0000000Z';CoverageSource='DC=test';CoverageText='Couverture : lecture complete.';ObjectEstimate=50004}}
                $Payload=[pscustomobject]@{Path=$benchPath;Items=@($item)}
                $timer=[Diagnostics.Stopwatch]::StartNew();$answer=& ([scriptblock]::Create($worker));$timer.Stop()
                Expect ([bool]$answer.Saved) 'P30 bench snapshot committed'
                $bench=@(Read-TestDb ("SELECT * FROM ad_snapshots WHERE snapshot_id='"+('d'*32)+"';"))
                # 50 000 objects of the OU tree plus CN=Slash\\ (escaped backslash, then a real boundary) and CN=Comma\,Name;
                # CN=Trap\, (escaped comma) belongs to the domain head, not to the OU.
                Expect ($bench.Count -eq 1 -and $bench[0].object_count -eq 50002 -and $bench[0].rows_sha256 -match '^[0-9A-F]{64}$') ('P30 bench snapshot exact count: '+$bench[0].object_count)
                Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_snapshot_rows WHERE snapshot_id='"+('d'*32)+"' AND object_guid IN ('60000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000004');"))[0].n -eq 0) 'P30 escaped comma and neighbouring OU stay outside the scope'
                Expect ((Read-TestDb ("SELECT count(*) AS n FROM ad_snapshot_rows WHERE snapshot_id='"+('d'*32)+"' AND object_guid IN ('60000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000003');"))[0].n -eq 2) 'P30 escaped backslash and escaped comma in a name stay inside the scope'
                # The old path took about 2 ms per row in PowerShell (over 100 s here) inside a 120 s batch shared with every save.
                Expect ($timer.ElapsedMilliseconds -lt 60000) ('P30 50 000-object snapshot within 60 s: '+$timer.ElapsedMilliseconds+' ms')
                Write-Output ('BENCH snapshot 50 000 objects (SQL copy + streamed SHA-256): '+$timer.ElapsedMilliseconds+' ms; local SQLite only')
                # Direct children only: deeper objects and an escaped comma that is not a boundary are told apart.
                $item.Row.SnapshotId=('e'*32);$item.Row.Subtree=$false;$item.Row.Label='Niveau direct'
                [void](& ([scriptblock]::Create($worker)))
                $direct=@(Read-TestDb ("SELECT object_guid FROM ad_snapshot_rows WHERE snapshot_id='"+('e'*32)+"' ORDER BY object_guid;"))
                Expect ($direct.Count -eq 2 -and $direct[0].object_guid -eq '60000000-0000-4000-8000-000000000002' -and $direct[1].object_guid -eq '60000000-0000-4000-8000-000000000003') ('P30 direct-children snapshot keeps the two direct children only: '+$direct.Count)
            }finally{$path=$savedPath}
        }finally{
            foreach($suffix in @('','-wal','-shm')){$candidate=Join-Path $folder ('snapshot-bench.sqlite'+$suffix);if([IO.File]::Exists($candidate)){[IO.File]::Delete($candidate)}}
        }
    }finally{
        $path=$originalPath
        foreach($suffix in @('','-wal','-shm')){$candidate=Join-Path $folder ('reconcile.sqlite'+$suffix);if([IO.File]::Exists($candidate)){[IO.File]::Delete($candidate)}}
    }

    # Synthetic AD provider exercises the actual delta/census serializer, without a network.
    $script:mockIndexQueries=[Collections.Generic.List[object]]::new()
    $script:mockIndexScenario='complete';$script:mockIndexVersionCalls=0;$script:mockIndexUsn=100
    function Get-WDirectoryVersionSource {
        param($Context)
        $script:mockIndexVersionCalls++
        if($script:mockIndexScenario -eq 'instance-change' -and $script:mockIndexVersionCalls -gt 1){return 'dc.test|instance-2'}
        return 'dc.test|instance-1'
    }
    function New-WRootDse {
        param($Context)
        $r=[pscustomobject]@{Properties=@{highestCommittedUSN=@{Value=$script:mockIndexUsn};schemaNamingContext=@{Value=''}}}
        $r|Add-Member ScriptMethod RefreshCache {param($Names)};return $r
    }
    function New-WSearcher {
        param($Context,$BaseDn,$Filter,$Properties,$Scope,$Limit)
        $isCensus=(@($Properties).Count -eq 3 -and $Properties -contains 'objectGUID' -and $Properties -contains 'distinguishedName' -and $Properties -contains 'uSNChanged')
        $s=[pscustomobject]@{PageSize=0;CacheResults=$true;ServerTimeLimit=$null;ClientTimeout=$null;Filter=$Filter;IsCensus=$isCensus;Properties=$Properties;Base=$BaseDn;Scope=$Scope}
        $s|Add-Member ScriptMethod FindAll {
            $script:mockIndexUsn=999
            $one=[pscustomobject]@{Properties=@{name='PC-1';distinguishedname='CN=PC-1,DC=test';objectguid='00000000-0000-0000-0000-000000000001';useraccountcontrol=2;usnchanged=95}}
            if($this.IsCensus){
                if($script:mockIndexScenario -eq 'failure'){throw 'provider interrupted'}
                if($script:mockIndexScenario -eq 'empty'){return ,@()}
                if($script:mockIndexScenario -eq 'invalid'){$one.Properties.objectguid='bad'}
                if($script:mockIndexScenario -eq 'outside'){$one.Properties.distinguishedname='CN=PC-1,DC=other'}
                if($script:mockIndexScenario -eq 'duplicate'){return ,@($one,$one)}
                if($script:mockIndexScenario -eq 'limit'){$two=[pscustomobject]@{Properties=@{objectguid='00000000-0000-0000-0000-000000000002';distinguishedname='CN=PC-2,DC=test'}};return ,@($one,$two)}
                return ,@($one)
            }
            if($this.Filter -match 'objectCategory=computer'){return ,@($one)}
            return ,@()
        }
        $s|Add-Member ScriptMethod Dispose {};[void]$script:mockIndexQueries.Add($s);return $s
    }
    $Context=[pscustomobject]@{BaseDn='DC=test';Server='dc.test'}
    foreach($scenario in @('complete','failure','empty','invalid','outside','duplicate','limit','instance-change')){
        $script:mockIndexScenario=$scenario;$script:mockIndexVersionCalls=0;$script:mockIndexUsn=100;$script:mockIndexQueries.Clear()
        $Payload=[pscustomobject]@{Path=$path;Progress=$progress;MaxObjects=$(if($scenario -eq 'limit'){1}else{0});BudgetMs=30000;LastUsn=10;LastServer='dc.test';LastInvocationId='instance-1';Since='';ComputerFirst=$false}
        $result=& ([scriptblock]::Create((Get-DomeniaIndexWorkerCode)))
        Expect ($result.RowCount -eq 1 -and $result.Transfer.RowCount -eq 1 -and $result.ComputerCount -eq 1) ('serializer object counts '+$scenario)
        Expect ($result.HighestUsn -eq 100) ('checkpoint remains before both reads '+$scenario)
        if($scenario -eq 'complete'){
            Expect (-not $result.Truncated -and $result.Reconcile.Complete -and $result.Transfer.CensusRowCount -eq 1) 'complete census receipt from real worker'
            Expect ($script:mockIndexQueries.Count -eq 3 -and $script:mockIndexQueries[2].IsCensus) 'lightweight census follows two attribute delta reads'
            Expect ($script:mockIndexQueries[2].Filter -notmatch 'uSNChanged' -and @($script:mockIndexQueries[2].Properties).Count -eq 3) 'census reads every identity with only GUID, DN and uSNChanged, never filtered by USN'
            $lines=@(Get-Content -LiteralPath $result.Transfer.Path)
            $identityLine=$lines[1]|ConvertFrom-Json
            Expect ($lines.Count -eq 2 -and $identityLine.Kind -eq 'Identity') 'one mixed spool retains distinct identity marker'
            Expect ([long]$identityLine.Usn -eq 95) 'P22 census identity carries its uSNChanged to bound the gap'
            Expect ($result.Transfer.Sha256 -eq (Get-FileHash $result.Transfer.Path).Hash) 'mixed serializer digest binds every byte'
        }else{Expect ($result.Truncated -and -not $result.Reconcile.Complete) ('unsafe census remains partial '+$scenario)}
        [IO.File]::Delete($result.Transfer.Path)
    }
    [IO.Directory]::Delete($spool)

    # PF-07 (lot X06): the prepared statements write exactly the values of the former text SQL (quotes, Unicode, empty
    # text, 64-bit numbers), keep the search key formula, and the reconciliation keeps a row made newer than the read.
    $parityPath=Join-Path $folder 'parity.sqlite'
    $db=Open-DomeniaDatabase -Path $parityPath;try{[void](Invoke-DomeniaDbExec $schema $db)}finally{Close-DomeniaDatabase $db}
    function Read-ParityDb {param([string]$Sql);$db=Open-DomeniaDatabase -Path $parityPath;try{return @(Invoke-DomeniaDbQuery $Sql $db)}finally{Close-DomeniaDatabase $db}}
    function Write-ParityItem {param($Item);$Payload=[pscustomobject]@{Path=$parityPath;Items=@($Item)};return & ([scriptblock]::Create($worker))}
    try{
        $g1='11111111-1111-1111-1111-111111111111';$g2='22222222-2222-2222-2222-222222222222';$g3='33333333-3333-3333-3333-333333333333'
        $tricky=[pscustomobject]@{Guid=$g1;Type='Utilisateur';Name="O'Brien ; DROP TABLE ad_objects; --";Login="o'brien";Upn="éléonore.o'brien@exemple.test";Display=('Élodie '+[char]0x00AB+'Σ'+[char]0x00BB+' '+[char]::ConvertFromUtf32(0x1F642));Description='';Extra=('ligne'+[char]10+'suivante');State='Actif';DN='CN=O\,Brien,OU=A,DC=test';WhenChanged='2026-10-01T00:00:00Z';Usn=9007199254740993;LastLogon=''}
        $machine=[pscustomobject]@{Guid=$g2;Type='Machine';Name='PC-2';Login='PC-2$';DN='CN=PC-2,OU=A,DC=test';State='Desactive';Usn=7;Facts=$true;OsVersion='26100';WhenCreated='2026-01-01T00:00:00Z';PwdLastSet='';LapsKind="Windows LAPS 'chiffré'";LapsExpiry=''}
        $answer=Write-ParityItem ([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=@($tricky,$machine);At='2026-10-10T00:00:00Z';Server='dc.test';BaseDn='DC=test';SyncScope='directory';Complete=$true;ReplaceAll=$false;HighestUsn=11;InvocationId='instance-1'}})
        Expect ([bool]$answer.Saved -and [long]$answer.IndexRows -eq 2 -and [long]$answer.IndexWriteMs -ge 0) 'PF-07 receipt counts the rows and the write time'
        $row=@(Read-ParityDb ("SELECT * FROM ad_objects WHERE object_guid='$g1';"))[0]
        foreach($pair in @(@('name',$tricky.Name),@('login',$tricky.Login),@('upn',$tricky.Upn),@('display_name',$tricky.Display),@('description',''),@('extra',$tricky.Extra),@('distinguished_name',$tricky.DN),@('source_dc','dc.test'),@('synced_at','2026-10-10T00:00:00Z'))){
            Expect ([string]$row.($pair[0]) -ceq [string]$pair[1]) ('PF-07 exact text: '+$pair[0])
        }
        Expect ($row.usn_changed -is [long] -and $row.usn_changed -eq 9007199254740993) 'PF-07 64-bit number kept as INTEGER'
        Expect ([string]$row.search_key -ceq ($tricky.Name+' '+$tricky.Login+' '+$tricky.Upn+' '+$tricky.Display+' '+' '+$tricky.Extra).ToLowerInvariant()) 'PF-07 search key formula unchanged'
        Expect ((Read-ParityDb "SELECT typeof(description) AS t FROM ad_objects WHERE object_guid='$g1';")[0].t -eq 'text') 'PF-07 empty text stays TEXT, never NULL'
        $facts=@(Read-ParityDb "SELECT * FROM ad_computer_facts WHERE object_guid='$g2';")[0]
        Expect ([string]$facts.laps_kind -ceq $machine.LapsKind -and [string]$facts.object_key -ceq $g2 -and [string]$facts.read_at -ceq '2026-10-10T00:00:00Z') 'PF-07 facts row written through its statement'
        # Reconciliation (Rows) with guarded prepared statements: the row absent from the read is deleted in the scope,
        # a row written after the read started keeps its newer value, the other rows take the read.
        [void](Write-ParityItem ([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=@([pscustomobject]@{Guid=$g3;Type='Machine';Name='PC-3';DN='CN=PC-3,OU=A,DC=test';State='Actif';Usn=8});At='2026-10-11T00:00:00Z';Server='dc.test';BaseDn='DC=test';SyncScope='directory';Complete=$true;ReplaceAll=$false;HighestUsn=12;InvocationId='instance-1'}}))
        $reconcile=[pscustomobject]@{Mode='Rows';SearchScope='Subtree';ScopeDn='OU=A,DC=test';Server='dc.test';InvocationId='instance-1';Complete=$true;ExpectedCount=2;StartedUtc='2026-10-10T12:00:00Z'}
        $rows=@([pscustomobject]@{Guid=$g1;Type='Utilisateur';Name='OBrien-lu';DN=$tricky.DN;State='Actif';Usn=20},[pscustomobject]@{Guid=$g3;Type='Machine';Name='PC-3-ancien';DN='CN=PC-3,OU=A,DC=test';State='Actif';Usn=8})
        $answer=Write-ParityItem ([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=$rows;At='2026-10-12T00:00:00Z';Server='dc.test';BaseDn='OU=A,DC=test';SyncScope='ou:ou=a,dc=test';Complete=$true;ReplaceAll=$false;HighestUsn=21;InvocationId='instance-1';Reconcile=$reconcile}})
        Expect ([bool]$answer.Saved) 'PF-07 reconciliation committed'
        Expect ((Read-ParityDb "SELECT name FROM ad_objects WHERE object_guid='$g1';")[0].name -ceq 'OBrien-lu') 'PF-07 reconciled row updated'
        Expect ((Read-ParityDb "SELECT name FROM ad_objects WHERE object_guid='$g3';")[0].name -ceq 'PC-3') 'PF-07 newer row kept against an older read'
        Expect ((Read-ParityDb "SELECT count(*) AS n FROM ad_objects WHERE object_guid='$g2';")[0].n -eq 0) 'PF-07 row absent from the read deleted in its scope'
        Expect ((Read-ParityDb "SELECT count(*) AS n FROM ad_computer_facts WHERE object_guid='$g2';")[0].n -eq 0) 'PF-07 facts of the deleted row removed'
        # Point 24 with PF-07: the row absent from the read is recorded as not seen (never deleted) by a prepared statement.
        $absence=@(Read-ParityDb "SELECT * FROM ad_absences WHERE object_guid='$g2';")
        Expect ($absence.Count -eq 1 -and [string]$absence[0].status -ceq 'NonVu' -and [string]$absence[0].last_dn -ceq $machine.DN -and [string]$absence[0].scope_dn -ceq 'OU=A,DC=test' -and [string]$absence[0].noticed_at -ceq '2026-10-12T00:00:00Z' -and [string]$absence[0].server -ceq 'dc.test') 'P24 absence written by the prepared statement of the reconciliation'
        # PF-26: the directory copies of points 22, 24 and 30 are created once per worker session, never by a lot.
        foreach($table in @('ad_absences','ad_census_gaps','ad_snapshots','ad_snapshot_rows')){
            Expect (([regex]::Matches($worker,'CREATE TABLE IF NOT EXISTS '+$table+'\(')).Count -eq 1) ('PF-26 '+$table+' created by the session check only')
            Expect ((Read-ParityDb ("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='"+$table+"';"))[0].n -eq 1) ('PF-26 '+$table+' present after the first session')
        }
        # BitLocker presence of an OU: prepared read and write; a known key count survives a read that saw nothing.
        $secretRows=@([pscustomobject]@{Computer='pc-2';At='2026-10-12T00:00:00Z';BitLockerKeys=2;BitLockerLast='2026-10-01';LapsScheme='';LapsExpiry='';Verdict='OK'},[pscustomobject]@{Computer='PC-2';At='2026-10-13T00:00:00Z';BitLockerKeys=0;BitLockerLast='';LapsScheme='';LapsExpiry='';Verdict='Aucune cle';KeepKnown=$true},[pscustomobject]@{Computer="PC-'quote";At='2026-10-13T00:00:00Z';BitLockerKeys=-1;BitLockerLast='';LapsScheme='Windows LAPS';LapsExpiry='2026-11-01';Verdict='LAPS'})
        $answer=Write-ParityItem ([pscustomobject]@{Kind='SecretMeta';Row=[pscustomobject]@{Rows=$secretRows}})
        $secret=@(Read-ParityDb 'SELECT * FROM secret_state ORDER BY computer_key;')
        Expect ([bool]$answer.Saved -and $secret.Count -eq 2) 'PF-07 one secret row per workstation'
        $pc2=@($secret|Where-Object{$_.computer_key -ceq 'PC-2'})[0]
        Expect ([long]$pc2.bitlocker_keys -eq 2 -and [string]$pc2.verdict -ceq 'OK') 'PF-07 known BitLocker count kept by the prepared read'
        $quoted=@($secret|Where-Object{$_.computer_key -ceq "PC-'QUOTE"})[0]
        Expect ([long]$quoted.bitlocker_keys -eq -1 -and [string]$quoted.laps_scheme -ceq 'Windows LAPS') 'PF-07 unknown BitLocker count stays -1 for a first row'
    }finally{foreach($suffix in @('','-wal','-shm')){if([IO.File]::Exists($parityPath+$suffix)){[IO.File]::Delete($parityPath+$suffix)}}}

    Write-Output ('PASS Index persistence and cache: '+$script:checks+' assertions; native local SQLite, no AD or VM')
}finally{
    foreach($file in @('test.sqlite','test.sqlite-wal','test.sqlite-shm')){$candidate=Join-Path $folder $file;if([IO.File]::Exists($candidate)){[IO.File]::Delete($candidate)}}
    if([IO.Directory]::Exists($folder) -and -not [IO.Directory]::EnumerateFileSystemEntries($folder).GetEnumerator().MoveNext()){[IO.Directory]::Delete($folder)}
}
