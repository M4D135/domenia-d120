using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class CollectionWriteContextTests
{
    [Test]
    public static async Task Real_store_refuses_wrong_request_store_and_ended_context_without_changing_previous_readings()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var pc = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("context.db"), Fixtures.Root, clock); await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Root, "", true), "DC1", default);
        var identity = new CollectionWriteContext(Guid.NewGuid().ToString("N"), db.StoreId, Fixtures.Root, 4);
        var patch = Patch(pc) with { CollectionContext = identity };
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(patch, default), "un identifiant dans le payload ne remplace pas le contexte attendu");
        using (CollectionWrites.Enter(identity, () => true))
        {
            await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(patch with { CollectionContext = identity with { RequestId = Guid.NewGuid().ToString("N") } }, default), "requête substituée refusée");
            await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(patch with { CollectionContext = identity with { StoreId = new('f', 64) } }, default), "base substituée refusée");
            var status = await db.InspectLocalStoreAsync(false, false, default);
            Check.Equal(0, status.Writer.Failures, "trois refus de contexte ne sont pas trois incidents de disque");
            Check.Equal(0, status.Writer.Pending, "aucun lot non autorisé conservé pour rejeu");
            Check.False(status.Writer.Suspended, "un relevé légitime peut encore être enregistré");
            await db.SaveFleetAsync(patch, default);
        }
        Check.Equal(1, (await new DomeniaDatabase(db.Path, Fixtures.Root, clock).ReadFleetAsync(default)).Observations.Workstations.Length, "écriture positive réellement persistée");
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(patch, default), "contexte terminé non rejoué implicitement");
        Check.Equal(1, (await db.ReadFleetAsync(default)).Observations.Workstations.Length, "refus sans perte des valeurs précédentes");
    }

    [Test]
    public static async Task Context_is_checked_again_immediately_before_commit_and_rolls_back_an_epoch_change()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var pc = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("rollback.db"), Fixtures.Root, clock); await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Root, "", true), "DC1", default);
        long Revision() { using var sql = new SqliteDatabase(db.Path, true); return (long)sql.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")!; }
        var before = Revision(); var checks = 0;
        var identity = new CollectionWriteContext(Guid.NewGuid().ToString("N"), db.StoreId, Fixtures.Root, 1);
        using (CollectionWrites.Enter(identity, () => Interlocked.Increment(ref checks) < 3))
            await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(Patch(pc) with { CollectionContext = identity }, default), "époque devenue différente après les upserts mais avant COMMIT");
        Check.Equal(3, checks, "contrôles admission, écrivain réellement démarré et validation finale");
        Check.Equal(before, Revision(), "révision transactionnelle non avancée");
        Check.Equal(0, (await new DomeniaDatabase(db.Path, Fixtures.Root, clock).ReadFleetAsync(default)).Observations.Workstations.Length, "aucune valeur partiellement publiée");
    }

    [Test]
    public static async Task Source_binds_the_remote_patch_to_its_actual_store_and_rejects_reset_during_handoff()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var pc = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock); await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Root, "", true), "DC1", default);
        var cache = new InterleavedCache(new SqliteDirectoryCache(db));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        await source.ReadLocalAsync(default);
        await source.SaveFleetAsync(Patch(pc), source.Epoch, default);
        Check.NotNull(cache.Last, "contexte attaché par la source réelle");
        Check.Equal(db.StoreId, cache.Last!.StoreId, "base réellement chargée, pas un identifiant d’interface");
        Check.Equal(source.Epoch, cache.Last.SessionEpoch, "génération du relevé");
        cache.BeforeSave = source.Reset;
        await Check.ThrowsAsync<InvalidDataException>(() => source.SaveFleetAsync(Patch(pc), source.Epoch, default), "changement entre la remise et le début du store refusé");
        Check.Equal(1, (await db.ReadFleetAsync(default)).Observations.Workstations.Length, "ancien succès conservé après changement de compte");
    }

    private static FleetCachePatch Patch(DirectoryComputer pc) => FleetCachePatch.Empty with
    { Observations = new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero))]) };

    private sealed class InterleavedCache(SqliteDirectoryCache inner) : IDirectoryCache, IAccueilCache
    {
        internal CollectionWriteContext? Last;
        internal Action? BeforeSave;
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => inner.ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => inner.SaveAsync(snapshot, scope, controller, token);
        public Task<CachedFleet> ReadFleetAsync(CancellationToken token) => inner.ReadFleetAsync(token);
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken token) => inner.ReadFleetHistoryAsync(scope, token);
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken token)
        { Last = patch.CollectionContext; BeforeSave?.Invoke(); return inner.SaveFleetAsync(patch, token); }
    }
}
