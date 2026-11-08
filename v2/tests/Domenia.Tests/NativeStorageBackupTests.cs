using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;
using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Bridge;

namespace Domenia.Tests;

internal static class NativeStorageBackupTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Native_backup_preserves_the_database_and_remains_verifiable_after_restart()
    {
        using var setup = new Setup();
        var database = await setup.Cache.DatabaseAsync(None); await database.InitializeAsync(None);
        var before = File.ReadAllBytes(database.Path);
        var writer = new AdStorageBackupLocalExecutor(setup.Source);
        var plan = Seal(await writer.PlanBackupAsync(StoragePolicyRules.Default, "{}", StorageWritePlans.ManualSeries, None));
        Check.True((await writer.CheckAsync(plan, None)).Current, "copie autorisée après relecture");
        Check.Equal(WriteResult.Applied, (await writer.ExecuteAsync(plan, None)).Result, "copie exécutée");
        Check.True(before.SequenceEqual(File.ReadAllBytes(database.Path)), "base active intacte");
        var settings = await new AdSettingsReader(setup.Source).LocalStoreAsync(None);
        Check.Equal(1, settings.Backups.Count(x => x.Kind == "manual"), "copie complète visible dans Paramètres");
        Check.True(BackupPreferencesRules.IsBound(settings.Backups.Single(x => x.Kind == "manual")), "annexe liée à son empreinte");
        var reopened = new CompatibleDirectoryCache(setup.App, setup.User, "test.local", TestClock.Fixed(Fixtures.Now.AddHours(1)));
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageBackupAsync(plan, None)).State, "preuve relue après redémarrage et expiration");
        Check.False((await writer.CheckAsync(plan, None)).Current, "plan déjà envoyé non rejoué");
        Check.Equal(WriteResult.NoChange, (await writer.ExecuteAsync(plan, None)).Result, "répétition directe sans seconde copie");
    }

    [Test]
    public static async Task Native_backup_copy_preserves_replaced_file_and_rejects_destination_races()
    {
        using var setup = new Setup();
        await (await setup.Cache.DatabaseAsync(None)).InitializeAsync(None);
        var writer = new AdStorageBackupCopyExecutor(setup.Source);
        var target = setup.Folder.File("published.db"); File.WriteAllText(target, "original à conserver");
        var stale = Seal(await writer.PlanBackupCopyAsync(target, StoragePolicyRules.Default, "{}", None));
        File.WriteAllText(target, "modification concurrente");
        Check.False((await writer.CheckAsync(stale, None)).Current, "cible modifiée signalée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(stale, None), "cible revérifiée à la publication");
        var plan = Seal(await writer.PlanBackupCopyAsync(target, StoragePolicyRules.Default, "{}", None));
        await writer.ExecuteAsync(plan, None);
        Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, None)).State, "publication relue");
        Check.Equal("modification concurrente", File.ReadAllText(target + ".previous-" + plan.Id + ".db"), "original remplacé récupérable");
        using var sqlite = new SqliteDatabase(target, true);
        Check.Equal("ok", sqlite.Scalar("PRAGMA quick_check;") as string, "copie publiée lisible");
    }

    [Test]
    public static async Task Native_backup_corruption_is_never_reported_as_verified()
    {
        using var setup = new Setup(); await (await setup.Cache.DatabaseAsync(None)).InitializeAsync(None);
        var writer = new AdStorageBackupLocalExecutor(setup.Source);
        var plan = Seal(await writer.PlanBackupAsync(StoragePolicyRules.Default, "{}", StorageWritePlans.ManualSeries, None));
        await writer.ExecuteAsync(plan, None);
        var database = await setup.Cache.DatabaseAsync(None);
        var file = plan.Changes.Single(x => x.Attribute == "backup.file").AfterValue!;
        File.AppendAllText(Path.Combine(Path.GetDirectoryName(database.Path)!, "Backups", file), "corrompu");
        await Check.ThrowsAsync<InvalidDataException>(() => writer.VerifyAsync(plan, None), "empreinte non conforme signalée");
    }

    [Test]
    public static async Task Exported_backup_round_trip_recovers_its_exact_plan_named_preferences_annex()
    {
        using var setup = new Setup(); var db = await setup.Cache.DatabaseAsync(None); await db.InitializeAsync(None);
        var annex = BackupPreferencesRules.Snapshot(new Dictionary<string, JsonElement> { [PreferenceApproval.ZoomKey] = JsonSerializer.SerializeToElement(120) });
        var target = setup.Folder.File("export.db");
        var plan = Seal(await setup.Cache.PrepareStorageBackupAsync(StoragePolicyRules.Default, annex, StorageWritePlans.ManualSeries, target, None));
        await setup.Cache.ApplyStorageBackupAsync(plan, None);
        Check.True(File.Exists(target + ".preferences-" + plan.Id + ".json"), "vraie annexe exportée présente");
        Check.False(File.Exists(Path.ChangeExtension(target, ".preferences.json")), "aucune annexe canonique créée artificiellement par le test");
        var external = await db.InspectExternalSwitchSourceAsync(target, None);
        Check.NotNull(external.Backup!.Preferences, "annexe retrouvée par liaison aux octets SQLite");
        Check.Equal(annex, external.Backup.Preferences!.Json, "préférences exactes, pas un document vide");
        var restore = await setup.Cache.PrepareStorageRestoreAsync(target, false, None);
        Check.Equal(external.Backup.Preferences.Sha256, restore.Changes.Single(c => c.Attribute == "restore.preferences").AfterValue, "empreinte jointe au plan de restauration réel");

        var executor = new AdStorageRestoreExecutor(setup.Source);
        using var context = new EngineContext(ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")),
            setup.Source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
            ScreenReaders.Discover(setup.Source, [typeof(AdSettingsReader).Assembly]), writers: WriteExecutors.From([executor]));
        var circuit = WriteCircuit.From(context);
        var planned = await circuit.PlanAsync(await executor.PlanRestoreFileAsync(target, None), None);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, planned.Plan.Confirmation.TypedName, null, None);
        Check.Equal(VerificationState.Verified, receipt.Verification, "restauration native confirmée par le circuit");
        var active = await setup.Cache.DatabaseAsync(None);
        Check.True(active.StoreId != db.StoreId, "identité de la destination réellement différente du reçu cible original");
        var activeBackups = await active.InspectLocalStoreAsync(false, false, None);
        Check.False(activeBackups.Backups.Any(b => b.Id == plan.Id), "registre voisin de l’original non adopté par la nouvelle base");
        await Check.ThrowsAsync<InvalidDataException>(() => active.InspectRegisteredSwitchSourceAsync(plan.Id, None), "accès explicite au reçu d’une autre base toujours refusé");
        Check.True(File.Exists(Path.Combine(Path.GetDirectoryName(db.Path)!, "Backups", ".receipts", plan.Id + ".json")), "preuve de l’original conservée");
        var operation = new SettingsOperations().CreateOperations(context).Single(o => o.Name == "settings.storage.restore.preferences");
        var args = JsonSerializer.SerializeToElement(new { receiptId = receipt.Id });
        var bridge = new BridgeContext(_ => { }, "restore-annex", operation.Name);
        var applied = (PreferenceApplyResult)(await operation.Handler(args, bridge, None))!;
        Check.Equal(1, applied.Changed, "clé de l’annexe réappliquée par le vrai handler Paramètres");
        Check.True(context.Preferences.TryGet(PreferenceApproval.ZoomKey, out var zoom) && zoom.GetInt32() == 120, "préférence effectivement restaurée");
        await context.Preferences.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100), None);
        var beforeWrite = (await active.InspectAsync(None))!.Revision;
        var beforeSnapshot = LogicalSnapshot(active.Path);
        // Restore selects a fresh database instance. Use the normal cache writer, which verifies/initializes that instance
        // before changing its revision; a direct uninitialized database write is correctly refused by EnsureReady.
        try { await setup.Cache.SaveFleetAsync(FleetCachePatch.Empty, None); }
        catch (SqliteStoreException error)
        { throw new InvalidOperationException("Premier enregistrement de la base restaurée et sa sauvegarde préalable : " + error.Message, error); }
        var afterWrite = (await active.InspectAsync(None))!;
        Check.Equal(beforeWrite + 1, afterWrite.Revision, "une nouvelle écriture a réellement changé la base restaurée");
        Check.NotNull(afterWrite.Backup, "la nouvelle base conserve sa propre sauvegarde avant écriture");
        RequireAutomaticBackup(afterWrite.Backup!, active.StoreId, beforeWrite, beforeSnapshot);
        await Check.ThrowsAsync<DomeniaOperationException>(() => operation.Handler(args, bridge, None), "ancienne relecture mémorisée insuffisante après nouvelle écriture SQLite");
        Check.True(context.Preferences.TryGet(PreferenceApproval.ZoomKey, out zoom) && zoom.GetInt32() == 100, "préférence préservée après refus");
    }

    [Test]
    public static async Task Automatic_backup_of_a_long_database_name_keeps_room_for_native_SQLite_journals()
    {
        using var folder = new TemporaryFolder();
        var backups = Path.Combine(folder.Path, "Backups");
        const string prefix = "Domenia-restauree-";
        var suffix = "-20261025-120000-" + new string('0', 32) + ".db";
        // Reproduce the actual boundary without changing TEMP or the native runtime: the old .partial name fits,
        // but its rollback journal does not. Both the active path and the final backup remain ordinary local paths.
        var stemLength = 259 - (backups.Length + 1 + suffix.Length + ".partial".Length);
        Check.True(stemLength >= prefix.Length && stemLength + 3 <= 255, "racine de test compatible avec la frontière de chemin native");
        var stem = prefix + new string('a', stemLength - prefix.Length);
        var oldWorkingName = Path.Combine(backups, stem + suffix + ".partial");
        Check.Equal(259, oldWorkingName.Length, "nom provisoire historique encore ouvrable");
        Check.Equal(267, (oldWorkingName + "-journal").Length, "journal historique au-delà de la frontière Win32");
        var database = new DomeniaDatabase(folder.File(stem + ".db"), Fixtures.Root, TestClock.Fixed());
        var initial = await database.InitializeAsync(None);
        using (var original = new SqliteDatabase(database.Path, false))
        { original.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('backup-boundary',?1);", "{\"text\":\"Données antérieures – 東京\"}"); }
        var beforeSnapshot = LogicalSnapshot(database.Path);
        await database.SaveFleetAsync(FleetCachePatch.Empty, None);
        var after = (await database.InspectAsync(None))!;
        Check.Equal(initial.Revision + 1, after.Revision, "le véritable enregistrement a été commis après la sauvegarde");
        Check.NotNull(after.Backup, "sauvegarde préalable réellement produite");
        Check.True(after.Backup!.Path.Length <= 251, "nom de série court indépendant du nom long de la base");
        RequireAutomaticBackup(after.Backup!, database.StoreId, initial.Revision, beforeSnapshot);

        using var refusedFolder = new TemporaryFolder();
        const int backupFileLength = 6 + 15 + 1 + 32 + 3; // Geste-yyyyMMdd-HHmmss-GUID.db
        var rootLength = 252 - (1 + "Backups".Length + 1 + backupFileLength);
        var refusedRoot = refusedFolder.File(new string('b', rootLength - refusedFolder.Path.Length - 1));
        var refusedBackups = Path.Combine(refusedRoot, "Backups");
        Check.Equal(252, refusedBackups.Length + 1 + backupFileLength, "le nom final dépasse la réserve native d’un caractère");
        var refused = new DomeniaDatabase(Path.Combine(refusedRoot, "source.db"), Fixtures.Root, TestClock.Fixed());
        var beforeRefusal = await refused.InitializeAsync(None);
        var originalBytes = File.ReadAllBytes(refused.Path);
        Check.False(Directory.Exists(refusedBackups), "aucun dossier de sauvegarde avant le cas refusé");
        await Check.ThrowsAsync<PathTooLongException>(() => refused.SaveFleetAsync(FleetCachePatch.Empty, None), "refus du nom final avant copie et écriture de la source");
        Check.False(Directory.Exists(refusedBackups), "aucun dossier ni copie de sauvegarde créés sur refus de longueur");
        Check.True(originalBytes.SequenceEqual(File.ReadAllBytes(refused.Path)), "octets de la source intacts après le refus");
        var afterRefusal = (await refused.InspectAsync(None))!;
        Check.Equal(beforeRefusal.Revision, afterRefusal.Revision, "révision source inchangée après refus");
        Check.Null(afterRefusal.Backup, "aucune sauvegarde déclarée après refus");
    }

    [Test]
    public static async Task Exported_annex_selection_rejects_conflicts_and_corruption_and_bounds_history()
    {
        using var setup = new Setup(); var db = await setup.Cache.DatabaseAsync(None); await db.InitializeAsync(None);
        var target = setup.Folder.File("export.db");
        var plan = Seal(await setup.Cache.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", StorageWritePlans.ManualSeries, target, None));
        await setup.Cache.ApplyStorageBackupAsync(plan, None);
        var extra = target + ".preferences-" + WritePlans.NewId() + ".json";
        var original = await db.InspectExternalSwitchSourceAsync(target, None);
        var conflicting = BackupPreferencesRules.Bind(BackupPreferencesRules.Snapshot(new Dictionary<string, JsonElement>
            { [PreferenceApproval.ZoomKey] = JsonSerializer.SerializeToElement(120) }), original.Backup!.Sha256, Fixtures.Now);
        File.WriteAllText(extra, JsonSerializer.Serialize(conflicting, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
        var conflict = await Check.ThrowsAsync<InvalidDataException>(() => db.InspectExternalSwitchSourceAsync(target, None), "deux annexes différentes pour les mêmes octets refusées");
        Check.Contains("contradictoires", conflict.Message, "refus motivé par les deux annexes effectivement décodées");
        File.WriteAllText(extra, "{");
        await Check.ThrowsAsync<JsonException>(() => db.InspectExternalSwitchSourceAsync(target, None), "annexe illisible jamais silencieusement perdue");
        // Retain the conflicting proof and add inert history: the bound must be checked before parsing any annex.
        for (var n = 0; n < 31; n++) { File.WriteAllText(target + ".preferences-" + WritePlans.NewId() + ".json", "{}"); }
        var quota = await Check.ThrowsAsync<InvalidDataException>(() => db.InspectExternalSwitchSourceAsync(target, None), "33 candidats refusés avant toute sélection");
        Check.Contains("32 annexes", quota.Message, "échec de quota, pas de décodage du fichier malformé");
        Check.True(File.Exists(extra), "preuve défectueuse conservée");
    }

    [Test]
    public static async Task Backup_rotation_keeps_recoverable_originals_outside_active_series()
    {
        using var setup = new Setup(); await (await setup.Cache.DatabaseAsync(None)).InitializeAsync(None);
        var writer = new AdStorageBackupLocalExecutor(setup.Source);
        var policy = StoragePolicyRules.Default with { BackupKeep = 2 };
        var first = Seal(await writer.PlanBackupAsync(policy, "{}", StorageWritePlans.ManualSeries, None));
        await writer.ExecuteAsync(first, None);
        var middle = Seal(await writer.PlanBackupAsync(policy, "{}", StorageWritePlans.ManualSeries, None));
        await writer.ExecuteAsync(middle, None);
        var second = Seal(await writer.PlanBackupAsync(policy, "{}", StorageWritePlans.ManualSeries, None));
        var rotatedId = second.Changes.Single(x => x.Attribute == "backup.rotation").BeforeValue;
        Check.True(rotatedId == first.Id || rotatedId == middle.Id, "rotation liée à une copie approuvée, même si les dates sont identiques");
        await writer.ExecuteAsync(second, None);
        var database = await setup.Cache.DatabaseAsync(None);
        var rotated = rotatedId == first.Id ? first : middle;
        var oldName = rotated.Changes.Single(x => x.Attribute == "backup.file").AfterValue!;
        Check.True(File.Exists(Path.Combine(Path.GetDirectoryName(database.Path)!, "Backups", "Retired", oldName)), "original de rotation récupérable");
        var active = (await new AdSettingsReader(setup.Source).LocalStoreAsync(None)).Backups.Where(x => x.Kind == "manual").ToArray();
        Check.Equal(2, active.Length, "série limitée");
        Check.True(active.Any(x => x.Id == second.Id), "nouvelle copie active");
    }

    [Test]
    public static async Task Cold_integrity_report_has_a_valid_unavailable_verdict_without_creating_files()
    {
        using var setup = new Setup();
        var report = await new AdSettingsReader(setup.Source).CheckIntegrityAsync(None);
        var view = LocalStoreRules.Integrity(report.Integrity!, TimeZoneInfo.Utc);
        Check.False(report.Available, "base absente");
        Check.True(view.Failed > 0, "absence explicite, pas de faux état sain");
        Check.False(Directory.Exists(setup.User), "aucun fichier créé");
    }

    private static string LogicalSnapshot(string path)
    {
        using var stored = new SqliteDatabase(path, true);
        stored.Begin(false);
        var snapshot = StorageWriteSnapshot.Read(stored, None);
        stored.Commit();
        return snapshot;
    }

    private static void RequireAutomaticBackup(DatabaseBackup backup, string storeId, long revision, string beforeSnapshot)
    {
        Check.Equal(backup.Sha256, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(backup.Path))), "empreinte de la sauvegarde préalable relue");
        using var stored = new SqliteDatabase(backup.Path, true);
        Check.Equal("ok", stored.Scalar("PRAGMA quick_check;") as string, "sauvegarde préalable lisible par le moteur natif");
        Check.Equal(storeId, stored.Scalar("SELECT store_id FROM domenia_store_state WHERE id=1;") as string, "copie liée à la base effectivement écrite");
        Check.Equal(revision, (long)stored.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")!, "révision antérieure conservée dans la copie");
        Check.Equal(beforeSnapshot, StorageWriteSnapshot.Read(stored, None), "schéma et lignes logiques antérieurs conservés dans la sauvegarde");
    }

    private static WritePlan Seal(WritePlanDraft draft) => WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
    private sealed class Setup : IDisposable
    {
        internal TemporaryFolder Folder { get; } = new();
        internal string App { get; }
        internal string User { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal Setup()
        {
            App = Folder.File("app"); User = Folder.File("profile");
            Cache = new(App, User, "test.local", TestClock.Fixed());
            Source = new("test.local", () => @"TEST\test", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: Cache);
        }
        public void Dispose()
        {
            Source.Dispose();
            foreach (var file in Directory.EnumerateFiles(Folder.Path, "*", SearchOption.AllDirectories))
            { File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly); }
            Folder.Dispose();
        }
    }
}
