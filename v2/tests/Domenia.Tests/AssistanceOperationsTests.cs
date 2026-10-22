using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>Operations of the Assistance screen through the real bridge over the simulated directory (docs/ops/assistance.md).</summary>
internal static class AssistanceOperationsTests
{
    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string UserDn(SimulatedBridge bridge, string sam = "c.bernard") =>
        bridge.Source.CurrentDirectory.Users.First(u => u.SamAccountName == sam).DistinguishedName;

    private static DirectoryComputer Computer(SimulatedBridge bridge, Func<DirectoryComputer, bool> predicate) =>
        bridge.Source.CurrentDirectory.Computers.First(predicate);

    private static string ErrorCode(BridgeResponse response)
    {
        Check.Equal("error", response.Kind, "erreur attendue");
        return response.Error!.Code;
    }

    [Test]
    public static async Task Overview_has_the_contract_shape_and_reads_nothing()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("assistance.overview"));
        Check.True(Names(json).SequenceEqual(["recipes", "workshop", "limits", "readerAvailable", "exportsPersistent", "exportsLabel"]), "propriétés : " + string.Join(",", Names(json)));
        Check.Equal(7, json.GetProperty("recipes").GetArrayLength(), "sept recettes");
        var first = json.GetProperty("recipes")[0];
        Check.Equal("logon", first.GetProperty("id").GetString(), "première recette");
        var step = first.GetProperty("stepList")[1];
        Check.Equal("needSubject", step.GetProperty("state").GetProperty("phase").GetString(), "sans sujet");
        Check.Equal("LockoutDiagnosis", step.GetProperty("operation").GetString(), "opération épinglée");
        Check.True(json.GetProperty("readerAvailable").GetBoolean(), "lecteur de la simulation");
        Check.False(json.GetProperty("exportsPersistent").GetBoolean(), "reçus en mémoire : documents en mémoire");
        Check.Equal(24, json.GetProperty("limits").GetProperty("pins").GetInt32(), "24 repères");
        Check.True(json.GetProperty("workshop").GetProperty("incidents").GetProperty("total").GetInt32() > 0, "incidents de la simulation collectés");
    }

    [Test]
    public static async Task Search_suggest_and_read_give_cards_snapshots_and_findings()
    {
        var bridge = new SimulatedBridge();
        var hits = SimulatedBridge.Json(await bridge.CallAsync("assistance.subjects.search", Args(new { text = "c.bernard" })));
        Check.Equal("c.bernard", hits[0].GetProperty("login").GetString(), "identifiant exact en premier");
        Check.Equal("user", hits[0].GetProperty("kind").GetString(), "compte");
        Check.Equal("arguments.invalid", ErrorCode(await bridge.CallAsync("assistance.subjects.search", Args(new { text = new string('x', 101) }))), "texte trop long");
        var suggestions = SimulatedBridge.Json(await bridge.CallAsync("assistance.subjects.suggest"));
        Check.True(suggestions.GetArrayLength() > 0, "suggestions");
        Check.Equal("c.bernard", suggestions[0].GetProperty("subject").GetProperty("login").GetString(), "compte verrouillé fixe en premier");
        var view = SimulatedBridge.Json(await bridge.CallAsync("assistance.subject.read", Args(new { dn = UserDn(bridge) })));
        Check.True(Names(view).SequenceEqual(["card", "snapshot", "findings", "coverage"]), "propriétés de la lecture");
        Check.Equal("Camille Bernard", view.GetProperty("card").GetProperty("name").GetString(), "carte");
        Check.Equal("live", view.GetProperty("snapshot").GetProperty("source").GetString(), "lecture fraîche");
        Check.Equal(29, view.GetProperty("snapshot").GetProperty("fields").GetArrayLength(), "liste blanche");
        Check.True(view.GetProperty("findings").EnumerateArray().Any(f => f.GetProperty("code").GetString() == "ACCOUNT_LOCKED"), "verrouillage constaté");
        Check.Equal(AssistanceErrors.SubjectUnknown, ErrorCode(await bridge.CallAsync("assistance.subject.read", Args(new { dn = "CN=Personne,DC=example,DC=local" }))), "objet introuvable");
        Check.Equal("arguments.invalid", ErrorCode(await bridge.CallAsync("assistance.subject.read", Args(new { dn = "pas un dn" }))), "DN mal formé");
        Check.Equal(AssistanceErrors.NotRead, ErrorCode(await bridge.CallAsync("assistance.subject.analyse", Args(new { dn = UserDn(bridge, "j.martin") }))), "analyse sans lecture");
    }

    [Test]
    public static async Task A_step_reads_once_from_the_closed_list_and_says_when()
    {
        var bridge = new SimulatedBridge();
        var dn = UserDn(bridge);
        await bridge.CallAsync("assistance.subject.read", Args(new { dn }));
        var run = SimulatedBridge.Json(await bridge.CallAsync("assistance.step.run", Args(new { recipe = "logon", step = "lockouts", dn })));
        var step = run.GetProperty("step");
        Check.Equal("read", step.GetProperty("state").GetProperty("phase").GetString(), "lue");
        Check.Contains("Lue à", step.GetProperty("state").GetProperty("text").GetString(), "heure de la lecture");
        var reading = step.GetProperty("reading");
        Check.Equal("LockoutDiagnosis", reading.GetProperty("operation").GetString(), "opération de la liste fermée");
        Check.True(reading.GetProperty("facts").GetArrayLength() >= 4, "faits résumés dans la ligne");
        Check.Equal("alert", reading.GetProperty("tone").GetString(), "verrouillages trouvés");
        var recipes = SimulatedBridge.Json(await bridge.CallAsync("assistance.recipes", Args(new { user = dn, computer = (string?)null })));
        Check.Equal(1, recipes.GetProperty("recipes")[0].GetProperty("done").GetInt32(), "une étape lue");
        Check.True(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains("Camille Bernard", StringComparison.Ordinal)), "journal des opérations");
        Check.Equal(AssistanceErrors.StepWithoutRead, ErrorCode(await bridge.CallAsync("assistance.step.run", Args(new { recipe = "logon", step = "account", dn }))), "étape sans lecture");
        Check.Equal(AssistanceErrors.RecipeUnknown, ErrorCode(await bridge.CallAsync("assistance.step.run", Args(new { recipe = "inconnue", step = "x", dn }))), "recette inconnue");
        Check.Equal(AssistanceErrors.StepUnknown, ErrorCode(await bridge.CallAsync("assistance.step.run", Args(new { recipe = "logon", step = "Remove-ADUser", dn }))), "étape inconnue : jamais devinée");
        Check.Equal(AssistanceErrors.SubjectMismatch, ErrorCode(await bridge.CallAsync("assistance.step.run", Args(new { recipe = "logon", step = "reach", dn }))), "étape d’un poste pour un compte");
    }

    [Test]
    public static async Task A_workstation_that_refuses_or_does_not_answer_is_recorded_never_retried()
    {
        var bridge = new SimulatedBridge();
        var probe = bridge.Source.World.Presence.ErrorProbes.First();
        var refused = Computer(bridge, c => c.ObjectGuid == probe);
        var run = SimulatedBridge.Json(await bridge.CallAsync("assistance.step.run", Args(new { recipe = "slow", step = "inventory", dn = refused.DistinguishedName })));
        Check.Equal("refused", run.GetProperty("step").GetProperty("state").GetProperty("phase").GetString(), "refus de la cible");
        Check.Contains("0x80070005", run.GetProperty("step").GetProperty("error").GetString(), "message du refus");
        var workshop = SimulatedBridge.Json(await bridge.CallAsync("assistance.workshop.get"));
        Check.True(workshop.GetProperty("incidents").GetProperty("items").EnumerateArray().Any(i => i.GetProperty("codes").GetString()!.Contains("ACCESS_DENIED", StringComparison.Ordinal)),
            "le refus devient un incident expliqué");
        var disabled = Computer(bridge, c => AdValues.IsDisabled(c.UserAccountControl));
        var failed = SimulatedBridge.Json(await bridge.CallAsync("assistance.step.run", Args(new { recipe = "slow", step = "inventory", dn = disabled.DistinguishedName })));
        Check.Equal("failed", failed.GetProperty("step").GetProperty("state").GetProperty("phase").GetString(), "échec, rien n’est relancé");
    }

    [Test]
    public static async Task Captures_compare_and_survive_a_file_round_trip()
    {
        var bridge = new SimulatedBridge();
        var a = UserDn(bridge);
        var b = UserDn(bridge, "j.martin");
        Check.Equal(AssistanceErrors.NotRead, ErrorCode(await bridge.CallAsync("assistance.capture.take", Args(new { slot = "a", dn = a }))), "capture sans lecture refusée");
        await bridge.CallAsync("assistance.subject.read", Args(new { dn = a }));
        await bridge.CallAsync("assistance.subject.read", Args(new { dn = b }));
        await bridge.CallAsync("assistance.capture.take", Args(new { slot = "a", dn = a }));
        var view = SimulatedBridge.Json(await bridge.CallAsync("assistance.capture.take", Args(new { slot = "b", dn = b })));
        var comparison = view.GetProperty("comparison");
        Check.True(comparison.GetProperty("ready").GetBoolean() && !comparison.GetProperty("sameObject").GetBoolean(), "objets différents comparés comme référence");
        Check.True(comparison.GetProperty("different").GetInt32() > 0, "différences");
        var swapped = SimulatedBridge.Json(await bridge.CallAsync("assistance.capture.swap"));
        Check.Equal("Julien Martin", swapped.GetProperty("a").GetProperty("name").GetString(), "A et B inversés");
        var export = SimulatedBridge.Json(await bridge.CallAsync("assistance.capture.export", Args(new { slot = "a" })));
        Check.False(export.GetProperty("saved").GetBoolean(), "mémoire seulement en test");
        Check.Equal(64, export.GetProperty("sha256").GetString()!.Length, "empreinte");
        var file = CaptureFiles.Export(SupportWorkshop.From(bridge.Context).Slot("a"));
        await bridge.CallAsync("assistance.capture.clear", Args(new { slot = (string?)null }));
        var loaded = SimulatedBridge.Json(await bridge.CallAsync("assistance.capture.import", Args(new { slot = "b", content = file })));
        Check.True(loaded.GetProperty("b").GetProperty("historical").GetBoolean(), "capture historique chargée");
        Check.Equal("cache", loaded.GetProperty("b").GetProperty("source").GetString(), "jamais une lecture actuelle");
        Check.Equal(AssistanceErrors.CaptureInvalid, ErrorCode(await bridge.CallAsync("assistance.capture.import", Args(new { slot = "a", content = "{}" }))), "format refusé");
        Check.Equal("arguments.invalid", ErrorCode(await bridge.CallAsync("assistance.capture.take", Args(new { slot = "c", dn = a }))), "emplacement inconnu");
    }

    [Test]
    public static async Task Pins_are_bounded_unique_and_found_again_by_guid()
    {
        var bridge = new SimulatedBridge();
        var dn = UserDn(bridge);
        await bridge.CallAsync("assistance.subject.read", Args(new { dn }));
        await bridge.CallAsync("assistance.pin.add", Args(new { dn }));
        var twice = SimulatedBridge.Json(await bridge.CallAsync("assistance.pin.add", Args(new { dn })));
        Check.Equal(1, twice.GetProperty("pins").GetArrayLength(), "aucun doublon d’identité");
        var identity = twice.GetProperty("pins")[0].GetProperty("identity").GetString()!;
        Check.True(identity.StartsWith("guid:", StringComparison.Ordinal), "identité par GUID");
        var where = SimulatedBridge.Json(await bridge.CallAsync("assistance.pin.locate", Args(new { identity })));
        Check.False(where.GetProperty("moved").GetBoolean(), "toujours à sa place");
        Check.Equal(dn, where.GetProperty("dn").GetString(), "DN actuel");
        foreach (var user in bridge.Source.CurrentDirectory.Users.Where(u => u.DistinguishedName.Contains("OU=Paris", StringComparison.Ordinal)).Take(24))
        {
            await bridge.CallAsync("assistance.subject.read", Args(new { dn = user.DistinguishedName }));
            await bridge.CallAsync("assistance.pin.add", Args(new { dn = user.DistinguishedName }));
        }
        var full = SimulatedBridge.Json(await bridge.CallAsync("assistance.workshop.get"));
        Check.Equal(24, full.GetProperty("pins").GetArrayLength(), "24 repères au plus");
        var removed = SimulatedBridge.Json(await bridge.CallAsync("assistance.pin.remove", Args(new { identity })));
        Check.Equal(23, removed.GetProperty("pins").GetArrayLength(), "repère retiré");
        Check.Equal(AssistanceErrors.PinUnknown, ErrorCode(await bridge.CallAsync("assistance.pin.remove", Args(new { identity }))), "repère déjà retiré");
        var reset = SimulatedBridge.Json(await bridge.CallAsync("assistance.workshop.reset"));
        Check.Equal(0, reset.GetProperty("pins").GetArrayLength(), "atelier vidé");
    }

    [Test]
    public static async Task Documents_need_a_key_to_pseudonymise_and_keep_the_raw_incident_out()
    {
        var bridge = new SimulatedBridge();
        var dn = UserDn(bridge);
        await bridge.CallAsync("assistance.subject.read", Args(new { dn }));
        await bridge.CallAsync("assistance.step.run", Args(new { recipe = "logon", step = "lockouts", dn }));
        var workshop = SimulatedBridge.Json(await bridge.CallAsync("assistance.workshop.get"));
        var incident = workshop.GetProperty("incidents").GetProperty("items")[0];
        var preview = SimulatedBridge.Json(await bridge.CallAsync("assistance.report.preview",
            Args(new { dn, ticket = "INC-42", template = "glpi", incident = incident.GetProperty("id").GetString(), pseudonymize = false, key = (string?)null })));
        var text = preview.GetProperty("text").GetString()!;
        Check.Contains("Référence du ticket" + FrenchText.Colon + "INC-42", text, "référence");
        Check.Contains("### Objet observé", text, "gabarit GLPI");
        Check.False(text.Contains(incident.GetProperty("detail").GetString()!, StringComparison.Ordinal), "message brut jamais exporté");
        Check.Equal(AssistanceErrors.KeyMissing, ErrorCode(await bridge.CallAsync("assistance.report.preview", Args(new { dn, pseudonymize = true, key = "court" }))), "clé trop courte");
        var masked = SimulatedBridge.Json(await bridge.CallAsync("assistance.report.preview", Args(new { dn, pseudonymize = true, key = "cle-de-test-1" })));
        Check.False(masked.GetProperty("text").GetString()!.Contains("Camille", StringComparison.Ordinal), "noms pseudonymisés");
        var export = SimulatedBridge.Json(await bridge.CallAsync("assistance.report.export", Args(new { dn })));
        Check.False(export.GetProperty("saved").GetBoolean(), "rien n’est écrit en test");
        var ticket = SimulatedBridge.Json(await bridge.CallAsync("assistance.ticket.preview", Args(new { dn })));
        Check.True(ticket.GetProperty("ready").GetBoolean(), "compte rendu prêt");
        Check.Equal(1, ticket.GetProperty("counts").GetProperty("confirmed").GetInt32(), "lecture confirmée");
        Check.True(ticket.GetProperty("counts").GetProperty("notTested").GetInt32() >= 1, "étapes non testées dites");
        Check.Equal("arguments.invalid", ErrorCode(await bridge.CallAsync("assistance.ticket.preview", Args(new { dn, sections = new[] { "context", "inconnue" } }))), "section inconnue");
    }

    [Test]
    public static async Task Offline_dossier_is_bounded_hashed_and_kept_in_memory_in_tests()
    {
        var bridge = new SimulatedBridge();
        var result = SimulatedBridge.Json(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "workingOu", dn = (string?)null, sections = new[] { "observations" } })));
        Check.False(result.GetProperty("saved").GetBoolean(), "mémoire seulement en test");
        string[] files = [.. result.GetProperty("files").EnumerateArray().Select(f => f.GetProperty("name").GetString()!)];
        Check.True(files.SequenceEqual(["etat.json", "postes.json", "observations.json", "LISEZMOI.txt", "manifeste.json", "SHA256SUMS.txt"]), "fichiers : " + string.Join(",", files));
        Check.Equal(AssistanceErrors.DossierPerimeter, ErrorCode(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "subject" }))), "aucun poste choisi");
        Check.Equal(AssistanceErrors.DossierPerimeter, ErrorCode(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "pins" }))), "aucun poste épinglé");
        Check.Equal("arguments.invalid", ErrorCode(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "domaine" }))), "périmètre inconnu");
    }

    [Test]
    public static async Task Engine_state_reads_no_network_and_directory_mode_refuses_without_reader()
    {
        var bridge = new SimulatedBridge();
        var state = SimulatedBridge.Json(await bridge.CallAsync("assistance.engine.state"));
        Check.Equal("simulation", state.GetProperty("mode").GetString(), "mode");
        Check.True(state.GetProperty("readers").EnumerateArray().Any(r => r.GetString() == "IAssistanceReader"), "lecteur servi");
        Check.True(bridge.Registry.TryGet("assistance.step.run", out var run) && run!.ServedInSimulation, "lecture d’étape servie par l’annuaire fictif");

        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        using var context = new EngineContext(decision, new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun"), new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        var registry = OperationModules.CreateRegistry(context, [new AssistanceOperations()]);
        Check.True(registry.TryGet("assistance.subject.read", out var read) && read!.Class == OperationClass.NetworkRead, "lecture réseau en mode annuaire");
        var dispatcherResponses = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, dispatcherResponses.Add, AdmissionGuards.ReadOnlyDirectory);
        await dispatcher.HandleAsync("{\"id\":\"d1\",\"op\":\"assistance.subjects.search\",\"args\":{\"text\":\"martin\"}}", CancellationToken.None);
        Check.Equal("source.unavailable", dispatcherResponses.Single().Error!.Code, "aucun lecteur : refus explicite");
        await dispatcher.HandleAsync("{\"id\":\"d2\",\"op\":\"assistance.overview\",\"args\":{}}", CancellationToken.None);
        Check.Equal("result", dispatcherResponses[1].Kind, "les recettes restent consultables");
    }
}
