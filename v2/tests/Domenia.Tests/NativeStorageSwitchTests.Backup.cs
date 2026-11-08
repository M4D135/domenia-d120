using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static partial class NativeStorageSwitchTests
{
    [Test]
    public static async Task Pending_switch_refuses_new_or_prepared_backups_after_restart_without_touching_files()
    {
        using var setup = new Setup(); await setup.Initialize();
        var backup = Seal(await setup.Cache.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", null, None));
        var move = await setup.Move();
        setup.Cache.SwitchCheckpoint = stage => { if (stage == "copied") throw new IOException("Bascule interrompue après copie."); };
        await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(move, None), "interruption de bascule réelle");
        var reopened = setup.Reopen();
        Check.True((await reopened.InspectLocalStoreAsync(false, false, None)).Maintenance.Locked, "marqueur relu à froid");
        var original = DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path);
        var files = Directory.EnumerateFiles(Path.GetDirectoryName(setup.Database.Path)!, "*", SearchOption.AllDirectories).Order().ToArray();
        await Check.ThrowsAsync<DomeniaOperationException>(() => reopened.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", null, None), "préparation tient compte du marqueur du cache");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reopened.CheckStorageBackupAsync(backup, None), "contrôle d’un ancien plan refuse la bascule en attente");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reopened.ApplyStorageBackupAsync(backup, None), "ancien plan sauvegarde non envoyé pendant bascule");
        Check.Equal(original, DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path), "source intacte");
        Check.True(files.SequenceEqual(Directory.EnumerateFiles(Path.GetDirectoryName(setup.Database.Path)!, "*", SearchOption.AllDirectories).Order()), "aucune copie ni intention de sauvegarde ajoutée");
        Check.True((await reopened.InspectLocalStoreAsync(false, false, None)).Maintenance.Locked, "reprise toujours explicite");
    }
}
