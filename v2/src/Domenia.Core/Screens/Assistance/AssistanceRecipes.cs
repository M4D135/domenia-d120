using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Kind of directory object one step of a recipe concerns (Domenia 1: Utilisateur, Machine).</summary>
public enum AssistanceSubject
{
    User,
    Computer,
}

/// <summary>
/// One read of the closed list (Domenia 1 Get-DomeniaAssistanceActions): the only reads a recipe may start, each bound to its
/// pinned operation and to the kinds of object it accepts. The operation always comes from this list, never from the page.
/// </summary>
public sealed record AssistanceAction(string Id, string Operation, string Label, ImmutableArray<AssistanceSubject> Subjects);

/// <summary>
/// Screen where a step shows its information: route of the page (« fiche », « poste », « audit ») and its section, in the
/// vocabulary of that screen (route contract of docs/ops/assistance.md § 11.1: Fiche « tab », Poste « onglet », Audit AD
/// « tab=objet » and « vue »).
/// </summary>
public sealed record AssistanceView(string Screen, string Section, string Label);

/// <summary>
/// One step of a recipe: what it reads, why, at what cost, for which kind of object, whether it is optional and whether it needs
/// the administration rights of the workstation. A step without action only opens its view (nothing is read).
/// </summary>
public sealed record AssistanceStep(
    string Id,
    string Title,
    AssistanceSubject Subject,
    string? Action,
    AssistanceView View,
    string Reads,
    string Why,
    string Cost,
    bool Optional = false,
    bool Privileged = false);

/// <summary>A guided path for one symptom. <see cref="Added"/> marks the recipes added by Domenia 2.</summary>
public sealed record AssistanceRecipe(string Id, string Title, string Symptom, string Icon, bool Added, ImmutableArray<AssistanceStep> Steps);

/// <summary>Outcome of a launched step: data read, read refused by the target, or failure (nothing is ever relaunched).</summary>
public enum StepOutcome
{
    Read,
    Refused,
    Failed,
}

/// <summary>Where a step stands for the current subjects.</summary>
public enum StepPhase
{
    NeedSubject,
    ViewOnly,
    Ready,
    Read,
    Refused,
    Failed,
}

/// <summary>Last launch of a step for one object of the session: when, how it ended and what it read.</summary>
public sealed record StepLaunch(DateTimeOffset At, StepOutcome Outcome, StepReading? Reading, string? ErrorCode, string? ErrorMessage);

/// <summary>State of one step row (Domenia 1 Get-DomeniaAssistanceStepState). A launched step says when it ran, never a verdict.</summary>
public sealed record StepState(StepPhase Phase, bool CanRun, bool CanOpen, string Text, Tone Tone, DateTimeOffset? At);

/// <summary>
/// Support recipes (Domenia 1 Domenia-Assistance.Model.ps1, point 110): four guided paths of Domenia 1 and three added by
/// Domenia 2 (printing, network drive, remote access). Each step names the read of the closed list it uses, what that read
/// collects, why it is useful and what it costs. No step chains to the next one and none writes. Pure data and rules.
/// </summary>
public static class AssistanceRecipes
{
    private const string ReachReads = "Réponse au ping et ouverture des ports d’administration du poste.";
    private const string FallbackCost = " Repli par tâche SYSTEM seulement si déjà autorisé pour ce poste dans la page Poste ; jusqu’à 45 secondes supplémentaires, arrêt et nettoyage vérifiés séparément.";
    private const string ReachCost = "Lecture réseau et CIM du poste, budget de 45 secondes." + FallbackCost;
    private const string CimCost = "Lecture CIM du poste, 10 à 60 secondes ; droits d’administration du poste.";
    private const string GroupsCost = "Lectures LDAP bornées, 10 secondes au plus.";
    private const string RegistryCost = "Lecture du registre du poste ; droits d’administration du poste." + FallbackCost;
    private const string LockoutReads = "Journal Sécurité de l’émulateur PDC : événements 4740 de ce seul compte, 7 jours, 200 au plus.";
    private const string LockoutCost = "Une lecture du journal du contrôleur ; droit de lecture du journal Sécurité requis.";

