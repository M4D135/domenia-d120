using System.Collections.Concurrent;
using System.Text.Json;
using Domenia.Bridge;

namespace Domenia.Tests;

internal static class BridgeQueueTests
{
    private static string Message(string id, string op, object? args = null) => JsonSerializer.Serialize(new { id, op, args = args ?? new { } });

    [Test]
    public static async Task Queue_view_is_bounded_and_never_exposes_arguments_targets_or_session_stamps()
    {
        using var fixture = new QueueFixture();
        await fixture.FillAsync();
        var pending = Enumerable.Range(0, 32).Select(i => fixture.Queue("q" + i)).ToArray();
        try
        {
            await fixture.Notices(32).WaitAsync(TimeSpan.FromSeconds(5));
            var view = await fixture.ViewAsync();
            Check.Equal(32, view.Waiting, "file pleine réelle"); Check.Equal(32, view.Reads.Count, "snapshot borné");
            Check.Equal("q0", view.Reads[0].RequestId, "ordre de demande"); Check.Equal("q31", view.Reads[^1].RequestId, "dernière demande");
            var json = JsonSerializer.Serialize(view);
            Check.False(json.Contains("Sensitive", StringComparison.Ordinal), "arguments et cible exclus");
            Check.False(json.Contains("standalone", StringComparison.Ordinal), "contexte de session exclu");
            Check.True(view.Reads.All(r => r.Operation == "test.queued" && r.WaitedSeconds is >= 0 and <= 120), "opérations et attente qualifiées");
            foreach (var row in view.Reads) { Check.True((await fixture.CancelAsync(row.RequestId)).Removed, "retrait de chacune avant envoi"); }
            await Task.WhenAll(pending);
            Check.Equal(0, fixture.ReadCalls, "aucun handler lancé par la lecture du snapshot ni par le retrait");
        }
        finally { fixture.Release(); await fixture.DrainAsync(pending); }
    }

    [Test]
    public static async Task Queue_cancellation_is_owned_by_the_dispatcher_and_removal_is_confirmed_only_once()
    {
        using var owner = new QueueFixture(); using var other = new QueueFixture();
        await owner.FillAsync(); var read = owner.Queue("private");
        try
        {
            await owner.Notices(1).WaitAsync(TimeSpan.FromSeconds(5));
            var foreign = await other.CancelAsync("private");
            Check.False(foreign.Removed, "un autre dispatcher ne retire rien"); Check.Equal("notQueued", foreign.State, "absence locale exacte");
            Check.Equal(1, (await owner.ViewAsync()).Waiting, "lecture conservée chez son propriétaire");
            var own = await owner.CancelAsync("private"); Check.True(own.Removed, "retrait réel"); Check.Equal("withdrawn", own.State, "preuve avant envoi");
            await read;
            Check.Equal("operation.cancelled", owner.Responses.Last(r => r.Id == "private" && r.Kind == "error").Error!.Code, "demande originale terminée en annulation");
            Check.False((await owner.CancelAsync("private")).Removed, "aucun second succès inventé");
            Check.Equal(0, owner.ReadCalls, "aucun handler appelé");
        }
        finally { owner.Release(); await owner.DrainAsync([read]); }
    }

    [Test]
    public static async Task Queue_cancel_after_admission_never_claims_that_the_running_handler_stopped()
    {
        using var fixture = new QueueFixture(); await fixture.FillAsync();
        try
        {
            var result = await fixture.CancelAsync("hold0");
            Check.False(result.Removed, "handler déjà démarré"); Check.Equal("notQueued", result.State, "aucun faux succès");
            Check.True(result.Message.Contains("Aucun arrêt confirmé", StringComparison.Ordinal), "incertitude expliquée");
            Check.Equal(BridgeAdmission.NetworkLimit, fixture.Dispatcher.AdmissionLoad.Network, "ressources toujours tenues");
        }
        finally { fixture.Release(); await fixture.DrainAsync([]); }
    }

