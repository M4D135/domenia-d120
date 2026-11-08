using Domenia.Core;

namespace Domenia.Tests;

internal static class ReadPerformanceTests
{
    private static readonly ReadPerformanceSample Sample = new(ReadPerformanceMethod.WinRm, "Query", 25, 70, ReadPerformanceOutcome.Success);

    [Test]
    public static async Task Read_timing_scopes_follow_the_worker_and_restore_the_parent_without_a_global_history()
    {
        var outer = new List<ReadPerformanceSample>(); var inner = new List<ReadPerformanceSample>();
        Check.False(ReadPerformance.Observed, "aucune mesure permanente");
        using (ReadPerformance.Observe(outer.Add))
        {
            await Task.Run(() => ReadPerformance.Publish(Sample));
            using (ReadPerformance.Observe(inner.Add)) { ReadPerformance.Publish(Sample with { Method = ReadPerformanceMethod.Ping }); }
            ReadPerformance.Publish(Sample with { Retry = 1 });
        }
        ReadPerformance.Publish(Sample);
        Check.Equal(2, outer.Count, "parent restauré, aucune publication après fermeture");
        Check.Equal(1, inner.Count, "opération imbriquée isolée");
        Check.Equal(25L, outer[0].QueueMs, "attente séparée");
        Check.Equal(70L, outer[0].ExecutionMs, "exécution réelle séparée");
        Check.Equal(1, outer[1].Retry, "nouvel essai explicite");
        Check.False(ReadPerformance.Observed, "observer libéré");
    }

    [Test]
    public static async Task Explicit_retry_numbers_follow_only_the_corresponding_worker_attempt()
    {
        var values = new List<ReadPerformanceSample>();
        using var observer = ReadPerformance.Observe(values.Add);
        using (ReadPerformance.Attempt(1)) { await Task.Run(() => ReadPerformance.Publish(Sample)); }
        ReadPerformance.Publish(Sample);
        Check.Equal(1, values[0].Retry, "reprise explicitement mesurée");
        Check.Equal(0, values[1].Retry, "lecture suivante indépendante");
    }

    [Test]
    public static void A_failed_measurement_observer_never_replaces_a_read_result_or_repeats_its_failure()
    {
        var calls = 0;
        using var observation = ReadPerformance.Observe(_ => { calls++; throw new InvalidOperationException("must not escape or be logged"); });
        ReadPerformance.Publish(Sample);
        ReadPerformance.Publish(Sample);
        Check.Equal(1, calls, "observer défaillant arrêté, lecture non perturbée");
        Check.Equal(0L, ReadPerformance.Milliseconds(TimeSpan.FromMilliseconds(-5)), "horloge bornée");
    }
}
