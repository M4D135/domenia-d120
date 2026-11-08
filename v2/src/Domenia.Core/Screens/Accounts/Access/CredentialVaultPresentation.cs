namespace Domenia.Core;

/// <summary>Names-only presentation decision. Password lookup still uses the exact recorded vault target, only after a click.</summary>
public sealed record CredentialVaultChoice(CredentialVaultTarget? Target, string Reason)
{
    public bool Available => Target is not null;
    public static CredentialVaultChoice Read(DomainIdentity? domain, string? login, ConnectionPreferences saved, bool available)
    {
        if (!available) return new(null, "Coffre Windows indisponible dans ce mode.");
        if (saved.VaultUser.Length == 0 || saved.VaultDomain.Length == 0) return new(null, "Aucun compte du coffre mémorisé. Vous pouvez enregistrer ce compte après validation.");
        if (domain?.DnsName is null || !SameDomain(domain, saved.VaultDomain)) return new(null, "Le compte mémorisé appartient à un autre domaine ou le domaine n’est pas confirmé.");
        var resolved = DirectoryLogin.Resolve(login ?? "", domain);
        if (resolved is null || !CredentialRules.IsWellFormed(saved.VaultUser)
            || !CredentialRules.CheckContext(CredentialRules.Directory, resolved, null, new[] { domain.DnsName, domain.NetbiosName }.OfType<string>().ToArray()).Valid
            || !CredentialRules.CheckContext(CredentialRules.Directory, saved.VaultUser, null, new[] { domain.DnsName, domain.NetbiosName }.OfType<string>().ToArray()).Valid
            || !CredentialRules.Parse(resolved).Name.Equals(CredentialRules.Parse(saved.VaultUser).Name, StringComparison.OrdinalIgnoreCase))
            return new(null, "Le coffre mémorisé correspond à un autre identifiant.");
        return new(new(saved.VaultDomain, CredentialRules.Directory, saved.VaultUser), "Même nom de compte dans ce domaine. Le coffre n’est lu qu’à votre demande ; son existence sera vérifiée à ce moment.");
    }
    private static bool SameDomain(DomainIdentity domain, string dn)
    {
        try
        {
            var parts = DistinguishedName.Parse(dn);
            return domain.RootDn is { Length: > 0 } root ? DistinguishedName.AreEqual(root, dn)
                : parts.Length > 0 && parts.All(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
                    && string.Join(".", parts.Select(p => p.Value)).Equals(domain.DnsName, StringComparison.OrdinalIgnoreCase);
        }
        catch (FormatException) { return false; }
    }
}
