using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationWriteTests
{
    private static async Task<(DomeniaDatabase Db, AdDirectorySource Source, AdBoundaryTests.RecordingAdConnection Ldap)> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        await cache.SaveObjectsAsync(Fixtures.Snapshot(users: [Fixtures.User("alice")], computers: [Fixtures.Computer("PC1")]), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); return (db, source, ldap);
    }
    private static void Insert(DomeniaDatabase db, string storageKey = "PC1", string user = "alice", string computer = "PC1", string source = "Console CIM/DCOM")
    {
        using var sql = new SqliteDatabase(db.Path, false);
        sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,observed_at,details,user_guid,computer_guid,user_dn,computer_dn,verified_in_ad) VALUES(?1,?2,?3,?4,?5,'Origine conservée',?6,?7,?8,?9,1);",
            storageKey, user, computer, source, Fixtures.Now.AddMinutes(-1).ToString("o"), Fixtures.User(user).ObjectGuid.ToString("D"), Fixtures.Computer(computer).ObjectGuid.ToString("D"),
            Fixtures.User(user).DistinguishedName, Fixtures.Computer(computer).DistinguishedName);
    }
    private static async Task<WritePlanDraft> Removal(AdRelationChangeExecutor executor, DomeniaDatabase db)
    {
        var relation = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.First().Relation;
        return await executor.PlanRemovalAsync(RelationRules.Key(relation), RelationRules.Fingerprint(relation), CancellationToken.None);
    }
    private static WritePlan Bind(AdRelationChangeExecutor executor, WritePlanDraft draft)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
        executor.Bind(draft, plan); return plan;
    }

    [Test]
    public static async Task Native_local_removal_uses_the_shared_confirmation_receipt_and_verification_circuit_without_LDAP()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder); Insert(db);
        using var executor = new AdRelationChangeExecutor(source); var receipts = new MemoryReceiptStore();
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
            new MemoryPreferenceStore(), source.Clock, new RecordingJournal(), writers: WriteExecutors.From([executor]), receipts: receipts);
        var circuit = WriteCircuit.From(context); var planned = await circuit.PlanAsync(await Removal(executor, db), CancellationToken.None);
        Check.Contains(db.StoreId, planned.Plan.Target.Dn, "base précise scellée");
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "préparation sans mutation");
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        Check.Equal(WriteResult.Applied, receipt.Result, "retrait local appliqué"); Check.Equal(VerificationState.Verified, receipt.Verification, "postcondition relue");
        Check.True(receipts.Appends >= 2, "reçu avant et après envoi"); Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "association retirée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None), "jeton non réutilisable");
        Check.Equal(1, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "un seul retrait journalisé"); Check.Equal(0, ldap.Searches.Count, "aucun LDAP");
    }

    [Test]
    public static async Task Concurrent_identical_relation_plans_keep_their_own_raw_SQLite_preconditions()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source; Insert(db);
        using var executor = new AdRelationChangeExecutor(source); var oldDraft = await Removal(executor, db);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET confidence=0.7 WHERE computer_key='PC1';"); }
        var freshDraft = await Removal(executor, db);
        Check.True(oldDraft.Changes.SequenceEqual(freshDraft.Changes), "même association visible malgré modification d’une colonne D1");
        var oldPlan = Bind(executor, oldDraft); var freshPlan = Bind(executor, freshDraft);
        Check.False((await executor.CheckAsync(oldPlan, CancellationToken.None)).Current, "ancien état brut non remplacé par celui du nouveau plan");
        Check.True((await executor.CheckAsync(freshPlan, CancellationToken.None)).Current, "nouveau plan lié à sa propre relecture");
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "précontrôles sans mutation");
    }

    [Test]
    public static async Task Unbound_copied_expired_or_previous_session_plans_cannot_write_local_relations()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source; Insert(db);
        using var executor = new AdRelationChangeExecutor(source); var draft = await Removal(executor, db);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, Fixtures.Now, source.Zone);
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "plan scellé mais non lié refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Task.Run(() => executor.Bind(draft with { }, plan)), "copie hors mémoire de préparation refusée");
        executor.Bind(draft, plan); ((FixedTimeProvider)source.Clock).Advance(WritePlans.Lifetime + TimeSpan.FromSeconds(1));
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "expiration respectée");
        var next = await Removal(executor, db);
        var nextPlan = WritePlans.Seal(next, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone);
        executor.Bind(next, nextPlan); source.Reset();
        Check.False((await executor.CheckAsync(nextPlan, CancellationToken.None)).Current, "ancienne session refusée");
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun changement");
    }

    [Test]
    public static async Task A_relation_receipt_can_be_verified_after_restart_only_against_its_original_store()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source; Insert(db);
        using var executor = new AdRelationChangeExecutor(source); var plan = Bind(executor, await Removal(executor, db));
        await executor.ExecuteAsync(plan, CancellationToken.None);
        using var restarted = new AdRelationChangeExecutor(source);
        Check.Equal(VerificationState.Verified, (await restarted.VerifyAsync(plan, CancellationToken.None)).State, "relecture sans brouillon en mémoire");
        Check.False((await restarted.CheckAsync(plan, CancellationToken.None)).Current, "aucun rejeu possible après redémarrage");
        using var otherFolder = new TemporaryFolder(); var (_, otherSource, _) = await Open(otherFolder); using var otherOwned = otherSource;
        using var other = new AdRelationChangeExecutor(otherSource);
        Check.Equal(VerificationState.Unknown, (await other.VerifyAsync(plan, CancellationToken.None)).State, "absence dans une autre base ne prouve pas le retrait");
        Insert(db, source: "Console CIM/DCOM");
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET details='Association revenue différemment';"); }
        Check.Equal(VerificationState.Mismatch, (await restarted.VerifyAsync(plan, CancellationToken.None)).State, "clé revenue avec une autre empreinte non présentée comme supprimée");
    }

    [Test]
    public static async Task Native_restore_preserves_original_identity_dates_and_source_and_consumes_the_removal_once()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder); using var owned = source; Insert(db);
        var original = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        using var executor = new AdRelationChangeExecutor(source); await executor.ExecuteAsync(Bind(executor, await Removal(executor, db)), CancellationToken.None);
        var entry = (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Single();
        var plan = Bind(executor, await executor.PlanRestoreAsync(entry.Id, CancellationToken.None));
        Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "retrait toujours restaurable");
        await executor.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(RelationRules.Fingerprint(original), RelationRules.Fingerprint((await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation), "original remis exactement");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanRestoreAsync(entry.Id, CancellationToken.None), "retrait consommé");
        Check.Equal(0, ldap.Searches.Count, "aucune requalification réseau implicite d’un historique");
    }

    [Test]
    public static async Task Import_undo_is_bounded_and_does_not_remove_other_batches_or_declared_assignments()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Script("ALTER TABLE user_machine_links ADD COLUMN kind TEXT; ALTER TABLE user_machine_links ADD COLUMN batch_id TEXT;"); }
        for (var i = 1; i <= 65; i++) { Insert(db, "PC" + i, computer: "PC" + i, source: "Import CSV"); }
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET kind='Imported',batch_id='lot-a';"); }
        Insert(db, "autre-lot", computer: "PC66", source: "Import CSV"); Insert(db, "declaration", source: RelationRules.ManualSource);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET kind='Imported',batch_id='lot-b' WHERE computer_key='autre-lot';"); }
        using var executor = new AdRelationChangeExecutor(source); var draft = await executor.PlanImportUndoAsync("lot-a", CancellationToken.None);
        Check.Equal(64, draft.Changes.Length, "64 lignes exactes dans la confirmation");
        await executor.ExecuteAsync(Bind(executor, draft), CancellationToken.None);
        var rows = (await db.ReadRelationsAsync(CancellationToken.None)).Rows;
        Check.Equal(3, rows.Length, "une ligne reportée, un autre lot et la déclaration conservés");
        Check.True(rows.Any(r => r.Relation.Kind == RelationKind.Assignment), "déclaration préservée");
        Check.Equal(1, (await executor.PlanImportUndoAsync("lot-a", CancellationToken.None)).Changes.Length, "suite explicite du lot");
    }

    [Test]
    public static async Task Ambiguous_physical_rows_and_modified_display_fingerprints_cannot_prepare_removals()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source; Insert(db);
        using var executor = new AdRelationChangeExecutor(source); var original = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanRemovalAsync(RelationRules.Key(original), "changed", CancellationToken.None), "empreinte affichée différente");
        Insert(db, "copie");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanRemovalAsync(RelationRules.Key(original), RelationRules.Fingerprint(original), CancellationToken.None), "doublon physique refusé");
        Check.Equal(2L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "deux originaux préservés");
    }
}
