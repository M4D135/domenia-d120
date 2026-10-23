using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Sealed, local-only sync mutations. No LDAP call or disk write is made while preparing a plan.</summary>
public sealed class AdSyncStoreExecutor(AdDirectorySource source) : ISyncStoreExecutor, IWritePlanBinder
{
    private sealed record Prepared(SyncLocalChange Change, long Epoch, string Operator);
    private readonly ConditionalWeakTable<WritePlanDraft, Prepared> drafts = new();
    private readonly Dictionary<string, Prepared> plans = new(StringComparer.Ordinal);
    private readonly Lock gate = new();
    private ISyncLocalStore Store => source.LocalStore as ISyncLocalStore
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Stockage de synchronisation indisponible.");
    public string Kind => SyncStoreChange.Kind;

    public async Task<WritePlanDraft> PlanBatchAsync(string batchId, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var batch = await AdSyncState.For(source).ReadAsync(batchId, cancellationToken).ConfigureAwait(false);
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        if (batch.StoreId != local.StoreId || batch.Revision != local.Revision || batch.BeforeSha256 != SyncLocalIdentity.Fingerprint(local))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "La base a changé depuis la lecture ; relancez un aperçu avant son enregistrement."); }
        if (batch.Epoch != session.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Connexion modifiée depuis la lecture ; lot écarté."); }
        var change = Change(local) with { Rows = batch.Rows, Coverage = batch.Coverage, Absences = batch.Absences, ResolvedGaps = batch.ResolvedGaps };
        var partial = batch.Coverage?.Partial == true;
        var effects = new List<WriteChange>
        {
            Effect("index.rows", "Objets effectivement lus", batch.Rows.Length),
            Effect("index.absences", "Disparitions à vérifier, copies conservées", batch.Absences.Length),
            Effect("index.gaps", "Écarts de recensement résolus", batch.ResolvedGaps.Length),
        };
        if (batch.Coverage is { } coverage)
        { effects.Add(new("coverage", "Couverture", WriteChangeKind.Replace, null, partial ? "Tentative incomplète ; dernier repère complet conservé" : "Lecture complète du périmètre choisi", null, coverage.Key)); }
        return Prepare(local, change, session, "Enregistrer la lecture dans la base locale", batch.Label,
            SyncStoreChange.BatchAttribute, "index", batch.Id, SyncLocalIdentity.PayloadFingerprint(change), batch.Rows.Length + batch.Absences.Length + batch.ResolvedGaps.Length,
            effects, partial ? "Lecture partielle : seuls les objets reçus sont enregistrés. Aucune disparition déduite." : "Résultats lus dans l’annuaire ; aucun objet absent n’est supprimé.");
    }

    public async Task<WritePlanDraft> PlanSnapshotCaptureAsync(string? label, SyncScope scope, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        if (!SyncLocations.InScope(scope.Dn, local.DomainDn) || scope.IsDomain != DistinguishedName.AreEqual(scope.Dn, local.DomainDn))
        { throw new DomeniaOperationException(SyncErrors.OutsideDomain, "Périmètre du relevé hors domaine ou ambigu."); }
        if (local.UnidentifiedLegacyObjects > 0) { throw WriteErrors.Refusal(WriteErrors.Stale, "Des objets historiques sans GUID doivent être relus dans l’annuaire avant de capturer un relevé."); }
        if (local.Snapshots.Length >= SyncSnapshots.MaxPerDomain) { throw new DomeniaOperationException(SyncErrors.SnapshotLimit, SyncErrors.SnapshotLimitMessage); }
        var selection = new ScopeSelection(scope.Dn, scope.Label, scope.Subtree);
        var lines = local.Rows.Where(x => ScopeRules.Contains(selection, x.Dn)).Select(SnapshotLine.From).ToImmutableArray();
        if (lines.Length > SyncSnapshots.MaxObjects) { throw new DomeniaOperationException(SyncErrors.SnapshotTooLarge, SyncErrors.SnapshotTooLargeMessage); }
        var coverage = SyncCoverageRules.Coverage(scope.Dn, local.DomainDn, local.Scopes, source.Clock.GetUtcNow(), source.Zone, scope.Subtree);
        var request = SyncSnapshots.Request(local.DomainDn, scope.Dn, scope.Subtree, label, coverage, WritePlans.NewId(), source.Clock.GetUtcNow(), source.Zone);
        var capture = new SnapshotRecord(request.Id, request.Label, local.DomainDn, request.ScopeDn, request.Subtree, request.CapturedAt,
            request.Coverage.State, request.Coverage.At, request.Coverage.Source, request.Coverage.Text, lines, SyncSnapshots.Fingerprint(lines));
        return Prepare(local, Change(local) with { Capture = capture }, session, "Enregistrer un relevé du périmètre", capture.Label,
            SyncStoreChange.SnapshotCaptureAttribute, "capture", capture.Id, capture.RowsSha256, lines.Length,
            [Effect("snapshot.count", "Objets copiés", lines.Length)], request.Coverage.Text + " " + SyncSnapshots.Notice);
    }

    public async Task<WritePlanDraft> PlanSnapshotDeleteAsync(string snapshotId, CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        var snapshot = local.Snapshots.FirstOrDefault(x => x.Id == snapshotId)
            ?? throw new DomeniaOperationException(SyncErrors.SnapshotUnknown, SyncErrors.SnapshotUnknownMessage);
        return Prepare(local, Change(local) with { DeleteSnapshot = snapshotId }, session, "Supprimer un relevé local", snapshot.Label,
            SyncStoreChange.SnapshotDeleteAttribute, "delete", snapshot.Id, snapshot.RowsSha256, snapshot.Lines.Length,
            [], "Le relevé disparaît de cette base ; les objets de l’annuaire et les autres relevés sont conservés.");
    }

    public async Task<WritePlanDraft> PlanParkResetAsync(CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        var park = local.Park ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Mémoire du parc indisponible.");
        if (park.Total == 0) { throw new DomeniaOperationException(SyncErrors.ParkEmpty, SyncErrors.ParkEmptyMessage); }
        if (park.Truncated || park.Rejected > 0 || park.UncertainDates > 0 || park.Rows.Length != park.Total)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Relevé du parc partiel ou illisible ; aucune suppression proposée."); }
        return Prepare(local, Change(local) with { ResetPark = true }, session, "Oublier les relevés du parc", "Mémoire locale du parc",
            SyncStoreChange.ParkResetAttribute, "park", "reset", park.Fingerprint, checked((int)park.Total), [],
            "Seul park_state est vidé après sauvegarde vérifiée. Associations, historique, index et caches de sessions sont conservés. Les résultats d’un passage antérieur seront refusés.");
    }

    private static SyncLocalChange Change(SyncLocalState local) => new(local.StoreId, local.Revision, SyncLocalIdentity.Fingerprint(local), null!, [], null, [], [], null, null);
    private static WriteChange Effect(string attribute, string label, int count) => new(attribute, label, WriteChangeKind.Replace, null,
        SyncStoreChange.Objects(count), null, count.ToString(System.Globalization.CultureInfo.InvariantCulture));

    private WritePlanDraft Prepare(SyncLocalState local, SyncLocalChange change, SessionSnapshot session, string title, string label,
        string attribute, string kind, string id, string sha, int count, IEnumerable<WriteChange> effects, string notice)
    {
        if (session.Epoch != source.Epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la préparation."); }
        var root = session.Domain?.RootDn;
        if (string.IsNullOrWhiteSpace(root) && session.Domain?.DnsName is { } dns)
        {
            var labels = dns.Split('.');
            if (labels.Length > 0 && labels.All(x => x.Length is > 0 and <= 63 && x.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')))
            { root = string.Join(',', labels.Select(x => "DC=" + x)); }
        }
        if (string.IsNullOrWhiteSpace(root) || !DistinguishedName.AreEqual(root, local.DomainDn))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "La base ne correspond pas au domaine de cette session ; aucun plan local préparé."); }
        var head = new WriteChange(attribute, label, WriteChangeKind.Replace, null, label + " · " + SyncStoreChange.Objects(count), null, SyncStoreChange.HeadValue(kind, id, sha, count));
        var target = SyncStoreChange.IndexTarget(label, false) with { Dn = SyncLocalIdentity.Target(local.StoreId, local.DomainDn) };
        var binding = new[]
        {
            new WriteChange(SyncLocalIdentity.StateAttribute, "Base et révision relues", WriteChangeKind.Replace, "Révision " + local.Revision, "Révision suivante", SyncLocalIdentity.StateValue(change), null),
            new WriteChange(SyncLocalIdentity.PayloadAttribute, "Empreinte du changement", WriteChangeKind.Replace, null, "Lot lié au plan", null, SyncLocalIdentity.PayloadFingerprint(change)),
        };
        var draft = SyncStoreChange.Draft(title, label, notice, target, head, binding.Concat(effects),
            [new(Tone.Info, "Sauvegarde complète vérifiée avant la transaction, puis relecture de toutes les données modifiées et du reçu.")],
            SyncStoreChange.BackedUp("La copie antérieure est conservée dans Backups."), null) with { Origin = WritePlanOrigin.From(session) };
        drafts.Add(draft, new(change, session.Epoch, session.Account.Login));
        return draft;
    }

    public void Bind(WritePlanDraft draft, WritePlan plan)
    {
        lock (gate)
        {
            foreach (var id in plans.Where(x => x.Value.Change.Plan.ExpiresAt <= source.Clock.GetUtcNow()).Select(x => x.Key).ToArray()) { plans.Remove(id); }
            if (!drafts.TryGetValue(draft, out var pending) || draft.Origin?.Epoch != source.Epoch || !WritePlans.IsIntact(plan)
                || plan.Kind != Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsPlanId(plan.Id)
                || plan.Operator != pending.Operator || plan.Target != draft.Target || plan.Controller != draft.Controller
                || plan.Confirmation != draft.Confirmation || !plan.Changes.SequenceEqual(draft.Changes))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Brouillon local absent ou modifié ; préparez un nouveau plan."); }
            if (plans.Count >= 64) { throw WriteErrors.Refusal(WriteErrors.Stale, "Trop de plans locaux en attente ; attendez leur expiration."); }
            plans.Add(plan.Id, pending with { Change = pending.Change with { Plan = plan } }); drafts.Remove(draft);
        }
    }

    private Prepared? Find(WritePlan plan)
    {
        lock (gate)
        {
            if (!WritePlans.IsIntact(plan) || !plans.TryGetValue(plan.Id, out var found) || found.Epoch != source.Epoch
                || found.Change.Plan.Fingerprint != plan.Fingerprint || plan.ExpiresAt <= source.Clock.GetUtcNow()) { return null; }
            return found;
        }
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var pending = Find(plan);
        if (pending is null) { return WritePrecheck.Stale("Plan absent, expiré ou connexion modifiée ; aucune écriture."); }
        await ValidateBatchAsync(pending.Change, cancellationToken).ConfigureAwait(false);
        return await Store.CheckSyncChangeAsync(pending.Change, cancellationToken).ConfigureAwait(false);
    }

    private async Task ValidateBatchAsync(SyncLocalChange change, CancellationToken token)
    {
        if (SyncStoreChange.Head(change.Plan) is not { Operation: SyncStoreOperation.Batch } head) { return; }
        var batch = await AdSyncState.For(source).ReadAsync(head.Id, token).ConfigureAwait(false);
        var reread = change with { StoreId = batch.StoreId, ExpectedRevision = batch.Revision, BeforeSha256 = batch.BeforeSha256,
            Rows = batch.Rows, Coverage = batch.Coverage, Absences = batch.Absences, ResolvedGaps = batch.ResolvedGaps };
        if (SyncLocalIdentity.PayloadFingerprint(reread) != SyncLocalIdentity.PayloadFingerprint(change))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Le lot temporaire diffère du plan confirmé ; aucune écriture."); }
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var pending = Find(plan) ?? throw WriteErrors.Refusal(WriteErrors.Stale, "Plan absent, expiré ou connexion modifiée ; aucune écriture.");
        try
        {
            await ValidateBatchAsync(pending.Change, cancellationToken).ConfigureAwait(false);
            var receipt = await Store.ApplySyncChangeAsync(pending.Change, cancellationToken).ConfigureAwait(false);
            var head = SyncStoreChange.Head(plan);
            if (head?.Operation == SyncStoreOperation.Batch)
            {
                var memory = AdSyncState.For(source);
                memory.Remove(head.Id);
            }
            return new(WriteResult.Applied, receipt.Text);
        }
        finally
        {
            // Verification uses the durable proof; never retain a large sent batch, including an uncertain outcome.
            lock (gate) { plans.Remove(plan.Id); }
        }
    }

    public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) => Store.VerifySyncChangeAsync(plan, cancellationToken);
}
