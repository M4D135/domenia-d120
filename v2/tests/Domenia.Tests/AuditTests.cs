using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// « Audit AD » (docs/ops/audit.md): contract of the audit.* operations through the real bridge in simulation, and the pure
/// rules ported from Domenia 1 (Domenia-AdAudit.Model.ps1). Written with the code, run at the very end (decision of 21/10).
/// </summary>
internal static class AuditTests
{
    private const string Root = "DC=example,DC=local";
    private const string Julien = "CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,DC=example,DC=local";
    private const string AdminJulien = "CN=adm-j.martin,OU=Comptes à privilèges,DC=example,DC=local";
    private const string ServiceWeb = "CN=svc-web,OU=Comptes de service,DC=example,DC=local";
    private const string Postes = "OU=Postes,DC=example,DC=local";

    private static readonly (string Name, OperationClass Class, bool Served)[] Operations =
    [
        ("audit.target", OperationClass.LocalRead, false),
        ("audit.objects.search", OperationClass.LocalRead, false),
        ("audit.suggestions", OperationClass.LocalRead, false),
        ("audit.catalogue", OperationClass.Local, false),
        ("audit.overview", OperationClass.NetworkRead, true),
        ("audit.finding.objects", OperationClass.Local, false),
        ("audit.localTotals", OperationClass.LocalRead, false),
        ("audit.dc.list", OperationClass.NetworkRead, true),
        ("audit.dc.probe", OperationClass.NetworkRead, true),
        ("audit.dc.services", OperationClass.NetworkRead, true),
        ("audit.dc.compare", OperationClass.NetworkRead, true),
        ("audit.object.policy", OperationClass.NetworkRead, true),
        ("audit.object.groups", OperationClass.NetworkRead, true),
        ("audit.object.groupPath", OperationClass.Local, false),
        ("audit.object.membership", OperationClass.NetworkRead, true),
        ("audit.object.acl", OperationClass.NetworkRead, true),
        ("audit.object.estimate", OperationClass.Local, false),
        ("audit.object.tokenGroups", OperationClass.NetworkRead, true),
        ("audit.object.gpoLinks", OperationClass.NetworkRead, true),
        ("audit.object.gpoApplied", OperationClass.NetworkRead, true),
        ("audit.object.machineIdentity", OperationClass.NetworkRead, true),
        ("audit.object.relations", OperationClass.LocalRead, false),
        ("audit.object.history", OperationClass.LocalRead, false),
        ("audit.identities.scan", OperationClass.NetworkRead, true),
    ];

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static async Task<string> ErrorAsync(SimulatedBridge bridge, string op, string args)
    {
        var response = await bridge.CallAsync(op, args);
        Check.Equal("error", response.Kind, "refus attendu pour " + op);
        return response.Error!.Code;
    }

    // ================================================================ registry

    [Test]
    public static void Every_audit_operation_is_declared_read_only_with_its_class()
    {
        var bridge = new SimulatedBridge();
        var audit = bridge.Registry.Names.Where(n => n.StartsWith("audit.", StringComparison.Ordinal)).Order(StringComparer.Ordinal).ToArray();
        Check.Equal(Operations.Length, audit.Length, "opérations audit.* : " + string.Join(", ", audit));
        foreach (var (name, operationClass, served) in Operations)
        {
            Check.True(bridge.Registry.TryGet(name, out var definition), "opération présente : " + name);
            Check.Equal(operationClass, definition!.Class, "classe de " + name);
            Check.Equal(served, definition.ServedInSimulation, "servie en simulation : " + name);
            Check.True(definition.Class != OperationClass.Write && definition.Class != OperationClass.LocalWrite, "aucune écriture : " + name);
        }
    }

