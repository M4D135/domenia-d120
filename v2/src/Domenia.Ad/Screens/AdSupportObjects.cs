using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded, selected-account reads shared by the shell picker and Assistance.</summary>
internal static class AdSupportObjects
{
    internal static async Task<DirectorySnapshot> ReadAsync(AdDirectorySource source, string? dn, Guid? guid, CancellationToken token)
    {
        if (dn is null && (guid is null || guid == Guid.Empty)) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Identité d’objet absente."); }
        var local = await source.ReadLocalAsync(token).ConfigureAwait(false);
        var root = local.Directory.Domain.RootDn;
        if (dn is not null) { AdFicheObjects.ValidateDn(dn); AdFicheObjects.EnsureDomain(dn, root); }
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, dn ?? root, stop.Token).ConfigureAwait(false);
        var rows = await access.SearchAsync(new(dn ?? root, guid is { } id ? AdObjectAccess.GuidFilter(id) : "(objectClass=*)",
            dn is null ? AdSearchScope.Subtree : AdSearchScope.Base, [.. AdObjectAccess.Attributes, "objectClass"])
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = true, MaxRangeValues = 50_000 }, stop.Token).ConfigureAwait(false);
        if (rows.Count > 1 || rows.Any(row => guid is { } wanted && row.Guid("objectGUID") != wanted
            || dn is not null && !DistinguishedName.AreEqual(row.DistinguishedName, dn)))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Réponse d’identité LDAP ambiguë ; aucun objet retenu."); }
        if (rows.Any(row => row.Strings("objectClass").Contains("user", StringComparer.OrdinalIgnoreCase)
            && (row.Int("userAccountControl") is null || row.Time("whenCreated") is not { } created || created > source.Clock.GetUtcNow())))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "État du compte ou date de création non lisible ; aucune fiche active supposée."); }
        access.EnsureCurrent();
        return AdObjectAccess.Project(rows, local.Directory.Domain, source.Clock.GetUtcNow());
    }

    internal static bool Denied(DomeniaOperationException exception) => exception.Code is AdErrors.AccessDenied or AdErrors.Credentials
        or AccountAccess.ContextRefused;

    internal static string Container(string dn) => string.Join(FrenchText.PathSeparator,
        DistinguishedName.Parse(dn).Skip(1).Where(p => !p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value).Reverse());
}
