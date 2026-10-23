using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageBackupTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Native_backup_preserves_the_database_and_remains_verifiable_after_restart()
    {
        using var setup = new Setup();
        var database = await setup.Cache.DatabaseAsync(None); await database.InitializeAsync(None);
        var before = File.ReadAllBytes(database.Path);
        var writer = new AdStorageBackupLocalExecutor(setup.Source);
        var plan = Seal(await writer.PlanBackupAsync(StoragePolicyRules.Default, "{}", StorageWritePlans.ManualSeries, None));
        Check.True((await writer.CheckAsync(plan, None)).Current, "copie autorisée après relecture");
        Check.Equal(WriteResult.Applied, (await writer.ExecuteAsync(plan, None)).Result, "copie exécutée");
        Check.True(before.SequenceEqual(File.ReadAllBytes(database.Path)), "base active intacte");
        var settings = await new AdSettingsReader(setup.Source).LocalStoreAsync(None);
        Check.Equal(1, settings.Backups.Count(x => x.Kind == "manual"), "copie complète visible dans Paramètres");
        Check.True(BackupPreferencesRules.IsBound(settings.Backups.Single(x => x.Kind == "manual")), "annexe liée à son empreinte");
        var reopened = new CompatibleDirectoryCache(setup.App, setup.User, "test.local", TestClock.Fixed(Fixtures.Now.AddHours(1)));
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageBackupAsync(plan, None)).State, "preuve relue après redémarrage et expiration");
        Check.False((await writer.CheckAsync(plan, None)).Current, "plan déjà envoyé non rejoué");
        Check.Equal(WriteResult.NoChange, (await writer.ExecuteAsync(plan, None)).Result, "répétition directe sans seconde copie");
    }

    [Test]
    public static async Task Native_backup_copy_preserves_replaced_file_and_rejects_destination_races()
    {
        using var setup = new Setup();
        await (await setup.Cache.DatabaseAsync(None)).InitializeAsync(None);
        var writer = new AdStorageBackupCopyExecutor(setup.Source);
        var target = setup.Folder.File("published.db"); File.WriteAllText(target, "original à conserver");
        var stale = Seal(await writer.PlanBackupCopyAsync(target, StoragePolicyRules.Default, "{}", None));
        File.WriteAllText(target, "modification concurrente");
        Check.False((await writer.CheckAsync(stale, None)).Current, "cible modifiée signalée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(stale, None), "cible revérifiée à la publication");
        var plan = Seal(await writer.PlanBackupCopyAsync(target, StoragePolicyRules.Default, "{}", None));
        await writer.ExecuteAsync(plan, None);
        Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, None)).State, "publication relue");
        Check.Equal("modification concurrente", File.ReadAllText(target + ".previous-" + plan.Id + ".db"), "original remplacé récupérable");
        using var sqlite = new SqliteDatabase(target, true);
        Check.Equal("ok", sqlite.Scalar("PRAGMA quick_check;") as string, "copie publiée lisible");
    }

    [Test]
    public static async Task Native_backup_corruption_is_never_reported_as_verified()
    {
        using var setup = new Setup(); await (await setup.Cache.DatabaseAsync(None)).InitializeAsync(None);
        var writer = new AdStorageBackupLocalExecutor(setup.Source);
        var plan = Seal(await writer.PlanBackupAsync(StoragePolicyRules.Default, "{}", StorageWritePlans.ManualSeries, None));
        await writer.ExecuteAsync(plan, None);
        var database = await setup.Cache.DatabaseAsync(None);
        var file = plan.Changes.Single(x => x.Attribute == "backup.file").AfterValue!;
        File.AppendAllText(Path.Combine(Path.GetDirectoryName(database.Path)!, "Backups", file), "corrompu");
        await Check.ThrowsAsync<InvalidDataException>(() => writer.VerifyAsync(plan, None), "empreinte non conforme signalée");
    }

    [Test]
    public static async Task Backup_rotation_keeps_recoverable_originals_outside_active_series()
    {
        using var setup = new Setup(); await (await setup.Cache.DatabaseAsync(None)).InitializeAsync(None);
        var writer = new AdStorageBackupLocalExecutor(setup.Source);
        var policy = StoragePolicyRules.Default with { BackupKeep = 2 };
        var first = Seal(await writer.PlanBackupAsync(policy, "{}", StorageWritePlans.ManualSeries, None));
        await writer.ExecuteAsync(first, None);
        var middle = Seal(await writer.PlanBackupAsync(policy, "{}", StorageWritePlans.ManualSeries, None));
        await writer.ExecuteAsync(middle, None);
        var second = Seal(await writer.PlanBackupAsync(policy, "{}", StorageWritePlans.ManualSeries, None));
        var rotatedId = second.Changes.Single(x => x.Attribute == "backup.rotation").BeforeValue;
        Check.True(rotatedId == first.Id || rotatedId == middle.Id, "rotation liée à une copie approuvée, même si les dates sont identiques");
        await writer.ExecuteAsync(second, None);
        var database = await setup.Cache.DatabaseAsync(None);
        var rotated = rotatedId == first.Id ? first : middle;
        var oldName = rotated.Changes.Single(x => x.Attribute == "backup.file").AfterValue!;
        Check.True(File.Exists(Path.Combine(Path.GetDirectoryName(database.Path)!, "Backups", "Retired", oldName)), "original de rotation récupérable");
        var active = (await new AdSettingsReader(setup.Source).LocalStoreAsync(None)).Backups.Where(x => x.Kind == "manual").ToArray();
        Check.Equal(2, active.Length, "série limitée");
        Check.True(active.Any(x => x.Id == second.Id), "nouvelle copie active");
    }

    [Test]
    public static async Task Cold_integrity_report_has_a_valid_unavailable_verdict_without_creating_files()
    {
        using var setup = new Setup();
        var report = await new AdSettingsReader(setup.Source).CheckIntegrityAsync(None);
        var view = LocalStoreRules.Integrity(report.Integrity!, TimeZoneInfo.Utc);
        Check.False(report.Available, "base absente");
        Check.True(view.Failed > 0, "absence explicite, pas de faux état sain");
        Check.False(Directory.Exists(setup.User), "aucun fichier créé");
    }

    private static WritePlan Seal(WritePlanDraft draft) => WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
    private sealed class Setup : IDisposable
    {
        internal TemporaryFolder Folder { get; } = new();
        internal string App { get; }
        internal string User { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal Setup()
        {
            App = Folder.File("app"); User = Folder.File("profile");
            Cache = new(App, User, "test.local", TestClock.Fixed());
            Source = new("test.local", () => "test", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: Cache);
        }
        public void Dispose() { Source.Dispose(); Folder.Dispose(); }
    }
}
