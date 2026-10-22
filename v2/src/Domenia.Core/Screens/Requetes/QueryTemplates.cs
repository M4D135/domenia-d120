using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Queries;

/// <summary>One delivered model: the recipe, its library category and its description (limits recalled).</summary>
public sealed record QueryTemplate(QueryRecipe Recipe, string Category, string Description);

/// <summary>
/// Delivered models (Domenia 1 Get-DomeniaQueryTemplates, kept whole: filters, distributions, cross-checks, generated
/// coverage, distribution and coded-state models, thresholds and parameterised models), plus the user and group models of
/// Domenia 2. Identifiers start with « template. »; duplicate definitions or titles are left out. No remote query here.
/// </summary>
public static partial class QueryTemplates
{
    public const string Prefix = "template.";
    private const string Limits = " Évaluation locale des données disponibles ; les valeurs non lues ou périmées restent inconnues.";

    private static readonly Lazy<ImmutableArray<QueryTemplate>> All_ = new(Build, LazyThreadSafetyMode.ExecutionAndPublication);

    public static ImmutableArray<QueryTemplate> All => All_.Value;

    public static QueryTemplate? Find(string? id) => id is null ? null : All_.Value.FirstOrDefault(t => string.Equals(t.Recipe.Id, id, StringComparison.Ordinal));

    private sealed class Builder
    {
        private readonly HashSet<string> signatures = new(StringComparer.Ordinal);
        private readonly HashSet<string> titles = new(StringComparer.OrdinalIgnoreCase);

        public List<QueryTemplate> Items { get; } = [];

        public void Add(QueryTarget target, string id, string name, string category, string description, IEnumerable<QueryClause>? clauses = null, string? groupBy = null,
            QueryJunction junction = QueryJunction.All, IEnumerable<QueryParameter>? parameters = null, QueryNode? expression = null)
        {
            var recipe = new QueryRecipe(QueryRecipe.FormatV3, Prefix + id, name, target, junction, [.. clauses ?? []], groupBy, [], null, null, [.. parameters ?? []], null, expression, null, null);
            recipe = recipe with { Format = recipe.MinimalFormat() };
            var signature = target + "|" + QueryRecipeJson.Write(recipe with { Id = "", Name = "" });
            if (!signatures.Add(signature) || !titles.Add(target + "|" + name))
            {
                return;
            }
            Items.Add(new QueryTemplate(recipe, category, description + Limits));
        }
    }

    private static QueryClause C(string field, QueryOperator op, QueryValue value) => new(field, op, value);

    private static QueryValue T(string text) => QueryValue.FromText(text);

    private static QueryValue N(decimal number) => QueryValue.FromNumber(number);

    private static QueryValue B(bool flag) => QueryValue.FromBoolean(flag);

    private static QueryValue Typed(string coded) => coded[..2] switch
    {
        "b:" => B(coded[2..] == "true"),
        "n:" => N(decimal.Parse(coded[2..], NumberStyles.Float, CultureInfo.InvariantCulture)),
        "t:" => T(coded[2..]),
        "z:" => QueryValue.None,
        _ => throw new InvalidOperationException("Invalid delivered model value."),
    };

    private static IEnumerable<string[]> Lines(string table, int columns) =>
        table.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(l => l.Split('|')).Select(p => p.Length == columns ? p : throw new InvalidOperationException("Invalid delivered model line."));

