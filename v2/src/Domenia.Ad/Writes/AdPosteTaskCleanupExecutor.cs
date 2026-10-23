using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Ad;

/// <summary>Explicit, single-use cleanup plan for the original durable remote read only.</summary>
public sealed class AdPosteTaskCleanupExecutor(AdDirectorySource source) : IPosteTaskCleanupExecutor, IWritePlanBinder
{
    private sealed record Prepared(RemoteTaskReadRecord Read, WritePlanOrigin Origin, string Operator, DateTimeOffset ExpiresAt);
    private readonly object gate = new();
    private readonly Dictionary<WritePlanDraft, Prepared> drafts = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<string, (Prepared Data, WritePlan Plan)> bound = new(StringComparer.Ordinal);
    public string Kind => "poste.read.cleanup";
    internal Func<Domenia.Inventory.RemoteTaskReadRunner>? RunnerFactory { get; init; }
    private AdPosteReader Reader() => new(source) { TaskReadRunnerFactory = RunnerFactory };

    public async Task<WritePlanDraft> PlanAsync(string computerDn, Guid operationId, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var read = await Reader().CleanupRecordAsync(computerDn, operationId, true, cancellationToken).ConfigureAwait(false);
        if (!read.CleanupRequired) { throw WriteErrors.Refusal(WriteErrors.Stale, "Cette opération est déjà nettoyée."); }
        var name = read.Plan.Host.Split('.')[0];
        var draft = new WritePlanDraft(Kind, "Nettoyer les artefacts de lecture", "Nettoyage d’une lecture distante",
            "Arrêter si nécessaire et retirer uniquement la tâche temporaire et le répertoire appartenant à cette lecture. La lecture ne sera pas relancée.",
            new("computer", "Poste", name, computerDn, read.Plan.ComputerGuid.ToString("D"), null),
            [new("remoteRead.cleanup", "Lecture à nettoyer", WriteChangeKind.Remove, operationId.ToString("N"), "Artefacts absents après contrôle", read.Plan.StoreId, operationId.ToString("N"))],
            [new(Tone.Warn, "Une exécution encore active de cette lecture sera arrêtée. Une propriété ou une identité incertaine conserve les artefacts et le reçu en attente.")],
            new(true, name, "Saisissez le nom du poste pour confirmer le nettoyage de cette opération."),
            new(false, "Définitif", "Les artefacts temporaires supprimés ne sont pas restaurés ; le résultat déjà reçu et son journal sont conservés."), session.Controller?.DnsName)
        { Origin = WritePlanOrigin.From(session) };
        lock (gate)
        {
            Purge();
            if (session.Epoch != source.Epoch || drafts.Count + bound.Count >= WriteCircuit.PlanCapacity)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée ou trop de plans en attente."); }
            drafts.Add(draft, new(read, draft.Origin!, session.Account.Login, source.Clock.GetUtcNow() + WritePlans.Lifetime));
        }
        return draft;
    }

    public void Bind(WritePlanDraft draft, WritePlan plan)
    {
        lock (gate)
        {
            Purge();
            if (!drafts.TryGetValue(draft, out var prepared) || prepared.Origin.Epoch != source.Epoch
                || plan.Kind != Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsIntact(plan)
                || !WritePlans.IsPlanId(plan.Id) || plan.Operator != prepared.Operator
                || plan.Target != draft.Target || !plan.Changes.SequenceEqual(draft.Changes) || plan.Controller != draft.Controller
                || plan.Confirmation != draft.Confirmation || plan.ExpiresAt <= source.Clock.GetUtcNow() || bound.ContainsKey(plan.Id))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Plan de nettoyage non lié à sa préparation."); }
            bound.Add(plan.Id, (prepared, plan)); drafts.Remove(draft);
        }
    }

    private Prepared Recall(WritePlan plan, SessionSnapshot session)
    {
        lock (gate)
        {
            Purge();
            if (!bound.TryGetValue(plan.Id, out var item) || !item.Data.Origin.Matches(session)
                || !WritePlans.IsIntact(plan) || item.Plan.Fingerprint != plan.Fingerprint || plan.ExpiresAt <= source.Clock.GetUtcNow())
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Plan absent, expiré ou d’une autre session."); }
            return item.Data;
        }
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        try
        {
            var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            using var lease = source.AcquireWriteLease(session); var data = Recall(plan, session);
            var current = await Reader().CleanupRecordAsync(data.Read.Plan.ComputerDn, data.Read.Plan.Id, true, cancellationToken).ConfigureAwait(false);
            return current == data.Read ? WritePrecheck.Valid("Poste, compte, base et opération inchangés.") : WritePrecheck.Stale("Reçu modifié depuis le plan.");
        }
        catch (DomeniaOperationException ex) { return WritePrecheck.Stale(ex.Message); }
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session); var data = Recall(plan, session);
        try
        {
            var result = await Reader().ExecuteCleanupAsync(data.Read, cancellationToken).ConfigureAwait(false);
            return new(result.ArtifactsRemoved && result.ExecutionStopped ? WriteResult.Applied : WriteResult.Unknown, result.Detail);
        }
        finally { lock (gate) { bound.Remove(plan.Id); } }
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        if (plan.Kind != Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsIntact(plan)
            || plan.Changes is not [var change] || change.Attribute != "remoteRead.cleanup" || !Guid.TryParseExact(change.AfterValue, "N", out var id))
        { return new(VerificationState.Unknown, "Plan de nettoyage invalide."); }
        try
        {
            var read = await Reader().CleanupRecordAsync(plan.Target.Dn, id, false, cancellationToken).ConfigureAwait(false);
            if (read.Plan.StoreId != change.BeforeValue || read.Plan.ComputerGuid.ToString("D") != plan.Target.ObjectGuid)
            { return new(VerificationState.Unknown, "Base ou poste différent du plan."); }
            return new(read.CleanupRequired ? VerificationState.Unknown : VerificationState.Verified,
                read.Completion?.Detail ?? "Aucun achèvement confirmé.");
        }
        catch (DomeniaOperationException ex) { return new(VerificationState.Unknown, ex.Message); }
    }

    private void Purge()
    {
        var now = source.Clock.GetUtcNow();
        foreach (var key in drafts.Where(p => p.Value.ExpiresAt <= now || p.Value.Origin.Epoch != source.Epoch).Select(p => p.Key).ToArray()) { drafts.Remove(key); }
        foreach (var key in bound.Where(p => p.Value.Data.ExpiresAt <= now || p.Value.Data.Origin.Epoch != source.Epoch).Select(p => p.Key).ToArray()) { bound.Remove(key); }
    }
}
