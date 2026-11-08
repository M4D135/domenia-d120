using System.Collections.Immutable;

namespace Domenia.Core.Accueil;

public sealed record RefreshMethodPerformance(string Method, string Label, long Reads, long CacheHits, long QueueMs, long ExecutionMs, long Incomplete);
public sealed record RefreshPerformanceSnapshot(long TotalMs, int WorkstationsReused, ImmutableArray<RefreshMethodPerformance> Methods);

/// <summary>Constant-space campaign totals. Parallel durations are summed per method, never presented as wall time or
/// percentiles; no targets, credentials, query text or unbounded samples enter the report.</summary>
internal sealed class RefreshPerformance(TimeProvider clock)
{
    private readonly long started = clock.GetTimestamp();
    private readonly object gate = new();
    private readonly Dictionary<ReadPerformanceMethod, RefreshMethodPerformance> totals = [];
    private int reused;

    internal void Reused(int count) { lock (gate) { reused = Math.Max(0, count); } }
    internal void Add(ReadPerformanceSample sample)
    {
        if (!Enum.IsDefined(sample.Method)) { return; }
        lock (gate)
        {
            var row = totals.GetValueOrDefault(sample.Method) ?? new(sample.Method.ToString(), Label(sample.Method), 0, 0, 0, 0, 0);
            totals[sample.Method] = sample.CacheHit ? row with { CacheHits = row.CacheHits + 1 }
                : row with { Reads = row.Reads + 1, QueueMs = row.QueueMs + Math.Clamp(sample.QueueMs, 0, 86_400_000L),
                    ExecutionMs = row.ExecutionMs + Math.Clamp(sample.ExecutionMs, 0, 86_400_000L),
                    Incomplete = row.Incomplete + (sample.Outcome == ReadPerformanceOutcome.Success ? 0 : 1) };
        }
    }
    internal RefreshPerformanceSnapshot Snapshot()
    { lock (gate) { return new(ReadPerformance.Milliseconds(clock.GetElapsedTime(started)), reused, [.. totals.OrderBy(p => p.Key).Select(p => p.Value)]); } }

    private static string Label(ReadPerformanceMethod method) => method switch
    {
        ReadPerformanceMethod.Ping => "Réseau / ICMP", ReadPerformanceMethod.Ldap => "AD / LDAP", ReadPerformanceMethod.WmiDcom => "WMI / DCOM",
        ReadPerformanceMethod.ScheduledTask => "Tâche distante", ReadPerformanceMethod.WindowsSessions => "Sessions Windows",
        ReadPerformanceMethod.SecurityLog => "Journal de sécurité", ReadPerformanceMethod.Registry => "Registre",
        ReadPerformanceMethod.WindowsRpc => "RPC Windows", ReadPerformanceMethod.WmiProcess => "Programme local / WMI",
        ReadPerformanceMethod.WinRmScript => "Programme local / WinRM",
        _ => method.ToString(),
    };
}
