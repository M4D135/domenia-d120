using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// The operations of the Opérations screen through the real bridge (docs/ops/operations.md): exact JSON shapes, tracking of the
/// other operations, stop of a read and of a batch, receipts with their detail and their manual review, the global blocking of the
/// writes while a receipt waits, runs and the resumed survey, checks, interface measures, diagnostic, documents and refusals.
/// Written with the code, run at the end (decision of David, 21/10).
/// </summary>
internal static class OperationsOperationsTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static readonly string[] RowFields =
    [
        "id", "reference", "operation", "screen", "label", "kind", "kindLabel", "foreground", "listed", "state", "stateLabel", "tone", "icon",
        "outcome", "outcomeLabel", "startedAt", "endedAt", "durationMs", "durationText", "dominantLabel", "dominantMs", "volume", "volumeText",
        "canStop", "stopReason", "detail", "access", "advice", "next", "category", "text", "dropped", "phases", "progress",
    ];

    [Test]
    public static async Task Overview_has_the_contract_shape_and_reads_nothing_on_the_network()
    {
        var bridge = new SimulatedBridge();
        var overview = SimulatedBridge.Json(await bridge.CallAsync("operations.overview"));
        Check.True(Names(overview).SequenceEqual(
        [
            "at", "mode", "simulation", "receiptsTotal", "receiptsPending", "receiptsUnreadable", "receiptsReadable", "receiptsPersistent", "receiptsSummary",
            "pill", "tasks", "sessionTasks", "sessionFailures", "successPercent", "engine", "writeKinds", "hiddenAutomatic", "note",
        ]), "champs : " + string.Join(", ", Names(overview)));
        Check.Equal("simulation", overview.GetProperty("mode").GetString(), "mode");
        Check.Equal(0, overview.GetProperty("receiptsPending").GetInt32(), "aucun reçu à vérifier");
        Check.True(Names(overview.GetProperty("pill")).SequenceEqual(["visible", "text", "help", "oldest"]), "champs de la pastille");
        Check.False(overview.GetProperty("pill").GetProperty("visible").GetBoolean(), "jamais « 0 opération »");
        Check.True(overview.GetProperty("writeKinds").EnumerateArray().Any(k => k.GetString() == "account.unlock"), "écriture servie en simulation");
        Check.False(overview.GetProperty("receiptsPersistent").GetBoolean(), "reçus en mémoire (tests)");
    }

    [Test]
    public static async Task The_session_tile_counts_like_the_grid_shown_by_default()
    {
        var bridge = new SimulatedBridge();
        await bridge.CallAsync("dashboard.summary");
        await bridge.CallAsync("dashboard.summary");
        await bridge.CallAsync("dashboard.widget.refresh", Args(new { id = "lockedAccounts" }));
        var overview = SimulatedBridge.Json(await bridge.CallAsync("operations.overview"));
        Check.Equal(1, overview.GetProperty("sessionTasks").GetInt32(), "seule la demande de l’opérateur est comptée");
        Check.Equal(2, overview.GetProperty("hiddenAutomatic").GetInt32(), "les lectures automatiques réussies sont comptées à part");
        Check.Equal(100.0, overview.GetProperty("successPercent").GetDouble(), "pourcentage des lignes affichées");
    }

    [Test]
    public static async Task Every_other_operation_is_followed_and_the_screen_does_not_follow_its_own_reads()
    {
        var bridge = new SimulatedBridge();
        await bridge.CallAsync("dashboard.summary");
        await bridge.CallAsync("dashboard.widget.refresh", Args(new { id = "lockedAccounts" }));
        await bridge.CallAsync("operations.overview");
        await bridge.CallAsync("operations.receipts");
        await bridge.CallAsync("operations.center");
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
        Check.Contains("Aucune suite nécessaire", refresh.GetProperty("next").GetString(), "suite possible après une réussite");
        var summary = recent.Single(r => r.GetProperty("operation").GetString() == "dashboard.summary");
        Check.False(summary.GetProperty("listed").GetBoolean(), "lecture automatique réussie masquée par défaut");
        var phases = refresh.GetProperty("phases").EnumerateArray().Select(p => p.GetProperty("phase").GetString()).ToList();
        Check.True(phases.SequenceEqual(["request", "work", "publish", "end"]), "demande, traitement, publication, fin : " + string.Join(", ", phases));
        var publish = refresh.GetProperty("phases").EnumerateArray().Single(p => p.GetProperty("phase").GetString() == "publish");
        Check.False(publish.GetProperty("measured").GetBoolean(), "publication non mesurée, jamais 0");
        Check.Contains("total", refresh.GetProperty("text").GetString(), "le total est donné à part");
        var json = JsonSerializer.Serialize(activity);
        Check.False(json.Contains("lockedAccounts", StringComparison.Ordinal), "aucun argument de la demande n’est gardé");
        var stats = SimulatedBridge.Json(await bridge.CallAsync("operations.stats"));
        Check.False(stats.GetProperty("rows").EnumerateArray().Any(r => r.GetProperty("operation").GetString()!.StartsWith("operations.", StringComparison.Ordinal)
            && r.GetProperty("sessionSamples").GetInt32() > 0), "aucune mesure de session pour les lectures de l’écran");
    }

    [Test]
    public static async Task A_write_is_followed_with_its_stages_in_order_and_a_refusal_with_its_code_only()
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
        var phases = write.GetProperty("phases").EnumerateArray().Select(p => p.GetProperty("phase").GetString()).ToList();
        Check.True(phases.SequenceEqual(["request", "queue", "step", "step", "step", "publish", "end"]), "ordre chronologique, total à part : " + string.Join(", ", phases));
        Check.Contains("Le reçu de l’écriture", write.GetProperty("next").GetString(), "suite possible d’une écriture");
        var refused = recent.First(r => r.GetProperty("operation").GetString() == "accounts.unlock.plan" && r.GetProperty("outcome").GetString() == "refused");
        Check.Equal(WriteErrors.TargetUnknown, refused.GetProperty("category").GetString(), "code du refus");
        Check.False(JsonSerializer.Serialize(refused).Contains("Personne", StringComparison.Ordinal), "jamais la saisie ni le message");
        Check.Contains("Référence " + refused.GetProperty("reference").GetString(), refused.GetProperty("advice").GetString(), "conseil et référence");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("[" + refused.GetProperty("reference").GetString() + "]", StringComparison.Ordinal)), "la référence est dans le journal technique");
    }

    [Test]
    public static async Task Reads_that_hand_back_a_receipt_stay_reads_even_on_a_receipt_still_to_verify()
    {
        var bridge = new SimulatedBridge();
        var receipt = await PendingReceiptAsync(bridge);
        Check.Equal("result", (await bridge.CallAsync("write.receipts.get", Args(new { id = receipt.Id }))).Kind, "reçu lu");
        await bridge.CallAsync("write.receipts.verify", Args(new { id = receipt.Id }));
        var recent = SimulatedBridge.Json(await bridge.CallAsync("operations.activity")).GetProperty("recent").EnumerateArray().ToList();
        var get = recent.Single(r => r.GetProperty("operation").GetString() == "write.receipts.get");
        Check.Equal("succeeded", get.GetProperty("outcome").GetString(), "une lecture qui répond est terminée, jamais « résultat inconnu »");
        Check.Equal("Lecture d’un reçu", get.GetProperty("label").GetString(), "son propre libellé, jamais celui de l’écriture");
        var verify = recent.Single(r => r.GetProperty("operation").GetString() == "write.receipts.verify");
        Check.Equal("succeeded", verify.GetProperty("outcome").GetString(), "la relecture est une lecture");
        Check.Equal("Relecture d’un reçu", verify.GetProperty("label").GetString(), "libellé de la relecture");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("write.receipts.get", StringComparison.Ordinal) && l.Contains("Unknown", StringComparison.Ordinal)), "aucun avertissement pour une lecture");
        var overview = SimulatedBridge.Json(await bridge.CallAsync("operations.overview"));
        Check.Equal(0, overview.GetProperty("sessionFailures").GetInt32(), "aucune opération à revoir");
        var stats = SimulatedBridge.Json(await bridge.CallAsync("operations.stats"));
        var verifyRow = stats.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("operation").GetString() == "write.receipts.verify");
        Check.True(verifyRow.GetProperty("averageBytes").GetDouble() > 0, "volume reçu estimé d’une lecture distante");
        Check.Equal(0, verifyRow.GetProperty("remoteAttempts").GetInt32(), "aucune tentative distante en simulation");
    }

    [Test]
    public static async Task A_receipt_to_verify_blocks_every_new_write_until_its_review()
    {
        var bridge = new SimulatedBridge();
        var receipt = await PendingReceiptAsync(bridge);
        var overview = SimulatedBridge.Json(await bridge.CallAsync("operations.overview"));
        var pill = overview.GetProperty("pill");
        Check.Equal("1 opération à vérifier", pill.GetProperty("text").GetString(), "pastille");
        Check.Contains("les nouvelles écritures restent bloquées", pill.GetProperty("help").GetString(), "texte de Domenia 1");
        Check.Contains("Camille Bernard", pill.GetProperty("oldest").GetProperty("text").GetString(), "objet du reçu le plus ancien au survol");
        var lucas = bridge.Source.CurrentDirectory.Users.First(u => u.LockoutTime > 0 && u.DisplayName != "Camille Bernard");
        var other = await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = lucas.DistinguishedName }));
        Check.Equal(WriteErrors.ReceiptsPending, other.Error!.Code, "un autre objet est bloqué aussi");
        var camille = bridge.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");
        Check.Equal(WriteErrors.TargetPending, (await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = camille.DistinguishedName }))).Error!.Code, "sa propre cible d’abord");
        var center = SimulatedBridge.Json(await bridge.CallAsync("operations.center"));
        Check.Contains("les nouvelles écritures restent bloquées", center.GetProperty("writeState").GetString(), "état des écritures");
        var blockers = SimulatedBridge.Json(await bridge.CallAsync("operations.blockers"));
        Check.True(blockers.GetProperty("lines").EnumerateArray().Any(l => l.GetProperty("text").GetString()!.Contains("toutes les nouvelles écritures sont bloquées", StringComparison.Ordinal)), "dit dans le bilan");
        var reviewed = SimulatedBridge.Json(await bridge.CallAsync("operations.receipts.review", Args(new { id = receipt.Id, reason = "Vérifié dans ADUC sur DC01 : compte toujours verrouillé." })));
        Check.False(reviewed.GetProperty("receipt").GetProperty("pending").GetBoolean(), "la revue lève l’incertitude");
        Check.Equal("result", (await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = lucas.DistinguishedName }))).Kind, "les écritures sont de nouveau admises");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("Incertitude levée uniquement après vérification ou revue explicite", StringComparison.Ordinal)), "journal technique (Domenia 1, WARN)");
    }

    [Test]
    public static async Task Stop_refuses_unknown_malformed_and_stale_tasks()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.task.stop", Args(new { id = "x" }))).Error!.Code, "identifiant mal formé");
        Check.Equal(OperationActivity.TaskUnknown, (await bridge.CallAsync("operations.task.stop", Args(new { id = WritePlans.NewId() }))).Error!.Code, "tâche inconnue");
        Check.Equal(OperationActivity.TaskUnknown, (await bridge.CallAsync("operations.task.stop", Args(new { id = "batch:releve-01" }))).Error!.Code, "aucun lot en cours");
        var runs = SimulatedBridge.Json(await bridge.CallAsync("operations.runs"));
        var started = SimulatedBridge.Json(await bridge.CallAsync("operations.survey.resume", Args(new { remaining = runs.GetProperty("offer").GetProperty("remaining").GetInt32() })));
        var id = "batch:" + started.GetProperty("id").GetString();
        Check.Equal(OperationActivity.TaskUnknown, (await bridge.CallAsync("operations.task.stop", Args(new { id = "batch:releve-99" }))).Error!.Code, "une ligne d’un ancien lot n’arrête jamais le lot en cours");
        var still = SimulatedBridge.Json(await bridge.CallAsync("operations.activity")).GetProperty("open").EnumerateArray().Single(r => r.GetProperty("kind").GetString() == "batch");
        Check.Equal("running", still.GetProperty("state").GetString(), "le lot en cours continue");
        var stopped = SimulatedBridge.Json(await bridge.CallAsync("operations.task.stop", Args(new { id })));
        Check.Equal("stopRequested", stopped.GetProperty("state").GetString(), "le bon identifiant arrête le lot");
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
        Check.True(detail.GetProperty("actions").GetProperty("templates").EnumerateArray().All(t => !t.GetString()!.Contains("example.local", StringComparison.Ordinal)
            || t.GetString()!.Contains(receipt.GetProperty("controller").GetString()!, StringComparison.Ordinal)), "motifs fréquents au nom du contrôleur du reçu");
        var resolved = await bridge.CallAsync("operations.receipts.review", Args(new { id = receipt.GetProperty("id").GetString(), reason = "Vérifié dans ADUC sur DC01." }));
        Check.Equal(ReceiptReviews.Resolved, resolved.Error!.Code, "un reçu résolu n’est jamais modifié");
        Check.Equal(ReceiptReviews.ReasonInvalid, (await bridge.CallAsync("operations.receipts.review", Args(new { id = receipt.GetProperty("id").GetString(), reason = "court" }))).Error!.Code, "motif trop court");
        Check.Equal(WriteErrors.ReceiptUnknown, (await bridge.CallAsync("operations.receipts.detail", Args(new { id = WritePlans.NewId() }))).Error!.Code, "reçu inconnu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.receipts.detail", Args(new { id = "x" }))).Error!.Code, "identifiant mal formé");
    }

    [Test]
    public static async Task A_manual_review_unblocks_the_writes_and_sends_nothing()
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
        var blocked = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(FakeWriteExecutor.OtherGuid), CancellationToken.None), "autre objet");
        Check.Equal(WriteErrors.ReceiptsPending, blocked.Code, "toutes les nouvelles écritures attendent");
        var secret = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ReviewAsync(receipt.Id, "Contrôlé, mot de passe : <valeur-de-test>", CancellationToken.None), "secret");
        Check.Equal(ReceiptReviews.ReasonInvalid, secret.Code, "motif refusé");
        var reviewed = await circuit.ReviewAsync(receipt.Id, "Vérifié dans ADUC sur DC1 : description à jour.", CancellationToken.None);
        Check.False(reviewed.Pending, "la revue lève l’incertitude");
        Check.Equal(VerificationState.Reviewed, reviewed.Verification, "revue manuelle");
        Check.Equal(Tone.Info, reviewed.Tone, "jamais un succès automatique");
        Check.Equal(1, executor.Executes, "rien n’est renvoyé");
        Check.NotNull(await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "la cible est de nouveau libre");
        Check.NotNull(await circuit.PlanAsync(FakeWriteExecutor.Draft(FakeWriteExecutor.OtherGuid), CancellationToken.None), "les autres objets aussi");
        Check.True(context.Journal.Snapshot().Any(e => e.Label.Contains("Revue du reçu", StringComparison.Ordinal)), "journal des opérations");
        Check.True(context.Journal.Snapshot().Any(e => e.Label.StartsWith("Écritures de nouveau admises", StringComparison.Ordinal)), "levée du blocage dite");
        Check.False(((RecordingJournal)context.Log).Lines.Any(l => l.Contains("ADUC", StringComparison.Ordinal)), "le motif ne va jamais au journal technique");
    }

    [Test]
    public static async Task Runs_and_the_interrupted_survey_follow_the_generated_world_with_their_phases_and_counters()
    {
        var bridge = new SimulatedBridge();
        var runs = SimulatedBridge.Json(await bridge.CallAsync("operations.runs"));
        Check.True(Names(runs).SequenceEqual(["generatedAt", "available", "rows", "current", "offer", "currentText", "note", "active"]), "champs des relevés");
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
        Check.Equal("preparing", started.GetProperty("phase").GetString(), "préparation d’abord");
        Check.Contains("erreur de ping", started.GetProperty("status").GetString(), "compteurs de Domenia 1");
        Check.Contains("faute de capacité", started.GetProperty("status").GetString(), "postes non relus faute de capacité");
        var activity = SimulatedBridge.Json(await bridge.CallAsync("operations.activity"));
        var batch = activity.GetProperty("open").EnumerateArray().Single(r => r.GetProperty("kind").GetString() == "batch");
        Check.True(batch.GetProperty("canStop").GetBoolean(), "un lot s’arrête");
        var progress = batch.GetProperty("progress");
        Check.True(Names(progress).SequenceEqual(["done", "total", "failed", "phase", "header", "counters", "pingErrors", "inFlight", "pendingSaves", "skipped", "steps"]), "champs du lot");
        var steps = progress.GetProperty("steps").EnumerateArray().Select(s => s.GetProperty("label").GetString()).ToList();
        Check.True(steps.SequenceEqual(["Préparation", "Lecture AD", "À confirmer", "En cours", "Enregistrement"]), "phases de Domenia 1");
        Check.Equal(SimulatedOperationsReader.SurveyBusy, (await bridge.CallAsync("operations.survey.forget")).Error!.Code, "pas d’abandon pendant la lecture");
        var stopped = SimulatedBridge.Json(await bridge.CallAsync("operations.task.stop", Args(new { id = batch.GetProperty("id").GetString() })));
        Check.Equal("stopRequested", stopped.GetProperty("state").GetString(), "arrêt demandé, pas encore confirmé");
    }

    [Test]
    public static async Task Checks_blockers_health_and_rules_answer_in_plain_words()
    {
        var bridge = new SimulatedBridge();
        var page = new { strictPolicy = true, structure = 4, structureTotal = 4, motion = "full", webView = "154.0.4258.62" };
        var report = SimulatedBridge.Json(await bridge.CallAsync("operations.check.run", Args(new { full = true, page })));
        var rows = report.GetProperty("rows").EnumerateArray().ToList();
        var policy = rows.Single(r => r.GetProperty("test").GetString() == "Politique d’écriture");
        Check.Equal("ok", policy.GetProperty("status").GetString(), "une seule porte d’écriture");
        Check.True(rows.Any(r => r.GetProperty("test").GetString() == "Recherches répétées"), "mesure de la vérification complète");
        Check.True(rows.Count(r => r.GetProperty("category").GetString() == "Interface") == 4, "les contrôles de la page sont écrits par le moteur");
        Check.False(rows.Any(r => r.GetProperty("category").GetString()!.Contains("WAPT", StringComparison.OrdinalIgnoreCase)), "WAPT abandonné (PST-001)");
        Check.Contains("Aucune écriture effectuée", report.GetProperty("summary").GetString(), "lecture seule dite");
        var ok = rows.Count(r => r.GetProperty("status").GetString() == "ok");
        Check.Equal(ok, report.GetProperty("ok").GetInt32(), "le résumé compte toutes les lignes, celles de la page comprises");
        var journal = SimulatedBridge.Json(await bridge.CallAsync("operations.journal"));
        Check.True(journal.GetProperty("lines").EnumerateArray().Any(l => l.GetProperty("label").GetString()!.Contains(report.GetProperty("summary").GetString()!, StringComparison.Ordinal)),
            "le journal dit les mêmes chiffres que le rapport");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.check.run", Args(new { full = false, page = new { motion = "partout" } }))).Error!.Code, "valeurs fermées seulement");
        var blockers = SimulatedBridge.Json(await bridge.CallAsync("operations.blockers"));
        var texts = blockers.GetProperty("lines").EnumerateArray().Select(l => l.GetProperty("text").GetString()!).ToList();
        Check.True(texts.Any(t => t.Contains("demandent un objet choisi", StringComparison.Ordinal)), "sans sélection (Domenia 1)");
        Check.True(texts.Any(t => t.StartsWith("Boutons clés", StringComparison.Ordinal)), "boutons clés (Domenia 1)");
        Check.True(texts.Any(t => t.StartsWith("Identité des lectures LAPS et BitLocker", StringComparison.Ordinal)), "identité des lectures de secrets");
        Check.True(blockers.GetProperty("transports").EnumerateArray().Any(t => t.GetString()!.Contains("WinRM", StringComparison.Ordinal)), "transports dits");
        var health = SimulatedBridge.Json(await bridge.CallAsync("operations.health"));
        var ids = health.GetProperty("categories").EnumerateArray().Select(c => c.GetProperty("id").GetString()).ToList();
        Check.True(ids.SequenceEqual(["localSearch", "render", "local", "directory", "computers", "writes"]), "les six catégories de Domenia 1");
        Check.Equal(1, health.GetProperty("providers").GetArrayLength(), "une ligne : les trois sondes en reprise, regroupées");
        Check.True(health.GetProperty("providers").EnumerateArray().Single().GetString()!.StartsWith("WMI · 3 cibles", StringComparison.Ordinal), "les trois sondes en erreur");
        Check.True(health.GetProperty("collection").EnumerateArray().Any(c => c.GetString()!.StartsWith("Actions explicites", StringComparison.Ordinal)), "collecte par classe de demande");
        var engine = SimulatedBridge.Json(await bridge.CallAsync("operations.engine"));
        Check.Equal(ProductInfo.Version, engine.GetProperty("version").GetString(), "version");
        var rules = SimulatedBridge.Json(await bridge.CallAsync("operations.rules"));
        Check.True(rules.GetProperty("kinds").EnumerateArray().Single(k => k.GetProperty("kind").GetString() == "account.unlock").GetProperty("available").GetBoolean(), "déverrouillage servi");
        Check.Equal(3, rules.GetProperty("lifecycles").GetArrayLength(), "trois séquences");
        var stats = SimulatedBridge.Json(await bridge.CallAsync("operations.stats"));
        Check.True(stats.GetProperty("history").GetBoolean(), "historique fictif des sessions précédentes");
        var statsRow = stats.GetProperty("rows").EnumerateArray().First();
        Check.True(Names(statsRow).Contains("averageBytes") && Names(statsRow).Contains("bytesPerSecond") && Names(statsRow).Contains("fallbackPercent") && Names(statsRow).Contains("remoteAttempts"),
            "colonnes réseau de Domenia 1");
        Check.True(journal.GetProperty("source").GetInt32() >= 14, "journal fictif de la simulation");
    }

    [Test]
    public static async Task Interface_measures_feed_the_render_category_and_a_stall_writes_one_line()
    {
        var bridge = new SimulatedBridge();
        var report = SimulatedBridge.Json(await bridge.CallAsync("operations.interface.report", Args(new
        {
            renders = new object[] { new { work = "ecran", ms = 48.5 }, new { work = "onglet", ms = 260.0 } },
            stall = new { lateMs = 812.0, work = "ecran", workMs = 640.0, longTaskMs = (double?)null },
        })));
        Check.Equal(2, report.GetProperty("kept").GetInt32(), "deux mesures gardées");
        Check.True(report.GetProperty("logged").GetBoolean(), "une ligne pour le blocage");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("Interface en retard de 812", StringComparison.Ordinal) && l.Contains("attribué", StringComparison.Ordinal)), "ligne écrite dans Domenia.log");
        var again = SimulatedBridge.Json(await bridge.CallAsync("operations.interface.report", Args(new { renders = Array.Empty<object>(), stall = new { lateMs = 500.0, work = (string?)null, workMs = (double?)null, longTaskMs = 450.0 } })));
        Check.False(again.GetProperty("logged").GetBoolean(), "une explication toutes les 5 s au plus");
        bridge.Clock.Advance(TimeSpan.FromSeconds(6));
        var later = SimulatedBridge.Json(await bridge.CallAsync("operations.interface.report", Args(new { renders = Array.Empty<object>(), stall = new { lateMs = 500.0, work = (string?)null, workMs = (double?)null, longTaskMs = 450.0 } })));
        Check.True(later.GetProperty("logged").GetBoolean(), "après 5 s, de nouveau");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("non attribué", StringComparison.Ordinal) && l.Contains("cause non établie", StringComparison.Ordinal)), "une tâche longue du navigateur n’est jamais une cause");
        var health = SimulatedBridge.Json(await bridge.CallAsync("operations.health"));
        var render = health.GetProperty("categories").EnumerateArray().Single(c => c.GetProperty("id").GetString() == "render");
        Check.Equal(2, render.GetProperty("summary").GetProperty("count").GetInt32(), "traitement des résultats dans l’interface");
        Check.True(health.GetProperty("slow").EnumerateArray().Any(s => s.GetProperty("phase").GetString() == "interface"), "un traitement de l’interface de plus de 120 ms est une lenteur");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.interface.report", Args(new { renders = new object[] { new { work = "texte libre", ms = 3.0 } } }))).Error!.Code, "codes fermés seulement");
        Check.False(JsonSerializer.Serialize(bridge.Log.Lines).Contains("texte libre", StringComparison.Ordinal), "jamais une saisie de la page dans le journal");
    }

    [Test]
    public static async Task The_center_gives_the_pill_and_the_tasks_in_progress()
    {
        var bridge = new SimulatedBridge();
        var center = SimulatedBridge.Json(await bridge.CallAsync("operations.center"));
        Check.True(Names(center).SequenceEqual(["at", "pill", "receiptsReadable", "writeState", "writeTone", "summary", "open", "attention", "note"]), "champs du centre");
        Check.False(center.GetProperty("pill").GetProperty("visible").GetBoolean(), "aucun reçu à vérifier");
        Check.Equal("ok", center.GetProperty("writeTone").GetString(), "au repos");
        Check.Equal(0, center.GetProperty("open").GetArrayLength(), "aucune tâche en cours");
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
        var export = SimulatedBridge.Json(await bridge.CallAsync("operations.export.save", Args(new { subject = "recus", csv = "﻿État;Opération\r\n" })));
        Check.False(export.GetProperty("saved").GetBoolean(), "CSV préparé en mémoire");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("operations.export.save", Args(new { subject = "..\\x", csv = "a" }))).Error!.Code, "sujet fermé");
        var dossier = SimulatedBridge.Json(await bridge.CallAsync("operations.dossier.save", Args(new { anonymize = true, webView = (string?)null })));
        Check.False(dossier.GetProperty("saved").GetBoolean(), "dossier en mémoire");
    }

    [Test]
    public static async Task Documents_are_never_overwritten_never_too_large_and_leave_no_temporary_file()
    {
        var bridge = new SimulatedBridge();
        var folder = Path.Combine(Path.GetTempPath(), "domenia-tests-exports-" + Guid.NewGuid().ToString("N"));
        try
        {
            var exports = new OperationsExports(bridge.Context, folder);
            Check.Equal(folder, exports.Folder, "dossier injecté");
            var first = await exports.SaveTextAsync("Domenia-Recus-20261021-182600.csv", "a;b\r\n", bom: true, CancellationToken.None);
            var second = await exports.SaveTextAsync("Domenia-Recus-20261021-182600.csv", "c;d\r\n", bom: true, CancellationToken.None);
            var third = await exports.SaveTextAsync("Domenia-Recus-20261021-182600.csv", "e;f\r\n", bom: true, CancellationToken.None);
            Check.True(first.Saved && second.Saved && third.Saved, "trois documents écrits");
            Check.Equal("Domenia-Recus-20261021-182600-2.csv", second.Name, "un nom pris reçoit -2");
            Check.Equal("Domenia-Recus-20261021-182600-3.csv", third.Name, "puis -3");
            Check.Equal("a;b\r\n", File.ReadAllText(first.Path!), "le premier n’est jamais remplacé");
            Check.True(File.ReadAllBytes(first.Path!).Take(3).SequenceEqual(new byte[] { 0xEF, 0xBB, 0xBF }), "CSV en UTF-8 avec BOM");
            var large = await Check.ThrowsAsync<DomeniaOperationException>(
                () => exports.SaveTextAsync("Domenia-Gros.csv", new string('x', OperationsExports.MaxDocumentBytes + 1), bom: false, CancellationToken.None), "trop gros");
            Check.Equal(OperationsExports.ExportTooLarge, large.Code, "4 Mo au plus");
            Check.False(File.Exists(Path.Combine(folder, "Domenia-Gros.csv")), "rien n’est écrit");
            Check.False(Directory.EnumerateFiles(folder, "*.tmp").Any(), "aucun fichier temporaire laissé");
            var memory = new OperationsExports(bridge.Context, null);
            var kept = await memory.SaveTextAsync("Domenia-Recus.csv", "a", bom: true, CancellationToken.None);
            Check.False(kept.Saved, "sans dossier : préparé en mémoire");
            Check.Equal(OperationsDiagnostics.Sha256("a"), kept.Sha256, "empreinte rendue");

            var target = Path.Combine(folder, "cible");
            var link = Path.Combine(Path.GetTempPath(), "domenia-tests-link-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(target);
            var created = false;
            try
            {
                Directory.CreateSymbolicLink(link, target);
                created = true;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
            {
                // Creating a link needs a privilege the test account may not hold: the check is then skipped, said in the name below.
            }
            if (created)
            {
                try
                {
                    var linked = new OperationsExports(bridge.Context, link);
                    var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => linked.SaveTextAsync("Domenia-Lien.csv", "a", bom: true, CancellationToken.None), "lien");
                    Check.Equal(OperationsExports.ExportFailed, refused.Code, "un lien à la place du dossier est refusé");
                    Check.False(File.Exists(Path.Combine(target, "Domenia-Lien.csv")), "rien n’est écrit au travers du lien");
                }
                finally
                {
                    Directory.Delete(link);
                }
            }
        }
        finally
        {
            if (Directory.Exists(folder))
            {
                Directory.Delete(folder, recursive: true);
            }
        }
    }

    /// <summary>
    /// A receipt found « sent » in the store (application closed during the send): uncertain, so it blocks the writes until a re-read
    /// settles it or a review is recorded (Domenia 1 TRV-231). The plan is that of a real unlock of Camille Bernard.
    /// </summary>
    private static async Task<ReceiptView> PendingReceiptAsync(SimulatedBridge bridge)
    {
        var camille = bridge.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");
        var draft = await bridge.Context.Writers.Require<IAccountUnlockExecutor>().PlanAsync(camille.DistinguishedName, CancellationToken.None);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"EXAMPLE\j.martin", AppMode.Simulation, bridge.Clock.GetUtcNow(), bridge.Clock.LocalTimeZone);
        var sent = WriteReceipts.Sent(plan, WritePlans.NewId(), bridge.Clock.GetUtcNow(), new ReceiptDetail("Préconditions", "Compte relu (essai)."));
        await bridge.Receipts.AppendAsync(sent, CancellationToken.None);
        return WriteReceipts.View(sent);
    }
}
