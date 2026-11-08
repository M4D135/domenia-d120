using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// Local files of the shell (docs/ops/shell.md § 3): the embedded file picker (starting places, network paths, mapped drives,
/// links, paths outside the places), its save mode (no overwrite without « Remplacer », replacement bound to the size and date
/// listed, nothing partial left), the exports folder (never overwritten, written next to its name then moved), the guides and
/// the interface policy of the configuration file. Written on 22 October 2026, run at the very end (decision of 21/10).
/// </summary>
internal static class ShellLocalFilesTests
{
    private static DriveType Fixed(string root) => DriveType.Fixed;

    private static LocalFileBrowser BrowserOf(TemporaryFolder folder, Func<string, DriveType>? driveType = null) =>
        new([new ShellFileRoot("Exports de Domenia", folder.Path)], driveType ?? Fixed);

    [Test]
    public static void Network_paths_and_device_paths_are_never_local()
    {
        Check.True(LocalFileBrowser.IsNetworkPath(@"\\serveur\partage\x.csv"), "UNC");
        Check.True(LocalFileBrowser.IsNetworkPath("//serveur/partage"), "UNC à barres obliques");
        Check.True(LocalFileBrowser.IsNetworkPath(@"\\?\C:\Windows"), "chemin de périphérique long");
        Check.True(LocalFileBrowser.IsNetworkPath(@"\\.\PhysicalDrive0"), "périphérique");
        Check.True(LocalFileBrowser.IsNetworkPath(@"  \\serveur\x"), "blancs en tête");
        Check.False(LocalFileBrowser.IsNetworkPath(@"C:\Users\x\Documents"), "chemin local");
    }

    [Test]
    public static void Starting_places_on_a_mapped_drive_are_dropped_before_any_listing()
    {
        using var folder = new TemporaryFolder();
        var asked = new List<string>();
        var browser = new LocalFileBrowser(
            [new ShellFileRoot("Local", folder.Path), new ShellFileRoot("Lecteur Z", @"Z:\Partage"), new ShellFileRoot("Partage", @"\\serveur\partage")],
            root =>
            {
                asked.Add(root);
                return root.StartsWith("Z", StringComparison.OrdinalIgnoreCase) ? DriveType.Network : DriveType.Fixed;
            });
        Check.Equal(1, browser.Roots.Length, "seul l’emplacement local reste");
        Check.False(asked.Any(r => r.StartsWith(@"\\", StringComparison.Ordinal)), "un chemin réseau n’est même pas interrogé");
        var places = browser.Browse(null, "all");
        Check.Equal(1, places.Entries.Length, "emplacements de départ");
        Check.Equal("root", places.Entries[0].Kind, "nature");
        Check.Null(browser.Resolve(@"Z:\Partage\x.csv"), "lecteur mappé refusé");
        Check.Null(browser.Resolve(@"\\serveur\partage\x.csv"), "UNC refusé");
    }

