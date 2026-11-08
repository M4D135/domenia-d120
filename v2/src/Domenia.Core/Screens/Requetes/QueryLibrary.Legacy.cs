using System.Text;
using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.Core.Queries;

public sealed record QueryLegacyReceipt(string SourceSha256, string Id, string Fingerprint, string Outcome, DateTimeOffset At);
public sealed record QueryLegacySourceReceipt(string SourceSha256, int Recipes, string ReceiptsSha256, DateTimeOffset At);
public sealed record QueryLegacyMigration(string SourceSha256, int Imported, int AlreadyPresent, int Conflicts, bool SourcePreserved);

public sealed partial class QueryLibrary
{
    public const int LegacyBatchRecipes = 50;
    public const int LegacyBatchBytes = 2_500_000;
    private const int MaxLegacyReceipts = 20_000;

    // The original setting is never deleted. Each batch commits recipes and replay receipts in the same document.
    private async Task<byte[]?> MigrateLegacyAsync(string key, byte[]? current, string original, CancellationToken token)
    {
        if (Encoding.UTF8.GetByteCount(original) > MaxDocumentBytes)
            throw new QueryDefinitionException("Ancienne bibliothèque supérieure à 16 Mio : original conservé, reprise refusée.");
        var source = QueryRecipeJson.Sha256(original);
        State known;
        var currentHash = current is null ? "" : Convert.ToHexStringLower(SHA256.HashData(current));
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (cache.TryGetValue(key, out var cached) && cached.Hash == currentHash) known = cached.State;
            else { ValidateReadEnvelope(current, key); known = Parse(current); }
        }
        finally { gate.Release(); }
        if (known.Newer || known.WholeUnreadable || known.RejectedRows)
            throw new QueryDefinitionException("La bibliothèque courante doit être lisible avant la reprise ; originaux conservés.");
        if (known.LegacySources.Any(r => r.SourceSha256 == source)) return current;
        JsonDocument parsed;
        try { parsed = JsonDocument.Parse(original, new JsonDocumentOptions { MaxDepth = 96 }); }
        catch (JsonException) { throw new QueryDefinitionException("Ancienne bibliothèque JSON illisible : source conservée, aucune recette importée."); }
        using var document = parsed;
        var root = document.RootElement;
        UniqueProperties(root);
        if (root.ValueKind != JsonValueKind.Object || Text(root, "Format", "") != "Domenia.QueryLibrary/1"
            || !root.TryGetProperty("Queries", out var queries) || queries.ValueKind != JsonValueKind.Array || queries.GetArrayLength() > MaxRecipes)
            throw new QueryDefinitionException("Ancienne bibliothèque invalide ou supérieure à 5 000 recettes ; original conservé.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var recipes = new List<(QueryRecipe Recipe, string Fingerprint, int Bytes)>();
        // Validate the entire source before the first write, including rows that already have a receipt.
        foreach (var item in queries.EnumerateArray())
        {
            token.ThrowIfCancellationRequested();
            var compiled = QueryEngine.Compile(QueryRecipeJson.Read(item.GetRawText()));
            var recipe = compiled.Normalized;
            var size = Encoding.UTF8.GetByteCount(QueryRecipeJson.Write(recipe));
            if (!ids.Add(recipe.Id) || recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal) || size > 1_048_576)
                throw new QueryDefinitionException("Ancienne recette dupliquée, réservée ou supérieure à 1 Mio ; reprise refusée avant écriture.");
            var preview = new State(); var at = clock.GetUtcNow();
            preview.Records.Add(LegacyRecord(recipe, compiled.Fingerprint, at));
            preview.LegacyReceipts.Add(new(source, recipe.Id, compiled.Fingerprint, "imported", at));
            // Count the actual escaped outer document, including receipt/metadata, with conservative clock/header headroom.
            var wireBytes = Serialize(preview, key, at).Length + 128;
            if (wireBytes > LegacyBatchBytes) throw new QueryDefinitionException("Ancienne recette supérieure à la borne de transaction (2,5 Mo) ; source conservée.");
            recipes.Add((recipe, compiled.Fingerprint, wireBytes));
        }
        var received = known.LegacyReceipts.Where(r => r.SourceSha256 == source).Select(r => r.Id).ToHashSet(StringComparer.Ordinal);
        var pending = recipes.Where(r => !received.Contains(r.Recipe.Id)).ToArray();
        var start = 0;
        do
        {
            token.ThrowIfCancellationRequested();
            var end = start; var bytes = 0;
            while (end < pending.Length && end - start < LegacyBatchRecipes && bytes + pending[end].Bytes <= LegacyBatchBytes)
            { bytes += pending[end].Bytes; end++; }
            var batch = pending[start..end];
            var (_, write) = await MutateAsync(key, state =>
            {
                if (state.WholeUnreadable) throw new QueryDefinitionException("Bibliothèque devenue illisible : reprise suspendue, source conservée.");
                var now = clock.GetUtcNow();
                var existing = state.Records.ToDictionary(r => r.Id, StringComparer.Ordinal);
                var receipts = state.LegacyReceipts.Where(r => r.SourceSha256 == source).Select(r => r.Id).ToHashSet(StringComparer.Ordinal);
                foreach (var row in batch)
                {
                    if (!receipts.Add(row.Recipe.Id)) continue;
                    if (state.LegacyReceipts.Count >= MaxLegacyReceipts)
                        throw new QueryDefinitionException("Journal de reprise plein : aucune ancienne preuve supprimée, reprise suspendue.");
                    string outcome;
                    if (existing.TryGetValue(row.Recipe.Id, out var previous))
                        outcome = previous.Fingerprint == row.Fingerprint ? "present" : "conflict";
                    else
                    {
                        if (state.Records.Count >= MaxRecipes) throw new QueryDefinitionException("Bibliothèque pleine (5 000 recettes) ; reprise suspendue, source conservée.");
                        state.Records.Add(LegacyRecord(row.Recipe, row.Fingerprint, now));
                        outcome = "imported";
                    }
                    state.LegacyReceipts.Add(new(source, row.Recipe.Id, row.Fingerprint, outcome, now));
                    state.Dirty = true;
                }
                if (end == pending.Length && !state.LegacySources.Any(r => r.SourceSha256 == source))
                {
                    if (state.LegacySources.Count >= 256) throw new QueryDefinitionException("256 sources historiques conservées : reprise suspendue sans effacer les preuves.");
                    var all = state.LegacyReceipts.Where(r => r.SourceSha256 == source).ToArray();
                    var expected = recipes.ToDictionary(r => r.Recipe.Id, r => r.Fingerprint, StringComparer.Ordinal);
                    if (all.Length != recipes.Count || all.Any(r => !expected.TryGetValue(r.Id, out var fingerprint) || fingerprint != r.Fingerprint))
                        throw new QueryDefinitionException("Reçus incomplets ou incohérents : aucun succès de reprise annoncé.");
                    state.LegacySources.Add(new(source, recipes.Count, LegacyReceiptHash(all), now)); state.Dirty = true;
                }
                return true;
            }, token).ConfigureAwait(false);
            if (write is { ReadBack: false }) throw new QueryDefinitionException("Reprise envoyée mais non confirmée : relisez la bibliothèque ; source conservée.");
            start = end;
        } while (start < pending.Length);
        return await store.ReadAsync(key, token).ConfigureAwait(false);
    }

    private static QueryLibraryRecord LegacyRecord(QueryRecipe recipe, string fingerprint, DateTimeOffset at) =>
        new(recipe.Id, recipe.Name, "Reprises de Domenia 1", "Ancienne préférence Query.Library ; original conservé.", 1, at, at, false, fingerprint, recipe, null, [], []);

    private static string LegacyReceiptHash(IEnumerable<QueryLegacyReceipt> rows) => QueryRecipeJson.Sha256(JsonSerializer.Serialize(
        rows.OrderBy(r => r.Id, StringComparer.Ordinal).Select(r => new { r.SourceSha256, r.Id, r.Fingerprint, r.Outcome }), StoreJson));

    private static QueryLegacyMigration? MigrationSummary(State state)
    {
        if (state.LegacyReceipts.LastOrDefault() is not { } latest) return null;
        var rows = state.LegacyReceipts.Where(r => r.SourceSha256 == latest.SourceSha256).ToArray();
        return new(latest.SourceSha256, rows.Count(r => r.Outcome == "imported"), rows.Count(r => r.Outcome == "present"), rows.Count(r => r.Outcome == "conflict"), true);
    }

    private static void ReadLegacyReceipts(JsonElement root, State state)
    {
        if (!root.TryGetProperty("legacyReceipts", out var list)) return;
        if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > MaxLegacyReceipts)
            throw new QueryDefinitionException("Journal de reprise invalide ; bibliothèque inchangée.");
        var keys = new HashSet<(string, string)>();
        foreach (var row in list.EnumerateArray())
        {
            var receipt = row.Deserialize<QueryLegacyReceipt>(StoreJson);
            if (receipt is null || receipt.SourceSha256 is not { Length: 64 } || !receipt.SourceSha256.All(char.IsAsciiHexDigitLower)
                || receipt.Fingerprint is not { Length: 64 } || !receipt.Fingerprint.All(char.IsAsciiHexDigitLower)
                || receipt.Id is not { Length: > 0 and <= 80 } || receipt.Outcome is not ("imported" or "present" or "conflict")
                || !keys.Add((receipt.SourceSha256, receipt.Id)))
                throw new QueryDefinitionException("Preuve de reprise invalide ou dupliquée ; bibliothèque inchangée.");
            state.LegacyReceipts.Add(receipt);
        }
        if (!root.TryGetProperty("legacySources", out var sources)) return;
        if (sources.ValueKind != JsonValueKind.Array || sources.GetArrayLength() > 256) throw new QueryDefinitionException("Sources de reprise hors limites.");
        var hashes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in sources.EnumerateArray())
        {
            var source = row.Deserialize<QueryLegacySourceReceipt>(StoreJson);
            if (source is null || source.SourceSha256 is not { Length: 64 } || !source.SourceSha256.All(char.IsAsciiHexDigitLower)
                || source.ReceiptsSha256 is not { Length: 64 } || !source.ReceiptsSha256.All(char.IsAsciiHexDigitLower)
                || source.Recipes is < 0 or > MaxRecipes || !hashes.Add(source.SourceSha256))
                throw new QueryDefinitionException("Preuve de source invalide ou dupliquée.");
            var completedRows = state.LegacyReceipts.Where(r => r.SourceSha256 == source.SourceSha256).ToArray();
            if (completedRows.Length != source.Recipes || LegacyReceiptHash(completedRows) != source.ReceiptsSha256)
                throw new QueryDefinitionException("Preuve de reprise complète incohérente ; bibliothèque conservée.");
            state.LegacySources.Add(source);
        }
    }

    private static void ValidateReadEnvelope(byte[]? bytes, string key, bool allowDamaged = false)
    {
        if (bytes is null) return;
        if (bytes.Length == 0) throw new QueryDefinitionException("Bibliothèque existante vide ou tronquée : aucune liste publiée ni nouvelle écriture. Original conservé.");
        if (bytes.Length > MaxDocumentBytes) throw new QueryDefinitionException("Bibliothèque supérieure à 16 Mio : aucune liste partielle publiée.");
        JsonDocument document;
        try { document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 96 }); }
        catch (JsonException) when (allowDamaged) { return; }
        catch (JsonException) { throw new QueryDefinitionException("Bibliothèque JSON illisible : aucune liste partielle publiée, original conservé."); }
        using (document)
        {
            var root = document.RootElement;
            UniqueProperties(root);
            if (root.ValueKind != JsonValueKind.Object || Text(root, "format", "") != DocumentFormat) return;
            if (root.TryGetProperty("version", out var declared) && declared.ValueKind == JsonValueKind.Number && declared.TryGetInt32(out var declaredVersion))
            {
                var admission = ContractCatalog.Decide("queryLibrary", DocumentFormat + "/" + declaredVersion.ToString(System.Globalization.CultureInfo.InvariantCulture));
                if (!admission.Allowed) throw new QueryDefinitionException(admission.Message);
            }
            if (root.TryGetProperty("version", out var version) && version.TryGetInt32(out var number) && number >= 4
                && (!root.TryGetProperty("legacyReceipts", out var receipts) || receipts.ValueKind != JsonValueKind.Array
                    || !root.TryGetProperty("legacySources", out var sources) || sources.ValueKind != JsonValueKind.Array))
                throw new QueryDefinitionException("Journal de reprise absent : aucun remplacement d’une bibliothèque version 4.");
            if (Text(root, "domainKey", "") != key) throw new QueryDefinitionException("Bibliothèque d’un autre domaine ; aucune publication ni écriture.");
            foreach (var (name, limit) in new[] { ("recipes", MaxRecipes), ("widgets", MaxWidgets), ("consumers", MaxConsumers),
                ("unreadable", 10000), ("legacyReceipts", MaxLegacyReceipts) })
                if (root.TryGetProperty(name, out var list) && (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > limit))
                    throw new QueryDefinitionException("Bibliothèque hors limites (" + name + ") ; aucun élément tronqué.");
            var ids = new HashSet<string>(StringComparer.Ordinal);
            if (root.TryGetProperty("recipes", out var recipes))
                foreach (var record in recipes.EnumerateArray())
                {
                    if (record.ValueKind != JsonValueKind.Object) continue; // Kept verbatim in the unreadable collection.
                    var id = Text(record, "id", "");
                    if (id.Length > 0 && !ids.Add(id)) throw new QueryDefinitionException("Identité de recette dupliquée ; aucune liste partielle publiée.");
                    if (record.TryGetProperty("definition", out var definition) && definition.ValueKind == JsonValueKind.String)
                    {
                        var text = definition.GetString()!;
                        if (Encoding.UTF8.GetByteCount(text) > 1_048_576) throw new QueryDefinitionException("Définition supérieure à 1 Mio ; bibliothèque inchangée.");
                        try
                        {
                            using var recipe = JsonDocument.Parse(text);
                            if (recipe.RootElement.TryGetProperty("Id", out var recipeId) && recipeId.ValueKind == JsonValueKind.String && recipeId.GetString() != id)
                                throw new QueryDefinitionException("Identités de recette incohérentes ; bibliothèque inchangée.");
                        }
                        catch (JsonException) { /* The existing unreadable-record path preserves malformed definitions. */ }
                    }
                }
        }
    }

    private static void UniqueProperties(JsonElement item)
    {
        if (item.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in item.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new QueryDefinitionException("Propriété de bibliothèque dupliquée ; lecture ambiguë refusée.");
                UniqueProperties(property.Value);
            }
        }
        else if (item.ValueKind == JsonValueKind.Array)
            foreach (var child in item.EnumerateArray()) UniqueProperties(child);
    }
}
