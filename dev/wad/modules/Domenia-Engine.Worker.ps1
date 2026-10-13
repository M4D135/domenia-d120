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
        $cache=@{};$identityReader=[Domenia.Native.ObservationIdentityReader]::new()
        if(@(Invoke-IdxWQuery $db "SELECT name FROM sqlite_master WHERE type='table' AND name='park_session_cache';").Count){
            foreach($item in @(Invoke-IdxWQuery $db $cacheSql)){
                if(([string]$item.payload).Length -gt 262144){continue}
                try{
                    $observation=$identityReader.Read([string]$item.payload)
                    if([string]$observation.Key -ieq [string]$item.object_key){$cache[[string]$item.object_key]=[pscustomobject]@{Identity=$observation;Json=[string]$item.payload}}
                }catch{}
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
            $types = @(Invoke-IdxWQuery $db "SELECT object_type AS t, CASE WHEN state='Desactive' THEN 'Desactive' ELSE 'Actif' END AS s, count(*) AS n FROM ad_objects GROUP BY 1,2;")
            $scopeSql = Get-IdxWDnScopeSql -Column 'a.distinguished_name' -Scope $scope -Subtree $subtree
            $factsJoin = ''; $factsCols = "'N' AS fx, NULL AS fv, NULL AS fc, NULL AS fp, NULL AS fk, NULL AS fe, NULL AS fr"
            if ($tables.ContainsKey('ad_computer_facts')) {
                $factsJoin = ' LEFT JOIN ad_computer_facts f ON f.object_guid = lower(a.object_guid)'
                $factsCols = "CASE WHEN f.object_guid IS NULL THEN 'N' WHEN COALESCE(f.read_at,'') >= COALESCE((SELECT last_sync FROM sync_state WHERE scope='directory'),'') THEN 'F' ELSE 'S' END AS fx, f.os_version AS fv, f.when_created AS fc, f.pwd_last_set AS fp, f.laps_kind AS fk, f.laps_expiry AS fe, f.read_at AS fr"
            }
            $b = @($bounds | ForEach-Object { Get-IdxWLiteral $_ })
            $created = Get-IdxWLiteral ([string]$plan.CreatedSince); $pwdBefore = Get-IdxWLiteral ([string]$plan.PasswordBefore); $nowLit = Get-IdxWLiteral ([string]$plan.NowUtc)
            $cte = "WITH m AS (SELECT a.name AS name, a.distinguished_name AS dn, a.object_guid AS guid, CASE WHEN a.state='Desactive' THEN 'D' ELSE 'A' END AS st," +
                " CASE WHEN instr(COALESCE(a.extra,''),' / ')>0 THEN substr(a.extra,1,instr(a.extra,' / ')-1) ELSE COALESCE(a.extra,'') END AS os," +
                " CASE WHEN COALESCE(a.last_logon,'') GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]*' THEN substr(a.last_logon,7,4)||'-'||substr(a.last_logon,4,2)||'-'||substr(a.last_logon,1,2) ELSE '' END AS ld," +
                " $factsCols, s.computer_key AS sk, s.bitlocker_keys AS sb, s.checked_at AS sc, s.verdict AS sv" +
                " FROM ad_objects a$factsJoin LEFT JOIN secret_state s ON s.computer_key = upper(a.name) WHERE a.object_type='Machine' AND $scopeSql)," +
                " g AS (SELECT name, dn, guid, st, os, ld, fx, sc, fr, CASE WHEN fx='F' THEN COALESCE(fv,'') ELSE '' END AS ver," +
                " CASE WHEN ld='' THEN 5 WHEN ld > $($b[0]) THEN 0 WHEN ld > $($b[1]) THEN 1 WHEN ld > $($b[2]) THEN 2 WHEN ld > $($b[3]) THEN 3 ELSE 4 END AS lb," +
                " CASE WHEN fx<>'F' OR COALESCE(fc,'')='' THEN '' WHEN fc >= $created THEN 'R' ELSE 'O' END AS cr," +
                " CASE WHEN fx<>'F' OR COALESCE(fp,'')='' THEN '' WHEN fp < $pwdBefore THEN 'O' ELSE 'R' END AS pw," +
                " CASE WHEN fx<>'F' THEN '' WHEN fk='NoSchema' THEN 'X' WHEN fk IN ('Legacy','Windows') AND COALESCE(fe,'')<>'' THEN (CASE WHEN fe < $nowLit THEN 'E' ELSE 'O' END) WHEN fk='None' THEN 'N' ELSE '' END AS lk," +
                " CASE WHEN sk IS NULL THEN 'U' WHEN COALESCE(sb,-1) < 0 THEN 'U' WHEN sv='non disponible dans ce domaine' THEN 'X' WHEN COALESCE(sb,0) > 0 THEN 'K' ELSE 'N' END AS bk FROM m)," +
                " h AS (SELECT *, st||'|'||os||'|'||ver||'|'||lb||'|'||cr||'|'||pw||'|'||lk||'|'||bk AS k FROM g) "
            # GROUP BY k is case sensitive (BINARY): the group ids are looked up the same way, never without the case.
            $gids = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            foreach ($group in @(Invoke-IdxWQuery $db ($cte + 'SELECT k, st, os, ver, lb, cr, pw, lk, bk, count(*) AS n FROM h GROUP BY k;'))) {
                $gids[[string]$group.k] = [string]($groups.Count + 1)
                $groups.Add([pscustomobject]@{ gid = $gids[[string]$group.k]; st = [string]$group.st; os = [string]$group.os; ver = [string]$group.ver; lb = [int]$group.lb; cr = [string]$group.cr; pw = [string]$group.pw; lk = [string]$group.lk; bk = [string]$group.bk; n = [int]$group.n })
            }
            # One text cell per workstation (fields never hold a tab: the index replaces them): thousands of rows are read
            # without one native call per cell.
            foreach ($machine in @(Invoke-IdxWQuery $db ($cte + "SELECT COALESCE(name,'')||char(9)||COALESCE(dn,'')||char(9)||COALESCE(guid,'')||char(9)||st||char(9)||k||char(9)||ld AS r FROM h ORDER BY name COLLATE NOCASE;"))) {
                $cells = ([string]$machine.r).Split([char]9)
                if ($cells.Count -lt 6) { continue }
                $gid = ''; [void]$gids.TryGetValue([string]$cells[4],[ref]$gid)
                $row = [pscustomobject]@{ name = $cells[0]; distinguished_name = $cells[1]; object_guid = $cells[2]; gid = [string]$gid; st = $cells[3]; logon = $cells[5] }
                $machines.Add($row)
                if ($cells[3] -ne 'D') { $targets.Add($row); $byDn[$cells[1].ToLowerInvariant()] = $row }
            }
            $parentPosition="instr($(Get-IdxWDnSeparators 'dn'),',')"
            $parents = @(Invoke-IdxWQuery $db ($cte + "SELECT CASE WHEN $parentPosition>0 THEN substr(dn,$parentPosition+1) ELSE '' END AS p, count(*) AS n FROM g WHERE st<>'D' GROUP BY 1;"))
            $coverageRow = @(Invoke-IdxWQuery $db ($cte + "SELECT sum(CASE WHEN bk<>'U' THEN 1 ELSE 0 END) AS br, max(CASE WHEN bk<>'U' THEN sc END) AS ba, sum(CASE WHEN fx='F' THEN 1 ELSE 0 END) AS ff, sum(CASE WHEN fx='S' THEN 1 ELSE 0 END) AS fs, max(fr) AS fa FROM g WHERE st<>'D';"))
            if ($coverageRow.Count) { $c0 = $coverageRow[0]; $coverage = [pscustomobject]@{ BitLockerRead = [int]$c0.br; BitLockerAt = [string]$c0.ba; FactsFresh = [int]$c0.ff; FactsStale = [int]$c0.fs; FactsAt = [string]$c0.fa } }
        }
        $active = $targets.Count
        $links = 0; $sources = @(); $presence = New-Object 'System.Collections.Generic.List[object]'
        try { $links = [int](@(Invoke-IdxWQuery $db 'SELECT count(*) AS n FROM user_machine_links;')[0].n) } catch { }
        try { $sources = @(Invoke-IdxWQuery $db 'SELECT source AS s, count(*) AS n FROM user_machine_links GROUP BY 1 ORDER BY 2 DESC LIMIT 6;') } catch { }
        if ($tables.ContainsKey('park_session_cache')) {
            # Explicit keys outside the OU (selected workstation): looked up as active workstations, never in scope.
            $wanted = New-Object 'System.Collections.Generic.List[string]'
            foreach ($key in @($byDn.Keys)) { $wanted.Add([string]$key) }
            $extra = @(@($Payload.Keys) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ -and -not $byDn.ContainsKey($_) } | Select-Object -First 20)
            if ($extra.Count) {
                foreach ($row in @(Invoke-IdxWQuery $db ("SELECT name, distinguished_name, object_guid FROM ad_objects WHERE object_type='Machine' AND (state IS NULL OR state<>'Desactive') AND distinguished_name COLLATE NOCASE IN (" + (@($extra | ForEach-Object { Get-IdxWLiteral $_ }) -join ',') + ');'))) {
                    $key = ([string]$row.distinguished_name).ToLowerInvariant()
                    if ($byDn.ContainsKey($key)) { continue }
                    $byDn[$key] = [pscustomobject]@{ name = [string]$row.name; distinguished_name = [string]$row.distinguished_name; object_guid = [string]$row.object_guid; gid = ''; st = 'A'; logon = ''; outside = $true }
                    $wanted.Add($key)
                }
            }
            $since = Get-IdxWLiteral ([string]$plan.ObservationsSince)
            for ($start = 0; $start -lt $wanted.Count; $start += 500) {
                $chunk = @($wanted.GetRange($start,[Math]::Min(500,$wanted.Count - $start)) | ForEach-Object { Get-IdxWLiteral $_ })
                foreach ($item in @(Invoke-IdxWQuery $db ('SELECT object_key, checked_utc, payload FROM park_session_cache WHERE checked_utc >= ' + $since + ' AND object_key IN (' + ($chunk -join ',') + ');'))) {
                    if (([string]$item.payload).Length -gt 262144) { $observationRejected++;continue }
                    $owner = $byDn[([string]$item.object_key).ToLowerInvariant()]
                    if ($null -eq $owner) { continue }
                    $observation = $null
                    try { $observation = $observationReader.Read([string]$item.payload,$observationNow) } catch { $observationRejected++;continue }
                    if ($null -eq $observation) { continue }
                    # A moved, deleted or recreated workstation does not inherit the observation of its DN.
                    $guidProperty = $observation.PSObject.Properties['Guid']
                    if (($null -eq $guidProperty) -or (-not [string]$guidProperty.Value) -or ([string]$guidProperty.Value -ine [string]$owner.object_guid)) { $observationRejected++;continue }
                    $outside = ($null -ne $owner.PSObject.Properties['outside'])
                    $presence.Add([pscustomobject]@{ object_key = ([string]$item.object_key).ToLowerInvariant(); checked_utc = [string]$item.checked_utc; observation = $observation; gid = [string]$owner.gid; name = [string]$owner.name; distinguished_name = [string]$owner.distinguished_name; object_guid = [string]$owner.object_guid; in_scope = (-not $outside) })
                }
            }
        }
        $history = @()
        if ((-not $observationsOnly) -and $tables.ContainsKey('fleet_snapshots') -and [string]$Payload.ScopeKey) {
            $history = @(Invoke-IdxWQuery $db ('SELECT snapshot_day AS day, figures FROM fleet_snapshots WHERE scope_key = ' + (Get-IdxWLiteral ([string]$Payload.ScopeKey)) + ' AND snapshot_day >= ' + (Get-IdxWLiteral ([string]$plan.HistorySince)) + ' ORDER BY snapshot_day;'))
        }
        # Dates and population come from the same SQLite snapshot, never from mutable UI metadata or computation time.
        $syncStates=@{}
        if($tables.ContainsKey('sync_state')){foreach($sync in @(Invoke-IdxWQuery $db "SELECT scope,base_dn,last_sync,details FROM sync_state WHERE scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%';")){$syncStates[[string]$sync.scope]=$sync}}
        $snapshotAtUtc=[datetime]::UtcNow.ToString('o')
        [void](Invoke-IdxWQuery $db 'COMMIT;')
        $domainDn=if($null -ne $Payload.PSObject.Properties['DomainDn']){[string]$Payload.DomainDn}else{''}
        $result=[pscustomobject]@{ Rows=@(); Busy=$false; Missing=$false; MachineCount=$active; ObservationRejected=$observationRejected; Scope=$scope; Subtree=$subtree; Types=$types; Groups=$groups.ToArray(); Machines=$machines.ToArray(); Targets=$targets.ToArray(); Parents=$parents; Coverage=$coverage; Links=$links; LinkSources=$sources; Presence=$presence.ToArray(); History=$history; SyncStates=$syncStates; SnapshotAtUtc=$snapshotAtUtc; DomainDn=$domainDn }
        if(-not $observationsOnly -and $null -ne $Payload.PSObject.Properties['ComputeBoard'] -and [bool]$Payload.ComputeBoard){
            # Aggregation over thousands of observations stays in the worker, never in the WPF callback.
            foreach($module in @('Domenia-Common.Model.ps1','Domenia-Boards.Model.ps1','Domenia-BoardFleet.Model.ps1')){. (Join-Path ([string]$Payload.ModuleRoot) $module)}
            $board=Get-DomeniaFleetBoardData -Result $result -Scope $scope -Subtree $subtree -Now ([datetime]::Parse([string]$plan.NowUtc,[Globalization.CultureInfo]::InvariantCulture)) -Lifecycle $Payload.Lifecycle -ObservationMaxAgeDays ([int]$Payload.ObservationMaxAgeDays) -IndexPartial ([string]$Payload.IndexPartial)
            $board.Freshness.ComputedAtUtc=[datetime]::UtcNow
            $result|Add-Member -NotePropertyName Board -NotePropertyValue $board
        }
        $result
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
