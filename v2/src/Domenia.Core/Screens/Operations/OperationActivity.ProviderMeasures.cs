using System.Collections.Immutable;

namespace Domenia.Core;

public sealed record ProviderReadMeasures(ReadPerformanceMethod Method, long Attempts, long Successful, long CacheHits,
    LatencySummary Admission, LatencySummary Execution, LatencySummary Startup);

public sealed partial class OperationActivity
{
    private sealed class ProviderMeasures
    {
        internal readonly Queue<double> Admission = new(), Execution = new(), Startup = new();
        internal long Attempts, Successful, CacheHits;
    }
    private readonly Dictionary<ReadPerformanceMethod, ProviderMeasures> providers = [];

    public void RecordReadPerformance(ReadPerformanceSample sample)
    {
        if (!Enum.IsDefined(sample.Method) || !Enum.IsDefined(sample.Outcome) || sample.QueueMs < 0 || sample.ExecutionMs < 0
            || sample.StartupMs is < 0) return;
        lock (gate)
        {
            var current = providers.TryGetValue(sample.Method, out var kept) ? kept : providers[sample.Method] = new();
            if (sample.CacheHit) { current.CacheHits++; return; }
            current.Attempts++;
            if (sample.Outcome == ReadPerformanceOutcome.Success) current.Successful++;
            Push(current.Admission, sample.QueueMs); Push(current.Execution, sample.ExecutionMs);
            if (sample.StartupMs is { } startup) Push(current.Startup, startup);
        }
    }

    public ImmutableArray<ProviderReadMeasures> ProviderMeasuresSnapshot()
    {
        lock (gate)
            return [.. providers.OrderBy(p => p.Key).Select(p => new ProviderReadMeasures(p.Key, p.Value.Attempts,
                p.Value.Successful, p.Value.CacheHits, ActivityRules.Latency(p.Value.Admission),
                ActivityRules.Latency(p.Value.Execution), ActivityRules.Latency(p.Value.Startup)))];
    }
}
