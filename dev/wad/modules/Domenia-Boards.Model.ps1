# Dashboards made of widgets (decision David 2026-10-07): every tile and chart of the fleet, workstation and
# software dashboards is a widget that can be edited, resized, moved or removed; new ones come from the
# built-in catalog or from the ready-made WMI queries. Pure rules: catalog, data contract, allowed
# representations per kind of data, sizes and layout operations. No WPF, no network, no disk.

$script:DomeniaBoardCatalogCache = @{}
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
computer.ad.clock|Compte machine dans Active Directory|Horloge du poste|Value|Kpi|S|Écart avec la référence disponible : contrôleur ou poste dʼadministration
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
computer.secureboot|Securite et etat|Démarrage sécurisé|Value|Kpi|S|Secure Boot lu dans le registre du poste par lʼinventaire
computer.updates|Securite et etat|Mises à jour|Value|Kpi|S|Build, révision et source des mises à jour, sans verdict de conformité
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
fleet.health|Santé|État du parc|Health|Health|S|Part des postes sans point critique ni à surveiller
fleet.attention|Santé|Points dʼattention|List|List|L|Problèmes détectés sur le périmètre : un clic déplie les postes concernés
fleet.machines|Inventaire du périmètre|Comptes ordinateur|Value|Kpi|S|Tous les comptes AD : activés, désactivés et état inconnu
fleet.enabled|Inventaire du périmètre|Comptes AD activés|Value|Kpi|S|État AD ; aucune déduction de présence réseau
fleet.accountunknown|Inventaire du périmètre|État AD inconnu|Value|Kpi|S|userAccountControl non lu|N
fleet.accountstatus|Inventaire du périmètre|État des comptes AD|Distribution|Pie|M|Activés, désactivés et inconnus
fleet.stale|Inventaire du périmètre|Sans connexion AD au-delà du seuil|Value|Kpi|S|Seuil réglé dans les règles de santé (90 j par défaut) ; lastLogonTimestamp à 14 jours près
fleet.disabled|Inventaire du périmètre|Comptes désactivés encore dans lʼOU|Value|Kpi|S|Comptes ordinateur désactivés à déplacer ou supprimer
fleet.created|Inventaire du périmètre|Créés ces 30 jours|Value|Kpi|S|Attribut whenCreated
fleet.pwdold|Inventaire du périmètre|Mot de passe machine de plus de 60 j|Value|Kpi|S|Attribut pwdLastSet
fleet.servers|Inventaire du périmètre|Serveurs / postes|Distribution|Pie|M|Attribut operatingSystem : serveurs et postes de travail|N
fleet.laps|Sécurité|Sans LAPS|Value|Kpi|S|Expiration LAPS lue avec la base autonome, jamais le mot de passe
fleet.bitlocker|Sécurité|Sans clé BitLocker|Value|Kpi|S|Présence des clés de récupération, lue sur demande pour lʼOU affichée
fleet.versions|Versions de Windows|Versions de Windows|Distribution|Pie|M|Attribut operatingSystemVersion de tout le périmètre
fleet.eos|Versions de Windows|Fin de service|Value|Kpi|S|Versions plus maintenues ou bientôt (90 jours avant la date)
fleet.win10|Versions de Windows|Postes sous Windows 10|Value|Kpi|S|Hors LTSC, LTSB et IoT
fleet.os|Répartition|Systèmes dʼexploitation|Distribution|Pie|M|Systèmes déclarés dans lʼannuaire
fleet.lastlogon|Répartition|Dernière connexion au domaine|Series|Column|M|Ancienneté de la dernière connexion
fleet.ou|Répartition|Postes par unité dʼorganisation|Distribution|Bar|M|Postes par OU ou sous-OU
fleet.presence|Relevés des postes|Présence réseau|Distribution|Pie|M|Dernier ping de moins de 30 jours ; sans réponse ne prouve pas un arrêt|N
fleet.wmi|Relevés des postes|Réponse WMI|Distribution|Pie|M|Dernière lecture WMI datée, indépendante du ping ; un échec ne prouve pas un arrêt|N
fleet.reach|Relevés des postes|Ping et WMI|Distribution|Bar|M|Réponse au ping et réponse WMI comparées pour chaque poste actif|N
fleet.users|Relevés des postes|Utilisateurs détectés|Value|Kpi|S|Utilisateurs distincts vus en session sur les postes|N
fleet.lastcheck|Relevés des postes|Dernier ping|Value|Kpi|S|Date du dernier relevé des postes|N
fleet.models|Relevés des postes|Modèles|Distribution|Bar|M|Modèles des postes analysés|N
fleet.releases|Relevés des postes|Versions relevées|Distribution|Pie|M|Versions commerciales relevées par WMI|N
fleet.ram|Relevés des postes|Mémoire installée|Series|Column|M|Postes par quantité de mémoire|N
fleet.diskfree|Relevés des postes|Espace libre sur C:|Series|Column|M|Postes par espace libre du disque système|N
fleet.lowdisk|Relevés des postes|Disque C: presque plein|Value|Kpi|S|Postes avec moins de 10 % libre|N
fleet.uptime|Relevés des postes|Non redémarrés depuis 30 j|Value|Kpi|S|Postes à redémarrer|N
fleet.trend|Évolution|Postes à traiter sur 90 jours|Timeline|Line|L|Instantanés quotidiens locaux de lʼOU affichée|N
fleet.trend.win10|Évolution|Windows 10 sur 90 jours|Timeline|Line|L|Postes sous Windows 10 hors LTSC, LTSB et IoT, instantanés quotidiens|N
fleet.trend.stale|Évolution|Inactifs sur 90 jours|Timeline|Line|L|Postes sans connexion AD au-delà du seuil réglé, instantanés quotidiens|N
fleet.trend.lowdisk|Évolution|Disques C: presque pleins sur 90 jours|Timeline|Line|L|Postes analysés avec moins de 10 % libre, instantanés quotidiens|N
'@
    Software = @'
software.count|Synthese|Logiciels|Value|Kpi|S|Nombre de logiciels et d editeurs
software.size|Synthese|Taille declaree|Value|Kpi|S|Somme des tailles connues
software.recent|Synthese|Installés ces 30 derniers jours|Value|Kpi|S|Date dʼinstallation déclarée par le logiciel, lue dans la liste
software.multiversion|Synthese|Installes en plusieurs versions|Value|Kpi|S|Logiciels presents en plusieurs versions
software.duplicates|Synthese|Installés en double|Value|Kpi|S|Même nom et même version présents dans plusieurs architectures, portées ou profils
software.nopublisher|Synthese|Sans editeur declare|Value|Kpi|S|Logiciels sans editeur renseigne
software.runtime|Synthese|Composants dʼexécution|Value|Kpi|S|Socles Visual C++, .NET et WebView2 déclarés dans la liste
software.browsers|Synthese|Navigateurs et versions|Value|Kpi|S|Navigateurs détectés dans la liste, avec leur version
software.publishers|Repartition|Editeurs|Distribution|Pie|M|Principaux editeurs
software.architecture|Repartition|Architecture|Distribution|Pie|M|Logiciels 32 et 64 bits
software.scope|Repartition|Portee d installation|Distribution|Pie|M|Installation machine ou utilisateur
software.largest|Repartition|Plus gros logiciels|Distribution|Bar|L|Taille declaree, en Mo
'@
}

# Fleet layout delivered up to RC1.13.0 (key|section|representation|size): a saved layout identical to it is
# replaced by the current delivered layout; any other saved layout is kept as it is (decision David 2026-10-08).
$script:DomeniaFleetLegacyLayoutText = @'
fleet.health|Vue d ensemble|Health|S
fleet.attention|Vue d ensemble|List|L
fleet.machines|Inventaire du perimetre|Kpi|S
fleet.stale|Inventaire du perimetre|Kpi|S
fleet.win10|Inventaire du perimetre|Kpi|S
fleet.users|Inventaire du perimetre|Kpi|S
fleet.lastcheck|Inventaire du perimetre|Kpi|S
fleet.os|Repartition|Pie|M
fleet.lastlogon|Repartition|Column|M
fleet.ou|Repartition|Bar|M
fleet.presence|Repartition|Pie|M
fleet.models|Releves WMI|Bar|M
fleet.releases|Releves WMI|Pie|M
fleet.ram|Releves WMI|Column|M
fleet.diskfree|Releves WMI|Column|M
fleet.lowdisk|Releves WMI|Kpi|S
fleet.uptime|Releves WMI|Kpi|S
'@

