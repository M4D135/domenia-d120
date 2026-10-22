using System.Collections.Immutable;

namespace Domenia.Core;

// Contract of the « Synchronisation et base autonome » screen (docs/ops/synchro.md). Every record below is serialized as is
// (camelCase, null fields written, enumerations as camelCase text, dates in UTC to the second).

/// <summary>Kind of an object of the local index (Domenia 1 « Utilisateur » and « Machine »).</summary>
public enum IndexObjectType
{
    User,
    Computer,
}

/// <summary>
/// One object of the local base as Domenia keeps it (Domenia 1 table ad_objects): identity, location and the few attributes
/// the base needs, never a secret (the LAPS expiration is a date only). <see cref="Usn"/> and <see cref="WhenChanged"/> come
/// from the controller that answered; <see cref="ObservedAt"/> is the moment of the read that produced the row.
/// </summary>
public sealed record IndexRecord(
    Guid ObjectGuid,
    IndexObjectType Type,
    string Name,
    string? Login,
    string? Upn,
    string? DisplayName,
    string? Description,
    string? Extra,
    bool Enabled,
    string Dn,
    DateTimeOffset? WhenChanged,
    long Usn,
    DateTimeOffset? LastLogon,
    LapsKind Laps,
    DateTimeOffset? LapsExpiration,
    DateTimeOffset ObservedAt);

/// <summary>Scope of the screen: the OU chosen for the updates (or the working OU by default), never silently the domain.</summary>
public sealed record SyncScope(string Dn, string Label, string Path, bool Subtree, bool IsDomain, string Source);

/// <summary>One part of the foot of a tile (enabled and disabled accounts, workstations with or without a user…).</summary>
public sealed record SyncTilePart(string Key, string Label, int Count, Tone Tone);

/// <summary>
/// One of the four tiles of the local base (Domenia 1 DS-09). <see cref="Number"/> is null when unknown, never 0. Every tile
/// has a foot of the same nature: two <see cref="Parts"/> (a distribution), or a <see cref="Gauge"/> from 0 to 1 (freshness of
/// the scope against the census threshold) with its caption.
/// </summary>
public sealed record SyncTile(string Key, string Caption, string Value, int? Number, string Detail, Tone Tone, ImmutableArray<SyncTilePart> Parts, double? Gauge, string? GaugeText);

/// <summary>State of the coverage of a scope by a complete read (Domenia 1 Get-DomeniaFleetFreshness).</summary>
public enum CoverageStatus
{
    Complete,
    Partial,
    UnknownDepth,
    Missing,
}

/// <summary>
/// Committed coverage of a scope: the latest complete read that covers it (itself or an ancestor read with its sub-OUs),
/// the latest attempt that stopped early, and whether a date of the future made the clock doubtful.
/// </summary>
public sealed record SyncCoverage(
    CoverageStatus Status,
    DateTimeOffset? At,
    string? SourceDn,
    string? SourceLabel,
    string? Depth,
    DateTimeOffset? AttemptAt,
    bool Partial,
    bool ClockInvalid,
    string Text);

/// <summary>Census advice of the chosen scope (Domenia 1 Get-DomeniaCensusAdvice): never starts anything.</summary>
public enum CensusState
{
    Recent,
    Due,
    Partial,
    Absent,
    Clock,
    Gap,
}

/// <summary>Census advice; <see cref="GapText"/> names the identities of the census still missing from the base, apart from the advice.</summary>
public sealed record CensusAdvice(CensusState State, bool Due, int? AgeDays, int MaxAgeDays, int GapCount, string Text, Tone Tone, string? GapText);

/// <summary>Directory checkpoint of the base (controller, instance, USN), the reference of the incremental updates.</summary>
public sealed record SyncCheckpoint(string Controller, string InvocationId, long Usn, DateTimeOffset At, int Count, string ScopeDn);

/// <summary>One coverage line of the base (Domenia 1 sync_state): a complete read, or an attempt that stopped early.</summary>
public sealed record SyncScopeState(
    string Key,
    string Label,
    string Dn,
    string Path,
    string Depth,
    DateTimeOffset At,
    bool Attempt,
    bool Partial,
    int Items,
    string? Controller,
    string State,
    string StateLabel,
    Tone Tone,
    string Detail);

public sealed record SyncNotice(Tone Tone, string Text);

