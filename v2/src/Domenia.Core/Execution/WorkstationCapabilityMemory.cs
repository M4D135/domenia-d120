using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

public enum WorkstationCapabilityFailure { None, ClassAbsent, ProtocolUnreachable, RightDenied }
public sealed record WorkstationCapabilityFact(WorkstationCapabilityFailure Failure, DateTimeOffset ObservedAt, DateTimeOffset Until);

/// <summary>Bounded negative facts of this engine session. No results, credentials, request buffers, disk or timers.
/// A native worker may finish late; only its captured session can amend this memory.</summary>
public sealed class WorkstationCapabilityMemory
{
    public const int Capacity = 2048;
    private const string Protocol = "$cim";
    private static readonly AsyncLocal<Context?> Active = new();
    private readonly Lock gate = new();
    private readonly TimeProvider clock;
    private readonly Dictionary<Key, Entry> entries = [];
    private long epoch = long.MinValue, machineGeneration, directoryGeneration;
    private readonly LinkedList<Key> order = new();
    private readonly Dictionary<(string Host, string Transport), HashSet<Key>> byHost = [];
    private DateTimeOffset lastSweep = DateTimeOffset.MinValue;
    private sealed record Key(string Host, string Transport, string Capability);
    private sealed record Entry(WorkstationCapabilityFact Fact, string Build, string Account, LinkedListNode<Key> Node);

    public WorkstationCapabilityMemory(TimeProvider clock) { ArgumentNullException.ThrowIfNull(clock); this.clock = clock; }
    public static Context? Current => Active.Value;
    internal int Count { get { lock (gate) { return entries.Count; } } }

    public static async Task<Context?> CaptureAsync(EngineContext engine, CancellationToken token)
    {
        if (engine.Mode != AppMode.Directory) { return null; }
        var session = await engine.Directory.GetSessionAsync(token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        return engine.Shared(static c => new WorkstationCapabilityMemory(c.Clock)).Capture(session.Epoch,
            MachineAccountService.From(engine).Generation, AccountAccess.From(engine).SelectionVersion, session.Account.Login, token);
    }

    internal Context Capture(long sessionEpoch, long machineAccounts, long directoryAccounts, string account, CancellationToken token)
    {
        if (account.Length > 512) { throw new ArgumentException("Identité de capacité hors limites.", nameof(account)); }
        lock (gate)
        {
            if (sessionEpoch > epoch) { entries.Clear(); order.Clear(); byHost.Clear(); lastSweep = DateTimeOffset.MinValue; epoch = sessionEpoch; machineGeneration = machineAccounts; directoryGeneration = directoryAccounts; }
            else if (sessionEpoch == epoch)
            { machineGeneration = Math.Max(machineGeneration, machineAccounts); directoryGeneration = Math.Max(directoryGeneration, directoryAccounts); }
            return new(this, sessionEpoch, machineAccounts, directoryAccounts, account, token);
        }
    }

    public static IDisposable Enter(Context? context)
    { var previous = Active.Value; Active.Value = context; return new Scope(previous); }

    private sealed class Scope(Context? previous) : IDisposable
    { private bool disposed; public void Dispose() { if (!disposed) { disposed = true; Active.Value = previous; } } }

    private void Forget(Key key)
    {
        if (!entries.Remove(key, out var entry)) return;
        order.Remove(entry.Node);
        var host = (key.Host, key.Transport);
        if (byHost.TryGetValue(host, out var keys))
        { keys.Remove(key); if (keys.Count == 0) byHost.Remove(host); }
    }

    public sealed class Context
    {
        private readonly WorkstationCapabilityMemory memory;
        private readonly long epoch, machineAccounts, directoryAccounts;
        private readonly string defaultAccount;
        private readonly CancellationToken token;
        internal Context(WorkstationCapabilityMemory memory, long epoch, long machineAccounts, long directoryAccounts, string defaultAccount, CancellationToken token)
        { this.memory = memory; this.epoch = epoch; this.machineAccounts = machineAccounts; this.directoryAccounts = directoryAccounts; this.defaultAccount = defaultAccount; this.token = token; }
        private bool Current => !token.IsCancellationRequested && memory.epoch == epoch
            && memory.machineGeneration == machineAccounts && memory.directoryGeneration == directoryAccounts;
        private string Account(string? supplied) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(
            (supplied ?? defaultAccount).ToUpperInvariant() + "\n" + machineAccounts + "\n" + directoryAccounts)));
        private static Key KeyOf(string host, string transport, string capability)
        {
            if (host.Length is 0 or > 255 || transport.Length is 0 or > 32 || capability.Length is 0 or > 512)
            { throw new ArgumentException("Clé de capacité hors limites."); }
            return new(host.ToUpperInvariant(), transport, capability.ToUpperInvariant());
        }

