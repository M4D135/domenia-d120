using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class StorageAtomicIndexTests
{
    [Test]
    public static async Task Atomic_replace_keeps_every_requested_previous_version_and_refuses_new_file_collisions()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("settings.json");
        AtomicLocalFile.Write(path, Encoding.UTF8.GetBytes("initial – 東京"), false, default);
        var first = AtomicLocalFile.Write(path, Encoding.UTF8.GetBytes("second"), true, default, keepPrevious: true);
        var second = AtomicLocalFile.Write(path, Encoding.UTF8.GetBytes("third"), true, default, keepPrevious: true);
        Check.Equal("initial – 東京", File.ReadAllText(first!), "première version préservée exactement");
        Check.Equal("second", File.ReadAllText(second!), "deuxième version conservée séparément");
        Check.Equal("third", File.ReadAllText(path), "version complète publiée");
        await Check.ThrowsAsync<IOException>(() => Task.Run(() => AtomicLocalFile.Write(path, [1, 2, 3], false, default)), "export nouveau jamais écrasant");
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => Task.Run(() => AtomicLocalFile.Write(path, [1], true, cancel.Token)), "annulation conserve cible");
        Check.Equal("third", File.ReadAllText(path), "aucun contenu partiel après refus");
        Check.Equal(0, Directory.GetFiles(folder.Path, ".domenia-*.tmp").Length, "provisoires possédés nettoyés");
    }

    [Test]
    public static async Task Relation_indexes_follow_insert_update_delete_and_search_never_joins_a_foreign_GUID_by_name()
    {
        using var folder = new TemporaryFolder(); var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var computer = Fixtures.Computer("PC1");
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer]), new(Fixtures.Postes, "Postes", true), "DC1", default);
        var user = Fixtures.IdOf("alice").ToString("D"); var guid = computer.ObjectGuid.ToString("D");
        var query = new IndexQuery("", new(Fixtures.Root, "Domaine", "Domaine", true, true, "test"), IndexSort.Name, false, 0, 200);
        using (var writer = new SqliteDatabase(database.Path, false))
        {
            writer.Execute("INSERT INTO user_machine_links(computer_key,computer,user_login,user_guid,computer_guid) VALUES('foreign','PC1','wrong',?1,?2);", user, Guid.NewGuid().ToString("D"));
            foreach (var (column, index) in new[] { ("computer_guid", "ix_links_computer_guid"), ("user_guid", "ix_links_user_guid"), ("computer", "ix_links_computer_name") })
            {
                var explanation = writer.Query("EXPLAIN QUERY PLAN SELECT user_login FROM user_machine_links WHERE " + column + "=?1 COLLATE NOCASE;", guid);
                Check.True(explanation.Any(r => (r["detail"] as string)?.Contains(index, StringComparison.Ordinal) == true), "index natif utilisé : " + column);
            }
        }
        Check.Null((await database.SearchIndexAsync(query, default)).Rows.Single().Association, "homonyme d’un autre GUID ignoré");
        using (var writer = new SqliteDatabase(database.Path, false))
            writer.Execute("INSERT INTO user_machine_links(computer_key,computer,user_login,user_guid,computer_guid) VALUES('exact','Renommé','alice',?1,?2);", user, guid);
        Check.Equal("alice", (await database.SearchIndexAsync(query, default)).Rows.Single().Association, "GUID retrouve le lien même après renommage");
        using (var writer = new SqliteDatabase(database.Path, false)) writer.Execute("UPDATE user_machine_links SET user_login='bob' WHERE computer_guid=?1 COLLATE NOCASE;", guid);
        Check.Equal("bob", (await database.SearchIndexAsync(query, default)).Rows.Single().Association, "mise à jour indexée immédiatement visible");
        using (var writer = new SqliteDatabase(database.Path, false)) writer.Execute("DELETE FROM user_machine_links WHERE user_guid=?1 COLLATE NOCASE;", user);
        Check.Null((await database.SearchIndexAsync(query, default)).Rows.Single().Association, "suppression indexée sans reconstruction");
        var other = Fixtures.Computer("PC1", "OU=Autre," + Fixtures.Root) with { ObjectGuid = Fixtures.IdOf("other-PC1") };
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer, other]), new(Fixtures.Root, "Domaine", true), "DC1", default);
        using (var writer = new SqliteDatabase(database.Path, false))
            writer.Execute("INSERT INTO user_machine_links(computer_key,computer,user_login) VALUES('legacy','PC1','ancien');");
        var selected = query with { Scope = new(Fixtures.Postes, "Postes", "Postes", true, false, "test") };
        Check.Equal(1, (await database.SearchIndexAsync(selected, default)).Total, "un seul homonyme visible dans cette OU");
        Check.Null((await database.SearchIndexAsync(selected, default)).Rows.Single().Association, "homonyme hors OU empêche le rapprochement par nom");
        using (var writer = new SqliteDatabase(database.Path, false))
            writer.Execute("INSERT INTO user_machine_links(computer_key,computer,user_login,computer_guid) VALUES('exact-again','PC1','prouvé',?1);", guid);
        Check.Equal("prouvé", (await database.SearchIndexAsync(selected, default)).Rows.Single().Association, "le GUID exact reste utilisable malgré homonymes");
    }
}
