using Domenia.Core;

namespace Domenia.Ad;

public sealed class AdStorageRetentionExecutor(AdDirectorySource source) : IStorageRetentionExecutor
{
    public string Kind => StorageWritePlans.Retention;
    private ILocalStorageRetention Store => source.LocalStore as ILocalStorageRetention
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Conservation de ce stockage indisponible.");
    public async Task<WritePlanDraft> PlanRetentionAsync(StoragePolicy policy, string fingerprint, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var draft = await Store.PrepareStorageRetentionAsync(policy, fingerprint, cancellationToken).ConfigureAwait(false);
        if (session.Epoch != source.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation."); }
        return draft with { Origin = WritePlanOrigin.From(session) };
    }
    public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) => Store.CheckStorageRetentionAsync(plan, cancellationToken);
    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) => source.RunLocalMaintenanceAsync(token => Store.ApplyStorageRetentionAsync(plan, token), cancellationToken);
    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) => Store.VerifyStorageRetentionAsync(plan, cancellationToken);
}
