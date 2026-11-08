namespace Domenia.Core;

public sealed partial class AccountAccess
{
    private bool closing;
    private int disposed;
    private TaskCompletionSource? validationIdle;
    private readonly Dictionary<string, DateTimeOffset> dismissedRequests = new(StringComparer.Ordinal);
    private static readonly TimeSpan RefusalQuiet = TimeSpan.FromSeconds(60);

    public bool ValidationActive { get { lock (gate) { return running is not null; } } }

    /// <summary>Called by the host's shared pulse. Memory only; never obtains a credential, reads disk or contacts a domain.</summary>
    public void SweepLocal(SessionSnapshot? current = null)
    {
        lock (gate)
        {
            if (closing) return;
            if (current is not null)
            {
                if (lastSession is { } previous && (previous.Epoch != current.Epoch || SessionIdentity.Key(previous) != SessionIdentity.Key(current)))
                    NewEpochLocked();
                lastSession = current;
            }
            Sweep(clock.GetUtcNow());
            foreach (var key in dismissedRequests.Where(p => clock.GetUtcNow() >= p.Value).Select(p => p.Key).ToArray()) dismissedRequests.Remove(key);
        }
    }

    /// <summary>Fence new validations, request cancellation without running callbacks under a lock, await real return separately.</summary>
    public Task BeginClose()
    {
        CancellationTokenSource? cancel; Task idle;
        lock (gate)
        {
            cancel = running?.Cancel;
            idle = validationIdle?.Task ?? Task.CompletedTask;
            if (!closing) { closing = true; NewEpochLocked(); }
        }
        RequestCancellation(cancel);
        return idle;
    }

    private void RequireOpenLocked()
    {
        if (closing) throw new DomeniaOperationException(EpochChanged, "La fenêtre se ferme ; aucune validation ni lecture avec un nouveau compte.");
    }
    private void StartValidationLocked(Running value)
    {
        RequireOpenLocked();
        validationIdle = new(TaskCreationOptions.RunContinuationsAsynchronously);
        running = value; revision++;
    }
    private void FinishValidationLocked()
    {
        running = null; revision++;
        validationIdle?.TrySetResult();
    }
    private static void RequestCancellation(CancellationTokenSource? cancel)
    {
        if (cancel is null) return;
        try
        {
            _ = cancel.CancelAsync().ContinueWith(static task => { _ = task.Exception; }, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
        catch (ObjectDisposedException) { /* Validation returned between the snapshot and the cancellation request. */ }
    }
    private static string RequestIdentity(string scope, string? target)
    {
        var value = target?.Trim() ?? "";
        if (value.Contains('='))
        {
            try { value = DistinguishedName.Format(DistinguishedName.Parse(value)); }
            catch (FormatException) { /* Non-DN target keeps its bounded literal identity. */ }
        }
        return scope + "|" + value.ToUpperInvariant();
    }
    /// <summary>A new explicit user gesture may reopen an access previously dismissed; background reports cannot.</summary>
    public void RequestAccess(string scope, string operation, string? target)
    {
        lock (gate)
        {
            RequireOpenLocked();
            dismissedRequests.Remove(RequestIdentity(scope, target));
            AddRequestLocked(new(scope, operation, target, "unconfirmed", clock.GetUtcNow()), true);
        }
    }
    private void DismissLocked(AccessRequest request)
    {
        dismissedRequests[RequestIdentity(request.Scope, request.Target)] = clock.GetUtcNow() + RefusalQuiet;
        while (dismissedRequests.Count > RefusalCapacity) dismissedRequests.Remove(dismissedRequests.MinBy(p => p.Value).Key);
    }
}