    private static ImmutableArray<QueryTemplate> Build()
    {
        var b = new Builder();
        const QueryTarget pc = QueryTarget.Computer;
        b.Add(pc, "all", "Tous les postes recensés", "Inventaire général", "Tous les comptes ordinateur du périmètre, actifs et désactivés ; sur le poste choisi, le seul objet sélectionné.");
        b.Add(pc, "stale", "Comptes actifs sans connexion depuis au moins 90 jours", "Comptes et activité AD",
            "Date AD répliquée d’au moins quatre-vingt-dix jours ; exclut les dates non renseignées et ne prouve pas une absence d’utilisation.",
            [C("active", QueryOperator.Equal, B(true)), C("logonBucket", QueryOperator.GreaterOrEqual, N(3)), C("logonBucket", QueryOperator.LessOrEqual, N(4))]);
        foreach (var p in Lines(ComputerRows, 7))
        {
            var op = Enum.Parse<QueryOperator>(p[4]);
            b.Add(pc, p[0], p[2], p[1], p[6], [C(p[3], op, Typed(p[5]))]);
        }
        foreach (var p in Lines(ComputerGroups, 4))
        {
            b.Add(pc, p[0], p[1], "Répartitions", p[3], groupBy: p[2]);
        }
        b.Add(pc, "active.lowdisk", "Comptes actifs avec moins de 10 % libre sur C:", "Vérifications croisées", "Croise l’état AD actif avec un manque d’espace relevé ; une mesure manquante reste inconnue.",
            [C("active", QueryOperator.Equal, B(true)), C("diskFreePercent", QueryOperator.Less, N(10))]);
        b.Add(pc, "active.ended", "Comptes actifs avec support Windows dépassé", "Vérifications croisées", "Priorise les comptes actifs dont la fin de support est connue et dépassée, selon le référentiel livré.",
            [C("active", QueryOperator.Equal, B(true)), C("lifeStatus", QueryOperator.Equal, T("Ended"))]);
        b.Add(pc, "observed.healthyspace", "Inventaire récent avec au moins 20 % libre sur C:", "Vérifications croisées",
            "Inventaire réussi de moins d’un jour et espace libre de prévention ; cela ne constitue pas un diagnostic de santé global.",
            [C("inventoryDays", QueryOperator.Less, N(1)), C("diskFreePercent", QueryOperator.GreaterOrEqual, N(20))]);
        b.Add(pc, "resource.review", "Mémoire faible ou disque peu disponible", "Vérifications croisées",
            "Au moins un seuil de revue atteint : RAM inférieure à 8 Go ou espace C: inférieur à 10 %. Ajustez selon l’usage.",
            [C("ramGB", QueryOperator.Less, N(8)), C("diskFreePercent", QueryOperator.Less, N(10))], junction: QueryJunction.Any);
        // Generated models: coverage of every information, distributions of non numeric ones, every coded state.
        Generated(b, pc);
        foreach (var p in Lines(ComputerThresholds, 2))
        {
            var field = QueryCatalog.Find(pc, p[0]) ?? throw new InvalidOperationException("Threshold on an unknown information.");
            foreach (var text in p[1].Split(','))
            {
                var number = decimal.Parse(text, CultureInfo.InvariantCulture);
                var key = field.Id.ToLowerInvariant().Replace(':', '.');
                b.Add(pc, "threshold." + key + ".lt" + text, field.Name + " : moins de " + text + " " + field.Unit, "Seuils · " + field.Category,
                    "Seuil de triage pour « " + field.Name + " », à adapter aux usages ; une information manquante ne vaut jamais zéro. " + field.Freshness, [C(field.Id, QueryOperator.Less, N(number))]);
                b.Add(pc, "threshold." + key + ".ge" + text, field.Name + " : au moins " + text + " " + field.Unit, "Seuils · " + field.Category,
                    "Seuil de triage pour « " + field.Name + " », à adapter aux usages ; une information manquante ne vaut jamais zéro. " + field.Freshness, [C(field.Id, QueryOperator.GreaterOrEqual, N(number))]);
            }
        }
        Parameterised(b);
        Users(b);
        Groups(b);
        return [.. b.Items];
    }

