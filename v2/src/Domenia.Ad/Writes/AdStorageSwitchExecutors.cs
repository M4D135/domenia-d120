using Domenia.Core;

namespace Domenia.Ad;

public abstract class AdStorageSwitchExecutor(AdDirectorySource source) : IWriteExecutor
{
    private protected ILocalStorageSwitch Store => source.LocalStore as ILocalStorageSwitch
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Bascule de ce stockage indisponible.");
    public abstract string Kind { get; }
    private protected async Task<WritePlanDraft> Prepare(Func<CancellationToken, Task<WritePlanDraft>> action, CancellationToken token)
    {
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        var draft = await action(token).ConfigureAwait(false);
        if (session.Epoch != source.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation de la bascule."); }
        return draft with { Origin = WritePlanOrigin.From(session) };
    }
    public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) => Store.CheckStorageSwitchAsync(plan, cancellationToken);
    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) =>
        source.RunLocalMaintenanceAsync(token => Store.ApplyStorageSwitchAsync(plan, token), cancellationToken);
    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) => Store.VerifyStorageSwitchAsync(plan, cancellationToken);
}

public sealed class AdStorageMoveExecutor(AdDirectorySource source) : AdStorageSwitchExecutor(source), IStorageMoveExecutor
{
    public override string Kind => StorageWritePlans.Move;
    public Task<WritePlanDraft> PlanMoveAsync(string destination, CancellationToken cancellationToken) => Prepare(token => Store.PrepareStorageMoveAsync(destination, token), cancellationToken);
}
public sealed class AdStorageRestoreExecutor(AdDirectorySource source) : AdStorageSwitchExecutor(source), IStorageRestoreExecutor
{
    public override string Kind => StorageWritePlans.Restore;
    public Task<WritePlanDraft> PlanRestoreAsync(string backupId, CancellationToken cancellationToken) => Prepare(token => Store.PrepareStorageRestoreAsync(backupId, true, token), cancellationToken);
    public Task<WritePlanDraft> PlanRestoreFileAsync(string path, CancellationToken cancellationToken) => Prepare(token => Store.PrepareStorageRestoreAsync(path, false, token), cancellationToken);
}
public sealed class AdStorageResumeExecutor(AdDirectorySource source) : AdStorageSwitchExecutor(source), IStorageResumeExecutor
{
    public override string Kind => StorageWritePlans.Resume;
    public Task<WritePlanDraft> PlanResumeAsync(CancellationToken cancellationToken) => Prepare(Store.PrepareStorageResumeAsync, cancellationToken);
}
public sealed class AdStorageRollbackExecutor(AdDirectorySource source) : AdStorageSwitchExecutor(source), IStorageRollbackExecutor
{
    public override string Kind => StorageWritePlans.Rollback;
    public Task<WritePlanDraft> PlanRollbackAsync(CancellationToken cancellationToken) => Prepare(Store.PrepareStorageRollbackAsync, cancellationToken);
}
