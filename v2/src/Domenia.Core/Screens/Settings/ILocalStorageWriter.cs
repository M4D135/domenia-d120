namespace Domenia.Core;

public interface ILocalStorageWriter
{
    Task<WritePlanDraft> PrepareWriterResumeAsync(CancellationToken cancellationToken);
    Task<WritePrecheck> CheckWriterResumeAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteOutcome> ApplyWriterResumeAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteVerification> VerifyWriterResumeAsync(WritePlan plan, CancellationToken cancellationToken);
}
