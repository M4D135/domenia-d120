using System.Collections.Concurrent;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class BridgeSharedReadTests
{
    private const string ReadName = "directory.ou.children";
    private static readonly JsonElement Empty = JsonSerializer.SerializeToElement(new { });
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static OperationDefinition Read(OperationHandler handler, OperationPriority priority = OperationPriority.Explicit,
        OperationClass kind = OperationClass.NetworkRead) => new(ReadName, kind, handler, "OU enfants")
        { Scheduling = new(priority, OperationProvider.Directory, ["dn"]), ShareRead = true };
    private static string Message(string id, string op = ReadName, object? args = null)
        => JsonSerializer.Serialize(new { id, op, args = args ?? new { } });

    [Test]
    public static async Task Late_shared_subscriber_receives_only_closed_tracking_and_survives_the_first_request_stop()
    {
        using var fixture = new Fixture(); using var firstStop = new CancellationTokenSource();
        var first = fixture.Request("first", firstStop.Token);
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var notice = new OperationTaskStarted(new string('a', 32), "Lecture partagée", "explicit", true);
        fixture.Context!.Publish("tracking", notice);
        fixture.Context.Publish("progress", new { step = "old" });
        var second = fixture.Request("second");
        try
        {
            await fixture.Event("second", "tracking").WaitAsync(TimeSpan.FromSeconds(5));
            Check.True(fixture.Responses.Where(r => r.Id == "second" && r.Operation == ReadName + ":tracking")
                .All(r => r.Data is OperationTaskStarted actual && actual.TaskId == notice.TaskId), "même tâche moteur, requestId individuel");
            Check.Equal(0, fixture.Responses.Count(r => r.Id == "second" && r.Operation == ReadName + ":progress"), "aucune progression ancienne rejouée");
            firstStop.Cancel(); await first.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(second.IsCompleted, "le nouvel abonné maintient le vrai travail");
            Check.False(fixture.HandlerToken.IsCancellationRequested, "aucun arrêt natif tant que le second reste");
            fixture.Release.TrySetResult(); await second.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal("result", fixture.Final("second").Kind, "fin propre de l’abonné tardif");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    [Test]
    public static async Task Shared_running_read_keeps_one_physical_worker_when_first_subscriber_cancels()
    {
        using var fixture = new Fixture(); using var firstStop = new CancellationTokenSource();
        var first = fixture.Request("first", firstStop.Token);
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = fixture.Request("second");
        try
        {
            await fixture.Event("second", "admitted").WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(1, fixture.Calls, "handler unique effectivement entré");
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "un seul bail physique");
            Check.Equal(1, fixture.Dispatcher.AdmissionLoad.Running, "un seul emplacement Bridge");
            firstStop.Cancel(); await first.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal("operation.cancelled", fixture.Final("first").Error!.Code, "seul le premier abonné finit annulé");
            Check.False(fixture.HandlerToken.IsCancellationRequested, "le second maintient le travail réel");
            Check.False(second.IsCompleted, "le second attend encore sa réponse");
            fixture.Context!.Publish("progress", new { stage = "read" });
            Check.Equal(1, fixture.Responses.Count(r => r.Operation == ReadName + ":progress" && r.Id == "second"), "événement remis au second");
            Check.Equal(0, fixture.Responses.Count(r => r.Operation == ReadName + ":progress" && r.Id == "first"), "abonné retiré exclu des événements");
            fixture.Release.TrySetResult(); await second.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal("result", fixture.Final("second").Kind, "résultat individuel du survivant");
            Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "bail rendu après fin réelle");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    [Test]
    public static async Task Last_subscriber_cancellation_keeps_closing_group_and_slot_until_handler_really_finishes()
    {
        using var admission = NewAdmission();
        var definition = Read((_, _, _) => Task.FromResult<object?>(true));
        using var first = await admission.EnterAsync("first", definition, Empty, default, () => { });
        var started = Signal(); var cancelled = Signal(); var release = Signal(); var calls = 0;
        var work = admission.ShareAsync(first, async (_, token) =>
        {
            using var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory);
            using var registration = token.Register(() => cancelled.TrySetResult());
            Interlocked.Increment(ref calls); started.TrySetResult();
            await release.Task; token.ThrowIfCancellationRequested(); return true;
        });
        await started.Task;
        try
        {
            first.Dispose();
            await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(1, admission.Load.Running, "annulation d’attente sans restitution anticipée");
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "worker bloqué encore compté");
            var replacement = await Check.ThrowsAsync<BridgeOperationException>(() => admission.EnterAsync("replacement", definition, Empty, default, () => { }), "remplacement interdit pendant fermeture");
            Check.Equal("operation.sharedClosing", replacement.Code, "cause exacte");
            Check.Equal(1, calls, "aucun second worker");
            release.TrySetResult();
            await Check.ThrowsAsync<TaskCanceledException>(() => work, "fin réelle du travail annulé");
            Check.Equal(0, admission.Load.Running, "fin réelle rend la place");
            Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "plus aucun worker physique");
            using var next = await admission.EnterAsync("new-explicit", definition, Empty, default, () => { });
            await admission.ShareAsync(next, (_, _) => { Interlocked.Increment(ref calls); return Task.FromResult<object?>(true); });
            Check.Equal(2, calls, "nouvelle exécution explicite, aucun résultat ancien en cache");
        }
        finally { release.TrySetResult(); }
    }

    [Test]
    public static async Task Shared_result_is_requalified_after_handler_before_any_success_is_published()
    {
        using var fixture = new Fixture();
        var first = fixture.Request("first"); await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = fixture.Request("second");
        try
        {
            await fixture.Event("second", "admitted").WaitAsync(TimeSpan.FromSeconds(5));
            fixture.Stamp = new("different-account-or-epoch", "site");
            fixture.Release.TrySetResult(); await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(1, fixture.Calls, "travail réellement partagé");
            foreach (var id in new[] { "first", "second" })
            { Check.Equal("operation.contextChanged", fixture.Final(id).Error!.Code, "aucun résultat de l’ancienne identité"); }
            Check.Equal(0, fixture.Responses.Count(r => r.Kind == "result"), "aucun faux succès");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    [Test]
    public static async Task Different_payload_or_session_never_joins_an_existing_read()
    {
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucun travail d’un test précédent encore actif");
        using var fixture = new Fixture();
        var first = fixture.Request("first", args: new { dn = "OU=A,DC=test" });
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var payload = fixture.Request("payload", args: new { dn = "OU=B,DC=test" });
        await fixture.Entry(2).WaitAsync(TimeSpan.FromSeconds(5));
        fixture.Stamp = new("session-b", "site");
        var session = fixture.Request("session", args: new { dn = "OU=A,DC=test" });
        try
        {
            await fixture.Entry(3).WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(3, fixture.Calls, "trois demandes incompatibles exécutées séparément");
            Check.Equal(3, PhysicalWorkBudget.Snapshot().Outstanding, "trois travaux distincts");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, payload, session); }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "les trois baux sont rendus après la fin réelle des handlers");
        Check.Equal("result", fixture.Final("session").Kind, "la session actuelle répond");
        Check.Equal("operation.contextChanged", fixture.Final("first").Error!.Code, "l’ancienne session ne publie pas");
    }

    [Test]
    public static async Task Dispatcher_ownership_prevents_sharing_even_for_identical_session_and_request()
    {
        using var one = new Fixture(); using var two = new Fixture();
        var first = one.Request("same"); var second = two.Request("same");
        try
        {
            await Task.WhenAll(one.Started.Task, two.Started.Task).WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(1, one.Calls, "travail du premier dispatcher"); Check.Equal(1, two.Calls, "travail du second dispatcher");
            Check.False(two.Dispatcher.CancelQueued("same"), "un départ réel ne devient pas un retrait de file");
            Check.Equal(2, PhysicalWorkBudget.Snapshot().Outstanding, "aucun partage entre propriétaires");
        }
        finally { one.Release.TrySetResult(); two.Release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    [Test]
    public static async Task Queued_subscribers_count_toward_32_and_first_withdrawal_preserves_one_promotion()
    {
        using var admission = NewAdmission(); var held = await HoldNetwork(admission);
        var definition = Read((_, _, _) => Task.FromResult<object?>(true));
        var waiting = Enumerable.Range(0, 32).Select(i => admission.EnterAsync("q" + i, definition, Empty, default, () => { })).ToArray();
        var leases = new List<BridgeAdmission.Lease>();
        try
        {
            Check.Equal(32, admission.Load.Queued, "32 abonnés, pas 32 groupes");
            Check.Equal(1, admission.SharedLoad.Groups, "un seul groupe en attente");
            var full = await Check.ThrowsAsync<BridgeOperationException>(() => admission.EnterAsync("overflow", definition, Empty, default, () => { }), "33e abonné refusé");
            Check.Equal("operation.queueFull", full.Code, "borne originale inchangée");
            Check.True(admission.CancelQueued("q0"), "retrait du premier avant envoi");
            await Check.ThrowsAsync<TaskCanceledException>(() => waiting[0], "premier retiré");
            Check.Equal(31, admission.Load.Queued, "les autres restent en attente");
            foreach (var item in held) { item.Dispose(); }
            leases.AddRange(await Task.WhenAll(waiting.Skip(1)).WaitAsync(TimeSpan.FromSeconds(5)));
            Check.Equal(1, admission.Load.Running, "une seule admission pour 31 réponses");
            var calls = 0; var finish = Signal();
            var executions = leases.Select(lease => admission.ShareAsync(lease, async (_, _) => { Interlocked.Increment(ref calls); await finish.Task; return "value"; })).ToArray();
            Check.Equal(1, calls, "un seul delegate a démarré");
            Check.True(executions.All(task => ReferenceEquals(task, executions[0])), "un seul travail partagé");
            finish.TrySetResult(); await Task.WhenAll(executions);
            Check.Equal(0, admission.Load.Running, "place rendue seulement après exécution");
        }
        finally { foreach (var item in held.Concat(leases)) { item.Dispose(); } admission.Dispose(); }
    }

    [Test]
    public static async Task Queued_group_expires_without_handler_and_does_not_retain_members()
    {
        var clock = TestClock.Fixed(); using var admission = NewAdmission(clock); var held = await HoldNetwork(admission);
        var definition = Read((_, _, _) => throw new InvalidOperationException("No handler expected."));
        var first = admission.EnterAsync("first", definition, Empty, default, () => { });
        var second = admission.EnterAsync("second", definition, Empty, default, () => { });
        try
        {
            Check.Equal(2, admission.Load.Queued, "setup positif réellement en attente");
            clock.Advance(BridgeAdmission.Expiration); await admission.RefreshAsync();
            foreach (var pending in new[] { first, second })
            {
                var failure = await Check.ThrowsAsync<BridgeOperationException>(() => pending, "expiration avant départ");
                Check.Equal("operation.queueExpired", failure.Code, "cause exacte");
            }
            Check.Equal((0, 0), admission.SharedLoad, "groupes et abonnés libérés");
            Check.Equal(8, admission.Load.Running, "seuls les travaux initiaux restent");
        }
        finally { foreach (var item in held) { item.Dispose(); } }
    }

    [Test]
    public static async Task Cancelling_every_promoted_subscriber_before_execution_releases_the_single_place()
    {
        using var admission = NewAdmission(); var definition = Read((_, _, _) => throw new InvalidOperationException("No handler expected."));
        var first = await admission.EnterAsync("first", definition, Empty, default, () => { });
        var second = await admission.EnterAsync("second", definition, Empty, default, () => { });
        Check.Equal(1, admission.Load.Running, "promotion unique réelle");
        first.Dispose(); Check.Equal(1, admission.Load.Running, "second abonné conserve la place");
        second.Dispose(); Check.Equal(0, admission.Load.Running, "dernier départ rend la promotion inutilisée");
        Check.Equal((0, 0), admission.SharedLoad, "aucun groupe fantôme");
        await Check.ThrowsAsync<TaskCanceledException>(() => admission.ShareAsync(second, (_, _) => throw new InvalidOperationException("Must never start.")), "aucun départ tardif après retrait");
    }

    [Test]
    public static async Task Cancelled_member_still_registered_after_admission_cannot_authorize_execution()
    {
        using var admission = NewAdmission(); using var stop = new CancellationTokenSource();
        using var lease = await admission.EnterAsync("read", Read((_, _, _) => Task.FromResult<object?>(true)), Empty, stop.Token, () => { });
        Check.Equal(1, admission.Load.Running, "promotion obtenue avant annulation");
        stop.Cancel();
        Check.Equal((1, 1), admission.SharedLoad, "abonné encore inscrit : son finally n’a pas été exécuté");
        var calls = 0;
        await Check.ThrowsAsync<TaskCanceledException>(() => admission.ShareAsync(lease, (_, _) =>
        { calls++; return Task.FromResult<object?>(true); }), "aucune exécution sans abonné actif");
        Check.Equal(0, calls, "delegate jamais invoqué");
        Check.Equal(0, admission.Load.Running, "promotion non utilisée restituée");
        lease.Dispose(); Check.Equal((0, 0), admission.SharedLoad, "abonnement finalement retiré sans double restitution");
    }

    [Test]
    public static async Task Dispatcher_disposal_after_promotion_prevents_any_late_shared_execution()
    {
        using var admission = NewAdmission();
        using var lease = await admission.EnterAsync("read", Read((_, _, _) => Task.FromResult<object?>(true)), Empty, default, () => { });
        Check.Equal(1, admission.Load.Running, "promotion obtenue avant fermeture");
        admission.Dispose(); var calls = 0;
        await Check.ThrowsAsync<TaskCanceledException>(() => admission.ShareAsync(lease, (_, _) =>
        { calls++; return Task.FromResult<object?>(true); }), "fermeture interdit le départ tardif");
        Check.Equal(0, calls, "delegate jamais invoqué après fermeture");
        Check.Equal(0, admission.Load.Running, "promotion rendue sans handler");
        lease.Dispose(); Check.Equal((0, 0), admission.SharedLoad, "aucun groupe ou abonnement retenu");
    }

    [Test]
    public static async Task Sharing_is_bounded_at_64_per_group_128_total_and_32_groups()
    {
        using var admission = NewAdmission(); var leases = new List<BridgeAdmission.Lease>();
        var definition = Read((_, _, _) => Task.FromResult<object?>(true), kind: OperationClass.LocalRead);
        try
        {
            foreach (var key in new[] { "A", "B" })
            {
                for (var i = 0; i < 64; i++) { leases.Add(await admission.EnterAsync(key + i, definition, JsonSerializer.SerializeToElement(new { dn = key }), default, () => { })); }
                var perGroup = await Check.ThrowsAsync<BridgeOperationException>(() => admission.EnterAsync(key + "overflow", definition,
                    JsonSerializer.SerializeToElement(new { dn = key }), default, () => { }), "65e abonné refusé");
                Check.Equal("operation.sharedFull", perGroup.Code, "borne par groupe");
            }
            Check.Equal((2, 128), admission.SharedLoad, "128 abonnés réellement inscrits");
            var total = await Check.ThrowsAsync<BridgeOperationException>(() => admission.EnterAsync("new-group", definition, Empty, default, () => { }), "129e abonné refusé");
            Check.Equal("operation.sharedFull", total.Code, "borne totale");
            foreach (var lease in leases) { lease.Dispose(); } leases.Clear();
            for (var i = 0; i < 32; i++) { leases.Add(await admission.EnterAsync("group" + i, definition, JsonSerializer.SerializeToElement(new { dn = "unique" + i }), default, () => { })); }
            Check.Equal((32, 32), admission.SharedLoad, "32 groupes réels");
            var groups = await Check.ThrowsAsync<BridgeOperationException>(() => admission.EnterAsync("group-overflow", definition, Empty, default, () => { }), "33e groupe refusé");
            Check.Equal("operation.sharedFull", groups.Code, "borne de groupes");
        }
        finally { foreach (var lease in leases) { lease.Dispose(); } }
        Check.Equal((0, 0), admission.SharedLoad, "aucune rétention après tous les départs");
    }

    [Test]
    public static async Task Follower_never_resets_group_age_or_changes_priority_requirements()
    {
        var clock = TestClock.Fixed(); using var admission = NewAdmission(clock); var held = await HoldNetwork(admission);
        var background = Read((_, _, _) => Task.FromResult<object?>(true), OperationPriority.Background);
        var oldest = admission.EnterAsync("oldest", background, Empty, default, () => { });
        var at = clock.GetUtcNow(); clock.Advance(BridgeAdmission.Aging);
        var follower = admission.EnterAsync("follower", background, Empty, default, () => { });
        var explicitRead = admission.EnterAsync("explicit", background with { Scheduling = background.Scheduling! with { Priority = OperationPriority.Explicit } }, Empty, default, () => { });
        try
        {
            Check.Equal((2, 3), admission.SharedLoad, "exigence explicite séparée du fond");
            Check.True(admission.CancelQueued("oldest"), "premier abonné retiré");
            await Check.ThrowsAsync<TaskCanceledException>(() => oldest, "retrait réel");
            foreach (var lease in held) { lease.Dispose(); }
            using var next = await follower.WaitAsync(TimeSpan.FromSeconds(5));
            using var other = await explicitRead.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(at, next.Entry.ScheduledAt, "vieillissement original conservé après départ de l’aîné");
            Check.Equal(OperationPriority.Background, next.Entry.Priority, "priorité inchangée");
            Check.False(ReferenceEquals(next.Entry.Shared, other.Entry.Shared), "aucune fusion d’exigences");
        }
        finally { foreach (var lease in held) { lease.Dispose(); } }
    }

    [Test]
    public static void Sharing_is_server_opt_in_for_closed_reads_and_never_for_writes_plans_or_credentials()
    {
        var read = Read((_, _, _) => Task.FromResult<object?>(true));
        foreach (var name in new[] { ReadName, "directory.branch.children", "directory.ou.search", "search.containers", "schema.read" })
        { Check.True(BridgeScheduling.Declare(read with { Name = name, Scheduling = null, ShareRead = false }).ShareRead, "liste fermée déclarée"); }
        foreach (var name in new[] { "search.run", "search.browse", "search.view", "search.preload", "requetes.wmi.schema", "test.plan", "accounts.credential" })
        {
            Check.Throws<ArgumentException>(() => new OperationRegistry([read with { Name = name }]), "partage hors liste refusé");
            Check.False(BridgeScheduling.Declare(read with { Name = name, Scheduling = null, ShareRead = false }).ShareRead, "aucun opt-in implicite");
        }
        Check.Throws<ArgumentException>(() => new OperationRegistry([read with { Class = OperationClass.Write }]), "écriture exclue");
        Check.Throws<ArgumentException>(() => new OperationRegistry([read with { Scheduling = read.Scheduling! with { Arguments = ["credential"] } }]), "argument sensible exclu");
    }

    [Test]
    public static async Task Cancelled_execution_qualifications_remain_bounded_until_the_capture_really_finishes()
    {
        var release = new TaskCompletionSource<BridgeSessionStamp>(TaskCreationOptions.RunContinuationsAsynchronously);
        var blocked = false; var captures = 0;
        using var admission = new BridgeAdmission(TestClock.Fixed(), _ =>
        {
            if (!blocked) { return Task.FromResult(new BridgeSessionStamp("session", "site")); }
            Interlocked.Increment(ref captures); return release.Task;
        });
        using var lease = await admission.EnterAsync("read", Read((_, _, _) => Task.FromResult<object?>(true)), Empty, default, () => { });
        Check.Equal(1, admission.Load.Running, "admission initiale réellement obtenue");
        blocked = true;
        try
        {
            for (var i = 0; i < BridgeAdmission.MaxPendingQualifications; i++)
            {
                using var stop = new CancellationTokenSource();
                var qualification = admission.RevalidateAsync(lease, stop.Token);
                stop.Cancel();
                await Check.ThrowsAsync<TaskCanceledException>(() => qualification, "seule l’attente est annulée");
            }
            Check.Equal(32, captures, "32 captures encore physiquement pendantes");
            var refused = await Check.ThrowsAsync<BridgeOperationException>(() => admission.RevalidateAsync(lease, default), "33e capture refusée");
            Check.Equal("operation.qualificationBusy", refused.Code, "cause exacte");
            Check.Equal(32, captures, "aucune nouvelle invocation du fournisseur");
        }
        finally { blocked = false; release.TrySetResult(new("session", "site")); }
    }

    [Test]
    public static async Task Invalid_or_oversized_arguments_cannot_attach_to_a_real_shared_read()
    {
        using var fixture = new Fixture(); var running = fixture.Request("valid");
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            await fixture.Request("secret", args: new { credential = "rejected" });
            Check.Equal("arguments.invalid", fixture.Final("secret").Error!.Code, "argument sensible refusé avant partage");
            await fixture.Dispatcher.HandleAsync(JsonSerializer.Serialize(new { id = "null", op = ReadName, args = (object?)null }), default).WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal("arguments.invalid", fixture.Final("null").Error!.Code, "null ne rejoint pas une lecture {} valide en contournant le schéma");
            await fixture.Request("oversized", args: new { dn = new string('x', BridgeScheduling.MaxQueuedMessageLength) });
            Check.Equal("operation.queuePayload", fixture.Final("oversized").Error!.Code, "enveloppe trop grande refusée avant conservation");
            Check.Equal(1, fixture.Calls, "seul le setup valide a exécuté le handler");
            Check.Equal(1, fixture.Dispatcher.AdmissionLoad.Running, "aucune admission supplémentaire");
        }
        finally { fixture.Release.TrySetResult(); await running; }
        Check.Equal("result", fixture.Final("valid").Kind, "preuve positive du setup");
    }

    [Test]
    public static async Task Schema_read_shares_the_real_service_and_delivers_its_progress_and_status_to_each_subscriber()
    {
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock,
            new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        var original = new SchemaOperations().CreateOperations(context).Single(d => d.Name == "schema.read");
        var started = Signal(); var release = Signal(); var joined = Signal(); var calls = 0;
        var declared = BridgeScheduling.Declare(original with { Handler = async (args, bridge, token) =>
        {
            Interlocked.Increment(ref calls); started.TrySetResult(); await release.Task;
            return await original.Handler(args, bridge, token);
        } });
        var sent = new ConcurrentQueue<BridgeResponse>();
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([declared], clock, token => BridgeScheduling.Capture(context, token)), response =>
        {
            sent.Enqueue(response);
            if (response.Id == "second" && response.Operation == "schema.read:admitted") { joined.TrySetResult(); }
        });
        Check.False((await SchemaService.From(context).StatusAsync(default)).Read, "aucun schéma avant le geste");
        var first = dispatcher.HandleAsync(Message("first", "schema.read"), default);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = dispatcher.HandleAsync(Message("second", "schema.read"), default);
        try
        {
            await joined.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(1, calls, "un seul appel au service de lecture");
            release.TrySetResult(); await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(5));
            foreach (var id in new[] { "first", "second" })
            {
                var result = sent.Single(r => r.Id == id && r.Kind == "result");
                Check.True(((SchemaStatus)result.Data!).Read, "statut du vrai service reçu");
                Check.True(sent.Any(r => r.Id == id && r.Operation == "schema.read:stage"), "progression reçue par chacun");
            }
            Check.True((await SchemaService.From(context).StatusAsync(default)).Read, "catalogue de session réellement construit");
        }
        finally { release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    private static BridgeAdmission NewAdmission(FixedTimeProvider? clock = null) => new(clock ?? TestClock.Fixed(), _ => Task.FromResult(new BridgeSessionStamp("session", "site")));
    private static async Task<List<BridgeAdmission.Lease>> HoldNetwork(BridgeAdmission admission)
    {
        var held = new List<BridgeAdmission.Lease>();
        var operation = new OperationDefinition("test.hold", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(true), "Occupation");
        for (var i = 0; i < 8; i++) { held.Add(await admission.EnterAsync("hold" + i, operation, Empty, default, () => { })); }
        return held;
    }

    private sealed class Fixture : IDisposable
    {
        internal readonly TaskCompletionSource Started = Signal(), Release = Signal(), CancelObserved = Signal(), Completed = Signal();
        private readonly ConcurrentDictionary<string, TaskCompletionSource> events = new();
        private readonly ConcurrentDictionary<int, TaskCompletionSource> entries = new();
        internal readonly ConcurrentQueue<BridgeResponse> Responses = new();
        internal BridgeSessionStamp Stamp = new("session-a", "site");
        internal BridgeDispatcher Dispatcher { get; }
        internal CancellationToken HandlerToken;
        internal BridgeContext? Context;
        internal int Calls;
        internal Fixture()
        {
            var registry = new OperationRegistry([Read(async (arguments, context, token) =>
            {
                BridgeArguments.ReadObject(arguments, ["dn"]);
                using var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory);
                using var registration = token.Register(() => CancelObserved.TrySetResult());
                HandlerToken = token; Context = context;
                var call = Interlocked.Increment(ref Calls);
                entries.GetOrAdd(call, _ => Signal()).TrySetResult(); Started.TrySetResult();
                try { await Release.Task.ConfigureAwait(false); return new[] { "OU=Stable,DC=test" }; }
                finally { Completed.TrySetResult(); }
            })], TestClock.Fixed(), _ => Task.FromResult(Volatile.Read(ref Stamp)));
            Dispatcher = new(registry, response =>
            {
                Responses.Enqueue(response);
                if (response.Kind == "event") { events.GetOrAdd(response.Id + ":" + response.Operation, _ => Signal()).TrySetResult(); }
            });
        }
        internal Task Request(string id, CancellationToken token = default, object? args = null) => Dispatcher.HandleAsync(Message(id, args: args), token);
        internal Task Event(string id, string name) => events.GetOrAdd(id + ":" + ReadName + ":" + name, _ => Signal()).Task;
        internal Task Entry(int number) => entries.GetOrAdd(number, _ => Signal()).Task;
        internal BridgeResponse Final(string id) => Responses.Last(r => r.Id == id && r.Kind is "error" or "result");
        public void Dispose() { Release.TrySetResult(); Dispatcher.Dispose(); }
    }
}
