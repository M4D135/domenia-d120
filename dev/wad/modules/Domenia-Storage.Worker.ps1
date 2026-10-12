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
    foreach($r in $objects){
        if($null -eq $r -or [string]::IsNullOrWhiteSpace([string]$r.DN)){throw 'Objet legacy sans DN.'}
        if(-not ([string]$r.DN).EndsWith(','+$BaseDn,[StringComparison]::OrdinalIgnoreCase) -and [string]$r.DN -ine $BaseDn){throw 'Objet legacy dans un autre domaine.'}
        $key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=(([string]$r.Type)+'|'+([string]$r.DN)).ToLowerInvariant()}
        if([string]::IsNullOrWhiteSpace($key)){throw 'Objet legacy sans cle.'}
        $search=(([string]$r.Name)+' '+([string]$r.Login)+' '+([string]$r.Upn)+' '+([string]$r.Display)+' '+([string]$r.Description)+' '+([string]$r.Extra)).ToLowerInvariant()
        $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,$search,'legacy_import',$At)
        [void](Invoke-DomeniaDbExec ('INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
        $imported++
    }
    foreach($r in $park){
        $key=[string]$r.Key
        if([string]::IsNullOrWhiteSpace($key)){$key=Get-DomeniaLegacyComputerKey ([string]$r.Computer)}
        if([string]::IsNullOrWhiteSpace($key)){throw 'Ligne park legacy sans cle.'}
        $values=@($key,[string]$r.Computer,[string]$r.LastProbe,[string]$r.Status,[string]$r.User,[int]$r.Attempts)
        [void](Invoke-DomeniaDbExec ('INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
    }
    foreach($r in $userScans){
        $login=[string]$r.Login
        if([string]::IsNullOrWhiteSpace($login)){throw 'Ligne scan legacy sans login.'}
        $loginKey=$login.ToLowerInvariant()
        $values=@($loginKey,$login,[string]$r.At,[int][bool]$r.Scanned,[int]$r.Candidates,[int]$r.Reachable,[int]$r.Probed,[string]$r.Found)
        [void](Invoke-DomeniaDbExec ('INSERT INTO user_scan_history(login_key,login,scanned_at,scanned,candidates,reachable,probed,found) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
    }
    foreach($r in $secrets){
        $computer=[string]$r.Computer
        if([string]::IsNullOrWhiteSpace($computer)){throw 'Ligne secret legacy sans ordinateur.'}
        $key=$computer.ToUpperInvariant()
        $values=@($key,$computer,[string]$r.At,[int]$r.BitLockerKeys,[string]$r.BitLockerLast,[string]$r.LapsScheme,[string]$r.LapsExpiry,[string]$r.Verdict,'Metadonnees sans secret')
        [void](Invoke-DomeniaDbExec ('INSERT INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $DatabaseHandle)
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
try {
 $db=Open-DomeniaDatabase -Path $path
 $version=@(Invoke-DomeniaDbQuery "SELECT value FROM schema_info WHERE key='schema_version';" $db)
 if($version.Count -ne 1 -or [string]$version[0].value -ne '11'){throw 'Schema stockage incompatible.'}
 $future=@(Invoke-DomeniaDbQuery "SELECT value FROM schema_info WHERE key='domenia_schema';" $db)
 if($future.Count -ne 1 -or [string]$future[0].value -ne '1'){throw 'Version Domenia incompatible.'}
 [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $db);$transaction=$true
 if($legacy.Count -gt 0){
  $r=Import-DomeniaLegacy $db $legacy[0]
  if([int]$r.Already -eq 1){[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db);$transaction=$false;return $r}
  [void](Invoke-DomeniaDbExec 'COMMIT;' $db);$transaction=$false;return $r
 }
 foreach($i in @($Payload.Items)){
  if($i.Kind -eq 'Index'){
    $r=$i.Row;$key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=([string]$r.Type+'|'+[string]$r.DN).ToLowerInvariant()}
    # Same search_key formula as IndexBulk (CO-26): the extra field (system, location, service) stays searchable.
    $search=([string]$r.Name+' '+[string]$r.Login+' '+[string]$r.Upn+' '+[string]$r.Display+' '+[string]$r.Description+' '+[string]$r.Extra).ToLowerInvariant()
    $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,$search,[string]$i.Server,[string]$i.At)
    $sql='INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'
    [void](Invoke-DomeniaDbExec $sql $db)
  } elseif($i.Kind -eq 'Link'){
    [void](Invoke-DomeniaLinkWrite -DatabaseHandle $db -Key ([string]$i.Key) -Expected ([string]$i.Expected) -Row $i.Row -Remove ([bool]$i.Remove) -Conflicts $conflicts -ImportMode $false)
  }elseif($i.Kind -eq 'ParkSession'){
    $r=$i.Row
    if([int]$r.Version -ne 1 -or -not $r.Key -or -not $r.Guid){throw 'Observation du parc invalide.'}
    # Widget probe results (2026-10-07) need a deeper and larger observation; still bounded.
    $json=$r|ConvertTo-Json -Depth 7 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 262144){throw 'Observation du parc trop volumineuse.'}
    [void](Invoke-DomeniaDbExec 'CREATE TABLE IF NOT EXISTS park_session_cache(object_key TEXT PRIMARY KEY,checked_utc TEXT NOT NULL,payload TEXT NOT NULL);' $db)
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
    foreach($r in $secretRows){
        if($null -eq $r -or -not ([string]$r.Computer).Trim()){continue}
        $key=ConvertTo-DomeniaSqlLiteral (([string]$r.Computer).ToUpperInvariant())
        $old=@(Invoke-DomeniaDbQuery ("SELECT * FROM secret_state WHERE computer_key=$key;") $db)
        $prev=if($old.Count){$old[0]}else{$null}
        # KeepKnown (BitLocker presence of an OU where nothing was visible): a key count already read for this computer
        # is never replaced by the zero of a read that saw nothing.
        if($null -ne $r.PSObject.Properties['KeepKnown'] -and [bool]$r.KeepKnown -and [int]$r.BitLockerKeys -eq 0 -and $null -ne $prev -and [int]$prev.bitlocker_keys -gt 0){continue}
        # BitLocker not read (-1, a LAPS read alone): the previous count, or -1 (unknown) for a first row, never 0.
        $keys=if([int]$r.BitLockerKeys -lt 0){if($null -ne $prev){[int]$prev.bitlocker_keys}else{-1}}else{[int]$r.BitLockerKeys}
        $last=if([int]$r.BitLockerKeys -lt 0){[string]$prev.bitlocker_last}else{[string]$r.BitLockerLast}
        $scheme=if([string]$r.LapsScheme){[string]$r.LapsScheme}else{[string]$prev.laps_scheme}
        $expiry=if([string]$r.LapsScheme){[string]$r.LapsExpiry}else{[string]$prev.laps_expiry}
        $values=@(([string]$r.Computer).ToUpperInvariant(),[string]$r.Computer,[string]$r.At,$keys,$last,$scheme,$expiry,[string]$r.Verdict,'Metadonnees sans secret')
        [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    }
  }elseif($i.Kind -eq 'FleetSnapshot'){
    # Daily local snapshot of the directory figures of the displayed OU (FO-10): the first of the day is kept,
    # history older than 400 days is dropped. No network, no directory value beyond the counts.
    $r=$i.Row
    $scopeKey=[string]$r.ScopeKey;$day=[string]$r.Day;$figures=[string]$r.Figures
    if(-not $scopeKey -or $scopeKey.Length -gt 4096 -or $day -notmatch '^\d{4}-\d{2}-\d{2}$' -or $figures.Length -gt 4096){throw 'Instantane du parc invalide.'}
    [void](Invoke-DomeniaDbExec 'CREATE TABLE IF NOT EXISTS fleet_snapshots(scope_key TEXT NOT NULL,snapshot_day TEXT NOT NULL,taken_at TEXT,scope_dn TEXT,machines INTEGER DEFAULT 0,figures TEXT,PRIMARY KEY(scope_key,snapshot_day));' $db)
    $values=@($scopeKey,$day,[string]$r.TakenAt,[string]$r.ScopeDn,[int]$r.Machines,$figures)
    [void](Invoke-DomeniaDbExec ('INSERT OR IGNORE INTO fleet_snapshots(scope_key,snapshot_day,taken_at,scope_dn,machines,figures) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    [void](Invoke-DomeniaDbExec "DELETE FROM fleet_snapshots WHERE snapshot_day < date('now','-400 days');" $db)
  }elseif($i.Kind -in @('Presence','UserScan','Park','Sample')){
    $r=$i.Row;$columns='';$table='';$values=@();$verb='INSERT OR REPLACE'
    switch([string]$i.Kind){
      'Presence' {$table='presence_cache';$columns='object_key,state,target,checked_at';$values=@([string]$r.Key,[string]$r.State,[string]$r.Target,[string]$r.At)}
      'UserScan' {$table='user_scan_history';$columns='login_key,login,scanned_at,scanned,candidates,reachable,probed,found';$values=@(([string]$r.Login).ToLowerInvariant(),[string]$r.Login,[string]$r.At,[int][bool]$r.Scanned,[int]$r.Candidates,[int]$r.Reachable,[int]$r.Probed,[string]$r.Found)}
      'Park' {$table='park_state';$columns='computer_key,computer,last_probe,status,user_login,attempts';$values=@([string]$r.Key,[string]$r.Computer,[string]$r.LastProbe,[string]$r.Status,[string]$r.User,[int]$r.Attempts)}
      'Sample' {$verb='INSERT';$table='operation_runs';$columns='operation,mode,item_count,duration_ms,bytes_estimated,ad_queries,remote_attempts,fallback_tasks,success_count,failure_count,started_at,finished_at,notes';$values=@([string]$r.Operation,[string]$r.Mode,[int]$r.ItemCount,[long]$r.DurationMs,[long]$r.BytesEstimated,[int]$r.AdQueries,[int]$r.RemoteAttempts,[int]$r.FallbackTasks,[int]$r.SuccessCount,[int]$r.FailureCount,[string]$r.StartedAt,[string]$r.Finished,'')}
    }
    [void](Invoke-DomeniaDbExec ($verb+' INTO '+$table+'('+$columns+') VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
  }elseif($i.Kind -eq 'IndexBulk'){
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
    $sqlBatch=[Text.StringBuilder]::new()

    # Computer facts read with the index (decision David 2026-10-08): emptied with it, refilled in this transaction.
    [void](Invoke-DomeniaDbExec 'CREATE TABLE IF NOT EXISTS ad_computer_facts(object_guid TEXT PRIMARY KEY,object_key TEXT,os_version TEXT,when_created TEXT,pwd_last_set TEXT,laps_kind TEXT,laps_expiry TEXT,read_at TEXT);' $db)
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
          [void]$sqlBatch.Append(('INSERT INTO temp.index_seen(guid,dn) VALUES('+(ConvertTo-DomeniaSqlLiteral ([string]$r.Guid))+','+(ConvertTo-DomeniaSqlLiteral ([string]$r.DN))+');'))
        }
        if($isIdentity){
          $identityCount++
          if(($identityCount % 256) -eq 0){[void](Invoke-DomeniaDbExec $sqlBatch.ToString() $db);[void]$sqlBatch.Clear()}
          continue
        }
      }
      if($null -eq $r -or [string]$r.Type -notin @('Machine','Utilisateur') -or -not [string]$r.DN -or -not [string]$r.Name){throw 'Identite manquante dans un enregistrement index.'}
      $readCount++
      $key=([string]$r.Guid).ToLowerInvariant();if(-not $key){$key=([string]$r.Type+'|'+[string]$r.DN).ToLowerInvariant()}
      $rowGuard=''
      if($null -ne $reconcile){
        $keySql=ConvertTo-DomeniaSqlLiteral $key
        $cutoff=ConvertTo-DomeniaSqlLiteral ($started.ToUniversalTime().ToString('o'))
        [void]$sqlBatch.Append(('INSERT INTO temp.index_batch(object_key) SELECT '+$keySql+' WHERE NOT EXISTS(SELECT 1 FROM ad_objects WHERE object_key='+$keySql+' AND julianday(synced_at)>julianday('+$cutoff+'));'))
        $rowGuard=' WHERE '+$keySql+' IN (SELECT object_key FROM temp.index_batch)'
      }
      $search=([string]$r.Name+' '+[string]$r.Login+' '+[string]$r.Upn+' '+[string]$r.Display+' '+[string]$r.Description+' '+[string]$r.Extra).ToLowerInvariant()
      $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,$search,[string]$bulk.Server,[string]$bulk.At)
      [void]$sqlBatch.Append(('INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) SELECT '+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+$rowGuard+';'))
      if([string]$r.Type -eq 'Machine' -and [string]$r.Guid -and $null -ne $r.PSObject.Properties['Facts'] -and [bool]$r.Facts){
        $facts=@(([string]$r.Guid).ToLowerInvariant(),$key,[string]$r.OsVersion,[string]$r.WhenCreated,[string]$r.PwdLastSet,[string]$r.LapsKind,[string]$r.LapsExpiry,[string]$bulk.At)
        [void]$sqlBatch.Append(('INSERT OR REPLACE INTO ad_computer_facts(object_guid,object_key,os_version,when_created,pwd_last_set,laps_kind,laps_expiry,read_at) SELECT '+(($facts|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+$rowGuard+';'))
      }
      if(($readCount % 256) -eq 0){[void](Invoke-DomeniaDbExec $sqlBatch.ToString() $db);[void]$sqlBatch.Clear();if($null -ne $progress){$progress.Count=$readCount}}
    }
    if($sqlBatch.Length){[void](Invoke-DomeniaDbExec $sqlBatch.ToString() $db)}
    if($null -ne $transfer -and $readCount -ne [long]$transfer.RowCount){throw 'Nombre de lignes du lot index incoherent : transaction annulee.'}
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
        [void]$sqlBatch.Clear();$reconciled=0
        foreach($candidate in $candidates){
          $keySql=ConvertTo-DomeniaSqlLiteral ([string]$candidate.object_key)
          if([string]$candidate.current_dn){
            if($reconcile.Mode -eq 'Census' -and [string]$candidate.distinguished_name -ine [string]$candidate.current_dn){[void]$sqlBatch.Append(('UPDATE ad_objects SET distinguished_name='+(ConvertTo-DomeniaSqlLiteral ([string]$candidate.current_dn))+' WHERE object_key='+$keySql+';'))}
          }elseif(Test-IndexDnInScope ([string]$candidate.distinguished_name) ([string]$reconcile.ScopeDn) ([string]$reconcile.SearchScope)){
            [void]$sqlBatch.Append(('DELETE FROM ad_computer_facts WHERE object_key='+$keySql+';DELETE FROM ad_objects WHERE object_key='+$keySql+';'))
          }
          $reconciled++
          if(($reconciled % 256) -eq 0 -and $sqlBatch.Length){[void](Invoke-DomeniaDbExec $sqlBatch.ToString() $db);[void]$sqlBatch.Clear()}
        }
        if($sqlBatch.Length){[void](Invoke-DomeniaDbExec $sqlBatch.ToString() $db)}
      }
    }elseif($null -ne $transfer -and $null -ne $transfer.PSObject.Properties['CensusRowCount'] -and [long]$transfer.CensusRowCount -ne 0){throw 'Recensement sans perimetre : transaction annulee.'}
    # Only a complete domain delta can certify unchanged facts. An OU or interrupted pass cannot do so.
    if(-not $bulk.ReplaceAll -and $complete -and $isDirectoryScope -and $previousSync.Count -and [string]$previousSync[0].v){[void](Invoke-DomeniaDbExec ('UPDATE ad_computer_facts SET read_at='+(ConvertTo-DomeniaSqlLiteral ([string]$bulk.At))+' WHERE COALESCE(read_at,'''')>='+(ConvertTo-DomeniaSqlLiteral ([string]$previousSync[0].v))+' AND julianday(read_at)<=julianday('+(ConvertTo-DomeniaSqlLiteral ([string]$bulk.At))+');') $db)}
    $total=[long](@(Invoke-DomeniaDbQuery 'SELECT count(*) AS n FROM ad_objects;' $db)[0].n)
    $details='async'
    if (-not [string]::IsNullOrWhiteSpace([string]$bulk.InvocationId)) { $details='inv='+[string]$bulk.InvocationId }
    # Attempts are separate from successful coverage and its checkpoint. A failed attempt never rejuvenates it.
    $attempt=@(('attempt:'+$syncScope),[string]$bulk.Server,[string]$bulk.BaseDn,[long]0,[string]$bulk.At,$readCount,$(if($complete){'complete'}else{'partial'}))
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($attempt|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    if(-not $complete){continue}
    $scopeCount=if($isDirectoryScope){$total}else{$readCount}
    $values=@($syncScope,[string]$bulk.Server,[string]$bulk.BaseDn,[long]$bulk.HighestUsn,[string]$bulk.At,$scopeCount,$details)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
    } finally {
      if($null -ne $progress){$progress.Count=$readCount;$progress.Phase='Attente'}
      if($null -ne $reader){$reader.Dispose()}elseif($null -ne $stream){$stream.Dispose()}
      if($null -ne $hashAlgorithm){$hashAlgorithm.Dispose()}
    }
  }else{throw 'Type stockage non autorise.'}
 }
 [void](Invoke-DomeniaDbExec 'DELETE FROM operation_runs WHERE id NOT IN (SELECT id FROM operation_runs ORDER BY id DESC LIMIT 10000);' $db)
 # User request 2026-10-04: association history is retained; only explicit History purge removes it.
 [void](Invoke-DomeniaDbExec 'COMMIT;' $db);$transaction=$false
 [pscustomobject]@{Saved=$true;Conflicts=$conflicts.ToArray();Count=@($Payload.Items).Count;Already=0;Imported=0;ImportedLinks=@()}
} finally {if($transaction){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}};if($db -ne [IntPtr]::Zero){Close-DomeniaDatabase $db}}
'@
}

function Get-DomeniaStorageUsageWorkerCode {
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
        Observations=@('adcc_live_observations','presence_cache','park_state','park_session_cache')
        Snapshots=@('adcc_live_queries')
        History=@('user_machine_history','user_scan_history','operation_runs','fleet_snapshots')
        Index=@('ad_objects','domenia_provenance','sync_state','ad_computer_facts')
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
            if($table -in @('park_session_cache','ad_computer_facts','fleet_snapshots') -and -not $existing.ContainsKey($table)){$rows=0L;$bytes=0L}
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
    [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
    return [pscustomobject]@{
        Kind='StorageUsage';Path=$path;MeasuredUtc=[datetime]::UtcNow.ToString('o');DurationMs=$watch.ElapsedMilliseconds
        DatabaseBytes=(Get-DomeniaMeasuredFileSize $path);WalBytes=(Get-DomeniaMeasuredFileSize ($path+'-wal'))
        PageSize=$pageSize;PageCount=$pages;FreePages=$freePages;ReusableBytes=($pageSize*$freePages)
        DbstatAvailable=$dbstat;Categories=$usage.ToArray();ReadOnly=$true
    }
} finally {if($db -ne [IntPtr]::Zero){Close-DomeniaDatabase $db};$watch.Stop()}

'@
}

function Get-DomeniaStoragePurgeWorkerCode {
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
        $flags = if ($ReadOnly) { 1 -bor 65536 } else { 2 -bor 65536 }
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
                foreach($table in @('adcc_live_observations','presence_cache','park_state','park_session_cache')){$targets.Add([pscustomobject]@{Category=$category;Table=$table;Action='Delete';Where='1=1'})}
            }
            Snapshots {$targets.Add([pscustomobject]@{Category=$category;Table='adcc_live_queries';Action='Delete';Where='1=1'})}
            History {
                $literal=ConvertTo-DomeniaSqlLiteral $cutoff
                $sources="('manual','saisie manuelle','import csv')"
                $protect="lower(trim(COALESCE(source,''))) NOT IN $sources AND lower(trim(COALESCE(computer_key,''))) NOT IN (SELECT lower(trim(COALESCE(computer_key,''))) FROM user_machine_links WHERE lower(trim(COALESCE(source,''))) IN $sources)"
                $targets.Add([pscustomobject]@{Category=$category;Table='user_machine_history';Action='Delete';Where=("julianday(observed_at) IS NOT NULL AND julianday(observed_at)<julianday($literal) AND $protect")})
                $targets.Add([pscustomobject]@{Category=$category;Table='user_scan_history';Action='Delete';Where=("julianday(scanned_at) IS NOT NULL AND julianday(scanned_at)<julianday($literal)")})
                $targets.Add([pscustomobject]@{Category=$category;Table='operation_runs';Action='Delete';Where=("julianday(finished_at) IS NOT NULL AND julianday(finished_at)<julianday($literal)")})
                $targets.Add([pscustomobject]@{Category=$category;Table='fleet_snapshots';Action='Delete';Where=("julianday(snapshot_day) IS NOT NULL AND julianday(snapshot_day)<julianday($literal)")})
            }
            Index {
                foreach($table in @('ad_objects','domenia_provenance','ad_computer_facts')){$targets.Add([pscustomobject]@{Category=$category;Table=$table;Action='Delete';Where='1=1'})}
                $targets.Add([pscustomobject]@{Category=$category;Table='sync_state';Action='Reset';Where="scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%'"})
            }
        }
    }
    $counts=New-Object 'System.Collections.Generic.List[object]'
    foreach($target in $targets){
        $n=0L;$exists=$tables.ContainsKey($target.Table)
        if($exists){$n=[long](@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM '+$target.Table+' WHERE '+$target.Where+';') $db)[0].n)}
        elseif($target.Table -notin @('adcc_live_observations','adcc_live_queries','park_session_cache','ad_computer_facts','fleet_snapshots')){throw ('Table locale requise absente : '+$target.Table)}
        $counts.Add([pscustomobject]@{Category=$target.Category;Table=$target.Table;Action=$target.Action;Rows=$n;Exists=$exists})
    }
    # Bind confirmation to the categories, fixed cutoff, path and freshly recounted rows.
    $basis=[ordered]@{Path=$path.ToUpperInvariant();Selection=@($selection|Sort-Object);HistoryCutoffUtc=$cutoff;Counts=$counts.ToArray()}
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
        [void](Invoke-DomeniaDbExec 'COMMIT;' $db)
    }else{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}
    $transaction=$false
    return [pscustomobject]@{Kind='StoragePurge';Path=$path;DryRun=$dryRun;Committed=(-not $dryRun);Selection=@($selection|Sort-Object);HistoryCutoffUtc=$cutoff;Fingerprint=$fingerprint;Counts=$counts.ToArray();DeletedRows=$deleted;ResetRows=$reset;DurationMs=$watch.ElapsedMilliseconds}
}finally{
    if($db -ne [IntPtr]::Zero){if($transaction){try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)}catch{}};Close-DomeniaDatabase $db}
    $watch.Stop()
}

'@
}
function Get-DomeniaStorageBackupWorkerCode {
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

function Get-DomeniaDatabasePath {throw 'Chemin de base explicite requis pour la sauvegarde.'}
# StorageBackup (2026-10-08): consistent hot copy through the SQLite backup API, outside the Dispatcher (D014).
# The original is opened read-only and never modified; a partial copy is removed on failure.
$dbPath=[string]$Payload.Database;$backupDir=[string]$Payload.BackupDirectory;$copyTo=[string]$Payload.CopyTo
$budget=[Math]::Max(5,[Math]::Min(120,[int]$Payload.BudgetSeconds));$keep=[Math]::Max(2,[Math]::Min(30,[int]$Payload.Keep))
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
$dest=Join-Path $backupDir ('Domenia-'+$stamp+'.db');$temporary=$dest+'.partial'
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
    Get-ChildItem -LiteralPath $backupDir -Filter 'Domenia-*.db' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
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
    [pscustomobject]@{Backup=$dest;CopiedTo=$copyTo}
}
finally{
    if($backup -ne [IntPtr]::Zero){[void][Domenia.WinSqliteNative]::sqlite3_backup_finish($backup)}
    Close-DomeniaDatabase $targetDb;Close-DomeniaDatabase $sourceDb
    if($mainPtr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($mainPtr)}
    if($exportTemporary){Remove-Item -LiteralPath $exportTemporary -Force -ErrorAction SilentlyContinue}
    if(-not $complete){foreach($suffix in @('','-wal','-shm','-journal')){Remove-Item -LiteralPath ($temporary+$suffix) -Force -ErrorAction SilentlyContinue}}
}
'@
}
