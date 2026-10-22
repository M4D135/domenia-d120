using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Queries;

/// <summary>Coded value offered in a list (LAPS O/E/N/X, BitLocker K/N/X, cycle Windows…).</summary>
public sealed record QueryChoice(string Name, QueryValue Value);

/// <summary>
/// One information the engine accepts (Domenia 1 Get-DomeniaQueryCatalog): source, type, unit, description, example, how
/// to obtain it, availability, cost, freshness rule and technical details. <see cref="Clock"/> names the clock that dates
/// it (« ad », « presence », « console », « inventory », « probe:&lt;id&gt; », « detail:&lt;key&gt; »).
/// </summary>
public sealed record QueryField(
    string Id,
    string Name,
    QueryFieldKind Kind,
    QuerySource Source,
    string SourceLabel,
    string Category,
    string TypeLabel,
    string Unit,
    string Description,
    string Example,
    string Collection,
    string Availability,
    string Technical,
    string Cost,
    string Freshness,
    ImmutableArray<QueryChoice> Choices,
    string Clock,
    string? LdapAttribute,
    string? ProbeId,
    string? Property,
    bool Volatile,
    bool Groupable,
    ImmutableArray<QueryOperator> Operators);

/// <summary>Catalog of the informations each target accepts. Pure: never discovers a remote class.</summary>
public static class QueryCatalog
{
    /// <summary>Prefix of a raw LDAP attribute (« ldap:department »).</summary>
    public const string LdapPrefix = "ldap:";

    /// <summary>Clause matching a whole LDAP filter item typed in the text editor.</summary>
    public const string LdapFilterField = "ldap.filter";

    public const string ProbePrefix = "probe:";
    public const string InstancePrefix = "instance:";
    public const string DetailPrefix = "detail:";

