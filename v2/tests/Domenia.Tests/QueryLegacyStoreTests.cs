using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class QueryLegacyStoreTests
{
    private const string Id = "personal.legacy";
    private static async Task<DomeniaDatabase> Legacy(TemporaryFolder folder)
    {
        var database = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(CancellationToken.None);
        using var db = new SqliteDatabase(database.Path, false);
        for (var revision = 1; revision <= 7; revision++)
        {
            var recipe = QueryRecipe.Empty(QueryTarget.Computer) with { Format = QueryRecipe.FormatV1, Id = Id, Name = "Définition " + revision };
            var definition = QueryRecipeJson.Write(recipe); var sha = QueryRecipeJson.Sha256(definition);
            var at = Fixtures.Now.AddDays(revision - 8).ToString("O");
            var provenance = new QueryProvenance(null, null, 0, "Source déclarée " + revision, Id, sha, false);
            db.Execute("INSERT INTO domenia_query_recipe_revisions(id,revision,definition_version,definition_json,definition_sha256,at_utc) VALUES(?1,?2,?3,?4,?5,?6);", Id, revision, 1, definition, sha, at);
            db.Execute("INSERT INTO domenia_query_recipe_provenance(recipe_id,revision,provenance_json) VALUES(?1,?2,?3);", Id, revision, JsonSerializer.Serialize(provenance));
            if (revision == 7)
            {
                db.Execute("INSERT INTO domenia_query_recipes(id,domain_dn,name,name_fold,category,revision,definition_version,definition_json,definition_sha256,created_utc,updated_utc,archived) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,0);",
                    Id, Fixtures.Root, recipe.Name, FrenchText.Fold(recipe.Name), "Mes requêtes", revision, 1, definition, sha, Fixtures.Now.AddDays(-7).ToString("O"), at);
            }
        }
        db.Execute("INSERT INTO domenia_query_recipe_dependencies(recipe_id,consumer_kind,consumer_id,bound_revision) VALUES(?1,'Fleet',?2,7);", Id, new string('w', 128));
        return database;
    }

    private static QueryLibrary Library(DomeniaDatabase database) => new(new SqliteDirectoryCache(database), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());

    [Test]
    public static async Task Legacy_query_migration_preserves_all_revisions_provenance_and_inherited_dependencies()
    {
        using var folder = new TemporaryFolder(); var database = await Legacy(folder);
        var before = SHA256.HashData(File.ReadAllBytes(database.Path));
        using var library = Library(database);
        var content = await library.ReadAsync(Fixtures.Root, CancellationToken.None);
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(database.Path))), "reprise en lecture seule sans créer de table");
        var record = content.Records.Single();
        Check.Equal(7L, record.Revision, "révision courante originale"); Check.Equal(6, record.History.Length, "toutes les révisions héritées accessibles, au-delà de cinq");
        Check.Equal("Source déclarée 7", record.Provenance!.Origin, "provenance courante");
        Check.Equal("Source déclarée 1", record.History.Single(h => h.Revision == 1).Provenance!.Origin, "provenance de la révision historique");
        Check.Equal("legacyFleet", content.Consumers.Single().Kind, "liaison historique explicite");
        Check.Equal(128, content.Consumers.Single().Id.Length, "identifiant hérité intégral");
        Check.Equal(0, content.Widgets.Count, "aucune disposition de widget inventée");
        var impact = await library.ImpactAsync(Fixtures.Root, Id, record.Recipe with { Name = "Révisée" }, null, CancellationToken.None);
        Check.Equal(1, impact.Orphans, "dépendance héritée visible dans la revue d’impact");
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.SaveAsync(Fixtures.Root, record.Recipe with { Name = "Révisée" }, null, null, 7, "update", null, CancellationToken.None), "aucune modification silencieuse d’une requête liée");
        var restored = await library.RevertAsync(Fixtures.Root, Id, 1, 7, "migrate", CancellationToken.None);
        Check.Equal(8L, restored.Record.Revision, "restauration atomique comme nouvelle révision");
        Check.Equal("Définition 1", restored.Record.Name, "définition ancienne restaurée");
        Check.Equal("Source déclarée 1", restored.Record.Provenance!.Origin, "provenance de la définition restaurée");
        Check.Equal(7, restored.Record.History.Length, "aucune ancienne révision perdue pendant la restauration");
        using var reopened = Library(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()));
        var reread = await reopened.ReadAsync(Fixtures.Root, CancellationToken.None);
        Check.Equal(7L, reread.Consumers.Single().BoundRevision, "liaison Domenia 1 conservée à sa révision réelle");
        Check.Equal(7, reread.Records.Single().History.Length, "historique conservé après réouverture");
        using var raw = new SqliteDatabase(database.Path, true);
        Check.Equal(7L, (long)raw.Scalar("SELECT count(*) FROM domenia_query_recipe_revisions;")!, "originaux Domenia 1 intacts");
        Check.Equal(7L, (long)raw.Scalar("SELECT revision FROM domenia_query_recipes;")!, "révision Domenia 1 intacte");
    }

    [Test]
    public static async Task Legacy_query_provenance_changes_after_migration_require_reconciliation()
    {
        using var folder = new TemporaryFolder(); var database = await Legacy(folder);
        using var library = Library(database);
        var record = (await library.ReadAsync(Fixtures.Root, CancellationToken.None)).Records.Single();
        await library.SaveAsync(Fixtures.Root, record.Recipe with { Name = "Révision v2" }, null, null, 7, "migrate", null, CancellationToken.None);
        using (var raw = new SqliteDatabase(database.Path, false)) { raw.Execute("UPDATE domenia_query_recipe_provenance SET provenance_json=?1 WHERE revision=1;", "{}"); }
        var before = SHA256.HashData(File.ReadAllBytes(database.Path));
        await Check.ThrowsAsync<InvalidDataException>(() => ((IQueryLibraryStore)new SqliteDirectoryCache(database)).ReadAsync(QueryLibrary.RootKey(Fixtures.Root), CancellationToken.None), "mutation historique détectée même quand la définition courante n’a pas changé");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(database.Path))), "refus sans écriture de réconciliation implicite");
    }

    [Test]
    public static async Task Legacy_query_orphan_history_is_refused_without_partial_migration()
    {
        using var folder = new TemporaryFolder(); var database = await Legacy(folder);
        using (var raw = new SqliteDatabase(database.Path, false)) { raw.Execute("UPDATE domenia_query_recipe_dependencies SET bound_revision=8;"); }
        var before = SHA256.HashData(File.ReadAllBytes(database.Path));
        await Check.ThrowsAsync<InvalidDataException>(() => ((IQueryLibraryStore)new SqliteDirectoryCache(database)).ReadAsync(QueryLibrary.RootKey(Fixtures.Root), CancellationToken.None), "dépendance sans révision refusée");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(database.Path))), "aucun original altéré");
    }

    [Test]
    public static async Task Restoring_a_query_revision_without_migrating_widgets_keeps_their_original_definition_available()
    {
        using var library = new QueryLibrary(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var first = await library.SaveAsync(Fixtures.Root, QueryRecipe.Empty() with { Name = "Première" }, null, null, 0, "update", new("fleet", "kpi", "Mon chiffre"), CancellationToken.None);
        await library.SaveAsync(Fixtures.Root, first.Record.Recipe with { Name = "Deuxième" }, null, null, 1, "migrate", null, CancellationToken.None);
        var restored = await library.RevertAsync(Fixtures.Root, first.Record.Id, 1, 2, "update", CancellationToken.None);
        var content = await library.ReadAsync(Fixtures.Root, CancellationToken.None);
        Check.Equal("Première", restored.Record.Name, "définition choisie restaurée");
        Check.Equal(2L, content.Widgets.Single().BoundRevision, "widget non migré sans demande");
        Check.Equal("Deuxième", QueryLibrary.RevisionRecipe(restored.Record, 2)!.Name, "ancienne définition du widget toujours disponible");
    }
}
