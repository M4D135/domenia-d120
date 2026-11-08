using System.Collections.Frozen;
using System.Collections.Immutable;
using Domenia.Core.Accueil;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Core.Queries;

/// <summary>Exact canonical declaration carried by a recipe or a cached reading. It never grants execution authority.</summary>
public sealed record QueryProbeDeclaration(string Key, string Document)
{
    public static QueryProbeDeclaration From(FrozenProbe probe) => new(probe.Key, PersonalProbeCatalog.Export(probe));

    public FrozenProbe Read()
    {
        try
        {
            if (!PersonalProbeCatalog.IsKey(Key)) { throw new QueryDefinitionException("Clé personnelle immuable invalide."); }
            var entries = PersonalProbeCatalog.Import(Document);
            if (entries.Length != 1 || entries[0].Key != Key)
            { throw new QueryDefinitionException("La déclaration de sonde diffère de son empreinte immuable."); }
            return entries[0];
        }
        catch (DomeniaOperationException ex) { throw new QueryDefinitionException(ex.Message); }
    }
}

/// <summary>Immutable typed projection of exact personal declarations, scoped to one recipe or one profile read.</summary>
public sealed class QueryProbeContext
{
    public static QueryProbeContext Empty { get; } = new([]);
    private readonly FrozenDictionary<string, QueryProbe> probes;
    private readonly FrozenDictionary<string, QueryField> fields;

    public QueryProbeContext(ImmutableArray<FrozenProbe> personal)
    {
        try { PersonalProbeCatalog.Validate(personal); }
        catch (DomeniaOperationException ex) { throw new QueryDefinitionException(ex.Message); }
        if (personal.Length > PersonalProbeCatalog.Capacity || personal.Any(p => !PersonalProbeCatalog.IsKey(p.Key)))
        { throw new QueryDefinitionException("Le contexte personnel accepte au plus 64 déclarations personnelles immuables."); }
        Definitions = personal;
        Personal = [.. personal.Select(Project)];
        probes = Personal.ToFrozenDictionary(p => p.Id, StringComparer.Ordinal);
        Fields = [.. Personal.Select(QueryCatalog.ProbeField)];
        InstanceFields = QueryCatalog.BuildInstances(Personal);
        fields = Fields.Concat(InstanceFields).ToFrozenDictionary(f => f.Id, StringComparer.Ordinal);
    }

    public ImmutableArray<FrozenProbe> Definitions { get; }
    public ImmutableArray<QueryProbe> Personal { get; }
    public ImmutableArray<QueryField> Fields { get; }
    public ImmutableArray<QueryField> InstanceFields { get; }
    public QueryProbe? Find(string? key) => QueryProbeCatalog.Find(key) ?? (key is not null ? probes.GetValueOrDefault(key) : null);
    public QueryField? FindField(string? key) => key is null ? null : fields.GetValueOrDefault(key);
    public FrozenProbe? Definition(string key) => Definitions.FirstOrDefault(p => p.Key == key);

    public static QueryProbeContext For(QueryRecipe recipe)
    {
        var declarations = recipe.PersonalProbes.IsDefault ? [] : recipe.PersonalProbes;
        if (declarations.Length > PersonalProbeCatalog.Capacity || declarations.Any(p => p is null))
        { throw new QueryDefinitionException("Déclarations de sondes personnelles invalides."); }
        return declarations.Length == 0 ? Empty : new([.. declarations.Select(p => p.Read())]);
    }

    public static QueryProbe Project(FrozenProbe frozen)
    {
        var d = frozen.Definition;
        return new(frozen.Key, d.Category, d.Name, d.Namespace, d.Class, d.Properties, d.Filter, d.Mode,
            d.Transform, d.Visual, d.Slow, d.SkipOnDc, d.Description, d.Limitations,
            [.. d.Fields.Select(f => new QueryProbeField(f.Name, f.CimType, Enum.Parse<QueryFieldKind>(f.Kind), f.IsArray, f.Unit, f.Description))])
        { PersonalDeclaration = QueryProbeDeclaration.From(frozen), DeclaredCost = d.Cost, DeclaredPrivilege = d.Privilege };
    }
}

/// <summary>Profile admission is separate from pure recipe compilation. Importing a recipe never imports its probes.</summary>
public static class QueryPersonalProbes
{
    public static QueryProbeContext ForRequest(QueryMeasureRequest request)
    {
        var context = new QueryProbeContext(request.PersonalProbes.IsDefault ? [] : request.PersonalProbes);
        var expected = request.Probes.Where(PersonalProbeCatalog.IsKey).Order(StringComparer.Ordinal);
        if (!context.Definitions.Select(p => p.Key).Order(StringComparer.Ordinal).SequenceEqual(expected))
        { throw new QueryDefinitionException("La collecte exige chaque définition personnelle exacte, sans déclaration supplémentaire."); }
        return context;
    }

