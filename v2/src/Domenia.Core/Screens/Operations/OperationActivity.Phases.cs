namespace Domenia.Core;

/// <summary>Closed vocabulary; instrumentation never records target names, request arguments or credentials.</summary>
public enum OperationPhase { SharedRead, Collection, Validation, LocalRead }

public sealed partial class OperationActivity
{
    internal sealed class MeasuredPhase(double start)
    {
        public double Start { get; } = start;
        public double Total { get; set; }
        public int Completed { get; set; }
        public int Active { get; set; }
    }

    internal IDisposable Measure(Trace trace, OperationPhase phase)
    {
        if (!Enum.IsDefined(phase)) throw new ArgumentOutOfRangeException(nameof(phase));
        try
        {
            var started = clock.GetTimestamp();
            lock (gate)
            {
                if (!trace.Open) return EmptyPhase.Instance;
                if (!trace.MeasuredPhases.TryGetValue(phase, out var item))
                    trace.MeasuredPhases[phase] = item = new(clock.GetElapsedTime(trace.StartTimestamp, started).TotalMilliseconds);
                item.Active++;
            }
            return new PhaseLease(this, trace, phase, started, trace.Request?.MeasurePhase(phase));
        }
#pragma warning disable CA1031 // A diagnostic clock or sink cannot change the measured operation.
        catch (Exception error) { try { Fault(error); } catch (Exception) { } return EmptyPhase.Instance; }
#pragma warning restore CA1031
    }

    internal void Admission(Trace trace, double? milliseconds, bool promoted)
    {
        if (milliseconds is not double value || !double.IsFinite(value) || value < 0) return;
        lock (gate)
        {
            if (!trace.Open || trace.AdmissionWaitMs is not null) return;
            trace.AdmissionWaitMs = value; trace.AdmissionPromoted = promoted;
        }
        trace.Request?.Admission(value);
    }

    internal void Progress(Trace trace, long received)
    {
        if (received < 0) return;
        lock (gate)
        {
            if (!trace.Open) return;
            trace.Volume = Math.Max(trace.Volume, received);
            trace.VolumeComplete = false;
        }
    }

    private void FinishPhase(Trace trace, OperationPhase phase, long started)
    {
        var elapsed = clock.GetElapsedTime(started).TotalMilliseconds;
        lock (gate)
        {
            // Late native completion must not rewrite a finished request or contaminate its successor.
            if (!trace.Open || !trace.MeasuredPhases.TryGetValue(phase, out var item)) return;
            item.Active--; item.Completed++;
            item.Total += Math.Max(0, elapsed);
            trace.LastAt = clock.GetUtcNow();
        }
    }

    private static IEnumerable<TaskPhaseRow> PhaseRows(Trace trace, long now)
    {
        _ = now;
        foreach (var (phase, item) in trace.MeasuredPhases.OrderBy(p => p.Value.Start))
        {
            var label = phase switch
            {
                OperationPhase.SharedRead => "Lecture partagée", OperationPhase.Collection => "Collecte",
                OperationPhase.Validation => "Validation", _ => "Lecture locale",
            };
            var detail = item.Completed > 1 ? FrenchText.Integer(item.Completed) + " intervalles mesurés cumulés ; chevauchements possibles, ne pas additionner au total"
                : "Intervalle réel observé ; peut inclure une autre phase, ne pas additionner au total";
            if (item.Active > 0) detail += trace.Open ? " ; " + FrenchText.Integer(item.Active) + " en cours" : " ; intervalle interrompu non mesuré";
            yield return new("step", label, item.Start, item.Completed == 0 ? null : item.Total,
                item.Completed > 0 ? ActivityRules.Duration(item.Total) : trace.Open ? "en cours" : "non mesurée",
                item.Completed > 0, detail, null);
        }
    }

    private sealed class PhaseLease(OperationActivity owner, Trace trace, OperationPhase phase, long started, IDisposable? requestPhase) : IDisposable
    {
        private int ended;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref ended, 1) != 0) return;
            try { owner.FinishPhase(trace, phase, started); }
#pragma warning disable CA1031 // Completing a diagnostic interval cannot replace a result or its original exception.
            catch (Exception error) { try { owner.Fault(error); } catch (Exception) { } }
#pragma warning restore CA1031
            finally { requestPhase?.Dispose(); }
        }
    }
    private sealed class EmptyPhase : IDisposable
    {
        internal static readonly EmptyPhase Instance = new();
        public void Dispose() { }
    }
}

/// <summary>Request-owned observer propagated through async/native work; no instrumentation when no request is attached.</summary>
public static class OperationPhases
{
    private static readonly AsyncLocal<ActivityTask?> Current = new();
    public static IDisposable Enter(ActivityTask task)
    {
        var previous = Current.Value;
        Current.Value = task;
        return new Restore(previous);
    }
    public static IDisposable? Measure(OperationPhase phase) => Current.Value?.Measure(phase);
    public static void Progress(long received) => Current.Value?.Progress(received);
    private sealed class Restore(ActivityTask? previous) : IDisposable
    {
        private bool disposed;
        public void Dispose() { if (disposed) return; disposed = true; Current.Value = previous; }
    }
}
