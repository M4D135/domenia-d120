# Workstation and software dashboards (decision David 2026-10-07). They only use data already read by the
# inventory and software workers: no extra request to the workstation.
function Clear-DomeniaDashboards {
    foreach ($name in @('PnlComputerDashboard','PnlSoftwareDashboard')) { $panel = Get-DomeniaControl $name; if ($null -ne $panel) { $panel.Children.Clear() } }
    [void](Set-DomeniaControlText 'LblComputerDashboard' 'Lancez un inventaire (Rapide ou Complet) : le tableau de bord se remplit avec ses resultats.')
    [void](Set-DomeniaControlText 'LblSoftwareDashboard' 'Chargez les logiciels pour afficher la synthese.')
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
function Update-DomeniaComputerDashboard {
    param($Result)
    $panel = Get-DomeniaControl 'PnlComputerDashboard'
    if ($null -eq $panel) { return }
    $panel.Children.Clear()
    $rows = @($Result.Rows); $metrics = $Result.Metrics
    $value = { param([string]$Category,[string]$Item) Get-DomeniaInventoryValue $rows $Category $Item }
    $firstLike = { param([string]$Category,[string]$Suffix) foreach ($row in $rows) { if ([string]$row.Category -eq $Category -and ([string]$row.Item).EndsWith($Suffix)) { return [string]$row.Value } }; return '' }

    # Identity
    $wrap = New-DomeniaDashboardSection $panel 'Identite du poste'
    $osName = & $value 'Systeme d exploitation' 'Nom'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Systeme' -Value $(if ($osName) { $osName -replace '^Microsoft ','' } else { 'Non lu' }) -Detail ((& $value 'Systeme d exploitation' 'Version commerciale') + ' ' + (& $value 'Systeme d exploitation' 'Build')).Trim()))
    $model = & $value 'Systeme' 'Modele'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Modele' -Value $(if ($model) { $model } else { 'Non lu' }) -Detail ((& $value 'Systeme' 'Fabricant') + ' · serie ' + (& $value 'Systeme' 'Numero de serie chassis')).Trim(' ','·')))
    $cpu = & $firstLike 'Processeur' ' modele'
    $cores = & $firstLike 'Processeur' ' coeurs'; $threads = & $firstLike 'Processeur' ' processeurs logiques'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Processeur' -Value $(if ($cpu) { ($cpu -replace '\(R\)|\(TM\)|CPU','' -replace '\s+',' ').Trim() } else { 'Non lu' }) -Detail $(if ($cores) { $cores + ' coeurs, ' + $threads + ' threads' } else { '' })))
    $modules = @($rows | Where-Object { [string]$_.Category -eq 'Memoire' -and ([string]$_.Item).StartsWith('Barrette') }).Count
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Memoire installee' -Value $(if ($null -ne $metrics -and [double]$metrics.MemoryTotal -gt 0) { Format-DomeniaDashboardSize $metrics.MemoryTotal } else { & $value 'Memoire' 'Total installe' }) -Detail $(if ($modules) { [string]$modules + ' barrette(s)' } else { '' })))
    $uptime = & $value 'Systeme d exploitation' 'Duree de fonctionnement'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'En service depuis' -Value $(if ($uptime) { $uptime } else { 'Non lu' }) -Detail ('Demarre le ' + (& $value 'Systeme d exploitation' 'Dernier demarrage'))))
    $user = & $value 'Systeme' 'Utilisateur connecte'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Utilisateur connecte' -Value $(if ($user) { $user } else { 'Aucun' }) -Detail 'Console, au moment de l inventaire'))
    $ip = & $firstLike 'Reseau' ' adresses IP'
    [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Adresse IP' -Value $(if ($ip) { ($ip -split '[,; ]+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1) } else { 'Non lue' }) -Detail ('Passerelle ' + (& $firstLike 'Reseau' ' passerelle'))))
    $domain = & $value 'Systeme' 'Domaine'
    if ($domain) { [void]$wrap.Children.Add((New-DomeniaKpiTile -Title 'Domaine' -Value $domain -Detail (& $value 'Systeme' 'Role dans le domaine'))) }

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
    $connections = Get-DomeniaCategorySummary $rows 'Connexions reseau'
    if ($connections.Count) {
        $peers = @($connections.Items | ForEach-Object { if ([string]$_.Value -match 'vers (?<peer>[^,]+):\d+') { $Matches.peer } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Name; Value = [double]$_.Count } })
        [void]$wrap.Children.Add((New-DomeniaBarChart -Title ('A qui parle ce poste (' + $connections.Count + ' connexions etablies)') -Items $peers -Width 420))
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
