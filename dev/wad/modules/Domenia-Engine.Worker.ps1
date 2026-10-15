# D014 worker bodies: local reads that used to block the Dispatcher. Each function returns ONE single-quoted
# here-string (ASCII body) pinned by SHA-256 in the closed worker registry. They receive $Context and $Payload.

function Get-DomeniaLocalIndexReadWorkerCode {
    # LocalIndexRead: read-only SQLite access with a bounded busy timeout (FI-12). A locked base returns Busy=$true,
    # never an empty answer presented as a result.
    return @'
$action = [string]$Payload.Action
if ($action -notin @('Search','ParkState','ParkTargets','FleetStats','ResolveNames','StoreRead','IndexMetadata','UserMachineLinks','SecretIndexEntry','OperationStats')) { throw 'Lecture locale non autorisee.' }
$path = [IO.Path]::GetFullPath([string]$Payload.Path)
if ($path.StartsWith('\\')) { throw 'Base locale reseau non prise en charge.' }
if (-not [IO.File]::Exists($path)) { return [pscustomobject]@{ Rows=@(); Busy=$false; Missing=$true; MachineCount=0 } }
# FI-12: an explicit short wait of the caller (type-ahead) wins; otherwise the configured lock wait of the worker
# context (LocalStore.DatabaseBusyTimeoutMs, 2 500 ms documented) applies.
$busyMs = 2500
$workerContext = Get-Variable -Name Context -ValueOnly -ErrorAction SilentlyContinue
if (($null -ne $Payload.PSObject.Properties['BusyTimeoutMs']) -and ([int]$Payload.BusyTimeoutMs -gt 0)) { $busyMs = [int]$Payload.BusyTimeoutMs }
elseif (($null -ne $workerContext) -and ($null -ne $workerContext.PSObject.Properties['BusyTimeoutMs'])) { $busyMs = [int]$workerContext.BusyTimeoutMs }
$busyMs = [Math]::Max(10,[Math]::Min(5000,$busyMs))
function New-IdxWUtf8 {
    param([AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes(([string]$Text) + [char]0)
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
    return $ptr
}
function ConvertFrom-IdxWUtf8 {
    param([IntPtr]$Pointer,[int]$Length = -1)
    if ($Pointer -eq [IntPtr]::Zero) { return '' }
    if ($Length -lt 0) { $Length = 0; while ([Runtime.InteropServices.Marshal]::ReadByte($Pointer,$Length) -ne 0) { $Length++ } }
    if ($Length -le 0) { return '' }
    $bytes = New-Object byte[] $Length
    [Runtime.InteropServices.Marshal]::Copy($Pointer,$bytes,0,$Length)
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function Get-IdxWLiteral {
    param($Value)
    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [int] -or $Value -is [long]) { return ([Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)) }
    return "'" + (([string]$Value) -replace "'","''") + "'"
}
function Get-IdxWDnSeparators {
    param([string]$Column)
    # Keep character offsets while hiding escaped backslash pairs, then escaped
    # commas. Only actual RDN separators survive, including after even slash runs.
    if ($Column -notin @('dn','distinguished_name','a.distinguished_name')) { throw 'Colonne DN invalide.' }
    return "replace(replace($Column,'\\','xx'),'\,','xx')"
}
function Get-IdxWDnScopeSql {
    param([string]$Column,[string]$Scope,[bool]$Subtree=$true)
    if (-not $Scope) { return '1=1' }
    $separators=Get-IdxWDnSeparators $Column
    $scopeLit=Get-IdxWLiteral $Scope; $suffixLit=Get-IdxWLiteral (','+$Scope)
    # SQLite length counts Unicode code points. A .NET UTF-16 Length would cut a
    # supplementary-character scope at the wrong position.
    $length="length($suffixLit)"
    $children="(substr($Column,-$length)=$suffixLit COLLATE NOCASE AND substr($separators,-$length,1)=','"
    if (-not $Subtree) { return $children+" AND instr($separators,',')=length($Column)-$length+1)" }
    return "($Column=$scopeLit COLLATE NOCASE OR "+$children+'))'
}
function Invoke-IdxWQuery {
    param([IntPtr]$Db,[string]$Sql)
    $sqlPtr = [IntPtr]::Zero; $stmt = [IntPtr]::Zero
    $rows = New-Object 'System.Collections.Generic.List[object]'
    try {
        $sqlPtr = New-IdxWUtf8 $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_prepare_v2($Db,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if ($rc -eq 5 -or $rc -eq 6) { throw 'SQLITE_BUSY' }
        if ($rc -ne 0) { throw ('SQLite prepare code ' + $rc + ' : ' + (ConvertFrom-IdxWUtf8 ([Domenia.WinSqliteNative]::sqlite3_errmsg($Db)))) }
        $count = [Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
        # Column names are read once per statement, not once per cell (thousands of rows for the overview).
        $names = New-Object 'string[]' ([Math]::Max(0,$count))
        for ($i = 0; $i -lt $count; $i++) { $names[$i] = ConvertFrom-IdxWUtf8 ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i)) }
        while (($step = [Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100) {
            $o = [ordered]@{}
            for ($i = 0; $i -lt $count; $i++) {
                $name = $names[$i]
                $type = [Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$i)
                $value = $null
                if ($type -eq 1) { $value = [long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$i) }
                elseif ($type -eq 2) { $value = [double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$i) }
                elseif ($type -ne 5) { $p = [Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n = [Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value = ConvertFrom-IdxWUtf8 $p $n }
                $o[$name] = $value
            }
            $rows.Add([pscustomobject]$o)
        }
        if ($step -eq 5 -or $step -eq 6) { throw 'SQLITE_BUSY' }
        if ($step -ne 101) { throw ('SQLite step code ' + $step + ' : ' + (ConvertFrom-IdxWUtf8 ([Domenia.WinSqliteNative]::sqlite3_errmsg($Db)))) }
        return $rows.ToArray()
    }
    finally {
        if ($stmt -ne [IntPtr]::Zero) { try { [void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
    }
}
function ConvertTo-DomeniaSqlLiteral { param($Value); return Get-IdxWLiteral $Value }
function Invoke-DomeniaDbQuery { param([string]$Sql,[IntPtr]$DatabaseHandle); return Invoke-IdxWQuery $DatabaseHandle $Sql }
function Get-StoreWMap {
    param($Value)
    $map=[ordered]@{};if($Value -is [Collections.IDictionary]){foreach($key in $Value.Keys){$map[$key]=$Value[$key]}}elseif($null -ne $Value){foreach($p in $Value.PSObject.Properties){$map[$p.Name]=$p.Value}};return ,$map
}
function Convert-StoreWJsonValue {
    param($Value)
    if($Value -is [datetime]){return $Value.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
    if($Value -is [datetimeoffset]){return $Value.UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
    if($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]){return $Value}
    if($Value -is [array]){$items=[Collections.Generic.List[object]]::new();foreach($item in $Value){$items.Add((Convert-StoreWJsonValue $item))};return ,$items.ToArray()}
    $map=[ordered]@{};foreach($p in $Value.PSObject.Properties){$map[$p.Name]=Convert-StoreWJsonValue $p.Value};return [pscustomobject]$map
}
function Get-StoreWJson {
    param([string]$Json)
    if(-not $Json){return $null};return ,(Convert-StoreWJsonValue ($Json|ConvertFrom-Json -ErrorAction Stop))
}
function Convert-StoreWDirectory {
    param($Row)
    $details=$null;$saved=$null
    if($Row.store_payload){$saved=Get-StoreWJson ([string]$Row.store_payload);$details=$saved.Details}
    return [pscustomobject]@{Guid=[string]$Row.object_guid;DN=[string]$Row.distinguished_name;Type=[string]$Row.object_type;Name=[string]$Row.name;Login=[string]$Row.login;Upn=[string]$Row.upn;Display=[string]$Row.display_name;Description=[string]$Row.description;Extra=[string]$Row.extra;State=[string]$Row.state;WhenChanged=[string]$Row.when_changed;Usn=[long]$Row.usn_changed;LastLogon=[string]$Row.last_logon;Source=[string]$Row.source_dc;ObservedAtUtc=[string]$Row.synced_at;Details=$details;FieldTimes=(Get-StoreWJson ([string]$Row.field_times));FieldSources=$(if($null -ne $saved){$saved.FieldSources}else{$null});Revision=[long]$Row.store_revision}
}
function Convert-StoreWObservation {
    # RecordedAtUtc: commit time of the batch that last wrote this row (point 10), '' when it was not read.
    param($Row,[string]$Kind='Observation')
    return [pscustomobject]@{Kind=$Kind;SummaryMissing=([bool]$Row.summary_missing);Guid=[string]$Row.object_guid;DN=[string]$Row.dn;Family=[string]$Row.family;ResultKind=[string]$Row.result_kind;RequestKey=[string]$Row.request_key;LastAttemptAtUtc=[string]$Row.attempt_at;Status=[string]$Row.status;Error=[string]$Row.error;LastSuccessAtUtc=[string]$Row.success_at;Data=(Get-StoreWJson ([string]$Row.payload));AttemptData=(Get-StoreWJson ([string]$Row.attempt_payload));DefinitionHash=[string]$Row.definition_hash;Revision=[long]$Row.revision;RecordedAtUtc=[string]$Row.recorded_at}
}
function Get-StoreWProjection {
    param([object[]]$Observations,[string]$Name='')
    if(-not $Observations.Count){return $null}
    $first=$Observations[0];$p=[ordered]@{Version=1;Key=([string]$first.DN).ToLowerInvariant();Guid=[string]$first.Guid;Computer=$Name;CheckedUtc='';Revision=0L;Probes=[ordered]@{};Times=[ordered]@{}}
    foreach($o in $Observations){
        $p.Revision=[Math]::Max([long]$p.Revision,[long]$o.Revision)
        $data=$o.Data;$summaryProp=$o.PSObject.Properties['SummaryMissing'];$unavailable=$null;if($null -ne $data){$unavailable=$data.PSObject.Properties['SummaryUnavailable']};$summaryMissing=(($null -ne $summaryProp -and [bool]$summaryProp.Value) -or ($null -ne $unavailable -and [bool]$unavailable.Value))
        if([string]$o.Family -like 'Probe:*'){
            $probeId=([string]$o.Family).Substring(6);$probe=$data
            if($null -ne $data -and $null -ne $data.Probes){$probe=$data.Probes.$probeId}
            $probeMap=Get-StoreWMap $probe
            # The GUI projection is bounded. Full instance graphs remain in the typed family readback.
            if($probeMap.Contains('Instances')){[void]$probeMap.Remove('Instances')}
            if($summaryMissing){$probeMap.Skipped='SummaryUnavailable';$probeMap.SummaryMissing=$true}
            if([string]$o.Status -eq 'Error'){
                $probeMap.Error=$(if([string]$o.Error){[string]$o.Error}else{'Lecture non confirmee.'})
                $probeMap.AttemptedUtc=[string]$o.LastAttemptAtUtc
                $probeMap.CheckedUtc=[string]$o.LastSuccessAtUtc
                $probeMap.Succeeded=$false
            }
            $p.Probes[$probeId]=[pscustomobject]$probeMap
        }else{
            if($null -ne $data){foreach($field in $data.PSObject.Properties){if($field.Name -notin @('Guid','Key','DN','Version','Times','Probes','CheckedUtc') -and (-not $Name -or $field.Name -ne 'Computer')){$p[$field.Name]=$field.Value}}}
            # A failed attempt may replace diagnostics, never successful measured values with null/empty fields.
            if([string]$o.Status -eq 'Error' -and $null -ne $o.AttemptData){
                foreach($field in $o.AttemptData.PSObject.Properties){
                    if($field.Name -in @('Outcome','Detail','PresenceDetail','InventoryError','ConsoleError','Error','ErrorKind','Status','DirectoryAuthRejected')){$p[$field.Name]=$field.Value}
                }
            }
        }
        $timeName=[string]$o.Family
        if($summaryMissing){$p['SummaryMissing.'+$timeName]=$true}
        $p.Times[$timeName]=[pscustomobject]@{ObservedUtc=[string]$o.LastSuccessAtUtc;LastAttemptUtc=[string]$o.LastAttemptAtUtc;Succeeded=([string]$o.Status -eq 'Success')}
        if([string]::CompareOrdinal([string]$o.LastAttemptAtUtc,[string]$p.CheckedUtc) -gt 0){$p.CheckedUtc=[string]$o.LastAttemptAtUtc;$p.Key=([string]$o.DN).ToLowerInvariant()}
        switch([string]$o.Family){
            'Presence' {$p.PresenceCheckedUtc=[string]$o.LastSuccessAtUtc;$p.PresenceAttemptUtc=[string]$o.LastAttemptAtUtc;$p.PresenceError=[string]$o.Error;if($o.Status -eq 'Error'){$p.Presence='Erreur de ping'}}
            'Console' {$p.ObservedUtc=[string]$o.LastSuccessAtUtc;$p.ConsoleCheckedUtc=[string]$o.LastSuccessAtUtc;$p.UserCheckedUtc=[string]$o.LastSuccessAtUtc;$p.ConsoleAttemptUtc=[string]$o.LastAttemptAtUtc;$p.ConsoleError=[string]$o.Error;if($o.Status -eq 'Error' -and -not $p.Outcome){$p.Outcome='Unavailable'}}
            'Inventory' {$p.InventoryCheckedUtc=[string]$o.LastSuccessAtUtc;$p.InventoryAttemptUtc=[string]$o.LastAttemptAtUtc;$p.InventoryError=[string]$o.Error}
        }
    }
    return [pscustomobject]$p
}
function Read-StoreWCommitted {
    param([IntPtr]$Db,[string[]]$Guids,[bool]$IncludeDirectoryDetails=$true,[bool]$IncludeObservations=$true,[bool]$IncludeDetails=$true,[string]$DetailWhere='1=1',[string[]]$ObservationFamilies=$null,[ValidateSet('Full','QuerySummary')][string]$DetailProjection='Full',[ValidateSet('Full','Summary')][string]$ObservationProjection='Full',[bool]$IncludeRecordedTime=$false)
    $keys=@($Guids|Select-Object -Unique|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ','
    # Point 10: the recorded time of a measure is the commit of the batch that wrote its row (same snapshot).
    $observationRecorded=if($IncludeRecordedTime){',(SELECT b.committed_at FROM domenia_store_batches b WHERE b.revision=domenia_observations.revision) AS recorded_at'}else{''}
    $detailRecorded=if($IncludeRecordedTime){',(SELECT b.committed_at FROM domenia_store_batches b WHERE b.revision=domenia_details.revision) AS recorded_at'}else{''}
    $rows=[Collections.Generic.List[object]]::new();$observations=[Collections.Generic.List[object]]::new();$details=[Collections.Generic.List[object]]::new();$projections=[Collections.Generic.List[object]]::new()
    if($keys){
        $names=@{};$payloadColumn=if($IncludeDirectoryDetails){'d.payload'}else{'NULL'}
        foreach($r in @(Invoke-DomeniaDbQuery ("SELECT a.*,$payloadColumn AS store_payload,d.field_times,d.revision AS store_revision FROM ad_objects a LEFT JOIN domenia_directory_data d ON d.object_guid=a.object_guid WHERE a.object_guid IN ($keys) ORDER BY a.name COLLATE NOCASE,a.object_guid;") $Db)){$rows.Add((Convert-StoreWDirectory $r));$names[[string]$r.object_guid]=[string]$r.name}
        $groups=@{};$familyWhere=''
        if($PSBoundParameters.ContainsKey('ObservationFamilies') -and $null -ne $ObservationFamilies){
            foreach($family in @($ObservationFamilies)){if($family -notmatch '^(Presence|Console|Inventory|Probe:[A-Za-z0-9_.-]{1,128})$'){throw 'Famille de lecture invalide.'}}
            $families=@($ObservationFamilies|Select-Object -Unique|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ','
            $familyWhere=if($families){" AND family IN ($families)"}else{' AND 0=1'}
        }
        if($IncludeObservations){
        $observationColumns='*'
        if($ObservationProjection -eq 'Summary'){
            $available=@(Invoke-DomeniaDbQuery 'PRAGMA table_info(domenia_observations);' $Db|ForEach-Object{[string]$_.name})
            $successSummary=if($available -contains 'summary_payload'){'summary_payload'}else{'NULL'};$attemptSummary=if($available -contains 'attempt_summary'){'attempt_summary'}else{'NULL'}
            $successRead="CASE WHEN $successSummary IS NOT NULL AND length(CAST($successSummary AS BLOB))<=262144 THEN $successSummary WHEN $successSummary IS NULL AND length(CAST(payload AS BLOB))<=16384 THEN payload ELSE NULL END"
            $attemptRead="CASE WHEN $attemptSummary IS NOT NULL AND length(CAST($attemptSummary AS BLOB))<=262144 THEN $attemptSummary WHEN $attemptSummary IS NULL AND length(CAST(attempt_payload AS BLOB))<=16384 THEN attempt_payload ELSE NULL END"
            $missing="CASE WHEN payload IS NOT NULL AND payload<>'null' AND ($successRead) IS NULL THEN 1 ELSE 0 END"
            $observationColumns="object_guid,family,dn,definition_hash,attempt_at,status,error,success_at,revision,$successRead AS payload,$attemptRead AS attempt_payload,$missing AS summary_missing"
        }
        foreach($r in @(Invoke-DomeniaDbQuery ("SELECT $observationColumns$observationRecorded FROM domenia_observations WHERE object_guid IN ($keys)$familyWhere ORDER BY object_guid,family;") $Db)){
            $o=Convert-StoreWObservation $r;$observations.Add($o)
            if(-not $groups.ContainsKey($o.Guid)){$groups[$o.Guid]=[Collections.Generic.List[object]]::new()};$groups[$o.Guid].Add($o)
        }
        foreach($g in $groups.Keys){$projections.Add((Get-StoreWProjection $groups[$g].ToArray() ([string]$names[$g])))}}
        if($IncludeDetails){
            $detailColumns='*'
            if($DetailProjection -eq 'QuerySummary'){
                $available=@(Invoke-DomeniaDbQuery 'PRAGMA table_info(domenia_details);' $Db|ForEach-Object{[string]$_.name})
                $successColumn=if($available -contains 'summary_payload'){'summary_payload'}else{'NULL'};$attemptColumn=if($available -contains 'attempt_summary'){'attempt_summary'}else{'NULL'}
                # No JSON extension and no full payload scan: old rows without a summary stay unknown.
                $detailColumns="object_guid,result_kind,request_key,dn,attempt_at,status,error,success_at,revision,$successColumn AS payload,$attemptColumn AS attempt_payload"
            }
            foreach($r in @(Invoke-DomeniaDbQuery ("SELECT $detailColumns$detailRecorded FROM domenia_details WHERE object_guid IN ($keys) AND ($DetailWhere) ORDER BY object_guid,result_kind,request_key;") $Db)){$details.Add((Convert-StoreWObservation $r 'DetailResult'))}
        }
    }
    $state=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_state WHERE id=1;' $Db)
    return [pscustomobject]@{Rows=$rows.ToArray();Observations=$observations.ToArray();ObservationRows=$projections.ToArray();Details=$details.ToArray();SnapshotRevision=$(if($state.Count){[long]$state[0].revision}else{0L})}
}
function Invoke-StoreWLibraryQuery {
    param([string]$Sql,[IntPtr]$Db)
    return @(Invoke-IdxWQuery $Db $Sql)
}
function Convert-StoreWQueryRecipe {
    param($Row)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$actual=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Row.definition_json))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    if($actual -cne [string]$Row.definition_sha256){throw 'Corruption de definition dans la bibliotheque locale.'}
    return [pscustomobject]@{Id=[string]$Row.id;DomainDn=[string]$Row.domain_dn;Name=[string]$Row.name;NameFold=[string]$Row.name_fold;Category=[string]$Row.category;Revision=[long]$Row.revision;DefinitionVersion=[int]$Row.definition_version;DefinitionJson=[string]$Row.definition_json;DefinitionSHA256=[string]$Row.definition_sha256;CreatedUtc=[string]$Row.created_utc;UpdatedUtc=[string]$Row.updated_utc;Archived=([int]$Row.archived -ne 0)}
}
function Read-StoreWQueryLibrary {
    param([IntPtr]$Db,$Query,[string]$DomainDn,[long]$SnapshotRevision,[string]$StoreId,[string[]]$RecipeIds=$null)
    if([string]$Query.StoreId -cne $StoreId -or [string]$Query.DomainDn -ine $DomainDn){throw 'Contexte de lecture de bibliotheque incoherent.'}
    if([long]$Query.MinimumRevision -gt $SnapshotRevision -or ([long]$Query.SnapshotRevision -gt 0 -and [long]$Query.SnapshotRevision -ne $SnapshotRevision)){throw 'Revision de bibliotheque demandee non disponible.'}
    $limit=100;if($null -ne $Query.PSObject.Properties['Limit']){$limit=[int]$Query.Limit};$offset=[int]$Query.Offset
    if($limit -lt 1 -or $limit -gt 250 -or $offset -lt 0 -or [string]$Query.OrderBy -notin @('','name_fold,id') -or ([string]$Query.Term).Length -gt 256 -or ([string]$Query.Category).Length -gt 80){throw 'Pagination ou filtre de bibliotheque invalide.'}
    $exists=@(Invoke-StoreWLibraryQuery "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_query_recipes';" $Db)
    $rows=@();$migrations=@();$dependencies=@();$total=0L
    if($exists.Count){
        $where='domain_dn='+(Get-IdxWLiteral $DomainDn)
        if(-not [bool]$Query.IncludeArchived){$where+=' AND archived='+[int][bool]$Query.Archived}
        # instr is literal: percent, underscore and quotes cannot widen this filter.
        if([string]$Query.Term){$where+=' AND instr(name_fold,'+(Get-IdxWLiteral ([string]$Query.Term))+')>0'}
        if([string]$Query.Category){$where+=' AND category='+(Get-IdxWLiteral ([string]$Query.Category))}
        if($null -ne $RecipeIds){
            if($RecipeIds.Count -gt 250){throw 'Trop de recettes pour une page.'}
            foreach($id in $RecipeIds){if($id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$'){throw 'Identifiant de lecture de recette invalide.'}}
            if($RecipeIds.Count){$where+=' AND id IN ('+(@($RecipeIds|ForEach-Object{Get-IdxWLiteral $_}) -join ',')+')'}else{$where+=' AND 0=1'}
        }
        $total=[long](@(Invoke-StoreWLibraryQuery "SELECT count(*) AS n FROM domenia_query_recipes WHERE $where;" $Db)[0].n)
        $rows=@(Invoke-StoreWLibraryQuery "SELECT * FROM domenia_query_recipes WHERE $where ORDER BY name_fold,id LIMIT $limit OFFSET $offset;" $Db|ForEach-Object{Convert-StoreWQueryRecipe $_})
        if($rows.Count){$keys=@($rows|ForEach-Object{Get-IdxWLiteral $_.Id}) -join ',';$dependencies=@(Invoke-StoreWLibraryQuery "SELECT recipe_id AS RecipeId,consumer_kind AS ConsumerKind,consumer_id AS ConsumerId,bound_revision AS BoundRevision FROM domenia_query_recipe_dependencies WHERE recipe_id IN ($keys) ORDER BY recipe_id,consumer_kind,consumer_id;" $Db)}
        $migrationTable=@(Invoke-StoreWLibraryQuery "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_query_migrations';" $Db)
        if($migrationTable.Count){$migrations=@(Invoke-StoreWLibraryQuery ('SELECT source_hash AS SourceHash,domain_dn AS DomainDn,imported_at AS ImportedAtUtc,revision AS Revision FROM domenia_query_migrations WHERE domain_dn='+(Get-IdxWLiteral $DomainDn)+' ORDER BY source_hash;') $Db)}
    }
    return [pscustomobject]@{QueryRecipes=$rows;QueryDependencies=$dependencies;QueryMigrations=$migrations;Total=$total;Offset=$offset;Limit=$limit;SnapshotRevision=$SnapshotRevision}
}

function Convert-IdxWParkObservationSummary {
    # Scheduling needs provenance and identity, never the per-instance data graph of old probes.
    # This is a detached in-memory projection, not a payload to write back into SQLite.
    param($Projection)
    $map=Get-StoreWMap $Projection;$summaries=[ordered]@{}
    $source=Get-StoreWMap $map['Probes']
    foreach($id in $source.Keys){
        $original=Get-StoreWMap $source[$id];$summary=[ordered]@{}
        foreach($field in @('CheckedUtc','AttemptedUtc','Error','Skipped','Truncated','Count','CountComplete','StoredCount','LimitReason','DefinitionHash','Succeeded')){if($original.Contains($field)){$summary[$field]=$original[$field]}}
        $summaries[$id]=[pscustomobject]$summary
    }
    $map['Probes']=[pscustomobject]$summaries;$map['SummaryOnly']=$true
    return [pscustomobject]$map
}
function Convert-IdxWFleetObservationSummary {
    # Native decoding is bounded per persisted family. Never concatenate every detailed family into one JSON.
    param($Projection,$Reader,[datetime]$NowUtc)
    $probes=Get-StoreWMap $Projection.Probes;$summaries=[ordered]@{}
    foreach($id in $probes.Keys){
        try{$summaries[$id]=$Reader.ReadProbe([string]$id,($probes[$id]|ConvertTo-Json -Depth 20 -Compress),$NowUtc)}
        catch{
            $old=Get-StoreWMap $probes[$id]
            $summaries[$id]=[pscustomobject]@{CheckedUtc=[string]$old['CheckedUtc'];AttemptedUtc=[string]$old['AttemptedUtc'];Error='Résumé local de cette sonde illisible ; détail conservé en base.';Skipped='';Truncated=$true;Rows=@();Count=$null;SummaryOnly=$true}
        }
    }
    $Projection.Probes=[pscustomobject]$summaries
    $Projection|Add-Member -NotePropertyName SummaryOnly -NotePropertyValue $true -Force
    return $Projection
}

function Read-IdxWCanonicalObservations {
    # Caller owns a read transaction across every chunk. A marker certifies the complete legacy family import.
    param([IntPtr]$Db,[object[]]$Owners,[Collections.IDictionary]$Tables,[Collections.IDictionary]$LegacyKeys,[ValidateSet('Fleet','Park')][string]$ProjectionKind='Fleet',$Reader=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    $answer=@{};$replaced=@{}
    if(-not $Tables.Contains('domenia_observations') -or -not $Tables.Contains('domenia_store_state')){return [pscustomobject]@{Rows=$answer;Replaced=$replaced}}
    $unique=@{};foreach($owner in $Owners){$g=[string]$owner.object_guid;if($g){$unique[$g]=$owner}}
    $guids=@($unique.Keys)
    # Smaller batches bound transient typed family graphs before compact native projection.
    for($offset=0;$offset -lt $guids.Count;$offset+=32){
        $slice=@($guids[$offset..([Math]::Min($offset+31,$guids.Count-1))]);$migrated=@{}
        if($Tables.Contains('domenia_legacy_observation_imports')){
            $keys=@($slice|ForEach-Object{Get-IdxWLiteral $_}) -join ','
            foreach($marker in @(Invoke-IdxWQuery $Db ("SELECT object_guid FROM domenia_legacy_observation_imports WHERE object_guid IN ($keys);"))){$migrated[[string]$marker.object_guid]=$true}
        }
        $selected=[Collections.Generic.List[string]]::new()
        foreach($guid in $slice){$owner=$unique[$guid];$dn=([string]$owner.distinguished_name).ToLowerInvariant();if($migrated.ContainsKey($guid) -or -not $LegacyKeys.Contains($dn)){$selected.Add($guid);$replaced[$dn]=$true}}
        if(-not $selected.Count){continue}
        $args=@{Db=$Db;Guids=$selected.ToArray();IncludeDirectoryDetails=$false;IncludeDetails=$false}
        if($null -ne $Payload.PSObject.Properties['ObservationFamilies'] -and $null -ne $Payload.ObservationFamilies){$args.ObservationFamilies=@($Payload.ObservationFamilies)}
        # Fleet and Park only. StoreRead keeps the default Full payload.
        $args.ObservationProjection='Summary'
        $read=Read-StoreWCommitted @args
        foreach($projection in @($read.ObservationRows)){
            $owner=$unique[[string]$projection.Guid];if($null -eq $owner){continue}
            $key=([string]$owner.distinguished_name).ToLowerInvariant();$projection.Key=$key;$projection.Computer=[string]$owner.name
            $answer[$key]=if($ProjectionKind -eq 'Park'){Convert-IdxWParkObservationSummary $projection}else{Convert-IdxWFleetObservationSummary -Projection $projection -Reader $Reader -NowUtc $NowUtc}
        }
    }
    return [pscustomobject]@{Rows=$answer;Replaced=$replaced}
}

$db = [IntPtr]::Zero
try {
    $pathPtr = New-IdxWUtf8 $path
    try { $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,(1 -bor 65536),[IntPtr]::Zero) }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) }
    if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw ('Ouverture SQLite en lecture impossible (code ' + $rc + ').') }
    [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
    if ($action -eq 'StoreRead') {
        $query=$Payload.Query;$kind=[string]$query.Kind
        $sqliteVersion=[string](@(Invoke-IdxWQuery $db 'SELECT sqlite_version() AS v;')[0].v)
        if($kind -notin @('Directory','Observation','Detail','AccountPreference','QueryLibrary')){throw 'Lecture canonique inconnue.'}
        [void](Invoke-IdxWQuery $db 'BEGIN;')
        $exists=@(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_store_state';")
        if(-not $exists.Count){[void](Invoke-IdxWQuery $db 'COMMIT;');return [pscustomobject]@{DataSource='SQLite';Missing=$true;Busy=$false;Rows=@();Observations=@();ObservationRows=@();Details=@();AccountPreferences=@();Total=0;Revision=0;SnapshotRevision=0}}
        $state=@(Invoke-IdxWQuery $db 'SELECT * FROM domenia_store_state WHERE id=1;')
        if(-not $state.Count){
            $legacy=@(Invoke-IdxWQuery $db "SELECT base_dn FROM sync_state WHERE scope='directory' AND COALESCE(base_dn,'')<>'';")
            if($legacy.Count -and [string]$legacy[0].base_dn -ine [string]$Payload.DomainDn){throw 'Domaine de la base existante incompatible.'}
        }
        if($state.Count -and ([string]$state[0].store_id -cne [string]$Payload.StoreId -or [string]$state[0].domain_dn -ine [string]$Payload.DomainDn)){throw 'Contexte de lecture ne correspond pas a la base.'}
        $revision=if($state.Count){[long]$state[0].revision}else{0L}
        if($revision -lt [long]$query.MinimumRevision){throw 'Revision demandee non encore disponible.'}
        if($null -ne $query.PSObject.Properties['SnapshotRevision'] -and [long]$query.SnapshotRevision -gt 0 -and [long]$query.SnapshotRevision -ne $revision){throw 'Instantane demande modifie ; rechargez les donnees avant de continuer.'}
        if($kind -eq 'QueryLibrary'){
            $library=Read-StoreWQueryLibrary -Db $db -Query $query -DomainDn ([string]$Payload.DomainDn) -SnapshotRevision $revision -StoreId ([string]$Payload.StoreId)
            [void](Invoke-IdxWQuery $db 'COMMIT;')
            return [pscustomobject]@{DataSource='SQLite';SQLiteVersion=$sqliteVersion;StoreId=[string]$Payload.StoreId;Path=$path;DomainDn=[string]$Payload.DomainDn;Missing=$false;Busy=$false;Rows=@();Observations=@();ObservationRows=@();Details=@();AccountPreferences=@();QueryRecipes=$library.QueryRecipes;QueryDependencies=$library.QueryDependencies;QueryMigrations=$library.QueryMigrations;Total=$library.Total;Offset=$library.Offset;Limit=$library.Limit;Revision=$revision;SnapshotRevision=$library.SnapshotRevision}
        }
        $limit=[Math]::Max(1,[Math]::Min(5000,$(if([int]$query.Limit -gt 0){[int]$query.Limit}else{250})));$offset=[Math]::Max(0,[int]$query.Offset)
        $conditions=[Collections.Generic.List[string]]::new();$conditions.Add('1=1')
        $guids=@($query.Guids|Where-Object{$_}|Select-Object -Unique)
        if($null -ne $query.PSObject.Properties['Guids'] -and -not $guids.Count){$conditions.Add('0=1')}
        if($guids.Count -gt 5000){throw 'Trop de GUID pour une page.'}
        foreach($g in $guids){$parsed=[guid]::Empty;if(-not [guid]::TryParse([string]$g,[ref]$parsed)){throw 'GUID de lecture invalide.'}}
        $guidSql=@($guids|ForEach-Object{Get-IdxWLiteral (([guid]$_).ToString('D'))}) -join ','
        $accountPreferences=@()
        if($kind -eq 'AccountPreference'){
            $scope=[string]$query.Scope;$where='domain_dn='+(Get-IdxWLiteral ([string]$Payload.DomainDn))
            if($scope){$where+=' AND scope='+(Get-IdxWLiteral $scope)}
            $accountPreferences=@(Invoke-IdxWQuery $db ("SELECT scope AS Scope,user_name AS UserName,domain_dn AS DomainDn,updated_at AS UpdatedAtUtc,revision AS Revision FROM domenia_account_preferences WHERE $where ORDER BY scope;"))
            $read=[pscustomobject]@{Rows=@();Observations=@();ObservationRows=@();Details=@();SnapshotRevision=$revision};$total=$accountPreferences.Count
        }else{
            if($kind -eq 'Directory'){
                $table='ad_objects';$column='object_guid';if($guidSql){$conditions.Add("object_guid IN ($guidSql)")}
                if([string]$query.ScopeDn){$conditions.Add((Get-IdxWDnScopeSql 'distinguished_name' ([string]$query.ScopeDn) ([bool]$query.Subtree)))}
                $types=@($query.Types|Where-Object{$_});foreach($type in $types){if([string]$type -notin @('Machine','Utilisateur','Groupe','OU','Conteneur')){throw 'Type de lecture invalide.'}}
                if($types.Count){$conditions.Add('object_type IN ('+(@($types|ForEach-Object{Get-IdxWLiteral $_}) -join ',')+')')}
                if([string]$query.Term){$term=([string]$query.Term).Trim().ToLowerInvariant();if($term.Length -gt 1024){throw 'Filtre trop long.'};$conditions.Add("instr(COALESCE(search_key,''),"+(Get-IdxWLiteral $term)+')>0')}
                $order='name COLLATE NOCASE,object_guid'
            }else{
                $table=if($kind -eq 'Observation'){'domenia_observations'}else{'domenia_details'};$column='object_guid';$order='object_guid'
                if($guidSql){$conditions.Add("object_guid IN ($guidSql)")}
                if([string]$query.ScopeDn){$conditions.Add((Get-IdxWDnScopeSql 'dn' ([string]$query.ScopeDn) ([bool]$query.Subtree)))}
                if($kind -eq 'Observation' -and [string]$query.Family){$conditions.Add('family='+(Get-IdxWLiteral ([string]$query.Family)))}
                if($kind -eq 'Detail' -and [string]$query.ResultKind){$conditions.Add('result_kind='+(Get-IdxWLiteral ([string]$query.ResultKind)))}
                if($kind -eq 'Detail' -and [string]$query.RequestKey){$conditions.Add('request_key='+(Get-IdxWLiteral ([string]$query.RequestKey)))}
            }
            $where=$conditions -join ' AND ';$total=[long](@(Invoke-IdxWQuery $db "SELECT count(DISTINCT $column) AS n FROM $table WHERE $where;")[0].n)
            $page=@(Invoke-IdxWQuery $db "SELECT DISTINCT $column FROM $table WHERE $where ORDER BY $order LIMIT $limit OFFSET $offset;")
            $detailWhere='1=1';if($kind -eq 'Detail'){if([string]$query.ResultKind){$detailWhere+=' AND result_kind='+(Get-IdxWLiteral ([string]$query.ResultKind))};if([string]$query.RequestKey){$detailWhere+=' AND request_key='+(Get-IdxWLiteral ([string]$query.RequestKey))}}
            $readArgs=@{Db=$db;Guids=@($page|ForEach-Object{[string]$_.object_guid});IncludeDirectoryDetails=([string]$query.Projection -ne 'List');IncludeObservations=($kind -eq 'Observation' -or [bool]$query.IncludeObservations);IncludeDetails=($kind -eq 'Detail');DetailWhere=$detailWhere}
            $readArgs.IncludeRecordedTime=(@(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_store_batches';").Count -gt 0)
            if($kind -eq 'Observation' -and [string]$query.Family){$readArgs.ObservationFamilies=@([string]$query.Family)}
            if($kind -eq 'Detail' -and $null -ne $query.PSObject.Properties['DetailProjection'] -and [string]$query.DetailProjection){$readArgs.DetailProjection=[string]$query.DetailProjection}
            $read=Read-StoreWCommitted @readArgs
            if($kind -eq 'Observation' -and [string]$query.Family){$read.Observations=@($read.Observations|Where-Object{[string]$_.Family -ceq [string]$query.Family})}
            if($kind -eq 'Detail'){$read.Details=@($read.Details|Where-Object{(-not [string]$query.ResultKind -or [string]$_.ResultKind -ceq [string]$query.ResultKind) -and (-not [string]$query.RequestKey -or [string]$_.RequestKey -ceq [string]$query.RequestKey)})}
        }
        [void](Invoke-IdxWQuery $db 'COMMIT;')
        return [pscustomobject]@{DataSource='SQLite';SQLiteVersion=$sqliteVersion;StoreId=[string]$Payload.StoreId;Path=$path;DomainDn=[string]$Payload.DomainDn;Missing=$false;Busy=$false;Rows=$read.Rows;Observations=$read.Observations;ObservationRows=$read.ObservationRows;Details=$read.Details;AccountPreferences=$accountPreferences;Total=$total;Offset=$offset;Limit=$limit;Revision=$revision;SnapshotRevision=$read.SnapshotRevision}
    }
    if ($action -eq 'ResolveNames') {
        # CO-08 (L04): presence of the accounts and workstations of an import file in the local index, read only.
        # Exact names only (login, workstation name or account), 1000 of each at most, queried by 200.
        $count = [int](@(Invoke-IdxWQuery $db 'SELECT count(*) AS n FROM ad_objects;')[0].n)
        $userNames = @(@($Payload.Users) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_.Length -le 256 } | Select-Object -Unique -First 1000)
        $computerNames = @(@($Payload.Computers) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_.Length -le 256 } | Select-Object -Unique -First 1000)
        $users = New-Object 'System.Collections.Generic.List[object]'
        $computers = New-Object 'System.Collections.Generic.List[object]'
        if ($count -gt 0) {
            for ($i = 0; $i -lt $userNames.Count; $i += 200) {
                $chunk = @($userNames[$i..([Math]::Min($i + 199,$userNames.Count - 1))] | ForEach-Object { Get-IdxWLiteral $_ })
                foreach ($r in @(Invoke-IdxWQuery $db ("SELECT login,object_guid,distinguished_name FROM ad_objects WHERE object_type='Utilisateur' AND login IN (" + ($chunk -join ',') + ');'))) { $users.Add($r) }
            }
            for ($i = 0; $i -lt $computerNames.Count; $i += 200) {
                $part = @($computerNames[$i..([Math]::Min($i + 199,$computerNames.Count - 1))])
                $names = @($part | ForEach-Object { Get-IdxWLiteral $_ }) -join ','
                $accounts = @($part | ForEach-Object { Get-IdxWLiteral ($_ + '$') }) -join ','
                foreach ($r in @(Invoke-IdxWQuery $db ("SELECT name,login,object_guid,distinguished_name FROM ad_objects WHERE object_type='Machine' AND (name IN (" + $names + ') OR login IN (' + $accounts + '));'))) { $computers.Add($r) }
            }
        }
        # UI-06: type and name of the members of a group shown in a fiche, by exact DN (2000 at most, queried by 200).
        $objects = New-Object 'System.Collections.Generic.List[object]'
        $dnNames = @()
        if ($null -ne $Payload.PSObject.Properties['Dns']) { $dnNames = @(@($Payload.Dns) | ForEach-Object { ([string]$_).Trim() } | Where-Object { ($_) -and ($_.Length -le 4096) } | Select-Object -Unique -First 2000) }
        if (($count -gt 0) -and ($dnNames.Count -gt 0)) {
            for ($i = 0; $i -lt $dnNames.Count; $i += 200) {
                $chunk = @($dnNames[$i..([Math]::Min($i + 199,$dnNames.Count - 1))] | ForEach-Object { Get-IdxWLiteral $_ })
                foreach ($r in @(Invoke-IdxWQuery $db ("SELECT object_type,name,distinguished_name FROM ad_objects WHERE distinguished_name COLLATE NOCASE IN (" + ($chunk -join ',') + ');'))) { $objects.Add($r) }
            }
        }
        [pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=0; IndexCount=$count; Users=$users.ToArray(); Computers=$computers.ToArray(); Objects=$objects.ToArray() }
        return
    }
    if ($action -eq 'ParkTargets') {
        [void](Invoke-IdxWQuery $db 'BEGIN;')
        $schema=@(Invoke-IdxWQuery $db "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');")
        if(@($schema|Where-Object{$_.key -eq 'schema_version' -and $_.value -ceq '11'}).Count -ne 1 -or @($schema|Where-Object{$_.key -eq 'domenia_schema' -and $_.value -ceq '1'}).Count -ne 1){throw 'Schema du parc incompatible.'}
        $source=if([string]$Payload.Scope -eq 'Results'){@($Payload.Targets)}else{@(Invoke-IdxWQuery $db "SELECT name,distinguished_name,object_guid FROM ad_objects WHERE object_type='Machine' AND state='Actif' ORDER BY name COLLATE NOCASE;")}
        $cacheSql='SELECT object_key,payload FROM park_session_cache'
        $usersSql="SELECT object_guid,usn_changed,distinguished_name,login FROM ad_objects WHERE object_type='Utilisateur'"
        if([string]$Payload.Scope -eq 'Results'){
            if(@($source).Count -gt 20000){throw 'Perimetre affiche trop grand (20 000 postes au plus).'}
            $keys=@($source|ForEach-Object{Get-IdxWLiteral (([string]$_.distinguished_name).ToLowerInvariant())})
            if(-not $keys.Count){[void](Invoke-IdxWQuery $db 'COMMIT;');[pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0};return}
            $cacheSql+=' WHERE object_key IN ('+($keys -join ',')+')'
        }
        $cache=@{};$legacyKeys=@{};$identityReader=[Domenia.Native.ObservationIdentityReader]::new()
        if(@(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table' AND name='park_session_cache';").Count){
            foreach($item in @(Invoke-IdxWQuery $db $cacheSql)){
                $legacyKeys[([string]$item.object_key).ToLowerInvariant()]=$true
                if(([string]$item.payload).Length -gt 262144){continue}
                try{
                    $observation=$identityReader.Read([string]$item.payload)
                    if([string]$observation.Key -ieq [string]$item.object_key){
                        $compact=Convert-IdxWParkObservationSummary (Get-StoreWJson ([string]$item.payload))
                        $cache[[string]$item.object_key]=[pscustomobject]@{Identity=$observation;Json=($compact|ConvertTo-Json -Depth 20 -Compress)}
                    }
                }catch{}
            }
        }
        $tables=@{};foreach($table in @(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table';")){$tables[[string]$table.name]=$true}
        $canonical=Read-IdxWCanonicalObservations -Db $db -Owners @($source) -Tables $tables -LegacyKeys $legacyKeys -ProjectionKind Park
        foreach($key in $canonical.Replaced.Keys){[void]$cache.Remove($key)}
        foreach($key in $canonical.Rows.Keys){
            $json=$canonical.Rows[$key]|ConvertTo-Json -Depth 20 -Compress
            try{$cache[$key]=[pscustomobject]@{Identity=$identityReader.Read($json);Json=$json}}catch{
                # A bad scheduling cache must trigger a new explicit read, not abort the whole fleet.
                [void]$cache.Remove($key)
            }
        }
        $users=@{};$usersByDn=@{};$usersByLogin=@{}
        if([string]$Payload.Scope -eq 'Results'){
            $conditions=New-Object 'System.Collections.Generic.List[string]'
            foreach($pair in @(@('UserGuid','object_guid'),@('UserDn','distinguished_name'),@('LinkUser','login'))){
                $field=[string]$pair[0]
                $values=@($cache.Values|Where-Object{$_.Identity.$field}|ForEach-Object{Get-IdxWLiteral ([string]$_.Identity.$field)}|Select-Object -Unique)
                if($values.Count){$conditions.Add($pair[1]+' COLLATE NOCASE IN ('+($values -join ',')+')')}
            }
            $usersSql+=if($conditions.Count){' AND ('+($conditions -join ' OR ')+')'}else{' AND 1=0'}
        }
        foreach($user in @(Invoke-IdxWQuery $db $usersSql)){
            if(-not $user.object_guid){continue}
            $users[[string]$user.object_guid]=$user
            foreach($pair in @(@($usersByDn,[string]$user.distinguished_name),@($usersByLogin,[string]$user.login))){
                $map=$pair[0];$value=[string]$pair[1];if(-not $value){continue}
                if(-not $map.ContainsKey($value)){$map[$value]=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)}
                [void]$map[$value].Add([string]$user.object_guid)
            }
        }
        $targets=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
        foreach($row in $source){
            $key=([string]$row.distinguished_name).ToLowerInvariant();$name=[string]$row.name;$guid=[string]$row.object_guid
            if(-not $key -or -not $guid -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$' -or $seen.ContainsKey($key)){continue}
            $seen[$key]=$true;$cached=$cache[$key];$previous=if($null -ne $cached){$cached.Identity}else{$null};$changed=$false
            if($null -ne $previous -and [string]$previous.Guid -ine $guid){$previous=$null}
            if($null -ne $previous){
                $user=$users[[string]$previous.UserGuid]
                $oldUsn=0L;$validUsn=[long]::TryParse([string]$previous.UserUsn,[ref]$oldUsn)
                $changed=(-not $validUsn -or $null -eq $user -or ($null -ne $user -and ([string]$user.distinguished_name -ine [string]$previous.UserDn -or [long]$user.usn_changed -gt $oldUsn)))
                # A known reused DN or login belongs to a new user even if the old GUID is absent.
                foreach($field in @('UserDn','LinkUser')){
                    $set=$null
                    if($field -eq 'UserDn'){$set=$usersByDn[[string]$previous.UserDn]}else{$set=$usersByLogin[[string]$previous.LinkUser]}
                    if($null -ne $set -and ($set.Count -ne 1 -or -not $set.Contains([string]$previous.UserGuid))){$changed=$true}
                }
            }
            $targets.Add([pscustomobject]@{Key=$key;Computer=$name;Guid=$guid;Previous=$null;PreviousJson=$(if($null -ne $previous){$cached.Json}else{''});DirectoryChanged=$changed})
        }
        [void](Invoke-IdxWQuery $db 'COMMIT;')
        [pscustomobject]@{Rows=$targets.ToArray();Busy=$false;Missing=$false;MachineCount=$targets.Count};return
    }
    if ($action -eq 'FleetStats') {
        if(-not (Get-Command New-DomeniaObservationReader -ErrorAction SilentlyContinue)){. (Join-Path ([string]$Payload.ModuleRoot) 'Domenia-Probes.Model.ps1')}
        $observationReader=New-DomeniaObservationReader
        $observationNow=[datetime]::UtcNow
        $observationRejected=0
        [void](Invoke-IdxWQuery $db 'BEGIN;')
        # Aggregates of the local index for the home dashboard, read only (decision David 2026-10-08, PF-03 and PF-21):
        # the OU is filtered in SQL (DN suffix, COLLATE NOCASE), the computer facts and the BitLocker presence are
        # joined by GUID and name, and the workstations are grouped by the boundaries of the payload plan (the rules
        # stay in BoardFleet.Model). Only the observations of the active workstations of the OU are parsed, after a
        # GUID check, plus those of the explicitly named keys (selected workstation).
        $scope = ([string]$Payload.Scope).Trim()
        $subtree = ($null -eq $Payload.PSObject.Properties['Subtree'] -or [bool]$Payload.Subtree)
        $plan = $Payload.Plan
        if ($null -eq $plan) { throw 'Plan de calcul absent.' }
        $bounds = @($plan.LogonBounds | ForEach-Object { [string]$_ })
        if ($bounds.Count -ne 4) { throw 'Plan de calcul invalide.' }
        foreach ($day in @($bounds + @([string]$plan.Today,[string]$plan.HistorySince))) { if ($day -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'Plan de calcul invalide.' } }
        foreach ($stamp in @([string]$plan.CreatedSince,[string]$plan.PasswordBefore,[string]$plan.NowUtc,[string]$plan.ObservationsSince)) { if ($stamp -notmatch '^\d{4}-\d{2}-\d{2}T[0-9:.]+Z$') { throw 'Plan de calcul invalide.' } }
        $tables = @{}
        foreach ($row in @(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table';")) { $tables[[string]$row.name] = $true }
        # ObservationsOnly: only the observations of the explicitly named keys (a selected workstation outside the OU of
        # the last overview), without any aggregate.
        $observationsOnly = (($null -ne $Payload.PSObject.Properties['ObservationsOnly']) -and [bool]$Payload.ObservationsOnly)
        $types = @(); $parents = @(); $groups = New-Object 'System.Collections.Generic.List[object]'
        $machines = New-Object 'System.Collections.Generic.List[object]'; $targets = New-Object 'System.Collections.Generic.List[object]'; $byDn = @{}
        $coverage = [pscustomobject]@{ BitLockerRead = 0; BitLockerAt = ''; FactsFresh = 0; FactsStale = 0; FactsAt = '' }
        if (-not $observationsOnly) {
            $types = @(Invoke-IdxWQuery $db "SELECT object_type AS t, CASE WHEN state='Actif' THEN 'Actif' WHEN state='Desactive' THEN 'Desactive' ELSE 'Inconnu' END AS s, count(*) AS n FROM ad_objects GROUP BY 1,2;")
            $scopeSql = Get-IdxWDnScopeSql -Column 'a.distinguished_name' -Scope $scope -Subtree $subtree
            $factsJoin = ''; $factsCols = "'N' AS fx, NULL AS fv, NULL AS fc, NULL AS fp, NULL AS fk, NULL AS fe, NULL AS fr"
            if ($tables.ContainsKey('ad_computer_facts')) {
                $factsJoin = ' LEFT JOIN ad_computer_facts f ON f.object_guid = lower(a.object_guid)'
                $factsCols = "CASE WHEN f.object_guid IS NULL THEN 'N' WHEN COALESCE(f.read_at,'') >= COALESCE((SELECT last_sync FROM sync_state WHERE scope='directory'),'') THEN 'F' ELSE 'S' END AS fx, f.os_version AS fv, f.when_created AS fc, f.pwd_last_set AS fp, f.laps_kind AS fk, f.laps_expiry AS fe, f.read_at AS fr"
            }
            $directoryJoin='';$directoryCols="NULL AS field_times"
            if($tables.ContainsKey('domenia_directory_data')){$directoryJoin=' LEFT JOIN domenia_directory_data d ON d.object_guid=a.object_guid';$directoryCols='d.field_times AS field_times'}
            $b = @($bounds | ForEach-Object { Get-IdxWLiteral $_ })
            $created = Get-IdxWLiteral ([string]$plan.CreatedSince); $pwdBefore = Get-IdxWLiteral ([string]$plan.PasswordBefore); $nowLit = Get-IdxWLiteral ([string]$plan.NowUtc)
            $cte = "WITH m AS (SELECT a.name AS name, a.distinguished_name AS dn, a.object_guid AS guid, CASE WHEN a.state='Actif' THEN 'A' WHEN a.state='Desactive' THEN 'D' ELSE 'U' END AS st," +
                " CASE WHEN instr(COALESCE(a.extra,''),' / ')>0 THEN substr(a.extra,1,instr(a.extra,' / ')-1) ELSE COALESCE(a.extra,'') END AS os," +
                " CASE WHEN COALESCE(a.last_logon,'') GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]*' THEN substr(a.last_logon,7,4)||'-'||substr(a.last_logon,4,2)||'-'||substr(a.last_logon,1,2) ELSE '' END AS ld," +
                " $factsCols, $directoryCols, a.synced_at AS observed_at, s.computer_key AS sk, s.bitlocker_keys AS sb, s.checked_at AS sc, s.verdict AS sv" +
                " FROM ad_objects a$factsJoin$directoryJoin LEFT JOIN secret_state s ON s.computer_key = upper(a.name) WHERE a.object_type='Machine' AND $scopeSql)," +
                " g AS (SELECT name, dn, guid, st, os, ld, fx, sc, fr, field_times, observed_at, CASE WHEN fx='F' THEN COALESCE(fp,'') ELSE '' END AS password_at, CASE WHEN fx='F' THEN COALESCE(fv,'') ELSE '' END AS ver," +
                " CASE WHEN ld='' THEN 5 WHEN ld > $($b[0]) THEN 0 WHEN ld > $($b[1]) THEN 1 WHEN ld > $($b[2]) THEN 2 WHEN ld > $($b[3]) THEN 3 ELSE 4 END AS lb," +
                " CASE WHEN fx<>'F' OR COALESCE(fc,'')='' THEN '' WHEN fc >= $created THEN 'R' ELSE 'O' END AS cr," +
                " CASE WHEN fx<>'F' OR COALESCE(fp,'')='' THEN '' WHEN fp < $pwdBefore THEN 'O' ELSE 'R' END AS pw," +
                " CASE WHEN fx<>'F' THEN '' WHEN fk='NoSchema' THEN 'X' WHEN fk IN ('Legacy','Windows') AND COALESCE(fe,'')<>'' THEN (CASE WHEN fe < $nowLit THEN 'E' ELSE 'O' END) WHEN fk='None' THEN 'N' ELSE '' END AS lk," +
                " CASE WHEN sk IS NULL THEN 'U' WHEN julianday(sc) IS NOT NULL AND julianday(fc) IS NOT NULL AND julianday(sc) < julianday(fc) THEN 'U' WHEN COALESCE(sb,-1) < 0 THEN 'U' WHEN sv='non disponible dans ce domaine' THEN 'X' WHEN COALESCE(sb,0) > 0 THEN 'K' ELSE 'N' END AS bk FROM m)," +
                " h AS (SELECT *, st||'|'||os||'|'||ver||'|'||lb||'|'||cr||'|'||pw||'|'||lk||'|'||bk AS k FROM g) "
            # Point 9: BitLocker metadata is keyed by name; a row written before the current computer of that name was
            # created (fc) belongs to a previous holder of the name and stays unknown (U), never K or N.
            # GROUP BY k is case sensitive (BINARY): the group ids are looked up the same way, never without the case.
            $gids = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            foreach ($group in @(Invoke-IdxWQuery $db ($cte + 'SELECT k, st, os, ver, lb, cr, pw, lk, bk, count(*) AS n FROM h GROUP BY k;'))) {
                $gids[[string]$group.k] = [string]($groups.Count + 1)
                $groups.Add([pscustomobject]@{ gid = $gids[[string]$group.k]; st = [string]$group.st; os = [string]$group.os; ver = [string]$group.ver; lb = [int]$group.lb; cr = [string]$group.cr; pw = [string]$group.pw; lk = [string]$group.lk; bk = [string]$group.bk; n = [int]$group.n })
            }
            # One text cell per workstation (fields never hold a tab: the index replaces them): thousands of rows are read
            # without one native call per cell.
            foreach ($machine in @(Invoke-IdxWQuery $db ($cte + "SELECT COALESCE(name,'')||char(9)||COALESCE(dn,'')||char(9)||COALESCE(guid,'')||char(9)||st||char(9)||k||char(9)||ld||char(9)||password_at||char(9)||COALESCE(field_times,'')||char(9)||COALESCE(observed_at,'') AS r FROM h ORDER BY name COLLATE NOCASE;"))) {
                $cells = ([string]$machine.r).Split([char]9)
                if ($cells.Count -lt 6) { continue }
                $gid = ''; [void]$gids.TryGetValue([string]$cells[4],[ref]$gid)
                # Transport provenance only; Query decodes these dates in its own worker when needed.
                # No directory details, invented date or per-row JSON parsing is added to the dashboard path.
                $fieldJson=if($cells.Count -gt 7 -and $cells[7].Length -le 65536){$cells[7]}else{''}
                $row = [pscustomobject]@{ name = $cells[0]; distinguished_name = $cells[1]; object_guid = $cells[2]; gid = [string]$gid; st = $cells[3]; logon = $cells[5]; PasswordUtc=$(if($cells.Count -gt 6){$cells[6]}else{''});FieldTimesJson=$fieldJson;ObservedAtUtc=$(if($cells.Count -gt 8){$cells[8]}else{''}) }
                $machines.Add($row)
                if ($cells[3] -eq 'A') { $targets.Add($row); $byDn[$cells[1].ToLowerInvariant()] = $row }
            }
            $parentPosition="instr($(Get-IdxWDnSeparators 'dn'),',')"
            $parents = @(Invoke-IdxWQuery $db ($cte + "SELECT CASE WHEN $parentPosition>0 THEN substr(dn,$parentPosition+1) ELSE '' END AS p, count(*) AS n FROM g WHERE st='A' GROUP BY 1;"))
            $coverageRow = @(Invoke-IdxWQuery $db ($cte + "SELECT sum(CASE WHEN bk<>'U' THEN 1 ELSE 0 END) AS br, max(CASE WHEN bk<>'U' THEN sc END) AS ba, sum(CASE WHEN fx='F' THEN 1 ELSE 0 END) AS ff, sum(CASE WHEN fx='S' THEN 1 ELSE 0 END) AS fs, max(fr) AS fa FROM g WHERE st='A';"))
            if ($coverageRow.Count) { $c0 = $coverageRow[0]; $coverage = [pscustomobject]@{ BitLockerRead = [int]$c0.br; BitLockerAt = [string]$c0.ba; FactsFresh = [int]$c0.ff; FactsStale = [int]$c0.fs; FactsAt = [string]$c0.fa } }
        }
        $active = $targets.Count
        $links = 0; $sources = @(); $presence = New-Object 'System.Collections.Generic.List[object]'
        try { $links = [int](@(Invoke-IdxWQuery $db 'SELECT count(*) AS n FROM user_machine_links;')[0].n) } catch { }
        try { $sources = @(Invoke-IdxWQuery $db 'SELECT source AS s, count(*) AS n FROM user_machine_links GROUP BY 1 ORDER BY 2 DESC LIMIT 6;') } catch { }
        $wanted=New-Object 'System.Collections.Generic.List[string]'
        foreach($key in @($byDn.Keys)){$wanted.Add([string]$key)}
        $extra=@(@($Payload.Keys)|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{$_ -and -not $byDn.ContainsKey($_)}|Select-Object -First 20)
        if($extra.Count){foreach($row in @(Invoke-IdxWQuery $db ("SELECT name,distinguished_name,object_guid FROM ad_objects WHERE object_type='Machine' AND state='Actif' AND distinguished_name COLLATE NOCASE IN ("+(@($extra|ForEach-Object{Get-IdxWLiteral $_}) -join ',')+');'))){
            $key=([string]$row.distinguished_name).ToLowerInvariant();if($byDn.ContainsKey($key)){continue}
            $byDn[$key]=[pscustomobject]@{name=[string]$row.name;distinguished_name=[string]$row.distinguished_name;object_guid=[string]$row.object_guid;gid='';st='A';logon='';outside=$true};$wanted.Add($key)
        }}
        $legacyKeys=@{};$projectionByDn=@{}
        if($tables.ContainsKey('park_session_cache')){
            for($start=0;$start -lt $wanted.Count;$start+=250){
                $chunk=@($wanted.GetRange($start,[Math]::Min(250,$wanted.Count-$start))|ForEach-Object{Get-IdxWLiteral $_})
                foreach($item in @(Invoke-IdxWQuery $db ('SELECT object_key,checked_utc,payload FROM park_session_cache WHERE object_key IN ('+($chunk -join ',')+');'))){
                    $key=([string]$item.object_key).ToLowerInvariant();$legacyKeys[$key]=$true
                    if([string]::CompareOrdinal([string]$item.checked_utc,[string]$plan.ObservationsSince) -lt 0){continue}
                    if(([string]$item.payload).Length -gt 262144){$observationRejected++;continue}
                    $owner=$byDn[$key];if($null -eq $owner){continue}
                    $observation=$null;try{$observation=$observationReader.Read([string]$item.payload,$observationNow)}catch{$observationRejected++;continue}
                    if($null -eq $observation){continue}
                    if(-not [string]$observation.Guid -or [string]$observation.Guid -ine [string]$owner.object_guid){$observationRejected++;continue}
                    $projectionByDn[$key]=$observation
                }
            }
        }
        $canonical=Read-IdxWCanonicalObservations -Db $db -Owners @($byDn.Values) -Tables $tables -LegacyKeys $legacyKeys -ProjectionKind Fleet -Reader $observationReader -NowUtc $observationNow
        foreach($key in $canonical.Replaced.Keys){[void]$projectionByDn.Remove($key)}
        foreach($key in $canonical.Rows.Keys){$projectionByDn[$key]=$canonical.Rows[$key]}
        foreach($key in $projectionByDn.Keys){
            $owner=$byDn[$key];$observation=$projectionByDn[$key];$outside=($null -ne $owner.PSObject.Properties['outside'])
            $presence.Add([pscustomobject]@{object_key=$key;checked_utc=[string]$observation.CheckedUtc;observation=$observation;gid=[string]$owner.gid;name=[string]$owner.name;distinguished_name=[string]$owner.distinguished_name;object_guid=[string]$owner.object_guid;in_scope=(-not $outside)})
        }
        $history = @()
        if ((-not $observationsOnly) -and $tables.ContainsKey('fleet_snapshots') -and [string]$Payload.ScopeKey) {
            $history = @(Invoke-IdxWQuery $db ('SELECT snapshot_day AS day, figures FROM fleet_snapshots WHERE scope_key = ' + (Get-IdxWLiteral ([string]$Payload.ScopeKey)) + ' AND snapshot_day >= ' + (Get-IdxWLiteral ([string]$plan.HistorySince)) + ' ORDER BY snapshot_day;'))
        }
        # Dates and population come from the same SQLite snapshot, never from mutable UI metadata or computation time.
        $storeRevision=0L;$storeIdentity=''
        if($tables.ContainsKey('domenia_store_state')){$storeRows=@(Invoke-IdxWQuery $db 'SELECT store_id,revision FROM domenia_store_state WHERE id=1;');if($storeRows.Count){$storeRevision=[long]$storeRows[0].revision;$storeIdentity=[string]$storeRows[0].store_id}}
        $syncStates=@{}
        if($tables.ContainsKey('sync_state')){foreach($sync in @(Invoke-IdxWQuery $db "SELECT scope,base_dn,last_sync,details FROM sync_state WHERE scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%';")){$syncStates[[string]$sync.scope]=$sync}}
        # Scope clocks of the explicit OU collections (points 4, 5 and 10), read in the same snapshot. The caller
        # names the exact scope and its enclosing subtrees; nothing else is read and nothing is written.
        # $null: not requested, so unknown; an empty list: requested and none recorded.
        $collectionRuns=$null;$runKeysProperty=$Payload.PSObject.Properties['RunKeys']
        if(($null -ne $runKeysProperty) -and ($null -ne $runKeysProperty.Value)){
            $collectionRuns=@()
            $runKeys=@(@($runKeysProperty.Value)|ForEach-Object{[string]$_}|Where-Object{$_}|Select-Object -Unique)
            if($runKeys.Count -gt 128){throw 'Trop de perimetres de collecte demandes.'}
            foreach($runKey in $runKeys){if(($runKey.Length -gt 4200) -or ($runKey -cnotmatch '^(subtree|onelevel):') -or ($runKey -match '[\x00-\x1f]')){throw 'Perimetre de collecte invalide.'}}
            if(($runKeys.Count) -and ($tables.ContainsKey('domenia_domain_metadata'))){
                $runDomain=Get-IdxWLiteral (([string]$Payload.DomainDn).Trim().ToLowerInvariant())
                $runSql='SELECT domain_dn,family,request_key,attempt_at,status,error,success_at,payload,attempt_payload,revision FROM domenia_domain_metadata WHERE domain_dn='+$runDomain+" AND family IN ('Directory','Presence','Inventory') AND request_key IN ("+(@($runKeys|ForEach-Object{Get-IdxWLiteral $_}) -join ',')+') ORDER BY family,request_key;'
                $collectionRuns=@(foreach($runRow in @(Invoke-IdxWQuery $db $runSql)){
                    $runSuccess=[string]$runRow.payload;$runAttempt=[string]$runRow.attempt_payload
                    [pscustomobject]@{Kind='CollectionRun';DomainDn=[string]$runRow.domain_dn;Family=[string]$runRow.family;RequestKey=[string]$runRow.request_key;LastAttemptAtUtc=[string]$runRow.attempt_at;Status=[string]$runRow.status;Error=[string]$runRow.error;LastSuccessAtUtc=[string]$runRow.success_at;Data=$(if(($runSuccess) -and ($runSuccess -cne 'null')){Get-StoreWJson $runSuccess}else{$null});AttemptData=$(if(($runAttempt) -and ($runAttempt -cne 'null')){Get-StoreWJson $runAttempt}else{$null});Revision=[long]$runRow.revision}
                })
            }
        }
        $snapshotAtUtc=[datetime]::UtcNow.ToString('o')
        [void](Invoke-IdxWQuery $db 'COMMIT;')
        $domainDn=if($null -ne $Payload.PSObject.Properties['DomainDn']){[string]$Payload.DomainDn}else{''}
        $result=[pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=$active; ObservationRejected=$observationRejected; Scope=$scope; Subtree=$subtree; Types=$types; Groups=$groups.ToArray(); Machines=$machines.ToArray(); Targets=$targets.ToArray(); Parents=$parents; Coverage=$coverage; Links=$links; LinkSources=$sources; Presence=$presence.ToArray(); History=$history; SyncStates=$syncStates; CollectionRuns=$collectionRuns; SnapshotAtUtc=$snapshotAtUtc; DomainDn=$domainDn; DataSource='SQLite'; StoreId=$storeIdentity; Revision=$storeRevision; SnapshotRevision=$storeRevision }
        if(-not $observationsOnly -and $null -ne $Payload.PSObject.Properties['ComputeBoard'] -and [bool]$Payload.ComputeBoard){
            # Aggregation over thousands of observations stays in the worker, never in the WPF callback.
            foreach($module in @('Domenia-Common.Model.ps1','Domenia-Collection.Model.ps1','Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-BoardFleet.Model.ps1')){. (Join-Path ([string]$Payload.ModuleRoot) $module)}
            $board=Get-DomeniaFleetBoardData -Result $result -Scope $scope -Subtree $subtree -Now ([datetime]::Parse([string]$plan.NowUtc,[Globalization.CultureInfo]::InvariantCulture)) -Lifecycle $Payload.Lifecycle -ObservationMaxAgeDays ([int]$Payload.ObservationMaxAgeDays) -IndexPartial ([string]$Payload.IndexPartial) -HealthPolicy $(if($null -ne $Payload.PSObject.Properties['HealthPolicy']){$Payload.HealthPolicy}else{$null}) -HealthPolicyBook $(if($null -ne $Payload.PSObject.Properties['HealthPolicyBook']){$Payload.HealthPolicyBook}else{$null})
            $board.Freshness.ComputedAtUtc=[datetime]::UtcNow
            $result|Add-Member -NotePropertyName Board -NotePropertyValue $board
        }
        $result
        return
    }
    # FI-19 (L20): the last synchronous SQLite reads of the Dispatcher. Each action answers what its former core
    # reader read, in one snapshot; a table that the schema does not have yet answers empty, never with an error.
    if ($action -in @('IndexMetadata','UserMachineLinks','SecretIndexEntry','OperationStats')) {
        [void](Invoke-IdxWQuery $db 'BEGIN;')
        $tables=@{};foreach($t in @(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table';")){$tables[[string]$t.name]=$true}
        $answer=[pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=0 }
        if ($action -eq 'IndexMetadata') {
            # Directory checkpoint, per-OU coverage and failed attempts, plus the counters of the Outils page.
            $sync=@()
            if($tables.ContainsKey('sync_state')){$sync=@(Invoke-IdxWQuery $db "SELECT scope,server,base_dn,highest_usn,last_sync,item_count,details FROM sync_state WHERE scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%';")}
            $counts=[pscustomobject]@{ Total=0L; Users=0L; Computers=0L; MachinesActive=0L; MachinesDisabled=0L }
            if($tables.ContainsKey('ad_objects')){
                $c=@(Invoke-IdxWQuery $db "SELECT count(*) AS total,sum(CASE WHEN object_type='Utilisateur' THEN 1 ELSE 0 END) AS users,sum(CASE WHEN object_type='Machine' THEN 1 ELSE 0 END) AS computers,sum(CASE WHEN object_type='Machine' AND (state IS NULL OR state<>'Desactive') THEN 1 ELSE 0 END) AS machines_active,sum(CASE WHEN object_type='Machine' AND state='Desactive' THEN 1 ELSE 0 END) AS machines_disabled FROM ad_objects;")
                if($c.Count){$counts=[pscustomobject]@{ Total=[long]$c[0].total; Users=[long]$c[0].users; Computers=[long]$c[0].computers; MachinesActive=[long]$c[0].machines_active; MachinesDisabled=[long]$c[0].machines_disabled }}
            }
            $answer|Add-Member -NotePropertyName SyncStates -NotePropertyValue $sync
            $answer|Add-Member -NotePropertyName Counts -NotePropertyValue $counts
            $answer.MachineCount=[int]$counts.MachinesActive
        }
        elseif ($action -eq 'UserMachineLinks') {
            # User-workstation associations, newest first; the GUI applies the canonical relation rules.
            $links=New-Object 'System.Collections.Generic.List[object]'
            if($tables.ContainsKey('user_machine_links')){
                foreach($r in @(Invoke-IdxWQuery $db 'SELECT user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn FROM user_machine_links ORDER BY observed_at DESC;')){
                    $links.Add([pscustomobject]@{ UserLogin=[string]$r.user_login; Computer=[string]$r.computer; Source=[string]$r.source; Confidence=[int]$r.confidence; VerifiedInAD=([long]$r.verified_in_ad -ne 0); When=[string]$r.observed_at; Details=[string]$r.details; UserGuid=[string]$r.user_guid; ComputerGuid=[string]$r.computer_guid; UserDn=[string]$r.user_dn; ComputerDn=[string]$r.computer_dn })
                }
            }
            $answer.Rows=$links.ToArray()
        }
        elseif ($action -eq 'SecretIndexEntry') {
            # Non-secret metadata of one workstation (key count, dates, LAPS scheme, verdict): never a key or a password.
            $key=([string]$Payload.Computer).Trim().ToUpperInvariant()
            if((-not $key) -or ($key.Length -gt 256)){throw 'Poste de lecture invalide.'}
            if($tables.ContainsKey('secret_state')){$answer.Rows=@(Invoke-IdxWQuery $db ('SELECT computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict FROM secret_state WHERE computer_key='+(Get-IdxWLiteral $key)+' LIMIT 1;'))}
            # Point 9: creation date of the displayed workstation, read by its GUID (primary key, one row), never by name:
            # the caller leaves out metadata written before that object existed. '' when unknown or not asked.
            $created=''
            $guidProperty=$Payload.PSObject.Properties['Guid']
            $guid=if($null -ne $guidProperty){([string]$guidProperty.Value).Trim().ToLowerInvariant()}else{''}
            if($guid){
                if($guid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'GUID de lecture invalide.'}
                if($tables.ContainsKey('ad_computer_facts')){$facts=@(Invoke-IdxWQuery $db ('SELECT when_created FROM ad_computer_facts WHERE object_guid='+(Get-IdxWLiteral $guid)+' LIMIT 1;'));if($facts.Count){$created=[string]$facts[0].when_created}}
            }
            $answer|Add-Member -NotePropertyName Computer -NotePropertyValue $key
            $answer|Add-Member -NotePropertyName CreatedUtc -NotePropertyValue $created
        }
        else {
            # Measured samples per operation: the statistics grid and the history model of the impact estimates
            # (samples with a duration only, as the former Get-DomeniaOperationHistoryModel).
            if($tables.ContainsKey('operation_runs')){
                $per='CASE WHEN duration_ms>0 AND item_count>0 THEN duration_ms*1.0/item_count ELSE NULL END'
                $answer.Rows=@(Invoke-IdxWQuery $db ('SELECT operation,count(*) AS samples,avg(duration_ms) AS avg_duration_ms,avg(CASE WHEN item_count>0 THEN duration_ms*1.0/item_count ELSE NULL END) AS avg_ms_per_item,avg(bytes_estimated) AS avg_bytes,' +
                    'sum(remote_attempts) AS remote_attempts,sum(fallback_tasks) AS fallback_tasks,sum(success_count) AS successes,sum(failure_count) AS failures,max(finished_at) AS last_run,' +
                    'sum(CASE WHEN duration_ms>0 THEN 1 ELSE 0 END) AS n,avg('+$per+') AS ms_per_item,min('+$per+') AS min_ms_per_item,max('+$per+') AS max_ms_per_item,' +
                    'avg(CASE WHEN duration_ms>0 AND item_count>0 THEN bytes_estimated*1.0/item_count ELSE NULL END) AS bytes_per_item,' +
                    'avg(CASE WHEN duration_ms>0 AND remote_attempts>0 THEN fallback_tasks*1.0/remote_attempts ELSE NULL END) AS fallback_ratio,' +
                    'avg(CASE WHEN duration_ms>0 AND item_count>0 THEN success_count*1.0/item_count ELSE NULL END) AS success_ratio' +
                    ' FROM operation_runs GROUP BY operation ORDER BY samples DESC, operation COLLATE NOCASE;'))
            }
        }
        [void](Invoke-IdxWQuery $db 'COMMIT;')
        $answer
        return
    }
    if ($action -eq 'ParkState') {
        $park = @(Invoke-IdxWQuery $db 'SELECT computer_key,computer,last_probe,status,user_login,attempts FROM park_state;')
        $machines = 0
        try { $machines = [int](@(Invoke-IdxWQuery $db "SELECT count(*) AS n FROM ad_objects WHERE object_type='Machine' AND (state IS NULL OR state<>'Desactive');")[0].n) } catch { if ($_.Exception.Message -eq 'SQLITE_BUSY') { throw } }
        [pscustomobject]@{ Rows=@($park); Busy=$false; Missing=$false; MachineCount=$machines }
        return
    }
    # Same normalisation and SQL as Find-DomeniaIndexMatches / Search-DomeniaDatabaseRows (core).
    $clean = ([string]$Payload.Term).Trim()
    if ($clean.Contains([string][char]92)) { $clean = $clean.Split([char]92)[-1] }
    if ($clean.Contains('@')) { $clean = $clean.Split('@')[0] }
    $clean = $clean.Trim().TrimEnd([char]36).ToLowerInvariant()
    $browse=($null -ne $Payload.PSObject.Properties['Browse'] -and [bool]$Payload.Browse -and -not $clean)
    if ($clean.Length -lt 2 -and -not $browse) { [pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=0; Total=0; Offset=0; HasMore=$false }; return }
    $limit = [Math]::Max(1,[Math]::Min(500,[int]$Payload.Limit))
    $offset=0;if($null -ne $Payload.PSObject.Properties['Offset']){$offset=[Math]::Max(0,[int]$Payload.Offset)}
    $like = $clean.Replace('!','!!').Replace('%','!%').Replace('_','!_')
    $termSql = Get-IdxWLiteral $clean
    $prefixSql = Get-IdxWLiteral ($like + '%')
    $containsSql = Get-IdxWLiteral ('%' + $like + '%')
    $where=if($browse){'1=1'}else{"(name=$termSql COLLATE NOCASE OR login=$termSql COLLATE NOCASE OR upn=$termSql COLLATE NOCASE" +
        " OR name LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR login LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR upn LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR search_key LIKE $containsSql ESCAPE '!')"}
    $searchScope='';if($null -ne $Payload.PSObject.Properties['Scope']){$searchScope=([string]$Payload.Scope).Trim()}
    if($searchScope){$where+=' AND '+(Get-IdxWDnScopeSql -Column 'distinguished_name' -Scope $searchScope)}
    # Only these literal SQL expressions can be selected by a header. The sort covers the
    # entire filtered population before LIMIT/OFFSET, with a stable identity tie-breaker.
    $sortField='';if($null -ne $Payload.PSObject.Properties['SortField']){$sortField=[string]$Payload.SortField}
    $descending=($null -ne $Payload.PSObject.Properties['Descending'] -and [bool]$Payload.Descending)
    $sortColumns=@{
        Type='NULLIF(object_type,'''') COLLATE NOCASE';Name='NULLIF(name,'''') COLLATE NOCASE'
        Login='NULLIF(login,'''') COLLATE NOCASE';Upn='NULLIF(upn,'''') COLLATE NOCASE'
        State='NULLIF(state,'''') COLLATE NOCASE';Description='NULLIF(description,'''') COLLATE NOCASE'
        Score='match_score';Reason='CASE WHEN match_score>=100 THEN 1 WHEN match_score>=90 THEN 2 ELSE 0 END'
    }
    foreach($dateColumn in @(@('LastLogon','last_logon'),@('WhenChanged','when_changed'))){
        $c=[string]$dateColumn[1]
        # AD's displayed French dates and ISO timestamps compare as dates, never as text.
        $sortColumns[[string]$dateColumn[0]]="julianday(CASE WHEN $c GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]*' THEN substr($c,7,4)||'-'||substr($c,4,2)||'-'||substr($c,1,2)||substr($c,11) ELSE $c END)"
    }
    $order='match_score DESC,name COLLATE NOCASE,object_guid,distinguished_name,object_key'
    if($sortField){
        if(-not $sortColumns.ContainsKey($sortField)){throw 'Colonne de tri locale non autorisee.'}
        $expression=[string]$sortColumns[$sortField];$direction=if($descending){'DESC'}else{'ASC'}
        $order='('+ $expression+' IS NULL) ASC,'+$expression+' '+$direction+',name COLLATE NOCASE,object_guid,distinguished_name,object_key'
    }
    # Count and page use the same SQLite snapshot. Pagination is a display bound, never a population cap.
    [void](Invoke-IdxWQuery $db 'BEGIN;')
    $total=[long](@(Invoke-IdxWQuery $db ('SELECT count(*) AS n FROM ad_objects WHERE '+$where+';'))[0].n)
    if($offset -ge $total){$offset=0}
    $scoreSql=if($browse){'0'}else{
        "CASE WHEN name=$termSql COLLATE NOCASE OR login=$termSql COLLATE NOCASE OR upn=$termSql COLLATE NOCASE THEN 100" +
        " WHEN name LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR login LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR upn LIKE $prefixSql ESCAPE '!' COLLATE NOCASE THEN 90 ELSE 70 END"
    }
    $sql = "SELECT object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,object_guid," +
        " $scoreSql AS match_score FROM ad_objects WHERE $where ORDER BY $order LIMIT $limit OFFSET $offset;"
    $seen = @{}
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in @(Invoke-IdxWQuery $db $sql)) {
        $dn = [string]$r.distinguished_name; $guid = [string]$r.object_guid
        $key = if (-not [string]::IsNullOrWhiteSpace($guid)) { $guid.ToLowerInvariant() } else { $dn.ToLowerInvariant() }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $score = [int]$r.match_score
        $reason = if($browse){'Perimetre local'}else{'Contenu dans la fiche'}
        if ($score -ge 100) { $reason = 'Correspondance exacte' } elseif ($score -ge 90) { $reason = 'Debut du nom' }
        $result.Add([pscustomobject]@{
            Type=[string]$r.object_type; Name=[string]$r.name; Login=[string]$r.login; Upn=[string]$r.upn; Display=[string]$r.display_name
            Description=[string]$r.description; Extra=[string]$r.extra; State=[string]$r.state; DN=$dn; WhenChanged=[string]$r.when_changed
            Usn=[long]$r.usn_changed; LastLogon=[string]$r.last_logon; Guid=$guid
            Key=(([string]$r.name+' '+[string]$r.login+' '+[string]$r.upn+' '+[string]$r.display_name+' '+[string]$r.description+' '+[string]$r.extra).ToLowerInvariant())
            NameKey=([string]$r.name).ToLowerInvariant(); LoginKey=([string]$r.login).ToLowerInvariant(); Score=$score; Reason=$reason
        })
    }
    [void](Invoke-IdxWQuery $db 'COMMIT;')
    [pscustomobject]@{ Rows=$result.ToArray(); Busy=$false; Missing=$false; MachineCount=0; Total=$total; Offset=$offset; SortField=$sortField; Descending=$descending; HasMore=(($offset+$result.Count) -lt $total) }
}
catch {
    if ([string]$_.Exception.Message -eq 'SQLITE_BUSY') { [pscustomobject]@{ Rows=@(); Busy=$true; Missing=$false; MachineCount=0 } }
    else { throw }
}
finally { if ($db -ne [IntPtr]::Zero) { try { [void][Domenia.WinSqliteNative]::sqlite3_close($db) } catch { } } }
'@
}

function Get-DomeniaParkSharedSyncWorkerCode {
    # ParkSharedSync: the shared park file may be a UNC path guarded by a lock file. Reading, merging (most
    # recent line wins per computer) and writing back run here, never on the Dispatcher.
    return @'
$path = ([string]$Payload.Path).Trim()
if ([string]::IsNullOrWhiteSpace($path)) { throw 'Chemin du releve partage absent.' }
$me = [string]$Payload.Me
$merged = @{}
foreach ($e in @($Payload.Entries)) {
    if ($null -eq $e -or [string]::IsNullOrWhiteSpace([string]$e.Computer)) { continue }
    $merged[([string]$e.Computer).ToUpperInvariant()] = [pscustomobject]@{ Computer=[string]$e.Computer; LastProbe=[string]$e.LastProbe; Status=[string]$e.Status; User=[string]$e.User; Attempts=[int]$e.Attempts; ProbedBy=[string]$e.ProbedBy }
}
$added = 0; $replaced = 0
if ([IO.File]::Exists($path)) {
    foreach ($line in [IO.File]::ReadAllLines($path,[Text.Encoding]::UTF8)) {
        $f = ([string]$line).Split([char]9)
        if ($f.Length -lt 5) { continue }
        $by = ''
        if ($f.Length -ge 6) { $by = $f[5] }
        $attempts = 0
        [void][int]::TryParse([string]$f[4],[ref]$attempts)
        $new = [pscustomobject]@{ Computer=$f[0]; LastProbe=$f[1]; Status=$f[2]; User=$f[3]; Attempts=$attempts; ProbedBy=$by }
        $key = ([string]$f[0]).ToUpperInvariant()
        if (-not $merged.ContainsKey($key)) { $merged[$key] = $new; $added++; continue }
        $newer = $false
        try { $newer = ([datetime]$new.LastProbe -gt [datetime]$merged[$key].LastProbe) } catch { $newer = $true }
        if ($newer) { $merged[$key] = $new; $replaced++ }
    }
}
$written = $false; $locked = $false
if ([bool]$Payload.WriteBack) {
    $lock = $null; $lockPath = $path + '.lock'; $wait = 0
    while ($null -eq $lock -and $wait -lt 12) {
        try { $lock = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None) }
        catch { Start-Sleep -Milliseconds 250; $wait++ }
    }
    if ($null -eq $lock) { $locked = $true }
    else {
        try {
            $lines = New-Object 'System.Collections.Generic.List[string]'
            foreach ($key in @($merged.Keys)) {
                $e = $merged[$key]; $by = [string]$e.ProbedBy
                if ([string]::IsNullOrWhiteSpace($by)) { $by = $me }
                $lines.Add(([string]$e.Computer + [char]9 + [string]$e.LastProbe + [char]9 + [string]$e.Status + [char]9 + [string]$e.User + [char]9 + [string][int]$e.Attempts + [char]9 + $by))
            }
            $temporary = $path + '.tmp'
            [IO.File]::WriteAllLines($temporary,$lines.ToArray(),(New-Object Text.UTF8Encoding($false)))
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            [IO.File]::Move($temporary,$path)
            $written = $true
        }
        finally {
            try { $lock.Close(); $lock.Dispose() } catch { }
            try { [IO.File]::Delete($lockPath) } catch { }
        }
    }
}
[pscustomobject]@{ Recus=$added; Actualises=$replaced; Total=$merged.Count; Ecrit=$written; Locked=$locked; Entries=@($merged.Values) }
'@
}
