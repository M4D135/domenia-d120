using Domenia.Core;

namespace Domenia.Tests;

internal static class ReadProgressDeadlineTests
{
    [Test]
    public static void Completed_rows_extend_idle_but_not_absolute_deadline()
    {
        var clock = new Clock();
        using var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(120), TimeSpan.FromSeconds(900));
        for (var i = 0; i < 8; i++) { clock.Advance(TimeSpan.FromSeconds(100)); deadline.Progress(1); }
        Check.False(deadline.Token.IsCancellationRequested, "800 secondes avec progression réelle");
        clock.Advance(TimeSpan.FromSeconds(100));
        Check.Throws<OperationCanceledException>(() => deadline.Progress(1), "900 secondes : aucun renouvellement tardif");
        var state = deadline.Snapshot();
        Check.Equal(8L, state.Received, "la neuvième ligne hors budget ne renouvelle rien");
        Check.Equal("Plafond total atteint", state.StopReason, "cause absolue");
        Check.Equal(TimeSpan.FromSeconds(900), state.Elapsed, "temps total");
        Check.Equal(TimeSpan.FromSeconds(100), state.Idle, "inactivité réelle");
    }

    [Test]
    public static void Inactivity_expires_at_boundary_and_cannot_be_revived()
    {
        var clock = new Clock();
        using var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(120), TimeSpan.FromSeconds(900));
        clock.Advance(TimeSpan.FromSeconds(119)); deadline.Progress(2);
        clock.Advance(TimeSpan.FromSeconds(120));
        Check.Contains("sans nouvelle", deadline.Snapshot().StopReason, "inactivité distincte du total");
        Check.Throws<OperationCanceledException>(() => deadline.Progress(1), "une ligne tardive ne réanime pas la lecture");
        Check.Equal(2L, deadline.Snapshot().Received, "seules les lignes à temps sont comptées");
    }

    [Test]
    public static void A_backward_clock_never_extends_read_ownership()
    {
        var clock = new Clock();
        using var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(120), TimeSpan.FromSeconds(900));
        clock.Advance(TimeSpan.FromSeconds(5)); deadline.Progress(1);
        clock.Advance(TimeSpan.FromSeconds(-1));
        Check.Equal("Horloge invalide", deadline.Snapshot().StopReason, "retour arrière refusé");
        Check.True(deadline.Token.IsCancellationRequested, "annulation demandée sans preuve de fin native");
    }

    [Test]
    public static void Zero_progress_cannot_refresh_a_read()
    {
        var clock = new Clock();
        using var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30));
        Check.Throws<ArgumentOutOfRangeException>(() => deadline.Progress(0), "un heartbeat n’est pas du travail terminé");
        clock.Advance(TimeSpan.FromSeconds(10));
        Check.Equal(0L, deadline.Snapshot().Received, "aucune ligne inventée");
        Check.True(deadline.Token.IsCancellationRequested, "temps écoulé sans progression");
    }

    [Test]
    public static void Cancellation_callbacks_can_read_the_state_from_another_thread()
    {
        var clock = new Clock();
        using var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30));
        using var registration = deadline.Token.Register(() =>
        {
            var read = Task.Run(deadline.Snapshot);
            Check.True(read.Wait(TimeSpan.FromSeconds(5)), "aucun verrou conservé pendant les callbacks");
            Check.NotNull(read.GetAwaiter().GetResult().StopReason, "cause visible");
        });
        clock.Advance(TimeSpan.FromSeconds(10)); deadline.Snapshot();
    }
    [Test]
    public static void A_paused_process_start_is_neither_progress_nor_inactivity_and_the_total_still_runs()
    {
        // Bench of 11/11/2026: after a silent query, the start of the fresh reading process was cut by the 25 s idle limit
        // and the 22 sources after it were lost. The start is excluded from inactivity, never credited as progress.
        var clock = new Clock();
        using (var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(25), TimeSpan.FromSeconds(55)))
        {
            clock.Advance(TimeSpan.FromSeconds(15));
            var pause = deadline.PauseInactivity();
            clock.Advance(TimeSpan.FromSeconds(12));
            var starting = deadline.Snapshot();
            Check.Null(starting.StopReason, "démarrage du processus de lecture hors inactivité");
            Check.Equal(TimeSpan.FromSeconds(15), starting.Idle, "le démarrage ne compte pas comme silence");
            pause.Dispose(); pause.Dispose();
            var resumed = deadline.Snapshot();
            Check.Equal(0L, resumed.Received, "le démarrage ne compte pas comme travail");
            Check.Equal(TimeSpan.FromSeconds(15), resumed.Idle, "inactivité reprise là où elle était, une seule fois");
            clock.Advance(TimeSpan.FromSeconds(9) + TimeSpan.FromMilliseconds(900));
            Check.Null(deadline.Snapshot().StopReason, "24,9 s d’inactivité réelle");
            clock.Advance(TimeSpan.FromMilliseconds(100));
            Check.Contains("sans nouvelle", deadline.Snapshot().StopReason, "limite d’inactivité inchangée après le démarrage");
            Check.True(deadline.Token.IsCancellationRequested, "arrêt demandé");
        }

        clock = new Clock();
        using (var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(25), TimeSpan.FromSeconds(55)))
        {
            using var pause = deadline.PauseInactivity();
            clock.Advance(TimeSpan.FromSeconds(55));
            Check.Equal("Plafond total atteint", deadline.Snapshot().StopReason, "le plafond total court pendant le démarrage");
            Check.True(deadline.Token.IsCancellationRequested, "arrêt au plafond même en démarrage");
        }

        clock = new Clock();
        using (var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(25), TimeSpan.FromSeconds(55)))
        {
            clock.Advance(TimeSpan.FromSeconds(25));
            using var pause = deadline.PauseInactivity();
            clock.Advance(TimeSpan.FromSeconds(1));
            Check.Contains("sans nouvelle", deadline.Snapshot().StopReason, "une pause ne réanime pas une lecture déjà arrêtée");
            Check.True(deadline.Token.IsCancellationRequested, "arrêt conservé");
        }

        clock = new Clock();
        using (var deadline = new ReadProgressDeadline(clock, TimeSpan.FromSeconds(25), TimeSpan.FromSeconds(55)))
        {
            var first = deadline.PauseInactivity(); var second = deadline.PauseInactivity();
            clock.Advance(TimeSpan.FromSeconds(30));
            first.Dispose();
            clock.Advance(TimeSpan.FromSeconds(10));
            Check.Null(deadline.Snapshot().StopReason, "pause tenue tant qu’un démarrage reste en cours");
            second.Dispose();
            Check.Equal(TimeSpan.Zero, deadline.Snapshot().Idle, "aucune inactivité comptée pendant les démarrages");
            clock.Advance(TimeSpan.FromSeconds(15));
            Check.Equal("Plafond total atteint", deadline.Snapshot().StopReason, "plafond total de 55 s inchangé");
        }
    }

    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = TestClock.Reference;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan elapsed) => now += elapsed;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) => new PassiveTimer();
        private sealed class PassiveTimer : ITimer
        {
            public bool Change(TimeSpan dueTime, TimeSpan period) => true;
            public void Dispose() { }
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }

}
