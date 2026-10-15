# Workstation assistance rules (programme of 8 October 2026, lot X04): the five views of a workstation and the
# former tab names they absorb (UX-21), the fixed header (DS-08), the AD account card (UI-07), the restart plan and
# the sessions read before it (SE-08), the program run settings (UI-26), the PowerShell command to copy (UX-42), the
# services list and the service command plan (UX-38), and the pending operations pill (UX-19).
# Pure decisions: no WPF, no network, no disk access and no clock read (the current time is always a parameter).

# ---------------------------------------------------------------- UX-21 five views, former tab names resolved
function Get-DomeniaComputerViewNames {
    # The five views of Assistance poste, in their order: Vue dʼensemble, Intervenir, Détails, Diagnostic, Secrets.
    # TabComputer, TabComputerAdmin, TabComputerHealth and TabSecurity keep their former names; only Détails is new.
    return @('TabComputer','TabComputerAdmin','TabComputerDetails','TabComputerHealth','TabSecurity')
}

function Resolve-DomeniaComputerViewRoute {
    # A destination inside Assistance poste, former tab names included (menus, widget links, shortcuts, saved routes):
    # View is the view of ComputerTabs, Inner/Sub the inner tab when the view has one, Section the part of the view to
    # bring into sight. An unknown name resolves to nothing (Known = false): the caller keeps the current view.
    param([AllowEmptyString()][AllowNull()][string]$Tab)
    $name = ([string]$Tab).Trim()
    $view = ''; $inner = ''; $sub = ''; $section = ''
    switch -CaseSensitive ($name) {
        'TabComputer'          { $view = 'TabComputer' }
        'TabComputerDashboard' { $view = 'TabComputer'; $section = 'UxComputerDashboardSection' }
        'TabComputerAdmin'     { $view = 'TabComputerAdmin' }
        'TabSessions'          { $view = 'TabComputerAdmin'; $section = 'UxCompSessionsSection' }
        'TabComputerServices'  { $view = 'TabComputerAdmin'; $section = 'UxCompServicesSection' }
        'TabComputerDetails'   { $view = 'TabComputerDetails'; $inner = 'ComputerDetailTabs' }
        'TabInventory'         { $view = 'TabComputerDetails'; $inner = 'ComputerDetailTabs'; $sub = 'TabInventory' }
        'TabSoftware'          { $view = 'TabComputerDetails'; $inner = 'ComputerDetailTabs'; $sub = 'TabSoftware' }
        'TabComputerHealth'    { $view = 'TabComputerHealth'; $inner = 'ComputerDiagTabs'; $sub = 'TabComputerChecks' }
        'TabComputerChecks'    { $view = 'TabComputerHealth'; $inner = 'ComputerDiagTabs'; $sub = 'TabComputerChecks' }
        'TabWmi'               { $view = 'TabComputerHealth'; $inner = 'ComputerDiagTabs'; $sub = 'TabWmi' }
        'TabSecurity'          { $view = 'TabSecurity' }
    }
    return [pscustomobject]@{Tab=$name;Known=[bool]$view;View=$view;Inner=$inner;Sub=$sub;Section=$section;Alias=(([bool]$view) -and ($view -cne $name))}
}

