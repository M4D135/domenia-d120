# Local data policy of Domenia (point 147). Pure rules: no WPF, no network, no disk.
# One row per kind of data kept on this workstation: what it holds, where, for how long, how to export it and how to
# delete it. The retention values come from the storage policy (ConvertTo-DomeniaStoragePolicy, Domenia-Store.Model);
# the folders come from the storage layout read by the caller (its Cache areas: Logs, Backups, Diagnostics, Exports,
# Legacy, Domains), so that every folder Domenia writes under the profile has its row. Data kept inside the base of a
# domain (associations, directory snapshots, collection clocks, query library) and the journals written beside it have
# their own rows too. Nothing here leaves the workstation.

function Get-DomeniaDataRetentionText {
    # Retention of one measure family: 0 keeps it without a time limit; otherwise the limit is applied only after the
    # operator's preview and confirmation (Stockage, Conservation des mesures).
    param([int]$Days)
    if ($Days -le 0) { return 'Sans limite de durée.' }
    return ([string]$Days + ' jours, appliqués après prévisualisation et confirmation ; aucune suppression automatique.')
}

function Get-DomeniaLocalDataPolicy {
    # $Policy: storage policy (any shape accepted by ConvertTo-DomeniaStoragePolicy, $null for the defaults).
    # $DataRoot, $ReceiptRoot: folders of the storage layout; $Areas: Cache areas of the layout (Name, Path), which take
    # precedence over DataRoot\<Name>; $DatabasePath: active base of this domain ('' when none).
    # An unknown folder is shown as such, never invented.
    # -PolicyUnreadable: the saved settings could not be read; retention is then shown as unknown, never as a default.
    param($Policy = $null,[AllowEmptyString()][string]$DataRoot = '',[AllowEmptyString()][string]$ReceiptRoot = '',[AllowEmptyString()][string]$DatabasePath = '',[object[]]$Areas = @(),[switch]$PolicyUnreadable)
    $settings = ConvertTo-DomeniaStoragePolicy $Policy
    $retention = { param([int]$Days) if ($PolicyUnreadable) { return 'Réglages de conservation illisibles : durée inconnue.' } return (Get-DomeniaDataRetentionText $Days) }
    $unknown = 'Emplacement non déterminé (stockage local non initialisé).'
    $join = { param([string]$Root,[string]$Child) if ($Root) { return ($Root.TrimEnd('\') + '\' + $Child) } return $unknown }
    $area = {
        param([string]$Name)
        foreach ($item in @($Areas)) { if (($null -ne $item) -and ([string](Get-DomeniaMember $item 'Name' '') -ceq $Name) -and ([string](Get-DomeniaMember $item 'Path' ''))) { return [string](Get-DomeniaMember $item 'Path' '') } }
        return (& $join $DataRoot $Name)
    }
    $base = $DatabasePath
    if (-not $base) { $base = & $area 'Domains' }
    $backupFolder = & $area 'Backups'
    if ($DatabasePath) {
        $cut = $DatabasePath.LastIndexOf('\')
        if ($cut -gt 0) { $backupFolder = $DatabasePath.Substring(0,$cut) + '\Backups' }
    }
    $receipts = $ReceiptRoot
    if (-not $receipts) { $receipts = $unknown }
    $exportFolder = & $area 'Exports'
    $manualDeletion = 'Fichiers supprimables à la main ; la désinstallation les supprime sur choix explicite.'
    $measureExport = 'Résultats et widgets exportables en CSV depuis leurs vues, dans le dossier des exports (ligne Exports CSV).'
    $measureDelete = 'Stockage : conservation (prévisualiser puis appliquer) ou purge volontaire des observations.'
    $backupRetention = 'Sauvegarde automatique désactivée : copies faites sur demande (Sauvegarder maintenant).'
    if ($settings.AutomaticBackup) { $backupRetention = 'Toutes les ' + [string]$settings.BackupHours + ' h pendant que Domenia est ouvert, ' + [string]$settings.BackupKeep + ' copies conservées.' }
    if ($PolicyUnreadable) { $backupRetention = 'Réglages de sauvegarde illisibles : fréquence et nombre de copies inconnus.' }
    $backupRetention += ' La sauvegarde faite avant une migration du schéma reste hors rotation.'
    # Copies taken before a gesture that changes the base form their own series (Geste-*.db, lot X06).
    if (-not $PolicyUnreadable) { $backupRetention += ' Copies avant un geste : série à part, ' + [string]$settings.BackupKeep + ' copies conservées, sans retirer les autres.' }
    # Point 37: the association history is compacted (repeated identical observations), never cut by age.
    $linkRetention = 'Historique conservé en entier.'
    if ($settings.LinkHistoryDays -gt 0) { $linkRetention = 'Historique : au-delà de ' + [string]$settings.LinkHistoryDays + ' jours, les observations identiques répétées sont résumées après prévisualisation et confirmation ; chaque changement dʼutilisateur est gardé.' }
    if ($PolicyUnreadable) { $linkRetention = 'Réglages de conservation illisibles : durée inconnue.' }
    $linkRetention += ' Les associations déclarées et leur historique ne sont jamais purgés.'
    $rows = @(
        [pscustomobject]@{ Category = 'Directory'; Label = 'Index de lʼannuaire'; Content = 'Objets AD lus dans les OU choisies : noms, DN, attributs affichés, appartenances.'; Location = $base; Retention = 'Mis à jour par les relectures de lʼannuaire ; conservé jusquʼà la purge.'; Export = 'Export CSV des résultats de Rechercher, dans le dossier des exports.'; Deletion = 'Stockage : purge volontaire de tout lʼindex local.' }
        [pscustomobject]@{ Category = 'DirectorySnapshot'; Label = 'Relevés de lʼannuaire'; Content = 'Copies datées des objets AD dʼun périmètre, avec la preuve de leur couverture ; objets non revus et écarts du recensement à vérifier. Ni mot de passe, ni droit, ni appartenance.'; Location = $base; Retention = 'Relevés gardés jusquʼà leur suppression ; les 50 000 objets non revus les plus récents sont gardés.'; Export = 'Aucun export dédié : la comparaison de deux relevés sʼaffiche dans la page.'; Deletion = 'Base autonome, onglet Contrôles : « Supprimer le relevé choisi… » ; tout part aussi avec la purge de lʼindex local.' }
        [pscustomobject]@{ Category = 'CollectionClock'; Label = 'Horloges de collecte'; Content = 'Pour chaque OU : dernière tentative, dernière réussite et erreur des lectures AD, ping et WMI.'; Location = $base; Retention = 'Une ligne par OU et par source, remplacée à chaque collecte.'; Export = 'Aucun export dédié : les dates sʼaffichent avec les mesures.'; Deletion = 'Stockage : purgées avec les mesures (ping, WMI) ou avec lʼindex local (lectures AD).' }
        [pscustomobject]@{ Category = 'Presence'; Label = 'Présence ping'; Content = 'Réponse au ping des postes interrogés, avec sa date.'; Location = $base; Retention = (& $retention $settings.PresenceDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Console'; Label = 'Utilisateur connecté'; Content = 'Compte ouvert sur la console des postes interrogés.'; Location = $base; Retention = (& $retention $settings.ConsoleDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Inventory'; Label = 'Inventaire'; Content = 'Matériel, système et logiciels lus par CIM/WMI sur les postes demandés.'; Location = $base; Retention = (& $retention $settings.InventoryDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Probe'; Label = 'Sondes'; Content = 'Valeurs des sondes WMI demandées.'; Location = $base; Retention = (& $retention $settings.ProbeDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Detail'; Label = 'Lectures détaillées'; Content = 'Classes WMI lues en détail à votre demande.'; Location = $base; Retention = (& $retention $settings.DetailDays); Export = $measureExport; Deletion = $measureDelete }
        [pscustomobject]@{ Category = 'Association'; Label = 'Associations poste-utilisateur'; Content = 'Associations observées, déclarées ou importées (CSV, GLPI, osquery) avec leur source et, pour un import, son lot de retour arrière ; historique des associations ; journal des suppressions à côté de la base (.relations-journal.jsonl).'; Location = $base; Retention = $linkRetention; Export = 'Relations : « Exporter » ou « Exporter tout » en CSV ; section associations du dossier hors ligne.'; Deletion = 'Relations : « Supprimer lʼassociation », « Nettoyer » ou « Annuler lʼimport » (dernier lot importé, même après un redémarrage) ; chaque retrait est journalisé et restaurable.' }
        [pscustomobject]@{ Category = 'QueryLibrary'; Label = 'Bibliothèque de requêtes'; Content = 'Requêtes personnelles enregistrées, avec chacune de leurs révisions ; journal des imports de packs à côté de la base (.query-imports.jsonl).'; Location = $base; Retention = 'Requêtes et révisions jamais supprimées : une requête archivée reste consultable et restaurable. Le journal garde les 40 derniers imports.'; Export = 'Atelier : « Exporter ma bibliothèque (JSON)… » ou « Exporter cette requête (PowerShell)… » ; section requêtes du dossier hors ligne.'; Deletion = 'Aucune suppression : « Archiver la requête » la retire des listes ; « Restaurer avant cet import… » revient à lʼétat précédant un import.' }
        [pscustomobject]@{ Category = 'Snapshot'; Label = 'Instantanés de recherche'; Content = 'Résultats déjà lus, gardés pour les comparaisons.'; Location = $base; Retention = 'Jusquʼà la purge volontaire.'; Export = 'Export CSV des résultats, dans le dossier des exports.'; Deletion = 'Stockage : purge volontaire des instantanés.' }
        [pscustomobject]@{ Category = 'Backup'; Label = 'Sauvegardes de la base'; Content = 'Copies complètes de la base locale : sauvegardes planifiées ou faites sur demande (Domenia-*.db) et copies prises avant un geste qui modifie la base (Geste-*.db) : mise à jour dʼune OU, import ou retrait dʼassociations, oubli des relevés du parc.'; Location = $backupFolder; Retention = $backupRetention; Export = 'Stockage : Copier une sauvegarde vers…'; Deletion = $manualDeletion }
        [pscustomobject]@{ Category = 'Log'; Label = 'Journaux'; Content = 'Actions, erreurs, comptes AD et Windows de la session ; mots de passe et secrets masqués.'; Location = (& $area 'Logs'); Retention = '5 Mo par journal, plus une génération précédente (.1).'; Export = 'Copie du journal (noms masquables) ; dossier technique sans nom ni chemin.'; Deletion = $manualDeletion }
        [pscustomobject]@{ Category = 'Export'; Label = 'Exports CSV'; Content = 'Fichiers CSV que vous exportez (résultats, widgets, requêtes) : données de lʼannuaire et des postes affichées, avec la description de la requête exportée.'; Location = $exportFolder; Retention = 'Jamais supprimés automatiquement.'; Export = 'Ce sont déjà des fichiers CSV : « Ouvrir le dossier » après chaque export.'; Deletion = $manualDeletion }
        [pscustomobject]@{ Category = 'OfflineDossier'; Label = 'Dossiers hors ligne'; Content = 'Dossiers de diagnostic préparés à votre demande (« Dossier hors ligne ») pour un périmètre choisi : état de la base, postes, observations, associations et requêtes enregistrées. Mots de passe, clés BitLocker, LAPS et journaux bruts exclus.'; Location = $exportFolder; Retention = 'Jamais supprimés automatiquement.'; Export = 'Fichiers JSON lisibles hors de Domenia, avec un manifeste de leurs empreintes SHA-256.'; Deletion = $manualDeletion }
        [pscustomobject]@{ Category = 'Diagnostic'; Label = 'Diagnostics'; Content = 'Description XAML dʼune vue qui nʼa pas pu sʼafficher ; dossier de travail du ZIP diagnostic (compte et domaine de connexion, configuration nettoyée, autodiagnostic).'; Location = (& $area 'Diagnostics'); Retention = 'Fichiers XAML jamais supprimés automatiquement ; dossier de travail retiré dès le ZIP diagnostic écrit.'; Export = 'ZIP diagnostic écrit dans le fichier que vous choisissez.'; Deletion = $manualDeletion }
        [pscustomobject]@{ Category = 'Legacy'; Label = 'Anciennes données'; Content = 'Zone réservée aux données des versions précédentes ; Domenia nʼy écrit rien. Les anciens fichiers (index TSV, liens poste-utilisateur) ne sont lus que par « Reprendre les anciennes données », après simulation et confirmation.'; Location = (& $area 'Legacy'); Retention = 'Jamais supprimées automatiquement : la reprise laisse les fichiers dʼorigine en place.'; Export = 'Fichiers déjà au format TSV ou CSV.'; Deletion = 'Fichiers supprimables à la main ; la désinstallation supprime la zone sur choix explicite, pas les anciens fichiers restés hors du dossier des données.' }
        [pscustomobject]@{ Category = 'Receipt'; Label = 'Reçus dʼopérations'; Content = 'Un reçu par écriture AD demandée (cible, action, état) et lʼétat attendu à relire si son issue reste inconnue (jamais un mot de passe), suivi jusquʼà sa fin.'; Location = $receipts; Retention = 'Jamais supprimés automatiquement ; au-delà de 384 reçus, les plus anciens terminés passent dans le sous-dossier archive, où ils restent.'; Export = 'Fichiers JSON du dossier des reçus.'; Deletion = 'Désinstallation sur choix explicite des données du profil, refusée tant quʼun reçu reste à vérifier.' }
        [pscustomobject]@{ Category = 'Preference'; Label = 'Préférences'; Content = 'Réglages de lʼinterface et périmètres choisis ; plan de reprise du dernier relevé ping ou WMI interrompu (postes visés). Aucun mot de passe.'; Location = (& $join $DataRoot 'Preferences'); Retention = 'Jusquʼà leur modification ; le plan de reprise est effacé à la fin du relevé ou à son abandon.'; Export = 'Aucun export dédié.'; Deletion = 'Désinstallation sur choix explicite.' }
        [pscustomobject]@{ Category = 'Vault'; Label = 'Comptes mémorisés'; Content = 'Mots de passe confiés au coffre Windows, seulement sur votre demande.'; Location = 'Gestionnaire dʼidentification Windows de ce compte.'; Retention = 'Jusquʼà leur retrait.'; Export = 'Aucun : Domenia ne les exporte jamais.'; Deletion = 'Comptes et accès : retirer. La désinstallation ne les supprime pas.' }
    )
    return [pscustomobject]@{
        Rows = $rows
        Statement = 'Domenia nʼenvoie aucune donnée hors de ce poste : ni télémétrie, ni service en ligne. Les lectures interrogent seulement lʼannuaire, les postes et les serveurs internes (connecteurs) que vous désignez.'
    }
}
