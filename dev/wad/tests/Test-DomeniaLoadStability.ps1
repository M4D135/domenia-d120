#requires -Version 5.1
# Points 122, 125 and 128: load and stability bench of the local data path on generated fixtures.
# 10 000 computers minimum (default), 20 000 for the qualification run (-Computers 20000). The number of computers
# alone does not describe the load: four profiles (Get-DomeniaLoadProfiles) add a cold start in fresh processes, a
# warm cache, a large history and heavily equipped computers. Every scenario is repeated in -Cycles cycles inside ONE
# process: managed memory must stabilise after the first cycle, and the queues (engine admission, storage admission,
# runtime series) must stay bounded. Response times are summarised with the application rule (Get-DomeniaLatencySummary:
# median, 95th percentile stated only from 20 measures, maximum) per reproducible scenario, and the invariants of
# point 128 are checked at every cycle (widget = detailed GUIDs, dated rendering, unknown kept).
# Production code only: storage worker, local index reader, query engine and board rules, extracted as in
# Test-DomeniaScale. Disposable SQLite under the user profile, removed at the end. No AD, no endpoint, no WPF, no
# network. The timings describe the host that ran the suite; they prove nothing about a real network or domain.
# Duration: not yet measured under Windows; several minutes for 10 000 computers (Invoke-LabRun allows it 3 600 s).
[CmdletBinding()]
param(
    [ValidateSet(10000,20000)][int]$Computers=10000,
    [ValidateRange(3,50)][int]$Cycles=3,
    [ValidateRange(20,500)][int]$Samples=20,
    [ValidateRange(7,200)][int]$HeavySamples=7,
    [ValidateRange(3,50)][int]$ColdStarts=5,
    [string]$ReportPath='',
    # Internal: first reads of an existing fixture base in a fresh process (started by this suite only).
    [string]$ColdStartDatabase='',
    [string]$ColdStartOutput=''
)
$script:ProcessWatch=[Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
$tokens=$null;$errors=$null
$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Core parse failed'}
$native=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Initialize-DomeniaWinSqliteNative')},$true))[0].Extent.Text
if($PSVersionTable.PSEdition -eq 'Core'){
    $native=$native.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$native=$native.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
    elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$native=$native.Replace('winsqlite3.dll','libsqlite3.so.0')}
}
. ([scriptblock]::Create($native));[void](Initialize-DomeniaWinSqliteNative)
Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
# Same rule files as the LocalQuery and LocalIndexRead workers, plus the store contract and the engine rules.
foreach($name in @('Common.Model','Engine.Model','HealthRules.Model','Boards.Model','BoardFleet.Model','BoardSoftware.Model','Probes.Model','Park.Model','QueryLibrary.Model','Store.Model','QuerySchema.Model','Workstation.Model','Query.Model','Query.Worker','Storage.Worker','Engine.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$storage=Get-DomeniaStorageWorkerCode;$script:Reader=[scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode));$script:Storage=[scriptblock]::Create($storage)
$ast=[Management.Automation.Language.Parser]::ParseInput($storage,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Storage worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
function Import-LoadFunction {
    # One function of a UI module, extracted by AST: the module itself (WPF, timers) is not loaded.
    param([string]$File,[string[]]$Names)
    $t=$null;$e=$null;$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $modules $File),[ref]$t,[ref]$e)
    if($e.Count){throw ('Parse failed: '+$File)}
    foreach($name in $Names){
        $nodes=@($tree.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $name)},$true))
        if($nodes.Count -ne 1){throw ('Function missing or ambiguous: '+$name)}
        . ([scriptblock]::Create(($nodes[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($name)+'\b'),('function script:'+$name))))
    }
}
# The production schema is the text Get-DomeniaSqliteSchemaText returns (its here-string expands the query library
# schema): the function is taken from the core and run, never its raw literal.
$schemaAst=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Get-DomeniaSqliteSchemaText')},$true))
if($schemaAst.Count -ne 1){throw 'Schema de production introuvable.'}
. ([scriptblock]::Create($schemaAst[0].Extent.Text))
$script:SchemaText=Get-DomeniaSqliteSchemaText
Import-LoadFunction 'Domenia-Engine.UI.ps1' @('Add-DomeniaRuntimeMetric','Get-DomeniaRuntimeMetricSummary','Get-DomeniaResponseTimeSummaries')
Import-LoadFunction 'Domenia-Storage.UI.ps1' @('Submit-DomeniaStoreBatch')
. (Join-Path (Join-Path $PSScriptRoot 'fixtures') 'Domenia-LoadFixtures.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'fixtures') 'Domenia-Invariants.ps1')
function Invoke-LoadReader {param($Payload);return (& $script:Reader)}
function Invoke-LoadStorage {param($Payload);return (& $script:Storage)}
$script:Domain='DC=example,DC=invalid'
$script:PreludeMs=$script:ProcessWatch.Elapsed.TotalMilliseconds

# ---------------------------------------------------------------- cold start (child process)
if($ColdStartDatabase){
    $result=[ordered]@{Passed=$false;PreludeMs=[Math]::Round($script:PreludeMs,1);ProcessStartToReadyMs=$null;FirstFleetStatsMs=$null;FirstSearchMs=$null;Machines=0;SearchTotal=0;Error=''}
    try{
        try{$started=(Get-Process -Id $PID).StartTime;$result.ProcessStartToReadyMs=[Math]::Round(([datetime]::Now-$started).TotalMilliseconds,1)}catch{$result.ProcessStartToReadyMs=$null}
        $now=[datetime]::UtcNow
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $fleet=Invoke-LoadReader ([pscustomobject]@{Action='FleetStats';Path=$ColdStartDatabase;BusyTimeoutMs=250;Scope='';Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey='*'})
        $result.FirstFleetStatsMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,1);$watch.Restart()
        $page=Invoke-LoadReader ([pscustomobject]@{Action='Search';Path=$ColdStartDatabase;BusyTimeoutMs=250;Term='pc-0001';Limit=200;Offset=0})
        $result.FirstSearchMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,1)
        $result.Machines=@($fleet.Machines).Count;$result.SearchTotal=[long]$page.Total;$result.Passed=$true
    }catch{$result.Error=$_.Exception.Message}
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ColdStartOutput),(([pscustomobject]$result)|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    if($result.Passed){exit 0};exit 1
}

