# Workstation rules: bounded quick diagnosis, readable sessions, software inventory without MSI side effects,
# targeted event presets, linked versus applied group policies, join and SSO state, update and management
# agent information, machine identity coherence, explicit Wake-on-LAN and the suite hand-off contract.
# Pure decisions: no CIM call, no socket, no registry, no file and no clock read happen here.
# "Now" is always a parameter; the caller reads, this module decides what the reading proves.
# Relies on Domenia-Common.Model.ps1 (facts, dates, GUID, SID) and Domenia-Relations.Model.ps1 (account identity).

# ---------------------------------------------------------------- shared helpers
function ConvertTo-DomeniaWorkstationFactState {
    # Maps a provider read status (worker status, inventory status or error category of Get-DomeniaErrorDecision)
    # to a fact state. A refusal or a failure never becomes an observation.
    param([AllowEmptyString()][AllowNull()][string]$Status)
    $text = ([string]$Status).Trim()
    if ($text -match '^(?i:ok|read|success|succeeded|vide|empty)$') { return 'Constate' }
    if ($text -match '^(?i:accessdenied|denied|refused|refuse|authrejected|unauthorized|credentialsrejected|accountstate|decryptiondenied|decryptdenied)$') { return 'Refuse' }
    if ($text -match '^(?i:timeout|unavailable|unreachable|injoignable|indisponible|network|prerequisite|absent|notinstalled|notfound|missing|error|erreur|failed)$') { return 'Indisponible' }
    return 'Inconnu'
}

function Test-DomeniaWorkstationMember {
    # True when the member exists, even when its value is an empty collection (which a function return would unroll).
    param($InputObject,[string]$Name)
    if ($null -eq $InputObject -or [string]::IsNullOrEmpty($Name)) { return $false }
    if ($InputObject -is [Collections.IDictionary]) { return [bool]$InputObject.Contains($Name) }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Test-DomeniaWorkstationListMember {
    # True when the member holds a list the provider really returned: a collection (even empty) or one record.
    # $null is not a list: "Events = Get-WinEvent ... -ErrorAction SilentlyContinue" gives $null both for "no match"
    # and for a silenced refusal, so it never proves an absence. A text is not a list either.
    # The value is read without Get-DomeniaMember, whose return would unroll an empty collection into $null.
    param($InputObject,[string]$Name)
    if ($null -eq $InputObject -or [string]::IsNullOrEmpty($Name)) { return $false }
    $value = $null
    if ($InputObject -is [Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $false }
        $value = $InputObject[$Name]
    } else {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property) { return $false }
        $value = $property.Value
    }
    if ($null -eq $value -or $value -is [string]) { return $false }
    return $true
}

function Test-DomeniaWorkstationPartialStatus {
    # Worker status of a read that ran but stopped before the end (PARTIEL in the existing workers).
    param([AllowEmptyString()][AllowNull()][string]$Status)
    return (([string]$Status).Trim() -match '^(?i:partiel|partial)$')
}

function Test-DomeniaWorkstationNotRequested {
    # Status of a read that was never asked for. Any other unknown status means "read, but not understood".
    param([AllowEmptyString()][AllowNull()][string]$Status)
    $text = ([string]$Status).Trim()
    return ((-not $text) -or ($text -match '^(?i:notrequested)$'))
}

function ConvertTo-DomeniaWorkstationBool {
    # Boolean read of a provider value: $null and unknown texts keep the default, 'False' is false.
    param($Value,[bool]$Default=$false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i:true|1|yes|oui)$') { return $true }
    if ($text -match '^(?i:false|0|no|non)$') { return $false }
    return $Default
}

