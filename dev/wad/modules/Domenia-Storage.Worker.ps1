function Get-DomeniaStorageWorkerCode {
    if(-not $script:DomeniaStoreQueryValidationCode){$script:DomeniaStoreQueryValidationCode=Get-DomeniaQueryLibraryDefinitionValidationCode}
$body=@'
function Initialize-DomeniaWinSqliteNative { return [Domenia.WinSqliteNative] }
function New-DomeniaUtf8Ptr {
    param([AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$Text) + [char]0)
    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
    return $ptr
}
function ConvertFrom-DomeniaUtf8Ptr {
    param([IntPtr]$Pointer,[int]$Length = -1)
    if ($Pointer -eq [IntPtr]::Zero) { return "" }
    if ($Length -lt 0) {
        $Length = 0
        while ([System.Runtime.InteropServices.Marshal]::ReadByte($Pointer,$Length) -ne 0) { $Length++ }
    }
    if ($Length -le 0) { return "" }
    $bytes = New-Object byte[] $Length
    [System.Runtime.InteropServices.Marshal]::Copy($Pointer,$bytes,0,$Length)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}
function Close-DomeniaDatabase {
    param([IntPtr]$DatabaseHandle)
    if($DatabaseHandle -eq [IntPtr]::Zero){return}
    Initialize-DomeniaWinSqliteNative | Out-Null
    $closed=[Domenia.WinSqliteNative]::sqlite3_close($DatabaseHandle)
    if($closed -ne 0){throw ('Fermeture SQLite non confirmee (code '+$closed+'). Le verrou est conserve.')}
    if($null -ne $script:StoreWHandleLeases -and $script:StoreWHandleLeases.ContainsKey($DatabaseHandle.ToInt64())){$lease=$script:StoreWHandleLeases[$DatabaseHandle.ToInt64()];$script:StoreWHandleLeases.Remove($DatabaseHandle.ToInt64());Exit-StoreWDatabaseLease $lease}
}
function ConvertTo-DomeniaSqlLiteral {
    param($Value)
    if ($null -eq $Value) { return "NULL" }
    if ($Value -is [bool]) { return $(if ($Value) { "1" } else { "0" }) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) { return ([Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)) }
    return "'" + (([string]$Value) -replace "'","''") + "'"
}
function Open-DomeniaDatabase {
    param([string]$Path = '',[switch]$ReadOnly)
    $native = Initialize-DomeniaWinSqliteNative
    $db = [IntPtr]::Zero
    $pathPtr = [IntPtr]::Zero;$writeLease=$null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-DomeniaDatabasePath }
        if(-not $ReadOnly){$writeLease=Enter-StoreWDatabaseLease -Path $Path}
        $pathPtr = New-DomeniaUtf8Ptr $Path
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 4 -bor 65536 }
        $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,$flags,[IntPtr]::Zero)
        if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw "Ouverture SQLite impossible (code $rc)." }
        # FI-12: lock wait from the worker context (LocalStore.DatabaseBusyTimeoutMs), 2 500 ms without one.
        $busyMs=2500;$workerContext=Get-Variable -Name Context -ValueOnly -ErrorAction SilentlyContinue
        if(($null -ne $workerContext) -and ($null -ne $workerContext.PSObject.Properties['BusyTimeoutMs'])){$busyMs=[Math]::Max(100,[Math]::Min(5000,[int]$workerContext.BusyTimeoutMs))}
        [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
        if(-not $ReadOnly){Assert-StoreWDatabaseWritable $db;if($null -eq $script:StoreWHandleLeases){$script:StoreWHandleLeases=@{}};$script:StoreWHandleLeases[$db.ToInt64()]=$writeLease;$writeLease=$null}
        return $db
    }
    catch {
        # sqlite3_open_v2 can return a non-null handle even on failure.
        if ($db -ne [IntPtr]::Zero) { [void][Domenia.WinSqliteNative]::sqlite3_close($db) }
        if($null -ne $writeLease){Exit-StoreWDatabaseLease $writeLease}
        throw
    }
    finally { if ($pathPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) } }
}
function Invoke-DomeniaDbExec {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $errPtr = [IntPtr]::Zero
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_exec($DatabaseHandle,$sqlPtr,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$errPtr)
        if ($rc -ne 0) {
            $msg = if ($errPtr -ne [IntPtr]::Zero) { ConvertFrom-DomeniaUtf8Ptr $errPtr } else { ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)) }
            throw "SQLite code $rc : $msg"
        }
        return $true
    }
    finally {
        if ($errPtr -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [Domenia.WinSqliteNative]::sqlite3_free($errPtr) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}
function Invoke-DomeniaDbQuery {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $stmt = [IntPtr]::Zero
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_prepare_v2($DatabaseHandle,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if ($rc -ne 0) { throw "SQLite prepare code $rc : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        $count = [Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
        while (($step = [Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100) {
            $o = [ordered]@{}
            for ($i=0;$i -lt $count;$i++) {
                $name = ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i))
                $type = [Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$i)
                $value = $null
                switch ($type) {
                    1 { $value = [long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$i) }
                    2 { $value = [double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$i) }
                    3 { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                    5 { $value = $null }
                    default { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                }
                $o[$name] = $value
            }
            $rows.Add([pscustomobject]$o)
        }
        if ($step -ne 101) { throw "SQLite step code $step : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        return $rows.ToArray()
    }
    finally {
        if ($stmt -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}
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
function Get-StoreWObservationSummaryJson {
    param([string]$Family,$Data)
    if($null -eq $Data){return 'null'}
    $result=[ordered]@{}
    if($Family -like 'Probe:*'){
        $id=$Family.Substring(6);$probe=$Data;if($null -ne $Data.Probes){$probe=$Data.Probes.$id}
        $entry=Get-StoreWMap $probe
        foreach($field in @('Instances','Schema','RawJson')){if($entry.Contains($field)){[void]$entry.Remove($field)}}
        $probes=[ordered]@{};$probes[$id]=[pscustomobject]$entry;$result.Probes=[pscustomobject]$probes
    }else{
        foreach($field in @('Computer','Presence','PresenceDetail','PresenceCheckedUtc','Outcome','User','ConsoleAccount','LinkUser','UserGuid','UserDn','UserUsn','ConsoleVerifiedAD','IdentityVerifiedUtc','IdentityCheckedUtc','Detail','Source','CheckedUtc','DirectoryAuthRejected','InventoryError','InventoryAttemptUtc','LastUser','RawAccount','CurrentUser','ConsoleError')){if($null -ne $Data.PSObject.Properties[$field]){$result[$field]=$Data.$field}}
        if($null -ne $Data.Inventory){$inventory=[ordered]@{};foreach($field in @('CheckedUtc','Model','Manufacturer','Build','OsCaption','LastBootUtc','RamBytes','DiskSize','DiskFree')){if($null -ne $Data.Inventory.PSObject.Properties[$field]){$inventory[$field]=$Data.Inventory.$field}};$result.Inventory=[pscustomobject]$inventory}
    }
    $json=[pscustomobject]$result|ConvertTo-Json -Depth 16 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 262144){return '{"SummaryUnavailable":true}'}
    return $json
}
function Get-StoreWDetailSummaryJson {
    param([string]$Kind,[string]$RequestKey,$Data,[switch]$AllowIncomplete)
    if($Kind -cne 'WmiQuery' -or $null -eq $Data -or [string]$Data.Mode -cne 'Select'){return 'null'}
    $count=0L
    if([string]$Data.RequestKey -cne $RequestKey -or $RequestKey -cnotmatch '^[a-f0-9]{64}$' -or $Data.CountComplete -isnot [bool] -or $Data.Truncated -isnot [bool] -or $null -eq $Data.PSObject.Properties['StoredCount'] -or -not [long]::TryParse([string]$Data.StoredCount,[ref]$count) -or $count -lt 0 -or $count -gt 2000 -or ([string]$Data.Namespace).Length -gt 256 -or ([string]$Data.CanonicalQuery).Length -gt 8192){if($AllowIncomplete){return 'null'};throw 'Resume de requete WMI incoherent.'}
    $sha=[Security.Cryptography.SHA256]::Create();try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([string]$Data.Namespace).ToLowerInvariant()+"`n"+[string]$Data.CanonicalQuery))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($key -cne $RequestKey){if($AllowIncomplete){return 'null'};throw 'Empreinte de requete WMI incoherente.'}
    $summary=[ordered]@{Format='Domenia.DetailQuerySummary/1';Mode='Select';Namespace=[string]$Data.Namespace;ClassName=[string]$Data.ClassName;CanonicalQuery=[string]$Data.CanonicalQuery;RequestKey=$RequestKey;StoredCount=$count;CountComplete=[bool]$Data.CountComplete;Truncated=[bool]$Data.Truncated}
    foreach($field in @('Computer','Source','SourceCompletedUtc','LimitReason')){if($null -ne $Data.PSObject.Properties[$field]){$value=[string]$Data.$field;if($value.Length -gt 512){$value=$value.Substring(0,512)};$summary[$field]=$value}}
    return [pscustomobject]$summary|ConvertTo-Json -Depth 4 -Compress
}
function Convert-StoreWObservation {
    param($Row,[string]$Kind='Observation')
    return [pscustomobject]@{Kind=$Kind;SummaryMissing=([bool]$Row.summary_missing);Guid=[string]$Row.object_guid;DN=[string]$Row.dn;Family=[string]$Row.family;ResultKind=[string]$Row.result_kind;RequestKey=[string]$Row.request_key;LastAttemptAtUtc=[string]$Row.attempt_at;Status=[string]$Row.status;Error=[string]$Row.error;LastSuccessAtUtc=[string]$Row.success_at;Data=(Get-StoreWJson ([string]$Row.payload));AttemptData=(Get-StoreWJson ([string]$Row.attempt_payload));DefinitionHash=[string]$Row.definition_hash;Revision=[long]$Row.revision}
}
function Convert-StoreWCollectionRun {
    # One committed scope clock (domenia_domain_metadata). 'null' payloads stay $null: no empty run is invented.
    param($Row)
    $success=[string]$Row.payload;$attempt=[string]$Row.attempt_payload
    return [pscustomobject]@{Kind='CollectionRun';DomainDn=[string]$Row.domain_dn;Family=[string]$Row.family;RequestKey=[string]$Row.request_key;LastAttemptAtUtc=[string]$Row.attempt_at;Status=[string]$Row.status;Error=[string]$Row.error;LastSuccessAtUtc=[string]$Row.success_at;Data=$(if(($success) -and ($success -cne 'null')){Get-StoreWJson $success}else{$null});AttemptData=$(if(($attempt) -and ($attempt -cne 'null')){Get-StoreWJson $attempt}else{$null});Revision=[long]$Row.revision}
}
function Get-StoreWCollectionRunWhere {
    param([object[]]$Changes)
    return (@($Changes|Where-Object{$_.Kind -eq 'CollectionRun'}|ForEach-Object{'(domain_dn='+(ConvertTo-DomeniaSqlLiteral ([string]$_.DomainDn))+' AND family='+(ConvertTo-DomeniaSqlLiteral ([string]$_.Family))+' AND request_key='+(ConvertTo-DomeniaSqlLiteral ([string]$_.RequestKey))+')'}|Select-Object -Unique) -join ' OR ')
}
function Read-StoreWCollectionRuns {
    # Read back after COMMIT, in the caller's read transaction: the receipt carries what SQLite holds.
    param([IntPtr]$Db,[object[]]$Changes)
    $where=Get-StoreWCollectionRunWhere $Changes
    if(-not $where){return @()}
    return @(Invoke-DomeniaDbQuery "SELECT * FROM domenia_domain_metadata WHERE $where ORDER BY family,request_key;" $Db|ForEach-Object{Convert-StoreWCollectionRun $_})
}
function Get-StoreWProjection {
    param([object[]]$Observations,[string]$Name='')
    if(-not $Observations.Count){return $null}
    $first=$Observations[0];$p=[ordered]@{Version=1;Key=([string]$first.DN).ToLowerInvariant();Guid=[string]$first.Guid;Computer=$Name;CheckedUtc='';Revision=0L;Probes=[ordered]@{};Times=[ordered]@{}}
    foreach($o in $Observations){
        $p.Revision=[Math]::Max([long]$p.Revision,[long]$o.Revision)
        $data=$o.Data;$summaryMissing=([bool]$o.SummaryMissing -or ($null -ne $data -and [bool]$data.SummaryUnavailable))
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
    param([IntPtr]$Db,[string[]]$Guids,[bool]$IncludeDirectoryDetails=$true,[bool]$IncludeObservations=$true,[bool]$IncludeDetails=$true,[string]$DetailWhere='1=1',[string[]]$ObservationFamilies=$null,[ValidateSet('Full','QuerySummary')][string]$DetailProjection='Full',[ValidateSet('Full','Summary')][string]$ObservationProjection='Full')
    $keys=@($Guids|Select-Object -Unique|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ','
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
        foreach($r in @(Invoke-DomeniaDbQuery ("SELECT $observationColumns FROM domenia_observations WHERE object_guid IN ($keys)$familyWhere ORDER BY object_guid,family;") $Db)){
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
            foreach($r in @(Invoke-DomeniaDbQuery ("SELECT $detailColumns FROM domenia_details WHERE object_guid IN ($keys) AND ($DetailWhere) ORDER BY object_guid,result_kind,request_key;") $Db)){$details.Add((Convert-StoreWObservation $r 'DetailResult'))}
        }
    }
    $state=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_state WHERE id=1;' $Db)
    return [pscustomobject]@{Rows=$rows.ToArray();Observations=$observations.ToArray();ObservationRows=$projections.ToArray();Details=$details.ToArray();SnapshotRevision=$(if($state.Count){[long]$state[0].revision}else{0L})}
}
function Convert-StoreWLegacyUtc {
    param($Value)
    if([string]::IsNullOrWhiteSpace([string]$Value)){return ''}
    $date=[datetimeoffset]::MinValue
    if(-not [datetimeoffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$date) -or $date.UtcDateTime -gt [datetime]::UtcNow.AddMinutes(2)){throw 'Date historique invalide : migration des mesures annulee.'}
    return $date.UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}
function Assert-StoreWLegacySafe {
    param($Value,[int]$Depth=0)
    if($Depth -gt 16){throw 'Mesures historiques trop imbriquees.'}
    if($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]){return}
    if($Value -is [array]){foreach($item in $Value){Assert-StoreWLegacySafe $item ($Depth+1)};return}
    foreach($p in $Value.PSObject.Properties){
        if($p.Name -match '^(?i:password|passwd|credential|credentials|securestring|accesstoken|refreshtoken|authorization|ms-mcs-admpwd|mslaps-password|mslaps-encryptedpassword|mslaps-encryptedpasswordhistory|msfve-keypackage|unicodepwd|userpassword|supplementalcredentials|dbcspwd|ntpwdhistory|msfve-recoverypassword|recoverypassword|recoverykey|privatekey)$'){throw 'Champ secret interdit dans les anciennes mesures.'}
        Assert-StoreWLegacySafe $p.Value ($Depth+1)
    }
}
function Import-StoreWLegacyObservations {
    param([IntPtr]$Db,[string[]]$Guids,[string]$DomainDn,[long]$Revision)
    # The marker and all imported families share the caller's write transaction.
    # No reader may retire the legacy fallback before this marker is committed.
    # PF-26: both tables exist (schema script, or Assert-StoreWSession once per worker session).
    if(-not @($Guids).Count){return}
    $keys=@($Guids|Where-Object{$_}|Select-Object -Unique|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ','
    if(-not $keys){return}
    $candidates=@(Invoke-DomeniaDbQuery ("SELECT a.object_guid,a.distinguished_name,p.payload FROM ad_objects a LEFT JOIN park_session_cache p ON p.object_key=lower(a.distinguished_name) LEFT JOIN domenia_legacy_observation_imports m ON m.object_guid=a.object_guid WHERE a.object_guid IN ($keys) AND m.object_guid IS NULL;") $Db)
    $existing=@{}
    if($candidates.Count){
        $candidateKeys=@($candidates|ForEach-Object{ConvertTo-DomeniaSqlLiteral ([string]$_.object_guid)}) -join ','
        foreach($row in @(Invoke-DomeniaDbQuery ("SELECT * FROM domenia_observations WHERE object_guid IN ($candidateKeys);") $Db)){$existing[[string]$row.object_guid+'|'+[string]$row.family]=$row}
    }
    foreach($candidate in $candidates){
        $guid=[string]$candidate.object_guid;$dn=[string]$candidate.distinguished_name
        if($dn -ine $DomainDn -and -not $dn.EndsWith(','+$DomainDn,[StringComparison]::OrdinalIgnoreCase)){throw 'Domaine historique incompatible.'}
        $payload=[string]$candidate.payload;$digest='';$families=[Collections.Generic.List[object]]::new()
        if($payload){
            if([Text.Encoding]::UTF8.GetByteCount($payload) -gt 262144){throw 'Anciennes mesures trop volumineuses ; migration annulee.'}
            $legacy=Get-StoreWJson $payload;$legacyGuid=[guid]::Empty
            if(-not [guid]::TryParse([string]$legacy.Guid,[ref]$legacyGuid) -or $legacyGuid -eq [guid]::Empty){throw 'GUID historique absent ou invalide ; migration annulee.'}
            # A DN may have been reused. Data from its previous object is never imported.
            if($legacyGuid.ToString('D') -ieq $guid){
                Assert-StoreWLegacySafe $legacy
                $parts=@(
                    @{Family='Presence';Fields=@('Computer','Presence','PresenceDetail');Success=$legacy.PresenceCheckedUtc;Attempt=$legacy.PresenceAttemptUtc;Error=$legacy.PresenceError;Present=([string]$legacy.PresenceCheckedUtc -ne '' -or [string]$legacy.Presence -notin @('','Non vérifié','Non verifie','Inconnu'))},
                    @{Family='Console';Fields=@('Computer','Outcome','User','LastUser','CurrentUser','RawAccount','ConsoleAccount','LinkUser','UserGuid','UserDn','UserUsn','ConsoleVerifiedAD','IdentityVerifiedUtc','IdentityCheckedUtc','Detail','Source','DirectoryAuthRejected');Success=$(if($legacy.ConsoleCheckedUtc){$legacy.ConsoleCheckedUtc}else{$legacy.ObservedUtc});Attempt=$legacy.ConsoleAttemptUtc;Error=$legacy.ConsoleError;Present=([string]$legacy.ConsoleCheckedUtc -ne '' -or [string]$legacy.ObservedUtc -ne '' -or [string]$legacy.RawAccount -ne '' -or [string]$legacy.LastUser -ne '')},
                    @{Family='Inventory';Fields=@('Computer','Inventory');Success=$legacy.Inventory.CheckedUtc;Attempt=$(if($legacy.InventoryAttemptUtc){$legacy.InventoryAttemptUtc}else{$legacy.InventoryCheckedUtc});Error=$legacy.InventoryError;Present=($null -ne $legacy.Inventory -or [string]$legacy.InventoryError -ne '')}
                )
                foreach($part in $parts){
                    $familyTime=$legacy.Times.([string]$part.Family)
                    if($null -ne $familyTime){
                        $part.Present=$true
                        if(-not $part.Success){$part.Success=$familyTime.ObservedUtc}
                        if(-not $part.Attempt){$part.Attempt=$familyTime.LastAttemptUtc}
                        if($familyTime.Succeeded -eq $false -and -not $part.Error){$part.Error='Ancienne lecture non confirmee.'}
                    }
                    if(-not $part.Present){continue}
                    $at=Convert-StoreWLegacyUtc $part.Success;$attempt=Convert-StoreWLegacyUtc $part.Attempt
                    if(-not $attempt){$attempt=$at};if(-not $attempt){throw ('Date propre absente pour '+$part.Family+' ; migration annulee.')}
                    $data=[ordered]@{};foreach($name in $part.Fields){if($null -ne $legacy.PSObject.Properties[$name]){$data[$name]=$legacy.$name}}
                    $families.Add([pscustomobject]@{Family=$part.Family;Success=$at;Attempt=$attempt;Error=[string]$part.Error;Data=[pscustomobject]$data;DefinitionHash=''})
                }
                $probes=Get-StoreWMap $legacy.Probes
                foreach($id in $probes.Keys){
                    if([string]$id -notmatch '^[A-Za-z0-9_.-]{1,128}$'){throw 'Identifiant de sonde historique invalide.'}
                    $probe=$probes[$id];if($null -eq $probe){continue}
                    $at=Convert-StoreWLegacyUtc $probe.CheckedUtc;$attempt=Convert-StoreWLegacyUtc $probe.AttemptedUtc;if(-not $attempt){$attempt=$at}
                    if(-not $attempt){throw ('Date propre absente pour Probe:'+ $id+' ; migration annulee.')}
                    $map=[ordered]@{};$map[$id]=$probe;$error=[string]$probe.Error
                    if(-not $error -and ($probe.Succeeded -eq $false -or [string]$probe.Skipped)){$error='Ancienne lecture non confirmee.'}
                    $families.Add([pscustomobject]@{Family=('Probe:'+$id);Success=$at;Attempt=$attempt;Error=$error;Data=[pscustomobject]@{Computer=$legacy.Computer;Probes=[pscustomobject]$map};DefinitionHash=[string]$probe.DefinitionHash})
                }
            }
            $sha=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        }
        $sql=[Text.StringBuilder]::new()
        foreach($family in $families){
            $json=$family.Data|ConvertTo-Json -Depth 20 -Compress;$status=if($family.Error){'Error'}else{'Success'}
            if(-not $family.Success -and $status -eq 'Success'){throw 'Succes historique sans date ; migration annulee.'}
            $old=$existing[$guid+'|'+[string]$family.Family]
            $newAttempt=($null -eq $old -or [string]::CompareOrdinal([string]$family.Attempt,[string]$old.attempt_at) -gt 0)
            $newSuccess=([string]$family.Success -ne '' -and ($null -eq $old -or [string]::CompareOrdinal([string]$family.Success,[string]$old.success_at) -gt 0))
            if(-not $newAttempt -and -not $newSuccess){continue}
            # Attempt and success clocks are independent: an older legacy success may
            # fill a missing success without replacing a newer canonical failure.
            $attempt=if($newAttempt){$family.Attempt}else{$old.attempt_at}
            $resultStatus=if($newAttempt){$status}else{$old.status};$error=if($newAttempt){$family.Error}else{$old.error}
            $success=if($newSuccess){$family.Success}elseif($null -ne $old){$old.success_at}else{''}
            $successJson=if($newSuccess){$json}elseif($null -ne $old){$old.payload}else{'null'}
            $attemptJson=if($newAttempt){if($family.Error){$json}else{'null'}}else{$old.attempt_payload}
            $definition=if($newAttempt){$family.DefinitionHash}else{$old.definition_hash}
            $v=@($guid,$family.Family,$dn,$definition,$attempt,$resultStatus,$error,$success,$successJson,$attemptJson,$Revision)
            [void]$sql.AppendLine('INSERT OR REPLACE INTO domenia_observations(object_guid,family,dn,definition_hash,attempt_at,status,error,success_at,payload,attempt_payload,revision) VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
        }
        $v=@($guid,$digest,[datetime]::UtcNow.ToString('o'))
        [void]$sql.AppendLine('INSERT INTO domenia_legacy_observation_imports(object_guid,payload_hash,imported_at) VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
        [void](Invoke-DomeniaDbExec $sql.ToString() $Db)
    }
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
    $exists=@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_query_recipes';" $Db)
    $rows=@();$migrations=@();$dependencies=@();$total=0L
    if($exists.Count){
        $where='domain_dn='+(ConvertTo-DomeniaSqlLiteral $DomainDn)
        if(-not [bool]$Query.IncludeArchived){$where+=' AND archived='+[int][bool]$Query.Archived}
        # instr is literal: percent, underscore and quotes cannot widen this filter.
        if([string]$Query.Term){$where+=' AND instr(name_fold,'+(ConvertTo-DomeniaSqlLiteral ([string]$Query.Term))+')>0'}
        if([string]$Query.Category){$where+=' AND category='+(ConvertTo-DomeniaSqlLiteral ([string]$Query.Category))}
        if($null -ne $RecipeIds){
            if($RecipeIds.Count -gt 250){throw 'Trop de recettes pour une page.'}
            foreach($id in $RecipeIds){if($id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$'){throw 'Identifiant de lecture de recette invalide.'}}
            if($RecipeIds.Count){$where+=' AND id IN ('+(@($RecipeIds|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+')'}else{$where+=' AND 0=1'}
        }
        $total=[long](@(Invoke-DomeniaDbQuery "SELECT count(*) AS n FROM domenia_query_recipes WHERE $where;" $Db)[0].n)
        $rows=@(Invoke-DomeniaDbQuery "SELECT * FROM domenia_query_recipes WHERE $where ORDER BY name_fold,id LIMIT $limit OFFSET $offset;" $Db|ForEach-Object{Convert-StoreWQueryRecipe $_})
        if($rows.Count){$keys=@($rows|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_.Id}) -join ',';$dependencies=@(Invoke-DomeniaDbQuery "SELECT recipe_id AS RecipeId,consumer_kind AS ConsumerKind,consumer_id AS ConsumerId,bound_revision AS BoundRevision FROM domenia_query_recipe_dependencies WHERE recipe_id IN ($keys) ORDER BY recipe_id,consumer_kind,consumer_id;" $Db)}
        $migrationTable=@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_query_migrations';" $Db)
        if($migrationTable.Count){$migrations=@(Invoke-DomeniaDbQuery ('SELECT source_hash AS SourceHash,domain_dn AS DomainDn,imported_at AS ImportedAtUtc,revision AS Revision FROM domenia_query_migrations WHERE domain_dn='+(ConvertTo-DomeniaSqlLiteral $DomainDn)+' ORDER BY source_hash;') $Db)}
    }
    return [pscustomobject]@{QueryRecipes=$rows;QueryDependencies=$dependencies;QueryMigrations=$migrations;Total=$total;Offset=$offset;Limit=$limit;SnapshotRevision=$SnapshotRevision}
}
function Assert-StoreWQueryRecord {
    param($Record,$Context)
    if([string]$Record.Format -cne 'Domenia.QueryLibraryRecord/1' -or [string]$Record.StoreId -cne [string]$Context.StoreId -or [string]$Record.DomainDn -ine [string]$Context.DomainDn){throw 'Contexte de recette incompatible.'}
    if([string]$Record.Id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$' -or [string]$Record.Id -like 'template.*' -or -not [string]$Record.Name -or ([string]$Record.Name).Length -gt 120 -or [string]$Record.Name -match '[\p{Cc}]' -or ([string]$Record.Category).Length -gt 80 -or [string]$Record.Category -match '[\p{Cc}]'){throw 'Identite de recette invalide.'}
    if([long]$Record.ExpectedRevision -lt 0 -or [long]$Record.ExpectedRevision -ge [long]::MaxValue -or [long]$Record.Revision -ne [long]$Record.ExpectedRevision+1 -or [int]$Record.DefinitionVersion -notin @(1,2) -or $Record.Archived -isnot [bool]){throw 'Revision de recette invalide.'}
    $json=[string]$Record.DefinitionJson
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1048576){throw 'Definition de recette trop volumineuse.'}
    $hash=[Security.Cryptography.SHA256]::Create();try{$actual=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    if($actual -cne [string]$Record.DefinitionSHA256){throw 'Empreinte de definition de recette invalide.'}
    $recipe=Assert-WQueryLibraryDefinition -DefinitionJson $json -DefinitionVersion ([int]$Record.DefinitionVersion) -RecipeId ([string]$Record.Id)
    Assert-StoreWLegacySafe $recipe
    if([string]$recipe.Name -cne [string]$Record.Name){throw 'Nom de recette incoherent.'}
    $builder=[Text.StringBuilder]::new();foreach($character in ([string]$Record.Name).Normalize([Text.NormalizationForm]::FormD).ToCharArray()){if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [Globalization.UnicodeCategory]::NonSpacingMark){[void]$builder.Append($character)}}
    $fold=([regex]::Replace($builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant(),'\s+',' ')).Trim()
    if([string]$Record.NameFold -cne $fold){throw 'Cle de recherche de recette incoherente.'}
    $at=Convert-StoreWLegacyUtc $Record.UpdatedUtc
    if(-not $at -or [datetime]$at -gt [datetime]::UtcNow.AddMinutes(2)){throw 'Date de recette invalide.'}
}
function Write-StoreWQueryChange {
    param([IntPtr]$Db,$Change,$Context,[long]$StoreRevision)
    $domain=ConvertTo-DomeniaSqlLiteral ([string]$Context.DomainDn)
    if($Change.Kind -eq 'QueryRecipe'){
        $r=$Change.Record;Assert-StoreWQueryRecord $r $Context
        $id=ConvertTo-DomeniaSqlLiteral ([string]$r.Id);$old=@(Invoke-DomeniaDbQuery "SELECT * FROM domenia_query_recipes WHERE id=$id;" $Db)
        $current=if($old.Count){[long]$old[0].revision}else{0L}
        if($old.Count -and [string]$old[0].domain_dn -ine [string]$Context.DomainDn){throw 'Domaine de recette incompatible.'}
        if($current -ne [long]$r.ExpectedRevision){throw ('QueryRevisionConflict : '+$r.Id+' attendue '+$r.ExpectedRevision+', actuelle '+$current+'.')}
        if($r.Archived -and @(Invoke-DomeniaDbQuery "SELECT recipe_id FROM domenia_query_recipe_dependencies WHERE recipe_id=$id LIMIT 1;" $Db).Count){throw 'QueryDependenciesExist : retirer explicitement les dependances avant archivage.'}
        $created=if($old.Count){[string]$old[0].created_utc}else{[string]$r.UpdatedUtc}
        $v=@($r.Id,$Context.DomainDn,$r.Name,$r.NameFold,$r.Category,$r.Revision,$r.DefinitionVersion,$r.DefinitionJson,$r.DefinitionSHA256,$created,$r.UpdatedUtc,[int][bool]$r.Archived)
        [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO domenia_query_recipes(id,domain_dn,name,name_fold,category,revision,definition_version,definition_json,definition_sha256,created_utc,updated_utc,archived) VALUES('+(@($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $Db)
        $v=@($r.Id,$r.Revision,$r.DefinitionVersion,$r.DefinitionJson,$r.DefinitionSHA256,$r.UpdatedUtc)
        [void](Invoke-DomeniaDbExec ('INSERT INTO domenia_query_recipe_revisions(id,revision,definition_version,definition_json,definition_sha256,at_utc) VALUES('+(@($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $Db)
        return
    }
    if($Change.Kind -eq 'QueryDependency'){
        $recipe=[string]$Change.RecipeId;$kind=[string]$Change.ConsumerKind;$key=[string]$Change.ConsumerId;$bound=[long]$Change.BoundRevision
        if($recipe -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$' -or $kind -cnotin @('Fleet','Computer') -or -not $key -or $key.Length -gt 128 -or $key -match '[\p{Cc}]' -or $bound -le 0 -or $Change.Remove -isnot [bool]){throw 'Dependance de recette invalide.'}
        $id=ConvertTo-DomeniaSqlLiteral $recipe;$consumer=ConvertTo-DomeniaSqlLiteral $kind;$consumerId=ConvertTo-DomeniaSqlLiteral $key
        $where="recipe_id=$id AND consumer_kind=$consumer AND consumer_id=$consumerId"
        $old=@(Invoke-DomeniaDbQuery "SELECT bound_revision FROM domenia_query_recipe_dependencies WHERE $where;" $Db)
        if($Change.Remove){
            if($old.Count -and [long]$old[0].bound_revision -ne $bound){throw 'QueryDependencyConflict : liaison modifiee.'}
            [void](Invoke-DomeniaDbExec "DELETE FROM domenia_query_recipe_dependencies WHERE $where;" $Db);return
        }
        $record=@(Invoke-DomeniaDbQuery "SELECT revision,archived FROM domenia_query_recipes WHERE id=$id AND domain_dn=$domain;" $Db)
        if(-not $record.Count -or [int]$record[0].archived -ne 0 -or [long]$record[0].revision -ne $bound){throw 'QueryDependencyConflict : recette absente, archivee ou modifiee.'}
        [void](Invoke-DomeniaDbExec "INSERT OR REPLACE INTO domenia_query_recipe_dependencies(recipe_id,consumer_kind,consumer_id,bound_revision) VALUES($id,$consumer,$consumerId,$bound);" $Db);return
    }
    if($Change.Kind -eq 'QueryMigration'){
        $hash=[string]$Change.SourceHash;$ids=@($Change.RecipeIds);$seen=@{}
        if($hash -cnotmatch '^[a-f0-9]{64}$' -or $ids.Count -gt 5000){throw 'Migration de recettes invalide.'}
        foreach($id in $ids){if([string]$id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$' -or $seen.ContainsKey([string]$id)){throw 'Identite de migration invalide.'};$seen[[string]$id]=$true}
        # Check in small groups: no oversized IN expression or silent partial marker.
        for($start=0;$start -lt $ids.Count;$start+=250){$end=[Math]::Min($ids.Count-1,$start+249);$keys=@($ids[$start..$end]|ForEach-Object{ConvertTo-DomeniaSqlLiteral ([string]$_)}) -join ',';$count=[long](@(Invoke-DomeniaDbQuery "SELECT count(*) AS n FROM domenia_query_recipes WHERE domain_dn=$domain AND id IN ($keys);" $Db)[0].n);if($count -ne $end-$start+1){throw 'Migration incomplete : recette attendue absente.'}}
        $v=@($hash,$Context.DomainDn,[datetime]::UtcNow.ToString('o'),$StoreRevision)
        [void](Invoke-DomeniaDbExec ('INSERT OR IGNORE INTO domenia_query_migrations(source_hash,domain_dn,imported_at,revision) VALUES('+(@($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $Db);return
    }
    throw 'Changement de bibliotheque inconnu.'
}

function New-StoreWStatement {
    # PF-07: one prepared statement per table, reused for every row of a bulk loop inside the caller's transaction.
    # Values are bound (UTF-16 text, int64, double, NULL): the SQL text is parsed once, never rebuilt per row.
    param([IntPtr]$Db,[string]$Sql)
    $sqlPtr=New-DomeniaUtf8Ptr $Sql;$stmt=[IntPtr]::Zero
    try{
        $rc=[Domenia.WinSqliteNative]::sqlite3_prepare_v2($Db,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if(($rc -ne 0) -or ($stmt -eq [IntPtr]::Zero)){throw ('SQLite prepare code '+$rc+' : '+(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($Db))))}
    }finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr)}
    $statement=[pscustomobject]@{Handle=$stmt;Db=$Db;Parameters=[int][Domenia.WinSqliteNative]::sqlite3_bind_parameter_count($stmt);Rows=0L;Transient=[IntPtr]::new(-1)}
    if($null -eq $script:StoreWStatements){$script:StoreWStatements=[Collections.Generic.List[object]]::new()}
    $script:StoreWStatements.Add($statement)
    return $statement
}
function Set-StoreWStatementValues {
    # Binds ?1..?N in order with the value semantics of ConvertTo-DomeniaSqlLiteral: integral numbers as INTEGER,
    # other numbers as REAL, $null as NULL, everything else as TEXT (exact UTF-16 length, copied by SQLite).
    param($Statement,[object[]]$Values)
    $stmt=$Statement.Handle
    if($stmt -eq [IntPtr]::Zero){throw 'Requete preparee deja fermee.'}
    if(@($Values).Count -ne [int]$Statement.Parameters){throw ('Requete preparee : '+[int]$Statement.Parameters+' valeur(s) attendue(s), '+@($Values).Count+' fournie(s).')}
    for($n=0;$n -lt $Values.Count;$n++){
        $value=$Values[$n];$index=$n+1
        if($null -eq $value){$rc=[Domenia.WinSqliteNative]::sqlite3_bind_null($stmt,$index)}
        elseif($value -is [bool]){$rc=[Domenia.WinSqliteNative]::sqlite3_bind_int64($stmt,$index,[long]$(if($value){1}else{0}))}
        elseif(($value -is [byte]) -or ($value -is [int16]) -or ($value -is [int32]) -or ($value -is [int64])){$rc=[Domenia.WinSqliteNative]::sqlite3_bind_int64($stmt,$index,[long]$value)}
        elseif(($value -is [double]) -or ($value -is [decimal])){
            $number=[double]$value
            if(([Math]::Floor($number) -eq $number) -and ([Math]::Abs($number) -lt 9.0e18)){$rc=[Domenia.WinSqliteNative]::sqlite3_bind_int64($stmt,$index,[long]$number)}
            else{$rc=[Domenia.WinSqliteNative]::sqlite3_bind_double($stmt,$index,$number)}
        }
        else{$text=[string]$value;$rc=[Domenia.WinSqliteNative]::sqlite3_bind_text16($stmt,$index,$text,(2*$text.Length),$Statement.Transient)}
        if($rc -ne 0){throw ('SQLite bind code '+$rc+' : '+(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($Statement.Db))))}
    }
}
function Invoke-StoreWStatement {
    # One row: bind, run to SQLITE_DONE, reset for the next row (bindings are replaced at the next call).
    param($Statement,[object[]]$Values)
    Set-StoreWStatementValues $Statement $Values
    $stmt=$Statement.Handle
    $step=[Domenia.WinSqliteNative]::sqlite3_step($stmt)
    $message='';if($step -ne 101){$message=ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($Statement.Db))}
    [void][Domenia.WinSqliteNative]::sqlite3_reset($stmt)
    if($step -ne 101){throw ('SQLite step code '+$step+' : '+$message)}
    $Statement.Rows++
}
function Read-StoreWStatementRow {
    # PF-07: first row of a prepared SELECT for these values, $null when there is none; the statement is reset.
    param($Statement,[object[]]$Values)
    Set-StoreWStatementValues $Statement $Values
    $stmt=$Statement.Handle;$row=$null
    try{
        $step=[Domenia.WinSqliteNative]::sqlite3_step($stmt)
        if($step -eq 100){
            $map=[ordered]@{};$count=[Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
            for($c=0;$c -lt $count;$c++){
                $name=ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$c))
                $type=[Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$c);$value=$null
                if($type -eq 1){$value=[long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$c)}
                elseif($type -eq 2){$value=[double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$c)}
                elseif($type -ne 5){$p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$c);$length=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$c);$value=ConvertFrom-DomeniaUtf8Ptr $p $length}
                $map[$name]=$value
            }
            $row=[pscustomobject]$map
        }elseif($step -ne 101){throw ('SQLite step code '+$step+' : '+(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($Statement.Db))))}
    }finally{[void][Domenia.WinSqliteNative]::sqlite3_reset($stmt)}
    return $row
}
function Close-StoreWStatements {
    # Every prepared statement of this worker session is finalized before sqlite3_close: an unfinalized statement
    # would make the close fail and keep the write lease.
    if($null -eq $script:StoreWStatements){return}
    foreach($statement in @($script:StoreWStatements)){
        if(($null -ne $statement) -and ($statement.Handle -ne [IntPtr]::Zero)){[void][Domenia.WinSqliteNative]::sqlite3_finalize($statement.Handle);$statement.Handle=[IntPtr]::Zero}
    }
    $script:StoreWStatements.Clear()
}
function Get-StoreWAdditiveTables {
    # PF-26: tables added to schema 11/1 without a version change. The schema script of Initialize-DomeniaDatabase
    # creates them; a base never opened by that script (an older copy, a fixture) gets them once per worker session.
    return [ordered]@{
        park_session_cache='CREATE TABLE IF NOT EXISTS park_session_cache(object_key TEXT PRIMARY KEY,checked_utc TEXT NOT NULL,payload TEXT NOT NULL);'
        domenia_legacy_observation_imports='CREATE TABLE IF NOT EXISTS domenia_legacy_observation_imports(object_guid TEXT PRIMARY KEY,payload_hash TEXT NOT NULL,imported_at TEXT NOT NULL);'
        ad_computer_facts='CREATE TABLE IF NOT EXISTS ad_computer_facts(object_guid TEXT PRIMARY KEY,object_key TEXT,os_version TEXT,when_created TEXT,pwd_last_set TEXT,laps_kind TEXT,laps_expiry TEXT,read_at TEXT);'
        fleet_snapshots='CREATE TABLE IF NOT EXISTS fleet_snapshots(scope_key TEXT NOT NULL,snapshot_day TEXT NOT NULL,taken_at TEXT,scope_dn TEXT,machines INTEGER DEFAULT 0,figures TEXT,PRIMARY KEY(scope_key,snapshot_day));'
    }
}
function Assert-StoreWSession {
    # PF-26: schema_info is read once per worker session, in ONE query, inside the write transaction of the caller:
    # the check and the writes see the same schema. Missing additive tables are created here, never per batch item.
    param([IntPtr]$Db)
    $tables=Get-StoreWAdditiveTables
    $presence=@(foreach($name in $tables.Keys){"(SELECT count(*) FROM sqlite_master WHERE type='table' AND name='"+$name+"') AS has_"+$name})
    $row=@(Invoke-DomeniaDbQuery ("SELECT sqlite_version() AS sqlite_version,(SELECT count(*) FROM schema_info WHERE key='schema_version') AS version_rows,(SELECT value FROM schema_info WHERE key='schema_version') AS schema_version,(SELECT count(*) FROM schema_info WHERE key='domenia_schema') AS revision_rows,(SELECT value FROM schema_info WHERE key='domenia_schema') AS domenia_schema,"+($presence -join ',')+';') $Db)
    if($row.Count -ne 1){throw 'Schema stockage incompatible.'}
    if(([long]$row[0].version_rows -ne 1) -or ([string]$row[0].schema_version -ne '11')){throw 'Schema stockage incompatible.'}
    if(([long]$row[0].revision_rows -ne 1) -or ([string]$row[0].domenia_schema -ne '1')){throw 'Version Domenia incompatible.'}
    $missing=@(foreach($name in $tables.Keys){if([long]$row[0].('has_'+$name) -eq 0){$tables[$name]}})
    if($missing.Count){[void](Invoke-DomeniaDbExec ($missing -join '') $Db)}
    return [string]$row[0].sqlite_version
}

function Invoke-StoreWBatch {
    param([IntPtr]$Db,$Item)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$actual=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Item.Json))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    if($actual -cne [string]$Item.Hash -or [Text.Encoding]::UTF8.GetByteCount([string]$Item.Json) -gt 4194304){throw 'Empreinte ou taille de lot invalide.'}
    $batch=Get-StoreWJson ([string]$Item.Json);$c=$batch.Context
    if([string]$c.Path -cne [string]$Payload.Path -or [int]$batch.Version -ne 1 -or @($batch.Changes).Count -gt 250){throw 'Enveloppe de stockage incoherente.'}
    $id=ConvertTo-DomeniaSqlLiteral ([string]$batch.BatchId);$store=ConvertTo-DomeniaSqlLiteral ([string]$c.StoreId);$domain=ConvertTo-DomeniaSqlLiteral ([string]$c.DomainDn)
    $known=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_state WHERE id=1;' $Db)
    if($known.Count){if([string]$known[0].store_id -cne [string]$c.StoreId -or [string]$known[0].domain_dn -ine [string]$c.DomainDn){throw 'Base appartenant a un autre contexte.'}}
    else{
        $legacy=@(Invoke-DomeniaDbQuery "SELECT base_dn FROM sync_state WHERE scope='directory' AND COALESCE(base_dn,'')<>'';" $Db)
        if($legacy.Count -and [string]$legacy[0].base_dn -ine [string]$c.DomainDn){throw 'Domaine de la base existante incompatible.'}
        [void](Invoke-DomeniaDbExec "INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,$store,$domain,0);" $Db)
    }
    if(@($batch.Changes|Where-Object{$_.Kind -in @('QueryRecipe','QueryDependency','QueryMigration')}).Count){[void](Invoke-DomeniaDbExec 'CREATE TABLE IF NOT EXISTS domenia_query_recipes (  id TEXT PRIMARY KEY NOT NULL, domain_dn TEXT NOT NULL, name TEXT NOT NULL, name_fold TEXT NOT NULL,  category TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), definition_version INTEGER NOT NULL,  definition_json TEXT NOT NULL, definition_sha256 TEXT NOT NULL, created_utc TEXT NOT NULL,  updated_utc TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)) ); CREATE INDEX IF NOT EXISTS ix_domenia_query_recipes_page ON domenia_query_recipes(archived,name_fold,id); CREATE INDEX IF NOT EXISTS ix_domenia_query_recipes_category ON domenia_query_recipes(archived,category,name_fold,id); CREATE TABLE IF NOT EXISTS domenia_query_recipe_revisions (  id TEXT NOT NULL, revision INTEGER NOT NULL, definition_version INTEGER NOT NULL,  definition_json TEXT NOT NULL, definition_sha256 TEXT NOT NULL, at_utc TEXT NOT NULL,  PRIMARY KEY(id,revision) ); CREATE TABLE IF NOT EXISTS domenia_query_migrations (  source_hash TEXT PRIMARY KEY NOT NULL, domain_dn TEXT NOT NULL, imported_at TEXT NOT NULL, revision INTEGER NOT NULL ); CREATE TABLE IF NOT EXISTS domenia_query_recipe_dependencies (  recipe_id TEXT NOT NULL, consumer_kind TEXT NOT NULL, consumer_id TEXT NOT NULL,  bound_revision INTEGER NOT NULL, PRIMARY KEY(recipe_id,consumer_kind,consumer_id) );' $Db)}
    $prior=@(Invoke-DomeniaDbQuery "SELECT * FROM domenia_store_batches WHERE batch_id=$id;" $Db)
    if($prior.Count){
        if([string]$prior[0].payload_hash -cne $actual){throw 'Identifiant de lot reutilise avec un autre contenu.'}
        return [pscustomobject]@{Already=$true;Batch=$batch;Revision=[long]$prior[0].revision;CommittedAtUtc=[string]$prior[0].committed_at}
    }
    $rev=1+[long](@(Invoke-DomeniaDbQuery 'SELECT revision FROM domenia_store_state WHERE id=1;' $Db)[0].revision)
    Import-StoreWLegacyObservations $Db @($batch.Changes.Guid) ([string]$c.DomainDn) $rev
    $keys=@($batch.Changes|Where-Object{$_.Guid}|ForEach-Object{ConvertTo-DomeniaSqlLiteral ([string]$_.Guid)}|Select-Object -Unique) -join ',';if(-not $keys){$keys="''"}
    $directoryKeys=@($batch.Changes|Where-Object{$_.Kind -eq 'DirectoryObject'}|ForEach-Object{ConvertTo-DomeniaSqlLiteral ([string]$_.Guid)}|Select-Object -Unique) -join ',';if(-not $directoryKeys){$directoryKeys="''"}
    $observationWhere=@($batch.Changes|Where-Object{$_.Kind -eq 'Observation'}|ForEach-Object{'(object_guid='+(ConvertTo-DomeniaSqlLiteral ([string]$_.Guid))+' AND family='+(ConvertTo-DomeniaSqlLiteral ([string]$_.Family))+')'}|Select-Object -Unique) -join ' OR '
    $detailWhere=@($batch.Changes|Where-Object{$_.Kind -eq 'DetailResult'}|ForEach-Object{'(object_guid='+(ConvertTo-DomeniaSqlLiteral ([string]$_.Guid))+' AND result_kind='+(ConvertTo-DomeniaSqlLiteral ([string]$_.ResultKind))+' AND request_key='+(ConvertTo-DomeniaSqlLiteral ([string]$_.RequestKey))+')'}|Select-Object -Unique) -join ' OR '
    $factKeys=@($batch.Changes|Where-Object{$_.Kind -eq 'DirectoryObject' -and $null -ne $_.Facts}|ForEach-Object{ConvertTo-DomeniaSqlLiteral ([string]$_.Guid)}|Select-Object -Unique) -join ','
    $dirs=@{};$obs=@{};$details=@{};$facts=@{}
    # A ping needs the canonical DN and only its previous family, not every WMI result.
    foreach($r in @(Invoke-DomeniaDbQuery "SELECT a.*,CASE WHEN a.object_guid IN ($directoryKeys) THEN d.payload ELSE NULL END AS store_payload,d.field_times,d.revision AS store_revision FROM ad_objects a LEFT JOIN domenia_directory_data d ON d.object_guid=a.object_guid WHERE a.object_guid IN ($keys);" $Db)){$dirs[[string]$r.object_guid]=$r}
    if($observationWhere){foreach($r in @(Invoke-DomeniaDbQuery "SELECT * FROM domenia_observations WHERE $observationWhere;" $Db)){$obs[[string]$r.object_guid+'|'+[string]$r.family]=$r}}
    if($detailWhere){foreach($r in @(Invoke-DomeniaDbQuery "SELECT * FROM domenia_details WHERE $detailWhere;" $Db)){$details[[string]$r.object_guid+'|'+[string]$r.result_kind+'|'+[string]$r.request_key]=$r}}
    if($factKeys){foreach($r in @(Invoke-DomeniaDbQuery "SELECT * FROM ad_computer_facts WHERE object_guid IN ($factKeys);" $Db)){$facts[[string]$r.object_guid]=$r}}
    # Scope clocks (points 4, 5 and 10): one row per domain, family and scope; the commit time is their recorded time.
    $recordedAt=[datetime]::UtcNow.ToString('o');$runs=@{};$runWhere=Get-StoreWCollectionRunWhere @($batch.Changes)
    if($runWhere){
        [void](Invoke-DomeniaDbExec 'CREATE TABLE IF NOT EXISTS domenia_domain_metadata(domain_dn TEXT NOT NULL,family TEXT NOT NULL,request_key TEXT NOT NULL,attempt_at TEXT NOT NULL,status TEXT NOT NULL,error TEXT NOT NULL DEFAULT '''',success_at TEXT NOT NULL DEFAULT '''',payload TEXT,attempt_payload TEXT,revision INTEGER NOT NULL,PRIMARY KEY(domain_dn,family,request_key));' $Db)
        foreach($r in @(Invoke-DomeniaDbQuery "SELECT * FROM domenia_domain_metadata WHERE $runWhere;" $Db)){$runs[[string]$r.domain_dn+'|'+[string]$r.family+'|'+[string]$r.request_key]=$r}
    }
    $sql=[Text.StringBuilder]::new()
    foreach($change in @($batch.Changes)){
        if($change.Kind -in @('QueryRecipe','QueryDependency','QueryMigration')){Write-StoreWQueryChange $Db $change $c $rev;continue}
        if($change.Kind -eq 'CollectionRun'){
            # Same clock rule as the measures: a newer attempt replaces the attempt fields only; a success replaces
            # the success fields only when it is not older. A failure never erases the last successful run.
            $runScope=[string]$change.ScopeDn;$runPrefix=if([bool]$change.Subtree){'subtree:'}else{'onelevel:'}
            if(([string]$change.DomainDn -ine [string]$c.DomainDn) -or ([string]$change.Family -cnotin @('Directory','Presence','Inventory')) -or ([string]$change.Status -cnotin @('Success','Partial','Error','Cancelled')) -or ([string]$change.RequestKey -cne ($runPrefix+$runScope.ToLowerInvariant())) -or (($runScope -ine [string]$c.DomainDn) -and (-not $runScope.EndsWith(','+[string]$c.DomainDn,[StringComparison]::OrdinalIgnoreCase)))){throw 'Releve de perimetre incoherent.'}
            $runKey=[string]$change.DomainDn+'|'+[string]$change.Family+'|'+[string]$change.RequestKey;$old=$runs[$runKey]
            $newAttempt=(($null -eq $old) -or ([string]::CompareOrdinal([string]$change.AttemptedAtUtc,[string]$old.attempt_at) -ge 0))
            $newSuccess=(([string]$change.Status -eq 'Success') -and (($null -eq $old) -or ([string]::CompareOrdinal([string]$change.AttemptedAtUtc,[string]$old.success_at) -ge 0)))
            if((-not $newAttempt) -and (-not $newSuccess)){continue}
            $runData=Get-StoreWMap $change.Data;$runData.RecordedAtUtc=$recordedAt
            $runJson=([pscustomobject]$runData)|ConvertTo-Json -Depth 4 -Compress
            $runAttempt=if($newAttempt){[string]$change.AttemptedAtUtc}else{[string]$old.attempt_at}
            $runStatus=if($newAttempt){[string]$change.Status}else{[string]$old.status}
            $runError=if($newAttempt){[string]$change.Error}else{[string]$old.error}
            $runSuccess=if($newSuccess){[string]$change.AttemptedAtUtc}elseif($null -ne $old){[string]$old.success_at}else{''}
            $runSuccessJson=if($newSuccess){$runJson}elseif($null -ne $old){[string]$old.payload}else{'null'}
            $runAttemptJson=if($newAttempt){if($change.Status -eq 'Success'){'null'}else{$runJson}}else{[string]$old.attempt_payload}
            $v=@([string]$change.DomainDn,[string]$change.Family,[string]$change.RequestKey,$runAttempt,$runStatus,$runError,$runSuccess,$runSuccessJson,$runAttemptJson,$rev)
            [void]$sql.AppendLine('INSERT OR REPLACE INTO domenia_domain_metadata(domain_dn,family,request_key,attempt_at,status,error,success_at,payload,attempt_payload,revision) VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
            $runs[$runKey]=[pscustomobject]@{attempt_at=$runAttempt;status=$runStatus;error=$runError;success_at=$runSuccess;payload=$runSuccessJson;attempt_payload=$runAttemptJson}
            continue
        }
        if($change.Kind -eq 'AccountPreference'){
            $v=@($change.DomainDn,$change.Scope,$change.UserName,$change.UpdatedAtUtc,$rev)
            $domainLit=ConvertTo-DomeniaSqlLiteral ([string]$change.DomainDn);$scopeLit=ConvertTo-DomeniaSqlLiteral ([string]$change.Scope);$dateLit=ConvertTo-DomeniaSqlLiteral ([string]$change.UpdatedAtUtc)
            [void]$sql.AppendLine('INSERT OR REPLACE INTO domenia_account_preferences(domain_dn,scope,user_name,updated_at,revision) SELECT '+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+" WHERE NOT EXISTS(SELECT 1 FROM domenia_account_preferences WHERE domain_dn=$domainLit AND scope=$scopeLit AND updated_at>$dateLit);")
            continue
        }
        $guid=[string]$change.Guid;$guidLit=ConvertTo-DomeniaSqlLiteral $guid;$dnLit=ConvertTo-DomeniaSqlLiteral ([string]$change.DN)
        if($change.Kind -eq 'DirectoryObject'){
            $old=$dirs[$guid];$record=[ordered]@{};$times=[ordered]@{}
            if($null -ne $old){$record=Get-StoreWMap (Convert-StoreWDirectory $old);$times=Get-StoreWMap (Get-StoreWJson ([string]$old.field_times))}
            $record.Guid=$guid;$fieldSources=Get-StoreWMap $record.FieldSources
            $at=[string]$change.ObservedAtUtc
            if(-not $record.DN -or [string]::CompareOrdinal($at,[string]$times.DN) -ge 0){$record.DN=[string]$change.DN;$times.DN=$at;$fieldSources.DN=[string]$change.Source}
            foreach($field in @($change.Fields)){
                $previous=[string]$times[$field];if(-not $previous -and $null -ne $old){$previous=[string]$old.synced_at}
                if([string]$field -ne 'Details' -and [string]::CompareOrdinal($at,$previous) -lt 0){continue}
                if([string]$field -eq 'Details'){
                    $merged=Get-StoreWMap $record.Details
                    foreach($p in $change.Data.Details.PSObject.Properties){$timeKey='Details.'+$p.Name;if([string]::CompareOrdinal($at,[string]$times[$timeKey]) -ge 0){$merged[$p.Name]=$p.Value;$times[$timeKey]=$at;$fieldSources[$timeKey]=[string]$change.Source}}
                    $record.Details=[pscustomobject]$merged
                }else{$record[$field]=$change.Data.$field;$times[$field]=$at;$fieldSources[$field]=[string]$change.Source}
            }
            if([string]$record.Type -notin @('Machine','Utilisateur','Groupe','OU','Conteneur')){throw 'Type annuaire absent ou invalide.'}
            if([string]::CompareOrdinal($at,[string]$record.ObservedAtUtc) -ge 0){$record.ObservedAtUtc=$at;$record.Source=[string]$change.Source}
            $record.Revision=$rev;$record.FieldSources=[pscustomobject]$fieldSources
            $currentDnLit=ConvertTo-DomeniaSqlLiteral ([string]$record.DN)
            if($null -ne $old -and [string]$old.distinguished_name -ine [string]$record.DN){
                $oldKey=ConvertTo-DomeniaSqlLiteral (([string]$old.distinguished_name).ToLowerInvariant())
                foreach($cached in @(Invoke-DomeniaDbQuery ("SELECT payload FROM park_session_cache WHERE object_key=$oldKey;") $Db)){
                    $oldProjection=Get-StoreWJson ([string]$cached.payload)
                    if([string]$oldProjection.Guid -ieq $guid){[void]$sql.AppendLine("DELETE FROM park_session_cache WHERE object_key=$oldKey AND payload="+(ConvertTo-DomeniaSqlLiteral ([string]$cached.payload))+';')}
                }
            }
            [void]$sql.AppendLine("UPDATE domenia_observations SET dn=$currentDnLit WHERE object_guid=$guidLit;UPDATE domenia_details SET dn=$currentDnLit WHERE object_guid=$guidLit;")
            $search=([string]$record.Name+' '+[string]$record.Login+' '+[string]$record.Upn+' '+[string]$record.Display+' '+[string]$record.Description+' '+[string]$record.Extra).ToLowerInvariant()
            $values=@($guid,$guid,$record.Type,$record.Name,$record.Login,$record.Upn,$record.Display,$record.Description,$record.Extra,$record.State,$record.DN,$record.WhenChanged,[long]$record.Usn,$record.LastLogon,$search,$record.Source,$record.ObservedAtUtc)
            [void]$sql.AppendLine('INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
            $dataJson=([pscustomobject]$record)|ConvertTo-Json -Depth 20 -Compress;$timesJson=([pscustomobject]$times)|ConvertTo-Json -Depth 4 -Compress
            [void]$sql.AppendLine('INSERT OR REPLACE INTO domenia_directory_data(object_guid,payload,field_times,revision,observed_at) VALUES('+( (@($guid,$dataJson,$timesJson,$rev,$record.ObservedAtUtc)|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
            # Repeated changes for one identity in the same batch merge against the just-built version.
            $dirs[$guid]=[pscustomobject]@{object_guid=$guid;distinguished_name=$record.DN;object_type=$record.Type;name=$record.Name;login=$record.Login;upn=$record.Upn;display_name=$record.Display;description=$record.Description;extra=$record.Extra;state=$record.State;when_changed=$record.WhenChanged;usn_changed=$record.Usn;last_logon=$record.LastLogon;source_dc=$record.Source;synced_at=$record.ObservedAtUtc;store_payload=$dataJson;field_times=$timesJson;store_revision=$rev}
            if($null -ne $change.Facts){
                $fact=$facts[$guid];$fv=[ordered]@{OsVersion='';WhenCreated='';PwdLastSet='';LapsKind='';LapsExpiry=''}
                if($null -ne $fact){$fv.OsVersion=$fact.os_version;$fv.WhenCreated=$fact.when_created;$fv.PwdLastSet=$fact.pwd_last_set;$fv.LapsKind=$fact.laps_kind;$fv.LapsExpiry=$fact.laps_expiry}
                if($null -eq $fact -or [string]::CompareOrdinal($at,[string]$fact.read_at) -ge 0){
                    foreach($p in $change.Facts.PSObject.Properties){if($fv.Contains($p.Name)){$fv[$p.Name]=$p.Value}}
                    $v=@($guid,([string]$record.DN).ToLowerInvariant(),$fv.OsVersion,$fv.WhenCreated,$fv.PwdLastSet,$fv.LapsKind,$fv.LapsExpiry,$at)
                    [void]$sql.AppendLine('INSERT OR REPLACE INTO ad_computer_facts(object_guid,object_key,os_version,when_created,pwd_last_set,laps_kind,laps_expiry,read_at) VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
                    $facts[$guid]=[pscustomobject]@{os_version=$fv.OsVersion;when_created=$fv.WhenCreated;pwd_last_set=$fv.PwdLastSet;laps_kind=$fv.LapsKind;laps_expiry=$fv.LapsExpiry;read_at=$at}
                }
            }
        }else{
            $isObservation=([string]$change.Kind -eq 'Observation')
            $key=$guid+'|'+$(if($isObservation){[string]$change.Family}else{[string]$change.ResultKind+'|'+[string]$change.RequestKey})
            $map=if($isObservation){$obs}else{$details};$old=$map[$key]
            $newAttempt=($null -eq $old -or [string]::CompareOrdinal([string]$change.AttemptedAtUtc,[string]$old.attempt_at) -ge 0)
            $newSuccess=($change.Status -eq 'Success' -and ($null -eq $old -or [string]::CompareOrdinal([string]$change.ObservedAtUtc,[string]$old.success_at) -ge 0))
            if(-not $newAttempt -and -not $newSuccess){continue}
            $dataJson=if($null -ne $change.Data){$change.Data|ConvertTo-Json -Depth 20 -Compress}else{'null'}
            # Points 82 and 87: a few probes keep a bounded history built from the previous committed payload of the
            # same family (Add-DomeniaProbeHistory). Summaries keep using the incoming data, without history. The
            # previous payload is parsed only for a probe that keeps a history (Get-DomeniaProbeHistoryPolicy).
            if(($isObservation) -and ($newSuccess) -and ($null -ne $change.Data) -and (([string]$change.Family).StartsWith('Probe:',[StringComparison]::Ordinal))){
                $historyProbeId=([string]$change.Family).Substring(6)
                if($null -ne (Get-DomeniaProbeHistoryPolicy $historyProbeId)){
                    $previousPayload=$null
                    if(($null -ne $old) -and ([string]$old.payload) -and ([string]$old.payload -cne 'null')){try{$previousPayload=Get-StoreWJson ([string]$old.payload)}catch{$previousPayload=$null}}
                    $withHistory=Add-DomeniaProbeHistory -Data $change.Data -PreviousData $previousPayload -ProbeId $historyProbeId
                    if($null -ne $withHistory){$dataJson=$withHistory|ConvertTo-Json -Depth 20 -Compress}
                }
            }
            $success=if($newSuccess){[string]$change.ObservedAtUtc}elseif($null -ne $old){[string]$old.success_at}else{''}
            $successJson=if($newSuccess){$dataJson}elseif($null -ne $old){[string]$old.payload}else{'null'}
            $attemptAt=if($newAttempt){[string]$change.AttemptedAtUtc}else{[string]$old.attempt_at}
            $status=if($newAttempt){[string]$change.Status}else{[string]$old.status}
            $error=if($newAttempt){[string]$change.Error}else{[string]$old.error}
            $definition=if($newAttempt){[string]$change.DefinitionHash}else{[string]$old.definition_hash}
            $attemptJson=if($newAttempt){if($change.Status -eq 'Error'){$dataJson}else{'null'}}else{[string]$old.attempt_payload}
            $currentDn=if($dirs.ContainsKey($guid)){[string]$dirs[$guid].distinguished_name}else{[string]$change.DN}
            if($isObservation){
                $summary=Get-StoreWObservationSummaryJson ([string]$change.Family) $change.Data
                $successSummary=if($newSuccess){$summary}elseif($null -ne $old){$old.summary_payload}else{$null}
                $attemptSummary=if($newAttempt){if($change.Status -eq 'Error'){$summary}else{$null}}elseif($null -ne $old){$old.attempt_summary}else{$null}
                $table='domenia_observations';$columns='object_guid,family,dn,definition_hash,attempt_at,status,error,success_at,payload,attempt_payload,summary_payload,attempt_summary,revision';$v=@($guid,$change.Family,$currentDn,$definition,$attemptAt,$status,$error,$success,$successJson,$attemptJson,$successSummary,$attemptSummary,$rev)
            }
            else{
                $summary=Get-StoreWDetailSummaryJson ([string]$change.ResultKind) ([string]$change.RequestKey) $change.Data -AllowIncomplete:($change.Status -eq 'Error')
                $successSummary=if($newSuccess){$summary}elseif($null -ne $old){[string]$old.summary_payload}else{'null'}
                $attemptSummary=if($newAttempt){if($change.Status -eq 'Error'){$summary}else{'null'}}elseif($null -ne $old){[string]$old.attempt_summary}else{'null'}
                $table='domenia_details';$columns='object_guid,result_kind,request_key,dn,attempt_at,status,error,success_at,payload,attempt_payload,summary_payload,attempt_summary,revision';$v=@($guid,$change.ResultKind,$change.RequestKey,$currentDn,$attemptAt,$status,$error,$success,$successJson,$attemptJson,$successSummary,$attemptSummary,$rev)
            }
            [void]$sql.AppendLine('INSERT OR REPLACE INTO '+$table+'('+$columns+') VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');')
            $map[$key]=[pscustomobject]@{attempt_at=$attemptAt;status=$status;error=$error;definition_hash=$definition;attempt_payload=$attemptJson;success_at=$success;payload=$successJson;summary_payload=$successSummary;attempt_summary=$attemptSummary}
        }
    }
    if($sql.Length){[void](Invoke-DomeniaDbExec $sql.ToString() $Db)}
    Import-StoreWLegacyObservations $Db @($batch.Changes.Guid) ([string]$c.DomainDn) $rev
    # Canonical families are read after COMMIT. Do not re-serialize every WMI family for a presence update.
    # The immutable input batch is bounded; dashboard decoders prepare bounded families separately.
    $at=$recordedAt;$identities=@($batch.Changes|ForEach-Object{[pscustomobject]@{Kind=$_.Kind;Guid=$_.Guid;Family=$_.Family;ResultKind=$_.ResultKind;RequestKey=$_.RequestKey}})|ConvertTo-Json -Depth 4 -Compress
    $v=@($batch.BatchId,$actual,$c.RequestId,[long]$batch.Sequence,$rev,$at,$identities)
    [void](Invoke-DomeniaDbExec ('UPDATE domenia_store_state SET revision='+$rev+' WHERE id=1;INSERT INTO domenia_store_batches(batch_id,payload_hash,request_id,sequence,revision,committed_at,changes_json) VALUES('+(($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $Db)
    # Compact only old descriptive identities, never the idempotence key/hash or its
    # original revision/time. Old retries therefore remain detectable indefinitely.
    # Bound each maintenance pass and amortize it over 256 committed batches.
    if(($rev % 256) -eq 0 -and $rev -gt 2048){
        $cutoff=ConvertTo-DomeniaSqlLiteral ([datetime]::UtcNow.AddDays(-30).ToString('o'))
        [void](Invoke-DomeniaDbExec ("UPDATE domenia_store_batches SET changes_json='[]' WHERE batch_id IN (SELECT batch_id FROM domenia_store_batches WHERE revision<="+($rev-2048)+" AND committed_at<$cutoff AND changes_json<>'[]' ORDER BY revision LIMIT 512);") $Db)
    }
    return [pscustomobject]@{Already=$false;Batch=$batch;Revision=$rev;CommittedAtUtc=$at}
}

function LinkHash($r){
    if($null -eq $r){return ''}
    $v=[ordered]@{UserLogin=[string]$r.user_login;Computer=[string]$r.computer;Source=[string]$r.source;Confidence=[string]$r.confidence;VerifiedInAD=[string]([int]$r.verified_in_ad -ne 0);When=[string]$r.observed_at;Details=[string]$r.details;UserGuid=[string]$r.user_guid;ComputerGuid=[string]$r.computer_guid;UserDn=[string]$r.user_dn;ComputerDn=[string]$r.computer_dn}
    $h=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes(($v|ConvertTo-Json -Compress)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}
}
function Get-DomeniaLegacyList {
    param($Value)
    if($null -eq $Value){return @()}
    return @($Value)
}
function Get-DomeniaLegacyComputerKey {
    param([string]$Computer)
    $c=([string]$Computer).Trim()
    if([string]::IsNullOrWhiteSpace($c)){return ''}
    $c=$c -replace '[" \t\r\n]',''
    if($c.EndsWith('$')){$c=$c.Substring(0,$c.Length-1)}
    if($c.Contains('.')){$c=$c.Split('.')[0]}
    return $c.ToUpperInvariant()
}
function Get-DomeniaLegacyDomainFromBaseDn {
    param([string]$BaseDn)
    if($BaseDn -notmatch '^(?i)\s*DC=[^,=\s]+(?:\s*,\s*DC=[^,=\s]+)*\s*$'){return ''}
    $dc=@()
    foreach($part in @(([string]$BaseDn) -split ',')){
        $t=$part.Trim()
        if($t -match '(?i)^DC=([^,]+)$'){$dc+=$matches[1].Trim()}
    }
    return (($dc -join '.') -replace '^\.+','').ToLowerInvariant()
}
function Invoke-DomeniaLinkWrite {
    param([IntPtr]$DatabaseHandle,[string]$Key,[string]$Expected,$Row,[bool]$Remove,[System.Collections.Generic.List[string]]$Conflicts,[bool]$ImportMode)
    $keyLit=ConvertTo-DomeniaSqlLiteral $Key
    $current=@(Invoke-DomeniaDbQuery ("SELECT * FROM user_machine_links WHERE computer_key=$keyLit;") $DatabaseHandle)
    $actual=if($current.Count){LinkHash $current[0]}else{''}
    if($ImportMode){
        if($current.Count){$Conflicts.Add($Key);return $false}
        if($Remove){$Conflicts.Add($Key);return $false}
    } else {
        if($actual -cne $Expected){$Conflicts.Add($Key);return $false}
        if($Remove){[void](Invoke-DomeniaDbExec ("DELETE FROM user_machine_links WHERE computer_key=$keyLit;") $DatabaseHandle);return $true}
    }
    if($current.Count){
        [void](Invoke-DomeniaDbExec ("INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) SELECT l.user_login,l.computer_key,l.computer,l.source,l.confidence,l.verified_in_ad,l.observed_at,l.details,l.user_guid,l.computer_guid FROM user_machine_links l WHERE l.computer_key=$keyLit AND NOT EXISTS(SELECT 1 FROM user_machine_history h WHERE h.computer_key=l.computer_key AND h.user_login=l.user_login AND COALESCE(h.observed_at,'')=COALESCE(l.observed_at,'') AND COALESCE(h.source,'')=COALESCE(l.source,'') AND COALESCE(h.user_guid,'')=COALESCE(l.user_guid,''));") $DatabaseHandle)
    }
    $l=$Row
    $verified=if([string]$l.VerifiedInAD -ieq 'True'){1}else{0}
    $values=@($Key,[string]$l.UserLogin,[string]$l.Computer,[string]$l.Source,[int]$l.Confidence,$verified,[string]$l.When,[string]$l.Details,[string]$l.UserGuid,[string]$l.ComputerGuid,[string]$l.UserDn,[string]$l.ComputerDn)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO user_machine_links(computer_key,user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
    $history=@([string]$l.UserLogin,$Key,[string]$l.Computer,[string]$l.Source,[int]$l.Confidence,$verified,[string]$l.When,[string]$l.Details,[string]$l.UserGuid,[string]$l.ComputerGuid)
    [void](Invoke-DomeniaDbExec ('INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) VALUES('+(($history|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
    return $true
}
function Import-DomeniaLegacy {
    param([IntPtr]$DatabaseHandle,$Item)
    $Row=$Item.Row
    if($null -eq $Row){throw 'Payload import legacy absent.'}
    $Marker=[string]$Row.Marker
    $BaseDn=[string]$Row.BaseDn
    $At=[string]$Row.At
    if([string]::IsNullOrWhiteSpace($Marker)){throw 'Marqueur import legacy requis.'}
    $domain=Get-DomeniaLegacyDomainFromBaseDn $BaseDn
    if([string]::IsNullOrWhiteSpace($domain)){throw 'BaseDn domaine requis.'}
    if([string]::IsNullOrWhiteSpace($At)){$At=[datetime]::UtcNow.ToString('o')}
    $markerRows=@(Invoke-DomeniaDbQuery "SELECT base_dn,details FROM sync_state WHERE scope='legacy_import' LIMIT 1;" $DatabaseHandle)
    if($markerRows.Count -gt 0){
        $existingDetails=[string]$markerRows[0].details
        $existingMarker=''
        if($existingDetails -match '(?i)marker=(.+)$'){$existingMarker=$matches[1]}
        if($existingMarker -ceq $Marker){
            $existingDomain=Get-DomeniaLegacyDomainFromBaseDn ([string]$markerRows[0].base_dn)
            if(-not [string]::IsNullOrWhiteSpace($existingDomain) -and $existingDomain -cne $domain){throw 'Marqueur legacy_import identique mais domaine different.'}
            return [pscustomobject]@{Saved=$true;Conflicts=@();Count=1;Already=$true;Imported=[pscustomobject]@{Objects=0;Park=0;UserScans=0;Secrets=0;Links=0};ImportedLinks=@()}
        }
        throw 'Import legacy deja applique avec un autre marqueur.'
    }
    $counts=@(Invoke-DomeniaDbQuery "SELECT (SELECT count(*) FROM ad_objects) AS ad_objects,(SELECT count(*) FROM park_state) AS park_state,(SELECT count(*) FROM user_scan_history) AS user_scan_history,(SELECT count(*) FROM secret_state) AS secret_state;" $DatabaseHandle)
    if($counts.Count -ne 1){throw 'Garde tables legacy impossible.'}
    $c=$counts[0]
    if([int]$c.ad_objects -gt 0 -or [int]$c.park_state -gt 0 -or [int]$c.user_scan_history -gt 0 -or [int]$c.secret_state -gt 0){throw 'Tables legacy non vides.'}
    $objects=@(Get-DomeniaLegacyList $Row.Objects)
    $park=@(Get-DomeniaLegacyList $Row.Park)
    $userScans=@(Get-DomeniaLegacyList $Row.UserScans)
    $secrets=@(Get-DomeniaLegacyList $Row.Secrets)
    $links=@(Get-DomeniaLegacyList $Row.Links)
    if($objects.Count -gt 250000 -or $park.Count -gt 250000 -or $userScans.Count -gt 250000 -or $secrets.Count -gt 250000 -or $links.Count -gt 250000){throw 'Tableau import legacy trop grand.'}
    $dirRows=@(Invoke-DomeniaDbQuery "SELECT base_dn FROM sync_state WHERE scope='directory' LIMIT 1;" $DatabaseHandle)
    if($dirRows.Count -gt 0){
        $existingDomain=Get-DomeniaLegacyDomainFromBaseDn ([string]$dirRows[0].base_dn)
        if([string]::IsNullOrWhiteSpace($existingDomain) -or $existingDomain -cne $domain){throw 'Domaine different de sync_state directory.'}
    } else {
        $values=@('directory','migration',$BaseDn,[long]0,$At,[int]$objects.Count,'legacy_import')
        [void](Invoke-DomeniaDbExec ('INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
    }
    $imported=0
    # PF-07: up to 250 000 rows per table: one prepared statement per table instead of one parsed INSERT per row.
    $objectStatement=$null;$parkStatement=$null;$scanStatement=$null;$secretStatement=$null
    if($objects.Count){$objectStatement=New-StoreWStatement $DatabaseHandle 'INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)'}
    if($park.Count){$parkStatement=New-StoreWStatement $DatabaseHandle 'INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES(?1,?2,?3,?4,?5,?6)'}
    if($userScans.Count){$scanStatement=New-StoreWStatement $DatabaseHandle 'INSERT INTO user_scan_history(login_key,login,scanned_at,scanned,candidates,reachable,probed,found) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)'}
    if($secrets.Count){$secretStatement=New-StoreWStatement $DatabaseHandle 'INSERT INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)'}
    foreach($r in $objects){
        if($null -eq $r -or [string]::IsNullOrWhiteSpace([string]$r.DN)){throw 'Objet legacy sans DN.'}
        if(-not ([string]$r.DN).EndsWith(','+$BaseDn,[StringComparison]::OrdinalIgnoreCase) -and [string]$r.DN -ine $BaseDn){throw 'Objet legacy dans un autre domaine.'}
        $key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=(([string]$r.Type)+'|'+([string]$r.DN)).ToLowerInvariant()}
        if([string]::IsNullOrWhiteSpace($key)){throw 'Objet legacy sans cle.'}
        $search=(([string]$r.Name)+' '+([string]$r.Login)+' '+([string]$r.Upn)+' '+([string]$r.Display)+' '+([string]$r.Description)+' '+([string]$r.Extra)).ToLowerInvariant()
        $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,$search,'legacy_import',$At)
        Invoke-StoreWStatement $objectStatement $values
        $imported++
    }
    foreach($r in $park){
        $key=[string]$r.Key
        if([string]::IsNullOrWhiteSpace($key)){$key=Get-DomeniaLegacyComputerKey ([string]$r.Computer)}
        if([string]::IsNullOrWhiteSpace($key)){throw 'Ligne park legacy sans cle.'}
        $values=@($key,[string]$r.Computer,[string]$r.LastProbe,[string]$r.Status,[string]$r.User,[int]$r.Attempts)
        Invoke-StoreWStatement $parkStatement $values
    }
    foreach($r in $userScans){
        $login=[string]$r.Login
        if([string]::IsNullOrWhiteSpace($login)){throw 'Ligne scan legacy sans login.'}
        $loginKey=$login.ToLowerInvariant()
        $values=@($loginKey,$login,[string]$r.At,[int][bool]$r.Scanned,[int]$r.Candidates,[int]$r.Reachable,[int]$r.Probed,[string]$r.Found)
        Invoke-StoreWStatement $scanStatement $values
    }
    foreach($r in $secrets){
        $computer=[string]$r.Computer
        if([string]::IsNullOrWhiteSpace($computer)){throw 'Ligne secret legacy sans ordinateur.'}
        $key=$computer.ToUpperInvariant()
        $values=@($key,$computer,[string]$r.At,[int]$r.BitLockerKeys,[string]$r.BitLockerLast,[string]$r.LapsScheme,[string]$r.LapsExpiry,[string]$r.Verdict,'Metadonnees sans secret')
        Invoke-StoreWStatement $secretStatement $values
    }
    $conflicts=[Collections.Generic.List[string]]::new()
    $importedLinks=[Collections.Generic.List[object]]::new()
    foreach($l in $links){
        $key=Get-DomeniaLegacyComputerKey ([string]$l.Computer)
        if([string]::IsNullOrWhiteSpace($key)){throw 'Lien legacy sans ordinateur.'}
        $added=Invoke-DomeniaLinkWrite -DatabaseHandle $DatabaseHandle -Key $key -Expected '' -Row $l -Remove $false -Conflicts $conflicts -ImportMode $true
        if($added){[void]$importedLinks.Add($l)}
    }
    $values=@('legacy_import','legacy_import',$BaseDn,[long]0,$At,[int]0,('marker='+$Marker))
    [void](Invoke-DomeniaDbExec ('INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
    $counts=[pscustomobject]@{Objects=$objects.Count;Park=$park.Count;UserScans=$userScans.Count;Secrets=$secrets.Count;Links=$importedLinks.Count}
    return [pscustomobject]@{Saved=$true;Conflicts=$conflicts.ToArray();Count=1;Already=$false;Imported=$counts;ImportedLinks=$importedLinks.ToArray()}
}
$items=@($Payload.Items)
$legacy=@($items|Where-Object{$_.Kind -eq 'LegacyImport'})
if($legacy.Count -gt 0 -and $items.Count -gt 1){throw 'Import legacy doit etre seul.'}
if(@($Payload.Items).Count -gt 64){throw 'Lot stockage trop grand.'}
$path=[IO.Path]::GetFullPath([string]$Payload.Path)
if($path.StartsWith('\\') -or [IO.DriveInfo]::new([IO.Path]::GetPathRoot($path)).DriveType -eq [IO.DriveType]::Network){throw 'Base active reseau non prise en charge.'}
$probe=[IO.FileInfo]::new($path)
while($null -ne $probe){if($probe.Exists -and ($probe.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Base ou dossier redirige.'};$probe=if($probe -is [IO.FileInfo]){$probe.Directory}else{$probe.Parent}}
$db=[IntPtr]::Zero;$transaction=$false;$conflicts=[Collections.Generic.List[string]]::new()
# PF-07: statements of a previous session of this pooled runspace were finalized by its finally block.
$script:StoreWStatements=[Collections.Generic.List[object]]::new()
$indexStatement=$null;$secretRead=$null;$secretWrite=$null;$indexWatch=$null;$indexRows=0L
try {
 $availableBytes=-1L
 try{$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($path));if($drive.IsReady){$availableBytes=[long]$drive.AvailableFreeSpace}}catch{}
 $incomingBytes=0L;foreach($item in $items){if($item.Kind -eq 'StoreBatch'){$incomingBytes += [Text.Encoding]::UTF8.GetByteCount([string]$item.Json)}}
 $minimumBytes=33554432L+(4L*$incomingBytes)
 if($availableBytes -ge 0 -and $availableBytes -lt $minimumBytes){throw ('StorageInsufficientSpace : espace libre '+$availableBytes+' octets, reserve minimale '+$minimumBytes+' octets. Le lot reste non enregistre.')}
 $db=Open-DomeniaDatabase -Path $path
 [void](Invoke-DomeniaDbExec 'PRAGMA synchronous=FULL;' $db)
 [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db);$transaction=$true
 $sqliteVersion=Assert-StoreWSession $db
 $sampleCount=0
 $storeItems=@($items|Where-Object{$_.Kind -eq 'StoreBatch'})
 if($storeItems.Count){
  if($items.Count -ne 1){throw 'Un lot canonique possede sa transaction.'}
  $commit=Invoke-StoreWBatch $db $storeItems[0]
  [void](Invoke-DomeniaDbExec 'COMMIT;' $db);$transaction=$false
  # A second, read-only transaction observes committed rows, never in-memory collector objects.
  [void](Invoke-DomeniaDbExec 'BEGIN;' $db);$transaction=$true
  $read=Read-StoreWCommitted $db @($commit.Batch.Changes.Guid)
  $collectionRuns=@(Read-StoreWCollectionRuns $db @($commit.Batch.Changes))
  $accountPreferences=@(Invoke-DomeniaDbQuery ('SELECT scope AS Scope,user_name AS UserName,domain_dn AS DomainDn,updated_at AS UpdatedAtUtc,revision AS Revision FROM domenia_account_preferences WHERE domain_dn='+(ConvertTo-DomeniaSqlLiteral ([string]$commit.Batch.Context.DomainDn))+' ORDER BY scope;') $db)
  $queryRead=[pscustomobject]@{QueryRecipes=@();QueryDependencies=@();QueryMigrations=@()}
  $queryChanges=@($commit.Batch.Changes|Where-Object{$_.Kind -in @('QueryRecipe','QueryDependency','QueryMigration')})
  if($queryChanges.Count){
    $queryIds=@($queryChanges|ForEach-Object{if($_.Kind -eq 'QueryRecipe'){[string]$_.Record.Id}elseif($_.Kind -eq 'QueryDependency'){[string]$_.RecipeId}}|Select-Object -Unique)
    $query=[pscustomobject]@{StoreId=[string]$commit.Batch.Context.StoreId;DomainDn=[string]$commit.Batch.Context.DomainDn;IncludeArchived=$true;Limit=250;Offset=0}
    $queryRead=Read-StoreWQueryLibrary $db $query ([string]$commit.Batch.Context.DomainDn) ([long]$read.SnapshotRevision) ([string]$commit.Batch.Context.StoreId) -RecipeIds $queryIds
  }
  [void](Invoke-DomeniaDbExec 'COMMIT;' $db);$transaction=$false
  [pscustomobject]@{Saved=$true;DataSource='SQLite';SQLiteVersion=$sqliteVersion;StoreId=[string]$commit.Batch.Context.StoreId;Path=$path;DomainDn=[string]$commit.Batch.Context.DomainDn;BatchId=[string]$commit.Batch.BatchId;RequestId=[string]$commit.Batch.Context.RequestId;Sequence=[long]$commit.Batch.Sequence;Revision=[long]$commit.Revision;SnapshotRevision=[long]$read.SnapshotRevision;CommittedAtUtc=[string]$commit.CommittedAtUtc;Already=[bool]$commit.Already;Rows=$read.Rows;Observations=$read.Observations;ObservationRows=$read.ObservationRows;Details=$read.Details;AccountPreferences=$accountPreferences;QueryRecipes=$queryRead.QueryRecipes;QueryDependencies=$queryRead.QueryDependencies;QueryMigrations=$queryRead.QueryMigrations;CollectionRuns=$collectionRuns;Count=@($commit.Batch.Changes).Count;Conflicts=@()}
  return
 }
 if($legacy.Count -gt 0){
  $r=Import-DomeniaLegacy $db $legacy[0]
  if([int]$r.Already -eq 1){[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db);$transaction=$false;return $r}
  [void](Invoke-DomeniaDbExec 'UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;COMMIT;' $db);$transaction=$false;return $r
 }
 foreach($i in @($Payload.Items)){
  if($i.Kind -eq 'Index'){
    $r=$i.Row;$key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=([string]$r.Type+'|'+[string]$r.DN).ToLowerInvariant()}
    # Same search_key formula as IndexBulk (CO-26): the extra field (system, location, service) stays searchable.
    $search=([string]$r.Name+' '+[string]$r.Login+' '+[string]$r.Upn+' '+[string]$r.Display+' '+[string]$r.Description+' '+[string]$r.Extra).ToLowerInvariant()
    $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,$search,[string]$i.Server,[string]$i.At)
    # PF-07: up to 64 rows per lot share one prepared statement.
    if($null -eq $indexStatement){$indexStatement=New-StoreWStatement $db 'INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)'}
    Invoke-StoreWStatement $indexStatement $values
  } elseif($i.Kind -eq 'Link'){
    [void](Invoke-DomeniaLinkWrite -DatabaseHandle $db -Key ([string]$i.Key) -Expected ([string]$i.Expected) -Row $i.Row -Remove ([bool]$i.Remove) -Conflicts $conflicts -ImportMode $false)
  }elseif($i.Kind -eq 'ParkSession'){
    $r=$i.Row
    if([int]$r.Version -ne 1 -or -not $r.Key -or -not $r.Guid){throw 'Observation du parc invalide.'}
    # Widget probe results (2026-10-07) need a deeper and larger observation; still bounded.
    $json=$r|ConvertTo-Json -Depth 7 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 262144){throw 'Observation du parc trop volumineuse.'}
    $values=@([string]$r.Key,[string]$r.CheckedUtc,$json)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO park_session_cache(object_key,checked_utc,payload) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    # Existing park coverage continues to display the latest attempt and the last known account.
    $keyLit=ConvertTo-DomeniaSqlLiteral (([string]$r.Computer).ToUpperInvariant())
    $old=@(Invoke-DomeniaDbQuery ("SELECT attempts FROM park_state WHERE computer_key=$keyLit;") $db)
    $attempts=1;if($old.Count){$attempts+=[int]$old[0].attempts}
    $status=if($r.Outcome -eq 'Observed'){'Session'}else{[string]$r.Outcome}
    $values=@(([string]$r.Computer).ToUpperInvariant(),[string]$r.Computer,[string]$r.CheckedUtc,$status,[string]$r.LinkUser,$attempts)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
  }elseif($i.Kind -eq 'SecretMeta'){
    # One computer, or the BitLocker presence of a whole OU (Rows): metadata only, never a key or a password.
    $secretRows=if($null -ne $i.Row.PSObject.Properties['Rows']){@($i.Row.Rows)}else{@($i.Row)}
    if($secretRows.Count -gt 50000){throw 'Lot de metadonnees de secrets trop grand.'}
    # PF-07: the BitLocker presence of an OU may hold 50 000 rows: one prepared read and one prepared write, shared by
    # every SecretMeta item of the lot.
    if($null -eq $secretRead){
      $secretRead=New-StoreWStatement $db 'SELECT * FROM secret_state WHERE computer_key=?1'
      $secretWrite=New-StoreWStatement $db 'INSERT OR REPLACE INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)'
    }
    foreach($r in $secretRows){
        if($null -eq $r -or -not ([string]$r.Computer).Trim()){continue}
        $prev=Read-StoreWStatementRow $secretRead @(([string]$r.Computer).ToUpperInvariant())
        # KeepKnown (BitLocker presence of an OU where nothing was visible): a key count already read for this computer
        # is never replaced by the zero of a read that saw nothing.
        if($null -ne $r.PSObject.Properties['KeepKnown'] -and [bool]$r.KeepKnown -and [int]$r.BitLockerKeys -eq 0 -and $null -ne $prev -and [int]$prev.bitlocker_keys -gt 0){continue}
        # BitLocker not read (-1, a LAPS read alone): the previous count, or -1 (unknown) for a first row, never 0.
        $keys=if([int]$r.BitLockerKeys -lt 0){if($null -ne $prev){[int]$prev.bitlocker_keys}else{-1}}else{[int]$r.BitLockerKeys}
        $last=if([int]$r.BitLockerKeys -lt 0){[string]$prev.bitlocker_last}else{[string]$r.BitLockerLast}
        $scheme=if([string]$r.LapsScheme){[string]$r.LapsScheme}else{[string]$prev.laps_scheme}
        $expiry=if([string]$r.LapsScheme){[string]$r.LapsExpiry}else{[string]$prev.laps_expiry}
        $values=@(([string]$r.Computer).ToUpperInvariant(),[string]$r.Computer,[string]$r.At,$keys,$last,$scheme,$expiry,[string]$r.Verdict,'Metadonnees sans secret')
        Invoke-StoreWStatement $secretWrite $values
    }
  }elseif($i.Kind -eq 'ParkReset'){
    # FI-13: « Oublier les relevés » deletes the park sweep state (last probe, status, attempts) of this base, after the
    # verified backup taken by the interface. Associations, observations and history are not touched.
    [void](Invoke-DomeniaDbExec 'DELETE FROM park_state;' $db)
  }elseif($i.Kind -eq 'FleetSnapshot'){
    # Daily local snapshot of the directory figures of the displayed OU (FO-10): the first of the day is kept,
    # history older than 400 days is dropped. No network, no directory value beyond the counts.
    $r=$i.Row
    $scopeKey=[string]$r.ScopeKey;$day=[string]$r.Day;$figures=[string]$r.Figures
    if(-not $scopeKey -or $scopeKey.Length -gt 4096 -or $day -notmatch '^\d{4}-\d{2}-\d{2}$' -or $figures.Length -gt 4096){throw 'Instantane du parc invalide.'}
    $values=@($scopeKey,$day,[string]$r.TakenAt,[string]$r.ScopeDn,[int]$r.Machines,$figures)
    [void](Invoke-DomeniaDbExec ('INSERT OR IGNORE INTO fleet_snapshots(scope_key,snapshot_day,taken_at,scope_dn,machines,figures) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    [void](Invoke-DomeniaDbExec "DELETE FROM fleet_snapshots WHERE snapshot_day < date('now','-400 days');" $db)
  }elseif($i.Kind -in @('Presence','UserScan','Park','Sample')){
    $r=$i.Row;$columns='';$table='';$values=@();$verb='INSERT OR REPLACE'
    switch([string]$i.Kind){
      'Presence' {$table='presence_cache';$columns='object_key,state,target,checked_at';$values=@([string]$r.Key,[string]$r.State,[string]$r.Target,[string]$r.At)}
      'UserScan' {$table='user_scan_history';$columns='login_key,login,scanned_at,scanned,candidates,reachable,probed,found';$values=@(([string]$r.Login).ToLowerInvariant(),[string]$r.Login,[string]$r.At,[int][bool]$r.Scanned,[int]$r.Candidates,[int]$r.Reachable,[int]$r.Probed,[string]$r.Found)}
      'Park' {$table='park_state';$columns='computer_key,computer,last_probe,status,user_login,attempts';$values=@([string]$r.Key,[string]$r.Computer,[string]$r.LastProbe,[string]$r.Status,[string]$r.User,[int]$r.Attempts)}
      'Sample' {$sampleCount++;$verb='INSERT';$table='operation_runs';$columns='operation,mode,item_count,duration_ms,bytes_estimated,ad_queries,remote_attempts,fallback_tasks,success_count,failure_count,started_at,finished_at,notes';$values=@([string]$r.Operation,[string]$r.Mode,[int]$r.ItemCount,[long]$r.DurationMs,[long]$r.BytesEstimated,[int]$r.AdQueries,[int]$r.RemoteAttempts,[int]$r.FallbackTasks,[int]$r.SuccessCount,[int]$r.FailureCount,[string]$r.StartedAt,[string]$r.Finished,'')}
    }
    [void](Invoke-DomeniaDbExec ($verb+' INTO '+$table+'('+$columns+') VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
  }elseif($i.Kind -eq 'IndexBulk'){
    # PF-07: storage time of the lot (validation, prepared inserts, reconciliation and COMMIT), returned to the
    # interface as an IndexStore sample beside the IndexBuild samples of the AD read.
    if($null -eq $indexWatch){$indexWatch=[Diagnostics.Stopwatch]::StartNew()}
    $bulk=$i.Row
    $reader=$null;$stream=$null;$hashAlgorithm=$null;$enumerator=$null;$readCount=0L;$identityCount=0L
    $transfer=$null;if($null -ne $bulk.PSObject.Properties['Transfer']){$transfer=$bulk.Transfer}
    $progress=$null;if($null -ne $transfer -and $null -ne $transfer.PSObject.Properties['Progress']){$progress=$transfer.Progress}
    if($null -ne $progress){$progress.Phase='Validation';$progress.Count=0L;$progress.Total=[long]$transfer.RowCount}
    try {
    # Scope membership uses RDN boundaries, including escaped commas/backslashes. SQL LIKE
    # would mistake a comma embedded in a name for a subtree boundary.
    function Get-IndexParentDn {
      param([string]$Dn)
      $escaped=$false
      for($n=0;$n -lt $Dn.Length;$n++){
        $ch=$Dn[$n]
        if($escaped){$escaped=$false;continue}
        if($ch -eq [char]92){$escaped=$true;continue}
        if($ch -eq ','){return $Dn.Substring($n+1).Trim()}
      }
      return ''
    }
    function Test-IndexDnInScope {
      param([string]$Dn,[string]$ScopeDn,[string]$SearchScope)
      if($SearchScope -eq 'OneLevel'){return (Get-IndexParentDn $Dn) -ieq $ScopeDn}
      $part=$Dn
      while($part){if($part -ieq $ScopeDn){return $true};$part=Get-IndexParentDn $part}
      return $false
    }
    $reconcile=$null;if($null -ne $bulk.PSObject.Properties['Reconcile']){$reconcile=$bulk.Reconcile}
    $syncScope='directory'
    if($null -ne $bulk.PSObject.Properties['SyncScope'] -and -not [string]::IsNullOrWhiteSpace([string]$bulk.SyncScope)){$syncScope=[string]$bulk.SyncScope}
    $isDirectoryScope=($syncScope -ceq 'directory')
    $complete=($null -eq $bulk.PSObject.Properties['Complete'] -or [bool]$bulk.Complete)
    $seenIdentities=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if($null -ne $reconcile){
      $started=[datetime]::MinValue
      if([string]$reconcile.Mode -notin @('Census','Rows') -or [string]$reconcile.SearchScope -notin @('Subtree','OneLevel') -or
         -not [string]$reconcile.ScopeDn -or [string]$reconcile.ScopeDn -ine [string]$bulk.BaseDn -or
         [string]$reconcile.Server -ine [string]$bulk.Server -or [string]$reconcile.InvocationId -ine [string]$bulk.InvocationId -or
         [bool]$reconcile.Complete -ne $complete -or [long]$reconcile.ExpectedCount -lt 0 -or
         -not [datetime]::TryParse([string]$reconcile.StartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$started)){
        throw 'Recu de reconciliation incoherent : transaction annulee.'
      }
      if(($bulk.ReplaceAll -and ($reconcile.Mode -ne 'Rows' -or $reconcile.SearchScope -ne 'Subtree')) -or ($reconcile.Mode -eq 'Census' -and (-not $isDirectoryScope -or $reconcile.SearchScope -ne 'Subtree' -or -not [string]$reconcile.InvocationId))){throw 'Perimetre du recensement invalide.'}
      if(-not $isDirectoryScope -and $syncScope -ine ('ou:'+([string]$reconcile.ScopeDn).ToLowerInvariant())){throw 'Couverture OU incoherente.'}
      [void](Invoke-DomeniaDbExec 'DROP TABLE IF EXISTS temp.index_seen; DROP TABLE IF EXISTS temp.index_batch; CREATE TEMP TABLE index_seen(guid TEXT PRIMARY KEY,dn TEXT NOT NULL); CREATE TEMP TABLE index_batch(object_key TEXT PRIMARY KEY);' $db)
    }
    if($null -ne $transfer){
      $folder=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$Payload.Path))) 'index-spool'))
      $file=[IO.Path]::GetFullPath([string]$transfer.Path)
      if([IO.Path]::GetDirectoryName($file) -cne $folder -or [IO.Path]::GetFileName($file) -notmatch '^[a-f0-9]{32}\.jsonl$'){throw 'Chemin du lot index non autorise.'}
      if(([IO.File]::GetAttributes($folder) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Lot index redirige : lecture refusee.'}
      if([string]$transfer.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$transfer.RowCount -lt 0){throw 'Recu du lot index invalide.'}
      $stream=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,65536)
      $hashAlgorithm=[Security.Cryptography.SHA256]::Create()
      $hash=[BitConverter]::ToString($hashAlgorithm.ComputeHash($stream)).Replace('-','')
      if($hash -ine [string]$transfer.Sha256){throw 'Lot index modifie depuis sa lecture : enregistrement refuse.'}
      $stream.Position=0;$reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true,65536)
    }else{
      if(@($bulk.Rows).Count -gt 5000000){throw 'Lot en memoire trop grand : utiliser le transfert sur disque.'}
      $records=@($bulk.Rows)
      if($null -ne $reconcile -and $reconcile.Mode -eq 'Census'){$records+=@($reconcile.Identities)}
      $enumerator=$records.GetEnumerator()
    }
    if($null -ne $progress){$progress.Phase='Enregistrement'}
    # PF-07: one prepared statement per table for the whole lot; the former text batches parsed every row again.
    $objectSql='INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17'
    $factSql='INSERT OR REPLACE INTO ad_computer_facts(object_guid,object_key,os_version,when_created,pwd_last_set,laps_kind,laps_expiry,read_at) SELECT ?1,?2,?3,?4,?5,?6,?7,?8'
    $seenStatement=$null;$batchStatement=$null;$cutoffText=''
    if($null -ne $reconcile){
      # A row made newer than this read (another console, a later single update) is never overwritten by the lot.
      $objectSql+=' WHERE ?1 IN (SELECT object_key FROM temp.index_batch)';$factSql+=' WHERE ?2 IN (SELECT object_key FROM temp.index_batch)'
      $cutoffText=$started.ToUniversalTime().ToString('o')
      $seenStatement=New-StoreWStatement $db 'INSERT INTO temp.index_seen(guid,dn) VALUES(?1,?2)'
      $batchStatement=New-StoreWStatement $db 'INSERT INTO temp.index_batch(object_key) SELECT ?1 WHERE NOT EXISTS(SELECT 1 FROM ad_objects WHERE object_key=?1 AND julianday(synced_at)>julianday(?2))'
    }
    $objectStatement=New-StoreWStatement $db $objectSql
    $factStatement=New-StoreWStatement $db $factSql

    # Computer facts read with the index (decision David 2026-10-08): emptied with it, refilled in this transaction.
    if($bulk.ReplaceAll -and (-not $complete -or -not $isDirectoryScope)){throw 'Reconstruction refusee : lecture complete du domaine requise.'}
    $previousSync=@()
    if($isDirectoryScope){$previousSync=@(Invoke-DomeniaDbQuery "SELECT COALESCE(last_sync,'') AS v FROM sync_state WHERE scope='directory';" $db)}
    if($bulk.ReplaceAll){
      # Modern full reads reconcile below as a transaction, preserving newer concurrent reads.
      # The legacy in-memory import has no snapshot receipt and keeps its explicit replacement.
      if($null -eq $reconcile){[void](Invoke-DomeniaDbExec 'DELETE FROM ad_objects;' $db);[void](Invoke-DomeniaDbExec 'DELETE FROM ad_computer_facts;' $db)}
      [void](Invoke-DomeniaDbExec "DELETE FROM sync_state WHERE scope LIKE 'ou:%' OR scope LIKE 'attempt:%';" $db)
    }
    while($true){
      if($null -ne $reader){
        $line=$reader.ReadLine();if($null -eq $line){break}
        if(-not $line -or $line.Length -gt 1048576){throw 'Enregistrement index invalide ou trop volumineux.'}
        $r=ConvertFrom-Json -InputObject $line -ErrorAction Stop
      }else{if(-not $enumerator.MoveNext()){break};$r=$enumerator.Current}
      $isIdentity=($null -ne $r -and $null -ne $r.PSObject.Properties['Kind'] -and [string]$r.Kind -ceq 'Identity')
      if($isIdentity -or $null -ne $reconcile){
        if($null -eq $reconcile -or ($isIdentity -and $reconcile.Mode -ne 'Census')){throw 'Identite de recensement inattendue.'}
        $guid=[guid]::Empty
        if(-not [guid]::TryParse([string]$r.Guid,[ref]$guid) -or $guid -eq [guid]::Empty -or
           -not (Test-IndexDnInScope ([string]$r.DN) ([string]$reconcile.ScopeDn) ([string]$reconcile.SearchScope))){throw 'GUID ou DN hors perimetre dans le lot de reconciliation.'}
        $r.Guid=$guid.ToString('D').ToLowerInvariant()
        if($isIdentity -or $reconcile.Mode -eq 'Rows'){
          if(-not $seenIdentities.Add([string]$r.Guid)){throw 'GUID duplique dans le recensement.'}
          Invoke-StoreWStatement $seenStatement @([string]$r.Guid,[string]$r.DN)
        }
        if($isIdentity){
          $identityCount++
          continue
        }
      }
      if($null -eq $r -or [string]$r.Type -notin @('Machine','Utilisateur') -or -not [string]$r.DN -or -not [string]$r.Name){throw 'Identite manquante dans un enregistrement index.'}
      $readCount++
      $key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=([string]$r.Type+'|'+[string]$r.DN).ToLowerInvariant()}
      if($null -ne $reconcile){Invoke-StoreWStatement $batchStatement @($key,$cutoffText)}
      $search=([string]$r.Name+' '+[string]$r.Login+' '+[string]$r.Upn+' '+[string]$r.Display+' '+[string]$r.Description+' '+[string]$r.Extra).ToLowerInvariant()
      $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,$search,[string]$bulk.Server,[string]$bulk.At)
      Invoke-StoreWStatement $objectStatement $values
      if([string]$r.Type -eq 'Machine' -and [string]$r.Guid -and $null -ne $r.PSObject.Properties['Facts'] -and [bool]$r.Facts){
        $facts=@(([string]$r.Guid).ToLowerInvariant(),$key,[string]$r.OsVersion,[string]$r.WhenCreated,[string]$r.PwdLastSet,[string]$r.LapsKind,[string]$r.LapsExpiry,[string]$bulk.At)
        Invoke-StoreWStatement $factStatement $facts
      }
      if((($readCount % 256) -eq 0) -and ($null -ne $progress)){$progress.Count=$readCount}
    }
    if($null -ne $transfer -and $readCount -ne [long]$transfer.RowCount){throw 'Nombre de lignes du lot index incoherent : transaction annulee.'}
    $indexRows+=$readCount
    if($null -ne $reconcile){
      $expected=if($reconcile.Mode -eq 'Census'){$identityCount}else{$readCount}
      if($expected -ne [long]$reconcile.ExpectedCount){throw 'Nombre d identites incoherent : transaction annulee.'}
      if($null -ne $transfer){
        $declared=0L;if($null -ne $transfer.PSObject.Properties['CensusRowCount']){$declared=[long]$transfer.CensusRowCount}
        if($declared -ne $identityCount){throw 'Nombre de marqueurs du lot incoherent : transaction annulee.'}
      }
      # Never infer deletion from an interrupted read, a limited result or an empty domain.
      # Newer concurrent local reads remain authoritative until the next reconciliation.
      if($complete){
        if($isDirectoryScope -and -not $bulk.ReplaceAll -and $expected -eq 0 -and [long](@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM ad_objects;' $db)[0].n) -gt 0){throw 'Recensement vide : reconstruction complete explicite requise.'}
        $cutoff=ConvertTo-DomeniaSqlLiteral ($started.ToUniversalTime().ToString('o'))
        $candidates=@(Invoke-DomeniaDbQuery ('SELECT a.object_key,a.object_guid,a.distinguished_name,s.dn AS current_dn FROM ad_objects a LEFT JOIN temp.index_seen s ON lower(a.object_guid)=s.guid WHERE COALESCE(a.synced_at,'''')='''' OR julianday(a.synced_at)<=julianday('+$cutoff+') OR a.object_key IN (SELECT object_key FROM temp.index_batch);') $db)
        $moveStatement=$null;$dropFactStatement=$null;$dropObjectStatement=$null
        foreach($candidate in $candidates){
          $candidateKey=[string]$candidate.object_key
          if([string]$candidate.current_dn){
            if(($reconcile.Mode -eq 'Census') -and ([string]$candidate.distinguished_name -ine [string]$candidate.current_dn)){
              if($null -eq $moveStatement){$moveStatement=New-StoreWStatement $db 'UPDATE ad_objects SET distinguished_name=?1 WHERE object_key=?2'}
              Invoke-StoreWStatement $moveStatement @([string]$candidate.current_dn,$candidateKey)
            }
          }elseif(Test-IndexDnInScope ([string]$candidate.distinguished_name) ([string]$reconcile.ScopeDn) ([string]$reconcile.SearchScope)){
            if($null -eq $dropObjectStatement){$dropFactStatement=New-StoreWStatement $db 'DELETE FROM ad_computer_facts WHERE object_key=?1';$dropObjectStatement=New-StoreWStatement $db 'DELETE FROM ad_objects WHERE object_key=?1'}
            Invoke-StoreWStatement $dropFactStatement @($candidateKey)
            Invoke-StoreWStatement $dropObjectStatement @($candidateKey)
          }
        }
      }
    }elseif($null -ne $transfer -and $null -ne $transfer.PSObject.Properties['CensusRowCount'] -and [long]$transfer.CensusRowCount -ne 0){throw 'Recensement sans perimetre : transaction annulee.'}
    # Only a complete domain delta can certify unchanged facts. An OU or interrupted pass cannot do so.
    if(-not $bulk.ReplaceAll -and $complete -and $isDirectoryScope -and $previousSync.Count -and [string]$previousSync[0].v){[void](Invoke-DomeniaDbExec ('UPDATE ad_computer_facts SET read_at='+(ConvertTo-DomeniaSqlLiteral ([string]$bulk.At))+' WHERE COALESCE(read_at,'''')>='+(ConvertTo-DomeniaSqlLiteral ([string]$previousSync[0].v))+' AND julianday(read_at)<=julianday('+(ConvertTo-DomeniaSqlLiteral ([string]$bulk.At))+');') $db)}
    $total=[long](@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM ad_objects;' $db)[0].n)
    $details='async'
    if (-not [string]::IsNullOrWhiteSpace([string]$bulk.InvocationId)) { $details='inv='+[string]$bulk.InvocationId }
    # Search depth belongs to the committed checkpoint. A direct-children walk must not overwrite a Subtree success.
    $depth=if($null -ne $reconcile){[string]$reconcile.SearchScope}elseif($isDirectoryScope){'Subtree'}else{'Unknown'}
    $details+=';depth='+$depth
    $checkpointScope=if(-not $isDirectoryScope -and $depth -eq 'OneLevel'){'ou:onelevel:'+([string]$bulk.BaseDn).ToLowerInvariant()}else{$syncScope}
    # Attempts are separate from successful coverage and its checkpoint. A failed attempt never rejuvenates it.
    $attemptDetails=$(if($complete){'complete'}else{'partial'})+';depth='+$depth
    $attempt=@(('attempt:'+$checkpointScope),[string]$bulk.Server,[string]$bulk.BaseDn,[long]0,[string]$bulk.At,$readCount,$attemptDetails)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($attempt|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    if(-not $complete){continue}
    $scopeCount=if($isDirectoryScope){$total}else{$readCount}
    $values=@($checkpointScope,[string]$bulk.Server,[string]$bulk.BaseDn,[long]$bulk.HighestUsn,[string]$bulk.At,$scopeCount,$details)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    } finally {
      if($null -ne $progress){$progress.Count=$readCount;$progress.Phase='Attente'}
      if($null -ne $reader){$reader.Dispose()}elseif($null -ne $stream){$stream.Dispose()}
      if($null -ne $hashAlgorithm){$hashAlgorithm.Dispose()}
    }
  }else{throw 'Type stockage non autorise.'}
 }
 # PF-26: the bounded history of measures is trimmed only after a sample was inserted, and only past 11 000 rows,
 # down to the newest 10 000: one count per batch of samples instead of a DELETE scan at every COMMIT.
 if($sampleCount -gt 0){
  $runs=[long](@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM operation_runs;' $db)[0].n)
  if($runs -gt 11000){[void](Invoke-DomeniaDbExec 'DELETE FROM operation_runs WHERE id<(SELECT min(id) FROM (SELECT id FROM operation_runs ORDER BY id DESC LIMIT 10000));' $db)}
 }
 # User request 2026-10-04: association history is retained; only explicit History purge removes it.
 Close-StoreWStatements
 [void](Invoke-DomeniaDbExec 'UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;COMMIT;' $db);$transaction=$false
 $indexWriteMs=0L;if($null -ne $indexWatch){$indexWatch.Stop();$indexWriteMs=[long]$indexWatch.ElapsedMilliseconds}
 [pscustomobject]@{Saved=$true;Conflicts=$conflicts.ToArray();Count=@($Payload.Items).Count;Already=0;Imported=0;ImportedLinks=@();IndexRows=[long]$indexRows;IndexWriteMs=$indexWriteMs}
} finally {Close-StoreWStatements;if($transaction){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}};if($db -ne [IntPtr]::Zero){Close-DomeniaDatabase $db}}
'@
    return (Get-DomeniaStorageLeaseWorkerCode) + [Environment]::NewLine + $script:DomeniaStoreQueryValidationCode + [Environment]::NewLine + $body
}

function Get-DomeniaStorageUsageWorkerCode {
$body=@'
function Initialize-DomeniaWinSqliteNative { return [Domenia.WinSqliteNative] }
function New-DomeniaUtf8Ptr {
    param([AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$Text) + [char]0)
    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
    return $ptr
}
function ConvertFrom-DomeniaUtf8Ptr {
    param([IntPtr]$Pointer,[int]$Length = -1)
    if ($Pointer -eq [IntPtr]::Zero) { return "" }
    if ($Length -lt 0) {
        $Length = 0
        while ([System.Runtime.InteropServices.Marshal]::ReadByte($Pointer,$Length) -ne 0) { $Length++ }
    }
    if ($Length -le 0) { return "" }
    $bytes = New-Object byte[] $Length
    [System.Runtime.InteropServices.Marshal]::Copy($Pointer,$bytes,0,$Length)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}
function Close-DomeniaDatabase {
    param([IntPtr]$DatabaseHandle)
    if($DatabaseHandle -eq [IntPtr]::Zero){return}
    Initialize-DomeniaWinSqliteNative | Out-Null
    $closed=[Domenia.WinSqliteNative]::sqlite3_close($DatabaseHandle)
    if($closed -ne 0){throw ('Fermeture SQLite non confirmee (code '+$closed+'). Le verrou est conserve.')}
    if($null -ne $script:StoreWHandleLeases -and $script:StoreWHandleLeases.ContainsKey($DatabaseHandle.ToInt64())){$lease=$script:StoreWHandleLeases[$DatabaseHandle.ToInt64()];$script:StoreWHandleLeases.Remove($DatabaseHandle.ToInt64());Exit-StoreWDatabaseLease $lease}
}
function ConvertTo-DomeniaSqlLiteral {
    param($Value)
    if ($null -eq $Value) { return "NULL" }
    if ($Value -is [bool]) { return $(if ($Value) { "1" } else { "0" }) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) { return ([Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)) }
    return "'" + (([string]$Value) -replace "'","''") + "'"
}
function Open-DomeniaDatabase {
    param([string]$Path = '',[switch]$ReadOnly)
    $native = Initialize-DomeniaWinSqliteNative
    $db = [IntPtr]::Zero
    $pathPtr = [IntPtr]::Zero;$writeLease=$null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-DomeniaDatabasePath }
        if(-not $ReadOnly){$writeLease=Enter-StoreWDatabaseLease -Path $Path}
        $pathPtr = New-DomeniaUtf8Ptr $Path
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 4 -bor 65536 }
        $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,$flags,[IntPtr]::Zero)
        if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw "Ouverture SQLite impossible (code $rc)." }
        # FI-12: lock wait from the worker context (LocalStore.DatabaseBusyTimeoutMs), 2 500 ms without one.
        $busyMs=2500;$workerContext=Get-Variable -Name Context -ValueOnly -ErrorAction SilentlyContinue
        if(($null -ne $workerContext) -and ($null -ne $workerContext.PSObject.Properties['BusyTimeoutMs'])){$busyMs=[Math]::Max(100,[Math]::Min(5000,[int]$workerContext.BusyTimeoutMs))}
        [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
        if(-not $ReadOnly){Assert-StoreWDatabaseWritable $db;if($null -eq $script:StoreWHandleLeases){$script:StoreWHandleLeases=@{}};$script:StoreWHandleLeases[$db.ToInt64()]=$writeLease;$writeLease=$null}
        return $db
    }
    catch {
        # sqlite3_open_v2 can return a non-null handle even on failure.
        if ($db -ne [IntPtr]::Zero) { [void][Domenia.WinSqliteNative]::sqlite3_close($db) }
        if($null -ne $writeLease){Exit-StoreWDatabaseLease $writeLease}
        throw
    }
    finally { if ($pathPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) } }
}
function Invoke-DomeniaDbExec {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $errPtr = [IntPtr]::Zero
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_exec($DatabaseHandle,$sqlPtr,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$errPtr)
        if ($rc -ne 0) {
            $msg = if ($errPtr -ne [IntPtr]::Zero) { ConvertFrom-DomeniaUtf8Ptr $errPtr } else { ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)) }
            throw "SQLite code $rc : $msg"
        }
        return $true
    }
    finally {
        if ($errPtr -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [Domenia.WinSqliteNative]::sqlite3_free($errPtr) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}
function Invoke-DomeniaDbQuery {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $stmt = [IntPtr]::Zero
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_prepare_v2($DatabaseHandle,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if ($rc -ne 0) { throw "SQLite prepare code $rc : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        $count = [Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
        while (($step = [Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100) {
            $o = [ordered]@{}
            for ($i=0;$i -lt $count;$i++) {
                $name = ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i))
                $type = [Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$i)
                $value = $null
                switch ($type) {
                    1 { $value = [long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$i) }
                    2 { $value = [double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$i) }
                    3 { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                    5 { $value = $null }
                    default { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                }
                $o[$name] = $value
            }
            $rows.Add([pscustomobject]$o)
        }
        if ($step -ne 101) { throw "SQLite step code $step : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        return $rows.ToArray()
    }
    finally {
        if ($stmt -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}

function Get-DomeniaDatabasePath {throw 'Chemin de base explicite requis pour la mesure.'}
function Test-DomeniaStorageMeasurePath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)){throw 'Chemin de base local absolu requis.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\') -or ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))).DriveType -eq [IO.DriveType]::Network){throw 'Mesure refusee sur une base reseau.'}
    $file=[IO.FileInfo]::new($full)
    if(-not $file.Exists){throw 'Base locale absente ; aucune base ne sera creee.'}
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Lien de base refuse.'}
    $dir=$file.Directory
    while($null -ne $dir){if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier de base redirige refuse.'};$dir=$dir.Parent}
    foreach($suffix in @('-wal','-shm')){
        $sidecar=[IO.FileInfo]::new($full+$suffix)
        if($sidecar.Exists -and ($sidecar.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Annexe SQLite redirigee refusee.'}
    }
    return $full
}
function Get-DomeniaMeasuredFileSize {
    param([string]$Path)
    try {return [long]([IO.FileInfo]::new($Path)).Length}
    catch [IO.FileNotFoundException] {return 0L}
    catch [IO.DirectoryNotFoundException] {return 0L}
    catch {return -1L}
}
$path=Test-DomeniaStorageMeasurePath ([string]$Payload.Path)
$db=[IntPtr]::Zero
$watch=[Diagnostics.Stopwatch]::StartNew()
try {
    $db=Open-DomeniaDatabase -Path $path -ReadOnly
    [void](Invoke-DomeniaDbExec 'BEGIN;' $db)
    $schema=@(Invoke-DomeniaDbQuery "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');" $db)
    $baseVersion=@($schema|Where-Object{$_.key -eq 'schema_version'});$localVersion=@($schema|Where-Object{$_.key -eq 'domenia_schema'})
    if($baseVersion.Count -ne 1 -or [string]$baseVersion[0].value -cne '11' -or $localVersion.Count -ne 1 -or [string]$localVersion[0].value -cne '1'){throw 'Schema local non pris en charge pour la mesure (11/1 requis).'}
    # Every identifier is constant. The payload contributes no table, category, SQL or size estimate.
    $categories=[ordered]@{
        Observations=@('adcc_live_observations','presence_cache','park_state','park_session_cache','domenia_observations','domenia_details')
        Snapshots=@('adcc_live_queries')
        History=@('user_machine_history','user_scan_history','operation_runs','fleet_snapshots')
        Index=@('ad_objects','domenia_provenance','sync_state','ad_computer_facts','domenia_directory_data')
        ManualLinks=@('user_machine_links')
        Secrets=@('secret_state')
    }
    $objects=@(Invoke-DomeniaDbQuery "SELECT name,tbl_name,type FROM sqlite_master WHERE type IN ('table','index');" $db)
    $existing=@{};foreach($object in $objects){if($object.type -eq 'table'){$existing[[string]$object.name]=$true}}
    $pages=[long](@(Invoke-DomeniaDbQuery 'PRAGMA page_count;' $db)[0].page_count)
    $pageSize=[long](@(Invoke-DomeniaDbQuery 'PRAGMA page_size;' $db)[0].page_size)
    $freePages=[long](@(Invoke-DomeniaDbQuery 'PRAGMA freelist_count;' $db)[0].freelist_count)
    $dbstat=$false;$objectBytes=@{}
    try {
        $stats=@(Invoke-DomeniaDbQuery 'SELECT name,sum(pgsize) AS bytes FROM dbstat GROUP BY name;' $db)
        foreach($entry in $stats){$objectBytes[[string]$entry.name]=[long]$entry.bytes}
        $dbstat=$true
    } catch {
        # An unavailable optional module is not an estimated distribution of database bytes.
        if($_.Exception.Message -notmatch '(?i)no such (table|module).*dbstat'){throw}
    }
    $usage=New-Object 'System.Collections.Generic.List[object]'
    foreach($category in $categories.Keys){
        $tables=New-Object 'System.Collections.Generic.List[object]';$totalRows=0L;$totalBytes=0L
        foreach($table in $categories[$category]){
            $rows=-1L;$bytes=-1L;$state='Absent'
            if($table -in @('park_session_cache','ad_computer_facts','fleet_snapshots','domenia_observations','domenia_details','domenia_directory_data') -and -not $existing.ContainsKey($table)){$rows=0L;$bytes=0L}
            if($existing.ContainsKey($table)){
                $rows=[long](@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM '+$table+';') $db)[0].n)
                $state='Mesure'
                if($dbstat){
                    $bytes=0L
                    foreach($object in @($objects|Where-Object{$_.tbl_name -eq $table})){
                        if($objectBytes.ContainsKey([string]$object.name)){$bytes+=[long]$objectBytes[[string]$object.name]}
                    }
                }
            }
            if($rows -lt 0){$totalRows=-1L}elseif($totalRows -ge 0){$totalRows+=$rows}
            if($bytes -lt 0){$totalBytes=-1L}elseif($totalBytes -ge 0){$totalBytes+=$bytes}
            $tables.Add([pscustomobject]@{Table=$table;Rows=$rows;Bytes=$bytes;State=$state})
        }
        $usage.Add([pscustomobject]@{Category=[string]$category;Rows=$totalRows;Bytes=$totalBytes;Tables=$tables.ToArray()})
    }
    $receiptCount=0L;$compactedCount=0L
    if($existing.ContainsKey('domenia_store_batches')){
        $receiptStats=@(Invoke-DomeniaDbQuery "SELECT count(*) AS n,COALESCE(sum(CASE WHEN changes_json='[]' THEN 1 ELSE 0 END),0) AS compacted FROM domenia_store_batches;" $db)[0]
        $receiptCount=[long]$receiptStats.n;$compactedCount=[long]$receiptStats.compacted
    }
    $diskFreeBytes=-1L;try{$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($path));if($drive.IsReady){$diskFreeBytes=[long]$drive.AvailableFreeSpace}}catch{}
    [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
    return [pscustomobject]@{
        Kind='StorageUsage';Path=$path;MeasuredUtc=[datetime]::UtcNow.ToString('o');DurationMs=$watch.ElapsedMilliseconds
        DatabaseBytes=(Get-DomeniaMeasuredFileSize $path);WalBytes=(Get-DomeniaMeasuredFileSize ($path+'-wal'))
        PageSize=$pageSize;PageCount=$pages;FreePages=$freePages;ReusableBytes=($pageSize*$freePages)
        DbstatAvailable=$dbstat;Categories=$usage.ToArray();ReadOnly=$true
        DiskFreeBytes=$diskFreeBytes;ReceiptCount=$receiptCount;CompactedReceiptCount=$compactedCount
    }
} finally {if($db -ne [IntPtr]::Zero){Close-DomeniaDatabase $db};$watch.Stop()}

'@
    return (Get-DomeniaStorageLeaseWorkerCode) + [Environment]::NewLine + $body
}

function Get-DomeniaStoragePurgeWorkerCode {
$body=@'
function Initialize-DomeniaWinSqliteNative { return [Domenia.WinSqliteNative] }
function New-DomeniaUtf8Ptr {
    param([AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$Text) + [char]0)
    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
    return $ptr
}
function ConvertFrom-DomeniaUtf8Ptr {
    param([IntPtr]$Pointer,[int]$Length = -1)
    if ($Pointer -eq [IntPtr]::Zero) { return "" }
    if ($Length -lt 0) {
        $Length = 0
        while ([System.Runtime.InteropServices.Marshal]::ReadByte($Pointer,$Length) -ne 0) { $Length++ }
    }
    if ($Length -le 0) { return "" }
    $bytes = New-Object byte[] $Length
    [System.Runtime.InteropServices.Marshal]::Copy($Pointer,$bytes,0,$Length)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}
function Close-DomeniaDatabase {
    param([IntPtr]$DatabaseHandle)
    if($DatabaseHandle -eq [IntPtr]::Zero){return}
    Initialize-DomeniaWinSqliteNative | Out-Null
    $closed=[Domenia.WinSqliteNative]::sqlite3_close($DatabaseHandle)
    if($closed -ne 0){throw ('Fermeture SQLite non confirmee (code '+$closed+'). Le verrou est conserve.')}
    if($null -ne $script:StoreWHandleLeases -and $script:StoreWHandleLeases.ContainsKey($DatabaseHandle.ToInt64())){$lease=$script:StoreWHandleLeases[$DatabaseHandle.ToInt64()];$script:StoreWHandleLeases.Remove($DatabaseHandle.ToInt64());Exit-StoreWDatabaseLease $lease}
}
function ConvertTo-DomeniaSqlLiteral {
    param($Value)
    if ($null -eq $Value) { return "NULL" }
    if ($Value -is [bool]) { return $(if ($Value) { "1" } else { "0" }) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) { return ([Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)) }
    return "'" + (([string]$Value) -replace "'","''") + "'"
}
function Open-DomeniaDatabase {
    param([string]$Path = '',[switch]$ReadOnly)
    $native = Initialize-DomeniaWinSqliteNative
    $db = [IntPtr]::Zero
    $pathPtr = [IntPtr]::Zero;$writeLease=$null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-DomeniaDatabasePath }
        if(-not $ReadOnly){$writeLease=Enter-StoreWDatabaseLease -Path $Path}
        $pathPtr = New-DomeniaUtf8Ptr $Path
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 65536 }
        $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,$flags,[IntPtr]::Zero)
        if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw "Ouverture SQLite impossible (code $rc)." }
        # FI-12: lock wait from the worker context (LocalStore.DatabaseBusyTimeoutMs), 2 500 ms without one.
        $busyMs=2500;$workerContext=Get-Variable -Name Context -ValueOnly -ErrorAction SilentlyContinue
        if(($null -ne $workerContext) -and ($null -ne $workerContext.PSObject.Properties['BusyTimeoutMs'])){$busyMs=[Math]::Max(100,[Math]::Min(5000,[int]$workerContext.BusyTimeoutMs))}
        [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
        if(-not $ReadOnly){Assert-StoreWDatabaseWritable $db;if($null -eq $script:StoreWHandleLeases){$script:StoreWHandleLeases=@{}};$script:StoreWHandleLeases[$db.ToInt64()]=$writeLease;$writeLease=$null}
        return $db
    }
    catch {
        # sqlite3_open_v2 can return a non-null handle even on failure.
        if ($db -ne [IntPtr]::Zero) { [void][Domenia.WinSqliteNative]::sqlite3_close($db) }
        if($null -ne $writeLease){Exit-StoreWDatabaseLease $writeLease}
        throw
    }
    finally { if ($pathPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) } }
}
function Invoke-DomeniaDbExec {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $errPtr = [IntPtr]::Zero
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_exec($DatabaseHandle,$sqlPtr,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$errPtr)
        if ($rc -ne 0) {
            $msg = if ($errPtr -ne [IntPtr]::Zero) { ConvertFrom-DomeniaUtf8Ptr $errPtr } else { ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)) }
            throw "SQLite code $rc : $msg"
        }
        return $true
    }
    finally {
        if ($errPtr -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [Domenia.WinSqliteNative]::sqlite3_free($errPtr) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}
function Invoke-DomeniaDbQuery {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $stmt = [IntPtr]::Zero
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_prepare_v2($DatabaseHandle,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if ($rc -ne 0) { throw "SQLite prepare code $rc : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        $count = [Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
        while (($step = [Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100) {
            $o = [ordered]@{}
            for ($i=0;$i -lt $count;$i++) {
                $name = ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i))
                $type = [Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$i)
                $value = $null
                switch ($type) {
                    1 { $value = [long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$i) }
                    2 { $value = [double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$i) }
                    3 { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                    5 { $value = $null }
                    default { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                }
                $o[$name] = $value
            }
            $rows.Add([pscustomobject]$o)
        }
        if ($step -ne 101) { throw "SQLite step code $step : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        return $rows.ToArray()
    }
    finally {
        if ($stmt -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}

function Get-DomeniaDatabasePath {throw 'Chemin de base explicite requis pour la purge.'}
function Test-DomeniaStoragePurgePath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)){throw 'Chemin de base local absolu requis.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\') -or ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))).DriveType -eq [IO.DriveType]::Network){throw 'Purge refusee sur une base reseau.'}
    $file=[IO.FileInfo]::new($full)
    if(-not $file.Exists){throw 'Base locale absente ; aucune base ne sera creee.'}
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Lien de base refuse.'}
    $dir=$file.Directory
    while($null -ne $dir){if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier de base redirige refuse.'};$dir=$dir.Parent}
    foreach($suffix in @('-wal','-shm')){
        $sidecar=[IO.FileInfo]::new($full+$suffix)
        if($sidecar.Exists -and ($sidecar.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Annexe SQLite redirigee refusee.'}
    }
    return $full
}

# Validate all input before opening the existing database. No payload identifier becomes SQL.
if($Payload.DryRun -isnot [bool]){throw 'Mode de simulation explicite requis.'}
$dryRun=[bool]$Payload.DryRun
$selection=New-Object 'System.Collections.Generic.List[string]';$seen=@{}
foreach($value in @($Payload.Selection)){
    $value=([string]$value).Trim()
    $canonical=switch($value){Observations{'Observations'}Snapshots{'Snapshots'}History{'History'}Index{'Index'}default{throw ('Categorie non purgeable : '+$value)}}
    if(-not $seen.ContainsKey($canonical)){$selection.Add($canonical);$seen[$canonical]=$true}
}
if($selection.Count -eq 0){throw 'Choisissez au moins une categorie purgeable.'}
$cutoff=''
if($seen.ContainsKey('History')){
    $date=[datetime]::MinValue
    if(-not [datetime]::TryParseExact([string]$Payload.HistoryCutoffUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$date) -or $date.Kind -ne [DateTimeKind]::Utc -or $date -ge [datetime]::UtcNow){throw 'Date limite UTC de l historique invalide.'}
    $cutoff=$date.ToString('o')
}
if(-not $dryRun -and [string]$Payload.ExpectedFingerprint -notmatch '^[A-F0-9]{64}$'){throw 'Simulation confirmee requise avant purge.'}
$path=Test-DomeniaStoragePurgePath ([string]$Payload.Path)
$db=[IntPtr]::Zero;$transaction=$false
$watch=[Diagnostics.Stopwatch]::StartNew()
try {
    $db=Open-DomeniaDatabase -Path $path
    [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db);$transaction=$true
    $schema=@(Invoke-DomeniaDbQuery "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');" $db)
    $base=@($schema|Where-Object{$_.key -eq 'schema_version'});$revision=@($schema|Where-Object{$_.key -eq 'domenia_schema'})
    if($base.Count -ne 1 -or [string]$base[0].value -cne '11' -or $revision.Count -ne 1 -or [string]$revision[0].value -cne '1'){throw 'Schema local non pris en charge pour la purge (11/1 requis).'}
    if(@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='trigger';" $db).Count){throw 'Purge refusee : declencheur SQLite non pris en charge.'}
    $tables=@{};foreach($row in @(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table';" $db)){$tables[[string]$row.name]=$true}
    $targets=New-Object 'System.Collections.Generic.List[object]'
    foreach($category in @($selection|Sort-Object)){
        switch($category){
            Observations {
                foreach($table in @('adcc_live_observations','presence_cache','park_state','park_session_cache','domenia_observations','domenia_details')){$targets.Add([pscustomobject]@{Category=$category;Table=$table;Action='Delete';Where='1=1'})}
                # Scope clocks of the ping and WMI campaigns go with the measures they dated.
                $targets.Add([pscustomobject]@{Category=$category;Table='domenia_domain_metadata';Action='Delete';Where="family IN ('Presence','Inventory')"})
            }
            Snapshots {$targets.Add([pscustomobject]@{Category=$category;Table='adcc_live_queries';Action='Delete';Where='1=1'})}
            History {
                $literal=ConvertTo-DomeniaSqlLiteral $cutoff
                # Same list as Get-DomeniaProtectedAssociationSources (Cache.Model), lower case; a rules test keeps them equal.
                $sources="('manual','saisie manuelle','import csv','import glpi','import osquery')"
                $protect="lower(trim(COALESCE(source,''))) NOT IN $sources AND lower(trim(COALESCE(computer_key,''))) NOT IN (SELECT lower(trim(COALESCE(computer_key,''))) FROM user_machine_links WHERE lower(trim(COALESCE(source,''))) IN $sources)"
                $targets.Add([pscustomobject]@{Category=$category;Table='user_machine_history';Action='Delete';Where=("julianday(observed_at) IS NOT NULL AND julianday(observed_at)<julianday($literal) AND $protect")})
                $targets.Add([pscustomobject]@{Category=$category;Table='user_scan_history';Action='Delete';Where=("julianday(scanned_at) IS NOT NULL AND julianday(scanned_at)<julianday($literal)")})
                $targets.Add([pscustomobject]@{Category=$category;Table='operation_runs';Action='Delete';Where=("julianday(finished_at) IS NOT NULL AND julianday(finished_at)<julianday($literal)")})
                $targets.Add([pscustomobject]@{Category=$category;Table='fleet_snapshots';Action='Delete';Where=("julianday(snapshot_day) IS NOT NULL AND julianday(snapshot_day)<julianday($literal)")})
            }
            Index {
                foreach($table in @('ad_objects','domenia_provenance','ad_computer_facts','domenia_directory_data')){$targets.Add([pscustomobject]@{Category=$category;Table=$table;Action='Delete';Where='1=1'})}
                # The scope clock of the AD reads goes with the index it dated.
                $targets.Add([pscustomobject]@{Category=$category;Table='domenia_domain_metadata';Action='Delete';Where="family='Directory'"})
                $targets.Add([pscustomobject]@{Category=$category;Table='sync_state';Action='Reset';Where="scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%'"})
            }
        }
    }
    $counts=New-Object 'System.Collections.Generic.List[object]'
    foreach($target in $targets){
        $n=0L;$exists=$tables.ContainsKey($target.Table)
        if($exists){$n=[long](@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM '+$target.Table+' WHERE '+$target.Where+';') $db)[0].n)}
        elseif($target.Table -notin @('adcc_live_observations','adcc_live_queries','park_session_cache','ad_computer_facts','fleet_snapshots','domenia_observations','domenia_details','domenia_directory_data','domenia_domain_metadata')){throw ('Table locale requise absente : '+$target.Table)}
        $counts.Add([pscustomobject]@{Category=$target.Category;Table=$target.Table;Action=$target.Action;Rows=$n;Exists=$exists})
    }
    # Bind confirmation to the categories, fixed cutoff, path and freshly recounted rows.
    $storeRevision=0L;if($tables.ContainsKey('domenia_store_state')){$state=@(Invoke-DomeniaDbQuery 'SELECT revision FROM domenia_store_state WHERE id=1;' $db);if($state.Count){$storeRevision=[long]$state[0].revision}}
    $basis=[ordered]@{Path=$path.ToUpperInvariant();Selection=@($selection|Sort-Object);HistoryCutoffUtc=$cutoff;Counts=$counts.ToArray();StoreRevision=$storeRevision}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$fingerprint=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($basis|ConvertTo-Json -Depth 5 -Compress)))).Replace('-','')}finally{$sha.Dispose()}
    if(-not $dryRun -and $fingerprint -cne [string]$Payload.ExpectedFingerprint){throw 'Le nombre de lignes ou le contexte a change. Refaites la simulation avant toute purge.'}
    $deleted=0L;$reset=0L
    if(-not $dryRun){
        foreach($target in $targets){
            if(-not $tables.ContainsKey($target.Table)){continue}
            if($target.Action -eq 'Reset'){
                [void](Invoke-DomeniaDbExec ("UPDATE sync_state SET highest_usn=0,last_sync=NULL,item_count=0,details=NULL WHERE "+$target.Where+';') $db)
                $reset+=[long](@(Invoke-DomeniaDbQuery 'SELECT changes() AS n;' $db)[0].n)
            }else{
                [void](Invoke-DomeniaDbExec ('DELETE FROM '+$target.Table+' WHERE '+$target.Where+';') $db)
                $deleted+=[long](@(Invoke-DomeniaDbQuery 'SELECT changes() AS n;' $db)[0].n)
            }
        }
        if($tables.ContainsKey('domenia_store_state')){[void](Invoke-DomeniaDbExec 'UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;' $db)}
        [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
    }else{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}
    $transaction=$false
    return [pscustomobject]@{Kind='StoragePurge';Path=$path;DryRun=$dryRun;Committed=(-not $dryRun);Selection=@($selection|Sort-Object);HistoryCutoffUtc=$cutoff;Fingerprint=$fingerprint;Counts=$counts.ToArray();DeletedRows=$deleted;ResetRows=$reset;DurationMs=$watch.ElapsedMilliseconds}
}finally{
    if($db -ne [IntPtr]::Zero){if($transaction){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}};Close-DomeniaDatabase $db}
    $watch.Stop()
}

'@
    return (Get-DomeniaStorageLeaseWorkerCode) + [Environment]::NewLine + $body
}
function Get-DomeniaStorageBackupWorkerCode {
$body=@'
function Initialize-DomeniaWinSqliteNative { return [Domenia.WinSqliteNative] }
function New-DomeniaUtf8Ptr {
    param([AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$Text) + [char]0)
    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes,0,$ptr,$bytes.Length)
    return $ptr
}
function ConvertFrom-DomeniaUtf8Ptr {
    param([IntPtr]$Pointer,[int]$Length = -1)
    if ($Pointer -eq [IntPtr]::Zero) { return "" }
    if ($Length -lt 0) {
        $Length = 0
        while ([System.Runtime.InteropServices.Marshal]::ReadByte($Pointer,$Length) -ne 0) { $Length++ }
    }
    if ($Length -le 0) { return "" }
    $bytes = New-Object byte[] $Length
    [System.Runtime.InteropServices.Marshal]::Copy($Pointer,$bytes,0,$Length)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}
function Close-DomeniaDatabase {
    param([IntPtr]$DatabaseHandle)
    if($DatabaseHandle -eq [IntPtr]::Zero){return}
    Initialize-DomeniaWinSqliteNative | Out-Null
    $closed=[Domenia.WinSqliteNative]::sqlite3_close($DatabaseHandle)
    if($closed -ne 0){throw ('Fermeture SQLite non confirmee (code '+$closed+'). Le verrou est conserve.')}
    if($null -ne $script:StoreWHandleLeases -and $script:StoreWHandleLeases.ContainsKey($DatabaseHandle.ToInt64())){$lease=$script:StoreWHandleLeases[$DatabaseHandle.ToInt64()];$script:StoreWHandleLeases.Remove($DatabaseHandle.ToInt64());Exit-StoreWDatabaseLease $lease}
}
function ConvertTo-DomeniaSqlLiteral {
    param($Value)
    if ($null -eq $Value) { return "NULL" }
    if ($Value -is [bool]) { return $(if ($Value) { "1" } else { "0" }) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) { return ([Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)) }
    return "'" + (([string]$Value) -replace "'","''") + "'"
}
function Open-DomeniaDatabase {
    param([string]$Path = '',[switch]$ReadOnly)
    $native = Initialize-DomeniaWinSqliteNative
    $db = [IntPtr]::Zero
    $pathPtr = [IntPtr]::Zero;$writeLease=$null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-DomeniaDatabasePath }
        if(-not $ReadOnly){$writeLease=Enter-StoreWDatabaseLease -Path $Path}
        $pathPtr = New-DomeniaUtf8Ptr $Path
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 4 -bor 65536 }
        $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,$flags,[IntPtr]::Zero)
        if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw "Ouverture SQLite impossible (code $rc)." }
        # FI-12: lock wait from the worker context (LocalStore.DatabaseBusyTimeoutMs), 2 500 ms without one.
        $busyMs=2500;$workerContext=Get-Variable -Name Context -ValueOnly -ErrorAction SilentlyContinue
        if(($null -ne $workerContext) -and ($null -ne $workerContext.PSObject.Properties['BusyTimeoutMs'])){$busyMs=[Math]::Max(100,[Math]::Min(5000,[int]$workerContext.BusyTimeoutMs))}
        [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
        if(-not $ReadOnly){Assert-StoreWDatabaseWritable $db;if($null -eq $script:StoreWHandleLeases){$script:StoreWHandleLeases=@{}};$script:StoreWHandleLeases[$db.ToInt64()]=$writeLease;$writeLease=$null}
        return $db
    }
    catch {
        # sqlite3_open_v2 can return a non-null handle even on failure.
        if ($db -ne [IntPtr]::Zero) { [void][Domenia.WinSqliteNative]::sqlite3_close($db) }
        if($null -ne $writeLease){Exit-StoreWDatabaseLease $writeLease}
        throw
    }
    finally { if ($pathPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) } }
}
function Invoke-DomeniaDbExec {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $errPtr = [IntPtr]::Zero
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_exec($DatabaseHandle,$sqlPtr,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$errPtr)
        if ($rc -ne 0) {
            $msg = if ($errPtr -ne [IntPtr]::Zero) { ConvertFrom-DomeniaUtf8Ptr $errPtr } else { ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)) }
            throw "SQLite code $rc : $msg"
        }
        return $true
    }
    finally {
        if ($errPtr -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [Domenia.WinSqliteNative]::sqlite3_free($errPtr) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}
function Invoke-DomeniaDbQuery {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Sql,[IntPtr]$DatabaseHandle = [IntPtr]::Zero)
    $own = ($DatabaseHandle -eq [IntPtr]::Zero)
    $sqlPtr = [IntPtr]::Zero
    $stmt = [IntPtr]::Zero
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        if ($own) { $DatabaseHandle = Open-DomeniaDatabase }
        $native = Initialize-DomeniaWinSqliteNative
        $sqlPtr = New-DomeniaUtf8Ptr $Sql
        $rc = [Domenia.WinSqliteNative]::sqlite3_prepare_v2($DatabaseHandle,$sqlPtr,-1,[ref]$stmt,[IntPtr]::Zero)
        if ($rc -ne 0) { throw "SQLite prepare code $rc : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        $count = [Domenia.WinSqliteNative]::sqlite3_column_count($stmt)
        while (($step = [Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100) {
            $o = [ordered]@{}
            for ($i=0;$i -lt $count;$i++) {
                $name = ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i))
                $type = [Domenia.WinSqliteNative]::sqlite3_column_type($stmt,$i)
                $value = $null
                switch ($type) {
                    1 { $value = [long][Domenia.WinSqliteNative]::sqlite3_column_int64($stmt,$i) }
                    2 { $value = [double][Domenia.WinSqliteNative]::sqlite3_column_double($stmt,$i) }
                    3 { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                    5 { $value = $null }
                    default { $p=[Domenia.WinSqliteNative]::sqlite3_column_text($stmt,$i); $n=[Domenia.WinSqliteNative]::sqlite3_column_bytes($stmt,$i); $value=ConvertFrom-DomeniaUtf8Ptr $p $n }
                }
                $o[$name] = $value
            }
            $rows.Add([pscustomobject]$o)
        }
        if ($step -ne 101) { throw "SQLite step code $step : $(ConvertFrom-DomeniaUtf8Ptr ([Domenia.WinSqliteNative]::sqlite3_errmsg($DatabaseHandle)))" }
        return $rows.ToArray()
    }
    finally {
        if ($stmt -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [void][Domenia.WinSqliteNative]::sqlite3_finalize($stmt) } catch { } }
        if ($sqlPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sqlPtr) }
        if ($own) { Close-DomeniaDatabase $DatabaseHandle }
    }
}

function Get-DomeniaDatabasePath {throw 'Chemin de base explicite requis pour la sauvegarde.'}
# StorageBackup (2026-10-08): consistent hot copy through the SQLite backup API, outside the Dispatcher (D014).
# The original is opened read-only and never modified; a partial copy is removed on failure.
$dbPath=[string]$Payload.Database;$backupDir=[string]$Payload.BackupDirectory;$copyTo=[string]$Payload.CopyTo
$budget=[Math]::Max(5,[Math]::Min(120,[int]$Payload.BudgetSeconds));$keep=[Math]::Max(2,[Math]::Min(30,[int]$Payload.Keep))
# FI-13: the copies taken before a gesture form their own series (Geste-*.db), rotated apart from the scheduled and
# manual copies (Domenia-*.db), so that frequent gestures never remove a deliberate copy. Any other value is refused.
$series='';if($null -ne $Payload.PSObject.Properties['Series']){$series=[string]$Payload.Series}
if(($series -cne '') -and ($series -cne 'Gesture')){throw 'Série de sauvegarde inconnue.'}
if(($series -ceq 'Gesture') -and ([bool]$copyTo)){throw 'Une sauvegarde avant geste ne se copie pas vers un fichier choisi.'}
$filePrefix=if($series -ceq 'Gesture'){'Geste-'}else{'Domenia-'}
function Get-WBackupSafePath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){throw 'Chemin de sauvegarde vide.'}
    $full=[IO.Path]::GetFullPath($Path);$part=$full
    while($part){
        if(Test-Path -LiteralPath $part){
            if(([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Un chemin de sauvegarde ne peut pas traverser un lien symbolique ou une jonction.'}
        }
        $parent=[IO.Path]::GetDirectoryName($part);if($parent -eq $part){break};$part=$parent
    }
    return $full
}
$dbPath=Get-WBackupSafePath $dbPath;$backupDir=Get-WBackupSafePath $backupDir
if($copyTo){
    $copyTo=Get-WBackupSafePath $copyTo
    foreach($suffix in @('','-wal','-shm','-journal')){
        if([string]::Equals($copyTo,($dbPath+$suffix),[StringComparison]::OrdinalIgnoreCase)){throw 'Export refusé : la destination est la base active ou un de ses journaux.'}
    }
    if([IO.Directory]::Exists($copyTo) -or -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($copyTo))){throw 'Le dossier de destination de l export doit exister et la destination doit être un fichier.'}
}
if(-not [IO.File]::Exists($dbPath)){throw 'aucune base active a sauvegarder.'}
[void][IO.Directory]::CreateDirectory($backupDir)
$stamp=(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$dest=Join-Path $backupDir ($filePrefix+$stamp+'.db');$temporary=$dest+'.partial'
$sourceDb=[IntPtr]::Zero;$targetDb=[IntPtr]::Zero;$backup=[IntPtr]::Zero;$mainPtr=[IntPtr]::Zero;$complete=$false;$exportTemporary=''
try{
    $sourceDb=Open-DomeniaDatabase -Path $dbPath -ReadOnly
    $targetDb=Open-DomeniaDatabase -Path $temporary
    $mainPtr=New-DomeniaUtf8Ptr 'main'
    $backup=[Domenia.WinSqliteNative]::sqlite3_backup_init($targetDb,$mainPtr,$sourceDb,$mainPtr)
    if($backup -eq [IntPtr]::Zero){throw 'Initialisation de la sauvegarde SQLite impossible.'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        $rc=[Domenia.WinSqliteNative]::sqlite3_backup_step($backup,256)
        if($rc -eq 101){break}
        if($rc -notin @(0,5,6)){throw "Sauvegarde SQLite : code $rc."}
        if($watch.Elapsed.TotalSeconds -ge $budget){throw "Sauvegarde SQLite interrompue apres $budget secondes. L'original est intact."}
        if($rc -in @(5,6)){Start-Sleep -Milliseconds 25}
    }while($true)
    $finish=[Domenia.WinSqliteNative]::sqlite3_backup_finish($backup);$backup=[IntPtr]::Zero
    if($finish -ne 0){throw "Finalisation de sauvegarde SQLite : code $finish."}
    $check=@(Invoke-DomeniaDbQuery -Sql 'PRAGMA quick_check;' -DatabaseHandle $targetDb)
    if($check.Count -ne 1 -or [string]$check[0].quick_check -cne 'ok'){throw 'La sauvegarde ne passe pas le controle SQLite.'}
    Close-DomeniaDatabase $targetDb;$targetDb=[IntPtr]::Zero
    Close-DomeniaDatabase $sourceDb;$sourceDb=[IntPtr]::Zero
    [IO.File]::Move($temporary,$dest);$complete=$true
    Get-ChildItem -LiteralPath $backupDir -Filter ($filePrefix+'*.db') -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    if($copyTo){
        try{
            # Publish a fully flushed sibling copy atomically. A failed export leaves the
            # previous destination and the verified local backup available.
            $exportTemporary=$copyTo+'.'+[guid]::NewGuid().ToString('N')+'.partial'
            $inputStream=$null;$outputStream=$null
            try{
                $inputStream=[IO.File]::Open($dest,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $outputStream=[IO.File]::Open($exportTemporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $inputStream.CopyTo($outputStream);$outputStream.Flush($true)
            }finally{if($null -ne $outputStream){$outputStream.Dispose()};if($null -ne $inputStream){$inputStream.Dispose()}}
            [void](Get-WBackupSafePath $copyTo)
            if([IO.File]::Exists($copyTo)){[IO.File]::Replace($exportTemporary,$copyTo,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($exportTemporary,$copyTo)}
            $exportTemporary=''
        }catch{throw ('Export non effectué ; sauvegarde locale vérifiée conservée dans '+$dest+' : '+$_.Exception.Message)}
    }
    $stream=[IO.File]::OpenRead($dest);$sha=[Security.Cryptography.SHA256]::Create();try{$fileHash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
    [pscustomobject]@{Backup=$dest;CopiedTo=$copyTo;Verified=$true;VerifiedAtUtc=[datetime]::UtcNow.ToString('o');SHA256=$fileHash;Bytes=[long]([IO.FileInfo]::new($dest).Length)}
}
finally{
    if($backup -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_backup_finish($backup)}
    Close-DomeniaDatabase $targetDb;Close-DomeniaDatabase $sourceDb
    if($mainPtr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($mainPtr)}
    if($exportTemporary){Remove-Item -LiteralPath $exportTemporary -Force -ErrorAction SilentlyContinue}
    if(-not $complete){foreach($suffix in @('','-wal','-shm','-journal')){Remove-Item -LiteralPath ($temporary+$suffix) -Force -ErrorAction SilentlyContinue}}
}
'@
    return (Get-DomeniaStorageLeaseWorkerCode) + [Environment]::NewLine + $body
}

function Get-DomeniaStorageLeaseWorkerCode {
    # Trusted versioned module, shared byte-for-byte by UI helpers and workers.
    if(-not $script:DomeniaStorageLeaseCode){$script:DomeniaStorageLeaseCode=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Domenia-StorageLease.Model.ps1'),[Text.Encoding]::UTF8)}
    return $script:DomeniaStorageLeaseCode
}

function Get-DomeniaStorageMaintenanceWorkerCode {
    $backupCode=Get-DomeniaStorageBackupWorkerCode
    $marker="function Get-DomeniaDatabasePath {throw 'Chemin de base explicite requis pour la sauvegarde.'}"
    $position=$backupCode.IndexOf($marker,[StringComparison]::Ordinal)
    if($position -lt 0){throw 'Preliminaire SQLite de maintenance absent.'}
    $prefix=$backupCode.Substring(0,$position)
    return $prefix+@'
function Get-DomeniaDatabasePath {throw 'Chemin de maintenance explicite requis.'}
function Get-MaintWPath {
    param([string]$Path,[switch]$Existing)
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path -match '[\x00-\x1f]'){throw 'Chemin local absolu requis.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\') -or [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full)).DriveType -eq [IO.DriveType]::Network){throw 'Une base active doit rester sur un disque local.'}
    if([IO.Path]::GetExtension($full) -ine '.db' -or ($Existing -and -not [IO.File]::Exists($full))){throw 'Fichier de base .db local requis.'}
    $part=$full;while($part){if((Test-Path -LiteralPath $part) -and ([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint)){throw 'Chemin redirige refuse.'};$next=[IO.Path]::GetDirectoryName($part);if($next -eq $part){break};$part=$next}
    foreach($suffix in @('-wal','-shm','-journal')){if([IO.File]::Exists($full+$suffix) -and ([IO.File]::GetAttributes($full+$suffix) -band [IO.FileAttributes]::ReparsePoint)){throw 'Annexe SQLite redirigee refusee.'}}
    return $full
}
function Get-MaintWHash {param([string]$Text);$sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Read-MaintWInfo {
    param([IntPtr]$Db,[string]$Path,[string]$Domain)
    $schema=@(Invoke-DomeniaDbQuery "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');" $Db)
    if(@($schema|Where-Object{$_.key -ceq 'schema_version' -and $_.value -ceq '11'}).Count -ne 1 -or @($schema|Where-Object{$_.key -ceq 'domenia_schema' -and $_.value -ceq '1'}).Count -ne 1){throw 'Schema incompatible : aucune modification.'}
    $integrity=@(Invoke-DomeniaDbQuery 'PRAGMA quick_check;' $Db);if($integrity.Count -ne 1 -or [string]$integrity[0].quick_check -cne 'ok'){throw 'Integrite SQLite non confirmee.'}
    $state=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_state WHERE id=1;' $Db)
    if($state.Count -ne 1 -or [string]$state[0].domain_dn -ine $Domain){throw 'Domaine de base absent ou different.'}
    $counts=[ordered]@{}
    foreach($table in @('ad_objects','domenia_observations','domenia_details','user_machine_links','domenia_query_recipes','domenia_store_batches')){
        $exists=Read-StoreWLeaseScalar $Db ("SELECT name FROM sqlite_master WHERE type='table' AND name='"+$table+"';")
        $counts[$table]=if($exists){[long](@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM '+$table+';') $Db)[0].n)}else{0L}
    }
    $files=@(foreach($suffix in @('','-wal')){$file=[IO.FileInfo]::new($Path+$suffix);if($file.Exists){[pscustomobject]@{Suffix=$suffix;Length=$file.Length;Written=$file.LastWriteTimeUtc.ToString('o')}}})
    $basis=[ordered]@{Path=$Path;DomainDn=[string]$state[0].domain_dn;StoreId=[string]$state[0].store_id;Revision=[long]$state[0].revision;Counts=$counts;Files=$files}
    return [pscustomobject]@{Path=$Path;DomainDn=[string]$state[0].domain_dn;StoreId=[string]$state[0].store_id;Revision=[long]$state[0].revision;Counts=[pscustomobject]$counts;Integrity='ok';Bytes=[long](@($files|Measure-Object Length -Sum)[0].Sum);Fingerprint=(Get-MaintWHash ($basis|ConvertTo-Json -Depth 5 -Compress))}
}
$action=[string]$Payload.Action;if($action -cnotin @('Inspect','ReadRedirect','Move','Restore','Resume','Rollback')){throw 'Operation de maintenance inconnue.'}
$domain=([string]$Payload.DomainDn).Trim().ToLowerInvariant();if($domain -notmatch '(^|,)dc='){throw 'Domaine de maintenance requis.'}
$active=Get-MaintWPath ([string]$Payload.ActivePath) -Existing
$source=Get-MaintWPath ([string]$Payload.SourcePath) -Existing
$db=[IntPtr]::Zero;$sourceDb=[IntPtr]::Zero;$targetDb=[IntPtr]::Zero;$lease=$null;$sourceLease=$null;$resumeTargetLease=$null;$backup=[IntPtr]::Zero;$main=[IntPtr]::Zero;$temporary='';$target='';$published=$false
try{
    if($action -eq 'ReadRedirect'){
        $db=Open-DomeniaDatabase $active -ReadOnly;[void](Invoke-DomeniaDbExec 'BEGIN;' $db)
        $info=Read-MaintWInfo $db $active $domain
        $redirect=$null
        if(Read-StoreWLeaseScalar $db "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_store_redirect';"){
            $rows=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_redirect WHERE id=1;' $db)
            if($rows.Count -gt 1){throw 'Marqueur de reprise ambigu.'}
            if($rows.Count){
                $id=[guid]::Empty;if(-not [guid]::TryParse([string]$rows[0].operation_id,[ref]$id) -or $id -eq [guid]::Empty){throw 'Operation de reprise invalide.'}
                $target=Get-MaintWPath ([string]$rows[0].target_path)
                if($target -ieq $active -or [string]$rows[0].target_store_id -cne (Get-MaintWHash ($target.ToLowerInvariant()+"`n"+$domain)) -or [long]$rows[0].target_revision -lt 1){throw 'Identite du marqueur de reprise invalide.'}
                $redirect=[pscustomobject]@{OperationId=$id.ToString('D');TargetPath=$target;StoreId=[string]$rows[0].target_store_id;Revision=[long]$rows[0].target_revision;MovedAtUtc=[string]$rows[0].moved_at}
            }
        }
        [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
        return [pscustomobject]@{Kind='StorageMaintenance';Action='ReadRedirect';ActivePath=$active;DomainDn=$domain;Redirect=$redirect;ReadOnly=$true}
    }
    if($action -eq 'Inspect'){
        $sourceDb=Open-DomeniaDatabase $source -ReadOnly;[void](Invoke-DomeniaDbExec 'BEGIN;' $sourceDb)
        $info=Read-MaintWInfo $sourceDb $source $domain;[void](Invoke-DomeniaDbExec 'COMMIT;' $sourceDb)
        return [pscustomobject]@{Kind='StorageMaintenance';Action='Inspect';Committed=$false;Source=$info;ActivePath=$active;DomainDn=$domain}
    }
    $operation=[guid]::Empty;if(-not [guid]::TryParse([string]$Payload.OperationId,[ref]$operation) -or $operation -eq [guid]::Empty){throw 'Identifiant de maintenance invalide.'}
    $lease=Enter-StoreWDatabaseLease $active 1000
    if($source -ine $active){$sourceLease=Enter-StoreWDatabaseLease $source 1000}
    # Open active read-only so a pending redirect can be resumed or rolled back explicitly.
    $db=Open-DomeniaDatabase $active -ReadOnly;[void](Invoke-DomeniaDbExec 'BEGIN;' $db)
    $redirect=@();if(Read-StoreWLeaseScalar $db "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_store_redirect';"){$redirect=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_redirect WHERE id=1;' $db)}
    if($action -in @('Resume','Rollback')){
        if(-not $redirect.Count -and $action -eq 'Rollback'){
            $info=Read-MaintWInfo $db $active $domain
            if($info.StoreId -cne (Get-MaintWHash ($active.ToLowerInvariant()+"`n"+$domain))){throw 'Identite du fichier original modifiee.'}
            return [pscustomobject]@{Kind='StorageMaintenance';Action=$action;Committed=$true;OperationId=$operation.ToString('D');ActivePath=$active;TargetPath=$active;StoreId=$info.StoreId;DomainDn=$domain;Revision=$info.Revision;Integrity='ok';OriginalPreserved=$true}
        }
        if($redirect.Count -ne 1 -or [string]$redirect[0].operation_id -cne $operation.ToString('D')){throw 'Redirection differente : reprise refusee.'}
        $target=Get-MaintWPath ([string]$redirect[0].target_path) -Existing
        $resumeTargetLease=Enter-StoreWDatabaseLease $target 1000
        $targetDb=Open-DomeniaDatabase $target -ReadOnly;$info=Read-MaintWInfo $targetDb $target $domain
        if($info.StoreId -cne [string]$redirect[0].target_store_id){throw 'Identite de la copie de reprise invalide.'}
        if($action -eq 'Rollback'){
            # A rollback is allowed only before the copied database receives another commit.
            if($info.Revision -ne [long]$redirect[0].target_revision){throw 'La nouvelle base a change. Retour automatique refuse ; les deux fichiers sont conserves.'}
            Close-DomeniaDatabase $db;$db=[IntPtr]::Zero
            $ptr=New-DomeniaUtf8Ptr $active;try{$rc=[Domenia.WinSqliteNative]::sqlite3_open_v2($ptr,[ref]$db,(2 -bor 65536),[IntPtr]::Zero)}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)};if($rc -ne 0){throw 'Reouverture du fichier original impossible.'}
            [void](Invoke-DomeniaDbExec ('BEGIN IMMEDIATE;DELETE FROM domenia_store_redirect WHERE id=1 AND operation_id='+(ConvertTo-DomeniaSqlLiteral $operation.ToString('D'))+';') $db)
            if([long](Read-StoreWLeaseScalar $db 'SELECT changes();') -ne 1){throw 'Le marqueur a change pendant la reprise : retour refuse.'}
            [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
        }
        if($action -eq 'Rollback'){$info=Read-MaintWInfo $db $active $domain;$target=$active}
        return [pscustomobject]@{Kind='StorageMaintenance';Action=$action;Committed=$true;OperationId=$operation.ToString('D');ActivePath=$active;TargetPath=$target;StoreId=$info.StoreId;DomainDn=$domain;Revision=$info.Revision;Integrity='ok';OriginalPreserved=$true}
    }
    if($redirect.Count){throw ('StorageRedirected : reprise requise vers '+[string]$redirect[0].target_path)}
    $activeInfo=Read-MaintWInfo $db $active $domain
    $sourceDb=Open-DomeniaDatabase $source -ReadOnly;[void](Invoke-DomeniaDbExec 'BEGIN;' $sourceDb);$info=Read-MaintWInfo $sourceDb $source $domain
    if($info.Fingerprint -cne [string]$Payload.ExpectedFingerprint){throw 'La source a change : refaire la previsualisation.'}
    $target=Get-MaintWPath ([string]$Payload.TargetPath)
    if($target -ieq $active -or $target -ieq $source -or (Test-Path -LiteralPath $target)){throw 'La destination doit etre un nouveau fichier ; aucun original ne sera ecrase.'}
    $parent=[IO.Path]::GetDirectoryName($target);if(-not [IO.Directory]::Exists($parent)){throw 'Le dossier de destination doit exister.'}
    foreach($suffix in @('-wal','-shm','-journal')){if(Test-Path -LiteralPath ($target+$suffix)){throw 'La destination contient deja une annexe SQLite.'}}
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($target));if($drive.IsReady -and $drive.AvailableFreeSpace -lt ([long]$info.Bytes*2+33554432L)){throw 'StorageInsufficientSpace : reserve de copie insuffisante.'}
    $temporary=Join-Path $parent ('.domenia-'+$operation.ToString('N')+'.partial.db')
    if(Test-Path -LiteralPath $temporary){throw 'Copie temporaire deja presente ; verifier la reprise precedente.'}
    $targetDb=Open-DomeniaDatabase $temporary;$main=New-DomeniaUtf8Ptr 'main';$backup=[Domenia.WinSqliteNative]::sqlite3_backup_init($targetDb,$main,$sourceDb,$main)
    if($backup -eq [IntPtr]::Zero){throw 'Copie SQLite impossible.'}
    $watch=[Diagnostics.Stopwatch]::StartNew();$budget=[Math]::Max(30,[Math]::Min(600,[int]$Payload.BudgetSeconds))
    do{$rc=[Domenia.WinSqliteNative]::sqlite3_backup_step($backup,256);if($rc -eq 101){break};if($rc -notin @(0,5,6)){throw ('Copie SQLite code '+$rc)};if($watch.Elapsed.TotalSeconds -gt $budget){throw 'Delai de copie depasse ; original conserve.'};if($rc -in @(5,6)){Start-Sleep -Milliseconds 25}}while($true)
    $rc=[Domenia.WinSqliteNative]::sqlite3_backup_finish($backup);$backup=[IntPtr]::Zero;if($rc -ne 0){throw 'Finalisation de copie impossible.'}
    $newId=Get-MaintWHash ($target.ToLowerInvariant()+"`n"+$domain);$newRevision=[Math]::Max([long]$info.Revision,[long]$activeInfo.Revision)+1
    [void](Invoke-DomeniaDbExec ('PRAGMA synchronous=FULL;BEGIN IMMEDIATE;UPDATE domenia_store_state SET store_id='+(ConvertTo-DomeniaSqlLiteral $newId)+',revision='+$newRevision+' WHERE id=1;DROP TABLE IF EXISTS domenia_store_redirect;COMMIT;') $targetDb)
    $verified=Read-MaintWInfo $targetDb $temporary $domain
    if($verified.StoreId -cne $newId -or $verified.Revision -ne $newRevision){throw 'Identite de copie non confirmee.'}
    Close-DomeniaDatabase $targetDb;$targetDb=[IntPtr]::Zero;Close-DomeniaDatabase $sourceDb;$sourceDb=[IntPtr]::Zero
    # All handles are closed before atomic publication. The old file is retained unchanged until the marker.
    [void](Get-MaintWPath $target);[IO.File]::Move($temporary,$target);$temporary='';$published=$true
    Close-DomeniaDatabase $db;$db=[IntPtr]::Zero;$db=Open-DomeniaDatabase $active
    $v=@($operation.ToString('D'),$target,$newId,$newRevision,[datetime]::UtcNow.ToString('o'))
    [void](Invoke-DomeniaDbExec ('PRAGMA synchronous=FULL;BEGIN IMMEDIATE;CREATE TABLE IF NOT EXISTS domenia_store_redirect(id INTEGER PRIMARY KEY CHECK(id=1),operation_id TEXT NOT NULL,target_path TEXT NOT NULL,target_store_id TEXT NOT NULL,target_revision INTEGER NOT NULL,moved_at TEXT NOT NULL);INSERT INTO domenia_store_redirect(id,operation_id,target_path,target_store_id,target_revision,moved_at) VALUES(1,'+(@($v|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');COMMIT;') $db)
    return [pscustomobject]@{Kind='StorageMaintenance';Action=$action;Committed=$true;OperationId=$operation.ToString('D');ActivePath=$active;TargetPath=$target;StoreId=$newId;DomainDn=$domain;Revision=$newRevision;Integrity='ok';OriginalPreserved=$true;Counts=$verified.Counts}
}catch{
    if($published){throw ('Copie verifiee conservee dans '+$target+'. Bascule a verifier, original conserve. '+$_.Exception.Message)}
    throw
}finally{
    if($backup -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_backup_finish($backup)}
    Close-DomeniaDatabase $targetDb;Close-DomeniaDatabase $sourceDb;Close-DomeniaDatabase $db
    if($main -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($main)}
    if($temporary){foreach($suffix in @('','-wal','-shm','-journal')){Remove-Item -LiteralPath ($temporary+$suffix) -Force -ErrorAction SilentlyContinue}}
    if($null -ne $resumeTargetLease){Exit-StoreWDatabaseLease $resumeTargetLease};if($null -ne $sourceLease){Exit-StoreWDatabaseLease $sourceLease};if($null -ne $lease){Exit-StoreWDatabaseLease $lease}
}
'@
}

function Get-DomeniaStorageRetentionWorkerCode {
    $code=Get-DomeniaStoragePurgeWorkerCode
    $marker='# Validate all input before opening the existing database. No payload identifier becomes SQL.'
    $position=$code.IndexOf($marker,[StringComparison]::Ordinal);if($position -lt 0){throw 'Preliminaire de retention absent.'}
    return $code.Substring(0,$position)+@'
function Copy-RetentionWBackup {
    param([string]$Path,[string]$StoreId,[long]$Revision)
    # The caller holds the writer lease and BEGIN IMMEDIATE. A separate read connection sees the exact pre-delete state.
    $directory=Join-Path ([IO.Path]::GetDirectoryName($Path)) 'Backups'
    if((Test-Path -LiteralPath $directory) -and ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint)){throw 'Dossier de sauvegarde redirige refuse.'}
    [void][IO.Directory]::CreateDirectory($directory)
    $bytes=0L;foreach($suffix in @('','-wal')){if([IO.File]::Exists($Path+$suffix)){$bytes+=[IO.FileInfo]::new($Path+$suffix).Length}}
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($directory));if($drive.IsReady -and $drive.AvailableFreeSpace -lt ($bytes*2+33554432L)){throw 'StorageInsufficientSpace : sauvegarde de conservation impossible.'}
    $destination=Join-Path $directory ('Domenia-retention-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N')+'.db')
    $temporary=$destination+'.partial';$source=[IntPtr]::Zero;$target=[IntPtr]::Zero;$backup=[IntPtr]::Zero;$main=[IntPtr]::Zero
    try{
        $source=Open-DomeniaDatabase $Path -ReadOnly;$target=Open-DomeniaDatabase $temporary
        [void](Invoke-DomeniaDbExec 'PRAGMA synchronous=FULL;' $target)
        $main=New-DomeniaUtf8Ptr 'main';$backup=[Domenia.WinSqliteNative]::sqlite3_backup_init($target,$main,$source,$main)
        if($backup -eq [IntPtr]::Zero){throw 'Sauvegarde prealable indisponible.'}
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do{$rc=[Domenia.WinSqliteNative]::sqlite3_backup_step($backup,256);if($rc -eq 101){break};if($rc -notin @(0,5,6)){throw ('Sauvegarde prealable code '+$rc)};if($watch.Elapsed.TotalSeconds -ge 120){throw 'Delai de sauvegarde prealable depasse.'};if($rc -in @(5,6)){Start-Sleep -Milliseconds 25}}while($true)
        $rc=[Domenia.WinSqliteNative]::sqlite3_backup_finish($backup);$backup=[IntPtr]::Zero;if($rc -ne 0){throw 'Sauvegarde prealable non finalisee.'}
        $check=@(Invoke-DomeniaDbQuery 'PRAGMA quick_check;' $target);$state=@(Invoke-DomeniaDbQuery 'SELECT store_id,revision FROM domenia_store_state WHERE id=1;' $target)
        if($check.Count -ne 1 -or $check[0].quick_check -cne 'ok' -or $state.Count -ne 1 -or $state[0].store_id -cne $StoreId -or [long]$state[0].revision -ne $Revision){throw 'Copie prealable non conforme au contexte confirme.'}
        Close-DomeniaDatabase $target;$target=[IntPtr]::Zero;Close-DomeniaDatabase $source;$source=[IntPtr]::Zero
        [IO.File]::Move($temporary,$destination);$temporary=''
        $stream=[IO.File]::OpenRead($destination);$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
        return [pscustomobject]@{Path=$destination;SHA256=$hash;Verified=$true;StoreId=$StoreId;Revision=$Revision}
    }finally{
        if($backup -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_backup_finish($backup)}
        Close-DomeniaDatabase $target;Close-DomeniaDatabase $source
        if($main -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($main)}
        if($temporary){foreach($suffix in @('','-wal','-shm','-journal')){Remove-Item -LiteralPath ($temporary+$suffix) -Force -ErrorAction SilentlyContinue}}
    }
}
if($Payload.DryRun -isnot [bool]){throw 'Mode de conservation explicite requis.'}
$path=Test-DomeniaStoragePurgePath ([string]$Payload.Path);$dryRun=[bool]$Payload.DryRun;$targets=[Collections.Generic.List[object]]::new()
foreach($family in @('Presence','Console','Inventory','Probe','Detail')){
    $cutoff=[string]$Payload.Cutoffs.$family;if(-not $cutoff){continue}
    $date=[datetime]::MinValue;if(-not [datetime]::TryParseExact($cutoff,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$date) -or $date.Kind -ne [DateTimeKind]::Utc -or $date -ge [datetime]::UtcNow){throw 'Date limite de conservation invalide.'}
    $literal=ConvertTo-DomeniaSqlLiteral $date.ToString('o');$table=if($family -eq 'Detail'){'domenia_details'}else{'domenia_observations'}
    $where="julianday(attempt_at) IS NOT NULL AND julianday(attempt_at)<julianday($literal) AND (COALESCE(success_at,'')='' OR (julianday(success_at) IS NOT NULL AND julianday(success_at)<julianday($literal)))"
    if($family -ne 'Detail'){$where+=' AND '+$(if($family -eq 'Probe'){"family LIKE 'Probe:%'"}else{'family='+(ConvertTo-DomeniaSqlLiteral $family)});$where+=' AND object_guid IN (SELECT object_guid FROM domenia_legacy_observation_imports)'}
    $targets.Add([pscustomobject]@{Family=$family;Table=$table;CutoffUtc=$date.ToString('o');Where=$where})
}
if(-not $targets.Count){throw 'Toutes les familles sont conservees sans limite ; aucune suppression a appliquer.'}
$db=[IntPtr]::Zero;$transaction=$false
try{
    $db=Open-DomeniaDatabase $path;[void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db);$transaction=$true
    $schema=@(Invoke-DomeniaDbQuery "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');" $db)
    if(@($schema|Where-Object{$_.key -eq 'schema_version' -and $_.value -eq '11'}).Count -ne 1 -or @($schema|Where-Object{$_.key -eq 'domenia_schema' -and $_.value -eq '1'}).Count -ne 1){throw 'Schema de retention incompatible.'}
    if(@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='trigger';" $db).Count){throw 'Conservation refusee : declencheur SQLite non reconnu.'}
    $state=@(Invoke-DomeniaDbQuery 'SELECT * FROM domenia_store_state WHERE id=1;' $db)
    if($state.Count -ne 1 -or [string]$state[0].store_id -cne [string]$Payload.StoreId -or [string]$state[0].domain_dn -ine [string]$Payload.DomainDn){throw 'Contexte de conservation incompatible.'}
    $counts=@(foreach($target in $targets){$n=[long](@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM '+$target.Table+' WHERE '+$target.Where+';') $db)[0].n);[pscustomobject]@{Family=$target.Family;CutoffUtc=$target.CutoffUtc;Rows=$n}})
    $skipped=[long](@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM domenia_observations WHERE object_guid NOT IN (SELECT object_guid FROM domenia_legacy_observation_imports);' $db)[0].n)
    $basis=[ordered]@{Path=$path;StoreId=$state[0].store_id;Revision=$state[0].revision;Counts=$counts;SkippedLegacyRows=$skipped}
    $sha=[Security.Cryptography.SHA256]::Create();try{$fingerprint=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($basis|ConvertTo-Json -Depth 6 -Compress)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if(-not $dryRun -and $fingerprint -cne [string]$Payload.ExpectedFingerprint){throw 'Les mesures ont change : refaire la previsualisation de conservation.'}
    $deleted=0L;$revision=[long]$state[0].revision;$backupReceipt=$null
    if(-not $dryRun){
        $backupReceipt=Copy-RetentionWBackup -Path $path -StoreId ([string]$state[0].store_id) -Revision $revision
        foreach($target in $targets){[void](Invoke-DomeniaDbExec ('DELETE FROM '+$target.Table+' WHERE '+$target.Where+';') $db);$deleted += [long](@(Invoke-DomeniaDbQuery 'SELECT changes() AS n;' $db)[0].n)}
        if($deleted -gt 0){$revision++;[void](Invoke-DomeniaDbExec ('UPDATE domenia_store_state SET revision='+$revision+' WHERE id=1;') $db)}
        [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
    }else{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}
    $transaction=$false
    return [pscustomobject]@{Kind='StorageRetention';Path=$path;StoreId=[string]$state[0].store_id;DomainDn=[string]$state[0].domain_dn;DryRun=$dryRun;Committed=(-not $dryRun);Counts=$counts;DeletedRows=$deleted;SkippedLegacyRows=$skipped;Fingerprint=$fingerprint;Revision=$revision;ReceiptsPreserved=$true;Backup=$backupReceipt}
}finally{if($db -ne [IntPtr]::Zero){if($transaction){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}};Close-DomeniaDatabase $db}}
'@
}
