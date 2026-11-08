using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class StorageBackupSchedulerRecoveryTests
{
    [Test]
    public static async Task Periodic_loop_survives_local_inspection_failure_and_retries_only_after_cooldown()
    {
        foreach (var failure in new Exception[] { new IOException("Lecture du disque refusée."), new JsonException("Marqueur tronqué.") })
        {
            var clock = new PulseClock(); var cache = new InspectionCache(failure);
            using var context = Context(clock, cache);
            using var source = (AdDirectorySource)context.Directory;
            await context.Preferences.SetAsync(StoragePolicyRules.PreferenceKey, StoragePolicyRules.ToJson(StoragePolicyRules.Default with { AutomaticBackup = true }), default);
            var scheduler = StorageBackupScheduler.From(context); scheduler.Start();
            await clock.Created.Task.WaitAsync(TimeSpan.FromSeconds(5));
            clock.Advance(TimeSpan.FromMinutes(1));
            await Until(scheduler, "failed");
            Check.Equal(1, cache.Reads, "exception réellement levée depuis LocalStoreAsync dans la boucle");
            Check.NotNull(scheduler.State.LastFailure, "échec visible dans les paramètres");
            Check.Null(scheduler.State.LastSuccess, "aucun succès fabriqué");
            clock.Advance(TimeSpan.FromMinutes(1));
            await Until(scheduler, "retryCooldown");
            Check.Equal(1, cache.Reads, "pas de nouvelle lecture pendant le délai");
            clock.Advance(TimeSpan.FromMinutes(14));
            await Until(scheduler, "unavailable");
            Check.Equal(2, cache.Reads, "même boucle encore vivante et nouvelle inspection réellement atteinte");
            Check.Equal(0, ((MemoryReceiptStore)context.Receipts).Appends, "aucune sauvegarde envoyée sans état disponible");
        }
    }

    [Test]
    public static async Task Inspection_cancellation_is_propagated_and_does_not_record_a_backup_failure()
    {
        var clock = new PulseClock(); var cache = new InspectionCache(new IOException("Non atteinte."));
        using var context = Context(clock, cache);
        using var source = (AdDirectorySource)context.Directory;
        await context.Preferences.SetAsync(StoragePolicyRules.PreferenceKey, StoragePolicyRules.ToJson(StoragePolicyRules.Default with { AutomaticBackup = true }), default);
        var scheduler = StorageBackupScheduler.From(context);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => scheduler.TickAsync(cancelled.Token), "annulation conservée");
        Check.Null(scheduler.State.LastFailure, "aucun échec imputé à une annulation");
        Check.Equal(0, cache.Reads, "lecture fournisseur non commencée");
        Check.Equal("failed", await scheduler.TickAsync(default), "le verrou ticking est libéré après annulation");
        Check.Equal(1, cache.Reads, "l’appel suivant atteint réellement le fournisseur");
    }

    private static EngineContext Context(TimeProvider clock, InspectionCache cache)
    {
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock,
            connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        return new(ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdSettingsReader).Assembly]),
            writers: WriteExecutors.Discover(source, [typeof(AdStorageBackupLocalExecutor).Assembly]), receipts: new MemoryReceiptStore());
    }

    private static async Task Until(StorageBackupScheduler scheduler, string expected)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (scheduler.State.LastReason != expected)
        {
            Check.False(timeout.IsCancellationRequested, "la boucle doit atteindre « " + expected + " » ; état observé : " + (scheduler.State.LastReason ?? "aucun tick"));
            await Task.Delay(10);
        }
    }

    private sealed class InspectionCache(Exception failure) : IDirectoryCache, ILocalStoreInspection
    {
        private int reads;
        internal int Reads => Volatile.Read(ref reads);
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult<DirectorySnapshot?>(null);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) => throw new InvalidOperationException("Aucune écriture de recette.");
        public Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Interlocked.Increment(ref reads) == 1) { return Task.FromException<LocalStoreSnapshot>(failure); }
            var snapshot = SimulatedLocalStore.For(new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed())).Snapshot();
            return Task.FromResult(snapshot with { Available = false });
        }
    }

    private sealed class PulseClock : TimeProvider
    {
        private readonly Lock gate = new();
        private DateTimeOffset now = Fixtures.Now;
        private PulseTimer? timer;
        internal TaskCompletionSource Created { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public override DateTimeOffset GetUtcNow() { lock (gate) { return now; } }
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var created = new PulseTimer(callback, state);
            // Reader discovery also creates credential-expiry timers. Their creation must not
            // release the test before the scheduler's own PeriodicTimer is actually installed.
            if (dueTime == StorageBackupScheduler.Period && period == StorageBackupScheduler.Period)
            { lock (gate) { timer = created; Created.TrySetResult(); } }
            return created;
        }
        internal void Advance(TimeSpan interval)
        {
            PulseTimer? current; lock (gate) { now += interval; current = timer; }
            current?.Fire();
        }
        private sealed class PulseTimer(TimerCallback callback, object? state) : ITimer
        {
            private int disposed;
            internal void Fire() { if (Volatile.Read(ref disposed) == 0) { callback(state); } }
            public bool Change(TimeSpan dueTime, TimeSpan period) => Volatile.Read(ref disposed) == 0;
            public void Dispose() => Interlocked.Exchange(ref disposed, 1);
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
