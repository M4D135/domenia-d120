using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.Core.Queries;

/// <summary>Objects a query evaluates (Domenia 1 evaluated computer accounts only; users and groups are new).</summary>
public enum QueryTarget
{
    Computer,
    User,
    Group,
}

/// <summary>Type of an information: decides the operators and how a value is typed.</summary>
public enum QueryFieldKind
{
    Text,
    Number,
    Boolean,
}

/// <summary>Where an information comes from (Domenia 1 catalog sources, plus raw LDAP and stored WMI SELECT results).</summary>
public enum QuerySource
{
    /// <summary>Directory attribute, copied in the local base.</summary>
    Ad,

    /// <summary>Computed locally from the directory copy and the delivered references.</summary>
    Local,

    /// <summary>Reading of the workstation (presence, console, light inventory), each with its own date.</summary>
    Observation,

    /// <summary>WMI probe of the delivered catalog.</summary>
    Probe,

    /// <summary>Property of one instance of a probe collection (only inside a collection group).</summary>
    Instance,

    /// <summary>Stored result of an advanced WMI SELECT tested on one workstation.</summary>
    Detail,

    /// <summary>Raw LDAP attribute or LDAP filter typed in the text editor.</summary>
    Ldap,
}

public enum QueryOperator
{
    Equal,
    NotEqual,
    Contains,
    StartsWith,
    EndsWith,
    Greater,
    GreaterOrEqual,
    Less,
    LessOrEqual,
    IsMissing,
    IsPresent,
}

public enum QueryJunction
{
    All,
    Any,
}

public enum QueryNodeKind
{
    Clause,
    All,
    Any,
    Not,
    Collection,
}

public enum CollectionQuantifier
{
    Any,
    All,
    None,
}

/// <summary>Three-valued verdict (RFC 4511 « Undefined » is <see cref="Unknown"/>): a missing measure never decides.</summary>
public enum MatchState
{
    NoMatch,
    Match,
    Unknown,
}

public enum QueryValueKind
{
    None,
    Text,
    Number,
    Boolean,
    Parameter,
}

/// <summary>
/// Literal of a condition: nothing, a text, a decimal number, Oui/Non, or a reference to a parameter of the recipe
/// ({ "parameter": "Seuil" }, Domenia 1 { Parameter = 'Seuil' }). Never evaluated as code.
/// </summary>
[JsonConverter(typeof(QueryValueJsonConverter))]
public readonly record struct QueryValue(QueryValueKind Kind, string? Text, decimal Number, bool Flag)
{
    public static QueryValue None { get; } = new(QueryValueKind.None, null, 0m, false);

    public static QueryValue FromText(string text) => new(QueryValueKind.Text, text ?? throw new ArgumentNullException(nameof(text)), 0m, false);

    public static QueryValue FromNumber(decimal number) => new(QueryValueKind.Number, null, number, false);

    public static QueryValue FromBoolean(bool value) => new(QueryValueKind.Boolean, null, 0m, value);

    public static QueryValue FromParameter(string name) => new(QueryValueKind.Parameter, name ?? throw new ArgumentNullException(nameof(name)), 0m, false);

    public bool IsNone => Kind == QueryValueKind.None;

    /// <summary>The value as a record value (string, decimal or bool), null for none or a parameter.</summary>
    public object? Raw => Kind switch
    {
        QueryValueKind.Text => Text,
        QueryValueKind.Number => Number,
        QueryValueKind.Boolean => Flag,
        _ => null,
    };

    /// <summary>Invariant text (pack comparison, canonical form).</summary>
    public string Invariant => Kind switch
    {
        QueryValueKind.Text => Text ?? "",
        QueryValueKind.Number => Number.ToString("G29", CultureInfo.InvariantCulture),
        QueryValueKind.Boolean => Flag ? "true" : "false",
        QueryValueKind.Parameter => "{parameter:" + Text + "}",
        _ => "",
    };

    public static QueryValue FromRaw(object? raw) => raw switch
    {
        null => None,
        string s => FromText(s),
        bool b => FromBoolean(b),
        decimal d => FromNumber(d),
        double f when double.IsFinite(f) => FromNumber((decimal)f),
        int i => FromNumber(i),
        long l => FromNumber(l),
        _ => FromText(Convert.ToString(raw, CultureInfo.InvariantCulture) ?? ""),
    };
}

/// <summary>JSON form of <see cref="QueryValue"/>: null, text, number, true/false or { "parameter": "…" }.</summary>
public sealed class QueryValueJsonConverter : JsonConverter<QueryValue>
{
    public override bool HandleNull => true;

