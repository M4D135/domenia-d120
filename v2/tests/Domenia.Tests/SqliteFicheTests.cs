using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteFicheTests
{
    [Test]
    public static async Task Fiche_cache_reads_do_not_create_a_database_and_keep_case_insensitive_attributes_after_restart()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("fiches.db");
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(path, Fixtures.Root, TestClock.Fixed()));
        var item = Fiche();
        Check.Null(await cache.ReadFicheAsync(item.Entry.Dn, CancellationToken.None), "pas de fiche avant relevé");
        Check.Equal(0, (await cache.ReadFicheIndexAsync(CancellationToken.None)).Length, "index vide");
        Check.False(File.Exists(path), "lecture locale sans création");
        await cache.SaveFicheAsync(item, CancellationToken.None);
        var reopened = new SqliteDirectoryCache(new DomeniaDatabase(path, Fixtures.Root, TestClock.Fixed()));
        var read = (await reopened.ReadFicheAsync(item.Entry.Dn.ToUpperInvariant(), CancellationToken.None))!;
        Check.Equal("Contact Élodie", read.Entry.First("displayName"), "comparaison des noms d’attribut restaurée");
        Check.Equal(item.ReadAt, read.ReadAt, "date conservée");
        var summary = (await reopened.ReadFicheIndexAsync(CancellationToken.None)).Single();
        Check.Equal("Contact Élodie", summary.Name, "résumé projeté sans relire tout le blob");
        Check.Equal(FicheKind.Contact, summary.Kind, "contact sans SID");
    }

    [Test]
    public static async Task An_older_fiche_does_not_replace_newer_attributes_and_a_move_replaces_only_its_GUID()
    {
        using var folder = new TemporaryFolder();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("fiches.db"), Fixtures.Root, TestClock.Fixed()));
        var first = Fiche();
        var moved = first with { ReadAt = first.ReadAt.AddMinutes(1), Entry = first.Entry with { Dn = "CN=Élodie,OU=Other," + Fixtures.Root } };
        await cache.SaveFicheAsync(moved, CancellationToken.None);
        var retained = await cache.SaveFicheAsync(first, CancellationToken.None);
        Check.Equal(moved.Entry.Dn, retained.Entry.Dn, "ancien DN non rétabli");
        Check.Null(await cache.ReadFicheAsync(first.Entry.Dn, CancellationToken.None), "ancienne place sans doublon");
        Check.Equal(1, (await cache.ReadFicheIndexAsync(CancellationToken.None)).Length, "une identité seulement");
    }

    [Test]
    public static async Task Fiche_cache_rejects_sensitive_attributes_foreign_objects_and_corrupt_payloads()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("fiches.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db);
        var item = Fiche();
        foreach (var bad in new[]
        {
            item with { Entry = item.Entry with { Dn = "CN=A,DC=foreign,DC=local" } },
            item with { Entry = item.Entry with { Attributes = item.Entry.Attributes.Add("unicodePwd", ["forbidden"]) } },
            item with { Entry = item.Entry with { Attributes = item.Entry.Attributes.Add("__untrusted", ["TRUE"]) } },
            item with { Entry = item.Entry with { ObjectGuid = Guid.NewGuid() } },
            item with { ReadAt = item.ReadAt.AddHours(1) },
        })
        { await Check.ThrowsAsync<InvalidDataException>(() => cache.SaveFicheAsync(bad, CancellationToken.None), "fiche invalide"); }
        await cache.SaveFicheAsync(item, CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, readOnly: false)) { sql.Execute("UPDATE domenia_v2_fiches SET payload='{}';"); }
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ReadFicheAsync(item.Entry.Dn, CancellationToken.None), "empreinte du contenu");
        using (var sql = new SqliteDatabase(db.Path, readOnly: false)) { sql.Execute("UPDATE domenia_v2_fiches SET summary='{}';"); }
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ReadFicheIndexAsync(CancellationToken.None), "empreinte du résumé");
    }

    [Test]
    public static async Task Adding_fiche_storage_preserves_the_existing_directory_and_makes_a_backup()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("fiches.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, readOnly: false))
        {
            sql.Script("DROP TABLE domenia_v2_fiches;");
            sql.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('keep','unchanged');");
        }
        var reopened = new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed());
        var result = await reopened.InitializeAsync(CancellationToken.None);
        Check.True(result.Backup is not null, "sauvegarde avant ajout de table");
        using var inspected = new SqliteDatabase(db.Path, readOnly: true);
        Check.Equal("unchanged", inspected.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='keep';"), "anciennes données préservées");
        Check.Equal("11", inspected.Scalar("SELECT value FROM schema_info WHERE key='schema_version';"), "version historique inchangée");
    }

    private static FicheLocalRead Fiche()
    {
        var id = Fixtures.IdOf("raw-fiche");
        var attributes = new Dictionary<string, IEnumerable<string?>>
        {
            ["OBJECTGUID"] = [id.ToString("D")], ["DISPLAYNAME"] = ["Contact Élodie"], ["description"] = ["Contact"],
        };
        return new(FicheEntry.Create(FicheKind.Contact, id, "CN=Élodie," + Fixtures.Postes, "Élodie", attributes), Fixtures.Now);
    }
}
