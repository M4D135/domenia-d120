# Support recipes (point 110 of the roadmap of 13 October 2026): guided paths for a failed logon, a slow workstation,
# a full disk or a missing software. Each step names the existing explicit read it uses, what that read collects,
# why it is useful and what it costs. No step chains to the next one, none writes, and a step only runs for the kind
# of object it concerns. Pure data and decisions: no WPF, no network, no disk and no clock read.
# Relies on Domenia-Common.Model.ps1 and, for the validation, Domenia-Safety.Model.ps1 (Get-DomeniaOperationEffect).

function Get-DomeniaAssistanceActions {
    # The only functions a recipe may start: existing explicit reads of the application, each bound to its pinned
    # operation. A recipe naming anything else is refused by Test-DomeniaAssistanceRecipes.
    return [ordered]@{
        'Start-DomeniaLockoutEventRead'='LockoutDiagnosis'
        'Start-DomeniaAdAuditPolicyRead'='PasswordPolicyRead'
        'Start-DomeniaAdAuditGroupRead'='GroupPathRead'
        'Start-DomeniaAdAuditGpoLinks'='GpoLinksRead'
        'Start-DomeniaAdAuditGpoApplied'='GpoAppliedRead'
        'Start-DomeniaAdAuditMachineIdentity'='MachineIdentityRead'
        'Start-ComputerDiagnostics'='ComputerDiagnostics'
        'Start-DomeniaComputerInventory'='ComputerInventory'
        'Start-DomeniaSoftwareInventory'='SoftwareInventory'
        'Start-DomeniaSessionsRead'='SessionsList'
    }
}

function New-DomeniaAssistanceStep {
    param(
        [Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][ValidateSet('Utilisateur','Machine')][string]$Subject,
        [AllowEmptyString()][string]$Action='',[hashtable]$Arguments=@{},
        [AllowEmptyString()][string]$Workspace='',[AllowEmptyString()][string]$Inner='',[AllowEmptyString()][string]$Tab='',[AllowEmptyString()][string]$AuditTab='',
        [Parameter(Mandatory=$true)][string]$Reads,[Parameter(Mandatory=$true)][string]$Why,[Parameter(Mandatory=$true)][string]$Cost,
        [bool]$Optional=$false,[bool]$Privileged=$false
    )
    $operation = ''
    $actions = Get-DomeniaAssistanceActions
    if ($Action -and $actions.Contains($Action)) { $operation = [string]$actions[$Action] }
    return [pscustomobject]@{
        Id=$Id;Title=$Title;Subject=$Subject;Action=$Action;Arguments=$Arguments;OperationId=$operation
        Workspace=$Workspace;Inner=$Inner;Tab=$Tab;AuditTab=$AuditTab;Reads=$Reads;Why=$Why;Cost=$Cost;Optional=$Optional;Privileged=$Privileged
    }
}

