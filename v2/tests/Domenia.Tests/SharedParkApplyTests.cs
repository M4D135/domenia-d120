using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Confirmed Store protocol on Windows local SQLite/TSV fixtures only. No real AD/SMB; final VM suites run separately.</summary>
internal static class SharedParkApplyTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    private sealed class Setup : IDisposable
    {
        internal TemporaryFolder Folder { get; } = new();
        internal DomeniaDatabase Db { get; }
        internal string Tsv => Folder.File("park.tsv");
        internal string Backups => Folder.File("backups");
        internal string Journal => Folder.File("intentions");
        internal SharedParkPreparedPreview Preview { get; private set; } = null!;
        internal WritePlan Plan { get; private set; } = null!;
        internal int SourceChecks;
        /// <summary>The very clock this <see cref="DomeniaDatabase"/> reads: advancing it is the only way a test can make real time pass
        /// for the protocol, instead of handing it a value the production code never consults.</summary>
        internal FixedTimeProvider Clock { get; }
        private Setup() { Clock = TestClock.Fixed(); Db = new(Folder.File("store.db"), Fixtures.Root, Clock); }

        internal static async Task<Setup> Create(bool tsvExists = true, bool native = true, bool legacy = false, Action<Setup>? beforePreview = null)
        {
            var setup = new Setup();
            try
            {
                if (native)
                {
                    await setup.Db.InitializeAsync(None);
                    using var db = new SqliteDatabase(setup.Db.Path, false);
                    db.Script("ALTER TABLE park_state ADD COLUMN computer_guid TEXT; ALTER TABLE park_state ADD COLUMN computer_dn TEXT;"
                        + "CREATE TABLE domenia_v2_sweep_state(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL CHECK(generation>=0)); INSERT INTO domenia_v2_sweep_state VALUES(1,4);");
                    var pc = Fixtures.Computer("PC1");
                    db.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts,computer_guid,computer_dn) VALUES('native-PC1','PC1','2026-10-20T09:00:00Z','SESSION','local-user',3,?1,?2);",
                        pc.ObjectGuid.ToString("D"), pc.DistinguishedName);
                    if (legacy) { db.Execute("DROP TABLE domenia_store_state;"); }
                }
                if (tsvExists) { File.WriteAllBytes(setup.Tsv, Bytes("PC1", "10:00:00", "remote-user")); }
                var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
                using (var user = WindowsIdentity.GetCurrent())
                {
                    foreach (var sid in new[] { user.User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }.DistinctBy(s => s.Value))
                    { security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
                }
                new DirectoryInfo(setup.Backups).Create(security);
                beforePreview?.Invoke(setup);
                setup.Preview = await setup.Db.PreviewSharedParkAsync(setup.Tsv, [], [], setup.Folder.File("preview"), WritePlans.NewId(), 7, None);
                var draft = setup.Db.DraftSharedPark(setup.Preview, new WritePlanOrigin(7, "fixture-source-session"));
                setup.Plan = WritePlans.Seal(draft, WritePlans.NewId(), "test-operator", AppMode.Directory, TestClock.Reference, TimeZoneInfo.Utc);
                return setup;
            }
            catch { setup.Dispose(); throw; }
        }

        internal async Task<WriteOutcome> Apply(Action<SharedParkApplyStage>? checkpoint = null, CancellationToken token = default, Action? sourceCheck = null)
        {
            Exception? failure = null;
            var outcome = await Db.ApplySharedParkConfirmedAsync(Preview, Plan, Backups, Journal, [], [],
                sourceCheck ?? (() => SourceChecks++), token, checkpoint, error => failure = error);
            if (failure is not null)
            {
                Console.WriteLine("DIAG SharedParkApply " + Plan.Id + ": " + failure.GetType().Name + " / " + failure.Message
                    + " / HRESULT " + failure.HResult.ToString("x8") + (failure.InnerException is null ? "" : " / " + failure.InnerException.Message));
                if (failure.Data["SharedPark.InitialDacl"] is string expected && failure.Data["SharedPark.PublishedDacl"] is string actual)
                { Console.WriteLine("DIAG SharedParkApply " + Plan.Id + " DACL initial=" + expected + " published=" + actual); }
            }
            return outcome;
        }
        internal Task<WriteVerification> Verify(DomeniaDatabase? restart = null) => (restart ?? Db).VerifySharedParkConfirmedAsync(Plan, Backups, Journal, [], [], None);
        internal SharedParkIntent? Intent() => new SharedParkIntentJournal(Journal, Db.StoreId, Db.DomainDn, TestClock.Fixed()).Read(Plan.Id, Plan.Fingerprint, None);
        internal string Displaced => Tsv + ".domenia-" + Plan.Id + ".evidence\\previous.tsv";
        internal string CorruptibleIntentFile() => Directory.EnumerateFiles(Journal).Single(path => path.EndsWith(".sharedparkintent", StringComparison.Ordinal));
        public void Dispose() { Preview?.Dispose(); Folder.Dispose(); }
    }

    private static byte[] Bytes(string computer, string time, string user)
        => Encoding.UTF8.GetBytes(computer + "\t2026-10-20T" + time + "Z\tCONFIRME\t" + user + "\t9\r\n");

    [Test]
    public static async Task A_confirmed_publication_preserves_native_identity_and_commits_only_external_observations()
    {
        using var setup = await Setup.Create();
        var before = await setup.Db.ReadSharedParkLocalAsync(None); var initialBytes = File.ReadAllBytes(setup.Tsv);
        var outcome = await setup.Apply();
        Check.Equal(WriteResult.Applied, outcome.Result, "publication et commit relus");
        Check.True(setup.SourceChecks >= 5, "le contexte réel doit être requalifié aux transitions");
        var after = await setup.Db.ReadSharedParkLocalAsync(None);
        var native = after.Sweeps.Rows.Single(r => r.StorageKey == "native-PC1");
        Check.Equal(before.Sweeps.Rows.Single().StorageFingerprint, native.StorageFingerprint, "tous les champs de la ligne native sont préservés");
        var external = after.Sweeps.Rows.Single(r => r.StorageKey == "shared:PC1");
        Check.Null(external.ComputerGuid, "aucun GUID déduit du nom TSV"); Check.Null(external.ComputerDn, "aucun DN déduit du nom TSV");
        Check.Equal("PARTAGE_CONFIRME", external.Status, "préfixe d’observation externe unique");
        Check.Equal("remote-user", external.UserLogin, "valeur distante réellement reçue");
        Check.Equal(9, external.Attempts, "compteur distant conservé sans incrément inventé");
        Check.Equal(4L, after.Generation, "reset generation préservée"); Check.Equal(before.Revision + 1, after.Revision, "une transaction avec reçu");
        Check.NotNull(setup.Intent(), "intention durable relue");
        Check.True(initialBytes.SequenceEqual(File.ReadAllBytes(setup.Displaced)), "fichier effectivement déplacé conservé");
        Check.Equal(setup.Preview.Reference.ProposedSha256, SharedParkFile.Hash(File.ReadAllBytes(setup.Tsv)), "publication exacte du spool confirmé");
        Check.Equal(VerificationState.Verified, (await setup.Verify()).State, "les deux ressources et le reçu sont relus");
    }

    [Test]
    public static async Task Verification_after_restart_and_expiration_uses_the_durable_receipt()
    {
        using var setup = await Setup.Create(); Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "premier envoi réellement validé");
        setup.Preview.Dispose();
        var restarted = new DomeniaDatabase(setup.Db.Path, Fixtures.Root, TestClock.Fixed(TestClock.Reference.AddHours(1)));
        Check.Equal(VerificationState.Verified, (await setup.Verify(restarted)).State, "aucun spool ou plan en mémoire nécessaire après expiration");
    }

    [Test]
    public static async Task A_missing_TSV_is_created_exclusively_and_absence_has_no_fake_initial_copy()
    {
        using var setup = await Setup.Create(tsvExists: false);
        Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "première publication relue");
        Check.Null(setup.Intent()!.TsvBackup, "absence initiale explicite");
        Check.False(File.Exists(setup.Displaced), "aucun ancien fichier inventé");
        Check.Equal(1, (await setup.Db.ReadSharedParkLocalAsync(None)).Sweeps.Rows.Length, "seule la ligne native subsiste : rien n’est créé depuis un partage absent");
        Check.Equal(VerificationState.Verified, (await setup.Verify()).State, "création et reçu vérifiés");
    }

    [Test]
    public static async Task Reusing_an_intention_never_replays_even_after_a_success()
    {
        using var setup = await Setup.Create(); Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "première écriture validée");
        var before = await setup.Db.ReadSharedParkLocalAsync(None); var bytes = File.ReadAllBytes(setup.Tsv);
        var error = await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(), "rejeu refusé avant sauvegardes ou publication");
        Check.Contains("aucun rejeu", error.Message, "intention existante est une preuve, pas un travail à rejouer");
        Check.Equal(before.Fingerprint, (await setup.Db.ReadSharedParkLocalAsync(None)).Fingerprint, "aucune seconde transaction");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucune seconde publication");
    }

    [Test]
    public static async Task An_altered_plan_is_refused_before_any_intention_or_publication()
    {
        using var setup = await Setup.Create();
        var tampered = setup.Plan with { Target = setup.Plan.Target with { Dn = "foreign" } };
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Db.ApplySharedParkConfirmedAsync(setup.Preview, tampered,
            setup.Backups, setup.Journal, [], [], () => { }, None), "plan altéré refusé");
        Check.Null(setup.Intent(), "pas d’intention avec plan altéré");
    }

    [Test]
    public static async Task An_absent_SQLite_is_prepared_privately_and_installed_with_its_committed_receipt()
    {
        using var setup = await Setup.Create(native: false); var reached = false;
        Check.Equal(WriteResult.Applied, (await setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.BeforeLocalInstall) { return; }
            reached = true; Check.False(File.Exists(setup.Db.Path), "nom actif toujours absent après commit privé");
            using var prepared = new SqliteDatabase(PreparedPath(setup), true);
            Check.Equal(1L, (long)prepared.Scalar("SELECT count(*) FROM domenia_v2_shared_park_receipts;")!, "reçu commis avec la proposition");
        })).Result, "nouvelle base et TSV réellement relus");
        Check.True(reached, "installation observée avant le déplacement"); Check.Null(setup.Intent()!.SqliteBackup, "pas de fausse copie d’une absence");
        var local = await setup.Db.ReadSharedParkLocalAsync(None);
        Check.True(local.Exists, "base maintenant présente"); Check.False(local.Legacy, "identité native explicite"); Check.Equal(1L, local.Revision, "première transaction");
        Check.Equal(0L, local.Generation, "génération initiale conservée"); Check.Equal("shared:PC1", local.Sweeps.Rows.Single().StorageKey, "clé externe uniquement");
        Check.Null(local.Sweeps.Rows.Single().ComputerGuid, "aucun GUID déduit"); Check.Null(local.Sweeps.Rows.Single().ComputerDn, "aucun DN déduit");
        Check.False(File.Exists(PreparedPath(setup)), "base réellement déplacée sans double copie fictive");
        Check.Equal(VerificationState.Verified, (await setup.Verify(new DomeniaDatabase(setup.Db.Path, Fixtures.Root, TestClock.Fixed()))).State, "vérification à froid");
    }

    [Test]
    public static async Task A_legacy_SQLite_keeps_native_rows_and_generation_while_receiving_its_first_bound_receipt()
    {
        using var setup = await Setup.Create(legacy: true); var before = await setup.Db.ReadSharedParkLocalAsync(None);
        Check.True(before.Legacy, "fixture réellement héritée");
        Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "rattachement minimal commis");
        var after = await setup.Db.ReadSharedParkLocalAsync(None);
        Check.False(after.Legacy, "identité du magasin maintenant rattachée"); Check.Equal(1L, after.Revision, "première révision");
        Check.Equal(4L, after.Generation, "génération D1 préservée");
        Check.Equal(before.Sweeps.Rows.Single().StorageFingerprint, after.Sweeps.Rows.Single(r => r.StorageKey == "native-PC1").StorageFingerprint, "ligne native intacte");
        Check.NotNull(setup.Intent()!.SqliteBackup, "vraie copie de la base historique"); Check.Equal(VerificationState.Verified, (await setup.Verify()).State, "preuve durable relue");
    }

    [Test]
    public static async Task A_minimal_legacy_SQLite_without_park_state_receives_only_the_required_tables()
    {
        using var setup = await Setup.Create(native: false, beforePreview: s =>
        {
            using var db = new SqliteDatabase(s.Db.Path, false);
            db.Script("CREATE TABLE schema_info(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO schema_info VALUES('schema_version','11');"
                + "CREATE TABLE opaque(value BLOB); INSERT INTO opaque VALUES(x'001122ff');");
        });
        Check.True(setup.Preview.Reference.Legacy, "vraie base11 sans métadonnées v2");
        Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "import partagé sur héritage minimal");
        using var actual = new SqliteDatabase(setup.Db.Path, true);
        Check.Null(actual.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';"), "aucune migration générale maquillée");
        Check.Equal("001122FF", (string)actual.Scalar("SELECT hex(value) FROM opaque;")!, "octets historiques conservés");
        Check.Equal(5L, (long)actual.Scalar("SELECT count(*) FROM sqlite_master WHERE type='table';")!, "schema_info, opaque et seulement les trois tables nécessaires");
        Check.Equal(VerificationState.Verified, (await setup.Verify()).State, "vérification accepte le schéma historique qualifié et exige son reçu");
    }

    [Test]
    public static async Task Cancellation_after_a_new_local_commit_retains_the_prepared_database_and_never_claims_success()
    {
        using var setup = await Setup.Create(native: false); using var cancel = new CancellationTokenSource(); var reached = false;
        var result = await setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.BeforeLocalInstall) { return; }
            reached = true; cancel.Cancel();
        }, cancel.Token);
        Check.True(reached, "commit privé réellement atteint"); Check.Equal(WriteResult.Unknown, result.Result, "TSV déjà publié, pas de faux refus");
        Check.False(File.Exists(setup.Db.Path), "base active jamais inventée après annulation");
        using var prepared = new SqliteDatabase(PreparedPath(setup), true);
        Check.Equal(1L, (long)prepared.Scalar("SELECT count(*) FROM domenia_v2_shared_park_receipts;")!, "reçu privé conservé");
        Check.Equal(setup.Preview.Reference.ProposedSha256, SharedParkFile.Hash(File.ReadAllBytes(setup.Tsv)), "publication réellement présente");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "pas de succès déduit du fichier partagé seul");
    }

    [Test]
    public static async Task A_noncooperating_base_appearance_after_remote_publication_is_never_overwritten()
    {
        using var setup = await Setup.Create(native: false); var alien = Encoding.UTF8.GetBytes("another writer owns this file"); var reached = false;
        var result = await setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.BeforeLocalInstall) { return; }
            reached = true; File.WriteAllBytes(setup.Db.Path, alien);
        });
        Check.True(reached, "apparition injectée au nom absent"); Check.Equal(WriteResult.Unknown, result.Result, "deux ressources non atomiques");
        Check.True(alien.SequenceEqual(File.ReadAllBytes(setup.Db.Path)), "aucun overwrite du fichier apparu");
        using var prepared = new SqliteDatabase(PreparedPath(setup), true);
        Check.Equal(1L, (long)prepared.Scalar("SELECT count(*) FROM domenia_v2_shared_park_receipts;")!, "base préparée commise conservée");
        Check.NotNull(setup.Intent(), "intention conserve l’absence initiale et la publication à examiner");
    }

    [Test]
    public static async Task An_absent_base_appearing_before_the_native_remote_attempt_refuses_without_publication()
    {
        using var setup = await Setup.Create(native: false); var before = File.ReadAllBytes(setup.Tsv); var reached = false;
        var error = await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.BeforePublication) { return; }
            reached = true; File.WriteAllText(setup.Db.Path, "appeared");
        }), "absence vérifiée encore au dernier instant");
        Check.True(reached, "frontière de publication réellement atteinte"); Check.Contains("apparu", error.Message, "refus exact de la présence concurrente");
        Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucune publication"); Check.NotNull(setup.Intent(), "preuve déjà créée conservée");
    }

    [Test]
    public static async Task A_legacy_transaction_failure_preserves_its_original_unbound_identity()
    {
        using var setup = await Setup.Create(legacy: true); var before = await setup.Db.ReadSharedParkLocalAsync(None); var reached = false;
        var result = await setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.BeforeCommit) { return; }
            reached = true; throw new IOException("interrupt before the legacy commit");
        });
        Check.True(reached, "transaction effectivement préparée"); Check.Equal(WriteResult.Unknown, result.Result, "TSV publié avant échec local");
        var after = await setup.Db.ReadSharedParkLocalAsync(None);
        Check.True(after.Legacy, "création de l’identité annulée avec les observations"); Check.Equal(before.Fingerprint, after.Fingerprint, "toutes les lignes et génération initiales conservées");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "intention sans reçu commis");
    }

    [Test]
    public static async Task Prepared_SQLite_admission_refuses_a_full_retained_directory_before_remote_publication()
    {
        using var setup = await Setup.Create(native: false); var root = SharedParkPendingSqlite.RootFor(setup.Db.Path);
        SharedParkLocalPaths.CreateExclusive(root);
        for (var i = 0; i < 32; i++) { SharedParkLocalPaths.CreateExclusive(System.IO.Path.Combine(root, WritePlans.NewId())); }
        var before = File.ReadAllBytes(setup.Tsv);
        var error = await Check.ThrowsAsync<IOException>(() => setup.Apply(), "quota des bases préparées");
        Check.Contains("32 bases", error.Message, "refus de quota précis"); Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucun envoi distant");
        Check.Equal(32, Directory.EnumerateDirectories(root).Count(), "preuves existantes conservées sans33e dossier");
    }

    private static string PreparedPath(Setup setup) => System.IO.Path.Combine(SharedParkPendingSqlite.RootFor(setup.Db.Path), setup.Plan.Id, "prepared.db");

    [Test]
    public static async Task A_generation_change_after_intention_refuses_without_publishing()
    {
        using var setup = await Setup.Create(); var before = File.ReadAllBytes(setup.Tsv); var reached = false;
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.IntentRecorded) { return; }
            reached = true; using var db = new SqliteDatabase(setup.Db.Path, false);
            db.Execute("UPDATE domenia_v2_sweep_state SET generation=generation+1 WHERE id=1;");
        }), "génération relue sous transaction avant publication");
        Check.True(reached, "reset concurrent réellement injecté"); Check.NotNull(setup.Intent(), "intention conservée après refus");
        Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucun résultat ancien réintroduit dans le partage");
    }

    [Test]
    public static async Task A_source_gate_change_after_intention_prevents_publication()
    {
        using var setup = await Setup.Create(); var changed = false; var before = File.ReadAllBytes(setup.Tsv);
        await Check.ThrowsAsync<InvalidOperationException>(() => setup.Apply(stage =>
        { if (stage == SharedParkApplyStage.IntentRecorded) { changed = true; } }, sourceCheck: () =>
        { if (changed) { throw new InvalidOperationException("source session changed"); } }), "source gate réévalué après intention");
        Check.True(changed, "transition réelle atteinte"); Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucune publication avec source remplacée");
        Check.NotNull(setup.Intent(), "preuve du plan conservée");
    }

    [Test]
    public static async Task A_remote_change_after_intention_refuses_the_first_CAS()
    {
        using var setup = await Setup.Create(); var changed = Bytes("PC2", "11:00:00", "concurrent"); var reached = false;
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(stage =>
        { if (stage == SharedParkApplyStage.IntentRecorded) { File.WriteAllBytes(setup.Tsv, changed); reached = true; } }), "relecture SHA sous verrou refuse l’aperçu périmé");
        Check.True(reached && changed.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "écriture concurrente conservée");
        Check.Equal(1, (await setup.Db.ReadSharedParkLocalAsync(None)).Sweeps.Rows.Length, "aucune observation externe écrite");
    }

    [Test]
    public static async Task Cancellation_after_publication_is_unknown_and_never_compensates()
    {
        using var setup = await Setup.Create(); using var cancel = new CancellationTokenSource(); var reached = false;
        var outcome = await setup.Apply(stage => { if (stage == SharedParkApplyStage.Published) { reached = true; cancel.Cancel(); } }, cancel.Token);
        Check.True(reached, "publication réellement terminée avant annulation"); Check.Equal(WriteResult.Unknown, outcome.Result, "annulation tardive explicitement incertaine");
        Check.Equal(setup.Preview.Reference.ProposedSha256, SharedParkFile.Hash(File.ReadAllBytes(setup.Tsv)), "publication non compensée");
        Check.Equal(1, (await setup.Db.ReadSharedParkLocalAsync(None)).Sweeps.Rows.Length, "transaction locale non commise");
        Check.NotNull(setup.Intent(), "intention durable conservée"); Check.True(File.Exists(setup.Displaced), "fichier antérieur conservé");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "SHA distant seul ne prouve jamais un succès");
    }

    [Test]
    public static async Task A_failing_diagnostic_observer_cannot_replace_an_uncertain_publication()
    {
        using var setup = await Setup.Create(); var observed = false;
        var before = await setup.Db.ReadSharedParkLocalAsync(None);
        var outcome = await setup.Db.ApplySharedParkConfirmedAsync(setup.Preview, setup.Plan, setup.Backups, setup.Journal,
            [], [], () => { }, None, stage =>
            {
                if (stage == SharedParkApplyStage.Published) { throw new IOException("interruption après publication"); }
            }, error =>
            {
                observed = true;
                throw new InvalidOperationException("diagnostic indisponible", error);
            });
        Check.True(observed, "l’observateur a réellement reçu l’erreur de publication");
        Check.Equal(WriteResult.Unknown, outcome.Result, "l’échec du diagnostic ne remplace pas l’issue incertaine");
        Check.Equal(before.Fingerprint, (await setup.Db.ReadSharedParkLocalAsync(None)).Fingerprint, "aucun commit SQLite après l’interruption");
        Check.NotNull(setup.Intent(), "intention durable conservée malgré l’échec du diagnostic");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "aucun succès inventé par le diagnostic");
    }

    [Test]
    public static async Task Failure_before_commit_rolls_back_only_the_local_transaction()
    {
        using var setup = await Setup.Create(); var reached = false;
        var outcome = await setup.Apply(stage =>
        { if (stage == SharedParkApplyStage.BeforeCommit) { reached = true; throw new IOException("interruption contrôlée avant commit"); } });
        Check.True(reached, "écritures locales et reçu préparés dans la transaction"); Check.Equal(WriteResult.Unknown, outcome.Result, "deux ressources jamais présentées comme atomiques");
        var local = await setup.Db.ReadSharedParkLocalAsync(None);
        Check.Equal(1, local.Sweeps.Rows.Length, "aucune demi-transaction locale"); Check.Equal(0L, local.Revision, "révision locale annulée avec les lignes");
        Check.Equal(setup.Preview.Reference.ProposedSha256, SharedParkFile.Hash(File.ReadAllBytes(setup.Tsv)), "TSV publié conservé");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "aucun reçu commis inventé");
    }

    [Test]
    public static async Task Failure_after_commit_can_be_resolved_by_cold_verification()
    {
        using var setup = await Setup.Create(); var reached = false;
        var outcome = await setup.Apply(stage =>
        { if (stage == SharedParkApplyStage.Committed) { reached = true; throw new IOException("réponse perdue après commit"); } });
        Check.True(reached, "commit réellement passé"); Check.Equal(WriteResult.Unknown, outcome.Result, "l’appel interrompu ne prétend pas avoir vérifié");
        Check.Equal(VerificationState.Verified, (await setup.Verify(new DomeniaDatabase(setup.Db.Path, Fixtures.Root, TestClock.Fixed()))).State,
            "le reçu durable et les deux états résolvent l’incertitude");
    }

    [Test]
    public static async Task An_uncooperative_replacement_in_the_native_window_is_preserved_and_never_committed_as_success()
    {
        using var setup = await Setup.Create(); var raced = Bytes("RACER", "12:00:00", "uncooperative"); var reached = false;
        var outcome = await setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.NativeReplaceWindow) { return; }
            File.Move(setup.Tsv, setup.Folder.File("racer-preserved-original.tsv"), overwrite: false);
            File.WriteAllBytes(setup.Tsv, raced); reached = true;
        });
        Check.True(reached, "le remplacement ignore volontairement le verrou D1"); Check.Equal(WriteResult.Unknown, outcome.Result, "aucune garantie CAS universelle inventée");
        Check.True(raced.SequenceEqual(File.ReadAllBytes(setup.Displaced)), "le fichier effectivement déplacé, même inattendu, est conservé");
        Check.Equal(1, (await setup.Db.ReadSharedParkLocalAsync(None)).Sweeps.Rows.Length, "aucun commit local sur une publication ambiguë");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "relecture explicite nécessaire, aucun rejeu");
    }

    [Test]
    public static async Task A_reserved_shared_key_with_a_native_GUID_is_never_overwritten()
    {
        using var setup = await Setup.Create(beforePreview: value =>
        {
            using var db = new SqliteDatabase(value.Db.Path, false);
            db.Execute("UPDATE park_state SET computer_key='shared:PC1';");
        });
        var before = File.ReadAllBytes(setup.Tsv);
        var error = await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(), "nom partagé ne prend jamais l’identité d’une ligne native");
        Check.Contains("observation native", error.Message, "collision explicitement refusée");
        Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "refus avant publication");
        Check.NotNull((await setup.Db.ReadSharedParkLocalAsync(None)).Sweeps.Rows.Single().ComputerGuid, "GUID original conservé");
    }

    [Test]
    public static async Task Changed_local_or_remote_states_are_not_verified_from_the_receipt_alone()
    {
        using (var setup = await Setup.Create())
        {
            Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "première opération validée");
            File.WriteAllBytes(setup.Tsv, Bytes("OTHER", "13:00:00", "changed"));
            Check.Equal(VerificationState.Mismatch, (await setup.Verify()).State, "fichier distant réellement relu");
        }
        using (var setup = await Setup.Create())
        {
            Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "seconde fixture validée");
            using (var db = new SqliteDatabase(setup.Db.Path, false)) { db.Execute("UPDATE park_state SET user_login='changed' WHERE computer_key='shared:PC1';"); }
            Check.Equal(VerificationState.Mismatch, (await setup.Verify()).State, "empreinte locale réellement relue sans dépendre de la révision");
        }
    }

    [Test]
    public static async Task A_trigger_refuses_before_publication_and_does_not_touch_other_tables()
    {
        using var setup = await Setup.Create(beforePreview: value =>
        {
            using var db = new SqliteDatabase(value.Db.Path, false);
            db.Script("CREATE TABLE unrelated(value TEXT); CREATE TRIGGER forbidden AFTER INSERT ON park_state BEGIN INSERT INTO unrelated VALUES('changed'); END;");
        });
        var before = File.ReadAllBytes(setup.Tsv);
        var error = await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(), "déclencheur non qualifié refusé");
        Check.Contains("déclencheur", error.Message, "cause exacte du refus"); Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "partage intact");
        using var read = new SqliteDatabase(setup.Db.Path, true); Check.Equal(0L, (long)read.Scalar("SELECT count(*) FROM unrelated;")!, "table étrangère intacte");
    }

    [Test]
    public static async Task Cancellation_before_publication_publishes_nothing_and_keeps_every_proof()
    {
        using var setup = await Setup.Create(); using var cancel = new CancellationTokenSource(); var before = File.ReadAllBytes(setup.Tsv); var reached = false;
        await Check.ThrowsAsync<OperationCanceledException>(() => setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.BeforePublication) { return; }
            reached = true; cancel.Cancel();
        }, cancel.Token), "annulation respectée avant toute tentative de renommage");
        Check.True(reached, "la frontière qui précède immédiatement le renommage est réellement atteinte");
        Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucun renommage tenté, le partage reste celui de l’aperçu");
        var local = await setup.Db.ReadSharedParkLocalAsync(None);
        Check.Equal(1, local.Sweeps.Rows.Length, "aucune observation externe écrite"); Check.Equal(0L, local.Revision, "aucune révision engagée");
        Check.NotNull(setup.Intent(), "intention et copies laissées en place, jamais nettoyées en silence après une annulation");
        Check.False(File.Exists(setup.Displaced), "rien n’a été déplacé puisqu’aucun remplacement n’a été tenté");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "une intention sans reçu commis ne prouve aucun succès");
    }

    [Test]
    public static async Task A_TSV_replaced_between_the_last_reread_and_the_rename_is_refused_by_the_physical_CAS()
    {
        using var setup = await Setup.Create(); var raced = Bytes("RACER", "12:00:00", "uncooperative"); var reached = false;
        var error = await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(stage =>
        {
            if (stage != SharedParkApplyStage.BeforePublication) { return; }
            // The lease this protocol holds on the TSV shares delete but never write: an uncooperative writer renames first, then
            // creates its own file under the freed name. That is exactly what the physical CAS must catch.
            File.Move(setup.Tsv, setup.Folder.File("kept-by-racer.tsv"), overwrite: false);
            File.WriteAllBytes(setup.Tsv, raced); reached = true;
        }), "le CAS physique refuse un TSV qui n’est plus l’inode confirmé");
        Check.True(reached, "l’interférence est réellement injectée entre la dernière relecture et le renommage");
        Check.Contains("CAS physique", error.Message, "cause exacte du refus");
        Check.True(raced.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "l’écriture concurrente n’est jamais écrasée par une publication refusée");
        Check.Equal(1, (await setup.Db.ReadSharedParkLocalAsync(None)).Sweeps.Rows.Length, "aucune observation externe écrite");
        Check.NotNull(setup.Intent(), "intention conservée comme preuve de la tentative avortée");
        Check.False(File.Exists(setup.Displaced), "aucun fichier déplacé puisqu’aucun remplacement n’a été tenté");
        Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "aucun succès déduit d’une intention seule");
    }

    [Test]
    public static async Task An_expiration_reached_during_the_publication_preparation_is_refused_before_any_rename()
    {
        // The plan lives five minutes and its batch ten, so two distinct advances discriminate the two bounds requalified at the
        // very last seam: seven minutes expires the plan alone, twenty expires the batch too.
        foreach (var (minutes, expectedCause) in new[] { (7, "Plan de partage"), (20, "Lot de sauvegarde") })
        {
            using var setup = await Setup.Create(); var before = File.ReadAllBytes(setup.Tsv); var reached = false;
            var error = await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(stage =>
            {
                if (stage != SharedParkApplyStage.BeforePublication) { return; }
                reached = true;
                // The temporary brother and the private evidence directory already exist at this seam. Advancing the very clock the
                // Store reads is the only way to make real time pass for the protocol between that preparation and the rename.
                setup.Clock.Advance(TimeSpan.FromMinutes(minutes));
            }), "expiration survenue après la préparation du temporaire, avant le renommage");
            Check.True(reached, "la frontière qui précède immédiatement le renommage est réellement atteinte");
            Check.Contains("expiré", error.Message, "refus d’expiration à la frontière, pas un effet de bord");
            Check.Contains(expectedCause, error.Message, "borne exactement atteinte après " + minutes + " minutes");
            Check.True(before.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucun renommage tenté après expiration, le partage reste celui de l’aperçu");
            var local = await setup.Db.ReadSharedParkLocalAsync(None);
            Check.Equal(1, local.Sweeps.Rows.Length, "aucune observation externe écrite"); Check.Equal(0L, local.Revision, "aucune révision engagée");
            using (var db = new SqliteDatabase(setup.Db.Path, true))
            { Check.Equal(0L, (long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='domenia_v2_shared_park_receipts';")!, "aucun reçu écrit"); }
            Check.NotNull(setup.Intent(), "copies et intention conservées après le refus, jamais nettoyées en silence");
            Check.False(File.Exists(setup.Displaced), "aucun fichier déplacé puisqu’aucun remplacement n’a été tenté");
            Check.Equal(VerificationState.Unknown, (await setup.Verify()).State, "intention sans reçu commis : aucun succès déduit, même horloge avancée");
        }
    }

    [Test]
    public static async Task The_durable_receipt_reports_the_exact_committed_state_on_a_cold_reread()
    {
        using var setup = await Setup.Create(); Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "opération réellement commise");
        using var db = new SqliteDatabase(setup.Db.Path, true);
        var rows = db.Query("SELECT plan_fingerprint,sha256,payload FROM domenia_v2_shared_park_receipts WHERE plan_id=?1;", setup.Plan.Id);
        Check.Equal(1, rows.Count, "un seul reçu durable pour ce plan");
        var payload = (string)rows[0]["payload"]!;
        Check.Equal(SharedParkFile.Hash(Encoding.UTF8.GetBytes(payload)), (string)rows[0]["sha256"]!, "le SHA stocké est bien celui des octets du reçu");
        Check.Equal(setup.Plan.Fingerprint, (string)rows[0]["plan_fingerprint"]!, "l’empreinte de colonne est celle du plan scellé");
        Check.True(Encoding.UTF8.GetByteCount(payload) <= 16384, "reçu conservé sous sa limite de 16 Kio");
        using var document = JsonDocument.Parse(payload);
        var receipt = document.RootElement; var batch = setup.Preview.Reference; var local = await setup.Db.ReadSharedParkLocalAsync(None);
        Check.Equal(1, receipt.GetProperty("Version").GetInt32(), "version unique de reçu");
        Check.Equal(setup.Plan.Id, receipt.GetProperty("PlanId").GetString(), "reçu rattaché à ce seul plan");
        Check.Equal(setup.Plan.Fingerprint, receipt.GetProperty("PlanFingerprint").GetString(), "reçu rattaché à l’empreinte du plan");
        Check.Equal(batch.Id, receipt.GetProperty("BatchId").GetString(), "reçu rattaché au lot d’aperçu réellement publié");
        Check.Equal(SharedParkIdentity.Fingerprint(batch), receipt.GetProperty("BatchFingerprint").GetString(), "empreinte du lot recalculée, pas recopiée");
        Check.Equal(setup.Db.StoreId, receipt.GetProperty("StoreId").GetString(), "magasin du reçu");
        Check.Equal(setup.Db.DomainDn, receipt.GetProperty("DomainDn").GetString(), "domaine du reçu");
        Check.Equal(batch.Path, receipt.GetProperty("Path").GetString(), "chemin réellement publié");
        Check.Equal(batch.ProposedSha256, receipt.GetProperty("RemoteSha256").GetString(), "SHA publié, jamais celui de l’ancien fichier");
        Check.Equal(local.RowsFingerprint, receipt.GetProperty("RowsFingerprint").GetString(), "empreinte des relevés relue dans la base, pas déclarée");
        Check.Equal(batch.Revision + 1, receipt.GetProperty("Revision").GetInt64(), "révision avancée d’un seul cran");
        Check.Equal(local.Revision, receipt.GetProperty("Revision").GetInt64(), "révision du reçu égale à celle réellement relue");
        Check.Equal(batch.Generation, receipt.GetProperty("Generation").GetInt64(), "génération d’en-tête conservée, jamais incrémentée");
        Check.Equal((long)batch.Added + batch.Replaced, receipt.GetProperty("Updated").GetInt64(), "nombre de relevés externes réellement écrits");
        Check.True(receipt.GetProperty("CommittedAt").GetString()!.EndsWith("+00:00", StringComparison.Ordinal), "horodatage du reçu exprimé en UTC");
    }

    [Test]
    public static async Task A_corrupted_intention_is_an_explicit_mismatch_and_blocks_any_replay()
    {
        using var setup = await Setup.Create(); Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "opération réellement commise");
        var bytes = File.ReadAllBytes(setup.Tsv); var local = await setup.Db.ReadSharedParkLocalAsync(None);
        File.WriteAllBytes(setup.CorruptibleIntentFile(), "{}"u8.ToArray());
        Check.Equal(VerificationState.Mismatch, (await setup.Verify()).State, "une intention corrompue est un échec explicite, jamais une absence ni un succès");
        await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(), "aucun rejeu n’est tenté tant que la preuve est corrompue");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "aucune seconde publication sur une preuve illisible");
        Check.Equal(local.Revision, (await setup.Db.ReadSharedParkLocalAsync(None)).Revision, "aucune seconde transaction locale");
    }

    [Test]
    public static async Task A_corrupted_receipt_is_an_explicit_mismatch_and_blocks_any_replay()
    {
        using var setup = await Setup.Create(); Check.Equal(WriteResult.Applied, (await setup.Apply()).Result, "opération réellement commise");
        var bytes = File.ReadAllBytes(setup.Tsv); var local = await setup.Db.ReadSharedParkLocalAsync(None);
        using (var db = new SqliteDatabase(setup.Db.Path, false))
        { db.Execute("UPDATE domenia_v2_shared_park_receipts SET payload=?1 WHERE plan_id=?2;", "{\"altéré\":true}", setup.Plan.Id); }
        Check.Equal(VerificationState.Mismatch, (await setup.Verify()).State, "un reçu dont le SHA ne correspond plus est un échec explicite, jamais relu comme vérifié");
        var error = await Check.ThrowsAsync<InvalidDataException>(() => setup.Apply(), "l’intention existante bloque le rejeu avant toute écriture");
        Check.Contains("aucun rejeu", error.Message, "cause exacte du refus");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(setup.Tsv)), "partage intact");
        Check.Equal(local.Revision, (await setup.Db.ReadSharedParkLocalAsync(None)).Revision, "aucune seconde transaction locale");
    }
}
