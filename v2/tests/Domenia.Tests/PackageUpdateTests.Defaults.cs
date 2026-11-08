using System.IO.Compression;
using System.Text.Json;
using Domenia.App;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class PackageUpdateTests
{
    [Test]
    public static async Task A_light_pack_keeps_its_variant_through_redistribution_and_update_preparation()
    {
        using var source = new TemporaryFolder();
        using var distribution = new TemporaryFolder();
        using var recipient = new TemporaryFolder();
        PackageIntegrityTests.LightPack(source);
        var copy = PackageDefaults.Create(source.Path, distribution.Path, null, DefaultsSeed(), default);
        var version = ProductInfo.DevelopmentVersion;
        Check.Equal($"Domenia_{version}_PROD-LIGHT_Windows-x64.zip", Path.GetFileName(copy.Archive), "la diffusion conserve son nom LIGHT");
        using var fullUpdates = new PackageUpdateSources(AppMode.Directory);
        using var lightUpdates = new PackageUpdateSources(AppMode.Directory, light: true);
        await Check.ThrowsAsync<InvalidDataException>(() => fullUpdates.LocalZipAsync(copy.Archive!, default), "un PROD complet ne sélectionne pas LIGHT");
        var offer = await lightUpdates.LocalZipAsync(copy.Archive!, default);
        var installed = await lightUpdates.PrepareAsync(offer, recipient.File("preparations"), default);
        using var checkedCopy = PackageIntegrity.Open(installed.Directory, true);
        Check.True(checkedCopy.IsLight && checkedCopy.Contract is not null, "contrat scellé et sélection Evergreen après extraction");
        Check.Throws<InvalidDataException>(() => PackageUpdateArchive.Prepare(copy.Archive!, copy.Sha256!, version, recipient.File("wrong-edition"), default),
            "le contenu LIGHT ne peut pas être préparé comme un PROD");
    }

    private static string DefaultsSeed() => PreferenceTransfer.Export(new Dictionary<string, JsonElement>
        { [PreferenceApproval.ZoomKey] = JsonSerializer.SerializeToElement(115) }, "annuaire", Fixtures.Now).Text;

    [Test]
    public static void Wad_archive_and_defaults_roundtrip_preserve_layout_and_private_configuration()
    {
        using var folder = new TemporaryFolder(); var zip = Pack(folder); var source = folder.File("wad-source");
        ZipFile.ExtractToDirectory(zip, source); WadPackageFixture.Convert(source);
        var privateConfig = Path.Combine(source, "wad/Domenia.config.json"); File.WriteAllText(privateConfig, "private");
        var text = DefaultsSeed(); var result = PackageDefaults.Create(source, folder.Path, null, text, default);
        var expected = PackageUpdateArchive.Prepare(result.Archive!, result.Sha256!, "2.0.1", folder.File("wad-recipient"), default);
        using var verified = PackageIntegrity.Open(expected.Directory, true);
        Check.Equal("wad/package-manifest.json", verified.ManifestRelativePath, "disposition conservée après diffusion et extraction");
        Check.Equal(text, File.ReadAllText(Path.Combine(expected.Directory, "wad/" + PackageDefaults.SeedName)), "réglages diffusés sous wad");
        Check.False(File.Exists(Path.Combine(expected.Directory, "wad/Domenia.config.json")), "configuration privée exclue");
        Check.Equal("private", File.ReadAllText(privateConfig), "source intacte");
    }

    [Test]
    public static void Define_defaults_produces_a_verified_redistributable_pack_and_leaves_running_pack_intact()
    {
        using var folder = new TemporaryFolder();
        var originalZip = Pack(folder); var source = folder.File("installed"); ZipFile.ExtractToDirectory(originalZip, source);
        File.WriteAllText(Path.Combine(source, "Domenia.config.json"), "Private local configuration must never be copied");
        var manifest = File.ReadAllBytes(Path.Combine(source, PackageIntegrity.ManifestName));
        var text = DefaultsSeed();
        var result = PackageDefaults.Create(source, folder.Path, folder.File("operator-data"), text, default);
        Check.False(result.Cancelled, "copie achevée"); Check.False(result.Simulated, "vraies copies temporaires locales");
        Check.True(File.Exists(result.Archive!), "ZIP disponible");
        var checksums = PackageUpdateCatalog.Checksums(File.ReadAllBytes(Path.Combine(result.Directory!, PackageUpdateCatalog.ChecksumsName)));
        Check.Equal(result.Sha256, checksums[Path.GetFileName(result.Archive!)], "empreinte du ZIP diffusé");
        var expected = PackageUpdateArchive.Prepare(result.Archive!, result.Sha256!, "2.0.1", folder.File("recipient"), default);
        using var verified = PackageIntegrity.Open(expected.Directory, true);
        Check.Equal(text, File.ReadAllText(Path.Combine(expected.Directory, PackageDefaults.SeedName)), "configuration reçue exacte");
        Check.False(File.Exists(Path.Combine(expected.Directory, "Domenia.config.json")), "configuration locale privée exclue");
        Check.False(File.Exists(Path.Combine(source, PackageDefaults.SeedName)), "aucun changement du logiciel ouvert");
        Check.True(manifest.SequenceEqual(File.ReadAllBytes(Path.Combine(source, PackageIntegrity.ManifestName))), "manifeste original inchangé");
        Check.Equal(Hash(File.ReadAllBytes(Path.Combine(source, "Domenia.exe"))), Hash(File.ReadAllBytes(Path.Combine(expected.Directory, "Domenia.exe"))), "binaires sans recompilation");
    }

    [Test]
    public static void Define_defaults_refuses_unapproved_values_or_destinations_before_creating_output()
    {
        using var folder = new TemporaryFolder(); var zip = Pack(folder); var source = folder.File("installed"); ZipFile.ExtractToDirectory(zip, source);
        var data = folder.File("operator-data"); Directory.CreateDirectory(data);
        var seed = DefaultsSeed();
        Check.Throws<InvalidDataException>(() => PackageDefaults.Create(source, source, data, seed, default), "jamais dans l’installation");
        Check.Throws<InvalidDataException>(() => PackageDefaults.Create(source, data, data, seed, default), "jamais dans les données");
        Check.Throws<InvalidDataException>(() => PackageDefaults.Create(source, folder.Path, data, seed.Replace("settings.zoom", "connection.password", StringComparison.Ordinal), default), "clé étrangère refusée");
        Check.Equal(0, Directory.GetDirectories(folder.Path, "Domenia-diffusion-*").Length, "aucun dossier après refus");
    }

    [Test]
    public static void Define_defaults_refuses_a_tampered_or_DEV_source_and_honors_cancellation()
    {
        using var folder = new TemporaryFolder(); var zip = Pack(folder, kind: "DEV"); var source = folder.File("installed"); ZipFile.ExtractToDirectory(zip, source);
        Check.Throws<InvalidDataException>(() => PackageDefaults.Create(source, folder.Path, null, DefaultsSeed(), default), "DEV non redistribué comme PROD");
        File.AppendAllText(Path.Combine(source, "Domenia.exe"), "changed");
        Check.Throws<InvalidDataException>(() => PackageDefaults.Create(source, folder.Path, null, DefaultsSeed(), default), "mélange de binaires refusé");
        using var stop = new CancellationTokenSource(); stop.Cancel();
        Check.Throws<OperationCanceledException>(() => PackageDefaults.Create(source, folder.Path, null, DefaultsSeed(), stop.Token), "annulation avant création");
        Check.Equal(0, Directory.GetDirectories(folder.Path, "Domenia-diffusion-*").Length, "aucune diffusion partielle sur refus initial");
    }
}
