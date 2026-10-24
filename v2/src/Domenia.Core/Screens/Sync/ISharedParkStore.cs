using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>The legacy TSV deliberately carries names, never certified AD identities.</summary>
public sealed record SharedParkLine(string Computer, DateTimeOffset At, string Status, string? User, int Attempts, string? ProbedBy);
public sealed record SharedParkBatch(string Id, string Path, string StoreId, string DomainDn, long Revision,
    string LocalSha256, string RemoteSha256, bool RemoteExists, ImmutableArray<SharedParkLine> Local,
    ImmutableArray<SharedParkLine> Remote, ImmutableArray<SharedParkLine> Merged, int LockAttempts);
public interface ISharedParkStore
{
    Task<string?> SharedParkPathAsync(CancellationToken cancellationToken);
    Task<SharedParkBatch> ReadSharedParkAsync(CancellationToken cancellationToken);
    Task<WritePrecheck> CheckSharedParkAsync(SharedParkBatch batch, CancellationToken cancellationToken);
    Task<WriteOutcome> ApplySharedParkAsync(SharedParkBatch batch, WritePlan plan, CancellationToken cancellationToken);
    Task<WriteVerification> VerifySharedParkAsync(WritePlan plan, CancellationToken cancellationToken);
}

public static class SharedParkIdentity
{
    public const string PayloadAttribute = "park.shared.payload";
    public const string PathAttribute = "park.shared.path";
    public static string Fingerprint(SharedParkBatch batch) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(batch)));
    /// <summary>The one mapping of the stored words, shared with the base survey: the TSV never certifies an identity it did not receive.</summary>
    public static ParkStatus Status(string value) => SyncPark.StoredStatus(value);
    public static ParkEntry Entry(SharedParkLine line) => new(line.Computer, line.At, Status(line.Status), line.User, line.Attempts, line.ProbedBy);
}
