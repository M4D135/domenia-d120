function Get-DomeniaStorageWorkerCode {
return @'
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
    if ($DatabaseHandle -ne [IntPtr]::Zero) { try { Initialize-DomeniaWinSqliteNative | Out-Null; [void][Domenia.WinSqliteNative]::sqlite3_close($DatabaseHandle) } catch { } }
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
    $pathPtr = [IntPtr]::Zero
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-DomeniaDatabasePath }
        $pathPtr = New-DomeniaUtf8Ptr $Path
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 4 -bor 65536 }
        $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,$flags,[IntPtr]::Zero)
        if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw "Ouverture SQLite impossible (code $rc)." }
        [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,300)
        return $db
    }
    catch {
        # sqlite3_open_v2 can return a non-null handle even on failure.
        if ($db -ne [IntPtr]::Zero) { [void][Domenia.WinSqliteNative]::sqlite3_close($db) }
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
function LinkHash($r){
    if($null -eq $r){return ''}
    $v=[ordered]@{UserLogin=[string]$r.user_login;Computer=[string]$r.computer;Source=[string]$r.source;Confidence=[string]$r.confidence;VerifiedInAD=[string]([int]$r.verified_in_ad -ne 0);When=[string]$r.observed_at;Details=[string]$r.details;UserGuid=[string]$r.user_guid;ComputerGuid=[string]$r.computer_guid;UserDn=[string]$r.user_dn;ComputerDn=[string]$r.computer_dn}
    $h=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes(($v|ConvertTo-Json -Compress)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}
}
if(@($Payload.Items).Count -gt 64){throw 'Lot stockage trop grand.'}
$path=[IO.Path]::GetFullPath([string]$Payload.Path)
if($path.StartsWith('\\') -or [IO.DriveInfo]::new([IO.Path]::GetPathRoot($path)).DriveType -eq [IO.DriveType]::Network){throw 'Base active reseau non prise en charge.'}
$probe=[IO.FileInfo]::new($path)
while($null -ne $probe){if($probe.Exists -and ($probe.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Base ou dossier redirige.'};$probe=if($probe -is [IO.FileInfo]){$probe.Directory}else{$probe.Parent}}
$db=[IntPtr]::Zero;$transaction=$false;$conflicts=[Collections.Generic.List[string]]::new()
try {
 $db=Open-DomeniaDatabase -Path $path
 $version=@(Invoke-DomeniaDbQuery "SELECT value FROM schema_info WHERE key='schema_version';" $db)
 if($version.Count -ne 1 -or [string]$version[0].value -ne '11'){throw 'Schema stockage incompatible.'}
 $future=@(Invoke-DomeniaDbQuery "SELECT value FROM schema_info WHERE key='domenia_schema';" $db)
 if($future.Count -ne 1 -or [string]$future[0].value -ne '1'){throw 'Version Domenia incompatible.'}
 [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db);$transaction=$true
 foreach($i in @($Payload.Items)){
  if($i.Kind -eq 'Index'){
    $r=$i.Row;$key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=([string]$r.Type+'|'+[string]$r.DN).ToLowerInvariant()}
    $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,(([string]$r.Name+' '+[string]$r.Login+' '+[string]$r.UPN+' '+[string]$r.Description+' '+[string]$r.Display).ToLowerInvariant()),[string]$i.Server,[string]$i.At)
    $sql='INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'
    [void](Invoke-DomeniaDbExec $sql $db)
  } elseif($i.Kind -eq 'Link'){
    $key=ConvertTo-DomeniaSqlLiteral ([string]$i.Key)
    $current=@(Invoke-DomeniaDbQuery ("SELECT * FROM user_machine_links WHERE computer_key=$key;") $db)
    $actual=if($current.Count){LinkHash $current[0]}else{''}
    if($actual -cne [string]$i.Expected){$conflicts.Add([string]$i.Key);continue}
    if($i.Remove){[void](Invoke-DomeniaDbExec ("DELETE FROM user_machine_links WHERE computer_key=$key;") $db);continue}
    $l=$i.Row;$verified=if([string]$l.VerifiedInAD -ieq 'True'){1}else{0}
    $values=@([string]$i.Key,[string]$l.UserLogin,[string]$l.Computer,[string]$l.Source,[int]$l.Confidence,$verified,[string]$l.When,[string]$l.Details,[string]$l.UserGuid,[string]$l.ComputerGuid,[string]$l.UserDn,[string]$l.ComputerDn)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO user_machine_links(computer_key,user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    $history=@([string]$l.UserLogin,[string]$i.Key,[string]$l.Computer,[string]$l.Source,[int]$l.Confidence,$verified,[string]$l.When,[string]$l.Details,[string]$l.UserGuid,[string]$l.ComputerGuid)
    [void](Invoke-DomeniaDbExec ('INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) VALUES('+(($history|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
  }elseif($i.Kind -in @('Presence','UserScan','Park','SecretMeta','Sample')){
    $r=$i.Row;$columns='';$table='';$values=@();$verb='INSERT OR REPLACE'
    switch([string]$i.Kind){
      'Presence' {$table='presence_cache';$columns='object_key,state,target,checked_at';$values=@([string]$r.Key,[string]$r.State,[string]$r.Target,[string]$r.At)}
      'UserScan' {$table='user_scan_history';$columns='login_key,login,scanned_at,scanned,candidates,reachable,probed,found';$values=@(([string]$r.Login).ToLowerInvariant(),[string]$r.Login,[string]$r.At,[int][bool]$r.Scanned,[int]$r.Candidates,[int]$r.Reachable,[int]$r.Probed,[string]$r.Found)}
      'Park' {$table='park_state';$columns='computer_key,computer,last_probe,status,user_login,attempts';$values=@([string]$r.Key,[string]$r.Computer,[string]$r.LastProbe,[string]$r.Status,[string]$r.User,[int]$r.Attempts)}
      'SecretMeta' {
        $key=ConvertTo-DomeniaSqlLiteral (([string]$r.Computer).ToUpperInvariant())
        $old=@(Invoke-DomeniaDbQuery ("SELECT * FROM secret_state WHERE computer_key=$key;") $db)
        $prev=if($old.Count){$old[0]}else{$null}
        $keys=if([int]$r.BitLockerKeys -lt 0){[int]$prev.bitlocker_keys}else{[int]$r.BitLockerKeys}
        $last=if([int]$r.BitLockerKeys -lt 0){[string]$prev.bitlocker_last}else{[string]$r.BitLockerLast}
        $scheme=if([string]$r.LapsScheme){[string]$r.LapsScheme}else{[string]$prev.laps_scheme}
        $expiry=if([string]$r.LapsScheme){[string]$r.LapsExpiry}else{[string]$prev.laps_expiry}
        $table='secret_state';$columns='computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail'
        $values=@(([string]$r.Computer).ToUpperInvariant(),[string]$r.Computer,[string]$r.At,$keys,$last,$scheme,$expiry,[string]$r.Verdict,'Metadonnees sans secret')
      }
      'Sample' {$verb='INSERT';$table='operation_runs';$columns='operation,mode,item_count,duration_ms,bytes_estimated,ad_queries,remote_attempts,fallback_tasks,success_count,failure_count,started_at,finished_at,notes';$values=@([string]$r.Operation,[string]$r.Mode,[int]$r.ItemCount,[long]$r.DurationMs,[long]$r.BytesEstimated,[int]$r.AdQueries,[int]$r.RemoteAttempts,[int]$r.FallbackTasks,[int]$r.SuccessCount,[int]$r.FailureCount,[string]$r.StartedAt,[string]$r.Finished,'')}
    }
    [void](Invoke-DomeniaDbExec ($verb+' INTO '+$table+'('+$columns+') VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
  }elseif($i.Kind -eq 'IndexBulk'){
    $bulk=$i.Row
    if(@($bulk.Rows).Count -gt 250000){throw 'Lot index trop grand.'}
    if($bulk.ReplaceAll){[void](Invoke-DomeniaDbExec 'DELETE FROM ad_objects;' $db)}
    foreach($r in @($bulk.Rows)){
      $key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=([string]$r.Type+'|'+[string]$r.DN).ToLowerInvariant()}
      $search=([string]$r.Name+' '+[string]$r.Login+' '+[string]$r.Upn+' '+[string]$r.Display+' '+[string]$r.Description+' '+[string]$r.Extra).ToLowerInvariant()
      $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,$search,[string]$bulk.Server,[string]$bulk.At)
      [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    }
    $total=[int](@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM ad_objects;' $db)[0].n)
    $values=@('directory',[string]$bulk.Server,[string]$bulk.BaseDn,[long]$bulk.HighestUsn,[string]$bulk.At,$total,'async')
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
  }else{throw 'Type stockage non autorise.'}
 }
 [void](Invoke-DomeniaDbExec 'DELETE FROM operation_runs WHERE id NOT IN (SELECT id FROM operation_runs ORDER BY id DESC LIMIT 10000);DELETE FROM user_machine_history WHERE id NOT IN (SELECT id FROM user_machine_history ORDER BY id DESC LIMIT 20000);' $db)
 [void](Invoke-DomeniaDbExec 'COMMIT;' $db);$transaction=$false
 [pscustomobject]@{Saved=$true;Conflicts=$conflicts.ToArray();Count=@($Payload.Items).Count}
} finally {if($transaction){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}};if($db -ne [IntPtr]::Zero){Close-DomeniaDatabase $db}}
'@
}
