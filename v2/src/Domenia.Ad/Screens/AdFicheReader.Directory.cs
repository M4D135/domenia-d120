using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdFicheReader
{
    private static readonly string[] SummaryAttributes = ["objectGUID", "objectClass", "name", "sAMAccountName", "displayName", "userPrincipalName", "description", "mail", "objectSid", "groupType", "adminCount", "userAccountControl", "uSNChanged"];

    public async Task<FicheChildren> ChildrenAsync(string dn, int limit, CancellationToken cancellationToken)
    {
        if (limit is < 1 or > 2000) { throw FicheErrors.Error(FicheErrors.Invalid, "Lecture limitée à 2 000 enfants directs."); }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var parent = await objects.ReadExactAsync(dn, ["objectClass"], TimeSpan.FromSeconds(10), budget.Token).ConfigureAwait(false)
            ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        if (AdFicheObjects.Project(parent).Kind is not (FicheKind.Ou or FicheKind.Container)) { return new(dn, [], true, null); }
        var epoch = source.Epoch;
        var entries = await source.Connection.SearchAsync(new(dn, "(objectClass=*)", AdSearchScope.OneLevel, SummaryAttributes)
        { PageSize = 500, SizeLimit = limit + 1, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(15), SortAttribute = "name" }, budget.Token).ConfigureAwait(false);
        ValidateChildren(entries, dn, limit + 1);
        var kept = entries.Take(limit).ToArray();
        RememberSummaries(kept, epoch);
        return new(dn, [.. kept.Select(e => e.DistinguishedName)], entries.Count <= limit,
            entries.Count > limit ? $"{FrenchText.Integer(limit)} premiers objets lus ; la branche en contient davantage." : null);
    }

    private static void ValidateChildren(IReadOnlyList<AdEntry> entries, string dn, int limit)
    {
        if (entries.Count > limit || entries.Any(e => !ScopeRules.Contains(new(dn, "", false), e.DistinguishedName) || e.Guid("objectGUID") is not { } id || id == Guid.Empty)
            || entries.Select(e => e.Guid("objectGUID")).Distinct().Count() != entries.Count) { throw AdAttributeRange.Incomplete(); }
    }

    public async Task<ImmutableArray<FicheDestination>> DestinationsAsync(string? parentDn, CancellationToken cancellationToken)
    {
        if (parentDn is not null) { AdFicheObjects.ValidateDn(parentDn); }
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var dn = parentDn ?? domain.RootDn;
        AdFicheObjects.EnsureDomain(dn, domain.RootDn);
        var epoch = source.Epoch;
        var entries = await source.Connection.SearchAsync(new(dn, "(|(objectClass=organizationalUnit)(objectClass=container))", AdSearchScope.OneLevel, [.. SummaryAttributes, "hasSubordinates"])
        { PageSize = 500, SizeLimit = 2001, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(15), SortAttribute = "name" }, cancellationToken).ConfigureAwait(false);
        ValidateChildren(entries, dn, 2001);
        if (entries.Count > 2000) { throw FicheErrors.Error(FicheErrors.Invalid, "Plus de 2 000 destinations dans cette branche : précisez une branche plus petite."); }
        RememberSummaries(entries, epoch);
        return [.. entries.Where(e => !FicheValues.SameDn(e.DistinguishedName, "CN=Builtin," + domain.RootDn))
            .Select(e => new FicheDestination(e.DistinguishedName, e.String("name") ?? FicheValues.DisplayName(e.DistinguishedName),
                e.Strings("objectClass").Contains("organizationalUnit", StringComparer.OrdinalIgnoreCase) ? "ou" : "container",
                FicheValues.ReadablePath(e.DistinguishedName, includeSelf: true), !string.Equals(e.String("hasSubordinates"), "FALSE", StringComparison.OrdinalIgnoreCase), null))
            .OrderBy(d => d.Kind == "ou" ? 0 : 1).ThenBy(d => FrenchText.Fold(d.Name), StringComparer.Ordinal)];
    }

    private async Task<(AdEntry Object, ImmutableArray<string> Values, bool Complete)> RangeAsync(string dn, string attribute, int cap, CancellationToken token)
    {
        AdFicheObjects.ValidateDn(dn);
        var domain = await source.DomainAsync(token).ConfigureAwait(false);
        AdFicheObjects.EnsureDomain(dn, domain.RootDn);
        var epoch = source.Epoch;
        var values = ImmutableArray.CreateBuilder<string>();
        AdEntry? first = null;
        var complete = false;
        while (values.Count < cap)
        {
            var start = values.Count;
            var end = Math.Min(cap - 1, start + 1499);
            var rows = await source.Connection.SearchAsync(new(dn, "(objectClass=*)", AdSearchScope.Base,
                [.. SummaryAttributes, "primaryGroupID", attribute + ";range=" + start.ToString(CultureInfo.InvariantCulture) + "-" + end.ToString(CultureInfo.InvariantCulture)])
            { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10), ExpandRanges = false }, token).ConfigureAwait(false);
            EnsureEpoch(epoch);
            if (rows.Count == 0) { throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage); }
            if (rows.Count != 1 || !FicheValues.SameDn(rows[0].DistinguishedName, dn) || rows[0].Guid("objectGUID") is not { } id || id == Guid.Empty) { throw AdAttributeRange.Incomplete(); }
            var entry = rows[0];
            if (first is not null) { AdFicheObjects.SameVersion(first, entry); }
            first ??= entry;
            var names = entry.AttributeNames.Where(n => n.Equals(attribute, StringComparison.OrdinalIgnoreCase)
                || n.StartsWith(attribute + ";", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (names.Length == 0 && start == 0) { complete = true; break; }
            if (names.Length != 1) { throw AdAttributeRange.Incomplete(); }
            var slice = entry.Strings(names[0]);
            var ranged = AdAttributeRange.TryParse(names[0], out var range);
            if (slice.Count > cap - start || ranged && (range!.Start != start || range.End is { } last && (last - start + 1 != slice.Count || slice.Count == 0))
                || !ranged && start != 0) { throw AdAttributeRange.Incomplete(); }
            foreach (var member in slice) { AdFicheObjects.ValidateDn(member); values.Add(member); }
            complete = !ranged || range!.End is null;
            if (complete) { break; }
        }
        if (values.Distinct(StringComparer.OrdinalIgnoreCase).Count() != values.Count) { throw AdAttributeRange.Incomplete(); }
        return (first ?? throw AdAttributeRange.Incomplete(), values.ToImmutable(), complete);
    }

    public async Task<FicheMemberRange> MembersAsync(string dn, int shown, int counted, CancellationToken cancellationToken)
    {
        if (shown is < 0 or > 2000 || counted is < 1 or > 50_000 || shown > counted) { throw FicheErrors.Error(FicheErrors.Invalid, "Limites de membres invalides."); }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(30), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var (entry, values, complete) = await RangeAsync(dn, "member", counted, budget.Token).ConfigureAwait(false);
        if (!entry.Strings("objectClass").Contains("group", StringComparer.OrdinalIgnoreCase)) { throw FicheErrors.Error(FicheErrors.NotApplicable, "Les membres se lisent sur un groupe."); }
        return new(dn, [.. values.Take(shown)], values.Length, complete, complete ? null : "Lecture arrêtée à " + FrenchText.Count(counted, "membre", "membres") + " ; la liste est incomplète.");
    }

    public async Task<bool?> TransitiveMemberAsync(string dn, string groupDn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(dn); AdFicheObjects.ValidateDn(groupDn);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        try
        {
            var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
            AdFicheObjects.EnsureDomain(dn, domain.RootDn); AdFicheObjects.EnsureDomain(groupDn, domain.RootDn);
            var epoch = source.Epoch;
            var rows = await source.Connection.SearchAsync(new(dn, "(memberOf:1.2.840.113556.1.4.1941:=" + SearchText.LdapLiteral(groupDn) + ")", AdSearchScope.Base, ["objectGUID"])
            { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, budget.Token).ConfigureAwait(false);
            EnsureEpoch(epoch);
            if (rows.Count > 1 || rows.Any(e => !FicheValues.SameDn(e.DistinguishedName, dn) || e.Guid("objectGUID") is null)) { throw AdAttributeRange.Incomplete(); }
            return rows.Count == 1;
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.NoSuchObject or AdErrors.Timeout or AdErrors.Unavailable) { return null; }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested) { return null; }
    }

    public async Task<FicheGroupGraph> GroupGraphAsync(string dn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(dn);
        var edges = ImmutableDictionary.CreateBuilder<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase);
        var nodes = ImmutableDictionary.CreateBuilder<string, FicheGraphNode>(StringComparer.OrdinalIgnoreCase);
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new Queue<(string Dn, int Depth)>();
        var truncated = false; var unread = 0;
        FichePrimaryGroup? primary = null;
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var epoch = await NetworkEpochAsync(dn, budget.Token).ConfigureAwait(false);
        try
        {
            var (start, parents, complete) = await RangeAsync(dn, "memberOf", 2000, budget.Token).ConfigureAwait(false);
            truncated = !complete;
            if (complete) { edges[dn] = parents; } else { unread++; }
            foreach (var parent in parents) { pending.Enqueue((parent, 1)); }
            var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
            if (start.Int("primaryGroupID") is > 0 and var rid && start.Sid("objectSid") is { } sid && sid.Contains('-'))
            {
                var primarySid = sid[..(sid.LastIndexOf('-') + 1)] + rid.ToString(CultureInfo.InvariantCulture);
                var found = await source.Connection.SearchAsync(new(domain.RootDn, "(&(objectClass=group)(objectSid=" + SearchText.LdapLiteral(primarySid) + "))", AdSearchScope.Subtree, SummaryAttributes)
                { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, budget.Token).ConfigureAwait(false);
                if (found.Count > 1 || found.Any(e => e.Sid("objectSid") != primarySid)) { throw AdAttributeRange.Incomplete(); }
                var group = found.SingleOrDefault();
                primary = FicheMemberships.PrimaryGroup(rid, group?.DistinguishedName, group?.String("name"));
                if (group is not null) { pending.Enqueue((group.DistinguishedName, 1)); }
            }
            while (pending.TryDequeue(out var next))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!visited.Add(next.Dn)) { continue; }
                if (nodes.Count >= 2000 || next.Depth > FicheMemberships.MaxDepth) { truncated = true; unread++; continue; }
                if (!ScopeRules.Contains(new(domain.RootDn, "", true), next.Dn)) { unread++; continue; }
                try
                {
                    var (group, ancestors, full) = await RangeAsync(next.Dn, "memberOf", 2000, budget.Token).ConfigureAwait(false);
                    if (!group.Strings("objectClass").Contains("group", StringComparer.OrdinalIgnoreCase) || group.Int("groupType") is not { } type) { unread++; continue; }
                    nodes[next.Dn] = new(next.Dn, group.String("name") ?? FicheValues.DisplayName(next.Dn), group.Sid("objectSid"), group.Int("adminCount"), type);
                    // No edge means unknown parents to the path algorithm; never turn a partial branch into a negative proof.
                    if (full) { edges[next.Dn] = ancestors; } else { truncated = true; unread++; }
                    foreach (var parent in ancestors) { pending.Enqueue((parent, next.Depth + 1)); }
                    if (pending.Count > 4000) { truncated = true; unread += pending.Count; break; }
                }
                catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.NoSuchObject or FicheErrors.Unknown or DomeniaErrors.SourceUnavailable) { unread++; }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested) { truncated = true; unread += Math.Max(1, pending.Count); }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Timeout or AdErrors.Unavailable) { truncated = true; unread += Math.Max(1, pending.Count); }
        EnsureEpoch(epoch);
        return new(dn, edges.ToImmutable(), nodes.ToImmutable(), truncated, unread, primary);
    }
}
