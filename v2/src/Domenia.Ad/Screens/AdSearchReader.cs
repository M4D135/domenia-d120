using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded LDAP lists and local, dated projections of the search screen. Construction performs no I/O.</summary>
public sealed partial class AdSearchReader : ISearchReader
{
    private const string LocalLabel = "Base locale";
    private readonly AdDirectorySource source;

    public AdSearchReader(AdDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<SearchPage> FindAsync(SearchQuery query, CancellationToken cancellationToken)
    {
        ValidateQuery(query);
        var duration = TimeSpan.FromSeconds(query.Plan.Kind == SearchPlanKind.Contains ? 60 : 30);
        using var elapsed = new CancellationTokenSource(duration, source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        try
        {
            var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
            EnsureBase(query.BaseDn, domain.RootDn);
            if (query.Kind == SearchListKind.Browse && SearchLists.IsRoot(query.BaseDn, domain.RootDn))
            { throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, "Choisissez une OU pour lister ses objets."); }
            var generation = source.Epoch;
            if (source.CanPrepareDirectoryRefresh) { await source.PrepareDirectoryRefreshAsync(budget.Token).ConfigureAwait(false); }
            var at = source.Clock.GetUtcNow();
            var stages = Stages(query, at);
            var resume = query.After;
            var firstStage = resume is null ? stages[0].Key : resume[..1];
            var start = stages.FindIndex(p => p.Key == firstStage);
            if (start < 0) { throw Invalid("Point de reprise incompatible avec cette recherche."); }
            var rows = ImmutableArray.CreateBuilder<SearchRow>();
            var accepted = new List<AdEntry>();
            var given = new HashSet<Guid>();
            var known = query.Known.ToHashSet(StringComparer.OrdinalIgnoreCase);
            var more = false;
            string? cursor = null;
            for (var n = start; n < stages.Count; n++)
            {
                var stage = stages[n];
                var after = n == start && resume is not null ? resume[2..] : "";
                var filter = after.Length == 0 ? stage.Filter : "(&" + stage.Filter + "(name>=" + SearchText.LdapLiteral(after) + "))";
                var count = query.Take - rows.Count + known.Count + given.Count + 1;
                var entries = await source.Connection.SearchAsync(new(query.BaseDn, filter, query.Subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel, AdObjectAccess.Attributes)
                { PageSize = 500, SizeLimit = count, Timeout = duration, SortAttribute = "name" }, budget.Token).ConfigureAwait(false);
                if (entries.Count > count || entries.Any(e => !ScopeRules.Contains(new(query.BaseDn, "", query.Subtree), e.DistinguishedName)))
                { throw Invalid("Réponse LDAP hors des limites ou du périmètre demandé."); }
                var projected = AdObjectAccess.Project(entries, domain, at);
                var candidates = SearchRowFactory.Candidates(projected).ToDictionary(c => c.Id);
                var factory = new SearchRowFactory(projected, source.CurrentObservations.Workstations, new Enrichment(source.CurrentDirectory ?? projected, source.FleetDetails), at);
                var lastInStage = after;
                foreach (var entry in entries)
                {
                    var id = entry.Guid("objectGUID")!.Value;
                    if (known.Contains(id.ToString("D")) || given.Contains(id)) { continue; }
                    if (rows.Count == query.Take)
                    {
                        more = true;
                        cursor = stage.Key + ":" + lastInStage;
                        break;
                    }
                    given.Add(id);
                    accepted.Add(entry);
                    rows.Add(factory.Row(candidates[id].Source));
                    // The server's raw name is the continuation key; French display folding is not an AD collation.
                    lastInStage = entry.String("name") ?? throw Invalid("Clé de tri LDAP absente.");
                    cursor = stage.Key + ":" + lastInStage;
                }
                if (more) { break; }
            }
            if (source.Epoch != generation) { throw Invalid("Session modifiée pendant la recherche."); }
            if (accepted.Count > 0)
            {
                await source.RememberObjectsAsync(AdObjectAccess.Project(accepted, domain, at), generation, budget.Token).ConfigureAwait(false);
            }
            return new(rows.ToImmutable(), more, cursor, at, "Annuaire · " + (source.ControllerName ?? domain.DnsName));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Budget de recherche atteint : résultat incomplet non publié. Affinez le texte ou le périmètre."); }
    }

    private static void ValidateQuery(SearchQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (query.Take is < 1 or > SearchLimits.MaxLimit || query.Known.Count > SearchLimits.MaxLimit
            || !query.Plan.Valid || query.Plan.Kind == SearchPlanKind.Address || string.IsNullOrWhiteSpace(query.Plan.LdapFilter)
            || query.After is { } key && (key.Length is < 2 or > 1026 || key[1] != ':'))
        { throw Invalid("Recherche invalide ou hors des limites : aucun objet lu."); }
    }

    private static List<(string Key, string Filter)> Stages(SearchQuery query, DateTimeOffset at)
    {
        if (query.Kind == SearchListKind.View)
        {
            var view = SearchViews.All(at).FirstOrDefault(v => v.Id == query.ViewId)
                ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, SearchErrors.ViewUnknownMessage);
            return [("p", view.LdapFilter)];
        }
        if (query.Kind != SearchListKind.Search || query.Plan.Kind != SearchPlanKind.Default || !query.Plan.Tokens.IsEmpty)
        { return [("p", query.Plan.LdapFilter)]; }
        var words = SearchText.Words(query.Plan.FreeText);
        if (words.IsEmpty || words.Any(w => w.Contains('*', StringComparison.Ordinal))) { return [("p", query.Plan.LdapFilter)]; }
        var type = SearchText.TypeLdapFilter(query.Type);
        var stages = new List<(string Key, string Filter)>();
        if (words.Length == 1)
        {
            var literal = SearchText.LdapLiteral(words[0]);
            var exact = "(|" + string.Concat(new[] { "name", "sAMAccountName", "userPrincipalName", "mail", "dNSHostName" }.Select(a => "(" + a + "=" + literal + ")")) + ")";
            stages.Add(("e", "(&" + type + exact + ")"));
        }
        stages.Add(("p", query.Plan.LdapFilter));
        stages.Add(("a", "(&" + type + string.Concat(words.Select(w => "(anr=" + SearchText.LdapLiteral(w) + ")")) + "(!" + query.Plan.LdapFilter + "))"));
        return stages;
    }

    private static void EnsureBase(string dn, string root)
    {
        if (!SearchLists.IsRoot(dn, root) && !ScopeRules.Contains(new(root, "", true), dn))
        { throw new DomeniaOperationException(DomeniaErrors.ScopeOutsideDomain, DomeniaErrors.ScopeOutsideDomainMessage); }
    }

    public async Task<ImmutableArray<SearchContainer>> ContainersAsync(bool counts, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        var epoch = source.Epoch;
        var found = await source.Connection.SearchAsync(new(domain.RootDn, "(objectClass=container)", AdSearchScope.OneLevel, ["distinguishedName", "name"])
        { PageSize = 500, SizeLimit = 501, Timeout = TimeSpan.FromSeconds(15) }, budget.Token).ConfigureAwait(false);
        if (found.Count > 500) { throw Invalid("Plus de 500 conteneurs : liste tronquée, affinez le périmètre."); }
        var result = ImmutableArray.CreateBuilder<SearchContainer>();
        foreach (var entry in found)
        {
            if (!ScopeRules.Contains(new(domain.RootDn, "", false), entry.DistinguishedName)) { throw Invalid("Conteneur hors domaine."); }
            var total = -1;
            if (counts)
            {
                var children = await source.Connection.SearchAsync(new(entry.DistinguishedName, SearchText.TypeLdapFilter(SearchTypeFilter.All), AdSearchScope.OneLevel, ["objectGUID"])
                { PageSize = 500, SizeLimit = 10_001, Timeout = TimeSpan.FromSeconds(15) }, budget.Token).ConfigureAwait(false);
                if (children.Count <= 10_000) { total = children.Count; }
            }
            result.Add(new(entry.DistinguishedName, entry.String("name") ?? SearchTexts.Leaf(entry.DistinguishedName), SearchContainers.IsSystem(entry.DistinguishedName, domain.RootDn), total));
        }
        if (source.Epoch != epoch) { throw Invalid("Session modifiée pendant la lecture des conteneurs."); }
        return [.. result.OrderBy(c => c.System).ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase)];
    }

    public async Task<ImmutableArray<SearchRow>> RereadAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        if (ids.Count == 0) { return []; }
        if (ids.Count > 500 || ids.Any(id => id == Guid.Empty)) { throw Invalid("Relecture limitée à 500 identités valides."); }
        await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var epoch = source.Epoch;
        var objects = await new AdObjectAccess(source).ReadAsync(ids.ToArray(), cancellationToken).ConfigureAwait(false);
        await source.RememberObjectsAsync(objects, epoch, cancellationToken).ConfigureAwait(false);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var factory = new SearchRowFactory(objects, state.Observations.Workstations, new Enrichment(state.Directory, source.FleetDetails), source.Clock.GetUtcNow());
        var found = SearchRowFactory.Candidates(objects).ToDictionary(c => c.Id);
        return [.. ids.Where(found.ContainsKey).Select(id => factory.Row(found[id].Source))];
    }

    private static DomeniaOperationException Invalid(string message) => new(DomeniaErrors.ArgumentsInvalid, message);
}
