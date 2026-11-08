using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class QueryLibrarySnapshotTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    internal static QueryLibrary Library(IQueryLibraryStore store) => new(store, new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
    internal static QueryRecipe Recipe(string id, string? name = null) => QueryRecipe.Empty(QueryTarget.Computer, id) with { Name = name ?? id };

    [Test]
    public static async Task Ambiguous_or_oversized_read_never_publishes_a_partial_list_or_overwrites_the_original()
    {
        using var store = new MemoryQueryLibraryStore(); using var library = Library(store);
        var saved = await library.SaveAsync(Fixtures.Root, Recipe("snapshot.one"), null, null, 0, "update", null, None);
        var key = QueryLibrary.RootKey(Fixtures.Root); var initial = (await store.ReadAsync(key, None))!;
        foreach (var fault in new[] { "duplicate", "domain", "identity", "tooMany", "oversize", "replayLedger", "fingerprint", "empty" })
        {
            var json = JsonNode.Parse(initial)!.AsObject();
            if (fault == "duplicate") json["recipes"]!.AsArray().Add(json["recipes"]![0]!.DeepClone());
            if (fault == "domain") json["domainKey"] = QueryLibrary.RootKey("DC=other,DC=local");
            if (fault == "identity") json["recipes"]![0]!["id"] = "snapshot.other";
            if (fault == "tooMany") json["recipes"] = new JsonArray(Enumerable.Range(0, 5001).Select(_ => (JsonNode?)null).ToArray());
            if (fault == "replayLedger") json.Remove("legacyReceipts");
            if (fault == "fingerprint") json["recipes"]![0]!["fingerprint"] = new string('0', 64);
            byte[] bytes = fault == "empty" ? [] : fault == "oversize" ? new byte[QueryLibrary.MaxDocumentBytes + 1] : Encoding.UTF8.GetBytes(json.ToJsonString());
            await store.UpdateAsync(key, _ => new(bytes, false), None);
            await Check.ThrowsAsync<QueryDefinitionException>(() => library.ReadAsync(Fixtures.Root, None), fault + " refusé avant publication");
            await Check.ThrowsAsync<QueryDefinitionException>(() => library.SaveAsync(Fixtures.Root, saved.Record.Recipe with { Name = "Ne doit pas remplacer" }, null, null, 1, "update", null, None), fault + " interdit aussi la mutation");
            var retained = (await store.ReadAsync(key, None))!;
            Check.True(bytes.SequenceEqual(retained), "original intégral conservé : " + fault);
            await store.UpdateAsync(key, _ => new(initial, false), None);
            Check.Equal("snapshot.one", (await library.ReadAsync(Fixtures.Root, None)).Records.Single().Name, "liste précédente retrouvée intacte après refus");
        }
    }

    [Test]
    public static async Task Native_read_uses_one_committed_snapshot_while_a_second_connection_changes_the_library()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        using var library = Library(new SqliteDirectoryCache(database));
        var saved = await library.SaveAsync(Fixtures.Root, Recipe("snapshot.native"), null, null, 0, "update", null, None);
        var key = QueryLibrary.RootKey(Fixtures.Root);
        var original = (await database.ReadQueryLibraryAsync(key, None))!;
        var next = JsonNode.Parse(original)!.AsObject(); next["generation"] = 2;
        next["recipes"]![0]!["description"] = "Deuxième instant";
        var changed = next.ToJsonString();
        using (var writer = new SqliteDatabase(database.Path, false))
        {
            writer.Begin();
            writer.Execute("UPDATE domenia_v2_query_library SET document=?1 WHERE domain_key=?2;", changed, key);
            var during = await database.ReadQueryLibraryAsync(key, None);
            Check.True(original.SequenceEqual(during!), "aucune moitié de transaction publiée malgré document temporairement différent de son empreinte");
            writer.Execute("UPDATE domenia_v2_query_library SET sha256=?1 WHERE domain_key=?2;", QueryRecipeJson.Sha256(changed), key);
            writer.Commit();
        }
        using var cold = Library(new SqliteDirectoryCache(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed())));
        var after = await cold.ReadAsync(Fixtures.Root, None);
        Check.Equal(2L, after.Generation, "nouvelle génération lue intégralement après commit");
        Check.Equal("Deuxième instant", after.Records.Single().Description, "contenu de la même génération");
        Check.True(after.Persistent && saved.Receipt is { Persisted: true, ReadBack: true }, "SQLite réel et reçu relu sous transaction");
    }

    [Test]
    public static async Task Native_library_reads_all_5000_rows_and_refuses_5001_without_truncation()
    {
        using var folder = new TemporaryFolder(); var database = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None); var key = QueryLibrary.RootKey(Fixtures.Root);
        var rows = Enumerable.Range(0, QueryLibrary.MaxRecipes).Select(i =>
        {
            var compiled = QueryEngine.Compile(Recipe("scale." + i));
            return new { id = compiled.Normalized.Id, definition = QueryRecipeJson.Write(compiled.Normalized), fingerprint = compiled.Fingerprint,
                category = "Échelle", description = "", revision = 1, createdAt = Fixtures.Now, updatedAt = Fixtures.Now, archived = false };
        }).ToArray();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { format = QueryLibrary.DocumentFormat, version = QueryLibrary.DocumentVersion,
            domainKey = key, generation = 1, recipes = rows, widgets = Array.Empty<object>(), consumers = Array.Empty<object>(),
            imports = Array.Empty<object>(), referenceReceipts = Array.Empty<object>(), legacyReceipts = Array.Empty<object>(), legacySources = Array.Empty<object>(),
            unreadable = Array.Empty<object>(), packVersions = new { } });
        await database.UpdateQueryLibraryAsync(key, _ => new(bytes, false), None);
        using var library = Library(new SqliteDirectoryCache(database));
        var content = await library.ReadAsync(Fixtures.Root, None);
        Check.Equal(5000, content.Records.Count, "aucune pagination fictive ni troncature du snapshot SQLite");
        Check.True(rows.Select(r => r.id).ToHashSet(StringComparer.Ordinal).SetEquals(content.Records.Select(r => r.Id)), "identités exactes jusqu’à la dernière");
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.SaveAsync(Fixtures.Root, Recipe("scale.5000"), null, null, 0, "update", null, None), "5001 refusé avant écriture");
        var retained = (await database.ReadQueryLibraryAsync(key, None))!;
        Check.True(bytes.SequenceEqual(retained), "les 5000 recettes restent intégrales à l’octet");
    }

    [Test]
    public static async Task Missing_real_store_keeps_module_composition_available_but_never_offers_a_memory_save()
    {
        using var source = new Domenia.Ad.AdDirectorySource("test.local", () => @"TEST\reader", TestClock.Fixed(),
            connection: new AdBoundaryTests.RecordingAdConnection());
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Test", null, "test.local", []), source,
            new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        var module = new Domenia.Bridge.RequetesOperations();
        Check.True(module.CreateOperations(context).Any(o => o.Name == "requetes.library.list"), "composition du module possible même sans base locale");
        var library = Domenia.Bridge.Operations.Requetes.RequetesServices.Library(context);
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.ReadAsync(Fixtures.Root, None), "lecture indisponible, jamais une liste mémoire vide confirmée");
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.SaveAsync(Fixtures.Root, Recipe("refused"), null, null, 0, "update", null, None), "aucun faux enregistrement mémoire en mode AD réel");
    }

    [Test]
    public static async Task Memory_medium_defends_its_bytes_when_a_reader_or_failed_update_mutates_an_array()
    {
        using var store = new MemoryQueryLibraryStore(); const string key = "test";
        await store.UpdateAsync(key, _ => new([1, 2, 3], false), None);
        var read = (await store.ReadAsync(key, None))!; read[0] = 99;
        await Check.ThrowsAsync<InvalidOperationException>(() => store.UpdateAsync(key, bytes =>
        { bytes![1] = 99; throw new InvalidOperationException("Rejet"); }, None), "callback refusé");
        var retained = (await store.ReadAsync(key, None))!;
        Check.True(new byte[] { 1, 2, 3 }.SequenceEqual(retained), "aucune mutation hors transaction du magasin mémoire");
    }
}
