namespace Domenia.Core;

/// <summary>Native local backup boundary; preparation and checking are read-only, execution never changes the active database.</summary>
public interface ILocalStorageBackup
{
    Task<WritePlanDraft> PrepareStorageBackupAsync(StoragePolicy policy, string annex, string series, string? destination, CancellationToken cancellationToken);
    Task<WritePrecheck> CheckStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteOutcome> ApplyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteVerification> VerifyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken);
}
