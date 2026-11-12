using Domenia.App;

namespace Domenia.Tests;

internal static partial class PackageIntegrityTests
{
    [Test]
    public static void Default_configuration_is_admitted_outside_the_manifest_only_at_its_place()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        File.WriteAllText(folder.File(PackageIntegrity.DefaultsName), "{}");
        using (var pack = PackageIntegrity.Open(folder.Path, true))
        {
            File.WriteAllText(folder.File(PackageIntegrity.DefaultsName), "{\"remplacée\":true}");
            Check.True(pack.Packaged && !pack.Components.Any(c => PackageIntegrity.IsDefaults(c.Path)), "admis hors manifeste et remplaçable pendant l’exécution");
        }
        File.Delete(folder.File(PackageIntegrity.DefaultsName));
        Directory.CreateDirectory(folder.File("wad")); File.WriteAllText(Path.Combine(folder.File("wad"), PackageIntegrity.DefaultsName), "{}");
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "emplacement d’une autre disposition refusé");
        Directory.Delete(folder.File("wad"), true);
        var leftover = PackageIntegrity.DefaultsName + ".domenia-" + new string('a', 32) + ".part";
        File.WriteAllText(folder.File(leftover), "partiel");
        Check.Contains("Écriture interrompue", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "temporaire jamais admis").Message,
            "consigne précise");
    }
}