    [Test]
    public static async Task Network_reads_are_refused_in_directory_mode_until_the_directory_is_wired()
    {
        // Directory mode without Domenia.Ad: no reader, every read answers source.unavailable, nothing is attempted.
        using var context = new EngineContext(
            ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local")),
            new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun"),
            new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        var registry = OperationModules.CreateRegistry(context, [new AuditOperations()]);
        Check.True(registry.TryGet("audit.overview", out var overview), "analyse déclarée");
        using var none = JsonDocument.Parse("{}");
        var thrown = await Check.ThrowsAsync<DomeniaOperationException>(() => overview!.Handler(none.RootElement, new BridgeContext(_ => { }, "test", "audit.overview"), CancellationToken.None), "sans lecteur");
        Check.Equal(DomeniaErrors.SourceUnavailable, thrown.Code, "source indisponible");
    }

    // ================================================================ target and search

    [Test]
    public static async Task The_target_says_which_reads_apply_and_why_not()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.target", Args(new { dn = Julien })));
        Check.True(Names(json).SequenceEqual(["dn", "kind", "kindLabel", "name", "samAccountName", "objectGuid", "sid", "dnsHostName", "path", "description", "availability"]), "propriétés de la cible");
        Check.Equal("user", json.GetProperty("kind").GetString(), "utilisateur");
        Check.Equal("Julien Martin", json.GetProperty("name").GetString(), "nom affiché");
        Check.Equal("example.local › Utilisateurs › Paris › Informatique › Julien Martin".Replace(" › ", FrenchText.PathSeparator, StringComparison.Ordinal), json.GetProperty("path").GetString(), "chemin lisible");
        var availability = json.GetProperty("availability");
        Check.True(availability.GetProperty("policy").GetProperty("allowed").GetBoolean(), "stratégie de mot de passe");
        Check.False(availability.GetProperty("gpoApplied").GetProperty("allowed").GetBoolean(), "RSoP refusé pour un utilisateur");
        Check.Contains("ordinateur", availability.GetProperty("gpoApplied").GetProperty("reason").GetString(), "motif dit");
        Check.Equal(AuditErrors.TargetUnknown, await ErrorAsync(bridge, "audit.target", Args(new { dn = "CN=Personne,OU=Paris,DC=example,DC=local" })), "objet inconnu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.target", Args(new { dn = "pas un DN" })), "DN invalide");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.target", Args(new { dn = Julien, extra = 1 })), "propriété en trop");
    }

    [Test]
    public static async Task A_read_that_does_not_apply_is_refused_with_its_reason()
    {
        var bridge = new SimulatedBridge();
        var response = await bridge.CallAsync("audit.object.gpoApplied", Args(new { dn = Julien }));
        Check.Equal(AuditErrors.NotApplicable, response.Error!.Code, "lecture non applicable");
        Check.Contains("ordinateur", response.Error.Message, "motif");
        Check.Equal(AuditErrors.NotApplicable, await ErrorAsync(bridge, "audit.object.policy", Args(new { dn = Postes })), "stratégie de mot de passe d’une OU");
    }

    [Test]
    public static async Task Search_finds_accounts_without_accents_nor_case_and_stays_bounded()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.objects.search", Args(new { text = "SVC-WEB" })));
        Check.True(json.GetArrayLength() >= 1, "au moins un résultat");
        Check.Equal(ServiceWeb, json[0].GetProperty("dn").GetString(), "correspondance exacte en tête");
        var many = SimulatedBridge.Json(await bridge.CallAsync("audit.objects.search", Args(new { text = "pc-par" })));
        Check.Equal(AuditService.SearchLimit, many.GetArrayLength(), "borne de 20 résultats");
        Check.Equal(0, SimulatedBridge.Json(await bridge.CallAsync("audit.objects.search", Args(new { text = "   " }))).GetArrayLength(), "texte vide : rien");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.objects.search", Args(new { text = new string('a', 101) })), "texte trop long");
    }

    [Test]
    public static async Task Suggestions_are_checked_in_the_local_index_and_find_domain_admins_by_its_rid()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.suggestions"));
        var items = json.EnumerateArray().ToList();
        Check.True(items.Count >= 3, "compte, racine et Admins du domaine au moins");
        Check.True(Names(items[0]).SequenceEqual(["id", "label", "detail", "target"]), "propriétés d’une suggestion");
        Check.Equal("account", items[0].GetProperty("id").GetString(), "compte de la session d’abord");
        Check.Equal(SimulationProfile.SessionLogin, items[0].GetProperty("target").GetProperty("samAccountName").GetString(), "compte de la session");
        var admins = items.Single(i => i.GetProperty("id").GetString() == "domainAdmins");
        var directory = bridge.Source.CurrentDirectory;
        var expected = directory.Groups.Single(g => g.Sid.EndsWith("-512", StringComparison.Ordinal));
        Check.Equal(expected.DistinguishedName, admins.GetProperty("target").GetProperty("dn").GetString(), "groupe trouvé par son RID, jamais par un nom écrit en dur");
        Check.Equal("group", admins.GetProperty("target").GetProperty("kind").GetString(), "un groupe");
        Check.True(items.Select(i => i.GetProperty("target").GetProperty("dn").GetString()).Distinct(StringComparer.OrdinalIgnoreCase).Count() == items.Count, "aucun doublon");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.suggestions", Args(new { text = "x" })), "aucun argument");
    }

    // ================================================================ domain overview

    [Test]
    public static async Task The_overview_grades_findings_by_severity_and_scores_the_domain()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.overview"));
        Check.True(Names(json).SequenceEqual(["readAt", "controller", "durationMs", "score", "counts", "findings", "sections", "refused", "anomalies", "summary", "previous"]), "propriétés de la vue du domaine");
        Check.Equal(JsonValueKind.Null, json.GetProperty("previous").ValueKind, "aucune vue précédente à la première analyse");
        var findings = json.GetProperty("findings").EnumerateArray().ToList();
        Check.Equal(AuditFindings.Catalogue.Length, findings.Count, "un constat par contrôle du catalogue");
        Check.True(Names(findings[0]).SequenceEqual(["id", "severity", "severityLabel", "tone", "category", "title", "summary", "count", "countLabel", "passed", "state", "source", "limit", "advice", "objectKind", "explorable", "truncated", "delta", "examples"]), "propriétés d’un constat");
        var dcsync = findings.Single(f => f.GetProperty("id").GetString() == "dcsyncRights");
        Check.Equal("critical", dcsync.GetProperty("severity").GetString(), "DCSync hors administrateurs : critique");
        Check.Equal(1, dcsync.GetProperty("count").GetInt32(), "svc-annuaire");
        Check.Equal("critical", findings[0].GetProperty("severity").GetString(), "les constats critiques d’abord");
        var never = findings.Single(f => f.GetProperty("id").GetString() == "passwordNeverExpires");
        Check.Equal(16, never.GetProperty("count").GetInt32(), "16 mots de passe sans expiration (SIMULATION.md § 4.4)");
        Check.Equal("medium", never.GetProperty("severity").GetString(), "gravité moyenne");
        var locked = findings.Single(f => f.GetProperty("id").GetString() == "lockedAccounts");
        Check.Equal(7, locked.GetProperty("count").GetInt32(), "7 comptes verrouillés");
        var policy = findings.Single(f => f.GetProperty("id").GetString() == "domainPasswordPolicy");
        Check.True(policy.GetProperty("passed").GetBoolean(), "stratégie du domaine sans écart");
        Check.Equal("ok", policy.GetProperty("tone").GetString(), "ton des contrôles sans écart");
        var krbtgt = findings.Single(f => f.GetProperty("id").GetString() == "krbtgtPassword");
        Check.True(krbtgt.GetProperty("count").GetInt32() > 365, "âge du mot de passe krbtgt en jours");
        var score = json.GetProperty("score").GetProperty("value").GetInt32();
        Check.True(score is >= 0 and <= 100, "score borné");
        var counts = json.GetProperty("counts");
        Check.True(counts.GetProperty("critical").GetInt32() >= 1, "au moins un constat critique");
        Check.Equal(11, json.GetProperty("sections").GetArrayLength(), "onze sections de la vue du domaine");

        var again = SimulatedBridge.Json(await bridge.CallAsync("audit.overview"));
        var previous = again.GetProperty("previous");
        Check.Equal(score, previous.GetProperty("score").GetInt32(), "vue précédente gardée pour la session");
        Check.Equal(0, previous.GetProperty("delta").GetInt32(), "annuaire inchangé : score inchangé");
        Check.Equal(0, again.GetProperty("findings")[0].GetProperty("delta").GetInt32(), "écart par constat");
    }

    [Test]
    public static async Task The_catalogue_lists_every_control_without_reading_anything()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.catalogue"));
        Check.Equal(AuditFindings.Catalogue.Length, json.GetArrayLength(), "un contrôle par définition");
        Check.True(Names(json[0]).SequenceEqual(["id", "category", "title", "severity", "severityLabel", "tone", "source", "advice"]), "propriétés d’un contrôle");
        Check.Equal("critical", json[0].GetProperty("severity").GetString(), "DCSync : critique quand il est trouvé");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture");
    }

    [Test]
    public static async Task Findings_are_explored_without_a_new_read_and_only_after_an_analysis()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(AuditErrors.OverviewNotRead, await ErrorAsync(bridge, "audit.finding.objects", Args(new { id = "passwordNeverExpires" })), "avant l’analyse");
        _ = await bridge.CallAsync("audit.overview");
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.finding.objects", Args(new { id = "passwordNeverExpires" })));
        Check.Equal(16, json.GetProperty("total").GetInt32(), "total du constat");
        Check.Equal(16, json.GetProperty("rows").GetArrayLength(), "objets lus par l’analyse");
        Check.False(json.GetProperty("truncated").GetBoolean(), "liste complète");
        var row = json.GetProperty("rows")[0];
        Check.True(Names(row).SequenceEqual(["dn", "name", "kind", "kindLabel", "samAccountName", "enabled", "lastLogon", "passwordLastSet", "detail", "container"]), "propriétés d’un objet");
        Check.Equal(AuditErrors.FindingUnknown, await ErrorAsync(bridge, "audit.finding.objects", Args(new { id = "inconnu" })), "constat inconnu");
    }

    [Test]
    public static async Task Local_totals_come_from_the_copy_with_its_date()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.localTotals"));
        Check.Equal("read", json.GetProperty("state").GetString(), "copie lue");
        Check.True(json.GetProperty("simulated").GetBoolean(), "copie fictive dite");
        Check.Equal(1258L + 454 + 75 + 39 + 3, json.GetProperty("total").GetInt64(), "objets de l’annuaire fictif et conteneurs");
        Check.Contains("aucune base locale n’est ouverte", json.GetProperty("summary").GetString(), "la simulation ne lit aucune base");
    }

    // ================================================================ controllers

    [Test]
    public static async Task Controllers_are_listed_then_diagnosed_without_calling_a_controller_down()
    {
        var bridge = new SimulatedBridge();
        var list = SimulatedBridge.Json(await bridge.CallAsync("audit.dc.list"));
        Check.Equal(2, list.GetProperty("controllers").GetArrayLength(), "DC01 et DC02");
        Check.Equal("DC01.example.local", list.GetProperty("pdc").GetString(), "émulateur PDC");
        var probe = SimulatedBridge.Json(await bridge.CallAsync("audit.dc.probe", Args(new { controllers = new[] { "DC01.example.local", "dc02" } })));
        var rows = probe.GetProperty("rows").EnumerateArray().ToDictionary(r => r.GetProperty("controller").GetString()!, StringComparer.Ordinal);
        Check.Equal("clear", rows["DC01.example.local"].GetProperty("verdict").GetString(), "DC01 sans écart");
        Check.Equal("check", rows["DC02.example.local"].GetProperty("verdict").GetString(), "DC02 à vérifier (réplication) ; le nom court revient comme la liste l’écrit");
        Check.Equal(10, probe.GetProperty("neighbors").GetArrayLength(), "cinq partitions par contrôleur");
    }

    [Test]
    public static async Task Only_the_controllers_of_the_domain_list_are_ever_contacted()
    {
        // A diagnosis, a services read (administrative rights) or a comparison never reaches a host outside the list of the
        // controllers of the domain (read now when the session has none): audit.controllersInvalid, nothing is read.
        var bridge = new SimulatedBridge();
        var outside = await bridge.CallAsync("audit.dc.probe", Args(new { controllers = new[] { "DC01.example.local", "DC99.example.local" } }));
        Check.Equal(AuditErrors.ControllersInvalid, outside.Error!.Code, "hôte hors de la liste");
        Check.Contains("DC99.example.local", outside.Error.Message, "hôte nommé");
        Check.Equal(AuditErrors.ControllersInvalid, await ErrorAsync(bridge, "audit.dc.services", Args(new { controllers = new[] { "srv-fichiers.example.local" } })), "services : jamais un hôte arbitraire");
        Check.Equal(AuditErrors.ControllersInvalid, await ErrorAsync(bridge, "audit.dc.compare", Args(new { dn = Julien, controllers = new[] { "pc-par-0001" } })), "comparaison : jamais un poste");
        var eleven = await bridge.CallAsync("audit.dc.probe", Args(new { controllers = Enumerable.Range(1, 11).Select(i => "DC" + i).ToArray() }));
        Check.Equal(AuditErrors.ControllersInvalid, eleven.Error!.Code, "plus de 10 : refus de l’audit (ops/audit.md § 3)");
        Check.Contains("Diagnostic borné à 10 contrôleurs", eleven.Error.Message, "message du contrat");
        Check.Equal(AuditErrors.ControllersInvalid, await ErrorAsync(bridge, "audit.dc.probe", Args(new { controllers = Array.Empty<string>() })), "aucun contrôleur choisi");
        Check.Equal(AuditErrors.ControllersInvalid, await ErrorAsync(bridge, "audit.dc.probe", Args(new { controllers = new[] { "dc01;rm" } })), "nom invalide");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.dc.probe", Args(new { controllers = "DC01" })), "pas un tableau");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.dc.probe", Args(new { controllers = new object[] { 1 } })), "élément qui n’est pas un texte");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.dc.probe", Args(new { controllers = Enumerable.Range(1, 101).Select(i => "DC" + i).ToArray() })), "tableau démesuré");
    }

    [Test]
    public static async Task An_object_is_compared_between_controllers_without_comparing_usns()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.dc.compare", Args(new { dn = Julien, controllers = new[] { "DC01.example.local", "DC02.example.local" } })));
        Check.True(Names(json).SequenceEqual(["dn", "name", "controllers", "rows", "differences", "comparable", "notRead", "note", "summary", "readAt"]), "propriétés de la comparaison");
        Check.Equal(Julien, json.GetProperty("dn").GetString(), "objet comparé");
        Check.Equal(2, json.GetProperty("controllers").GetArrayLength(), "deux contrôleurs");
        var row = json.GetProperty("rows")[0];
        Check.True(Names(row).SequenceEqual(["attribute", "identical", "values"]), "propriétés d’une ligne");
        Check.True(Names(row.GetProperty("values")[0]).SequenceEqual(["controller", "value", "version", "changedAt", "origin"]), "propriétés d’une valeur");
        Check.False(json.GetProperty("rows").EnumerateArray().Any(r => r.GetProperty("attribute").GetString()!.Contains("USN", StringComparison.OrdinalIgnoreCase)), "les USN, locaux à chaque contrôleur, ne sont jamais comparés");
        Check.Equal(AuditErrors.TargetUnknown, await ErrorAsync(bridge, "audit.dc.compare", Args(new { dn = "CN=Personne,DC=example,DC=local", controllers = new[] { "DC01.example.local" } })), "objet inconnu");
    }

    [Test]
    public static async Task Services_compare_with_the_expected_state_and_a_stopped_service_is_to_check()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.dc.services", Args(new { controllers = new[] { "DC02.example.local" } })));
        var adws = json.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("service").GetString() == "ADWS");
        Check.Equal("Arrêté", adws.GetProperty("state").GetString(), "état en français");
        Check.Equal("Non démarré : à vérifier", adws.GetProperty("finding").GetString(), "constat");
        var frs = json.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("service").GetString() == "NtFrs");
        Check.Equal("Non utilisé : DFSR réplique SYSVOL", frs.GetProperty("finding").GetString(), "NtFrs absent, DFSR en cours");
    }

    // ================================================================ object reads

    [Test]
    public static async Task The_applicable_password_policy_follows_msDS_ResultantPSO()
    {
        var bridge = new SimulatedBridge();
        var admin = SimulatedBridge.Json(await bridge.CallAsync("audit.object.policy", Args(new { dn = AdminJulien })));
        Check.Equal("applies", admin.GetProperty("state").GetString(), "stratégie fine applicable");
        Check.Contains("PSO-Comptes-a-privileges", admin.GetProperty("summary").GetString(), "nommée");
        var julien = SimulatedBridge.Json(await bridge.CallAsync("audit.object.policy", Args(new { dn = Julien })));
        Check.Equal("applies", julien.GetProperty("state").GetString(), "GG-Support-N2 est imbriqué dans GG-Admins-Postes");
        var service = SimulatedBridge.Json(await bridge.CallAsync("audit.object.policy", Args(new { dn = ServiceWeb })));
        Check.Contains("PSO-Comptes-de-service", service.GetProperty("summary").GetString(), "comptes de service");
        Check.True(service.GetProperty("facts").EnumerateArray().Any(f => f.GetProperty("value").GetString()!.StartsWith("N’expire jamais", StringComparison.Ordinal)), "option du compte");
    }

    [Test]
    public static async Task Nested_groups_give_depth_path_primary_group_and_why_a_member()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(AuditErrors.GroupsNotRead, await ErrorAsync(bridge, "audit.object.groupPath", Args(new { dn = Julien, groupDn = "CN=GG-Admins-Postes,OU=Sécurité,OU=Groupes,DC=example,DC=local" })), "avant la lecture");
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.object.groups", Args(new { dn = Julien })));
        var rows = json.GetProperty("rows").EnumerateArray().ToList();
        var support = rows.Single(r => r.GetProperty("name").GetString() == "GG-Support-N2");
        Check.Equal(1, support.GetProperty("depth").GetInt32(), "appartenance directe");
        var admins = rows.Single(r => r.GetProperty("name").GetString() == "GG-Admins-Postes");
        Check.Equal(2, admins.GetProperty("depth").GetInt32(), "par imbrication");
        Check.Equal("Par GG-Support-N2", admins.GetProperty("via").GetString(), "arrive par");
        Check.Equal("Utilisateurs du domaine", json.GetProperty("primaryGroup").GetProperty("name").GetString(), "groupe principal (513)");
        Check.Equal(0, json.GetProperty("cycles").GetArrayLength(), "aucun cycle dans l’annuaire fictif");
        Check.True(json.GetProperty("graph").GetProperty("nodes").GetArrayLength() > rows.Count, "graphe : l’objet, ses groupes et le groupe principal");
        var why = SimulatedBridge.Json(await bridge.CallAsync("audit.object.groupPath", Args(new { dn = Julien, groupDn = admins.GetProperty("dn").GetString() })));
        Check.True(why.GetProperty("member").GetBoolean(), "membre");
        Check.True(why.GetProperty("path").EnumerateArray().Select(p => p.GetString()).SequenceEqual(["Julien Martin", "GG-Support-N2", "GG-Admins-Postes"]), "plus court chemin");
        Check.False(why.GetProperty("confirmed").GetBoolean(), "sans relecture");
        var confirmed = SimulatedBridge.Json(await bridge.CallAsync("audit.object.membership", Args(new { dn = Julien, groupDn = admins.GetProperty("dn").GetString() })));
        Check.True(confirmed.GetProperty("confirmed").GetBoolean(), "question posée au contrôleur");
        Check.Contains("confirmé par le contrôleur", confirmed.GetProperty("text").GetString(), "réponse du contrôleur");
    }

    [Test]
    public static async Task Delegations_show_the_replication_rights_and_the_estimate_reuses_the_entries_read()
    {
        var bridge = new SimulatedBridge();
        var root = SimulatedBridge.Json(await bridge.CallAsync("audit.object.acl", Args(new { dn = Root })));
        var rows = root.GetProperty("rows").EnumerateArray().ToList();
        Check.True(rows.Any(r => r.GetProperty("trustee").GetString() == "svc-annuaire" && r.GetProperty("target").GetString() == "Répliquer toutes les modifications de l’annuaire"), "DCSync de svc-annuaire");
        Check.Contains("Une entrée observée n’est pas un droit effectif", root.GetProperty("limit").GetString(), "limite affichée");

        Check.Equal(AuditErrors.AclNotRead, await ErrorAsync(bridge, "audit.object.estimate", Args(new { dn = Julien, sid = "S-1-1-0" })), "estimation avant lecture");
        var user = SimulatedBridge.Json(await bridge.CallAsync("audit.object.acl", Args(new { dn = Julien })));
        var support = user.GetProperty("trustees").EnumerateArray().Single(t => t.GetProperty("name").GetString() == "GG-Support-N2");
        var estimate = SimulatedBridge.Json(await bridge.CallAsync("audit.object.estimate", Args(new { dn = Julien, sid = support.GetProperty("sid").GetString() })));
        var reset = estimate.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("id").GetString() == "reset");
        Check.Equal("allowed", reset.GetProperty("result").GetString(), "réinitialisation déléguée au support");
        Check.Contains("entrée héritée", reset.GetProperty("decidedBy").GetString(), "entrée qui décide");
        Check.Equal(AuditErrors.BuiltinTrustee, await ErrorAsync(bridge, "audit.object.tokenGroups", Args(new { dn = Julien, sid = "S-1-5-11" })), "identité intégrée");

        var service = SimulatedBridge.Json(await bridge.CallAsync("audit.object.acl", Args(new { dn = ServiceWeb })));
        Check.True(service.GetProperty("deny").GetInt32() >= 2, "« ne peut pas changer de mot de passe » : deux refus");
        var admin = SimulatedBridge.Json(await bridge.CallAsync("audit.object.acl", Args(new { dn = AdminJulien })));
        Check.True(admin.GetProperty("protected").GetBoolean(), "AdminSDHolder : héritage désactivé");
        Check.Equal(0, admin.GetProperty("inherited").GetInt32(), "aucune entrée héritée");
    }

    [Test]
    public static async Task An_estimate_refuses_a_trustee_absent_from_the_entries_read()
    {
        var bridge = new SimulatedBridge();
        _ = await bridge.CallAsync("audit.object.acl", Args(new { dn = Julien }));
        Check.Equal(AuditErrors.TrusteeUnknown, await ErrorAsync(bridge, "audit.object.estimate", Args(new { dn = Julien, sid = "S-1-5-21-1-2-3-999999" })), "bénéficiaire absent");
        Check.Equal(AuditErrors.TrusteeUnknown, await ErrorAsync(bridge, "audit.object.tokenGroups", Args(new { dn = Julien, sid = "S-1-5-21-1-2-3-999999" })), "aucune lecture de ses groupes");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.object.estimate", Args(new { dn = Julien, sid = "pas un SID" })), "SID mal formé");
    }

    [Test]
    public static async Task A_new_target_drops_the_reads_of_the_previous_one_and_the_latest_request_decides()
    {
        // AUD-003, AUD-010: the reads kept for local estimates belong to the current object only (Clear-DomeniaAdAuditObjectResults).
        var bridge = new SimulatedBridge();
        _ = await bridge.CallAsync("audit.target", Args(new { dn = Julien }));
        var acl = SimulatedBridge.Json(await bridge.CallAsync("audit.object.acl", Args(new { dn = Julien })));
        var sid = acl.GetProperty("trustees")[0].GetProperty("sid").GetString();
        Check.Equal("result", (await bridge.CallAsync("audit.object.estimate", Args(new { dn = Julien, sid }))).Kind, "estimation sur les entrées lues");
        _ = await bridge.CallAsync("audit.target", Args(new { dn = ServiceWeb }));
        Check.Equal(AuditErrors.AclNotRead, await ErrorAsync(bridge, "audit.object.estimate", Args(new { dn = Julien, sid })), "nouvelle cible : délégations de l’ancienne oubliées");
        _ = await bridge.CallAsync("audit.object.acl", Args(new { dn = ServiceWeb }));
        _ = await bridge.CallAsync("audit.object.groups", Args(new { dn = Julien }));
        Check.Equal(AuditErrors.AclNotRead, await ErrorAsync(bridge, "audit.object.estimate", Args(new { dn = ServiceWeb, sid })), "la dernière demande décide de l’objet courant");
    }

    [Test]
    public static async Task Relations_and_history_of_the_session_account_come_from_local_memory()
    {
        var bridge = new SimulatedBridge();
        var relations = SimulatedBridge.Json(await bridge.CallAsync("audit.object.relations", Args(new { dn = Julien })));
        Check.True(Names(relations).SequenceEqual(["dn", "applicable", "lines", "declared", "observed", "history", "text"]), "propriétés de la synthèse");
        Check.True(relations.GetProperty("applicable").GetBoolean(), "un utilisateur");
        Check.True(relations.GetProperty("lines").GetArrayLength() >= 1, "Julien Martin a une affectation et un historique en simulation");
        Check.True(Names(relations.GetProperty("lines")[0]).SequenceEqual(["fact", "value", "badge", "badgeLabel", "rule"]), "propriétés d’une ligne");
        var history = SimulatedBridge.Json(await bridge.CallAsync("audit.object.history", Args(new { dn = Julien, limit = (int?)null })));
        Check.True(Names(history).SequenceEqual(["dn", "state", "stateLabel", "total", "shown", "limit", "rows", "summary"]), "propriétés de l’historique");
        Check.Equal("read", history.GetProperty("state").GetString(), "historique lu");
        Check.Equal(AuditService.HistoryLimit, history.GetProperty("limit").GetInt32(), "200 lignes par défaut");
        Check.True(history.GetProperty("rows").GetArrayLength() >= 1, "lignes de l’historique");
        Check.True(Names(history.GetProperty("rows")[0]).SequenceEqual(["at", "dateLabel", "user", "computer", "nature", "badge", "rule", "source", "verifiedInAd", "details"]), "propriétés d’une ligne");
        Check.Contains("ne prouve pas une session actuelle", history.GetProperty("summary").GetString(), "limite dite");
        var group = SimulatedBridge.Json(await bridge.CallAsync("audit.object.relations", Args(new { dn = Postes })));
        Check.False(group.GetProperty("applicable").GetBoolean(), "une OU n’a pas d’association");
        Check.Equal(AuditErrors.NotApplicable, await ErrorAsync(bridge, "audit.object.history", Args(new { dn = Postes, limit = 10 })), "historique d’une OU refusé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.object.history", Args(new { dn = Julien, limit = 0 })), "limite hors bornes");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "audit.object.history", Args(new { dn = Julien, limit = 1001 })), "limite hors bornes");
    }

    [Test]
    public static async Task Machine_identity_gives_three_sources_with_stable_fact_ids()
    {
        var bridge = new SimulatedBridge();
        var computer = bridge.Source.CurrentDirectory.Computers.First(c => c.Name.StartsWith("PC-PAR-", StringComparison.Ordinal) && !AdValues.IsDisabled(c.UserAccountControl));
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.object.machineIdentity", Args(new { dn = computer.DistinguishedName })));
        Check.True(Names(json).SequenceEqual(["dn", "state", "stateLabel", "tone", "summary", "reasons", "warnings", "facts", "address", "expected", "reported", "readAt"]), "propriétés de l’identité");
        var ids = json.GetProperty("facts").EnumerateArray().Select(f => f.TryGetProperty("id", out var id) ? id.GetString() : null).ToList();
        Check.True(ids.Contains("adName") && ids.Contains("dnsForward") && ids.Contains("dnsReverse") && ids.Contains("reported"), "faits repérés par un identifiant stable, jamais par leur libellé");
        Check.True(json.GetProperty("state").GetString() is "coherent" or "unverified" or "incoherent", "verdict");
        Check.Equal(AuditErrors.NotApplicable, await ErrorAsync(bridge, "audit.object.machineIdentity", Args(new { dn = Julien })), "un utilisateur n’a pas d’identité de poste");
    }

    [Test]
    public static async Task Gpo_links_of_an_object_outside_the_domain_are_refused()
    {
        var source = new OutsideDomainSource(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed()));
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
            ScreenReaders.Discover(source, [typeof(OutsideDomainAuditReader).Assembly]));
        var registry = OperationModules.CreateRegistry(context, [new AuditOperations()]);
        Check.True(registry.TryGet("audit.object.gpoLinks", out var links), "liens GPO déclarés");
        using var args = JsonDocument.Parse(Args(new { dn = OutsideDomainAuditReader.OutsideDn }));
        var thrown = await Check.ThrowsAsync<DomeniaOperationException>(() => links!.Handler(args.RootElement, new BridgeContext(_ => { }, "test", "audit.object.gpoLinks"), CancellationToken.None), "hors du domaine");
        Check.Equal(AuditErrors.OutsideDomain, thrown.Code, "audit.outsideDomain");
        Check.Equal(AuditErrors.OutsideDomainMessage, thrown.Message, "message du contrat");
    }

    [Test]
    public static async Task Gpo_links_and_the_applied_result_are_two_facts()
    {
        var bridge = new SimulatedBridge();
        var directory = bridge.Source.CurrentDirectory;
        var laptop = directory.Computers.First(c => c.Name.StartsWith("PT-PAR-", StringComparison.Ordinal) && !AdValues.IsDisabled(c.UserAccountControl));
        var links = SimulatedBridge.Json(await bridge.CallAsync("audit.object.gpoLinks", Args(new { dn = laptop.DistinguishedName })));
        Check.True(links.GetProperty("linksRead").GetBoolean(), "liens lus");
        Check.Equal(3, links.GetProperty("chain").GetArrayLength(), "Paris, Postes, domaine");
        var baseline = links.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("name").GetString() == "Postes - Sécurité de base");
        Check.Equal("Oui", baseline.GetProperty("enforced").GetString(), "lien forcé");
        Check.Equal("unproven", baseline.GetProperty("outcome").GetString(), "un lien ne prouve pas l’application");
        var applied = await bridge.CallAsync("audit.object.gpoApplied", Args(new { dn = laptop.DistinguishedName }));
        var view = SimulatedBridge.Json(applied);
        var state = view.GetProperty("rsopState").GetString();
        Check.True(state is "observed" or "unavailable", "RSoP lu ou poste injoignable");
        if (state == "observed")
        {
            Check.True(view.GetProperty("appliedProven").GetBoolean(), "ordre d’application lu");
            Check.True(view.GetProperty("rows").EnumerateArray().Any(r => r.GetProperty("linkedTo").GetString() == string.Empty), "GPO de site, hors liens lus");
        }
    }

    [Test]
    public static async Task Identity_scan_refuses_the_whole_domain_and_reviews_without_merging()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(AuditErrors.ScopeTooWide, await ErrorAsync(bridge, "audit.identities.scan", Args(new { dn = Root, subtree = true })), "jamais tout le domaine");
        Check.Equal(DomeniaErrors.OuUnknown, await ErrorAsync(bridge, "audit.identities.scan", Args(new { dn = "OU=Inconnue,DC=example,DC=local", subtree = false })), "OU inconnue");
        var json = SimulatedBridge.Json(await bridge.CallAsync("audit.identities.scan", Args(new { dn = Postes, subtree = true })));
        Check.Equal(431, json.GetProperty("objects").GetInt32(), "postes de l’OU Postes, sous-OU comprises");
        var findings = json.GetProperty("findings").EnumerateArray().ToList();
        Check.True(findings.All(f => f.GetProperty("conclusion").GetString() == "À revoir"), "tout constat est à revoir");
        Check.True(findings.Any(f => f.GetProperty("category").GetString() == "Nom recyclé ou objet recréé"), "noms recyclés de la copie fictive");
    }

    // ================================================================ pure rules

    [Test]
    public static void Cycles_are_found_once_whatever_their_start()
    {
        var edges = new Dictionary<string, ImmutableArray<string>>(StringComparer.Ordinal)
        {
            ["a"] = ["b"],
            ["b"] = ["c"],
            ["c"] = ["a", "d"],
            ["d"] = [],
            ["e"] = ["e"],
        };
        var cycles = AuditGroupRules.FindCycles(edges);
        Check.Equal(2, cycles.Length, "deux cycles");
        Check.True(cycles.Any(c => c.SequenceEqual(["a", "b", "c", "a"])), "a → b → c → a");
        Check.True(cycles.Any(c => c.SequenceEqual(["e", "e"])), "boucle sur lui-même");
    }

    [Test]
    public static void A_gpLink_gives_its_guid_order_and_options()
    {
        var links = AuditGpoRules.ParseGpLink("[LDAP://cn={31B2F340-016D-11D2-945F-00C04FB984F9},cn=policies,cn=system,DC=x;0][LDAP://cn={6AC1786C-016F-11D2-945F-00C04FB984F9},cn=policies,cn=system,DC=x;3]", "OU=A,DC=x");
        Check.Equal(2, links.Length, "deux liens");
        Check.True(links[0].LinkEnabled && !links[0].Enforced, "premier lien actif, non forcé");
        Check.False(links[1].LinkEnabled, "bit 1 : lien désactivé");
        Check.True(links[1].Enforced, "bit 2 : lien forcé");
        Check.Equal(new Guid("6ac1786c-016f-11d2-945f-00c04fb984f9"), links[1].Guid, "GUID");
    }

    [Test]
    public static void A_refusal_on_the_object_wins_over_an_inherited_allow()
    {
        var read = new AclRead("CN=x,DC=t", ReadState.Read, null, 2, false, 1000,
        [
            new AceRead("S-1-5-21-1-2-3-1100", true, "GenericAll", null, null, true, "All"),
            new AceRead("S-1-5-21-1-2-3-1100", false, "WriteDacl", null, null, false, "None"),
            new AceRead("S-1-5-21-1-2-3-1200", true, "ReadProperty, WriteProperty", new Guid("28630ebf-41d5-11d1-a9c1-0000f80367c1"), null, false, "None"),
        ], null, false, ImmutableDictionary<string, string>.Empty, null, ImmutableDictionary<Guid, string>.Empty, "dc", Fixtures.Now);
        var first = AuditAclRules.Estimate(read, "S-1-5-21-1-2-3-1100", null);
        Check.Equal(EstimateResult.Denied, first.Rows.Single(r => r.Id == "dacl").Result, "refus posé sur l’objet d’abord");
        Check.Equal(EstimateResult.Allowed, first.Rows.Single(r => r.Id == "delete").Result, "contrôle total hérité");
        var second = AuditAclRules.Estimate(read, "S-1-5-21-1-2-3-1200", null);
        Check.Equal(EstimateResult.Partial, second.Rows.Single(r => r.Id == "write").Result, "écriture d’un attribut précis : partiel");
        Check.Equal(EstimateResult.NotGranted, second.Rows.Single(r => r.Id == "reset").Result, "rien d’autre");
        Check.Contains("Groupes du bénéficiaire non lus", second.Limits, "limites dites");
    }

    [Test]
    public static void An_unreadable_resultant_policy_never_presumes_the_domain_one()
    {
        var read = new PasswordPolicyRead("CN=u,DC=t", "dc", Fixtures.Now, AdValues.NormalAccount, 0, Fixtures.Ft(Fixtures.Now - TimeSpan.FromDays(10)), null, null, null, null,
            new DomainPolicyRead(12, 24, AdInterval.Of(TimeSpan.FromDays(90)), AdInterval.Of(TimeSpan.FromDays(1)), 5, AdInterval.Of(TimeSpan.FromMinutes(30)), AdInterval.Of(TimeSpan.FromMinutes(30)), 1, 10), 0);
        var view = AuditPolicyRules.View(read, Fixtures.Now, TestClock.Paris);
        Check.Equal(PolicyState.Unreadable, view.State, "inconnue");
        Check.False(view.PolicyKnown, "non connue");
        Check.True(view.Facts.Any(f => f.Label == "Pourquoi inconnue"), "raison dite");
        Check.True(view.Facts.Where(f => f.Label.StartsWith("Domaine (référence)", StringComparison.Ordinal)).All(f => f.State == AuditFactState.Unknown), "domaine en référence seulement");
        Check.Equal("Inconnue", view.Facts.Single(f => f.Label == "Expiration du mot de passe").Value, "aucune échéance déduite");
    }

    [Test]
    public static void A_workstation_answering_under_another_name_is_incoherent()
    {
        var target = new AuditTarget("CN=PC-A,OU=Postes,DC=t", AuditObjectKind.Computer, "PC-A", "PC-A$", Guid.NewGuid(), null, "pc-a.test.local", 515, null);
        var read = new MachineIdentityRead("pc-a.test.local", new DnsResolutionRead(ReadState.Read, ["10.0.0.5"], "pc-b.test.local", null),
            new ReportedIdentityRead(ReadState.Read, "PC-B", "pc-b.test.local", "test.local", null), Fixtures.Now);
        var view = AuditIdentityRules.MachineView(target.Dn, target, read);
        Check.Equal(IdentityCoherence.Incoherent, view.State, "incohérente");
        Check.True(view.Reasons.Any(r => r.Contains("répond sous le nom pc-b.test.local", StringComparison.Ordinal)), "raison");
        Check.True(view.Warnings.Any(w => w.Contains("DNS inverse", StringComparison.Ordinal)), "inverse périmé");
    }

    [Test]
    public static void The_score_counts_only_findings_that_were_read()
    {
        static AuditFinding F(Severity s, bool passed = false, ReadState state = ReadState.Read) =>
            new("x", s, "", Tone.Off, "", "", "", 1, "", passed, state, "", "", "", null, false, false, null, []);
        var score = AuditFindings.Score([F(Severity.Critical), F(Severity.High), F(Severity.Medium), F(Severity.Low), F(Severity.Critical, state: ReadState.Refused), F(Severity.High, passed: true)]);
        Check.Equal(100 - 15 - 6 - 3 - 1, score.Value, "15, 6, 3 et 1 points");
        Check.Contains("le score peut être optimiste", score.Detail, "contrôle non lu signalé");
    }

    [Test]
    public static void The_gpo_chain_stops_at_the_domain_and_refuses_another_domain()
    {
        var chain = AuditTargets.GpoContainerChain("CN=PC,OU=Paris,OU=Postes,DC=example,DC=local", Root, AuditObjectKind.Computer);
        Check.True(chain.SequenceEqual(["OU=Paris,OU=Postes,DC=example,DC=local", "OU=Postes,DC=example,DC=local", Root]), "OU puis domaine");
        Check.True(AuditTargets.GpoContainerChain("CN=Users,DC=other,DC=local", Root, AuditObjectKind.Other).IsEmpty, "hors domaine : aucun lien");
        Check.True(AuditTargets.GpoContainerChain("CN=x,CN=Users,DC=example,DC=local", Root, AuditObjectKind.User).SequenceEqual([Root]), "conteneur CN= sans lien");
    }

    [Test]
    public static void An_unreachable_controller_is_not_read_never_down()
    {
        // The host of the list that does not answer (no DNS, no port): « Non lu », never « en panne » (Get-DomeniaAdHealthView).
        var probe = new ControllerProbesRead(
            [new ControllerProbeRead("DC03.test.local", [], "Hôte inconnu.", false, false, ReadState.NotRead, null, null, null, null, null, ReadState.NotRead, null, [])],
            [], ReadState.Read, null, null, Fixtures.Now);
        var view = AuditControllerRules.HealthView(probe, Fixtures.Now, TestClock.Paris);
        var row = view.Rows.Single();
        Check.Equal(ControllerVerdict.NotRead, row.Verdict, "non lu");
        Check.False(row.VerdictLabel.Contains("panne", StringComparison.OrdinalIgnoreCase), "jamais « en panne »");
    }

    [Test]
    public static void Replication_xml_refuses_a_dtd_and_reads_never_for_1601()
    {
        Check.Null(AuditControllerRules.ParseNeighbor("<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///c:/windows/win.ini\">]><DS_REPL_NEIGHBOR><pszNamingContext>&e;</pszNamingContext></DS_REPL_NEIGHBOR>"), "DTD refusée");
        var neighbor = AuditControllerRules.ParseNeighbor("<DS_REPL_NEIGHBOR><pszNamingContext>DC=x</pszNamingContext><pszSourceDsaDN>CN=NTDS Settings,CN=DC02,CN=Servers,CN=Lyon,CN=Sites,CN=Configuration,DC=x</pszSourceDsaDN><ftimeLastSyncSuccess>1601-01-01T00:00:00Z</ftimeLastSyncSuccess><dwLastSyncResult>1722</dwLastSyncResult><cNumConsecutiveSyncFailures>3</cNumConsecutiveSyncFailures></DS_REPL_NEIGHBOR>");
        Check.NotNull(neighbor, "fragment lu");
        Check.Equal("DC02", neighbor!.Partner, "partenaire");
        Check.True(neighbor.Never, "1601 : jamais");
        Check.Equal(1722L, neighbor.LastResult, "résultat");
        Check.Equal("1722 (serveur RPC non disponible)", AuditText.ReplicationResult(neighbor.LastResult), "résultat traduit");
    }
}

