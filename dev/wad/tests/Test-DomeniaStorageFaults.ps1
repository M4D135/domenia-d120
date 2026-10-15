#requires -Version 5.1
# Point 126: storage fault injection with verified recovery, on the production storage worker (pinned body, unchanged
# on disk) and disposable SQLite bases. Faults: base held by another Domenia instance, base locked in the same process,
# disk full (the real SQLITE_FULL of the engine through max_page_count, not a physically full volume), abrupt stop of
# the process before COMMIT, between COMMIT and the receipt returned to the interface, during the migration of legacy
# measures and during a full index rebuild. An abrupt stop is a real one: the worker runs in a child Windows PowerShell
# process that is terminated (Process.Kill) when it reaches the injection point, so no finally block, ROLLBACK or close
# runs; SQLite recovers the base when it is opened again. After every fault the suite checks PRAGMA integrity_check,
# the absence of partial rows and receipts, then replays the SAME batch and verifies that it is written exactly once.
# The injection points are found by exact text in the worker code; a missing anchor fails the case (worker changed).
# No AD, no network, no WPF. Not a Windows qualification by itself: the report says where it ran.
[CmdletBinding()]
param(
    [string]$ReportPath='',
    # Internal: child process modes started by this suite only.
    [ValidateSet('','holder','precommit','postcommit','import','index')][string]$FaultChild='',
    [string]$FaultDatabase='',
    [string]$FaultPayload='',
    [string]$FaultMarker=''
)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
$t=$null;$e=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse failed'}
$native=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Initialize-DomeniaWinSqliteNative')},$true))[0].Extent.Text
if($PSVersionTable.PSEdition -eq 'Core'){
    $native=$native.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$native=$native.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
    elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$native=$native.Replace('winsqlite3.dll','libsqlite3.so.0')}
}
. ([scriptblock]::Create($native));[void](Initialize-DomeniaWinSqliteNative)
# Same rule files as Test-DomeniaStore, plus the probe catalogue read by the query validation code of the worker.
foreach($name in @('Common.Model','Probes.Model','QueryLibrary.Model','Store.Model','Cache.Model','Storage.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
. (Join-Path (Join-Path $PSScriptRoot 'fixtures') 'Domenia-LoadFixtures.ps1')
$script:Worker=Get-DomeniaStorageWorkerCode
$ast=[Management.Automation.Language.Parser]::ParseInput($script:Worker,[ref]$t,[ref]$e)
if($e.Count){throw 'Worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$script:Domain='DC=example,DC=invalid'
# Exact text of the injection points in the storage worker body (Get-DomeniaStorageWorkerCode).
$script:Anchors=@{
    precommit="  [void](Invoke-DomeniaDbExec 'COMMIT;' `$db);`$transaction=`$false`n  # A second, read-only transaction observes committed rows, never in-memory collector objects."
    postcommit="  # A second, read-only transaction observes committed rows, never in-memory collector objects."
    import="        [void]`$sql.AppendLine('INSERT INTO domenia_legacy_observation_imports(object_guid,payload_hash,imported_at) VALUES('+((`$v|ForEach-Object{ConvertTo-DomeniaSqlLiteral `$_}) -join ',')+');')`n        [void](Invoke-DomeniaDbExec `$sql.ToString() `$Db)"
    # Index rows written as text batches (former body) or through prepared statements (PF-07): either text, once.
    index=@("      if((`$readCount % 256) -eq 0){[void](Invoke-DomeniaDbExec `$sqlBatch.ToString() `$db);[void]`$sqlBatch.Clear();if(`$null -ne `$progress){`$progress.Count=`$readCount}}",
            "      if(((`$readCount % 256) -eq 0) -and (`$null -ne `$progress)){`$progress.Count=`$readCount}")
    synchronous="[void](Invoke-DomeniaDbExec 'PRAGMA synchronous=FULL;' `$db)"
}
function Find-FaultAnchor {
    # The one text of an injection point present exactly once in the worker; alternatives cover reviewed versions.
    param([string]$Point)
    $found=@(foreach($candidate in @($script:Anchors[$Point])){if(([regex]::Matches($script:Worker,[regex]::Escape([string]$candidate))).Count -eq 1){[string]$candidate}})
    $present=@(foreach($candidate in @($script:Anchors[$Point])){if($script:Worker.Contains([string]$candidate)){[string]$candidate}})
    if(($found.Count -ne 1) -or ($present.Count -ne 1)){throw ('Point dʼinjection introuvable ou ambigu dans le worker de stockage : '+$Point+' ('+$present.Count+')')}
    return $found[0]
}
function Get-FaultWorkerCode {
    # Private copy of the worker with one statement inserted at an anchor that must appear exactly once.
    param([string]$Point,[string]$Hook)
    $anchor=Find-FaultAnchor $Point
    switch($Point){
        'precommit' {return $script:Worker.Replace($anchor,$Hook+"`n"+$anchor)}
        'postcommit' {return $script:Worker.Replace($anchor,$Hook+"`n"+$anchor)}
        'import' {return $script:Worker.Replace($anchor,$anchor+"`n"+$Hook)}
        'index' {return $script:Worker.Replace($anchor,$anchor+"`n      if(`$readCount -eq 512){"+$Hook+"}")}
        'synchronous' {return $script:Worker.Replace($anchor,$Hook)}
    }
    throw ('Point dʼinjection inconnu : '+$Point)
}

# ---------------------------------------------------------------- child process (killed by the parent)
if($FaultChild){
    $markerLiteral="'"+$FaultMarker.Replace("'","''")+"'"
    $stall="[IO.File]::WriteAllText($markerLiteral,'reached');Start-Sleep -Seconds 600"
    if($FaultChild -eq 'holder'){
        # Another Domenia instance holding the base: write lease and SQLite write lock, then it waits to be stopped.
        $db=Open-DomeniaDatabase $FaultDatabase
        [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;UPDATE domenia_store_state SET revision=revision WHERE id=1;' $db)
        & ([scriptblock]::Create($stall))
        exit 0
    }
    $code=Get-FaultWorkerCode -Point $FaultChild -Hook $stall
    # The parent writes plain values only; the payload is rebuilt here exactly as the interface builds it.
    $spec=[IO.File]::ReadAllText($FaultPayload)|ConvertFrom-Json
    if([string]$spec.Kind -eq 'StoreBatch'){
        $Payload=[pscustomobject]@{Path=[string]$spec.Path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=[string]$spec.Json;Hash=[string]$spec.Hash})}
    }elseif([string]$spec.Kind -eq 'IndexBulk'){
        $transfer=[pscustomobject]@{Path=[string]$spec.TransferPath;Sha256=[string]$spec.Sha256;RowCount=[long]$spec.RowCount}
        $Payload=[pscustomobject]@{Path=[string]$spec.Path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=@();Transfer=$transfer;At=[string]$spec.At;Server='dc.example.invalid';BaseDn=$script:Domain;Complete=$true;ReplaceAll=$true;HighestUsn=[long]$spec.HighestUsn}})}
    }else{exit 4}
    [void](& ([scriptblock]::Create($code)))
    # Reaching this line means the stall point was never met: the parent reports it.
    exit 3
}

