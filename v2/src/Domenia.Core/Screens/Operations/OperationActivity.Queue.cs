using System.Collections.Immutable;

namespace Domenia.Core;

public enum CollectionQueueClass { Explicit, Selection, Background, Write }
public sealed record CollectionQueueMeasure(CollectionQueueClass Class, LatencySummary Wait, long Admitted, long Promotions);

public sealed partial class OperationActivity
{
    private sealed class QueueMeasures
    {
        public Queue<double> Waits { get; } = new();
        public long Admitted;
        public long Promotions;
    }
    private readonly Dictionary<CollectionQueueClass, QueueMeasures> queueMeasures = [];

    /// <summary>Called exactly once at real admission. Rejected/expired requests are not completed queue waits.</summary>
    public void RecordQueueAdmission(CollectionQueueClass requestClass, double milliseconds, bool promoted)
    {
        if (!Enum.IsDefined(requestClass) || !double.IsFinite(milliseconds) || milliseconds < 0)
            throw new ArgumentOutOfRangeException(nameof(milliseconds));
        lock (gate)
        {
            if (!queueMeasures.TryGetValue(requestClass, out var values)) queueMeasures[requestClass] = values = new();
            values.Waits.Enqueue(milliseconds);
            while (values.Waits.Count > ActivityRules.SamplesPerSeries) values.Waits.Dequeue();
            values.Admitted++;
            if (promoted) values.Promotions++;
        }
    }

    public ImmutableArray<CollectionQueueMeasure> QueueMeasuresSnapshot()
    {
        lock (gate)
        {
            return [.. Enum.GetValues<CollectionQueueClass>().Select(kind => queueMeasures.TryGetValue(kind, out var values)
                ? new CollectionQueueMeasure(kind, ActivityRules.Latency(values.Waits), values.Admitted, values.Promotions)
                : new CollectionQueueMeasure(kind, ActivityRules.Latency([]), 0, 0))];
        }
    }

    private ImmutableArray<string> QueueLines() => [.. QueueMeasuresSnapshot().Select(row =>
        ActivityRules.LatencyText("Attente en file · " + (row.Class switch
        {
            CollectionQueueClass.Explicit => "actions explicites",
            CollectionQueueClass.Selection => "sélection",
            CollectionQueueClass.Background => "lectures de fond",
            _ => "écritures",
        }), row.Wait) + " " + FrenchText.Integer(row.Admitted) + " admissions ; " + FrenchText.Integer(row.Promotions)
            + " promotions après longue attente. Qualification locale incluse ; traitement après admission exclu.")];
}
