# Fleet board provider: dashboards made of widgets (decision David 2026-10-07). The FleetStats worker groups the
# workstations of the OU in SQL by the boundaries this module gives it (Get-DomeniaFleetQueryPlan) and returns small
# aggregates; the rules (verdicts, thresholds, end of service) are applied here to those aggregates (decision David
# 2026-10-08, PF-03 and PF-21). Pure rules: no WPF, no AD, no network, no disk, no script state (the caller keeps the
# returned Observations, Last and Snapshot).

function Get-DomeniaFleetQueryPlan {
    # Boundaries given to the FleetStats worker, which only groups by them (no rule is copied into the pinned body).
    # LogonBounds: lastLogonTimestamp day strictly after the bound n = bucket n (0-6, 7-29, 30-89, 90-179 days), older
    # = 4, never = 5. Dates of the computer facts are UTC ISO texts compared as text.
    param([datetime]$Now = [datetime]::Now,[int]$ObservationMaxAgeDays = 30,$HealthPolicy=$null)
    $policy=ConvertTo-DomeniaHealthPolicy $HealthPolicy
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $utc = $Now.ToUniversalTime()
    $maxAge = [Math]::Max(1,[Math]::Min(3650,$ObservationMaxAgeDays))
    return [pscustomobject]@{
        LogonBounds = @(foreach ($days in @(7,30,90,180)) { $Now.Date.AddDays(0 - $days).ToString('yyyy-MM-dd',$invariant) })
        CreatedSince = $utc.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ',$invariant)
        PasswordBefore = $utc.AddDays(-[int]$policy.Thresholds.PasswordDays).ToString('yyyy-MM-ddTHH:mm:ssZ',$invariant)
        NowUtc = $utc.ToString('yyyy-MM-ddTHH:mm:ssZ',$invariant)
        ObservationsSince = $utc.AddDays(0 - $maxAge).ToString('o',$invariant)
        Today = $Now.ToString('yyyy-MM-dd',$invariant)
        HistorySince = $Now.Date.AddDays(-400).ToString('yyyy-MM-dd',$invariant)
    }
}

function Get-DomeniaFleetPointTargets {
    # Workstations of one point of attention, from the rows already in memory (no request): the machines of the
    # aggregate groups named by the point, or the observed machines it lists. At most $Max, in name order.
    param([object[]]$Machines = @(),$Point = $null,[int]$Max = 200)
    $result = New-Object System.Collections.ArrayList
    if ($null -eq $Point) { return @() }
    $listed = @()
    $machinesProperty = $Point.PSObject.Properties['Machines']
    if ($null -ne $machinesProperty) { $listed = @($machinesProperty.Value | Where-Object { $null -ne $_ }) }
    if ($listed.Count) {
        foreach ($machine in @($listed | Sort-Object -Property @{ Expression = { [string]$_.name } })) { if ($result.Count -ge $Max) { break }; [void]$result.Add($machine) }
        return @($result)
    }
    $wanted = @{}
    $groupsProperty = $Point.PSObject.Properties['Groups']
    if ($null -ne $groupsProperty) { foreach ($gid in @($groupsProperty.Value)) { if ($null -ne $gid) { $wanted[[string]$gid] = $true } } }
    if (-not $wanted.Count) { return @() }
    foreach ($machine in @($Machines)) {
        if ($null -eq $machine) { continue }
        if ($wanted.ContainsKey([string]$machine.gid)) { [void]$result.Add($machine); if ($result.Count -ge $Max) { break } }
    }
    return @($result)
}

