using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One BASE tokenGroups query per authenticated identity, never per workstation. Group membership is an
/// application admission policy only: it grants neither AD writes nor rights on the remote machine.</summary>
internal static class AdAdministrationIdentity
{
    internal static async Task<AdministrationIdentity> ReadAsync(IAdConnection connection, DomainInfo domain, AdEntry identity, CancellationToken token)
        => (await ReadEvidenceAsync(connection, domain, identity, token).ConfigureAwait(false)).Identity;

    internal static async Task<(AdministrationIdentity Identity, MachineAdministrationPrincipal? Principal)> ReadEvidenceAsync(
        IAdConnection connection, DomainInfo domain, AdEntry identity, CancellationToken token)
    {
        try
        {
            var rows = await connection.SearchAsync(new(identity.DistinguishedName, "(objectClass=user)", AdSearchScope.Base,
                ["objectGUID", "objectSid", "tokenGroups", "primaryGroupID"])
            { SizeLimit = 2, PageSize = 1, MaxRangeValues = 4096, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, token).ConfigureAwait(false);
            if (rows.Count != 1 || !DistinguishedName.AreEqual(rows[0].DistinguishedName, identity.DistinguishedName)
                || rows[0].Guid("objectGUID") != identity.Guid("objectGUID") || rows[0].Sid("objectSid") != identity.Sid("objectSid"))
            { return (AdministrationIdentity.Unknown, null); }
            var entry = rows[0];
            var groups = Groups(domain.DomainSid, entry);
            var login = domain.NetbiosName + "\\" + identity.String("sAMAccountName");
            var principal = groups is null || entry.Sid("objectSid") is not { } sid ? null
                : new MachineAdministrationPrincipal(login, sid, [.. groups]);
            return (ClassifyGroups(domain.DomainSid, groups), principal?.IsBounded == true ? principal : null);
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.Timeout or AdErrors.Unavailable)
        { return (AdministrationIdentity.Unknown, null); }
        catch (ArgumentException) { return (AdministrationIdentity.Unknown, null); }
    }

    internal static AdministrationIdentity Classify(string domainSid, AdEntry entry)
        => ClassifyGroups(domainSid, Groups(domainSid, entry));

    private static HashSet<string>? Groups(string domainSid, AdEntry entry)
    {
        // Missing is not an empty, successfully read token. Never infer from an account name, process elevation,
        // successful WMI access, a foreign SID ending in 512, or SID history.
        if (!entry.AttributeNames.Contains("tokenGroups", StringComparer.OrdinalIgnoreCase)) { return null; }
        var groups = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in entry.Raw("tokenGroups"))
        {
            if (groups.Count >= 4096 || value is not byte[] bytes) { return null; }
            try { groups.Add(new SecurityIdentifier(bytes, 0).Value); }
            catch (ArgumentException) { return null; }
        }
        if (entry.Int("primaryGroupID") is > 0 and var rid)
        { groups.Add(domainSid + "-" + rid.ToString(System.Globalization.CultureInfo.InvariantCulture)); }
        return groups;
    }

    private static AdministrationIdentity ClassifyGroups(string domainSid, HashSet<string>? groups)
    {
        if (groups is null) return AdministrationIdentity.Unknown;
        // Enterprise administrators are accepted through their effective membership of this domain's
        // Administrators group, not by assuming this domain is the forest root or trusting any *-519 SID.
        return groups.Contains(domainSid + "-512") || groups.Contains("S-1-5-32-544")
            ? new(AdministrationIdentityState.Administrator, "Appartenance à un groupe d’administration du domaine confirmée. Les droits de chaque poste restent vérifiés à la lecture.")
            : new(AdministrationIdentityState.Standard, "Lecture de l’annuaire disponible. Pour les fonctions distantes, validez explicitement ce compte sur le poste s’il en est administrateur local, ou choisissez un autre compte. Domain Admins n’est pas requis pour une preuve limitée à ce poste.");
    }
}
