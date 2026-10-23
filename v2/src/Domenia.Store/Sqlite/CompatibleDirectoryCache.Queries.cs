using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : IQueryResultsStore, IQueryLibraryStore
{
    public bool Persistent => true;
    public async Task<QueryStoredReadings> ReadQueryResultsAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadQueryResultsAsync(cancellationToken).ConfigureAwait(false);
    public async Task<QueryStoredReadings> SaveQueryResultsAsync(QueryComputerReadings readings, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveQueryResultsAsync(readings, cancellationToken).ConfigureAwait(false);
    async Task<byte[]?> IQueryLibraryStore.ReadAsync(string rootKey, CancellationToken cancellationToken) =>
        await ((IQueryLibraryStore)await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadAsync(rootKey, cancellationToken).ConfigureAwait(false);
    async Task<QueryStoreWrite?> IQueryLibraryStore.UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken) =>
        await ((IQueryLibraryStore)await CacheAsync(cancellationToken).ConfigureAwait(false)).UpdateAsync(rootKey, update, cancellationToken).ConfigureAwait(false);
}
