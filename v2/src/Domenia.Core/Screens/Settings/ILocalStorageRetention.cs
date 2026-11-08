namespace Domenia.Core;

public interface ILocalStorageRetention
{
    Task<WritePlanDraft> PrepareStorageRetentionAsync(StoragePolicy policy, string previewFingerprint, CancellationToken cancellationToken);
    Task<WritePrecheck> CheckStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteOutcome> ApplyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteVerification> VerifyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken);
}
