using System.Collections.Immutable;
using System.Diagnostics;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdSyncReader
{
    private static string ModeLabel(SyncReadMode mode) => mode switch
    {
        SyncReadMode.Ou => "Lecture de l’OU choisie",
        SyncReadMode.Incremental => "Changements USN et recensement des identités",
        _ => "Lecture complète du domaine",
    };

    public async Task<SyncReadResult> RunReadAsync(string estimateId, Action<SyncProgress> progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(progress);
        SyncEstimate estimate; long epoch;
        lock (State.Gate)
        {
            State.Purge();
            if (!State.Estimates.Remove(estimateId, out var held) || !held.Value.Ready) { throw new DomeniaOperationException("sync.estimateExpired", "Estimation absente, expirée ou non exécutable."); }
            estimate = held.Value; epoch = held.Epoch;
        }
        var run = Start(estimate.Target, estimate.Scope.Label); var watch = Stopwatch.StartNew();
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, run.Stop.Token); budget.CancelAfter(estimate.BudgetMs);
        var rows = ImmutableArray.CreateBuilder<IndexRecord>(); var identities = new HashSet<Guid>(); SyncCut? cut = null;
        var notes = ImmutableArray.CreateBuilder<string>();
        try
        {
            if (source.LocalStore is not IPreparedDirectoryCache prepared) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Sauvegarde préalable indisponible."); }
            progress(new(run.Id, SyncPhase.Backup, "Sauvegarde vérifiée", 0, null, null, 0, null, "Préparation d’un point de retour avant lecture."));
            await prepared.PrepareAsync(budget.Token).ConfigureAwait(false);
            var local = await Store.ReadSyncStateAsync(budget.Token).ConfigureAwait(false);
            using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, estimate.Scope.Dn, budget.Token).ConfigureAwait(false);
            var maximum = checked((int)Math.Min(300_000, estimate.MaxObjects == 0 ? 300_000 : estimate.MaxObjects));
            var remote = estimate.Target == SyncTarget.Domain ? await ControllerStampAsync(access, budget.Token).ConfigureAwait(false) : null;
            var checkpoint = LocalCheckpoint(local);
            var eligibility = CanUseCheckpoint(local, remote);
            var mode = estimate.Target == SyncTarget.Ou ? SyncReadMode.Ou
                : estimate.Mode == SyncReadMode.Incremental && !estimate.Rebuild && eligibility.Usable ? SyncReadMode.Incremental : SyncReadMode.Full;
            if (estimate.Target == SyncTarget.Domain && !eligibility.Usable) { notes.Add(eligibility.Reason); }
            HashSet<Guid>? census = null;
            if (mode == SyncReadMode.Incremental)
            {
                try
                {
                    progress(new(run.Id, SyncPhase.Reading, "Recensement des identités", 0, null, null, checked((int)watch.ElapsedMilliseconds), null, "Lecture paginée des GUID du domaine, sans secret."));
                    census = await CensusAsync(access, local.DomainDn, maximum, budget.Token).ConfigureAwait(false);
                    if (census.Count == 0 && local.Rows.Length > 0) { cut = SyncCoverageRules.Cut("error", 0, 0); notes.Add("Recensement vide malgré une base existante : aucun repère avancé."); }
                    var known = local.Rows.Select(x => x.ObjectGuid).ToHashSet();
                    if (local.UnidentifiedLegacyObjects > 0 || census.Any(x => !known.Contains(x)))
                    {
                        mode = SyncReadMode.Full; census = null;
                        notes.Add("Une identité visible manque dans la base : lecture complète des attributs dans le budget confirmé, sans réutiliser l’ancien USN.");
                    }
                }
                catch (OperationCanceledException) { cut = Interrupted(); }
                catch (DomeniaOperationException ex) { cut = SyncCoverageRules.Cut(ex.Code == "sync.censusVolume" ? "volume" : "error", maximum, 0); notes.Add("Recensement non terminé : " + ex.Code + "."); }
                catch (InvalidDataException) { cut = SyncCoverageRules.Cut("error", 0, 0); notes.Add("Identités du recensement non qualifiées ; aucun repère avancé."); }
            }
            foreach (var type in new[] { IndexObjectType.Computer, IndexObjectType.User })
            {
                if (cut is not null) { break; }
                var remaining = maximum - rows.Count;
                if (remaining <= 0) { cut = SyncCoverageRules.Cut("volume", maximum, rows.Count); break; }
                try
                {
                    var filter = type == IndexObjectType.Computer ? AdDirectoryMapper.ComputerFilter : AdDirectoryMapper.UserFilter;
                    if (mode == SyncReadMode.Incremental) { filter = DeltaFilter(filter, checkpoint!); }
                    var entries = await access.SearchAsync(new(estimate.Scope.Dn, filter,
                        estimate.Scope.Subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel, type == IndexObjectType.Computer ? AdDirectoryMapper.ComputerAttributes : AdDirectoryMapper.UserAttributes)
                    { PageSize = 500, SizeLimit = remaining + 1, Timeout = TimeSpan.FromSeconds(30), Budget = TimeSpan.FromMilliseconds(Math.Max(1, estimate.BudgetMs - watch.ElapsedMilliseconds)) }, budget.Token).ConfigureAwait(false);
                    var observed = source.Clock.GetUtcNow();
                    foreach (var entry in entries.Take(remaining))
                    {
                        var row = Project(entry, type, observed);
                        if (row is null || !ScopeRules.Contains(new(estimate.Scope.Dn, estimate.Scope.Label, estimate.Scope.Subtree), entry.DistinguishedName)
                            || !identities.Add(row.ObjectGuid) || mode == SyncReadMode.Incremental && row.Usn <= checkpoint!.Usn)
                        { cut = SyncCoverageRules.Cut("error", 0, rows.Count); continue; }
                        rows.Add(row);
                    }
                    if (entries.Count > remaining) { cut = SyncCoverageRules.Cut("volume", maximum, rows.Count); }
                    progress(new(run.Id, SyncPhase.Reading, ModeLabel(mode), rows.Count, null, null, checked((int)watch.ElapsedMilliseconds), null, FrenchText.Count(rows.Count, "objet lu", "objets lus")));
                }
                catch (OperationCanceledException) { cut = Interrupted(); }
                catch (DomeniaOperationException ex) { cut = SyncCoverageRules.Cut("error", 0, rows.Count); notes.Add("Lecture interrompue : " + ex.Code + "."); }
            }
            if (cut is null && remote is not null)
            {
                try
                {
                    if (await ReadInvocationAsync(access, remote.ServiceDn, budget.Token).ConfigureAwait(false) != remote.Invocation)
                    { cut = SyncCoverageRules.Cut("error", 0, rows.Count); notes.Add("Instance du contrôleur modifiée pendant la passe : aucun repère avancé."); }
                }
                catch (OperationCanceledException) { cut = Interrupted(); }
                catch (DomeniaOperationException ex) { cut = SyncCoverageRules.Cut("error", 0, rows.Count); notes.Add("Instance non revérifiée : " + ex.Code + "."); }
            }
            access.EnsureCurrent();
            if (source.Epoch != epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée : aucun lot publié."); }
            var at = source.Clock.GetUtcNow(); var built = rows.ToImmutable();
            if (mode != SyncReadMode.Incremental)
            { cut ??= SyncReconcile.EmptyReadCut(built.Length, local.Rows.Length, [], null, estimate.Target == SyncTarget.Domain, false, estimate.Rebuild); }
            var complete = cut is null;
            var reconciliation = SyncReconcile.Reconcile(local.Rows.ToDictionary(x => x.ObjectGuid), built, estimate.Scope.Dn,
                complete && estimate.Scope.Subtree && mode != SyncReadMode.Incremental, estimate.Rebuild);
            var counts = reconciliation.Counts with { TotalAfter = local.Rows.Length + reconciliation.Counts.Added };
            var unseen = complete && mode == SyncReadMode.Incremental && census is not null
                ? local.Rows.Where(x => !census.Contains(x.ObjectGuid) && !identities.Contains(x.ObjectGuid)).ToImmutableArray()
                : reconciliation.Unseen;
            counts = counts with { Unseen = unseen.Length };
            var absences = unseen.Select(x => new AbsenceRecord(x.ObjectGuid, x.Name, x.Type, x.Dn, null, AbsenceStatus.NotSeen, at, null,
                "Non revu par le recensement complet ; copie locale conservée jusqu’à vérification par GUID.", estimate.Scope.Dn, access.Controller)).ToImmutableArray();
            var key = estimate.Scope.IsDomain ? "directory" : "ou:" + (estimate.Scope.Subtree ? "" : "onelevel:") + estimate.Scope.Dn.ToLowerInvariant();
            if (!complete) { key = "attempt:" + key; }
            var advances = complete && estimate.Scope.IsDomain && estimate.Scope.Subtree && remote is not null && counts.TotalAfter > 0;
            var coverage = new SyncStateEntry(key, estimate.Scope.Dn, at, estimate.Scope.Subtree ? "Subtree" : "OneLevel", !complete, built.Length,
                remote?.Controller ?? access.Controller, advances ? remote!.Usn : 0, advances ? remote!.Invocation.ToString("D") : null, cut?.Reason, cut?.Limit ?? 0)
            { ReaderFingerprint = advances ? remote!.Reader : null, CheckpointItems = advances ? counts.TotalAfter : null, Incremental = mode == SyncReadMode.Incremental };
            var batch = new AdSyncBatch(WritePlans.NewId(), ModeLabel(mode) + " · " + estimate.Scope.Label, epoch, at, at.AddMinutes(15), built,
                coverage, absences, [.. local.Gaps.Where(x => identities.Contains(x.ObjectGuid)).Select(x => x.ObjectGuid)]).AtBase(local);
            await State.HoldAsync(batch, cancellationToken).ConfigureAwait(false);
            var sha = SyncReconcile.Fingerprint(built);
            notes.Add("Les absences ne prouvent aucune suppression. Les anciennes lignes sont conservées.");
            var result = new SyncReadResult(run.Id, batch.Id, estimate.Target, estimate.Scope, mode, ModeLabel(mode), complete, cut,
                remote?.Controller ?? access.Controller ?? "Non établi", remote?.Invocation.ToString("D"), remote?.Usn ?? 0, at,
                checked((int)watch.ElapsedMilliseconds), built.Length, built.Count(x => x.Type == IndexObjectType.User), built.Count(x => x.Type == IndexObjectType.Computer), counts, reconciliation.Samples,
                SyncIndex.LapsSchemaUnknown, "Seules les expirations LAPS lisibles sont relevées ; aucun secret demandé.", advances,
                advances ? "USN lu avant la passe et instance revérifiée ; le repère avancera seulement dans la transaction confirmée."
                    : "Repère USN non avancé : réponse incomplète ou instance du contrôleur non certifiée.", 0, sha, built.Length,
                complete ? "Lecture terminée ; confirmez son enregistrement local." : "Lecture incomplète ; seules les lignes effectivement reçues peuvent être enregistrées.",
                notes.ToImmutable(), built.Length > 0 || complete, batch.Expires, estimate.Rebuild);
            progress(new(run.Id, SyncPhase.Done, "Aperçu prêt", built.Length, built.Length, null, checked((int)watch.ElapsedMilliseconds), 100, result.Summary));
            return result;
        }
        finally { Finish(run.Stop); }

        SyncCut Interrupted() => SyncCoverageRules.Cut(run.Stop.IsCancellationRequested || cancellationToken.IsCancellationRequested ? "arret" : "temps", estimate.BudgetMs, rows.Count);
    }
}
