# Fiche dʼappel (R40, improvement 3 of David): what a technician needs during a phone call about one user account.
# Built from data already read (the attributes of the fiche, the stored associations and measures of the associated
# workstations, the durable receipts of Domenia) and from the explicit reads the operator starts from the sheet (4740
# journal, password policy, sessions, quick inventory). Every fact carries its source, its observation date and a state
# of the one measure vocabulary (Get-DomeniaMeasureStateKeys, Domenia-Collection.Model.ps1): an unknown value stays
# unknown, a stale one says so.
# Pure decisions: no WPF, no network, no disk and no clock read (the caller gives NowUtc and the local UTC offset).
# Relies on Domenia-Common (members, dates), Domenia-Collection (measure states), Domenia-Search (DN parts),
# Domenia-Relations (badges, primary relation), Domenia-Access (secret masking), Domenia-Directory (account state,
# lockout, password policy) and Domenia-Readings (pending restart, processor share of the processes).

function Format-DomeniaCallSheetDate {
    # Local display of an instant: « 21/10/2026 14:05 », the date alone with -DateOnly, '' when unreadable.
    param($Value,[switch]$DateOnly)
    $utc = ConvertTo-DomeniaUtcDate $Value
    if ($null -eq $utc) { return '' }
    $format = 'dd/MM/yyyy HH:mm'
    if ($DateOnly) { $format = 'dd/MM/yyyy' }
    return $utc.ToLocalTime().ToString($format,[Globalization.CultureInfo]::InvariantCulture)
}

function New-DomeniaCallSheetFact {
    # One line of the sheet. State is a key of Get-DomeniaMeasureStateKeys: Known is a valid dated value, every other
    # key says why the value cannot be used as it is. An empty value is written as the state, never left blank.
    param(
        [Parameter(Mandatory=$true)][string]$Section,
        [Parameter(Mandatory=$true)][string]$Label,
        [AllowEmptyString()][AllowNull()][string]$Value='',
        [string]$State='Known',
        [AllowEmptyString()][AllowNull()][string]$Source='',
        $ObservedUtc=$null,
        [AllowEmptyString()][AllowNull()][string]$Detail='',
        [bool]$Attention=$false
    )
    if ($State -cnotin @(Get-DomeniaMeasureStateKeys)) { throw ('État de mesure inconnu : ' + $State) }
    $when = ConvertTo-DomeniaUtcDate $ObservedUtc
    $text = ([string]$Value).Trim()
    if (-not $text) {
        if ($State -ceq 'Known') { $text = 'Non renseigné' } else { $text = Get-DomeniaMeasureStateLabel $State }
    }
    $iso = ''
    if ($null -ne $when) { $iso = $when.ToString('o',[Globalization.CultureInfo]::InvariantCulture) }
    return [pscustomobject]@{
        Section=$Section;Label=$Label;Value=$text;State=$State;StateLabel=(Get-DomeniaMeasureStateLabel $State)
        Source=[string]$Source;ObservedUtc=$iso;DateText=(Format-DomeniaCallSheetDate $when);Detail=[string]$Detail;Attention=[bool]$Attention
    }
}

function Test-DomeniaCallSheetAttribute {
    # Whether the property bag of the fiche holds the attribute at all (any key casing), whatever its value.
    param($Properties,[Parameter(Mandatory=$true)][string]$Name)
    if ($null -eq $Properties) { return $false }
    if ($Properties -is [Collections.IDictionary]) {
        foreach ($key in @($Properties.Keys)) { if ([string]$key -ieq $Name) { return $true } }
        return $false
    }
    foreach ($property in @($Properties.PSObject.Properties)) { if ([string]$property.Name -ieq $Name) { return $true } }
    return $false
}

function Get-DomeniaCallSheetOrigin {
    # How the fiche shown was obtained. Live: read on a domain controller in this session. Cache: projection of the local
    # base, usable while recent (FreshMinutes) and stale beyond, until the directory read replaces it. An unknown origin
    # or date is never presented as fresh.
    param([AllowEmptyString()][AllowNull()][string]$Origin='',$ObservedUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow,[int]$FreshMinutes=15,[AllowEmptyString()][AllowNull()][string]$Server='')
    $when = ConvertTo-DomeniaUtcDate $ObservedUtc
    $now = $NowUtc.ToUniversalTime()
    $dateText = Format-DomeniaCallSheetDate $when
    if ($Origin -ceq 'Live') {
        $source = 'Fiche lue dans lʼannuaire'
        if ($Server) { $source += ' (' + $Server + ')' }
        $text = $source + ', date de lecture non conservée.'
        if ($null -ne $when) { $text = $source + ' le ' + $dateText + '.' }
        return [pscustomobject]@{Origin='Live';Live=$true;State='Known';Source=$source;ObservedUtc=$when;Text=$text}
    }
    $source = 'Fiche de la base locale'
    if ($Origin -cne 'Cache') { $source = 'Fiche dʼorigine non confirmée' }
    if (($null -eq $when) -or ($when -gt $now.AddMinutes(5))) {
        return [pscustomobject]@{Origin=$(if($Origin -ceq 'Cache'){'Cache'}else{'Unknown'});Live=$false;State='Expired';Source=$source;ObservedUtc=$when;Text=($source + ' : date de lecture inconnue ou future, relisez la fiche depuis lʼannuaire.')}
    }
    $age = ($now - $when).TotalMinutes
    if (($Origin -ceq 'Cache') -and ($age -le [Math]::Max(1,$FreshMinutes))) {
        return [pscustomobject]@{Origin='Cache';Live=$false;State='Known';Source=$source;ObservedUtc=$when;Text=($source + ' du ' + $dateText + ' ; la lecture de lʼannuaire la remplace dès son arrivée.')}
    }
    return [pscustomobject]@{Origin=$(if($Origin -ceq 'Cache'){'Cache'}else{'Unknown'});Live=$false;State='Expired';Source=$source;ObservedUtc=$when;Text=($source + ' du ' + $dateText + ', plus de ' + [string][Math]::Max(1,$FreshMinutes) + ' min : relisez la fiche depuis lʼannuaire.')}
}

# ---------------------------------------------------------------- logon restrictions
function ConvertFrom-DomeniaLogonHoursValue {
    # logonHours as Domenia holds it: a byte[] (DirectoryEntry), the « FF-FF-… » text written by the directory readers
    # (BitConverter.ToString), plain hexadecimal, or 21 numbers. Returns the 21 bytes, or $null when unreadable.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) {
        if ($Value.Length -eq 21) { return ,([byte[]]$Value) }
        return $null
    }
    if (($Value -isnot [string]) -and ($Value -is [Collections.IEnumerable])) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add($item) }
        if ($items.Count -eq 1) {
            $single = ConvertFrom-DomeniaLogonHoursValue $items[0]
            return ,$single
        }
        if ($items.Count -ne 21) { return $null }
        $numbers = New-Object 'byte[]' 21
        for ($i = 0; $i -lt 21; $i++) {
            $number = 0
            if ((-not [int]::TryParse([string]$items[$i],[ref]$number)) -or ($number -lt 0) -or ($number -gt 255)) { return $null }
            $numbers[$i] = [byte]$number
        }
        return ,$numbers
    }
    $text = ([string]$Value) -replace '[\s:-]',''
    if ($text -notmatch '^[0-9A-Fa-f]{42}$') { return $null }
    $bytes = New-Object 'byte[]' 21
    for ($i = 0; $i -lt 21; $i++) { $bytes[$i] = [Convert]::ToByte($text.Substring($i * 2,2),16) }
    return ,$bytes
}

function Format-DomeniaCallSheetUtcOffset {
    # « UTC+02:00 », « UTC-03:30 ».
    param([int]$Minutes)
    $sign = '+'
    if ($Minutes -lt 0) { $sign = '-' }
    $abs = [Math]::Abs($Minutes)
    return ('UTC' + $sign + ([int][Math]::Floor($abs / 60)).ToString('00') + ':' + ($abs % 60).ToString('00'))
}

function Get-DomeniaCallSheetDayName {
    # French day name, 0 = Sunday as [DayOfWeek].
    param([int]$Day)
    return (@('dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi'))[(($Day % 7) + 7) % 7]
}