function Get-DomeniaWorkstationShortName {
    # First DNS label in lower case, without a DOMAIN\ prefix, a trailing dot or the machine account dollar sign.
    param([AllowEmptyString()][AllowNull()][string]$Name)
    $text = ([string]$Name).Trim()
    if ($text.IndexOf('\') -ge 0) { $text = $text.Substring($text.LastIndexOf('\') + 1) }
    $text = $text.TrimEnd('.').TrimEnd('$')
    if (-not $text) { return '' }
    return (($text -split '\.')[0]).ToLowerInvariant()
}

function ConvertTo-DomeniaWorkstationNumber {
    # Culture-independent number read. Returns $null when the value is not a number.
    param($Value)
    if ($null -eq $Value) { return $null }
    $number = 0.0
    if ([double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { return $number }
    return $null
}

function Get-DomeniaWorkstationNumberText {
    # Fixed French formatting, whatever the culture of the session.
    param([double]$Value,[string]$Format='0.0')
    return $Value.ToString($Format,[Globalization.CultureInfo]::GetCultureInfo('fr-FR'))
}

function Get-DomeniaWorkstationDurationText {
    param([TimeSpan]$Span)
    $days = [int][Math]::Floor($Span.TotalDays)
    return ([string]$days + ' j ' + [string]$Span.Hours + ' h')
}

# ---------------------------------------------------------------- UX-17 : un verdict, pas un compte d'echecs
# Le worker du diagnostic (Core, operation epinglee ComputerDiagnostics) rend des lignes
# Check/Status/Method/DurationMs/Detail avec des codes : OK, ERREUR, REFUSE, INJOIGNABLE,
# INDISPONIBLE, IGNORE. La page les additionnait tels quels : sur un poste sain ou WinRM HTTPS est
# ferme et ou les deux transports de repli ne sont pas installes, elle affichait « 3 en echec ».
# Un transport facultatif qui manque n'est pas une panne : Domenia lit par CIM, et PsExec comme le
# planificateur ne servent que si CIM est refuse. Ces lignes passent donc en Information. Le code
# reste dans la ligne et dans le rapport copie au presse-papiers : le libelle est ce que l operateur
# lit, le code reste ce qu il transmet a un collegue qui rouvrira le journal.
function Get-DomeniaDiagStatusLabel {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Status = '')
    $code = ([string]$Status).Trim().ToUpperInvariant()
    $labels = @{
        'OK' = 'Réussi'
        'ERREUR' = 'Erreur'
        'REFUSE' = 'Refusé'
        'INJOIGNABLE' = 'Injoignable'
        'INDISPONIBLE' = 'Non installé'
        'IGNORE' = 'Non tenté'
        'INFO' = 'Information'
    }
    if ($labels.ContainsKey($code)) { return [string]$labels[$code] }
    # Un code que cette table ne connait pas ressort tel quel : il correspond a une ligne du
    # rapport copie. Un libelle invente pour lui ne se verifierait nulle part.
    return $code
}

function Get-DomeniaDiagSeverity {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Check = '',
          [AllowNull()][AllowEmptyString()][string]$Status = '')
    $code = ([string]$Status).Trim().ToUpperInvariant()
    if ($code -eq 'OK') { return 'Reussi' }
    if ($code -eq 'IGNORE') { return 'Non tente' }
    $name = ([string]$Check).Trim()
    # Noms exacts produits par le worker. Les transports de repli (PsExec, planificateur) n en
    # font pas partie : s ils echouent alors que CIM a deja echoue, le poste est vraiment en panne.
    foreach ($prefix in @('WinRM', 'Transport PsExec', 'Transport Task Scheduler')) {
        if ($name -eq $prefix) { return 'Information' }
        if ($name.StartsWith($prefix + ' ', [StringComparison]::OrdinalIgnoreCase)) { return 'Information' }
    }
    if ($name.StartsWith('TCP 5985', [StringComparison]::OrdinalIgnoreCase) -or
        $name.StartsWith('TCP 5986', [StringComparison]::OrdinalIgnoreCase)) { return 'Information' }
    return 'Echec'
}

function Get-DomeniaNetworkLayerDiagnosis {
    # Point 90: the diagnosis rows read layer by layer - name resolution, ICMP, TCP transport, useful protocol - and
    # the first layer that blocks the connection. ICMP alone never blocks: a filtered ping with an open management
    # port is a reachable workstation. A layer that was not tried stays "Non tente" and proves nothing.
    [CmdletBinding()]
    param([AllowNull()]$Rows = $null)
    $list = @(@($Rows) | Where-Object { $null -ne $_ })
    $stateOf = {
        param($Found)
        if (-not @($Found).Count) { return 'Non tente' }
        $code = ([string]@($Found)[0].Status).Trim().ToUpperInvariant()
        if ($code -eq 'OK') { return 'Reussi' }
        if ($code -in @('IGNORE','INDISPONIBLE','')) { return 'Non tente' }
        return 'Echec'
    }
    $dns = @($list | Where-Object { [string]$_.Check -eq 'Resolution DNS' } | Select-Object -First 1)
    $ping = @($list | Where-Object { [string]$_.Check -eq 'Ping' } | Select-Object -First 1)
    $tcp = @($list | Where-Object { ([string]$_.Check).StartsWith('TCP ',[StringComparison]::OrdinalIgnoreCase) })
    $open = @($tcp | Where-Object { ([string]$_.Status).Trim().ToUpperInvariant() -eq 'OK' } | ForEach-Object { (([string]$_.Check) -split ' ')[1] })
    $cim = @($list | Where-Object { [string]$_.Check -eq 'Session CIM' } | Select-Object -First 1)
    $share = @($list | Where-Object { [string]$_.Check -eq 'Partage C$' } | Select-Object -First 1)
    $dnsState = & $stateOf $dns
    $pingState = & $stateOf $ping
    $tcpState = if (-not $tcp.Count) { 'Non tente' } elseif ($open.Count) { 'Reussi' } else { 'Echec' }
    $cimState = & $stateOf $cim
    $shareState = & $stateOf $share
    $protocolState = if ($cimState -eq 'Reussi') { 'Reussi' } elseif ($cimState -eq 'Echec') { 'Echec' } elseif ($shareState -eq 'Reussi') { 'Partiel' } elseif ($shareState -eq 'Echec') { 'Echec' } else { 'Non tente' }
    $detailOf = { param($Found) if (@($Found).Count) { return (ConvertTo-DomeniaFlatText ([string]@($Found)[0].Detail) 120) }; return '' }
    $layers = @(
        [pscustomobject]@{ Step = 1; Label = 'Résolution du nom'; State = $dnsState; Detail = (& $detailOf $dns) }
        [pscustomobject]@{ Step = 2; Label = 'Réponse ICMP (ping)'; State = $pingState; Detail = (& $detailOf $ping) }
        [pscustomobject]@{ Step = 3; Label = 'Transport TCP'; State = $tcpState; Detail = $(if ($open.Count) { 'ports ouverts : ' + ($open -join ', ') } elseif ($tcp.Count) { 'aucun port de gestion ne répond' } else { '' }) }
        [pscustomobject]@{ Step = 4; Label = 'Protocole utile (CIM, C$)'; State = $protocolState; Detail = $(if ($cim.Count) { & $detailOf $cim } else { & $detailOf $share }) }
    )
    $reachable = ($tcpState -eq 'Reussi') -or ($protocolState -in @('Reussi','Partiel'))
    $blocking = 0; $sentence = ''
    if ($dnsState -eq 'Echec') { $blocking = 1; $sentence = 'La connexion échoue à la résolution du nom : aucune adresse nʼest connue pour ce poste.' }
    elseif ($tcpState -eq 'Echec') {
        $blocking = 3
        $sentence = 'La connexion échoue au transport : aucun port de gestion ne répond' + $(if ($pingState -eq 'Reussi') { ' alors que le poste répond au ping (pare-feu probable).' } elseif ($pingState -eq 'Echec') { ' ni au ping (poste éteint, hors réseau ou filtré).' } else { '.' })
    }
    elseif ($protocolState -eq 'Echec') {
        $blocking = 4
        $cimCode = if ($cim.Count) { ([string]$cim[0].Status).Trim().ToUpperInvariant() } else { '' }
        $sentence = if ($cimCode -eq 'REFUSE') { 'La connexion échoue au protocole : la session CIM est refusée au compte utilisé.' } elseif (($cimCode -eq 'INJOIGNABLE') -and ($open -contains '135')) { 'La connexion échoue au protocole : le port 135 répond mais la session CIM nʼaboutit pas (ports RPC dynamiques filtrés ?).' } elseif ($cim.Count) { 'La connexion échoue au protocole : la session CIM nʼaboutit pas.' } else { 'La connexion échoue au protocole : le partage C$ nʼest pas accessible.' }
    }
    elseif (($pingState -eq 'Echec') -and $reachable) { $sentence = 'Pas de réponse au ping, mais le poste est joignable par TCP : ICMP est probablement filtré.' }
    elseif (($dnsState -eq 'Reussi') -and ($tcpState -eq 'Reussi') -and ($protocolState -eq 'Reussi')) { $sentence = 'Toutes les étapes utiles réussissent : nom résolu, ' + $(if ($open.Count) { 'ports ' + ($open -join ', ') + ' ouverts, ' } else { '' }) + 'session CIM ouverte.' }
    elseif (-not $reachable) { $sentence = 'Étape bloquante inconnue : aucun port ni protocole nʼa été testé.' }
    return [pscustomobject]@{ Layers = $layers; BlockingStep = $blocking; Reachable = $reachable; Sentence = $sentence }
}

function ConvertTo-DomeniaDiagVerdict {
    [CmdletBinding()]
    param([AllowNull()]$Rows = $null, [AllowNull()][AllowEmptyString()][string]$Computer = '')
    $list = @()
    if ($null -ne $Rows) { $list = @($Rows) }
    $out = New-Object Collections.ArrayList
    $reussi = 0; $echec = 0; $info = 0; $nonTente = 0
    foreach ($row in $list) {
        if ($null -eq $row) { continue }
        $check = [string]$row.Check
        $status = [string]$row.Status
        $severity = Get-DomeniaDiagSeverity -Check $check -Status $status
        if ($severity -eq 'Reussi') { $reussi += 1 }
        elseif ($severity -eq 'Echec') { $echec += 1 }
        elseif ($severity -eq 'Information') { $info += 1 }
        else { $nonTente += 1 }
        [void]$out.Add([pscustomobject]@{
            Check = $check
            Status = $status
            EtatLibelle = (Get-DomeniaDiagStatusLabel -Status $status)
            Severity = $severity
            Method = [string]$row.Method
            DurationMs = [int]$row.DurationMs
            Detail = [string]$row.Detail
        })
    }
    $rowsOut = @($out.ToArray())
    if ($rowsOut.Count -eq 0) {
        return [pscustomobject]@{ Rows=@(); Layers=@(); BlockingStep=0; Verdict=''; Ok=0; Failed=0; Info=0; Skipped=0
            EmptyText='Aucun contrôle exécuté : lancez « Lancer le diagnostic » pour lire le poste.' }
    }
    $subject = ([string]$Computer).Trim()
    if ([string]::IsNullOrWhiteSpace($subject)) { $subject = 'Le poste' }
    $echecs = @($rowsOut | Where-Object { $_.Severity -eq 'Echec' })
    $points = @()
    # Point 90 : lecture par couche (nom, ICMP, TCP, protocole) et premiere etape qui bloque.
    $couches = Get-DomeniaNetworkLayerDiagnosis -Rows $rowsOut
    # Un poste injoignable ne se resume pas a un nombre : la premiere phrase doit le dire, sinon
    # l operateur lit « 8 controles reussis » sur une machine eteinte. Un ping filtre sur un poste
    # qui repond en TCP n'est pas un poste injoignable.
    $down = @($echecs | Where-Object { ($_.Check -eq 'Resolution DNS') -or (($_.Check -eq 'Ping') -and (-not $couches.Reachable)) })
    if ($down.Count -gt 0) {
        if (@($echecs | Where-Object { $_.Check -eq 'Resolution DNS' }).Count -gt 0) {
            $points += ($subject + ' ne répond pas : son nom ne se résout pas.')
        }
        else {
            $points += ($subject + ' ne répond pas : aucun ping.')
        }
    }
    else {
        $positifs = @()
        if (@($rowsOut | Where-Object { $_.Check -eq 'Partage C$' -and $_.Severity -eq 'Reussi' }).Count -gt 0) {
            $positifs += 'C$ accessible'
        }
        if (@($rowsOut | Where-Object { $_.Check -eq 'Session CIM' -and $_.Severity -eq 'Reussi' }).Count -gt 0) {
            $positifs += 'WMI lu'
        }
        if (@($rowsOut | Where-Object { $_.Check -like 'TCP 3389*' -and $_.Severity -eq 'Reussi' }).Count -gt 0) {
            $positifs += 'Bureau à distance ouvert'
        }
        $head = $subject + ' répond'
        if (@($echecs | Where-Object { $_.Check -eq 'Ping' }).Count -gt 0) { $head += ' sans ping (ICMP filtré)' }
        if ($positifs.Count -gt 0) { $head += ' : ' + ($positifs -join ', ') }
        $points += ($head + '.')
    }
    if ($couches.Sentence) { $points += [string]$couches.Sentence }
    if ($echecs.Count -gt 0) {
        $noms = @($echecs | ForEach-Object { [string]$_.Check } | Select-Object -First 3)
        $phrase = [string]$echecs.Count + ' contrôle(s) en échec : ' + ($noms -join ', ')
        if ($echecs.Count -gt 3) { $phrase += ' (et ' + [string]($echecs.Count - 3) + ' autre(s)).' }
        else { $phrase += '.' }
        $points += $phrase
    }
    $facultatifs = @($rowsOut | Where-Object { $_.Severity -eq 'Information' })
    if ($facultatifs.Count -gt 0) {
        # Deux absences n'ont pas le meme sens : WinRM ferme est le reglage normal d'un parc qui lit par
        # DCOM, alors que les deux transports de repli qui manquent retirent le plan B de Domenia.
        $winrm = @($facultatifs | Where-Object { $_.Check -like 'TCP 5985*' -or $_.Check -like 'TCP 5986*' -or $_.Check -eq 'WinRM' })
        $replis = @($facultatifs | Where-Object { $_.Check -notlike 'TCP 5985*' -and $_.Check -notlike 'TCP 5986*' -and $_.Check -ne 'WinRM' })
        if ($winrm.Count -gt 0) { $points += 'WinRM fermé : normal tant que le parc nʼutilise pas WinRM.' }
        if ($replis.Count -gt 0) {
            $noms = @($replis | ForEach-Object { [string]$_.Check } | Select-Object -First 3)
            $points += ('Transports de repli non disponibles : ' + ($noms -join ', ') + '.')
        }
    }
    return [pscustomobject]@{
        Rows = $rowsOut
        Layers = $couches.Layers
        BlockingStep = $couches.BlockingStep
        Verdict = ($points -join ' ')
        Ok = $reussi
        Failed = $echec
        Info = $info
        Skipped = $nonTente
        EmptyText = ''
    }
}

# ---------------------------------------------------------------- PF-22 : la liste deja lue sert une fois
# L'inventaire rapide remplit deja la categorie « Logiciels installes » (une requete SCCM, un aller-retour
# WinRM, ou jusqu'a 250 cles du registre Uninstall). L'onglet Logiciels repartait de zero avec sa propre
# requete pour afficher les memes noms. Cette vue transforme les lignes de l'inventaire en lignes de la
# grille Logiciels. Elle ne rend que ce que l'inventaire a vraiment lu : nom, version, portee machine.
# L'éditeur, la date, la taille et la commande de desinstallation ne sortent pas de la, donc ils ne sont
# pas inventes : la page les replie et le texte de provenance le dit.
function ConvertTo-DomeniaSoftwareFromInventory {
    [CmdletBinding()]
    param([AllowNull()]$Items = $null, [AllowNull()]$CompletedAt = $null)
    $list = @()
    if ($null -ne $Items) { $list = @($Items) }
    $rows = New-Object Collections.ArrayList
    foreach ($item in $list) {
        if ($null -eq $item) { continue }
        if (([string]$item.Category) -ne 'Logiciels installes') { continue }
        $name = ([string]$item.Item).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        # Le collecteur publie egalement une ligne « Nombre detecte » : ce n'est pas un logiciel.
        if ($name -eq 'Nombre detecte') { continue }
        [void]$rows.Add([pscustomobject]@{
            Name = $name
            Version = [string]$item.Value
            Publisher = ''
            InstallDate = ''
            InstallDateShort = ''
            Size = ''
            SizeKb = 0
            Scope = 'Machine'
            Architecture = ''
            Kind = ''
            Location = ''
            UninstallString = ''
            Source = ('Inventaire — ' + [string]$item.Source)
        })
    }
    $rowsOut = @($rows.ToArray())
    $heure = ''
    if ($null -ne $CompletedAt) { try { $heure = ([datetime]$CompletedAt).ToString('HH:mm') } catch { } }
    $de = ''
    if ($heure -ne '') { $de = ' de ' + $heure }
    return [pscustomobject]@{
        Rows = $rowsOut
        Count = $rowsOut.Count
        ProvenanceText = ('Liste reprise de lʼinventaire' + $de + ' : nom et version, portée machine seulement. « Charger les logiciels » relit le poste en complet (éditeur, date, taille, désinstallation).')
        DashboardText = 'Synthèse non calculée : la liste vient de lʼinventaire rapide, qui ne lit ni lʼéditeur, ni la date, ni la taille. Chargez les logiciels pour obtenir la synthèse.'
    }
}

function Get-DomeniaSoftwareColumnVisibility {
    # Une seule table dit ce que la grille Logiciels montre, pour que le bouton « Colonnes » et la
    # provenance de la liste ne se contredisent jamais. Les colonnes techniques (emplacement, commande de
    # desinstallation, source) restent derriere « Colonnes » : elles debordent de l'ecran et ne servent
    # qu'a copier une commande. Une colonne que la lecture n'a pas renseignee ne s'affiche pas vide : une
    # case « Desinstallation » vide se lirait « ce logiciel ne se desinstalle pas », alors que la reponse
    # n'a simplement pas ete cherchee. Un entete inconnu reste visible : rien n'est replie par devinette.
    [CmdletBinding()]
    param([string[]]$Headers = @(), [bool]$FromInventory = $false, [bool]$ShowTechnical = $false)
    $techniques = @('Emplacement','Desinstallation','Source')
    $nonLues = @('Editeur','Installe le','Taille','Archi','Type')
    $visibilites = @{}
    foreach ($entete in @($Headers)) {
        $nom = [string]$entete
        $visible = $true
        if ($FromInventory -and ($nonLues -contains $nom)) { $visible = $false }
        if ((-not $ShowTechnical) -and ($techniques -contains $nom)) { $visible = $false }
        $visibilites[$nom] = $visible
    }
    return $visibilites
}

function Get-DomeniaSoftwareAccessSummary {
    # Le detail par portee tient en une ligne : ce qui a ete lu, portee par portee. Une portee que le
    # worker n'a pas rapportee n'est pas mentionnee, et un etat inconnu est rendu tel quel au lieu d'être
    # traduit — inventer « lu » pour un etat que le produit ne connait pas serait un faux rapport.
    [CmdletBinding()]
    param([object[]]$Rows = @())
    $mots = @{ OK='lu'; VIDE=('lu, rien trouv' + [char]0x00E9 + 'e'); PARTIEL='lu en partie';
               REFUSE=('refus' + [char]0x00E9); INJOIGNABLE='injoignable';
               INDISPONIBLE='indisponible'; ERREUR=('en ' + [char]0x00E9 + 'chec') }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $portee = ([string](Get-DomeniaMember $row 'Category' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($portee)) { continue }
        $etat = ([string](Get-DomeniaMember $row 'Status' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($etat)) { $etat = 'sans ' + [char]0x00E9 + 'tat' }
        $mot = $etat
        if ($mots.ContainsKey($etat)) { $mot = [string]$mots[$etat] }
        $combien = 0
        try { $combien = [int](Get-DomeniaMember $row 'Items' 0) } catch { $combien = 0 }
        if ($combien -gt 0) { $parts.Add($portee + ' : ' + $mot + ' (' + $combien + ')') }
        else { $parts.Add($portee + ' : ' + $mot) }
    }
    if ($parts.Count -eq 0) { return 'Aucune port' + [char]0x00E9 + 'e lue.' }
    return ($parts -join (' ' + [char]0x00B7 + ' '))
}

# ---------------------------------------------------------------- D071 quick diagnosis with an announced cost
# --- UX-37 : la colonne Valeur de l inventaire du poste rend un libelle, pas le code CIM ---
# Le collecteur recopie ce que CIM lui rend : role « 1 », chassis « 10 », langue « 1036 », carte
# « 2, 1000 Mb/s », BitLocker « 6 », SMART « Pred Fail ». Ces codes se relisent dans une console WMI, pas
# dans une grille d appui. Table fermee, comme celle des sondes (Get-DomeniaProbeValues) : une valeur
# qu elle ne connait pas ressort telle quelle. Un libelle invente ne se verifie nulle part, un code si.
# La valeur brute n est donc pas perdue : l infobulle de la grille la montre, le presse-papiers et
# l export la gardent.
$script:DomeniaInventoryRoleText = @{
    '1' = 'Poste membre du domaine'
    '2' = 'Contrôleur de domaine principal'
    '3' = 'Contrôleur de domaine de sauvegarde'
    '4' = 'Membre dʼun groupe de travail'
    '5' = 'Contrôleur de domaine principal de confiance'
    '6' = 'Contrôleur de domaine de sauvegarde de confiance'
}
# ChassisTypes (Win32_SystemEnclosure) : la liste SMBIOS est longue et les constructeurs n'en rendent
# qu'une poignee. 9 et 10 sont ce que rendent les portables du parc ; le nom SMBIOS de 10 ne dirait rien
# a un operateur, les deux portent le meme libelle.
$script:DomeniaInventoryChassisText = @{
    '1' = 'Autre'
    '2' = 'Inconnu'
    '3' = 'Bureau'
    '4' = 'Bureau (profil bas)'
    '5' = 'Bureau (format pizza)'
    '6' = 'Tour'
    '7' = 'Portable'
    '8' = 'Portable'
    '9' = 'Portable'
    '10' = 'Portable'
    '11' = 'Station dʼaccueil'
    '12' = 'Bureau (tout-en-un)'
    '13' = 'Portable (compact)'
    '14' = 'Bureau (gain de place)'
    '16' = 'Châssis principal'
    '17' = 'Châssis dʼextension'
    '18' = 'Sous-châssis'
    '23' = 'Baie (rack)'
    '26' = 'Portable'
    '28' = 'Station dʼaccueil'
    '32' = 'Mini PC'
    '34' = 'Mini PC'
    '37' = 'Serveur (densite faible)'
    '38' = 'Serveur (densite moyenne)'
    '39' = 'Serveur (densite elevee)'
    '41' = 'Lame'
}
# OSLanguage est un LANGID : « 0409 » et « 409 » sont deux ecritures de la meme cle.
$script:DomeniaInventoryLanguageText = @{
    '1031' = 'Allemand'
    '1033' = 'Anglais (États-Unis)'
    '1036' = 'Français'
    '1040' = 'Italien'
    '1043' = 'Néerlandais'
    '1044' = 'Norvégien'
    '1046' = 'Portugais (Brésil)'
    '1049' = 'Russe'
    '1053' = 'Suédois'
    '1055' = 'Turc'
    '1058' = 'Ukrainien'
    '2057' = 'Anglais (Royaume-Uni)'
    '2060' = 'Français (Belgique)'
    '2070' = 'Portugais'
    '3082' = 'Espagnol'
    '4105' = 'Anglais (Canada)'
}
# NetConnectionStatus (Win32_NetworkAdapter) : 2 = connectee, d'ou « Connectee, 1 Gb/s ».
$script:DomeniaInventoryNetStatusText = @{
    '0' = 'Déconnectée'
    '1' = 'Connexion en cours'
    '2' = 'Connectée'
    '3' = 'Déconnexion en cours'
    '4' = 'Matériel absent'
    '5' = 'Matériel désactivé'
    '6' = 'Panne matérielle'
    '7' = 'Composant non installé'
    '8' = 'Inconnu'
}
# EncryptionMethod (Win32_EncryptableVolume).
$script:DomeniaInventoryBitLockerMethodText = @{
    '0' = 'Inconnue'
    '1' = 'AES 128 bits avec diffuseur'
    '2' = 'AES 256 bits avec diffuseur'
    '3' = 'AES 128 bits'
    '4' = 'AES 256 bits'
    '5' = 'XTS-AES 128 bits'
    '6' = 'XTS-AES 256 bits'
}
# Status des disques physiques : CIM rend de l'anglais. Clefs en majuscules, la lookup normalise.
$script:DomeniaInventorySmartText = @{
    'OK' = 'Sain'
    'PRED FAIL' = 'Panne annoncée'
    'PREDICTIVE FAILURE' = 'Panne annoncée'
    'UNKNOWN' = 'Inconnu'
    'N/A' = 'Non applicable'
    'BAD' = 'Hors service'
    'SERVICE' = 'En maintenance'
    'DEGRADED' = 'Dégradé'
    'OFFLINE' = 'Hors ligne'
    'STARTING' = 'Démarrage'
    'STOPPING' = 'Arrêt'
}

function Get-DomeniaInventoryMapText {
    # Cle numerique normalisee : « 0409 » et « 409 » sont la meme langue. Une cle hors table rend le brut.
    param($Table, [string]$Key, [string]$Fallback)
    $cle = ([string]$Key).Trim()
    if ($cle -match '^\d+$') { $cle = $cle.TrimStart('0'); if ($cle -eq '') { $cle = '0' } }
    if ($null -ne $Table -and $Table.ContainsKey($cle)) { return [string]$Table[$cle] }
    return $Fallback
}

function Get-DomeniaInventoryValueText {
    <#
        UX-37 : le libelle que l operateur doit lire dans la colonne Valeur de l inventaire du poste, a
        partir de la valeur brute rendue par CIM. Une valeur que la table ne connait pas ressort telle
        quelle : rien n est invente. La table est branchee sur le nom de l element, pas sur sa ligne, pour
        que le collecteur reste libre d ajouter une categorie sans toucher ici.
    #>
    param($Category, $Item, $Value)
    $brut = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($brut)) { return '' }
    $nom = ([string]$Item).Trim().ToLowerInvariant()
    $cat = ([string]$Category).Trim().ToLowerInvariant()
    if ($nom -eq 'role dans le domaine') { return Get-DomeniaInventoryMapText -Table $script:DomeniaInventoryRoleText -Key $brut -Fallback $brut }
    if ($nom -eq 'type de chassis') {
        # ChassisTypes est une liste : « 6, 10 » rend deux libelles, pas une chaine recoupee.
        $libelles = @()
        foreach ($morceau in @($brut -split ',')) {
            $code = $morceau.Trim()
            if ($code -eq '') { continue }
            $libelles += Get-DomeniaInventoryMapText -Table $script:DomeniaInventoryChassisText -Key $code -Fallback $code
        }
        if ($libelles.Count -eq 0) { return $brut }
        return ($libelles -join ', ')
    }
    if ($nom -eq 'langue') { return Get-DomeniaInventoryMapText -Table $script:DomeniaInventoryLanguageText -Key $brut -Fallback $brut }
    if ($cat -eq 'bitlocker' -and $nom.EndsWith('methode')) {
        return Get-DomeniaInventoryMapText -Table $script:DomeniaInventoryBitLockerMethodText -Key $brut -Fallback $brut
    }
    if ($cat -eq 'disques physiques' -and $nom.EndsWith('etat smart')) {
        return Get-DomeniaInventoryMapText -Table $script:DomeniaInventorySmartText -Key $brut.ToUpperInvariant() -Fallback $brut
    }
    if ($cat -eq 'cartes reseau') {
        # Le collecteur colle le statut et la vitesse dans la meme valeur : « 2, 1000 Mb/s ».
        $statut = $brut
        $vitesse = ''
        if ($brut -match '^(?<statut>.*?)[,;]\s*(?<vitesse>[\d.,]+)\s*(?<unite>Mb|Gb)/s$') {
            $statut = [string]$matches['statut']
            $nombre = 0.0
            $chiffres = ([string]$matches['vitesse']) -replace ',', '.'
            if ([double]::TryParse($chiffres, [ref]$nombre) -and $nombre -gt 0) {
                if ($matches['unite'] -eq 'Mb' -and $nombre -ge 1000) { $nombre = $nombre / 1000.0; $unite = 'Gb' } else { $unite = $matches['unite'] }
                $vitesse = (('{0:0.#}' -f $nombre) -replace '\.', ',') + ' ' + $unite + '/s'
            }
            else { $vitesse = [string]$matches['vitesse'] + ' ' + $matches['unite'] + '/s' }
        }
        $libelle = Get-DomeniaInventoryMapText -Table $script:DomeniaInventoryNetStatusText -Key $statut -Fallback $statut.Trim()
        if ($vitesse -eq '') { return $libelle }
        return $libelle + ', ' + $vitesse
    }
    return $brut
}

function Get-DomeniaQuickDiagPlan {
    # Five bounded read-only checks. The worker follows this plan; nothing is read here.
    # No intrusive fallback: a refused or unreachable check stays refused or unreachable.
    $checks = @(
        [pscustomobject]@{Id='System';Label='Système';Source='CIM Win32_OperatingSystem (Caption, Version)';TimeoutSeconds=4;Ports=@();Services=@()}
        [pscustomobject]@{Id='LastBoot';Label='Dernier démarrage';Source='CIM Win32_OperatingSystem (LastBootUpTime)';TimeoutSeconds=2;Ports=@();Services=@()}
        [pscustomobject]@{Id='DiskC';Label='Disque C:';Source='CIM Win32_LogicalDisk (C:)';TimeoutSeconds=4;Ports=@();Services=@()}
        [pscustomobject]@{Id='Ports';Label='Ports 135/445/5985';Source='Ouverture de connexion TCP, sans envoi de données';TimeoutSeconds=6;Ports=@(135,445,5985);Services=@()}
        [pscustomobject]@{Id='Services';Label='Services de gestion';Source='CIM Win32_Service (lecture seule)';TimeoutSeconds=4;Ports=@();Services=@('Winmgmt','RpcSs','WinRM','LanmanServer','WAPTService')}
    )
    $budget = 0
    foreach ($check in $checks) { $budget += [int]$check.TimeoutSeconds }
    return [pscustomobject]@{
        OperationId='ComputerQuickDiag';Checks=$checks;CheckCount=@($checks).Count;BudgetSeconds=$budget
        CostText=([string]@($checks).Count + ' contrôles, ' + [string]$budget + ' s au plus')
        Trigger='ExplicitRun';Intrusive=$false
        Fallback='Aucun repli : ni PsExec, ni tâche planifiée, ni modification du poste.'
    }
}

function Test-DomeniaQuickDiagAllowed {
    # Opening a list, selecting a line, switching tab or refreshing never starts the diagnosis:
    # only the explicit button of one workstation does.
    param([AllowEmptyString()][string]$Trigger='',[int]$TargetCount=1)
    if ($Trigger -cne 'ExplicitRun') { return [pscustomobject]@{Allowed=$false;Reason='Le diagnostic rapide démarre uniquement par le bouton Lire de ce poste.'} }
    if ($TargetCount -ne 1) { return [pscustomobject]@{Allowed=$false;Reason='Un seul poste par diagnostic rapide : aucun contrôle collectif.'} }
    return [pscustomobject]@{Allowed=$true;Reason=''}
}

function ConvertTo-DomeniaQuickDiagFacts {
    # $Raw: {Computer, ElapsedMs, Checks={
    #   System={Status,Caption,Version}; LastBoot={Status,LastBootUtc}; DiskC={Status,FreeBytes,SizeBytes};
    #   Ports={Status,Results=@({Port,State='Open'|'Closed'|'Timeout'})}; Services={Status,Results=@({Name,State,StartMode,Present})}}}.
    # Status per check: OK, AccessDenied, Timeout, Unavailable, Skipped. A check absent from $Raw was not run.
    # Only the planned checks become facts: extra raw entries are ignored.
    param($Raw,[Parameter(Mandatory=$true)][datetime]$NowUtc,$Plan=$null,[AllowEmptyString()][string]$Reader='')
    if ($null -eq $Plan) { $Plan = Get-DomeniaQuickDiagPlan }
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    $checksRaw = Get-DomeniaMember $Raw 'Checks' $null
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $counts = @{Constate=0;Estime=0;Refuse=0;Indisponible=0;Inconnu=0}
    foreach ($check in @($Plan.Checks)) {
        $entry = Get-DomeniaMember $checksRaw ([string]$check.Id) $null
        $state = 'Inconnu'; $value = 'Non exécuté'; $hypothesis = ''; $detail = ''
        $limit = 'Contrôle non tenté (budget épuisé ou diagnostic interrompu) : aucune conclusion.'
        if ($null -ne $entry) {
            $state = ConvertTo-DomeniaWorkstationFactState ([string](Get-DomeniaMember $entry 'Status' ''))
            $detail = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $entry 'Detail' '')) 160
            if ($state -eq 'Refuse') { $value = 'Lecture refusée'; $limit = 'Un refus ne dit rien de lʼétat du poste.' }
            elseif ($state -eq 'Indisponible') { $value = 'Lecture impossible'; $limit = 'Aucune conclusion sur ce contrôle.' }
            elseif ($state -eq 'Inconnu') { $value = 'Non tenté'; $limit = 'Contrôle non tenté : aucune conclusion.' }
            elseif ($check.Id -eq 'System') {
                $value = (([string](Get-DomeniaMember $entry 'Caption' '')) + ' ' + ([string](Get-DomeniaMember $entry 'Version' ''))).Trim()
                $limit = 'Lu au moment du diagnostic.'
                if (-not $value) { $state = 'Inconnu'; $value = 'Valeurs absentes de la réponse' }
            }
            elseif ($check.Id -eq 'LastBoot') {
                $boot = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $entry 'LastBootUtc' $null)
                $limit = 'Heure déclarée par le poste.'
                if ($null -eq $boot) { $state = 'Inconnu'; $value = 'Date absente de la réponse' }
                elseif ($boot -gt $now) { $state = 'Estime'; $value = $boot.ToLocalTime().ToString('dd/MM/yyyy HH:mm') + ' (postérieure à la lecture : horloge à vérifier)' }
                else { $value = 'Démarré le ' + $boot.ToLocalTime().ToString('dd/MM/yyyy HH:mm') + ', en service depuis ' + (Get-DomeniaWorkstationDurationText ($now - $boot)) }
            }
            elseif ($check.Id -eq 'DiskC') {
                $free = ConvertTo-DomeniaWorkstationNumber (Get-DomeniaMember $entry 'FreeBytes' $null)
                $size = ConvertTo-DomeniaWorkstationNumber (Get-DomeniaMember $entry 'SizeBytes' $null)
                $limit = 'Volume C: uniquement.'
                if ($null -eq $free -or $null -eq $size -or $size -le 0 -or $free -lt 0 -or $free -gt $size) { $state = 'Inconnu'; $value = 'Taille ou espace libre absent ou incohérent dans la réponse' }
                else {
                    $percent = [Math]::Round(100.0 * $free / $size,0)
                    $value = (Get-DomeniaWorkstationNumberText ($free / 1GB)) + ' Go libres sur ' + (Get-DomeniaWorkstationNumberText ($size / 1GB)) + ' Go (' + (Get-DomeniaWorkstationNumberText $percent '0') + ' %)'
                    if ($percent -lt 10) { $hypothesis = 'Moins de 10 % libres : les mises à jour peuvent échouer.' }
                }
            }
            elseif ($check.Id -eq 'Ports') {
                $results = @(@(Get-DomeniaMember $entry 'Results' @()) | Where-Object { $null -ne $_ })
                $parts = New-Object 'System.Collections.Generic.List[string]'
                $tested = 0
                foreach ($port in @($check.Ports)) {
                    $found = @($results | Where-Object { [string](Get-DomeniaMember $_ 'Port' '') -eq [string]$port })
                    $portState = 'non testé'
                    if ($found.Count -gt 0) {
                        $portRaw = [string](Get-DomeniaMember $found[0] 'State' '')
                        if ($portRaw -match '^(?i:open|ouvert)$') { $portState = 'ouvert'; $tested++ }
                        elseif ($portRaw -match '^(?i:closed|ferme|filtered|timeout|refused)$') { $portState = 'fermé ou filtré'; $tested++ }
                    }
                    $parts.Add(([string]$port + ' ' + $portState))
                }
                $value = $parts.ToArray() -join ', '
                $limit = 'Un port fermé ou filtré ne prouve pas que le poste est éteint.'
                if ($tested -eq 0) { $state = 'Inconnu'; $limit = 'Aucun port testé : aucune conclusion.' }
            }
            elseif ($check.Id -eq 'Services') {
                $results = @(@(Get-DomeniaMember $entry 'Results' @()) | Where-Object { $null -ne $_ })
                $parts = New-Object 'System.Collections.Generic.List[string]'
                $read = 0
                foreach ($name in @($check.Services)) {
                    $found = @($results | Where-Object { [string](Get-DomeniaMember $_ 'Name' '') -ieq [string]$name })
                    $text = $name + ' : non lu'
                    if ($found.Count -gt 0) {
                        $read++
                        if (-not (ConvertTo-DomeniaWorkstationBool (Get-DomeniaMember $found[0] 'Present' $true) $true)) { $text = $name + ' : non installé' }
                        else {
                            $running = [string](Get-DomeniaMember $found[0] 'State' '')
                            if ($running -ieq 'Running') { $running = 'démarré' } elseif ($running -ieq 'Stopped') { $running = 'arrêté' }
                            $mode = [string](Get-DomeniaMember $found[0] 'StartMode' '')
                            if ($mode -ieq 'Auto') { $mode = 'automatique' } elseif ($mode -ieq 'Manual') { $mode = 'manuel' } elseif ($mode -ieq 'Disabled') { $mode = 'désactivé' }
                            $text = $name + ' : ' + $running
                            if ($mode) { $text += ' (' + $mode + ')' }
                        }
                    }
                    $parts.Add($text)
                }
                $value = $parts.ToArray() -join ' ; '
                $limit = 'Lecture de lʼétat uniquement : aucun service nʼest démarré ni modifié.'
                if ($read -eq 0) { $state = 'Inconnu'; $limit = 'Aucun service lu : aucune conclusion.' }
            }
            if ($detail -and ($state -in @('Refuse','Indisponible','Inconnu'))) { $value += ' : ' + $detail }
        }
        $counts[$state] = [int]$counts[$state] + 1
        $facts.Add((New-DomeniaFact -Fait ([string]$check.Label) -Valeur $value -Etat $state -Source ([string]$check.Source) -Limite $limit -Hypothese $hypothesis -Date $now -Lecteur $Reader))
    }
    $elapsed = ConvertTo-DomeniaWorkstationNumber (Get-DomeniaMember $Raw 'ElapsedMs' $null)
    $overrun = $false; $durationText = 'Durée non mesurée.'
    if ($null -ne $elapsed) {
        $overrun = ($elapsed -gt (1000.0 * [int]$Plan.BudgetSeconds))
        $durationText = (Get-DomeniaWorkstationNumberText ($elapsed / 1000.0)) + ' s pour un budget de ' + [string]$Plan.BudgetSeconds + ' s.'
        if ($overrun) { $durationText += ' Budget dépassé : les contrôles en retard doivent être interrompus.' }
    }
    $summary = [string]$counts['Constate'] + ' constaté(s), ' + [string]$counts['Refuse'] + ' refusé(s), ' + [string]$counts['Indisponible'] + ' indisponible(s), ' + [string]([int]$counts['Inconnu'] + [int]$counts['Estime']) + ' non concluant(s) sur ' + [string]$Plan.CheckCount + ' contrôles.'
    return [pscustomobject]@{
        Computer=[string](Get-DomeniaMember $Raw 'Computer' '');Facts=$facts.ToArray();Counts=$counts;Summary=$summary
        Complete=([int]$counts['Constate'] -eq [int]$Plan.CheckCount);Overrun=$overrun;DurationText=$durationText
    }
}

