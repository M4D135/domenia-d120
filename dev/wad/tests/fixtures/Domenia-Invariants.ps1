# Point 128: automatic invariant checks shared by the Domenia test suites (rules, load, storage and network faults).
# Test-only file: dot-sourced by wad/tests, never loaded by the application. Pure checks: no disk, no network, no WPF.
# A check never throws on bad data: it returns violations, so one run reports every broken invariant and the suite
# decides. A violation is {Invariant; Subject; Expected; Actual; Text}.
#
# Invariants (roadmap point 128):
#   WidgetDetail   the number a widget shows, and each of its segments, equals the number of distinct GUIDs of the
#                  detailed list behind it; the segments add up to the matched population; Total equals
#                  Matched + NotMatched + Unknown.
#   RenderDated    a rendered figure carries the UTC date of the computation it shows: present, parseable, not the
#                  default date, not later than now plus the allowed clock skew.
#   UnknownKept    an unknown result stays unknown: the count of unknown values equals the source count, it is not
#                  folded into a known value, and a displayed unknown never reads as zero, no or empty.
#   CurrentAnswer  a response is applied only to the selection that requested it (session epoch, generation, reader,
#                  object GUID): an answer of an older selection is never applied.
# The oracle is independent of the application rules (Test-DomeniaIdentityCurrent, SelectionIdentity.SameContext):
# fields are compared directly, so a weakened production rule is detected instead of being trusted.

function New-DomeniaInvariantViolation {
    param([string]$Invariant,[string]$Subject,$Expected,$Actual,[string]$Text)
    return [pscustomobject]@{ Invariant=$Invariant; Subject=$Subject; Expected=[string]$Expected; Actual=[string]$Actual; Text=$Text }
}

function ConvertTo-DomeniaInvariantGuidSet {
    # Distinct normalised GUIDs of a detail list (strings, braces and case ignored). Invalid entries are counted apart:
    # a detail list holds identities, never names.
    param($Ids)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $invalid = 0
    $items = @()
    if ($Ids -is [Collections.IDictionary]) { $items = @($Ids.Keys) } elseif ($null -ne $Ids) { $items = @($Ids) }
    foreach ($id in $items) {
        $text = ([string]$id).Trim().Trim('{','}')
        $parsed = [guid]::Empty
        if ((-not [guid]::TryParse($text,[ref]$parsed)) -or ($parsed -eq [guid]::Empty)) { $invalid++; continue }
        [void]$set.Add($parsed.ToString('D'))
    }
    return [pscustomobject]@{ Set=$set; Count=$set.Count; Invalid=$invalid }
}