function Get-DomeniaLogonHoursView {
    # logonHours: 21 bytes, one bit per hour of the week in UTC from Sunday 00:00, low-order bit of each byte first.
    # The slots are written in the local time of this computer at the given offset (as the AD consoles do, daylight
    # saving moves them by one hour twice a year). $Read: whether the fiche was able to hold the attribute (absent from a
    # directory read: no restriction; absent from a local projection: not read). NowUtc tells whether a logon is allowed
    # right now, from the UTC bit itself.
    param($Value,[bool]$Read=$true,[int]$UtcOffsetMinutes=0,$NowUtc=$null)
    $offsetText = Format-DomeniaCallSheetUtcOffset $UtcOffsetMinutes
    $make = {
        param([string]$State,[string]$Summary,[bool]$Unrestricted,[bool]$Never,[int]$Hours,[object[]]$Days,$AllowedNow)
        [pscustomobject]@{State=$State;Summary=$Summary;Unrestricted=$Unrestricted;NeverAllowed=$Never;AllowedHours=$Hours;Days=@($Days);AllowedNow=$AllowedNow;Offset=$offsetText}
    }
    $empty = ($null -eq $Value) -or (($Value -is [string]) -and (-not $Value.Trim()))
    if ((-not $empty) -and ($Value -isnot [string]) -and ($Value -isnot [byte[]]) -and ($Value -is [Collections.IEnumerable])) {
        $count = 0
        foreach ($item in $Value) { $count++ }
        $empty = ($count -eq 0)
    }
    if ($empty) {
        if (-not $Read) { return (& $make 'NotRead' 'Non lu : la fiche affichée ne contient pas les heures dʼouverture de session.' $false $false -1 @() $null) }
        return (& $make 'Known' 'Aucune restriction horaire' $true $false 168 @() $true)
    }
    $bytes = ConvertFrom-DomeniaLogonHoursValue $Value
    if ($null -eq $bytes) { return (& $make 'Error' 'Valeur de logonHours illisible : 21 octets attendus.' $false $false -1 @() $null) }
    $allowed = New-Object 'System.Collections.Generic.List[int]'
    for ($hour = 0; $hour -lt 168; $hour++) {
        if (([int]$bytes[[int][Math]::Floor($hour / 8)] -band (1 -shl ($hour % 8))) -ne 0) { $allowed.Add($hour) }
    }
    $allowedNow = $null
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    if ($null -ne $now) { $allowedNow = $allowed.Contains(([int]$now.DayOfWeek * 24) + $now.Hour) }
    if ($allowed.Count -eq 168) { return (& $make 'Known' 'Toutes les heures sont autorisées' $true $false 168 @() $true) }
    if ($allowed.Count -eq 0) { return (& $make 'Known' 'Aucune heure autorisée : ouverture de session refusée à toute heure' $false $true 0 @() $false) }
    # Local minutes of the week, [Start, End), from Sunday 00:00 local time.
    $segments = New-Object 'System.Collections.Generic.List[object]'
    foreach ($hour in $allowed) {
        $start = ((($hour * 60) + $UtcOffsetMinutes) % 10080 + 10080) % 10080
        $end = $start + 60
        if ($end -le 10080) { $segments.Add([pscustomobject]@{Start=$start;End=$end}) }
        else {
            $segments.Add([pscustomobject]@{Start=$start;End=10080})
            $segments.Add([pscustomobject]@{Start=0;End=($end - 10080)})
        }
    }
    $sorted = @($segments | Sort-Object Start)
    $dash = [string][char]0x2013
    $clock = { param([int]$Minute) ([int][Math]::Floor($Minute / 60)).ToString('00') + ':' + ($Minute % 60).ToString('00') }
    $dayTexts = New-Object 'string[]' 7
    for ($day = 0; $day -lt 7; $day++) {
        $from = $day * 1440; $to = $from + 1440
        $parts = New-Object 'System.Collections.Generic.List[object]'
        foreach ($segment in $sorted) {
            $s = [Math]::Max($from,[int]$segment.Start); $e = [Math]::Min($to,[int]$segment.End)
            if ($e -le $s) { continue }
            if (($parts.Count -gt 0) -and ([int]$parts[$parts.Count - 1].End -ge $s)) { $parts[$parts.Count - 1].End = [Math]::Max([int]$parts[$parts.Count - 1].End,$e) }
            else { $parts.Add([pscustomobject]@{Start=$s;End=$e}) }
        }
        $texts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($part in $parts) { $texts.Add((& $clock ([int]$part.Start - $from)) + $dash + (& $clock ([int]$part.End - $from))) }
        $dayTexts[$day] = ($texts.ToArray() -join ', ')
    }
    # Monday first, consecutive days with the same slots grouped: « du lundi au vendredi : 08:00–18:00 ».
    $groups = New-Object 'System.Collections.Generic.List[object]'
    $days = New-Object 'System.Collections.Generic.List[object]'
    foreach ($day in @(1,2,3,4,5,6,0)) {
        $text = [string]$dayTexts[$day]
        $hoursText = $text
        if (-not $hoursText) { $hoursText = 'aucune heure' }
        $days.Add([pscustomobject]@{Day=(Get-DomeniaCallSheetDayName $day);Hours=$hoursText})
        if (($groups.Count -gt 0) -and ([string]$groups[$groups.Count - 1].Text -ceq $text)) { $groups[$groups.Count - 1].Days.Add($day) }
        else {
            $members = New-Object 'System.Collections.Generic.List[int]'
            $members.Add($day)
            $groups.Add([pscustomobject]@{Text=$text;Days=$members})
        }
    }
    $phrases = New-Object 'System.Collections.Generic.List[string]'
    foreach ($group in $groups) {
        $names = @(foreach ($member in $group.Days) { Get-DomeniaCallSheetDayName $member })
        $label = $names[0]
        if ($names.Count -ge 3) { $label = 'du ' + $names[0] + ' au ' + $names[$names.Count - 1] }
        elseif ($names.Count -eq 2) { $label = $names[0] + ' et ' + $names[1] }
        $hoursText = [string]$group.Text
        if (-not $hoursText) { $hoursText = 'aucune heure' }
        $phrases.Add($label + ' : ' + $hoursText)
    }
    $summary = $phrases.ToArray() -join ' ; '
    $summary = $summary.Substring(0,1).ToUpperInvariant() + $summary.Substring(1)
    return (& $make 'Known' $summary $false $false $allowed.Count $days.ToArray() $allowedNow)
}

function Get-DomeniaCallSheetShortName {
    # Short upper-case name of a workstation (« PC-42.corp.example » -> « PC-42 »), for comparisons only.
    param([AllowEmptyString()][AllowNull()][string]$Name)
    $text = ([string]$Name).Trim().TrimEnd('$')
    $dot = $text.IndexOf('.')
    if ($dot -gt 0) { $text = $text.Substring(0,$dot) }
    return $text.ToUpperInvariant()
}

function Get-DomeniaUserWorkstationsView {
    # userWorkstations: the NetBIOS names of the workstations this account may log on to, comma-separated. Absent from a
    # directory read: every workstation; absent from a local projection: not read. The associated workstations of the
    # account that are not in the list are named: the logon would be refused there.
    param($Value,[bool]$Read=$true,[string[]]$LinkedComputers=@())
    $text = ''
    foreach ($item in @($Value)) { if ($null -ne $item) { $text += ',' + [string]$item } }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in ($text -split ',')) {
        $name = ([string]$part).Trim()
        if (([bool]$name) -and ($seen.Add($name))) { $names.Add($name) }
    }
    if ($names.Count -eq 0) {
        if (-not $Read) { return [pscustomobject]@{State='NotRead';Unrestricted=$false;Names=@();Summary='Non lu : la fiche affichée ne contient pas la liste des postes autorisés.';Outside=@();Attention=$false;Detail=''} }
        return [pscustomobject]@{State='Known';Unrestricted=$true;Names=@();Summary='Tous les postes';Outside=@();Attention=$false;Detail='Attribut userWorkstations non renseigné : aucune limite de poste.'}
    }
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) { [void]$allowed.Add((Get-DomeniaCallSheetShortName $name)) }
    $linked = @(@($LinkedComputers) | ForEach-Object { Get-DomeniaCallSheetShortName $_ } | Where-Object { $_ } | Select-Object -Unique)
    $outside = @($linked | Where-Object { -not $allowed.Contains([string]$_) })
    $attention = $false; $detail = 'Liste lue dans userWorkstations.'
    if ($linked.Count -gt 0) {
        if ($outside.Count -eq $linked.Count) { $attention = $true; $detail = 'Aucun poste associé à ce compte nʼest dans cette liste : lʼouverture de session y sera refusée.' }
        elseif ($outside.Count -gt 0) { $detail = 'Postes associés hors de la liste, où lʼouverture de session sera refusée : ' + ($outside -join ', ') + '.' }
    }
    return [pscustomobject]@{State='Known';Unrestricted=$false;Names=$names.ToArray();Summary=([string]$names.Count + ' poste(s) autorisé(s) : ' + ($names.ToArray() -join ', '));Outside=$outside;Attention=$attention;Detail=$detail}
}

