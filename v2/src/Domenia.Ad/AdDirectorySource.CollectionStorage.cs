using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource : ICollectionStorage
{
    public async Task<CollectionStorageState> CollectionStorageAsync(CancellationToken token)
    {
        CollectionStorageState state = new(new(null, null, 0), false, false, 0, null);
        try { if (LocalStore is ICollectionStorage storage) state = await storage.CollectionStorageAsync(token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidDataException or ArgumentException or System.Security.SecurityException)
        {
            return new(new(null, null, 0), true, false, 0,
                "Stockage local non vérifiable (" + ex.GetType().Name + ") : aucune nouvelle collecte. Consultez Base locale.");
        }
        lock (gate) { return localMaintenanceRequested || localMaintenance ? state with { Maintenance = true } : state; }
    }

    internal async Task EnsureCollectionStorageAsync(CancellationToken token) =>
        CollectionStorageRules.Ensure(await CollectionStorageAsync(token).ConfigureAwait(false), Clock.GetUtcNow(), Zone);
}
