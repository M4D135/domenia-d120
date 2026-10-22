using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Accueil (docs/ops/accueil.md): fleet catalog, end of service, health rules and their JSON, collection clocks, probes,
/// and the accueil.* operations over the simulated directory (board, exact sets, layout, refresh, health, favourites,
/// first steps, analysis, BitLocker, tools). Written with the code; run at the very end (decision of 21/10).
/// </summary>
internal static class AccueilTests
{
    private const string Domain = "DC=example,DC=local";
    private const string Postes = "OU=Postes," + Domain;
    private static readonly DateOnly Today = new(2026, 10, 21);

    // ---------------------------------------------------------------- catalog

    [Test]
    public static void Fleet_catalog_holds_the_34_widgets_of_Domenia_1()
    {
        Check.Equal(34, FleetCatalog.All.Length, "widgets du catalogue");
        Check.Equal(34, FleetCatalog.All.Select(w => w.Key).Distinct(StringComparer.Ordinal).Count(), "clés uniques");
        Check.Equal(7, FleetCatalog.Groups.Length, "sections");
        var layout = FleetCatalog.DefaultLayout();
        Check.True(layout.All(i => FleetCatalog.TryGet(i.Key, out var d) && d.Default), "disposition livrée : widgets livrés seulement");
        Check.Equal(FleetCatalog.All.Count(w => w.Default), layout.Length, "tous les widgets livrés");
        Check.Equal("Santé", layout[^1].Group, "la santé vient après l’inventaire");
        Check.True(FleetCatalog.IsDefault(layout), "disposition livrée reconnue");
        Check.False(FleetCatalog.IsDefault([.. layout.Skip(1)]), "disposition changée reconnue");
    }

    [Test]
    public static void Representations_follow_the_kind_of_data()
    {
        Check.True(FleetCatalog.VisualsFor(FleetDataKind.Value).SequenceEqual(["Kpi", "Text"]), "valeur");
        Check.True(FleetCatalog.VisualsFor(FleetDataKind.Timeline).SequenceEqual(["Line", "Column", "Text"]), "évolution");
        Check.Equal("Kpi", FleetCatalog.ResolveVisual("Line", FleetDataKind.Value), "une valeur n’est jamais une courbe");
        Check.Equal("Bar", FleetCatalog.ResolveVisual("Bar", FleetDataKind.Distribution), "représentation admise gardée");
        Check.Equal("Pie", FleetCatalog.ResolveVisual(null, FleetDataKind.Distribution), "défaut de la répartition");
        Check.True(FleetCatalog.IsSize("S") && FleetCatalog.IsSize("L") && !FleetCatalog.IsSize("XL"), "tailles");
    }

    [Test]
    public static void A_preset_puts_its_widgets_first_and_adds_the_missing_ones()
    {
        var layout = FleetCatalog.ApplyPreset("support", FleetCatalog.DefaultLayout());
        Check.Equal("fleet.attention", layout[0].Key, "points d’attention en tête");
        Check.True(layout.Any(i => i.Key == "fleet.presence"), "présence réseau ajoutée");
        Check.Throws<ArgumentException>(() => FleetCatalog.ApplyPreset("inconnu", FleetCatalog.DefaultLayout()), "disposition inconnue");
    }

    // ---------------------------------------------------------------- end of service

    [Test]
    public static void End_of_service_of_Windows_releases()
    {
        Check.Equal("19045", WindowsLifecycle.BuildOf("10.0 (19045)"), "build entre parenthèses");
        Check.Equal("19045", WindowsLifecycle.BuildOf("10.0.19045"), "build pointé");
        Check.Equal("", WindowsLifecycle.BuildOf("inconnu"), "build absent");
        var ended = WindowsLifecycle.Evaluate("10.0 (19045)", "Windows 10 Entreprise", Today);
        Check.Equal(LifecycleStatus.Ended, ended.Status, "Windows 10 22H2 terminé");
        Check.Equal("Windows 10 22H2 Entreprise", ended.Label, "libellé avec l’édition");
        Check.Equal(LifecycleStatus.Soon, WindowsLifecycle.Evaluate("22631", "Windows 11 Entreprise", Today).Status, "23H2 Entreprise : moins de 90 jours");
        Check.Equal(LifecycleStatus.Soon, WindowsLifecycle.Evaluate("19044", "Windows 10 Enterprise LTSC 2021", Today).Status, "LTSC 2021 : 83 jours");
        Check.Equal(LifecycleStatus.Ok, WindowsLifecycle.Evaluate("26100", "Windows 11 Entreprise", Today).Status, "24H2 Entreprise maintenu");
        Check.Equal(LifecycleStatus.Ended, WindowsLifecycle.Evaluate("26100", "Windows 11 Professionnel", Today).Status, "24H2 Pro terminé le 13/10/2026");
        Check.Equal(WindowsFamily.Server, WindowsLifecycle.FamilyOf("Windows Server 2022 Standard"), "famille serveur");
    }

    // ---------------------------------------------------------------- health rules

    [Test]
    public static void Health_rules_refuse_incoherent_thresholds()
    {
        Check.Equal(25, HealthRules.Catalog.Length, "25 contrôles");
        var bad = HealthPolicy.Default with { Thresholds = HealthThresholds.Default.With("DiskFreeAlert", 30) };
        var error = Check.Throws<DomeniaOperationException>(() => HealthRules.Validate(bad), "disque critique au-dessus du seuil de surveillance");
        Check.Equal(HealthRules.InvalidCode, error.Code, "code health.invalid");
        Check.Equal(HealthPolicy.Default.Thresholds, HealthRules.Validate(HealthPolicy.Default).Thresholds, "politique par défaut valide");
    }

    [Test]
    public static void An_OU_keeps_only_its_differences_and_its_children_inherit_them()
    {
        var now = TestClock.Reference;
        var paris = "OU=Paris," + Postes;
        var book = HealthPolicyBook.Empty(Domain);
        var policy = HealthPolicy.Default with { Thresholds = HealthThresholds.Default.With("StaleDays", 45) };
        var next = HealthRules.SetScopePolicy(book, Postes, policy, now);
        Check.Equal(45, HealthRules.Resolve(next, Postes).Policy.Thresholds.StaleDays, "seuil de l’OU");
        Check.True(HealthRules.Resolve(next, Postes).Local, "exception locale");
        var child = HealthRules.Resolve(next, paris);
        Check.Equal(45, child.Policy.Thresholds.StaleDays, "hérité par la sous-OU");
        Check.False(child.Local, "la sous-OU n’a pas d’exception");
        Check.Equal(90, HealthRules.Resolve(next, null).Policy.Thresholds.StaleDays, "domaine inchangé");
        Check.Equal(1, HealthRules.Exceptions(next, now).Length, "une exception listée");
        Check.Equal(90, HealthRules.Resolve(HealthRules.RemoveScope(next, Postes), Postes).Policy.Thresholds.StaleDays, "retour aux règles héritées");
    }

    [Test]
    public static void A_suspension_ends_by_itself_and_can_be_ended_now()
    {
        var now = TestClock.Reference;
        var policy = HealthPolicy.Default with { Suspensions = [new HealthSuspension("uptime", "Campagne de redémarrage", now.AddHours(24))] };
        Check.Equal(HealthRuleState.Suspended, HealthRules.State(policy, "uptime", now), "suspendu");
        Check.Equal(HealthRuleState.On, HealthRules.State(policy, "uptime", now.AddHours(25)), "revenu seul");
        var parsed = HealthPolicyJson.ReadPolicy(Json("""{"suspensions":[{"ruleId":"uptime","reason":"Campagne de redémarrage","untilUtc":"2026-10-22T16:26:00Z","endNow":true}]}"""), policy, now);
        Check.Equal(HealthRuleState.On, HealthRules.State(parsed, "uptime", now), "« Réactiver maintenant »");
        Check.Equal(1, parsed.Suspensions.Length, "le motif reste listé");
    }

