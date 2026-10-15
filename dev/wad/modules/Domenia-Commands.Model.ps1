# W13 (points 115, 117, 120): command palette, keyboard shortcuts and presentation undo of the result list.
# Pure rules: no WPF, no network, no disk. The interface gives the context (selection, connection, controls) and
# applies the decisions; nothing here starts an operation.

function Get-DomeniaKeyboardShortcuts {
    # The shortcuts registered on the main window (Register-DomeniaShortcuts), in the words shown to the operator.
    # Scope: Window = anywhere in the main window; List = while the result list has the focus.
    return @(
        [pscustomobject]@{Id='Palette';Key='K';Modifiers='Control';Text='Ctrl+K';Label='Ouvrir la palette de commandes';Scope='Window'}
        [pscustomobject]@{Id='Search';Key='F';Modifiers='Control';Text='Ctrl+F';Label='Aller à la recherche';Scope='Window'}
        [pscustomobject]@{Id='Dashboard';Key='D';Modifiers='Control';Text='Ctrl+D';Label='Ouvrir lʼaccueil';Scope='Window'}
        [pscustomobject]@{Id='Journal';Key='L';Modifiers='Control';Text='Ctrl+L';Label='Ouvrir le journal de session';Scope='Window'}
        [pscustomobject]@{Id='Index';Key='I';Modifiers='Control';Text='Ctrl+I';Label='Ouvrir lʼindex local';Scope='Window'}
        [pscustomobject]@{Id='Theme';Key='T';Modifiers='Control';Text='Ctrl+T';Label='Changer de thème';Scope='Window'}
        [pscustomobject]@{Id='Summary';Key='C';Modifiers='Control+Shift';Text='Ctrl+Maj+C';Label='Copier le résumé de lʼobjet';Scope='Window'}
        [pscustomobject]@{Id='Tree';Key='F5';Modifiers='None';Text='F5';Label='Actualiser lʼarborescence';Scope='Window'}
        [pscustomobject]@{Id='Tools';Key='F1';Modifiers='None';Text='F1';Label='Ouvrir les outils et lʼaide';Scope='Window'}
        [pscustomobject]@{Id='Escape';Key='Escape';Modifiers='None';Text='Échap';Label='Fermer le panneau ouvert, ou effacer la saisie de la recherche';Scope='Window'}
        [pscustomobject]@{Id='Undo';Key='Z';Modifiers='Control';Text='Ctrl+Z';Label='Annuler la dernière présentation de la liste';Scope='List'}
    )
}

