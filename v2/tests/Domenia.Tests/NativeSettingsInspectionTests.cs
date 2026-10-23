using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeSettingsInspectionTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Legacy_inspection_separates_schema_revision_data_revision_and_domain_notation()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("legacy.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        using (var db = new SqliteDatabase(database.Path, false)) { db.Execute("UPDATE domenia_store_state SET revision=987 WHERE id=1;"); }
        var snapshot = await database.InspectLocalStoreAsync(false, false, None);
        Check.Equal(987L, snapshot.Revision, "révision des données conservée");
        Check.Equal("11", snapshot.Legacy.Database!.SchemaVersion, "version du schéma isolée");
        Check.Equal("1", snapshot.Legacy.Database.Revision, "révision du schéma, pas celle des données");
        Check.Equal(0, LegacyRules.Plan(snapshot.Legacy, "test.local").Blockers.Length, "même domaine reconnu en DNS et DN");
        Check.True(LegacyRules.Plan(snapshot.Legacy, "other.local").Blockers.Length > 0, "autre domaine refusé");
    }

    [Test]
    public static async Task Unsupported_schema_is_not_mislabeled_as_corruption_or_unimplemented_storage()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("unsupported.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        using (var db = new SqliteDatabase(database.Path, false)) { db.Execute("UPDATE schema_info SET value='12' WHERE key='schema_version';"); }
        var snapshot = await database.InspectLocalStoreAsync(false, true, None);
        Check.False(snapshot.Available, "schéma refusé");
        Check.False(snapshot.Maintenance.Recovery, "un schéma différent n’est pas une corruption prouvée");
        Check.Equal("Inconnu", snapshot.Schema, "aucun schéma inventé");
        var view = StorageViewBuilder.Build(snapshot, StoragePolicyRules.Default, false, 6, 32, Fixtures.Now, TimeZoneInfo.Utc, snapshot.PathLabel);
        Check.Equal(snapshot.LastFailure, view.UnavailableReason, "cause réelle préservée");
        Check.True(view.Integrity is not null, "diagnostic d’intégrité conservé dans la vue indisponible");
    }

    [Test]
    public static async Task Proven_notadb_keeps_the_original_and_offers_only_restore()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("broken.db"), Fixtures.Root, TestClock.Fixed());
        File.WriteAllText(database.Path, "Ce fichier n’est pas une base SQLite.");
        var before = File.ReadAllBytes(database.Path);
        var snapshot = await database.InspectLocalStoreAsync(false, true, None);
        Check.True(snapshot.Available && snapshot.Maintenance.Recovery, "base présente et corruption prouvée");
        var maintenance = LocalStoreRules.Maintenance(snapshot);
        Check.True(maintenance.Restore, "restauration proposée");
        Check.False(maintenance.Move || maintenance.Resume || maintenance.Rollback, "aucune autre maintenance");
        Check.True(before.SequenceEqual(File.ReadAllBytes(database.Path)), "original intact");
    }
}
