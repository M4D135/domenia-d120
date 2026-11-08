using System.Security.Cryptography;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LegacyCompatibilityFilesTests
{
    [Test]
    public static async Task Explicit_fixed_copies_preserve_sources_and_existing_destinations_even_empty()
    {
        using var folder = new TemporaryFolder(); var app = folder.File("app"); var user = folder.File("profile");
        Directory.CreateDirectory(app); Directory.CreateDirectory(user);
        await File.WriteAllTextAsync(Path.Combine(app, "ADCC.theme.cfg"), "dark");
        await File.WriteAllTextAsync(Path.Combine(app, "ADCC.login-mode.cfg"), "current");
        await File.WriteAllTextAsync(Path.Combine(app, "Domenia.login-mode.cfg"), "");
        await File.WriteAllTextAsync(Path.Combine(app, "ADCC.other.cfg"), "hors liste");
        var before = Directory.GetFiles(app).Order().ToArray();
        var preview = LegacyCompatibilityFiles.Preview(app, user, default);
        Check.True(before.SequenceEqual(Directory.GetFiles(app).Order()), "inspection ne crée aucun fichier");
        Check.Equal(5, preview.Copies.Length, "quatre noms ADCC et un déplacement de préférences, liste fermée");
        Check.Equal("kept", preview.Copies.Single(c => c.Id == "adcc.login-mode.cfg").State, "destination vide conservée");
        var copy = preview.Copies.Single(c => c.Id == "adcc.theme.cfg");
        var receipt = LegacyCompatibilityFiles.Apply(app, user, copy.Id, preview.Fingerprint, default);
        Check.True(receipt.Applied, "copie explicitement appliquée et relue");
        Check.Equal("dark", await File.ReadAllTextAsync(copy.Destination), "octets copiés sans interprétation");
        Check.Equal("dark", await File.ReadAllTextAsync(copy.Source), "source intacte");
        Check.Equal("", await File.ReadAllTextAsync(Path.Combine(app, "Domenia.login-mode.cfg")), "aucun remplacement");
        Check.False(File.Exists(Path.Combine(app, "Domenia.other.cfg")), "aucune copie joker");
        await Check.ThrowsAsync<InvalidDataException>(() => Task.Run(() => LegacyCompatibilityFiles.Apply(app, user, copy.Id, preview.Fingerprint, default)), "ancien aperçu non rejoué");
        Check.Equal(0, Directory.GetFiles(app, ".domenia-compat-*.tmp").Length, "aucun provisoire restant");
    }

    [Test]
    public static async Task Settings_copy_uses_only_validated_data_root_and_refuses_changed_or_busy_sources()
    {
        using var folder = new TemporaryFolder(); var app = folder.File("app"); var user = folder.File("profile");
        Directory.CreateDirectory(app); Directory.CreateDirectory(user); var data = Path.Combine(app, "data"); Directory.CreateDirectory(data);
        await File.WriteAllTextAsync(Path.Combine(app, "Domenia.config.json"), "{\"LocalStore\":{\"Mode\":\"Portable\"}}");
        var source = Path.Combine(data, "Domenia.settings.json"); await File.WriteAllTextAsync(source, "{\"Search.WorkspacesJson\":\"[]\"}");
        var original = await File.ReadAllBytesAsync(source);
        var preview = LegacyCompatibilityFiles.Preview(app, user, default);
        Check.False(Directory.Exists(Path.Combine(data, "Preferences")), "aperçu n’a pas créé Preferences");
        using (var writer = new FileStream(source, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
            await Check.ThrowsAsync<IOException>(() => Task.Run(() => LegacyCompatibilityFiles.Apply(app, user, "settings", preview.Fingerprint, default)), "source occupée refusée");
        var receipt = LegacyCompatibilityFiles.Apply(app, user, "settings", preview.Fingerprint, default);
        Check.Equal(Path.Combine(data, "Preferences", "Domenia.settings.json"), receipt.Destination, "destination du mode Portable uniquement");
        Check.Equal(Convert.ToHexStringLower(SHA256.HashData(original)), receipt.Sha256, "empreinte réelle relue");
        var after = await File.ReadAllBytesAsync(source); Check.True(original.SequenceEqual(after), "source intacte");
        Check.False(Directory.Exists(Path.Combine(user, "Data")), "aucune destination de repli créée");
    }

    [Test]
    public static async Task Compatibility_preview_rejects_bad_json_network_paths_and_stale_confirmation_without_overwrite()
    {
        using var folder = new TemporaryFolder(); var app = folder.File("app"); var user = folder.File("profile"); Directory.CreateDirectory(app); Directory.CreateDirectory(user);
        await File.WriteAllTextAsync(Path.Combine(app, "ADCC.config.json"), "{\"x\":1,\"X\":2}");
        var preview = LegacyCompatibilityFiles.Preview(app, user, default);
        Check.Equal("refused", preview.Copies.Single(c => c.Id == "adcc.config.json").State, "doublons refusés");
        await Check.ThrowsAsync<InvalidDataException>(() => Task.Run(() => LegacyCompatibilityFiles.Preview(@"\\invalid-host\share", user, default)), "UNC refusé avant ouverture");
        await File.WriteAllTextAsync(Path.Combine(app, "ADCC.theme.cfg"), "dark"); preview = LegacyCompatibilityFiles.Preview(app, user, default);
        await File.WriteAllTextAsync(Path.Combine(app, "ADCC.theme.cfg"), "light");
        await Check.ThrowsAsync<InvalidDataException>(() => Task.Run(() => LegacyCompatibilityFiles.Apply(app, user, "adcc.theme.cfg", preview.Fingerprint, default)), "source modifiée depuis l’aperçu refusée");
        Check.False(File.Exists(Path.Combine(app, "Domenia.theme.cfg")), "aucune publication après refus");
    }
}
