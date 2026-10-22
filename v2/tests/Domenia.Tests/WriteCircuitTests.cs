using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Executor of the tests: counts its calls; each step can be replaced. Internal, so the discovery of the real executors never
/// finds it.
/// </summary>
internal sealed class FakeWriteExecutor : IWriteExecutor
{
    public const string FakeKind = "test.write";
    public const string TargetGuid = "0b0f8f3e-6a51-4e67-9d1c-2f1b9e2b7a10";
    public const string OtherGuid = "7d2c1a90-3b44-4c5e-8f60-1e2d3c4b5a69";

    public string Kind => FakeKind;

    public int Checks { get; private set; }

    public int Executes { get; private set; }

    public int Verifies { get; private set; }

    public Func<WritePlan, WritePrecheck> OnCheck { get; set; } = _ => WritePrecheck.Valid("Objet relu : inchangé.");

    public Func<WritePlan, WriteOutcome> OnExecute { get; set; } = _ => new WriteOutcome(WriteResult.Applied, "Description remplacée.");

    public Func<WritePlan, WriteVerification> OnVerify { get; set; } = _ => new WriteVerification(VerificationState.Verified, "Description relue conforme.");

    public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        Checks++;
        return Task.FromResult(OnCheck(plan));
    }

    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        Executes++;
        return Task.FromResult(OnExecute(plan));
    }

    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        Verifies++;
        return Task.FromResult(OnVerify(plan));
    }

    public static WritePlanDraft Draft(string guid = TargetGuid, bool typed = false) => new(
        FakeKind,
        "Modifier la description",
        "Modification de la description",
        "La description de l’objet d’essai sera remplacée.",
        new WriteTarget("user", "Compte utilisateur", "Objet d’essai", "CN=Objet d’essai,OU=Essais,DC=test,DC=local", guid, "essai"),
        [new WriteChange("description", "Description", WriteChangeKind.Replace, "Ancienne", "Nouvelle", "Ancienne", "Nouvelle")],
        [],
        typed ? new WriteConfirmation(true, "essai", "Saisie du nom exigée.") : new WriteConfirmation(false, null, "Confirmation simple."),
        new WriteReversibility(true, "Réversible", "Une nouvelle modification rétablit l’ancienne valeur."),
        "DC1.test.local");
}

/// <summary>Receipts whose appends fail from a given version (1: nothing is ever written) or whose reads fail.</summary>
internal sealed class FailingReceiptStore(int failFromVersion, bool failReads = false) : IReceiptStore
{
    private readonly MemoryReceiptStore memory = new();

    public bool Persistent => true;

    public int Appends => memory.Appends;

    public Task AppendAsync(WriteReceipt receipt, CancellationToken cancellationToken)
    {
        if (receipt.Version >= failFromVersion)
        {
            throw new IOException("Disque plein (test).");
        }
        return memory.AppendAsync(receipt, cancellationToken);
    }

    public Task<ReceiptLog> ReadAllAsync(CancellationToken cancellationToken) =>
        failReads ? Task.FromException<ReceiptLog>(new IOException("Fichier verrouillé (test).")) : memory.ReadAllAsync(cancellationToken);
}

internal static class WriteCircuitTests
{
    private static readonly string[] PlanFields =
    [
        "id", "kind", "title", "label", "summary", "target", "changes", "risks", "confirmation", "reversibility", "controller",
        "operator", "mode", "simulated", "createdAt", "expiresAt", "fingerprint", "details",
    ];

    private static readonly string[] ReceiptFields =
    [
        "id", "kind", "title", "label", "target", "at", "sentAt", "completedAt", "verifiedAt", "operator", "controller", "mode",
        "simulated", "result", "resultLabel", "verification", "verificationLabel", "pending", "tone", "summary", "error",
        "details", "plan",
    ];

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static DirectoryUser Camille(SimulatedBridge bridge) =>
        bridge.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");