function Get-DomeniaFleetBoardData {
    # Entries of the Fleet board for the OU chosen in Rechercher (empty scope = whole indexed domain; -Subtree:$false =
    # its direct children only). Throws the text shown by Fail-DomeniaFleetDashboard when the worker result cannot be
    # used, so the previous board stays on screen. $Lifecycle: the delivered end-of-service table, read once by the
    # interface ($null: end dates unknown, never critical). Also returns Observations (lower-cased DN -> observation of
    # the workstations returned by the worker), Last ({Scope; Subtree; Targets; Machines}) and Snapshot (figures of the
    # daily local snapshot; Taken tells whether today's one already exists).
    param($Result,[string]$Scope = '',[bool]$Subtree = $true,[datetime]$Now = [datetime]::Now,$Lifecycle = $null,[int]$ObservationMaxAgeDays = 30,[string]$IndexPartial = '',$HealthPolicy=$null,$HealthPolicyBook=$null)
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $nowUtc = $Now.ToUniversalTime()

    # Last worker output carrying the aggregates (same rule as Get-DomeniaEffectiveWorkerResult).
    $source = $null
    foreach ($candidate in @($Result)) {
        if ($null -eq $candidate) { continue }
        if (($null -ne $candidate.PSObject.Properties['Types']) -and ($null -ne $candidate.PSObject.Properties['Groups'])) { $source = $candidate }
    }
    if ($null -eq $source) {
        # A locked base answers Busy without any aggregate.
        $locked = @(@($Result) | Where-Object { ($null -ne $_) -and ($null -ne $_.PSObject.Properties['Busy']) -and ([bool]$_.Busy) })
        if ($locked.Count) { throw 'base occupee, reessayez dans un instant.' }
        throw 'reponse incomplete.'
    }
    $busyProperty = $source.PSObject.Properties['Busy']
    if (($null -ne $busyProperty) -and ([bool]$busyProperty.Value)) { throw 'base occupee, reessayez dans un instant.' }
    $member = {
        param($Object,[string]$Name,$Default)
        if ($null -eq $Object) { return $Default }
        $property = $Object.PSObject.Properties[$Name]
        if (($null -eq $property) -or ($null -eq $property.Value)) { return $Default }
        return $property.Value
    }

    $scope = ([string]$Scope).Trim()
    $data = New-DomeniaBoardData -Board Fleet
    $data.HealthPolicy=ConvertTo-DomeniaHealthPolicy $HealthPolicy
    $data.HealthPolicy.EvaluatedAtUtc=$nowUtc.ToString('o')
    $limits=$data.HealthPolicy.Thresholds
    $domainDn=[string](& $member $source 'DomainDn' '')
    if(-not $domainDn){
        $domainDn=$scope
        while($domainDn -and $domainDn -notmatch '^(?i:DC)='){$domainDn=Get-DomeniaRawDnParent $domainDn}
    }
    $snapshotAt=ConvertFrom-DomeniaUtcText ([string](& $member $source 'SnapshotAtUtc' ''))
    $referenceAt=if($null -ne $snapshotAt){$snapshotAt}else{$nowUtc}
    $syncStates=Get-DomeniaMemberValue $source 'SyncStates'
    if($syncStates -isnot [Collections.IDictionary]){$syncStates=@{}}
    $indexFreshness=Get-DomeniaFleetFreshness -ScopeDn $scope -DomainDn $domainDn -SyncStates $syncStates -Subtree $Subtree -NowUtc $referenceAt
    if($null -ne $source.PSObject.Properties['SyncStates']){$IndexPartial=if($indexFreshness.Partial){'dernière tentative incomplète le '+$indexFreshness.AttemptAt.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{''}}
    $searchLink = [pscustomobject]@{ Id = 'CollectFleet'; Text = 'Relever ce périmètre'; Tip = 'Prépare la collecte des postes actifs de ce tableau de bord, avec confirmation.'; Link = $true }
    $lifecycleKnown = $false
    if ($null -ne $Lifecycle) {
        $entriesProperty = $Lifecycle.PSObject.Properties['Entries']
        $lifecycleKnown = (@($(if ($null -ne $entriesProperty) { @($entriesProperty.Value) } else { @($Lifecycle) }) | Where-Object { $null -ne $_ }).Count -gt 0)
    }
    $data|Add-Member -NotePropertyName LifecycleKnown -NotePropertyValue $lifecycleKnown
    if($IndexPartial){$data.Partial=[pscustomobject]@{Text='Base AD incomplète : couverture partielle';Action=$null}}
    # Parts of a count table, largest first; ties by label so the order never depends on the hash.
    $rank = {
        param($Table)
        return @($Table.GetEnumerator() | Sort-Object -Property @{ Expression = { [double]$_.Value }; Descending = $true }, @{ Expression = { [string]$_.Key }; Descending = $false } | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [double]$_.Value } })
    }
    # Dominant part and its share, so a chart can also be shown as a figure.
    $share = {
        param([object[]]$Items,[double]$Total)
        $top = $null
        foreach ($part in @($Items)) { if (($null -ne $part) -and (($null -eq $top) -or ([double]$part.Value -gt [double]$top.Value))) { $top = $part } }
        if ($null -eq $top) { return [pscustomobject]@{ Value = ''; Detail = '' } }
        return [pscustomobject]@{ Value = [string]$top.Label; Detail = ([string][int]$top.Value + ' poste(s) sur ' + [string][int]$Total) }
    }
    $plural = { param([int]$Count,[string]$One,[string]$Many) if ($Count -gt 1) { return $Many } else { return $One } }

    # ----------------------------------------------------------------------------------------------------------------
    # Directory aggregates: one group per combination of system, version, activity, facts, LAPS and BitLocker
    # ----------------------------------------------------------------------------------------------------------------
    $groups = @(@($source.Groups) | Where-Object { $null -ne $_ })
    $active = @($groups | Where-Object { [string]$_.st -eq 'A' })
    $unknownGroups = @($groups | Where-Object { [string]$_.st -notin @('A','D') })
    $accountUnknown=0;foreach($group in $unknownGroups){$accountUnknown += [int]$group.n}
    $machines=[object[]]@(& $member $source 'Machines' @())
    $enabledByDn=@{};foreach($machine in $machines){if($machine.st -eq 'A'){$enabledByDn[([string]$machine.distinguished_name).ToLowerInvariant()]=$machine}}
    $groupTargets=@{};$widgetMembers=@{}
    foreach($machine in $machines){if($machine.st -eq 'A'){$gid=[string]$machine.gid;if(-not $groupTargets.ContainsKey($gid)){$groupTargets[$gid]=[Collections.Generic.List[object]]::new()};$groupTargets[$gid].Add($machine)}}
    $addWidgetTargets={param([string]$Key,[object[]]$Rows)if(-not $widgetMembers.ContainsKey($Key)){$widgetMembers[$Key]=[Collections.Generic.List[object]]::new()};$widgetMembers[$Key].AddRange($Rows)}
    $disabledGroups = @($groups | Where-Object { [string]$_.st -eq 'D' })
    $total = 0; foreach ($group in $active) { $total += [int]$group.n }
    $disabled = 0; foreach ($group in $disabledGroups) { $disabled += [int]$group.n }
    # Buckets of the worker (lb 0 to 5) named with their unit (decision David 2026-10-08, CO-16).
    $buckets = [ordered]@{ '0 à 6 j' = 0; '7 à 29 j' = 0; '30 à 89 j' = 0; '90 à 179 j' = 0; '180 j et plus' = 0; 'non renseignée' = 0 }
    $bucketNames = @($buckets.Keys)
    $osCounts = @{}; $versions = @{}; $releaseCache = @{}
    $ended = @{}; $soon = @{}
    $stale = 0; $never = 0; $created = 0; $pwdOld = 0; $windows10 = 0; $versionRead = 0
    $staleGroups = New-Object System.Collections.ArrayList; $neverGroups = New-Object System.Collections.ArrayList
    $createdGroups = New-Object System.Collections.ArrayList; $pwdGroups = New-Object System.Collections.ArrayList
    $win10Groups = New-Object System.Collections.ArrayList; $win10Status = @{}; $win10End = $null
    $kinds = [ordered]@{ 'Postes de travail' = 0; 'Serveurs' = 0; 'Système non renseigné' = 0 }
    $laps = @{ 'O' = 0; 'E' = 0; 'N' = 0; 'X' = 0; '' = 0 }
    $bitlocker = @{ 'K' = 0; 'N' = 0; 'X' = 0; 'U' = 0 }
    $factsKnown = 0
    $problem = @{}
    # Point 75: groups whose end-of-service date is determined, the data the eos rules need.
    $eosKnownGroups = @{}
    foreach ($group in $active) {
        $n = [int]$group.n; $gid = [string]$group.gid
        $os = ([string]$group.os).Trim(); if (-not $os) { $os = 'Systeme non renseigne' }
        $os = $os -replace '^Microsoft ','' -replace 'Professionnel|Professional','Pro'
        $osCounts[$os] = $n + [int]$osCounts[$os]
        $ver = [string]$group.ver
        $releaseKey = $os + '|' + $ver
        if (-not $releaseCache.ContainsKey($releaseKey)) { $releaseCache[$releaseKey] = Get-DomeniaWindowsRelease -Build $ver -Caption $os -Lifecycle $Lifecycle -Now $Now }
        $release = $releaseCache[$releaseKey]
        $eosKnownGroups[$gid] = [bool]([string]$release.End)
        # Serveurs / postes (FO-11): from operatingSystem, the family of the lifecycle table (no extra call per group).
        $kind = if (-not ([string]$group.os).Trim()) { 'Système non renseigné' } elseif ([string]$release.Family -eq 'Server') { 'Serveurs' } else { 'Postes de travail' }
        $kinds[$kind] = $n + [int]$kinds[$kind]
        $label = if ([string]$release.Build) { $(if ([string]$release.Label) { [string]$release.Label } else { $os + ' (build ' + [string]$release.Build + ')' }) } else { 'Version non lue' }
        if ([string]$release.Build) { $versionRead += $n }
        $versions[$label] = $n + [int]$versions[$label]
        $eosLabel = if ([string]$release.Label) { [string]$release.Label } else { $os }
        if ([string]$release.Status -eq 'Ended') {
            if (-not $ended.ContainsKey($eosLabel)) { $ended[$eosLabel] = [pscustomobject]@{ Total = 0; End = [string]$release.End; Guessed = (-not [string]$release.Build); Groups = (New-Object System.Collections.ArrayList) } }
            $ended[$eosLabel].Total += $n; [void]$ended[$eosLabel].Groups.Add($gid); $problem[$gid] = $true
        } elseif ([string]$release.Status -eq 'Soon') {
            if (-not $soon.ContainsKey($eosLabel)) { $soon[$eosLabel] = [pscustomobject]@{ Total = 0; End = [string]$release.End; Groups = (New-Object System.Collections.ArrayList) } }
            $soon[$eosLabel].Total += $n; [void]$soon[$eosLabel].Groups.Add($gid); $problem[$gid] = $true
        }
        # Windows 10 out of LTSC, LTSB and IoT (decision David 2026-10-08, CO-13).
        if ((($os -like 'Windows 10*') -or ([string]$release.Name -like 'Windows 10*')) -and ([string]$release.Family -in @('Pro','Enterprise'))) {
            $windows10 += $n; [void]$win10Groups.Add($gid)
            $win10Status[[string]$release.Status] = $n + [int]$win10Status[[string]$release.Status]
            if (($release.EndDate -is [datetime]) -and (($null -eq $win10End) -or ($release.EndDate -gt $win10End))) { $win10End = $release.EndDate }
        }
        $lb = 5; try { $lb = [int]$group.lb } catch { $lb = 5 }
        if (($lb -lt 0) -or ($lb -gt 5)) { $lb = 5 }
        $buckets[$bucketNames[$lb]] = $n + [int]$buckets[$bucketNames[$lb]]

        if ($lb -eq 5) { $never += $n; [void]$neverGroups.Add($gid); $problem[$gid] = $true }
        $cr = [string]$group.cr; $pw = [string]$group.pw
        if ($cr -or $pw) { $factsKnown += $n }
        if ($cr -eq 'R') { $created += $n; [void]$createdGroups.Add($gid) }
        if ($pw -eq 'O') { $pwdOld += $n; [void]$pwdGroups.Add($gid); $problem[$gid] = $true }
        $lk = [string]$group.lk; if (-not $laps.ContainsKey($lk)) { $lk = '' }
        $laps[$lk] = $n + [int]$laps[$lk]
        $bk = [string]$group.bk; if (-not $bitlocker.ContainsKey($bk)) { $bk = 'U' }
        $bitlocker[$bk] = $n + [int]$bitlocker[$bk]
        $rows=@($groupTargets[$gid]);$keys=@('fleet.versions',('fleet.versions|'+$label),'fleet.os',('fleet.os|'+$os),'fleet.servers',('fleet.servers|'+$kind),'fleet.lastlogon',('fleet.lastlogon|'+$bucketNames[$lb]))
        if($cr -eq 'R'){$keys+='fleet.created'};if($pw -eq 'O'){$keys+='fleet.pwdold'};if($lk -eq 'N'){$keys+='fleet.laps'};if($bk -eq 'N'){$keys+='fleet.bitlocker'}
        if([string]$release.Status -eq 'Ended'){$keys+='fleet.eos'}
        if($win10Groups -contains $gid){$keys+='fleet.win10'}
        foreach($key in $keys){& $addWidgetTargets $key $rows}
    }
    # Activity is independent of network reachability. Use the actual replicated AD date for custom thresholds.
    $staleMachines=[Collections.Generic.List[object]]::new();$activityUnknown=[Collections.Generic.List[object]]::new()
    $cutoff=$Now.Date.AddDays(-[int]$limits.StaleDays)
    foreach($machine in $machines){
        if($machine.st -ne 'A'){continue}
        $stamp=[datetime]::MinValue
        if([datetime]::TryParseExact([string]$machine.logon,'yyyy-MM-dd',$invariant,[Globalization.DateTimeStyles]::None,[ref]$stamp) -and $stamp -le $Now.Date){
            if($stamp -le $cutoff){$staleMachines.Add($machine)}
        }else{$activityUnknown.Add($machine)}
    }
    $stale=$staleMachines.Count
    # LAPS and BitLocker: a missing value only counts when at least one value is visible with this account
    # (decision David 2026-10-08): otherwise nothing tells "no LAPS" from "not readable".
    $lapsVisible = [int]$laps['O'] + [int]$laps['E']
    $bitlockerVisible = [int]$bitlocker['K']
    $lapsGroups = New-Object System.Collections.ArrayList; $lapsExpiredGroups = New-Object System.Collections.ArrayList; $bitlockerGroups = New-Object System.Collections.ArrayList
    foreach ($group in $active) {
        $gid = [string]$group.gid
        if (($lapsVisible -gt 0) -and ([string]$group.lk -eq 'N')) { [void]$lapsGroups.Add($gid); $problem[$gid] = $true }
        if (($lapsVisible -gt 0) -and ([string]$group.lk -eq 'E')) { [void]$lapsExpiredGroups.Add($gid); $problem[$gid] = $true }
        if (($bitlockerVisible -gt 0) -and ([string]$group.bk -eq 'N')) { [void]$bitlockerGroups.Add($gid); $problem[$gid] = $true }
    }
    $unhealthy = 0
    foreach ($group in $active) { if ($problem.ContainsKey([string]$group.gid)) { $unhealthy += [int]$group.n } }
    $disabledIds = @($disabledGroups | ForEach-Object { [string]$_.gid })

    # Coverage figures computed by the worker (facts read with the base, BitLocker presence read on request).
    $coverage = & $member $source 'Coverage' $null
    $factsFresh = [int](& $member $coverage 'FactsFresh' 0)
    $factsStale = [int](& $member $coverage 'FactsStale' 0)
    $bitlockerRead = [int](& $member $coverage 'BitLockerRead' 0)
    $bitlockerAt = ConvertFrom-DomeniaUtcText ([string](& $member $coverage 'BitLockerAt' ''))
    $factsMissing = ($factsFresh -eq 0)
    $factsText = if ($factsStale -gt 0) { 'À relire : la base a été remise à jour sans ces attributs. Mettez-la à jour.' } else { 'Non lu : mettez à jour la base autonome pour lire cet attribut.' }

    # ----------------------------------------------------------------------------------------------------------------
    # Observations kept by the detections and analyses (presence, console user, light WMI inventory), attached by GUID
    # to the active workstations of the perimeter by the worker; past $ObservationMaxAgeDays they are left out, past
    # seven days they are shown greyed (decision David 2026-10-08, FI-04).
    # ----------------------------------------------------------------------------------------------------------------
    $presence = @{ 'En ligne' = 0; 'Sans réponse' = 0; 'Non vérifié' = 0 }
    $presenceTargets=@{'En ligne'=[Collections.Generic.List[object]]::new();'Sans réponse'=[Collections.Generic.List[object]]::new();'Non vérifié'=[Collections.Generic.List[object]]::new()};$presenceSeen=@{}
    # Point 72: the WMI answer is read from its own CIM families, never inferred from the ping (and conversely).
    $wmiNames=@('WMI a répondu','WMI non confirmé','WMI non relevé');$wmiByState=@{Responded='WMI a répondu';Failed='WMI non confirmé';NotRead='WMI non relevé'}
    $reachNames=@('Ping et WMI répondent','WMI répond, pas le ping','Ping répond, WMI non confirmé','Ni ping ni WMI','Un seul canal relevé','Aucun relevé')
    $wmiTargets=@{};foreach($name in $wmiNames){$wmiTargets[$name]=[Collections.Generic.List[object]]::new()}
    $reachTargets=@{};foreach($name in $reachNames){$reachTargets[$name]=[Collections.Generic.List[object]]::new()}
    # Oldest usable WMI date (success or failure), for the same seven-day greying as the other observations (FI-04).
    $unreachableWmi=0;$wmiOldest=$null
    $users = @{}; $sessions = 0; $inventories = New-Object System.Collections.ArrayList; $lastCheck = $null; $oldest = $null
    $observations = @{}; $observed = 0;$canonicalPresence=[Collections.Generic.List[object]]::new()
    $unreachable = New-Object System.Collections.ArrayList; $lowDiskMachines = New-Object System.Collections.ArrayList; $uptimeMachines = New-Object System.Collections.ArrayList
    $tightDiskMachines = New-Object System.Collections.ArrayList
    $observedProblem = @{}
    # Figure of the daily snapshot: only when a disk size was read (otherwise unknown, never 0).
    $lowDiskFigure = $null
    $inventoryNewest=$null;$inventoryOldest=$null;$inventoryReleaseCache=@{};$healthInventoryKnown=@{};$customMeasures=[Collections.Generic.List[object]]::new()
    foreach ($item in @(& $member $source 'Presence' @())) {
        if ($null -eq $item) { continue }
        $observation = & $member $item 'observation' $null
        if ($null -eq $observation) { continue }
        $key = ([string]$item.object_key).ToLowerInvariant()
        if (-not [bool](& $member $item 'in_scope' $true) -or -not $enabledByDn.ContainsKey($key) -or $presenceSeen.ContainsKey($key)) { continue }
        $target=$enabledByDn[$key]
        if([string]$target.object_guid -ine [string]$item.object_guid){continue}
        $presenceSeen[$key]=$true
        $canonicalPresence.Add($item)
        # Retain only canonical observations of this perimeter. Each probe has its own source date.
        $familyDates=@((Get-DomeniaHealthValue $observation 'PresenceCheckedUtc'),(Get-DomeniaHealthValue $observation 'ObservedUtc'),(Get-DomeniaHealthValue (Get-DomeniaHealthValue $observation 'Inventory') 'CheckedUtc'))
        $probes=Get-DomeniaHealthValue $observation 'Probes'
        $probeIds=if($null -eq $probes){@()}elseif($probes -is [Collections.IDictionary]){$probes.Keys}else{$probes.PSObject.Properties.Name}
        foreach($probeId in $probeIds){$familyDates+=Get-DomeniaHealthValue (Get-DomeniaHealthValue $probes ([string]$probeId)) 'CheckedUtc'}
        $hasFreshFamily=@($familyDates|Where-Object{(Test-DomeniaObservationAge -CheckedUtc $_ -NowUtc $nowUtc -MaxDays $ObservationMaxAgeDays) -ne 'Expired'}).Count -gt 0
        if($hasFreshFamily){$observations[$key] = $observation}
        # Only the ping source timestamp dates presence. A recent WMI read never refreshes an old ping.
        $checked=ConvertFrom-DomeniaUtcText ([string](& $member $observation 'PresenceCheckedUtc' ''))
        $pingAge=Test-DomeniaObservationAge -CheckedUtc $checked -NowUtc $nowUtc -MaxDays $ObservationMaxAgeDays
        $state=[string](& $member $observation 'Presence' '')
        $presenceKey='Non vérifié'
        if($pingAge -ne 'Expired'){
            if($state -eq 'En ligne'){$presenceKey='En ligne'}
            elseif($state -match '^(Sans r[eé]ponse(?: au ping)?|Hors ligne)$'){$presenceKey='Sans réponse'}
        }
        $presence[$presenceKey]++
        $presenceTargets[$presenceKey].Add($target)
        $wmiResponse=Get-DomeniaFleetWmiResponse -Observation $observation -NowUtc $nowUtc -MaxDays $ObservationMaxAgeDays;$wmiState=[string]$wmiResponse.State
        if(($null -ne $wmiResponse.At) -and (($null -eq $wmiOldest) -or ($wmiResponse.At -lt $wmiOldest))){$wmiOldest=$wmiResponse.At}
        $wmiTargets[$wmiByState[$wmiState]].Add($target)
        $reachTargets[(Get-DomeniaFleetReachLabel -Presence $presenceKey -Wmi $wmiState)].Add($target)
        if(($presenceKey -eq 'Sans réponse') -and ($wmiState -eq 'Responded')){$unreachableWmi++}
        if($presenceKey -ne 'Non vérifié'){
            $observed++
            if(($null -eq $lastCheck) -or ($checked -gt $lastCheck)){$lastCheck=$checked}
            if(($null -eq $oldest) -or ($checked -lt $oldest)){$oldest=$checked}
        }
        if($presenceKey -eq 'Sans réponse'){[void]$unreachable.Add($target)}
        # CO-11: distinct users, without case.
        $user = ([string](& $member $observation 'LinkUser' '')).Trim()
        $userAge=Test-DomeniaObservationAge -CheckedUtc ([string](& $member $observation 'ObservedUtc' '')) -NowUtc $nowUtc -MaxDays $ObservationMaxAgeDays
        if ($user -and $userAge -ne 'Expired') { $users[$user.ToLowerInvariant()] = $true; $sessions++ }
        $inventory = & $member $observation 'Inventory' $null
        $inventoryAge=Test-DomeniaObservationAge -CheckedUtc ([string](& $member $inventory 'CheckedUtc' '')) -NowUtc $nowUtc -MaxDays $ObservationMaxAgeDays
        # Point 85: BIOS version of each workstation for the model x BIOS cross table, from the detailed probe first.
        foreach($biosProbeId in @('hw.biosdetails','hw.bios')){
            $biosResult=Get-DomeniaHealthValue $probes $biosProbeId
            if($null -eq $biosResult){continue}
            if((Test-DomeniaObservationAge -CheckedUtc ([string](Get-DomeniaHealthValue $biosResult 'CheckedUtc' '')) -NowUtc $nowUtc -MaxDays $ObservationMaxAgeDays) -eq 'Expired'){continue}
            $biosProbe=Get-DomeniaProbe $biosProbeId;if($null -eq $biosProbe){continue}
            $biosVersion=[string](@(Get-DomeniaProbeValues $biosProbe $biosResult|Where-Object{[string]$_})|Select-Object -First 1)
            if($biosVersion){& $addWidgetTargets ('fleet.bios|'+$biosVersion.Trim()) @($target);break}
        }
        if ($null -ne $inventory -and $inventoryAge -ne 'Expired') {
            [void]$inventories.Add([pscustomobject]@{ Inventory = $inventory; Target = $target })
            $inventoryAt=ConvertFrom-DomeniaUtcText ([string](& $member $inventory 'CheckedUtc' ''))
            if($null -eq $inventoryNewest -or $inventoryAt -gt $inventoryNewest){$inventoryNewest=$inventoryAt}
            if($null -eq $inventoryOldest -or $inventoryAt -lt $inventoryOldest){$inventoryOldest=$inventoryAt}
        }
    }
    foreach($target in $enabledByDn.Values){if(-not $presenceSeen.ContainsKey(([string]$target.distinguished_name).ToLowerInvariant())){$presence['Non vérifié']++;$presenceTargets['Non vérifié'].Add($target);$wmiTargets['WMI non relevé'].Add($target);$reachTargets['Aucun relevé'].Add($target)}}
    $observedOld = (($null -ne $oldest) -and (($nowUtc - $oldest).TotalDays -gt 7))
    $observedText = Get-DomeniaCoverageText -Analysed $observed -Total $total -LastUtc $lastCheck

    # ----------------------------------------------------------------------------------------------------------------
    # Points of attention, most serious first (the order of Complete-DomeniaBoardData)
    # ----------------------------------------------------------------------------------------------------------------
    foreach ($name in @($ended.Keys | Sort-Object)) {
        $part = $ended[$name]
        $when = if ([bool]$part.Guessed) { 'fin de service au plus tard le ' + [string]$part.End } else { 'fin de service le ' + [string]$part.End }
        Add-DomeniaBoardAttention -Data $data -Level Alert -Text ([string]$part.Total + ' poste(s) sous ' + $name + ', ' + $when + ' : à migrer.') -Point 'eos.ended' -Groups @($part.Groups)
    }
    foreach ($name in @($soon.Keys | Sort-Object)) {
        $part = $soon[$name]
        Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$part.Total + ' poste(s) sous ' + $name + ', fin de service le ' + [string]$part.End + '.') -Point 'eos.soon' -Groups @($part.Groups)
    }
    if ($stale) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$stale + ' poste(s) sans connexion au domaine depuis '+$limits.StaleDays+' jours ou plus (date AD approximative) : à vérifier.') -Point 'stale' -Machines $staleMachines.ToArray() }
    if ($never) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$never + ' compte(s) ordinateur sans date de connexion AD renseignée.') -Point 'never' -Groups @($neverGroups) }
    # The local base is incomplete (last update stopped at its limit): every figure of this board may be underestimated.
    if ($IndexPartial) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ('Base locale incomplète : ' + $IndexPartial + ' Les chiffres peuvent être sous-estimés : utilisez Mettre à jour cette OU.') -Point 'index.partial' }
    if ($pwdOld) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$pwdOld + ' poste(s) avec un mot de passe machine de plus de '+$limits.PasswordDays+' jours.') -Point 'pwdold' -Groups @($pwdGroups) }
    if (($lapsVisible -gt 0) -and [int]$laps['N']) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$laps['N'] + ' poste(s) sans expiration LAPS visible.') -Point 'laps.none' -Groups @($lapsGroups) }
    if ([int]$laps['E']) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$laps['E'] + ' poste(s) dont le mot de passe LAPS a expiré.') -Point 'laps.expired' -Groups @($lapsExpiredGroups) }
    if (($bitlockerVisible -gt 0) -and [int]$bitlocker['N']) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$bitlocker['N'] + ' poste(s) sans clé BitLocker visible.') -Point 'bitlocker.none' -Groups @($bitlockerGroups) }
    if ($created) { Add-DomeniaBoardAttention -Data $data -Level Info -Text ([string]$created + ' poste(s) créé(s) ces 30 derniers jours.') -Point 'created' -Groups @($createdGroups) }
    if ($disabled) { Add-DomeniaBoardAttention -Data $data -Level Info -Text ([string]$disabled + ' compte(s) ordinateur désactivé(s) encore dans lʼOU : à déplacer ou supprimer.') -Point 'disabled' -Groups $disabledIds }
    # Point 72: no ICMP answer is never a verdict of a switched-off or unqueryable workstation.
    if ($unreachable.Count) { Add-DomeniaBoardAttention -Data $data -Level Info -Text ([string]$unreachable.Count + ' poste(s) sans réponse au ping au dernier relevé' + $(if ($unreachableWmi) { ', dont ' + [string]$unreachableWmi + ' ayant répondu à WMI (ICMP probablement filtré)' } else { '' }) + ' : absence de réponse, pas une preuve dʼarrêt.') -Point 'unreachable' -Machines @($unreachable) }
    $wmiFailed = $wmiTargets['WMI non confirmé']
    if ($wmiFailed.Count) { Add-DomeniaBoardAttention -Data $data -Level Info -Text ([string]$wmiFailed.Count + ' poste(s) sans lecture WMI confirmée au dernier essai (accès refusé, délai ou service indisponible) : à relever de nouveau, pas une preuve dʼarrêt.') -Point 'wmi.failed' -Machines $wmiFailed.ToArray() }

    # ----------------------------------------------------------------------------------------------------------------
    # Inventaire du perimetre
    # ----------------------------------------------------------------------------------------------------------------
    $activeUsers = 0
    foreach ($type in @($source.Types)) { if (($null -ne $type) -and ([string]$type.t -eq 'Utilisateur') -and ([string]$type.s -eq 'Actif')) { $activeUsers += [long]$type.n } }
    $links = 0
    try { $links = [int](& $member $source 'Links' 0) } catch { $links = 0 }
    # La tuile compte la base entiere du perimetre, desactives compris : c'est le seul chiffre comparable a la
    # recherche, qui interroge l'annuaire en direct et ne filtre aucun etat. La ventilation est detaillee ici, la
    # tuile fleet.disabled garde son role d'alerte, et les ratios (versions, LAPS, BitLocker) restent sur les actifs.
    $machineCount = $total + $disabled + $accountUnknown
    $machineDetail=[string]$total+' activés · '+[string]$disabled+' désactivés · '+[string]$accountUnknown+' état inconnu · '+$(if(-not $scope){'domaine indexé'}elseif($Subtree){'OU et sous-OU'}else{'OU directe'})
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.machines' -Kind Value -Value ([string]$machineCount) -Detail $machineDetail)
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.enabled' -Kind Value -Value ([string]$total) -Detail 'Comptes AD activés ; ce nombre ne décrit pas la présence réseau')
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.accountunknown' -Kind Value -Value ([string]$accountUnknown) -State $(if($accountUnknown){'Off'}else{''}) -Detail 'État du compte AD non lu ; ne vaut ni activé ni désactivé')
    $accountItems=@([pscustomobject]@{Label='Activés';Value=$total},[pscustomobject]@{Label='Désactivés';Value=$disabled},[pscustomobject]@{Label='État inconnu';Value=$accountUnknown})
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.accountstatus' -Kind Distribution -Value ([string]$machineCount) -Detail $machineDetail -Items $accountItems -CenterText ([string]$machineCount+' comptes'))
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.stale' -Kind Value -Value ([string]$stale) -State $(if ($stale) { 'Warn' } else { 'Ok' }) -Title ('Sans connexion AD depuis '+$limits.StaleDays+' j') -Detail ('lastLogonTimestamp approximatif ; '+$activityUnknown.Count+' date(s) inconnue(s), sans rapport avec le ping'))
    $kindItems = @(foreach ($name in @($kinds.Keys)) { if ([int]$kinds[$name] -gt 0) { [pscustomobject]@{ Label = [string]$name; Value = [double]$kinds[$name] } } })
    if ($kindItems.Count) {
        $servers = [int]$kinds['Serveurs']
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.servers' -Kind Distribution -Value ([string]$servers + ' serveur' + $(if ($servers -gt 1) { 's' } else { '' })) -Detail ([string]$kinds['Postes de travail'] + ' poste(s) de travail sur ' + [string]$total + ' comptes actifs') -Items $kindItems -CenterText ([string]$total + ' comptes'))
    }
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.disabled' -Kind Value -Value ([string]$disabled) -State $(if ($disabled) { 'Warn' } else { 'Ok' }) -Detail $(if ($disabled) { 'Désactivés, encore dans le périmètre' } else { 'Aucun compte désactivé dans le périmètre' }))
    if ($factsMissing) {
        foreach ($key in @('fleet.created','fleet.pwdold')) { Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key $key -Kind Value -Value $(if ($factsStale -gt 0) { 'À relire' } else { 'Non lu' }) -Detail $factsText -State Off) }
    } else {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.created' -Kind Value -Value ([string]$created) -Detail ('Lu avec la base pour ' + [string]$factsKnown + ' poste(s) sur ' + [string]$total))
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.pwdold' -Title ('Mot de passe machine de plus de '+$limits.PasswordDays+' j') -Kind Value -Value ([string]$pwdOld) -State $(if ($pwdOld) { 'Warn' } else { 'Ok' }) -Detail ('Lu avec la base pour ' + [string]$factsKnown + ' poste(s) sur ' + [string]$total))
    }

    # Securite : LAPS (expiration read with the base) and BitLocker (presence read on request for the OU).
    $lapsRead = $lapsVisible + [int]$laps['N'] + [int]$laps['X']
    if ($factsMissing -or (-not $lapsRead)) {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.laps' -Kind Value -Value $(if ($factsStale -gt 0) { 'À relire' } else { 'Non lu' }) -Detail $factsText -State Off)
    } elseif (($lapsVisible + [int]$laps['N']) -eq 0) {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.laps' -Kind Value -Value 'Non disponible' -Detail 'Non disponible dans ce domaine : attributs LAPS absents du schéma.' -State Off)
    } elseif ($lapsVisible -eq 0) {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.laps' -Kind Value -Value 'Non déterminé' -Detail ('Aucune expiration LAPS visible avec ce compte sur ' + [string]$total + ' poste(s) (droits ou LAPS non déployé).') -State Off)
    } else {
        $lapsMissing = [int]$laps['N']
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.laps' -Kind Value -Value ([string]$lapsMissing) -State $(if ($lapsMissing -or [int]$laps['E']) { 'Warn' } else { 'Ok' }) -Detail ([string]$lapsVisible + ' poste(s) avec expiration visible' + $(if ([int]$laps['E']) { ', dont ' + [string]$laps['E'] + ' expirée(s)' } else { '' }) + ' sur ' + [string]$total))
    }
    $bitlockerAction = if ($scope) { [pscustomobject]@{ Id = 'BitLockerPresence'; Text = 'Lire la présence des clés BitLocker de cette OU'; Tip = 'Recherche paginée des objets de récupération de lʼOU affichée (nom, emplacement et date seulement, jamais la clé).' } } else { $null }
    if (-not $bitlockerRead) {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.bitlocker' -Kind Value -Value 'Non lu' -Detail $(if ($scope) { 'Présence des clés non lue pour cette OU.' } else { 'Choisissez une OU avec le sélecteur du tableau de bord : lecture refusée à la racine du domaine.' }) -State Off -Action $bitlockerAction)
    } elseif (([int]$bitlocker['K'] + [int]$bitlocker['N']) -eq 0) {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.bitlocker' -Kind Value -Value 'Non disponible' -Detail 'Non disponible dans ce domaine : classe de récupération BitLocker absente du schéma.' -State Off -Action $bitlockerAction)
    } elseif ($bitlockerVisible -eq 0) {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.bitlocker' -Kind Value -Value 'Non déterminé' -Detail ('Aucune clé visible avec ce compte (droits ou clés non sauvegardées dans AD) · ' + (Get-DomeniaCoverageText -Analysed $bitlockerRead -Total $total -LastUtc $bitlockerAt)) -State Off -Action $bitlockerAction)
    } else {
        $bitlockerMissing = [int]$bitlocker['N']
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.bitlocker' -Kind Value -Value ([string]$bitlockerMissing) -State $(if ($bitlockerMissing) { 'Warn' } else { 'Ok' }) -Detail (Get-DomeniaCoverageText -Analysed $bitlockerRead -Total $total -LastUtc $bitlockerAt) -Action $bitlockerAction)
    }

    # Versions de Windows (operatingSystemVersion) and end of service (FO-08).
    if ($total) {
        $versionItems = @(& $rank $versions)
        $lead = & $share $versionItems $total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.versions' -Kind Distribution -Value $lead.Value -Detail $(if ($versionRead) { $lead.Detail } else { $factsText }) -Items $versionItems -CenterText ([string]$total + ' postes'))
    }
    $endedCount = 0; foreach ($part in @($ended.Values)) { $endedCount += [int]$part.Total }
    $soonCount = 0; foreach ($part in @($soon.Values)) { $soonCount += [int]$part.Total }
    if (-not $lifecycleKnown) {
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.eos' -Kind Value -Value 'Non déterminé' -Detail 'Table des fins de service absente : date de fin inconnue.' -State Off)
    } else {
        $eosDetail = if ($soonCount) { [string]$soonCount + ' à surveiller (fin dans 90 jours ou moins)' } elseif ($endedCount) { 'Versions plus maintenues : à migrer' } else { 'Aucune version en fin de service' }
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.eos' -Kind Value -Value ([string]$endedCount) -State $(if ($endedCount) { 'Alert' } elseif ($soonCount) { 'Warn' } else { 'Ok' }) -Detail $eosDetail)
    }
    # Windows 10 out of LTSC, LTSB and IoT: its state comes from the end-of-service table, never from a date in the code
    # (no table: end date unknown, never critical).
    if (-not $lifecycleKnown) { $win10State = 'Off'; $win10Detail = 'Hors LTSC, LTSB et IoT : date de fin inconnue (table des fins de service absente)' }
    elseif (-not $windows10) { $win10State = 'Ok'; $win10Detail = 'Hors LTSC, LTSB et IoT' }
    else {
        $win10State = if ([int]$win10Status['Ended']) { 'Alert' } elseif ([int]$win10Status['Soon']) { 'Warn' } elseif ([int]$win10Status['Ok']) { 'Ok' } else { 'Off' }
        $win10Detail = 'Hors LTSC, LTSB et IoT' + $(if ($null -ne $win10End) { ' : fin de service le ' + $win10End.ToString('dd/MM/yyyy',$invariant) } else { ' : date de fin inconnue' })
    }
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.win10' -Kind Value -Value ([string]$windows10) -State $win10State -Detail $win10Detail)

    # Repartition
    $osRanked = @(& $rank $osCounts)
    $osItems = @($osRanked | Select-Object -First 6)
    $osOthers = 0.0
    foreach ($part in @($osRanked | Select-Object -Skip 6)) { $osOthers += [double]$part.Value }
    if ($osOthers -gt 0) { $osItems += [pscustomobject]@{ Label = 'Autres'; Value = $osOthers } }
    if ($osItems.Count) {
        $lead = & $share $osRanked $total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.os' -Kind Distribution -Value $lead.Value -Detail $lead.Detail -Items $osItems -CenterText ([string]$total + ' postes'))
    }
    if ($total) {
        # Every bucket is kept, empty ones included: they show the distribution.
        $logonItems = @(foreach ($name in $bucketNames) { [pscustomobject]@{ Label = [string]$name; Value = [double]$buckets[$name] } })
        $lead = & $share $logonItems $total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.lastlogon' -Kind Series -Value $lead.Value -Detail $lead.Detail -Items $logonItems)
    }
    # Postes par OU: from the parent DN of the workstations (GROUP BY in the worker). Whole domain: the OU that holds
    # the workstation; chosen OU: its direct sub-OU containing the workstation.
    $sites = @{}
    foreach ($parent in @(& $member $source 'Parents' @())) {
        if ($null -eq $parent) { continue }
        $siteName = Get-DomeniaDnSite -ParentDn ([string]$parent.p) -Scope $scope
        $sites[$siteName] = [int]$parent.n + [int]$sites[$siteName]
    }
    $ouRanked = @(& $rank $sites)
    $ouItems = @($ouRanked)
    if ($ouItems.Count) {
        $lead = & $share $ouRanked $total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.ou' -Kind Distribution -Title $(if ($scope) { 'Postes par sous-OU' } else { '' }) -Value $lead.Value -Detail $lead.Detail -Items $ouItems -CenterText ([string]$total + ' postes'))
    }
    if (-not $total) {
        $data.Hints['Répartition'] = 'Aucun poste actif indexé dans ce périmètre : mettez à jour la base autonome.'
        $data.Hints['Repartition'] = $data.Hints['Répartition']
        # SP-17: on the home overview only a link to Rechercher, where the base and the analyses are run.
        $data.HintActions['Répartition'] = $searchLink; $data.HintActions['Repartition'] = $searchLink
    }

    # Releves des postes (observations): presence, users, last analysis, light WMI inventory, with their coverage.
    $observationState = if ($observedOld) { 'Off' } else { '' }
    $presenceColors = @{ 'En ligne' = 'Ok'; 'Sans réponse' = 'Warn'; 'Non vérifié' = 'Off' }
    $presenceItems = @(foreach ($name in @('En ligne','Sans réponse','Non vérifié')) { if ([int]$presence[$name] -gt 0) { [pscustomobject]@{ Label = $name; Value = [double]$presence[$name]; Color = (Get-DomeniaBoardColor -Name $presenceColors[$name]) } } })
    if ($presenceItems.Count) {
        $presenceTotal = [int]$presence['En ligne'] + [int]$presence['Sans réponse'] + [int]$presence['Non vérifié']
        $lead = & $share $presenceItems $presenceTotal
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.presence' -Kind Distribution -Value $lead.Value -Detail $observedText -State $observationState -Items $presenceItems -CenterText ([string]$presenceTotal + ' postes'))
    }
    if ($total) {
        # Point 72: WMI answer and the ping/WMI comparison over the same active accounts, each with its own source dates.
        $wmiColors = @{ 'WMI a répondu' = 'Ok'; 'WMI non confirmé' = 'Warn'; 'WMI non relevé' = 'Off' }
        $wmiItems = @(foreach ($name in $wmiNames) { if ($wmiTargets[$name].Count) { [pscustomobject]@{ Label = $name; Value = [double]$wmiTargets[$name].Count; Color = (Get-DomeniaBoardColor -Name $wmiColors[$name]) } } })
        $wmiRead = $wmiTargets['WMI a répondu'].Count + $wmiTargets['WMI non confirmé'].Count
        # A WMI answer older than seven days is shown greyed, like the ping; the comparison is greyed when either is.
        $wmiOld = (($null -ne $wmiOldest) -and (($nowUtc - $wmiOldest).TotalDays -gt 7))
        $lead = & $share $wmiItems $total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.wmi' -Kind Distribution -Value $lead.Value -Detail ([string]$wmiRead + ' poste(s) avec une lecture WMI datée sur ' + [string]$total + ' ; indépendant du ping') -State $(if ($wmiOld) { 'Off' } else { '' }) -Items $wmiItems -CenterText ([string]$total + ' postes'))
        $reachColors = @{ 'Ping et WMI répondent' = 'Ok'; 'WMI répond, pas le ping' = 'Info'; 'Ping répond, WMI non confirmé' = 'Warn'; 'Ni ping ni WMI' = 'Warn'; 'Un seul canal relevé' = 'Off'; 'Aucun relevé' = 'Off' }
        $reachItems = @(foreach ($name in $reachNames) { if ($reachTargets[$name].Count) { [pscustomobject]@{ Label = $name; Value = [double]$reachTargets[$name].Count; Color = (Get-DomeniaBoardColor -Name $reachColors[$name]) } } })
        $lead = & $share $reachItems $total
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.reach' -Kind Distribution -Value $lead.Value -Detail 'Une absence de réponse au ping ou à WMI ne prouve pas que le poste est éteint.' -State $(if ($observedOld -or $wmiOld) { 'Off' } else { '' }) -Items $reachItems -CenterText ([string]$total + ' postes'))
    }
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.users' -Kind Value -Value ([string]$users.Count) -State $observationState -Detail ('sur ' + [string]$sessions + ' poste(s) avec une session · ' + [string]$links + ' associations au total'))
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.lastcheck' -Kind Value -Value $(if ($null -ne $lastCheck) { $lastCheck.ToLocalTime().ToString('dd/MM HH:mm',$invariant) } else { 'Aucune' }) -State $observationState -Detail $observedText)
    if (-not $inventories.Count) {
        $wmiHint = 'Relever ce périmètre recueille les modèles, la mémoire, les disques, les versions et les démarrages des postes actifs de lʼOU choisie.'
        $data.Hints['Relevés des postes'] = $wmiHint
        $data.Hints['Releves WMI'] = $wmiHint
        $data.HintActions['Relevés des postes'] = $searchLink; $data.HintActions['Releves WMI'] = $searchLink
    } else {
        $inventoryText=Get-DomeniaCoverageText -Analysed $inventories.Count -Total $total -LastUtc $inventoryNewest
        $inventoryOld=($null -ne $inventoryOldest -and ($nowUtc-$inventoryOldest).TotalDays -gt 7)
        $inventoryState=if($inventoryOld){'Off'}else{''}
        $models = @{}; $releases = @{}; $longUptime = 0; $lowDisk = 0; $tightDisk = 0; $bootSeen = 0
        # CO-16: whole bounds with their unit (12 Go is in '9 à 16 Go'); the reported total sits a little under the
        # nominal size, hence the half gigabyte of margin.
        $ram = [ordered]@{ ([string][char]0x2264 + ' 4 Go') = 0; '5 à 8 Go' = 0; '9 à 16 Go' = 0; '17 à 32 Go' = 0; '> 32 Go' = 0 }
        $ramNames = @($ram.Keys)
        # CO-14: the fleet uses the thresholds of the workstation (critical under 10 %, to watch under 20 %).
        $limits = Get-DomeniaBoardThresholds -Policy $data.HealthPolicy
        $alertLimit = [string][int]$limits.DiskFreeAlert; $warnLimit = [string][int]$limits.DiskFreeWarn
        $diskNames = if([int]$warnLimit -lt 50){@(('moins de ' + $alertLimit + ' %'), ($alertLimit + ' à ' + $warnLimit + ' %'), ($warnLimit + ' à 50 %'), '50 % et plus')}else{@(('moins de '+$alertLimit+' %'),($alertLimit+' à '+$warnLimit+' %'),($warnLimit+' % et plus'))}
        $disk = [ordered]@{}; foreach ($name in $diskNames) { $disk[$name] = 0 }
        foreach ($pair in $inventories) {
            $inventoryKeys=[Collections.Generic.List[string]]::new();$diskPercent=$null;$uptimeDays=$null;$knownInventory=[pscustomobject]@{Disk=$false;Boot=$false;DiskPercent=$null;UptimeDays=$null}
            $inventory = $pair.Inventory
            $model = ([string](& $member $inventory 'Model' '')).Trim(); if (-not $model) { $model = 'Modele inconnu' }
            $models[$model] = 1 + [int]$models[$model];$inventoryKeys.Add('fleet.models');$inventoryKeys.Add('fleet.models|'+$model)
            $gb = 0.0; try { $gb = [double](& $member $inventory 'RamBytes' 0) / 1GB } catch { $gb = 0.0 }
            $k = if ($gb -le 4.5) { $ramNames[0] } elseif ($gb -le 8.5) { $ramNames[1] } elseif ($gb -le 16.5) { $ramNames[2] } elseif ($gb -le 32.5) { $ramNames[3] } else { $ramNames[4] }
            if ($gb -gt 0) { $ram[$k] = 1 + [int]$ram[$k];$inventoryKeys.Add('fleet.ram');$inventoryKeys.Add('fleet.ram|'+$k) }
            $size = 0.0; try { $size = [double](& $member $inventory 'DiskSize' 0) } catch { $size = 0.0 }
            $freeValue=& $member $inventory 'DiskFree' $null
            $freeBytes=-1.0;try{if($null -ne $freeValue){$freeBytes=[double]$freeValue}}catch{}
            if ($size -gt 0 -and $freeBytes -ge 0 -and $freeBytes -le $size) {
                $free = 100.0 * $freeBytes / $size;$diskPercent=$free;$knownInventory.Disk=$true;$knownInventory.DiskPercent=$free
                $diskState = Get-DomeniaThresholdState -Measure DiskFree -Percent $free -Policy $data.HealthPolicy
                $dk = if ($diskState -eq 'Alert') { $diskNames[0] } elseif ($diskState -eq 'Warn') { $diskNames[1] } elseif ($diskNames.Count -eq 3 -or $free -lt 50) { $diskNames[2] } else { $diskNames[3] }
                $disk[$dk] = 1 + [int]$disk[$dk];$inventoryKeys.Add('fleet.diskfree');$inventoryKeys.Add('fleet.diskfree|'+$dk)
                if ($diskState -eq 'Alert') { $lowDisk++; [void]$lowDiskMachines.Add($pair.Target); $observedProblem[[string]$pair.Target.distinguished_name] = $pair.Target }
                elseif ($diskState -eq 'Warn') { $tightDisk++; [void]$tightDiskMachines.Add($pair.Target); $observedProblem[[string]$pair.Target.distinguished_name] = $pair.Target }
            }
            $build = ([string](& $member $inventory 'Build' '')).Trim()
            $caption=[string](& $member $inventory 'OsCaption' '');$releaseKey=$caption+'|'+$build
            if(-not $inventoryReleaseCache.ContainsKey($releaseKey)){$inventoryReleaseCache[$releaseKey]=(Get-DomeniaWindowsRelease -Build $build -Caption $caption -Lifecycle $Lifecycle -Now $Now).Name}
            $release=[string]$inventoryReleaseCache[$releaseKey]
            if (-not $release) { $release = if ($build) { 'Build ' + $build } else { 'Version inconnue' } }
            $releases[$release] = 1 + [int]$releases[$release];$inventoryKeys.Add('fleet.releases');$inventoryKeys.Add('fleet.releases|'+$release)
            foreach($key in $inventoryKeys){& $addWidgetTargets $key @($pair.Target)}
            $boot = & $member $inventory 'LastBootUtc' $null
            try {
                $bootUtc = if ($boot -is [datetime]) { $boot.ToUniversalTime() } else { [datetime]::Parse([string]$boot,$invariant).ToUniversalTime() }
                if($bootUtc -le $nowUtc){
                $bootSeen++;$uptimeDays=($nowUtc-$bootUtc).TotalDays;$knownInventory.Boot=$true;$knownInventory.UptimeDays=$uptimeDays
                if ($uptimeDays -gt $limits.UptimeDays) { $longUptime++; [void]$uptimeMachines.Add($pair.Target); $observedProblem[[string]$pair.Target.distinguished_name] = $pair.Target }
                }
            } catch { }
            $healthInventoryKnown[[string]$pair.Target.object_guid]=$knownInventory
            $customMeasures.Add([pscustomobject]@{Target=$pair.Target;DiskFree=$diskPercent;UptimeDays=$uptimeDays})
        }
        $modelRanked = @(& $rank $models)
        $modelItems = @($modelRanked)
        $lead = & $share $modelRanked $inventories.Count
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.models' -Kind Distribution -Value $lead.Value -Detail $inventoryText -State $inventoryState -Items $modelItems -CenterText ([string]$inventories.Count + ' postes'))
        $releaseItems = @(& $rank $releases)
        $lead = & $share $releaseItems $inventories.Count
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.releases' -Kind Distribution -Value $lead.Value -Detail $inventoryText -State $inventoryState -Items $releaseItems -CenterText ([string]$inventories.Count + ' postes'))
        $ramItems = @(foreach ($name in @($ram.Keys)) { [pscustomobject]@{ Label = [string]$name; Value = [double]$ram[$name] } })
        $ramTotal = 0.0; foreach ($part in $ramItems) { $ramTotal += [double]$part.Value }
        if ($ramTotal -gt 0) {
            $lead = & $share $ramItems $ramTotal
            Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.ram' -Kind Series -Value $lead.Value -Detail $inventoryText -State $inventoryState -Items $ramItems)
        }
        # Coloured like the workstation disk: critical, to watch, then the neutral colour of one series.
        $diskColors = @((Get-DomeniaBoardColor 'Alert'), (Get-DomeniaBoardColor 'Warn'), (Get-DomeniaBoardColor 'Info'), (Get-DomeniaBoardColor 'Info'))
        $diskItems = @(for ($d = 0; $d -lt $diskNames.Count; $d++) { [pscustomobject]@{ Label = [string]$diskNames[$d]; Value = [double]$disk[$diskNames[$d]]; Color = [string]$diskColors[$d] } })
        $diskTotal = 0.0; foreach ($part in $diskItems) { $diskTotal += [double]$part.Value }
        if ($diskTotal -gt 0) {
            $lowDiskFigure = $lowDisk
            $lead = & $share $diskItems $diskTotal
            Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.diskfree' -Kind Series -Value $lead.Value -Detail $inventoryText -State $inventoryState -Items $diskItems)
            # Only when a disk size was read: a failed WMI probe stores DiskSize 0, which is no "0 full disk".
            Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.lowdisk' -Kind Value -Value ([string]$lowDisk) -State $(if ($inventoryOld) { 'Off' } elseif ($lowDisk) { 'Alert' } else { 'Ok' }) -Detail ('Moins de ' + $alertLimit + ' % libre · ' + $inventoryText))
        }
        # Only when a boot date was read (a failed probe stores LastBootUtc '').
        if ($bootSeen -gt 0) { Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.uptime' -Title ('Sans redémarrage depuis '+$limits.UptimeDays+' j') -Kind Value -Value ([string]$longUptime) -State $(if ($inventoryOld) { 'Off' } elseif ($longUptime) { 'Warn' } else { 'Ok' }) -Detail ('Redémarrage conseillé · ' + $inventoryText)) }
        if ($lowDisk) { Add-DomeniaBoardAttention -Data $data -Level Alert -Text ([string]$lowDisk + ' poste(s) avec moins de ' + $alertLimit + ' % libre sur C:.') -Point 'lowdisk' -Machines @($lowDiskMachines) }
        if ($tightDisk) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$tightDisk + ' poste(s) avec peu dʼespace sur C: (moins de ' + $warnLimit + ' % libre).') -Point 'disk.tight' -Machines @($tightDiskMachines) }
        if ($longUptime) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$longUptime + ' poste(s) non redémarré(s) depuis plus de '+$limits.UptimeDays+' jours.') -Point 'uptime' -Machines @($uptimeMachines) }
    }
    $data|Add-Member -NotePropertyName HealthInventoryKnown -NotePropertyValue $healthInventoryKnown
    Add-DomeniaCustomHealthAttention -Data $data -Measures $customMeasures.ToArray()
    # A workstation with an observed problem and no directory problem is one more workstation to treat.
    foreach ($target in @($observedProblem.Values)) { if (-not $problem.ContainsKey([string]$target.gid)) { $unhealthy++ } }
    $healthy = [Math]::Max(0,$total - $unhealthy)

    # Evolution: daily local snapshots of the OU (FO-10), drawn once 90 days of history exist.
    $history = @(@(& $member $source 'History' @()) | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { [string]$_.day } })
    $today = $Now.ToString('yyyy-MM-dd',$invariant)
    $taken = (@($history | Where-Object { [string]$_.day -eq $today }).Count -gt 0)
    $since = $Now.Date.AddDays(-89).ToString('yyyy-MM-dd',$invariant)
    $first = if ($history.Count) { [string]$history[0].day } else { '' }
    if ($first -and ([string]::CompareOrdinal($first,$since) -le 0)) {
        # One curve per figure of the snapshots (FO-10); a day whose snapshot lacks the figure (older delivery, disks
        # not read) is left out of that curve, never drawn as 0.
        $curves = @(
            @('fleet.trend','Problems','postes à traiter'),
            @('fleet.trend.win10','Windows10','postes sous Windows 10'),
            # Point 71: the inactivity period is the configured one, never a fixed 90 days.
            @('fleet.trend.stale','Stale',('postes sans connexion AD au-delà du seuil (actuellement '+[string]$data.HealthPolicy.Thresholds.StaleDays+' j)')),
            @('fleet.trend.lowdisk','LowDisk','postes analysés avec C: presque plein')
        )
        $parsedDays = New-Object System.Collections.ArrayList
        foreach ($row in $history) {
            if ([string]::CompareOrdinal([string]$row.day,$since) -lt 0) { continue }
            $figures = $null
            try { $figures = ([string]$row.figures) | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($null -ne $figures) { [void]$parsedDays.Add([pscustomobject]@{ Label = ([string]$row.day).Substring(8,2) + '/' + ([string]$row.day).Substring(5,2); Figures = $figures }) }
        }
        foreach ($curve in $curves) {
            $points = New-Object System.Collections.ArrayList
            $drawn = New-Object System.Collections.ArrayList
            foreach ($day in $parsedDays) {
                $figure = & $member $day.Figures ([string]$curve[1]) $null
                if ($null -eq $figure) { continue }
                [void]$points.Add([pscustomobject]@{ Label = [string]$day.Label; Value = [double]$figure })
                [void]$drawn.Add($day.Figures)
            }
            # Point 71: each day counted its inactive accounts with the threshold of that day; a mix is stated.
            $note = if ([string]$curve[1] -eq 'Stale') { Get-DomeniaStaleTrendNote -Figures $drawn.ToArray() -StaleDays ([int]$data.HealthPolicy.Thresholds.StaleDays) } else { '' }
            if ($points.Count) { Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key ([string]$curve[0]) -Kind Timeline -Value ([string][int]$points[$points.Count - 1].Value) -Detail ([string]$points.Count + ' jour(s) relevé(s) sur 90 : ' + [string]$curve[2] + $note) -Items @($points)) }
        }
    } else {
        $days = 0
        if ($first) { $parsed = [datetime]::MinValue; if ([datetime]::TryParseExact($first,'yyyy-MM-dd',$invariant,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { $days = [int]($Now.Date - $parsed).TotalDays + 1 } }
        $data.Hints['Évolution'] = 'La courbe sʼaffiche après 90 jours dʼhistorique local (' + [string]$days + ' jour(s) aujourdʼhui) : un instantané est pris au premier calcul de lʼaccueil de chaque jour.'
    }

    $rejected=[int](& $member $source 'ObservationRejected' 0)
    if($rejected -gt 0){Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$rejected+' relevé(s) ignoré(s) : contenu illisible ou identité AD différente. Les postes restent dans la base et peuvent être relevés à nouveau.') -Point 'cache.invalid'}
    $data.Summary = [string]$machineCount+' comptes ordinateur dans le périmètre : '+$machineDetail+'.'
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Population' -Value ([pscustomobject]@{ Total = $total; Healthy = $healthy })
    $measurementFreshness=Get-DomeniaOuObservationFreshness -Presence $canonicalPresence.ToArray() -Total $total -NowUtc $referenceAt -MaxDays $ObservationMaxAgeDays
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Freshness' -Value ([pscustomobject]@{Version=1;ScopeDn=$scope;Subtree=$Subtree;Index=$indexFreshness;Observations=$measurementFreshness;SnapshotAtUtc=$snapshotAt;ComputedAtUtc=$nowUtc})
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Observations' -Value $observations
    # The worker rows are kept as they are, without copy nor pipeline: thousands of workstations stay cheap on the
    # interface thread (PF-21). Targets: the active workstations (name, distinguished_name, object_guid).
    $machines = [object[]]@(& $member $source 'Machines' @())
    $targetsProperty = $source.PSObject.Properties['Targets']
    if (($null -ne $targetsProperty) -and ($null -ne $targetsProperty.Value)) { $targets = [object[]]@($targetsProperty.Value | Where-Object { $_.st -eq 'A' }) }
    else {
        $targetList = New-Object 'System.Collections.Generic.List[object]'
        foreach ($machine in $machines) { if (($null -ne $machine) -and ($machine.st -eq 'A')) { $targetList.Add($machine) } }
        $targets = $targetList.ToArray()
    }
    $healthyTargets=[Collections.Generic.List[object]]::new();$problemTargets=[Collections.Generic.List[object]]::new()
    foreach($machine in $targets){
        if($problem.ContainsKey([string]$machine.gid) -or $observedProblem.ContainsKey([string]$machine.distinguished_name)){$problemTargets.Add($machine)}
        else{$healthyTargets.Add($machine)}
    }
    $widgetTargets=@{
        'fleet.machines'=@($machines);'fleet.enabled'=@($targets);'fleet.stale'=$staleMachines.ToArray()
        'fleet.disabled'=@($machines|Where-Object{$_.st -eq 'D'})
        'fleet.accountunknown'=@($machines|Where-Object{$_.st -notin @('A','D')})
    }
    $widgetTargets['fleet.accountstatus|Activés']=$widgetTargets['fleet.enabled']
    $widgetTargets['fleet.accountstatus|Désactivés']=$widgetTargets['fleet.disabled']
    $widgetTargets['fleet.accountstatus|État inconnu']=$widgetTargets['fleet.accountunknown']
    $widgetTargets['fleet.accountstatus']=@($machines)
    foreach($key in $widgetMembers.Keys){$widgetTargets[$key]=$widgetMembers[$key].ToArray()}
    foreach($key in @('fleet.created','fleet.pwdold','fleet.laps','fleet.bitlocker','fleet.eos','fleet.win10')){if(-not $widgetTargets.ContainsKey($key)){$widgetTargets[$key]=@()}}
    $widgetTargets['fleet.lowdisk']=@($lowDiskMachines);$widgetTargets['fleet.uptime']=@($uptimeMachines)
    $ouMembers=@{};$siteCache=@{}
    foreach($target in $targets){
        $parent=Get-DomeniaRawDnParent ([string]$target.distinguished_name)
        if(-not $siteCache.ContainsKey($parent)){$siteCache[$parent]=Get-DomeniaDnSite -ParentDn $parent -Scope $scope}
        $site=[string]$siteCache[$parent];if(-not $ouMembers.ContainsKey($site)){$ouMembers[$site]=[Collections.Generic.List[object]]::new()};$ouMembers[$site].Add($target)
    }
    $widgetTargets['fleet.ou']=@($targets);foreach($site in $ouMembers.Keys){$widgetTargets['fleet.ou|'+$site]=$ouMembers[$site].ToArray()}
    $widgetTargets['fleet.presence']=@($targets)
    foreach($label in $presenceTargets.Keys){$widgetTargets['fleet.presence|'+$label]=$presenceTargets[$label].ToArray()}
    $widgetTargets['fleet.wmi']=@($targets);foreach($label in $wmiTargets.Keys){$widgetTargets['fleet.wmi|'+$label]=$wmiTargets[$label].ToArray()}
    $widgetTargets['fleet.reach']=@($targets);foreach($label in $reachTargets.Keys){$widgetTargets['fleet.reach|'+$label]=$reachTargets[$label].ToArray()}
    foreach($entry in $data.Entries.Values){if($entry.Kind -in @('Distribution','Series')){foreach($part in @($entry.Items)){$key=[string]$entry.Key+'|'+[string]$part.Label;if(-not $widgetTargets.ContainsKey($key)){$widgetTargets[$key]=@()}}}}
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Last' -Value ([pscustomobject]@{ Scope = $scope; Subtree = [bool]$Subtree; Targets = $targets; Machines = $machines; Groups = $groups; WidgetTargets=$widgetTargets; HealthyTargets=$healthyTargets.ToArray(); ProblemTargets=$problemTargets.ToArray(); Freshness=$data.Freshness })
    # StaleDays: the inactivity threshold that produced Stale, kept so a later curve can tell days apart (point 71).
    $figures = [pscustomobject]@{ Machines = $total; Healthy = $healthy; Problems = ($total - $healthy); Stale = $stale; StaleDays = [int]$data.HealthPolicy.Thresholds.StaleDays; EndOfService = $endedCount; Disabled = $disabled; Windows10 = $windows10; LowDisk = $lowDiskFigure }
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Snapshot' -Value ([pscustomobject]@{ Day = $today; Taken = $taken; Figures = $figures })
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'EosKnownGroups' -Value $eosKnownGroups
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'HealthEligibility' -Value (Get-DomeniaFleetRuleEligibility -Data $data -NowUtc $nowUtc)
    if($null -ne $HealthPolicyBook -and @($HealthPolicyBook.Scopes).Count){Update-DomeniaFleetScopedHealth -Data $data -Book $HealthPolicyBook -NowUtc $nowUtc -Lifecycle $Lifecycle}
    [void](Complete-DomeniaBoardData -Data $data)
    $data.Last.WidgetTargets['fleet.health']=@($targets);$data.Last.WidgetTargets['fleet.attention']=@($data.Last.ProblemTargets)
    $data.Last.WidgetTargets['fleet.health|Sans problème']=@($data.Last.HealthyTargets);$data.Last.WidgetTargets['fleet.health|Problèmes']=@($data.Last.ProblemTargets);$data.Last.WidgetTargets['fleet.health|Incomplets']=@($data.Last.UnknownTargets)
    Set-DomeniaHealthSnapshotMetadata -Data $data -History $history -NowUtc $nowUtc
    $data|Add-Member -NotePropertyName Pivots -NotePropertyValue (Get-DomeniaFleetPivots $data)
    return $data
}

