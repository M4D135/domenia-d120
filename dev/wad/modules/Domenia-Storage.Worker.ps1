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
    $values=@($key,[string]$r.Guid,[string]$r.Type,[string]$r.Name,[string]$r.Login,[string]$r.Upn,[string]$r.Display,[string]$r.Description,[string]$r.Extra,[string]$r.State,[string]$r.DN,[string]$r.WhenChanged,[long]$r.Usn,[string]$r.LastLogon,(([string]$r.Name+' '+[string]$r.Login+' '+[string]$r.UPN+' '+[string]$r.Description+' '+[string]$r.Display).ToLowerInvariant()),[string]$i.Server,[string]$i.At)
    $sql='INSERT OR REPLACE INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');'
    [void](Invoke-DomeniaDbExec $sql $db)
  } elseif($i.Kind -eq 'Link'){
    [void](Invoke-DomeniaLinkWrite -DatabaseHandle $db -Key ([string]$i.Key) -Expected ([string]$i.Expected) -Row $i.Row -Remove ([bool]$i.Remove) -Conflicts $conflicts -ImportMode $false)
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
    $details='async'
    if (-not [string]::IsNullOrWhiteSpace([string]$bulk.InvocationId)) { $details='inv='+[string]$bulk.InvocationId }
    $values=@('directory',[string]$bulk.Server,[string]$bulk.BaseDn,[long]$bulk.HighestUsn,[string]$bulk.At,$total,$details)
    [void](Invoke-DomeniaDbExec ('INSERT OR REPLACE INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('+(($values|ForEach-Object{ConvertTo-DomeniaSqlLiteral $_}) -join ',')+');') $db)
  }else{throw 'Type stockage non autorise.'}
 }
 [void](Invoke-DomeniaDbExec 'DELETE FROM operation_runs WHERE id NOT IN (SELECT id FROM operation_runs ORDER BY id DESC LIMIT 10000);' $db)
 $protectedSources="('manual','saisie manuelle','import csv')"
 $pruneSql="DELETE FROM user_machine_history WHERE lower(trim(COALESCE(source,''))) NOT IN $protectedSources AND lower(trim(COALESCE(computer_key,''))) NOT IN (SELECT lower(trim(COALESCE(computer_key,''))) FROM user_machine_links WHERE lower(trim(COALESCE(source,''))) IN $protectedSources) AND id NOT IN (SELECT id FROM user_machine_history WHERE lower(trim(COALESCE(source,''))) NOT IN $protectedSources AND lower(trim(COALESCE(computer_key,''))) NOT IN (SELECT lower(trim(COALESCE(computer_key,''))) FROM user_machine_links WHERE lower(trim(COALESCE(source,''))) IN $protectedSources) ORDER BY id DESC LIMIT 20000);"
 [void](Invoke-DomeniaDbExec $pruneSql $db)
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
        Observations=@('adcc_live_observations','presence_cache','park_state')
        Snapshots=@('adcc_live_queries')
        History=@('user_machine_history','user_scan_history','operation_runs')
        Index=@('ad_objects','domenia_provenance','sync_state')
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
                foreach($table in @('adcc_live_observations','presence_cache','park_state')){$targets.Add([pscustomobject]@{Category=$category;Table=$table;Action='Delete';Where='1=1'})}
            }
            Snapshots {$targets.Add([pscustomobject]@{Category=$category;Table='adcc_live_queries';Action='Delete';Where='1=1'})}
            History {
                $literal=ConvertTo-DomeniaSqlLiteral $cutoff
                $sources="('manual','saisie manuelle','import csv')"
                $protect="lower(trim(COALESCE(source,''))) NOT IN $sources AND lower(trim(COALESCE(computer_key,''))) NOT IN (SELECT lower(trim(COALESCE(computer_key,''))) FROM user_machine_links WHERE lower(trim(COALESCE(source,''))) IN $sources)"
                $targets.Add([pscustomobject]@{Category=$category;Table='user_machine_history';Action='Delete';Where=("julianday(observed_at) IS NOT NULL AND julianday(observed_at)<julianday($literal) AND $protect")})
                $targets.Add([pscustomobject]@{Category=$category;Table='user_scan_history';Action='Delete';Where=("julianday(scanned_at) IS NOT NULL AND julianday(scanned_at)<julianday($literal)")})
                $targets.Add([pscustomobject]@{Category=$category;Table='operation_runs';Action='Delete';Where=("julianday(finished_at) IS NOT NULL AND julianday(finished_at)<julianday($literal)")})
            }
            Index {
                foreach($table in @('ad_objects','domenia_provenance')){$targets.Add([pscustomobject]@{Category=$category;Table=$table;Action='Delete';Where='1=1'})}
                $targets.Add([pscustomobject]@{Category=$category;Table='sync_state';Action='Reset';Where="scope='directory'"})
            }
        }
    }
    $counts=New-Object 'System.Collections.Generic.List[object]'
    foreach($target in $targets){
        $n=0L;$exists=$tables.ContainsKey($target.Table)
        if($exists){$n=[long](@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM '+$target.Table+' WHERE '+$target.Where+';') $db)[0].n)}
        elseif($target.Table -notin @('adcc_live_observations','adcc_live_queries')){throw ('Table locale requise absente : '+$target.Table)}
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
