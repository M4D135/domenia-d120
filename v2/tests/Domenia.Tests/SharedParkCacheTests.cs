using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Real cache leases and local Windows fixtures. These tests require no AD, SMB or external configuration.</summary>
internal static class SharedParkCacheTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private sealed class Setup : IDisposable
    {
        internal readonly TemporaryFolder Folder = new();
        internal readonly FixedTimeProvider Clock = TestClock.Fixed();
        internal readonly WritePlanOrigin Origin = new(7, "cache-source");
        internal CompatibleDirectoryCache Cache { get; }
        internal string App => Folder.File("app");
        internal string User => Folder.File("user");
        internal string Tsv => Folder.File("park.tsv");
        internal string PrivateRoot => System.IO.Path.Combine(User, "SharedPark-Isolated");
        internal DomeniaDatabase Db = null!;
        internal int Checks;
        private Setup()
        {
            Directory.CreateDirectory(App); Directory.CreateDirectory(User);
            Configure(Tsv);
            Cache = new(App, User, "test.local", Clock, isolated: true);
        }
        internal static async Task<Setup> Create(bool native = true)
        {
            var setup = new Setup();
            try
            {
                setup.Db = await setup.Cache.DatabaseAsync(None);
                if (native) { await setup.Db.InitializeAsync(None); }
                File.WriteAllBytes(setup.Tsv, SharedParkFile.Encode([new("REMOTE", TestClock.Reference.AddMinutes(-5), "CONFIRME", "user", 2, null)]));
                return setup;
            }
            catch { setup.Dispose(); throw; }
        }
        internal void Configure(string path) => File.WriteAllText(System.IO.Path.Combine(App, "Domenia.config.json"), JsonSerializer.Serialize(new { ParkSweep = new { SharedPath = path } }));
        internal void Validate() => Checks++;
        internal Task<SharedParkPreviewInfo> Read() => Cache.ReadSharedParkAsync(Origin, Validate, None);
        internal async Task<WritePlan> Plan(SharedParkBatch batch) => WritePlans.Seal(await Cache.DraftSharedParkAsync(batch, Origin, None),
            WritePlans.NewId(), "fixture", AppMode.Directory, Clock.GetUtcNow(), TimeZoneInfo.Utc);
        public void Dispose() { Cache.DiscardSharedParkPreviews(); Folder.Dispose(); }
    }

    [Test]
    public static async Task Cache_reads_measured_metadata_without_initializing_an_absent_base()
    {
        using var s = await Setup.Create(native: false); var before = SharedParkPreviewFile.ActiveLeases;
        var info = await s.Read();
        Check.Equal(1, info.RemoteRows, "nombre distant réellement lu"); Check.Equal(0, info.Kept, "aucune ligne locale");
        Check.Equal("REMOTE", info.Differences.Single().Computer, "différence concrète");
        Check.False(info.Batch.LocalExists, "absence explicitement liée"); Check.False(File.Exists(s.Db.Path), "lecture sans initialisation");
        Check.True(s.Checks >= 10, "validator réel aux transitions");
        Check.Equal(before + 1, SharedParkPreviewFile.ActiveLeases, "lease détenue");
        s.Cache.DiscardSharedPark(info.Batch.Id);
        Check.Equal(before, SharedParkPreviewFile.ActiveLeases, "lease libérée explicitement");
        await Check.ThrowsAsync<InvalidDataException>(() => s.Cache.DraftSharedParkAsync(info.Batch, s.Origin, None), "référence abandonnée inutilisable");
    }

    [Test]
    public static async Task Presentation_kept_and_differences_use_real_local_winners_and_exclude_equal_dates()
    {
        using var s = await Setup.Create();
        using (var db = new SqliteDatabase(s.Db.Path, false))
        {
            db.Script("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES"
                + "('a','EQUAL','2026-10-21T16:20:00Z','SESSION',NULL,1),('b','LOCAL','2026-10-21T16:21:00Z','SESSION',NULL,1),"
                + "('c','ONLYLOCAL','2026-10-21T16:21:00Z','SESSION',NULL,1);");
        }
        File.WriteAllBytes(s.Tsv, SharedParkFile.Encode([new("EQUAL", TestClock.Reference.AddMinutes(-6), "CONFIRME", null, 1, null),
            new("LOCAL", TestClock.Reference.AddMinutes(-8), "CONFIRME", null, 1, null)]));
        var info = await s.Read();
        Check.Equal(2, info.RemoteRows, "deux lignes reçues"); Check.Equal(2, info.Kept, "plus récente et absente du partage");
        Check.Equal(2, info.Differences.Length, "égalité exclue"); Check.False(info.DifferencesTruncated, "affichage complet");
    }

    [Test]
    public static async Task Presentation_is_bounded_without_truncating_the_actual_proposal()
    {
        using var s = await Setup.Create();
        File.WriteAllBytes(s.Tsv, SharedParkFile.Encode([.. Enumerable.Range(0, 130).Select(i => new SharedParkLine("PC" + i.ToString("D3"), TestClock.Reference.AddMinutes(-5), "CONFIRME", null, 1, null))]));
        var info = await s.Read();
        Check.Equal(130, info.RemoteRows, "source entière mesurée"); Check.Equal(130, info.Batch.MergedRows, "proposition entière");
        Check.Equal(128, info.Differences.Length, "présentation bornée"); Check.True(info.DifferencesTruncated, "troncature explicite");
    }

    [Test]
    public static async Task Draft_is_metadata_only_and_does_not_read_a_now_unavailable_share()
    {
        using var s = await Setup.Create(); var info = await s.Read();
        File.Delete(s.Tsv); s.Configure(s.Folder.File("different.tsv"));
        var draft = await s.Cache.DraftSharedParkAsync(info.Batch, s.Origin, None);
        Check.Equal(s.Origin, draft.Origin!, "origine conservée");
        Check.False((await s.Cache.CheckSharedParkAsync(info.Batch, s.Origin, s.Validate, None)).Current, "précheck détecte le chemin changé");
    }

    [Test]
    public static async Task Cache_rejects_a_forged_batch_or_another_origin_without_releasing_the_real_lease()
    {
        using var s = await Setup.Create(); var info = await s.Read();
        await Check.ThrowsAsync<InvalidDataException>(() => s.Cache.DraftSharedParkAsync(info.Batch with { Added = 0 }, s.Origin, None), "résumé forgé refusé");
        await Check.ThrowsAsync<InvalidDataException>(() => s.Cache.DraftSharedParkAsync(info.Batch, s.Origin with { SessionKey = "other" }, None), "origine différente refusée");
        Check.True((await s.Cache.CheckSharedParkAsync(info.Batch, s.Origin, s.Validate, None)).Current, "lease originale toujours valide");
    }

    [Test]
    public static async Task Cache_qualification_detects_a_D1_writer_without_a_revision_increment()
    {
        using var s = await Setup.Create(); var info = await s.Read();
        using (var db = new SqliteDatabase(s.Db.Path, false))
        { db.Script("INSERT INTO park_state VALUES('local','LOCAL','2026-10-21T16:20:00Z','SESSION',NULL,1);"); }
        Check.False((await s.Cache.CheckSharedParkAsync(info.Batch, s.Origin, s.Validate, None)).Current, "empreinte des lignes complète relue");
    }

    [Test]
    public static async Task Invalidating_during_read_prevents_delivery_and_releases_the_created_spool()
    {
        using var s = await Setup.Create(); var before = SharedParkPreviewFile.ActiveLeases; var hit = false;
        await Check.ThrowsAsync<InvalidDataException>(() => s.Cache.ReadSharedParkAsync(s.Origin, () =>
        {
            if (SharedParkPreviewFile.ActiveLeases > before) { hit = true; s.Cache.DiscardSharedParkPreviews(); }
        }, None), "invalidée après création du spool");
        Check.True(hit, "frontière post-spool réellement atteinte"); Check.Equal(before, SharedParkPreviewFile.ActiveLeases, "aucune lease échouée conservée");
    }

    [Test]
    public static async Task Cache_admission_and_expiration_bound_the_number_of_live_previews()
    {
        using var s = await Setup.Create(); var before = SharedParkPreviewFile.ActiveLeases;
        for (var i = 0; i < 8; i++) { await s.Read(); }
        var error = await Check.ThrowsAsync<InvalidDataException>(() => s.Read(), "neuvième aperçu refusé");
        Check.Contains("huit", error.Message, "borne du cache atteinte");
        s.Clock.Advance(TimeSpan.FromMinutes(11)); await s.Read();
        Check.Equal(before + 1, SharedParkPreviewFile.ActiveLeases, "aperçus expirés libérés avant nouvelle admission");
    }

    [Test]
    public static async Task Existing_public_spool_root_is_refused_without_changing_its_ACL()
    {
        using var s = await Setup.Create(); Directory.CreateDirectory(s.PrivateRoot);
        var security = new DirectoryInfo(s.PrivateRoot).GetAccessControl();
        security.AddAccessRule(new(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.ReadAndExecute, AccessControlType.Allow));
        new DirectoryInfo(s.PrivateRoot).SetAccessControl(security);
        var before = new DirectoryInfo(s.PrivateRoot).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access);
        await Check.ThrowsAsync<InvalidDataException>(() => s.Read(), "root non privé refusé");
        Check.Equal(before, new DirectoryInfo(s.PrivateRoot).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access), "pas de réparation d’un ACL externe");
    }

    [Test]
    public static async Task Cache_executes_once_then_verifies_after_a_new_instance_has_no_lease()
    {
        using var s = await Setup.Create(); var info = await s.Read(); var plan = await s.Plan(info.Batch);
        var before = SharedParkPreviewFile.ActiveLeases;
        Check.Equal(WriteResult.Applied, (await s.Cache.ApplySharedParkAsync(info.Batch, plan, s.Origin, s.Validate, None)).Result, "protocole réel raccordé");
        Check.Equal(before - 1, SharedParkPreviewFile.ActiveLeases, "consommation ferme la lease");
        await Check.ThrowsAsync<InvalidDataException>(() => s.Cache.ApplySharedParkAsync(info.Batch, plan, s.Origin, s.Validate, None), "rejeu refusé");
        var restarted = new CompatibleDirectoryCache(s.App, s.User, "test.local", s.Clock, isolated: true);
        Check.Equal(VerificationState.Verified, (await restarted.VerifySharedParkAsync(plan, None)).State, "journal et reçu durable suffisent à froid");
    }

    [Test]
    public static async Task A_cancelled_source_before_apply_leaves_remote_and_local_unchanged_and_consumes_the_lease()
    {
        using var s = await Setup.Create(); var info = await s.Read(); var plan = await s.Plan(info.Batch);
        var remote = File.ReadAllBytes(s.Tsv); var before = SharedParkPreviewFile.ActiveLeases;
        await Check.ThrowsAsync<OperationCanceledException>(() => s.Cache.ApplySharedParkAsync(info.Batch, plan, s.Origin,
            () => throw new OperationCanceledException("source fermée"), None), "source réelle annule");
        Check.True(remote.SequenceEqual(File.ReadAllBytes(s.Tsv)), "TSV inchangé");
        Check.Equal(0, (await s.Db.ReadSharedParkLocalAsync(None)).Sweeps.Rows.Length, "aucune observation inventée");
        Check.Equal(before - 1, SharedParkPreviewFile.ActiveLeases, "lease consommée même après refus");
    }
}
