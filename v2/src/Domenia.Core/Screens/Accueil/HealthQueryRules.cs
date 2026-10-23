using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core.Accueil;

public sealed record HealthQueryBinding(string RecipeId, long Revision, string Fingerprint, string Definition)
{
    public string? Problem { get; init; }
}

/// <summary>A query alert freezes a validated definition and its SHA; it never starts collection or adopts a later revision.</summary>
public static class HealthQueryRules
{
    private static readonly string[] Keys = ["recipeId", "revision", "fingerprint", "definition"];
    public static HealthQueryBinding Read(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Count() != Keys.Length || value.EnumerateObject().Any(p => !Keys.Contains(p.Name, StringComparer.Ordinal)))
        { throw HealthRules.Invalid("Référence de requête invalide."); }
        string Text(string key) => value.TryGetProperty(key, out var x) && x.ValueKind == JsonValueKind.String ? x.GetString()! : "";
        var binding = new HealthQueryBinding(Text("recipeId"), value.TryGetProperty("revision", out var rev) && rev.ValueKind == JsonValueKind.Number && rev.TryGetInt64(out var n) ? n : 0, Text("fingerprint"), Text("definition"));
        if (!Valid(binding)) { throw HealthRules.Invalid("Révision ou empreinte de requête invalide ; aucune alerte appliquée."); }
        return binding;
    }

    public static object? Write(HealthQueryBinding? value) => value is null ? null : new Dictionary<string, object?>
    { ["recipeId"] = value.RecipeId, ["revision"] = value.Revision, ["fingerprint"] = value.Fingerprint, ["definition"] = value.Definition };

    public static bool Valid(HealthQueryBinding? binding)
    {
        if (binding is null || binding.Problem is not null || binding.Revision < 1 || binding.RecipeId.Length != 32 || !binding.RecipeId.All(char.IsAsciiHexDigitLower)
            || binding.Fingerprint.Length != 64 || !binding.Fingerprint.All(char.IsAsciiHexDigitLower) || binding.Definition.Length > 262_144) { return false; }
        try
        {
            var query = QueryEngine.Compile(QueryRecipeJson.Read(binding.Definition));
            return query.Target == QueryTarget.Computer && query.Normalized.Id == binding.RecipeId && query.Fingerprint == binding.Fingerprint;
        }
        catch (QueryDefinitionException) { return false; }
    }

    public static HealthQueryBinding Freeze(QueryLibraryRecord record, long revision)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (record.Archived || record.Revision != revision || record.Recipe.Target != QueryTarget.Computer)
        { throw HealthRules.Invalid("Choisissez une requête sur les postes, non archivée, à la révision affichée."); }
        var query = QueryEngine.Compile(record.Recipe);
        return new(record.Id, revision, query.Fingerprint, QueryRecipeJson.Write(query.Normalized));
    }

    public static ImmutableDictionary<Guid, MatchState> Evaluate(HealthQueryBinding binding, FleetQuerySnapshot? snapshot, ScopeSelection scope, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(binding);
        if (!Valid(binding) || snapshot?.Dataset is not { } dataset || snapshot.Library is not { } library) { return ImmutableDictionary<Guid, MatchState>.Empty; }
        var stored = library.Records.FirstOrDefault(r => r.Id == binding.RecipeId);
        if (stored is null || stored.Archived) { return ImmutableDictionary<Guid, MatchState>.Empty; }
        try
        {
            var recipe = QueryLibrary.RevisionRecipe(stored, binding.Revision);
            if (recipe is null || QueryEngine.Compile(recipe).Fingerprint != binding.Fingerprint) { return ImmutableDictionary<Guid, MatchState>.Empty; }
            var query = QueryEngine.Compile(QueryRecipeJson.Read(binding.Definition));
            var context = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
            return QueryRecordBuilder.Build(dataset, QueryTarget.Computer, scope, now).ToImmutableDictionary(r => Guid.Parse(r.Id),
                r => query.InPopulation(r, context) ? query.Evaluate(r, context) : MatchState.NoMatch);
        }
        catch (QueryDefinitionException) { return ImmutableDictionary<Guid, MatchState>.Empty; }
    }
}
