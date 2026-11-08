using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdSyncStoreExecutor
{
    private sealed record PreparedSharedPark(SharedParkBatch Batch, WritePlanOrigin Origin, string Operator, WritePlan? Plan = null);
    private readonly ConditionalWeakTable<WritePlanDraft, PreparedSharedPark> sharedDrafts = new();
    private readonly Dictionary<string, PreparedSharedPark> sharedPlans = new(StringComparer.Ordinal);
    // Deterministic test seam at the real reserved source generation, before the Store operation. No production callback is installed.
    internal Action? SharedParkMaintenanceReserved { get; set; }
    private ISharedParkStore SharedParkStore => source.LocalStore as ISharedParkStore
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Partage du relevé du parc indisponible.");

    private static bool IsSharedPark(WritePlan plan)
        => SyncStoreChange.Head(plan) is { Operation: SyncStoreOperation.Batch, Kind: "park" };

    private async Task<WritePlanDraft> PlanSharedParkAsync(AdSyncState.SharedPreview preview, SessionSnapshot session, CancellationToken token)
    {
        if (!preview.Origin.Matches(session))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Connexion modifiée depuis la lecture du partage ; relancez l’aperçu."); }
        source.ValidateSyncOrigin(preview.Origin);
        var draft = await SharedParkStore.DraftSharedParkAsync(preview.Batch, preview.Origin, token).ConfigureAwait(false);
        source.ValidateSyncOrigin(preview.Origin);
        if (draft.Origin != preview.Origin)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Le brouillon partagé ne correspond pas à cette session."); }
        sharedDrafts.Add(draft, new(preview.Batch, preview.Origin, session.Account.Login));
        return draft;
    }

    private void BindSharedPark(WritePlanDraft draft, WritePlan plan)
    {
        lock (gate)
        {
            foreach (var id in sharedPlans.Where(x => x.Value.Plan!.ExpiresAt <= source.Clock.GetUtcNow()
                || x.Value.Origin.Epoch != source.Epoch).Select(x => x.Key).ToArray())
            { sharedPlans.Remove(id); }
            if (!sharedDrafts.TryGetValue(draft, out var pending) || draft.Origin != pending.Origin
                || pending.Origin.Epoch != source.Epoch || !WritePlans.IsIntact(plan)
                || !WritePlans.IsPlanId(plan.Id) || plan.Kind != Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText
                || plan.Operator != pending.Operator || plan.Target != draft.Target || plan.Controller != draft.Controller
                || plan.Confirmation != draft.Confirmation || !plan.Changes.SequenceEqual(draft.Changes))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Brouillon partagé absent ou modifié ; préparez un nouvel aperçu."); }
            if (sharedPlans.Count >= 8)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Huit plans de partage attendent déjà leur confirmation."); }
            sharedPlans.Add(plan.Id, pending with { Plan = plan });
            sharedDrafts.Remove(draft);
        }
    }

    private PreparedSharedPark? FindSharedPark(WritePlan plan)
    {
        lock (gate)
        {
            if (!WritePlans.IsIntact(plan) || !sharedPlans.TryGetValue(plan.Id, out var pending)
                || pending.Plan?.Fingerprint != plan.Fingerprint || pending.Origin.Epoch != source.Epoch
                || plan.ExpiresAt <= source.Clock.GetUtcNow()) { return null; }
            return pending;
        }
    }

    private async Task<WritePrecheck> CheckSharedParkAsync(WritePlan plan, CancellationToken token)
    {
        var pending = FindSharedPark(plan);
        if (pending is null) { return WritePrecheck.Stale("Aperçu partagé absent, expiré ou session modifiée."); }
        return await SharedParkStore.CheckSharedParkAsync(pending.Batch, pending.Origin,
            () => source.ValidateSyncOrigin(pending.Origin), token).ConfigureAwait(false);
    }

    private async Task<WriteOutcome> ExecuteSharedParkAsync(WritePlan plan, CancellationToken token)
    {
        var pending = FindSharedPark(plan)
            ?? throw WriteErrors.Refusal(WriteErrors.Stale, "Aperçu partagé absent, expiré ou session modifiée ; aucune publication.");
        var state = AdSyncState.For(source);
        WriteOutcome? sent = null;
        var ownsPreview = false;
        try
        {
            var transferred = state.TakeShared(pending.Batch.Id, pending.Origin);
            ownsPreview = transferred is not null;
            if (transferred?.Batch != pending.Batch)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Aperçu partagé déjà transféré ou abandonné ; aucune publication."); }
            // Source maintenance advances its own epoch under a held write lease. Its callback checks that reserved generation,
            // while the original origin remains bound to the compact preview and the operator-confirmed plan.
            return await source.RunQualifiedLocalMaintenanceAsync(pending.Origin,
                async (validateSource, heldToken) =>
                {
                    SharedParkMaintenanceReserved?.Invoke(); validateSource();
                    return sent = await SharedParkStore.ApplySharedParkAsync(
                        pending.Batch, plan, pending.Origin, validateSource, heldToken).ConfigureAwait(false);
                },
                token).ConfigureAwait(false);
        }
        catch (Exception ex) when (sent?.Result is WriteResult.Applied or WriteResult.Unknown
            && ex is IOException or UnauthorizedAccessException or OperationCanceledException or DomeniaOperationException or InvalidOperationException)
        {
            // A reload failure after publication is not a pre-send refusal. The outer write circuit must retain an uncertain
            // receipt and use the durable Store verifier; translating it to NotApplied would permit a misleading retry.
            return new(WriteResult.Unknown, "Publication engagée ; rechargement local incomplet. Les preuves sont conservées ; relisez le reçu, sans relancer l’écriture.");
        }
        finally
        {
            lock (gate) { sharedPlans.Remove(plan.Id); }
            if (ownsPreview)
            {
                state.Remove(pending.Batch.Id);
                SharedParkStore.DiscardSharedPark(pending.Batch.Id);
            }
        }
    }
}
