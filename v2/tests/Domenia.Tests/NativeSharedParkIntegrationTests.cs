using System.Text;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Real cache/reader/executor composition on local Windows fixtures, without LDAP or a real share.</summary>
internal static class NativeSharedParkIntegrationTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    private sealed class Setup : IDisposable
    {
        internal TemporaryFolder Folder { get; } = new();
        internal AdBoundaryTests.RecordingAdConnection Ldap { get; } = new();
        internal CompatibleDirectoryCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal AdSyncReader Reader { get; }
        internal AdSyncStoreExecutor Executor { get; }
        internal string Tsv => Folder.File("park.tsv");
        internal string Profile => Folder.File("profile");
        internal Setup()
        {
            Directory.CreateDirectory(Folder.File("app"));
            Configure(Tsv);
            Cache = new(Folder.File("app"), Profile, "test.local", TestClock.Fixed());
            Source = new("test.local", () => @"TEST\test", TestClock.Fixed(), connection: Ldap, localStore: Cache);
            Reader = new(Source); Executor = new(Source);
        }
        internal void Configure(string path) => File.WriteAllText(Folder.File("app/Domenia.config.json"),
            JsonSerializer.Serialize(new { ParkSweep = new { SharedPath = path } }));
        internal void Remote(string computer = "REMOTE1") => File.WriteAllText(Tsv,
            computer + "\t2026-10-20T10:00:00Z\tCONFIRME\tremote-user\t2\r\n", new UTF8Encoding(false));
        internal async Task Initialize() => await (await Cache.DatabaseAsync(None)).InitializeAsync(None);
        internal async Task<WritePlan> Plan(ParkSharedRead preview)
        {
            var draft = await Executor.PlanBatchAsync(preview.BatchId, None);
            var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
            Executor.Bind(draft, plan); return plan;
        }
        public void Dispose() { Source.Dispose(); Ldap.Dispose(); Folder.Dispose(); }
    }

    [Test]
    public static async Task Park_open_reads_only_local_configuration_even_when_the_shared_bytes_are_invalid()
    {
        using var setup = new Setup();
        File.WriteAllBytes(setup.Tsv, [0xff, 0xfe, 0xff]);
        var state = await setup.Reader.ParkAsync(None);
        Check.True(state.Shared.Configured, "chemin local reconnu sans interpréter le partage");
        Check.Equal(setup.Tsv, state.Shared.Path, "chemin affiché tel que qualifié");
        Check.False(Directory.Exists(setup.Profile), "aucune base ou spool à l’ouverture");
        Check.Equal(0, setup.Ldap.Calls, "aucune lecture AD implicite");
    }

    [Test]
    public static async Task Explicit_preview_does_not_publish_and_discard_prevents_a_later_plan()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var before = File.ReadAllBytes(setup.Tsv);
        var preview = await setup.Reader.ReadSharedParkAsync(None);
        Check.Equal(1, preview.Received, "ligne effectivement reçue");
        Check.Equal(1, preview.Added, "nouvelle observation externe");
        Check.False(preview.Locked, "aucun verrou de publication prétendu à la lecture");
        Check.Equal(0, (await setup.Reader.ParkAsync(None)).Rows.Length, "aperçu non appliqué au parc");
        Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "TSV inchangé");
        Check.True(setup.Reader.DiscardRead(preview.BatchId).Discarded, "lease libérée explicitement");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.PlanBatchAsync(preview.BatchId, None), "lot écarté inutilisable");
        Check.Equal(0, setup.Ldap.Calls, "le nom externe ne provoque aucune recherche AD");
    }

    [Test]
    public static async Task Planning_is_local_but_the_precheck_detects_a_replaced_shared_file()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var preview = await setup.Reader.ReadSharedParkAsync(None);
        setup.Remote("CONCURRENT");
        var plan = await setup.Plan(preview);
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "CAS des octets distants relu avant envoi");
        Check.Equal(0, (await setup.Reader.ParkAsync(None)).Rows.Length, "pas de mutation locale au contrôle");
        Check.Equal(0, setup.Ldap.Calls, "plan et contrôle sans LDAP");
    }

    [Test]
    public static async Task Source_reset_releases_the_preview_and_refuses_its_confirmed_plan()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var leases = SharedParkPreviewFile.ActiveLeases;
        var preview = await setup.Reader.ReadSharedParkAsync(None); var plan = await setup.Plan(preview);
        Check.Equal(leases + 1, SharedParkPreviewFile.ActiveLeases, "lease réellement créée");
        var before = File.ReadAllBytes(setup.Tsv);
        setup.Source.Reset();
        Check.Equal(leases, SharedParkPreviewFile.ActiveLeases, "reset ferme immédiatement la lease");
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "ancien contexte refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "pas de publication après déconnexion");
        Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "fichier conservé après refus");
    }

    [Test]
    public static async Task Changed_configuration_cannot_redirect_a_previously_confirmed_publication()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var plan = await setup.Plan(await setup.Reader.ReadSharedParkAsync(None));
        var other = setup.Folder.File("other.tsv"); setup.Configure(other);
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "chemin changé explicitement périmé");
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Executor.ExecuteAsync(plan, None), "aucune réorientation du plan");
        Check.False(File.Exists(other), "nouvelle destination jamais créée");
    }

    [Test]
    public static async Task Confirmed_publication_survives_its_own_epoch_change_and_is_verified_after_restart()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var plan = await setup.Plan(await setup.Reader.ReadSharedParkAsync(None));
        var epoch = setup.Source.Epoch;
        Check.True((await setup.Executor.CheckAsync(plan, None)).Current, "précontrôle réel positif");
        Check.Equal(WriteResult.Applied, (await setup.Executor.ExecuteAsync(plan, None)).Result, "publication et transaction réelles");
        Check.True(setup.Source.Epoch > epoch, "maintenance invalide les anciennes lectures");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "preuve durable relue");
        var shown = (await setup.Reader.ParkAsync(None)).Rows.Single();
        Check.Equal("REMOTE1", shown.Computer, "projection rechargée");
        Check.True(shown.ProbedBy?.Contains("non certifiée", StringComparison.Ordinal) == true, "origine externe visible");
        var stored = (await setup.Cache.ReadRelationSweepsAsync(None)).Rows.Single();
        Check.Null(stored.ComputerGuid, "aucun GUID inventé"); Check.Null(stored.ComputerDn, "aucun DN inventé");
        var later = TestClock.Fixed(Fixtures.Now.AddHours(1));
        var freshCache = new CompatibleDirectoryCache(setup.Folder.File("app"), setup.Profile, "test.local", later);
        using var restarted = new AdDirectorySource("test.local", () => @"TEST\test", later,
            connection: new AdBoundaryTests.RecordingAdConnection(), localStore: freshCache);
        Check.True(plan.ExpiresAt < later.GetUtcNow(), "plan réellement expiré aussi pour le nouveau Store");
        Check.Equal(VerificationState.Verified, (await new AdSyncStoreExecutor(restarted).VerifyAsync(plan, None)).State, "reçu vérifié sans plan mémoire après expiration");
        Check.False((await setup.Executor.CheckAsync(plan, None)).Current, "plan consommé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Executor.ExecuteAsync(plan, None), "pas de rejeu");
        Check.Equal(0, setup.Ldap.Calls, "publication locale et TSV sans écriture AD");
    }

    [Test]
    public static async Task Shared_park_uses_the_real_confirmation_circuit_and_keeps_a_single_verified_receipt()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var preview = await setup.Reader.ReadSharedParkAsync(None);
        var receipts = new MemoryReceiptStore();
        using var writers = WriteExecutors.From([setup.Executor]);
        using var circuit = new WriteCircuit(writers, receipts, setup.Source, new OperationJournal(), TestClock.Fixed(), new RecordingJournal(), AppMode.Directory);
        var planned = await circuit.PlanAsync(await setup.Executor.PlanBatchAsync(preview.BatchId, None), None);
        Check.Equal(0, receipts.Appends, "le plan ne fabrique aucun reçu d’envoi");
        var stages = new List<WriteStage>();
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, planned.Plan.Confirmation.TypedName,
            stage => { stages.Add(stage); if (stage == WriteStage.Sending) { Check.Equal(1, receipts.Appends, "reçu enregistré avant l’envoi"); } }, None);
        Check.Equal(WriteResult.Applied, receipt.Result, "circuit réellement appliqué");
        Check.Equal(VerificationState.Verified, receipt.Verification, "relecture réelle réussie");
        Check.Equal(3, receipts.Appends, "envoyé, achevé, vérifié");
        Check.True(stages.SequenceEqual([WriteStage.Checking, WriteStage.Sending, WriteStage.Verifying]), "ordre du circuit");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(planned.Plan.Id, planned.Token,
            planned.Plan.Confirmation.TypedName, null, None), "jeton jamais rejoué");
        Check.Equal(3, receipts.Appends, "aucun nouvel envoi");
        Check.Equal(0, setup.Ldap.Calls, "aucun AD derrière le geste de publication TSV");
    }

    [Test]
    public static async Task Qualified_maintenance_validates_the_reserved_generation_without_deadlocking_its_own_load_gate()
    {
        using var setup = new Setup(); await setup.Initialize();
        var origin = WritePlanOrigin.From(await setup.Source.GetSessionAsync(None));
        var called = 0;
        var result = await setup.Source.RunQualifiedLocalMaintenanceAsync(origin, (validate, _) =>
        { validate(); called++; validate(); return Task.FromResult(42); }, None);
        Check.Equal(42, result, "mutation terminée"); Check.Equal(1, called, "un seul envoi");
        await Check.ThrowsAsync<DomeniaOperationException>(() => setup.Source.RunQualifiedLocalMaintenanceAsync(origin,
            (_, _) => { called++; return Task.FromResult(0); }, None), "origine ancienne refusée avant délégué");
        Check.Equal(1, called, "aucune mutation périmée");
    }

    [Test]
    public static async Task A_concurrent_overview_purge_cannot_discard_the_preview_transferred_to_maintenance()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var preview = await setup.Reader.ReadSharedParkAsync(None); var plan = await setup.Plan(preview);
        var epoch = setup.Source.Epoch; var leases = SharedParkPreviewFile.ActiveLeases; var reached = false;
        setup.Executor.SharedParkMaintenanceReserved = () =>
        {
            reached = true; Check.True(setup.Source.Epoch > epoch, "époque de maintenance réellement réservée");
            var state = AdSyncState.For(setup.Source);
            lock (state.Gate) { state.Purge(); }
            Check.Null(state.FindShared(preview.BatchId), "référence compacte transférée hors des aperçus à purger");
            Check.Equal(leases, SharedParkPreviewFile.ActiveLeases, "la purge d’overview conserve la lease détenue par l’exécuteur");
        };
        Check.Equal(WriteResult.Applied, (await setup.Executor.ExecuteAsync(plan, None)).Result, "publication réelle après interleaving");
        Check.True(reached, "frontière réservée réellement atteinte");
        Check.Equal(leases - 1, SharedParkPreviewFile.ActiveLeases, "seul l’exécuteur rend finalement la lease");
        Check.Equal(VerificationState.Verified, (await setup.Executor.VerifyAsync(plan, None)).State, "deux ressources et reçu confirmés");
    }

    [Test]
    public static async Task Reset_does_not_let_eight_old_plans_occupy_the_new_sessions_capacity()
    {
        using var setup = new Setup(); await setup.Initialize(); setup.Remote();
        var first = await setup.Reader.ReadSharedParkAsync(None);
        for (var i = 0; i < 8; i++) { await setup.Plan(first); }
        setup.Source.Reset();
        var current = await setup.Reader.ReadSharedParkAsync(None); var plan = await setup.Plan(current);
        Check.True((await setup.Executor.CheckAsync(plan, None)).Current, "nouvelle session admise malgré huit anciens plans non expirés");
    }

    [Test]
    public static async Task Historical_and_case_variant_shared_rows_keep_their_uncertified_origin_badge()
    {
        using var setup = new Setup(); await setup.Initialize();
        using (var db = new SqliteDatabase((await setup.Cache.DatabaseAsync(None)).Path, false))
        {
            db.Script("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES"
                + "('SHARED:UPPER','UPPER','2026-10-20T10:00:00Z','CONFIRME',NULL,1),"
                + "('old-key','LEGACY','2026-10-20T10:00:00Z','partage_SESSION',NULL,1),"
                + "('native:TIE','TIE','2026-10-20T10:00:00Z','SESSION','native-user',1),"
                + "('SHARED:TIE','TIE','2026-10-20T10:00:00Z','PARTAGE_CONFIRME','shared-user',1);");
        }
        var park = await setup.Reader.ParkAsync(None);
        Check.Equal(3, park.Rows.Length, "trois noms affichés avec égalité départagée");
        foreach (var name in new[] { "UPPER", "LEGACY" })
        { Check.Contains("non certifiée", park.Rows.Single(r => r.Computer == name).ProbedBy, "origine externe visible indépendamment de la clé historique"); }
        Check.Null(park.Rows.Single(r => r.Computer == "TIE").ProbedBy, "à égalité la ligne native est conservée");
        Check.Equal(0, setup.Ldap.Calls, "aucune résolution AD déduite des noms");
    }
}
