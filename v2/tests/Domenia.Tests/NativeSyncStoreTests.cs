using System.Collections.Immutable;
using System.Security.Cryptography;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeSyncStoreTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static SyncScope Domain => new(Fixtures.Root, "Domaine", "Domaine", true, true, "Test explicite");

    [Test]
    public static async Task Native_sync_and_settings_discover_real_wrapper_without_creating_a_cold_store()
    {
        using var setup = new Setup();
        using var writers = WriteExecutors.Discover(setup.Source, [typeof(AdSyncStoreExecutor).Assembly]);
        Check.True(writers.Find<ISyncStoreExecutor>() is AdSyncStoreExecutor, "exécuteur natif découvert");
        var local = await setup.Cache.ReadSyncStateAsync(None);
        var settings = await new AdSettingsReader(setup.Source).LocalStoreAsync(None);
        var plan = await setup.Executor.PlanSnapshotCaptureAsync("Avant création", Domain, None);
        Check.False(local.Available, "base absente signalée");
        Check.False(settings.Available, "inspection absente");
        Check.True(plan.Target.Dn.Contains(local.StoreId, StringComparison.Ordinal), "identité liée au véritable wrapper");
        Check.False(Directory.Exists(setup.User), "aucun dossier créé par lecture ou plan");
        Check.Equal(0, setup.Ldap.Calls, "aucun LDAP implicite");
    }

    [Test]
    public static async Task Snapshot_commit_is_backed_up_verified_and_recoverable_from_a_new_executor()
    {
        using var setup = new Setup();
        var plan = await setup.PlanCapture("État initial");
        Check.True((await setup.Executor.CheckAsync(plan, None)).Current, "plan courant sur base absente");
        Check.Equal(WriteResult.Applied, (await setup.Executor.ExecuteAsync(plan, None)).Result, "transaction enregistrée");
        var database = await setup.Cache.DatabaseAsync(None);
        var state = await setup.Cache.ReadSyncStateAsync(None);
        Check.Equal(1L, state.Revision, "une révision");
        Check.Equal(1, state.Snapshots.Length, "un relevé");
        Check.Equal(1, state.Receipts.Length, "un reçu");
        var backup = (await database.InspectAsync(None))!.Backup!;
        using (var stream = File.OpenRead(backup.Path)) { Check.Equal(backup.Sha256, Convert.ToHexStringLower(SHA256.HashData(stream)), "sauvegarde vérifiable"); }
        using (var saved = new SqliteDatabase(backup.Path, true)) { Check.Equal(0L, (long)saved.Scalar("SELECT count(*) FROM ad_snapshots;")!, "copie antérieure"); }
        using var restarted = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(Fixtures.Now.AddHours(1)), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: setup.Cache);
        Check.Equal(VerificationState.Verified, (await new AdSyncStoreExecutor(restarted).VerifyAsync(plan, None)).State, "relecture après expiration et redémarrage sans lot mémoire");
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "pas de rejeu du plan consommé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "second envoi refusé");
        Check.Equal(1L, (await setup.Cache.ReadSyncStateAsync(None)).Revision, "aucune nouvelle mutation");
    }

    [Test]
    public static async Task Two_reviewed_plans_cannot_overwrite_each_other()
    {
        using var setup = new Setup();
        var first = await setup.PlanCapture("Premier");
        var second = await setup.PlanCapture("Concurrent");
        await setup.Executor.ExecuteAsync(first, None);
        Check.False((await setup.Executor.CheckAsync(second, None)).Current, "CAS refuse la révision périmée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(second, None), "révision revérifiée à l’envoi");
        Check.Equal("Premier", (await setup.Cache.ReadSyncStateAsync(None)).Snapshots.Single().Label, "premier relevé conservé");
    }

    [Test]
    public static async Task Partial_batch_never_replaces_complete_coverage_or_manufactures_disappearances()
    {
        using var setup = new Setup();
        var row = Row("PC1");
        await setup.StoreBatch([row], new("directory", Fixtures.Root, Fixtures.Now, "Subtree", false, 1, "DC01", 0, null, null, 0));
        await setup.StoreBatch([], new("attempt:directory", Fixtures.Root, Fixtures.Now.AddSeconds(1), "Subtree", true, 0, "DC01", 0, null, "time", 30_000));
        var state = await setup.Cache.ReadSyncStateAsync(None);
        Check.Equal(row.ObjectGuid, state.Rows.Single().ObjectGuid, "objet non revu conservé");
        Check.Equal(2, state.Scopes.Length, "tentative distincte du repère complet");
        Check.False(state.Scopes.Single(x => x.Key == "directory").Partial, "repère complet intact");
        Check.True(state.Scopes.Single(x => x.Key == "attempt:directory").Partial, "tentative explicitement partielle");
        Check.Equal("time", state.Scopes.Single(x => x.Key == "attempt:directory").CutReason, "cause conservée");
        Check.Equal(0, state.Absences.Length, "aucune disparition déduite");
    }

    [Test]
    public static async Task Batch_preview_refuses_a_changed_store_before_issuing_a_new_plan()
    {
        using var setup = new Setup();
        var batch = await setup.Hold([Row("PC1")], null);
        await setup.Executor.ExecuteAsync(await setup.PlanCapture("Concurrence"), None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.PlanBatchAsync(batch.Id, None), "ancien aperçu refusé");
    }

    [Test]
    public static async Task Park_reset_preserves_sessions_and_associations_and_rejects_late_sweeps()
    {
        using var setup = new Setup();
        var database = await setup.Cache.DatabaseAsync(None);
        await database.InitializeAsync(None);
        var update = new RelationSweepUpdate(Guid.NewGuid(), "CN=PC1," + Fixtures.Postes, "PC1", Fixtures.Now, "empty", null);
        await setup.Cache.ApplyRelationSweepsAsync(new(database.StoreId, WritePlans.NewId(), 0, [update]), None);
        using (var db = new SqliteDatabase(database.Path, false))
        { db.Execute("INSERT INTO park_session_cache(object_key,checked_utc,payload) VALUES('preserved',?1,'{}');", Fixtures.Now.ToString("O")); }
        var draft = await setup.Executor.PlanParkResetAsync(None);
        var plan = setup.Seal(draft);
        await setup.Executor.ExecuteAsync(plan, None);
        var park = await setup.Cache.ReadRelationSweepsAsync(None);
        Check.Equal(0L, park.Total, "parc vidé");
        Check.Equal(1L, park.Generation, "barrière des anciens passages");
        using (var db = new SqliteDatabase(database.Path, true))
        { Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM park_session_cache;")!, "cache session préservé"); }
        Check.False((await setup.Cache.CheckRelationSweepsAsync(new(database.StoreId, WritePlans.NewId(), 0, [update]), None)).Current, "passage antérieur refusé");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "effacement relu");
    }

    [Test]
    public static async Task Snapshot_deletion_is_a_new_sealed_transaction()
    {
        using var setup = new Setup();
        await setup.Executor.ExecuteAsync(await setup.PlanCapture("À conserver en sauvegarde"), None);
        var id = (await setup.Cache.ReadSyncStateAsync(None)).Snapshots.Single().Id;
        var plan = setup.Seal(await setup.Executor.PlanSnapshotDeleteAsync(id, None));
        await setup.Executor.ExecuteAsync(plan, None);
        Check.Equal(0, (await setup.Cache.ReadSyncStateAsync(None)).Snapshots.Length, "relevé effacé");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "suppression relue");
        var backup = (await (await setup.Cache.DatabaseAsync(None)).InspectAsync(None))!.Backup!;
        using var saved = new SqliteDatabase(backup.Path, true);
        Check.Equal(1L, (long)saved.Scalar("SELECT count(*) FROM ad_snapshots;")!, "relevé récupérable dans sauvegarde");
    }

    [Test]
    public static async Task Corrupt_commit_proof_never_claims_success_and_never_replays()
    {
        using var setup = new Setup();
        var plan = await setup.PlanCapture("Contrôle");
        await setup.Executor.ExecuteAsync(plan, None);
        var database = await setup.Cache.DatabaseAsync(None);
        using (var db = new SqliteDatabase(database.Path, false)) { db.Execute("UPDATE domenia_v2_sync_proofs SET payload='{}' WHERE plan_id=?1;", plan.Id); }
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Executor.VerifyAsync(plan, None), "corruption signalée");
        Check.Equal(1L, (await setup.Cache.ReadSyncStateAsync(None)).Revision, "aucun rejeu");
    }

    [Test]
    public static async Task Foreign_store_refuses_a_valid_plan_from_another_location()
    {
        using var first = new Setup();
        using var second = new Setup();
        var plan = await first.PlanCapture("Base A");
        await Check.ThrowsAsync<InvalidDataException>(() => second.Executor.VerifyAsync(plan, None), "autre emplacement refusé");
        Check.False(Directory.Exists(second.User), "aucune création étrangère");
    }

    [Test]
    public static async Task Unqualified_trigger_is_refused_before_any_sync_mutation()
    {
        using var setup = new Setup();
        var database = await setup.Cache.DatabaseAsync(None);
        await database.InitializeAsync(None);
        using (var db = new SqliteDatabase(database.Path, false))
        { db.Script("CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES('conserver'); CREATE TRIGGER hidden_effect AFTER INSERT ON ad_snapshots BEGIN DELETE FROM sentinel; END;"); }
        var plan = await setup.PlanCapture("Déclencheur");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "déclencheur inconnu refusé");
        using var read = new SqliteDatabase(database.Path, true);
        Check.Equal("conserver", read.Scalar("SELECT value FROM sentinel;") as string, "donnée étrangère intacte");
        Check.Equal(0L, (long)read.Scalar("SELECT count(*) FROM ad_snapshots;")!, "transaction sans mutation");
    }

    private static IndexRecord Row(string name) => new(Guid.NewGuid(), IndexObjectType.Computer, name, name + "$", name + ".test.local", null, null, "Windows", true,
        "CN=" + name + "," + Fixtures.Postes, Fixtures.Now, 12, null, LapsKind.None, null, Fixtures.Now);

    private sealed class Setup : IDisposable
    {
        private readonly TemporaryFolder folder = new();
        internal string User { get; }
        internal AdBoundaryTests.RecordingAdConnection Ldap { get; } = new();
        internal CompatibleDirectoryCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal AdSyncStoreExecutor Executor { get; }
        internal Setup()
        {
            User = folder.File("profile");
            Cache = new(folder.File("app"), User, "test.local", TestClock.Fixed());
            Source = new("test.local", () => "test", TestClock.Fixed(), connection: Ldap, localStore: Cache);
            Executor = new(Source);
        }
        internal WritePlan Seal(WritePlanDraft draft)
        {
            var plan = WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
            Executor.Bind(draft, plan); return plan;
        }
        internal async Task<WritePlan> PlanCapture(string label) => Seal(await Executor.PlanSnapshotCaptureAsync(label, Domain, None));
        internal async Task<AdSyncBatch> Hold(ImmutableArray<IndexRecord> rows, SyncStateEntry? coverage)
        {
            var local = await Cache.ReadSyncStateAsync(None);
            var batch = new AdSyncBatch(WritePlans.NewId(), "Lecture explicite", Source.Epoch, Fixtures.Now, Fixtures.Now.AddMinutes(15), rows, coverage, [], []).AtBase(local);
            AdSyncState.For(Source).Hold(batch); return batch;
        }
        internal async Task StoreBatch(ImmutableArray<IndexRecord> rows, SyncStateEntry? coverage)
        {
            var batch = await Hold(rows, coverage);
            var plan = Seal(await Executor.PlanBatchAsync(batch.Id, None));
            await Executor.ExecuteAsync(plan, None);
        }
        public void Dispose() { Source.Dispose(); Ldap.Dispose(); folder.Dispose(); }
    }
}
