using System.Security.Cryptography;
using System.Text.Json;
using Domenia.App;

namespace Domenia.Tests;

internal static class PackageIntegrityTests
{
    private static readonly string[] Components = ["Domenia.exe", "Domenia.dll", "Domenia.deps.json", "Domenia.runtimeconfig.json",
        "Domenia.Core.dll", "Domenia.Ad.dll", "Domenia.Store.dll", "Domenia.Inventory.dll", "Domenia.Engine.dll",
        "Domenia.Bridge.dll", "Domenia.Simulation.dll", "web/index.html", "runtime/webview2/msedgewebview2.exe", "web/js/main.js"];

    private static void Pack(TemporaryFolder folder)
    {
        foreach (var name in Components)
        {
            var file = folder.File(name); Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, "trusted fixture " + name);
        }
        File.WriteAllBytes(folder.File(".lifecycle.lock"), []);
        Manifest(folder, Components);
    }

    private static void Manifest(TemporaryFolder folder, IEnumerable<string> names)
    {
        var files = names.Select(name => new { path = name, length = new FileInfo(folder.File(name)).Length,
            sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(folder.File(name)))) });
        File.WriteAllText(folder.File(PackageIntegrity.ManifestName), JsonSerializer.Serialize(new { format = 1, files }));
    }

    [Test]
    public static void Valid_package_holds_files_and_lifecycle_until_shutdown()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        using (var pack = PackageIntegrity.Open(folder.Path, true))
        {
            Check.True(pack.Packaged, "paquet reconnu"); Check.Equal(Components.Length, pack.FilesChecked, "tous les fichiers contrôlés");
            Check.Throws<IOException>(() => { using var stream = new FileStream(folder.File(".lifecycle.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None); }, "mise à jour concurrente refusée");
            Check.Throws<IOException>(() => File.WriteAllText(folder.File("web/js/main.js"), "modified"), "module protégé après vérification");
        }
        File.WriteAllText(folder.File("web/js/main.js"), "changed after exit");
        Check.Contains("changed after exit", File.ReadAllText(folder.File("web/js/main.js")), "verrou libéré à la fermeture");
    }

    [Test]
    public static void A_changed_component_or_an_unlisted_module_prevents_startup()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        File.WriteAllText(folder.File("web/js/main.js"), "tampered");
        Check.Contains("SHA-256", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "modification refusée").Message, "diagnostic contient preuve");
        Pack(folder); File.WriteAllText(folder.File("web/js/stale.js"), "stale");
        Check.Contains("hors manifeste", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "module obsolète refusé").Message, "extra identifié");
    }

    [Test]
    public static void Required_manifest_cannot_be_removed_to_bypass_checks()
    {
        using var folder = new TemporaryFolder();
        using (var development = PackageIntegrity.Open(folder.Path, false)) { Check.False(development.Packaged, "compilation non publiée explicite"); }
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "pack publié exige manifeste");
        Pack(folder); Manifest(folder, Components.Where(x => x != "Domenia.Core.dll"));
        Check.Contains("incomplet", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "composant omis refusé").Message, "manifeste incomplet");
    }

    [Test]
    public static void An_interrupted_update_is_refused_even_without_a_manifest()
    {
        using var folder = new TemporaryFolder(); Directory.CreateDirectory(folder.File("Support"));
        File.WriteAllText(folder.File("Support/.update.pending"), "interrupted");
        Check.Contains("interrompue", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, false).Dispose(), "marqueur bloque toute ouverture").Message, "restauration demandée");
    }

    [Test]
    public static void Duplicate_components_and_unsafe_windows_paths_are_rejected()
    {
        using var folder = new TemporaryFolder(); Pack(folder); Manifest(folder, Components.Append(Components[0]));
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "doublon refusé");
        foreach (var name in new[] { "../outside.dll", "/root.dll", "web/../module.js", "C:/x.dll", "web/x:stream", "web\\x.js", "web/x. ", "CON.dll", "web/LPT1.js", "web//x.js" })
        { Check.False(PackageIntegrity.ValidRelativePath(name), "chemin dangereux refusé : " + name); }
        Check.True(PackageIntegrity.ValidRelativePath("runtime/webview2/125.0/fr.pak"), "chemin relatif ordinaire accepté");
    }

    [Test]
    public static void Operator_configuration_is_not_a_pack_component()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        File.WriteAllText(folder.File("Domenia.config.json"), "{}");
        using var pack = PackageIntegrity.Open(folder.Path, true);
        File.WriteAllText(folder.File("Domenia.config.json"), "{\"setting\":true}");
        Check.True(pack.Packaged, "configuration locale distincte des fichiers runtime");
    }
}
