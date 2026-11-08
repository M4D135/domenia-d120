using System.Collections.Concurrent;
using System.Text.Json;
using Domenia.Bridge;

namespace Domenia.Tests;

internal static class BridgeAdmissionTests
{
    private static string Message(string id, string op) => JsonSerializer.Serialize(new { id, op, args = new { } });

    [Test]
    public static async Task Saturated_network_reads_leave_local_controls_responsive_and_are_never_replayed()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = new ConcurrentQueue<BridgeResponse>(); var calls = 0;
        var dispatcher = new BridgeDispatcher(new OperationRegistry([
            new("test.network", OperationClass.NetworkRead, async (_, _, _) =>
            {
                if (Interlocked.Increment(ref calls) == BridgeAdmission.NetworkLimit) { entered.SetResult(); }
                await release.Task.ConfigureAwait(false); return true;
            }, "read"),
            new("test.local", OperationClass.LocalRead, (_, _, _) => Task.FromResult<object?>("local"), "local"),
            new("test.stop", OperationClass.Local, (_, _, _) => Task.FromResult<object?>("arrêt reçu"), "stop"),
        ]), sent.Enqueue);
        var pending = Enumerable.Range(0, BridgeAdmission.NetworkLimit).Select(i => dispatcher.HandleAsync(Message("read" + i, "test.network"), CancellationToken.None)).ToArray();
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await dispatcher.HandleAsync(Message("overflow", "test.network"), CancellationToken.None);
            await dispatcher.HandleAsync(Message("local", "test.local"), CancellationToken.None);
            await dispatcher.HandleAsync(Message("stop", "test.stop"), CancellationToken.None);
            Check.Equal("operation.busy", sent.Single(x => x.Id == "overflow").Error!.Code, "saturation annoncée");
            Check.Equal("result", sent.Single(x => x.Id == "local").Kind, "lecture locale disponible");
            Check.Equal("result", sent.Single(x => x.Id == "stop").Kind, "arrêt disponible");
        }
        finally { release.TrySetResult(); }
        await Task.WhenAll(pending);
        Check.Equal(BridgeAdmission.NetworkLimit, calls, "demande refusée jamais exécutée plus tard");
        await dispatcher.HandleAsync(Message("new", "test.network"), CancellationToken.None);
        Check.Equal(BridgeAdmission.NetworkLimit + 1, calls, "nouveau geste admis après libération");
    }

    [Test]
    public static async Task Duplicate_request_id_cannot_launch_a_second_handler()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = new ConcurrentQueue<BridgeResponse>(); var calls = 0;
        var dispatcher = new BridgeDispatcher(new OperationRegistry([
            new("test.read", OperationClass.LocalRead, async (_, _, _) => { Interlocked.Increment(ref calls); await release.Task.ConfigureAwait(false); return null; }, "read"),
        ]), sent.Enqueue);
        var first = dispatcher.HandleAsync(Message("same", "test.read"), CancellationToken.None);
        try
        {
            await dispatcher.HandleAsync(Message("same", "test.read"), CancellationToken.None);
            Check.Equal("operation.duplicate", sent.Single().Error!.Code, "identifiant en cours refusé");
        }
        finally { release.TrySetResult(); }
        await first;
        Check.Equal(1, calls, "un seul appel réel");
    }

    [Test]
    public static async Task A_cancelled_or_failed_handler_releases_its_admission()
    {
        var sent = new ConcurrentQueue<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(new OperationRegistry([
            new("test.fail", OperationClass.NetworkRead, (_, _, _) => throw new BridgeOperationException("test.refused", "Refus attendu."), "failure"),
            new("test.ok", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(true), "success"),
        ]), sent.Enqueue);
        using var stopped = new CancellationTokenSource(); stopped.Cancel();
        await dispatcher.HandleAsync(Message("same", "test.ok"), stopped.Token);
        Check.Equal("operation.cancelled", sent.Last().Error!.Code, "annulation conservée");
        await dispatcher.HandleAsync(Message("same", "test.fail"), CancellationToken.None);
        Check.Equal("test.refused", sent.Last().Error!.Code, "emplacement récupéré après annulation");
        await dispatcher.HandleAsync(Message("same", "test.ok"), CancellationToken.None);
        Check.Equal("result", sent.Last().Kind, "emplacement récupéré après échec");
    }

    [Test]
    public static async Task Stop_operations_have_reserved_capacity_when_ordinary_work_is_full()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = new ConcurrentQueue<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(new OperationRegistry([
            new("test.local", OperationClass.Local, async (_, _, _) => { await release.Task.ConfigureAwait(false); return null; }, "work"),
            new("test.cancel", OperationClass.Local, (_, _, _) => Task.FromResult<object?>(true), "cancel"),
        ]), sent.Enqueue);
        var pending = Enumerable.Range(0, BridgeAdmission.OrdinaryLimit).Select(i => dispatcher.HandleAsync(Message("work" + i, "test.local"), CancellationToken.None)).ToArray();
        try
        {
            await dispatcher.HandleAsync(Message("extra", "test.local"), CancellationToken.None);
            await dispatcher.HandleAsync(Message("cancel", "test.cancel"), CancellationToken.None);
            Check.Equal("operation.busy", sent.Single(x => x.Id == "extra").Error!.Code, "travail ordinaire borné");
            Check.Equal("result", sent.Single(x => x.Id == "cancel").Kind, "annulation admise malgré saturation");
        }
        finally { release.TrySetResult(); }
        await Task.WhenAll(pending);
    }
}
