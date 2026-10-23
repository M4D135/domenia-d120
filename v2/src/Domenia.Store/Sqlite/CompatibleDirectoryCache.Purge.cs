using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStoragePurge
{
    public async Task<WritePlanDraft> PrepareStoragePurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string previewFingerprint, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).PrepareStoragePurgeAsync(categories, historyDays, previewFingerprint, cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).CheckStoragePurgeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteOutcome> ApplyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).ApplyStoragePurgeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteVerification> VerifyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).VerifyStoragePurgeAsync(plan, cancellationToken).ConfigureAwait(false);
}
