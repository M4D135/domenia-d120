#requires -Version 5.1
# Production storage/read/query functions, disposable SQLite and invented directory objects only.
# No AD, endpoint, WPF, VM or network calls. Timing reports describe this host, not Windows qualification.
param([ValidateRange(5000,20000)][int]$Count=5000,[ValidateRange(0,78)][int]$ProbeCount=8,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
$tokens=$null;$errors=$null
$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Core parse failed'}
$native=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DomeniaWinSqliteNative'},$true))[0].Extent.Text
if($PSVersionTable.PSEdition -eq 'Core'){
    $native=$native.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$native=$native.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
    elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$native=$native.Replace('winsqlite3.dll','libsqlite3.so.0')}
}
. ([scriptblock]::Create($native));[void](Initialize-DomeniaWinSqliteNative)
Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
# HealthRules.Model: Get-DomeniaFleetQueryPlan and the board rules read the health policy (ConvertTo-DomeniaHealthPolicy).
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','BoardFleet.Model','Probes.Model','Park.Model','QueryLibrary.Model','Query.Model','Query.Worker','Storage.Worker','Engine.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$storage=Get-DomeniaStorageWorkerCode;$reader=[scriptblock]::Create((Get-DomeniaLocalIndexReadWorkerCode))
$ast=[Management.Automation.Language.Parser]::ParseInput($storage,[ref]$tokens,[ref]$errors)
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-scale-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$path=Join-Path $folder 'scale.sqlite';$spool=Join-Path $folder 'index-spool';[void][IO.Directory]::CreateDirectory($spool)
$file=Join-Path $spool ([guid]::NewGuid().ToString('N')+'.jsonl')
$script:checks=0;$times=[ordered]@{};$watch=[Diagnostics.Stopwatch]::StartNew()
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
function Mark {param([string]$Name);$times[$Name]=$watch.ElapsedMilliseconds;Write-Output ($Name+': '+$watch.ElapsedMilliseconds+' ms');$watch.Restart()}
function Guid-For {param([int]$N);return ('00000000-0000-0000-0000-{0:D12}' -f $N)}
$now=[datetime]::UtcNow;$at=$now.ToString('o');$inventoryAt=$now.AddDays(-40).ToString('o')
try{
    # The schema is the text Get-DomeniaSqliteSchemaText returns: its here-string expands the query library schema.
    $schemaAst=@($core.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Get-DomeniaSqliteSchemaText')},$true))
    Expect ($schemaAst.Count -eq 1) 'production schema found'
    . ([scriptblock]::Create($schemaAst[0].Extent.Text))
    $schemaText=Get-DomeniaSqliteSchemaText
    Expect (($schemaText -match 'CREATE TABLE IF NOT EXISTS schema_info') -and ($schemaText -notmatch '\$\(')) 'production schema expanded'
    $db=Open-DomeniaDatabase $path
    try{[void](Invoke-DomeniaDbExec $schemaText $db)}finally{Close-DomeniaDatabase $db}
    $writer=[IO.StreamWriter]::new($file,$false,[Text.UTF8Encoding]::new($false))
    try{
        for($n=1;$n -le $Count;$n++){
            $name='PC-{0:D6}' -f $n;$ou=if($n%5 -eq 0){'Beta'}else{'Alpha'}
            $row=[ordered]@{Guid=(Guid-For $n);Type='Machine';Name=$name;Login=$name+'$';DN=('CN='+$name+',OU='+$ou+',DC=example,DC=invalid');State=$(if($n%10 -eq 0){'Desactive'}else{'Actif'});Extra='Windows 11';LastLogon=$now.AddDays(-($n%200)).ToString('dd/MM/yyyy');Facts=$true;OsVersion='26100';WhenCreated=$at;PwdLastSet=$at;LapsKind='None';Usn=$n}
            $writer.WriteLine(($row|ConvertTo-Json -Compress))
        }
    }finally{$writer.Dispose()}
    $transfer=[pscustomobject]@{Path=$file;Sha256=(Get-FileHash $file).Hash;RowCount=$Count}
    Mark 'PrepareFixture'
    $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=[pscustomobject]@{Rows=@();Transfer=$transfer;At=$at;Server='dc.example.invalid';BaseDn='DC=example,DC=invalid';Complete=$true;ReplaceAll=$true;HighestUsn=$Count}})}
    $receipt=& ([scriptblock]::Create($storage));Expect ([bool]$receipt.Saved) 'index committed';Mark 'IndexWrite'
    $probes=@(Get-DomeniaProbeCatalog|Select-Object -First $ProbeCount)
    $db=Open-DomeniaDatabase $path
    try{
        $cacheSchema=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like 'CREATE TABLE IF NOT EXISTS park_session_cache*'},$true))[0].Value
        [void](Invoke-DomeniaDbExec $cacheSchema $db)
        [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db)
        $sql=[Text.StringBuilder]::new()
        for($n=1;$n -le $Count;$n++){
            if($n%10 -eq 0 -or $n%7 -eq 0){continue}
            $name='PC-{0:D6}' -f $n;$ou=if($n%5 -eq 0){'Beta'}else{'Alpha'};$dn='CN='+$name+',OU='+$ou+',DC=example,DC=invalid'
            $probeValues=[ordered]@{}
            foreach($p in $probes){$probeValues[$p.Id]=[pscustomobject]@{CheckedUtc=$at;Count=1;Rows=@(,@('42'));Error='';Skipped='';Truncated=$false}}
            $obs=[pscustomobject]@{Key=$dn.ToLowerInvariant();Guid=$(if($n%13 -eq 0){'recreated'}else{Guid-For $n});CheckedUtc=$at;Presence=$(if($n%3 -eq 0){'Sans reponse'}else{'En ligne'});Inventory=[pscustomobject]@{CheckedUtc=$(if($n%11 -eq 0){$inventoryAt}else{$at});Model=('Model '+($n%12));RamBytes=$(if($n%4 -eq 0){4GB}else{16GB});DiskSize=100GB;DiskFree=($n%100)*1GB};Probes=$probeValues}
            $json=$obs|ConvertTo-Json -Depth 8 -Compress
            [void]$sql.Append(('INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES('+ (ConvertTo-DomeniaSqlLiteral $obs.Key)+','+(ConvertTo-DomeniaSqlLiteral $at)+','+(ConvertTo-DomeniaSqlLiteral $json)+');'))
            if($n%100 -eq 0 -or $sql.Length -gt 1MB){[void](Invoke-DomeniaDbExec $sql.ToString() $db);[void]$sql.Clear()}
        }
        if($sql.Length){[void](Invoke-DomeniaDbExec $sql.ToString() $db)}
        [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
    }finally{Close-DomeniaDatabase $db}
    Mark 'SeedObservations'
    $Payload=[pscustomobject]@{Action='ParkTargets';Path=$path;BusyTimeoutMs=250;Scope='Park'}
    $prepared=& $reader
    Expect ($prepared.Rows.Count -eq ($Count-$Count/10)) 'collection preparation retains all active targets'
    foreach($target in $prepared.Rows){Expect ($null -eq $target.Previous) 'pending collection targets retain JSON only, never full PowerShell probe graphs'}
    $first=$prepared.Rows[0]
    Expect ([bool]$first.PreviousJson) 'raw observation available for first admitted target'
    Expand-DomeniaParkPrevious $first
    Expect ($first.Previous.Probes.PSObject.Properties.Name.Count -eq $ProbeCount -and -not $first.PreviousJson) 'one admission decodes every probe and releases source JSON'
    if($ProbeCount){Expect ($first.Previous.Probes.($probes[0].Id).Rows[0][0] -eq '42') 'original raw probe rows survive for persistence merge'}
    Clear-DomeniaParkTargetBuffers $prepared.Rows
    Expect (@($prepared.Rows|Where-Object{$_.PreviousJson -or $null -ne $_.Previous}).Count -eq 0) 'completion or cancellation releases every collection buffer'
    $prepared=$null
    Mark 'CollectionPreparation'
    $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;BusyTimeoutMs=250;Scope='';Subtree=$true;Plan=(Get-DomeniaFleetQueryPlan -Now $now);Keys=@();ScopeKey='*'}
    $fleet=& $reader
    Expect ($fleet.Machines.Count -eq $Count) 'dashboard population includes every disabled workstation'
    Expect ($fleet.Targets.Count -eq ($Count-$Count/10)) 'collection has exactly active targets'
    Mark 'FleetRead'
    $board=Get-DomeniaFleetBoardData -Result $fleet -Now $now
    Expect ([long]$board.Entries['fleet.machines'].Value -eq $Count) 'dashboard total agrees with SQLite population'
    Mark 'FleetRules'
    $records=ConvertTo-DomeniaQueryRecords -Fleet $board.Last -Observations $board.Observations -NowUtc $now
    Expect ($records.Count -eq $Count) 'query projection includes every workstation'
    Mark 'QueryProjection'
    $recipe=New-DomeniaQueryRecipe
    $compiled=ConvertTo-DomeniaCompiledQuery $recipe
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for($offset=0;$offset -lt $Count;$offset+=200){
        $options=[M4D.Admin.Common.Query.QueryOptions]::new();$options.Offset=$offset;$options.Limit=200;$options.SortField='name'
        $page=$compiled.Execute($records,$options)
        Expect ($page.Total -eq $Count -and $page.Matched -eq $Count) 'page counters retain full population'
        foreach($r in $page.Rows){Expect ($seen.Add($r.Id)) 'no duplicate across pages'}
    }
    Expect ($seen.Count -eq $Count -and $seen.Contains((Guid-For $Count))) 'all objects accessible, including last page'
    Mark 'AllPages'
    $probeRequests=@($probes|ForEach-Object{[pscustomobject]@{Key=$_.Id;Visual='Bar'}})
    $probeEntries=Measure-DomeniaFleetProbeEntries -Fleet $board.Last -Observations $board.Observations -Requests $probeRequests -NowUtc $now
    Expect ($probeEntries.Count -eq $ProbeCount) 'every requested probe produces a widget even if its value is unknown'
    Mark 'ProbeWidgets'
    $small=New-DomeniaQueryRecipe -Name 'RAM < 8' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=8}) -GroupBy model
    $measured=Measure-DomeniaQueryWidget $records $small
    $expected=0
    for($n=1;$n -le $Count;$n++){if($n%10 -ne 0 -and $n%7 -ne 0 -and $n%13 -ne 0 -and $n%11 -ne 0 -and $n%4 -eq 0){$expected++}}
    Expect ($measured.Matched -eq $expected) 'RAM widget excludes missing, stale and recreated observations'
    foreach($item in $measured.Items){$ids=Get-DomeniaQueryMatchIds $records (New-DomeniaQuerySegmentRecipe $small $item.Select);Expect ($ids.Count -eq $item.Value) 'every distribution segment equals its drilldown'}
    Mark 'WidgetDrilldown'
    $Payload.Scope='OU=Beta,DC=example,DC=invalid';$Payload.ScopeKey=$Payload.Scope
    $Payload|Add-Member -NotePropertyName ComputeBoard -NotePropertyValue $true
    $Payload|Add-Member -NotePropertyName ModuleRoot -NotePropertyValue $modules
    $Payload|Add-Member -NotePropertyName Lifecycle -NotePropertyValue $null
    $Payload|Add-Member -NotePropertyName ObservationMaxAgeDays -NotePropertyValue 30
    $Payload|Add-Member -NotePropertyName IndexPartial -NotePropertyValue ''
    $beta=& $reader
    Expect ($beta.Machines.Count -eq $Count/5 -and $beta.Targets.Count -eq $Count/10) 'OU scope includes exactly its active and disabled objects'
    Expect ([long]$beta.Board.Entries['fleet.machines'].Value -eq $Count/5) 'board rules execute inside the background worker'
    Mark 'ScopedRead'
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for($offset=0;$offset -lt $Count;$offset+=200){
        $Payload=[pscustomobject]@{Action='Search';Path=$path;BusyTimeoutMs=250;Term='';Browse=$true;Scope='';Limit=200;Offset=$offset}
        $page=& $reader
        Expect ($page.Total -eq $Count -and $page.Offset -eq $offset) 'base browser count and offset cover whole population'
        foreach($r in $page.Rows){Expect ($seen.Add($r.Guid)) 'no duplicate in base browser pagination'}
    }
    Expect ($seen.Count -eq $Count -and -not $page.HasMore) 'base browser includes every row beyond the former 200/500 cap'
    $Payload.Scope='OU=Beta,DC=example,DC=invalid';$Payload.Offset=0;$Payload.Term='PC-'
    $page=& $reader;Expect ($page.Total -eq $Count/5 -and $page.Rows.Count -eq 200) 'local search respects chosen OU with exact total'
    $Payload.Term='PC-%';$page=& $reader;Expect ($page.Total -eq 0) 'wildcards in local search are literal'
    Mark 'BaseBrowserPages'
    $retained=[GC]::GetTotalMemory($true);$process=[Diagnostics.Process]::GetCurrentProcess()
    $report=[ordered]@{Count=$Count;ProbesPerObservedComputer=$ProbeCount;Checks=$script:checks;Passed=$true;PowerShell=$PSVersionTable.PSVersion.ToString();Host=[Environment]::OSVersion.ToString();TimingsMs=$times;PeakWorkingSetMB=$(if($process.PeakWorkingSet64 -gt 0){[Math]::Round($process.PeakWorkingSet64/1MB,1)}else{$null});ManagedRetainedMB=[Math]::Round($retained/1MB,1);DatabaseMB=[Math]::Round((Get-Item $path).Length/1MB,1);Qualification='Local synthetic SQLite and pure rules only; Windows/WPF/AD not evaluated'}
    $json=$report|ConvertTo-Json -Depth 5
    if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),$json,[Text.UTF8Encoding]::new($false))}
    Write-Output $json
}finally{if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder,$true)}}
