using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>The original storage key and bounded projection fingerprint remain distinct from the semantic relation key.</summary>
public sealed record CachedRelation(string StorageKey, string StorageFingerprint, StoredRelation Relation);
public sealed record RelationCacheSnapshot(string StoreId, string DomainDn, long Revision, ImmutableArray<CachedRelation> Rows,
    long Total, int Rejected, int UncertainDates, bool Truncated, string Notice)
{
    public static RelationCacheSnapshot Empty(string storeId, string domainDn) => new(storeId, domainDn, 0, [], 0, 0, 0, false, "Aucune association enregistrée.");
}
public sealed record RelationJournalCache(ImmutableArray<RelationJournalRecord> Entries, int Rejected, int Foreign, bool Truncated, string Notice);

/// <summary>Local, read-only view of existing associations. Reading never assigns an identity from a namesake or migrates a file.</summary>
public interface IRelationLocalCache
{
    Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken cancellationToken);
    Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken cancellationToken);
}