/// <summary>Limits of a directory pass (Domenia 1 Index.MaxObjects, Index.BudgetMs and their neighbours).</summary>
public sealed record SyncLimits(
    long MaxObjects,
    int BudgetMs,
    string BudgetText,
    int TimeoutSeconds,
    int FullRebuildDays,
    int StartupDeltaMaxAgeMinutes,
    int PageSize,
    int MaxPageSize,
    int CheckLimit,
    int SnapshotLimit,
    int SnapshotMaxObjects,
    string Source);

/// <summary>Whether a new directory pass may start now, and why not (Domenia 1 Test-DomeniaIndexWriteReady).</summary>
public sealed record SyncReadiness(bool Ready, string? Reason);

/// <summary>
/// State of the storage that admits new collections (Domenia 1 Get-DomeniaStorageCollectionRefusal, points 32 and 35):
/// maintenance of the base, writer suspended after failures, free space of the volume of the base (« unknown » while not
/// measured: nothing is blocked then). <see cref="Refusal"/> is the sentence shown when a new pass must wait.
/// </summary>
public sealed record SyncStorageHealth(string SpaceState, long? FreeBytes, string SpaceText, bool Maintenance, bool WriterSuspended, string? Refusal);

/// <summary>Counters shown on the tabs of the workspaces (objects, coverage lines, disappearances, census gaps, snapshots, park).</summary>
public sealed record SyncWorkspaceCounts(int Objects, int Scopes, int Absences, int AbsencesPending, int Gaps, int Snapshots, int Park);

/// <summary>A read of the directory in progress (shown again when the operator comes back to the screen).</summary>
public sealed record SyncRunInfo(string RunId, string Target, string ScopeLabel, string Phase, string PhaseLabel, DateTimeOffset StartedAt, bool Stopping);

/// <summary>A result of a read kept by the engine until it is stored by its plan, or until it expires (15 minutes).</summary>
public sealed record SyncPendingBatch(string BatchId, string Kind, string Label, int Count, DateTimeOffset ReadAt, DateTimeOffset ExpiresAt);

/// <summary>Storage receipt of one batch written to the base: rows and SHA-256 checked before the commit, then read back.</summary>
public sealed record SyncStorageReceipt(string BatchId, string Kind, string Label, DateTimeOffset At, int Count, string Sha256, bool Verified, string Text);

/// <summary>Verified backup taken before the gestures that change the base (Domenia 1 FI-13).</summary>
public sealed record SyncBackupInfo(DateTimeOffset? LastAt, bool Due, string Text);

/// <summary>Figures of the stored park survey (Domenia 1 Get-DomeniaParkCoverageFigures); -1 machines while unknown.</summary>
public sealed record ParkCoverage(int Machines, int Surveyed, int WithSession, int Dormants, double? Percent, DateTimeOffset? LatestAt, string Text);

/// <summary>Result of synchro.overview.</summary>
public sealed record SyncOverview(
    SyncScope Scope,
    string StoreLabel,
    bool Simulated,
    long Generation,
    int Objects,
    ImmutableArray<SyncTile> Tiles,
    SyncCoverage Coverage,
    ImmutableArray<string> Freshness,
    CensusAdvice Census,
    SyncCheckpoint? Checkpoint,
    ImmutableArray<SyncScopeState> Scopes,
    ImmutableArray<SyncNotice> Notices,
    string? Partial,
    SyncLimits Limits,
    SyncReadiness Readiness,
    SyncRunInfo? Running,
    SyncPendingBatch? Pending,
    ImmutableArray<SyncStorageReceipt> Receipts,
    SyncBackupInfo Backup,
    ParkCoverage Park,
    string Details,
    string Lead,
    DateTimeOffset Now,
    SyncWorkspaceCounts Counts,
    SyncStorageHealth Storage,
    string LapsSchema);

/// <summary>Sort of the local index, chosen by the operator: only these fixed expressions exist (Domenia 1 point 39).</summary>
public enum IndexSort
{
    Relevance,
    Type,
    Name,
    Login,
    Upn,
    State,
    Description,
    Score,
    Reason,
    LastLogon,
    WhenChanged,
}

