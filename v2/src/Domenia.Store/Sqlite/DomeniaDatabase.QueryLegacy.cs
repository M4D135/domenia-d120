using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record LegacyQueryExtra(
        IReadOnlyList<IReadOnlyDictionary<string, object?>> Revisions,
        IReadOnlyList<IReadOnlyDictionary<string, object?>> Provenances,
        IReadOnlyList<IReadOnlyDictionary<string, object?>> Dependencies);

    private static readonly JsonSerializerOptions QueryLegacyJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };

    private static LegacyQueryExtra LegacyQueryMetadata(SqliteDatabase db)
    {
        IReadOnlyList<IReadOnlyDictionary<string, object?>> Rows(string table, string columns, string bytes, string order, int limit)
        {
            if (!Table(db, table)) { return []; }
            if ((long?)db.Scalar("SELECT coalesce(sum(" + bytes + "),0) FROM " + table + ";") > QueryLibrary.MaxDocumentBytes)
            { throw new InvalidDataException("Historique ou dépendances de requêtes Domenia 1 supérieurs à 16 Mio ; aucune reprise partielle."); }
            var rows = db.Query("SELECT " + columns + " FROM " + table + " ORDER BY " + order + " LIMIT " + (limit + 1) + ";");
            if (rows.Count > limit) { throw new InvalidDataException("Historique ou dépendances de requêtes Domenia 1 hors limites ; aucune reprise partielle."); }
            return rows;
        }
        return new(
            Rows("domenia_query_recipe_revisions", "id,revision,definition_version,definition_json,definition_sha256,at_utc", "length(CAST(definition_json AS BLOB))", "id,revision", 20_000),
            Rows("domenia_query_recipe_provenance", "recipe_id,revision,provenance_json", "length(CAST(provenance_json AS BLOB))", "recipe_id,revision", 20_000),
            Rows("domenia_query_recipe_dependencies", "recipe_id,consumer_kind,consumer_id,bound_revision", "length(recipe_id)+length(consumer_kind)+length(consumer_id)+8", "recipe_id,consumer_kind,consumer_id", 5000));
    }

    private sealed record LegacyQueryProjection(
        IReadOnlyDictionary<string, ImmutableArray<QueryRevision>> History,
        IReadOnlyDictionary<string, QueryProvenance> Provenance,
        ImmutableArray<QueryConsumerLink> Dependencies);

    private LegacyQueryProjection ProjectQueryLegacy(List<Dictionary<string, object?>> recipes, LegacyQueryExtra extra)
    {
        var records = recipes.ToDictionary(r => (string)r["id"]!, StringComparer.Ordinal);
        var versions = new Dictionary<(string Id, long Revision), QueryRevision>();
        var origins = new Dictionary<(string Id, long Revision), QueryProvenance>();
        foreach (var row in extra.Revisions)
        {
            var id = row["id"] as string ?? throw new InvalidDataException("Identité de révision héritée absente.");
            var revision = (long)row["revision"]!;
            if (!records.TryGetValue(id, out var current) || revision <= 0 || revision > (long)current["revision"]!)
            { throw new InvalidDataException("Révision héritée orpheline ou incohérente."); }
            var definition = row["definition_json"] as string ?? throw new InvalidDataException("Définition historique absente.");
            var compiled = LegacyQueryDefinition(definition, id, (long)row["definition_version"]!, row["definition_sha256"] as string);
            var at = QueryDate((string)row["at_utc"]!);
            if (at < QueryDate((string)current["created_utc"]!) || at > QueryDate((string)current["updated_utc"]!))
            { throw new InvalidDataException("Date de révision héritée incohérente."); }
            if (revision == (long)current["revision"]! && row["definition_sha256"] as string != current["definition_sha256"] as string)
            { throw new InvalidDataException("Révision courante et historique Domenia 1 différents."); }
            if (!versions.TryAdd((id, revision), new(revision, at, compiled.Fingerprint, QueryRecipeJson.Write(compiled.Normalized))))
            { throw new InvalidDataException("Révision héritée dupliquée."); }
        }
        foreach (var row in extra.Provenances)
        {
            var id = row["recipe_id"] as string ?? throw new InvalidDataException("Identité de provenance absente.");
            var revision = (long)row["revision"]!;
            if (!records.TryGetValue(id, out var current) || revision <= 0 || revision > (long)current["revision"]!
                || revision != (long)current["revision"]! && !versions.ContainsKey((id, revision)))
            { throw new InvalidDataException("Provenance héritée sans révision identifiable."); }
            var text = row["provenance_json"] as string ?? throw new InvalidDataException("Provenance héritée absente.");
            if (text.Length > 8192) { throw new InvalidDataException("Provenance héritée hors limites."); }
            var provenance = JsonSerializer.Deserialize<QueryProvenance>(text, QueryLegacyJson) ?? throw new InvalidDataException("Provenance héritée illisible.");
            if (!QueryRecipeJson.IdPattern().IsMatch(provenance.SourceRecipeId ?? "") || provenance.DefinitionSha256 is not { Length: 64 } hash || hash.Any(c => !char.IsAsciiHexDigit(c))
                || provenance.PackName?.Length > 80 || provenance.Origin?.Length > 256 || (provenance.PackName + provenance.Origin).Any(char.IsControl)
                || provenance.PackVersion is < 0 or > 1_000_000
                || (string.IsNullOrEmpty(provenance.PackId) ? provenance.Verified || provenance.PackVersion != 0
                    : provenance.PackVersion == 0 || string.IsNullOrWhiteSpace(provenance.PackName) || provenance.PackId != QueryLibrary.PackId(provenance.PackName)))
            { throw new InvalidDataException("Provenance héritée incohérente ; elle ne constitue pas une identité d’éditeur vérifiée."); }
            if (!origins.TryAdd((id, revision), provenance)) { throw new InvalidDataException("Provenance héritée dupliquée."); }
        }
        var links = ImmutableArray.CreateBuilder<QueryConsumerLink>();
        var seen = new HashSet<(string, string, string)>();
        foreach (var row in extra.Dependencies)
        {
            var id = row["recipe_id"] as string ?? ""; var kind = row["consumer_kind"] as string ?? ""; var consumer = row["consumer_id"] as string ?? "";
            var revision = (long)row["bound_revision"]!;
            if (!records.TryGetValue(id, out var current) || kind is not ("Fleet" or "Computer") || consumer.Length is 0 or > 128 || consumer.Any(char.IsControl)
                || revision <= 0 || revision > (long)current["revision"]! || revision != (long)current["revision"]! && !versions.ContainsKey((id, revision))
                || !seen.Add((id, kind, consumer)))
            { throw new InvalidDataException("Dépendance héritée inconnue, dupliquée ou sans révision disponible."); }
            // D1 stores a binding, not the widget layout. Preserve it as an explicit inherited reference,
            // never invent its visualization or install a widget that the user has not chosen.
            links.Add(new(kind == "Fleet" ? "legacyFleet" : "legacyComputer", consumer, id, revision,
                "Widget Domenia 1 · " + consumer, null, DateTimeOffset.MinValue));
        }
        var revisionsByRecipe = versions.ToLookup(v => v.Key.Id, StringComparer.Ordinal);
        return new(
            records.ToDictionary(p => p.Key, p => revisionsByRecipe[p.Key].Where(v => v.Key.Revision < (long)p.Value["revision"]!)
                .OrderByDescending(v => v.Key.Revision).Select(v => v.Value with { Provenance = origins.GetValueOrDefault(v.Key) }).ToImmutableArray(), StringComparer.Ordinal),
            records.Where(p => origins.ContainsKey((p.Key, (long)p.Value["revision"]!))).ToDictionary(p => p.Key, p => origins[(p.Key, (long)p.Value["revision"]!)], StringComparer.Ordinal),
            links.ToImmutable());
    }

    private static CompiledQuery LegacyQueryDefinition(string definition, string id, long version, string? sha)
    {
        if (System.Text.Encoding.UTF8.GetByteCount(definition) > 1_048_576 || QueryHash(definition) != sha)
        { throw new InvalidDataException("Empreinte ou taille de définition héritée incorrecte."); }
        var recipe = QueryRecipeJson.Read(definition);
        if (recipe.Id != id || recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal) || recipe.Format != "Domenia.Query/" + version)
        { throw new InvalidDataException("Identité ou format de définition héritée incohérent."); }
        return QueryEngine.Compile(recipe);
    }
}