    [Test]
    public static void Health_policy_JSON_is_read_strictly()
    {
        var now = TestClock.Reference;
        var read = HealthPolicyJson.ReadPolicy(Json("""{"thresholds":{"staleDays":45},"disabledRules":["battery"]}"""), HealthPolicy.Default, now);
        Check.Equal(45, read.Thresholds.StaleDays, "seuil lu");
        Check.True(read.DisabledRules.SequenceEqual(["battery"]), "contrôle désactivé");
        var hours = HealthPolicyJson.ReadPolicy(Json("""{"suspensions":[{"ruleId":"lowdisk","reason":"Disques en commande","hours":24}]}"""), HealthPolicy.Default, now);
        Check.Equal(now.AddHours(24), hours.Suspensions[0].UntilUtc, "suspension de 24 h");
        Check.Throws<DomeniaOperationException>(() => HealthPolicyJson.ReadPolicy(Json("""{"thresholds":{"inconnu":3}}"""), HealthPolicy.Default, now), "seuil inconnu");
        Check.Throws<DomeniaOperationException>(() => HealthPolicyJson.ReadPolicy(Json("""{"suspensions":[{"ruleId":"lowdisk","reason":"Disques","hours":5}]}"""), HealthPolicy.Default, now), "durée hors liste");
        Check.Throws<DomeniaOperationException>(() => HealthPolicyJson.ReadPolicy(Json("""{"customRules":[{"name":"Requête","measure":"Query","operator":"GreaterThan","threshold":1,"severity":"Warn","enabled":true}]}"""), HealthPolicy.Default, now), "alerte sur requête refusée");
        var written = HealthPolicyJson.Write(HealthRules.SetScopePolicy(HealthPolicyBook.Empty(Domain), Postes, read, now));
        var back = HealthPolicyJson.ReadBook(written, Domain, now);
        Check.Equal(45, HealthRules.Resolve(back, Postes).Policy.Thresholds.StaleDays, "aller-retour du carnet");
    }

    // ---------------------------------------------------------------- collection clocks

    [Test]
    public static void A_collection_run_in_the_future_is_refused()
    {
        var now = TestClock.Reference;
        Check.Throws<ArgumentException>(() => CollectionClocks.Create(CollectionFamily.Presence, Domain, Postes, true, CollectionStatus.Success, now.AddMinutes(5), now.AddMinutes(6),
            null, 10, 10, 10, 0, null, now), "date future");
        Check.Throws<ArgumentException>(() => CollectionClocks.Create(CollectionFamily.Presence, "DC=autre,DC=local", "DC=autre,DC=local", true, CollectionStatus.Success, now.AddMinutes(-5), now,
            null, 10, 10, 10, 0, null, now), "autre domaine");
    }

    [Test]
    public static void A_subtree_run_of_an_enclosing_OU_dates_the_view()
    {
        var now = TestClock.Reference;
        var run = CollectionClocks.Create(CollectionFamily.Directory, Domain, Postes, true, CollectionStatus.Success, now.AddMinutes(-20), now.AddMinutes(-19),
            null, null, 1826, null, null, "DC01.example.local", now);
        var clock = CollectionClocks.Clock([run], CollectionFamily.Directory, new ScopeSelection("OU=Paris," + Postes, "Paris", true), Domain, now, TestClock.Paris);
        Check.NotNull(clock.Success, "dernier succès connu");
        Check.True(clock.Success!.Inherited, "hérité de l’OU englobante");
        Check.Equal("success", clock.State, "état");
        var none = CollectionClocks.Clock([run], CollectionFamily.Presence, new ScopeSelection(Postes, "Postes", true), Domain, now, TestClock.Paris);
        Check.Equal("neverRecorded", none.State, "autre famille : jamais relevé");
    }

    // ---------------------------------------------------------------- probes

    [Test]
    public static void Probe_catalog_and_contracts()
    {
        var catalog = AccueilService.Catalog();
        Check.True(catalog.ProbeCount >= 100, "sondes intégrées et détaillées : " + catalog.ProbeCount);
        foreach (var probe in catalog.Probes.SelectMany(c => c.Probes))
        {
            Check.True(probe.Visuals.Length > 0, "représentations de " + probe.Id);
            var definition = ProbeCatalog.Find(probe.Id);
            Check.NotNull(definition, "sonde retrouvée : " + probe.Id);
            Check.True(ProbeCatalog.Contract(definition!).Lines.Length > 0, "contrat de " + probe.Id);
        }
        Check.Null(ProbeCatalog.Find("inconnue"), "sonde inconnue");
        Check.Equal(FleetCatalog.All.Length, catalog.Groups.Sum(g => g.Widgets.Length), "widgets du catalogue");
    }

    // ---------------------------------------------------------------- operations over the simulated directory

