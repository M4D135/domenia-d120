using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>One original D1 park_state row. A legacy name without a GUID never proves the identity of a current computer.</summary>
public sealed record RelationSweepRecord(string StorageKey, string StorageFingerprint, string Computer, Guid? ComputerGuid,
    string? ComputerDn, DateTimeOffset? At, string Status, string? UserLogin, int Attempts);
public sealed record RelationSweepCacheSnapshot(string StoreId, string DomainDn, ImmutableArray<RelationSweepRecord> Rows,
    long Total, int Rejected, int UncertainDates, bool Truncated, string Fingerprint, string Notice);

/// <summary>Read-only, bounded compatibility view of the D1 sweep memory. Opening a view never migrates the base.</summary>
public interface IRelationSweepCache
{
    Task<RelationSweepCacheSnapshot> ReadRelationSweepsAsync(CancellationToken cancellationToken);
}
