using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class BackupScheduleEvidenceTests
{
    [Test]
    public static async Task Future_native_backup_stops_the_real_scheduler_without_sending_another_write()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", clock);
        var database = await cache.DatabaseAsync(default); await database.InitializeAsync(default);
        var draft = await cache.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", null, default);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, clock.GetUtcNow(), TimeZoneInfo.Utc);
        await cache.ApplyStorageBackupAsync(plan, default);
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock,
            connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        using var context = new EngineContext(ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")),
            source, new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdSettingsReader).Assembly]),
            writers: WriteExecutors.Discover(source, [typeof(AdStorageBackupLocalExecutor).Assembly]), receipts: new MemoryReceiptStore());
        await context.Preferences.SetAsync(StoragePolicyRules.PreferenceKey, StoragePolicyRules.ToJson(StoragePolicyRules.Default with { AutomaticBackup = true }), default);
        clock.Advance(TimeSpan.FromMinutes(-3));
        var scheduler = StorageBackupScheduler.From(context);
        Check.Equal("invalidClock", await scheduler.TickAsync(default), "vraie sauvegarde datée au-delà de la tolérance bloque la boucle");
        Check.Null(scheduler.State.LastAttempt, "aucune tentative ni délai de reprise fabriqué");
        Check.Null(scheduler.State.LastSuccess, "aucun nouveau succès de session");
        Check.Equal(0, ((MemoryReceiptStore)context.Receipts).Appends, "aucune écriture envoyée");
        var operation = new SettingsOperations().CreateOperations(context).Single(o => o.Name == "settings.storage");
        var view = (StorageView)(await operation.Handler(JsonSerializer.SerializeToElement(new { }), new BridgeContext(_ => { }, "schedule", operation.Name), default))!;
        var schedule = view.Schedule ?? throw new TestFailureException("Planification absente du handler Paramètres.");
        Check.Equal("invalidClock", schedule.Reason, "état du vrai handler concordant");
        Check.True(schedule.Lines.Any(l => l.Contains("planification arrêtée", StringComparison.Ordinal)), "arrêt visible");
        Check.Null(schedule.NextAt, "aucune fausse échéance annoncée");
        clock.Advance(TimeSpan.FromMinutes(3));
        Check.Equal("recent", await scheduler.TickAsync(default), "correction de l’horloge permet de réévaluer la même copie");
        Check.Equal(1, (await cache.InspectLocalStoreAsync(false, false, default)).Backups.Length, "aucune copie supplémentaire");
    }

    [Test]
    public static void Schedule_view_distinguishes_verified_copy_unknown_copy_failure_and_next_date()
    {
        var policy = StoragePolicyRules.Default with { AutomaticBackup = true, BackupHours = 24, BackupKeep = 7 };
        var at = Fixtures.Now.AddHours(-1);
        var copy = new LocalStoreBackup(WritePlans.NewId(), "Domenia-test.db", at, 4 * 1024 * 1024, new string('a', 64), true, at, "manual", 1,
            new(null, null, null, null, null, null), null, null);
        var view = StoragePolicyRules.Schedule(policy, copy, null, "Disque indisponible", Fixtures.Now, false, Fixtures.Now, TimeZoneInfo.Utc);
        Check.Equal("recent", view.Reason, "preuve récente");
        Check.Equal(at.AddHours(24), view.NextAt!.Value, "prochaine échéance issue de la vraie date de copie");
        Check.True(view.Lines.Any(l => l.Contains("Dernière sauvegarde vérifiée", StringComparison.Ordinal)
            && l.Contains(SettingsFormat.Size(copy.Bytes), StringComparison.Ordinal) && l.Contains("aaaaaaaaaaaa", StringComparison.Ordinal)), "date, taille et début du SHA présents sur la même preuve");
        Check.True(view.Lines.Any(l => l.Contains("Prochaine sauvegarde", StringComparison.Ordinal)
            && l.Contains(SettingsFormat.LocalDate(at.AddHours(24), TimeZoneInfo.Utc), StringComparison.Ordinal)), "échéance explicite");
        Check.True(view.Lines.Any(l => l.Contains("Dernier échec (cette session)", StringComparison.Ordinal)
            && l.Contains("Disque indisponible", StringComparison.Ordinal)), "échec conserve sa cause sans effacer la dernière copie");
        var unknown = StoragePolicyRules.Schedule(policy, copy with { Verified = false }, null, null, null, false, Fixtures.Now, TimeZoneInfo.Utc);
        Check.True(unknown.Lines.Contains("Aucune sauvegarde vérifiée enregistrée pour cette base."), "fichier sans preuve n’est pas un succès");
        var futureAttempt = StoragePolicyRules.Schedule(policy, copy, Fixtures.Now.AddMinutes(3), null, null, false, Fixtures.Now, TimeZoneInfo.Utc);
        Check.Equal("invalidClock", futureAttempt.Reason, "une tentative future bloque également");
        Check.Null(futureAttempt.NextAt, "pas de prochaine date quand l’horloge est incohérente");
    }
}
