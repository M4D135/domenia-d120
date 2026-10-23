using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded native audit reads; local entry points never contact the directory.</summary>
public sealed partial class AdAuditReader : IAuditReader
{
    private readonly AdDirectorySource source;
    private static readonly string[] IdentityAttributes = ["objectGUID", "objectSid", "objectClass", "name", "sAMAccountName", "dNSHostName", "primaryGroupID", "description"];
    public AdAuditReader(AdDirectorySource source) { ArgumentNullException.ThrowIfNull(source); this.source = source; }
    private DateTimeOffset Now => source.Clock.GetUtcNow();
    private static DomeniaOperationException Invalid(string text) => new(DomeniaErrors.ArgumentsInvalid, text);
    private static DomeniaOperationException Incomplete() => new(DomeniaErrors.SourceUnavailable, "Réponse d’audit incomplète ou identité différente ; aucune conclusion déduite.");
    private void Current(long epoch) { if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant l’audit."); } }
    private static ReadState State(Exception ex) => ex is DomeniaOperationException { Code: AdErrors.AccessDenied or AdErrors.Credentials } ? ReadState.Refused : ReadState.Unavailable;
    private static bool Recoverable(Exception ex) => ex is DomeniaOperationException { Code: not AccountAccess.EpochChanged } or System.IO.IOException or TimeoutException;
    private static string Message(Exception ex) => ex is DomeniaOperationException op ? op.Message : "Source indisponible ; aucune valeur supposée.";
    private static string Controller(AdReadAccess access) => access.Controller ?? "Contrôleur sélectionné";
    private async Task<DirectorySnapshot> Local(CancellationToken token) => (await source.ReadLocalAsync(token).ConfigureAwait(false)).Directory;
    private static IEnumerable<AuditTarget> Targets(DirectorySnapshot d) =>
        d.Users.Select(u => new AuditTarget(u.DistinguishedName, AuditObjectKind.User, u.DisplayName ?? u.Cn, u.SamAccountName, u.ObjectGuid, u.Sid, null, u.PrimaryGroupId, u.Description))
        .Concat(d.Computers.Select(c => new AuditTarget(c.DistinguishedName, AuditObjectKind.Computer, c.Name, c.SamAccountName, c.ObjectGuid, c.Sid, c.DnsHostName, c.PrimaryGroupId, c.Description)))
        .Concat(d.Groups.Select(g => new AuditTarget(g.DistinguishedName, AuditObjectKind.Group, g.Name, g.SamAccountName, g.ObjectGuid, g.Sid, null, null, g.Description)))
        .Concat(d.OrganizationalUnits.Select(o => new AuditTarget(o.DistinguishedName, AuditObjectKind.OrganizationalUnit, o.Name, null, o.ObjectGuid, null, null, null, o.Description)))
        .Append(new(d.Domain.RootDn, AuditObjectKind.Domain, d.Domain.DnsName, null, null, d.Domain.DomainSid, null, null, null));
    private static AuditObjectKind Kind(AdEntry e) => e.Strings("objectClass").Any(c => c.Equals("computer", StringComparison.OrdinalIgnoreCase)) ? AuditObjectKind.Computer
        : e.Strings("objectClass").Any(c => c.Equals("group", StringComparison.OrdinalIgnoreCase)) ? AuditObjectKind.Group
        : e.Strings("objectClass").Any(c => c.Equals("user", StringComparison.OrdinalIgnoreCase)) ? AuditObjectKind.User
        : e.Strings("objectClass").Any(c => c.Equals("organizationalUnit", StringComparison.OrdinalIgnoreCase)) ? AuditObjectKind.OrganizationalUnit
        : e.Strings("objectClass").Any(c => c.Equals("domainDNS", StringComparison.OrdinalIgnoreCase)) ? AuditObjectKind.Domain : AuditObjectKind.Other;
    private static AuditTarget Target(AdEntry e) => new(e.DistinguishedName, Kind(e), e.String("name") ?? AdDirectoryMapper.LeafValue(e.DistinguishedName), e.String("sAMAccountName"), e.Guid("objectGUID"), e.Sid("objectSid"), e.String("dNSHostName"), e.Int("primaryGroupID"), e.String("description"));
    private static AdSearchRequest Request(string dn, string filter, AdSearchScope scope, IEnumerable<string> attributes, int limit = 2, int seconds = 10) =>
        new(dn, filter, scope, attributes.Distinct(StringComparer.OrdinalIgnoreCase).ToArray())
        { PageSize = Math.Min(limit, 250), SizeLimit = limit, Timeout = TimeSpan.FromSeconds(Math.Min(seconds, 10)), Budget = TimeSpan.FromSeconds(seconds), MaxRangeValues = 2000 };
    private static async Task<AdEntry?> One(AdReadAccess access, string dn, IEnumerable<string> attrs, CancellationToken token, bool forest = false, bool acl = false)
    {
        var request = Request(dn, "(objectClass=*)", AdSearchScope.Base, IdentityAttributes.Concat(attrs)) with { ReadOwnerAndDacl = acl };
        try
        {
            var rows = forest ? await access.SearchForestAsync(request, token).ConfigureAwait(false) : await access.SearchAsync(request, token).ConfigureAwait(false);
            if (rows.Count > 1 || rows.Any(e => !DistinguishedName.AreEqual(e.DistinguishedName, dn) || e.Guid("objectGUID") is null)) { throw Incomplete(); }
            return rows.SingleOrDefault();
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NoSuchObject) { return null; }
    }
    private async Task<AdEntry> Exact(AdReadAccess access, AuditTarget target, IEnumerable<string> attrs, CancellationToken token, bool acl = false)
    {
        AdFicheObjects.ValidateDn(target.Dn);
        var entry = await One(access, target.Dn, attrs, token, acl: acl).ConfigureAwait(false) ?? throw Incomplete();
        if (target.ObjectGuid is { } id && entry.Guid("objectGUID") != id || target.Sid is { } sid && !string.Equals(entry.Sid("objectSid"), sid, StringComparison.OrdinalIgnoreCase)
            || Kind(entry) != target.Kind) { throw Incomplete(); }
        return entry;
    }
    public async Task<AuditTarget?> FindTargetAsync(string dn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(dn); var epoch = source.Epoch; var d = await Local(cancellationToken).ConfigureAwait(false); Current(epoch);
        AdFicheObjects.EnsureDomain(dn, d.Domain.RootDn);
        var found = Targets(d).Where(t => DistinguishedName.AreEqual(t.Dn, dn)).Take(2).ToArray(); return found.Length == 1 ? found[0] : null;
    }
    public async Task<ImmutableArray<AuditTarget>> SearchObjectsAsync(string text, int limit, CancellationToken cancellationToken)
    {
        if (text is null || text.Length > 500 || limit is < 1 or > 100) { throw Invalid("Recherche locale limitée à 100 objets et 500 caractères."); }
        var epoch = source.Epoch; var d = await Local(cancellationToken).ConfigureAwait(false); Current(epoch); var folded = FrenchText.Fold(text.Trim());
        return [.. Targets(d).Where(t => FrenchText.Fold(t.Name + " " + t.SamAccountName + " " + t.DnsHostName).Contains(folded, StringComparison.Ordinal)).OrderBy(t => t.Name, StringComparer.OrdinalIgnoreCase).Take(limit)];
    }
    public async Task<AuditTarget?> FindDomainGroupAsync(int rid, CancellationToken cancellationToken)
    {
        if (rid < 1) { throw Invalid("RID de groupe invalide."); } var d = await Local(cancellationToken).ConfigureAwait(false);
        return Targets(d).SingleOrDefault(t => t.Kind == AuditObjectKind.Group && t.Sid == d.Domain.DomainSid + "-" + rid.ToString(CultureInfo.InvariantCulture));
    }
    public async Task<LocalTotalsRead> LocalTotalsAsync(CancellationToken cancellationToken)
    {
        var d = await Local(cancellationToken).ConfigureAwait(false);
        return new(ReadState.Read, d.Complete ? null : "Copie locale partielle ; ces nombres ne sont pas les totaux du domaine.", d.ReadAt == DateTimeOffset.MinValue ? null : d.ReadAt, d.Complete, false,
            [new("Utilisateur", false, d.Users.Count(u => !AdValues.IsDisabled(u.UserAccountControl))), new("Utilisateur", true, d.Users.Count(u => AdValues.IsDisabled(u.UserAccountControl))),
             new("Ordinateur", false, d.Computers.Count(c => !AdValues.IsDisabled(c.UserAccountControl))), new("Ordinateur", true, d.Computers.Count(c => AdValues.IsDisabled(c.UserAccountControl))),
             new("Groupe", false, d.Groups.Length), new("OU", false, d.OrganizationalUnits.Length)]);
    }
    public async Task<IdentityScanRead> IdentityScanAsync(string baseDn, bool subtree, int limit, CancellationToken cancellationToken)
    {
        if (limit is < 1 or > 5000) { throw Invalid("Analyse limitée à 5 000 identités."); }
        var d = await Local(cancellationToken).ConfigureAwait(false); AdFicheObjects.ValidateDn(baseDn); AdFicheObjects.EnsureDomain(baseDn, d.Domain.RootDn);
        if (subtree && DistinguishedName.AreEqual(baseDn, d.Domain.RootDn)) { throw new DomeniaOperationException(AuditErrors.ScopeTooWide, AuditErrors.ScopeTooWideMessage); }
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, baseDn, cancellationToken).ConfigureAwait(false);
        var ou = await One(access, baseDn, [], cancellationToken).ConfigureAwait(false);
        if (ou is null || Kind(ou) is not (AuditObjectKind.OrganizationalUnit or AuditObjectKind.Domain)) { throw Invalid("Sélectionnez une OU du domaine."); }
        var rows = await access.SearchAsync(Request(baseDn, "(|(&(objectCategory=person)(objectClass=user))(objectClass=computer))", subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel,
            [.. IdentityAttributes, "userPrincipalName", "mail", "employeeID", "userAccountControl"], limit + 1, 30), cancellationToken).ConfigureAwait(false);
        if (rows.Any(e => e.Guid("objectGUID") is null || e.Int("userAccountControl") is null || Kind(e) is not (AuditObjectKind.User or AuditObjectKind.Computer) || !DistinguishedName.IsWithin(e.DistinguishedName, baseDn, subtree))) { throw Incomplete(); }
        if (rows.Select(e => e.Guid("objectGUID")).Distinct().Count() != rows.Count) { throw Incomplete(); }
        return new(baseDn, subtree, limit, [.. rows.Take(limit).Select(e => new IdentityScanObject(e.Guid("objectGUID")!.Value, e.DistinguishedName, e.String("name") ?? "", Kind(e), e.String("sAMAccountName"), e.String("userPrincipalName"), e.String("mail"), e.String("employeeID"), e.String("dNSHostName"), e.Int("userAccountControl")!.Value))], rows.Count > limit, Controller(access), Now);
    }
    public async Task<LocalNamesRead> LocalNamesAsync(IdentityScanRead scan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scan); var d = await Local(cancellationToken).ConfigureAwait(false); AdFicheObjects.EnsureDomain(scan.BaseDn, d.Domain.RootDn);
        var users = scan.Objects.Where(o => o.Kind == AuditObjectKind.User && o.SamAccountName is not null).Select(o => o.SamAccountName!).Distinct(StringComparer.OrdinalIgnoreCase).Take(1000).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var pcs = scan.Objects.Where(o => o.Kind == AuditObjectKind.Computer).Select(o => o.Name).Distinct(StringComparer.OrdinalIgnoreCase).Take(1000).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return new(ReadState.Read, "Noms de la copie locale seulement ; une absence ne prouve pas une suppression.", [.. d.Computers.Where(c => pcs.Contains(c.Name)).Select(c => new LocalNameRead(c.ObjectGuid, c.Name))],
            [.. d.Users.Where(u => users.Contains(u.SamAccountName)).Select(u => new LocalNameRead(u.ObjectGuid, u.SamAccountName))], users.Count + pcs.Count, scan.Objects.Length, false);
    }
}
