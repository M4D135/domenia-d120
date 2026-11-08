using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

public sealed record EngineSelfTestCheck(string Name, bool Passed);

/// <summary>Local, bounded engine diagnostics for the isolated command-line host. No provider or user handler runs.</summary>
public static class EngineSelfTest
{
    public static async Task<ImmutableArray<EngineSelfTestCheck>> RunAsync(CancellationToken token)
    {
        var results = ImmutableArray.CreateBuilder<EngineSelfTestCheck>();
        var empty = JsonSerializer.SerializeToElement(new { });
        static Task<object?> Answer(JsonElement _, BridgeContext __, CancellationToken ___) => Task.FromResult<object?>(true);
        var ordinary = new OperationDefinition("selftest.read", OperationClass.NetworkRead, Answer, "Lecture locale factice");
        var eligible = ordinary with { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, []) };
        using (var admission = new BridgeAdmission(new NoTimersClock(), _ => Task.FromResult(new BridgeSessionStamp("local-selftest", "local"))))
        {
            var held = new List<BridgeAdmission.Lease>();
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
            using var promotionStop = CancellationTokenSource.CreateLinkedTokenSource(token);
            Task<BridgeAdmission.Lease>? queued = null;
            try
            {
                for (var i = 0; i < BridgeAdmission.NetworkLimit; i++)
                    held.Add(await admission.EnterAsync("hold-" + i, ordinary, empty, token, static () => { }).ConfigureAwait(false));
                var noticed = false;
                queued = admission.EnterAsync("withdraw", eligible, empty, stop.Token, () => noticed = true);
                results.Add(new("scheduler.capacity", noticed && !queued.IsCompleted && admission.Load.Network == BridgeAdmission.NetworkLimit && admission.Load.Queued == 1));
                stop.Cancel();
                var cancelled = false;
                try { using var unexpected = await queued.ConfigureAwait(false); }
                catch (OperationCanceledException) { cancelled = true; }
                results.Add(new("scheduler.cancel-before-send", cancelled && admission.Load.Queued == 0 && admission.Load.Network == BridgeAdmission.NetworkLimit));
                queued = admission.EnterAsync("promote", eligible, empty, promotionStop.Token, static () => { });
                var waiting = !queued.IsCompleted && admission.Load.Queued == 1;
                held[0].Dispose(); held.RemoveAt(0);
                using (await queued.WaitAsync(TimeSpan.FromSeconds(5), token).ConfigureAwait(false))
                    results.Add(new("scheduler.promotion", waiting && admission.Load.Queued == 0 && admission.Load.Network == BridgeAdmission.NetworkLimit));
                queued = null;
            }
            finally
            {
                stop.Cancel();
                promotionStop.Cancel();
                foreach (var lease in held) lease.Dispose();
                if (queued is not null)
                {
                    try { using var remaining = await queued.ConfigureAwait(false); }
                    catch (OperationCanceledException) { }
                }
            }
            results.Add(new("scheduler.release", admission.Load.Network == 0 && admission.Load.Running == 0));
        }
        token.ThrowIfCancellationRequested();
        // This command runs before composition. Refuse to diagnose a shared process that already has real work.
        if (PhysicalWorkBudget.Snapshot().Outstanding != 0) throw new InvalidOperationException("Autotest réservé à un processus sans travail physique actif.");
        var physical = new List<IDisposable>();
        try
        {
            for (var i = 0; i < PhysicalWorkBudget.ReadLimit; i++) physical.Add(PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Other, PhysicalWorkPriority.Selection));
            var refused = false;
            try { using var unexpected = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Other, PhysicalWorkPriority.Selection); }
            catch (DomeniaOperationException error) when (error.Code == "operation.physicalBusy") { refused = true; }
            results.Add(new("physical.read-ceiling", refused && PhysicalWorkBudget.Snapshot().Outstanding == PhysicalWorkBudget.ReadLimit));
            using var explicitSlot = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Other, PhysicalWorkPriority.Explicit);
            using var writeSlot = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Other, PhysicalWorkPriority.Write);
            results.Add(new("physical.foreground-reservations", PhysicalWorkBudget.Snapshot().Outstanding == PhysicalWorkBudget.WriteLimit));
        }
        finally { foreach (var lease in physical) lease.Dispose(); }
        results.Add(new("physical.release", PhysicalWorkBudget.Snapshot().Outstanding == 0));
        results.Add(new("simulation.no-real-provider", AdmissionGuards.ReadOnlySimulation(ordinary) is not null));
        results.Add(new("write.closed-door", AdmissionGuards.ReadOnlyDirectory(ordinary with { Class = OperationClass.Write }) is not null));
        results.Add(new("registry.rejects-duplicates", RejectsDuplicate(ordinary)));
        var progressClock = new NoTimersClock();
        using (var progress = new ReadProgressDeadline(progressClock, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(20)))
        {
            progressClock.Advance(TimeSpan.FromSeconds(4)); progress.Progress(1);
            progressClock.Advance(TimeSpan.FromSeconds(4));
            results.Add(new("inactivity.completed-progress", progress.Snapshot().Received == 1 && !progress.Token.IsCancellationRequested));
            progressClock.Advance(TimeSpan.FromSeconds(1));
            results.Add(new("inactivity.exact-expiry", progress.Snapshot().StopReason is not null && progress.Token.IsCancellationRequested));
            var refused = false;
            try { progress.Progress(1); } catch (OperationCanceledException) { refused = true; }
            results.Add(new("inactivity.no-late-revival", refused && progress.Snapshot().Received == 1));
        }
        token.ThrowIfCancellationRequested();
        return results.ToImmutable();
    }

    private static bool RejectsDuplicate(OperationDefinition definition)
    {
        try { _ = new OperationRegistry([definition, definition]); return false; }
        catch (ArgumentException) { return true; }
    }

    // Admission timers are deliberately inert: cancellation and promotion are exercised explicitly, with no background loop.
    private sealed class NoTimersClock : TimeProvider
    {
        private long ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => ticks;
        public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch.AddTicks(ticks);
        internal void Advance(TimeSpan elapsed) => ticks += elapsed.Ticks;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) => new InertTimer();
        private sealed class InertTimer : ITimer
        {
            public bool Change(TimeSpan dueTime, TimeSpan period) => true;
            public void Dispose() { }
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }
}
