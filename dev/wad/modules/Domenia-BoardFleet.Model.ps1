# Fleet board provider: dashboards made of widgets (decision David 2026-10-07). Turns the local index aggregates
# (FleetStats) and the cached presence and WMI observations into board entries. Pure rules: no WPF, no AD, no
# network, no script state (the caller keeps the returned Observations and Last).

function Get-DomeniaFleetBoardData {
    # Entries of the Fleet board for the OU chosen in Rechercher (empty scope = whole indexed domain; -Subtree:$false =
    # its direct children only). Throws the text shown by Fail-DomeniaFleetDashboard when the worker result cannot be
    # used, so the previous board stays on screen. Also returns Observations (lower-cased DN -> observation, every
    # cached row whatever its scope) and Last ({Scope; Subtree; Targets}: indexed workstations of the scope).
    param($Result,[string]$Scope = '',[bool]$Subtree = $true,[datetime]$Now = [datetime]::Now)
    $invariant = [Globalization.CultureInfo]::InvariantCulture

    # Last worker output carrying both aggregates (same rule as Get-DomeniaEffectiveWorkerResult).
    $source = $null
    foreach ($candidate in @($Result)) {
        if ($null -eq $candidate) { continue }
        if (($null -ne $candidate.PSObject.Properties['Types']) -and ($null -ne $candidate.PSObject.Properties['Machines'])) { $source = $candidate }
    }
    if ($null -eq $source) {
        # A locked base answers Busy without any aggregate.
        $locked = @(@($Result) | Where-Object { ($null -ne $_) -and ($null -ne $_.PSObject.Properties['Busy']) -and ([bool]$_.Busy) })
        if ($locked.Count) { throw 'base occupee, reessayez dans un instant.' }
        throw 'reponse incomplete.'
    }
    $busyProperty = $source.PSObject.Properties['Busy']
    if (($null -ne $busyProperty) -and ([bool]$busyProperty.Value)) { throw 'base occupee, reessayez dans un instant.' }

    $scope = ([string]$Scope).Trim()
    $data = New-DomeniaBoardData -Board Fleet
    # Same rule as the Rechercher list (Subtree or OneLevel) and the FleetStats worker: an empty scope accepts every DN.
    $inScope = {
        param([string]$Dn)
        if (-not $scope) { return $true }
        $text = ([string]$Dn).Trim()
        if (-not $text) { return $false }
        if (-not $Subtree) { return (($text -replace '^(?:[^,\\]|\\.)*,','') -ieq $scope) }
        if ($text -ieq $scope) { return $true }
        return $text.EndsWith(',' + $scope,[StringComparison]::OrdinalIgnoreCase)
    }
    # Fields of cached observations: older payloads miss some of them; read as empty, also under StrictMode.
    $field = {
        param($Object,[string]$Name)
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }
    $number = {
        param($Object,[string]$Name)
        $value = & $field $Object $Name
        $parsed = 0.0
        try { $parsed = [double]$value } catch { $parsed = 0.0 }
        return $parsed
    }
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

    # Indexed workstations of the scope.
    $machines = @(foreach ($machine in @($source.Machines)) { if (($null -ne $machine) -and (& $inScope ([string]$machine.distinguished_name))) { $machine } })
    $targets = @(foreach ($machine in $machines) { [pscustomobject]@{ name = [string]$machine.name; distinguished_name = [string]$machine.distinguished_name; object_guid = [string]$machine.object_guid } })
    $buckets = [ordered]@{ '<7j' = 0; '7-30j' = 0; '30-90j' = 0; '90-180j' = 0; '>180j' = 0; 'Jamais' = 0 }
    $osCounts = @{}; $sites = @{}; $stale = 0; $windows10 = 0
    foreach ($machine in $machines) {
        $os = ([string]$machine.extra -split ' / ')[0].Trim(); if (-not $os) { $os = 'Systeme non renseigne' }
        $os = $os -replace '^Microsoft ','' -replace 'Professionnel|Professional','Pro'
        $osCounts[$os] = 1 + [int]$osCounts[$os]
        if ($os -like 'Windows 10*') { $windows10++ }
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$machine.last_logon,'dd/MM/yyyy HH:mm:ss',$invariant,[Globalization.DateTimeStyles]::None,[ref]$date)) {
            $days = ($Now - $date).TotalDays
            $key = if ($days -lt 7) { '<7j' } elseif ($days -lt 30) { '7-30j' } elseif ($days -lt 90) { '30-90j' } elseif ($days -lt 180) { '90-180j' } else { '>180j' }
            $buckets[$key] = 1 + [int]$buckets[$key]
            if ($days -ge 90) { $stale++ }
        } else { $buckets['Jamais'] = 1 + [int]$buckets['Jamais'] }
        $dn = [string]$machine.distinguished_name
        $relative = if (($scope) -and ($dn.EndsWith(',' + $scope,[StringComparison]::OrdinalIgnoreCase))) { $dn.Substring(0,$dn.Length - $scope.Length - 1) } else { $dn }
        # Whole domain: the OU that holds the workstation; chosen OU: its direct sub-OU containing the workstation.
        $ous = @(@($relative -split '(?<!\\),') -like 'OU=*')
        # Wrapped in @(): an if statement used as a value unrolls a one-item array to a plain string.
        $site = @(if (($ous.Count -gt 0) -and ($scope)) { $ous[$ous.Count - 1] } elseif ($ous.Count -gt 0) { $ous[0] })
        $siteName = if ($site.Count) { ([string]$site[0]).Substring(3) } elseif ($scope) { '(directement dans l OU)' } else { 'Hors OU' }
        $sites[$siteName] = 1 + [int]$sites[$siteName]
    }

    # Live observations kept by the detections and analyses (presence, console user, light WMI inventory).
    $presence = @{ 'En ligne' = 0; 'Sans reponse' = 0; 'Non verifie' = 0 }
    $users = 0; $inventories = New-Object System.Collections.ArrayList; $lastCheck = [datetime]::MinValue
    $observations = @{}
    $presenceRows = @(if ($null -ne $source.PSObject.Properties['Presence']) { $source.Presence })
    foreach ($item in $presenceRows) {
        if ($null -eq $item) { continue }
        # The worker parses the payloads off the interface thread; older results still carry the raw payload.
        $observation = $null
        $parsed = $item.PSObject.Properties['observation']
        if ($null -ne $parsed) { $observation = $parsed.Value }
        else { try { $observation = ([string]$item.payload) | ConvertFrom-Json -ErrorAction Stop } catch { continue } }
        if ($null -eq $observation) { continue }
        $observations[([string]$item.object_key).ToLowerInvariant()] = $observation
        if (-not (& $inScope ([string]$item.object_key))) { continue }
        $state = [string](& $field $observation 'Presence')
        $key = if ($state -eq 'En ligne') { 'En ligne' } elseif ($state -match 'Sans|Erreur|Hors') { 'Sans reponse' } else { 'Non verifie' }
        $presence[$key] = 1 + [int]$presence[$key]
        if ([string](& $field $observation 'LinkUser')) { $users++ }
        $inventory = & $field $observation 'Inventory'
        if ($null -ne $inventory) { [void]$inventories.Add($inventory) }
        try { $checked = [datetime]::Parse([string]$item.checked_utc); if ($checked -gt $lastCheck) { $lastCheck = $checked } } catch { }
    }
    $observed = [int]$presence['En ligne'] + [int]$presence['Sans reponse'] + [int]$presence['Non verifie']
    $presence['Non verifie'] = [int]$presence['Non verifie'] + [Math]::Max(0,$machines.Count - $observed)

    # Points of attention (the WMI ones are added with their section).
    $neverLogged = [int]$buckets['Jamais']; $unreachable = [int]$presence['Sans reponse']
    if ($windows10) { Add-DomeniaBoardAttention -Data $data -Level Alert -Text ([string]$windows10 + ' poste(s) sous Windows 10, fin de support depuis le 14/10/2025.') }
    if ($stale) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$stale + ' poste(s) sans connexion au domaine depuis 90 jours ou plus : a verifier ou nettoyer.') }
    if ($neverLogged) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$neverLogged + ' compte(s) ordinateur jamais connecte(s).') }
    if ($unreachable) { Add-DomeniaBoardAttention -Data $data -Level Info -Text ([string]$unreachable + ' poste(s) sans reponse au dernier releve.') }

    # Inventaire du perimetre
    $activeUsers = 0
    foreach ($type in @($source.Types)) { if (($null -ne $type) -and ([string]$type.t -eq 'Utilisateur') -and ([string]$type.s -eq 'Actif')) { $activeUsers += [long]$type.n } }
    $links = 0
    $linksProperty = $source.PSObject.Properties['Links']
    if ($null -ne $linksProperty) { try { $links = [int]$linksProperty.Value } catch { $links = 0 } }
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.machines' -Kind Value -Value ([string]$machines.Count) -Detail $(if ($scope) { $(if ($Subtree) { 'dans l OU et ses sous-OU' } else { 'directement dans l OU' }) } else { [string]$activeUsers + ' utilisateurs actifs au total' }))
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.stale' -Kind Value -Value ([string]$stale) -State $(if ($stale) { 'Warn' } else { 'Ok' }) -Detail 'Derniere connexion au domaine : a verifier ou nettoyer')
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.win10' -Kind Value -Value ([string]$windows10) -State $(if ($windows10) { 'Alert' } else { 'Ok' }) -Detail 'Fin de support le 14/10/2025')
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.users' -Kind Value -Value ([string]$users) -Detail ([string]$links + ' associations au total'))
    Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.lastcheck' -Kind Value -Value $(if ($lastCheck -gt [datetime]::MinValue) { $lastCheck.ToLocalTime().ToString('dd/MM HH:mm',$invariant) } else { 'Aucune' }) -Detail ([string]$inventories.Count + ' postes avec releve WMI'))

    # Repartition
    $osRanked = @(& $rank $osCounts)
    $osItems = @($osRanked | Select-Object -First 6)
    $osOthers = 0.0
    foreach ($part in @($osRanked | Select-Object -Skip 6)) { $osOthers += [double]$part.Value }
    if ($osOthers -gt 0) { $osItems += [pscustomobject]@{ Label = 'Autres'; Value = $osOthers } }
    if ($osItems.Count) {
        $lead = & $share $osRanked $machines.Count
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.os' -Kind Distribution -Value $lead.Value -Detail $lead.Detail -Items $osItems -CenterText ([string]$machines.Count + ' postes'))
    }
    if ($machines.Count) {
        # Every bucket is kept, empty ones included: they show the distribution.
        $logonItems = @(foreach ($name in @($buckets.Keys)) { [pscustomobject]@{ Label = [string]$name; Value = [double]$buckets[$name] } })
        $lead = & $share $logonItems $machines.Count
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.lastlogon' -Kind Series -Value $lead.Value -Detail $lead.Detail -Items $logonItems)
    }
    $ouRanked = @(& $rank $sites)
    $ouItems = @($ouRanked | Select-Object -First 10)
    $ouOthers = 0.0
    foreach ($part in @($ouRanked | Select-Object -Skip 10)) { $ouOthers += [double]$part.Value }
    if ($ouOthers -gt 0) { $ouItems += [pscustomobject]@{ Label = 'Autres'; Value = $ouOthers } }
    if ($ouItems.Count) {
        $lead = & $share $ouRanked $machines.Count
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.ou' -Kind Distribution -Title $(if ($scope) { 'Postes par sous-OU' } else { '' }) -Value $lead.Value -Detail $lead.Detail -Items $ouItems -CenterText ([string]$machines.Count + ' postes'))
    }
    # Pastel meaning colours: online, no answer, not checked.
    $presenceColors = @{ 'En ligne' = 'Ok'; 'Sans reponse' = 'Warn'; 'Non verifie' = 'Off' }
    $presenceItems = @(foreach ($name in @('En ligne','Sans reponse','Non verifie')) { if ([int]$presence[$name] -gt 0) { [pscustomobject]@{ Label = $name; Value = [double]$presence[$name]; Color = (Get-DomeniaBoardColor -Name $presenceColors[$name]) } } })
    if ($presenceItems.Count) {
        $presenceTotal = [int]$presence['En ligne'] + [int]$presence['Sans reponse'] + [int]$presence['Non verifie']
        $lead = & $share $presenceItems $presenceTotal
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.presence' -Kind Distribution -Value $lead.Value -Detail $lead.Detail -Items $presenceItems -CenterText ([string]$presenceTotal + ' postes'))
    }
    if ((-not $machines.Count) -and (-not $presenceItems.Count)) {
        $data.Hints['Repartition'] = 'Aucun poste actif indexe dans ce perimetre : mettez a jour la base autonome (Outils, Base autonome, Mettre a jour tout).'
    }

    # Releves WMI
    if (-not $inventories.Count) {
        $data.Hints['Releves WMI'] = 'Dans Rechercher, Analyser la liste remplit cette section pour les postes affiches : modeles, memoire, disques, versions et demarrages.'
    } else {
        $models = @{}; $releases = @{}; $longUptime = 0; $lowDisk = 0; $bootSeen = 0
        $ram = [ordered]@{ '4 Go et -' = 0; '8 Go' = 0; '16 Go' = 0; '32 Go' = 0; '+ de 32 Go' = 0 }
        $disk = [ordered]@{ '< 10 %' = 0; '10-25 %' = 0; '25-50 %' = 0; '> 50 %' = 0 }
        $utcNow = $Now.ToUniversalTime()
        foreach ($inventory in $inventories) {
            $model = ([string](& $field $inventory 'Model')).Trim(); if (-not $model) { $model = 'Modele inconnu' }
            $models[$model] = 1 + [int]$models[$model]
            $gb = (& $number $inventory 'RamBytes') / 1GB
            $k = if ($gb -le 4.5) { '4 Go et -' } elseif ($gb -le 9) { '8 Go' } elseif ($gb -le 17) { '16 Go' } elseif ($gb -le 33) { '32 Go' } else { '+ de 32 Go' }
            if ($gb -gt 0) { $ram[$k] = 1 + [int]$ram[$k] }
            $size = & $number $inventory 'DiskSize'
            if ($size -gt 0) {
                $free = 100.0 * (& $number $inventory 'DiskFree') / $size
                $dk = if ($free -lt 10) { '< 10 %' } elseif ($free -lt 25) { '10-25 %' } elseif ($free -lt 50) { '25-50 %' } else { '> 50 %' }
                $disk[$dk] = 1 + [int]$disk[$dk]; if ($free -lt 10) { $lowDisk++ }
            }
            $build = ([string](& $field $inventory 'Build')).Trim()
            $release = (Get-DomeniaWindowsRelease -Build $build -Caption ([string](& $field $inventory 'OsCaption'))).Name
            if (-not $release) { $release = if ($build) { 'Build ' + $build } else { 'Version inconnue' } }
            $releases[$release] = 1 + [int]$releases[$release]
            $boot = & $field $inventory 'LastBootUtc'
            try {
                $bootUtc = if ($boot -is [datetime]) { $boot.ToUniversalTime() } else { [datetime]::Parse([string]$boot).ToUniversalTime() }
                $bootSeen++
                if (($utcNow - $bootUtc).TotalDays -gt 30) { $longUptime++ }
            } catch { }
        }
        $modelRanked = @(& $rank $models)
        $modelItems = @($modelRanked | Select-Object -First 8)
        $modelOthers = 0.0
        foreach ($part in @($modelRanked | Select-Object -Skip 8)) { $modelOthers += [double]$part.Value }
        if ($modelOthers -gt 0) { $modelItems += [pscustomobject]@{ Label = 'Autres'; Value = $modelOthers } }
        $lead = & $share $modelRanked $inventories.Count
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.models' -Kind Distribution -Value $lead.Value -Detail $lead.Detail -Items $modelItems -CenterText ([string]$inventories.Count + ' postes'))
        $releaseItems = @(& $rank $releases)
        $lead = & $share $releaseItems $inventories.Count
        Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.releases' -Kind Distribution -Value $lead.Value -Detail $lead.Detail -Items $releaseItems -CenterText ([string]$inventories.Count + ' postes'))
        $ramItems = @(foreach ($name in @($ram.Keys)) { [pscustomobject]@{ Label = [string]$name; Value = [double]$ram[$name] } })
        $ramTotal = 0.0; foreach ($part in $ramItems) { $ramTotal += [double]$part.Value }
        if ($ramTotal -gt 0) {
            $lead = & $share $ramItems $ramTotal
            Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.ram' -Kind Series -Value $lead.Value -Detail $lead.Detail -Items $ramItems)
        }
        $diskItems = @(foreach ($name in @($disk.Keys)) { [pscustomobject]@{ Label = [string]$name; Value = [double]$disk[$name] } })
        $diskTotal = 0.0; foreach ($part in $diskItems) { $diskTotal += [double]$part.Value }
        if ($diskTotal -gt 0) {
            $lead = & $share $diskItems $diskTotal
            Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.diskfree' -Kind Series -Value $lead.Value -Detail $lead.Detail -Items $diskItems)
            # Only when a disk size was read: a failed WMI probe stores DiskSize 0, which is no "0 full disk".
            Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.lowdisk' -Kind Value -Value ([string]$lowDisk) -State $(if ($lowDisk) { 'Alert' } else { 'Ok' }) -Detail 'Moins de 10 % libre')
        }
        # Only when a boot date was read (a failed probe stores LastBootUtc '').
        if ($bootSeen -gt 0) { Add-DomeniaBoardEntry $data (New-DomeniaBoardEntry -Key 'fleet.uptime' -Kind Value -Value ([string]$longUptime) -State $(if ($longUptime) { 'Warn' } else { 'Ok' }) -Detail 'Redemarrage conseille') }
        if ($lowDisk) { Add-DomeniaBoardAttention -Data $data -Level Alert -Text ([string]$lowDisk + ' poste(s) avec moins de 10 % libre sur C:.') }
        if ($longUptime) { Add-DomeniaBoardAttention -Data $data -Level Warn -Text ([string]$longUptime + ' poste(s) non redemarre(s) depuis plus de 30 jours.') }
    }

    $data.Summary = 'Base autonome locale et derniers releves : ' + [string]$machines.Count + ' postes actifs dans le perimetre, calcul du ' + $Now.ToString('dd/MM/yyyy HH:mm',$invariant) + '. Parc incomplet ? Outils, Base autonome, Mettre a jour tout.'
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Observations' -Value $observations
    Add-Member -InputObject $data -MemberType NoteProperty -Name 'Last' -Value ([pscustomobject]@{ Scope = $scope; Subtree = [bool]$Subtree; Targets = $targets })
    [void](Complete-DomeniaBoardData -Data $data)
    return $data
}
