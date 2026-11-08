using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class FleetRowsScaleTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static FleetCachePatch Patch(DirectoryComputer pc, bool answered) => FleetCachePatch.Empty with
    { Observations = new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(answered, TimeSpan.Zero))]) };
    private static async Task<DomeniaDatabase> Create(TemporaryFolder folder, params DirectoryComputer[] computers)
    {
        var database = new DomeniaDatabase(folder.File("fleet.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: computers), new(Fixtures.Postes, "Postes", true), "DC1", None);
        return database;
    }

    [Test]
    public static async Task Hundred_thousand_native_rows_reopen_completely_and_repeated_single_host_writes_touch_only_that_host()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("REAL");
        var database = await Create(folder, pc);
        await database.SaveFleetAsync(Patch(pc, true), None);
        Guid neighbour = default;
        using (var sql = new SqliteDatabase(database.Path, false))
        {
            var template = JsonNode.Parse((string)sql.Scalar("SELECT payload FROM domenia_v2_fleet_rows WHERE row_key=?1;", pc.ObjectGuid.ToString("D"))!)!;
            sql.Begin();
            for (var i = 1; i < 100_000; i++)
            {
                var id = new Guid(i, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3); if (i == 1) neighbour = id;
                template["observation"]!["computerGuid"] = id.ToString("D");
                var payload = template.ToJsonString();
                sql.Execute("INSERT INTO domenia_v2_fleet_rows(row_key,kind,payload,sha256) VALUES(?1,'computer',?2,?3);", id.ToString("D"), payload, Hash(payload));
            }
            sql.Commit();
        }
        var reopened = new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed());
        await reopened.InitializeAsync(None);
        var snapshot = await reopened.ReadFleetAsync(None);
        Check.Equal(100_000, snapshot.Observations.Workstations.Length, "aucun plafond silencieux, tous les postes relus à froid");
        var originalNeighbour = snapshot.Observations.Find(neighbour);
        Check.NotNull(originalNeighbour, "index complet après réouverture");
        long generation; string neighbourBytes;
        using (var sql = new SqliteDatabase(database.Path, true))
        {
            generation = (long)sql.Scalar("SELECT generation FROM domenia_v2_fleet_state WHERE id=1;")!;
            neighbourBytes = (string)sql.Scalar("SELECT payload FROM domenia_v2_fleet_rows WHERE row_key=?1;", neighbour.ToString("D"))!;
            Check.True((long)sql.Scalar("SELECT length(payload) FROM domenia_v2_metadata WHERE key='fleet';")! < 4096, "en-tête borné indépendamment des 100 000 postes");
        }
        using (await reopened.AcquireOperationsLeaseAsync(None))
        {
            for (var i = 0; i < 20; i++)
            {
                var saved = await reopened.SaveFleetAsync(Patch(pc, i % 2 != 0), None);
                Check.True(ReferenceEquals(originalNeighbour, saved.Observations.Find(neighbour)), "chaque lot réutilise les objets immuables inchangés au lieu de désérialiser le parc");
                Check.True(ReferenceEquals(snapshot.Probes.ByProbe, saved.Probes.ByProbe), "une mesure de présence ne reconstruit pas les relevés des sondes");
            }
        }
        using var verified = new SqliteDatabase(database.Path, true);
        Check.Equal(generation + 20, (long)verified.Scalar("SELECT generation FROM domenia_v2_fleet_state WHERE id=1;")!, "exactement une ligne modifiée par lot, aucun delete/rewrite global");
        Check.Equal(100_000L, (long)verified.Scalar("SELECT computers FROM domenia_v2_fleet_state WHERE id=1;")!, "compteur transactionnel exact");
        Check.Equal(neighbourBytes, verified.Scalar("SELECT payload FROM domenia_v2_fleet_rows WHERE row_key=?1;", neighbour.ToString("D")) as string, "octets du voisin préservés");
        Check.Equal((long)verified.Scalar("SELECT sum(length(CAST(payload AS BLOB))) FROM domenia_v2_fleet_rows;")!, (long)verified.Scalar("SELECT bytes FROM domenia_v2_fleet_state WHERE id=1;")!, "budget en octets exact après les patches");
    }

    [Test]
    public static void Indexed_observations_preserve_old_snapshots_wire_format_and_timestamp_rules()
    {
        var pc = Fixtures.Computer("PC1"); var old = Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.FromMinutes(10)), Fixtures.Disk(100, 50, TimeSpan.FromMinutes(10)));
        var before = new FleetObservations(Fixtures.Now.AddMinutes(-10), [old]);
        var failedInventory = InventoryMeasure.Unread with { State = MeasureState.Error, CheckedAt = Fixtures.Now };
        var after = before.Merge(new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.Zero), failedInventory)]));
        Check.True(ReferenceEquals(old, before.Find(pc.ObjectGuid)), "snapshot précédent intact");
        Check.Equal(false, after.Find(pc.ObjectGuid)!.Presence.Answered, "nouveau ping reçu");
        Check.Equal(MeasureState.Error, after.Find(pc.ObjectGuid)!.Inventory.State, "échec courant explicite");
        Check.Equal(old.Inventory, after.Find(pc.ObjectGuid)!.Inventory.LastSuccessful, "dernier succès conservé avec sa date, sans déguiser la tentative");
        var roundtrip = JsonSerializer.Deserialize<FleetObservations>(JsonSerializer.Serialize(after, Json), Json)!;
        Check.Equal(after.Find(pc.ObjectGuid), roundtrip.Find(pc.ObjectGuid), "constructeur JSON historique et lecture indexée compatibles");
        var fleet = new CachedFleet(after, AccueilFacts.Empty("test"), ProbeReadings.Empty);
        Check.True(ReferenceEquals(after, fleet.Merge(FleetCachePatch.Empty).Observations), "patch sans observation conserve la référence du snapshot");
        var late = after.Merge(new(Fixtures.Now.AddHours(-1), [Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.FromHours(1)))]));
        Check.Equal(false, late.Find(pc.ObjectGuid)!.Presence.Answered, "résultat arrivé tardivement mais daté plus ancien ignoré");
        var replaced = after with { Workstations = [] };
        Check.Null(replaced.Find(pc.ObjectGuid), "with Workstations invalide correctement l’index dérivé");
    }

    [Test]
    public static async Task Legacy_migration_is_atomic_preserves_facts_and_keeps_a_readable_pre_migration_backup()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var db = await Create(folder, pc);
        var legacy = CachedFleet.Empty(db.StoreId).Merge(Patch(pc, true));
        legacy = legacy with { Facts = legacy.Facts with { RejectedObservations = 7,
            Machines = legacy.Facts.Machines.Add(pc.ObjectGuid, new("TEST\\alice", Fixtures.Now, "BIOS", Fixtures.Now, MeasureState.Known, Fixtures.Now, null)),
            BitLocker = [new(Fixtures.Postes, true, Fixtures.Now, true, false, ImmutableDictionary<Guid, BitLockerFact>.Empty.Add(pc.ObjectGuid, new(2, Fixtures.Now)))],
            Runs = [new(CollectionFamily.Directory, Fixtures.Root, Fixtures.Postes, true, CollectionStatus.Success, Fixtures.Now.AddMinutes(-1), Fixtures.Now, null, 1, 1, 1, 0, "DC1", "AD")] } };
        var raw = JsonSerializer.Serialize(legacy, Json);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('fleet',?1);", raw);
            sql.Script("CREATE TRIGGER abort_migration BEFORE UPDATE ON domenia_v2_metadata WHEN NEW.key='fleet' BEGIN SELECT RAISE(ABORT,'migration interrupted'); END;");
        }
        await Check.ThrowsAsync<SqliteStoreException>(() => db.SaveFleetAsync(Patch(pc, false), None), "interruption de migration après création des lignes natives");
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            Check.Equal(raw, sql.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string, "ancien JSON intact après rollback");
            Check.Equal("1", sql.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") as string, "ancien lecteur toujours compatible après échec");
            Check.Equal(0L, (long)sql.Scalar("SELECT count(*) FROM sqlite_master WHERE name='domenia_v2_fleet_rows';")!, "DDL et lignes de la migration annulés ensemble");
            sql.Execute("DROP TRIGGER abort_migration;");
        }
        var migrated = await db.SaveFleetAsync(Patch(pc, false), None);
        Check.Equal(7, migrated.Facts.RejectedObservations, "compteur de relevés écartés préservé");
        Check.Equal("TEST\\alice", migrated.Facts.Machines[pc.ObjectGuid].ConsoleUser, "faits du cache historique préservés");
        var inspection = (await db.InspectAsync(None))!;
        Check.Equal(2, inspection.SchemaRevision, "barrière explicite empêchant l’ancien exécutable de lire un faux parc vide");
        using (var backup = new SqliteDatabase(inspection.Backup!.Path, true))
        {
            Check.Equal("1", backup.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") as string, "backup utilisable par l’ancien lecteur");
            Check.Equal(raw, backup.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string, "copie exacte du cache avant migration, même si la sauvegarde précédente était récente");
        }
        var cold = await new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(None);
        Check.Equal(false, cold.Observations.Find(pc.ObjectGuid)!.Presence.Answered, "nouvelle mesure après migration relue");
        Check.Equal(7, cold.Facts.RejectedObservations, "compteur conservé à froid");
        Check.Equal(legacy.Facts.Runs.Single(), cold.Facts.Runs.Single(), "historique de campagne conservé");
        Check.Equal(2, cold.Facts.BitLocker.Single().Machines[pc.ObjectGuid].Keys, "périmètre BitLocker conservé séparément");
        using var sqlAfter = new SqliteDatabase(db.Path, true);
        Check.Equal(1L, (long)sqlAfter.Scalar("SELECT computers FROM domenia_v2_fleet_state;")!, "une ligne poste");
        Check.Equal(1L, (long)sqlAfter.Scalar("SELECT scopes FROM domenia_v2_fleet_state;")!, "une ligne périmètre");
    }

    [Test]
    public static async Task External_row_mutations_and_dropped_guards_cannot_reuse_a_stale_process_snapshot()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var db = await Create(folder, pc);
        await db.SaveFleetAsync(Patch(pc, true), None);
        long revision;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            revision = (long)sql.Scalar("SELECT revision FROM domenia_store_state;")!;
            var row = JsonNode.Parse((string)sql.Scalar("SELECT payload FROM domenia_v2_fleet_rows;")!)!;
            row["observation"]!["presence"]!["answered"] = false;
            var raw = row.ToJsonString();
            sql.Execute("UPDATE domenia_v2_fleet_rows SET payload=?1,sha256=?2;", raw, Hash(raw));
        }
        Check.Equal(false, (await db.ReadFleetAsync(None)).Observations.Find(pc.ObjectGuid)!.Presence.Answered, "mutation extérieure prise en compte sans révision globale");
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            Check.Equal(revision, (long)sql.Scalar("SELECT revision FROM domenia_store_state;")!, "fixture n’a pas incrémenté la révision globale");
            var guard = (string)sql.Scalar("SELECT sql FROM sqlite_master WHERE name='domenia_fleet_rows_update';")!;
            sql.Execute("DROP TRIGGER domenia_fleet_rows_update;");
            sql.Execute("UPDATE domenia_v2_fleet_rows SET payload='tampered';");
            sql.Script(guard + ";");
        }
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadFleetAsync(None), "suppression/recréation de la même garde invalide le snapshot chaud et contrôle les octets");
        await Check.ThrowsAsync<InvalidDataException>(() => new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(None), "lecteur froid refuse aussi le payload altéré");
    }

    [Test]
    public static async Task Relocation_preserves_incremental_facts_and_refuses_a_typed_row_damaged_inside_a_healthy_SQLite_file()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var db = await Create(folder, pc);
        await db.SaveFleetAsync(Patch(pc, true), None);
        var source = await db.InspectSwitchSourceAsync(db.Path, false, None);
        var destination = new DomeniaDatabase(folder.File("moved.db"), Fixtures.Root, TestClock.Fixed());
        destination.CopyForSwitch(source, folder.File("staging.db"), None, _ => { });
        var moved = await destination.ReadFleetAsync(None);
        Check.Equal(destination.StoreId, moved.Facts.StoreId, "identité réattribuée dans l’en-tête seulement");
        Check.Equal(true, moved.Observations.Find(pc.ObjectGuid)!.Presence.Answered, "mesure native préservée après copie");
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("UPDATE domenia_v2_fleet_rows SET payload='broken typed row';"); Check.Equal("ok", sql.Scalar("PRAGMA quick_check;") as string, "SQLite structurellement sain ne suffit pas"); }
        var damaged = await db.InspectSwitchSourceAsync(db.Path, false, None);
        var refused = new DomeniaDatabase(folder.File("refused.db"), Fixtures.Root, TestClock.Fixed());
        Check.Throws<InvalidDataException>(() => refused.CopyForSwitch(damaged, folder.File("rejected-staging.db"), None, _ => { }), "hash et contenu de chaque ligne validés avant publication de la copie");
        Check.False(File.Exists(refused.Path), "aucune destination publiée après le refus");
        Check.True(File.Exists(db.Path), "source conservée pour diagnostic");
    }

    [Test]
    public static async Task Warm_snapshot_checks_counter_changes_and_monotonic_state_cannot_be_reset_or_replaced()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var db = await Create(folder, pc);
        await db.SaveFleetAsync(Patch(pc, true), None);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            Check.Throws<SqliteStoreException>(() => sql.Execute("UPDATE domenia_v2_fleet_state SET generation=0;"), "réinitialisation extérieure de génération refusée");
            Check.Throws<SqliteStoreException>(() => sql.Execute("INSERT OR REPLACE INTO domenia_v2_fleet_state VALUES(1,0,0,0,0);"), "REPLACE ne contourne pas la génération monotone");
            Check.Throws<SqliteStoreException>(() => sql.Execute("DELETE FROM domenia_v2_fleet_state;"), "suppression de l’état refusée");
            sql.Execute("UPDATE domenia_v2_fleet_state SET generation=generation+1,computers=0;");
        }
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadFleetAsync(None), "modification des compteurs détectée même avec snapshot déjà chaud");
    }

    [Test]
    public static async Task Failed_incremental_transaction_never_publishes_rows_or_reuses_an_uncommitted_generation()
    {
        using var folder = new TemporaryFolder(); var a = Fixtures.Computer("A"); var b = Fixtures.Computer("B"); var db = await Create(folder, a, b);
        await db.SaveFleetAsync(Patch(a, true), None); await db.SaveFleetAsync(Patch(b, true), None);
        long generation;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            generation = (long)sql.Scalar("SELECT generation FROM domenia_v2_fleet_state;")!;
            sql.Script("CREATE TRIGGER abort_fleet_header BEFORE UPDATE ON domenia_v2_metadata WHEN NEW.key='fleet' BEGIN SELECT RAISE(ABORT,'injected failure after rows'); END;");
        }
        await Check.ThrowsAsync<SqliteStoreException>(() => db.SaveFleetAsync(Patch(a, false), None), "échec après écriture de la ligne mais avant commit");
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            Check.Equal(generation, (long)sql.Scalar("SELECT generation FROM domenia_v2_fleet_state;")!, "génération rollbackée avec les lignes");
            sql.Execute("DROP TRIGGER abort_fleet_header;");
        }
        var after = await db.SaveFleetAsync(Patch(b, false), None);
        Check.Equal(true, after.Observations.Find(a.ObjectGuid)!.Presence.Answered, "résultat non commis jamais publié lors d’une réutilisation du numéro de génération");
        Check.Equal(false, after.Observations.Find(b.ObjectGuid)!.Presence.Answered, "écriture suivante valide conservée");
    }
}
