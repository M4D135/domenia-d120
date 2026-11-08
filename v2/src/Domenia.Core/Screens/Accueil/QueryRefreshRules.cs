using System.Collections.Immutable;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core.Accueil;

public sealed record FrozenFleetQuery(string Id, long Revision, string Fingerprint, QueryRecipe Recipe)
{
    public string? DomainKey { get; init; }
}

/// <summary>Pure preparation: exact revisions and targets; deriving the missing work never performs a remote read.</summary>
public static class QueryRefreshRules
{
    private sealed class DirectoryPlanIndex(DirectorySnapshot snapshot)
    {
        internal Dictionary<Guid, DirectoryComputer> Computers { get; } = snapshot.Computers.ToDictionary(c => c.ObjectGuid);
        internal DirectoryLdapChain Chain { get; } = new(snapshot);
    }
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<DirectorySnapshot, DirectoryPlanIndex> DirectoryIndexes = new();
    public static ImmutableArray<FrozenFleetQuery> Freeze(QueryLibraryContent library, IEnumerable<FleetLayoutItem> items, IEnumerable<CustomHealthRule> alerts, string? rootDn = null, string board = "Fleet")
    {
        if (board is not ("Fleet" or "Computer")) throw new ArgumentOutOfRangeException(nameof(board));
        var selected = new List<(string Id, long Revision, string? Hash)>();
        foreach (var item in items.Where(i => i.Source == FleetWidgetSource.Query && !i.Paused && !i.Hidden))
        {
            if (item.QueryBinding is { } binding)
            {
                if (rootDn is null) { throw Invalid("Domaine de la liaison importée absent."); }
                try { _ = BoardQueryBindings.Resolve(binding, item.Key, library, rootDn, board); }
                catch (InvalidDataException ex) { throw Invalid(ex.Message); }
                selected.Add((binding.RecipeId, binding.Revision, binding.Fingerprint));
                continue;
            }
            var link = library.Widgets.FirstOrDefault(w => w.Id == item.Key && w.Board == (board == "Fleet" ? "fleet" : "computer"));
            var inherited = library.Consumers.Where(c => c.Kind == "legacy" + board && (c.Id == item.Key || c.RecipeId == item.Key)).ToArray();
            var id = link?.RecipeId ?? (inherited.Length == 1 ? inherited[0].RecipeId : null);
            var revision = link?.BoundRevision ?? (inherited.Length == 1 ? inherited[0].BoundRevision : 0);
            if (id is null || revision < 1) { throw Invalid("Lien de widget absent ou ambigu."); }
            selected.Add((id, revision, null));
        }
        foreach (var alert in alerts.Where(r => r.Enabled && r.Measure == "Query"))
        {
            if (!HealthQueryRules.Valid(alert.Query)) { throw Invalid("Une alerte contient une référence de requête illisible."); }
            var binding = alert.Query!;
            selected.Add((binding.RecipeId, binding.Revision, binding.Fingerprint));
        }
        var result = ImmutableArray.CreateBuilder<FrozenFleetQuery>();
        foreach (var entry in selected.Distinct())
        {
            var record = library.Records.FirstOrDefault(r => r.Id == entry.Id && !r.Archived) ?? throw Invalid("Requête absente ou archivée.");
            var recipe = QueryLibrary.RevisionRecipe(record, entry.Revision) ?? throw Invalid("Révision liée non conservée.");
            var query = QueryEngine.Compile(recipe);
            var hash = record.Revision == entry.Revision ? record.Fingerprint : record.History.First(h => h.Revision == entry.Revision).Fingerprint;
            if (query.Fingerprint != hash || entry.Hash is not null && entry.Hash != hash) { throw Invalid("Empreinte de révision incohérente."); }
            if (query.Target != QueryTarget.Computer) { continue; } // Other targets use the explicit AD stage, never WMI on fabricated computers.
            result.Add(new(entry.Id, entry.Revision, hash, query.Normalized) { DomainKey = rootDn is null ? null : QueryLibrary.RootKey(rootDn) });
        }
        return [.. result.DistinctBy(r => (r.Id, r.Revision, r.Fingerprint))];
    }

    public static void Confirm(QueryLibraryContent library, FrozenFleetQuery frozen, string? rootDn = null)
    {
        if (frozen.DomainKey is { } expected && (rootDn is null || QueryLibrary.RootKey(rootDn) != expected))
        { throw Invalid("Domaine de la révision remplacé depuis le plan."); }
        var record = library.Records.FirstOrDefault(r => r.Id == frozen.Id && !r.Archived);
        var recipe = record is null ? null : QueryLibrary.RevisionRecipe(record, frozen.Revision);
        if (recipe is null || QueryEngine.Compile(recipe).Fingerprint != frozen.Fingerprint)
        { throw Invalid("Requête archivée ou révision remplacée depuis le plan ; aucune nouvelle collecte."); }
    }

