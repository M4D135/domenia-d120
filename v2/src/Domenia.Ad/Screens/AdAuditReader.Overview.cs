using System.Collections.Immutable;
using System.DirectoryServices;
using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdAuditReader
{
    private const string Users = "(&(objectCategory=person)(objectClass=user))";
    private const string Active = "(!(userAccountControl:1.2.840.113556.1.4.803:=2))";
    private static string Flag(int flag) => "(userAccountControl:1.2.840.113556.1.4.803:=" + flag.ToString(CultureInfo.InvariantCulture) + ")";
    private static readonly string[] CheckAttributes = [.. IdentityAttributes, "userAccountControl", "lastLogonTimestamp", "pwdLastSet", "adminCount", "primaryGroupID", "msDS-User-Account-Control-Computed", "msDS-AllowedToDelegateTo", "servicePrincipalName"];
    private static DateTimeOffset? FileTime(long? value)
    {
        if (value is not > 0 || value == long.MaxValue) { return null; }
        try { return DateTimeOffset.FromFileTime(value.Value); } catch (ArgumentOutOfRangeException) { return null; }
    }
    private static AuditObjectRef Ref(AdEntry e) => new(e.DistinguishedName, e.String("name") ?? AdDirectoryMapper.LeafValue(e.DistinguishedName), Kind(e), e.String("sAMAccountName"),
        e.Int("userAccountControl") is { } uac ? !AdValues.IsDisabled(uac) : null, FileTime(e.Long("lastLogonTimestamp")), FileTime(e.Long("pwdLastSet")),
        e.Strings("msDS-AllowedToDelegateTo").Count > 0 ? string.Join(", ", e.Strings("msDS-AllowedToDelegateTo").Take(20)) : null, e.Int("adminCount") == 1);
    public async Task<DomainOverviewRead> DomainOverviewAsync(CancellationToken cancellationToken)
    {
        var started = source.Clock.GetTimestamp(); using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(90)); var token = stop.Token;
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, token).ConfigureAwait(false);
        var root = await access.RootDseAsync(token).ConfigureAwait(false); var sections = ImmutableArray.CreateBuilder<OverviewSectionRead>(); var checks = new Dictionary<string, SecurityCheckRead>(StringComparer.Ordinal);
        AdEntry? domain = null;
        async Task Capture(string id, Func<Task<SecurityCheckRead>> read)
        {
            if (checks.Values.Any(c => c.State == ReadState.Refused) || sections.Any(c => c.State == ReadState.Refused)) { checks[id] = new(id, ReadState.NotRead, "Compte suspendu après refus ; aucune autre authentification essayée.", [], -1, 0, null, null); return; }
            try { checks[id] = await read().ConfigureAwait(false); }
            catch (Exception ex) when (Recoverable(ex)) { checks[id] = new(id, State(ex), Message(ex), [], -1, 0, null, null); }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { checks[id] = new(id, ReadState.Unavailable, "Budget de 90 secondes atteint ; contrôle non conclu.", [], -1, 0, null, null); }
        }
        async Task<SecurityCheckRead> Search(string id, string filter, int limit = 60, string? baseDn = null)
        {
            var rows = await access.SearchAsync(Request(baseDn ?? root.DefaultNamingContext, filter, AdSearchScope.Subtree, CheckAttributes, limit + 1), token).ConfigureAwait(false);
            if (rows.Any(e => e.Guid("objectGUID") is null)) { throw Incomplete(); }
            return new(id, ReadState.Read, rows.Count > limit ? "Liste bornée ; le nombre est un minimum constaté, pas le total du domaine." : null, [.. rows.Take(limit).Select(Ref)], rows.Count, limit, null, null);
        }
        try
        {
            domain = await One(access, root.DefaultNamingContext, [.. PolicyAttributes, "fSMORoleOwner", "msDS-Behavior-Version", "whenCreated", "gPLink"], token).ConfigureAwait(false) ?? throw Incomplete();
            sections.Add(new("directory", "Annuaire", ReadState.Read, null, [new("Domaine", root.DefaultNamingContext), new("Contrôleur", root.DnsHostName), new("Forêt", root.RootDomainNamingContext), new("Niveau fonctionnel", domain.Int("msDS-Behavior-Version")?.ToString(CultureInfo.InvariantCulture) ?? "Non lu")]));
            sections.Add(new("policy", "Stratégie du domaine", ReadState.Read, null, [new("Longueur minimale", domain.String("minPwdLength") ?? "Non lue"), new("Historique", domain.String("pwdHistoryLength") ?? "Non lu"), new("Seuil de verrouillage", domain.String("lockoutThreshold") ?? "Non lu")]));
        }
        catch (Exception ex) when (Recoverable(ex)) { sections.Add(new("directory", "Annuaire", State(ex), Message(ex), [])); }
        await Capture("domainPasswordPolicy", () =>
        {
            if (domain?.Int("minPwdLength") is not { } length || domain.Int("lockoutThreshold") is not { } lockout || domain.Int("pwdProperties") is not { } properties) { throw Incomplete(); }
            var issues = (length < 12 ? 1 : 0) + (lockout == 0 ? 1 : 0) + ((properties & 1) == 0 ? 1 : 0);
            return Task.FromResult(new SecurityCheckRead("domainPasswordPolicy", ReadState.Read, null, [], issues, 3, issues, "Longueur " + length + ", seuil " + lockout + ", complexité " + ((properties & 1) != 0 ? "activée" : "désactivée")));
        });
        await Capture("machineAccountQuota", () => Task.FromResult(domain?.Int("ms-DS-MachineAccountQuota") is { } quota
            ? new SecurityCheckRead("machineAccountQuota", ReadState.Read, null, [], 0, 1, quota, null) : throw Incomplete()));
        var old = Now.AddDays(-90).ToFileTime().ToString(CultureInfo.InvariantCulture); var now = Now.ToFileTime().ToString(CultureInfo.InvariantCulture);
        var filters = new (string Id, string Filter, int Limit)[]
        {
            ("unconstrainedDelegation", "(&(|(objectClass=user)(objectClass=computer))" + Flag(524288) + "(!" + Flag(8192) + "))", 60),
            ("constrainedDelegation", "(&" + Users + "(msDS-AllowedToDelegateTo=*)" + Flag(16777216) + ")", 60),
            ("asrepRoast", "(&" + Users + Flag(4194304) + ")", 60),
            ("passwordNotRequired", "(&" + Users + Active + Flag(32) + ")", 60),
            ("reversibleEncryption", "(&" + Users + Active + Flag(128) + ")", 60),
            ("kerberoast", "(&" + Users + "(servicePrincipalName=*)(!(sAMAccountName=krbtgt)))", 60),
            ("passwordNeverExpires", "(&" + Users + Active + Flag(65536) + ")", 60),
            ("staleUsers", "(&" + Users + Active + "(lastLogonTimestamp>=1)(lastLogonTimestamp<=" + old + "))", 60),
            ("neverLoggedUsers", "(&" + Users + Active + "(|(!(lastLogonTimestamp=*))(lastLogonTimestamp=0)))", 60),
            ("staleComputers", "(&(objectClass=computer)" + Active + "(|(!(lastLogonTimestamp=*))(lastLogonTimestamp<=" + old + ")))", 60),
            ("lapsMissing", "(&(objectClass=computer)" + Active + "(!" + Flag(8192) + ")(!(msLAPS-PasswordExpirationTime=*))(!(ms-Mcs-AdmPwdExpirationTime=*)))", 60),
            ("lapsExpired", "(&(objectClass=computer)" + Active + "(|(&(msLAPS-PasswordExpirationTime>=1)(msLAPS-PasswordExpirationTime<=" + now + "))(&(ms-Mcs-AdmPwdExpirationTime>=1)(ms-Mcs-AdmPwdExpirationTime<=" + now + "))))", 60),
            ("disabledInGroups", "(&" + Users + Flag(2) + "(memberOf=*))", 60),
            ("disabledAccounts", "(&" + Users + Flag(2) + ")", 200),
            ("trusts", "(objectClass=trustedDomain)", 60),
        };
        foreach (var (id, filter, limit) in filters) { await Capture(id, () => Search(id, filter, limit, id == "trusts" ? "CN=System," + root.DefaultNamingContext : null)).ConfigureAwait(false); }
        if (checks.GetValueOrDefault("reversibleEncryption") is { State: ReadState.Read } reversible && domain?.Int("pwdProperties") is { } props && (props & 16) != 0)
        { checks["reversibleEncryption"] = reversible with { Total = reversible.Total + 1, Message = "Le chiffrement réversible est également activé dans la stratégie du domaine." }; }
        if (checks.TryGetValue("lapsMissing", out var laps) && laps.State == ReadState.Read) { checks["lapsMissing"] = laps with { Message = string.Join(" ", laps.Message, "Dates LAPS non retournées ; les droits de lecture peuvent en masquer l’existence. Aucun secret demandé.") }; }
        var local = await Local(cancellationToken).ConfigureAwait(false); var sid = local.Domain.DomainSid;
        await Capture("krbtgtPassword", async () =>
        {
            var rows = await access.SearchAsync(Request(root.DefaultNamingContext, "(&(objectClass=user)(objectSid=" + SearchText.LdapLiteral(sid + "-502") + "))", AdSearchScope.Subtree, CheckAttributes), token).ConfigureAwait(false);
            if (rows.Count != 1 || FileTime(rows[0].Long("pwdLastSet")) is not { } date) { throw Incomplete(); }
            return new("krbtgtPassword", ReadState.Read, null, [Ref(rows[0])], 1, 1, Math.Max(0, (long)(Now - date).TotalDays), null);
        }).ConfigureAwait(false);
        await Capture("builtinAdminActive", () => Search("builtinAdminActive", "(&" + Users + Active + "(objectSid=" + SearchText.LdapLiteral(sid + "-500") + ")(lastLogonTimestamp>=" + old + "))")).ConfigureAwait(false);
        await Capture("lockedAccounts", async () =>
        {
            var rows = await access.SearchAsync(Request(root.DefaultNamingContext, "(&" + Users + "(lockoutTime>=1))", AdSearchScope.Subtree, CheckAttributes, 201), token).ConfigureAwait(false);
            if (rows.Count > 200 || rows.Any(e => e.Int("msDS-User-Account-Control-Computed") is null)) { throw Incomplete(); }
            var locked = rows.Where(e => (e.Int("msDS-User-Account-Control-Computed") & 16) != 0).ToArray(); return new("lockedAccounts", ReadState.Read, null, [.. locked.Select(Ref)], locked.Length, 200, null, null);
        }).ConfigureAwait(false);
        await Capture("recycleBin", async () =>
        {
            var partitions = await One(access, "CN=Partitions," + root.ConfigurationNamingContext, ["msDS-EnabledFeature"], token, forest: true).ConfigureAwait(false) ?? throw Incomplete();
            var features = partitions.Strings("msDS-EnabledFeature"); if (!partitions.Has("msDS-EnabledFeature")) { throw Incomplete(); }
            var enabled = features.Any(dn => dn.StartsWith("CN=Recycle Bin Feature,", StringComparison.OrdinalIgnoreCase));
            return new("recycleBin", ReadState.Read, null, [], enabled ? 0 : 1, 1, enabled ? 1 : 0, null);
        }).ConfigureAwait(false);
        string? privileged = null;
        await Capture("privilegedMembers", async () =>
        {
            var sids = new[] { 512, 518, 519 }.Select(r => sid + "-" + r).Concat(new[] { "S-1-5-32-544", "S-1-5-32-548", "S-1-5-32-549", "S-1-5-32-550", "S-1-5-32-551" }).ToArray();
            var groups = await access.SearchAsync(Request(root.DefaultNamingContext, "(&(objectClass=group)(|" + string.Concat(sids.Select(s => "(objectSid=" + SearchText.LdapLiteral(s) + ")")) + "))", AdSearchScope.Subtree, IdentityAttributes, 10), token).ConfigureAwait(false);
            if (groups.Count is 0 or > 8) { throw Incomplete(); }
            privileged = "(|" + string.Concat(groups.Select(g => "(memberOf:1.2.840.113556.1.4.1941:=" + SearchText.LdapLiteral(g.DistinguishedName) + ")")) + "(primaryGroupID=512)(primaryGroupID=518)(primaryGroupID=519))";
            return await Search("privilegedMembers", "(&" + Users + privileged + ")", 200).ConfigureAwait(false);
        }).ConfigureAwait(false);
        await Capture("adminCountOrphans", () => privileged is null ? throw Incomplete() : Search("adminCountOrphans", "(&" + Users + "(adminCount=1)(!" + privileged + "))")).ConfigureAwait(false);
        await Capture("privilegedNotProtected", async () =>
        {
            if (privileged is null) { throw Incomplete(); }
            var protectedUsers = await access.SearchAsync(Request(root.DefaultNamingContext, "(&(objectClass=group)(objectSid=" + SearchText.LdapLiteral(sid + "-525") + "))", AdSearchScope.Subtree, IdentityAttributes), token).ConfigureAwait(false);
            if (protectedUsers.Count != 1) { throw Incomplete(); }
            return await Search("privilegedNotProtected", "(&" + Users + Active + privileged + "(!(sAMAccountName=krbtgt))(!(memberOf:1.2.840.113556.1.4.1941:=" + SearchText.LdapLiteral(protectedUsers[0].DistinguishedName) + ")))").ConfigureAwait(false);
        }).ConfigureAwait(false);
        await Capture("dcsyncRights", async () =>
        {
            var e = await One(access, root.DefaultNamingContext, ["nTSecurityDescriptor"], token, acl: true).ConfigureAwait(false) ?? throw Incomplete();
            if (e.Bytes("nTSecurityDescriptor") is not { Length: > 0 and <= 1048576 } bytes) { throw Incomplete(); }
            var security = new ActiveDirectorySecurity(); security.SetSecurityDescriptorBinaryForm(bytes, AccessControlSections.Access); var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)); if (rules.Count > 1000) { throw Incomplete(); }
            var getChanges = Guid.Parse("1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"); var getAll = Guid.Parse("1131f6ad-9c07-11d1-f79f-00c04fc2dcd2");
            var expected = new HashSet<string>(new[] { sid + "-512", sid + "-516", sid + "-518", sid + "-519", sid + "-521", "S-1-5-32-544", "S-1-5-9", "S-1-5-18" }, StringComparer.OrdinalIgnoreCase);
            var suspect = rules.OfType<ActiveDirectoryAccessRule>().Where(r => r.AccessControlType == AccessControlType.Allow && !expected.Contains(r.IdentityReference.Value))
                .GroupBy(r => r.IdentityReference.Value, StringComparer.OrdinalIgnoreCase).Where(g => g.Any(r => (r.ActiveDirectoryRights & ActiveDirectoryRights.GenericAll) == ActiveDirectoryRights.GenericAll)
                    || new[] { getChanges, getAll }.All(right => g.Any(r => (r.ActiveDirectoryRights & ActiveDirectoryRights.ExtendedRight) != 0 && (r.ObjectType == Guid.Empty || r.ObjectType == right)))).ToArray();
            var objects = suspect.Select(g => new AuditObjectRef(root.DefaultNamingContext, g.Key, AuditObjectKind.Other, null, null, null, null, "Droits présents dans la DACL ; droits effectifs non calculés (refus et jeton à examiner).", false)).ToImmutableArray();
            return new("dcsyncRights", ReadState.Read, "DACL de la racine seulement ; ni secret ni réplication de données demandés.", objects, objects.Length, 1000, null, null);
        }).ConfigureAwait(false);
        foreach (var definition in AuditFindings.Catalogue) { checks.TryAdd(definition.Id, new(definition.Id, ReadState.NotRead, "Contrôle non exécuté.", [], -1, 0, null, null)); }
        access.EnsureCurrent(); return new(Controller(access), Now, (long)source.Clock.GetElapsedTime(started).TotalMilliseconds, sections.ToImmutable(), [.. AuditFindings.Catalogue.Select(c => checks[c.Id])]);
    }
}
