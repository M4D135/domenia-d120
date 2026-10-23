using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

/// <summary>Initializes or migrates on the first explicit stored read, with the native store's backup rules.</summary>
public sealed class SqliteDirectoryCache(DomeniaDatabase database) : IPreparedDirectoryCache, IAccueilCache, IObjectDirectoryCache, IFicheCache, IDirectoryDeletionCache, IRelationLocalCache
{
    public Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken cancellationToken) => Database.ReadRelationsAsync(cancellationToken);
    public Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken cancellationToken) => Database.ReadRelationJournalAsync(cancellationToken);
    public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) => Database.ReadFleetHistoryAsync(scope, cancellationToken);

    public DomeniaDatabase Database { get; } = database;

    public Task<DirectoryDeletionLinks> CountDeletionLinksAsync(WriteTarget target, CancellationToken cancellationToken) => Database.CountDeletionLinksAsync(target, cancellationToken);
    public async Task<DirectoryDeletionLinks> ApplyDeletionAsync(WriteTarget target, DateTimeOffset observedAt, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.ApplyDeletionAsync(target, observedAt, cancellationToken).ConfigureAwait(false);
    }

    public Task<FicheLocalRead?> ReadFicheAsync(string dn, CancellationToken cancellationToken) => Database.ReadFicheAsync(dn, cancellationToken);
    public Task<ImmutableArray<FicheSummary>> ReadFicheIndexAsync(CancellationToken cancellationToken) => Database.ReadFicheIndexAsync(cancellationToken);
    public async Task<FicheLocalRead> SaveFicheAsync(FicheLocalRead fiche, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.SaveFicheAsync(fiche, cancellationToken).ConfigureAwait(false);
    }
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

    public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken cancellationToken) => Database.ReadDirectoryAsync(cancellationToken, allKnown: true);

    public async Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        var scope = new ScopeSelection(objects.Domain.RootDn, objects.Domain.DnsName, true);
        await Database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), objects with { Complete = false }, scope, controller, cancellationToken, preserveCoverage: true).ConfigureAwait(false);
        return await ReadKnownAsync(cancellationToken).ConfigureAwait(false) ?? throw new InvalidDataException("Projection absente après stockage du relevé.");
    }

    public async Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken)
    {
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        await Database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), snapshot, scope, controller, cancellationToken).ConfigureAwait(false);
    }
}
