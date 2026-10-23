using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Identity of an explicit read awaiting confirmation in this process; never a replay instruction.</summary>
public sealed record SyncBatchHeader(string Id, string Label, string SessionId, long Epoch, DateTimeOffset At, DateTimeOffset Expires,
    string StoreId, string DomainDn, long Revision, string BeforeSha256, SyncStateEntry? Coverage,
    int Rows, int Absences, int ResolvedGaps);

public sealed record SyncStagedBatch(SyncBatchHeader Header, ImmutableArray<IndexRecord> Rows,
    ImmutableArray<AbsenceRecord> Absences, ImmutableArray<Guid> ResolvedGaps);

/// <summary>A bounded local JSONL file held open until confirmation, discard, expiry, or source closure.</summary>
public interface ISyncBatchLease : IDisposable
{
    SyncBatchHeader Header { get; }
    long Bytes { get; }
    string Sha256 { get; }
    Task<SyncStagedBatch> ReadAsync(CancellationToken cancellationToken);
}

public interface ISyncBatchSpool
{
    Task<ISyncBatchLease> StageSyncBatchAsync(SyncStagedBatch batch, CancellationToken cancellationToken);
}
