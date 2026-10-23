using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core.Queries;

namespace Domenia.Tests;

/// <summary>
/// Operations of the query workshop through the real bridge over the fictitious directory (docs/ops/requetes.md): catalog,
/// validation, frozen previews, library with revisions, packs, collection plan, WMI on one workstation, drafts.
/// </summary>
internal static class RequetesOperationsTests
{
    private static string RecipeJson(string templateId) =>
        QueryRecipeJson.Write((QueryTemplates.Find(templateId) ?? throw new TestFailureException("modèle absent : " + templateId)).Recipe);

    private static string Args(object value) => JsonSerializer.Serialize(value, BridgeJson.Options);

    private static async Task<JsonElement> Ok(SimulatedBridge bridge, string op, string args = "{}") => SimulatedBridge.Json(await bridge.CallAsync(op, args));

    private static async Task<string> Refused(SimulatedBridge bridge, string op, string args)
    {
        var response = await bridge.CallAsync(op, args);
        Check.Equal("error", response.Kind, "refus attendu pour " + op);
        return response.Error!.Code;
    }

    /// <summary>The OU of the workstations (« Postes »): the first OU in name order (« Comptes de service ») holds no computer.</summary>
    internal static async Task<string> WorkstationsOuAsync(SimulatedBridge bridge)
    {
        var tree = await Ok(bridge, "directory.ou.children", "{\"dn\":null}");
        return tree.GetProperty("children").EnumerateArray().First(c => c.GetProperty("name").GetString() == "Postes").GetProperty("dn").GetString()!;
    }

    [Test]
    public static async Task The_catalog_describes_each_target_with_its_sources_and_limits()
    {
        var bridge = new SimulatedBridge();
        var computers = await Ok(bridge, "requetes.catalog", "{\"target\":\"computer\"}");
        Check.True(computers.GetProperty("fields").GetArrayLength() >= 140, "informations des postes");
        Check.True(computers.GetProperty("collections").GetArrayLength() > 0, "collections d’instances");
        Check.True(computers.GetProperty("ldapAttributes").GetArrayLength() > 50, "attributs LDAP");
        var users = await Ok(bridge, "requetes.catalog", "{\"target\":\"user\"}");
        Check.Equal("user", users.GetProperty("target").GetString(), "cible");
        Check.Equal(0, users.GetProperty("instanceFields").GetArrayLength(), "pas d’instances de sonde pour les comptes");
        Check.Equal("query.invalid", await Refused(bridge, "requetes.validate", "{\"recipe\":{\"Format\":\"Domenia.Query/3\",\"Name\":\"x\",\"Inconnu\":1}}"), "propriété inconnue refusée");
    }

    [Test]
    public static async Task Validation_returns_the_normalized_recipe_its_LDAP_filter_and_the_summary()
    {
        var bridge = new SimulatedBridge();
        var data = await Ok(bridge, "requetes.validate", "{\"recipe\":" + RecipeJson("template.active.lowdisk") + "}");
        Check.True(data.GetProperty("valid").GetBoolean(), "modèle valide");
        Check.Equal(64, data.GetProperty("fingerprint").GetString()!.Length, "empreinte SHA-256");
        Check.False(data.GetProperty("ldap").GetProperty("exact").GetBoolean(), "relevé de disque : traduction partielle");
        Check.Contains("Get-ADComputer", data.GetProperty("command").GetString(), "commande en lecture seule");
        var invalid = await Ok(bridge, "requetes.validate", "{\"recipe\":{\"Format\":\"Domenia.Query/3\",\"Name\":\"x\",\"Clauses\":[{\"Field\":\"inconnue\",\"Operator\":\"Equal\",\"Value\":1}]}}");
        Check.False(invalid.GetProperty("valid").GetBoolean(), "information inconnue");
        Check.True(invalid.GetProperty("errors").GetArrayLength() > 0, "erreur en français");
    }

