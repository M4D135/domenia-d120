namespace Domenia.Core;

public interface ILocalStorageLegacy
{
    Task<WritePlanDraft> PrepareStorageLegacyAsync(string domain, string previewFingerprint, CancellationToken cancellationToken);
    Task<WritePrecheck> CheckStorageLegacyAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteOutcome> ApplyStorageLegacyAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteVerification> VerifyStorageLegacyAsync(WritePlan plan, CancellationToken cancellationToken);
}
