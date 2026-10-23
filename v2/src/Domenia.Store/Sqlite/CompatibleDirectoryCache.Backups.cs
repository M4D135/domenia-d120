using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStorageBackup
{
    public async Task<WritePlanDraft> PrepareStorageBackupAsync(StoragePolicy policy, string annex, string series, string? destination, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).PrepareStorageBackupAsync(policy, annex, series, destination, cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).CheckStorageBackupAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteOutcome> ApplyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).ApplyStorageBackupAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteVerification> VerifyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).VerifyStorageBackupAsync(plan, cancellationToken).ConfigureAwait(false);
}
