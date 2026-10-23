using System.Security.Cryptography;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteRelationReadTests
{
    private static Task SaveDirectory(DomeniaDatabase db, DirectoryComputer pc, params DirectoryUser[] users) => db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"),
        Fixtures.Snapshot(computers: [pc], users: users), new(Fixtures.Postes, "Postes", true), null, CancellationToken.None);
    private static void Insert(DomeniaDatabase db, string key, string login, string computer, string source, string? at = null, string? userId = null, string? computerId = null, string? userDn = null, string? details = null)
    {
        using var sql = new SqliteDatabase(db.Path, false);
        sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,observed_at,user_guid,computer_guid,user_dn,details,verified_in_ad) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,1);",
            key, login, computer, source, at, userId, computerId, userDn, details);
    }

    [Test]
    public static async Task Relation_read_never_creates_a_missing_database_or_changes_existing_rows()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed());
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "base absente vide"); Check.False(File.Exists(db.Path), "lecture sans création implicite");
        await db.InitializeAsync(CancellationToken.None);
        Insert(db, "PC1", "alice", "PC1", "Saisie manuelle", "2026-10-20T12:00:00Z");
        var before = SHA256.HashData(File.ReadAllBytes(db.Path));
        var read = await db.ReadRelationsAsync(CancellationToken.None);
        Check.Equal("PC1", read.Rows.Single().StorageKey, "clé primaire D1 inchangée"); Check.Equal(RelationKind.Assignment, read.Rows[0].Relation.Kind, "nature reconnue");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "octets de la base inchangés par la lecture");
        Check.Null(read.Rows[0].Relation.UserGuid, "GUID manquant non inventé");
    }

    [Test]
    public static async Task Legacy_relation_dates_use_local_timezone_and_import_batches_are_read_without_schema_migration()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        Insert(db, "PC1", "alice", "PC1", "Console CIM/DCOM", "2026-10-20T12:00:00");
        Insert(db, "PC1|batch", "bob", "PC1", "Import GLPI", "2026-10-20T12:00:00+02:00", details: "Lot dʼimport 20261020T120000-abc. Export GLPI.");
        var read = await db.ReadRelationsAsync(CancellationToken.None);
        Check.Equal(2, read.Rows.Length, "plusieurs relations du même poste conservées");
        Check.Equal(new DateTimeOffset(2026, 10, 20, 10, 0, 0, TimeSpan.Zero), read.Rows[0].Relation.When!.Value, "heure locale Paris convertie en UTC");
        Check.Equal(read.Rows[0].Relation.When, read.Rows[1].Relation.When, "date avec décalage identique");
        Check.Equal("20261020T120000-abc", read.Rows[1].Relation.BatchId, "ancien jeton d’import reconnu");
        using var sql = new SqliteDatabase(db.Path, true);
        Check.False(sql.Query("PRAGMA table_info(user_machine_links);").Any(c => (string?)c["name"] == "batch_id"), "lecture sans ajout de colonne");
    }

    [Test]
    public static async Task Ambiguous_missing_or_future_relation_dates_do_not_acquire_a_fabricated_instant()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        var dates = new[] { "2025-10-26T02:30:00", "2026-03-29T02:30:00", "2028-01-01T00:00:00Z", "illisible", "" };
        for (var i = 0; i < dates.Length; i++) { Insert(db, "PC" + i, "alice", "PC" + i, "Profil", dates[i]); }
        var read = await db.ReadRelationsAsync(CancellationToken.None);
        Check.Equal(5, read.Rows.Length, "relations conservées avec date inconnue"); Check.Equal(4, read.UncertainDates, "dates invalides distinctes de date absente");
        Check.True(read.Rows.All(r => r.Relation.When is null), "aucun horaire DST ou futur inventé");
    }

    [Test]
    public static async Task Malformed_foreign_or_oversized_relation_rows_are_quarantined_without_deleting_them()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        Insert(db, "one", "alice", "PC1", "Manual", userId: "bad-guid");
        Insert(db, "two", "alice", "PC2", "Manual", userDn: "CN=alice,DC=other,DC=local");
        Insert(db, "three", "alice", "PC3", "Manual", details: new string('x', 16_385));
        Insert(db, "four", "alice", "PC4", "Manual", userDn: "invalid");
        var read = await db.ReadRelationsAsync(CancellationToken.None);
        Check.Equal(4, read.Rejected, "lignes non interprétables écartées"); Check.Equal(0, read.Rows.Length, "aucun lien faussement qualifié");
        using var sql = new SqliteDatabase(db.Path, true);
        Check.Equal(4L, (long)sql.Scalar("SELECT count(*) FROM user_machine_links;")!, "originaux intacts");
    }

    [Test]
    public static async Task Workstation_header_resolves_stored_GUIDs_after_rename_and_does_not_contact_LDAP()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed());
        var pc = Fixtures.Computer("PC1") with { Name = "Bureau renommé" }; var alice = Fixtures.User("alice") with { SamAccountName = "alice.renommee", DisplayName = "Alice actuelle" };
        await db.InitializeAsync(CancellationToken.None); await SaveDirectory(db, pc, alice);
        Insert(db, "PC1", "alice", "Ancien nom", "Saisie manuelle", "2026-10-20T12:00:00Z", alice.ObjectGuid.ToString("D"), pc.ObjectGuid.ToString("D"));
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: new SqliteDirectoryCache(db));
        var consent = new ConsentState(new(false, null, 0, "", null), new(false, null, 0, "", null));
        var view = await new AdPosteReader(source).OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, consent, CancellationToken.None);
        Check.Equal(alice.ObjectGuid, view.Association.User!.Guid!.Value, "même GUID utilisateur après renommage");
        Check.Equal("alice.renommee", view.Association.User.Login, "identifiant local actuel"); Check.True(view.Association.IdentityProven, "GUID des deux côtés");
        Check.Equal(AssociationBadge.Declared, view.Association.Badge, "affectation déclarée préservée"); Check.Equal(0, ldap.Calls, "ouverture sans réseau");
    }

    [Test]
    public static async Task Legacy_names_without_GUID_stay_unverified_and_another_GUID_never_inherits_the_old_assignment()
    {
        foreach (var foreign in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed());
            var pc = Fixtures.Computer("PC1") with { Name = "CN renommé" }; var alice = Fixtures.User("alice");
            await db.InitializeAsync(CancellationToken.None); await SaveDirectory(db, pc, alice);
            Insert(db, "PC1", "alice", "PC1", "Import CSV", "2026-10-20T12:00:00Z", computerId: foreign ? Guid.NewGuid().ToString("D") : null);
            var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: new SqliteDirectoryCache(db));
            var consent = new ConsentState(new(false, null, 0, "", null), new(false, null, 0, "", null));
            var view = await new AdPosteReader(source).OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, consent, CancellationToken.None);
            if (foreign) { Check.Null(view.Association.User, "ancien détenteur écarté même si le nom correspond"); }
            else
            {
                Check.Equal("alice", view.Association.User!.Login, "libellé hérité conservé malgré CN renommé"); Check.Null(view.Association.User.Guid, "homonyme courant non substitué");
                Check.Null(view.Association.User.Dn, "aucun lien trompeur vers le compte courant"); Check.False(view.Association.IdentityProven, "incertitude affichée");
                Check.Equal(AssociationBadge.Imported, view.Association.Badge, "provenance importée conservée");
            }
            Check.Equal(0, ldap.Calls, "aucun rapprochement réseau implicite");
        }
    }
}
