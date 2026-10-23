using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageLegacyTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly SyncScope Scope = new(Fixtures.Root, "Domaine", "Domaine", true, true, "Test");

    [Test]
    public static async Task Native_legacy_discovery_is_cold_and_reads_no_network()
    {
        using var setup = new Setup();
        var snapshot = await setup.Reader.LocalStoreAsync(None);
        Check.False(snapshot.Available, "base absente");
        Check.False(snapshot.Legacy.Found, "aucune source inventée");
        Check.False(Directory.Exists(setup.User), "aucun dossier créé par inspection");
        Check.Equal(0, setup.Connection.Calls, "aucun LDAP implicite");
    }

    [Test]
    public static async Task Native_legacy_import_uses_all_five_files_keeps_existing_links_and_has_restart_proof()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.WriteAll();
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('pc1','declared','PC1','Saisie manuelle');"); }
        var preview = StorageViewBuilder.LegacySimulation(await setup.Reader.LocalStoreAsync(None), "test.local", TimeZoneInfo.Utc);
        Check.Equal(5L, preview.WriteCount, "quatre sources et seulement le lien absent");
        var plan = await setup.Plan(preview);
        Check.True((await setup.Executor.CheckAsync(plan, None)).Current, "sources et cible inchangées");
        var before = setup.Source.Epoch;
        await setup.Executor.ExecuteAsync(plan, None);
        Check.True(setup.Source.Epoch > before, "caches invalidés sous maintenance");
        using (var db = new SqliteDatabase(setup.Database.Path, true))
        {
            foreach (var table in new[] { "ad_objects", "park_state", "user_scan_history", "secret_state" })
            { Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM " + table + ";")!, "source importée " + table); }
            Check.Equal("declared", db.Scalar("SELECT user_login FROM user_machine_links WHERE computer_key='pc1';") as string, "déclaration existante conservée");
            Check.Equal("alice", db.Scalar("SELECT user_login FROM user_machine_links WHERE computer_key='pc2';") as string, "lien le plus récent retenu");
            Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM user_machine_history;")!, "seul lien ajouté historisé");
            Check.False((db.Scalar("SELECT detail FROM secret_state;") as string)!.Contains("secret-original", StringComparison.Ordinal), "détail libre exclu");
            Check.False((db.Scalar("SELECT details FROM user_machine_history;") as string)!.Contains("secret-original", StringComparison.Ordinal), "détail CSV exclu");
        }
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "preuve immédiate");
        var after = await setup.Reader.LocalStoreAsync(None);
        Check.True(LegacyRules.Plan(after.Legacy, "test.local").Already, "marqueur identique empêche reprise");
        var reopened = new CompatibleDirectoryCache(setup.App, setup.User, "test.local", TestClock.Fixed(Fixtures.Now.AddDays(1)));
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageLegacyAsync(plan, None)).State, "preuve indépendante du processus et de l’expiration");
        var backup = (await setup.Database.InspectAsync(None))!.Backup!;
        using var copy = new SqliteDatabase(backup.Path, true);
        Check.Equal(0L, (long)copy.Scalar("SELECT count(*) FROM ad_objects;")!, "sauvegarde avant import");
        Check.Equal(1L, (long)copy.Scalar("SELECT count(*) FROM user_machine_links;")!, "déclaration sauvegardée");
    }

    [Test]
    public static async Task Duplicate_and_cross_domain_legacy_sources_refuse_the_whole_transaction()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.WriteAll();
        var objects = setup.LegacyFile("Index/objets.tsv");
        File.AppendAllText(objects, File.ReadAllText(objects));
        var preview = StorageViewBuilder.LegacySimulation(await setup.Reader.LocalStoreAsync(None), "test.local", TimeZoneInfo.Utc);
        Check.True(preview.Blockers.Any(x => x.Contains("Doublon", StringComparison.Ordinal)), "doublon bloquant");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Plan(preview), "source refusée avant envoi");
        setup.WriteAll();
        File.AppendAllText(setup.LegacyFile("Domenia-user-machine-links.csv"), "PC3,bob,1,80,2026-10-20T12:00:00Z,,,,,\"CN=PC3,DC=other,DC=local\"\n");
        preview = StorageViewBuilder.LegacySimulation(await setup.Reader.LocalStoreAsync(None), "test.local", TimeZoneInfo.Utc);
        Check.True(preview.Blockers.Any(x => x.Contains("domaines", StringComparison.Ordinal)), "DN d’association d’un autre domaine bloquant");
        using var db = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(0L, (long)db.Scalar("SELECT count(*) FROM ad_objects;")!, "aucune reprise partielle");
    }

    [Test]
    public static async Task Native_legacy_plan_detects_changed_source_and_D1_write_without_revision()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.WriteAll();
        var plan = await setup.Plan();
        File.AppendAllText(setup.LegacyFile("Index/parc.tsv"), "PC9\t2026-10-20T12:00:00Z\tempty\t\t1\n");
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "fichier modifié");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "source ou base modifiée refusée");
        setup.WriteAll(); plan = await setup.Plan();
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('pc9','bob','PC9','Saisie manuelle');"); }
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "écriture D1 sans révision détectée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "source ou base modifiée refusée");
        using var read = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(0L, (long)read.Scalar("SELECT count(*) FROM ad_objects;")!, "import refusé intact");
    }

    [Test]
    public static async Task Old_nine_column_objects_are_preserved_without_fabricated_GUID_and_warn_until_read()
    {
        using var setup = new Setup(); await setup.Initialize();
        setup.Write("Index/objets.tsv", "Machine\tPC1\tPC1$\t\tPC1\tAncien poste\tWindows\tActif\tCN=PC1,OU=Postes,DC=test,DC=local\n");
        var plan = await setup.Plan(); await setup.Executor.ExecuteAsync(plan, None);
        var local = await setup.Cache.ReadSyncStateAsync(None);
        Check.Equal(0, local.Rows.Length, "aucune identité artificielle");
        Check.Equal(1, local.UnidentifiedLegacyObjects, "identité explicitement non relue");
        var page = await setup.Cache.SearchSyncIndexAsync(new("", Scope, IndexSort.Name, false, 0, 100), None);
        Check.True(page.Message.Contains("sans GUID", StringComparison.Ordinal), "limite visible en consultation");
        var reader = new AdSyncReader(setup.Source);
        Check.True((await reader.StartupNoticesAsync(SyncSettings.Default, None)).Any(x => x.Text.Contains("sans GUID", StringComparison.Ordinal)), "limite visible à l’ouverture");
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdSyncStoreExecutor(setup.Source).PlanSnapshotCaptureAsync("Archives", Scope, None), "relevé sans identité complète refusé");
        using var db = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM ad_objects WHERE object_guid='';")!, "ligne D1 conservée");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "preuve de reprise des données brutes");
    }

    [Test]
    public static async Task Historical_receipt_and_backup_tampering_are_not_reported_as_success()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.WriteAll();
        var plan = await setup.Plan(); await setup.Executor.ExecuteAsync(plan, None);
        var backup = (await setup.Database.InspectAsync(None))!.Backup!;
        File.AppendAllText(backup.Path, "tamper");
        Check.Equal(VerificationState.Mismatch, (await setup.Executor.VerifyAsync(plan, None)).State, "sauvegarde altérée");
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Execute("UPDATE domenia_v2_legacy_receipts SET payload='{}';"); }
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Executor.VerifyAsync(plan, None), "preuve altérée refusée");
    }

    private sealed class Setup : IDisposable
    {
        private TemporaryFolder Folder { get; } = new();
        internal string App { get; }
        internal string User { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal AdBoundaryTests.RecordingAdConnection Connection { get; } = new();
        internal AdDirectorySource Source { get; }
        internal AdStorageLegacyImportExecutor Executor { get; }
        internal AdSettingsReader Reader { get; }
        internal DomeniaDatabase Database { get; private set; } = null!;
        internal Setup()
        {
            App = Folder.File("app"); User = Folder.File("profile"); Cache = new(App, User, "test.local", TestClock.Fixed());
            Source = new("test.local", () => "test", TestClock.Fixed(), connection: Connection, localStore: Cache);
            Executor = new(Source); Reader = new(Source);
        }
        internal async Task Initialize() { Database = await Cache.DatabaseAsync(None); await Database.InitializeAsync(None); }
        internal string LegacyFile(string file) => System.IO.Path.Combine(User, file.Replace('/', System.IO.Path.DirectorySeparatorChar));
        internal void Write(string file, string content)
        {
            var path = LegacyFile(file); Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!); File.WriteAllText(path, content);
        }
        internal void WriteAll()
        {
            var id = Fixtures.Computer("PC1").ObjectGuid.ToString("D");
            Write("Index/objets.tsv", "Machine\tPC1\tPC1$\t\tPC1\tPoste ancien\tWindows\tActif\tCN=PC1,OU=Postes,DC=test,DC=local\t2026-10-20T12:00:00Z\t50\t\t" + id + "\n");
            Write("Index/parc.tsv", "PC1\t20/10/2026 12:00:00\tempty\t\t1\n");
            Write("Index/recherches.tsv", "alice\t2026-10-20T12:00:00Z\t1\t3\t2\t1\tPC1\n");
            Write("Index/secrets-etat.tsv", "PC1\t2026-10-20T12:00:00Z\t1\t2026-10-20T12:00:00Z\twindows\t\tok\tsecret-original\n");
            Write("Domenia-user-machine-links.csv", "Computer,UserLogin,VerifiedInAD,Confidence,When,Details,UserGuid,ComputerGuid,UserDn,ComputerDn\nPC1,old,1,80,2026-10-20T12:00:00Z,secret-original,,,,\nPC2,bob,1,80,2026-10-19T12:00:00Z,,,,,\nPC2,alice,1,80,2026-10-20T12:00:00Z,secret-original,,,,\n");
        }
        internal async Task<WritePlan> Plan(LegacyPreview? preview = null)
        {
            preview ??= StorageViewBuilder.LegacySimulation(await Reader.LocalStoreAsync(None), "test.local", TimeZoneInfo.Utc);
            return WritePlans.Seal(await Executor.PlanLegacyImportAsync("test.local", preview.Fingerprint, None), WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        }
        public void Dispose() { Source.Dispose(); Folder.Dispose(); }
    }
}
