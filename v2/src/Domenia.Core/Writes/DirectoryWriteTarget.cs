namespace Domenia.Core;

/// <summary>Domain object writes never address rootDSE, schema/configuration or application DNS partitions.</summary>
public static class DirectoryWriteTarget
{
    public static void Require(string dn, string rootDn, bool allowDomainRoot = false)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(dn) || dn.Length > 4096 || dn.Any(char.IsControl)
                || string.IsNullOrWhiteSpace(rootDn)) throw new FormatException();
            var parts = DistinguishedName.Parse(dn); var root = DistinguishedName.Parse(rootDn);
            if (root.Length == 0 || root.Any(r => !r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
                || parts.Length < root.Length || !FicheValues.SameDn(string.Join(',', parts.Skip(parts.Length - root.Length)
                    .Select(r => DistinguishedName.Rdn(r.Type, r.Value))), rootDn)
                || !allowDomainRoot && parts.Length == root.Length) throw new FormatException();
            // Compare decoded complete RDNs, never substrings (escaped commas and harmless CN names stay valid).
            var below = parts.Take(parts.Length - root.Length).ToArray();
            if (below.Any(r => r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
                || below.Length > 0 && below[^1].Type.Equals("CN", StringComparison.OrdinalIgnoreCase)
                    && (below[^1].Value.Equals("Configuration", StringComparison.OrdinalIgnoreCase)
                        || below[^1].Value.Equals("Schema", StringComparison.OrdinalIgnoreCase))) throw new FormatException();
        }
        catch (FormatException)
        { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "DN hors de la partition d’objets du domaine ; aucune écriture préparée ni envoyée."); }
    }
}
