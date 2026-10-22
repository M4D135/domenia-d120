using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core.Queries.Wmi;

public enum WqlNodeKind
{
    And,
    Or,
    Not,
    Compare,
    Like,
    IsNull,
    IsNotNull,
}

/// <summary>WHERE condition of a WQL SELECT (closed grammar: comparisons, LIKE, IS [NOT] NULL, AND, OR, NOT).</summary>
public sealed record WqlNode(WqlNodeKind Kind, ImmutableArray<WqlNode> Children, string? Property, string? Operator, string? Literal, bool LiteralIsString);

/// <summary>Parsed SELECT: class, requested properties, properties referenced, WHERE, canonical text.</summary>
public sealed record WqlSelect(string ClassName, ImmutableArray<string> Properties, ImmutableArray<string> ReferencedProperties, ImmutableArray<string> WhereProperties, WqlNode? Where, string CanonicalQuery, bool LocalAccountOnly);

/// <summary>Relation an instance may follow (Domenia 1 Get-DomeniaWmiRelationPresets): declared association or identity reference.</summary>
public sealed record WmiRelationPreset(string Id, string Source, string Kind, string Association, string Result, string SourceProperty, string TargetProperty, string ValueKind, ImmutableArray<string> Properties, string Label);

/// <summary>Local review of a SELECT before any remote read (Domenia 1 Get-DomeniaWqlPlanReport).</summary>
public sealed record WqlPlanReport(
    bool Valid,
    string Message,
    string ClassName,
    string CanonicalQuery,
    ImmutableArray<string> Properties,
    ImmutableArray<string> KeyProperties,
    ImmutableArray<string> ReferencedProperties,
    ImmutableArray<string> MissingProperties,
    ImmutableArray<string> WhereProperties,
    ImmutableArray<string> Preconditions,
    ImmutableArray<string> Limits,
    ImmutableArray<string> Warnings,
    bool Ready,
    string ReadyText,
    string Text);

/// <summary>Test of a SELECT on one workstation, needed before a recipe is prepared from it.</summary>
public sealed record WmiTested(string Namespace, string CanonicalQuery, string Computer, DateTimeOffset At);

/// <summary>
/// Deliberately small WQL SELECT grammar (Domenia 1 ConvertFrom-DomeniaWqlSelect): explicit properties, one class, a WHERE
/// with =, &lt;&gt;, !=, &lt;, &gt;, &lt;=, &gt;=, LIKE, IS [NOT] NULL, AND, OR, NOT; 8 levels, 512 tokens, 64 properties, 8 192
/// characters. Secret properties, the MSI provider and the classes that enumerate the whole domain are refused. Pure.
/// </summary>
public static partial class WqlRules
{
    public const string ReadFormat = "Domenia.WmiRead/1";

