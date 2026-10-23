using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Local reset bound to a reviewed snapshot, with backup, generation and durable receipt handled by its precise store.</summary>
public sealed class AdRelationSweepResetExecutor(AdDirectorySource source) : IRelationSweepResetExecutor, IWritePlanBinder, IDisposable
{
    private sealed record Prepared(RelationSweepCacheSnapshot Snapshot, WritePlanOrigin Origin, string Operator, DateTimeOffset Expires);
    private sealed record Bound(Prepared Data, WritePlan Plan);
    private readonly Lock gate = new();
    private readonly Dictionary<WritePlanDraft, Prepared> drafts = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<string, Bound> bound = new(StringComparer.Ordinal);
    private long epoch = source.Epoch;
    private bool disposed;
    public string Kind => RelationSweepReset.Kind;

    public async Task<WritePlanDraft> PlanSweepResetAsync(CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session);
        if (source.LocalStore is not IRelationSweepWriter writer) { throw WriteErrors.Refusal(DomeniaErrors.WriteUnavailable, "Stockage des relevés indisponible."); }
        var snapshot = await writer.ReadRelationSweepsAsync(cancellationToken).ConfigureAwait(false);
        if (source.CurrentDirectory is not { } directory || !DistinguishedName.AreEqual(snapshot.DomainDn, directory.Domain.RootDn)
            || snapshot.Truncated || snapshot.Rejected > 0 || snapshot.Total != snapshot.Rows.Length || snapshot.Generation == long.MaxValue
            || snapshot.Rows.GroupBy(r => r.StorageKey, StringComparer.Ordinal).Any(g => g.Count() > 1))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Mémoire des relevés partielle, ambiguë ou d’un autre domaine ; aucun effacement préparé."); }
        var oldest = snapshot.Rows.Where(r => r.At is not null).Select(r => r.At).Min();
        var draft = RelationSweepReset.Draft(checked((int)snapshot.Total), snapshot.Fingerprint,
            RelationRules.WhenText(oldest, source.Clock.GetUtcNow(), source.Zone), false, false);
        draft = draft with { Target = draft.Target with { Dn = RelationSweepReset.StoreTarget(snapshot.StoreId, snapshot.DomainDn) }, Origin = WritePlanOrigin.From(session) };
        lock (gate)
        {
            Purge();
            if (source.Epoch != session.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation."); }
            if (drafts.Count + bound.Count >= WriteCircuit.PlanCapacity) { throw WriteErrors.Refusal(WriteErrors.Stale, "Trop de confirmations de relevés en attente ; terminez-les ou attendez leur expiration."); }
            drafts.Add(draft, new(snapshot, draft.Origin, session.Account.Login, source.Clock.GetUtcNow() + WritePlans.Lifetime));
        }
        return draft;
    }

    public void Bind(WritePlanDraft draft, WritePlan plan)
    {
        lock (gate)
        {
            Purge();
            if (!drafts.TryGetValue(draft, out var prepared) || prepared.Origin.Epoch != source.Epoch || plan.Kind != Kind || plan.Simulated
                || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.Operator != prepared.Operator || !WritePlans.IsIntact(plan) || !WritePlans.IsPlanId(plan.Id)
                || plan.ExpiresAt <= source.Clock.GetUtcNow() || plan.Target != draft.Target || !plan.Changes.SequenceEqual(draft.Changes)
                || plan.Controller != draft.Controller || bound.ContainsKey(plan.Id))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Plan d’effacement sans préparation correspondante ; aucune liaison."); }
            bound.Add(plan.Id, new(prepared, plan)); drafts.Remove(draft);
        }
    }

    private Bound Recall(WritePlan plan, SessionSnapshot session)
    {
        lock (gate)
        {
            Purge();
            if (!bound.TryGetValue(plan.Id, out var held) || !held.Data.Origin.Matches(session) || !WritePlans.IsIntact(plan)
                || held.Plan.Fingerprint != plan.Fingerprint || plan.ExpiresAt <= source.Clock.GetUtcNow())
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Plan d’effacement non lié, expiré ou d’une autre session."); }
            return held;
        }
    }
    private static RelationSweepResetWrite Request(Bound held) => new(held.Data.Snapshot.StoreId, held.Plan, held.Data.Snapshot.Generation);

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        try
        {
            var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false); using var lease = source.AcquireWriteLease(session);
            var held = Recall(plan, session);
            return source.LocalStore is IRelationSweepWriter writer ? await writer.CheckRelationSweepResetAsync(Request(held), cancellationToken).ConfigureAwait(false)
                : WritePrecheck.Stale("Base locale indisponible.");
        }
        catch (DomeniaOperationException ex) { return WritePrecheck.Stale(ex.Message); }
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        try
        {
            var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false); using var lease = source.AcquireWriteLease(session);
            var held = Recall(plan, session);
            if (source.LocalStore is not IRelationSweepWriter writer) { throw WriteErrors.Refusal(DomeniaErrors.WriteUnavailable, "Base locale indisponible."); }
            var result = await writer.ResetRelationSweepsAsync(Request(held), cancellationToken).ConfigureAwait(false);
            return new(result.Forgotten > 0 ? WriteResult.Applied : WriteResult.NoChange,
                FrenchText.Count(result.Forgotten, "relevé oublié", "relevés oubliés") + ". Sauvegarde vérifiée avant effacement (SHA-256 " + result.BackupSha256
                + "). Associations et annuaire conservés ; anciens passages en cours non réintroduits.");
        }
        finally { lock (gate) { bound.Remove(plan.Id); } }
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        if (plan.Kind != Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsIntact(plan)
            || plan.Target.ObjectGuid != RelationSweepReset.MemoryGuid.ToString("D") || plan.Changes.Length != 1
            || plan.Changes[0].Attribute != RelationSweepReset.Attribute || plan.Changes[0].Kind != WriteChangeKind.Reset || plan.Changes[0].AfterValue != RelationSweepReset.Value(0, ""))
        { return new(VerificationState.Unknown, "Plan de relevés invalide ; aucune nouvelle écriture."); }
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false); using var lease = source.AcquireWriteLease(session);
        if (source.LocalStore is not IRelationSweepCache cache) { return new(VerificationState.Unknown, "Mémoire locale indisponible."); }
        var current = await cache.ReadRelationSweepsAsync(cancellationToken).ConfigureAwait(false);
        if (plan.Target.Dn != RelationSweepReset.StoreTarget(current.StoreId, current.DomainDn)) { return new(VerificationState.Unknown, "Base différente de celle du reçu."); }
        if (current.Truncated || current.Rejected > 0 || current.Rows.Length != current.Total) { return new(VerificationState.Unknown, "Mémoire partiellement lisible ; postcondition inconnue."); }
        return RelationSweepReset.Verify(checked((int)current.Total));
    }

    private void Purge()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (epoch != source.Epoch) { drafts.Clear(); bound.Clear(); epoch = source.Epoch; }
        var now = source.Clock.GetUtcNow();
        foreach (var draft in drafts.Where(p => p.Value.Expires <= now).Select(p => p.Key).ToArray()) { drafts.Remove(draft); }
        foreach (var id in bound.Where(p => p.Value.Plan.ExpiresAt <= now).Select(p => p.Key).ToArray()) { bound.Remove(id); }
    }
    public void Dispose() { lock (gate) { disposed = true; drafts.Clear(); bound.Clear(); } }
}
