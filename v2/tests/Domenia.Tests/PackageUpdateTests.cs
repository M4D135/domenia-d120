using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.App;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class PackageUpdateTests
{
    private static readonly string[] Required = ["Domenia.exe", "Domenia.dll", "Domenia.deps.json", "Domenia.runtimeconfig.json",
        "Domenia.Core.dll", "Domenia.Ad.dll", "Domenia.Store.dll", "Domenia.Inventory.dll", "Domenia.Engine.dll",
        "Domenia.Bridge.dll", "Domenia.Simulation.dll", "web/index.html", "runtime/webview2/msedgewebview2.exe"];
    private const string Name = "Domenia_2.0.1_PROD_Windows-x64.zip";
    private static string Hash(byte[] value) => Convert.ToHexStringLower(SHA256.HashData(value));
    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value);

    private static string Pack(TemporaryFolder root, Action<Dictionary<string, byte[]>>? edit = null, string architecture = "win-x64", string kind = "PROD")
    {
        var data = Required.ToDictionary(n => n, n => Utf8("Fichier fictif inerte : " + n), StringComparer.Ordinal);
        data["package-release.json"] = JsonSerializer.SerializeToUtf8Bytes(new
        {
            version = "2.0.1", build = "2.0.1+" + new string('a', 64), dataSchemaVersion = 11, dataSchemaRevision = 1,
            project = "Domenia", architecture, packageType = kind, sourceCommit = new string('b', 40), executableSha256 = Hash(data["Domenia.exe"]),
            dependencies = new Dictionary<string, string> { [".NET"] = "10.0.0", ["WebView2"] = "125.0.0.0" },
        });
        data["package-manifest.json"] = JsonSerializer.SerializeToUtf8Bytes(new { format = 1,
            files = data.Select(p => new { path = p.Key, length = p.Value.Length, sha256 = Hash(p.Value) }).ToArray() });
        data[".lifecycle.lock"] = [];
        edit?.Invoke(data);
        var path = root.File(Name);
        using (var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create))
        {
            foreach (var pair in data)
            {
                var entry = zip.CreateEntry(pair.Key, CompressionLevel.Optimal);
                using var content = entry.Open(); content.Write(pair.Value);
            }
        }
        File.WriteAllText(root.File(PackageUpdateCatalog.ChecksumsName), Hash(File.ReadAllBytes(path)) + "  " + Name + "\n", new UTF8Encoding(false));
        return path;
    }

    [Test]
    public static void Update_catalog_selects_semantic_latest_PROD_ignores_DEV_and_rejects_ambiguity()
    {
        string[] names = ["Domenia_2.9.0_PROD_Windows-x64.zip", "Domenia_2.10.0_PROD_Windows-x64.zip", "Domenia_3.0.0_DEV_Windows-x64.zip", "Domenia_9.0.0_PROD_Windows-x64.zip.tmp"];
        var sums = PackageUpdateCatalog.Checksums(Utf8(string.Join('\n', names.Select(n => new string('a', 64) + "  " + n))));
        var choices = PackageUpdateCatalog.FromChecksums(sums);
        Check.Equal("2.10.0", PackageUpdateCatalog.Latest(choices, "2.0.0")!.Version, "comparaison numérique et PROD seulement");
        var both = new Dictionary<string, string>(sums) { ["Domenia_3.0.0_PROD-LIGHT_Windows-x64.zip"] = new string('b', 64) };
        Check.Equal("2.10.0", PackageUpdateCatalog.Latest(PackageUpdateCatalog.FromChecksums(both), "2.0.0")!.Version, "PROD conserve sa variante");
        Check.Equal("3.0.0", PackageUpdateCatalog.Latest(PackageUpdateCatalog.FromChecksums(both, true), "2.0.0", light: true)!.Version, "LIGHT conserve la sienne");
        Check.True(PackageUpdateCatalog.Latest(choices, "2.10.0") is null, "absence de nouvelle version");
        Check.Equal("2.10.0", PackageUpdateCatalog.Latest(choices, "2.10.0-dev+local")!.Version, "une stable peut remplacer son développement");
        Check.Throws<InvalidDataException>(() => PackageUpdateCatalog.Latest(choices.Concat(choices), "2.0.0"), "publication ambiguë refusée");
        Check.Throws<InvalidDataException>(() => PackageUpdateCatalog.Checksums(Utf8(new string('a', 64) + "  " + Name + "\n" + new string('b', 64) + "  " + Name.ToUpperInvariant())), "doublon Windows refusé");
        Check.Throws<InvalidDataException>(() => PackageUpdateCatalog.StableVersion("02.1.0"), "pas de version ambiguë");
    }

    [Test]
    public static async Task Local_update_prepares_exact_private_copy_and_never_changes_original_files()
    {
        using var folder = new TemporaryFolder(); var zip = Pack(folder); var before = File.ReadAllBytes(zip);
        using var sources = new PackageUpdateSources(AppMode.Directory);
        var offer = await sources.LocalZipAsync(zip, default);
        Check.Equal(Hash(before), offer.Asset.Sha256, "empreinte de provenance sélectionnée");
        var prepared = await sources.PrepareAsync(offer, folder.File("preparations"), default);
        Check.Equal("2.0.1", prepared.Version, "version vérifiée de la copie");
        Check.Equal(Hash(before), prepared.ArchiveSha256, "archive réelle relue");
        PackageLifecycleFiles.RequirePrivate(Path.GetDirectoryName(prepared.Directory)!);
        using var verified = PackageIntegrity.Open(prepared.Directory, true);
        Check.Equal(prepared.ManifestSha256, verified.ManifestHash, "copie entière validée par vérificateur livré");
        Check.True(before.SequenceEqual(File.ReadAllBytes(zip)), "source inchangée, ouverte en lecture seule");
        Check.False(File.Exists(folder.File("Domenia.exe")), "aucune installation dans le dossier de diffusion");
    }

    [Test]
    public static async Task Folder_update_refuses_changed_catalog_and_keeps_existing_installation_untouched()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        var installed = folder.File("old.exe"); File.WriteAllText(installed, "ancienne installation");
        using var sources = new PackageUpdateSources(AppMode.Directory);
        var offer = await sources.FolderAsync(folder.Path, "2.0.0", default);
        Check.NotNull(offer, "précondition positive de sélection réelle");
        File.AppendAllText(folder.File(PackageUpdateCatalog.ChecksumsName), "\n");
        await Check.ThrowsAsync<InvalidDataException>(() => sources.PrepareAsync(offer!, folder.File("preparations"), default), "CAS du catalogue après aperçu");
        Check.Equal("ancienne installation", File.ReadAllText(installed), "aucun remplacement avant préparation vérifiée");
    }

    [Test]
    public static void Zip_hash_component_hash_and_exact_inventory_all_gate_preparation()
    {
        using var folder = new TemporaryFolder(); var zip = Pack(folder); var expected = Hash(File.ReadAllBytes(zip));
        Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Prepare(zip, new string('0', 64), "2.0.1", folder.File("wronghash"), default), "SHA du ZIP incorrect");
        Check.False(Directory.Exists(folder.File("wronghash")), "aucune extraction avant SHA");
        Pack(folder, data => data["web/index.html"] = Utf8("octets altérés"));
        Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Prepare(zip, Hash(File.ReadAllBytes(zip)), "2.0.1", folder.File("changed"), default), "même ZIP signé par le hash extérieur mais composant incohérent");
        Pack(folder, data => data["private.log"] = Utf8("doit être refusé"));
        Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Prepare(zip, Hash(File.ReadAllBytes(zip)), "2.0.1", folder.File("extra"), default), "fichier hors manifeste refusé");
        Check.False(Directory.Exists(folder.File("extra")), "inventaire intégral avant extraction");
        Check.True(expected != Hash(File.ReadAllBytes(zip)), "archives négatives distinctes de la fixture positive");
    }

    [Test]
    public static void Zip_rejects_traversal_case_aliases_links_and_excessive_ratio()
    {
        foreach (var hostile in new[] { "../outside", "Domenia.EXE", "web/CON.txt", "C:/absolute", "web/x:ads", "web/back\\slash" })
        {
            using var folder = new TemporaryFolder(); var zip = Pack(folder, d => d[hostile] = [1]);
            using var archive = ZipFile.OpenRead(zip);
            Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Inspect(archive), "nom hostile refusé : " + hostile);
        }
        using var linkRoot = new TemporaryFolder(); var linkZip = Pack(linkRoot);
        using (var archive = ZipFile.Open(linkZip, ZipArchiveMode.Update)) { archive.GetEntry("web/index.html")!.ExternalAttributes = 0xA1FF << 16; }
        using (var archive = ZipFile.OpenRead(linkZip)) { Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Inspect(archive), "lien Unix refusé avant extraction"); }
        using var ratioRoot = new TemporaryFolder(); var ratioZip = Pack(ratioRoot, d => d["bomb"] = new byte[4 * 1024 * 1024]);
        using var ratio = ZipFile.OpenRead(ratioZip);
        Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Inspect(ratio), "ratio excessif refusé sans allouer les octets annoncés");
    }

    [Test]
    public static void Zip_requires_PROD_compatible_architecture_and_manifested_executable_identity()
    {
        foreach (var pair in new[] { ("win-arm64", "PROD"), ("win-x64", "DEV") })
        {
            using var folder = new TemporaryFolder(); var zip = Pack(folder, architecture: pair.Item1, kind: pair.Item2);
            Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Prepare(zip, Hash(File.ReadAllBytes(zip)), "2.0.1", folder.File("package"), default), "type/architecture incompatibles");
            Check.False(Directory.Exists(folder.File("package")), "refus avant extraction");
        }
        using var valid = new TemporaryFolder(); var path = Pack(valid);
        Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Prepare(path, Hash(File.ReadAllBytes(path)), "2.0.2", valid.File("wrong-version"), default), "version différente de l’offre");
    }

    [Test]
    public static async Task Demo_direct_acquisition_calls_do_not_touch_files()
    {
        using var sources = new PackageUpdateSources(AppMode.Simulation);
        await Check.ThrowsAsync<InvalidOperationException>(() => sources.FolderAsync(@"\\missing\share", "2.0.0", default), "partage réel interdit avant toute qualification réseau");
        await Check.ThrowsAsync<InvalidOperationException>(() => sources.LocalZipAsync(@"C:\not-read.zip", default), "fichier réel interdit avant lecture");
        var offer = new UpdateOffer("folder", @"\\missing\share", new(Name, "2.0.1", 1, new string('a', 64)), new string('b', 64));
        await Check.ThrowsAsync<InvalidOperationException>(() => sources.PrepareAsync(offer, @"C:\not-created", default), "installation réelle bloquée côté moteur");
    }

    [Test]
    public static async Task Preparation_accepts_only_the_distribution_folder_or_a_local_ZIP()
    {
        // GitHub was removed as an update source (David, 08/11/2026): an offer naming any other source never reaches the disk.
        using var parent = new TemporaryFolder(); using var sources = new PackageUpdateSources(AppMode.Directory);
        foreach (var source in new[] { "github", "Folder", "" })
        {
            var offer = new UpdateOffer(source, parent.Path, new(Name, "2.0.1", 1, new string('a', 64)), new string('b', 64));
            await Check.ThrowsAsync<InvalidDataException>(() => sources.PrepareAsync(offer, parent.Path, default), "source hors dossier et ZIP refusée");
        }
        Check.False(Directory.EnumerateFileSystemEntries(parent.Path).Any(), "aucune préparation créée");
    }

    [Test]
    public static async Task Missing_or_incomplete_folder_publication_cannot_be_selected_as_success()
    {
        using var folder = new TemporaryFolder(); using var sources = new PackageUpdateSources(AppMode.Directory);
        await Check.ThrowsAsync<FileNotFoundException>(() => sources.FolderAsync(folder.Path, "2.0.0", default), "manifeste absent");
        File.WriteAllText(folder.File(PackageUpdateCatalog.ChecksumsName), new string('a', 64) + "  " + Name);
        await Check.ThrowsAsync<FileNotFoundException>(() => sources.FolderAsync(folder.Path, "2.0.0", default), "ZIP absent malgré catalogue publié");
        File.WriteAllBytes(folder.File(Name), []);
        await Check.ThrowsAsync<InvalidDataException>(() => sources.FolderAsync(folder.Path, "2.0.0", default), "ZIP incomplet vide");
    }
}