function Get-DomeniaBoardCatalogCache {
    # Cache only immutable catalog text and its parsed index, never a user's layout or live data.
    # Public readers return copies: editing a picker item must not corrupt later cards.
    param([Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board)
    if ($null -eq $script:DomeniaBoardCatalogCache) { $script:DomeniaBoardCatalogCache = @{} }
    $text = [string]$script:DomeniaBoardCatalogText[$Board]
    $cached = $script:DomeniaBoardCatalogCache[$Board]
    if ($null -ne $cached -and $cached.Text -ceq $text) { return $cached }
    $rows = New-Object System.Collections.ArrayList
    $index = @{}
    foreach ($line in ($text -split "`n")) {
        $lineText = $line.Trim()
        if (-not $lineText) { continue }
        $cells = $lineText -split '\|'
        if ($cells.Count -lt 7) { continue }
        $default = -not (($cells.Count -ge 8) -and ([string]$cells[7]).Trim() -eq 'N')
        $item = [pscustomobject]@{ Key = $cells[0]; Group = $cells[1]; Title = $cells[2]; Kind = $cells[3]; Visual = $cells[4]; Size = $cells[5]; Description = $cells[6]; Default = $default }
        [void]$rows.Add($item)
        if (-not $index.ContainsKey([string]$item.Key)) { $index[[string]$item.Key] = $item }
    }
    $cached = [pscustomobject]@{ Text = $text; Rows = @($rows); Index = $index }
    $script:DomeniaBoardCatalogCache[$Board] = $cached
    return $cached
}
function Get-DomeniaBoardCatalog {
    param([Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board)
    foreach ($item in (Get-DomeniaBoardCatalogCache -Board $Board).Rows) { $item.PSObject.Copy() }
}
function Get-DomeniaBoardCatalogItem {
    param([string]$Board,[string]$Key)
    $cached = Get-DomeniaBoardCatalogCache -Board $Board
    if ($cached.Index.ContainsKey($Key)) { return $cached.Index[$Key].PSObject.Copy() }
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
function Get-DomeniaBoardThresholds {
    # One table for the drawing, the tile and the attention point, on the workstation and on the fleet (decision David
    # 2026-10-08, CO-14): free space of a disk (percent), used memory (percent) and battery left (percent).
    param($Policy=$null)
    if($null -ne $Policy -and $Policy.PSObject.TypeNames -contains 'Domenia.HealthPolicy'){return $Policy.Thresholds}
    return (ConvertTo-DomeniaHealthPolicy $Policy).Thresholds
}
function Get-DomeniaThresholdState {
    # State of one measure against the shared thresholds: 'Alert', 'Warn' or 'Ok'.
    param([ValidateSet('DiskFree','MemoryUsed','Battery')][string]$Measure,[double]$Percent,$Policy=$null)
    $limits = Get-DomeniaBoardThresholds -Policy $Policy
    switch ($Measure) {
        'DiskFree' { if ($Percent -lt $limits.DiskFreeAlert) { return 'Alert' }; if ($Percent -lt $limits.DiskFreeWarn) { return 'Warn' }; return 'Ok' }
        'MemoryUsed' { if ($Percent -gt $limits.MemoryUsedWarn) { return 'Warn' }; return 'Ok' }
        'Battery' { if ($Percent -lt $limits.BatteryWarn) { return 'Warn' }; return 'Ok' }
    }
    return 'Ok'
}
function Get-DomeniaChartTicks {
    # Rounded graduations (1, 2 or 5 x 10^n) from 0 to the first one at or above the maximum, whole steps for counts
    # (decision David 2026-10-08, CO-16): a count never shows a half workstation.
    param([double]$Maximum,[switch]$Integer,[int]$Count = 4)
    if (($Maximum -le 0) -or [double]::IsNaN($Maximum) -or [double]::IsInfinity($Maximum)) { $Maximum = 1.0 }
    $raw = $Maximum / [Math]::Max(1, $Count)
    $power = [Math]::Pow(10, [Math]::Floor([Math]::Log10($raw)))
    $step = 10 * $power
    foreach ($factor in @(1, 2, 5, 10)) { $candidate = [Math]::Round($factor * $power, 10); if ($candidate -ge $raw) { $step = $candidate; break } }
    if ($Integer -and ($step -lt 1)) { $step = 1.0 }
    $top = [Math]::Round([Math]::Ceiling([Math]::Round($Maximum / $step, 9)) * $step, 10)
    if ($top -le 0) { $top = $step }
    $ticks = New-Object System.Collections.ArrayList
    for ($i = 0; ($i * $step) -le ($top + $step / 2); $i++) { [void]$ticks.Add([Math]::Round($i * $step, 10)) }
    return [pscustomobject]@{ Step = $step; Top = $top; Ticks = @($ticks) }
}
function Test-DomeniaBoardNumberText {
    # A figure, with at most one short unit ('16 Go', '35 %', '+12 s', '128 postes'), as opposed to a text
    # ('Intel Core i5-1345U', 'il y a 3 j'): figures get the large size, texts the reading size (DS-13).
    param([string]$Text)
    return ([string]$Text).Trim() -match '^[+\-]?\d[\d\s  ]*([.,]\d+)?(\s?(%|[A-Za-zÀ-ÿ/]{1,6}))?$'
}
function ConvertFrom-DomeniaOsVersion {
    # Build number of operatingSystemVersion ('10.0 (19045)') or of a CIM version ('10.0.19045'); '' when absent.
    param([string]$Version)
    $text = ([string]$Version).Trim()
    if ($text -match '\((\d{3,6})\)') { return [string]$Matches[1] }
    if ($text -match '^\d+\.\d+\.(\d{3,6})') { return [string]$Matches[1] }
    if ($text -match '^\d{3,6}$') { return $text }
    return ''
}
function Get-DomeniaWindowsFamily {
    # Lifecycle family of a system name (AD operatingSystem or CIM caption): LTSC, LTSB and IoT keep their own dates.
    param([string]$Caption)
    $c = [string]$Caption
    if ($c -match '(?i)server') { return 'Server' }
    if ($c -match '(?i)LTS[BC]') { if ($c -match '(?i)\bIoT\b') { return 'IoT' }; return 'LTSC' }
    # Pro Education and Pro for Workstations follow the Pro dates (table Families.Pro), never the Education ones.
    if ($c -match '(?i)\bPro\b|professionnel|professional') { return 'Pro' }
    if ($c -match '(?i)entreprise|enterprise|education|éducation') { return 'Enterprise' }
    if ($c -match '(?i)\bIoT\b') { return 'Enterprise' }
    return 'Pro'
}
function Get-DomeniaWindowsRelease {
    # Release name and end of service of one system. $Lifecycle: the delivered table (Domenia-WindowsLifecycle.json,
    # read once by the interface and passed here: a rule never reads the disk). Without the table, or without a line
    # for the build and family, the end date is unknown and never critical (decision David 2026-10-08).
    # Servers share their builds with Windows 11: a caption naming a server gives the server release
    # (real case 2026-10-07: CNAMTS-DC01, Windows Server 2025, build 26100, was shown as Windows 11 24H2).
    # Status: Ended (past the date), Soon (90 days or less before), Ok, Unknown.
    param([string]$Build,[string]$Caption = '',$Lifecycle = $null,[datetime]$Now = [datetime]::Now)
    $names = @{ '26200'='Windows 11 25H2'; '26100'='Windows 11 24H2'; '22631'='Windows 11 23H2'; '22621'='Windows 11 22H2'; '22000'='Windows 11 21H2'; '19045'='Windows 10 22H2'; '19044'='Windows 10 21H2'; '19043'='Windows 10 21H1' }
    $servers = @{ '26100'='Windows Server 2025'; '20348'='Windows Server 2022'; '17763'='Windows Server 2019'; '14393'='Windows Server 2016' }
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $key = ConvertFrom-DomeniaOsVersion $Build
    $family = Get-DomeniaWindowsFamily $Caption
    $entries = @()
    if ($null -ne $Lifecycle) {
        $listProperty = $Lifecycle.PSObject.Properties['Entries']
        $entries = @(if ($null -ne $listProperty) { @($listProperty.Value) } else { @($Lifecycle) })
    }
    $tableKnown = (@($entries | Where-Object { $null -ne $_ }).Count -gt 0)
    $match = $null
    if ($key) { foreach ($entry in $entries) { if (($null -ne $entry) -and ([string]$entry.Build -eq $key) -and ([string]$entry.Family -eq $family)) { $match = $entry } } }
    $name = ''
    if ($null -ne $match) { $name = [string]$match.Name }
    elseif ($family -eq 'Server') {
        $name = [string]$servers[$key]
        if (-not $name) { $name = (([string]$Caption -replace '(?i)^Microsoft\s+','') -replace '(?i)\s+(Standard|Datacenter|Essentials|Evaluation).*$','').Trim() }
        if ($name -notlike 'Windows*') { $name = 'Windows Server' }
    }
    else { $name = [string]$names[$key] }
    # Family shown with the client releases whose dates differ by edition.
    $label = $name
    if ($name -and ($family -in @('Pro','Enterprise')) -and ($name -like 'Windows 1*') -and ($name -notmatch 'LTS')) { $label = $name + $(if ($family -eq 'Pro') { ' Pro' } else { ' Entreprise' }) }
    $end = $null
    if (($null -ne $match) -and [string]$match.End) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$match.End,'yyyy-MM-dd',$invariant,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { $end = $parsed }
    }
    # Build not read: every Windows 10 release of a mainstream family ended on 14/10/2025 at the latest, so the
    # latest date of the family settles it; otherwise the date stays unknown.
    $guessed = $false
    if (($null -eq $end) -and (-not $key) -and $tableKnown -and ($family -in @('Pro','Enterprise')) -and ([string]$Caption -match '(?i)windows\s+(\d+)')) {
        $product = 'Windows ' + $Matches[1]
        $latest = $null
        foreach ($entry in $entries) {
            if (($null -eq $entry) -or ([string]$entry.Family -ne $family) -or (-not ([string]$entry.Name).StartsWith($product + ' '))) { continue }
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact([string]$entry.End,'yyyy-MM-dd',$invariant,[Globalization.DateTimeStyles]::None,[ref]$parsed) -and (($null -eq $latest) -or ($parsed -gt $latest))) { $latest = $parsed }
        }
        if (($null -ne $latest) -and ($latest -lt $Now.Date)) { $end = $latest; $guessed = $true; if (-not $name) { $name = $product; $label = $product + ' (version non lue)' } }
    }
    $status = 'Unknown'
    if ($null -ne $end) {
        if ($Now.Date -gt $end) { $status = 'Ended' }
        elseif (($end - $Now.Date).TotalDays -le 90) { $status = 'Soon' }
        else { $status = 'Ok' }
    }
    $endText = if ($null -ne $end) { $end.ToString('dd/MM/yyyy',$invariant) } else { '' }
    $buildText = if ($key) { 'Build ' + $key } else { '' }
    $note = switch ($status) {
        'Ended' { $(if ($guessed) { 'Fin de service au plus tard le ' + $endText + ' : à migrer' } else { 'Fin de service le ' + $endText + ' : à migrer' }) }
        'Soon' { 'Fin de service le ' + $endText }
        'Ok' { (@($buildText, ('fin de service le ' + $endText)) | Where-Object { $_ }) -join ' · ' }
        default { $(if ($name -or $key) { (@($buildText, 'date de fin inconnue') | Where-Object { $_ }) -join ' · ' } else { '' }) }
    }
    return [pscustomobject]@{ Name = $name; Label = $label; Note = $note; Family = $family; Build = $key; End = $endText; EndDate = $end; Status = $status }
}
function Format-DomeniaAge {
    # 'il y a 5 min', 'il y a 3 h', 'il y a 2 j' between two UTC times.
    param([datetime]$FromUtc,[datetime]$NowUtc = [datetime]::UtcNow)
    $span = $NowUtc - $FromUtc
    if ($span.TotalMinutes -lt 1) { return 'à lʼinstant' }
    if ($span.TotalHours -lt 1) { return 'il y a ' + [int][Math]::Floor($span.TotalMinutes) + ' min' }
    if ($span.TotalDays -lt 1) { return 'il y a ' + [int][Math]::Floor($span.TotalHours) + ' h' }
    return 'il y a ' + [int][Math]::Floor($span.TotalDays) + ' j'
}
function ConvertFrom-DomeniaUtcText {
    # ISO 8601 text written by the workers ('o' or 'yyyy-MM-ddTHH:mm:ssZ') to a UTC date; $null when unreadable.
    param([string]$Text)
    $value = ([string]$Text).Trim()
    if (-not $value) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($value,[Globalization.CultureInfo]::InvariantCulture,([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal),[ref]$parsed)) { return $parsed }
    return $null
}
function Get-DomeniaCoverageText {
    # Coverage of a widget built on observations: 'N postes analysés sur M, le jj/MM'.
    param([int]$Analysed,[int]$Total,$LastUtc = $null)
    $text = [string]$Analysed + ' poste' + $(if ($Analysed -gt 1) { 's' } else { '' }) + ' analysé' + $(if ($Analysed -gt 1) { 's' } else { '' }) + ' sur ' + [string]$Total
    if ($LastUtc -is [datetime]) { $text += ', le ' + $LastUtc.ToLocalTime().ToString('dd/MM',[Globalization.CultureInfo]::InvariantCulture) }
    return $text
}
function Test-DomeniaObservationAge {
    # Use of an observation by its age (decision David 2026-10-08): Fresh, Old (shown greyed, past $GreyDays) or
    # Expired (left out, past $MaxDays). An unreadable date is Expired.
    param($CheckedUtc,[datetime]$NowUtc = [datetime]::UtcNow,[int]$MaxDays = 30,[int]$GreyDays = 7)
    $date = if ($CheckedUtc -is [datetime]) { $CheckedUtc.ToUniversalTime() } else { ConvertFrom-DomeniaUtcText ([string]$CheckedUtc) }
    if ($null -eq $date) { return 'Expired' }
    if($date -gt $NowUtc.AddMinutes(5)){return 'Expired'}
    $days = ($NowUtc - $date).TotalDays
    if ($days -gt [Math]::Max(1,$MaxDays)) { return 'Expired' }
    if ($days -gt $GreyDays) { return 'Old' }
    return 'Fresh'
}

# ---------------------------------------------------------------------------
# Data contract shared by the providers and the renderer
# ---------------------------------------------------------------------------
function New-DomeniaBoardEntry {
    # Value: one text. Number: a measure with an optional maximum (gauge). Distribution: parts of a whole.
    # Measure: numeric values gathered in buckets. Series: ordered buckets. List: Level/Text lines. Health: score.
    # Timeline: values by date (daily local snapshots), the only data drawn as a curve.
    # Action: optional button of the widget {Id; Text; Tip} handled by the interface (never run by a rule).
    # Subtitle: line under the title of a chart ('19 postes'). Badge: short warning under a score (UX-23).
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('Value','Number','Distribution','Measure','Series','List','Health','Timeline')][string]$Kind,
        [string]$Title = '',
        [string]$Value = '',
        [string]$Detail = '',
        [ValidateSet('','Ok','Warn','Alert','Off')][string]$State = '',
        [object[]]$Items = @(),
        $Number = $null,
        $Maximum = $null,
        [string]$Unit = '',
        [switch]$LowIsBad,
        [string]$CenterText = '',
        $Action = $null,
        [string]$Subtitle = '',
        [string]$Badge = ''
    )
    return [pscustomobject]@{ Key = $Key; Kind = $Kind; Title = $Title; Value = $Value; Detail = $Detail; State = $State; Items = @($Items | Where-Object { $null -ne $_ }); Number = $Number; Maximum = $Maximum; Unit = $Unit; LowIsBad = [bool]$LowIsBad; CenterText = $CenterText; Action = $Action; Subtitle = $Subtitle; Badge = $Badge }
}
function New-DomeniaBoardData {
    # What a provider returns: entries by key, attention points, hints for empty sections, a summary line.
    # HintActions: section -> {Id; Text; Tip; Link} offered under its hint, run only on a click (SP-17).
    # Partial: {Text; Action} when the score misses key checks (UX-23), shown as a badge under the score.
    param([Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board)
    # SuppressedAttention: points of disabled or suspended rules, never scored, kept for the explanation (point 75).
    return [pscustomobject]@{ Board = $Board; Entries = @{}; Attention = New-Object System.Collections.ArrayList; SuppressedAttention = New-Object System.Collections.ArrayList; Hints = @{}; HintActions = @{}; Partial = $null; Summary = ''; HealthPolicy=(ConvertTo-DomeniaHealthPolicy) }
}
function Add-DomeniaBoardEntry {
    param([Parameter(Mandatory=$true)]$Data,$Entry)
    if ($null -eq $Entry) { return }
    $Data.Entries[[string]$Entry.Key] = $Entry
}
function Add-DomeniaBoardAttention {
    # -Point: stable name of the check. -Groups / -Machines: workstations concerned (fleet: aggregate groups of the
    # worker, or observed workstations), unfolded by a click from the data already in memory. -Route: workspace that
    # holds the useful action (workstation board), opened by Invoke-DomeniaUxRoute without running anything.
    param([Parameter(Mandatory=$true)]$Data,[ValidateSet('Alert','Warn','Info')][string]$Level,[string]$Text,[string]$Point = '',[object[]]$Groups = @(),[object[]]$Machines = @(),[string]$Route = '',[string]$RouteText = '')
    if (-not $Text) { return }
    $item = [pscustomobject]@{ Level = $Level; Text = $Text; Point = $Point; Groups = @($Groups | Where-Object { $null -ne $_ }); Machines = @($Machines | Where-Object { $null -ne $_ }); Route = $Route; RouteText = $RouteText }
    if (-not (Test-DomeniaHealthRuleEnabled $Data.HealthPolicy $Point)) {
        # A disabled or suspended rule never scores nor lists; what it would flag stays explainable (point 75).
        if ($Level -in @('Alert','Warn')) {
            $reason = Get-DomeniaHealthRuleState $Data.HealthPolicy $Point
            $item | Add-Member -NotePropertyName Reason -NotePropertyValue $reason
            if ($null -eq $Data.PSObject.Properties['SuppressedAttention']) { $Data | Add-Member -NotePropertyName SuppressedAttention -NotePropertyValue (New-Object System.Collections.ArrayList) }
            [void]$Data.SuppressedAttention.Add($item)
        }
        return
    }
    [void]$Data.Attention.Add($item)
}
function Get-DomeniaBoardHealth {
    # 100 minus 25 per critical point and 10 per point to watch; information lines do not count.
    # One rule (decision David 2026-10-08, CO-10): the verdict follows the state, so its words always match its colour.
    # Critique as soon as one point is critical, Dégradé below 60, À surveiller with one point to watch, else Bon état.
    param([object[]]$Attention = @())
    $alerts = @($Attention | Where-Object { ($null -ne $_) -and ([string]$_.Level -eq 'Alert') }).Count
    $warnings = @($Attention | Where-Object { ($null -ne $_) -and ([string]$_.Level -eq 'Warn') }).Count
    $score = [Math]::Max(0, 100 - 25 * $alerts - 10 * $warnings)
    $state = if ($alerts -or ($score -lt 60)) { 'Alert' } elseif ($warnings) { 'Warn' } else { 'Ok' }
    $verdict = if ($alerts) { 'Critique' } elseif ($state -eq 'Alert') { 'Dégradé' } elseif ($state -eq 'Warn') { 'À surveiller' } else { 'Bon état' }
    return [pscustomobject]@{ Score = $score; Verdict = $verdict; State = $state; Alerts = $alerts; Warnings = $warnings }
}
function Get-DomeniaHealthCoverage {
    # Share of the enabled accounts actually evaluated by the health rules (point 74), as a whole percentage rounded
    # down so that 49.9 % never reads as 50 %. Sufficient: at least MinimumPercent evaluated (bounded 1 to 100).
    param([int]$Total,[int]$Assessed,[int]$MinimumPercent = 50)
    $minimum = [Math]::Max(1, [Math]::Min(100, $MinimumPercent))
    $total = [Math]::Max(0, $Total); $assessed = [Math]::Max(0, [Math]::Min($total, $Assessed))
    $percent = if ($total -gt 0) { [int][Math]::Floor(100.0 * $assessed / $total) } else { 0 }
    $text = if ($total -gt 0) { 'couverture ' + [string]$percent + ' % (' + [string]$assessed + ' évalué(s) sur ' + [string]$total + ')' } else { 'aucun poste à évaluer' }
    return [pscustomobject]@{ Total = $total; Assessed = $assessed; Unassessed = ($total - $assessed); Percent = $percent; MinimumPercent = $minimum; Sufficient = (($total -gt 0) -and ((100 * $assessed) -ge ($minimum * $total))); Text = $text }
}
function Get-DomeniaFleetHealth {
    # Fleet score (decision David 2026-10-08, MO-01): share of the workstations without any critical point nor point
    # to watch. Critique as soon as one point is critical, otherwise Bon état from 90 %, À surveiller from 75 %,
    # Dégradé below. An empty or unassessed perimeter has no numeric score.
    # Point 74: a poorly covered perimeter gets no reassuring score. Below $MinimumCoveragePercent of the enabled
    # accounts evaluated, the score is withheld (verdict Couverture insuffisante, or Critique when a point is
    # critical); the unevaluated workstations stay counted apart and never as healthy.
    param([int]$Total,[int]$Healthy,[object[]]$Attention = @(),[int]$Unassessed=0,[int]$MinimumCoveragePercent=50)
    $alerts = @($Attention | Where-Object { ($null -ne $_) -and ([string]$_.Level -eq 'Alert') }).Count
    $warnings = @($Attention | Where-Object { ($null -ne $_) -and ([string]$_.Level -eq 'Warn') }).Count
    $unassessed=[Math]::Max(0,[Math]::Min($Total,$Unassessed));$assessed=[Math]::Max(0,$Total-$unassessed)
    if($assessed -eq 0){return [pscustomobject]@{Score=$null;Verdict=$(if($Total){'Données insuffisantes'}else{'Aucun poste évalué'});State='Off';Alerts=$alerts;Warnings=$warnings;Detail=([string]$assessed+' évalué(s) sur '+$Total+' · '+$unassessed+' non évalué(s)');Healthy=0;Total=$Total;Unassessed=$unassessed}}
    $coverage=Get-DomeniaHealthCoverage -Total $Total -Assessed $assessed -MinimumPercent $MinimumCoveragePercent
    if(($unassessed -gt 0) -and (-not $coverage.Sufficient)){
        $partialHealthy=[Math]::Max(0,[Math]::Min($assessed,$Healthy))
        return [pscustomobject]@{Score=$null;Verdict=$(if($alerts){'Critique'}else{'Couverture insuffisante'});State=$(if($alerts){'Alert'}else{'Off'});Alerts=$alerts;Warnings=$warnings;Detail=([string]$partialHealthy+' sans point détecté sur '+$assessed+' évalué(s) · '+$coverage.Text+' : score affiché à partir de '+$coverage.MinimumPercent+' %');Healthy=$partialHealthy;Total=$Total;Unassessed=$unassessed}
    }
    $healthy = [Math]::Max(0,[Math]::Min($assessed,$Healthy))
    $score = if ($assessed -gt 0) { [int][Math]::Floor(100.0 * $healthy / $assessed) } else { 100 }
    $verdict = if ($alerts) { 'Critique' } elseif ($score -ge 90 -and $unassessed) { 'Évaluation partielle' } elseif ($score -ge 90) { 'Bon état' } elseif ($score -ge 75) { 'À surveiller' } else { 'Dégradé' }
    $state = if ($alerts -or ($verdict -eq 'Dégradé')) { 'Alert' } elseif ($verdict -eq 'À surveiller') { 'Warn' } elseif($unassessed){'Off'} else { 'Ok' }
    $detail = if ($Total -gt 0) { [string]$healthy + ' poste' + $(if ($healthy -gt 1) { 's' } else { '' }) + ' sur ' + [string]$assessed + ' évalués sans point détecté · '+[string]$unassessed+' non évalué(s)' } else { 'Aucun poste dans le périmètre' }
    # The share evaluated is shown beside the score as soon as one workstation is missing (point 74).
    if (($Total -gt 0) -and ($unassessed -gt 0)) { $detail += ' · ' + $coverage.Text }
    return [pscustomobject]@{ Score = $score; Verdict = $verdict; State = $state; Alerts = $alerts; Warnings = $warnings; Detail = $detail; Healthy = $healthy; Total = $Total }
}
function Complete-DomeniaBoardData {
    # Adds the health and attention entries computed from every check, whether its widget is shown or not.
    # A provider that counts its workstations ($Data.Population = {Total; Healthy}) gets the proportional score.
    param([Parameter(Mandatory=$true)]$Data)
    $prefix = ([string]$Data.Board).ToLowerInvariant()
    $scoped=[bool](Get-DomeniaHealthValue $Data 'ScopedHealthEvaluated' $false)
    $attention = @($Data.Attention | Where-Object {$scoped -or (Test-DomeniaHealthRuleEnabled $Data.HealthPolicy ([string]$_.Point))})
    if($Data.Board -eq 'Fleet' -and -not $scoped -and $null -ne $Data.PSObject.Properties['Last']){Update-DomeniaFleetHealthPopulation $Data $attention}
    $population = $null
    $populationProperty = $Data.PSObject.Properties['Population']
    if ($null -ne $populationProperty) { $population = $populationProperty.Value }
    if ($null -ne $population) { $health = Get-DomeniaFleetHealth -Total ([int]$population.Total) -Healthy ([int]$population.Healthy) -Attention $attention -Unassessed ([int](Get-DomeniaHealthValue $population 'Unassessed' 0)) }
    else { $health = Get-DomeniaBoardHealth -Attention $attention }
    $detail = if ($health.Alerts -or $health.Warnings) { @($(if ($health.Alerts) { [string]$health.Alerts + ' critique(s)' }), $(if ($health.Warnings) { [string]$health.Warnings + ' a surveiller' })) -join ' · ' } else { 'Aucun point a verifier' }
    $healthDetail = $detail
    if ($null -ne $population) { $healthDetail = [string]$health.Detail }
    # UX-23: a score computed without its key checks says so under the score, with the button of the full reading.
    $badge = ''; $badgeAction = $null
    $partialProperty = $Data.PSObject.Properties['Partial']
    if (($null -ne $partialProperty) -and ($null -ne $partialProperty.Value) -and [string]$partialProperty.Value.Text) {
        $badge = [string]$partialProperty.Value.Text
        $actionProperty = $partialProperty.Value.PSObject.Properties['Action']
        if ($null -ne $actionProperty) { $badgeAction = $actionProperty.Value }
    }
    if($Data.Board -eq 'Computer' -and $badge -and -not ($health.Alerts -or $health.Warnings)){
        $health.Score=$null;$health.Verdict='Données insuffisantes';$health.State='Off';$healthDetail='Aucun problème établi ; contrôles incomplets.'
    }
    if($Data.Board -eq 'Fleet' -and $badge){$health.Score=$null;if(-not $health.Alerts){$health.Verdict='Évaluation partielle';$health.State='Off'}}
    if($Data.Board -eq 'Computer'){
        $enabledChecks=@(Get-DomeniaHealthRuleCatalog|Where-Object{Test-DomeniaHealthRuleEnabled $Data.HealthPolicy $_.Id}).Count+@($Data.HealthPolicy.CustomRules|Where-Object{Test-DomeniaHealthRuleEnabled $Data.HealthPolicy $_.Id}).Count
        if(-not $enabledChecks){$health.Score=$null;$health.Verdict='Aucun contrôle activé';$health.State='Off';$healthDetail='Activez un contrôle dans les règles de santé.'}
    }
    if($Data.Board -in @('Fleet','Computer')){
        $Data|Add-Member -NotePropertyName HealthExplanation -NotePropertyValue (Get-DomeniaHealthExplanation $Data) -Force
        if($Data.HealthExplanation.SuspendedRules){$badge=(@($badge,($Data.HealthExplanation.SuspendedRules.ToString()+' règle(s) suspendue(s) temporairement'))|Where-Object{$_}) -join ' · '}
    }
    $coverageText=[string](Get-DomeniaHealthValue $Data 'HealthCoverage' '')
    if($coverageText){$badge=(@($badge,$coverageText)|Where-Object{$_}) -join ' · '}
    Add-DomeniaBoardEntry $Data (New-DomeniaBoardEntry -Key ($prefix + '.health') -Kind Health -Value $health.Verdict -Detail $healthDetail.Trim(' ','·') -State $health.State -Number $health.Score -Maximum 100 -Badge $badge -Action $badgeAction)
    $sorted = @(@($attention | Where-Object { $_.Level -eq 'Alert' }) + @($attention | Where-Object { $_.Level -eq 'Warn' }) + @($attention | Where-Object { $_.Level -notin @('Alert','Warn') }))
    $title = if ($health.Alerts + $health.Warnings) { [string]($health.Alerts + $health.Warnings) + ' point(s) a verifier' } elseif($null -eq $health.Score -or $badge){'Aucun problème établi'} else { 'Rien a signaler' }
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
    # Representations that make sense for a kind of data (decision David 2026-10-07), preferred first. A curve
    # (Line) is offered for dated values only: buckets and shares are not a time line (decision David 2026-10-08).
    param([string]$Kind,[switch]$HasMaximum)
    switch ($Kind) {
        'Value' { return @('Kpi','Text') }
        'Number' { if ($HasMaximum) { return @('Gauge','Kpi','Text') }; return @('Kpi','Text') }
        'Distribution' { return @('Pie','Bar','Column','Text','Kpi') }
        'Measure' { return @('Column','Bar','Kpi','Text') }
        'Series' { return @('Column','Bar','Text','Kpi') }
        'Timeline' { return @('Line','Column','Text') }
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
    # -Paused (decision David 2026-10-14): the widget keeps its place, size and title, is drawn as paused and is left
    # out of every collection (its own refresh, the board refresh, Analyser la liste, the WMI refresh of the OU).
    param([ValidateSet('Builtin','Probe','Query')][string]$Source,[string]$Key,[string]$Visual,[string]$Size = '',[string]$Group = '',[string]$Title = '',[string]$Id = '',[switch]$Paused)
    if (-not $Id) { $Id = New-DomeniaBoardItemId }
    return [pscustomobject]@{ Id = $Id; Source = $Source; Key = $Key; Visual = $Visual; Title = $Title; Size = $Size; Group = $Group; Paused = [bool]$Paused }
}
function Test-DomeniaBoardItemPaused {
    # A layout item written before the pause existed has no Paused member: it is active.
    param($Item)
    if ($null -eq $Item) { return $false }
    $property = $Item.PSObject.Properties['Paused']
    if ($null -eq $property) { return $false }
    return (($property.Value -is [bool]) -and ([bool]$property.Value))
}
function Select-DomeniaActiveBoardItems {
    # Widgets that take part in collections and local calculations: every widget except the paused ones.
    param([object[]]$Layout = @())
    return @($Layout | Where-Object { ($null -ne $_) -and (-not (Test-DomeniaBoardItemPaused -Item $_)) })
}
function Get-DomeniaBoardNextSize {
    # Keyboard resizing (point 80): one step smaller (-1) or larger (+1), bounded to Compacte and Large.
    param([string]$Size = 'M',[int]$Step = 1)
    $order = @('S','M','L')
    $index = [Array]::IndexOf($order, [string]$Size)
    if ($index -lt 0) { $index = 1 }
    return $order[[Math]::Max(0, [Math]::Min(2, $index + [Math]::Sign($Step)))]
}
function Get-DomeniaBoardFitScale {
    # Point 80: at a high DPI or in a narrow window the board offers fewer device-independent pixels than a widget
    # needs. Scale of that widget: 1 when it fits, else the ratio rounded down (so it always fits), never below
    # Minimum (a widget that would become unreadable stays readable and is cut by the page edge, as before).
    param([double]$Needed,[double]$Available,[double]$Minimum = 0.6)
    if (($Needed -le 0) -or ($Available -le 0) -or ($Needed -le $Available)) { return 1.0 }
    return [Math]::Max($Minimum, [Math]::Floor(1000.0 * $Available / $Needed) / 1000.0)
}
function Get-DomeniaBoardKeyGesture {
    # Keyboard of a focused widget (point 80): {Action; Value}, or $null when the key means nothing to the board.
    # F5 refreshes the widget at any time; moving (Alt+arrows, Alt+Home/End), resizing (Alt+Shift+arrows) and removing
    # (Delete) change the layout and are offered while customising only, like the mouse gestures.
    param([string]$Key,[bool]$Alt = $false,[bool]$Shift = $false,[bool]$Control = $false,[bool]$Editing = $false)
    if ($Control) { return $null }
    if ((-not $Alt) -and (-not $Shift) -and ($Key -eq 'F5')) { return [pscustomobject]@{ Action = 'Refresh'; Value = '' } }
    if (-not $Editing) { return $null }
    if ((-not $Alt) -and (-not $Shift) -and ($Key -eq 'Delete')) { return [pscustomobject]@{ Action = 'Remove'; Value = '' } }
    if (-not $Alt) { return $null }
    $value = ''
    if ($Shift) {
        switch ($Key) { 'Right' { $value = 'Grow' } 'Up' { $value = 'Grow' } 'Left' { $value = 'Shrink' } 'Down' { $value = 'Shrink' } }
        if ($value) { return [pscustomobject]@{ Action = 'Size'; Value = $value } }
        return $null
    }
    switch ($Key) { 'Left' { $value = 'Back' } 'Right' { $value = 'Forward' } 'Home' { $value = 'First' } 'End' { $value = 'Last' } }
    if ($value) { return [pscustomobject]@{ Action = 'Move'; Value = $value } }
    return $null
}
function Get-DomeniaBoardDefaultLayout {
    # Delivered layout: the catalog in its order, without the widgets marked catalog only (eighth cell N).
    param([Parameter(Mandatory=$true)][ValidateSet('Computer','Fleet','Software')][string]$Board)
    return @(Get-DomeniaBoardCatalog -Board $Board | Where-Object { [bool]$_.Default } | ForEach-Object { New-DomeniaBoardItem -Source Builtin -Key $_.Key -Visual $_.Visual -Size $_.Size -Group $_.Group -Id ('b-' + $_.Key) })
}
function Test-DomeniaFleetLegacyLayout {
    # True when a saved Fleet layout is the layout delivered up to RC1.13.0, unchanged (identifiers aside): it is then
    # replaced by the current delivered layout. A layout changed by the operator is never replaced.
    param([object[]]$Items = @())
    $legacy = New-Object System.Collections.ArrayList
    foreach ($line in ([string]$script:DomeniaFleetLegacyLayoutText -split "`n")) { $text = $line.Trim(); if ($text) { [void]$legacy.Add(($text -split '\|')) } }
    $stored = @($Items | Where-Object { $null -ne $_ })
    if (($stored.Count -ne $legacy.Count) -or (-not $legacy.Count)) { return $false }
    for ($i = 0; $i -lt $legacy.Count; $i++) {
        $raw = $stored[$i]
        $cells = @($legacy[$i])
        $read = @{}
        foreach ($name in @('Source','Key','Group','Visual','Size','Title')) { $property = $raw.PSObject.Properties[$name]; $read[$name] = $(if (($null -ne $property) -and ($null -ne $property.Value)) { [string]$property.Value } else { '' }) }
        if (($read['Source'] -ne 'Builtin') -or ($read['Key'] -cne $cells[0]) -or ($read['Group'] -cne $cells[1]) -or ($read['Visual'] -cne $cells[2]) -or ($read['Size'] -cne $cells[3]) -or $read['Title']) { return $false }
    }
    return $true
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
    # The Fleet layout delivered up to RC1.13.0, saved unchanged, becomes the current delivered layout.
    if (($null -ne $stored) -and ($Board -eq 'Fleet') -and (Test-DomeniaFleetLegacyLayout -Items $stored)) { $stored = $null }
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
        } elseif ($source -eq 'Query' -and $Board -in @('Fleet','Computer')) {
            $kind=if((& $get 'Visual') -in @('Bar','Pie','Column')){'Distribution'}else{'Number'};$group=& $get 'Group';if(-not $group){$group='Mes sondes'};$defaultSize='M'
        } else { continue }
        $id = & $get 'Id'; if (-not $id -or $seen.ContainsKey($id)) { $id = New-DomeniaBoardItemId }
        $seen[$id] = $true
        $visual = Resolve-DomeniaBoardVisual -Visual (& $get 'Visual') -Kind $kind -HasMaximum:($kind -in @('Number','Health'))
        $size = & $get 'Size'; if ($size -notin @('S','M','L')) { $size = if ($defaultSize) { $defaultSize } elseif ($visual -eq 'Kpi') { 'S' } else { 'M' } }
        [void]$clean.Add((New-DomeniaBoardItem -Source $source -Key $key -Visual $visual -Size $size -Group $group -Title (& $get 'Title') -Id $id -Paused:(Test-DomeniaBoardItemPaused -Item $raw)))
    }
    return @($clean)
}
function ConvertTo-DomeniaBoardLayoutJson {
    param([object[]]$Layout = @())
    # Paused is written only for a paused widget: an active layout keeps the text it had before the pause existed.
    $plain = @($Layout | Where-Object { $null -ne $_ } | ForEach-Object {
        $row = [ordered]@{ Id = [string]$_.Id; Source = [string]$_.Source; Key = [string]$_.Key; Visual = [string]$_.Visual; Title = [string]$_.Title; Size = [string]$_.Size; Group = [string]$_.Group }
        if (Test-DomeniaBoardItemPaused -Item $_) { $row['Paused'] = $true }
        [pscustomobject]$row
    })
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
    # Changes some fields (Visual, Title, Size, Group, Paused) of one widget; a widget moved to another section goes to its end.
    param([object[]]$Layout = @(),[string]$Id,[hashtable]$Changes = @{})
    $target = $null
    foreach ($item in @($Layout)) { if ($null -ne $item -and [string]$item.Id -eq $Id) { $target = $item } }
    if ($null -eq $target) { return @($Layout) }
    $updated = New-DomeniaBoardItem -Source ([string]$target.Source) -Key ([string]$target.Key) -Visual ([string]$target.Visual) -Size ([string]$target.Size) -Group ([string]$target.Group) -Title ([string]$target.Title) -Id ([string]$target.Id) -Paused:(Test-DomeniaBoardItemPaused -Item $target)
    foreach ($name in @('Visual','Title','Size','Group')) { if ($Changes.ContainsKey($name)) { $updated.$name = [string]$Changes[$name] } }
    if ($Changes.ContainsKey('Paused')) { $updated.Paused = [bool]$Changes['Paused'] }
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
        $moving = New-DomeniaBoardItem -Source ([string]$moving.Source) -Key ([string]$moving.Key) -Visual ([string]$moving.Visual) -Size ([string]$moving.Size) -Group ([string]$target.Group) -Title ([string]$moving.Title) -Id ([string]$moving.Id) -Paused:(Test-DomeniaBoardItemPaused -Item $moving)
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
        $moving = New-DomeniaBoardItem -Source ([string]$moving.Source) -Key ([string]$moving.Key) -Visual ([string]$moving.Visual) -Size ([string]$moving.Size) -Group ([string]$target.Group) -Title ([string]$moving.Title) -Id ([string]$moving.Id) -Paused:(Test-DomeniaBoardItemPaused -Item $moving)
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
        # A query guarded on the domain controllers (FI-17) and only skipped there says so instead of waiting.
        $skippedProperty = if ($null -ne $Measured) { $Measured.PSObject.Properties['Skipped'] } else { $null }
        if (($null -ne $skippedProperty) -and ([int]$skippedProperty.Value -gt 0)) {
            return New-DomeniaBoardEntry -Key $Key -Kind $kind -Value 'Non lu' -Detail 'Requête ignorée sur un contrôleur de domaine : elle y parcourrait tout lʼannuaire' -State 'Off'
        }
        # Fleet queries run from Rechercher on the displayed workstations (decision David 2026-10-08).
        $how = if ($Board -eq 'Fleet') { 'Utilisez Relever dans le tableau de bord pour recueillir cette mesure.' } else { 'Actualiser les requetes pour remplir ce widget' }
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
    # The name stays the title; the number of workstations goes under it (CO-16: never 'Nom (%) (19 postes)').
    $title = [string]$Probe.Name
    $machines = [int]$Measured.Machines
    $subtitle = [string]$machines + ' poste' + $(if ($machines -gt 1) { 's' } else { '' })
    if ($kind -eq 'Measure') {
        $sum = 0.0; $count = 0; $min = [double]::MaxValue; $max = [double]::MinValue
        if($null -ne $Measured.PSObject.Properties['Samples']){$sum=$Measured.Samples.Sum;$count=$Measured.Samples.NumericCount;$min=$Measured.Samples.Min;$max=$Measured.Samples.Max}
        else{
        foreach ($v in @($Measured.Values)) { $d = 0.0; if ([double]::TryParse([string]$v,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d)) { $sum += $d; $count++; if ($d -lt $min) { $min = $d }; if ($d -gt $max) { $max = $d } } }
        }
        $value = if ($count) { ([Math]::Round($sum / $count, 1)).ToString([Globalization.CultureInfo]::GetCultureInfo('fr-FR')) + $unit } else { 'Aucune valeur' }
        $detail = if ($count) { 'Moyenne · min ' + ([Math]::Round($min, 1)).ToString([Globalization.CultureInfo]::GetCultureInfo('fr-FR')) + ' · max ' + ([Math]::Round($max, 1)).ToString([Globalization.CultureInfo]::GetCultureInfo('fr-FR')) } else { [string]$Measured.Summary }
        return New-DomeniaBoardEntry -Key $Key -Kind Measure -Title $title -Subtitle $subtitle -Value $value -Detail $detail -Items $items -Unit $unit.Trim()
    }
    $top = @($items | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 1)
    $value = if ($top.Count) { [string]$top[0].Label } else { 'Aucune valeur' }
    $detail = if ($top.Count) { [string][int]$top[0].Value + ' poste(s) sur ' + $machines } else { [string]$Measured.Summary }
    return New-DomeniaBoardEntry -Key $Key -Kind Distribution -Title $title -Subtitle $subtitle -Value $value -Detail $detail -Items $items -CenterText ([string]$machines + ' postes')
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
        'Health' { return New-DomeniaBoardEntry -Key $Key -Kind Health -Value 'Bon état' -Detail 'Apercu' -State Ok -Number 90 -Maximum 100 }
        'Timeline' { return New-DomeniaBoardEntry -Key $Key -Kind Timeline -Value '7' -Detail 'Aperçu' -Items @([pscustomobject]@{ Label = '01/07'; Value = 9 }, [pscustomobject]@{ Label = '01/08'; Value = 8 }, [pscustomobject]@{ Label = '01/09'; Value = 7 }) }
        default { return New-DomeniaBoardEntry -Key $Key -Kind Value -Value 'Exemple' -Detail 'Apercu : la valeur reelle apparait apres lecture' }
    }
}


