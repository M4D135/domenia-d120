using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageRecoveryTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Cold_corrupt_store_restores_through_session_and_native_executor_without_claiming_a_loaded_cache()
    {
        using var setup = new Setup(); await setup.Initialize();
        using var source = setup.Source(setup.Reopen());
        var session = await source.GetSessionAsync(None);
        Check.Equal("test.local", session.Domain!.DnsName, "domaine réel conservé sans connexion réseau");
        Check.Equal(@"TEST\operator", session.Account.Login, "identité de session conservée");
        Check.Null(session.Store.LastReadAt, "aucune date de cache inventée");
        Check.False(session.Store.Complete, "cache indisponible, pas une lecture vide réussie");
        await Check.ThrowsAsync<IOException>(() => source.ReadLocalAsync(None), "les consommateurs du cache restent refusés");
        var executor = new AdStorageRestoreExecutor(source);
        var draft = await executor.PlanRestoreFileAsync(setup.Backup.Path, None);
        var plan = Seal(draft, session.Account.Login); executor.Bind(draft, plan);
        Check.False(plan.Reversibility.Reversible, "aucun retour proposé vers les octets illisibles");
        Check.Null(plan.Changes.Single(c => c.Attribute == "revision").BeforeValue, "aucune révision SQLite inventée pour l’original");
        Check.True((await executor.CheckAsync(plan, None)).Current, "sauvegarde et original brut requalifiés");
        Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(plan, None)).Result, "restauration réelle exécutée");
        Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, None)).State, "reçu et deux fichiers relus");
        Check.True(setup.Original.SequenceEqual(File.ReadAllBytes(setup.Database.Path)), "octets corrompus conservés exactement");
        var reopened = setup.Reopen();
        Check.Equal(plan.Changes.Single(c => c.Attribute == "store.path").AfterValue, (await reopened.DatabaseAsync(None)).Path, "sélection durable après redémarrage");
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageSwitchAsync(plan, None)).State, "preuve relue à froid");
        Check.False((await reopened.InspectLocalStoreAsync(false, false, None)).Maintenance.CanUndo, "rollback corrompu non proposé");
        await Check.ThrowsAsync<InvalidDataException>(() => reopened.PrepareStorageRollbackAsync(None), "retour explicitement refusé");
    }

    [Test]
    public static async Task Same_length_original_change_invalidates_the_restore_before_any_marker()
    {
        using var setup = new Setup(); await setup.Initialize(); var cache = setup.Reopen();
        var plan = Seal(await cache.PrepareStorageRestoreAsync(setup.Backup.Path, false, None));
        var changed = setup.Original.ToArray(); changed[^1] ^= 1; File.WriteAllBytes(setup.Database.Path, changed);
        Check.Equal(setup.Original.Length, changed.Length, "dérive de même longueur");
        Check.False((await cache.CheckStorageSwitchAsync(plan, None)).Current, "empreinte différente malgré longueur identique");
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ApplyStorageSwitchAsync(plan, None), "dérive refusée à l’exécution aussi");
        Check.False(File.Exists(StorageWriteFence.Marker(setup.Database.Path)), "aucun marqueur sur original modifié");
        Check.True(changed.SequenceEqual(File.ReadAllBytes(setup.Database.Path)), "nouveaux octets intacts");
    }

    [Test]
    public static async Task Interrupted_corrupt_restore_resumes_explicitly_after_restart_with_original_bytes_preserved()
    {
        using var setup = new Setup(); await setup.Initialize(); var cache = setup.Reopen();
        var plan = Seal(await cache.PrepareStorageRestoreAsync(setup.Backup.Path, false, None)); var reached = false;
        cache.SwitchCheckpoint = point => { if (point == "copied") { reached = true; throw new IOException("Interruption de recette après preuve de copie."); } };
        await Check.ThrowsAsync<IOException>(() => cache.ApplyStorageSwitchAsync(plan, None), "interruption conservée");
        Check.True(reached, "interruption effectivement après copie qualifiée");
        var reopened = setup.Reopen(); var state = await reopened.InspectLocalStoreAsync(false, false, None);
        Check.True(state.Maintenance.Locked && state.Maintenance.RecoveryReceipt, "reprise proposée sur preuve durable malgré original illisible");
        Check.False((await reopened.CheckStorageSwitchAsync(plan, None)).Current, "ancien plan non rejouable");
        var resume = Seal(await reopened.PrepareStorageResumeAsync(None));
        await reopened.ApplyStorageSwitchAsync(resume, None);
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageSwitchAsync(resume, None)).State, "nouveau reçu de reprise vérifié");
        Check.True(setup.Original.SequenceEqual(File.ReadAllBytes(setup.Database.Path)), "original toujours conservé");
    }

    [Test]
    public static async Task Sidecar_appearing_during_corrupt_restore_prevents_pointer_publication()
    {
        using var setup = new Setup(); await setup.Initialize(); var cache = setup.Reopen();
        var plan = Seal(await cache.PrepareStorageRestoreAsync(setup.Backup.Path, false, None)); var reached = false;
        cache.SwitchCheckpoint = point => { if (point == "copied") { reached = true; File.WriteAllText(setup.Database.Path + "-wal", "preuve concurrente"); } };
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ApplyStorageSwitchAsync(plan, None), "apparition concurrente du WAL refusée");
        Check.True(reached, "apparition réellement après copie");
        Check.Equal("preuve concurrente", File.ReadAllText(setup.Database.Path + "-wal"), "preuve concurrente conservée");
        Check.Equal(setup.Database.Path, (await setup.Reopen().DatabaseAsync(None)).Path, "pointeur original conservé");
        Check.True(File.Exists(plan.Changes.Single(c => c.Attribute == "store.path").AfterValue!), "copie qualifiée conservée pour diagnostic");
    }

    [Test]
    public static async Task Corrupt_restore_does_not_accept_a_foreign_backup_or_an_unsupported_original_schema()
    {
        using var setup = new Setup(); await setup.Initialize(); var cache = setup.Reopen();
        var foreign = new DomeniaDatabase(setup.Folder.File("foreign.db"), "DC=other,DC=local", TestClock.Fixed()); await foreign.InitializeAsync(None);
        await Check.ThrowsAsync<InvalidDataException>(() => cache.PrepareStorageRestoreAsync(foreign.Path, false, None), "identité du domaine de sauvegarde obligatoire");
        File.Copy(setup.Backup.Path, setup.Database.Path, overwrite: true);
        using (var db = new SqliteDatabase(setup.Database.Path, false)) { db.Execute("UPDATE schema_info SET value='12' WHERE key='schema_version';"); }
        using var source = setup.Source(setup.Reopen());
        await Check.ThrowsAsync<InvalidDataException>(() => source.GetSessionAsync(None), "schéma incompatible non absorbé comme corruption");
        Check.False(File.Exists(StorageWriteFence.Marker(setup.Database.Path)), "aucune bascule ni protection posée");
    }

    [Test]
    public static async Task Cold_restore_verification_detects_loss_of_preserved_original()
    {
        using var setup = new Setup(); await setup.Initialize(); var cache = setup.Reopen();
        var plan = Seal(await cache.PrepareStorageRestoreAsync(setup.Backup.Path, false, None));
        await cache.ApplyStorageSwitchAsync(plan, None);
        File.SetAttributes(setup.Database.Path, File.GetAttributes(setup.Database.Path) & ~FileAttributes.ReadOnly);
        File.WriteAllText(setup.Database.Path, "autres octets");
        Check.Equal(VerificationState.Mismatch, (await setup.Reopen().VerifyStorageSwitchAsync(plan, None)).State, "copie valide seule ne prouve pas conservation de l’original");
    }

    [Test]
    public static async Task Cancellation_after_recovery_copy_keeps_evidence_for_explicit_resume()
    {
        using var setup = new Setup(); await setup.Initialize(); var cache = setup.Reopen();
        var plan = Seal(await cache.PrepareStorageRestoreAsync(setup.Backup.Path, false, None));
        using var stop = new CancellationTokenSource(); var reached = false;
        cache.SwitchCheckpoint = point => { if (point == "copied") { reached = true; stop.Cancel(); } };
        await Check.ThrowsAsync<OperationCanceledException>(() => cache.ApplyStorageSwitchAsync(plan, stop.Token), "annulation tardive propagée");
        Check.True(reached, "annulation après copie réellement atteinte");
        var destination = plan.Changes.Single(c => c.Attribute == "store.path").AfterValue!;
        Check.False(File.Exists(destination), "pas de sélection implicite après annulation");
        Check.Equal(1, Directory.EnumerateFiles(Path.GetDirectoryName(destination)!, Path.GetFileName(destination) + ".partial-*.db").Count(), "copie partielle qualifiée conservée");
        var reopened = setup.Reopen(); var resume = Seal(await reopened.PrepareStorageResumeAsync(None));
        await reopened.ApplyStorageSwitchAsync(resume, None);
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageSwitchAsync(resume, None)).State, "nouvelle confirmation puis reprise vérifiée");
    }

    [Test]
    public static async Task Corrupt_original_above_recovery_limit_is_refused_before_switch_evidence()
    {
        using var setup = new Setup(); await setup.Initialize();
        using (var file = new FileStream(setup.Database.Path, FileMode.Open, FileAccess.Write)) { file.SetLength(256L * 1024 * 1024 + 1); }
        var refusal = await Check.ThrowsAsync<InvalidDataException>(() => setup.Reopen().PrepareStorageRestoreAsync(setup.Backup.Path, false, None), "original au-delà de la borne refusé");
        Check.Contains("256 Mio", refusal.Message, "borne brute, pas une erreur SQLite quelconque");
        Check.False(File.Exists(StorageWriteFence.Marker(setup.Database.Path)), "aucune preuve de bascule commencée");
        Check.Equal(256L * 1024 * 1024 + 1, new FileInfo(setup.Database.Path).Length, "fichier volumineux conservé");
    }

    private static WritePlan Seal(WritePlanDraft draft, string account = "test") => WritePlans.Seal(draft, WritePlans.NewId(), account, AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
    private sealed class Setup : IDisposable
    {
        internal TemporaryFolder Folder { get; } = new();
        internal string App => Folder.File("app");
        internal string User => Folder.File("profile");
        internal DomeniaDatabase Database = null!;
        internal DatabaseBackup Backup = null!;
        internal byte[] Original = [];
        internal CompatibleDirectoryCache Reopen() => new(App, User, "test.local", TestClock.Fixed());
        internal AdDirectorySource Source(CompatibleDirectoryCache cache) => new("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        internal async Task Initialize()
        {
            Directory.CreateDirectory(App); Directory.CreateDirectory(User);
            Database = await Reopen().DatabaseAsync(None); await Database.InitializeAsync(None);
            Backup = await Database.BackupAsync(None);
            File.WriteAllText(Database.Path, "Original endommagé à préserver intégralement."); Original = File.ReadAllBytes(Database.Path);
        }
        public void Dispose()
        {
            foreach (var file in Directory.EnumerateFiles(Folder.Path, "*", SearchOption.AllDirectories))
            { File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly); }
            Folder.Dispose();
        }
    }
}