    [Test]
    public static async Task A_preview_is_frozen_with_its_definition_and_counts_every_object_once()
    {
        var bridge = new SimulatedBridge();
        var preview = await Ok(bridge, "requetes.preview", "{\"recipe\":" + RecipeJson("template.active.lowdisk") + "}");
        var counts = preview.GetProperty("counts");
        var population = counts.GetProperty("population").GetInt32();
        Check.True(population > 0, "population non vide");
        Check.Equal(population, counts.GetProperty("matched").GetInt32() + counts.GetProperty("unknown").GetInt32() + counts.GetProperty("noMatch").GetInt32(), "trois verdicts sans recouvrement");
        var id = preview.GetProperty("id").GetString()!;
        var unknown = await Ok(bridge, "requetes.preview.page", Args(new { evaluationId = id, verdict = "unknown", offset = 0, limit = 50 }));
        Check.Equal(counts.GetProperty("unknown").GetInt32(), unknown.GetProperty("total").GetInt32(), "page des inconnus");
        foreach (var row in unknown.GetProperty("rows").EnumerateArray())
        {
            Check.Equal("unknown", row.GetProperty("verdict").GetString(), "verdict des lignes filtrées");
        }
        var first = preview.GetProperty("rows")[0].GetProperty("id").GetString()!;
        var detail = await Ok(bridge, "requetes.preview.object", Args(new { evaluationId = id, id = first }));
        Check.True(detail.GetProperty("explanation").GetArrayLength() >= 2, "une ligne par condition");
        Check.False(detail.GetProperty("stale").GetBoolean(), "aperçu à jour");
        var export = await Ok(bridge, "requetes.preview.export", Args(new { evaluationId = id, verdict = "all", format = "csv" }));
        Check.Equal(population, export.GetProperty("rows").GetInt32(), "export de toute la population");
        var token = export.GetProperty("token").GetString()!;
        var content = await Ok(bridge, "requetes.export.content", Args(new { token }));
        Check.Equal(population + 1, content.GetProperty("content").GetString()!.Split("\r\n", StringSplitOptions.RemoveEmptyEntries).Length, "en-tête et une ligne par objet");
        Check.Equal("query.exportUnavailable", await Refused(bridge, "requetes.export.save", Args(new { token })), "export refusé sans préférences persistantes");
        Check.Equal("query.evaluationUnknown", await Refused(bridge, "requetes.preview.page", Args(new { evaluationId = new string('0', 32) })), "aperçu inconnu");
    }

    [Test]
    public static async Task A_distribution_is_exact_and_a_value_becomes_a_segment()
    {
        var bridge = new SimulatedBridge();
        var preview = await Ok(bridge, "requetes.preview", "{\"recipe\":" + RecipeJson("template.user.by.department") + "}");
        var groups = preview.GetProperty("groups");
        var items = groups.GetProperty("items");
        Check.True(items.GetArrayLength() > 1, "plusieurs services");
        Check.Equal(groups.GetProperty("matched").GetInt64(), items.EnumerateArray().Sum(i => i.GetProperty("value").GetInt64()), "les parts couvrent tous les correspondants");
        var select = items[0].GetProperty("select");
        var segment = await Ok(bridge, "requetes.preview.segment", Args(new { evaluationId = preview.GetProperty("id").GetString(), label = select.GetProperty("label").GetString(), missing = select.GetProperty("missing").GetBoolean(), value = select.GetProperty("value") }));
        Check.True(segment.GetProperty("valid").GetBoolean(), "segment valide");
        Check.Equal(1, segment.GetProperty("recipe").GetProperty("refinements").GetArrayLength(), "segment ajouté en ET");
    }