function Get-DomeniaAssistanceRecipes {
    # Four recipes. A step without action opens the view where the information already read is shown.
    $user = @{Workspace='WsObject';Inner='DetailTabs';Tab='TabUser'}
    $audit = @{Workspace='TabApplicationTools';Inner='ApplicationToolTabs';Tab='WsAdAudit'}
    $health = @{Workspace='WsComputer';Inner='ComputerTabs';Tab='TabComputerHealth'}
    $inventory = @{Workspace='WsComputer';Inner='ComputerTabs';Tab='TabInventory'}
    $software = @{Workspace='WsComputer';Inner='ComputerTabs';Tab='TabSoftware'}
    $sessions = @{Workspace='WsComputer';Inner='ComputerTabs';Tab='TabSessions'}
    $reachReads = 'Réponse au ping et ouverture des ports dʼadministration du poste.'
    $reachCost = 'Lecture réseau du poste, quelques secondes.'
    return @(
        [pscustomobject]@{
            Id='logon';Title='Connexion impossible';Symptom='Lʼutilisateur ne peut pas ouvrir de session : mot de passe refusé, compte bloqué ou poste qui nʼauthentifie plus.'
            Steps=@(
                (New-DomeniaAssistanceStep -Id 'account' -Title 'État du compte' -Subject Utilisateur @user -Reads 'Rien de nouveau : état du compte, verrouillage, échéance du mot de passe et échecs, déjà lus à lʼouverture de la fiche.' -Why 'Un compte désactivé, expiré ou verrouillé, ou un mot de passe échu, empêche toute ouverture de session.' -Cost 'Aucune lecture.')
                (New-DomeniaAssistanceStep -Id 'lockouts' -Title 'Verrouillages des 7 derniers jours' -Subject Utilisateur -Action 'Start-DomeniaLockoutEventRead' @user -Reads 'Journal Sécurité de lʼémulateur PDC : événements 4740 de ce seul compte, 7 jours, 200 au plus.' -Why 'Trouver le poste qui verrouille le compte : session, lecteur réseau ou service gardant un ancien mot de passe.' -Cost 'Une lecture du journal du contrôleur ; droit de lecture du journal Sécurité requis.')
                (New-DomeniaAssistanceStep -Id 'policy' -Title 'Stratégie de mot de passe applicable' -Subject Utilisateur -Action 'Start-DomeniaAdAuditPolicyRead' @audit -AuditTab 'TabAdAuditPolicy' -Reads 'Stratégie fine applicable (msDS-ResultantPSO), stratégie du domaine et échéance calculée par le contrôleur ; aucun mot de passe.' -Why 'Comprendre une expiration ou un seuil de verrouillage propres à ce compte.' -Cost 'Trois à cinq lectures LDAP bornées.' -Optional $true)
                (New-DomeniaAssistanceStep -Id 'reach' -Title 'Poste joignable' -Subject Machine -Action 'Start-ComputerDiagnostics' @health -Reads $reachReads -Why 'Un poste hors réseau ne joint pas le contrôleur et refuse les nouveaux mots de passe.' -Cost $reachCost)
                (New-DomeniaAssistanceStep -Id 'identity' -Title 'Identité du poste' -Subject Machine -Action 'Start-DomeniaAdAuditMachineIdentity' @audit -AuditTab 'TabAdAuditMachine' -Reads 'Résolution DNS du nom du poste depuis ce poste et nom renvoyé par le poste (CIM).' -Why 'Un enregistrement DNS périmé ou un poste renommé casse la relation avec le domaine.' -Cost 'Une résolution DNS et une lecture CIM ; droits dʼadministration du poste.' -Privileged $true)
                (New-DomeniaAssistanceStep -Id 'clock' -Title 'Heure et démarrage du poste' -Subject Machine -Action 'Start-DomeniaComputerInventory' @inventory -Reads 'Inventaire rapide : système, dernier démarrage et écart dʼhorloge avec le contrôleur.' -Why 'Au-delà de 5 minutes dʼécart, Kerberos refuse lʼouverture de session.' -Cost 'Lecture CIM du poste, 10 à 60 secondes ; droits dʼadministration du poste.' -Privileged $true)
            )
        }
        [pscustomobject]@{
            Id='slow';Title='Poste lent';Symptom='Le poste répond lentement, à lʼouverture de session ou en continu.'
            Steps=@(
                (New-DomeniaAssistanceStep -Id 'reach' -Title 'Réseau du poste' -Subject Machine -Action 'Start-ComputerDiagnostics' @health -Reads $reachReads -Why 'Une latence réseau ou des ports filtrés ralentissent lʼouverture de session et les partages.' -Cost $reachCost)
                (New-DomeniaAssistanceStep -Id 'inventory' -Title 'Mémoire, disques et démarrage' -Subject Machine -Action 'Start-DomeniaComputerInventory' @inventory -Reads 'Inventaire rapide : mémoire, processeur, disques et durée depuis le dernier démarrage.' -Why 'Peu de mémoire libre, un disque plein ou des semaines sans redémarrage expliquent souvent la lenteur.' -Cost 'Lecture CIM du poste, 10 à 60 secondes ; droits dʼadministration du poste.' -Privileged $true)
                (New-DomeniaAssistanceStep -Id 'sessions' -Title 'Sessions ouvertes' -Subject Machine -Action 'Start-DomeniaSessionsRead' @sessions -Reads 'Sessions console et RDP du poste, sans fermeture.' -Why 'Plusieurs sessions ou une session déconnectée occupent la mémoire.' -Cost 'Une lecture des sessions du poste.' -Optional $true)
                (New-DomeniaAssistanceStep -Id 'deep' -Title 'Inventaire complet' -Subject Machine -Action 'Start-DomeniaComputerInventory' -Arguments @{Deep=$true} @inventory -Reads 'Inventaire complet : lectures supplémentaires du poste.' -Why 'Approfondir seulement si lʼinventaire rapide nʼexplique pas la lenteur.' -Cost 'Plus long que lʼinventaire rapide ; droits dʼadministration du poste.' -Optional $true -Privileged $true)
            )
        }
        [pscustomobject]@{
            Id='disk';Title='Manque dʼespace';Symptom='Le poste signale un disque plein ou une application refuse dʼenregistrer.'
            Steps=@(
                (New-DomeniaAssistanceStep -Id 'inventory' -Title 'Espace des disques' -Subject Machine -Action 'Start-DomeniaComputerInventory' @inventory -Reads 'Inventaire rapide : disques logiques, taille et espace libre.' -Why 'Mesurer lʼespace restant et le disque concerné avant toute action.' -Cost 'Lecture CIM du poste, 10 à 60 secondes ; droits dʼadministration du poste.' -Privileged $true)
                (New-DomeniaAssistanceStep -Id 'sessions' -Title 'Sessions et profils ouverts' -Subject Machine -Action 'Start-DomeniaSessionsRead' @sessions -Reads 'Sessions console et RDP du poste, sans fermeture.' -Why 'Des sessions inactives gardent des profils et des fichiers temporaires.' -Cost 'Une lecture des sessions du poste.' -Optional $true)
                (New-DomeniaAssistanceStep -Id 'software' -Title 'Logiciels installés' -Subject Machine -Action 'Start-DomeniaSoftwareInventory' @software -Reads 'Logiciels installés lus dans le registre, sans effet de bord MSI.' -Why 'Repérer un logiciel volumineux ou inattendu.' -Cost 'Lecture du registre du poste ; droits dʼadministration du poste.' -Optional $true -Privileged $true)
            )
        }
        [pscustomobject]@{
            Id='software';Title='Logiciel absent';Symptom='Un logiciel attendu nʼest pas installé, ou pas dans la bonne version.'
            Steps=@(
                (New-DomeniaAssistanceStep -Id 'software' -Title 'Logiciels installés' -Subject Machine -Action 'Start-DomeniaSoftwareInventory' @software -Reads 'Logiciels installés lus dans le registre : nom, éditeur et version, sans effet de bord MSI.' -Why 'Vérifier si le logiciel est présent, et dans quelle version.' -Cost 'Lecture du registre du poste ; droits dʼadministration du poste.' -Privileged $true)
                (New-DomeniaAssistanceStep -Id 'groups' -Title 'Groupes du poste' -Subject Machine -Action 'Start-DomeniaAdAuditGroupRead' @audit -AuditTab 'TabAdAuditGroups' -Reads 'Groupes du poste, directs et imbriqués, bornés à 2 000.' -Why 'Un logiciel distribué par groupe nʼarrive que si le poste en est membre.' -Cost 'Lectures LDAP bornées, 10 secondes au plus.')
                (New-DomeniaAssistanceStep -Id 'gpo' -Title 'Liens GPO du poste' -Subject Machine -Action 'Start-DomeniaAdAuditGpoLinks' @audit -AuditTab 'TabAdAuditGpo' -Reads 'Liens GPO des OU au-dessus du poste et du domaine.' -Why 'Un déploiement par stratégie de groupe dépend des liens et de lʼhéritage.' -Cost 'Une lecture LDAP par niveau dʼOU.')
                (New-DomeniaAssistanceStep -Id 'gpo-applied' -Title 'Stratégies appliquées sur le poste' -Subject Machine -Action 'Start-DomeniaAdAuditGpoApplied' @audit -AuditTab 'TabAdAuditGpo' -Reads 'Dernier résultat des stratégies enregistré par le poste (RSoP), sans actualisation.' -Why 'Vérifier que la stratégie de déploiement a réellement été appliquée.' -Cost 'Lecture CIM du poste ; droits dʼadministration du poste.' -Optional $true -Privileged $true)
                (New-DomeniaAssistanceStep -Id 'groups-user' -Title 'Groupes de lʼutilisateur' -Subject Utilisateur -Action 'Start-DomeniaAdAuditGroupRead' @audit -AuditTab 'TabAdAuditGroups' -Reads 'Groupes du compte, directs et imbriqués, bornés à 2 000.' -Why 'Un logiciel distribué à des utilisateurs dépend de leurs groupes.' -Cost 'Lectures LDAP bornées, 10 secondes au plus.' -Optional $true)
            )
        }
    )
}

