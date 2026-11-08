using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class CollectionAdmissionTests
{
    private static Task Settings(EngineContext context, int maximum, int widget = 0, string window = "toujours") =>
        context.Preferences.SetAsync(CollectionSettingsRules.PreferenceKey, JsonSerializer.SerializeToElement(new
        { maxTargets = maximum, widgetMax = widget, windows = new { standard = window } }), default);

    [Test]
    public static async Task Home_and_widgets_refuse_whole_populations_and_recheck_a_lowered_ceiling_before_contact()
    {
        var source = new HomePipelineSource(); using var context = source.Context();
        var home = AccueilService.From(context);
        await home.SaveLayoutAsync([new("presence", FleetWidgetSource.Builtin, "fleet.lastcheck", "Kpi", "S", null, false, "")], default);
        await Settings(context, 1);
        Check.Equal(CollectionAdmission.Ceiling, (await Check.ThrowsAsync<DomeniaOperationException>(
            () => home.PlanRefreshAsync("presence", default), "aucune sélection arbitraire sur deux postes")).Code, "plafond général Accueil");
        Check.Equal("widget.ceiling", (await Check.ThrowsAsync<DomeniaOperationException>(
            () => home.PlanWidgetCollectionAsync("presence", "add", default), "widget0 hérite du plafond général")).Code, "garde du widget");
        await Settings(context, 2, 1);
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.PlanWidgetCollectionAsync("presence", "add", default), "borne widget plus petite");
        await Settings(context, 2, 0);
        var widget = await home.PlanWidgetCollectionAsync("presence", "add", default);
        var campaign = await home.PlanRefreshAsync("presence", default);
        Check.Equal(2, widget.Targets, "borne exacte autorisée sans rognage");
        await Settings(context, 1);
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(widget.Id, true, default), "paramètres revérifiés après attente");
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunRefreshAsync(campaign.Id, false, _ => { }, default), "campagne revérifiée");
        Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "aucun contact après refus");
    }

    [Test]
    public static async Task Directory_growth_cannot_bypass_the_confirmed_campaign_ceiling()
    {
        var source = new HomePipelineSource(); using var context = source.Context();
        source.AfterDirectory = source.Current.Directory with { Computers = [.. source.Current.Directory.Computers, Fixtures.Computer("PC3")] };
        await Settings(context, 2);
        var home = AccueilService.From(context);
        var plan = await home.PlanRefreshAsync("all", default);
        var report = await home.RunRefreshAsync(plan.Id, false, _ => { }, default);
        Check.True(report.Status != "success", "agrandissement refusé après reçu AD");
        Check.Equal(3, source.Current.Directory.Computers.Length, "annuaire reçu conservé intégralement");
        Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "aucun poste au-delà du plan contacté");
    }

    [Test]
    public static async Task Two_hundred_and_one_targets_require_confirmation_even_with_widget_limit_disabled()
    {
        var source = new HomePipelineSource();
        source.Current = source.Current with { Directory = source.Current.Directory with
        { Computers = [.. Enumerable.Range(0, 201).Select(i => Fixtures.Computer("PC" + i))] } };
        using var context = source.Context(); await Settings(context, 201);
        var home = AccueilService.From(context);
        await home.SaveLayoutAsync([new("presence", FleetWidgetSource.Builtin, "fleet.lastcheck", "Kpi", "S", null, false, "")], default);
        var plan = await home.PlanWidgetCollectionAsync("presence", "add", default);
        Check.Equal(201, plan.Targets, "population intégrale"); Check.True(plan.ConfirmationRequired, "confirmation indépendante du plafond widget");
        Check.Equal("widget.confirmation", (await Check.ThrowsAsync<DomeniaOperationException>(
            () => home.RunWidgetCollectionAsync(plan.Id, false, default), "confirmation obligatoire")).Code, "garde moteur");
        Check.Equal(0, source.PresenceCalls, "aucun envoi");
    }

    [Test]
    public static async Task Workshop_plan_uses_global_ceiling_and_honest_effective_concurrency_then_rechecks_admission()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        var ou = await RequetesOperationsTests.WorkstationsOuAsync(bridge);
        _ = SimulatedBridge.Json(await bridge.CallAsync("requetes.scope.set", JsonSerializer.Serialize(new { dn = ou, subtree = true })));
        var recipe = QueryRecipeJson.Write(QueryTemplates.Find("template.active.lowdisk")!.Recipe);
        var args = "{\"recipe\":" + recipe + ",\"cacheMinutes\":0}";
        await Settings(context, 1000);
        await context.Preferences.SetAsync(CollectionSettingsRules.PreferenceKey, JsonSerializer.SerializeToElement(new { maxTargets = 1000, concurrency = 8 }), default);
        var first = SimulatedBridge.Json(await bridge.CallAsync("requetes.collect.plan", args));
        var plan = first.GetProperty("plan");
        Check.True(plan.GetProperty("targets").GetArrayLength() > 1, "population de fixture suffisante pour la limite");
        Check.Equal(8, plan.GetProperty("configuredConcurrency").GetInt32(), "préférence effectivement lue");
        Check.Equal(1, plan.GetProperty("effectiveConcurrency").GetInt32(), "Atelier séquentiel déclaré");
        await Settings(context, 1);
        Check.Equal(CollectionAdmission.Ceiling, (await bridge.CallAsync("requetes.collect.run", JsonSerializer.Serialize(new
        { ticket = first.GetProperty("ticket").GetString(), confirmed = true }))).Error?.Code, "garde avant lecture du plan devenu trop grand");
        Check.Equal(CollectionAdmission.Ceiling, (await bridge.CallAsync("requetes.collect.plan", args)).Error?.Code, "nouveau plan refusé sans troncature");
        await Settings(context, 1000, window: "jamais");
        var closed = SimulatedBridge.Json(await bridge.CallAsync("requetes.collect.plan", args));
        Check.True(closed.GetProperty("plan").GetProperty("confirmationRequired").GetBoolean(), "fenêtre fermée signalée");
        Check.Equal("collection.confirmation", (await bridge.CallAsync("requetes.collect.run", JsonSerializer.Serialize(new
        { ticket = closed.GetProperty("ticket").GetString() }))).Error?.Code, "absence de confirmation ne contacte rien");
    }

    [Test]
    public static async Task Closed_window_stops_automatic_reconciliation_but_allows_explicit_gestures_with_notice()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        var list = SimulatedBridge.Json(await bridge.CallAsync("search.run", "{\"text\":\"PC\"}"));
        await Settings(context, 500, window: "jamais");
        var id = list.GetProperty("listId").GetString();
        Check.Equal(CollectionAdmission.WindowClosed, (await bridge.CallAsync("search.reconcile", JsonSerializer.Serialize(new { listId = id, background = true }))).Error?.Code, "premier passage automatique complet suspendu");
        Check.Equal(CollectionAdmission.WindowClosed, (await bridge.CallAsync("search.reconcile", JsonSerializer.Serialize(new { listId = id, background = true, incremental = true }))).Error?.Code, "delta suspendu également");
        Check.True((await bridge.CallAsync("search.reconcile", JsonSerializer.Serialize(new { listId = id }))).Error is null, "geste explicite autorisé");
        Check.Equal(CollectionAdmission.WindowClosed, (await bridge.CallAsync("search.revalidate", JsonSerializer.Serialize(new { ids = new[] { Guid.NewGuid() } }))).Error?.Code, "revalidation automatique suspendue avant lecteur");
        var source = new HomePipelineSource(); using var homeContext = source.Context(); await Settings(homeContext, 500, window: "jamais");
        var home = AccueilService.From(homeContext);
        await home.SaveLayoutAsync([new("presence", FleetWidgetSource.Builtin, "fleet.lastcheck", "Kpi", "S", null, false, "")], default);
        var widget = await home.PlanWidgetCollectionAsync("presence", "add", default);
        Check.True(widget.ConfirmationRequired, "fenêtre fermée impose confirmation même sous200");
        Check.Contains("confirmation", widget.Detail, "avis fenêtre dans le plan");
        var campaign = await home.PlanRefreshAsync("presence", default);
        Check.True(campaign.Warnings.Any(w => w.Contains("confirmation", StringComparison.Ordinal)), "campagne explicite avertie");
    }
}