# ---------------------------------------------------------------- D072 sessions: readable, consultation only
function Get-DomeniaSessionEmptyText {
    # What an empty or partial list means. An empty console never proves that no RDP session is open,
    # and a refused read never proves that no session exists.
    param([AllowEmptyString()][string]$ReadStatus='OK',[int]$UserSessionCount=0,[int]$RdpSessionCount=0,[bool]$ConsoleOccupied=$false,[ValidateSet('Wts','ConsoleOnly')][string]$Coverage='Wts',[int]$UnreadSessionCount=0)
    $state = ConvertTo-DomeniaWorkstationFactState $ReadStatus
    if ($state -eq 'Refuse') { return 'Lecture des sessions refusée pour ce compte : aucune conclusion sur les sessions ouvertes.' }
    if ($state -eq 'Indisponible') { return 'Poste injoignable ou lecture WTS impossible : aucune conclusion sur les sessions ouvertes.' }
    # A partial or unrecognized read did run: it is never presented as "not requested", and never as an absence.
    if (Test-DomeniaWorkstationPartialStatus $ReadStatus) { return 'Lecture WTS partielle : liste incomplète, aucune conclusion sur les sessions non listées. Une console vide ne signifie pas absence de session RDP.' }
    if ($state -ne 'Constate') {
        if (Test-DomeniaWorkstationNotRequested $ReadStatus) { return 'Sessions non lues. La lecture WTS se lance par le bouton Lire.' }
        if (([string]$ReadStatus).Trim() -match '^(?i:incomplete)$') { return 'Réponse WTS sans liste de sessions : aucune conclusion sur les sessions ouvertes.' }
        return ('Lecture WTS au statut non reconnu (' + (ConvertTo-DomeniaFlatText ([string]$ReadStatus) 40) + ') : aucune conclusion sur les sessions ouvertes.')
    }
    if ($Coverage -eq 'ConsoleOnly') {
        if (-not $ConsoleOccupied) { return 'Console vide : cela ne signifie pas absence de session RDP. Seule la console a été lue ; lisez les sessions du poste.' }
        return 'Console occupée. Les sessions RDP ne sont pas couvertes par cette lecture.'
    }
    if ($UnreadSessionCount -gt 0) { return ('Lecture WTS partielle : ' + [string]$UnreadSessionCount + ' session(s) dont le compte nʼa pas pu être lu. Aucune conclusion sur ces sessions.') }
    if ($UserSessionCount -le 0) { return 'Aucune session utilisateur ouverte lors de la lecture WTS.' }
    if (-not $ConsoleOccupied -and $RdpSessionCount -gt 0) { return ('Console vide : cela ne signifie pas absence de session RDP. ' + [string]$RdpSessionCount + ' session(s) RDP ouverte(s).') }
    return ''
}