    /// <summary>Operations of Domenia 1 that only read (Get-DomeniaOperationEffect = Read): a recipe may name nothing else.</summary>
    public static ImmutableHashSet<string> ReadOperations { get; } = ImmutableHashSet.Create(StringComparer.Ordinal,
        "LockoutDiagnosis", "PasswordPolicyRead", "GroupPathRead", "GpoLinksRead", "GpoAppliedRead", "MachineIdentityRead",
        "ComputerDiagnostics", "ComputerInventory", "SoftwareInventory", "SessionsList");

    /// <summary>The closed list of reads a step may start.</summary>
    public static ImmutableArray<AssistanceAction> Actions { get; } =
    [
        new("lockoutEvents", "LockoutDiagnosis", "Verrouillages du compte (événements 4740)", [AssistanceSubject.User]),
        new("passwordPolicy", "PasswordPolicyRead", "Stratégie de mot de passe applicable", [AssistanceSubject.User]),
        new("groups", "GroupPathRead", "Groupes directs et imbriqués", [AssistanceSubject.User, AssistanceSubject.Computer]),
        new("gpoLinks", "GpoLinksRead", "Liens GPO des OU parentes", [AssistanceSubject.User, AssistanceSubject.Computer]),
        new("gpoApplied", "GpoAppliedRead", "Stratégies appliquées sur le poste (RSoP)", [AssistanceSubject.Computer]),
        new("machineIdentity", "MachineIdentityRead", "Identité du poste (DNS et CIM)", [AssistanceSubject.Computer]),
        new("diagnostics", "ComputerDiagnostics", "Diagnostic réseau du poste", [AssistanceSubject.Computer]),
        new("inventory", "ComputerInventory", "Inventaire rapide", [AssistanceSubject.Computer]),
        new("inventoryDeep", "ComputerInventory", "Inventaire complet", [AssistanceSubject.Computer]),
        new("software", "SoftwareInventory", "Logiciels installés", [AssistanceSubject.Computer]),
        new("sessions", "SessionsList", "Sessions ouvertes", [AssistanceSubject.Computer]),
    ];

    // Fiche: « tab » of the screen (onglet Compte). Audit AD: the « Objet » tab and its inner view (« vue »), the internal tabs
    // Domenia 1 opened (AuditTab TabAdAuditPolicy, Machine, Groupes, Gpo).
    private static readonly AssistanceView UserView = new("fiche", "compte", "Fiche du compte");
    private static readonly AssistanceView AuditPolicy = new("audit", "motdepasse", "Audit AD · Stratégie de mot de passe");
    private static readonly AssistanceView AuditMachine = new("audit", "poste", "Audit AD · Identité du poste");
    private static readonly AssistanceView AuditGroups = new("audit", "groupes", "Audit AD · Groupes");
    private static readonly AssistanceView AuditGpo = new("audit", "gpo", "Audit AD · Stratégies de groupe");
    // Sections of the Poste screen accept the former tabs of Domenia 1 (TabComputerHealth…) and these short names.
    private static readonly AssistanceView Health = new("poste", "reseau", "Poste · Diagnostic réseau");
    private static readonly AssistanceView Inventory = new("poste", "materiel", "Poste · Inventaire");
    private static readonly AssistanceView Software = new("poste", "logiciels", "Poste · Logiciels");
    private static readonly AssistanceView Sessions = new("poste", "sessions", "Poste · Sessions");

    private static AssistanceStep AccountState() => new("account", "État du compte", AssistanceSubject.User, null, UserView,
        "Rien de nouveau : état du compte, verrouillage, échéance du mot de passe et échecs, déjà lus à l’ouverture de la fiche.",
        "Un compte désactivé, expiré ou verrouillé, ou un mot de passe échu, empêche toute ouverture de session.", "Aucune lecture.");

    private static AssistanceStep Lockouts(string why, bool optional = false) => new("lockouts", "Verrouillages des 7 derniers jours",
        AssistanceSubject.User, "lockoutEvents", UserView, LockoutReads, why, LockoutCost, optional);

    private static AssistanceStep Policy(string why, bool optional) => new("policy", "Stratégie de mot de passe applicable", AssistanceSubject.User,
        "passwordPolicy", AuditPolicy, "Stratégie fine applicable (msDS-ResultantPSO), stratégie du domaine et échéance calculée par le contrôleur ; aucun mot de passe.",
        why, "Trois à cinq lectures LDAP bornées.", optional);

