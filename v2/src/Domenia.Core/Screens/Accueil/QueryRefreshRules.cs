using System.Collections.Immutable;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core.Accueil;

public sealed record FrozenFleetQuery(string Id, long Revision, string Fingerprint, QueryRecipe Recipe);

/// <summary>Pure preparation: exact revisions and targets; deriving the missing work never performs a remote read.</summary>
public static class QueryRefreshRules
{
    public static ImmutableArray<FrozenFleetQuery> Freeze(QueryLibraryContent library, IEnumerable<FleetLayoutItem> items, IEnumerable<CustomHealthRule> alerts)
    {
        var selected = new List<(string Id, long Revision, string? Hash)>();
        foreach (var item in items.Where(i => i.Source == FleetWidgetSource.Query && !i.Paused))
        {
            var link = library.Widgets.FirstOrDefault(w => w.Id == item.Key && w.Board == "fleet");
            var inherited = library.Consumers.Where(c => c.Kind == "legacyFleet" && (c.Id == item.Key || c.RecipeId == item.Key)).ToArray();
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
            result.Add(new(entry.Id, entry.Revision, hash, query.Normalized));
        }
        return [.. result.DistinctBy(r => (r.Id, r.Revision, r.Fingerprint))];
    }

    public static void Confirm(QueryLibraryContent library, FrozenFleetQuery frozen)
    {
        var record = library.Records.FirstOrDefault(r => r.Id == frozen.Id && !r.Archived);
        var recipe = record is null ? null : QueryLibrary.RevisionRecipe(record, frozen.Revision);
        if (recipe is null || QueryEngine.Compile(recipe).Fingerprint != frozen.Fingerprint)
        { throw Invalid("Requête archivée ou révision remplacée depuis le plan ; aucune nouvelle collecte."); }
    }

    public static ImmutableArray<QueryMeasureRequest> Requests(FrozenFleetQuery frozen, QueryDataset dataset, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> identities, IReadOnlySet<Guid> online, DateTimeOffset now, bool force)
    {
        var query = QueryEngine.Compile(frozen.Recipe);
        if (query.Fingerprint != frozen.Fingerprint) { throw Invalid("Définition figée altérée."); }
        var evaluation = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
        var records = QueryRecordBuilder.Build(dataset, QueryTarget.Computer, scope, now)
            .Where(r => Guid.TryParse(r.Id, out var id) && online.Contains(id) && identities.ContainsKey(id)).ToArray();
        var plan = QueryAnalysis.CollectPlan(query, records, evaluation, now, cacheMinutes: force ? 0 : 15);
        if (plan.NotCollectable > 0) { throw Invalid("Une lecture WMI détaillée n’a plus sa définition SELECT ; aucune collecte approchée."); }
        var requests = ImmutableArray.CreateBuilder<QueryMeasureRequest>();
        foreach (var target in plan.Targets)
        {
            var id = Guid.Parse(target.Id);
            var actual = dataset.Directory.Computers.Single(c => c.ObjectGuid == id);
            if (!identities[id].Matches(actual)) { throw Invalid("Poste déplacé, recréé ou renommé depuis le plan ; préparez une nouvelle collecte."); }
            // Presence was explicitly measured by the preceding stage. Do not ping a second time for a query.
            var console = target.Families.Contains("Console"); var inventory = target.Families.Contains("Inventory");
            var details = target.Families.Contains("Detail") && plan.Detail is { } detail ? ImmutableArray.Create(detail) : [];
            if (!console && !inventory && target.MissingProbes.IsEmpty && details.IsEmpty) { continue; }
            requests.Add(new([id], false, console, inventory, target.MissingProbes, details)
            { ExpectedIdentities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(id, identities[id]) });
        }
        return requests.ToImmutable();
    }

    private static DomeniaOperationException Invalid(string detail) => new(AccueilService.RefreshQueryMissing,
        detail + " Relisez ou retirez l’élément concerné avant de préparer un autre plan.");
}