function Get-DomeniaSessionIdleText {
    # UX-39 : WTSIdleTime est une duree, pas une date : sous une colonne « Inactive depuis », « 12 min » se
    # lit mieux qu'une heure de dernière entrée. -1 ou 0 = le poste ne rend pas cette horloge : la cellule
    # reste vide, rien n'est invente.
    param($Ticks)
    $raw = ConvertTo-DomeniaWorkstationNumber $Ticks
    if ($null -eq $raw -or $raw -le 0) { return '' }
    $seconds = [long][Math]::Floor($raw / 10000000.0)
    if ($seconds -lt 1) { return '< 1 s' }
    if ($seconds -lt 60) { return [string]$seconds + ' s' }
    if ($seconds -lt 3600) { return [string][long][Math]::Floor($seconds / 60) + ' min' }
    if ($seconds -lt 86400) { return [string][long][Math]::Floor($seconds / 3600) + ' h' }
    return [string][long][Math]::Floor($seconds / 86400) + ' j'
}
function Get-DomeniaSessionOpenedText {
    # UX-39 : « Ouverte à » en heure locale de la machine qui affiche, pas en UTC : l'operateur rappelle un
    # poste et doit retrouver l'heure qu'on lui donne au telephone. La journee de comparaison est l'instant de
    # la lecture ($Reference), jamais l'heure du banc : deux lectures du meme poste rendent la meme ligne.
    # Une horloge non rendue (ou 0, qui veut dire « jamais » pour WTS) rend une cellule vide.
    param($Ticks,$Reference)
    $instant = ConvertTo-DomeniaUtcDate $Ticks
    if ($null -eq $instant) { return '' }
    $local = $instant.ToLocalTime()
    $day = if ($null -ne $Reference) { $Reference.ToLocalTime().Date } else { [datetime]::Now.Date }
    if ($local.Date -eq $day) { return $local.ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture) }
    return $local.ToString('dd/MM HH:mm',[Globalization.CultureInfo]::InvariantCulture)
}
function Get-DomeniaSessionAccountName {
    # UX-39 : « Ouvrir la fiche » cherche un compte AD par sAMAccountName. La vue rend « DOM\user » pour etre
    # lisible ; le filtre LDAP veut le nom nu, et le domaine rendu par WTS n'y a rien a faire. Une ligne sans
    # compte (service, ecouteur) n'a pas de fiche : elle rend vide, et la page le dit au lieu de lancer une
    # recherche qui echouerait.
    param($Row)
    if ($null -eq $Row) { return '' }
    $account = ([string](Get-DomeniaMember $Row 'Utilisateur' '')).Trim()
    if (-not $account -or $account -eq 'Compte non lu') { return '' }
    if ($account.Contains('\')) { return ($account.Split('\')[-1]).Trim() }
    return $account
}
function ConvertTo-DomeniaSessionView {
    # $Result: output of the SessionsList worker {Rows=@({Id,Station,User,Domain,State,Protocol,Detail}), Computer,
    # ObservedUtc, Source, Identity}, or a failure {ReadStatus='AccessDenied'|'Timeout'|...}, or $null when not read.
    # Rows must be a list (@() when no session): $null or a missing Rows is an incomplete answer, not an empty list.
    # A PARTIEL read shows the rows it got and concludes nothing about the others.
    # Consultation only: the view offers a re-read and nothing else (no disconnect, no logoff, no message).
    param($Result,[AllowEmptyString()][string]$ReadStatus='')
    $status = $ReadStatus
    if (-not $status) {
        if ($null -eq $Result) { $status = 'NotRequested' } else { $status = [string](Get-DomeniaMember $Result 'ReadStatus' 'OK') }
    }
    $partial = Test-DomeniaWorkstationPartialStatus $status
    $state = ConvertTo-DomeniaWorkstationFactState $status
    if ($partial) { $state = 'Constate' }
    # An answer without session list is not an empty list.
    if ($state -eq 'Constate' -and -not (Test-DomeniaWorkstationListMember $Result 'Rows')) { $status = 'Incomplete'; $state = 'Inconnu'; $partial = $false }
    $computer = [string](Get-DomeniaMember $Result 'Computer' '')
    $source = [string](Get-DomeniaMember $Result 'Source' 'WTS')
    if (-not $source) { $source = 'WTS' }
    $observed = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Result 'ObservedUtc' $null)
    $sourceText = $source
    if ($null -ne $observed) { $sourceText = $source + ', ' + $observed.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $system = 0; $unread = 0; $consoleUser = ''; $rdp = 0; $disconnected = 0
    if ($state -eq 'Constate') {
        foreach ($row in @(Get-DomeniaMember $Result 'Rows' @())) {
            if ($null -eq $row) { continue }
            $user = ([string](Get-DomeniaMember $row 'User' '')).Trim()
            $detail = [string](Get-DomeniaMember $row 'Detail' '')
            $protocol = [string](Get-DomeniaMember $row 'Protocol' 'Indetermine')
            $sessionState = [string](Get-DomeniaMember $row 'State' 'Indetermine')
            $station = [string](Get-DomeniaMember $row 'Station' '')
            $label = [string](Get-DomeniaMember $row 'Id' '')
            if ($station) { $label = $label + ' (' + $station + ')' }
            # Les deux horloges se calculent avant les branches : une ligne sans compte reste une ligne lue.
            $opened = Get-DomeniaSessionOpenedText -Ticks (Get-DomeniaMember $row 'LogonTicks' $null) -Reference $observed
            $idle = Get-DomeniaSessionIdleText -Ticks (Get-DomeniaMember $row 'IdleTicks' $null)
            if (-not $user) {
                # A session whose account could not be read is listed as such: it is not an empty session.
                if ($detail -match '(?i)partiel|partial') {
                    $unread++
                    $rows.Add([pscustomobject]@{Session=$label;Utilisateur='Compte non lu';Etat=$sessionState;Protocole=$protocol;Source=$sourceText;Detail=$detail;User='';Ouverte=$opened;Inactive=$idle})
                    continue
                }
                # Services session 0, logon screen and RDP listeners carry no account: counted, not listed.
                $system++
                continue
            }
            $domain = ([string](Get-DomeniaMember $row 'Domain' '')).Trim()
            $account = $user
            if ($domain) { $account = $domain + '\' + $user }
            if ($protocol -ieq 'Console' -and -not $consoleUser) { $consoleUser = $account }
            if ($protocol -ieq 'RDP') { $rdp++ }
            if ($sessionState -match '^(?i:deconnect|disconnect)') { $disconnected++ }
            $rows.Add([pscustomobject]@{Session=$label;Utilisateur=$account;Etat=$sessionState;Protocole=$protocol;Source=$sourceText;Detail=$detail;User=$user;Ouverte=$opened;Inactive=$idle})
        }
    }
    $userCount = $rows.Count - $unread
    $empty = Get-DomeniaSessionEmptyText -ReadStatus $status -UserSessionCount $userCount -RdpSessionCount $rdp -ConsoleOccupied ([bool]$consoleUser) -Coverage Wts -UnreadSessionCount $unread
    $reader = [string](Get-DomeniaMember $Result 'Identity' '')
    # UX-39 : l'etat de la page se lit avant la grille. Il commence par l'heure locale de la lecture, dit
    # combien de lignes la grille montre et combien elle en masque, et nomme le compte qui a lu. Le texte
    # brut de la source (« WTS, lecture a la demande ») ne remonte plus ici : c'est une constante du
    # collecteur, pas une donnee du poste, et elle reste portee par la colonne Source de chaque ligne.
    $statusParts = @()
    if ($null -ne $observed) { $statusParts += ('Lu à ' + $observed.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)) }
    if ($state -eq 'Constate') {
        # Chaque segment porte un fait et rien d'autre. « 0 session(s) avec compte » se tait quand la page
        # est vide : EmptyText le dit deja, et deux phrases qui repetent la meme absence se lisent comme un doute.
        $segments = @()
        if ($userCount -gt 0) { $segments += ([string]$userCount + ' session(s) avec compte') }
        if ($unread -gt 0) { $segments += ([string]$unread + ' dont le compte nʼa pas pu être lu') }
        if ($system -gt 0) { $segments += ([string]$system + ' ligne(s) sans compte masquée(s) : services, écran de connexion, écouteur RDP') }
        if ($segments.Count -gt 0) { $statusParts += ($segments -join ', ') }
    }
    if ($computer) { $statusParts += $computer }
    if ($reader) { $statusParts += ('lu par ' + $reader) }
    $statusText = ($statusParts -join ' · ')
    if ($statusText) { $statusText += '. ' }
    $statusText += 'Consultation seule : aucune déconnexion depuis cet écran.'
    return [pscustomobject]@{
        Computer=$computer;ReadState=$state;Partial=$partial;Rows=$rows.ToArray();UserSessions=$userCount;UnreadSessions=$unread;SystemSessions=$system
        ConsoleUser=$consoleUser;ConsoleOccupied=([bool]$consoleUser);RdpSessions=$rdp;DisconnectedSessions=$disconnected
        EmptyText=$empty;StatusText=$statusText;Actions=@('Relire');Reader=$reader
    }
}

# ---------------------------------------------------------------- D073 software inventory without MSI side effects
function Get-DomeniaMsiProviderClassNames {
    # Classes of root\cimv2 served by the Windows Installer provider (MSIProv), then the classes whose deep
    # enumeration reaches them (WMI enumerates subclasses by default, so "CIM_Product" also reads the MSI products).
    # Reading any of them goes through the MSI provider, which may check, and possibly repair, every MSI product.
    # Taken from the schema of Windows 11 26100 (CNAMTS-W11-01, schema read only, no instance enumerated).
    # The names are kept as stems so that this list is not itself reported as a use by Test-DomeniaInventoryCodeSafe.
    # The first name is the product class.
    $win32 = @(
        'Product','ProductCheck','ProductResource','ProductSoftwareFeatures',
        'SoftwareFeature','SoftwareFeatureAction','SoftwareFeatureCheck','SoftwareFeatureParent','SoftwareFeatureSoftwareElements',
        'SoftwareElement','SoftwareElementAction','SoftwareElementCheck','SoftwareElementCondition','SoftwareElementResource',
        'InstalledSoftwareElement','Patch','PatchFile','PatchPackage','Property','Binary','ApplicationService','ApplicationCommandLine',
        'CommandLineAccess','ActionCheck','CheckCheck','Condition','LaunchCondition','ReserveCost','ServiceControl',
        'ServiceSpecification','ServiceSpecificationService','ShortcutAction','ShortcutSAP','BindImageAction','ClassInfoAction',
        'CreateFolderAction','DuplicateFileAction','ExtensionInfoAction','FontInfoAction','MIMEInfoAction','MoveFileAction',
        'PublishComponentAction','RegistryAction','RemoveFileAction','RemoveIniAction','SelfRegModuleAction','TypeLibraryAction',
        'DirectorySpecification','EnvironmentSpecification','FileSpecification','IniFileSpecification','ProgIDSpecification',
        'ODBCAttribute','ODBCDataSourceAttribute','ODBCDataSourceSpecification','ODBCDriverAttribute','ODBCDriverSoftwareElement',
        'ODBCDriverSpecification','ODBCSourceAttribute','ODBCTranslatorSpecification',
        'MSIResource','SettingCheck','ManagedSystemElementResource'
    )
    $cim = @(
        'Product','ProductSoftwareFeatures','SoftwareFeature','SoftwareFeatureSoftwareElements','SoftwareElement',
        'SoftwareElementActions','SoftwareElementChecks','InstalledSoftwareElement','Action','Check','Component','Dependency',
        'CopyFileAction','CreateDirectoryAction','DirectoryAction','DirectorySpecification','FileAction','FileSpecification',
        'RemoveFileAction','Service','ServiceAccessBySAP','ServiceAccessPoint','Setting','LogicalElement','ManagedSystemElement'
    )
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($stem in $win32) { $names.Add('Win32_' + $stem) }
    foreach ($stem in $cim) { $names.Add('CIM_' + $stem) }
    return $names.ToArray()
}

function Test-DomeniaMsiProviderClass {
    # True when reading the class goes through the Windows Installer provider. Accepts a class name, a
    # "namespace:class" text or a WMI object path; the comparison ignores case, like WMI.
    param([AllowEmptyString()][AllowNull()][string]$ClassName)
    $text = ([string]$ClassName).Trim()
    if (-not $text) { return $false }
    $text = @($text -split '[:\\]')[-1]
    $text = @($text -split '[.=]')[0].Trim()
    foreach ($name in @(Get-DomeniaMsiProviderClassNames)) { if ($text -ieq $name) { return $true } }
    return $false
}

function Get-DomeniaSoftwareSources {
    # Where the inventory reads, and which categories stay uncovered. No class of the MSI provider is ever a source:
    # enumerating the product class makes Windows Installer check, and possibly repair, every MSI product.
    # A category is covered when at least one included source of that category was read (or is planned, when
    # $Outcomes is not given). The SCCM class used by the existing inventory covers 32-bit programs only.
    # $Outcomes: optional map source Id -> read status once the inventory has run (worker statuses OK, VIDE,
    # PARTIEL, REFUSE, INJOIGNABLE, INDISPONIBLE, ERREUR are understood). See ConvertFrom-DomeniaSoftwareAccess.
    param([string[]]$Included=@('Uninstall64','Uninstall32'),$Outcomes=$null)
    $catalog = @(
        [pscustomobject]@{Id='Uninstall64';Category='Programmes 64 bits (machine)';Location='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';Limit=''}
        [pscustomobject]@{Id='Uninstall32';Category='Programmes 32 bits (machine)';Location='HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall';Limit=''}
        [pscustomobject]@{Id='Sccm';Category='Programmes 32 bits (machine)';Location='CIM Win32Reg_AddRemovePrograms (client SCCM)';Limit='Présente seulement avec le client SCCM ; sur un poste 64 bits, ne décrit que les programmes 32 bits (Win32Reg_AddRemovePrograms64 nʼest pas lue).'}
        [pscustomobject]@{Id='PerUser';Category='Installations par utilisateur';Location='HKU\<SID>\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';Limit='Ruches chargées sous HKU, donc les profils ayant une session ouverte ; lues par StdRegProv sur la session CIM, sans repli en cas dʼéchec.'}
        [pscustomobject]@{Id='Appx';Category='Paquets Appx/MSIX';Location='Get-AppxPackage -AllUsers';Limit='Exige WinRM sur le poste.'}
    )
    $known = @($catalog | ForEach-Object { $_.Id })
    $refused = New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in @($Included)) {
        if ($known -cnotcontains $id) { $refused.Add([pscustomobject]@{Id=[string]$id;Reason='Source non autorisée pour un inventaire.'}) }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $categories = New-Object 'System.Collections.Generic.List[string]'
    $categoryCovered = @{}
    $categoryNotes = @{}
    $categorySources = @{}
    foreach ($source in $catalog) {
        $isIncluded = ($Included -ccontains $source.Id)
        $readState = ''
        $covered = $isIncluded
        if ($isIncluded -and $null -ne $Outcomes) {
            $raw = Get-DomeniaMember $Outcomes $source.Id $null
            if ($null -eq $raw) { $readState = 'Inconnu' }
            elseif (Test-DomeniaWorkstationPartialStatus ([string]$raw)) { $readState = 'Partiel' }
            else { $readState = ConvertTo-DomeniaWorkstationFactState ([string]$raw) }
            $covered = ($readState -eq 'Constate')
        }
        $display = 'Non demandée'
        if ($isIncluded) {
            $display = 'Prévue'
            switch ($readState) { 'Constate' { $display = 'Lue' } 'Partiel' { $display = 'Lecture partielle' } 'Refuse' { $display = 'Lecture refusée' } 'Indisponible' { $display = 'Lecture impossible' } 'Inconnu' { $display = 'Non lue' } }
        }
        $category = [string]$source.Category
        if (-not $categoryCovered.ContainsKey($category)) {
            $categories.Add($category); $categoryCovered[$category] = $false
            $categoryNotes[$category] = New-Object 'System.Collections.Generic.List[string]'
            $categorySources[$category] = New-Object 'System.Collections.Generic.List[string]'
        }
        if ($isIncluded) { $categorySources[$category].Add([string]$source.Id) }
        if ($covered) { $categoryCovered[$category] = $true }
        elseif ($isIncluded -and -not $categoryNotes[$category].Contains($display.ToLowerInvariant())) { $categoryNotes[$category].Add($display.ToLowerInvariant()) }
        $rows.Add([pscustomobject]@{Id=$source.Id;Categorie=$category;Emplacement=$source.Location;Incluse=$isIncluded;Etat=$display;Couverte=$covered;Limite=$source.Limit})
    }
    $uncovered = New-Object 'System.Collections.Generic.List[string]'
    $categoryRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($category in $categories) {
        $categoryRows.Add([pscustomobject]@{Categorie=$category;Couverte=[bool]$categoryCovered[$category];Sources=$categorySources[$category].ToArray()})
        if ($categoryCovered[$category]) { continue }
        $suffix = ''
        if ($categoryNotes[$category].Count -gt 0) { $suffix = ' (' + ($categoryNotes[$category].ToArray() -join ', ') + ')' }
        $uncovered.Add($category + $suffix)
    }
    $coverage = 'Toutes les catégories ont été lues.'
    if ($uncovered.Count -gt 0) { $coverage = 'Non couvert : ' + ($uncovered.ToArray() -join ', ') + '.' }
    $msiClasses = @(Get-DomeniaMsiProviderClassNames)
    return [pscustomobject]@{
        Sources=$rows.ToArray();Categories=$categoryRows.ToArray();Uncovered=$uncovered.ToArray();CoverageText=$coverage;Refused=$refused.ToArray()
        Excluded=@(
            [pscustomobject]@{Id=$msiClasses[0];Reason='Exclu : sa lecture peut déclencher une vérification ou une réparation MSI sur le poste.'}
            [pscustomobject]@{Id='MSIProv';Reason=('Exclu : les ' + [string]$msiClasses.Count + ' classes servies par le fournisseur Windows Installer ou qui y mènent (classes parentes) passent par la même lecture MSI.')}
        )
    }
}

function ConvertFrom-DomeniaSoftwareAccess {
    # Maps the access rows of the existing SoftwareInventory worker ({Category, Status, Method, Detail}, see Add-Access
    # in Domenia-Core.ps1) to the source Ids of Get-DomeniaSoftwareSources:
    #   Machine     -> Uninstall64 and Uninstall32 (WinRM or key-by-key registry), or Sccm when the machine read went
    #                  through Win32Reg_AddRemovePrograms ($MachineSource 'SCCM', or a detail naming SCCM);
    #   Utilisateur -> PerUser;  Store -> Appx;
    #   Joignabilite, Connexion CIM, Repli de transport, Fallback ... -> transport steps, not sources.
    # An unknown category never adds coverage. Two rows for one source keep the least conclusive status.
    param([object[]]$Access=@(),[AllowEmptyString()][string]$MachineSource='')
    $included = New-Object 'System.Collections.Generic.List[string]'
    $outcomes = @{}
    $transport = New-Object 'System.Collections.Generic.List[string]'
    $unmapped = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in @($Access)) {
        if ($null -eq $row) { continue }
        $category = ([string](Get-DomeniaMember $row 'Category' '')).Trim()
        $status = ([string](Get-DomeniaMember $row 'Status' '')).Trim()
        $ids = @()
        if ($category -ieq 'Machine') {
            $viaSccm = ($MachineSource -ieq 'SCCM')
            if ((-not $MachineSource) -and (([string](Get-DomeniaMember $row 'Detail' '')) -match '(?i)\bSCCM\b')) { $viaSccm = $true }
            if ($viaSccm) { $ids = @('Sccm') } else { $ids = @('Uninstall64','Uninstall32') }
        }
        elseif ($category -ieq 'Utilisateur') { $ids = @('PerUser') }
        elseif ($category -ieq 'Store') { $ids = @('Appx') }
        elseif ($category -match '^(?i:joignabilite|joignabilité|connexion cim|repli de transport|fallback)') { $transport.Add($category); continue }
        else { $unmapped.Add($category); continue }
        foreach ($id in $ids) {
            if ($included -cnotcontains $id) { $included.Add($id) }
            $rank = 2
            if (Test-DomeniaWorkstationPartialStatus $status) { $rank = 1 }
            elseif ((ConvertTo-DomeniaWorkstationFactState $status) -eq 'Constate') { $rank = 0 }
            $previous = 0
            if ($outcomes.ContainsKey($id)) {
                $old = [string]$outcomes[$id]
                $previous = 2
                if (Test-DomeniaWorkstationPartialStatus $old) { $previous = 1 }
                elseif ((ConvertTo-DomeniaWorkstationFactState $old) -eq 'Constate') { $previous = 0 }
                if ($rank -lt $previous) { continue }
            }
            $outcomes[$id] = $status
        }
    }
    return [pscustomobject]@{Included=$included.ToArray();Outcomes=$outcomes;Transport=$transport.ToArray();Unmapped=$unmapped.ToArray()}
}

function Test-DomeniaInventoryGuardNode {
    # True when the comparison only decides a condition: the condition of if/elseif, while, do or for, possibly
    # through parentheses, -not and -and/-or. A comparison whose value is used (argument, index, assignment,
    # array element) is not a guard: "(@('X') -ne '')[0]" yields the class name itself.
    param($Comparison)
    $child = $Comparison
    $up = $Comparison.Parent
    while ($null -ne $up) {
        if (($up -is [Management.Automation.Language.ParenExpressionAst]) -or ($up -is [Management.Automation.Language.CommandExpressionAst])) { $child = $up; $up = $up.Parent; continue }
        if (($up -is [Management.Automation.Language.UnaryExpressionAst]) -and (([string]$up.TokenKind) -match '^(Not|Exclaim)$')) { $child = $up; $up = $up.Parent; continue }
        if (($up -is [Management.Automation.Language.BinaryExpressionAst]) -and (([string]$up.Operator) -match '^(And|Or|Xor)$')) { $child = $up; $up = $up.Parent; continue }
        if ($up -is [Management.Automation.Language.PipelineAst]) {
            if (@($up.PipelineElements).Count -ne 1) { return $false }
            $child = $up; $up = $up.Parent; continue
        }
        break
    }
    if ($up -is [Management.Automation.Language.IfStatementAst]) {
        foreach ($clause in @($up.Clauses)) { if ([object]::ReferenceEquals($clause.Item1,$child)) { return $true } }
        return $false
    }
    if (($up -is [Management.Automation.Language.WhileStatementAst]) -or ($up -is [Management.Automation.Language.DoWhileStatementAst]) -or ($up -is [Management.Automation.Language.DoUntilStatementAst]) -or ($up -is [Management.Automation.Language.ForStatementAst])) {
        return [object]::ReferenceEquals($up.Condition,$child)
    }
    return $false
}

function Get-DomeniaInventoryCodeFindings {
    # Findings for one source text. A here-string or a multi-line string (worker code) is inspected as code as
    # well: that is where the remote inventory code lives.
    param([AllowEmptyString()][AllowNull()][string]$SourceText,[int]$Depth=0)
    $findings = New-Object 'System.Collections.Generic.List[string]'
    $canonical = @{}
    $escaped = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @(Get-DomeniaMsiProviderClassNames | Sort-Object -Property Length -Descending)) { $canonical[$name] = $name; $escaped.Add([regex]::Escape($name)) }
    $classes = '(?<class>' + ($escaped.ToArray() -join '|') + ')'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([string]$SourceText,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        if ($Depth -eq 0) { $findings.Add('Code illisible : analyse impossible, inventaire refusé.') }
        else {
            # An embedded text that is not PowerShell (XAML, C#) is only searched for the class names.
            $found = [regex]::Match([string]$SourceText,'(?i)\b' + $classes + '\b')
            if ($found.Success) { $findings.Add([string]$canonical[$found.Groups['class'].Value] + ' cité dans un texte embarqué non analysable') }
        }
        return $findings.ToArray()
    }
    $passThrough = @('ArrayLiteralAst','ArrayExpressionAst','StatementBlockAst','PipelineAst','CommandExpressionAst','ParenExpressionAst')
    $strings = @($ast.FindAll({ param($node) ($node -is [Management.Automation.Language.StringConstantExpressionAst]) -or ($node -is [Management.Automation.Language.ExpandableStringExpressionAst]) }, $true))
    foreach ($node in $strings) {
        $value = [string]$node.Value
        $embedded = (([string]$node.StringConstantType) -match 'HereString$') -or ($value.IndexOf([char]10) -ge 0)
        if ($Depth -lt 3 -and $embedded) {
            foreach ($inner in @(Get-DomeniaInventoryCodeFindings $value ($Depth + 1))) { $findings.Add($inner) }
            continue
        }
        $wql = [regex]::Match($value,'(?i)\b(from|isa)\s+[''"]?' + $classes + '\b')
        if (-not $wql.Success) { $wql = [regex]::Match($value,'(?i)\bof\s*\{\s*' + $classes + '\b') }
        if ($wql.Success) { $findings.Add('Requête WQL sur ' + [string]$canonical[$wql.Groups['class'].Value]); continue }
        $path = [regex]::Match($value,'(?i)[:\\]' + $classes + '\b')
        if ($path.Success) { $findings.Add('Chemin WMI vers ' + [string]$canonical[$path.Groups['class'].Value]); continue }
        $whole = [regex]::Match($value,'^(?i)\s*' + $classes + '\s*$')
        if (-not $whole.Success) { continue }
        $cursor = $node.Parent
        while ($null -ne $cursor -and $passThrough -contains $cursor.GetType().Name) { $cursor = $cursor.Parent }
        $isGuard = (($cursor -is [Management.Automation.Language.BinaryExpressionAst]) -and (([string]$cursor.Operator) -match '^(?i)[IC](eq|ne|like|notlike|match|notmatch|in|notin|contains|notcontains)$') -and (Test-DomeniaInventoryGuardNode $cursor))
        if (-not $isGuard) { $findings.Add('Classe ' + [string]$canonical[$whole.Groups['class'].Value] + ' utilisée (fournisseur Windows Installer)') }
    }
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($command in $commands) {
        $text = [string]$command.Extent.Text
        if ($text -match '(?i)\bmsiexec(\.exe)?\b' -and $text -match '(?i)(^|[\s''"])[/-]f[a-z]{0,7}([\s''"]|$)') { $findings.Add('Réparation MSI (msiexec /f)') }
    }
    return $findings.ToArray()
}

