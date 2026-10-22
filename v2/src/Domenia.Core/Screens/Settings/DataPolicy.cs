using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Locations of the local data of the mode, as labels (« %LOCALAPPDATA%\Domenia\… ») and as openable folders.</summary>
public sealed record DataLocations(
    string? DataFolder,
    string? Preferences,
    string? Receipts,
    string? Logs,
    string? WebProfile,
    string? Base,
    string? Backups,
    bool Simulation,
    bool MemoryOnly);

/// <summary>One kind of data kept on this workstation (PAR-029): content, place, duration, export and deletion.</summary>
public sealed record DataPolicyRow(string Category, string Label, string Content, string Location, string Retention, string Export, string Deletion, string? Folder);

/// <summary>Result of settings.dataPolicy: rows and the commitment (nothing leaves the workstation).</summary>
public sealed record DataPolicyView(ImmutableArray<DataPolicyRow> Rows, string Statement, bool PolicyUnreadable);

/// <summary>
/// Local data policy of Domenia 2 (Domenia 1 PAR-029, Get-DomeniaLocalDataPolicy, adapted to the files of Domenia 2): one row
/// per kind of data kept on the workstation. An unknown folder is said undetermined, never invented; unreadable settings
/// give an unknown duration, never a default. Improvement: rows whose folder exists carry « Ouvrir le dossier ».
/// </summary>
public static class DataPolicyRules
{
    public const string Statement = "Domenia n’envoie aucune donnée hors de ce poste" + FrenchText.Nbsp + ": ni télémétrie, ni service en ligne. Les lectures interrogent seulement l’annuaire, les postes et les serveurs internes que vous désignez.";

    private const string Unknown = "Emplacement non déterminé (aucun dossier de données utilisable).";

