using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationChangeExecutor(AdDirectorySource source) : IRelationChangeExecutor, IWritePlanBinder, IDisposable
{
    private sealed record Prepared(string StoreId, WritePlanOrigin Origin, string Operator, ImmutableArray<CachedRelation> Expected,
        ImmutableArray<RelationChangeItem> Items, ImmutableArray<StoredRelation> ExpectedAbsent, DateTimeOffset Expires);
    private sealed record Bound(Prepared Data, WritePlan Plan);
    private sealed record Local(RelationCacheSnapshot Stored, SessionSnapshot Session, IRelationLocalWriter Writer);
    private readonly Lock gate = new();
    private readonly Dictionary<WritePlanDraft, Prepared> drafts = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<string, Bound> bound = new(StringComparer.Ordinal);
    private long epoch = source.Epoch;
    private bool disposed;
    public string Kind => RelationChange.Kind;

    private async Task<Local> ReadAsync(CancellationToken token)
    {
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session);
        if (source.LocalStore is not IRelationLocalWriter writer) { throw WriteErrors.Refusal(DomeniaErrors.WriteUnavailable, "Stockage local des associations indisponible."); }
        var stored = await writer.ReadRelationsAsync(token).ConfigureAwait(false);
        if (stored.Truncated || stored.Rejected > 0) { throw WriteErrors.Refusal(WriteErrors.Stale, "Base partiellement lisible ; aucune modification préparée."); }
        if (source.CurrentDirectory is not { } directory || !DistinguishedName.AreEqual(stored.DomainDn, directory.Domain.RootDn))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Base et annuaire local de domaines différents."); }
        if (source.Epoch != session.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation locale."); }
        return new(stored, session, writer);
    }

    private static string TargetDn(RelationCacheSnapshot data) => "Base locale Domenia · " + data.DomainDn + " · " + data.StoreId;

    private WritePlanDraft Hold(Local local, string title, string label, string summary, string targetName, IReadOnlyList<RelationChangeItem> items,
        IEnumerable<WriteRisk> risks, WriteReversibility reversibility, ImmutableArray<StoredRelation> expectedAbsent = default)
    {
        var touched = items.SelectMany(i => new[] { i.Before, i.After }).OfType<StoredRelation>().Select(RelationRules.Key).ToHashSet(StringComparer.Ordinal);
        var expected = local.Stored.Rows.Where(r => touched.Contains(RelationRules.Key(r.Relation))).ToImmutableArray();
        if (expected.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).Any(g => g.Count() > 1))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Plusieurs lignes physiques pour cette association ; aucun choix arbitraire."); }
        var draft = RelationChange.Draft(title, label, summary, targetName, false, items, risks, reversibility, source.Clock.GetUtcNow(), source.Zone);
        draft = draft with { Target = draft.Target with { Dn = TargetDn(local.Stored) }, Origin = WritePlanOrigin.From(local.Session) };
        lock (gate)
        {
            Purge();
            if (source.Epoch != local.Session.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Préparation d’une ancienne session écartée."); }
            if (drafts.Count + bound.Count >= WriteCircuit.PlanCapacity) { throw WriteErrors.Refusal(WriteErrors.Stale, "Trop de plans locaux en attente ; terminez les confirmations ouvertes ou attendez leur expiration."); }
            drafts.Add(draft, new(local.Stored.StoreId, draft.Origin, local.Session.Account.Login, expected, [.. items], expectedAbsent.IsDefault ? [] : expectedAbsent,
                source.Clock.GetUtcNow() + WritePlans.Lifetime));
        }
        return draft;
    }

    public void Bind(WritePlanDraft draft, WritePlan plan)
    {
        lock (gate)
        {
            Purge();
            if (!drafts.TryGetValue(draft, out var data) || data.Origin.Epoch != source.Epoch || plan.Kind != Kind || plan.Simulated
                || plan.Operator != data.Operator || !WritePlans.IsIntact(plan) || !WritePlans.IsPlanId(plan.Id)
                || plan.ExpiresAt <= source.Clock.GetUtcNow() || plan.Mode != AppInfoBuilder.DirectoryModeText
                || plan.Target != draft.Target || !plan.Changes.SequenceEqual(draft.Changes) || plan.Controller != draft.Controller || bound.ContainsKey(plan.Id))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Les données préparées ne peuvent pas être liées à ce plan."); }
            bound.Add(plan.Id, new(data, plan)); drafts.Remove(draft);
        }
    }

    private Bound Recall(WritePlan plan, SessionSnapshot session)
    {
        lock (gate)
        {
            Purge();
            if (!bound.TryGetValue(plan.Id, out var held) || !held.Data.Origin.Matches(session) || !WritePlans.IsIntact(plan)
                || plan.Fingerprint != held.Plan.Fingerprint || plan.ExpiresAt <= source.Clock.GetUtcNow())
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Plan local non lié, expiré ou d’une ancienne session ; préparez-le à nouveau."); }
            return held;
        }
    }
    private static RelationStoreWrite Request(Bound held) => new(held.Data.StoreId, held.Plan, held.Data.Expected, held.Data.Items);

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        try
        {
            var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            using var lease = source.AcquireWriteLease(session); var held = Recall(plan, session);
            if (source.LocalStore is not IRelationLocalWriter writer) { return WritePrecheck.Stale("Base locale indisponible."); }
            await AdRelationDirectory.ValidateAssignmentsAsync(source, held.Data.Items, cancellationToken).ConfigureAwait(false);
            await ValidateAbsenceAsync(held.Data.ExpectedAbsent, cancellationToken).ConfigureAwait(false);
            return await writer.CheckRelationsAsync(Request(held), cancellationToken).ConfigureAwait(false);
        }
        catch (DomeniaOperationException ex) { return WritePrecheck.Stale(ex.Message); }
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session); var held = Recall(plan, session);
        try
        {
            if (source.LocalStore is not IRelationLocalWriter writer) { throw WriteErrors.Refusal(WriteErrors.Stale, "Base locale indisponible."); }
            await AdRelationDirectory.ValidateAssignmentsAsync(source, held.Data.Items, cancellationToken).ConfigureAwait(false);
            await ValidateAbsenceAsync(held.Data.ExpectedAbsent, cancellationToken).ConfigureAwait(false);
            var result = await writer.ApplyRelationsAsync(Request(held), cancellationToken).ConfigureAwait(false);
            return new(result.Applied > 0 ? WriteResult.Applied : WriteResult.NoChange,
                FrenchText.Count(result.Applied, "association modifiée", "associations modifiées") + ". " + result.Notice);
        }
        finally { lock (gate) { bound.Remove(plan.Id); } }
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        if (plan.Kind != Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.Changes.Length is < 1 or > WritePlans.MaxChanges
            || !WritePlans.IsIntact(plan) || plan.Target.ObjectGuid != RelationChange.StoreGuid.ToString("D"))
        { return new(VerificationState.Unknown, "Plan d’associations invalide ; aucune nouvelle écriture."); }
        if (source.LocalStore is not IRelationLocalCache cache) { return new(VerificationState.Unknown, "Base locale indisponible."); }
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session);
        var current = await cache.ReadRelationsAsync(cancellationToken).ConfigureAwait(false);
        if (!string.Equals(plan.Target.Dn, TargetDn(current), StringComparison.OrdinalIgnoreCase))
        { return new(VerificationState.Unknown, "Une autre base locale est sélectionnée ; ce reçu ne peut pas y être vérifié."); }
        if (current.Truncated || current.Rejected > 0) { return new(VerificationState.Unknown, "Base partiellement lisible ; postcondition non établie."); }
        var groups = current.Rows.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToArray(), StringComparer.Ordinal);
        foreach (var change in plan.Changes)
        {
            var before = RelationChange.Parse(change.BeforeValue); var after = RelationChange.Parse(change.AfterValue);
            if (change.Attribute != RelationChange.Attribute || before is null && after is null) { return new(VerificationState.Unknown, "Changement local illisible."); }
            var beforeRows = before is { } old ? groups.GetValueOrDefault(old.Key, []) : [];
            var afterRows = after is { } fresh ? groups.GetValueOrDefault(fresh.Key, []) : [];
            if (beforeRows.Length > 1 || afterRows.Length > 1) { return new(VerificationState.Unknown, "Association ambiguë à la relecture ; aucune ligne choisie arbitrairement."); }
            var valid = change.Kind switch
            {
                WriteChangeKind.Remove => before is not null && after is null && beforeRows.Length == 0,
                WriteChangeKind.Add => before is null && after is { } add && afterRows.Length == 1 && RelationRules.Fingerprint(afterRows[0].Relation) == add.Fingerprint,
                WriteChangeKind.Replace => before is { } previous && after is { } updated && afterRows.Length == 1
                    && RelationRules.Fingerprint(afterRows[0].Relation) == updated.Fingerprint && (previous.Key == updated.Key || beforeRows.Length == 0),
                _ => false,
            };
            if (!valid) { return new(VerificationState.Mismatch, "L’état actuel de l’association ne correspond pas au plan ; aucun rejeu."); }
        }
        return new(VerificationState.Verified, "Associations relues par clé et empreinte dans la base précise du plan ; aucune écriture AD.");
    }

    private void Purge()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (source.Epoch != epoch) { drafts.Clear(); bound.Clear(); epoch = source.Epoch; }
        var now = source.Clock.GetUtcNow();
        foreach (var key in drafts.Where(p => p.Value.Expires <= now).Select(p => p.Key).ToArray()) { drafts.Remove(key); }
        foreach (var key in bound.Where(p => p.Value.Plan.ExpiresAt <= now).Select(p => p.Key).ToArray()) { bound.Remove(key); }
    }
    public void Dispose() { lock (gate) { disposed = true; drafts.Clear(); bound.Clear(); } }
}
