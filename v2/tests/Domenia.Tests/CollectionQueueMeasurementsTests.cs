using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class CollectionQueueMeasurementsTests
{
    private sealed class Clock : TimeProvider
    {
        private long elapsed;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Interlocked.Read(ref elapsed);
        public override DateTimeOffset GetUtcNow() => Fixtures.Now + TimeSpan.FromTicks(GetTimestamp());
        public void Advance(TimeSpan value) => Interlocked.Add(ref elapsed, value.Ticks);
    }
    private static readonly JsonElement Empty = JsonSerializer.SerializeToElement(new { });
    private static OperationDefinition Read(OperationPriority priority, bool shared = false) =>
        new("test.read", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(true), "Lecture locale de test")
        { Scheduling = new(priority, OperationProvider.Directory, []), ShareRead = shared };
    private static Task<BridgeAdmission.Lease> Enter(BridgeAdmission admission, string id, OperationDefinition definition, Action? queued = null, CancellationToken token = default) =>
        admission.EnterAsync(id, definition, Empty, token, queued ?? (() => { }));
    private static async Task<List<BridgeAdmission.Lease>> Hold(BridgeAdmission admission, int count)
    {
        var held = new List<BridgeAdmission.Lease>();
        var immediate = new OperationDefinition("test.hold", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(null), "Place de test");
        for (var n = 0; n < count; n++) held.Add(await Enter(admission, "held" + n, immediate));
        return held;
    }

    [Test]
    public static async Task Real_selection_queue_records_its_wait_once_and_cancelled_requests_are_not_admissions()
    {
        var clock = new Clock(); var activity = new OperationActivity(clock, new RecordingJournal(), false);
        using var admission = new BridgeAdmission(clock, _ => Task.FromResult(new BridgeSessionStamp("a", "ou")), activity: activity);
        var held = await Hold(admission, 8);
        var notified = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var waiting = Enter(admission, "selection", Read(OperationPriority.Selection), () => notified.TrySetResult());
        try
        {
            await notified.Task.WaitAsync(TimeSpan.FromSeconds(5));
            clock.Advance(TimeSpan.FromSeconds(2)); held[0].Dispose();
            using var lease = await waiting.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(2000.0, lease.Entry.QueueWaitMs!.Value, "intervalle réel d’admission indépendant du handler");
            var row = activity.QueueMeasuresSnapshot().Single(r => r.Class == CollectionQueueClass.Selection);
            Check.Equal(1L, row.Admitted, "sélection réellement admise une seule fois");
            Check.Equal(2000.0, row.Wait.P50!.Value, "médiane de la file, pas du traitement");
            Check.False(row.Wait.P95Stated, "un échantillon ne fabrique pas un P95");
            using var stop = new CancellationTokenSource();
            var queued = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var cancelled = Enter(admission, "cancelled", Read(OperationPriority.Explicit), () => queued.TrySetResult(), stop.Token);
            await queued.Task.WaitAsync(TimeSpan.FromSeconds(5)); stop.Cancel();
            try { using var unused = await cancelled; throw new TestFailureException("Lecture annulée admise."); }
            catch (OperationCanceledException) { }
            catch (BridgeOperationException error) when (error.Code == "operation.cancelled") { }
            Check.Equal(8L, activity.QueueMeasuresSnapshot().Single(r => r.Class == CollectionQueueClass.Explicit).Admitted, "le retrait ne crée ni zéro ni admission terminée");
        }
        finally { foreach (var lease in held) lease.Dispose(); }
    }

    [Test]
    public static async Task Actual_aging_promotion_and_shared_subscribers_are_counted_without_duplicates()
    {
        var clock = new Clock(); var activity = new OperationActivity(clock, new RecordingJournal(), false);
        using var admission = new BridgeAdmission(clock, _ => Task.FromResult(new BridgeSessionStamp("a", "ou")), activity: activity);
        var held = await Hold(admission, 7);
        var notified = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = Enter(admission, "aged", Read(OperationPriority.Background), () => notified.TrySetResult());
        try
        {
            await notified.Task.WaitAsync(TimeSpan.FromSeconds(5));
            clock.Advance(BridgeAdmission.Aging); await admission.RefreshAsync();
            using var aged = await pending.WaitAsync(TimeSpan.FromSeconds(5));
            await admission.RefreshAsync();
            var row = activity.QueueMeasuresSnapshot().Single(r => r.Class == CollectionQueueClass.Background);
            Check.Equal(1L, row.Promotions, "une vraie promotion, pas chaque passage de l’ordonnanceur");
            Check.Equal(30000.0, row.Wait.P50!.Value, "attente mesurée de bout en bout");
        }
        finally { foreach (var lease in held) lease.Dispose(); }
        var before = activity.QueueMeasuresSnapshot().Single(r => r.Class == CollectionQueueClass.Explicit).Admitted;
        using var first = await Enter(admission, "shared-first", Read(OperationPriority.Explicit, shared: true));
        clock.Advance(TimeSpan.FromSeconds(4));
        using var second = await Enter(admission, "shared-second", Read(OperationPriority.Explicit, shared: true));
        Check.Equal(1, admission.Load.Network, "un seul emplacement physique partagé");
        Check.Equal(0.0, second.Entry.QueueWaitMs!.Value, "abonné tardif ne reçoit pas l’âge du premier");
        Check.Equal(before + 2, activity.QueueMeasuresSnapshot().Single(r => r.Class == CollectionQueueClass.Explicit).Admitted, "chaque requête est comptée une seule fois");
    }

    [Test]
    public static void Queue_percentiles_keep_only_512_samples_and_the_real_registry_publishes_them()
    {
        var bridge = new SimulatedBridge(modules: [new OperationsOperations()]);
        var activity = OperationActivity.From(bridge.Context);
        Check.True(ReferenceEquals(activity, bridge.Registry.Activity), "registre produit relié à sa propre session");
        for (var n = 1; n <= 600; n++) activity.RecordQueueAdmission(CollectionQueueClass.Selection, n, false);
        var row = activity.QueueMeasuresSnapshot().Single(r => r.Class == CollectionQueueClass.Selection);
        Check.Equal(600L, row.Admitted, "compteur total distinct de la fenêtre statistique");
        Check.Equal(512, row.Wait.Count, "mémoire bornée"); Check.True(row.Wait.P95Stated, "assez de mesures réelles");
        Check.Equal(344.0, row.Wait.P50!.Value, "médiane des 512 dernières attentes");
        Check.True(activity.ClassLines().Any(line => line.Contains("Attente en file · sélection", StringComparison.Ordinal)), "ligne Sélection vraiment mesurée");
    }
}