# ---------------------------------------------------------------- DS-08 fixed header
function Get-DomeniaComputerPresenceBadge {
    # The coloured pill of the header, from the presence text of the fiche (TxtCompPresence). CheckedAt is the local
    # time of the last answer seen by this page (« 14:32 »), empty when unknown: a remembered state never gets a time.
    param([AllowEmptyString()][AllowNull()][string]$State='',[AllowEmptyString()][AllowNull()][string]$CheckedAt='')
    $value = ([string]$State).Trim()
    $remembered = $value.EndsWith('(cache)')
    if ($remembered) { $value = $value.Substring(0,$value.Length - 7).Trim() }
    $tone = 'Unknown'; $label = 'Présence non vérifiée'
    $help = 'Aucun test de présence pour ce poste dans cette session. « Tester la réponse » envoie un seul ping.'
    if ($value -like 'En ligne*') {
        $tone = 'Online'; $label = 'Répond au ping'
        $help = 'Réponse ICMP reçue. Un poste qui répond peut tout de même refuser les outils dʼadministration.'
    }
    elseif (($value -like 'Hors ligne*') -or ($value -like 'Sans réponse au ping*')) {
        $tone = 'Offline'; $label = 'Ne répond pas au ping'
        $help = 'Aucune réponse ICMP : poste éteint, hors du réseau ou ICMP filtré. Ce nʼest pas une preuve quʼil est éteint.'
    }
    elseif (($value -like 'Test*') -or ($value -like 'Vérification*')) {
        $tone = 'Pending'; $label = 'Test en cours'
        $help = 'Ping en cours. La pastille change dès la réponse.'
    }
    elseif ($value -like 'Erreur de ping*') {
        $tone = 'Error'; $label = 'Test impossible'
        $help = 'Le ping nʼa pas pu être envoyé. Le détail est dans le journal de session.'
    }
    $time = ([string]$CheckedAt).Trim()
    if (($remembered) -and ($tone -in @('Online','Offline'))) {
        $tone = 'Remembered'; $label += ' (mémoire)'
        $help += ' Valeur reprise de la mémoire locale : ce nʼest pas un état actuel confirmé.'
    }
    elseif (($time) -and ($tone -in @('Online','Offline','Error'))) {
        $label += ' · ' + $time
        $help += ' Dernier test à ' + $time + '.'
    }
    return [pscustomobject]@{Tone=$tone;Label=$label;Help=$help;State=$value;Remembered=$remembered}
}

function Get-DomeniaPresenceObservationTime {
    # DS-08: the local time (« 14:32 ») of the presence test an observation records: the latest of the last attempt
    # (PresenceAttemptUtc, also set by a failed test) and the last answer (PresenceCheckedUtc; CheckedUtc only for an
    # observation without it, as Get-DomeniaLivePresenceView reads it). '' when no date is readable: the pill then
    # shows no time rather than a guessed one.
    param($Observation)
    if ($null -eq $Observation) { return '' }
    $answered = Get-DomeniaMember $Observation 'PresenceCheckedUtc' $null
    if (($null -eq $answered) -or ([string]::IsNullOrWhiteSpace([string]$answered))) { $answered = Get-DomeniaMember $Observation 'CheckedUtc' $null }
    $latest = $null
    foreach ($value in @((Get-DomeniaMember $Observation 'PresenceAttemptUtc' $null),$answered)) {
        if (($null -eq $value) -or ([string]::IsNullOrWhiteSpace([string]$value))) { continue }
        $at = ConvertTo-DomeniaUtcDate $value
        if (($null -ne $at) -and (($null -eq $latest) -or ($at -gt $latest))) { $latest = $at }
    }
    if ($null -eq $latest) { return '' }
    return $latest.ToLocalTime().ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture)
}