    private static readonly Lazy<FrozenDictionary<QueryTarget, ImmutableArray<QueryField>>> Fields_ = new(BuildAll, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<FrozenDictionary<QueryTarget, FrozenDictionary<string, QueryField>>> Maps = new(
        () => Fields_.Value.ToFrozenDictionary(p => p.Key, p => p.Value.ToFrozenDictionary(f => f.Id, StringComparer.Ordinal)), LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<ImmutableArray<QueryField>> Instances_ = new(BuildInstances, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<FrozenDictionary<string, QueryField>> InstanceMap = new(() => Instances_.Value.ToFrozenDictionary(f => f.Id, StringComparer.Ordinal), LazyThreadSafetyMode.ExecutionAndPublication);

    public static ImmutableArray<QueryOperator> TextOperators { get; } =
        [QueryOperator.Equal, QueryOperator.NotEqual, QueryOperator.Contains, QueryOperator.StartsWith, QueryOperator.EndsWith, QueryOperator.IsMissing, QueryOperator.IsPresent];

    public static ImmutableArray<QueryOperator> NumberOperators { get; } =
        [QueryOperator.Equal, QueryOperator.NotEqual, QueryOperator.Greater, QueryOperator.GreaterOrEqual, QueryOperator.Less, QueryOperator.LessOrEqual, QueryOperator.IsMissing, QueryOperator.IsPresent];

    public static ImmutableArray<QueryOperator> BooleanOperators { get; } =
        [QueryOperator.Equal, QueryOperator.NotEqual, QueryOperator.IsMissing, QueryOperator.IsPresent];

    /// <summary>Raw LDAP attributes: the comparisons an LDAP filter can express.</summary>
    public static ImmutableArray<QueryOperator> LdapOperators { get; } =
        [QueryOperator.Equal, QueryOperator.NotEqual, QueryOperator.Contains, QueryOperator.StartsWith, QueryOperator.EndsWith, QueryOperator.GreaterOrEqual, QueryOperator.LessOrEqual, QueryOperator.IsMissing, QueryOperator.IsPresent];

    public static ImmutableArray<QueryOperator> OperatorsFor(QueryFieldKind kind) => kind switch
    {
        QueryFieldKind.Number => NumberOperators,
        QueryFieldKind.Boolean => BooleanOperators,
        _ => TextOperators,
    };

    public static ImmutableArray<QueryField> Fields(QueryTarget target) => Fields_.Value[target];

    public static ImmutableArray<QueryField> InstanceFields => Instances_.Value;

    /// <summary>
    /// The information <paramref name="id"/> for a recipe of <paramref name="target"/>: catalog field, instance property,
    /// raw LDAP attribute, LDAP filter item, or stored WMI SELECT field of <paramref name="read"/>; null when unknown.
    /// </summary>
    public static QueryField? Find(QueryTarget target, string? id, WmiReadDefinition? read = null)
    {
        if (string.IsNullOrEmpty(id))
        {
            return null;
        }
        if (Maps.Value[target].TryGetValue(id, out var field))
        {
            return field;
        }
        if (id.StartsWith(InstancePrefix, StringComparison.Ordinal))
        {
            return target == QueryTarget.Computer && InstanceMap.Value.TryGetValue(id, out var instance) ? instance : null;
        }
        if (id == LdapFilterField)
        {
            return LdapFilter;
        }
        if (id.StartsWith(LdapPrefix, StringComparison.Ordinal))
        {
            return Ldap.LdapSchema.Find(id[LdapPrefix.Length..]) is { } attribute ? LdapAttributeField(attribute) : null;
        }
        if (id.StartsWith(DetailPrefix, StringComparison.Ordinal) && read is not null && target == QueryTarget.Computer)
        {
            return DetailFields(read).FirstOrDefault(f => f.Id == id);
        }
        return null;
    }

    /// <summary>Clock label (dates of each source).</summary>
    public static string ClockLabel(string clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        if (clock.StartsWith("probe:", StringComparison.Ordinal))
        {
            return "Sonde · " + (QueryProbeCatalog.Find(clock[6..])?.Name ?? clock[6..]);
        }
        return clock switch
        {
            "ad" => "Annuaire AD",
            "presence" => "Présence (ping)",
            "console" => "Utilisateur console",
            "inventory" => "Inventaire du poste",
            _ when clock.StartsWith("detail:", StringComparison.Ordinal) => "SELECT WMI mémorisé",
            _ => clock,
        };
    }

    /// <summary>Instantaneous measures (Domenia 1 Test-DomeniaQueryVolatileKey): an hour-old value no longer describes the same moment.</summary>
    public static bool IsVolatileClock(string clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        if (clock is "presence" or "console")
        {
            return true;
        }
        if (!clock.StartsWith("probe:", StringComparison.Ordinal))
        {
            return false;
        }
        var id = clock[6..];
        return id.StartsWith("evt.", StringComparison.Ordinal) || id.StartsWith("svc.", StringComparison.Ordinal) || id.StartsWith("net.", StringComparison.Ordinal)
            || id.Contains("load", StringComparison.Ordinal) || id.Contains("battery", StringComparison.Ordinal) || id.Contains("free", StringComparison.Ordinal)
            || id.Contains("users", StringComparison.Ordinal) || id.Contains("stopped", StringComparison.Ordinal) || id.Contains("process", StringComparison.Ordinal);
    }

    /// <summary>Measurement family a remote read refreshes for this clock (Domenia 1 Get-DomeniaCollectionFieldFamily).</summary>
    public static string Family(string clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        return clock switch
        {
            "presence" => "Presence",
            "console" => "Console",
            "inventory" => "Inventory",
            _ when clock.StartsWith("probe:", StringComparison.Ordinal) => "Probe",
            _ when clock.StartsWith("detail:", StringComparison.Ordinal) => "Detail",
            _ => "Local",
        };
    }

    /// <summary>Fields of a stored WMI SELECT (Domenia 1 Get-DomeniaQueryReadDefinitionFields).</summary>
    public static ImmutableArray<QueryField> DetailFields(WmiReadDefinition read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var prefix = DetailPrefix + read.RequestKey + ":";
        var clock = "detail:" + read.RequestKey;
        var technical = "Espace de noms : " + read.Namespace + "\nSELECT : " + read.CanonicalQuery + "\nLimite : " + read.Limit.ToString(CultureInfo.InvariantCulture) + " instances";
        const string collection = "Exécutez de nouveau ce SELECT depuis l’onglet WMI avancé, sur le poste choisi : jamais de lecture en masse.";
        const string availability = "Seuls les postes où ce SELECT a été exécuté et enregistré ont une valeur ; les autres restent inconnus.";
        return
        [
            Make(prefix + "exists", "WMI " + read.ClassName + " · au moins une instance correspond", QueryFieldKind.Boolean, QuerySource.Detail, "SELECT mémorisé", "Oui / Non",
                "Vrai si le SELECT enregistré a trouvé au moins une instance sur le poste.", "Oui", collection, availability, technical, clock, null, null, null, [], true),
            Make(prefix + "count", "WMI " + read.ClassName + " · nombre complet d’instances", QueryFieldKind.Number, QuerySource.Detail, "SELECT mémorisé", "Instances",
                "Nombre d’instances renvoyées, seulement quand la lecture était complète.", "2", collection, availability, technical, clock, null, null, null, [], false),
        ];
    }

    /// <summary>Raw LDAP attribute as a query information (any target).</summary>
    public static QueryField LdapAttributeField(Ldap.LdapAttribute attribute)
    {
        ArgumentNullException.ThrowIfNull(attribute);
        var read = attribute.ReadByDomenia
            ? "Attribut lu par Domenia et conservé dans la base locale."
            : "Attribut non conservé par Domenia : en local, le verdict reste inconnu ; en mode annuaire, le contrôleur l’évalue.";
        return new QueryField(LdapPrefix + attribute.Name, "LDAP · " + attribute.Name, QueryFieldKind.Text, QuerySource.Ldap, "Attribut LDAP", "Attributs LDAP",
            "Texte LDAP", attribute.SyntaxLabel, attribute.Description, attribute.Example, "Actualisez la base AD du périmètre, puis exécutez la requête localement.",
            read, "Attribut : " + attribute.Name + "\nSyntaxe : " + attribute.SyntaxLabel, "Lecture locale, aucun accès aux postes",
            "Date de la lecture AD qui a alimenté la base.", [], "ad", attribute.Name, null, null, false, false, LdapOperators);
    }

    /// <summary>LDAP filter item typed in the text editor and kept as is.</summary>
    public static QueryField LdapFilter { get; } = new(LdapFilterField, "Filtre LDAP", QueryFieldKind.Text, QuerySource.Ldap, "Filtre LDAP", "Attributs LDAP", "Filtre LDAP",
        "Texte", "Élément de filtre LDAP (RFC 4515) évalué tel quel sur la copie locale de l’annuaire, et envoyé au contrôleur en mode annuaire.",
        "(description=*impression*)", "Actualisez la base AD du périmètre.", "Un attribut que Domenia ne conserve pas laisse le verdict inconnu en local.",
        "Évaluateur LDAP de Domenia.Core (égalité, sous-chaînes, ordre, présence, règles 1.2.840.113556.1.4.803, .804 et .1941).",
        "Lecture locale, aucun accès aux postes", "Date de la lecture AD qui a alimenté la base.", [], "ad", null, null, null, false, false, [QueryOperator.Equal]);

    private static FrozenDictionary<QueryTarget, ImmutableArray<QueryField>> BuildAll() => new Dictionary<QueryTarget, ImmutableArray<QueryField>>
    {
        [QueryTarget.Computer] = Sorted(ComputerFields().Concat(QueryProbeCatalog.All.Select(ProbeField))),
        [QueryTarget.User] = Sorted(UserFields()),
        [QueryTarget.Group] = Sorted(GroupFields()),
    }.ToFrozenDictionary();

    private static ImmutableArray<QueryField> Sorted(IEnumerable<QueryField> fields) =>
        [.. fields.OrderBy(f => FrenchText.Fold(f.Category), StringComparer.Ordinal).ThenBy(f => FrenchText.Fold(f.Name), StringComparer.Ordinal).ThenBy(f => f.Id, StringComparer.Ordinal)];

    private const string AdCollection = "Actualisez la base AD du périmètre choisi, puis exécutez la requête localement.";
    private const string AdAvailability = "Dépend des attributs lus, du schéma et des droits AD de la session. La mise à jour de la base doit couvrir le périmètre choisi.";
    private const string LocalAvailability = "Calculé à partir de la base AD et du référentiel local, selon leur couverture et leur date. Aucun accès au poste pendant le calcul.";
    private const string ObservationCollection = "Lancez un relevé explicite du poste ou du périmètre, puis exécutez la requête. « Collecter les données manquantes » prépare uniquement les mesures nécessaires à la requête, avec confirmation.";
    private const string ObservationAvailability = "Poste Windows joignable et droits de lecture distants selon la mesure. Chaque relevé conserve sa date ; une ancienne valeur ne devient pas fraîche après un échec.";
    private const string AdFreshness = "Date de la lecture AD qui a alimenté la base ; recalculer ne rajeunit pas les données.";
    private const string RemoteFreshness = "Date propre à chaque relevé ; un ping ne rajeunit ni l’inventaire ni les sondes.";

    private static ImmutableArray<QueryChoice> Codes(params (string Value, string Name)[] codes) => [.. codes.Select(c => new QueryChoice(c.Name, QueryValue.FromText(c.Value)))];

    private static ImmutableArray<QueryChoice> YesNo { get; } = [new("Oui", QueryValue.FromBoolean(true)), new("Non", QueryValue.FromBoolean(false))];

    private static QueryField Make(string id, string name, QueryFieldKind kind, QuerySource source, string category, string unit, string description, string example,
        string collection, string availability, string technical, string clock, string? ldap, string? probe, string? property, ImmutableArray<QueryChoice> choices, bool groupable)
    {
        var sourceLabel = source switch
        {
            QuerySource.Ad => "Annuaire AD",
            QuerySource.Local => "Calcul local",
            QuerySource.Observation => "Relevé du poste",
            QuerySource.Probe => "Sonde WMI",
            QuerySource.Instance => "Instance de sonde",
            QuerySource.Detail => "SELECT WMI mémorisé",
            _ => "Attribut LDAP",
        };
        var typeLabel = kind switch
        {
            QueryFieldKind.Boolean => "Oui / Non",
            QueryFieldKind.Number => "Nombre",
            _ => "Texte",
        };
        if (kind == QueryFieldKind.Boolean && choices.IsDefaultOrEmpty)
        {
            choices = YesNo;
        }
        var cost = source switch
        {
            QuerySource.Probe when probe is not null && QueryProbeCatalog.Find(probe)?.Slow == true => "Élevé : collecte explicite à cibler",
            QuerySource.Probe or QuerySource.Observation or QuerySource.Instance => "Lecture distante ciblée, réutilisation des relevés frais",
            QuerySource.Detail => "Lecture WMI avancée sur un seul poste, déjà enregistrée",
            _ => "Lecture locale, aucun accès aux postes",
        };
        var freshness = source is QuerySource.Probe or QuerySource.Observation or QuerySource.Instance or QuerySource.Detail ? RemoteFreshness : AdFreshness;
        return new QueryField(id, name, kind, source, sourceLabel, category, typeLabel, unit, description, example, collection, availability, technical, cost, freshness,
            choices.IsDefault ? [] : choices, clock, ldap, probe, property, IsVolatileClock(clock), groupable, OperatorsFor(kind));
    }

    private static QueryField Ad(string id, string name, QueryFieldKind kind, string category, string description, string unit, string example, string ldap, bool groupable = true, ImmutableArray<QueryChoice> choices = default) =>
        Make(id, name, kind, QuerySource.Ad, category, unit, description, example, AdCollection, AdAvailability, "Identifiant : " + id + "\nOrigine : " + ldap, "ad", ldap, null, null, choices, groupable);

    private static QueryField Local(string id, string name, QueryFieldKind kind, string category, string description, string unit, string example, string origin, string? ldap = null, bool groupable = true, ImmutableArray<QueryChoice> choices = default) =>
        Make(id, name, kind, QuerySource.Local, category, unit, description, example, AdCollection, LocalAvailability, "Identifiant : " + id + "\nOrigine : " + origin, "ad", ldap, null, null, choices, groupable);

    private static QueryField Seen(string id, string name, QueryFieldKind kind, string category, string description, string unit, string example, string origin, string clock, bool groupable = true, ImmutableArray<QueryChoice> choices = default) =>
        Make(id, name, kind, QuerySource.Observation, category, unit, description, example, ObservationCollection, ObservationAvailability, "Identifiant : " + id + "\nOrigine : " + origin, clock, null, null, null, choices, groupable);

    private static IEnumerable<QueryField> ComputerFields()
    {
        var lifecycle = Codes(("Ended", "Support terminé"), ("Soon", "Fin de support prochaine"), ("Ok", "Support en cours"), ("Unknown", "Cycle inconnu"));
        var presence = Codes(("En ligne", "En ligne"), ("Sans réponse", "Sans réponse"), ("Non vérifié", "Non vérifié"));
        var family = Codes(("Serveurs", "Serveurs"), ("Postes de travail", "Postes de travail"), ("Système non renseigné", "Système non renseigné"));
        var buckets = new[] { ("0", "0 à 6 jours"), ("1", "7 à 29 jours"), ("2", "30 à 89 jours"), ("3", "90 à 179 jours"), ("4", "180 jours et plus"), ("5", "Non renseignée") }
            .Select(b => new QueryChoice(b.Item2, QueryValue.FromNumber(decimal.Parse(b.Item1, CultureInfo.InvariantCulture)))).ToImmutableArray();
        yield return Ad("name", "Nom du poste", QueryFieldKind.Text, "Identité AD", "Retrouver un poste par son nom.", "Texte", "PC-PAR-0042", "name", groupable: false);
        yield return Ad("dn", "Chemin AD complet", QueryFieldKind.Text, "Identité AD", "Limiter les résultats à un chemin de l’annuaire.", "Texte", "OU=Paris", "distinguishedName", groupable: false);
        yield return Ad("sam", "Compte machine (sAMAccountName)", QueryFieldKind.Text, "Identité AD", "Nom de compte du poste, terminé par $.", "Texte", "PC-PAR-0042$", "sAMAccountName", groupable: false);
        yield return Ad("dnsHostName", "Nom DNS déclaré", QueryFieldKind.Text, "Identité AD", "Nom DNS complet enregistré dans le compte ordinateur.", "Texte", "pc-par-0042.example.local", "dNSHostName", groupable: false);
        yield return Ad("active", "Compte actif", QueryFieldKind.Boolean, "Identité AD", "Distinguer les comptes ordinateurs actifs et désactivés.", "Oui / Non", "Oui", "userAccountControl");
        yield return Ad("description", "Description du compte", QueryFieldKind.Text, "Identité AD", "Texte libre de la description AD (affectation, rôle).", "Texte", "Poste de Camille Bernard", "description");
        yield return Ad("location", "Emplacement déclaré", QueryFieldKind.Text, "Identité AD", "Attribut location : site, bâtiment, étage.", "Texte", "Paris – bâtiment A", "location");
        yield return Ad("managedBy", "Responsable (managedBy)", QueryFieldKind.Text, "Identité AD", "DN du responsable déclaré du poste.", "Texte", "CN=Camille Bernard", "managedBy");
        yield return Ad("memberOf", "Groupes (memberOf)", QueryFieldKind.Text, "Identité AD", "Groupes directs du compte ordinateur, séparés par des points-virgules ; utilisez « contient ».", "Texte", "GG-Postes-Kiosque", "memberOf", groupable: false);
        yield return Ad("os", "Système déclaré dans AD", QueryFieldKind.Text, "Système AD", "Filtrer le système déclaré dans le compte ordinateur.", "Texte", "Windows 11", "operatingSystem");
        yield return Ad("version", "Version déclarée dans AD", QueryFieldKind.Text, "Système AD", "Filtrer la version déclarée dans l’annuaire.", "Texte", "10.0 (26100)", "operatingSystemVersion");
        yield return Ad("laps", "État LAPS (O valide, E expiré, N absent, X sans schéma)", QueryFieldKind.Text, "Protection AD", "Filtrer l’état d’expiration LAPS visible avec les droits de la session, sans lire le secret.", "Code texte", "O : valide ; E : expiré ; N : absent ; X : sans schéma", "msLAPS-PasswordExpirationTime, ms-Mcs-AdmPwdExpirationTime",
            choices: Codes(("O", "Valide"), ("E", "Expiré"), ("N", "Aucun attribut lu"), ("X", "Schéma indisponible")));
        yield return Ad("bitlocker", "Clé BitLocker dans AD (K présente, N aucune, X indisponible)", QueryFieldKind.Text, "Protection AD", "Filtrer la présence d’une clé visible dans AD ; cela ne mesure pas le chiffrement du disque.", "Code texte", "K : présente ; N : aucune visible ; X : indisponible", "msFVE-RecoveryInformation",
            choices: Codes(("K", "Clé visible"), ("N", "Aucune clé visible"), ("X", "Indisponible")));
        yield return Local("osLabel", "Libellé système du tableau de bord", QueryFieldKind.Text, "Cycle de vie Windows", "Regrouper les libellés système harmonisés du tableau de bord.", "Texte", "Windows 11 Entreprise", "operatingSystem");
        yield return Local("release", "Version Windows du tableau de bord", QueryFieldKind.Text, "Cycle de vie Windows", "Retrouver la version Windows déduite du build AD.", "Texte", "Windows 11 24H2", "operatingSystemVersion");
        yield return Local("osFamily", "Famille poste ou serveur", QueryFieldKind.Text, "Cycle de vie Windows", "Séparer postes de travail, serveurs et systèmes non renseignés.", "Texte", "Serveurs", "operatingSystem", choices: family);
        yield return Local("site", "OU du regroupement", QueryFieldKind.Text, "Périmètre AD", "Regrouper les postes par OU dans le périmètre courant.", "Texte", "Paris", "distinguishedName");
        yield return Local("lifeStatus", "Cycle Windows (fin de support)", QueryFieldKind.Text, "Cycle de vie Windows", "Repérer une fin de support connue par le référentiel livré.", "Texte", "Ended, Soon, Ok, Unknown", "Référentiel Windows local + système AD", choices: lifecycle);
        yield return Local("win10", "Windows 10 hors LTSC, LTSB et IoT", QueryFieldKind.Boolean, "Cycle de vie Windows", "Repérer Windows 10 hors éditions LTSC, LTSB et IoT.", "Oui / Non", "Oui", "operatingSystem");
        yield return Local("logonDays", "Jours depuis la connexion AD (approximatif)", QueryFieldKind.Number, "Activité AD", "Rechercher une ancienneté de connexion AD ; cette date est approximative et répliquée.", "Jours", "90", "lastLogonTimestamp", "lastLogonTimestamp", groupable: false);
        yield return Local("logonBucket", "Tranche de connexion AD", QueryFieldKind.Number, "Activité AD", "Filtrer les mêmes tranches de connexion que le tableau de bord.", "Nombre / tranche", "0 : 0–6 j ; 1 : 7–29 j ; 2 : 30–89 j ; 3 : 90–179 j ; 4 : 180 j et plus ; 5 : non renseignée", "lastLogonTimestamp", choices: buckets);
        yield return Local("createdRecent", "Créé depuis 30 jours", QueryFieldKind.Boolean, "Activité AD", "Repérer les comptes créés depuis trente jours.", "Oui / Non", "Oui", "whenCreated", "whenCreated");
        yield return Local("createdDays", "Jours depuis la création du compte", QueryFieldKind.Number, "Activité AD", "Ancienneté du compte ordinateur dans l’annuaire.", "Jours", "365", "whenCreated", "whenCreated", groupable: false);
        yield return Local("passwordOld", "Mot de passe machine de plus de 60 jours", QueryFieldKind.Boolean, "Activité AD", "Repérer les mots de passe machine âgés de plus de soixante jours.", "Oui / Non", "Oui", "pwdLastSet", "pwdLastSet");
        yield return Local("passwordAgeDays", "Âge du mot de passe machine en jours", QueryFieldKind.Number, "Activité AD", "Ancienneté du dernier changement du mot de passe machine.", "Jours", "30", "pwdLastSet", "pwdLastSet", groupable: false);
        yield return Seen("presenceBucket", "Présence regroupée du tableau de bord", QueryFieldKind.Text, "Présence et console", "Regrouper le dernier constat réseau utilisable du tableau de bord.", "Texte", "En ligne, Sans réponse, Non vérifié", "Observation ICMP enregistrée", "presence", choices: presence);
        yield return Seen("presence", "Dernière présence observée", QueryFieldKind.Text, "Présence et console", "Filtrer le dernier résultat de présence enregistré.", "Texte", "En ligne", "Presence", "presence");
        yield return Seen("checkedDays", "Ancienneté du relevé en jours", QueryFieldKind.Number, "Présence et console", "Évaluer l’âge du dernier ping enregistré, indépendamment des relevés WMI.", "Jours", "7", "PresenceCheckedUtc", "presence", groupable: false);
        yield return Seen("user", "Utilisateur console observé", QueryFieldKind.Text, "Présence et console", "Retrouver l’utilisateur console résolu dans AD ; les sessions RDP ne sont pas recensées.", "Texte", "j.martin", "Win32_ComputerSystem.UserName + identité AD", "console");
        yield return Seen("inventoryDays", "Ancienneté de l’inventaire en jours", QueryFieldKind.Number, "Inventaire du poste", "Évaluer l’âge de la dernière lecture d’inventaire réussie.", "Jours", "5", "Inventory.CheckedUtc", "inventory", groupable: false);
        yield return Seen("observedRelease", "Windows relevé sur le poste", QueryFieldKind.Text, "Inventaire du poste", "Filtrer la version Windows relevée sur le poste.", "Texte", "Windows 11 24H2", "Win32_OperatingSystem : Caption, BuildNumber", "inventory");
        yield return Seen("model", "Modèle relevé", QueryFieldKind.Text, "Inventaire du poste", "Regrouper les postes par modèle matériel relevé.", "Texte", "Latitude", "Win32_ComputerSystem.Model", "inventory");
        yield return Seen("ramGB", "Mémoire relevée en Go", QueryFieldKind.Number, "Inventaire du poste", "Rechercher les postes sous un seuil de mémoire installée.", "Go", "8", "Win32_ComputerSystem.TotalPhysicalMemory", "inventory", groupable: false);
        yield return Seen("diskFreePercent", "Espace libre C: relevé (%)", QueryFieldKind.Number, "Inventaire du poste", "Repérer un manque d’espace libre sur C:.", "%", "10", "Win32_LogicalDisk.FreeSpace / Size", "inventory", groupable: false);
        yield return Seen("uptimeDays", "Jours depuis le démarrage relevé", QueryFieldKind.Number, "Inventaire du poste", "Rechercher les postes restés allumés longtemps.", "Jours", "30", "Win32_OperatingSystem.LastBootUpTime", "inventory", groupable: false);
    }

    private static IEnumerable<QueryField> UserFields()
    {
        var lockState = Codes(("Déverrouillé", "Déverrouillé"), ("Verrouillé", "Verrouillé"), ("À vérifier", "À vérifier"));
        var password = Codes(("Valide", "Valide"), ("À changer", "À changer à la prochaine connexion"), ("N’expire jamais", "N’expire jamais"), ("Expiré", "Expiré"), ("Expire bientôt", "Expire sous 7 jours"));
        yield return Ad("name", "Nom (cn)", QueryFieldKind.Text, "Identité AD", "Nom commun du compte.", "Texte", "Camille Bernard", "cn", groupable: false);
        yield return Ad("displayName", "Nom affiché", QueryFieldKind.Text, "Identité AD", "Nom affiché dans les carnets d’adresses.", "Texte", "Camille Bernard", "displayName", groupable: false);
        yield return Ad("sam", "Compte (sAMAccountName)", QueryFieldKind.Text, "Identité AD", "Identifiant de connexion du compte.", "Texte", "c.bernard", "sAMAccountName", groupable: false);
        yield return Ad("upn", "Nom d’utilisateur principal (UPN)", QueryFieldKind.Text, "Identité AD", "userPrincipalName du compte.", "Texte", "c.bernard@example.local", "userPrincipalName", groupable: false);
        yield return Ad("dn", "Chemin AD complet", QueryFieldKind.Text, "Identité AD", "Limiter les résultats à un chemin de l’annuaire.", "Texte", "OU=Lyon", "distinguishedName", groupable: false);
        yield return Ad("active", "Compte actif", QueryFieldKind.Boolean, "Identité AD", "Distinguer les comptes actifs et désactivés.", "Oui / Non", "Oui", "userAccountControl");
        yield return Ad("mail", "Courriel", QueryFieldKind.Text, "Coordonnées", "Adresse de messagerie.", "Texte", "camille.bernard@example.local", "mail", groupable: false);
        yield return Ad("title", "Fonction", QueryFieldKind.Text, "Organisation", "Intitulé du poste.", "Texte", "Chargée de clientèle", "title");
        yield return Ad("department", "Service", QueryFieldKind.Text, "Organisation", "Service de rattachement.", "Texte", "Commercial", "department");
        yield return Ad("office", "Bureau", QueryFieldKind.Text, "Organisation", "Site ou bureau déclaré (physicalDeliveryOfficeName).", "Texte", "Lyon", "physicalDeliveryOfficeName");
        yield return Ad("telephone", "Téléphone", QueryFieldKind.Text, "Coordonnées", "Numéro de téléphone principal.", "Texte", "+33 4 65 71 00 00", "telephoneNumber", groupable: false);
        yield return Ad("manager", "Responsable", QueryFieldKind.Text, "Organisation", "DN du responsable hiérarchique.", "Texte", "CN=Julien Martin", "manager");
        yield return Ad("employeeId", "Matricule", QueryFieldKind.Text, "Identité AD", "employeeID du compte.", "Texte", "104512", "employeeID", groupable: false);
        yield return Ad("description", "Description", QueryFieldKind.Text, "Identité AD", "Texte libre de la description AD.", "Texte", "Départ le 30/09/2026", "description");
        yield return Ad("memberOf", "Groupes (memberOf)", QueryFieldKind.Text, "Appartenances", "Groupes directs du compte, séparés par des points-virgules ; utilisez « contient ».", "Texte", "GG-Commercial-Lyon", "memberOf", groupable: false);
        yield return Ad("adminCount", "Compte protégé (adminCount = 1)", QueryFieldKind.Boolean, "Sécurité du compte", "Compte protégé par AdminSDHolder (membre passé ou présent d’un groupe privilégié).", "Oui / Non", "Oui", "adminCount");
        yield return Ad("badPwdCount", "Essais erronés de mot de passe", QueryFieldKind.Number, "Sécurité du compte", "Compteur d’essais erronés relu sur le contrôleur de la session ; il n’est pas répliqué.", "Nombre", "3", "badPwdCount");
        yield return Local("lockState", "Verrouillage", QueryFieldKind.Text, "Sécurité du compte", "État de verrouillage calculé par le contrôleur ; lockoutTime seul ne prouve rien (à vérifier).", "Texte", "Verrouillé", "msDS-User-Account-Control-Computed, lockoutTime", "lockoutTime", choices: lockState);
        yield return Local("passwordState", "Situation du mot de passe", QueryFieldKind.Text, "Mot de passe", "À changer, n’expire jamais, expiré, expire sous 7 jours ou valide (règles de la fiche compte).", "Texte", "Expire bientôt", "pwdLastSet, msDS-UserPasswordExpiryTimeComputed", "pwdLastSet", choices: password);
        yield return Local("passwordNeverExpires", "Mot de passe sans expiration", QueryFieldKind.Boolean, "Mot de passe", "Indicateur DONT_EXPIRE_PASSWORD de userAccountControl.", "Oui / Non", "Oui", "userAccountControl", "userAccountControl");
        yield return Local("passwordNotRequired", "Mot de passe non exigé", QueryFieldKind.Boolean, "Mot de passe", "Indicateur PASSWD_NOTREQD de userAccountControl : à corriger.", "Oui / Non", "Oui", "userAccountControl", "userAccountControl");
        yield return Local("passwordAgeDays", "Âge du mot de passe en jours", QueryFieldKind.Number, "Mot de passe", "Jours depuis le dernier changement de mot de passe.", "Jours", "60", "pwdLastSet", "pwdLastSet", groupable: false);
        yield return Local("passwordExpiresInDays", "Expiration du mot de passe dans (jours)", QueryFieldKind.Number, "Mot de passe", "Jours avant l’expiration calculée ; absent si le mot de passe n’expire jamais.", "Jours", "7", "msDS-UserPasswordExpiryTimeComputed", groupable: false);
        yield return Local("logonDays", "Jours depuis la connexion AD (approximatif)", QueryFieldKind.Number, "Activité AD", "Ancienneté de lastLogonTimestamp, répliqué avec un retard de 9 à 14 jours.", "Jours", "90", "lastLogonTimestamp", "lastLogonTimestamp", groupable: false);
        yield return Local("logonBucket", "Tranche de connexion AD", QueryFieldKind.Number, "Activité AD", "Tranches 0–6, 7–29, 30–89, 90–179, 180 jours et plus, puis non renseignée.", "Nombre / tranche", "3", "lastLogonTimestamp",
            choices: new[] { "0 à 6 jours", "7 à 29 jours", "30 à 89 jours", "90 à 179 jours", "180 jours et plus", "Non renseignée" }.Select((n, i) => new QueryChoice(n, QueryValue.FromNumber(i))).ToImmutableArray());
        yield return Local("createdRecent", "Créé depuis 30 jours", QueryFieldKind.Boolean, "Activité AD", "Comptes créés dans les trente derniers jours.", "Oui / Non", "Oui", "whenCreated", "whenCreated");
        yield return Local("createdDays", "Jours depuis la création du compte", QueryFieldKind.Number, "Activité AD", "Ancienneté du compte dans l’annuaire.", "Jours", "365", "whenCreated", "whenCreated", groupable: false);
        yield return Local("accountExpiresDays", "Expiration du compte dans (jours)", QueryFieldKind.Number, "Sécurité du compte", "Jours avant l’expiration du compte (accountExpires) ; absent si le compte n’expire jamais.", "Jours", "30", "accountExpires", groupable: false);
        yield return Local("site", "OU du regroupement", QueryFieldKind.Text, "Périmètre AD", "Regrouper les comptes par OU dans le périmètre courant.", "Texte", "Commercial", "distinguishedName");
        yield return Local("privileged", "Membre d’un groupe d’administration", QueryFieldKind.Boolean, "Sécurité du compte", "Membre direct ou indirect d’Admins du domaine, Administrateurs, Administrateurs de l’entreprise ou du schéma.", "Oui / Non", "Oui", "memberOf (chaîne)");
    }

    private static IEnumerable<QueryField> GroupFields()
    {
        var scope = Codes(("Global", "Global"), ("Domaine local", "Domaine local"), ("Universel", "Universel"), ("Local intégré", "Local intégré"));
        var kind = Codes(("Sécurité", "Sécurité"), ("Distribution", "Distribution"));
        yield return Ad("name", "Nom du groupe", QueryFieldKind.Text, "Identité AD", "Nom du groupe.", "Texte", "GG-Support-N2", "name", groupable: false);
        yield return Ad("sam", "Nom pré-Windows 2000", QueryFieldKind.Text, "Identité AD", "sAMAccountName du groupe.", "Texte", "GG-Support-N2", "sAMAccountName", groupable: false);
        yield return Ad("dn", "Chemin AD complet", QueryFieldKind.Text, "Identité AD", "Limiter les résultats à un chemin de l’annuaire.", "Texte", "OU=Sécurité", "distinguishedName", groupable: false);
        yield return Ad("description", "Description", QueryFieldKind.Text, "Identité AD", "Texte libre de la description AD.", "Texte", "Support de niveau 2", "description");
        yield return Ad("mail", "Courriel", QueryFieldKind.Text, "Identité AD", "Adresse d’une liste de distribution.", "Texte", "ld-lyon@example.local", "mail", groupable: false);
        yield return Ad("managedBy", "Responsable (managedBy)", QueryFieldKind.Text, "Identité AD", "DN du responsable déclaré du groupe.", "Texte", "CN=Julien Martin", "managedBy");
        yield return Ad("adminCount", "Groupe protégé (adminCount = 1)", QueryFieldKind.Boolean, "Sécurité du groupe", "Groupe protégé par AdminSDHolder.", "Oui / Non", "Oui", "adminCount");
        yield return Ad("memberOf", "Groupes parents (memberOf)", QueryFieldKind.Text, "Appartenances", "Groupes directs dont ce groupe est membre ; utilisez « contient ».", "Texte", "DL-Partage-Commun-M", "memberOf", groupable: false);
        yield return Local("scope", "Étendue du groupe", QueryFieldKind.Text, "Type de groupe", "Étendue déduite de groupType.", "Texte", "Global", "groupType", "groupType", choices: scope);
        yield return Local("groupKind", "Sécurité ou distribution", QueryFieldKind.Text, "Type de groupe", "Groupe de sécurité ou liste de distribution (bit 0x80000000 de groupType).", "Texte", "Sécurité", "groupType", "groupType", choices: kind);
        yield return Local("members", "Membres directs", QueryFieldKind.Number, "Appartenances", "Nombre de membres directs (attribut member) ; les membres par groupe principal ne sont pas comptés.", "Nombre", "12", "member", groupable: false);
        yield return Local("empty", "Groupe vide", QueryFieldKind.Boolean, "Appartenances", "Aucun membre direct ; un groupe principal (Utilisateurs du domaine…) n’est jamais déclaré vide.", "Oui / Non", "Oui", "member, primaryGroupID");
        yield return Local("builtin", "Groupe intégré", QueryFieldKind.Boolean, "Type de groupe", "Groupe de CN=Builtin ou à SID bien connu (S-1-5-32-…).", "Oui / Non", "Non", "objectSid");
        yield return Local("createdRecent", "Créé depuis 30 jours", QueryFieldKind.Boolean, "Activité AD", "Groupes créés dans les trente derniers jours.", "Oui / Non", "Oui", "whenCreated", "whenCreated");
        yield return Local("createdDays", "Jours depuis la création du groupe", QueryFieldKind.Number, "Activité AD", "Ancienneté du groupe dans l’annuaire.", "Jours", "365", "whenCreated", "whenCreated", groupable: false);
        yield return Local("site", "OU du regroupement", QueryFieldKind.Text, "Périmètre AD", "Regrouper les groupes par OU dans le périmètre courant.", "Texte", "Sécurité", "distinguishedName");
    }

    private static QueryField ProbeField(QueryProbe probe)
    {
        var numeric = probe.Numeric;
        var description = "Interroger « " + probe.Name + " » dans les relevés des postes.";
        var unit = probe.Unit;
        var example = numeric ? (unit == "Go" ? "8" : unit == "%" ? "10" : unit == "Jours" ? "30" : unit == "Mbit/s" ? "1000" : unit == "Année" ? "2024" : "1") : "";
        if (probe.Mode == "Count")
        {
            description += " Compte toutes les instances lues ; le détail conservé est limité à vingt lignes.";
            example = "0";
        }
        else if (probe.Mode == "All")
        {
            description += " Plusieurs valeurs par poste sont réunies en un texte séparé par des points-virgules ; utilisez « contient » pour chercher une valeur.";
        }
        else
        {
            description += " Utilise la première instance renvoyée par le fournisseur.";
        }
        if (!string.IsNullOrEmpty(probe.Description))
        {
            description += " " + probe.Description;
        }
        var values = probe.MapValues;
        if (!values.IsEmpty)
        {
            example = string.Join(", ", values);
        }
        var availability = "Fournisseur WMI/CIM Windows requis, poste joignable et droits de lecture distants. Une classe absente, un accès refusé ou une lecture incomplète reste inconnu.";
        if (probe.Slow)
        {
            availability += " Cette sonde peut être lente, notamment sur un journal volumineux.";
        }
        if (probe.SkipOnDc)
        {
            availability += " Elle est ignorée sur les contrôleurs de domaine.";
        }
        if (!string.IsNullOrEmpty(probe.Limitations))
        {
            availability += " " + probe.Limitations;
        }
        var technical = "Identifiant : probe:" + probe.Id + "\nEspace de noms : " + probe.Namespace + "\nClasse : " + probe.Class + "\nPropriétés : " + string.Join(", ", probe.Properties)
            + "\nFiltre : " + (probe.Filter.Length > 0 ? probe.Filter : "aucun") + "\nLecture : " + probe.Mode + " ; conversion : " + probe.Transform;
        var choices = values.Select(v => new QueryChoice(v, QueryValue.FromText(v))).ToImmutableArray();
        const string collection = "Ajoutez ce champ à une condition ou à une répartition, puis utilisez « Collecter les données manquantes ». La collecte est préparée sur les postes actifs du périmètre et confirmée avant lancement.";
        return Make(ProbePrefix + probe.Id, probe.Category + " · " + probe.Name, numeric ? QueryFieldKind.Number : QueryFieldKind.Text, QuerySource.Probe, probe.Category, unit,
            description, example, collection, availability, technical, "probe:" + probe.Id, null, probe.Id, null, choices, !numeric);
    }

    private static ImmutableArray<QueryField> BuildInstances()
    {
        var numericNames = new HashSet<string>(StringComparer.Ordinal)
        {
            "FreeSpace", "Size", "TotalPhysicalMemory", "NumberOfCores", "NumberOfLogicalProcessors", "LoadPercentage", "MaxClockSpeed", "EstimatedChargeRemaining", "PCSystemTypeEx",
            "ProductType", "OSLanguage", "AllocatedBaseSize", "FreePhysicalMemory", "FreeVirtualMemory", "TotalVisibleMemorySize", "NumberOfUsers", "MediaType", "HealthStatus",
            "ProtectionStatus", "AntivirusSignatureAge", "QuickScanAge", "FullScanAge", "Speed", "EventCode",
        };
        var list = new List<QueryField>();
        foreach (var probe in QueryProbeCatalog.All)
        {
            foreach (var property in probe.Properties)
            {
                var declared = probe.Fields.FirstOrDefault(f => string.Equals(f.Name, property, StringComparison.OrdinalIgnoreCase));
                var kind = declared is not null && !declared.IsArray ? declared.Kind : numericNames.Contains(property) ? QueryFieldKind.Number : QueryFieldKind.Text;
                var unit = declared is not null && declared.Unit.Length > 0 ? declared.Unit : "Valeur brute du fournisseur";
                var description = declared is not null && declared.Description.Length > 0 ? declared.Description : "Propriété " + property + " de la classe " + probe.Class + ", valeur brute du fournisseur.";
                list.Add(Make(InstancePrefix + probe.Id + ":" + property, probe.Name + " · " + property, kind, QuerySource.Instance, probe.Category, unit, description, "",
                    "Collecte explicite de la sonde « " + probe.Name + " ».", "Une collection incomplète ou une propriété non conservée donne Inconnu.",
                    "Classe : " + probe.Class + "\nPropriété : " + property + (declared is not null ? "\nType CIM : " + declared.CimType : ""), "probe:" + probe.Id, null, probe.Id, property, [], false));
            }
        }
        return [.. list];
    }
}
