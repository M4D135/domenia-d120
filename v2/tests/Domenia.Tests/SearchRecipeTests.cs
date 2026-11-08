using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Tests;

internal static class SearchRecipeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static async Task<JsonElement> Ok(SimulatedBridge bridge, string operation, object? args = null) =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, JsonSerializer.Serialize(args ?? new { })));

    [Test]
    public static async Task Real_search_catalog_executes_saved_recipe_revision_and_keeps_next_page_frozen()
    {
        var bridge = new SimulatedBridge(); var session = await bridge.Source.GetSessionAsync(None);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine simulé absent.");
        var library = RequetesServices.Library(bridge.Context);
        var saved = await library.SaveAsync(root, QueryRecipe.Empty(id: "A_saved-recipe") with { Name = "Tous mes postes" }, null, null, 0, "update", null, None);
        var catalog = await Ok(bridge, "search.catalog");
        var entry = catalog.GetProperty("entries").EnumerateArray().Single(e => e.GetProperty("id").GetString() == "recipe:" + saved.Record.Id);
        Check.Equal(1L, entry.GetProperty("recipe").GetProperty("revision").GetInt64(), "révision réellement affichée");
        await Ok(bridge, "search.query.favorite", new { id = "recipe:" + saved.Record.Id, favorite = true });
        var queryReader = bridge.Context.Readers.Require<IQueryWorkshopReader>(); var before = await queryReader.DatasetAsync(None);
        var args = new { id = saved.Record.Id, revision = 1, fingerprint = saved.Record.Fingerprint, domain = root, dn = root, subtree = true, verdict = "all", limit = 2 };
        var first = await Ok(bridge, "search.recipe.run", args);
        Check.Equal(2, first.GetProperty("rows").GetArrayLength(), "limite demandée");
        Check.Equal(1L, first.GetProperty("recipe").GetProperty("revision").GetInt64(), "révision exécutée");
        await library.SaveAsync(root, saved.Record.Recipe with { Name = "Nouvelle révision" }, null, null, 1, "update", null, None);
        var next = await Ok(bridge, "search.recipe.more", new { listId = first.GetProperty("listId").GetString(), limit = 5 });
        Check.Equal(3, next.GetProperty("rows").GetArrayLength(), "seules les lignes suivantes");
        Check.Equal(1L, next.GetProperty("recipe").GetProperty("revision").GetInt64(), "aucune adoption silencieuse de la nouvelle révision");
        Check.Equal(before.Version, (await queryReader.DatasetAsync(None)).Version, "aucune collecte déclenchée");
        Check.Equal("search.viewUnknown", (await bridge.CallAsync("search.recipe.run", JsonSerializer.Serialize(args))).Error?.Code, "catalogue périmé refusé");
        Check.False(first.GetProperty("view").GetProperty("surveyAllowed").GetBoolean(), "collecte distincte du calcul local");
        var other = new { id = saved.Record.Id, revision = 1, fingerprint = saved.Record.Fingerprint, domain = Fixtures.Root, dn = root, subtree = true, verdict = "all", limit = 2 };
        Check.Equal("search.viewUnknown", (await bridge.CallAsync("search.recipe.run", JsonSerializer.Serialize(other))).Error?.Code, "domaine du catalogue qualifié avant calcul");
    }

    [Test]
    public static async Task Empty_workshop_selection_remains_active_and_other_session_domain_or_target_is_refused()
    {
        var bridge = new SimulatedBridge(); var session = await bridge.Source.GetSessionAsync(None);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine simulé absent.");
        var workshop = QueryWorkshop.From(bridge.Context);
        var selected = new QuerySearchSelection("empty", "Sélection vide", QueryTarget.Computer, [], TestClock.Reference, new string('a', 64))
            { RootDn = root, Epoch = session.Epoch, Account = session.Account.Login };
        workshop.Search = selected;
        Check.Equal(0, (await Ok(bridge, "requetes.search.selection")).GetProperty("count").GetInt32(), "[] existe, distinct de null");
        Check.Equal(0, (await Ok(bridge, "search.query.rows")).GetProperty("rows").GetArrayLength(), "vraie liste vide affichable");
        Check.False(selected.Matches(session with { Epoch = session.Epoch + 1 }), "reconnexion du même compte refusée");
        Check.False(selected.Matches(session with { Account = session.Account with { Login = "autre" } }), "autre compte refusé");
        workshop.Search = selected with { RootDn = Fixtures.Root };
        Check.Equal(JsonValueKind.Null, (await Ok(bridge, "requetes.search.selection")).ValueKind, "autre domaine masqué");
        Check.Equal("search.listUnknown", (await bridge.CallAsync("search.query.rows", "{}")).Error?.Code, "autre domaine interdit à la lecture des lignes");
        workshop.Search = selected with { Target = QueryTarget.User };
        Check.Equal("search.listUnknown", (await bridge.CallAsync("search.query.rows", "{}")).Error?.Code, "uniquement GUID de postes");
    }

    [Test]
    public static async Task Saved_select_uses_real_dated_details_and_missing_or_old_readings_remain_unknown()
    {
        var machines = new[] { Fixtures.Computer("A"), Fixtures.Computer("B"), Fixtures.Computer("C"), Fixtures.Computer("D") };
        var definition = WqlRules.NewReadDefinition(@"root\cimv2", "SELECT Name FROM Win32_Service", 100);
        var details = ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty
            .Add(machines[0].ObjectGuid, [new(definition.RequestKey, TestClock.Reference, true, 2, true, false)])
            .Add(machines[1].ObjectGuid, [new(definition.RequestKey, TestClock.Reference, true, 0, true, false)])
            .Add(machines[2].ObjectGuid, [new(definition.RequestKey, TestClock.Reference.AddDays(-31), true, 2, true, false)]);
        var recipe = QueryRecipe.Empty() with { ReadDefinition = definition, Clauses = [new(QueryCatalog.DetailPrefix + definition.RequestKey + ":count", QueryOperator.Greater, QueryValue.FromNumber(0))] };
        var source = await SourceAsync(Dataset(Fixtures.Snapshot(computers: machines)) with { Details = details });
        using var context = Context(source); using var library = Library();
        var saved = await library.SaveAsync(Fixtures.Root, recipe, null, null, 0, "update", null, None);
        var result = await SearchService.From(context).RecipeAsync(library, saved.Record.Id, 1, saved.Record.Fingerprint, Fixtures.Root, true, "all", 100, None);
        Check.Equal(1, result.Verdicts!.Match, "SELECT mémorisé positif"); Check.Equal(1, result.Verdicts.NoMatch, "zéro réellement complet");
        Check.Equal(2, result.Verdicts.Unknown, "ancien ou absent reste inconnu"); Check.Equal(0, source.RemoteReads, "aucun SELECT distant relancé");
    }

    [Test]
    public static async Task Twenty_thousand_rows_are_two_pages_of_one_population_and_reconnection_refuses_more()
    {
        var machines = Enumerable.Range(0, 20_005).Select(i => Fixtures.Computer("PC" + i.ToString("D5", System.Globalization.CultureInfo.InvariantCulture))).ToArray();
        var source = await SourceAsync(Dataset(Fixtures.Snapshot(computers: machines) with { Complete = false }));
        using var context = Context(source); using var library = Library(); var service = SearchService.From(context);
        var saved = await library.SaveAsync(Fixtures.Root, QueryRecipe.Empty(), null, null, 0, "update", null, None);
        var first = await service.RecipeAsync(library, saved.Record.Id, 1, saved.Record.Fingerprint, Fixtures.Root, true, "all", 20_000, None);
        Check.Equal(10_000, first.Rows.Length, "première page bornée"); Check.False(first.Recipe!.SourceComplete, "source partielle visible");
        source.Dataset = Dataset(Fixtures.Snapshot());
        var second = await service.RecipeMoreAsync(first.ListId, 20_000, None);
        Check.Equal(10_000, second.Rows.Length, "deuxième page bornée");
        Check.Equal(20_000, first.Rows.Concat(second.Rows).Select(r => r.Id).Distinct().Count(), "aucun doublon, ancienne population conservée");
        Check.Equal(1, source.DatasetReads, "la continuation ne relit ni ne recalcule");
        Check.False(second.Complete, "20 005 correspondants ne sont pas annoncés complets"); Check.False(second.Continuation.Allowed, "plafond explicite");
        source.Session = source.Session with { Epoch = source.Session.Epoch + 1 };
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RecipeMoreAsync(first.ListId, 20_000, None), "session remplacée refusée");
        Check.Equal(0, source.RemoteReads, "aucune lecture distante");
    }

    [Test]
    public static async Task Changed_recipe_during_dataset_read_is_refused_and_root_direct_scope_does_not_expand()
    {
        var source = await SourceAsync(Dataset(Fixtures.Snapshot(computers: [Fixtures.Computer("A")]) with { Coverage = new(Fixtures.Postes, "Postes", true) }));
        using var context = Context(source); using var library = Library(); var service = SearchService.From(context);
        var saved = await library.SaveAsync(Fixtures.Root, QueryRecipe.Empty(), null, null, 0, "update", null, None);
        var direct = await service.RecipeAsync(library, saved.Record.Id, 1, saved.Record.Fingerprint, Fixtures.Root, false, "all", 10, None);
        Check.Equal(0, direct.Rows.Length, "sans sous-OU ne devient pas tout le domaine");
        Check.False(direct.Recipe!.SourceComplete, "copie complète d’une OU ne prouve pas la couverture du domaine");
        source.BeforeDataset = async () => { await library.SaveAsync(Fixtures.Root, saved.Record.Recipe with { Name = "Modification concurrente" }, null, null, 1, "update", null, None); };
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RecipeAsync(library, saved.Record.Id, 1, saved.Record.Fingerprint, Fixtures.Root, true, "all", 10, None), "révision requalifiée après lecture des données");
        source.BeforeDataset = null;
        source.Dataset = source.Dataset with { Directory = source.Dataset.Directory with { Domain = Fixtures.Domain with { RootDn = "DC=other,DC=local" } } };
        var current = (await library.ReadAsync(Fixtures.Root, None)).Records.Single();
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RecipeAsync(library, current.Id, current.Revision, current.Fingerprint, Fixtures.Root, true, "all", 10, None), "cache d’un autre domaine refusé");
        using var canceled = new CancellationTokenSource(); canceled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => service.RecipeAsync(library, current.Id, current.Revision, current.Fingerprint, Fixtures.Root, true, "all", 10, canceled.Token), "annulation conservée");
        Check.Equal(0, source.RemoteReads, "refus sans lecture distante");
    }

    private static QueryDataset Dataset(DirectorySnapshot directory) => new(directory, new(null, []), ImmutableDictionary<Guid, ImmutableArray<Domenia.Core.Queries.ProbeReading>>.Empty,
        ImmutableDictionary<Guid, ConsoleReading>.Empty, ImmutableDictionary<Guid, char>.Empty, ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "Copie locale de test", true);
    private static async Task<SearchRecipeFixtureSource> SourceAsync(QueryDataset dataset)
    {
        var session = await new SimulatedBridge().Source.GetSessionAsync(None);
        return new(dataset, session with { Domain = new("test.local", "TEST", Fixtures.Root) });
    }
    private static EngineContext Context(SearchRecipeFixtureSource source) => new(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
        ScreenReaders.Discover(source, [typeof(SearchRecipeFixtureReader).Assembly]));
    private static QueryLibrary Library() => new(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
}

public sealed class SearchRecipeFixtureSource(QueryDataset dataset, SessionSnapshot session) : IDirectorySource
{
    public QueryDataset Dataset { get; set; } = dataset;
    public SessionSnapshot Session { get; set; } = session;
    public int DatasetReads { get; set; }
    public Func<Task>? BeforeDataset { get; set; }
    public int RemoteReads { get; private set; }
    public DirectorySourceKind Kind => DirectorySourceKind.Simulation;
    public Task<SessionSnapshot> GetSessionAsync(CancellationToken token) { token.ThrowIfCancellationRequested(); return Task.FromResult(Session); }
    public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => Task.FromResult(new DirectoryState(Dataset.Directory, Dataset.Observations, [], []));
    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token) { RemoteReads++; throw new InvalidOperationException("Lecture distante interdite."); }
}
public sealed class SearchRecipeFixtureReader(SearchRecipeFixtureSource source) : IQueryWorkshopReader
{
    public async Task<QueryDataset> DatasetAsync(CancellationToken token) { token.ThrowIfCancellationRequested(); source.DatasetReads++; if (source.BeforeDataset is { } before) { await before(); } return source.Dataset; }
    public Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken token) => throw new InvalidOperationException("Collecte interdite.");
}
