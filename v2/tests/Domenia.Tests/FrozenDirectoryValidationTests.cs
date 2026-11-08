using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class FrozenDirectoryValidationTests
{
    [Test]
    public static void Hundred_thousand_probe_groups_reuse_only_the_same_immutable_validated_directory()
    {
        var computers = Enumerable.Range(0, 100_000).Select(i => Fixtures.Computer("GROUP-" + i)).ToImmutableArray();
        var directory = Fixtures.Snapshot(computers: computers);
        var identities = computers.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var guard = new FrozenDirectoryValidation();
        var index = AdComputerIndex.For(directory);
        Check.True(guard.Confirm(directory, identities), "une validation complète avant le premier groupe");
        foreach (var computer in computers)
        {
            Check.False(guard.Confirm(directory, identities), "aucun nouveau scan du parc pour un autre groupe");
            Check.True(ReferenceEquals(index, AdComputerIndex.For(directory)), "index partagé par photographie immuable");
            Check.Equal(computer, index.Find(computer.ObjectGuid), "cible retrouvée sans parcours du parc");
        }
        var changed = directory with { Computers = computers.SetItem(computers.Length - 1, computers[^1] with { DnsHostName = "renamed.test.local" }) };
        Check.Throws<DomeniaOperationException>(() => guard.Confirm(changed, identities), "changement tardif du dernier poste refusé avant le groupe suivant");
        Check.Equal("renamed.test.local", AdComputerIndex.For(changed).Find(computers[^1].ObjectGuid)!.DnsHostName, "nouvelle photographie jamais masquée par l’index précédent");
    }

    [Test]
    public static void Changing_frozen_identities_or_replacing_a_snapshot_cannot_reuse_its_validation()
    {
        var computer = Fixtures.Computer("PC1"); var snapshot = Fixtures.Snapshot(computers: [computer]);
        var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(computer.ObjectGuid, QueryComputerIdentity.Of(computer));
        var guard = new FrozenDirectoryValidation(); Check.True(guard.Confirm(snapshot, identities), "validation initiale");
        var altered = identities.SetItem(computer.ObjectGuid, QueryComputerIdentity.Of(computer with { Sid = "S-1-5-21-1-2-3-999" }));
        Check.Throws<DomeniaOperationException>(() => guard.Confirm(snapshot, altered), "un with des cibles ne réutilise pas l’ancien contrôle");
        Check.True(guard.Confirm(snapshot with { ReadAt = snapshot.ReadAt.AddSeconds(1) }, identities), "une nouvelle photographie est contrôlée, même si seules métadonnées changent");
        var duplicate = snapshot with { Computers = [computer, computer] };
        Check.Throws<ArgumentException>(() => guard.Confirm(duplicate, identities), "doublons non masqués par le cache");
        Check.Null(AdComputerIndex.For(duplicate).Find(computer.ObjectGuid), "index refuse une identité ambiguë");
    }
}
