using Domenia.Core;

namespace Domenia.Store;

/// <summary>Initializes or migrates on the first explicit stored read, with the native store's backup rules.</summary>
public sealed class SqliteDirectoryCache(DomeniaDatabase database) : IDirectoryCache
{
    public DomeniaDatabase Database { get; } = database;
    public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Database.ReadDirectoryAsync(cancellationToken);

    public async Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        await Database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), snapshot, scope, controller, cancellationToken).ConfigureAwait(false);
    }
}