# ---------------------------------------------------------------- account
function Get-DomeniaCallSheetAccountFacts {
    # The account facts of the sheet from the fiche attributes (sections Compte and Restrictions): state, lockout, failed
    # passwords, password change and expiry, account expiry, last logon, logon hours, allowed workstations, smart card and
    # password not required. $PolicyView: result of the explicit password policy read (ConvertTo-DomeniaPasswordPolicyView),
    # which then gives the expiry with its own source and date. $LinkedComputers: names of the associated workstations.
    param(
        $Properties,
        [AllowEmptyString()][AllowNull()][string]$Origin='',
        $ObservedUtc=$null,
        [datetime]$NowUtc=[datetime]::UtcNow,
        [int]$UtcOffsetMinutes=0,
        [int]$FreshMinutes=15,
        [AllowEmptyString()][AllowNull()][string]$Server='',
        $PolicyView=$null,
        $PolicyObservedUtc=$null,
        [AllowEmptyString()][AllowNull()][string]$PolicyServer='',
        [string[]]$LinkedComputers=@()
    )
    $now = $NowUtc.ToUniversalTime()
    $originView = Get-DomeniaCallSheetOrigin -Origin $Origin -ObservedUtc $ObservedUtc -NowUtc $now -FreshMinutes $FreshMinutes -Server $Server
    $live = [bool]$originView.Live
    $base = [string]$originView.State
    $source = [string]$originView.Source
    $at = $originView.ObservedUtc
    $stale = ''
    if ($base -ne 'Known') { $stale = ' ' + [string]$originView.Text }
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $missing = {
        param([string]$Section,[string]$Label,[string]$Attribute)
        $why = $Attribute + ' absent de la fiche affichée'
        if ($live) { $why += ' : le contrôleur ne lʼa pas renvoyé (droit de lecture ?).' } else { $why += ' : relisez la fiche depuis lʼannuaire.' }
        New-DomeniaCallSheetFact -Section $Section -Label $Label -Value 'Non lu' -State 'NotRead' -Source $source -ObservedUtc $at -Detail $why
    }
    $add = {
        param([string]$Section,[string]$Label,[string]$Value,[string]$Detail='',[bool]$Attention=$false)
        New-DomeniaCallSheetFact -Section $Section -Label $Label -Value $Value -State $base -Source $source -ObservedUtc $at -Detail ($Detail + $stale).Trim() -Attention $Attention
    }

    $state = Get-DomeniaAccountState (Get-DomeniaAttr $Properties 'userAccountControl' $null) (Get-DomeniaAttr $Properties 'msDS-User-Account-Control-Computed' $null) (Get-DomeniaAttr $Properties 'lockoutTime' $null)
    if (-not [bool]$state.Known) { $facts.Add((& $missing 'Compte' 'État du compte' 'userAccountControl')) }
    elseif ([bool]$state.Disabled) { $facts.Add((& $add 'Compte' 'État du compte' 'Désactivé' 'Lu dans userAccountControl.' $true)) }
    else { $facts.Add((& $add 'Compte' 'État du compte' 'Activé' 'Lu dans userAccountControl.')) }

    # Lockout: the state computed by the controller decides; lockoutTime alone dates the last lockout, nothing more.
    $diagnosis = Get-DomeniaLockoutDiagnosis -User $Properties -EventReadState 'NotRequested' -NowUtc $now
    $lockoutUtc = ConvertTo-DomeniaAdDate (Get-DomeniaAttr $Properties 'lockoutTime' $null)
    switch ([string]$diagnosis.Verdict) {
        'Verrouille' {
            $value = 'Verrouillé'
            if ($null -ne $lockoutUtc) { $value += ' depuis le ' + (Format-DomeniaCallSheetDate $lockoutUtc) }
            $facts.Add((& $add 'Compte' 'Verrouillage' $value 'État calculé par le contrôleur. Le journal 4740 dit quel poste a provoqué le verrouillage.' $true))
        }
        'NonVerrouille' {
            $value = 'Non verrouillé'
            if (($null -ne $lockoutUtc) -and ($lockoutUtc -gt $now.AddDays(-7))) { $value += ' (verrouillé le ' + (Format-DomeniaCallSheetDate $lockoutUtc) + ', libéré depuis)' }
            $facts.Add((& $add 'Compte' 'Verrouillage' $value 'État calculé par le contrôleur.'))
        }
        default {
            $facts.Add((New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillage' -Value 'Inconnu' -State 'NotRead' -Source $source -ObservedUtc $at -Detail 'État calculé du contrôleur (msDS-User-Account-Control-Computed) non lu : un lockoutTime non nul ne prouve pas un verrouillage actuel.'))
        }
    }

    $bad = ([string](Get-DomeniaAttr $Properties 'badPwdCount' '')).Trim()
    $badCount = 0L
    if (-not $bad) { $facts.Add((& $missing 'Compte' 'Échecs de mot de passe' 'badPwdCount')) }
    elseif (-not [long]::TryParse($bad,[ref]$badCount)) { $facts.Add((New-DomeniaCallSheetFact -Section 'Compte' -Label 'Échecs de mot de passe' -Value 'Illisible' -State 'Error' -Source $source -ObservedUtc $at -Detail ('Valeur de badPwdCount non numérique : ' + (ConvertTo-DomeniaFlatText $bad 40)))) }
    else {
        $value = [string]$badCount
        $badTime = ConvertTo-DomeniaAdDate (Get-DomeniaAttr $Properties 'badPasswordTime' $null)
        if (($badCount -gt 0) -and ($null -ne $badTime)) { $value += ' (dernier échec le ' + (Format-DomeniaCallSheetDate $badTime) + ')' }
        $facts.Add((& $add 'Compte' 'Échecs de mot de passe' $value 'Compteur propre au contrôleur interrogé : il nʼest pas répliqué entre contrôleurs.' ($badCount -gt 0)))
    }

    $pwdRaw = Get-DomeniaAttr $Properties 'pwdLastSet' $null
    $pwdNumber = ConvertTo-DomeniaAdInt64 $pwdRaw
    $mustChange = (($null -ne $pwdNumber) -and ($pwdNumber -eq 0L))
    if (($null -eq $pwdRaw) -or ([string]$pwdRaw -eq '')) { $facts.Add((& $missing 'Compte' 'Mot de passe changé' 'pwdLastSet')) }
    elseif ($mustChange) { $facts.Add((& $add 'Compte' 'Mot de passe changé' 'À changer à la prochaine ouverture de session' 'pwdLastSet vaut 0.' $true)) }
    else {
        $pwdUtc = ConvertTo-DomeniaAdDate $pwdRaw
        if ($null -eq $pwdUtc) { $facts.Add((New-DomeniaCallSheetFact -Section 'Compte' -Label 'Mot de passe changé' -Value 'Illisible' -State 'Error' -Source $source -ObservedUtc $at -Detail 'Valeur de pwdLastSet illisible.')) }
        else { $facts.Add((& $add 'Compte' 'Mot de passe changé' ('Le ' + (Format-DomeniaCallSheetDate $pwdUtc)) 'Lu dans pwdLastSet.')) }
    }

    # Expiry of the password: Resolve-DomeniaPasswordPolicy decides which value applies (computed by the controller first,
    # or estimated from the policy read); this function only words it.
    $expSource = $source; $expAt = $at; $expBase = $base; $expStale = $stale
    if ($null -ne $PolicyView) {
        $expiresUtc = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $PolicyView 'ExpiresUtc' $null)
        $policyFacts = @(Get-DomeniaMember $PolicyView 'Facts' @())
        $expSource = 'Stratégie de mot de passe lue'
        if ($PolicyServer) { $expSource += ' sur ' + $PolicyServer }
        $expAt = ConvertTo-DomeniaUtcDate $PolicyObservedUtc; $expBase = 'Known'; $expStale = ''
    } else {
        $resolved = Resolve-DomeniaPasswordPolicy -User $Properties -ResultantPsoState 'Unreadable' -NowUtc $now
        $expiresUtc = $resolved.ExpiresUtc
        $policyFacts = @($resolved.Facts)
    }
    $expiryFact = @($policyFacts | Where-Object { [string](Get-DomeniaMember $_ 'Fait' '') -ceq 'Expiration du mot de passe' } | Select-Object -First 1)
    $expiryEtat = 'Inconnu'; $expiryLimit = ''
    if ($expiryFact.Count) { $expiryEtat = [string](Get-DomeniaMember $expiryFact[0] 'Etat' 'Inconnu'); $expiryLimit = [string](Get-DomeniaMember $expiryFact[0] 'Limite' '') }
    $computed = ConvertTo-DomeniaAdInt64 (Get-DomeniaAttr $Properties 'msDS-UserPasswordExpiryTimeComputed' $null)
    $expiry = $null
    if (([bool]$state.Known) -and ([bool]$state.NeverExpires)) { $expiry = @('Nʼexpire jamais (option du compte)','Option « Le mot de passe nʼexpire jamais » de userAccountControl.',$false) }
    elseif ($mustChange) { $expiry = @('À changer à la prochaine ouverture de session','pwdLastSet vaut 0 : le point est déjà signalé par « Mot de passe changé ».',$false) }
    elseif ($null -ne $expiresUtc) {
        $days = ($expiresUtc - $now).TotalDays
        $how = 'Calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed).'
        if ($expiryEtat -ceq 'Estime') { $how = 'Estimée à partir de la stratégie lue : valeur calculée par le contrôleur non disponible.' }
        if ($days -le 0) { $expiry = @(('Expiré depuis le ' + (Format-DomeniaCallSheetDate $expiresUtc)),$how,$true) }
        else { $expiry = @(('Expire le ' + (Format-DomeniaCallSheetDate $expiresUtc) + ' (dans ' + [string][int][Math]::Ceiling($days) + ' j)'),$how,($days -le 7)) }
    }
    elseif (($null -ne $computed) -and ($computed -eq [long]::MaxValue)) { $expiry = @('Nʼexpire pas','Valeur calculée par le contrôleur : aucune échéance.',$false) }
    elseif ($expiryEtat -ceq 'Constate') { $expiry = @('Nʼexpire pas','Stratégie lue sans durée de validité.',$false) }
    if ($null -ne $expiry) {
        $facts.Add((New-DomeniaCallSheetFact -Section 'Compte' -Label 'Expiration du mot de passe' -Value ([string]$expiry[0]) -State $expBase -Source $expSource -ObservedUtc $expAt -Detail (([string]$expiry[1]) + $expStale).Trim() -Attention ([bool]$expiry[2])))
    } else {
        $why = 'Échéance non calculée par le contrôleur : lisez la stratégie applicable (« Lire la stratégie de mot de passe »).'
        if ($null -ne $PolicyView) { $why = [string](Get-DomeniaMember $PolicyView 'Summary' '') + ' ' + $expiryLimit }
        $facts.Add((New-DomeniaCallSheetFact -Section 'Compte' -Label 'Expiration du mot de passe' -Value 'Inconnue' -State 'NotRead' -Source $expSource -ObservedUtc $expAt -Detail $why.Trim()))
    }

    $accountRaw = Get-DomeniaAttr $Properties 'accountExpires' $null
    if (($null -eq $accountRaw) -or ([string]$accountRaw -eq '')) {
        if ($live) { $facts.Add((& $add 'Compte' 'Expiration du compte' 'Nʼexpire jamais' 'Attribut accountExpires non renseigné.')) }
        else { $facts.Add((& $missing 'Compte' 'Expiration du compte' 'accountExpires')) }
    } else {
        $accountNumber = ConvertTo-DomeniaAdInt64 $accountRaw
        if (($null -ne $accountNumber) -and (($accountNumber -eq 0L) -or ($accountNumber -eq [long]::MaxValue))) { $facts.Add((& $add 'Compte' 'Expiration du compte' 'Nʼexpire jamais' 'accountExpires sans échéance.')) }
        else {
            $accountUtc = ConvertTo-DomeniaAdDate $accountRaw
            if ($null -eq $accountUtc) { $facts.Add((New-DomeniaCallSheetFact -Section 'Compte' -Label 'Expiration du compte' -Value 'Illisible' -State 'Error' -Source $source -ObservedUtc $at -Detail 'Valeur de accountExpires illisible.')) }
            elseif ($accountUtc -le $now) { $facts.Add((& $add 'Compte' 'Expiration du compte' ('Expiré depuis le ' + (Format-DomeniaCallSheetDate $accountUtc)) 'Un compte expiré ne peut plus ouvrir de session.' $true)) }
            else { $facts.Add((& $add 'Compte' 'Expiration du compte' ('Expire le ' + (Format-DomeniaCallSheetDate $accountUtc)) 'Lu dans accountExpires.' (($accountUtc - $now).TotalDays -le 7))) }
        }
    }

    $logon = ConvertTo-DomeniaAdDate (Get-DomeniaAttr $Properties 'lastLogonTimestamp' $null)
    if ($null -ne $logon) { $facts.Add((& $add 'Compte' 'Dernière ouverture de session' ('Vers le ' + (Format-DomeniaCallSheetDate $logon -DateOnly)) 'Valeur répliquée avec un retard pouvant atteindre 14 jours.')) }
    elseif ($live) { $facts.Add((& $add 'Compte' 'Dernière ouverture de session' 'Aucune enregistrée' 'lastLogonTimestamp non renseigné : aucune ouverture répliquée.')) }
    else { $facts.Add((& $missing 'Compte' 'Dernière ouverture de session' 'lastLogonTimestamp')) }

    # Restrictions. On a directory read an absent optional attribute means no restriction.
    $hoursRead = ($live -or (Test-DomeniaCallSheetAttribute $Properties 'logonHours'))
    $hours = Get-DomeniaLogonHoursView -Value (Get-DomeniaAttr $Properties 'logonHours' $null) -Read $hoursRead -UtcOffsetMinutes $UtcOffsetMinutes -NowUtc $now
    if ([string]$hours.State -ne 'Known') {
        $facts.Add((New-DomeniaCallSheetFact -Section 'Restrictions' -Label 'Heures dʼouverture de session' -Value ([string]$hours.Summary) -State ([string]$hours.State) -Source $source -ObservedUtc $at -Detail 'Attribut logonHours.'))
    } else {
        $value = [string]$hours.Summary
        $outsideNow = (($null -ne $hours.AllowedNow) -and (-not [bool]$hours.AllowedNow) -and (-not [bool]$hours.NeverAllowed))
        if ($outsideNow) { $value += ' · en ce moment : hors des heures autorisées' }
        $detail = 'Attribut logonHours non renseigné : toutes les heures.'
        if (-not [bool]$hours.Unrestricted) { $detail = 'Heure locale de ce poste (' + [string]$hours.Offset + ') ; lʼannuaire enregistre ces plages en UTC.' }
        elseif (Test-DomeniaCallSheetAttribute $Properties 'logonHours') { $detail = 'Les 168 heures de la semaine sont autorisées dans logonHours.' }
        $facts.Add((& $add 'Restrictions' 'Heures dʼouverture de session' $value $detail (([bool]$hours.NeverAllowed) -or ($outsideNow))))
    }
    $workstationsRead = ($live -or (Test-DomeniaCallSheetAttribute $Properties 'userWorkstations'))
    $workstations = Get-DomeniaUserWorkstationsView -Value (Get-DomeniaAttrAll $Properties 'userWorkstations') -Read $workstationsRead -LinkedComputers $LinkedComputers
    if ([string]$workstations.State -ne 'Known') { $facts.Add((New-DomeniaCallSheetFact -Section 'Restrictions' -Label 'Postes autorisés' -Value ([string]$workstations.Summary) -State ([string]$workstations.State) -Source $source -ObservedUtc $at -Detail 'Attribut userWorkstations.')) }
    else { $facts.Add((& $add 'Restrictions' 'Postes autorisés' ([string]$workstations.Summary) ([string]$workstations.Detail) ([bool]$workstations.Attention))) }
    if ([bool]$state.Known) {
        if ([bool]$state.SmartcardRequired) { $facts.Add((& $add 'Restrictions' 'Carte à puce' 'Exigée : le mot de passe ne permet pas dʼouvrir une session interactive' 'Option SMARTCARD_REQUIRED de userAccountControl.' $true)) }
        else { $facts.Add((& $add 'Restrictions' 'Carte à puce' 'Non exigée' 'Lu dans userAccountControl.')) }
        if ([bool]$state.PasswordNotRequired) { $facts.Add((& $add 'Restrictions' 'Mot de passe non requis' 'Oui (PASSWD_NOTREQD) : à revoir' 'Option de userAccountControl : un mot de passe vide peut être accepté.' $true)) }
        else { $facts.Add((& $add 'Restrictions' 'Mot de passe non requis' 'Non' 'Lu dans userAccountControl.')) }
    } else {
        $facts.Add((& $missing 'Restrictions' 'Carte à puce' 'userAccountControl'))
        $facts.Add((& $missing 'Restrictions' 'Mot de passe non requis' 'userAccountControl'))
    }
    return $facts.ToArray()
}

function Get-DomeniaCallSheetLockoutFact {
    # The 4740 read of the sheet as one fact. $Read: {State; Server; Events; ObservedUtc} of the LockoutDiagnosis worker,
    # or $null when not requested; $Failure: the read could not run. A refusal or an unreachable journal concludes nothing.
    param($Read=$null,$Diagnosis=$null,[AllowEmptyString()][AllowNull()][string]$Failure='',$FailureUtc=$null)
    if ($Failure) {
        $state = 'Error'
        if (Test-DomeniaMeasureRefusal -ErrorText $Failure) { $state = 'Refused' }
        return (New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillages des 7 derniers jours' -Value 'Lecture non aboutie' -State $state -Source 'Journal Sécurité' -ObservedUtc $FailureUtc -Detail (ConvertTo-DomeniaFlatText $Failure 240))
    }
    if ($null -eq $Read) { return (New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillages des 7 derniers jours' -Value 'Non demandés' -State 'NotRead' -Source 'Journal Sécurité' -Detail 'La lecture du journal 4740 se demande explicitement : « Lire les verrouillages (4740) ».') }
    $server = [string](Get-DomeniaMember $Read 'Server' '')
    $source = 'Journal Sécurité'
    if ($server) { $source += ' de ' + $server }
    $at = Get-DomeniaMember $Read 'ObservedUtc' $null
    switch ([string](Get-DomeniaMember $Read 'State' '')) {
        'Refused' { return (New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillages des 7 derniers jours' -Value 'Lecture refusée' -State 'Refused' -Source $source -ObservedUtc $at -Detail 'Un refus ne prouve pas lʼabsence de verrouillage : le compte doit pouvoir lire le journal Sécurité du contrôleur.') }
        'Unavailable' { return (New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillages des 7 derniers jours' -Value 'Journal injoignable' -State 'Error' -Source $source -ObservedUtc $at -Detail 'Aucune conclusion sur les verrouillages passés.') }
    }
    $events = @(@(Get-DomeniaMember $Read 'Events' @()) | Where-Object { $null -ne $_ })
    if ($events.Count -eq 0) { return (New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillages des 7 derniers jours' -Value 'Aucun dans la fenêtre lue' -State 'Known' -Source $source -ObservedUtc $at -Detail 'Absence dans la fenêtre lue seulement : un journal recyclé peut ne plus contenir les événements anciens.') }
    $origins = @(Get-DomeniaMember $Diagnosis 'Origins' @())
    $value = [string]$events.Count + ' verrouillage(s)'
    if ($origins.Count) { $value += ' · postes : ' + ($origins -join ', ') }
    $state = 'Known'
    if ([bool](Get-DomeniaMember $Read 'Truncated' $false)) { $state = 'Incomplete' }
    return (New-DomeniaCallSheetFact -Section 'Compte' -Label 'Verrouillages des 7 derniers jours' -Value $value -State $state -Source $source -ObservedUtc $at -Detail 'Le poste indiqué est celui que le contrôleur a noté : une session, un lecteur réseau ou un service peut y garder un ancien mot de passe.' -Attention $true)
}

function Get-DomeniaCallSheetAttention {
    # The facts that explain a call at first glance, in sheet order: « Verrouillage : Verrouillé depuis le … ».
    param([object[]]$Facts=@())
    foreach ($fact in @($Facts)) {
        if (($null -ne $fact) -and ([bool](Get-DomeniaMember $fact 'Attention' $false))) { [string](Get-DomeniaMember $fact 'Label' '') + ' : ' + [string](Get-DomeniaMember $fact 'Value' '') }
    }
}

# ---------------------------------------------------------------- workstations and sessions
function Get-DomeniaCallSheetSessionSummary {
    # The sessions of this account on one workstation, from the view of a SessionsList read (ConvertTo-DomeniaSessionView)
    # or its failure. A failed read says nothing about the sessions; a read whose accounts were partly unread says so.
    param($View=$null,[AllowEmptyString()][AllowNull()][string]$UserLogin='',$ObservedUtc=$null,[AllowEmptyString()][AllowNull()][string]$Failure='')
    $at = ConvertTo-DomeniaUtcDate $ObservedUtc
    if ($Failure) {
        $state = 'Error'
        if (Test-DomeniaMeasureRefusal -ErrorText $Failure) { $state = 'Refused' }
        return [pscustomobject]@{State=$state;Value=('Lecture non confirmée : ' + (ConvertTo-DomeniaFlatText $Failure 160));ObservedUtc=$at;Mine=0}
    }
    if ($null -eq $View) { return [pscustomobject]@{State='NotRead';Value='Non lues';ObservedUtc=$null;Mine=0} }
    if ([string](Get-DomeniaMember $View 'ReadState' '') -cne 'Constate') { return [pscustomobject]@{State='Incomplete';Value='Réponse incomplète : aucune conclusion';ObservedUtc=$at;Mine=0} }
    $login = ([string]$UserLogin).Trim()
    if ($login.Contains('\')) { $login = $login.Split('\')[-1] }
    $rows = @(@(Get-DomeniaMember $View 'Rows' @()) | Where-Object { $null -ne $_ })
    $mine = @($rows | Where-Object { [string](Get-DomeniaMember $_ 'User' '') -ieq $login })
    $others = @($rows | Where-Object { ([bool][string](Get-DomeniaMember $_ 'User' '')) -and ([string](Get-DomeniaMember $_ 'User' '') -ine $login) }).Count
    $unread = [int](Get-DomeniaMember $View 'UnreadSessions' 0)
    $state = 'Known'
    if (($unread -gt 0) -or ([bool](Get-DomeniaMember $View 'Partial' $false))) { $state = 'Incomplete' }
    if ($mine.Count) {
        $parts = @(foreach ($row in $mine) {
            $text = [string](Get-DomeniaMember $row 'Etat' '') + ' (' + [string](Get-DomeniaMember $row 'Protocole' '') + ')'
            $opened = [string](Get-DomeniaMember $row 'Ouverte' '')
            if ($opened) { $text += ' ouverte à ' + $opened }
            $idle = [string](Get-DomeniaMember $row 'Inactive' '')
            if ($idle) { $text += ', inactive ' + $idle }
            $text
        })
        $value = 'Session de ce compte : ' + ($parts -join ' ; ')
    } else {
        $value = 'Aucune session de ce compte'
        if ($others -gt 0) { $value += ' ; ' + [string]$others + ' autre(s) session(s) avec compte' }
    }
    if ($unread -gt 0) { $value += ' ; ' + [string]$unread + ' session(s) dont le compte nʼa pas pu être lu' }
    return [pscustomobject]@{State=$state;Value=$value;ObservedUtc=$at;Mine=$mine.Count}
}

function ConvertTo-DomeniaCallSheetComputerRows {
    # The usual workstations of the account: its associations (declared first, then the most recent: Relations rule),
    # each with the presence and the console account last committed for it and the sessions read from this sheet.
    # $Targets: {Computer; Dn; Guid; Link; Observation; Sessions (Get-DomeniaCallSheetSessionSummary or $null)}. A presence
    # or a console account is an instant fact: older than InstantMinutes it keeps its value and date but is stale.
    param([object[]]$Targets=@(),[AllowEmptyString()][AllowNull()][string]$UserLogin='',[datetime]$NowUtc=[datetime]::UtcNow,[int]$InstantMinutes=15)
    $now = $NowUtc.ToUniversalTime()
    $items = @(@($Targets) | Where-Object { $null -ne $_ })
    $links = @($items | ForEach-Object { Get-DomeniaMemberValue $_ 'Link' } | Where-Object { $null -ne $_ })
    $primary = $null
    if ($links.Count) { $primary = Select-DomeniaPrimaryRelation $links }
    $login = ([string]$UserLogin).Trim()
    if ($login.Contains('\')) { $login = $login.Split('\')[-1] }
    $instant = {
        param($Measure,[string]$KnownValue)
        $state = [string]$Measure.State
        $value = [string]$Measure.Label
        if ($state -ceq 'Known') {
            $value = $KnownValue
            if (($null -ne $Measure.LastSuccessUtc) -and (($now - $Measure.LastSuccessUtc).TotalMinutes -gt [Math]::Max(1,$InstantMinutes))) { $state = 'Expired' }
        }
        [pscustomobject]@{State=$state;Value=$value;Date=(Format-DomeniaCallSheetDate $Measure.LastSuccessUtc);Reason=[string]$Measure.Reason}
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in $items) {
        $link = Get-DomeniaMemberValue $target 'Link'
        $computer = [string](Get-DomeniaMember $target 'Computer' '')
        if ((-not $computer) -and ($null -ne $link)) { $computer = [string](Get-DomeniaMember $link 'Computer' '') }
        $badge = Get-DomeniaEvidenceBadge $link
        $isPrimary = (($null -ne $link) -and ([object]::ReferenceEquals($link,$primary)))
        $qualification = [string]$badge.Label
        if ($isPrimary) { $qualification += ' · principal' }
        $observation = Get-DomeniaMemberValue $target 'Observation'
        $presenceMeasure = Get-DomeniaMeasureState -Observation $observation -Family 'Presence' -NowUtc $now -MaxDays 30 -ToleranceMinutes 5
        $presence = & $instant $presenceMeasure ([string](Get-DomeniaMember $observation 'Presence' ''))
        $consoleMeasure = Get-DomeniaMeasureState -Observation $observation -Family 'Console' -NowUtc $now -MaxDays 30 -ToleranceMinutes 5
        $current = ([string](Get-DomeniaMember $observation 'CurrentUser' '')).Trim()
        $currentName = $current
        if ($currentName.Contains('\')) { $currentName = $currentName.Split('\')[-1] }
        $consoleText = 'Aucun compte en console'
        if (([bool]$current) -and ([bool]$login) -and ($currentName -ieq $login)) { $consoleText = 'Ce compte est en console' }
        elseif ($current) { $consoleText = 'Autre compte en console : ' + $current }
        $console = & $instant $consoleMeasure $consoleText
        $sessions = Get-DomeniaMemberValue $target 'Sessions'
        if ($null -eq $sessions) { $sessions = [pscustomobject]@{State='NotRead';Value='Non lues';ObservedUtc=$null;Mine=0} }
        $sessionState = [string](Get-DomeniaMember $sessions 'State' 'NotRead')
        $detail = [string]$badge.Rule
        foreach ($part in @(@('Présence',$presence),@('Console',$console))) {
            if ([string]$part[1].State -cne 'Known') { $detail += ' ' + [string]$part[0] + ' : ' + [string]$part[1].Reason }
        }
        $rows.Add([pscustomobject]@{
            Computer=$computer;Dn=[string](Get-DomeniaMember $target 'Dn' '');Guid=[string](Get-DomeniaMember $target 'Guid' '');Primary=$isPrimary
            Qualification=$qualification;AssociatedText=(Format-DomeniaRelationWhen (Get-DomeniaMember $link 'When' '') -NowUtc $now);Rule=[string]$badge.Rule
            PresenceValue=$presence.Value;PresenceState=$presence.State;PresenceStateLabel=(Get-DomeniaMeasureStateLabel $presence.State);PresenceDate=$presence.Date
            ConsoleValue=$console.Value;ConsoleState=$console.State;ConsoleStateLabel=(Get-DomeniaMeasureStateLabel $console.State);ConsoleDate=$console.Date
            SessionValue=[string](Get-DomeniaMember $sessions 'Value' '');SessionState=$sessionState;SessionStateLabel=(Get-DomeniaMeasureStateLabel $sessionState);SessionDate=(Format-DomeniaCallSheetDate (Get-DomeniaMember $sessions 'ObservedUtc' $null))
            SortKey=(Get-DomeniaRelationWhenSortKey (Get-DomeniaMember $link 'When' ''));Detail=$detail.Trim()
        })
    }
    return @($rows.ToArray() | Sort-Object @{Expression={[bool]$_.Primary};Descending=$true},@{Expression={$_.SortKey};Descending=$true},@{Expression={[string]$_.Computer};Descending=$false})
}

# ---------------------------------------------------------------- groups
function Get-DomeniaCallSheetGroupSummary {
    # Direct groups of the fiche (memberOf; the primary group apart), the privileged ones named, and the changes seen in
    # this session: $Baseline is the memberOf of the first sheet of this account in the session ($null: first sheet),
    # $BaselineUtc its time. No local history of memberships exists (the directory snapshots carry no group): nothing
    # older is claimed.
    param($Properties,[AllowEmptyString()][AllowNull()][string]$Origin='',$ObservedUtc=$null,[string[]]$Baseline=$null,$BaselineUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow,[int]$FreshMinutes=15)
    $originView = Get-DomeniaCallSheetOrigin -Origin $Origin -ObservedUtc $ObservedUtc -NowUtc $NowUtc -FreshMinutes $FreshMinutes
    $source = [string]$originView.Source; $at = $originView.ObservedUtc
    $present = Test-DomeniaCallSheetAttribute $Properties 'memberOf'
    $current = @(@(Get-DomeniaAttrAll $Properties 'memberOf') | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $completeRaw = Get-DomeniaAttr $Properties '__memberOfComplete' $null
    $note = [string](Get-DomeniaAttr $Properties '__memberOfNote' '')
    $state = [string]$originView.State
    $detail = 'Groupes directs seulement : les groupes imbriqués et les droits effectifs se lisent dans Appartenances.'
    if ((-not $present) -and (-not [bool]$originView.Live)) { $state = 'NotRead'; $detail = 'memberOf absent de la fiche affichée : relisez la fiche depuis lʼannuaire.' }
    elseif (($null -ne $completeRaw) -and ([string]$completeRaw -notmatch '^(?i:true|1)$')) { $state = 'Incomplete'; $detail = 'Lecture des appartenances partielle' + $(if($note){' : ' + (ConvertTo-DomeniaFlatText $note 160)}else{'.'}) }
    $key = { param([string]$Dn) $Dn.Trim().ToLowerInvariant() }
    $currentSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($dn in $current) { [void]$currentSet.Add((& $key $dn)) }
    $baselineSet = $null
    if ($null -ne $Baseline) {
        $baselineSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($dn in @($Baseline)) { if ([string]$dn) { [void]$baselineSet.Add((& $key ([string]$dn))) } }
    }
    $since = Format-DomeniaCallSheetDate $BaselineUtc
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $privileged = New-Object 'System.Collections.Generic.List[string]'
    $added = 0
    foreach ($dn in $current) {
        $name = Get-DomeniaDnDisplayName $dn
        $isPrivileged = Test-DomeniaPrivilegedGroup ([pscustomobject]@{Name=$name})
        if ($isPrivileged) { $privileged.Add($name) }
        $change = ''
        if (($null -ne $baselineSet) -and (-not $baselineSet.Contains((& $key $dn)))) { $change = 'Ajouté depuis ' + $since; $added++ }
        $rows.Add([pscustomobject]@{Name=$name;Dn=$dn;Nature=$(if($isPrivileged){'Privilégié'}else{'Standard'});Change=$change;Privileged=$isPrivileged;Removed=$false})
    }
    $removed = 0
    if ($null -ne $baselineSet) {
        foreach ($dn in @($Baseline)) {
            if ((-not [string]$dn) -or ($currentSet.Contains((& $key ([string]$dn))))) { continue }
            $removed++
            $rows.Add([pscustomobject]@{Name=(Get-DomeniaDnDisplayName ([string]$dn));Dn=[string]$dn;Nature='';Change=('Retiré depuis ' + $since);Privileged=$false;Removed=$true})
        }
    }
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $countText = [string]$current.Count + ' groupe(s) direct(s)'
    if ($privileged.Count) { $countText += ', dont ' + [string]$privileged.Count + ' privilégié(s) : ' + ($privileged.ToArray() -join ', ') }
    $facts.Add((New-DomeniaCallSheetFact -Section 'Groupes' -Label 'Groupes directs' -Value $countText -State $state -Source $source -ObservedUtc $at -Detail $detail))
    $primaryId = ([string](Get-DomeniaAttr $Properties 'primaryGroupID' '')).Trim()
    if ($primaryId) {
        $names = @{'513'='Utilisateurs du domaine';'512'='Admins du domaine';'514'='Invités du domaine';'515'='Ordinateurs du domaine'}
        $primaryText = 'RID ' + $primaryId
        if ($names.ContainsKey($primaryId)) { $primaryText = [string]$names[$primaryId] + ' (RID ' + $primaryId + ')' }
        $facts.Add((New-DomeniaCallSheetFact -Section 'Groupes' -Label 'Groupe principal' -Value $primaryText -State ([string]$originView.State) -Source $source -ObservedUtc $at -Detail 'primaryGroupID : ce groupe nʼapparaît pas dans memberOf.' -Attention ($primaryId -eq '512')))
    }
    $history = 'Aucun historique local des appartenances : les relevés de lʼannuaire ne contiennent pas les groupes.'
    if ($null -eq $baselineSet) {
        $facts.Add((New-DomeniaCallSheetFact -Section 'Groupes' -Label 'Changements récents' -Value 'Première fiche de ce compte dans la session : rien à comparer' -State 'NotRead' -Source 'Fiches de cette session' -Detail $history))
    } elseif (($added -eq 0) -and ($removed -eq 0)) {
        $facts.Add((New-DomeniaCallSheetFact -Section 'Groupes' -Label 'Changements récents' -Value ('Aucun depuis ' + $since) -State $state -Source 'Fiches de cette session' -ObservedUtc $at -Detail $history))
    } else {
        $facts.Add((New-DomeniaCallSheetFact -Section 'Groupes' -Label 'Changements récents' -Value ([string]$added + ' ajout(s), ' + [string]$removed + ' retrait(s) depuis ' + $since) -State $state -Source 'Fiches de cette session' -ObservedUtc $at -Detail $history -Attention $true))
    }
    $sortedRows = @($rows.ToArray() | Sort-Object @{Expression={[bool]$_.Removed};Descending=$false},@{Expression={[bool]$_.Privileged};Descending=$true},@{Expression={[string]$_.Name};Descending=$false})
    return [pscustomobject]@{Facts=$facts.ToArray();Rows=$sortedRows;Count=$current.Count;Privileged=$privileged.ToArray();Added=$added;Removed=$removed;Current=$current;State=$state}
}

# ---------------------------------------------------------------- receipts
function ConvertTo-DomeniaCallSheetReceiptSummary {
    # The durable receipts of Domenia whose target is this account (Get-DomeniaReceiptView rows), newest first, at most
    # $Limit. $Views $null: the receipts were not read in this session, nothing is concluded.
    param([object[]]$Views=$null,[AllowEmptyString()][AllowNull()][string]$Dn='',$ReadUtc=$null,[int]$Limit=10)
    $source = 'Reçus durables de Domenia'
    if ($null -eq $Views) {
        $fact = New-DomeniaCallSheetFact -Section 'Opérations' -Label 'Opérations Domenia' -Value 'Reçus non lus' -State 'NotRead' -Source $source -Detail 'Les reçus se relisent depuis le disque local : « Relire les reçus ».'
        return [pscustomobject]@{Fact=$fact;Rows=@();Total=0;Pending=0}
    }
    $target = ([string]$Dn).Trim()
    $mine = @(@($Views) | Where-Object { ($null -ne $_) -and ([bool]$target) -and ([string](Get-DomeniaMember $_ 'DN' '') -ieq $target) })
    $sorted = @($mine | Sort-Object @{Expression={$d = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $_ 'UpdatedUtc' $null); if ($null -eq $d) { [datetime]::MinValue } else { $d }};Descending=$true})
    $pending = @($mine | Where-Object { [bool](Get-DomeniaMember $_ 'Pending' $false) }).Count
    $rows = @($sorted | Select-Object -First ([Math]::Max(1,$Limit)) | ForEach-Object {
        [pscustomobject]@{Date=[string](Get-DomeniaMember $_ 'UpdatedLabel' '');Operation=[string](Get-DomeniaMember $_ 'OperationLabel' '');Stage=[string](Get-DomeniaMember $_ 'StageLabel' '');Pending=[bool](Get-DomeniaMember $_ 'Pending' $false);Explanation=[string](Get-DomeniaMember $_ 'Explanation' '')}
    })
    if ($mine.Count -eq 0) { $value = 'Aucun reçu sur ce compte' }
    else {
        $value = [string]$mine.Count + ' reçu(s) sur ce compte'
        if ($pending -gt 0) { $value += ', dont ' + [string]$pending + ' à vérifier' }
    }
    $detail = 'Opérations dont la cible est ce compte ; une opération sur un groupe porte le nom du groupe.'
    if ($mine.Count -gt $rows.Count) { $detail += ' Les ' + [string]$rows.Count + ' plus récentes sont listées.' }
    $fact = New-DomeniaCallSheetFact -Section 'Opérations' -Label 'Opérations Domenia' -Value $value -State 'Known' -Source $source -ObservedUtc $ReadUtc -Detail $detail -Attention ($pending -gt 0)
    return [pscustomobject]@{Fact=$fact;Rows=$rows;Total=$mine.Count;Pending=$pending}
}

# ---------------------------------------------------------------- slow workstation triage
function Get-DomeniaCallSheetTriageFacts {
    # Quick triage of a slow workstation from its last quick inventory (ComputerInventory, committed then read back):
    # processor, memory, system disk, other volumes, most active processes, last start and pending restart, each with the
    # date of the inventory. Instant values (processor, memory, processes) older than InstantMinutes are stale, the others
    # after MaxDays. $Failure: the last attempt failed (said beside the last success, which keeps its own date).
    # $Thresholds: {DiskFreeAlert; DiskFreeWarn; MemoryUsedWarn; UptimeDays} of the health policy of the workstation.
    param($Inventory=$null,[AllowEmptyString()][AllowNull()][string]$Computer='',[AllowEmptyString()][AllowNull()][string]$Failure='',$FailureUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow,[int]$InstantMinutes=60,[int]$MaxDays=30,$Thresholds=$null)
    $now = $NowUtc.ToUniversalTime()
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $labels = @('Processeur','Mémoire','Disque système','Autres volumes','Processus les plus actifs','Démarrage','Redémarrage en attente')
    $instantLabels = @('Processeur','Mémoire','Processus les plus actifs')
    $source = 'Inventaire rapide'
    if ($Computer) { $source += ' de ' + $Computer }
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $failureState = 'Error'
    if (([bool]$Failure) -and (Test-DomeniaMeasureRefusal -ErrorText $Failure)) { $failureState = 'Refused' }
    $attempt = {
        if (-not $Failure) { return }
        $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Dernière tentative' -Value ('Non confirmée : ' + (ConvertTo-DomeniaFlatText $Failure 160)) -State $failureState -Source $source -ObservedUtc $FailureUtc -Detail 'Les valeurs ci-dessus gardent la date de la dernière lecture réussie.'))
    }
    if ($null -eq $Inventory) {
        foreach ($label in $labels) {
            if ($Failure) { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label $label -Value 'Inventaire non confirmé' -State $failureState -Source $source -ObservedUtc $FailureUtc -Detail 'Aucune lecture réussie enregistrée pour ce poste.')) }
            else { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label $label -Value 'Aucun inventaire enregistré' -State 'Absent' -Source $source -Detail '« Trier la lenteur du poste » lance lʼinventaire rapide de ce poste.')) }
        }
        & $attempt
        return $facts.ToArray()
    }
    $observed = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Inventory 'SourceCompletedUtc' $null)
    $instantState = 'Known'; $durableState = 'Known'; $ageText = ''
    if (($null -eq $observed) -or ($observed -gt $now.AddMinutes(5))) {
        foreach ($label in $labels) { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label $label -Value 'Date dʼinventaire illisible ou future' -State 'Error' -Source $source -Detail 'La mesure nʼest pas utilisée : horloge à vérifier.')) }
        & $attempt
        return $facts.ToArray()
    }
    $ageMinutes = ($now - $observed).TotalMinutes
    if ($ageMinutes -gt [Math]::Max(1,$InstantMinutes)) { $instantState = 'Expired' }
    if ($ageMinutes -gt ([Math]::Max(1,$MaxDays) * 1440.0)) { $durableState = 'Expired' }
    $staleInstant = ''
    if ($instantState -ne 'Known') { $staleInstant = ' Mesure instantanée de plus de ' + [string][Math]::Max(1,$InstantMinutes) + ' min : relancez le tri pour lʼétat actuel.' }
    $limit = { param([string]$Name,[int]$Default) $n = 0; if ([int]::TryParse([string](Get-DomeniaMember $Thresholds $Name ''),[ref]$n)) { return $n }; return $Default }
    $diskAlert = & $limit 'DiskFreeAlert' 10; $diskWarn = & $limit 'DiskFreeWarn' 20; $memoryWarn = & $limit 'MemoryUsedWarn' 90; $uptimeDays = & $limit 'UptimeDays' 30
    $rows = @(@(Get-DomeniaMember $Inventory 'Rows' @()) | Where-Object { $null -ne $_ })
    $metrics = Get-DomeniaMemberValue $Inventory 'Metrics'
    $number = { param($Value) $d = 0.0; if (($null -ne $Value) -and ([double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d))) { return $d }; return $null }
    $size = { param([double]$Bytes) if ($Bytes -ge 1TB) { return ($Bytes / 1TB).ToString('0.#',$fr) + ' To' }; if ($Bytes -ge 1GB) { return ($Bytes / 1GB).ToString('0.#',$fr) + ' Go' }; return ($Bytes / 1MB).ToString('0',$fr) + ' Mo' }
    $value = {
        param([string]$Category,[string]$Item)
        foreach ($row in $rows) {
            if (([string](Get-DomeniaMember $row 'Category' '') -ceq $Category) -and ([string](Get-DomeniaMember $row 'Item' '') -ceq $Item)) {
                $text = ([string](Get-DomeniaMember $row 'Value' '')).Trim()
                if ($text -match '^\(vide\)$|^Non renseigne$|^Non fourni|^Aucun$') { return '' }
                return $text
            }
        }
        return ''
    }
    $notMeasured = { param([string]$Label,[string]$What) New-DomeniaCallSheetFact -Section 'Poste' -Label $Label -Value 'Non mesuré' -State 'NotRead' -Source $source -ObservedUtc $observed -Detail ($What + ' absent de cet inventaire.') }

    $cpu = & $number (Get-DomeniaMember $metrics 'CpuLoad' $null)
    if (($null -ne $cpu) -and ($cpu -ge 0)) { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Processeur' -Value ($cpu.ToString('0',$fr) + ' % de charge') -State $instantState -Source $source -ObservedUtc $observed -Detail ('Charge au moment de lʼinventaire.' + $staleInstant) -Attention (($instantState -eq 'Known') -and ($cpu -ge 90)))) }
    else { $facts.Add((& $notMeasured 'Processeur' 'La charge du processeur est')) }

    $memoryTotal = & $number (Get-DomeniaMember $metrics 'MemoryTotal' $null)
    $memoryFree = & $number (Get-DomeniaMember $metrics 'MemoryFree' $null)
    if (($null -ne $memoryTotal) -and ($memoryTotal -gt 0) -and ($null -ne $memoryFree)) {
        $used = [Math]::Max(0.0,$memoryTotal - $memoryFree)
        $percent = 100.0 * $used / $memoryTotal
        $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Mémoire' -Value ($percent.ToString('0',$fr) + ' % utilisés (' + (& $size $used) + ' sur ' + (& $size $memoryTotal) + ')') -State $instantState -Source $source -ObservedUtc $observed -Detail ('Seuil de surveillance : ' + [string]$memoryWarn + ' %.' + $staleInstant) -Attention (($instantState -eq 'Known') -and ($percent -gt $memoryWarn))))
    } else { $facts.Add((& $notMeasured 'Mémoire' 'La mémoire libre est')) }

    $disks = @(@(Get-DomeniaMember $metrics 'Disks' @()) | Where-Object { ($null -ne $_) -and ((& $number (Get-DomeniaMember $_ 'Size' $null)) -gt 0) })
    $system = @($disks | Where-Object { [string](Get-DomeniaMember $_ 'Name' '') -ieq 'C:' } | Select-Object -First 1)
    if (-not $system.Count) { $system = @($disks | Select-Object -First 1) }
    if ($system.Count) {
        $disk = $system[0]; $diskSize = & $number (Get-DomeniaMember $disk 'Size' $null); $diskFree = & $number (Get-DomeniaMember $disk 'Free' $null)
        if ($null -eq $diskFree) { $diskFree = 0.0 }
        $freePercent = 100.0 * $diskFree / $diskSize
        $text = [string](Get-DomeniaMember $disk 'Name' '') + ' : ' + $freePercent.ToString('0',$fr) + ' % libres (' + (& $size $diskFree) + ' sur ' + (& $size $diskSize) + ')'
        if ($freePercent -lt $diskAlert) { $text += ', presque plein' }
        $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Disque système' -Value $text -State $durableState -Source $source -ObservedUtc $observed -Detail ('Seuils : critique sous ' + [string]$diskAlert + ' %, à surveiller sous ' + [string]$diskWarn + ' %.') -Attention ($freePercent -lt $diskWarn)))
        $others = @($disks | Where-Object { [string](Get-DomeniaMember $_ 'Name' '') -ine [string](Get-DomeniaMember $disk 'Name' '') })
        if ($others.Count) {
            $worst = $null; $worstPercent = 101.0
            foreach ($other in $others) {
                $p = 100.0 * (& $number (Get-DomeniaMember $other 'Free' 0)) / (& $number (Get-DomeniaMember $other 'Size' 1))
                if ($p -lt $worstPercent) { $worst = $other; $worstPercent = $p }
            }
            $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Autres volumes' -Value ([string]$others.Count + ' volume(s), le moins libre ' + [string](Get-DomeniaMember $worst 'Name' '') + ' : ' + $worstPercent.ToString('0',$fr) + ' % libres') -State $durableState -Source $source -ObservedUtc $observed -Detail 'Volumes logiques locaux lus pendant lʼinventaire.' -Attention ($worstPercent -lt $diskAlert)))
        } else { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Autres volumes' -Value 'Aucun autre volume' -State $durableState -Source $source -ObservedUtc $observed -Detail 'Seul le disque système est monté, selon lʼinventaire.')) }
    } else {
        $facts.Add((& $notMeasured 'Disque système' 'Lʼespace des disques est'))
        $facts.Add((& $notMeasured 'Autres volumes' 'Lʼespace des disques est'))
    }

    $sample = Get-DomeniaMemberValue $metrics 'ProcessSample'
    $load = $null
    if ($null -ne $sample) { $load = Measure-DomeniaProcessLoad -Sample $sample -Top 50 }
    $processes = @(@(Get-DomeniaMember $metrics 'Processes' @()) | Where-Object { $null -ne $_ })
    if (($null -ne $load) -and ([bool]$load.Measured) -and (@($load.Items).Count -gt 0)) {
        $byName = @{}
        foreach ($item in @($load.Items)) { $name = [string]$item.Name; if (-not $byName.ContainsKey($name)) { $byName[$name] = 0.0 }; $byName[$name] = [double]$byName[$name] + [double]$item.Percent }
        $top = @($byName.Keys | Sort-Object @{Expression={[double]$byName[$_]};Descending=$true},@{Expression={[string]$_};Descending=$false} | Select-Object -First 5)
        $text = (@($top | ForEach-Object { [string]$_ + ' ' + ([double]$byName[$_]).ToString('0.#',$fr) + ' %' }) -join ' · ')
        $when = $observed
        if ($null -ne $load.SampledUtc) { $when = $load.SampledUtc }
        $interval = ''
        if ($null -ne $load.IntervalMs) { $interval = ' sur ' + ([double]$load.IntervalMs / 1000.0).ToString('0.#',$fr) + ' s' }
        $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Processus les plus actifs' -Value $text -State $instantState -Source $source -ObservedUtc $when -Detail ('Part du processeur' + $interval + ', total mesuré ' + ([double]$load.TotalPercent).ToString('0.#',$fr) + ' %.' + $staleInstant)))
    } elseif ($processes.Count) {
        $groups = @{}
        foreach ($process in $processes) { $name = [string](Get-DomeniaMember $process 'Name' ''); if (-not $groups.ContainsKey($name)) { $groups[$name] = 0.0 }; $mb = & $number (Get-DomeniaMember $process 'Mb' 0); if ($null -ne $mb) { $groups[$name] = [double]$groups[$name] + $mb } }
        $top = @($groups.Keys | Sort-Object @{Expression={[double]$groups[$_]};Descending=$true},@{Expression={[string]$_};Descending=$false} | Select-Object -First 5)
        $text = (@($top | ForEach-Object { [string]$_ + ' ' + ([double]$groups[$_]).ToString('0',$fr) + ' Mo' }) -join ' · ')
        $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Processus les plus actifs' -Value $text -State $instantState -Source $source -ObservedUtc $observed -Detail ('Mémoire utilisée par processus : la part du processeur nʼa pas été mesurée par cet inventaire.' + $staleInstant)))
    } else { $facts.Add((& $notMeasured 'Processus les plus actifs' 'La liste des processus est')) }

    $uptime = & $value 'Systeme d exploitation' 'Duree de fonctionnement'
    $boot = & $value 'Systeme d exploitation' 'Dernier demarrage'
    if (([bool]$uptime) -or ([bool]$boot)) {
        $days = -1
        if ($uptime -match '^(\d+) j') { $days = [int]$Matches[1] }
        if (([bool]$boot) -and ([bool]$uptime)) { $text = 'Démarré le ' + $boot + ' (depuis ' + $uptime + ' au moment de lʼinventaire)' }
        elseif ($boot) { $text = 'Démarré le ' + $boot }
        else { $text = 'En fonctionnement depuis ' + $uptime + ' au moment de lʼinventaire' }
        $long = ($days -gt $uptimeDays)
        $detail = 'Seuil de redémarrage ancien : ' + [string]$uptimeDays + ' jours.'
        if ($long) { $detail = 'Plus de ' + [string]$uptimeDays + ' jours sans redémarrage : un redémarrage est conseillé.' }
        $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Démarrage' -Value $text -State $durableState -Source $source -ObservedUtc $observed -Detail $detail -Attention $long))
    } else { $facts.Add((& $notMeasured 'Démarrage' 'Le dernier démarrage est')) }

    $reboot = Get-DomeniaPendingRebootReading $rows
    switch ([string]$reboot.State) {
        'Required' { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Redémarrage en attente' -Value ('Oui : ' + (@($reboot.Confirmed) -join ', ')) -State $durableState -Source $source -ObservedUtc $observed -Detail ([string]$reboot.Detail) -Attention $true)) }
        'Partial' { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Redémarrage en attente' -Value ('Indices partiels : ' + (@($reboot.Partial) -join ', ')) -State $durableState -Source $source -ObservedUtc $observed -Detail ([string]$reboot.Detail))) }
        'None' { $facts.Add((New-DomeniaCallSheetFact -Section 'Poste' -Label 'Redémarrage en attente' -Value 'Non' -State $durableState -Source $source -ObservedUtc $observed -Detail ([string]$reboot.Detail))) }
        default { $facts.Add((& $notMeasured 'Redémarrage en attente' 'Lʼétat de redémarrage est')) }
    }
    if ($Failure) {
        $failedAt = ConvertTo-DomeniaUtcDate $FailureUtc
        if (($null -eq $failedAt) -or ($failedAt -gt $observed)) { & $attempt }
    }
    return $facts.ToArray()
}

# ---------------------------------------------------------------- ticket
function Get-DomeniaCallSheetTemplatePlaceholders {
    # The placeholders a ticket template may use, between braces: {Compte}, {Postes}…
    return @('Date','NomAffiche','Identifiant','UPN','PointsAttention','Compte','Restrictions','Postes','Groupes','Operations','Triage')
}

function Get-DomeniaCallSheetDefaultTemplate {
    # Default text of « Copier pour le ticket ». CallSheet.TicketTemplate of Domenia.config.json replaces it.
    return (@(
        'Fiche dʼappel Domenia du {Date}'
        'Compte : {NomAffiche} ({Identifiant}, {UPN})'
        'À noter : {PointsAttention}'
        ''
        'Compte'
        '{Compte}'
        ''
        'Restrictions dʼouverture de session'
        '{Restrictions}'
        ''
        'Postes et sessions'
        '{Postes}'
        ''
        'Groupes'
        '{Groupes}'
        ''
        'Opérations Domenia sur ce compte'
        '{Operations}'
        ''
        'Poste lent : tri rapide'
        '{Triage}'
        ''
        'Faits relevés par Domenia, chacun avec sa source et sa date ; une valeur inconnue reste inconnue.'
    ) -join "`n")
}

function Resolve-DomeniaCallSheetTemplate {
    # The template in force: CallSheet.TicketTemplate (a text, or an array of lines) when it is usable, else the default
    # one with the reason. Refused: more than 4 000 characters, control characters other than line breaks and tabs, or
    # no known placeholder at all (a fixed text would hide every fact).
    param($Configured=$null)
    $default = Get-DomeniaCallSheetDefaultTemplate
    if ($null -eq $Configured) { return [pscustomobject]@{Text=$default;Source='Défaut';Warning=''} }
    $text = ''
    if ($Configured -is [string]) { $text = $Configured }
    elseif ($Configured -is [Collections.IEnumerable]) { $text = (@(foreach ($line in $Configured) { [string]$line }) -join "`n") }
    else { $text = [string]$Configured }
    $text = $text -replace "`r`n","`n"
    if (-not $text.Trim()) { return [pscustomobject]@{Text=$default;Source='Défaut';Warning=''} }
    $reason = ''
    if ($text.Length -gt 4000) { $reason = 'modèle de plus de 4 000 caractères' }
    elseif ($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { $reason = 'caractères de contrôle dans le modèle' }
    else {
        $known = $false
        foreach ($match in [regex]::Matches($text,'\{([A-Za-z]+)\}')) { if ([string]$match.Groups[1].Value -in @(Get-DomeniaCallSheetTemplatePlaceholders)) { $known = $true; break } }
        if (-not $known) { $reason = 'aucun champ connu entre accolades' }
    }
    if ($reason) { return [pscustomobject]@{Text=$default;Source='Défaut';Warning=('Modèle CallSheet.TicketTemplate ignoré (' + $reason + ') : modèle par défaut.')} }
    return [pscustomobject]@{Text=$text;Source='Configuration';Warning=''}
}

function ConvertTo-DomeniaCallSheetFactLine {
    # One plain-text line of a fact: « Verrouillage : Verrouillé depuis le 21/10/2026 08:12 (fiche lue dans lʼannuaire,
    # 21/10/2026 08:15) ». A state other than Known is written between brackets: an unknown value never reads as a fact.
    param($Fact)
    if ($null -eq $Fact) { return '' }
    $line = '- ' + [string](Get-DomeniaMember $Fact 'Label' '') + ' : ' + [string](Get-DomeniaMember $Fact 'Value' '')
    $state = [string](Get-DomeniaMember $Fact 'State' 'Known')
    if ($state -cne 'Known') { $line += ' [' + (Get-DomeniaMeasureStateLabel $state) + ']' }
    $origin = @(@([string](Get-DomeniaMember $Fact 'Source' ''),[string](Get-DomeniaMember $Fact 'DateText' '')) | Where-Object { $_ })
    if ($origin.Count) { $line += ' (' + ($origin -join ', ') + ')' }
    return $line
}

function Get-DomeniaCallSheetTicketValues {
    # Placeholder values of the ticket from one built sheet: {Subject {DisplayName; Login; Upn}; AccountFacts;
    # ComputerRows; GroupSummary; ReceiptSummary; TriageComputer; TriageFacts}. An empty section says so in words.
    param($Sheet,[datetime]$NowUtc=[datetime]::UtcNow)
    $lines = { param([object[]]$Facts) $out = @(foreach ($fact in @($Facts)) { if ($null -ne $fact) { ConvertTo-DomeniaCallSheetFactLine $fact } }); if ($out.Count) { return ($out -join "`n") }; return '- Aucun fait relevé.' }
    $subject = Get-DomeniaMember $Sheet 'Subject' $null
    $account = @(Get-DomeniaMember $Sheet 'AccountFacts' @())
    $attention = @(Get-DomeniaCallSheetAttention -Facts @(@($account) + @(Get-DomeniaMember (Get-DomeniaMember $Sheet 'GroupSummary' $null) 'Facts' @()) + @(Get-DomeniaMember (Get-DomeniaMember $Sheet 'ReceiptSummary' $null) 'Fact' $null) + @(Get-DomeniaMember $Sheet 'TriageFacts' @())))
    $computers = @(foreach ($row in @(Get-DomeniaMember $Sheet 'ComputerRows' @())) {
        if ($null -eq $row) { continue }
        $text = '- ' + [string]$row.Computer + ' (' + [string]$row.Qualification
        if ([string]$row.AssociatedText) { $text += ', associé le ' + [string]$row.AssociatedText }
        $text += ') : présence ' + [string]$row.PresenceValue
        if ([string]$row.PresenceState -cne 'Known') { $text += ' [' + [string]$row.PresenceStateLabel + ']' }
        if ([string]$row.PresenceDate) { $text += ' (' + [string]$row.PresenceDate + ')' }
        $text += ' ; console : ' + [string]$row.ConsoleValue
        if ([string]$row.ConsoleState -cne 'Known') { $text += ' [' + [string]$row.ConsoleStateLabel + ']' }
        $text += ' ; sessions : ' + [string]$row.SessionValue
        if ([string]$row.SessionDate) { $text += ' (' + [string]$row.SessionDate + ')' }
        $text
    })
    $groups = Get-DomeniaMember $Sheet 'GroupSummary' $null
    $groupLines = & $lines @(Get-DomeniaMember $groups 'Facts' @())
    $changes = @(@(Get-DomeniaMember $groups 'Rows' @()) | Where-Object { [string](Get-DomeniaMember $_ 'Change' '') } | ForEach-Object { '  ' + [string]$_.Name + ' : ' + [string]$_.Change })
    if ($changes.Count) { $groupLines += "`n" + ($changes -join "`n") }
    $receipts = Get-DomeniaMember $Sheet 'ReceiptSummary' $null
    $operationLines = & $lines @(Get-DomeniaMember $receipts 'Fact' $null)
    $recent = @(@(Get-DomeniaMember $receipts 'Rows' @()) | Select-Object -First 5 | ForEach-Object { '  ' + [string]$_.Date + ' · ' + [string]$_.Operation + ' · ' + [string]$_.Stage })
    if ($recent.Count) { $operationLines += "`n" + ($recent -join "`n") }
    $triageComputer = [string](Get-DomeniaMember $Sheet 'TriageComputer' '')
    $triage = '- Aucun poste associé : tri non disponible.'
    if ($triageComputer) { $triage = 'Poste ' + $triageComputer + "`n" + (& $lines @(Get-DomeniaMember $Sheet 'TriageFacts' @())) }
    $points = 'rien de particulier relevé'
    if ($attention.Count) { $points = $attention -join ' · ' }
    $values = [ordered]@{}
    $values['Date'] = Format-DomeniaCallSheetDate $NowUtc
    $values['NomAffiche'] = [string](Get-DomeniaMember $subject 'DisplayName' '')
    $values['Identifiant'] = [string](Get-DomeniaMember $subject 'Login' '')
    $values['UPN'] = [string](Get-DomeniaMember $subject 'Upn' '')
    $values['PointsAttention'] = $points
    $values['Compte'] = & $lines @($account | Where-Object { [string](Get-DomeniaMember $_ 'Section' '') -ceq 'Compte' })
    $values['Restrictions'] = & $lines @($account | Where-Object { [string](Get-DomeniaMember $_ 'Section' '') -ceq 'Restrictions' })
    $values['Postes'] = $(if ($computers.Count) { $computers -join "`n" } else { '- Aucun poste associé à ce compte.' })
    $values['Groupes'] = $groupLines
    $values['Operations'] = $operationLines
    $values['Triage'] = $triage
    return $values
}

function ConvertTo-DomeniaCallSheetTicket {
    # The plain text copied for a ticket: the template with its placeholders replaced, CRLF line ends, masked by the secret
    # rule of the journal (Protect-DomeniaSecretText) and bounded by MaxLength. A placeholder the sheet does not know is
    # left as written, so that a mistyped template shows itself. Returns {Text; Masked; Truncated; Unknown}.
    param([AllowEmptyString()][AllowNull()][string]$Template='',[Collections.IDictionary]$Values=$null,[int]$MaxLength=8000)
    $map = @{}
    if ($null -ne $Values) { foreach ($key in @($Values.Keys)) { $map[([string]$key).ToLowerInvariant()] = [string]$Values[$key] } }
    $unknown = New-Object 'System.Collections.Generic.List[string]'
    $builder = New-Object System.Text.StringBuilder
    $position = 0
    $source = [string]$Template
    foreach ($match in [regex]::Matches($source,'\{([A-Za-z]+)\}')) {
        [void]$builder.Append($source.Substring($position,$match.Index - $position))
        $name = [string]$match.Groups[1].Value
        if ($map.ContainsKey($name.ToLowerInvariant())) { [void]$builder.Append([string]$map[$name.ToLowerInvariant()]) }
        else {
            [void]$builder.Append($match.Value)
            if (-not $unknown.Contains($name)) { $unknown.Add($name) }
        }
        $position = $match.Index + $match.Length
    }
    [void]$builder.Append($source.Substring($position))
    $text = (($builder.ToString() -replace "`r`n","`n") -replace "`r","`n").TrimEnd()
    $protected = Protect-DomeniaSecretText $text
    $wasMasked = ($protected -cne $text)
    $truncated = $false
    $limit = [Math]::Max(200,$MaxLength)
    if ($protected.Length -gt $limit) {
        $protected = $protected.Substring(0,$limit) + "`n[" + [string][char]0x2026 + '] Texte tronqué à ' + [string]$limit + ' caractères.'
        $truncated = $true
    }
    return [pscustomobject]@{Text=($protected -replace "`n","`r`n");Masked=$wasMasked;Truncated=$truncated;Unknown=$unknown.ToArray()}
}