function Get-DomeniaFleetFreshness {
    # Only committed, complete coverage can date the base. Legacy OU markers do not prove their search depth.
    param([string]$ScopeDn,[string]$DomainDn,[Collections.IDictionary]$SyncStates,[bool]$Subtree=$true,[datetime]$NowUtc=[datetime]::UtcNow)
    $target=if($ScopeDn){$ScopeDn.Trim()}else{$DomainDn.Trim()}
    $ancestors=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $current=$target
    while($current){[void]$ancestors.Add($current);$current=Get-DomeniaRawDnParent $current}
    $at=$null;$source='';$sourceScope='';$sourceDepth='';$attemptAt=$null;$partial=$false;$legacyAt=$null;$clockInvalid=$false
    if($null -ne $SyncStates){foreach($entry in $SyncStates.Values){
        $key=[string]$entry.scope;$base=([string]$entry.base_dn).Trim();$details=[string]$entry.details
        if(-not $base -or -not $ancestors.Contains($base)){continue}
        $attempt=$key.StartsWith('attempt:',[StringComparison]::OrdinalIgnoreCase)
        $coverageKey=if($attempt){$key.Substring(8)}else{$key}
        $directory=($coverageKey -ieq 'directory')
        if($directory){if(-not $DomainDn -or $base -ine $DomainDn.Trim()){continue}}
        elseif($coverageKey -ine ('ou:'+$base) -and $coverageKey -ine ('ou:onelevel:'+$base)){continue}
        $stamp=ConvertFrom-DomeniaUtcText ([string]$entry.last_sync)
        if($null -eq $stamp){continue}
        if($stamp -gt $NowUtc){$clockInvalid=$true;continue}
        $depth='Unknown'
        if($details -match '(?i)(?:^|;)depth=(Subtree|OneLevel)(?:;|$)'){$depth=[string]$matches[1]}
        elseif($directory){$depth='Subtree'} # The directory checkpoint has always meant a complete domain census/delta.
        if($coverageKey -ieq ('ou:onelevel:'+$base) -and $depth -ine 'OneLevel'){continue}
        $covers=($depth -ieq 'Subtree' -or ($depth -ieq 'OneLevel' -and -not $Subtree -and $base -ieq $target))
        if($attempt){
            # A partial direct-children read can warn for this OU, but cannot cover its descendants.
            $overlaps=($depth -ieq 'Subtree' -or $base -ieq $target)
            if($overlaps -and ($null -eq $attemptAt -or $stamp -gt $attemptAt)){
                $attemptAt=$stamp;$partial=($details -match '^(?i:partial)(?:;|$)')
            }
            continue
        }
        if(-not $covers){
            if($depth -eq 'Unknown' -and ($null -eq $legacyAt -or $stamp -gt $legacyAt)){$legacyAt=$stamp}
            continue
        }
        if($null -eq $at -or $stamp -gt $at){$at=$stamp;$source=$base;$sourceScope=$coverageKey;$sourceDepth=$depth}
    }}
    $partial=($partial -and ($null -eq $at -or $attemptAt -ge $at))
    $unknown=($null -ne $legacyAt -and ($null -eq $at -or $legacyAt -gt $at))
    $status=if($partial){'Partial'}elseif($null -ne $at){'Complete'}elseif($unknown){'UnknownDepth'}else{'Missing'}
    [pscustomobject]@{Version=1;At=$at;SourceDn=$source;SourceScope=$sourceScope;Depth=$sourceDepth;AttemptAt=$attemptAt;Partial=$partial;Status=$status;DepthUnknown=$unknown;LegacyAt=$legacyAt;ClockInvalid=$clockInvalid;ScopeDn=$target;Subtree=$Subtree}
}

