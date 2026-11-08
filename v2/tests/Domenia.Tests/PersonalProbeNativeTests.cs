using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;
using ProbeCatalog = Domenia.Core.Accueil.ProbeCatalog;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

/// <summary>Native boundary with an injected CIM session; never a real provider or directory during these checks.</summary>
internal static class PersonalProbeNativeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(p => p.Name, p => p.Value));

    [Test]
    public static async Task Tampered_declarations_and_AD_controllers_are_refused_before_any_native_session()
    {
        var entry = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var changed = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model")).Single();
        var sessions = 0; var reader = new WmiFleetProbeReader(TestClock.Fixed())
        { SessionFactory = (_, _, _) => { Interlocked.Increment(ref sessions); throw new TestFailureException("Aucun transport ne doit être construit."); } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadFrozenAsync(Fixtures.Computer("PC1"),
            [entry with { Definition = changed.Definition }], None), "autre déclaration complète et valide sous la même clé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadFrozenAsync(Fixtures.Computer("PC1"),
            [entry with { Definition = entry.Definition with { Slow = false } }], None), "collecte implicite refusée");
        var result = await reader.ReadFrozenAsync(Fixtures.Computer("DC1") with { UserAccountControl = AdValues.ServerTrustAccount }, [entry], None);
        Check.Equal(MeasureState.NotRead, result[entry.Key].State, "contrôleur exclu sans valeur fictive");
        Check.Equal(0, sessions, "refus avant admission du travail natif");
    }

    [Test]
    public static async Task CIM_role_and_identity_are_required_before_custom_SELECT_with_the_existing_budget()
    {
        var entry = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        foreach (var role in new int?[] { null, 4, 5, 1 })
        {
            var queries = new List<string>(); var clock = TestClock.Fixed();
            var reader = new WmiFleetProbeReader(clock)
            {
                SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
                {
                    ReadOverride = (_, query, _) =>
                    {
                        queries.Add(query);
                        return query.Contains("DomainRole", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", role))]
                            : [Row(("Manufacturer", "Fabricant physique"))];
                    },
                },
            };
            var result = await reader.ReadFrozenAsync(Fixtures.Computer("PC1"), [entry], None);
            Check.Equal("SELECT Name, DNSHostName, Domain, DomainRole FROM Win32_ComputerSystem", queries[0], "même contrôle d’identité, rôle ajouté à la même projection");
            if (role != 1)
            {
                Check.Equal(1, queries.Count, "aucun SELECT personnel sur rôle inconnu ou contrôleur");
                Check.Equal(MeasureState.NotRead, result[entry.Key].State, "absence de mesure explicite");
            }
            else
            {
                Check.Equal(2, queries.Count, "identité puis projection explicite seulement");
                Check.Equal("SELECT Manufacturer FROM Win32_ComputerSystem", queries[1], "projection originale exécutée");
                Check.Equal("Fabricant physique", result[entry.Key].Values.Single(), "valeur sous la clé immuable");
                Check.False(result.ContainsKey(entry.Definition.Id), "aucune mesure indexée par alias");
            }
        }
    }

    [Test]
    public static void First_all_count_and_partial_results_keep_the_existing_projection_semantics()
    {
        foreach (var mode in new[] { "First", "All", "Count" })
        {
            var entry = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document(mode: mode)).Single();
            var measured = WmiFleetProbeReader.Project(entry.RuntimeDefinition,
                new("personnelle", SourceStatus.Ok, "lu", 1, [Row(("Manufacturer", "A")), Row(("Manufacturer", "B"))]), Fixtures.Now);
            Check.True(measured.Values.SequenceEqual(mode switch { "First" => ["A"], "All" => ["A", "B"], _ => ["2"] }), "valeurs de " + mode);
            var partial = WmiFleetProbeReader.Project(entry.RuntimeDefinition,
                new("personnelle", SourceStatus.Partial, "plafond", 1, [Row(("Manufacturer", "A"))]), Fixtures.Now);
            Check.Equal(MeasureState.Incomplete, partial.State, "partiel non promu en complet");
            Check.True(partial.Values.IsEmpty, "aucun faux total ou répartition complète");
        }
    }

    [Test]
    public static async Task Directory_reader_persists_frozen_custom_key_and_refuses_a_rebound_target_before_the_probe()
    {
        var pc = Fixtures.Computer("PC1"); var entry = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc]));
        cache.Fleet = cache.Fleet.Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero))]) });
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(None); var called = 0;
        var reader = new AdAccueilReader(source)
        {
            ProbeOverride = (_, keys, _) =>
            {
                called++;
                Check.True(keys.SequenceEqual([entry.Key]), "frontière AD conserve la clé figée");
                return Task.FromResult(ImmutableDictionary<string, ProbeReading>.Empty.Add(entry.Key, new(MeasureState.Known, Fixtures.Now, ["Fabricant"], null)));
            },
        };
        var targets = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(pc.ObjectGuid, QueryComputerIdentity.Of(pc));
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectFrozenProbesAsync([entry], new(Fixtures.Postes, "Postes", true),
            targets.SetItem(pc.ObjectGuid, targets[pc.ObjectGuid] with { Host = "other.test.local" }), source.Epoch, None), "réaffectation avant contact");
        Check.Equal(0, called, "aucune sonde après refus de cible");
        await reader.CollectFrozenProbesAsync([entry], new(Fixtures.Postes, "Postes", true), targets, source.Epoch, None);
        Check.Equal("Fabricant", (await reader.StoredProbesAsync(None)).ByProbe[entry.Key][pc.ObjectGuid].Values.Single(), "commit relu via lecteur réel");
        Check.Equal(1, called, "un seul relevé explicite");
    }
}
