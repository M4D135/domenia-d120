using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Reading = Domenia.Core.Queries.ProbeReading;

namespace Domenia.Tests;

/// <summary>The actual library, query evaluator and both widget consumers share the exact saved recipe; no remote reader.</summary>
internal static class AtelierBitLockerWidgetTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private const string Volumes = "sec.bitlockervolumes";
    private const string SystemMethod = "sec.bitlockermethodc";
    private static QueryLibrary Library() => new(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
    private static ProbeInstance Volume(string drive, object? method) => new(drive,
        ImmutableDictionary<string, object?>.Empty.Add("DriveLetter", drive).Add("EncryptionMethod", method), []);
    private static Reading Read(string probe, params ProbeInstance[] rows) => new(probe, Fixtures.Now.AddMinutes(-1), null, false, false, rows.Length, true,
        [.. rows.Select(row => probe == SystemMethod ? row with { Values = row.Values.Remove("DriveLetter") } : row)]);
    private static QueryDataset Dataset(string[] names, Reading?[] reads)
    {
        var computers = names.Select(n => Fixtures.Computer(n)).ToArray();
        var probes = ImmutableDictionary<Guid, ImmutableArray<Reading>>.Empty.ToBuilder();
        for (var i = 0; i < reads.Length; i++) { if (reads[i] is { } read) probes.Add(computers[i].ObjectGuid, [read]); }
        return new(Fixtures.Snapshot(computers: computers), new(null, []), probes.ToImmutable(),
            ImmutableDictionary<Guid, ConsoleReading>.Empty, ImmutableDictionary<Guid, char>.Empty,
            ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "Fixture BitLocker", true);
    }
    private static FleetComputation Fleet(QueryDataset dataset, QueryLibraryContent library, QuerySaveResult saved, string visual)
    {
        var widget = saved.Widget ?? throw new TestFailureException("Widget attendu.");
        var item = new FleetLayoutItem("q-" + widget.Id, FleetWidgetSource.Query, widget.Id, visual, "M", saved.Record.Name, false, "Requêtes");
        var input = new FleetBoardInput(new(dataset.Directory, dataset.Observations, [], []), new(Fixtures.Postes, "Postes", true),
            Fixtures.Root, Fixtures.Domain.DnsName, HealthPolicyBook.Empty(Fixtures.Root), AccueilFacts.Empty("test"), null,
            Domenia.Core.Accueil.ProbeReadings.Empty, [item], [], Fixtures.Now, TestClock.Paris);
        return FleetQueryWidgets.Apply(FleetBoardCalculator.Compute(input), input, new(library, dataset, null));
    }
    private static QueryRecipe Xts128SystemVolume() => QueryRecipe.Empty() with
    {
        Name = "Postes avec C: en XTS-AES 128", Clauses = [],
        Expression = QueryNode.Collection("probe:" + Volumes, CollectionQuantifier.Any,
            QueryNode.Group(QueryNodeKind.All,
            [
                QueryNode.Leaf(new("instance:" + Volumes + ":DriveLetter", QueryOperator.Equal, QueryValue.FromText("C:"))),
                QueryNode.Leaf(new("instance:" + Volumes + ":EncryptionMethod", QueryOperator.Equal, QueryValue.FromNumber(6))),
            ])),
    };

    [Test]
    public static async Task Saved_xts128_query_preserves_correlated_instances_and_unknown_in_both_widgets()
    {
        var dataset = Dataset(["XTS128", "XTS256", "Plain", "OtherVolume", "MissingCode", "Unread", "Refused"],
        [
            Read(Volumes, Volume("C:", 6u)), Read(Volumes, Volume("C:", 7u)), Read(Volumes, Volume("C:", 0u)),
            Read(Volumes, Volume("C:", 0u), Volume("D:", 6u)), Read(Volumes, Volume("C:", null), Volume("D:", 6u)),
            null, Read(Volumes, Volume("C:", 6u)) with { Error = "Accès refusé" },
        ]);
        using var library = Library();
        var saved = await library.SaveAsync(Fixtures.Root, Xts128SystemVolume(), null, null, 0, "update", new("fleet", "pie", "XTS 128"), None);
        var content = await library.ReadAsync(Fixtures.Root, None);
        var board = Fleet(dataset, content, saved, "Pie");
        var entry = board.Board.Entries["query:" + saved.Widget!.Id];
        Check.True(entry.Measured, "requête enregistrée réellement calculée");
        Check.Equal(1d, entry.Number!.Value, "un seul poste correspond sur la même instance C:");
        Check.Equal(3d, entry.Items.Single(p => p.Label == "Inconnus").Value, "code absent, non lu et refus restent inconnus");
        Check.Equal(3d, entry.Items.Single(p => p.Label == "Non correspondants").Value, "XTS 256, zéro explicite et autre volume sont distincts");
        Check.True(board.Targets[entry.TargetsKey!].SequenceEqual([Fixtures.IdOf("XTS128")]), "liste exacte du compteur");

        var computerSaved = await library.SaveAsync(Fixtures.Root, saved.Record.Recipe, null, null, saved.Record.Revision, "update", new("computer", "text", "XTS 128"), None);
        var prefs = new MemoryPreferenceStore();
        await PosteBoardLayouts.SaveAsync(prefs, "Computer", [], None);
        var latest = await library.ReadAsync(Fixtures.Root, None);
        await PosteQueryLayout.PlaceAsync(prefs, Fixtures.Root, computerSaved.Widget!, computerSaved.Record.Fingerprint, () => latest, None);
        var item = PosteBoardLayouts.Read(prefs, "Computer").Items.Single();
        var expected = new[] { "match", "noMatch", "noMatch", "noMatch", "unknown", "unknown", "unknown" };
        for (var i = 0; i < dataset.Directory.Computers.Length; i++)
        {
            var pc = dataset.Directory.Computers[i];
            var card = PosteQueryCards.Build(item, latest, dataset, pc.ObjectGuid, pc.DistinguishedName, Fixtures.Now);
            Check.Equal(expected[i], card.Verdict, "même recette sur " + pc.Name);
            Check.Equal(computerSaved.Record.Fingerprint, card.Fingerprint, "révision enregistrée confirmée");
        }
    }

    [Test]
    public static async Task System_volume_distribution_keeps_unknown_codes_separate_from_explicit_zero_and_exact_targets()
    {
        var dataset = Dataset(["XTS128", "XTS256", "Plain", "NullCode", "MissingCode", "Refused", "Empty", "Unread"],
        [
            Read(SystemMethod, Volume("C:", 6u)), Read(SystemMethod, Volume("C:", 7u)), Read(SystemMethod, Volume("C:", 0u)),
            Read(SystemMethod, Volume("C:", null)), Read(SystemMethod, new ProbeInstance("C:", ImmutableDictionary<string, object?>.Empty, [])),
            Read(SystemMethod, Volume("C:", 6u)) with { Error = "Accès refusé" }, Read(SystemMethod), null,
        ]);
        using var library = Library();
        var recipe = QueryRecipe.Empty() with { Name = "Méthode BitLocker de C:", GroupBy = "probe:" + SystemMethod };
        var saved = await library.SaveAsync(Fixtures.Root, recipe, null, null, 0, "update", new("fleet", "pie", recipe.Name), None);
        var board = Fleet(dataset, await library.ReadAsync(Fixtures.Root, None), saved, "Pie");
        var entry = board.Board.Entries["query:" + saved.Widget!.Id];
        Check.True(entry.Measured, "répartition valide");
        Check.Equal(8d, entry.Number!.Value, "tous les postes de la population restent représentés");
        Check.Equal(1d, entry.Items.Single(p => p.Label == "XTS-AES 128").Value, "code 6 libellé");
        Check.Equal(1d, entry.Items.Single(p => p.Label == "XTS-AES 256").Value, "code 7 libellé");
        Check.Equal(1d, entry.Items.Single(p => p.Label == "Non chiffré").Value, "seul le zéro réellement lu");
        var missing = entry.Items.Single(p => p.Label == "Valeur inconnue");
        Check.Equal(5d, missing.Value, "aucune valeur n’est inventée à partir d’une lecture absente, vide ou refusée");
        var ids = new HashSet<Guid>();
        foreach (var part in entry.Items)
        {
            Check.Equal(part.Value, (double)board.Targets[part.TargetsKey].Length, "détail exact de la part");
            foreach (var id in board.Targets[part.TargetsKey]) { Check.True(ids.Add(id), "chaque poste compté une seule fois"); }
        }
        Check.Equal(8, ids.Count, "partition complète de la population");
    }

    [Test]
    public static void Fresh_bitlocker_cache_is_reused_and_force_only_requests_the_required_probe()
    {
        var dataset = Dataset(["Fresh", "Old", "Unread", "Error"],
        [
            Read(SystemMethod, Volume("C:", 6u)), Read(SystemMethod, Volume("C:", 7u)) with { CheckedAt = Fixtures.Now.AddDays(-2) },
            null, Read(SystemMethod, Volume("C:", 6u)) with { Error = "WMI indisponible" },
        ]);
        var recipe = QueryRecipe.Empty() with { Name = "Répartition de C:", GroupBy = "probe:" + SystemMethod };
        var query = QueryEngine.Compile(recipe);
        var records = QueryRecordBuilder.Build(dataset, QueryTarget.Computer, new(Fixtures.Postes, "Postes", true), Fixtures.Now);
        var context = new QueryEvaluationContext(null, Fixtures.Now);
        var normal = QueryAnalysis.CollectPlan(query, records, context, Fixtures.Now);
        Check.Equal(1L, normal.Reused, "lecture récente réutilisée");
        Check.Equal(3, normal.Targets.Length, "seuls absent, ancien et erreur demandent une lecture");
        var force = QueryAnalysis.CollectPlan(query, records, context, Fixtures.Now, cacheMinutes: 0);
        Check.Equal(4, force.Targets.Length, "forcer ignore le cache récent");
        Check.True(force.Targets.All(t => t.MissingProbes.SequenceEqual([SystemMethod])), "aucune sonde annexe ni inventaire complet");
        Check.False(force.Inventory || force.Console, "plan limité au besoin BitLocker");
    }
}