# ---------------------------------------------------------------- bench
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-load-'+[guid]::NewGuid().ToString('N'))
$cases=[Collections.Generic.List[object]]::new();$script:Checks=0
$script:Scenarios=[ordered]@{};$script:ScenarioLabels=@{};$script:CycleRows=[Collections.Generic.List[object]]::new()
$script:Violations=[Collections.Generic.List[object]]::new();$script:InvariantChecks=0;$script:BoardSurvey=[Collections.Generic.List[object]]::new()
$script:ManagedMB=[Collections.Generic.List[double]]::new();$script:PrivateMB=[Collections.Generic.List[double]]::new()
$script:ColdRuns=[Collections.Generic.List[object]]::new();$script:Bounds=[ordered]@{};$script:DomeniaRuntimeMetrics=@{}
function Expect {param([bool]$Good,[string]$Name);$script:Checks++;if(-not $Good){throw $Name}}
function Case {param([string]$Name,[scriptblock]$Code)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error='';Ms=$watch.ElapsedMilliseconds})}
    catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' @ '+$_.ScriptStackTrace);Ms=$watch.ElapsedMilliseconds});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function Measure-LoadStep {
    # Runs one scenario sample and records its duration. Provenance/OperationKey: the series of the application this
    # duration belongs to (same keys as Add-DomeniaTaskRuntimeMetric), so the per-category summary is the panel's one.
    param([string]$Scenario,[string]$Label,[scriptblock]$Block,[string]$Provenance='',[string]$OperationKey='')
    if(-not $script:Scenarios.Contains($Scenario)){$script:Scenarios[$Scenario]=[Collections.Generic.List[double]]::new();$script:ScenarioLabels[$Scenario]=$Label}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=& $Block
    $watch.Stop()
    $ms=[double]$watch.Elapsed.TotalMilliseconds
    $script:Scenarios[$Scenario].Add($ms)
    if($Provenance){Add-DomeniaRuntimeMetric -Provenance $Provenance -OperationId $OperationKey -DurationMs $ms}
    return ,$result
}
function Add-LoadViolations {param($Found);$script:InvariantChecks++;foreach($v in @($Found)){if($null -ne $v){$script:Violations.Add($v)}}}
function Invoke-LoadSql {
    # Executes generated statements in one write transaction (fixture seeding only, never a measured path).
    param([string]$Path,[Collections.Generic.List[string]]$Statements)
    $db=Open-DomeniaDatabase $Path
    try{
        [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db)
        $sql=[Text.StringBuilder]::new()
        foreach($statement in $Statements){[void]$sql.Append($statement);if($sql.Length -gt 1048576){[void](Invoke-DomeniaDbExec $sql.ToString() $db);[void]$sql.Clear()}}
        if($sql.Length){[void](Invoke-DomeniaDbExec $sql.ToString() $db)}
        [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
    }finally{Close-DomeniaDatabase $db}
}
function Read-LoadScalar {param([string]$Path,[string]$Sql);$db=Open-DomeniaDatabase $Path;try{return @(Invoke-DomeniaDbQuery $Sql $db)[0]}finally{Close-DomeniaDatabase $db}}
function Get-LoadGuids {param($Rows);return @(@($Rows)|Where-Object{$null -ne $_}|ForEach-Object{[string]$_.object_guid})}
function Test-LoadBoardWidgets {
    # Point 128 on the real Fleet board: the account figures come from SQL aggregates, their lists from the per-machine
    # rows, so the two are independent. Blocking: machines, enabled, disabled and the account status parts. Every other
    # distribution part is surveyed (not blocking, reported) for point 73 'liste exacte derrière chaque widget'.
    param($Board,[string]$Subject)
    $targets=$Board.Last.WidgetTargets
    foreach($key in @('fleet.machines','fleet.enabled','fleet.disabled')){
        $entry=$Board.Entries[$key];$value=0.0;[void][double]::TryParse([string]$entry.Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value)
        $widget=[pscustomobject]@{Total=$value;Matched=$value;NotMatched=0;Unknown=0;Items=@()}
        Add-LoadViolations (Test-DomeniaWidgetDetailInvariant ($Subject+' '+$key) $widget (Get-LoadGuids $targets[$key]))
    }
    $status=$Board.Entries['fleet.accountstatus'];$segments=@{};$sum=0.0
    foreach($part in @($status.Items)){$segments[[string]$part.Label]=(Get-LoadGuids $targets['fleet.accountstatus|'+[string]$part.Label]);$sum+=[double]$part.Value}
    Add-LoadViolations (Test-DomeniaWidgetDetailInvariant ($Subject+' fleet.accountstatus') ([pscustomobject]@{Total=$sum;Matched=$sum;NotMatched=0;Unknown=0;Items=@($status.Items)}) (Get-LoadGuids $targets['fleet.accountstatus']) $segments)
    foreach($entry in @($Board.Entries.Values)){
        if(([string]$entry.Kind -notin @('Distribution','Series')) -or ([string]$entry.Key -eq 'fleet.accountstatus')){continue}
        foreach($part in @($entry.Items)){
            if(($null -eq $part) -or ($null -eq $part.PSObject.Properties['Value']) -or ($null -eq $part.PSObject.Properties['Label'])){continue}
            $key=[string]$entry.Key+'|'+[string]$part.Label
            if(-not $targets.ContainsKey($key)){$script:BoardSurvey.Add([pscustomobject]@{Widget=$key;Value=[string]$part.Value;Detail='aucune liste'});continue}
            $count=@(Get-LoadGuids $targets[$key]|Select-Object -Unique).Count
            if([double]$part.Value -ne $count){$script:BoardSurvey.Add([pscustomobject]@{Widget=$key;Value=[string]$part.Value;Detail=('liste de '+$count+' poste(s)')})}
        }
    }
}

try{
    [void][IO.Directory]::CreateDirectory($folder)
    $now=[datetime]::UtcNow;$at=$now.ToString('o');$staleAt=$now.AddDays(-40).ToString('o')
    $profiles=@(Get-DomeniaLoadProfiles -Computers $Computers)
    $script:Expected=Get-DomeniaLoadExpectations -Computers $Computers
    $script:HeavyExpected=Get-DomeniaLoadExpectations -Computers $Computers -HeavyProfile
    $catalog=@(Get-DomeniaProbeCatalog)
    $baseProbes=@($catalog|Select-Object -First 4|ForEach-Object{[string]$_.Id})
    $heavyProbes=@($catalog|Select-Object -First 40|ForEach-Object{[string]$_.Id})
    $paths=@{Base=(Join-Path (Join-Path $folder 'base') 'load.sqlite');History=(Join-Path (Join-Path $folder 'history') 'load.sqlite');Heavy=(Join-Path (Join-Path $folder 'heavy') 'load.sqlite')}
    foreach($key in $paths.Keys){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths[$key]))}
    $base=$paths.Base

    Case 'Fixture : 10 000 postes minimum indexes par le vrai worker de stockage, observations generees' {
        Expect ($catalog.Count -ge 40) 'probe catalogue holds at least 40 probes'
        Expect (($script:SchemaText -match '^PRAGMA journal_mode=WAL;') -and ($script:SchemaText -match 'CREATE TABLE IF NOT EXISTS schema_info') -and ($script:SchemaText -notmatch '\$\(')) 'production schema found and expanded'
        $db=Open-DomeniaDatabase $base
        try{[void](Invoke-DomeniaDbExec $script:SchemaText $db)}finally{Close-DomeniaDatabase $db}
        $spool=Join-Path (Split-Path -Parent $base) 'index-spool';[void][IO.Directory]::CreateDirectory($spool)
        $file=Join-Path $spool ([guid]::NewGuid().ToString('N')+'.jsonl')
        $writer=[IO.StreamWriter]::new($file,$false,[Text.UTF8Encoding]::new($false))
        try{for($n=1;$n -le $Computers;$n++){$writer.WriteLine((ConvertTo-DomeniaLoadIndexLine -Computer (Get-DomeniaLoadComputer -Index $n) -At $at -NowUtc $now))}}finally{$writer.Dispose()}
        $transfer=[pscustomobject]@{Path=$file;Sha256=(Get-FileHash $file -Algorithm SHA256).Hash;RowCount=$Computers}
        $receipt=Measure-LoadStep 'FixtureIndex' 'Indexation initiale (worker de stockage)' {Invoke-LoadStorage ([pscustomobject]@{Path=$base;Items=@([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=@();Transfer=$transfer;At=$at;Server='dc.example.invalid';BaseDn=$script:Domain;Complete=$true;ReplaceAll=$true;HighestUsn=$Computers}})})}
        Expect ([bool]$receipt.Saved) 'index committed by the storage worker'
        # Same definition as the storage worker (park_session_cache is an additive table of schema 11/1).
        $statements=[Collections.Generic.List[string]]::new();$statements.Add('CREATE TABLE IF NOT EXISTS park_session_cache(object_key TEXT PRIMARY KEY,checked_utc TEXT NOT NULL,payload TEXT NOT NULL);')
        for($n=1;$n -le $Computers;$n++){
            $c=Get-DomeniaLoadComputer -Index $n
            if(-not $c.Observed){continue}
            $json=ConvertTo-DomeniaLoadObservationJson -Computer $c -At $at -StaleAt $staleAt -ProbeIds $baseProbes
            $statements.Add('INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES('+(ConvertTo-DomeniaSqlLiteral $c.Key)+','+(ConvertTo-DomeniaSqlLiteral $at)+','+(ConvertTo-DomeniaSqlLiteral $json)+');')
        }
        Invoke-LoadSql $base $statements
        Expect ([long](Read-LoadScalar $base "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine';").n -eq $Computers) 'every generated computer indexed'
        Expect ([long](Read-LoadScalar $base 'SELECT count(*) AS n FROM park_session_cache;').n -eq $script:Expected.Observed) 'every generated observation stored'
        $db=Open-DomeniaDatabase $base
        try{[void](Invoke-DomeniaDbExec 'PRAGMA wal_checkpoint(TRUNCATE);' $db)}finally{Close-DomeniaDatabase $db}
        foreach($copy in @('History','Heavy')){[IO.File]::Copy($base,$paths[$copy],$false)}
    }

    Case 'Fixture : historique volumineux (instantanes, recus de lots, traces, associations)' {
        $historyProfile=@($profiles|Where-Object{$_.Id -eq 'LargeHistory'})[0];$path=$paths.History
        $statements=[Collections.Generic.List[string]]::new()
        $invariant=[Globalization.CultureInfo]::InvariantCulture
        for($day=0;$day -lt [int]$historyProfile.HistoryDays;$day++){
            $date=$now.Date.AddDays(-$day).ToString('yyyy-MM-dd',$invariant)
            $figures='{"Machines":'+$Computers+',"Healthy":'+[int]($Computers*0.8)+',"Problems":'+[int]($Computers*0.2)+',"Stale":'+($day%50)+',"EndOfService":0,"Disabled":'+$script:Expected.Disabled+',"Windows10":0,"LowDisk":'+($day%30)+'}'
            $statements.Add("INSERT OR REPLACE INTO fleet_snapshots(scope_key,snapshot_day,taken_at,scope_dn,machines,figures) VALUES('*','"+$date+"',"+(ConvertTo-DomeniaSqlLiteral $now.AddDays(-$day).ToString('o'))+",'',"+$Computers+','+(ConvertTo-DomeniaSqlLiteral $figures)+');')
        }
        $storeId=Get-DomeniaStoreId $path $script:Domain
        $statements.Add('INSERT OR REPLACE INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,'+(ConvertTo-DomeniaSqlLiteral $storeId)+','+(ConvertTo-DomeniaSqlLiteral $script:Domain.ToLowerInvariant())+','+[int]$historyProfile.Receipts+');')
        for($r=1;$r -le [int]$historyProfile.Receipts;$r++){
            $id=('10000000-0000-4000-8000-{0:D12}' -f $r);$hash=('{0:x64}' -f $r)
            $committed=$now.AddMinutes(-([int]$historyProfile.Receipts-$r)).ToString('o')
            $statements.Add("INSERT INTO domenia_store_batches(batch_id,payload_hash,request_id,sequence,revision,committed_at,changes_json) VALUES('"+$id+"','"+$hash+"','history',1,"+$r+",'"+$committed+"','[]');")
        }
        for($r=1;$r -le [int]$historyProfile.OperationRuns;$r++){
            $finished=$now.AddMinutes(-$r).ToString('o')
            $statements.Add("INSERT INTO operation_runs(operation,mode,item_count,duration_ms,started_at,finished_at,notes) VALUES('LoadFixture','Fixture',"+($r%500)+','+($r%9000)+",'"+$finished+"','"+$finished+"','');")
        }
        for($n=1;$n -le $Computers;$n++){
            $c=Get-DomeniaLoadComputer -Index $n
            for($k=1;$k -le 3;$k++){$statements.Add("INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) VALUES('user"+($n%2000)+"','"+$c.Name+"','"+$c.Name+"','Fixture',50,0,'"+$now.AddDays(-$k*30).ToString('o')+"','','','"+$c.Guid+"');")}
        }
        Invoke-LoadSql $path $statements
        Expect ([long](Read-LoadScalar $path 'SELECT count(*) AS n FROM domenia_store_batches;').n -eq [long]$historyProfile.Receipts) 'receipts seeded'
        Expect ([long](Read-LoadScalar $path "SELECT count(*) AS n FROM fleet_snapshots WHERE scope_key='*';").n -eq [long]$historyProfile.HistoryDays) 'daily snapshots seeded'
    }

    Case 'Fixture : postes tres equipes (40 familles de sondes sur 5 % des postes)' {
        $path=$paths.Heavy;$statements=[Collections.Generic.List[string]]::new();$rewritten=0
        for($n=1;$n -le $Computers;$n++){
            $c=Get-DomeniaLoadComputer -Index $n -HeavyProfile
            if(-not ($c.Heavy -and $c.Observed)){continue}
            $json=ConvertTo-DomeniaLoadObservationJson -Computer $c -At $at -StaleAt $staleAt -ProbeIds $heavyProbes
            $statements.Add('INSERT OR REPLACE INTO park_session_cache(object_key,checked_utc,payload) VALUES('+(ConvertTo-DomeniaSqlLiteral $c.Key)+','+(ConvertTo-DomeniaSqlLiteral $at)+','+(ConvertTo-DomeniaSqlLiteral $json)+');');$rewritten++
        }
        Invoke-LoadSql $path $statements
        Expect ($rewritten -gt 0) 'heavy computers rewritten'
        $script:HeavyRewritten=$rewritten
    }

    Case 'Demarrage a froid : premiers acces dans des processus Windows PowerShell neufs' {
        $shell=(Get-Process -Id $PID).Path
        for($i=1;$i -le $ColdStarts;$i++){
            $output=Join-Path $folder ('cold-'+$i+'.json')
            $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-ColdStartDatabase',('"'+$base+'"'),'-ColdStartOutput',('"'+$output+'"'))
            if($PSVersionTable.PSEdition -ne 'Core'){$arguments=@('-STA')+$arguments}
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $process=Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $folder ('cold-'+$i+'.out.txt')) -RedirectStandardError (Join-Path $folder ('cold-'+$i+'.err.txt'))
            $null=$process.Handle
            if(-not $process.WaitForExit(300000)){try{$process.Kill()}catch{};throw ('cold start '+$i+' timed out')}
            $process.WaitForExit();$watch.Stop()
            Expect (($process.ExitCode -eq 0) -and [IO.File]::Exists($output)) ('cold start '+$i+' failed: '+[IO.File]::ReadAllText((Join-Path $folder ('cold-'+$i+'.err.txt'))))
            $run=[IO.File]::ReadAllText($output)|ConvertFrom-Json
            Expect (([long]$run.Machines -eq $Computers) -and ([long]$run.SearchTotal -eq 100)) 'cold reads return the whole fixture'
            $script:ColdRuns.Add([pscustomobject]@{Run=$i;WallMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,1);ProcessStartToReadyMs=$run.ProcessStartToReadyMs;FirstFleetStatsMs=$run.FirstFleetStatsMs;FirstSearchMs=$run.FirstSearchMs})
            foreach($pair in @(@('ColdProcess','Processus neuf, du lancement aux premiers résultats',$watch.Elapsed.TotalMilliseconds),@('ColdFleetStats','Première vue du parc dans un processus neuf',[double]$run.FirstFleetStatsMs),@('ColdSearch','Première recherche locale dans un processus neuf',[double]$run.FirstSearchMs))){
                if(-not $script:Scenarios.Contains([string]$pair[0])){$script:Scenarios[[string]$pair[0]]=[Collections.Generic.List[double]]::new();$script:ScenarioLabels[[string]$pair[0]]=[string]$pair[1]}
                $script:Scenarios[[string]$pair[0]].Add([double]$pair[2])
            }
        }
    }

    $heavySet=@{};for($n=1;$n -le $Computers;$n++){$c=Get-DomeniaLoadComputer -Index $n -HeavyProfile;if($c.Heavy -and $c.Observed -and (-not $c.Recreated)){$heavySet[$c.Key]=$true}}
    $commitPool=@(for($n=1;$n -le $Computers;$n++){$c=Get-DomeniaLoadComputer -Index $n;if($c.Active -and (-not $c.Observed)){$c}})
    $historyContext=[pscustomobject]@{Version=1;Path=$paths.History;DomainDn=$script:Domain;StoreId=(Get-DomeniaStoreId $paths.History $script:Domain);RequestId='load';Generation=1;SessionEpoch=1;ScopeDn=$script:Domain;Subtree=$true}
    $probeRequests=@($heavyProbes|ForEach-Object{[pscustomobject]@{Key=$_;Visual='Bar'}})
    $commitIndex=0
    for($cycle=1;$cycle -le $Cycles;$cycle++){
        Case ('Cycle '+$cycle+' : cache chaud (recherche locale, vue du parc, regles, requetes, widgets)') {
            for($i=0;$i -lt $Samples;$i++){
                # Prefixes pc-0001 to pc-0099: each matches exactly the 100 names PC-00NN00 to PC-00NN99.
                $term='pc-'+('{0:D4}' -f ((((($cycle*$Samples)+$i)*37) % 99)+1))
                $page=Measure-LoadStep 'WarmSearch' 'Recherche locale, page de 200 résultats (cache chaud)' {Invoke-LoadReader ([pscustomobject]@{Action='Search';Path=$base;BusyTimeoutMs=250;Term=$term;Limit=200;Offset=0})} 'Sqlite' 'LocalIndexRead:Search'
                Expect ([long]$page.Total -eq 100) ('local search total for '+$term)
                $offset=(($i*200) % $Computers)
                $browse=Measure-LoadStep 'WarmBrowse' 'Parcours de la base locale, page de 200 lignes' {Invoke-LoadReader ([pscustomobject]@{Action='Search';Path=$base;BusyTimeoutMs=250;Term='';Browse=$true;Limit=200;Offset=$offset})} 'Sqlite' 'LocalIndexRead:Search'
                Expect ([long]$browse.Total -eq $Computers) 'browse total covers the whole base'
            }
            $fleet=$null;$board=$null;$records=$null
            for($i=0;$i -lt $HeavySamples;$i++){
                $fleet=Measure-LoadStep 'WarmFleetStats' 'Vue du parc (lecture SQLite)' {Invoke-LoadReader ([pscustomobject]@{Action='FleetStats';Path=$base;BusyTimeoutMs=250;Scope='';Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey='*'})} 'Sqlite' 'LocalIndexRead:FleetStats'
                $board=Measure-LoadStep 'BoardRules' 'Règles du tableau de bord du parc' {Get-DomeniaFleetBoardData -Result $fleet -Now $now}
                $records=Measure-LoadStep 'QueryProjection' 'Projection des postes pour les requêtes' {ConvertTo-DomeniaQueryRecords -Fleet $board.Last -Observations $board.Observations -NowUtc $now} 'Sqlite' 'LocalQuery'
                $ram=New-DomeniaQueryRecipe -Name 'RAM < 8' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=8}) -GroupBy model
                $widget=Measure-LoadStep 'QueryWidget' 'Widget de requête groupé (RAM < 8 Go par modèle)' {Measure-DomeniaQueryWidget $records $ram} 'Sqlite' 'LocalQuery'
            }
            Expect ((@($fleet.Machines).Count -eq $Computers) -and (@($fleet.Targets).Count -eq $script:Expected.Active)) 'fleet population exact'
            Expect ([long]$board.Entries['fleet.machines'].Value -eq $Computers) 'board total equals the SQLite population'
            Expect ($records.Count -eq $Computers) 'query projection holds every computer'
            # Point 128, at every cycle.
            Add-LoadViolations (Test-DomeniaRenderDatedInvariant ('Cycle '+$cycle+' vue du parc') $board.Freshness.ComputedAtUtc)
            Add-LoadViolations (Test-DomeniaRenderDatedInvariant ('Cycle '+$cycle+' instantane SQLite') $fleet.SnapshotAtUtc)
            Test-LoadBoardWidgets -Board $board -Subject ('Cycle '+$cycle)
            $segments=@{};foreach($item in @($widget.Items)){$segments[[string]$item.Label]=Get-DomeniaQueryMatchIds $records (New-DomeniaQuerySegmentRecipe $ram $item.Select)}
            Add-LoadViolations (Test-DomeniaWidgetDetailInvariant ('Cycle '+$cycle+' RAM < 8') $widget (Get-DomeniaQueryMatchIds $records $ram) $segments)
            Add-LoadViolations (Test-DomeniaUnknownKeptInvariant ('Cycle '+$cycle+' RAM < 8') $script:Expected.UnknownInventory $widget.Unknown $script:Expected.KnownInventory ([long]$widget.Matched+[long]$widget.NotMatched))
            Expect ([long]$widget.Matched -eq $script:Expected.LowRam) 'RAM widget equals the count computed from the generation rules'
            $models=New-DomeniaQueryRecipe -Name 'Modèles' -GroupBy model
            $byModel=Measure-DomeniaQueryWidget $records $models
            $modelSegments=@{};$known=0L;$unknownSegment=$null
            foreach($item in @($byModel.Items)){
                $modelSegments[[string]$item.Label]=Get-DomeniaQueryMatchIds $records (New-DomeniaQuerySegmentRecipe $models $item.Select)
                if([bool]$item.Select.Missing){$unknownSegment=[long]$item.Value}else{$known+=[long]$item.Value}
                if((-not [bool]$item.Select.Missing) -and ([string]$item.Label -like 'Model *')){Expect ([long]$item.Value -eq [long]$script:Expected.Models[[string]$item.Label]) ('model count '+$item.Label)}
            }
            Add-LoadViolations (Test-DomeniaWidgetDetailInvariant ('Cycle '+$cycle+' modèles') $byModel (Get-DomeniaQueryMatchIds $records $models) $modelSegments)
            Add-LoadViolations (Test-DomeniaUnknownKeptInvariant ('Cycle '+$cycle+' modèles') $script:Expected.UnknownInventory $unknownSegment $script:Expected.KnownInventory $known)
            $fleet=$null;$board=$null;$records=$null;$widget=$null;$byModel=$null;$segments=$null;$modelSegments=$null
        }
        Case ('Cycle '+$cycle+' : historique volumineux (vue du parc avec un an d instantanes, enregistrement de lots)') {
            for($i=0;$i -lt $HeavySamples;$i++){
                $history=Measure-LoadStep 'HistoryFleetStats' 'Vue du parc avec 400 instantanés' {Invoke-LoadReader ([pscustomobject]@{Action='FleetStats';Path=$paths.History;BusyTimeoutMs=250;Scope='';Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey='*'})} 'Sqlite' 'LocalIndexRead:FleetStats'
                Expect (@($history.History).Count -eq 400) 'every daily snapshot read'
                $historyBoard=Measure-LoadStep 'HistoryBoardRules' 'Règles du tableau de bord avec courbes' {Get-DomeniaFleetBoardData -Result $history -Now $now}
                Expect ($historyBoard.Entries.ContainsKey('fleet.trend')) 'trend curve drawn from the history'
            }
            for($i=0;$i -lt $Samples;$i++){
                $c=$commitPool[$commitIndex % $commitPool.Count];$commitIndex++
                $stamp=[datetime]::UtcNow.ToString('o')
                $change=[pscustomobject]@{Kind='Observation';Guid=$c.Guid;DN=$c.Dn;Family='Presence';Status='Success';AttemptedAtUtc=$stamp;ObservedAtUtc=$stamp;Error='';Data=[pscustomobject]@{Computer=$c.Name;Presence='En ligne'}}
                $batch=ConvertTo-DomeniaStoreBatch -Context $historyContext -BatchId ([guid]::NewGuid().ToString()) -Sequence 1 -Changes @($change)
                $saved=Measure-LoadStep 'HistoryCommit' 'Enregistrement dʼun lot (50 000 reçus existants)' {Invoke-LoadStorage ([pscustomobject]@{Path=$paths.History;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$batch.Json;Hash=$batch.Hash})})} 'Sqlite' 'LocalStore'
                Expect ([bool]$saved.Saved -and (-not [bool]$saved.Already)) 'batch committed once'
            }
            Add-LoadViolations (Test-DomeniaRenderDatedInvariant ('Cycle '+$cycle+' historique') $historyBoard.Freshness.ComputedAtUtc)
            $history=$null;$historyBoard=$null
        }
        Case ('Cycle '+$cycle+' : postes tres equipes (40 sondes, 2 500 logiciels)') {
            for($i=0;$i -lt $HeavySamples;$i++){
                $prepared=Measure-LoadStep 'HeavyParkTargets' 'Préparation de collecte, postes à 40 sondes' {Invoke-LoadReader ([pscustomobject]@{Action='ParkTargets';Path=$paths.Heavy;BusyTimeoutMs=250;Scope='Park'})} 'Sqlite' 'LocalIndexRead:ParkTargets'
                Expect (@($prepared.Rows).Count -eq $script:Expected.Active) 'collection targets are the active computers'
                $expanded=Measure-LoadStep 'HeavyExpand' 'Décodage des relevés des postes très équipés' {$count=0;foreach($target in @($prepared.Rows)){if($heavySet.ContainsKey([string]$target.Key)){Expand-DomeniaParkPrevious $target;$count++}};$count}
                Expect ([int]$expanded -eq $heavySet.Count) 'every heavy computer decoded'
                Clear-DomeniaParkTargetBuffers $prepared.Rows
                Expect (@($prepared.Rows|Where-Object{([string]$_.PreviousJson) -or ($null -ne $_.Previous)}).Count -eq 0) 'collection buffers released'
                $prepared=$null
                $fleet=Measure-LoadStep 'HeavyFleetStats' 'Vue du parc, postes à 40 sondes' {Invoke-LoadReader ([pscustomobject]@{Action='FleetStats';Path=$paths.Heavy;BusyTimeoutMs=250;Scope='';Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey='*'})} 'Sqlite' 'LocalIndexRead:FleetStats'
                $board=Get-DomeniaFleetBoardData -Result $fleet -Now $now
                $entries=Measure-LoadStep 'HeavyProbeWidgets' 'Quarante widgets de sondes' {Measure-DomeniaFleetProbeEntries -Fleet $board.Last -Observations $board.Observations -Requests $probeRequests -NowUtc $now} 'Sqlite' 'LocalQuery'
                Expect ($entries.Count -eq 40) 'every requested probe has its widget, even when its value is unknown'
                $rows=New-DomeniaLoadSoftwareRows -Count 2500 -NowUtc $now
                $software=Measure-LoadStep 'HeavySoftwareBoard' 'Synthèse de 2 500 logiciels dʼun poste' {Get-DomeniaSoftwareBoardData -Rows $rows -Now ([datetime]::Now)} 'Dispatcher' 'Callback:SoftwareInventory'
                Expect ([string]$software.Entries['software.count'].Value -eq '2500') 'software count equals the list read'
                $fleet=$null;$board=$null;$entries=$null;$rows=$null;$software=$null
            }
        }
        [GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect()
        $managed=[GC]::GetTotalMemory($true)/1MB
        $current=[Diagnostics.Process]::GetCurrentProcess();$measuredPrivateMb=0.0
        try{$measuredPrivateMb=$current.PrivateMemorySize64/1MB}finally{$current.Dispose()}
        $script:ManagedMB.Add([Math]::Round($managed,1));$script:PrivateMB.Add([Math]::Round($measuredPrivateMb,1))
        $script:CycleRows.Add([pscustomobject]@{Cycle=$cycle;ManagedMB=[Math]::Round($managed,1);PrivateMB=[Math]::Round($measuredPrivateMb,1);ElapsedS=[Math]::Round($script:ProcessWatch.Elapsed.TotalSeconds,1)})
    }

    Case 'Memoire stabilisee apres le premier cycle' {
        $memory=Test-DomeniaMemoryStabilized -SamplesMB $script:ManagedMB.ToArray() -Warmup 1
        $script:Bounds['Memory']=$memory
        Expect ([bool]$memory.Stable) ('managed memory still growing: '+($script:ManagedMB -join ' -> ')+' MB, limit +'+$memory.LimitMB+' MB')
    }
    Case 'Files bornees : admission du moteur, file de stockage et series de mesures' {
        $burst=Measure-DomeniaLoadAdmissionBurst -Requests $Computers
        $script:Bounds['EngineAdmission']=$burst
        Expect ([bool]$burst.Bounded) 'engine admission queue bounded'
        function Request-DomeniaStorageWork {}
        $script:Persistence=[pscustomobject]@{Pending=([ordered]@{});InFlightItems=@();Failures=0}
        $floodContext=[pscustomobject]@{Version=1;Path=$base;DomainDn=$script:Domain;StoreId=(Get-DomeniaStoreId $base $script:Domain);RequestId='flood';Generation=1;SessionEpoch=1;ScopeDn=$script:Domain;Subtree=$true}
        $accepted=0;$refused=0;$other=0;$changes=[Collections.Generic.List[object]]::new();$stamp=[datetime]::UtcNow.ToString('o')
        for($n=1;$n -le $Computers;$n++){
            $c=Get-DomeniaLoadComputer -Index $n
            $changes.Add([pscustomobject]@{Kind='Observation';Guid=$c.Guid;DN=$c.Dn;Family='Presence';Status='Success';AttemptedAtUtc=$stamp;ObservedAtUtc=$stamp;Error='';Data=[pscustomobject]@{Computer=$c.Name;Presence='En ligne'}})
            if(($changes.Count -eq 250) -or ($n -eq $Computers)){
                $answer=Submit-DomeniaStoreBatch $floodContext ([guid]::NewGuid().ToString()) 1 $changes.ToArray() 'Complete-LoadStore' 'Fail-LoadStore' $null
                if([bool]$answer.Accepted){$accepted++}elseif([bool]$answer.Backpressure -and ([string]$answer.Reason -eq 'StorageQueueFull')){$refused++}else{$other++}
                $changes.Clear()
            }
        }
        $pendingChanges=0L;foreach($item in @($script:Persistence.Pending.Values)){$pendingChanges+=[long]$item.ChangeCount}
        $script:Bounds['StorageAdmission']=[pscustomobject]@{Batches=($accepted+$refused+$other);Accepted=$accepted;Refused=$refused;Other=$other;PendingChanges=$pendingChanges;ChangeBudget=4096}
        Expect (($other -eq 0) -and ($refused -gt 0) -and ($pendingChanges -le 4096) -and ($script:Persistence.Pending.Count -eq $accepted)) 'storage queue refuses explicitly beyond its budget and keeps every accepted batch'
        $script:Persistence=$null
        for($i=0;$i -lt 2000;$i++){Add-DomeniaRuntimeMetric -Provenance 'Queue' -OperationId 'LoadBound' -DurationMs $i}
        $largest=0;foreach($key in @($script:DomeniaRuntimeMetrics.Keys)){$largest=[Math]::Max($largest,$script:DomeniaRuntimeMetrics[$key].Count)}
        $script:Bounds['RuntimeSeries']=[pscustomobject]@{Series=$script:DomeniaRuntimeMetrics.Count;LargestSeries=$largest;Bound=512}
        Expect (($largest -le 512) -and ((Get-DomeniaRuntimeMetricSummary -Provenance 'Queue' -Prefix 'LoadBound').Count -eq 512)) 'runtime series bounded at 512 values'
    }
    Case 'Invariants verifies a chaque cycle (point 128)' {
        $report=Get-DomeniaInvariantReport -Violations $script:Violations.ToArray() -Checked $script:InvariantChecks
        $script:Bounds['Invariants']=$report
        Expect ([bool]$report.Passed) ('invariants broken: '+((@($report.Violations|Select-Object -First 10|ForEach-Object{$_.Subject+' : '+$_.Text+' (attendu '+$_.Expected+', obtenu '+$_.Actual+')'})) -join ' | '))
    }
}finally{
    if([IO.Directory]::Exists($folder)){try{[IO.Directory]::Delete($folder,$true)}catch{Write-Output ('Dossier temporaire non supprime : '+$folder)}}
}

