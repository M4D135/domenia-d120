using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>One original D1 park_state row. A legacy name without a GUID never proves the identity of a current computer.</summary>
public sealed record RelationSweepRecord(string StorageKey, string StorageFingerprint, string Computer, Guid? ComputerGuid,
    string? ComputerDn, DateTimeOffset? At, string Status, string? UserLogin, int Attempts)
{
    public string PreservedFingerprint { get; init; } = "";
}
public sealed record RelationSweepCacheSnapshot(string StoreId, string DomainDn, ImmutableArray<RelationSweepRecord> Rows,
    long Total, int Rejected, int UncertainDates, bool Truncated, string Fingerprint, string Notice)
{
    public long Generation { get; init; }
}

public sealed record RelationSweepUpdate(Guid ComputerGuid, string ComputerDn, string Computer, DateTimeOffset At, string Status, string? UserLogin);
public sealed record RelationSweepWrite(string StoreId, string BatchId, long Generation, ImmutableArray<RelationSweepUpdate> Updates);
public sealed record RelationSweepWriteResult(int Updated, int Ignored, long Generation, long Revision, bool AlreadyRecorded, string Detail);
public sealed record RelationSweepResetWrite(string StoreId, WritePlan Plan, long Generation);
public sealed record RelationSweepResetResult(int Forgotten, long Generation, long Revision, bool AlreadyApplied, string BackupPath, string BackupSha256);

/// <summary>Read-only, bounded compatibility view of the D1 sweep memory. Opening a view never migrates the base.</summary>
public interface IRelationSweepCache
{
    Task<RelationSweepCacheSnapshot> ReadRelationSweepsAsync(CancellationToken cancellationToken);
}

/// <summary>Bounded native readings only; generation prevents a late reading from resurrecting memory cleared in the meantime.</summary>
public interface IRelationSweepWriter : IRelationSweepCache
{
    Task<WritePrecheck> CheckRelationSweepsAsync(RelationSweepWrite request, CancellationToken cancellationToken);
    Task<RelationSweepWriteResult> ApplyRelationSweepsAsync(RelationSweepWrite request, CancellationToken cancellationToken);
    Task<WritePrecheck> CheckRelationSweepResetAsync(RelationSweepResetWrite request, CancellationToken cancellationToken);
    Task<RelationSweepResetResult> ResetRelationSweepsAsync(RelationSweepResetWrite request, CancellationToken cancellationToken);
}
