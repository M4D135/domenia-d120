using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStorageRetention
{
    public async Task<WritePlanDraft> PrepareStorageRetentionAsync(StoragePolicy policy, string previewFingerprint, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).PrepareStorageRetentionAsync(policy, previewFingerprint, cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).CheckStorageRetentionAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteOutcome> ApplyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).ApplyStorageRetentionAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteVerification> VerifyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).VerifyStorageRetentionAsync(plan, cancellationToken).ConfigureAwait(false);
}
