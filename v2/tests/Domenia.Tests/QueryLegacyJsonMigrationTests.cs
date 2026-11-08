using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class QueryLegacyJsonMigrationTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static string Legacy(IEnumerable<QueryRecipe> recipes) => JsonSerializer.Serialize(new
    { Format = "Domenia.QueryLibrary/1", Queries = recipes.Select(r => JsonSerializer.Deserialize<JsonElement>(QueryRecipeJson.Write(r))) });

    private sealed class LegacyStore(IQueryLibraryStore inner, string original, CancellationTokenSource? stop = null) : IQueryLibraryStore
    {
        internal readonly List<int> BatchSizes = [];
        internal readonly List<int> BatchBytes = [];
        public bool Persistent => inner.Persistent;
        public Task<byte[]?> ReadAsync(string key, CancellationToken token) => inner.ReadAsync(key, token);
        public Task<string?> ReadLegacyAsync(string key, CancellationToken token) => Task.FromResult<string?>(original);
        public async Task<QueryStoreWrite?> UpdateAsync(string key, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken token)
        {
            var receipt = await inner.UpdateAsync(key, before =>
            {
                var next = update(before);
                if (next is not null)
                {
                    using var previous = before is null ? null : JsonDocument.Parse(before);
                    using var after = JsonDocument.Parse(next.Document);
                    var previousCount = previous is not null && previous.RootElement.TryGetProperty("legacyReceipts", out var ledger) ? ledger.GetArrayLength() : 0;
                    BatchSizes.Add(after.RootElement.GetProperty("legacyReceipts").GetArrayLength() - previousCount);
                    BatchBytes.Add(next.Document.Length - (before?.Length ?? 0));
                }
                return next;
            }, token);
            if (receipt is not null) stop?.Cancel();
            return receipt;
        }
    }

    [Test]
    public static async Task Interrupted_native_migration_resumes_from_durable_receipts_and_never_replaces_local_changes()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        var native = (IQueryLibraryStore)new SqliteDirectoryCache(database);
        using (var seed = QueryLibrarySnapshotTests.Library(native))
            await seed.SaveAsync(Fixtures.Root, QueryLibrarySnapshotTests.Recipe("legacy.0", "Définition locale conservée"), null, null, 0, "update", null, None);
        var recipes = Enumerable.Range(0, 123).Select(i => QueryLibrarySnapshotTests.Recipe("legacy." + i)).ToArray();
        var original = Legacy(recipes);
        using var stop = new CancellationTokenSource(); var interrupted = new LegacyStore(native, original, stop);
        using (var library = QueryLibrarySnapshotTests.Library(interrupted))
            await Check.ThrowsAsync<OperationCanceledException>(() => library.ReadAsync(Fixtures.Root, stop.Token), "arrêt entre deux transactions bornées");
        Check.Equal(50, interrupted.BatchSizes.Single(), "premier lot de 50 reçus, y compris le conflit conservé");
        using (var first = QueryLibrarySnapshotTests.Library(native))
        {
            var partial = await first.ReadAsync(Fixtures.Root, None);
            Check.Equal(50, partial.Records.Count, "49 imports et la recette locale existante sont durables");
            Check.Equal(1, partial.LegacyMigration!.Conflicts, "conflit visible sans remplacement");
            var row = partial.Records.Single(r => r.Id == "legacy.1");
            await first.SaveAsync(Fixtures.Root, row.Recipe with { Name = "Correction après interruption" }, null, null, row.Revision, "update", null, None);
        }
        var coldNative = (IQueryLibraryStore)new SqliteDirectoryCache(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()));
        var resumed = new LegacyStore(coldNative, original);
        using var cold = QueryLibrarySnapshotTests.Library(resumed);
        var content = await cold.ReadAsync(Fixtures.Root, None);
        Check.Equal(123, content.Records.Count, "toutes les identités après reprise à froid");
        Check.True(resumed.BatchSizes.SequenceEqual(new[] { 50, 23 }), "seulement les deux lots restants");
        Check.Equal("Définition locale conservée", content.Records.Single(r => r.Id == "legacy.0").Name, "conflit conservé");
        Check.Equal("Correction après interruption", content.Records.Single(r => r.Id == "legacy.1").Name, "aucun rejeu de la définition historique déjà reçue");
        var before = (await coldNative.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), None))!;
        await cold.ReadAsync(Fixtures.Root, None);
        var after = (await coldNative.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), None))!;
        Check.True(before.SequenceEqual(after), "relecture idempotente à l’octet");
        Check.Equal(122, content.LegacyMigration!.Imported, "compte des importations durables");
        Check.True(resumed.BatchBytes.All(n => n <= QueryLibrary.LegacyBatchBytes), "volume réel ajouté par transaction borné");
        using var document = JsonDocument.Parse(before);
        Check.Equal(123, document.RootElement.GetProperty("legacySources")[0].GetProperty("recipes").GetInt32(), "preuve durable de source entièrement examinée");
        var damaged = System.Text.Json.Nodes.JsonNode.Parse(before)!.AsObject();
        damaged["legacySources"]![0]!["recipes"] = 124;
        await MemoryProof(damaged);
        async Task MemoryProof(System.Text.Json.Nodes.JsonObject invalid)
        {
            using var memory = new MemoryQueryLibraryStore(); var key = QueryLibrary.RootKey(Fixtures.Root);
            await memory.UpdateAsync(key, _ => new(System.Text.Encoding.UTF8.GetBytes(invalid.ToJsonString()), false), None);
            using var guard = QueryLibrarySnapshotTests.Library(new LegacyStore(memory, original));
            await Check.ThrowsAsync<QueryDefinitionException>(() => guard.ReadAsync(Fixtures.Root, None), "fausse preuve de source complète refusée avant reprise");
        }
    }

    [Test]
    public static async Task Actual_compatible_store_finds_the_original_setting_and_defers_during_real_source_maintenance()
    {
        using var folder = new TemporaryFolder();
        var app = folder.File("app"); var user = folder.File("user"); Directory.CreateDirectory(app); Directory.CreateDirectory(user);
        var path = Path.Combine(app, "Domenia.settings.json");
        var text = JsonSerializer.Serialize(new Dictionary<string, string> { ["Query.Library"] = Legacy([QueryLibrarySnapshotTests.Recipe("legacy.actual")]) });
        File.WriteAllText(path, text);
        var cache = new CompatibleDirectoryCache(app, user, "test.local", TestClock.Fixed());
        using var source = new AdDirectorySource("test.local", () => @"TEST\reader", TestClock.Fixed(),
            connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        var prepared = await cache.DatabaseAsync(None);
        using (var inactive = QueryLibrarySnapshotTests.Library(source.QueryLibraryStore!))
        { await Check.ThrowsAsync<DomeniaOperationException>(() => inactive.ReadAsync(Fixtures.Root, None), "aucune migration n’initialise une base absente implicitement"); }
        Check.False(File.Exists(prepared.Path), "refus avant création de la base");
        await prepared.InitializeAsync(None); // Explicitly prepare the active destination before testing maintenance.
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var maintenance = source.RunLocalCopyAsync(async _ => { entered.SetResult(); await release.Task; return true; }, None);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            using var busy = QueryLibrarySnapshotTests.Library(source.QueryLibraryStore!);
            await Check.ThrowsAsync<DomeniaOperationException>(() => busy.ReadAsync(Fixtures.Root, None), "reprise différée pendant la vraie réservation de maintenance");
        }
        finally { release.TrySetResult(); await maintenance; }
        using var library = QueryLibrarySnapshotTests.Library(source.QueryLibraryStore!);
        var content = await library.ReadAsync(Fixtures.Root, None);
        Check.True(content.Persistent && content.LegacyMigration is { Imported: 1, SourcePreserved: true }, "reprise SQLite après libération, reçue et affichable");
        Check.Equal(text, File.ReadAllText(path), "préférences historiques inchangées");
        var database = await cache.DatabaseAsync(None);
        using var cold = QueryLibrarySnapshotTests.Library(new SqliteDirectoryCache(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed())));
        Check.Equal("legacy.actual", (await cold.ReadAsync(Fixtures.Root, None)).Records.Single().Id, "vraie relecture SQLite à froid");
    }

    [Test]
    public static async Task Real_serialized_batch_budget_splits_large_frozen_selections_below_2_point_5_MB()
    {
        var ids = Enumerable.Range(0, QueryLimits.MaxObjectIds).Select(i => Fixtures.IdOf("migration" + i).ToString("D")).ToImmutableArray();
        var recipes = Enumerable.Range(0, 4).Select(i => QueryLibrarySnapshotTests.Recipe("large." + i) with { ObjectIds = ids });
        using var memory = new MemoryQueryLibraryStore(); var source = new LegacyStore(memory, Legacy(recipes));
        using var library = QueryLibrarySnapshotTests.Library(source);
        var read = await library.ReadAsync(Fixtures.Root, None);
        Check.Equal(4, read.Records.Count, "sélections complètes conservées");
        Check.True(source.BatchSizes.Count > 1 && source.BatchSizes.All(n => n <= 50), "volume force plusieurs lots avant la borne de 50");
        Check.True(source.BatchBytes.All(n => n <= QueryLibrary.LegacyBatchBytes), "vrais octets ajoutés, avec échappement JSON et reçus");
        Check.True(read.Records.All(r => r.Recipe.ObjectIds is { Length: 20000 }), "aucune sélection tronquée");
    }

    private sealed class BlockingLibraryCache(IQueryLibraryStore inner) : IDirectoryCache, IQueryLibraryStore
    {
        internal readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Persistent => inner.Persistent;
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(Fixtures.Snapshot());
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Aucune écriture AD dans ce scénario.");
        public Task<byte[]?> ReadAsync(string key, CancellationToken token) => inner.ReadAsync(key, token);
        public async Task<QueryStoreWrite?> UpdateAsync(string key, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken token)
        { Entered.TrySetResult(); await Release.Task.WaitAsync(token); return await inner.UpdateAsync(key, update, token); }
    }

    [Test]
    public static async Task Maintenance_drains_a_library_write_already_admitted_and_refuses_new_writes_without_replay()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        var blocked = new BlockingLibraryCache(new SqliteDirectoryCache(database));
        using var source = new AdDirectorySource("test.local", () => @"TEST\reader", TestClock.Fixed(), localStore: blocked,
            connection: new AdBoundaryTests.RecordingAdConnection());
        using var library = QueryLibrarySnapshotTests.Library(source.QueryLibraryStore!);
        var writing = library.SaveAsync(Fixtures.Root, QueryLibrarySnapshotTests.Recipe("admitted"), null, null, 0, "update", null, None);
        await blocked.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var entered = false;
        var maintenance = source.RunLocalCopyAsync(_ => { entered = true; return Task.FromResult(true); }, None);
        try
        {
            Check.True(source.MaintenanceRequested, "maintenance annoncée pendant l’attente du commit");
            Check.False(entered, "copie pas commencée sous l’écriture admise");
            using var newcomer = QueryLibrarySnapshotTests.Library(source.QueryLibraryStore!);
            await Check.ThrowsAsync<DomeniaOperationException>(() => newcomer.SaveAsync(Fixtures.Root, QueryLibrarySnapshotTests.Recipe("refused"), null, null, 0, "update", null, None), "nouvelle écriture refusée sans attendre ni rejouer");
        }
        finally { blocked.Release.TrySetResult(); await writing; await maintenance; }
        Check.True(entered, "maintenance admise seulement après libération de la bibliothèque");
        using var cold = QueryLibrarySnapshotTests.Library(new SqliteDirectoryCache(database));
        Check.Equal("admitted", (await cold.ReadAsync(Fixtures.Root, None)).Records.Single().Id, "seule l’écriture réellement admise est durable");
    }

    [Test]
    public static async Task Duplicate_or_oversized_legacy_sources_are_validated_before_the_first_batch()
    {
        foreach (var original in new[] { Legacy([QueryLibrarySnapshotTests.Recipe("same"), QueryLibrarySnapshotTests.Recipe("same")]),
            Legacy(Enumerable.Range(0, 5001).Select(i => QueryLibrarySnapshotTests.Recipe("many." + i))), new string('x', QueryLibrary.MaxDocumentBytes + 1) })
        {
            using var memory = new MemoryQueryLibraryStore(); var source = new LegacyStore(memory, original);
            using var library = QueryLibrarySnapshotTests.Library(source);
            await Check.ThrowsAsync<QueryDefinitionException>(() => library.ReadAsync(Fixtures.Root, None), "source invalide refusée avant mutation");
            Check.Equal(0, source.BatchSizes.Count, "aucun lot partiel");
            Check.True(await memory.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), None) is null, "aucune bibliothèque vide créée par un échec");
        }
    }
}
