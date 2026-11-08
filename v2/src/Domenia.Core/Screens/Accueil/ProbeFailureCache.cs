using Domenia.Core.Poste;

namespace Domenia.Core.Accueil;

/// <summary>Short-lived failed attempts, never successful values or account unlocks. Keys contain no credentials.</summary>
public sealed class ProbeFailureCache(TimeProvider clock)
{
    public const int Capacity = 20000;
    private sealed record Entry(ProbeReading Reading, long Since, TimeSpan Delay, LinkedListNode<string> Node);
    private readonly Lock gate = new();
    private readonly Dictionary<string, Entry> failures = [];
    private readonly LinkedList<string> order = new();
    public int Count { get { lock (gate) return failures.Count; } }
    private void Remove(string key)
    {
        if (failures.Remove(key, out var entry)) order.Remove(entry.Node);
    }
    public ProbeReading? Read(string? key)
    {
        if (key is null) return null;
        lock (gate)
        {
            if (!failures.TryGetValue(key, out var entry)) return null;
            if (clock.GetElapsedTime(entry.Since) >= entry.Delay) { Remove(key); return null; }
            return entry.Reading; // Original timestamp and error: no new attempt and no fresh success.
        }
    }
    public void Remember(string? key, ProbeReading reading)
    {
        if (key is null) return;
        var seconds = reading.FailureStatus switch
        {
            SourceStatus.Unreachable or SourceStatus.Interrupted => 120,
            SourceStatus.Refused or SourceStatus.Unavailable => 600,
            SourceStatus.Error => 60,
            _ => 0,
        };
        lock (gate)
        {
            Remove(key);
            // Authentication remains governed by the existing account circuit; a cache expiry cannot resume it.
            if (seconds == 0 || reading.AuthenticationRejected || reading.State == MeasureState.Known
                || reading.Values.Length != 0 || reading.Error?.Length > 2048) return;
            failures[key] = new(reading, clock.GetTimestamp(), TimeSpan.FromSeconds(seconds), order.AddLast(key));
            // Constant work per result even when all 100 000 targets fail. Different TTLs are checked on lookup;
            // capacity pressure drops the oldest retained attempt, without a complete dictionary scan.
            if (failures.Count > Capacity && order.First is { } oldest) Remove(oldest.Value);
        }
    }
}