    public override QueryValue Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null:
                return QueryValue.None;
            case JsonTokenType.String:
                return QueryValue.FromText(reader.GetString()!);
            case JsonTokenType.Number:
                return reader.TryGetDecimal(out var number) ? QueryValue.FromNumber(number) : throw new JsonException("Number out of range.");
            case JsonTokenType.True:
                return QueryValue.FromBoolean(true);
            case JsonTokenType.False:
                return QueryValue.FromBoolean(false);
            case JsonTokenType.StartObject:
                using (var document = JsonDocument.ParseValue(ref reader))
                {
                    return QueryRecipeJson.ReadValue(document.RootElement, "valeur");
                }
            default:
                throw new JsonException("Invalid query value.");
        }
    }

    public override void Write(Utf8JsonWriter writer, QueryValue value, JsonSerializerOptions options)
    {
        ArgumentNullException.ThrowIfNull(writer);
        switch (value.Kind)
        {
            case QueryValueKind.Text:
                writer.WriteStringValue(value.Text);
                break;
            case QueryValueKind.Number:
                writer.WriteNumberValue(value.Number);
                break;
            case QueryValueKind.Boolean:
                writer.WriteBooleanValue(value.Flag);
                break;
            case QueryValueKind.Parameter:
                writer.WriteStartObject();
                writer.WriteString("parameter", value.Text);
                writer.WriteEndObject();
                break;
            default:
                writer.WriteNullValue();
                break;
        }
    }
}

/// <summary>One typed condition: information, operator, value (Domenia 1 { Field, Operator, Value }).</summary>
public sealed record QueryClause(string Field, QueryOperator Operator, QueryValue Value);

/// <summary>
/// Node of the condition tree (Domenia 1 Expression): a clause, an AND / OR group, a NOT group (one child) or a collection
/// group (one child, conditions on the properties of the same instance, with a quantifier).
/// </summary>
public sealed record QueryNode(QueryNodeKind Kind, QueryClause? Clause, ImmutableArray<QueryNode> Children, string? CollectionField, CollectionQuantifier? Quantifier)
{
    public static QueryNode Leaf(QueryClause clause) => new(QueryNodeKind.Clause, clause, [], null, null);

    public static QueryNode Group(QueryNodeKind kind, IEnumerable<QueryNode> children) => new(kind, null, [.. children], null, null);

    public static QueryNode Collection(string field, CollectionQuantifier quantifier, QueryNode child) =>
        new(QueryNodeKind.Collection, null, [child], field, quantifier);
}

/// <summary>Named parameter of a recipe (Domenia 1 { Name, Field, Default, Label, Minimum, Maximum }).</summary>
public sealed record QueryParameter(string Name, string Field, QueryValue Default, string? Label, decimal? Minimum, decimal? Maximum);

/// <summary>Segment on one probe value (Domenia 1 ProbeSelection: Equal, Range or Other with excluded categories).</summary>
public sealed record QueryProbeSegment(string Key, string Mode, string? Value, decimal? Low, decimal? High, ImmutableArray<string> Excluded);

/// <summary>Advanced WMI SELECT tested on one workstation and kept with a recipe (Domenia 1 Domenia.WmiRead/1).</summary>
public sealed record WmiReadDefinition(string Format, string Namespace, string ClassName, string CanonicalQuery, ImmutableArray<string> Properties, string RequestKey, int Limit);

