using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStoreInspection, ISyncLocalStore
{
    public async Task<WriteVerification> VerifySyncChangeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).VerifySyncChangeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken cancellationToken) =>
        await WithLegacySourcesAsync(WithSwitchState(await (await CacheAsync(cancellationToken).ConfigureAwait(false)).InspectLocalStoreAsync(measure, integrity, cancellationToken).ConfigureAwait(false)), cancellationToken).ConfigureAwait(false);
    public async Task<SyncLocalState> ReadSyncStateAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
    public async Task<IndexSearchPage> SearchSyncIndexAsync(IndexQuery query, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SearchSyncIndexAsync(query, cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckSyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).CheckSyncChangeAsync(change, cancellationToken).ConfigureAwait(false);
    public async Task<SyncStorageReceipt> ApplySyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ApplySyncChangeAsync(change, cancellationToken).ConfigureAwait(false);
}