function Get-DomeniaOuObservationFreshness {
    # Count each active workstation once per measurement family; never replace a missing family date by AD/calculation time.
    param([object[]]$Presence=@(),[int]$Total=0,[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxDays=30)
    $families=@{Ping=@{};Inventory=@{}}
    foreach($item in $Presence){
        if($null -eq $item -or -not [bool](Get-DomeniaMember $item 'in_scope' $true)){continue}
        $observation=Get-DomeniaMemberValue $item 'observation';$key=([string](Get-DomeniaMember $item 'object_key')).Trim()
        if($null -eq $observation -or -not $key){continue}
        $pingText=[string](Get-DomeniaMember $observation 'PresenceCheckedUtc' '')
        $ping=ConvertFrom-DomeniaUtcText $pingText
        $state=[string](Get-DomeniaMember $observation 'Presence')
        $inventory=Get-DomeniaMemberValue $observation 'Inventory'
        $inventoryAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $inventory 'CheckedUtc'))
        foreach($name in @('Ping','Inventory')){
            $date=if($name -eq 'Ping'){$ping}else{$inventoryAt}
            if($null -eq $date -or $date -gt $NowUtc -or (Test-DomeniaObservationAge -CheckedUtc $date -NowUtc $NowUtc -MaxDays $MaxDays) -eq 'Expired'){continue}
            if($name -eq 'Ping' -and ($state -notmatch '^(En ligne|Sans r[eé]ponse(?: au ping)?|Hors ligne)$')){continue}
            $known=$families[$name]
            if(-not $known.ContainsKey($key) -or $date -gt $known[$key]){$known[$key]=$date}
        }
    }
    $result=[ordered]@{Version=1;Total=[Math]::Max(0,$Total)}
    foreach($name in @('Ping','Inventory')){
        $known=$families[$name];$oldest=$null;$newest=$null
        foreach($date in $known.Values){if($null -eq $oldest -or $date -lt $oldest){$oldest=$date};if($null -eq $newest -or $date -gt $newest){$newest=$date}}
        $result[$name]=[pscustomobject]@{Count=$known.Count;Total=$result.Total;Missing=[Math]::Max(0,$result.Total-$known.Count);OldestUtc=$oldest;NewestUtc=$newest}
    }
    return [pscustomobject]$result
}

