using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Bridge;
using Domenia.Bridge.Operations.Requetes;

namespace Domenia.Tests;

internal static class HomeSearchSelectionTests
{
    [Test]
    public static async Task Home_route_resolves_the_exact_calculation_set_locally_and_refuses_any_replacement()
    {
        var bridge = new SimulatedBridge(); var home = AccueilService.From(bridge.Context);
        var session = await bridge.Source.GetSessionAsync(default);
        var working = WorkingScope.From(bridge.Context);
        await working.SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, default);
        var board = await home.BoardAsync(default);
        const string key = "fleet.enabled";
        var expected = await home.SearchSelectionAsync(board.Revision, key, default);
        Check.True(expected.Guids.Length > 0, "population de test réelle");
        Check.True(bridge.Registry.TryGet("search.home.selection", out var operation), "raccord du vrai module");
        Check.Equal(OperationClass.LocalRead, operation!.Class, "aucune autorisation réseau pour ce parcours");
        var response = SimulatedBridge.Json(await bridge.CallAsync("search.home.selection", JsonSerializer.Serialize(new { revision = board.Revision, key })));
        var actual = response.GetProperty("rows").EnumerateArray().Select(row => Guid.Parse(row.GetProperty("id").GetString()!)).ToHashSet();
        Check.True(actual.SetEquals(expected.Guids), "même ensemble que le chiffre, sans élargissement à l’OU");
        Check.Equal("selection", response.GetProperty("kind").GetString(), "liste figée, pas une recherche d’OU");
        Check.Contains(board.Revision, response.GetProperty("view").GetProperty("note").GetString(), "calcul nommé dans l’explication");
        Check.Equal(AccueilService.TargetsUnknown, (await bridge.CallAsync("search.home.selection", JsonSerializer.Serialize(new { revision = board.Revision, key = "absent" }))).Error!.Code, "pas de repli sur l’OU");
        await home.BoardAsync(default);
        Check.Equal(AccueilService.BoardReplaced, (await bridge.CallAsync("search.home.selection", JsonSerializer.Serialize(new { revision = board.Revision, key }))).Error!.Code, "ancien calcul refusé");
        board = await home.BoardAsync(default);
        await working.SetAsync(session, session.Domain?.RootDn ?? throw new TestFailureException("Le scénario exige un domaine connu."), true, default);
        await working.SetAsync(session, board.Scope.Dn, board.Scope.Subtree, default);
        Check.Equal(AccueilService.BoardReplaced, (await bridge.CallAsync("search.home.selection", JsonSerializer.Serialize(new { revision = board.Revision, key }))).Error!.Code, "retour A→B→A ne réactive pas l’ancien calcul");
    }
    [Test]
    public static async Task Hundred_thousand_home_targets_survive_the_real_search_service_without_page_truncation_or_network()
    {
        var source = new HomePipelineSource();
        var computers = Enumerable.Range(0, 100_000).Select(n => Fixtures.Computer("PC" + n.ToString("D6"))).ToArray();
        source.Current = source.Current with { Directory = Fixtures.Snapshot(computers: computers) with { Coverage = HomePipelineSource.Scope } };
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([new("machines", FleetWidgetSource.Builtin, "fleet.machines", "Kpi", "M", null, false, "")], default);
        var board = await home.BoardAsync(default);
        Check.Equal(100_000, (await home.SearchSelectionAsync(board.Revision, "fleet.machines", default)).Guids.Length, "le vrai calcul contient 100 000 postes");
        Check.True(home.Targets(board.Revision, "fleet.machines").Truncated, "le tiroir reste volontairement borné");
        var result = await SearchService.From(context).HomeSelectionAsync(board.Revision, "fleet.machines", default);
        Check.Equal(100_000, source.RequestedLocalRows, "le service demande le total, pas le contenu du tiroir ni les 20 000 premières lignes");
        Check.Equal(100_000, result.Rows.Length, "aucune limite de pagination de recherche n’ampute la sélection");
        Check.True(result.Rows.Select(r => Guid.Parse(r.Id)).ToHashSet().SetEquals(computers.Select(c => c.ObjectGuid)), "identités exactes jusqu’au dernier poste");
        Check.Equal(1, source.LocalRowsCalls, "une lecture locale, aucun parcours AD");
        Check.Equal(0, source.DirectoryCalls + source.PresenceCalls + source.InventoryCalls, "aucune collecte implicite");
    }

    [Test]
    public static async Task Account_epoch_store_and_scope_changes_during_local_rows_refuse_publication()
    {
        foreach (var change in new[] { "account", "epoch", "store", "scope" })
        {
            var source = new HomePipelineSource { HoldLocalRows = new(TaskCreationOptions.RunContinuationsAsynchronously) };
            using var context = source.Context(); var home = AccueilService.From(context);
            var board = await home.BoardAsync(default);
            var reading = SearchService.From(context).HomeSelectionAsync(board.Revision, "fleet.machines", default);
            await source.LocalRowsEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            if (change == "account") source.SessionLogin = @"TEST\other";
            else if (change == "epoch") source.SessionEpoch++;
            else if (change == "store") source.CurrentStoreId = "another-store";
            else await WorkingScope.From(context).SetAsync(await source.GetSessionAsync(default), Fixtures.Root, true, default);
            source.HoldLocalRows!.SetResult();
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reading, "contexte remplacé pendant la vraie lecture locale");
            Check.Equal(AccueilService.BoardReplaced, error.Code, "pas de publication d’une autre session/base/OU");
            Check.Equal(1, source.LocalRowsCalls, "pas de repli vers une autre sélection");
            Check.Equal(0, source.DirectoryCalls + source.PresenceCalls + source.InventoryCalls, "pas de réseau de remplacement");
        }
    }

    [Test]
    public static async Task Rechecking_a_home_selection_keeps_missing_rows_without_any_network_fallback()
    {
        var source = new HomePipelineSource();
        using var context = source.Context(); var home = AccueilService.From(context);
        var board = await home.BoardAsync(default); var search = SearchService.From(context);
        var result = await search.HomeSelectionAsync(board.Revision, "fleet.machines", default);
        var missing = source.Current.Directory.Computers[0].ObjectGuid;
        source.MissingLocalRows.Add(missing);
        var reread = await search.ReconcileAsync(result.ListId, default);
        Check.Equal(1, reread.Rows.Length, "seule ligne encore disponible dans la base locale");
        Check.True(reread.Missing.SequenceEqual([missing.ToString("D")]), "absence locale signalée sans preuve de suppression");
        Check.Equal(2, reread.Loaded, "la liste garde l’identité absente");
        Check.Equal(0, reread.Moved.Length + reread.Added.Length, "aucun déplacement ni élargissement déduit du cache");
        Check.Equal(2, source.LocalRowsCalls, "ouverture puis une seule relecture locale");
        source.MissingLocalRows.Clear();
        var recovered = await search.ReconcileAsync(result.ListId, default);
        Check.Equal(2, recovered.Rows.Length, "la même identité peut réapparaître au prochain contrôle explicite");
        Check.Equal(0, recovered.Missing.Length + recovered.Added.Length, "identité retrouvée sans doublon");
        Check.Equal(0, source.DirectoryCalls + source.PresenceCalls + source.InventoryCalls, "aucune collecte réseau");
        // HomeSelectionSearchReader throws on every network fallback, including RereadAsync.
    }

    [Test]
    public static async Task Missing_local_rows_are_reported_without_widening_the_home_set()
    {
        var source = new HomePipelineSource(); source.MissingLocalRows.Add(source.Current.Directory.Computers[0].ObjectGuid);
        using var context = source.Context(); var home = AccueilService.From(context);
        var board = await home.BoardAsync(default);
        var result = await SearchService.From(context).HomeSelectionAsync(board.Revision, "fleet.machines", default);
        Check.Equal(1, result.Rows.Length, "le poste disparu n’est pas remplacé");
        Check.Contains("1 poste absent", result.View!.Note, "absence expliquée avec le nombre exact");
        Check.Equal(source.Current.Directory.Computers[1].ObjectGuid.ToString("D"), result.Rows[0].Id, "seule identité encore disponible");
    }

}


