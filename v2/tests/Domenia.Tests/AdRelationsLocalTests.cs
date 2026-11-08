using System.Security.Cryptography;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationsLocalTests
{
    private static StoredRelation Link(string computer = "PC1") => new("alice", Fixtures.User("alice").ObjectGuid, Fixtures.User("alice").DistinguishedName,
        computer, Fixtures.Computer(computer).ObjectGuid, Fixtures.Computer(computer).DistinguishedName, RelationKind.Console, RelationRules.ConsoleSource,
        Fixtures.Now.AddMinutes(-2), "Console observée", true, null, null);
    private static async Task<(DomeniaDatabase Db, AdDirectorySource Source, AdBoundaryTests.RecordingAdConnection Ldap)> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        await cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")], users: [Fixtures.User("alice")]), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); return (db, source, ldap);
    }
    private static void Insert(DomeniaDatabase db, string key)
    {
        var link = Link(); using var sql = new SqliteDatabase(db.Path, false);
        sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,observed_at,details,user_guid,computer_guid,user_dn,computer_dn,verified_in_ad) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1);",
            key, link.UserLogin, link.Computer, link.Source, link.When!.Value.ToString("o"), link.Details, link.UserGuid!.Value.ToString("D"), link.ComputerGuid!.Value.ToString("D"), link.UserDn, link.ComputerDn);
    }

    [Test]
    public static async Task Native_relations_local_views_read_existing_storage_without_LDAP_migration_or_journal_creation()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder); using var owned = source; Insert(db, "PC1");
        var hash = SHA256.HashData(File.ReadAllBytes(db.Path)); var reader = new AdRelationsReader(source);
        var overview = await reader.OverviewAsync(CancellationToken.None); var list = await reader.ListAsync(CancellationToken.None);
        var subject = await reader.SubjectAsync("alice", CancellationToken.None); var matches = await reader.SubjectsAsync("ali", CancellationToken.None);
        var journal = await reader.JournalAsync(CancellationToken.None); var pending = await reader.PendingAsync(CancellationToken.None);
        Check.False(overview.Simulated, "base réelle"); Check.Equal(1, overview.Total, "une association locale");
        Check.Equal(1, list.Rows.Length, "liste de la base"); Check.Equal(1, subject.Associations.Length, "sujet local"); Check.Equal(1, matches.Results.Length, "recherche de l’index");
        Check.Contains("aucune lecture réseau", list.Notice, "provenance locale explicite");
        Check.Equal(0, journal.Entries.Length, "journal absent"); Check.Equal(0, pending.Total, "pas d’observation fabriquée");
        Check.Equal(0, ldap.Searches.Count, "aucun LDAP"); Check.True(hash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "base inchangée");
        Check.False(File.Exists(db.Path + ".relations-journal.jsonl"), "journal non créé par lecture");
    }

    [Test]
    public static void Native_lookup_does_not_follow_missing_GUIDs_foreign_authorities_or_CN_aliases_and_excludes_ambiguous_identities()
    {
        var alice = Fixtures.User("alice"); var other = Fixtures.User("bob") with { SamAccountName = "alice" };
        var pc = Fixtures.Computer("PC1") with { Name = "Etiquette de classement" };
        var lookup = new AdRelationLookup(Fixtures.Snapshot(users: [other], computers: [pc]));
        Check.Null(lookup.User(alice.ObjectGuid, "alice"), "ancien GUID non réattribué au nouveau nom");
        Check.Null(lookup.Find(@"FOREIGN\alice"), "autorité étrangère refusée"); Check.Null(lookup.Find("PC1.foreign.local"), "FQDN étranger non raccourci");
        Check.Null(lookup.Find("Etiquette de classement"), "CN différent du nom Windows non utilisé comme alias machine");
        Check.Equal(pc.ObjectGuid, lookup.Find("PC1.test.local")!.Guid, "nom DNS exact retrouvé");
        Check.Equal(other.ObjectGuid, lookup.Find(@"TEST\alice")!.Guid, "autorité du domaine explicite");
        var ambiguous = new AdRelationLookup(Fixtures.Snapshot(users: [alice, other], computers: [pc]));
        Check.Null(ambiguous.Find("alice"), "deux comptes, aucun premier choisi");
        Check.NotNull(ambiguous.User(alice.ObjectGuid, "alice"), "GUID exact reste disponible malgré homonymie");
        var duplicates = new AdRelationLookup(Fixtures.Snapshot(users: [alice, other with { DistinguishedName = alice.DistinguishedName }], computers: [pc]));
        Check.Equal(2, duplicates.Rejected, "deux versions du même DN écartées"); Check.Null(duplicates.User(alice.ObjectGuid, "alice"), "identité ambiguë non promue");
    }

    [Test]
    public static async Task Duplicate_physical_relations_remain_visible_with_distinct_row_ids_and_disabled_mutations()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source;
        Insert(db, "PC1"); Insert(db, "PC1|ancienne-copie"); var reader = new AdRelationsReader(source);
        var list = await reader.ListAsync(CancellationToken.None); var subject = await reader.SubjectAsync("alice", CancellationToken.None);
        Check.Equal(2, list.Rows.Length, "deux originaux visibles"); Check.Equal(2, list.Rows.Select(r => r.Key).Distinct().Count(), "identifiants de grille distincts");
        Check.True(list.Rows.All(r => r.StorageAmbiguous), "aucune mutation choisie arbitrairement");
        Check.Equal(2, subject.Associations.Select(r => r.Key).Distinct().Count(), "même protection dans le sujet");
        Check.Contains("Plusieurs lignes", list.Notice, "ambiguïté annoncée");
    }

    [Test]
    public static async Task Opening_pending_views_never_saves_observations_or_contacts_the_network()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder); using var owned = source;
        var shared = AdRelationSession.For(source); shared.ObserveValidated(Link(), source.Epoch);
        var reader = new AdRelationsReader(source); var pending = await reader.PendingAsync(CancellationToken.None); var list = await reader.ListAsync(CancellationToken.None);
        Check.Equal(1, pending.Total, "observation en attente"); Check.Equal(RelationPersistence.Session, list.Rows.Single().Persistence, "session seulement");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucune sauvegarde à l’ouverture");
        Check.Equal(1, shared.Snapshot(source.Epoch).Length, "observation conservée pour le producteur"); Check.Equal(0, ldap.Searches.Count, "aucun réseau");
    }

    [Test]
    public static async Task A_foreign_relation_store_is_not_mixed_with_the_local_directory()
    {
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(),
            connection: new AdBoundaryTests.RecordingAdConnection(), localStore: new ForeignStore());
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdRelationsReader(source).ListAsync(CancellationToken.None), "base étrangère refusée");
        Check.Equal(RelationErrors.IdentityChanged, error.Code, "domaine incompatible explicite");
    }

    [Test]
    public static void Large_local_relation_graphs_limit_the_first_ring_without_truncating_the_underlying_rows()
    {
        var computers = Enumerable.Range(1, 150).Select(i => Fixtures.Computer("PC" + i)).ToArray(); var alice = Fixtures.User("alice");
        var lookup = new AdRelationLookup(Fixtures.Snapshot(users: [alice], computers: computers)); var links = computers.Select(c => Link(c.Name)).ToArray();
        var subject = lookup.User(alice.ObjectGuid, "alice")!;
        var view = RelationProjection.Subject(subject, "Utilisateurs", links, [], links, lookup, null, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
        Check.Equal(150, view.Associations.Length, "liste complète conservée"); Check.True(view.Graph.Truncated, "graphe partiel explicite");
        Check.Equal(RelationProjection.FirstRingLimit + 1, view.Graph.Nodes.Length, "128 voisins et sujet");
    }

    [Test]
    public static async Task An_unreadable_legacy_journal_path_is_not_reported_as_a_missing_history()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source;
        Directory.CreateDirectory(db.Path + ".relations-journal.jsonl");
        var journal = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.False(journal.LegacyReadable, "chemin occupé par un dossier non présenté comme fichier absent");
        Check.Contains("inaccessible", (await new AdRelationsReader(source).JournalAsync(CancellationToken.None)).Note, "incertitude visible");
    }

    private sealed class ForeignStore : IDirectoryCache, IRelationLocalCache
    {
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(Fixtures.Snapshot(users: [Fixtures.User("alice")]));
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Lecture seule");
        public Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken token) => Task.FromResult(RelationCacheSnapshot.Empty("foreign", "DC=foreign,DC=local"));
        public Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken token) => throw new InvalidOperationException("Ne pas lire un journal étranger");
    }
}
