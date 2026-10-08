# Dashboards made of widgets (decision David 2026-10-07): every tile and chart of the fleet, workstation and
# software dashboards is a widget that can be edited, resized, moved or removed; new ones come from the
# built-in catalog or from the ready-made WMI queries. Pure rules: catalog, data contract, allowed
# representations per kind of data, sizes and layout operations. No WPF, no network, no disk.

$script:DomeniaBoardCatalogText = @{
    Computer = @'
computer.health|Vue d ensemble|Etat general|Health|Health|S|Score calcule a partir des points d attention
computer.attention|Vue d ensemble|Points d attention|List|List|L|Problemes detectes, du plus grave au moins grave
computer.os|Identite du poste|Systeme|Value|Kpi|S|Version commerciale de Windows et build
computer.model|Identite du poste|Modele|Value|Kpi|S|Fabricant, modele et numero de serie
computer.cpu|Identite du poste|Processeur|Value|Kpi|S|Modele, coeurs et threads
computer.memory|Identite du poste|Memoire installee|Value|Kpi|S|Memoire physique et barrettes
computer.uptime|Identite du poste|En service depuis|Value|Kpi|S|Duree depuis le dernier demarrage
computer.user|Identite du poste|Utilisateur connecte|Value|Kpi|S|Session console au moment de l inventaire
computer.ip|Identite du poste|Adresse IP|Value|Kpi|S|Adresse IPv4 et passerelle
computer.domain|Identite du poste|Domaine|Value|Kpi|S|Domaine et role du poste
computer.ad.password|Compte machine dans Active Directory|Mot de passe machine|Value|Kpi|S|Age du mot de passe du compte ordinateur
computer.ad.lastlogon|Compte machine dans Active Directory|Derniere connexion au domaine|Value|Kpi|S|Attribut lastLogonTimestamp
computer.ad.account|Compte machine dans Active Directory|Compte ordinateur|Value|Kpi|S|Actif ou desactive, date de creation
computer.ad.ou|Compte machine dans Active Directory|Unite d organisation|Value|Kpi|S|OU qui contient le poste
computer.ad.laps|Compte machine dans Active Directory|Mot de passe LAPS|Value|Kpi|S|Expiration du mot de passe administrateur local
computer.ad.managedby|Compte machine dans Active Directory|Gere par|Value|Kpi|S|Attribut managedBy
computer.ad.clock|Compte machine dans Active Directory|Horloge du poste|Value|Kpi|S|Ecart avec le poste d administration
computer.memory.usage|Ressources|Memoire utilisee|Number|Gauge|S|Memoire occupee au moment de l inventaire
computer.cpu.load|Ressources|Charge du processeur|Number|Gauge|S|Charge du processeur au moment de l inventaire
computer.battery|Ressources|Batterie|Number|Gauge|S|Charge restante des postes portables
computer.disk.system|Ressources|Disque systeme|Distribution|Pie|M|Espace utilise et libre sur C:
computer.disk.volumes|Ressources|Autres volumes|Distribution|Bar|M|Espace libre des autres volumes, en pourcentage
computer.services|Activite|Services Windows|Distribution|Pie|M|Services en cours, arretes et desactives
computer.processes|Activite|Processus les plus gourmands|Distribution|Bar|L|Memoire utilisee par processus, en Mo
computer.events|Activite|Erreurs systeme par source|Distribution|Bar|M|Journal Systeme des 3 derniers jours
computer.antivirus|Securite et etat|Antivirus|Value|Kpi|S|Produit antivirus declare a Windows
computer.firewall|Securite et etat|Pare-feu|Value|Kpi|S|Profils du pare-feu actifs
computer.bitlocker|Securite et etat|BitLocker|Value|Kpi|S|Protection du volume systeme
computer.wsus|Securite et etat|Windows Update|Value|Kpi|S|Serveur WSUS configure
computer.reboot|Securite et etat|Redemarrage en attente|Value|Kpi|S|Redemarrage demande par une installation
computer.services.stopped|Securite et etat|Services automatiques arretes|Value|Kpi|S|Services automatiques a l arret
computer.devices|Securite et etat|Peripheriques en erreur|Value|Kpi|S|Peripheriques signales en erreur
computer.drivers|Securite et etat|Pilotes non signes|Value|Kpi|S|Pilotes sans signature numerique
computer.admins|Securite et etat|Administrateurs locaux|Value|Kpi|S|Membres du groupe Administrateurs
computer.sessions|Securite et etat|Sessions et comptes locaux|Value|Kpi|S|Comptes et sessions du poste
computer.autostart|Securite et etat|Demarrage automatique|Value|Kpi|S|Programmes lances au demarrage
computer.shares|Securite et etat|Partages|Value|Kpi|S|Dossiers partages par le poste
computer.printers|Securite et etat|Imprimantes|Value|Kpi|S|Imprimantes installees
computer.display|Securite et etat|Affichage|Value|Kpi|S|Carte graphique et resolution
computer.physicaldisk|Securite et etat|Disque physique|Value|Kpi|S|Modele et interface du disque
computer.certificates|Securite et etat|Certificats machine|Value|Kpi|S|Certificats du magasin ordinateur
computer.hotfix|Securite et etat|Dernier correctif|Value|Kpi|S|Date du dernier correctif installe
'@
    Fleet = @'
fleet.health|Vue d ensemble|Etat du parc|Health|Health|S|Score calcule a partir des points d attention
fleet.attention|Vue d ensemble|Points d attention|List|List|L|Problemes detectes sur le perimetre
fleet.machines|Inventaire du perimetre|Postes actifs|Value|Kpi|S|Comptes ordinateur actifs du perimetre
fleet.stale|Inventaire du perimetre|Postes inactifs (90 j et plus)|Value|Kpi|S|Sans connexion au domaine depuis 90 jours
fleet.win10|Inventaire du perimetre|Postes sous Windows 10|Value|Kpi|S|Fin de support le 14/10/2025
fleet.users|Inventaire du perimetre|Utilisateurs detectes|Value|Kpi|S|Utilisateurs vus sur les postes
fleet.lastcheck|Inventaire du perimetre|Derniere analyse|Value|Kpi|S|Date du dernier releve des postes
fleet.os|Repartition|Systemes d exploitation|Distribution|Pie|M|Systemes declares dans l annuaire
fleet.lastlogon|Repartition|Derniere connexion au domaine|Series|Column|M|Anciennete de la derniere connexion
fleet.ou|Repartition|Postes par unite d organisation|Distribution|Bar|M|Postes par OU ou sous-OU
fleet.presence|Repartition|Presence reseau|Distribution|Pie|M|Resultat des derniers releves
fleet.models|Releves WMI|Modeles|Distribution|Bar|M|Modeles des postes analyses
fleet.releases|Releves WMI|Versions de Windows|Distribution|Pie|M|Versions commerciales relevees
fleet.ram|Releves WMI|Memoire installee|Series|Column|M|Postes par quantite de memoire
fleet.diskfree|Releves WMI|Espace libre sur C:|Series|Column|M|Postes par espace libre du disque systeme
fleet.lowdisk|Releves WMI|Disque C: presque plein|Value|Kpi|S|Postes avec moins de 10 % libre
fleet.uptime|Releves WMI|Non redemarres depuis 30 j|Value|Kpi|S|Postes a redemarrer
'@
    Software = @'
software.count|Synthese|Logiciels|Value|Kpi|S|Nombre de logiciels et d editeurs
software.size|Synthese|Taille declaree|Value|Kpi|S|Somme des tailles connues
software.multiversion|Synthese|Installes en plusieurs versions|Value|Kpi|S|Logiciels presents en plusieurs versions
software.nopublisher|Synthese|Sans editeur declare|Value|Kpi|S|Logiciels sans editeur renseigne
software.publishers|Repartition|Editeurs|Distribution|Pie|M|Principaux editeurs
software.architecture|Repartition|Architecture|Distribution|Pie|M|Logiciels 32 et 64 bits
software.scope|Repartition|Portee d installation|Distribution|Pie|M|Installation machine ou utilisateur
software.largest|Repartition|Plus gros logiciels|Distribution|Bar|L|Taille declaree, en Mo
'@
}