function Get-DomeniaAssistanceRecipe {
    param([AllowEmptyString()][string]$Id)
    foreach ($recipe in @(Get-DomeniaAssistanceRecipes)) { if ([string]$recipe.Id -ceq $Id) { return $recipe } }
    return $null
}

function Test-DomeniaAssistanceRecipes {
    # Contract of the recipes: unique identifiers, every step explained (what, why, cost), every action allowed and
    # bound to a read operation. Writes the problems found; none means the recipes may be offered.
    param([object[]]$Recipes=@())
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $actions = Get-DomeniaAssistanceActions
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($recipe in @($Recipes)) {
        if ($null -eq $recipe) { continue }
        $recipeId = [string](Get-DomeniaMember $recipe 'Id' '')
        if ((-not $recipeId) -or (-not $ids.Add($recipeId))) { $problems.Add('Recette sans identifiant unique : ' + $recipeId) }
        if (-not [string](Get-DomeniaMember $recipe 'Symptom' '')) { $problems.Add($recipeId + ' : symptôme absent') }
        $stepIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $steps = @(Get-DomeniaMember $recipe 'Steps' @())
        if ($steps.Count -eq 0) { $problems.Add($recipeId + ' : aucune étape') }
        foreach ($step in $steps) {
            $stepId = [string](Get-DomeniaMember $step 'Id' '')
            if ((-not $stepId) -or (-not $stepIds.Add($stepId))) { $problems.Add($recipeId + ' : étape sans identifiant unique ' + $stepId) }
            foreach ($field in @('Title','Reads','Why','Cost')) { if (-not [string](Get-DomeniaMember $step $field '')) { $problems.Add($recipeId + '/' + $stepId + ' : ' + $field + ' absent') } }
            $action = [string](Get-DomeniaMember $step 'Action' '')
            $operation = [string](Get-DomeniaMember $step 'OperationId' '')
            if ($action) {
                if (-not $actions.Contains($action)) { $problems.Add($recipeId + '/' + $stepId + ' : action non autorisée ' + $action) }
                elseif ([string]$actions[$action] -cne $operation) { $problems.Add($recipeId + '/' + $stepId + ' : opération incohérente') }
                if ((Get-DomeniaOperationEffect $operation) -ne 'Read') { $problems.Add($recipeId + '/' + $stepId + ' : ' + $operation + ' nʼest pas une lecture') }
            }
            elseif (-not [string](Get-DomeniaMember $step 'Workspace' '')) { $problems.Add($recipeId + '/' + $stepId + ' : ni lecture ni vue à ouvrir') }
        }
    }
    # Written one by one: the caller counts them with @().
    foreach ($problem in $problems) { $problem }
}

