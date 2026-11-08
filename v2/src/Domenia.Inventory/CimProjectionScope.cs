using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Inventory;

public sealed record CimProjection(string Namespace, string Query, int Limit);

/// <summary>One frozen, sequential collection on one admitted host/account/transport. No value survives its disposal.
/// Identity checks and repeated samples explicitly bypass this plan. Filters are compared byte for byte.</summary>
public sealed class CimProjectionScope : IDisposable
{
    private static readonly AsyncLocal<CimProjectionScope?> Ambient = new();
    private readonly CimProjectionScope? previous;
    private readonly string host, account;
    private readonly bool windowsSession;
    private readonly InventoryTransport transport;
    private readonly Action ensureCurrent;
    private int closed;
    internal CimProjectionPlan Plan { get; }
    internal static CimProjectionScope? Current => Ambient.Value;

    public CimProjectionScope(string host, InventoryTransport transport, RemoteProbeCredential? credential,
        IEnumerable<CimProjection> projections, Action ensureCurrent, Action? reused = null)
    {
        this.host = host; this.transport = transport; this.ensureCurrent = ensureCurrent;
        windowsSession = credential is null or { Session: true };
        account = windowsSession ? "" : credential!.Account;
        Plan = new(projections, reused);
        previous = Ambient.Value; Ambient.Value = this;
    }

    internal CimProjectionPlan? For(string requestedHost, InventoryTransport requestedTransport, RemoteProbeCredential? credential)
    {
        if (!string.Equals(host, requestedHost, StringComparison.OrdinalIgnoreCase) || transport != requestedTransport
            || windowsSession != (credential is null or { Session: true })
            || !windowsSession && !string.Equals(account, credential?.Account, StringComparison.Ordinal)) { return null; }
        ObjectDisposedException.ThrowIf(Volatile.Read(ref closed) != 0, this);
        ensureCurrent(); return Plan;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref closed, 1) != 0) { return; }
        Plan.Dispose();
        if (ReferenceEquals(Ambient.Value, this)) { Ambient.Value = previous; }
    }
}

internal sealed class CimProjectionPlan : IDisposable
{
    private sealed record Key(string Namespace, string Class, string Filter);
    private sealed class Group(string query, int limit, string[] properties, Dictionary<string, int> consumers)
    {
        internal string Query { get; set; } = query;
        internal string[] Properties { get; set; } = properties;
        internal int Limit { get; } = limit;
        internal Dictionary<string, int> Consumers { get; } = consumers;
        internal CimReading? Result;
        internal bool Busy, Separate;
    }
    private readonly Lock gate = new();
    private readonly Dictionary<Key, Group> groups = [];
    private readonly Action? reused;
    private long heldBytes;
    private bool closed;
    internal int QueriesAvoided { get; private set; }

