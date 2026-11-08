using System.Net;
using System.Net.Sockets;
using Domenia.Core.Poste;

namespace Domenia.Core;

public enum AdaptiveReadOutcome { Success, Failure, Timeout, Neutral, Cancelled }
public sealed record AdaptiveReadLoad(string Group, int Active, int Limit, TimeSpan SuspendedFor, int RememberedHosts)
{
    public string State { get; init; } = "closed";
    public int Failures { get; init; }
}

/// <summary>Process-local feedback for completed native steps. Observed IPv4 /24 is a grouping hint only.
/// No DNS, retry, credential or stored work payload. Unknown addresses share a bounded group which never suspends.</summary>
public sealed class AdaptiveReadBudget
{
    public static AdaptiveReadBudget Shared { get; } = new(TimeProvider.System);
    // A failed or occupied WMI source must not prevent an independent ICMP observation.
    public static AdaptiveReadBudget Presence { get; } = new(TimeProvider.System, PhysicalWorkBudget.ReadLimit);
    public static AdaptiveReadBudget Cim { get; } = new(TimeProvider.System);
    public const int MaximumHosts = 20_000, MaximumGroups = 4096, InitialLimit = 4, MaximumLimit = 32;
    private readonly TimeProvider clock;
    private readonly int maximum;
    private readonly Lock gate = new();
    private readonly Dictionary<string, LinkedListNode<Address>> addresses = new(StringComparer.OrdinalIgnoreCase);
    private readonly LinkedList<Address> addressOrder = new();
    private readonly Dictionary<string, Group> groups = new(StringComparer.OrdinalIgnoreCase);
    private long sequence;
    private TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private sealed record Address(string Host, string Subnet);
    internal sealed class Group(int maximum, bool unknown)
    {
        internal int Active, Limit = maximum, Successes, Failures, Opens, Samples;
        internal int SuspensionSeconds;
        internal long SuspendedAt, LastDecrease, Used;
        internal bool Decreased, Open;
        internal readonly bool Unknown = unknown;
        internal double BaselineMs;
        internal Lease? Trial;
    }

    public AdaptiveReadBudget(TimeProvider clock, int maximum = InitialLimit)
    {
        ArgumentNullException.ThrowIfNull(clock);
        if (maximum is < 1 or > MaximumLimit) throw new ArgumentOutOfRangeException(nameof(maximum));
        this.clock = clock; this.maximum = maximum;
    }

    public void ObserveAddress(string host, IPAddress? address)
    {
        var subnet = Subnet(address);
        if (subnet is null) return;
        var name = Name(host);
        lock (gate)
        {
            if (addresses.TryGetValue(name, out var existing))
            {
                existing.Value = new(name, subnet);
                addressOrder.Remove(existing); addressOrder.AddLast(existing);
            }
            else
            {
                if (addresses.Count >= MaximumHosts && addressOrder.First is { } oldest)
                { addresses.Remove(oldest.Value.Host); addressOrder.RemoveFirst(); }
                addresses.Add(name, addressOrder.AddLast(new Address(name, subnet)));
            }
        }
    }

    public Lease Acquire(string? host, bool controller = false)
    {
        lock (gate)
        {
            var key = Key(host, controller);
            if (!groups.TryGetValue(key, out var group))
            {
                if (groups.Count >= MaximumGroups)
                {
                    // Never forget an active or suspended source to admit another name.
                    var unused = groups.Where(p => p.Value.Active == 0 && !p.Value.Open).OrderBy(p => p.Value.Used).FirstOrDefault();
                    if (unused.Key is null) throw Busy("Mémoire des budgets de lecture occupée ; aucun nouvel envoi.");
                    groups.Remove(unused.Key);
                }
                group = new(maximum, key.EndsWith('?')); groups.Add(key, group);
            }
            group.Used = ++sequence;
            if (Remaining(group) > TimeSpan.Zero) throw Busy("Source de lectures temporairement suspendue après échecs ; aucun nouvel envoi.");
            var limit = group.Open ? 1 : group.Limit;
            if (group.Active >= limit) throw Busy("Budget de lectures de cette source atteint ; les travaux précédents restent comptés jusqu’à leur fin physique.");
            group.Active++;
            var lease = new Lease(this, key, group);
            if (group.Open) group.Trial = lease;
            return lease;
        }
    }

