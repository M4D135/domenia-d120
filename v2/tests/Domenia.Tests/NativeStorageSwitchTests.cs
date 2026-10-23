using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageSwitchTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Move_rebinds_fleet_and_operations_preserves_original_and_blocks_old_writers()
    {
        using var setup = new Setup(); await setup.Initialize();
        await setup.Database.SaveFleetAsync(FleetCachePatch.Empty, None);
        var operations = await setup.Database.ReadOperationsAsync(None);
        await setup.Database.UpdateOperationsAsync(operations.Revision, operations with { Revision = operations.Revision + 1 }, None);
        var original = DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path);
        var plan = await setup.Move();
        Check.True((await setup.Cache.CheckStorageSwitchAsync(plan, None)).Current, "plan relu avant bascule");
        await setup.Cache.ApplyStorageSwitchAsync(plan, None);
        var moved = await setup.Cache.DatabaseAsync(None);
        Check.Equal(setup.Destination, moved.Path, "nouveau chemin effectivement sélectionné");
        Check.True(moved.StoreId != setup.Database.StoreId, "nouvelle identité liée au chemin");
        Check.Equal(moved.StoreId, (await moved.ReadFleetAsync(None)).Facts.StoreId, "relevés liés à la nouvelle identité");
        Check.Equal(moved.StoreId, (await moved.ReadOperationsAsync(None)).StoreId, "opérations relues sous nouvelle identité");
        Check.Equal(original, DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path), "ancien fichier intact");
        Check.True(File.GetAttributes(setup.Database.Path).HasFlag(FileAttributes.ReadOnly), "ancien emplacement protégé");
        Check.Equal(VerificationState.Verified, (await setup.Cache.VerifyStorageSwitchAsync(plan, None)).State, "identité et empreinte relues");
        await ExpectFailure(() => setup.Database.SaveFleetAsync(FleetCachePatch.Empty, None), "ancienne instance incapable d’écrire");
        var reopened = setup.Reopen();
        Check.Equal(setup.Destination, (await reopened.DatabaseAsync(None)).Path, "sélection durable après redémarrage");
    }

    [Test]
    public static async Task Existing_noncooperative_write_handle_prevents_switch_without_a_marker()
    {
        using var setup = new Setup(); await setup.Initialize(); var plan = await setup.Move();
        using (var d1 = new FileStream(setup.Database.Path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
        { await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(plan, None), "D1 écrivain ouvert refusé"); }
        Check.True(!File.Exists(setup.Destination), "aucune copie publiée");
        Check.True(!File.Exists(StorageWriteFence.Marker(setup.Database.Path)), "aucune protection posée avant exclusivité");
        Check.Equal(setup.Database.Path, (await setup.Reopen().DatabaseAsync(None)).Path, "original reste sélectionné");
    }

    [Test]
    public static async Task Interrupted_copy_is_explicitly_resumed_after_restart_without_replaying_the_first_plan()
    {
        using var setup = new Setup(); await setup.Initialize(); var plan = await setup.Move();
        setup.Cache.SwitchCheckpoint = point => { if (point == "copied") { throw new IOException("arrêt injecté après copie vérifiée"); } };
        await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(plan, None), "interruption après copie");
        Check.True(!File.Exists(setup.Destination), "copie vérifiée encore dans son fichier provisoire");
        var reopened = setup.Reopen(); var state = await reopened.InspectLocalStoreAsync(false, false, None);
        Check.True(state.Maintenance.Locked && state.Writer.Suspended, "bascule à reprendre et écritures suspendues");
        Check.True(!(await reopened.CheckStorageSwitchAsync(plan, None)).Current, "ancien plan non rejouable");
        var resume = Seal(await reopened.PrepareStorageResumeAsync(None));
        await reopened.ApplyStorageSwitchAsync(resume, None);
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageSwitchAsync(resume, None)).State, "reprise vérifiée sous son nouveau reçu");
        Check.Equal(setup.Destination, (await reopened.DatabaseAsync(None)).Path, "copie sélectionnée seulement après reprise explicite");
    }

    [Test]
    public static async Task Return_is_durable_without_deleting_copies_and_refuses_modified_destination()
    {
        using var setup = new Setup(); await setup.Initialize(); await setup.Cache.ApplyStorageSwitchAsync(await setup.Move(), None);
        var moved = await setup.Cache.DatabaseAsync(None);
        var rollback = Seal(await setup.Cache.PrepareStorageRollbackAsync(None));
        await setup.Cache.ApplyStorageSwitchAsync(rollback, None);
        Check.Equal(setup.Database.Path, (await setup.Reopen().DatabaseAsync(None)).Path, "retour durable");
        Check.True(File.Exists(moved.Path) && File.GetAttributes(moved.Path).HasFlag(FileAttributes.ReadOnly), "copie quittée conservée et protégée");
        Check.Equal(VerificationState.Verified, (await setup.Cache.VerifyStorageSwitchAsync(rollback, None)).State, "retour relu");
        await setup.Database.SaveFleetAsync(FleetCachePatch.Empty, None);
        await ExpectFailure(() => moved.SaveFleetAsync(FleetCachePatch.Empty, None), "instance de la copie quittée bloquée");
        using var changed = new Setup(); await changed.Initialize(); await changed.Cache.ApplyStorageSwitchAsync(await changed.Move(), None);
        await (await changed.Cache.DatabaseAsync(None)).SaveFleetAsync(FleetCachePatch.Empty, None);
        await ExpectFailure(() => changed.Cache.PrepareStorageRollbackAsync(None), "écritures nouvelles empêchent le retour");
    }

    [Test]
    public static async Task Interrupted_return_resumes_to_original_instead_of_reentering_forward_switch()
    {
        using var setup = new Setup(); await setup.Initialize(); await setup.Cache.ApplyStorageSwitchAsync(await setup.Move(), None);
        var rollback = Seal(await setup.Cache.PrepareStorageRollbackAsync(None));
        setup.Cache.SwitchCheckpoint = point => { if (point == "returning") { throw new IOException("arrêt injecté pendant retour"); } };
        await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(rollback, None), "retour interrompu");
        var reopened = setup.Reopen(); var resume = Seal(await reopened.PrepareStorageResumeAsync(None));
        Check.Equal(setup.Database.Path, resume.Changes.Single(c => c.Attribute == "store.path").AfterValue, "reprise dirigée vers l’original");
        await reopened.ApplyStorageSwitchAsync(resume, None);
        Check.Equal(setup.Database.Path, (await reopened.DatabaseAsync(None)).Path, "retour achevé");
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageSwitchAsync(resume, None)).State, "reçu de reprise du retour vérifié");
    }

    [Test]
    public static async Task Restore_uses_verified_backup_without_overwriting_original_and_rejects_foreign_domain()
    {
        using var setup = new Setup(); await setup.Initialize();
        var backup = await setup.Database.BackupAsync(None);
        var hash = DomeniaDatabase.SwitchFileFingerprint(backup.Path);
        var restore = Seal(await setup.Cache.PrepareStorageRestoreAsync(backup.Path, false, None));
        Check.True(restore.Confirmation.TypedNameRequired, "domaine à confirmer pour restauration");
        await setup.Cache.ApplyStorageSwitchAsync(restore, None);
        Check.Equal(hash, DomeniaDatabase.SwitchFileFingerprint(backup.Path), "sauvegarde intacte");
        Check.True(File.Exists(setup.Database.Path), "ancienne base conservée");
        Check.Equal(VerificationState.Verified, (await setup.Cache.VerifyStorageSwitchAsync(restore, None)).State, "restauration relue");
        var foreign = new DomeniaDatabase(System.IO.Path.Combine(setup.User, "foreign.db"), "DC=other,DC=local", TestClock.Fixed()); await foreign.InitializeAsync(None);
        await ExpectFailure(() => setup.Cache.PrepareStorageRestoreAsync(foreign.Path, false, None), "autre domaine refusé");
    }

    [Test]
    public static async Task Remote_receipts_stay_historical_and_pending_backup_cannot_be_restored()
    {
        using var setup = new Setup(); await setup.Initialize();
        var pc = Fixtures.Computer("PC1");
        await setup.Cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [pc]), null, None);
        var task = new RemoteTaskReadPlan(Guid.NewGuid(), setup.Database.StoreId, pc.ObjectGuid, pc.DistinguishedName,
            pc.DnsHostName!, pc.WhenCreated, Fixtures.Now, @"TEST\operator", RemoteTaskReadKind.UserIdentity, new('a', 64), new('b', 64));
        await setup.Database.PrepareTaskReadAsync(task, None);
        await ExpectFailure(() => setup.Move(), "nettoyage distant requis interdit déplacement");
        var pendingBackup = await setup.Database.BackupAsync(None);
        var completion = new RemoteTaskReadCompletion(Fixtures.Now, true, true, true, "Arrêt et nettoyage confirmés.");
        await setup.Database.CompleteTaskReadAsync(task.Id, 1, completion, None);
        await ExpectFailure(() => setup.Cache.PrepareStorageRestoreAsync(pendingBackup.Path, false, None), "copie avec tâche encore pendante refusée");
        await setup.Cache.ApplyStorageSwitchAsync(await setup.Move(), None);
        var moved = await setup.Cache.DatabaseAsync(None);
        var historical = await moved.ReadTaskReadAsync(task.Id, None);
        Check.NotNull(historical, "reçu terminé conservé après déplacement");
        Check.Equal(setup.Database.StoreId, historical!.Plan.StoreId, "provenance originale conservée");
        Check.Equal(0, (await moved.PendingTaskReadsAsync(None)).Length, "historique ne redevient pas travail en attente");
        await ExpectFailure(() => moved.PrepareTaskReadAsync(task, None), "ancien plan non réactivable");
        await ExpectFailure(() => moved.CompleteTaskReadAsync(task.Id, historical.Revision, completion, None), "même réessai exact reste historique en lecture seule");
    }

    private static WritePlan Seal(WritePlanDraft draft) => WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
    private static async Task ExpectFailure(Func<Task> action, string message)
    {
        var failed = false;
        try { await action(); } catch (Exception ex) when (ex is IOException or InvalidDataException or DomeniaOperationException or UnauthorizedAccessException) { failed = true; }
        Check.True(failed, message);
    }
    private sealed class Setup : IDisposable
    {
        private TemporaryFolder Folder { get; } = new();
        internal string App { get; }
        internal string User { get; }
        internal string Destination { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal DomeniaDatabase Database { get; private set; } = null!;
        internal Setup()
        {
            App = Folder.File("app"); User = Folder.File("profile"); Directory.CreateDirectory(App); Directory.CreateDirectory(User);
            Destination = Folder.File("deplacee.db"); Cache = Reopen();
        }
        internal CompatibleDirectoryCache Reopen() => new(App, User, "test.local", TestClock.Fixed());
        internal async Task Initialize() { Database = await Cache.DatabaseAsync(None); await Database.InitializeAsync(None); }
        internal async Task<WritePlan> Move() => Seal(await Cache.PrepareStorageMoveAsync(Destination, None));
        public void Dispose()
        {
            foreach (var file in Directory.EnumerateFiles(Folder.Path, "*", SearchOption.AllDirectories))
            { File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly); }
            Folder.Dispose();
        }
    }
}