function Format-DomeniaOuFreshnessSummary {
    # Three clocks, three labels. Newest measurement is never presented as the freshness of the entire OU.
    param($IndexFreshness,$Observations,$ComputedAtUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    $dateText={param($At) if($At -is [datetime]){return $At.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)};return ''}
    $at=Get-DomeniaMemberValue $IndexFreshness 'At'
    $base='Base locale (AD) : '
    if($at -is [datetime] -and $at -le $NowUtc){$base+='lecture complète le '+(& $dateText $at)+' ('+(Format-DomeniaAge -FromUtc $at -NowUtc $NowUtc)+')'}
    else{$base+='aucune lecture complète couvrant ce périmètre'}
    if([bool](Get-DomeniaMember $IndexFreshness 'Partial' $false)){$base+=' ; tentative incomplète le '+(& $dateText (Get-DomeniaMemberValue $IndexFreshness 'AttemptAt'))}
    if([bool](Get-DomeniaMember $IndexFreshness 'DepthUnknown' $false)){$base+=' ; profondeur de lecture historique inconnue, relire lʼOU'}
    if([bool](Get-DomeniaMember $IndexFreshness 'ClockInvalid' $false) -or ($at -is [datetime] -and $at -gt $NowUtc)){$base+=' ; date future ignorée, vérifier lʼhorloge'}
    $families=[Collections.Generic.List[string]]::new()
    foreach($name in @('Ping','Inventory')){
        $family=Get-DomeniaMemberValue $Observations $name
        $count=[int](Get-DomeniaMember $family 'Count' 0);$total=[int](Get-DomeniaMember $family 'Total' (Get-DomeniaMember $Observations 'Total' 0))
        $text=$(if($name -eq 'Ping'){'ping '}else{'inventaire WMI '})+$count+'/'+$total
        $oldest=Get-DomeniaMemberValue $family 'OldestUtc';$newest=Get-DomeniaMemberValue $family 'NewestUtc'
        if($count -gt 0 -and $oldest -is [datetime] -and $newest -is [datetime]){
            if($oldest -eq $newest){$text+=' (le '+(& $dateText $oldest)+')'}
            else{$text+=' (du '+(& $dateText $oldest)+' au '+(& $dateText $newest)+')'}
        }else{$text+=' (aucun relevé daté utilisable)'}
        $families.Add($text)
    }
    $computed=if($ComputedAtUtc -is [datetime] -and $ComputedAtUtc -le $NowUtc){'Vue recalculée le '+(& $dateText $ComputedAtUtc)+' ; aucune lecture AD ou poste pendant ce calcul.'}else{'Vue locale : date de calcul non disponible.'}
    [pscustomobject]@{BaseText=$base;ObservationsText=('Postes actifs : '+($families -join ' · '));ComputedText=$computed}
}

