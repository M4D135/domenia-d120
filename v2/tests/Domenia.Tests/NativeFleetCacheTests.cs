using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeFleetCacheTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Fleet_decode_cache_compares_persisted_content_even_when_revision_did_not_change()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("cache.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        var pc = Fixtures.Computer("PC1");
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", None);
        var saved = await database.SaveFleetAsync(Patch(pc, Fixtures.Presence(true, TimeSpan.Zero)), None);
        var unchanged = await database.ReadFleetAsync(None);
        Check.True(ReferenceEquals(saved.Probes, unchanged.Probes), "charge inchangée réutilisée sans nouvelle désérialisation");
        var altered = saved with { Observations = new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.Zero))]) };
        using (var db = new SqliteDatabase(database.Path, false))
        {
            db.Execute("UPDATE domenia_v2_metadata SET payload=?1 WHERE key='fleet';", JsonSerializer.Serialize(altered, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
            db.Execute("INSERT INTO user_machine_links(computer_key,user_login,source) VALUES('PC1','alice','Saisie manuelle');");
        }
        var reread = await database.ReadFleetAsync(None);
        Check.Equal(false, reread.Observations.Workstations.Single().Presence.Answered, "écriture extérieure sans révision détectée");
        Check.Equal(1, reread.Facts.Associations, "associations recomptées même quand les relevés sont mémorisés");
        var unknown = Fixtures.Computer("UNKNOWN");
        await Check.ThrowsAsync<InvalidDataException>(() => database.SaveFleetAsync(Patch(unknown, Fixtures.Presence(true, TimeSpan.Zero)), None), "identité absente refusée");
        Check.Equal(1, (await database.ReadFleetAsync(None)).Observations.Workstations.Length, "échec sans mutation du cache");
    }

    [Test]
    public static async Task Two_database_instances_merge_only_committed_fleet_and_preserve_newer_measurements()
    {
        using var folder = new TemporaryFolder();
        var first = new DomeniaDatabase(folder.File("shared.db"), Fixtures.Root, TestClock.Fixed());
        await first.InitializeAsync(None);
        var a = Fixtures.Computer("A"); var b = Fixtures.Computer("B");
        await first.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [a, b]), new(Fixtures.Postes, "Postes", true), "DC1", None);
        await first.SaveFleetAsync(Patch(a, Fixtures.Presence(true, TimeSpan.Zero)), None);
        var other = new DomeniaDatabase(first.Path, Fixtures.Root, TestClock.Fixed());
        await other.InitializeAsync(None);
        await other.SaveFleetAsync(Patch(b, Fixtures.Presence(true, TimeSpan.Zero)), None);
        var merged = await first.SaveFleetAsync(Patch(a, Fixtures.Presence(false, TimeSpan.FromHours(1))), None);
        Check.Equal(2, merged.Observations.Workstations.Length, "l’autre instance n’est pas écrasée par une copie en mémoire");
        Check.True(merged.Observations.Workstations.All(x => x.Presence.Answered == true), "résultat tardif plus ancien ignoré");
        Check.Equal(2, (await new DomeniaDatabase(first.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(None)).Observations.Workstations.Length, "format historique relu à froid");
    }

    [Test]
    public static async Task Same_object_moved_in_AD_keeps_cache_but_changed_endpoint_invalidates_only_that_machine()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("identity.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None);
        var a = Fixtures.Computer("A"); var b = Fixtures.Computer("B");
        var root = new ScopeSelection(Fixtures.Root, "Domaine", true);
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [a, b]), root, "DC1", None);
        await database.SaveFleetAsync(Patch(a, Fixtures.Presence(true, TimeSpan.Zero)), None);
        await database.SaveFleetAsync(Patch(b, Fixtures.Presence(true, TimeSpan.Zero)), None);
        var moved = a with { DistinguishedName = "CN=A,OU=Autre," + Fixtures.Root, Description = "nouvelle description" };
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [moved, b], readAt: Fixtures.Now.AddMinutes(-5)), root, "DC1", None);
        Check.Equal(2, (await database.ReadFleetAsync(None)).Observations.Workstations.Length, "même objet déplacé, relevés gardés");
        var replaced = moved with { DnsHostName = "different.test.local" };
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [replaced, b], readAt: Fixtures.Now), root, "DC1", None);
        var current = await database.ReadFleetAsync(None);
        Check.Equal(b.ObjectGuid, current.Observations.Workstations.Single().ComputerGuid, "seul l’hôte différent perd ses anciennes mesures");
        // A late directory response cannot restore the former endpoint or discard the other workstation's cache.
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [a, b]), root, "DC1", None);
        Check.Equal(b.ObjectGuid, (await database.ReadFleetAsync(None)).Observations.Workstations.Single().ComputerGuid, "ancien lot sans réintroduction de mesures");
    }

    private static FleetCachePatch Patch(DirectoryComputer computer, PresenceMeasure presence) => FleetCachePatch.Empty with
    { Observations = new(presence.CheckedAt, [Fixtures.Observe(computer, presence)]) };
}
