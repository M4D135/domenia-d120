using Domenia.Core;

namespace Domenia.Ad;

public sealed class AdStorageLegacyImportExecutor(AdDirectorySource source) : IStorageLegacyImportExecutor
{
    public string Kind => StorageWritePlans.LegacyImport;
    private ILocalStorageLegacy Store => source.LocalStore as ILocalStorageLegacy
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Reprise historique de ce stockage indisponible.");
    public async Task<WritePlanDraft> PlanLegacyImportAsync(string domain, string fingerprint, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var draft = await Store.PrepareStorageLegacyAsync(domain, fingerprint, cancellationToken).ConfigureAwait(false);
        if (session.Epoch != source.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation."); }
        return draft with { Origin = WritePlanOrigin.From(session) };
    }
    public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) => Store.CheckStorageLegacyAsync(plan, cancellationToken);
    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) => source.RunLocalMaintenanceAsync(token => Store.ApplyStorageLegacyAsync(plan, token), cancellationToken);
    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) => Store.VerifyStorageLegacyAsync(plan, cancellationToken);
}
