# Workstation and software dashboards (decision David 2026-10-07). They only use data already read by the
# inventory and software workers: no extra request to the workstation.
function Clear-DomeniaDashboards {
    $script:LastComputerDashboardResult = $null
    foreach ($name in @('PnlComputerDashboard','PnlSoftwareDashboard')) { $panel = Get-DomeniaControl $name; if ($null -ne $panel) { $panel.Children.Clear() } }
    [void](Set-DomeniaControlText 'LblComputerDashboard' 'Lancez un inventaire (Rapide ou Complet) : le tableau de bord se remplit avec ses resultats.')
    [void](Set-DomeniaControlText 'LblSoftwareDashboard' 'Chargez les logiciels pour afficher la synthese.')
    Show-DomeniaComputerWidgetsOnly
}
function Show-DomeniaComputerWidgetsOnly {
    # Before any inventory the workstation dashboard still offers its widgets (Ajouter, Sonder).
    $panel = Get-DomeniaControl 'PnlComputerDashboard'
    if ($null -eq $panel) { return }
    $panel.Children.Clear()
    try { Add-DomeniaWidgetSection -Panel $panel -Board 'Computer' -OnChanged { Show-DomeniaComputerWidgetsOnly } } catch { }
}
function Format-DomeniaDashboardSize {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:0.#} To' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:0.#} Go' -f ($Bytes / 1GB)) }
    return ('{0:0} Mo' -f ($Bytes / 1MB))
}
function Get-DomeniaInventoryValue {
    param($Rows,[string]$Category,[string]$Item)
    foreach ($row in @($Rows)) { if ([string]$row.Category -eq $Category -and [string]$row.Item -eq $Item) { return [string]$row.Value } }
    return ''
}
function Get-DomeniaCategorySummary {
    # Items of one inventory category without its 'Etat' line; when empty, the 'Etat' text ("Aucun ...") is kept.
    param($Rows,[string]$Category)
    $items = @($Rows | Where-Object { [string]$_.Category -eq $Category -and [string]$_.Item -ne 'Etat' })
    $state = @($Rows | Where-Object { [string]$_.Category -eq $Category -and [string]$_.Item -eq 'Etat' } | Select-Object -First 1)
    return [pscustomobject]@{ Items = $items; Count = $items.Count; State = $(if ($state.Count) { [string]$state[0].Value } else { '' }); Read = ($items.Count -gt 0 -or $state.Count -gt 0) }
}
function New-DomeniaDashboardSection {
    param($Host_,[string]$Title)
    $section = New-Object System.Windows.Controls.StackPanel
    $section.Margin = [System.Windows.Thickness]::new(0,4,0,10)
    $header = New-DomeniaChartText -Text $Title -Size 15 -Bold -Key 'TextColor'
    $header.Margin = [System.Windows.Thickness]::new(6,0,0,4)
    [void]$section.Children.Add($header)
    $wrap = New-Object System.Windows.Controls.WrapPanel
    [void]$section.Children.Add($wrap)
    [void]$Host_.Children.Add($section)
    return $wrap
}
function Get-DomeniaWindowsRelease {
    # Release name from the build number. Only Windows 10 carries an end-of-support note (14/10/2025).
    param([string]$Build)
    $names = @{ '26200'='Windows 11 25H2'; '26100'='Windows 11 24H2'; '22631'='Windows 11 23H2'; '22621'='Windows 11 22H2'; '22000'='Windows 11 21H2'; '19045'='Windows 10 22H2'; '19044'='Windows 10 21H2'; '19043'='Windows 10 21H1' }
    $name = [string]$names[([string]$Build).Trim()]
    $note = if ($name -like 'Windows 10*') { 'Fin de support le 14/10/2025 : a migrer' } elseif ($name) { 'Build ' + $Build } else { '' }
    return [pscustomobject]@{ Name = $name; Note = $note }
}
function Get-DomeniaEntryFileTimeUtc {
    # AD large integer (pwdLastSet, lastLogonTimestamp, LAPS expiration) or date, as UTC; $null when absent.
    param($Entry,[string]$Name)
    $raw = $null; try { $raw = Get-DeProp $Entry $Name $null } catch { return $null }
    if ($null -eq $raw -or [string]$raw -eq '') { return $null }
    if ($raw -is [datetime]) { return $raw.ToUniversalTime() }
    $ticks = $null
    try { $ticks = ConvertFrom-DomeniaLargeInteger $raw } catch { }
    if ($null -eq $ticks) { $parsed = 0L; if ([long]::TryParse([string]$raw,[ref]$parsed)) { $ticks = $parsed } }
    if ($null -eq $ticks -or $ticks -le 0 -or $ticks -eq [long]::MaxValue) { return $null }
    try { return [datetime]::FromFileTimeUtc($ticks) } catch { return $null }
}
function Add-DomeniaComputerAdSection {
    param($Panel,$Metrics)
    $object = $script:SelectedObject
    if ($null -eq $object -or $null -eq $object.Entry) { return }
    $entry = $object.Entry
    $wrap = New-DomeniaDashboardSection $Panel 'Compte machine dans Active Directory'
    $ageText = { param($Date) if ($null -eq $Date) { return '' }; $days = [int]([datetime]::UtcNow - $Date).TotalDays; return ('il y a ' + $days + ' j') }
    $pwd = Get-DomeniaEntryFileTimeUtc $entry 'pwdLastSet'
    if ($null -ne $pwd) {
        $days = [int]([datetime]::UtcNow - $pwd).TotalDays
        [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Mot de passe machine' -Value (& $ageText $pwd) -Detail $(if ($days -gt 45) { 'Plus de 45 jours : relation d approbation a verifier' } else { 'Renouvele le ' + $pwd.ToLocalTime().ToString('dd/MM/yyyy') })))
    }
    $logon = Get-DomeniaEntryFileTimeUtc $entry 'lastLogonTimestamp'
    if ($null -ne $logon) {
        $days = [int]([datetime]::UtcNow - $logon).TotalDays
        [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Derniere connexion au domaine' -Value (& $ageText $logon) -Detail $(if ($days -gt 90) { 'Plus de 90 jours : poste peut-etre inactif' } else { $logon.ToLocalTime().ToString('dd/MM/yyyy') + ' (replique a 14 j pres)' })))
    }
    $uac = 0; [void][int]::TryParse((Get-DomeniaEntryFirstString $entry 'userAccountControl'),[ref]$uac)
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Compte ordinateur' -Value $(if ($uac -band 2) { 'Desactive' } else { 'Actif' }) -Detail ('Cree le ' + $(try { ([datetime](Get-DomeniaEntryFirstString $entry 'whenCreated')).ToLocalTime().ToString('dd/MM/yyyy') } catch { 'date inconnue' }))))
    $dn = [string]$object.DN
    $ou = @($dn -split '(?<!\\),' | Where-Object { $_ -like 'OU=*' } | Select-Object -First 2 | ForEach-Object { $_.Substring(3) })
    if ($ou.Count) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Unite d organisation' -Value $ou[0] -Detail $(if ($ou.Count -gt 1) { 'dans ' + $ou[1] } else { '' }))) }
    $laps = Get-DomeniaEntryFileTimeUtc $entry 'msLAPS-PasswordExpirationTime'
    if ($null -eq $laps) { $laps = Get-DomeniaEntryFileTimeUtc $entry 'ms-Mcs-AdmPwdExpirationTime' }
    if ($null -ne $laps) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Mot de passe LAPS' -Value $(if ($laps -lt [datetime]::UtcNow) { 'Expire' } else { 'Valide' }) -Detail ('Expiration le ' + $laps.ToLocalTime().ToString('dd/MM/yyyy HH:mm')))) }
    $manager = Get-DomeniaEntryFirstString $entry 'managedBy'
    if ($manager) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Gere par' -Value (($manager -split '(?<!\\),')[0] -replace '^CN=','') -Detail 'Attribut managedBy')) }
    if ($null -ne $Metrics -and $null -ne $Metrics.ClockSkewSeconds) {
        $skew = [int]$Metrics.ClockSkewSeconds
        [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Horloge du poste' -Value $(if ([Math]::Abs($skew) -lt 2) { 'A l heure' } else { ('{0:+0;-0} s' -f $skew) }) -Detail $(if ([Math]::Abs($skew) -gt 300) { 'Plus de 5 min : Kerberos refusera l authentification' } else { 'Ecart avec ce poste d administration' })))
    }
}
function Start-DomeniaFleetDashboard {
    # Home dashboard (decision David 2026-10-07): aggregates of the local index, read in the background.
    param([switch]$Quiet)
    $path = [string]$script:DatabaseScopedPath
    if (-not $path) { if (-not $Quiet) { Set-Status 'Aucune base autonome active : vue d ensemble indisponible.' 'WARN' }; return }
    [void](Initialize-DomeniaWinSqliteNative)
    $job = Start-UiTask -Name 'Vue d ensemble du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{ Action='FleetStats'; Path=$path; BusyTimeoutMs=250 }) -CallbackState ([pscustomobject]@{ Path=$path; Epoch=[long]$script:SessionEpoch }) -SuccessHandler 'Complete-DomeniaFleetDashboard' -ErrorHandler 'Fail-DomeniaFleetDashboard' -TimeoutSeconds 60 -TaskClass 'Explicit'
    if ($job) { [void](Set-DomeniaControlText 'LblFleetDashboard' 'Calcul de la vue d ensemble depuis la base locale...') }
}
function Fail-DomeniaFleetDashboard {
    param($Message,$State)
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue d ensemble non calculee : ' + [string]$Message))
}
function Get-DomeniaFleetScope {
    return ([string](Get-DomeniaSetting 'FleetScopeDn' '')).Trim()
}
function Select-DomeniaFleetScope {
    # Starting OU of the home dashboard and of its analyses (decision David 2026-10-07), remembered between sessions.
    param([switch]$Reset)
    if ($Reset) { Set-DomeniaSetting 'FleetScopeDn' '' }
    else {
        $picked = Show-DomeniaInlinePicker -Kind OU -Title 'Perimetre du tableau de bord' -Prompt 'Choisissez l OU de depart : les statistiques et les analyses se limitent a ses postes.'
        if ($null -eq $picked -or -not [string]$picked.DN) { return }
        Set-DomeniaSetting 'FleetScopeDn' ([string]$picked.DN)
    }
    try { Save-DomeniaSettings -Immediate } catch { }
    Start-DomeniaFleetDashboard
}
function Start-DomeniaFleetAction {
    # Ping, detection or light WMI analysis of the indexed workstations of the chosen OU; never the whole domain.
    param([ValidateSet('Ping','Detect','Analyze')][string]$Mode)
    try {
        $scope = Get-DomeniaFleetScope
        if (-not $scope -or $scope -ieq [string]$script:Conn.BaseDn) { throw 'choisissez d abord une OU : aucune analyse sur le domaine entier.' }
        if ($null -eq $script:FleetLast -or [string]$script:FleetLast.Scope -cne $scope) { throw 'actualisez d abord la vue d ensemble de cette OU.' }
        $targets = @($script:FleetLast.Targets)
        if (-not $targets.Count) { throw 'aucun poste indexe dans cette OU. Mettez a jour la base autonome.' }
        $label = (($scope -split '(?<!\\),')[0] -replace '^OU=','')
        switch ($Mode) {
            'Ping'    { Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label -PingOnly }
            'Detect'  { Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label }
            'Analyze' { Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label -Inventory }
        }
    } catch { Set-Status ('Analyse impossible : ' + $_.Exception.Message) 'WARN' }
}
function Complete-DomeniaFleetDashboard {
    param($Result,$State)
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    $panel = Get-DomeniaControl 'PnlFleetDashboard'
    if ($null -eq $panel) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('Types','Machines')
    if ($null -eq $data) { Fail-DomeniaFleetDashboard 'reponse incomplete.' $State; return }
    if ([bool]$data.Busy) { Fail-DomeniaFleetDashboard 'base occupee, reessayez dans un instant.' $State; return }
    $panel.Children.Clear()
    $script:FleetLastResult = $Result
    $scope = Get-DomeniaFleetScope
    $scopeLabel = if ($scope) { $scope } else { 'Tout le domaine indexe' }
    [void](Set-DomeniaControlText 'TxtFleetScope' $scopeLabel)
    $inScope = { param([string]$Dn) Test-DomeniaLiveRowInScope -Dn $Dn -BaseDn $scope -Scope 'Subtree' }
    $machines = @(@($data.Machines) | Where-Object { & $inScope ([string]$_.distinguished_name) })
    $script:FleetLast = [pscustomobject]@{ Scope = $scope; Targets = @($machines | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; distinguished_name = [string]$_.distinguished_name; object_guid = [string]$_.object_guid } }) }
    $now = [datetime]::Now
    $buckets = [ordered]@{ '<7j'=0; '7-30j'=0; '30-90j'=0; '90-180j'=0; '>180j'=0; 'Jamais'=0 }
    $osCounts = @{}; $sites = @{}; $stale = 0; $windows10 = 0
    foreach ($machine in $machines) {
        $os = ([string]$machine.extra -split ' / ')[0].Trim(); if (-not $os) { $os = 'Systeme non renseigne' }
        $os = $os -replace '^Microsoft ','' -replace 'Professionnel|Professional','Pro'
        $osCounts[$os] = 1 + [int]$osCounts[$os]
        if ($os -like 'Windows 10*') { $windows10++ }
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$machine.last_logon,'dd/MM/yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) {
            $days = ($now - $date).TotalDays
            $key = if ($days -lt 7) { '<7j' } elseif ($days -lt 30) { '7-30j' } elseif ($days -lt 90) { '30-90j' } elseif ($days -lt 180) { '90-180j' } else { '>180j' }
            $buckets[$key] = 1 + [int]$buckets[$key]
            if ($days -ge 90) { $stale++ }
        } else { $buckets['Jamais'] = 1 + [int]$buckets['Jamais'] }
        $relative = if ($scope -and ([string]$machine.distinguished_name).EndsWith(',' + $scope,[StringComparison]::OrdinalIgnoreCase)) { ([string]$machine.distinguished_name).Substring(0,([string]$machine.distinguished_name).Length - $scope.Length - 1) } else { [string]$machine.distinguished_name }
        $site = @(($relative -split '(?<!\\),') | Where-Object { $_ -like 'OU=*' } | Select-Object -Last 1)
        $siteName = if ($site.Count) { $site[0].Substring(3) } else { $(if ($scope) { '(directement dans l OU)' } else { 'Hors OU' }) }
        $sites[$siteName] = 1 + [int]$sites[$siteName]
    }
    # Live observations kept by the detections and analyses (presence, console user, light WMI inventory).
    $presence = @{ 'En ligne'=0; 'Sans reponse'=0; 'Non verifie'=0 }; $users = 0; $inventories = New-Object Collections.ArrayList; $lastCheck = [datetime]::MinValue
    $script:FleetObservations = @{}
    foreach ($item in @($data.Presence)) {
        try { $observation = ([string]$item.payload) | ConvertFrom-Json } catch { continue }
        $script:FleetObservations[([string]$item.object_key).ToLowerInvariant()] = $observation
        if (-not (& $inScope ([string]$item.object_key))) { continue }
        $presenceState = [string]$observation.Presence
        $key = if ($presenceState -eq 'En ligne') { 'En ligne' } elseif ($presenceState -match 'Sans|Erreur|Hors') { 'Sans reponse' } else { 'Non verifie' }
        $presence[$key] = 1 + [int]$presence[$key]
        if ([string]$observation.LinkUser) { $users++ }
        if ($null -ne $observation.Inventory) { [void]$inventories.Add($observation.Inventory) }
        try { $checked = [datetime]::Parse([string]$item.checked_utc); if ($checked -gt $lastCheck) { $lastCheck = $checked } } catch { }
    }
    $observed = [int]$presence['En ligne'] + [int]$presence['Sans reponse'] + [int]$presence['Non verifie']
    $presence['Non verifie'] = [int]$presence['Non verifie'] + [Math]::Max(0,$machines.Count - $observed)

    $wrap = New-DomeniaDashboardSection $panel 'Inventaire du perimetre'
    $count = { param([string]$Type) @($data.Types | Where-Object { [string]$_.t -eq $Type -and [string]$_.s -eq 'Actif' } | Measure-Object -Property n -Sum).Sum }
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Postes actifs' -Value ([string]$machines.Count) -Detail $(if ($scope) { 'dans l OU choisie' } else { [string](& $count 'Utilisateur') + ' utilisateurs actifs au total' })))
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Postes inactifs (90 j et plus)' -Value ([string]$stale) -Detail 'Derniere connexion au domaine : a verifier ou nettoyer'))
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Postes sous Windows 10' -Value ([string]$windows10) -Detail 'Fin de support le 14/10/2025'))
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Utilisateurs detectes' -Value ([string]$users) -Detail ([string][int]$data.Links + ' associations au total')))
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Derniere analyse' -Value $(if ($lastCheck -gt [datetime]::MinValue) { $lastCheck.ToLocalTime().ToString('dd/MM HH:mm') } else { 'Aucune' }) -Detail ([string]$inventories.Count + ' postes avec releve WMI')))

    $wrap = New-DomeniaDashboardSection $panel 'Repartition'
    $osItems = @($osCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [double]$_.Value } })
    $osOthers = 0; foreach ($entry in @($osCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -Skip 6)) { $osOthers += [int]$entry.Value }
    if ($osOthers -gt 0) { $osItems += [pscustomobject]@{ Label = 'Autres'; Value = [double]$osOthers } }
    [void]$wrap.Children.Add((New-DomeniaDonutChart -Title 'Systemes d exploitation (AD)' -CenterText ([string]$machines.Count) -Items $osItems -Width 420))
    [void]$wrap.Children.Add((New-DomeniaColumnChart -Title 'Derniere connexion au domaine' -Items @($buckets.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [double]$_.Value } }) -Width 460))
    [void]$wrap.Children.Add((New-DomeniaBarChart -Title $(if ($scope) { 'Postes par sous-OU' } else { 'Postes par unite d organisation' }) -Items @($sites.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [double]$_.Value } }) -Width 460))
    [void]$wrap.Children.Add((New-DomeniaDonutChart -Title 'Presence reseau (derniers releves)' -Items @(foreach ($k in @('En ligne','Sans reponse','Non verifie')) { if ([int]$presence[$k] -gt 0) { [pscustomobject]@{ Label = $k; Value = [double]$presence[$k] } } }) -Width 420))

    $wrap = New-DomeniaDashboardSection $panel 'Releves WMI (Analyser l OU)'
    if (-not $inventories.Count) {
        [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Aucun releve WMI' -Value 'Analyser l OU' -Detail 'Modeles, memoire, disques, versions et demarrages apparaissent ici'))
    } else {
        $models = @($inventories | Group-Object { $m = ([string]$_.Model).Trim(); if ($m) { $m } else { 'Modele inconnu' } } | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double]$_.Count } })
        [void]$wrap.Children.Add((New-DomeniaBarChart -Title 'Modeles' -Items $models -Width 460))
        $ram = [ordered]@{ '4 Go et -'=0; '8 Go'=0; '16 Go'=0; '32 Go'=0; '+ de 32 Go'=0 }
        $disk = [ordered]@{ '< 10 %'=0; '10-25 %'=0; '25-50 %'=0; '> 50 %'=0 }
        $releases = @{}; $longUptime = 0; $lowDisk = 0
        foreach ($inventory in $inventories) {
            $gb = [double]$inventory.RamBytes / 1GB
            $k = if ($gb -le 4.5) { '4 Go et -' } elseif ($gb -le 9) { '8 Go' } elseif ($gb -le 17) { '16 Go' } elseif ($gb -le 33) { '32 Go' } else { '+ de 32 Go' }
            if ($gb -gt 0) { $ram[$k] = 1 + [int]$ram[$k] }
            if ([double]$inventory.DiskSize -gt 0) {
                $free = 100.0 * [double]$inventory.DiskFree / [double]$inventory.DiskSize
                $dk = if ($free -lt 10) { '< 10 %' } elseif ($free -lt 25) { '10-25 %' } elseif ($free -lt 50) { '25-50 %' } else { '> 50 %' }
                $disk[$dk] = 1 + [int]$disk[$dk]; if ($free -lt 10) { $lowDisk++ }
            }
            $release = (Get-DomeniaWindowsRelease ([string]$inventory.Build)).Name; if (-not $release) { $release = 'Build ' + [string]$inventory.Build }
            $releases[$release] = 1 + [int]$releases[$release]
            try { if (([datetime]::UtcNow - [datetime]::Parse([string]$inventory.LastBootUtc).ToUniversalTime()).TotalDays -gt 30) { $longUptime++ } } catch { }
        }
        [void]$wrap.Children.Add((New-DomeniaDonutChart -Title 'Versions de Windows (releve)' -Items @($releases.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [double]$_.Value } }) -Width 420))
        [void]$wrap.Children.Add((New-DomeniaColumnChart -Title 'Memoire installee' -Items @($ram.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [double]$_.Value } }) -Width 420))
        [void]$wrap.Children.Add((New-DomeniaColumnChart -Title 'Espace libre sur C:' -Items @($disk.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [double]$_.Value } }) -Width 420))
        [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Disque C: presque plein' -Value ([string]$lowDisk) -Detail 'Moins de 10 % libre'))
        [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Non redemarres depuis 30 j' -Value ([string]$longUptime) -Detail 'Redemarrage conseille'))
    }
    try { Add-DomeniaWidgetSection -Panel $panel -Board 'Fleet' -OnChanged { if ($null -ne $script:FleetLastResult) { Complete-DomeniaFleetDashboard -Result $script:FleetLastResult -State $null } } } catch { Add-DomeniaUiLog -Area 'Tableau de bord' -Level 'WARN' -Text ('Widgets du parc non affiches : ' + $_.Exception.Message) }
    if ($null -ne $script:LastComputerDashboardResult) { try { Update-DomeniaComputerDashboard -Result $script:LastComputerDashboardResult } catch { } }
    elseif ($null -ne $script:SelectedObject) { Show-DomeniaComputerWidgetsOnly }
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Base autonome locale et derniers releves : ' + $machines.Count + ' postes actifs dans le perimetre, calcul du ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '. Parc incomplet ? Outils, Base autonome, Mettre a jour tout.'))
}
function Update-DomeniaComputerDashboard {
    param($Result)
    $panel = Get-DomeniaControl 'PnlComputerDashboard'
    if ($null -eq $panel) { return }
    $panel.Children.Clear()
    $script:LastComputerDashboardResult = $Result
    $rows = @($Result.Rows); $metrics = $Result.Metrics
    $value = { param([string]$Category,[string]$Item) Get-DomeniaInventoryValue $rows $Category $Item }
    $firstLike = { param([string]$Category,[string]$Suffix) foreach ($row in $rows) { if ([string]$row.Category -eq $Category -and ([string]$row.Item).EndsWith($Suffix)) { return [string]$row.Value } }; return '' }

    # Identity
    $wrap = New-DomeniaDashboardSection $panel 'Identite du poste'
    $osName = & $value 'Systeme d exploitation' 'Nom'
    $build = (& $value 'Systeme d exploitation' 'Build'); if (-not $build) { $build = ((& $value 'Systeme d exploitation' 'Version') -split '\.')[-1] }
    $release = Get-DomeniaWindowsRelease $build
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Systeme' -Value $(if ($release.Name) { $release.Name } elseif ($osName) { $osName -replace '^Microsoft ','' } else { 'Non lu' }) -Detail $(if ($release.Note) { $release.Note } else { (($osName -replace '^Microsoft ','') + ' · build ' + $build).Trim(' ','·') })))
    $model = & $value 'Systeme' 'Modele'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Modele' -Value $(if ($model) { $model } else { 'Non lu' }) -Detail ((& $value 'Systeme' 'Fabricant') + ' · serie ' + (& $value 'Systeme' 'Numero de serie chassis')).Trim(' ','·')))
    $cpu = & $firstLike 'Processeur' ' modele'
    $cores = & $firstLike 'Processeur' ' coeurs'; $threads = & $firstLike 'Processeur' ' processeurs logiques'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Processeur' -Value $(if ($cpu) { ($cpu -replace '\(R\)|\(TM\)|CPU','' -replace '\s+',' ').Trim() } else { 'Non lu' }) -Detail $(if ($cores) { $cores + ' coeurs, ' + $threads + ' threads' } else { '' })))
    $modules = @($rows | Where-Object { [string]$_.Category -eq 'Memoire' -and ([string]$_.Item).StartsWith('Barrette') }).Count
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Memoire installee' -Value $(if ($null -ne $metrics -and [double]$metrics.MemoryTotal -gt 0) { Format-DomeniaDashboardSize $metrics.MemoryTotal } else { & $value 'Memoire' 'Total installe' }) -Detail $(if ($modules) { [string]$modules + ' barrette(s)' } else { '' })))
    $uptime = & $value 'Systeme d exploitation' 'Duree de fonctionnement'
    $uptimeDays = 0; if ($uptime -match '^(\d+) j') { $uptimeDays = [int]$Matches[1] }
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'En service depuis' -Value $(if ($uptime) { $uptime } else { 'Non lu' }) -Detail $(if ($uptimeDays -gt 30) { 'Plus de 30 jours : redemarrage conseille' } else { 'Demarre le ' + (& $value 'Systeme d exploitation' 'Dernier demarrage') })))
    $user = & $value 'Systeme' 'Utilisateur connecte'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Utilisateur connecte' -Value $(if ($user) { $user } else { 'Aucun' }) -Detail 'Console, au moment de l inventaire'))
    $ip = & $firstLike 'Reseau' ' adresses IP'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Adresse IP' -Value $(if ($ip) { ($ip -split '[,; ]+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1) } else { 'Non lue' }) -Detail ('Passerelle ' + (& $firstLike 'Reseau' ' passerelle'))))
    $domain = & $value 'Systeme' 'Domaine'
    if ($domain) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Domaine' -Value $domain -Detail (& $value 'Systeme' 'Role dans le domaine'))) }

    # Active Directory: health of the computer account (attributes already read with the object card).
    Add-DomeniaComputerAdSection $panel $metrics

    # Resources
    $wrap = New-DomeniaDashboardSection $panel 'Ressources'
    if ($null -ne $metrics -and [double]$metrics.MemoryTotal -gt 0) {
        $used = [Math]::Max(0.0,[double]$metrics.MemoryTotal - [double]$metrics.MemoryFree)
        [void]$wrap.Children.Add((New-DomeniaGauge -Title ('Memoire utilisee sur ' + (Format-DomeniaDashboardSize $metrics.MemoryTotal)) -Value ([Math]::Round($used / 1GB,1)) -Maximum ([Math]::Round([double]$metrics.MemoryTotal / 1GB,1)) -Unit 'Go'))
    }
    if ($null -ne $metrics -and [double]$metrics.CpuLoad -ge 0) { [void]$wrap.Children.Add((New-DomeniaGauge -Title 'Charge du processeur' -Value ([double]$metrics.CpuLoad) -Maximum 100 -Unit '%')) }
    if ($null -ne $metrics -and [double]$metrics.Battery -ge 0) { [void]$wrap.Children.Add((New-DomeniaGauge -Title 'Batterie' -Value ([double]$metrics.Battery) -Maximum 100 -Unit '%' -LowIsBad)) }
    foreach ($disk in @(@($metrics.Disks) | Where-Object { $null -ne $_ -and [double]$_.Size -gt 0 } | Select-Object -First 4)) {
        $free = [double]$disk.Free; $used = [Math]::Max(0.0,[double]$disk.Size - $free)
        $percent = [Math]::Round(100.0 * $free / [double]$disk.Size)
        [void]$wrap.Children.Add((New-DomeniaDonutChart -Title ('Disque ' + [string]$disk.Name + ' (' + (Format-DomeniaDashboardSize $disk.Size) + ')') -CenterText ([string]$percent + ' % libre') -Items @(
            [pscustomobject]@{ Label = ('Utilise ' + (Format-DomeniaDashboardSize $used)); Value = $used },
            [pscustomobject]@{ Label = ('Libre ' + (Format-DomeniaDashboardSize $free)); Value = $free })))
    }

    # Activity
    $wrap = New-DomeniaDashboardSection $panel 'Activite'
    if ($null -ne $metrics -and $null -ne $metrics.Services -and $metrics.Services.Count) {
        $ring = @(foreach ($key in @('En cours','Arretes (automatiques)','Arretes (manuels)','Desactives')) { if ([int]$metrics.Services[$key] -gt 0) { [pscustomobject]@{ Label = $key; Value = [double]$metrics.Services[$key] } } })
        $total = 0; foreach ($item in $ring) { $total += [int]$item.Value }
        [void]$wrap.Children.Add((New-DomeniaDonutChart -Title 'Services Windows' -CenterText ([string]$total) -Items $ring -Width 380))
    }
    if ($null -ne $metrics -and @($metrics.Processes).Count) {
        $top = @(@($metrics.Processes) | Group-Object Name | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double](($_.Group | Measure-Object -Property Mb -Sum).Sum) } } | Sort-Object Value -Descending | Select-Object -First 8)
        [void]$wrap.Children.Add((New-DomeniaBarChart -Title 'Processus les plus gourmands (Mo)' -Items $top -Unit ' Mo' -Width 520))
    }
    $events = Get-DomeniaCategorySummary $rows 'Evenements systeme'
    if ($events.Count) {
        $sources = @($events.Items | Group-Object { ([string]$_.Item -replace ' ID \d+$','') } | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double]$_.Count } })
        [void]$wrap.Children.Add((New-DomeniaBarChart -Title 'Erreurs systeme par source (3 jours)' -Items $sources -Width 420))
    }
    if (-not $wrap.Children.Count) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Activite' -Value 'Inventaire complet requis' -Detail 'Correctifs, processus et evenements')) }

    # Security and state
    $wrap = New-DomeniaDashboardSection $panel 'Securite et etat'
    $tile = {
        param([string]$Title,[string]$Category,[string]$WhenEmpty,[string]$Hint)
        $summary = Get-DomeniaCategorySummary $rows $Category
        if (-not $summary.Read) { return }
        $detail = if ($summary.Count) { [string]$summary.Items[0].Item } elseif ($summary.State) { $summary.State } else { $Hint }
        [void]$wrap.Children.Add((New-DomeniaKpiTile -Title $Title -Value $(if ($summary.Count) { [string]$summary.Count } else { $WhenEmpty }) -Detail $detail))
    }
    $av = Get-DomeniaCategorySummary $rows 'Antivirus'
    if ($av.Count) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Antivirus' -Value ([string]$av.Items[0].Item) -Detail ([string]$av.Items[0].Value))) }
    $firewall = Get-DomeniaCategorySummary $rows 'Pare-feu'
    if ($firewall.Count) { $on = @($firewall.Items | Where-Object { [string]$_.Value -match '(?i)actif|active|on' -and [string]$_.Value -notmatch '(?i)inactif|desactiv' }).Count; [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Pare-feu' -Value ([string]$on + ' / ' + $firewall.Count + ' profils actifs') -Detail (@($firewall.Items | ForEach-Object { [string]$_.Item + ' : ' + [string]$_.Value }) -join ' · '))) }
    $bitlocker = @($rows | Where-Object { [string]$_.Category -eq 'BitLocker' -and -not ([string]$_.Item).EndsWith(' methode') -and [string]$_.Item -ne 'Etat' })
    if ($bitlocker.Count) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'BitLocker' -Value ([string]$bitlocker[0].Value) -Detail ([string]$bitlocker[0].Item))) }
    $wsus = & $value 'Windows Update' 'Serveur WSUS'
    if ($wsus) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Windows Update' -Value 'WSUS' -Detail $wsus)) }
    $reboot = & $value 'Redemarrage en attente' 'Etat'
    $rebootItems = Get-DomeniaCategorySummary $rows 'Redemarrage en attente'
    if ($rebootItems.Read) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Redemarrage en attente' -Value $(if ($rebootItems.Count) { 'Oui' } else { 'Non' }) -Detail $(if ($rebootItems.Count) { [string]$rebootItems.Items[0].Item } else { $reboot }))) }
    & $tile 'Services automatiques arretes' 'Services en defaut' '0' 'Aucun'
    & $tile 'Peripheriques en erreur' 'Peripheriques en erreur' '0' 'Aucun'
    & $tile 'Pilotes non signes' 'Pilotes non signes' '0' 'Aucun'
    & $tile 'Administrateurs locaux' 'Administrateurs locaux' '0' 'Groupe non lu'
    & $tile 'Sessions et comptes locaux' 'Comptes et sessions' '0' 'Aucune'
    & $tile 'Demarrage automatique' 'Demarrage automatique' '0' 'Aucun programme'
    & $tile 'Partages' 'Partages' '0' 'Aucun partage'
    & $tile 'Imprimantes' 'Imprimantes' '0' 'Aucune'
    $display = Get-DomeniaCategorySummary $rows 'Affichage'
    if ($display.Count) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Affichage' -Value ([string]$display.Items[0].Item) -Detail ([string]$display.Items[0].Value))) }
    $physical = Get-DomeniaCategorySummary $rows 'Disques physiques'
    if ($physical.Count) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Disque physique' -Value ([string]$physical.Items[0].Item) -Detail ([string]$physical.Items[0].Value))) }
    & $tile 'Certificats machine' 'Certificats machine' '0' 'Aucun'
    if ($null -ne $metrics -and @($metrics.Hotfixes).Count) {
        $latest = @($metrics.Hotfixes | Sort-Object -Descending)[0]; $date = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$latest,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) {
            $age = [int]([datetime]::Today - $date).TotalDays
            [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Dernier correctif' -Value ('il y a ' + $age + ' j') -Detail ($date.ToString('dd/MM/yyyy') + ' · ' + @($metrics.Hotfixes).Count + ' correctifs')))
        }
    }

    try { Add-DomeniaWidgetSection -Panel $panel -Board 'Computer' -OnChanged { if ($null -ne $script:LastComputerDashboardResult) { Update-DomeniaComputerDashboard -Result $script:LastComputerDashboardResult } } } catch { Add-DomeniaUiLog -Area 'Tableau de bord' -Level 'WARN' -Text ('Widgets du poste non affiches : ' + $_.Exception.Message) }
    $text = 'Tableau de bord de l inventaire du ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '. ' + $(if ($null -eq $metrics) { 'Mesures chiffrees indisponibles (inventaire par tache distante) : seules les tuiles sont remplies.' } else { 'Donnees lues par CIM, sans nouvelle requete. L inventaire complet ajoute correctifs, processus et evenements.' })
    [void](Set-DomeniaControlText 'LblComputerDashboard' $text)
}
function Update-DomeniaSoftwareDashboard {
    param($Rows)
    $panel = Get-DomeniaControl 'PnlSoftwareDashboard'
    if ($null -eq $panel) { return }
    $panel.Children.Clear()
    $items = @($Rows | Where-Object { $null -ne $_ -and [string]$_.Name })
    if (-not $items.Count) { [void](Set-DomeniaControlText 'LblSoftwareDashboard' 'Aucun logiciel lu.'); return }
    $add = { param($element) if ($null -ne $element) { [void]$panel.Children.Add($element) } }
    $publishers = @($items | Group-Object -Property { $p = ([string]$_.Publisher).Trim(); if ($p) { $p } else { 'Editeur non renseigne' } } | Sort-Object Count -Descending)
    $totalKb = 0.0; foreach ($item in $items) { try { $totalKb += [double]$item.SizeKb } catch { } }
    & $add (New-DomeniaKpiTile -Title 'Logiciels' -Value ([string]$items.Count) -Detail ([string]$publishers.Count + ' editeurs'))
    & $add (New-DomeniaKpiTile -Title 'Taille declaree' -Value (Format-DomeniaDashboardSize ($totalKb * 1KB)) -Detail 'Somme des tailles connues')
    $top = @($publishers | Select-Object -First 6 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double]$_.Count } })
    $others = @($publishers | Select-Object -Skip 6 | Measure-Object -Property Count -Sum).Sum
    if ($others -gt 0) { $top += [pscustomobject]@{ Label = 'Autres'; Value = [double]$others } }
    & $add (New-DomeniaDonutChart -Title 'Editeurs' -Items $top -Width 380)
    $architecture = @($items | Group-Object { $a = ([string]$_.Architecture).Trim(); if ($a) { $a } else { 'Non precise' } } | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double]$_.Count } })
    & $add (New-DomeniaDonutChart -Title 'Architecture' -Items $architecture -Width 320)
    $scope = @($items | Group-Object { $k = ([string]$_.Scope).Trim(); if ($k) { $k } else { 'Non precise' } } | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double]$_.Count } })
    & $add (New-DomeniaDonutChart -Title 'Portee d installation' -Items $scope -Width 320)
    $multiple = @($items | Group-Object { ([string]$_.Name).ToLowerInvariant() } | Where-Object { @($_.Group | ForEach-Object { [string]$_.Version } | Sort-Object -Unique).Count -gt 1 })
    & $add (New-DomeniaKpiTile -Title 'Installes en plusieurs versions' -Value ([string]$multiple.Count) -Detail $(if ($multiple.Count) { [string]$multiple[0].Group[0].Name } else { 'Aucun doublon de version' }))
    $anonymous = @($items | Where-Object { -not ([string]$_.Publisher).Trim() })
    & $add (New-DomeniaKpiTile -Title 'Sans editeur declare' -Value ([string]$anonymous.Count) -Detail $(if ($anonymous.Count) { [string]$anonymous[0].Name } else { 'Tous les editeurs sont renseignes' }))
    $largest = @($items | Where-Object { [double]$_.SizeKb -gt 0 } | Sort-Object { [double]$_.SizeKb } -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [Math]::Round([double]$_.SizeKb / 1024) } })
    & $add (New-DomeniaBarChart -Title 'Plus gros logiciels (Mo)' -Items $largest -Unit ' Mo' -Width 520)
    [void](Set-DomeniaControlText 'LblSoftwareDashboard' ([string]$items.Count + ' logiciels lus. Synthese calculee sur la liste chargee.'))
}
