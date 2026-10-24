using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>The legacy TSV deliberately carries names, never certified AD identities.</summary>
public sealed record SharedParkLine(string Computer, DateTimeOffset At, string Status, string? User, int Attempts, string? ProbedBy);

/// <summary>
/// The compact, immutable reference a preview leaves behind: what was read and what was measured, never the payload itself. It binds
/// the source epoch, the canonical TSV path, the store and domain identities, the local revision AND the local header generation,
/// whether the local survey exists and whether the base is inherited, the exhaustive rows fingerprint and the local logical
/// fingerprint, whether the shared TSV exists and the SHA of its bytes, the lease creation and expiration instants, the merged row
/// count, the exact proposed byte count and the SHA of the proposed bytes, and the added/replaced counters of the merge. It carries
/// no bytes, no array, no serialized payload and no spool path: the proposed bytes stay behind the held lease handle and must be
/// re-read explicitly. <see cref="LocalFingerprint"/> is the local logical fingerprint (store/domain/revision/generation/legacy over
/// the exhaustive rows fingerprint), while <see cref="RemoteSha256"/> and <see cref="ProposedSha256"/> are byte hashes of the shared
/// and of the proposed content — the two families of names never mix. This is a bound preview, never a plan authorized to write and
/// never a proof of a database re-read or of a CAS: the caller must still re-read and re-qualify everything before any publication.
/// </summary>
public sealed record SharedParkBatch(string Id, string SessionId, long Epoch, string Path, string StoreId, string DomainDn,
    long Revision, long Generation, bool LocalExists, bool Legacy, string RowsFingerprint, string LocalFingerprint,
    bool RemoteExists, string RemoteSha256, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, int MergedRows,
    long PayloadBytes, string ProposedSha256, int Added, int Replaced);

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

    /// <summary>
    /// Deterministic over every compact scalar, so the same reference always hashes the same and any change of an Exists flag, of the
    /// epoch, session, generation or of any SHA changes it — an absent survey is never folded onto a present empty one that would
    /// share the same empty SHA. It is a binding of the described read, never a proof of a physical re-read or of a CAS.
    /// </summary>
    public static string Fingerprint(SharedParkBatch batch)
    {
        ArgumentNullException.ThrowIfNull(batch);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n',
            "domenia.sharedpark.batch.v1", batch.Id, batch.SessionId,
            batch.Epoch.ToString(CultureInfo.InvariantCulture), batch.Path, batch.StoreId, batch.DomainDn,
            batch.Revision.ToString(CultureInfo.InvariantCulture), batch.Generation.ToString(CultureInfo.InvariantCulture),
            batch.LocalExists ? "local:oui" : "local:non", batch.Legacy ? "herite" : "natif",
            batch.RowsFingerprint, batch.LocalFingerprint,
            batch.RemoteExists ? "distant:oui" : "distant:non", batch.RemoteSha256,
            batch.CreatedAt.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture),
            batch.ExpiresAt.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture),
            batch.MergedRows.ToString(CultureInfo.InvariantCulture),
            batch.PayloadBytes.ToString(CultureInfo.InvariantCulture), batch.ProposedSha256,
            batch.Added.ToString(CultureInfo.InvariantCulture), batch.Replaced.ToString(CultureInfo.InvariantCulture)))));
    }

    /// <summary>The one mapping of the stored words, shared with the base survey: the TSV never certifies an identity it did not receive.</summary>
    public static ParkStatus Status(string value) => SyncPark.StoredStatus(value);
    public static ParkEntry Entry(SharedParkLine line) => new(line.Computer, line.At, Status(line.Status), line.User, line.Attempts, line.ProbedBy);
}
