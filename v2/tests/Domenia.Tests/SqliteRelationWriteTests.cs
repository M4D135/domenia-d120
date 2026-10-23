using System.Collections.Immutable;
using System.Security.Cryptography;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteRelationWriteTests
{
    private static StoredRelation Relation(string user = "alice", string computer = "PC1", RelationKind kind = RelationKind.Assignment) => new(
        user, Fixtures.User(user).ObjectGuid, Fixtures.User(user).DistinguishedName,
        computer, Fixtures.Computer(computer).ObjectGuid, Fixtures.Computer(computer).DistinguishedName,
        kind, kind == RelationKind.Assignment ? RelationRules.ManualSource : "Console CIM/DCOM", Fixtures.Now.AddMinutes(-1),
        "Identités relues", true, @"TEST\operator", null);
    private static RelationChangeItem Add(StoredRelation relation, string? restores = null) => new(RelationChangeOperation.Add, null, relation, "Ajout de test", restores);
    private static RelationChangeItem Remove(StoredRelation relation) => new(RelationChangeOperation.Remove, relation, null, "Retrait de test", null);
    private static async Task<RelationStoreWrite> Prepare(DomeniaDatabase db, params RelationChangeItem[] items)
    {
        var read = await db.ReadRelationsAsync(CancellationToken.None);
        var keys = items.SelectMany(i => new[] { i.Before, i.After }).OfType<StoredRelation>().Select(RelationRules.Key).ToHashSet(StringComparer.Ordinal);
        var draft = RelationChange.Draft("Test local", "Associations", "Lot local vérifiable", "Associations", false, items, [],
            RelationChange.AddReversibility(), Fixtures.Now, TestClock.Fixed().LocalTimeZone);
        return new(db.StoreId, WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, Fixtures.Now, TestClock.Fixed().LocalTimeZone),
            [.. read.Rows.Where(r => keys.Contains(RelationRules.Key(r.Relation)))], [.. items]);
    }
    private static Task<RelationStoreResult> Apply(DomeniaDatabase db, RelationStoreWrite request) => db.ApplyRelationsAsync(request, CancellationToken.None);
    private static async Task<DomeniaDatabase> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("relations.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None); return db;
    }

    [Test]
    public static async Task Relations_commit_in_batches_with_legacy_primary_and_secondary_keys_and_durable_journal()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        var first = Relation(); var second = Relation("bob"); var observed = Relation(kind: RelationKind.Console);
        var result = await Apply(db, await Prepare(db, Add(first), Add(second), Add(observed)));
        Check.Equal(3, result.Applied, "trois associations indépendantes"); Check.Equal(0, result.JournalPending, "journal D1 copié");
        var read = await db.ReadRelationsAsync(CancellationToken.None);
        Check.Equal(3, read.Rows.Length, "plusieurs utilisateurs/natures sans écrasement");
        Check.True(read.Rows.Any(r => r.StorageKey == "PC1"), "clé D1 principale conservée");
        Check.Equal(2, read.Rows.Count(r => r.StorageKey.StartsWith("PC1|", StringComparison.Ordinal)), "deux clés secondaires");
        var journal = await db.ReadRelationJournalAsync(CancellationToken.None);
        Check.Equal(3, journal.Entries.Length, "SQLite et JSONL regroupés par UUID"); Check.Equal(0, journal.Rejected, "format D1 relu sans perte");
        Check.True(journal.Entries.All(e => e.Relation.UserGuid is not null), "GUID préservés");
        var backup = (await db.InspectAsync(CancellationToken.None))!.Backup!;
        using var old = new SqliteDatabase(backup.Path, true);
        Check.Equal(0L, (long)old.Scalar("SELECT count(*) FROM user_machine_links;")!, "sauvegarde avant premier lot");
        Check.Equal(backup.Sha256, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(backup.Path))), "sauvegarde vérifiable");
    }

    [Test]
    public static async Task Physical_CAS_detects_legacy_changes_hidden_by_the_typed_projection_without_rejecting_unrelated_writes()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var first = Relation();
        await Apply(db, await Prepare(db, Add(first)));
        var removal = await Prepare(db, Remove(first));
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET confidence=73 WHERE computer_key='PC1';"); }
        Check.False((await db.CheckRelationsAsync(removal, CancellationToken.None)).Current, "modification invisible au type détectée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, removal), "aucun retrait après conflit");
        var freshRemoval = await Prepare(db, Remove(first));
        await Apply(db, await Prepare(db, Add(Relation("bob", "PC2"))));
        Check.True((await db.CheckRelationsAsync(freshRemoval, CancellationToken.None)).Current, "autre poste ne rend pas le plan caduc");
        await Apply(db, freshRemoval);
        Check.Equal("PC2", (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.Computer, "autre association intacte");
    }

    [Test]
    public static async Task A_failing_second_insert_rolls_back_the_first_row_the_additive_schema_and_the_journal()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Script("CREATE TRIGGER fail_relation BEFORE INSERT ON user_machine_links WHEN NEW.user_login='bob' BEGIN SELECT RAISE(ABORT,'test'); END;"); }
        var request = await Prepare(db, Add(Relation()), Add(Relation("bob", "PC2")));
        await Check.ThrowsAsync<SqliteStoreException>(() => Apply(db, request), "échec au milieu du lot");
        Check.Equal(0, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Length, "aucune ligne partielle");
        Check.Equal(0, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "aucun faux ajout au journal");
        using var check = new SqliteDatabase(db.Path, true);
        Check.False(check.Query("PRAGMA table_info(user_machine_links);").Any(r => (string?)r["name"] == "batch_id"), "migration annulée elle aussi");
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM sqlite_master WHERE name='domenia_v2_relation_writes';")!, "aucun reçu partiel");
    }

    [Test]
    public static async Task Legacy_keys_extension_columns_and_confidence_survive_updates_then_removals_are_restorable()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Script("ALTER TABLE user_machine_links ADD COLUMN local_extension TEXT;");
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,confidence,observed_at,local_extension) VALUES('PC1|ancienne-cle','alice','PC1','Saisie manuelle',42,'2026-10-20T12:00:00Z','à conserver');");
        }
        var old = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        var updated = old with { Details = "Détail relu", When = Fixtures.Now, BatchId = "import-1", Declarant = @"TEST\operator" };
        var prepared = await Prepare(db, new RelationChangeItem(RelationChangeOperation.Replace, old, updated, "Mise à jour", null));
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET local_extension='nouvelle donnée';"); }
        Check.False((await db.CheckRelationsAsync(prepared, CancellationToken.None)).Current, "changement d’une colonne inconnue détecté");
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET local_extension='à conserver';"); }
        await Apply(db, prepared);
        using (var sql = new SqliteDatabase(db.Path, true))
        {
            var row = sql.Query("SELECT computer_key,local_extension,confidence,batch_id FROM user_machine_links;").Single();
            Check.Equal("PC1|ancienne-cle", (string)row["computer_key"]!, "clé non réécrite"); Check.Equal(42L, (long)row["confidence"]!, "ancienne confiance intacte");
            Check.Equal("à conserver", (string)row["local_extension"]!, "colonne inconnue conservée"); Check.Equal("import-1", (string)row["batch_id"]!, "colonne additive utilisée");
        }
        await Apply(db, await Prepare(db, Remove(updated)));
        var removed = (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Single(e => e.Action == RelationJournalAction.Removed);
        await Apply(db, await Prepare(db, Add(removed.Relation, removed.Id)));
        Check.Equal(RelationRules.Fingerprint(updated), RelationRules.Fingerprint((await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation), "contenu typé restauré");
        Check.Equal(0, RelationRules.Restorable((await db.ReadRelationJournalAsync(CancellationToken.None)).Entries).Length, "retrait consommé une fois");
    }

    [Test]
    public static async Task A_committed_plan_is_not_replayed_after_restart_even_after_a_later_removal()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var relation = Relation();
        var addition = await Prepare(db, Add(relation)); await Apply(db, addition);
        await Apply(db, await Prepare(db, Remove(relation)));
        var reopened = new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()); await reopened.InitializeAsync(CancellationToken.None);
        var replay = await Apply(reopened, addition);
        Check.Equal(0, replay.Applied, "aucun rejeu"); Check.Equal(1, replay.AlreadyDone, "reçu durable retrouvé");
        Check.Equal(0, (await reopened.ReadRelationsAsync(CancellationToken.None)).Rows.Length, "retrait ultérieur respecté");
        Check.Equal(2, (await reopened.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "pas de nouvelle entrée de journal");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(reopened, addition with { Items = [addition.Items[0] with { Note = "autres octets" }] }), "même ID avec autre contenu refusé");
    }

    [Test]
    public static async Task A_locked_legacy_journal_does_not_lose_SQLite_entries_and_the_outbox_resumes_on_the_next_write()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var held = new FileStream(db.Path + ".relations-journal.jsonl", FileMode.Create, FileAccess.ReadWrite, FileShare.None))
        {
            var result = await Apply(db, await Prepare(db, Add(Relation())));
            Check.Equal(1, result.Applied, "lot local commis"); Check.Equal(1, result.JournalPending, "projection en attente signalée");
            var read = await db.ReadRelationJournalAsync(CancellationToken.None);
            Check.Equal(1, read.Entries.Length, "entrée durable lisible sans JSONL"); Check.False(read.LegacyReadable, "historique D1 inaccessible explicite");
        }
        var next = await Apply(db, await Prepare(db, Add(Relation("bob", "PC2"))));
        Check.Equal(0, next.JournalPending, "file précédente vidée après libération");
        Check.Equal(2, File.ReadAllLines(db.Path + ".relations-journal.jsonl").Length, "deux entrées recopiées");
        Check.Equal(2, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "pas de doubles entrées à la lecture");
    }

    [Test]
    public static async Task Duplicate_semantic_rows_and_unknown_restore_ids_never_select_an_arbitrary_legacy_row()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var relation = Relation();
        await Check.ThrowsAsync<DomeniaOperationException>(async () => await Apply(db, await Prepare(db, Add(relation, WritePlans.NewId()))), "restauration sans retrait refusée");
        await Apply(db, await Prepare(db, Add(relation)));
        var request = await Prepare(db, Remove(relation));
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Script("INSERT INTO user_machine_links SELECT 'PC1|doublon',user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn,kind,batch_id,declarant FROM user_machine_links WHERE computer_key='PC1';"); }
        Check.False((await db.CheckRelationsAsync(request, CancellationToken.None)).Current, "doublon refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, request), "aucun retrait arbitraire");
        Check.Equal(2, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Length, "deux originaux conservés");
    }

    [Test]
    public static async Task A_trigger_that_recreates_a_removed_relation_with_another_fingerprint_rolls_back_the_whole_removal()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var relation = Relation();
        await Apply(db, await Prepare(db, Add(relation)));
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Script("CREATE TRIGGER recreate_relation AFTER DELETE ON user_machine_links BEGIN INSERT INTO user_machine_links(computer_key,user_login,computer,source,user_guid,computer_guid,kind,details) VALUES(OLD.computer_key,OLD.user_login,OLD.computer,OLD.source,OLD.user_guid,OLD.computer_guid,OLD.kind,'modifié'); END;");
        }
        var request = await Prepare(db, Remove(relation));
        await Check.ThrowsAsync<InvalidDataException>(() => Apply(db, request), "relecture différente de l’effet prévu");
        Check.Equal(RelationRules.Fingerprint(relation), RelationRules.Fingerprint((await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation), "original rétabli par rollback");
        Check.Equal(1, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "aucun faux retrait au journal");
    }

    [Test]
    public static async Task Foreign_stores_simulation_tampered_plans_and_foreign_DNs_are_rejected_before_mutation()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var request = await Prepare(db, Add(Relation()));
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, request with { StoreId = new string('0', 64) }), "autre base refusée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, request with { Plan = request.Plan with { Simulated = true } }), "simulation refusée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, request with { Plan = request.Plan with { Operator = "autre" } }), "empreinte invalide refusée");
        var foreign = await Prepare(db, Add(Relation() with { UserDn = "CN=alice,DC=foreign,DC=local" }));
        await Check.ThrowsAsync<InvalidDataException>(() => Apply(db, foreign), "DN hors domaine refusé");
        Check.Equal(0, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Length, "aucune écriture après refus");
    }
}
