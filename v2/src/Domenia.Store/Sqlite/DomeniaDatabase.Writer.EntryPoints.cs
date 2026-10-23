using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<DatabaseInspection> InitializeAsync(CancellationToken cancellationToken) =>
        ObserveWriteAsync("Initialize", new { Operation = "initialisation" }, false, ct => InitializeCoreAsync(ct), cancellationToken);

    public Task<DatabaseBackup> PrepareReadAsync(CancellationToken cancellationToken) =>
        ObserveWriteAsync("PrepareRead", new { Operation = "préparation de lecture" }, false, ct => PrepareReadCoreAsync(ct), cancellationToken);

    public Task<DatabaseBackup> BackupAsync(CancellationToken cancellationToken) =>
        ObserveWriteAsync("Backup", new { Operation = "sauvegarde" }, false, ct => BackupCoreAsync(ct), cancellationToken);

    public Task<DirectoryCommitReceipt> SaveDirectoryAsync(string batchId, DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken, bool preserveCoverage = false) =>
        ObserveWriteAsync("SaveDirectory", new { batchId, snapshot, scope, controller, preserveCoverage }, true, ct => SaveDirectoryCoreAsync(batchId, snapshot, scope, controller, ct, preserveCoverage), cancellationToken);

    public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken) =>
        ObserveWriteAsync("SaveFleet", patch, true, ct => SaveFleetCoreAsync(patch, ct), cancellationToken);

    public Task<FicheLocalRead> SaveFicheAsync(FicheLocalRead fiche, CancellationToken token) =>
        ObserveWriteAsync("SaveFiche", fiche, true, ct => SaveFicheCoreAsync(fiche, ct), token);

    public Task<QueryStoredReadings> SaveQueryResultsAsync(QueryComputerReadings readings, CancellationToken cancellationToken) =>
        ObserveWriteAsync("SaveQueryResults", readings, true, ct => SaveQueryResultsCoreAsync(readings, ct), cancellationToken);

    public Task<OperationsLocalState> UpdateOperationsAsync(long expectedRevision, OperationsLocalState next, CancellationToken cancellationToken) =>
        ObserveWriteAsync("UpdateOperations", new { expectedRevision, next }, false, ct => UpdateOperationsCoreAsync(expectedRevision, next, ct), cancellationToken);

    public Task<QueryStoreWrite?> UpdateQueryLibraryAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken) =>
        ObserveWriteAsync("UpdateQueryLibrary", new { rootKey }, false, ct => UpdateQueryLibraryCoreAsync(rootKey, update, ct), cancellationToken);

    public Task<RemoteTaskReadRecord> PrepareTaskReadAsync(RemoteTaskReadPlan plan, CancellationToken token) =>
        ObserveWriteAsync("PrepareTaskRead", plan, false, ct => PrepareTaskReadCoreAsync(plan, ct), token);

    public Task<RemoteTaskReadRecord> CompleteTaskReadAsync(Guid id, long expectedRevision, RemoteTaskReadCompletion completion, CancellationToken token) =>
        ObserveWriteAsync("CompleteTaskRead", new { id, expectedRevision, completion }, false, ct => CompleteTaskReadCoreAsync(id, expectedRevision, completion, ct), token);

    public Task<RelationStoreResult> ApplyRelationsAsync(RelationStoreWrite request, CancellationToken token) =>
        ObserveWriteAsync("ApplyRelations", request, false, ct => ApplyRelationsCoreAsync(request, ct), token);

    public Task<RelationSweepWriteResult> ApplyRelationSweepsAsync(RelationSweepWrite request, CancellationToken token) =>
        ObserveWriteAsync("ApplyRelationSweeps", request, false, ct => ApplyRelationSweepsCoreAsync(request, ct), token);

    public Task<RelationSweepResetResult> ResetRelationSweepsAsync(RelationSweepResetWrite request, CancellationToken token) =>
        ObserveWriteAsync("ResetRelationSweeps", request, false, ct => ResetRelationSweepsCoreAsync(request, ct), token);

    public Task<DirectoryDeletionLinks> ApplyDeletionAsync(WriteTarget target, DateTimeOffset observedAt, CancellationToken token) =>
        ObserveWriteAsync("ApplyDeletion", new { target, observedAt }, false, ct => ApplyDeletionCoreAsync(target, observedAt, ct), token);

    public Task<SyncStorageReceipt> ApplySyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken) =>
        ObserveWriteAsync("ApplySyncChange", change, false, ct => ApplySyncChangeCoreAsync(change, ct), cancellationToken);

    public Task<WriteOutcome> ApplyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) =>
        ObserveWriteAsync("ApplyStorageRetention", plan, false, ct => ApplyStorageRetentionCoreAsync(plan, ct), cancellationToken);

    public Task<WriteOutcome> ApplyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        ObserveWriteAsync("ApplyStoragePurge", plan, false, ct => ApplyStoragePurgeCoreAsync(plan, ct), cancellationToken);

    public Task<WriteOutcome> ApplyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) =>
        ObserveWriteAsync("ApplyStorageBackup", plan, false, ct => ApplyStorageBackupCoreAsync(plan, ct), cancellationToken);

    internal Task<WriteOutcome> ApplyStorageLegacyAsync(IReadOnlyList<string> roots, WritePlan plan, CancellationToken token) =>
        ObserveWriteAsync("ApplyStorageLegacy", plan, false, ct => ApplyStorageLegacyCoreAsync(roots, plan, ct), token);

}
