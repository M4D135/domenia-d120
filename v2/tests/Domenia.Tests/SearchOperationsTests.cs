using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>Contract of the search.* operations over the simulated directory (example.local), through the real bridge.</summary>
internal static class SearchOperationsTests
{
    /// <summary>
    /// Operations of the search module with their class in simulation: PlatformTests composes the closed registry from the
    /// list of each module, so a screen never edits the list of another one.
    /// </summary>
    public static readonly (string Name, OperationClass Class)[] Operations =
    [
        ("search.browse", OperationClass.LocalRead),
        ("search.catalog", OperationClass.LocalRead),
        ("search.checks.resume", OperationClass.Local),
        ("search.compare", OperationClass.LocalRead),
        ("search.containers", OperationClass.LocalRead),
        ("search.dns.reverse", OperationClass.NetworkRead),
        ("search.favorite.move", OperationClass.LocalWrite),
        ("search.favorite.pin", OperationClass.LocalWrite),
        ("search.favorite.unpin", OperationClass.LocalWrite),
        ("search.localQuery", OperationClass.LocalRead),
        ("search.measures", OperationClass.LocalRead),
        ("search.memory", OperationClass.LocalWrite),
        ("search.more", OperationClass.LocalRead),
        ("search.netdiag", OperationClass.NetworkRead),
        ("search.policy", OperationClass.LocalRead),
        ("search.preload", OperationClass.LocalRead),
        ("search.preview", OperationClass.LocalRead),
        ("search.query.favorite", OperationClass.LocalWrite),
        ("search.recent.add", OperationClass.LocalWrite),
        ("search.recent.clear", OperationClass.LocalWrite),
        ("search.recheck", OperationClass.NetworkRead),
        ("search.reconcile", OperationClass.LocalRead),
        ("search.revalidate", OperationClass.LocalRead),
        ("search.run", OperationClass.LocalRead),
        ("search.suggest", OperationClass.LocalRead),
        ("search.survey.forget", OperationClass.Local),
        ("search.survey.plan", OperationClass.LocalRead),
        ("search.survey.run", OperationClass.NetworkRead),
        ("search.survey.state", OperationClass.Local),
        ("search.survey.stop", OperationClass.Local),
        ("search.view", OperationClass.LocalRead),
        ("search.workspace.remove", OperationClass.LocalWrite),
        ("search.workspace.save", OperationClass.LocalWrite),
        ("search.workspace.undo", OperationClass.LocalWrite),
    ];

