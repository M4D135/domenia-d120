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

/// <summary>
/// Annex of the preferences joined to a backup made from the interface (Domenia 1 PAR-034, Domenia.BackupPreferences.1):
/// the approved preferences of the moment (never the connection identity, the window of this workstation nor a secret),
/// bound to the SHA-256 of the copy it goes with. <see cref="Json"/> is the canonical document of the values;
/// <see cref="Sha256"/> its own fingerprint.
/// </summary>
public sealed record BackupPreferences(string Format, string DatabaseSha256, DateTimeOffset CreatedAt, int Keys, string Sha256, string Json);

/// <summary>One verified copy of the base (Domenia 1 StorageBackup receipt), with its last batch, its last measure and its annex.</summary>
public sealed record LocalStoreBackup(
    string Id,
    string FileName,
    DateTimeOffset At,
    long Bytes,
    string Sha256,
    bool Verified,
    DateTimeOffset? VerifiedAt,
    string Kind,
    long Revision,
    LocalStoreCounts Counts,
    DateTimeOffset? LastMeasureAt,
    BackupPreferences? Preferences)
{
    /// <summary>Approved preferences joined to the copy (0 without an annex).</summary>
    public int PreferenceKeys => Preferences?.Keys ?? 0;
}

/// <summary>Last measure of the free space of the volume of the base (none until « Mesurer »).</summary>
public sealed record LocalStoreSpace(long? FreeBytes, DateTimeOffset? MeasuredAt, long QueuedBytes);

/// <summary>
/// State of the single writer of the base (Domenia 1 persistence state): <see cref="Active"/> while a batch is being saved,
/// <see cref="Suspended"/> after three failures or a lack of space (Fail-DomeniaStorageWork), with what is still in memory.
/// </summary>
public sealed record LocalStoreWriter(bool Unavailable, bool Suspended, bool Active, int Pending, long QueuedChanges, long QueuedBytes, int Failures, int Conflicts, DateTimeOffset? LastSavedAt, string? Fault);

/// <summary>Rows of one table of the base (closed identifiers of the purge targets), as the last inspection counted them.</summary>
public sealed record LocalStoreTable(string Table, long Rows);

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

/// <summary>
/// One part of the Domenia 1 base (or of its settings file) found for the takeover: how many rows it holds, how many of them
/// Domenia 2 already holds (<see cref="Present"/>), and the rule that applies. Rules: « emptyOnly » (taken only into an empty
/// table of Domenia 2, never merged), « addMissing » (rows absent from Domenia 2 added, existing ones never replaced),
/// « history » (closed history kept read only, never replayed).
/// </summary>
public sealed record LegacyPart(string Id, string Label, string Target, long Rows, long Present, string Rule);

/// <summary>The local base of Domenia 1 found on this workstation, as a read-only inspection reports it (schema, revision, domain).</summary>
public sealed record LegacyDatabase(string Name, string Path, string? SchemaVersion, string? Revision, string? Domain, long Bytes, ImmutableArray<LegacyPart> Parts);

/// <summary>
/// A file of the older version found for the takeover (Domenia 1 Read-DomeniaLegacySource): objets.tsv, parc.tsv,
/// recherches.tsv, secrets-etat.tsv or the workstation-user links. <see cref="Locked"/>: read under a shared lock (nobody
/// could write it during the read); <see cref="Domains"/>: domains of its DN column (objects only).
/// </summary>
public sealed record LegacyFile(string Kind, string Path, long Bytes, long Rows, int Rejected, int Duplicates, string Sha256, ImmutableArray<string> Domains, bool Locked);

/// <summary>
/// Data of Domenia 1 found on this workstation for the takeover (PAR-028, ARCHITECTURE.md § 6): its local base (schema 11),
/// its settings file, the files of the older version, the rows of the target tables of Domenia 2, the marker of the
/// sources (SHA-256 of their kinds, paths and hashes) and the marker of the takeover already applied, if any.
/// </summary>
public sealed record LegacySource(
    bool Found,
    string Location,
    string Domain,
    DateTimeOffset? ReadAt,
    LegacyDatabase? Database,
    ImmutableArray<LegacyPart> Settings,
    ImmutableArray<LegacyFile> Files,
    ImmutableDictionary<string, long> TargetRows,
    string Marker,
    string? AppliedMarker,
    DateTimeOffset? ImportedAt);

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
    ImmutableArray<LocalStoreTable> Tables,
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

/// <summary>A copy of a backup published to a file chosen by the operator (PAR-035), with the backup it copies.</summary>
public sealed record LocalStoreExport(string Destination, DateTimeOffset At, string Sha256, long Bytes, string BackupId);

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
    string Fingerprint,
    string TimeZoneLabel);
