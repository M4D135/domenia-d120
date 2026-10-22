using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Schema screen through the real bridge in simulation (docs/ops/schema.md § 2 to 9). Written now, run at the end.</summary>
internal static class SchemaTests
{
    private const string Nbsp = " ";

    private static async Task<SimulatedBridge> ReadAsync()
    {
        var bridge = new SimulatedBridge();
        SimulatedBridge.Json(await bridge.CallAsync("schema.read"));
        return bridge;
    }

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    [Test]
    public static async Task Status_before_any_read_says_nothing_is_read()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("schema.status"));
        Check.True(Names(json).SequenceEqual(["read", "server", "readAt", "classes", "attributes", "truncated", "durationMs", "text", "tone", "lastError", "simulated", "limits", "statistics"]),
            "propriétés du statut : " + string.Join(", ", Names(json)));
        Check.False(json.GetProperty("read").GetBoolean(), "rien n’est lu au chargement");
        Check.Equal(JsonValueKind.Null, json.GetProperty("server").ValueKind, "aucun contrôleur");
        Check.Equal("Schéma non lu dans cette session. La lecture est explicite et ne modifie rien.", json.GetProperty("text").GetString(), "texte de Domenia 1");
        Check.Equal("off", json.GetProperty("tone").GetString(), "ton neutre");
        Check.Equal(8000, json.GetProperty("limits").GetProperty("attributes").GetInt32(), "8 000 attributs au plus");
        Check.Equal(3000, json.GetProperty("limits").GetProperty("classes").GetInt32(), "3 000 classes au plus");
        Check.Equal(90, json.GetProperty("limits").GetProperty("seconds").GetInt32(), "90 secondes au plus");
        Check.Equal(JsonValueKind.Null, json.GetProperty("statistics").ValueKind, "aucune statistique");
        Check.True(json.GetProperty("simulated").GetBoolean(), "annuaire fictif");
    }

    [Test]
    public static async Task Catalog_operations_refuse_before_the_read()
    {
        var bridge = new SimulatedBridge();
        foreach (var (op, args) in new[] { ("schema.list", "{\"kind\":\"classes\"}"), ("schema.class", "{\"name\":\"user\"}"), ("schema.attribute", "{\"name\":\"cn\"}"), ("schema.filter.insert", "{\"filter\":null,\"attribute\":\"cn\"}") })
        {
            var response = await bridge.CallAsync(op, args);
            Check.Equal("error", response.Kind, op + " refusée");
            Check.Equal(SchemaErrors.NotRead, response.Error!.Code, op + " : schéma non lu");
        }
        // The analysis works without the schema: the index use stays unknown and says so.
        var analysis = SimulatedBridge.Json(await bridge.CallAsync("schema.filter.analyze", "{\"filter\":\"(sAMAccountName=jdupont)\"}"));
        Check.Equal("unknown", analysis.GetProperty("level").GetString(), "coût inconnu sans schéma");
        Check.False(analysis.GetProperty("schemaUsed").GetBoolean(), "schéma non utilisé");
        Check.Contains("Index non vérifiés", analysis.GetProperty("advice")[0].GetString(), "conseil de lire le schéma");
    }

    [Test]
    public static async Task Read_keeps_the_schema_with_its_controller_and_date_and_reports_its_stages()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("schema.read"));
        Check.True(json.GetProperty("read").GetBoolean(), "schéma lu");
        Check.Equal("DC01.example.local", json.GetProperty("server").GetString(), "contrôleur de la session");
        Check.Equal("2026-10-21T16:26:00Z", json.GetProperty("readAt").GetString(), "date de la lecture (horloge)");
        Check.Equal(47, json.GetProperty("classes").GetInt32(), "classes du schéma fictif");
        Check.Equal(244, json.GetProperty("attributes").GetInt32(), "attributs du schéma fictif");
        Check.False(json.GetProperty("truncated").GetBoolean(), "lecture complète");
        Check.Equal("Schéma lu le 21/10/2026 à 18:26 sur DC01.example.local" + Nbsp + ": 47 classes, 244 attributs.", json.GetProperty("text").GetString(), "statut en heure locale");
        Check.Equal("ok", json.GetProperty("tone").GetString(), "ton");
        var stats = json.GetProperty("statistics");
        Check.True(stats.GetProperty("indexed").GetInt32() > 30, "attributs indexés");
        Check.True(stats.GetProperty("confidential").GetInt32() >= 8, "attributs confidentiels (LAPS, BitLocker, TPM, Unix)");
        Check.True(stats.GetProperty("constructed").GetInt32() >= 12, "attributs calculés");
        Check.Equal("text", stats.GetProperty("syntaxes")[0].GetProperty("id").GetString(), "le texte est la famille la plus fréquente");
        string[] stages = [.. bridge.Events.Where(e => e.Operation == "schema.read:stage").Select(e => JsonSerializer.SerializeToElement(e.Data, BridgeJson.Options).GetProperty("stage").GetString()!)];
        Check.True(stages.SequenceEqual(["context", "attributes", "classes"]), "étapes : " + string.Join(", ", stages));
        Check.True(bridge.Context.Journal.Snapshot().Any(j => j.Label.StartsWith("Schéma lu sur DC01.example.local", StringComparison.Ordinal)), "journal des opérations");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("sAMAccountName", StringComparison.Ordinal)), "aucune donnée du schéma au journal technique");
        var status = SimulatedBridge.Json(await bridge.CallAsync("schema.status"));
        Check.True(status.GetProperty("read").GetBoolean(), "gardé pour la session");
    }

    [Test]
    public static async Task List_counts_every_match_and_returns_the_first_rows()
    {
        var bridge = await ReadAsync();
        var classes = SimulatedBridge.Json(await bridge.CallAsync("schema.list", "{\"kind\":\"classes\"}"));
        Check.Equal(47, classes.GetProperty("total").GetInt32(), "toutes les classes");
        Check.Equal(500, classes.GetProperty("limit").GetInt32(), "limite par défaut de Domenia 1");
        string[] names = [.. classes.GetProperty("rows").EnumerateArray().Select(r => r.GetProperty("name").GetString()!)];
        Check.True(names.SequenceEqual(names.Order(StringComparer.OrdinalIgnoreCase)), "ordre alphabétique");
        var user = classes.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("name").GetString() == "user");
        Check.Equal("Structurelle", user.GetProperty("nature").GetString(), "nature de user");
        Check.Equal("Hérite de organizationalPerson", user.GetProperty("detail").GetString(), "détail de user");
        var legacy = classes.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("name").GetString() == "exampleLegacyAsset");
        Check.Equal("Obsolète", legacy.GetProperty("nature").GetString(), "classe obsolète marquée");

        var limited = SimulatedBridge.Json(await bridge.CallAsync("schema.list", "{\"kind\":\"attributes\",\"text\":\"pwd\",\"limit\":2}"));
        Check.Equal(2, limited.GetProperty("shown").GetInt32(), "deux lignes");
        Check.True(limited.GetProperty("total").GetInt32() > 2, "total exact au-delà de la limite");
        Check.Contains("précisez le filtre", limited.GetProperty("summary").GetString(), "invite à préciser");

        // Name or description, case ignored (« personne » finds the descriptions in French).
        var person = SimulatedBridge.Json(await bridge.CallAsync("schema.list", "{\"kind\":\"classes\",\"text\":\"PERSON\"}"));
        string[] found = [.. person.GetProperty("rows").EnumerateArray().Select(r => r.GetProperty("name").GetString()!)];
        Check.True(found.Contains("organizationalPerson") && found.Contains("inetOrgPerson") && found.Contains("examplePersonExt"), "nom ou description : " + string.Join(", ", found));
        var attribute = SimulatedBridge.Json(await bridge.CallAsync("schema.list", "{\"kind\":\"attributes\",\"text\":\"sAMAccountName\"}"));
        var row = attribute.GetProperty("rows").EnumerateArray().First(r => r.GetProperty("name").GetString() == "sAMAccountName");
        Check.Equal("Une valeur · Indexé", row.GetProperty("detail").GetString(), "détail d’un attribut");
        Check.True(row.GetProperty("indexed").GetBoolean(), "indexé");
    }

    [Test]
    public static async Task Class_detail_walks_superclasses_and_auxiliary_classes()
    {
        var bridge = await ReadAsync();
        var json = SimulatedBridge.Json(await bridge.CallAsync("schema.class", "{\"name\":\"USER\"}"));
        Check.Equal("user", json.GetProperty("name").GetString(), "nom exact malgré la casse");
        string[] supers = [.. json.GetProperty("superclasses").EnumerateArray().Select(e => e.GetString()!)];
        Check.True(supers.SequenceEqual(["user", "organizationalPerson", "person", "top"]), "superclasses : " + string.Join(", ", supers));
        string[] auxiliaries = [.. json.GetProperty("lineage").EnumerateArray().Where(l => l.GetProperty("relation").GetString() == "auxiliary").Select(l => l.GetProperty("name").GetString()!)];
        Check.True(auxiliaries.SequenceEqual(["securityPrincipal", "mailRecipient", "posixAccount", "examplePersonExt"]), "auxiliaires : " + string.Join(", ", auxiliaries));
        Check.Equal(7, json.GetProperty("requiredCount").GetInt32(), "obligatoires : objectSid, sAMAccountName, cn et les quatre de top");
        Check.Equal(0, json.GetProperty("missing").GetArrayLength(), "aucun attribut absent");
        var rows = json.GetProperty("attributes").EnumerateArray().ToList();
        Check.True(rows.Take(7).All(r => r.GetProperty("required").GetBoolean()), "obligatoires d’abord");
        Check.True(rows.Skip(7).All(r => !r.GetProperty("required").GetBoolean()), "puis facultatifs");
        var sam = rows.Single(r => r.GetProperty("name").GetString() == "sAMAccountName");
        Check.Equal("securityPrincipal", sam.GetProperty("origin").GetString(), "défini par securityPrincipal");
        var cn = rows.Single(r => r.GetProperty("name").GetString() == "cn");
        Check.Equal("mailRecipient", cn.GetProperty("origin").GetString(), "première classe qui l’exige, dans l’ordre du parcours de Domenia 1");
        Check.Equal("(objectClass=user)", json.GetProperty("filter").GetString(), "filtre direct");
        Check.Equal("(&(objectCategory=person)(objectClass=user))", json.GetProperty("recommendedFilter").GetString(), "filtre recommandé");
        Check.Contains("un poste est aussi de classe user", json.GetProperty("filterAdvice").GetString(), "conseil objectClass ou objectCategory");
        string[] subclasses = [.. json.GetProperty("subclasses").EnumerateArray().Select(e => e.GetString()!)];
        Check.True(subclasses.SequenceEqual(["computer", "inetOrgPerson"]), "classes dérivées : " + string.Join(", ", subclasses));
        Check.Contains("user · classe structurelle · chaîne" + Nbsp + ": user → organizationalPerson", json.GetProperty("summary").GetString(), "résumé de Domenia 1");
    }

    [Test]
    public static async Task Attribute_detail_gives_flags_hint_links_and_users()
    {
        var bridge = await ReadAsync();
        var sam = SimulatedBridge.Json(await bridge.CallAsync("schema.attribute", "{\"name\":\"sAMAccountName\"}"));
        Check.Equal("Texte Unicode", sam.GetProperty("syntaxLabel").GetString(), "syntaxe en clair");
        Check.Equal("Indexé", sam.GetProperty("indexText").GetString(), "index");
        Check.Equal("(sAMAccountName=valeur*)", sam.GetProperty("hint").GetProperty("example").GetString(), "exemple de critère");
        Check.True(sam.GetProperty("insertable").GetBoolean(), "ajout au filtre permis");
        Check.True(sam.GetProperty("flags").EnumerateArray().Single(f => f.GetProperty("id").GetString() == "anr").GetProperty("on").GetBoolean(), "ANR");
        Check.True(sam.GetProperty("usedBy").EnumerateArray().Any(u => u.GetProperty("name").GetString() == "securityPrincipal" && u.GetProperty("required").GetBoolean()), "obligatoire dans securityPrincipal");
        Check.Equal("De 0 à 256 caractères", sam.GetProperty("rangeLabel").GetString(), "plage");

        var computed = SimulatedBridge.Json(await bridge.CallAsync("schema.attribute", "{\"name\":\"msDS-User-Account-Control-Computed\"}"));
        Check.True(computed.GetProperty("constructed").GetBoolean(), "calculé");
        Check.Equal("", computed.GetProperty("hint").GetProperty("example").GetString(), "aucun exemple pour un calculé");
        Check.False(computed.GetProperty("insertable").GetBoolean(), "ajout refusé");
        Check.Equal("Calculé, non filtrable", computed.GetProperty("indexText").GetString(), "index d’un calculé");

        var memberOf = SimulatedBridge.Json(await bridge.CallAsync("schema.attribute", "{\"name\":\"memberOf\"}"));
        Check.Equal(3, memberOf.GetProperty("linkId").GetInt32(), "lien retour");
        Check.Equal("member", memberOf.GetProperty("linkPartner").GetString(), "attribut associé");
        Check.Contains("Lien retour", memberOf.GetProperty("linkLabel").GetString(), "libellé du lien");

        var defunct = SimulatedBridge.Json(await bridge.CallAsync("schema.attribute", "{\"name\":\"exampleLegacyHrId\"}"));
        Check.True(defunct.GetProperty("defunct").GetBoolean(), "obsolète");
        Check.False(defunct.GetProperty("insertable").GetBoolean(), "obsolète : ajout refusé");
        Check.Contains("obsolète", defunct.GetProperty("hint").GetProperty("notes")[0].GetString(), "note obsolète en tête");

        var laps = SimulatedBridge.Json(await bridge.CallAsync("schema.attribute", "{\"name\":\"ms-Mcs-AdmPwd\"}"));
        Check.True(laps.GetProperty("flags").EnumerateArray().Single(f => f.GetProperty("id").GetString() == "confidential").GetProperty("on").GetBoolean(), "confidentiel");
    }

    [Test]
    public static async Task Insertion_builds_a_draft_and_analyzes_it()
    {
        var bridge = await ReadAsync();
        var first = SimulatedBridge.Json(await bridge.CallAsync("schema.filter.insert", "{\"filter\":\"\",\"attribute\":\"sAMAccountName\"}"));
        Check.Equal("(sAMAccountName=valeur*)", first.GetProperty("filter").GetString(), "filtre vide : l’exemple");
        Check.True(first.GetProperty("changed").GetBoolean(), "changé");
        var and = SimulatedBridge.Json(await bridge.CallAsync("schema.filter.insert", "{\"filter\":\"(&(objectCategory=person)(objectClass=user))\",\"attribute\":\"mail\"}"));
        Check.Equal("(&(objectCategory=person)(objectClass=user)(mail=valeur*))", and.GetProperty("filter").GetString(), "dans le ET existant");
        var wrap = SimulatedBridge.Json(await bridge.CallAsync("schema.filter.insert", "{\"filter\":\"cn=a*\",\"attribute\":\"pwdLastSet\"}"));
        Check.Equal("(&(cn=a*)(pwdLastSet>=133000000000000000))", wrap.GetProperty("filter").GetString(), "ET créé, filtre complété");
        Check.Equal("targeted", wrap.GetProperty("analysis").GetProperty("level").GetString(), "analyse du brouillon");
        var refused = SimulatedBridge.Json(await bridge.CallAsync("schema.filter.insert", "{\"filter\":\"(cn=a)\",\"attribute\":\"tokenGroups\"}"));
        Check.False(refused.GetProperty("changed").GetBoolean(), "calculé : rien d’ajouté");
        Check.Equal("(cn=a)", refused.GetProperty("filter").GetString(), "filtre inchangé");
    }

    [Test]
    public static async Task Arguments_are_checked_without_copying_the_input()
    {
        var bridge = await ReadAsync();
        var badKind = await bridge.CallAsync("schema.list", "{\"kind\":\"objets\"}");
        Check.Equal("arguments.invalid", badKind.Error!.Code, "type de liste");
        var badName = await bridge.CallAsync("schema.class", "{\"name\":\"user(cn=*)\"}");
        Check.Equal("arguments.invalid", badName.Error!.Code, "nom LDAP");
        Check.False(badName.Error.Message.Contains("cn=*", StringComparison.Ordinal), "la saisie n’est pas recopiée");
        var badLimit = await bridge.CallAsync("schema.list", "{\"kind\":\"classes\",\"limit\":0}");
        Check.Equal("arguments.invalid", badLimit.Error!.Code, "limite");
        var extra = await bridge.CallAsync("schema.status", "{\"x\":1}");
        Check.Equal("arguments.invalid", extra.Error!.Code, "aucun argument admis");
        var unknown = await bridge.CallAsync("schema.class", "{\"name\":\"licorne\"}");
        Check.Equal(SchemaErrors.UnknownClass, unknown.Error!.Code, "classe inconnue");
        var unknownAttribute = await bridge.CallAsync("schema.attribute", "{\"name\":\"licorne\"}");
        Check.Equal(SchemaErrors.UnknownAttribute, unknownAttribute.Error!.Code, "attribut inconnu");
    }

    [Test]
    public static async Task Read_is_refused_in_directory_mode_while_Domenia_Ad_is_not_wired()
    {
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), ScreenReaders.None);
        var registry = OperationModules.CreateRegistry(context, [new SchemaOperations()]);
        Check.True(registry.TryGet("schema.read", out var read), "lecture déclarée");
        Check.Equal(OperationClass.NetworkRead, read!.Class, "lecture réseau");
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Directory));
        await dispatcher.HandleAsync("""{"id":"s1","op":"schema.read","args":{}}""", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent.Single().Error!.Code, "source indisponible");
    }

    [Test]
    public static void Catalog_rules_follow_Domenia_1()
    {
        Check.Equal("Grand entier (compteur ou date FILETIME)", SchemaRules.SyntaxLabel("2.5.5.16"), "libellé de syntaxe");
        Check.Equal("Syntaxe non reconnue", SchemaRules.SyntaxLabel("1.2.3"), "syntaxe inconnue");
        Check.Equal(SchemaSyntaxKind.Dn, SchemaRules.SyntaxKind("2.5.5.14"), "DN chaîne");
        var flags = SchemaRules.SearchFlags(904);
        Check.True(flags.Confidential && flags.PreserveOnDelete && flags.NeverAudit && flags.RodcFiltered && !flags.Indexed, "searchFlags 904");
        Check.True(SchemaRules.SystemFlags(20).Constructed && SchemaRules.SystemFlags(20).BaseSchema, "systemFlags 20");
        Check.Equal(SchemaClassCategory.Structural, SchemaRules.ClassCategory(null), "catégorie absente : structurelle");
        Check.Equal("Classe 88", SchemaRules.ClassCategoryLabel(SchemaRules.ClassCategory(0)), "classe 88");
        Check.Equal("a b", SchemaRules.FlatText("a\r\n\tb"), "texte aplati");
        Check.Equal(500, SchemaRules.FlatText(new string('x', 900)).Length, "500 caractères au plus");
        Check.False(SchemaRules.IsValidName("bad name"), "espace refusé");
        Check.True(SchemaRules.IsValidName("ms-Mcs-AdmPwd"), "tirets admis");
    }

    [Test]
    public static void Class_walk_is_bounded_on_a_schema_loop()
    {
        var read = new SchemaReadResult(
            [new SchemaAttributeDefinition("cn", null, null, "2.5.5.12", 64, true, 1, 0, true, null, null, null, false)],
            [
                new SchemaClassDefinition("a", null, null, "b", [], ["cn"], [], 1, false),
                new SchemaClassDefinition("b", null, null, "a", ["ghost"], [], ["absent"], 1, false),
            ],
            "DC1", TestClock.Reference, false, 10, "DC=test,DC=local", "CN=Schema,CN=Configuration,DC=test,DC=local");
        var catalog = SchemaRules.BuildCatalog(read);
        var detail = SchemaRules.ClassDetail(catalog, "a");
        Check.True(detail.Chain.SequenceEqual(["a", "b"]), "boucle parcourue une fois");
        Check.True(detail.Superclasses.SequenceEqual(["a", "b"]), "superclasses bornées");
        Check.True(detail.Missing.SequenceEqual(["absent"]), "attribut absent signalé");
        Check.True(detail.Lineage.Any(l => l.Name == "ghost" && !l.Known), "auxiliaire absente signalée");
    }
}
