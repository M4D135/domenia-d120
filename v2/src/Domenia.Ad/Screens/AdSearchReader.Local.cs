using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Ad;

public sealed partial class AdSearchReader
{
    private async Task<DirectoryState?> LocalAsync(CancellationToken token)
    {
        try { return await source.ReadLocalAsync(token).ConfigureAwait(false); }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NotConnected) { return null; }
    }

    private SearchRowFactory Factory(DirectoryState state) => new(state.Directory, state.Observations.Workstations,
        new Enrichment(state.Directory, source.FleetDetails), source.Clock.GetUtcNow());

    public async Task<SearchPage> CachedAsync(SearchQuery query, CancellationToken cancellationToken)
    {
        var state = await LocalAsync(cancellationToken).ConfigureAwait(false);
        if (state is null) { return new([], false, null, source.Clock.GetUtcNow(), "Base locale non lue"); }
        EnsureBase(query.BaseDn, state.Directory.Domain.RootDn);
        var factory = Factory(state);
        var match = SearchMatcher.Compile(query.Plan, query.Type);
        var rows = SearchRowFactory.Candidates(state.Directory).Where(c => ScopeRules.Contains(new(query.BaseDn, "", query.Subtree), c.Dn) && match(c))
            .OrderBy(c => SearchMatcher.Rank(c, query.Plan.FreeText)).ThenBy(c => c.NameKey, StringComparer.Ordinal).Take(Math.Clamp(query.Take, 1, SearchLimits.MaxLimit));
        return new([.. rows.Select(c => factory.Row(c.Source))], false, null, state.Directory.ReadAt, LocalLabel);
    }

    public async Task<ImmutableArray<SearchSuggestion>> SuggestAsync(string text, SearchTypeFilter type, int max, CancellationToken cancellationToken)
    {
        var folded = FrenchText.Fold(text.Trim());
        if (folded.Length < SearchLimits.MinChars) { return []; }
        var state = await LocalAsync(cancellationToken).ConfigureAwait(false);
        if (state is null) { return []; }
        return [.. SearchRowFactory.Candidates(state.Directory).Where(c => SearchMatcher.OfType(c, type) && c.Folded.Any(v => v.Contains(folded, StringComparison.Ordinal)))
            .OrderBy(c => c.Folded.Any(v => v.StartsWith(folded, StringComparison.Ordinal)) ? 0 : 1)
            .ThenBy(c => c.NameKey, StringComparer.Ordinal).Take(Math.Clamp(max, 1, 50))
            .Select(c => new SearchSuggestion("local", c.Name, c.Name, LocalLabel + " · " + (c.Sam ?? c.Kind.ToString()), c.Kind, c.Dn))];
    }

    public async Task<SearchPreview?> PreviewAsync(Guid id, CancellationToken cancellationToken)
    {
        var state = await LocalAsync(cancellationToken).ConfigureAwait(false);
        if (state is null) { return null; }
        var candidate = SearchRowFactory.Candidates(state.Directory).FirstOrDefault(c => c.Id == id);
        if (candidate is null) { return null; }
        var factory = Factory(state);
        return SearchDetails.Preview(factory.Row(candidate.Source), candidate.Source, state.Directory, factory.Observation(id), source.Zone, LocalLabel);
    }

    public async Task<SearchComparison> CompareAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var factory = Factory(state);
        var byId = SearchRowFactory.Candidates(state.Directory).ToDictionary(c => c.Id);
        var rows = ids.Where(byId.ContainsKey).Select(id => byId[id]).Select(c => (factory.Row(c.Source), c.Source, factory.Observation(c.Id))).ToList();
        return SearchDetails.Compare(rows, state.Directory, source.Zone);
    }

    public async Task<ImmutableArray<SearchRow>> LocalRowsAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        var state = await LocalAsync(cancellationToken).ConfigureAwait(false);
        if (state is null) { return []; }
        var factory = Factory(state);
        var byId = SearchRowFactory.Candidates(state.Directory).ToDictionary(c => c.Id);
        return [.. ids.Where(byId.ContainsKey).Select(id => factory.Row(byId[id].Source))];
    }

    public async Task<SearchPage> FindAddressAsync(SearchAddress address, int limit, CancellationToken cancellationToken)
    {
        var state = await LocalAsync(cancellationToken).ConfigureAwait(false);
        if (state is null) { return new([], false, null, source.Clock.GetUtcNow(), "Aucun relevé local"); }
        var factory = Factory(state);
        var computers = state.Directory.Computers.ToDictionary(c => c.ObjectGuid);
        var matching = source.FleetDetails.Addresses.Where(p => computers.ContainsKey(p.Key)).SelectMany(p => p.Value.Select(a => (Id: p.Key, Address: a)))
            .Where(p => string.Equals(address.Kind == "mac" ? p.Address.Mac : p.Address.Ip, address.Value, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(p => p.Address.ObservedAt).GroupBy(p => p.Id).Select(g => g.First()).ToList();
        var take = Math.Clamp(limit, 1, SearchLimits.MaxLimit);
        return new([.. matching.Take(take).Select(p => factory.Computer(computers[p.Id]) with { Address = p.Address })], matching.Count > take, null,
            state.Observations.TakenAt ?? state.Directory.ReadAt, "Relevés locaux datés");
    }

    public Task<ImmutableArray<SearchLegacySaved>> LegacySavedSearchesAsync(CancellationToken cancellationToken) =>
        source.LocalStore is ILegacySearchCache legacy ? legacy.ReadLegacySearchesAsync(cancellationToken) : Task.FromResult(ImmutableArray<SearchLegacySaved>.Empty);

    public async Task<(SearchPage Page, SearchVerdictTotals Totals)> LocalQueryAsync(string queryId, string baseDn, bool subtree, string verdict, int limit, CancellationToken cancellationToken)
    {
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        EnsureBase(baseDn, state.Directory.Domain.RootDn);
        var factory = Factory(state);
        var now = source.Clock.GetUtcNow();
        var query = SearchViews.LocalQueries.FirstOrDefault(q => q.Id == queryId)
            ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, SearchErrors.ViewUnknownMessage);
        var covered = state.Directory.CoversScope(new(baseDn, "", subtree));
        int match = 0, unknown = 0, noMatch = 0, read = 0, total = 0;
        DateTimeOffset? oldest = null;
        var rows = new List<(int Order, SearchRow Row)>();
        foreach (var candidate in SearchRowFactory.Candidates(state.Directory).OrderBy(c => c.NameKey, StringComparer.Ordinal))
        {
            if (candidate.Source is not DirectoryComputer computer || AdValues.IsDisabled(computer.UserAccountControl)
                || AdValues.HasFlag(computer.UserAccountControl, AdValues.ServerTrustAccount) || !ScopeRules.Contains(new(baseDn, "", subtree), candidate.Dn))
            {
                continue;
            }
            var observation = factory.Observation(computer.ObjectGuid);
            total++;
            // Coverage (RCH-120): the latest reading of each workstation of the perimeter, dated, within 30 days.
            var latest = Latest(observation);
            if (latest is DateTimeOffset at && now - at <= TimeSpan.FromDays(30))
            {
                read++;
                oldest = oldest is null || at < oldest ? at : oldest;
            }
            var result = query.Evaluate(computer, observation, now, source.Zone);
            int order;
            switch (result.Verdict)
            {
                case SearchViews.Match:
                    match++;
                    order = 0;
                    break;
                case SearchViews.NoMatch:
                    noMatch++;
                    order = 2;
                    break;
                default:
                    unknown++;
                    order = 1;
                    break;
            }
            if (verdict == "all" || verdict == result.Verdict)
            {
                rows.Add((order, factory.Computer(computer, 9, SearchViews.VerdictLabel(result.Verdict) + " · " + result.Value)));
            }
        }
        var shown = verdict switch
        {
            SearchViews.Match => "Correspondants",
            SearchViews.NoMatch => "Non correspondants",
            SearchViews.Unknown => "Inconnus",
            _ => "Tous les postes",
        };
        // « Tous » lists the matching workstations first, then the unknown, then the others: the limit never hides the signal.
        var ordered = rows.OrderBy(r => r.Order).Select(r => r.Row).ToList();
        var take = Math.Max(1, limit);
        DateTimeOffset? complete = covered && total > 0 && read == total ? oldest : null;
        var coverage = !covered ? "Base locale partielle : seuls les postes connus sont évalués, sans total garanti pour cette OU." : total == 0
            ? "Aucun poste actif dans ce périmètre."
            : complete is DateTimeOffset since
                ? "Dernière lecture complète couvrant le périmètre" + FrenchText.Colon + "tous les postes relevés depuis le " + SearchDetails.When(since, source.Zone) + "."
                : "Aucune lecture complète du périmètre" + FrenchText.Colon + FrenchText.Count(total - read, "poste", "postes") + " sur " + FrenchText.Integer(total)
                    + " sans aucun relevé (présence ou inventaire) de moins de 30 jours.";
        return (new SearchPage([.. ordered.Take(take)], ordered.Count > take, null, state.Observations.TakenAt ?? state.Directory.ReadAt, "Relevés locaux datés"),
            new SearchVerdictTotals(match, unknown, noMatch, shown, complete, coverage));
    }

    private static DateTimeOffset? Latest(WorkstationObservation? observation)
    {
        if (observation is null)
        {
            return null;
        }
        DateTimeOffset? at = observation.Presence is { HasReading: true, CheckedAt: DateTimeOffset p } ? p : null;
        if (observation.Inventory is { HasReading: true, CheckedAt: DateTimeOffset i } && (at is null || i > at))
        {
            at = i;
        }
        return at;
    }

    private sealed class Enrichment(DirectorySnapshot directory, CachedFleet fleet) : ISearchEnrichment
    {
        public PresenceMeasure? Presence(Guid computer) => null;
        public SearchConsole? Console(Guid computer)
        {
            if (!fleet.Facts.Machines.TryGetValue(computer, out var facts) || facts.ConsoleAt is null) { return null; }
            var login = facts.ConsoleUser;
            if (string.IsNullOrWhiteSpace(login)) { return new("none", "Aucune session à la console", null, null, null, facts.ConsoleAt); }
            var pieces = login.Split('\\');
            var user = (pieces.Length == 1 || pieces.Length == 2 && (pieces[0].Equals(directory.Domain.NetbiosName, StringComparison.OrdinalIgnoreCase)
                || pieces[0].Equals(directory.Domain.DnsName, StringComparison.OrdinalIgnoreCase)))
                ? directory.Users.FirstOrDefault(u => u.SamAccountName.Equals(pieces[^1], StringComparison.OrdinalIgnoreCase)) : null;
            return new("seen", user is null ? login : user.DisplayName + " (" + login + ")", user?.DisplayName, login, user?.DistinguishedName, facts.ConsoleAt);
        }
        public SearchAssociation? Association(Guid objectId)
        {
            var computer = directory.Computers.FirstOrDefault(c => c.ObjectGuid == objectId);
            var user = computer?.ManagedByDn is { } dn ? directory.Users.FirstOrDefault(u => DistinguishedName.AreEqual(u.DistinguishedName, dn)) : null;
            return user is null ? null : new(user.DisplayName + " (" + user.SamAccountName + ")", user.DistinguishedName,
                "Déclaré dans l’annuaire (managedBy)", "Déclaré", "Association déclarée ; l’identité de la personne au poste n’est pas vérifiable par Domenia.");
        }
        public SearchAddressReading? Address(Guid computer) => fleet.Addresses.TryGetValue(computer, out var readings)
            ? readings.OrderByDescending(a => a.ObservedAt).FirstOrDefault() : null;
    }
}
