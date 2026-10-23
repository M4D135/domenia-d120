using System.Collections.Immutable;
using Domenia.Core.Poste;

namespace Domenia.Core.Accueil;

/// <summary>Typed local readings, separate from the AD object cache and from UI preferences.</summary>
public sealed record CachedFleet(FleetObservations Observations, AccueilFacts Facts, ProbeReadings Probes)
{
    public ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>> Addresses { get; init; } = ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>>.Empty;
    public ImmutableDictionary<Guid, InventorySnapshot> Inventories { get; init; } = ImmutableDictionary<Guid, InventorySnapshot>.Empty;
    public ImmutableDictionary<Guid, ProbeStore> WorkstationProbes { get; init; } = ImmutableDictionary<Guid, ProbeStore>.Empty;
    public ImmutableDictionary<Guid, WorkstationSecretMetadata> WorkstationSecrets { get; init; } = ImmutableDictionary<Guid, WorkstationSecretMetadata>.Empty;

    public static CachedFleet Empty(string storeId) => new(FleetObservations.Empty, AccueilFacts.Empty(storeId), ProbeReadings.Empty);

    public CachedFleet Merge(FleetCachePatch patch)
    {
        var observations = Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        foreach (var next in patch.Observations.Workstations)
        {
            if (!observations.TryGetValue(next.ComputerGuid, out var old)) { observations[next.ComputerGuid] = next; continue; }
            var presence = next.Presence.CheckedAt >= old.Presence.CheckedAt || old.Presence.CheckedAt is null ? next.Presence : old.Presence;
            var inventory = next.Inventory.CheckedAt >= old.Inventory.CheckedAt || old.Inventory.CheckedAt is null ? next.Inventory : old.Inventory;
            // Keep a recent successful payload during a failed attempt; MachineFacts retains that attempt and its reason.
            if (old.Inventory.HasReading && !inventory.HasReading && inventory.CheckedAt - old.Inventory.CheckedAt <= TimeSpan.FromMinutes(15)) { inventory = old.Inventory; }
            observations[next.ComputerGuid] = new(next.ComputerGuid, presence, inventory);
        }
        var machines = Facts.Machines;
        foreach (var (id, next) in patch.Machines)
        {
            if (!machines.TryGetValue(id, out var old)) { machines = machines.SetItem(id, next); continue; }
            var newest = next.WmiAt >= old.WmiAt || old.WmiAt is null ? next : old;
            // Missing fields in an unsuccessful attempt do not erase the last dated observation.
            machines = machines.SetItem(id, newest with
            {
                ConsoleUser = next.ConsoleAt >= old.ConsoleAt || old.ConsoleAt is null ? next.ConsoleUser : old.ConsoleUser,
                ConsoleAt = next.ConsoleAt >= old.ConsoleAt || old.ConsoleAt is null ? next.ConsoleAt : old.ConsoleAt,
                BiosVersion = next.BiosAt >= old.BiosAt || old.BiosAt is null ? next.BiosVersion : old.BiosVersion,
                BiosAt = next.BiosAt >= old.BiosAt || old.BiosAt is null ? next.BiosAt : old.BiosAt,
            });
        }
        var bitlocker = Facts.BitLocker.ToList();
        foreach (var next in patch.BitLocker)
        {
            var index = bitlocker.FindIndex(p => ScopeRules.SameScope(new(p.ScopeDn, "", p.Subtree), new(next.ScopeDn, "", next.Subtree)));
            if (index < 0) { bitlocker.Add(next); }
            else if (next.At >= bitlocker[index].At) { bitlocker[index] = next; }
        }
        var at = patch.Observations.TakenAt >= Observations.TakenAt || Observations.TakenAt is null ? patch.Observations.TakenAt : Observations.TakenAt;
        var addresses = Addresses;
        foreach (var (id, next) in patch.Addresses)
        {
            if (!addresses.TryGetValue(id, out var old) || next.Max(a => a.ObservedAt) >= old.Max(a => a.ObservedAt)) { addresses = addresses.SetItem(id, next); }
        }
        var inventories = Inventories;
        foreach (var (id, next) in patch.Inventories)
        {
            if (!inventories.TryGetValue(id, out var old) || next.CollectedAt >= old.CollectedAt) { inventories = inventories.SetItem(id, next); }
        }
        var detailed = WorkstationProbes;
        foreach (var (id, next) in patch.WorkstationProbes)
        { detailed = detailed.SetItem(id, PosteProbeCache.Merge(detailed.GetValueOrDefault(id), next)); }
        var secrets = WorkstationSecrets;
        foreach (var (id, next) in patch.WorkstationSecrets) { secrets = secrets.SetItem(id, PosteSecretCache.Merge(secrets.GetValueOrDefault(id), next)); }
        return new(new(at, [.. observations.Values]), Facts with { Machines = machines, BitLocker = [.. bitlocker] }, Probes.Merge(patch.Probes))
        { Addresses = addresses, Inventories = inventories, WorkstationProbes = detailed, WorkstationSecrets = secrets };
    }
}

public sealed record FleetCachePatch(FleetObservations Observations, ImmutableDictionary<Guid, MachineFacts> Machines, ImmutableArray<BitLockerPresence> BitLocker, ProbeReadings Probes)
{
    public ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>> Addresses { get; init; } = ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>>.Empty;
    public ImmutableDictionary<Guid, InventorySnapshot> Inventories { get; init; } = ImmutableDictionary<Guid, InventorySnapshot>.Empty;
    public ImmutableDictionary<Guid, ProbeStore> WorkstationProbes { get; init; } = ImmutableDictionary<Guid, ProbeStore>.Empty;
    public ImmutableDictionary<Guid, WorkstationSecretMetadata> WorkstationSecrets { get; init; } = ImmutableDictionary<Guid, WorkstationSecretMetadata>.Empty;

    public static FleetCachePatch Empty { get; } = new(FleetObservations.Empty, ImmutableDictionary<Guid, MachineFacts>.Empty, [], ProbeReadings.Empty);
}

public interface IAccueilCache
{
    Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken);
    Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken);
    Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken);
}