function Get-DomeniaComputerHeaderView {
    # What the fixed header of a workstation shows, whatever the view: name, system, presence pill, associated user
    # and the age of the last inventory. Every text says when it does not know.
    param(
        [AllowEmptyString()][AllowNull()][string]$Name='',
        [AllowEmptyString()][AllowNull()][string]$OperatingSystem='',
        [AllowEmptyString()][AllowNull()][string]$Version='',
        [AllowEmptyString()][AllowNull()][string]$Presence='',
        [AllowEmptyString()][AllowNull()][string]$PresenceCheckedAt='',
        [AllowEmptyString()][AllowNull()][string]$UserDisplay='',
        [AllowEmptyString()][AllowNull()][string]$UserLogin='',
        [AllowEmptyString()][AllowNull()][string]$InventoryLabel=''
    )
    $computer = ([string]$Name).Trim()
    if (-not $computer) { $computer = 'Poste sans nom' }
    $os = ([string]$OperatingSystem).Trim(); $osVersion = ([string]$Version).Trim()
    $system = 'Système non renseigné dans lʼannuaire'
    if (($os) -and ($osVersion)) { $system = $os + ' · ' + $osVersion }
    elseif ($os) { $system = $os }
    elseif ($osVersion) { $system = 'Version ' + $osVersion }
    $login = ([string]$UserLogin).Trim()
    $user = ([string]$UserDisplay).Trim()
    if (-not $user) { $user = $login }
    $userHelp = 'Aucun utilisateur associé à ce poste dans la mémoire locale. « Détecter à nouveau » interroge le poste.'
    if ($user) { $userHelp = 'Ouvre la fiche de ' + $user + $(if (($login) -and ($login -cne $user)) { ' (' + $login + ')' } else { '' }) + '. Aucune écriture, aucune sonde du poste.' }
    $inventory = ([string]$InventoryLabel).Trim()
    if (-not $inventory) { $inventory = 'Aucun inventaire dans cette session' }
    return [pscustomobject]@{
        Name=$computer;SystemText=$system
        Presence=(Get-DomeniaComputerPresenceBadge -State $Presence -CheckedAt $PresenceCheckedAt)
        HasUser=[bool]$user;UserText=$user;UserLogin=$login;UserHelp=$userHelp;InventoryText=$inventory
    }
}

# ---------------------------------------------------------------- UI-07 AD account card
function Get-DomeniaComputerAccountAction {
    # One button for the computer account: Activer when it is disabled, Désactiver otherwise. An unreadable
    # userAccountControl shows neither: the page never guesses the state of an account.
    param($Uac)
    $value = 0L
    $known = (($null -ne $Uac) -and (-not [string]::IsNullOrWhiteSpace([string]$Uac)) -and ([long]::TryParse([string]$Uac,[ref]$value)))
    if (-not $known) {
        return [pscustomobject]@{Action='Unknown';ShowEnable=$false;ShowDisable=$false;Text='État du compte non lu : relisez la fiche avant de lʼactiver ou de le désactiver.'}
    }
    if (($value -band 2) -ne 0) {
        return [pscustomobject]@{Action='Enable';ShowEnable=$true;ShowDisable=$false;Text='Compte désactivé dans le domaine : le poste ne peut plus sʼauthentifier.'}
    }
    return [pscustomobject]@{Action='Disable';ShowEnable=$false;ShowDisable=$true;Text='Compte actif dans le domaine.'}
}

# ---------------------------------------------------------------- SE-08 restart with the sessions read first
function Get-DomeniaRestartDelaySeconds {
    # Restart.DefaultDelaySeconds: from 1 to 60 minutes, 5 minutes when absent or unreadable.
    param($Configured)
    $value = 0
    if (($null -eq $Configured) -or (-not [int]::TryParse([string]$Configured,[ref]$value))) { return 300 }
    if ($value -lt 60) { return 60 }
    if ($value -gt 3600) { return 3600 }
    return $value
}

function Get-DomeniaRestartDefaultMessage {
    param([int]$DelaySeconds=300)
    $minutes = [int][Math]::Ceiling([Math]::Max(60,$DelaySeconds) / 60.0)
    $unit = 'minutes'; if ($minutes -eq 1) { $unit = 'minute' }
    return ('Votre poste va redémarrer dans ' + $minutes + ' ' + $unit + ' à la demande du support informatique. Enregistrez votre travail et fermez vos documents.')
}

