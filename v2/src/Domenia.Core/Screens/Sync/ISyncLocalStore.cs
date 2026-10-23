using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>One consistent, read-only transaction over the legacy-compatible local index.</summary>
public sealed record SyncLocalState(string StoreId, string DomainDn, long Revision, bool Available,
    ImmutableArray<IndexRecord> Rows, ImmutableArray<SyncStateEntry> Scopes, ImmutableArray<AbsenceRecord> Absences,
    ImmutableArray<CensusGapRecord> Gaps, ImmutableArray<SnapshotRecord> Snapshots,
    ImmutableArray<SyncStorageReceipt> Receipts, DateTimeOffset? BackupAt)
{
    public RelationSweepCacheSnapshot? Park { get; init; }
}

/// <summary>A closed local mutation bound to the exact reviewed base and to a sealed operator plan.</summary>
public sealed record SyncLocalChange(string StoreId, long ExpectedRevision, string BeforeSha256, WritePlan Plan,
    ImmutableArray<IndexRecord> Rows, SyncStateEntry? Coverage, ImmutableArray<AbsenceRecord> Absences,
    ImmutableArray<Guid> ResolvedGaps, SnapshotRecord? Capture, string? DeleteSnapshot)
{
    public bool ResetPark { get; init; }
}

public interface ISyncLocalStore
{
    Task<SyncLocalState> ReadSyncStateAsync(CancellationToken cancellationToken);
    Task<IndexSearchPage> SearchSyncIndexAsync(IndexQuery query, CancellationToken cancellationToken);
    Task<WritePrecheck> CheckSyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken);
    Task<SyncStorageReceipt> ApplySyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken);
    Task<WriteVerification> VerifySyncChangeAsync(WritePlan plan, CancellationToken cancellationToken);
}

public static class SyncLocalIdentity
{
    public const string StateAttribute = "local.state";
    public const string PayloadAttribute = "local.payload";
    public static string StateValue(SyncLocalChange change) => change.StoreId + "|" + change.ExpectedRevision.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + change.BeforeSha256;
    public static string PayloadFingerprint(SyncLocalChange change) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new
    {
        change.StoreId, change.ExpectedRevision, change.BeforeSha256, change.Rows, change.Coverage,
        change.Absences, change.ResolvedGaps, change.Capture, change.DeleteSnapshot, change.ResetPark,
    })));
    public static string Target(string storeId, string domainDn) => "DomeniaSync:" + storeId + ":" + domainDn;
    public static string Fingerprint(SyncLocalState state) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
    {
        state.StoreId, state.DomainDn, state.Revision, state.Available,
        Park = state.Park is { } park ? new { park.Fingerprint, park.Generation, park.Total, park.Rejected, park.Truncated } : null,
        Rows = state.Rows.OrderBy(x => x.ObjectGuid), Scopes = state.Scopes.OrderBy(x => x.Key, StringComparer.Ordinal),
        Absences = state.Absences.OrderBy(x => x.ObjectGuid), Gaps = state.Gaps.OrderBy(x => x.ObjectGuid),
        Snapshots = state.Snapshots.OrderBy(x => x.Id, StringComparer.Ordinal),
    }))));
}
