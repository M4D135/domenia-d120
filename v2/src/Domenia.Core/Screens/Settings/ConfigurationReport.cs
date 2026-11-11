using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Kind of a configuration value.</summary>
public enum ConfigValueKind
{
    Boolean,
    Integer,
    Text,
}

/// <summary>Use of a setting by Domenia 2 today: applied, applied by construction, or planned with the feature it bounds.</summary>
public enum ConfigUse
{
    Applied,
    ByConstruction,
    Planned,
}

/// <summary>One setting of the catalogue: its default, bounds, effect and use by Domenia 2.</summary>
public sealed record ConfigDefinition(string Section, string Key, string Label, ConfigValueKind Kind, string Default, int? Minimum, int? Maximum, string Effect, ConfigUse Use, ImmutableArray<string> Choices);

/// <summary>Effective value of a setting and where it comes from (improvement of PAR-042: value and provenance).</summary>
public sealed record ConfigEntry(string Section, string Key, string Label, string Value, string Default, string Source, string SourceLabel, Tone Tone, string? Bounds, string Effect, string Use, string UseLabel);

/// <summary>A section of the configuration with its effective values.</summary>
public sealed record ConfigSection(string Id, string Label, string Description, ImmutableArray<ConfigEntry> Entries, int FromFile);

/// <summary>One line of the central policy of the interface elements (PAR-044).</summary>
public sealed record GuiPolicyEntry(string Element, string Policy, bool Valid, string Text);

/// <summary>Result of settings.config.</summary>
public sealed record ConfigurationReport(
    string FileState,
    string FileLabel,
    string? Problem,
    ImmutableArray<ConfigSection> Sections,
    ImmutableArray<GuiPolicyEntry> GuiPolicy,
    bool AllowExpertProfile,
    int FromFile,
    ImmutableArray<string> UnknownSections,
    ImmutableArray<string> Notes);

/// <summary>
/// Effective configuration of Domenia.config.json (Domenia 1 PAR-042 to PAR-046): every setting read by Domenia, bounded,
/// with its default, the value in force and its provenance (default, file, file bounded, file unreadable). Same reading
/// rules as Domenia 1: names case insensitive, a name present twice in different case makes the file unreadable, an empty
/// value keeps the default, a value outside its bounds is brought back into them (clamp). Pure: the caller reads the bytes.
/// </summary>
public static class ConfigurationRules
{
    private static ConfigDefinition B(string section, string key, string label, bool value, string effect, ConfigUse use = ConfigUse.Planned) =>
        new(section, key, label, ConfigValueKind.Boolean, value ? "true" : "false", null, null, effect, use, []);

    private static ConfigDefinition N(string section, string key, string label, int value, int min, int max, string effect, ConfigUse use = ConfigUse.Planned) =>
        new(section, key, label, ConfigValueKind.Integer, value.ToString(CultureInfo.InvariantCulture), min, max, effect, use, []);

    private static ConfigDefinition T(string section, string key, string label, string value, string effect, ConfigUse use = ConfigUse.Planned, params string[] choices) =>
        new(section, key, label, ConfigValueKind.Text, value, null, null, effect, use, [.. choices]);

    /// <summary>Sections in display order: identifier, label and what they govern.</summary>
    public static ImmutableArray<(string Id, string Label, string Description)> Sections { get; } =
    [
        ("Startup", "Démarrage", "Suivi local après validation du paquet ; appliqué à la prochaine ouverture."),
        ("Auth", "Connexion", "Ouverture de session et mode de démarrage."),
        ("Security", "Sécurité", "Garde-fous des écritures, des secrets et de la lecture seule ; valeurs prudentes par défaut."),
        ("Features", "Commutateurs de fonctionnalités", "Comportements de remplacement ; les fonctions intrusives sont désactivées par défaut."),
        ("UI", "Interface", "Profil Expert, lecture seule au démarrage."),
        ("Park", "Relevés", "Plafond d’un relevé de liste (réglable aussi dans Budgets réseau)."),
        ("Streaming", "Vérifications en direct", "Rien ne part sur le réseau sans geste, sauf choix explicite de l’administrateur."),
        ("Async", "Moteur et délais", "Concurrence, file d’attente et délais des opérations, chacun borné."),
        ("Remote", "Accès distant", "Moyens d’accès aux postes et délais réseau."),
        ("Cache", "Cache de lecture", "Durée de vie et taille du cache en mémoire."),
        ("Browser", "Recherche et listes", "Limites des recherches et des pages de résultats."),
        ("Index", "Index local", "Mise à jour de la base locale de l’annuaire."),
        ("LocalStore", "Base locale", "Emplacement, verrou et sauvegardes de la base SQLite."),
        ("UserMachineLink", "Utilisateurs et postes", "Délais et seuils de la détection des associations."),
    ];

