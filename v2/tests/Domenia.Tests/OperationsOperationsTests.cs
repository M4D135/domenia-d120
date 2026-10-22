using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// The operations of the Opérations screen through the real bridge (docs/ops/operations.md): exact JSON shapes, tracking of the
/// other operations, stop of a read, receipts with their detail and their manual review, runs and the resumed survey, checks,
/// diagnostic, documents and refusals. Written with the code, run at the end (decision of David, 21/10).
/// </summary>
internal static class OperationsOperationsTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static readonly string[] RowFields =
    [
        "id", "reference", "operation", "screen", "label", "kind", "kindLabel", "foreground", "listed", "state", "stateLabel", "tone", "icon",
        "outcome", "outcomeLabel", "startedAt", "endedAt", "durationMs", "durationText", "dominantLabel", "dominantMs", "volume", "volumeText",
        "canStop", "stopReason", "detail", "access", "advice", "category", "text", "dropped", "phases", "progress",
    ];

    [Test]
    public static async Task Overview_has_the_contract_shape_and_reads_nothing_on_the_network()
    {
        var bridge = new SimulatedBridge();
        var overview = SimulatedBridge.Json(await bridge.CallAsync("operations.overview"));
        Check.True(Names(overview).SequenceEqual(
        [
            "at", "mode", "simulation", "receiptsTotal", "receiptsPending", "receiptsUnreadable", "receiptsReadable", "receiptsPersistent", "receiptsSummary",
            "pill", "tasks", "sessionTasks", "sessionFailures", "successPercent", "engine", "writeKinds", "note",
        ]), "champs : " + string.Join(", ", Names(overview)));
        Check.Equal("simulation", overview.GetProperty("mode").GetString(), "mode");
        Check.Equal(0, overview.GetProperty("receiptsPending").GetInt32(), "aucun reçu à vérifier");
        Check.False(overview.GetProperty("pill").GetProperty("visible").GetBoolean(), "jamais « 0 opération »");
        Check.True(overview.GetProperty("writeKinds").EnumerateArray().Any(k => k.GetString() == "account.unlock"), "écriture servie en simulation");
        Check.False(overview.GetProperty("receiptsPersistent").GetBoolean(), "reçus en mémoire (tests)");
    }

    [Test]
    public static async Task Every_other_operation_is_followed_and_the_screen_does_not_follow_its_own_reads()
    {
        var bridge = new SimulatedBridge();
        await bridge.CallAsync("dashboard.summary");
        await bridge.CallAsync("dashboard.widget.refresh", Args(new { id = "lockedAccounts" }));
        await bridge.CallAsync("operations.overview");
        var activity = SimulatedBridge.Json(await bridge.CallAsync("operations.activity"));
        Check.True(Names(activity).SequenceEqual(["generatedAt", "summary", "open", "recent", "kept", "listed", "faults", "note"]), "champs de l’activité");
        var recent = activity.GetProperty("recent").EnumerateArray().ToList();
        Check.True(recent.All(r => !r.GetProperty("operation").GetString()!.StartsWith("operations.", StringComparison.Ordinal)), "les lectures de l’écran ne sont pas suivies");
        var refresh = recent.Single(r => r.GetProperty("operation").GetString() == "dashboard.widget.refresh");
        Check.True(Names(refresh).SequenceEqual(RowFields), "champs d’une tâche : " + string.Join(", ", Names(refresh)));
        Check.True(refresh.GetProperty("listed").GetBoolean(), "lecture réseau : demande de l’opérateur, listée");
        Check.Equal("succeeded", refresh.GetProperty("outcome").GetString(), "terminée");
        Check.Equal("Actualisation d’un widget", refresh.GetProperty("label").GetString(), "libellé court");
        Check.Equal(8, refresh.GetProperty("reference").GetString()!.Length, "référence courte");
        var summary = recent.Single(r => r.GetProperty("operation").GetString() == "dashboard.summary");
        Check.False(summary.GetProperty("listed").GetBoolean(), "lecture automatique réussie masquée par défaut");
        var phases = refresh.GetProperty("phases").EnumerateArray().Select(p => p.GetProperty("phase").GetString()).ToList();
        Check.True(phases.SequenceEqual(["request", "engine", "end"]), "demande, traitement, fin");
        var json = JsonSerializer.Serialize(activity);
        Check.False(json.Contains("lockedAccounts", StringComparison.Ordinal), "aucun argument de la demande n’est gardé");
    }

    [Test]
    public static async Task A_write_is_followed_with_its_stages_and_a_refusal_with_its_code_only()
    {
        var bridge = new SimulatedBridge();
        var camille = bridge.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");
        var planned = SimulatedBridge.Json(await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = camille.DistinguishedName })));
        await bridge.CallAsync("write.execute", Args(new { planId = planned.GetProperty("plan").GetProperty("id").GetString(), token = planned.GetProperty("token").GetString(), typedName = (string?)null }));
        Check.Equal(3, bridge.Events.Count(e => e.Operation == "write.execute:stage"), "les étapes partent toujours vers la page");
        await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = "CN=Personne,OU=Nulle,DC=example,DC=local" }));
        var recent = SimulatedBridge.Json(await bridge.CallAsync("operations.activity")).GetProperty("recent").EnumerateArray().ToList();
        var write = recent.Single(r => r.GetProperty("operation").GetString() == "write.execute");
        Check.Equal("Déverrouillage du compte", write.GetProperty("label").GetString(), "libellé du plan exécuté");
        Check.Equal("succeeded", write.GetProperty("outcome").GetString(), "appliquée et vérifiée");
        var stages = write.GetProperty("phases").EnumerateArray().Where(p => p.GetProperty("phase").GetString() == "step").ToList();
        Check.Equal(3, stages.Count, "trois étapes de l’écriture");
        Check.True(write.GetProperty("phases").EnumerateArray().Any(p => p.GetProperty("phase").GetString() == "queue"), "attente du canal d’écriture");
        var refused = recent.First(r => r.GetProperty("operation").GetString() == "accounts.unlock.plan" && r.GetProperty("outcome").GetString() == "refused");
        Check.Equal(WriteErrors.TargetUnknown, refused.GetProperty("category").GetString(), "code du refus");
        Check.False(JsonSerializer.Serialize(refused).Contains("Personne", StringComparison.Ordinal), "jamais la saisie ni le message");
        Check.Contains("Référence " + refused.GetProperty("reference").GetString(), refused.GetProperty("advice").GetString(), "conseil et référence");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("[" + refused.GetProperty("reference").GetString() + "]", StringComparison.Ordinal)), "la référence est dans le journal technique");
    }

    [Test]
    public static async Task Stop_refuses_unknown_and_malformed_tasks()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.task.stop", Args(new { id = "x" }))).Error!.Code, "identifiant mal formé");
        Check.Equal(OperationActivity.TaskUnknown, (await bridge.CallAsync("operations.task.stop", Args(new { id = WritePlans.NewId() }))).Error!.Code, "tâche inconnue");
        Check.Equal(OperationActivity.TaskUnknown, (await bridge.CallAsync("operations.task.stop", Args(new { id = "batch:releve-01" }))).Error!.Code, "aucun lot en cours");
    }

    [Test]
    public static async Task Receipt_detail_says_what_proves_the_write_and_whether_it_can_be_compensated()
    {
        var bridge = new SimulatedBridge();
        var camille = bridge.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");
        var planned = SimulatedBridge.Json(await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = camille.DistinguishedName })));
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Args(new { planId = planned.GetProperty("plan").GetProperty("id").GetString(), token = planned.GetProperty("token").GetString(), typedName = (string?)null })));
        var detail = SimulatedBridge.Json(await bridge.CallAsync("operations.receipts.detail", Args(new { id = receipt.GetProperty("id").GetString() })));
        Check.True(Names(detail).SequenceEqual(["receipt", "rule", "compensation", "actions", "executorAvailable"]), "champs du détail");
        Check.Contains("lockoutTime", detail.GetProperty("rule").GetProperty("check").GetString(), "preuve attendue");
        Check.False(detail.GetProperty("compensation").GetProperty("offered").GetBoolean(), "un déverrouillage ne se compense pas");
        Check.True(detail.GetProperty("actions").GetProperty("canVerify").GetBoolean(), "relecture possible");
        Check.False(detail.GetProperty("actions").GetProperty("canReview").GetBoolean(), "reçu résolu : aucune revue");
        var resolved = await bridge.CallAsync("operations.receipts.review", Args(new { id = receipt.GetProperty("id").GetString(), reason = "Vérifié dans ADUC sur DC01." }));
        Check.Equal(ReceiptReviews.Resolved, resolved.Error!.Code, "un reçu résolu n’est jamais modifié");
        Check.Equal(ReceiptReviews.ReasonInvalid, (await bridge.CallAsync("operations.receipts.review", Args(new { id = receipt.GetProperty("id").GetString(), reason = "court" }))).Error!.Code, "motif trop court");
        Check.Equal(WriteErrors.ReceiptUnknown, (await bridge.CallAsync("operations.receipts.detail", Args(new { id = WritePlans.NewId() }))).Error!.Code, "reçu inconnu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.receipts.detail", Args(new { id = "x" }))).Error!.Code, "identifiant mal formé");
    }

    [Test]
    public static async Task A_manual_review_unblocks_the_target_of_an_uncertain_receipt_and_sends_nothing()
    {
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var executor = new FakeWriteExecutor
        {
            OnExecute = _ => throw new InvalidOperationException("Connexion perdue (test)."),
            OnVerify = _ => new WriteVerification(VerificationState.Unknown, "Contrôleur injoignable."),
        };
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
            writers: WriteExecutors.From([executor]), receipts: new MemoryReceiptStore());
        var circuit = WriteCircuit.From(context);
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        Check.True(receipt.Pending, "issue inconnue : à vérifier");
        var secret = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ReviewAsync(receipt.Id, "Contrôlé, mot de passe: Azerty123", CancellationToken.None), "secret");
        Check.Equal(ReceiptReviews.ReasonInvalid, secret.Code, "motif refusé");
        var reviewed = await circuit.ReviewAsync(receipt.Id, "Vérifié dans ADUC sur DC1 : description à jour.", CancellationToken.None);
        Check.False(reviewed.Pending, "la revue lève l’incertitude");
        Check.Equal(VerificationState.Reviewed, reviewed.Verification, "revue manuelle");
        Check.Equal(Tone.Info, reviewed.Tone, "jamais un succès automatique");
        Check.Equal(1, executor.Executes, "rien n’est renvoyé");
        Check.NotNull(await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "la cible est de nouveau libre");
        Check.Contains("Revue du reçu", context.Journal.Snapshot()[0].Label, "journal des opérations");
        Check.False(((RecordingJournal)context.Log).Lines.Any(l => l.Contains("ADUC", StringComparison.Ordinal)), "le motif ne va jamais au journal technique");
    }

    [Test]
    public static async Task Runs_and_the_interrupted_survey_follow_the_generated_world()
    {
        var bridge = new SimulatedBridge();
        var runs = SimulatedBridge.Json(await bridge.CallAsync("operations.runs"));
        Check.True(Names(runs).SequenceEqual(["generatedAt", "available", "rows", "current", "offer", "currentText", "note"]), "champs des relevés");
        var rows = runs.GetProperty("rows").EnumerateArray().ToList();
        Check.Equal(11, rows.Count, "une ligne par famille et par OU : 1 lecture d’objets, 5 sites × ping et WMI");
        Check.True(rows.Zip(rows.Skip(1)).All(p => string.CompareOrdinal(p.First.GetProperty("attemptAt").GetString(), p.Second.GetProperty("attemptAt").GetString()) >= 0), "le plus récent en haut");
        var offer = runs.GetProperty("offer");
        Check.True(offer.GetProperty("resumable").GetBoolean(), "relevé interrompu à reprendre");
        var remaining = offer.GetProperty("remaining").GetInt32();
        Check.Equal(36 - 21, remaining, "postes restants de Bordeaux");
        Check.Equal(SimulatedOperationsReader.SurveyChanged, (await bridge.CallAsync("operations.survey.resume", Args(new { remaining = remaining + 1 }))).Error!.Code, "offre changée : rien n’est lu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.survey.resume", Args(new { remaining = 0 }))).Error!.Code, "entier positif");
        var started = SimulatedBridge.Json(await bridge.CallAsync("operations.survey.resume", Args(new { remaining })));
        Check.True(started.GetProperty("open").GetBoolean(), "lot en cours");
        Check.Equal(remaining, started.GetProperty("total").GetInt32(), "seuls les postes restants");
        var activity = SimulatedBridge.Json(await bridge.CallAsync("operations.activity"));
        var batch = activity.GetProperty("open").EnumerateArray().Single(r => r.GetProperty("kind").GetString() == "batch");
        Check.True(batch.GetProperty("canStop").GetBoolean(), "un lot s’arrête");
        Check.Equal(SimulatedOperationsReader.SurveyBusy, (await bridge.CallAsync("operations.survey.forget")).Error!.Code, "pas d’abandon pendant la lecture");
        var stopped = SimulatedBridge.Json(await bridge.CallAsync("operations.task.stop", Args(new { id = batch.GetProperty("id").GetString() })));
        Check.Equal("stopRequested", stopped.GetProperty("state").GetString(), "arrêt demandé, pas encore confirmé");
    }

    [Test]
    public static async Task Checks_blockers_health_and_rules_answer_in_plain_words()
    {
        var bridge = new SimulatedBridge();
        var report = SimulatedBridge.Json(await bridge.CallAsync("operations.check.run", Args(new { full = true })));
        var rows = report.GetProperty("rows").EnumerateArray().ToList();
        var policy = rows.Single(r => r.GetProperty("test").GetString() == "Politique d’écriture");
        Check.Equal("ok", policy.GetProperty("status").GetString(), "une seule porte d’écriture");
        Check.True(rows.Any(r => r.GetProperty("test").GetString() == "Recherches répétées"), "mesure de la vérification complète");
        Check.Contains("Aucune écriture effectuée", report.GetProperty("summary").GetString(), "lecture seule dite");
        var blockers = SimulatedBridge.Json(await bridge.CallAsync("operations.blockers"));
        Check.True(blockers.GetProperty("lines").GetArrayLength() > 0, "lignes du bilan");
        Check.True(blockers.GetProperty("transports").EnumerateArray().Any(t => t.GetString()!.Contains("WinRM", StringComparison.Ordinal)), "transports dits");
        var health = SimulatedBridge.Json(await bridge.CallAsync("operations.health"));
        Check.Equal(5, health.GetProperty("categories").GetArrayLength(), "cinq catégories");
        Check.Equal(1, health.GetProperty("providers").GetArrayLength(), "une ligne : les trois sondes en reprise, regroupées");
        Check.True(health.GetProperty("providers").EnumerateArray().Single().GetString()!.StartsWith("WMI · 3 cibles", StringComparison.Ordinal), "les trois sondes en erreur");
        var engine = SimulatedBridge.Json(await bridge.CallAsync("operations.engine"));
        Check.Equal(ProductInfo.Version, engine.GetProperty("version").GetString(), "version");
        var rules = SimulatedBridge.Json(await bridge.CallAsync("operations.rules"));
        Check.True(rules.GetProperty("kinds").EnumerateArray().Single(k => k.GetProperty("kind").GetString() == "account.unlock").GetProperty("available").GetBoolean(), "déverrouillage servi");
        Check.Equal(3, rules.GetProperty("lifecycles").GetArrayLength(), "trois séquences");
        var stats = SimulatedBridge.Json(await bridge.CallAsync("operations.stats"));
        Check.True(stats.GetProperty("history").GetBoolean(), "historique fictif des sessions précédentes");
        var journal = SimulatedBridge.Json(await bridge.CallAsync("operations.journal"));
        Check.True(journal.GetProperty("source").GetInt32() >= 14, "journal fictif de la simulation");
    }

    [Test]
    public static async Task The_diagnostic_and_the_documents_never_leave_the_machine_and_never_hold_a_name()
    {
        var bridge = new SimulatedBridge();
        await bridge.CallAsync("dashboard.summary");
        var preview = SimulatedBridge.Json(await bridge.CallAsync("operations.diagnostic.preview", Args(new { webView = "154.0.4258.62", theme = "dark", interfaceP50Ms = 2.5, interfaceP95Ms = 9.0, interfaceSamples = 40 })));
        var json = preview.GetProperty("json").GetString()!;
        Check.Contains("Domenia.Diagnostic.3", json, "format");
        Check.False(json.Contains("j.martin", StringComparison.OrdinalIgnoreCase) || json.Contains("example.local", StringComparison.OrdinalIgnoreCase), "aucun nom");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.diagnostic.preview", Args(new { interfaceP50Ms = -3 }))).Error!.Code, "nombre positif");
        var saved = SimulatedBridge.Json(await bridge.CallAsync("operations.diagnostic.save", Args(new { })));
        Check.False(saved.GetProperty("saved").GetBoolean(), "reçus en mémoire : rien n’est écrit sur le disque");
        Check.Contains("non écrit", saved.GetProperty("message").GetString(), "dit au retour");
        var export = SimulatedBridge.Json(await bridge.CallAsync("operations.export.save", Args(new { subject = "recus", csv = "\uFEFFÉtat;Opération\r\n" })));
        Check.False(export.GetProperty("saved").GetBoolean(), "CSV préparé en mémoire");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.export.save", Args(new { subject = "..\\x", csv = "a" }))).Error!.Code, "sujet fermé");
        var dossier = SimulatedBridge.Json(await bridge.CallAsync("operations.dossier.save", Args(new { anonymize = true, webView = (string?)null })));
        Check.False(dossier.GetProperty("saved").GetBoolean(), "dossier en mémoire");
    }
}