function Get-DomeniaChartCategoryGroups {
    # Render a bounded number of additive categories while retaining every original selection in the remainder.
    param([object[]]$Items,[ValidateRange(1,64)][int]$Maximum=8)
    $valid=@($Items|Where-Object{$null -ne $_ -and $null -ne $_.Value -and [double]$_.Value -gt 0})
    if($valid.Count -le $Maximum){return ,$valid}
    $keep=[Math]::Max(0,$Maximum-1);$head=@();if($keep){$head=@($valid[0..($keep-1)])}
    $tail=@($valid[$keep..($valid.Count-1)]);$sum=0.0;$labels=[Collections.Generic.List[string]]::new();$selections=[Collections.Generic.List[object]]::new()
    foreach($part in $tail){$sum+=[double]$part.Value;$labels.Add([string]$part.Label);$select=Get-DomeniaHealthValue $part 'Select';if($null -ne $select){$selections.Add($select)}}
    $remainder=[pscustomobject]@{Label=('Autres ('+$tail.Count+' catégories)');Value=$sum;Color='#94A3B8';Items=$tail;Select=[pscustomobject]@{Label='Autres';Labels=$labels.ToArray();Selections=$selections.ToArray()}}
    return ,@($head+$remainder)
}

function Get-DomeniaHealthFingerprint {
    param([string[]]$Values=@())
    $sorted=[string[]]@($Values);[Array]::Sort($sorted,[StringComparer]::Ordinal)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($sorted -join "`n")))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Set-DomeniaHealthSnapshotMetadata {
    param($Data,[object[]]$History=@(),[datetime]$NowUtc=[datetime]::UtcNow)
    $figures=$Data.Snapshot.Figures;$targets=@($Data.Last.Targets);$assessed=@($Data.Last.HealthyTargets)+@($Data.Last.ProblemTargets)
    $policies=@(Get-DomeniaHealthValue $Data 'EffectiveHealthPolicies' @());if(-not $policies.Count){$policies=@([pscustomobject]@{ScopeDn=$Data.Last.Scope;Policy=$Data.HealthPolicy})}
    $policyTokens=[Collections.Generic.List[string]]::new()
    foreach($record in $policies){
        $p=$record.Policy;$stable=[ordered]@{ScopeDn=([string]$record.ScopeDn).ToLowerInvariant();Thresholds=$p.Thresholds;DisabledRules=@($p.DisabledRules|Sort-Object);CustomRules=@($p.CustomRules|Sort-Object Id);Suspensions=@($p.Suspensions|Sort-Object RuleId);ActiveSuspensions=@($p.Suspensions|Where-Object{$null -ne (Get-DomeniaHealthSuspension $p $_.RuleId)}|ForEach-Object{$_.RuleId}|Sort-Object)}
        $policyTokens.Add(($stable|ConvertTo-Json -Depth 8 -Compress))
    }
    $groups=@{};foreach($g in $Data.Last.Groups){$groups[[string]$g.gid]=$g}
    $coverage=[Collections.Generic.List[string]]::new()
    foreach($target in $targets){$guid=[string]$target.object_guid;$inventory=$Data.HealthInventoryKnown[$guid];$g=$groups[[string]$target.gid]
        $date=[datetime]::MinValue;$logonKnown=[datetime]::TryParseExact([string]$target.logon,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date) -and $date -le $NowUtc.Date
        $coverage.Add($guid+'|'+[int]$logonKnown+'|'+[int][bool]([string]$g.ver)+'|'+[int][bool]([string]$g.pw)+'|'+[int]($g.lk -in @('O','E','N','X'))+'|'+[int]($g.bk -in @('K','N','X'))+'|'+[int]($null -ne $inventory -and $inventory.Disk)+'|'+[int]($null -ne $inventory -and $inventory.Boot))
    }
    $values=[ordered]@{FormatVersion=2;PopulationHash=(Get-DomeniaHealthFingerprint @($targets|ForEach-Object{([string]$_.object_guid).ToLowerInvariant()}));AssessedHash=(Get-DomeniaHealthFingerprint @($assessed|ForEach-Object{([string]$_.object_guid).ToLowerInvariant()}));CoverageHash=(Get-DomeniaHealthFingerprint $coverage.ToArray());PolicyHash=(Get-DomeniaHealthFingerprint $policyTokens.ToArray());Unassessed=[int]$Data.Population.Unassessed;Assessed=$assessed.Count;Score=$Data.Entries['fleet.health'].Number;PingRead=($Data.Last.WidgetTargets['fleet.presence|En ligne'].Count+$Data.Last.WidgetTargets['fleet.presence|Sans réponse'].Count);WmiRead=$Data.HealthInventoryKnown.Count;ComputedUtc=$NowUtc.ToString('o')}
    if($targets.Count -ne [int]$Data.Population.Total){$values.PopulationHash='';$values.AssessedHash='';$values.CoverageHash=''}
    foreach($key in $values.Keys){$figures|Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force}
    $records=[Collections.Generic.List[object]]::new()
    foreach($row in $History){try{$f=([string]$row.figures)|ConvertFrom-Json -ErrorAction Stop}catch{continue};if($null -eq $f -or [string]$row.day -notmatch '^\d{4}-\d{2}-\d{2}$'){continue};$records.Add([pscustomobject]@{Label=([string]$row.day+' · relevé quotidien');Day=[string]$row.day;Figures=$f})}
    $records.Add([pscustomobject]@{Label=('Vue actuelle · '+$NowUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm'));Day=$NowUtc.ToString('yyyy-MM-dd');Figures=$figures})
    $Data|Add-Member -NotePropertyName HealthHistory -NotePropertyValue $records.ToArray() -Force
}
function Compare-DomeniaHealthSnapshots {
    # Point 78: separate the three causes of a change between two health readings. Perimeter (which GUIDs), coverage
    # (which GUIDs could be assessed, with which data) and rules (thresholds, enabled rules, active suspensions) are
    # compared through their fingerprints; only when all three are unchanged is a variation a real change of the
    # observed state. Counters are always shown; a cause is never inferred from a counter alone.
    param($Before,$After)
    if($null -eq $Before -or $null -eq $After){throw 'Choisissez deux relevés.'}
    $invariant=[Globalization.CultureInfo]::InvariantCulture
    $moment={param($Item)
        $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue (Get-DomeniaHealthValue $Item 'Figures') 'ComputedUtc' ''))
        if($null -eq $at){$parsed=[datetime]::MinValue;if([datetime]::TryParseExact([string](Get-DomeniaHealthValue $Item 'Day' ''),'yyyy-MM-dd',$invariant,([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),[ref]$parsed)){$at=$parsed}}
        return $at
    }
    $first=& $moment $Before;$second=& $moment $After;$swapped=$false
    if(($null -ne $first) -and ($null -ne $second) -and ($first -gt $second)){$swap=$Before;$Before=$After;$After=$swap;$swapped=$true}
    $a=Get-DomeniaHealthValue $Before 'Figures';$b=Get-DomeniaHealthValue $After 'Figures'
    $number={param($Figures,[string]$Name)
        $raw=Get-DomeniaHealthValue $Figures $Name;if($null -eq $raw){return $null}
        $value=0.0;if([double]::TryParse([string]$raw,[Globalization.NumberStyles]::Float,$invariant,[ref]$value)){return $value};return $null
    }
    $hash={param([string]$Name)
        $old=[string](Get-DomeniaHealthValue $a $Name '');$new=[string](Get-DomeniaHealthValue $b $Name '')
        if((-not $old) -or (-not $new)){return 'Unknown'};if($old -ceq $new){return 'Same'};return 'Changed'
    }
    $french=[Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $text={param($Value) if($null -eq $Value){return 'Non renseigné'};return ([double]$Value).ToString('0.#',$french)}
    $signed={param($Old,$New) if(($null -eq $Old) -or ($null -eq $New)){return 'Non comparable'};$delta=[Math]::Round([double]$New-[double]$Old,1);if($delta -eq 0){$delta=0.0};return $(if($delta -gt 0){'+'}else{''})+$delta.ToString('0.#',$french)}
    $arrow={param($Old,$New,[string]$Unit='')
        if(($null -eq $Old) -or ($null -eq $New)){return 'non renseigné'}
        return ((& $text $Old)+$Unit+' → '+(& $text $New)+$Unit+' ('+(& $signed $Old $New)+$Unit+')')
    }
    $limits=[Collections.Generic.List[string]]::new();if($swapped){$limits.Add('Relevés remis dans lʼordre chronologique.')}
    $missing={param([string]$Name,[string]$What)
        $old=[string](Get-DomeniaHealthValue $a $Name '');$new=[string](Get-DomeniaHealthValue $b $Name '')
        if(-not $old){$limits.Add('Le premier relevé ne conserve pas lʼempreinte '+$What+' : comparaison limitée aux compteurs.')}
        if(-not $new){$limits.Add('Le second relevé ne conserve pas lʼempreinte '+$What+' : comparaison limitée aux compteurs.')}
    }
    & $missing 'PopulationHash' 'de la population';& $missing 'CoverageHash' 'de la couverture';& $missing 'PolicyHash' 'des règles'
    # Perimeter: the exact set of active GUIDs.
    $ma=& $number $a 'Machines';$mb=& $number $b 'Machines';$population=& $hash 'PopulationHash'
    $perimeterStatus=if($population -eq 'Same'){'Inchangé'}elseif($population -eq 'Changed'){'Modifié'}elseif(($null -ne $ma) -and ($null -ne $mb) -and ($ma -ne $mb)){'Modifié'}else{'Inconnu'}
    $perimeterText='Comptes activés : '+(& $arrow $ma $mb)
    if($population -eq 'Same'){$perimeterText+=' ; mêmes GUID'}elseif(($population -eq 'Changed') -and ($ma -eq $mb)){$perimeterText+=' ; même nombre, composition différente (entrées et sorties)'}elseif($population -eq 'Unknown'){$perimeterText+=' ; composition non vérifiable'}
    # Coverage: which workstations were assessed and with which data families.
    $aa=& $number $a 'Assessed';$ab=& $number $b 'Assessed';$coverageHash=& $hash 'CoverageHash';$assessedHash=& $hash 'AssessedHash'
    $coverageStatus=if(($coverageHash -eq 'Same') -and ($assessedHash -eq 'Same')){'Inchangé'}elseif(($coverageHash -eq 'Changed') -or ($assessedHash -eq 'Changed')){'Modifié'}elseif(($null -ne $aa) -and ($null -ne $ab) -and ($aa -ne $ab)){'Modifié'}else{'Inconnu'}
    $share={param($Assessed,$Machines) if(($null -eq $Assessed) -or ($null -eq $Machines) -or ($Machines -le 0)){return $null};return [Math]::Round(100.0*$Assessed/$Machines,1)}
    $pa=& $share $aa $ma;$pb=& $share $ab $mb
    $coverageText='Postes évalués : '+(& $arrow $aa $ab)+' · part évaluée : '+(& $arrow $pa $pb ' %')
    $direction=''
    if($coverageStatus -eq 'Modifié'){
        if(($null -ne $pa) -and ($null -ne $pb) -and ($pb -gt $pa)){$direction='Up';$coverageText+=' ; des postes jusque-là non mesurés entrent dans le score'}
        elseif(($null -ne $pa) -and ($null -ne $pb) -and ($pb -lt $pa)){$direction='Down';$coverageText+=' ; des postes sortent du score faute de données'}
        else{$coverageText+=' ; données disponibles différentes'}
    }
    # Rules: thresholds, enabled rules, custom alerts and suspensions active at computation time.
    $policyHash=& $hash 'PolicyHash'
    $policyStatus=switch($policyHash){'Same'{'Inchangé'}'Changed'{'Modifié'}default{'Inconnu'}}
    $policyText=switch($policyHash){'Same'{'Règles, seuils et suspensions actives identiques'}'Changed'{'Règles, seuils ou suspensions actives modifiés'}default{'Règles non décrites par ce relevé'}}
    # Observed state of the assessed workstations.
    $ha=& $number $a 'Healthy';$hb=& $number $b 'Healthy';$xa=& $number $a 'Problems';$xb=& $number $b 'Problems';$sa=& $number $a 'Score';$sb=& $number $b 'Score'
    $stateStatus=if(($null -eq $xa) -or ($null -eq $xb) -or ($null -eq $ha) -or ($null -eq $hb)){'Inconnu'}elseif(($xa -eq $xb) -and ($ha -eq $hb)){'Inchangé'}else{'Modifié'}
    $stateText='Avec un problème : '+(& $arrow $xa $xb)+' · sans problème détecté : '+(& $arrow $ha $hb)+' · score : '+$(if(($null -eq $sa) -or ($null -eq $sb)){'non calculé sur au moins un relevé'}else{& $arrow $sa $sb})
    $factors=@(
        [pscustomobject]@{Factor='Périmètre';Status=$perimeterStatus;Text=$perimeterText}
        [pscustomobject]@{Factor='Couverture';Status=$coverageStatus;Text=$coverageText}
        [pscustomobject]@{Factor='Règles';Status=$policyStatus;Text=$policyText}
        [pscustomobject]@{Factor='État observé';Status=$stateStatus;Text=$stateText}
    )
    $causes=@($factors|Select-Object -First 3|Where-Object{$_.Status -eq 'Modifié'}|ForEach-Object{$_.Factor})
    $unknown=@($factors|Select-Object -First 3|Where-Object{$_.Status -eq 'Inconnu'}).Count
    if($unknown){
        $category='Limitée';$summary='Comparaison limitée aux compteurs : un des relevés ne décrit pas sa population, sa couverture ou ses règles. Ne pas lire la variation du score comme un gain ou une dégradation du parc.'
    }elseif(-not $causes.Count){
        if($stateStatus -eq 'Inchangé'){$category='Stable';$summary='Aucun changement : même population, même couverture, mêmes règles et même état observé.'}
        else{$category='Réel';$summary='Changement réel de lʼétat observé : même population, mêmes données et mêmes règles. Ce constat ne dit pas pourquoi lʼétat a changé.'}
    }elseif($causes.Count -gt 1){
        $category='Mixte';$summary='Effets mêlés ('+(($causes|ForEach-Object{$_.ToLowerInvariant()}) -join ', ')+' modifiés) : ne pas lire la variation du score comme un gain ou une dégradation du parc.'
    }else{
        switch($causes[0]){
            'Périmètre'{$category='Périmètre';$summary='Évolution du périmètre : des postes sont entrés ou sortis ; la variation ne décrit pas un changement dʼétat des mêmes postes.'}
            'Couverture'{$category='Couverture';$summary=if($direction -eq 'Up'){'Amélioration de la couverture : davantage de postes ou de données évalués ; une baisse du score peut révéler des problèmes jusque-là non mesurés.'}elseif($direction -eq 'Down'){'Couverture réduite : moins de postes ou de données évalués ; une hausse du score peut venir de postes qui ne sont plus mesurés.'}else{'Couverture modifiée : les données disponibles ne sont plus les mêmes ; la variation ne décrit pas seulement lʼétat du parc.'}}
            default{$category='Règles';$summary='Règles modifiées : la variation peut venir des seuils, des contrôles activés ou des suspensions, pas du parc.'}
        }
    }
    $rows=[Collections.Generic.List[object]]::new()
    foreach($pair in @(@('Comptes activés','Machines'),@('Postes évalués','Assessed'),@('Postes incomplets','Unassessed'),@('Sans problème détecté','Healthy'),@('Avec un problème','Problems'),@('Ping renseigné','PingRead'),@('Inventaire WMI renseigné','WmiRead'),@('Score','Score'))){
        $old=& $number $a $pair[1];$new=& $number $b $pair[1]
        $rows.Add([pscustomobject]@{Measure=$pair[0];Before=(& $text $old);After=(& $text $new);Delta=(& $signed $old $new)})
    }
    $rows.Add([pscustomobject]@{Measure='Part des comptes évalués (%)';Before=(& $text $pa);After=(& $text $pb);Delta=(& $signed $pa $pb)})
    [pscustomobject]@{Comparable=($category -in @('Stable','Réel'));Category=$category;Summary=$summary;Factors=$factors;Limits=$limits.ToArray();Rows=$rows.ToArray();Swapped=$swapped;BeforeLabel=[string](Get-DomeniaHealthValue $Before 'Label' '');AfterLabel=[string](Get-DomeniaHealthValue $After 'Label' '')}
}
function Get-DomeniaFleetPivots {
    # Every non-empty cell owns the complete set of GUIDs; unread dimensions remain explicit categories.
    param($Data)
    $dimensions=@{};foreach($name in @('fleet.ou','fleet.versions','fleet.models','fleet.ram','fleet.presence','fleet.bios')){$dimensions[$name]=@{}}
    foreach($key in $Data.Last.WidgetTargets.Keys){foreach($name in $dimensions.Keys){$prefix=$name+'|';if(-not ([string]$key).StartsWith($prefix,[StringComparison]::Ordinal)){continue};$label=([string]$key).Substring($prefix.Length);foreach($target in $Data.Last.WidgetTargets[$key]){$dimensions[$name][[string]$target.object_guid]=$label}}}
    $tables=@{OuWindows=@{};ModelRam=@{};SiteCoverage=@{};ModelBios=@{}};$seen=@{}
    foreach($target in $Data.Last.Targets){
        $guid=[string]$target.object_guid;if(-not $guid -or $seen.ContainsKey($guid)){continue};$seen[$guid]=$true
        $site=[string]$dimensions['fleet.ou'][$guid];if(-not $site){$site='OU non renseignée'}
        $windows=[string]$dimensions['fleet.versions'][$guid];if(-not $windows){$windows='Version non lue'}
        $model=[string]$dimensions['fleet.models'][$guid];if(-not $model){$model='Modèle non lu'}
        $ram=[string]$dimensions['fleet.ram'][$guid];if(-not $ram){$ram='RAM non lue'}
        # Point 85: a workstation without a dated BIOS reading stays in its own explicit column.
        $bios=[string]$dimensions['fleet.bios'][$guid];if(-not $bios){$bios='BIOS non relevé'}
        # Coverage of the data the health rules use: ping read (answer or not) and light WMI inventory read. A console-only
        # CIM answer counts in fleet.wmi but not here, so the labels name the inventory (point 72 keeps both apart).
        $ping=([string]$dimensions['fleet.presence'][$guid] -in @('En ligne','Sans réponse'));$wmi=$Data.HealthInventoryKnown.ContainsKey($guid)
        $coverage=if($ping -and $wmi){'Ping et inventaire WMI'}elseif($ping){'Ping sans inventaire WMI'}elseif($wmi){'Inventaire WMI sans ping'}else{'Ni ping ni inventaire WMI'}
        foreach($pair in @(@('OuWindows',$site,$windows),@('ModelRam',$model,$ram),@('SiteCoverage',$site,$coverage),@('ModelBios',$model,$bios))){
            $row=[string]$pair[1];$col=[string]$pair[2];$key=$row.Length.ToString()+':'+$row+$col.Length.ToString()+':'+$col;$table=$tables[$pair[0]]
            if(-not $table.ContainsKey($key)){$table[$key]=[pscustomobject]@{Row=$row;Column=$col;Count=0;Targets=[Collections.Generic.List[object]]::new()}}
            $cell=$table[$key];$cell.Count++;$cell.Targets.Add($target)
        }
    }
    # Natural column order where one exists (memory buckets, coverage levels); otherwise by size (point 79).
    $ramOrder=@(@(Get-DomeniaHealthValue (Get-DomeniaHealthValue $Data.Entries 'fleet.ram') 'Items' @())|ForEach-Object{[string]$_.Label})+@('RAM non lue')
    $orders=@{OuWindows=@();ModelRam=$ramOrder;SiteCoverage=@('Ping et inventaire WMI','Ping sans inventaire WMI','Inventaire WMI sans ping','Ni ping ni inventaire WMI');ModelBios=@()}
    $titles=@{OuWindows=@('OU','Version de Windows');ModelRam=@('Modèle','RAM');SiteCoverage=@('OU / site','Couverture');ModelBios=@('Modèle','Version du BIOS')}
    $result=@{};foreach($name in $tables.Keys){$rows=@($tables[$name].Values|Sort-Object Row,Column);foreach($cell in $rows){$cell.Targets=$cell.Targets.ToArray()};$result[$name]=[pscustomobject]@{Rows=$rows;Total=$seen.Count;Cells=$rows.Count;Scope=[string]$Data.Last.Scope;ColumnOrder=@($orders[$name]);RowTitle=[string]$titles[$name][0];ColumnTitle=[string]$titles[$name][1]}}
    return $result
}
function ConvertTo-DomeniaPivotMatrix {
    # Point 79: rectangular view of one cross table with row, column and grand totals. Every workstation sits in exactly
    # one cell, so the totals always agree with the cells; a filter keeps whole cells whose row or column label
    # matches. Columns beyond -MaxColumns are folded into one visible remainder column, never dropped.
    param($Table,[string]$Filter='',[ValidateRange(2,64)][int]$MaxColumns=24)
    $filterText=([string]$Filter).Trim()
    $cells=@(@(Get-DomeniaHealthValue $Table 'Rows' @())|Where-Object{($null -ne $_) -and ((-not $filterText) -or (([string]$_.Row).IndexOf($filterText,[StringComparison]::OrdinalIgnoreCase) -ge 0) -or (([string]$_.Column).IndexOf($filterText,[StringComparison]::OrdinalIgnoreCase) -ge 0))})
    $columnCounts=@{};foreach($cell in $cells){$columnCounts[[string]$cell.Column]=[int]$columnCounts[[string]$cell.Column]+[int]$cell.Count}
    $ordered=[Collections.Generic.List[string]]::new()
    foreach($label in @(Get-DomeniaHealthValue $Table 'ColumnOrder' @())){if($columnCounts.ContainsKey([string]$label) -and (-not $ordered.Contains([string]$label))){$ordered.Add([string]$label)}}
    foreach($pair in @($columnCounts.GetEnumerator()|Sort-Object @{Expression={[int]$_.Value};Descending=$true},@{Expression={[string]$_.Key};Descending=$false})){if(-not $ordered.Contains([string]$pair.Key)){$ordered.Add([string]$pair.Key)}}
    $folded=0;$columns=$ordered.ToArray()
    if($columns.Count -gt $MaxColumns){$folded=$columns.Count-($MaxColumns-1);$columns=@($columns[0..($MaxColumns-2)])+@('Autres colonnes ('+$folded+')')}
    $index=@{};for($i=0;$i -lt $columns.Count;$i++){$index[$columns[$i]]=$i};$other=$columns.Count-1
    $width=$columns.Count;$rowsByLabel=@{};$rowOrder=[Collections.Generic.List[string]]::new()
    $columnTotals=New-Object 'int[]' $width;$columnTargets=@(for($i=0;$i -lt $width;$i++){,([Collections.Generic.List[object]]::new())})
    $grand=0
    foreach($cell in $cells){
        $rowLabel=[string]$cell.Row;$position=if($index.ContainsKey([string]$cell.Column)){[int]$index[[string]$cell.Column]}else{$other}
        if(-not $rowsByLabel.ContainsKey($rowLabel)){$rowsByLabel[$rowLabel]=[pscustomobject]@{Label=$rowLabel;Counts=(New-Object 'int[]' $width);Targets=@(for($i=0;$i -lt $width;$i++){,([Collections.Generic.List[object]]::new())});Total=0;AllTargets=[Collections.Generic.List[object]]::new()};$rowOrder.Add($rowLabel)}
        $row=$rowsByLabel[$rowLabel];$count=[int]$cell.Count;$members=@($cell.Targets)
        $row.Counts[$position]+=$count;$row.Total+=$count;$row.Targets[$position].AddRange($members);$row.AllTargets.AddRange($members)
        $columnTotals[$position]+=$count;$columnTargets[$position].AddRange($members);$grand+=$count
    }
    $rows=@($rowOrder|Sort-Object|ForEach-Object{$rowsByLabel[$_]})
    [pscustomobject]@{Columns=@($columns);Rows=$rows;ColumnTotals=$columnTotals;ColumnTargets=$columnTargets;GrandTotal=$grand;Folded=$folded;Cells=$cells.Count;Total=[int](Get-DomeniaHealthValue $Table 'Total' 0);RowTitle=[string](Get-DomeniaHealthValue $Table 'RowTitle' 'Ligne');ColumnTitle=[string](Get-DomeniaHealthValue $Table 'ColumnTitle' 'Colonne');Filtered=[bool]$filterText}
}
