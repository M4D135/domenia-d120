using Domenia.Core;

namespace Domenia.Inventory;

/// <summary>One native worker's read deadline. UI notifications, cached data and request admission never credit it.
/// The existing total ceiling is unchanged; the D1 idle ceiling is 25 s for inventory and 20 s for probes alone.</summary>
internal sealed class NativeReadProgress : IDisposable
{
    private readonly ReadProgressDeadline deadline;
    private readonly CancellationTokenSource stopping;
    private readonly IDisposable? resource;
    private int closed;

    internal NativeReadProgress(TimeProvider clock, TimeSpan total, bool inventory, CancellationToken token)
    {
        var idle = TimeSpan.FromSeconds(inventory ? 25 : 20);
        deadline = new(clock, idle < total ? idle : total, total);
        stopping = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        Token = stopping.Token;
        resource = RuntimeResources.Register(RuntimeResourceKind.ReadTimer, RequestStopAsync);
    }

    private Task RequestStopAsync()
    {
        if (Volatile.Read(ref closed) != 0) return Task.CompletedTask;
        try { return stopping.CancelAsync(); }
        catch (ObjectDisposedException) when (Volatile.Read(ref closed) != 0) { return Task.CompletedTask; }
    }

    internal CancellationToken Token { get; }
    internal ReadProgressState Snapshot() => deadline.Snapshot();

    internal static string Stopped(NativeReadProgress? progress, string fallback)
    {
        if (progress is null) { return fallback + " Mesure de progression native non commencée."; }
        var state = progress.Snapshot();
        return (state.StopReason ?? fallback) + " · durée " + Seconds(state.Elapsed)
            + " s · sans source terminée depuis " + Seconds(state.Idle) + " s · "
            + state.Received.ToString(System.Globalization.CultureInfo.InvariantCulture)
            + " source(s) native(s) terminée(s). Résultats reçus conservés ; aucune relance automatique.";
    }

    private static string Seconds(TimeSpan value) => value.TotalSeconds.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>A completed source operation only. Cancellation is terminal: an in-flight callback can never revive the
    /// linked token, and callbacks observed after stop/disposal neither increment work nor extend inactivity.</summary>
    internal void Completed()
    {
        if (Volatile.Read(ref closed) != 0 || Token.IsCancellationRequested) { return; }
        try { deadline.Progress(1); }
        catch (OperationCanceledException) when (Token.IsCancellationRequested) { }
        catch (ObjectDisposedException) when (Volatile.Read(ref closed) != 0) { }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref closed, 1) != 0) { return; }
        _ = deadline.Snapshot(); // Freeze the final elapsed/idle values before releasing the timer.
        // This closes only the observation channel, never a physical lease. The worker disposes its CIM session first.
        stopping.Dispose(); deadline.Dispose(); resource?.Dispose();
    }
}
