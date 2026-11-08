namespace Domenia.Core;

/// <summary>Observes an actual outstanding send. It never cancels it, releases a lease, changes its receipt or retries it.</summary>
public sealed class WriteWaitObserver : IDisposable
{
    private readonly Lock gate = new();
    private readonly Action<WriteStage> report;
    private readonly ITimer soft, hard;
    private bool ended;
    public WriteWaitObserver(TimeProvider clock, TimeSpan softDelay, TimeSpan hardDelay, Action<WriteStage> report)
    {
        ArgumentNullException.ThrowIfNull(clock); ArgumentNullException.ThrowIfNull(report);
        if (softDelay <= TimeSpan.Zero || hardDelay < softDelay) throw new ArgumentOutOfRangeException(nameof(softDelay));
        this.report = report;
        soft = clock.CreateTimer(_ => Publish(WriteStage.Slow), null, softDelay, Timeout.InfiniteTimeSpan);
        hard = clock.CreateTimer(_ => Publish(WriteStage.Prolonged), null, hardDelay, Timeout.InfiniteTimeSpan);
    }
    private void Publish(WriteStage stage)
    {
        lock (gate)
        {
            if (ended) return;
#pragma warning disable CA1031 // A UI/log observer cannot change an already sent write.
            try { report(stage); } catch (Exception) { }
#pragma warning restore CA1031
        }
    }
    public void Dispose() { lock (gate) { if (ended) return; ended = true; soft.Dispose(); hard.Dispose(); } }
}
