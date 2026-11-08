using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

public abstract class AdStorageSwitchExecutor(AdDirectorySource source) : IWriteExecutor, IWritePlanBinder
{
    private sealed record Prepared(WritePlanOrigin Origin, string Operator);
    private sealed record Bound(Prepared Data, WritePlan Plan);
    private readonly ConditionalWeakTable<WritePlanDraft, Prepared> drafts = new();
    private readonly Dictionary<string, Bound> bound = new(StringComparer.Ordinal);
    private readonly Lock gate = new();
    private protected ILocalStorageSwitch Store => source.LocalStore as ILocalStorageSwitch
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Bascule de ce stockage indisponible.");
    public abstract string Kind { get; }
    private protected async Task<WritePlanDraft> Prepare(Func<CancellationToken, Task<WritePlanDraft>> action, CancellationToken token)
    {
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        var draft = await action(token).ConfigureAwait(false);
        var origin = WritePlanOrigin.From(session);
        source.ValidateSyncOrigin(origin);
        draft = draft with { Origin = origin };
        drafts.Add(draft, new(origin, session.Account.Login));
        return draft;
    }
    public void Bind(WritePlanDraft draft, WritePlan plan)
    {
        lock (gate)
        {
            foreach (var key in bound.Where(p => p.Value.Plan.ExpiresAt <= source.Clock.GetUtcNow()
                || p.Value.Data.Origin.Epoch != source.Epoch).Select(p => p.Key).ToArray()) bound.Remove(key);
            if (!drafts.TryGetValue(draft, out var data) || draft.Origin != data.Origin || data.Origin.Epoch != source.Epoch
                || !WritePlans.IsIntact(plan) || !WritePlans.IsPlanId(plan.Id) || plan.Kind != Kind || plan.Simulated
                || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.Operator != data.Operator || plan.Target != draft.Target
                || plan.Controller != draft.Controller || plan.Confirmation != draft.Confirmation || !plan.Changes.SequenceEqual(draft.Changes))
                throw WriteErrors.Refusal(WriteErrors.Stale, "Brouillon de bascule absent ou modifié ; préparez un nouvel aperçu.");
            if (bound.Count >= WriteCircuit.PlanCapacity)
                throw WriteErrors.Refusal(WriteErrors.Stale, "Trop de confirmations en attente ; attendez leur expiration.");
            bound.Add(plan.Id, new(data, plan)); drafts.Remove(draft);
        }
    }
    private Bound Recall(WritePlan plan)
    {
        lock (gate)
        {
            if (!bound.TryGetValue(plan.Id, out var held) || !WritePlans.IsIntact(plan)
                || held.Plan.Fingerprint != plan.Fingerprint || plan.ExpiresAt <= source.Clock.GetUtcNow())
                throw WriteErrors.Refusal(WriteErrors.Stale, "Bascule absente, modifiée ou expirée ; aucune écriture.");
            source.ValidateSyncOrigin(held.Data.Origin);
            return held;
        }
    }
    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var held = Recall(plan);
        var result = await Store.CheckStorageSwitchAsync(plan, cancellationToken).ConfigureAwait(false);
        source.ValidateSyncOrigin(held.Data.Origin);
        return result;
    }
    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var held = Recall(plan);
        try
        {
            return await source.RunQualifiedLocalMaintenanceAsync(held.Data.Origin, (validate, token) =>
            { validate(); return Store.ApplyStorageSwitchAsync(plan, token); }, cancellationToken).ConfigureAwait(false);
        }
        finally { lock (gate) bound.Remove(plan.Id); }
    }
    // Verification reads durable evidence and remains available after the session epoch changes.
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