function Get-DomeniaRestartPlan {
    # The restart chosen in the page. Delayed (default): shutdown /r with a delay and a message shown to the user of
    # the workstation. Now: immediate forced restart, without message. The message is one line of at most 400
    # characters, without double quote (it travels as a native argument of shutdown.exe). The delayed restart travels
    # by WinRM: it is refused when the configuration forbids WinRM (WinRmAllowed = Remote.UseWinRM).
    param(
        [AllowEmptyString()][AllowNull()][string]$Computer='',
        [AllowEmptyString()][AllowNull()][string]$Mode='Delayed',
        [int]$DelaySeconds=300,
        [AllowEmptyString()][AllowNull()][string]$Message='',
        [bool]$WinRmAllowed=$true
    )
    $target = ([string]$Computer).Trim()
    $choice = ([string]$Mode).Trim()
    if ($choice -notin @('Delayed','Now')) { return [pscustomobject]@{Valid=$false;Reason='Choisissez « Dans 5 min avec message » ou « Maintenant ».';Computer=$target;Mode=$choice} }
    if (-not $target) { return [pscustomobject]@{Valid=$false;Reason='Aucun poste sélectionné.';Computer='';Mode=$choice} }
    if (($choice -eq 'Delayed') -and (-not $WinRmAllowed)) { return [pscustomobject]@{Valid=$false;Reason='Redémarrage différé indisponible : il passe par WinRM, désactivé par la configuration (Remote.UseWinRM). Rien nʼest envoyé.';Computer=$target;Mode=$choice} }
    $delay = Get-DomeniaRestartDelaySeconds $DelaySeconds
    $minutes = [int][Math]::Ceiling($delay / 60.0)
    if ($choice -eq 'Now') {
        return [pscustomobject]@{
            Valid=$true;Reason='';Computer=$target;Mode='Now';DelaySeconds=0;Minutes=0;Message=''
            Summary='Redémarrage immédiat, sans délai ni message : le travail non enregistré sur le poste est perdu.'
            ConfirmText='Redémarrer maintenant';Title=('Redémarrer ' + $target + ' maintenant ?')
        }
    }
    $text = ([string]$Message) -replace '[\x00-\x1F\x7F]+',' '
    $text = ($text.Replace([string][char]34,[string][char]39) -replace '\s+',' ').Trim().TrimEnd([char]92).Trim()
    if (-not $text) { $text = Get-DomeniaRestartDefaultMessage -DelaySeconds $delay }
    if ($text.Length -gt 400) { return [pscustomobject]@{Valid=$false;Reason='Message trop long : 400 caractères au plus.';Computer=$target;Mode='Delayed'} }
    return [pscustomobject]@{
        Valid=$true;Reason='';Computer=$target;Mode='Delayed';DelaySeconds=$delay;Minutes=$minutes;Message=$text
        Summary=('Redémarrage dans ' + $minutes + ' min. Lʼutilisateur voit le message : « ' + $text + ' »')
        ConfirmText=('Redémarrer dans ' + $minutes + ' min');Title=('Redémarrer ' + $target + ' dans ' + $minutes + ' min ?')
    }
}