function Get-DomeniaAssistanceSubjectLabel {
    param([AllowEmptyString()][string]$Subject)
    if ($Subject -eq 'Machine') { return 'Poste' }
    if ($Subject -eq 'Utilisateur') { return 'Utilisateur' }
    return $Subject
}

function Get-DomeniaAssistanceStepState {
    # Whether one step can run for the current selection, and the state shown on its row. A launched step says when
    # it was started, never that it succeeded: its result is read in the view it opens.
    param($Step,[AllowEmptyString()][string]$SelectionType='',$LaunchedUtc=$null)
    $subject = [string](Get-DomeniaMember $Step 'Subject' '')
    $hasAction = [bool][string](Get-DomeniaMember $Step 'Action' '')
    if ($SelectionType -cne $subject) {
        $need = 'Sélectionnez le poste concerné.'
        if ($subject -eq 'Utilisateur') { $need = 'Sélectionnez le compte concerné.' }
        return [pscustomobject]@{CanRun=$false;CanOpen=$false;Text=$need}
    }
    if (-not $hasAction) { return [pscustomobject]@{CanRun=$false;CanOpen=$true;Text='Sans lecture : ouvrir la vue'} }
    $when = ConvertTo-DomeniaUtcDate $LaunchedUtc
    if ($null -ne $when) { return [pscustomobject]@{CanRun=$true;CanOpen=$true;Text=('Lancée à ' + $when.ToLocalTime().ToString('HH:mm') + ' : résultat dans sa vue')} }
    return [pscustomobject]@{CanRun=$true;CanOpen=$true;Text='À lancer'}
}