/// <summary>
/// Source of the « outside the domain » test only (its own type, so <see cref="OutsideDomainAuditReader"/> never matches a real
/// source in the discovery tests): the fictitious session, unchanged.
/// </summary>
public sealed class OutsideDomainSource(SimulatedDirectorySource inner) : IDirectorySource
{
    public SimulatedDirectorySource Inner { get; } = inner;

    public DirectorySourceKind Kind => Inner.Kind;

    public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken) => Inner.GetSessionAsync(cancellationToken);

    public Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken) => Inner.ReadLocalAsync(cancellationToken);

    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken) => Inner.RefreshAsync(family, scope, cancellationToken);
}

/// <summary>
/// Simulated audit reader whose index also knows one workstation of another domain (a stale entry of the local index): its
/// GPO chain never reaches the root of the session, so the links are refused with audit.outsideDomain before any read.
/// </summary>
public sealed class OutsideDomainAuditReader(OutsideDomainSource source) : IAuditReader
{
    public const string OutsideDn = "CN=PC-AILLEURS,OU=Postes,DC=autre,DC=local";

    private readonly SimulatedAuditReader inner = new(source.Inner);

    public Task<AuditTarget?> FindTargetAsync(string dn, CancellationToken cancellationToken) =>
        string.Equals(dn, OutsideDn, StringComparison.OrdinalIgnoreCase)
            ? Task.FromResult<AuditTarget?>(new AuditTarget(OutsideDn, AuditObjectKind.Computer, "PC-AILLEURS", "PC-AILLEURS$", Guid.Parse("8d1f4c55-2f53-4b0c-9a59-0c6f1c7a3b11"), null, "pc-ailleurs.autre.local", 515, null))
            : inner.FindTargetAsync(dn, cancellationToken);