function Get-DomeniaRestartSessionSummary {
    # What the restart panel says of the sessions read just before (ConvertTo-DomeniaSessionView). A refused or
    # failed read concludes nothing: an open session stays possible and the delayed restart stays recommended.
    param($View,[AllowEmptyString()][AllowNull()][string]$Failure='')
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $failureText = ConvertTo-DomeniaFlatText ([string]$Failure) 200
    if ($failureText) {
        return [pscustomobject]@{Known=$false;Count=-1;Lines=@();Text=('Sessions non lues : ' + $failureText + ' Une session peut être ouverte : préférez le redémarrage différé avec message.')}
    }
    if ($null -eq $View) {
        return [pscustomobject]@{Known=$false;Count=-1;Lines=@();Text='Lecture des sessions ouvertes en cours…'}
    }
    $state = [string](Get-DomeniaMember $View 'ReadState' '')
    if ($state -ne 'Constate') {
        $empty = [string](Get-DomeniaMember $View 'EmptyText' '')
        if (-not $empty) { $empty = 'Sessions non lues : aucune conclusion.' }
        return [pscustomobject]@{Known=$false;Count=-1;Lines=@();Text=($empty + ' Une session peut être ouverte : préférez le redémarrage différé avec message.')}
    }
    foreach ($row in @(Get-DomeniaMember $View 'Rows' @())) {
        if ($null -eq $row) { continue }
        $parts = @([string](Get-DomeniaMember $row 'Utilisateur' ''))
        foreach ($field in @('Protocole','Etat')) { $v = [string](Get-DomeniaMember $row $field ''); if ($v) { $parts += $v } }
        $opened = [string](Get-DomeniaMember $row 'Ouverte' ''); if ($opened) { $parts += ('ouverte à ' + $opened) }
        $idle = [string](Get-DomeniaMember $row 'Inactive' ''); if ($idle) { $parts += ('inactive depuis ' + $idle) }
        $lines.Add(($parts | Where-Object { $_ }) -join ' · ')
    }
    $count = [int](Get-DomeniaMember $View 'UserSessions' 0)
    $unread = [int](Get-DomeniaMember $View 'UnreadSessions' 0)
    $text = 'Aucune session utilisateur ouverte lors de la lecture.'
    if ($count -eq 1) { $text = '1 session ouverte : le travail non enregistré de cet utilisateur sera perdu sans délai.' }
    elseif ($count -gt 1) { $text = [string]$count + ' sessions ouvertes : le travail non enregistré de ces utilisateurs sera perdu sans délai.' }
    if ($unread -gt 0) { $text += ' ' + [string]$unread + ' session(s) dont le compte nʼa pas pu être lu.' }
    if ([bool](Get-DomeniaMember $View 'Partial' $false)) { $text += ' Lecture partielle : aucune conclusion sur les sessions non listées.' }
    return [pscustomobject]@{Known=$true;Count=$count;Lines=$lines.ToArray();Text=$text}
}

# ---------------------------------------------------------------- UI-26 run a program on the workstation
function Get-DomeniaRunProgramPlan {
    # Two ways only: in the background under the system account (SYSTEM, without window), or in the session of a
    # user already logged on. The program path is the one of the workstation; arguments stay a plain string.
    param(
        [AllowEmptyString()][AllowNull()][string]$Computer='',
        [AllowEmptyString()][AllowNull()][string]$Mode='System',
        [AllowEmptyString()][AllowNull()][string]$Command='',
        [AllowEmptyString()][AllowNull()][string]$Arguments='',
        [AllowEmptyString()][AllowNull()][string]$RunUser='',
        [bool]$Elevated=$true
    )
    $target = ([string]$Computer).Trim()
    $program = ([string]$Command).Trim()
    $args2 = ([string]$Arguments).Trim()
    $user = ([string]$RunUser).Trim()
    $refuse = { param([string]$Why) return [pscustomobject]@{Valid=$false;Reason=$Why} }
    if (-not $target) { return (& $refuse 'Aucun poste sélectionné.') }
    if ([string]$Mode -notin @('System','Interactive')) { return (& $refuse 'Choisissez « En arrière-plan (compte système) » ou « Dans la session de lʼutilisateur ».') }
    if (-not $program) { return (& $refuse 'Indiquez le programme à lancer, tel quʼil existe sur le poste.') }
    if (($program.Length -gt 260) -or ($args2.Length -gt 1024)) { return (& $refuse 'Programme ou arguments trop longs.') }
    if (($program + $args2) -match '[\x00-\x1F]') { return (& $refuse 'Retour à la ligne ou caractère de contrôle refusé dans la commande.') }
    if ([string]$Mode -eq 'Interactive') {
        if (-not $user) { return (& $refuse 'Indiquez le compte de la session ouverte sur le poste.') }
        if ($user -notmatch '^[^\\/:*?"<>|\s]{1,64}(\\[^\\/:*?"<>|\s]{1,104})?$') { return (& $refuse 'Compte de session invalide : DOMAINE\identifiant ou identifiant.') }
    } else { $user = '' }
    $how = 'en arrière-plan sous le compte système, sans fenêtre visible'
    if ([string]$Mode -eq 'Interactive') { $how = 'dans la session ouverte de ' + $user }
    $line = $program; if ($args2) { $line += ' ' + $args2 }
    return [pscustomobject]@{
        Valid=$true;Reason='';Computer=$target;Mode=[string]$Mode;Command=$program;Arguments=$args2;RunUser=$user;Elevated=$Elevated
        Title=('Exécuter un programme sur ' + $target + ' ?')
        Summary=('Lance « ' + $line + ' » ' + $how + $(if ($Elevated) { ', avec le niveau le plus élevé' } else { '' }) + '. Une tâche planifiée unique est créée puis supprimée ; lʼexécution du programme nʼest pas vérifiée.')
    }
}

