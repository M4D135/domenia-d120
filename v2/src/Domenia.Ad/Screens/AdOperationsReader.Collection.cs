using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdOperationsReader
{
    public async Task BeginCollectionAsync(string id, ScopeSelection scope, SurveyMode mode, ImmutableArray<SurveyTarget> targets, CancellationToken cancellationToken)
    {
        await saving.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (gate) { ObjectDisposedException.ThrowIf(disposed, this); if (current is { Open: true }) { throw new DomeniaOperationException("operations.surveyBusy", "Un relevé est déjà en cours."); } }
            var before = await Store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
            var checkpoint = new OperationsSurveyCheckpoint(id, before.DomainDn, scope, mode, targets, [], Now, Now, false, 0);
            var next = before with { Revision = before.Revision + 1, Survey = checkpoint };
            OperationsPersistence.Validate(next);
            await Store.UpdateOperationsAsync(before.Revision, next, cancellationToken).ConfigureAwait(false);
            lock (gate) { activeId = id; activeEpoch = source.Epoch; current = State(checkpoint, true); }
        }
        finally { saving.Release(); }
    }
    public async Task ProgressCollectionAsync(string id, ImmutableArray<Guid> completed, int failed, CancellationToken cancellationToken)
    {
        await saving.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var before = await Store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
            if (before.Survey is not { } survey || survey.Id != id || activeId != id || survey.Completed.Except(completed).Any()) { throw Changed(); }
            var nextSurvey = survey with { Completed = completed, Failed = failed, UpdatedAt = Now };
            var next = before with { Revision = before.Revision + 1, Survey = nextSurvey }; OperationsPersistence.Validate(next);
            await Store.UpdateOperationsAsync(before.Revision, next, cancellationToken).ConfigureAwait(false);
            lock (gate) { current = State(nextSurvey, true) with { StopRequested = current?.StopRequested ?? false }; }
        }
        finally { saving.Release(); }
    }
    public async Task FinishCollectionAsync(string id, bool interrupted, CancellationToken cancellationToken)
    {
        await saving.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var before = await Store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
            if (before.Survey is not { } survey || survey.Id != id || activeId != id) { throw Changed(); }
            var ended = survey with { Interrupted = interrupted, UpdatedAt = Now };
            var left = ended.Targets.Length - ended.Completed.Length;
            var status = interrupted || left > 0 ? OperationsCollectionStatus.Cancelled : ended.Failed > 0 ? OperationsCollectionStatus.Partial : OperationsCollectionStatus.Success;
            var previous = before.Runs.Where(r => r.Family == Family(ended.Mode) && DistinguishedName.AreEqual(r.ScopeDn, ended.Scope.Dn) && r.Subtree == ended.Scope.Subtree).OrderByDescending(r => r.AttemptAt).FirstOrDefault();
            var run = new OperationsCollectionRun(Family(ended.Mode), ended.Scope.Dn, ended.Scope.Label, ended.Scope.Subtree, ended.StartedAt, status, ended.Completed.Length, ended.Targets.Length,
                ended.Failed, status == OperationsCollectionStatus.Success ? Now : previous?.SuccessAt,
                left > 0 ? "Interrompu ; " + left + " postes restent à confirmer avant reprise." : ended.Failed > 0 ? "Certaines lectures ne sont pas confirmées ; aucune nouvelle tentative automatique." : null);
            var measured = source.AccountContext is { } context ? OperationActivity.From(context).Samples() : [];
            var samples = before.Samples.Concat(measured.Select(s => s with { Session = false })).DistinctBy(s => (s.Operation, s.At, s.DurationMs)).OrderByDescending(s => s.At).Take(10000).OrderBy(s => s.At).ToImmutableArray();
            var next = before with { Revision = before.Revision + 1, Runs = [.. before.Runs.Append(run).OrderByDescending(r => r.AttemptAt).Take(1000)], Samples = samples, Survey = left > 0 ? ended : null };
            await Store.UpdateOperationsAsync(before.Revision, next, cancellationToken).ConfigureAwait(false);
            lock (gate) { current = State(ended, false); }
        }
        catch
        {
            lock (gate)
            {
                if (current is { } state) { current = state with { Open = false, Phase = SurveyPhase.Done, EndedAt = Now, Status = "Enregistrement final impossible ; progression durable à vérifier avant reprise." }; }
            }
            throw;
        }
        finally { saving.Release(); }
    }

    private async Task RunRemainingAsync(OperationsSurveyCheckpoint plan, CancellationToken token)
    {
        // Yield so the durable claim and its UI state leave the calling lock before work begins.
        await Task.Yield();
        var done = plan.Completed.ToHashSet(); var failed = plan.Failed; var interrupted = false; string? failure = null;
        try
        {
            var reader = new AdSearchReader(source);
            foreach (var target in plan.Targets.Where(t => !done.Contains(Guid.Parse(t.Id))))
            {
                token.ThrowIfCancellationRequested(); CurrentEpoch();
                using (var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, target.Dn, token).ConfigureAwait(false))
                {
                    var id = Guid.Parse(target.Id);
                    var rows = await access.SearchAsync(new(target.Dn, "(objectClass=computer)", AdSearchScope.Base, ["objectGUID", "userAccountControl"])
                    { SizeLimit = 2, PageSize = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, token).ConfigureAwait(false);
                    if (rows.Count != 1 || rows[0].Guid("objectGUID") != id || !DistinguishedName.AreEqual(rows[0].DistinguishedName, target.Dn)
                        || rows[0].Int("userAccountControl") is not { } uac || AdValues.IsDisabled(uac))
                    { throw Unavailable("Cible déplacée, recréée, désactivée ou non lisible ; relevé arrêté avant la sonde."); }
                }
                var outcome = await reader.ProbeAsync(Guid.Parse(target.Id), plan.Mode, 1, TimeSpan.Zero, token).ConfigureAwait(false);
                done.Add(Guid.Parse(target.Id)); failed += outcome.Denied || outcome.Kind != "online" ? 1 : 0;
                await ProgressCollectionAsync(plan.Id, [.. done], failed, CancellationToken.None).ConfigureAwait(false);
                if (outcome.Denied) { interrupted = true; failure = "Compte refusé ; aucune autre cible contactée."; break; }
            }
        }
        catch (OperationCanceledException) { interrupted = true; failure = "Relevé arrêté ; les mesures terminées restent conservées."; }
        catch (Exception ex)
        {
            interrupted = true; failure = ex is DomeniaOperationException op ? op.Message : "Lecture ou enregistrement impossible ; progression conservée au dernier point validé.";
            source.AccountContext?.Log.Warning("operations.survey.resume : " + ex.GetType().Name);
        }
        finally
        {
            try { await FinishCollectionAsync(plan.Id, interrupted, CancellationToken.None).ConfigureAwait(false); }
            catch (Exception ex)
            {
                failure = "Fin du relevé non enregistrée ; ne pas supposer sa réussite. Les derniers compteurs durables restent consultables.";
                source.AccountContext?.Log.Warning("operations.survey.save : " + ex.GetType().Name);
            }
            lock (gate)
            {
                if (current is { } state) { current = state with { Open = false, Phase = SurveyPhase.Done, EndedAt = Now, Status = failure ?? state.Status }; }
                resumedStop?.Dispose(); resumedStop = null;
            }
        }
    }
}
