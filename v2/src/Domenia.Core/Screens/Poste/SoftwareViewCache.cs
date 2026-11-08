using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>Immutable software presentation only; no remote read and no freshness permission.</summary>
public interface IPosteViewCacheReader { int ClearSoftwareViews(); }

public sealed class SoftwareViewCache
{
    public const int MaxEntries = 16;
    private readonly Lock gate = new();
    private readonly Dictionary<string, (SoftwareResult Result, long Use)> entries = [];
    private long sequence;
    private long epoch = -1;
    public int Clear() { lock (gate) { var count = entries.Count; entries.Clear(); return count; } }
    public SoftwareResult Resolve(Guid identity, long session, DateOnly today, object content, Func<SoftwareResult> build)
    {
        // Day and cultures affect labels; theme and width belong to CSS and are never cached here.
        var hash = identity == Guid.Empty ? null : BoundedCacheKey.Create(new { identity, session, today,
            culture = CultureInfo.CurrentCulture.Name, uiCulture = CultureInfo.CurrentUICulture.Name, content });
        if (hash is null) return build();
        lock (gate)
        {
            if (session < epoch) return build();
            if (session != epoch) { entries.Clear(); epoch = session; }
            if (entries.TryGetValue(hash, out var found)) { entries[hash] = (found.Result, ++sequence); return found.Result; }
            var result = build();
            // Both keys and retained values are bounded. A large inventory remains fully visible, simply uncached.
            if (BoundedCacheKey.Create(result) is not null)
            {
                entries[hash] = (result, ++sequence);
                while (entries.Count > MaxEntries) entries.Remove(entries.MinBy(e => e.Value.Use).Key);
            }
            return result;
        }
    }
}