# ---------------------------------------------------------------- UX-42 PowerShell command copied
function Get-DomeniaPsRemoteCommand {
    # The command copied for the technicianʼs own console. With an account for workstations, -Credential names it so
    # that Windows asks for its password; the password itself is never part of the text.
    param([Parameter(Mandatory=$true)][string]$Computer,[AllowEmptyString()][AllowNull()][string]$UserName='')
    $quote = { param([string]$Value) return ("'" + $Value.Replace("'","''") + "'") }
    $text = 'Enter-PSSession -ComputerName ' + (& $quote $Computer.Trim())
    $user = ([string]$UserName).Trim()
    $status = 'Commande PowerShell copiée : collez-la dans votre console PowerShell.'
    if ($user) {
        $text += ' -Credential ' + (& $quote $user)
        $status = 'Commande PowerShell copiée avec le compte ' + $user + ' : Windows demandera son mot de passe, qui nʼest jamais copié.'
    }
    return [pscustomobject]@{Text=$text;UsesCredential=[bool]$user;Status=$status}
}

# ---------------------------------------------------------------- UX-38 services of the workstation
function Get-DomeniaServiceStateLabel {
    param([AllowEmptyString()][AllowNull()][string]$State)
    switch ([string]$State) {
        'Running' { return 'En cours' }
        'Stopped' { return 'Arrêté' }
        'Start Pending' { return 'Démarrage en cours' }
        'Stop Pending' { return 'Arrêt en cours' }
        'Paused' { return 'En pause' }
        'Pause Pending' { return 'Mise en pause en cours' }
        'Continue Pending' { return 'Reprise en cours' }
        '' { return 'Non lu' }
    }
    return [string]$State
}

function Get-DomeniaServiceStartLabel {
    param([AllowEmptyString()][AllowNull()][string]$StartMode,[AllowEmptyString()][AllowNull()][string]$Delayed='')
    switch ([string]$StartMode) {
        'Auto' { if ([string]$Delayed -ieq 'True') { return 'Automatique (différé)' }; return 'Automatique' }
        'Manual' { return 'Manuel' }
        'Disabled' { return 'Désactivé' }
        'Boot' { return 'Démarrage du système' }
        'System' { return 'Système' }
        '' { return 'Non lu' }
    }
    return [string]$StartMode
}

