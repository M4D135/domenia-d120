using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationSessionTests
{
    private static StoredRelation Observation(string user = "alice", string computer = "PC1", RelationKind kind = RelationKind.Console) => new(
        user, Fixtures.User(user).ObjectGuid, Fixtures.User(user).DistinguishedName, computer, Fixtures.Computer(computer).ObjectGuid,
        Fixtures.Computer(computer).DistinguishedName, kind, kind == RelationKind.Console ? "Console CIM/DCOM" : "LogonUI.LastLoggedOnSAMUser",
        kind == RelationKind.History ? null : Fixtures.Now.AddMinutes(-1), "Identités validées dans la source native", true, null, null);
    private static async Task<(DomeniaDatabase Db, SqliteDirectoryCache Cache, AdDirectorySource Source, AdBoundaryTests.RecordingAdConnection Ldap)> Open(TemporaryFolder folder, Func<SqliteDirectoryCache, IDirectoryCache>? wrap = null)
    {
        var db = new DomeniaDatabase(folder.File("auto.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        await cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")], users: [Fixtures.User("alice")]), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: wrap?.Invoke(cache) ?? cache);
        await source.ReadLocalAsync(CancellationToken.None); return (db, cache, source, ldap);
    }

    [Test]
    public static async Task Native_observations_save_in_64_item_batches_without_LDAP_or_replacing_declared_assignments()
    {
        using var folder = new TemporaryFolder(); var (db, _, source, ldap) = await Open(folder); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,user_guid,computer_guid) VALUES('PC1','declared','PC1','Saisie manuelle',?1,?2);", Fixtures.User("declared").ObjectGuid.ToString("D"), Fixtures.Computer("PC1").ObjectGuid.ToString("D")); }
        var session = AdRelationSession.For(source);
        for (var i = 1; i <= 65; i++) { Check.True(session.ObserveValidated(Observation("alice", "PC" + i), source.Epoch).Accepted, "observation qualifiée reçue"); }
        var saved = await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(65, saved.Saved, "65 observations mémorisées"); Check.Equal(2, saved.Batches, "64 puis une"); Check.Equal(0, saved.Remaining, "file vide");
        var rows = (await db.ReadRelationsAsync(CancellationToken.None)).Rows;
        Check.Equal(66, rows.Length, "déclaration et observations coexistent"); Check.True(rows.Any(r => r.Relation.Kind == RelationKind.Assignment && r.Relation.UserLogin == "declared"), "déclaration intacte");
        Check.Equal(65, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "chaque changement tracé");
        Check.Equal(0, ldap.Searches.Count, "aucune lecture LDAP lancée par la sauvegarde locale"); Check.Equal(0, session.Snapshot(source.Epoch).Length, "observations acquittées libérées");
    }

    [Test]
    public static async Task GUID_observations_do_not_reidentify_legacy_names_and_undated_history_stays_undated()
    {
        using var folder = new TemporaryFolder(); var (db, _, source, _) = await Open(folder); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,observed_at) VALUES('PC1','alice','PC1','Console CIM/DCOM','2026-10-20T12:00:00Z');"); }
        var session = AdRelationSession.For(source);
        session.ObserveValidated(Observation(), source.Epoch); session.ObserveValidated(Observation(kind: RelationKind.History), source.Epoch);
        await session.SaveAsync(source.Epoch, CancellationToken.None);
        var rows = (await db.ReadRelationsAsync(CancellationToken.None)).Rows;
        Check.Equal(3, rows.Length, "historique, ancien lien et nouvelle observation séparés");
        Check.Null(rows.Single(r => r.StorageKey == "PC1").Relation.UserGuid, "ancien nom non transformé en GUID actuel");
        Check.Null(rows.Single(r => r.Relation.Kind == RelationKind.History).Relation.When, "date LogonUI non inventée");
    }

    [Test]
    public static async Task Older_or_already_stored_observations_do_not_move_dates_back_or_fill_session_memory_forever()
    {
        using var folder = new TemporaryFolder(); var (db, _, source, _) = await Open(folder); using var owned = source; var session = AdRelationSession.For(source);
        var fresh = Observation(); session.ObserveValidated(fresh, source.Epoch); await session.SaveAsync(source.Epoch, CancellationToken.None);
        session.ObserveValidated(fresh with { When = Fixtures.Now.AddDays(-1), Details = "Réponse tardive" }, source.Epoch);
        var ignored = await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(0, ignored.Saved, "aucun recul de date"); Check.Equal(0, ignored.Remaining, "ancienne observation ne sera pas rejouée");
        Check.Equal(fresh.When, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.When, "date récente conservée");
        session.ObserveValidated(fresh, source.Epoch); await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(0, session.Snapshot(source.Epoch).Length, "constat déjà enregistré retiré de la file");
        Check.Equal(1, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "aucun faux rafraîchissement");
    }

    [Test]
    public static async Task Failed_batches_remain_pending_without_an_immediate_retry_then_can_resume_explicitly()
    {
        using var folder = new TemporaryFolder(); FaultStore? fault = null;
        var (db, _, source, _) = await Open(folder, cache => fault = new(cache, afterCommit: false)); using var owned = source; var session = AdRelationSession.For(source);
        session.ObserveValidated(Observation(), source.Epoch);
        var failed = await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(0, failed.Saved, "échec non annoncé réussi"); Check.Equal(1, failed.Remaining, "observation conservée"); Check.Equal(1, fault!.Calls, "pas de boucle de reprise");
        var resumed = await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(1, resumed.Saved, "nouvelle tentative réussie"); Check.Equal(0, resumed.Remaining, "plus rien en attente");
        Check.Equal(1, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "une seule entrée durable");
    }

    [Test]
    public static async Task Lost_acknowledgement_after_commit_is_settled_by_re_reading_without_a_second_write()
    {
        using var folder = new TemporaryFolder(); FaultStore? fault = null;
        var (db, _, source, _) = await Open(folder, cache => fault = new(cache, afterCommit: true)); using var owned = source; var session = AdRelationSession.For(source);
        session.ObserveValidated(Observation(), source.Epoch);
        var uncertain = await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(1, uncertain.Remaining, "observation non acquittée gardée"); Check.Equal(0, uncertain.Saved, "pas de succès sans retour");
        var resumed = await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(0, resumed.Saved, "relecture suffisante"); Check.Equal(0, resumed.Remaining, "file acquittée"); Check.Equal(1, fault!.Calls, "aucun second envoi");
        Check.Equal(1, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "une seule entrée");
    }

    [Test]
    public static async Task Unqualified_names_foreign_objects_assignments_and_old_epochs_cannot_enter_native_automatic_storage()
    {
        using var folder = new TemporaryFolder(); var (_, _, source, _) = await Open(folder); using var owned = source; var session = AdRelationSession.For(source); var epoch = source.Epoch;
        foreach (var invalid in new[] { Observation() with { UserGuid = null }, Observation() with { VerifiedInAd = false }, Observation() with { Kind = RelationKind.Assignment },
            Observation() with { UserDn = "CN=alice,DC=other,DC=local" }, Observation() with { When = Fixtures.Now.AddDays(1) }, Observation() with { When = null } })
        { Check.False(session.ObserveValidated(invalid, epoch).Accepted, "entrée non qualifiée refusée"); }
        Check.True(session.ObserveValidated(Observation(), epoch).Accepted, "observation qualifiée acceptée"); source.Reset();
        Check.Throws<DomeniaOperationException>(() => session.Snapshot(epoch), "ancienne époque refusée");
        Check.Equal(0, session.Snapshot(source.Epoch).Length, "observations vidées au changement de session");
    }

    private sealed class FaultStore(SqliteDirectoryCache inner, bool afterCommit) : IDirectoryCache, IRelationLocalWriter
    {
        internal int Calls { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => inner.ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => inner.SaveAsync(snapshot, scope, controller, token);
        public Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken token) => inner.ReadRelationsAsync(token);
        public Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken token) => inner.ReadRelationJournalAsync(token);
        public Task<WritePrecheck> CheckRelationsAsync(RelationStoreWrite request, CancellationToken token) => inner.CheckRelationsAsync(request, token);
        public async Task<RelationStoreResult> ApplyRelationsAsync(RelationStoreWrite request, CancellationToken token)
        {
            Calls++;
            if (Calls == 1 && !afterCommit) { throw new IOException("Interruption avant transaction"); }
            var result = await inner.ApplyRelationsAsync(request, token);
            if (Calls == 1) { throw new IOException("Retour perdu après transaction"); }
            return result;
        }
    }
}
