using System.Collections.Concurrent;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Inventory;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class OperationPhaseTests
{
    [Test]
    public static void Phases_measure_intervals_group_repeated_batches_and_keep_partial_volume_on_stop()
    {
        var clock = new PhaseClock(); var activity = new OperationActivity(clock, new RecordingJournal(), false);
        using var task = activity.Begin("search.run", TaskKind.NetworkRead, default);
        task.RecordAdmission(200, true);
        using (OperationPhases.Enter(task))
        {
            using (OperationPhases.Measure(OperationPhase.Validation)) clock.Tick(7);
            using (OperationPhases.Measure(OperationPhase.LocalRead)) clock.Tick(13);
            for (var n = 0; n < 1000; n++) task.Step("Étape « lot »", false);
            OperationPhases.Progress(3);
            OperationPhases.Progress(2); // A late smaller progress report cannot erase already received rows.
            var live = activity.Snapshot().Open.Single();
            Check.Contains("au moins 3", live.VolumeText, "volume réel inférieur borné pendant la lecture");
        }
        task.Complete(TaskOutcome.Stopped, "operation.stopped", -1);
        var row = activity.Snapshot().Recent.Single();
        Check.Equal(7d, row.Phases.Single(p => p.Label == "Validation").DurationMs, "intervalle monotone exact");
        Check.Equal(13d, row.Phases.Single(p => p.Label == "Lecture locale").DurationMs, "deuxième intervalle distinct");
        Check.Equal(20d, row.DurationMs, "le total reste le temps du moteur, pas une somme de phases");
        Check.Equal(200d, row.Phases.Single(p => p.Label == "Admission dans le moteur").DurationMs, "attente avant handler mesurée séparément");
        Check.Contains("exclue du total", row.Phases.Single(p => p.Label == "Admission dans le moteur").Detail, "pas de double comptage");
        Check.Contains("1 000", row.Phases.Single(p => p.Label == "Étape « lot »").Detail?.Replace('\u00a0', ' ').Replace('\u202f', ' '), "lots consécutifs regroupés");
        Check.Equal(0, row.Dropped, "répétitions compactées avant la borne, pas perdues");
        Check.Contains("au moins 3", row.VolumeText, "interruption ne transforme pas un résultat partiel en inconnu ou complet");
        OperationPhases.Progress(99);
        Check.Equal(3L, activity.Snapshot().Recent.Single().Volume, "contexte sorti ne modifie pas la tâche terminée");
    }

    [Test]
    public static async Task Real_WMI_reader_and_SQLite_reader_publish_collection_and_local_phases_without_extra_reads()
    {
        var clock = TestClock.Fixed(); var activity = new OperationActivity(clock, new RecordingJournal(), false);
        using var folder = new TemporaryFolder(); var database = new DomeniaDatabase(folder.File("phases.db"), Fixtures.Root, clock);
        await database.InitializeAsync(default);
        using var task = activity.Begin("poste.read", TaskKind.NetworkRead, default);
        using (OperationPhases.Enter(task))
        {
            _ = await database.ReadDirectoryAsync(default);
            var calls = 0;
            var reader = new WmiWorkstationProbe(clock)
            {
                SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
                {
                    ReadOverride = (_, query, _) =>
                    {
                        Interlocked.Increment(ref calls);
                        return [new(new Dictionary<string, object?> { ["SystemDrive"] = "C:", ["Name"] = "PC1", ["DNSHostName"] = "PC1", ["Domain"] = "test.local", ["Caption"] = "Windows" })];
                    },
                },
            };
            _ = await reader.ReadFactsAsync("PC1.test.local", TimeSpan.FromSeconds(10), default);
            Check.Equal(4, calls, "mêmes quatre requêtes CIM, instrumentation sans collecte supplémentaire");
        }
        task.Complete(TaskOutcome.Succeeded, null, 1);
        var phases = activity.Snapshot().Recent.Single().Phases;
        Check.True(phases.Single(p => p.Label == "Lecture locale").Measured, "véritable méthode SQLite observée");
        Check.True(phases.Single(p => p.Label == "Collecte").Measured, "véritable worker CIM observé");
    }

    [Test]
    public static async Task Tracked_partial_LDAP_result_keeps_real_volume_and_validation_measurement()
    {
        var clock = TestClock.Fixed();
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = query =>
        {
            if (query.SortAttribute is null) return [];
            query.EntryReceived!.Invoke(AdPosteNetworkTests.Entry(Fixtures.Computer("PC1")));
            clock.Advance(TimeSpan.FromSeconds(120));
            query.EntryReceived.Invoke(AdPosteNetworkTests.Entry(Fixtures.Computer("PC2")));
            return [];
        } };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap);
        using var context = new EngineContext(ModeResolver.Resolve([], null, () => new(DomainJoinState.Joined, "test.local")), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.None);
        var query = new SearchQuery(SearchListKind.Search, SearchText.Plan("PC*", SearchTypeFilter.Computers, SearchMatchMode.Prefix),
            SearchTypeFilter.Computers, Fixtures.Postes, true, null, null, new HashSet<string>(), 10);
        var definition = OperationTracking.Track(context, new("search.run", OperationClass.NetworkRead,
            async (_, _, token) => await new AdSearchReader(source).FindAsync(query, token), "Lecture LDAP enregistrée"));
        var result = (SearchPage)(await definition.Handler(JsonSerializer.SerializeToElement(new { }), new(_ => { }, "partial", "search.run"), default))!;
        Check.True(result.Interrupted, "vraie interruption LDAP avec un résultat reçu");
        var row = OperationActivity.From(context).Snapshot().Recent.Single();
        Check.Contains("au moins 1", row.VolumeText, "le moteur marque le volume incomplet même après réponse réussie du handler");
        Check.True(row.Phases.Single(p => p.Label == "Validation").Measured, "contrôles réels de requête et réponse observés");
        Check.True(row.Phases.Single(p => p.Label == "Collecte").Measured, "appel LDAP réel observé même lorsqu’il finit partiel");
    }

    [Test]
    public static async Task Real_shared_dispatch_executes_and_measures_one_read_for_two_subscribers()
    {
        var clock = TestClock.Fixed(); var source = new SimulatedDirectorySource(SimulationOptions.Default, clock);
        using var context = new EngineContext(ModeResolver.Resolve(["--simulation"], null, () => new(DomainJoinState.Unknown, null)), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.None);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var joined = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var replies = new ConcurrentQueue<BridgeResponse>(); var calls = 0;
        var raw = new OperationDefinition("directory.ou.children", OperationClass.NetworkRead, async (_, _, token) =>
        { Interlocked.Increment(ref calls); entered.TrySetResult(); await release.Task.WaitAsync(token); return Array.Empty<string>(); }, "Lecture partagée enregistrée")
        { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, ["dn"]), ShareRead = true };
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([OperationTracking.Track(context, raw)], clock,
            _ => Task.FromResult(new BridgeSessionStamp("same-session", "same-scope"))), response =>
        { replies.Enqueue(response); if (response.Id == "b" && response.Operation.EndsWith(":admitted", StringComparison.Ordinal)) joined.TrySetResult(); });
        string Message(string id) => JsonSerializer.Serialize(new { id, op = raw.Name, args = new { } });
        var first = dispatcher.HandleAsync(Message("a"), default);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = dispatcher.HandleAsync(Message("b"), default);
        try { await joined.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        finally { release.TrySetResult(); await Task.WhenAll(first, second); }
        Check.Equal(1, calls, "un seul handler partagé");
        Check.Equal(2, replies.Count(r => r.Kind == "result"), "deux réponses livrées");
        var rows = OperationActivity.From(context).Snapshot().Recent;
        Check.Equal(1, rows.Length, "une seule mesure du travail physique partagé");
        Check.True(rows[0].Phases.Single(p => p.Label == "Admission dans le moteur").Measured, "raccord réel file → dispatcher → trace");
        Check.True(rows[0].Phases.Single(p => p.Label == "Lecture partagée").Measured, "raccord partagé réel du dispatcher");
    }

    private sealed class PhaseClock : TimeProvider
    {
        private long time;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => time;
        public override DateTimeOffset GetUtcNow() => Fixtures.Now.AddMilliseconds(time);
        internal void Tick(int milliseconds) => time += milliseconds;
    }
}
