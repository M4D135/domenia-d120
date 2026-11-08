using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdLocalMaintenanceTests
{
    private sealed class Cache(DirectorySnapshot directory) : IObjectDirectoryCache, IAccueilCache, ILocalStoreInspection
    {
        internal DirectorySnapshot Directory = directory;
        internal CachedFleet Fleet = CachedFleet.Empty("maintenance");
        internal int Writes;
        internal TaskCompletionSource? SaveEntered;
        internal TaskCompletionSource? ReleaseSave;
        internal LocalStoreSnapshot? Snapshot;
        internal int Inspections;
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(Directory);
        public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken token) => ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Pas de recensement.");
        public Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot snapshot, string? controller, CancellationToken token) { Writes++; return Task.FromResult(Directory = snapshot); }
        public Task<CachedFleet> ReadFleetAsync(CancellationToken token) => Task.FromResult(Fleet);
        public async Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken token)
        {
            SaveEntered?.TrySetResult();
            if (ReleaseSave is { } release) await release.Task.WaitAsync(token);
            Writes++; return Fleet = Fleet.Merge(patch);
        }
        public Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken token)
        { Inspections++; return Task.FromResult(Snapshot ?? throw new InvalidDataException("Snapshot fixture absent.")); }
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken token) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    }

    [Test]
    public static async Task Maintenance_keeps_operator_documents_and_receipts_writable_while_local_mutations_are_refused()
    {
        using var folder = new TemporaryFolder(); var cache = new Cache(Fixtures.Snapshot());
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        await source.ReadLocalAsync(default); var session = await source.GetSessionAsync(default);
        using var receipts = new FileReceiptStore(folder.File("receipts/log.jsonl"), new RecordingJournal());
        var documents = new FileDocumentStore(folder.File("exports"), new RecordingJournal());
        var plan = WritePlans.Seal(FakeWriteExecutor.Draft(FakeWriteExecutor.TargetGuid), WritePlans.NewId(), @"TEST\test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        await source.RunLocalMaintenanceAsync(async token =>
        {
            await Check.ThrowsAsync<DomeniaOperationException>(() => Task.Run(() => { using var blocked = source.AcquireWriteLease(session); }), "mutation métier refusée pendant maintenance");
            await receipts.AppendAsync(WriteReceipts.Sent(plan, WritePlans.NewId(), Fixtures.Now, new("Contrôle", "Preuve opérateur")), token);
            var document = await documents.SaveFileAsync("diagnostic.txt", System.Text.Encoding.UTF8.GetBytes("État à conserver"), token);
            Check.True(document.Saved, "document opérateur enregistré pendant maintenance");
            Check.Equal(1, (await receipts.ReadAllAsync(token)).Receipts.Length, "preuve de l’opérateur jamais bloquée par maintenance de la base");
            return true;
        }, default);
    }

    [Test]
    public static async Task Read_only_backup_keeps_in_flight_collection_generation_and_loaded_projections()
    {
        var cache = new Cache(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        var before = await source.ReadLocalAsync(default); var generation = source.Epoch;
        await source.RunLocalCopyAsync(async _ =>
        {
            Check.True(source.MaintenanceRequested, "nouvelle admission suspendue pendant copie");
            await Check.ThrowsAsync<DomeniaOperationException>(() => source.EnsureCollectionStorageAsync(default), "pas de nouvelle collecte pendant la copie");
            return true;
        }, default);
        Check.Equal(generation, source.Epoch, "sauvegarder ne change pas l’identité des données");
        Check.True(ReferenceEquals(before.Directory, (await source.ReadLocalAsync(default)).Directory), "aucune projection invalidée par une simple copie");
        await source.SaveFleetAsync(FleetCachePatch.Empty, generation, default);
        Check.Equal(1, cache.Writes, "résultat commencé avant copie encore enregistrable, jamais perdu");
    }

    [Test]
    public static async Task Drain_and_job_are_visible_while_old_publication_finishes_and_new_collections_are_refused()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("maintenance.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var cache = new Cache(Fixtures.Snapshot()) { Snapshot = await database.InspectLocalStoreAsync(false, false, default),
            SaveEntered = new(TaskCreationOptions.RunContinuationsAsynchronously), ReleaseSave = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        await source.ReadLocalAsync(default);
        var reader = new AdSettingsReader(source); await reader.LocalStoreAsync(default);
        var pending = source.SaveFleetAsync(FleetCachePatch.Empty, source.Epoch, default);
        await cache.SaveEntered.Task;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var maintenance = source.RunLocalMaintenanceAsync(async _ => { entered.SetResult(); await release.Task; return true; }, default);
        try
        {
            var draining = await reader.LocalStoreAsync(default);
            Check.True(draining.Maintenance.Draining, "vidange réelle visible avant fin de l’écrivain");
            Check.Contains("Copie en attente", LocalStoreRules.Maintenance(draining).Text, "libellé branché à l’état réel");
            Check.False(entered.Task.IsCompleted, "aucune copie avant la fin de publication");
            await Check.ThrowsAsync<DomeniaOperationException>(() => source.EnsureCollectionStorageAsync(default), "admission suspendue même sur cache sans capacité disque");
            await Check.ThrowsAsync<DomeniaOperationException>(() => source.RunLocalMaintenanceAsync(_ => Task.FromResult(true), default), "seconde maintenance refusée sans attente");
            cache.ReleaseSave.SetResult(); await pending; await entered.Task;
            var running = await reader.LocalStoreAsync(default);
            Check.False(running.Maintenance.Draining, "fin de vidange");
            Check.True(running.Maintenance.Job is not null, "étape réelle visible pendant la mutation");
            Check.False(LocalStoreRules.Maintenance(running).Move, "autres actions désactivées");
            Check.Equal(1, cache.Inspections, "état pendant maintenance sans relire une base verrouillée");
            await Check.ThrowsAsync<DomeniaOperationException>(() => reader.MeasureAsync(default), "diagnostic différé pendant maintenance");
        }
        finally { cache.ReleaseSave.TrySetResult(); release.TrySetResult(); await pending; await maintenance; }
        Check.False((await reader.LocalStoreAsync(default)).Maintenance.Draining || source.MaintenanceRequested, "état et admission libérés");
        Check.Equal(1, cache.Writes, "publication antérieure terminée une seule fois");
    }

    [Test]
    public static async Task Drain_timeout_or_cancellation_keeps_results_and_releases_all_reservations()
    {
        foreach (var cancel in new[] { false, true })
        {
            var cache = new Cache(Fixtures.Snapshot()) { SaveEntered = new(TaskCreationOptions.RunContinuationsAsynchronously), ReleaseSave = new(TaskCreationOptions.RunContinuationsAsynchronously) };
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache)
                { MaintenanceDrainBudget = TimeSpan.FromMilliseconds(cancel ? 120000 : 30) };
            await source.ReadLocalAsync(default); var epoch = source.Epoch; var mutations = 0;
            var pending = source.SaveFleetAsync(FleetCachePatch.Empty, epoch, default); await cache.SaveEntered.Task;
            using var stop = new CancellationTokenSource();
            var maintenance = source.RunLocalMaintenanceAsync(_ => { mutations++; return Task.FromResult(true); }, stop.Token);
            if (cancel) stop.Cancel();
            try
            {
                var failure = await Check.ThrowsAsync<Exception>(() => maintenance.WaitAsync(TimeSpan.FromSeconds(5)), "attente bornée");
                Check.True(cancel ? failure is OperationCanceledException : failure is DomeniaOperationException { Code: "storage.busy" }, "cause exacte conservée");
                Check.Equal(0, mutations, "aucune mutation commencée"); Check.Equal(epoch, source.Epoch, "aucune invalidation avant drain terminé");
                Check.False(source.MaintenanceRequested, "réservation libérée malgré refus");
            }
            finally { cache.ReleaseSave.TrySetResult(); await pending; }
            await source.RunLocalMaintenanceAsync(_ => Task.FromResult(true), default);
            Check.Equal(1, cache.Writes, "résultat en attente conservé sans rejeu");
        }
    }

    [Test]
    public static async Task Local_maintenance_replaces_loaded_objects_and_rejects_old_collection_publication()
    {
        var old = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]); var cache = new Cache(old);
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); var generation = source.Epoch;
        await source.RunLocalMaintenanceAsync(_ =>
        {
            cache.Directory = Fixtures.Snapshot(computers: [Fixtures.Computer("PC2")]);
            cache.Fleet = CachedFleet.Empty("replacement"); return Task.FromResult(true);
        }, CancellationToken.None);
        Check.Equal("PC2", (await source.ReadLocalAsync(CancellationToken.None)).Directory.Computers.Single().Name, "cache déjà chargé remplacé");
        Check.Equal("replacement", source.FleetDetails.Facts.StoreId, "mesures anciennes remplacées");
        await Check.ThrowsAsync<DomeniaOperationException>(() => source.SaveFleetAsync(FleetCachePatch.Empty, generation, CancellationToken.None), "ancienne collecte refusée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => source.RememberObjectsAsync(old, generation, CancellationToken.None), "ancienne lecture ciblée refusée");
        Check.Equal(0, cache.Writes, "aucune donnée supprimée réintroduite");
    }

    [Test]
    public static async Task Readers_wait_for_local_maintenance_and_stale_writers_cannot_overtake_it()
    {
        var cache = new Cache(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); var generation = source.Epoch;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var maintenance = source.RunLocalMaintenanceAsync(async _ =>
        {
            started.SetResult(); await release.Task.ConfigureAwait(false);
            cache.Directory = Fixtures.Snapshot(computers: []); return true;
        }, CancellationToken.None);
        await started.Task;
        var reading = source.ReadLocalAsync(CancellationToken.None);
        var oldWrite = source.SaveFleetAsync(FleetCachePatch.Empty, generation, CancellationToken.None);
        Check.False(reading.IsCompleted || oldWrite.IsCompleted, "lecture et publication attendent la maintenance");
        release.SetResult(); await maintenance;
        Check.Equal(0, (await reading).Directory.Computers.Length, "lecture du stockage après transaction");
        await Check.ThrowsAsync<DomeniaOperationException>(() => oldWrite, "publication retardée invalidée");
        Check.Equal(0, cache.Writes, "ancien résultat jamais enregistré");
    }

    [Test]
    public static async Task Failed_maintenance_keeps_old_cache_invalid_and_releases_every_publication_lock()
    {
        var cache = new Cache(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); var generation = source.Epoch;
        await Check.ThrowsAsync<IOException>(() => source.RunLocalMaintenanceAsync<bool>(_ =>
        {
            cache.Directory = Fixtures.Snapshot(computers: []);
            throw new IOException("Réponse perdue après modification locale.");
        }, CancellationToken.None), "échec préservé");
        Check.Equal(0, (await source.ReadLocalAsync(CancellationToken.None)).Directory.Computers.Length, "ancienne projection non réutilisée");
        Check.True(source.Epoch != generation, "résultats engagés avant maintenance invalidés");
        await source.RunLocalMaintenanceAsync(_ => Task.FromResult(true), CancellationToken.None);
        await source.SaveFleetAsync(FleetCachePatch.Empty, source.Epoch, CancellationToken.None);
        Check.Equal(1, cache.Writes, "verrous libérés après échec");
    }
}