    public Task<ImmutableArray<AuditTarget>> SearchObjectsAsync(string text, int limit, CancellationToken cancellationToken) => inner.SearchObjectsAsync(text, limit, cancellationToken);

    public Task<AuditTarget?> FindDomainGroupAsync(int rid, CancellationToken cancellationToken) => inner.FindDomainGroupAsync(rid, cancellationToken);

    public Task<DomainOverviewRead> DomainOverviewAsync(CancellationToken cancellationToken) => inner.DomainOverviewAsync(cancellationToken);

    public Task<LocalTotalsRead> LocalTotalsAsync(CancellationToken cancellationToken) => inner.LocalTotalsAsync(cancellationToken);

    public Task<ControllerListRead> ControllersAsync(CancellationToken cancellationToken) => inner.ControllersAsync(cancellationToken);

    public Task<ControllerProbesRead> ProbeControllersAsync(IReadOnlyList<string> controllers, string? pdc, CancellationToken cancellationToken) => inner.ProbeControllersAsync(controllers, pdc, cancellationToken);

    public Task<ControllerServicesReads> ControllerServicesAsync(IReadOnlyList<string> controllers, int budgetSeconds, CancellationToken cancellationToken) => inner.ControllerServicesAsync(controllers, budgetSeconds, cancellationToken);