function Get-DomeniaCommandCatalogue {
    # Closed catalogue of the palette. Effect says what Entrée does:
    #   Navigate      opens a view, reads nothing;
    #   Local         acts on this workstation only (theme, copy, presentation);
    #   Read          starts a read or a probe: choosing it in the palette is the explicit gesture;
    #   Sensitive     protected read (secret): the palette only brings its button forward, the click stays the gesture;
    #   PrepareWrite  brings the button of a write forward: nothing is written without its own confirmation.
    # Requires: object type of the selection ('' any or none, Selection = any open object, MachineRows = rows of the list).
    # Target: the named control the command acts on or brings forward ('' for an action of the shell).
    $rows = @(
        @('search','Rechercher dans Active Directory','trouver nom compte poste','Navigation','Navigate','','',$false,'Search')
        @('dashboard','Ouvrir lʼaccueil','tableau de bord parc','Navigation','Navigate','','',$false,'Dashboard')
        @('operations','Afficher les opérations en cours','taches suivi lenteur sante','Navigation','Navigate','','',$false,'')
        @('journal','Ouvrir le journal de session','log erreurs historique','Navigation','Navigate','','',$false,'Journal')
        @('index','Ouvrir lʼindex local','base locale cache','Navigation','Navigate','','',$false,'Index')
        @('queries','Ouvrir lʼatelier de requêtes','requete filtre parc','Navigation','Navigate','','',$false,'')
        @('accounts','Ouvrir Comptes et accès','identite compte secondaire laps bitlocker','Navigation','Navigate','','',$false,'')
        @('relations','Ouvrir les relations utilisateur et poste','association lien poste utilisateur','Navigation','Navigate','','',$false,'')
        @('tools','Ouvrir les outils et lʼaide','aide parametres','Navigation','Navigate','','',$false,'Tools')
        @('shortcuts','Afficher les raccourcis clavier','clavier touches aide','Aide','Local','','',$false,'')
        @('theme','Changer de thème clair ou sombre','sombre clair couleurs','Présentation','Local','','',$false,'Theme')
        @('undo','Annuler la dernière présentation de la liste','colonnes tri filtre retour','Présentation','Local','','',$false,'Undo')
        @('summary','Copier le résumé de lʼobjet','presse-papiers fiche','Objet ouvert','Local','Selection','',$false,'Summary')
        @('parent','Ouvrir le conteneur parent','ou dossier parent','Objet ouvert','Navigate','Selection','',$true,'')
        @('diagnostic','Préparer le diagnostic expurgé','support export versions mesures','Application','Local','','',$false,'')
        @('selfcheck','Vérifier lʼapplication','auto-verification prerequis','Application','Read','','',$false,'')
        @('tree','Actualiser lʼarborescence','ou arbre recharger','Lecture','Read','','',$true,'Tree')
        @('batch','Diagnostic réseau des postes sélectionnés','ping ports smb winrm','Lecture','Read','MachineRows','',$true,'')
        @('ping','Pinger ce poste','reseau joignable','Lecture','Read','Machine','BtnCompPing',$true,'')
        @('sessions','Lire les sessions du poste','utilisateur connecte rdp','Lecture','Read','Machine','BtnSessionsRead',$true,'')
        @('computerdiag','Lancer le diagnostic du poste','sante disque services','Lecture','Read','Machine','BtnRunComputerDiag',$true,'')
        @('inventory','Lancer lʼinventaire rapide du poste','materiel wmi','Lecture','Read','Machine','BtnRunInventory',$true,'')
        @('software','Charger les logiciels du poste','applications installees','Lecture','Read','Machine','BtnLoadSoftware',$true,'')
        @('lastuser','Détecter lʼutilisateur du poste','session utilisateur','Lecture','Read','Machine','BtnRefreshMachineLink',$true,'')
        @('lockouts','Lire les verrouillages du compte (4740)','verrouillage evenement securite','Lecture','Read','Utilisateur','BtnUserSupportLockouts',$true,'')
        @('permissions','Analyser les permissions de lʼobjet','acl droits securite','Lecture','Read','Selection','BtnPermissionRefresh',$true,'')
        @('laps','Lire le mot de passe LAPS','administrateur local secret','Lecture protégée','Sensitive','Machine','BtnLoadLaps',$true,'')
        @('bitlocker','Lire les clés BitLocker','recuperation secret','Lecture protégée','Sensitive','Machine','BtnLoadBitLocker',$true,'')
        @('useredit','Modifier la fiche de lʼutilisateur','editer champs','Écriture préparée','PrepareWrite','Utilisateur','BtnUserEdit',$true,'')
        @('unlock','Déverrouiller le compte','verrouille debloquer','Écriture préparée','PrepareWrite','Utilisateur','BtnUserUnlock',$true,'')
        @('resetpassword','Réinitialiser le mot de passe','mot de passe changer','Écriture préparée','PrepareWrite','Utilisateur','BtnUserResetPwd',$true,'')
        @('userenable','Activer le compte','activer utilisateur','Écriture préparée','PrepareWrite','Utilisateur','BtnUserEnable',$true,'')
        @('userdisable','Désactiver le compte','desactiver utilisateur','Écriture préparée','PrepareWrite','Utilisateur','BtnUserDisable',$true,'')
        @('usermove','Déplacer lʼutilisateur','ou deplacer','Écriture préparée','PrepareWrite','Utilisateur','BtnUserMove',$true,'')
        @('useraddgroup','Ajouter lʼutilisateur à un groupe','groupe membre','Écriture préparée','PrepareWrite','Utilisateur','BtnUserAddGroup',$true,'')
        @('groupadd','Ajouter un membre au groupe','groupe membre','Écriture préparée','PrepareWrite','Groupe','BtnGroupAddMember',$true,'')
        @('groupremove','Retirer un membre du groupe','groupe membre','Écriture préparée','PrepareWrite','Groupe','BtnGroupRemoveMember',$true,'')
        @('computeredit','Modifier la fiche du poste','description emplacement','Écriture préparée','PrepareWrite','Machine','BtnCompEdit',$true,'')
        @('computerenable','Activer le poste','activer ordinateur','Écriture préparée','PrepareWrite','Machine','BtnCompEnable',$true,'')
        @('computerdisable','Désactiver le poste','desactiver ordinateur','Écriture préparée','PrepareWrite','Machine','BtnCompDisable',$true,'')
        @('gpupdate','Actualiser les stratégies du poste','gpupdate gpo','Écriture préparée','PrepareWrite','Machine','BtnCompGpUpdate',$true,'')
        @('restart','Redémarrer le poste','redemarrage reboot','Écriture préparée','PrepareWrite','Machine','BtnCompRestart',$true,'')
    )
    $order = 0
    foreach ($row in $rows) {
        $order++
        [pscustomobject]@{Id=[string]$row[0];Label=[string]$row[1];Keywords=[string]$row[2];Group=[string]$row[3];Effect=[string]$row[4];Requires=[string]$row[5];Target=[string]$row[6];NeedsConnection=[bool]$row[7];Shortcut=[string]$row[8];Order=$order}
    }
}

