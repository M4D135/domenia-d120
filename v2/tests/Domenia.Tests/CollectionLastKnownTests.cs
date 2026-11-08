using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class CollectionLastKnownTests
{
    [Test]
    public static async Task An_inventory_failure_days_later_keeps_one_dated_success_across_native_reopen()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var clock = TestClock.Fixed();
        var db = new DomeniaDatabase(folder.File("history.db"), Fixtures.Root, clock);
        await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", default);
        var successful = Fixtures.Disk(100, 40, TimeSpan.FromDays(10), TimeSpan.FromDays(11));
        var seen = Fixtures.Presence(true, TimeSpan.FromDays(10));
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now.AddDays(-10), [Fixtures.Observe(pc, seen, successful)]) }, default);
        var failed = InventoryMeasure.Unread with { State = MeasureState.Error, CheckedAt = Fixtures.Now };
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(pc,
            new(MeasureState.Error, null, Fixtures.Now, null), failed)]) }, default);
        var cold = await new DomeniaDatabase(db.Path, Fixtures.Root, clock).ReadFleetAsync(default);
        var observed = cold.Observations.Find(pc.ObjectGuid)!;
        Check.Equal(MeasureState.Error, observed.Inventory.State, "échec réel toujours visible");
        Check.Equal(Fixtures.Now, observed.Inventory.CheckedAt, "date de la tentative");
        Check.Equal(successful, observed.Inventory.LastSuccessful, "aucune limite de quinze minutes qui efface le dernier succès");
        Check.Equal(seen.LastOnlineAt, observed.Presence.LastOnlineAt, "dernière présence conservée sans nouveau ping positif");
        Check.False(observed.Inventory.HasReading || observed.Presence.HasReading, "aucun échec converti en succès récent");
        Check.Equal(successful.CheckedAt, observed.Inventory.LastKnown!.CheckedAt, "affichage historique conserve sa date");
        var latest = InventoryMeasure.Merge(observed.Inventory, failed with { CheckedAt = Fixtures.Now.AddHours(1) });
        Check.Null(latest.LastSuccessful!.LastSuccessful, "un seul niveau de succès historique");
        var purged = StorageFleetRetention.Transform(cold, (_, family, at) => family == "inventory" && at < Fixtures.Now.AddDays(-5));
        Check.Null(purged.Observations.Find(pc.ObjectGuid)!.Inventory.LastSuccessful, "historique purgé selon sa propre date");
        Check.Equal(MeasureState.Error, purged.Observations.Find(pc.ObjectGuid)!.Inventory.State, "la purge historique laisse la tentative récente");
    }

    [Test]
    public static async Task Partial_bitlocker_pass_preserves_other_GUIDs_without_rejuvenating_them_and_explicit_zero_replaces_keys()
    {
        using var folder = new TemporaryFolder(); var first = Fixtures.Computer("PC1"); var second = Fixtures.Computer("PC2");
        var db = new DomeniaDatabase(folder.File("bitlocker.db"), Fixtures.Root, TestClock.Fixed()); await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [first, second]), new(Fixtures.Postes, "Postes", true), "DC1", default);
        var earlier = Fixtures.Now.AddDays(-2);
        var before = new BitLockerPresence(Fixtures.Postes, true, earlier, true, false,
            ImmutableDictionary<Guid, BitLockerFact>.Empty.Add(first.ObjectGuid, new(1, earlier)).Add(second.ObjectGuid, new(2, earlier)));
        await db.SaveFleetAsync(FleetCachePatch.Empty with { BitLocker = [before] }, default);
        var partial = before with { At = Fixtures.Now, Truncated = true,
            Machines = ImmutableDictionary<Guid, BitLockerFact>.Empty.Add(first.ObjectGuid, new(3, Fixtures.Now)) };
        await db.SaveFleetAsync(FleetCachePatch.Empty with { BitLocker = [partial] }, default);
        var read = (await new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(default)).Facts.BitLocker.Single();
        Check.Equal(2, read.Machines.Count, "poste non relu conservé"); Check.Equal(3, read.Machines[first.ObjectGuid].Keys, "poste relu actualisé");
        Check.Equal(earlier, read.Machines[second.ObjectGuid].ObservedAt, "aucun rajeunissement par le lot voisin");
        var zero = partial with { Machines = ImmutableDictionary<Guid, BitLockerFact>.Empty.Add(second.ObjectGuid, new(0, null)) };
        await db.SaveFleetAsync(FleetCachePatch.Empty with { BitLocker = [zero] }, default);
        var final = (await db.ReadFleetAsync(default)).Facts.BitLocker.Single();
        Check.Equal(0, final.Machines[second.ObjectGuid].Keys, "zéro explicitement observé admis");
        Check.Equal(3, final.Machines[first.ObjectGuid].Keys, "aucun effacement des autres GUID");
    }

    [Test]
    public static void Sessions_observed_before_the_known_boot_are_not_reused_even_for_the_same_AD_account()
    {
        var earlier = Fixtures.Now.AddHours(-2);
        var success = new WorkstationSessionRead(earlier, SourceStatus.Empty, [], 0, "fixture", null);
        var cached = new WorkstationSessionMemory("PC1", success, success);
        var created = Fixtures.Now.AddDays(-300); var boot = Fixtures.Now.AddHours(-1);
        Check.Null(PosteSessionCache.Applicable(cached, created, Fixtures.Now, boot), "session du démarrage précédent exclue");
        var failure = new WorkstationSessionRead(Fixtures.Now, SourceStatus.Error, [], 0, "fixture", null);
        var current = PosteSessionCache.Applicable(new("PC1", failure, success), created, Fixtures.Now, boot);
        Check.NotNull(current, "tentative après démarrage conservée"); Check.Null(current!.LastComplete, "ancien succès non réutilisable après reboot");
        Check.NotNull(PosteSessionCache.Applicable(cached, created, Fixtures.Now), "aucun démarrage inventé lorsqu’il n’est pas connu");
    }
}