    /// <summary>Wait only for an occupied place before the first send. A suspended source is refused immediately;
    /// no timer creates a read, and cancellation/expiry never becomes an observation of the target.</summary>
    public async ValueTask<Lease> AcquireAsync(string? host, TimeSpan maximumWait, CancellationToken token, bool controller = false)
    {
        if (maximumWait <= TimeSpan.Zero || maximumWait > TimeSpan.FromMinutes(5)) throw new ArgumentOutOfRangeException(nameof(maximumWait));
        var started = clock.GetTimestamp();
        while (true)
        {
            token.ThrowIfCancellationRequested();
            if (clock.GetElapsedTime(started) >= maximumWait) throw Busy("Attente du budget de lecture expirée ; aucun appel envoyé.");
            Task wake;
            lock (gate)
            {
                try { return Acquire(host, controller); }
                catch (DomeniaOperationException ex) when (ex.Code == "operation.siteBusy")
                {
                    var key = Key(host, controller);
                    if (!groups.TryGetValue(key, out var group) || group.Open) throw;
                    wake = changed.Task;
                }
            }
            var remaining = maximumWait - clock.GetElapsedTime(started);
            if (remaining <= TimeSpan.Zero) throw Busy("Attente du budget de lecture expirée ; aucun appel envoyé.");
            try { await wake.WaitAsync(remaining, clock, token).ConfigureAwait(false); }
            catch (TimeoutException) { throw Busy("Attente du budget de lecture expirée ; aucun appel envoyé."); }
        }
    }

    /// <summary>Queue a first send without starting its network deadline. A suspended provider pauses this existing
    /// request, then admits only one recovery trial. The caller must retain its campaign cancellation and recheck its
    /// account/identity after admission. This does not retry an already sent operation or create background work.</summary>
    public async ValueTask<Lease> AcquireAsync(string? host, CancellationToken token, bool controller = false)
    {
        while (true)
        {
            token.ThrowIfCancellationRequested();
            Task wake;
            TimeSpan recovery;
            lock (gate)
            {
                try { return Acquire(host, controller); }
                catch (DomeniaOperationException ex) when (ex.Code == "operation.siteBusy")
                {
                    var key = Key(host, controller);
                    if (!groups.TryGetValue(key, out var group)) throw;
                    recovery = Remaining(group);
                    wake = changed.Task;
                }
            }
            if (recovery > TimeSpan.Zero)
            {
                try { await wake.WaitAsync(recovery, clock, token).ConfigureAwait(false); }
                catch (TimeoutException) { /* Recheck the circuit and capacity; the timer never sends a request. */ }
            }
            else await wake.WaitAsync(token).ConfigureAwait(false);
        }
    }

    private void WakeWaiting()
    {
        var previous = changed;
        changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        previous.TrySetResult();
    }

    public AdaptiveReadLoad Snapshot(string? host, bool controller = false)
    {
        lock (gate)
        {
            var key = Key(host, controller);
            return groups.TryGetValue(key, out var group) ? new(key, group.Active, group.Open ? 1 : group.Limit, Remaining(group), addresses.Count)
            { State = group.Open ? Remaining(group) > TimeSpan.Zero ? "open" : "halfOpen" : "closed", Failures = group.Failures }
                : new(key, 0, maximum, TimeSpan.Zero, addresses.Count);
        }
    }

