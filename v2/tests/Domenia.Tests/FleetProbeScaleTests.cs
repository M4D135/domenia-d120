using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class FleetProbeScaleTests
{
    [Test]
    public static void One_probe_category_of_hundred_thousand_workstations_keeps_exact_drill_down_targets()
    {
        var computers = Enumerable.Range(0, 100_000).Select(i => Fixtures.Computer("FLEET-" + i)).ToImmutableArray();
        var readings = computers.ToImmutableDictionary(c => c.ObjectGuid, _ => new ProbeReading(MeasureState.Known, Fixtures.Now, ["Acme"], null) { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find("hw.maker")!) });
        var probes = new ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>>.Empty.Add("hw.maker", readings));
        var item = new FleetLayoutItem("maker", FleetWidgetSource.Probe, "hw.maker", "Pie", "M", null, false, "Matériel");
        var input = new FleetBoardInput(new(Fixtures.Snapshot(computers: computers), FleetObservations.Empty, [], []), new(Fixtures.Postes, "Postes", true),
            Fixtures.Root, Fixtures.Domain.DnsName, HealthPolicyBook.Empty(Fixtures.Root), AccueilFacts.Empty("scale"), null, probes, [item], [], Fixtures.Now, TestClock.Paris);
        var board = FleetBoardCalculator.Compute(input);
        var entry = board.Board.Entries["probe:hw.maker"]; var part = entry.Items.Single();
        Check.Equal("Acme", part.Label, "catégorie exacte"); Check.Equal(100_000d, part.Value, "compteur non tronqué");
        var targets = board.Targets[part.TargetsKey];
        Check.Equal(100_000, targets.Length, "détails exacts conservés avant pagination UI");
        Check.True(targets.ToHashSet().SetEquals(computers.Select(c => c.ObjectGuid)), "ni doublon ni perte dans la part de100000 postes");
        Check.True(entry.Measured, "dessin local réellement calculé");
    }
}
