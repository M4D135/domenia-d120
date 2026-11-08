using System.Security.Cryptography;
using System.Text.Json;
using Domenia.App;

namespace Domenia.Tests;

internal static class WadPackageFixture
{
    internal static void Convert(string root)
    {
        using var manifest = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root, "package-manifest.json")));
        var names = manifest.RootElement.GetProperty("files").EnumerateArray().Select(f => f.GetProperty("path").GetString()!).ToArray();
        var wad = Path.Combine(root, "wad"); Directory.CreateDirectory(wad);
        foreach (var path in Directory.GetFileSystemEntries(root))
        {
            var name = Path.GetFileName(path);
            if (name is "Domenia.exe" or "wad") continue;
            if (Directory.Exists(path)) Directory.Move(path, Path.Combine(wad, name));
            else File.Move(path, Path.Combine(wad, name));
        }
        var files = names.Select(name => name == "Domenia.exe" ? name : "wad/" + name).Select(name => new
        {
            path = name, length = new FileInfo(Path.Combine(root, name)).Length,
            sha256 = ConvertHash(Path.Combine(root, name))
        });
        File.WriteAllText(Path.Combine(wad, "package-manifest.json"), JsonSerializer.Serialize(new { format = 1, files }));
    }
    private static string ConvertHash(string path) => System.Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
}

internal static partial class PackageLifecycleTests
{
    [Test]
    public static void Wad_layout_checks_root_executable_payload_and_refuses_mixed_roots()
    {
        foreach (var changed in new[] { "Domenia.exe", "wad/Domenia.dll", "leftover.dll", "package-manifest.json" })
        {
            using var fixture = new Fixture(); WadPackageFixture.Convert(fixture.Source);
            using (var valid = PackageIntegrity.Open(fixture.Source, true))
            { Check.Equal("wad/package-manifest.json", valid.ManifestRelativePath, "manifeste sous wad et chemins relatifs à l’exe"); }
            File.WriteAllText(Path.Combine(fixture.Source, changed), "unexpected bytes");
            Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(fixture.Source, true).Dispose(), "altération ou mélange refusé : " + changed);
        }
    }

    [Test]
    public static void Wad_first_install_and_same_layout_update_preserve_only_exe_and_wad_at_root()
    {
        foreach (var fresh in new[] { true, false })
        {
            using var fixture = new Fixture(fresh); WadPackageFixture.Convert(fixture.Source);
            if (!fresh) WadPackageFixture.Convert(fixture.Target);
            var delivery = fixture.Delivery(); var preview = delivery.PreviewUpdate(fixture.Target, None);
            delivery.Update(fixture.Target, preview.Confirmation, None);
            using var pack = PackageIntegrity.Open(fixture.Target, true);
            Check.Equal(preview.SourceIdentity, pack.ManifestHash, "nouveau pack entier vérifié");
            Check.True(Directory.GetFileSystemEntries(fixture.Target).Select(Path.GetFileName).Order().SequenceEqual(new[] { "Domenia.exe", "wad" }), "racine à deux entrées");
        }
    }

    [Test]
    public static void Wad_interrupted_update_resumes_or_restores_from_verified_backups()
    {
        foreach (var restore in new[] { false, true })
        foreach (var phase in new[] { "pending-written", "component-staged", "before-manifest", "manifest-replaced" })
        {
            using var fixture = new Fixture(); WadPackageFixture.Convert(fixture.Source); WadPackageFixture.Convert(fixture.Target);
            var reached = false;
            var delivery = fixture.Delivery(point => { if (point == phase && !reached) { reached = true; throw new IOException("wad interruption"); } });
            var plan = delivery.PreviewUpdate(fixture.Target, None);
            Check.Equal("wad interruption", Check.Throws<IOException>(() => delivery.Update(fixture.Target, plan.Confirmation, None), "interruption injectée").Message, "phase atteinte");
            Check.True(reached && File.Exists(Path.Combine(fixture.Target, "wad/.update.pending")), "marqueur durable sous wad");
            var recovery = fixture.Delivery(); var next = recovery.PreviewRecovery(fixture.Target, fixture.Transaction, restore, None);
            var result = recovery.Recover(fixture.Target, fixture.Transaction, restore, next.Confirmation, None);
            using var active = PackageIntegrity.Open(fixture.Target, true);
            Check.Equal(result.ActiveIdentity, active.ManifestHash, "reprise intégrale vérifiée");
            Check.Equal((restore ? "old" : "new") + ":Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "version demandée active");
        }
    }

    [Test]
    public static void Wad_uninstall_preserves_operator_configuration_and_releases_pending_marker()
    {
        using var fixture = new Fixture(); WadPackageFixture.Convert(fixture.Source); WadPackageFixture.Convert(fixture.Target);
        var config = Path.Combine(fixture.Target, "wad/Domenia.config.json"); File.WriteAllText(config, "private setting");
        var delivery = fixture.Delivery(); var plan = delivery.PreviewUninstall(fixture.Target, None);
        var result = delivery.Uninstall(fixture.Target, plan.Confirmation, None);
        Check.False(File.Exists(Path.Combine(fixture.Target, "Domenia.exe")), "exécutable conforme retiré");
        Check.Equal("private setting", File.ReadAllText(config), "configuration conservée");
        Check.True(result.Preserved.Contains("wad/.lifecycle.lock"), "verrou conservé au bon emplacement");
        Check.False(File.Exists(Path.Combine(fixture.Target, "wad/.update.pending")), "désinstallation terminée");
    }

    [Test]
    public static void Changing_layout_requires_new_folder_before_any_target_mutation()
    {
        foreach (var sourceWad in new[] { true, false })
        {
            using var fixture = new Fixture(); WadPackageFixture.Convert(sourceWad ? fixture.Source : fixture.Target);
            Check.Contains("dossier distinct", Check.Throws<InvalidDataException>(() => fixture.Delivery().PreviewUpdate(fixture.Target, None), "pas de mélange automatique").Message, "instruction utile");
            Check.False(Directory.Exists(fixture.Storage), "aucune transaction créée");
            Check.Equal("old:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "ancien exe conservé");
        }
    }
}
