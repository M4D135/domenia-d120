using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class AdLocalMaintenanceTests
{
    private sealed class Cache(DirectorySnapshot directory) : IObjectDirectoryCache, IAccueilCache
    {
        internal DirectorySnapshot Directory = directory;
        internal CachedFleet Fleet = CachedFleet.Empty("maintenance");
        internal int Writes;
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(Directory);
        public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken token) => ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Pas de recensement.");
        public Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot snapshot, string? controller, CancellationToken token) { Writes++; return Task.FromResult(Directory = snapshot); }
        public Task<CachedFleet> ReadFleetAsync(CancellationToken token) => Task.FromResult(Fleet);
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken token) { Writes++; return Task.FromResult(Fleet = Fleet.Merge(patch)); }
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken token) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
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
