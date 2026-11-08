using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeSettingsInspectionTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Malformed_fleet_JSON_is_an_unavailable_inspection_without_claiming_SQLite_corruption()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("malformed-fleet.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        const string malformed = "{invalid-fleet-json";
        using (var db = new SqliteDatabase(database.Path, false))
            db.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('fleet',?1) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload;", malformed);
        var snapshot = await database.InspectLocalStoreAsync(false, true, None);
        Check.False(snapshot.Available, "données illisibles signalées sans exception UI");
        Check.False(snapshot.Maintenance.Recovery, "JSON invalide ne prouve pas une corruption SQLite");
        Check.Contains("Inspection locale interrompue", snapshot.LastFailure, "cause de l’indisponibilité présentée");
        var view = StorageViewBuilder.Build(snapshot, StoragePolicyRules.Default, false, 6, 32, Fixtures.Now, TimeZoneInfo.Utc, snapshot.PathLabel);
        Check.Equal(snapshot.LastFailure, view.UnavailableReason, "cause transmise à la page");
        using var unchanged = new SqliteDatabase(database.Path, true);
        Check.Equal(malformed, unchanged.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string, "inspection seule ne modifie pas le cache");
    }

    [Test]
    public static async Task Inspection_counts_3500_machines_and_large_valid_payloads_without_a_purge_inventory()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("fleet.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        var computers = Enumerable.Range(1, 3500).Select(i => Fixtures.Computer("PC" + i.ToString("D4"))).ToArray();
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: computers), new(Fixtures.Postes, "Postes", true), "DC1", None);
        foreach (var batch in computers.Chunk(32))
        {
            await database.SaveFleetAsync(FleetCachePatch.Empty with
            { Observations = new(Fixtures.Now, [.. batch.Select(pc => Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero)))]) }, None);
        }
        // A legitimate detailed result can exceed the per-cell ceiling used by destructive operation proofs.
        var payload = JsonSerializer.Serialize(new { rows = Enumerable.Range(0, 5000).Select(i => new { id = i, description = new string('x', 70) }) });
        Check.True(payload.Length > 262144, "fixture au-delà de l’ancien plafond de la page");
        using (var db = new SqliteDatabase(database.Path, false))
        {
            db.Execute("INSERT INTO domenia_details(object_guid,result_kind,request_key,dn,attempt_at,status,payload,revision) VALUES(?1,'Wmi','inventory',?2,?3,'known',?4,1);",
                computers[0].ObjectGuid.ToString("D"), computers[0].DistinguishedName, Fixtures.Now.ToString("O"), payload);
        }
        var snapshot = await database.InspectLocalStoreAsync(false, false, None);
        Check.True(snapshot.Available, "page de stockage disponible pour le parc de 3500 postes");
        Check.Null(snapshot.LastFailure, "pas de faux diagnostic de panne ou de corruption");
        Check.Equal(3500L, snapshot.Counts.Objects!.Value, "compte complet de l’index");
        Check.Equal(3500L, snapshot.NativePurgeTargets.Single(x => x.Table == "domenia_v2_objects").Rows, "cible native comptée exactement");
        Check.Equal(1L, snapshot.NativePurgeTargets.Single(x => x.Table == "domenia_details").Rows, "grand résultat compté sans charger son contenu");
        Check.Equal(3500, (await new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(None)).Observations.Workstations.Length, "lots entièrement persistés et relus à froid");
        var preview = LocalStoreRules.PurgePlan(snapshot, ["observations"], 730, Fixtures.Now, TimeZoneInfo.Utc);
        await Check.ThrowsAsync<InvalidDataException>(() => database.PrepareStoragePurgeAsync(["observations"], 730, preview.Fingerprint, None), "la synthèse ne contourne pas les bornes de la preuve destructive");
        using var untouched = new SqliteDatabase(database.Path, true);
        Check.Equal(payload, untouched.Scalar("SELECT payload FROM domenia_details;") as string, "grand résultat intact après refus explicite du plan");
    }

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
