using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class RuntimeSecurityPolicyTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static void A_secret_has_one_successful_copy_and_a_real_bounded_owner_lifetime()
    {
        var clock = new Clock();
        var configuration = RuntimeConfigurationTests.Config("""{"Security":{"SecretMemorySeconds":30,"AutoClearSecretClipboardSeconds":7},"Features":{"SecretSingleCopy":false}}""");
        using var secret = SecretReading.FromPassword("TEST-PC", "test", "fictive-value".AsSpan(), "Fixture", clock.GetUtcNow());
        secret.ApplyPolicy(FicheSecurityPolicy.From(configuration.Fiche, AppMode.Directory), clock);
        Check.Equal(7, secret.ClipboardClearSeconds, "durée portée jusqu’au presse-papiers hôte");
        Check.Equal(0, secret.Extensions, "prolongation ne franchit pas la durée mémoire");
        var copies = 0;
        Check.False(secret.CopyOnce(_ => { copies++; return false; }), "échec presse-papiers ne consomme pas le droit de copie");
        Check.True(secret.CopyOnce(_ => { copies++; return true; }), "copie confirmée");
        Check.False(secret.CopyOnce(_ => { copies++; return true; }), "seconde copie refusée même si ancien commutateur false");
        Check.Equal(2, copies, "aucun second accès au presse-papiers après succès");
        clock.Advance(TimeSpan.FromSeconds(30));
        Check.Null(secret.Value, "propriétaire vidé à son échéance même sans fenêtre");
        Check.Throws<ObjectDisposedException>(() => secret.CopyText(), "contenu devenu indisponible");
    }

    [Test]
    public static async Task Both_write_alerts_leave_the_actual_send_occupied_and_its_receipt_unmodified_until_completion()
    {
        var clock = new Clock(); var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var executor = new HeldExecutor(); var receipts = new MemoryReceiptStore(); var stages = new List<WriteStage>();
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
            writers: WriteExecutors.From([executor]), receipts: receipts,
            configuration: RuntimeConfigurationTests.Config("""{"Async":{"WriteSoftTimeoutSeconds":10,"WriteHardTimeoutSeconds":30}}"""));
        var circuit = WriteCircuit.From(context);
        var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), None);
        var execution = circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, stage => stages.Add(stage), None);
        await executor.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            clock.Advance(TimeSpan.FromSeconds(10));
            Check.True(stages.Contains(WriteStage.Slow), "seuil doux réellement émis");
            clock.Advance(TimeSpan.FromSeconds(20));
            Check.True(stages.Contains(WriteStage.Prolonged), "seuil prolongé réellement émis");
            Check.False(execution.IsCompleted, "pas de faux résultat ou libération après délai");
            Check.True(circuit.InFlight, "canal d’écriture toujours occupé");
            Check.False(executor.Token.CanBeCanceled, "envoi déjà parti jamais annulé par les alertes");
            Check.Equal(WriteResult.Sent, (await receipts.ReadAllAsync(None)).Receipts.Single().Result, "reçu d’envoi conservé sans inventer l’issue");
            Check.Equal(1, executor.Executions, "aucun rejeu");
        }
        finally { executor.Release.TrySetResult(); }
        var result = await execution.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal(WriteResult.Applied, result.Result, "seule la réponse réelle conclut");
        Check.False(circuit.InFlight, "libération après retour réel");
        var count = stages.Count; clock.Advance(TimeSpan.FromHours(1));
        Check.Equal(count, stages.Count, "aucune alerte tardive après la clôture");
    }

    private sealed class HeldExecutor : IWriteExecutor
    {
        public string Kind => FakeWriteExecutor.FakeKind;
        internal readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Executions; internal CancellationToken Token;
        public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken token) => Task.FromResult(WritePrecheck.Valid("Relu"));
        public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken token)
        { Executions++; Token = token; Entered.TrySetResult(); await Release.Task; return new(WriteResult.Applied, "Confirmé"); }
        public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken token) => Task.FromResult(new WriteVerification(VerificationState.Verified, "Relu"));
    }

    internal sealed class Clock : TimeProvider
    {
        private readonly Lock gate = new(); private readonly List<Timer> timers = []; private long ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() { lock (gate) return ticks; }
        public override DateTimeOffset GetUtcNow() => TestClock.Reference + TimeSpan.FromTicks(GetTimestamp());
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        { var timer = new Timer(this, callback, state); lock (gate) { timers.Add(timer); timer.Change(dueTime, period); } return timer; }
        internal void Advance(TimeSpan by)
        { Timer[] copy; lock (gate) { ticks += by.Ticks; copy = [.. timers]; } foreach (var timer in copy) timer.Fire(); }
        private sealed class Timer(Clock clock, TimerCallback callback, object? state) : ITimer
        {
            private long due = long.MaxValue; private TimeSpan period; private bool disposed;
            public bool Change(TimeSpan delay, TimeSpan repeat)
            { lock (clock.gate) { if (disposed) return false; due = delay == Timeout.InfiniteTimeSpan ? long.MaxValue : clock.ticks + delay.Ticks; period = repeat; return true; } }
            internal void Fire()
            { lock (clock.gate) { if (disposed || due > clock.ticks) return; due = period > TimeSpan.Zero ? clock.ticks + period.Ticks : long.MaxValue; } callback(state); }
            public void Dispose() { lock (clock.gate) { disposed = true; due = long.MaxValue; } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