    [Test]
    public static async Task The_library_keeps_revisions_refuses_a_stale_revision_and_restores_an_archive()
    {
        var bridge = new SimulatedBridge();
        var recipe = RecipeJson("template.stale");
        var saved = await Ok(bridge, "requetes.library.save", "{\"recipe\":" + recipe + ",\"category\":\"Revue\",\"expectedRevision\":0}");
        var id = saved.GetProperty("id").GetString()!;
        Check.False(id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal), "un modèle se copie en requête personnelle");
        Check.Equal(1, saved.GetProperty("revision").GetInt64(), "première révision");
        Check.True(saved.GetProperty("receipt").GetProperty("readBack").GetBoolean(), "reçu relu");
        var mine = saved.GetProperty("recipe").GetRawText();
        var second = await Ok(bridge, "requetes.library.save", "{\"recipe\":" + mine.Replace("\"name\":\"", "\"name\":\"Revue · ", StringComparison.Ordinal) + ",\"expectedRevision\":1}");
        Check.Equal(2, second.GetProperty("revision").GetInt64(), "deuxième révision");
        Check.Equal("query.revisionChanged", await Refused(bridge, "requetes.library.save", "{\"recipe\":" + mine + ",\"expectedRevision\":1}"), "révision dépassée refusée");
        var list = await Ok(bridge, "requetes.library.list", "{\"source\":\"personal\"}");
        Check.Equal(1, list.GetProperty("filtered").GetInt32(), "une requête personnelle");
        var archived = await Ok(bridge, "requetes.library.archive", Args(new { id, expectedRevision = 2 }));
        Check.Equal(3, archived.GetProperty("revision").GetInt64(), "archivage : nouvelle révision");
        Check.Equal(0, (await Ok(bridge, "requetes.library.list", "{\"source\":\"personal\"}")).GetProperty("filtered").GetInt32(), "plus dans « Mes requêtes »");
        var restored = await Ok(bridge, "requetes.library.restore", Args(new { id, expectedRevision = 3, restoreWidgets = true }));
        Check.Equal(4, restored.GetProperty("revision").GetInt64(), "restauration : nouvelle révision");
        var reverted = await Ok(bridge, "requetes.library.revert", Args(new { id, revision = 1, expectedRevision = 4 }));
        Check.Equal(5, reverted.GetProperty("revision").GetInt64(), "révision 1 remise comme révision 5");
        var detail = await Ok(bridge, "requetes.library.get", Args(new { id }));
        Check.True(detail.GetProperty("history").EnumerateArray().Any(h => h.GetProperty("revision").GetInt64() == 1), "révision ancienne conservée et consultable");
        var template = await Refused(bridge, "requetes.library.archive", Args(new { id = "template.stale", expectedRevision = 0 }));
        Check.True(template is "query.templateReadOnly" or "query.notFound", "un modèle livré ne s’archive pas : " + template);
    }

    [Test]
    public static async Task A_widget_is_linked_to_a_revision_and_the_impact_review_lists_it()
    {
        var bridge = new SimulatedBridge();
        var widget = await Ok(bridge, "requetes.widget.save", "{\"recipe\":" + RecipeJson("template.active.lowdisk") + ",\"board\":\"fleet\",\"visual\":\"kpi\",\"title\":\"Disques pleins\",\"expectedRevision\":0}");
        var id = widget.GetProperty("id").GetString()!;
        var list = await Ok(bridge, "requetes.widget.list");
        Check.Equal(1, list.GetArrayLength(), "un widget");
        Check.Equal(1, list[0].GetProperty("boundRevision").GetInt64(), "lié à la révision 1");
        var changed = widget.GetProperty("recipe").GetRawText().Replace("\"value\":10", "\"value\":15", StringComparison.Ordinal);
        var impact = await Ok(bridge, "requetes.library.impact", "{\"id\":\"" + id + "\",\"recipe\":" + changed + "}");
        Check.True(impact.GetProperty("hasConsumers").GetBoolean(), "le widget est un consommateur");
        Check.True(impact.GetProperty("changed").GetBoolean(), "définition modifiée");
        var removed = await Ok(bridge, "requetes.widget.remove", Args(new { id = list[0].GetProperty("id").GetString() }));
        Check.True(removed.GetProperty("removed").GetBoolean(), "widget retiré");
    }

    [Test]
    public static async Task A_pack_is_examined_before_any_write_applied_once_and_rolled_back()
    {
        var bridge = new SimulatedBridge();
        await Ok(bridge, "requetes.library.save", "{\"recipe\":" + RecipeJson("template.stale") + ",\"expectedRevision\":0}");
        var mine = (await Ok(bridge, "requetes.library.list", "{\"source\":\"personal\"}")).GetProperty("rows")[0].GetProperty("id").GetString()!;
        var pack = await Ok(bridge, "requetes.pack.export", Args(new { name = "Équipe", version = 1, ids = new[] { mine } }));
        Check.Equal(1, pack.GetProperty("count").GetInt32(), "une requête exportée");
        Check.Equal(2, pack.GetProperty("nextVersion").GetInt64(), "version suivante proposée");
        var other = new SimulatedBridge();
        var packText = (await Ok(bridge, "requetes.export.content", Args(new { token = pack.GetProperty("token").GetString() }))).GetProperty("content").GetString();
        var plan = await Ok(other, "requetes.pack.examine", Args(new { content = packText }));
        Check.True(plan.GetProperty("verified").GetBoolean(), "intégrité vérifiée");
        var item = plan.GetProperty("items")[0];
        Check.Equal("new", item.GetProperty("status").GetString(), "requête nouvelle dans l’autre bibliothèque");
        Check.Equal(0, (await Ok(other, "requetes.library.list", "{\"source\":\"personal\"}")).GetProperty("filtered").GetInt32(), "examen sans écriture");
        var examination = plan.GetProperty("examinationId").GetString()!;
        var applied = await Ok(other, "requetes.pack.apply", "{\"examinationId\":\"" + examination + "\",\"choices\":{\"" + item.GetProperty("id").GetString() + "\":\"create\"}}");
        Check.Equal(1, applied.GetProperty("created").GetInt32(), "une création");
        Check.Equal("query.importUnknown", await Refused(other, "requetes.pack.apply", "{\"examinationId\":\"" + examination + "\",\"choices\":{}}"), "un examen ne s’applique qu’une fois");
        var rollback = await Ok(other, "requetes.pack.rollback", Args(new { importId = applied.GetProperty("importId").GetString() }));
        Check.Equal(1, rollback.GetProperty("restored").GetInt32(), "création retirée");
        Check.Equal(0, (await Ok(other, "requetes.library.list", "{\"source\":\"personal\"}")).GetProperty("filtered").GetInt32(), "bibliothèque revenue avant l’import");
        Check.Equal("query.packInvalid", await Refused(other, "requetes.pack.examine", Args(new { content = "{\"Format\":\"Domenia.QueryPack/9\"}" })), "format de pack plus récent refusé");
    }

    [Test]
    public static async Task Collection_needs_a_plan_bounded_to_an_OU_and_runs_it_once()
    {
        var bridge = new SimulatedBridge();
        Check.Equal("query.collectRefused", await Refused(bridge, "requetes.collect.plan", "{\"recipe\":" + RecipeJson("template.all") + "}"), "annuaire seul : rien à collecter");
        var ou = await WorkstationsOuAsync(bridge);
        var scope = await Ok(bridge, "requetes.scope.set", Args(new { dn = ou, subtree = true }));
        Check.False(scope.GetProperty("scope").GetProperty("wholeDomain").GetBoolean(), "périmètre borné à une OU");
        var planned = await Ok(bridge, "requetes.collect.plan", "{\"recipe\":" + RecipeJson("template.active.lowdisk") + "}");
        var ticket = planned.GetProperty("ticket").GetString()!;
        var run = await Ok(bridge, "requetes.collect.run", Args(new { ticket }));
        Check.Contains("Relevé", run.GetProperty("text").GetString(), "compte rendu du relevé");
        Check.Equal("query.collectRefused", await Refused(bridge, "requetes.collect.run", Args(new { ticket })), "un plan ne se rejoue jamais");
    }

    [Test]
    public static async Task Advanced_WMI_reads_one_workstation_and_only_a_tested_SELECT_becomes_a_recipe()
    {
        var bridge = new SimulatedBridge();
        var found = await Ok(bridge, "requetes.objects.find", "{\"text\":\"PC-PAR\",\"target\":\"computer\"}");
        var computer = found[0].GetProperty("id").GetString()!;
        const string ns = "root\\\\cimv2";
        var classes = await Ok(bridge, "requetes.wmi.classes", "{\"computer\":\"" + computer + "\",\"namespace\":\"" + ns + "\",\"filter\":\"Win32_Logical*\"}");
        Check.True(classes.GetProperty("classes").GetArrayLength() > 0, "classes lues");
        var schema = await Ok(bridge, "requetes.wmi.schema", "{\"computer\":\"" + computer + "\",\"namespace\":\"" + ns + "\",\"className\":\"Win32_LogicalDisk\"}");
        Check.True(schema.GetProperty("properties").GetArrayLength() > 0, "propriétés lues");
        var built = await Ok(bridge, "requetes.wmi.build", "{\"computer\":\"" + computer + "\",\"namespace\":\"" + ns + "\",\"className\":\"Win32_LogicalDisk\",\"properties\":[\"DeviceID\",\"FreeSpace\"]}");
        var query = built.GetProperty("query").GetString()!;
        Check.Equal("query.wmiNotTested", await Refused(bridge, "requetes.wmi.recipe", Args(new { computer, @namespace = "root\\cimv2", query, limit = 100 })), "pas de recette avant un test");
        var run = await Ok(bridge, "requetes.wmi.run", Args(new { computer, @namespace = "root\\cimv2", query, limit = 100 }));
        Check.True(run.GetProperty("rows").GetArrayLength() > 0, "instances lues");
        var recipe = await Ok(bridge, "requetes.wmi.recipe", Args(new { computer, @namespace = "root\\cimv2", query, limit = 100 }));
        Check.NotNull(recipe.GetProperty("recipe").GetProperty("readDefinition").GetProperty("requestKey").GetString(), "recette liée au SELECT mémorisé");
        Check.Equal("query.wmiInvalid", await Refused(bridge, "requetes.wmi.run", Args(new { computer, @namespace = "root\\cimv2", query = "SELECT * FROM Win32_Process", limit = 10 })), "SELECT * refusé");
    }

    [Test]
    public static async Task Drafts_and_the_selection_for_Recherche_are_kept_locally()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(JsonValueKind.Null, (await Ok(bridge, "requetes.draft.get")).ValueKind, "aucun brouillon au départ");
        await Ok(bridge, "requetes.draft.keep", "{\"recipe\":" + RecipeJson("template.stale") + "}");
        var draft = await Ok(bridge, "requetes.draft.get");
        Check.Equal("template.stale", draft.GetProperty("recipe").GetProperty("id").GetString(), "brouillon repris");
        var preview = await Ok(bridge, "requetes.preview", "{\"recipe\":" + RecipeJson("template.stale") + "}");
        var applied = await Ok(bridge, "requetes.search.apply", Args(new { evaluationId = preview.GetProperty("id").GetString() }));
        Check.Equal(preview.GetProperty("counts").GetProperty("matched").GetInt32(), applied.GetProperty("count").GetInt32(), "seuls les correspondants sont figés");
        var selection = await Ok(bridge, "requetes.search.selection");
        Check.Equal(applied.GetProperty("count").GetInt32(), selection.GetProperty("count").GetInt32(), "sélection lue par Rechercher");
        Check.True((await Ok(bridge, "requetes.search.clear")).GetProperty("cleared").GetBoolean(), "sélection retirée");
        var script = await Ok(bridge, "requetes.script", "{\"recipe\":" + RecipeJson("template.stale") + ",\"format\":\"powershell\"}");
        Check.Contains("-LDAPFilter", script.GetProperty("content").GetString(), "script en lecture seule par filtre LDAP");
        Check.False(script.GetProperty("content").GetString()!.Contains("Set-AD", StringComparison.OrdinalIgnoreCase), "aucune cmdlet d’écriture");
    }
}
