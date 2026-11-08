using Domenia.Core;

namespace Domenia.Store;

// The application injects this deferred cache, not SqliteDirectoryCache directly.
public sealed partial class CompatibleDirectoryCache : IDirectoryBranchCache
{
    public async Task<DirectoryBranch?> ReadBranchAsync(string dn, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadBranchAsync(dn, cancellationToken).ConfigureAwait(false);
    public async Task<DirectoryBranch> SaveBranchAsync(DirectoryBranch branch, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveBranchAsync(branch, cancellationToken).ConfigureAwait(false);
}
