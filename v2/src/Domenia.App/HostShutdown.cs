using System.Diagnostics;

namespace Domenia.App;

/// <summary>One host wait budget, independent of cooperative cancellation. The owner retains every resource until
/// real completion; reaching the deadline only ends the UI's wait, never a worker's lifetime.</summary>
internal sealed class HostShutdown(TimeSpan budget)
{
    public static readonly TimeSpan DrainBudget = TimeSpan.FromSeconds(3);
    private readonly long started = Stopwatch.GetTimestamp();
    public TimeSpan Remaining => TimeSpan.FromTicks(Math.Max(0, (budget - Stopwatch.GetElapsedTime(started)).Ticks));

    public bool Wait(Task completion, Action<Exception> error) => WaitAsync(completion, Remaining, error).GetAwaiter().GetResult();

    public static async Task<bool> WaitAsync(Task completion, TimeSpan limit, Action<Exception> error)
    {
        ArgumentNullException.ThrowIfNull(completion);
        try
        {
            if (completion.IsCompleted) await completion.ConfigureAwait(false);
            else await completion.WaitAsync(limit > TimeSpan.Zero ? limit : TimeSpan.Zero).ConfigureAwait(false);
            return true;
        }
        catch (TimeoutException)
        {
            // Completion can win just after WaitAsync's timer. Inspect the worker's actual outcome instead of
            // recording the wait timeout as a business failure, and always observe a late fault.
            if (completion.IsCompleted)
            {
                try { await completion.ConfigureAwait(false); }
                catch (Exception failure) { Report(error, failure); }
                return true;
            }
            _ = completion.ContinueWith(done => Observe(done, error), CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return false;
        }
        catch (Exception failure) { Report(error, failure); return true; }
    }

    /// <summary>Stop requests, handlers, detached finalization and native calls finish before persistence/disposal.
    /// No cancellation token is used to pretend those ownership barriers have completed.</summary>
    public static Task FinishAsync(Func<Task> stop, IEnumerable<Task> handlers, Func<Task> physicalCompletion,
        Func<Task> persist, Action release, Action<Exception> error) => Task.Run(async () =>
    {
        // Invoke stop off the UI thread: even a foreign cancellation callback can ignore its contract.
        try { await stop().ConfigureAwait(false); }
        catch (Exception failure) { Report(error, failure); }
        try { await Task.WhenAll(handlers).ConfigureAwait(false); }
        catch (Exception failure) { Report(error, failure); }
        await physicalCompletion().ConfigureAwait(false);
        try { await persist().ConfigureAwait(false); }
        catch (Exception failure) { Report(error, failure); }
        finally { release(); }
    });

    private static void Observe(Task task, Action<Exception> error)
    { if (task.Exception is { } failure) Report(error, failure); }
    private static void Report(Action<Exception> error, Exception failure)
    {
#pragma warning disable CA1031 // Diagnostics must not change ownership or the bounded wait.
        try { error(failure); } catch (Exception) { }
#pragma warning restore CA1031
    }
}