/// <summary>One row of the local index search (Domenia 1 DgIndex).</summary>
public sealed record IndexHit(
    string Guid,
    IndexObjectType Type,
    string TypeLabel,
    string Name,
    string? Login,
    string? Upn,
    string? DisplayName,
    string? Description,
    string? Extra,
    bool Enabled,
    string StateLabel,
    string Dn,
    string Location,
    string? Association,
    int Score,
    string Reason,
    DateTimeOffset? WhenChanged,
    DateTimeOffset? LastLogon,
    DateTimeOffset? LapsExpiration,
    DateTimeOffset ObservedAt,
    string? LapsState,
    string? LapsText);

/// <summary>Result of synchro.index.search: one page, its total and the page taken from the same state of the base.</summary>
public sealed record IndexSearchPage(
    string Term,
    bool Browse,
    SyncScope Scope,
    IndexSort Sort,
    bool Descending,
    string SortLabel,
    int Offset,
    int Limit,
    int Page,
    int Pages,
    int Total,
    bool HasMore,
    bool Busy,
    long Generation,
    ImmutableArray<IndexHit> Rows,
    string Message);

/// <summary>What became of an object that a complete read did not return (Domenia 1 point 24).</summary>
public enum AbsenceStatus
{
    NotSeen,
    Visible,
    Moved,
    Deleted,
    NotFound,
    Invisible,
    Unconfirmed,
}

/// <summary>One object not seen again by a complete read, with the result of its last verification.</summary>
public sealed record AbsenceRow(
    string Guid,
    AbsenceStatus Status,
    string Label,
    Tone Tone,
    string Name,
    IndexObjectType Type,
    string TypeLabel,
    string LastDn,
    string? FoundDn,
    string Location,
    DateTimeOffset NoticedAt,
    DateTimeOffset? CheckedAt,
    string Detail,
    string ScopeDn,
    string? Server,
    bool InScope);

public sealed record AbsenceCount(AbsenceStatus Status, string Label, int Count, Tone Tone);

/// <summary>Disappeared objects of the domain; <see cref="InScope"/> counts those last seen inside the scope of the screen.</summary>
public sealed record AbsenceList(int Total, ImmutableArray<AbsenceCount> Counts, int Pending, int Shown, bool CanCheck, string Summary, ImmutableArray<AbsenceRow> Rows, int InScope);

/// <summary>An identity the last census of the domain saw in the directory but the base does not hold.</summary>
public sealed record CensusGapRow(string Guid, string Dn, string Name, string Location, DateTimeOffset SeenAt);

public sealed record CensusGapList(int Total, int Shown, bool CanRead, string Summary, ImmutableArray<CensusGapRow> Rows);

/// <summary>Coverage proof kept with a snapshot (Domenia 1 ConvertTo-DomeniaSnapshotCoverage).</summary>
public enum SnapshotCoverageState
{
    Complete,
    Partial,
    Unknown,
    Missing,
}

/// <summary>One dated snapshot of the base for a scope (Domenia 1 point 30).</summary>
public sealed record SnapshotRow(
    string Id,
    string Label,
    string DomainDn,
    string ScopeDn,
    bool Subtree,
    string ScopeText,
    DateTimeOffset CapturedAt,
    int ObjectCount,
    SnapshotCoverageState CoverageState,
    DateTimeOffset? CoverageAt,
    string CoverageText,
    string RowsSha256,
    string Display);

public sealed record SnapshotList(int Count, int Max, int MaxObjects, string Text, string Notice, ImmutableArray<SnapshotRow> Rows);

/// <summary>Result of synchro.controls: census, census gaps, disappeared objects and snapshots of the domain.</summary>
public sealed record SyncControls(SyncScope Scope, CensusAdvice Census, CensusGapList Gaps, AbsenceList Absences, SnapshotList Snapshots, long Generation, DateTimeOffset Now);

/// <summary>Target of a read: the chosen OU with its sub-OUs, or the changes of the whole domain.</summary>
public enum SyncTarget
{
    Ou,
    Domain,
}

/// <summary>How a read will run: one OU, the changes since the checkpoint, or a complete read of the domain.</summary>
public enum SyncReadMode
{
    Ou,
    Incremental,
    Full,
}

