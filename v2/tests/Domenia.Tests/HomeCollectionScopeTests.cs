using System.Text.Json;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using ProbeCatalog = Domenia.Core.Accueil.ProbeCatalog;

namespace Domenia.Tests;

internal static class HomeCollectionScopeTests
{
    [Test]
    public static async Task OU_plan_freezes_both_boards_active_probes_and_exact_query_revisions()
    {
        var bridge = new SimulatedBridge(); var service = AccueilService.From(bridge.Context);
        var session = await bridge.Source.GetSessionAsync(default);
        await WorkingScope.From(bridge.Context).SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, default);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Le scénario exige un domaine connu.");
        var library = RequetesServices.Library(bridge.Context);
        var saved = await library.SaveAsync(root, QueryRecipe.Empty() with { Name = "Mémoire du poste", Clauses = [new("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))] }, null, null, 0, "update", null, default);
        var binding = new BoardQueryBinding(QueryLibrary.RootKey(root), saved.Record.Id, 1, saved.Record.Fingerprint, 1, saved.Record.Name, false);
        var key = BoardQueryBindings.Key(binding);
        var active = ProbeCatalog.All[0].Id; var paused = ProbeCatalog.All[1].Id;
        await service.SaveLayoutAsync([new("home-probe", FleetWidgetSource.Probe, active, "Kpi", "S", null, false, "")], default);
        await PosteBoardLayouts.SaveAsync(bridge.Preferences, "Computer",
            [new("same", FleetWidgetSource.Probe, active, "Table", "M", null, false, ""),
             new("pause", FleetWidgetSource.Probe, paused, "Table", "M", null, true, ""),
             new("query", FleetWidgetSource.Query, key, "Verdict", "M", null, false, "") { QueryBinding = binding }], default);
        var first = await service.PlanRefreshAsync("inventory", default);
        Check.True(first.Probes.SequenceEqual([active]), "union dédupliquée des deux tableaux, pause exclue");
        Check.True(first.Stages.Any(s => s.Id == "queries"), "requête présente uniquement dans Poste réellement préparée");
        Check.True(first.Warnings.Any(w => w.Contains(saved.Record.Fingerprint[..12], StringComparison.Ordinal)), "révision exacte annoncée");
        await library.SaveAsync(root, saved.Record.Recipe with { Name = "Nouvelle version" }, null, null, 1, "update", null, default);
        var next = await service.PlanRefreshAsync("inventory", default);
        Check.True(next.Warnings.Any(w => w.Contains(saved.Record.Fingerprint[..12], StringComparison.Ordinal)), "la révision courante ne remplace pas le lien de Poste");
        await library.ArchiveAsync(root, saved.Record.Id, 2, default);
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => service.PlanRefreshAsync("inventory", default), "absence de révision active refuse tout plan");
        Check.Equal(AccueilService.RefreshQueryMissing, refused.Code, "raison explicite");
        Check.False((await service.PlanRefreshAsync("presence", default)).Stages.Any(s => s.Id == "queries"), "présence seule indépendante des widgets");
    }

    [Test]
    public static async Task Corrupt_computer_layout_blocks_inventory_without_affecting_presence_or_overwriting_it()
    {
        var bridge = new SimulatedBridge();
        var corrupt = JsonSerializer.SerializeToElement(new { broken = true });
        await bridge.Preferences.SetAsync(PosteBoardLayouts.PreferenceKey("Computer"), corrupt, default);
        var service = AccueilService.From(bridge.Context);
        Check.Equal("refresh.layoutInvalid", (await Check.ThrowsAsync<DomeniaOperationException>(() => service.PlanRefreshAsync("inventory", default), "plan partiel refusé")).Code, "disposition à corriger");
        _ = await service.PlanRefreshAsync("presence", default);
        Check.True(bridge.Preferences.TryGet(PosteBoardLayouts.PreferenceKey("Computer"), out var after), "original conservé");
        Check.Equal(corrupt.GetRawText(), after.GetRawText(), "aucune réparation silencieuse");
    }

    [Test]
    public static async Task Actual_catalog_exposes_documented_metadata_and_import_refusal_is_traced_without_document_contents()
    {
        var bridge = new SimulatedBridge(); var service = AccueilService.From(bridge.Context);
        var catalog = await service.CatalogAsync(default);
        foreach (var p in catalog.Probes.SelectMany(c => c.Probes))
        {
            var definition = ProbeCatalog.Find(p.Id)!;
            Check.Equal(definition.Class, p.Class, "classe reçue par le catalogue réel");
            Check.Equal(definition.Description, p.Description, "description intégrale");
            Check.Equal(definition.Compatibility, p.Compatibility, "compatibilité intégrale");
            Check.True(ProbeCatalog.Contract(definition).Lines.Any(l => l.Section == "Compatibilité" && l.Value == p.Compatibility), "contrat détaillé raccordé");
        }
        var before = (await service.PersonalProbeCatalogAsync(default)).ChoiceToken;
        const string marker = "DECLARATION_PRIVATE_FIXTURE";
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.PreviewPersonalProbesAsync("{\"unknown\":\"" + marker + "\"}", before, default), "déclaration refusée");
        Check.Equal(1, bridge.Log.Lines.Count(l => l.Contains("Import de sondes refusé", StringComparison.Ordinal)), "un refus au journal, pas un catalogue tronqué");
        Check.False(bridge.Log.Lines.Any(l => l.Contains(marker, StringComparison.Ordinal)), "texte importé absent du journal");
        Check.Equal(before, (await service.PersonalProbeCatalogAsync(default)).ChoiceToken, "catalogue inchangé");
    }
}