function Get-DomeniaShortcutListText {
    # Every shortcut, one per line, for the palette (discoverable without the documentation).
    $lines = foreach ($shortcut in @(Get-DomeniaKeyboardShortcuts)) {
        $where = ''
        if ([string]$shortcut.Scope -ceq 'List') { $where = ' (dans la liste de résultats)' }
        [string]$shortcut.Text + ' : ' + [string]$shortcut.Label + $where
    }
    return (@($lines) -join "`r`n")
}

function Get-DomeniaCommandEffectText {
    # What Entrée does, in the words of the palette.
    param([AllowEmptyString()][string]$Effect='')
    switch ($Effect) {
        'Navigate' { return 'Ouvre la vue ; rien nʼest lu.' }
        'Local' { return 'Action locale à ce poste ; rien nʼest envoyé.' }
        'Read' { return 'Lecture lancée par Entrée ; aucune écriture.' }
        'Sensitive' { return 'Amène le bouton à lʼécran : la lecture protégée part seulement après votre clic.' }
        'PrepareWrite' { return 'Amène le bouton à lʼécran : rien nʼest écrit sans sa propre confirmation.' }
    }
    return ''
}

function ConvertTo-DomeniaCommandSearchKey {
    # Case, accents and apostrophes folded: « detecter » finds « Détecter », « lindex » finds « lʼindex ».
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $folded = ([string]$Text).ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $folded = [regex]::Replace($folded,'\p{Mn}','')
    $apostrophes = '[' + [string][char]0x27 + [string][char]0x2BC + [string][char]0x2019 + ']'
    $folded = [regex]::Replace($folded,$apostrophes,'')
    return ([regex]::Replace($folded,'[^a-z0-9]+',' ')).Trim()
}