    [GeneratedRegex(@"\G\s*(?:(?<String>'(?:[^'\\]|\\.|'')*')|(?<Number>[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)|(?<Identifier>[A-Za-z_][A-Za-z0-9_]*)|(?<Operator><=|>=|<>|!=|=|<|>)|(?<Symbol>[(),]))", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex Token();

    [GeneratedRegex("(?i)password|passwd|pwd|secret|token|credential|recoverykey|privatekey|productkey|cleartext", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex SecretName();

    [GeneratedRegex(@"^root(?:\\[A-Za-z_][A-Za-z0-9_]*)*$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex NamespacePattern();

    [GeneratedRegex(@"^[A-Za-z_][A-Za-z0-9_]{0,126}\*?$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex ClassFilterPattern();

    [GeneratedRegex(@"^[A-Za-z_][A-Za-z0-9_]{0,127}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex ClassPattern();

    private sealed record Tok(string Kind, string Text);

    /// <summary>True for a property name that may carry a secret (never kept in a request nor shown).</summary>
    public static bool IsSecret(string name) => SecretName().IsMatch(name ?? "");

    public static WqlSelect Parse(string query, IReadOnlyCollection<string>? knownProperties = null)
    {
        if (string.IsNullOrWhiteSpace(query) || query.Length > 8192 || query.Any(c => c < 0x20 && c is not ('\t' or '\n' or '\r')))
        {
            throw Invalid("SELECT vide ou supérieur à 8 192 caractères.");
        }
        var tokens = new List<Tok>();
        var offset = 0;
        while (offset < query.Length)
        {
            if (query[offset..].Trim().Length == 0)
            {
                break;
            }
            var match = Token().Match(query, offset);
            if (!match.Success || match.Index != offset)
            {
                throw Invalid("syntaxe WQL non prise en charge à la position " + (offset + 1).ToString(CultureInfo.InvariantCulture) + ". SELECT de propriétés explicites uniquement.");
            }
            var kind = new[] { "String", "Number", "Identifier", "Operator", "Symbol" }.First(k => match.Groups[k].Success);
            tokens.Add(new Tok(kind, match.Groups[kind].Value));
            offset = match.Index + match.Length;
            if (tokens.Count > 512)
            {
                throw Invalid("SELECT limité à 512 éléments.");
            }
        }
        var state = new State(tokens, knownProperties);
        state.Read("SELECT");
        var properties = new List<string>();
        while (true)
        {
            var property = state.Read(kind: "Identifier").Text;
            state.Use(property);
            if (properties.Contains(property, StringComparer.OrdinalIgnoreCase))
            {
                throw Invalid("propriété SELECT dupliquée.");
            }
            properties.Add(property);
            if (properties.Count > 64)
            {
                throw Invalid("SELECT limité à 64 propriétés.");
            }
            if (state.Peek(","))
            {
                state.Read(",");
                continue;
            }
            break;
        }
        state.Read("FROM");
        var className = state.Read(kind: "Identifier").Text;
        if (className.Length > 128)
        {
            throw Invalid("nom de classe trop long.");
        }
        WqlNode? where = null;
        var localOnly = false;
        if (!state.End)
        {
            state.Read("WHERE");
            (where, localOnly) = state.Or(0);
        }
        if (!state.End)
        {
            throw Invalid("une seule instruction SELECT est autorisée.");
        }
        CheckAccountScope(className, localOnly);
        var canonical = string.Join(" ", tokens.Select(t => t.Text));
        return new WqlSelect(className, [.. properties], [.. state.Used], [.. state.WhereUsed], where, canonical, localOnly);
    }

    /// <summary>
    /// Never a whole-domain scan: the account classes need LocalAccount = TRUE in every branch of the WHERE; associations and
    /// generic classes that also return domain accounts are refused (Domenia 1 Assert-DomeniaWqlAccountScope).
    /// </summary>
    public static void CheckAccountScope(string className, bool localAccountOnly)
    {
        const string remedy = " Lisez les comptes et groupes locaux avec Win32_UserAccount ou Win32_Group WHERE LocalAccount = TRUE.";
        var refused = new (string Name, string Reason)[]
        {
            ("Win32_GroupUser", "elle énumère les appartenances de tous les groupes du domaine depuis le poste"),
            ("Win32_GroupInDomain", "elle énumère tous les groupes du domaine depuis le poste"),
            ("Win32_UserInDomain", "elle énumère tous les comptes du domaine depuis le poste"),
            ("Win32_AccountSID", "elle énumère tous les comptes du domaine depuis le poste"),
            ("CIM_LogicalElement", "cette classe générique inclut les comptes du domaine et chaque fichier du disque"),
            ("CIM_ManagedSystemElement", "cette classe générique inclut les comptes du domaine et chaque fichier du disque"),
        };
        foreach (var (name, reason) in refused)
        {
            if (string.Equals(className, name, StringComparison.OrdinalIgnoreCase))
            {
                throw new QueryDefinitionException("Classe " + name + " refusée : " + reason + "." + remedy);
            }
        }
        if (className is var c && (c.Equals("Win32_Account", StringComparison.OrdinalIgnoreCase) || c.Equals("Win32_UserAccount", StringComparison.OrdinalIgnoreCase) || c.Equals("Win32_Group", StringComparison.OrdinalIgnoreCase)) && !localAccountOnly)
        {
            throw new QueryDefinitionException("Classe " + className + " refusée sans LocalAccount = TRUE : depuis un poste du domaine, elle énumère tous les comptes ou groupes du domaine. Ajoutez LocalAccount = TRUE à la condition WHERE, dans chaque branche OU, pour ne lire que les comptes locaux du poste.");
        }
    }

    public static void CheckNamespace(string ns)
    {
        if (string.IsNullOrEmpty(ns) || ns.Length > 256 || !NamespacePattern().IsMatch(ns))
        {
            throw new QueryDefinitionException("Espace de noms WMI invalide (root ou root\\…).");
        }
    }

    /// <summary>Class list filter: a class name, optionally ending with one wildcard (Win32_*); never a WQL fragment.</summary>
    public static void CheckClassFilter(string? filter)
    {
        if (!string.IsNullOrEmpty(filter) && !ClassFilterPattern().IsMatch(filter))
        {
            throw new QueryDefinitionException("Filtre de classes invalide : un nom de classe, éventuellement terminé par *.");
        }
    }

    public static void CheckTarget(string ns, string className)
    {
        CheckNamespace(ns);
        if (!ClassPattern().IsMatch(className ?? ""))
        {
            throw new QueryDefinitionException("Nom de classe WMI invalide.");
        }
        if (QueryProbeCatalog.MsiProviderClasses.Contains(className!, StringComparer.OrdinalIgnoreCase))
        {
            throw new QueryDefinitionException("Fournisseur MSI interdit : sa lecture peut déclencher une vérification ou une réparation.");
        }
    }

    /// <summary>Known costly providers; a syntax check never proves that a provider is inert.</summary>
    public static ImmutableArray<string> ProviderWarnings(string className, bool hasWhere)
    {
        var costly = new (string Name, string Text)[]
        {
            ("CIM_DataFile", "parcourt les fichiers du disque"),
            ("CIM_Directory", "parcourt les dossiers du disque"),
            ("Win32_Directory", "parcourt les dossiers du disque"),
            ("Win32_ShortcutFile", "parcourt les raccourcis du disque"),
            ("Win32_NTLogEvent", "lit les journaux d’événements, parfois très volumineux"),
            ("Win32_ReliabilityRecords", "lit l’historique de fiabilité, lent sur un poste ancien"),
            ("Win32_PnPSignedDriver", "interroge chaque pilote, lentement"),
        };
        var warnings = new List<string>();
        foreach (var (name, text) in costly)
        {
            if (string.Equals(className, name, StringComparison.OrdinalIgnoreCase))
            {
                warnings.Add("Classe " + name + " : " + text + "." + (hasWhere ? "" : " Sans clause WHERE, la lecture porte sur tout ce périmètre."));
            }
        }
        warnings.Add("La validation syntaxique ne garantit pas qu’un fournisseur est sans effet de bord : testez la requête sur un poste choisi avant d’en faire une recette.");
        return [.. warnings];
    }

    public static string RequestKey(string ns, string canonical) => QueryRecipeJson.Sha256((ns ?? "").ToLowerInvariant() + "\n" + canonical);

    /// <summary>Review of a SELECT before any remote read: properties, keys, preconditions, limits, prudence, test status.</summary>
    public static WqlPlanReport Plan(string ns, string query, int limit, IReadOnlyCollection<string>? knownProperties, IReadOnlyCollection<string>? keyProperties, string? schemaClass, WmiTested? tested, string? computer)
    {
        WqlSelect plan;
        try
        {
            plan = Parse(query);
            CheckTarget(ns, plan.ClassName);
            if (limit is < 1 or > 2000)
            {
                throw new QueryDefinitionException("Choisissez une limite entre 1 et 2 000 instances.");
            }
        }
        catch (QueryDefinitionException ex)
        {
            return new WqlPlanReport(false, ex.Message, "", "", [], [], [], [], [], [], [], [], false, "", "Requête non exécutable : " + ex.Message);
        }
        var known = knownProperties ?? [];
        var schemaKnown = !string.IsNullOrEmpty(schemaClass) && string.Equals(schemaClass, plan.ClassName, StringComparison.OrdinalIgnoreCase) && known.Count > 0;
        ImmutableArray<string> missing = schemaKnown ? [.. plan.ReferencedProperties.Where(p => !known.Contains(p, StringComparer.OrdinalIgnoreCase))] : [];
        ImmutableArray<string> keys = schemaKnown && keyProperties is not null ? [.. keyProperties.Where(k => !plan.Properties.Contains(k, StringComparer.OrdinalIgnoreCase))] : [];
        var preconditions = new List<string>
        {
            !string.IsNullOrEmpty(computer) ? "Poste choisi : " + computer + "." : "Choisissez le poste à interroger : aucune lecture sans poste choisi.",
            "Connexion CIM (DCOM, ou WinRM si activé) avec le compte distant configuré ; un refus d’authentification suspend les lectures.",
            "Droit de lecture sur l’espace de noms " + ns + ".",
        };
        if (schemaKnown)
        {
            preconditions.Add("Schéma de " + plan.ClassName + " relu pour ce poste : propriétés vérifiées.");
            if (missing.Length > 0)
            {
                preconditions.Add("Propriétés absentes du schéma relu : " + string.Join(", ", missing) + ". La lecture sera refusée.");
            }
        }
        else
        {
            preconditions.Add("Schéma de " + plan.ClassName + " non relu pour ce poste : la classe et les propriétés seront vérifiées au moment de la lecture.");
        }
        var identity = keys.Length > 0 ? ", plus les clés " + string.Join(", ", keys) + " pour conserver l’identité des instances"
            : !schemaKnown ? ", plus les clés du fournisseur pour conserver l’identité des instances" : "";
        ImmutableArray<string> limits =
        [
            FrenchText.Count(limit, "instance", "instances") + " au plus, 1 Mio de résultats conservés et 50 secondes de lecture.",
            "Seules les propriétés citées sont demandées" + identity + " ; aucune méthode WMI n’est appelée.",
            "Un résultat partiel (limite ou budget atteint) reste marqué comme tel ; il n’est jamais présenté comme complet.",
        ];
        var warnings = ProviderWarnings(plan.ClassName, plan.WhereProperties.Length > 0);
        var ready = tested is not null && string.Equals(tested.CanonicalQuery, plan.CanonicalQuery, StringComparison.Ordinal)
            && string.Equals(tested.Namespace, ns, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(computer) && string.Equals(tested.Computer, computer, StringComparison.OrdinalIgnoreCase);
        var readyText = ready
            ? "Testée sur " + tested!.Computer + " (résultat enregistré " + tested.At.UtcDateTime.ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture) + " UTC) : la recette locale peut être préparée."
            : "Pas encore testée sous cette forme sur ce poste : exécutez-la avant d’en faire une recette.";
        var lines = new List<string>
        {
            "Classe : " + plan.ClassName + " · espace de noms : " + ns,
            "Propriétés demandées : " + string.Join(", ", plan.Properties) + (keys.Length > 0 ? " (+ clés : " + string.Join(", ", keys) + ")" : ""),
            plan.WhereProperties.Length > 0 ? "Condition WHERE sur : " + string.Join(", ", plan.WhereProperties) : "Aucune condition WHERE : toutes les instances de la classe, dans la limite choisie.",
            "Préconditions :",
        };
        lines.AddRange(preconditions.Select(p => " • " + p));
        lines.Add("Limites :");
        lines.AddRange(limits.Select(l => " • " + l));
        lines.Add("Prudence :");
        lines.AddRange(warnings.Select(w => " • " + w));
        lines.Add(readyText);
        return new WqlPlanReport(true, "", plan.ClassName, plan.CanonicalQuery, plan.Properties, keys, plan.ReferencedProperties, missing, plan.WhereProperties, [.. preconditions], limits, warnings,
            ready, readyText, string.Join("\n", lines));
    }

    /// <summary>Definition kept with a recipe after a successful test (Domenia 1 New-DomeniaQueryReadDefinition).</summary>
    public static WmiReadDefinition NewReadDefinition(string ns, string query, int limit)
    {
        var plan = Parse(query);
        CheckTarget(ns, plan.ClassName);
        if (limit is < 1 or > 2000)
        {
            throw new QueryDefinitionException("La définition WMI accepte entre 1 et 2 000 instances.");
        }
        return new WmiReadDefinition(ReadFormat, ns, plan.ClassName, plan.CanonicalQuery, plan.Properties, RequestKey(ns, plan.CanonicalQuery), limit);
    }

    /// <summary>A stored definition must be exactly what a new one would be (key, class, canonical text, properties).</summary>
    public static void CheckReadDefinition(WmiReadDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        QueryRecipeJson.CheckFormat(definition.Format, "Domenia.WmiRead", 1, "lecture WMI");
        var expected = NewReadDefinition(definition.Namespace, definition.CanonicalQuery, definition.Limit);
        if (!string.Equals(expected.RequestKey, definition.RequestKey, StringComparison.Ordinal) || !string.Equals(expected.ClassName, definition.ClassName, StringComparison.Ordinal)
            || !string.Equals(expected.CanonicalQuery, definition.CanonicalQuery, StringComparison.Ordinal) || !expected.Properties.SequenceEqual(definition.Properties, StringComparer.Ordinal))
        {
            throw new QueryDefinitionException(QueryTexts.InvalidMessage("définition WMI ou empreinte incohérente."));
        }
    }

    /// <summary>Relations a provider declares or exposes through an identity property; filtered by source class when given.</summary>
    public static ImmutableArray<WmiRelationPreset> RelationPresets(string? className = null)
    {
        ImmutableArray<WmiRelationPreset> all =
        [
            new("disk-partitions", "Win32_DiskDrive", "Association", "Win32_DiskDriveToDiskPartition", "Win32_DiskPartition", "", "", "", [], "Partitions de ce disque physique"),
            new("partition-disk", "Win32_DiskPartition", "Association", "Win32_DiskDriveToDiskPartition", "Win32_DiskDrive", "", "", "", [], "Disque physique qui porte cette partition"),
            new("partition-volume", "Win32_DiskPartition", "Association", "Win32_LogicalDiskToPartition", "Win32_LogicalDisk", "", "", "", [], "Volume logique de cette partition"),
            new("volume-partition", "Win32_LogicalDisk", "Association", "Win32_LogicalDiskToPartition", "Win32_DiskPartition", "", "", "", [], "Partition qui porte ce volume"),
            new("adapter-configuration", "Win32_NetworkAdapter", "Association", "Win32_NetworkAdapterSetting", "Win32_NetworkAdapterConfiguration", "", "", "", [], "Configuration IP de cette carte"),
            new("configuration-adapter", "Win32_NetworkAdapterConfiguration", "Association", "Win32_NetworkAdapterSetting", "Win32_NetworkAdapter", "", "", "", [], "Carte réseau de cette configuration"),
            new("service-dependencies", "Win32_Service", "Association", "Win32_DependentService", "Win32_Service", "", "", "", [], "Services liés par dépendance (dans les deux sens)"),
            new("service-process", "Win32_Service", "Reference", "", "Win32_Process", "ProcessId", "Handle", "String", ["Name", "ProcessId", "ParentProcessId", "CreationDate", "ExecutablePath"], "Processus qui héberge ce service, au moment de la lecture"),
            new("process-services", "Win32_Process", "Reference", "", "Win32_Service", "Handle", "ProcessId", "Number", ["Name", "DisplayName", "State", "StartMode", "ProcessId"], "Services hébergés par ce processus, au moment de la lecture"),
        ];
        return string.IsNullOrEmpty(className) ? all : [.. all.Where(p => string.Equals(p.Source, className, StringComparison.OrdinalIgnoreCase))];
    }

    /// <summary>Identity value of a reference relation: digits only, never zero (a stopped service has no hosting process).</summary>
    public static string ReferenceValue(WmiRelationPreset preset, string? value)
    {
        ArgumentNullException.ThrowIfNull(preset);
        if (value is null)
        {
            throw new QueryDefinitionException("La propriété " + preset.SourceProperty + " n’a pas été lue pour cette instance : ajoutez-la au SELECT puis exécutez-le à nouveau.");
        }
        var text = value.Trim();
        if (text.Length is 0 or > 10 || !text.All(char.IsAsciiDigit))
        {
            throw new QueryDefinitionException("Identifiant " + preset.SourceProperty + " invalide : la relation n’est pas lue.");
        }
        var number = long.Parse(text, CultureInfo.InvariantCulture);
        if (number <= 0 || number > 4294967295)
        {
            throw new QueryDefinitionException("Aucun processus associé (" + preset.SourceProperty + " = " + text + ") : un service arrêté n’a pas de processus hôte.");
        }
        return number.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Evaluates a WHERE on one instance (simulation and tests): WQL comparisons are case-insensitive for strings; LIKE takes
    /// % and _; a missing property compares as NULL.
    /// </summary>
    public static bool Matches(WqlNode? where, IReadOnlyDictionary<string, string?> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        if (where is null)
        {
            return true;
        }
        string? Get(string property) => values.FirstOrDefault(p => string.Equals(p.Key, property, StringComparison.OrdinalIgnoreCase)).Value;
        switch (where.Kind)
        {
            case WqlNodeKind.And:
                return where.Children.All(c => Matches(c, values));
            case WqlNodeKind.Or:
                return where.Children.Any(c => Matches(c, values));
            case WqlNodeKind.Not:
                return !Matches(where.Children[0], values);
            case WqlNodeKind.IsNull:
                return Get(where.Property!) is null;
            case WqlNodeKind.IsNotNull:
                return Get(where.Property!) is not null;
            case WqlNodeKind.Like:
                return Get(where.Property!) is { } text && LikeMatches(text, where.Literal ?? "");
            default:
                var actual = Get(where.Property!);
                if (actual is null || where.Literal is null || where.Literal == "NULL")
                {
                    return false;
                }
                int comparison;
                if (!where.LiteralIsString && decimal.TryParse(actual, NumberStyles.Float, CultureInfo.InvariantCulture, out var a) && decimal.TryParse(where.Literal, NumberStyles.Float, CultureInfo.InvariantCulture, out var b))
                {
                    comparison = a.CompareTo(b);
                }
                else
                {
                    comparison = string.Compare(actual, where.Literal, StringComparison.OrdinalIgnoreCase);
                }
                return where.Operator switch
                {
                    "=" => comparison == 0,
                    "<>" or "!=" => comparison != 0,
                    "<" => comparison < 0,
                    ">" => comparison > 0,
                    "<=" => comparison <= 0,
                    ">=" => comparison >= 0,
                    _ => false,
                };
        }
    }

    private static bool LikeMatches(string text, string pattern)
    {
        var regex = "^" + Regex.Escape(pattern).Replace("%", ".*", StringComparison.Ordinal).Replace("_", ".", StringComparison.Ordinal) + "$";
        return Regex.IsMatch(text, regex, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Singleline, TimeSpan.FromMilliseconds(200));
    }

    private static QueryDefinitionException Invalid(string reason) => new("SELECT refusé" + FrenchText.Colon + reason);

    private sealed class State(List<Tok> tokens, IReadOnlyCollection<string>? known)
    {
        private int index;

        public List<string> Used { get; } = [];

        public List<string> WhereUsed { get; } = [];

        public bool End => index >= tokens.Count;

        public bool Peek(string text) => !End && string.Equals(tokens[index].Text, text, StringComparison.OrdinalIgnoreCase);

        public Tok Read(string text = "", string kind = "")
        {
            if (End)
            {
                throw Invalid("SELECT incomplet.");
            }
            var token = tokens[index];
            if ((text.Length > 0 && !string.Equals(token.Text, text, StringComparison.OrdinalIgnoreCase)) || (kind.Length > 0 && token.Kind != kind))
            {
                throw Invalid((text.Length > 0 ? text : kind == "Identifier" ? "nom" : kind) + " attendu.");
            }
            index++;
            return token;
        }

        public void Use(string name)
        {
            if (IsSecret(name))
            {
                throw new QueryDefinitionException("Une propriété de secret ne peut pas être conservée dans une requête.");
            }
            if (known is not null && !known.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                throw Invalid("propriété absente du schéma lu (" + name + ").");
            }
            if (!Used.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                Used.Add(name);
            }
        }

        // Each reader returns whether its condition guarantees LocalAccount = TRUE (Domenia 1 rule): an exact predicate, an AND
        // with at least one such operand, an OR whose every branch has one. NOT never guarantees it.
        public (WqlNode Node, bool Local) Or(int depth)
        {
            var (node, local) = And(depth);
            var items = new List<WqlNode> { node };
            while (Peek("OR"))
            {
                Read("OR");
                var (next, nextLocal) = And(depth);
                items.Add(next);
                local &= nextLocal;
            }
            return (items.Count == 1 ? node : new WqlNode(WqlNodeKind.Or, [.. items], null, null, null, false), local);
        }

        private (WqlNode Node, bool Local) And(int depth)
        {
            var (node, local) = Predicate(depth);
            var items = new List<WqlNode> { node };
            while (Peek("AND"))
            {
                Read("AND");
                var (next, nextLocal) = Predicate(depth);
                items.Add(next);
                local |= nextLocal;
            }
            return (items.Count == 1 ? node : new WqlNode(WqlNodeKind.And, [.. items], null, null, null, false), local);
        }

        private (WqlNode Node, bool Local) Predicate(int depth)
        {
            if (depth > 8)
            {
                throw Invalid("conditions WQL limitées à 8 niveaux.");
            }
            if (End)
            {
                throw Invalid("condition WQL incomplète.");
            }
            if (Peek("NOT"))
            {
                Read("NOT");
                var (inner, _) = Predicate(depth + 1);
                return (new WqlNode(WqlNodeKind.Not, [inner], null, null, null, false), false);
            }
            if (Peek("("))
            {
                Read("(");
                var (node, local) = Or(depth + 1);
                Read(")");
                return (node, local);
            }
            var field = Read(kind: "Identifier").Text;
            Use(field);
            if (!WhereUsed.Contains(field, StringComparer.OrdinalIgnoreCase))
            {
                WhereUsed.Add(field);
            }
            var op = Read();
            if (string.Equals(op.Text, "IS", StringComparison.OrdinalIgnoreCase))
            {
                var not = false;
                if (Peek("NOT"))
                {
                    Read("NOT");
                    not = true;
                }
                Read("NULL");
                return (new WqlNode(not ? WqlNodeKind.IsNotNull : WqlNodeKind.IsNull, [], field, null, null, false), false);
            }
            if (op.Kind != "Operator" && !string.Equals(op.Text, "LIKE", StringComparison.OrdinalIgnoreCase))
            {
                throw Invalid("comparateur WQL non pris en charge.");
            }
            var literal = Read();
            var upper = literal.Text.ToUpperInvariant();
            if (literal.Kind is not ("String" or "Number") && upper is not ("TRUE" or "FALSE" or "NULL"))
            {
                throw Invalid("une valeur WQL doit être un texte entre apostrophes, un nombre, TRUE, FALSE ou NULL.");
            }
            var like = string.Equals(op.Text, "LIKE", StringComparison.OrdinalIgnoreCase);
            if (like && literal.Kind != "String")
            {
                throw Invalid("LIKE attend un texte entre apostrophes.");
            }
            var isString = literal.Kind == "String";
            var value = isString ? literal.Text[1..^1].Replace("''", "'", StringComparison.Ordinal).Replace("\\'", "'", StringComparison.Ordinal) : upper is "TRUE" ? "True" : upper is "FALSE" ? "False" : literal.Text;
            var isLocal = string.Equals(field, "LocalAccount", StringComparison.OrdinalIgnoreCase) && op.Text == "=" && literal.Kind == "Identifier" && upper == "TRUE";
            return (new WqlNode(like ? WqlNodeKind.Like : WqlNodeKind.Compare, [], field, like ? "LIKE" : op.Text, value, isString), isLocal);
        }
    }
}
