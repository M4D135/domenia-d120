# Collection rules for slow networks (roadmap points 11, 13, 14, 15, 17, 18, 19, 20, 159, 160).
# Pure decisions only: no WPF, no network, no disk, no timer and no runspace. Domenia-Collection.UI.ps1,
# Domenia-Park.UI.ps1 and Domenia-Engine.UI.ps1 apply them to the live engine and to the explicit campaigns.

# ---------------------------------------------------------------- point 11: freshness per data family and usage profile
function Get-DomeniaFreshnessFamilies {
    # Families whose reuse delay the operator may set. Minimum and Maximum bound one setting, in seconds. Only the
    # families that a reader really applies are listed: no reader applies a reuse delay to the AD identity, so it is
    # not offered as a setting that would change nothing.
    return @(
        [pscustomobject]@{Id='Presence';Label='Présence réseau (ping)';Minimum=0;Maximum=604800;Effect='Le dernier ping reste affiché comme récent pendant cette durée ; au-delà il est marqué à relire.'}
        [pscustomobject]@{Id='Console';Label='Utilisateur console';Minimum=0;Maximum=604800;Effect='Lʼutilisateur console relevé reste récent pendant cette durée. Un relevé relit toujours la console.'}
        [pscustomobject]@{Id='Attributes';Label='Attributs AD';Minimum=0;Maximum=604800;Effect='Les attributs AD affichés restent récents pendant cette durée ; au-delà la fiche indique « à relire ».'}
        [pscustomobject]@{Id='Inventory';Label='Inventaire léger WMI';Minimum=0;Maximum=604800;Effect='Un relevé réutilise lʼinventaire léger plus récent que cette durée au lieu de le relire.'}
        [pscustomobject]@{Id='StaticProbe';Label='Sondes WMI stables';Minimum=0;Maximum=604800;Effect='Un relevé réutilise le résultat des sondes stables (matériel, BIOS, système) plus récent que cette durée.'}
        [pscustomobject]@{Id='VolatileProbe';Label='Sondes WMI variables';Minimum=0;Maximum=604800;Effect='Un relevé réutilise le résultat des sondes variables (services, réseau, charge, journaux) plus récent que cette durée.'}
    )
}

function Get-DomeniaCollectionProfiles {
    # Usage profiles. Seconds per freshness family; Windows is the default collection window of the profile (point 159).
    return @(
        [pscustomobject]@{Id='Standard';Label='Standard';Description='Réseau local ou rapide : durées habituelles de Domenia, travaux de fond permis à tout moment.';Windows='';Seconds=@{Presence=120;Console=300;Attributes=900;Inventory=300;StaticProbe=900;VolatileProbe=60}}
        [pscustomobject]@{Id='SlowNetwork';Label='Réseau lent ou site distant';Description='Mesures réutilisées plus longtemps ; travaux de fond limités aux heures creuses.';Windows='lun-ven 00:00-08:00 12:00-14:00 18:00-24:00; sam-dim';Seconds=@{Presence=600;Console=900;Attributes=3600;Inventory=3600;StaticProbe=14400;VolatileProbe=300}}
        [pscustomobject]@{Id='Troubleshooting';Label='Dépannage en direct';Description='Mesures relues rapidement pendant une intervention ; travaux de fond permis à tout moment.';Windows='';Seconds=@{Presence=30;Console=60;Attributes=300;Inventory=120;StaticProbe=300;VolatileProbe=30}}
    )
}

function Get-DomeniaCollectionProfile {
    # Unknown or empty identifiers fall back to Standard: a damaged setting never removes every duration.
    param([AllowEmptyString()][string]$Id='Standard')
    $profiles = @(Get-DomeniaCollectionProfiles)
    foreach ($profile in $profiles) { if ([string]$profile.Id -ieq ([string]$Id).Trim()) { return $profile } }
    return $profiles[0]
}

function Get-DomeniaFreshnessDurationChoices {
    # Durations offered by the editor, limited to the bounds of the family.
    param([Parameter(Mandatory=$true)][string]$Family)
    $definition = @(Get-DomeniaFreshnessFamilies | Where-Object { [string]$_.Id -ieq $Family })
    if (-not $definition.Count) { return @() }
    $choices = @(0,30,60,120,300,600,900,1800,3600,7200,14400,43200,86400,604800)
    return @($choices | Where-Object { ($_ -ge [int]$definition[0].Minimum) -and ($_ -le [int]$definition[0].Maximum) })
}

function Format-DomeniaCollectionDuration {
    # Short French duration: '30 s', '5 min', '1 h 30 min', '1 j'. Zero means the value is always read again.
    param([long]$Seconds)
    if ($Seconds -le 0) { return '0 s (toujours relire)' }
    if ($Seconds -lt 60) { return ([string]$Seconds + ' s') }
    if ($Seconds -lt 3600) {
        $minutes = [long][Math]::Floor($Seconds / 60); $rest = $Seconds % 60
        if ($rest) { return ([string]$minutes + ' min ' + [string]$rest + ' s') }
        return ([string]$minutes + ' min')
    }
    if ($Seconds -lt 86400) {
        $hours = [long][Math]::Floor($Seconds / 3600); $minutes = [long][Math]::Floor(($Seconds % 3600) / 60)
        if ($minutes) { return ([string]$hours + ' h ' + [string]$minutes + ' min') }
        return ([string]$hours + ' h')
    }
    $days = [long][Math]::Floor($Seconds / 86400); $hours = [long][Math]::Floor(($Seconds % 86400) / 3600)
    if ($hours) { return ([string]$days + ' j ' + [string]$hours + ' h') }
    return ([string]$days + ' j')
}

function ConvertFrom-DomeniaFreshnessOverrides {
    # Settings text (JSON object family -> seconds) to a validated table. An unknown family, a non-integer or a value
    # outside the bounds of its family is dropped and reported; nothing is guessed.
    param([AllowEmptyString()][string]$Text)
    $values = @{}
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $clean = ([string]$Text).Trim()
    if (-not $clean) { return [pscustomobject]@{Values=$values;Errors=@()} }
    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $clean -ErrorAction Stop } catch { $parsed = $null }
    if ($parsed -isnot [Management.Automation.PSCustomObject]) {
        $errors.Add('Durées personnalisées illisibles : les durées du profil sʼappliquent.')
        return [pscustomobject]@{Values=$values;Errors=$errors.ToArray()}
    }
    $families = @{}
    foreach ($family in @(Get-DomeniaFreshnessFamilies)) { $families[[string]$family.Id] = $family }
    foreach ($property in @($parsed.PSObject.Properties)) {
        if (-not $families.ContainsKey([string]$property.Name)) { $errors.Add('Famille inconnue ignorée : ' + [string]$property.Name); continue }
        $family = $families[[string]$property.Name]
        $number = 0L
        if (-not [long]::TryParse([string]$property.Value,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) {
            $errors.Add('Durée non entière ignorée : ' + [string]$family.Label); continue
        }
        if (($number -lt [long]$family.Minimum) -or ($number -gt [long]$family.Maximum)) {
            $errors.Add('Durée hors limites ignorée : ' + [string]$family.Label); continue
        }
        $values[[string]$family.Id] = [int]$number
    }
    return [pscustomobject]@{Values=$values;Errors=$errors.ToArray()}
}

function ConvertTo-DomeniaFreshnessOverridesText {
    # Stable text (families in catalog order) for the settings file. Unknown families are not written.
    param($Values)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($family in @(Get-DomeniaFreshnessFamilies)) {
        $id = [string]$family.Id
        $present = $false
        if ($Values -is [Collections.IDictionary]) { $present = $Values.Contains($id) }
        if (-not $present) { continue }
        $parts.Add('"' + $id + '":' + [string][int]$Values[$id])
    }
    if (-not $parts.Count) { return '' }
    return ('{' + ($parts.ToArray() -join ',') + '}')
}

function Resolve-DomeniaFreshnessTable {
    # Effective durations: the profile, then the validated overrides. Rows describe each family for the settings view.
    param([AllowEmptyString()][string]$Profile='Standard',$Overrides=$null)
    $definition = Get-DomeniaCollectionProfile $Profile
    $custom = @{}
    if ($Overrides -is [Collections.IDictionary]) { $custom = $Overrides }
    $seconds = @{}
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($family in @(Get-DomeniaFreshnessFamilies)) {
        $id = [string]$family.Id
        $base = [int]$definition.Seconds[$id]
        $value = $base; $source = 'Profil'
        if ($custom.Contains($id)) { $value = [int]$custom[$id]; $source = 'Personnalisé' }
        $seconds[$id] = $value
        $rows.Add([pscustomobject]@{Family=$id;Label=[string]$family.Label;Seconds=$value;Duration=(Format-DomeniaCollectionDuration $value);ProfileSeconds=$base;Source=$source;Effect=[string]$family.Effect})
    }
    return [pscustomobject]@{Profile=[string]$definition.Id;Label=[string]$definition.Label;Seconds=$seconds;Rows=$rows.ToArray()}
}

