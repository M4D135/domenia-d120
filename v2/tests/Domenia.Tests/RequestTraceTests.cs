using System.Collections;
using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RequestTraceTests
{
    [Test]
    public static async Task Real_dispatch_and_parallel_SQLite_jobs_close_one_trace_after_the_last_publication_without_targets()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("private-target.db");
        using (var db = new SqliteDatabase(path, false))
        { db.Script("CREATE TABLE private_table(value TEXT);"); db.Execute("INSERT INTO private_table VALUES (?);", "secret-poste.test.local"); }
        var log = new RecordingJournal(); using var setup = new Setup(log);
        var publications = 0;
        var definition = new OperationDefinition("search.run", OperationClass.LocalRead, async (_, bridge, _) =>
        {
            async Task<int> ReadAsync() => await Task.Run(() =>
            {
                using var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage);
                using var phase = OperationPhases.Measure(OperationPhase.LocalRead);
                using var db = new SqliteDatabase(path, true);
                return db.Query("SELECT value FROM private_table;").Count;
            });
            var counts = await Task.WhenAll(ReadAsync(), ReadAsync());
            Check.Equal(2, counts.Sum(), "deux lectures natives réellement terminées");
            bridge.Publish("rows", new CountOnly(100_000));
            return new[] { "secret-user", "secret-poste" };
        }, "Lecture locale de test");
        using var dispatcher = setup.Dispatcher(definition, _ =>
        {
            Check.Equal(0, Traces(log).Length, "aucune synthèse avant le retour de la dernière publication");
            Interlocked.Increment(ref publications);
        });
        await dispatcher.HandleAsync(Message(definition.Name, "raw-page-id-secret"), default);
        var line = Traces(log).Single();
        Check.Equal(2, publications, "événement et résultat transmis");
        Check.Contains("jobs=3", line, "handler et deux travaux physiques réels");
        Check.Contains("lignes transmises=100002", line, "comptage constant, aucun parcours des 100 000 lignes");
        Check.Contains("/2 intervalles/2 lignes/0 incomplets", line, "les deux relectures SQLite sont comptées exactement");
        Check.Contains("LocalRead=", line, "phases observées, cumulées sans devenir un total inventé");
        var measured = Regex.Match(line, @"Read=([0-9.]+)ms/2 intervalles", RegexOptions.CultureInvariant);
        Check.True(measured.Success && double.Parse(measured.Groups[1].Value, CultureInfo.InvariantCulture) > 0, "durée SQLite native réellement positive");
        foreach (var secret in new[] { path, "secret-poste", "secret-user", "private_table", "raw-page-id-secret" })
            Check.False(line.Contains(secret, StringComparison.Ordinal), "aucun argument, contenu ou identifiant de page dans la synthèse");
        Check.Equal(0, setup.Context.Journal.Snapshot().Length, "TRACE technique absent du journal utilisateur");
    }

    [Test]
    public static async Task Cancelled_request_keeps_its_physical_job_until_native_completion_then_emits_once()
    {
        var log = new RecordingJournal(); using var setup = new Setup(log);
        var started = Signal(); var release = Signal(); Task? worker = null;
        var definition = new OperationDefinition("search.run", OperationClass.LocalRead, async (_, _, token) =>
        {
            var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Other);
            worker = Task.Run(async () => { using (physical) { started.TrySetResult(); await release.Task; } });
            await worker.WaitAsync(token);
            return null;
        }, "Lecture annulable");
        using var dispatcher = setup.Dispatcher(definition, _ => { }); using var stop = new CancellationTokenSource();
        var request = dispatcher.HandleAsync(Message(definition.Name, "stopped"), stop.Token);
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(5)); stop.Cancel();
            await request.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(0, Traces(log).Length, "réponse annulée ne clôture pas le travail natif encore vivant");
            var cleanup = setup.Activity.Snapshot();
            Check.Equal(TaskState.Cleanup, cleanup.Open.Single().State, "appel natif encore vivant visible en nettoyage");
            Check.Equal(1, cleanup.Summary.Cleanup, "nettoyage compté dans l’activité");
            Check.False(cleanup.Open.Single().CanStop, "nettoyage ne libère ni n’annule une autre tâche");
            Check.Equal(1, setup.Activity.ActiveCount(), "la demande détachée reste comptée une seule fois");
        }
        finally { release.TrySetResult(); if (worker is not null) await worker; }
        Check.Equal(0, setup.Activity.ActiveCount(), "dernière libération native clôture le suivi");
        var line = Traces(log).Single();
        Check.Contains("jobs=2", line, "handler et vrai worker réservé");
        Check.Contains("issue=Stopped", line, "fin native tardive ne transforme pas l’arrêt en succès");
        Check.Equal(1, Traces(log).Length, "une seule synthèse après dernière libération");
    }

    [Test]
    public static async Task Shared_read_has_one_physical_execution_but_each_subscriber_counts_its_own_publications()
    {
        var log = new RecordingJournal(); using var setup = new Setup(log);
        var started = Signal(); var joined = Signal(); var release = Signal(); var calls = 0;
        var definition = new OperationDefinition("directory.ou.children", OperationClass.NetworkRead, async (_, bridge, token) =>
        {
            using var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory);
            Interlocked.Increment(ref calls); started.TrySetResult(); await release.Task.WaitAsync(token);
            bridge.Publish("rows", new[] { "private-child" }); return new[] { "private-child", "private-child2" };
        }, "Lecture partagée") { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, ["dn"]), ShareRead = true };
        using var dispatcher = setup.Dispatcher(definition, response =>
        { if (response.Id == "b" && response.Operation.EndsWith(":admitted", StringComparison.Ordinal)) joined.TrySetResult(); });
        var a = dispatcher.HandleAsync(Message(definition.Name, "a"), default);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var b = dispatcher.HandleAsync(Message(definition.Name, "b"), default);
        try { await joined.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        finally { release.TrySetResult(); await Task.WhenAll(a, b); }
        Check.Equal(1, calls, "une seule exécution partagée");
        var lines = Traces(log); Check.Equal(2, lines.Length, "une synthèse de chaque requête, pas une par publication");
        Check.True(lines.All(l => l.Contains("lignes transmises=3", StringComparison.Ordinal)), "chaque abonné a reçu ses trois lignes");
        Check.Equal(1, lines.Count(l => l.Contains("SharedRequest/", StringComparison.Ordinal)), "l’abonné référence le travail propriétaire sans inventer une seconde collecte");
        Check.Equal(1, lines.Count(l => l.Contains("Directory/", StringComparison.Ordinal)), "une seule référence de travail physique");
        Check.True(lines.All(l => !l.Contains("private-child", StringComparison.Ordinal)), "aucune cible dans les lignes");
    }

    [Test]
    public static async Task Cancelled_requalification_keeps_its_summary_open_until_the_ignoring_provider_really_returns()
    {
        var log = new SignallingJournal(); using var setup = new Setup(log);
        var started = Signal(); var release = new TaskCompletionSource<BridgeSessionStamp>(TaskCreationOptions.RunContinuationsAsynchronously);
        var captures = 0; var handlers = 0;
        Task<BridgeSessionStamp> Capture(CancellationToken ignored)
        {
            _ = ignored;
            if (Interlocked.Increment(ref captures) == 3) { started.TrySetResult(); return release.Task; }
            return Task.FromResult(new BridgeSessionStamp("session", "scope"));
        }
        var definition = new OperationDefinition("search.run", OperationClass.NetworkRead, (_, _, _) =>
        { Interlocked.Increment(ref handlers); return Task.FromResult<object?>(null); }, "Qualification annulable")
        { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, ["dn"]) };
        using var dispatcher = setup.Dispatcher(definition, _ => { }, Capture);
        using var stop = new CancellationTokenSource();
        var request = dispatcher.HandleAsync(Message(definition.Name, "qualification"), stop.Token);
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(5)); stop.Cancel();
            await request.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(log.Trace.Task.IsCompleted, "la réponse annulée ne ferme pas une qualification native toujours active");
        }
        finally { release.TrySetResult(new("session", "scope")); }
        var line = await log.Trace.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal(0, handlers, "aucun handler lancé après annulation de sa qualification");
        Check.Contains("issue=Stopped", line, "la fin tardive du fournisseur ne transforme pas l’arrêt en réussite");
        Check.Equal(1, Traces(log.Recorded).Length, "une seule synthèse après la vraie fin");
    }

    [Test]
    public static async Task Real_storage_batch_and_reread_have_distinct_measures_and_one_durable_TRACE_line()
    {
        using var folder = new TemporaryFolder(); var log = new FileJournal(folder.File("domenia.log"));
        using var setup = new Setup(log); var database = new DomeniaDatabase(folder.File("cache.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var definition = new OperationDefinition("sync.read", OperationClass.LocalRead, async (_, _, token) =>
        {
            await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [Fixtures.Computer("SECRET")]),
                new(Fixtures.Postes, "Postes", true), "SECRET-DC", token);
            return (await database.ReadSyncStateAsync(token)).Rows.ToArray();
        }, "Lot local et relecture");
        using var dispatcher = setup.Dispatcher(definition, _ => { });
        await dispatcher.HandleAsync(Message(definition.Name, "durable"), default);
        log.Flush(); var text = File.ReadAllText(folder.File("domenia.log"));
        var lines = text.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
        var trace = lines.Single(l => l.Contains("[TRACE] Requête", StringComparison.Ordinal));
        Check.Contains("WriteBatch=", trace, "intervalle de véritable enregistrement");
        Check.Contains("ReadBatch=", trace, "intervalle de véritable relecture");
        Check.False(trace.Contains("WriteBatch=non mesuré", StringComparison.Ordinal), "écrivain réellement observé");
        Check.False(trace.Contains("ReadBatch=non mesuré", StringComparison.Ordinal), "relecture réellement observée");
        Check.False(trace.Contains("SECRET", StringComparison.Ordinal), "contenu du lot exclu du journal");
    }

    [Test]
    public static async Task Incident_sink_failure_never_replaces_the_original_bridge_error_and_valid_codes_are_returned()
    {
        var log = new RecordingJournal(); using var setup = new Setup(log); var responses = new List<BridgeResponse>();
        var expected = new OperationDefinition("test.expected", OperationClass.LocalRead,
            (_, _, _) => throw new DomeniaOperationException("directory.denied", "Accès refusé."), "Erreur attendue");
        using (var dispatcher = setup.Dispatcher(expected, responses.Add))
        {
            dispatcher.ReportIncident = (_, _) => throw new IOException("journal inaccessible");
            await dispatcher.HandleAsync(Message(expected.Name, "fail"), default);
            Check.Equal("directory.denied", responses.Single().Error!.Code, "code métier intact");
            Check.Equal("Accès refusé.", responses.Single().Error!.Message, "aucun faux code incident");
            Check.Equal(1, setup.Activity.Faults, "panne du suivi comptée sans casser la réponse");
            responses.Clear(); dispatcher.ReportIncident = (_, _) => "INC-" + new string('a', 32);
            await dispatcher.HandleAsync(Message(expected.Name, "code"), default);
            Check.Contains("INC-" + new string('A', 32), responses.Single().Error!.Message, "code opaque normalisé comme l’interface et le support");
        }
        responses.Clear();
        var unexpected = expected with { Name = "test.unexpected", Handler = (_, _, _) => throw new InvalidOperationException("private target") };
        using var failed = setup.Dispatcher(unexpected, responses.Add);
        failed.ReportIncident = (_, _) => throw new IOException(); failed.UnhandledError += (_, _) => throw new IOException();
        await failed.HandleAsync(Message(unexpected.Name, "unexpected"), default);
        Check.Equal("operation.failed", responses.Single().Error!.Code, "les deux observateurs en panne laissent la réponse originale");
    }

    [Test]
    public static void Summary_survives_UI_ring_eviction_and_bounds_job_references_without_losing_counts()
    {
        var log = new RecordingJournal(); var activity = new OperationActivity(TimeProvider.System, log, false);
        activity.Declare("test.rows", TaskKind.LocalRead, "Test");
        using (var request = activity.BeginRequest("test.rows") ?? throw new TestFailureException("Trace non ouverte."))
        using (OperationRequests.Enter(request))
        {
            for (var i = 0; i < 100; i++)
            { using var task = activity.Begin("test.rows", TaskKind.LocalRead, default); task.Complete(TaskOutcome.Succeeded, null, 0); }
            Check.Equal(0, Traces(log).Length, "le débordement de l’anneau ne ferme pas la requête");
            request.Publish(() => { }, 100_000);
        }
        var line = Traces(log).Single();
        Check.Contains("jobs=100", line, "tous les travaux réels comptés");
        Check.Contains("références omises=36", line, "liste de références bornée à 64");
        Check.Equal(64, Regex.Matches(line, "Handler/", RegexOptions.CultureInvariant).Count, "aucune rétention de références après la borne");
        Check.True(line.Length < TechnicalJournalRecord.MaximumLine, "synthèse tient dans une ligne technique entière");
    }

    [Test]
    public static void Publication_interval_is_measured_until_the_callback_returns_and_failed_clock_never_prevents_send()
    {
        var clock = new TraceClock(); var log = new RecordingJournal(); var activity = new OperationActivity(clock, log, false);
        activity.Declare("test.read", TaskKind.LocalRead, "Lecture");
        using (var request = activity.BeginRequest("test.read") ?? throw new TestFailureException("Trace absente."))
        {
            using (request.MeasurePhase(OperationPhase.Validation)) clock.Tick(7);
            request.Publish(() => { Check.Equal(0, Traces(log).Length, "publication encore en cours"); clock.Tick(13); }, 3);
            request.Outcome(TaskOutcome.Succeeded);
        }
        var line = Traces(log).Single();
        Check.Contains("Validation=7ms/1", line, "intervalle réel de validation");
        Check.Contains("envoi=13ms", line, "fin physique du callback mesurée");
        Check.Contains("total=20ms", line, "total monotone jusqu’à sa dernière publication, pas somme de phases");
        using (var request = activity.BeginRequest("test.read") ?? throw new TestFailureException("Trace absente."))
        {
            using var task = activity.Begin("test.read", TaskKind.LocalRead, default);
            var phaseStartedBeforeFailure = task.Measure(OperationPhase.LocalRead);
            clock.Fail = true; var sent = 0;
            request.Publish(() => sent++, 1);
            using var ignored = request.MeasurePhase(OperationPhase.Collection);
            using var taskPhase = task.Measure(OperationPhase.Validation);
            phaseStartedBeforeFailure.Dispose();
            task.Complete(TaskOutcome.Succeeded, null, 1);
            Check.Equal(1, sent, "horloge diagnostic en panne : publication préservée");
            Check.Null(ignored, "aucun intervalle fictif après panne d’horloge");
        }
        Check.Null(activity.BeginRequest("test.read"), "construction de trace refusée proprement sans refuser l’opération");
        Check.True(activity.Faults >= 3, "pannes de suivi comptées");
    }

    [Test]
    public static async Task A_broken_trace_sink_or_collection_counter_does_not_change_the_real_result()
    {
        ITechnicalJournal[] journals = [new RecordingJournal(), new BrokenJournal()];
        foreach (var journal in journals)
        {
            using var setup = new Setup(journal); var responses = new List<BridgeResponse>();
            var answer = new BrokenCount();
            var definition = new OperationDefinition("test.read", OperationClass.LocalRead,
                (_, _, _) => Task.FromResult<object?>(answer), "Lecture sans métrique fiable");
            using var dispatcher = setup.Dispatcher(definition, responses.Add);
            await dispatcher.HandleAsync(Message(definition.Name, "observer-failure"), default);
            Check.Equal("result", responses.Single().Kind, "ni panne du compteur ni panne du journal ne deviennent une erreur métier");
            Check.True(ReferenceEquals(answer, responses.Single().Data), "la véritable réponse est transmise sans remplacement");
            Check.True(setup.Activity.Faults >= 2, "incidents du suivi observés");
            if (journal is RecordingJournal recorded)
            {
                Check.Contains("issue=Succeeded", Traces(recorded).Single(), "le compteur défaillant ne transforme pas la réussite en échec");
                Check.Contains("volumes non mesurés=1", Traces(recorded).Single(), "aucun volume fabriqué");
            }
        }
    }

    private static string[] Traces(RecordingJournal log) => log.Lines.Where(l => l.StartsWith("TRACE Requête", StringComparison.Ordinal)).ToArray();
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static string Message(string operation, string id) => JsonSerializer.Serialize(new { id, op = operation, args = new { } });
    private sealed class Setup : IDisposable
    {
        internal EngineContext Context { get; }
        internal OperationActivity Activity => OperationActivity.From(Context);
        internal Setup(ITechnicalJournal log)
        {
            var clock = TestClock.Fixed();
            Context = new(ModeResolver.Resolve(["--simulation"], null, () => new(DomainJoinState.Unknown, null)),
                new SimulatedDirectorySource(SimulationOptions.Default, clock), new MemoryPreferenceStore(), clock, log, ScreenReaders.None);
        }
        internal BridgeDispatcher Dispatcher(OperationDefinition definition, Action<BridgeResponse> publish,
            Func<CancellationToken, Task<BridgeSessionStamp>>? capture = null) => new(
            new OperationRegistry([OperationTracking.Track(Context, definition)], Context.Clock,
                capture ?? (_ => Task.FromResult(new BridgeSessionStamp("session", "scope"))), activity: Activity), publish);
        public void Dispose() => Context.Dispose();
    }
    private sealed class CountOnly(int count) : ICollection
    {
        public int Count => count; public bool IsSynchronized => false; public object SyncRoot => this;
        public void CopyTo(Array array, int index) => throw new InvalidOperationException("No row traversal allowed.");
        public IEnumerator GetEnumerator() => throw new InvalidOperationException("No row traversal allowed.");
    }
    private sealed class BrokenCount : ICollection
    {
        public int Count => throw new InvalidOperationException("Compteur indisponible.");
        public bool IsSynchronized => false; public object SyncRoot => this;
        public void CopyTo(Array array, int index) => throw new InvalidOperationException();
        public IEnumerator GetEnumerator() => throw new InvalidOperationException();
    }
    private sealed class BrokenJournal : ITechnicalJournal
    {
        public void Trace(string message) => throw new IOException("Trace indisponible.");
        public void Info(string message) => throw new IOException("Journal indisponible.");
        public void Warning(string message) => throw new IOException("Journal indisponible.");
        public void Error(string message, Exception exception) => throw new IOException("Journal indisponible.");
    }
    private sealed class SignallingJournal : ITechnicalJournal
    {
        internal RecordingJournal Recorded { get; } = new();
        internal TaskCompletionSource<string> Trace { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        void ITechnicalJournal.Trace(string message) { Recorded.Trace(message); Trace.TrySetResult(message); }
        public void Info(string message) => Recorded.Info(message);
        public void Warning(string message) => Recorded.Warning(message);
        public void Error(string message, Exception exception) => Recorded.Error(message, exception);
    }
    private sealed class TraceClock : TimeProvider
    {
        private long milliseconds;
        internal bool Fail { get; set; }
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => Fail ? throw new InvalidOperationException("Horloge indisponible.") : milliseconds;
        public override DateTimeOffset GetUtcNow() => Fixtures.Now.AddMilliseconds(milliseconds);
        internal void Tick(int amount) => milliseconds += amount;
    }
    private sealed class FileJournal(string path) : ITechnicalJournal
    {
        private readonly RotatingTechnicalJournal journal = new(path, null, TimeProvider.System);
        public void Trace(string message) => journal.Enqueue("TRACE", message);
        public void Info(string message) => journal.Enqueue("INFO", message);
        public void Warning(string message) => journal.Enqueue("ATTENTION", message);
        public void Error(string message, Exception exception) => journal.Enqueue("ERREUR", message + exception.GetType().Name);
        internal void Flush() => journal.Flush();
    }
}
