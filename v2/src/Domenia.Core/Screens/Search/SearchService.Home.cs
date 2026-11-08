using System.Collections.Immutable;
using Domenia.Core.Accueil;

namespace Domenia.Core;

public sealed partial class SearchService
{
    /// <summary>The exact set of the displayed home calculation, resolved by the engine. No OU browse and no network read.</summary>
    public async Task<SearchResult> HomeSelectionAsync(string revision, string key, CancellationToken token)
    {
        var home = AccueilService.From(context);
        var selection = await home.SearchSelectionAsync(revision, key, token).ConfigureAwait(false);
        var owner = await ReconcileOwnerAsync(token).ConfigureAwait(false);
        var rows = await context.Readers.Require<ISearchReader>().LocalRowsAsync(selection.Guids, token).ConfigureAwait(false);
        var expected = selection.Guids.ToHashSet();
        var byId = rows.Where(row => row.Kind == SearchObjectKind.Computer && Guid.TryParse(row.Id, out var id)
            && expected.Contains(id) && SearchMemoryRules.Within(row.Dn, selection.DomainDn)).GroupBy(row => Guid.Parse(row.Id)).ToDictionary(g => g.Key, g => g.First());
        var ordered = selection.Guids.Where(byId.ContainsKey).Select(id => byId[id]).ToImmutableArray();
        _ = await home.SearchSelectionAsync(revision, key, token).ConfigureAwait(false);
        if (owner != await ReconcileOwnerAsync(token).ConfigureAwait(false))
            throw new DomeniaOperationException(AccueilService.BoardReplaced, AccueilService.BoardReplacedMessage);
        token.ThrowIfCancellationRequested();
        var missing = selection.Guids.Length - ordered.Length;
        var note = "Ensemble exact de l’Accueil · calcul " + revision + " · " + FrenchText.Count(selection.Guids.Length, "poste", "postes")
            + (missing == 0 ? "" : " · " + FrenchText.Count(missing, "poste absent des données locales", "postes absents des données locales") + " ; aucune recherche élargie.");
        var plan = new SearchPlan(SearchPlanKind.Selection, true, "", note, [], [], null, null, "", false, "");
        var info = new SearchViewInfo("home", selection.Label, note, false, true, "");
        var scope = SearchLists.Scope(false, selection.Scope.Dn, selection.DomainDn, owner.Domain ?? "", selection.Scope.Subtree);
        var state = Register(new ListState(SearchListKind.Selection, plan, SearchTypeFilter.Computers, selection.Scope.Dn, selection.Scope.Subtree,
            "home", "", SearchMatchMode.Prefix, scope, info));
        return Complete(state, new SearchPage(ordered, false, null, selection.At, "Ensemble local de l’Accueil"), Math.Max(1, ordered.Length), appended: false);
    }
}