function Get-DomeniaFreshnessSeconds {
    # Duration of one family in a resolved table; $Default when the table is absent or does not know the family.
    param($Table,[Parameter(Mandatory=$true)][string]$Family,[int]$Default=0)
    $seconds = Get-DomeniaMember $Table 'Seconds' $null
    if (($seconds -is [Collections.IDictionary]) -and $seconds.Contains($Family)) { return [int]$seconds[$Family] }
    if (($Table -is [Collections.IDictionary]) -and $Table.Contains($Family)) { return [int]$Table[$Family] }
    return $Default
}

# ---------------------------------------------------------------- point 159: collection windows
function Get-DomeniaCollectionWindowSources {
    # Background sources that read the network on their own. Live (a selection), Dashboard (local rebuild), Storage and
    # Receipts are never held by a window: they are either an operator gesture or local work.
    return @('Reconcile','ObjectChanges','Park','Index')
}

function ConvertFrom-DomeniaCollectionWindowText {
    # 'lun-ven 07:30-12:00 13:30-18:00; sam 08:00-12:00'. Empty or 'toujours' = always open, 'jamais' = never open.
    # Days: lun mar mer jeu ven sam dim (full names accepted), lists 'lun,mer', ranges 'lun-ven' or 'ven-lun', 'tous'.
    # A day without range is open all day. A range whose end precedes its start continues the next day.
    param([AllowEmptyString()][string]$Text)
    $clean = ([string]$Text).Trim()
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $rules = New-Object 'System.Collections.Generic.List[object]'
    if ((-not $clean) -or ($clean -ieq 'toujours')) { return [pscustomobject]@{Valid=$true;Mode='Always';Rules=@();Errors=@();Text=''} }
    if ($clean -ieq 'jamais') { return [pscustomobject]@{Valid=$true;Mode='Never';Rules=@();Errors=@();Text='jamais'} }
    $dayMap = @{lun=1;lundi=1;mar=2;mardi=2;mer=3;mercredi=3;jeu=4;jeudi=4;ven=5;vendredi=5;sam=6;samedi=6;dim=0;dimanche=0}
    foreach ($clause in @($clean.Split(';'))) {
        $part = ([string]$clause).Trim()
        if (-not $part) { continue }
        $tokens = @($part.Split([char[]]@(' ',"`t"),[StringSplitOptions]::RemoveEmptyEntries))
        $days = New-Object 'System.Collections.Generic.List[int]'
        $dayText = ([string]$tokens[0]).ToLowerInvariant()
        $dayValid = $true
        if ($dayText -in @('tous','tlj')) { foreach ($d in 0..6) { $days.Add($d) } }
        else {
            foreach ($item in @($dayText.Split(','))) {
                if (-not $item) { $dayValid = $false; continue }
                $bounds = @($item.Split('-'))
                if ($bounds.Count -eq 1) {
                    if ($dayMap.ContainsKey($bounds[0])) { if (-not $days.Contains([int]$dayMap[$bounds[0]])) { $days.Add([int]$dayMap[$bounds[0]]) } } else { $dayValid = $false }
                }
                elseif (($bounds.Count -eq 2) -and $dayMap.ContainsKey($bounds[0]) -and $dayMap.ContainsKey($bounds[1])) {
                    # Monday-based walk so that 'ven-lun' covers vendredi, samedi, dimanche, lundi.
                    $start = ([int]$dayMap[$bounds[0]] + 6) % 7; $end = ([int]$dayMap[$bounds[1]] + 6) % 7
                    $index = $start
                    for ($guard = 0; $guard -lt 7; $guard++) {
                        $day = ($index + 1) % 7
                        if (-not $days.Contains($day)) { $days.Add($day) }
                        if ($index -eq $end) { break }
                        $index = ($index + 1) % 7
                    }
                }
                else { $dayValid = $false }
            }
        }
        if ((-not $dayValid) -or (-not $days.Count)) { $errors.Add('Jours non reconnus : « ' + [string]$tokens[0] + ' » (exemple : lun-ven).'); continue }
        $ranges = @($tokens | Select-Object -Skip 1)
        if (-not $ranges.Count) { $rules.Add([pscustomobject]@{Days=$days.ToArray();StartMinute=0;EndMinute=1440;Overnight=$false}); continue }
        foreach ($range in $ranges) {
            if ([string]$range -notmatch '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$') { $errors.Add('Plage horaire non reconnue : « ' + [string]$range + ' » (exemple : 07:30-12:00).'); continue }
            $sh = [int]$Matches[1]; $sm = [int]$Matches[2]; $eh = [int]$Matches[3]; $em = [int]$Matches[4]
            if (($sh -gt 23) -or ($sm -gt 59) -or ($em -gt 59) -or ($eh -gt 24) -or (($eh -eq 24) -and ($em -ne 0))) { $errors.Add('Heure invalide : « ' + [string]$range + ' ».'); continue }
            $startMinute = $sh * 60 + $sm; $endMinute = $eh * 60 + $em
            if ($startMinute -eq $endMinute) { $errors.Add('Plage vide : « ' + [string]$range + ' ».'); continue }
            $rules.Add([pscustomobject]@{Days=$days.ToArray();StartMinute=$startMinute;EndMinute=$endMinute;Overnight=($endMinute -lt $startMinute)})
        }
    }
    if ($errors.Count) { return [pscustomobject]@{Valid=$false;Mode='Invalid';Rules=@();Errors=$errors.ToArray();Text=$clean} }
    if (-not $rules.Count) { return [pscustomobject]@{Valid=$false;Mode='Invalid';Rules=@();Errors=@('Aucune plage reconnue.');Text=$clean} }
    return [pscustomobject]@{Valid=$true;Mode='Rules';Rules=$rules.ToArray();Errors=@();Text=$clean}
}

function Test-DomeniaCollectionWindowRule {
    # $true when the rule covers the local instant $At.
    param($Rule,[datetime]$At)
    $minute = $At.Hour * 60 + $At.Minute
    $day = [int]$At.DayOfWeek
    $days = @($Rule.Days)
    if (-not [bool]$Rule.Overnight) { return (($days -contains $day) -and ($minute -ge [int]$Rule.StartMinute) -and ($minute -lt [int]$Rule.EndMinute)) }
    $previous = ($day + 6) % 7
    return ((($days -contains $day) -and ($minute -ge [int]$Rule.StartMinute)) -or (($days -contains $previous) -and ($minute -lt [int]$Rule.EndMinute)))
}

function Test-DomeniaCollectionWindowOpen {
    # State of a parsed window at the local instant $Now, with the next change (opening or closing) within eight days.
    param($Window,[datetime]$Now=(Get-Date))
    $mode = [string](Get-DomeniaMember $Window 'Mode' 'Always')
    if ($mode -eq 'Always') { return [pscustomobject]@{Open=$true;Mode=$mode;NextChange=$null} }
    if ($mode -ne 'Rules') { return [pscustomobject]@{Open=$false;Mode=$mode;NextChange=$null} }
    $rules = @(Get-DomeniaMember $Window 'Rules' @())
    $at = $Now.Date.AddHours($Now.Hour).AddMinutes($Now.Minute)
    $isOpen = $false
    foreach ($rule in $rules) { if (Test-DomeniaCollectionWindowRule $rule $at) { $isOpen = $true; break } }
    # Boundaries are rule starts and ends: the state can only change there.
    $boundaries = New-Object 'System.Collections.Generic.List[datetime]'
    for ($offset = -1; $offset -le 8; $offset++) {
        $day = $Now.Date.AddDays($offset)
        foreach ($rule in $rules) {
            if (@($rule.Days) -notcontains [int]$day.DayOfWeek) { continue }
            $boundaries.Add($day.AddMinutes([int]$rule.StartMinute))
            $endDay = $day
            if ([bool]$rule.Overnight) { $endDay = $day.AddDays(1) }
            $boundaries.Add($endDay.AddMinutes([int]$rule.EndMinute))
        }
    }
    $next = $null
    foreach ($moment in @($boundaries.ToArray() | Where-Object { $_ -gt $at } | Sort-Object -Unique)) {
        $state = $false
        foreach ($rule in $rules) { if (Test-DomeniaCollectionWindowRule $rule $moment) { $state = $true; break } }
        if ($state -ne $isOpen) { $next = $moment; break }
    }
    return [pscustomobject]@{Open=$isOpen;Mode=$mode;NextChange=$next}
}