    public Task<ObjectComparisonRead> CompareObjectAsync(AuditTarget target, IReadOnlyList<string> controllers, CancellationToken cancellationToken) => inner.CompareObjectAsync(target, controllers, cancellationToken);

    public Task<PasswordPolicyRead> PasswordPolicyAsync(AuditTarget target, CancellationToken cancellationToken) => inner.PasswordPolicyAsync(target, cancellationToken);

    public Task<GroupGraphRead> NestedGroupsAsync(AuditTarget target, CancellationToken cancellationToken) => inner.NestedGroupsAsync(target, cancellationToken);

    public Task<MembershipRead> MembershipAsync(AuditTarget target, string groupDn, CancellationToken cancellationToken) => inner.MembershipAsync(target, groupDn, cancellationToken);

    public Task<AclRead> DelegationsAsync(AuditTarget target, CancellationToken cancellationToken) => inner.DelegationsAsync(target, cancellationToken);

    public Task<TokenGroupsRead> TokenGroupsAsync(string sid, CancellationToken cancellationToken) => inner.TokenGroupsAsync(sid, cancellationToken);

    public Task<GpoLinksRead> GpoLinksAsync(IReadOnlyList<string> containers, CancellationToken cancellationToken) =>
        throw new InvalidOperationException("Aucun lien ne doit être lu pour un objet hors du domaine.");

    public Task<RsopRead> AppliedPoliciesAsync(AuditTarget target, CancellationToken cancellationToken) => inner.AppliedPoliciesAsync(target, cancellationToken);

    public Task<MachineIdentityRead> MachineIdentityAsync(AuditTarget target, CancellationToken cancellationToken) => inner.MachineIdentityAsync(target, cancellationToken);

    public Task<ImmutableArray<RelationRecord>> RelationsAsync(AuditTarget target, CancellationToken cancellationToken) => inner.RelationsAsync(target, cancellationToken);

    public Task<RelationHistoryRead> RelationHistoryAsync(AuditTarget target, int limit, CancellationToken cancellationToken) => inner.RelationHistoryAsync(target, limit, cancellationToken);

    public Task<IdentityScanRead> IdentityScanAsync(string baseDn, bool subtree, int limit, CancellationToken cancellationToken) => inner.IdentityScanAsync(baseDn, subtree, limit, cancellationToken);

    public Task<LocalNamesRead> LocalNamesAsync(IdentityScanRead scan, CancellationToken cancellationToken) => inner.LocalNamesAsync(scan, cancellationToken);
}
