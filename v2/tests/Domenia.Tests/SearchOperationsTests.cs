using System.Text.Json;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Contract of the search.* operations over the simulated directory (example.local), through the real bridge.</summary>
internal static class SearchOperationsTests
{
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
    public static async Task Surveys_are_planned_confirmed_and_never_cover_the_whole_domain_by_stealth()
    {
        var bridge = new SimulatedBridge();
        var computers = Ids(await Ok(bridge, "search.browse", Args(new { dn = Paris, subtree = true, type = "computers", limit = 3 })));
        var selection = new { scope = "selection", global = false, hasTerm = false, wholeDomain = false, hasFilter = false, coversList = false, scopeLabel = "Paris", subtree = true, listLimit = 3 };
        var plan = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", ids = computers, context = selection }));
        Check.True(plan.GetProperty("admission").GetProperty("allowed").GetBoolean(), "sélection admise");
        string[] targets = [.. plan.GetProperty("targets").EnumerateArray().Select(t => t.GetProperty("id").GetString()!)];
        Check.Equal(computers.Length, targets.Length + plan.GetProperty("excluded").GetArrayLength(), "chaque ligne ciblée ou écartée avec sa raison");
        Check.True(targets.Length > 0, "au moins un poste actif");

        var global = new { scope = "results", global = true, hasTerm = false, wholeDomain = true, hasFilter = false, coversList = true, scopeLabel = "Partout", subtree = true, listLimit = 100 };
        var refusedPlan = await Ok(bridge, "search.survey.plan", Args(new { mode = "ping", ids = computers, context = global }));
        Check.False(refusedPlan.GetProperty("admission").GetProperty("allowed").GetBoolean(), "recherche globale sans terme refusée");
        Check.Equal("globalWithoutTerm", refusedPlan.GetProperty("admission").GetProperty("code").GetString(), "motif");
        Check.Equal(SearchErrors.SurveyRefused, await Refused(bridge, "search.survey.run", Args(new { mode = "ping", ids = computers, context = global })), "relevé refusé");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.survey.plan", Args(new { mode = "scan", ids = computers, context = selection })), "mode inconnu");

        var run = await Ok(bridge, "search.survey.run", Args(new { mode = "ping", ids = computers, context = selection }));
        Check.Equal(targets.Length, run.GetProperty("total").GetInt32(), "postes relevés");
        Check.Equal(targets.Length, run.GetProperty("done").GetInt32(), "relevé terminé");
        Check.False(run.GetProperty("stopped").GetBoolean(), "non arrêté");
        Check.True(bridge.Events.Any(e => e.Operation == "search.survey.run:progress"), "progression publiée");

        var user = Ids(await Ok(bridge, "search.run", Args(new { text = "martin", type = "users" })))[0];
        Check.Equal(SearchErrors.NotWorkstation, await Refused(bridge, "search.recheck", Args(new { id = user })), "aucune sonde vers un compte");
        var recheck = await Ok(bridge, "search.recheck", Args(new { id = targets[0] }));
        Check.Equal(targets[0], recheck.GetProperty("id").GetString(), "un seul poste");
        var diagnostic = await Ok(bridge, "search.netdiag", Args(new { ids = targets }));
        Check.Equal(targets.Length, diagnostic.GetProperty("lines").GetArrayLength(), "une ligne par poste actif");
    }

    [Test]
    public static async Task Memory_is_per_domain_flat_and_bounded()
    {
        var bridge = new SimulatedBridge();
        var empty = await Ok(bridge, "search.memory");
        Check.True(Names(empty).SequenceEqual(["recents", "favorites", "workspaces", "queryFavorites", "undo", "maxFavorites", "maxWorkspaces", "persistent", "warning"]),
            "propriétés : " + string.Join(",", Names(empty)));
        Check.Equal(0, empty.GetProperty("recents").GetArrayLength(), "aucune recherche récente");

        _ = await Ok(bridge, "search.recent.add", Args(new { kind = "search", text = "martin" }));
        var twice = await Ok(bridge, "search.recent.add", Args(new { kind = "search", text = "MARTIN" }));
        Check.Equal(1, twice.GetProperty("recents").GetArrayLength(), "doublon retiré");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.recent.add", Args(new { kind = "password", text = "x" })), "genre inconnu");
        var cleared = await Ok(bridge, "search.recent.clear");
        Check.Equal(0, cleared.GetProperty("recents").GetArrayLength(), "récents effacés");

        var pinned = await Ok(bridge, "search.favorite.pin", Args(new { dn = Paris, subtree = true, type = "computers" }));
        Check.Equal(1, pinned.GetProperty("favorites").GetArrayLength(), "OU épinglée");
        Check.Equal("Paris", pinned.GetProperty("favorites")[0].GetProperty("name").GetString(), "nom de l’OU");
        Check.Equal("search.favoriteRefused", await Refused(bridge, "search.favorite.pin", Args(new { dn = Root, subtree = true })), "domaine entier");
        Check.Equal("search.favoriteRefused", await Refused(bridge, "search.favorite.pin", Args(new { dn = "OU=Nulle," + Root, subtree = true })), "OU inconnue");
        var unpinned = await Ok(bridge, "search.favorite.unpin", Args(new { dn = Paris }));
        Check.Equal(0, unpinned.GetProperty("favorites").GetArrayLength(), "favori retiré");

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
        var suggestions = await Ok(bridge, "search.suggest", Args(new { text = "mar" }));
        Check.True(suggestions.GetArrayLength() <= SearchLimits.Suggestions, "huit suggestions au plus");
        Check.Equal("arguments.invalid", await Refused(bridge, "search.containers", Args(new { dn = Root })), "aucun argument");
        Check.Equal(0, bridge.Source.PresenceRound, "aucune manche de présence");
    }
}