/// <summary>Estimate confirmed in the page before any read of the directory (Domenia 1 UX-07).</summary>
public sealed record SyncEstimate(
    string Id,
    SyncTarget Target,
    SyncScope Scope,
    SyncReadMode Mode,
    string ModeLabel,
    string? CheckpointReason,
    int ExpectedObjects,
    int KnownObjects,
    int EstimatedMs,
    string EstimateText,
    long MaxObjects,
    int BudgetMs,
    int TimeoutSeconds,
    SyncBackupInfo Backup,
    ImmutableArray<string> Warnings,
    string ConfirmTitle,
    string ConfirmLabel,
    string ConfirmText,
    bool Ready,
    string? Refusal,
    DateTimeOffset ExpiresAt,
    bool Rebuild,
    bool CanRebuild);

/// <summary>Phase of a read in progress, pushed as « synchro.read.run:progress ».</summary>
public enum SyncPhase
{
    Backup,
    Reading,
    Census,
    Fingerprint,
    Validation,
    Done,
}

public sealed record SyncProgress(string RunId, SyncPhase Phase, string PhaseLabel, int Count, int? Total, double? Rate, int ElapsedMs, double? Percent, string Text);

/// <summary>The limit that cut a pass: volume (Index.MaxObjects), time (Index.BudgetMs), server (ServerTimeLimit), stop or error.</summary>
public sealed record SyncCut(string Reason, long Limit, string Text);

/// <summary>Reconciliation of a read with the base, computed before anything is stored (Domenia 1 IndexBulk).</summary>
public sealed record SyncReconcileCounts(int Added, int Updated, int Moved, int Renamed, int Changed, int Unchanged, int Unseen, int Conflicts, int TotalAfter);

/// <summary>One example line of a reconciliation (names only, no attribute value of the directory beyond the location).</summary>
public sealed record SyncReconcileSample(string Category, string Name, IndexObjectType Type, string Detail);

/// <summary>Result of synchro.read.run: what was read, what storing it would change, and its batch identity.</summary>
public sealed record SyncReadResult(
    string RunId,
    string BatchId,
    SyncTarget Target,
    SyncScope Scope,
    SyncReadMode Mode,
    string ModeLabel,
    bool Complete,
    SyncCut? Cut,
    string Controller,
    string? InvocationId,
    long HighestUsn,
    DateTimeOffset ReadAt,
    int DurationMs,
    int Read,
    int Users,
    int Computers,
    SyncReconcileCounts Reconcile,
    ImmutableArray<SyncReconcileSample> Samples,
    string LapsSchema,
    string? LapsText,
    bool CheckpointAdvances,
    string CheckpointText,
    int CensusGaps,
    string Sha256,
    int RowCount,
    string Summary,
    ImmutableArray<string> Notes,
    bool Storable,
    DateTimeOffset ExpiresAt,
    bool Rebuild);

public sealed record SyncStop(bool Stopping, string Message);

/// <summary>Result of synchro.read.discard: a read kept by the engine and dropped at the operator's request (nothing is written).</summary>
public sealed record SyncDiscard(bool Discarded, string Message);

/// <summary>Visibility of the deleted objects for this account (Domenia 1 DeletedRead).</summary>
public enum DeletedProbe
{
    Read,
    Empty,
    Refused,
    Unavailable,
    NotRequested,
}

/// <summary>Verification of one disappeared object (Domenia 1 Resolve-DomeniaDirectoryAbsence).</summary>
public sealed record AbsenceResolution(string Guid, string Name, AbsenceStatus Status, string Label, Tone Tone, string? FoundDn, string Location, string Proof, string Text);

public sealed record AbsenceCheckResult(
    string BatchId,
    int Checked,
    ImmutableArray<AbsenceCount> Counts,
    DeletedProbe DeletedProbe,
    string DeletedProbeText,
    string Server,
    DateTimeOffset ObservedAt,
    ImmutableArray<AbsenceResolution> Rows,
    string Summary,
    bool Storable,
    DateTimeOffset ExpiresAt);

/// <summary>Read by GUID of one census gap (Domenia 1 New-DomeniaCensusGapStoreRow).</summary>
public sealed record GapResolution(string Guid, string Name, string Status, string Label, Tone Tone, string? FoundDn, string Location, string Text);

public sealed record GapReadResult(string BatchId, int Asked, int Added, int Gone, int Unread, ImmutableArray<GapResolution> Rows, string Summary, bool Storable, DateTimeOffset ExpiresAt);