function Get-DomeniaBoardCatalog {
    # Built-in widgets of a board, in their default order.
    param([Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board)
    $rows = New-Object System.Collections.ArrayList
    foreach ($line in ([string]$script:DomeniaBoardCatalogText[$Board] -split "`n")) {
        $text = $line.Trim()
        if (-not $text) { continue }
        $cells = $text -split '\|'
        if ($cells.Count -lt 7) { continue }
        [void]$rows.Add([pscustomobject]@{ Key = $cells[0]; Group = $cells[1]; Title = $cells[2]; Kind = $cells[3]; Visual = $cells[4]; Size = $cells[5]; Description = $cells[6] })
    }
    return @($rows)
}
function Get-DomeniaBoardCatalogItem {
    param([string]$Board,[string]$Key)
    foreach ($item in @(Get-DomeniaBoardCatalog -Board $Board)) { if ($item.Key -eq $Key) { return $item } }
    return $null
}

# ---------------------------------------------------------------------------
# Shared helpers (pure): pastel meaning colours, sizes, Windows releases
# ---------------------------------------------------------------------------
function Get-DomeniaBoardColor {
    # Pastel meaning colours for shapes (rings, bars) on the light and dark themes (decision David 2026-10-07).
    param([string]$Name)
    switch ($Name) { 'Ok' { return '#86EFAC' } 'Warn' { return '#FCD34D' } 'Alert' { return '#FCA5A5' } 'Off' { return '#CBD5E1' } 'Info' { return '#93C5FD' } 'Used' { return '#93C5FD' } default { return '' } }
}
function Format-DomeniaDashboardSize {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:0.#} To' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:0.#} Go' -f ($Bytes / 1GB)) }
    return ('{0:0} Mo' -f ($Bytes / 1MB))
}
function Get-DomeniaWindowsRelease {
    # Release name from the build number. Only Windows 10 carries an end-of-support note (14/10/2025).
    # Servers share their builds with Windows 11: a caption naming a server gives the server release
    # (real case 2026-10-07: CNAMTS-DC01, Windows Server 2025, build 26100, was shown as Windows 11 24H2).
    param([string]$Build,[string]$Caption = '')
    $names = @{ '26200'='Windows 11 25H2'; '26100'='Windows 11 24H2'; '22631'='Windows 11 23H2'; '22621'='Windows 11 22H2'; '22000'='Windows 11 21H2'; '19045'='Windows 10 22H2'; '19044'='Windows 10 21H2'; '19043'='Windows 10 21H1' }
    $servers = @{ '26100'='Windows Server 2025'; '20348'='Windows Server 2022'; '17763'='Windows Server 2019'; '14393'='Windows Server 2016' }
    $key = ([string]$Build).Trim()
    if ($Caption -match '(?i)server') {
        $name = [string]$servers[$key]
        if (-not $name) { $name = (($Caption -replace '(?i)^Microsoft\s+','') -replace '(?i)\s+(Standard|Datacenter|Essentials|Evaluation).*$','').Trim() }
        if ($name -notlike 'Windows*') { $name = 'Windows Server' }
        return [pscustomobject]@{ Name = $name; Note = $(if ($key) { 'Build ' + $key } else { '' }) }
    }
    $name = [string]$names[$key]
    $note = if ($name -like 'Windows 10*') { 'Fin de support le 14/10/2025 : a migrer' } elseif ($name) { 'Build ' + $Build } else { '' }
    return [pscustomobject]@{ Name = $name; Note = $note }
}

# ---------------------------------------------------------------------------
# Data contract shared by the providers and the renderer
# ---------------------------------------------------------------------------
function New-DomeniaBoardEntry {
    # Value: one text. Number: a measure with an optional maximum (gauge). Distribution: parts of a whole.
    # Measure: numeric values gathered in buckets. Series: ordered buckets. List: Level/Text lines. Health: score.
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('Value','Number','Distribution','Measure','Series','List','Health')][string]$Kind,
        [string]$Title = '',
        [string]$Value = '',
        [string]$Detail = '',
        [ValidateSet('','Ok','Warn','Alert','Off')][string]$State = '',
        [object[]]$Items = @(),
        $Number = $null,
        $Maximum = $null,
        [string]$Unit = '',
        [switch]$LowIsBad,
        [string]$CenterText = ''
    )
    return [pscustomobject]@{ Key = $Key; Kind = $Kind; Title = $Title; Value = $Value; Detail = $Detail; State = $State; Items = @($Items | Where-Object { $null -ne $_ }); Number = $Number; Maximum = $Maximum; Unit = $Unit; LowIsBad = [bool]$LowIsBad; CenterText = $CenterText }
}
function New-DomeniaBoardData {
    # What a provider returns: entries by key, attention points, hints for empty sections, a summary line.
    param([Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board)
    return [pscustomobject]@{ Board = $Board; Entries = @{}; Attention = New-Object System.Collections.ArrayList; Hints = @{}; Summary = '' }
}
function Add-DomeniaBoardEntry {
    param([Parameter(Mandatory=$true)]$Data,$Entry)
    if ($null -eq $Entry) { return }
    $Data.Entries[[string]$Entry.Key] = $Entry
}
function Add-DomeniaBoardAttention {
    param([Parameter(Mandatory=$true)]$Data,[ValidateSet('Alert','Warn','Info')][string]$Level,[string]$Text)
    if (-not $Text) { return }
    [void]$Data.Attention.Add([pscustomobject]@{ Level = $Level; Text = $Text })
}
function Get-DomeniaBoardHealth {
    # 100 minus 25 per critical point and 10 per point to watch; information lines do not count.
    param([object[]]$Attention = @())
    $alerts = @($Attention | Where-Object { $null -ne $_ -and [string]$_.Level -eq 'Alert' }).Count
    $warnings = @($Attention | Where-Object { $null -ne $_ -and [string]$_.Level -eq 'Warn' }).Count
    $score = [Math]::Max(0, 100 - 25 * $alerts - 10 * $warnings)
    $verdict = if ($alerts) { 'Critique' } elseif ($score -ge 85) { 'Bon etat' } elseif ($score -ge 60) { 'A surveiller' } else { 'Degrade' }
    $state = if ($alerts -or $score -lt 60) { 'Alert' } elseif ($warnings) { 'Warn' } else { 'Ok' }
    return [pscustomobject]@{ Score = $score; Verdict = $verdict; State = $state; Alerts = $alerts; Warnings = $warnings }
}
function Complete-DomeniaBoardData {
    # Adds the health and attention entries computed from every check, whether its widget is shown or not.
    param([Parameter(Mandatory=$true)]$Data)
    $prefix = ([string]$Data.Board).ToLowerInvariant()
    $attention = @($Data.Attention)
    $health = Get-DomeniaBoardHealth -Attention $attention
    $detail = if ($health.Alerts -or $health.Warnings) { @($(if ($health.Alerts) { [string]$health.Alerts + ' critique(s)' }), $(if ($health.Warnings) { [string]$health.Warnings + ' a surveiller' })) -join ' · ' } else { 'Aucun point a verifier' }
    Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key ($prefix + '.health') -Kind Health -Value $health.Verdict -Detail $detail.Trim(' ','·') -State $health.State -Number $health.Score -Maximum 100)
    $sorted = @(@($attention | Where-Object { $_.Level -eq 'Alert' }) + @($attention | Where-Object { $_.Level -eq 'Warn' }) + @($attention | Where-Object { $_.Level -notin @('Alert','Warn') }))
    $title = if ($health.Alerts + $health.Warnings) { [string]($health.Alerts + $health.Warnings) + ' point(s) a verifier' } else { 'Rien a signaler' }
    Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key ($prefix + '.attention') -Kind List -Title $title -Value $title -Detail $detail.Trim(' ','·') -State $health.State -Items $sorted)
    return $Data
}

