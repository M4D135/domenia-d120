using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

/// <summary>Initializes or migrates on the first explicit stored read, with the native store's backup rules.</summary>
public sealed partial class SqliteDirectoryCache(DomeniaDatabase database) : IPreparedDirectoryCache, IAccueilCache, IObjectDirectoryCache, IFicheCache, IDirectoryDeletionCache, IRelationLocalWriter, IRelationSweepWriter, Domenia.Core.Poste.ILegacySessionCache, Domenia.Core.Poste.IRemoteTaskReadJournal
{
    public async Task<Domenia.Core.Poste.RemoteTaskReadRecord> PrepareTaskReadAsync(Domenia.Core.Poste.RemoteTaskReadPlan plan, CancellationToken cancellationToken)
    { await Database.InitializeAsync(cancellationToken).ConfigureAwait(false); return await Database.PrepareTaskReadAsync(plan, cancellationToken).ConfigureAwait(false); }
    public async Task<Domenia.Core.Poste.RemoteTaskReadRecord> CompleteTaskReadAsync(Guid id, long expectedRevision, Domenia.Core.Poste.RemoteTaskReadCompletion completion, CancellationToken cancellationToken)
    {
        if (await Database.ReadTaskReadAsync(id, cancellationToken).ConfigureAwait(false) is null) { throw new InvalidDataException("Lecture distante non préparée ; base non créée."); }
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.CompleteTaskReadAsync(id, expectedRevision, completion, cancellationToken).ConfigureAwait(false);
    }
    public Task<Domenia.Core.Poste.RemoteTaskReadRecord?> ReadTaskReadAsync(Guid id, CancellationToken cancellationToken) => Database.ReadTaskReadAsync(id, cancellationToken);
    public Task<ImmutableArray<Domenia.Core.Poste.RemoteTaskReadRecord>> PendingTaskReadsAsync(CancellationToken cancellationToken) => Database.PendingTaskReadsAsync(cancellationToken);
    public Task<Domenia.Core.Poste.LegacySessionCacheRead> ReadLegacySessionsAsync(DirectoryComputer computer, CancellationToken cancellationToken) => Database.ReadLegacySessionsAsync(computer, cancellationToken);
    public Task<WritePrecheck> CheckRelationSweepsAsync(RelationSweepWrite request, CancellationToken cancellationToken) => Database.CheckRelationSweepsAsync(request, cancellationToken);
    public Task<WritePrecheck> CheckRelationSweepResetAsync(RelationSweepResetWrite request, CancellationToken cancellationToken) => Database.CheckRelationSweepResetAsync(request, cancellationToken);
    public async Task<RelationSweepResetResult> ResetRelationSweepsAsync(RelationSweepResetWrite request, CancellationToken cancellationToken)
    {
        var check = await Database.CheckRelationSweepResetAsync(request, cancellationToken).ConfigureAwait(false);
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.ResetRelationSweepsAsync(request, cancellationToken).ConfigureAwait(false);
    }
    public async Task<RelationSweepWriteResult> ApplyRelationSweepsAsync(RelationSweepWrite request, CancellationToken cancellationToken)
    {
        var check = await Database.CheckRelationSweepsAsync(request, cancellationToken).ConfigureAwait(false);
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.ApplyRelationSweepsAsync(request, cancellationToken).ConfigureAwait(false);
    }
    public Task<RelationSweepCacheSnapshot> ReadRelationSweepsAsync(CancellationToken cancellationToken) => Database.ReadRelationSweepsAsync(cancellationToken);
    public Task<WritePrecheck> CheckRelationsAsync(RelationStoreWrite request, CancellationToken cancellationToken) => Database.CheckRelationsAsync(request, cancellationToken);
    public async Task<RelationStoreResult> ApplyRelationsAsync(RelationStoreWrite request, CancellationToken cancellationToken)
    {
        var check = await Database.CheckRelationsAsync(request, cancellationToken).ConfigureAwait(false);
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.ApplyRelationsAsync(request, cancellationToken).ConfigureAwait(false);
    }
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