/// <summary>
/// A query recipe (Domenia 1 Domenia.Query/1 and /2, Domenia 2 Domenia.Query/3): typed conditions combined in AND or OR,
/// advanced tree, segment (refinements, probe segment, frozen selection), parameters, coherence window of the source dates,
/// distribution and target objects. Data only: never executed.
/// </summary>
public sealed record QueryRecipe(
    string Format,
    string Id,
    string Name,
    QueryTarget Target,
    QueryJunction Junction,
    ImmutableArray<QueryClause> Clauses,
    string? GroupBy,
    ImmutableArray<QueryClause> Refinements,
    QueryProbeSegment? ProbeSelection,
    ImmutableArray<string>? ObjectIds,
    ImmutableArray<QueryParameter> Parameters,
    ImmutableSortedDictionary<string, QueryValue>? ParameterValues,
    QueryNode? Expression,
    decimal? CoherenceHours,
    WmiReadDefinition? ReadDefinition)
{
    public const string FormatV1 = "Domenia.Query/1";
    public const string FormatV2 = "Domenia.Query/2";
    public const string FormatV3 = "Domenia.Query/3";

    /// <summary>Empty draft (« Nouvelle »): every computer of the scope.</summary>
    public static QueryRecipe Empty(QueryTarget target = QueryTarget.Computer, string? id = null) => new(
        FormatV3, id ?? Guid.NewGuid().ToString("N"), QueryTexts.DefaultName(target), target, QueryJunction.All, [], null, [], null, null, [], null, null, null, null);

    /// <summary>Lowest format that holds this recipe: Domenia 1 can still read a computer recipe without Domenia 2 elements.</summary>
    public string MinimalFormat()
    {
        if (Target != QueryTarget.Computer || UsesLdap())
        {
            return FormatV3;
        }
        return Parameters.Length > 0 || Expression is not null || CoherenceHours is not null || ReadDefinition is not null ? FormatV2 : FormatV1;
    }

    private bool UsesLdap() => QueryRecipeWalk.Clauses(this).Any(c => c.Field.StartsWith(QueryCatalog.LdapPrefix, StringComparison.Ordinal) || c.Field == QueryCatalog.LdapFilterField);
}

/// <summary>Visits the clauses of a recipe (simple conditions, segment, tree).</summary>
public static class QueryRecipeWalk
{
    public static IEnumerable<QueryClause> Clauses(QueryRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        foreach (var clause in recipe.Clauses)
        {
            yield return clause;
        }
        foreach (var clause in recipe.Refinements)
        {
            yield return clause;
        }
        foreach (var clause in TreeClauses(recipe.Expression))
        {
            yield return clause;
        }
    }

    public static IEnumerable<QueryClause> TreeClauses(QueryNode? node)
    {
        if (node is null)
        {
            yield break;
        }
        var stack = new Stack<QueryNode>();
        stack.Push(node);
        var budget = 0;
        while (stack.Count > 0)
        {
            if (++budget > QueryLimits.MaxTreeNodes * 4)
            {
                yield break;
            }
            var current = stack.Pop();
            if (current.Kind == QueryNodeKind.Clause && current.Clause is { } clause)
            {
                yield return clause;
            }
            for (var i = current.Children.Length - 1; i >= 0; i--)
            {
                stack.Push(current.Children[i]);
            }
        }
    }

    /// <summary>Every node of a tree with its depth, depth-first in display order.</summary>
    public static IEnumerable<(QueryNode Node, int Depth, string Path)> Nodes(QueryNode? node)
    {
        if (node is null)
        {
            yield break;
        }
        var stack = new Stack<(QueryNode, int, string)>();
        stack.Push((node, 0, ""));
        var budget = 0;
        while (stack.Count > 0)
        {
            if (++budget > QueryLimits.MaxTreeNodes * 4)
            {
                yield break;
            }
            var (current, depth, path) = stack.Pop();
            yield return (current, depth, path);
            for (var i = current.Children.Length - 1; i >= 0; i--)
            {
                stack.Push((current.Children[i], depth + 1, path + "/" + i.ToString(CultureInfo.InvariantCulture)));
            }
        }
    }
}

/// <summary>Bounds of the query contract (Domenia 1 values, kept as is).</summary>
public static class QueryLimits
{
    public const int MaxConditions = 64;
    public const int MaxTreeDepth = 8;
    public const int MaxTreeNodes = 256;
    public const int MaxParameters = 32;
    public const int MaxNameLength = 120;
    public const int MaxTextValue = 4096;
    public const int MaxObjectIds = 20000;
    public const int MaxCoherenceHours = 8760;
    public const int MaxInstances = 10000;
    public const int MaxCategories = 100000;
    public const int MaxCategoryLabel = 80;
    public const int MaxDefinitionBytes = 64 * 1024;
    public const int MaxLdapLength = 8192;
    public const int MaxCollectFields = 256;
    public const int PreviewPage = 1000;
    public const int MaxPreviewPage = 5000;
    public const int GroupPage = 100;
    public const int MaxGroupPage = 500;
    public const int MaxExportRows = 200000;
}

/// <summary>Expected refusal of a query operation: a stable code and a French message (never the page's input).</summary>
public sealed class QueryDefinitionException(string message) : Exception(message)
{
}

