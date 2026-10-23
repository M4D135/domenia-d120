using System.Security.Cryptography;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemoteTaskReadJournalTests
{
    private static RemoteTaskReadPlan Plan(DomeniaDatabase db)
    {
        var pc = Fixtures.Computer("PC1");
        return new(Guid.NewGuid(), db.StoreId, pc.ObjectGuid, pc.DistinguishedName, pc.DnsHostName!, pc.WhenCreated,
            Fixtures.Now, @"TEST\operator", RemoteTaskReadKind.UserIdentity, new('a', 64), new('b', 64));
    }

    private static async Task<DomeniaDatabase> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("remote.db"), Fixtures.Root, TestClock.Fixed());
        await new SqliteDirectoryCache(db).SaveObjectsAsync(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]), null, CancellationToken.None);
        return db;
    }

    [Test]
    public static async Task Remote_read_preparation_is_durable_idempotent_and_does_not_change_D1_rows()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("INSERT INTO park_state(computer_key,computer,status) VALUES('legacy','PC1','SESSION');"); }
        var plan = Plan(db); var first = await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        var again = await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        Check.Equal(first, again, "même préparation sans nouvelle révision"); Check.True(first.CleanupRequired, "préparation considérée en attente dès avant le réseau");
        var cold = new SqliteDirectoryCache(new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()));
        Check.Equal(first, (await cold.PendingTaskReadsAsync(CancellationToken.None)).Single(), "reprise locale après redémarrage");
        Check.Equal(first, await cold.ReadTaskReadAsync(plan.Id, CancellationToken.None), "lecture sans initialisation");
        var backup = (await db.InspectAsync(CancellationToken.None))!.Backup!;
        Check.Equal(backup.Sha256, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(backup.Path))), "sauvegarde vérifiée avant ajout du journal");
        using var saved = new SqliteDatabase(backup.Path, true);
        Check.Equal(0L, (long)saved.Scalar("SELECT count(*) FROM sqlite_master WHERE name='domenia_v2_remote_reads';")!, "sauvegarde avant migration additive");
        using var current = new SqliteDatabase(db.Path, true);
        Check.Equal("SESSION", current.Scalar("SELECT status FROM park_state;") as string, "ligne D1 intacte");
        await Check.ThrowsAsync<InvalidDataException>(() => db.PrepareTaskReadAsync(plan with { Nonce = new('c', 64) }, CancellationToken.None), "ID déjà lié à d’autres octets");
    }

    [Test]
    public static async Task Pending_remote_read_blocks_same_host_until_stopped_and_cleaned_receipt()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var plan = Plan(db);
        await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        await Check.ThrowsAsync<InvalidDataException>(() => db.PrepareTaskReadAsync(Plan(db), CancellationToken.None), "pas de seconde tâche pendant une issue inconnue");
        var partial = new RemoteTaskReadCompletion(Fixtures.Now, true, false, false, "Résultat reçu, arrêt à vérifier.");
        var next = await db.CompleteTaskReadAsync(plan.Id, 1, partial, CancellationToken.None);
        Check.True(next.CleanupRequired, "réponse reçue ne prouve pas le nettoyage");
        var cold = new SqliteDirectoryCache(new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()));
        var done = await cold.CompleteTaskReadAsync(plan.Id, next.Revision, partial with { ExecutionStopped = true, ArtifactsRemoved = true, Detail = "Nettoyé." }, CancellationToken.None);
        Check.False(done.CleanupRequired, "nettoyage confirmé après réouverture"); Check.Equal(0, (await cold.PendingTaskReadsAsync(CancellationToken.None)).Length, "historique exclu des attentes");
        Check.Equal(done, await cold.ReadTaskReadAsync(plan.Id, CancellationToken.None), "historique conservé");
        Check.True((await db.PrepareTaskReadAsync(Plan(db), CancellationToken.None)).CleanupRequired, "nouvelle lecture après nettoyage confirmé");
    }

    [Test]
    public static async Task Remote_receipts_reject_stale_revisions_regressions_and_impossible_cleanup()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var plan = Plan(db); await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        var read = new RemoteTaskReadCompletion(Fixtures.Now, true, false, false, "Reçu.");
        var next = await db.CompleteTaskReadAsync(plan.Id, 1, read, CancellationToken.None);
        Check.Equal(next, await db.CompleteTaskReadAsync(plan.Id, 1, read, CancellationToken.None), "réessai exact reconnu avant comparaison de révision");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 1, read with { ExecutionStopped = true }, CancellationToken.None), "révision périmée");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 2, read with { ResultReceived = false }, CancellationToken.None), "effet observé non oublié");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 2, read with { ArtifactsRemoved = true }, CancellationToken.None), "nettoyage sans arrêt impossible");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 2, read with { At = Fixtures.Now.AddMinutes(3) }, CancellationToken.None), "date future refusée");
        Check.Equal(next, await db.ReadTaskReadAsync(plan.Id, CancellationToken.None), "reçu antérieur conservé");
    }

    [Test]
    public static async Task Remote_plans_require_exact_stored_workstation_and_never_authorize_domain_controllers()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var plan = Plan(db);
        foreach (var invalid in new[] { plan with { StoreId = new('c', 64) }, plan with { ComputerGuid = Guid.NewGuid() },
            plan with { ComputerDn = "CN=Other," + Fixtures.Postes }, plan with { ComputerCreated = plan.ComputerCreated.AddDays(1) },
            plan with { Host = "other.test.local" }, plan with { Account = "" }, plan with { Nonce = "short" } })
        { await Check.ThrowsAsync<InvalidDataException>(() => db.PrepareTaskReadAsync(invalid, CancellationToken.None), "identité divergente ou plan invalide refusé"); }
        await new SqliteDirectoryCache(db).SaveObjectsAsync(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1") with { UserAccountControl = AdValues.ServerTrustAccount }]), null, CancellationToken.None);
        await Check.ThrowsAsync<InvalidDataException>(() => db.PrepareTaskReadAsync(plan, CancellationToken.None), "aucune tâche SYSTEM sur un DC");
        Check.Equal(0, (await db.PendingTaskReadsAsync(CancellationToken.None)).Length, "aucun plan accepté");
    }

    [Test]
    public static async Task Remote_journal_detects_corruption_and_oversized_receipts_before_recovery()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var plan = Plan(db); await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE domenia_v2_remote_reads SET plan_hash=?1;", new string('0', 64)); }
        await Check.ThrowsAsync<InvalidDataException>(() => db.PendingTaskReadsAsync(CancellationToken.None), "empreinte divergente refusée");
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            var json = (string)sql.Scalar("SELECT plan FROM domenia_v2_remote_reads;")!;
            sql.Execute("UPDATE domenia_v2_remote_reads SET plan_hash=?1,completion=?2,completion_hash=NULL;", Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(json))), new string('x', 20000));
        }
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadTaskReadAsync(plan.Id, CancellationToken.None), "reçu trop gros non assimilé à un reçu absent");
    }

    [Test]
    public static async Task Remote_journal_trigger_side_effects_roll_back_receipt_and_legacy_changes()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var plan = Plan(db); await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("INSERT INTO park_state(computer_key,computer,status) VALUES('legacy','PC1','SESSION');");
            sql.Script("CREATE TRIGGER unsafe_receipt AFTER UPDATE ON domenia_v2_remote_reads BEGIN DELETE FROM park_state; END;");
        }
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 1, new(Fixtures.Now, true, true, true, "Nettoyé."), CancellationToken.None), "effet secondaire refusé");
        Check.Null((await db.ReadTaskReadAsync(plan.Id, CancellationToken.None))!.Completion, "reçu annulé");
        using var after = new SqliteDatabase(db.Path, true);
        Check.Equal(1L, (long)after.Scalar("SELECT count(*) FROM park_state;")!, "ligne D1 restaurée");
    }

    [Test]
    public static async Task Reading_or_completing_unknown_remote_work_never_creates_a_database()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("absent.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        Check.Null(await cache.ReadTaskReadAsync(Guid.NewGuid(), CancellationToken.None), "aucun reçu");
        Check.Equal(0, (await cache.PendingTaskReadsAsync(CancellationToken.None)).Length, "aucune attente");
        await Check.ThrowsAsync<InvalidDataException>(() => cache.CompleteTaskReadAsync(Guid.NewGuid(), 1, new(Fixtures.Now, false, true, true, "Absent."), CancellationToken.None), "pas de préparation");
        Check.False(File.Exists(db.Path), "lecture et reçu sans création de fichier");
    }
}
