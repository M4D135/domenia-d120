using System.Text;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteSessionMeasurementsTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static void Configured_timeout_reaches_native_connections_and_remains_bounded_per_session()
    {
        using var folder = new TemporaryFolder();
        foreach (var (value, expected) in new[] { (-1, 100), (775, 775), (9000, 5000) })
        {
            var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), false);
            var report = ConfigurationRules.Read(Encoding.UTF8.GetBytes("{\"LocalStore\":{\"DatabaseBusyTimeoutMs\":" + value + "}}"), "test");
            activity.ConfigureSqliteTimeout(ConfigurationRules.Integer(report, "LocalStore", "DatabaseBusyTimeoutMs", 2500));
            var database = new DomeniaDatabase(folder.File("timeout" + expected + ".db"), Fixtures.Root, TestClock.Fixed());
            database.ConfigureSession(activity);
            using var native = database.Open(false);
            Check.Equal((long)expected, (long)native.Scalar("PRAGMA busy_timeout;")!, "vrai paramètre natif de cette base");
            Check.Equal(expected, activity.SqliteBusyTimeoutMs, "valeur affichée par Santé du moteur identique");
            using (OperationsMeasurements.Enter(activity))
            using (var related = new SqliteDatabase(folder.File("related" + expected + ".db"), false))
                Check.Equal((long)expected, (long)related.Scalar("PRAGMA busy_timeout;")!, "copie ou worker dans le contexte de session");
        }
        using var defaults = new SqliteDatabase(folder.File("default.db"), false);
        Check.Equal(2500L, (long)defaults.Scalar("PRAGMA busy_timeout;")!, "aucun réglage global laissé par une autre session");
    }

    [Test]
    public static async Task Background_writer_busy_is_counted_once_without_a_bridge_context_and_never_replayed()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var activity = new OperationActivity(clock, new RecordingJournal(), false); activity.ConfigureSqliteTimeout(100);
        var database = new DomeniaDatabase(folder.File("writer.db"), Fixtures.Root, clock); database.ConfigureSession(activity);
        var pc = Fixtures.Computer("PC1");
        await database.InitializeAsync(None);
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", None);
        using (var blocker = new SqliteDatabase(database.Path, false))
        {
            blocker.Begin();
            var patch = FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero))]) };
            await Check.ThrowsAsync<SqliteStoreException>(() => Task.Run(() => database.SaveFleetAsync(patch, None)), "écrivain réel sans requête du pont");
            Check.Equal(1, activity.SqliteBusy.Count, "une fin Busy, ni doublon du catch ni oubli du worker");
            Check.Equal(Fixtures.Now, activity.SqliteBusy.Last!.Value, "date de cette session");
        }
        Check.Equal(0, (await database.ReadFleetAsync(None)).Observations.Workstations.Length, "aucun rejeu après libération du verrou");
        Check.Equal(1, activity.SqliteBusy.Count, "lecture réussie ne crée aucun incident");
    }

    [Test]
    public static async Task Branch_cache_contention_belongs_to_its_session_without_a_bridge_context()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var owner = new OperationActivity(clock, new RecordingJournal(), false); owner.ConfigureSqliteTimeout(100);
        var database = new DomeniaDatabase(folder.File("branches.db"), Fixtures.Root, clock); database.ConfigureSession(owner);
        await database.InitializeAsync(None);
        var original = new DirectoryBranch(new(Fixtures.Root, "test.local", "test.local"), [], Fixtures.Now, Guid.NewGuid());
        await database.SaveBranchAsync(original, None);
        using (var blocker = new SqliteDatabase(database.Path, false))
        {
            blocker.Script("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;");
            await Check.ThrowsAsync<SqliteStoreException>(() => database.ReadBranchAsync(Fixtures.Root, None), "lecture de branche réellement bloquée hors pont");
            Check.Equal(1, owner.SqliteBusy.Count, "incident de lecture attribué à la session propriétaire");
        }
        using (var blocker = new SqliteDatabase(database.Path, false))
        {
            blocker.Begin();
            await Check.ThrowsAsync<SqliteStoreException>(() => database.SaveBranchAsync(original with { ReadId = Guid.NewGuid() }, None), "écriture de branche réellement bloquée hors pont");
            Check.Equal(2, owner.SqliteBusy.Count, "un seul incident de plus pour cette écriture");
        }
        Check.Equal(original.ReadId, (await database.ReadBranchAsync(Fixtures.Root, None))!.ReadId, "branche initiale conservée, aucun rejeu implicite");
        Check.Equal(2, owner.SqliteBusy.Count, "relecture réussie sans nouvel incident");
    }

    [Test]
    public static async Task Local_index_busy_reports_unknown_and_uses_the_database_owner_even_under_another_ambient_context()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var owner = new OperationActivity(clock, new RecordingJournal(), false); owner.ConfigureSqliteTimeout(100);
        var other = new OperationActivity(clock, new RecordingJournal(), false);
        var database = new DomeniaDatabase(folder.File("reader.db"), Fixtures.Root, clock); database.ConfigureSession(owner);
        await database.InitializeAsync(None);
        var scope = new SyncScope(Fixtures.Postes, "Postes", "Postes", false, false, "test");
        using (var blocker = new SqliteDatabase(database.Path, false))
        {
            blocker.Script("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;");
            using (OperationsMeasurements.Enter(other))
            {
                var page = await database.SearchIndexAsync(new("", scope, IndexSort.Name, false, 0, 200), None);
                Check.True(page.Busy, "refus explicite, jamais une liste vide présentée comme un succès");
            }
            Check.Equal(1, owner.SqliteBusy.Count, "base attribuée à son propriétaire");
            Check.Equal(0, other.SqliteBusy.Count, "aucune contamination d’une autre session");
        }
        Check.False((await database.SearchIndexAsync(new("", scope, IndexSort.Name, false, 0, 200), None)).Busy, "nouvelle lecture explicite possible après libération");
    }
}
