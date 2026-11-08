using System.Collections.Immutable;
using Domenia.Core.Queries;

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
    string? WmiError)
{
    /// <summary>A single dated OS reading; installed RAM and separately read free RAM must never be mixed.</summary>
    public MemoryUsageFact? Memory { get; init; }
}

/// <summary>Win32_OperatingSystem physical memory, both fields in KB from the same completed instance.</summary>
public sealed record MemoryUsageFact(long VisibleKb, long FreeKb, DateTimeOffset At)
{
    public bool IsValid => VisibleKb > 0 && FreeKb >= 0 && FreeKb <= VisibleKb && At != default;
    public double? UsedPercent => IsValid ? 100.0 * (VisibleKb - FreeKb) / VisibleKb : null;
    public static MemoryUsageFact? Read(long? visibleKb, long? freeKb, DateTimeOffset at) =>
        visibleKb is > 0 && freeKb is >= 0 && freeKb <= visibleKb && at != default ? new(visibleKb.Value, freeKb.Value, at) : null;
    public static MemoryUsageFact? Latest(MemoryUsageFact? previous, MemoryUsageFact? next) =>
        next is { IsValid: true } && (previous is not { IsValid: true } || next.At >= previous.At) ? next
            : previous is { IsValid: true } ? previous : null;
}

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
public sealed record BitLockerFact(int Keys, DateTimeOffset? Newest)
{
    public DateTimeOffset? ObservedAt { get; init; }
}

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

    /// <summary>Previously committed probe values; never starts a workstation read.</summary>
    Task<ProbeReadings> StoredProbesAsync(CancellationToken cancellationToken) => Task.FromResult(ProbeReadings.Empty);

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

    /// <summary>Confirmed campaign identities and epoch must survive the boundary down to the native probe.</summary>
    Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> probeIds, ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets,
        long expectedEpoch, CancellationToken cancellationToken) => throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable,
            "Ce lecteur ne qualifie pas les identités figées des sondes ; aucune collecte.");

    /// <summary>Exact profile definitions, validated before any provider is contacted. Older readers may serve built-ins only.</summary>
    Task<ProbeReadings> CollectFrozenProbesAsync(ImmutableArray<FrozenProbe> probes, ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets,
        long expectedEpoch, CancellationToken cancellationToken)
    {
        PersonalProbeCatalog.Validate(probes);
        if (probes.Any(p => PersonalProbeCatalog.IsKey(p.Key)))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Ce lecteur ne prend pas en charge les définitions personnelles figées ; aucune collecte."); }
        return CollectProbesAsync([.. probes.Select(p => p.Key)], scope, targets, expectedEpoch, cancellationToken);
    }

    /// <summary>
    /// Reads the inventory (WMI/CIM) again on the given active workstations of an OU only: the ones that answered the ping of the
    /// same refresh and still need a reading (ACC-004, ACC-038). NetworkRead in directory mode, part of the explicit refresh of the
    /// OU; never the domain root. Returns the new local state; the other workstations keep their earlier reading and its date.
    /// </summary>
    Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken cancellationToken);
    /// <summary>Confirmed plan only: exact identities and connection generation, never expands to new objects of the OU.</summary>
    Task<DirectoryState> ReadPresenceAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken cancellationToken);
    Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken cancellationToken);

}

/// <summary>Explicit retry bypasses only the short failure cache; identity and account guards still apply.</summary>
public interface IAccueilProbeRetryReader
{
    Task<ProbeReadings> RetryFrozenProbesAsync(ImmutableArray<FrozenProbe> probes, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token);
}