    private static void Generated(Builder b, QueryTarget target)
    {
        foreach (var field in QueryCatalog.Fields(target))
        {
            var key = (target == QueryTarget.Computer ? "" : target.ToString().ToLowerInvariant() + ".") + field.Id.ToLowerInvariant().Replace(':', '.');
            b.Add(target, "catalog." + key + ".missing", field.Name + " : valeur inconnue", "Couverture des informations",
                "Vérifier la couverture de « " + field.Name + " ». Une valeur inconnue peut être non lue, expirée, refusée ou incomplète ; consultez la fiche locale pour préciser la cause.",
                [C(field.Id, QueryOperator.IsMissing, QueryValue.None)]);
            b.Add(target, "catalog." + key + ".present", field.Name + " : valeur disponible", "Couverture des informations",
                "Vérifier la couverture de « " + field.Name + " ». Une valeur inconnue peut être non lue, expirée, refusée ou incomplète ; consultez la fiche locale pour préciser la cause.",
                [C(field.Id, QueryOperator.IsPresent, QueryValue.None)]);
            if (field.Kind != QueryFieldKind.Number && field.Id is not ("name" or "dn" or "user" or "site" or "sam" or "upn" or "mail" or "displayName" or "telephone" or "employeeId" or "dnsHostName" or "memberOf"))
            {
                b.Add(target, "catalog." + key + ".distribution", field.Name + " : répartition", "Répartitions détaillées",
                    "Répartir les objets par « " + field.Name + " », avec une catégorie séparée pour les valeurs inconnues. Source : " + field.SourceLabel + ".", groupBy: field.Id);
            }
            var index = 0;
            foreach (var choice in field.Choices)
            {
                index++;
                b.Add(target, "catalog." + key + ".state" + index.ToString(CultureInfo.InvariantCulture), field.Name + " : " + choice.Name, "États · " + field.Category,
                    "Repérer la valeur « " + choice.Name + " » de « " + field.Name + " ». La condition porte sur le relevé ou l’attribut enregistré et ne déclenche aucune lecture distante.",
                    [C(field.Id, QueryOperator.Equal, choice.Value)]);
            }
        }
    }

    private static QueryParameter P(string name, string field, QueryValue value, string label, decimal? min = null, decimal? max = null) => new(name, field, value, label, min, max);

