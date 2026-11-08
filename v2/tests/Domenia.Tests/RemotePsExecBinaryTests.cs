using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class RemotePsExecBinaryTests
{
    private static readonly byte[] Fixture = "Fixture inerte de qualification ; ceci n’est pas un exécutable."u8.ToArray();
    private static string Hash => Convert.ToHexStringLower(SHA256.HashData(Fixture));

    [Test]
    public static void PsExec_binary_pin_binds_the_read_bytes_and_prevents_overwrite_delete_or_parent_move()
    {
        using var folder = new TemporaryFolder(); var parent = folder.File("package"); Directory.CreateDirectory(parent);
        var path = Path.Combine(parent, "fixture.bin"); File.WriteAllBytes(path, Fixture);
        using (var pinned = RemotePsExecBinary.Open(path, Hash, CancellationToken.None))
        {
            Check.Equal(Hash, pinned.Sha256, "octets relus"); Check.Equal(path, pinned.Path, "chemin exact qualifié");
            Check.Throws<IOException>(() => File.WriteAllBytes(path, [1]), "écrasement refusé pendant le bail");
            Check.Throws<IOException>(() => File.Delete(path), "suppression refusée pendant le bail");
            Check.Throws<IOException>(() => Directory.Move(parent, folder.File("moved")), "ancêtre épinglé");
        }
        Check.True(File.ReadAllBytes(path).SequenceEqual(Fixture), "octets initiaux conservés"); File.Delete(path);
    }

    [Test]
    public static void PsExec_discovery_is_bounded_and_absence_creates_or_downloads_nothing()
    {
        using var folder = new TemporaryFolder();
        Check.Null(RemotePsExecBinary.Find(folder.Path, CancellationToken.None), "outil optionnel absent");
        Check.Equal(0, Directory.GetFileSystemEntries(folder.Path).Length, "pas de dossier wad ni de fichier créé");
    }

    [Test]
    public static void A_PsExec_name_is_not_binary_approval_and_corrupted_bytes_are_refused()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("PsExec.exe"); File.WriteAllBytes(path, Fixture);
        var error = Check.Throws<IOException>(() => RemotePsExecBinary.Find(folder.Path, CancellationToken.None), "nom seul insuffisant");
        Check.Contains("Empreinte", error.Message, "refus portant bien sur les octets");
        var changed = Fixture.ToArray(); changed[^1] ^= 1; File.WriteAllBytes(path, changed);
        Check.Throws<IOException>(() => RemotePsExecBinary.Open(path, Hash, CancellationToken.None), "altération de même longueur");
        Check.True(File.ReadAllBytes(path).SequenceEqual(changed), "aucune réparation ou copie de remplacement");
    }

    [Test]
    public static void PsExec_binary_limits_and_cancellation_precede_execution()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("oversized.bin");
        using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write)) { file.SetLength(RemotePsExecBinary.MaximumBytes + 1L); }
        var error = Check.Throws<IOException>(() => RemotePsExecBinary.Open(path, Hash, CancellationToken.None), "taille bornée");
        Check.Contains("16 Mio", error.Message, "borne effectivement atteinte");
        using var stop = new CancellationTokenSource(); stop.Cancel();
        Check.Throws<OperationCanceledException>(() => RemotePsExecBinary.Open(path, Hash, stop.Token), "annulation avant qualification");
    }

    [Test]
    public static void PsExec_binary_and_ancestors_cannot_be_symbolic_links()
    {
        using var folder = new TemporaryFolder(); var real = folder.File("real"); Directory.CreateDirectory(real);
        var path = Path.Combine(real, "fixture.bin"); File.WriteAllBytes(path, Fixture);
        var fileLink = folder.File("file-link.bin"); File.CreateSymbolicLink(fileLink, path);
        Check.Throws<IOException>(() => RemotePsExecBinary.Open(fileLink, Hash, CancellationToken.None), "lien terminal refusé même avec le SHA correct");
        var directoryLink = folder.File("directory-link"); Directory.CreateSymbolicLink(directoryLink, real);
        Check.Throws<IOException>(() => RemotePsExecBinary.Open(Path.Combine(directoryLink, "fixture.bin"), Hash, CancellationToken.None), "ancêtre indirect refusé");
    }

    [Test]
    public static void PsExec_binary_with_multiple_hard_links_is_not_an_immutable_package()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("fixture.bin"); File.WriteAllBytes(path, Fixture);
        Check.True(CreateHardLinkW(folder.File("second.bin"), path, IntPtr.Zero), "lien matériel local réellement créé");
        Check.Throws<IOException>(() => RemotePsExecBinary.Open(path, Hash, CancellationToken.None), "nombre de liens vérifié depuis le handle");
    }

    [Test]
    public static void PsExec_path_qualification_rejects_UNC_ADS_relative_and_traversal_paths()
    {
        using var folder = new TemporaryFolder();
        foreach (var path in new[] { @"\\host\share\PsExec.exe", "PsExec.exe", folder.File("a\\..\\PsExec.exe"), folder.File("PsExec.exe:stream") })
        { Check.Throws<IOException>(() => RemotePsExecBinary.Open(path, Hash, CancellationToken.None), "chemin non admissible sans accès réseau"); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(string name, string existing, IntPtr security);
}
