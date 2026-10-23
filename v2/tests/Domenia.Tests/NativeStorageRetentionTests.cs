using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageRetentionTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly StoragePolicy Policy = StoragePolicyRules.Default with { PresenceDays = 30, ConsoleDays = 0, InventoryDays = 0, ProbeDays = 0, DetailDays = 0, LinkHistoryDays = 0 };

    [Test]
    public static async Task Retention_counts_actual_imported_rows_and_keeps_recent_uncertain_and_live_D1_measures()
    {
        using var setup = new Setup(); await setup.Seed();
        var snapshot = await setup.Reader.LocalStoreAsync(None);
        var preview = StoragePolicyRules.Preview(Policy, snapshot, Fixtures.Now, TimeZoneInfo.Utc);
        Check.Equal(1L, preview.TotalRows, "une seule mesure importée assez ancienne et datée");
        var plan = await setup.Plan(Policy);
        Check.True((await setup.Executor.CheckAsync(plan, None)).Current, "inventaire relu");
        Check.Equal(WriteResult.Applied, (await setup.Executor.ExecuteAsync(plan, None)).Result, "transaction appliquée");
        using (var db = new SqliteDatabase(setup.Database.Path, true))
        {
            Check.Equal(0L, (long)db.Scalar("SELECT count(*) FROM domenia_observations WHERE object_guid='old';")!, "ancienne mesure retirée");
            Check.Equal(4L, (long)db.Scalar("SELECT count(*) FROM domenia_observations;")!, "mesures récentes, illisibles, tentative récente et D1 active préservées");
        }
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "état et sauvegarde relus");
        var backup = (await setup.Database.InspectAsync(None))!.Backup!;
        using var saved = new SqliteDatabase(backup.Path, true);
        Check.Equal(5L, (long)saved.Scalar("SELECT count(*) FROM domenia_observations;")!, "sauvegarde antérieure complète");
        var reopened = new CompatibleDirectoryCache(setup.App, setup.User, "test.local", TestClock.Fixed(Fixtures.Now.AddDays(1)));
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageRetentionAsync(plan, None)).State, "preuve après expiration et redémarrage");
        Check.Equal(WriteResult.NoChange, (await setup.Executor.ExecuteAsync(plan, None)).Result, "aucun rejeu");
    }

    [Test]
    public static async Task Retention_detects_a_D1_write_without_a_revision_increment()
    {
        using var setup = new Setup(); await setup.Seed();
        var plan = await setup.Plan(Policy);
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Execute("UPDATE domenia_observations SET payload='modification concurrente' WHERE object_guid='old';"); }
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "empreinte des données modifiée à révision identique");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "CAS avant suppression");
        using var check = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(5L, (long)check.Scalar("SELECT count(*) FROM domenia_observations;")!, "aucune perte concurrente");
    }

    [Test]
    public static async Task Retention_compacts_only_repeated_history_and_preserves_protected_associations()
    {
        using var setup = new Setup(); await setup.Seed();
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        {
            foreach (var key in new[] { "automatic", "protected" })
            {
                for (var i = 0; i < 3; i++)
                { db.Execute("INSERT INTO user_machine_history(computer_key,user_login,user_guid,source,observed_at) VALUES(?1,'alice','u1','Session',?2);", key, Fixtures.Now.AddDays(-100 + i).ToString("O")); }
            }
            db.Execute("INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('protected','alice','Saisie manuelle');");
        }
        var policy = Policy with { PresenceDays = 0, LinkHistoryDays = 30 };
        var plan = await setup.Plan(policy);
        Check.Equal(1L, StorageWritePlans.PlannedRows(plan, "retention.").Single().Rows, "un doublon intérieur automatique seulement");
        await setup.Executor.ExecuteAsync(plan, None);
        using var check = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(2L, (long)check.Scalar("SELECT count(*) FROM user_machine_history WHERE computer_key='automatic';")!, "bornes de période conservées");
        Check.Equal(3L, (long)check.Scalar("SELECT count(*) FROM user_machine_history WHERE computer_key='protected';")!, "historique protégé intact");
        Check.Equal(1L, (long)check.Scalar("SELECT count(*) FROM user_machine_links;")!, "association actuelle intacte");
    }

    [Test]
    public static async Task Retention_removes_native_measures_and_refreshes_the_loaded_source_without_network()
    {
        using var setup = new Setup(); await setup.Seed();
        var computer = Fixtures.Computer("PC1");
        await setup.Database.SaveDirectoryAsync(WritePlans.NewId(), Fixtures.Snapshot(computers: [computer]), new(Fixtures.Postes, "Postes", true), "DC01", None);
        var observation = Fixtures.Observe(computer) with { Presence = new(MeasureState.Known, true, Fixtures.Now.AddDays(-100), Fixtures.Now.AddDays(-100)), Inventory = InventoryMeasure.Unread };
        await setup.Database.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now.AddDays(-100), [observation]) }, None);
        _ = await setup.Source.GetSessionAsync(None);
        var plan = await setup.Plan(Policy);
        await setup.Executor.ExecuteAsync(plan, None);
        Check.Equal(MeasureState.NotRead, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Single().Presence.State, "mesure native purgée");
        Check.Equal(MeasureState.NotRead, setup.Source.FleetDetails.Observations.Workstations.Single().Presence.State, "cache chargé remplacé");
        Check.Equal(0, setup.Connection.Calls, "aucun LDAP implicite");
    }

    [Test]
    public static async Task Retention_rejects_trigger_side_effects_and_detects_corrupted_receipts()
    {
        using var setup = new Setup(); await setup.Seed();
        var plan = await setup.Plan(Policy);
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Script("CREATE TRIGGER unexpected AFTER DELETE ON domenia_observations BEGIN DELETE FROM secret_state; END;"); }
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "déclencheur non qualifié refusé");
        using (var db = new SqliteDatabase(setup.Database.Path, false)) { db.Script("DROP TRIGGER unexpected;"); }
        var fresh = await setup.Plan(Policy); await setup.Executor.ExecuteAsync(fresh, None);
        using (var db = new SqliteDatabase(setup.Database.Path, false)) { db.Execute("UPDATE domenia_v2_retention_receipts SET payload='{}';"); }
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Executor.VerifyAsync(fresh, None), "aucune fausse preuve sur reçu altéré");
    }

    private sealed class Setup : IDisposable
    {
        private TemporaryFolder Folder { get; } = new();
        internal string App { get; }
        internal string User { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal AdBoundaryTests.RecordingAdConnection Connection { get; } = new();
        internal AdStorageRetentionExecutor Executor { get; }
        internal AdSettingsReader Reader { get; }
        internal DomeniaDatabase Database { get; private set; } = null!;
        internal Setup()
        {
            App = Folder.File("app"); User = Folder.File("profile"); Cache = new(App, User, "test.local", TestClock.Fixed());
            Source = new("test.local", () => "test", TestClock.Fixed(), connection: Connection, localStore: Cache);
            Executor = new(Source); Reader = new(Source);
        }
        internal async Task Seed()
        {
            Database = await Cache.DatabaseAsync(None); await Database.InitializeAsync(None);
            using var db = new SqliteDatabase(Database.Path, false);
            foreach (var id in new[] { "old", "recent", "unreadable", "retry", "live-d1" })
            {
                var at = id == "recent" ? Fixtures.Now.AddDays(-1).ToString("O") : id == "unreadable" ? "inconnue" : Fixtures.Now.AddDays(-100).ToString("O");
                db.Execute("INSERT INTO domenia_observations(object_guid,family,dn,attempt_at,success_at,status,revision) VALUES(?1,'Presence',?2,?3,?4,'ok',0);", id, Fixtures.Root, at, id == "retry" ? Fixtures.Now.ToString("O") : "");
                if (id != "live-d1") { db.Execute("INSERT INTO domenia_legacy_observation_imports(object_guid,payload_hash,imported_at) VALUES(?1,'hash',?2);", id, Fixtures.Now.ToString("O")); }
            }
        }
        internal async Task<WritePlan> Plan(StoragePolicy policy)
        {
            var store = await Reader.LocalStoreAsync(None);
            var preview = StoragePolicyRules.Preview(policy, store, Fixtures.Now, TimeZoneInfo.Utc);
            var draft = await Executor.PlanRetentionAsync(policy, preview.Fingerprint, None);
            return WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        }
        public void Dispose() { Source.Dispose(); Folder.Dispose(); }
    }
}