function Test-DomeniaInventoryCodeSafe {
    # Static check of an inventory code text. Refuses every class of the Windows Installer provider and the classes
    # whose enumeration reaches it (Get-DomeniaMsiProviderClassNames: the product class, CIM_Product, the feature and
    # element classes...) used as a class, in a WQL query (FROM, ISA, ASSOCIATORS OF) or in a WMI path, and any
    # msiexec repair switch, including inside embedded worker here-strings. A comparison with such a name that only
    # decides an if/while condition (a guard that refuses it) is accepted; the same comparison used as a value is not.
    # Limit: a name assembled at run time (concatenation, variable fed elsewhere, encoded text) or code held in a
    # one-line ordinary string is not seen; a guard proves nothing about what its own branch does.
    param([AllowEmptyString()][AllowNull()][string]$SourceText)
    $unique = @(@(Get-DomeniaInventoryCodeFindings $SourceText 0) | Select-Object -Unique)
    return [pscustomobject]@{Safe=($unique.Count -eq 0);Findings=$unique}
}

# ---------------------------------------------------------------- D074 targeted events, bounded
function Get-DomeniaEventPresets {
    # Fixed log, providers and identifiers per preset. Window and volume are bounded by New-DomeniaEventQuery.
    return @(
        [pscustomobject]@{Id='Startup';Label='Démarrage et arrêt';LogName=@('System');Providers=@('EventLog','Microsoft-Windows-Kernel-Power','User32');EventIds=@(6005,6006,6008,41,1074);Meaning='6005 et 6006 journal démarré ou arrêté, 6008 arrêt inattendu, 41 redémarrage sans arrêt propre, 1074 arrêt demandé par un processus ou un compte'}
        [pscustomobject]@{Id='Crash';Label='Plantages';LogName=@('Application');Providers=@('Application Error','Windows Error Reporting');EventIds=@(1000,1001);Meaning='1000 erreur dʼapplication, 1001 rapport dʼerreur Windows'}
        [pscustomobject]@{Id='Disk';Label='Disque';LogName=@('System');Providers=@('disk');EventIds=@(7,11,51,153);Meaning='7 bloc défectueux, 11 erreur de contrôleur, 51 erreur pendant une pagination, 153 opération dʼentrée-sortie relancée'}
        [pscustomobject]@{Id='Policy';Label='Stratégie de groupe';LogName=@('System','Microsoft-Windows-GroupPolicy/Operational');Providers=@('Microsoft-Windows-GroupPolicy');EventIds=@(1085,1125,7016);Meaning='1085 extension non appliquée, 1125 échec interne du traitement, 7016 fin du traitement dʼune extension avec son code'}
        [pscustomobject]@{Id='Updates';Label='Mises à jour';LogName=@('System');Providers=@('Microsoft-Windows-WindowsUpdateClient');EventIds=@(19,20,43);Meaning='19 installation signalée réussie par Windows Update, 20 échec dʼinstallation, 43 installation démarrée'}
    )
}

function New-DomeniaEventQuery {
    # Bounded query for one preset: 1 to 720 hours, 1 to 200 events. The worker passes Filter to Get-WinEvent
    # with -MaxEvents; nothing is read here.
    param([Parameter(Mandatory=$true)][string]$PresetId,[Parameter(Mandatory=$true)][datetime]$NowUtc,[int]$WindowHours=72,[int]$MaxEvents=50,[AllowEmptyString()][string]$Computer='')
    $preset = @(Get-DomeniaEventPresets | Where-Object { $_.Id -ceq $PresetId })
    if ($preset.Count -ne 1) { throw ('Préréglage dʼévénements inconnu : ' + $PresetId) }
    $chosen = $preset[0]
    $window = [Math]::Max(1,[Math]::Min(720,$WindowHours))
    $volume = [Math]::Max(1,[Math]::Min(200,$MaxEvents))
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    $start = $now.AddHours(-$window)
    $filter = @{LogName=@($chosen.LogName);ProviderName=@($chosen.Providers);Id=@($chosen.EventIds);StartTime=$start;EndTime=$now}
    return [pscustomobject]@{
        OperationId='ComputerEventsRead';PresetId=$chosen.Id;Label=$chosen.Label;Computer=$Computer
        LogName=@($chosen.LogName);Providers=@($chosen.Providers);EventIds=@($chosen.EventIds)
        StartTimeUtc=$start;EndTimeUtc=$now;WindowHours=$window;MaxEvents=$volume
        Clamped=(($window -ne $WindowHours) -or ($volume -ne $MaxEvents));Filter=$filter
    }
}

function ConvertTo-DomeniaEventFacts {
    # $Result: {ReadStatus, Events=@({Id,ProviderName,TimeCreatedUtc,MachineName,UserId,LevelDisplayName,Message}), Truncated}.
    # Attribution is explicit: with $UserSid only events carrying that SID concern the user; without it only events
    # emitted by the queried workstation concern it. Everything else stays general. A refused or failed read,
    # an answer without event list (Events missing or $null: the worker must send @() when nothing matched),
    # a partial read or an unrecognized status is never turned into "no event".
    param($Result,[Parameter(Mandatory=$true)]$Query,[AllowEmptyString()][string]$UserSid='',[AllowEmptyString()][string]$Reader='',[Parameter(Mandatory=$true)][datetime]$NowUtc)
    $status = 'NotRequested'
    if ($null -ne $Result) { $status = [string](Get-DomeniaMember $Result 'ReadStatus' 'OK') }
    $partialRead = Test-DomeniaWorkstationPartialStatus $status
    $state = ConvertTo-DomeniaWorkstationFactState $status
    if ($partialRead) { $state = 'Constate' }
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    $computer = [string](Get-DomeniaMember $Query 'Computer' '')
    $label = 'Événements : ' + [string](Get-DomeniaMember $Query 'Label' '')
    $source = 'Journal ' + (@(Get-DomeniaMember $Query 'LogName' @()) -join ', ')
    if ($computer) { $source += ' de ' + $computer }
    $window = [int](Get-DomeniaMember $Query 'WindowHours' 0)
    $limitCount = [int](Get-DomeniaMember $Query 'MaxEvents' 50)
    $ids = @(@(Get-DomeniaMember $Query 'EventIds' @()) | ForEach-Object { [int]$_ })
    $targetShort = Get-DomeniaWorkstationShortName $computer
    $sid = ConvertTo-DomeniaSidText $UserSid
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $attributed = 0; $general = 0; $ignored = 0; $partial = $false; $noneConfirmed = $false
    if ($state -eq 'Constate' -and -not (Test-DomeniaWorkstationListMember $Result 'Events')) {
        $state = 'Inconnu'
        $facts.Add((New-DomeniaFact -Fait $label -Valeur 'Réponse sans liste dʼévénements' -Etat Inconnu -Source $source -Limite 'Réponse incomplète : aucune conclusion sur la période.' -Date $now -Lecteur $Reader))
    }
    elseif ($state -eq 'Constate') {
        $list = @(@(Get-DomeniaMember $Result 'Events' @()) | Where-Object { $null -ne $_ })
        if ($partialRead -or (ConvertTo-DomeniaWorkstationBool (Get-DomeniaMember $Result 'Truncated' $false) $false)) { $partial = $true }
        foreach ($record in $list) {
            $number = 0
            if (-not [int]::TryParse([string](Get-DomeniaMember $record 'Id' ''),[ref]$number) -or $ids -notcontains $number) { $ignored++; continue }
            if ($rows.Count -ge $limitCount) { $partial = $true; break }
            $machine = Get-DomeniaWorkstationShortName ([string](Get-DomeniaMember $record 'MachineName' ''))
            $recordSid = ConvertTo-DomeniaSidText (Get-DomeniaMember $record 'UserId' '')
            $scope = 'Général'; $why = ''
            if ($sid) {
                if ($recordSid -and $recordSid -ceq $sid) { $scope = 'Cible'; $why = 'Compte de lʼévénement = utilisateur ciblé.' }
                elseif ($recordSid) { $why = 'Événement dʼun autre compte : non attribué à lʼutilisateur ciblé.' }
                else { $why = 'Événement sans compte associé : non attribué à lʼutilisateur ciblé.' }
            }
            elseif ($targetShort -and $machine -ceq $targetShort) { $scope = 'Cible'; $why = 'Émis par le poste interrogé.' }
            else { $why = 'Poste émetteur absent ou différent : non attribué au poste interrogé.' }
            if ($scope -eq 'Cible') { $attributed++ } else { $general++ }
            $when = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $record 'TimeCreatedUtc' $null)
            $whenText = ''
            if ($null -ne $when) { $whenText = $when.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') }
            $rows.Add([pscustomobject]@{
                Date=$whenText;Id=$number;Fournisseur=[string](Get-DomeniaMember $record 'ProviderName' '');Niveau=[string](Get-DomeniaMember $record 'LevelDisplayName' '')
                Attribution=$scope;Motif=$why;Message=(ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $record 'Message' '')) 300)
            })
        }
        # Exactly MaxEvents rows means the worker may have stopped there: the list is not proven complete.
        if ($rows.Count -ge $limitCount) { $partial = $true }
        if ($rows.Count -eq 0) {
            if ($partial) {
                $why = 'Volume plafonné : aucune conclusion sur la période.'
                if ($partialRead) { $why = 'Lecture partielle du journal : aucune conclusion sur la période.' }
                $facts.Add((New-DomeniaFact -Fait $label -Valeur 'Lecture partielle sans événement retenu' -Etat Inconnu -Source $source -Limite $why -Date $now -Lecteur $Reader))
            } else {
                $noneConfirmed = $true
                $facts.Add((New-DomeniaFact -Fait $label -Valeur ('Aucun événement correspondant dans les ' + [string]$window + ' dernières heures') -Source $source -Limite 'Absence constatée dans le journal et la fenêtre lus seulement ; un journal recyclé peut ne plus contenir les événements anciens.' -Date $now -Lecteur $Reader))
            }
        } else {
            $limit = 'Fenêtre de ' + [string]$window + ' h.'
            if ($partialRead) { $limit = 'Lecture partielle du journal : liste incomplète.' }
            elseif ($partial) { $limit = 'Volume plafonné à ' + [string]$limitCount + ' événements : liste partielle.' }
            $facts.Add((New-DomeniaFact -Fait $label -Valeur ([string]$rows.Count + ' événement(s) : ' + [string]$attributed + ' attribué(s) à la cible, ' + [string]$general + ' général(aux)') -Source $source -Limite $limit -Date $now -Lecteur $Reader))
        }
    }
    elseif ($state -eq 'Refuse') { $facts.Add((New-DomeniaFact -Fait $label -Valeur 'Lecture refusée' -Etat Refuse -Source $source -Limite 'Un refus de lecture ne signifie pas quʼaucun événement nʼa eu lieu : aucun constat sain.' -Date $now -Lecteur $Reader)) }
    elseif ($state -eq 'Indisponible') { $facts.Add((New-DomeniaFact -Fait $label -Valeur 'Journal injoignable' -Etat Indisponible -Source $source -Limite 'Aucune conclusion sur les événements de la période.' -Date $now -Lecteur $Reader)) }
    elseif (Test-DomeniaWorkstationNotRequested $status) { $facts.Add((New-DomeniaFact -Fait $label -Valeur 'Non demandés' -Etat Inconnu -Source $source -Limite 'La lecture du journal se demande explicitement.' -Date $now -Lecteur $Reader)) }
    else { $facts.Add((New-DomeniaFact -Fait $label -Valeur 'Lecture au statut non reconnu' -Etat Inconnu -Source $source -Limite ('Statut ' + (ConvertTo-DomeniaFlatText $status 40) + ' : aucune conclusion sur la période.') -Date $now -Lecteur $Reader)) }
    return [pscustomobject]@{
        PresetId=[string](Get-DomeniaMember $Query 'PresetId' '');ReadState=$state;Rows=$rows.ToArray();Facts=$facts.ToArray()
        NoEventsConfirmed=$noneConfirmed;Partial=$partial;Attributed=$attributed;General=$general;Ignored=$ignored
    }
}

# ---------------------------------------------------------------- D075 linked GPO versus applied result
function ConvertFrom-DomeniaGpLink {
    # gPLink = "[LDAP://cn={GUID},cn=policies,cn=system,DC=...;N]..." where bit 1 of N = link disabled, bit 2 = enforced.
    param([AllowEmptyString()][AllowNull()][string]$GpLink,[AllowEmptyString()][string]$ContainerDn='')
    $position = 0
    foreach ($item in [regex]::Matches([string]$GpLink,'\[(?i:LDAP)://(?<dn>[^;\]]+);(?<opt>\d{1,2})\]')) {
        $position++
        $dn = $item.Groups['dn'].Value
        $guid = ''
        $guidMatch = [regex]::Match($dn,'(?i)cn=\{(?<g>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\}')
        if ($guidMatch.Success) { $guid = ConvertTo-DomeniaGuidText $guidMatch.Groups['g'].Value }
        $options = 0
        [void][int]::TryParse($item.Groups['opt'].Value,[ref]$options)
        [pscustomobject]@{Guid=$guid;GpoDn=$dn;ContainerDn=$ContainerDn;Position=$position;LinkEnabled=(($options -band 1) -eq 0);Enforced=(($options -band 2) -ne 0);Options=$options}
    }
}

function Get-DomeniaRsopGpoGuid {
    # GUID of an RSoP entry flattened by the worker (RSOP_GPO or RSOP_GPLink): Guid, guidName '{GUID}', id or GPO
    # 'CN={GUID},CN=Policies,...'. '' for the local policy (id LocalGPO) or an unreadable reference.
    param($Entry)
    $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Entry 'Guid' '')
    if (-not $guid) { $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Entry 'GuidName' '') }
    foreach ($name in @('Id','Gpo')) {
        if ($guid) { break }
        $idMatch = [regex]::Match([string](Get-DomeniaMember $Entry $name ''),'\{(?<g>[0-9A-Fa-f-]{36})\}')
        if ($idMatch.Success) { $guid = ConvertTo-DomeniaGuidText $idMatch.Groups['g'].Value }
    }
    return $guid
}

function Get-DomeniaRsopGpoOutcome {
    # One GPO of the RSoP result. Explicit RSOP_GPO flags prove a non-application (security filtering, WMI filter,
    # disabled GPO). The application itself is proven only by RSOP_GPLink.appliedOrder > 0: a RSOP_GPO entry with
    # every flag favourable is still not applied when it is empty or reached through a disabled or blocked link
    # (seen on CNAMTS-W11-01: the local policy has favourable flags and appliedOrder 0). Missing or $null flags and
    # unreadable orders prove nothing.
    # $Orders: appliedOrder values of the RSOP_GPLink entries of this GPO; $LinksRead: RSOP_GPLink was read.
    param($Entry,[object[]]$Orders=@(),[bool]$LinksRead=$false)
    $denied = Get-DomeniaMember $Entry 'AccessDenied' $null
    $filter = Get-DomeniaMember $Entry 'FilterAllowed' $null
    $enabled = Get-DomeniaMember $Entry 'Enabled' $null
    if (ConvertTo-DomeniaWorkstationBool $denied $false) { return [pscustomobject]@{Result='Filtered';Text='Non appliquée : refusée par le filtrage de sécurité selon RSoP';State='Constate'} }
    if (-not (ConvertTo-DomeniaWorkstationBool $filter $true)) { return [pscustomobject]@{Result='Filtered';Text='Non appliquée : filtre WMI non satisfait selon RSoP';State='Constate'} }
    if (-not (ConvertTo-DomeniaWorkstationBool $enabled $true)) { return [pscustomobject]@{Result='Disabled';Text='Non appliquée : GPO désactivée selon RSoP';State='Constate'} }
    if ($LinksRead) {
        if (@($Orders).Count -eq 0) { return [pscustomobject]@{Result='Unproven';Text='Non prouvé : présente dans RSoP sans lien enregistré (RSOP_GPLink)';State='Inconnu'} }
        $best = -1L; $unreadable = 0
        foreach ($order in @($Orders)) {
            $number = 0L
            if (($null -ne $order) -and ([long]::TryParse(([string]$order).Trim(),[ref]$number)) -and ($number -ge 0)) { if ($number -gt $best) { $best = $number } }
            else { $unreadable++ }
        }
        if ($best -gt 0) { return [pscustomobject]@{Result='Applied';Text=('Appliquée selon RSoP du poste (ordre dʼapplication ' + [string]$best + ')');State='Constate'} }
        if ($unreadable -eq 0) { return [pscustomobject]@{Result='NotApplied';Text='Non appliquée selon RSoP : ordre dʼapplication nul (GPO vide, lien désactivé ou bloqué)';State='Constate'} }
        return [pscustomobject]@{Result='Unproven';Text='Non prouvé : ordre dʼapplication illisible dans RSoP';State='Inconnu'}
    }
    $favourable = ((-not (ConvertTo-DomeniaWorkstationBool $denied $true)) -and (ConvertTo-DomeniaWorkstationBool $filter $false) -and (ConvertTo-DomeniaWorkstationBool $enabled $false))
    if ($favourable) { return [pscustomobject]@{Result='Unproven';Text='Non prouvé : présente dans RSoP, filtrage favorable, ordre dʼapplication non lu';State='Inconnu'} }
    return [pscustomobject]@{Result='Unproven';Text='Non prouvé : présente dans RSoP, filtrage non lu';State='Inconnu'}
}

