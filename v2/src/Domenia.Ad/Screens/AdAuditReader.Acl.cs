using System.Collections.Immutable;
using System.DirectoryServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdAuditReader
{
    public async Task<AclRead> DelegationsAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(30)); var token = stop.Token;
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, target.Dn, token).ConfigureAwait(false);
        try
        {
            var e = await Exact(access, target, ["nTSecurityDescriptor"], token, acl: true).ConfigureAwait(false);
            var bytes = e.Bytes("nTSecurityDescriptor"); if (bytes is null || bytes.Length is 0 or > 1048576) { throw Incomplete(); }
            var security = new ActiveDirectorySecurity(); security.SetSecurityDescriptorBinaryForm(bytes, AccessControlSections.Owner | AccessControlSections.Access);
            var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)); var aces = ImmutableArray.CreateBuilder<AceRead>();
            foreach (ActiveDirectoryAccessRule rule in rules)
            {
                if (aces.Count >= 1000) { break; }
                aces.Add(new(rule.IdentityReference.Value, rule.AccessControlType == AccessControlType.Allow, rule.ActiveDirectoryRights.ToString(),
                    rule.ObjectType == Guid.Empty ? null : rule.ObjectType, rule.InheritedObjectType == Guid.Empty ? null : rule.InheritedObjectType, rule.IsInherited, rule.InheritanceType.ToString()));
            }
            var owner = security.GetOwner(typeof(SecurityIdentifier))?.Value;
            var names = ImmutableDictionary.CreateBuilder<string, string>(StringComparer.OrdinalIgnoreCase); var guids = ImmutableDictionary.CreateBuilder<Guid, string>(); string? nameError = null;
            var root = await access.RootDseAsync(token).ConfigureAwait(false);
            var sids = aces.Select(a => a.Sid).Append(owner).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            var local = await Local(token).ConfigureAwait(false);
            foreach (var t in Targets(local).Where(t => t.Sid is not null)) { names.TryAdd(t.Sid!, t.Name); }
            foreach (var batch in sids.Where(s => !names.ContainsKey(s) && AuditText.IsDomainAccountSid(s) && s.StartsWith(local.Domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase)).Take(256).Chunk(32))
            {
                try
                {
                    var rows = await access.SearchAsync(Request(root.DefaultNamingContext, "(|" + string.Concat(batch.Select(s => "(objectSid=" + SearchText.LdapLiteral(s) + ")")) + ")", AdSearchScope.Subtree, ["objectSid", "name"], batch.Length + 1), token).ConfigureAwait(false);
                    foreach (var row in rows) { if (row.Sid("objectSid") is { } sid && batch.Contains(sid, StringComparer.OrdinalIgnoreCase)) { names[sid] = row.String("name") ?? sid; } }
                }
                catch (Exception ex) when (Recoverable(ex)) { nameError = Message(ex); if (State(ex) == ReadState.Refused) { break; } }
            }
            if (sids.Any(s => !names.ContainsKey(s))) { nameError = string.Join(" ", nameError, "Certains SID restent affichés sans résolution ; aucun domaine étranger interrogé."); }
            foreach (var batch in aces.SelectMany(a => new[] { a.ObjectType, a.InheritedObjectType }).OfType<Guid>().Distinct().Take(256).Chunk(32))
            {
                try
                {
                    var schemaFilter = "(|" + string.Concat(batch.Select(g => "(schemaIDGUID=" + BinaryFilter(g.ToByteArray()) + ")")) + ")";
                    var rows = await access.SearchForestAsync(Request(root.SchemaNamingContext, schemaFilter, AdSearchScope.Subtree, ["schemaIDGUID", "lDAPDisplayName", "name"], batch.Length + 1), token).ConfigureAwait(false);
                    foreach (var row in rows) { if (row.Guid("schemaIDGUID") is { } id && batch.Contains(id)) { guids[id] = row.String("lDAPDisplayName") ?? row.String("name") ?? id.ToString("D"); } }
                    var missing = batch.Where(g => !guids.ContainsKey(g)).ToArray();
                    if (missing.Length > 0)
                    {
                        rows = await access.SearchForestAsync(Request("CN=Extended-Rights," + root.ConfigurationNamingContext, "(|" + string.Concat(missing.Select(g => "(rightsGuid=" + g.ToString("D") + ")")) + ")", AdSearchScope.OneLevel, ["rightsGuid", "displayName", "name"], missing.Length + 1), token).ConfigureAwait(false);
                        foreach (var row in rows) { if (Guid.TryParse(row.String("rightsGuid"), out var id) && missing.Contains(id)) { guids[id] = row.String("displayName") ?? row.String("name") ?? id.ToString("D"); } }
                    }
                }
                catch (Exception ex) when (Recoverable(ex)) { nameError = string.Join(" ", nameError, "Noms des droits partiels : " + Message(ex)); break; }
            }
            access.EnsureCurrent(); return new(target.Dn, ReadState.Read, null, rules.Count, rules.Count > 1000, 1000, aces.ToImmutable(), owner, security.AreAccessRulesProtected, names.ToImmutable(), nameError, guids.ToImmutable(), Controller(access), Now);
        }
        catch (Exception ex) when (Recoverable(ex) || ex is ArgumentException)
        { return new(target.Dn, State(ex), Message(ex), -1, false, 1000, [], null, false, ImmutableDictionary<string, string>.Empty, null, ImmutableDictionary<Guid, string>.Empty, Controller(access), Now); }
    }
    private static string BinaryFilter(byte[] bytes) => string.Concat(bytes.Select(b => "\\" + b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture)));
}
