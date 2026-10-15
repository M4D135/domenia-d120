# Workstation dashboard as widgets (decision David 2026-10-07): the checks of the old workstation dashboard
# (inventory rows, CIM measures, computer account read with the object card) now fill the entries of the
# Domenia-Boards.Model contract, drawn by the widget renderer. No WPF here and no new request to the workstation.

function Add-DomeniaComputerBoardAdEntries {
    # Health of the computer account in Active Directory, from the attributes already read with the object card.
    param([Parameter(Mandatory=$true)]$Data,$Object = $null,$Metrics = $null)
    if (($null -eq $Object) -or ($null -eq $Object.Entry)) { return }
    $entry = $Object.Entry
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $now = [datetime]::UtcNow
    $limits=$Data.HealthPolicy.Thresholds

    $passwordSet = Get-DomeniaEntryFileTimeUtc $entry 'pwdLastSet'
    if ($null -ne $passwordSet) {
        $days = [int]($now - $passwordSet).TotalDays
        $late = ($days -gt $limits.PasswordDays)
        # CO-09: the operator cannot check the trust relationship himself; he warns the administrator.
        if ($late) { Add-DomeniaBoardAttention -Data $Data -Level Warn -Text ('Mot de passe machine ancien (' + $days + ' jours) : prévenir lʼadministrateur.') -Point 'pwdold' }
        $detail = if ($late) { 'Mot de passe machine ancien : prévenir lʼadministrateur' } else { 'Renouvelé le ' + $passwordSet.ToLocalTime().ToString('dd/MM/yyyy', $invariant) }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ad.password' -Kind Value -Value ('il y a ' + $days + ' j') -Detail $detail -State $(if ($late) { 'Warn' } else { 'Ok' }))
    }

    $logon = Get-DomeniaEntryFileTimeUtc $entry 'lastLogonTimestamp'
    if ($null -ne $logon) {
        $days = [int]($now - $logon).TotalDays
        $late = ($days -ge $limits.StaleDays)
        if ($late) { Add-DomeniaBoardAttention -Data $Data -Level Warn -Text ('Aucune connexion au domaine depuis ' + $days + ' jours (lastLogonTimestamp approximatif).') -Point 'stale' }
        $detail = if ($late) { ('Plus de '+$limits.StaleDays+' jours, date AD approximative') } else { $logon.ToLocalTime().ToString('dd/MM/yyyy', $invariant) + ' · date approximative, à 14 jours près' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ad.lastlogon' -Kind Value -Value ('il y a ' + $days + ' j') -Detail $detail -State $(if ($late) { 'Warn' } else { 'Ok' }))
    }

    $uac = 0; $uacKnown=[int]::TryParse((Get-DomeniaEntryFirstString $entry 'userAccountControl'),[ref]$uac) -and $uac -ge 0
    $disabled = [bool]($uac -band 2)
    if ($disabled) { Add-DomeniaBoardAttention -Data $Data -Level Alert -Text 'Compte ordinateur desactive dans AD.' -Point 'ad.disabled' }
    $created = 'date inconnue'
    try { $created = ([datetime](Get-DomeniaEntryFirstString $entry 'whenCreated')).ToLocalTime().ToString('dd/MM/yyyy', $invariant) } catch { $created = 'date inconnue' }
    Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ad.account' -Kind Value -Value $(if(-not $uacKnown){'État inconnu'}elseif ($disabled) { 'Désactivé' } else { 'Activé' }) -Detail ('Compte AD ; créé le ' + $created) -State $(if(-not $uacKnown){'Off'}elseif ($disabled) { 'Alert' } else { 'Ok' }))

    # Two nearest OUs of the distinguished name, escaped commas restored.
    $dn = [string]$Object.DN
    $ous = @($dn -split '(?<!\\),' | Where-Object { $_ -like 'OU=*' } | Select-Object -First 2 | ForEach-Object { $_.Substring(3) -replace '\\(.)','$1' })
    if ($ous.Count) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ad.ou' -Kind Value -Value ([string]$ous[0]) -Detail $(if ($ous.Count -gt 1) { 'dans ' + [string]$ous[1] } else { '' })) }

    $laps = Get-DomeniaEntryFileTimeUtc $entry 'msLAPS-PasswordExpirationTime'
    if ($null -eq $laps) { $laps = Get-DomeniaEntryFileTimeUtc $entry 'ms-Mcs-AdmPwdExpirationTime' }
    if ($null -ne $laps) {
        $expired = ($laps -lt $now)
        if ($expired) { Add-DomeniaBoardAttention -Data $Data -Level Warn -Text 'Mot de passe LAPS expire (rotation en attente).' -Point 'laps.expired' -Route 'ComputerSecrets' -RouteText 'Vue Secrets du poste' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ad.laps' -Kind Value -Value $(if ($expired) { 'Expire' } else { 'Valide' }) -Detail ('Expiration le ' + $laps.ToLocalTime().ToString('dd/MM/yyyy HH:mm', $invariant)) -State $(if ($expired) { 'Warn' } else { 'Ok' }))
    }

    $manager = Get-DomeniaEntryFirstString $entry 'managedBy'
    if ($manager) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ad.managedby' -Kind Value -Value ((($manager -split '(?<!\\),')[0] -replace '^CN=','') -replace '\\(.)','$1') -Detail 'Attribut managedBy') }

    # Clock skew measured by the inventory against the connected domain controller (CO-09: currentTime of its RootDSE,
    # read during the requested inventory); an older result, or a controller not read, compares with this workstation.
    if (($null -ne $Metrics) -and ($null -ne $Metrics.PSObject.Properties['ClockSkewSeconds']) -and ($null -ne $Metrics.ClockSkewSeconds)) {
        $skew = [int]$Metrics.ClockSkewSeconds
        $gap = [Math]::Abs($skew)
        $referenceProperty = $Metrics.PSObject.Properties['ClockReference']
        $byController = (($null -ne $referenceProperty) -and ([string]$referenceProperty.Value -eq 'Controleur'))
        $against = if ($byController) { 'par rapport au contrôleur de domaine' } else { 'par rapport à ce poste dʼadministration' }
        # A local reference does not establish the offset from the domain controller.
        if ($gap -gt 300 -and $byController) {
            Add-DomeniaBoardAttention -Data $Data -Level Alert -Text ('Horloge décalée de ' + $skew + ' s ' + $against + ' : risque dʼéchec de lʼauthentification Kerberos.') -Point 'clock'
        } elseif ($gap -gt 60) {
            Add-DomeniaBoardAttention -Data $Data -Level Warn -Text ('Horloge décalée de ' + $skew + ' s ' + $against + '.' + $(if (-not $byController) { ' Vérifiez la synchronisation des deux postes ; le contrôleur nʼa pas été lu.' } else { '' })) -Point 'clock'
        }
        $clockDetail = if (-not $byController) { 'Écart avec ce poste dʼadministration (contrôleur non lu)' } elseif ($gap -gt 300) { 'Plus de 5 min avec le contrôleur : risque dʼéchec Kerberos' } else { 'Écart avec le contrôleur de domaine' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ad.clock' -Kind Value -Value $(if ($gap -lt 2) { 'À lʼheure' } else { ('{0:+0;-0} s' -f $skew) }) -Detail $clockDetail -State $(if ($gap -gt 300 -and $byController) { 'Alert' } elseif ($gap -gt 60) { 'Warn' } else { 'Ok' }))
    }
}

function Get-DomeniaComputerBoardData {
    # Entries, attention points, hints and summary of the workstation board for one inventory result
    # ($Result.Rows, $Result.Metrics). $Object is the selected directory object ({Entry; DN}): without it the
    # computer account entries are left out. $At: time of the inventory shown in the summary (now when absent).
    # $Lifecycle: end-of-service table read once by the interface ($null: end date unknown, never critical).
    param($Result = $null,$Object = $null,$At = $null,$Lifecycle = $null,$HealthPolicy=$null)
    $Data = New-DomeniaBoardData -Board Computer
    $Data.HealthPolicy=ConvertTo-DomeniaHealthPolicy $HealthPolicy
    $Data.HealthPolicy.EvaluatedAtUtc=[datetime]::UtcNow.ToString('o')
    $limits=$Data.HealthPolicy.Thresholds
    $hasInventory = ($null -ne $Result)
    $rows = @(); $metrics = $null; $uptime='';$uptimeDays=0
    if ($hasInventory) {
        $rows = @(@($Result.Rows) | Where-Object { $null -ne $_ })
        $metrics = $Result.Metrics
    }
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    # A point may name the tab holding its useful action (stable point name, route of Invoke-DomeniaBoardRoute):
    # the attention card offers a link that opens it and runs nothing (decision David 2026-10-08, UX-10).
    $note = { param([string]$Level,[string]$Text,[string]$Point = '',[string]$Route = '',[string]$RouteText = '') Add-DomeniaBoardAttention -Data $Data -Level $Level -Text $Text -Point $Point -Route $Route -RouteText $RouteText }
    $isEmpty = { param([string]$Text) return ($Text -match '^\(vide\)$|^Non renseigne$|^Non fourni|^Aucun$|^\s*$') }
    $value = { param([string]$Category,[string]$Item) Get-DomeniaInventoryValue $rows $Category $Item }
    # First non-empty value of the category whose item ends with the suffix (per processor, per adapter).
    $firstLike = { param([string]$Category,[string]$Suffix) foreach ($row in $rows) { if (([string]$row.Category -eq $Category) -and ([string]$row.Item).EndsWith($Suffix)) { $text = [string]$row.Value; if (-not (& $isEmpty $text)) { return $text } } }; return '' }
    # Free space thresholds shared by the system disk, the other volumes and the fleet (CO-14, Get-DomeniaBoardThresholds).
    $freeLevel = { param([double]$Percent) return (Get-DomeniaThresholdState -Measure DiskFree -Percent $Percent -Policy $Data.HealthPolicy) }

    if ($hasInventory) {
        # -------------------------------------------------------------------
        # Identite du poste
        # -------------------------------------------------------------------
        $osName = (& $value 'Systeme d exploitation' 'Nom') -replace '^Microsoft ',''
        $build = & $value 'Systeme d exploitation' 'Build'
        if (-not $build) { $build = [string]((& $value 'Systeme d exploitation' 'Version') -split '\.')[-1] }
        # End of service from the delivered table (FO-08): LTSC, LTSB and IoT keep their own dates (CO-13).
        $release = Get-DomeniaWindowsRelease -Build $build -Caption $osName -Lifecycle $Lifecycle
        $releaseName = if ([string]$release.Label) { [string]$release.Label } else { [string]$release.Name }
        if ([string]$release.Status -eq 'Ended') { & $note 'Alert' ($releaseName + ' : fin de service le ' + [string]$release.End + ', poste à migrer.') 'eos.ended' }
        elseif ([string]$release.Status -eq 'Soon') { & $note 'Warn' ($releaseName + ' : fin de service le ' + [string]$release.End + '.') 'eos.soon' }
        $osValue = if ($release.Name) { [string]$release.Name } elseif ($osName) { $osName } else { 'Non lu' }
        $osDetail = if ($release.Note) { [string]$release.Note } elseif ($build) { 'Build ' + $build } else { '' }
        $osState = if ([string]$release.Status -eq 'Ended') { 'Alert' } elseif ([string]$release.Status -eq 'Soon') { 'Warn' } elseif ($osValue -eq 'Non lu') { 'Off' } else { '' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.os' -Kind Value -Value $osValue -Detail $osDetail -State $osState)

        $model = & $value 'Systeme' 'Modele'
        $serial = & $value 'Systeme' 'Numero de serie chassis'
        $modelParts = New-Object System.Collections.ArrayList
        $maker = & $value 'Systeme' 'Fabricant'; if ($maker) { [void]$modelParts.Add($maker) }
        if ($serial) { [void]$modelParts.Add('serie ' + $serial) }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.model' -Kind Value -Value $(if ($model) { $model } else { 'Non lu' }) -Detail (@($modelParts) -join ' · ') -State $(if ($model) { '' } else { 'Off' }))

        $cpu = & $firstLike 'Processeur' ' modele'
        $cores = & $firstLike 'Processeur' ' coeurs'; $threads = & $firstLike 'Processeur' ' processeurs logiques'
        $cpuDetail = if ($cores -and $threads) { $cores + ' coeurs, ' + $threads + ' threads' } elseif ($cores) { $cores + ' coeurs' } else { '' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.cpu' -Kind Value -Value $(if ($cpu) { ($cpu -replace '\(R\)|\(TM\)|CPU','' -replace '\s+',' ').Trim() } else { 'Non lu' }) -Detail $cpuDetail -State $(if ($cpu) { '' } else { 'Off' }))

        # Installed memory: CIM measure, else the memory modules total, else the computer system total.
        $memoryTotal = 0.0; if ($null -ne $metrics) { $memoryTotal = [double]$metrics.MemoryTotal }
        $modules = @($rows | Where-Object { ([string]$_.Category -eq 'Memoire') -and ([string]$_.Item).StartsWith('Barrette') }).Count
        $memoryText = if ($memoryTotal -gt 0) { Format-DomeniaDashboardSize $memoryTotal } else { & $value 'Memoire' 'Total installe' }
        if (-not $memoryText) { $memoryText = & $value 'Systeme' 'Memoire physique totale' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.memory' -Kind Value -Value $(if ($memoryText) { $memoryText } else { 'Non lue' }) -Detail $(if ($modules) { [string]$modules + ' barrette(s)' } else { 'Barrettes non exposees (machine virtuelle ?)' }) -State $(if ($memoryText) { '' } else { 'Off' }))

        # Uptime '0 j 2 h 2 min' shown as '2 h 02 min', '3 j 4 h 10 min' as '3 j 4 h'.
        $uptime = & $value 'Systeme d exploitation' 'Duree de fonctionnement'
        $uptimeDays = 0; $uptimeText = $uptime
        if ($uptime -match '^(\d+) j(?: (\d+) h)?(?: (\d+) min)?') {
            $uptimeDays = [int]$Matches[1]
            $hours = 0; if ($Matches[2]) { $hours = [int]$Matches[2] }
            $minutes = 0; if ($Matches[3]) { $minutes = [int]$Matches[3] }
            $uptimeText = if ($uptimeDays -gt 0) { [string]$uptimeDays + ' j ' + $hours + ' h' } elseif ($hours -gt 0) { [string]$hours + ' h ' + $minutes.ToString('00') + ' min' } else { [string]$minutes + ' min' }
        }
        $longUptime = ($uptimeDays -gt $limits.UptimeDays)
        if ($longUptime) { & $note 'Warn' ('Pas de redemarrage depuis ' + $uptimeDays + ' jours.') 'uptime' 'ComputerActions' 'Redémarrer : vue Intervenir' }
        $lastBoot = & $value 'Systeme d exploitation' 'Dernier demarrage'
        $uptimeDetail = if ($longUptime) { ('Plus de '+$limits.UptimeDays+' jours : redemarrage conseille') } elseif ($lastBoot) { 'Demarre le ' + $lastBoot } else { '' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.uptime' -Kind Value -Value $(if ($uptime) { $uptimeText } else { 'Non lu' }) -Detail $uptimeDetail -State $(if ($longUptime) { 'Warn' } elseif (-not $uptime) { 'Off' } else { '' }))

        $user = & $value 'Systeme' 'Utilisateur connecte'
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.user' -Kind Value -Value $(if ($user) { $user } else { 'Aucun' }) -Detail $(if ($user) { 'Console, au moment de l inventaire' } else { 'Personne en console au moment de l inventaire' }))

        # First IPv4 address of the adapters, with the gateway of the same adapter.
        $ip = ''; $gateway = ''; $anyAddress = ''
        foreach ($row in $rows) {
            if (([string]$row.Category -ne 'Reseau') -or (-not ([string]$row.Item).EndsWith(' adresses IP'))) { continue }
            $tokens = @(([string]$row.Value) -split '[,; ]+' | Where-Object { $_ })
            if ((-not $anyAddress) -and $tokens.Count) { $anyAddress = [string]$tokens[0] }
            $v4 = @($tokens | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
            if (-not $v4.Count) { continue }
            $ip = [string]$v4[0]
            $label = ([string]$row.Item).Substring(0, ([string]$row.Item).Length - ' adresses IP'.Length)
            $gatewayText = & $value 'Reseau' ($label + ' passerelle')
            $gateways = @(($gatewayText -split '[,; ]+') | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
            $gateway = if ($gateways.Count) { [string]$gateways[0] } else { $gatewayText.Trim() }
            break
        }
        if (-not $ip) { $ip = $anyAddress }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.ip' -Kind Value -Value $(if ($ip) { $ip } else { 'Non lue' }) -Detail $(if ($gateway) { 'Passerelle ' + $gateway } elseif ($ip) { 'Sans passerelle' } else { '' }) -State $(if ($ip) { '' } else { 'Off' }))

        $domain = & $value 'Systeme' 'Domaine'
        $roles = @{ '0'='Poste autonome'; '1'='Poste membre du domaine'; '2'='Serveur autonome'; '3'='Serveur membre'; '4'='Controleur de domaine secondaire'; '5'='Controleur de domaine principal' }
        $role = [string](& $value 'Systeme' 'Role dans le domaine'); if ($roles.ContainsKey($role)) { $role = [string]$roles[$role] }
        if ($domain) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.domain' -Kind Value -Value $domain -Detail $role) }
    }

    # -----------------------------------------------------------------------
    # Compte machine dans Active Directory (attributes read with the object card)
    # -----------------------------------------------------------------------
    Add-DomeniaComputerBoardAdEntries -Data $Data -Object $Object -Metrics $metrics

    # -----------------------------------------------------------------------
    # Ressources (measured during the inventory)
    # -----------------------------------------------------------------------
    if ($null -ne $metrics) {
        $memoryTotal = [double]$metrics.MemoryTotal
        # No gauge without the CIM total: the text total alone gives no free figure.
        if ($memoryTotal -gt 0) {
            $used = [Math]::Max(0.0, $memoryTotal - [double]$metrics.MemoryFree)
            $ratio = $used / $memoryTotal
            # CO-14: the gauge is coloured by this state, the same one that raises the point.
            $memoryState = Get-DomeniaThresholdState -Measure MemoryUsed -Percent (100.0 * $ratio) -Policy $Data.HealthPolicy
            $memoryLimit = [string][int](Get-DomeniaBoardThresholds -Policy $Data.HealthPolicy).MemoryUsedWarn
            if ($memoryState -ne 'Ok') { & $note 'Warn' ('Mémoire utilisée à plus de ' + $memoryLimit + ' %.') 'memory' }
            $usedGb = [Math]::Round($used / 1GB, 1); $totalGb = [Math]::Round($memoryTotal / 1GB, 1)
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.memory.usage' -Kind Number -Title ('Mémoire utilisée sur ' + (Format-DomeniaDashboardSize $memoryTotal)) -Value (([Math]::Round(100.0 * $ratio)).ToString('0', $fr) + ' %') -Detail ($usedGb.ToString('0.#', $fr) + ' / ' + $totalGb.ToString('0.#', $fr) + ' Go') -State $(if ($memoryState -ne 'Ok') { 'Warn' } else { '' }) -Number ([double]$usedGb) -Maximum ([double]$totalGb) -Unit 'Go')
        }
        if ([double]$metrics.CpuLoad -ge 0) {
            $load = [double]$metrics.CpuLoad
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.cpu.load' -Kind Number -Value ($load.ToString('0', $fr) + ' %') -Detail 'Au moment de lʼinventaire' -Number $load -Maximum 100.0 -Unit '%')
        }
        if ([double]$metrics.Battery -ge 0) {
            $battery = [double]$metrics.Battery
            $lowBattery = ((Get-DomeniaThresholdState -Measure Battery -Percent $battery -Policy $Data.HealthPolicy) -ne 'Ok')
            $batteryLimit = [string][int](Get-DomeniaBoardThresholds -Policy $Data.HealthPolicy).BatteryWarn
            if ($lowBattery) { & $note 'Warn' ('Batterie à ' + $battery.ToString('0', $fr) + ' %.') 'battery' }
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.battery' -Kind Number -Value ($battery.ToString('0', $fr) + ' %') -Detail $(if ($lowBattery) { 'Moins de ' + $batteryLimit + ' % : poste à brancher' } else { 'Charge restante' }) -State $(if ($lowBattery) { 'Warn' } else { '' }) -Number $battery -Maximum 100.0 -Unit '%' -LowIsBad)
        }
        else {
            # The inventory answered that there is no battery (decision David 2026-10-14): said in words, never a 0 %.
            $batteryState = Get-DomeniaCategorySummary $rows 'Batterie'
            if ((-not $batteryState.Count) -and ([string]$batteryState.State -match '^Aucune batterie')) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.battery' -Kind Value -Value 'Aucune batterie' -Detail 'Poste fixe ou alimentation secteur uniquement, selon lʼinventaire') }
        }

        # One system disk on the fleet workstations (decision David 2026-10-07): C: (else the first volume) as a ring,
        # every other volume as one bar of free space.
        $allDisks = @(@($metrics.Disks) | Where-Object { ($null -ne $_) -and ([double]$_.Size -gt 0) })
        $systemDisk = @($allDisks | Where-Object { [string]$_.Name -ieq 'C:' } | Select-Object -First 1)
        if (-not $systemDisk.Count) { $systemDisk = @($allDisks | Select-Object -First 1) }
        if ($systemDisk.Count) {
            $disk = $systemDisk[0]
            $diskName = [string]$disk.Name
            $size = [double]$disk.Size; $free = [double]$disk.Free; $used = [Math]::Max(0.0, $size - $free)
            $percent = [Math]::Round(100.0 * $free / $size)
            $diskState = & $freeLevel $percent
            # CO-09: one colon only ('Peu dʼespace sur C: (13 % libre)', never 'Disque C: : 13 % libre').
            if ($diskState -eq 'Alert') { & $note 'Alert' ($diskName + ' presque plein (' + $percent + ' % libre).') 'lowdisk' 'ComputerActions' 'Ouvrir le disque C : vue Intervenir' } elseif ($diskState -eq 'Warn') { & $note 'Warn' ('Peu dʼespace sur ' + $diskName + ' (' + $percent + ' % libre).') 'disk.tight' 'ComputerActions' 'Ouvrir le disque C : vue Intervenir' }
            $ring = @(
                [pscustomobject]@{ Label = ('Utilisé ' + (Format-DomeniaDashboardSize $used)); Value = $used; Color = (Get-DomeniaBoardColor 'Used') },
                [pscustomobject]@{ Label = ('Libre ' + (Format-DomeniaDashboardSize $free)); Value = $free; Color = (Get-DomeniaBoardColor $diskState) }
            )
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.disk.system' -Kind Distribution -Title ('Disque ' + $diskName + ' (' + (Format-DomeniaDashboardSize $size) + ')') -Value ([string]$percent + ' % libre') -Detail ((Format-DomeniaDashboardSize $free) + ' libres sur ' + (Format-DomeniaDashboardSize $size)) -State $(if ($diskState -eq 'Ok') { '' } else { $diskState }) -Items $ring -CenterText ([string]$percent + ' % libre'))

            $others = @($allDisks | Where-Object { [string]$_.Name -ine $diskName })
            if ($others.Count) {
                $volumeItems = New-Object System.Collections.ArrayList
                $worst = $null; $worstPercent = 101.0; $worstState = 'Ok'
                foreach ($other in $others) {
                    $otherPercent = [Math]::Round(100.0 * [double]$other.Free / [double]$other.Size)
                    $otherState = & $freeLevel $otherPercent
                    if ($otherState -eq 'Alert') { & $note 'Alert' ('Volume ' + [string]$other.Name + ' presque plein (' + $otherPercent + ' % libre).') 'lowdisk' }
                    [void]$volumeItems.Add([pscustomobject]@{ Label = [string]$other.Name; Value = [double]$otherPercent; Color = (Get-DomeniaBoardColor $otherState) })
                    if ($otherPercent -lt $worstPercent) { $worst = $other; $worstPercent = $otherPercent; $worstState = $otherState }
                }
                $volumesDetail = if ($others.Count -eq 1) { (Format-DomeniaDashboardSize $worst.Free) + ' libres sur ' + (Format-DomeniaDashboardSize $worst.Size) } else { 'Le moins libre des ' + $others.Count + ' volumes' }
                Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.disk.volumes' -Kind Distribution -Value ([string]$worst.Name + ' ' + $worstPercent + ' % libre') -Detail $volumesDetail -State $(if ($worstState -eq 'Ok') { '' } else { $worstState }) -Items @($volumeItems) -Maximum 100.0 -Unit '%')
            }
            else {
                # The logical disks were read and only the system disk exists: an answer, not a missing value.
                Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.disk.volumes' -Kind Value -Value 'Aucun autre volume' -Detail ('Seul ' + $diskName + ' est monté, selon lʼinventaire'))
            }
        }
    }

    # -----------------------------------------------------------------------
    # Activite
    # -----------------------------------------------------------------------
    # MO-06: the noise table of Domenia-Workstation.Model (trigger or delayed services, known System errors).
    $noise = Get-DomeniaWorkstationNoiseRules
    $stoppedSummary = Get-DomeniaCategorySummary $rows 'Services en defaut'
    # Worker value: 'Demarrage automatique mais arrete. Nom : <short name>'.
    $stoppedExpected = @($stoppedSummary.Items | Where-Object { ([string]$_.Value -match 'Nom : (\S+)\s*$') -and (Test-DomeniaServiceStopExpected -Name $Matches[1] -Rules $noise) })
    $stoppedUnexpected = @($stoppedSummary.Items | Where-Object { $stoppedExpected -notcontains $_ })
    $services = $null; if ($null -ne $metrics) { $services = $metrics.Services }
    $serviceCount = {
        param([string]$Name)
        if ($null -eq $services) { return 0 }
        if ($services -is [System.Collections.IDictionary]) { return [int]$services[$Name] }
        $property = $services.PSObject.Properties[$Name]
        if ($null -ne $property) { return [int]$property.Value }
        return 0
    }
    $running = & $serviceCount 'En cours'; $autoStopped = & $serviceCount 'Arretes (automatiques)'
    # Stopped automatic services that start on a trigger or after a delay are drawn apart, in grey (MO-06).
    $autoExpected = [Math]::Min($autoStopped, $stoppedExpected.Count)
    $serviceParts = @(
        [pscustomobject]@{ Label = 'En cours'; Count = $running; Color = (Get-DomeniaBoardColor 'Ok') }
        [pscustomobject]@{ Label = 'Arrêtés (automatiques)'; Count = ($autoStopped - $autoExpected); Color = (Get-DomeniaBoardColor 'Warn') }
        [pscustomobject]@{ Label = 'Arrêtés (déclencheur ou différé)'; Count = $autoExpected; Color = (Get-DomeniaBoardColor 'Off') }
        [pscustomobject]@{ Label = 'Arrêtés (manuels)'; Count = (& $serviceCount 'Arretes (manuels)'); Color = (Get-DomeniaBoardColor 'Off') }
        [pscustomobject]@{ Label = 'Désactivés'; Count = (& $serviceCount 'Desactives'); Color = '#E2E8F0' }
    )
    $serviceRing = @(foreach ($part in $serviceParts) { if ([int]$part.Count -gt 0) { [pscustomobject]@{ Label = [string]$part.Label; Value = [double]$part.Count; Color = [string]$part.Color } } })
    if ($serviceRing.Count) {
        $total = 0; foreach ($part in $serviceRing) { $total += [int]$part.Value }
        $unexpectedCount = $autoStopped - $autoExpected
        $servicesDetail = 'sur ' + $total + ' services' + $(if ($unexpectedCount -gt 0) { ' · ' + $unexpectedCount + ' automatique(s) arrêté(s)' } else { '' })
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.services' -Kind Distribution -Value ([string]$running + ' en cours') -Detail $servicesDetail -Items $serviceRing -CenterText ([string]$total + ' services'))
    }

    $processes = @(); if ($null -ne $metrics) { $processes = @(@($metrics.Processes) | Where-Object { $null -ne $_ }) }
    if ($processes.Count) {
        $top = @($processes | Group-Object Name | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [Math]::Round([double](($_.Group | Measure-Object -Property Mb -Sum).Sum), 1) } } | Sort-Object Value -Descending | Select-Object -First 8)
        if ($top.Count) {
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.processes' -Kind Distribution -Value ([string]$top[0].Label) -Detail (([double]$top[0].Value).ToString('0', $fr) + ' Mo · ' + $processes.Count + ' processus releves') -Items $top -Unit 'Mo')
        }
    }

    # MO-06: known noise left out, disk, NTFS and Kernel-Power 41 to watch, any other error as information.
    $events = Get-DomeniaCategorySummary $rows 'Evenements systeme'
    if ($events.Count) {
        $kept = New-Object System.Collections.ArrayList
        $ignored = 0; $critical = 0
        foreach ($logEvent in @($events.Items)) {
            $source = [string]$logEvent.Item; $id = ''
            if ($source -match '^(.*) ID (\d+)$') { $source = $Matches[1]; $id = $Matches[2] }
            $level = Get-DomeniaSystemEventLevel -Source $source -EventId $id -Rules $noise
            if ($level -eq 'Ignore') { $ignored++; continue }
            if ($level -eq 'Warn') { $critical++ }
            [void]$kept.Add([pscustomobject]@{ Source = $source; Level = $level })
        }
        $generic = $kept.Count - $critical
        if ($critical) { & $note 'Warn' ([string]$critical + ' erreur(s) critique(s) dans le journal Système sur 3 jours (disque, NTFS ou arrêt inattendu).') 'events' }
        if ($generic) { & $note 'Info' ([string]$generic + ' autre(s) erreur(s) dans le journal Système sur 3 jours.') }
        $ignoredText = if ($ignored) { ' · ' + $ignored + ' connue(s) sans gravité ignorée(s)' } else { '' }
        if ($kept.Count) {
            $groups = @($kept | Group-Object Source | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } | Select-Object -First 8)
            $sources = @(foreach ($group in $groups) {
                $isCritical = (@($group.Group | Where-Object { $_.Level -eq 'Warn' }).Count -gt 0)
                [pscustomobject]@{ Label = [string]$group.Name; Value = [double]$group.Count; Color = (Get-DomeniaBoardColor $(if ($isCritical) { 'Warn' } else { 'Info' })) }
            })
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.events' -Kind Distribution -Value ([string]$sources[0].Label) -Detail ([string][int]$sources[0].Value + ' sur ' + $kept.Count + ' erreur(s) en 3 jours' + $ignoredText) -State $(if ($critical) { 'Warn' } else { '' }) -Items $sources)
        } else {
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.events' -Kind Value -Value 'Aucune à signaler' -Detail ([string]$ignored + ' erreur(s) connue(s) sans gravité ignorée(s) en 3 jours') -State Ok)
        }
    }

    # -----------------------------------------------------------------------
    # Securite et etat
    # -----------------------------------------------------------------------
    $av = Get-DomeniaCategorySummary $rows 'Antivirus'
    if ($av.Count) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.antivirus' -Kind Value -Value ([string]$av.Items[0].Item) -Detail ([string]$av.Items[0].Value)) }

    # CO-12: one effective state per profile, the group policy winning over the local key; only that state alerts.
    # Current worker rows: 'Profil domaine' = 'Active (strategie)'. Older rows: 'Profil domaine (strategie)' and
    # 'Profil domaine' = 'Active' or 'Desactive'. Values are compared exactly; anything else is not counted.
    $firewall = Get-DomeniaCategorySummary $rows 'Pare-feu'
    $firewallProfiles = [ordered]@{}
    foreach ($item in @($firewall.Items)) {
        $profileName = ([string]$item.Item).Trim(); $text = ([string]$item.Value).Trim()
        $fromPolicy = $false
        if ($profileName -match '^(.+?)\s*\(strategie\)$') { $profileName = $Matches[1]; $fromPolicy = $true }
        if ($text -match '^(Active|Desactive) \((strategie|local)\)$') { $text = $Matches[1]; $fromPolicy = ($Matches[2] -ceq 'strategie') }
        $enabled = $null
        if ($text -ceq 'Active') { $enabled = $true } elseif ($text -ceq 'Desactive') { $enabled = $false }
        if ($null -eq $enabled) { continue }
        if ((-not $firewallProfiles.Contains($profileName)) -or ($fromPolicy -and (-not $firewallProfiles[$profileName].Policy))) { $firewallProfiles[$profileName] = [pscustomobject]@{ Enabled = $enabled; Policy = $fromPolicy } }
    }
    if ($firewallProfiles.Count) {
        $profileLabels = @{ 'Profil domaine' = 'Domaine'; 'Profil prive' = 'Privé'; 'Profil public' = 'Public' }
        $on = 0; $offNames = New-Object System.Collections.ArrayList; $parts = New-Object System.Collections.ArrayList; $policies = 0
        foreach ($name in @($firewallProfiles.Keys)) {
            $profileState = $firewallProfiles[$name]
            $label = if ($profileLabels.ContainsKey([string]$name)) { [string]$profileLabels[[string]$name] } else { [string]$name }
            if ($profileState.Enabled) { $on++ } else { [void]$offNames.Add($label) }
            if ($profileState.Policy) { $policies++ }
            [void]$parts.Add($label + ' : ' + $(if ($profileState.Enabled) { 'actif' } else { 'désactivé' }) + ' (' + $(if ($profileState.Policy) { 'stratégie' } else { 'local' }) + ')')
        }
        $profileCount = $firewallProfiles.Count
        $origin = if ($policies -eq $profileCount) { ' (stratégie)' } elseif ($policies -eq 0) { ' (local)' } else { '' }
        $firewallValue = [string]$on + ' profil' + $(if ($on -gt 1) { 's' } else { '' }) + ' sur ' + $profileCount + ' actif' + $(if ($on -gt 1) { 's' } else { '' }) + $origin
        if ($offNames.Count) { & $note 'Warn' ('Pare-feu désactivé : ' + (@($offNames) -join ', ') + '.') 'firewall' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.firewall' -Kind Value -Value $firewallValue -Detail (@($parts) -join ' · ') -State $(if ($offNames.Count) { 'Warn' } else { 'Ok' }))
    }

    $bitlocker = @($rows | Where-Object { ([string]$_.Category -eq 'BitLocker') -and (-not ([string]$_.Item).EndsWith(' methode')) -and ([string]$_.Item -ne 'Etat') })
    # System volume first: WMI order may start with a data volume or one without a drive letter.
    $system = @($bitlocker | Where-Object { [string]$_.Item -eq 'Volume C:' })
    if ($system.Count) { $bitlocker = @($system) + @($bitlocker | Where-Object { [string]$_.Item -ne 'Volume C:' }) }
    if ($bitlocker.Count) {
        $bitlockerText = [string]$bitlocker[0].Value
        # Worker values: 'Protection Active', 'Protection Desactive', 'Protection Inconnu' (the word 'Protection' alone proves nothing).
        $protected = (($bitlockerText -match '(?i)\bactive\b|\bprotege\b') -and ($bitlockerText -notmatch '(?i)desactiv|non protege|inconnu|\boff\b'))
        if (-not $protected) { & $note 'Warn' ('BitLocker : ' + $bitlockerText + '.') 'bitlocker.none' 'ComputerSecrets' 'Vue Secrets du poste' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.bitlocker' -Kind Value -Value $bitlockerText -Detail ([string]$bitlocker[0].Item) -State $(if ($protected) { 'Ok' } else { 'Warn' }))
    }

    # Sources that answered this inventory, even without any item (access status of the worker): an empty answer is a
    # reading ('0', 'Aucune'), not a widget left unread (SP-18).
    $answered = @{}
    if ($hasInventory -and ($null -ne $Result.PSObject.Properties['Access'])) {
        foreach ($access in @($Result.Access)) { if (($null -ne $access) -and ([string]$access.Status -in @('OK','VIDE','PARTIEL'))) { $answered[[string]$access.Category] = $true } }
    }

    $wsus = & $value 'Windows Update' 'Serveur WSUS'
    if ($wsus) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.wsus' -Kind Value -Value 'WSUS' -Detail $wsus) }
    elseif (([bool](Get-DomeniaCategorySummary $rows 'Windows Update').Read) -or ($answered.ContainsKey('Windows Update'))) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.wsus' -Kind Value -Value 'Windows Update' -Detail 'Aucun serveur WSUS configuré') }

    $rebootItems = Get-DomeniaCategorySummary $rows 'Redemarrage en attente'
    if ($rebootItems.Read) {
        # The worker writes one 'Etat' row: 'Aucun redemarrage en attente' or 'Redemarrage requis : <reasons>'.
        $rebootState = [string]$rebootItems.State
        $pending = (($rebootItems.Count -gt 0) -or ($rebootState -like 'Redemarrage requis*'))
        if ($pending) { & $note 'Warn' 'Redemarrage en attente.' 'reboot' 'ComputerActions' 'Redémarrer : vue Intervenir' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.reboot' -Kind Value -Value $(if ($pending) { 'Oui' } else { 'Non' }) -Detail $(if ($rebootItems.Count) { [string]$rebootItems.Items[0].Item } else { $rebootState }) -State $(if ($pending) { 'Warn' } else { 'Ok' }))
    }

    # Stopped automatic services: those starting on a trigger or after a delay are expected (MO-06).
    if ($stoppedSummary.Read) {
        $firstStopped = if ($stoppedUnexpected.Count) { [string]$stoppedUnexpected[0].Item } else { '' }
        $expectedText = if ($stoppedExpected.Count) { [string]$stoppedExpected.Count + ' sur déclencheur ou différé(s), sans défaut' } else { '' }
        $stoppedDetail = if ($stoppedUnexpected.Count -gt 1) { $firstStopped + ' et ' + ($stoppedUnexpected.Count - 1) + ' autre(s)' } elseif ($stoppedUnexpected.Count) { $firstStopped } elseif ($expectedText) { $expectedText } elseif ($stoppedSummary.State) { [string]$stoppedSummary.State } else { 'Aucun' }
        if ($stoppedUnexpected.Count) { & $note 'Warn' ([string]$stoppedUnexpected.Count + ' service(s) automatique(s) arrêté(s).') 'services' }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.services.stopped' -Kind Value -Value ([string]$stoppedUnexpected.Count) -Detail $stoppedDetail -State $(if ($stoppedUnexpected.Count) { 'Warn' } else { 'Ok' }))
    }

    # Count tiles of one inventory category; Watch: any item is a point to watch, none is a good state.
    $checks = @(
        [pscustomobject]@{ Key = 'computer.devices'; Title = 'Peripheriques en erreur'; Category = 'Peripheriques en erreur'; Hint = 'Aucun'; Watch = $true }
        [pscustomobject]@{ Key = 'computer.drivers'; Title = 'Pilotes non signes'; Category = 'Pilotes non signes'; Hint = 'Aucun'; Watch = $true }
        [pscustomobject]@{ Key = 'computer.admins'; Title = 'Administrateurs locaux'; Category = 'Administrateurs locaux'; Hint = 'Groupe non lu'; Watch = $false }
        [pscustomobject]@{ Key = 'computer.sessions'; Title = 'Sessions et comptes locaux'; Category = 'Comptes et sessions'; Hint = 'Aucune'; Watch = $false }
        [pscustomobject]@{ Key = 'computer.autostart'; Title = 'Demarrage automatique'; Category = 'Demarrage automatique'; Hint = 'Aucun programme'; Watch = $false }
        [pscustomobject]@{ Key = 'computer.shares'; Title = 'Partages'; Category = 'Partages'; Hint = 'Aucun partage'; Watch = $false }
        [pscustomobject]@{ Key = 'computer.printers'; Title = 'Imprimantes'; Category = 'Imprimantes'; Hint = 'Aucune'; Watch = $false }
        [pscustomobject]@{ Key = 'computer.certificates'; Title = 'Certificats machine'; Category = 'Certificats machine'; Hint = 'Aucun'; Watch = $false }
    )
    foreach ($check in $checks) {
        $summary = Get-DomeniaCategorySummary $rows ([string]$check.Category)
        if ((-not $summary.Read) -and (-not $answered.ContainsKey([string]$check.Category))) { continue }
        $first = if ($summary.Count) { [string]$summary.Items[0].Item } else { '' }
        $checkDetail = if ($summary.Count -gt 1) { $first + ' et ' + ($summary.Count - 1) + ' autre(s)' } elseif ($summary.Count) { $first } elseif ($summary.State) { [string]$summary.State } else { [string]$check.Hint }
        $checkState = ''
        if ($check.Watch) {
            if ($summary.Count) { $checkState = 'Warn'; & $note 'Warn' ([string]$summary.Count + ' ' + ([string]$check.Title).ToLowerInvariant() + '.') ([string]$check.Key).Substring(9) } else { $checkState = 'Ok' }
        }
        Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key ([string]$check.Key) -Kind Value -Value $(if ($summary.Count) { [string]$summary.Count } else { '0' }) -Detail $checkDetail -State $checkState)
    }

    $display = Get-DomeniaCategorySummary $rows 'Affichage'
    if ($display.Count) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.display' -Kind Value -Value ([string]$display.Items[0].Item) -Detail ([string]$display.Items[0].Value)) }
    $physical = Get-DomeniaCategorySummary $rows 'Disques physiques'
    if ($physical.Count) { Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.physicaldisk' -Kind Value -Value ([string]$physical.Items[0].Item) -Detail ([string]$physical.Items[0].Value)) }

    # Latest hotfix: the most recent readable date (yyyy-MM-dd) among the installed hotfixes.
    $hotfixes = @(); if ($null -ne $metrics) { $hotfixes = @(@($metrics.Hotfixes) | Where-Object { ($null -ne $_) -and ([string]$_) }) }
    if ($hotfixes.Count) {
        $latest = $null
        foreach ($hotfix in $hotfixes) {
            $date = [datetime]::MinValue
            if ([datetime]::TryParseExact([string]$hotfix,'yyyy-MM-dd',$invariant,[Globalization.DateTimeStyles]::None,[ref]$date)) { if (($null -eq $latest) -or ($date -gt $latest)) { $latest = $date } }
        }
        if ($null -ne $latest) {
            $age = [int]([datetime]::Today - $latest).TotalDays
            $oldHotfix = ($age -gt 60)
            if ($oldHotfix) { & $note 'Warn' ('Dernier correctif installe il y a ' + $age + ' jours.') 'hotfix' }
            Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key 'computer.hotfix' -Kind Value -Value ('il y a ' + $age + ' j') -Detail ($latest.ToString('dd/MM/yyyy', $invariant) + ' · ' + $hotfixes.Count + ' correctifs') -State $(if ($oldHotfix) { 'Warn' } else { '' }))
        }
    }

    # -----------------------------------------------------------------------
    # Hints for the sections left without data, summary, health and attention
    # -----------------------------------------------------------------------
    $hintTexts = [ordered]@{
        'Identite du poste' = 'Lancez un inventaire (rapide ou complet) pour remplir cette section.'
        'Compte machine dans Active Directory' = 'Ouvrez la fiche du poste dans l annuaire pour lire son compte machine.'
        'Ressources' = $(if ($hasInventory -and ($null -eq $metrics)) { 'Mesures chiffrees indisponibles (inventaire par tache distante).' } elseif ($hasInventory) { 'Aucune mesure relevee pendant cet inventaire.' } else { 'Lancez un inventaire pour mesurer la memoire, le processeur et les disques.' })
        'Activite' = 'Non lu pendant cet inventaire : voir le détail par source. Lʼinventaire complet ajoute les processus et les erreurs système.'
        'Securite et etat' = 'Non lu pendant cet inventaire : voir le détail par source. Lʼinventaire complet ajoute les certificats machine.'
    }
    # SP-17: under an empty section, the button of the existing action that fills it, run only on its click.
    $quick = [pscustomobject]@{ Id = 'InventoryQuick'; Text = 'Inventaire rapide'; Tip = 'Lance lʼinventaire rapide du poste sélectionné (lecture seule), comme le bouton du tableau de bord.'; Link = $false }
    $full = [pscustomobject]@{ Id = 'InventoryFull'; Text = 'Inventaire complet'; Tip = 'Lance lʼinventaire complet du poste sélectionné (lecture seule, plus long), comme le bouton du tableau de bord.'; Link = $false }
    $hintActions = @{
        'Identite du poste' = $quick
        'Compte machine dans Active Directory' = [pscustomobject]@{ Id = 'OpenCard'; Text = 'Ouvrir la fiche'; Tip = 'Ouvre la fiche du poste déjà chargée, sans nouvelle lecture.'; Link = $false }
        'Activite' = $full
        'Securite et etat' = $full
    }
    if (-not $hasInventory) { $hintActions['Ressources'] = $quick }
    $filled = @{}
    foreach ($item in @(Get-DomeniaBoardCatalog -Board Computer)) { if ($Data.Entries.ContainsKey([string]$item.Key)) { $filled[[string]$item.Group] = $true } }
    foreach ($group in @($hintTexts.Keys)) {
        if ($filled.ContainsKey([string]$group)) { continue }
        $Data.Hints[[string]$group] = [string]$hintTexts[$group]
        if ($hintActions.ContainsKey([string]$group)) { $Data.HintActions[[string]$group] = $hintActions[[string]$group] }
    }

    # UX-23: without the firewall, BitLocker nor the antivirus, the score misses the security checks and says so.
    $securityRead = ($firewallProfiles.Count -gt 0) -and ($bitlocker.Count -gt 0) -and ($av.Count -gt 0)
    if (-not $securityRead) { $Data.Partial = [pscustomobject]@{ Text = 'Partiel : antivirus, pare-feu ou BitLocker non lu'; Action = $full } }

    if ($hasInventory) {
        $when = Get-Date; if ($At -is [datetime]) { $when = $At }
        $Data.Summary = 'Tableau de bord de l inventaire du ' + $when.ToString('dd/MM/yyyy HH:mm', $invariant) + '. ' + $(if ($null -eq $metrics) { 'Mesures chiffrees indisponibles (inventaire par tache distante) : seules les tuiles sont remplies.' } else { 'Données lues par CIM, sans nouvelle requête. Lʼinventaire complet ajoute les processus, les erreurs système, les tâches planifiées, les certificats et les connexions réseau.' })
    } else {
        $Data.Summary = 'Lancez un inventaire (rapide ou complet) : le tableau de bord se remplit avec ses résultats.'
    }
    $customDisk=$null;$customMemory=$null;$customUptime=$null
    if($null -ne $metrics){
        $system=@($metrics.Disks|Where-Object{$_.Name -ieq 'C:' -and [double]$_.Size -gt 0}|Select-Object -First 1)
        if($system.Count -and $null -ne $system[0].Free -and [double]$system[0].Free -ge 0 -and [double]$system[0].Free -le [double]$system[0].Size){$customDisk=100.0*[double]$system[0].Free/[double]$system[0].Size}
        if([double]$metrics.MemoryTotal -gt 0 -and $null -ne $metrics.MemoryFree -and [double]$metrics.MemoryFree -ge 0 -and [double]$metrics.MemoryFree -le [double]$metrics.MemoryTotal){$customMemory=100.0*(1-[double]$metrics.MemoryFree/[double]$metrics.MemoryTotal)}
    }
    if($uptime){$customUptime=$uptimeDays}
    Add-DomeniaCustomHealthAttention -Data $Data -Measures @([pscustomobject]@{DiskFree=$customDisk;MemoryUsed=$customMemory;UptimeDays=$customUptime})
    Complete-DomeniaBoardData -Data $Data | Out-Null
    return $Data
}
