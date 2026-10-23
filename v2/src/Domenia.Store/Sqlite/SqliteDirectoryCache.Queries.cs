using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class SqliteDirectoryCache : IQueryResultsStore, IQueryLibraryStore
{
    public bool Persistent => true;
    public Task<QueryStoredReadings> ReadQueryResultsAsync(CancellationToken cancellationToken) => Database.ReadQueryResultsAsync(cancellationToken);
    public async Task<QueryStoredReadings> SaveQueryResultsAsync(QueryComputerReadings readings, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.SaveQueryResultsAsync(readings, cancellationToken).ConfigureAwait(false);
    }
    Task<byte[]?> IQueryLibraryStore.ReadAsync(string rootKey, CancellationToken cancellationToken) => Database.ReadQueryLibraryAsync(rootKey, cancellationToken);
    async Task<QueryStoreWrite?> IQueryLibraryStore.UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.UpdateQueryLibraryAsync(rootKey, update, cancellationToken).ConfigureAwait(false);
    }
}
