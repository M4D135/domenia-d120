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
    public ImmutableDictionary<Guid, WorkstationSessionMemory> WorkstationSessions { get; init; } = ImmutableDictionary<Guid, WorkstationSessionMemory>.Empty;
    public ImmutableDictionary<Guid, ImmutableDictionary<string, PosteDetailMemory>> WorkstationDetails { get; init; } = ImmutableDictionary<Guid, ImmutableDictionary<string, PosteDetailMemory>>.Empty;

    public static CachedFleet Empty(string storeId) => new(FleetObservations.Empty, AccueilFacts.Empty(storeId), ProbeReadings.Empty);

    public CachedFleet Merge(FleetCachePatch patch)
    {
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
                Memory = MemoryUsageFact.Latest(old.Memory, next.Memory),
            });
        }
        var bitlocker = Facts.BitLocker.ToList();
        foreach (var next in patch.BitLocker)
        {
            var index = bitlocker.FindIndex(p => ScopeRules.SameScope(new(p.ScopeDn, "", p.Subtree), new(next.ScopeDn, "", next.Subtree)));
            var dated = next with { Machines = next.Machines.ToImmutableDictionary(p => p.Key,
                p => p.Value with { ObservedAt = p.Value.ObservedAt ?? next.At }) };
            if (index < 0) { bitlocker.Add(dated); }
            else
            {
                var previous = bitlocker[index];
                var merged = previous.Machines.ToImmutableDictionary(p => p.Key,
                    p => p.Value with { ObservedAt = p.Value.ObservedAt ?? previous.At });
                foreach (var (id, fact) in dated.Machines)
                    if (!merged.TryGetValue(id, out var old) || fact.ObservedAt >= old.ObservedAt) merged = merged.SetItem(id, fact);
                bitlocker[index] = (next.At >= previous.At ? dated : previous) with { Machines = merged };
            }
        }
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
        var sessions = WorkstationSessions;
        foreach (var (id, next) in patch.WorkstationSessions) { sessions = sessions.SetItem(id, PosteSessionCache.Merge(sessions.GetValueOrDefault(id), next)); }
        var details = WorkstationDetails;
        foreach (var (id, incoming) in patch.WorkstationDetails)
        {
            var previous = details.GetValueOrDefault(id, ImmutableDictionary<string, PosteDetailMemory>.Empty);
            foreach (var (family, memory) in incoming) previous = previous.SetItem(family, PosteDetailCache.Merge(previous.GetValueOrDefault(family), memory));
            details = details.SetItem(id, previous);
        }
        return new(Observations.Merge(patch.Observations), Facts with { Machines = machines, BitLocker = [.. bitlocker] }, Probes.Merge(patch.Probes))
        { Addresses = addresses, Inventories = inventories, WorkstationProbes = detailed, WorkstationSecrets = secrets, WorkstationSessions = sessions, WorkstationDetails = details };
    }
}

public sealed record FleetCachePatch(FleetObservations Observations, ImmutableDictionary<Guid, MachineFacts> Machines, ImmutableArray<BitLockerPresence> BitLocker, ProbeReadings Probes)
{
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public CollectionWriteContext? CollectionContext { get; init; }

    public ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>> Addresses { get; init; } = ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>>.Empty;
    public ImmutableDictionary<Guid, InventorySnapshot> Inventories { get; init; } = ImmutableDictionary<Guid, InventorySnapshot>.Empty;
    public ImmutableDictionary<Guid, ProbeStore> WorkstationProbes { get; init; } = ImmutableDictionary<Guid, ProbeStore>.Empty;
    public ImmutableDictionary<Guid, WorkstationSecretMetadata> WorkstationSecrets { get; init; } = ImmutableDictionary<Guid, WorkstationSecretMetadata>.Empty;
    public ImmutableDictionary<Guid, WorkstationSessionMemory> WorkstationSessions { get; init; } = ImmutableDictionary<Guid, WorkstationSessionMemory>.Empty;
    public ImmutableDictionary<Guid, ImmutableDictionary<string, PosteDetailMemory>> WorkstationDetails { get; init; } = ImmutableDictionary<Guid, ImmutableDictionary<string, PosteDetailMemory>>.Empty;

    public static FleetCachePatch Empty { get; } = new(FleetObservations.Empty, ImmutableDictionary<Guid, MachineFacts>.Empty, [], ProbeReadings.Empty);
}

public interface IAccueilCache
{
    Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken);
    Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken);
    Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken);
}
