namespace Domenia.Core;

/// <summary>Immutable session policy for queue ageing, withdrawal and bounded promotion. It grants no admission capacity.</summary>
public sealed record QueueTiming
{
    private QueueTiming(int backgroundAgingSeconds, int maxQueueWaitSeconds, int tickBudgetMilliseconds, int maxUserProbes = 2, int maxThreads = 8, int maxQueued = 32, int reservedForeground = 2, int maxOutstanding = 12,
        int treeSeconds = 30, int searchSeconds = 120, int objectSeconds = 35, int remoteSeconds = 45)
    {
        BackgroundAgingSeconds = Math.Clamp(backgroundAgingSeconds, 5, 600);
        MaxQueueWaitSeconds = Math.Clamp(maxQueueWaitSeconds, 5, 600);
        TickBudgetMilliseconds = Math.Clamp(tickBudgetMilliseconds, 5, 200);
        MaxUserProbes = Math.Clamp(maxUserProbes, 1, 3);
        MaxThreads = Math.Clamp(maxThreads, 1, 8); MaxQueued = Math.Clamp(maxQueued, 0, 32);
        ReservedForeground = Math.Clamp(reservedForeground, 0, Math.Max(0, MaxThreads - 1));
        MaxOutstanding = Math.Clamp(maxOutstanding, 1, 12);
        TreeSeconds = Math.Clamp(treeSeconds, 5, 300); SearchSeconds = Math.Clamp(searchSeconds, 10, 900);
        ObjectSeconds = Math.Clamp(objectSeconds, 5, 300); RemoteSeconds = Math.Clamp(remoteSeconds, 5, 600);
    }

    public int BackgroundAgingSeconds { get; }
    public int MaxQueueWaitSeconds { get; }
    public int TickBudgetMilliseconds { get; }
    public int MaxUserProbes { get; }
    public int MaxThreads { get; }
    public int MaxQueued { get; }
    public int ReservedForeground { get; }
    public int MaxOutstanding { get; }
    public int TreeSeconds { get; }
    public int SearchSeconds { get; }
    public int ObjectSeconds { get; }
    public int RemoteSeconds { get; }
    public int? ReadSeconds(string operation) => operation.StartsWith("directory.", StringComparison.Ordinal) ? TreeSeconds
        : operation.StartsWith("fiche.", StringComparison.Ordinal) || operation.StartsWith("accounts.", StringComparison.Ordinal) ? ObjectSeconds : operation.StartsWith("poste.", StringComparison.Ordinal) ? RemoteSeconds : null;
    public TimeSpan Aging => TimeSpan.FromSeconds(BackgroundAgingSeconds);
    public TimeSpan Expiration => TimeSpan.FromSeconds(MaxQueueWaitSeconds);
    public TimeSpan TickBudget => TimeSpan.FromMilliseconds(TickBudgetMilliseconds);

    public static QueueTiming Default { get; } = new(30, 120, 25);

    public static QueueTiming From(ConfigurationReport report)
    {
        ArgumentNullException.ThrowIfNull(report);
        return new(ConfigurationRules.Integer(report, "Async", "BackgroundAgingSeconds", 30),
            ConfigurationRules.Integer(report, "Async", "MaxQueueWaitSeconds", 120),
            ConfigurationRules.Integer(report, "Async", "TickBudgetMs", 25),
            ConfigurationRules.Integer(report, "Streaming", "MaxUserProbes", 2),
            ConfigurationRules.Integer(report, "Async", "MaxThreads", 8), ConfigurationRules.Integer(report, "Async", "MaxQueued", 32),
            ConfigurationRules.Integer(report, "Async", "ReservedForeground", 2), ConfigurationRules.Integer(report, "Async", "MaxOutstandingWorkers", 12),
            ConfigurationRules.Integer(report, "Async", "TreeTimeoutSeconds", 30), ConfigurationRules.Integer(report, "Async", "SearchTimeoutSeconds", 120),
            ConfigurationRules.Integer(report, "Async", "ObjectTimeoutSeconds", 35), ConfigurationRules.Integer(report, "Async", "RemoteTimeoutSeconds", 45));
    }
}
