using System.Security.Cryptography;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteDatabaseTests
{
    [Test]
    public static async Task Sqlite_parameters_preserve_unicode_quotes_and_binary_without_SQL_execution()
    {
        using var folder = new TemporaryFolder();
        using var db = new SqliteDatabase(folder.File("bindings.db"), false);
        db.Script("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT, data BLOB);");
        const string input = "Éléonore'); DROP TABLE sample;-- 東京";
        db.Execute("INSERT INTO sample(id,value,data) VALUES(?1,?2,?3);", 1, input, new byte[] { 0, 255, 1 });
        var row = db.Query("SELECT value,data FROM sample WHERE id=?1;", 1).Single();
        Check.Equal(input, (string?)row["value"], "texte exact lié");
        Check.True(((byte[])row["data"]!).SequenceEqual(new byte[] { 0, 255, 1 }), "octets exacts");
        await Check.ThrowsAsync<ArgumentException>(() => Task.Run(() => db.Execute("DELETE FROM sample; DROP TABLE sample;")), "plusieurs instructions refusées");
        Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM sample;")!, "instruction refusée non exécutée");
    }

    [Test]
    public static void Sqlite_disposal_rolls_back_an_uncommitted_transaction()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("rollback.db");
        using (var db = new SqliteDatabase(path, false))
        {
            db.Script("CREATE TABLE sample(value TEXT);");
            db.Begin();
            db.Execute("INSERT INTO sample(value) VALUES(?1);", "uncommitted");
        }
        using var reopened = new SqliteDatabase(path, true);
        Check.Equal(0L, (long)reopened.Scalar("SELECT count(*) FROM sample;")!, "transaction annulée");
    }

    [Test]
    public static async Task Sqlite_busy_is_reported_and_never_looks_like_an_empty_success()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("busy.db");
        using var first = new SqliteDatabase(path, false);
        first.Script("CREATE TABLE sample(value TEXT);");
        first.Begin();
        using var other = new SqliteDatabase(path, false, 50);
        var error = await Check.ThrowsAsync<SqliteStoreException>(() => Task.Run(() => other.Execute("INSERT INTO sample(value) VALUES(?1);", "blocked")), "verrou visible");
        Check.True(error.Busy, "code occupé");
        first.Rollback();
    }

    [Test]
    public static async Task New_database_has_complete_Domenia_1_schema_and_stable_identity()
    {
        using var folder = new TemporaryFolder();
        var store = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        Check.Null(await store.InspectAsync(CancellationToken.None), "aucune création à la lecture");
        var result = await store.InitializeAsync(CancellationToken.None);
        Check.Equal(11, result.SchemaVersion, "schéma Domenia 1");
        Check.Equal(1, result.SchemaRevision, "révision compatible");
        Check.Equal<long?>(0, result.Objects, "base neuve");
        Check.Equal(store.StoreId, result.StoreId, "identité stable");
        using var db = new SqliteDatabase(store.Path, true);
        Check.Equal("ok", db.Scalar("PRAGMA quick_check;") as string, "intégrité");
        Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE name='domenia_query_recipe_dependencies';")!, "bibliothèque compatible");
        Check.Null((await store.InitializeAsync(CancellationToken.None)).Backup, "pas de migration répétée");
    }

    [Test]
    public static async Task Legacy_schema_upgrade_preserves_records_and_keeps_a_verified_backup()
    {
        using var folder = new TemporaryFolder();
        var store = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await store.InitializeAsync(CancellationToken.None);
        using (var legacy = new SqliteDatabase(store.Path, false))
        {
            legacy.Execute("INSERT INTO ad_objects(object_key,object_guid,object_type,name,distinguished_name) VALUES(?1,?2,?3,?4,?5);", "id", Guid.NewGuid().ToString("D"), "Utilisateur", "Éléonore", "CN=Éléonore," + Fixtures.People);
            legacy.Script("DROP TABLE domenia_v2_objects; DROP TABLE domenia_v2_metadata; DROP TABLE domenia_v2_batches; DELETE FROM schema_info WHERE key='domenia_schema';");
        }
        var migrated = await new DomeniaDatabase(store.Path, Fixtures.Root, TestClock.Fixed()).InitializeAsync(CancellationToken.None);
        Check.Equal<long?>(1, migrated.Objects, "objet historique conservé");
        Check.True(migrated.Backup is not null, "sauvegarde antérieure disponible");
        using var bytes = File.OpenRead(migrated.Backup!.Path);
        Check.Equal(migrated.Backup.Sha256, Convert.ToHexStringLower(SHA256.HashData(bytes)), "empreinte vérifiable");
        using var backup = new SqliteDatabase(migrated.Backup.Path, true);
        Check.Equal("Éléonore", backup.Scalar("SELECT name FROM ad_objects;") as string, "objet dans la sauvegarde");
        Check.Null(backup.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';"), "sauvegarde précédant la migration");
    }

    [Test]
    public static async Task Newer_or_foreign_database_is_refused_without_changes()
    {
        using var folder = new TemporaryFolder();
        var store = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await store.InitializeAsync(CancellationToken.None);
        using (var db = new SqliteDatabase(store.Path, false)) { db.Execute("UPDATE schema_info SET value='12' WHERE key='schema_version';"); }
        var before = SHA256.HashData(File.ReadAllBytes(store.Path));
        await Check.ThrowsAsync<InvalidDataException>(() => store.InitializeAsync(CancellationToken.None), "schéma futur refusé");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(store.Path))), "fichier intact");
        using (var db = new SqliteDatabase(store.Path, false)) { db.Execute("UPDATE schema_info SET value='11' WHERE key='schema_version';"); }
        before = SHA256.HashData(File.ReadAllBytes(store.Path));
        await Check.ThrowsAsync<InvalidDataException>(() => new DomeniaDatabase(store.Path, "DC=other,DC=local", TestClock.Fixed()).InitializeAsync(CancellationToken.None), "domaine étranger refusé");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(store.Path))), "base étrangère intacte");
    }

    [Test]
    public static async Task Backup_includes_committed_WAL_pages_only()
    {
        using var folder = new TemporaryFolder();
        var store = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await store.InitializeAsync(CancellationToken.None);
        using var writer = new SqliteDatabase(store.Path, false);
        writer.Script("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;");
        writer.Execute("INSERT INTO park_state(computer_key,computer) VALUES(?1,?2);", "pc1", "PC1");
        writer.Begin();
        writer.Execute("INSERT INTO park_state(computer_key,computer) VALUES(?1,?2);", "pc2", "PC2");
        var saved = await store.BackupAsync(CancellationToken.None);
        using var backup = new SqliteDatabase(saved.Path, true);
        Check.Equal(1L, (long)backup.Scalar("SELECT count(*) FROM park_state;")!, "une seule ligne validée");
        Check.Equal("PC1", backup.Scalar("SELECT computer FROM park_state;") as string, "page WAL incluse");
        writer.Rollback();
    }

    [Test]
    public static async Task Directory_commit_is_idempotent_and_partial_reads_never_delete_unseen_objects()
    {
        using var folder = new TemporaryFolder();
        var store = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await store.InitializeAsync(CancellationToken.None);
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1"), Fixtures.Computer("PC2")]);
        var batch = Guid.NewGuid().ToString("D");
        var first = await store.SaveDirectoryAsync(batch, snapshot, scope, "DC1.test.local", CancellationToken.None);
        Check.False(first.AlreadyCommitted, "premier commit");
        var repeat = await store.SaveDirectoryAsync(batch, snapshot, scope, "DC1.test.local", CancellationToken.None);
        Check.True(repeat.AlreadyCommitted, "reçu relu sans second commit");
        Check.Equal(first.Revision, repeat.Revision, "révision stable");
        var partial = snapshot with { ReadAt = snapshot.ReadAt.AddMinutes(1), Complete = false, Computers = [snapshot.Computers[0]] };
        await Check.ThrowsAsync<InvalidDataException>(() => store.SaveDirectoryAsync(batch, partial, scope, "DC1.test.local", CancellationToken.None), "même ID autres octets refusés");
        await store.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), partial, scope, "DC1.test.local", CancellationToken.None);
        var restored = await store.ReadDirectoryAsync(CancellationToken.None);
        Check.Equal(2, restored!.Computers.Length, "poste absent d’un résultat partiel conservé");
        Check.False(restored.Complete, "union locale jamais présentée comme un recensement frais complet");
        using var db = new SqliteDatabase(store.Path, true);
        Check.Equal(2L, (long)db.Scalar("SELECT count(*) FROM ad_objects;")!, "index historique compatible");
        Check.Equal(2L, (long)db.Scalar("SELECT item_count FROM sync_state WHERE scope=?1;", "ou:" + Fixtures.Postes.ToLowerInvariant())!, "repère complet non abaissé");
        Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM sync_state WHERE scope LIKE 'attempt:%';")!, "tentative partielle séparée");
    }

    [Test]
    public static async Task Directory_storage_rejects_scope_escape_and_does_not_replace_a_newer_legacy_row()
    {
        using var folder = new TemporaryFolder();
        var store = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await store.InitializeAsync(CancellationToken.None);
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        await Check.ThrowsAsync<InvalidDataException>(() => store.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(users: [Fixtures.User("Outside")]), scope, "DC1", CancellationToken.None), "objet hors branche");
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]);
        using (var db = new SqliteDatabase(store.Path, false))
        {
            var id = snapshot.Computers[0].ObjectGuid.ToString("D");
            db.Execute("INSERT INTO ad_objects(object_key,object_guid,object_type,name,distinguished_name,synced_at) VALUES(?1,?1,'Machine',?2,?3,?4);", id, "Nouveau", snapshot.Computers[0].DistinguishedName, Fixtures.Now.ToString("O"));
        }
        await store.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), snapshot, scope, "DC1", CancellationToken.None);
        using var after = new SqliteDatabase(store.Path, true);
        Check.Equal("Nouveau", after.Scalar("SELECT name FROM ad_objects;") as string, "relevé plus récent conservé");
    }

    [Test]
    public static async Task Stored_scope_keeps_its_base_OU_and_index_search_respects_one_level()
    {
        using var folder = new TemporaryFolder();
        var store = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        await store.InitializeAsync(CancellationToken.None);
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC-Étage"), Fixtures.Computer("PC-Nested", "OU=Enfant," + Fixtures.Postes)]) with
        {
            OrganizationalUnits = [new DirectoryOu(Fixtures.IdOf("ou"), Fixtures.Postes, "Postes", null, null, Fixtures.Now, Fixtures.Now, 1)],
        };
        await store.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), snapshot, new ScopeSelection(Fixtures.Postes, "Postes", true), "DC1", CancellationToken.None);
        Check.Equal(1, (await store.ReadDirectoryAsync(CancellationToken.None))!.OrganizationalUnits.Length, "OU de base d’une lecture subtree conservée");
        var scope = new SyncScope(Fixtures.Postes, "Postes", "Postes", false, false, "test");
        var page = await store.SearchIndexAsync(new IndexQuery("", scope, IndexSort.Name, false, 0, 200), CancellationToken.None);
        Check.Equal(1, page.Total, "profondeur directe respectée");
        Check.Equal("PC-Étage", page.Rows.Single().Name, "poste direct");
        page = await store.SearchIndexAsync(new IndexQuery("etage", scope, IndexSort.Relevance, false, 0, 200), CancellationToken.None);
        Check.Equal(1, page.Total, "recherche insensible aux accents");
        using var db = new SqliteDatabase(store.Path, true);
        var payload = db.Scalar("SELECT payload FROM domenia_directory_data WHERE object_guid=?1;", snapshot.Computers[0].ObjectGuid.ToString("D")) as string;
        using var json = System.Text.Json.JsonDocument.Parse(payload!);
        Check.Equal("Actif", json.RootElement.GetProperty("State").GetString(), "projection historique maintenue");
    }
}