function Resolve-DomeniaGpoView {
    # Links read in AD (gPLink, gPOptions) and the result applied on the workstation (RSoP read by CIM in
    # root\rsop\computer) are two different facts. A linked GPO is announced applied only when RSOP_GPLink gives it an
    # applied order; it is announced not applied when RSoP lists it as filtered, disabled or with a null order, or
    # when a complete RSoP answer does not list it at all.
    # $Containers: from the container of the computer up to the domain root, each {Dn, GpLink, GpOptions, ReadStatus}.
    # $Rsop: {ReadStatus, Gpos=@({Guid, GuidName or Id, Name, AccessDenied, FilterAllowed, Enabled}),
    #         Links=@({Gpo or Guid, Som, AppliedOrder, Enabled, NoOverride}), ReadUtc} or $null when not read.
    # Gpos and Links must be lists: missing, $null or an empty Gpos list is an incomplete answer (RSoP logging off,
    # or a silenced error), never "nothing applied". Without Links, no GPO is announced applied.
    # $GpoNames: optional map GUID -> display name.
    param([object[]]$Containers=@(),$Rsop=$null,$GpoNames=$null,[AllowEmptyString()][string]$Reader='')
    $rsopStatus = 'NotRequested'
    if ($null -ne $Rsop) { $rsopStatus = [string](Get-DomeniaMember $Rsop 'ReadStatus' 'OK') }
    $rsopState = ConvertTo-DomeniaWorkstationFactState $rsopStatus
    $rsopSource = 'RSoP du poste (CIM root\rsop\computer, RSOP_GPO et RSOP_GPLink)'
    $rsopDate = Get-DomeniaMember $Rsop 'ReadUtc' $null
    $unproven = 'Non prouvé : résultat RSoP non demandé'
    if ($rsopState -eq 'Refuse') { $unproven = 'Non prouvé : lecture RSoP refusée' }
    elseif ($rsopState -eq 'Indisponible') { $unproven = 'Non prouvé : RSoP injoignable' }
    elseif ($rsopState -ne 'Constate' -and -not (Test-DomeniaWorkstationNotRequested $rsopStatus)) { $unproven = 'Non prouvé : lecture RSoP partielle ou au statut non reconnu' }
    $inRsop = @{}
    $orders = @{}
    $linksRead = $false
    if ($rsopState -eq 'Constate') {
        if (-not (Test-DomeniaWorkstationListMember $Rsop 'Gpos')) {
            $rsopState = 'Inconnu'; $unproven = 'Non prouvé : réponse RSoP incomplète'
        } else {
            $entries = 0
            foreach ($entry in @(Get-DomeniaMember $Rsop 'Gpos' @())) {
                if ($null -eq $entry) { continue }
                $entries++
                $guid = Get-DomeniaRsopGpoGuid $entry
                if ($guid) { $inRsop[$guid] = $entry }
            }
            if ($entries -eq 0) { $rsopState = 'Inconnu'; $unproven = 'Non prouvé : résultat RSoP vide (journalisation RSoP désactivée ou aucun traitement enregistré)' }
        }
    }
    if ($rsopState -eq 'Constate' -and (Test-DomeniaWorkstationListMember $Rsop 'Links')) {
        $linkEntries = 0
        foreach ($link in @(Get-DomeniaMember $Rsop 'Links' @())) {
            if ($null -eq $link) { continue }
            $linkEntries++
            $guid = Get-DomeniaRsopGpoGuid $link
            if (-not $guid) { continue }
            if (-not $orders.ContainsKey($guid)) { $orders[$guid] = New-Object 'System.Collections.Generic.List[object]' }
            $orders[$guid].Add((Get-DomeniaMember $link 'AppliedOrder' $null))
        }
        $linksRead = ($linkEntries -gt 0)
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $linked = @{}
    $blockedBelow = $false; $blockUnknown = $false; $linksComplete = $true; $containerCount = 0; $linkCount = 0; $unidentified = 0
    foreach ($container in @($Containers)) {
        if ($null -eq $container) { continue }
        $containerCount++
        $dn = [string](Get-DomeniaMember $container 'Dn' '')
        if ((ConvertTo-DomeniaWorkstationFactState ([string](Get-DomeniaMember $container 'ReadStatus' 'OK'))) -ne 'Constate') {
            # Links and inheritance flag unknown for this level, and therefore for every level above it.
            $linksComplete = $false; $blockUnknown = $true
            continue
        }
        foreach ($link in @(ConvertFrom-DomeniaGpLink ([string](Get-DomeniaMember $container 'GpLink' '')) $dn)) {
            $linkCount++
            $guid = [string]$link.Guid
            $expected = 'Non'
            if ($link.LinkEnabled) {
                if ($link.Enforced -or -not $blockedBelow) { $expected = 'Oui' }
                # A known block wins; an unread lower level leaves a non-enforced link undetermined.
                if ($blockUnknown -and -not $blockedBelow -and -not $link.Enforced) { $expected = 'Indéterminé' }
            }
            $inheritance = 'Héritée'
            if ($blockedBelow -and -not $link.Enforced) { $inheritance = 'Bloquée par un conteneur inférieur' }
            elseif ($containerCount -eq 1) { $inheritance = 'Lien direct' }
            $result = 'Unproven'; $resultText = $unproven; $factState = $rsopState
            if (-not $guid) {
                # The link does not name a GPO GUID: it can be compared with nothing.
                $unidentified++
                $resultText = 'Non prouvé : GPO du lien non identifiée'; $factState = 'Inconnu'
            }
            elseif ($rsopState -eq 'Constate') {
                if ($inRsop.ContainsKey($guid)) {
                    $gpoOrders = @()
                    if ($orders.ContainsKey($guid)) { $gpoOrders = $orders[$guid].ToArray() }
                    $outcome = Get-DomeniaRsopGpoOutcome $inRsop[$guid] $gpoOrders $linksRead
                    $result = $outcome.Result; $resultText = $outcome.Text; $factState = $outcome.State
                }
                else { $result = 'NotApplied'; $resultText = 'Absente du résultat RSoP du poste'; $factState = 'Constate' }
            }
            $name = ''
            if ($guid) { $name = [string](Get-DomeniaMember $GpoNames $guid '') }
            if (-not $name -and $guid -and $inRsop.ContainsKey($guid)) { $name = [string](Get-DomeniaMember $inRsop[$guid] 'Name' '') }
            if (-not $name) { $name = $guid }
            if (-not $name) { $name = [string]$link.GpoDn }
            if ($guid) { $linked[$guid] = $true }
            $linkText = 'Activé'
            if (-not $link.LinkEnabled) { $linkText = 'Désactivé' }
            $forced = 'Non'
            if ($link.Enforced) { $forced = 'Oui' }
            $proof = $rsopSource
            if ($factState -ne 'Constate') { $proof = 'Liens AD (gPLink) seulement' }
            $rows.Add([pscustomobject]@{
                Guid=$guid;Nom=$name;LieA=$dn;Lien=$linkText;Force=$forced;Heritage=$inheritance
                AttenduParLiens=$expected;Result=$result;Resultat=$resultText;Etat=$factState;Preuve=$proof
            })
        }
        $options = 0
        [void][int]::TryParse([string](Get-DomeniaMember $container 'GpOptions' 0),[ref]$options)
        if (($options -band 1) -ne 0) { $blockedBelow = $true }
    }
    $outside = 'Hors liens lus (site, stratégie locale ou conteneur non lu)'
    if ($unidentified -gt 0) { $outside = 'Hors liens lus (site, stratégie locale, conteneur non lu ou lien non identifié)' }
    foreach ($guid in @($inRsop.Keys | Sort-Object)) {
        if ($linked.ContainsKey($guid)) { continue }
        $entry = $inRsop[$guid]
        $name = [string](Get-DomeniaMember $GpoNames $guid '')
        if (-not $name) { $name = [string](Get-DomeniaMember $entry 'Name' '') }
        if (-not $name) { $name = $guid }
        $gpoOrders = @()
        if ($orders.ContainsKey($guid)) { $gpoOrders = $orders[$guid].ToArray() }
        $outcome = Get-DomeniaRsopGpoOutcome $entry $gpoOrders $linksRead
        $rows.Add([pscustomobject]@{Guid=$guid;Nom=$name;LieA='';Lien=$outside;Force='';Heritage='';AttenduParLiens='Indéterminé';Result=$outcome.Result;Resultat=$outcome.Text;Etat=$outcome.State;Preuve=$rsopSource})
    }
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $linkLimit = 'Un lien ne prouve pas lʼapplication : filtrage de sécurité, filtre WMI, blocage dʼhéritage, réplication ou poste non redémarré.'
    $linkState = 'Constate'
    if (-not $linksComplete) { $linkState = 'Estime'; $linkLimit = 'Certains conteneurs nʼont pas été lus : liste de liens incomplète. ' + $linkLimit }
    if ($unidentified -gt 0) { $linkLimit = [string]$unidentified + ' lien(s) sans GPO identifiable. ' + $linkLimit }
    $facts.Add((New-DomeniaFact -Fait 'Liens GPO lus dans AD' -Valeur ([string]$linkCount + ' lien(s) sur ' + [string]$containerCount + ' conteneur(s)') -Etat $linkState -Source 'Attributs gPLink et gPOptions' -Limite $linkLimit -Lecteur $Reader))
    $appliedValue = $unproven
    $appliedState = $rsopState
    if ($rsopState -eq 'Constate') {
        if ($linksRead) { $appliedValue = [string]@($rows | Where-Object { $_.Result -eq 'Applied' }).Count + ' GPO appliquée(s) selon RSoP' }
        else { $appliedValue = 'Application non prouvée : ordre dʼapplication (RSOP_GPLink) non lu'; $appliedState = 'Inconnu' }
    }
    $facts.Add((New-DomeniaFact -Fait 'Résultat appliqué sur le poste' -Valeur $appliedValue -Etat $appliedState -Source $rsopSource -Limite 'Résultat du dernier traitement des stratégies enregistré par le poste, pas une simulation.' -Date $rsopDate -Lecteur $Reader))
    return [pscustomobject]@{Rows=$rows.ToArray();Facts=$facts.ToArray();RsopState=$rsopState;AppliedProven=(($rsopState -eq 'Constate') -and $linksRead);LinksRead=$linksRead;LinksComplete=$linksComplete}
}

# ---------------------------------------------------------------- D076 AD / Entra / SSO diagnosis
function ConvertFrom-DomeniaDsregStatus {
    # Parses a pasted "dsregcmd /status" text into sections and values. Nothing is executed and nothing is repaired.
    param([AllowEmptyString()][AllowNull()][string]$Text,[ValidateRange(1024,1048576)][int]$MaxLength=131072)
    $raw = [string]$Text
    $truncated = $false
    if ($raw.Length -gt $MaxLength) { $raw = $raw.Substring(0,$MaxLength); $truncated = $true }
    $values = [ordered]@{}
    $sections = [ordered]@{}
    $current = ''
    $lineCount = 0
    foreach ($line in ($raw -split "`r?`n")) {
        $lineCount++
        $header = [regex]::Match($line,'^\s*\|\s*(?<name>[^|]*[^|\s])\s*\|\s*$')
        if ($header.Success) {
            $current = $header.Groups['name'].Value
            if (-not $sections.Contains($current)) { $sections[$current] = [ordered]@{} }
            continue
        }
        $pair = [regex]::Match($line,'^\s*(?<key>[A-Za-z][A-Za-z0-9 ._()-]{0,63}?)\s*:(\s+(?<value>.*))?$')
        if (-not $pair.Success) { continue }
        $key = $pair.Groups['key'].Value.Trim()
        $value = ''
        if ($pair.Groups['value'].Success) { $value = ConvertTo-DomeniaFlatText $pair.Groups['value'].Value 256 }
        if (-not $key) { continue }
        if (-not $sections.Contains($current)) { $sections[$current] = [ordered]@{} }
        if (-not $sections[$current].Contains($key)) { $sections[$current][$key] = $value }
        if (-not $values.Contains($key)) { $values[$key] = $value }
    }
    $valid = ($values.Contains('AzureAdJoined') -or $values.Contains('DomainJoined'))
    return [pscustomobject]@{Valid=$valid;Values=$values;Sections=$sections;Truncated=$truncated;LineCount=$lineCount}
}

function Get-DomeniaDsregValue {
    param($Values,[Parameter(Mandatory=$true)][string]$Key)
    return ([string](Get-DomeniaMember $Values $Key '')).Trim()
}

function Test-DomeniaDsregAccountMatch {
    # Compares the declared end user with the "Executing Account Name" line (DOMAIN\login, upn).
    # DOMAIN\login is compared whole, a UPN with the UPN part, a bare login with the login part.
    param([AllowEmptyString()][string]$EndUser='',[AllowEmptyString()][string]$ExecutingLine='')
    $parts = @(([string]$ExecutingLine) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0 -or -not ([string]$EndUser).Trim()) { return $false }
    $seen = ConvertTo-DomeniaAccountIdentity $parts[0]
    $wanted = ConvertTo-DomeniaAccountIdentity $EndUser
    if ($wanted.Form -eq 'DownLevel') { return ($seen.Form -eq 'DownLevel' -and $seen.Authority -ieq $wanted.Authority -and $seen.Login -ieq $wanted.Login) }
    if ($wanted.Form -eq 'Upn') {
        foreach ($part in $parts) { if ($part -ieq $EndUser.Trim()) { return $true } }
        return $false
    }
    return ([bool]$seen.Login -and $seen.Login -ieq $wanted.Login)
}

function Get-DomeniaJoinStateFacts {
    # Join state is a property of the device. SSO state (PRT, Windows Hello, workplace registration) belongs to the
    # session that ran dsregcmd: collected under an administrative account, in an undeclared session, or under an
    # account other than the end user, it says nothing about the token of the end user. No repair is offered here.
    param(
        $Status,
        [ValidateSet('EndUserSession','AdministrativeAccount','Unknown')][string]$CollectedAs='Unknown',
        [AllowEmptyString()][string]$EndUser='',
        [AllowEmptyString()][string]$ExpectedComputer='',
        [AllowEmptyString()][string]$Reader='',
        $CollectedUtc=$null
    )
    $source = 'dsregcmd /status (texte collé)'
    $pasted = 'Texte collé : poste, session et date de collecte déclarés, non vérifiés par Domenia.'
    $facts = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Status -or -not (ConvertTo-DomeniaWorkstationBool (Get-DomeniaMember $Status 'Valid' $false) $false)) {
        $facts.Add((New-DomeniaFact -Fait 'Jonction' -Valeur 'Texte non reconnu' -Etat Inconnu -Source $source -Limite 'Collez la sortie complète de dsregcmd /status.' -Lecteur $Reader))
        return [pscustomobject]@{Mode='Inconnu';SsoVerdict='NonEvaluable';SsoReason='Texte non reconnu.';ExecutingAccount='';ComputerMatches=$null;Facts=$facts.ToArray();RepairOffered=$false}
    }
    $values = Get-DomeniaMember $Status 'Values' $null
    $ad = (Get-DomeniaDsregValue $values 'DomainJoined').ToUpperInvariant()
    $entra = (Get-DomeniaDsregValue $values 'AzureAdJoined').ToUpperInvariant()
    $mode = 'Inconnu'
    if ($ad -eq 'YES' -and $entra -eq 'YES') { $mode = 'Hybride (AD et Entra ID)' }
    elseif ($entra -eq 'YES' -and $ad -eq 'NO') { $mode = 'Entra ID seul' }
    elseif ($ad -eq 'YES' -and $entra -eq 'NO') { $mode = 'Active Directory seul' }
    elseif ($ad -eq 'NO' -and $entra -eq 'NO') { $mode = 'Aucune jonction' }
    $yesNo = @{YES='Oui';NO='Non'}
    foreach ($pair in @(@('Jonction Active Directory',$ad,'DomainName'),@('Jonction Entra ID',$entra,'TenantName'))) {
        $flag = [string]$pair[1]
        if ($yesNo.ContainsKey($flag)) {
            $value = [string]$yesNo[$flag]
            $detail = Get-DomeniaDsregValue $values ([string]$pair[2])
            if ($flag -eq 'YES' -and $detail) { $value += ' (' + $detail + ')' }
            $facts.Add((New-DomeniaFact -Fait ([string]$pair[0]) -Valeur $value -Source $source -Limite $pasted -Date $CollectedUtc -Lecteur $Reader))
        } else {
            $facts.Add((New-DomeniaFact -Fait ([string]$pair[0]) -Valeur 'Non indiqué' -Etat Inconnu -Source $source -Limite $pasted -Date $CollectedUtc -Lecteur $Reader))
        }
    }
    $modeState = 'Constate'
    if ($mode -eq 'Inconnu') { $modeState = 'Inconnu' }
    $facts.Add((New-DomeniaFact -Fait 'Mode de jonction' -Valeur $mode -Etat $modeState -Source $source -Limite $pasted -Date $CollectedUtc -Lecteur $Reader))
    $deviceAuth = Get-DomeniaDsregValue $values 'DeviceAuthStatus'
    if ($deviceAuth) { $facts.Add((New-DomeniaFact -Fait 'Authentification de lʼappareil' -Valeur $deviceAuth -Source $source -Limite $pasted -Date $CollectedUtc -Lecteur $Reader)) }
    $deviceName = Get-DomeniaDsregValue $values 'Device Name'
    $computerMatches = $null
    if ($deviceName) {
        $hypothesis = ''
        if ($ExpectedComputer) {
            $computerMatches = ((Get-DomeniaWorkstationShortName $deviceName) -ceq (Get-DomeniaWorkstationShortName $ExpectedComputer))
            if (-not $computerMatches) { $hypothesis = 'Le texte semble provenir dʼun autre poste que ' + $ExpectedComputer + ' : il ne décrit pas ce poste.' }
        }
        $facts.Add((New-DomeniaFact -Fait 'Nom du poste dans le texte' -Valeur $deviceName -Source $source -Limite $pasted -Hypothese $hypothesis -Date $CollectedUtc -Lecteur $Reader))
    }
    # SSO: evaluable only for a text declared as collected in the end user session AND produced under that account.
    $executing = Get-DomeniaDsregValue $values 'Executing Account Name'
    $executingAccount = ''
    if ($executing) { $executingAccount = (($executing -split ',')[0]).Trim() }
    $evaluable = $false
    $reason = ''
    if ($CollectedAs -eq 'AdministrativeAccount') { $reason = 'Lu sous un compte dʼadministration : lʼétat SSO décrit cette session, pas le jeton de lʼutilisateur final.' }
    elseif ($CollectedAs -eq 'Unknown') { $reason = 'Session de collecte non déclarée : état SSO de lʼutilisateur final non évaluable.' }
    elseif (-not $EndUser.Trim()) { $reason = 'Utilisateur final non désigné : état SSO non évaluable.' }
    elseif (-not $executingAccount) { $reason = 'Compte dʼexécution absent du texte : session de collecte non vérifiable, état SSO non évaluable.' }
    elseif (Test-DomeniaDsregAccountMatch $EndUser $executing) { $evaluable = $true }
    else { $reason = 'Texte produit sous le compte ' + $executingAccount + ', pas sous celui de ' + $EndUser.Trim() + ' : état SSO non évaluable.' }
    $verdict = 'NonEvaluable'
    if ($evaluable) {
        $prt = (Get-DomeniaDsregValue $values 'AzureAdPrt').ToUpperInvariant()
        $userSource = 'dsregcmd /status, session de lʼutilisateur final (déclarée)'
        if ($prt -eq 'YES') { $verdict = 'PrtPresent' } elseif ($prt -eq 'NO') { $verdict = 'PrtAbsent' } else { $verdict = 'Inconnu' }
        $prtValue = 'Non indiqué'
        if ($prt -eq 'YES') { $prtValue = 'Présent' } elseif ($prt -eq 'NO') { $prtValue = 'Absent' }
        $prtUpdate = Get-DomeniaDsregValue $values 'AzureAdPrtUpdateTime'
        if ($prtUpdate -and $prt -eq 'YES') { $prtValue += ', mis à jour le ' + $prtUpdate }
        $prtState = 'Constate'
        if ($verdict -eq 'Inconnu') { $prtState = 'Inconnu' }
        $facts.Add((New-DomeniaFact -Fait 'Jeton SSO Entra ID (PRT)' -Valeur $prtValue -Etat $prtState -Source $userSource -Limite ('État à la date de collecte seulement. ' + $pasted) -Date $CollectedUtc -Lecteur $Reader))
        foreach ($pair in @(@('Windows Hello configuré','NgcSet'),@('Enregistrement Workplace','WorkplaceJoined'))) {
            $flag = (Get-DomeniaDsregValue $values ([string]$pair[1])).ToUpperInvariant()
            if ($yesNo.ContainsKey($flag)) { $facts.Add((New-DomeniaFact -Fait ([string]$pair[0]) -Valeur ([string]$yesNo[$flag]) -Source $userSource -Limite $pasted -Date $CollectedUtc -Lecteur $Reader)) }
        }
    } else {
        $facts.Add((New-DomeniaFact -Fait 'Jeton SSO de lʼutilisateur final' -Valeur 'Non évaluable' -Etat Inconnu -Source $source -Limite $reason -Date $CollectedUtc -Lecteur $Reader))
    }
    return [pscustomobject]@{Mode=$mode;SsoVerdict=$verdict;SsoReason=$reason;ExecutingAccount=$executingAccount;ComputerMatches=$computerMatches;Facts=$facts.ToArray();RepairOffered=$false}
}

