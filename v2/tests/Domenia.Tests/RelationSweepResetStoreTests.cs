using System.Security.Cryptography;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RelationSweepResetStoreTests
{
    private static async Task<DomeniaDatabase> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("reset.db"), Fixtures.Root, TestClock.Fixed()); await db.InitializeAsync(CancellationToken.None);
        Seed(db); return db;
    }
    internal static void Seed(DomeniaDatabase db)
    {
        using var sql = new SqliteDatabase(db.Path, false);
        sql.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES('legacy','PC1','2026-10-20T10:00:00Z','SESSION','alice',3);");
    }
    private static async Task<RelationSweepResetWrite> Prepare(DomeniaDatabase db)
    {
        var memory = await db.ReadRelationSweepsAsync(CancellationToken.None);
        var draft = RelationSweepReset.Draft(checked((int)memory.Total), memory.Fingerprint, null, false, false);
        draft = draft with { Target = draft.Target with { Dn = RelationSweepReset.StoreTarget(db.StoreId, db.DomainDn) } };
        return new(db.StoreId, WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, Fixtures.Now, TestClock.Fixed().LocalTimeZone), memory.Generation);
    }

    [Test]
    public static async Task Sweep_reset_backs_up_exact_legacy_rows_and_preserves_associations_and_other_D1_tables()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("ALTER TABLE park_state ADD COLUMN extension TEXT DEFAULT 'historique';");
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('PC1','alice','PC1','Saisie manuelle');");
            sql.Execute("INSERT INTO user_scan_history(login_key,login,scanned) VALUES('alice','alice',12);");
        }
        var request = await Prepare(db); var old = await db.ReadRelationSweepsAsync(CancellationToken.None);
        var result = await db.ResetRelationSweepsAsync(request, CancellationToken.None);
        Check.Equal(1, result.Forgotten, "une ligne historique effacée"); Check.Equal(1L, result.Generation, "génération nouvelle");
        var current = await db.ReadRelationSweepsAsync(CancellationToken.None); Check.Equal(0L, current.Total, "mémoire relue vide");
        Check.Equal(result.BackupSha256, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(result.BackupPath))), "sauvegarde identifiée et vérifiable");
        using var backup = new SqliteDatabase(result.BackupPath, true);
        Check.Equal("historique", (string)backup.Scalar("SELECT extension FROM park_state;")!, "extension sauvegardée");
        Check.Equal(3L, (long)backup.Scalar("SELECT attempts FROM park_state;")!, "compteur D1 sauvegardé");
        using var after = new SqliteDatabase(db.Path, true);
        Check.Equal(1L, (long)after.Scalar("SELECT count(*) FROM user_machine_links;")!, "associations intactes");
        Check.Equal(12L, (long)after.Scalar("SELECT scanned FROM user_scan_history WHERE login_key='alice';")!, "historique utilisateur intact");
        Check.False(after.Query("PRAGMA table_info(park_state);").Any(r => (string?)r["name"] == "computer_guid"), "effacement sans migration inutile de park_state");
        Check.Equal(1L, old.Total, "instantané de préparation conservé");
    }

    [Test]
    public static async Task Reset_fingerprints_include_extensions_and_raw_dates_even_when_the_typed_date_does_not_change()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("ALTER TABLE park_state ADD COLUMN extension TEXT DEFAULT 'A';"); }
        var first = await Prepare(db);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE park_state SET extension='B';"); }
        Check.False((await db.CheckRelationSweepResetAsync(first, CancellationToken.None)).Current, "extension modifiée détectée");
        var second = await Prepare(db); var date = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().At;
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE park_state SET last_probe='2026-10-20T12:00:00+02:00';"); }
        Check.Equal(date, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().At, "même instant typé");
        Check.False((await db.CheckRelationSweepResetAsync(second, CancellationToken.None)).Current, "représentation physique changée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => db.ResetRelationSweepsAsync(second, CancellationToken.None), "transaction revérifie l’empreinte");
        Check.Equal(1L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "aucun effacement après conflit");
    }

    [Test]
    public static async Task A_reset_receipt_never_deletes_passes_created_after_its_commit_and_old_generations_are_rejected()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var request = await Prepare(db);
        await db.ResetRelationSweepsAsync(request, CancellationToken.None);
        var pc = Fixtures.Computer("PC1");
        var pass = new RelationSweepWrite(db.StoreId, WritePlans.NewId(), 1, [new(pc.ObjectGuid, pc.DistinguishedName, "PC1", Fixtures.Now, "LU", null)]);
        await db.ApplyRelationSweepsAsync(pass, CancellationToken.None);
        var retry = await db.ResetRelationSweepsAsync(request, CancellationToken.None);
        Check.True(retry.AlreadyApplied, "reçu durable d’effacement retrouvé"); Check.Equal(1L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "nouveau passage non supprimé par un rejeu");
        var late = pass with { BatchId = WritePlans.NewId(), Generation = 0 };
        Check.False((await db.CheckRelationSweepsAsync(late, CancellationToken.None)).Current, "ancien passage refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => db.ApplyRelationSweepsAsync(late, CancellationToken.None), "pas de résurrection de l’ancienne génération");
    }

    [Test]
    public static async Task A_delete_trigger_with_side_effects_rolls_back_rows_generation_and_receipt()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('PC1','alice','PC1','Saisie manuelle');");
            sql.Script("CREATE TRIGGER unsafe_reset AFTER DELETE ON park_state BEGIN DELETE FROM user_machine_links; END;");
        }
        var request = await Prepare(db);
        await Check.ThrowsAsync<InvalidDataException>(() => db.ResetRelationSweepsAsync(request, CancellationToken.None), "mutation supplémentaire détectée");
        var current = await db.ReadRelationSweepsAsync(CancellationToken.None); Check.Equal(1L, current.Total, "relevé revenu par rollback"); Check.Equal(0L, current.Generation, "génération inchangée");
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "association sauvegardée par rollback");
        using var sqlAfter = new SqliteDatabase(db.Path, true);
        Check.Equal(0L, (long)sqlAfter.Scalar("SELECT count(*) FROM sqlite_master WHERE name='domenia_v2_sweep_writes';")!, "migration et reçu annulés");
    }

    [Test]
    public static async Task Reset_rejects_unreadable_rows_and_another_store_but_empty_memory_still_advances_its_generation()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var request = await Prepare(db);
        var other = new DomeniaDatabase(folder.File("other.db"), Fixtures.Root, TestClock.Fixed());
        await Check.ThrowsAsync<ArgumentException>(() => other.CheckRelationSweepResetAsync(request, CancellationToken.None), "autre chemin de base refusé");
        Check.False(File.Exists(other.Path), "autre base non créée");
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE park_state SET attempts=-1;"); }
        Check.False((await db.CheckRelationSweepResetAsync(request, CancellationToken.None)).Current, "ligne invalide non supprimée");
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("DELETE FROM park_state;"); }
        var empty = await db.ResetRelationSweepsAsync(request, CancellationToken.None);
        Check.Equal(0, empty.Forgotten, "mémoire déjà vide"); Check.Equal(1L, empty.Generation, "les anciens passages restent bloqués même sans ligne à effacer");
    }

    private static WritePlan Bind(AdRelationSweepResetExecutor executor, WritePlanDraft draft, AdDirectorySource source)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone);
        executor.Bind(draft, plan); return plan;
    }

    [Test]
    public static async Task Native_reset_is_discovered_and_uses_the_shared_confirmation_receipt_and_independent_verification()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); Seed(db);
        var writers = WriteExecutors.Discover(source, [typeof(AdDirectorySource).Assembly]);
        Check.True(writers.Require<IRelationSweepResetExecutor>() is AdRelationSweepResetExecutor, "contrat natif découvert");
        var executor = writers.Require<IRelationSweepResetExecutor>(); var receipts = new MemoryReceiptStore();
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
            new MemoryPreferenceStore(), source.Clock, new RecordingJournal(), writers: writers, receipts: receipts);
        var circuit = WriteCircuit.From(context); var planned = await circuit.PlanAsync(await executor.PlanSweepResetAsync(CancellationToken.None), CancellationToken.None);
        Check.Contains(db.StoreId, planned.Plan.Target.Dn, "base précise dans le plan"); Check.Equal(1L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "préparation sans effacement");
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        Check.Equal(WriteResult.Applied, receipt.Result, "effacement appliqué"); Check.Equal(VerificationState.Verified, receipt.Verification, "mémoire relue vide");
        Check.True(receipts.Appends >= 2, "reçu avant et après envoi"); Check.Equal(0, ldap.Searches.Count, "aucun LDAP");
        using var freshExecutor = new AdRelationSweepResetExecutor(source);
        Check.Equal(VerificationState.Verified, (await freshExecutor.VerifyAsync(planned.Plan, CancellationToken.None)).State, "vérification indépendante après libération du plan");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None), "jeton non rejoué");
    }

    [Test]
    public static async Task Native_reset_binding_rejects_copies_unbound_expired_and_previous_session_plans()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Seed(db);
        using var executor = new AdRelationSweepResetExecutor(source); var draft = await executor.PlanSweepResetAsync(CancellationToken.None);
        var unbound = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone);
        Check.False((await executor.CheckAsync(unbound, CancellationToken.None)).Current, "plan scellé non lié refusé");
        Check.Throws<DomeniaOperationException>(() => executor.Bind(draft with { }, unbound), "copie étrangère à la préparation refusée");
        var plan = Bind(executor, draft, source); ((FixedTimeProvider)source.Clock).Advance(WritePlans.Lifetime + TimeSpan.FromSeconds(1));
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "expiration respectée");
        var next = Bind(executor, await executor.PlanSweepResetAsync(CancellationToken.None), source); source.Reset();
        Check.False((await executor.CheckAsync(next, CancellationToken.None)).Current, "ancienne époque refusée");
        Check.Equal(1L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "relevés conservés");
    }

    [Test]
    public static async Task Concurrent_reset_plans_keep_their_own_raw_snapshot_and_a_later_generation_invalidates_the_other()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Seed(db);
        using var executor = new AdRelationSweepResetExecutor(source); var first = Bind(executor, await executor.PlanSweepResetAsync(CancellationToken.None), source);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE park_state SET attempts=4;"); }
        var second = Bind(executor, await executor.PlanSweepResetAsync(CancellationToken.None), source);
        Check.False((await executor.CheckAsync(first, CancellationToken.None)).Current, "premier instantané conservé et périmé");
        Check.True((await executor.CheckAsync(second, CancellationToken.None)).Current, "deuxième instantané exact");
        await executor.ExecuteAsync(second, CancellationToken.None);
        Check.False((await executor.CheckAsync(first, CancellationToken.None)).Current, "ancienne génération ne devient pas valide parce que la mémoire est vide");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(second, CancellationToken.None), "préparation exécutée consommée");
    }
}
