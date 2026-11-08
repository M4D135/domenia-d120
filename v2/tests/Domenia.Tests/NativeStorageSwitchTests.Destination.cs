using Domenia.Store;

namespace Domenia.Tests;

internal static partial class NativeStorageSwitchTests
{
    [Test]
    public static async Task Destination_write_probe_runs_only_after_confirmation_and_leaves_no_file_or_switch_on_interruption()
    {
        using var setup = new Setup(); await setup.Initialize();
        var source = DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path);
        var plan = await setup.Move();
        var directory = Path.GetDirectoryName(setup.Destination)!;
        Check.Equal(0, Directory.GetFiles(directory, ".domenia-write-probe-*.tmp").Length, "préparation en lecture seule");
        var checkedWrite = false;
        setup.Cache.SwitchCheckpoint = point =>
        {
            if (point != "destination-writable") return;
            checkedWrite = true;
            Check.Equal(0, Directory.GetFiles(directory, ".domenia-write-probe-*.tmp").Length, "fichier propre déjà supprimé après écriture et relecture réelles");
            throw new IOException("Interruption avant toute publication de bascule.");
        };
        await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(plan, None), "arrêt après le contrôle physique");
        Check.True(checkedWrite, "contrôle effectivement atteint");
        Check.False(File.Exists(setup.Destination), "aucune destination vide créée");
        Check.Equal(source, DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path), "original inchangé");
        Check.False(File.GetAttributes(setup.Database.Path).HasFlag(FileAttributes.ReadOnly), "original non protégé avant le marqueur");
        Check.False((await setup.Cache.InspectLocalStoreAsync(false, false, None)).Maintenance.Locked, "aucune bascule pendante fabriquée");
        setup.Cache.SwitchCheckpoint = null;
        await setup.Cache.ApplyStorageSwitchAsync(plan, None);
        Check.True(File.Exists(setup.Destination), "nouveau geste explicite possible après refus avant marqueur");
    }
}
