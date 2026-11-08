using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class QueueTimingTests
{
    private static readonly JsonElement Empty = JsonSerializer.SerializeToElement(new { });
    private static QueueTiming Timing(string json) => QueueTiming.From(ConfigurationRules.Read(System.Text.Encoding.UTF8.GetBytes(json), "test"));
    private static OperationDefinition Read(bool background = false) => new("timing.read", OperationClass.NetworkRead,
        (_, _, _) => Task.FromResult<object?>(true), "Lecture")
    { Scheduling = new(background ? OperationPriority.Background : OperationPriority.Explicit, OperationProvider.Directory, []) };
    private static Task<BridgeAdmission.Lease> Enter(BridgeAdmission admission, string id, OperationDefinition definition) =>
        admission.EnterAsync(id, definition, Empty, CancellationToken.None, () => { });
    private static async Task<List<BridgeAdmission.Lease>> Hold(BridgeAdmission admission, int count)
    {
        var result = new List<BridgeAdmission.Lease>();
        for (var i = 0; i < count; i++) result.Add(await Enter(admission, "held-" + i, Read() with { Scheduling = null }));
        return result;
    }

    [Test]
    public static void Queue_values_use_the_displayed_defaults_bounds_and_invalid_document_policy()
    {
        var bounded = Timing("""{"Async":{"BackgroundAgingSeconds":1,"MaxQueueWaitSeconds":9999,"TickBudgetMs":1}}""");
        Check.Equal(5, bounded.BackgroundAgingSeconds, "vieillissement borné à cinq secondes");
        Check.Equal(600, bounded.MaxQueueWaitSeconds, "attente bornée à dix minutes");
        Check.Equal(5, bounded.TickBudgetMilliseconds, "budget de promotion borné");
        Check.Equal(QueueTiming.Default, Timing("""{"Async":{"MaxQueueWaitSeconds":5},"async":{"MaxQueueWaitSeconds":6}}"""),
            "document ambigu entièrement ignoré, comme le rapport de configuration");
    }

    [Test]
    public static async Task Configured_aging_promotes_one_background_without_exceeding_physical_admission()
    {
        var clock = TestClock.Fixed();
        using var admission = new BridgeAdmission(clock, _ => Task.FromResult(new BridgeSessionStamp("timing", "site")),
            Timing("""{"Async":{"BackgroundAgingSeconds":5}}"""));
        var held = await Hold(admission, 7);
        var pending = Enter(admission, "background", Read(background: true));
        try
        {
            clock.Advance(TimeSpan.FromSeconds(4)); await admission.RefreshAsync();
            Check.False(pending.IsCompleted, "réservation maintenue avant le délai choisi");
            clock.Advance(TimeSpan.FromSeconds(1)); await admission.RefreshAsync();
            using var admitted = await pending.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(8, admission.Load.Network, "la place réservée est accessible au délai configuré, sans neuvième lecture");
        }
        finally { admission.CancelQueued("background"); foreach (var lease in held) lease.Dispose(); }
    }

    [Test]
    public static async Task Configured_expiration_withdraws_before_send_and_keeps_running_slots()
    {
        var clock = TestClock.Fixed();
        using var admission = new BridgeAdmission(clock, _ => Task.FromResult(new BridgeSessionStamp("timing", "site")),
            Timing("""{"Async":{"MaxQueueWaitSeconds":5}}"""));
        var held = await Hold(admission, 8);
        var pending = Enter(admission, "expired", Read());
        try
        {
            clock.Advance(TimeSpan.FromSeconds(4)); await admission.RefreshAsync();
            Check.False(pending.IsCompleted, "pas de retrait prématuré");
            clock.Advance(TimeSpan.FromSeconds(1)); await admission.RefreshAsync();
            var error = await Check.ThrowsAsync<BridgeOperationException>(() => pending, "retrait au délai choisi");
            Check.Equal("operation.queueExpired", error.Code, "motif exact du retrait avant envoi");
            Check.True(error.Message.Contains("5 secondes", StringComparison.Ordinal), "message issu de la valeur effective");
            Check.Equal(8, admission.Load.Network, "aucune place physique libérée par le seul retrait");
        }
        finally { admission.CancelQueued("expired"); foreach (var lease in held) lease.Dispose(); }
    }

    [Test]
    public static async Task A_longer_configured_wait_survives_the_old_constant_and_is_shown_exactly()
    {
        var clock = TestClock.Fixed();
        using var admission = new BridgeAdmission(clock, _ => Task.FromResult(new BridgeSessionStamp("timing", "site")),
            Timing("""{"Async":{"MaxQueueWaitSeconds":180}}"""));
        var held = await Hold(admission, 8);
        var pending = Enter(admission, "longer", Read());
        try
        {
            clock.Advance(TimeSpan.FromSeconds(121)); await admission.RefreshAsync();
            Check.False(pending.IsCompleted, "ancienne constante de 120 secondes remplacée");
            Check.Equal(121, admission.Snapshot().Reads.Single().WaitedSeconds, "attente observée non tronquée à 120");
            held[0].Dispose();
            using var admitted = await pending.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { admission.CancelQueued("longer"); foreach (var lease in held) lease.Dispose(); }
    }
}
