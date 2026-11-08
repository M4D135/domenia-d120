namespace Domenia.Core;

/// <summary>Durable switch of a domain's active local database, with explicit recovery and historical receipts.</summary>
public interface ILocalStorageSwitch
{
    Task<WritePlanDraft> PrepareStorageMoveAsync(string destination, CancellationToken cancellationToken);
    Task<WritePlanDraft> PrepareStorageRestoreAsync(string source, bool registeredBackup, CancellationToken cancellationToken);
    Task<WritePlanDraft> PrepareStorageResumeAsync(CancellationToken cancellationToken);
    Task<WritePlanDraft> PrepareStorageRollbackAsync(CancellationToken cancellationToken);
    Task<WritePrecheck> CheckStorageSwitchAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteOutcome> ApplyStorageSwitchAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteVerification> VerifyStorageSwitchAsync(WritePlan plan, CancellationToken cancellationToken);
}