# ---------------------------------------------------------------- report
$scenarioRows=[Collections.Generic.List[object]]::new()
foreach($key in @($script:Scenarios.Keys)){
    $summary=Get-DomeniaLatencySummary -Samples $script:Scenarios[$key].ToArray()
    $scenarioRows.Add([pscustomobject]@{Scenario=$key;Label=[string]$script:ScenarioLabels[$key];Count=$summary.Count;P50Ms=$summary.P50;P95Ms=$summary.P95;MaxMs=$summary.Max;P95Stated=$summary.P95Stated;Text=(Format-DomeniaLatencySummaryText -Label ([string]$script:ScenarioLabels[$key]) -Summary $summary)})
}
$categories=@();try{$categories=@(Get-DomeniaResponseTimeSummaries|ForEach-Object{[pscustomobject]@{Id=$_.Id;Text=$_.Text}})}catch{$categories=@()}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{
    Suite='DomeniaLoadStability';Passed=(($failed -eq 0) -and ($cases.Count -gt 0));Total=$cases.Count;Failed=$failed;Assertions=$script:Checks
    Qualifying=$false
    Scope='Charge et stabilité du chemin local (stockage, lecture, requêtes, règles) sur fixtures générées. Aucun AD, aucun réseau, aucune interface WPF : ne prouve ni le réseau cible ni le rendu.'
    Computers=$Computers;Cycles=$Cycles;Samples=$Samples;HeavySamples=$HeavySamples;ColdStarts=$ColdStarts
    Profiles=$(try{@(Get-DomeniaLoadProfiles -Computers $Computers)}catch{@()})
    Scenarios=$scenarioRows.ToArray();ApplicationCategories=$categories;ColdRuns=$script:ColdRuns.ToArray()
    Memory=[ordered]@{ManagedMB=$script:ManagedMB.ToArray();PrivateMB=$script:PrivateMB.ToArray();Verdict=$script:Bounds['Memory']}
    Bounds=$script:Bounds;CycleMemory=$script:CycleRows.ToArray()
    BoardWidgetSurvey=[ordered]@{Blocking=$false;Note='Parts de widgets du tableau de bord dont la liste détaillée manque ou diffère (point 73), hors comptes vérifiés.';Mismatches=@($script:BoardSurvey|Select-Object -First 50);Count=$script:BoardSurvey.Count}
    PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition;Host=[Environment]::OSVersion.ToString();Computer=[Environment]::MachineName
    DurationS=[Math]::Round($script:ProcessWatch.Elapsed.TotalSeconds,1);Cases=$cases.ToArray()
}
$json=([pscustomobject]$report)|ConvertTo-Json -Depth 8
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),$json,[Text.UTF8Encoding]::new($false))}
foreach($row in $scenarioRows){Write-Output $row.Text}
Write-Output ('LoadStability: '+($cases.Count-$failed)+'/'+$cases.Count+' cases, '+$script:Checks+' assertions, '+$script:InvariantChecks+' invariant checks')
if($failed){exit 1};exit 0
