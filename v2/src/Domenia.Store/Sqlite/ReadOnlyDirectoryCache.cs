using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Store;

/// <summary>Existing local data only: no initialization, migration, backup, or write capability.
/// Each read and the caller's final export guard must still observe the opened store revision.</summary>
public sealed class ReadOnlyDirectoryCache : IObjectDirectoryCache, IAccueilCache, IRelationLocalCache, IQueryLibraryStore
{
    private readonly DomeniaDatabase database;
    private readonly DatabaseInspection opened;

    private ReadOnlyDirectoryCache(DomeniaDatabase database, DatabaseInspection opened)
    { this.database = database; this.opened = opened; }

    public static async Task<ReadOnlyDirectoryCache> OpenAsync(string appFolder, string userFolder, string joinedDomain,
        TimeProvider clock, CancellationToken cancellationToken)
    {
        // The same local path selection as the application, including an explicitly selected/switched database.
        // DatabaseAsync only resolves the path; none of the mutating CompatibleDirectoryCache capabilities escape.
        var database = await new CompatibleDirectoryCache(appFolder, userFolder, joinedDomain, clock)
            .DatabaseAsync(cancellationToken).ConfigureAwait(false);
        var inspection = await database.InspectAsync(cancellationToken).ConfigureAwait(false)
            ?? throw new InvalidDataException("Base locale absente ; aucune base n’a été créée.");
        var cache = new ReadOnlyDirectoryCache(database, inspection);
        if (await cache.ReadKnownAsync(cancellationToken).ConfigureAwait(false) is null)
        { throw new InvalidDataException("Aucun relevé d’annuaire local lisible ; aucune migration n’a été effectuée."); }
        return cache;
    }

    public async Task EnsureUnchangedAsync(CancellationToken cancellationToken)
    {
        var current = await database.InspectAsync(cancellationToken).ConfigureAwait(false);
        if (current is null || current.StoreId != opened.StoreId || !DistinguishedName.AreEqual(current.DomainDn, opened.DomainDn)
            || current.Revision != opened.Revision || current.SchemaVersion != opened.SchemaVersion || current.SchemaRevision != opened.SchemaRevision)
        { throw new InvalidDataException("La base locale a changé pendant la préparation ; relancez le dossier."); }
    }

    private async Task<T> ReadAsync<T>(Func<Task<T>> read, CancellationToken cancellationToken)
    {
        await EnsureUnchangedAsync(cancellationToken).ConfigureAwait(false);
        var value = await read().ConfigureAwait(false);
        await EnsureUnchangedAsync(cancellationToken).ConfigureAwait(false);
        return value;
    }

    public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) =>
        ReadAsync(() => database.ReadDirectoryAsync(cancellationToken), cancellationToken);
    public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken cancellationToken) =>
        ReadAsync(() => database.ReadDirectoryAsync(cancellationToken, allKnown: true), cancellationToken);
    public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) =>
        ReadAsync(() => database.ReadFleetAsync(cancellationToken), cancellationToken);
    public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) =>
        ReadAsync(() => database.ReadFleetHistoryAsync(scope, cancellationToken), cancellationToken);
    public Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken cancellationToken) =>
        ReadAsync(() => database.ReadRelationsAsync(cancellationToken), cancellationToken);
    public Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken cancellationToken) =>
        ReadAsync(() => database.ReadRelationJournalAsync(cancellationToken), cancellationToken);
    public bool Persistent => true;
    Task<byte[]?> IQueryLibraryStore.ReadAsync(string rootKey, CancellationToken cancellationToken) =>
        ReadAsync(() => database.ReadQueryLibraryAsync(rootKey, cancellationToken), cancellationToken);

    private static NotSupportedException ReadOnly() => new("Le dossier hors ligne ne peut pas modifier la base locale.");
    Task IDirectoryCache.SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) => Task.FromException(ReadOnly());
    Task<DirectorySnapshot> IObjectDirectoryCache.SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken cancellationToken) => Task.FromException<DirectorySnapshot>(ReadOnly());
    Task<CachedFleet> IAccueilCache.SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken) => Task.FromException<CachedFleet>(ReadOnly());
    Task<QueryStoreWrite?> IQueryLibraryStore.UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken) => Task.FromException<QueryStoreWrite?>(ReadOnly());
}
