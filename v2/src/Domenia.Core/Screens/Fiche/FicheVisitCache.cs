namespace Domenia.Core;

public sealed record FicheVisitMetrics(int Count, long Hits, long Misses, long Expired, long Evictions);

/// <summary>Bounded acceleration only. Expiring a visit never deletes the dated durable fiche or its observations.</summary>
public sealed class FicheVisitCache<T>(TimeProvider clock, TimeSpan lifetime, int capacity = 400)
{
    private sealed record Item(T Value, DateTimeOffset Observed, DateTimeOffset Stored, long Order);
    private readonly Lock gate = new();
    private readonly Dictionary<Guid, Item> items = [];
    private long hits, misses, expired, evictions, order;
    public void Put(Guid id, T value, DateTimeOffset observed)
    {
        if (id == Guid.Empty || observed == DateTimeOffset.MinValue || observed > clock.GetUtcNow().AddMinutes(5)) return;
        lock (gate)
        {
            Prune();
            if (items.TryGetValue(id, out var previous) && previous.Observed > observed) return;
            items[id] = new(value, observed, clock.GetUtcNow(), ++order);
            while (items.Count > Math.Clamp(capacity, 1, 400))
            { items.Remove(items.MinBy(p => p.Value.Order).Key); evictions++; }
        }
    }
    public T? Find(Func<T, bool> predicate)
    {
        lock (gate)
        {
            Prune();
            var found = items.Values.Where(v => predicate(v.Value)).Take(2).ToArray();
            if (found.Length != 1) { misses++; return default; }
            hits++; return found[0].Value;
        }
    }
    public IReadOnlyList<T> Snapshot()
    { lock (gate) { Prune(); return items.Values.Select(v => v.Value).ToArray(); } }
    public bool Remove(Guid id) { lock (gate) return items.Remove(id); }
    public void Clear() { lock (gate) items.Clear(); }
    public FicheVisitMetrics Metrics { get { lock (gate) { Prune(); return new(items.Count, hits, misses, expired, evictions); } } }
    private void Prune()
    {
        var now = clock.GetUtcNow();
        foreach (var id in items.Where(p => now < p.Value.Stored || now - p.Value.Stored >= lifetime).Select(p => p.Key).ToArray())
        { items.Remove(id); expired++; }
    }
}
