namespace Domenia.App;

internal sealed partial class PackageIntegrity
{
    internal PackageSignatureVerdict VerifyPublisher(PackagePublisherPolicy policy, Func<FileStream, PackageNativeSignature>? verifier = null)
    {
        if (!Packaged) throw new InvalidDataException("Paquet non vérifié ; aucune confiance éditeur déduite.");
        var executable = held.SingleOrDefault(f => Path.GetFileName(f.Name).Equals("Domenia.exe", StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidDataException("Exécutable vérifié non détenu.");
        var verdict = PackagePublisherTrust.Verify(executable, policy, verifier);
        var expected = Components.Single(c => c.Path.Equals("Domenia.exe", StringComparison.OrdinalIgnoreCase));
        if (verdict.ExecutableSha256 != expected.Sha256.ToLowerInvariant()) throw new InvalidDataException("Exécutable différent de l’intégrité qualifiée.");
        return verdict;
    }
}