    [Test]
    public static async Task Queue_cancel_uses_reserved_control_admission_when_all_ordinary_places_are_held()
    {
        using var fixture = new QueueFixture(local: true); await fixture.FillAsync(); var read = fixture.Queue("waiting");
        try
        {
            await fixture.Notices(1).WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(BridgeAdmission.OrdinaryLimit, fixture.Dispatcher.AdmissionLoad.Running, "48 places occupées");
            Check.Equal("waiting", (await fixture.ViewAsync()).Reads.Single().RequestId, "lecture de file encore accessible pour choisir quoi retirer");
            Check.True((await fixture.CancelAsync("waiting")).Removed, "contrôle admis malgré saturation ordinaire");
            await read; Check.Equal(0, fixture.ReadCalls, "retrait sans exécution");
        }
        finally { fixture.Release(); await fixture.DrainAsync([read]); }
    }

    [Test]
    public static async Task Queue_controls_refuse_unknown_arguments_and_invalid_request_ids()
    {
        using var fixture = new QueueFixture();
        foreach (var args in new object[] { new { requestId = "x", password = "not-accepted" }, new { requestId = new string('x', 65) }, new { requestId = "x\n" } })
        {
            await fixture.Dispatcher.HandleAsync(Message("bad" + fixture.Responses.Count, "operations.queue.cancel", args), default);
            Check.Equal("arguments.invalid", fixture.Responses.Last().Error!.Code, "contrat fermé");
        }
        Check.Equal(0, fixture.Dispatcher.AdmissionLoad.Queued, "aucun contrôle en attente");
    }

    private sealed class QueueFixture : IDisposable
    {
        private readonly TaskCompletionSource release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource filled = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly ConcurrentDictionary<int, TaskCompletionSource> notices = new();
        private readonly int limit;
        private int entered, queued, request;
        private Task[] holds = [];
        internal int ReadCalls;
        internal ConcurrentQueue<BridgeResponse> Responses { get; } = new();
        internal BridgeDispatcher Dispatcher { get; }

        internal QueueFixture(bool local = false)
        {
            limit = local ? BridgeAdmission.OrdinaryLimit : BridgeAdmission.NetworkLimit;
            var kind = local ? OperationClass.LocalRead : OperationClass.NetworkRead;
            var registry = new OperationRegistry([
                .. BridgeQueueOperations.Definitions(),
                new("test.hold", kind, async (_, _, _) =>
                {
                    if (Interlocked.Increment(ref entered) == limit) { filled.TrySetResult(); }
                    await release.Task.ConfigureAwait(false); return true;
                }, "Lecture active"),
                new("test.queued", kind, (_, _, _) => { Interlocked.Increment(ref ReadCalls); return Task.FromResult<object?>(true); }, "Lecture préparée")
                { Scheduling = new(OperationPriority.Explicit, local ? OperationProvider.Local : OperationProvider.Cim, ["scope"], "scope") },
            ]);
            Dispatcher = new(registry, response =>
            {
                Responses.Enqueue(response);
                if (response.Kind == "event" && response.Operation == "test.queued:queued")
                { var number = Interlocked.Increment(ref queued); notices.GetOrAdd(number, _ => new(TaskCreationOptions.RunContinuationsAsynchronously)).TrySetResult(); }
            });
        }
        internal Task Notices(int number) => notices.GetOrAdd(number, _ => new(TaskCreationOptions.RunContinuationsAsynchronously)).Task;
        internal async Task FillAsync()
        {
            holds = Enumerable.Range(0, limit).Select(i => Dispatcher.HandleAsync(Message("hold" + i, "test.hold"), default)).ToArray();
            await filled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        internal Task Queue(string id) => Dispatcher.HandleAsync(Message(id, "test.queued", new { scope = "OU=Sensitive,DC=test,DC=local" }), default);
        internal async Task<BridgeQueueSnapshot> ViewAsync()
        {
            var id = "view" + Interlocked.Increment(ref request); await Dispatcher.HandleAsync(Message(id, "operations.queue.read"), default);
            return (BridgeQueueSnapshot)Responses.Single(r => r.Id == id && r.Kind == "result").Data!;
        }
        internal async Task<BridgeQueueCancellation> CancelAsync(string target)
        {
            var id = "cancel" + Interlocked.Increment(ref request); await Dispatcher.HandleAsync(Message(id, "operations.queue.cancel", new { requestId = target }), default);
            return (BridgeQueueCancellation)Responses.Single(r => r.Id == id && r.Kind == "result").Data!;
        }
        internal void Release() => release.TrySetResult();
        internal Task DrainAsync(Task[] pending) => Task.WhenAll([.. holds, .. pending]);
        public void Dispose() { Release(); Dispatcher.Dispose(); }
    }
}
