using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class QueryIdentityCacheTests
{
    private static readonly DirectoryComputer Pc = Fixtures.Computer("CACHE-ID") with { WhenCreated = Fixtures.Now.AddYears(-3) };
    private static ProbeReading Reading(string id = "hw.model", string property = "Model", string value = "Latitude") => new(id,
        Fixtures.Now.AddYears(-1), null, false, false, 1, true,
        [new("one", ImmutableDictionary<string, object?>.Empty.Add(property, value), [])]) { Identity = QueryComputerIdentity.Of(Pc) };
    private static QueryRecord Record(ProbeReading reading, DirectoryComputer? pc = null)
    {
        var dataset = new QueryDataset(Fixtures.Snapshot(computers: [pc ?? Pc]), new(null, []),
            ImmutableDictionary<Guid, ImmutableArray<ProbeReading>>.Empty.Add(Pc.ObjectGuid, [reading]),
            ImmutableDictionary<Guid, ConsoleReading>.Empty, ImmutableDictionary<Guid, char>.Empty,
            ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "cache", true);
        return QueryRecordBuilder.Build(dataset, QueryTarget.Computer, null, Fixtures.Now).Single();
    }
    private static QueryCollectPlan Plan(QueryRecord record, int cache = 15) => QueryAnalysis.CollectPlan(
        QueryEngine.Compile(QueryRecipe.Empty() with { Name = "Modèle", GroupBy = "probe:hw.model" }), [record], new(null, Fixtures.Now), Fixtures.Now, cache);

    [Test]
    public static void Qualified_identity_fact_survives_time_but_force_still_collects()
    {
        var record = Record(Reading());
        Check.Equal("Latitude", (string)record.Value("probe:hw.model")!, "valeur ancienne qualifiée conservée");
        Check.Equal(0, Plan(record).Targets.Length, "pas de requête distante pour un fait stable qualifié");
        Check.Equal(1, Plan(record, 0).Targets.Length, "cache désactivé force réellement une nouvelle lecture");
        Check.Equal(1, QueryAnalysis.CollectPlan(QueryEngine.Compile(QueryRecipe.Empty() with { Name = "Modèle", GroupBy = "probe:hw.model" }),
            [record], new(null, Fixtures.Now), Fixtures.Now, freshnessSeconds: new Dictionary<string, int> { ["staticProbe"] = 0 }).Targets.Length,
            "désactiver la réutilisation de la famille stable est respecté");
        Check.Equal(Fixtures.Now.AddYears(-1), record.Clocks["probe:hw.model"], "aucune date artificiellement rajeunie");
    }

    [Test]
    public static void Legacy_errors_placeholders_and_reincarnations_never_become_permanent()
    {
        var good = Reading();
        foreach (var reading in new[] { good with { Identity = null }, good with { Error = "Refus" }, good with { Truncated = true },
            good with { CheckedAt = Fixtures.Now.AddMinutes(10) }, Reading(value: "unknown"),
            Reading(value: "To be filled by O.E.M."), good with { Identity = good.Identity! with { Sid = null } } })
        { Check.Equal(1, Plan(Record(reading)).Targets.Length, "lecture dégradée ou ancienne non qualifiée à refaire"); }
        foreach (var changed in new[] { Pc with { Sid = "S-1-5-21-999-999-999-1234" }, Pc with { DnsHostName = "other.test.local" },
            Pc with { WhenCreated = Pc.WhenCreated.AddDays(1) }, Pc with { SamAccountName = "OTHER$" } })
        { Check.Null(Record(good with { CheckedAt = Fixtures.Now }, changed).Value("probe:hw.model"), "autre identité refuse même une mesure récente"); }
        Check.Null(Record(Reading("os.caption", "Caption", "Windows 11")).Value("probe:os.caption"), "Windows reste soumis à la fraîcheur normale");
    }
}