    internal CimProjectionPlan(IEnumerable<CimProjection> projections, Action? reused = null)
    {
        this.reused = reused;
        var inputs = projections.Take(257).ToArray();
        if (inputs.Length > 256) { return; } // Optimization ceiling only; the ordinary bounded reads remain available.
        var parsed = inputs.Select(p => (Projection: p, Select: WqlRules.Parse(p.Query))).ToArray();
        foreach (var (p, _) in parsed)
        { if (p.Limit is < 1 or > 20000 || !CimQuery.IsReadOnlySelect(p.Query, p.Namespace)) { throw new ArgumentException("Projection CIM hors contrat.", nameof(projections)); } }
        foreach (var set in parsed.GroupBy(p => GroupKey(p.Projection.Namespace, p.Projection.Query, p.Select)))
        {
            if (set.Count() < 2) { continue; }
            var properties = set.SelectMany(p => p.Select.Properties).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (properties.Length > 64) { continue; }
            var first = set.First();
            var query = "SELECT " + string.Join(", ", properties) + " FROM " + first.Select.ClassName + set.Key.Filter;
            if (!CimQuery.IsReadOnlySelect(query, first.Projection.Namespace)) { continue; }
            groups.Add(set.Key, new(query, set.Max(p => p.Projection.Limit), properties, set.GroupBy(p => p.Select.CanonicalQuery, StringComparer.Ordinal)
                .ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal)));
        }
    }

    private static Key GroupKey(string ns, string query, WqlSelect parsed)
    {
        // The closed grammar has no quoted token before WHERE. Keep spelling, whitespace and literals unchanged.
        var where = System.Text.RegularExpressions.Regex.Match(query, @"\s+WHERE\s+", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
        return new(ns.ToUpperInvariant(), parsed.ClassName.ToUpperInvariant(), where.Success ? query[where.Index..] : "");
    }

    internal void CompleteProjection(string ns, string original, string expanded)
    {
        var before = WqlRules.Parse(original); var after = WqlRules.Parse(expanded);
        var key = GroupKey(ns, original, before);
        if (key != GroupKey(ns, expanded, after) || !CimQuery.IsReadOnlySelect(expanded, ns)
            || before.Properties.Any(p => !after.Properties.Contains(p, StringComparer.OrdinalIgnoreCase))) { return; }
        lock (gate)
        {
            if (closed || !groups.TryGetValue(key, out var group) || group.Busy || group.Separate
                || !group.Consumers.TryGetValue(before.CanonicalQuery, out var count) || count == 0 || before.CanonicalQuery == after.CanonicalQuery) { return; }
            var properties = group.Properties.Concat(after.Properties).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (properties.Length > 64 || group.Result is not null && properties.Length != group.Properties.Length)
            { group.Separate = true; return; }
            var query = "SELECT " + string.Join(", ", properties) + " FROM " + before.ClassName + key.Filter;
            if (!CimQuery.IsReadOnlySelect(query, ns)) { group.Separate = true; return; }
            group.Properties = properties; group.Query = query;
            group.Consumers[before.CanonicalQuery] = 0;
            group.Consumers[after.CanonicalQuery] = group.Consumers.GetValueOrDefault(after.CanonicalQuery) + count;
        }
    }

    internal CimReading? Read(string category, string ns, string query, int limit, Action<WmiInstance>? receive,
        Func<string, int, Action<WmiInstance>?, CimReading> native)
    {
        lock (gate) { if (closed || groups.Count == 0) { return null; } }
        var parsed = WqlRules.Parse(query); Group? group; CimReading? cached;
        lock (gate)
        {
            if (closed || !groups.TryGetValue(GroupKey(ns, query, parsed), out group) || group.Separate || group.Busy
                || !group.Consumers.TryGetValue(parsed.CanonicalQuery, out var remaining) || remaining == 0) { return null; }
            group.Consumers[parsed.CanonicalQuery] = remaining - 1;
            cached = group.Result;
            if (cached is null) { group.Busy = true; }
        }
        WmiInstance Project(WmiInstance row) => new(parsed.Properties.ToDictionary(p => p, row.Raw, StringComparer.OrdinalIgnoreCase));
        if (cached is not null)
        {
            lock (gate) { if (closed) { return null; } QueriesAvoided++; }
            ObserveReuse();
            var rows = cached.Instances.Take(limit).Select(Project).ToArray();
            foreach (var row in rows) { receive?.Invoke(row); }
            return cached with { Category = category, DurationMs = 0, Instances = rows,
                Status = cached.Items > limit ? SourceStatus.Partial : cached.Status,
                Detail = cached.Items > limit ? "Projection du relevé commun limitée ; résultat incomplet." : "Projection du relevé commun déjà reçu ; aucun nouvel appel CIM." };
        }
        try
        {
            var sent = 0;
            var read = native(group.Query, group.Limit, receive is null ? null : row => { if (sent++ < limit) { receive(Project(row)); } });
            if (read.ProjectionRejected && !read.AuthenticationRejected && read.Items == 0)
            {
                lock (gate) { group.Separate = true; }
                // Only the provider's explicit projection rejection allows the original SELECT. No retry for a
                // refusal, unreachable host, timeout, partial answer or malformed IPC; no account/transport fallback.
                return string.Equals(WqlRules.Parse(group.Query).CanonicalQuery, parsed.CanonicalQuery, StringComparison.Ordinal)
                    ? read : native(query, limit, receive);
            }
            long bytes = 0;
            var missing = read.Instances.Any(row => group.Properties.Any(p => !row.Names.Contains(p, StringComparer.OrdinalIgnoreCase)));
            if (missing && read.Answered) { read = read with { Status = SourceStatus.Partial, Detail = "Projection commune incomplète : propriété absente de la réponse." }; }
            var retain = (read.Status is SourceStatus.Ok or SourceStatus.Empty)
                && read.Instances.All(row => CimSession.WithinLimits(row, ref bytes));
            lock (gate)
            {
                if (!closed && retain && heldBytes + bytes <= 8 * 1024 * 1024)
                { group.Result = read; heldBytes += bytes; }
                else { group.Separate = true; }
            }
            return read with { Category = category, Instances = read.Instances.Take(limit).Select(Project).ToArray(),
                Status = read.Items > limit && read.Answered ? SourceStatus.Partial : read.Status };
        }
        finally { lock (gate) { group.Busy = false; } }
    }

    public void Dispose() { lock (gate) { closed = true; groups.Clear(); heldBytes = 0; } }

    private void ObserveReuse()
    {
#pragma warning disable CA1031 // Optional telemetry must never turn a complete native reading into an application failure.
        try { reused?.Invoke(); } catch { }
#pragma warning restore CA1031
    }
}
