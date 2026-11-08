using Domenia.Core;

namespace Domenia.Store;

public sealed partial class SqliteDirectoryCache : IDirectoryBranchCache
{
    public Task<DirectoryBranch?> ReadBranchAsync(string dn, CancellationToken cancellationToken) => Database.ReadBranchAsync(dn, cancellationToken);
    public async Task<DirectoryBranch> SaveBranchAsync(DirectoryBranch branch, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.SaveBranchAsync(branch, cancellationToken).ConfigureAwait(false);
    }
}
