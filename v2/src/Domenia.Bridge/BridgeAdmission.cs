using System.Diagnostics;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Bounded bridge requests, not a census of native workers. Only declared reads wait; running slots last until real completion.</summary>
internal sealed partial class BridgeAdmission : IDisposable
{
    internal const int NetworkLimit = 8, OrdinaryLimit = 48, ControlLimit = 4, QueueLimit = 32, ReservedForeground = 2, MaxProviderStates = 256;
    /// <summary>Hard bound on session captures actually still running: a provider that ignores cancellation can never grow orphan captures past one queue.</summary>
    internal const int MaxPendingQualifications = QueueLimit;
    internal static readonly TimeSpan Aging = TimeSpan.FromSeconds(30), Expiration = TimeSpan.FromSeconds(120);
    private readonly Lock gate = new();
    private readonly Dictionary<string, Entry> entries = new(StringComparer.Ordinal);
    private readonly List<Entry> queued = [];
    private readonly Dictionary<StateKey, ProviderState> states = [];
    private readonly int[] providerRunning = new int[6];
    private readonly TimeProvider clock;
    private readonly Func<CancellationToken, Task<BridgeSessionStamp>> captureSession;
    private readonly QueueTiming timing;
    private readonly OperationActivity? activity;
    private readonly CancellationTokenSource lifetime = new();
    private readonly ITimer timer;
    private long sequence;
    private int network, ordinary, control, background, selection, writes, refreshing, qualifying;
    private bool disposed;

