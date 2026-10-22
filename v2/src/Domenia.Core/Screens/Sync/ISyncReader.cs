using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Search of the local index asked by the page: term, scope, fixed sort, page.</summary>
public sealed record IndexQuery(string Term, SyncScope Scope, IndexSort Sort, bool Descending, int Offset, int Limit);

/// <summary>
/// Estimate asked before a read: target, scope and the limits of this pass (null: the settings of the screen,
/// <see cref="SyncSettings"/>). <see cref="Rebuild"/> asks a complete rebuild of the domain explicitly: the only read that may
/// confirm an empty domain after a checkpoint (Domenia 1 ReplaceAll).
/// </summary>
public sealed record SyncEstimateRequest(SyncTarget Target, SyncScope Scope, long? MaxObjects, int? BudgetSeconds, SyncSettings Settings, bool Rebuild = false);

/// <summary>
/// Reads of the « Synchronisation et base autonome » screen (docs/ops/synchro.md), served by the source of the mode: the
/// simulated local base now, the SQLite base of Domenia and Active Directory with Domenia.Ad (wave 3). Read only by
/// construction: the local reads never touch the network, the directory reads (<see cref="RunReadAsync"/>,
/// <see cref="CheckAbsencesAsync"/>, <see cref="ReadGapsAsync"/>, <see cref="ReadSharedParkAsync"/>) only run after an
/// explicit gesture and keep their result in memory: nothing is stored without its plan (write.execute).
/// </summary>
public interface ISyncReader : IScreenReader
{
    /// <summary>Tiles, coverage, census advice, checkpoint, notices and receipts of the base for the scope (local only).</summary>
    Task<SyncOverview> OverviewAsync(SyncScope scope, SyncSettings settings, CancellationToken cancellationToken);

    /// <summary>
    /// Startup notices on the age of the base and its first construction (Domenia 1 Request-DomeniaIndexAutoRefresh and
    /// Request-DomeniaIndexFirstBuild), read once at startup from the local base only: nothing is ever started from them.
    /// </summary>
    Task<System.Collections.Immutable.ImmutableArray<SyncNotice>> StartupNoticesAsync(SyncSettings settings, CancellationToken cancellationToken);

    /// <summary>One page of the local index (Domenia 1 LocalIndexRead Search): busy base reported, never an empty result.</summary>
    Task<IndexSearchPage> SearchAsync(IndexQuery query, CancellationToken cancellationToken);

    /// <summary>Every row matching the query, sorted, <paramref name="max"/> at most (CSV export).</summary>
    Task<ImmutableArray<IndexHit>> ExportRowsAsync(IndexQuery query, int max, CancellationToken cancellationToken);

    /// <summary>Census advice, census gaps, disappeared objects and snapshots of the domain (local only).</summary>
    Task<SyncControls> ControlsAsync(SyncScope scope, SyncSettings settings, CancellationToken cancellationToken);

    /// <summary>Estimate of a read, kept 15 minutes: nothing is read in the directory here.</summary>
    Task<SyncEstimate> EstimateAsync(SyncEstimateRequest request, CancellationToken cancellationToken);

    /// <summary>
    /// The read of a confirmed estimate (directory read after the gesture): progress pushed by <paramref name="progress"/>,
    /// result kept as a batch for its storage plan. One read at a time.
    /// </summary>
    Task<SyncReadResult> RunReadAsync(string estimateId, Action<SyncProgress> progress, CancellationToken cancellationToken);

    /// <summary>Asks the running read to stop: a request, never a confirmed cancellation (the data read so far stay a partial batch).</summary>
    SyncStop StopRead(string runId);

    /// <summary>Drops a read kept by the engine (« Ignorer cette lecture »): it is no longer offered for storage. Nothing is written.</summary>
    SyncDiscard DiscardRead(string batchId);

    /// <summary>Reads again by GUID, 200 at most, the objects not seen by a complete read (Domenia 1 point 24).</summary>
    Task<AbsenceCheckResult> CheckAbsencesAsync(Action<SyncProgress> progress, CancellationToken cancellationToken);

    /// <summary>Reads by GUID, 200 at most, the identities of the last census missing from the base (Domenia 1 point 22).</summary>
    Task<GapReadResult> ReadGapsAsync(Action<SyncProgress> progress, CancellationToken cancellationToken);

    /// <summary>Compares two snapshots of the same domain and scope, in the base (Domenia 1 SnapshotCompare).</summary>
    Task<SnapshotComparison> CompareSnapshotsAsync(string beforeId, string afterId, CancellationToken cancellationToken);

    /// <summary>Stored park survey and its coverage (Domenia 1 ParkState), read from the base.</summary>
    Task<ParkState> ParkAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Reads and merges the shared park survey (lock file, 12 attempts) without writing it (Domenia 1 ParkSharedSync). A request
    /// during another synchronisation is made after it, never dropped; a lock not obtained or a share out of reach leaves the
    /// work in local and says so.
    /// </summary>
    Task<ParkSharedRead> ReadSharedParkAsync(CancellationToken cancellationToken);
}
