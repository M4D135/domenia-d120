using Domenia.Core;

namespace Domenia.Ad;

public sealed class AdStoragePurgeExecutor(AdDirectorySource source) : IStoragePurgeExecutor
{
    public string Kind => StorageWritePlans.Purge;
    private ILocalStoragePurge Store => source.LocalStore as ILocalStoragePurge
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Purge de ce stockage indisponible.");
    public async Task<WritePlanDraft> PlanPurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string fingerprint, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var draft = await Store.PrepareStoragePurgeAsync(categories, historyDays, fingerprint, cancellationToken).ConfigureAwait(false);
        if (session.Epoch != source.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation."); }
        return draft with { Origin = WritePlanOrigin.From(session) };
    }
    public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) => Store.CheckStoragePurgeAsync(plan, cancellationToken);
    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) => source.RunLocalMaintenanceAsync(token => Store.ApplyStoragePurgeAsync(plan, token), cancellationToken);
    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) => Store.VerifyStoragePurgeAsync(plan, cancellationToken);
}
