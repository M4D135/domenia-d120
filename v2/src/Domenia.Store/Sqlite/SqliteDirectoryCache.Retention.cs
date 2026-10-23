using Domenia.Core;

namespace Domenia.Store;

public sealed partial class SqliteDirectoryCache : ILocalStorageRetention
{
    public Task<WritePlanDraft> PrepareStorageRetentionAsync(StoragePolicy policy, string previewFingerprint, CancellationToken cancellationToken) => Database.PrepareStorageRetentionAsync(policy, previewFingerprint, cancellationToken);
    public Task<WritePrecheck> CheckStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) => Database.CheckStorageRetentionAsync(plan, cancellationToken);
    public Task<WriteOutcome> ApplyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) => Database.ApplyStorageRetentionAsync(plan, cancellationToken);
    public Task<WriteVerification> VerifyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) => Database.VerifyStorageRetentionAsync(plan, cancellationToken);
}
