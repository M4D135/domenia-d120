using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class ProviderReadMeasuresTests
{
    [Test]
    public static void Completed_samples_have_bounded_provider_specific_waits_and_do_not_count_cache_hits_as_native_work()
    {
        var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), false);
        using var measurements = OperationsMeasurements.Enter(activity);
        var campaignSamples = 0;
        using var campaign = ReadPerformance.Observe(_ => campaignSamples++);
        for (var i = 1; i <= 600; i++) ReadPerformance.Publish(new(ReadPerformanceMethod.Ldap, "search", i, 2 * i, ReadPerformanceOutcome.Success));
        ReadPerformance.Publish(new(ReadPerformanceMethod.WmiDcom, "Query", 5, 200, ReadPerformanceOutcome.Partial) { StartupMs = 70 });
        ReadPerformance.Publish(new(ReadPerformanceMethod.WmiDcom, "Query", 0, 0, ReadPerformanceOutcome.Success, CacheHit: true));
        var directory = activity.ProviderMeasuresSnapshot().Single(s => s.Method == ReadPerformanceMethod.Ldap);
        Check.Equal(600L, directory.Attempts, "toutes les tentatives terminées comptées");
        Check.Equal(512, directory.Admission.Count, "série bornée à512");
        Check.Equal(600d, directory.Admission.Max!.Value, "attente indépendante");
        Check.Equal(1200d, directory.Execution.Max!.Value, "exécution indépendante");
        Check.True(directory.Execution.P95Stated, "percentile sur assez de mesures");
        var cim = activity.ProviderMeasuresSnapshot().Single(s => s.Method == ReadPerformanceMethod.WmiDcom);
        Check.Equal(1L, cim.Attempts, "cache ne fabrique pas une nouvelle tentative"); Check.Equal(1L, cim.CacheHits, "cache séparé");
        Check.Equal(0L, cim.Successful, "partiel n’est pas complet");
        Check.Equal(70d, cim.Startup.Max!.Value, "démarrage séparé, inclus dans les200ms mesurées");
        Check.Equal(602, campaignSamples, "observateur campagne existant conservé");
    }

    [Test]
    public static async Task Real_child_startup_is_measured_once_while_its_second_request_reuses_the_authenticated_pipe()
    {
        var activity = new OperationActivity(TimeProvider.System, new RecordingJournal(), false);
        using var measurements = OperationsMeasurements.Enter(activity);
        var samples = new List<ReadPerformanceSample>(); using var observer = ReadPerformance.Observe(samples.Add);
        using var client = new NativeReadClient(new("PC-TEST", InventoryTransport.Dcom, 60000, true, null, false, false), null, default,
            adaptive: new AdaptiveReadBudget(TimeProvider.System));
        var query = new NativeReadRequest(NativeReadKind.Query, 20000)
        { Category = "Fixture", Namespace = @"root\cimv2", Query = "SELECT Name FROM Win32_ComputerSystem", MaxItems = 1 };
        Check.Equal(SourceStatus.Skipped, (await client.ReadAsync(query)).Reading!.Status, "sans contact réseau");
        Check.Equal(SourceStatus.Skipped, (await client.ReadAsync(query)).Reading!.Status, "réutilisation du même enfant");
        Check.True(samples[0].StartupMs is >= 0 && samples[0].StartupMs <= samples[0].ExecutionMs, "handshake réel inclus dans durée totale");
        Check.Null(samples[1].StartupMs, "pas de temps de création fabriqué au deuxième appel");
        var saved = activity.ProviderMeasuresSnapshot().Single();
        Check.Equal(2, saved.Execution.Count, "deux appels terminés"); Check.Equal(1, saved.Startup.Count, "un seul démarrage observé");
    }
}