function Get-DomeniaPaletteEntries {
    # Each command of the catalogue judged against the context: available or not, and why. A command whose button is
    # disabled keeps the reason the button gives (its tool tip, shown on a disabled control, D088).
    # $Context: {Connected, SelectionType, MachineRows, ReadOnly, Demo, UndoAvailable, UndoText, Controls}
    # Controls: name -> {Reachable, Enabled, ToolTip} for the targets that exist in the page.
    param($Context=$null)
    $connected = [bool](Get-DomeniaMember $Context 'Connected' $false)
    $type = [string](Get-DomeniaMember $Context 'SelectionType' '')
    $machineRows = [int](Get-DomeniaMember $Context 'MachineRows' 0)
    $readOnly = [bool](Get-DomeniaMember $Context 'ReadOnly' $true)
    $demo = [bool](Get-DomeniaMember $Context 'Demo' $false)
    $undo = [bool](Get-DomeniaMember $Context 'UndoAvailable' $false)
    $undoText = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $Context 'UndoText' '')) 60
    $controls = Get-DomeniaMemberValue $Context 'Controls' $null
    $shortcuts = @{}
    foreach ($shortcut in @(Get-DomeniaKeyboardShortcuts)) { $shortcuts[[string]$shortcut.Id] = [string]$shortcut.Text }
    $typeLabels = @{Utilisateur='un utilisateur';Machine='un poste';Groupe='un groupe'}
    foreach ($command in @(Get-DomeniaCommandCatalogue)) {
        $available = $true; $reason = ''
        $label = [string]$command.Label
        if (($command.Id -ceq 'undo') -and $undoText) { $label = 'Annuler la dernière présentation de la liste (' + $undoText + ')' }
        if ($command.NeedsConnection -and (-not $connected)) { $available = $false; $reason = 'Connexion à lʼannuaire requise.' }
        elseif (($command.Requires -ceq 'Selection') -and (-not $type)) { $available = $false; $reason = 'Ouvrez dʼabord une fiche.' }
        elseif (($command.Requires -ceq 'MachineRows') -and ($machineRows -lt 1)) { $available = $false; $reason = 'Sélectionnez au moins un poste dans la liste.' }
        elseif ($typeLabels.ContainsKey([string]$command.Requires) -and ($type -cne [string]$command.Requires)) { $available = $false; $reason = 'Sélectionnez ' + [string]$typeLabels[[string]$command.Requires] + '.' }
        elseif (($command.Effect -ceq 'PrepareWrite') -and $demo) { $available = $false; $reason = 'Écritures désactivées en démonstration.' }
        elseif (($command.Effect -ceq 'PrepareWrite') -and $readOnly) { $available = $false; $reason = 'Lecture seule : passez en mode écriture pour préparer cette action.' }
        elseif (($command.Id -ceq 'undo') -and (-not $undo)) { $available = $false; $reason = 'Aucune présentation de la liste à annuler.' }
        elseif ([string]$command.Target) {
            $control = $null
            if ($null -ne $controls) { $control = Get-DomeniaMemberValue $controls ([string]$command.Target) $null }
            if ($null -eq $control) { $available = $false; $reason = 'Action absente de cette page.' }
            elseif (-not [bool](Get-DomeniaMember $control 'Reachable' $false)) { $available = $false; $reason = 'Action non affichée pour cette fiche ou ce profil.' }
            elseif (-not [bool](Get-DomeniaMember $control 'Enabled' $false)) {
                $available = $false
                $reason = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $control 'ToolTip' '')) 160
                if (-not $reason) { $reason = 'Action indisponible pour lʼinstant.' }
            }
        }
        $shortcutText = ''
        if ([string]$command.Shortcut -and $shortcuts.ContainsKey([string]$command.Shortcut)) { $shortcutText = [string]$shortcuts[[string]$command.Shortcut] }
        $effectText = Get-DomeniaCommandEffectText ([string]$command.Effect)
        $detail = $effectText
        if ($command.Id -ceq 'shortcuts') { $detail = Get-DomeniaShortcutListText }
        if (-not $available) { $detail = 'Indisponible : ' + $reason }
        [pscustomobject]@{
            Id=[string]$command.Id;Label=$label;Group=[string]$command.Group;Effect=[string]$command.Effect;Target=[string]$command.Target
            Available=$available;Reason=$reason;EffectText=$effectText;Shortcut=$shortcutText;Detail=$detail;Order=[int]$command.Order
            SearchKey=(ConvertTo-DomeniaCommandSearchKey ($label + ' ' + [string]$command.Keywords + ' ' + [string]$command.Group))
            LabelKey=(ConvertTo-DomeniaCommandSearchKey $label)
        }
    }
}