/// <summary>Error codes of the query workshop (docs/ops/requetes.md).</summary>
public static class QueryErrors
{
    public const string Invalid = "query.invalid";
    public const string LdapInvalid = "query.ldapInvalid";
    public const string EvaluationUnknown = "query.evaluationUnknown";
    public const string EvaluationUnknownMessage = "Aperçu introuvable ou trop ancien : relancez l’aperçu. Rien n’a été lu.";
    public const string ObjectUnknown = "query.objectUnknown";
    public const string ObjectUnknownMessage = "Objet absent de l’aperçu : relancez l’aperçu. Rien n’a été lu.";
    public const string NotFound = "query.notFound";
    public const string NotFoundMessage = "Requête introuvable dans la bibliothèque locale : rien n’a été changé.";
    public const string RevisionChanged = "query.revisionChanged";
    public const string TemplateReadOnly = "query.templateReadOnly";
    public const string TemplateReadOnlyMessage = "Un modèle livré ne se modifie pas : enregistrez-en une copie personnelle. Rien n’a été écrit.";
    public const string LibraryFull = "query.libraryFull";
    public const string PackInvalid = "query.packInvalid";
    public const string ImportUnknown = "query.importUnknown";
    public const string ImportUnknownMessage = "Examen du pack introuvable ou expiré : examinez de nouveau le pack. Rien n’a été importé.";
    public const string RollbackRefused = "query.rollbackRefused";
    public const string CollectRefused = "query.collectRefused";
    public const string WmiInvalid = "query.wmiInvalid";
    public const string WmiUnknownComputer = "query.wmiUnknownComputer";
    public const string WmiUnknownComputerMessage = "Poste introuvable dans l’annuaire de la session : aucune lecture WMI.";
    public const string WmiNotTested = "query.wmiNotTested";
    public const string WidgetInvalid = "query.widgetInvalid";
    public const string ExportTooLarge = "query.exportTooLarge";
    public const string ExportUnavailable = "query.exportUnavailable";
    public const string ScopeChanged = "query.scopeChanged";
    public const string ScopeChangedMessage = "L’OU de travail a changé depuis cet aperçu : relancez l’aperçu sur le nouveau périmètre.";
}

/// <summary>Fixed French texts shared by the engine and the bridge.</summary>
public static class QueryTexts
{
    public static string DefaultName(QueryTarget target) => target switch
    {
        QueryTarget.User => "Tous les comptes utilisateurs recensés",
        QueryTarget.Group => "Tous les groupes recensés",
        _ => "Tous les postes recensés",
    };

    public static string TargetLabel(QueryTarget target) => target switch
    {
        QueryTarget.User => "Comptes utilisateurs",
        QueryTarget.Group => "Groupes",
        _ => "Comptes ordinateurs",
    };

    /// <summary>Noun of one object of the target, singular and plural.</summary>
    public static (string One, string Many) Noun(QueryTarget target) => target switch
    {
        QueryTarget.User => ("compte", "comptes"),
        QueryTarget.Group => ("groupe", "groupes"),
        _ => ("poste", "postes"),
    };

    public static string Verdict(MatchState state) => state switch
    {
        MatchState.Match => "Vrai",
        MatchState.NoMatch => "Faux",
        _ => "Inconnu",
    };

    public static string VerdictKey(MatchState state) => state switch
    {
        MatchState.Match => "match",
        MatchState.NoMatch => "noMatch",
        _ => "unknown",
    };

    public static string Junction(QueryJunction junction) =>
        junction == QueryJunction.Any ? "Au moins une condition (OU)" : "Toutes les conditions (ET)";

    public static string OperatorLabel(QueryOperator op) => op switch
    {
        QueryOperator.Equal => "est égal à",
        QueryOperator.NotEqual => "est différent de",
        QueryOperator.Contains => "contient",
        QueryOperator.StartsWith => "commence par",
        QueryOperator.EndsWith => "se termine par",
        QueryOperator.Greater => "est supérieur à",
        QueryOperator.GreaterOrEqual => "est supérieur ou égal à",
        QueryOperator.Less => "est inférieur à",
        QueryOperator.LessOrEqual => "est inférieur ou égal à",
        QueryOperator.IsMissing => "est absent",
        QueryOperator.IsPresent => "est renseigné",
        _ => op.ToString(),
    };

    public static string Quantifier(CollectionQuantifier quantifier) => quantifier switch
    {
        CollectionQuantifier.All => "Toutes les instances",
        CollectionQuantifier.None => "Aucune instance",
        _ => "Au moins une instance",
    };

    /// <summary>« Requête invalide : … » with the reason.</summary>
    public static string InvalidMessage(string reason) => "Requête invalide" + FrenchText.Colon + reason;
}