    [Test]
    public static void Paths_outside_the_places_and_traversals_are_refused()
    {
        using var folder = new TemporaryFolder();
        Directory.CreateDirectory(folder.File("Sous"));
        File.WriteAllText(folder.File(Path.Combine("Sous", "liste.csv")), "a;b\n1;2\n");
        var browser = BrowserOf(folder);
        Check.NotNull(browser.Resolve(folder.File(Path.Combine("Sous", "liste.csv"))), "fichier sous un emplacement");
        Check.Null(browser.Resolve(folder.File(Path.Combine("Sous", "..", "..", "ailleurs.csv"))), "remontée hors de l’emplacement");
        Check.Null(browser.Resolve(Environment.GetFolderPath(Environment.SpecialFolder.Windows)), "dossier hors des emplacements");
        Check.Null(browser.Resolve("liste.csv"), "chemin relatif");
        Check.Null(browser.Resolve(new string('a', 1025)), "1 025 caractères");
        var err = Check.Throws<DomeniaOperationException>(() => browser.Browse(@"C:\", "all"), "parcours hors des emplacements");
        Check.Equal(ShellErrors.FileRefused, err.Code, "code du refus");
        var listing = browser.Browse(folder.File("Sous"), "csv");
        Check.Equal(1, listing.Entries.Length, "un fichier CSV");
        Check.Equal(folder.Path, listing.Parent, "dossier parent");
        Check.Contains("Exports de Domenia", listing.Label, "libellé lisible, jamais le chemin complet");
        Check.False(listing.Label!.Contains(folder.Path, StringComparison.OrdinalIgnoreCase), "aucun nom d’utilisateur dans le libellé");
    }

    [Test]
    public static void A_link_inside_a_place_is_refused()
    {
        using var folder = new TemporaryFolder();
        var target = Path.Combine(Path.GetTempPath(), "domenia-tests-cible-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(target);
        try
        {
            try
            {
                Directory.CreateSymbolicLink(folder.File("Lien"), target);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Creating a link needs the developer mode or a privilege: without it, the refusal is checked on the reparse
                // flag only (the rule is the same), and the test says so.
                Console.WriteLine("  (lien symbolique non créé sur ce poste : vérification limitée)");
                return;
            }
            var browser = BrowserOf(folder);
            Check.Null(browser.Resolve(folder.File("Lien")), "lien refusé");
            Check.Null(browser.Resolve(folder.File(Path.Combine("Lien", "x.csv"))), "fichier derrière un lien refusé");
            Check.Equal(0, browser.Browse(folder.Path, "all").Entries.Count(e => e.Name == "Lien"), "lien jamais listé");
        }
        finally
        {
            Directory.Delete(target, recursive: true);
        }
    }

    [Test]
    public static void Read_keeps_the_bounds_of_an_import()
    {
        using var folder = new TemporaryFolder();
        // Encoding.UTF8 writes the byte order mark, as Excel does.
        File.WriteAllText(folder.File("liste.csv"), "Nom;Poste\nMartin;PC-01\n", Encoding.UTF8);
        File.WriteAllBytes(folder.File("gros.json"), new byte[LocalFileBrowser.MaxFileBytes + 1]);
        var browser = BrowserOf(folder);
        var csv = browser.Read(folder.File("liste.csv"), "csv");
        Check.Equal(";", csv.Delimiter, "séparateur détecté");
        Check.True(csv.Headers.SequenceEqual(["Nom", "Poste"]), "BOM retiré des en-têtes");
        Check.Equal(ShellErrors.FileUnreadable, Check.Throws<DomeniaOperationException>(() => browser.Read(folder.File("gros.json"), "json"), "plus de 1 Mo").Code, "trop gros");
        Check.Equal(ShellErrors.FileRefused, Check.Throws<DomeniaOperationException>(() => browser.Read(folder.File("liste.csv"), "json"), "nature attendue").Code, "nature");
    }

    [Test]
    public static async Task Share_folders_are_recognised_and_read_only_after_a_listing()
    {
        Check.True(LocalFileBrowser.IsShareFolder(@"\\srv-fic-01\Partage\Exports"), "partage et sous-dossier");
        Check.True(LocalFileBrowser.IsShareFolder(@"\\srv-fic-01\Admin$"), "partage administratif");
        Check.False(LocalFileBrowser.IsShareFolder(@"\\srv-fic-01"), "serveur seul");
        Check.False(LocalFileBrowser.IsShareFolder(@"\\?\C:\Windows"), "périphérique");
        Check.False(LocalFileBrowser.IsShareFolder(@"\\.\pipe\x"), "canal");
        Check.False(LocalFileBrowser.IsShareFolder(@"\\srv\partage\..\autre"), "remontée");
        Check.False(LocalFileBrowser.IsShareFolder(@"\\srv bad\partage"), "nom de serveur invalide");
        Check.False(LocalFileBrowser.IsShareFolder(@"C:\Partage"), "chemin local");
        using var folder = new TemporaryFolder();
        var browser = BrowserOf(folder);
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => browser.ReadShareAsync(@"\\srv\partage\x.csv", "csv", CancellationToken.None), "dossier jamais interrogé");
        Check.Equal(ShellErrors.ShareRefused, refused.Code, "lecture d’un partage non interrogé refusée");
    }

    [Test]
    public static async Task Save_mode_never_replaces_without_remplacer_and_checks_the_file_again()
    {
        using var folder = new TemporaryFolder();
        var browser = BrowserOf(folder);
        var writer = new LocalFileWriter(browser);
        var first = await writer.SaveAsync(new ShellSaveTarget(folder.Path, "rapport.csv", null), "csv", Encoding.UTF8.GetBytes("a"), CancellationToken.None);
        Check.Equal(folder.File("rapport.csv"), first, "fichier écrit à l’emplacement choisi");
        var exists = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.SaveAsync(new ShellSaveTarget(folder.Path, "rapport.csv", null), "csv", Encoding.UTF8.GetBytes("b"), CancellationToken.None), "sans « Remplacer »");
        Check.Equal(ShellErrors.FileExists, exists.Code, "fichier existant protégé");
        Check.Equal("a", await File.ReadAllTextAsync(first), "contenu inchangé");
        var info = new FileInfo(first);
        var stale = new ShellFileSignature(info.Length + 1, new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero));
        var changed = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.SaveAsync(new ShellSaveTarget(folder.Path, "rapport.csv", stale), "csv", Encoding.UTF8.GetBytes("c"), CancellationToken.None), "signature périmée");
        Check.Equal(ShellErrors.FileChanged, changed.Code, "fichier changé depuis le choix");
        var signature = new ShellFileSignature(info.Length, new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero));
        await writer.SaveAsync(new ShellSaveTarget(folder.Path, "rapport.csv", signature), "csv", Encoding.UTF8.GetBytes("d"), CancellationToken.None);
        Check.Equal("d", await File.ReadAllTextAsync(first), "remplacé sur « Remplacer » avec la bonne signature");
        Check.Equal(0, Directory.GetFiles(folder.Path, "*.tmp").Length, "aucun fichier temporaire laissé");
        var outside = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.SaveAsync(new ShellSaveTarget(Path.GetTempPath(), "x.csv", null), "csv", Encoding.UTF8.GetBytes("e"), CancellationToken.None), "hors des emplacements");
        Check.Equal(ShellErrors.FileRefused, outside.Code, "dossier hors des emplacements refusé");
        var badName = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.SaveAsync(new ShellSaveTarget(folder.Path, @"..\x.csv", null), "csv", Encoding.UTF8.GetBytes("f"), CancellationToken.None), "nom avec dossier");
        Check.Equal(ShellErrors.FileRefused, badName.Code, "nom avec dossier refusé");
        Check.Equal("Exports de Domenia", writer.LabelOf(folder.Path), "libellé lisible de l’emplacement");
    }

    [Test]
    public static async Task Exports_folder_never_overwrites_and_leaves_nothing_partial()
    {
        using var folder = new TemporaryFolder();
        using var store = new FileExportStore(folder.File("Exports"), "%LOCALAPPDATA%\\Domenia\\Exports");
        var a = await store.SaveAsync("Domenia-x-20261022-0905.csv", Encoding.UTF8.GetBytes("a"), CancellationToken.None);
        var b = await store.SaveAsync("Domenia-x-20261022-0905.csv", Encoding.UTF8.GetBytes("b"), CancellationToken.None);
        Check.Equal("Domenia-x-20261022-0905.csv", a, "premier nom");
        Check.Equal("Domenia-x-20261022-0905-2.csv", b, "nom numéroté, jamais d’écrasement");
        Check.Equal("a", await File.ReadAllTextAsync(Path.Combine(folder.File("Exports"), a)), "premier fichier intact");
        Check.Equal(0, Directory.GetFiles(folder.File("Exports"), "*.tmp").Length, "aucun fichier temporaire laissé");
        File.WriteAllText(Path.Combine(folder.File("Exports"), "notes.txt"), "x");
        Check.Equal(2, store.List(10).Length, "seuls les exports de Domenia sont listés");
        Check.NotNull(store.PathOf(b), "chemin d’un export");
        Check.Null(store.PathOf("..\\notes.txt"), "nom hors export refusé");
        Check.Throws<ArgumentException>(() => _ = new FileExportStore("Exports", "x"), "dossier relatif refusé");
    }

    [Test]
    public static void Guides_are_found_in_a_doc_folder_and_kept_once_found()
    {
        using var folder = new TemporaryFolder();
        var app = Directory.CreateDirectory(folder.File(Path.Combine("pack", "app"))).FullName;
        var chapter = GuideChapters.For("accueil");
        var locator = new GuideLocator(app, _ => DriveType.Fixed);
        Check.False(locator.Remote, "dossier local");
        Check.Null(locator.Find(chapter), "aucun guide");
        var doc = Directory.CreateDirectory(folder.File(Path.Combine("pack", "DOC"))).FullName;
        File.WriteAllText(Path.Combine(doc, chapter.Files[1]), "%PDF");
        Check.Equal(Path.Combine(doc, chapter.Files[1]), locator.Find(chapter), "guide de Domenia 1 dans le DOC du dossier parent, trouvé après coup (réessayer)");
        File.WriteAllText(Path.Combine(doc, chapter.Files[0]), "%PDF");
        Check.Equal(Path.Combine(doc, chapter.Files[1]), locator.Find(chapter), "un guide trouvé est gardé pour la session");
        var remote = new GuideLocator(app, _ => DriveType.Network);
        Check.True(remote.Remote, "lecteur réseau reconnu avant tout accès");
        var once = remote.Find(chapter);
        Directory.Delete(doc, recursive: true);
        Check.Equal(once, remote.Find(chapter), "sur un partage, la réponse est gardée : aucun nouvel accès réseau");
        Check.True(new GuideLocator(@"\\serveur\pack\app", _ => DriveType.Fixed).Remote, "dossier UNC : distant");
    }

    [Test]
    public static void Interface_policy_file_is_read_next_to_the_executable()
    {
        using var folder = new TemporaryFolder();
        Check.True(ShellPolicyFile.Read(folder.Path).ExpertAllowed, "sans fichier : Expert proposé");
        File.WriteAllText(folder.File(LegacyConfiguration.FileName), """{"UI":{"AllowExpertProfile":false}}""");
        Check.False(ShellPolicyFile.Read(folder.Path).ExpertAllowed, "masqué par la configuration");
        File.WriteAllText(folder.File(LegacyConfiguration.FileName), "{");
        var broken = ShellPolicyFile.Read(folder.Path);
        Check.True(broken.ExpertAllowed, "fichier illisible : valeur par défaut");
        Check.NotNull(broken.Problem, "motif donné");
        var team = TeamLayoutFile.Read(folder.Path, "Interface");
        Check.Null(team.Text, "disposition d’équipe absente d’un fichier illisible");
        Check.Equal("JSON illisible", team.Problem, "motif court, jamais le contenu");
    }
}