function Format-DomeniaCollectionWindowState {
    # One sentence for the settings view and the campaign confirmation.
    param($State,[datetime]$Now=(Get-Date))
    $mode = [string](Get-DomeniaMember $State 'Mode' 'Always')
    if ($mode -eq 'Always') { return 'Travaux de fond permis à tout moment (aucune fenêtre de collecte).' }
    if ($mode -eq 'Never') { return 'Travaux de fond suspendus : aucune fenêtre de collecte. Les actions explicites restent possibles.' }
    if ($mode -ne 'Rules') { return 'Fenêtre de collecte invalide : travaux de fond suspendus jusquʼà correction.' }
    $next = Get-DomeniaMember $State 'NextChange' $null
    $day = ''; $time = ''
    if ($null -ne $next) {
        $names = @('dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi')
        $moment = [datetime]$next
        $time = $moment.ToString('HH:mm')
        if ($moment.Date -eq $Now.Date.AddDays(1)) { $day = 'demain' }
        elseif ($moment.Date -ne $Now.Date) { $day = $names[[int]$moment.DayOfWeek] }
    }
    if ([bool](Get-DomeniaMember $State 'Open' $false)) {
        if (-not $time) { return 'Fenêtre de collecte ouverte.' }
        if ($day) { return ('Fenêtre de collecte ouverte jusquʼà ' + $day + ' ' + $time + '.') }
        return ('Fenêtre de collecte ouverte jusquʼà ' + $time + '.')
    }
    if (-not $time) { return 'Fenêtre de collecte fermée : travaux de fond en pause.' }
    if ($day) { return ('Fenêtre de collecte fermée : travaux de fond en pause, reprise ' + $day + ' à ' + $time + '.') }
    return ('Fenêtre de collecte fermée : travaux de fond en pause, reprise à ' + $time + '.')
}

function Test-DomeniaCollectionWindowAllows {
    # $true when the window lets this background source read the network now. Sources outside the list are not held.
    param($Window,[AllowEmptyString()][string]$Source,[datetime]$Now=(Get-Date))
    if (@(Get-DomeniaCollectionWindowSources) -notcontains [string]$Source) { return $true }
    if ($null -eq $Window) { return $true }
    if (-not [bool](Get-DomeniaMember $Window 'Valid' $true)) { return $false }
    return [bool](Test-DomeniaCollectionWindowOpen -Window $Window -Now $Now).Open
}

# ---------------------------------------------------------------- points 14, 15, 160: health of a collection source
function New-DomeniaSourcePolicy {
    # One budget: MaxLimit is the bound chosen by the operator, never exceeded. FailureThreshold 0 never suspends.
    param([int]$MaxLimit=4,[int]$MinLimit=1,[int]$FailureThreshold=3,[int]$OpenSeconds=60,[int]$MaxOpenSeconds=900,
        [double]$SlowFactor=2.0,[int]$SlowFloorMs=1500,[int]$DecreaseCooldownSeconds=10)
    $max = [Math]::Max(1,$MaxLimit)
    return [pscustomobject]@{MaxLimit=$max;MinLimit=[Math]::Max(1,[Math]::Min($MinLimit,$max));FailureThreshold=[Math]::Max(0,$FailureThreshold)
        OpenSeconds=[Math]::Max(1,$OpenSeconds);MaxOpenSeconds=[Math]::Max([Math]::Max(1,$OpenSeconds),$MaxOpenSeconds)
        SlowFactor=[Math]::Max(1.1,$SlowFactor);SlowFloorMs=[Math]::Max(0,$SlowFloorMs);DecreaseCooldownSeconds=[Math]::Max(0,$DecreaseCooldownSeconds)}
}

function New-DomeniaSourceHealth { return @{} }

function Get-DomeniaSourceEntry {
    # Creates the entry of a source on first use. A new source starts at the bound chosen by the operator.
    param($Health,[Parameter(Mandatory=$true)][string]$Key,$Policy)
    if ($null -eq $Health) { return $null }
    if ($null -eq $Policy) { $Policy = New-DomeniaSourcePolicy }
    if (-not $Health.ContainsKey($Key)) {
        $Health[$Key] = [pscustomobject]@{Key=$Key;State='Closed';Limit=[int]$Policy.MaxLimit;Successes=0;ConsecutiveFailures=0;Opens=0
            OpenUntilUtc=[datetime]::MinValue;BaselineMs=[double]0;Samples=0;LastLatencyMs=[double]-1;LastDecreaseUtc=[datetime]::MinValue
            LastOutcome='';LastUtc=[datetime]::MinValue;Suspensions=0;Decreases=0}
    }
    return $Health[$Key]
}

function Get-DomeniaSourceOpenSeconds {
    # Delay of the n-th consecutive suspension: doubling and bounded.
    param($Policy,[int]$Opens)
    $power = [Math]::Max(0,[Math]::Min(10,$Opens - 1))
    return [int][Math]::Min([double]$Policy.MaxOpenSeconds,[double]$Policy.OpenSeconds * [Math]::Pow(2,$power))
}

function Register-DomeniaSourceOutcome {
    # Additive increase, multiplicative decrease (point 14) and suspension with progressive recovery (point 160).
    # Success: an answer proved the path works. Timeout and Failure count against the source. Neutral (machine off,
    # refused right, rejected account) and Cancelled say nothing about the source and change nothing.
    param($Health,[Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('Success','Timeout','Failure','Neutral','Cancelled')][string]$Outcome,
        [double]$LatencyMs=-1,$Policy=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $Policy) { $Policy = New-DomeniaSourcePolicy }
    $entry = Get-DomeniaSourceEntry -Health $Health -Key $Key -Policy $Policy
    if ($null -eq $entry) { return $null }
    if ($Outcome -in @('Neutral','Cancelled')) { return $entry }
    $entry.LastOutcome = $Outcome; $entry.LastUtc = $NowUtc
    # A source whose suspension has expired is half open: the first answer decides.
    $halfOpen = (([string]$entry.State -eq 'HalfOpen') -or (([string]$entry.State -eq 'Open') -and ($NowUtc -ge [datetime]$entry.OpenUntilUtc)))
    $decrease = {
        if (($NowUtc - [datetime]$entry.LastDecreaseUtc).TotalSeconds -ge [double]$Policy.DecreaseCooldownSeconds) {
            $next = [int][Math]::Max([double]$Policy.MinLimit,[Math]::Floor([double]$entry.Limit / 2))
            if ($next -lt [int]$entry.Limit) { $entry.Decreases = [int]$entry.Decreases + 1 }
            $entry.Limit = $next; $entry.LastDecreaseUtc = $NowUtc; $entry.Successes = 0
        }
    }
    if ($Outcome -eq 'Success') {
        $entry.ConsecutiveFailures = 0
        $recovered = $false
        if ($halfOpen -or ([string]$entry.State -eq 'Open')) {
            # Progressive recovery: the trial answer reopens the source at one read at a time; the following answers
            # widen it by the additive increase.
            $entry.State = 'Closed'; $entry.Limit = [int]$Policy.MinLimit; $entry.Successes = 0; $entry.LastDecreaseUtc = $NowUtc
            $recovered = $true
        }
        $slow = $false
        if ($LatencyMs -ge 0) {
            $entry.LastLatencyMs = $LatencyMs
            $threshold = [Math]::Max([double]$Policy.SlowFloorMs,[double]$Policy.SlowFactor * [double]$entry.BaselineMs)
            $slow = (([int]$entry.Samples -ge 3) -and ($LatencyMs -gt $threshold))
            if ($slow) {
                # A slow answer still moves the reference a little: a site that became slower for good is accepted.
                $entry.BaselineMs = [double]$entry.BaselineMs + 0.05 * ($LatencyMs - [double]$entry.BaselineMs)
            }
            elseif ([int]$entry.Samples -eq 0) { $entry.BaselineMs = $LatencyMs; $entry.Samples = 1 }
            else { $entry.BaselineMs = 0.8 * [double]$entry.BaselineMs + 0.2 * $LatencyMs; $entry.Samples = [int]$entry.Samples + 1 }
        }
        if ($slow) { & $decrease }
        elseif (-not $recovered) {
            $entry.Successes = [int]$entry.Successes + 1
            if (([int]$entry.Successes -ge [int]$entry.Limit) -and ([int]$entry.Limit -lt [int]$Policy.MaxLimit)) { $entry.Limit = [int]$entry.Limit + 1; $entry.Successes = 0 }
            if ([int]$entry.Limit -ge [int]$Policy.MaxLimit) { $entry.Opens = 0 }
        }
        return $entry
    }
    # Timeout or failure.
    $entry.ConsecutiveFailures = [int]$entry.ConsecutiveFailures + 1
    $entry.Successes = 0
    & $decrease
    $suspend = $halfOpen
    if ((-not $suspend) -and ([int]$Policy.FailureThreshold -gt 0) -and ([int]$entry.ConsecutiveFailures -ge [int]$Policy.FailureThreshold) -and ([string]$entry.State -eq 'Closed')) { $suspend = $true }
    if ($suspend -and ([int]$Policy.FailureThreshold -gt 0)) {
        $entry.Opens = [int]$entry.Opens + 1
        $entry.Suspensions = [int]$entry.Suspensions + 1
        $entry.State = 'Open'
        $entry.Limit = [int]$Policy.MinLimit
        $entry.OpenUntilUtc = $NowUtc.AddSeconds((Get-DomeniaSourceOpenSeconds -Policy $Policy -Opens ([int]$entry.Opens)))
    }
    return $entry
}