        public WorkstationCapabilityFact? Find(string host, string transport, string capability, string? build, string? account, bool classQualified)
        {
            if ((account?.Length ?? 0) > 512 || (build?.Length ?? 0) > 64) { return null; }
            var query = KeyOf(host, transport, capability);
            lock (memory.gate)
            {
                if (!Current) { return null; }
                var common = Read(query with { Capability = Protocol }, build, Account(account));
                return common ?? (classQualified ? Read(query, build, Account(account)) : null);
            }
        }

        private WorkstationCapabilityFact? Read(Key key, string? build, string account)
        {
            if (!memory.entries.TryGetValue(key, out var entry)) { return null; }
            var fact = entry.Fact;
            var now = memory.clock.GetUtcNow();
            if (now < fact.ObservedAt || now >= fact.Until
                || fact.Failure != WorkstationCapabilityFailure.ClassAbsent && entry.Account != account
                || fact.Failure == WorkstationCapabilityFailure.ClassAbsent && !string.IsNullOrEmpty(build) && entry.Build != build)
            { memory.Forget(key); return null; }
            return fact;
        }

        public void Record(string host, string transport, string capability, WorkstationCapabilityFailure failure, string? build, string? account, bool protocolWide = true)
        {
            var ttl = failure switch
            { WorkstationCapabilityFailure.ClassAbsent => TimeSpan.FromDays(7), WorkstationCapabilityFailure.ProtocolUnreachable => TimeSpan.FromMinutes(15),
                WorkstationCapabilityFailure.RightDenied => TimeSpan.FromHours(1), _ => TimeSpan.Zero };
            if (ttl == TimeSpan.Zero || (build?.Length ?? 0) > 64 || (account?.Length ?? 0) > 512) { return; }
            var common = failure != WorkstationCapabilityFailure.ClassAbsent && protocolWide;
            var key = KeyOf(host, transport, common ? Protocol : capability);
            // KeyOf folds class names; the reserved protocol key is canonicalized to the same spelling on both paths.
            if (common) { key = key with { Capability = Protocol }; }
            lock (memory.gate)
            {
                if (!Current) { return; }
                var now = memory.clock.GetUtcNow();
                // Expiration is also checked on every lookup. A periodic bounded sweep avoids scanning
                // the whole capability cache for every class of every machine in a large campaign.
                if (now < memory.lastSweep || now - memory.lastSweep >= TimeSpan.FromMinutes(1))
                {
                    foreach (var old in memory.entries.Where(p => p.Value.Fact.Until <= now || p.Value.Fact.ObservedAt > now).Select(p => p.Key).ToArray())
                        memory.Forget(old);
                    memory.lastSweep = now;
                }
                memory.Forget(key);
                if (memory.entries.Count >= Capacity && memory.order.First is { } oldest) memory.Forget(oldest.Value);
                var node = memory.order.AddLast(key);
                memory.entries[key] = new(new(failure, now, now + ttl), build ?? "", Account(account), node);
                var hostKey = (key.Host, key.Transport);
                if (!memory.byHost.TryGetValue(hostKey, out var keys)) memory.byHost.Add(hostKey, keys = []);
                keys.Add(key);
            }
        }

        public void Success(string host, string transport, string capability)
        {
            var key = KeyOf(host, transport, capability);
            lock (memory.gate)
            {
                if (!Current) { return; }
                memory.Forget(key); memory.Forget(key with { Capability = Protocol });
            }
        }

        public void ObserveBuild(string host, string transport, string build)
        {
            if (build.Length is 0 or > 64) { return; }
            var key = KeyOf(host, transport, Protocol);
            lock (memory.gate)
            {
                if (!Current) { return; }
                if (!memory.byHost.TryGetValue((key.Host, key.Transport), out var keys)) return;
                foreach (var old in keys.Where(k => memory.entries[k].Fact.Failure == WorkstationCapabilityFailure.ClassAbsent
                    && memory.entries[k].Build != build).ToArray()) memory.Forget(old);
            }
        }
    }
}
