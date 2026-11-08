using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class EngineSchedulingContractTests
{
    private static readonly JsonElement Empty = JsonSerializer.SerializeToElement(new { });
    private static QueueTiming Policy(int count) => QueueTiming.From(ConfigurationRules.Read(
        Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { Streaming = new { MaxUserProbes = count } })), "fixture"));
    private static OperationDefinition Read(OperationPriority priority) => new("fixture.read", OperationClass.NetworkRead,
        (_, _, _) => Task.FromResult<object?>(true), "Lecture") { Scheduling = new(priority, OperationProvider.Directory, []) };

    [Test]
    public static async Task Selection_limit_uses_effective_configuration_and_leaves_explicit_work_available()
    {
        Check.Equal(1, Policy(0).MaxUserProbes, "minimum"); Check.Equal(3, Policy(20).MaxUserProbes, "maximum");
        using var admission = new BridgeAdmission(TestClock.Fixed(), _ => Task.FromResult(new BridgeSessionStamp("session", "site")), Policy(1));
        Task<BridgeAdmission.Lease> Enter(string id, OperationDefinition definition) => admission.EnterAsync(id, definition, Empty, CancellationToken.None, () => { });
        using var first = await Enter("first", Read(OperationPriority.Selection));
        var waiting = Enter("waiting", Read(OperationPriority.Selection));
        try
        {
            Check.False(waiting.IsCompleted, "sélection suivante attend, sans envoi");
            using var explicitRead = await Enter("explicit", Read(OperationPriority.Explicit));
            Check.Equal(2, admission.Load.Network, "le geste explicite garde sa place");
            using var writing = await Enter("writing", new("fixture.write", OperationClass.Write, (_, _, _) => Task.FromResult<object?>(true), "Écriture"));
            first.Dispose(); await admission.RefreshAsync();
            Check.False(waiting.IsCompleted, "la sélection attend la fin de l’écriture même avec une place libre");
            writing.Dispose();
            using var next = await waiting.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { admission.CancelQueued("waiting"); }
    }

    [Test]
    public static async Task Real_tracking_announces_the_exact_stoppable_handler_and_excludes_background_from_foreground()
    {
        var (context, _, _, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var events = new List<BridgeResponse>();
        var definition = Read(OperationPriority.Explicit) with { Handler = async (_, _, token) =>
        { started.TrySetResult(); await Task.Delay(Timeout.Infinite, token); return null; } };
        var tracked = OperationTracking.Track(context, definition);
        var running = tracked.Handler(Empty, new BridgeContext(events.Add, "request", definition.Name), CancellationToken.None);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var notice = events.Single(e => e.Operation == "fixture.read:tracking");
        var value = JsonSerializer.SerializeToElement(notice.Data, BridgeJson.Options);
        var id = value.GetProperty("taskId").GetString()!;
        Check.True(value.GetProperty("cancellable").GetBoolean(), "annulation autorisée par le moteur");
        Check.Equal("explicit", value.GetProperty("priority").GetString(), "priorité du même contrat que l’admission");
        OperationActivity.From(context).Stop(id);
        await Check.ThrowsAsync<OperationCanceledException>(() => running, "l’identifiant publié arrête le vrai handler");
        events.Clear();
        var background = OperationTracking.Track(context, Read(OperationPriority.Background));
        await background.Handler(Empty, new BridgeContext(events.Add, "background", background.Name), CancellationToken.None);
        Check.Equal(0, events.Count, "le fond ne prend pas le bandeau");
        Check.False(background.Foreground, "métadonnée commune");
        Check.Equal(OperationPriority.Write, (definition with { Class = OperationClass.Write }).Priority, "une écriture ne peut être déclassée par la sélection");
    }

    [Test]
    public static async Task Same_login_reconnection_does_not_clear_uncertain_receipts_or_send_a_verification()
    {
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        executor.OnExecute = _ => throw new IOException("fixture");
        executor.OnVerify = _ => new WriteVerification(VerificationState.Unknown, "Non confirmé");
        var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var receipt = await circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, CancellationToken.None);
        Check.True(receipt.Pending, "écriture incertaine conservée");
        var calls = executor.Checks + executor.Executes + executor.Verifies;
        var source = (SimulatedDirectorySource)context.Directory;
        var user = source.CurrentDirectory.Users.Single(u => u.SamAccountName == "adm-j.martin");
        using var password = new System.Security.SecureString(); password.AppendChar('x');
        var login = await new SimulatedAccountsReader(source).OpenSessionAsync(new(source.CurrentDirectory.Domain.NetbiosName + "\\" + user.SamAccountName, CredentialRules.Directory, null), password, CancellationToken.None);
        Check.True(login.Answer.Success, "reconnexion explicite");
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "reçu toujours bloquant");
        Check.Equal(WriteErrors.TargetPending, refused.Code, "le changement d’epoch ne prouve pas le résultat");
        Check.Equal(calls, executor.Checks + executor.Executes + executor.Verifies, "aucune vérification ni réexécution automatique après login");
    }

    [Test]
    public static async Task Production_composition_declares_scheduling_before_tracking_captures_it()
    {
        var (context, _, _, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var registry = OperationModules.CreateRegistryFromDefinitions(context,
            [new OperationDefinition("search.revalidate", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(true), "Vérification", ServedInSimulation: true)], QueueTiming.Default);
        Check.True(registry.TryGet("search.revalidate", out var definition), "déclaration composée");
        Check.Equal(OperationPriority.Background, definition!.Priority, "priorité officielle");
        var events = new List<BridgeResponse>();
        await definition.Handler(Empty, new BridgeContext(events.Add, "request", definition.Name), CancellationToken.None);
        Check.Equal(0, events.Count, "le wrapper composé ne capture pas la priorité explicite antérieure à Declare");
        Check.Throws<ArgumentException>(() => new OperationRegistry([Read(OperationPriority.Explicit) with { Class = (OperationClass)999 }]),
            "classe inconnue refusée dès la composition");
    }

    [Test]
    public static async Task Shell_counter_uses_the_real_queue_and_keeps_tracking_capabilities_after_wrapping()
    {
        var (context, _, _, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var activity = OperationActivity.From(context);
        using var task = activity.Begin("fixture.read", TaskKind.NetworkRead, default, "other-request");
        var definition = new ShellOperations().CreateOperations(context).Single(d => d.Name == "shell.activity");
        var tracked = OperationTracking.Track(context, definition);
        var calls = 0;
        var bridge = new BridgeContext(_ => { }, "counter-request", definition.Name)
        { ReadQueue = () => { calls++; return new(2, 3, 1, 0, 32, []); } };
        var result = (ShellActivity)(await tracked.Handler(Empty, bridge, default))!;
        Check.Equal(1, calls, "capacité locale du vrai dispatcher transmise par le wrapper");
        Check.Equal(1, result.Tasks.Running, "le compteur ne se compte pas lui-même");
        Check.Equal(3, result.Tasks.Queued, "file réelle du pont, pas compteur historique du tableau de bord");
        Check.Equal(4 + result.Receipts.Pending, result.Active, "chaque tâche et reçu compte une seule fois");
        task.Complete(TaskOutcome.Succeeded, null, 0);
    }

    [Test]
    public static void Legacy_isolation_false_does_not_claim_to_disable_the_native_process_boundary()
    {
        var report = ConfigurationRules.Read(Encoding.UTF8.GetBytes("""{"Features":{"IsolatedReads":false}}"""), "fixture");
        var entry = report.Sections.SelectMany(s => s.Entries).Single(e => e.Key == "IsolatedReads");
        Check.Equal("true", entry.Value, "valeur réellement appliquée"); Check.Equal("byConstruction", entry.Use, "protection effective");
    }
}
