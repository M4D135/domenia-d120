using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStoragePurge
{
    public async Task<WritePlanDraft> PrepareStoragePurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string previewFingerprint, CancellationToken cancellationToken)
    {
        var snapshot = await InspectLocalStoreAsync(false, false, cancellationToken).ConfigureAwait(false);
        StorageWritePlans.EnsureWritable(snapshot);
        if (snapshot.Maintenance.Locked || snapshot.Writer.Active)
            throw new DomeniaOperationException(StorageWritePlans.StoreUnavailable, "Maintenance ou enregistrement en attente : aucune purge préparée.");
        return await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).PrepareStoragePurgeAsync(categories, historyDays, previewFingerprint, cancellationToken).ConfigureAwait(false);
    }
    public async Task<WritePrecheck> CheckStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).CheckStoragePurgeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteOutcome> ApplyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).ApplyStoragePurgeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteVerification> VerifyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).VerifyStoragePurgeAsync(plan, cancellationToken).ConfigureAwait(false);
}