function Test-DomeniaSourceAdmission {
    # May one more read start on this source now? $Running counts the reads of the source still in flight.
    param($Health,[Parameter(Mandatory=$true)][string]$Key,[int]$Running=0,$Policy=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $Policy) { $Policy = New-DomeniaSourcePolicy }
    $entry = $null
    if (($null -ne $Health) -and $Health.ContainsKey($Key)) { $entry = $Health[$Key] }
    if ($null -eq $entry) {
        if ($Running -lt [int]$Policy.MaxLimit) { return [pscustomobject]@{Allowed=$true;State='Closed';Limit=[int]$Policy.MaxLimit;Reason='';RetryAfterUtc=$null} }
        return [pscustomobject]@{Allowed=$false;State='Closed';Limit=[int]$Policy.MaxLimit;Reason=('Limite atteinte : ' + [string]$Policy.MaxLimit + ' lecture(s) simultanée(s) pour cette source.');RetryAfterUtc=$null}
    }
    $state = [string]$entry.State
    if ($state -eq 'Open') {
        if ($NowUtc -lt [datetime]$entry.OpenUntilUtc) {
            return [pscustomobject]@{Allowed=$false;State='Open';Limit=0;Reason=('Source suspendue après ' + [string]$entry.ConsecutiveFailures + ' échec(s) consécutif(s) : nouvel essai après ' + ([datetime]$entry.OpenUntilUtc).ToLocalTime().ToString('HH:mm:ss') + '.');RetryAfterUtc=[datetime]$entry.OpenUntilUtc}
        }
        $state = 'HalfOpen'
    }
    if ($state -eq 'HalfOpen') {
        if ($Running -lt 1) { return [pscustomobject]@{Allowed=$true;State='HalfOpen';Limit=1;Reason='Reprise progressive : une seule lecture dʼessai.';RetryAfterUtc=$null} }
        return [pscustomobject]@{Allowed=$false;State='HalfOpen';Limit=1;Reason='Reprise progressive : une lecture dʼessai est déjà en cours.';RetryAfterUtc=$null}
    }
    $limit = [int][Math]::Max(1,[Math]::Min([int]$entry.Limit,[int]$Policy.MaxLimit))
    if ($Running -lt $limit) { return [pscustomobject]@{Allowed=$true;State='Closed';Limit=$limit;Reason='';RetryAfterUtc=$null} }
    return [pscustomobject]@{Allowed=$false;State='Closed';Limit=$limit;Reason=('Limite adaptée atteinte : ' + [string]$limit + ' lecture(s) simultanée(s) pour cette source.');RetryAfterUtc=$null}
}

function ConvertTo-DomeniaIPv4Text {
    # Dotted IPv4 text or ''. Loopback, unspecified and multicast addresses are not a site.
    param([AllowEmptyString()][string]$Text)
    $value = ([string]$Text).Trim()
    if ($value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return '' }
    $octets = @([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4])
    foreach ($octet in $octets) { if ($octet -gt 255) { return '' } }
    if (($octets[0] -eq 0) -or ($octets[0] -eq 127) -or ($octets[0] -ge 224)) { return '' }
    return ($octets -join '.')
}

function Get-DomeniaAddressFromText {
    # Last IPv4 address quoted in a worker text such as 'Réponse ICMP · 12 ms · 10.1.2.3'.
    param([AllowEmptyString()][string]$Text)
    $found = ''
    foreach ($match in [regex]::Matches([string]$Text,'(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\d.])')) {
        $candidate = ConvertTo-DomeniaIPv4Text $match.Groups[1].Value
        if ($candidate) { $found = $candidate }
    }
    return $found
}

function Get-DomeniaSubnetKey {
    # Presumed subnet of an address ('10.1.2.0/24'); '' when the address is unknown. The prefix is an assumption made
    # without reading the real mask: the label says « présumé ».
    param([AllowEmptyString()][string]$Address,[ValidateRange(8,30)][int]$PrefixLength=24)
    $ip = ConvertTo-DomeniaIPv4Text $Address
    if (-not $ip) { return '' }
    $parts = @($ip.Split('.') | ForEach-Object { [long]$_ })
    $value = ($parts[0] -shl 24) -bor ($parts[1] -shl 16) -bor ($parts[2] -shl 8) -bor $parts[3]
    $full = [long]4294967295
    $mask = ($full -shl (32 - $PrefixLength)) -band $full
    $network = $value -band $mask
    return ((@((($network -shr 24) -band 255),(($network -shr 16) -band 255),(($network -shr 8) -band 255),($network -band 255)) -join '.') + '/' + [string]$PrefixLength)
}

function Get-DomeniaCollectionSourceKey {
    # Budget of one read: the controller for the directory, the presumed subnet for a workstation, else the provider.
    param([Parameter(Mandatory=$true)][string]$Provider,[AllowEmptyString()][string]$Server='',[AllowEmptyString()][string]$Address='')
    if ($Provider -eq 'Directory') {
        $dc = ([string]$Server).Trim().ToLowerInvariant()
        if ($dc) { return ('dc:' + $dc) }
        return 'dc:?'
    }
    if ($Provider -in @('Cim','Wts','Network')) {
        $subnet = Get-DomeniaSubnetKey $Address
        if ($subnet) { return ('site:' + $subnet) }
        return 'site:?'
    }
    return ('provider:' + ([string]$Provider).ToLowerInvariant())
}

function Get-DomeniaCollectionSourceLabel {
    param([AllowEmptyString()][string]$Key)
    if ($Key -eq 'site:?') { return 'postes sans adresse connue' }
    if ($Key -like 'site:*') { return ('sous-réseau présumé ' + $Key.Substring(5)) }
    if ($Key -eq 'dc:?') { return 'contrôleur non désigné' }
    if ($Key -like 'dc:*') { return ('contrôleur ' + $Key.Substring(3)) }
    return $Key
}

function New-DomeniaCampaignSources {
    # Per-source budgets of one campaign: every site or controller adapts on its own, bounded by the chosen value.
    # Workstations without known address share one budget that never suspends (it is not a site).
    param([int]$MaxLimit=4)
    $max = [Math]::Max(1,[Math]::Min(32,$MaxLimit))
    return [pscustomobject]@{Health=(New-DomeniaSourceHealth);Policy=(New-DomeniaSourcePolicy -MaxLimit $max);UnknownPolicy=(New-DomeniaSourcePolicy -MaxLimit $max -FailureThreshold 0);MaxLimit=$max}
}

function Get-DomeniaCampaignSourcePolicy {
    param($Sources,[AllowEmptyString()][string]$Key)
    if ($null -eq $Sources) { return (New-DomeniaSourcePolicy) }
    if ($Key -in @('site:?','dc:?')) { return $Sources.UnknownPolicy }
    return $Sources.Policy
}

function Get-DomeniaCampaignSourceSummary {
    # Sources that are reduced or suspended, for the status line. Healthy sources are not listed.
    param($Sources,[datetime]$NowUtc=[datetime]::UtcNow)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Sources) { return '' }
    foreach ($key in @($Sources.Health.Keys | Sort-Object)) {
        $entry = $Sources.Health[$key]
        $label = Get-DomeniaCollectionSourceLabel ([string]$key)
        if (([string]$entry.State -eq 'Open') -and ($NowUtc -lt [datetime]$entry.OpenUntilUtc)) { $parts.Add($label + ' suspendu jusquʼà ' + ([datetime]$entry.OpenUntilUtc).ToLocalTime().ToString('HH:mm:ss')) }
        elseif (([string]$entry.State -eq 'Open') -or ([string]$entry.State -eq 'HalfOpen')) { $parts.Add($label + ' en reprise (une lecture dʼessai)') }
        elseif ([int]$entry.Limit -lt [int]$Sources.MaxLimit) { $parts.Add($label + ' ralenti à ' + [string]$entry.Limit + '/' + [string]$Sources.MaxLimit) }
    }
    return ($parts.ToArray() -join ' ; ')
}

