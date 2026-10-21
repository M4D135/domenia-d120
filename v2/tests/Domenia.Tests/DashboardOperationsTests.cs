using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class DashboardOperationsTests
{
    private const string Utc = "yyyy-MM-ddTHH:mm:ssZ";

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static void SameNames(JsonElement element, string[] expected, string what) =>
        Check.True(Names(element).SequenceEqual(expected), $"propriétés de {what} : {string.Join(",", Names(element))}");

    private static void IsUtcSecond(JsonElement element, string what)
    {
        var text = element.GetString();
        Check.True(text is not null && text.Length == Utc.Length && text.EndsWith('Z')
            && DateTimeOffset.TryParseExact(text, "yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out _), "date UTC à la seconde : " + what);
    }

    [Test]
    public static async Task Summary_returns_the_ten_widgets_with_the_figures_of_the_contract()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        var widgets = json.GetProperty("widgets");
        SameNames(widgets, [.. WidgetCatalog.All.Select(w => w.Id)], "widgets");
        var online = widgets.GetProperty("workstationsOnline").GetProperty("data");
        Check.Equal(287, online.GetProperty("value").GetInt32(), "en ligne");
        Check.Equal(412, online.GetProperty("total").GetInt32(), "postes");
        Check.Equal(1186, widgets.GetProperty("activeAccounts").GetProperty("data").GetProperty("value").GetInt32(), "comptes actifs");
        Check.Equal(72, widgets.GetProperty("activeAccounts").GetProperty("data").GetProperty("breakdown")[1].GetProperty("value").GetInt32(), "désactivés");
        Check.Equal(7, widgets.GetProperty("lockedAccounts").GetProperty("data").GetProperty("value").GetInt32(), "verrouillés");
        var passwords = widgets.GetProperty("passwordsExpiring").GetProperty("data");
        Check.Equal(23, passwords.GetProperty("value").GetInt32(), "expirants");
        int[] passwordParts = [.. passwords.GetProperty("breakdown").EnumerateArray().Select(b => b.GetProperty("value").GetInt32())];
        Check.True(passwordParts.SequenceEqual([23, 11, 4, 16]), "ventilation des mots de passe");
        var disks = widgets.GetProperty("diskAlerts").GetProperty("data");
        int[] diskParts = [.. disks.GetProperty("breakdown").EnumerateArray().Select(b => b.GetProperty("value").GetInt32())];
        Check.Equal(9, disks.GetProperty("value").GetInt32(), "alertes disque");
        Check.True(diskParts.SequenceEqual([9, 17, 345, 41]), "ventilation des disques");
        var segments = widgets.GetProperty("osDistribution").GetProperty("data").GetProperty("segments");
        string[] keys = [.. segments.EnumerateArray().Select(s => s.GetProperty("key").GetString()!)];
        int[] values = [.. segments.EnumerateArray().Select(s => s.GetProperty("value").GetInt32())];
        double[] percents = [.. segments.EnumerateArray().Select(s => s.GetProperty("percent").GetDouble())];
        Check.True(keys.SequenceEqual(["w11-24h2", "w11-23h2", "w11-25h2", "w10-22h2", "autres"]), "segments : " + string.Join(",", keys));
        Check.True(values.SequenceEqual([223, 96, 58, 23, 12]), "valeurs des segments");
        Check.True(percents.SequenceEqual([54.1, 23.3, 14.1, 5.6, 2.9]), "pourcentages des segments");
        Check.Equal("Windows 10 LTSC 2021", segments[4].GetProperty("members")[0].GetString(), "membres de « autres »");
        var freshness = widgets.GetProperty("measureFreshness").GetProperty("data");
        Check.Equal(84.0, freshness.GetProperty("percent").GetDouble(), "fraîcheur");
        Check.Equal(346, freshness.GetProperty("fresh").GetInt32(), "récents");
        Check.Equal(63, widgets.GetProperty("watchlist").GetProperty("data").GetProperty("total").GetInt32(), "postes à surveiller");
        Check.Equal(287, widgets.GetProperty("workstationActivity").GetProperty("data").GetProperty("points")[6].GetProperty("value").GetInt32(), "activité du jour");
        Check.Equal(14, widgets.GetProperty("recentOperations").GetProperty("data").GetProperty("total").GetInt32(), "journal fictif");
        Check.Equal(1826, json.GetProperty("store").GetProperty("objects").GetInt32(), "objets de la base");
    }

    [Test]
    public static async Task Json_names_dates_and_nulls_follow_the_contract()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        SameNames(json, ["generatedAt", "scope", "store", "widgets"], "dashboard.summary");
        IsUtcSecond(json.GetProperty("generatedAt"), "generatedAt");
        SameNames(json.GetProperty("scope"), ["dn", "label", "subtree"], "scope");
        SameNames(json.GetProperty("store"), ["lastReadAt", "objects", "complete"], "store");
        string[] common = ["id", "kind", "title", "scopeLabel", "enabled", "tone", "measuredAt", "stale", "detail", "data"];
        foreach (var widget in json.GetProperty("widgets").EnumerateObject())
        {
            SameNames(widget.Value, common, widget.Name);
            IsUtcSecond(widget.Value.GetProperty("measuredAt"), widget.Name);
        }
        var widgets = json.GetProperty("widgets");
        SameNames(widgets.GetProperty("lockedAccounts").GetProperty("data"), ["value", "total", "unit", "delta", "history", "breakdown"], "kpi");
        Check.Equal(JsonValueKind.Null, widgets.GetProperty("lockedAccounts").GetProperty("data").GetProperty("total").ValueKind, "total nul écrit");
        SameNames(widgets.GetProperty("lockedAccounts").GetProperty("data").GetProperty("delta"), ["value", "period", "label", "tone"], "delta");
        SameNames(widgets.GetProperty("lockedAccounts").GetProperty("data").GetProperty("history")[0], ["date", "value"], "history");
        Check.Equal(10, widgets.GetProperty("lockedAccounts").GetProperty("data").GetProperty("history")[0].GetProperty("date").GetString()!.Length, "date seule");
        SameNames(widgets.GetProperty("lockedAccounts").GetProperty("data").GetProperty("breakdown")[0], ["key", "label", "value", "tone"], "breakdown");
        SameNames(widgets.GetProperty("osDistribution").GetProperty("data"), ["total", "unit", "centerText", "segments", "lead"], "distribution");
        SameNames(widgets.GetProperty("osDistribution").GetProperty("data").GetProperty("segments")[0], ["key", "label", "value", "percent", "members"], "segment");
        SameNames(widgets.GetProperty("workstationActivity").GetProperty("data"), ["unit", "max", "points"], "series");
        SameNames(widgets.GetProperty("workstationActivity").GetProperty("data").GetProperty("points")[0], ["date", "label", "value", "partial"], "point");
        SameNames(widgets.GetProperty("measureFreshness").GetProperty("data"), ["percent", "fresh", "total", "freshDays", "breakdown"], "gauge");
        SameNames(widgets.GetProperty("watchlist").GetProperty("data"), ["total", "shown", "rows"], "list");
        SameNames(widgets.GetProperty("watchlist").GetProperty("data").GetProperty("rows")[0],
            ["name", "dn", "objectGuid", "ruleId", "reason", "severity", "otherReasons", "lastSeenAt"], "ligne de la liste");
        Check.Equal("lowDisk", widgets.GetProperty("watchlist").GetProperty("data").GetProperty("rows")[0].GetProperty("ruleId").GetString(), "énumération camelCase");
        SameNames(widgets.GetProperty("recentOperations").GetProperty("data").GetProperty("rows")[0], ["label", "at", "tone"], "ligne du journal");
        Check.Equal("kpi", widgets.GetProperty("lockedAccounts").GetProperty("kind").GetString(), "kind camelCase");
        Check.Equal("alert", widgets.GetProperty("lockedAccounts").GetProperty("tone").GetString(), "tone camelCase");
        Check.Equal("OU Postes", widgets.GetProperty("diskAlerts").GetProperty("scopeLabel").GetString(), "périmètre OU");
        Check.Equal("Domaine example.local", widgets.GetProperty("lockedAccounts").GetProperty("scopeLabel").GetString(), "périmètre domaine");
    }

    [Test]
    public static async Task Session_info_has_the_contract_shape_and_tracks_the_first_summary()
    {
        var bridge = new SimulatedBridge();
        var before = SimulatedBridge.Json(await bridge.CallAsync("session.info", "null"));
        SameNames(before, ["connection", "domain", "controller", "account", "authentication", "scope", "rights", "readOnly", "tasks", "cache", "onboarding"], "session.info");
        Check.Equal("simulated", before.GetProperty("connection").GetProperty("state").GetString(), "état simulé");
        Check.Equal("Annuaire simulé", before.GetProperty("connection").GetProperty("label").GetString(), "libellé");
        Check.Equal(@"EXAMPLE\j.martin", before.GetProperty("account").GetProperty("login").GetString(), "compte");
        Check.Equal("Julien", before.GetProperty("account").GetProperty("givenName").GetString(), "prénom");
        Check.Equal(JsonValueKind.Null, before.GetProperty("authentication").GetProperty("protocol").ValueKind, "protocole nul écrit");
        Check.Equal("none", before.GetProperty("authentication").GetProperty("method").GetString(), "aucune authentification");
        Check.True(before.GetProperty("readOnly").GetBoolean(), "lecture seule");
        Check.Equal("fresh", before.GetProperty("cache").GetProperty("state").GetString(), "base à jour");
        Check.Equal(1826, before.GetProperty("cache").GetProperty("objects").GetInt32(), "objets");
        Check.Equal(3, before.GetProperty("onboarding").GetProperty("completed").GetInt32(), "trois étapes faites");
        Check.False(before.GetProperty("onboarding").GetProperty("steps")[3].GetProperty("done").GetBoolean(), "tableau de bord pas encore vu");

        _ = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        var after = SimulatedBridge.Json(await bridge.CallAsync("session.info"));
        Check.Equal("dashboard", after.GetProperty("onboarding").GetProperty("steps")[3].GetProperty("id").GetString(), "quatrième étape");
        Check.True(after.GetProperty("onboarding").GetProperty("steps")[3].GetProperty("done").GetBoolean(), "tableau de bord vu");
        Check.Equal(4, after.GetProperty("onboarding").GetProperty("completed").GetInt32(), "quatre étapes faites");
    }

    [Test]
    public static async Task Refresh_and_set_enabled_validate_their_arguments()
    {
        var bridge = new SimulatedBridge();
        Check.Equal("widget.unknown", (await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"everything\"}")).Error!.Code, "widget inconnu");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("dashboard.widget.refresh", "{}")).Error!.Code, "id absent");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":3}")).Error!.Code, "id non texte");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"diskAlerts\",\"scope\":\"DC=example,DC=local\"}")).Error!.Code, "propriété en trop");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("dashboard.widget.refresh", "[\"diskAlerts\"]")).Error!.Code, "args non objet");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"diskAlerts\",\"id\":\"watchlist\"}")).Error!.Code, "propriété en double");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"diskAlerts\",\"enabled\":\"non\"}")).Error!.Code, "enabled non booléen");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("dashboard.summary", "{\"x\":1}")).Error!.Code, "aucun argument admis");
        var unknown = await bridge.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"nope\",\"enabled\":false}");
        Check.Equal("widget.unknown", unknown.Error!.Code, "widget inconnu");
        Check.Equal(DomeniaErrors.WidgetUnknownChangeMessage, unknown.Error.Message, "rien n’a été changé");
        Check.Equal("operation.unknown", (await bridge.CallAsync("dashboard.widget.delete", "{}")).Error!.Code, "opération inconnue");
    }

    [Test]
    public static async Task Disabled_widget_is_refused_without_any_round()
    {
        var bridge = new SimulatedBridge();
        _ = SimulatedBridge.Json(await bridge.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"workstationsOnline\",\"enabled\":false}"));
        var refused = await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"workstationsOnline\"}");
        Check.Equal("widget.disabled", refused.Error!.Code, "widget désactivé");
        Check.Equal(0, bridge.Source.PresenceRound, "aucune manche de présence");
    }

    [Test]
    public static async Task Set_enabled_keeps_the_widget_on_the_board_and_is_idempotent()
    {
        var bridge = new SimulatedBridge();
        _ = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        var off = SimulatedBridge.Json(await bridge.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"lockedAccounts\",\"enabled\":false}"));
        Check.False(off.GetProperty("enabled").GetBoolean(), "désactivé");
        Check.Equal(JsonValueKind.Null, off.GetProperty("data").ValueKind, "data nul");
        Check.Equal("off", off.GetProperty("tone").GetString(), "ton off");
        Check.Equal(JsonValueKind.Null, off.GetProperty("measuredAt").ValueKind, "measuredAt nul");

        var summary = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        var locked = summary.GetProperty("widgets").GetProperty("lockedAccounts");
        Check.Equal(JsonValueKind.Null, locked.GetProperty("data").ValueKind, "toujours au tableau, sans données");
        var journalBefore = summary.GetProperty("widgets").GetProperty("recentOperations").GetProperty("data").GetProperty("total").GetInt32();

        _ = SimulatedBridge.Json(await bridge.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"lockedAccounts\",\"enabled\":false}"));
        var again = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        Check.Equal(journalBefore, again.GetProperty("widgets").GetProperty("recentOperations").GetProperty("data").GetProperty("total").GetInt32(), "deuxième appel identique : aucune entrée de journal");

        var on = SimulatedBridge.Json(await bridge.CallAsync("dashboard.widget.setEnabled", "{\"id\":\"lockedAccounts\",\"enabled\":true}"));
        Check.True(on.GetProperty("enabled").GetBoolean(), "réactivé");
        Check.Equal(7, on.GetProperty("data").GetProperty("value").GetInt32(), "rétabli depuis le dernier état connu");
    }

    [Test]
    public static async Task Presence_rounds_are_identical_for_two_fresh_sources()
    {
        var clockA = TestClock.Fixed();
        var clockB = TestClock.Fixed();
        var a = new SimulatedBridge(clock: clockA);
        var b = new SimulatedBridge(clock: clockB);
        for (var round = 1; round <= 5; round++)
        {
            clockA.Advance(TimeSpan.FromMinutes(1));
            clockB.Advance(TimeSpan.FromMinutes(1));
            var first = SimulatedBridge.Json(await a.CallAsync("dashboard.widget.refresh", "{\"id\":\"workstationsOnline\"}"));
            var second = SimulatedBridge.Json(await b.CallAsync("dashboard.widget.refresh", "{\"id\":\"workstationsOnline\"}"));
            Check.Equal(first.GetRawText(), second.GetRawText(), "même manche " + round);
            Check.Equal(clockA.GetUtcNow().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture), first.GetProperty("measuredAt").GetString(), "measuredAt = horloge injectée");
            var data = first.GetProperty("data");
            var notChecked = data.GetProperty("breakdown")[2].GetProperty("value").GetInt32();
            Check.Equal(3, notChecked, "seules les sondes en erreur restent non vérifiées");
            var value = data.GetProperty("value").GetInt32();
            Check.True(value >= 287 - 6 && value <= 287 + 6, "manche proche de la cible");
        }
        Check.Equal(5, a.Source.PresenceRound, "cinq manches");
    }

    [Test]
    public static async Task Cancellation_during_a_simulated_wait_answers_cancelled()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));
        var response = await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"diskAlerts\"}", cancellation.Token);
        Check.Equal("operation.cancelled", response.Error!.Code, "opération annulée");
        Check.Equal(0, bridge.Source.PresenceRound, "rien n’a changé");
    }

    [Test]
    public static async Task Directory_mode_without_ad_answers_unavailable_but_keeps_the_session()
    {
        var clock = TestClock.Fixed();
        using var service = new DashboardService(new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun"), new OperationJournal(), clock);
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(new OperationRegistry(DashboardOperations.Create(service)), sent.Add);
        await dispatcher.HandleAsync("{\"id\":\"a\",\"op\":\"dashboard.summary\",\"args\":{}}", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent[^1].Error!.Code, "résumé indisponible");
        await dispatcher.HandleAsync("{\"id\":\"b\",\"op\":\"dashboard.widget.refresh\",\"args\":{\"id\":\"lockedAccounts\"}}", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent[^1].Error!.Code, "actualisation indisponible");
        await dispatcher.HandleAsync("{\"id\":\"c\",\"op\":\"session.info\"}", CancellationToken.None);
        var session = SimulatedBridge.Json(sent[^1]);
        Check.Equal("disconnected", session.GetProperty("connection").GetProperty("state").GetString(), "non connecté");
        Check.Equal("Annuaire non connecté", session.GetProperty("connection").GetProperty("label").GetString(), "libellé");
        Check.Equal("cnamts.local", session.GetProperty("domain").GetProperty("dnsName").GetString(), "domaine de jonction");
        Check.Equal(JsonValueKind.Null, session.GetProperty("controller").ValueKind, "contrôleur inconnu");
        Check.Equal("empty", session.GetProperty("cache").GetProperty("state").GetString(), "base vide");
        Check.Equal(0, session.GetProperty("onboarding").GetProperty("completed").GetInt32(), "aucune étape");
    }

    [Test]
    public static async Task Simulation_guard_refuses_writes_and_unserved_network_reads_before_their_handler()
    {
        var ran = 0;
        var sent = new List<BridgeResponse>();
        var registry = new OperationRegistry(
        [
            new OperationDefinition("test.write", OperationClass.Write, (_, _, _) =>
            {
                ran++;
                return Task.FromResult<object?>(null);
            }, "écriture de test", ServedInSimulation: true),
            new OperationDefinition("test.remote", OperationClass.NetworkRead, (_, _, _) =>
            {
                ran++;
                return Task.FromResult<object?>(null);
            }, "outil distant de test"),
            new OperationDefinition("test.read", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(1), "lecture servie de test", ServedInSimulation: true),
            new OperationDefinition("test.local", OperationClass.LocalRead, (_, _, _) => Task.FromResult<object?>(2), "lecture locale de test"),
        ]);
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Simulation));
        await dispatcher.HandleAsync("{\"id\":\"w\",\"op\":\"test.write\",\"args\":{}}", CancellationToken.None);
        Check.Equal(DomeniaErrors.SimulationReadOnly, sent[^1].Error!.Code, "écriture refusée, même marquée servie");
        await dispatcher.HandleAsync("{\"id\":\"n\",\"op\":\"test.remote\",\"args\":{}}", CancellationToken.None);
        Check.Equal(DomeniaErrors.SimulationUnavailable, sent[^1].Error!.Code, "outil distant non servi : indisponible");
        Check.Equal(DomeniaErrors.SimulationUnavailableMessage, sent[^1].Error!.Message, "message du contrat");
        Check.Equal(0, ran, "gestionnaires jamais appelés");
        await dispatcher.HandleAsync("{\"id\":\"r\",\"op\":\"test.read\",\"args\":{}}", CancellationToken.None);
        Check.Equal("result", sent[^1].Kind, "lecture servie par la simulation admise");
        await dispatcher.HandleAsync("{\"id\":\"l\",\"op\":\"test.local\",\"args\":{}}", CancellationToken.None);
        Check.Equal("result", sent[^1].Kind, "lecture locale admise");
        var home = DashboardOperations.Create(new SimulatedBridge().Service);
        Check.True(home.Where(d => d.Class == OperationClass.NetworkRead).All(d => d.ServedInSimulation), "lectures réseau de l’Accueil servies par la simulation");
        Check.Null(AdmissionGuards.For(AppMode.Directory), "aucune garde en mode annuaire");
    }

    [Test]
    public static async Task Summary_overlapping_a_refresh_never_restores_an_older_state()
    {
        var clock = TestClock.Fixed();
        var gated = new GatedReadSource(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock));
        using var service = new DashboardService(gated, new OperationJournal(), clock);
        // The summary captures the state of round 0, then waits while a presence round completes.
        var summary = service.GetSummaryAsync(CancellationToken.None);
        await gated.ReadCaptured.Task.ConfigureAwait(false);
        clock.Advance(TimeSpan.FromMinutes(2));
        var refreshed = await service.RefreshAsync(WidgetCatalog.WorkstationsOnline, CancellationToken.None).ConfigureAwait(false);
        gated.Release.SetResult();
        var old = (await summary.ConfigureAwait(false)).Widgets[WidgetCatalog.WorkstationsOnline];
        Check.True(old.MeasuredAt < refreshed.MeasuredAt, "le résumé porte l’état d’avant la manche");
        await service.SetEnabledAsync(WidgetCatalog.WorkstationsOnline, false, CancellationToken.None).ConfigureAwait(false);
        var again = await service.SetEnabledAsync(WidgetCatalog.WorkstationsOnline, true, CancellationToken.None).ConfigureAwait(false);
        Check.Equal(refreshed.MeasuredAt, again.MeasuredAt, "réactivation depuis la dernière manche");
        Check.Equal(JsonSerializer.Serialize(refreshed.Data, BridgeJson.Options), JsonSerializer.Serialize(again.Data, BridgeJson.Options), "mêmes valeurs que l’actualisation");
    }

    [Test]
    public static async Task Local_widget_refresh_waits_the_delay_of_a_measure()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        // Generated beforehand: only the simulated wait is timed.
        _ = bridge.Source.World;
        using (var early = new CancellationTokenSource(TimeSpan.FromMilliseconds(300)))
        {
            var cancelled = await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"watchlist\"}", early.Token);
            Check.Equal("operation.cancelled", cancelled.Error?.Code, "calcul local : 400 à 900 ms, pas 120 à 250 ms");
        }
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var done = await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"recentOperations\"}");
        watch.Stop();
        Check.Equal("result", done.Kind, "calcul local servi");
        Check.True(watch.ElapsedMilliseconds >= 380, "délai d’une actualisation : " + watch.ElapsedMilliseconds + " ms");
        Check.Equal(0, bridge.Source.PresenceRound, "aucune manche pour un calcul local");
    }
}
