using Domenia.Core;

namespace Domenia.Bridge;

internal sealed partial class BridgeAdmission
{
    internal const int SharedGroupLimit = 32, SharedSubscriberLimit = 128, SharedPerGroupLimit = 64;
    private readonly Dictionary<SharedIdentity, SharedRead> shared = [];
    private int sharedSubscribers;
    private long sharedJoins;

    internal (int Groups, int Subscribers) SharedLoad
    { get { lock (gate) { return (shared.Count, sharedSubscribers); } } }

    // All membership, admission and closing transitions use the existing admission gate. There is no second queue,
    // credential capture, result cache or session qualification pool. Each waiting subscriber consumes one of the 32 places.
    private void AttachShared(Entry entry)
    {
        if (entry.SharedKey is not { } key) { return; }
        var identity = new SharedIdentity(key, entry.Stamp!);
        if (shared.TryGetValue(identity, out var group) && group.Closing)
        { throw Refusal("operation.sharedClosing", "La lecture précédente termine son arrêt ; aucun nouvel envoi automatique."); }
        if (sharedSubscribers >= SharedSubscriberLimit || group?.Members.Count >= SharedPerGroupLimit
            || group is null && shared.Count >= SharedGroupLimit)
        { throw Refusal("operation.sharedFull", "Limite des lectures partagées atteinte ; aucune attente supplémentaire."); }
        if (group is null)
        {
            group = new(identity, entry.At, entry.Sequence);
            shared.Add(identity, group);
        }
        else { sharedJoins++; } // An accepted attachment, not an inferred success or an estimate of LDAP/WQL calls avoided.
        if (entry.At < group.At) { group.At = entry.At; }
        group.Sequence = Math.Min(group.Sequence, entry.Sequence);
        group.Members.Add(entry); entry.Shared = group; sharedSubscribers++;
        if (group.Owner is not null)
        {
            // An already running group owns its physical/admission place. A new subscriber owns only its bounded request.
            RecordAdmission(entry);
            queued.Remove(entry); entry.Running = true;
            entry.Completion.TrySetResult(new Lease(this, entry));
            Arm();
        }
    }

    private void Promote(Entry chosen)
    {
        Start(chosen);
        if (chosen.Shared is not { } group)
        {
            queued.Remove(chosen);
            chosen.Completion.TrySetResult(new Lease(this, chosen));
            return;
        }
        group.Owner = chosen;
        foreach (var member in group.Members)
        {
            RecordAdmission(member);
            queued.Remove(member); member.Running = true;
            member.Completion.TrySetResult(new Lease(this, member));
        }
    }

    /// <summary>Claims exactly one execution, independently of the first subscriber. Its task is retained until actual
    /// handler completion, even when every subscriber stops waiting. The result belongs only to current subscribers.</summary>
    internal Task<object?> ShareAsync(Lease lease, Func<Entry, CancellationToken, Task<object?>> execute)
    {
        var group = lease.Entry.Shared ?? throw new InvalidOperationException("Shared admission required.");
        bool start;
        BridgeResponse? tracking;
        lock (gate)
        {
            // Promotion is not execution. A cancelled subscriber can reach this method before its dispatcher's finally
            // detaches it; its presence in Members is therefore insufficient authorization to launch the shared handler.
            if (!group.Executing && !group.Completed && (disposed || !group.Members.Any(e => Current(e) && !e.Token.IsCancellationRequested)))
            { RetireUnstarted(group); }
            start = !group.Executing && !group.Completed;
            if (start) { group.Executing = true; group.RequestTrace = OperationRequests.CurrentRequest; }
            tracking = !start && Current(lease.Entry) && !lease.Entry.Token.IsCancellationRequested ? group.Tracking : null;
        }
        // Late subscribers need the same task identity. No result or old progress is replayed, and no UI callback
        // runs under the admission gate. A racing initial publication may duplicate this closed notice; the client deduplicates it.
        if (tracking is not null && lease.Entry.Publish is { } target)
        {
#pragma warning disable CA1031 // A presentation observer must never replace the shared handler result.
            try { target(tracking with { Id = lease.Entry.Id }); }
            catch (Exception error) { try { activity?.Fault(error); } catch (Exception) { } }
#pragma warning restore CA1031
        }
        if (start) { _ = RunSharedAsync(group, execute); }
        return group.Result.Task;
    }

