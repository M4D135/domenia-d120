using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Bridge.Operations.Requetes;

/// <summary>Column of the result grid: identifier, label, type, unit, and whether the recipe reads it.</summary>
public sealed record QueryColumnView(string Id, string Label, string Kind, string Unit, bool Requested, bool Hidden);

/// <summary>One object of a preview, ready for the grid: verdict, account state, presence, display values and raw values.</summary>
public sealed record QueryRowView(string Id, string Name, string Dn, string Verdict, bool? Active, string? Presence, IReadOnlyDictionary<string, string?> Values, IReadOnlyDictionary<string, object?> Raw);

public sealed record QueryCountsView(int Total, int Population, int Matched, int Unknown, int NoMatch);

public sealed record QueryGroupsView(string Field, string FieldName, long Matched, long CategoryCount, long Missing, ImmutableArray<QueryGroupItem> Items);

/// <summary>Result of « Aperçu local » (requetes.preview).</summary>
public sealed record QueryPreviewView(
    string Id,
    DateTimeOffset EvaluatedAt,
    string Fingerprint,
    QueryPopulation Population,
    QueryCountsView Counts,
    ImmutableArray<QueryColumnView> Columns,
    ImmutableArray<QueryRowView> Rows,
    bool HasMore,
    QueryGroupsView? Groups,
    LdapTranslation Ldap,
    ImmutableArray<string> Warnings,
    string Summary);

public sealed record QueryPageView(ImmutableArray<QueryRowView> Rows, int Total, int Offset, int Limit, bool HasMore, bool Stale);

/// <summary>One information of the local fiche of an object (Domenia 1 « Objet sélectionné · fiche locale »).</summary>
public sealed record QueryFieldValueView(string Id, string Name, string Category, string Source, string Value, string State, DateTimeOffset? ObservedAt, bool Requested, bool Known);

public sealed record QueryObjectView(string Id, string Name, string Dn, string Verdict, DateTimeOffset ComputedAt, string Fingerprint, ImmutableArray<QueryFieldValueView> Fields,
    ImmutableArray<QueryExplanationRow> Explanation, bool Stale);

public sealed record QueryLibraryRowView(string Id, string Name, string Category, string Source, string SourceLabel, string Target, string Informations, string Description, long Revision,
    DateTimeOffset? UpdatedAt, bool Archived, bool Remote, string Provenance, int Widgets);

public sealed record QueryLibraryListView(ImmutableArray<QueryLibraryRowView> Rows, int Total, int Filtered, int Offset, int Limit, ImmutableArray<string> Categories, int Unreadable, bool Persistent);

public sealed record QueryRevisionView(long Revision, DateTimeOffset SavedAt, string Fingerprint);

public sealed record QueryLibraryDetailView(string Id, string Name, string Category, string Source, string Description, long Revision, DateTimeOffset? UpdatedAt, bool Archived,
    QueryRecipe Recipe, ImmutableArray<QueryRevisionView> History, QueryProvenance? Provenance, string ProvenanceText, string Sources, string Collection,
    ImmutableArray<QueryWidgetLink> Widgets, ImmutableArray<QuerySummaryLine> Summary);

/// <summary>One readable element of a definition and its values (summary panels).</summary>
public sealed record QuerySummaryLine(string Element, ImmutableArray<string> Values);

/// <summary>Builds the views of the query workshop from the engine results (texts already in French).</summary>
internal static class RequetesViews
{
    private static readonly Dictionary<QueryTarget, string[]> Standard = new()
    {
        [QueryTarget.Computer] = ["os", "version", "logonDays", "checkedDays", "site"],
        [QueryTarget.User] = ["sam", "department", "title", "lockState", "passwordState", "logonDays"],
        [QueryTarget.Group] = ["scope", "groupKind", "members", "description"],
    };

    public static ImmutableArray<QueryColumnView> Columns(CompiledQuery query)
    {
        var columns = new List<QueryColumnView>();
        var seen = new HashSet<string>(StringComparer.Ordinal) { "name", "dn" };
        foreach (var id in Standard[query.Target])
        {
            if (seen.Add(id) && QueryCatalog.Find(query.Target, id) is { } field)
            {
                columns.Add(Column(field, query.RequestedFields.Contains(id), false));
            }
        }
        foreach (var id in query.RequestedFields)
        {
            if (seen.Add(id) && QueryCatalog.Find(query.Target, id, query.Resolved.ReadDefinition) is { Source: not (QuerySource.Instance or QuerySource.Ldap) } field)
            {
                columns.Add(Column(field, true, false));
            }
        }
        return [.. columns];
    }

    private static QueryColumnView Column(QueryField field, bool requested, bool hidden) =>
        new(field.Id, field.Name, field.Kind switch { QueryFieldKind.Number => "number", QueryFieldKind.Boolean => "bool", _ => "text" }, field.Unit, requested, hidden);

