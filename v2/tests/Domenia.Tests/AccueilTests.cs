using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

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
        Check.Equal(412.0, entries.GetProperty("fleet.enabled").GetProperty("number").GetDouble(), "tuile « Comptes AD activés »");
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

    // ---------------------------------------------------------------- helpers

    private static string ProbeIdOf() => AccueilService.Catalog().Probes.SelectMany(c => c.Probes).First().Id;

    private static JsonElement Json(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }
}
