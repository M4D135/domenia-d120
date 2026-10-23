using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>The original storage key and bounded projection fingerprint remain distinct from the semantic relation key.</summary>
public sealed record CachedRelation(string StorageKey, string StorageFingerprint, StoredRelation Relation);
public sealed record RelationCacheSnapshot(string StoreId, string DomainDn, long Revision, ImmutableArray<CachedRelation> Rows,
    long Total, int Rejected, int UncertainDates, bool Truncated, string Notice)
{
    public static RelationCacheSnapshot Empty(string storeId, string domainDn) => new(storeId, domainDn, 0, [], 0, 0, 0, false, "Aucune association enregistrée.");
}
public sealed record RelationJournalCache(ImmutableArray<RelationJournalRecord> Entries, int Rejected, int Foreign, bool Truncated, string Notice)
{
    public bool LegacyReadable { get; init; } = true;
}

/// <summary>Local, read-only view of existing associations. Reading never assigns an identity from a namesake or migrates a file.</summary>
public interface IRelationLocalCache
{
    Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken cancellationToken);
    Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken cancellationToken);
}

/// <summary>A bounded prepared write. Expected rows retain their physical keys and raw fingerprints; records must match the sealed plan.</summary>
public sealed record RelationStoreWrite(string StoreId, WritePlan Plan, ImmutableArray<CachedRelation> Expected, ImmutableArray<RelationChangeItem> Items);
public sealed record RelationStoreResult(int Applied, int AlreadyDone, long Revision, int JournalPending, string Notice);
public interface IRelationLocalWriter : IRelationLocalCache
{
    Task<WritePrecheck> CheckRelationsAsync(RelationStoreWrite request, CancellationToken cancellationToken);
    Task<RelationStoreResult> ApplyRelationsAsync(RelationStoreWrite request, CancellationToken cancellationToken);
}