    public static DataPolicyView Build(StoragePolicy policy, bool policyUnreadable, DataLocations locations)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(locations);
        string Retention(int days) => policyUnreadable ? "Réglages de conservation illisibles" + FrenchText.Colon + "durée inconnue." : StoragePolicyRules.RetentionText(days);
        var memory = locations.MemoryOnly ? " En mémoire seulement pour cette session (capture, E2E ou sans dossier de données)." : "";
        var simulated = locations.Simulation ? " Simulation" + FrenchText.Colon + "fichier distinct du mode annuaire, jamais partagé." : "";
        var baseLocation = locations.Simulation
            ? "Base fictive en mémoire (simulation)" + FrenchText.Colon + "aucune base SQLite n’est ouverte."
            : locations.Base ?? Unknown;
        const string measureExport = "Résultats et widgets exportables en CSV depuis leurs vues (fichier choisi à chaque export).";
        const string measureDelete = "Paramètres › Données et cache" + FrenchText.Nbsp + ": conservation (prévisualiser puis appliquer) ou purge volontaire.";
        var backupRetention = policyUnreadable
            ? "Réglages de sauvegarde illisibles" + FrenchText.Colon + "fréquence et nombre de copies inconnus."
            : policy.AutomaticBackup
                ? "Toutes les " + FrenchText.Integer(policy.BackupHours) + FrenchText.Nbsp + "h pendant que Domenia est ouvert, " + FrenchText.Count(policy.BackupKeep, "copie conservée", "copies conservées") + "."
                : "Sauvegarde automatique désactivée" + FrenchText.Colon + "copies faites sur demande (Sauvegarder maintenant).";
        backupRetention += " Les copies faites avant une conservation, une purge, une migration ou une reprise restent hors rotation.";
        var linkRetention = policyUnreadable ? "Réglages de conservation illisibles" + FrenchText.Colon + "durée inconnue."
            : policy.LinkHistoryDays > 0
                ? "Historique" + FrenchText.Colon + "au-delà de " + FrenchText.Count(policy.LinkHistoryDays, "jour", "jours") + ", les observations identiques répétées sont résumées après prévisualisation et confirmation ; chaque changement d’utilisateur est gardé."
                : "Historique conservé en entier.";
        linkRetention += " Les associations déclarées et leur historique ne sont jamais purgés.";
        var rows = new List<DataPolicyRow>
        {
            new("directory", "Index de l’annuaire", "Objets AD lus dans les OU choisies : noms, DN, attributs affichés, appartenances.", baseLocation,
                "Mis à jour par les relectures de l’annuaire ; conservé jusqu’à la purge.", "Export CSV des résultats de Rechercher.", "Purge volontaire de tout l’index local.", null),
            new("collectionClock", "Horloges de collecte", "Pour chaque OU : dernière tentative, dernière réussite et erreur des lectures AD, ping et WMI.", baseLocation,
                "Une ligne par OU et par source, remplacée à chaque collecte.", "Aucun export dédié : les dates s’affichent avec les mesures.", "Purgées avec les mesures ou avec l’index local.", null),
            new("presence", "Présence ping", "Réponse au ping des postes interrogés, avec sa date.", baseLocation, Retention(policy.PresenceDays), measureExport, measureDelete, null),
            new("console", "Utilisateur connecté", "Compte ouvert sur la console des postes interrogés.", baseLocation, Retention(policy.ConsoleDays), measureExport, measureDelete, null),
            new("inventory", "Inventaire", "Matériel, système et logiciels lus par CIM/WMI sur les postes demandés.", baseLocation, Retention(policy.InventoryDays), measureExport, measureDelete, null),
            new("probe", "Sondes", "Valeurs des sondes WMI demandées.", baseLocation, Retention(policy.ProbeDays), measureExport, measureDelete, null),
            new("detail", "Lectures détaillées", "Classes WMI lues en détail à votre demande.", baseLocation, Retention(policy.DetailDays), measureExport, measureDelete, null),
            new("association", "Associations poste-utilisateur", "Associations observées, déclarées ou importées, avec leur source ; historique des associations.", baseLocation, linkRetention,
                "Utilisateurs et postes : « Exporter » en CSV.", "Suppression journalisée et restaurable dans Utilisateurs et postes.", null),
            new("backup", "Sauvegardes de la base", "Copies complètes et vérifiées de la base locale (quick_check, SHA-256), avec une annexe des préférences approuvées, sans identité de connexion.",
                locations.Simulation ? "Copies fictives en mémoire (simulation)" + FrenchText.Colon + "aucun fichier." : locations.Backups ?? Unknown, backupRetention,
                "Paramètres › Données et cache" + FrenchText.Nbsp + ": « Copier une sauvegarde vers… ».", "Fichiers supprimables à la main ; restauration seulement sur décision explicite.", null),
            new("preference", "Préférences", "Réglages de l’interface et des écrans (widgets, OU de travail, collecte, conservation). Aucun mot de passe." + simulated + memory,
                locations.Preferences ?? Unknown, "Jusqu’à leur modification ou leur réinitialisation.", "Paramètres › Préférences" + FrenchText.Nbsp + ": « Exporter les préférences ».",
                "Paramètres › Préférences" + FrenchText.Nbsp + ": « Réinitialiser » par groupe.", locations.DataFolder),
            new("receipt", "Reçus d’écriture", "Un reçu par écriture (plan, cible, résultat, relectures), écrit avant l’envoi ; jamais un jeton ni un mot de passe." + simulated + memory,
                locations.Receipts ?? Unknown, "Jamais supprimés automatiquement ; rien n’y est jamais rejoué.", "Opérations" + FrenchText.Nbsp + ": liste des reçus et leur détail.",
                "Désinstallation sur choix explicite, refusée tant qu’un reçu reste à vérifier.", locations.DataFolder),
            new("log", "Journal technique", "Démarrage, opérations et erreurs (codes, nombres, types d’erreur) ; jamais une saisie de la page ni un secret.",
                locations.Logs ?? Unknown, "Fichier domenia.log ; une génération par fichier.", "Paramètres › Journaux" + FrenchText.Nbsp + ": copie du journal affiché, avec masquage des noms.",
                "Fichiers supprimables à la main.", locations.Logs),
            new("webProfile", "Profil du moteur web", "Préférences de l’interface (thème, animations, zoom, densité), cache et stockage du moteur WebView2." + simulated,
                locations.WebProfile ?? Unknown, "Jusqu’à leur modification ; le cache du moteur est géré par WebView2.", "Aucun export dédié (les préférences d’interface partent avec l’export des préférences).",
                "Paramètres › Préférences" + FrenchText.Nbsp + ": « Réinitialiser l’interface ».", locations.DataFolder),
            new("legacy", "Anciennes données", "Données de Domenia 1 : lues seulement par « Reprendre les anciennes données », après simulation et confirmation. Domenia 2 n’y écrit rien.",
                locations.Simulation ? "Données fictives de Domenia 1 (simulation)." : "%LOCALAPPDATA%\\Domenia\\Data (Domenia 1)", "Jamais supprimées automatiquement : la reprise laisse les fichiers d’origine en place.",
                "Fichiers déjà au format TSV, CSV ou SQLite.", "Fichiers supprimables à la main.", null),
            new("vault", "Comptes mémorisés", "Mots de passe confiés au coffre Windows, seulement sur votre demande.", "Gestionnaire d’identification Windows de ce compte.",
                "Jusqu’à leur retrait.", "Aucun : Domenia ne les exporte jamais.", "Retrait depuis la connexion ; la désinstallation ne les supprime pas.", null),
        };
        return new DataPolicyView([.. rows], Statement, policyUnreadable);
    }
}
