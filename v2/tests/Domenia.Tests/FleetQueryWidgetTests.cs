using System.Collections.Immutable;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class FleetQueryWidgetTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static async Task<(SimulatedBridge Bridge, AccueilService Service, QueryLibrary Library, string Root)> Setup()
    {
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(None);
        await WorkingScope.From(bridge.Context).SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, None);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine de simulation absent.");
        return (bridge, AccueilService.From(bridge.Context), RequetesServices.Library(bridge.Context), root);
    }

    [Test]
    public static async Task Home_catalog_reads_the_workshop_library_and_pins_the_displayed_revision()
    {
        var setup = await Setup();
        var recipe = QueryRecipe.Empty() with { Name = "Postes activés", Clauses = [new("active", QueryOperator.Equal, QueryValue.FromBoolean(true))] };
        var saved = await setup.Library.SaveAsync(setup.Root, recipe, null, null, 0, "update", null, None);
        var catalog = await setup.Service.CatalogAsync(None);
        Check.True(catalog.QueriesAvailable, "bibliothèque réellement lue");
        Check.Equal(saved.Record.Id, catalog.Queries.Single().Id, "même document que l’atelier");
        var linked = await setup.Service.BindQueryAsync(saved.Record.Id, saved.Record.Revision, None);
        Check.True(linked.Receipt.ReadBack, "lien relu");
        await setup.Service.SaveLayoutAsync([linked.Item], None);
        var board = await setup.Service.BoardAsync(None);
        var entry = board.Entries["query:" + linked.Item.Key];
        Check.True(entry.Measured && entry.Number > 0, "calcul réel sur le périmètre");
        var exact = setup.Service.Targets(board.Revision, entry.TargetsKey!);
        Check.Equal(entry.Number, (double?)exact.Total, "le détail ouvre exactement le chiffre");
        Check.Contains("Révision 1", entry.Subtitle, "révision évaluée visible");
        var revised = await setup.Library.SaveAsync(setup.Root, saved.Record.Recipe, "Catégorie revue", null, saved.Record.Revision, "update", null, None);
        var nextBoard = await setup.Service.BoardAsync(None);
        var oldRevision = nextBoard.Entries["query:" + linked.Item.Key];
        Check.Contains("Révision 1", oldRevision.Subtitle, "une modification de bibliothèque n’avance pas le lien silencieusement");
        Check.NotNull(oldRevision.Action, "nouvelle révision à confirmer sur le widget");
        await setup.Service.BindQueryAsync(revised.Record.Id, revised.Record.Revision, None);
        var confirmed = await setup.Service.BoardAsync(None);
        Check.Contains("Révision 2", confirmed.Entries["query:" + linked.Item.Key].Subtitle, "révision liée seulement après le geste explicite");
        Check.Throws<DomeniaOperationException>(() => setup.Service.Targets(board.Revision, entry.TargetsKey!), "ancien clic refusé après remplacement du calcul");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Service.BindQueryAsync(saved.Record.Id, 99, None), "révision non relue refusée sans nouvelle liaison");
    }

    [Test]
    public static async Task Grouping_keeps_exact_top_ten_and_other_targets_without_contacting_a_workstation()
    {
        var setup = await Setup();
        var saved = await setup.Library.SaveAsync(setup.Root, QueryRecipe.Empty() with { Name = "Répartition des affectations", GroupBy = "description" }, null, null, 0, "update", null, None);
        var linked = await setup.Service.BindQueryAsync(saved.Record.Id, saved.Record.Revision, None);
        await setup.Service.SaveLayoutAsync([linked.Item], None);
        var before = await setup.Bridge.Context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(None);
        var board = await setup.Service.BoardAsync(None);
        var after = await setup.Bridge.Context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(None);
        Check.Equal(before.Version, after.Version, "aucune collecte ne modifie les observations au montage");
        var entry = board.Entries["query:" + linked.Item.Key];
        Check.True(entry.Measured, "répartition calculée");
        Check.True(entry.Items.Any(p => p.Label == "Autres valeurs"), "reste au-delà des dix premières valeurs");
        var all = new HashSet<Guid>();
        foreach (var part in entry.Items)
        {
            var exact = setup.Service.Targets(board.Revision, part.TargetsKey);
            Check.Equal(part.Value, (double)exact.Total, "chaque part conserve son ensemble exact");
            foreach (var row in exact.Rows) { Check.True(all.Add(row.Guid), "aucun recouvrement entre parts"); }
        }
        Check.Equal(entry.Number, entry.Items.Sum(p => p.Value), "total conservé par la répartition");
    }

    [Test]
    public static async Task Archived_or_missing_recipes_keep_the_layout_without_a_false_zero()
    {
        var setup = await Setup();
        var saved = await setup.Library.SaveAsync(setup.Root, QueryRecipe.Empty() with { Name = "À archiver" }, null, null, 0, "update", null, None);
        var linked = await setup.Service.BindQueryAsync(saved.Record.Id, saved.Record.Revision, None);
        await setup.Service.SaveLayoutAsync([linked.Item, linked.Item with { Id = "q-absent", Key = "absent" }], None);
        await setup.Library.ArchiveAsync(setup.Root, saved.Record.Id, saved.Record.Revision, None);
        var board = await setup.Service.BoardAsync(None);
        Check.Equal(2, setup.Service.Layout().Items.Length, "aucune suppression silencieuse des widgets");
        var archived = board.Entries["query:" + linked.Item.Key];
        Check.False(archived.Measured, "archive non présentée comme calcul courant");
        Check.Null(archived.Number, "archive n’est pas zéro");
        Check.Contains("archivée", archived.Value, "motif exact visible");
        Check.Null(board.Entries["query:absent"].Number, "absence de définition n’est pas zéro");
    }
}
