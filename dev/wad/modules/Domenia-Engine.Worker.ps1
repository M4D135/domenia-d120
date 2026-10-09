# D014 worker bodies: local reads that used to block the Dispatcher. Each function returns ONE single-quoted
# here-string (ASCII body) pinned by SHA-256 in the closed worker registry. They receive $Context and $Payload.

function Get-DomeniaLocalIndexReadWorkerCode {
    # LocalIndexRead: read-only SQLite access with a short busy timeout. A locked base returns Busy=$true,
    # never an empty answer presented as a result.
    return @'
$action = [string]$Payload.Action
if ($action -notin @('Search','ParkState','ParkTargets','FleetStats','ResolveNames')) { throw 'Lecture locale non autorisee.' }
$path = [IO.Path]::GetFullPath([string]$Payload.Path)
if ($path.StartsWith('\\')) { throw 'Base locale reseau non prise en charge.' }
if (-not [IO.File]::Exists($path)) { return [pscustomobject]@{ Rows=@(); Busy=$false; Missing=$true; MachineCount=0 } }
$busyMs = [Math]::Max(10,[Math]::Min(1000,[int]$Payload.BusyTimeoutMs))
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
        while (($step = [Domenia.WinSqliteNative]::sqlite3_step($stmt)) -eq 100) {
            $o = [ordered]@{}
            for ($i = 0; $i -lt $count; $i++) {
                $name = ConvertFrom-IdxWUtf8 ([Domenia.WinSqliteNative]::sqlite3_column_name($stmt,$i))
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
$db = [IntPtr]::Zero
try {
    $pathPtr = New-IdxWUtf8 $path
    try { $rc = [Domenia.WinSqliteNative]::sqlite3_open_v2($pathPtr,[ref]$db,(1 -bor 65536),[IntPtr]::Zero) }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($pathPtr) }
    if ($rc -ne 0 -or $db -eq [IntPtr]::Zero) { throw ('Ouverture SQLite en lecture impossible (code ' + $rc + ').') }
    [void][Domenia.WinSqliteNative]::sqlite3_busy_timeout($db,$busyMs)
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
        [pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=0; IndexCount=$count; Users=$users.ToArray(); Computers=$computers.ToArray() }
        return
    }
    if ($action -eq 'ParkTargets') {
        $schema=@(Invoke-IdxWQuery $db "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');")
        if(@($schema|Where-Object{$_.key -eq 'schema_version' -and $_.value -ceq '11'}).Count -ne 1 -or @($schema|Where-Object{$_.key -eq 'domenia_schema' -and $_.value -ceq '1'}).Count -ne 1){throw 'Schema du parc incompatible.'}
        $source=if([string]$Payload.Scope -eq 'Results'){@($Payload.Targets)}else{@(Invoke-IdxWQuery $db "SELECT name,distinguished_name,object_guid FROM ad_objects WHERE object_type='Machine' AND (state IS NULL OR state<>'Desactive') ORDER BY name COLLATE NOCASE;")}
        $cacheSql='SELECT object_key,payload FROM park_session_cache'
        $usersSql="SELECT object_guid,usn_changed,distinguished_name,login FROM ad_objects WHERE object_type='Utilisateur'"
        if([string]$Payload.Scope -eq 'Results'){
            if(@($source).Count -gt 20000){throw 'Perimetre affiche trop grand (20 000 postes au plus).'}
            $keys=@($source|ForEach-Object{Get-IdxWLiteral (([string]$_.distinguished_name).ToLowerInvariant())})
            if(-not $keys.Count){[pscustomobject]@{Rows=@();Busy=$false;Missing=$false;MachineCount=0};return}
            $cacheSql+=' WHERE object_key IN ('+($keys -join ',')+')'
        }
        $cache=@{}
        if(@(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table' AND name='park_session_cache';").Count){
            foreach($item in @(Invoke-IdxWQuery $db $cacheSql)){
                if(([string]$item.payload).Length -gt 262144){continue}
                try{$observation=([string]$item.payload)|ConvertFrom-Json -ErrorAction Stop;if([string]$observation.Key -ieq [string]$item.object_key){$cache[[string]$item.object_key]=$observation}}catch{}
            }
        }
        $users=@{};$usersByDn=@{};$usersByLogin=@{}
        if([string]$Payload.Scope -eq 'Results'){
            $conditions=New-Object 'System.Collections.Generic.List[string]'
            foreach($pair in @(@('UserGuid','object_guid'),@('UserDn','distinguished_name'),@('LinkUser','login'))){
                $field=[string]$pair[0]
                $values=@($cache.Values|Where-Object{$_.$field}|ForEach-Object{Get-IdxWLiteral ([string]$_.$field)})
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
            $seen[$key]=$true;$previous=$cache[$key]
            if($null -ne $previous -and [string]$previous.Guid -ine $guid){$previous=$null}
            if($null -ne $previous){
                $user=$users[[string]$previous.UserGuid]
                $oldUsn=0L;$validUsn=[long]::TryParse([string]$previous.UserUsn,[ref]$oldUsn)
                $changed=(-not $validUsn -or ($null -ne $user -and ([string]$user.distinguished_name -ine [string]$previous.UserDn -or [long]$user.usn_changed -gt $oldUsn)))
                # A known reused DN or login belongs to a new user even if the old GUID is absent.
                foreach($field in @('UserDn','LinkUser')){
                    $set=$null
                    if($field -eq 'UserDn'){$set=$usersByDn[[string]$previous.UserDn]}else{$set=$usersByLogin[[string]$previous.LinkUser]}
                    if($null -ne $set -and ($set.Count -ne 1 -or -not $set.Contains([string]$previous.UserGuid))){$changed=$true}
                }
                $previous|Add-Member -NotePropertyName DirectoryChanged -NotePropertyValue $changed -Force
            }
            $targets.Add([pscustomobject]@{Key=$key;Computer=$name;Guid=$guid;Previous=$previous})
        }
        [pscustomobject]@{Rows=$targets.ToArray();Busy=$false;Missing=$false;MachineCount=$targets.Count};return
    }
    if ($action -eq 'FleetStats') {
        # Aggregates of the local index for the home dashboard (decision David 2026-10-07). Read only.
        # The scope is the OU chosen in Rechercher (decision David 2026-10-08): workstations are filtered and cached
        # observations parsed here, off the interface thread, which only aggregates the workstations of the OU.
        $scope = ([string]$Payload.Scope).Trim()
        $subtree = ($null -eq $Payload.PSObject.Properties['Subtree'] -or [bool]$Payload.Subtree)
        $types = @(Invoke-IdxWQuery $db "SELECT object_type AS t, CASE WHEN state='Desactive' THEN 'Desactive' ELSE 'Actif' END AS s, count(*) AS n FROM ad_objects GROUP BY 1,2;")
        $machines = New-Object 'System.Collections.Generic.List[object]'
        foreach ($machine in @(Invoke-IdxWQuery $db "SELECT name, object_guid, extra, last_logon, distinguished_name FROM ad_objects WHERE object_type='Machine' AND (state IS NULL OR state<>'Desactive');")) {
            $dn = ([string]$machine.distinguished_name).Trim()
            if ($scope) {
                # Subtree: the OU and its sub-OUs; one level: the parent DN (first RDN removed, escaped commas kept) is the OU.
                if ($subtree) { if (-not ($dn -ieq $scope -or $dn.EndsWith(',' + $scope,[StringComparison]::OrdinalIgnoreCase))) { continue } }
                elseif (($dn -replace '^(?:[^,\\]|\\.)*,','') -ine $scope) { continue }
            }
            $machines.Add($machine)
        }
        $links = 0; $sources = @(); $presence = New-Object 'System.Collections.Generic.List[object]'
        try { $links = [int](@(Invoke-IdxWQuery $db 'SELECT count(*) AS n FROM user_machine_links;')[0].n) } catch { }
        try { $sources = @(Invoke-IdxWQuery $db 'SELECT source AS s, count(*) AS n FROM user_machine_links GROUP BY 1 ORDER BY 2 DESC LIMIT 6;') } catch { }
        if (@(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table' AND name='park_session_cache';").Count) {
            $cached = @()
            try { $cached = @(Invoke-IdxWQuery $db 'SELECT object_key, checked_utc, payload FROM park_session_cache;') } catch { }
            # Every observation is kept (the workstation board reads the selected one, whatever the OU); same size
            # limit as ParkTargets.
            foreach ($item in $cached) {
                if (([string]$item.payload).Length -gt 262144) { continue }
                $observation = $null
                try { $observation = ([string]$item.payload) | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if ($null -eq $observation) { continue }
                $presence.Add([pscustomobject]@{ object_key = [string]$item.object_key; checked_utc = [string]$item.checked_utc; observation = $observation })
            }
        }
        [pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=$machines.Count; Scope=$scope; Subtree=$subtree; Types=$types; Machines=$machines.ToArray(); Links=$links; LinkSources=$sources; Presence=$presence.ToArray() }
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
    if ($clean.Length -lt 2) { [pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=0 }; return }
    $limit = [Math]::Max(1,[Math]::Min(500,[int]$Payload.Limit))
    $like = $clean.Replace('!','!!').Replace('%','!%').Replace('_','!_')
    $termSql = Get-IdxWLiteral $clean
    $prefixSql = Get-IdxWLiteral ($like + '%')
    $containsSql = Get-IdxWLiteral ('%' + $like + '%')
    $sql = "SELECT object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,object_guid," +
        " CASE WHEN name=$termSql COLLATE NOCASE OR login=$termSql COLLATE NOCASE OR upn=$termSql COLLATE NOCASE THEN 100" +
        " WHEN name LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR login LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR upn LIKE $prefixSql ESCAPE '!' COLLATE NOCASE THEN 90" +
        " ELSE 70 END AS match_score FROM ad_objects WHERE name=$termSql COLLATE NOCASE OR login=$termSql COLLATE NOCASE OR upn=$termSql COLLATE NOCASE" +
        " OR name LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR login LIKE $prefixSql ESCAPE '!' COLLATE NOCASE OR upn LIKE $prefixSql ESCAPE '!' COLLATE NOCASE" +
        " OR search_key LIKE $containsSql ESCAPE '!' ORDER BY match_score DESC,name COLLATE NOCASE LIMIT $limit;"
    $seen = @{}
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in @(Invoke-IdxWQuery $db $sql)) {
        $dn = [string]$r.distinguished_name; $guid = [string]$r.object_guid
        $key = if (-not [string]::IsNullOrWhiteSpace($guid)) { $guid.ToLowerInvariant() } else { $dn.ToLowerInvariant() }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $score = [int]$r.match_score
        $reason = 'Contenu dans la fiche'
        if ($score -ge 100) { $reason = 'Correspondance exacte' } elseif ($score -ge 90) { $reason = 'Debut du nom' }
        $result.Add([pscustomobject]@{
            Type=[string]$r.object_type; Name=[string]$r.name; Login=[string]$r.login; Upn=[string]$r.upn; Display=[string]$r.display_name
            Description=[string]$r.description; Extra=[string]$r.extra; State=[string]$r.state; DN=$dn; WhenChanged=[string]$r.when_changed
            Usn=[long]$r.usn_changed; LastLogon=[string]$r.last_logon; Guid=$guid
            Key=(([string]$r.name+' '+[string]$r.login+' '+[string]$r.upn+' '+[string]$r.display_name+' '+[string]$r.description+' '+[string]$r.extra).ToLowerInvariant())
            NameKey=([string]$r.name).ToLowerInvariant(); LoginKey=([string]$r.login).ToLowerInvariant(); Score=$score; Reason=$reason
        })
    }
    [pscustomobject]@{ Rows=$result.ToArray(); Busy=$false; Missing=$false; MachineCount=0 }
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