# ---------------------------------------------------------------- point 18: classify before any retry
function ConvertTo-DomeniaCollectionFailure {
    # Class of one workstation measurement. Health feeds the source budget; Category decides a retry.
    # Transient: the machine answered the ping (or no ping was asked) but the read timed out, or the worker itself
    # timed out. Offline: no answer at all, a retry soon would only wait again. A refusal is never transient.
    param([AllowEmptyString()][string]$Outcome='',[AllowEmptyString()][string]$Presence='',[bool]$PingCollected=$true,[bool]$JobFailed=$false,[AllowEmptyString()][string]$ErrorText='')
    if ($JobFailed) {
        if ([string]$ErrorText -match '(?i)timeout|timed out|d[eé]lai|aucune requ[eê]te') { return [pscustomobject]@{Category='Transient';Health='Timeout';Reason='Délai dépassé avant la fin de la lecture.'} }
        if ([string]$ErrorText -match '(?i)identifiants?.{0,20}(rejet|refus)|logon failure|password is incorrect|mot de passe') { return [pscustomobject]@{Category='Credential';Health='Neutral';Reason='Identifiants rejetés.'} }
        return [pscustomobject]@{Category='Permanent';Health='Failure';Reason='Lecture interrompue : erreur non transitoire.'}
    }
    $online = ([string]$Presence -eq 'En ligne')
    $silent = ([string]$Presence -in @('Sans réponse au ping','Erreur de ping'))
    switch ([string]$Outcome) {
        'AuthRejected' { return [pscustomobject]@{Category='Credential';Health='Neutral';Reason='Identifiants rejetés : aucune reprise automatique.'} }
        'Denied' { return [pscustomobject]@{Category='AccessDenied';Health='Success';Reason='Droit refusé : aucune reprise automatique.'} }
        'Timeout' {
            if ($PingCollected -and $silent) { return [pscustomobject]@{Category='Offline';Health='Neutral';Reason='Poste sans réponse : pas de reprise immédiate.'} }
            return [pscustomobject]@{Category='Transient';Health='Timeout';Reason='Délai dépassé sur un poste joignable.'}
        }
        'Unavailable' {
            if ($online) { return [pscustomobject]@{Category='ProtocolUnreachable';Health='Neutral';Reason='Le poste répond au ping mais refuse WMI (DCOM) : pas de reprise immédiate.'} }
            if ($PingCollected -and $silent) { return [pscustomobject]@{Category='Offline';Health='Neutral';Reason='Poste sans réponse : pas de reprise immédiate.'} }
            return [pscustomobject]@{Category='Transient';Health='Failure';Reason='Lecture WMI non confirmée.'}
        }
        default {
            if ($PingCollected -and ([string]$Presence -eq 'Erreur de ping')) { return [pscustomobject]@{Category='Permanent';Health='Neutral';Reason='Nom non résolu ou erreur réseau locale.'} }
            if ($PingCollected -and ([string]$Presence -eq 'Sans réponse au ping') -and ([string]$Outcome -in @('PresenceOnly',''))) { return [pscustomobject]@{Category='Success';Health='Neutral';Reason=''} }
            return [pscustomobject]@{Category='Success';Health='Success';Reason=''}
        }
    }
}