    private static async Task<JsonElement> PlanCamilleAsync(SimulatedBridge bridge) =>
        SimulatedBridge.Json(await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = Camille(bridge).DistinguishedName })));

    private static string Execute(JsonElement planned, string? typedName = null) => Args(new
    {
        planId = planned.GetProperty("plan").GetProperty("id").GetString(),
        token = planned.GetProperty("token").GetString(),
        typedName,
    });

    private static int LockedAccounts(JsonElement summary) =>
        summary.GetProperty("widgets").GetProperty("lockedAccounts").GetProperty("data").GetProperty("value").GetInt32();

    private static (EngineContext Context, WriteCircuit Circuit, FakeWriteExecutor Executor, FixedTimeProvider Clock) FakeCircuit(IReceiptStore? receipts = null)
    {
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var executor = new FakeWriteExecutor();
        var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
            writers: WriteExecutors.From([executor]), receipts: receipts ?? new MemoryReceiptStore());
        return (context, WriteCircuit.From(context), executor, clock);
    }

    // ---------------------------------------------------------------- the example: unlock, end to end

    [Test]
    public static async Task Unlock_plan_has_the_contract_shape_and_writes_nothing()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var planned = await PlanCamilleAsync(bridge);
        Check.True(Names(planned).SequenceEqual(["plan", "token"]), "forme : plan et jeton");
        var plan = planned.GetProperty("plan");
        Check.True(Names(plan).SequenceEqual(PlanFields), "champs du plan : " + string.Join(", ", Names(plan)));
        Check.Equal("account.unlock", plan.GetProperty("kind").GetString(), "type");
        Check.Equal("Déverrouiller le compte", plan.GetProperty("title").GetString(), "titre");
        Check.Equal("Déverrouillage du compte", plan.GetProperty("label").GetString(), "libellé");
        var target = plan.GetProperty("target");
        Check.True(Names(target).SequenceEqual(["kind", "kindLabel", "name", "dn", "objectGuid", "samAccountName"]), "champs de la cible");
        Check.Equal("user", target.GetProperty("kind").GetString(), "compte utilisateur");
        Check.Equal("Camille Bernard", target.GetProperty("name").GetString(), "nom");
        Check.Equal(camille.DistinguishedName, target.GetProperty("dn").GetString(), "DN");
        Check.Equal(camille.ObjectGuid.ToString("D"), target.GetProperty("objectGuid").GetString(), "GUID figé");
        Check.Equal(camille.SamAccountName, target.GetProperty("samAccountName").GetString(), "compte");
        var change = plan.GetProperty("changes").EnumerateArray().Single();
        Check.True(Names(change).SequenceEqual(["attribute", "label", "kind", "before", "after", "beforeValue", "afterValue"]), "champs d’un changement");
        Check.Equal("lockoutTime", change.GetProperty("attribute").GetString(), "attribut");
        Check.Equal("clear", change.GetProperty("kind").GetString(), "remise à zéro");
        Check.Equal("Déverrouillé", change.GetProperty("after").GetString(), "après");
        Check.Contains("Verrouillé depuis le 21/10/2026 à ", change.GetProperty("before").GetString(), "avant, heure locale");
        Check.Equal(camille.LockoutTime!.Value.ToString(System.Globalization.CultureInfo.InvariantCulture), change.GetProperty("beforeValue").GetString(), "valeur brute avant");
        Check.Equal("0", change.GetProperty("afterValue").GetString(), "valeur brute après");
        var risks = plan.GetProperty("risks").EnumerateArray().ToList();
        Check.True(risks.Any(r => r.GetProperty("tone").GetString() == "warn" && r.GetProperty("text").GetString()!.Contains("identité du demandeur", StringComparison.Ordinal)), "vérifier l’identité du demandeur");
        Check.True(risks.Any(r => r.GetProperty("text").GetString()!.Contains("essais erronés (5)", StringComparison.Ordinal)), "compteur d’essais remis à zéro");
        var confirmation = plan.GetProperty("confirmation");
        Check.False(confirmation.GetProperty("typedNameRequired").GetBoolean(), "compte standard : confirmation simple");
        Check.Equal(JsonValueKind.Null, confirmation.GetProperty("typedName").ValueKind, "aucun nom à saisir");
        Check.False(plan.GetProperty("reversibility").GetProperty("reversible").GetBoolean(), "déverrouillage sans retour arrière");
        Check.Equal("DC01.example.local", plan.GetProperty("controller").GetString(), "contrôleur");
        Check.Equal(@"EXAMPLE\adm-j.martin", plan.GetProperty("operator").GetString(), "opérateur (compte d’administration)");
        Check.Equal("simulation", plan.GetProperty("mode").GetString(), "mode");
        Check.True(plan.GetProperty("simulated").GetBoolean(), "plan simulé");
        Check.Equal("2026-10-21T16:26:00Z", plan.GetProperty("createdAt").GetString(), "préparé maintenant");
        Check.Equal("2026-10-21T16:31:00Z", plan.GetProperty("expiresAt").GetString(), "valable 5 minutes");
        Check.True(WritePlans.IsPlanId(plan.GetProperty("id").GetString()), "identifiant de 32 caractères hexadécimaux");
        Check.Equal(64, plan.GetProperty("fingerprint").GetString()!.Length, "empreinte SHA-256");
        Check.Contains("Empreinte du plan", plan.GetProperty("details").GetString(), "détails techniques");
        Check.True(ConfirmationTokens.IsWellFormed(planned.GetProperty("token").GetString()), "jeton de 43 caractères");
        Check.Equal(0L, bridge.Source.Overlay.Version, "un plan n’écrit rien");
        Check.Equal(0, ((MemoryReceiptStore)bridge.Receipts).Appends, "aucun reçu pour un plan");
    }

    [Test]
    public static async Task Unlock_runs_once_on_the_overlay_with_a_verified_receipt_seen_by_every_read()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var fingerprint = bridge.Source.World.ComputeFingerprint();
        var lockedBefore = LockedAccounts(SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary")));
        var planned = await PlanCamilleAsync(bridge);

        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned)));
        Check.True(Names(receipt).SequenceEqual(ReceiptFields), "champs du reçu : " + string.Join(", ", Names(receipt)));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "écriture appliquée");
        Check.Equal("Appliquée (simulation)", receipt.GetProperty("resultLabel").GetString(), "libellé du résultat");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "vérifiée par relecture");
        Check.False(receipt.GetProperty("pending").GetBoolean(), "rien à vérifier");
        Check.Equal("ok", receipt.GetProperty("tone").GetString(), "ton");
        Check.True(receipt.GetProperty("simulated").GetBoolean(), "reçu marqué simulé");
        Check.Equal("simulation", receipt.GetProperty("mode").GetString(), "mode");
        Check.Equal(@"EXAMPLE\adm-j.martin", receipt.GetProperty("operator").GetString(), "opérateur (compte d’administration)");
        Check.Contains("aucun effet réel", receipt.GetProperty("summary").GetString(), "la simulation est dite");
        Check.Equal(JsonValueKind.Null, receipt.GetProperty("error").ValueKind, "aucune erreur");
        Check.Equal(planned.GetProperty("plan").GetProperty("id").GetString(), receipt.GetProperty("plan").GetProperty("id").GetString(), "le plan exécuté");
        string[] details = [.. receipt.GetProperty("details").EnumerateArray().Select(d => d.GetProperty("label").GetString()!)];
        Check.True(details.SequenceEqual(["Préconditions", "Envoi", "Relecture"]), "détails dans l’ordre : " + string.Join(", ", details));

        // The overlay: every read sees the write, the generated world does not change.
        var after = Camille(bridge);
        Check.Equal(0L, after.LockoutTime, "lockoutTime remis à zéro");
        Check.False(AdValues.HasFlag(after.ComputedAccountControl ?? 0, AdValues.LockedOut), "plus de verrouillage calculé");
        Check.Equal(0, after.BadPasswordCount, "essais erronés remis à zéro");
        Check.True(after.UsnChanged > camille.UsnChanged, "numéro de mise à jour avancé");
        Check.True(bridge.Source.World.Directory.Users.Single(u => u.ObjectGuid == camille.ObjectGuid).LockoutTime > 0, "monde généré inchangé");
        Check.Equal(fingerprint, bridge.Source.World.ComputeFingerprint(), "empreinte du monde inchangée");
        Check.Equal(1L, bridge.Source.Overlay.Version, "une seule écriture dans la surcouche");
        Check.Equal(lockedBefore - 1, LockedAccounts(SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"))), "l’Accueil voit le déverrouillage");

        // Receipt written before sending, then completed and verified: three versions, the latest wins.
        Check.Equal(3, ((MemoryReceiptStore)bridge.Receipts).Appends, "trois versions du reçu");
        var stored = (await bridge.Receipts.ReadAllAsync(CancellationToken.None)).Receipts.Single();
        Check.Equal(3, stored.Version, "dernière version");
        Check.Equal(receipt.GetProperty("id").GetString(), stored.Id, "même reçu");

        // Stages pushed to the page, in order.
        string[] stages = [.. bridge.Events.Where(e => e.Operation == "write.execute:stage").Select(e => ((WriteStageEvent)e.Data!).Stage.ToString())];
        Check.True(stages.SequenceEqual(["Checking", "Sending", "Verifying"]), "étapes : " + string.Join(", ", stages));

        // Journal of the session (Accueil, « Dernières opérations »).
        // The startup notices of the local base (Synchronisation) arrive in the background: they are left aside.
        var line = bridge.Context.Journal.Snapshot().First(e => !e.Label.StartsWith("Base locale · ", StringComparison.Ordinal));
        Check.Contains("Déverrouillage du compte (simulation)", line.Label, "journal : opération simulée");
        Check.Contains("Camille Bernard · relecture conforme", line.Label, "journal : cible et relecture");
        Check.Equal(Tone.Ok, line.Tone, "journal : ton");

        // Opérations: list and detail.
        var list = SimulatedBridge.Json(await bridge.CallAsync("write.receipts.list"));
        Check.True(Names(list).SequenceEqual(["total", "pending", "unreadable", "truncated", "summary", "receipts"]), "forme de la liste");
        Check.Equal(1, list.GetProperty("total").GetInt32(), "un reçu");
        Check.Equal(0, list.GetProperty("pending").GetInt32(), "aucun à vérifier");
        Check.Contains("Aucune écriture à vérifier. Un reçu conservé", list.GetProperty("summary").GetString(), "phrase de la liste");
        var row = list.GetProperty("receipts").EnumerateArray().Single();
        Check.False(row.TryGetProperty("plan", out _), "une ligne ne porte pas le plan");
        var id = receipt.GetProperty("id").GetString()!;
        var detail = SimulatedBridge.Json(await bridge.CallAsync("write.receipts.get", Args(new { id })));
        Check.True(Names(detail).SequenceEqual(ReceiptFields), "détail : forme du reçu");
        Check.Equal("verified", detail.GetProperty("verification").GetString(), "détail vérifié");
    }

    [Test]
    public static async Task A_plan_runs_only_once_and_is_never_replayed()
    {
        var bridge = new SimulatedBridge();
        var planned = await PlanCamilleAsync(bridge);
        var first = await bridge.CallAsync("write.execute", Execute(planned));
        Check.Equal("result", first.Kind, "première exécution");
        var second = await bridge.CallAsync("write.execute", Execute(planned));
        Check.Equal(WriteErrors.TokenUsed, second.Error!.Code, "le même plan ne repart pas");
        Check.Equal(WriteErrors.TokenUsedMessage, second.Error!.Message, "message du contrat");
        Check.Equal(1L, bridge.Source.Overlay.Version, "une seule écriture");
        Check.Equal(3, ((MemoryReceiptStore)bridge.Receipts).Appends, "aucun nouveau reçu");
    }

    [Test]
    public static async Task An_expired_confirmation_sends_nothing()
    {
        var bridge = new SimulatedBridge();
        var planned = await PlanCamilleAsync(bridge);
        bridge.Clock.Advance(TimeSpan.FromMinutes(5));
        var refused = await bridge.CallAsync("write.execute", Execute(planned));
        Check.Equal(WriteErrors.TokenExpired, refused.Error!.Code, "plan de 5 minutes expiré");
        Check.Equal(0L, bridge.Source.Overlay.Version, "rien d’écrit");
        Check.Equal(0, ((MemoryReceiptStore)bridge.Receipts).Appends, "aucun reçu");

        var again = await PlanCamilleAsync(bridge);
        bridge.Clock.Advance(TimeSpan.FromSeconds(299));
        Check.Equal("result", (await bridge.CallAsync("write.execute", Execute(again))).Kind, "4 min 59 s : encore valable");
    }

    [Test]
    public static async Task A_wrong_token_is_refused_without_spending_the_plan()
    {
        var bridge = new SimulatedBridge();
        var planned = await PlanCamilleAsync(bridge);
        var planId = planned.GetProperty("plan").GetProperty("id").GetString();
        var wrong = await bridge.CallAsync("write.execute", Args(new { planId, token = new string('A', ConfirmationTokens.TokenLength) }));
        Check.Equal(WriteErrors.TokenInvalid, wrong.Error!.Code, "jeton d’un autre plan ou inventé");
        Check.Equal(0L, bridge.Source.Overlay.Version, "rien d’écrit");
        var malformed = await bridge.CallAsync("write.execute", Args(new { planId, token = "abc" }));
        Check.Equal(DomeniaErrors.ArgumentsInvalid, malformed.Error!.Code, "jeton mal formé : arguments refusés");
        Check.Equal("result", (await bridge.CallAsync("write.execute", Execute(planned))).Kind, "le bon jeton passe ensuite");
    }

    [Test]
    public static async Task Malformed_arguments_and_unknown_plans_are_refused_before_anything()
    {
        var bridge = new SimulatedBridge();
        var token = new string('a', ConfirmationTokens.TokenLength);
        var unknown = await bridge.CallAsync("write.execute", Args(new { planId = WritePlans.NewId(), token }));
        Check.Equal(WriteErrors.PlanUnknown, unknown.Error!.Code, "plan inconnu");
        foreach (var (args, why) in new[]
        {
            ("{}", "arguments vides"),
            ("[]", "pas un objet"),
            (Args(new { planId = "XYZ", token }), "identifiant de plan mal formé"),
            (Args(new { planId = WritePlans.NewId() }), "jeton absent"),
            (Args(new { planId = WritePlans.NewId(), token, typedName = 3 }), "nom saisi non texte"),
            (Args(new { planId = WritePlans.NewId(), token, typedName = new string('x', 257) }), "nom saisi trop long"),
            (Args(new { planId = WritePlans.NewId(), token, other = true }), "propriété en trop"),
        })
        {
            var refused = await bridge.CallAsync("write.execute", args);
            Check.Equal(DomeniaErrors.ArgumentsInvalid, refused.Error!.Code, why);
        }
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("write.receipts.get", Args(new { id = "x" }))).Error!.Code, "identifiant de reçu mal formé");
        Check.Equal(WriteErrors.ReceiptUnknown, (await bridge.CallAsync("write.receipts.get", Args(new { id = WritePlans.NewId() }))).Error!.Code, "reçu inconnu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("write.receipts.list", Args(new { id = "x" }))).Error!.Code, "liste sans argument");
        Check.Equal(0, ((MemoryReceiptStore)bridge.Receipts).Appends, "aucun reçu");
    }

    [Test]
    public static async Task Unlock_plan_refuses_what_is_not_a_locked_user()
    {
        var bridge = new SimulatedBridge();
        var free = bridge.Source.CurrentDirectory.Users.First(u => u.LockoutTime is null or 0);
        var notLocked = await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = free.DistinguishedName }));
        Check.Equal(WriteErrors.NothingToDo, notLocked.Error!.Code, "compte non verrouillé");
        Check.Equal(AccountUnlock.NotLockedMessage, notLocked.Error!.Message, "message");
        var computer = bridge.Source.CurrentDirectory.Computers[0];
        Check.Equal(WriteErrors.TargetUnknown, (await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = computer.DistinguishedName }))).Error!.Code, "un poste n’est pas un compte utilisateur");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = "pas un DN" }))).Error!.Code, "DN mal formé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("accounts.unlock.plan", "{}")).Error!.Code, "DN absent");
        // The DN is found whatever its case.
        var camille = Camille(bridge);
        Check.Equal("result", (await bridge.CallAsync("accounts.unlock.plan", Args(new { dn = camille.DistinguishedName.ToUpperInvariant() }))).Kind, "DN sans casse");
    }

    [Test]
    public static async Task A_second_plan_of_an_account_unlocked_meanwhile_writes_nothing()
    {
        var bridge = new SimulatedBridge();
        var first = await PlanCamilleAsync(bridge);
        var second = await PlanCamilleAsync(bridge);
        Check.Equal("result", (await bridge.CallAsync("write.execute", Execute(first))).Kind, "premier plan exécuté");
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(second)));
        Check.Equal("noChange", receipt.GetProperty("result").GetString(), "déjà déverrouillé : rien envoyé");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "relu déverrouillé");
        Check.Equal(1L, bridge.Source.Overlay.Version, "aucune seconde écriture");
    }

    [Test]
    public static async Task Unlock_plan_reads_the_controller_in_directory_mode_and_is_refused_without_executor()
    {
        var clock = TestClock.Fixed();
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal());
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(WriteOperations).Assembly]));
        Check.True(registry.TryGet("accounts.unlock.plan", out var plan), "plan déclaré");
        Check.Equal(OperationClass.NetworkRead, plan!.Class, "lecture du contrôleur en mode annuaire");
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Directory));
        await dispatcher.HandleAsync("""{"id":"p","op":"accounts.unlock.plan","args":{"dn":"CN=Camille Bernard,OU=Lyon,DC=cnamts,DC=local"}}""", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent[^1].Error!.Code, "aucun exécuteur tant que Domenia.Ad n’est pas branché");
        var execute = Args(new { id = "x", op = "write.execute", args = new { planId = WritePlans.NewId(), token = new string('a', ConfirmationTokens.TokenLength) } });
        await dispatcher.HandleAsync(execute, CancellationToken.None);
        Check.Equal(WriteErrors.PlanUnknown, sent[^1].Error!.Code, "admise en mode annuaire, mais aucun plan à exécuter");
    }

    // ---------------------------------------------------------------- the circuit, with an executor of the tests

    [Test]
    public static async Task A_typed_confirmation_is_checked_again_by_the_engine_and_spends_the_plan()
    {
        var (context, circuit, executor, _) = FakeCircuit();
        using var owned = context;
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(typed: true), CancellationToken.None);
        Check.True(planned.Plan.Confirmation.TypedNameRequired, "saisie exigée");
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(
            () => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, "Essai", null, CancellationToken.None), "casse différente");
        Check.Equal(WriteErrors.ConfirmationMismatch, refused.Code, "nom différent");
        var spent = await Check.ThrowsAsync<DomeniaOperationException>(
            () => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, "essai", null, CancellationToken.None), "plan dépensé");
        Check.Equal(WriteErrors.TokenUsed, spent.Code, "un refus dépense le plan (fail closed)");
        Check.Equal(0, executor.Checks + executor.Executes, "rien relu ni envoyé");

        var again = await circuit.PlanAsync(FakeWriteExecutor.Draft(typed: true), CancellationToken.None);
        var receipt = await circuit.ExecuteAsync(again.Plan.Id, again.Token, "essai", null, CancellationToken.None);
        Check.Equal(WriteResult.Applied, receipt.Result, "nom exact : exécuté");
        Check.Equal(1, executor.Executes, "envoyé une fois");
    }

    [Test]
    public static async Task Changed_preconditions_send_nothing_and_say_why()
    {
        var store = new MemoryReceiptStore();
        var (context, circuit, executor, _) = FakeCircuit(store);
        using var owned = context;
        executor.OnCheck = _ => WritePrecheck.Stale("La description a changé depuis le plan : rien n’a été envoyé.");
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(
            () => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None), "préconditions changées");
        Check.Equal(WriteErrors.Stale, refused.Code, "plan périmé");
        Check.Contains("rien n’a été envoyé", refused.Message, "raison de l’exécuteur");
        Check.Equal(0, executor.Executes, "rien envoyé");
        Check.Equal(0, store.Appends, "aucun reçu sans envoi");
        Check.Contains("Écriture non envoyée", context.Journal.Snapshot().First(e => !e.Label.StartsWith("Base locale · ", StringComparison.Ordinal)).Label, "journal");
    }

    [Test]
    public static async Task An_unknown_outcome_holds_every_new_write_until_a_re_read_settles_it()
    {
        var (context, circuit, executor, _) = FakeCircuit();
        using var owned = context;
        executor.OnExecute = _ => throw new InvalidOperationException("Connexion perdue (test).");
        executor.OnVerify = _ => new WriteVerification(VerificationState.Unknown, "Contrôleur injoignable.");
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        Check.Equal(WriteResult.Unknown, receipt.Result, "issue inconnue");
        Check.True(receipt.Pending, "à vérifier");
        Check.Equal(Tone.Warn, receipt.Tone, "ton");
        Check.Equal(WriteErrors.OutcomeUnknown, receipt.Error!.Code, "erreur gardée sur le reçu");
        Check.Equal(1, executor.Executes, "jamais renvoyée");

        var blocked = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "même cible");
        Check.Equal(WriteErrors.TargetPending, blocked.Code, "cible bloquée");
        // Domenia 1 Assert-WriteAllowed (OPE-025, OPE-026): a receipt to verify holds every new write back, not only its target.
        var other = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(FakeWriteExecutor.OtherGuid), CancellationToken.None), "autre cible");
        Check.Equal(WriteErrors.ReceiptsPending, other.Code, "toutes les nouvelles écritures sont bloquées");
        Check.Contains("Une opération reste à vérifier", other.Message, "message de Domenia 1");

        executor.OnVerify = _ => new WriteVerification(VerificationState.Verified, "Description relue conforme.");
        var settled = await circuit.VerifyAsync(receipt.Id, CancellationToken.None);
        Check.False(settled.Pending, "issue confirmée par la relecture");
        Check.Equal(WriteResult.Unknown, settled.Result, "le résultat reste celui de l’envoi");
        Check.Equal(VerificationState.Verified, settled.Verification, "vérifiée");
        Check.Equal(1, executor.Executes, "la relecture ne renvoie rien");
        Check.NotNull(await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "cible de nouveau libre");
        Check.NotNull(await circuit.PlanAsync(FakeWriteExecutor.Draft(FakeWriteExecutor.OtherGuid), CancellationToken.None), "les autres objets aussi");
    }

    [Test]
    public static async Task Without_a_durable_receipt_nothing_is_sent()
    {
        var store = new FailingReceiptStore(failFromVersion: 1);
        var (context, circuit, executor, _) = FakeCircuit(store);
        using var owned = context;
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(
            () => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None), "reçu impossible");
        Check.Equal(WriteErrors.ReceiptUnavailable, refused.Code, "reçu indispensable");
        Check.Equal(1, executor.Checks, "préconditions relues");
        Check.Equal(0, executor.Executes, "rien envoyé sans reçu");

        var unreadable = new FailingReceiptStore(failFromVersion: 1, failReads: true);
        var (context2, circuit2, _, _) = FakeCircuit(unreadable);
        using var owned2 = context2;
        var noPlan = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit2.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "reçus illisibles");
        Check.Equal(WriteErrors.ReceiptUnavailable, noPlan.Code, "aucun plan tant que les reçus sont illisibles");
        Check.Equal(WriteErrors.ReceiptsUnreadableMessage, noPlan.Message, "message");
    }

    [Test]
    public static async Task A_later_version_refused_by_the_disk_holds_for_the_session_and_is_said()
    {
        var store = new FailingReceiptStore(failFromVersion: 2);
        var (context, circuit, _, _) = FakeCircuit(store);
        using var owned = context;
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        Check.Equal(WriteResult.Applied, receipt.Result, "écriture faite");
        Check.Equal(1, store.Appends, "seule la version 1 est sur le disque");
        var list = await circuit.ListAsync(CancellationToken.None);
        Check.Equal(VerificationState.Verified, list.Receipts.Single().Verification, "la session garde la dernière version");
        Check.True(context.Journal.Snapshot().Any(e => e.Label.Contains("Reçu d’écriture non enregistré sur le disque", StringComparison.Ordinal)), "le journal le dit");
    }

    [Test]
    public static async Task Refused_writes_and_double_clicks_never_run_twice()
    {
        var (context, circuit, executor, _) = FakeCircuit();
        using var owned = context;
        executor.OnExecute = _ => throw new DomeniaOperationException("write.accessDenied", "Accès refusé par le contrôleur : rien n’a été modifié.");
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var first = circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        var second = circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        var outcomes = new List<string>();
        foreach (var call in new[] { first, second })
        {
            try
            {
                var receipt = await call;
                outcomes.Add(receipt.Result.ToString());
                Check.Equal("write.accessDenied", receipt.Error!.Code, "refus gardé sur le reçu");
                Check.False(receipt.Pending, "un refus n’est pas incertain");
            }
            catch (DomeniaOperationException ex)
            {
                outcomes.Add(ex.Code);
            }
        }
        Check.True(outcomes.Order(StringComparer.Ordinal).SequenceEqual(["NotApplied", WriteErrors.TokenUsed]), "un seul envoi : " + string.Join(", ", outcomes));
        Check.Equal(1, executor.Executes, "envoyé une fois");
    }

    [Test]
    public static async Task Tokens_and_directory_data_never_reach_receipts_nor_the_technical_journal()
    {
        var bridge = new SimulatedBridge();
        var planned = await PlanCamilleAsync(bridge);
        var token = planned.GetProperty("token").GetString()!;
        await bridge.CallAsync("write.execute", Execute(planned));
        var stored = (await bridge.Receipts.ReadAllAsync(CancellationToken.None)).Receipts.Single();
        var text = JsonSerializer.Serialize(stored, BridgeJson.Options) + JsonSerializer.Serialize(SimulatedBridge.Json(await bridge.CallAsync("write.receipts.list")));
        Check.False(text.Contains(token, StringComparison.Ordinal), "le jeton n’est dans aucun reçu");
        var camille = Camille(bridge);
        foreach (var line in bridge.Log.Lines)
        {
            Check.False(line.Contains(token, StringComparison.Ordinal), "jeton absent du journal technique");
            Check.False(line.Contains(camille.DistinguishedName, StringComparison.OrdinalIgnoreCase), "DN absent du journal technique");
            Check.False(line.Contains("Camille", StringComparison.Ordinal), "nom absent du journal technique");
        }
    }

    [Test]
    public static async Task The_overlay_lives_in_memory_only()
    {
        var bridge = new SimulatedBridge();
        await bridge.CallAsync("write.execute", Execute(await PlanCamilleAsync(bridge)));
        Check.Equal(0L, Camille(bridge).LockoutTime, "déverrouillée dans cette session");
        var children = await bridge.CallAsync("directory.ou.children", """{"dn":null}""");
        Check.Equal("result", children.Kind, "l’arborescence reste lisible après une écriture");
        var fresh = new SimulatedBridge();
        Check.True(Camille(fresh).LockoutTime > 0, "une nouvelle session repart de l’annuaire généré");
        Check.Equal(0L, fresh.Source.Overlay.Version, "surcouche vide");
    }

    [Test]
    public static void Executors_follow_the_source_of_the_mode_and_read_nothing_at_discovery()
    {
        var simulated = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        var writers = WriteExecutors.Discover(simulated, [typeof(SimulatedDirectorySource).Assembly, typeof(WriteCircuitTests).Assembly]);
        Check.True(new[] { AccountUnlock.Kind, RelationChange.Kind, RelationSweepReset.Kind }.All(writers.Kinds.Contains), "écritures servies : " + string.Join(", ", writers.Kinds));
        // Every screen brings its own kinds (prefixed by the screen); the unlock of the platform stays served.
        Check.True(writers.Kinds.Contains(AccountUnlock.Kind), "écritures servies : " + string.Join(", ", writers.Kinds));
        Check.True(writers.Kinds.All(k => k.IndexOf('.', StringComparison.Ordinal) > 0), "types préfixés par leur écran : " + string.Join(", ", writers.Kinds));
        Check.True(writers.Kinds.Contains(PosteRemoteWrites.RestartKind) && writers.Kinds.Contains(PosteDirectoryWrites.MoveKind), "écritures du poste servies");
        Check.True(writers.Find<IAccountUnlockExecutor>() is SimulatedAccountUnlockExecutor, "déverrouillage simulé trouvé");
        Check.True(ReferenceEquals(writers.ForKind(AccountUnlock.Kind), writers.Find<IAccountUnlockExecutor>()), "même instance par type");
        var field = typeof(SimulatedDirectorySource).GetField("world", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        Check.False(((Lazy<SimulatedWorld>)field!.GetValue(simulated)!).IsValueCreated, "aucune génération à la découverte");

        var none = WriteExecutors.Discover(new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun"), [typeof(SimulatedDirectorySource).Assembly]);
        Check.True(none.Kinds.Count == 0, "aucune écriture sans Domenia.Ad");
        Check.Equal(DomeniaErrors.SourceUnavailable, Check.Throws<DomeniaOperationException>(() => none.Require<IAccountUnlockExecutor>(), "exécuteur exigé").Code, "source indisponible");
        Check.Throws<InvalidOperationException>(() => WriteExecutors.From([new FakeWriteExecutor(), new FakeWriteExecutor()]), "deux exécuteurs du même type");
    }

    // ---------------------------------------------------------------- admission

    [Test]
    public static async Task Guards_admit_the_write_circuit_and_no_other_write()
    {
        var ran = new List<string>();
        OperationDefinition Define(string name, OperationClass operationClass) =>
            new(name, operationClass, (_, _, _) =>
            {
                ran.Add(name);
                return Task.FromResult<object?>(null);
            }, "test", ServedInSimulation: true);
        var registry = new OperationRegistry([Define("write.execute", OperationClass.Write), Define("write.other", OperationClass.Write), Define("test.write", OperationClass.Write)]);
        foreach (var (mode, code) in new[] { (AppMode.Simulation, DomeniaErrors.SimulationReadOnly), (AppMode.Directory, DomeniaErrors.WriteUnavailable) })
        {
            ran.Clear();
            var sent = new List<BridgeResponse>();
            var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(mode));
            foreach (var name in new[] { "write.execute", "write.other", "test.write" })
            {
                await dispatcher.HandleAsync("{\"id\":\"x\",\"op\":\"" + name + "\",\"args\":{}}", CancellationToken.None);
            }
            Check.True(ran.SequenceEqual(["write.execute"]), "seule la porte du circuit est admise (" + mode + ") : " + string.Join(", ", ran));
            Check.Equal(code, sent[1].Error!.Code, "autre écriture refusée (" + mode + ")");
            Check.Equal(code, sent[2].Error!.Code, "écriture d’un autre écran refusée (" + mode + ")");
        }
        Check.False(AdmissionGuards.IsWriteCircuit(new OperationDefinition("write.execute", OperationClass.LocalRead, (_, _, _) => Task.FromResult<object?>(null), "t")), "le nom seul ne suffit pas");
    }

    // ---------------------------------------------------------------- pure pieces

    [Test]
    public static void The_fingerprint_covers_what_is_sent_and_binds_the_token()
    {
        var zone = TestClock.Paris;
        var plan = WritePlans.Seal(FakeWriteExecutor.Draft(), WritePlans.NewId(), @"TEST\adm", AppMode.Directory, TestClock.Reference, zone);
        Check.True(WritePlans.IsIntact(plan), "plan intact");
        Check.Equal("annuaire", plan.Mode, "mode annuaire");
        Check.False(plan.Simulated, "non simulé");
        Check.Equal(plan.Fingerprint, WritePlans.ComputeFingerprint(plan with { Summary = "Autre texte." }), "les textes ne comptent pas");
        foreach (var (changed, why) in new[]
        {
            (plan with { Target = plan.Target with { Dn = "CN=Autre,DC=test,DC=local" } }, "autre DN"),
            (plan with { Target = plan.Target with { ObjectGuid = FakeWriteExecutor.OtherGuid } }, "autre GUID"),
            (plan with { Controller = "DC2.test.local" }, "autre contrôleur"),
            (plan with { Operator = @"TEST\autre" }, "autre opérateur"),
            (plan with { Changes = [plan.Changes[0] with { AfterValue = "Autre" }] }, "autre valeur"),
            (plan with { ExpiresAt = plan.ExpiresAt.AddMinutes(10) }, "autre échéance"),
            (plan with { Confirmation = new WriteConfirmation(true, "autre", "x") }, "autre confirmation"),
        })
        {
            Check.False(WritePlans.ComputeFingerprint(changed) == plan.Fingerprint, "empreinte changée : " + why);
            Check.False(WritePlans.IsIntact(changed), "plan altéré : " + why);
        }
        var tokens = new ConfirmationTokens();
        var token = tokens.Issue(plan.Id, plan.Fingerprint, plan.ExpiresAt, TestClock.Reference);
        Check.Equal(TokenCheck.Valid, tokens.Check(plan.Id, token, plan.Fingerprint, TestClock.Reference), "jeton valable");
        Check.Equal(TokenCheck.Invalid, tokens.Check(plan.Id, token, WritePlans.ComputeFingerprint(plan with { Controller = "DC2" }), TestClock.Reference), "lié à l’empreinte");
        Check.Equal(TokenCheck.Expired, tokens.Check(plan.Id, token, plan.Fingerprint, plan.ExpiresAt), "expire avec le plan");
        Check.True(tokens.Consume(plan.Id), "premier usage");
        Check.False(tokens.Consume(plan.Id), "usage unique");
        Check.Equal(TokenCheck.Used, tokens.Check(plan.Id, token, plan.Fingerprint, TestClock.Reference), "déjà utilisé");
        Check.Equal(TokenCheck.Unknown, tokens.Check(WritePlans.NewId(), token, plan.Fingerprint, TestClock.Reference), "plan inconnu");
        Check.Throws<ArgumentException>(() => WritePlans.Seal(FakeWriteExecutor.Draft() with { Changes = [] }, WritePlans.NewId(), "x", AppMode.Directory, TestClock.Reference, zone), "plan vide refusé");
        Check.Throws<ArgumentException>(() => WritePlans.Seal(FakeWriteExecutor.Draft() with { Target = FakeWriteExecutor.Draft().Target with { ObjectGuid = "" } }, WritePlans.NewId(), "x", AppMode.Directory, TestClock.Reference, zone), "cible sans GUID refusée");
        Check.Throws<ArgumentException>(() => WritePlans.Seal(FakeWriteExecutor.Draft() with { Kind = "Ecrire" }, WritePlans.NewId(), "x", AppMode.Directory, TestClock.Reference, zone), "type mal formé refusé");
    }

    [Test]
    public static void Receipts_say_result_and_re_read_in_plain_words()
    {
        var plan = WritePlans.Seal(FakeWriteExecutor.Draft(), WritePlans.NewId(), @"TEST\adm", AppMode.Simulation, TestClock.Reference, TestClock.Paris);
        var sent = WriteReceipts.Sent(plan, WritePlans.NewId(), TestClock.Reference, new ReceiptDetail("Préconditions", "Relu."));
        Check.True(WriteReceipts.IsPending(sent), "envoyée sans suite : à vérifier");
        Check.Equal("Relecture en attente", WriteReceipts.VerificationLabel(sent.Result, sent.Verification), "relecture en attente");
        Check.Contains("bloquées", WriteReceipts.SummaryOf(sent), "bloque sa cible");
        var cases = new (WriteResult Result, VerificationState State, Tone Tone, bool Pending)[]
        {
            (WriteResult.Applied, VerificationState.Verified, Tone.Ok, false),
            (WriteResult.Applied, VerificationState.Mismatch, Tone.Alert, false),
            (WriteResult.Applied, VerificationState.Unknown, Tone.Warn, false),
            (WriteResult.NoChange, VerificationState.Verified, Tone.Ok, false),
            (WriteResult.NotApplied, VerificationState.Mismatch, Tone.Alert, false),
            (WriteResult.Unknown, VerificationState.Unknown, Tone.Warn, true),
            (WriteResult.Unknown, VerificationState.Verified, Tone.Ok, false),
            (WriteResult.Unknown, VerificationState.Mismatch, Tone.Info, false),
            (WriteResult.Sent, VerificationState.Mismatch, Tone.Info, false),
        };
        foreach (var (result, state, tone, pending) in cases)
        {
            var receipt = sent with { Result = result, Verification = state };
            Check.Equal(tone, WriteReceipts.ToneOf(receipt), $"ton {result}/{state}");
            Check.Equal(pending, WriteReceipts.IsPending(receipt), $"à vérifier {result}/{state}");
            Check.False(string.IsNullOrWhiteSpace(WriteReceipts.SummaryOf(receipt)), $"phrase {result}/{state}");
        }
        Check.Equal("Appliquée (simulation)", WriteReceipts.ResultLabel(WriteResult.Applied, simulated: true), "simulée");
        Check.Equal("Appliquée", WriteReceipts.ResultLabel(WriteResult.Applied, simulated: false), "réelle");
        Check.Contains("Aucun reçu d’écriture.", WriteReceipts.ListSummary(0, 0, 0), "aucun reçu");
        Check.Contains("2 opérations restent à vérifier", WriteReceipts.ListSummary(5, 2, 0), "à vérifier");
        Check.Contains("les nouvelles écritures sont bloquées", WriteReceipts.ListSummary(5, 2, 0), "toutes les écritures (Domenia 1)");
        Check.Contains("Un enregistrement illisible ignoré.", WriteReceipts.ListSummary(1, 0, 1), "illisible");
        var list = WriteReceipts.List([sent with { Result = WriteResult.Applied, Verification = VerificationState.Verified, At = TestClock.Reference.AddMinutes(5) }, sent with { Id = WritePlans.NewId() }], 0);
        Check.True(list.Receipts[0].Pending, "les reçus à vérifier d’abord");
        Check.Equal(1, list.Pending, "un à vérifier");
    }
}
