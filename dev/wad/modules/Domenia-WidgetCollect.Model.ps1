# Per-widget collection and explanation (decision David 2026-10-14, points 6, 73 and 74). Every widget names the source
# of its figure, what refreshing that widget alone collects for the population of its board (the selected
# workstation, or the active workstations of the OU shown on Accueil, never the whole domain), what pausing it
# changes, and how its figure is computed. Pure rules: no WPF, no network, no disk.

# key|source|formula|criteria|exclusions. Sources: Directory (OU read into the local base), Presence (ping), Console
# (console user read by WMI), Inventory (light WMI reading), BitLocker (presence of the recovery objects of the OU),
# Local (computed from data already stored), ComputerQuick / ComputerDeep (inventory of the selected workstation),
# Card (attributes reread with the object card), Software (software list of the workstation).
$script:DomeniaWidgetSourceText = @'
fleet.health|Local|Score = postes évalués sans point détecté ÷ postes évalués × 100.|Règles de santé activées et seuils de la politique applicable à chaque OU.|Comptes désactivés ; postes incomplets (donnée nécessaire absente ou expirée) retirés du dénominateur et jamais comptés sains ; score retenu sous 50 % de couverture.
fleet.attention|Local|Contrôles en défaut, du plus grave au moins grave ; chaque point compte ses postes une fois.|Règles de santé activées.|Règles désactivées ou suspendues ; comptes désactivés.
fleet.machines|Directory|Nombre de comptes ordinateur du périmètre.|Tous les comptes de la base locale : activés, désactivés et état inconnu.|Aucune.
fleet.enabled|Directory|Nombre de comptes ordinateur activés.|userAccountControl sans le drapeau de désactivation.|Comptes désactivés ou à lʼétat inconnu ; ce nombre ne décrit pas la présence réseau.
fleet.accountunknown|Directory|Nombre de comptes dont lʼétat nʼest pas lu.|userAccountControl absent de la copie locale.|Comptes activés et désactivés.
fleet.accountstatus|Directory|Répartition des comptes : activés, désactivés, état inconnu.|userAccountControl de la copie locale.|Aucune.
fleet.stale|Directory|Comptes activés dont la dernière connexion AD dépasse le seuil dʼinactivité.|lastLogonTimestamp répliqué, précis à 14 jours près ; seuil de la politique.|Comptes désactivés ; dates inconnues comptées à part.
fleet.disabled|Directory|Nombre de comptes ordinateur désactivés encore dans le périmètre.|userAccountControl avec le drapeau de désactivation.|Comptes activés ou à lʼétat inconnu.
fleet.created|Directory|Comptes activés créés ces 30 derniers jours.|Attribut whenCreated lu avec la base.|Comptes désactivés ; attribut non lu.
fleet.pwdold|Directory|Comptes activés dont le mot de passe machine dépasse le seuil.|Attribut pwdLastSet ; seuil de la politique.|Comptes désactivés ; attribut non lu.
fleet.servers|Directory|Répartition des comptes activés entre serveurs et postes de travail.|Attribut operatingSystem et famille de la table des fins de service.|Comptes désactivés.
fleet.laps|Directory|Comptes activés sans expiration LAPS visible.|Attributs dʼexpiration LAPS lus avec la base, jamais le mot de passe.|Comptes désactivés ; rien nʼest compté tant quʼaucune expiration nʼest visible avec ce compte.
fleet.bitlocker|BitLocker|Comptes activés sans clé de récupération BitLocker visible.|Objets de récupération de lʼOU lus sur demande : nom, emplacement et date, jamais la clé.|Comptes désactivés ; rien nʼest compté tant quʼaucune clé nʼest visible avec ce compte.
fleet.versions|Directory|Répartition des comptes activés par version de Windows.|Attributs operatingSystem et operatingSystemVersion.|Comptes désactivés.
fleet.eos|Directory|Comptes activés dont la version nʼest plus maintenue.|Build AD comparé à la table des fins de service livrée.|Comptes désactivés ; version non lue.
fleet.win10|Directory|Comptes activés sous Windows 10.|Attribut operatingSystem et build.|Éditions LTSC, LTSB et IoT ; comptes désactivés.
fleet.os|Directory|Répartition des comptes activés par système dʼexploitation.|Attribut operatingSystem.|Comptes désactivés.
fleet.lastlogon|Directory|Répartition des comptes activés par ancienneté de la dernière connexion au domaine.|lastLogonTimestamp répliqué, précis à 14 jours près.|Comptes désactivés.
fleet.ou|Directory|Comptes activés par OU ou sous-OU.|OU parente de chaque compte.|Comptes désactivés.
fleet.presence|Presence|Répartition des comptes activés par dernier résultat de ping.|Ping daté par le poste qui lʼa mesuré, conservé selon la durée de conservation.|Comptes désactivés ; ping expiré compté Non vérifié, jamais éteint.
fleet.users|Console|Utilisateurs distincts vus en session console.|Lecture WMI de la console, datée et conservée selon la durée de conservation.|Sessions RDP ; lectures expirées.
fleet.lastcheck|Presence|Date du ping le plus récent du périmètre.|Pings datés des comptes activés.|Pings expirés.
fleet.models|Inventory|Répartition des postes analysés par modèle.|Relevé WMI léger (Win32_ComputerSystem) daté.|Postes sans relevé exploitable ; relevés expirés.
fleet.releases|Inventory|Répartition des postes analysés par version relevée.|Build lu par WMI (Win32_OperatingSystem).|Postes sans relevé exploitable ; relevés expirés.
fleet.ram|Inventory|Postes analysés par quantité de mémoire installée.|TotalPhysicalMemory lu par WMI.|Postes sans relevé exploitable ; relevés expirés.
fleet.diskfree|Inventory|Postes analysés par espace libre du disque C:.|Win32_LogicalDisk C: ; seuils de la politique.|Postes sans taille de disque lue ; relevés expirés.
fleet.lowdisk|Inventory|Postes analysés dont C: est sous le seuil critique dʼespace libre.|Win32_LogicalDisk C: ; seuil de la politique.|Postes sans taille de disque lue ; relevés expirés.
fleet.uptime|Inventory|Postes analysés non redémarrés depuis plus de 30 jours.|LastBootUpTime lu par WMI.|Postes sans date de démarrage lue ; relevés expirés.
fleet.trend|Local|Nombre de postes à traiter, un point par instantané quotidien.|Instantanés locaux de lʼOU affichée.|Jours sans instantané ; les postes de chaque jour ne sont pas conservés.
fleet.trend.win10|Local|Postes sous Windows 10 hors LTSC, LTSB et IoT, un point par instantané quotidien.|Instantanés locaux de lʼOU affichée.|Jours sans instantané ; les postes de chaque jour ne sont pas conservés.
fleet.trend.stale|Local|Postes sans connexion depuis le seuil dʼinactivité, un point par instantané quotidien.|Instantanés locaux de lʼOU affichée.|Jours sans instantané ; les postes de chaque jour ne sont pas conservés.
fleet.trend.lowdisk|Local|Postes analysés avec C: presque plein, un point par instantané quotidien.|Instantanés locaux de lʼOU affichée.|Jours sans instantané ; les postes de chaque jour ne sont pas conservés.
computer.health|Local|Score = 100 − 25 par point critique − 10 par point à surveiller, minimum 0.|Contrôles activés dans les règles de santé du poste.|Contrôles non lus : le score est retenu et lʼévaluation déclarée incomplète.
computer.attention|Local|Contrôles en défaut du poste, du plus grave au moins grave.|Contrôles activés dans les règles de santé du poste.|Contrôles désactivés ou suspendus.
computer.os|ComputerQuick|Version commerciale déduite du build de Windows.|Win32_OperatingSystem et table des fins de service livrée.|Aucune.
computer.model|ComputerQuick|Fabricant, modèle et numéro de série du châssis.|Win32_ComputerSystem et Win32_SystemEnclosure.|Valeurs que le fabricant ne renseigne pas.
computer.cpu|ComputerQuick|Modèle, cœurs et threads du premier processeur.|Win32_Processor.|Aucune.
computer.memory|ComputerQuick|Mémoire physique installée.|Win32_PhysicalMemory, sinon Win32_ComputerSystem.|Barrettes non exposées (machines virtuelles).
computer.uptime|ComputerQuick|Durée depuis le dernier démarrage, au moment de lʼinventaire.|Win32_OperatingSystem.LastBootUpTime.|Aucune.
computer.user|ComputerQuick|Compte en session console au moment de lʼinventaire.|Win32_ComputerSystem.UserName.|Sessions RDP.
computer.ip|ComputerQuick|Première adresse IPv4 et passerelle de la même carte.|Win32_NetworkAdapterConfiguration.|Cartes sans adresse.
computer.domain|ComputerQuick|Domaine et rôle du poste.|Win32_ComputerSystem.|Aucune.
computer.ad.password|Card|Âge du mot de passe du compte ordinateur.|Attribut pwdLastSet lu avec la fiche.|Aucune.
computer.ad.lastlogon|Card|Ancienneté de la dernière connexion au domaine.|lastLogonTimestamp lu avec la fiche, précis à 14 jours près.|Aucune.
computer.ad.account|Card|Compte activé ou désactivé, et date de création.|userAccountControl et whenCreated lus avec la fiche.|Aucune.
computer.ad.ou|Card|OU qui contient le compte.|DN du compte lu avec la fiche.|Aucune.
computer.ad.laps|Card|Expiration du mot de passe administrateur local.|Attributs dʼexpiration LAPS lus avec la fiche, jamais le mot de passe.|Attribut non visible avec ce compte.
computer.ad.managedby|Card|Responsable déclaré du poste.|Attribut managedBy lu avec la fiche.|Aucune.
computer.ad.clock|ComputerQuick|Écart entre lʼhorloge du poste et la référence disponible.|Heure lue pendant lʼinventaire, comparée au contrôleur ou au poste dʼadministration.|Aucune.
computer.memory.usage|ComputerQuick|Mémoire occupée ÷ mémoire installée, au moment de lʼinventaire.|Win32_OperatingSystem.FreePhysicalMemory ; seuil de la politique.|Aucune.
computer.cpu.load|ComputerQuick|Charge du processeur au moment de lʼinventaire.|Win32_Processor.LoadPercentage.|Aucune.
computer.battery|ComputerQuick|Charge restante de la batterie.|Win32_Battery.EstimatedChargeRemaining ; seuil de la politique.|Postes sans batterie.
computer.disk.system|ComputerQuick|Espace libre ÷ taille du disque système.|Win32_LogicalDisk C: ; seuils de la politique.|Aucune.
computer.disk.volumes|ComputerQuick|Espace libre des autres volumes, en pourcentage.|Win32_LogicalDisk.|Disque système.
computer.services|ComputerQuick|Services en cours, arrêtés et désactivés.|Win32_Service.|Aucune.
computer.processes|ComputerDeep|Mémoire utilisée par processus, les plus gourmands.|Win32_Process, lu par lʼinventaire complet.|Processus au-delà des premiers.
computer.events|ComputerDeep|Erreurs du journal Système par source sur 3 jours.|Win32_NTLogEvent, lu par lʼinventaire complet.|Erreurs connues sans gravité.
computer.antivirus|ComputerQuick|Produit antivirus déclaré à Windows.|Centre de sécurité Windows (SecurityCenter2).|Serveurs sans centre de sécurité.
computer.firewall|ComputerQuick|État effectif du pare-feu par profil.|Registre FirewallPolicy ; la stratégie prime sur la clé locale.|Aucune.
computer.bitlocker|ComputerQuick|Protection du volume système.|Win32_EncryptableVolume.|Autres volumes.
computer.wsus|ComputerQuick|Serveur WSUS configuré.|Registre WindowsUpdate.|Aucune.
computer.reboot|ComputerQuick|Redémarrage demandé par une installation.|Clés de registre de redémarrage en attente.|Aucune.
computer.services.stopped|ComputerQuick|Services automatiques à lʼarrêt.|Win32_Service.|Services démarrés sur déclencheur.
computer.devices|ComputerQuick|Périphériques signalés en erreur.|Win32_PnPEntity.|Aucune.
computer.drivers|ComputerQuick|Pilotes sans signature numérique.|Win32_PnPSignedDriver.|Aucune.
computer.admins|ComputerQuick|Membres du groupe Administrateurs du poste.|Win32_Group et Win32_GroupUser.|Aucune.
computer.sessions|ComputerQuick|Comptes locaux et sessions du poste.|Win32_UserAccount.|Aucune.
computer.autostart|ComputerQuick|Programmes lancés au démarrage.|Win32_StartupCommand.|Aucune.
computer.shares|ComputerQuick|Dossiers partagés par le poste.|Win32_Share.|Aucune.
computer.printers|ComputerQuick|Imprimantes installées.|Win32_Printer.|Aucune.
computer.display|ComputerQuick|Carte graphique et résolution.|Win32_VideoController.|Aucune.
computer.physicaldisk|ComputerQuick|Modèle et interface du disque.|Win32_DiskDrive.|Aucune.
computer.certificates|ComputerDeep|Certificats du magasin ordinateur.|Magasin LocalMachine\My, lu par lʼinventaire complet.|Aucune.
computer.hotfix|ComputerQuick|Ancienneté du dernier correctif installé.|Win32_QuickFixEngineering.|Mises à jour que QFE nʼexpose pas.
software.count|Software|Nombre de logiciels et dʼéditeurs de la liste.|Registre Uninstall du poste, lu sur demande.|Logiciels non déclarés dans le registre.
software.size|Software|Somme des tailles déclarées.|Tailles déclarées dans le registre Uninstall.|Logiciels sans taille déclarée.
software.recent|Software|Logiciels installés ces 30 derniers jours.|Date dʼinstallation déclarée par le logiciel.|Logiciels sans date déclarée.
software.multiversion|Software|Logiciels présents en plusieurs versions.|Nom et version de la liste.|Aucune.
software.nopublisher|Software|Logiciels sans éditeur déclaré.|Éditeur de la liste.|Aucune.
software.runtime|Software|Composants dʼexécution déclarés : Visual C++, .NET et WebView2.|Noms de la liste.|Aucune.
software.browsers|Software|Navigateurs détectés et leur version.|Noms et versions de la liste.|Aucune.
software.publishers|Software|Répartition par éditeur.|Éditeur de la liste.|Aucune.
software.architecture|Software|Répartition 32 et 64 bits.|Branche du registre lue.|Aucune.
software.scope|Software|Répartition entre installation machine et utilisateur.|Ruche du registre lue.|Aucune.
software.largest|Software|Logiciels les plus volumineux, en Mo.|Tailles déclarées dans le registre Uninstall.|Logiciels sans taille déclarée.
'@
$script:DomeniaWidgetSourceCache = $null