# ---------------------------------------------------------------------------
# Representations and sizes
# ---------------------------------------------------------------------------
function Get-DomeniaBoardVisualNames {
    return [ordered]@{ Kpi = 'Chiffre cle'; Gauge = 'Jauge'; Pie = 'Anneau'; Bar = 'Barres'; Column = 'Histogramme'; Line = 'Courbe'; Text = 'Liste'; List = 'Liste de points'; Health = 'Score' }
}
function Get-DomeniaBoardVisuals {
    # Representations that make sense for a kind of data (decision David 2026-10-07), preferred first.
    param([string]$Kind,[switch]$HasMaximum)
    switch ($Kind) {
        'Value' { return @('Kpi','Text') }
        'Number' { if ($HasMaximum) { return @('Gauge','Kpi','Text') }; return @('Kpi','Text') }
        'Distribution' { return @('Pie','Bar','Column','Text','Kpi') }
        'Measure' { return @('Column','Bar','Line','Kpi','Text') }
        'Series' { return @('Column','Line','Bar','Text','Kpi') }
        'List' { return @('List') }
        'Health' { return @('Health','Kpi') }
        default { return @('Kpi','Text') }
    }
}
function Resolve-DomeniaBoardVisual {
    # The stored representation when it is still allowed for the data, otherwise the preferred one.
    param([string]$Visual,[string]$Kind,[switch]$HasMaximum)
    $allowed = @(Get-DomeniaBoardVisuals -Kind $Kind -HasMaximum:$HasMaximum)
    if ($Visual -in $allowed) { return $Visual }
    return $allowed[0]
}
function Get-DomeniaBoardSizeNames {
    return [ordered]@{ S = 'Compacte'; M = 'Moyenne'; L = 'Large' }
}
function Get-DomeniaBoardSize {
    # Width, height (0 = fits its content) and minimum height. Tall cards share one height (250) and two
    # compact tiles stacked (2 x 118 + margins) line up with them.
    param([string]$Visual,[string]$Size = 'M')
    $table = @{
        Kpi = @{ S = @(230,118,0); M = @(345,118,0); L = @(475,118,0) }
        Text = @{ S = @(300,0,118); M = @(420,0,250); L = @(560,0,250) }
        Pie = @{ S = @(310,250,0); M = @(390,250,0); L = @(490,250,0) }
        Bar = @{ S = @(320,250,0); M = @(440,250,0); L = @(600,250,0) }
        Column = @{ S = @(320,250,0); M = @(440,250,0); L = @(600,250,0) }
        Line = @{ S = @(320,250,0); M = @(440,250,0); L = @(600,250,0) }
        Gauge = @{ S = @(230,250,0); M = @(300,250,0); L = @(380,250,0) }
        List = @{ S = @(380,0,250); M = @(500,0,250); L = @(660,0,250) }
        Health = @{ S = @(230,250,0); M = @(300,250,0); L = @(380,250,0) }
    }
    $sizes = $table[$Visual]; if ($null -eq $sizes) { $sizes = $table['Kpi'] }
    $chosen = $sizes[$Size]; if ($null -eq $chosen) { $chosen = $sizes['M'] }
    return [pscustomobject]@{ Width = [double]$chosen[0]; Height = [double]$chosen[1]; MinHeight = [double]$chosen[2] }
}

