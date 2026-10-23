using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed partial class AccueilService
{
    private sealed record RefreshQueryWork(long Epoch, string StoreId, ImmutableArray<FrozenFleetQuery> Queries,
        ImmutableDictionary<Guid, QueryComputerIdentity> Identities);
    private readonly Dictionary<string, RefreshQueryWork> queryRefreshPlans = new(StringComparer.Ordinal);
    private sealed record RefreshTargets(long Epoch, string StoreId, ImmutableDictionary<Guid, QueryComputerIdentity> Identities);
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

    private async Task ConfirmRefreshTargetsAsync(RefreshTargets frozen, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var facts = await Reader.FactsAsync(token).ConfigureAwait(false);
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var actual = local.Directory.Computers.ToDictionary(c => c.ObjectGuid);
        if (session.Epoch != frozen.Epoch || facts.StoreId != frozen.StoreId
            || frozen.Identities.Any(p => !actual.TryGetValue(p.Key, out var pc) || !p.Value.Matches(pc)))
        { throw new DomeniaOperationException(RefreshScopeChanged, "Identité, session ou base modifiée depuis le plan ; préparez une nouvelle actualisation."); }
    }

    private async Task<RefreshQueryWork?> PrepareQueryRefreshAsync(ImmutableArray<FleetLayoutItem> items, DirectoryState state, ScopeSelection scope, string domain,
        CancellationToken token)
    {
        var policies = HealthBook(domain);
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).ToArray();
        var alerts = active.SelectMany(c => HealthRules.Resolve(policies, DistinguishedName.Parent(c.DistinguishedName)).Policy.CustomRules)
            .Where(r => r.Measure == "Query" && r.Enabled).Distinct().ToArray();
        if (!items.Any(i => i.Source == FleetWidgetSource.Query && !i.Paused) && alerts.Length == 0) { return null; }
        var library = queryLibrary ?? throw new DomeniaOperationException(RefreshQueryMissing, RefreshQueryMissingMessage);
        _ = context.Readers.Find<IQueryWorkshopReader>() ?? throw new DomeniaOperationException(RefreshQueryMissing, "Lecteur de requêtes indisponible : aucune collecte lancée.");
        var content = await library.ReadAsync(domain, token).ConfigureAwait(false);
        var queries = QueryRefreshRules.Freeze(content, items, alerts);
        if (queries.IsEmpty) { return null; }
        if (active.Length > 1000 || queries.Length > 64)
        { throw new DomeniaOperationException(RefreshQueryMissing, "Collecte des requêtes limitée à 1 000 postes et 64 révisions par plan. Choisissez une OU plus précise ou mettez des widgets en pause."); }
        var identities = active.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        return new(session.Epoch, (await Reader.FactsAsync(token).ConfigureAwait(false)).StoreId, queries, identities);
    }

    private async Task<string> CollectRefreshQueriesAsync(RefreshQueryWork work, RefreshPlan plan, bool force, string domain, DateTimeOffset onlineSince,
        CancellationToken token)
    {
        var reader = context.Readers.Find<IQueryWorkshopReader>() ?? throw new DomeniaOperationException(RefreshQueryMissing, "Lecteur de requêtes indisponible.");
        var library = queryLibrary ?? throw new DomeniaOperationException(RefreshQueryMissing, "Bibliothèque indisponible.");
        using var budget = new CancellationTokenSource(TimeSpan.FromMinutes(10), context.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, budget.Token);
        var requested = 0; var failed = 0; var answered = 0;
        try
        {
            foreach (var query in work.Queries)
            {
                stop.Token.ThrowIfCancellationRequested();
                await ConfirmRefreshQueryStoreAsync(work, stop.Token).ConfigureAwait(false);
                QueryRefreshRules.Confirm(await library.ReadAsync(domain, stop.Token).ConfigureAwait(false), query);
                // Re-read locally after each recipe: reused inventory/probes must not be collected twice for two widgets.
                var dataset = await reader.DatasetAsync(stop.Token).ConfigureAwait(false);
                var directoryState = await context.Directory.ReadLocalAsync(stop.Token).ConfigureAwait(false);
                var online = OnlineIds(directoryState, plan.Scope, onlineSince).ToHashSet();
                var requests = QueryRefreshRules.Requests(query, dataset, plan.Scope, work.Identities, online, Now, force);
                foreach (var request in requests)
                {
                    stop.Token.ThrowIfCancellationRequested();
                    await ConfirmRefreshQueryStoreAsync(work, stop.Token).ConfigureAwait(false);
                    var result = await reader.MeasureAsync(request with { ExpectedEpoch = work.Epoch }, stop.Token).ConfigureAwait(false);
                    requested += result.Requested; answered += result.Answered; failed += result.Failed + result.SkippedDisabled;
                }
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new DomeniaOperationException("refresh.queryBudget", "Budget de 10 min atteint pour les requêtes. Les sources déjà enregistrées sont conservées ; préparez une reprise explicite."); }
        catch (QueryDefinitionException ex)
        { throw new DomeniaOperationException(RefreshQueryMissing, ex.Message); }
        finally { lock (gate) { latest = null; } }
        var text = FrenchText.Integer(requested) + " lectures ciblées · " + FrenchText.Integer(answered) + " abouties · " + FrenchText.Integer(failed) + " incomplètes ou refusées. Révisions et identités du plan conservées ; aucun second ping.";
        if (failed > 0) { throw new DomeniaOperationException("refresh.queryPartial", text + " Les sources réellement enregistrées sont conservées."); }
        return requested == 0 ? "Aucune lecture supplémentaire : informations encore utilisables ou aucun poste du plan en ligne." : text;
    }

    private async Task ConfirmRefreshQueryStoreAsync(RefreshQueryWork work, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var facts = await Reader.FactsAsync(token).ConfigureAwait(false);
        if (session.Epoch != work.Epoch || facts.StoreId != work.StoreId)
        { throw new DomeniaOperationException(RefreshScopeChanged, "Session ou base modifiée depuis le plan ; aucune nouvelle lecture de requête."); }
    }
}