    private static AssistanceStep Reach(string title, string why) => new("reach", title, AssistanceSubject.Computer, "diagnostics", Health, ReachReads, why, ReachCost);

    private static AssistanceStep UserGroups(string why, bool optional) => new("groups-user", "Groupes de l’utilisateur", AssistanceSubject.User, "groups", AuditGroups,
        "Groupes du compte, directs et imbriqués, bornés à 2 000.", why, GroupsCost, optional);

    /// <summary>The recipes, in the order of the list.</summary>
    public static ImmutableArray<AssistanceRecipe> All { get; } =
    [
        new("logon", "Connexion impossible", "L’utilisateur ne peut pas ouvrir de session : mot de passe refusé, compte bloqué ou poste qui n’authentifie plus.", "key", false,
        [
            AccountState(),
            Lockouts("Trouver le poste qui verrouille le compte : session, lecteur réseau ou service gardant un ancien mot de passe."),
            Policy("Comprendre une expiration ou un seuil de verrouillage propres à ce compte.", optional: true),
            Reach("Poste joignable", "Un poste hors réseau ne joint pas le contrôleur et refuse les nouveaux mots de passe."),
            new("identity", "Identité du poste", AssistanceSubject.Computer, "machineIdentity", AuditMachine,
                "Résolution DNS du nom du poste depuis ce poste et nom renvoyé par le poste (CIM).",
                "Un enregistrement DNS périmé ou un poste renommé casse la relation avec le domaine.",
                "Une résolution DNS et une lecture CIM ; droits d’administration du poste.", Privileged: true),
            new("clock", "Heure et démarrage du poste", AssistanceSubject.Computer, "inventory", Inventory,
                "Inventaire rapide : système, dernier démarrage et écart d’horloge avec le contrôleur.",
                "Au-delà de 5 minutes d’écart, Kerberos refuse l’ouverture de session.", CimCost, Privileged: true),
        ]),
        new("slow", "Poste lent", "Le poste répond lentement, à l’ouverture de session ou en continu.", "gauge", false,
        [
            Reach("Réseau du poste", "Une latence réseau ou des ports filtrés ralentissent l’ouverture de session et les partages."),
            new("inventory", "Mémoire, disques et démarrage", AssistanceSubject.Computer, "inventory", Inventory,
                "Inventaire rapide : mémoire, processeur, disques et durée depuis le dernier démarrage.",
                "Peu de mémoire libre, un disque plein ou des semaines sans redémarrage expliquent souvent la lenteur.", CimCost + FallbackCost, Privileged: true),
            new("sessions", "Sessions ouvertes", AssistanceSubject.Computer, "sessions", Sessions, "Sessions console et RDP du poste, sans fermeture.",
                "Plusieurs sessions ou une session déconnectée occupent la mémoire.", "Une lecture des sessions du poste.", Optional: true),
            new("deep", "Inventaire complet", AssistanceSubject.Computer, "inventoryDeep", Inventory, "Inventaire complet : lectures supplémentaires du poste.",
                "Approfondir seulement si l’inventaire rapide n’explique pas la lenteur.", "Plus long que l’inventaire rapide ; droits d’administration du poste." + FallbackCost,
                Optional: true, Privileged: true),
        ]),
        new("disk", "Manque d’espace", "Le poste signale un disque plein ou une application refuse d’enregistrer.", "disk", false,
        [
            new("inventory", "Espace des disques", AssistanceSubject.Computer, "inventory", Inventory, "Inventaire rapide : disques logiques, taille et espace libre.",
                "Mesurer l’espace restant et le disque concerné avant toute action.", CimCost + FallbackCost, Privileged: true),
            new("sessions", "Sessions et profils ouverts", AssistanceSubject.Computer, "sessions", Sessions, "Sessions console et RDP du poste, sans fermeture.",
                "Des sessions inactives gardent des profils et des fichiers temporaires.", "Une lecture des sessions du poste.", Optional: true),
            new("software", "Logiciels installés", AssistanceSubject.Computer, "software", Software, "Logiciels installés lus dans le registre, sans effet de bord MSI.",
                "Repérer un logiciel volumineux ou inattendu.", RegistryCost, Optional: true, Privileged: true),
        ]),
        new("software", "Logiciel absent", "Un logiciel attendu n’est pas installé, ou pas dans la bonne version.", "layers", false,
        [
            new("software", "Logiciels installés", AssistanceSubject.Computer, "software", Software,
                "Logiciels installés lus dans le registre : nom, éditeur et version, sans effet de bord MSI.",
                "Vérifier si le logiciel est présent, et dans quelle version.", RegistryCost, Privileged: true),
            new("groups", "Groupes du poste", AssistanceSubject.Computer, "groups", AuditGroups, "Groupes du poste, directs et imbriqués, bornés à 2 000.",
                "Un logiciel distribué par groupe n’arrive que si le poste en est membre.", GroupsCost),
            new("gpo", "Liens GPO du poste", AssistanceSubject.Computer, "gpoLinks", AuditGpo, "Liens GPO des OU au-dessus du poste et du domaine.",
                "Un déploiement par stratégie de groupe dépend des liens et de l’héritage.", "Une lecture LDAP par niveau d’OU."),
            new("gpo-applied", "Stratégies appliquées sur le poste", AssistanceSubject.Computer, "gpoApplied", AuditGpo,
                "Dernier résultat des stratégies enregistré par le poste (RSoP), sans actualisation.",
                "Vérifier que la stratégie de déploiement a réellement été appliquée.", "Lecture CIM du poste ; droits d’administration du poste.",
                Optional: true, Privileged: true),
            UserGroups("Un logiciel distribué à des utilisateurs dépend de leurs groupes.", optional: true),
        ]),
        new("printer", "Impression impossible", "L’imprimante n’apparaît pas sur le poste, ou les documents restent en attente.", "printer", true,
        [
            Reach("Poste joignable", "Un poste hors réseau ne joint ni le serveur d’impression ni le contrôleur."),
            new("groups", "Groupes du poste", AssistanceSubject.Computer, "groups", AuditGroups, "Groupes du poste, directs et imbriqués, bornés à 2 000.",
                "Une imprimante déployée par groupe n’arrive que si le poste en est membre.", GroupsCost),
            new("gpo", "Liens GPO du poste", AssistanceSubject.Computer, "gpoLinks", AuditGpo, "Liens GPO des OU au-dessus du poste et du domaine.",
                "Les imprimantes sont souvent déployées par stratégie de groupe (préférences).", "Une lecture LDAP par niveau d’OU."),
            new("gpo-applied", "Stratégies appliquées sur le poste", AssistanceSubject.Computer, "gpoApplied", AuditGpo,
                "Dernier résultat des stratégies enregistré par le poste (RSoP), sans actualisation.",
                "Vérifier que la stratégie de déploiement des imprimantes a bien été appliquée.", "Lecture CIM du poste ; droits d’administration du poste.",
                Optional: true, Privileged: true),
            new("drivers", "Pilotes et logiciels d’impression", AssistanceSubject.Computer, "software", Software,
                "Logiciels installés lus dans le registre : pilotes et utilitaires d’impression, sans effet de bord MSI.",
                "Un pilote absent ou trop ancien empêche l’impression.", RegistryCost, Optional: true, Privileged: true),
            UserGroups("Une imprimante attribuée aux utilisateurs dépend de leurs groupes.", optional: true),
        ]),
        new("drive", "Lecteur réseau absent", "Un lecteur réseau attendu n’est pas monté, ou il demande sans cesse un mot de passe.", "folder", true,
        [
            AccountState(),
            Lockouts("Un lecteur réseau qui garde un ancien mot de passe verrouille le compte à chaque tentative.", optional: true),
            UserGroups("L’accès au partage et le montage du lecteur dépendent des groupes du compte.", optional: false),
            new("gpo-user", "Liens GPO de l’utilisateur", AssistanceSubject.User, "gpoLinks", AuditGpo, "Liens GPO des OU au-dessus du compte et du domaine.",
                "Les lecteurs réseau sont souvent montés par une stratégie de groupe utilisateur.", "Une lecture LDAP par niveau d’OU."),
            Reach("Poste joignable", "Sans réseau vers le serveur de fichiers, le lecteur reste déconnecté."),
            new("sessions", "Sessions ouvertes", AssistanceSubject.Computer, "sessions", Sessions, "Sessions console et RDP du poste, sans fermeture.",
                "Une session restée ouverte garde d’anciennes connexions SMB (erreur 1219).", "Une lecture des sessions du poste.", Optional: true),
        ]),
        new("remote", "Accès distant impossible", "L’utilisateur ne parvient pas à se connecter à distance (VPN, tunnel ou bureau à distance).", "domain", true,
        [
            AccountState(),
            Policy("Un mot de passe expiré est refusé par la passerelle avant toute ouverture de session.", optional: false),
            UserGroups("L’accès distant est souvent réservé aux membres d’un groupe dédié.", optional: false),
            Lockouts("Des essais répétés depuis un téléphone ou un portable verrouillent le compte.", optional: true),
            new("identity", "Identité du poste", AssistanceSubject.Computer, "machineIdentity", AuditMachine,
                "Résolution DNS du nom du poste depuis ce poste et nom renvoyé par le poste (CIM).",
                "Un tunnel ouvert avant la connexion exige un compte ordinateur sain.",
                "Une résolution DNS et une lecture CIM ; droits d’administration du poste.", Optional: true, Privileged: true),
            new("clock", "Heure du poste", AssistanceSubject.Computer, "inventory", Inventory,
                "Inventaire rapide : système, dernier démarrage et écart d’horloge avec le contrôleur.",
                "Un écart d’horloge de plus de 5 minutes fait échouer Kerberos à travers le tunnel.", CimCost, Optional: true, Privileged: true),
        ]),
    ];