# ---------------------------------------------------------------- D077 updates and management agent
function ConvertTo-DomeniaUpdateFacts {
    # $Providers: @({Provider='WindowsUpdate'|'WAPT'|..., Status, LastUtc, LastResult, Source, Detail}).
    # Date, source and result of the last available information. Old information is marked old; an absent
    # provider is unavailable, never "broken". Nothing is installed or relaunched.
    param([object[]]$Providers=@(),[Parameter(Mandatory=$true)][datetime]$NowUtc,[ValidateRange(1,3650)][int]$StaleDays=30,[AllowEmptyString()][string]$Reader='')
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $failures = 0
    foreach ($provider in @($Providers)) {
        if ($null -eq $provider) { continue }
        $id = [string](Get-DomeniaMember $provider 'Provider' '')
        $label = $id
        if ($id -ieq 'WindowsUpdate') { $label = 'Windows Update' } elseif ($id -ieq 'WAPT') { $label = 'Agent WAPT' }
        if (-not $label) { $label = 'Fournisseur non nommé' }
        $status = [string](Get-DomeniaMember $provider 'Status' 'NotRequested')
        $state = ConvertTo-DomeniaWorkstationFactState $status
        $source = [string](Get-DomeniaMember $provider 'Source' '')
        if (-not $source) { $source = $label }
        $dateText = ''; $age = $null; $stale = $false; $resultCode = ''; $resultText = ''
        $value = ''; $limit = ''; $factState = $state
        if ($status -match '^(?i:absent|notinstalled|missing|notfound)$') {
            $value = 'Non détecté sur ce poste'
            $limit = 'Fournisseur absent ou non installé : ce nʼest ni une panne, ni un échec de mise à jour.'
        }
        elseif ($state -eq 'Refuse') { $value = 'Lecture refusée'; $limit = 'Aucune conclusion sur les mises à jour de ce poste.' }
        elseif ($state -eq 'Indisponible') { $value = 'Lecture impossible'; $limit = 'Aucune conclusion sur les mises à jour de ce poste.' }
        elseif ($state -eq 'Inconnu') { $value = 'Non lu'; $limit = 'La lecture se demande explicitement.' }
        else {
            $last = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $provider 'LastUtc' $null)
            $raw = ([string](Get-DomeniaMember $provider 'LastResult' '')).Trim()
            if ($raw -match '^(?i:succeeded|success|ok|installed|0|reussi)$') { $resultCode = 'Succes'; $resultText = 'succès signalé par la source' }
            elseif ($raw -match '^(?i:failed|failure|error|echec)$') { $resultCode = 'Echec'; $resultText = 'échec signalé par la source'; $failures++ }
            elseif ($raw -match '^(?i:pending|inprogress|running|en attente)$') { $resultCode = 'EnAttente'; $resultText = 'en attente selon la source' }
            elseif ($raw) { $resultCode = 'Autre'; $resultText = ConvertTo-DomeniaFlatText $raw 120 }
            else { $resultCode = 'Inconnu'; $resultText = 'résultat non indiqué' }
            if ($null -eq $last) {
                $factState = 'Inconnu'; $value = 'Date de la dernière information inconnue, ' + $resultText
                $limit = 'Sans date, lʼinformation ne décrit pas lʼétat actuel.'
            } else {
                $age = [int][Math]::Floor(($now - $last).TotalDays)
                $dateText = $last.ToLocalTime().ToString('dd/MM/yyyy HH:mm')
                $value = 'Dernière information le ' + $dateText + ', ' + $resultText
                $limit = 'Dernière information disponible, pas une vérification en direct.'
                if ($last -gt $now.AddDays(1)) { $factState = 'Estime'; $value += ' (date postérieure à la lecture : horloge à vérifier)' }
                elseif ($age -gt $StaleDays) {
                    $stale = $true; $value += ' (ancienne : ' + [string]$age + ' j)'
                    $limit = 'Information de plus de ' + [string]$StaleDays + ' jours : lʼétat actuel nʼest pas connu.'
                }
            }
        }
        $fact = New-DomeniaFact -Fait $label -Valeur $value -Etat $factState -Source $source -Limite $limit -Date $now -Lecteur $Reader
        $facts.Add($fact)
        $rows.Add([pscustomobject]@{Provider=$id;Label=$label;State=$factState;Date=$dateText;AgeDays=$age;Stale=$stale;Result=$resultCode;ResultText=$resultText;Source=$source;Fact=$fact})
    }
    return [pscustomobject]@{Rows=$rows.ToArray();Facts=$facts.ToArray();ReportedFailures=$failures;StaleDays=$StaleDays}
}

# ---------------------------------------------------------------- D078 AD / DNS / machine identity coherence
function Test-DomeniaMachineIdentityCoherence {
    # Compares the AD name (sAMAccountName, dNSHostName), the DNS resolution and the identity returned by the
    # workstation before any observation is attributed to the AD object. A stale DNS record, a renamed workstation
    # or a reassigned address leaves the observations unattributed.
    # $Directory: {Name, DnsHostName, Guid}. $Resolution: {Status, Addresses, PtrName}. $Reported: {Status, ComputerName, DnsHostName, Domain}.
    param($Directory,$Resolution,$Reported,[AllowEmptyString()][string]$Reader='')
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $dnsName = ([string](Get-DomeniaMember $Directory 'DnsHostName' '')).Trim().TrimEnd('.')
    $samName = [string](Get-DomeniaMember $Directory 'Name' '')
    $expected = Get-DomeniaWorkstationShortName $dnsName
    if (-not $expected) { $expected = Get-DomeniaWorkstationShortName $samName }
    $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Directory 'Guid' '')
    $domainSuffix = ''
    if ($dnsName.IndexOf('.') -gt 0) { $domainSuffix = $dnsName.Substring($dnsName.IndexOf('.') + 1).ToLowerInvariant() }
    if ($samName -and $expected -and (Get-DomeniaWorkstationShortName $samName) -cne $expected) { $warnings.Add('Nom AD (' + $samName + ') et dNSHostName (' + $dnsName + ') diffèrent : renommage ou mise à jour en attente.') }
    $directoryName = $samName
    if ($dnsName) { $directoryName = $dnsName }
    $directoryState = 'Inconnu'
    if ($expected) { $directoryState = 'Constate' }
    $facts.Add((New-DomeniaFact -Fait 'Nom dans lʼannuaire' -Valeur $directoryName -Etat $directoryState -Source 'Attributs sAMAccountName et dNSHostName' -Lecteur $Reader))
    $state = 'Coherent'
    if (-not $expected) { $state = 'Unverified'; $reasons.Add('Nom AD du poste absent : identité non vérifiable.') }
    $resolutionState = ConvertTo-DomeniaWorkstationFactState ([string](Get-DomeniaMember $Resolution 'Status' 'NotRequested'))
    $addresses = @(@(Get-DomeniaMember $Resolution 'Addresses' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $address = ''
    if ($addresses.Count -gt 0) { $address = $addresses[0] }
    if ($resolutionState -ne 'Constate' -or $addresses.Count -eq 0) {
        if ($state -eq 'Coherent') { $state = 'Unverified' }
        $reasons.Add('Résolution DNS non obtenue : aucune adresse à confronter.')
        $dnsFactState = $resolutionState
        if ($resolutionState -eq 'Constate') { $dnsFactState = 'Inconnu' }
        $facts.Add((New-DomeniaFact -Fait 'Résolution DNS' -Valeur 'Non obtenue' -Etat $dnsFactState -Source 'DNS' -Lecteur $Reader))
    } else {
        $facts.Add((New-DomeniaFact -Fait 'Résolution DNS' -Valeur ($addresses -join ', ') -Source 'DNS' -Limite 'Un enregistrement DNS peut être périmé.' -Lecteur $Reader))
        $ptr = [string](Get-DomeniaMember $Resolution 'PtrName' '')
        if ($ptr -and $expected -and (Get-DomeniaWorkstationShortName $ptr) -cne $expected) { $warnings.Add('Lʼenregistrement inverse de ' + $address + ' désigne ' + $ptr + ' : DNS inverse périmé possible.') }
    }
    $reportedState = ConvertTo-DomeniaWorkstationFactState ([string](Get-DomeniaMember $Reported 'Status' 'NotRequested'))
    $reportedName = [string](Get-DomeniaMember $Reported 'DnsHostName' '')
    if (-not $reportedName) { $reportedName = [string](Get-DomeniaMember $Reported 'ComputerName' '') }
    $reportedShort = Get-DomeniaWorkstationShortName $reportedName
    if ($reportedState -ne 'Constate' -or -not $reportedShort) {
        if ($state -eq 'Coherent') { $state = 'Unverified' }
        $reasons.Add('Identité renvoyée par le poste non lue : les observations ne sont pas attribuées.')
        $reportedFactState = $reportedState
        if ($reportedState -eq 'Constate') { $reportedFactState = 'Inconnu' }
        $facts.Add((New-DomeniaFact -Fait 'Identité renvoyée par le poste' -Valeur 'Non lue' -Etat $reportedFactState -Source 'CIM Win32_ComputerSystem' -Lecteur $Reader))
    } else {
        $facts.Add((New-DomeniaFact -Fait 'Identité renvoyée par le poste' -Valeur $reportedName -Source 'CIM Win32_ComputerSystem' -Lecteur $Reader))
        if ($expected -and $reportedShort -cne $expected) {
            $state = 'Incoherent'
            $where = 'Lʼadresse interrogée'
            if ($address) { $where = 'Lʼadresse ' + $address }
            $reasons.Add($where + ' répond sous le nom ' + $reportedName + ', lʼannuaire attend ' + $expected + ' : DNS périmé, adresse réattribuée ou poste renommé.')
        }
        $reportedDomain = ([string](Get-DomeniaMember $Reported 'Domain' '')).Trim().TrimEnd('.').ToLowerInvariant()
        if (-not $reportedDomain) {
            # A fully qualified name returned by the workstation carries its domain: a namesake elsewhere is not this one.
            $fqdn = ([string]$reportedName).Trim().TrimEnd('.')
            if ($fqdn.IndexOf('\') -lt 0 -and $fqdn.IndexOf('.') -gt 0) { $reportedDomain = $fqdn.Substring($fqdn.IndexOf('.') + 1).ToLowerInvariant() }
        }
        if ($state -ne 'Incoherent' -and $reportedDomain -and $domainSuffix -and $reportedDomain -cne $domainSuffix) {
            $state = 'Incoherent'
            $reasons.Add('Le poste se déclare dans le domaine ' + $reportedDomain + ', lʼannuaire attend ' + $domainSuffix + ' : homonyme dʼun autre domaine.')
        }
    }
    $attribute = ($state -eq 'Coherent')
    $summary = 'Identité cohérente : les observations peuvent être attribuées à ce poste.'
    if ($state -eq 'Incoherent') { $summary = 'Identité incohérente : aucune observation ni relation nʼest attribuée à ce poste.' }
    elseif ($state -eq 'Unverified') { $summary = 'Identité non vérifiée : observations affichées sans attribution.' }
    return [pscustomobject]@{
        State=$state;AttributeObservations=$attribute;ComputerGuid=$guid;Address=$address;Expected=$expected;Reported=$reportedName
        Reasons=$reasons.ToArray();Warnings=$warnings.ToArray();Summary=$summary;Facts=$facts.ToArray()
    }
}

function Select-DomeniaRelationsForMachine {
    # Relations follow the AD object (its GUID), never an address or a reused name. A relation recorded for the
    # same address or the same name but another workstation, or without workstation GUID, is not handed to the
    # workstation that now owns that address or name. Without the GUID of the target workstation nothing is kept,
    # and no reason claims a GUID difference that cannot be checked.
    # $Relations: stored relations {UserLogin, ComputerGuid, Computer, Address}.
    param([object[]]$Relations=@(),[Parameter(Mandatory=$true)][AllowEmptyString()][string]$ComputerGuid,[AllowEmptyString()][string]$Address='',[AllowEmptyString()][string]$ComputerName='')
    $target = ConvertTo-DomeniaGuidText $ComputerGuid
    $short = Get-DomeniaWorkstationShortName $ComputerName
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $excluded = New-Object 'System.Collections.Generic.List[object]'
    $toVerify = New-Object 'System.Collections.Generic.List[object]'
    foreach ($relation in @($Relations)) {
        if ($null -eq $relation) { continue }
        $relationGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $relation 'ComputerGuid' '')
        $relationAddress = ([string](Get-DomeniaMember $relation 'Address' '')).Trim()
        $relationName = Get-DomeniaWorkstationShortName ([string](Get-DomeniaMember $relation 'Computer' ''))
        if ($target -and $relationGuid -and $relationGuid -ceq $target) { $kept.Add($relation); continue }
        $sameAddress = ($Address -and $relationAddress -and $relationAddress -ceq $Address.Trim())
        $sameName = ($short -and $relationName -and $relationName -ceq $short)
        if ($sameAddress) {
            $why = 'Même adresse mais autre poste (GUID différent) : relation non reprise.'
            if (-not $relationGuid) { $why = 'Relation enregistrée par adresse, sans GUID de poste : non attribuable.' }
            elseif (-not $target) { $why = 'Même adresse, GUID du poste cible inconnu : une adresse ne suffit pas, relation non reprise.' }
            $excluded.Add([pscustomobject]@{Relation=$relation;Reason=$why})
            continue
        }
        if ($sameName -and $relationGuid -and -not $target) { $toVerify.Add([pscustomobject]@{Relation=$relation;Reason='Même nom, GUID du poste cible inconnu : à vérifier avant reprise.'}); continue }
        if ($sameName -and $relationGuid) { $excluded.Add([pscustomobject]@{Relation=$relation;Reason='Même nom mais autre objet AD (GUID différent) : relation non reprise.'}); continue }
        if ($sameName) { $toVerify.Add([pscustomobject]@{Relation=$relation;Reason='Relation sans GUID de poste, rattachée au seul nom : à vérifier avant reprise.'}) }
    }
    return [pscustomobject]@{Kept=$kept.ToArray();Excluded=$excluded.ToArray();ToVerify=$toVerify.ToArray()}
}

# ---------------------------------------------------------------- D079 Wake-on-LAN, strictly voluntary
function Test-DomeniaMacAddress {
    # Accepts AA-BB-CC-DD-EE-FF, AA:BB:CC:DD:EE:FF, AABBCCDDEEFF and AABB.CCDD.EEFF. Refuses null, broadcast and
    # group (multicast) addresses: none of them designates one network card.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    $text = ([string]$Value).Trim()
    $hex = ''
    if ($text -match '^[0-9A-Fa-f]{2}([-:])[0-9A-Fa-f]{2}(\1[0-9A-Fa-f]{2}){4}$') { $hex = $text -replace '[-:]','' }
    elseif ($text -match '^[0-9A-Fa-f]{12}$') { $hex = $text }
    elseif ($text -match '^[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}$') { $hex = $text -replace '\.','' }
    if (-not $hex) { return [pscustomobject]@{Valid=$false;Normalized='';Reason='Adresse MAC absente ou mal formée.'} }
    $hex = $hex.ToUpperInvariant()
    if ($hex -eq '000000000000') { return [pscustomobject]@{Valid=$false;Normalized='';Reason='Adresse MAC nulle.'} }
    if ($hex -eq 'FFFFFFFFFFFF') { return [pscustomobject]@{Valid=$false;Normalized='';Reason='Adresse de diffusion : pas une carte réseau.'} }
    if (([Convert]::ToInt32($hex.Substring(0,2),16) -band 1) -ne 0) { return [pscustomobject]@{Valid=$false;Normalized='';Reason='Adresse de groupe (multicast) : pas une carte réseau.'} }
    $pairs = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt 12; $i += 2) { $pairs.Add($hex.Substring($i,2)) }
    return [pscustomobject]@{Valid=$true;Normalized=($pairs.ToArray() -join '-');Reason=''}
}

function New-DomeniaWakePacket {
    # Magic packet: six bytes 0xFF, then the MAC address sixteen times (102 bytes). Building it sends nothing.
    param([Parameter(Mandatory=$true)][string]$MacAddress)
    $check = Test-DomeniaMacAddress $MacAddress
    if (-not $check.Valid) { throw $check.Reason }
    $mac = New-Object byte[] 6
    $parts = $check.Normalized -split '-'
    for ($i = 0; $i -lt 6; $i++) { $mac[$i] = [Convert]::ToByte($parts[$i],16) }
    $bytes = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $bytes[$i] = [byte]0xFF }
    for ($repeat = 0; $repeat -lt 16; $repeat++) {
        for ($i = 0; $i -lt 6; $i++) { $bytes[6 + ($repeat * 6) + $i] = $mac[$i] }
    }
    return ,$bytes
}

