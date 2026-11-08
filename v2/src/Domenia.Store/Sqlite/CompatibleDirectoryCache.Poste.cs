using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : IRelationSweepWriter, ILegacySessionCache, IRemoteTaskReadJournal
{
    public async Task<RelationSweepCacheSnapshot> ReadRelationSweepsAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadRelationSweepsAsync(cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckRelationSweepsAsync(RelationSweepWrite request, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).CheckRelationSweepsAsync(request, cancellationToken).ConfigureAwait(false);
    public async Task<RelationSweepWriteResult> ApplyRelationSweepsAsync(RelationSweepWrite request, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ApplyRelationSweepsAsync(request, cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckRelationSweepResetAsync(RelationSweepResetWrite request, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).CheckRelationSweepResetAsync(request, cancellationToken).ConfigureAwait(false);
    public async Task<RelationSweepResetResult> ResetRelationSweepsAsync(RelationSweepResetWrite request, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ResetRelationSweepsAsync(request, cancellationToken).ConfigureAwait(false);
    public async Task<LegacySessionCacheRead> ReadLegacySessionsAsync(DirectoryComputer computer, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadLegacySessionsAsync(computer, cancellationToken).ConfigureAwait(false);
    public async Task<RemoteTaskReadRecord> PrepareTaskReadAsync(RemoteTaskReadPlan plan, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).PrepareTaskReadAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<RemoteTaskReadRecord> CompleteTaskReadAsync(Guid id, long expectedRevision, RemoteTaskReadCompletion completion, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).CompleteTaskReadAsync(id, expectedRevision, completion, cancellationToken).ConfigureAwait(false);
    public async Task<RemoteTaskReadRecord?> ReadTaskReadAsync(Guid id, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadTaskReadAsync(id, cancellationToken).ConfigureAwait(false);
    public async Task<ImmutableArray<RemoteTaskReadRecord>> PendingTaskReadsAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).PendingTaskReadsAsync(cancellationToken).ConfigureAwait(false);
}
