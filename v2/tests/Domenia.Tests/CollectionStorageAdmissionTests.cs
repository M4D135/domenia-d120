using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class CollectionStorageAdmissionTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static void Queue_adjusted_thresholds_are_identical_for_admission_settings_and_sync_without_overflow()
    {
        foreach (var queued in new[] { 0L, 1024L * 1024, long.MaxValue })
        {
            var boundary = CollectionStorageRules.Reserve(LocalStoreRules.SuspendReserve, queued);
            foreach (var free in new[] { boundary - 1, boundary })
            {
                var space = new LocalStoreSpace(free, Fixtures.Now, queued);
                var view = LocalStoreRules.Space(space, Fixtures.Now, TimeZoneInfo.Utc);
                var sync = SyncCoverageRules.Storage(false, 0, free, Fixtures.Now, queued, Fixtures.Now, TimeZoneInfo.Utc);
                Check.Equal(free < boundary, view.BlocksCollections, "seuil Settings exact, aucun dépassement numérique");
                Check.Equal(view.BlocksCollections, sync.Refusal is not null, "même règle de la Base autonome");
                if (view.BlocksCollections)
                {
                    var error = Check.Throws<DomeniaOperationException>(() => CollectionStorageRules.Ensure(new(space, false, false, 0, null), Fixtures.Now, TimeZoneInfo.Utc), "collecte réellement refusée");
                    Check.Equal(CollectionStorageRules.InsufficientSpace, error.Code, "code de refus stable");
                }
                else CollectionStorageRules.Ensure(new(space, false, false, 0, null), Fixtures.Now, TimeZoneInfo.Utc);
            }
        }
        var unknown = LocalStoreRules.Space(new(null, null, 0), Fixtures.Now, TimeZoneInfo.Utc);
        Check.Equal("unknown", unknown.State, "absence de mesure conservée");
        Check.True(LocalStoreRules.Space(new(1, Fixtures.Now.AddHours(-1), 0), Fixtures.Now, TimeZoneInfo.Utc).Stale, "mesure ancienne explicite");
    }

    [Test]
    public static async Task Actual_database_volume_blocks_new_AD_and_presence_reads_before_any_connection()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("volume.db"), Fixtures.Root, TestClock.Fixed()) { FreeSpaceProbe = () => 511L * 1024 * 1024 };
        var cache = new SqliteDirectoryCache(database);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        foreach (var family in new[] { MeasureFamily.Directory, MeasureFamily.DomainAccounts, MeasureFamily.Presence, MeasureFamily.Inventory })
        {
            var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => source.RefreshAsync(family, new(Fixtures.Postes, "Postes", true), None), "aucune lecture avant admission du volume de la base");
            Check.Equal(CollectionStorageRules.InsufficientSpace, failure.Code, "cause d’espace explicite");
        }
        await Check.ThrowsAsync<DomeniaOperationException>(() => cache.PrepareAsync(None), "préparation directe elle aussi protégée avant création");
        Check.Equal(0, ldap.Searches.Count, "aucune recherche LDAP ni collecte implicite");
        Check.False(File.Exists(database.Path), "pas de création de base avant refus");
    }

    [Test]
    public static async Task Held_payload_and_suspension_remain_blocking_even_after_free_space_recovers()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("held.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None); database.FreeSpaceProbe = () => 1;
        var patch = FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(Fixtures.Computer("PC1"), Fixtures.Presence(true, TimeSpan.Zero))]) };
        await Check.ThrowsAsync<IOException>(() => database.SaveFleetAsync(patch, None), "lot conservé après refus disque");
        database.FreeSpaceProbe = () => long.MaxValue;
        var state = await database.CollectionStorageAsync(None);
        Check.True(state.Suspended && state.Space.QueuedBytes > 0, "vraie file retenue et suspension sans déduction depuis les préférences");
        var error = Check.Throws<DomeniaOperationException>(() => CollectionStorageRules.Ensure(state, Fixtures.Now, TimeZoneInfo.Utc), "reprise explicite obligatoire");
        Check.Equal(CollectionStorageRules.Unavailable, error.Code, "aucune reprise automatique après libération du disque");
        Check.Equal(0, (await database.ReadFleetAsync(None)).Observations.Workstations.Length, "lot non rejoué");
    }
}
