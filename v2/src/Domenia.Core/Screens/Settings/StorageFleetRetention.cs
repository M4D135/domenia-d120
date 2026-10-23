using System.Collections.Immutable;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>Visits each independently dated native measure once; a caller decides which reviewed identities may leave.</summary>
public static class StorageFleetRetention
{
    public static CachedFleet Transform(CachedFleet fleet, Func<string, string, DateTimeOffset?, bool> remove)
    {
        ArgumentNullException.ThrowIfNull(fleet); ArgumentNullException.ThrowIfNull(remove);
        var observations = fleet.Observations.Workstations.Select(x => x with
        {
            Presence = remove("presence:" + x.ComputerGuid, "presence", x.Presence.CheckedAt) ? PresenceMeasure.Unread : x.Presence,
            Inventory = remove("inventory:" + x.ComputerGuid, "inventory", x.Inventory.CheckedAt) ? InventoryMeasure.Unread : x.Inventory,
        }).ToImmutableArray();
        var machines = fleet.Facts.Machines.ToImmutableDictionary(x => x.Key, x =>
        {
            var m = x.Value;
            if (remove("console:" + x.Key, "console", m.ConsoleAt)) { m = m with { ConsoleUser = null, ConsoleAt = null }; }
            if (remove("bios:" + x.Key, "inventory", m.BiosAt)) { m = m with { BiosVersion = null, BiosAt = null }; }
            if (remove("wmi:" + x.Key, "inventory", m.WmiAt)) { m = m with { WmiState = MeasureState.NotRead, WmiAt = null, WmiError = null }; }
            return m;
        });
        var probes = fleet.Probes.ByProbe.ToImmutableDictionary(x => x.Key,
            x => x.Value.Where(p => !remove("probe:" + x.Key + ":" + p.Key, "probe", p.Value.At)).ToImmutableDictionary(), StringComparer.Ordinal);
        return fleet with
        {
            Observations = fleet.Observations with { Workstations = observations },
            Facts = fleet.Facts with { Machines = machines },
            Probes = new(probes),
            Addresses = fleet.Addresses.Where(x => !remove("address:" + x.Key, "inventory", Latest(x.Value.Select(v => v.ObservedAt), requireAll: true))).ToImmutableDictionary(),
            Inventories = fleet.Inventories.Where(x => !remove("details:" + x.Key, "inventory", x.Value.CollectedAt)).ToImmutableDictionary(),
            WorkstationProbes = fleet.WorkstationProbes.Where(x => !remove("workstationProbe:" + x.Key, "detail", ProbeDate(x.Value))).ToImmutableDictionary(),
            WorkstationSessions = fleet.WorkstationSessions.Where(x => !remove("sessions:" + x.Key, "console", Latest([x.Value.Latest.At, x.Value.LastComplete?.At], false))).ToImmutableDictionary(),
        };
    }

    private static DateTimeOffset? ProbeDate(ProbeStore probe)
    {
        if (probe.Probes.Any(x => x.State != ProbeState.NotRead && x.LastAttempt is null && x.LastSuccess is null && x.DataAt is null)) { return null; }
        return Latest(probe.Probes.SelectMany(x => new[] { x.LastAttempt, x.LastSuccess, x.DataAt })
            .Concat(probe.Values.Values.Select(x => (DateTimeOffset?)x.At))
            .Concat(probe.SystemVolumeHistory.Select(x => (DateTimeOffset?)x.At))
            .Concat(probe.MonitorHistory.Select(x => (DateTimeOffset?)x.At)).Append(probe.CollectedAt).Append(probe.MonitorAt), false);
    }
    private static DateTimeOffset? Latest(IEnumerable<DateTimeOffset?> values, bool requireAll)
    {
        var dates = values.ToArray();
        return requireAll && dates.Any(x => x is null) ? null : dates.Max();
    }
}