function ConvertTo-DomeniaWakeIpv4Number {
    # Dotted IPv4 text to its unsigned value held in a long; -1 when the text is not a plain IPv4 address.
    param([AllowEmptyString()][AllowNull()][string]$Address)
    $parsed = [regex]::Match(([string]$Address).Trim(),'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
    if (-not $parsed.Success) { return -1L }
    $number = 0L
    for ($index = 1; $index -le 4; $index++) {
        $part = [long]$parsed.Groups[$index].Value
        if ($part -gt 255) { return -1L }
        $number = ($number * 256) + $part
    }
    return $number
}

function ConvertFrom-DomeniaWakeIpv4Number {
    param([long]$Number)
    $octets = New-Object long[] 4
    $rest = $Number
    for ($i = 3; $i -ge 0; $i--) { $octets[$i] = $rest % 256; $rest = [long][Math]::Floor($rest / 256) }
    return ($octets -join '.')
}

function ConvertTo-DomeniaWakeIpv4Prefix {
    # 255.255.255.0 -> 24. A non-contiguous mask returns -1.
    param([AllowEmptyString()][AllowNull()][string]$Mask)
    $number = ConvertTo-DomeniaWakeIpv4Number $Mask
    if ($number -lt 0) { return -1 }
    for ($prefix = 0; $prefix -le 32; $prefix++) {
        $size = [long][Math]::Pow(2,32 - $prefix)
        if ((4294967296L - $size) -eq $number) { return $prefix }
    }
    return -1
}

function Get-DomeniaBroadcastAddress {
    # Directed broadcast address of the known IPv4 subnet of a workstation. '' when the address or the prefix is
    # unknown, when the subnet has no broadcast (/31, /32), is wider than /8, or when the address is not a host.
    param([AllowEmptyString()][AllowNull()][string]$Address,[int]$PrefixLength=-1,[AllowEmptyString()][string]$Mask='')
    $prefix = $PrefixLength
    if ($prefix -lt 0 -and $Mask) { $prefix = ConvertTo-DomeniaWakeIpv4Prefix $Mask }
    if ($prefix -lt 8 -or $prefix -gt 30) { return '' }
    $number = ConvertTo-DomeniaWakeIpv4Number $Address
    if ($number -lt 0) { return '' }
    $first = [long][Math]::Floor($number / 16777216)
    if ($first -eq 0 -or $first -eq 127 -or $first -ge 224) { return '' }
    $size = [long][Math]::Pow(2,32 - $prefix)
    $network = $number - ($number % $size)
    $broadcast = $network + $size - 1
    if ($number -eq $network -or $number -eq $broadcast) { return '' }
    return (ConvertFrom-DomeniaWakeIpv4Number $broadcast)
}

function Test-DomeniaWakeIpv4InNetwork {
    # True when the address belongs to the network written a.b.c.d/n.
    param([AllowEmptyString()][AllowNull()][string]$Address,[AllowEmptyString()][AllowNull()][string]$Network)
    $parsed = [regex]::Match([string]$Network,'^\s*(?<ip>\d{1,3}(\.\d{1,3}){3})/(?<len>\d{1,2})\s*$')
    if (-not $parsed.Success) { return $false }
    $length = [int]$parsed.Groups['len'].Value
    if ($length -gt 32) { return $false }
    $base = ConvertTo-DomeniaWakeIpv4Number $parsed.Groups['ip'].Value
    $number = ConvertTo-DomeniaWakeIpv4Number $Address
    if ($base -lt 0 -or $number -lt 0) { return $false }
    $size = [long][Math]::Pow(2,32 - $length)
    return (($number - ($number % $size)) -eq ($base - ($base % $size)))
}

function Test-DomeniaWakeAllowed {
    # Off by default (Features.WakeOnLan). One known workstation, a valid MAC address, a known subnet entirely
    # inside the allowed perimeter and an explicit gesture are all required: no collective or automatic wake.
    # $Request: {MacAddress, Address, PrefixLength or Mask}.
    param($Request,[bool]$Enabled=$false,[string[]]$AllowedNetworks=@(),[AllowEmptyString()][string]$Trigger='',[int]$TargetCount=1)
    $denied = [pscustomobject]@{Allowed=$false;Reason='';MacAddress='';Broadcast='';Port=0;OperationId='WakeOnLanSend'}
    if (-not $Enabled) { $denied.Reason = 'Réveil désactivé par défaut (Features.WakeOnLan).'; return $denied }
    if ($Trigger -cne 'ExplicitWake') { $denied.Reason = 'Le réveil exige une action explicite sur ce poste.'; return $denied }
    if ($TargetCount -ne 1) { $denied.Reason = 'Un seul poste par demande : aucun réveil collectif.'; return $denied }
    $mac = Test-DomeniaMacAddress ([string](Get-DomeniaMember $Request 'MacAddress' ''))
    if (-not $mac.Valid) { $denied.Reason = 'Adresse MAC inconnue ou invalide : ' + $mac.Reason; return $denied }
    $address = [string](Get-DomeniaMember $Request 'Address' '')
    $prefix = -1; $parsed = 0
    if ([int]::TryParse([string](Get-DomeniaMember $Request 'PrefixLength' ''),[ref]$parsed)) { $prefix = $parsed }
    $broadcast = Get-DomeniaBroadcastAddress -Address $address -PrefixLength $prefix -Mask ([string](Get-DomeniaMember $Request 'Mask' ''))
    if (-not $broadcast) { $denied.Reason = 'Réseau du poste inconnu : adresse ou masque absent ou invalide.'; return $denied }
    $inside = $false
    foreach ($network in @($AllowedNetworks)) {
        if ((Test-DomeniaWakeIpv4InNetwork $address $network) -and (Test-DomeniaWakeIpv4InNetwork $broadcast $network)) { $inside = $true; break }
    }
    if (-not $inside) { $denied.Reason = 'Réseau du poste hors du périmètre autorisé.'; return $denied }
    return [pscustomobject]@{Allowed=$true;Reason='';MacAddress=$mac.Normalized;Broadcast=$broadcast;Port=9;OperationId='WakeOnLanSend'}
}

function Get-DomeniaWakeState {
    # A magic packet proves nothing about the workstation: the text says what was sent and what a later,
    # separate check saw. It never claims that the workstation is on.
    param([bool]$Sent=$false,[AllowEmptyString()][string]$SendError='',[ValidateSet('NotChecked','Reachable','NoAnswer')][string]$Verification='NotChecked')
    if (-not $Sent) {
        $text = 'Demande non envoyée.'
        if ($SendError) { $text += ' ' + (ConvertTo-DomeniaFlatText $SendError 160) }
        return [pscustomobject]@{State='NotSent';Text=$text}
    }
    if ($Verification -eq 'Reachable') { return [pscustomobject]@{State='ReachableAfterRequest';Text='Demande envoyée. Poste joignable lors de la vérification qui a suivi.'} }
    if ($Verification -eq 'NoAnswer') { return [pscustomobject]@{State='NoAnswerAfterRequest';Text='Demande envoyée. Aucune réponse lors de la vérification : cela ne prouve pas que le poste est éteint.'} }
    return [pscustomobject]@{State='RequestSent';Text='Demande envoyée. État du poste non vérifié.'}
}

# ---------------------------------------------------------------- D080 hand-off to suite tools (Pesto, FILPRO)
function Get-DomeniaSuiteContextFields {
    # Non-secret context a suite tool may receive, with the strict pattern its value must match.
    return [ordered]@{
        ComputerName='^(?=.{1,253}$)[A-Za-z0-9][A-Za-z0-9-]{0,62}(\.[A-Za-z0-9][A-Za-z0-9-]{0,62})*$'
        ComputerGuid='guid'
        UserLogin='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
        UserGuid='guid'
        Domain='^(?=.{1,253}$)[A-Za-z0-9][A-Za-z0-9-]{0,62}(\.[A-Za-z0-9][A-Za-z0-9-]{0,62})*$'
    }
}

function Get-DomeniaSuiteMemberNames {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [Collections.IDictionary]) { return @($InputObject.Keys | ForEach-Object { [string]$_ }) }
    return @($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Test-DomeniaSuiteContract {
    # The target tool declares suite-contract.json: {Schema='DomeniaSuiteContract/1', Tool, Version, Context={Field='--option'}}.
    # The caller reads the file next to the verified executable; this rule receives its text or object only.
    # Anything unexpected means "contract not recognized": the tool then opens without argument, as before.
    param($Contract,[Parameter(Mandatory=$true)][string]$ToolName)
    $refuse = { param($why) [pscustomobject]@{Recognized=$false;Reason=$why;Tool='';Version='';Fields=[ordered]@{}} }
    if ($null -eq $Contract) { return (& $refuse 'Aucun contrat déclaré par lʼoutil.') }
    $object = $Contract
    if ($Contract -is [string]) {
        $text = [string]$Contract
        if ($text.Length -gt 16384) { return (& $refuse 'Contrat trop volumineux.') }
        if (-not $text.Trim()) { return (& $refuse 'Contrat vide.') }
        try { $object = $text | ConvertFrom-Json -ErrorAction Stop } catch { return (& $refuse 'Contrat illisible (JSON invalide).') }
    }
    if ($null -eq $object -or $object -is [array] -or $object -is [string] -or $object -is [ValueType]) { return (& $refuse 'Contrat non reconnu : objet attendu.') }
    foreach ($name in @(Get-DomeniaSuiteMemberNames $object)) {
        if (@('Schema','Tool','Version','Context','Description') -cnotcontains $name) { return (& $refuse ('Champ non prévu dans le contrat : ' + $name + '.')) }
    }
    if ([string](Get-DomeniaMember $object 'Schema' '') -cne 'DomeniaSuiteContract/1') { return (& $refuse 'Schéma non reconnu (DomeniaSuiteContract/1 attendu).') }
    $tool = [string](Get-DomeniaMember $object 'Tool' '')
    if (-not $tool -or $tool -ine $ToolName) { return (& $refuse ('Contrat dʼun autre outil que ' + $ToolName + '.')) }
    $context = Get-DomeniaMember $object 'Context' $null
    $allowed = Get-DomeniaSuiteContextFields
    $allowedNames = @($allowed.Keys | ForEach-Object { [string]$_ })
    $fields = [ordered]@{}
    $options = @{}
    if ($null -ne $context) {
        if ($context -is [array] -or $context -is [string] -or $context -is [ValueType]) { return (& $refuse 'Context doit être un objet.') }
        foreach ($field in @(Get-DomeniaSuiteMemberNames $context)) {
            if ($allowedNames -cnotcontains $field) { return (& $refuse ('Champ de contexte non autorisé : ' + $field + '.')) }
            $option = Get-DomeniaMember $context $field ''
            if ($option -isnot [string] -or $option -cnotmatch '^(--?|/)[A-Za-z][A-Za-z0-9-]{0,31}$') { return (& $refuse ('Option invalide pour ' + $field + '.')) }
            if ($options.ContainsKey($option.ToLowerInvariant())) { return (& $refuse ('Option en double : ' + $option + '.')) }
            $options[$option.ToLowerInvariant()] = $true
            $fields[$field] = $option
        }
    }
    return [pscustomobject]@{Recognized=$true;Reason='';Tool=$tool;Version=[string](Get-DomeniaMember $object 'Version' '');Fields=$fields}
}

function Get-DomeniaSuiteLaunchPlan {
    # Explicit gesture only. With a recognized contract, only its declared non-secret fields are passed, each value
    # matching a strict pattern; without one, the tool opens without argument (current behaviour of
    # Open-DomeniaSuiteTool). Never a shell, never a credential: the caller starts the verified executable itself.
    param([Parameter(Mandatory=$true)][string]$ToolName,$Contract=$null,$Context=$null,[AllowEmptyString()][string]$Trigger='')
    if ($Trigger -cne 'ExplicitOpen') {
        return [pscustomobject]@{Allowed=$false;Mode='None';Arguments='';ArgumentList=@();Omitted=@();UsesShell=$false;Reason='Ouverture uniquement par le bouton de lʼoutil : une navigation ou une sélection ne lance rien.'}
    }
    $check = Test-DomeniaSuiteContract $Contract $ToolName
    if (-not $check.Recognized) {
        return [pscustomobject]@{Allowed=$true;Mode='NoArgument';Arguments='';ArgumentList=@();Omitted=@();UsesShell=$false;Reason=($check.Reason + ' Ouverture sans argument.')}
    }
    $patterns = Get-DomeniaSuiteContextFields
    $list = New-Object 'System.Collections.Generic.List[string]'
    $omitted = New-Object 'System.Collections.Generic.List[object]'
    foreach ($field in @($check.Fields.Keys | ForEach-Object { [string]$_ })) {
        $option = [string]$check.Fields[$field]
        $raw = Get-DomeniaMember $Context $field $null
        $value = ''; $why = ''
        if ($null -eq $raw) { $why = 'Valeur absente.' }
        elseif ($raw -is [Management.Automation.PSCredential] -or $raw -is [Security.SecureString]) { $why = 'Secret refusé : aucun compte ni mot de passe nʼest transmis.' }
        elseif ($raw -isnot [string] -and $raw -isnot [guid]) { $why = 'Type de valeur non pris en charge.' }
        else {
            $text = ([string]$raw).Trim()
            if ([string]$patterns[$field] -eq 'guid') {
                $value = ConvertTo-DomeniaGuidText $text
                if (-not $value) { $why = 'GUID invalide.' }
            }
            elseif ($text -cmatch [string]$patterns[$field]) { $value = $text }
            else { $why = 'Valeur refusée : caractères non autorisés.' }
        }
        if ($why) { $omitted.Add([pscustomobject]@{Field=$field;Reason=$why}); continue }
        $list.Add($option); $list.Add($value)
    }
    return [pscustomobject]@{Allowed=$true;Mode='Contract';Arguments=($list.ToArray() -join ' ');ArgumentList=$list.ToArray();Omitted=$omitted.ToArray();UsesShell=$false;Reason=''}
}

# ---------------------------------------------------------------- workstation board noise (MO-06)
function Get-DomeniaWorkstationNoiseRules {
    # Exclusions of the workstation board (decision David 2026-10-08, MO-06), kept as data in this module: no runtime
    # file. Event|Level|Sources|Event IDs (* = any)|Reason: Ignore leaves the error out of the board, Warn makes it a
    # point to watch; any other System error is an information line. Service|Name (* wildcard)|Reason: a service that
    # starts on a trigger or after a delay is expected to be stopped between two uses.
    $text = @'
Event|Ignore|DCOM,DistributedCOM,Microsoft-Windows-DistributedCOM|10016|Autorisations DCOM par défaut des composants Windows
Event|Warn|disk|*|Erreur du disque
Event|Warn|Ntfs,Microsoft-Windows-Ntfs|*|Système de fichiers NTFS
Event|Warn|Microsoft-Windows-Kernel-Power,Kernel-Power|41|Arrêt inattendu (Kernel-Power 41)
Service|gupdate|Google Update, démarrage différé
Service|GoogleUpdater*|Google Updater, démarrage sur déclencheur
Service|edgeupdate|Microsoft Edge Update, démarrage différé
Service|MapsBroker|Gestionnaire des cartes téléchargées, démarrage différé
Service|sppsvc|Protection logicielle, démarrage différé sur déclencheur
Service|RemoteRegistry|Registre à distance, démarrage sur déclencheur
Service|clr_optimization_*|Optimisation du runtime .NET, démarrage différé
Service|DoSvc|Optimisation de la distribution, démarrage différé
Service|UsoSvc|Orchestrateur des mises à jour, démarrage différé
Service|BITS|Service de transfert intelligent, démarrage différé
Service|wuauserv|Windows Update, démarrage sur déclencheur
Service|WbioSrvc|Biométrie Windows, démarrage sur déclencheur
Service|dmwappushservice|Routage des messages push, démarrage sur déclencheur
Service|WMPNetworkSvc|Partage réseau du Lecteur Windows Media, démarrage différé
Service|OneSyncSvc_*|Synchronisation de lʼhôte, démarrage différé
'@
    $events = New-Object System.Collections.ArrayList
    $services = New-Object System.Collections.ArrayList
    foreach ($line in ($text -split "`r?`n")) {
        $cells = @(([string]$line).Trim().Split('|'))
        if (($cells.Count -eq 5) -and ($cells[0] -ceq 'Event')) {
            $sources = @($cells[2].Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
            $ids = @($cells[3].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            [void]$events.Add([pscustomobject]@{ Level = $cells[1]; Sources = $sources; Ids = $ids; Reason = $cells[4] })
        }
        elseif (($cells.Count -eq 3) -and ($cells[0] -ceq 'Service') -and $cells[1].Trim()) {
            [void]$services.Add([pscustomobject]@{ Name = $cells[1].Trim(); Reason = $cells[2] })
        }
    }
    return [pscustomobject]@{ Events = @($events); Services = @($services) }
}
function Get-DomeniaSystemEventLevel {
    # Level of one System log error on the workstation board: Ignore (excluded), Warn (critical source) or Info.
    param([AllowEmptyString()][string]$Source,[AllowEmptyString()][string]$EventId,$Rules = $null)
    if ($null -eq $Rules) { $Rules = Get-DomeniaWorkstationNoiseRules }
    $name = ([string]$Source).Trim().ToLowerInvariant()
    $id = ([string]$EventId).Trim()
    foreach ($rule in @($Rules.Events)) {
        if ($name -notin @($rule.Sources)) { continue }
        if (('*' -in @($rule.Ids)) -or ($id -and ($id -in @($rule.Ids)))) { return [string]$rule.Level }
    }
    return 'Info'
}
function Test-DomeniaServiceStopExpected {
    # True when an automatic service may be stopped without fault (trigger or delayed start), by its short name.
    param([AllowEmptyString()][string]$Name,$Rules = $null)
    $service = ([string]$Name).Trim()
    if (-not $service) { return $false }
    if ($null -eq $Rules) { $Rules = Get-DomeniaWorkstationNoiseRules }
    foreach ($rule in @($Rules.Services)) { if ($service -like [string]$rule.Name) { return $true } }
    return $false
}
