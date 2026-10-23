using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStoragePurgeTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Native_history_preview_counts_each_actual_table_independently()
    {
        using var setup = new Setup(); await setup.Initialize();
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        {
            db.Execute("INSERT INTO operation_runs(operation,finished_at) VALUES('ancienne',?1);", Fixtures.Now.AddDays(-1000).ToString("O"));
            db.Execute("INSERT INTO operation_runs(operation,finished_at) VALUES('récente',?1);", Fixtures.Now.AddDays(-1).ToString("O"));
            db.Execute("INSERT INTO operation_runs(operation,finished_at) VALUES('date illisible','inconnue');");
            db.Execute("INSERT INTO user_machine_history(computer_key,user_login,source,observed_at) VALUES('declared','alice','Session',?1);", Fixtures.Now.AddDays(-1000).ToString("O"));
            db.Execute("INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('declared','alice','Saisie manuelle');");
        }
        var snapshot = await setup.Reader.LocalStoreAsync(None);
        var preview = LocalStoreRules.PurgePlan(snapshot, ["history"], 730, Fixtures.Now, TimeZoneInfo.Utc);
        Check.Equal(1L, preview.TotalRows, "une exécution réellement ancienne même sans association purgeable");
        Check.Equal(1L, preview.Targets.Single(x => x.Table == "operation_runs").Rows, "compte exact de sa propre table");
        var plan = await setup.Plan(["history"]);
        await setup.Executor.ExecuteAsync(plan, None);
        using var check = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(2L, (long)check.Scalar("SELECT count(*) FROM operation_runs;")!, "récente et illisible gardées");
        Check.Equal(1L, (long)check.Scalar("SELECT count(*) FROM user_machine_history;")!, "historique déclaré gardé");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "purge historique relue");
    }

    [Test]
    public static async Task Native_history_purge_recognizes_snapshot_day_without_inventing_invalid_dates()
    {
        using var setup = new Setup(); await setup.Initialize();
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        {
            db.Execute("INSERT INTO fleet_snapshots(scope_key,snapshot_day,scope_dn) VALUES('old','2020-01-01',?1);", Fixtures.Root);
            db.Execute("INSERT INTO fleet_snapshots(scope_key,snapshot_day,scope_dn) VALUES('invalid','2020-99-99',?1);", Fixtures.Root);
        }
        var plan = await setup.Plan(["history"]); await setup.Executor.ExecuteAsync(plan, None);
        using var check = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(1L, (long)check.Scalar("SELECT count(*) FROM fleet_snapshots;")!, "date invalide conservée, journée ancienne purgée");
        Check.Equal("invalid", check.Scalar("SELECT scope_key FROM fleet_snapshots;") as string, "aucune date inventée");
    }

    [Test]
    public static async Task Index_purge_clears_native_and_legacy_projections_but_keeps_secrets_associations_and_receipts()
    {
        using var setup = new Setup(); await setup.Initialize();
        var computer = Fixtures.Computer("PC1");
        await setup.Database.SaveDirectoryAsync(WritePlans.NewId(), Fixtures.Snapshot(computers: [computer]), new(Fixtures.Postes, "Postes", true), "DC01", None);
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        {
            db.Execute("INSERT INTO secret_state(computer_key,computer) VALUES('secret','PC1');");
            db.Execute("INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('link','alice','Saisie manuelle');");
        }
        var plan = await setup.Plan(["index"]);
        Check.True(plan.Confirmation.TypedNameRequired, "purge soumise au domaine saisi");
        await setup.Executor.ExecuteAsync(plan, None);
        using var check = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM ad_objects;")!, "index D1 vidé");
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM domenia_v2_objects;")!, "index natif vidé");
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM domenia_v2_metadata WHERE key='directory';")!, "en-tête de couverture retiré");
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM sync_state WHERE last_sync IS NOT NULL;")!, "aucune fraîcheur conservée");
        Check.Equal(1L, (long)check.Scalar("SELECT count(*) FROM secret_state;")!, "métadonnées de sécurité gardées");
        Check.Equal(1L, (long)check.Scalar("SELECT count(*) FROM user_machine_links;")!, "déclaration gardée");
        Check.Equal(1L, (long)check.Scalar("SELECT count(*) FROM domenia_v2_batches;")!, "reçu historique gardé");
        var reopened = new CompatibleDirectoryCache(setup.App, setup.User, "test.local", TestClock.Fixed(Fixtures.Now.AddHours(1)));
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStoragePurgeAsync(plan, None)).State, "preuve durable relue après redémarrage");
        Check.True(await reopened.ReadKnownAsync(None) is null, "aucun ancien cache reconstitué depuis l’en-tête");
        Check.Equal(0, (await reopened.ReadSyncStateAsync(None)).Scopes.Length, "repère réinitialisé sans fraîcheur ni erreur de lecture");
    }

    [Test]
    public static async Task Observation_purge_clears_native_measurements_and_fences_previous_sweeps()
    {
        using var setup = new Setup(); await setup.Initialize();
        var computer = Fixtures.Computer("PC1");
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        await setup.Database.SaveDirectoryAsync(WritePlans.NewId(), Fixtures.Snapshot(computers: [computer]), scope, "DC01", None);
        var bitlocker = new BitLockerPresence(scope.Dn, true, Fixtures.Now, true, false, ImmutableDictionary<Guid, BitLockerFact>.Empty.Add(computer.ObjectGuid, new(1, Fixtures.Now)));
        await setup.Database.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(computer)]), BitLocker = [bitlocker] }, None);
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,attempts) VALUES('p','PC1',?1,'empty',1);", Fixtures.Now.ToString("O")); }
        var before = await setup.Cache.ReadRelationSweepsAsync(None);
        var plan = await setup.Plan(["observations"]); await setup.Executor.ExecuteAsync(plan, None);
        var fleet = await setup.Cache.ReadFleetAsync(None);
        Check.Equal(0, fleet.Observations.Workstations.Length, "mesures natives vidées");
        Check.Equal(1, fleet.Facts.BitLocker.Length, "présence BitLocker conservée");
        Check.Equal(0, setup.Source.FleetDetails.Observations.Workstations.Length, "cache source remplacé");
        var after = await setup.Cache.ReadRelationSweepsAsync(None);
        Check.Equal(before.Generation + 1, after.Generation, "génération de passage avancée");
        Check.Equal(0L, after.Total, "parc vidé");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "purge relue");
        var backup = (await setup.Database.InspectAsync(None))!.Backup!;
        using var saved = new SqliteDatabase(backup.Path, true);
        Check.Equal(1L, (long)saved.Scalar("SELECT count(*) FROM park_state;")!, "sauvegarde avant suppression récupérable");
    }

    [Test]
    public static async Task Purge_refuses_concurrent_content_and_forbidden_categories_without_losing_data()
    {
        using var setup = new Setup(); await setup.Initialize();
        using (var db = new SqliteDatabase(setup.Database.Path, false)) { db.Execute("INSERT INTO presence_cache(object_key,state) VALUES('p','old');"); }
        var plan = await setup.Plan(["observations"]);
        using (var db = new SqliteDatabase(setup.Database.Path, false)) { db.Execute("UPDATE presence_cache SET state='concurrent';"); }
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "écriture sans révision détectée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "CAS revérifié à l’envoi");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Plan(["observations", "manualLinks"]), "catégorie protégée bloque tout le plan");
        using var check = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal("concurrent", check.Scalar("SELECT state FROM presence_cache;") as string, "donnée concurrente intacte");
    }

    private sealed class Setup : IDisposable
    {
        private TemporaryFolder Folder { get; } = new();
        internal string App { get; }
        internal string User { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal AdStoragePurgeExecutor Executor { get; }
        internal AdSettingsReader Reader { get; }
        internal DomeniaDatabase Database { get; private set; } = null!;
        internal Setup()
        {
            App = Folder.File("app"); User = Folder.File("profile"); Cache = new(App, User, "test.local", TestClock.Fixed());
            Source = new("test.local", () => "test", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: Cache);
            Executor = new(Source); Reader = new(Source);
        }
        internal async Task Initialize() { Database = await Cache.DatabaseAsync(None); await Database.InitializeAsync(None); }
        internal async Task<WritePlan> Plan(IReadOnlyCollection<string> selection)
        {
            var snapshot = await Reader.LocalStoreAsync(None);
            var preview = LocalStoreRules.PurgePlan(snapshot, selection, 730, Fixtures.Now, TimeZoneInfo.Utc);
            return WritePlans.Seal(await Executor.PlanPurgeAsync(selection, 730, preview.Fingerprint, None), WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        }
        public void Dispose() { Source.Dispose(); Folder.Dispose(); }
    }
}