function Get-DomeniaCollectionRetryDecision {
    # Bounded and spaced retries of a READ after a transient incident only: 30 s, then 2 min, three attempts at most.
    # Never for a write, a rejected account, a refused right, an offline machine or an absent class.
    param([AllowEmptyString()][string]$Category,[int]$Attempt=1,[int]$MaxAttempts=3,[bool]$IsWrite=$false,
        [int]$BaseDelaySeconds=30,[int]$MaxDelaySeconds=300,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($IsWrite) { return [pscustomobject]@{Retry=$false;DelaySeconds=0;NotBeforeUtc=$null;Reason='Une écriture nʼest jamais rejouée.'} }
    if ([string]$Category -ne 'Transient') {
        $why = switch ([string]$Category) {
            'Credential' { 'Identifiants rejetés : reprise seulement après un changement de compte explicite.' }
            'AccessDenied' { 'Droit refusé : une nouvelle lecture donnerait le même refus.' }
            'Offline' { 'Poste sans réponse : il sera relu au prochain relevé.' }
            'ProtocolUnreachable' { 'WMI inaccessible sur ce poste : il sera relu au prochain relevé.' }
            'Success' { '' }
            default { 'Erreur non transitoire : aucune reprise automatique.' }
        }
        return [pscustomobject]@{Retry=$false;DelaySeconds=0;NotBeforeUtc=$null;Reason=$why}
    }
    $max = [Math]::Max(1,[Math]::Min(5,$MaxAttempts))
    if ($Attempt -ge $max) { return [pscustomobject]@{Retry=$false;DelaySeconds=0;NotBeforeUtc=$null;Reason=('Incident transitoire persistant après ' + [string]$Attempt + ' essai(s) : arrêt des reprises.')} }
    $delay = [int][Math]::Min([double][Math]::Max(1,$MaxDelaySeconds),[double][Math]::Max(1,$BaseDelaySeconds) * [Math]::Pow(4,[Math]::Max(0,$Attempt - 1)))
    return [pscustomobject]@{Retry=$true;DelaySeconds=$delay;NotBeforeUtc=$NowUtc.AddSeconds($delay);Reason=('Incident transitoire : nouvel essai dans ' + (Format-DomeniaCollectionDuration $delay) + ' (essai ' + [string]($Attempt + 1) + '/' + [string]$max + ').')}
}

# ---------------------------------------------------------------- point 19: capabilities of the workstations
function New-DomeniaCapabilityMemory { return [pscustomobject]@{Entries=@{}} }

function Get-DomeniaCapabilityTtlSeconds {
    param([Parameter(Mandatory=$true)][string]$Kind)
    switch ($Kind) {
        'ClassAbsent' { return 604800 }
        'ProtocolUnreachable' { return 900 }
        'RightDenied' { return 3600 }
        default { return 0 }
    }
}

function Test-DomeniaWmiClassAbsentText {
    # WMI answers « classe non valide » (0x80041010) or « espace de noms non valide » (0x8004100E): the class is
    # absent from this system, which is a capability, not an incident.
    param([AllowEmptyString()][string]$Text)
    return ([string]$Text -match '(?i)0x80041010|0x8004100e|invalid class|classe non valide|invalid namespace|espace de noms non valide')
}

function Get-DomeniaCapabilityKey {
    param([AllowEmptyString()][string]$Target,[AllowEmptyString()][string]$Capability)
    return (([string]$Target).Trim().ToLowerInvariant() + '|' + ([string]$Capability).Trim().ToLowerInvariant())
}

function Get-DomeniaProbeCapability {
    # Capability name of a catalog probe: its namespace and class.
    param($Probe)
    return ('class:' + [string](Get-DomeniaMember $Probe 'Namespace' '') + ':' + [string](Get-DomeniaMember $Probe 'Class' ''))
}

function Register-DomeniaCapabilityFact {
    # Remembers that a capability is missing on one workstation for a limited time. Build and AccountGeneration are
    # the context of the fact: a new Windows build invalidates an absent class, a new account a refused right.
    param($Memory,[Parameter(Mandatory=$true)][string]$Target,[Parameter(Mandatory=$true)][string]$Capability,
        [Parameter(Mandatory=$true)][ValidateSet('ClassAbsent','ProtocolUnreachable','RightDenied')][string]$Kind,
        [datetime]$NowUtc=[datetime]::UtcNow,[AllowEmptyString()][string]$Build='',[long]$AccountGeneration=0)
    if ($null -eq $Memory) { return $null }
    $entry = [pscustomobject]@{Target=$Target;Capability=$Capability;Kind=$Kind;ObservedUtc=$NowUtc;UntilUtc=$NowUtc.AddSeconds((Get-DomeniaCapabilityTtlSeconds $Kind));Build=([string]$Build).Trim();AccountGeneration=$AccountGeneration}
    $Memory.Entries[(Get-DomeniaCapabilityKey $Target $Capability)] = $entry
    return $entry
}

function Clear-DomeniaCapabilityFact {
    # A success proves the capability: the fact is forgotten at once.
    param($Memory,[AllowEmptyString()][string]$Target,[AllowEmptyString()][string]$Capability='')
    if ($null -eq $Memory) { return 0 }
    $removed = 0
    $prefix = ([string]$Target).Trim().ToLowerInvariant() + '|'
    foreach ($key in @($Memory.Entries.Keys)) {
        if ($Capability) { if ([string]$key -ne (Get-DomeniaCapabilityKey $Target $Capability)) { continue } }
        elseif (-not ([string]$key).StartsWith($prefix,[StringComparison]::Ordinal)) { continue }
        [void]$Memory.Entries.Remove($key); $removed++
    }
    return $removed
}

function Reset-DomeniaCapabilityMemory {
    # Explicit change (account, reconnection): facts that depend on it are forgotten. Kind='' forgets everything.
    param($Memory,[AllowEmptyString()][string]$Kind='')
    if ($null -eq $Memory) { return 0 }
    $removed = 0
    foreach ($key in @($Memory.Entries.Keys)) {
        if ($Kind -and ([string]$Memory.Entries[$key].Kind -ne $Kind)) { continue }
        [void]$Memory.Entries.Remove($key); $removed++
    }
    return $removed
}

function Test-DomeniaCapabilityFact {
    # Known=$true when a fact still holds: not expired, same build for an absent class, same accounts for a refusal.
    param($Memory,[AllowEmptyString()][string]$Target,[AllowEmptyString()][string]$Capability,[datetime]$NowUtc=[datetime]::UtcNow,
        [AllowEmptyString()][string]$Build='',[long]$AccountGeneration=0)
    $none = [pscustomobject]@{Known=$false;Kind='';Reason='';UntilUtc=$null}
    if ($null -eq $Memory) { return $none }
    $key = Get-DomeniaCapabilityKey $Target $Capability
    if (-not $Memory.Entries.ContainsKey($key)) { return $none }
    $entry = $Memory.Entries[$key]
    $stale = ($NowUtc -ge [datetime]$entry.UntilUtc)
    if ((-not $stale) -and ([string]$entry.Kind -eq 'ClassAbsent') -and [string]$entry.Build -and ([string]$Build).Trim() -and ([string]$entry.Build -ine ([string]$Build).Trim())) { $stale = $true }
    if ((-not $stale) -and ([string]$entry.Kind -in @('RightDenied','ProtocolUnreachable')) -and ([long]$entry.AccountGeneration -ne $AccountGeneration)) { $stale = $true }
    if ($stale) { [void]$Memory.Entries.Remove($key); return $none }
    $until = ([datetime]$entry.UntilUtc).ToLocalTime().ToString('dd/MM HH:mm')
    $reason = switch ([string]$entry.Kind) {
        'ClassAbsent' { 'Classe WMI absente sur ce poste (relevé du ' + ([datetime]$entry.ObservedUtc).ToLocalTime().ToString('dd/MM HH:mm') + ') : non relue jusquʼau ' + $until + ' ou jusquʼà un changement de version de Windows.' }
        'ProtocolUnreachable' { 'WMI (DCOM) inaccessible sur ce poste : ping seul jusquʼà ' + ([datetime]$entry.UntilUtc).ToLocalTime().ToString('HH:mm') + ' ou jusquʼà un changement de compte.' }
        default { 'Droit refusé sur ce poste : lecture WMI suspendue jusquʼà ' + ([datetime]$entry.UntilUtc).ToLocalTime().ToString('HH:mm') + ' ou jusquʼà un changement de compte.' }
    }
    return [pscustomobject]@{Known=$true;Kind=[string]$entry.Kind;Reason=$reason;UntilUtc=[datetime]$entry.UntilUtc}
}

function Get-DomeniaCapabilityPlan {
    # Removes from one collection plan what is known to be impossible on this workstation. A forced read ignores the
    # memory. The previous stored result of a probe also proves an absent class while its date is recent enough.
    param($Memory,[AllowEmptyString()][string]$Target,[object[]]$Probes=@(),$Previous=$null,[datetime]$NowUtc=[datetime]::UtcNow,
        [AllowEmptyString()][string]$Build='',[long]$AccountGeneration=0,[bool]$Force=$false)
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $all = @(@($Probes) | Where-Object { $null -ne $_ })
    if ($Force) { return [pscustomobject]@{Probes=$all;Skipped=@();SkipCim=$false;CimReason=''} }
    $cim = Test-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability 'cim' -NowUtc $NowUtc -Build $Build -AccountGeneration $AccountGeneration
    $previousProbes = Get-DomeniaMemberValue $Previous 'Probes' $null
    $ttl = Get-DomeniaCapabilityTtlSeconds 'ClassAbsent'
    foreach ($probe in $all) {
        $capability = Get-DomeniaProbeCapability $probe
        $fact = Test-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability $capability -NowUtc $NowUtc -Build $Build -AccountGeneration $AccountGeneration
        if ((-not [bool]$fact.Known) -and ($null -ne $previousProbes)) {
            $old = Get-DomeniaMemberValue $previousProbes ([string]$probe.Id) $null
            $oldError = [string](Get-DomeniaMember $old 'Error' '')
            $oldAt = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $old 'CheckedUtc' $null)
            if ((Test-DomeniaWmiClassAbsentText $oldError) -and ($null -ne $oldAt) -and (($NowUtc - $oldAt).TotalSeconds -lt $ttl) -and ($oldAt -le $NowUtc.AddMinutes(1))) {
                $fact = Register-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability $capability -Kind 'ClassAbsent' -NowUtc $oldAt -Build $Build -AccountGeneration $AccountGeneration
                $fact = Test-DomeniaCapabilityFact -Memory $Memory -Target $Target -Capability $capability -NowUtc $NowUtc -Build $Build -AccountGeneration $AccountGeneration
            }
        }
        if ([bool]$fact.Known) { $skipped.Add([pscustomobject]@{Id=[string]$probe.Id;Kind=[string]$fact.Kind;Reason=[string]$fact.Reason}); continue }
        $kept.Add($probe)
    }
    return [pscustomobject]@{Probes=$kept.ToArray();Skipped=$skipped.ToArray();SkipCim=[bool]$cim.Known;CimReason=[string]$cim.Reason}
}

# ---------------------------------------------------------------- point 13: grouping of the CIM reads
function Get-DomeniaCimGroupKey {
    # Namespace and class names are case-insensitive; the filter is kept byte for byte (two literals never share).
    param([AllowEmptyString()][string]$Namespace,[AllowEmptyString()][string]$Class,[AllowEmptyString()][string]$Filter='')
    return (([string]$Namespace).ToUpperInvariant() + '|' + ([string]$Class).ToUpperInvariant() + '|' + [string]$Filter)
}

function Measure-DomeniaCimQueryPlan {
    # Expected CIM queries of one workstation: what each consumer would send alone, and what the shared reads send.
    # Console and inventory share Win32_ComputerSystem; the system type of the controller check joins the inventory
    # read of Win32_OperatingSystem; catalog probes of a class already read reuse it when their properties are there.
    param([bool]$ProbeUser=$true,[bool]$Inventory=$false,[object[]]$Probes=@())
    $requested = 0; $groups = @{}
    $cs = Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_ComputerSystem' ''
    $os = Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_OperatingSystem' ''
    $disk = Get-DomeniaCimGroupKey 'root\cimv2' 'Win32_LogicalDisk' "DeviceID='C:'"
    if ($ProbeUser) { $requested++; $groups[$cs] = $true }
    if ($Inventory) { $requested += 3; $groups[$cs] = $true; $groups[$os] = $true; $groups[$disk] = $true }
    $needProductType = $false
    foreach ($probe in @($Probes)) {
        if ($null -eq $probe) { continue }
        $requested++
        if ([string](Get-DomeniaMember $probe 'Skip' '') -eq 'DomainController') { $needProductType = $true }
        $groups[(Get-DomeniaCimGroupKey ([string](Get-DomeniaMember $probe 'Namespace' '')) ([string](Get-DomeniaMember $probe 'Class' '')) ([string](Get-DomeniaMember $probe 'Filter' '')))] = $true
    }
    if ($needProductType) { $requested++; $groups[$os] = $true }
    $executed = $groups.Count
    return [pscustomobject]@{Requested=$requested;Executed=$executed;Avoided=[Math]::Max(0,$requested - $executed)}
}

