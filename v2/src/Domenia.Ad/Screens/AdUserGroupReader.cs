using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One bounded, ephemeral view of a user's visible group paths. It never replaces the persistent directory index.</summary>
internal sealed class AdUserGroupReader(AdDirectorySource source, AdReadAccess access, DomainInfo domain)
{
    internal static readonly string[] UserAttributes = [.. AdDirectoryMapper.UserAttributes.Where(a => a != "memberOf"), "company", "memberOf;range=0-1999"];
    private static readonly string[] GroupAttributes = ["objectGUID", "objectSid", "objectClass", "distinguishedName", "name", "sAMAccountName", "groupType", "adminCount", "uSNChanged", "memberOf;range=0-1999"];
    internal sealed record Result(DirectoryUser User, string? Company, ImmutableArray<DirectoryGroup> Groups, ImmutableArray<string> Limits);
    private readonly List<string> limits = [];
    private int references;
    private long characters;

    internal async Task<Result> ReadAsync(string dn, Guid? expected, CancellationToken cancellationToken)
    {
        AdRelationDirectory.ValidateDn(dn, domain);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var rows = await access.SearchAsync(Query(dn, AdDirectoryMapper.UserFilter, AdSearchScope.Base, UserAttributes, 2), budget.Token).ConfigureAwait(false);
        if (rows.Count != 1 || !DistinguishedName.AreEqual(rows[0].DistinguishedName, dn) || AdRelationDirectory.Map(rows[0], domain) is not { Kind: RelationSubjectKind.User } identity
            || expected is { } guid && identity.Guid != guid)
        { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Compte absent, remplacé ou illisible ; aucune comparaison publiée."); }
        var original = rows[0];
        var normalized = await MembershipAsync(original, budget.Token, cancellationToken).ConfigureAwait(false);
        var primaryRid = original.Int("primaryGroupID");
        if (primaryRid is null or <= 0) { Limit("Attribut primaryGroupID non lu ; groupe principal inconnu."); }
        var user = AdDirectoryMapper.User(normalized)! with { DistinguishedName = Canonical(dn), PrimaryGroupId = primaryRid is > 0 ? primaryRid.Value : 0 };
        var queue = new Queue<(string Dn, int Depth)>(user.MemberOf.Select(p => (p, 1)));
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var groups = new Dictionary<string, DirectoryGroup>(StringComparer.OrdinalIgnoreCase);
        var identities = new Dictionary<Guid, string>();
        try
        {
            if (primaryRid is > 0)
            {
                var sid = domain.DomainSid + "-" + primaryRid.Value.ToString(CultureInfo.InvariantCulture);
                var primary = await access.SearchAsync(Query(domain.RootDn, "(&(objectCategory=group)(objectSid=" + SearchText.LdapLiteral(sid) + "))", AdSearchScope.Subtree,
                    ["objectGUID", "objectSid", "objectClass", "distinguishedName"], 2), budget.Token).ConfigureAwait(false);
                if (primary.Count == 1 && primary[0].Sid("objectSid") == sid && primary[0].Guid("objectGUID") is { } id && id != Guid.Empty
                    && primary[0].Strings("objectClass").Contains("group", StringComparer.OrdinalIgnoreCase) && InDomain(primary[0].DistinguishedName))
                { queue.Enqueue((Canonical(primary[0].DistinguishedName), 1)); }
                else { Limit("Groupe principal non résolu de façon unique."); }
            }
            while (queue.Count > 0 && groups.Count < UserGroupComparer.MaxGroups)
            {
                budget.Token.ThrowIfCancellationRequested();
                var pending = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase); var filterBytes = 0;
                while (queue.Count > 0 && pending.Count < Math.Min(40, UserGroupComparer.MaxGroups - groups.Count))
                {
                    var item = queue.Peek();
                    if (item.Depth > UserGroupComparer.MaxDepth) { queue.Dequeue(); Limit("Parcours limité à 16 niveaux de groupes."); continue; }
                    if (!InDomain(item.Dn)) { queue.Dequeue(); Limit("Des groupes référencés sont hors domaine ou portent un DN invalide ; ils ne sont pas interrogés."); continue; }
                    var name = Canonical(item.Dn);
                    if (visited.Contains(name)) { queue.Dequeue(); continue; }
                    var bytes = Encoding.UTF8.GetByteCount("(distinguishedName=" + SearchText.LdapLiteral(name) + ")");
                    if (bytes > 30_000) { queue.Dequeue(); Limit("Un DN de groupe dépasse la limite du filtre LDAP ; référence non interrogée."); continue; }
                    if (filterBytes + bytes > 30_000) { break; }
                    queue.Dequeue(); visited.Add(name); pending.Add(name, item.Depth); filterBytes += bytes;
                }
                if (pending.Count == 0) { continue; }
                var filter = "(&(objectCategory=group)(|" + string.Concat(pending.Keys.Select(name => "(distinguishedName=" + SearchText.LdapLiteral(name) + ")")) + "))";
                var found = await access.SearchAsync(Query(domain.RootDn, filter, AdSearchScope.Subtree, GroupAttributes, pending.Count + 1), budget.Token).ConfigureAwait(false);
                if (found.Count > pending.Count || found.Any(e => !InDomain(e.DistinguishedName) || !pending.ContainsKey(Canonical(e.DistinguishedName)))
                    || found.Select(e => Canonical(e.DistinguishedName)).Distinct(StringComparer.OrdinalIgnoreCase).Count() != found.Count)
                { throw AdAttributeRange.Incomplete(); }
                if (found.Count < pending.Count) { Limit("Certains groupes demandés n’ont pas été retournés avec ce compte de lecture."); }
                foreach (var entry in found)
                {
                    if (!entry.Strings("objectClass").Contains("group", StringComparer.OrdinalIgnoreCase) || entry.Int("groupType") is null
                        || entry.Guid("objectGUID") is not { } id || id == Guid.Empty || entry.Sid("objectSid") is not { } sid
                        || !sid.StartsWith(domain.DomainSid + "-", StringComparison.OrdinalIgnoreCase) && !sid.StartsWith("S-1-5-32-", StringComparison.OrdinalIgnoreCase))
                    { Limit("Un groupe retourné n’a pas une identité ou un type lisible ; il est écarté."); continue; }
                    var name = Canonical(entry.DistinguishedName);
                    if (identities.TryGetValue(id, out var previous) && !StringComparer.OrdinalIgnoreCase.Equals(name, previous)) { throw AdAttributeRange.Incomplete(); }
                    identities[id] = name;
                    var read = await MembershipAsync(entry, budget.Token, cancellationToken).ConfigureAwait(false);
                    var group = AdDirectoryMapper.Group(read)! with { DistinguishedName = name };
                    groups.Add(name, group);
                    foreach (var parent in group.MemberOf) { queue.Enqueue((parent, pending[name] + 1)); }
                }
            }
            if (queue.Count > 0) { Limit("Lecture limitée à 2 000 groupes par compte."); }
            // An account membership change during the traversal invalidates the result; do not mix two versions of it.
            if (original.Long("uSNChanged") is { } version)
            {
                var check = await access.SearchAsync(Query(dn, AdObjectAccess.GuidFilter(identity.Guid), AdSearchScope.Base, ["objectGUID", "uSNChanged"], 2), budget.Token).ConfigureAwait(false);
                if (check.Count != 1 || check[0].Guid("objectGUID") != identity.Guid || check[0].Long("uSNChanged") != version || !DistinguishedName.AreEqual(check[0].DistinguishedName, dn))
                { throw WriteErrors.Refusal(WriteErrors.Stale, "Le compte a changé pendant la lecture de ses groupes ; relancez la comparaison."); }
            }
            else { Limit("Version du compte non lisible ; stabilité des appartenances pendant le parcours non vérifiée."); }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested)
        { Limit("Délai de 10 secondes atteint pour ce compte ; seuls les groupes déjà lus sont comparés."); }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.Timeout)
        { Limit("Lecture LDAP interrompue par son délai ; les groupes non lus restent inconnus."); }
        access.EnsureCurrent();
        return new(user, original.String("company"), [.. groups.Values], [.. limits]);
    }

    private async Task<AdEntry> MembershipAsync(AdEntry original, CancellationToken budget, CancellationToken outer)
    {
        var members = new List<object>(); var start = 0; var entry = original;
        while (true)
        {
            var names = entry.AttributeNames.Where(n => n.Equals("memberOf", StringComparison.OrdinalIgnoreCase) || n.StartsWith("memberOf;", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (names.Length == 0) { if (start > 0) { Limit("Suite d’appartenances non retournée ; parcours partiel."); } break; }
            if (names.Length != 1) { throw AdAttributeRange.Incomplete(); }
            var name = names[0]; var values = entry.Strings(name); int? end = null; var exhausted = false;
            if (!name.Equals("memberOf", StringComparison.OrdinalIgnoreCase))
            {
                if (!AdAttributeRange.TryParse(name, out var range) || range!.Start != start) { throw AdAttributeRange.Incomplete(); }
                range.Validate(start, values.Count, start, 2001); end = range.End;
            }
            else if (start != 0) { throw AdAttributeRange.Incomplete(); }
            foreach (var value in values.Take(2000 - start))
            {
                if (value.Length is 0 or > 4096) { Limit("Référence de groupe illisible ; appartenance écartée."); continue; }
                try
                {
                    var canonical = Canonical(value);
                    if (references >= 10_000 || characters + canonical.Length > 4 * 1024 * 1024)
                    { Limit("Références de groupes bornées à 10 000 et quatre millions de caractères ; parcours partiel."); exhausted = true; break; }
                    members.Add(canonical); references++; characters += canonical.Length;
                }
                catch (FormatException) { Limit("Référence de groupe au DN invalide ; appartenance écartée."); }
            }
            if (values.Count > 2000 - start || start + values.Count >= 2000 && end is not null) { Limit("Attribut memberOf limité à 2 000 valeurs ; parcours partiel."); break; }
            if (end is null) { break; }
            if (exhausted || references >= 10_000 || characters >= 4 * 1024 * 1024) { break; }
            if (original.Guid("objectGUID") is not { } id || original.Long("uSNChanged") is not { } version)
            { Limit("Version de l’objet non lue ; aucune suite de plage mélangée aux valeurs déjà reçues."); break; }
            start = end.Value + 1;
            try
            {
                var next = await access.SearchAsync(Query(original.DistinguishedName, AdObjectAccess.GuidFilter(id), AdSearchScope.Base,
                    ["objectGUID", "uSNChanged", "memberOf;range=" + start.ToString(CultureInfo.InvariantCulture) + "-1999"], 2), budget).ConfigureAwait(false);
                if (next.Count != 1 || next[0].Guid("objectGUID") != id || next[0].Long("uSNChanged") != version || !DistinguishedName.AreEqual(next[0].DistinguishedName, original.DistinguishedName))
                { throw AdAttributeRange.Incomplete(); }
                entry = next[0];
            }
            catch (OperationCanceledException) when (!outer.IsCancellationRequested && budget.IsCancellationRequested) { Limit("Délai atteint pendant les plages memberOf ; valeurs reçues seulement."); break; }
            catch (DomeniaOperationException ex) when (ex.Code == AdErrors.Timeout) { Limit("Délai LDAP pendant les plages memberOf ; valeurs reçues seulement."); break; }
        }
        var attributes = original.AttributeNames.Where(n => !n.Equals("memberOf", StringComparison.OrdinalIgnoreCase) && !n.StartsWith("memberOf;", StringComparison.OrdinalIgnoreCase))
            .ToDictionary(n => n, original.Raw, StringComparer.OrdinalIgnoreCase);
        attributes["memberOf"] = members.Distinct().ToArray(); return new(original.DistinguishedName, attributes);
    }
    private static AdSearchRequest Query(string dn, string filter, AdSearchScope scope, IReadOnlyList<string> attributes, int limit) => new(dn, filter, scope, attributes)
    { PageSize = Math.Min(40, limit), SizeLimit = limit, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = false };
    private static string Canonical(string dn) => DistinguishedName.Format(DistinguishedName.Parse(dn));
    private bool InDomain(string dn) { try { return ScopeRules.Contains(new(domain.RootDn, "", true), dn); } catch (FormatException) { return false; } }
    private void Limit(string text) { if (!limits.Contains(text, StringComparer.Ordinal)) { limits.Add(text); } }
}
