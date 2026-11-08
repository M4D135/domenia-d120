using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LocalStorageDiagnosticTests
{
    [Test]
    public static async Task Native_measurement_reports_actual_sizes_probes_and_optional_dbstat_without_writing()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("measure.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var before = File.ReadAllBytes(database.Path);
        var snapshot = await database.InspectLocalStoreAsync(true, true, default);
        Check.True(snapshot.Available, "base intacte inspectée");
        Check.False(snapshot.Writer.Active, "le verrou propre au diagnostic est libéré avant la vue");
        StoragePolicyRules.EnsureRetentionAvailable(snapshot);
        var usage = snapshot.Usage!;
        Check.Equal(new FileInfo(database.Path).Length, usage.DatabaseBytes, "taille réelle du fichier");
        Check.True(usage.Probes.Length == 4 && usage.Probes.All(p => p.Milliseconds >= 0 && p.Plan.Length > 0), "quatre vraies lectures et EXPLAIN");
        using var db = new SqliteDatabase(database.Path, true);
        var compiled = db.Query("PRAGMA compile_options;").Any(r => r.Values.Any(v => v as string == "ENABLE_DBSTAT_VTAB"));
        Check.Equal(compiled, usage.DbstatAvailable, "capacité de la DLL réellement utilisée");
        Check.Contains(compiled ? "Pages allouées" : "dbstat absent", usage.SizeNote, "mesure ou repli expliqué");
        Check.True(compiled ? usage.Tables.Any(t => t.Bytes > 0) : usage.Tables.All(t => t.Bytes is null), "aucun octet inventé");
        Check.True(usage.Tables.Any(t => t.Table == "domenia_v2_objects"), "projections natives incluses, pas seulement schéma D1");
        var report = snapshot.Integrity ?? throw new TestFailureException("rapport absent");
        Check.Equal(9, report.Checks.Length, "neuf contrôles distincts");
        foreach (var id in new[] { "open", "schema", "identity", "tables", "receipts", "foreignKeys", "quickCheck", "wal" })
            Check.Equal("ok", report.Checks.Single(c => c.Id == id).Status, "contrôle natif " + id);
        Check.Contains("Mode SQLite observé", report.Checks.Single(c => c.Id == "wal").Detail, "PRAGMA journal_mode lu");
        Check.Contains("En-têtes", report.Checks.Single(c => c.Id == "receipts").Detail, "portée exacte du contrôle");
        Check.True(before.SequenceEqual(File.ReadAllBytes(database.Path)), "aucune modification par mesure et intégrité");
    }

    [Test]
    public static async Task Composed_active_cache_can_report_healthy_after_all_nine_actual_checks()
    {
        using var folder = new TemporaryFolder();
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("profile"), "test.local", TestClock.Fixed());
        await (await cache.DatabaseAsync(default)).InitializeAsync(default);
        var snapshot = await cache.InspectLocalStoreAsync(false, true, default);
        var report = snapshot.Integrity ?? throw new TestFailureException("rapport absent");
        Check.True(report.Checks.All(c => c.Status == "ok"), "les neuf contrôles peuvent être sains en mode natif");
        Check.Equal("Sain", LocalStoreRules.Integrity(report, TimeZoneInfo.Utc).Verdict, "pas d’avertissement artificiel permanent");
        Check.False(snapshot.Writer.Active, "inspection ne se présente pas comme une écriture encore active");
    }

    [Test]
    public static async Task Native_diagnostics_refuse_overlap_and_release_the_gate_afterward()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("busy.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        using (var blocker = new SqliteDatabase(database.Path, false))
        {
            blocker.Script("BEGIN EXCLUSIVE;");
            var first = database.InspectLocalStoreAsync(true, true, default);
            try
            {
                var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => database.InspectLocalStoreAsync(true, false, default), "une seule inspection explicite");
                Check.Equal("settings.diagnosticBusy", refused.Code, "refus avant une seconde lecture SQLite");
                Check.Contains("relancez", refused.Message, "nouveau geste demandé, aucun rejeu");
            }
            finally { blocker.Script("ROLLBACK;"); }
            Check.True((await first).Available, "le premier diagnostic reprend après libération du verrou tiers");
        }
        Check.True((await database.InspectLocalStoreAsync(false, true, default)).Available, "le geste suivant fonctionne, aucun verrou abandonné");
    }

    [Test]
    public static async Task Native_integrity_rejects_bad_receipt_hash_and_unmigrated_schema_without_repair()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("headers.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        using (var db = new SqliteDatabase(database.Path, false))
            db.Execute("INSERT INTO domenia_v2_batches(batch_id,sha256,revision,committed_at,items) VALUES('invalid',?1,0,?2,0);", new string('g', 64), Fixtures.Now.ToString("O"));
        var snapshot = await database.InspectLocalStoreAsync(false, true, default);
        Check.Equal("failed", snapshot.Integrity!.Checks.Single(c => c.Id == "receipts").Status, "hash non hexadécimal refusé, même longueur 64");
        using (var db = new SqliteDatabase(database.Path, false)) db.Execute("UPDATE schema_info SET value='0' WHERE key='domenia_schema';");
        snapshot = await database.InspectLocalStoreAsync(true, true, default);
        Check.False(snapshot.Available, "diagnostic du schéma 0 non migré refusé");
        using var unchanged = new SqliteDatabase(database.Path, true);
        Check.Equal("0", unchanged.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") as string, "pas de migration cachée par le diagnostic");
    }

    [Test]
    public static async Task Catalog_preserves_reader_completeness_unknown_dates_and_a_bounded_view()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("catalog.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var snapshot = Fixtures.Snapshot() with { Complete = false, ReaderLogin = @"TEST\reader" };
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), snapshot, new(Fixtures.Root, "Domaine", true), "dc.test.local", default);
        var cold = new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed());
        Check.Equal(snapshot.ReaderLogin, (await cold.ReadDirectoryAsync(default))!.ReaderLogin, "provenance préservée après réouverture");
        var checkpoint = (await cold.ReadSyncStateAsync(default)).Scopes.Single();
        Check.Equal("Subtree", checkpoint.Depth, "profondeur JSON consommée par la synchronisation réelle");
        Check.True(checkpoint.Partial, "complétude JSON consommée sans faux recensement");
        var run = (await cold.ReadOperationsAsync(default)).Runs.Single();
        Check.True(run.Subtree && run.Status == OperationsCollectionStatus.Partial, "opérations héritées conservent le passage partiel");
        var stored = await database.InspectLocalStoreAsync(false, false, default);
        var scope = stored.Scopes.Single();
        Check.Equal(@"TEST\reader", scope.Reader, "compte de lecture conservé, pas compte du consommateur");
        Check.Equal(false, scope.Complete, "lecture incomplète conservée");
        var view = LocalStoreRules.Catalog(stored.Scopes, Fixtures.Now.AddHours(2), TimeZoneInfo.Utc).Single();
        Check.Contains("incomplet", view.Source, "source compréhensible et complétude visible");
        Check.Contains("ne prouve aucune absence", view.Usage, "aucune fausse suppression");
        Check.Contains("2", view.Age, "âge de l’observation, pas date d’inspection");
        long baselineRows;
        using (var db = new SqliteDatabase(database.Path, false))
        {
            baselineRows = (long)db.Scalar("SELECT count(*) FROM sync_state;")!;
            Check.Equal(2L, baselineRows, "tentative partielle et repère de réparation du schéma présents avant le peuplement");
            Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM sync_state WHERE scope='repair:search_key_extra' AND details='CO-26';")!, "repère de réparation hors catalogue explicitement conservé");
            db.Execute("INSERT INTO sync_state(scope,server,base_dn,last_sync,item_count,details) VALUES('ou:old','old-dc',?1,'inconnue',1,'depth=OneLevel;full');", Fixtures.Root);
            db.Script("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO sync_state(scope,server,base_dn,last_sync,item_count,details) SELECT 'ou:'||x,'dc','OU='||x||',DC=test,DC=local','2020-01-01',0,'depth=Subtree;partial' FROM n;");
        }
        stored = await database.InspectLocalStoreAsync(false, false, default);
        Check.True(stored.Available && stored.CatalogTruncated, "limite du catalogue sans invalider toute la base");
        Check.Equal(10000, stored.Scopes.Length, "borne affichée");
        var old = LocalStoreRules.Catalog(stored.Scopes, Fixtures.Now, TimeZoneInfo.Utc).Single(s => s.Controller == "old-dc");
        Check.Equal("inconnu", old.Observed, "date ancienne illisible reste inconnue");
        Check.Contains("Non conservé", old.Reader, "identité ancienne jamais inventée");
        using var verify = new SqliteDatabase(database.Path, true);
        Check.Equal(baselineRows + 10001, (long)verify.Scalar("SELECT count(*) FROM sync_state;")!, "aucun repère supprimé par la limite, y compris la réparation hors catalogue");
        Check.Equal(1L, (long)verify.Scalar("SELECT count(*) FROM sync_state WHERE scope='repair:search_key_extra' AND details='CO-26';")!, "réparation intacte après lecture du catalogue borné");
    }

    [Test]
    public static async Task Rich_legacy_checkpoint_fields_survive_the_shared_details_codec()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("checkpoint.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var invocation = Guid.NewGuid().ToString("D"); var reader = new string('a', 64);
        using (var db = new SqliteDatabase(database.Path, false))
            db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc',?1,77,?2,12,?3);", Fixtures.Root, Fixtures.Now.ToString("O"),
                "depth=OneLevel;partial;invocation=" + invocation + ";reader=" + reader + ";cut=limit;limit=100;checkpoint-count=12;incremental");
        var checkpoint = (await database.ReadSyncStateAsync(default)).Scopes.Single();
        Check.Equal("OneLevel", checkpoint.Depth, "ancien format conservé"); Check.True(checkpoint.Partial && checkpoint.Incremental, "drapeaux conservés");
        Check.Equal(invocation, checkpoint.InvocationId, "identité contrôleur conservée"); Check.Equal(reader, checkpoint.ReaderFingerprint, "empreinte du compte conservée distincte du login");
        Check.Equal("limit", checkpoint.CutReason, "motif de coupure"); Check.Equal(100L, checkpoint.CutLimit, "limite exacte"); Check.Equal(12, checkpoint.CheckpointItems!.Value, "compteur de repère");
        var run = (await database.ReadOperationsAsync(default)).Runs.Single();
        Check.False(run.Subtree, "lecture directe conservée dans les opérations");
        Check.Equal(OperationsCollectionStatus.Partial, run.Status, "passage incomplet ne devient pas réussite");
    }

    [Test]
    public static async Task Location_and_unavailable_view_keep_real_states_without_enabling_maintenance()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("location.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var store = await database.InspectLocalStoreAsync(false, false, default);
        Check.Equal(database.Path, SettingsFolders.ActiveBasePath(store), "résolution appelée par l’hôte : fichier exact du snapshot actif");
        Check.Null(SettingsFolders.ActiveBasePath(store with { Simulated = true }), "aucun fichier de démonstration");
        Check.Null(SettingsFolders.ActiveBasePath(store with { Available = false }), "aucun repli quand la base est indisponible");
        var location = LocalStoreRules.Location(store, null, Fixtures.Now, store.PathLabel);
        Check.Contains("jamais sauvegardée", location.Text, "absence explicite"); Check.True(location.Alert, "première sauvegarde proposée");
        Check.False(LocalStoreRules.Location(store, Fixtures.Now.AddDays(-7), Fixtures.Now, store.PathLabel).Alert, "seuil strict");
        Check.True(LocalStoreRules.Location(store, Fixtures.Now.AddDays(-8), Fixtures.Now, store.PathLabel).Alert, "alerte après sept jours");
        store = store with { Available = false, PathLabel = "", LastFailure = "Marqueur incohérent", Writer = store.Writer with { Suspended = true }, Maintenance = store.Maintenance with { Locked = true } };
        var unavailable = StorageViewBuilder.Build(store, StoragePolicyRules.Default, false, 6, 32, Fixtures.Now, TimeZoneInfo.Utc, null);
        Check.Contains("Aucune base locale", unavailable.Location!.Text, "troisième état atteignable");
        Check.Null(unavailable.Location.Path, "aucun chemin inventé"); Check.False(unavailable.Writer!.CanResume, "aucun rejeu sous identité douteuse");
        Check.Equal("Marqueur incohérent", unavailable.UnavailableReason, "cause conservée");
        Check.Throws<DomeniaOperationException>(() => StoragePolicyRules.Preview(StoragePolicyRules.Default, store with { Available = true }, Fixtures.Now, TimeZoneInfo.Utc), "conservation refuse la bascule en attente");
    }
}
