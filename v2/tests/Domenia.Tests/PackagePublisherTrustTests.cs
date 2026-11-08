using Domenia.App;

namespace Domenia.Tests;

internal static class PackagePublisherTrustTests
{
    private static readonly string Certificate = new('A', 64);
    [Test]
    public static void Publisher_pins_are_closed_and_independent_of_package_json()
    {
        Check.Equal(Certificate, PackagePublisherPolicy.Pin(string.Join(':', Enumerable.Repeat("aa", 32))), "normalisation SHA-256 explicite");
        foreach (var invalid in new[] { new string('a', 40), "sha256:" + Certificate, new string('g', 64), "" })
            Check.Throws<InvalidDataException>(() => PackagePublisherPolicy.Pin(invalid), "aucune ancienne empreinte SHA1 ou valeur ambiguë admise");
        Check.Throws<InvalidDataException>(() => PackagePublisherPolicy.Parse([Certificate, Certificate.ToLowerInvariant()], false), "doublons refusés");
        Check.Throws<InvalidDataException>(() => PackagePublisherPolicy.Parse([], true), "aucune obligation sans identité définie");
        using var folder = new TemporaryFolder(); var file = folder.File("Domenia.exe"); File.WriteAllText(file, "octets détenus");
        File.WriteAllText(folder.File("package-release.json"), "{\"signature\":\"valid\",\"trusted\":true}");
        var unsigned = PackagePublisherTrust.Verify(file, PackagePublisherPolicy.Parse([Certificate], false), _ => new(PackagePublisherTrust.NoSignature, Certificate, "faux"));
        Check.Equal("unsigned", unsigned.Signature, "verdict du fournisseur natif uniquement"); Check.False(unsigned.Trusted || unsigned.Pinned || unsigned.WindowsAccepted, "JSON ou certificat déclaré ne donne aucune confiance");
        Check.Throws<InvalidDataException>(() => unsigned.RequireAllowed(PackagePublisherPolicy.Parse([Certificate], true)), "obligation machine appliquée");
    }
    [Test]
    public static void Windows_acceptance_and_explicit_machine_pin_are_distinct_and_use_the_held_executable()
    {
        using var folder = new TemporaryFolder(); var file = folder.File("Domenia.exe"); File.WriteAllText(file, "same object");
        PackageNativeSignature Verify(FileStream stream)
        {
            Check.Equal(file, stream.Name, "vrai fichier ouvert livré au fournisseur");
            Check.Throws<IOException>(() => File.Move(file, folder.File("replaced.exe")), "substitution interdite pendant vérification");
            Check.Throws<IOException>(() => File.WriteAllText(file, "changed"), "modification interdite pendant vérification");
            return new(0, Certificate, "Éditeur de test");
        }
        var local = PackagePublisherTrust.Verify(file, PackagePublisherPolicy.Unconfigured, Verify);
        Check.True(local.WindowsAccepted, "signature valide localement"); Check.False(local.Trusted, "sans pin, aucune confiance éditeur spécifique");
        var required = PackagePublisherPolicy.Parse([Certificate], true);
        var trusted = PackagePublisherTrust.Verify(file, required, Verify); trusted.RequireAllowed(required);
        Check.True(trusted.Trusted && trusted.Pinned, "Windows et pin tous deux requis");
        Check.Equal(local.ExecutableSha256, trusted.ExecutableSha256, "mêmes octets sous les deux politiques");
        Check.False(local.PolicyIdentity == trusted.PolicyIdentity, "confirmation liée à la politique effective");
        var rejected = PackagePublisherTrust.Verify(file, required, _ => new(unchecked((int)0x80096010), Certificate, "Même nom"));
        Check.False(rejected.Trusted, "mauvais hash ne devient pas fiable grâce au certificat connu");
        Check.Throws<InvalidDataException>(() => rejected.RequireAllowed(required), "signature défectueuse refuse l’admission");
        var strangeSuccess = PackagePublisherTrust.Verify(file, required, _ => new(1, Certificate, "Même nom"));
        Check.False(strangeSuccess.WindowsAccepted, "seul zéro est un succès WinVerifyTrust, pas SUCCEEDED(status)");
    }
    [Test]
    public static void Actual_Windows_provider_never_trusts_an_unsigned_executable_or_an_arbitrary_file()
    {
        var process = Environment.ProcessPath ?? throw new TestFailureException("Image de test absente");
        var real = PackagePublisherTrust.Verify(process, PackagePublisherPolicy.Unconfigured);
        Check.False(real.Trusted || real.Pinned, "aucune épingle inventée même si le lanceur Windows est signé");
        Check.True(real.Signature is "validLocal" or "unsigned" or "rejected", "verdict natif fermé");
        Check.True((PackagePublisherTrust.OfflineFlags & 0x1000) != 0 && (PackagePublisherTrust.OfflineFlags & 0x10) != 0, "cache seulement, aucune révocation réseau demandée");
        using var folder = new TemporaryFolder(); var file = folder.File("not-a-program.exe"); File.WriteAllText(file, "not PE");
        var invalid = PackagePublisherTrust.Verify(file, PackagePublisherPolicy.Parse([Certificate], false));
        Check.False(invalid.WindowsAccepted || invalid.Trusted, "aucune signature valide issue des octets arbitraires");
    }
}