function Get-DomeniaWidgetSourceTable {
    # Parsed once: key -> {Key; Source; Formula; Criteria; Exclusions}. The text is immutable delivered data.
    $cache = $script:DomeniaWidgetSourceCache
    if (($null -ne $cache) -and ([string]$cache.Text -ceq [string]$script:DomeniaWidgetSourceText)) { return $cache.Index }
    $index = @{}
    foreach ($line in ([string]$script:DomeniaWidgetSourceText -split "`n")) {
        $text = $line.Trim()
        if (-not $text) { continue }
        $cells = @($text -split '\|')
        if ($cells.Count -ne 5) { continue }
        $index[[string]$cells[0]] = [pscustomobject]@{ Key = [string]$cells[0]; Source = [string]$cells[1]; Formula = [string]$cells[2]; Criteria = [string]$cells[3]; Exclusions = [string]$cells[4] }
    }
    $script:DomeniaWidgetSourceCache = [pscustomobject]@{ Text = [string]$script:DomeniaWidgetSourceText; Index = $index }
    return $index
}
function Get-DomeniaWidgetSource {
    # Source row of a built-in widget, or $null for a key the table does not know.
    param([string]$Key)
    $index = Get-DomeniaWidgetSourceTable
    if ($index.ContainsKey($Key)) { return $index[$Key] }
    return $null
}
function Get-DomeniaWidgetFieldNeeds {
    # Fields of a saved query to what a collection reads. A probe or instance field is a WMI query of the catalog,
    # inventory fields come from the light WMI reading, presence from the ping, user from the console read; detail
    # fields are custom WMI reads of the workshop; every other field comes from the AD copy of the local base.
    param([string[]]$Fields = @())
    $probes = New-Object System.Collections.Generic.List[string]
    $ping = $false; $console = $false; $inventory = $false; $directory = $false; $workshop = $false
    foreach ($field in @($Fields)) {
        $name = [string]$field
        if (-not $name) { continue }
        $id = ''
        if ($name -like 'probe:*') { $id = $name.Substring(6) }
        elseif ($name -match '^instance:([^:]+):') { $id = [string]$Matches[1] }
        if ($id) { if (-not $probes.Contains($id)) { $probes.Add($id) }; continue }
        if ($name -in @('model','ramGB','diskFreePercent','uptimeDays','inventoryDays','observedRelease')) { $inventory = $true }
        elseif ($name -in @('presence','presenceBucket','checkedDays')) { $ping = $true }
        elseif ($name -eq 'user') { $console = $true }
        elseif ($name -like 'detail:*') { $workshop = $true }
        else { $directory = $true }
    }
    return [pscustomobject]@{ ProbeIds = @($probes | Sort-Object); Ping = $ping; Console = $console; Inventory = $inventory; Directory = $directory; Workshop = $workshop }
}
function Get-DomeniaWidgetCollectionNeed {
    # What refreshing one widget alone reads, for the population of its board only. Kind:
    #   Remote            endpoint read through the pinned LiveConsole worker: ping, console, light inventory, probes
    #   ComputerInventory inventory of the selected workstation (Deep: the complete one)
    #   Directory         objects of the OU shown on Accueil reread into the local base (no ping, no WMI)
    #   Card              the selected object reread from AD
    #   BitLocker         presence of the BitLocker recovery objects of the OU (never a key)
    #   Software          software list of the selected workstation
    #   Local             computed from data already stored: nothing to collect
    #   Unknown           a widget whose source is not known: nothing is started
    # -Fields: requested fields of the saved query of a Query widget (Get-DomeniaQueryRequestedFields).
    # -RecipeMissing: the saved query of a Query widget is absent or ambiguous; nothing is started for it.
    param([ValidateSet('Computer','Fleet','Software')][string]$Board,$Item,[string[]]$Fields = @(),[switch]$RecipeMissing)
    $source = [string](Get-DomeniaMember $Item 'Source' '')
    $key = [string](Get-DomeniaMember $Item 'Key' '')
    $need = [ordered]@{ Board = $Board; Id = [string](Get-DomeniaMember $Item 'Id' ''); Source = $source; Key = $key; Kind = 'Unknown'; Ping = $false; Console = $false; Inventory = $false; Deep = $false; ProbeIds = @(); Workshop = $false; Directory = $false; Label = '' }
    if ($source -eq 'Probe') {
        if ($Board -ne 'Software') { $need.Kind = 'Remote'; $need.ProbeIds = @($key) }
    } elseif (($source -eq 'Query') -and (-not $RecipeMissing)) {
        $parts = Get-DomeniaWidgetFieldNeeds -Fields $Fields
        $need.ProbeIds = @($parts.ProbeIds); $need.Ping = [bool]$parts.Ping; $need.Console = [bool]$parts.Console; $need.Inventory = [bool]$parts.Inventory; $need.Workshop = [bool]$parts.Workshop; $need.Directory = [bool]$parts.Directory
        if ($need.ProbeIds.Count -or $need.Ping -or $need.Console -or $need.Inventory) { $need.Kind = 'Remote' }
        elseif ($parts.Directory) { $need.Kind = $(if ($Board -eq 'Computer') { 'Card' } else { 'Directory' }) }
        elseif (-not $parts.Workshop) { $need.Kind = 'Local' }
    } elseif ($source -eq 'Builtin') {
        $row = Get-DomeniaWidgetSource -Key $key
        $kind = if ($null -ne $row) { [string]$row.Source } else { '' }
        switch ($kind) {
            'Presence' { $need.Kind = 'Remote'; $need.Ping = $true }
            'Console' { $need.Kind = 'Remote'; $need.Console = $true }
            'Inventory' { $need.Kind = 'Remote'; $need.Inventory = $true }
            'ComputerQuick' { $need.Kind = 'ComputerInventory' }
            'ComputerDeep' { $need.Kind = 'ComputerInventory'; $need.Deep = $true }
            'Directory' { $need.Kind = 'Directory' }
            'Card' { $need.Kind = 'Card' }
            'BitLocker' { $need.Kind = 'BitLocker' }
            'Software' { $need.Kind = 'Software' }
            'Local' { $need.Kind = 'Local' }
        }
    }
    $need.Label = Get-DomeniaWidgetNeedText -Need ([pscustomobject]$need)
    return [pscustomobject]$need
}
function Get-DomeniaWidgetNeedText {
    # What the refresh of this widget reads, in plain words, with its population.
    param($Need)
    $board = [string](Get-DomeniaMember $Need 'Board' '')
    $population = if ($board -eq 'Fleet') { 'les postes actifs de lʼOU affichée' } else { 'le poste sélectionné' }
    switch ([string](Get-DomeniaMember $Need 'Kind' '')) {
        'Remote' {
            $parts = New-Object System.Collections.Generic.List[string]
            if ([bool](Get-DomeniaMember $Need 'Ping' $false)) { $parts.Add('ping') }
            if ([bool](Get-DomeniaMember $Need 'Console' $false)) { $parts.Add('utilisateur console (WMI)') }
            if ([bool](Get-DomeniaMember $Need 'Inventory' $false)) { $parts.Add('relevé WMI léger') }
            $probes = @(Get-DomeniaMember $Need 'ProbeIds' @()).Count
            if ($probes) { $parts.Add([string]$probes + ' requête(s) WMI de ce widget') }
            $text = 'Relit seulement : ' + ($parts -join ', ') + ', pour ' + $population + ', en lecture seule.'
            if ([bool](Get-DomeniaMember $Need 'Directory' $false)) { $text += ' Les attributs AD restent ceux de la base locale.' }
            if ([bool](Get-DomeniaMember $Need 'Workshop' $false)) { $text += ' Les relevés WMI personnalisés de la requête se relancent depuis lʼatelier.' }
            return $text
        }
        'ComputerInventory' { if ([bool](Get-DomeniaMember $Need 'Deep' $false)) { return 'Inventaire complet du poste sélectionné (environ 3 minutes), en lecture seule.' }; return 'Inventaire rapide du poste sélectionné (environ 1 minute), en lecture seule.' }
        'Directory' { return 'Relit les objets AD de lʼOU affichée et de ses sous-OU dans la base locale ; aucun ping ni WMI.' }
        'Card' { return 'Relit la fiche du poste sélectionné depuis lʼannuaire.' }
        'BitLocker' { return 'Lit la présence des clés BitLocker de lʼOU affichée : nom, emplacement et date, jamais la clé.' }
        'Software' { return 'Recharge la liste des logiciels du poste sélectionné.' }
        'Local' { return 'Recalcule depuis les données enregistrées, sans collecte.' }
    }
    if ([bool](Get-DomeniaMember $Need 'Workshop' $false)) { return 'Cette requête lit des relevés WMI personnalisés : relancez-les depuis lʼatelier.' }
    return 'Source inconnue : aucune collecte nʼest lancée pour ce widget.'
}
function Get-DomeniaWidgetPauseText {
    # What pausing this widget changes, without promising a saving that does not exist: a reading shared by other
    # widgets (inventory of the workstation, AD copy, ping and light WMI used by the health) stays as it is.
    param($Need)
    $kind = [string](Get-DomeniaMember $Need 'Kind' '')
    if ($kind -eq 'Remote') {
        $probes = @(Get-DomeniaMember $Need 'ProbeIds' @()).Count
        $shared = New-Object System.Collections.Generic.List[string]
        if ([bool](Get-DomeniaMember $Need 'Ping' $false)) { $shared.Add('ping') }
        if ([bool](Get-DomeniaMember $Need 'Console' $false)) { $shared.Add('console') }
        if ([bool](Get-DomeniaMember $Need 'Inventory' $false)) { $shared.Add('WMI léger') }
        $text = 'Mesure suspendue'
        if ($probes) { $text += ' : aucune requête WMI nʼest lancée pour ce widget' }
        $why = if ([string](Get-DomeniaMember $Need 'Board' '') -eq 'Fleet') { ') reste lu par les actions de liste, car la santé du parc lʼutilise.' } else { ') reste lu par les autres actions du poste.' }
        if ($shared.Count) { $text += $(if ($probes) { '. ' } else { ' : ce widget nʼest plus actualisé. ' }) + 'Le relevé commun (' + ($shared -join ', ') + $why }
        else { $text += '.' }
        return $text
    }
    switch ($kind) {
        'ComputerInventory' { return 'Widget suspendu : il nʼest plus calculé. Lʼinventaire du poste reste une lecture commune à tous ses widgets.' }
        'Directory' { return 'Widget suspendu : il nʼest plus calculé ni actualisé ; la base locale reste mise à jour par lʼOU.' }
        'Card' { return 'Widget suspendu : il nʼest plus calculé ; la fiche du poste reste lue à son ouverture.' }
        'BitLocker' { return 'Mesure suspendue : la présence des clés BitLocker nʼest plus lue pour ce widget.' }
        'Software' { return 'Widget suspendu : il nʼest plus calculé ; la liste des logiciels reste commune.' }
    }
    return 'Widget suspendu : il nʼest plus calculé.'
}
function Get-DomeniaWidgetCollectAdmission {
    # Adding, resuming or refreshing one widget is the explicit gesture (decision David 2026-10-14): its collection
    # starts at once for a population of at most Limit workstations; a larger population asks the inline
    # confirmation with its count first. Limit: 200 workstations by default, bounded 1 to 2000 when given.
    param([int]$TargetCount,[int]$Limit = 200)
    $bounded = [Math]::Max(1, [Math]::Min(2000, $Limit))
    $count = [Math]::Max(0, $TargetCount)
    return [pscustomobject]@{ Direct = (($count -ge 1) -and ($count -le $bounded)); Limit = $bounded; Count = $count }
}
function Test-DomeniaWidgetMeasureUsable {
    # One stored measurement answers the widget: no error, not truncated, dated and younger than MaxAgeDays. A probe
    # skipped as not applicable (domain controller) is an answer, not a missing value.
    param($Value,[int]$MaxAgeDays = 30,[datetime]$NowUtc = [datetime]::UtcNow,[string]$DateName = 'CheckedUtc')
    if ($null -eq $Value) { return $false }
    if ([string](Get-DomeniaMember $Value 'Error' '')) { return $false }
    if ([bool](Get-DomeniaMember $Value 'Truncated' $false)) { return $false }
    return ((Test-DomeniaObservationAge -CheckedUtc ([string](Get-DomeniaMember $Value $DateName '')) -NowUtc $NowUtc -MaxDays $MaxAgeDays) -ne 'Expired')
}
function Select-DomeniaWidgetMissingTargets {
    # Workstations of the board population that lack a usable measurement for this widget (collect only what is
    # missing, decision David 2026-10-14). Observations: lower-case DN -> stored observation of the snapshot; an
    # observation of another GUID (workstation recreated under the same DN) never counts. Only the families the
    # widget reads are checked: probes, light inventory, ping, console. Bounded by the population given (never
    # more than the OU shown or the selected workstation).
    param([object[]]$Targets = @(),$Observations = $null,$Need,[int]$MaxAgeDays = 30,[datetime]$NowUtc = [datetime]::UtcNow)
    $probeIds = @(Get-DomeniaMember $Need 'ProbeIds' @())
    $inventory = [bool](Get-DomeniaMember $Need 'Inventory' $false)
    $ping = [bool](Get-DomeniaMember $Need 'Ping' $false)
    $console = [bool](Get-DomeniaMember $Need 'Console' $false)
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        $observation = $null
        $dn = ([string](Get-DomeniaMember $target 'distinguished_name' '')).ToLowerInvariant()
        if ($dn -and ($Observations -is [Collections.IDictionary]) -and (Test-DomeniaDictionaryKey $Observations $dn)) { $observation = $Observations[$dn] }
        $guid = ([string](Get-DomeniaMember $observation 'Guid' '')).Trim().Trim('{','}')
        $expected = ([string](Get-DomeniaMember $target 'object_guid' '')).Trim().Trim('{','}')
        if (($null -eq $observation) -or ($guid -and $expected -and ($guid -ine $expected))) { $missing.Add($target); continue }
        $complete = $true
        $probes = Get-DomeniaMemberValue $observation 'Probes'
        foreach ($id in $probeIds) { if (-not (Test-DomeniaWidgetMeasureUsable -Value (Get-DomeniaMemberValue $probes ([string]$id)) -MaxAgeDays $MaxAgeDays -NowUtc $NowUtc)) { $complete = $false; break } }
        if ($complete -and $inventory) { $complete = Test-DomeniaWidgetMeasureUsable -Value (Get-DomeniaMemberValue $observation 'Inventory') -MaxAgeDays $MaxAgeDays -NowUtc $NowUtc }
        if ($complete -and $ping) { $complete = ((Test-DomeniaObservationAge -CheckedUtc ([string](Get-DomeniaMember $observation 'PresenceCheckedUtc' '')) -NowUtc $NowUtc -MaxDays $MaxAgeDays) -ne 'Expired') }
        if ($complete -and $console) {
            $at = ''
            foreach ($name in @('UserCheckedUtc','ConsoleCheckedUtc','ObservedUtc')) { $at = [string](Get-DomeniaMember $observation $name ''); if ($at) { break } }
            $complete = ((Test-DomeniaObservationAge -CheckedUtc $at -NowUtc $NowUtc -MaxDays $MaxAgeDays) -ne 'Expired')
        }
        if (-not $complete) { $missing.Add($target) }
    }
    return @($missing.ToArray())
}
function Format-DomeniaWidgetCollectProgress {
    # Progress line of a widget whose data is being collected; the figure stays the last one actually read.
    param([ValidateSet('Queued','Preparing','Confirming','Running','Inventory','Directory','BitLocker','Card','Software','Local')][string]$Phase,[int]$Done = 0,[int]$Total = 0,[int]$Fresh = 0,[int]$Failed = 0)
    switch ($Phase) {
        'Queued' { return 'En file : démarre après le relevé en cours.' }
        'Preparing' { return 'Préparation de la collecte…' }
        'Confirming' { return ('Collecte en attente de confirmation · ' + [string]$Total + ' poste(s)') }
        'Running' {
            $text = 'Collecte en cours · ' + [string]$Done + '/' + [string]$Total + ' poste(s)'
            if ($Fresh -gt 0) { $text += ' · ' + [string]$Fresh + ' déjà à jour' }
            if ($Failed -gt 0) { $text += ' · ' + [string]$Failed + ' non confirmé(s)' }
            return $text
        }
        'Inventory' { return 'Inventaire du poste en cours…' }
        'Directory' { return 'Lecture AD de lʼOU en cours…' }
        'BitLocker' { return 'Lecture des clés BitLocker de lʼOU en cours…' }
        'Card' { return 'Relecture de la fiche en cours…' }
        'Software' { return 'Lecture des logiciels en cours…' }
        'Local' { return 'Recalcul local en cours…' }
    }
    return ''
}
function Get-DomeniaWidgetPlaceholder {
    # Card of a widget that has no figure (decision David 2026-10-14, replaces Non lu par cet inventaire): paused,
    # being collected or queued, read by the complete inventory only, absent from the last reading, or not collected
    # yet, with the button that acts on it. Never a measure. Action: Resume, Refresh or '' (nothing to offer).
    param($Need,[bool]$Paused = $false,[string]$Progress = '',[bool]$Collected = $false,[bool]$DeepRead = $false,[string]$CollectedAt = '')
    $kind = [string](Get-DomeniaMember $Need 'Kind' '')
    if ($Paused) { return [pscustomobject]@{ State = 'Paused'; Message = (Get-DomeniaWidgetPauseText -Need $Need); Action = 'Resume'; ActionText = 'Reprendre la mesure'; Glyph = [string][char]0xE769 } }
    if ($Progress) { return [pscustomobject]@{ State = 'Collecting'; Message = $Progress; Action = ''; ActionText = ''; Glyph = [string][char]0xE895 } }
    if (($kind -eq 'ComputerInventory') -and $Collected -and [bool](Get-DomeniaMember $Need 'Deep' $false) -and (-not $DeepRead)) {
        return [pscustomobject]@{ State = 'Deep'; Message = 'Lu par lʼinventaire complet seulement : le dernier inventaire était rapide.'; Action = 'Refresh'; ActionText = 'Inventaire complet'; Glyph = [string][char]0xE9D2 }
    }
    if ($kind -eq 'Unknown') { return [pscustomobject]@{ State = 'Unknown'; Message = (Get-DomeniaWidgetNeedText -Need $Need); Action = ''; ActionText = ''; Glyph = [string][char]0xE9CE } }
    if ($Collected) {
        $when = if ($CollectedAt) { ' du ' + $CollectedAt } else { '' }
        $board = [string](Get-DomeniaMember $Need 'Board' '')
        $message = if ($board -eq 'Fleet') { 'Aucune valeur dans le dernier calcul' + $when + ' pour ce périmètre.' } elseif ($board -eq 'Software') { 'Aucune valeur dans la dernière liste' + $when + '.' } else { 'Absent du dernier relevé' + $when + ' : information non renvoyée pour ce poste.' }
        return [pscustomobject]@{ State = 'Absent'; Message = $message; Action = 'Refresh'; ActionText = $(if ($board -eq 'Fleet') { 'Actualiser' } else { 'Relire' }); Glyph = [string][char]0xE9D2 }
    }
    if ($kind -eq 'Local') { return [pscustomobject]@{ State = 'Missing'; Message = 'Pas encore calculé.'; Action = 'Refresh'; ActionText = 'Recalculer'; Glyph = [string][char]0xE9D2 } }
    return [pscustomobject]@{ State = 'Missing'; Message = 'Pas encore collecté pour ce tableau.'; Action = 'Refresh'; ActionText = 'Collecter'; Glyph = [string][char]0xE9D2 }
}
function Test-DomeniaComputerInventoryDeep {
    # The inventory result carries no mode: the categories read only by the complete inventory reveal it.
    param($Result)
    foreach ($row in @(Get-DomeniaMember $Result 'Rows' @())) {
        if ([string](Get-DomeniaMember $row 'Category' '') -in @('Processus','Evenements systeme','Taches planifiees','Certificats machine')) { return $true }
    }
    return $false
}
function Format-DomeniaWidgetDetailLabel {
    # Name of the exact selection opened from a widget (point 73): its title, the count it showed and the
    # calculation it comes from, so the list reads as that snapshot. Kept under 110 characters (recipe names: 120).
    param([string]$Title,[int]$Count,$ComputedAtUtc = $null)
    $when = ''
    if ($ComputedAtUtc -is [datetime]) { $when = ' · calcul du ' + $ComputedAtUtc.ToLocalTime().ToString('dd/MM HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
    $suffix = ' · ' + [string]$Count + ' poste' + $(if ($Count -gt 1) { 's' } else { '' }) + $when
    $head = ([string]$Title).Trim()
    if (($head.Length + $suffix.Length) -gt 110) { $head = $head.Substring(0, [Math]::Min($head.Length, [Math]::Max(10, 109 - $suffix.Length))) + [string][char]0x2026 }
    return $head + $suffix
}
function Test-DomeniaWidgetSnapshotCurrent {
    # A widget opens its exact list only from the calculation it was drawn from (point 73): a newer calculation
    # may count other workstations under the same title.
    param([string]$Drawn,[string]$Current)
    return ([bool]$Drawn -and ($Drawn -ceq $Current))
}
function Get-DomeniaWidgetExplanation {
    # Point 6: what one figure means, from the data the board already holds; nothing is read to explain it.
    # Rows {Aspect; Text}: displayed value, formula, perimeter, criteria, exclusions, coverage, dates, workstations
    # of the total and what refreshing this widget reads. TargetCount -1: no exact list is kept for this figure.
    param(
        [string]$Board,
        $Item,
        [string]$Title = '',
        $Entry = $null,
        $Need = $null,
        [string]$Scope = '',
        [string]$Coverage = '',
        $ComputedAtUtc = $null,
        [int]$TargetCount = -1,
        [string]$Formula = '',
        [string]$Criteria = '',
        [string]$Exclusions = '',
        [int]$MaxAgeDays = 30
    )
    $key = [string](Get-DomeniaMember $Item 'Key' '')
    $source = [string](Get-DomeniaMember $Item 'Source' '')
    $row = if ($source -eq 'Builtin') { Get-DomeniaWidgetSource -Key $key } else { $null }
    if ((-not $Formula) -and ($null -ne $row)) { $Formula = [string]$row.Formula }
    if ((-not $Criteria) -and ($null -ne $row)) { $Criteria = [string]$row.Criteria }
    if ((-not $Exclusions) -and ($null -ne $row)) { $Exclusions = [string]$row.Exclusions }
    if (-not $Formula) { $Formula = 'Formule non documentée pour ce widget.' }
    if (-not $Criteria) { $Criteria = 'Non documentés pour ce widget.' }
    if (-not $Exclusions) { $Exclusions = 'Non documentées pour ce widget.' }
    $kind = [string](Get-DomeniaMember $Need 'Kind' '')
    if ($kind -eq 'Remote') { $Exclusions += ' Relevés de plus de ' + [string]([Math]::Max(1, $MaxAgeDays)) + ' jours ignorés.' }
    $value = [string](Get-DomeniaMember $Entry 'Value' '')
    $detail = [string](Get-DomeniaMember $Entry 'Detail' '')
    $shown = if ($null -eq $Entry) { 'Aucune valeur : ce widget nʼa pas encore de donnée.' } elseif ($value -and $detail) { $value + ' · ' + $detail } elseif ($value) { $value } elseif ($detail) { $detail } else { 'Valeur vide.' }
    $dates = if ($ComputedAtUtc -is [datetime]) { 'Calcul local du ' + $ComputedAtUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) + '.' } else { 'Date de calcul non conservée.' }
    if ($kind -in @('Remote','ComputerInventory','Directory','Card','BitLocker','Software')) { $dates += ' Chaque mesure garde la date de sa collecte ; un recalcul ne la rajeunit pas.' }
    $members = if ($TargetCount -ge 0) { [string]$TargetCount + ' poste(s) : liste exacte des GUID conservée avec ce calcul, ouverte par Afficher les postes.' } else { 'Liste nominative non conservée pour ce chiffre.' }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($pair in @(
        @('Valeur affichée', $shown),
        @('Formule', $Formula),
        @('Périmètre', $(if ($Scope) { $Scope } else { 'Non précisé.' })),
        @('Critères', $Criteria),
        @('Exclusions', $Exclusions),
        @('Couverture', $(if ($Coverage) { $Coverage } else { 'Non mesurée pour ce chiffre.' })),
        @('Dates', $dates),
        @('Postes du total', $members),
        @('Actualiser ce widget', $(if ($null -ne $Need) { [string](Get-DomeniaMember $Need 'Label' '') } else { 'Non disponible.' }))
    )) { $rows.Add([pscustomobject]@{ Aspect = [string]$pair[0]; Text = [string]$pair[1] }) }
    return [pscustomobject]@{ Title = $(if ($Title) { $Title } else { $key }); Board = $Board; Key = $key; TargetCount = $TargetCount; Rows = $rows.ToArray() }
}
