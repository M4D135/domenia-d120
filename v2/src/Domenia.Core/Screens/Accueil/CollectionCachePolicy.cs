using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

/// <summary>Reuse follows the value's lifetime, never a single age for the entire workstation.</summary>
public sealed class CollectionCachePolicy(CollectionSettings settings)
{
    private readonly ImmutableDictionary<string, int> seconds = CollectionSettingsRules.FreshnessTable(settings).ToImmutableDictionary(f => f.Family, f => f.Seconds);
    private readonly int cap = settings.Budgets.GetValueOrDefault(CollectionSettingsRules.CacheMinutes, 15) * 60;
    public int ReuseMinutes => cap / 60;
    public static CollectionCachePolicy Read(IPreferenceStore preferences) => new(CollectionSettingsRules.Read(
        preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var stored) ? stored : null, []));

    public DateTimeOffset Since(string family, DateTimeOffset now) => now - TimeSpan.FromSeconds(Math.Min(seconds.GetValueOrDefault(family, 0), cap));
    public bool Inventory(InventoryMeasure? value, DateTimeOffset now, bool force = false) => !force && cap > 0
        && seconds.GetValueOrDefault("inventory", 0) > 0 && RefreshRules.InventoryAnswered(value, Since("inventory", now), now);

    public bool Memory(MemoryUsageFact? value, DateTimeOffset now, bool force = false) => !force && cap > 0
        && seconds.GetValueOrDefault("volatileProbe", 0) > 0 && HomeMemoryPolicy.Answered(value, Since("volatileProbe", now), now);

    public static bool IdentityFact(string id) => id is "hw.maker" or "hw.model" or "hw.serialmissing";
    public static string Family(string id) => id.StartsWith("hw.", StringComparison.Ordinal)
        && id is not ("hw.cpuload" or "hw.batterylevel" or "hw.screens" or "hw.memoryusage") || id.StartsWith("os.", StringComparison.Ordinal)
        && id is not ("os.uptime" or "os.pagefile" or "os.freeram" or "os.virtualfree" or "os.users") ? "staticProbe" : "volatileProbe";

    public bool Probe(string id, ProbeReading? value, QueryComputerIdentity? target, DateTimeOffset now, bool force = false)
    {
        if (force || cap == 0 || !ProbeDefinitionIdentity.Current(id, value?.DefinitionHash) || value is not { State: MeasureState.Known, Error: null, At: { } at }
            || at > now + RefreshRules.FutureTolerance || value.AuthenticationRejected || value.Values.IsDefaultOrEmpty
            || seconds.GetValueOrDefault(Family(id), 0) == 0
            || value.Identity is not null && target is not null && value.Identity != target) { return false; }
        // Only an explicitly qualified identity makes long-lived data reusable. Old cache rows refresh once.
        if (IdentityFact(id) && target is not null && value.Identity == target && at >= target.Created
            && !value.Values.IsDefaultOrEmpty && value.Values.All(v => !string.IsNullOrWhiteSpace(v)
                && !v.Equals("unknown", StringComparison.OrdinalIgnoreCase) && !v.Equals("not specified", StringComparison.OrdinalIgnoreCase)
                && !v.Equals("to be filled by o.e.m.", StringComparison.OrdinalIgnoreCase))) { return true; }
        var family = Family(id);
        return seconds.GetValueOrDefault(family, 0) > 0 && at >= Since(family, now);
    }

    public ImmutableArray<Guid> Missing(IEnumerable<Guid> online, IReadOnlyDictionary<Guid, WorkstationObservation> observations,
        ProbeReadings probes, ImmutableArray<string> probeIds, IReadOnlyDictionary<Guid, QueryComputerIdentity> identities,
        DateTimeOffset now, bool force = false, Func<Guid, string, bool>? excluded = null, Func<Guid, bool>? inventoryMissing = null) => [.. online.Distinct().Where(id =>
            !Inventory(observations.GetValueOrDefault(id)?.Inventory, now, force) || inventoryMissing?.Invoke(id) == true || probeIds.Any(probe => excluded?.Invoke(id, probe) != true
                && !Probe(probe, probes.ByProbe.GetValueOrDefault(probe)?.GetValueOrDefault(id), identities.GetValueOrDefault(id), now, force)))];
}