    private static void Parameterised(Builder b)
    {
        const QueryTarget pc = QueryTarget.Computer;
        const string category = "Modèles paramétrés";
        b.Add(pc, "param.diskfree", "C: : espace libre sous un seuil à choisir", category,
            "Seuil d’espace libre sur C: saisi dans le formulaire des paramètres, 10 % par défaut ; une mesure absente ou expirée n’est jamais assimilée à zéro.",
            [C("diskFreePercent", QueryOperator.Less, QueryValue.FromParameter("Seuil"))], parameters: [P("Seuil", "diskFreePercent", N(10), "Espace libre minimal sur C:", 0, 100)]);
        b.Add(pc, "param.ram", "Mémoire installée sous un seuil à choisir", category,
            "Seuil de mémoire installée saisi dans le formulaire (8 Go par défaut, Mo et To acceptés) ; le dernier inventaire léger utilisable fournit la valeur.",
            [C("ramGB", QueryOperator.Less, QueryValue.FromParameter("Memoire"))], parameters: [P("Memoire", "ramGB", N(8), "Mémoire installée minimale", 0, 4096)]);
        b.Add(pc, "param.logon", "Comptes actifs sans connexion AD depuis une période à choisir", category,
            "Période saisie en jours (90 par défaut) appliquée à la date AD répliquée lastLogonTimestamp, approximative ; une date absente reste inconnue et ne prouve aucune inactivité.",
            [C("active", QueryOperator.Equal, B(true)), C("logonDays", QueryOperator.GreaterOrEqual, QueryValue.FromParameter("Periode"))], parameters: [P("Periode", "logonDays", N(90), "Période sans connexion AD", 1, 3650)]);
        b.Add(pc, "param.inventory", "Inventaire plus ancien qu’une période à choisir", category,
            "Âge maximal de l’inventaire léger saisi en jours ou en heures (7 jours par défaut) ; un inventaire expiré ou jamais lu reste inconnu.",
            [C("inventoryDays", QueryOperator.Greater, QueryValue.FromParameter("Periode"))], parameters: [P("Periode", "inventoryDays", N(7), "Âge maximal de l’inventaire", 0, 3650)]);
        b.Add(pc, "param.ou", "Postes dont le chemin AD contient une OU à choisir", category,
            "Partie du chemin AD saisie dans le formulaire ou reprise de l’OU de travail ; OU=Postes est un exemple à remplacer, la comparaison reste littérale.",
            [C("dn", QueryOperator.Contains, QueryValue.FromParameter("OU"))], parameters: [P("OU", "dn", T("OU=Postes"), "Partie du chemin AD (OU)")]);
        b.Add(pc, "param.release", "Version Windows relevée à choisir", category,
            "Version commerciale cherchée dans l’inventaire du poste (24H2 par défaut), distincte du système déclaré dans AD ; un poste non inventorié reste inconnu.",
            [C("observedRelease", QueryOperator.Contains, QueryValue.FromParameter("Version"))], parameters: [P("Version", "observedRelease", T("24H2"), "Version Windows relevée")]);
        var service = QueryNode.Group(QueryNodeKind.All,
        [
            QueryNode.Collection("probe:soft.servicedetails", CollectionQuantifier.Any,
                QueryNode.Group(QueryNodeKind.All, [QueryNode.Leaf(C("instance:soft.servicedetails:Name", QueryOperator.Equal, QueryValue.FromParameter("Service")))])),
        ]);
        b.Add(pc, "param.service", "Service Windows présent, nom à choisir", category,
            "Cherche le nom court saisi (Spooler par défaut) dans la liste détaillée des services du poste, relevée par une collecte explicite ; une liste incomplète ou non lue reste inconnue.",
            parameters: [P("Service", "instance:soft.servicedetails:Name", T("Spooler"), "Nom court du service Windows")], expression: service);
        b.Add(pc, "ldap.kiosk", "Postes dont la description contient « kiosque » (filtre LDAP)", "Filtres LDAP",
            "Exemple de filtre LDAP brut, évalué localement et envoyé tel quel au contrôleur en mode annuaire.",
            [C(QueryCatalog.LdapFilterField, QueryOperator.Equal, T("(description=*kiosque*)"))]);
        b.Add(pc, "ldap.nolaps", "Postes sans attribut LAPS Windows ni hérité (filtre LDAP)", "Filtres LDAP",
            "Filtre LDAP sur la présence des attributs d’expiration LAPS ; aucun secret n’est lu.",
            [C(QueryCatalog.LdapFilterField, QueryOperator.Equal, T("(&(!(msLAPS-PasswordExpirationTime=*))(!(ms-Mcs-AdmPwdExpirationTime=*)))"))]);
    }