function Select-DomeniaPaletteEntries {
    # Typed words filter the entries (every word must appear, accents and case ignored); available commands first, then
    # a label that starts with the text, then a word of the label that starts with it, then the catalogue order.
    param([object[]]$Entries=@(),[AllowEmptyString()][string]$Query='',[ValidateRange(1,200)][int]$Maximum=40)
    $key = ConvertTo-DomeniaCommandSearchKey $Query
    $terms = @($key -split ' ' | Where-Object { $_ })
    $scored = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $haystack = ' ' + [string]$entry.SearchKey + ' '
        $match = $true
        foreach ($term in $terms) { if ($haystack.IndexOf($term,[StringComparison]::Ordinal) -lt 0) { $match = $false; break } }
        if (-not $match) { continue }
        $rank = 3
        if ($terms.Count -eq 0) { $rank = 0 }
        elseif (([string]$entry.LabelKey).StartsWith($key,[StringComparison]::Ordinal)) { $rank = 0 }
        elseif ((' ' + [string]$entry.LabelKey).IndexOf(' ' + $terms[0],[StringComparison]::Ordinal) -ge 0) { $rank = 1 }
        elseif ((' ' + [string]$entry.SearchKey).IndexOf(' ' + $terms[0],[StringComparison]::Ordinal) -ge 0) { $rank = 2 }
        $availability = 1
        if ([bool]$entry.Available) { $availability = 0 }
        $scored.Add([pscustomobject]@{Entry=$entry;Availability=$availability;Rank=$rank;Order=[int]$entry.Order})
    }
    $sorted = @($scored.ToArray() | Sort-Object -Property @{Expression={[int]$_.Availability}},@{Expression={[int]$_.Rank}},@{Expression={[int]$_.Order}} | Select-Object -First $Maximum)
    foreach ($item in $sorted) { $item.Entry }
}

function Get-DomeniaPaletteDecision {
    # What the interface does when an entry is chosen. Never a write: a PrepareWrite or Sensitive entry only brings its
    # button forward (Focus), and only a Read entry of an enabled button is clicked by the palette.
    param($Entry=$null)
    if (($null -eq $Entry) -or (-not [bool](Get-DomeniaMember $Entry 'Available' $false))) {
        return [pscustomobject]@{Action='None';Target='';Status=([string](Get-DomeniaMember $Entry 'Detail' 'Choisissez une action disponible.'))}
    }
    $target = [string](Get-DomeniaMember $Entry 'Target' '')
    $label = [string](Get-DomeniaMember $Entry 'Label' '')
    switch ([string](Get-DomeniaMember $Entry 'Effect' '')) {
        'PrepareWrite' { return [pscustomobject]@{Action='Focus';Target=$target;Status=($label + ' : bouton prêt. Entrée ou un clic ouvre sa confirmation ; rien nʼest encore écrit.')} }
        'Sensitive' { return [pscustomobject]@{Action='Focus';Target=$target;Status=($label + ' : bouton prêt. La lecture protégée part seulement après votre clic.')} }
        'Read' {
            if ($target) { return [pscustomobject]@{Action='Click';Target=$target;Status=($label + ' : lecture demandée.')} }
            return [pscustomobject]@{Action='Run';Target='';Status=($label + ' : lecture demandée.')}
        }
    }
    return [pscustomobject]@{Action='Run';Target=$target;Status=''}
}

# ---------------------------------------------------------------- point 120: presentation undo of the result list
function ConvertTo-DomeniaPresentationKey {
    # Canonical text of a presentation (columns, sort, local filter, presence filter) to compare two of them.
    param($State=$null)
    if ($null -eq $State) { return '' }
    $columns = @(@(Get-DomeniaMember $State 'Columns' @()) | Where-Object { $null -ne $_ } | ForEach-Object {
        [string](Get-DomeniaMember $_ 'Key' '') + '@' + [string](Get-DomeniaMember $_ 'Index' '') + ':' + [string](Get-DomeniaMember $_ 'Width' '') + [string](Get-DomeniaMember $_ 'Unit' '')
    })
    $sort = @(@(Get-DomeniaMember $State 'Sort' @()) | Where-Object { $null -ne $_ } | ForEach-Object {
        [string](Get-DomeniaMember $_ 'Field' '') + ' ' + [string](Get-DomeniaMember $_ 'Direction' '')
    })
    return ('C=' + ($columns -join ';') + '|S=' + ($sort -join ';') + '|F=' + [string](Get-DomeniaMember $State 'LocalFilter' '') + '|P=' + [string](Get-DomeniaMember $State 'Presence' ''))
}

