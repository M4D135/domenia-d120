using System.Security.Cryptography;
using System.Text.Json;
using Domenia.App;

namespace Domenia.Tests;

internal static partial class PackageIntegrityTests
{
    private static SocleWebView FakeSocle(TemporaryFolder pack, params (string Name, string Text)[] files)
    {
        var entries = new List<object>();
        foreach (var (name, text) in files)
        {
            var path = pack.File("wad/" + SocleWebView.Folder + "/" + name);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, text);
            var bytes = File.ReadAllBytes(path);
            entries.Add(new { path = SocleWebView.Folder + "/" + name, bytes = bytes.LongLength, sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) });
        }
        return SocleWebView.Parse(JsonSerializer.SerializeToUtf8Bytes(new
        { component = "webview2-fixed", version = SocleWebView.PinnedVersion, root = SocleWebView.Folder, file_count = entries.Count, files = entries }));
    }

    [Test]
    public static void A_light_pack_admits_the_Socle_engine_only_as_its_exact_index()
    {
        using var pack = new TemporaryFolder(); LightPack(pack);
        var socle = FakeSocle(pack, ("msedgewebview2.exe", "moteur"), ("msedge.dll", "bibliothèque"), ("Locales/fr.pak", "langue"));
        using (var verified = PackageIntegrity.OpenWithSocle(pack.Path, socle))
            Check.True(verified.IsLight && verified.Socle == socle && verified.FilesChecked == verified.Components.Count + 3,
                "moteur du Socle vérifié fichier par fichier à côté du pack");
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(pack.Path, true).Dispose(), "un autre contenu que l’index épinglé n’est jamais admis");
        var extra = pack.File("wad/" + SocleWebView.Folder + "/Locales/de.pak");
        File.WriteAllText(extra, "ajout");
        Check.Contains("Fichier étranger au pack WebView2 du Socle", Check.Throws<InvalidDataException>(
            () => PackageIntegrity.OpenWithSocle(pack.Path, socle).Dispose(), "fichier ajouté au moteur").Message, "cause nommée");
        File.Delete(extra);
        var library = pack.File("wad/" + SocleWebView.Folder + "/msedge.dll");
        File.WriteAllText(library, "bibliothèquE");
        Check.Throws<InvalidDataException>(() => PackageIntegrity.OpenWithSocle(pack.Path, socle).Dispose(), "octets modifiés, même taille");
        File.Delete(library);
        Check.Contains("incomplet", Check.Throws<InvalidDataException>(
            () => PackageIntegrity.OpenWithSocle(pack.Path, socle).Dispose(), "fichier du moteur absent").Message, "cause nommée");
    }

    [Test]
    public static void The_pinned_Socle_index_is_the_published_156_engine()
    {
        var socle = SocleWebView.Pinned;
        Check.Equal(SocleWebView.PinnedVersion, socle.Version, "version du Socle épinglée");
        Check.Equal(257, socle.Files.Count, "les 257 fichiers publiés");
        Check.Equal(706167729L, socle.Files.Sum(f => f.Length), "taille décompressée publiée");
        Check.True(socle.Files.All(f => f.Path.StartsWith(SocleWebView.Folder + "/", StringComparison.Ordinal)), "tout le moteur sous runtime/webview2");
    }

    [Test]
    public static void A_Socle_index_with_an_unexpected_shape_is_refused()
    {
        static object Entry(string path, string? sha = null) => new { path, bytes = 1L, sha256 = sha ?? new string('a', 64) };
        static byte[] Index(object[] files, int? count = null, string root = SocleWebView.Folder) => JsonSerializer.SerializeToUtf8Bytes(new
        { component = "webview2-fixed", version = SocleWebView.PinnedVersion, root, file_count = count ?? files.Length, files });
        var exe = Entry(SocleWebView.Folder + "/msedgewebview2.exe"); var library = Entry(SocleWebView.Folder + "/msedge.dll");
        Check.Equal(2, SocleWebView.Parse(Index([exe, library])).Files.Count, "index minimal du moteur");
        foreach (var (bytes, why) in new[]
        {
            (Index([exe]), "moteur incomplet"),
            (Index([exe, library], count: 3), "nombre de fichiers différent"),
            (Index([exe, library, Entry(SocleWebView.Folder + "/MSEDGE.DLL")]), "doublon à la casse près"),
            (Index([exe, library, Entry("runtime/autre/x.dll")]), "fichier hors du dossier du moteur"),
            (Index([exe, library, Entry(SocleWebView.Folder + "/../x.dll")]), "remontée de dossier"),
            (Index([exe, library, Entry(SocleWebView.Folder + "/x.dll", "zz")]), "empreinte invalide"),
            (Index([exe, library], root: "runtime/webview3"), "autre racine"),
        })
            Check.Throws<InvalidDataException>(() => SocleWebView.Parse(bytes), why);
    }
}