/// <summary>Only the local boundary is served; every network/search fallback throws instead of returning a convenient empty list.</summary>
public sealed class HomeSelectionSearchReader(HomePipelineSource source) : ISearchReader
{
    public async Task<ImmutableArray<SearchRow>> LocalRowsAsync(IReadOnlyList<Guid> ids, CancellationToken token)
    {
        source.LocalRowsCalls++; source.RequestedLocalRows = ids.Count; source.LocalRowsEntered.TrySetResult();
        if (source.HoldLocalRows is { } held) await held.Task.WaitAsync(token);
        token.ThrowIfCancellationRequested();
        var wanted = ids.ToHashSet();
        var factory = new SearchRowFactory(source.Current.Directory, source.Current.Observations.Workstations, null, Fixtures.Now);
        return [.. source.Current.Directory.Computers.Where(c => wanted.Contains(c.ObjectGuid) && !source.MissingLocalRows.Contains(c.ObjectGuid)).Select(c => factory.Computer(c))];
    }
    private static InvalidOperationException Unexpected() => new("Aucune autre lecture autorisée pour une sélection Accueil locale.");
    public Task<SearchPage> FindAsync(SearchQuery query, CancellationToken token) => throw Unexpected();
    public Task<ImmutableArray<SearchContainer>> ContainersAsync(bool counts, CancellationToken token) => throw Unexpected();
    public Task<SearchPage> CachedAsync(SearchQuery query, CancellationToken token) => throw Unexpected();
    public Task<SearchPage> FindAddressAsync(SearchAddress address, int limit, CancellationToken token) => throw Unexpected();
    public Task<(SearchPage Page, SearchVerdictTotals Totals)> LocalQueryAsync(string queryId, string baseDn, bool subtree, string verdict, int limit, CancellationToken token) => throw Unexpected();
    public Task<ImmutableArray<SearchSuggestion>> SuggestAsync(string text, SearchTypeFilter type, int max, CancellationToken token) => throw Unexpected();
    public Task<SearchPreview?> PreviewAsync(Guid id, CancellationToken token) => throw Unexpected();
    public Task<SearchComparison> CompareAsync(IReadOnlyList<Guid> ids, CancellationToken token) => throw Unexpected();
    public Task<ImmutableArray<SearchRow>> RereadAsync(IReadOnlyList<Guid> ids, CancellationToken token) => throw Unexpected();
    public Task<string?> ReverseDnsAsync(string ipv4, CancellationToken token) => throw Unexpected();
    public Task<SurveyOutcome> ProbeAsync(Guid id, SurveyMode mode, int run, TimeSpan inventoryReuse, CancellationToken token) => throw Unexpected();
    public Task<ImmutableArray<SearchLegacySaved>> LegacySavedSearchesAsync(CancellationToken token) => throw Unexpected();
    public Task<NetworkDiagnosticLine> DiagnoseAsync(Guid id, CancellationToken token) => throw Unexpected();
}
