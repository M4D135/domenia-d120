using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CollectionPreferenceContractTests
{
    private static async Task<JsonElement> Set(SimulatedBridge bridge, object value) =>
        SimulatedBridge.Json(await bridge.CallAsync("settings.collection.set", JsonSerializer.Serialize(value)));

    [Test]
    public static async Task Three_profiles_have_exact_families_and_real_windows_and_reset_is_scoped_to_the_active_profile()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        foreach (var (profile, expected) in new[]
        {
            ("standard", new[] { 120, 300, 900, 300, 900, 60 }),
            ("slowNetwork", new[] { 600, 900, 3600, 3600, 14400, 300 }),
            ("troubleshooting", new[] { 30, 60, 300, 120, 300, 30 }),
        })
        {
            await Set(bridge, new { profile });
            var settings = CollectionAdmission.Read(context.Preferences);
            Check.True(CollectionSettingsRules.FreshnessTable(settings).Select(f => f.Seconds).SequenceEqual(expected), profile + " six durées exactes");
            var closedWednesday = new DateTimeOffset(2026, 10, 21, 9, 0, 0, TimeSpan.Zero); // 11 h Paris
            var state = CollectionSettingsRules.CheckWindow(CollectionSettingsRules.WindowText(settings), closedWednesday, TestClock.Paris);
            Check.Equal(profile != "slowNetwork", state.Open, "fenêtre réelle du profil");
            Check.True(CollectionSettingsRules.CheckWindow(CollectionSettingsRules.WindowText(settings), closedWednesday.AddHours(9), TestClock.Paris).Open, "soirée ouverte");
        }
        await Set(bridge, new { profile = "standard", freshness = new { presence = 604800, console = 0, attributes = 604800, inventory = 0, staticProbe = 604800, volatileProbe = 0 } });
        await Set(bridge, new { profile = "slowNetwork", freshness = new { presence = 17 } });
        await Set(bridge, new { freshness = (object?)null });
        Check.Equal(600, CollectionSettingsRules.FreshnessTable(CollectionAdmission.Read(context.Preferences))[0].Seconds, "réinitialisation au profil lent");
        await Set(bridge, new { profile = "standard" });
        var values = CollectionSettingsRules.FreshnessTable(CollectionAdmission.Read(context.Preferences));
        Check.True(values.Select(f => f.Seconds).SequenceEqual([604800, 0, 604800, 0, 604800, 0]), "autre profil intact, bornes exactes");
        foreach (var freshness in new object[] { new { presence = 604801 }, new { presence = -1 }, new { presence = 1.5 }, new { unknown = 1 } })
            Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("settings.collection.set", JsonSerializer.Serialize(new { freshness }))).Error?.Code, "durée non admise refusée");
        Check.Equal(604800, CollectionSettingsRules.FreshnessTable(CollectionAdmission.Read(context.Preferences))[0].Seconds, "aucun écrasement après refus");
    }

    [Test]
    public static void Invalid_saved_values_warn_without_enabling_background_or_disabling_valid_limits()
    {
        using var json = JsonDocument.Parse("""{"profile":"standard","freshness":{"standard":{"presence":604801,"console":"x","attributes":1.5,"unknown":9}},"windows":{"standard":"lundy"},"budgets":{"concurrency":99,"maxTargets":0,"widgetMax":-1,"wmiRetries":9,"wmiRetryDelaySeconds":9}}""");
        var warnings = new List<string>(); var settings = CollectionSettingsRules.Read(json.RootElement, warnings);
        Check.True(warnings.Count >= 10, "chaque anomalie signalée");
        Check.Equal(500, CollectionAdmission.Maximum(settings, true), "repli vers plafonds sûrs");
        Check.False(CollectionAdmission.Window(settings, TestClock.Fixed()).Open, "fenêtre illisible suspend, jamais toujours");
        Check.Throws<DomeniaOperationException>(() => CollectionAdmission.EnsureBackground(settings, TestClock.Fixed()), "refus effectif");
    }

    [Test]
    public static async Task Preference_freshness_is_consumed_by_all_six_cache_families_and_zero_forces_reading()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        await Set(bridge, new { freshness = new { presence = 11, console = 22, attributes = 33, inventory = 44, staticProbe = 55, volatileProbe = 66 }, budgets = new { cacheMinutes = 1440 } });
        var cache = CollectionCachePolicy.Read(context.Preferences);
        var families = new[] { "presence", "console", "attributes", "inventory", "staticProbe", "volatileProbe" };
        for (var i = 0; i < families.Length; i++)
            Check.Equal(Fixtures.Now.AddSeconds(-11 * (i + 1)), cache.Since(families[i], Fixtures.Now), "famille effectivement lue " + families[i]);
        await Set(bridge, new { budgets = new { cacheMinutes = 0 } });
        cache = CollectionCachePolicy.Read(context.Preferences);
        foreach (var family in families) Check.Equal(Fixtures.Now, cache.Since(family, Fixtures.Now), "réutilisation coupée " + family);
    }

    [Test]
    public static async Task Retry_settings_from_the_real_bridge_change_attempts_and_waits_without_relaxing_authentication()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        var evidence = new CollectionRetryEvidence(CollectionReadFailure.Transient, true, true);
        await Set(bridge, new { budgets = new { wmiRetries = 0, wmiRetryDelaySeconds = 10 } });
        var calls = 0;
        await new CollectionReadRetry(context.Clock, CollectionRetryPolicy.Read(context.Preferences)).RunAsync(
            _ => Task.FromResult(++calls), _ => evidence, () => { }, TimeSpan.FromSeconds(15), default);
        Check.Equal(1, calls, "préférence zéro aucune reprise");
        await Set(bridge, new { budgets = new { wmiRetries = 2, wmiRetryDelaySeconds = 10 } });
        var waits = new List<TimeSpan>(); calls = 0;
        var retry = new CollectionReadRetry(context.Clock, CollectionRetryPolicy.Read(context.Preferences))
        { DelayOverride = (duration, _) => { waits.Add(duration); return Task.CompletedTask; } };
        await retry.RunAsync(_ => Task.FromResult(++calls), _ => evidence, () => { }, TimeSpan.FromSeconds(15), default);
        Check.Equal(3, calls, "deux reprises configurées");
        Check.True(waits.SequenceEqual([TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(40)]), "délai persistant effectif");
        Check.False(CollectionReadRetry.Decide(evidence with { Failure = CollectionReadFailure.CredentialRejected }, 1,
            TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(15), policy: CollectionRetryPolicy.Read(context.Preferences)).Retry, "compte refusé jamais rejoué");
    }

    [Test]
    public static async Task Stored_retry_policy_controls_the_actual_native_probe_after_physical_completion()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        var attempts = 0;
        var probe = new WmiWorkstationProbe(context.Clock)
        {
            SessionFactory = (host, timeout, token) => new CimSession(host, timeout, context.Clock, cancellationToken: token)
            {
                ReadOverride = (_, query, _) => query.Contains("Win32_OperatingSystem", StringComparison.Ordinal)
                    ? Fail()
                    : query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
                        ? [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC-TEST", ["DNSHostName"] = "PC-TEST", ["Domain"] = "test.local", ["UserName"] = null })] : [],
            },
        };
        IReadOnlyList<WmiInstance> Fail() { Interlocked.Increment(ref attempts); throw new TimeoutException(); }
        foreach (var retries in new[] { 0, 2 })
        {
            await Set(bridge, new { budgets = new { wmiRetries = retries, wmiRetryDelaySeconds = 10 } });
            var waits = new List<TimeSpan>(); attempts = 0;
            var runner = new CollectionReadRetry(context.Clock, CollectionRetryPolicy.Read(context.Preferences))
            { DelayOverride = (delay, _) => { waits.Add(delay); return Task.CompletedTask; } };
            var result = await runner.RunAsync(token => probe.ReadFactsAsync("PC-TEST", TimeSpan.FromSeconds(15), token),
                value => new(value.RetryFailure, value.ReadPhysicallyCompleted, true), () => { }, TimeSpan.FromSeconds(15), default);
            Check.Equal(retries + 1, attempts, "nombre réel de SELECT OS après préférence persistée");
            Check.True(result.ReadPhysicallyCompleted, "aucune reprise d’un travail encore natif");
            Check.Equal(retries, waits.Count, "attentes réelles du pilote");
            if (retries > 0) Check.True(waits.SequenceEqual([TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(40)]), "délai du profil jusqu’au pilote natif");
        }
    }

    [Test]
    public static async Task Real_query_dispatcher_uses_the_saved_concurrency_and_retains_all_targets()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        await Set(bridge, new { budgets = new { concurrency = 2 } });
        var active = 0; var peak = 0;
        var firstWave = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reader = new Reader(async (_, token) =>
        {
            var now = Interlocked.Increment(ref active);
            int old; do { old = Volatile.Read(ref peak); if (old >= now) break; } while (Interlocked.CompareExchange(ref peak, now, old) != old);
            if (now == 2) firstWave.TrySetResult();
            await firstWave.Task.WaitAsync(TimeSpan.FromSeconds(10), token);
            Interlocked.Decrement(ref active);
            return new(1, 1, 0, 0, 0, Fixtures.Now);
        });
        var requests = Enumerable.Range(0, 20).Select(i => new QueryMeasureRequest([Fixtures.IdOf("limit" + i)], false, true, false, []));
        var result = await QueryRefreshDispatcher.RunAsync(reader, requests, CollectionAdmission.Read(context.Preferences).Budgets[CollectionSettingsRules.Concurrency],
            1, 2, 3, (_, _) => Task.CompletedTask, default);
        Check.Equal(2, peak, "deux lecteurs physiques observés"); Check.Equal(20, result.Answered, "aucune perte par limitation");
    }

    private sealed class Reader(Func<QueryMeasureRequest, CancellationToken, Task<QueryMeasureResult>> read) : IQueryWorkshopReader
    {
        public DirectorySourceKind Kind => DirectorySourceKind.Simulation;
        public Task<QueryDataset> DatasetAsync(CancellationToken token) => throw new InvalidOperationException("Aucune donnée fictive nécessaire.");
        public Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken token) => read(request, token);
    }
}
