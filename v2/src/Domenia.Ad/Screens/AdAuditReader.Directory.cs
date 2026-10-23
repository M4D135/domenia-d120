using System.Collections.Immutable;
using System.Globalization;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdAuditReader
{
    private static readonly string[] PolicyAttributes = ["minPwdLength", "pwdHistoryLength", "maxPwdAge", "minPwdAge", "lockoutThreshold", "lockoutDuration", "lockOutObservationWindow", "pwdProperties", "ms-DS-MachineAccountQuota"];
    internal static AdInterval Interval(long? value) => value switch { null => AdInterval.Unread, 0 or long.MinValue => AdInterval.NeverExpires, < 0 => AdInterval.Of(TimeSpan.FromTicks(-value.Value)), _ => AdInterval.Unread };
    private static DomainPolicyRead Policy(AdEntry e) => new(e.Int("minPwdLength"), e.Int("pwdHistoryLength"), Interval(e.Long("maxPwdAge")), Interval(e.Long("minPwdAge")), e.Int("lockoutThreshold"), Interval(e.Long("lockoutDuration")), Interval(e.Long("lockOutObservationWindow")), e.Int("pwdProperties"), e.Int("ms-DS-MachineAccountQuota"));
    private static bool? Boolean(AdEntry e, string field) => bool.TryParse(e.String(field), out var value) ? value : null;
    public async Task<PasswordPolicyRead> PasswordPolicyAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        if (target.Kind != AuditObjectKind.User) { throw Invalid("La stratégie concerne un compte utilisateur."); }
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(20)); var token = stop.Token;
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, target.Dn, token).ConfigureAwait(false);
        var user = await Exact(access, target, ["userAccountControl", "msDS-User-Account-Control-Computed", "pwdLastSet", "msDS-UserPasswordExpiryTimeComputed", "msDS-ResultantPSO"], token).ConfigureAwait(false);
        var uac = user.Int("userAccountControl") ?? throw Incomplete(); var root = (await access.RootDseAsync(token).ConfigureAwait(false)).DefaultNamingContext;
        var domain = await One(access, root, PolicyAttributes, token).ConfigureAwait(false); PsoRead? pso = null; string? error = null; var resultant = user.String("msDS-ResultantPSO");
        if (resultant is not null)
        {
            try
            {
                var e = await One(access, resultant, ["msDS-PasswordSettingsPrecedence", "msDS-MinimumPasswordLength", "msDS-PasswordHistoryLength", "msDS-PasswordComplexityEnabled", "msDS-PasswordReversibleEncryptionEnabled", "msDS-MaximumPasswordAge", "msDS-MinimumPasswordAge", "msDS-LockoutThreshold", "msDS-LockoutDuration", "msDS-LockoutObservationWindow", "msDS-PSOAppliesTo"], token).ConfigureAwait(false);
                if (e is null || !e.Strings("objectClass").Contains("msDS-PasswordSettings", StringComparer.OrdinalIgnoreCase)) { throw Incomplete(); }
                pso = new(e.DistinguishedName, e.String("name") ?? "Stratégie fine", e.Int("msDS-PasswordSettingsPrecedence"), e.Int("msDS-MinimumPasswordLength"), e.Int("msDS-PasswordHistoryLength"), Boolean(e, "msDS-PasswordComplexityEnabled"), Boolean(e, "msDS-PasswordReversibleEncryptionEnabled"), Interval(e.Long("msDS-MaximumPasswordAge")), Interval(e.Long("msDS-MinimumPasswordAge")), e.Int("msDS-LockoutThreshold"), Interval(e.Long("msDS-LockoutDuration")), Interval(e.Long("msDS-LockoutObservationWindow")), e.Strings("msDS-PSOAppliesTo").Count);
            }
            catch (Exception ex) when (Recoverable(ex)) { error = Message(ex); }
        }
        var visible = -1;
        try { visible = (await access.SearchAsync(Request("CN=Password Settings Container,CN=System," + root, "(objectClass=msDS-PasswordSettings)", AdSearchScope.OneLevel, ["objectGUID"], 201), token).ConfigureAwait(false)).Count; if (visible > 200) { visible = -1; } }
        catch (Exception ex) when (Recoverable(ex)) { error = string.Join(" ", error, "Nombre de stratégies fines non déterminé : " + Message(ex)); }
        access.EnsureCurrent(); return new(target.Dn, Controller(access), Now, uac, user.Int("msDS-User-Account-Control-Computed"), user.Long("pwdLastSet"), user.Long("msDS-UserPasswordExpiryTimeComputed"), resultant, error, pso, domain is null ? null : Policy(domain), visible);
    }

    public async Task<GroupGraphRead> NestedGroupsAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        var start = source.Clock.GetTimestamp(); using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(10)); var token = stop.Token;
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, target.Dn, token).ConfigureAwait(false);
        var first = await Exact(access, target, ["memberOf", "primaryGroupID"], token).ConfigureAwait(false);
        var parents = first.Strings("memberOf").ToImmutableArray(); var queue = new Queue<(string Dn, int Level)>(parents.Select(dn => (dn, 1)));
        var nodes = ImmutableArray.CreateBuilder<GroupNodeRead>(); var unread = ImmutableArray.CreateBuilder<UnreadGroupRead>(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var truncated = false; string? reason = null; PrimaryGroupRead? primary = null;
        while (queue.TryDequeue(out var next))
        {
            if (!seen.Add(DistinguishedName.Format(DistinguishedName.Parse(next.Dn)))) { continue; }
            if (nodes.Count >= 2000 || next.Level > 16) { truncated = true; reason = "Limite de 2 000 groupes ou 16 niveaux atteinte."; break; }
            try
            {
                var e = await One(access, next.Dn, ["memberOf", "adminCount"], token).ConfigureAwait(false);
                if (e is null || Kind(e) != AuditObjectKind.Group) { throw Incomplete(); }
                var above = e.Strings("memberOf").ToImmutableArray(); nodes.Add(new(e.DistinguishedName, e.String("name") ?? "Groupe", e.Sid("objectSid"), e.Int("adminCount"), above, false));
                foreach (var dn in above) { queue.Enqueue((dn, next.Level + 1)); }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { truncated = true; reason = "Budget de dix secondes atteint."; break; }
            catch (Exception ex) when (Recoverable(ex)) { unread.Add(new(next.Dn, Message(ex))); if (State(ex) == ReadState.Refused) { truncated = true; reason = "Compte suspendu après refus ; autres groupes non contactés."; break; } }
        }
        if (!truncated && first.Sid("objectSid") is { } sid && first.Int("primaryGroupID") is { } rid)
        {
            var primarySid = sid[..sid.LastIndexOf('-')] + "-" + rid.ToString(CultureInfo.InvariantCulture);
            var root = (await access.RootDseAsync(token).ConfigureAwait(false)).DefaultNamingContext;
            var found = await access.SearchAsync(Request(root, "(&(objectClass=group)(objectSid=" + SearchText.LdapLiteral(primarySid) + "))", AdSearchScope.Subtree, IdentityAttributes), token).ConfigureAwait(false);
            primary = found.Count == 1 ? new(found[0].DistinguishedName, found[0].String("name"), primarySid) : new(null, null, primarySid);
        }
        access.EnsureCurrent(); return new(target.Dn, Controller(access), Now, (long)source.Clock.GetElapsedTime(start).TotalMilliseconds, parents, true, null, nodes.ToImmutable(), unread.ToImmutable(), primary, truncated, reason);
    }
    public async Task<MembershipRead> MembershipAsync(AuditTarget target, string groupDn, CancellationToken cancellationToken)
    {
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, target.Dn, cancellationToken).ConfigureAwait(false);
        try
        {
            var current = await Exact(access, target, [], cancellationToken).ConfigureAwait(false);
            var group = await One(access, groupDn, [], cancellationToken).ConfigureAwait(false); if (group is null || Kind(group) != AuditObjectKind.Group) { throw Incomplete(); }
            var rows = await access.SearchAsync(Request(target.Dn, "(memberOf:1.2.840.113556.1.4.1941:=" + SearchText.LdapLiteral(groupDn) + ")", AdSearchScope.Base, IdentityAttributes), cancellationToken).ConfigureAwait(false);
            if (rows.Count > 1 || rows.Any(e => e.Guid("objectGUID") != current.Guid("objectGUID") || !DistinguishedName.AreEqual(e.DistinguishedName, target.Dn))) { throw Incomplete(); }
            return new(target.Dn, groupDn, rows.Count == 1, null, Controller(access), Now);
        }
        catch (Exception ex) when (Recoverable(ex)) { return new(target.Dn, groupDn, null, Message(ex), Controller(access), Now); }
    }
    public async Task<TokenGroupsRead> TokenGroupsAsync(string sid, CancellationToken cancellationToken)
    {
        if (!AuditText.IsDomainAccountSid(sid)) { throw Invalid("Un SID de compte du domaine est requis."); }
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, cancellationToken).ConfigureAwait(false);
        try
        {
            var d = await Local(cancellationToken).ConfigureAwait(false); if (!sid.StartsWith(d.Domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase)) { throw Invalid("Le bénéficiaire appartient à un autre domaine."); }
            var rows = await access.SearchAsync(Request(d.Domain.RootDn, "(objectSid=" + SearchText.LdapLiteral(sid) + ")", AdSearchScope.Subtree, IdentityAttributes), cancellationToken).ConfigureAwait(false);
            if (rows.Count != 1 || rows[0].Sid("objectSid") != sid) { throw Incomplete(); }
            var e = await Exact(access, Target(rows[0]), ["tokenGroups"], cancellationToken).ConfigureAwait(false);
            if (!e.Has("tokenGroups")) { return new(sid, e.String("name"), ReadState.NotRead, "Attribut tokenGroups non retourné ; absence de groupes non démontrée.", [], Controller(access), Now); }
            var groups = e.Raw("tokenGroups").Select(v => v is byte[] bytes ? new SecurityIdentifier(bytes, 0).Value : throw Incomplete()).Distinct(StringComparer.OrdinalIgnoreCase).ToImmutableArray();
            return new(sid, e.String("name"), ReadState.Read, null, groups, Controller(access), Now);
        }
        catch (Exception ex) when (Recoverable(ex) || ex is ArgumentException) { return new(sid, null, State(ex), Message(ex), [], Controller(access), Now); }
    }
    public async Task<GpoLinksRead> GpoLinksAsync(IReadOnlyList<string> containers, CancellationToken cancellationToken)
    {
        if (containers.Count is < 1 or > 64) { throw Invalid("Chaîne GPO limitée à 64 conteneurs."); }
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(30)); var token = stop.Token;
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, containers[0], token).ConfigureAwait(false);
        var reads = ImmutableArray.CreateBuilder<GpoContainerRead>(); var names = ImmutableArray.CreateBuilder<GpoRead>(); var dns = new HashSet<string>(StringComparer.OrdinalIgnoreCase); string? error = null; var state = ReadState.Read;
        foreach (var dn in containers)
        {
            try
            {
                var e = await One(access, dn, ["gPLink", "gPOptions"], token).ConfigureAwait(false); if (e is null || Kind(e) is not (AuditObjectKind.OrganizationalUnit or AuditObjectKind.Domain) || e.Int("gPOptions") is not (0 or 1)) { throw Incomplete(); }
                var links = e.String("gPLink"); if (links?.Length > 65536) { throw Incomplete(); }
                reads.Add(new(dn, links, e.Int("gPOptions")!.Value, ReadState.Read, null));
                foreach (var link in AuditGpoRules.ParseGpLink(links, dn)) { if (dns.Count >= 256) { state = ReadState.Unavailable; error = "Limite de 256 GPO atteinte."; break; } dns.Add(link.GpoDn); }
            }
            catch (Exception ex) when (Recoverable(ex)) { reads.Add(new(dn, null, 0, State(ex), Message(ex))); state = State(ex); error = Message(ex); if (state == ReadState.Refused) { break; } }
        }
        if (state != ReadState.Refused)
        {
            foreach (var dn in dns)
            {
                try
                {
                    var e = await One(access, dn, ["displayName", "flags", "whenChanged"], token).ConfigureAwait(false);
                    if (e is null || !e.Strings("objectClass").Contains("groupPolicyContainer", StringComparer.OrdinalIgnoreCase) || !Guid.TryParse(e.String("name"), out var id)) { throw Incomplete(); }
                    names.Add(new(id, e.String("displayName") ?? e.String("name")!, e.Int("flags"), e.Time("whenChanged")));
                }
                catch (Exception ex) when (Recoverable(ex)) { state = State(ex); error = Message(ex); if (state == ReadState.Refused) { break; } }
            }
        }
        access.EnsureCurrent(); return new(reads.ToImmutable(), names.ToImmutable(), state, error, Controller(access), Now);
    }
}