    private const string Root = "DC=example,DC=local";
    private const string Postes = "OU=Postes," + Root;
    private const string Paris = "OU=Paris,OU=Postes," + Root;

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static async Task<JsonElement> Ok(SimulatedBridge bridge, string operation, string arguments = "{}") =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, arguments));

    private static async Task<string> Refused(SimulatedBridge bridge, string operation, string arguments) =>
        (await bridge.CallAsync(operation, arguments)).Error?.Code ?? "(aucune erreur)";

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string[] Ids(JsonElement result) => [.. result.GetProperty("rows").EnumerateArray().Select(r => r.GetProperty("id").GetString()!)];

    [Test]
    public static async Task Run_returns_the_list_contract_ranked_like_domenia_1()
    {
        var bridge = new SimulatedBridge();
        var result = await Ok(bridge, "search.run", Args(new { text = "martin" }));
        Check.True(Names(result).SequenceEqual(["listId", "kind", "scope", "type", "text", "match", "plan", "rows", "loaded", "limit", "complete", "limitReached",
            "continuation", "counter", "absence", "offer", "dns", "view", "verdicts", "sourceLabel", "readAt", "appended"]), "propriétés : " + string.Join(",", Names(result)));
        Check.Equal("search", result.GetProperty("kind").GetString(), "recherche");
        Check.Equal(32, result.GetProperty("listId").GetString()!.Length, "identifiant de liste");
        Check.True(result.GetProperty("scope").GetProperty("wholeDomain").GetBoolean(), "partout");
        Check.Equal("default", result.GetProperty("plan").GetProperty("kind").GetString(), "plan par défaut");
        Check.Contains("(sAMAccountName=martin*)", result.GetProperty("plan").GetProperty("ldapFilter").GetString(), "filtre du mode annuaire");
        var rows = result.GetProperty("rows");
        Check.True(rows.GetArrayLength() > 0, "des résultats");
        Check.Equal(rows.GetArrayLength(), result.GetProperty("loaded").GetInt32(), "lignes chargées");
        int[] ranks = [.. rows.EnumerateArray().Select(r => r.GetProperty("rank").GetInt32())];
        Check.True(ranks.SequenceEqual(ranks.Order()), "rangs croissants");
        Check.True(rows.EnumerateArray().All(r => r.GetProperty("dn").GetString()!.EndsWith(Root, StringComparison.OrdinalIgnoreCase)), "objets du domaine");
        Check.False(result.GetProperty("appended").GetBoolean(), "première page");
        Check.True(result.GetProperty("readAt").GetString()!.EndsWith('Z'), "date UTC");
    }

    [Test]
    public static async Task Run_refuses_texts_that_would_walk_the_whole_domain()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(SearchErrors.TextInvalid, await Refused(bridge, "search.run", Args(new { text = "a" })), "un caractère");
        Check.Equal(SearchErrors.TextInvalid, await Refused(bridge, "search.run", Args(new { text = "**" })), "étoiles seules");
        Check.Equal(SearchErrors.TextInvalid, await Refused(bridge, "search.run", Args(new { text = "a b", match = "contains" })), "contient trop court");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.run", Args(new { text = "martin", type = "printers" })), "type inconnu");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.run", Args(new { text = "martin", limit = 20_001 })), "limite au-delà du maximum");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.run", Args(new { text = new string('x', 257) })), "texte trop long");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.run", Args(new { text = "martin", extra = 1 })), "propriété en trop");
        Check.Equal(DomeniaErrors.OuUnknown, await Refused(bridge, "search.run", Args(new { text = "pc", scope = "OU=Nulle,DC=example,DC=local" })), "OU inconnue");
    }

    [Test]
    public static async Task A_chosen_ou_bounds_the_global_search()
    {
        var bridge = new SimulatedBridge();
        var result = await Ok(bridge, "search.run", Args(new { text = "pc", scope = Paris, type = "computers" }));
        Check.False(result.GetProperty("scope").GetProperty("wholeDomain").GetBoolean(), "pas le domaine entier");
        Check.True(result.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("dn").GetString()!.EndsWith("," + Paris, StringComparison.OrdinalIgnoreCase)), "sous l’OU choisie");
        Check.True(result.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("kind").GetString() == "computer"), "postes seulement");
    }

    [Test]
    public static async Task Addresses_are_searched_in_local_readings_and_dns_waits_for_a_click()
    {
        var bridge = new SimulatedBridge();
        var found = await Ok(bridge, "search.run", Args(new { text = "10.10.1.12" }));
        Check.Equal("address", found.GetProperty("kind").GetString(), "recherche par adresse");
        Check.True(found.GetProperty("rows").GetArrayLength() > 0, "poste relevé");
        Check.True(found.GetProperty("rows").EnumerateArray().Any(r => r.GetProperty("address").GetProperty("ip").GetString() == "10.10.1.12"), "adresse relevée");
        Check.Equal(JsonValueKind.Null, found.GetProperty("dns").ValueKind, "pas d’offre DNS quand un poste est trouvé");
        var none = await Ok(bridge, "search.run", Args(new { text = "10.99.99.99" }));
        Check.Equal(0, none.GetProperty("rows").GetArrayLength(), "aucun relevé");
        Check.Equal("10.99.99.99", none.GetProperty("dns").GetProperty("ip").GetString(), "offre DNS seulement");
        var mac = await Ok(bridge, "search.run", Args(new { text = "00-00-00-00-00-01" }));
        Check.Equal("address", mac.GetProperty("kind").GetString(), "MAC");
        Check.Equal(JsonValueKind.Null, mac.GetProperty("dns").ValueKind, "pas de DNS pour une MAC");
        Check.Equal(SearchErrors.TextInvalid, await Refused(bridge, "search.dns.reverse", Args(new { ip = "pc-par-0001" })), "DNS inverse d’une IPv4 seulement");
        var reverse = await Ok(bridge, "search.dns.reverse", Args(new { ip = "10.10.1.12" }));
        Check.Equal("10.10.1.12", reverse.GetProperty("ip").GetString(), "adresse demandée");
    }

    [Test]
    public static async Task More_reads_the_following_rows_only()
    {
        var bridge = new SimulatedBridge();
        var first = await Ok(bridge, "search.browse", Args(new { dn = Postes, subtree = true, type = "computers", limit = 50 }));
        Check.Equal("browse", first.GetProperty("kind").GetString(), "contenu d’OU");
        Check.True(first.GetProperty("limitReached").GetBoolean(), "liste limitée");
        var continuation = first.GetProperty("continuation");
        Check.True(continuation.GetProperty("allowed").GetBoolean(), "suite proposée");
        Check.Equal(100, continuation.GetProperty("nextLimit").GetInt32(), "liste doublée");
        var listId = first.GetProperty("listId").GetString()!;
        var more = await Ok(bridge, "search.more", Args(new { listId, limit = 100 }));
        Check.True(more.GetProperty("appended").GetBoolean(), "lignes ajoutées");
        Check.Equal(100, more.GetProperty("loaded").GetInt32(), "cent lignes en tout");
        Check.Equal(50, more.GetProperty("rows").GetArrayLength(), "cinquante nouvelles lignes");
        Check.False(Ids(first).Intersect(Ids(more)).Any(), "aucune ligne relue");
        Check.Equal(SearchErrors.ListComplete, await Refused(bridge, "search.more", Args(new { listId, limit = 80 })), "taille déjà chargée");
        Check.Equal(SearchErrors.ListUnknown, await Refused(bridge, "search.more", Args(new { listId = new string('a', 32), limit = 200 })), "liste inconnue");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.more", Args(new { listId = "../x", limit = 200 })), "identifiant mal formé");
    }

    [Test]
    public static async Task Views_and_local_queries_are_bounded_and_explained()
    {
        var bridge = new SimulatedBridge();
        var locked = await Ok(bridge, "search.view", Args(new { id = "lockedusers", subtree = true, wholeDomain = true }));
        Check.Equal("view", locked.GetProperty("kind").GetString(), "vue");
        Check.Equal("lockedusers", locked.GetProperty("view").GetProperty("id").GetString(), "vue demandée");
        Check.True(locked.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("kind").GetString() == "user"), "comptes seulement");
        Check.Equal(SearchErrors.ViewUnknown, await Refused(bridge, "search.view", Args(new { id = "everything", subtree = true, wholeDomain = true })), "vue inconnue");

        var query = await Ok(bridge, "search.localQuery", Args(new { id = "local.lowdisk", dn = Postes, subtree = true, verdict = "all", limit = 2000 }));
        Check.Equal("localQuery", query.GetProperty("kind").GetString(), "requête locale");
        var verdicts = query.GetProperty("verdicts");
        var total = verdicts.GetProperty("match").GetInt32() + verdicts.GetProperty("unknown").GetInt32() + verdicts.GetProperty("noMatch").GetInt32();
        Check.Equal(total, query.GetProperty("loaded").GetInt32(), "trois verdicts pour tous les postes");
        Check.True(query.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("verdict").ValueKind == JsonValueKind.String), "verdict sur chaque ligne");
        var match = await Ok(bridge, "search.localQuery", Args(new { id = "local.lowdisk", dn = Postes, subtree = true, verdict = "match", limit = 2000 }));
        Check.Equal(verdicts.GetProperty("match").GetInt32(), match.GetProperty("loaded").GetInt32(), "correspondants seulement");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.localQuery", Args(new { id = "local.lowdisk", dn = Postes, verdict = "maybe" })), "verdict inconnu");

        var catalog = await Ok(bridge, "search.catalog");
        Check.Equal(SearchViews.All(TestClock.Reference).Length + SearchViews.LocalQueries.Length, catalog.GetProperty("entries").GetArrayLength(), "vues et requêtes locales");
        Check.True(catalog.GetProperty("entries").EnumerateArray().Any(e => e.GetProperty("id").GetString() == "local:lowdisk" && e.GetProperty("local").GetBoolean()), "requête locale au catalogue");
    }

    [Test]
    public static async Task Preview_compare_and_revalidate_read_the_local_base_only()
    {
        var bridge = new SimulatedBridge();
        var users = await Ok(bridge, "search.run", Args(new { text = "martin", type = "users" }));
        var ids = Ids(users);
        Check.True(ids.Length >= 2, "au moins deux comptes");
        var preview = await Ok(bridge, "search.preview", Args(new { id = ids[0] }));
        Check.Equal(ids[0], preview.GetProperty("row").GetProperty("id").GetString(), "objet demandé");
        Check.True(preview.GetProperty("sections").GetArrayLength() > 0, "sections");
        Check.Equal(SearchErrors.ObjectUnknown, await Refused(bridge, "search.preview", Args(new { id = Guid.Empty.ToString("D") })), "objet inconnu");

        var comparison = await Ok(bridge, "search.compare", Args(new { ids = ids.Take(2).ToArray() }));
        Check.Equal("user", comparison.GetProperty("kind").GetString(), "comptes comparés");
        Check.True(comparison.GetProperty("lines").GetArrayLength() > 0, "lignes de comparaison");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.compare", Args(new { ids = ids.Take(1).ToArray() })), "un seul objet");
        var computers = await Ok(bridge, "search.browse", Args(new { dn = Paris, subtree = true, type = "computers", limit = 3 }));
        Check.Equal(SearchErrors.CompareInvalid, await Refused(bridge, "search.compare", Args(new { ids = new[] { ids[0], Ids(computers)[0] } })), "types mélangés");

        var revalidated = await Ok(bridge, "search.revalidate", Args(new { ids = ids.Take(2).ToArray() }));
        Check.Equal(2, revalidated.GetProperty("rows").GetArrayLength(), "objets relus");
        Check.Equal(0, revalidated.GetProperty("missing").GetArrayLength(), "aucun objet absent");
        Check.Equal(0, bridge.Source.PresenceRound, "aucune manche de présence");
    }

    [Test]
    public static async Task Surveys_are_planned_from_the_list_confirmed_once_and_never_cover_the_whole_domain_by_stealth()
    {
        var bridge = new SimulatedBridge();
        var paris = await Ok(bridge, "search.browse", Args(new { dn = Paris, subtree = true, type = "computers", limit = 3 }));
        var listId = paris.GetProperty("listId").GetString()!;
        var computers = Ids(paris);
        var plan = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", listId, ids = computers, scope = "selection" }));
        Check.True(plan.GetProperty("admission").GetProperty("allowed").GetBoolean(), "lignes de l’OU admises");
        Check.Equal(32, plan.GetProperty("planId").GetString()!.Length, "plan identifié");
        Check.True(plan.GetProperty("details").GetArrayLength() >= 3, "profil, budget et fenêtre annoncés");
        Check.Contains("Fenêtre de collecte", string.Join(" ", plan.GetProperty("details").EnumerateArray().Select(d => d.GetString())), "fenêtre de collecte");
        string[] targets = [.. plan.GetProperty("targets").EnumerateArray().Select(t => t.GetProperty("id").GetString()!)];
        Check.Equal(computers.Length, targets.Length + plan.GetProperty("excluded").GetArrayLength(), "chaque ligne ciblée ou écartée avec sa raison");
        Check.True(targets.Length > 0, "au moins un poste actif");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.survey.plan", Args(new { mode = "scan", listId, ids = computers })), "mode inconnu");

        var planId = plan.GetProperty("planId").GetString()!;
        var run = await Ok(bridge, "search.survey.run", Args(new { planId }));
        Check.Equal(targets.Length, run.GetProperty("total").GetInt32(), "postes relevés");
        Check.Equal(targets.Length, run.GetProperty("done").GetInt32(), "relevé terminé");
        Check.False(run.GetProperty("stopped").GetBoolean(), "non arrêté");
        Check.True(run.GetProperty("status").GetProperty("lines").GetArrayLength() >= 6, "détail de l’état du relevé");
        Check.True(bridge.Events.Any(e => e.Operation == "search.survey.run:progress"), "progression publiée");
        Check.Equal(SearchErrors.SurveyPlanUnknown, await Refused(bridge, "search.survey.run", Args(new { planId })), "un plan ne sert qu’une fois");

        var users = await Ok(bridge, "search.run", Args(new { text = "martin", type = "users" }));
        var user = Ids(users)[0];
        Check.Equal(SearchErrors.NotWorkstation, await Refused(bridge, "search.recheck", Args(new { id = user, listId = users.GetProperty("listId").GetString() })), "aucune sonde vers un compte");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.recheck", Args(new { id = user })), "le moteur juge sur la liste affichée : listId obligatoire");
        var recheck = await Ok(bridge, "search.recheck", Args(new { id = targets[0], listId }));
        Check.Equal(targets[0], recheck.GetProperty("id").GetString(), "un seul poste");
        var ping = await Ok(bridge, "search.recheck", Args(new { id = targets[0], mode = "ping", listId, onClick = true }));
        Check.Equal(targets[0], ping.GetProperty("id").GetString(), "vérification au clic");
        var diagnostic = await Ok(bridge, "search.netdiag", Args(new { listId, ids = targets }));
        Check.Equal(targets.Length, diagnostic.GetProperty("lines").GetArrayLength(), "une ligne par poste actif");
    }

    [Test]
    public static async Task A_forged_survey_is_refused_by_the_engine()
    {
        var bridge = new SimulatedBridge();
        var paris = await Ok(bridge, "search.browse", Args(new { dn = Paris, subtree = true, type = "computers", limit = 3 }));
        var parisId = paris.GetProperty("listId").GetString()!;
        // Rows of another list: the engine checks every target against the list, the page cannot add any GUID.
        var lyon = Ids(await Ok(bridge, "search.browse", Args(new { dn = "OU=Lyon,OU=Postes," + Root, subtree = true, type = "computers", limit = 2 })));
        Check.Equal(SearchErrors.SurveyRefused, await Refused(bridge, "search.survey.plan", Args(new { mode = "ping", listId = parisId, ids = lyon })), "GUID hors de la liste");
        Check.Equal(SearchErrors.ListUnknown, await Refused(bridge, "search.survey.plan", Args(new { mode = "ping", listId = new string('a', 32), ids = lyon })), "liste inconnue");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.survey.plan", Args(new { mode = "ping", listId = parisId, ids = lyon, context = new { global = false } })),
            "aucun contexte accepté de la page");

        // A ready-made view listed on the whole domain: never surveyed, not even a partial selection of it (RCH-117).
        var view = await Ok(bridge, "search.view", Args(new { id = "stalecomputers", wholeDomain = true, subtree = true, limit = 20 }));
        var viewId = view.GetProperty("listId").GetString()!;
        var some = Ids(view).Take(2).ToArray();
        var refused = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", listId = viewId, ids = some, scope = "selection" }));
        Check.False(refused.GetProperty("admission").GetProperty("allowed").GetBoolean(), "vue sur tout le domaine refusée");
        Check.Equal("wholeDomainView", refused.GetProperty("admission").GetProperty("code").GetString(), "motif");
        Check.Equal(SearchErrors.SurveyRefused, await Refused(bridge, "search.survey.run", Args(new { planId = refused.GetProperty("planId").GetString() })), "lancement refusé");
        Check.Equal(SearchErrors.SurveyRefused, await Refused(bridge, "search.netdiag", Args(new { listId = viewId, ids = some })), "diagnostic refusé");
        Check.Equal(SearchErrors.SurveyRefused, await Refused(bridge, "search.recheck", Args(new { id = some[0], listId = viewId })), "revérification refusée");

        // The whole list of the root, without any filter: refused (RCH-090); a filtered part of it is its own filter.
        var root = await Ok(bridge, "search.browse", Args(new { dn = Root, subtree = true, type = "computers", limit = 40 }));
        var rootId = root.GetProperty("listId").GetString()!;
        var all = Ids(root);
        var whole = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", listId = rootId, ids = all, scope = "results" }));
        Check.Equal("domainRoot", whole.GetProperty("admission").GetProperty("code").GetString(), "racine sans filtre refusée");
        var part = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", listId = rootId, ids = all.Take(5).ToArray(), scope = "results" }));
        Check.True(part.GetProperty("admission").GetProperty("allowed").GetBoolean(), "partie filtrée admise");

        // Above 100 workstations the typed count is checked again by the engine, and the plan expires after ten minutes.
        var big = await Ok(bridge, "search.browse", Args(new { dn = Postes, subtree = true, type = "computers", limit = 300 }));
        var bigId = big.GetProperty("listId").GetString()!;
        var many = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", listId = bigId, ids = Ids(big), scope = "results" }));
        Check.True(many.GetProperty("typedCountRequired").GetBoolean(), "saisie du nombre exigée");
        Check.Equal(SearchErrors.SurveyTypedCount, await Refused(bridge, "search.survey.run", Args(new { planId = many.GetProperty("planId").GetString(), typedCount = 3 })), "nombre saisi faux");
        var later = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", listId = parisId, ids = Ids(paris), scope = "results" }));
        bridge.Clock.Advance(TimeSpan.FromMinutes(11));
        Check.Equal(SearchErrors.SurveyPlanUnknown, await Refused(bridge, "search.survey.run", Args(new { planId = later.GetProperty("planId").GetString() })), "plan expiré");
    }

    [Test]
    public static async Task A_view_needs_an_ou_or_the_explicit_whole_domain()
    {
        var bridge = new SimulatedBridge();
        Check.Equal("arguments.invalid", await Refused(bridge, "search.view", Args(new { id = "lockedusers", subtree = true, wholeDomain = false, limit = 10 })), "ni OU ni domaine entier");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.view", Args(new { id = "lockedusers", dn = Root, subtree = true, wholeDomain = false, limit = 10 })), "la racine sans choix explicite");
        var whole = await Ok(bridge, "search.view", Args(new { id = "lockedusers", subtree = true, wholeDomain = true, limit = 10 }));
        Check.True(whole.GetProperty("scope").GetProperty("wholeDomain").GetBoolean(), "domaine entier explicite");
        Check.False(whole.GetProperty("view").GetProperty("surveyAllowed").GetBoolean(), "aucun relevé proposé");
    }

    [Test]
    public static async Task Two_continuations_of_an_address_list_never_read_twice()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        var parc = await Ok(bridge, "search.browse", Args(new { dn = Postes, subtree = true, type = "computers", limit = 2000 }));
        var shared = parc.GetProperty("rows").EnumerateArray()
            .Select(r => r.GetProperty("address").ValueKind == JsonValueKind.Object ? r.GetProperty("address").GetProperty("ip").GetString() : null)
            .OfType<string>().GroupBy(ip => ip).FirstOrDefault(g => g.Count() > 1)?.Key;
        Check.True(shared is not null, "adresse partagée par deux postes (réutilisation DHCP)");
        var first = await Ok(bridge, "search.run", Args(new { text = shared, limit = 1 }));
        Check.True(first.GetProperty("limitReached").GetBoolean(), "liste d’adresse limitée");
        var listId = first.GetProperty("listId").GetString();
        var both = await Task.WhenAll(bridge.CallAsync("search.more", Args(new { listId, limit = 2 })), bridge.CallAsync("search.more", Args(new { listId, limit = 2 })));
        Check.Equal(1, both.Count(r => r.Error is null), "une seule suite lue");
        Check.Equal(SearchErrors.ListBusy, both.First(r => r.Error is not null).Error!.Code, "la seconde est refusée, jamais mise en file");
    }

    [Test]
    public static async Task Reconcile_adds_new_objects_and_never_removes_rows()
    {
        var bridge = new SimulatedBridge();
        var paris = await Ok(bridge, "search.browse", Args(new { dn = Paris, subtree = true, type = "computers", limit = 5 }));
        var listId = paris.GetProperty("listId").GetString()!;
        var again = await Ok(bridge, "search.reconcile", Args(new { listId }));
        Check.True(Names(again).SequenceEqual(["listId", "rows", "added", "moved", "missing", "loaded", "checkpoint", "readAt", "summary"]), "propriétés : " + string.Join(",", Names(again)));
        Check.Equal(0, again.GetProperty("added").GetArrayLength(), "rien de nouveau");
        Check.Equal(0, again.GetProperty("missing").GetArrayLength(), "aucun absent");
        Check.Contains("Point de reprise", again.GetProperty("checkpoint").GetString(), "point de reprise tenu");
        var measures = await Ok(bridge, "search.measures", Args(new { listId, offset = 0 }));
        Check.Equal(paris.GetProperty("rows").GetArrayLength(), measures.GetProperty("rows").GetArrayLength(), "mesures de la liste");
        Check.Equal(JsonValueKind.Null, measures.GetProperty("next").ValueKind, "une seule page");
        var preload = await Ok(bridge, "search.preload", Args(new { id = Ids(paris)[0] }));
        Check.Equal(Ids(paris)[0], preload.GetProperty("row").GetProperty("id").GetString(), "fiche relue");
        Check.Equal(0, bridge.Source.PresenceRound, "aucune manche de présence");
    }

    [Test]
    public static async Task Local_queries_show_the_signal_first_with_their_coverage()
    {
        var bridge = new SimulatedBridge();
        var all = await Ok(bridge, "search.localQuery", Args(new { id = "local.lowdisk", dn = Root, subtree = true, verdict = "all", limit = 50 }));
        var verdicts = all.GetProperty("verdicts");
        var match = verdicts.GetProperty("match").GetInt32();
        string[] labels = [.. all.GetProperty("rows").EnumerateArray().Select(r => r.GetProperty("verdict").GetString()!.Split(" · ")[0])];
        Check.True(labels.Take(Math.Min(match, labels.Length)).All(l => l == "Correspond"), "les correspondants d’abord");
        Check.True(verdicts.GetProperty("coverage").GetString()!.Length > 0, "couverture du périmètre dite");
    }

    [Test]
    public static async Task Memory_is_per_domain_flat_and_bounded()
    {
        var bridge = new SimulatedBridge();
        var empty = await Ok(bridge, "search.memory");
        Check.True(Names(empty).SequenceEqual(["recents", "favorites", "workspaces", "queryFavorites", "undo", "maxFavorites", "maxWorkspaces", "persistent", "warning", "imported"]),
            "propriétés : " + string.Join(",", Names(empty)));
        Check.Equal(0, empty.GetProperty("recents").GetArrayLength(), "aucune recherche récente");
        // RCH-004: the two OU searches of Domenia 1 became favourites once (the text search on the whole domain is left out).
        Check.Equal(2, empty.GetProperty("imported").GetInt32(), "recherches de Domenia 1 reprises");
        Check.Equal(2, empty.GetProperty("favorites").GetArrayLength(), "favoris repris");
        var again = await Ok(bridge, "search.memory");
        Check.Equal(0, again.GetProperty("imported").GetInt32(), "reprise unique");
        var baseline = again.GetProperty("favorites").GetArrayLength();

        _ = await Ok(bridge, "search.recent.add", Args(new { kind = "search", text = "martin" }));
        var twice = await Ok(bridge, "search.recent.add", Args(new { kind = "search", text = "MARTIN" }));
        Check.Equal(1, twice.GetProperty("recents").GetArrayLength(), "doublon retiré");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.recent.add", Args(new { kind = "password", text = "x" })), "genre inconnu");
        var cleared = await Ok(bridge, "search.recent.clear");
        Check.Equal(0, cleared.GetProperty("recents").GetArrayLength(), "récents effacés");

        var pinned = await Ok(bridge, "search.favorite.pin", Args(new { dn = Paris, subtree = true, type = "computers" }));
        Check.Equal(baseline + 1, pinned.GetProperty("favorites").GetArrayLength(), "OU épinglée");
        Check.Equal("Paris", pinned.GetProperty("favorites")[baseline].GetProperty("name").GetString(), "nom de l’OU");
        Check.Equal("search.favoriteRefused", await Refused(bridge, "search.favorite.pin", Args(new { dn = Root, subtree = true })), "domaine entier");
        Check.Equal("search.favoriteRefused", await Refused(bridge, "search.favorite.pin", Args(new { dn = "OU=Nulle," + Root, subtree = true })), "OU inconnue");
        var unpinned = await Ok(bridge, "search.favorite.unpin", Args(new { dn = Paris }));
        Check.Equal(baseline, unpinned.GetProperty("favorites").GetArrayLength(), "favori retiré");

        var draft = new { name = "Postes de Paris", dn = Paris, subtree = true, type = "computers", presence = "online", filter = "pc", limit = 200, columnSet = "computers", layout = (object?)null };
        var saved = await Ok(bridge, "search.workspace.save", Args(draft));
        Check.Equal(1, saved.GetProperty("workspaces").GetArrayLength(), "vue enregistrée");
        Check.Equal("search.workspaceRefused", await Refused(bridge, "search.workspace.save", Args(draft)), "même nom refusé");
        var id = saved.GetProperty("workspaces")[0].GetProperty("id").GetString()!;
        var removed = await Ok(bridge, "search.workspace.remove", Args(new { id }));
        Check.Equal(0, removed.GetProperty("workspaces").GetArrayLength(), "vue retirée");
        var restored = await Ok(bridge, "search.workspace.undo");
        Check.Equal(1, restored.GetProperty("workspaces").GetArrayLength(), "vue rétablie");

        var star = await Ok(bridge, "search.query.favorite", Args(new { id = "local:lowdisk", favorite = true }));
        Check.Equal("local:lowdisk", star.GetProperty("queryFavorites")[0].GetString(), "requête épinglée");
        Check.Equal("search.queryUnknown", await Refused(bridge, "search.query.favorite", Args(new { id = "../x", favorite = true })), "requête inconnue");
    }

    [Test]
    public static async Task Tree_containers_and_suggestions_never_query_the_directory()
    {
        var bridge = new SimulatedBridge();
        var containers = await Ok(bridge, "search.containers");
        Check.True(containers.EnumerateArray().Any(c => c.GetProperty("name").GetString() == "Users" && !c.GetProperty("system").GetBoolean()), "conteneur Users");
        Check.True(containers.EnumerateArray().All(c => c.GetProperty("objects").GetInt32() == -1), "aucun comptage sans demande");
        var counted = await Ok(bridge, "search.containers", Args(new { counts = true }));
        Check.True(counted.EnumerateArray().Any(c => c.GetProperty("objects").GetInt32() > 0), "comptage sur demande");
        var suggestions = await Ok(bridge, "search.suggest", Args(new { text = "mar" }));
        Check.True(suggestions.GetArrayLength() <= SearchLimits.Suggestions, "huit suggestions au plus");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.containers", Args(new { dn = Root })), "aucun argument");
        Check.Equal(0, bridge.Source.PresenceRound, "aucune manche de présence");
    }

    // ---------------------------------------------------------------- tour 2 of the critique (written, run at the very end)

    [Test]
    public static async Task A_root_container_is_a_perimeter_for_the_search_the_views_and_the_local_queries()
    {
        var bridge = new SimulatedBridge();
        const string computers = "CN=Computers," + Root;
        var browsed = await Ok(bridge, "search.browse", Args(new { dn = computers, subtree = true }));
        Check.Equal(computers, browsed.GetProperty("scope").GetProperty("dn").GetString(), "contenu du conteneur");
        var found = await Ok(bridge, "search.run", Args(new { text = "a", scope = computers, type = "all", match = "contains" }));
        Check.Equal(computers, found.GetProperty("scope").GetProperty("dn").GetString(), "recherche dans « Computers » : jamais « OU inconnue »");
        var view = await bridge.CallAsync("search.view", Args(new { id = "oucomputers", dn = computers, subtree = true, wholeDomain = false }));
        Check.True(view.Error is null || view.Error.Code != "ou.unknown", "vue sur un conteneur de la racine admise");
        var local = await bridge.CallAsync("search.localQuery", Args(new { id = "local.lowdisk", dn = computers, subtree = true }));
        Check.True(local.Error is null || local.Error.Code != "ou.unknown", "requête locale sur un conteneur de la racine admise");
        Check.Equal("ou.unknown", await Refused(bridge, "search.run", Args(new { text = "a", scope = "CN=Inconnu," + Root })), "un conteneur inconnu reste refusé");
    }

    [Test]
    public static async Task The_policy_gives_the_defaults_of_Domenia_1_without_a_configuration()
    {
        var bridge = new SimulatedBridge();
        var policy = await Ok(bridge, "search.policy");
        Check.False(policy.GetProperty("revalidateListed").GetBoolean(), "revalidation des objets listés désactivée par défaut");
        Check.Equal(60, policy.GetProperty("revalidateSeconds").GetInt32(), "toutes les 60 s quand un administrateur l’active");
        Check.Equal(SearchSurvey.MaxTargets, policy.GetProperty("maxTargets").GetInt32(), "plafond d’un relevé : 500");
        Check.Equal(4, policy.GetProperty("concurrency").GetInt32(), "quatre postes à la fois");
        Check.Equal(192, policy.GetProperty("pingBatch").GetInt32(), "échos par lots de 192");
        Check.Equal(0, policy.GetProperty("hiddenActions").GetArrayLength(), "aucune action masquée");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.policy", Args(new { x = 1 })), "aucun argument");
    }

    [Test]
    public static void The_policy_reads_the_configuration_and_the_settings_strictly()
    {
        using var config = JsonDocument.Parse("""{ "streaming": { "RevalidateListedObjects": "oui", "RevalidateIntervalSeconds": 120 }, "UI": { "Elements": { "rechercher.export": "Masqué", "rechercher.compare": "Grisé", "fiche.x": "Hidden", "rechercher.refresh": "Rouge" } } }""");
        using var settings = JsonDocument.Parse("""{ "concurrency": 8, "maxTargets": 2000 }""");
        var policy = SearchPolicyRules.Read(config.RootElement, settings.RootElement);
        Check.True(policy.RevalidateListed, "section et clé lues sans casse, « oui » vaut vrai");
        Check.Equal(120, policy.RevalidateSeconds, "intervalle dans ses bornes");
        Check.True(policy.HiddenActions.SequenceEqual(["rechercher.export"]), "action masquée de cet écran seulement");
        Check.True(policy.DisabledActions.SequenceEqual(["rechercher.compare"]), "action grisée");
        Check.Equal(1, policy.Problems.Length, "valeur inconnue signalée, jamais devinée");
        Check.Equal(8, policy.Concurrency, "budget de Paramètres");
        Check.Equal(2000, policy.MaxTargets, "plafond de Paramètres");
        using var wrong = JsonDocument.Parse("""{ "Streaming": { "RevalidateIntervalSeconds": 5 } }""");
        using var badSettings = JsonDocument.Parse("""{ "concurrency": 64 }""");
        var fallback = SearchPolicyRules.Read(wrong.RootElement, badSettings.RootElement);
        Check.Equal(60, fallback.RevalidateSeconds, "hors limites : 60 s");
        Check.Equal(4, fallback.Concurrency, "hors limites : 4");
        Check.Equal(2, fallback.Problems.Length, "les deux valeurs hors limites sont dites");
        Check.Equal("hidden", SearchPolicyRules.Mode("Collapsed"), "synonymes de Domenia 1");
        Check.Equal("default", SearchPolicyRules.Mode("Visible"), "visible = par défaut");
    }

    [Test]
    public static async Task The_survey_ceiling_of_Parametres_bounds_the_plan()
    {
        var preferences = new MemoryPreferenceStore();
        using var budgets = JsonDocument.Parse("""{ "maxTargets": 2 }""");
        await preferences.SetAsync("settings.collection", budgets.RootElement.Clone(), CancellationToken.None);
        var bridge = new SimulatedBridge(preferences: preferences);
        var paris = await Ok(bridge, "search.browse", Args(new { dn = Paris, subtree = true, type = "computers", limit = 10 }));
        var plan = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", listId = paris.GetProperty("listId").GetString(), ids = Ids(paris), scope = "selection" }));
        Check.False(plan.GetProperty("admission").GetProperty("allowed").GetBoolean(), "au-delà du plafond réglé dans Paramètres, le relevé est refusé");
        Check.Equal(2, plan.GetProperty("admission").GetProperty("maximum").GetInt32(), "plafond lu dans settings.collection");
    }
}
