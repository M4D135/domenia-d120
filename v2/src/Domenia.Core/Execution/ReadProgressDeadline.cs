namespace Domenia.Core;

public sealed record ReadProgressState(TimeSpan Elapsed, TimeSpan Idle, long Received, string? StopReason);

/// <summary>Read-only inactivity and absolute budgets. Only completed work advances the clock; invalid time never extends it.
/// Cancellation abandons the wait, not ownership of a native worker or its resources.</summary>
public sealed class ReadProgressDeadline : IDisposable
{
    private readonly Lock gate = new();
    private readonly TimeProvider clock;
    private readonly TimeSpan inactivity, total;
    private readonly DateTimeOffset started;
    private DateTimeOffset last, observed;
    private readonly CancellationTokenSource stop = new();
    private readonly ITimer timer;
    private long received;
    private string? reason;
    private bool disposed;

    public ReadProgressDeadline(TimeProvider clock, TimeSpan inactivity, TimeSpan total)
    {
        ArgumentNullException.ThrowIfNull(clock);
        if (inactivity <= TimeSpan.Zero || total < inactivity || total > TimeSpan.FromHours(1)) { throw new ArgumentOutOfRangeException(nameof(total)); }
        this.clock = clock; this.inactivity = inactivity; this.total = total;
        started = last = observed = clock.GetUtcNow();
        timer = clock.CreateTimer(_ => Poll(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    public CancellationToken Token => stop.Token;

    public void Progress(int completed)
    {
        if (completed <= 0) { throw new ArgumentOutOfRangeException(nameof(completed)); }
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var now = clock.GetUtcNow(); Evaluate(now);
            if (reason is null) { received = checked(received + completed); last = now; }
        }
        Poll();
        stop.Token.ThrowIfCancellationRequested();
    }

    public ReadProgressState Snapshot()
    {
        Poll();
        lock (gate) { return new(Positive(observed - started), Positive(observed - last), received, reason); }
    }

    private static TimeSpan Positive(TimeSpan value) => value < TimeSpan.Zero ? TimeSpan.Zero : value;
    private void Evaluate(DateTimeOffset now)
    {
        if (reason is not null) { return; }
        if (now < observed) { reason = "Horloge invalide"; return; }
        observed = now;
        if (now - started >= total) { reason = "Plafond total atteint"; }
        else if (now - last >= inactivity) { reason = "Délai sans nouvelle donnée atteint"; }
    }

    private void Poll()
    {
        lock (gate)
        {
            if (disposed) { return; }
            Evaluate(clock.GetUtcNow());
            if (reason is null || stop.IsCancellationRequested) { return; }
        }
        // Callbacks run outside the state lock; disposal may have won after the timer left that lock.
        try { stop.Cancel(); } catch (ObjectDisposedException) { }
    }

    public void Dispose()
    {
        lock (gate) { if (disposed) { return; } disposed = true; }
        timer.Dispose(); stop.Dispose();
    }
}
