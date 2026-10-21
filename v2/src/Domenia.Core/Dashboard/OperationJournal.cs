using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>In-memory journal of the session operations: a ring of the most recent entries, thread safe.</summary>
public sealed class OperationJournal
{
    public const int DefaultCapacity = 200;

    private readonly Lock gate = new();
    private readonly Queue<JournalEntry> entries = new();
    private readonly int capacity;

    public OperationJournal(int capacity = DefaultCapacity)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(capacity, 1);
        this.capacity = capacity;
    }

    public void Add(JournalEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        lock (gate)
        {
            entries.Enqueue(entry);
            while (entries.Count > capacity)
            {
                entries.Dequeue();
            }
        }
    }

    /// <summary>Entries, most recent first.</summary>
    public ImmutableArray<JournalEntry> Snapshot()
    {
        lock (gate)
        {
            return [.. entries.Reverse()];
        }
    }
}