    /// <summary>Settings read by Domenia (Domenia 1 New-DefaultConfig, restricted to those that matter for Domenia 2).</summary>
    public static ImmutableArray<ConfigDefinition> Catalog { get; } =
    [
        T("Auth", "LoginWindowMode", "Fenêtre de connexion", "Standard", "Standard ou diagnostic : saisie native puis suivi horodaté de la validation, trace fermée sans secret.", ConfigUse.Applied, "Standard", "Debug"),
        B("Auth", "AllowWindowsSession", "Session Windows proposée d’abord", true, "« Continuer en tant que DOMAINE\\nom » sans mot de passe ; faux refuse aussi la connexion dans le moteur.", ConfigUse.Applied),
        N("Auth", "LoginTimeoutSeconds", "Délai total de connexion", 30, 5, 120, "Budget total découverte et validation ; au-delà résultat abandonné, travail natif retenu jusqu’à sa fin réelle, jamais de nouvel essai.", ConfigUse.Applied),
        N("Auth", "PerServerTimeoutSeconds", "Délai par contrôleur", 6, 1, 30, "Délai du contrôleur, plafonné aussi par le budget total ; aucun autre contrôleur ne reçoit le secret.", ConfigUse.Applied),
        N("Auth", "MaxServerCandidates", "Contrôleurs candidats", 1, 1, 1, "V2 épingle un seul contrôleur après découverte Windows sans secret explicite. Aucun second DC ni variante d’identité ne reçoit le mot de passe.", ConfigUse.ByConstruction),
        B("Auth", "DemoProvider", "Démarrage en simulation", false, "Seule la valeur JSON true démarre en simulation (annuaire fictif, aucune connexion).", ConfigUse.Applied),

        N("Security", "WritePlanMaxAgeMinutes", "Délai de confirmation d’un plan", 5, 1, 5, "Délai de 1 à 5 minutes contrôlé avant précontrôle et envoi, avec une horloge monotone. Le délai ne peut pas être désactivé ; aucune confirmation permanente.", ConfigUse.Applied),
        N("Security", "SecretRevealSeconds", "Révélation d’un mot de passe saisi", 5, 1, 30, "Durée maximale du calque de révélation ; saisie, perte de focus et fermeture le masquent plus tôt. Le champ reste masqué et le calque ne permet ni édition ni copie.", ConfigUse.Applied),
        N("Security", "SecretMemorySeconds", "Durée en mémoire d’un secret", 300, 30, 3600, "Durée maximale du propriétaire de secret en mémoire ; fermeture et compte à rebours visuel peuvent l’effacer plus tôt. Les copies natives temporaires suivent le nettoyage Windows.", ConfigUse.Applied),
        N("Security", "AutoClearSecretClipboardSeconds", "Effacement du presse-papiers", 30, 5, 300, "Un secret copié est retiré du presse-papiers après ce délai.", ConfigUse.Applied),
        B("Security", "ForcePasswordChangeOnReset", "Changement de mot de passe imposé", true, "Un mot de passe réinitialisé doit être changé par son utilisateur.", ConfigUse.Applied),
        N("Security", "GeneratedPasswordLength", "Longueur du mot de passe généré", 16, 14, 64, "Longueur du mot de passe proposé par le bouton de génération.", ConfigUse.Applied),
        N("Security", "ReadOnlyReturnMinutes", "Retour en lecture seule", 0, 0, 0, "Aucun mode écriture persistant dans V2 : chaque envoi nécessite un nouveau plan confirmé. L’ancien délai D1 ne crée jamais une fenêtre d’autorisation.", ConfigUse.ByConstruction),
        B("Security", "BlockProtectedObjects", "Objets protégés bloqués", true, "Les objets protégés (adminCount=1) exigent la saisie de leur nom ; certains restent bloqués.", ConfigUse.ByConstruction),
        B("Security", "AllowContainerDelete", "Suppression de conteneur", false, "Interdite par défaut.", ConfigUse.Applied),
        B("Security", "AllowRawAttributeWrite", "Écriture d’attribut brut", false, "Interdite par défaut ; jamais sur un attribut sensible.", ConfigUse.Applied),
        B("Security", "RequireTypedHighRiskConfirmation", "Confirmation saisie des écritures à risque", true, "Le nom exact de la cible est saisi avant une écriture à risque.", ConfigUse.ByConstruction),
        B("Security", "SingleWriteChannel", "Canal d’écriture unique", true, "Une écriture à la fois, par write.execute seulement.", ConfigUse.ByConstruction),
        B("Security", "NeverPersistLaps", "Jamais de mot de passe LAPS enregistré", true, "Aucun secret LAPS n’est écrit sur le disque.", ConfigUse.ByConstruction),
        B("Security", "NeverPersistBitLockerRecovery", "Jamais de clé BitLocker enregistrée", true, "Aucune clé de récupération n’est écrite sur le disque.", ConfigUse.ByConstruction),
        B("Security", "NeverLogSecretValues", "Aucun secret journalisé", true, "Le journal technique ne reçoit que des codes, des nombres et des types d’erreur.", ConfigUse.ByConstruction),

        B("Features", "Scheduler", "Ordonnanceur à budgets", true, "File bornée et places réservées aux actions explicites.", ConfigUse.ByConstruction),
        B("Features", "IdlePolicy", "Politique d’inactivité", true, "Suspend les nouvelles admissions de fond quand la fenêtre est inactive ou masquée ; les lectures en cours finissent et les gestes restent disponibles.", ConfigUse.Applied),
        B("Features", "BitLockerKeySelection", "Choix d’une clé BitLocker", true, "Sélection explicite d’une clé quand plusieurs existent.", ConfigUse.ByConstruction),
        B("Features", "SecretSingleCopy", "Copie unique d’un secret", true, "Un secret ne se copie qu’une fois par affichage.", ConfigUse.ByConstruction),
        B("Features", "ScopedLocks", "Verrous ciblés", true, "Une écriture incertaine bloque sa cible seulement.", ConfigUse.ByConstruction),
        B("Features", "SearchSyntax", "Syntaxe de recherche", true, "Préfixes utilisateur:, poste:, groupe:, mail:.", ConfigUse.Applied),
        B("Features", "SearchRanking", "Classement des résultats", true, "Résultats classés par pertinence.", ConfigUse.Applied),
        B("Features", "ColumnProfiles", "Profils de colonnes", true, "Dispositions de colonnes mémorisées.", ConfigUse.Applied),
        B("Features", "InlineConfirm", "Confirmation dans la page", true, "Jamais de fenêtre de confirmation : panneaux et dialogues dans la page.", ConfigUse.ByConstruction),
        B("Features", "IsolatedReads", "Lectures isolées", true, "Lectures natives potentiellement bloquantes obligatoirement isolées dans un processus borné ; ancienne clé conservée pour compatibilité, false ne désactive pas cette protection. ICMP asynchrone et LDAP borné gardent leurs propres budgets.", ConfigUse.ByConstruction),
        B("Features", "WakeOnLan", "Wake-on-LAN", false, "Envoi d’un paquet de réveil ; fonction intrusive désactivée par défaut.", ConfigUse.Applied),
        B("Features", "LocalAssistant", "Assistant local", false, "Assistant d’aide local ; désactivé par défaut.", ConfigUse.Applied),
        B("Features", "ReadTrace", "Trace des lectures", false, "Trace détaillée des requêtes de lecture dans le journal technique.", ConfigUse.Applied),

        B("UI", "AllowExpertProfile", "Profil Expert autorisé", true, "Faux masque le profil Expert et force Essentiel ; ce choix ne donne aucun droit.", ConfigUse.Applied),
        B("UI", "ReadOnlyDefault", "Démarrage en lecture seule", true, "Domenia démarre toujours en lecture seule sur l’Accueil.", ConfigUse.ByConstruction),

        N("Park", "MaxTargets", "Plafond d’un relevé de liste", 500, 1, 100000, "Défaut administrateur du plafond ; le choix de l’opérateur dans Budgets réseau le remplace.", ConfigUse.Applied),

        B("Streaming", "VerifyUserOnSelection", "Vérifier l’utilisateur à la sélection", true, "Relit l’utilisateur connecté d’un poste choisi, sur geste."),
        B("Streaming", "RevalidateListedObjects", "Revérifier les listes affichées", false, "Faux par défaut : rien ne part sur le réseau sans geste."),
        N("Streaming", "RevalidateIntervalSeconds", "Intervalle de revérification", 60, 10, 3600, "Intervalle quand la revérification est activée."),
        N("Streaming", "ReconcileSeconds", "Réconciliation des listes", 180, 30, 3600, "Intervalle de réconciliation des listes en arrière-plan."),
        N("Streaming", "MaxUserProbes", "Lectures de sélection simultanées", 2, 1, 3, "Limite des lectures automatiques liées à une sélection ; elles attendent pendant une écriture. Les gestes explicites gardent leurs places réservées.", ConfigUse.Applied),

        N("Async", "MaxThreads", "Tâches simultanées", 8, 1, 8, "Lectures réseau admises simultanément ; plafond V2 de huit, quotas fournisseurs et physiques toujours prioritaires.", ConfigUse.Applied),
        N("Async", "MaxOutstandingWorkers", "Travaux en cours au plus", 12, 1, 12, "Plafond physique des lectures ; une place explicite et une place écriture supplémentaires restent réservées, sans jamais dépasser 14.", ConfigUse.Applied),
        N("Async", "MaxQueued", "File d’attente", 32, 0, 32, "Demandes en attente au plus ; au-delà, la demande est refusée et le dit.", ConfigUse.Applied),
        N("Async", "ReservedForeground", "Places réservées aux gestes", 2, 0, 7, "Places gardées pour les actions explicites de l’opérateur.", ConfigUse.Applied),
        N("Async", "MaxQueueWaitSeconds", "Attente maximale en file", 120, 5, 600, "Une lecture en attente est retirée avant envoi à ce délai ; aucun travail physique déjà commencé n’est libéré.", ConfigUse.Applied),
        N("Async", "TickBudgetMs", "Budget d’une itération du moteur", 25, 5, 200, "Temps maximal consacré aux promotions en file par itération.", ConfigUse.Applied),
        N("Async", "BackgroundAgingSeconds", "Vieillissement des travaux de fond", 30, 5, 600, "Un travail de fond qui attend gagne en priorité après ce délai, sans franchir une pause ni le plafond physique.", ConfigUse.Applied),
        N("Async", "TreeTimeoutSeconds", "Délai de l’arborescence", 30, 5, 300, "Délai de lecture d’un niveau d’arborescence.", ConfigUse.Applied),
        N("Async", "SearchTimeoutSeconds", "Inactivité d’une recherche", 120, 10, 900, "Délai sans nouvelle page LDAP ; une recherche en progression conserve son plafond global de 900 secondes.", ConfigUse.Applied),
        N("Async", "ObjectTimeoutSeconds", "Délai d’une fiche", 35, 5, 300, "Délai de lecture d’un objet.", ConfigUse.Applied),
        N("Async", "RemoteTimeoutSeconds", "Délai d’une lecture distante", 45, 5, 600, "Délai d’une lecture sur un poste.", ConfigUse.Applied),
        N("Async", "WriteSoftTimeoutSeconds", "Écriture : délai d’alerte", 90, 10, 600, "Au-delà, l’écriture est signalée lente (jamais interrompue).", ConfigUse.Applied),
        N("Async", "WriteHardTimeoutSeconds", "Écriture : alerte prolongée", 300, 30, 1800, "Seuil d’alerte prolongée : reçu d’envoi conservé et issue en attente, sans arrêt forcé, libération du canal ni rejeu.", ConfigUse.Applied),

        N("Remote", "PortTimeoutMs", "Délai de test d’un port", 1200, 200, 5000, "Délai d’un test de port avant une lecture distante.", ConfigUse.Applied),
        N("Remote", "CommandTimeoutSeconds", "Délai d’une commande distante", 10, 1, 300, "Délai par appel natif CIM/WinRM (1 à 300 s) ; le planificateur COM peut dépasser ce délai et conserve alors sa place jusqu’au vrai retour.", ConfigUse.Applied),
        B("Remote", "UseWinRM", "WinRM", true, "Domenia ne modifie jamais la configuration WinRM."),
        B("Remote", "UseCim", "CIM / WMI", true, "Lectures CIM sur DCOM."),
        B("Remote", "UseRemoteRegistry", "Registre distant", true, "Lecture du registre d’un poste."),
        B("Remote", "UseProfilesShare", "Partage des profils", true, "Lecture des profils par le partage administratif."),
        B("Remote", "UseSecurityLog", "Journal Sécurité", false, "Lecture du journal Sécurité d’un poste ; désactivée par défaut."),
        B("Remote", "UseTaskFallback", "Collecte par tâche planifiée", false, "Méthode ponctuelle autorisée après activation ; journal et nettoyage obligatoires.", ConfigUse.Applied),
        B("Remote", "UsePsExecFallback", "Collecte par PsExec", false, "Exécutable approuvé ; contexte Windows intégré, aucun secret en argument.", ConfigUse.Applied),
        B("Remote", "AllowRemoteArtifacts", "Activer les collectes ponctuelles", false, "Désactivées par défaut. Un script temporaire peut être déposé, exécuté puis nettoyé ; aucune installation résidente.", ConfigUse.Applied),
        T("Remote", "DirectMode", "Transport de lecture directe", "auto", "Auto lit en DCOM et relit une seule fois l’inventaire par WinRM autorisé si DCOM est injoignable. Le choix manuel fixe un seul transport.", ConfigUse.Applied, "auto", "dcom", "winrm"),
        T("Remote", "TransientMode", "Déclenchement ponctuel", "manual", "Manuel : autorisation par poste. Automatique : après activation, uniquement dans le périmètre explicite de la lecture et dans la limite configurée.", ConfigUse.Applied, "manual", "automatic"),
        T("Remote", "TransientMethod", "Méthode ponctuelle", "auto", "Une méthode choisie avant lancement. Jamais de second lancement après une issue inconnue ou une authentification refusée.", ConfigUse.Applied, "auto", "task", "psexec", "wmi", "winrm"),
        B("Remote", "UseWmiProcess", "Collecte locale lancée par WMI", false, "Script temporaire exécuté sur le poste par le lanceur WMI, suivi et nettoyé.", ConfigUse.Applied),
        B("Remote", "UseWinRmScript", "Collecte locale lancée par WinRM", false, "Script temporaire exécuté via WinRM déjà configuré sur la cible.", ConfigUse.Applied),
        N("Remote", "AutomaticTargetLimit", "Postes avec collecte ponctuelle automatique", 20, 1, 100000, "Plafond par campagne ou lecture ; les autres postes restent sur les lectures directes.", ConfigUse.Applied),

        B("Startup", "ShowMonitor", "Afficher les étapes d’ouverture", true, "Bandeau de suivi local après validation du paquet. Le contrôle d’intégrité initial reste visible et annulable.", ConfigUse.Applied),
        B("Startup", "KeepMonitorUntilReady", "Suivre jusqu’au premier écran prêt", true, "Conserver le bandeau jusqu’au rendu utilisable ; sinon le masquer dès la navigation WebView réussie. La connexion reste seule à l’écran.", ConfigUse.Applied),
        N("Startup", "WarnStageSeconds", "Signaler une étape longue", 8, 1, 120, "Secondes écoulées sur l’étape locale avant le message d’attente ; aucune estimation de durée restante.", ConfigUse.Applied),

        N("Cache", "TtlSeconds", "Durée de vie du cache", 90, 0, 3600, "Durée de réutilisation des résumés de fiches en mémoire ; aucune donnée durable effacée.", ConfigUse.Applied),
        N("Cache", "ObjectTtlSeconds", "Durée de vie d’une fiche", 45, 0, 3600, "Durée de réutilisation d’une fiche lue.", ConfigUse.Applied),
        N("Cache", "MaxEntries", "Entrées au plus", 400, 10, 400, "Taille du cache en mémoire.", ConfigUse.Applied),

        N("Browser", "DefaultLimit", "Limite par défaut des listes", 100, 1, 20000, "Lignes lues par défaut.", ConfigUse.Applied),
        N("Browser", "GlobalSearchLimit", "Limite de la recherche globale", 100, 1, 100, "Lignes lues par une recherche globale.", ConfigUse.Applied),
        N("Browser", "SearchPageSize", "Taille d’une page LDAP", 250, 10, 1000, "Taille des pages demandées au contrôleur.", ConfigUse.Applied),
        N("Browser", "SearchServerTimeLimitSeconds", "Délai côté contrôleur", 60, 5, 600, "Délai accordé au contrôleur pour une recherche.", ConfigUse.Applied),

        N("Index", "FullRebuildDays", "Reconstruction complète", 7, 1, 90, "Âge au-delà duquel l’index local est relu en entier.", ConfigUse.Applied),
        N("Index", "BudgetMs", "Budget d’une lecture de l’index", 1200000, 30000, 7200000, "Budget de lecture progressive avec conservation des pages acquittées.", ConfigUse.Applied),
        N("Index", "StartupDeltaMaxAgeMinutes", "Âge conseillé à l’ouverture", 30, 1, 525600, "Avis local de fraîcheur ; aucune lecture AD automatique à l’ouverture.", ConfigUse.Applied),
        N("Index", "MaxObjects", "Objets au plus", 0, 0, 300000, "0 : plafond de sécurité de 300 000 objets ; un quota inférieur arrête la lecture en signalant explicitement sa couverture partielle.", ConfigUse.Applied),

        T("LocalStore", "Mode", "Emplacement des données", "Compatible", "Compatible, UserLocal (profil local) ou Portable (à côté de l’exe). Mode résolu au démarrage et affiché avec la base active.", ConfigUse.Applied, "Compatible", "UserLocal", "Portable"),
        T("LocalStore", "DatabaseFile", "Nom du fichier de base", "Domenia.db", "Nom .db local appliqué lors de la résolution de la base ; un chemin ou un nom hors contrat est refusé.", ConfigUse.Applied),
        N("LocalStore", "DatabaseBusyTimeoutMs", "Attente d’un verrou SQLite", 2500, 100, 5000, "Attente d’un verrou de la base avant de dire « base occupée » ; appliquée aux connexions de la session au démarrage.", ConfigUse.Applied),
        N("LocalStore", "BackupTimeoutSeconds", "Délai d’une sauvegarde", 30, 5, 600, "Budget de copie, attente de l’écrivain comprise, après la vidange distincte de 120 s au plus ; contrôlé entre les étapes SQLite et les blocs de fichier. Appliqué au démarrage.", ConfigUse.Applied),
        N("LocalStore", "DatabaseBackupCount", "Copies gardées par défaut", 7, 2, 30, "Défaut administrateur ; le réglage « Copies à conserver » le remplace.", ConfigUse.Applied),

        N("UserMachineLink", "ProbeTimeoutSeconds", "Délai d’une détection", 25, 5, 300, "Délai de la détection de l’utilisateur d’un poste.", ConfigUse.Applied),
        N("UserMachineLink", "MinimumConfidence", "Identité confirmée", 100, 100, 100, "V2 exige la preuve de l’identité AD avant de proposer une association ; 100 désigne cette exigence, pas un score calculé. L’ancien seuil heuristique ne peut l’affaiblir.", ConfigUse.ByConstruction),
        N("UserMachineLink", "SecurityLogDays", "Profondeur du journal Sécurité", 14, 1, 90, "Jours lus dans le journal Sécurité quand il est autorisé.", ConfigUse.Applied),
    ];

