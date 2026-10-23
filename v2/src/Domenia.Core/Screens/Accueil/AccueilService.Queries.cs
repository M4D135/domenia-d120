using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed record FleetQueryCatalogItem(string Id, string Name, string Target, long Revision, string Fingerprint, string Visual, string? WidgetId, long? BoundRevision)
{
    public bool HealthEligible { get; init; }
}
public sealed record FleetQueryBinding(FleetLayoutItem Item, QueryStoreReceipt Receipt);

public sealed partial class AccueilService
{
    private QueryLibrary? queryLibrary;

    /// <summary>The bridge supplies the same library instance as the workshop, backed by the active SQLite store.</summary>
    public void AttachQueryLibrary(QueryLibrary library)
    {
        ArgumentNullException.ThrowIfNull(library);
        var before = Interlocked.CompareExchange(ref queryLibrary, library, null);
        if (before is not null && !ReferenceEquals(before, library)) { throw new InvalidOperationException("Bibliothèque déjà raccordée à cette session."); }
    }

    public async Task<WidgetCatalogView> CatalogAsync(CancellationToken token)
    {
        var result = Catalog();
        if (queryLibrary is null) { return result; }
        var (_, _, domain) = await ScopeAsync(token).ConfigureAwait(false);
        try
        {
            var content = await queryLibrary.ReadAsync(domain, token).ConfigureAwait(false);
            var entries = content.Records.Where(r => !r.Archived).OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase).Select(r =>
            {
                var link = content.Widgets.FirstOrDefault(w => w.RecipeId == r.Id && w.Board == "fleet");
                return new FleetQueryCatalogItem(r.Id, r.Name, QueryTexts.TargetLabel(r.Recipe.Target), r.Revision, r.Fingerprint,
                    r.Recipe.GroupBy is null ? "Kpi" : "Pie", link?.Id, link?.BoundRevision) { HealthEligible = r.Recipe.Target == QueryTarget.Computer };
            }).ToImmutableArray();
            return result with { QueriesAvailable = true, Queries = entries,
                QueriesText = "Requêtes locales du domaine. Ajouter lie la révision affichée ; aucune collecte réseau ne démarre."
                    + (content.Unreadable > 0 ? " Certaines définitions sont illisibles et restent conservées dans la bibliothèque." : "") };
        }
        catch (Exception ex) when (ex is QueryDefinitionException or IOException or UnauthorizedAccessException or DomeniaOperationException)
        {
            context.Log.Warning("Catalogue des requêtes non lu : " + ex.GetType().Name + ".");
            return result with { QueriesText = "Bibliothèque non lue pour l’instant ; aucun lien n’est modifié. Réessayez depuis l’atelier de requêtes." };
        }
    }

    /// <summary>Explicit local gesture: pin the displayed revision and retain the library's verified write receipt.</summary>
    public async Task<FleetQueryBinding> BindQueryAsync(string recipeId, long revision, CancellationToken token)
    {
        var library = queryLibrary ?? throw new DomeniaOperationException(QueryErrors.NotFound, "Bibliothèque non raccordée à cette session.");
        var (_, _, domain) = await ScopeAsync(token).ConfigureAwait(false);
        var record = await library.FindAsync(domain, recipeId, token).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(QueryErrors.NotFound, "Requête absente de la bibliothèque.");
        if (record.Archived || record.Revision != revision) { throw new DomeniaOperationException(QueryErrors.RevisionChanged, "Requête archivée ou révision modifiée : relisez le catalogue avant de confirmer."); }
        var visual = record.Recipe.GroupBy is null ? "kpi" : "pie";
        var saved = await library.SaveAsync(domain, record.Recipe, null, null, revision, "update", new QueryWidgetRequest("fleet", visual, record.Name[..Math.Min(80, record.Name.Length)]), token).ConfigureAwait(false);
        var widget = saved.Widget ?? throw new DomeniaOperationException(QueryErrors.NotFound, "Lien du widget non confirmé par la bibliothèque.");
        return new FleetQueryBinding(new FleetLayoutItem("q-" + widget.Id, FleetWidgetSource.Query, widget.Id, visual == "pie" ? "Pie" : "Kpi", "M", widget.Title, false, "Requêtes"), saved.Receipt);
    }

    private async Task<FleetQuerySnapshot> ReadQueriesAsync(CancellationToken token)
    {
        if (queryLibrary is null || context.Readers.Find<IQueryWorkshopReader>() is not { } reader)
        { return new(null, null, "Bibliothèque non raccordée à cette session."); }
        try
        {
            var (_, _, domain) = await ScopeAsync(token).ConfigureAwait(false);
            var content = await queryLibrary.ReadAsync(domain, token).ConfigureAwait(false);
            var dataset = await reader.DatasetAsync(token).ConfigureAwait(false);
            if (!DistinguishedName.AreEqual(dataset.Directory.Domain.RootDn, domain))
            { return new(null, null, "La base locale appartient à un autre domaine ; aucun chiffre calculé."); }
            return new(content, dataset, null);
        }
        catch (Exception ex) when (ex is QueryDefinitionException or IOException or UnauthorizedAccessException or DomeniaOperationException)
        {
            context.Log.Warning("Widgets de requêtes non calculés : " + ex.GetType().Name + ".");
            return new(null, null, "Bibliothèque ou données locales non lues ; aucun ancien résultat présenté comme actuel.");
        }
    }
}
