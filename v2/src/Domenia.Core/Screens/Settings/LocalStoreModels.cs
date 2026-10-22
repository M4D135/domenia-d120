using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Storage policy of the local base (Domenia 1 Storage.PolicyJson, ConvertTo-DomeniaStoragePolicy): automatic backup and
/// retention per measure family. Saving it never deletes anything: retention only applies after its preview and the
/// operator's confirmation.
/// </summary>
public sealed record StoragePolicy(
    bool AutomaticBackup,
    int BackupHours,
    int BackupKeep,
    int PresenceDays,
    int ConsoleDays,
    int InventoryDays,
    int ProbeDays,
    int DetailDays,
    int LinkHistoryDays);

/// <summary>A retention family (Get-DomeniaStorageRetentionFamilies): what is lost when its old measures leave.</summary>
public sealed record RetentionFamily(string Family, string PolicyKey, string Label, bool Compaction, string Loss);

/// <summary>One category of rows of the base (Observations, Snapshots, History, Index, ManualLinks, Secrets).</summary>
public sealed record LocalStoreCategory(string Id, string Label, long Rows, long? Bytes);

/// <summary>
/// Ages of the rows of a measure family: <see cref="DayCounts"/>[n] rows are n days old (the last cell holds every older
/// row). For the association history, <see cref="Repeated"/> counts the repeated identical observations (the only ones a
/// compaction removes) the same way.
/// </summary>
public sealed record LocalStoreFamily(string Family, ImmutableArray<int> DayCounts, ImmutableArray<int> Repeated);

/// <summary>Counts of a base as an inspection reports them (Format-DomeniaStorageContent): unknown stays null.</summary>
public sealed record LocalStoreCounts(long? Objects, long? Measures, long? Details, long? Associations, long? Queries, long? Receipts);

/// <summary>One verified copy of the base (Domenia 1 StorageBackup receipt).</summary>
public sealed record LocalStoreBackup(
    string Id,
    string FileName,
    DateTimeOffset At,
    long Bytes,
    string Sha256,
    bool Verified,
    DateTimeOffset? VerifiedAt,
    string Kind,
    int PreferenceKeys,
    long Revision,
    LocalStoreCounts Counts);

/// <summary>Last measure of the free space of the volume of the base (none until « Mesurer »).</summary>
public sealed record LocalStoreSpace(long? FreeBytes, DateTimeOffset? MeasuredAt, long QueuedBytes);

/// <summary>State of the single writer of the base (Domenia 1 persistence state).</summary>
public sealed record LocalStoreWriter(bool Unavailable, bool Suspended, int Pending, long QueuedChanges, long QueuedBytes, int Failures, int Conflicts, DateTimeOffset? LastSavedAt, string? Fault);

/// <summary>
/// Maintenance state of the base (Domenia 1 Get-DomeniaStorageMaintenanceControlState inputs): a drain or a running step
/// blocks everything; a lock with a target is an interrupted switch; a recovery is a base proven unreadable.
/// </summary>
public sealed record LocalStoreMaintenance(
    bool Locked,
    bool Draining,
    string? Job,
    bool Recovery,
    bool RecoveryReceipt,
    string? TargetPath,
    bool CanUndo,
    string? PreviousPath);

/// <summary>One measured read of the usage measure (Format-DomeniaStorageReadProbes).</summary>
public sealed record LocalStoreReadProbe(string Name, long Rows, double Milliseconds, string Plan);

/// <summary>Result of the usage measure (StorageUsage worker), kept for the session.</summary>
public sealed record LocalStoreUsage(DateTimeOffset MeasuredAt, long DatabaseBytes, long WalBytes, bool DbstatAvailable, ImmutableArray<LocalStoreCategory> Categories, ImmutableArray<LocalStoreReadProbe> Probes, long DurationMilliseconds);

/// <summary>One check of the integrity report (StorageIntegrity worker): Ok, Warning, Failed or Unknown.</summary>
public sealed record LocalStoreCheck(string Id, string Status, string? Detail);

/// <summary>Integrity report (read only): every check once; « Défaut » points to the restore assistant.</summary>
public sealed record LocalStoreIntegrity(DateTimeOffset CheckedAt, long DurationMilliseconds, bool Readable, ImmutableArray<LocalStoreCheck> Checks);

/// <summary>One cached perimeter of the base (Get-DomeniaCacheCatalogRows input).</summary>
public sealed record LocalStoreScope(string Scope, string Source, string Controller, string Reader, long Rows, DateTimeOffset? ObservedAt);

/// <summary>One part of the Domenia 1 data found for the takeover (improvement of PAR-028).</summary>
public sealed record LegacyItem(string Id, string Label, long Count, string Detail, bool Imported);

/// <summary>Domenia 1 data found on this workstation for the takeover, and what was already taken.</summary>
public sealed record LegacySource(bool Found, string Location, string Domain, DateTimeOffset? ReadAt, ImmutableArray<LegacyItem> Items, DateTimeOffset? ImportedAt, ImmutableArray<string> Refusals);

/// <summary>
/// Snapshot of the local base of the mode, as the reader of the screen sees it. In simulation it is a fictitious base kept in
/// memory (never a SQLite file, SIMULATION.md § 1); <see cref="Available"/> is false while the mode has no base.
/// </summary>
public sealed record LocalStoreSnapshot(
    bool Available,
    bool Simulated,
    string Domain,
    string PathLabel,
    string StoreId,
    long Revision,
    string Schema,
    long DatabaseBytes,
    long WalBytes,
    DateTimeOffset? LastWriteAt,
    LocalStoreCounts Counts,
    ImmutableArray<LocalStoreCategory> Categories,
    ImmutableArray<LocalStoreFamily> Families,
    ImmutableArray<LocalStoreBackup> Backups,
    LocalStoreSpace Space,
    LocalStoreWriter Writer,
    LocalStoreMaintenance Maintenance,
    LocalStoreUsage? Usage,
    LocalStoreIntegrity? Integrity,
    ImmutableArray<LocalStoreScope> Scopes,
    LegacySource Legacy,
    ImmutableArray<LocalStoreExport> Exports,
    string? LastFailure,
    DateTimeOffset? LastFailureAt);

/// <summary>A copy of a backup published to a file chosen by the operator (PAR-035).</summary>
public sealed record LocalStoreExport(string Destination, DateTimeOffset At, string Sha256, long Bytes);

/// <summary>Facts of the simulation shown by the « Démonstration » section (never in directory mode).</summary>
public sealed record SimulationFacts(
    ulong Seed,
    DateTimeOffset Reference,
    string TimeZone,
    bool Weekend,
    bool RealisticLatency,
    string Domain,
    string Controller,
    string Operator,
    int OrganizationalUnits,
    int Users,
    int Computers,
    int Groups,
    long OverlayVersion,
    int OverlayChangedObjects,
    int PresenceRound,
    string Fingerprint);