    [Test]
    public static async Task Board_counts_the_workstations_of_the_working_OU()
    {
        var bridge = new SimulatedBridge();
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        var population = board.GetProperty("population");
        var machines = population.GetProperty("machines").GetInt32();
        Check.Equal(machines, population.GetProperty("enabled").GetInt32() + population.GetProperty("disabled").GetInt32() + population.GetProperty("unknown").GetInt32(), "population complète");
        Check.Equal(412, population.GetProperty("enabled").GetInt32(), "postes activés de l’OU Postes");
        var entries = board.GetProperty("entries");
        Check.Equal(412.0, entries.GetProperty("fleet.enabled").GetProperty("number").GetDouble(), "tuile « Comptes ordinateur activés »");
        Check.Equal("health", entries.GetProperty("fleet.health").GetProperty("kind").GetString(), "carte santé");
        var health = board.GetProperty("health");
        Check.Equal(health.GetProperty("total").GetInt32(), health.GetProperty("assessed").GetInt32() + health.GetProperty("unassessed").GetInt32(), "évalués + non évalués");
        Check.Equal("current", board.GetProperty("snapshot").GetProperty("kind").GetString(), "vue actuelle");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("accueil.board", "{\"x\":1}")).Error!.Code, "aucun argument admis");
    }

    [Test]
    public static async Task Each_figure_opens_its_exact_workstations()
    {
        var bridge = new SimulatedBridge();
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        var revision = board.GetProperty("revision").GetString()!;
        var disabled = board.GetProperty("entries").GetProperty("fleet.disabled");
        var expected = (int)disabled.GetProperty("number").GetDouble();
        var list = SimulatedBridge.Json(await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision, key = "fleet.disabled" })));
        Check.Equal(expected, list.GetProperty("total").GetInt32(), "même nombre que la tuile");
        Check.Equal(expected, list.GetProperty("rows").GetArrayLength(), "lignes");
        Check.True(list.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("state").GetString() == "Désactivé"), "tous désactivés");
        Check.Equal("targets.unknown", (await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision, key = "fleet.inconnu" }))).Error!.Code, "clé inconnue");
        Check.Equal("board.replaced", (await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision = "ancienne", key = "fleet.disabled" }))).Error!.Code, "calcul remplacé");
    }

    [Test]
    public static async Task Layout_is_kept_in_the_preferences_and_can_be_restored()
    {
        var preferences = new MemoryPreferenceStore();
        var bridge = new SimulatedBridge(preferences: preferences);
        var layout = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout"));
        Check.False(layout.GetProperty("customized").GetBoolean(), "disposition livrée");
        var items = layout.GetProperty("items").EnumerateArray().Skip(1).Select(i => new
        {
            id = i.GetProperty("id").GetString(),
            source = i.GetProperty("source").GetString(),
            key = i.GetProperty("key").GetString(),
            visual = i.GetProperty("visual").GetString(),
            size = i.GetProperty("size").GetString(),
            title = (string?)null,
            paused = false,
        }).ToList();
        items.Add(new { id = (string?)null, source = (string?)"probe", key = (string?)ProbeIdOf(), visual = (string?)"Pie", size = (string?)"M", title = (string?)"Ma sonde", paused = true });
        var saved = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout.save", JsonSerializer.Serialize(new { items })));
        Check.True(saved.GetProperty("customized").GetBoolean(), "disposition personnalisée");
        Check.True(preferences.TryGet(AccueilService.LayoutPreference, out _), "mémorisée dans les préférences locales");
        var last = saved.GetProperty("items")[saved.GetProperty("items").GetArrayLength() - 1];
        Check.Equal("Ma sonde", last.GetProperty("title").GetString(), "titre gardé");
        Check.True(last.GetProperty("paused").GetBoolean(), "sonde en pause");
        var reset = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout.reset"));
        Check.False(reset.GetProperty("customized").GetBoolean(), "disposition livrée rétablie");
        Check.Equal("layout.preset", (await bridge.CallAsync("accueil.layout.reset", "{\"preset\":\"inconnue\"}")).Error!.Code, "disposition inconnue");
    }

    [Test]
    public static async Task A_refresh_plan_runs_once_and_reports_its_stages()
    {
        var bridge = new SimulatedBridge();
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"directory\"}"));
        string[] stages = [.. plan.GetProperty("stages").EnumerateArray().Select(s => s.GetProperty("id").GetString()!)];
        Check.True(stages.SequenceEqual(["backup", "directory", "commit"]), "étapes : " + string.Join(",", stages));
        var id = plan.GetProperty("id").GetString()!;
        var report = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = id })));
        Check.Equal("success", report.GetProperty("status").GetString(), "actualisation réussie");
        Check.True(bridge.Events.Any(e => e.Operation == "accueil.refresh.run:progress"), "progression publiée");
        Check.Equal("refresh.planUnknown", (await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = id }))).Error!.Code, "jamais rejoué");
        var state = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.state"));
        Check.False(state.GetProperty("running").GetBoolean(), "plus rien en cours");
        Check.Equal(id, state.GetProperty("last").GetProperty("id").GetString(), "dernier compte rendu");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"tout\"}")).Error!.Code, "mode inconnu");
    }

    [Test]
    public static async Task Nothing_is_measured_on_the_whole_domain()
    {
        var bridge = new SimulatedBridge();
        await bridge.CallAsync("session.setScope", JsonSerializer.Serialize(new { dn = Domain, subtree = true }));
        Check.Equal("scope.tooWide", (await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"inventory\"}")).Error!.Code, "aucune collecte sur tout le domaine");
        Check.Equal("scope.tooWide", (await bridge.CallAsync("accueil.bitlocker.read")).Error!.Code, "aucune lecture BitLocker sur tout le domaine");
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        Check.True(board.GetProperty("population").GetProperty("machines").GetInt32() > 431, "le tableau se calcule depuis la base locale");
    }

    [Test]
    public static async Task BitLocker_presence_is_counted_never_a_key()
    {
        var bridge = new SimulatedBridge();
        var summary = SimulatedBridge.Json(await bridge.CallAsync("accueil.bitlocker.read"));
        Check.Equal(summary.GetProperty("read").GetInt32(), summary.GetProperty("withKey").GetInt32() + summary.GetProperty("withoutKey").GetInt32(), "postes lus");
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        Check.True(board.GetProperty("entries").GetProperty("fleet.bitlocker").GetProperty("measured").GetBoolean(), "tuile BitLocker mesurée");
        Check.False(JsonSerializer.Serialize(summary).Contains("recoveryPassword", StringComparison.OrdinalIgnoreCase), "aucune clé");
    }

    [Test]
    public static async Task Health_rules_saved_for_the_domain_change_the_board()
    {
        var bridge = new SimulatedBridge();
        var view = SimulatedBridge.Json(await bridge.CallAsync("accueil.health.save", """{"policy":{"thresholds":{"staleDays":45}}}"""));
        Check.Equal(45, view.GetProperty("policy").GetProperty("thresholds").GetProperty("staleDays").GetInt32(), "seuil enregistré");
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        Check.Contains("45", board.GetProperty("entries").GetProperty("fleet.stale").GetProperty("title").GetString(), "titre de la tuile avec le seuil");
        Check.Equal("health.invalid", (await bridge.CallAsync("accueil.health.save", """{"policy":{"thresholds":{"diskFreeAlert":50}}}""")).Error!.Code, "seuils incohérents");
        var explain = SimulatedBridge.Json(await bridge.CallAsync("accueil.health.explain"));
        Check.True(explain.GetProperty("rows").GetArrayLength() >= 11, "une ligne par contrôle noté");
    }

    [Test]
    public static async Task Favourites_switch_the_working_OU_in_one_click()
    {
        var bridge = new SimulatedBridge();
        var lyon = "OU=Lyon," + Postes;
        var list = SimulatedBridge.Json(await bridge.CallAsync("accueil.favorite.save", JsonSerializer.Serialize(new { name = "Lyon", dn = lyon, subtree = true })));
        Check.Equal(1, list.GetProperty("items").GetArrayLength(), "une favorite");
        Check.True(list.GetProperty("items")[0].GetProperty("exists").GetBoolean(), "OU présente dans la base");
        var id = list.GetProperty("items")[0].GetProperty("id").GetString()!;
        Check.Equal("favorite.invalid", (await bridge.CallAsync("accueil.favorite.save", JsonSerializer.Serialize(new { name = "", dn = lyon, subtree = true }))).Error!.Code, "nom vide");
        var dropped = SimulatedBridge.Json(await bridge.CallAsync("accueil.favorite.drop", JsonSerializer.Serialize(new { id })));
        Check.Equal(0, dropped.GetProperty("items").GetArrayLength(), "favorite retirée");
        Check.Equal("favorite.unknown", (await bridge.CallAsync("accueil.favorite.drop", JsonSerializer.Serialize(new { id }))).Error!.Code, "déjà retirée");
    }

    [Test]
    public static async Task First_steps_follow_the_session_and_the_board()
    {
        var bridge = new SimulatedBridge();
        var before = SimulatedBridge.Json(await bridge.CallAsync("accueil.firstSteps"));
        string[] ids = [.. before.GetProperty("steps").EnumerateArray().Select(s => s.GetProperty("id").GetString()!)];
        Check.True(ids.SequenceEqual(["connect", "scope", "firstRead", "dashboard", "rights"]), "étapes : " + string.Join(",", ids));
        await bridge.CallAsync("accueil.board");
        var after = SimulatedBridge.Json(await bridge.CallAsync("accueil.firstSteps"));
        Check.True(after.GetProperty("steps")[3].GetProperty("done").GetBoolean(), "tableau de bord vu");
        Check.Equal(4, after.GetProperty("completed").GetInt32(), "quatre étapes faites");
        var hidden = SimulatedBridge.Json(await bridge.CallAsync("accueil.firstSteps.dismiss", "{\"dismissed\":true}"));
        Check.True(hidden.GetProperty("dismissed").GetBoolean(), "carte masquée");
        var help = SimulatedBridge.Json(await bridge.CallAsync("accueil.help.seen"));
        Check.True(help.GetProperty("helpSeen").GetBoolean(), "aide vue");
    }

    [Test]
    public static async Task Analysis_compares_two_readings_and_crosses_dimensions()
    {
        var bridge = new SimulatedBridge();
        var list = SimulatedBridge.Json(await bridge.CallAsync("accueil.analysis.snapshots"));
        var items = list.GetProperty("items");
        Check.True(items.GetArrayLength() >= 2, "relevés quotidiens et vue actuelle");
        Check.Equal(4, list.GetProperty("tables").GetArrayLength(), "quatre tableaux croisés");
        var current = items.EnumerateArray().First(i => i.GetProperty("kind").GetString() == "current").GetProperty("id").GetString();
        var daily = items.EnumerateArray().First(i => i.GetProperty("kind").GetString() == "daily").GetProperty("id").GetString();
        var comparison = SimulatedBridge.Json(await bridge.CallAsync("accueil.analysis.compare", JsonSerializer.Serialize(new { before = daily, after = current })));
        Check.Equal(4, comparison.GetProperty("factors").GetArrayLength(), "périmètre, couverture, règles, état");
        Check.Equal("snapshot.same", (await bridge.CallAsync("accueil.analysis.compare", JsonSerializer.Serialize(new { before = current, after = current }))).Error!.Code, "deux relevés différents");
        var matrix = SimulatedBridge.Json(await bridge.CallAsync("accueil.analysis.pivots", "{\"table\":\"ouWindows\"}"));
        Check.Equal(matrix.GetProperty("total").GetInt32(), matrix.GetProperty("grandTotal").GetInt32(), "chaque poste dans une seule cellule");
        Check.Equal("pivot.unknown", (await bridge.CallAsync("accueil.analysis.pivots", "{\"table\":\"inconnu\"}")).Error!.Code, "tableau inconnu");
        var snapshot = SimulatedBridge.Json(await bridge.CallAsync("accueil.snapshot.take", "{\"label\":\"Avant la migration\"}"));
        Check.Equal("manual", snapshot.GetProperty("kind").GetString(), "instantané manuel");
    }

    [Test]
    public static async Task Session_tools_check_clear_and_read_locally()
    {
        var bridge = new SimulatedBridge();
        var check = SimulatedBridge.Json(await bridge.CallAsync("accueil.selfCheck"));
        Check.True(check.GetProperty("checks").EnumerateArray().Any(c => c.GetProperty("id").GetString() == "mode"), "contrôle du mode");
        Check.Equal(0, check.GetProperty("failures").GetInt32(), "aucun échec en simulation");
        await bridge.CallAsync("accueil.board");
        var cleared = SimulatedBridge.Json(await bridge.CallAsync("accueil.cache.clear"));
        Check.Contains("aucun objet Active Directory n’est modifié", cleared.GetProperty("text").GetString(), "texte du vidage");
        var journal = SimulatedBridge.Json(await bridge.CallAsync("accueil.journal"));
        Check.True(journal.GetProperty("total").GetInt32() > 0, "journal des opérations");
        var provenance = SimulatedBridge.Json(await bridge.CallAsync("accueil.provenance"));
        Check.Equal(3, provenance.GetProperty("clocks").GetArrayLength(), "trois horloges");
        var collections = SimulatedBridge.Json(await bridge.CallAsync("accueil.collections"));
        Check.True(collections.GetProperty("rows").GetArrayLength() > 0, "relevés par OU");
        Check.Equal("probe.unknown", (await bridge.CallAsync("accueil.probe", "{\"id\":\"inconnue\"}")).Error!.Code, "sonde inconnue");
    }

    [Test]
    public static async Task Last_view_is_remembered_for_the_same_base_and_OU()
    {
        var bridge = new SimulatedBridge();
        var none = SimulatedBridge.Json(await bridge.CallAsync("accueil.lastView"));
        Check.False(none.GetProperty("available").GetBoolean(), "rien avant le premier calcul");
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        await bridge.CallAsync("accueil.lastView.save", JsonSerializer.Serialize(new { revision = board.GetProperty("revision").GetString() }));
        var view = SimulatedBridge.Json(await bridge.CallAsync("accueil.lastView"));
        Check.True(view.GetProperty("available").GetBoolean(), "dernière vue enregistrée");
        Check.Equal(412, view.GetProperty("machines").GetInt32(), "compte des postes, jamais un nom");
    }

    // ---------------------------------------------------------------- tour 1 (critique du 22/10): refresh rules, sets, records

    [Test]
    public static void Refresh_admission_refuses_new_collections()
    {
        Check.Null(RefreshRules.Refusal(new RefreshAdmission(false, 0, false, 0, 10L * 1024 * 1024 * 1024)), "aucun refus");
        Check.Contains("mesure de widget", RefreshRules.Refusal(new RefreshAdmission(true, 1, false, 0, null)), "mesure en cours");
        Check.Contains("BitLocker", RefreshRules.Refusal(new RefreshAdmission(true, 0, true, 0, null)), "lecture BitLocker en cours");
        Check.Contains("Enregistrement local suspendu", RefreshRules.Refusal(new RefreshAdmission(true, 0, false, 3, null)), "trois échecs d’écriture");
        Check.Null(RefreshRules.Refusal(new RefreshAdmission(true, 0, false, 2, null)), "deux échecs : encore admis");
        Check.Contains("insuffisant", RefreshRules.Refusal(new RefreshAdmission(false, 0, false, 0, 400L * 1024 * 1024)), "moins de 512 Mio");
        Check.Contains("critique", RefreshRules.Refusal(new RefreshAdmission(false, 0, false, 0, 10L * 1024 * 1024)), "moins de 32 Mio");
        Check.Null(RefreshRules.Refusal(new RefreshAdmission(true, 0, false, 0, 10L * 1024 * 1024)), "la simulation n’écrit rien sur le disque");
        Check.Null(RefreshRules.Refusal(new RefreshAdmission(false, 0, false, 0, null)), "espace non mesuré : rien n’est bloqué");
    }

    [Test]
    public static void Only_what_is_missing_is_collected()
    {
        var now = TestClock.Reference;
        Guid G(int n) => new("00000000-0000-4000-8000-" + n.ToString("D12", System.Globalization.CultureInfo.InvariantCulture));
        WorkstationObservation O(int n, InventoryMeasure inventory) => new(G(n), PresenceMeasure.Unread, inventory);
        var fresh = InventoryMeasure.Unread with { State = MeasureState.Known, CheckedAt = now - TimeSpan.FromDays(3) };
        var old = fresh with { CheckedAt = now - TimeSpan.FromDays(40) };
        var failed = fresh with { State = MeasureState.Error };
        var future = fresh with { CheckedAt = now + TimeSpan.FromMinutes(10) };
        var observations = new Dictionary<Guid, WorkstationObservation> { [G(1)] = O(1, fresh), [G(2)] = O(2, old), [G(3)] = O(3, failed), [G(5)] = O(5, future) };
        var since = now - TimeSpan.FromDays(RefreshRules.ReuseDays);
        var missing = RefreshRules.Missing([G(1), G(2), G(3), G(4), G(5)], observations, ProbeReadings.Empty, [], since, now);
        Check.True(missing.SequenceEqual([G(2), G(3), G(4), G(5)]), "ancien, en erreur, absent et daté dans le futur : relus ; récent : réutilisé");
        Check.Equal(5, RefreshRules.Missing([G(1), G(2), G(3), G(4), G(5)], observations, ProbeReadings.Empty, [], null, now).Length, "« Tout relire » : rien n’est réutilisé");
        var probes = ProbeReadings.Empty.Merge(new ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>>.Empty.Add("disk.free",
            ImmutableDictionary<Guid, ProbeReading>.Empty.Add(G(9), new ProbeReading(MeasureState.Known, now - TimeSpan.FromDays(1), ["42"], null)))));
        observations[G(9)] = O(9, fresh);
        Check.True(RefreshRules.Missing([G(1), G(9)], observations, probes, ["disk.free"], since, now).SequenceEqual([G(1)]), "sonde du plan absente : poste contacté");
    }

    [Test]
    public static async Task Wmi_reads_only_the_workstations_that_answered_the_ping()
    {
        var bridge = new SimulatedBridge();
        var before = await bridge.Source.ReadLocalAsync(CancellationToken.None);
        bridge.Clock.Advance(TimeSpan.FromDays(40));
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"inventory\"}"));
        var report = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = plan.GetProperty("id").GetString() })));
        Check.Equal("success", report.GetProperty("status").GetString(), "relevé réussi");
        var after = await bridge.Source.ReadLocalAsync(CancellationToken.None);
        var start = TestClock.Reference + TimeSpan.FromDays(40);
        var redated = after.Observations.Workstations.Where(o => o.Inventory.CheckedAt >= start).ToList();
        Check.True(redated.Count > 0, "des inventaires relus");
        Check.True(redated.All(o => o.Presence.Answered == true && o.Presence.CheckedAt >= start), "WMI relu seulement sur les postes qui ont répondu au ping de ce relevé");
        var silent = after.Observations.Workstations.Where(o => o.Presence.HasReading && o.Presence.Answered == false && o.Inventory.HasReading).ToList();
        Check.True(silent.All(o => o.Inventory.CheckedAt == before.Observations.Workstations.First(b => b.ComputerGuid == o.ComputerGuid).Inventory.CheckedAt),
            "poste sans réponse au ping : date WMI inchangée");
    }

    [Test]
    public static async Task Up_to_date_workstations_are_not_contacted_unless_forced()
    {
        var bridge = new SimulatedBridge();
        var first = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"inventory\"}"));
        await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = first.GetProperty("id").GetString() }));
        var second = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"inventory\"}"));
        Check.True(second.GetProperty("reused").GetInt32() > 0, "postes déjà à jour comptés au plan");
        var report = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = second.GetProperty("id").GetString() })));
        var stage = report.GetProperty("stages").EnumerateArray().First(st => st.GetProperty("id").GetString() == "inventory");
        Check.Contains("déjà à jour", stage.GetProperty("detail").GetString(), "« déjà à jour, non contactés »");
        var third = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"inventory\"}"));
        var forced = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = third.GetProperty("id").GetString(), force = true })));
        Check.True(forced.GetProperty("forced").GetBoolean(), "« Tout relire »");
        var forcedStage = forced.GetProperty("stages").EnumerateArray().First(st => st.GetProperty("id").GetString() == "inventory");
        Check.False(forcedStage.GetProperty("detail").GetString()!.Contains("déjà à jour", StringComparison.Ordinal), "rien n’est réutilisé");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("accueil.refresh.run", "{\"planId\":\"" + new string('a', 32) + "\",\"force\":\"oui\"}")).Error!.Code, "force booléen");
    }

    [Test]
    public static async Task A_refresh_plan_expires_and_follows_the_working_OU()
    {
        var bridge = new SimulatedBridge();
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}"));
        bridge.Clock.Advance(TimeSpan.FromMinutes(6));
        Check.Equal("refresh.planExpired", (await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = plan.GetProperty("id").GetString() }))).Error!.Code, "plan expiré après 5 min");
        var other = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}"));
        await bridge.CallAsync("session.setScope", JsonSerializer.Serialize(new { dn = "OU=Lyon," + Postes, subtree = true }));
        Check.Equal("refresh.scopeChanged", (await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = other.GetProperty("id").GetString() }))).Error!.Code, "OU changée depuis le plan");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("accueil.refresh.run", "{\"planId\":\"ABC\"}")).Error!.Code, "identifiant de plan : 32 caractères hexadécimaux");
        Check.Equal("arguments.invalid", (await bridge.CallAsync("accueil.refresh.run", "{\"planId\":\"" + new string('A', 32) + "\"}")).Error!.Code, "minuscules seulement");
    }

    [Test]
    public static async Task Directory_mode_refuses_an_AD_read_without_a_verified_backup()
    {
        var bridge = new SimulatedBridge();
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"all\"}"));
        var backup = plan.GetProperty("stages")[0];
        Check.Equal("backup", backup.GetProperty("id").GetString(), "sauvegarde en tête");
        Check.Contains("Sans objet en simulation", backup.GetProperty("detail").GetString(), "le plan ne promet pas de sauvegarde en simulation");
        var report = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = plan.GetProperty("id").GetString() })));
        Check.Equal("na", report.GetProperty("stages")[0].GetProperty("state").GetString(), "étape « sans objet », jamais « terminée »");
        Check.Equal(AccueilService.RefreshBackupUnavailable, "refresh.backupUnavailable", "code du refus en mode annuaire");
    }

    [Test]
    public static async Task A_query_widget_refuses_the_WMI_collection()
    {
        var bridge = new SimulatedBridge();
        var layout = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout"));
        var items = layout.GetProperty("items").EnumerateArray().Select(i => new { id = i.GetProperty("id").GetString()!, source = i.GetProperty("source").GetString()!, key = i.GetProperty("key").GetString()!, visual = i.GetProperty("visual").GetString()!, size = i.GetProperty("size").GetString()! }).ToList();
        items.Add(new { id = "q-1", source = "query", key = "mes.postes", visual = "Kpi", size = "S" });
        await bridge.CallAsync("accueil.layout.save", JsonSerializer.Serialize(new { items }));
        Check.Equal("refresh.queryMissing", (await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"inventory\"}")).Error!.Code, "requête absente : refus explicite");
        Check.Equal("result", (await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}")).Kind, "le ping seul reste possible");
    }

    [Test]
    public static async Task Layout_save_is_bounded_to_64_widgets()
    {
        var bridge = new SimulatedBridge();
        var items = Enumerable.Range(0, 65).Select(n => new { id = "b-" + n, source = "builtin", key = "fleet.machines", visual = "Kpi", size = "S" });
        Check.Equal("arguments.invalid", (await bridge.CallAsync("accueil.layout.save", JsonSerializer.Serialize(new { items }))).Error!.Code, "65 widgets refusés");
        var ok = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout.save", JsonSerializer.Serialize(new { items = items.Take(64) })));
        Check.Equal(64, ok.GetProperty("items").GetArrayLength(), "64 widgets admis");
    }

    [Test]
    public static async Task Exact_sets_refuse_a_replaced_or_unknown_calculation()
    {
        var bridge = new SimulatedBridge();
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        var revision = board.GetProperty("revision").GetString();
        var rows = SimulatedBridge.Json(await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision, key = "fleet.enabled" })));
        var row = rows.GetProperty("rows")[0];
        Check.True(row.TryGetProperty("score", out _) && row.TryGetProperty("alerts", out _), "score du poste dans la liste exacte");
        Check.Equal("targets.unknown", (await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision, key = "inconnu" }))).Error!.Code, "ensemble inconnu");
        await bridge.CallAsync("accueil.board");
        Check.Equal("board.replaced", (await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision, key = "fleet.enabled" }))).Error!.Code, "calcul remplacé");
    }

    [Test]
    public static async Task Machine_scores_and_missing_collection_follow_the_health_rules()
    {
        Check.Equal(100, FleetBoardCalculator.MachineScore(0, 0), "sans point");
        Check.Equal(65, FleetBoardCalculator.MachineScore(1, 1), "100 − 25 − 10");
        Check.Equal(0, FleetBoardCalculator.MachineScore(5, 0), "jamais sous 0");
        var bridge = new SimulatedBridge();
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        var explain = SimulatedBridge.Json(await bridge.CallAsync("accueil.health.explain"));
        Check.Equal(board.GetProperty("revision").GetString(), explain.GetProperty("revision").GetString(), "explication liée au calcul affiché");
        Check.False(explain.GetProperty("summary").GetString()!.Contains("Évaluables", StringComparison.Ordinal), "colonne nommée comme à l’écran");
        var lacking = explain.GetProperty("rows").EnumerateArray().FirstOrDefault(r => r.GetProperty("missing").GetInt32() > 0);
        if (lacking.ValueKind == JsonValueKind.Object)
        {
            var set = SimulatedBridge.Json(await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision = explain.GetProperty("revision").GetString(), key = lacking.GetProperty("missingKey").GetString() })));
            Check.Equal(lacking.GetProperty("missing").GetInt32(), set.GetProperty("total").GetInt32(), "« Voir la collecte manquante » : les postes exacts, sans collecte");
        }
        var problems = SimulatedBridge.Json(await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision = board.GetProperty("revision").GetString(), key = "fleet.health|Problèmes" })));
        Check.True(problems.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("score").GetInt32() < 100), "un poste avec problème a un score sous 100");
        var unknown = SimulatedBridge.Json(await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision = board.GetProperty("revision").GetString(), key = "fleet.health|Incomplets" })));
        Check.True(unknown.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("score").ValueKind == JsonValueKind.Null), "poste non évalué : aucun score");
    }

    [Test]
    public static async Task A_stopped_refresh_skips_its_stages_and_can_be_resumed()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"all\"}"));
        var running = bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = plan.GetProperty("id").GetString() }));
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!bridge.Events.Any(e => e.Operation == "accueil.refresh.run:progress") && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }
        Check.Equal("refresh.running", (await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}")).Error!.Code, "une seule actualisation à la fois");
        var stop = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.stop"));
        Check.True(stop.GetProperty("stopping").GetBoolean(), "arrêt demandé");
        var report = SimulatedBridge.Json(await running);
        Check.Equal("cancelled", report.GetProperty("status").GetString(), "compte rendu « arrêtée »");
        Check.True(report.GetProperty("stages").EnumerateArray().Any(st => st.GetProperty("state").GetString() is "skipped" or "stopped"), "étapes non lancées publiées");
        Check.True(report.GetProperty("resumable").GetBoolean(), "reprise proposée");
        var resume = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"resume\"}"));
        Check.True(resume.GetProperty("stages").GetArrayLength() > 0, "étapes restantes seulement");
        Check.Equal(report.GetProperty("id").GetString(), resume.GetProperty("resumeOf").GetString(), "reprise de l’actualisation interrompue");
    }

    [Test]
    public static async Task Nothing_to_resume_after_a_finished_refresh()
    {
        var bridge = new SimulatedBridge();
        Check.Equal("refresh.nothingToResume", (await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"resume\"}")).Error!.Code, "aucune actualisation");
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}"));
        await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = plan.GetProperty("id").GetString() }));
        Check.Equal("refresh.nothingToResume", (await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"resume\"}")).Error!.Code, "actualisation terminée : rien à reprendre");
    }

    [Test]
    public static async Task First_steps_go_away_for_good_once_finished()
    {
        var preferences = new MemoryPreferenceStore();
        var bridge = new SimulatedBridge(preferences: preferences);
        await bridge.CallAsync("accueil.board");
        var steps = SimulatedBridge.Json(await bridge.CallAsync("accueil.firstSteps"));
        Check.True(steps.GetProperty("finished").GetBoolean(), "quatre étapes faites : carte terminée");
        var again = new SimulatedBridge(preferences: preferences);
        Check.True(SimulatedBridge.Json(await again.CallAsync("accueil.firstSteps")).GetProperty("finished").GetBoolean(), "mémorisé (Home.FirstStepsDone)");
    }

    [Test]
    public static async Task Last_view_is_written_when_it_changes_or_once_a_minute()
    {
        var preferences = new CountingPreferenceStore();
        var bridge = new SimulatedBridge(preferences: preferences);
        for (var k = 0; k < 3; k++)
        {
            var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
            await bridge.CallAsync("accueil.lastView.save", JsonSerializer.Serialize(new { revision = board.GetProperty("revision").GetString() }));
        }
        Check.Equal(1, preferences.Writes.Count(k => k.StartsWith("accueil.lastView.", StringComparison.Ordinal)), "mêmes chiffres : une seule écriture");
        bridge.Clock.Advance(TimeSpan.FromMinutes(2));
        var later = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        await bridge.CallAsync("accueil.lastView.save", JsonSerializer.Serialize(new { revision = later.GetProperty("revision").GetString() }));
        Check.Equal(2, preferences.Writes.Count(k => k.StartsWith("accueil.lastView.", StringComparison.Ordinal)), "une minute plus tard : réécrite");
    }

    [Test]
    public static async Task Runs_and_snapshots_are_kept_in_the_local_preferences()
    {
        var preferences = new MemoryPreferenceStore();
        var bridge = new SimulatedBridge(preferences: preferences);
        var before = SimulatedBridge.Json(await bridge.CallAsync("accueil.collections")).GetProperty("total").GetInt32();
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}"));
        await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = plan.GetProperty("id").GetString() }));
        await bridge.CallAsync("accueil.snapshot.take", "{\"label\":\"Avant\"}");
        var again = new SimulatedBridge(preferences: preferences);
        Check.Equal(before + 1, SimulatedBridge.Json(await again.CallAsync("accueil.collections")).GetProperty("total").GetInt32(), "relevé relu au démarrage suivant");
        var list = SimulatedBridge.Json(await again.CallAsync("accueil.analysis.snapshots"));
        Check.True(list.GetProperty("items").EnumerateArray().Any(i => i.GetProperty("kind").GetString() == "manual" && i.GetProperty("label").GetString()!.StartsWith("Avant", StringComparison.Ordinal)), "instantané manuel relu");
    }

    [Test]
    public static async Task Failed_local_writes_suspend_new_collections()
    {
        var bridge = new SimulatedBridge(preferences: new FailingPreferenceStore());
        for (var k = 0; k < 3; k++)
        {
            await bridge.CallAsync("accueil.firstSteps.dismiss", "{\"dismissed\":true}");
        }
        var refused = await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}");
        Check.Equal(RefreshRules.Refused, refused.Error!.Code, "trois échecs : nouvelles collectes suspendues");
        var details = SimulatedBridge.Json(await bridge.CallAsync("accueil.session.details"));
        Check.True(details.GetProperty("localWriteFailures").GetInt32() >= 3, "échecs montrés dans les détails de la session");
    }

    [Test]
    public static async Task Session_details_name_links_check_and_calculations()
    {
        var bridge = new SimulatedBridge();
        await bridge.CallAsync("accueil.board");
        await bridge.CallAsync("accueil.selfCheck");
        var details = SimulatedBridge.Json(await bridge.CallAsync("accueil.session.details"));
        Check.True(details.GetProperty("associations").GetInt32() >= 0, "liens utilisateur–poste");
        Check.Equal(JsonValueKind.Object, details.GetProperty("lastCheck").ValueKind, "dernière vérification");
        Check.True(details.GetProperty("calculations").GetArrayLength() is > 0 and <= 5, "cinq derniers calculs au plus");
    }

    [Test]
    public static async Task Journal_tail_is_bounded_and_joins_continuation_lines()
    {
        var absent = await Domenia.App.AccueilHostFiles.TailAsync(null, CancellationToken.None);
        Check.False(absent.Available, "journal absent");
        using var folder = new TemporaryFolder();
        var path = folder.File("domenia.log");
        await File.WriteAllTextAsync(path, "2026-10-21T16:00:00Z [WARN] Préférences non enregistrées\n   à la ligne suivante\n2026-10-21T16:01:00Z Démarrage\n");
        var tail = await Domenia.App.AccueilHostFiles.TailAsync(path, CancellationToken.None);
        Check.Equal(2, tail.Lines.Length, "deux entrées");
        Check.Equal("Démarrage", tail.Lines[0].Text, "la plus récente d’abord");
        Check.Contains("à la ligne suivante", tail.Lines[1].Text, "ligne de suite rattachée");
        Check.Equal("WARN", tail.Lines[1].Level, "niveau lu");
        var big = string.Concat(Enumerable.Range(0, 6000).Select(n => "2026-10-21T16:00:00Z ligne " + n + new string('x', 40) + "\n"));
        await File.WriteAllTextAsync(path, big);
        var cut = await Domenia.App.AccueilHostFiles.TailAsync(path, CancellationToken.None);
        Check.True(cut.Truncated, "plus de 256 Kio : début non affiché");
        Check.Equal(Domenia.App.AccueilHostFiles.MaxLines, cut.Lines.Length, "200 lignes au plus");
        Check.Null(Domenia.App.AccueilHostFiles.FreeBytes(null), "sans dossier de données : non mesuré");
    }

    // ---------------------------------------------------------------- tour 2 of the critique (written, run at the very end)

    [Test]
    public static async Task A_locked_journal_gives_a_clear_sentence_and_a_trace()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("domenia.log");
        await File.WriteAllTextAsync(path, "2026-10-21T16:00:00Z Démarrage\n");
        var traces = new List<string>();
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            var tail = await Domenia.App.AccueilHostFiles.TailAsync(path, CancellationToken.None, traces.Add);
            Check.False(tail.Available, "journal verrouillé : rien n’est lu");
            Check.Contains("illisible pour l’instant", tail.Summary, "phrase claire, pas une erreur générique");
            Check.Equal(1, traces.Count, "une trace au journal technique");
            Check.Contains("IOException", traces[0], "le type d’erreur seulement");
        }
    }

    [Test]
    public static void A_run_on_the_direct_children_does_not_date_the_sub_OUs()
    {
        var now = TestClock.Reference;
        var run = CollectionClocks.Create(CollectionFamily.Presence, Domain, Postes, false, CollectionStatus.Success, now.AddMinutes(-10), now.AddMinutes(-9),
            null, 0, 0, 0, 0, null, now);
        var own = CollectionClocks.Clock([run], CollectionFamily.Presence, new ScopeSelection(Postes, "Postes", false), Domain, now, TestClock.Paris);
        Check.Equal("success", own.State, "la vue « cette OU seulement » est datée");
        var child = CollectionClocks.Clock([run], CollectionFamily.Presence, new ScopeSelection("OU=Paris," + Postes, "Paris", true), Domain, now, TestClock.Paris);
        Check.Equal("neverRecorded", child.State, "un relevé des enfants directs ne date jamais les descendants (ACC-023)");
    }

    [Test]
    public static async Task A_refresh_records_the_depth_really_measured()
    {
        var bridge = new SimulatedBridge();
        var paris = "OU=Paris," + Postes;
        await bridge.CallAsync("session.setScope", JsonSerializer.Serialize(new { dn = paris, subtree = false }));
        static int Count(JsonElement list, string dn, bool subtree) => list.GetProperty("rows").EnumerateArray()
            .Count(r => string.Equals(r.GetProperty("ouDn").GetString(), dn, StringComparison.OrdinalIgnoreCase) && r.GetProperty("subtree").GetBoolean() == subtree);
        var before = SimulatedBridge.Json(await bridge.CallAsync("accueil.collections"));
        var plan = SimulatedBridge.Json(await bridge.CallAsync("accueil.refresh.plan", "{\"mode\":\"presence\"}"));
        await bridge.CallAsync("accueil.refresh.run", JsonSerializer.Serialize(new { planId = plan.GetProperty("id").GetString() }));
        var after = SimulatedBridge.Json(await bridge.CallAsync("accueil.collections"));
        Check.Equal(Count(before, paris, false) + 1, Count(after, paris, false), "relevé enregistré « sans les sous-OU »");
        Check.Equal(Count(before, paris, true), Count(after, paris, true), "aucun relevé « sous-OU comprises » inventé");
    }

    [Test]
    public static async Task A_snapshot_keeps_the_board_on_screen_valid()
    {
        var bridge = new SimulatedBridge();
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        var revision = board.GetProperty("revision").GetString();
        await bridge.CallAsync("accueil.snapshot.take", "{\"label\":\"Avant\"}");
        var targets = await bridge.CallAsync("accueil.targets", JsonSerializer.Serialize(new { revision, key = "fleet.enabled" }));
        Check.Null(targets.Error, "les chiffres du tableau affiché ouvrent encore leurs postes après un instantané (pas de board.replaced)");
    }

    [Test]
    public static async Task The_board_carries_the_badge_and_the_freshness_of_the_branch()
    {
        var bridge = new SimulatedBridge();
        var board = SimulatedBridge.Json(await bridge.CallAsync("accueil.board"));
        var badge = board.GetProperty("health").GetProperty("badge").GetString();
        Check.NotNull(badge, "badge du score (ACC-055)");
        Check.Contains("évalués", badge!, "ligne de couverture « X évalués / Y comptes activés »");
        var directory = board.GetProperty("directory");
        Check.Equal("complete", directory.GetProperty("status").GetString(), "annuaire fictif lu en entier (ACC-020)");
        Check.False(directory.GetProperty("partial").GetBoolean(), "aucune tentative partielle");
        Check.Equal(JsonValueKind.String, directory.GetProperty("at").ValueKind, "date de la dernière lecture complète de la branche");
    }

    [Test]
    public static async Task Two_BitLocker_reads_never_run_together()
    {
        var bridge = new SimulatedBridge();
        var answers = await Task.WhenAll(bridge.CallAsync("accueil.bitlocker.read"), bridge.CallAsync("accueil.bitlocker.read"));
        Check.True(answers.Any(a => a.Error is null), "au moins une lecture aboutit");
        Check.True(answers.All(a => a.Error is null || a.Error.Code == "bitlocker.running"), "une seconde lecture simultanée est refusée (bitlocker.running), jamais une autre erreur");
        Check.Null((await bridge.CallAsync("accueil.bitlocker.read")).Error, "le verrou est rendu : une lecture suivante part");
    }

    [Test]
    public static async Task An_exception_on_a_vanished_OU_is_signalled()
    {
        var bridge = new SimulatedBridge();
        var gone = "OU=Disparue," + Postes;
        var saved = await bridge.CallAsync("accueil.health.save", JsonSerializer.Serialize(new { dn = gone, policy = new { thresholds = new { staleDays = 45 } } }));
        Check.Null(saved.Error, "exception enregistrée pour une OU absente de l’index (OU supprimée depuis)");
        var rows = SimulatedBridge.Json(await bridge.CallAsync("accueil.health.exceptions")).GetProperty("rows").EnumerateArray().ToList();
        var row = rows.Single(r => r.GetProperty("scopeDn").GetString() == gone);
        Check.True(row.GetProperty("missing").GetBoolean(), "« OU introuvable » signalée (ACC-026)");
        await bridge.CallAsync("accueil.health.save", JsonSerializer.Serialize(new { dn = "OU=Lyon," + Postes, policy = new { thresholds = new { staleDays = 60 } } }));
        var lyon = SimulatedBridge.Json(await bridge.CallAsync("accueil.health.exceptions")).GetProperty("rows").EnumerateArray()
            .Single(r => r.GetProperty("scopeDn").GetString() == "OU=Lyon," + Postes);
        Check.False(lyon.GetProperty("missing").GetBoolean(), "une OU connue n’est pas signalée");
    }

    [Test]
    public static void Accueil_texts_use_french_no_break_spaces()
    {
        // Messages of the engine (constants) and visible strings of the page: no ordinary space before « : ; ! ? » nor inside « ».
        var messages = new[] { typeof(AccueilService), typeof(RefreshRules), typeof(HealthRules) }
            .SelectMany(t => t.GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static))
            .Where(f => f.IsLiteral && f.FieldType == typeof(string)).Select(f => (Name: f.Name, Text: (string)f.GetRawConstantValue()!));
        foreach (var (name, text) in messages)
        {
            Check.Null(FrenchSpacing.Fault(text), "message " + name);
        }
        var root = FrenchSpacing.WebRoot();
        if (root is null)
        {
            return; // Sources not beside the binaries (pack): the page check runs from the repository only.
        }
        var files = Directory.GetFiles(Path.Combine(root, "js", "pages", "accueil"), "*.js").Append(Path.Combine(root, "js", "pages", "accueil.js"));
        foreach (var file in files)
        {
            foreach (var literal in FrenchSpacing.JsLiterals(File.ReadAllText(file)))
            {
                Check.Null(FrenchSpacing.Fault(literal), Path.GetFileName(file) + " : " + literal[..Math.Min(80, literal.Length)]);
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    private static string ProbeIdOf() => AccueilService.Catalog().Probes.SelectMany(c => c.Probes).First().Id;

    private static JsonElement Json(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }
}

/// <summary>Preference store that counts its writes (last view written at most once a minute).</summary>
internal sealed class CountingPreferenceStore : IPreferenceStore
{
    private readonly MemoryPreferenceStore memory = new();
    private readonly List<string> writes = [];

    public bool Persistent => true;

    public IReadOnlyList<string> Writes
    {
        get
        {
            lock (writes)
            {
                return [.. writes];
            }
        }
    }

    public bool TryGet(string key, out JsonElement value) => memory.TryGet(key, out value);

    public Task SetAsync(string key, JsonElement? value, CancellationToken cancellationToken)
    {
        lock (writes)
        {
            writes.Add(key);
        }
        return memory.SetAsync(key, value, cancellationToken);
    }
}

/// <summary>
/// French spacing of visible texts (KIT.md § 6, point 8): string literals of a page (template expressions and comments left out)
/// and the fault of one text.
/// </summary>
internal static class FrenchSpacing
{
    private static readonly System.Text.RegularExpressions.Regex Before = new(@"[0-9A-Za-zÀ-ÖØ-öø-ÿ’»)\]] [:;!?](?=[ \t\n""'`<$]|$)", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    public static string? Fault(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (Before.Match(text) is { Success: true } m)
        {
            return "espace ordinaire avant « " + m.Value[^1] + " »";
        }
        if (text.Contains("« ", StringComparison.Ordinal) || text.Contains(" »", StringComparison.Ordinal))
        {
            return "espace ordinaire à l’intérieur de « »";
        }
        return null;
    }

    /// <summary>The web folder of the sources, found from the binaries upwards (null outside the repository).</summary>
    public static string? WebRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var web = Path.Combine(dir.FullName, "web");
            if (File.Exists(Path.Combine(web, "js", "pages", "accueil.js")) && Directory.Exists(Path.Combine(dir.FullName, "src")))
            {
                return web;
            }
        }
        return null;
    }

    /// <summary>Text parts of the string and template literals of a script: code, comments, regular expressions and ${…} skipped.</summary>
    public static IEnumerable<string> JsLiterals(string src)
    {
        ArgumentNullException.ThrowIfNull(src);
        var result = new List<string>();
        var depth = new Stack<int>();
        var buffer = new System.Text.StringBuilder();
        var state = 'c';
        var last = ' ';
        for (var i = 0; i < src.Length; i++)
        {
            var c = src[i];
            if (state == 'c')
            {
                if (c == '/' && i + 1 < src.Length && src[i + 1] == '/')
                {
                    i = src.IndexOf('\n', i) is var j and >= 0 ? j : src.Length;
                    continue;
                }
                if (c == '/' && i + 1 < src.Length && src[i + 1] == '*')
                {
                    i = src.IndexOf("*/", i + 2, StringComparison.Ordinal) is var j and >= 0 ? j + 1 : src.Length;
                    continue;
                }
                if (c is '\'' or '"')
                {
                    state = c;
                    continue;
                }
                if (c == '`')
                {
                    state = 't';
                    continue;
                }
                if (c == '{' && depth.Count > 0)
                {
                    depth.Push(depth.Pop() + 1);
                }
                else if (c == '}' && depth.Count > 0)
                {
                    if (depth.Peek() == 0)
                    {
                        depth.Pop();
                        state = 't';
                        continue;
                    }
                    depth.Push(depth.Pop() - 1);
                }
                else if (c == '/' && "(,=:[!&|?{};+-*%<>~^".Contains(last, StringComparison.Ordinal))
                {
                    var cls = false;
                    for (i++; i < src.Length && src[i] != '\n'; i++)
                    {
                        if (src[i] == '\\')
                        {
                            i++;
                            continue;
                        }
                        if (src[i] == '[')
                        {
                            cls = true;
                        }
                        else if (src[i] == ']')
                        {
                            cls = false;
                        }
                        else if (src[i] == '/' && !cls)
                        {
                            break;
                        }
                    }
                    last = 'x';
                    continue;
                }
                if (!char.IsWhiteSpace(c))
                {
                    last = c;
                }
                continue;
            }
            if (c == '\\' && i + 1 < src.Length)
            {
                buffer.Append(c).Append(src[++i]);
                continue;
            }
            if ((state is '\'' or '"' && c == state) || (state == 't' && c == '`'))
            {
                result.Add(buffer.ToString());
                buffer.Clear();
                state = 'c';
                last = 'x';
                continue;
            }
            if (state == 't' && c == '$' && i + 1 < src.Length && src[i + 1] == '{')
            {
                result.Add(buffer.ToString());
                buffer.Clear();
                depth.Push(0);
                state = 'c';
                last = '{';
                i++;
                continue;
            }
            buffer.Append(c);
        }
        return result;
    }
}
