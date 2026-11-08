using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdLargeFleetReaderTests
{
    [Test]
    public static void Hundred_thousand_computers_share_one_local_index_without_reusing_an_identity_from_another_picture()
    {
        var computers = Enumerable.Range(0, 100_000).Select(i => Fixtures.Computer("PC-" + i)).ToImmutableArray();
        var picture = Fixtures.Snapshot(computers: computers);
        var index = AdComputerIndex.For(picture);
        foreach (var computer in computers)
            Check.True(ReferenceEquals(computer, index.Find(computer.ObjectGuid)), "chaque poste retrouvé sans parcours répété du parc");
        Check.True(ReferenceEquals(index, AdComputerIndex.For(picture)), "index partagé entre lecteurs de la même image");
        var recreated = computers[0] with { WhenCreated = computers[0].WhenCreated.AddDays(1), Sid = "S-1-5-21-1-2-3-1111" };
        var next = picture with { Computers = computers.SetItem(0, recreated) };
        Check.True(ReferenceEquals(recreated, AdComputerIndex.For(next).Find(recreated.ObjectGuid)), "nouvelle image, nouvelle identité");
        Check.True(ReferenceEquals(computers[0], index.Find(recreated.ObjectGuid)), "le plan précédent reste immuable");
        var ambiguous = Fixtures.Snapshot(computers: [computers[0], recreated, computers[1] with { ObjectGuid = Guid.Empty }]);
        Check.Null(AdComputerIndex.For(ambiguous).Find(recreated.ObjectGuid), "GUID ambigu refusé");
        Check.Null(AdComputerIndex.For(ambiguous).Find(Guid.Empty), "identité absente refusée");
    }

    [Test]
    public static async Task Large_directory_census_keeps_small_pages_sequential_classes_and_a_truncation_sentinel()
    {
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        await AdDirectoryReader.ReadSnapshotAsync(connection, Fixtures.Domain, new(Fixtures.Postes, "Postes", true), 100_000,
            TestClock.Fixed(), default);
        Check.Equal(5, connection.Searches.Count, "une recherche par classe, pas une par poste");
        foreach (var request in connection.Searches)
        {
            Check.Equal(100_001, request.SizeLimit, "une entrée supplémentaire prouve une troncature");
            Check.Equal(1000, request.PageSize, "pas de page géante pour les grands parcs");
            Check.Equal(TimeSpan.FromSeconds(500), request.Budget, "budget global ajusté au nombre de pages");
            Check.Equal(TimeSpan.FromSeconds(60), request.Timeout, "délai par page conservé");
            Check.False(request.Attributes.Contains("*"), "projection des attributs nécessaires");
        }
        Check.Equal(TimeSpan.FromMinutes(3), AdDirectoryReader.SnapshotBudget(3500), "petit parc garde un budget prudent");
        Check.Equal(TimeSpan.FromMinutes(15), AdDirectoryReader.SnapshotBudget(int.MaxValue), "plafond absolu sans dépassement entier");
        foreach (var requested in new[] { -1, 0, 1, 500, 1000, 2000, int.MaxValue })
            Check.True(AdConnection.EffectivePageSize(requested) is >= 1 and <= 1000, "taille des réponses bornée");
    }
}