# ---------------------------------------------------------------------------
# Layout: ordered items {Id, Source, Key, Visual, Title, Size, Group}
# ---------------------------------------------------------------------------
function New-DomeniaBoardItemId {
    param([string]$Seed = '')
    return ([guid]::NewGuid().ToString('N')).Substring(0, 10)
}
function New-DomeniaBoardItem {
    param([ValidateSet('Builtin','Probe')][string]$Source,[string]$Key,[string]$Visual,[string]$Size = '',[string]$Group = '',[string]$Title = '',[string]$Id = '')
    if (-not $Id) { $Id = New-DomeniaBoardItemId }
    return [pscustomobject]@{ Id = $Id; Source = $Source; Key = $Key; Visual = $Visual; Title = $Title; Size = $Size; Group = $Group }
}
function Get-DomeniaBoardDefaultLayout {
    param([Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board)
    return @(Get-DomeniaBoardCatalog -Board $Board | ForEach-Object { New-DomeniaBoardItem -Source Builtin -Key $_.Key -Visual $_.Visual -Size $_.Size -Group $_.Group -Id ('b-' + $_.Key) })
}
function ConvertTo-DomeniaBoardLayout {
    # Stored text (JSON) to a clean layout: unknown widgets dropped, representations and sizes corrected, ids unique.
    # The widgets of the first version (separate "Widgets" part) are kept, in a section named after their category.
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board,
        [string]$Json = '',
        [object[]]$LegacyWidgets = @(),
        [object[]]$ProbeCatalog = @()
    )
    $stored = $null
    # ConvertFrom-Json (5.1) emits a JSON array as a single object: assigned first, then wrapped.
    if (-not [string]::IsNullOrWhiteSpace($Json)) { try { $parsed = ConvertFrom-Json -InputObject $Json; $stored = @($parsed) } catch { $stored = $null } }
    # Nothing stored: the delivered layout. A stored empty list ('[]') is a board emptied on purpose and stays empty.
    $items = if ($null -eq $stored) { @(Get-DomeniaBoardDefaultLayout -Board $Board) } else { @($stored) }
    foreach ($legacy in @($LegacyWidgets)) {
        if ($null -eq $legacy -or $null -eq $legacy.PSObject.Properties['ProbeId']) { continue }
        $category = 'Requetes'
        foreach ($probe in @($ProbeCatalog)) { if ([string]$probe.Id -eq [string]$legacy.ProbeId) { $category = [string]$probe.Category } }
        $title = if ($null -ne $legacy.PSObject.Properties['Title']) { [string]$legacy.Title } else { '' }
        $id = if ($null -ne $legacy.PSObject.Properties['Id'] -and [string]$legacy.Id) { 'p-' + [string]$legacy.Id } else { '' }
        $visual = if ($null -ne $legacy.PSObject.Properties['Visual']) { [string]$legacy.Visual } else { 'Kpi' }
        $items += New-DomeniaBoardItem -Source Probe -Key ([string]$legacy.ProbeId) -Visual $visual -Group $category -Title $title -Id $id
    }
    $catalog = @{}; foreach ($item in @(Get-DomeniaBoardCatalog -Board $Board)) { $catalog[$item.Key] = $item }
    $probes = @{}; foreach ($probe in @($ProbeCatalog)) { $probes[[string]$probe.Id] = $probe }
    $seen = @{}
    $clean = New-Object System.Collections.ArrayList
    foreach ($raw in $items) {
        if ($null -eq $raw) { continue }
        $get = { param([string]$Name) if ($null -ne $raw.PSObject.Properties[$Name] -and $null -ne $raw.$Name) { [string]$raw.$Name } else { '' } }
        $source = & $get 'Source'; $key = & $get 'Key'
        if ($source -eq 'Builtin') {
            if (-not $catalog.ContainsKey($key)) { continue }
            $kind = [string]$catalog[$key].Kind
            $group = & $get 'Group'; if (-not $group) { $group = [string]$catalog[$key].Group }
            $defaultSize = [string]$catalog[$key].Size
        } elseif ($source -eq 'Probe') {
            if ($probes.Count -and -not $probes.ContainsKey($key)) { continue }
            $kind = Get-DomeniaProbeKind -Probe $probes[$key] -Board $Board
            $group = & $get 'Group'; if (-not $group) { $group = if ($probes.ContainsKey($key)) { [string]$probes[$key].Category } else { 'Requetes' } }
            $defaultSize = ''
        } else { continue }
        $id = & $get 'Id'; if (-not $id -or $seen.ContainsKey($id)) { $id = New-DomeniaBoardItemId }
        $seen[$id] = $true
        $visual = Resolve-DomeniaBoardVisual -Visual (& $get 'Visual') -Kind $kind -HasMaximum:($kind -in @('Number','Health'))
        $size = & $get 'Size'; if ($size -notin @('S','M','L')) { $size = if ($defaultSize) { $defaultSize } elseif ($visual -eq 'Kpi') { 'S' } else { 'M' } }
        [void]$clean.Add((New-DomeniaBoardItem -Source $source -Key $key -Visual $visual -Size $size -Group $group -Title (& $get 'Title') -Id $id))
    }
    return @($clean)
}
function ConvertTo-DomeniaBoardLayoutJson {
    param([object[]]$Layout = @())
    $plain = @($Layout | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Source = [string]$_.Source; Key = [string]$_.Key; Visual = [string]$_.Visual; Title = [string]$_.Title; Size = [string]$_.Size; Group = [string]$_.Group } })
    if (-not $plain.Count) { return '[]' }
    return (ConvertTo-Json -InputObject $plain -Depth 3 -Compress)
}
function Get-DomeniaBoardGroups {
    # Sections in the order of their first widget.
    param([object[]]$Layout = @())
    # Compared without case, like every other section test (-eq).
    $groups = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($item in @($Layout)) { if ($null -ne $item -and [string]$item.Group -and -not $seen.ContainsKey([string]$item.Group)) { $seen[[string]$item.Group] = $true; [void]$groups.Add([string]$item.Group) } }
    return @($groups)
}
function Add-DomeniaBoardItem {
    # New widget at the end of its section (or of the board when the section is new).
    param([object[]]$Layout = @(),[Parameter(Mandatory=$true)]$Item)
    $list = New-Object System.Collections.ArrayList
    $inserted = $false
    $items = @($Layout | Where-Object { $null -ne $_ })
    for ($i = 0; $i -lt $items.Count; $i++) {
        [void]$list.Add($items[$i])
        $last = ($i -eq $items.Count - 1) -or ([string]$items[$i + 1].Group -ne [string]$items[$i].Group)
        if (-not $inserted -and [string]$items[$i].Group -eq [string]$Item.Group -and $last) { [void]$list.Add($Item); $inserted = $true }
    }
    if (-not $inserted) { [void]$list.Add($Item) }
    return @($list)
}
function Remove-DomeniaBoardItem {
    param([object[]]$Layout = @(),[string]$Id)
    return @($Layout | Where-Object { $null -ne $_ -and [string]$_.Id -ne $Id })
}
function Update-DomeniaBoardItem {
    # Changes some fields (Visual, Title, Size, Group) of one widget; a widget moved to another section goes to its end.
    param([object[]]$Layout = @(),[string]$Id,[hashtable]$Changes = @{})
    $target = $null
    foreach ($item in @($Layout)) { if ($null -ne $item -and [string]$item.Id -eq $Id) { $target = $item } }
    if ($null -eq $target) { return @($Layout) }
    $updated = New-DomeniaBoardItem -Source ([string]$target.Source) -Key ([string]$target.Key) -Visual ([string]$target.Visual) -Size ([string]$target.Size) -Group ([string]$target.Group) -Title ([string]$target.Title) -Id ([string]$target.Id)
    foreach ($name in @('Visual','Title','Size','Group')) { if ($Changes.ContainsKey($name)) { $updated.$name = [string]$Changes[$name] } }
    if ([string]$updated.Group -ne [string]$target.Group) { return @(Add-DomeniaBoardItem -Layout @(Remove-DomeniaBoardItem -Layout $Layout -Id $Id) -Item $updated) }
    return @($Layout | ForEach-Object { if ($null -ne $_ -and [string]$_.Id -eq $Id) { $updated } else { $_ } })
}
function Move-DomeniaBoardItem {
    # Before another widget (and into its section), or one step back/forward inside the section.
    # -Onto: dropped on another widget, it takes that widget's place (after it when dragged forward, before it when dragged back).
    param([object[]]$Layout = @(),[string]$Id,[string]$Before = '',[ValidateSet('','Back','Forward','First','Last')][string]$Step = '',[string]$Onto = '')
    $items = New-Object System.Collections.ArrayList
    foreach ($item in @($Layout)) { if ($null -ne $item) { [void]$items.Add($item) } }
    $index = -1; for ($i = 0; $i -lt $items.Count; $i++) { if ([string]$items[$i].Id -eq $Id) { $index = $i } }
    if ($index -lt 0) { return @($items) }
    $moving = $items[$index]
    if ($Onto) {
        if ($Onto -eq $Id) { return @($items) }
        $targetIndex = -1; for ($i = 0; $i -lt $items.Count; $i++) { if ([string]$items[$i].Id -eq $Onto) { $targetIndex = $i } }
        if ($targetIndex -lt 0) { return @($items) }
        $target = $items[$targetIndex]
        $items.RemoveAt($index)
        $moving = New-DomeniaBoardItem -Source ([string]$moving.Source) -Key ([string]$moving.Key) -Visual ([string]$moving.Visual) -Size ([string]$moving.Size) -Group ([string]$target.Group) -Title ([string]$moving.Title) -Id ([string]$moving.Id)
        $place = $items.IndexOf($target)
        if ($index -lt $targetIndex) { $place++ }
        $items.Insert($place, $moving)
        return @($items)
    }
    if ($Before) {
        if ($Before -eq $Id) { return @($items) }
        $target = $null; foreach ($item in $items) { if ([string]$item.Id -eq $Before) { $target = $item } }
        if ($null -eq $target) { return @($items) }
        $items.RemoveAt($index)
        $moving = New-DomeniaBoardItem -Source ([string]$moving.Source) -Key ([string]$moving.Key) -Visual ([string]$moving.Visual) -Size ([string]$moving.Size) -Group ([string]$target.Group) -Title ([string]$moving.Title) -Id ([string]$moving.Id)
        $items.Insert($items.IndexOf($target), $moving)
        return @($items)
    }
    $group = [string]$moving.Group
    $positions = @(for ($i = 0; $i -lt $items.Count; $i++) { if ([string]$items[$i].Group -eq $group) { $i } })
    $place = [Array]::IndexOf($positions, $index)
    $goal = switch ($Step) { 'Back' { $place - 1 } 'Forward' { $place + 1 } 'First' { 0 } 'Last' { $positions.Count - 1 } default { $place } }
    $goal = [Math]::Max(0, [Math]::Min($positions.Count - 1, $goal))
    if ($goal -eq $place) { return @($items) }
    $items.RemoveAt($index)
    $items.Insert($positions[$goal], $moving)
    return @($items)
}