    public static QueryRowView Row(QueryRecord record, MatchState verdict, ImmutableArray<QueryColumnView> columns, CompiledQuery query)
    {
        var values = new Dictionary<string, string?>(StringComparer.Ordinal);
        var raw = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var column in columns)
        {
            var field = QueryCatalog.Find(query.Target, column.Id, query.Resolved.ReadDefinition);
            if (record.Values.TryGetValue(column.Id, out var value))
            {
                raw[column.Id] = value is decimal d ? Math.Round(d, 2) : value;
                values[column.Id] = column.Id is "logonDays" or "checkedDays" && value is decimal days ? QueryFormat.Number(Math.Floor(days)) + FrenchText.Nbsp + "j" : QueryFormat.Raw(value, field);
            }
            else
            {
                raw[column.Id] = null;
                values[column.Id] = null;
            }
        }
        string? presence = record.Target == QueryTarget.Computer
            ? (record.Values.GetValueOrDefault("presenceBucket") as string) switch
            {
                "En ligne" => "online",
                "Sans réponse" => "offline",
                _ => "unchecked",
            }
            : null;
        return new QueryRowView(record.Id, record.Name, record.Dn, QueryTexts.VerdictKey(verdict), record.Active, presence, values, raw);
    }

    public static QueryObjectView Object(QueryEvaluation evaluation, QueryRecord record, MatchState verdict, bool stale)
    {
        var query = evaluation.Query;
        var fields = QueryCatalog.Fields(query.Target).Select(f => (Field: f, Requested: query.RequestedFields.Contains(f.Id)))
            .Concat(query.RequestedFields.Where(id => QueryCatalog.Fields(query.Target).All(f => f.Id != id)).Select(id => QueryCatalog.Find(query.Target, id, query.Resolved.ReadDefinition))
                .OfType<QueryField>().Where(f => f.Source is not QuerySource.Instance).Select(f => (Field: f, Requested: true)))
            .Select(x =>
            {
                var known = record.Values.TryGetValue(x.Field.Id, out var value);
                var at = record.Clocks.TryGetValue(x.Field.Clock, out var date) ? date : (DateTimeOffset?)null;
                return new QueryFieldValueView(x.Field.Id, x.Field.Name, x.Field.Category, x.Field.SourceLabel, known ? QueryFormat.Raw(value, x.Field) : record.State(x.Field.Id), record.State(x.Field.Id), at, x.Requested, known);
            })
            .OrderByDescending(v => v.Requested).ThenBy(v => FrenchText.Fold(v.Category), StringComparer.Ordinal).ThenBy(v => FrenchText.Fold(v.Name), StringComparer.Ordinal)
            .ToImmutableArray();
        return new QueryObjectView(record.Id, record.Name, record.Dn, QueryTexts.VerdictKey(verdict), evaluation.Description.EvaluatedAt, query.Fingerprint, fields,
            query.Explain(record, evaluation.Context), stale);
    }

    public static string Informations(QueryRecipe recipe)
    {
        var names = QueryEngine.RequestedFields(recipe).Select(id => QueryCatalog.Find(recipe.Target, id, recipe.ReadDefinition)?.Name ?? id).Distinct(StringComparer.Ordinal).ToList();
        return names.Count == 0 ? "Aucune condition" : string.Join(", ", names.Take(6)) + (names.Count > 6 ? ", …" : "");
    }

    /// <summary>True when a recipe needs readings of the workstations (presence, inventory, probes, stored SELECT).</summary>
    public static bool Remote(QueryRecipe recipe) => QueryEngine.RequestedFields(recipe)
        .Select(id => QueryCatalog.Find(recipe.Target, id, recipe.ReadDefinition)).OfType<QueryField>()
        .Any(f => f.Source is QuerySource.Observation or QuerySource.Probe or QuerySource.Instance or QuerySource.Detail);

    public static string Sources(QueryRecipe recipe)
    {
        var fields = QueryEngine.RequestedFields(recipe).Select(id => QueryCatalog.Find(recipe.Target, id, recipe.ReadDefinition)).OfType<QueryField>().ToList();
        if (fields.Count == 0)
        {
            return "Source : base AD locale (aucune condition).";
        }
        var groups = fields.GroupBy(f => f.SourceLabel).Select(g => g.Key + " (" + FrenchText.Integer(g.Count()) + ")");
        var probes = fields.Count(f => f.Source == QuerySource.Probe || f.Source == QuerySource.Instance);
        return "Sources : " + string.Join(", ", groups) + (probes > 0 ? " · " + FrenchText.Count(probes, "sonde", "sondes") + " WMI" : "") + ".";
    }

    public static string Collection(QueryRecipe recipe) => Remote(recipe)
        ? "Collecte nécessaire pour les postes sans relevé à jour : « Collecter les données manquantes » prépare un plan, confirmé avant toute lecture."
        : "Aucune collecte : la requête lit seulement la base AD locale et les calculs locaux.";

    public static string ProvenanceText(QueryProvenance? provenance)
    {
        if (provenance is null)
        {
            return "Requête personnelle créée dans cette bibliothèque.";
        }
        var pack = provenance.PackName is null ? "pack sans nom" : "pack « " + provenance.PackName + " » v" + provenance.PackVersion.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return "Provenance déclarée : " + pack + (provenance.Origin is { Length: > 0 } origin ? " (" + origin + ")" : "") + ", recette source " + provenance.SourceRecipeId
            + (provenance.Verified ? ", intégrité du pack vérifiée" : ", intégrité non vérifiée") + ". Éditeur non vérifié.";
    }

    public static ImmutableArray<QuerySummaryLine> Summary(QueryRecipe recipe) =>
        [.. QueryAnalysis.Summary(recipe).Select(e => new QuerySummaryLine(e.Element, e.Values))];

    public static string TargetKey(QueryTarget target) => target switch
    {
        QueryTarget.User => "user",
        QueryTarget.Group => "group",
        _ => "computer",
    };
}
