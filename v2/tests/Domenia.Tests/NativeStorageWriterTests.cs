using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageWriterTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Disk_failure_retains_real_collected_payload_until_explicit_verified_resume()
    {
        using var setup = new Setup(); await setup.Initialize();
        setup.Database.FreeSpaceProbe = () => 1;
        await Check.ThrowsAsync<IOException>(() => setup.Database.SaveFleetAsync(setup.Patch, None), "réserve disque avant envoi");
        var failed = await setup.Reader.LocalStoreAsync(None);
        Check.True(failed.Writer.Suspended, "suspension immédiate sur manque d’espace");
        Check.Equal(1, failed.Writer.Pending, "lot réel retenu");
        Check.True(failed.Writer.QueuedBytes > 0, "octets sérialisés mesurés");
        Check.Equal(1, failed.Writer.Failures, "échec réellement compté");
        Check.Equal(1L, failed.Space.FreeBytes, "mesure disque conservée");
        Check.Equal(0, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Length, "aucune écriture prématurée");
        setup.Database.FreeSpaceProbe = () => long.MaxValue;
        var plan = await setup.Plan(); await setup.Executor.ExecuteAsync(plan, None);
        var after = await setup.Reader.LocalStoreAsync(None);
        Check.False(after.Writer.Suspended, "écrivain réarmé"); Check.Equal(0, after.Writer.Pending, "file vidée après commit");
        Check.Equal(1, setup.Source.FleetDetails.Observations.Workstations.Length, "cache relu après reprise");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "preuve durable de reprise");
        var reopened = new CompatibleDirectoryCache(setup.App, setup.User, "test.local", TestClock.Fixed(Fixtures.Now.AddDays(1)));
        Check.Equal(VerificationState.Verified, (await reopened.VerifyWriterResumeAsync(plan, None)).State, "preuve après redémarrage et expiration");
    }

    [Test]
    public static async Task Resume_refuses_D1_change_without_revision_and_keeps_the_collected_payload()
    {
        using var setup = new Setup(); await setup.Initialize();
        setup.Database.FreeSpaceProbe = () => 1;
        await Check.ThrowsAsync<IOException>(() => setup.Database.SaveFleetAsync(setup.Patch, None), "collecte retenue");
        setup.Database.FreeSpaceProbe = () => long.MaxValue;
        var plan = await setup.Plan();
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Execute("INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('concurrent','alice','Saisie manuelle');"); }
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "mutation D1 détectée sans révision");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "aucun écrasement de l’écriture concurrente");
        Check.Equal(1, (await setup.Reader.LocalStoreAsync(None)).Writer.Pending, "lot conservé pour examen");
        Check.Equal(0, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Length, "lot non rejoué");
    }

    [Test]
    public static async Task Three_failed_operator_plans_suspend_but_are_never_retained_for_replay()
    {
        using var setup = new Setup(); await setup.Initialize();
        var snapshot = await setup.Reader.LocalStoreAsync(None);
        var preview = LocalStoreRules.PurgePlan(snapshot, ["index"], 730, Fixtures.Now, TimeZoneInfo.Utc);
        var purge = new AdStoragePurgeExecutor(setup.Source);
        var plan = WritePlans.Seal(await purge.PlanPurgeAsync(["index"], 730, preview.Fingerprint, None), WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        setup.Database.FreeSpaceProbe = () => throw new IOException("Volume temporairement inaccessible.");
        for (var attempt = 0; attempt < 3; attempt++)
        { await Check.ThrowsAsync<IOException>(() => purge.ExecuteAsync(plan, None), "défaut du volume"); }
        var failed = await setup.Reader.LocalStoreAsync(None);
        Check.True(failed.Writer.Suspended, "trois échecs suspendent"); Check.Equal(3, failed.Writer.Failures, "trois échecs réels");
        Check.Equal(0, failed.Writer.Pending, "aucun plan opérateur retenu");
        setup.Database.FreeSpaceProbe = () => long.MaxValue;
        var resume = await setup.Plan(); await setup.Executor.ExecuteAsync(resume, None);
        using var db = new SqliteDatabase(setup.Database.Path, true);
        Check.Equal(1L, (long)db.Scalar("SELECT count(*) FROM ad_objects;")!, "purge jamais rejouée par reprise de l’écrivain");
    }

    [Test]
    public static async Task Cancelling_a_waiting_save_removes_its_actual_queue_counters_without_failure()
    {
        using var setup = new Setup(); await setup.Initialize();
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        setup.Database.FreeSpaceProbe = () => { entered.Set(); if (!release.Wait(TimeSpan.FromSeconds(10))) { throw new TimeoutException("Contrôle de test non libéré."); } return long.MaxValue; };
        var active = Task.Run(() => setup.Database.SaveFleetAsync(setup.Patch, None));
        try
        {
            Check.True(await Task.Run(() => entered.Wait(TimeSpan.FromSeconds(5))), "premier lot actif");
            using var cancel = new CancellationTokenSource();
            var waiting = setup.Database.SaveFleetAsync(setup.Patch, cancel.Token);
            var snapshot = await setup.Reader.LocalStoreAsync(None);
            Check.True(snapshot.Writer.Active, "écriture observée active"); Check.Equal(1, snapshot.Writer.Pending, "seul second lot attend");
            Check.True(snapshot.Writer.QueuedBytes > 0, "taille réelle du lot en attente");
            cancel.Cancel(); await Check.ThrowsAsync<OperationCanceledException>(() => waiting, "annulation du seul lot en attente");
            Check.Equal(0, (await setup.Reader.LocalStoreAsync(None)).Writer.Pending, "compteurs retirés après annulation");
        }
        finally { release.Set(); }
        await active;
        Check.Equal(0, (await setup.Reader.LocalStoreAsync(None)).Writer.Failures, "annulation jamais comptée en faute");
    }

    [Test]
    public static async Task Free_space_is_checked_again_at_commit_and_failure_rolls_back_the_collected_rows()
    {
        using var setup = new Setup(); await setup.Initialize();
        var checks = 0; setup.Database.FreeSpaceProbe = () => ++checks >= 3 ? 1 : long.MaxValue;
        await Check.ThrowsAsync<IOException>(() => setup.Database.SaveFleetAsync(setup.Patch, None), "réserve perdue avant commit");
        Check.True(checks >= 3, "espace contrôlé à l’envoi puis à la validation");
        Check.Equal(0, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Length, "transaction annulée");
        Check.Equal(1, (await setup.Reader.LocalStoreAsync(None)).Writer.Pending, "lot non perdu après rollback");
    }

    [Test]
    public static async Task Explicit_retry_checks_CAS_inside_BEGIN_IMMEDIATE_after_its_last_disk_measure()
    {
        using var setup = new Setup(); await setup.Initialize();
        setup.Database.FreeSpaceProbe = () => 1;
        await Check.ThrowsAsync<IOException>(() => setup.Database.SaveFleetAsync(setup.Patch, None), "collecte retenue");
        setup.Database.FreeSpaceProbe = () => long.MaxValue;
        var plan = await setup.Plan(); var checks = 0;
        setup.Database.FreeSpaceProbe = () =>
        {
            if (++checks == 2)
            {
                using var concurrent = new SqliteDatabase(setup.Database.Path, false);
                concurrent.Execute("INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('race','bob','Saisie manuelle');");
            }
            return long.MaxValue;
        };
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "CAS après la dernière mesure disque");
        Check.Equal(0, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Length, "aucune collecte écrasant la course");
        Check.Equal(1, (await setup.Reader.LocalStoreAsync(None)).Writer.Pending, "lot conservé après conflit");
    }

    [Test]
    public static async Task First_failed_collection_offers_explicit_resume_without_promising_automatic_retry()
    {
        using var setup = new Setup(); await setup.Initialize();
        setup.Database.FreeSpaceProbe = () => throw new IOException("Volume momentanément indisponible.");
        await Check.ThrowsAsync<IOException>(() => setup.Database.SaveFleetAsync(setup.Patch, None), "premier défaut avant envoi");
        var snapshot = await setup.Reader.LocalStoreAsync(None);
        Check.False(snapshot.Writer.Suspended, "pas encore trois échecs");
        var view = LocalStoreRules.Writer(snapshot.Writer, Fixtures.Now);
        Check.True(view.CanResume, "file retenue reprise explicitement dès le premier échec");
        Check.False(view.Text.Contains("nouvel essai prévu", StringComparison.Ordinal), "aucune promesse de relance automatique");
        setup.Database.FreeSpaceProbe = () => long.MaxValue;
        var plan = await setup.Plan(); await setup.Executor.ExecuteAsync(plan, None);
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "première reprise confirmée");
    }

    [Test]
    public static async Task A_large_unrelated_history_does_not_force_a_full_snapshot_on_each_collection()
    {
        using var setup = new Setup(); await setup.Initialize();
        using (var db = new SqliteDatabase(setup.Database.Path, false))
        { db.Execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<300001) INSERT INTO operation_runs(operation) SELECT 'ancienne' FROM n;"); }
        await setup.Database.SaveFleetAsync(setup.Patch, None);
        Check.Equal(1, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Length, "collecte normale indépendante d’un historique trop grand pour la reprise mémoire");
    }

    [Test]
    public static async Task Unqualified_row_identity_never_loops_or_becomes_a_replayable_snapshot()
    {
        foreach (var create in new[] { "CREATE TABLE writer_shadow(rowid INTEGER PRIMARY KEY,value TEXT);", "CREATE TABLE writer_without(key TEXT PRIMARY KEY) WITHOUT ROWID;" })
        {
            using var setup = new Setup(); await setup.Initialize();
            using (var db = new SqliteDatabase(setup.Database.Path, false)) { db.Execute(create); }
            setup.Database.FreeSpaceProbe = () => 1;
            await Check.ThrowsAsync<IOException>(() => setup.Database.SaveFleetAsync(setup.Patch, None), "lot gardé sans identité de base qualifiée");
            Check.Equal(1, (await setup.Reader.LocalStoreAsync(None)).Writer.Pending, "données conservées pour examen");
            setup.Database.FreeSpaceProbe = () => long.MaxValue;
            var plan = await setup.Plan();
            Check.True(plan.Summary.Contains("examen", StringComparison.Ordinal), "sort du lot explicitement annoncé");
            await setup.Executor.ExecuteAsync(plan, None);
            var rearmed = await setup.Reader.LocalStoreAsync(None);
            Check.False(rearmed.Writer.Suspended, "réarmement possible sans comparer un schéma non qualifié");
            Check.Equal(1, rearmed.Writer.Pending, "lot toujours conservé, jamais abandonné implicitement");
            Check.Equal(0, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Length, "aucun rejeu du lot non qualifié");
            Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "preuve du réarmement seul");
        }
    }

    [Test]
    public static async Task An_ambiguous_send_can_rearm_without_replaying_or_discarding_its_collected_payload()
    {
        using var setup = new Setup(); await setup.Initialize();
        var checks = 0; setup.Database.FreeSpaceProbe = () => ++checks >= 3 ? 1 : long.MaxValue;
        await Check.ThrowsAsync<IOException>(() => setup.Database.SaveFleetAsync(setup.Patch, None), "envoi interrompu avant sa confirmation");
        setup.Database.FreeSpaceProbe = () => long.MaxValue;
        var plan = await setup.Plan();
        Check.True(plan.Summary.Contains("1 lot restera en mémoire pour examen", StringComparison.Ordinal), "conséquence exacte annoncée");
        await setup.Executor.ExecuteAsync(plan, None);
        var held = await setup.Reader.LocalStoreAsync(None);
        Check.False(held.Writer.Suspended, "nouveaux enregistrements admis"); Check.Equal(1, held.Writer.Pending, "ancien contenu conservé");
        Check.Equal(0, (await setup.Cache.ReadFleetAsync(None)).Observations.Workstations.Length, "lot ambigu jamais rejoué");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "preuve précise du réarmement sans rejeu");
        await setup.Database.SaveFleetAsync(setup.Patch, None);
        var after = await setup.Reader.LocalStoreAsync(None);
        Check.Equal(1, after.Writer.Pending, "nouvelle sauvegarde ne jette pas le lot pour examen");
        Check.True(after.Writer.Fault?.Contains("examen", StringComparison.Ordinal) == true, "avertissement visible malgré nouvel enregistrement réussi");
    }

    private sealed class Setup : IDisposable
    {
        private TemporaryFolder Folder { get; } = new();
        internal string App { get; }
        internal string User { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal AdStorageWriterResumeExecutor Executor { get; }
        internal AdSettingsReader Reader { get; }
        internal DomeniaDatabase Database { get; private set; } = null!;
        internal FleetCachePatch Patch => FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(Fixtures.Computer("PC1"))]) };
        internal Setup()
        {
            App = Folder.File("app"); User = Folder.File("profile"); Cache = new(App, User, "test.local", TestClock.Fixed());
            Source = new("test.local", () => "test", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: Cache);
            Executor = new(Source); Reader = new(Source);
        }
        internal async Task Initialize()
        {
            Database = await Cache.DatabaseAsync(None); await Database.InitializeAsync(None);
            await Database.SaveDirectoryAsync(WritePlans.NewId(), Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]), new(Fixtures.Postes, "Postes", true), "DC01", None);
        }
        internal async Task<WritePlan> Plan() => WritePlans.Seal(await Executor.PlanWriterResumeAsync(None), WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        public void Dispose() { Source.Dispose(); Folder.Dispose(); }
    }
}