    private async Task RunSharedAsync(SharedRead group, Func<Entry, CancellationToken, Task<object?>> execute)
    {
        using var requestJob = OperationRequests.BeginJob(RequestJobKind.Other);
        object? result = null; Exception? failure = null;
        try { result = await execute(group.Owner!, group.Stop.Token).ConfigureAwait(false); }
#pragma warning disable CA1031 // Every subscriber receives the same expected or unexpected failure through the normal dispatcher boundary.
        catch (Exception ex) { failure = ex; }
#pragma warning restore CA1031
        Task cancellation;
        lock (gate)
        {
            group.Closing = true; group.Completed = true;
            cancellation = group.Cancellation;
        }
        // CancelAsync runs callbacks outside the admission gate. Even those callbacks must physically finish before the
        // group releases its place or its cancellation source; a slow native cancellation cannot create an uncounted worker.
        try { await cancellation.ConfigureAwait(false); }
#pragma warning disable CA1031 // Callback failures are observed and returned, never left as detached task faults.
        catch (Exception ex) { failure ??= ex; }
#pragma warning restore CA1031
        lock (gate)
        {
            shared.Remove(group.Identity);
            ReleaseRunning(group.Owner!, BridgeScheduling.Outcome(failure));
        }
        group.Stop.Dispose();
        if (failure is OperationCanceledException) { group.Result.TrySetCanceled(); }
        else if (failure is not null) { group.Result.TrySetException(failure); }
        else { group.Result.TrySetResult(result); }
        _ = RefreshAsync();
    }

    private void DetachShared(Entry entry)
    {
        if (entry.Shared is not { } group || !group.Members.Remove(entry)) { return; }
        sharedSubscribers--;
        if (group.Members.Count != 0 || group.Completed) { return; }
        if (group.Executing) { StopShared(group); return; }
        // The last subscriber can leave after promotion but before any dispatcher claims execution. There is then no
        // handler to cancel or await: return the one reserved place here, exactly once, and never invoke the delegate.
        RetireUnstarted(group);
    }

    private void RetireUnstarted(SharedRead group)
    {
        group.Completed = true; group.Closing = true;
        shared.Remove(group.Identity);
        if (group.Owner is not null) { ReleaseRunning(group.Owner, BridgeProviderOutcome.Cancelled); }
        // No execution has received this token, so there are no handler cancellation callbacks or native resources.
        group.Stop.Dispose(); group.Result.TrySetCanceled();
    }

    private static void StopShared(SharedRead group)
    {
        if (group.Closing || group.Completed) { return; }
        group.Closing = true;
        group.Cancellation = group.Stop.CancelAsync();
    }

    internal void PublishShared(Lease lease, BridgeResponse response, Action<BridgeResponse> publish)
    {
        Entry[] subscribers;
        lock (gate)
        {
            if (response.Kind == "event" && response.Operation == lease.Entry.Definition.Name + ":tracking"
                && response.Data is OperationTaskStarted)
                lease.Entry.Shared!.Tracking = response;
            subscribers = lease.Entry.Shared!.Members.Where(e => Current(e) && !e.Token.IsCancellationRequested).ToArray();
        }
        foreach (var subscriber in subscribers) { (subscriber.Publish ?? publish)(response with { Id = subscriber.Id }); }
    }

    internal sealed record SharedIdentity(string Request, BridgeSessionStamp Session);
    internal sealed class SharedRead(SharedIdentity identity, DateTimeOffset at, long sequence)
    {
        internal SharedIdentity Identity { get; } = identity;
        internal DateTimeOffset At = at;
        internal long Sequence = sequence;
        internal HashSet<Entry> Members { get; } = [];
        internal CancellationTokenSource Stop { get; } = new();
        internal TaskCompletionSource<object?> Result { get; } = CreateResult();
        internal Entry? Owner;
        internal ActivityRequest? RequestTrace;
        internal BridgeResponse? Tracking;
        internal bool Executing, Closing, Completed;
        internal Task Cancellation = Task.CompletedTask;

        private static TaskCompletionSource<object?> CreateResult()
        {
            var result = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
            _ = result.Task.ContinueWith(static task => { _ = task.Exception; }, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return result;
        }
    }
}
