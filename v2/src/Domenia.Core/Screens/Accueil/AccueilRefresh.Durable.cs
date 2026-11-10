using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed partial class AccueilService
{
    private readonly Dictionary<string, HomeCampaignStored> homeRefreshPlans = new(StringComparer.Ordinal);

    private static bool HomeTargetsProvisional(HomeCampaignCheckpoint plan) => plan.Stages.Contains("directory")
        && !plan.DoneStages.Contains("commit") && plan.PresenceStartedAt is null && plan.PresenceDone.IsEmpty && plan.InventoryDone.IsEmpty
        && !plan.DoneStages.Any(s => s is "presence" or "inventory" or "queries");

    private static string HomeStageLabel(string id) => id switch
    {
        "backup" => "Sauvegarde vérifiée de la base locale",
        "directory" => "Lecture AD de l’OU",
        "commit" => "Reçu d’enregistrement local",
        "presence" => "Relevé de présence (ping)",
        "inventory" => "Inventaire WMI des postes admissibles",
        "queries" => "Informations des requêtes liées",
        _ => id,
    };

    private static RefreshReport HomeReport(HomeCampaignCheckpoint plan) => new(plan.Id, plan.Mode, "interrupted",
        "Actualisation interrompue conservée ; cause précédente non enregistrée · " + plan.Scope.Label, plan.Scope, plan.StartedAt, plan.UpdatedAt,
        [.. plan.Stages.Select(id => new RefreshStageResult(id, HomeStageLabel(id), plan.DoneStages.Contains(id) ? "done" : "stopped",
            plan.DoneStages.Contains(id) ? "Étape enregistrée avant l’interruption."
                : id == "presence" ? FrenchText.Integer(plan.PresenceDone.Length) + "/" + FrenchText.Integer(plan.Targets.Length) + " résultats de présence enregistrés."
                : id == "inventory" ? FrenchText.Integer(plan.InventoryDone.Length) + " inventaires enregistrés."
                : "À reprendre après une nouvelle confirmation.", null, null))], [], false, plan.Forced, plan.Stages.Except(plan.DoneStages).Any());

    /// <summary>Only local reads. Discovery of a checkpoint never schedules a network operation.</summary>
    public async Task<RefreshState> RefreshStatusAsync(CancellationToken token)
    {
        var status = RefreshStatus();
        if (status.Running || context.Readers.Find<IHomeCampaignRecorder>() is not { } recorder) { return status; }
        var raw = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var session = await workingScope.ApplyAsync(raw, token).ConfigureAwait(false);
        // No selected OU is a normal startup state. Keep the checkpoint until its scope can be matched.
        if (session.Scope is not { } scope || session.Domain?.RootDn is not { } domain)
        { return status with { Last = null }; }
        var stored = await recorder.ReadHomeCampaignAsync(token).ConfigureAwait(false);
        if (stored.Plan is { } plan)
        {
            HomeCampaignRules.Validate(plan, (await Reader.FactsAsync(token).ConfigureAwait(false)).StoreId, domain);
            if (ScopeRules.SameScope(plan.Scope, scope))
            {
                // The local checkpoint records progress, not the cause. Preserve the qualified report of this session.
                return status with { Last = status.Last is { } knownReport && knownReport.Id == plan.Id ? knownReport : HomeReport(plan) };
            }
        }
        return status with { Last = status.Last is { } last && ScopeRules.SameScope(last.Scope, scope) ? last with { Resumable = false } : null };
    }

    private async Task<RefreshQueryWork?> RestoreHomeQueriesAsync(HomeCampaignCheckpoint plan, RefreshTargets targets, string domain, CancellationToken token)
    {
        if (plan.Queries.IsEmpty) { return null; }
        var library = queryLibrary ?? throw new DomeniaOperationException(RefreshQueryMissing, RefreshQueryMissingMessage);
        _ = context.Readers.Find<IQueryWorkshopReader>() ?? throw new DomeniaOperationException(RefreshQueryMissing, RefreshQueryMissingMessage);
        var content = await library.ReadAsync(domain, token).ConfigureAwait(false);
        var queries = ImmutableArray.CreateBuilder<FrozenFleetQuery>();
        foreach (var saved in plan.Queries)
        {
            var record = content.Records.FirstOrDefault(r => r.Id == saved.Id && !r.Archived);
            var recipe = record is null ? null : QueryLibrary.RevisionRecipe(record, saved.Revision);
            if (recipe is null) { throw new DomeniaOperationException(RefreshQueryMissing, "Révision du plan durable absente ou archivée ; aucune nouvelle collecte."); }
            var frozen = new FrozenFleetQuery(saved.Id, saved.Revision, saved.Fingerprint, recipe) { DomainKey = QueryLibrary.RootKey(domain) };
            QueryRefreshRules.Confirm(content, frozen, domain);
            await QueryPersonalProbes.ConfirmAsync(QueryEngine.Compile(recipe), context.Preferences, token).ConfigureAwait(false);
            queries.Add(frozen);
        }
        return new(targets.Epoch, targets.StoreId, queries.ToImmutable(), targets.Identities);
    }

    private async Task ConfirmHomeProgressAsync(HomeCampaignCheckpoint plan, CancellationToken token)
    {
        var definitions = (await FrozenProbesAsync(plan.Probes, token).ConfigureAwait(false)).ToDictionary(p => p.Key);
        var identities = plan.Targets.ToDictionary(t => t.Guid);
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var rows = local.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var readings = await Reader.StoredProbesAsync(token).ConfigureAwait(false);
        var since = plan.PresenceStartedAt;
        var memoryRequired = HomeMemoryPolicy.Resolver(plan.MemoryPolicies);
        var memory = await Reader.FactsAsync(token).ConfigureAwait(false);
        var cachePolicy = CollectionCachePolicy.Read(context.Preferences);
        var presence = plan.DoneStages.Contains("presence") ? plan.Targets.Select(t => t.Guid) : plan.PresenceDone;
        // Same predicate and window as SaveHomeProgressAsync: a reading, or a definitive answer about the name, since the campaign.
        if (presence.Any(id => !rows.TryGetValue(id, out var row) || since is not { } start
                || !PresenceOutcomes.Settled(row.Presence, start, Now + RefreshRules.FutureTolerance))
            || plan.InventoryDone.Any(id => !rows.TryGetValue(id, out var row) || !(RefreshRules.InventoryAnswered(row.Inventory, plan.StartedAt, Now)
                    || !plan.Forced && cachePolicy.Inventory(row.Inventory, plan.StartedAt))
                || memoryRequired(identities[id].Dn) && !(HomeMemoryPolicy.Answered(memory.Machines.GetValueOrDefault(id)?.Memory, plan.StartedAt, Now)
                    || !plan.Forced && cachePolicy.Memory(memory.Machines.GetValueOrDefault(id)?.Memory, plan.StartedAt))
                || plan.Probes.Any(probe => !(definitions[probe].Definition.SkipOnDc && (identities[id].UserAccountControl & AdValues.ServerTrustAccount) != 0)
                    && !(RefreshRules.ProbeAnswered(readings.ByProbe.GetValueOrDefault(probe)?.GetValueOrDefault(id), plan.StartedAt, Now)
                        || !plan.Forced && cachePolicy.Probe(probe, readings.ByProbe.GetValueOrDefault(probe)?.GetValueOrDefault(id), identities[id], plan.StartedAt)))))
        { throw new DomeniaOperationException("refresh.progressMissing", "Des mesures du plan durable ne sont plus disponibles dans cette base. Préparez une nouvelle actualisation ; aucune cible déjà cochée ne sera ignorée sans preuve locale."); }
    }

    private async Task<IHomeCampaignLease?> BeginHomeRefreshAsync(RunState state, RefreshTargets targets, RefreshQueryWork? queries,
        HomeCampaignStored? offered, string domain, CancellationToken token)
    {
        if (context.Readers.Find<IHomeCampaignRecorder>() is not { } recorder) { return null; }
        var plan = state.Plan;
        var checkpoint = plan.Mode == "resume" && offered?.Plan is { } previous ? previous with
        { Id = plan.Id, UpdatedAt = Now, Interrupted = false, Forced = previous.Forced || state.Forced }
        : new HomeCampaignCheckpoint(plan.Id, targets.StoreId, domain, plan.Scope, plan.Mode,
            [.. plan.Stages.Select(s => s.Id)], [], [.. targets.Identities.Values.OrderBy(t => t.Guid)], plan.Probes,
            queries is null ? [] : [.. queries.Queries.Select(q => new HomeCampaignQuery(q.Id, q.Revision, q.Fingerprint))],
            [], [], state.StartedAt, state.StartedAt, null, state.Forced, false) { Branches = plan.Branches, ReadWithoutEcho = plan.ReadWithoutEcho, MemoryPolicies = plan.MemoryPolicies };
        return await recorder.BeginHomeCampaignAsync(checkpoint, offered?.Token, token, replace: plan.Mode != "resume").ConfigureAwait(false);
    }

    /// <summary>Polls only the committed local projection while the physical stage retains its admission.</summary>
    private async Task<T> ObserveHomeStageAsync<T>(RunState state, RefreshTargets targets, Func<Task<T>> work)
    {
        var pending = work();
        if (state.Durable is null) { return await pending.ConfigureAwait(false); }
        try
        {
            while (!pending.IsCompleted)
            {
                using var delay = new CancellationTokenSource();
                var tick = Task.Delay(TimeSpan.FromSeconds(10), context.Clock, delay.Token);
                if (await Task.WhenAny(pending, tick).ConfigureAwait(false) == pending)
                { await delay.CancelAsync().ConfigureAwait(false); break; }
                await SaveHomeProgressAsync(state, targets).ConfigureAwait(false);
            }
            return await pending.ConfigureAwait(false);
        }
        catch
        {
            // Failure of the journal stops further work, but does not release the physical worker early.
            await state.Cancellation.CancelAsync().ConfigureAwait(false);
            try { await pending.ConfigureAwait(false); }
            catch (Exception ex) { context.Log.Warning("Étape Accueil interrompue après arrêt : " + ex.GetType().Name + "."); }
            throw;
        }
    }

    private async Task SaveHomeProgressAsync(RunState state, RefreshTargets targets)
    {
        var lease = state.Durable;
        if (lease is null) { return; }
        if (state.DirectoryTargetsPending) { await ConfirmRefreshContextAsync(targets, CancellationToken.None).ConfigureAwait(false); }
        else { await ConfirmRefreshTargetsAsync(targets, CancellationToken.None).ConfigureAwait(false); }
        var committed = await context.Directory.ReadLocalAsync(CancellationToken.None).ConfigureAwait(false);
        var storedProbes = await Reader.StoredProbesAsync(CancellationToken.None).ConfigureAwait(false);
        var checkpoint = lease.State;
        var observations = committed.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var since = checkpoint.PresenceStartedAt ?? state.PresenceStartedAt;
        var presence = checkpoint.PresenceDone.ToHashSet();
        var inventory = checkpoint.InventoryDone.ToHashSet();
        var memoryRequired = HomeMemoryPolicy.Resolver(checkpoint.MemoryPolicies);
        var memory = await Reader.FactsAsync(CancellationToken.None).ConfigureAwait(false);
        var cachePolicy = CollectionCachePolicy.Read(context.Preferences);
        if (!state.DirectoryTargetsPending && since is not null)
        {
            foreach (var target in checkpoint.Targets)
            {
                if (!observations.TryGetValue(target.Guid, out var row)) { continue; }
                // A definitive answer about the name is settled like a reading: « Reprendre » never asks it again.
                if (checkpoint.Stages.Contains("presence") && PresenceOutcomes.Settled(row.Presence, since.Value, Now + RefreshRules.FutureTolerance)) { presence.Add(target.Guid); }
                if (state.InventoryStartedAt is { } inventoryStarted && checkpoint.Stages.Contains("inventory")
                    && CollectionNetworkPolicy.Eligible(row.Presence, checkpoint.ReadWithoutEcho) && row.Presence.CheckedAt is { } pingAt
                    && pingAt >= since && pingAt <= Now + RefreshRules.FutureTolerance
                    && (RefreshRules.InventoryAnswered(row.Inventory, checkpoint.StartedAt, Now)
                        || !checkpoint.Forced && cachePolicy.Inventory(row.Inventory, inventoryStarted))
                    && (!memoryRequired(target.Dn) || HomeMemoryPolicy.Answered(memory.Machines.GetValueOrDefault(target.Guid)?.Memory, checkpoint.StartedAt, Now)
                        || !checkpoint.Forced && cachePolicy.Memory(memory.Machines.GetValueOrDefault(target.Guid)?.Memory, inventoryStarted))
                    && checkpoint.Probes.All(id => state.FrozenProbes.Any(p => p.Key == id && p.Definition.SkipOnDc) && (target.UserAccountControl & 8192) != 0
                        || RefreshRules.ProbeAnswered(storedProbes.ByProbe.GetValueOrDefault(id)?.GetValueOrDefault(target.Guid), checkpoint.StartedAt, Now)
                        || !checkpoint.Forced && cachePolicy.Probe(id, storedProbes.ByProbe.GetValueOrDefault(id)?.GetValueOrDefault(target.Guid), target, inventoryStarted)))
                { inventory.Add(target.Guid); }
            }
        }
        var done = checkpoint.DoneStages.ToHashSet(StringComparer.Ordinal);
        lock (gate)
        {
            foreach (var stage in state.Stages.Where(s => s.State is "done" or "na"))
            {
                // A directory answer is not a durable completion before its qualified SQLite receipt.
                if (stage.Id == "directory" && !state.Stages.Any(s => s.Id == "commit" && s.State == "done")) { continue; }
                if (stage.Id is "inventory" or "queries" && checkpoint.Stages.Contains("presence") && !done.Contains("presence")) { continue; }
                if (stage.Id == "queries" && checkpoint.Stages.Contains("inventory") && !done.Contains("inventory")) { continue; }
                done.Add(stage.Id);
            }
        }
        await lease.SaveAsync([.. checkpoint.Stages.Where(done.Contains)], [.. presence.Order()], [.. inventory.Order()], since, CancellationToken.None).ConfigureAwait(false);
        var branches = CampaignBranches.Summarize(state.Plan.Scope, checkpoint.Targets, presence, inventory);
        lock (gate) { state.Branches = branches; }
    }

    private async Task FinishHomeRefreshAsync(RunState state, RefreshTargets targets, bool complete)
    {
        if (state.Durable is not { } lease) { return; }
        Exception? failure = null;
        try
        {
            try { await SaveHomeProgressAsync(state, targets).ConfigureAwait(false); }
            catch (Exception ex)
            {
                complete = false;
                failure = ex;
                context.Log.Warning("Progression finale Accueil non ajoutée ; le dernier reçu reste conservé (" + ex.GetType().Name + ").");
                if (!state.Stopping) { state.Stopping = true; }
            }
            await lease.FinishAsync(complete && !lease.State.Stages.Except(lease.State.DoneStages).Any(), CancellationToken.None).ConfigureAwait(false);
            if (failure is not null)
            { throw new DomeniaOperationException("refresh.checkpoint", "La progression finale n’a pas pu être confirmée. Le dernier checkpoint reste conservé ; relisez la reprise avant toute nouvelle collecte."); }
        }
        finally { state.Durable = null; lease.Dispose(); }
    }
}