    public static WqlSelect Select(QueryProbe probe, DateTimeOffset at)
    {
        var filter = ProbeCatalog.ResolveFilter(probe.Filter, at);
        return WqlRules.Parse("SELECT " + string.Join(", ", probe.Properties) + " FROM " + probe.Class
            + (filter.Length == 0 ? "" : " WHERE " + filter));
    }

    public static void ConfirmProjection(FrozenProbe declaration, string ns, WqlSelect select, int limit, DateTimeOffset at)
    {
        var context = new QueryProbeContext([declaration]);
        var probe = context.Personal[0];
        var expected = Select(probe, at);
        if (!string.Equals(ns, probe.Namespace, StringComparison.OrdinalIgnoreCase) || select.CanonicalQuery != expected.CanonicalQuery
            || limit != (probe.Mode == "First" ? 1 : 500))
        { throw new QueryDefinitionException("Projection différente de la sonde personnelle figée ; aucun contact."); }
    }

    public static ImmutableArray<string> RequiredKeys(QueryRecipe recipe)
    {
        var keys = new SortedSet<string>(StringComparer.Ordinal);
        void Add(string? field) { if (KeyFromField(field) is { } key) { keys.Add(key); } }
        foreach (var clause in recipe.Clauses.IsDefault ? [] : recipe.Clauses) { Add(clause.Field); }
        foreach (var clause in recipe.Refinements.IsDefault ? [] : recipe.Refinements) { Add(clause.Field); }
        foreach (var parameter in recipe.Parameters.IsDefault ? [] : recipe.Parameters) { Add(parameter.Field); }
        Add(recipe.GroupBy);
        if (recipe.ProbeSelection is { } segment) { Add(QueryCatalog.ProbePrefix + segment.Key); }
        var stack = new Stack<QueryNode>();
        if (recipe.Expression is { } expression) { stack.Push(expression); }
        var budget = 0;
        while (stack.Count > 0)
        {
            if (++budget > QueryLimits.MaxTreeNodes) { throw new QueryDefinitionException("Arbre de requête limité à 256 éléments."); }
            var node = stack.Pop(); Add(node.Clause?.Field); Add(node.CollectionField);
            if (!node.Children.IsDefault) { foreach (var child in node.Children) { stack.Push(child); } }
        }
        return [.. keys];
    }

    public static string? KeyFromField(string? field)
    {
        if (field is null) { return null; }
        var prefix = field.StartsWith(QueryCatalog.ProbePrefix, StringComparison.Ordinal) ? QueryCatalog.ProbePrefix
            : field.StartsWith(QueryCatalog.InstancePrefix, StringComparison.Ordinal) ? QueryCatalog.InstancePrefix : null;
        if (prefix is null || field.Length < prefix.Length + 71) { return null; }
        var key = field.Substring(prefix.Length, 71);
        return PersonalProbeCatalog.IsKey(key) && (field.Length == prefix.Length + 71 || field[prefix.Length + 71] == ':') ? key : null;
    }

    /// <summary>Bind editor references to exact declarations in the current profile; any embedded declaration is checked first.</summary>
    public static async Task<QueryRecipe> BindAsync(QueryRecipe recipe, IPreferenceStore preferences, CancellationToken token)
    {
        _ = QueryProbeContext.For(recipe);
        var keys = RequiredKeys(recipe);
        if (keys.Length == 0) { return recipe with { PersonalProbes = [] }; }
        var definitions = await ProfileProbeCatalog.ResolveAsync(preferences, keys, token).ConfigureAwait(false);
        return recipe with { Format = QueryRecipe.FormatV4, PersonalProbes = [.. definitions.Select(QueryProbeDeclaration.From)] };
    }

    public static Task ConfirmAsync(CompiledQuery compiled, IPreferenceStore preferences, CancellationToken token) =>
        ProfileProbeCatalog.ConfirmAsync(preferences, compiled.Probes.Definitions, token);

    public static void Confirm(CompiledQuery compiled, ImmutableArray<FrozenProbe> available)
    {
        if (compiled.Probes.Definitions.IsEmpty) { return; }
        var profile = available.IsDefault ? [] : available;
        foreach (var declaration in compiled.Probes.Definitions)
        {
            var same = profile.FirstOrDefault(p => p.Key == declaration.Key)
                ?? throw new QueryDefinitionException("Sonde personnelle absente du profil : importez sa version exacte. Aucun résultat courant ni collecte.");
            try { PersonalProbeCatalog.Validate([same]); }
            catch (DomeniaOperationException ex) { throw new QueryDefinitionException(ex.Message); }
        }
    }
}