function ConvertTo-DomeniaServiceRows {
    # Win32_Service as read by the WmiQuery operation (one row per instance and property) into one row per service.
    param([object[]]$Instances=@())
    $byInstance = @{}
    $order = New-Object 'System.Collections.Generic.List[string]'
    foreach ($cell in @($Instances)) {
        if ($null -eq $cell) { continue }
        $key = [string](Get-DomeniaMember $cell 'Instance' '')
        if (-not $key) { continue }
        if (-not $byInstance.ContainsKey($key)) { $byInstance[$key] = @{}; $order.Add($key) }
        $byInstance[$key][[string](Get-DomeniaMember $cell 'Property' '')] = [string](Get-DomeniaMember $cell 'Value' '')
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $order) {
        $p = $byInstance[$key]
        $name = ''; if ($p.ContainsKey('Name')) { $name = [string]$p['Name'] }
        if (-not $name) { continue }
        $display = $name; if (($p.ContainsKey('DisplayName')) -and ([string]$p['DisplayName'])) { $display = [string]$p['DisplayName'] }
        $state = ''; if ($p.ContainsKey('State')) { $state = [string]$p['State'] }
        $start = ''; if ($p.ContainsKey('StartMode')) { $start = [string]$p['StartMode'] }
        $delayed = ''; if ($p.ContainsKey('DelayedAutoStart')) { $delayed = [string]$p['DelayedAutoStart'] }
        $autoStopped = (($start -eq 'Auto') -and ($state -eq 'Stopped'))
        $rows.Add([pscustomobject]@{
            Name=$name;DisplayName=$display;State=$state;StartMode=$start
            StateLabel=(Get-DomeniaServiceStateLabel $state);StartLabel=(Get-DomeniaServiceStartLabel $start $delayed)
            AutoStopped=$autoStopped;CanStart=(($state -eq 'Stopped') -and ($start -ne 'Disabled'));CanRestart=($state -eq 'Running')
        })
    }
    return @($rows.ToArray() | Sort-Object @{Expression={[bool]$_.AutoStopped};Descending=$true},@{Expression={[string]$_.DisplayName}})
}

