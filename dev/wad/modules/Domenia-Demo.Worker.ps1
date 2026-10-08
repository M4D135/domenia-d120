# DemoDirectory worker (D002, D003): the in-memory directory answers in the exact shapes of the real readers.
# One single-quoted here-string, ASCII body, pinned by SHA-256 in the closed registry (LiteralIndex 0).

function Get-DomeniaDemoDirectoryWorkerCode {
    return @'
# DemoDirectory: no network, no disk, no credential. Unknown operations are refused explicitly.
if (-not [bool]$Context.DemoMode -or [string]$Context.OperationId -cne 'DemoDirectory' -or $null -ne $Context.Credential) { throw 'DOMENIA_DEMO_CONTEXT : contexte de demonstration invalide.' }
$directory = $Payload.Directory
if ($null -eq $directory -or [string]$directory.Format -cne 'DomeniaDemoDirectory/1') { throw 'DOMENIA_DEMO_CONTEXT : annuaire de demonstration absent.' }
$op = [string]$Payload.Operation
$req = $Payload.Request
$baseDn = [string]$directory.BaseDn
$baseKey = $baseDn.ToLowerInvariant()
$bindUser = ([string]$Context.BindUser).Trim()

function Get-DemoParentDn {
    param([string]$Dn)
    for ($i = 0; $i -lt $Dn.Length; $i++) {
        if ($Dn[$i] -eq [char]92) { $i++; continue }
        if ($Dn[$i] -eq [char]44) { return $Dn.Substring($i + 1) }
    }
    return ''
}
function Wait-DemoLatency {
    param($Token)
    $total = [Math]::Max(0,[Math]::Min(5000,[int]$directory.LatencyMs))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $total) {
        if ($null -ne $Token -and $Token.IsCancellationRequested) { throw 'Lecture remplacee ou arretee.' }
        Start-Sleep -Milliseconds 50
    }
}
function Test-DemoInBase {
    param([string]$Key)
    return ($Key -eq $baseKey -or $Key.EndsWith(',' + $baseKey))
}
function Test-DemoDenied {
    param($Item)
    foreach ($denied in @($Item.Denied)) { if ([string]$denied -and [string]$denied -ieq $bindUser) { return $true } }
    return $false
}
function ConvertFrom-DemoLdapValue {
    # \XX escapes are UTF-8 bytes; a raw * is a wildcard. Returns the list of literal segments.
    param([string]$Value)
    $segments = New-Object Collections.ArrayList
    $bytes = New-Object Collections.Generic.List[byte]
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if ($c -eq [char]42) { [void]$segments.Add([Text.Encoding]::UTF8.GetString($bytes.ToArray())); $bytes.Clear(); continue }
        if ($c -eq [char]92) {
            $hex = ''
            if ($i + 2 -le $Value.Length - 1) { $hex = $Value.Substring($i + 1,2) }
            $number = 0
            if ($hex.Length -eq 2 -and [int]::TryParse($hex,[Globalization.NumberStyles]::HexNumber,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { $bytes.Add([byte]$number); $i += 2; continue }
            throw ('Echappement LDAP invalide en demonstration : ' + $Value)
        }
        foreach ($b in [Text.Encoding]::UTF8.GetBytes([string]$c)) { $bytes.Add($b) }
    }
    [void]$segments.Add([Text.Encoding]::UTF8.GetString($bytes.ToArray()))
    return ,($segments.ToArray())
}
function Read-DemoFilter {
    param($State)
    $text = [string]$State.Text
    if ($State.Pos -ge $text.Length -or $text[$State.Pos] -ne [char]40) { throw ('Filtre LDAP non reconnu en demonstration : ' + $text) }
    $State.Pos++
    $c = [string]$text[$State.Pos]
    if ($c -eq '&' -or $c -eq '|' -or $c -eq '!') {
        $State.Pos++
        $children = New-Object Collections.ArrayList
        while ($State.Pos -lt $text.Length -and $text[$State.Pos] -eq [char]40) { [void]$children.Add((Read-DemoFilter $State)) }
        if ($State.Pos -ge $text.Length -or $text[$State.Pos] -ne [char]41) { throw ('Filtre LDAP non reconnu en demonstration : ' + $text) }
        $State.Pos++
        if ($c -eq '!' -and $children.Count -ne 1) { throw ('Filtre LDAP non reconnu en demonstration : ' + $text) }
        return [pscustomobject]@{ Op=$c; Children=$children.ToArray() }
    }
    $end = $text.IndexOf([char]41,$State.Pos)
    if ($end -lt 0) { throw ('Filtre LDAP non reconnu en demonstration : ' + $text) }
    $item = $text.Substring($State.Pos,$end - $State.Pos)
    $State.Pos = $end + 1
    $eq = $item.IndexOf('=')
    if ($eq -le 0) { throw ('Filtre LDAP non reconnu en demonstration : ' + $item) }
    $attr = $item.Substring(0,$eq)
    $raw = $item.Substring($eq + 1)
    # Ordered comparisons and the AD bitwise matching rules are used by the work views; ~= and other
    # extensible rules stay refused rather than answered approximately.
    $op = '='
    if ($attr.EndsWith('>') -or $attr.EndsWith('<')) { $op = $attr.Substring($attr.Length - 1) + '='; $attr = $attr.Substring(0,$attr.Length - 1) }
    elseif ($attr.Contains(':')) {
        $parts = $attr.Split(':')
        if ($parts.Count -ne 3 -or $parts[2] -ne '' -or $parts[1] -notin @('1.2.840.113556.1.4.803','1.2.840.113556.1.4.804')) { throw ('Operateur LDAP non pris en charge en demonstration : ' + $item) }
        $op = 'BitAnd'
        if ($parts[1] -eq '1.2.840.113556.1.4.804') { $op = 'BitOr' }
        $attr = $parts[0]
    }
    if ($attr.EndsWith('~') -or -not $attr) { throw ('Operateur LDAP non pris en charge en demonstration : ' + $item) }
    if ($op -ne '=') {
        if ($raw.Contains('*')) { throw ('Filtre LDAP non reconnu en demonstration : ' + $item) }
        return [pscustomobject]@{ Op=$op; Attr=$attr.ToLowerInvariant(); Presence=$false; Value=$raw; Segments=@($raw) }
    }
    return [pscustomobject]@{ Op='='; Attr=$attr.ToLowerInvariant(); Presence=($raw -eq '*'); Value=$raw; Segments=(ConvertFrom-DemoLdapValue $raw) }
}
function ConvertFrom-DemoFilter {
    param([string]$Text)
    $state = [pscustomobject]@{ Text=$Text.Trim(); Pos=0 }
    $node = Read-DemoFilter $state
    if ($state.Pos -ne $state.Text.Length) { throw ('Filtre LDAP non reconnu en demonstration : ' + $Text) }
    return $node
}
function Test-DemoText {
    param([string]$Value,[object[]]$Segments)
    $v = $Value.ToLowerInvariant()
    if ($Segments.Count -eq 1) { return ($v -eq ([string]$Segments[0]).ToLowerInvariant()) }
    $first = ([string]$Segments[0]).ToLowerInvariant()
    $last = ([string]$Segments[$Segments.Count - 1]).ToLowerInvariant()
    if (-not $v.StartsWith($first)) { return $false }
    $position = $first.Length
    for ($i = 1; $i -lt $Segments.Count - 1; $i++) {
        $part = ([string]$Segments[$i]).ToLowerInvariant()
        if (-not $part) { continue }
        $found = $v.IndexOf($part,$position)
        if ($found -lt 0) { return $false }
        $position = $found + $part.Length
    }
    if ($v.Length - $last.Length -lt $position) { return $false }
    return $v.EndsWith($last)
}
function ConvertFrom-DemoLdapBytes {
    # Exact binary value of an LDAP assertion (\XX escapes, other characters as UTF-8); $null with a wildcard.
    param([string]$Value)
    $bytes = New-Object Collections.Generic.List[byte]
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if ($c -eq [char]42) { return $null }
        if ($c -eq [char]92) {
            $number = 0
            if (($i + 2 -le $Value.Length - 1) -and [int]::TryParse($Value.Substring($i + 1,2),[Globalization.NumberStyles]::HexNumber,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { $bytes.Add([byte]$number); $i += 2; continue }
            return $null
        }
        foreach ($b in [Text.Encoding]::UTF8.GetBytes([string]$c)) { $bytes.Add($b) }
    }
    return ,($bytes.ToArray())
}
function Compare-DemoOrdered {
    # Returns -1, 0 or 1 (stored value against the filter value), or $null when they cannot be compared.
    # Dates are compared with the LDAP generalized time, numbers as Int64, other values as text.
    param($Value,[string]$Wanted)
    if ($Value -is [datetime]) {
        $text = $Wanted
        $dot = $text.IndexOf('.')
        if ($dot -gt 0) { $text = $text.Substring(0,$dot) }
        $text = $text.TrimEnd('Z')
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($text,'yyyyMMddHHmmss',[Globalization.CultureInfo]::InvariantCulture,([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),[ref]$parsed)) { return $null }
        return ([datetime]$Value).ToUniversalTime().CompareTo($parsed)
    }
    $left = [long]0; $right = [long]0
    if ([long]::TryParse([string]$Value,[ref]$left) -and [long]::TryParse($Wanted,[ref]$right)) { return $left.CompareTo($right) }
    return [Math]::Sign([string]::Compare([string]$Value,$Wanted,[StringComparison]::OrdinalIgnoreCase))
}
function Test-DemoItem {
    param($Node,$Item)
    $attrs = $Item.Attrs
    if ($Node.Op -in @('>=','<=','BitAnd','BitOr')) {
        if (-not $attrs.ContainsKey($Node.Attr)) { return $false }
        $mask = [long]0
        if ($Node.Op -in @('BitAnd','BitOr') -and -not [long]::TryParse([string]$Node.Value,[ref]$mask)) { return $false }
        foreach ($value in @($attrs[$Node.Attr])) {
            if ($null -eq $value -or $value -is [byte[]]) { continue }
            if ($Node.Op -in @('BitAnd','BitOr')) {
                $number = [long]0
                if (-not [long]::TryParse([string]$value,[ref]$number)) { continue }
                if (($Node.Op -eq 'BitAnd') -and (($number -band $mask) -eq $mask)) { return $true }
                if (($Node.Op -eq 'BitOr') -and (($number -band $mask) -ne 0)) { return $true }
                continue
            }
            $order = Compare-DemoOrdered $value ([string]$Node.Value)
            if ($null -eq $order) { continue }
            if (($Node.Op -eq '>=') -and ($order -ge 0)) { return $true }
            if (($Node.Op -eq '<=') -and ($order -le 0)) { return $true }
        }
        return $false
    }
    if ($Node.Attr -eq 'anr') {
        $prefix = ([string]$Node.Segments[0]).ToLowerInvariant()
        foreach ($name in @('name','displayname','givenname','sn','samaccountname','mail','userprincipalname')) {
            foreach ($value in @($attrs[$name])) { if ($null -ne $value -and $value -isnot [byte[]] -and ([string]$value).ToLowerInvariant().StartsWith($prefix)) { return $true } }
        }
        return $false
    }
    if (-not $attrs.ContainsKey($Node.Attr)) { return $false }
    $values = @($attrs[$Node.Attr])
    if ($Node.Presence) { return ($values.Count -gt 0) }
    foreach ($value in $values) {
        if ($null -eq $value) { continue }
        if ($value -is [byte[]]) {
            # A pasted GUID or SID is searched by its exact binary value, or by the S-1-... text for a SID.
            if ($Node.Attr -notin @('objectguid','objectsid')) { continue }
            $wanted = ConvertFrom-DemoLdapBytes ([string]$Node.Value)
            if ($null -ne $wanted -and [Convert]::ToBase64String([byte[]]$value) -ceq [Convert]::ToBase64String([byte[]]$wanted)) { return $true }
            if ($Node.Attr -eq 'objectsid' -and ([string]$Node.Value).StartsWith('S-')) {
                try { if ((New-Object Security.Principal.SecurityIdentifier -ArgumentList @([byte[]]$value,0)).Value -ieq [string]$Node.Value) { return $true } } catch { }
            }
            continue
        }
        $text = [string]$value
        if ($Node.Attr -eq 'objectcategory') {
            $rdn = $text
            if ($text.StartsWith('CN=')) { $rdn = $text.Substring(3,$text.IndexOf(',') - 3).Replace('-','') }
            if (Test-DemoText $rdn $Node.Segments) { return $true }
            if (Test-DemoText $text $Node.Segments) { return $true }
            continue
        }
        if (Test-DemoText $text $Node.Segments) { return $true }
    }
    return $false
}
function Test-DemoFilter {
    param($Node,$Item)
    if ($Node.Op -eq '&') { foreach ($child in $Node.Children) { if (-not (Test-DemoFilter $child $Item)) { return $false } }; return $true }
    if ($Node.Op -eq '|') { foreach ($child in $Node.Children) { if (Test-DemoFilter $child $Item) { return $true } }; return $false }
    if ($Node.Op -eq '!') { return (-not (Test-DemoFilter $Node.Children[0] $Item)) }
    return (Test-DemoItem $Node $Item)
}
function New-DemoResult {
    param($Item)
    return [pscustomobject]@{ Path=''; Properties=$Item.Attrs }
}
function ConvertTo-DemoPropertyValue {
    param([string]$Name,$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) {
        if ($Name -ieq 'objectGUID') { return ([guid]::new([byte[]]$Value)).ToString('D') }
        if ($Name -ieq 'objectSid') { return (New-Object Security.Principal.SecurityIdentifier -ArgumentList @([byte[]]$Value,0)).Value }
        return [BitConverter]::ToString([byte[]]$Value)
    }
    return $Value
}

$items = New-Object Collections.ArrayList
$byDn = @{}
foreach ($object in @($directory.Objects)) {
    $attrs = @{}
    foreach ($key in @($object.Attributes.Keys)) { $attrs[([string]$key).ToLowerInvariant()] = @($object.Attributes[$key]) }
    $dn = [string]$object.DN
    $item = [pscustomobject]@{ DN=$dn; Key=$dn.ToLowerInvariant(); Parent=(Get-DemoParentDn $dn).ToLowerInvariant(); Denied=@($object.DeniedFor); Attrs=$attrs; Original=$object }
    [void]$items.Add($item)
    $byDn[$item.Key] = $item
}
$ordered = @($items | Sort-Object Key)

if ($op -eq 'TreeChildren') {
    $dn = ([string]$req.DN).Trim()
    $key = $dn.ToLowerInvariant()
    if (-not (Test-DemoInBase $key)) { throw ('Branche ' + $dn + ' hors de l annuaire de demonstration.') }
    Wait-DemoLatency $null
    $rows = New-Object Collections.ArrayList
    foreach ($item in $ordered) {
        if ($item.Parent -ne $key) { continue }
        $classes = @($item.Attrs['objectclass'] | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if (-not (($classes -contains 'organizationalunit') -or ($classes -contains 'container') -or ($classes -contains 'builtindomain'))) { continue }
        [void]$rows.Add([pscustomobject]@{ Name=[string](Get-WPropFirst $item.Attrs 'name' ''); DN=$item.DN; Kind=(Get-WObjectType $item.Attrs) })
    }
    [pscustomobject]@{ Rows=@($rows | Sort-Object Name) }
    return
}

if ($op -eq 'GlobalSearch') {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $searchBase = ([string]$req.BaseDn).Trim().ToLowerInvariant()
    $scope = [string]$req.Scope
    if (-not $searchBase) { throw 'Recherche impossible : Base DN vide.' }
    if ($scope -notin @('Subtree','OneLevel')) { throw 'Portee de recherche invalide.' }
    $filters = New-Object Collections.ArrayList
    foreach ($candidate in @([string]$req.PrefixFilter,[string]$req.FastFilter,[string]$req.ExactFilter,[string]$req.AnrFilter,[string]$req.BroadFilter)) {
        $f = ([string]$candidate).Trim()
        if ($f -and -not $filters.Contains($f)) { [void]$filters.Add($f) }
    }
    if ($filters.Count -eq 0) { throw 'Aucun filtre LDAP valide n a ete construit.' }
    $limit = [Math]::Max(1,[int]$req.Limit)
    $rows = New-Object Collections.ArrayList
    $seen = @{}
    $diagnostics = New-Object Collections.ArrayList
    $raw = 0; $limitReached = $false; $filterUsed = ''
    foreach ($filterText in $filters) {
        $filterUsed = [string]$filterText
        $node = ConvertFrom-DemoFilter $filterText
        Wait-DemoLatency $req.StopToken
        $added = 0
        foreach ($item in $ordered) {
            if ($null -ne $req.StopToken -and $req.StopToken.IsCancellationRequested) { throw 'Lecture remplacee ou arretee.' }
            if ($scope -eq 'OneLevel') { if ($item.Parent -ne $searchBase) { continue } }
            elseif (-not ($item.Key -eq $searchBase -or $item.Key.EndsWith(',' + $searchBase))) { continue }
            if (-not (Test-DemoFilter $node $item)) { continue }
            $raw++
            $result = New-DemoResult $item
            $row = New-WBranchRow $result
            $g = Get-WPropFirst $result.Properties 'objectguid' $null
            $guidText = if ($g -is [array] -and $g.Count -eq 16) { ([guid]([byte[]]$g)).ToString('D') } else { Convert-WGuid $g }
            Add-Member -InputObject $row -NotePropertyName Guid -NotePropertyValue $guidText
            Add-Member -InputObject $row -NotePropertyName AdminCount -NotePropertyValue ([string](Get-WPropFirst $result.Properties 'admincount' '')) -Force
            if ([string]$row.Type -notin @('Utilisateur','Machine','Groupe','OU','Conteneur')) { continue }
            $rowKey = ([string]$row.DN).Trim().ToLowerInvariant()
            if ($seen.ContainsKey($rowKey)) { continue }
            $seen[$rowKey] = $true
            [void]$rows.Add($row)
            $added++
            if ($null -ne $req.Progress) { $req.Progress.Enqueue([pscustomobject]@{ Kind='Row'; Row=$row; ObservedUtc=[datetime]::UtcNow.ToString('o') }) }
            if ($rows.Count -ge $limit) { $limitReached = $true; break }
        }
        [void]$diagnostics.Add('demonstration : ' + $filterText + ' => ajoutes=' + $added)
        if ($rows.Count -gt 0 -or $limitReached) { break }
    }
    $watch.Stop()
    [pscustomobject]@{ Rows=@($rows); Partial=$false; Failure=''; RawCount=[int]$raw; DurationMs=[long]$watch.ElapsedMilliseconds; Server='(demonstration)'; BaseDn=[string]$req.BaseDn; Scope=$scope; LimitReached=[bool]$limitReached; Filters=@($diagnostics); FilterUsed=$filterUsed }
    return
}

if ($op -eq 'OpenAdObject') {
    $dn = ([string]$req.DN).Trim()
    $key = $dn.ToLowerInvariant()
    Wait-DemoLatency $null
    if (-not $byDn.ContainsKey($key)) { throw ('Objet ' + $dn + ' introuvable dans l annuaire de demonstration (0x80072030).') }
    $item = $byDn[$key]
    if (Test-DemoDenied $item) { throw ('Lecture refusee pour ' + $bindUser + ' sur ' + $dn + ' (0x80070005).') }
    $h = @{}
    $requested = @(@($req.Properties) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if (-not $requested.Count) { throw 'Liste explicite de proprietes AD requise.' }
    foreach ($name in $requested) {
        if ($name -in @('member','memberOf')) { continue }
        $values = New-Object Collections.Generic.List[object]
        foreach ($value in @($item.Attrs[([string]$name).ToLowerInvariant()])) { if ($null -ne $value) { $values.Add((ConvertTo-DemoPropertyValue ([string]$name) $value)) } }
        if ($values.Count) { $h[[string]$name] = $values.ToArray() }
    }
    foreach ($attribute in @('member','memberOf')) {
        if ($requested -notcontains $attribute) { continue }
        $h[$attribute] = @(@($item.Attrs[$attribute.ToLowerInvariant()]) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $h['__' + $attribute + 'Complete'] = @($true)
        $h['__' + $attribute + 'Note'] = @('')
    }
    [pscustomobject]@{ Properties=$h; DN=$item.DN; Type=[string]$req.Type; Live=$true }
    return
}

if ($op -eq 'IndexBuild') {
    # Same rows as the real IndexBuild, computer facts included (operatingSystemVersion, whenCreated, pwdLastSet,
    # LAPS expiration, never a password); the demonstration schema holds both LAPS attributes.
    Wait-DemoLatency $null
    $utcText = {
        param($Value)
        if ($null -eq $Value -or [string]$Value -eq '') { return '' }
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture) }
        $ticks = [long]0
        if (-not [long]::TryParse([string]$Value,[ref]$ticks) -or $ticks -le 0 -or $ticks -eq [long]::MaxValue) { return '' }
        return [DateTime]::FromFileTimeUtc($ticks).ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
    }
    $rows = New-Object Collections.ArrayList
    foreach ($item in $ordered) {
        $attrs = $item.Attrs
        $type = Get-WObjectType $attrs
        if ($type -notin @('Utilisateur','Machine')) { continue }
        $name = [string](Get-WPropFirst $attrs 'name' '')
        if (-not $name) { continue }
        $uac = 0; try { $uac = [int](Get-WPropFirst $attrs 'useraccountcontrol' 0) } catch { $uac = 0 }
        $guid = ConvertTo-DemoPropertyValue 'objectGUID' (Get-WPropFirst $attrs 'objectguid' $null)
        $logonTicks = [long]0; [void][long]::TryParse([string](Get-WPropFirst $attrs 'lastlogontimestamp' 0),[ref]$logonTicks)
        $lastLogon = if (($logonTicks -gt 0) -and ($logonTicks -ne [long]::MaxValue)) { [DateTime]::FromFileTimeUtc($logonTicks).ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') } else { 'Jamais' }
        $changed = Get-WPropFirst $attrs 'whenchanged' $null
        $row = [ordered]@{ Type=$type; WhenChanged=$(if ($changed -is [datetime]) { $changed.ToString('dd/MM/yyyy HH:mm:ss') } else { '' }); Usn=[long](Get-WPropFirst $attrs 'usnchanged' 0); LastLogon=$lastLogon; Name=$name
            Login=([string](Get-WPropFirst $attrs 'samaccountname' '')).TrimEnd([char]36); Upn=''; Display=[string](Get-WPropFirst $attrs 'displayname' ''); Description=[string](Get-WPropFirst $attrs 'description' ''); Extra=''
            State=$(if (($uac -band 2) -ne 0) { 'Desactive' } else { 'Actif' }); DN=$item.DN; Guid=[string]$guid; Facts=$false; OsVersion=''; WhenCreated=''; PwdLastSet=''; LapsKind=''; LapsExpiry='' }
        if ($type -eq 'Utilisateur') { $row.Upn = [string](Get-WPropFirst $attrs 'userprincipalname' '') }
        else {
            $row.Upn = [string](Get-WPropFirst $attrs 'dnshostname' '')
            $row.Extra = [string](Get-WPropFirst $attrs 'operatingsystem' '')
            $row.Facts = $true
            $row.OsVersion = [string](Get-WPropFirst $attrs 'operatingsystemversion' '')
            $row.WhenCreated = & $utcText (Get-WPropFirst $attrs 'whencreated' $null)
            $row.PwdLastSet = & $utcText (Get-WPropFirst $attrs 'pwdlastset' $null)
            $windows = & $utcText (Get-WPropFirst $attrs 'mslaps-passwordexpirationtime' $null)
            $legacy = & $utcText (Get-WPropFirst $attrs 'ms-mcs-admpwdexpirationtime' $null)
            if ($windows) { $row.LapsKind = 'Windows'; $row.LapsExpiry = $windows } elseif ($legacy) { $row.LapsKind = 'Legacy'; $row.LapsExpiry = $legacy } else { $row.LapsKind = 'None' }
        }
        [void]$rows.Add([pscustomobject]$row)
    }
    [pscustomobject]@{ Rows=@($rows); Diagnostics=@('demonstration : ' + $rows.Count + ' objet(s) indexes'); Truncated=$false; Incremental=$false; DeltaClause=''; HighestUsn=[long]12999; Server='(demonstration)'; BaseDn=$baseDn; DurationMs=[long]0; Success=$true; InvocationId=''; LapsSchema='Present' }
    return
}

if ($op -eq 'BitLockerPresence') {
    # Same refusals and shape as the real reader: never at the domain root, metadata of recovery objects only.
    $ouDn = ([string]$req.DN).Trim()
    $ouKey = $ouDn.ToLowerInvariant()
    if (-not $ouDn) { throw 'OU absente : aucune lecture envoyee.' }
    if ($ouKey -eq $baseKey) { throw 'Lecture refusee a la racine du domaine : choisissez une OU dans Rechercher.' }
    if (-not (Test-DemoInBase $ouKey)) { throw 'OU hors du domaine de la session : aucune lecture envoyee.' }
    Wait-DemoLatency $null
    $computers = @{}; $found = 0
    foreach ($item in $ordered) {
        $classes = @($item.Attrs['objectclass'] | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($classes -notcontains 'msfve-recoveryinformation') { continue }
        if (-not $item.Key.EndsWith(',' + $ouKey)) { continue }
        $found++
        if (-not $computers.ContainsKey($item.Parent)) { $computers[$item.Parent] = [pscustomobject]@{ DN = (Get-DemoParentDn $item.DN); Keys = 0; Last = '' } }
        $computers[$item.Parent].Keys = [int]$computers[$item.Parent].Keys + 1
    }
    [pscustomobject]@{ Mode='BitLockerPresence'; Success=$true; DN=$ouDn; ClassPresent=$true; RecoveryObjectsFound=$found; Truncated=$false; Computers=@($computers.Values); ErrorKind=''; ErrorMessage=''; ReadAtUtc=[datetime]::UtcNow.ToString('o') }
    return
}

if ($op -eq 'ReceiptStore' -and [string]$req.Action -eq 'List') {
    # Demonstration receipts are never read from the real receipt folder.
    [pscustomobject]@{ Rows=@(); Pending=0 }
    return
}

if ($op -eq 'StartupWarmCache') {
    # Same shape as the real read: one level under the base, objects bounded by ObjectLimit.
    $treeRows = New-Object Collections.ArrayList
    $objectRows = New-Object Collections.ArrayList
    $objectLimit = [Math]::Max(1,[int]$req.ObjectLimit)
    foreach ($item in $ordered) {
        if ($item.Parent -ne $baseKey) { continue }
        $result = New-DemoResult $item
        $type = Get-WObjectType $item.Attrs
        if ([bool]$req.WarmTree -and $type -in @('OU','Conteneur')) { [void]$treeRows.Add([pscustomobject]@{ Name=[string](Get-WPropFirst $item.Attrs 'name' ''); DN=$item.DN; Kind=$type }) }
        if ([bool]$req.WarmObjects -and $objectRows.Count -lt $objectLimit -and $type -in @('Utilisateur','Machine','Groupe','OU','Conteneur')) { [void]$objectRows.Add((New-WBranchRow $result)) }
    }
    [pscustomobject]@{ BaseDn=$baseDn; TreeReady=$true; ObjectsReady=$true; TreeRows=@($treeRows | Sort-Object Name); ObjectRows=@($objectRows); WorkerThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId }
    return
}

throw ('DOMENIA_DEMO_UNAVAILABLE : ' + $op + ' non disponible en demonstration - aucune connexion AD.')
'@
}
