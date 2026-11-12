using Domenia.App;

namespace Domenia.Tests;

internal static partial class PackageLifecycleTests
{
    [Test]
    public static void Update_keeps_the_default_configuration_written_in_place()
    {
        foreach (var wad in new[] { false, true })
        {
            using var fixture = new Fixture();
            if (wad) { WadPackageFixture.Convert(fixture.Source); WadPackageFixture.Convert(fixture.Target); }
            var relative = (wad ? "wad/" : "") + PackageIntegrity.DefaultsName;
            var seed = Path.Combine(fixture.Target, relative.Replace('/', Path.DirectorySeparatorChar));
            File.WriteAllText(seed, "configuration par défaut");
            using (var before = PackageIntegrity.Open(fixture.Target, true)) { Check.True(before.Packaged, "pack actif admis avec son fichier hors manifeste"); }
            var delivery = fixture.Delivery(); var plan = delivery.PreviewUpdate(fixture.Target, None);
            Check.True(plan.Preserved.Contains(relative) && !plan.Removed.Any(PackageIntegrity.IsDefaults), "annoncée conservée, jamais retirée");
            delivery.Update(fixture.Target, plan.Confirmation, None);
            using var pack = PackageIntegrity.Open(fixture.Target, true);
            Check.Equal("new:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "nouveau code entier");
            Check.Equal("configuration par défaut", File.ReadAllText(seed), "fichier conservé à l’octet");
        }
    }

    [Test]
    public static void Update_from_a_copy_listing_its_defaults_keeps_the_file_and_restore_returns_the_copy()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b', 2));
        var seed = Path.Combine(fixture.Target, PackageIntegrity.DefaultsName); File.WriteAllText(seed, "copie 2.1.5");
        Manifest(fixture.Target, Components.Append("package-release.json").Append(PackageIntegrity.DefaultsName));
        var delivery = fixture.Delivery(); var plan = delivery.PreviewUpdate(fixture.Target, None);
        Check.True(plan.Preserved.Contains(PackageIntegrity.DefaultsName) && !plan.Removed.Contains(PackageIntegrity.DefaultsName), "annoncée conservée, pas retirée avec l’ancien code");
        delivery.Update(fixture.Target, plan.Confirmation, None);
        using (var updated = PackageIntegrity.Open(fixture.Target, true))
        { Check.False(updated.Components.Any(c => PackageIntegrity.IsDefaults(c.Path)), "fichier hors du nouveau manifeste"); }
        Check.Equal("copie 2.1.5", File.ReadAllText(seed), "fichier laissé en place");
        var restore = delivery.PreviewRecovery(fixture.Target, fixture.Transaction, true, None);
        delivery.Recover(fixture.Target, fixture.Transaction, true, restore.Confirmation, None);
        using var restored = PackageIntegrity.Open(fixture.Target, true);
        Check.True(restored.Components.Any(c => c.Path == PackageIntegrity.DefaultsName), "copie d’origine restaurée avec son manifeste");
        Check.Equal("old:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "ancien code restauré");
        Check.Equal("copie 2.1.5", File.ReadAllText(seed), "fichier identique");
    }

    [Test]
    public static void An_incoming_pack_never_overwrites_a_default_configuration_written_in_place()
    {
        using var fixture = new Fixture();
        File.WriteAllText(Path.Combine(fixture.Target, PackageIntegrity.DefaultsName), "réglée sur place");
        File.WriteAllText(Path.Combine(fixture.Source, PackageIntegrity.DefaultsName), "copie préparée");
        Manifest(fixture.Source, Components.Append(PackageIntegrity.DefaultsName));
        Check.Throws<InvalidDataException>(() => fixture.Delivery().PreviewUpdate(fixture.Target, None), "conservation sans écrasement");
        Check.Equal("réglée sur place", File.ReadAllText(Path.Combine(fixture.Target, PackageIntegrity.DefaultsName)), "fichier intact");
    }
}
