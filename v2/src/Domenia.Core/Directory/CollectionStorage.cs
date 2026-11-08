namespace Domenia.Core;

/// <summary>Cheap admission facts of the active database, without scanning its tables or starting a collection.</summary>
public interface ICollectionStorage
{
    Task<CollectionStorageState> CollectionStorageAsync(CancellationToken token);

    /// <summary>Drain admission needs queue bytes only, without a disk probe that would bypass the real writer's failure accounting.</summary>
    async Task<long> PendingStorageBytesAsync(CancellationToken token) => (await CollectionStorageAsync(token).ConfigureAwait(false)).Space.QueuedBytes;
}

public sealed record CollectionStorageState(LocalStoreSpace Space, bool Maintenance, bool Suspended, int Failures, string? Fault);

public static class CollectionStorageRules
{
    public const string InsufficientSpace = "StorageInsufficientSpace";
    public const string Unavailable = "storage.collectionSuspended";

    /// <summary>Saturating reserve: corrupt or extreme queue sizes can never wrap around into permission to collect.</summary>
    public static long Reserve(long baseline, long queued) => queued > (long.MaxValue - baseline) / 4
        ? long.MaxValue : baseline + 4 * Math.Max(0, queued);

    public static void Ensure(CollectionStorageState state, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (state.Maintenance || state.Suspended || state.Failures >= SyncCoverageRules.WriterFailureLimit)
            throw new DomeniaOperationException(Unavailable, state.Fault ?? "Stockage local suspendu ou en maintenance : aucune nouvelle collecte. Consultez Base locale.");
        var space = LocalStoreRules.Space(state.Space, now, zone);
        if (space.BlocksCollections) throw new DomeniaOperationException(InsufficientSpace, space.Text);
    }
}