function Test-DomeniaServiceRowMatch {
    # Local filter of the services list: « automatiques arrêtés » and a text found in the name or the display name.
    param($Row,[bool]$AutoStoppedOnly=$false,[AllowEmptyString()][AllowNull()][string]$Text='')
    if ($null -eq $Row) { return $false }
    if (($AutoStoppedOnly) -and (-not [bool](Get-DomeniaMember $Row 'AutoStopped' $false))) { return $false }
    $needle = ([string]$Text).Trim()
    if (-not $needle) { return $true }
    foreach ($field in @('DisplayName','Name')) {
        if (([string](Get-DomeniaMember $Row $field '')).IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Get-DomeniaServiceListSummary {
    param([object[]]$Rows=@(),[int]$Shown=0,[AllowEmptyString()][AllowNull()][string]$ReadAt='',[AllowEmptyString()][AllowNull()][string]$Computer='')
    $all = @($Rows | Where-Object { $null -ne $_ })
    $stopped = @($all | Where-Object { [bool]$_.AutoStopped }).Count
    $text = [string]$all.Count + ' service(s) lus'
    if ($Computer) { $text += ' sur ' + $Computer }
    if ($ReadAt) { $text += ' à ' + $ReadAt }
    $text += ' ; ' + [string]$stopped + ' automatique(s) arrêté(s)'
    if ($Shown -ne $all.Count) { $text += ' ; ' + [string]$Shown + ' affiché(s) par le filtre' }
    return ($text + '. Lecture seule : la liste ne se relit que sur « Lire les services ».')
}

function Get-DomeniaServiceRowWithState {
    # The row of a service once a command came back with the state the worker read again; the other fields stay.
    param($Row,[AllowEmptyString()][AllowNull()][string]$State='')
    if ($null -eq $Row) { return $null }
    $start = [string](Get-DomeniaMember $Row 'StartMode' '')
    $value = [string]$State
    return [pscustomobject]@{
        Name=[string](Get-DomeniaMember $Row 'Name' '');DisplayName=[string](Get-DomeniaMember $Row 'DisplayName' '');State=$value;StartMode=$start
        StateLabel=(Get-DomeniaServiceStateLabel $value);StartLabel=[string](Get-DomeniaMember $Row 'StartLabel' (Get-DomeniaServiceStartLabel $start))
        AutoStopped=(($start -eq 'Auto') -and ($value -eq 'Stopped'));CanStart=(($value -eq 'Stopped') -and ($start -ne 'Disabled'));CanRestart=($value -eq 'Running')
    }
}

function Test-DomeniaServiceName {
    # Key name of a service (Win32_Service.Name) as it may travel in a WQL filter: letters, digits, spaces inside and
    # a few signs used by Windows and editors (MSSQL$SQLEXPRESS, CDPUserSvc_1a2b3c, Apple Mobile Device Service).
    # A quote, a backslash or a control character is refused: the name never changes the meaning of the filter.
    param([AllowEmptyString()][AllowNull()][string]$Name)
    $value = [string]$Name
    if (($value.Length -lt 1) -or ($value.Length -gt 256) -or ($value -cne $value.Trim())) { return $false }
    return ($value -match '^[A-Za-z0-9 _.$@+#,(){}-]+$')
}

function Get-DomeniaServiceControlPlan {
    # Start or restart one service of the selected workstation. The start type of a service is never changed: a
    # disabled service is refused here, before any request. The name is the service key name (Win32_Service.Name).
    param(
        [AllowEmptyString()][AllowNull()][string]$Computer='',
        [AllowEmptyString()][AllowNull()][string]$Action='',
        $Row
    )
    $target = ([string]$Computer).Trim()
    $refuse = { param([string]$Why) return [pscustomobject]@{Valid=$false;Reason=$Why} }
    if (-not $target) { return (& $refuse 'Aucun poste sélectionné.') }
    if ($null -eq $Row) { return (& $refuse 'Sélectionnez un service dans la liste.') }
    $name = [string](Get-DomeniaMember $Row 'Name' '')
    $display = [string](Get-DomeniaMember $Row 'DisplayName' $name)
    $state = [string](Get-DomeniaMember $Row 'State' '')
    $start = [string](Get-DomeniaMember $Row 'StartMode' '')
    if (-not (Test-DomeniaServiceName $name)) { return (& $refuse 'Nom de service non reconnu : aucune commande ne part.') }
    switch ([string]$Action) {
        'Start' {
            if ($start -eq 'Disabled') { return (& $refuse ('« ' + $display + ' » est désactivé : Domenia ne change pas le type de démarrage dʼun service.')) }
            if ($state -ne 'Stopped') { return (& $refuse ('« ' + $display + ' » nʼest pas arrêté (' + (Get-DomeniaServiceStateLabel $state) + ').')) }
            return [pscustomobject]@{
                Valid=$true;Reason='';Computer=$target;Action='Start';Name=$name;DisplayName=$display;Risk='Normal';ConfirmText='Démarrer'
                Title=('Démarrer « ' + $display + ' » sur ' + $target + ' ?')
                Summary=('Demande au poste de démarrer le service ' + $name + ', puis relit son état. Aucun autre service nʼest modifié.')
            }
        }
        'Restart' {
            if ($state -ne 'Running') { return (& $refuse ('« ' + $display + ' » nʼest pas en cours (' + (Get-DomeniaServiceStateLabel $state) + ') : utilisez Démarrer.')) }
            return [pscustomobject]@{
                Valid=$true;Reason='';Computer=$target;Action='Restart';Name=$name;DisplayName=$display;Risk='Danger';ConfirmText='Redémarrer le service'
                Title=('Redémarrer « ' + $display + ' » sur ' + $target + ' ?')
                Summary=('Arrête puis redémarre le service ' + $name + '. Ce quʼil sert est interrompu pendant lʼopération ; un service dont dʼautres dépendent est refusé par Windows, sans rien arrêter.')
            }
        }
    }
    return (& $refuse 'Action de service inconnue.')
}

# ---------------------------------------------------------------- UX-19 operations to check
function Get-DomeniaPendingOperationsView {
    # The header pill exists only while a durable receipt waits for a check: never a « 0 opération ».
    param([int]$Pending=0)
    if ($Pending -le 0) { return [pscustomobject]@{Visible=$false;Text='';Help=''} }
    $text = '1 opération à vérifier'
    if ($Pending -gt 1) { $text = [string]$Pending + ' opérations à vérifier' }
    $help = 'Une écriture envoyée attend une vérification ou une revue : les nouvelles écritures restent bloquées. Ouvre la liste des reçus ; rien nʼest rejoué.'
    return [pscustomobject]@{Visible=$true;Text=$text;Help=$help}
}