function Get-DomeniaInvariantNumber {
    # Number read from a widget member; $null when absent or not a finite number.
    param($InputObject,[string]$Name)
    if ($null -eq $InputObject) { return $null }
    $value = $null
    if ($InputObject -is [Collections.IDictionary]) { try { $value = $InputObject[$Name] } catch { $value = $null } }
    elseif ($null -ne $InputObject.PSObject.Properties[$Name]) { $value = $InputObject.$Name }
    if ($null -eq $value) { return $null }
    $number = [double]::NaN
    if (-not [double]::TryParse([string]$value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
    return $number
}

function Test-DomeniaWidgetDetailInvariant {
    # Widget: {Total; Matched; NotMatched; Unknown; Items=@({Label; Value})} as Measure-DomeniaQueryWidget returns it.
    # MatchedIds: detailed list of the whole widget (GUIDs), or $null when not read. SegmentIds: label -> detailed list
    # of that segment; a segment without its list is a violation (its figure could not be opened).
    param([string]$Subject,$Widget,$MatchedIds=$null,[Collections.IDictionary]$SegmentIds=$null)
    $violations = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Widget) {
        $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' $Subject 'widget' 'absent' 'Widget absent : aucun chiffre à vérifier.'))
        return ,($violations.ToArray())
    }
    $total = Get-DomeniaInvariantNumber $Widget 'Total'; $matched = Get-DomeniaInvariantNumber $Widget 'Matched'
    $not = Get-DomeniaInvariantNumber $Widget 'NotMatched'; $unknown = Get-DomeniaInvariantNumber $Widget 'Unknown'
    if (($null -eq $total) -or ($null -eq $matched) -or ($null -eq $not) -or ($null -eq $unknown)) {
        $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' $Subject 'Total, Matched, NotMatched, Unknown' 'compteur absent' 'Un compteur du widget manque : le chiffre ne peut pas être rapproché de sa liste.'))
        return ,($violations.ToArray())
    }
    if ($total -ne ($matched + $not + $unknown)) {
        $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' $Subject ($matched + $not + $unknown) $total 'Total différent de la somme des postes retenus, écartés et inconnus.'))
    }
    if ($null -ne $MatchedIds) {
        $set = ConvertTo-DomeniaInvariantGuidSet $MatchedIds
        if ($set.Invalid -gt 0) { $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' $Subject 0 $set.Invalid 'La liste détaillée contient des identités qui ne sont pas des GUID.')) }
        if ($set.Count -ne $matched) { $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' $Subject $matched $set.Count 'Le chiffre du widget diffère du nombre de GUID de sa liste détaillée.')) }
    }
    $items = @()
    if ($Widget -is [Collections.IDictionary]) { try { $items = @($Widget['Items']) } catch { $items = @() } }
    elseif ($null -ne $Widget.PSObject.Properties['Items']) { $items = @($Widget.Items) }
    $items = @($items | Where-Object { $null -ne $_ })
    if ($items.Count -gt 0) {
        $sum = 0.0
        foreach ($item in $items) {
            $value = Get-DomeniaInvariantNumber $item 'Value'
            $label = ''
            if ($null -ne $item.PSObject.Properties['Label']) { $label = [string]$item.Label }
            if ($null -eq $value) { $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' ($Subject + ' · ' + $label) 'nombre' 'absent' 'Segment sans valeur numérique.')); continue }
            $sum += $value
            if ($null -eq $SegmentIds) { continue }
            if (-not $SegmentIds.Contains($label)) { $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' ($Subject + ' · ' + $label) 'liste détaillée' 'absente' 'Segment affiché sans liste détaillée.')); continue }
            $segment = ConvertTo-DomeniaInvariantGuidSet $SegmentIds[$label]
            if ($segment.Invalid -gt 0) { $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' ($Subject + ' · ' + $label) 0 $segment.Invalid 'La liste du segment contient des identités qui ne sont pas des GUID.')) }
            if ($segment.Count -ne $value) { $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' ($Subject + ' · ' + $label) $value $segment.Count 'Le chiffre du segment diffère du nombre de GUID de sa liste détaillée.')) }
        }
        if ($sum -ne $matched) { $violations.Add((New-DomeniaInvariantViolation 'WidgetDetail' $Subject $matched $sum 'Les segments ne totalisent pas les postes retenus.')) }
    }
    return ,($violations.ToArray())
}

function ConvertTo-DomeniaInvariantUtc {
    # [datetime] (any kind) or ISO 8601 text -> UTC [datetime]; $null when absent or unreadable.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return $null }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    $text = ([string]$Value).Trim()
    if (-not $text) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces
    # Text without an offset or Z is a local reading of unknown zone: refused, never assumed UTC.
    if ($text -notmatch '(Z|[+-]\d{2}:?\d{2})$') { return $null }
    if (-not [DateTimeOffset]::TryParse($text,[Globalization.CultureInfo]::InvariantCulture,$styles,[ref]$parsed)) { return $null }
    return $parsed.UtcDateTime
}

function Test-DomeniaRenderDatedInvariant {
    # ComputedAt: date of the computation a rendered figure shows. Unspecified-kind dates and texts without an offset
    # are refused: a figure must say when, in an unambiguous way, it was computed.
    param([string]$Subject,$ComputedAt,[datetime]$NowUtc=[datetime]::UtcNow,[ValidateRange(0,1440)][int]$MaxSkewMinutes=5)
    $violations = New-Object 'System.Collections.Generic.List[object]'
    $utc = ConvertTo-DomeniaInvariantUtc $ComputedAt
    if ($null -eq $utc) {
        $violations.Add((New-DomeniaInvariantViolation 'RenderDated' $Subject 'date UTC' ([string]$ComputedAt) 'Rendu sans date de calcul lisible et non ambiguë.'))
        return ,($violations.ToArray())
    }
    if ($utc.Year -lt 2000) { $violations.Add((New-DomeniaInvariantViolation 'RenderDated' $Subject 'date réelle' $utc.ToString('o') 'Date de calcul par défaut : le rendu nʼest pas daté.')) }
    $now = $NowUtc
    if ($now.Kind -ne [DateTimeKind]::Utc) { $now = $now.ToUniversalTime() }
    if ($utc -gt $now.AddMinutes($MaxSkewMinutes)) { $violations.Add((New-DomeniaInvariantViolation 'RenderDated' $Subject ('au plus ' + $now.AddMinutes($MaxSkewMinutes).ToString('o')) $utc.ToString('o') 'Date de calcul dans le futur.')) }
    return ,($violations.ToArray())
}

function Test-DomeniaUnknownKeptInvariant {
    # SourceUnknown: unknown values counted from the source data (independently of the code under test).
    # ReportedUnknown: unknown count shown (Unknown of a widget, 'Valeur inconnue' segment...); $null means not shown.
    # SourceKnown / ReportedKnown (optional): a lost unknown must not reappear inside a known count.
    param([string]$Subject,[long]$SourceUnknown,$ReportedUnknown,$SourceKnown=$null,$ReportedKnown=$null)
    $violations = New-Object 'System.Collections.Generic.List[object]'
    if ($SourceUnknown -gt 0) {
        if ($null -eq $ReportedUnknown) {
            $violations.Add((New-DomeniaInvariantViolation 'UnknownKept' $Subject $SourceUnknown 'absent' 'Des valeurs inconnues ont disparu du résultat.'))
        }
        elseif ([long]$ReportedUnknown -ne $SourceUnknown) {
            $violations.Add((New-DomeniaInvariantViolation 'UnknownKept' $Subject $SourceUnknown $ReportedUnknown 'Le nombre de valeurs inconnues diffère de la source.'))
        }
    }
    elseif (($null -ne $ReportedUnknown) -and ([long]$ReportedUnknown -ne 0)) {
        $violations.Add((New-DomeniaInvariantViolation 'UnknownKept' $Subject 0 $ReportedUnknown 'Valeurs inconnues inventées.'))
    }
    if (($null -ne $SourceKnown) -and ($null -ne $ReportedKnown) -and ([long]$ReportedKnown -ne [long]$SourceKnown)) {
        $violations.Add((New-DomeniaInvariantViolation 'UnknownKept' $Subject $SourceKnown $ReportedKnown 'Le nombre de valeurs connues diffère de la source : un inconnu a été compté comme connu, ou lʼinverse.'))
    }
    return ,($violations.ToArray())
}

function Test-DomeniaUnknownDisplayInvariant {
    # A source value that is unknown must be displayed as unknown, never as a known neutral value.
    # Forbidden: texts that read as a measure ('0', '0 %', 'Non', 'False', 'Aucun', empty).
    param([string]$Subject,[bool]$SourceUnknown,[string]$Displayed,[string[]]$UnknownTexts=@('Inconnu','Inconnue','Valeur inconnue','Non vérifié','Non lu','Données insuffisantes'))
    $violations = New-Object 'System.Collections.Generic.List[object]'
    if (-not $SourceUnknown) { return ,($violations.ToArray()) }
    $text = ([string]$Displayed).Trim()
    $known = $false
    foreach ($candidate in $UnknownTexts) { if ($text.StartsWith([string]$candidate,[StringComparison]::Ordinal)) { $known = $true; break } }
    if (-not $known) {
        $violations.Add((New-DomeniaInvariantViolation 'UnknownKept' $Subject ($UnknownTexts -join ' | ') $text 'Valeur inconnue affichée comme une valeur connue.'))
    }
    return ,($violations.ToArray())
}

function Test-DomeniaCurrentAnswerInvariant {
    # Request / Current: {Epoch; Generation; Reader; Guid} of the selection that sent the request and of the selection on
    # screen when the answer arrives. Applied: whether the answer changed the screen.
    # -RequireCurrentApplied also reports a current answer that was dropped (lost answer).
    param([string]$Subject,$Request,$Current,[bool]$Applied,[switch]$RequireCurrentApplied)
    $violations = New-Object 'System.Collections.Generic.List[object]'
    $differences = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('Epoch','Generation','Reader','Guid')) {
        $left = ''; $right = ''
        if (($null -ne $Request) -and ($null -ne $Request.PSObject.Properties[$name])) { $left = [string]$Request.$name }
        if (($null -ne $Current) -and ($null -ne $Current.PSObject.Properties[$name])) { $right = [string]$Current.$name }
        if ($name -eq 'Guid') { $left = $left.Trim().Trim('{','}').ToLowerInvariant(); $right = $right.Trim().Trim('{','}').ToLowerInvariant() }
        if (($left -cne $right) -or (-not $left)) { $differences.Add($name) }
    }
    if ($Applied -and $differences.Count -gt 0) {
        $violations.Add((New-DomeniaInvariantViolation 'CurrentAnswer' $Subject 'réponse écartée' ('appliquée (' + ($differences -join ', ') + ' différent)') 'Réponse dʼune ancienne sélection appliquée.'))
    }
    if ((-not $Applied) -and $differences.Count -eq 0 -and [bool]$RequireCurrentApplied) {
        $violations.Add((New-DomeniaInvariantViolation 'CurrentAnswer' $Subject 'réponse appliquée' 'écartée' 'Réponse de la sélection courante perdue.'))
    }
    return ,($violations.ToArray())
}

function Get-DomeniaInvariantReport {
    # Aggregates the violations of several checks: Checked (number of checks run), Violations, Passed, per invariant.
    param([object[]]$Violations=@(),[int]$Checked=0)
    $list = @($Violations | Where-Object { $null -ne $_ })
    $byInvariant = [ordered]@{ WidgetDetail=0; RenderDated=0; UnknownKept=0; CurrentAnswer=0 }
    foreach ($violation in $list) {
        $name = [string]$violation.Invariant
        if ($byInvariant.Contains($name)) { $byInvariant[$name] = [int]$byInvariant[$name] + 1 } else { $byInvariant[$name] = 1 }
    }
    return [pscustomobject]@{ Checked=$Checked; Violations=$list; ViolationCount=$list.Count; Passed=(($list.Count -eq 0) -and ($Checked -gt 0)); ByInvariant=[pscustomobject]$byInvariant }
}