# ---------------------------------------------------------------- point 17: progress of a campaign
function Get-DomeniaCampaignProgressState {
    # Validated results are those read back from SQLite after COMMIT. Elapsed is the total time, Idle the time since
    # the last validated result, Held the time spent waiting with free places (budgets, retries, storage).
    param([int]$Total=0,[int]$Validated=0,[int]$Pending=0,[int]$Waiting=0,$StartedUtc=$null,$LastValidatedUtc=$null,[double]$HeldSeconds=0,
        [datetime]$NowUtc=[datetime]::UtcNow,[int]$StallSeconds=120)
    $started = ConvertTo-DomeniaUtcDate $StartedUtc
    $last = ConvertTo-DomeniaUtcDate $LastValidatedUtc
    $elapsed = 0.0
    if ($null -ne $started) { $elapsed = [Math]::Max(0.0,($NowUtc - $started).TotalSeconds) }
    $idle = $elapsed
    if ($null -ne $last) { $idle = [Math]::Max(0.0,($NowUtc - $last).TotalSeconds) }
    $active = (($Pending -gt 0) -or ($Waiting -gt 0))
    $stalled = ($active -and ($idle -gt [Math]::Max(10,$StallSeconds)))
    $text = [string]$Validated + '/' + [string]$Total + ' résultat(s) validé(s) · ' + (Format-DomeniaCollectionDuration ([long]$elapsed)) + ' écoulé(s)'
    if ($null -ne $last) { $text += ' · dernier résultat validé il y a ' + (Format-DomeniaCollectionDuration ([long]$idle)) }
    elseif ($active) { $text += ' · aucun résultat validé pour lʼinstant' }
    if ($HeldSeconds -ge 1) { $text += ' · attente réelle ' + (Format-DomeniaCollectionDuration ([long]$HeldSeconds)) }
    if ($stalled) { $text += ' · aucun progrès depuis ' + (Format-DomeniaCollectionDuration ([long]$idle)) + ' : les lectures en cours attendent leur délai' }
    return [pscustomobject]@{ElapsedSeconds=$elapsed;IdleSeconds=$idle;HeldSeconds=$HeldSeconds;Stalled=$stalled;Text=$text}
}

# ---------------------------------------------------------------- point 20: durable campaign plan
function Get-DomeniaCampaignPlanKinds { return @('Ping','Console','Wmi','Analysis') }

function New-DomeniaCampaignPlan {
    # Read-only campaigns only: ping, console, WMI or analysis of explicit workstations. The plan never holds a
    # credential, an AD write or a free query; only names, DN, GUID and the probe identifiers of the catalog.
    param([Parameter(Mandatory=$true)][ValidateSet('Ping','Console','Wmi','Analysis')][string]$Kind,[object[]]$Targets=@(),
        [string[]]$ProbeIds=@(),[bool]$Inventory=$false,[AllowEmptyString()][string]$ScopeLabel='',[AllowEmptyString()][string]$DomainDn='',
        [AllowEmptyString()][string]$DatabasePath='',[datetime]$NowUtc=[datetime]::UtcNow,[AllowEmptyString()][string]$Id='')
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        $name = [string](Get-DomeniaMember $target 'Computer' (Get-DomeniaMember $target 'name' ''))
        $dn = [string](Get-DomeniaMember $target 'Key' (Get-DomeniaMember $target 'distinguished_name' ''))
        $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $target 'Guid' (Get-DomeniaMember $target 'object_guid' ''))
        if ((-not $name) -or (-not $dn) -or (-not $guid)) { continue }
        $key = $guid.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $rows.Add([pscustomobject]@{N=$name;D=$dn;G=$guid})
    }
    if (-not $Id) { $Id = [guid]::NewGuid().ToString('N') }
    return [pscustomobject]@{Schema='DomeniaCampaignPlan/1';Id=$Id;Kind=$Kind;CreatedUtc=$NowUtc.ToString('o');DomainDn=([string]$DomainDn).Trim();DatabasePath=[string]$DatabasePath
        ScopeLabel=[string]$ScopeLabel;Inventory=$Inventory;ProbeIds=@(@($ProbeIds) | Where-Object { [string]$_ -match '^[A-Za-z0-9_.-]{1,128}$' } | ForEach-Object { [string]$_ } | Select-Object -Unique);Targets=$rows.ToArray()}
}

function New-DomeniaCampaignProgress {
    # The progress file repeats the head of the plan: the resume offer reads it without unpacking the target list.
    param([Parameter(Mandatory=$true)]$Plan,[datetime]$NowUtc=[datetime]::UtcNow)
    $count = @($Plan.Targets).Count
    return [pscustomobject]@{Schema='DomeniaCampaignProgress/1';PlanId=[string]$Plan.Id;Kind=[string]$Plan.Kind;CreatedUtc=[string]$Plan.CreatedUtc;DomainDn=[string]$Plan.DomainDn
        DatabasePath=[string]$Plan.DatabasePath;ScopeLabel=[string]$Plan.ScopeLabel;Done=(New-Object byte[] ([int][Math]::Ceiling($count / 8.0)));DoneCount=0;Total=$count
        State='Running';Reason='';UpdatedUtc=$NowUtc.ToString('o')}
}

function Set-DomeniaCampaignTargetDone {
    # Marks one target as validated (result committed). Idempotent: a duplicate delivery counts once.
    param([Parameter(Mandatory=$true)]$Progress,[int]$Index)
    if (($Index -lt 0) -or ($Index -ge [int]$Progress.Total)) { return $false }
    $byte = [int][Math]::Floor($Index / 8); $bit = [byte](1 -shl ($Index % 8))
    if (([byte]$Progress.Done[$byte] -band $bit) -ne 0) { return $false }
    $Progress.Done[$byte] = [byte]([byte]$Progress.Done[$byte] -bor $bit)
    $Progress.DoneCount = [int]$Progress.DoneCount + 1
    return $true
}

function Test-DomeniaCampaignTargetDone {
    param([Parameter(Mandatory=$true)]$Progress,[int]$Index)
    if (($Index -lt 0) -or ($Index -ge [int]$Progress.Total)) { return $false }
    return ((([byte]$Progress.Done[[int][Math]::Floor($Index / 8)]) -band [byte](1 -shl ($Index % 8))) -ne 0)
}

function ConvertTo-DomeniaCampaignTargetsText {
    # One line per workstation: name, DN and GUID separated by tabs. A DN with a control character is refused rather
    # than written in a form that could not be read back exactly.
    param([object[]]$Targets=@())
    $builder = New-Object Text.StringBuilder
    foreach ($target in @($Targets)) {
        $name = [string]$target.N; $dn = [string]$target.D; $guid = [string]$target.G
        if (($name + $dn + $guid) -match '[\x00-\x1F]') { throw 'Poste au nom ou DN non conservable dans le plan.' }
        [void]$builder.Append($name).Append([char]9).Append($dn).Append([char]9).Append($guid).Append([char]10)
    }
    return $builder.ToString()
}

function ConvertTo-DomeniaCampaignPlanText {
    # The target list is compressed: a 20 000 workstation plan stays under the size limit of a preference file.
    param([Parameter(Mandatory=$true)]$Plan)
    $raw = ConvertTo-DomeniaCampaignTargetsText @($Plan.Targets)
    $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
    $buffer = [IO.MemoryStream]::new()
    try {
        $zip = [IO.Compression.GZipStream]::new($buffer,[IO.Compression.CompressionMode]::Compress,$true)
        try { $zip.Write($bytes,0,$bytes.Length) } finally { $zip.Dispose() }
        $packed = [Convert]::ToBase64String($buffer.ToArray())
    } finally { $buffer.Dispose() }
    $head = [ordered]@{Schema=[string]$Plan.Schema;Id=[string]$Plan.Id;Kind=[string]$Plan.Kind;CreatedUtc=[string]$Plan.CreatedUtc;DomainDn=[string]$Plan.DomainDn
        DatabasePath=[string]$Plan.DatabasePath;ScopeLabel=[string]$Plan.ScopeLabel;Inventory=[bool]$Plan.Inventory;ProbeIds=@($Plan.ProbeIds);Count=@($Plan.Targets).Count
        TargetsSha256=(Get-DomeniaTextHash $raw);Targets=$packed}
    return ([pscustomobject]$head | ConvertTo-Json -Depth 4 -Compress)
}

