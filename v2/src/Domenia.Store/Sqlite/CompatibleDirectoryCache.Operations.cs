using Domenia.Core;
namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : IOperationsLocalStore
{
    public async Task<IDisposable> AcquireOperationsLeaseAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).AcquireOperationsLeaseAsync(cancellationToken).ConfigureAwait(false);
    public async Task<OperationsLocalState> ReadOperationsAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
    public async Task<OperationsLocalState> UpdateOperationsAsync(long expectedRevision, OperationsLocalState next, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).UpdateOperationsAsync(expectedRevision, next, cancellationToken).ConfigureAwait(false);
}
