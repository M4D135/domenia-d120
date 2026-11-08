using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class HomeQueryDraftTests
{
    [Test]
    public static async Task A_real_home_figure_opens_an_equivalent_recipe_and_local_preview_in_the_same_scope()
    {
        var bridge = new SimulatedBridge(); using var owned = bridge.Context;
        var home = AccueilService.From(bridge.Context);
        var session = await bridge.Source.GetSessionAsync(default);
        await WorkingScope.From(bridge.Context).SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, default);
        var board = await home.BoardAsync(default);
        foreach (var key in new[] { "fleet.enabled", "fleet.disabled", "fleet.machines", "fleet.attention" })
        {
            var expected = await home.SearchSelectionAsync(board.Revision, key, default);
            var response = await bridge.CallAsync("requetes.home.recipe", JsonSerializer.Serialize(new { revision = board.Revision, key }));
            Check.Equal("result", response.Kind, "transfert réel accepté : " + key + " " + response.Error?.Message);
            var data = SimulatedBridge.Json(response); var draft = data.GetProperty("draft");
            Check.Equal(expected.Guids.Length, draft.GetProperty("count").GetInt32(), "total complet du calcul");
            Check.Equal(expected.Scope.Dn, data.GetProperty("scope").GetProperty("effective").GetProperty("dn").GetString(), "OU conservée");
            Check.Equal(expected.Account, draft.GetProperty("account").GetString(), "compte de provenance");
            Check.Equal(key == "fleet.attention", draft.GetProperty("frozen").GetBoolean(), "critères simples ou attention explicitement figée");
            var preview = SimulatedBridge.Json(await bridge.CallAsync("requetes.preview", "{\"recipe\":" + draft.GetProperty("recipe").GetRawText() + ",\"verdict\":\"match\"}"));
            Check.Equal(expected.Guids.Length, preview.GetProperty("counts").GetProperty("matched").GetInt32(), "aperçu des mêmes correspondants");
            Check.True(preview.GetProperty("rows").EnumerateArray().All(row => expected.Guids.Contains(Guid.Parse(row.GetProperty("id").GetString()!))), "aucun autre poste introduit");
        }
        await home.BoardAsync(default);
        var stale = await bridge.CallAsync("requetes.home.recipe", JsonSerializer.Serialize(new { revision = board.Revision, key = "fleet.enabled" }));
        Check.Equal(AccueilService.BoardReplaced, stale.Error!.Code, "ancien chiffre refusé sans élargissement");
        Check.True(bridge.Registry.TryGet("requetes.home.recipe", out var operation) && operation!.Class == Domenia.Bridge.OperationClass.LocalWrite, "transfert de périmètre local, jamais réseau");
    }

    [Test]
    public static void Frozen_sets_keep_empty_distinct_from_all_and_bound_the_full_identity_set()
    {
        var empty = HomeQueryRecipes.Resolve("fleet.attention", "Attention", [], [], Fixtures.Now, @"TEST\operator");
        Check.True(empty.ObjectIds is { Length: 0 }, "vide explicite, jamais null qui signifierait tout le périmètre");
        var dataset = Dataset(Fixtures.Computer("PC1"));
        var record = QueryRecordBuilder.Build(dataset, QueryTarget.Computer, null, Fixtures.Now).Single();
        var evaluation = new QueryEvaluationContext(null, Fixtures.Now);
        Check.False(QueryEngine.Compile(empty).InPopulation(record, evaluation), "aucun poste ne rentre dans la sélection vide");
        var ids = Enumerable.Range(0, QueryLimits.MaxObjectIds).Select(i => Fixtures.IdOf("fixed" + i)).ToImmutableArray();
        var full = HomeQueryRecipes.Resolve("fleet.attention", "Attention", ids, [], Fixtures.Now, @"TEST\operator");
        var roundtrip = QueryEngine.Compile(QueryRecipeJson.Read(QueryRecipeJson.Write(full))).Normalized;
        Check.True(roundtrip.ObjectIds!.Value.SequenceEqual(ids.Select(id => id.ToString("D")).Order(StringComparer.Ordinal)), "20 000 identités conservées jusqu’à la dernière et réouvrables");
        Check.Contains("TEST\\operator", full.Name, "sélection nommée avec son compte");
        Check.Equal("query.selectionTooLarge", Check.Throws<DomeniaOperationException>(() => HomeQueryRecipes.Resolve("fleet.attention", "Attention", ids.Add(Guid.NewGuid()), [], Fixtures.Now, "operator"), "20 001 refusés sans troncature").Code, "borne explicite");
        foreach (var invalid in new[] { ImmutableArray.Create(Guid.Empty), ImmutableArray.Create(ids[0], ids[0]) })
            Check.Equal("query.selectionInvalid", Check.Throws<DomeniaOperationException>(() => HomeQueryRecipes.Resolve("fleet.machines", "Parc", invalid, [], Fixtures.Now, "operator"), "identités invalides").Code, "jamais de dédoublonnage silencieux");
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(full with { ObjectIds = ["pas-un-guid"] }), "moteur refuse aussi une saisie invalide");
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(full with { ObjectIds = [Guid.Empty.ToString("D")] }), "GUID vide refusé par le moteur");
    }

    [Test]
    public static void A_rule_that_does_not_reproduce_the_figure_falls_back_to_its_exact_frozen_set()
    {
        var pc = Fixtures.Computer("PC1");
        var records = QueryRecordBuilder.Build(Dataset(pc), QueryTarget.Computer, null, Fixtures.Now);
        var draft = HomeQueryRecipes.Resolve("fleet.enabled", "Activés", [], records, Fixtures.Now, "operator");
        Check.True(draft.ObjectIds is { Length: 0 }, "données divergentes : aucun autre poste proposé par une équivalence supposée");
    }

    [Test]
    public static async Task Twenty_thousand_frozen_ids_survive_the_bridge_draft_and_library_without_relaxing_condition_limits()
    {
        var bridge = new SimulatedBridge(); using var owned = bridge.Context;
        var ids = Enumerable.Range(0, QueryLimits.MaxObjectIds).Select(i => Fixtures.IdOf("bridge-fixed" + i)).ToImmutableArray();
        var recipe = HomeQueryRecipes.Resolve("fleet.attention", "Attention", ids, [], Fixtures.Now, @"TEST\operator");
        var json = QueryRecipeJson.Write(recipe);
        var keep = await bridge.CallAsync("requetes.draft.keep", "{\"recipe\":" + json + "}");
        Check.Equal("result", keep.Kind, "le vrai pont conserve le brouillon de 20 000 GUID : " + keep.Error?.Message);
        var draft = SimulatedBridge.Json(await bridge.CallAsync("requetes.draft.get"));
        Check.Equal(QueryLimits.MaxObjectIds, draft.GetProperty("recipe").GetProperty("objectIds").GetArrayLength(), "réouverture sans troncature");
        var saved = await bridge.CallAsync("requetes.library.save", "{\"recipe\":" + json + ",\"expectedRevision\":0}");
        Check.Equal("result", saved.Kind, "même limite acceptée par la bibliothèque : " + saved.Error?.Message);
        var detail = SimulatedBridge.Json(await bridge.CallAsync("requetes.library.get", JsonSerializer.Serialize(new { id = recipe.Id })));
        Check.Equal(QueryLimits.MaxObjectIds, detail.GetProperty("recipe").GetProperty("objectIds").GetArrayLength(), "recette personnelle réouvrable intégralement");
        var oversized = recipe with { Clauses = [.. Enumerable.Range(0, 64).Select(_ => new QueryClause("name", QueryOperator.Contains, QueryValue.FromText(new string('x', 2000))))] };
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(oversized), "la sélection n’augmente pas le budget des conditions");
    }

    internal static QueryDataset Dataset(DirectoryComputer pc, WorkstationObservation? observation = null, ConsoleReading? console = null) =>
        new(Fixtures.Snapshot(computers: [pc]), observation is null ? FleetObservations.Empty : new(Fixtures.Now, [observation]),
            ImmutableDictionary<Guid, ImmutableArray<Domenia.Core.Queries.ProbeReading>>.Empty,
            console is null ? ImmutableDictionary<Guid, ConsoleReading>.Empty : ImmutableDictionary<Guid, ConsoleReading>.Empty.Add(pc.ObjectGuid, console),
            ImmutableDictionary<Guid, char>.Empty, ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "Cache local de test", false);
}
