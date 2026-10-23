using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Directory-mode local backup plans, served by the configured legacy-compatible store.</summary>
public abstract class AdStorageBackupExecutor(AdDirectorySource source) : IWriteExecutor
{
    private protected ILocalStorageBackup Store => source.LocalStore as ILocalStorageBackup
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Sauvegarde de ce stockage indisponible.");
    public abstract string Kind { get; }
    private protected async Task<WritePlanDraft> Prepare(StoragePolicy policy, string annex, string series, string? destination, CancellationToken token)
    {
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        var draft = await Store.PrepareStorageBackupAsync(policy, annex, series, destination, token).ConfigureAwait(false);
        if (session.Epoch != source.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation de la sauvegarde."); }
        return draft with { Origin = WritePlanOrigin.From(session) };
    }
    public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) => Store.CheckStorageBackupAsync(plan, cancellationToken);
    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) => Store.ApplyStorageBackupAsync(plan, cancellationToken);
    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) => Store.VerifyStorageBackupAsync(plan, cancellationToken);
}

public sealed class AdStorageBackupLocalExecutor(AdDirectorySource source) : AdStorageBackupExecutor(source), IStorageBackupExecutor
{
    public override string Kind => StorageWritePlans.Backup;
    public Task<WritePlanDraft> PlanBackupAsync(StoragePolicy policy, string annex, string series, CancellationToken cancellationToken) =>
        Prepare(policy, annex, series, null, cancellationToken);
}

public sealed class AdStorageBackupCopyExecutor(AdDirectorySource source) : AdStorageBackupExecutor(source), IStorageBackupCopyExecutor
{
    public override string Kind => StorageWritePlans.BackupCopy;
    public Task<WritePlanDraft> PlanBackupCopyAsync(string destination, StoragePolicy policy, string annex, CancellationToken cancellationToken) =>
        Prepare(policy, annex, StorageWritePlans.ManualSeries, destination, cancellationToken);
}
