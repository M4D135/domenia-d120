using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

/// <summary>Only immutable compiled definitions survive a redraw. Values, clock, scope and rendered output never do.</summary>
public sealed class FleetQueryPlanCache
{
    public const int Capacity = 64;
    private readonly Lock gate = new();
    private readonly Dictionary<string, (CompiledQuery Query, long Use)> plans = [];
    private long sequence;
    public int Count { get { lock (gate) return plans.Count; } }
    public int Clear() { lock (gate) { var count = plans.Count; plans.Clear(); return count; } }
    public CompiledQuery Compile(QueryRecipe recipe)
    {
        var key = BoundedCacheKey.Create(recipe);
        if (key is null) return QueryEngine.Compile(recipe);
        lock (gate)
        {
            if (plans.TryGetValue(key, out var saved)) { plans[key] = (saved.Query, ++sequence); return saved.Query; }
            var query = QueryEngine.Compile(recipe);
            plans[key] = (query, ++sequence);
            while (plans.Count > Capacity) plans.Remove(plans.MinBy(p => p.Value.Use).Key);
            return query;
        }
    }
    public void Retain(IEnumerable<QueryRecipe> recipes)
    {
        var active = recipes.Select(r => BoundedCacheKey.Create(r)).OfType<string>().ToHashSet(StringComparer.Ordinal);
        lock (gate) foreach (var key in plans.Keys.Where(k => !active.Contains(k)).ToArray()) plans.Remove(key);
    }
}