# ---------------------------------------------------------------- parent
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-storage-faults-'+[guid]::NewGuid().ToString('N'))
$cases=[Collections.Generic.List[object]]::new();$script:Checks=0;$script:Stops=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Good,[string]$Name);$script:Checks++;if(-not $Good){throw $Name}}
function Case {param([string]$Name,[scriptblock]$Code)
    try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' @ '+$_.ScriptStackTrace)});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}
# The production schema is the text Get-DomeniaSqliteSchemaText returns (its here-string expands the query library
# schema): the function is taken from the core and run, never its raw literal.
$schemaAst=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Get-DomeniaSqliteSchemaText')},$true))
if($schemaAst.Count -ne 1){throw 'Schema de production introuvable.'}
. ([scriptblock]::Create($schemaAst[0].Extent.Text))
$script:SchemaText=Get-DomeniaSqliteSchemaText
function New-FaultBase {
    # One disposable base per case: production schema, then three computers committed by the real worker.
    param([string]$Name)
    if(($script:SchemaText -notmatch 'CREATE TABLE IF NOT EXISTS schema_info') -or ($script:SchemaText -match '\$\(')){throw 'Schema de production introuvable ou non developpe.'}
    $directory=Join-Path $folder $Name;[void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $directory 'faults.sqlite'
    $db=Open-DomeniaDatabase $path
    try{[void](Invoke-DomeniaDbExec $script:SchemaText $db)}finally{Close-DomeniaDatabase $db}
    # Not named $context: the worker reads an optional $Context (lock wait) from the calling scopes.
    $storeContext=[pscustomobject]@{Version=1;Path=$path;DomainDn=$script:Domain;StoreId=(Get-DomeniaStoreId $path $script:Domain);RequestId='faults';Generation=1;SessionEpoch=1;ScopeDn=$script:Domain;Subtree=$true}
    $base=[pscustomobject]@{Path=$path;Directory=$directory;Context=$storeContext}
    $changes=@(foreach($n in 1..3){New-FaultDirectoryChange (Get-DomeniaLoadComputer -Index $n)})
    $r=Invoke-FaultWorker $base (New-FaultBatch $base $changes)
    if(-not [bool]$r.Saved){throw 'Base de test non initialisee.'}
    return $base
}
function New-FaultDirectoryChange {
    param($Computer,[string]$At='2026-01-01T00:00:00Z')
    return [pscustomobject]@{Kind='DirectoryObject';Guid=$Computer.Guid;DN=$Computer.Dn;ObservedAtUtc=$At;Source='dc.example.invalid';Fields=@('Type','Name','State','Details');Data=[pscustomobject]@{Type='Machine';Name=$Computer.Name;State='Actif';Details=[pscustomobject]@{department='IT'}};Facts=[pscustomobject]@{OsVersion='26100';WhenCreated=$At}}
}
function New-FaultPing {
    param($Computer,[string]$At='2026-02-01T00:00:00Z',$Data=$null)
    if($null -eq $Data){$Data=[pscustomobject]@{Computer=$Computer.Name;Presence='En ligne'}}
    return [pscustomobject]@{Kind='Observation';Guid=$Computer.Guid;DN=$Computer.Dn;Family='Presence';AttemptedAtUtc=$At;ObservedAtUtc=$At;Status='Success';Error='';Data=$Data}
}
function New-FaultBatch {
    param($Base,[object[]]$Changes,[string]$Id=([guid]::NewGuid().ToString()))
    $batch=ConvertTo-DomeniaStoreBatch -Context $Base.Context -BatchId $Id -Sequence 1 -Changes $Changes
    return [pscustomobject]@{Path=$Base.Path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$batch.Json;Hash=$batch.Hash})}
}
function Invoke-FaultWorker {
    # The production worker body, in this process.
    param($Base,$Payload,[string]$Code=$script:Worker)
    return (& ([scriptblock]::Create($Code)))
}
function Read-FaultBase {param($Base,[string]$Sql);$db=Open-DomeniaDatabase $Base.Path;try{return @(Invoke-DomeniaDbQuery $Sql $db)}finally{Close-DomeniaDatabase $db}}
function Get-FaultState {
    # Revision, receipts and integrity read through a write connection: it runs the WAL recovery after a stop.
    param($Base,[string]$BatchId='')
    $db=Open-DomeniaDatabase $Base.Path
    try{
        $integrity=[string]@(Invoke-DomeniaDbQuery 'PRAGMA integrity_check;' $db)[0].integrity_check
        $revision=[long]@(Invoke-DomeniaDbQuery 'SELECT revision FROM domenia_store_state WHERE id=1;' $db)[0].revision
        $receipts=[long]@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM domenia_store_batches;' $db)[0].n
        $mine=0L;if($BatchId){$mine=[long]@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM domenia_store_batches WHERE batch_id='+(ConvertTo-DomeniaSqlLiteral $BatchId)+';') $db)[0].n}
        return [pscustomobject]@{Integrity=$integrity;Revision=$revision;Receipts=$receipts;BatchReceipts=$mine}
    }finally{Close-DomeniaDatabase $db}
}
function Get-FaultBatchId {param($Payload);return [string](($Payload.Items[0].Json|ConvertFrom-Json).BatchId)}
function ConvertTo-FaultChildSpec {
    # Plain values of a storage payload (no nested array), rebuilt by the child: nothing depends on how Windows
    # PowerShell 5.1 serialises arrays inside objects.
    param($Payload)
    $item=@($Payload.Items)[0]
    if([string]$item.Kind -eq 'StoreBatch'){return [pscustomobject]@{Kind='StoreBatch';Path=[string]$Payload.Path;Json=[string]$item.Json;Hash=[string]$item.Hash}}
    $row=$item.Row
    return [pscustomobject]@{Kind='IndexBulk';Path=[string]$Payload.Path;TransferPath=[string]$row.Transfer.Path;Sha256=[string]$row.Transfer.Sha256;RowCount=[long]$row.Transfer.RowCount;At=[string]$row.At;HighestUsn=[long]$row.HighestUsn}
}
function Start-FaultChild {
    # Starts this suite in a child process at one injection point and returns once the point is reached.
    param([string]$Mode,$Base,$Payload=$null,[string]$Name)
    $marker=Join-Path $Base.Directory ($Name+'.reached')
    $payloadFile=''
    if($null -ne $Payload){$payloadFile=Join-Path $Base.Directory ($Name+'.payload.json');[IO.File]::WriteAllText($payloadFile,((ConvertTo-FaultChildSpec $Payload)|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-FaultChild',$Mode,'-FaultDatabase',('"'+$Base.Path+'"'),'-FaultMarker',('"'+$marker+'"'))
    if($payloadFile){$arguments+=@('-FaultPayload',('"'+$payloadFile+'"'))}
    if($PSVersionTable.PSEdition -ne 'Core'){$arguments=@('-STA')+$arguments}
    $stdout=Join-Path $Base.Directory ($Name+'.out.txt');$stderr=Join-Path $Base.Directory ($Name+'.err.txt')
    $process=Start-Process -FilePath ((Get-Process -Id $PID).Path) -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null=$process.Handle
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists($marker)){
        if($process.WaitForExit(50)){throw ('Le processus enfant sʼest arrêté avant le point dʼinjection '+$Mode+' (code '+$process.ExitCode+') : '+[IO.File]::ReadAllText($stderr))}
        if($watch.Elapsed.TotalSeconds -gt 180){try{$process.Kill()}catch{};throw ('Point dʼinjection non atteint en 180 s : '+$Mode)}
    }
    return $process
}
function Stop-FaultChild {
    # Abrupt stop: TerminateProcess, no finally block, no ROLLBACK, no close in the child.
    param($Process,[string]$Mode)
    $Process.Kill();$Process.WaitForExit()
    $script:Stops.Add([pscustomobject]@{Mode=$Mode;ExitCode=$Process.ExitCode;StoppedUtc=[datetime]::UtcNow.ToString('o')})
}

try{
    [void][IO.Directory]::CreateDirectory($folder)
    Case 'Points dʼinjection presents une seule fois dans le worker de stockage livre' {
        foreach($point in @($script:Anchors.Keys)){[void](Find-FaultAnchor $point)}
        Expect (($script:SchemaText -match 'CREATE TABLE IF NOT EXISTS schema_info') -and ($script:SchemaText -notmatch '\$\(')) 'production schema found and expanded'
    }
    Case 'Base occupee par une autre instance : refus explicite, aucun recu, reprise apres son arret brutal' {
        $base=New-FaultBase 'holder';$before=Get-FaultState $base
        $c=Get-DomeniaLoadComputer -Index 1;$payload=New-FaultBatch $base @(New-FaultPing $c);$id=Get-FaultBatchId $payload
        $holder=Start-FaultChild 'holder' $base $null 'holder'
        try{
            $message='';try{[void](Invoke-FaultWorker $base $payload)}catch{$message=$_.Exception.Message}
            Expect ($message -match 'StorageBusy|SQLite code 5') ('refusal kept its category: '+$message)
        }finally{Stop-FaultChild $holder 'holder'}
        $after=Get-FaultState $base $id
        Expect ($after.Integrity -eq 'ok') ('integrity after the other instance stopped: '+$after.Integrity)
        Expect (($after.Revision -eq $before.Revision) -and ($after.BatchReceipts -eq 0)) 'nothing written while the base was held'
        $r=Invoke-FaultWorker $base $payload
        Expect ([bool]$r.Saved -and (-not [bool]$r.Already)) 'explicit retry committed'
        $final=Get-FaultState $base $id
        Expect (($final.Revision -eq ($before.Revision+1)) -and ($final.BatchReceipts -eq 1)) 'committed exactly once'
    }
    Case 'Base verrouillee dans le meme processus : SQLite 5 conserve, aucun recu, reprise verifiee' {
        $base=New-FaultBase 'busy';$before=Get-FaultState $base
        $c=Get-DomeniaLoadComputer -Index 2;$payload=New-FaultBatch $base @(New-FaultPing $c);$id=Get-FaultBatchId $payload
        $holder=Open-DomeniaDatabase $base.Path
        try{
            [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $holder)
            $message='';try{[void](Invoke-FaultWorker $base $payload)}catch{$message=$_.Exception.Message}
            Expect ($message -match 'SQLite code 5') ('actual SQLITE_BUSY: '+$message)
        }finally{try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $holder)}catch{};Close-DomeniaDatabase $holder}
        $after=Get-FaultState $base $id
        Expect (($after.Integrity -eq 'ok') -and ($after.Revision -eq $before.Revision) -and ($after.BatchReceipts -eq 0)) 'no partial write, no receipt'
        $r=Invoke-FaultWorker $base $payload
        Expect ([bool]$r.Saved -and (-not [bool]$r.Already)) 'retry committed'
        Expect ((Get-FaultState $base $id).BatchReceipts -eq 1) 'exactly one receipt'
    }
    Case 'Disque plein (SQLITE_FULL reel du moteur) : rien dʼecrit, reprise verifiee apres liberation' {
        $base=New-FaultBase 'full';$before=Get-FaultState $base
        $pages=[int](@(Read-FaultBase $base 'PRAGMA page_count;')[0].page_count)+2
        $full=Get-FaultWorkerCode -Point 'synchronous' -Hook ("[void](Invoke-DomeniaDbExec 'PRAGMA synchronous=FULL;PRAGMA max_page_count="+$pages+";' `$db)")
        $c=Get-DomeniaLoadComputer -Index 3;$change=New-FaultDirectoryChange $c '2026-03-01T00:00:00Z';$change.Data.Details=[pscustomobject]@{description=('X'*524288)}
        $payload=New-FaultBatch $base @($change);$id=Get-FaultBatchId $payload
        $message='';try{[void](Invoke-FaultWorker $base $payload $full)}catch{$message=$_.Exception.Message}
        Expect ($message -match 'SQLite code 13') ('actual SQLITE_FULL: '+$message)
        $after=Get-FaultState $base $id
        Expect (($after.Integrity -eq 'ok') -and ($after.Revision -eq $before.Revision) -and ($after.BatchReceipts -eq 0)) 'disk full rolled back rows and receipt'
        Expect (@(Read-FaultBase $base ("SELECT 1 AS x FROM domenia_directory_data WHERE object_guid="+(ConvertTo-DomeniaSqlLiteral $c.Guid)+" AND payload LIKE '%XXXX%';")).Count -eq 0) 'no partial directory payload'
        $r=Invoke-FaultWorker $base $payload
        Expect ([bool]$r.Saved -and (-not [bool]$r.Already)) 'same batch committed once space is available'
        $final=Get-FaultState $base $id
        Expect (($final.Revision -eq ($before.Revision+1)) -and ($final.BatchReceipts -eq 1)) 'exactly one write after the retry'
    }
    Case 'Arret brutal avant COMMIT : aucune ligne, aucun recu, base integre, reprise verifiee' {
        $base=New-FaultBase 'precommit';$before=Get-FaultState $base
        $c=Get-DomeniaLoadComputer -Index 1;$payload=New-FaultBatch $base @(New-FaultPing $c);$id=Get-FaultBatchId $payload
        $child=Start-FaultChild 'precommit' $base $payload 'precommit';Stop-FaultChild $child 'precommit'
        $after=Get-FaultState $base $id
        Expect ($after.Integrity -eq 'ok') ('integrity after the stop: '+$after.Integrity)
        Expect (($after.Revision -eq $before.Revision) -and ($after.Receipts -eq $before.Receipts) -and ($after.BatchReceipts -eq 0)) 'uncommitted batch left no receipt'
        Expect (@(Read-FaultBase $base ("SELECT 1 AS x FROM domenia_observations WHERE object_guid="+(ConvertTo-DomeniaSqlLiteral $c.Guid)+" AND family='Presence';")).Count -eq 0) 'uncommitted observation absent'
        $r=Invoke-FaultWorker $base $payload
        Expect ([bool]$r.Saved -and (-not [bool]$r.Already)) 'replayed batch committed'
        $final=Get-FaultState $base $id
        Expect (($final.Revision -eq ($before.Revision+1)) -and ($final.BatchReceipts -eq 1)) 'committed exactly once after the stop'
    }
    Case 'Arret brutal entre COMMIT et recu : lot enregistre une fois, rejeu sans seconde ecriture' {
        $base=New-FaultBase 'postcommit';$before=Get-FaultState $base
        $c=Get-DomeniaLoadComputer -Index 2;$payload=New-FaultBatch $base @(New-FaultPing $c);$id=Get-FaultBatchId $payload
        $child=Start-FaultChild 'postcommit' $base $payload 'postcommit';Stop-FaultChild $child 'postcommit'
        $after=Get-FaultState $base $id
        Expect ($after.Integrity -eq 'ok') ('integrity after the stop: '+$after.Integrity)
        Expect (($after.Revision -eq ($before.Revision+1)) -and ($after.BatchReceipts -eq 1)) 'COMMIT before the stop is durable with its receipt'
        $r=Invoke-FaultWorker $base $payload
        Expect ([bool]$r.Saved -and [bool]$r.Already) 'replay recognised as already committed'
        Expect (@($r.ObservationRows|Where-Object{[string]$_.Guid -ieq $c.Guid}).Count -eq 1) 'replay returns the committed rows read back from SQLite'
        $final=Get-FaultState $base $id
        Expect (($final.Revision -eq $after.Revision) -and ($final.BatchReceipts -eq 1)) 'no second write'
    }
    Case 'Migration des anciennes mesures interrompue : repli conserve a lʼoctet, aucun marqueur, reprise verifiee' {
        $base=New-FaultBase 'import';$c=Get-DomeniaLoadComputer -Index 3
        $legacy=[pscustomobject]@{Version=1;Guid=$c.Guid;Key=$c.Key;Computer=$c.Name;Presence='Hors ligne';PresenceCheckedUtc='2026-01-01T00:00:00Z';Inventory=[pscustomobject]@{CheckedUtc='2026-01-02T00:00:00Z';Model='Old inventory retained';RamBytes=8589934592};Probes=[pscustomobject]@{fixture=[pscustomobject]@{CheckedUtc='2026-01-03T00:00:00Z';Rows=@(,@('42'));Count=1}}}
        $json=$legacy|ConvertTo-Json -Depth 12 -Compress
        $db=Open-DomeniaDatabase $base.Path
        try{[void](Invoke-DomeniaDbExec ('DELETE FROM domenia_legacy_observation_imports WHERE object_guid='+(ConvertTo-DomeniaSqlLiteral $c.Guid)+';INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES('+((@($c.Key,'2026-01-03T00:00:00Z',$json)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)}finally{Close-DomeniaDatabase $db}
        $before=Get-FaultState $base
        $payload=New-FaultBatch $base @(New-FaultPing $c);$id=Get-FaultBatchId $payload
        $child=Start-FaultChild 'import' $base $payload 'import';Stop-FaultChild $child 'import'
        $after=Get-FaultState $base $id
        Expect ($after.Integrity -eq 'ok') ('integrity after the stop: '+$after.Integrity)
        Expect (($after.Revision -eq $before.Revision) -and ($after.BatchReceipts -eq 0)) 'interrupted migration left no receipt'
        $guid=ConvertTo-DomeniaSqlLiteral $c.Guid
        Expect ([long]@(Read-FaultBase $base ('SELECT count(*) AS n FROM domenia_legacy_observation_imports WHERE object_guid='+$guid+';'))[0].n -eq 0) 'no misleading migration marker'
        Expect ([long]@(Read-FaultBase $base ('SELECT count(*) AS n FROM domenia_observations WHERE object_guid='+$guid+';'))[0].n -eq 0) 'no half-migrated family'
        Expect ([string]@(Read-FaultBase $base ('SELECT payload FROM park_session_cache WHERE object_key='+(ConvertTo-DomeniaSqlLiteral $c.Key)+';'))[0].payload -ceq $json) 'legacy fallback preserved byte for byte'
        $r=Invoke-FaultWorker $base $payload
        Expect ([bool]$r.Saved -and (-not [bool]$r.Already)) 'migration resumed with the same batch'
        Expect ([long]@(Read-FaultBase $base ('SELECT count(*) AS n FROM domenia_legacy_observation_imports WHERE object_guid='+$guid+';'))[0].n -eq 1) 'migration marker committed once'
        $row=@($r.ObservationRows|Where-Object{[string]$_.Guid -ieq $c.Guid})
        Expect (($row.Count -eq 1) -and ([string]$row[0].Inventory.Model -eq 'Old inventory retained')) 'migrated inventory visible after the resume'
        Expect ([string]$row[0].PresenceCheckedUtc -like '2026-02-01*') 'new ping kept its own date'
        Expect ((Get-FaultState $base $id).BatchReceipts -eq 1) 'one receipt'
    }
    Case 'Indexation complete interrompue : index precedent intact, reprise du meme lot verifiee' {
        $base=New-FaultBase 'index';$spool=Join-Path $base.Directory 'index-spool';[void][IO.Directory]::CreateDirectory($spool)
        $now=[datetime]::UtcNow;$at=$now.ToString('o')
        function New-FaultTransfer {param([int]$Count,[string]$Stamp)
            $file=Join-Path $spool ([guid]::NewGuid().ToString('N')+'.jsonl')
            $writer=[IO.StreamWriter]::new($file,$false,[Text.UTF8Encoding]::new($false))
            try{for($n=1;$n -le $Count;$n++){$writer.WriteLine((ConvertTo-DomeniaLoadIndexLine -Computer (Get-DomeniaLoadComputer -Index $n) -At $Stamp -NowUtc $now))}}finally{$writer.Dispose()}
            return [pscustomobject]@{Path=$file;Sha256=(Get-FileHash $file -Algorithm SHA256).Hash;RowCount=$Count}
        }
        function New-FaultIndexPayload {param($Transfer,[string]$Stamp,[int]$Count)
            return [pscustomobject]@{Path=$base.Path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=@();Transfer=$Transfer;At=$Stamp;Server='dc.example.invalid';BaseDn=$script:Domain;Complete=$true;ReplaceAll=$true;HighestUsn=$Count}})}
        }
        $first=New-FaultTransfer 1000 $now.AddHours(-1).ToString('o')
        $r=Invoke-FaultWorker $base (New-FaultIndexPayload $first $now.AddHours(-1).ToString('o') 1000)
        Expect ([bool]$r.Saved) 'first index committed'
        $sync=[string]@(Read-FaultBase $base "SELECT COALESCE(last_sync,'') AS v FROM sync_state WHERE scope='directory';")[0].v
        $second=New-FaultTransfer 2000 $at;$payload=New-FaultIndexPayload $second $at 2000
        $child=Start-FaultChild 'index' $base $payload 'index';Stop-FaultChild $child 'index'
        $state=Get-FaultState $base
        Expect ($state.Integrity -eq 'ok') ('integrity after the stop: '+$state.Integrity)
        Expect ([long]@(Read-FaultBase $base "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine';")[0].n -eq 1000) 'previous index intact after the interrupted rebuild'
        Expect ([string]@(Read-FaultBase $base "SELECT COALESCE(last_sync,'') AS v FROM sync_state WHERE scope='directory';")[0].v -ceq $sync) 'coverage date not rejuvenated by the interrupted rebuild'
        $r=Invoke-FaultWorker $base $payload
        Expect ([bool]$r.Saved) 'same transfer committed on resume'
        Expect ([long]@(Read-FaultBase $base "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine';")[0].n -eq 2000) 'rebuilt index complete'
        Expect ([string]@(Read-FaultBase $base "SELECT COALESCE(last_sync,'') AS v FROM sync_state WHERE scope='directory';")[0].v -ceq $at) 'coverage dated by the resumed rebuild'
    }
}finally{
    if([IO.Directory]::Exists($folder)){try{[IO.Directory]::Delete($folder,$true)}catch{Write-Output ('Dossier temporaire non supprime : '+$folder)}}
}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{
    Suite='DomeniaStorageFaults';Passed=(($failed -eq 0) -and ($cases.Count -gt 0));Total=$cases.Count;Failed=$failed;Assertions=$script:Checks
    Qualifying=$false
    Faults=@('Base tenue par une autre instance','Base verrouillee','Disque plein (SQLITE_FULL du moteur)','Arret avant COMMIT','Arret entre COMMIT et recu','Migration des mesures interrompue','Indexation complete interrompue')
    Limitation='Disque plein simule par max_page_count (vrai code SQLITE_FULL du moteur), pas un volume physiquement plein. Arrets reels du processus enfant (Process.Kill).'
    Stops=$script:Stops.ToArray()
    PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition;Host=[Environment]::OSVersion.ToString();Computer=[Environment]::MachineName
    Cases=$cases.ToArray()
}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),(([pscustomobject]$report)|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('StorageFaults: '+($cases.Count-$failed)+'/'+$cases.Count+' cases, '+$script:Checks+' assertions')
if($failed){exit 1};exit 0
