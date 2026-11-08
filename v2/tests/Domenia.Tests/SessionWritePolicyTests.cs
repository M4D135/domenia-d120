using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class SessionWritePolicyTests
{
    [Test]
    public static async Task A_disconnected_real_session_cannot_prepare_or_execute_a_write()
    {
        var clock = TestClock.Fixed();
        var source = new SessionSource(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock));
        var executor = new FakeWriteExecutor(); var receipts = new MemoryReceiptStore();
        using var context = new EngineContext(SimulatedBridge.Decision with { Mode = AppMode.Directory }, source, new MemoryPreferenceStore(), clock,
            new RecordingJournal(), writers: WriteExecutors.From([new DirectoryMutationExecutor(executor)]), receipts: receipts);
        var circuit = WriteCircuit.From(context);
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "déconnecté");
        Check.Equal("write.sessionRequired", refused.Code, "aucun jeton disponible hors connexion");
        source.Connected = true;
        var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        Check.True((await source.GetSessionAsync(CancellationToken.None)).ReadOnly, "le plan n’ouvre pas de mode global");
        source.Connected = false;
        refused = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, CancellationToken.None), "session perdue depuis le plan");
        Check.Equal("write.sessionRequired", refused.Code, "précondition relue avant l’envoi");
        Check.Equal(0, executor.Checks + executor.Executes + receipts.Appends, "aucune cible lue, aucun reçu d’envoi, aucune mutation");
        source.Connected = true;
        refused = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, CancellationToken.None), "jeton refusé déjà dépensé");
        Check.Equal(WriteErrors.TokenUsed, refused.Code, "aucun rejeu après reconnexion");
    }

    [Test]
    public static async Task Losing_connection_during_the_precondition_check_sends_nothing()
    {
        var clock = TestClock.Fixed();
        var source = new SessionSource(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock)) { Connected = true };
        var executor = new FakeWriteExecutor(); var receipts = new MemoryReceiptStore();
        using var context = new EngineContext(SimulatedBridge.Decision with { Mode = AppMode.Directory }, source, new MemoryPreferenceStore(), clock,
            new RecordingJournal(), writers: WriteExecutors.From([new DirectoryMutationExecutor(executor)]), receipts: receipts);
        var circuit = WriteCircuit.From(context);
        var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        executor.OnCheck = _ => { source.Connected = false; return WritePrecheck.Valid("Objet inchangé"); };
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, CancellationToken.None), "session perdue pendant les préconditions");
        Check.Equal("write.sessionRequired", refused.Code, "connexion relue à la frontière d’envoi");
        Check.Equal(1, executor.Checks, "préconditions réellement exécutées");
        Check.Equal(0, executor.Executes + receipts.Appends, "aucun envoi malgré un objet inchangé");
    }

    [Test]
    public static async Task A_local_maintenance_plan_remains_available_without_a_directory_connection()
    {
        var clock = TestClock.Fixed();
        var source = new SessionSource(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock));
        var executor = new FakeWriteExecutor(); var receipts = new MemoryReceiptStore();
        using var context = new EngineContext(SimulatedBridge.Decision with { Mode = AppMode.Directory }, source, new MemoryPreferenceStore(), clock,
            new RecordingJournal(), writers: WriteExecutors.From([executor]), receipts: receipts);
        var circuit = WriteCircuit.From(context);
        var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        await circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, CancellationToken.None);
        Check.Equal(1, executor.Checks, "préconditions locales conservées");
        Check.Equal(1, executor.Executes, "opération locale confirmée malgré annuaire déconnecté");
        Check.Equal(1, executor.Verifies, "relecture locale effective");
        Check.True(receipts.Appends >= 3, "reçu avant action et vérification durable du circuit");
        Check.Equal(ConnectionState.Disconnected, (await source.GetSessionAsync(CancellationToken.None)).Connection, "aucune connexion AD induite");
    }

    [Test]
    public static async Task Session_policy_distinguishes_read_default_from_confirmed_operations_and_simulation()
    {
        var clock = TestClock.Fixed();
        var source = new SessionSource(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock));
        using var dashboard = new DashboardService(source, new OperationJournal(), clock);
        var disconnected = await dashboard.GetSessionInfoAsync(CancellationToken.None);
        Check.True(disconnected.ReadOnly, "lecture par défaut");
        Check.False(disconnected.WritePlanAvailable, "une session Windows n’est pas une connexion AD");
        Check.Equal("confirmationPerOperation", disconnected.WritePolicy, "aucun mode écriture global");
        source.Connected = true;
        var connected = await dashboard.GetSessionInfoAsync(CancellationToken.None);
        Check.True(connected.ReadOnly, "aucun passage en écriture à la connexion");
        Check.True(connected.WritePlanAvailable, "un plan peut être demandé, sans promettre des droits effectifs");
        var bridge = new SimulatedBridge();
        var simulation = SimulatedBridge.Json(await bridge.CallAsync("session.info"));
        Check.Equal("simulation", simulation.GetProperty("writePolicy").GetString(), "simulation explicitement isolée");
        Check.False(simulation.GetProperty("readOnly").GetBoolean(), "surcouche fictive conservée");
        var ready = await bridge.CallAsync("session.interfaceReady");
        Check.Equal("result", ready.Kind, "jalon local sans connexion ni données AD");
    }

    private sealed class DirectoryMutationExecutor(FakeWriteExecutor inner) : IWriteExecutor, IDirectoryMutationExecutor
    {
        public string Kind => inner.Kind;
        public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken token) => inner.CheckAsync(plan, token);
        public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken token) => inner.ExecuteAsync(plan, token);
        public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken token) => inner.VerifyAsync(plan, token);
    }

    private sealed class SessionSource(IDirectorySource inner) : IDirectorySource
    {
        internal bool Connected { get; set; }
        public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;
        public async Task<SessionSnapshot> GetSessionAsync(CancellationToken token) => (await inner.GetSessionAsync(token)) with
        { Connection = Connected ? ConnectionState.Connected : ConnectionState.Disconnected, ReadOnly = true };
        public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => inner.ReadLocalAsync(token);
        public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token) => throw new InvalidOperationException("aucun réseau attendu");
    }
}