function ConvertFrom-DomeniaCampaignPlanText {
    # Refuses anything else than a well formed read campaign whose target list matches its digest.
    param([AllowEmptyString()][string]$Text)
    $head = $null
    try { $head = ConvertFrom-Json -InputObject ([string]$Text) -ErrorAction Stop } catch { throw 'Plan de relevé illisible.' }
    if ([string](Get-DomeniaMember $head 'Schema' '') -cne 'DomeniaCampaignPlan/1') { throw 'Plan de relevé dʼune version inconnue.' }
    if (@(Get-DomeniaCampaignPlanKinds) -notcontains [string](Get-DomeniaMember $head 'Kind' '')) { throw 'Plan de relevé dʼun type non autorisé.' }
    if ([string](Get-DomeniaMember $head 'Id' '') -notmatch '^[0-9a-fA-F]{32}$') { throw 'Identifiant de plan invalide.' }
    $raw = $null
    try {
        $source = [IO.MemoryStream]::new([Convert]::FromBase64String([string](Get-DomeniaMember $head 'Targets' '')))
        try {
            $zip = [IO.Compression.GZipStream]::new($source,[IO.Compression.CompressionMode]::Decompress)
            $output = [IO.MemoryStream]::new()
            try { $zip.CopyTo($output); $raw = [Text.Encoding]::UTF8.GetString($output.ToArray()) } finally { $output.Dispose(); $zip.Dispose() }
        } finally { $source.Dispose() }
    } catch { throw 'Liste des postes du plan illisible.' }
    if ((Get-DomeniaTextHash $raw) -cne [string](Get-DomeniaMember $head 'TargetsSha256' '')) { throw 'Liste des postes du plan altérée.' }
    $clean = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $raw.Split([char]10)) {
        if (-not $line) { continue }
        $fields = $line.Split([char]9)
        if ($fields.Count -ne 3) { throw 'Poste du plan invalide.' }
        $guid = ConvertTo-DomeniaGuidText $fields[2]
        if ((-not $guid) -or ($fields[0] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$') -or (-not $fields[1])) { throw 'Poste du plan invalide.' }
        $clean.Add([pscustomobject]@{N=$fields[0];D=$fields[1];G=$guid})
    }
    if ($clean.Count -ne [int](Get-DomeniaMember $head 'Count' -1)) { throw 'Nombre de postes du plan incohérent.' }
    return [pscustomobject]@{Schema='DomeniaCampaignPlan/1';Id=[string]$head.Id;Kind=[string]$head.Kind;CreatedUtc=[string](Get-DomeniaMember $head 'CreatedUtc' '');DomainDn=[string](Get-DomeniaMember $head 'DomainDn' '')
        DatabasePath=[string](Get-DomeniaMember $head 'DatabasePath' '');ScopeLabel=[string](Get-DomeniaMember $head 'ScopeLabel' '');Inventory=[bool](Get-DomeniaMember $head 'Inventory' $false)
        ProbeIds=@(@(Get-DomeniaMember $head 'ProbeIds' @()) | Where-Object { [string]$_ -match '^[A-Za-z0-9_.-]{1,128}$' } | ForEach-Object { [string]$_ });Targets=$clean.ToArray()}
}

function ConvertTo-DomeniaCampaignProgressText {
    param([Parameter(Mandatory=$true)]$Progress)
    return ([pscustomobject][ordered]@{Schema='DomeniaCampaignProgress/1';PlanId=[string]$Progress.PlanId;Kind=[string]$Progress.Kind;CreatedUtc=[string]$Progress.CreatedUtc
        DomainDn=[string]$Progress.DomainDn;DatabasePath=[string]$Progress.DatabasePath;ScopeLabel=[string]$Progress.ScopeLabel;Total=[int]$Progress.Total;DoneCount=[int]$Progress.DoneCount
        Done=[Convert]::ToBase64String([byte[]]$Progress.Done);State=[string]$Progress.State;Reason=[string]$Progress.Reason;UpdatedUtc=[string]$Progress.UpdatedUtc} | ConvertTo-Json -Compress)
}

function ConvertFrom-DomeniaCampaignProgressText {
    # Progress alone (resume offer) or checked against its plan (resume). The counter is recomputed from the bits:
    # a damaged counter never hides a remaining workstation.
    param([AllowEmptyString()][string]$Text,$Plan=$null)
    $data = $null
    try { $data = ConvertFrom-Json -InputObject ([string]$Text) -ErrorAction Stop } catch { throw 'Avancement du relevé illisible.' }
    if ([string](Get-DomeniaMember $data 'Schema' '') -cne 'DomeniaCampaignProgress/1') { throw 'Avancement du relevé dʼune version inconnue.' }
    if ([string](Get-DomeniaMember $data 'PlanId' '') -notmatch '^[0-9a-fA-F]{32}$') { throw 'Avancement du relevé illisible.' }
    if (@(Get-DomeniaCampaignPlanKinds) -notcontains [string](Get-DomeniaMember $data 'Kind' '')) { throw 'Avancement dʼun relevé dʼun type non autorisé.' }
    $total = [int](Get-DomeniaMember $data 'Total' -1)
    if ($null -ne $Plan) {
        if ([string](Get-DomeniaMember $data 'PlanId' '') -cne [string]$Plan.Id) { throw 'Avancement dʼun autre plan.' }
        if ($total -ne @($Plan.Targets).Count) { throw 'Avancement incohérent avec le plan.' }
    }
    if ($total -lt 0) { throw 'Avancement incohérent.' }
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String([string](Get-DomeniaMember $data 'Done' '')) } catch { throw 'Avancement du relevé illisible.' }
    if ($bytes.Length -ne [int][Math]::Ceiling($total / 8.0)) { throw 'Avancement incohérent avec le plan.' }
    $progress = [pscustomobject]@{Schema='DomeniaCampaignProgress/1';PlanId=[string]$data.PlanId;Kind=[string]$data.Kind;CreatedUtc=[string](Get-DomeniaMember $data 'CreatedUtc' '')
        DomainDn=[string](Get-DomeniaMember $data 'DomainDn' '');DatabasePath=[string](Get-DomeniaMember $data 'DatabasePath' '');ScopeLabel=[string](Get-DomeniaMember $data 'ScopeLabel' '')
        Done=$bytes;DoneCount=0;Total=$total;State=[string](Get-DomeniaMember $data 'State' 'Interrupted');Reason=[string](Get-DomeniaMember $data 'Reason' '');UpdatedUtc=[string](Get-DomeniaMember $data 'UpdatedUtc' '')}
    $done = 0
    for ($i = 0; $i -lt $total; $i++) { if (Test-DomeniaCampaignTargetDone $progress $i) { $done++ } }
    $progress.DoneCount = $done
    return $progress
}

function Get-DomeniaCampaignRemainingTargets {
    # Workstations not validated yet, in plan order, in the shape of the explicit scope of a collection.
    param([Parameter(Mandatory=$true)]$Plan,[Parameter(Mandatory=$true)]$Progress)
    $out = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    foreach ($target in @($Plan.Targets)) {
        if (-not (Test-DomeniaCampaignTargetDone $Progress $index)) { $out.Add([pscustomobject]@{name=[string]$target.N;distinguished_name=[string]$target.D;object_guid=[string]$target.G}) }
        $index++
    }
    return $out.ToArray()
}

function Get-DomeniaCampaignResumeState {
    # A plan is offered again only on the same domain and the same local base, and only while targets remain.
    param($Progress,[AllowEmptyString()][string]$DomainDn='',[AllowEmptyString()][string]$DatabasePath='')
    if ($null -eq $Progress) { return [pscustomobject]@{Resumable=$false;Remaining=0;Total=0;Reason='Aucun relevé interrompu.'} }
    $total = [int]$Progress.Total
    $remaining = [Math]::Max(0,$total - [int]$Progress.DoneCount)
    if ($remaining -eq 0) { return [pscustomobject]@{Resumable=$false;Remaining=0;Total=$total;Reason='Relevé terminé : aucun poste restant.'} }
    if ([string]$Progress.DomainDn -ine ([string]$DomainDn).Trim()) { return [pscustomobject]@{Resumable=$false;Remaining=$remaining;Total=$total;Reason='Relevé interrompu sur un autre domaine : non proposé ici.'} }
    if ([string]$Progress.DatabasePath -ine [string]$DatabasePath) { return [pscustomobject]@{Resumable=$false;Remaining=$remaining;Total=$total;Reason='Relevé interrompu sur une autre base locale : non proposé ici.'} }
    $when = ''
    $created = ConvertTo-DomeniaUtcDate ([string]$Progress.CreatedUtc)
    if ($null -ne $created) { $when = ' du ' + $created.ToLocalTime().ToString('dd/MM à HH:mm') }
    $label = ''
    if ([string]$Progress.ScopeLabel) { $label = ' (' + [string]$Progress.ScopeLabel + ')' }
    $why = ''
    switch ([string]$Progress.State) {
        'Paused' { $why = ' arrêté par lʼopérateur' }
        'Closed' { $why = ' interrompu par la fermeture de Domenia' }
        'Incident' { $why = ' interrompu par un incident' }
        default { $why = ' interrompu' }
    }
    $detail = ''
    if ([string]$Progress.Reason) { $detail = ' Motif : ' + [string]$Progress.Reason }
    return [pscustomobject]@{Resumable=$true;Remaining=$remaining;Total=$total;Reason=('Relevé' + $when + $label + $why + ' : ' + [string]$remaining + ' poste(s) restant(s) sur ' + [string]$total + '. La reprise ne relit que les postes non validés, en lecture seule.' + $detail)}
}
