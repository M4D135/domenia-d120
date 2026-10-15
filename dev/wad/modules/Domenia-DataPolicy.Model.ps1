# Local data policy of Domenia (point 147). Pure rules: no WPF, no network, no disk.
# One row per kind of data kept on this workstation: what it holds, where, for how long, how to export it and how to
# delete it. The retention values come from the storage policy (ConvertTo-DomeniaStoragePolicy, Domenia-Store.Model);
# the folders come from the storage layout read by the caller. Nothing here leaves the workstation.

function Get-DomeniaDataRetentionText {
    # Retention of one measure family: 0 keeps it without a time limit; otherwise the limit is applied only after the
    # operator's preview and confirmation (Stockage, Conservation des mesures).
    param([int]$Days)
    if ($Days -le 0) { return 'Sans limite de durée.' }
    return ([string]$Days + ' jours, appliqués après prévisualisation et confirmation ; aucune suppression automatique.')
}

function Get-DomeniaLocalDataPolicy {
    # $Policy: storage policy (any shape accepted by ConvertTo-DomeniaStoragePolicy, $null for the defaults).
    # $DataRoot, $ReceiptRoot: folders of the storage layout; $DatabasePath: active base of this domain ('' when none).
    # An unknown folder is shown as such, never invented.
    # -PolicyUnreadable: the saved settings could not be read; retention is then shown as unknown, never as a default.
    param($Policy = $null,[AllowEmptyString()][string]$DataRoot = '',[AllowEmptyString()][string]$ReceiptRoot = '',[AllowEmptyString()][string]$DatabasePath = '',[switch]$PolicyUnreadable)
    $settings = ConvertTo-DomeniaStoragePolicy $Policy
    $retention = { param([int]$Days) if ($PolicyUnreadable) { return 'Réglages de conservation illisibles : durée inconnue.' } return (Get-DomeniaDataRetentionText $Days) }
    $unknown = 'Emplacement non déterminé (stockage local non initialisé).'
    $join = { param([string]$Root,[string]$Child) if ($Root) { return ($Root.TrimEnd('\') + '\' + $Child) } return $unknown }
    $base = $DatabasePath
    if (-not $base) { $base = & $join $DataRoot 'Domains' }
    $backupFolder = & $join $DataRoot 'Backups'
    if ($DatabasePath) {
        $cut = $DatabasePath.LastIndexOf('\')
        if ($cut -gt 0) { $backupFolder = $DatabasePath.Substring(0,$cut) + '\Backups' }
    }
    $receipts = $ReceiptRoot
    if (-not $receipts) { $receipts = $unknown }
    $measureExport = 'Résultats et widgets exportables en CSV depuis leurs vues.'
    $measureDelete = 'Stockage : conservation (prévisualiser puis appliquer) ou purge volontaire des observations.'
    $backupRetention = 'Sauvegarde automatique désactivée : copies faites sur demande (Sauvegarder maintenant).'
    if ($settings.AutomaticBackup) { $backupRetention = 'Toutes les ' + [string]$settings.BackupHours + ' h pendant que Domenia est ouvert, ' + [string]$settings.BackupKeep + ' copies conservées.' }
    if ($PolicyUnreadable) { $backupRetention = 'Réglages de sauvegarde illisibles : fréquence et nombre de copies inconnus.' }
    $backupRetention += ' La sauvegarde faite avant une migration du schéma reste hors rotation.'
    $rows = @(
        [pscustomobject]@{ Category = 'Directory'; Label = 'Index de lʼannuaire'; Content = 'Objets AD lus dans les OU choisies : noms, DN, attributs affichés, appartenances.'; Location = $base; Retention = 'Mis à jour par les relectures de lʼannuaire ; conservé jusquʼà la purge.'; Export = 'Export CSV des résultats de Rechercher.'; Deletion = 'Stockage : purge volontaire de tout lʼindex local.' }
        [pscustomobject]@{ Category = 'Presence'; Label = 'Présence ping'; Content = 'Réponse au ping des postes interrogés, avec sa date.'; Location = $base; Retention = (& $retention $settings.PresenceDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Console'; Label = 'Utilisateur connecté'; Content = 'Compte ouvert sur la console des postes interrogés.'; Location = $base; Retention = (& $retention $settings.ConsoleDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Inventory'; Label = 'Inventaire'; Content = 'Matériel, système et logiciels lus par CIM/WMI sur les postes demandés.'; Location = $base; Retention = (& $retention $settings.InventoryDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Probe'; Label = 'Sondes'; Content = 'Valeurs des sondes WMI demandées.'; Location = $base; Retention = (& $retention $settings.ProbeDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Detail'; Label = 'Lectures détaillées'; Content = 'Classes WMI lues en détail à votre demande.'; Location = $base; Retention = (& $retention $settings.DetailDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Snapshot'; Label = 'Instantanés de recherche'; Content = 'Résultats déjà lus, gardés pour les comparaisons.'; Location = $base; Retention = 'Jusquʼà la purge volontaire.'; Export = 'Export CSV des résultats.'; Deletion = 'Stockage : purge volontaire des instantanés.' }
        [pscustomobject]@{ Category = 'Backup'; Label = 'Sauvegardes de la base'; Content = 'Copies complètes de la base locale.'; Location = $backupFolder; Retention = $backupRetention; Export = 'Stockage : Copier une sauvegarde vers…'; Deletion = 'Fichiers supprimables à la main ; la désinstallation les supprime sur choix explicite.' }
        [pscustomobject]@{ Category = 'Log'; Label = 'Journaux'; Content = 'Actions, erreurs, comptes AD et Windows de la session ; mots de passe et secrets masqués.'; Location = (& $join $DataRoot 'Logs'); Retention = '5 Mo par journal, plus une génération précédente (.1).'; Export = 'Copie du journal (noms masquables) ; dossier technique sans nom ni chemin.'; Deletion = 'Fichiers supprimables à la main ; la désinstallation les supprime sur choix explicite.' }
        [pscustomobject]@{ Category = 'Receipt'; Label = 'Reçus dʼopérations'; Content = 'Un reçu par écriture AD demandée (cible, action, état), suivi jusquʼà sa fin.'; Location = $receipts; Retention = 'Jamais supprimés automatiquement ; au-delà de 384 reçus, les plus anciens terminés passent dans le sous-dossier archive.'; Export = 'Fichiers JSON du dossier des reçus.'; Deletion = 'Désinstallation sur choix explicite des données du profil.' }
        [pscustomobject]@{ Category = 'Preference'; Label = 'Préférences'; Content = 'Réglages de lʼinterface et périmètres choisis ; aucun mot de passe.'; Location = (& $join $DataRoot 'Preferences'); Retention = 'Jusquʼà leur modification.'; Export = 'Aucun export dédié.'; Deletion = 'Désinstallation sur choix explicite.' }
        [pscustomobject]@{ Category = 'Vault'; Label = 'Comptes mémorisés'; Content = 'Mots de passe confiés au coffre Windows, seulement sur votre demande.'; Location = 'Gestionnaire dʼidentification Windows de ce compte.'; Retention = 'Jusquʼà leur retrait.'; Export = 'Aucun : Domenia ne les exporte jamais.'; Deletion = 'Comptes et accès : retirer. La désinstallation ne les supprime pas.' }
    )
    return [pscustomobject]@{
        Rows = $rows
        Statement = 'Domenia nʼenvoie aucune donnée hors de ce poste : ni télémétrie, ni service en ligne. Les lectures interrogent seulement lʼannuaire, les postes et les serveurs internes (connecteurs) que vous désignez.'
    }
}
