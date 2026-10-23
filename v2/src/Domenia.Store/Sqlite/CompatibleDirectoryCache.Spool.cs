using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ISyncBatchSpool
{
    public async Task<ISyncBatchLease> StageSyncBatchAsync(SyncStagedBatch batch, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).StageSyncBatchAsync(batch, cancellationToken).ConfigureAwait(false);
}

public sealed partial class SqliteDirectoryCache : ISyncBatchSpool
{
    public Task<ISyncBatchLease> StageSyncBatchAsync(SyncStagedBatch batch, CancellationToken cancellationToken) =>
        Task.Run<ISyncBatchLease>(() => SyncBatchFile.Stage(Database, batch, cancellationToken), cancellationToken);
}