    /// <summary>Policies admitted for an interface element (Default, Disabled, Hidden).</summary>
    public static ImmutableArray<string> GuiPolicies { get; } = ["Default", "Disabled", "Hidden"];

    private static string UseLabel(ConfigUse use) => use switch
    {
        ConfigUse.Applied => "Appliqué par Domenia 2",
        ConfigUse.ByConstruction => "Garanti par Domenia 2 (par construction)",
        _ => "S’appliquera avec la fonction concernée",
    };

    /// <summary>Report from the bytes of the file (null when absent). Never throws for a bad file: it is reported, defaults apply.</summary>
    public static ConfigurationReport Read(byte[]? bytes, string fileLabel)
    {
        ArgumentNullException.ThrowIfNull(fileLabel);
        Dictionary<string, Dictionary<string, JsonElement>>? sections = null;
        string state;
        string? problem = null;
        var unknownSections = new List<string>();
        JsonDocument? document = null;
        try
        {
            if (bytes is null)
            {
                state = "absent";
            }
            else if (bytes.Length > LegacyConfiguration.MaxBytes)
            {
                state = "invalid";
                problem = "fichier de plus de 1 Mo";
            }
            else
            {
                var span = bytes.AsSpan();
                if (span.StartsWith("\uFEFF"u8))
                {
                    span = span[3..];
                }
                try
                {
                    document = JsonDocument.Parse(span.ToArray(), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
                    (sections, problem) = Index(document.RootElement, unknownSections);
                    state = problem is null ? "read" : "invalid";
                    if (problem is not null)
                    {
                        sections = null;
                    }
                }
                catch (JsonException)
                {
                    state = "invalid";
                    problem = "JSON illisible";
                }
            }
            var entries = Catalog.Select(d => Entry(d, sections)).ToList();
            void LimitBy(string key, int limit)
            {
                var at = entries.FindIndex(e => e.Section == "Async" && e.Key == key);
                var entry = entries[at];
                if (int.Parse(entry.Value, CultureInfo.InvariantCulture) > limit)
                    entries[at] = entry with { Value = limit.ToString(CultureInfo.InvariantCulture), Source = "clamped", SourceLabel = "Borné par les autres budgets effectifs", Tone = Tone.Warn };
            }
            var indexBudget = entries.FindIndex(e => e.Section == "Index" && e.Key == "BudgetMs");
            if (entries[indexBudget].Value == "240000")
                entries[indexBudget] = entries[indexBudget] with { Value = "1200000", Source = "clamped", SourceLabel = "Ancien défaut porté au budget V2", Tone = Tone.Info };
            var threads = int.Parse(entries.Single(e => e.Section == "Async" && e.Key == "MaxThreads").Value, CultureInfo.InvariantCulture);
            LimitBy("ReservedForeground", Math.Max(0, threads - 1));
            var hard = int.Parse(entries.Single(e => e.Section == "Async" && e.Key == "WriteHardTimeoutSeconds").Value, CultureInfo.InvariantCulture);
            LimitBy("WriteSoftTimeoutSeconds", hard);
            var report = Sections.Select(s =>
            {
                var list = entries.Where(e => e.Section == s.Id).ToImmutableArray();
                return new ConfigSection(s.Id, s.Label, s.Description, list, list.Count(e => e.Source != "default"));
            }).Where(s => s.Entries.Length > 0).ToImmutableArray();
            var gui = GuiPolicy(sections);
            var expert = entries.First(e => e.Section == "UI" && e.Key == "AllowExpertProfile").Value == "true";
            var notes = new List<string>
            {
                "Les valeurs sont bornées à la lecture : une valeur hors limites est ramenée dans ses bornes et signalée.",
                "Une valeur vide ou absente garde le défaut ; un nom présent deux fois avec une casse différente rend le fichier illisible.",
                "Le fichier est lu au démarrage ; une modification s’applique au prochain lancement de Domenia.",
            };
            if (state == "invalid")
            {
                notes.Insert(0, "Fichier illisible (" + problem + ")" + FrenchText.Colon + "les valeurs par défaut s’appliquent pour cette session, y compris les réglages de sécurité et d’accès distant.");
            }
            return new ConfigurationReport(state, fileLabel, problem, report, gui, expert, entries.Count(e => e.Source is "file" or "clamped"), [.. unknownSections], [.. notes]);
        }
        finally
        {
            document?.Dispose();
        }
    }

    private static (Dictionary<string, Dictionary<string, JsonElement>>?, string?) Index(JsonElement root, List<string> unknownSections)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return (null, "objet JSON attendu");
        }
        var sections = new Dictionary<string, Dictionary<string, JsonElement>>(StringComparer.OrdinalIgnoreCase);
        foreach (var section in root.EnumerateObject())
        {
            if (sections.ContainsKey(section.Name))
            {
                return (null, "section " + section.Name + " en double");
            }
            var values = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
            if (section.Value.ValueKind == JsonValueKind.Object)
            {
                foreach (var key in section.Value.EnumerateObject())
                {
                    if (!values.TryAdd(key.Name, key.Value.Clone()))
                    {
                        return (null, "clé " + section.Name + "." + key.Name + " en double");
                    }
                }
            }
            sections[section.Name] = values;
            if (!Sections.Any(s => string.Equals(s.Id, section.Name, StringComparison.OrdinalIgnoreCase))
                && !string.Equals(section.Name, "GuiElementPolicy", StringComparison.OrdinalIgnoreCase))
            {
                unknownSections.Add(section.Name);
            }
        }
        return (sections, null);
    }

    private static ConfigEntry Entry(ConfigDefinition d, Dictionary<string, Dictionary<string, JsonElement>>? sections)
    {
        string? bounds = d.Minimum is int min && d.Maximum is int max ? FrenchText.Integer(min) + " à " + FrenchText.Integer(max) : d.Choices.Length > 0 ? string.Join(", ", d.Choices) : null;
        ConfigEntry Make(string value, string source, string sourceLabel, Tone tone) =>
            new(d.Section, d.Key, d.Label, value, d.Default, source, sourceLabel, tone, bounds, d.Effect, d.Use switch { ConfigUse.Applied => "applied", ConfigUse.ByConstruction => "byConstruction", _ => "planned" }, UseLabel(d.Use));
        if (sections is null || !sections.TryGetValue(d.Section, out var values) || !values.TryGetValue(d.Key, out var raw)
            || raw.ValueKind == JsonValueKind.Null || (raw.ValueKind == JsonValueKind.String && raw.GetString()!.Length == 0))
        {
            return Make(d.Default, "default", "Défaut", Tone.Off);
        }
        if (d.Use == ConfigUse.ByConstruction)
            return Make(d.Default, "construction", "Protection obligatoire dans Domenia 2", raw.ValueKind == JsonValueKind.True ? Tone.Info : Tone.Warn);
        switch (d.Kind)
        {
            case ConfigValueKind.Boolean:
                if (d.Section == "UI" && d.Key == "AllowExpertProfile" && raw.ValueKind == JsonValueKind.Number && raw.TryGetInt32(out var flag) && flag is 0 or 1)
                    return Make(flag == 1 ? "true" : "false", "file", "Fichier (compatibilité D1)", Tone.Info);
                return raw.ValueKind is JsonValueKind.True or JsonValueKind.False
                    ? Make(raw.ValueKind == JsonValueKind.True ? "true" : "false", "file", "Fichier", Tone.Info)
                    : Make(d.Default, "invalid", "Valeur illisible : défaut", Tone.Warn);
            case ConfigValueKind.Integer:
                long number;
                if (raw.ValueKind == JsonValueKind.Number && raw.TryGetInt64(out number)) { }
                else if (raw.ValueKind == JsonValueKind.String && long.TryParse(raw.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out number)) { }
                else
                {
                    return Make(d.Default, "invalid", "Valeur illisible : défaut", Tone.Warn);
                }
                var clamped = Math.Clamp(number, d.Minimum ?? long.MinValue, d.Maximum ?? long.MaxValue);
                return clamped == number
                    ? Make(number.ToString(CultureInfo.InvariantCulture), "file", "Fichier", Tone.Info)
                    : Make(clamped.ToString(CultureInfo.InvariantCulture), "clamped", "Fichier, ramené dans ses bornes", Tone.Warn);
            default:
                if (raw.ValueKind != JsonValueKind.String)
                {
                    return Make(d.Default, "invalid", "Valeur illisible : défaut", Tone.Warn);
                }
                var text = raw.GetString()!.Trim();
                if (d.Choices.Length > 0)
                {
                    var choice = d.Choices.FirstOrDefault(c => string.Equals(c, text, StringComparison.OrdinalIgnoreCase));
                    return choice is null ? Make(d.Default, "invalid", "Valeur inconnue : défaut", Tone.Warn) : Make(choice, "file", "Fichier", Tone.Info);
                }
                return Make(text, "file", "Fichier", Tone.Info);
        }
    }

    private static ImmutableArray<GuiPolicyEntry> GuiPolicy(Dictionary<string, Dictionary<string, JsonElement>>? sections)
    {
        if (sections is null || !sections.TryGetValue("GuiElementPolicy", out var values))
        {
            return [];
        }
        return GuiElementPolicies.Parse(values);
    }

    public static bool Boolean(ConfigurationReport report, string section, string key, bool fallback)
    {
        var entry = report.Sections.SelectMany(s => s.Entries).FirstOrDefault(e => e.Section == section && e.Key == key);
        return entry is null ? fallback : entry.Value == "true";
    }

    /// <summary>Effective value of one integer setting of a report (default when absent or unreadable).</summary>
    public static int Integer(ConfigurationReport report, string section, string key, int fallback)
    {
        ArgumentNullException.ThrowIfNull(report);
        var entry = report.Sections.SelectMany(s => s.Entries).FirstOrDefault(e => e.Section == section && e.Key == key);
        return entry is not null && int.TryParse(entry.Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : fallback;
    }
}