function Get-DomeniaFleetWmiResponse {
    # CIM/WMI answer of one workstation, kept apart from ICMP (point 72): console, light inventory and catalog probes
    # are CIM reads, each family with its own source dates. Responded: a CIM read succeeded within MaxDays and no CIM
    # attempt failed afterwards (a failure within 15 minutes of a success belongs to the same collection and does not
    # erase the answer). Failed: the latest dated CIM attempt within MaxDays failed. NotRead: no usable dated attempt.
    # A failure is never read as "switched off": access may be refused, the service stopped or the network filtered.
    # Called once per active workstation of the fleet: member reads stay inline, without helper calls.
    param($Observation,[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxDays=30)
    if($null -eq $Observation){return [pscustomobject]@{State='NotRead';At=$null;LastSuccessUtc=$null}}
    $v=@{}
    $names=@('Times','Inventory','InventoryCheckedUtc','InventoryError','InventoryAttemptUtc','Outcome','ConsoleCheckedUtc','UserCheckedUtc','ConsoleAttemptUtc')
    if($Observation -is [Collections.IDictionary]){foreach($name in $names){if($Observation.Contains($name)){$v[$name]=$Observation[$name]}}}
    else{$properties=$Observation.PSObject.Properties;foreach($name in $names){$property=$properties[$name];if($null -ne $property){$v[$name]=$property.Value}}}
    $events=[Collections.Generic.List[object]]::new()
    $times=$v['Times'];$families=@()
    if($times -is [Collections.IDictionary]){$families=@($times.Keys)}elseif($null -ne $times){$families=@($times.PSObject.Properties|ForEach-Object{$_.Name})}
    $families=@($families|Where-Object{[string]$_ -cne 'Presence'})
    if($families.Count){
        # Canonical projection: one record per persisted family with its last success and last attempt.
        foreach($family in $families){
            $time=if($times -is [Collections.IDictionary]){$times[$family]}else{$times.PSObject.Properties[[string]$family].Value}
            if($null -eq $time){continue}
            $read=@{};foreach($name in @('ObservedUtc','LastAttemptUtc','Succeeded')){if($time -is [Collections.IDictionary]){if($time.Contains($name)){$read[$name]=$time[$name]}}else{$property=$time.PSObject.Properties[$name];if($null -ne $property){$read[$name]=$property.Value}}}
            $events.Add(@([string]$read['ObservedUtc'],$true))
            if(-not [bool]$read['Succeeded']){$events.Add(@([string]$read['LastAttemptUtc'],$false))}
        }
    }else{
        # Older local observations: inventory dates and the console outcome carry the same facts.
        $inventory=$v['Inventory'];$inventoryAt=[string]$v['InventoryCheckedUtc']
        if((-not $inventoryAt) -and ($inventory -is [Collections.IDictionary])){if($inventory.Contains('CheckedUtc')){$inventoryAt=[string]$inventory['CheckedUtc']}}
        elseif((-not $inventoryAt) -and ($null -ne $inventory)){$property=$inventory.PSObject.Properties['CheckedUtc'];if($null -ne $property){$inventoryAt=[string]$property.Value}}
        if($null -ne $inventory){$events.Add(@($inventoryAt,$true))}
        if([string]$v['InventoryError']){$events.Add(@([string]$v['InventoryAttemptUtc'],$false))}
        $outcome=[string]$v['Outcome'];$consoleAt=[string]$v['ConsoleCheckedUtc'];if(-not $consoleAt){$consoleAt=[string]$v['UserCheckedUtc']}
        if($outcome -in @('Observed','NoConsole')){$events.Add(@($consoleAt,$true))}
        elseif($outcome -in @('Denied','AuthRejected','Timeout','Unavailable')){$attempt=[string]$v['ConsoleAttemptUtc'];if(-not $attempt){$attempt=$consoleAt};$events.Add(@($attempt,$false))}
    }
    # Same parsing as ConvertFrom-DomeniaUtcText; dates in the future or older than MaxDays are not usable.
    $culture=[Globalization.CultureInfo]::InvariantCulture;$styles=[Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    $newest=$NowUtc.AddMinutes(5);$oldest=$NowUtc.AddDays(0-[Math]::Max(1,$MaxDays))
    $success=$null;$failure=$null
    foreach($item in $events){
        $text=([string]$item[0]).Trim();if(-not $text){continue}
        $at=[datetime]::MinValue;if(-not [datetime]::TryParse($text,$culture,$styles,[ref]$at)){continue}
        if(($at -gt $newest) -or ($at -lt $oldest)){continue}
        if([bool]$item[1]){if(($null -eq $success) -or ($at -gt $success)){$success=$at}}
        elseif(($null -eq $failure) -or ($at -gt $failure)){$failure=$at}
    }
    if(($null -ne $failure) -and (($null -eq $success) -or ($failure -gt $success.AddMinutes(15)))){return [pscustomobject]@{State='Failed';At=$failure;LastSuccessUtc=$success}}
    if($null -ne $success){return [pscustomobject]@{State='Responded';At=$success;LastSuccessUtc=$success}}
    return [pscustomobject]@{State='NotRead';At=$null;LastSuccessUtc=$null}
}

function Get-DomeniaFleetReachLabel {
    # Ping and WMI side by side (point 72): neither channel decides alone whether a workstation is reachable.
    # $Presence: dashboard ping bucket (En ligne, Sans réponse, Non vérifié); $Wmi: Get-DomeniaFleetWmiResponse state.
    param([string]$Presence,[string]$Wmi)
    $ping=if($Presence -ceq 'En ligne'){'Yes'}elseif($Presence -ceq 'Sans réponse'){'No'}else{''}
    $cim=if($Wmi -ceq 'Responded'){'Yes'}elseif($Wmi -ceq 'Failed'){'No'}else{''}
    if(($ping -eq 'Yes') -and ($cim -eq 'Yes')){return 'Ping et WMI répondent'}
    if(($ping -eq 'No') -and ($cim -eq 'Yes')){return 'WMI répond, pas le ping'}
    if(($ping -eq 'Yes') -and ($cim -eq 'No')){return 'Ping répond, WMI non confirmé'}
    if(($ping -eq 'No') -and ($cim -eq 'No')){return 'Ni ping ni WMI'}
    if($ping -or $cim){return 'Un seul canal relevé'}
    return 'Aucun relevé'
}

function Get-DomeniaStaleTrendNote {
    # Point 71: every daily snapshot counted its inactive accounts with the threshold of its own day (StaleDays).
    # Returns '' when every drawn day used the current threshold, otherwise a short note giving how many days used
    # another threshold or did not keep it (snapshots older than this figure), so the curve never hides a rule change.
    param([object[]]$Figures=@(),[int]$StaleDays)
    $other=0;$unknown=0;$invariant=[Globalization.CultureInfo]::InvariantCulture
    foreach($item in @($Figures)){
        if($null -eq $item){continue}
        $raw=$null
        if($item -is [Collections.IDictionary]){if($item.Contains('StaleDays')){$raw=$item['StaleDays']}}
        else{$property=$item.PSObject.Properties['StaleDays'];if($null -ne $property){$raw=$property.Value}}
        $value=0
        if(($null -eq $raw) -or (-not [int]::TryParse([string]$raw,[Globalization.NumberStyles]::Integer,$invariant,[ref]$value))){$unknown++}
        elseif($value -ne $StaleDays){$other++}
    }
    $parts=@()
    if($other){$parts+=([string]$other+' jour(s) compté(s) avec un autre seuil')}
    if($unknown){$parts+=([string]$unknown+' jour(s) sans seuil conservé')}
    if(-not $parts.Count){return ''}
    return (' ; '+($parts -join ', ')+' : ces jours ne se comparent pas directement')
}
