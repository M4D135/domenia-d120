using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Domenia.App;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class PackageUpdateTests
{
    private static string DefaultsSeed(int zoom = 115) => PreferenceTransfer.Export(new Dictionary<string, JsonElement>
        { [PreferenceApproval.ZoomKey] = JsonSerializer.SerializeToElement(zoom) }, "annuaire", Fixtures.Now).Text;

    private static Func<byte[], CancellationToken, Task<string?>> Backups(List<byte[]> saved) =>
        (bytes, _) => { saved.Add(bytes); return Task.FromResult<string?>("Domenia.settings.seed.avant-remplacement.json"); };

    [Test]
    public static async Task Define_defaults_writes_one_file_in_place_and_leaves_code_manifest_and_official_zip_intact()
    {
        using var folder = new TemporaryFolder();
        var zip = Pack(folder); var official = File.ReadAllBytes(zip);
        var source = folder.File("installed"); ZipFile.ExtractToDirectory(zip, source);
        File.WriteAllText(Path.Combine(source, "Domenia.config.json"), "private");
        var manifest = File.ReadAllBytes(Path.Combine(source, PackageIntegrity.ManifestName));
        var exe = File.ReadAllBytes(Path.Combine(source, "Domenia.exe"));
        var saved = new List<byte[]>(); var text = DefaultsSeed();
        var result = await PackageDefaults.WriteAsync(source, text, Backups(saved), default);
        Check.False(result.Simulated, "écriture réelle");
        Check.Equal(Path.Combine(source, PackageDefaults.SeedName), result.File, "un seul fichier à côté du code");
        Check.Equal(text, File.ReadAllText(result.File!), "texte validé exact");
        Check.Equal(Hash(Encoding.UTF8.GetBytes(text)), result.Sha256, "empreinte du fichier écrit");
        Check.True(result.Backup is null && saved.Count == 0, "aucune sauvegarde sans fichier précédent");
        Check.True(manifest.SequenceEqual(File.ReadAllBytes(Path.Combine(source, PackageIntegrity.ManifestName))), "manifeste inchangé");
        Check.True(exe.SequenceEqual(File.ReadAllBytes(Path.Combine(source, "Domenia.exe"))), "binaires inchangés");
        Check.True(official.SequenceEqual(File.ReadAllBytes(zip)), "ZIP officiel inchangé");
        Check.Equal("private", File.ReadAllText(Path.Combine(source, "Domenia.config.json")), "configuration administrateur intacte");
        Check.Equal(0, Directory.GetFiles(source, "*.part", SearchOption.AllDirectories).Length, "aucun fichier temporaire laissé");
        using var verified = PackageIntegrity.Open(source, true);
        Check.True(verified.Packaged && !verified.Components.Any(c => PackageIntegrity.IsDefaults(c.Path)), "démarrage admis, fichier hors manifeste");
    }

    [Test]
    public static async Task Define_defaults_backs_up_a_previous_file_before_replacing_it_and_skips_identical_content()
    {
        using var folder = new TemporaryFolder(); var source = folder.File("installed"); ZipFile.ExtractToDirectory(Pack(folder), source);
        var saved = new List<byte[]>(); var first = DefaultsSeed(110);
        await PackageDefaults.WriteAsync(source, first, Backups(saved), default);
        var same = await PackageDefaults.WriteAsync(source, first, Backups(saved), default);
        Check.True(same.Backup is null && saved.Count == 0, "contenu identique : rien réécrit ni sauvegardé");
        Check.Contains("déjà en place", same.Message, "aucun faux remplacement annoncé");
        var second = DefaultsSeed(125);
        var replaced = await PackageDefaults.WriteAsync(source, second, Backups(saved), default);
        Check.Equal(1, saved.Count, "une sauvegarde avant remplacement");
        Check.Equal(first, Encoding.UTF8.GetString(saved[0]), "sauvegarde de l’ancien fichier exact");
        Check.Equal("Domenia.settings.seed.avant-remplacement.json", replaced.Backup, "sauvegarde annoncée");
        Check.Contains("avant-remplacement", replaced.Message, "message cite la sauvegarde");
        Check.Equal(second, File.ReadAllText(replaced.File!), "nouveau fichier en place");
        await Check.ThrowsAsync<IOException>(() => PackageDefaults.WriteAsync(source, DefaultsSeed(140), (_, _) => Task.FromResult<string?>(null), default),
            "sans sauvegarde possible, aucun remplacement");
        Check.Equal(second, File.ReadAllText(replaced.File!), "fichier conservé après refus");
        using var verified = PackageIntegrity.Open(source, true);
        Check.True(verified.Packaged, "dossier toujours admis au démarrage");
    }

    [Test]
    public static async Task Define_defaults_in_a_light_wad_pack_lands_in_wad_and_keeps_the_sealed_contract()
    {
        using var source = new TemporaryFolder(); PackageIntegrityTests.LightPack(source);
        var result = await PackageDefaults.WriteAsync(source.Path, DefaultsSeed(), Backups([]), default);
        Check.Equal(Path.Combine(source.Path, "wad", PackageDefaults.SeedName), result.File, "fichier sous wad");
        using (var pack = PackageIntegrity.Open(source.Path, true))
        { Check.True(pack.IsLight && pack.Contract is not null, "variante et contrat scellé conservés"); }
        File.Move(result.File!, Path.Combine(source.Path, PackageDefaults.SeedName));
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(source.Path, true).Dispose(), "admis à sa place seulement, jamais à la racine");
    }

    [Test]
    public static async Task Define_defaults_refuses_DEV_tampered_unapproved_or_manifested_defaults_before_writing()
    {
        using var folder = new TemporaryFolder();
        var dev = folder.File("dev"); ZipFile.ExtractToDirectory(Pack(folder, kind: "DEV"), dev);
        await Check.ThrowsAsync<InvalidDataException>(() => PackageDefaults.WriteAsync(dev, DefaultsSeed(), Backups([]), default), "DEV refusé");
        var source = folder.File("installed"); ZipFile.ExtractToDirectory(Pack(folder), source);
        await Check.ThrowsAsync<InvalidDataException>(() => PackageDefaults.WriteAsync(source,
            DefaultsSeed().Replace("settings.zoom", "connection.password", StringComparison.Ordinal), Backups([]), default), "clé étrangère refusée");
        using (var stop = new CancellationTokenSource())
        {
            await stop.CancelAsync();
            await Check.ThrowsAsync<OperationCanceledException>(() => PackageDefaults.WriteAsync(source, DefaultsSeed(), Backups([]), stop.Token), "annulation avant écriture");
        }
        File.AppendAllText(Path.Combine(source, "Domenia.exe"), "changed");
        await Check.ThrowsAsync<InvalidDataException>(() => PackageDefaults.WriteAsync(source, DefaultsSeed(), Backups([]), default), "pack altéré refusé");
        Check.False(File.Exists(Path.Combine(dev, PackageDefaults.SeedName)) || File.Exists(Path.Combine(source, PackageDefaults.SeedName)), "aucun fichier écrit sur refus");

        var copy = folder.File("copie-2.1.5"); ZipFile.ExtractToDirectory(Pack(folder, edit: data =>
        {
            data[PackageDefaults.SeedName] = Utf8(DefaultsSeed());
            data[PackageIntegrity.ManifestName] = JsonSerializer.SerializeToUtf8Bytes(new { format = 1, files = data
                .Where(p => p.Key is not (PackageIntegrity.ManifestName or ".lifecycle.lock"))
                .Select(p => new { path = p.Key, length = p.Value.Length, sha256 = Hash(p.Value) }).ToArray() });
        }), copy);
        using (var legacy = PackageIntegrity.Open(copy, true))
        { Check.True(legacy.Components.Any(c => c.Path == PackageDefaults.SeedName), "copie antérieure valide, fichier au manifeste"); }
        var refused = await Check.ThrowsAsync<InvalidDataException>(() => PackageDefaults.WriteAsync(copy, DefaultsSeed(130), Backups([]), default),
            "fichier du manifeste jamais remplacé sur place");
        Check.Contains("ZIP officiel", refused.Message, "consigne de reprise");
        using var still = PackageIntegrity.Open(copy, true);
        Check.True(still.Packaged, "copie antérieure intacte");
    }
}