    private static void Users(Builder b)
    {
        const QueryTarget u = QueryTarget.User;
        const string accounts = "Comptes utilisateurs";
        const string password = "Mots de passe";
        const string security = "Sécurité des comptes";
        b.Add(u, "user.all", "Tous les comptes utilisateurs recensés", accounts, "Tous les comptes utilisateurs du périmètre, actifs et désactivés.");
        b.Add(u, "user.active", "Comptes utilisateurs actifs", accounts, "Comptes activés dans la copie AD du périmètre.", [C("active", QueryOperator.Equal, B(true))]);
        b.Add(u, "user.disabled", "Comptes utilisateurs désactivés", accounts, "Comptes désactivés, par exemple en attente de suppression.", [C("active", QueryOperator.Equal, B(false))]);
        b.Add(u, "user.locked", "Comptes verrouillés", security, "État calculé par le contrôleur ; un verrouillage peut venir d’une tentative d’intrusion ou d’un ancien mot de passe enregistré.",
            [C("lockState", QueryOperator.Equal, T("Verrouillé"))]);
        b.Add(u, "user.lockcheck", "Verrouillage à vérifier", security, "lockoutTime renseigné sans état calculé lisible : à confirmer sur le contrôleur, jamais présenté comme verrouillé.",
            [C("lockState", QueryOperator.Equal, T("À vérifier"))]);
        b.Add(u, "user.neverexpires", "Comptes actifs au mot de passe sans expiration", password, "Indicateur DONT_EXPIRE_PASSWORD sur un compte actif ; justifier chaque exception (comptes de service).",
            [C("active", QueryOperator.Equal, B(true)), C("passwordNeverExpires", QueryOperator.Equal, B(true))]);
        b.Add(u, "user.expired", "Mots de passe expirés", password, "Expiration calculée dépassée.", [C("passwordState", QueryOperator.Equal, T("Expiré"))]);
        b.Add(u, "user.expiring", "Mots de passe expirant sous 7 jours", password, "Expiration dans les sept prochains jours : prévenir les utilisateurs.", [C("passwordState", QueryOperator.Equal, T("Expire bientôt"))]);
        b.Add(u, "user.mustchange", "Mot de passe à changer à la prochaine connexion", password, "pwdLastSet = 0.", [C("passwordState", QueryOperator.Equal, T("À changer"))]);
        b.Add(u, "user.notrequired", "Mot de passe non exigé", security, "Indicateur PASSWD_NOTREQD : un mot de passe vide reste possible, à corriger.", [C("passwordNotRequired", QueryOperator.Equal, B(true))]);
        b.Add(u, "user.inactive90", "Comptes actifs sans connexion depuis 90 jours", accounts, "Date répliquée lastLogonTimestamp, approximative ; une date absente reste inconnue.",
            [C("active", QueryOperator.Equal, B(true)), C("logonDays", QueryOperator.GreaterOrEqual, N(90))]);
        b.Add(u, "user.neverlogged", "Comptes actifs jamais connectés", accounts, "Aucune date de connexion répliquée ; vérifier les comptes récents et les comptes de service.",
            [C("active", QueryOperator.Equal, B(true)), C("logonDays", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(u, "user.protected", "Comptes protégés (adminCount)", security, "Comptes marqués par AdminSDHolder ; certains ne sont plus membres d’un groupe privilégié.", [C("adminCount", QueryOperator.Equal, B(true))]);
        b.Add(u, "user.privileged", "Membres d’un groupe d’administration", security, "Membres directs ou indirects des groupes d’administration du domaine.", [C("privileged", QueryOperator.Equal, B(true))]);
        b.Add(u, "user.created30", "Comptes créés depuis 30 jours", accounts, "Arrivées récentes.", [C("createdRecent", QueryOperator.Equal, B(true))]);
        b.Add(u, "user.expiresoon", "Comptes expirant sous 30 jours", accounts, "Expiration du compte (accountExpires) proche : stagiaires, prestataires.",
            [C("accountExpiresDays", QueryOperator.Less, N(30)), C("accountExpiresDays", QueryOperator.GreaterOrEqual, N(0))]);
        b.Add(u, "user.nomanager", "Comptes actifs sans responsable", accounts, "Attribut manager absent.", [C("active", QueryOperator.Equal, B(true)), C("manager", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(u, "user.nomail", "Comptes actifs sans courriel", accounts, "Attribut mail absent.", [C("active", QueryOperator.Equal, B(true)), C("mail", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(u, "user.badpwd", "Au moins 3 essais erronés récents", security, "Compteur non répliqué, relu sur le contrôleur de la session.", [C("badPwdCount", QueryOperator.GreaterOrEqual, N(3))]);
        b.Add(u, "user.service", "Comptes de service (svc-…)", accounts, "Convention de nommage des comptes de service ; adaptez le préfixe.", [C("sam", QueryOperator.StartsWith, T("svc-"))]);
        b.Add(u, "user.departures", "Description « Départ » (filtre LDAP)", accounts, "Filtre LDAP brut sur la description des comptes partis.",
            [C(QueryCatalog.LdapFilterField, QueryOperator.Equal, T("(description=Départ*)"))]);
        b.Add(u, "user.chain", "Membres directs ou indirects de GG-Support-N2 (règle en chaîne)", security, "Règle LDAP 1.2.840.113556.1.4.1941 : appartenance transitive, évaluée localement sur la copie de l’annuaire.",
            [C(QueryCatalog.LdapFilterField, QueryOperator.Equal, T("(memberOf:1.2.840.113556.1.4.1941:=CN=GG-Support-N2,OU=Sécurité,OU=Groupes,DC=example,DC=local)"))]);
        b.Add(u, "user.by.department", "Comptes par service", "Répartitions", "Répartition par attribut department.", groupBy: "department");
        b.Add(u, "user.by.office", "Comptes par bureau", "Répartitions", "Répartition par bureau déclaré.", groupBy: "office");
        b.Add(u, "user.by.password", "Situation des mots de passe", "Répartitions", "Valide, à changer, n’expire jamais, expiré ou expirant.", groupBy: "passwordState");
        b.Add(u, "user.by.lock", "États de verrouillage", "Répartitions", "Déverrouillé, verrouillé ou à vérifier.", groupBy: "lockState");
        b.Add(u, "user.param.inactive", "Comptes actifs sans connexion depuis une période à choisir", "Modèles paramétrés",
            "Période en jours (90 par défaut) sur lastLogonTimestamp, approximative.",
            [C("active", QueryOperator.Equal, B(true)), C("logonDays", QueryOperator.GreaterOrEqual, QueryValue.FromParameter("Periode"))], parameters: [P("Periode", "logonDays", N(90), "Période sans connexion AD", 1, 3650)]);
        b.Add(u, "user.param.department", "Comptes d’un service à choisir", "Modèles paramétrés", "Service saisi dans le formulaire (Commercial par défaut).",
            [C("department", QueryOperator.Equal, QueryValue.FromParameter("Service"))], parameters: [P("Service", "department", T("Commercial"), "Service")]);
        Generated(b, u);
    }

    private static void Groups(Builder b)
    {
        const QueryTarget g = QueryTarget.Group;
        const string groups = "Groupes";
        b.Add(g, "group.all", "Tous les groupes recensés", groups, "Tous les groupes du périmètre.");
        b.Add(g, "group.empty", "Groupes vides", groups, "Aucun membre direct ; un groupe principal n’est jamais déclaré vide.", [C("empty", QueryOperator.Equal, B(true))]);
        b.Add(g, "group.protected", "Groupes protégés (adminCount)", groups, "Groupes marqués par AdminSDHolder.", [C("adminCount", QueryOperator.Equal, B(true))]);
        b.Add(g, "group.distribution", "Listes de distribution", groups, "Groupes sans le bit de sécurité.", [C("groupKind", QueryOperator.Equal, T("Distribution"))]);
        b.Add(g, "group.security", "Groupes de sécurité", groups, "Groupes portant le bit de sécurité.", [C("groupKind", QueryOperator.Equal, T("Sécurité"))]);
        b.Add(g, "group.universal", "Groupes universels", groups, "Étendue universelle.", [C("scope", QueryOperator.Equal, T("Universel"))]);
        b.Add(g, "group.domainlocal", "Groupes de domaine local", groups, "Étendue domaine local (ressources).", [C("scope", QueryOperator.Equal, T("Domaine local"))]);
        b.Add(g, "group.nodescription", "Groupes sans description", groups, "Description absente : documenter l’usage.", [C("description", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(g, "group.nomanager", "Groupes sans responsable", groups, "managedBy absent.", [C("managedBy", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(g, "group.large", "Groupes d’au moins 50 membres directs", groups, "Groupes volumineux.", [C("members", QueryOperator.GreaterOrEqual, N(50))]);
        b.Add(g, "group.builtin", "Groupes intégrés", groups, "CN=Builtin ou SID bien connu.", [C("builtin", QueryOperator.Equal, B(true))]);
        b.Add(g, "group.created30", "Groupes créés depuis 30 jours", groups, "Créations récentes.", [C("createdRecent", QueryOperator.Equal, B(true))]);
        b.Add(g, "group.by.scope", "Groupes par étendue", "Répartitions", "Global, domaine local, universel, local intégré.", groupBy: "scope");
        b.Add(g, "group.by.kind", "Sécurité ou distribution", "Répartitions", "Répartition par type de groupe.", groupBy: "groupKind");
        Generated(b, g);
    }
}