    internal BridgeAdmission(TimeProvider clock, Func<CancellationToken, Task<BridgeSessionStamp>> captureSession, QueueTiming? timing = null, OperationActivity? activity = null)
    {
        this.clock = clock;
        this.captureSession = captureSession;
        this.timing = timing ?? QueueTiming.Default;
        this.activity = activity;
        timer = clock.CreateTimer(_ => { _ = RefreshAsync(); }, null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    internal (int Running, int Queued, int Network, int Control) Load
    { get { lock (gate) { return (ordinary, queued.Count, network, control); } } }

    internal BridgeQueueSnapshot Snapshot()
    {
        lock (gate)
        {
            RemoveExpired();
            return new(ordinary, queued.Count, network, control, timing.MaxQueued,
                queued.OrderBy(e => e.Sequence).Select(e => new BridgeQueuedRead(e.Id, e.Definition.Name,
                    e.Definition.Description.Length <= 160 ? e.Definition.Description : e.Definition.Description[..160],
                    e.At, Math.Clamp((int)(clock.GetUtcNow() - e.At).TotalSeconds, 0, timing.MaxQueueWaitSeconds))).ToArray())
                { SharedReadJoins = sharedJoins };
        }
    }

    internal Task<Lease> EnterAsync(string id, OperationDefinition definition, JsonElement arguments, CancellationToken token, Action queuedNotice, Action<BridgeResponse>? publish = null)
    {
        token.ThrowIfCancellationRequested();
        var eligible = BridgeScheduling.Eligible(definition);
        var target = eligible ? BridgeScheduling.Target(definition.Scheduling!, arguments) : "";
        Entry entry;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (entries.ContainsKey(id)) { throw Refusal("operation.duplicate", "Cette demande est déjà en cours ou en attente ; aucun second envoi."); }
            entry = new(id, definition, target, checked(++sequence), clock.GetUtcNow(), token)
            { EnqueuedTimestamp = clock.GetTimestamp(), SharedKey = BridgeScheduling.SharedKey(definition, arguments), IdentityArguments = definition.CaptureReadIdentity is null ? default : arguments.Clone(), Publish = publish };
            if (!eligible)
            {
                if (!Capacity(entry, false)) { throw Refusal("operation.busy", "Moteur saturé ; cette demande n’est pas mise en attente. Recommencez explicitement après libération."); }
                entries.Add(id, entry); Start(entry);
                return Task.FromResult(new Lease(this, entry));
            }
            if (queued.Count >= Math.Max(1, timing.MaxQueued) || timing.MaxQueued == 0 && !Capacity(entry, false))
            { throw Refusal("operation.queueFull", $"File d’attente à sa limite ({timing.MaxQueued} lectures) ; aucun envoi ni nouvelle tentative automatique."); }
            // Qualification itself is bounded by the queue. No worker or credential is acquired here.
            entries.Add(id, entry); queued.Add(entry); Arm();
        }
        return PrepareAndWaitAsync(entry, queuedNotice);
    }

    private async Task<Lease> PrepareAndWaitAsync(Entry entry, Action queuedNotice)
    {
        using var qualification = new CancellationTokenSource();
        using var registration = entry.Token.Register(() => CancelQueued(entry));
        bool started;
        lock (gate)
        {
            if (!Current(entry)) { started = false; }
            else if (qualifying >= MaxPendingQualifications)
            {
                entries.Remove(entry.Id); queued.Remove(entry); Arm();
                throw Refusal("operation.busy", "Trop de qualifications de session encore pendantes ; aucune nouvelle capture. Recommencez explicitement après libération.");
            }
            else { qualifying++; started = true; }
        }
        if (!started) { return await entry.Completion.Task.ConfigureAwait(false); }
        // The reservation is taken under the gate, the provider is invoked outside it: a slow or synchronously throwing
        // preamble can neither hold the gate that protects expiry and cancellation nor keep its own reservation.
        Task<BridgeSessionStamp> running;
        var qualificationJob = OperationRequests.BeginJob(RequestJobKind.Other);
        try { running = CaptureEntryAsync(entry, qualification.Token, initial: true); }
        catch { qualificationJob?.Dispose(); qualification.Cancel(); Abandon(entry, true); throw; }
        // The bound counts captures that are truly still running: a provider that ignores cancellation keeps its slot until it really finishes.
        _ = running.ContinueWith(task => { _ = task.Exception; lock (gate) { qualifying--; } qualificationJob?.Dispose(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        try
        {
            var awaited = running.WaitAsync(qualification.Token);
            _ = awaited.ContinueWith(static task => { _ = task.Exception; }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
            // Prefer the completion: a withdrawal (expiry, supersession, context change, cancellation) must surface its own reason, never the qualification's cancellation.
            if (await Task.WhenAny(awaited, entry.Completion.Task).ConfigureAwait(false) == entry.Completion.Task || entry.Completion.Task.IsCompleted)
            {
                qualification.Cancel();   // cleanly stop the qualification of a withdrawn entry; a provider may still ignore it
                return await entry.Completion.Task.ConfigureAwait(false);
            }
            var captured = await awaited.ConfigureAwait(false);
            ValidateStamp(captured);
            lock (gate)
            {
                if (Current(entry))
                {
                    entry.Stamp = captured;
                    AttachShared(entry);
                    if (entry.Definition.Scheduling!.ReplacementKey is { } replacement)
                    {
                        foreach (var previous in queued.Where(e => e != entry && e.Sequence < entry.Sequence && e.Stamp == captured
                            && e.Definition.Scheduling?.ReplacementKey == replacement).ToArray())
                        { Withdraw(previous, "operation.superseded", "Lecture remplacée dans la file avant envoi."); }
                    }
                }
            }
            // The shared refresh is started, never awaited to its end: a global capture that suspends must not hide a local
            // withdrawal. Its own errors are still observed by this caller, and its single-flight bound stays its own concern.
            var promotion = RefreshAsync();
            _ = promotion.ContinueWith(static task => { _ = task.Exception; }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
            if (await Task.WhenAny(promotion, entry.Completion.Task).ConfigureAwait(false) != entry.Completion.Task) { await promotion.ConfigureAwait(false); }
            if (!entry.Completion.Task.IsCompleted)
            {
                if (timing.MaxQueued == 0)
                {
                    lock (gate) if (Current(entry) && !entry.Running) Withdraw(entry, "operation.queueFull", "Attente désactivée ; aucun envoi. Recommencez explicitement après libération.");
                }
                else queuedNotice();
            }
            return await entry.Completion.Task.ConfigureAwait(false);
        }
        catch
        {
            qualification.Cancel();
            Abandon(entry, false);
            throw;
        }
    }

    /// <summary>Returns one qualification reservation exactly once and removes exactly its own queued entry. A capture still
    /// truly running keeps its slot, and a lease already handed out is disposed rather than a success being invented.</summary>
    private void Abandon(Entry entry, bool releaseQualification)
    {
        Lease? acquired = null;
        lock (gate)
        {
            if (releaseQualification) { qualifying--; }
            if (!entry.Running && Current(entry)) { entries.Remove(entry.Id); queued.Remove(entry); DetachShared(entry); Arm(); }
            else if (entry.Running && entry.Completion.Task.IsCompletedSuccessfully) { acquired = entry.Completion.Task.Result; }
        }
        acquired?.Dispose();
    }

    /// <summary>Local session qualification, not a memory-only read: the provider loads the source session and the effective
    /// working scope. One refresh at a time, at most 32 candidates and the configured promotion budget under the gate.
    /// Expiration and cancellation run on every call, before the single-flight guard, independently of suspended qualification.</summary>
    internal async Task RefreshAsync()
    {
        ExpireQueued();   // independent of the single-flight guard: a blocked provider cannot freeze the configured expiry
        if (Interlocked.Exchange(ref refreshing, 1) != 0) { return; }
        try
        {
            lock (gate)
            {
                if (disposed || queued.Count == 0 || qualifying >= MaxPendingQualifications) { return; }
                RemoveExpired();
                if (queued.Count == 0) { return; }
            }
            var current = await BeginCapture(lifetime.Token).WaitAsync(lifetime.Token).ConfigureAwait(false);
            ValidateStamp(current);
            lock (gate)
            {
                if (disposed) { return; }
                RemoveExpired();
                foreach (var stale in queued.Where(e => e.Stamp is not null && e.Stamp != current).ToArray())
                { Withdraw(stale, "operation.contextChanged", "Session, source ou identité modifiée : lecture retirée de la file avant envoi."); }
                foreach (var old in states.Where(p => p.Key.Identity != current.Identity && p.Value.Running == 0).Select(p => p.Key).ToArray())
                { states.Remove(old); }
                var started = Stopwatch.GetTimestamp();
                while (queued.Count > 0 && Stopwatch.GetElapsedTime(started) < timing.TickBudget)
                {
                    var ordered = queued.Where(e => e.Stamp is not null).OrderBy(e => Aged(e) ? -1 : (int)e.Priority).ThenBy(e => e.Shared?.Sequence ?? e.Sequence).ToArray();
                    Entry? chosen = null;
                    foreach (var candidate in ordered)
                    {
                        if (candidate.Token.IsCancellationRequested) { WithdrawCancelled(candidate); continue; }
                        if (!Capacity(candidate, Aged(candidate))) { continue; }
                        var refusal = ProviderAdmission(candidate, Aged(candidate));
                        if (refusal is { Code: "operation.providerBusy" }) { continue; }
                        if (refusal is not null) { Withdraw(candidate, refusal.Code, refusal.Message); continue; }
                        chosen = candidate; break;
                    }
                    if (chosen is null) { break; }
                    Promote(chosen);
                }
                Arm();
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (BridgeOperationException ex) when (ex.Code == "operation.qualificationBusy") { }
#pragma warning disable CA1031 // Failure to qualify withdraws bounded pending reads; no handler can start with an unknown context.
        catch (Exception)
#pragma warning restore CA1031
        {
            lock (gate)
            {
                foreach (var entry in queued.ToArray()) { Withdraw(entry, "operation.contextUnavailable", "Contexte de session indisponible : lecture retirée avant envoi."); }
                Arm();
            }
        }
        finally { Volatile.Write(ref refreshing, 0); }
    }

    /// <summary>Independent expiry and cancellation sweep, run on every tick before the single-flight guard and outside any suspended qualification.</summary>
    private void ExpireQueued()
    {
        lock (gate)
        {
            if (disposed || queued.Count == 0) { return; }
            RemoveExpired();
        }
    }

    internal Task RevalidateAsync(Lease lease, CancellationToken token) => RevalidateAsync(lease.Entry, token);

    internal async Task RevalidateAsync(Entry entry, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (entry.Stamp is not { } expected) { return; }
        var current = await BeginCapture(token, entry).WaitAsync(token).ConfigureAwait(false);
        ValidateStamp(current);
        if (current != expected) { throw Refusal("operation.contextChanged", "Session, source ou identité modifiée avant le départ réel ; aucun envoi."); }
        token.ThrowIfCancellationRequested();
    }

    private async Task<BridgeSessionStamp> CaptureEntryAsync(Entry entry, CancellationToken token, bool initial)
    {
        var stamp = await captureSession(token).ConfigureAwait(false);
        if (!entry.Definition.ShareRead || entry.Definition.CaptureReadIdentity is not { } capture || !initial && entry.ReadIdentity is null) { return stamp; }
        var observed = await capture(entry.IdentityArguments, token).ConfigureAwait(false);
        var after = await captureSession(token).ConfigureAwait(false);
        if (after != stamp)
        { throw Refusal("operation.contextChanged", "Session ou source modifiée pendant la qualification locale de cible ; aucun rattachement."); }
        token.ThrowIfCancellationRequested();
        if (observed is not null && (observed.Length != 64 || !observed.All(char.IsAsciiHexDigitLower)))
        { throw Refusal("operation.targetInvalid", "Identité locale de cible non qualifiée ; aucun rattachement."); }
        if (initial)
        {
            entry.ReadIdentity = observed;
            entry.SharedKey = observed is null || entry.SharedKey is null ? null : BridgeReadIdentity.Hash(entry.SharedKey + ":" + observed);
        }
        else if (observed != entry.ReadIdentity)
        { throw Refusal("operation.contextChanged", "Identité locale de la cible modifiée depuis la demande ; résultat partagé refusé."); }
        return stamp;
    }

    private Task<BridgeSessionStamp> BeginCapture(CancellationToken token, Entry? entry = null)
    {
        lock (gate)
        {
            if (qualifying >= MaxPendingQualifications)
            { throw Refusal("operation.qualificationBusy", "Qualifications de session encore actives à leur limite ; aucun nouvel envoi."); }
            qualifying++;
        }
        Task<BridgeSessionStamp> running;
        var qualificationJob = OperationRequests.BeginJob(RequestJobKind.Other);
        try { running = entry is null ? captureSession(token) : CaptureEntryAsync(entry, token, initial: false); }
        catch { lock (gate) { qualifying--; } qualificationJob?.Dispose(); throw; }
        // A cancelled wait is not a finished local capture. The same bound covers initial, refresh and execution-time
        // qualifications, including a provider that ignores cancellation after its caller stops waiting.
        _ = running.ContinueWith(task => { _ = task.Exception; lock (gate) { qualifying--; } qualificationJob?.Dispose(); }, CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        return running;
    }

    private static void ValidateStamp(BridgeSessionStamp stamp)
    {
        if (string.IsNullOrEmpty(stamp.Identity) || stamp.Identity.Length > 128 || stamp.Group is null || stamp.Group.Length > 128)
        { throw Refusal("operation.contextInvalid", "Identité de session non bornée."); }
    }

    private bool Capacity(Entry entry, bool aged)
    {
        if (entry.Control) { return control < ControlLimit; }
        if (entry.Priority == OperationPriority.Background && activity?.BackgroundAllowed == false) return false;
        if (entry.Priority is OperationPriority.Selection or OperationPriority.Background && writes > 0) { return false; }
        if (entry.Priority == OperationPriority.Selection && selection >= timing.MaxUserProbes) { return false; }
        if (ordinary >= (entry.Priority == OperationPriority.Write ? OrdinaryLimit + 1 : OrdinaryLimit)) { return false; }
        if (entry.Priority == OperationPriority.Background && ordinary >= OrdinaryLimit - timing.ReservedForeground && !aged) { return false; }
        return !entry.Network || network < (entry.Priority == OperationPriority.Background && !aged ? timing.MaxThreads - timing.ReservedForeground : timing.MaxThreads);
    }

    private bool Aged(Entry entry) => entry.Priority == OperationPriority.Background && background == 0 && clock.GetUtcNow() - entry.ScheduledAt >= timing.Aging;

    private BridgeError? ProviderAdmission(Entry entry, bool aged)
    {
        var provider = entry.Definition.Scheduling!.Provider;
        var budget = BridgeScheduling.Budget(provider);
        if (!TryState(new(provider, entry.Stamp!.Identity, entry.Target, false), out var target))
        { return new("operation.providerStateFull", "Budget des sources suivi à sa limite ; aucun nouvel état ni envoi."); }
        entry.TargetState = target;
        if (!TryState(new(provider, entry.Stamp.Identity, entry.Stamp.Group, true), out var group))
        { return new("operation.providerStateFull", "Budget des sources suivi à sa limite ; aucun nouvel état ni envoi."); }
        entry.GroupState = group;
        if (target.CredentialBlocked) { return new("operation.credentialsBlocked", "Compte rejeté pour cette source ; changement de compte ou reconnexion requis avant un nouvel envoi."); }
        if (entry.Priority != OperationPriority.Background) { return null; }
        var now = clock.GetUtcNow();
        if (target.PausedUntil > now || group.PausedUntil > now || target.Recovery > 0 && target.Running >= target.Recovery
            || group.Recovery > 0 && group.Running >= group.Recovery)
        { return new("operation.providerBusy", "Lectures de fond suspendues ou en reprise progressive pour cette source."); }
        var extra = aged && target.Recovery == 0 && group.Recovery == 0 ? 1 : 0;
        return providerRunning[(int)provider] >= budget.Concurrent + extra || group.Running >= budget.PerGroup + extra
            ? new("operation.providerBusy", "Budget du fournisseur ou du site atteint ; lecture en attente.") : null;
    }

    private bool TryState(StateKey key, out ProviderState state)
    {
        if (states.TryGetValue(key, out state!)) { return true; }
        if (states.Count >= MaxProviderStates)
        {
            var removable = states.FirstOrDefault(p => p.Value.Running == 0 && p.Value.Failures == 0 && p.Value.Recovery == 0 && !p.Value.CredentialBlocked
                && !entries.Values.Any(e => ReferenceEquals(e.TargetState, p.Value) || ReferenceEquals(e.GroupState, p.Value)));
            if (removable.Value is null) { state = null!; return false; }
            states.Remove(removable.Key);
        }
        state = new(); states.Add(key, state); return true;
    }

    private void Start(Entry entry)
    {
        RecordAdmission(entry, Aged(entry));
        entry.Running = true; entry.Counted = true;
        if (entry.Control) { control++; return; }
        ordinary++;
        if (entry.Network) { network++; }
        if (entry.Priority == OperationPriority.Background) { background++; }
        if (entry.Priority == OperationPriority.Selection) { selection++; }
        if (entry.Priority == OperationPriority.Write) { writes++; }
        if (entry.TargetState is not null)
        {
            providerRunning[(int)entry.Definition.Scheduling!.Provider]++;
            entry.TargetState.Running++; entry.GroupState!.Running++;
        }
    }

    private void RecordAdmission(Entry entry, bool promoted = false)
    {
        if (entry.QueueWaitMs is not null) return;
        entry.QueueWaitMs = Math.Max(0, clock.GetElapsedTime(entry.EnqueuedTimestamp).TotalMilliseconds);
        entry.QueuePromoted = promoted;
        activity?.RecordQueueAdmission(entry.Priority switch
        {
            OperationPriority.Selection => CollectionQueueClass.Selection,
            OperationPriority.Background => CollectionQueueClass.Background,
            OperationPriority.Write => CollectionQueueClass.Write,
            _ => CollectionQueueClass.Explicit,
        }, entry.QueueWaitMs.Value, promoted);
    }

    private void Finish(Entry entry, BridgeProviderOutcome outcome)
    {
        lock (gate)
        {
            if (Current(entry)) { entries.Remove(entry.Id); }
            if (entry.Shared is not null) { DetachShared(entry); }
            else { ReleaseRunning(entry, outcome); }
        }
        _ = RefreshAsync();
    }

    private void ReleaseRunning(Entry entry, BridgeProviderOutcome outcome)
    {
        if (!entry.Counted) { return; }
        entry.Counted = false;
        if (entry.Control) { control--; return; }
        ordinary--;
        if (entry.Network) { network--; }
        if (entry.Priority == OperationPriority.Background) { background--; }
        if (entry.Priority == OperationPriority.Selection) { selection--; }
        if (entry.Priority == OperationPriority.Write) { writes--; }
        if (entry.TargetState is not { } target) { return; }
        var provider = entry.Definition.Scheduling!.Provider;
        providerRunning[(int)provider]--;
        target.Running--; entry.GroupState!.Running--;
        var budget = BridgeScheduling.Budget(provider);
        Outcome(target, outcome, budget, false); Outcome(entry.GroupState, outcome, budget, true);
    }

    private void Outcome(ProviderState state, BridgeProviderOutcome outcome, BridgeProviderBudget budget, bool group)
    {
        if (!group && outcome == BridgeProviderOutcome.CredentialRejected) { state.CredentialBlocked = true; return; }
        if (outcome == BridgeProviderOutcome.Success || group && outcome == BridgeProviderOutcome.AccessDenied)
        {
            state.Failures = 0; state.PausedUntil = DateTimeOffset.MinValue;
            if (state.Recovery > 0 && ++state.Recovery >= (group ? budget.PerGroup : budget.Concurrent)) { state.Recovery = 0; }
            return;
        }
        if (group ? outcome != BridgeProviderOutcome.Timeout || budget.GroupFailures == 0
            : outcome is not (BridgeProviderOutcome.Failure or BridgeProviderOutcome.Timeout)) { return; }
        state.Failures = Math.Min(100, state.Failures + 1);
        var threshold = group ? budget.GroupFailures : budget.Failures;
        if (state.Failures < threshold) { return; }
        var seconds = Math.Min(budget.MaxBackoffSeconds, budget.BackoffSeconds * (1 << Math.Min(6, state.Failures - threshold)));
        state.PausedUntil = clock.GetUtcNow().AddSeconds(seconds); state.Recovery = 1;
    }

    private void RemoveExpired()
    {
        foreach (var entry in queued.ToArray())
        {
            if (entry.Token.IsCancellationRequested) { WithdrawCancelled(entry); }
            else if (clock.GetUtcNow() - entry.At >= timing.Expiration)
            { Withdraw(entry, "operation.queueExpired", $"Retirée de la file avant envoi : attente de {timing.MaxQueueWaitSeconds} secondes atteinte."); }
        }
        Arm();
    }

    private void CancelQueued(Entry entry)
    {
        lock (gate) { if (!entry.Running && Current(entry)) { WithdrawCancelled(entry); Arm(); } }
        _ = RefreshAsync();
    }

    /// <summary>Bounded local withdrawal of one of this admission's own queued reads. True only for a removal before the real
    /// start; an entry that already started keeps its slot (its handler and token decide), so no success is invented here.</summary>
    internal bool CancelQueued(string id)
    {
        lock (gate)
        {
            if (!entries.TryGetValue(id, out var entry) || entry.Running || !queued.Contains(entry)) { return false; }
            WithdrawCancelled(entry); Arm();
        }
        _ = RefreshAsync();
        return true;
    }

    private void WithdrawCancelled(Entry entry)
    { queued.Remove(entry); entries.Remove(entry.Id); DetachShared(entry); entry.Completion.TrySetCanceled(entry.Token); }
    private void Withdraw(Entry entry, string code, string message)
    { queued.Remove(entry); entries.Remove(entry.Id); DetachShared(entry); entry.Completion.TrySetException(Refusal(code, message)); }
    private bool Current(Entry entry) => entries.TryGetValue(entry.Id, out var current) && ReferenceEquals(current, entry);
    private void Arm()
    {
        if (!disposed) { timer.Change(queued.Count == 0 ? Timeout.InfiniteTimeSpan : TimeSpan.FromMilliseconds(250),
            queued.Count == 0 ? Timeout.InfiniteTimeSpan : TimeSpan.FromMilliseconds(250)); }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) { return; }
            disposed = true;
            foreach (var entry in queued.ToArray()) { Withdraw(entry, "operation.cancelled", "Fenêtre fermée : lecture retirée de la file avant envoi."); }
            foreach (var group in shared.Values) { StopShared(group); }
        }
        lifetime.Cancel(); timer.Dispose(); lifetime.Dispose();
        // Running leases are released only by actual handler completion.
    }

    private static BridgeOperationException Refusal(string code, string message) => new(code, message);
    private sealed record StateKey(OperationProvider Provider, string Identity, string Target, bool Group);
    internal sealed class ProviderState
    {
        internal int Running, Failures, Recovery;
        internal bool CredentialBlocked;
        internal DateTimeOffset PausedUntil;
    }
    internal sealed class Entry(string id, OperationDefinition definition, string target, long sequence, DateTimeOffset at, CancellationToken token)
    {
        internal string Id { get; } = id;
        internal OperationDefinition Definition { get; } = definition;
        internal string Target { get; } = target;
        internal long Sequence { get; } = sequence;
        internal DateTimeOffset At { get; } = at;
        internal long EnqueuedTimestamp;
        internal double? QueueWaitMs;
        internal bool QueuePromoted;
        internal Action<BridgeResponse>? Publish;
        internal CancellationToken Token { get; } = token;
        internal TaskCompletionSource<Lease> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal BridgeSessionStamp? Stamp;
        internal JsonElement IdentityArguments;
        internal string? ReadIdentity;
        internal bool Running, Counted;
        internal string? SharedKey;
        internal SharedRead? Shared;
        internal DateTimeOffset ScheduledAt => Shared?.At ?? At;
        internal ProviderState? TargetState, GroupState;
        internal bool Control => Definition.Class == OperationClass.Local
            && (Definition.Name.EndsWith(".stop", StringComparison.Ordinal) || Definition.Name.EndsWith(".cancel", StringComparison.Ordinal)
                || Definition.Name == "operations.queue.read"); // bounded in-memory view stays reachable to identify a read to withdraw
        internal bool Network => Definition.Class == OperationClass.NetworkRead;
        internal OperationPriority Priority => Definition.Priority;
    }
    internal sealed class Lease(BridgeAdmission owner, Entry entry) : IDisposable
    {
        private BridgeAdmission? active = owner;
        internal Entry Entry { get; } = entry;
        private BridgeProviderOutcome outcome = BridgeProviderOutcome.Refused;
        internal void Complete(Exception? exception) => outcome = BridgeScheduling.Outcome(exception);
        public void Dispose() { Interlocked.Exchange(ref active, null)?.Finish(Entry, outcome); }
    }
}
