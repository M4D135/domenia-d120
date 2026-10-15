#requires -Version 5.1
# Runs the actual storage worker against a disposable local SQLite database.
# macOS uses Apple's SQLite ABI; this does not qualify Windows winsqlite3 or WPF.
$ErrorActionPreference='Stop'
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
Import-CoreFunction Initialize-DomeniaWinSqliteNative -Native
[void](Initialize-DomeniaWinSqliteNative)
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
    $schema=@($core.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -or $node -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true)|Where-Object{$_.Value -match '^PRAGMA journal_mode=WAL;' -and $_.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'})
    if($schema.Count -ne 1){throw ('Schema literal count '+$schema.Count)}
    $db=Open-DomeniaDatabase -Path $path;try{[void](Invoke-DomeniaDbExec $schema[0].Value $db)}finally{Close-DomeniaDatabase $db}
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
    $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schema[0].Value $db)}finally{Close-DomeniaDatabase $db}
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
        $isCensus=(@($Properties).Count -eq 2 -and $Properties -contains 'objectGUID' -and $Properties -contains 'distinguishedName')
        $s=[pscustomobject]@{PageSize=0;CacheResults=$true;ServerTimeLimit=$null;ClientTimeout=$null;Filter=$Filter;IsCensus=$isCensus;Properties=$Properties;Base=$BaseDn;Scope=$Scope}
        $s|Add-Member ScriptMethod FindAll {
            $script:mockIndexUsn=999
            $one=[pscustomobject]@{Properties=@{name='PC-1';distinguishedname='CN=PC-1,DC=test';objectguid='00000000-0000-0000-0000-000000000001';useraccountcontrol=2}}
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
            Expect ($script:mockIndexQueries[2].Filter -notmatch 'uSNChanged' -and @($script:mockIndexQueries[2].Properties).Count -eq 2) 'census reads every identity with only GUID and DN'
            $lines=@(Get-Content -LiteralPath $result.Transfer.Path)
            Expect ($lines.Count -eq 2 -and ($lines[1]|ConvertFrom-Json).Kind -eq 'Identity') 'one mixed spool retains distinct identity marker'
            Expect ($result.Transfer.Sha256 -eq (Get-FileHash $result.Transfer.Path).Hash) 'mixed serializer digest binds every byte'
        }else{Expect ($result.Truncated -and -not $result.Reconcile.Complete) ('unsafe census remains partial '+$scenario)}
        [IO.File]::Delete($result.Transfer.Path)
    }
    [IO.Directory]::Delete($spool)

    # PF-07 (lot X06): the prepared statements write exactly the values of the former text SQL (quotes, Unicode, empty
    # text, 64-bit numbers), keep the search key formula, and the reconciliation keeps a row made newer than the read.
    $parityPath=Join-Path $folder 'parity.sqlite'
    $db=Open-DomeniaDatabase -Path $parityPath;try{[void](Invoke-DomeniaDbExec $schema[0].Value $db)}finally{Close-DomeniaDatabase $db}
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
