using Domenia.Core;

namespace Domenia.Ad;

public sealed class AdStorageWriterResumeExecutor(AdDirectorySource source) : IStorageWriterResumeExecutor
{
    public string Kind => StorageWritePlans.WriterResume;
    private ILocalStorageWriter Store => source.LocalStore as ILocalStorageWriter
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Reprise des enregistrements locaux indisponible.");
    public async Task<WritePlanDraft> PlanWriterResumeAsync(CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var draft = await Store.PrepareWriterResumeAsync(cancellationToken).ConfigureAwait(false);
        if (session.Epoch != source.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation."); }
        return draft with { Origin = WritePlanOrigin.From(session) };
    }
    public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) => Store.CheckWriterResumeAsync(plan, cancellationToken);
    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) => source.RunLocalMaintenanceAsync(token => Store.ApplyWriterResumeAsync(plan, token), cancellationToken);
    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) => Store.VerifyWriterResumeAsync(plan, cancellationToken);
}