    private string Key(string? host, bool controller)
    {
        if (controller && string.IsNullOrEmpty(host)) return "dc:?";
        var name = Name(host);
        if (controller) return "dc:" + name;
        if (IPAddress.TryParse(name, out var literal) && Subnet(literal) is { } subnet) return subnet;
        if (!addresses.TryGetValue(name, out var entry)) return "site:?";
        addressOrder.Remove(entry); addressOrder.AddLast(entry);
        return entry.Value.Subnet;
    }
    private static string? Subnet(IPAddress? address)
    {
        if (address?.AddressFamily != AddressFamily.InterNetwork) return null;
        var bytes = address.GetAddressBytes();
        return bytes[0] is 0 or 127 or >= 224 ? null : $"site:{bytes[0]}.{bytes[1]}.{bytes[2]}.0/24";
    }
    private TimeSpan Remaining(Group group) => !group.Open ? TimeSpan.Zero
        : TimeSpan.FromSeconds(Math.Max(0, group.SuspensionSeconds - clock.GetElapsedTime(group.SuspendedAt).TotalSeconds));
    private static string Name(string? name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length > 255 || name.Any(char.IsControl) || Uri.CheckHostName(name) == UriHostNameType.Unknown)
            throw new ArgumentException("Nom de cible non qualifié pour le budget de lecture.", nameof(name));
        return name.TrimEnd('.').ToLowerInvariant();
    }
    private static DomeniaOperationException Busy(string text) => new("operation.siteBusy", text);

    /// <summary>Partial/empty are actual answers. Refused rights, missing capabilities, skipped and offline are not provider failures.</summary>
    public static AdaptiveReadOutcome Classify(SourceStatus? status) => status switch
    {
        SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial => AdaptiveReadOutcome.Success,
        SourceStatus.Interrupted => AdaptiveReadOutcome.Timeout,
        SourceStatus.Error => AdaptiveReadOutcome.Failure,
        _ => AdaptiveReadOutcome.Neutral,
    };

    public sealed class Lease : IDisposable
    {
        private readonly AdaptiveReadBudget owner;
        private readonly Group group;
        private int disposed;
        public string GroupName { get; }
        internal Lease(AdaptiveReadBudget owner, string key, Group group) { this.owner = owner; this.group = group; GroupName = key; }

        public void RequireContinuation()
        {
            lock (owner.gate)
            {
                ObjectDisposedException.ThrowIf(disposed != 0, this);
                if (owner.Remaining(group) > TimeSpan.Zero) throw Busy("Source suspendue ; aucun nouvel appel dans le processus conservé.");
                if (!group.Open) return;
                if (group.Trial is null) group.Trial = this;
                if (!ReferenceEquals(group.Trial, this)) throw Busy("Une seule lecture d’essai peut reprendre cette source.");
            }
        }

        public void Report(bool success, TimeSpan elapsed) => Report(success ? AdaptiveReadOutcome.Success : AdaptiveReadOutcome.Failure, elapsed);

        /// <summary>Feedback never releases admission. Cancellation/neutral results do not change source health.</summary>
        public void Report(AdaptiveReadOutcome outcome, TimeSpan elapsed)
        {
            if (elapsed < TimeSpan.Zero || !Enum.IsDefined(outcome)) throw new ArgumentOutOfRangeException(nameof(outcome));
            lock (owner.gate)
            {
                if (disposed != 0 || outcome is AdaptiveReadOutcome.Neutral or AdaptiveReadOutcome.Cancelled) return;
                group.Used = ++owner.sequence;
                var now = owner.clock.GetTimestamp();
                void Decrease()
                {
                    if (group.Decreased && owner.clock.GetElapsedTime(group.LastDecrease, now) < TimeSpan.FromSeconds(10)) return;
                    group.Limit = Math.Max(1, group.Limit / 2); group.Successes = 0; group.LastDecrease = now; group.Decreased = true;
                }
                if (outcome != AdaptiveReadOutcome.Success)
                {
                    group.Failures = Math.Min(1_000_000, group.Failures + 1); group.Successes = 0; Decrease();
                    if (!group.Unknown && (!group.Open && group.Failures >= 3 || group.Open && ReferenceEquals(group.Trial, this)))
                    {
                        group.Opens = Math.Min(10, group.Opens + 1);
                        group.SuspensionSeconds = Math.Min(900, 60 * (1 << (group.Opens - 1)));
                        group.SuspendedAt = now; group.Open = true; group.Trial = null; group.Limit = 1;
                    }
                    owner.WakeWaiting();
                    return;
                }
                // A late answer from an already-running request cannot bypass the suspension or its one admitted trial.
                if (group.Open && (owner.Remaining(group) > TimeSpan.Zero || !ReferenceEquals(group.Trial, this))) return;
                var recovering = group.Open;
                if (recovering) { group.Open = false; group.Trial = null; group.Limit = 1; group.Successes = 0; group.LastDecrease = now; group.Decreased = true; }
                group.Failures = 0;
                var latency = elapsed.TotalMilliseconds;
                var slow = group.Samples >= 3 && latency > Math.Max(500, group.BaselineMs * 2);
                if (slow) { group.BaselineMs += .05 * (latency - group.BaselineMs); group.Successes = 0; Decrease(); }
                else
                {
                    group.BaselineMs = group.Samples == 0 ? latency : group.BaselineMs * .8 + latency * .2;
                    group.Samples = Math.Min(1_000_000, group.Samples + 1);
                    if (!recovering && ++group.Successes >= group.Limit) { group.Successes = 0; group.Limit = Math.Min(owner.maximum, group.Limit + 1); }
                    if (group.Limit == owner.maximum) group.Opens = 0;
                }
                owner.WakeWaiting();
            }
        }
        public void Dispose()
        {
            lock (owner.gate)
            {
                if (disposed != 0) return;
                disposed = 1; group.Active--; group.Used = ++owner.sequence;
                if (ReferenceEquals(group.Trial, this)) group.Trial = null;
                owner.WakeWaiting();
            }
        }
    }
}