function Get-DomeniaPresentationChangeText {
    # What differs between two presentations, in the words of the undo button: colonnes, tri, filtre de la liste, présence.
    param($Before=$null,$After=$null)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $beforeKey = ConvertTo-DomeniaPresentationKey $Before
    $afterKey = ConvertTo-DomeniaPresentationKey $After
    if ($beforeKey -ceq $afterKey) { return '' }
    $b = $beforeKey.Split([char]'|'); $a = $afterKey.Split([char]'|')
    if (($b.Count -eq 4) -and ($a.Count -eq 4)) {
        if ($b[0] -cne $a[0]) { $parts.Add('colonnes') }
        if ($b[1] -cne $a[1]) { $parts.Add('tri') }
        if ($b[2] -cne $a[2]) { $parts.Add('filtre de la liste') }
        if ($b[3] -cne $a[3]) { $parts.Add('filtre de présence') }
    }
    if ($parts.Count -eq 0) { $parts.Add('présentation') }
    return ($parts.ToArray() -join ', ')
}

function New-DomeniaPresentationHistory {
    # Ten steps at most, like the layout of the boards (FI-11). The history is about presentation only: it never
    # undoes a read, a write or any operation on the directory.
    param([ValidateRange(1,50)][int]$Maximum=10)
    return [pscustomobject]@{Current=$null;CurrentKey='';Undo=(New-Object 'System.Collections.Generic.List[object]');Maximum=$Maximum}
}

function Add-DomeniaPresentationState {
    # Records the presentation now shown. The first state is the starting point; a change pushes the previous state
    # with the words of what changed. Returns $true when a step was recorded.
    param([Parameter(Mandatory=$true)]$History,$State=$null)
    if ($null -eq $State) { return $false }
    $key = ConvertTo-DomeniaPresentationKey $State
    if ($null -eq $History.Current) { $History.Current = $State; $History.CurrentKey = $key; return $false }
    if ($key -ceq [string]$History.CurrentKey) { return $false }
    $History.Undo.Add([pscustomobject]@{State=$History.Current;Text=(Get-DomeniaPresentationChangeText -Before $History.Current -After $State)})
    while ($History.Undo.Count -gt [int]$History.Maximum) { $History.Undo.RemoveAt(0) }
    $History.Current = $State; $History.CurrentKey = $key
    return $true
}

function Get-DomeniaPresentationUndoText {
    # Words of the next undo (what it gives back), '' when nothing can be undone.
    param($History=$null)
    if (($null -eq $History) -or ($History.Undo.Count -eq 0)) { return '' }
    return [string]$History.Undo[$History.Undo.Count - 1].Text
}

function Reset-DomeniaPresentationCurrent {
    # A new list (new search) becomes the reference without a step: the earlier steps stay undoable.
    param([Parameter(Mandatory=$true)]$History,$State=$null)
    if ($null -eq $State) { return }
    $History.Current = $State
    $History.CurrentKey = ConvertTo-DomeniaPresentationKey $State
}

function Undo-DomeniaPresentationState {
    # Takes the last step: returns the presentation to apply and what it gives back; $null when there is none.
    param([Parameter(Mandatory=$true)]$History)
    if ($History.Undo.Count -eq 0) { return $null }
    $step = $History.Undo[$History.Undo.Count - 1]
    $History.Undo.RemoveAt($History.Undo.Count - 1)
    $History.Current = $step.State
    $History.CurrentKey = ConvertTo-DomeniaPresentationKey $step.State
    return [pscustomobject]@{State=$step.State;Text=[string]$step.Text;Remaining=$History.Undo.Count}
}
