using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed partial class AccueilService
{
    private sealed record RefreshQueryWork(long Epoch, string StoreId, ImmutableArray<FrozenFleetQuery> Queries,
        ImmutableDictionary<Guid, QueryComputerIdentity> Identities);
    private readonly Dictionary<string, RefreshQueryWork> queryRefreshPlans = new(StringComparer.Ordinal);
    private sealed record RefreshTargets(long Epoch, string StoreId, ImmutableDictionary<Guid, QueryComputerIdentity> Identities)
    {
        internal FrozenDirectoryValidation Validation { get; } = new();
    }
    private readonly Dictionary<string, RefreshTargets> refreshTargets = new(StringComparer.Ordinal);

    private static DirectoryState FrozenObservationState(DirectoryState state, RefreshTargets frozen) => state with
    {
        Directory = state.Directory with { Computers = [.. state.Directory.Computers.Where(c => frozen.Identities.ContainsKey(c.ObjectGuid))] },
        Observations = state.Observations with { Workstations = [.. state.Observations.Workstations.Where(o => frozen.Identities.ContainsKey(o.ComputerGuid))] },
    };

    private async Task<RefreshTargets> FreezeRefreshTargetsAsync(IEnumerable<DirectoryComputer> active, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var facts = await Reader.FactsAsync(token).ConfigureAwait(false);
        return new(session.Epoch, facts.StoreId, active.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of));
    }

    private async Task ConfirmRefreshContextAsync(RefreshTargets frozen, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var facts = await Reader.FactsAsync(token).ConfigureAwait(false);
        if (session.Epoch != frozen.Epoch || facts.StoreId != frozen.StoreId)
        { throw new DomeniaOperationException(RefreshScopeChanged, "Session ou base modifiée depuis le plan ; préparez une nouvelle actualisation."); }
    }

    private async Task ConfirmRefreshTargetsAsync(RefreshTargets frozen, CancellationToken token)
    {
        await ConfirmRefreshContextAsync(frozen, token).ConfigureAwait(false);
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        frozen.Validation.Confirm(local.Directory, frozen.Identities);
    }

    private async Task<RefreshQueryWork?> PrepareQueryRefreshAsync(ImmutableArray<FleetLayoutItem> items, DirectoryState state, ScopeSelection scope, string domain,
        CancellationToken token, bool includeHealth = true, ImmutableArray<FleetLayoutItem> computerItems = default)
    {
        var policies = HealthBook(domain);
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).ToArray();
        var alerts = (includeHealth ? active.SelectMany(c => HealthRules.Resolve(policies, DistinguishedName.Parent(c.DistinguishedName)).Policy.CustomRules) : Enumerable.Empty<CustomHealthRule>())
            .Where(r => r.Measure == "Query" && r.Enabled).Distinct().ToArray();
        if (!items.Concat(computerItems.IsDefault ? [] : computerItems).Any(i => i.Source == FleetWidgetSource.Query && !i.Paused && !i.Hidden) && alerts.Length == 0) { return null; }
        var library = queryLibrary ?? throw new DomeniaOperationException(RefreshQueryMissing, RefreshQueryMissingMessage);
        _ = context.Readers.Find<IQueryWorkshopReader>() ?? throw new DomeniaOperationException(RefreshQueryMissing, "Lecteur de requêtes indisponible : aucune collecte lancée.");
        var content = await library.ReadAsync(domain, token).ConfigureAwait(false);
        var queries = QueryRefreshRules.Freeze(content, items, alerts, domain)
            .AddRange(QueryRefreshRules.Freeze(content, computerItems.IsDefault ? [] : computerItems, [], domain, "Computer"))
            .DistinctBy(q => (q.Id, q.Revision, q.Fingerprint)).ToImmutableArray();
        if (queries.IsEmpty) { return null; }
        foreach (var query in queries)
        { await QueryPersonalProbes.ConfirmAsync(QueryEngine.Compile(query.Recipe), context.Preferences, token).ConfigureAwait(false); }
        if (active.Length > OperationsPersistence.MaxTargets || queries.Length > 64)
        { throw new DomeniaOperationException(RefreshQueryMissing, "Collecte des requêtes limitée à " + FrenchText.Integer(OperationsPersistence.MaxTargets) + " postes et 64 révisions par plan. Choisissez une OU plus précise ou mettez des widgets en pause."); }
        var identities = active.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        return new(session.Epoch, (await Reader.FactsAsync(token).ConfigureAwait(false)).StoreId, queries, identities);
    }

    private async Task<string> CollectRefreshQueriesAsync(RefreshQueryWork work, RefreshPlan plan, bool force, string domain, DateTimeOffset onlineSince,
        CancellationToken token)
    {
        var reader = context.Readers.Find<IQueryWorkshopReader>() ?? throw new DomeniaOperationException(RefreshQueryMissing, "Lecteur de requêtes indisponible.");
        var library = queryLibrary ?? throw new DomeniaOperationException(RefreshQueryMissing, "Bibliothèque indisponible.");
        var settings = CollectionSettingsRules.Read(context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var stored) ? stored : null, []);
        var concurrency = settings.Budgets.GetValueOrDefault(CollectionSettingsRules.Concurrency, 4);
        var duration = CollectionCampaignBudget.For(work.Identities.Count, concurrency, settings.Budgets.GetValueOrDefault(CollectionSettingsRules.CampaignMinutes));
        using var budget = new CancellationTokenSource(duration, context.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, budget.Token);
        var cacheMinutes = settings.Budgets.GetValueOrDefault(CollectionSettingsRules.CacheMinutes, 15);
        var accountVersion = AccountAccess.From(context).SelectionVersion;
        var machineGeneration = MachineAccountService.From(context).Generation;
        var requested = 0; var failed = 0; var answered = 0;
        try
        {
            foreach (var query in work.Queries)
            {
                stop.Token.ThrowIfCancellationRequested();
                await ConfirmRefreshQueryStoreAsync(work, stop.Token).ConfigureAwait(false);
                QueryRefreshRules.Confirm(await library.ReadAsync(domain, stop.Token).ConfigureAwait(false), query, domain);
                await QueryPersonalProbes.ConfirmAsync(QueryEngine.Compile(query.Recipe), context.Preferences, stop.Token).ConfigureAwait(false);
                // Re-read locally after each recipe: reused inventory/probes must not be collected twice for two widgets.
                var dataset = await reader.DatasetAsync(stop.Token).ConfigureAwait(false);
                var directoryState = await context.Directory.ReadLocalAsync(stop.Token).ConfigureAwait(false);
                var online = OnlineIds(directoryState, plan.Scope, onlineSince, plan.ReadWithoutEcho).ToHashSet();
                var requests = QueryRefreshRules.Queue(query, dataset, plan.Scope, work.Identities, online, Now, force, cacheMinutes, stop.Token,
                    CollectionSettingsRules.FreshnessTable(settings).ToDictionary(f => f.Family, f => f.Seconds));
                var counts = await QueryRefreshDispatcher.RunAsync(reader, requests, concurrency, work.Epoch, accountVersion, machineGeneration,
                    async (request, stopping) =>
                {
                    await ConfirmRefreshQueryStoreAsync(work, stopping).ConfigureAwait(false);
                    if (AccountAccess.From(context).SelectionVersion != accountVersion || MachineAccountService.From(context).Generation != machineGeneration)
                        throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié pendant la collecte des requêtes ; aucun nouveau poste contacté.");
                    await ProfileProbeCatalog.ConfirmAsync(context.Preferences, request.PersonalProbes, stopping).ConfigureAwait(false);
                }, stop.Token).ConfigureAwait(false);
                requested += counts.Requested; answered += counts.Answered; failed += counts.Failed;
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new DomeniaOperationException("refresh.queryBudget", "Durée maximale de collecte atteinte pour les requêtes. Les sources déjà enregistrées sont conservées ; préparez une reprise explicite."); }
        catch (QueryDefinitionException ex)
        { throw new DomeniaOperationException(RefreshQueryMissing, ex.Message); }
        finally { lock (gate) { latest = null; } }
        var text = FrenchText.Integer(requested) + " lectures ciblées · " + FrenchText.Integer(answered) + " abouties · " + FrenchText.Integer(failed) + " incomplètes ou refusées. Révisions et identités du plan conservées ; aucun second ping.";
        if (failed > 0) { throw new DomeniaOperationException("refresh.queryPartial", text + " Les sources réellement enregistrées sont conservées."); }
        return requested == 0 ? "Aucune lecture supplémentaire : informations encore utilisables ou aucun poste admissible du plan." : text;
    }

    private async Task ConfirmRefreshQueryStoreAsync(RefreshQueryWork work, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var facts = await Reader.FactsAsync(token).ConfigureAwait(false);
        if (session.Epoch != work.Epoch || facts.StoreId != work.StoreId)
        { throw new DomeniaOperationException(RefreshScopeChanged, "Session ou base modifiée depuis le plan ; aucune nouvelle lecture de requête."); }
    }
}