    public static ImmutableArray<QueryMeasureRequest> Requests(FrozenFleetQuery frozen, QueryDataset dataset, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> identities, IReadOnlySet<Guid> online, DateTimeOffset now, bool force, int cacheMinutes = 15)
        => [.. Queue(frozen, dataset, scope, identities, online, now, force, cacheMinutes)];

    /// <summary>Checks the complete frozen population before exposing any work. Rich query records live only for one
    /// planning window; per-host requests are then constructed as bounded workers admit them.</summary>
    internal static IEnumerable<QueryMeasureRequest> Queue(FrozenFleetQuery frozen, QueryDataset dataset, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> identities, IReadOnlySet<Guid> online, DateTimeOffset now, bool force, int cacheMinutes = 15,
        CancellationToken cancellationToken = default, IReadOnlyDictionary<string, int>? freshnessSeconds = null)
    {
        var (query, targets) = PrepareTargets(frozen, dataset, scope, identities, online, now, force, cacheMinutes, cancellationToken, freshnessSeconds);
        return Enumerate();

        IEnumerable<QueryMeasureRequest> Enumerate()
        {
            foreach (var (target, details) in targets)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var id = Guid.Parse(target.Id);
                // Presence was explicitly measured by the preceding stage. Never ping again for a query.
                yield return new([id], false, target.Families.Contains("Console"), target.Families.Contains("Inventory"), target.MissingProbes, details)
                { ExpectedIdentities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(id, identities[id]),
                    PersonalProbes = [.. query.Probes.Definitions.Where(p => target.MissingProbes.Contains(p.Key, StringComparer.Ordinal))] };
            }
        }
    }

    /// <summary>A widget preview needs identities, not native requests. Keep the same full validation without creating
    /// per-workstation request objects, arrays or dictionaries before the widget ceiling is checked.</summary>
    internal static IEnumerable<Guid> MissingTargetIds(FrozenFleetQuery frozen, QueryDataset dataset, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> identities, IReadOnlySet<Guid> online, DateTimeOffset now, int cacheMinutes,
        CancellationToken cancellationToken, IReadOnlyDictionary<string, int> freshnessSeconds)
    {
        var (_, targets) = PrepareTargets(frozen, dataset, scope, identities, online, now, false, cacheMinutes, cancellationToken, freshnessSeconds);
        return Enumerate();

        IEnumerable<Guid> Enumerate()
        {
            foreach (var (target, _) in targets)
            { cancellationToken.ThrowIfCancellationRequested(); yield return Guid.Parse(target.Id); }
        }
    }

    private static (CompiledQuery Query, List<(QueryCollectTarget Target, ImmutableArray<WmiReadDefinition> Details)> Targets) PrepareTargets(
        FrozenFleetQuery frozen, QueryDataset dataset, ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> identities,
        IReadOnlySet<Guid> online, DateTimeOffset now, bool force, int cacheMinutes, CancellationToken cancellationToken,
        IReadOnlyDictionary<string, int>? freshnessSeconds)
    {
        var query = QueryEngine.Compile(frozen.Recipe);
        if (query.Fingerprint != frozen.Fingerprint) { throw Invalid("Définition figée altérée."); }
        var directoryIndex = DirectoryIndexes.GetValue(dataset.Directory, static directory => new(directory));
        var evaluation = new QueryEvaluationContext(directoryIndex.Chain, now);
        var computers = identities.Keys.Where(online.Contains).Select(id => directoryIndex.Computers.GetValueOrDefault(id)).OfType<DirectoryComputer>().Where(c =>
            ScopeRules.Contains(scope, c.DistinguishedName) || ScopeRules.IsDomainRoot(scope, dataset.Directory.Domain.RootDn)).ToDictionary(c => c.ObjectGuid);
        var targets = new List<(QueryCollectTarget Target, ImmutableArray<WmiReadDefinition> Details)>();
        foreach (var records in QueryRecordBuilder.EnumerateComputers(dataset, CampaignBranches.Order(computers.Values), now).Chunk(256))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var plan = QueryAnalysis.CollectPlan(query, records, evaluation, now, cacheMinutes: force ? 0 : cacheMinutes, freshnessSeconds: freshnessSeconds);
            if (plan.NotCollectable > 0) { throw Invalid("Une lecture WMI détaillée n’a plus sa définition SELECT ; aucune collecte approchée."); }
            foreach (var target in plan.Targets)
            {
                var id = Guid.Parse(target.Id);
                if (!identities[id].Matches(computers[id])) { throw Invalid("Poste déplacé, recréé ou renommé depuis le plan ; préparez une nouvelle collecte."); }
                var details = target.Families.Contains("Detail") && plan.Detail is { } detail ? ImmutableArray.Create(detail) : [];
                if (target.Families.Contains("Console") || target.Families.Contains("Inventory") || !target.MissingProbes.IsEmpty || !details.IsEmpty)
                { targets.Add((target, details)); }
            }
        }
        return (query, targets);
    }

    private static DomeniaOperationException Invalid(string detail) => new(AccueilService.RefreshQueryMissing,
        detail + " Relisez ou retirez l’élément concerné avant de préparer un autre plan.");
}
