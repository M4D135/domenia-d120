using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

/// <summary>Initializes or migrates on the first explicit stored read, with the native store's backup rules.</summary>
public sealed class SqliteDirectoryCache(DomeniaDatabase database) : IPreparedDirectoryCache, IAccueilCache
{
    public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) => Database.ReadFleetHistoryAsync(scope, cancellationToken);

    public DomeniaDatabase Database { get; } = database;
    public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Database.ReadDirectoryAsync(cancellationToken);

    public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) => Database.ReadFleetAsync(cancellationToken);

    public async Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.SaveFleetAsync(patch, cancellationToken).ConfigureAwait(false);
    }

    public async Task<DirectoryBackupReceipt> PrepareAsync(CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        var backup = await Database.PrepareReadAsync(cancellationToken).ConfigureAwait(false);
        return new(Database.StoreId, backup.Sha256, backup.At);
    }

    public async Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        await Database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), snapshot, scope, controller, cancellationToken).ConfigureAwait(false);
    }
}
