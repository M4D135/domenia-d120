using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Small, explicit LDAP identity reads for relation gestures, through the selected account lease.</summary>
internal static class AdRelationDirectory
{
    internal static readonly string[] Attributes = ["objectGUID", "objectSid", "objectClass", "distinguishedName", "name", "cn", "sAMAccountName", "userPrincipalName",
        "displayName", "userAccountControl", "whenCreated", "lastLogonTimestamp", "dNSHostName", "operatingSystem", "description", "title", "department"];
    internal sealed record Read(AdEntry Entry, RelationObject Object);
    internal static void ValidateDn(string dn, DomainInfo domain)
    { AdFicheObjects.ValidateDn(dn); AdFicheObjects.EnsureDomain(dn, domain.RootDn); }

    internal static RelationObject? Map(AdEntry entry, DomainInfo domain)
    {
        ValidateDn(entry.DistinguishedName, domain);
        var classes = entry.Strings("objectClass"); var computer = classes.Contains("computer", StringComparer.OrdinalIgnoreCase);
        if (!classes.Contains("user", StringComparer.OrdinalIgnoreCase) || classes.Any(c => c.Equals("msDS-ManagedServiceAccount", StringComparison.OrdinalIgnoreCase)
            || c.Equals("msDS-GroupManagedServiceAccount", StringComparison.OrdinalIgnoreCase))) { return null; }
        if (entry.Guid("objectGUID") is not { } id || id == Guid.Empty || entry.Int("userAccountControl") is not { } uac
            || entry.Time("whenCreated") is not { } created || created == DateTimeOffset.MinValue || string.IsNullOrWhiteSpace(entry.String("sAMAccountName"))
            || entry.Sid("objectSid") is not { } sid || !AccountsRules.IsDomainSid(sid) || !sid.StartsWith(domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase)) { return null; }
        var sam = entry.String("sAMAccountName")!;
        var name = computer ? WorkstationIdentity.ExpectedName(AdDirectoryMapper.Computer(entry)!) : entry.String("displayName") ?? entry.String("cn") ?? entry.String("name") ?? sam;
        if (string.IsNullOrWhiteSpace(name) || name.Length > 320 || sam.Length > 320) { return null; }
        return new(computer ? RelationSubjectKind.Computer : RelationSubjectKind.User, id, entry.DistinguishedName, name, sam,
            computer ? entry.String("operatingSystem") : entry.String("description"), !AdValues.IsDisabled(uac), AdValues.FromFileTime(entry.Long("lastLogonTimestamp")), created, sid, entry.String("userPrincipalName"));
    }

    internal static async Task<Read> ExactAsync(AdReadAccess access, DomainInfo domain, string dn, Guid? expected, bool full, CancellationToken token)
    {
        ValidateDn(dn, domain);
        IReadOnlyList<AdEntry> rows;
        try
        {
            rows = await access.SearchAsync(new(dn, "(objectClass=*)", AdSearchScope.Base,
                full ? Attributes.Concat(AdDirectoryMapper.UserAttributes).Concat(AdDirectoryMapper.ComputerAttributes).Distinct(StringComparer.OrdinalIgnoreCase).ToArray() : Attributes)
            { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = full, MaxRangeValues = 50_000 }, token).ConfigureAwait(false);
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NoSuchObject)
        { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Objet absent ou déplacé ; relancez la recherche."); }
        if (rows.Count != 1 || !DistinguishedName.AreEqual(rows[0].DistinguishedName, dn) || Map(rows[0], domain) is not { } value
            || expected is { } guid && value.Guid != guid)
        { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Identité absente, ambiguë, remplacée ou illisible ; aucune association préparée."); }
        return new(rows[0], value);
    }

    internal static async Task ValidateAssignmentsAsync(AdDirectorySource source, IEnumerable<RelationChangeItem> items, CancellationToken token)
    {
        var assignments = items.Where(i => i.RestoresEntry is null && i.After?.Kind == RelationKind.Assignment).Select(i => i.After!).ToArray();
        if (assignments.Length == 0) { return; }
        var domain = source.CurrentDirectory?.Domain ?? throw WriteErrors.Refusal(WriteErrors.Stale, "Domaine local indisponible.");
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(25), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, elapsed.Token);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
        foreach (var link in assignments)
        {
            if (link.UserGuid is null || link.ComputerGuid is null || link.UserDn is null || link.ComputerDn is null)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Identités de l’affectation incomplètes."); }
            var user = (await ExactAsync(access, domain, link.UserDn, link.UserGuid, false, budget.Token).ConfigureAwait(false)).Object;
            var computer = (await ExactAsync(access, domain, link.ComputerDn, link.ComputerGuid, false, budget.Token).ConfigureAwait(false)).Object;
            if (user.Kind != RelationSubjectKind.User || computer.Kind != RelationSubjectKind.Computer || user.Login != link.UserLogin || computer.Name != link.Computer)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Une identité de l’affectation a changé ; préparez de nouveau l’association."); }
        }
        access.EnsureCurrent();
    }
}
