using Domenia.Core;

namespace Domenia.Store;

public sealed partial class SqliteDirectoryCache : ILocalStoreInspection, ISyncLocalStore
{
    public Task<WriteVerification> VerifySyncChangeAsync(WritePlan plan, CancellationToken cancellationToken) => Database.VerifySyncChangeAsync(plan, cancellationToken);
    public Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken cancellationToken)
        => Database.InspectLocalStoreAsync(measure, integrity, cancellationToken);
    public Task<SyncLocalState> ReadSyncStateAsync(CancellationToken cancellationToken) => Database.ReadSyncStateAsync(cancellationToken);
    public Task<IndexSearchPage> SearchSyncIndexAsync(IndexQuery query, CancellationToken cancellationToken) => Database.SearchSyncIndexAsync(query, cancellationToken);
    public Task<WritePrecheck> CheckSyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken) => Database.CheckSyncChangeAsync(change, cancellationToken);
    public async Task<SyncStorageReceipt> ApplySyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken)
    {
        var check = await Database.CheckSyncChangeAsync(change, cancellationToken).ConfigureAwait(false);
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.ApplySyncChangeAsync(change, cancellationToken).ConfigureAwait(false);
    }
}
