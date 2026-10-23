using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdQueryNativeTests
{
    private sealed class QueryCache(DirectorySnapshot directory) : IObjectDirectoryCache, IQueryResultsStore
    {
        public DirectorySnapshot Directory { get; set; } = directory;
        public QueryStoredReadings Stored { get; private set; } = QueryStoredReadings.Empty;
        public List<QueryComputerReadings> Writes { get; } = [];
        public bool FailWrites { get; set; }
        public bool LastWriteCancelable { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(Directory);
        public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken token) => ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Pas de recensement");
        public Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken token) => Task.FromResult(Directory = objects);
        public Task<QueryStoredReadings> ReadQueryResultsAsync(CancellationToken token) => Task.FromResult(Stored);
        public Task<QueryStoredReadings> SaveQueryResultsAsync(QueryComputerReadings next, CancellationToken token)
        {
            Writes.Add(next); LastWriteCancelable = token.CanBeCanceled;
            if (FailWrites) { throw new IOException("Stockage indisponible"); }
            var pc = Directory.Computers.SingleOrDefault(c => c.ObjectGuid == next.Computer);
            if (pc is null || pc.WhenCreated != next.Created || !DistinguishedName.AreEqual(pc.DistinguishedName, next.Dn))
            { throw new InvalidDataException("Identité locale modifiée"); }
            var merged = QueryReadingRules.Merge(Stored.Computers.SingleOrDefault(c => c.Computer == next.Computer), next);
            return Task.FromResult(Stored = new(Stored.Revision + 1, [.. Stored.Computers.Where(c => c.Computer != next.Computer), merged]));
        }
    }

    private static QueryComputerReadings Reading(DirectoryComputer pc, string? error = null) => new(pc.ObjectGuid, pc.DistinguishedName, pc.WhenCreated,
        [new("hw.model", Fixtures.Now, error, false, false, error is null ? 1 : null, error is null,
            error is null ? [new("0", ImmutableDictionary<string, object?>.Empty.Add("Model", "Portable"), [])] : [])], []);

    [Test]
    public static void Query_readings_never_merge_different_objects_or_recreated_identity()
    {
        var pc = Fixtures.Computer("PC1"); var before = Reading(pc);
        foreach (var next in new[] { before with { Computer = Guid.NewGuid(), Probes = [] }, before with { Created = before.Created.AddSeconds(1), Probes = [] },
            before with { Dn = Fixtures.Computer("PC2").DistinguishedName, Probes = [] } })
        { Check.Equal(0, QueryReadingRules.Merge(before, next).Probes.Length, "aucune mesure de l’ancienne identité"); }
        var failed = Reading(pc, "Lecture refusée");
        Check.Equal("Lecture refusée", QueryReadingRules.Merge(before, failed).Probes.Single().Error, "l’échec récent remplace le verdict");
        var old = before with { Probes = [before.Probes[0] with { CheckedAt = Fixtures.Now.AddMinutes(-1) }] };
        Check.Equal("Lecture refusée", QueryReadingRules.Merge(failed, old).Probes.Single().Error, "un résultat tardif plus ancien ne rajeunit pas le verdict");
    }

    [Test]
    public static void Query_readings_reject_embedded_objects_future_dates_and_false_complete_counts()
    {
        var good = Reading(Fixtures.Computer("PC1")); QueryReadingRules.Validate(good, Fixtures.Now);
        foreach (var probe in new[] { good.Probes[0] with { CheckedAt = Fixtures.Now.AddMinutes(3) }, good.Probes[0] with { Error = "Échec" },
            good.Probes[0] with { Count = 0 }, good.Probes[0] with { Instances = [new("0", ImmutableDictionary<string, object?>.Empty.Add("Model", new object()), [])] },
            good.Probes[0] with { Instances = [new("0", ImmutableDictionary<string, object?>.Empty.Add("Model", new string('x', 4097)), [])] } })
        { Check.Throws<InvalidDataException>(() => QueryReadingRules.Validate(good with { Probes = [probe] }, Fixtures.Now), "valeur non qualifiée refusée"); }
    }

    [Test]
    public static async Task Compatible_query_store_is_cold_readonly_persistent_and_identity_bound()
    {
        using var folder = new TemporaryFolder(); var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        var db = await cache.DatabaseAsync(CancellationToken.None);
        Check.Equal(0, (await cache.ReadQueryResultsAsync(CancellationToken.None)).Computers.Length, "lecture froide vide");
        Check.Null(await ((IQueryLibraryStore)cache).ReadAsync(QueryLibrary.RootKey(Fixtures.Root), CancellationToken.None), "bibliothèque froide absente");
        Check.False(File.Exists(db.Path), "aucune base créée par les lectures");
        await cache.PrepareAsync(CancellationToken.None);
        var pc = Fixtures.Computer("PC1"); await cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [pc]), "DC1.test.local", CancellationToken.None);
        var saved = await cache.SaveQueryResultsAsync(Reading(pc), CancellationToken.None);
        Check.Equal(1, saved.Computers.Length, "résultat conservé");
        var reopened = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        Check.Equal("Portable", (await reopened.ReadQueryResultsAsync(CancellationToken.None)).Computers[0].Probes[0].Instances[0].Values["Model"] as string, "scalaire restauré au redémarrage");
        await Check.ThrowsAsync<InvalidDataException>(() => cache.SaveQueryResultsAsync(Reading(pc with { ObjectGuid = Guid.NewGuid() }), CancellationToken.None), "GUID absent refusé");
        Check.True((await db.InspectAsync(CancellationToken.None))!.Backup is not null, "sauvegarde avant extension");
    }

    [Test]
    public static async Task Compatible_query_library_keeps_revisions_and_refuses_lost_updates()
    {
        using var folder = new TemporaryFolder();
        var store = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        var library = new QueryLibrary(store, new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var recipe = QueryRecipe.Empty(QueryTarget.Computer) with { Name = "Mon parc" };
        var first = await library.SaveAsync(Fixtures.Root, recipe, null, null, 0, "update", null, CancellationToken.None);
        var other = new QueryLibrary(new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var next = first.Record.Recipe with { Name = "Mon parc révisé" };
        var second = await other.SaveAsync(Fixtures.Root, next, null, null, 1, "update", null, CancellationToken.None);
        Check.Equal(2L, second.Record.Revision, "révision relue depuis SQLite");
        Check.Equal("SQLite", second.Receipt.Source, "support réel attesté");
        Check.Equal((await store.DatabaseAsync(CancellationToken.None)).StoreId, second.Receipt.StoreId, "base exacte dans le reçu");
        Check.True(second.Receipt.StoreRevision > first.Receipt.StoreRevision, "révision physique croissante");
        var bytes = await ((IQueryLibraryStore)store).ReadAsync(QueryLibrary.RootKey(Fixtures.Root), CancellationToken.None);
        Check.Equal(Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes!)), second.Receipt.DocumentSha256, "document réellement relu empreinté");
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.SaveAsync(Fixtures.Root, next with { Name = "Ancienne fenêtre" }, null, null, 1, "update", null, CancellationToken.None), "écriture obsolète refusée");
        var restored = await library.RevertAsync(Fixtures.Root, first.Record.Id, 1, 2, "update", CancellationToken.None);
        Check.Equal(3L, restored.Record.Revision, "restauration produit une nouvelle révision");
        Check.Equal(first.Record.Name, restored.Record.Name, "ancienne définition restaurée");
        Check.True(restored.Record.History.Any(h => h.Revision == 2), "révision remplacée conservée dans l’historique");
        await Check.ThrowsAsync<InvalidDataException>(() => ((IQueryLibraryStore)store).ReadAsync(QueryLibrary.RootKey("DC=other,DC=local"), CancellationToken.None), "bibliothèque étrangère refusée");
    }

    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(p => p.Name, p => p.Value));
    private static WmiWorkstationReader Native(Func<string, IReadOnlyList<WmiInstance>> read) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        {
            ReadOverride = (_, query, _) => read(query),
            MetadataOverride = (_, _, _, _) => [Row(("Name", "Name"), ("Type", "String"), ("Key", true)), Row(("Name", "Model"), ("Type", "String"), ("Key", false))],
        },
    };

    [Test]
    public static async Task Native_query_refuses_recreated_GUID_before_contact_and_keeps_local_view_network_free()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc with { ObjectGuid = Guid.NewGuid() })] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var contacts = 0; var reader = new AdQueryWmiReader(source) { InventoryReaderOverride = _ => { contacts++; return Native(_ => []); } };
        await new AdQueryWorkshopReader(source).DatasetAsync(CancellationToken.None);
        Check.Equal(0, contacts, "index local sans lecture machine");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SelectAsync(pc.ObjectGuid, @"root\cimv2", WqlRules.Parse("SELECT Model FROM Win32_ComputerSystem"), 10, CancellationToken.None), "compte recréé refusé");
        Check.Equal(0, contacts, "aucun SELECT après remplacement du GUID");
    }

    [Test]
    public static async Task Native_query_validates_both_identities_and_invalidates_old_count_after_failure()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var name = "PC1";
        var reader = new AdQueryWmiReader(source) { InventoryReaderOverride = _ => Native(query => query.StartsWith("SELECT Name FROM", StringComparison.Ordinal)
            ? [Row(("Name", name))] : [Row(("Name", "PC1"), ("Model", "Portable"))]) };
        var selected = await reader.SelectAsync(pc.ObjectGuid, @"root\cimv2", WqlRules.Parse("SELECT Model FROM Win32_ComputerSystem"), 10, CancellationToken.None);
        Check.Equal("Portable", selected.Rows.Single().Values["Model"], "données du poste confirmé");
        Check.False(selected.Truncated, "lecture complète");
        name = "OTHER";
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SelectAsync(pc.ObjectGuid, @"root\cimv2", WqlRules.Parse("SELECT Model FROM Win32_ComputerSystem"), 10, CancellationToken.None), "nom Windows étranger refusé");
        var data = await new AdQueryWorkshopReader(source).DatasetAsync(CancellationToken.None);
        Check.False(data.Details[pc.ObjectGuid].Single().Success, "ancien nombre remplacé par un échec, jamais zéro confirmé");
        Check.False(data.Details[pc.ObjectGuid].Single().CountComplete, "aucune exhaustivité inventée");
    }

    [Test]
    public static async Task Native_query_disk_failure_preserves_original_error_and_invalidates_session_count_and_evidence()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new QueryCache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var name = "PC1"; var contacts = 0;
        var reader = new AdQueryWmiReader(source) { InventoryReaderOverride = _ => Native(query =>
        {
            contacts++;
            return query.Contains("FROM Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", name))] : [Row(("Name", "Spooler"))];
        }) };
        var query = WqlRules.Parse("SELECT Name FROM Win32_Service");
        var selected = await reader.SelectAsync(pc.ObjectGuid, @"root\cimv2", query, 10, CancellationToken.None);
        var before = await new AdQueryWorkshopReader(source).DatasetAsync(CancellationToken.None);
        cache.FailWrites = true; name = "OTHER";
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SelectAsync(pc.ObjectGuid, @"root\cimv2", query, 10, CancellationToken.None), "échec initial conservé");
        Check.Equal(DomeniaErrors.SourceUnavailable, error.Code, "l’indisponibilité Windows n’est pas masquée par le disque");
        Check.True(error.Data["query.invalidation"] is string diagnostic && diagnostic.Contains(nameof(IOException), StringComparison.Ordinal), "diagnostic séparé de persistance");
        Check.True(cache.LastWriteCancelable, "invalidation persistante bornée indépendamment de l’appelant");
        Check.True(cache.Stored.Computers.Single().Details.Single().CountComplete, "disque inchangé dans ce défaut simulé");
        var after = await new AdQueryWorkshopReader(source).DatasetAsync(CancellationToken.None);
        Check.False(after.Details[pc.ObjectGuid].Single().Success, "échec visible malgré le défaut du disque");
        Check.False(after.Details[pc.ObjectGuid].Single().CountComplete, "ancien compte exhaustif jamais actuel");
        Check.True(before.Version != after.Version, "version locale invalidée même sans écriture");
        var countBeforeRelation = contacts;
        await Check.ThrowsAsync<QueryDefinitionException>(() => reader.RelatedAsync(pc.ObjectGuid, @"root\cimv2", "Win32_Service", selected.Rows.Single(),
            WqlRules.RelationPresets("Win32_Service").First(), CancellationToken.None), "preuve de l’ancienne instance retirée");
        Check.Equal(countBeforeRelation, contacts, "aucune relation après invalidation de la preuve");
    }

    [Test]
    public static async Task Native_query_failure_is_never_attributed_to_moved_or_reincarnated_cache_identity()
    {
        foreach (var moved in new[] { true, false })
        {
            var original = Fixtures.Computer("PC1"); var current = original;
            var cache = new QueryCache(Fixtures.Snapshot(computers: [original]));
            var query = WqlRules.Parse("SELECT Model FROM Win32_ComputerSystem");
            var key = WqlRules.RequestKey(@"root\cimv2", query.CanonicalQuery);
            await cache.SaveQueryResultsAsync(new(original.ObjectGuid, original.DistinguishedName, original.WhenCreated, [], [new(key, Fixtures.Now, true, 1, true, false)]), CancellationToken.None);
            using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == current.DistinguishedName ? [AdPosteNetworkTests.Entry(current)] : [] };
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
            var reader = new AdQueryWmiReader(source) { InventoryReaderOverride = _ => Native(q =>
            {
                if (q.StartsWith("SELECT Name FROM", StringComparison.Ordinal)) { return [Row(("Name", "PC1"))]; }
                current = moved ? original with { DistinguishedName = Fixtures.Computer("PC2").DistinguishedName } : original with { WhenCreated = original.WhenCreated.AddDays(1) };
                source.RememberObjectsAsync(Fixtures.Snapshot(computers: [current]), source.Epoch, CancellationToken.None).GetAwaiter().GetResult();
                return [Row(("Name", "PC1"), ("Model", "Portable"))];
            }) };
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SelectAsync(original.ObjectGuid, @"root\cimv2", query, 10, CancellationToken.None), "identité modifiée pendant lecture");
            Check.Equal(RelationErrors.IdentityChanged, error.Code, "erreur d’identité initiale conservée");
            var attempted = cache.Writes.Last();
            Check.Equal(original.DistinguishedName, attempted.Dn, "échec lié au DN réellement engagé");
            Check.Equal(original.WhenCreated, attempted.Created, "échec lié à l’incarnation réellement engagée");
            Check.True(error.Data.Contains("query.invalidation"), "refus du stockage distinct de l’erreur d’identité");
            var data = await new AdQueryWorkshopReader(source).DatasetAsync(CancellationToken.None);
            Check.False(data.Details.ContainsKey(current.ObjectGuid), "aucun résultat de l’ancienne identité attribué à la nouvelle");
            await source.RememberObjectsAsync(Fixtures.Snapshot(computers: [original]), source.Epoch, CancellationToken.None);
            var returned = await new AdQueryWorkshopReader(source).DatasetAsync(CancellationToken.None);
            Check.False(returned.Details[original.ObjectGuid].Single().CountComplete, "retour de l’ancien DN sans résurrection du compte exhaustif");
        }
    }

    [Test]
    public static async Task Workshop_probe_failure_invalidates_session_verdict_even_when_storage_fails()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new QueryCache(Fixtures.Snapshot(computers: [pc]));
        await cache.SaveQueryResultsAsync(Reading(pc), CancellationToken.None);
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdQueryWorkshopReader(source) { InventoryReaderOverride = _ => Native(_ => [Row(("Name", "OTHER"))]) };
        var before = await reader.DatasetAsync(CancellationToken.None); cache.FailWrites = true;
        var result = await reader.MeasureAsync(new([pc.ObjectGuid], false, false, false, ["hw.model"]), CancellationToken.None);
        Check.Equal(1, result.Failed, "échec Windows conservé dans le bilan malgré le disque");
        var after = await reader.DatasetAsync(CancellationToken.None);
        Check.True(after.Probes[pc.ObjectGuid].Single().Error is not null, "ancien verdict sonde invalidé en mémoire");
        Check.False(after.Probes[pc.ObjectGuid].Single().CountComplete, "ancien compte jamais annoncé complet après échec");
        Check.True(cache.Stored.Computers.Single().Probes.Single().CountComplete, "ancien disque conservé dans le défaut simulé");
        Check.True(cache.LastWriteCancelable, "persistance bornée");
        Check.True(before.Version != after.Version, "version locale modifiée sans persistance");
    }

    [Test]
    public static void Workshop_relation_paths_refuse_foreign_hosts_namespaces_and_multiple_keys()
    {
        Check.NotNull(WorkshopRelationPath.Parse("Win32_LogicalDisk.DeviceID=\"C:\"", "pc1.test.local", @"root\cimv2"), "chemin local accepté");
        foreach (var path in new[] { @"\\foreign\root\cimv2:Win32_LogicalDisk.DeviceID=""C:""", @"\\pc1\root\other:Win32_LogicalDisk.DeviceID=""C:""", "Win32_Service.Name=\"x\",Other=\"y\"" })
        { Check.Null(WorkshopRelationPath.Parse(path, "pc1.test.local", @"root\cimv2"), "chemin hors périmètre refusé"); }
    }
}