    public static AssistanceRecipe? Find(string? id) => All.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal));

    public static AssistanceAction? FindAction(string? id) => Actions.FirstOrDefault(a => string.Equals(a.Id, id, StringComparison.Ordinal));

    public static string SubjectLabel(AssistanceSubject subject) => subject == AssistanceSubject.Computer ? "Poste" : "Utilisateur";

    /// <summary>
    /// Contract of the recipes (Domenia 1 Test-DomeniaAssistanceRecipes, TRV-184): unique identifiers, a symptom, at least one
    /// step, every step explained (what, why, cost), every action allowed, bound to a read operation and to the kind of object
    /// it accepts. Returns the problems found; none means the recipes may be offered.
    /// </summary>
    public static ImmutableArray<string> Validate(IEnumerable<AssistanceRecipe> recipes)
    {
        ArgumentNullException.ThrowIfNull(recipes);
        var problems = ImmutableArray.CreateBuilder<string>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var recipe in recipes)
        {
            if (recipe is null)
            {
                continue;
            }
            var recipeId = recipe.Id ?? "";
            if (recipeId.Length == 0 || !ids.Add(recipeId))
            {
                problems.Add("Recette sans identifiant unique" + FrenchText.Colon + recipeId);
            }
            if (string.IsNullOrWhiteSpace(recipe.Symptom))
            {
                problems.Add(recipeId + FrenchText.Colon + "symptôme absent");
            }
            if (recipe.Steps.IsDefaultOrEmpty)
            {
                problems.Add(recipeId + FrenchText.Colon + "aucune étape");
                continue;
            }
            var stepIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var step in recipe.Steps)
            {
                var stepId = step.Id ?? "";
                if (stepId.Length == 0 || !stepIds.Add(stepId))
                {
                    problems.Add(recipeId + FrenchText.Colon + "étape sans identifiant unique " + stepId);
                }
                foreach (var (field, value) in new[] { ("Title", step.Title), ("Reads", step.Reads), ("Why", step.Why), ("Cost", step.Cost) })
                {
                    if (string.IsNullOrWhiteSpace(value))
                    {
                        problems.Add(recipeId + "/" + stepId + FrenchText.Colon + field + " absent");
                    }
                }
                if (step.Action is { } actionId)
                {
                    var action = FindAction(actionId);
                    if (action is null)
                    {
                        problems.Add(recipeId + "/" + stepId + FrenchText.Colon + "action non autorisée " + actionId);
                        continue;
                    }
                    if (!ReadOperations.Contains(action.Operation))
                    {
                        problems.Add(recipeId + "/" + stepId + FrenchText.Colon + action.Operation + " n’est pas une lecture");
                    }
                    if (!action.Subjects.Contains(step.Subject))
                    {
                        problems.Add(recipeId + "/" + stepId + FrenchText.Colon + "type d’objet non admis par " + actionId);
                    }
                }
                else if (step.View is null || string.IsNullOrWhiteSpace(step.View.Screen))
                {
                    problems.Add(recipeId + "/" + stepId + FrenchText.Colon + "ni lecture ni vue à ouvrir");
                }
            }
        }
        return problems.ToImmutable();
    }

    /// <summary>
    /// What the whole recipe would collect if every step were launched, said before the first click (Domenia 1
    /// Get-DomeniaAssistancePlanText), with French plurals.
    /// </summary>
    public static string PlanText(AssistanceRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var steps = recipe.Steps;
        var reads = steps.Where(s => s.Action is not null).ToList();
        var none = steps.Length - reads.Count;
        var computer = reads.Count(s => s.Subject == AssistanceSubject.Computer);
        var user = reads.Count(s => s.Subject == AssistanceSubject.User);
        var privileged = reads.Count(s => s.Privileged);
        var optional = steps.Count(s => s.Optional);
        // « 6 étapes, dont 2 lectures pour le compte, 3 pour le poste et 1 sans lecture. » — no colon: the page shows the plan
        // under its own title (« Avant le premier clic »).
        var parts = new List<string>();
        if (user > 0)
        {
            parts.Add(AssistanceText.Count(user, "lecture pour le compte", "lectures pour le compte"));
        }
        if (computer > 0)
        {
            parts.Add(user > 0 ? FrenchText.Integer(computer) + FrenchText.Nbsp + "pour le poste" : AssistanceText.Count(computer, "lecture pour le poste", "lectures pour le poste"));
        }
        if (none > 0)
        {
            parts.Add(FrenchText.Integer(none) + FrenchText.Nbsp + "sans lecture");
        }
        var text = AssistanceText.Count(steps.Length, "étape", "étapes") + (parts.Count > 0 ? ", dont " + AssistanceText.List(parts) : "") + ".";
        if (privileged > 0)
        {
            text += " " + FrenchText.Integer(privileged) + FrenchText.Nbsp + (privileged > 1 ? "demandent" : "demande") + " les droits d’administration du poste.";
        }
        if (optional > 0)
        {
            text += " " + AssistanceText.Count(optional, "étape facultative", "étapes facultatives") + ".";
        }
        return text + " Aucune étape ne part seule" + FrenchText.Nbsp + "; aucune n’écrit.";
    }

    /// <summary>
    /// Whether one step can run for the chosen subjects, and the text of its row. A launched step says when it ran and how it
    /// ended (its result is shown with it), never that the problem is solved; it can be launched again only by a new click.
    /// </summary>
    public static StepState State(AssistanceStep step, bool subjectChosen, StepLaunch? launch, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(step);
        ArgumentNullException.ThrowIfNull(zone);
        if (!subjectChosen)
        {
            return new StepState(StepPhase.NeedSubject, false, false,
                step.Subject == AssistanceSubject.User ? "Sélectionnez le compte concerné." : "Sélectionnez le poste concerné.", Tone.Off, null);
        }
        if (step.Action is null)
        {
            return new StepState(StepPhase.ViewOnly, false, true, "Sans lecture" + FrenchText.Colon + "ouvrir la vue", Tone.Info, null);
        }
        if (launch is null)
        {
            return new StepState(StepPhase.Ready, true, true, "À lancer", Tone.Off, null);
        }
        var time = TimeZoneInfo.ConvertTime(launch.At, zone).ToString("HH':'mm", CultureInfo.InvariantCulture);
        return launch.Outcome switch
        {
            StepOutcome.Read => new StepState(StepPhase.Read, true, true, "Lue à " + time + FrenchText.Colon + "résultat ci-dessous", Tone.Info, launch.At),
            StepOutcome.Refused => new StepState(StepPhase.Refused, true, true, "Refusée à " + time + FrenchText.Colon + "rien n’a été lu", Tone.Alert, launch.At),
            _ => new StepState(StepPhase.Failed, true, true, "Échec à " + time + FrenchText.Colon + "rien n’est relancé seul", Tone.Warn, launch.At),
        };
    }
}
