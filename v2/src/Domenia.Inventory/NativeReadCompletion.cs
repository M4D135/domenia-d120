namespace Domenia.Inventory;

internal enum NativeReadStop { None, Cancelled, Budget }

internal sealed record NativeReadCompletion<T>(T Value, NativeReadStop Stop, Exception? Failure = null);

/// <summary>A logical deadline requests cancellation but cannot release the caller's campaign or credentials.
/// The worker owns its native session; its task is the sole proof that disposal and physical work have ended.</summary>
internal static class NativeReadCompletion
{
    internal static async Task<NativeReadCompletion<T>> AwaitAsync<T>(Task<T> worker, CancellationTokenSource stop,
        TimeSpan budget, TimeProvider clock, CancellationToken token, Func<T> partial)
    {
        using var deadline = new CancellationTokenSource(budget, clock);
        using var waiting = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        try
        {
            var result = await worker.WaitAsync(waiting.Token).ConfigureAwait(false);
            if (!waiting.IsCancellationRequested) { return new(result, NativeReadStop.None); }
        }
        catch (Exception) when (waiting.IsCancellationRequested)
        {
            // Observe the real task below as well: cancellation can win a race with a late native fault.
        }

        var reason = token.IsCancellationRequested ? NativeReadStop.Cancelled : NativeReadStop.Budget;
        Exception? failure = null;
        try { await stop.CancelAsync().ConfigureAwait(false); }
        catch (Exception ex) { failure = ex; }
        try
        {
            // Deliberately no cancelled token or second timeout here. This is asynchronous physical ownership,
            // not a wait on the UI thread; a following campaign may start only after this task has settled.
            var value = await worker.ConfigureAwait(false);
            return new(value, token.IsCancellationRequested ? NativeReadStop.Cancelled : reason, failure);
        }
        catch (Exception ex)
        {
            // Completed measurements remain available, but a late fault or cancellation never becomes success.
            return new(partial(), token.IsCancellationRequested ? NativeReadStop.Cancelled : reason, ex);
        }
    }
}
