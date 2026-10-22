using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Operations of the shell through the real dispatcher in simulation (docs/ops/shell.md §§ 1 and 2).</summary>
internal static class ShellOperationsTests
{
    private const string Root = "DC=example,DC=local";
    private static readonly string[] UserKind = ["user"];

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static async Task<JsonElement> ResultAsync(SimulatedBridge bridge, string operation, string arguments = "{}") =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, arguments));

    private static async Task<string> ErrorAsync(SimulatedBridge bridge, string operation, string arguments)
    {
        var response = await bridge.CallAsync(operation, arguments);
        Check.Equal("error", response.Kind, "refus attendu pour " + operation + " " + arguments);
        return response.Error!.Code;
    }

    [Test]
    public static async Task Interface_preferences_are_bounded_and_read_back()
    {
        var bridge = new SimulatedBridge();
        var empty = await ResultAsync(bridge, "shell.interface.get");
        Check.True(Names(empty).SequenceEqual(["persistent", "interface", "layouts", "boards", "ouFavourites", "warning"]), "forme : " + string.Join(",", Names(empty)));
        Check.Equal(0, empty.GetProperty("ouFavourites").GetArrayLength(), "aucun favori");

        var saved = await ResultAsync(bridge, "shell.interface.set",
            "{\"interface\":{\"theme\":\"dark\",\"navWidth\":999,\"unknown\":1,\"navCollapsed\":true},"
            + "\"layouts\":{\"grid:rechercher\":{\"columns\":[\"cn\"]},\"bad key\":{}},"
            + "\"boards\":{\"interface\":{\"Format\":\"Domenia.BoardDocument.2\"}},"
            + "\"ouFavourites\":[\"OU=Postes," + Root + "\",\"" + Root + "\",\"OU=Ailleurs,DC=autre,DC=local\"]}");
        var iface = saved.GetProperty("interface");
        Check.Equal("dark", iface.GetProperty("theme").GetString(), "thème");
        Check.True(iface.GetProperty("navCollapsed").GetBoolean(), "menu replié");
        Check.False(iface.TryGetProperty("navWidth", out _), "largeur hors bornes refusée");
        Check.False(iface.TryGetProperty("unknown", out _), "champ inconnu ignoré");
        Check.True(saved.GetProperty("layouts").TryGetProperty("grid:rechercher", out _), "disposition de liste");
        Check.False(saved.GetProperty("layouts").TryGetProperty("bad key", out _), "clé invalide refusée");
        Check.True(saved.GetProperty("boards").TryGetProperty("interface", out _), "tableau");
        Check.Equal(1, saved.GetProperty("ouFavourites").GetArrayLength(), "favoris du domaine sans la racine");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("valeur(s) refusée(s)", StringComparison.Ordinal)), "refus compté au journal");

        var again = await ResultAsync(bridge, "shell.interface.get");
        Check.Equal("dark", again.GetProperty("interface").GetProperty("theme").GetString(), "relu");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.interface.set", "{\"interface\":3}"), "objet attendu");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.interface.set", "{\"other\":{}}"), "argument inconnu");
    }

    [Test]
    public static async Task A_failed_save_keeps_the_session_and_warns()
    {
        var bridge = new SimulatedBridge(preferences: new FailingPreferenceStore());
        var saved = await ResultAsync(bridge, "shell.interface.set", "{\"interface\":{\"theme\":\"light\"}}");
        Check.Equal("light", saved.GetProperty("interface").GetProperty("theme").GetString(), "valeur gardée pour la session");
        Check.Contains("non enregistr", saved.GetProperty("warning").GetString(), "avertissement");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("Préférences non enregistrées", StringComparison.Ordinal)), "journal");
    }

    [Test]
    public static async Task Activity_counts_reads_and_receipts_of_the_session()
    {
        var bridge = new SimulatedBridge();
        var activity = await ResultAsync(bridge, "shell.activity");
        Check.True(Names(activity).SequenceEqual(["tasks", "receipts", "active", "counterText", "detail", "journal", "at"]), "forme : " + string.Join(",", Names(activity)));
        Check.Equal(0, activity.GetProperty("active").GetInt32(), "rien en cours");
        Check.Equal("", activity.GetProperty("counterText").GetString(), "compteur vide à zéro");
        Check.True(activity.GetProperty("receipts").GetProperty("available").GetBoolean(), "reçus lisibles");
        Check.Contains("aucun reçu à vérifier", activity.GetProperty("detail").GetString(), "phrase de l’infobulle");
        Check.True(activity.GetProperty("journal").GetArrayLength() <= ShellActivityService.MaxJournalLines, "journal borné");
    }

    [Test]
    public static async Task Lookup_finds_objects_and_verify_rechecks_dn_and_guid()
    {
        var bridge = new SimulatedBridge();
        var found = await ResultAsync(bridge, "shell.lookup", "{\"text\":\"pos\",\"kinds\":[\"ou\",\"computer\"]}");
        Check.True(Names(found).SequenceEqual(["items", "total", "truncated", "summary"]), "forme");
        var items = found.GetProperty("items").EnumerateArray().ToList();
        Check.True(items.Count is > 0 and <= 100, "résultats bornés : " + items.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));
        Check.True(items.All(i => i.GetProperty("kind").GetString() is "computer" or "ou"), "natures demandées seulement");
        Check.Equal(found.GetProperty("total").GetInt32() > 100, found.GetProperty("truncated").GetBoolean(), "troncature cohérente");
        var first = items[0];
        Check.True(Names(first).SequenceEqual(["kind", "kindLabel", "name", "dn", "objectGuid", "detail", "path", "enabled"]), "forme d’un objet");

        var dn = first.GetProperty("dn").GetString()!;
        var guid = first.GetProperty("objectGuid").GetString()!;
        var ok = await ResultAsync(bridge, "shell.lookup.verify", JsonSerializer.Serialize(new { dn, objectGuid = guid }));
        Check.Equal("ok", ok.GetProperty("state").GetString(), "même DN, même GUID");
        var moved = await ResultAsync(bridge, "shell.lookup.verify", JsonSerializer.Serialize(new { dn = "OU=Ancien," + Root, objectGuid = guid }));
        Check.Equal("moved", moved.GetProperty("state").GetString(), "DN changé");
        Check.Equal(dn, moved.GetProperty("item").GetProperty("dn").GetString(), "nouveau DN repris");
        var missing = await ResultAsync(bridge, "shell.lookup.verify", JsonSerializer.Serialize(new { dn, objectGuid = Guid.Empty.ToString("D") }));
        Check.Equal("missing", missing.GetProperty("state").GetString(), "GUID inconnu");
        Check.Equal(JsonValueKind.Null, missing.GetProperty("item").ValueKind, "aucun objet rendu");
    }

    [Test]
    public static async Task The_refused_account_of_the_demonstration_is_denied()
    {
        var bridge = new SimulatedBridge();
        var coverage = await ResultAsync(bridge, "shell.demo.coverage");
        var refused = coverage.GetProperty("fixtures").EnumerateArray().Single(f => f.GetProperty("id").GetString() == "refused");
        Check.True(refused.GetProperty("present").GetBoolean(), "compte refusé présent");
        var detail = refused.GetProperty("detail").GetString()!;
        var name = detail[(detail.LastIndexOf('(') + 1)..detail.LastIndexOf(')')];
        var found = await ResultAsync(bridge, "shell.lookup", JsonSerializer.Serialize(new { text = name, kinds = UserKind }));
        var candidates = found.GetProperty("items").EnumerateArray().ToList();
        var target = candidates.FirstOrDefault(i => i.GetProperty("dn").GetString()!.StartsWith("CN=" + name + ",", StringComparison.OrdinalIgnoreCase));
        if (target.ValueKind == JsonValueKind.Undefined)
        {
            target = candidates.First();
        }
        var check = await ResultAsync(bridge, "shell.lookup.verify", JsonSerializer.Serialize(new { dn = target.GetProperty("dn").GetString(), objectGuid = target.GetProperty("objectGuid").GetString() }));
        Check.Equal("denied", check.GetProperty("state").GetString(), "accès refusé");
        Check.Equal(ShellErrors.LookupDeniedMessage, check.GetProperty("message").GetString(), "message du refus");
    }

    [Test]
    public static async Task Ou_picker_reads_the_guid_of_an_ou_then_rechecks_it()
    {
        var bridge = new SimulatedBridge();
        var children = await ResultAsync(bridge, "directory.ou.children", "{\"dn\":null}");
        var ou = children.GetProperty("children").EnumerateArray().First();
        var dn = ou.GetProperty("dn").GetString()!;
        var resolved = await ResultAsync(bridge, "shell.ou.resolve", JsonSerializer.Serialize(new { dn }));
        Check.Equal("ok", resolved.GetProperty("state").GetString(), "OU relue");
        var item = resolved.GetProperty("item");
        Check.Equal("ou", item.GetProperty("kind").GetString(), "nature");
        var guid = item.GetProperty("objectGuid").GetString()!;
        Check.True(Guid.TryParseExact(guid, "D", out _), "GUID au format 8-4-4-4-12");
        var check = await ResultAsync(bridge, "shell.lookup.verify", JsonSerializer.Serialize(new { dn, objectGuid = guid }));
        Check.Equal("ok", check.GetProperty("state").GetString(), "revérification par DN et GUID");
        var missing = await ResultAsync(bridge, "shell.ou.resolve", JsonSerializer.Serialize(new { dn = "OU=Inexistante," + Root }));
        Check.Equal("missing", missing.GetProperty("state").GetString(), "OU introuvable");
        Check.Equal(JsonValueKind.Null, missing.GetProperty("item").ValueKind, "aucun objet rendu");
        var user = await ResultAsync(bridge, "shell.lookup", "{\"text\":\"ma\",\"kinds\":[\"user\"]}");
        var userDn = user.GetProperty("items")[0].GetProperty("dn").GetString()!;
        var notOu = await ResultAsync(bridge, "shell.ou.resolve", JsonSerializer.Serialize(new { dn = userDn }));
        Check.Equal("missing", notOu.GetProperty("state").GetString(), "un compte n’est pas une OU");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.ou.resolve", "{\"dn\":\"pas un DN\"}"), "DN vérifié");
        var ous = await ResultAsync(bridge, "shell.lookup", "{\"text\":\"p\",\"kinds\":[\"ou\"]}");
        Check.True(ous.GetProperty("items").GetArrayLength() <= ShellOperations.LookupLimit, "recherche d’OU : 100 au plus");
    }

    [Test]
    public static async Task Faults_name_their_place_and_swallowed_errors_are_apart()
    {
        var bridge = new SimulatedBridge();
        var swallowed = await ResultAsync(bridge, "shell.fault", "{\"kind\":\"swallowed\",\"route\":\"shell\",\"count\":1,\"place\":\"board.copy\"}");
        Check.True(swallowed.GetProperty("traced").GetBoolean(), "tracée");
        Check.Equal(0, swallowed.GetProperty("total").GetInt32(), "pas une erreur de l’interface");
        Check.Equal(1, swallowed.GetProperty("swallowed").GetInt32(), "erreur ignorée comptée");
        var nested = await ResultAsync(bridge, "shell.fault", "{\"kind\":\"nested\",\"route\":\"shell\",\"count\":2,\"place\":null}");
        Check.Equal(2, nested.GetProperty("total").GetInt32(), "erreurs imbriquées comptées");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("(board.copy)", StringComparison.Ordinal)), "endroit du code au journal");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.fault", "{\"kind\":\"swallowed\",\"route\":\"shell\",\"count\":1,\"place\":\"mot de passe=x\"}"), "endroit : identifiant seulement");
        var metric = await ResultAsync(bridge, "shell.metric", "{\"kind\":\"sheet\",\"route\":\"shell\",\"count\":2,\"milliseconds\":4200}");
        Check.True(metric.GetProperty("traced").GetBoolean(), "temps bloqué tracé");
        Check.Equal(2, metric.GetProperty("panels").GetInt32(), "panneaux");
        Check.Equal(4200L, metric.GetProperty("totalMilliseconds").GetInt64(), "durée");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.metric", "{\"kind\":\"other\",\"route\":\"shell\",\"count\":1,\"milliseconds\":1}"), "nature fermée");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.metric", "{\"kind\":\"sheet\",\"route\":\"shell\",\"count\":1,\"milliseconds\":-1}"), "durée positive");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("panneau(x) modal(aux)", StringComparison.Ordinal)), "ligne du journal technique");
    }

    [Test]
    public static async Task Lookup_arguments_are_checked_before_any_read()
    {
        var bridge = new SimulatedBridge();
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.lookup", "{\"text\":\"a\",\"kinds\":[\"user\"]}"), "un caractère");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.lookup", "{\"text\":\"" + new string('a', 161) + "\",\"kinds\":[\"user\"]}"), "trop long");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.lookup", "{\"text\":\"ab\",\"kinds\":[\"group\"]}"), "nature inconnue");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.lookup.verify", "{\"dn\":\"pas un DN\",\"objectGuid\":\"00000000-0000-0000-0000-000000000000\"}"), "DN invalide");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.lookup.verify", "{\"dn\":\"" + Root + "\",\"objectGuid\":\"x\"}"), "GUID invalide");
        var ouOnly = await ResultAsync(bridge, "shell.lookup", "{\"text\":\"p\",\"kinds\":[\"ou\"]}");
        Check.True(ouOnly.GetProperty("items").EnumerateArray().All(i => i.GetProperty("kind").GetString() == "ou"), "un caractère suffit pour les OU");
    }

    [Test]
    public static async Task Demonstration_coverage_lists_thirteen_cases_with_their_counts()
    {
        var bridge = new SimulatedBridge();
        var coverage = await ResultAsync(bridge, "shell.demo.coverage");
        Check.True(coverage.GetProperty("available").GetBoolean(), "simulation");
        var fixtures = coverage.GetProperty("fixtures").EnumerateArray().ToList();
        Check.Equal(13, fixtures.Count, "cas");
        Check.Equal(13, coverage.GetProperty("total").GetInt32(), "total");
        Check.Equal(fixtures.Count(f => f.GetProperty("present").GetBoolean()), coverage.GetProperty("present").GetInt32(), "présents comptés");
        Check.True(fixtures.All(f => f.GetProperty("present").GetBoolean() == f.GetProperty("count").GetInt32() > 0), "présent si au moins un objet");
        foreach (var id in new[] { "ous", "locked", "disabled", "noDns", "refused" })
        {
            Check.True(fixtures.Single(f => f.GetProperty("id").GetString() == id).GetProperty("present").GetBoolean(), "cas présent : " + id);
        }
        // TRV-047: the last workstation just joined has no DNS name yet; every category of the demonstration is present.
        Check.Equal(1, fixtures.Single(f => f.GetProperty("id").GetString() == "noDns").GetProperty("count").GetInt32(), "un poste sans nom DNS");
    }

    [Test]
    public static async Task Faults_are_traced_once_a_minute_without_any_message()
    {
        var bridge = new SimulatedBridge();
        var first = await ResultAsync(bridge, "shell.fault", "{\"kind\":\"error\",\"route\":\"accueil\",\"count\":2}");
        Check.True(first.GetProperty("traced").GetBoolean(), "première ligne écrite");
        var second = await ResultAsync(bridge, "shell.fault", "{\"kind\":\"error\",\"route\":\"accueil\",\"count\":3}");
        Check.False(second.GetProperty("traced").GetBoolean(), "dans la minute : comptée seulement");
        Check.Equal(5, second.GetProperty("total").GetInt32(), "total de la session");
        bridge.Clock.Advance(TimeSpan.FromMinutes(1));
        var third = await ResultAsync(bridge, "shell.fault", "{\"kind\":\"error\",\"route\":\"accueil\",\"count\":1}");
        Check.True(third.GetProperty("traced").GetBoolean(), "une minute après : nouvelle ligne");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("3 autre(s) depuis la ligne précédente", StringComparison.Ordinal)), "occurrences silencieuses annoncées");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.fault", "{\"kind\":\"message\",\"route\":\"accueil\",\"count\":1}"), "nature fermée");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.fault", "{\"kind\":\"error\",\"route\":\"Mot de passe=x\",\"count\":1}"), "écran seulement, jamais un texte");
        Check.Equal("argument.invalid", await ErrorAsync(bridge, "shell.fault", "{\"kind\":\"error\",\"route\":\"accueil\",\"count\":0}"), "nombre borné");
    }

    [Test]
    public static async Task Automation_preview_validates_and_answers_from_local_data()
    {
        var bridge = new SimulatedBridge();
        var contract = await ResultAsync(bridge, "shell.automation.contract");
        Check.Equal(ShellAutomation.ContractName, contract.GetProperty("contract").GetString(), "contrat");

        var refused = await ResultAsync(bridge, "shell.automation.preview", "{\"command\":\"postes\"}");
        Check.False(refused.GetProperty("valid").GetBoolean(), "périmètre exigé");
        Check.Equal(4, refused.GetProperty("exitCode").GetInt32(), "code 4");

        var postes = await ResultAsync(bridge, "shell.automation.preview", "{\"command\":\"postes\",\"ou\":\"OU=Postes," + Root + "\",\"limit\":5}");
        Check.True(postes.GetProperty("valid").GetBoolean(), "commande valide");
        Check.Equal("json", postes.GetProperty("outputFormat").GetString(), "JSON");
        Check.True(postes.GetProperty("rows").GetInt32() is > 0 and <= 5, "aperçu borné par la limite");
        using var envelope = JsonDocument.Parse(postes.GetProperty("output").GetString()!);
        Check.Equal(ShellAutomation.ContractName, envelope.RootElement.GetProperty("Contract").GetString(), "enveloppe");
        Check.Equal(postes.GetProperty("truncated").GetBoolean(), envelope.RootElement.GetProperty("Truncated").GetBoolean(), "troncature publiée");

        var csv = await ResultAsync(bridge, "shell.automation.preview", "{\"command\":\"postes\",\"ou\":\"OU=Postes," + Root + "\",\"format\":\"Csv\",\"limit\":3}");
        Check.True(csv.GetProperty("output").GetString()!.StartsWith("\"Guid\";\"Nom\"", StringComparison.Ordinal), "CSV");

        var later = await ResultAsync(bridge, "shell.automation.preview", "{\"command\":\"observations\",\"computers\":[\"PC-01\"]}");
        Check.True(later.GetProperty("valid").GetBoolean(), "commande valide sans aperçu");
        Check.Equal(JsonValueKind.Null, later.GetProperty("output").ValueKind, "aucune réponse inventée");
    }

    [Test]
    public static void Shell_operations_never_write_to_the_directory()
    {
        var bridge = new SimulatedBridge();
        var shell = bridge.Registry.Names.Where(n => n.StartsWith("shell.", StringComparison.Ordinal))
            .Select(n => bridge.Registry.TryGet(n, out var d) ? d : throw new TestFailureException("opération absente : " + n)).ToList();
        Check.True(shell.Count >= 9, "opérations de la coque enregistrées");
        Check.True(shell.All(o => o.Class != OperationClass.Write), "aucune écriture d’annuaire");
        Check.True(shell.Where(o => o.Class == OperationClass.LocalWrite).Select(o => o.Name).Order(StringComparer.Ordinal).SequenceEqual(["shell.fault", "shell.interface.set", "shell.metric"]), "écritures locales connues");
    }
}