/// <summary>Nature of one difference between two snapshots.</summary>
public enum SnapshotDiffNature
{
    Added,
    Disappeared,
    Moved,
    Renamed,
    Changed,
}

/// <summary>
/// One difference between two snapshots. <see cref="Before"/> and <see cref="After"/> are readable (a location for an
/// addition, a disappearance or a move, a value for a changed field); the DNs stay in <see cref="BeforeDn"/> and <see cref="AfterDn"/>.
/// </summary>
public sealed record SnapshotDiffRow(SnapshotDiffNature Nature, string NatureLabel, string Name, string Guid, string Detail, string? Before, string? After, string? BeforeDn, string? AfterDn);

/// <summary>
/// Exact totals of a comparison. <see cref="Distinct"/> is the union of the two snapshots (common, added, disappeared);
/// a common object can be moved and changed at once, so <see cref="Moved"/> + <see cref="Renamed"/> + <see cref="Changed"/>
/// may exceed <see cref="Differing"/>.
/// </summary>
public sealed record SnapshotDiffCounts(int Added, int Disappeared, int Common, int Differing, int Unchanged, int Moved, int Renamed, int Changed, int Distinct);

public sealed record SnapshotComparison(
    SnapshotRow Before,
    SnapshotRow After,
    bool Comparable,
    ImmutableArray<string> Reasons,
    ImmutableArray<string> Warnings,
    SnapshotDiffCounts Counts,
    int Limit,
    bool Truncated,
    ImmutableArray<SnapshotDiffRow> Rows,
    ImmutableArray<string> Summary,
    string Notice,
    string Headline,
    string Overlap);

/// <summary>Status of one workstation in the park survey (Domenia 1 park_state.status).</summary>
public enum ParkStatus
{
    Session,
    Empty,
    Unreachable,
    Refused,
    Error,
}

/// <summary>One workstation of the stored park survey: last probe, status, user seen, attempts (Domenia 1 park_state).</summary>
public sealed record ParkEntry(string Computer, DateTimeOffset LastProbe, ParkStatus Status, string? User, int Attempts, string? ProbedBy);

public sealed record ParkRow(string Key, string Computer, DateTimeOffset LastProbe, ParkStatus Status, string StatusLabel, Tone Tone, string? User, int Attempts, string? ProbedBy);

public sealed record ParkShared(bool Configured, string? Path, DateTimeOffset? LastSyncAt, string Text, bool CanSync);

/// <summary>
/// Stored park survey (Domenia 1 ParkState). <see cref="Deferred"/> counts the workstation results that arrived while the
/// stored state was read again: they were applied after it, so their attempt counters start from the stored ones.
/// </summary>
public sealed record ParkState(ParkCoverage Coverage, ImmutableArray<ParkRow> Rows, ParkShared Shared, long Generation, int Deferred, string? DeferredText, DateTimeOffset Now);

/// <summary>One workstation where the shared survey and the local one differ, and which line wins (the most recent).</summary>
public sealed record ParkMergeRow(string Computer, DateTimeOffset? Local, DateTimeOffset? Shared, string Winner, string Detail);

/// <summary>
/// Result of a read of the shared park survey (Domenia 1 ParkSharedSync). <see cref="Outcome"/> is « merged » (lock obtained,
/// merged in memory), « lockBusy » (lock not obtained after 12 attempts: work in local, new attempt at <see cref="RetryAt"/>)
/// or « unreachable » (share not reachable: work in local, noted in the Parc journal). <see cref="Queued"/> says the request
/// arrived during another synchronisation and was made after it. <see cref="BatchId"/> is empty when nothing can be stored.
/// </summary>
public sealed record ParkSharedRead(
    string BatchId,
    string Path,
    int Received,
    int Added,
    int Updated,
    int Kept,
    int Total,
    bool Locked,
    int LockAttempts,
    ImmutableArray<ParkMergeRow> Rows,
    string Text,
    bool Storable,
    DateTimeOffset ExpiresAt,
    string Outcome,
    bool Reachable,
    bool Queued,
    DateTimeOffset? RetryAt);

/// <summary>A CSV written by the screen (Exports folder), or prepared only when the mode keeps everything in memory.</summary>
public sealed record SyncExport(bool Written, string? Path, string FileName, int Rows, string Sha256, string Text);