# ---------------------------------------------------------------------------
# Ready-made WMI queries as widgets
# ---------------------------------------------------------------------------
function Get-DomeniaProbeKind {
    # One workstation: a value. Several: a share of text values, or numeric values gathered in buckets.
    param($Probe,[string]$Board = 'Fleet')
    if ($Board -eq 'Computer') { return 'Value' }
    if ($null -eq $Probe) { return 'Distribution' }
    # A count turned into words by a Map transform (Oui/Non...) is a share of text values, not a measure.
    $numeric = ([string]$Probe.Transform -notlike 'Map:*') -and (([string]$Probe.Mode -eq 'Count') -or ([string]$Probe.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree)$'))
    if ($numeric) { return 'Measure' }
    return 'Distribution'
}
function Get-DomeniaProbeUnit {
    param($Probe)
    if ($null -eq $Probe) { return '' }
    switch -Regex ([string]$Probe.Transform) { '^PercentFree$' { return ' %' } '^GB' { return ' Go' } '^MB$' { return ' Mo' } '^DaysSince$' { return ' j' } '^Mbps$' { return ' Mbit/s' } default { return '' } }
}
function ConvertFrom-DomeniaProbeMeasure {
    # A measured query (Measure-DomeniaWidgetData) as a board entry.
    param($Probe,$Measured,[string]$Board = 'Fleet',[string]$Key = '')
    if (-not $Key -and $null -ne $Probe) { $Key = [string]$Probe.Id }
    $kind = Get-DomeniaProbeKind -Probe $Probe -Board $Board
    $unit = Get-DomeniaProbeUnit -Probe $Probe
    if ($null -eq $Measured -or -not [int]$Measured.Machines) {
        # Fleet queries run from Rechercher on the displayed workstations (decision David 2026-10-08).
        $how = if ($Board -eq 'Fleet') { 'Dans Rechercher, Analyser la liste remplit ce widget' } else { 'Actualiser les requetes pour remplir ce widget' }
        return New-DomeniaBoardEntry -Key $Key -Kind $kind -Value 'En attente' -Detail $how -State 'Off'
    }
    $items = @($Measured.Items)
    if ($kind -eq 'Value') {
        # The measured values themselves, not the buckets used to draw a fleet ('<= 4', '4-8'...).
        $values = @(@($Measured.Values) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
        if (-not $values.Count) { $values = @($items | ForEach-Object { [string]$_.Label } | Where-Object { $_ }) }
        $items = @($values | ForEach-Object { [pscustomobject]@{ Label = $_; Value = 1 } })
        $value = if ($values.Count) { $values[0] } else { 'Aucune valeur' }
        if ($Measured.Numeric -and $value -match '^-?\d+([.,]\d+)?$') { $value = $value.Replace('.', ',') + $unit }
        $detail = if ($values.Count -gt 1) { [string]$values.Count + ' valeurs : ' + (($values | Select-Object -First 3) -join ', ') } else { [string]$Probe.Category + ' · ' + [string]$Probe.Name }
        return New-DomeniaBoardEntry -Key $Key -Kind Value -Value $value -Detail $detail -Items @($items | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Label; Value = [double]$_.Value } })
    }
    $title = [string]$Probe.Name + ' (' + [int]$Measured.Machines + ' postes)'
    if ($kind -eq 'Measure') {
        $sum = 0.0; $count = 0; $min = [double]::MaxValue; $max = [double]::MinValue
        foreach ($v in @($Measured.Values)) { $d = 0.0; if ([double]::TryParse([string]$v,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d)) { $sum += $d; $count++; if ($d -lt $min) { $min = $d }; if ($d -gt $max) { $max = $d } } }
        $value = if ($count) { ([Math]::Round($sum / $count, 1)).ToString([Globalization.CultureInfo]::GetCultureInfo('fr-FR')) + $unit } else { 'Aucune valeur' }
        $detail = if ($count) { 'Moyenne · min ' + ([Math]::Round($min, 1)).ToString([Globalization.CultureInfo]::GetCultureInfo('fr-FR')) + ' · max ' + ([Math]::Round($max, 1)).ToString([Globalization.CultureInfo]::GetCultureInfo('fr-FR')) } else { [string]$Measured.Summary }
        return New-DomeniaBoardEntry -Key $Key -Kind Measure -Title $title -Value $value -Detail $detail -Items $items -Unit $unit.Trim()
    }
    $top = @($items | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 1)
    $value = if ($top.Count) { [string]$top[0].Label } else { 'Aucune valeur' }
    $detail = if ($top.Count) { [string][int]$top[0].Value + ' poste(s) sur ' + [int]$Measured.Machines } else { [string]$Measured.Summary }
    return New-DomeniaBoardEntry -Key $Key -Kind Distribution -Title $title -Value $value -Detail $detail -Items $items -CenterText ([string][int]$Measured.Machines + ' postes')
}
function ConvertTo-DomeniaSearchText {
    # Lower case without accents: 'Memoire' is found by 'mémoire' and the other way round.
    param([string]$Text)
    $decomposed = ([string]$Text).ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$builder.Append($ch) } }
    return $builder.ToString()
}
function New-DomeniaBoardSample {
    # Example data for the live preview of a widget that has no result yet.
    param([string]$Key,[string]$Kind)
    $parts = @([pscustomobject]@{ Label = 'Exemple A'; Value = 12 }, [pscustomobject]@{ Label = 'Exemple B'; Value = 7 }, [pscustomobject]@{ Label = 'Exemple C'; Value = 3 })
    switch ($Kind) {
        'Number' { return New-DomeniaBoardEntry -Key $Key -Kind Number -Value '62 %' -Detail 'Apercu' -Number 62 -Maximum 100 -Unit '%' }
        'Distribution' { return New-DomeniaBoardEntry -Key $Key -Kind Distribution -Value 'Exemple A' -Detail '12 sur 22 · apercu' -Items $parts }
        'Measure' { return New-DomeniaBoardEntry -Key $Key -Kind Measure -Value '42' -Detail 'Moyenne · apercu' -Items $parts }
        'Series' { return New-DomeniaBoardEntry -Key $Key -Kind Series -Value '22' -Detail 'Apercu' -Items $parts }
        'List' { return New-DomeniaBoardEntry -Key $Key -Kind List -Value 'Apercu' -Items @([pscustomobject]@{ Level = 'Warn'; Text = 'Exemple de point a surveiller.' }, [pscustomobject]@{ Level = 'Info'; Text = 'Exemple d information.' }) }
        'Health' { return New-DomeniaBoardEntry -Key $Key -Kind Health -Value 'Bon etat' -Detail 'Apercu' -State Ok -Number 90 -Maximum 100 }
        default { return New-DomeniaBoardEntry -Key $Key -Kind Value -Value 'Exemple' -Detail 'Apercu : la valeur reelle apparait apres lecture' }
    }
}
