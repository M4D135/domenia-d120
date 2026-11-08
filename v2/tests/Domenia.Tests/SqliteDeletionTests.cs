using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteDeletionTests
{
    [Test]
    public static async Task Confirmed_deletion_cleans_only_known_current_links_and_keeps_history_and_other_GUIDs()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("deletions.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db);
        var (target, fiche, snapshot) = Data();
        await cache.SaveObjectsAsync(snapshot, "DC1", CancellationToken.None);
        await cache.SaveFicheAsync(fiche, CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,user_guid) VALUES('bound','compte',?1);", target.ObjectGuid);
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,user_dn) VALUES('dn','compte',?1);", target.Dn);
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,user_guid) VALUES('replacement','compte',?1);", Guid.NewGuid().ToString("D"));
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login) VALUES('legacy','TEST\\compte');");
            sql.Execute("INSERT INTO user_machine_history(user_login,computer_key,user_guid) VALUES('compte','bound',?1);", target.ObjectGuid);
        }
        var count = await cache.CountDeletionLinksAsync(target, CancellationToken.None);
        Check.Equal(2, count.Identified, "GUID et DN connus"); Check.Equal(1, count.Unresolved, "ancien lien au seul nom");
        var removed = await cache.ApplyDeletionAsync(target, Fixtures.Now, CancellationToken.None);
        Check.Equal(count, removed, "nettoyage exact");
        Check.Null(await cache.ReadFicheAsync(target.Dn, CancellationToken.None), "fiche brute retirée");
        Check.Equal(0, (await cache.ReadKnownAsync(CancellationToken.None))!.Users.Length, "projection typée retirée");
        using var check = new SqliteDatabase(db.Path, true);
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM ad_objects;")!, "index D1 nettoyé");
        Check.Equal(2L, (long)check.Scalar("SELECT count(*) FROM user_machine_links;")!, "homonyme d’autre GUID et lien incertain conservés");
        Check.Equal(1L, (long)check.Scalar("SELECT count(*) FROM user_machine_history;")!, "historique conservé");
        var backup = (await db.InspectAsync(CancellationToken.None))!.Backup!;
        using var saved = new SqliteDatabase(backup.Path, true);
        Check.Equal(4L, (long)saved.Scalar("SELECT count(*) FROM user_machine_links;")!, "sauvegarde fraîche avant retrait");
    }

    [Test]
    public static async Task A_late_read_cannot_resurrect_a_deleted_GUID_but_a_newer_positive_read_can_restore_it()
    {
        using var folder = new TemporaryFolder();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("deletions.db"), Fixtures.Root, TestClock.Fixed()));
        var (target, fiche, snapshot) = Data();
        await cache.SaveObjectsAsync(snapshot, "DC1", CancellationToken.None);
        await cache.SaveFicheAsync(fiche, CancellationToken.None);
        await cache.ApplyDeletionAsync(target, Fixtures.Now, CancellationToken.None);
        var late = await cache.SaveObjectsAsync(snapshot, "DC1", CancellationToken.None);
        Check.Equal(0, late.Users.Length, "ancienne lecture non rétablie");
        await Check.ThrowsAsync<InvalidDataException>(() => cache.SaveFicheAsync(fiche, CancellationToken.None), "ancienne fiche refusée");
        var newer = Fixtures.Now.AddSeconds(1);
        await cache.SaveObjectsAsync(snapshot with { ReadAt = newer }, "DC1", CancellationToken.None);
        await cache.SaveFicheAsync(fiche with { ReadAt = newer }, CancellationToken.None);
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ApplyDeletionAsync(target, Fixtures.Now, CancellationToken.None), "ancien nettoyage ne peut pas effacer une restauration plus récente");
        Check.Equal(1, (await cache.ReadKnownAsync(CancellationToken.None))!.Users.Length, "restauration conservée");
    }

    [Test]
    public static async Task Deletion_cleanup_rolls_back_links_and_projections_together_on_a_store_failure()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("deletions.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db);
        var (target, fiche, snapshot) = Data();
        await cache.SaveObjectsAsync(snapshot, "DC1", CancellationToken.None);
        await cache.SaveFicheAsync(fiche, CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,user_guid) VALUES('bound','compte',?1);", target.ObjectGuid);
            sql.Script("CREATE TRIGGER fail_delete BEFORE DELETE ON domenia_v2_fiches BEGIN SELECT RAISE(ABORT,'test'); END;");
        }
        await Check.ThrowsAsync<SqliteStoreException>(() => cache.ApplyDeletionAsync(target, Fixtures.Now, CancellationToken.None), "échec injecté après retrait des liens");
        Check.Equal(1, (await cache.CountDeletionLinksAsync(target, CancellationToken.None)).Identified, "lien rétabli par rollback");
        Check.Equal(1, (await cache.ReadKnownAsync(CancellationToken.None))!.Users.Length, "projection rétablie");
        Check.True(await cache.ReadFicheAsync(target.Dn, CancellationToken.None) is not null, "fiche conservée");
        using var check = new SqliteDatabase(db.Path, true);
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM domenia_v2_deletions;")!, "aucune disparition locale enregistrée à moitié");
    }

    private static (WriteTarget, FicheLocalRead, DirectorySnapshot) Data()
    {
        var user = Fixtures.User("Compte");
        var entry = FicheEntry.Create(FicheKind.User, user.ObjectGuid, user.DistinguishedName, "Compte", new Dictionary<string, IEnumerable<string?>>
        { ["objectGUID"] = [user.ObjectGuid.ToString("D")], ["sAMAccountName"] = ["compte"] });
        return (ObjectWrites.Target(entry), new(entry, Fixtures.Now.AddMinutes(-1)), Fixtures.Snapshot(users: [user]));
    }
}
