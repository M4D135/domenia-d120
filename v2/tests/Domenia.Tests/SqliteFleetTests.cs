using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteFleetTests
{
    private static readonly ScopeSelection Scope = new(Fixtures.Postes, "Postes", true);

    [Test]
    public static async Task Fleet_readings_are_committed_restored_and_keep_newer_observation_times()
    {
        using var folder = new TemporaryFolder();
        var computer = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("fleet.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer]), Scope, "dc1.test.local", CancellationToken.None);
        var observation = Fixtures.Observe(computer, Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(100, 40, TimeSpan.Zero));
        var machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(computer.ObjectGuid, new("TEST\\alice", Fixtures.Now, "1.2", Fixtures.Now, MeasureState.Known, Fixtures.Now, null));
        var probes = new ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>>.Empty.Add("hw.model", ImmutableDictionary<Guid, ProbeReading>.Empty.Add(computer.ObjectGuid, new(MeasureState.Known, Fixtures.Now, ["Modèle"], null))));
        await db.SaveFleetAsync(new(new(Fixtures.Now, [observation]), machines, [new(Scope.Dn, true, Fixtures.Now, true, false, ImmutableDictionary<Guid, BitLockerFact>.Empty.Add(computer.ObjectGuid, new(1, Fixtures.Now.AddDays(-1))))], probes), CancellationToken.None);
        var reopened = new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed());
        var stored = await reopened.ReadFleetAsync(CancellationToken.None);
        Check.Equal(observation, stored.Observations.Workstations.Single(), "mesures relues après réouverture");
        Check.Equal("TEST\\alice", stored.Facts.Machines[computer.ObjectGuid].ConsoleUser, "session datée");
        Check.Equal("Modèle", stored.Probes.ByProbe["hw.model"][computer.ObjectGuid].Values.Single(), "sonde persistée");
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now.AddHours(-1), [observation with { Presence = Fixtures.Presence(false, TimeSpan.FromHours(1)) }]) }, CancellationToken.None);
        Check.True((await db.ReadFleetAsync(CancellationToken.None)).Observations.Workstations.Single().Presence.Answered == true, "lecture tardive sans recul de date");
    }

    [Test]
    public static async Task Unknown_targets_future_dates_and_foreign_BitLocker_scope_do_not_change_the_store()
    {
        using var folder = new TemporaryFolder();
        var computer = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("guards.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer]), Scope, null, CancellationToken.None);
        var revision = (await db.InspectAsync(CancellationToken.None))!.Revision;
        var unknown = FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(Fixtures.Computer("unknown"))]) };
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(unknown, CancellationToken.None), "poste non enregistré");
        var future = FleetCachePatch.Empty with { Observations = new(Fixtures.Now.AddDays(1), [Fixtures.Observe(computer)]) };
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(future, CancellationToken.None), "date future");
        var foreign = FleetCachePatch.Empty with { BitLocker = [new("OU=Elsewhere," + Fixtures.Root, true, Fixtures.Now, true, false, ImmutableDictionary<Guid, BitLockerFact>.Empty.Add(computer.ObjectGuid, new(1, null)))] };
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(foreign, CancellationToken.None), "poste hors de la branche du relevé");
        Check.Equal(revision, (await db.InspectAsync(CancellationToken.None))!.Revision, "aucun commit des données refusées");
        Check.True((await db.ReadFleetAsync(CancellationToken.None)).Observations.Workstations.IsEmpty, "pas de relevé fabriqué");
    }

    [Test]
    public static async Task A_corrupted_recent_backup_is_replaced_before_the_next_network_refresh()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("backup.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        var first = await db.PrepareReadAsync(CancellationToken.None);
        File.AppendAllText(first.Path, "damaged");
        var second = await db.PrepareReadAsync(CancellationToken.None);
        Check.False(first.Path == second.Path, "nouvelle sauvegarde distincte");
        Check.True(File.Exists(first.Path), "ancienne sauvegarde conservée pour diagnostic");
        using var restored = new SqliteDatabase(second.Path, true);
        Check.Equal("ok", (string?)restored.Scalar("PRAGMA quick_check;"), "nouvelle sauvegarde lisible");
    }

    [Test]
    public static async Task Legacy_daily_history_keeps_depth_and_unknown_coverage()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("history.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        var figures = JsonSerializer.Serialize(new { Machines = 7, Healthy = 3, Problems = 4, Stale = 1, StaleDays = 90, EndOfService = 2, Disabled = 1, Windows10 = 2, LowDisk = (int?)null });
        using (var raw = new SqliteDatabase(db.Path, false))
        {
            raw.Execute("INSERT INTO fleet_snapshots(scope_key,snapshot_day,taken_at,scope_dn,machines,figures) VALUES(?1,?2,?3,?4,7,?5);", Scope.Dn.ToLowerInvariant() + "|OneLevel", "2026-10-20", "2026-10-20T12:00:00Z", Scope.Dn, figures);
        }
        Check.True((await db.ReadFleetHistoryAsync(Scope, CancellationToken.None)).IsEmpty, "historique direct non attribué aux sous-OU");
        var history = await db.ReadFleetHistoryAsync(Scope with { Subtree = false }, CancellationToken.None);
        Check.Equal(7, history.Single().Figures.Machines, "compte historique");
        Check.Null(history.Single().Figures.LowDisk, "disque inconnu préservé");
        Check.Null(history.Single().Figures.Score, "couverture historique inconnue");
        Check.Equal(1, history.Single().Figures.FormatVersion, "format historique explicite");
    }
}