function ConvertTo-DomeniaAssistanceStepRows {
    # Grid rows of one recipe for the current selection. $Launched: map step id -> UTC time of its last launch.
    param($Recipe,[AllowEmptyString()][string]$SelectionType='',[Collections.IDictionary]$Launched=$null)
    $order = 0
    foreach ($step in @(Get-DomeniaMember $Recipe 'Steps' @())) {
        if ($null -eq $step) { continue }
        $order++
        $launchedAt = $null
        if (($null -ne $Launched) -and $Launched.Contains([string]$step.Id)) { $launchedAt = $Launched[[string]$step.Id] }
        $state = Get-DomeniaAssistanceStepState -Step $step -SelectionType $SelectionType -LaunchedUtc $launchedAt
        $title = [string]$step.Title
        if ([bool]$step.Optional) { $title += ' (facultatif)' }
        [pscustomobject]@{
            Order=$order;Id=[string]$step.Id;Title=$title;Pour=(Get-DomeniaAssistanceSubjectLabel ([string]$step.Subject));Reads=[string]$step.Reads;Why=[string]$step.Why
            Cost=[string]$step.Cost;State=[string]$state.Text;CanRun=[bool]$state.CanRun;CanOpen=[bool]$state.CanOpen;Step=$step
        }
    }
}

function Get-DomeniaAssistancePlanText {
    # What the whole recipe would collect if every step were launched, said before the first click.
    param($Recipe)
    $steps = @(Get-DomeniaMember $Recipe 'Steps' @())
    $reads = @($steps | Where-Object { [string]$_.Action })
    $none = $steps.Count - $reads.Count
    $machine = @($reads | Where-Object { [string]$_.Subject -eq 'Machine' }).Count
    $user = @($reads | Where-Object { [string]$_.Subject -eq 'Utilisateur' }).Count
    $privileged = @($reads | Where-Object { [bool]$_.Privileged }).Count
    $optional = @($steps | Where-Object { [bool]$_.Optional }).Count
    $text = [string]$steps.Count + ' étape(s) : ' + [string]$user + ' lecture(s) pour le compte, ' + [string]$machine + ' pour le poste'
    if ($none -gt 0) { $text += ', ' + [string]$none + ' sans lecture' }
    $text += '.'
    if ($privileged -gt 0) { $text += ' ' + [string]$privileged + ' demande(nt) les droits dʼadministration du poste.' }
    if ($optional -gt 0) { $text += ' ' + [string]$optional + ' facultative(s).' }
    $text += ' Aucune étape ne part seule ; aucune nʼécrit.'
    return $text
}
