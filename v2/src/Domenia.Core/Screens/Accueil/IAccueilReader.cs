using System.Collections.Immutable;

namespace Domenia.Core.Accueil;

/// <summary>
/// Facts of one workstation that the directory snapshot does not carry: user seen in the console session, BIOS version read
/// by a probe, and the state of the WMI answer, kept apart from the ping (point 72).
/// </summary>
public sealed record MachineFacts(
    string? ConsoleUser,
    DateTimeOffset? ConsoleAt,
    string? BiosVersion,
    DateTimeOffset? BiosAt,
    MeasureState WmiState,
    DateTimeOffset? WmiAt,
    string? WmiError);

/// <summary>
/// Local facts of the fleet of the session (local base in directory mode, derived data in simulation): per workstation facts,
/// readings set aside (content unreadable or another AD identity), recorded OU collections, the number of user/workstation
/// associations, the identity of the local base and the BitLocker presence reads it keeps (joined by GUID, Domenia 1 ACC-032).
/// </summary>
public sealed record AccueilFacts(
    ImmutableDictionary<Guid, MachineFacts> Machines,
    int RejectedObservations,
    ImmutableArray<CollectionRun> Runs,
    int Associations,
    string StoreId,
    ImmutableArray<BitLockerPresence> BitLocker)
{
    public static AccueilFacts Empty(string storeId) => new(ImmutableDictionary<Guid, MachineFacts>.Empty, 0, [], 0, storeId, []);
}

/// <summary>Presence of the BitLocker recovery objects of one workstation: their number and the date of the newest (never a key).</summary>
public sealed record BitLockerFact(int Keys, DateTimeOffset? Newest);

/// <summary>
/// Result of one BitLocker presence read of an OU (Domenia 1, BitLockerPresence): counts and dates only, never
/// msFVE-RecoveryPassword nor msFVE-KeyPackage. <see cref="ClassPresent"/> false: the recovery class is absent from the schema.
/// </summary>
public sealed record BitLockerPresence(
    string ScopeDn,
    bool Subtree,
    DateTimeOffset At,
    bool ClassPresent,
    bool Truncated,
    ImmutableDictionary<Guid, BitLockerFact> Machines);

/// <summary>
/// Read interface of the home page (docs/ops/accueil.md). Read only by construction. Served by the simulation now
/// (SimulatedAccueilReader, derived data) and by Domenia.Ad and the local base later (vague 3).
/// </summary>
public interface IAccueilReader : IScreenReader
{
    /// <summary>Local facts of the fleet (local base): never the network.</summary>
    Task<AccueilFacts> FactsAsync(CancellationToken cancellationToken);

    /// <summary>Daily local snapshots of the fleet figures of an OU, oldest first (fleet_snapshots of the local base).</summary>
    Task<ImmutableArray<FleetSnapshot>> HistoryAsync(ScopeSelection scope, CancellationToken cancellationToken);

    /// <summary>
    /// Presence of the BitLocker recovery objects of an OU: NetworkRead in directory mode (paged search under the OU, 500 per
    /// page, 100 000 objects at most), after an explicit gesture; never the domain root.
    /// </summary>
    Task<BitLockerPresence> ReadBitLockerAsync(ScopeSelection scope, CancellationToken cancellationToken);

    /// <summary>
    /// Reads the given probes on the active workstations of an OU that answered the presence check: NetworkRead in directory
    /// mode (WMI/CIM, bounded budgets), part of the explicit refresh of the OU. Probes flagged NoDC are never read on a domain
    /// controller.
    /// </summary>
    Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> probeIds, ScopeSelection scope, IReadOnlyCollection<Guid> online, CancellationToken cancellationToken);

    /// <summary>
    /// Reads the inventory (WMI/CIM) again on the given active workstations of an OU only: the ones that answered the ping of the
    /// same refresh and still need a reading (ACC-004, ACC-038). NetworkRead in directory mode, part of the explicit refresh of the
    /// OU; never the domain root. Returns the new local state; the other workstations keep their earlier reading and its date.
    /// </summary>
    Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken cancellationToken);
}
