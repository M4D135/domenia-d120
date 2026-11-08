using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase : ICollectionStorage
{
    internal DateTimeOffset Now => clock.GetUtcNow();
    public Task<CollectionStorageState> CollectionStorageAsync(CancellationToken token) => Task.Run(() => ReadCollectionStorage(token), token);

    public Task<long> PendingStorageBytesAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var health = Health;
        lock (health.Gate) return Task.FromResult(checked(health.WaitingBytes + health.ActiveBytes + health.Held.Sum(x => x.Bytes)));
    }

    private CollectionStorageState ReadCollectionStorage(CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); CompatibleDirectoryCache.ValidateLocalPath(Path);
        var free = FreeSpaceProbe?.Invoke() ?? new DriveInfo(System.IO.Path.GetPathRoot(Path)!).AvailableFreeSpace;
        var health = Health;
        lock (health.Gate)
        {
            var now = clock.GetUtcNow(); health.FreeBytes = free; health.SpaceAt = now;
            var queued = checked(health.WaitingBytes + health.ActiveBytes + health.Held.Sum(x => x.Bytes));
            return new CollectionStorageState(new(free, now, queued), File.Exists(StorageWriteFence.Marker(Path)),
                health.Suspended, health.Failures, health.Fault);
        }
    }
}

public sealed partial class SqliteDirectoryCache : ICollectionStorage
{
    public Task<long> PendingStorageBytesAsync(CancellationToken token) => Database.PendingStorageBytesAsync(token);
    public Task<CollectionStorageState> CollectionStorageAsync(CancellationToken token) => Database.CollectionStorageAsync(token);
}

public sealed partial class CompatibleDirectoryCache : ICollectionStorage
{
    public async Task<long> PendingStorageBytesAsync(CancellationToken token)
        => await (await DatabaseAsync(token).ConfigureAwait(false)).PendingStorageBytesAsync(token).ConfigureAwait(false);
    public async Task<CollectionStorageState> CollectionStorageAsync(CancellationToken token)
    {
        // Re-read the marker even when this instance already holds a cache: another process may have switched it.
        var state = ReadSwitchState();
        var db = await DatabaseAsync(token).ConfigureAwait(false);
        var read = await db.CollectionStorageAsync(token).ConfigureAwait(false);
        var pending = state is not null && (SwitchPending(state) || !string.Equals(db.Path, state.ActivePath, StringComparison.OrdinalIgnoreCase));
        return pending ? read with { Maintenance = true, Fault = "Bascule de base à terminer : aucune nouvelle collecte. Consultez Base locale." } : read;
    }
}
