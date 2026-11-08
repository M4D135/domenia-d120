using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class CollectionReadRetryTests
{
    private static readonly CollectionRetryEvidence Transient = new(CollectionReadFailure.Transient, true, true);

    [Test]
    public static void Retry_requires_transient_reachable_completed_read_and_never_replays_a_write()
    {
        CollectionRetryDecision Decide(CollectionRetryEvidence value, bool write = false) =>
            CollectionReadRetry.Decide(value, 1, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(15), write);
        Check.True(Decide(Transient).Retry, "incident de lecture natif qualifié");
        Check.False(Decide(Transient, true).Retry, "écriture jamais rejouée");
        Check.False(Decide(Transient with { Reachable = false }).Retry, "aucune preuve de présence");
        Check.False(Decide(Transient with { PhysicallyCompleted = false }).Retry, "appel natif encore détenu");
        foreach (var failure in Enum.GetValues<CollectionReadFailure>().Where(value => value != CollectionReadFailure.Transient))
            Check.False(Decide(Transient with { Failure = failure }).Retry, "aucun rejeu pour " + failure);
        Check.False(Decide(Transient with { Failure = (CollectionReadFailure)999 }).Retry, "valeur inconnue refusée");
    }

    [Test]
    public static void Retry_combination_never_hides_denied_credentials_missing_capabilities_or_unknown_failures()
    {
        foreach (var failure in new[] { CollectionReadFailure.CredentialRejected, CollectionReadFailure.AccessDenied,
            CollectionReadFailure.ClassAbsent, CollectionReadFailure.ProtocolUnavailable, CollectionReadFailure.Unknown })
        {
            var combined = CollectionReadRetry.Combine([CollectionReadFailure.Success, CollectionReadFailure.Transient, failure]);
            Check.Equal(failure, combined, "un succès ou délai ne masque pas un refus");
            Check.False(CollectionReadRetry.Decide(new(combined, true, true), 1, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(15)).Retry, "aucune reprise");
        }
        Check.Equal(CollectionReadFailure.Unknown, CollectionReadRetry.Combine([]), "absence de faits distincte du succès");
    }

    [Test]
    public static async Task Retry_makes_three_attempts_with_acknowledgment_before_thirty_and_one_hundred_twenty_seconds()
    {
        var clock = new Clock(); var waits = new List<TimeSpan>(); var acknowledgments = new List<int>(); var calls = 0;
        var retry = new CollectionReadRetry(clock) { DelayOverride = (delay, token) =>
        {
            token.ThrowIfCancellationRequested();
            Check.Equal(calls, acknowledgments.Count, "les observations sont acquittées avant l’attente");
            waits.Add(delay); clock.Advance(delay); return Task.CompletedTask;
        } };
        var result = await retry.RunAsync(_ => Task.FromResult(++calls), _ => Transient, () => { }, TimeSpan.FromSeconds(15), default,
            acknowledge: value => { acknowledgments.Add(value); return Task.CompletedTask; });
        Check.Equal(3, calls, "trois essais au total"); Check.Equal(3, result, "dernier résultat réel");
        Check.Equal(2, waits.Count, "aucune attente après le troisième essai");
        Check.Equal(TimeSpan.FromSeconds(30), waits[0], "première attente");
        Check.Equal(TimeSpan.FromSeconds(120), waits[1], "seconde attente");
    }

    [Test]
    public static async Task Operator_retry_count_and_delay_are_effective_but_never_extend_the_total_deadline()
    {
        var calls = 0;
        await new CollectionReadRetry(new Clock(), new(0, 10)).RunAsync(_ => Task.FromResult(++calls), _ => Transient,
            () => { }, TimeSpan.FromSeconds(15), default);
        Check.Equal(1, calls, "zéro nouvel essai fait une seule tentative");
        var clock = new Clock(); var waits = new List<TimeSpan>(); calls = 0;
        var retry = new CollectionReadRetry(clock, new(4, 10)) { DelayOverride = (delay, _) =>
        { waits.Add(delay); clock.Advance(delay); return Task.CompletedTask; } };
        await retry.RunAsync(_ => Task.FromResult(++calls), _ => Transient, () => { }, TimeSpan.FromSeconds(15), default);
        Check.Equal(4, calls, "le plafond de cinq minutes interdit un cinquième essai malgré quatre reprises autorisées");
        Check.True(waits.SequenceEqual(new[] { TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(40), TimeSpan.FromSeconds(160) }), "délai configuré et temporisation exponentielle effectifs");
        Check.False(CollectionReadRetry.Decide(Transient with { Failure = CollectionReadFailure.CredentialRejected }, 1,
            TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(15), policy: new(4, 10)).Retry, "plus de reprises ne contourne jamais un refus d’identifiants");
    }

    [Test]
    public static async Task Retry_stops_on_cancel_without_losing_the_completed_acknowledgment_or_sending_again()
    {
        var clock = new Clock(); var calls = 0; var saved = 0; using var stop = new CancellationTokenSource();
        var retry = new CollectionReadRetry(clock) { DelayOverride = (_, token) =>
        { stop.Cancel(); token.ThrowIfCancellationRequested(); return Task.CompletedTask; } };
        await Check.ThrowsAsync<OperationCanceledException>(() => retry.RunAsync(_ => Task.FromResult(++calls), _ => Transient,
            () => { }, TimeSpan.FromSeconds(15), stop.Token, acknowledge: value => { saved = value; return Task.CompletedTask; }), "annulation de l’attente");
        Check.Equal(1, calls, "aucun deuxième envoi"); Check.Equal(1, saved, "observation reçue conservée");
    }

    [Test]
    public static async Task Retry_rechecks_context_after_wait_and_does_not_switch_accounts()
    {
        var clock = new Clock(); var calls = 0; var changed = false;
        var retry = new CollectionReadRetry(clock) { DelayOverride = (delay, _) =>
        { clock.Advance(delay); changed = true; return Task.CompletedTask; } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => retry.RunAsync(_ => Task.FromResult(++calls), _ => Transient,
            () => { if (changed) throw new DomeniaOperationException(AccountAccess.EpochChanged, "Contexte changé."); },
            TimeSpan.FromSeconds(15), default), "compte changé pendant le délai");
        Check.Equal(1, calls, "aucun envoi sous le nouveau compte");
    }

    [Test]
    public static async Task Retry_does_not_reset_its_total_budget_or_replay_an_unfinished_native_work()
    {
        var clock = new Clock(); var calls = 0;
        var retry = new CollectionReadRetry(clock) { DelayOverride = (_, _) =>
        { clock.Advance(TimeSpan.FromMinutes(6)); return Task.CompletedTask; } };
        Check.Equal(1, await retry.RunAsync(_ => Task.FromResult(++calls), _ => Transient, () => { }, TimeSpan.FromSeconds(15), default), "délai dépassé conserve le résultat");
        Check.Equal(1, calls, "pas d’envoi après expiration");
        calls = 0;
        await retry.RunAsync(_ => Task.FromResult(++calls), _ => Transient with { PhysicallyCompleted = false }, () => { }, TimeSpan.FromSeconds(15), default);
        Check.Equal(1, calls, "le simple retour à l’interface n’autorise pas une reprise physique");
    }

    [Test]
    public static void Retry_budget_reserves_the_whole_next_attempt_and_cached_results_cannot_authorize_it()
    {
        Check.False(CollectionReadRetry.Decide(Transient, 1, TimeSpan.FromSeconds(44), TimeSpan.FromSeconds(15)).Retry, "30 + 15 secondes ne tiennent pas");
        Check.True(CollectionReadRetry.Decide(Transient, 1, TimeSpan.FromSeconds(45), TimeSpan.FromSeconds(15)).Retry, "borne exacte");
        var live = new WorkstationInventoryRead(InventoryMeasure.Unread, new(null, null, null, null, MeasureState.NotRead, null, null))
            { RetryFailure = CollectionReadFailure.Transient, ReadPhysicallyCompleted = true };
        var cached = JsonSerializer.Deserialize<WorkstationInventoryRead>(JsonSerializer.Serialize(live))!;
        Check.False(cached.ReadPhysicallyCompleted, "une sérialisation ne conserve pas la preuve de fin physique");
        Check.Equal(CollectionReadFailure.Unknown, cached.RetryFailure, "l’ancien résultat ne relance aucune lecture");
        var access = new SourceAccess("CIM", SourceStatus.Interrupted, "Délai", 1, 0, InventoryTransport.Dcom) { RetryFailure = CollectionReadFailure.Transient };
        Check.Equal(CollectionReadFailure.Unknown, JsonSerializer.Deserialize<SourceAccess>(JsonSerializer.Serialize(access))!.RetryFailure, "accès stocké sans autorité de reprise");
    }

    [Test]
    public static async Task Retry_total_deadline_cancels_admission_without_issuing_another_read()
    {
        var clock = new Clock(); var calls = 0; var sends = 0; var saved = 0;
        var waiting = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var admission = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var retry = new CollectionReadRetry(clock) { DelayOverride = (delay, _) =>
        { clock.Advance(delay); return Task.CompletedTask; } };
        var pending = retry.RunAsync(async token =>
        {
            if (++calls > 1) { waiting.TrySetResult(); await admission.Task.WaitAsync(token); }
            token.ThrowIfCancellationRequested();
            return ++sends;
        }, _ => Transient, () => { }, TimeSpan.FromSeconds(15), default,
            acknowledge: value => { saved = value; return Task.CompletedTask; });
        await waiting.Task.WaitAsync(TimeSpan.FromSeconds(5));
        clock.Advance(CollectionReadRetry.MaximumDuration);
        Check.Equal(1, await pending.WaitAsync(TimeSpan.FromSeconds(5)), "dernier résultat qualifié conservé à l’échéance");
        Check.Equal(1, sends, "aucun envoi après l’attente d’admission expirée");
        Check.Equal(1, saved, "premier résultat acquitté avant attente");
    }

    private sealed class Clock : TimeProvider
    {
        private long ticks;
        private readonly List<Timer> timers = [];
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => ticks;
        public override DateTimeOffset GetUtcNow() => TestClock.Reference + TimeSpan.FromTicks(ticks);
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new Timer(this, callback, state); timer.Change(dueTime, period); timers.Add(timer); return timer;
        }
        internal void Advance(TimeSpan elapsed)
        { ticks += elapsed.Ticks; foreach (var timer in timers.ToArray()) timer.Fire(ticks); }

        private sealed class Timer(Clock clock, TimerCallback callback, object? state) : ITimer
        {
            private long due = long.MaxValue;
            private bool disposed;
            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                if (disposed) return false;
                if (period != Timeout.InfiniteTimeSpan) throw new InvalidOperationException("Fixture : délai unique uniquement.");
                due = dueTime == Timeout.InfiniteTimeSpan ? long.MaxValue : clock.GetTimestamp() + dueTime.Ticks;
                return true;
            }
            internal void Fire(long now) { if (!disposed && now >= due) { due = long.MaxValue; callback(state); } }
            public void Dispose() { disposed = true; }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
