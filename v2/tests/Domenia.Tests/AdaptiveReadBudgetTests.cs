using System.DirectoryServices.Protocols;
using System.Net;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdaptiveReadBudgetTests
{
    private static readonly TimeSpan Fast = TimeSpan.FromMilliseconds(100);
    private static AdaptiveReadBudget Known(Clock clock, int maximum = 4)
    {
        var budget = new AdaptiveReadBudget(clock, maximum);
        budget.ObserveAddress("PC-A", IPAddress.Parse("192.0.2.10"));
        budget.ObserveAddress("PC-B", IPAddress.Parse("192.0.2.20"));
        return budget;
    }

    [Test]
    public static void Adaptive_observed_subnet_shares_capacity_but_not_the_controller_or_another_subnet()
    {
        var clock = new Clock(); var budget = Known(clock, 2);
        using var a = budget.Acquire("PC-A"); using var b = budget.Acquire("pc-b.");
        Check.Equal("operation.siteBusy", Check.Throws<DomeniaOperationException>(() => budget.Acquire("192.0.2.30"), "même /24 présumé").Code, "refus avant envoi");
        using var other = budget.Acquire("198.51.100.30"); using var dc = budget.Acquire("PC-A", controller: true);
        Check.Equal(2, budget.Snapshot("PC-A").Active, "les deux noms partagent les places");
        Check.Equal(1, budget.Snapshot("PC-A", controller: true).Active, "contrôleur séparé");
        budget.ObserveAddress("PC-B", IPAddress.Parse("198.51.100.20"));
        Check.Equal(other.GroupName, budget.Snapshot("PC-B").Group, "dernière adresse réellement vue retenue");
        Check.Equal(a.GroupName, b.GroupName, "le bail physique existant conserve son groupe original");
    }

    [Test]
    public static void Adaptive_unknown_addresses_never_suspend_and_non_unicast_addresses_are_not_site_evidence()
    {
        var clock = new Clock(); var budget = new AdaptiveReadBudget(clock);
        foreach (var address in new[] { "127.0.0.1", "0.0.0.0", "224.0.0.1", "::1", "2001:db8::1" }) budget.ObserveAddress("PC-A", IPAddress.Parse(address));
        using var lease = budget.Acquire("PC-A");
        for (var i = 0; i < 10; i++) { clock.Advance(TimeSpan.FromSeconds(11)); lease.Report(AdaptiveReadOutcome.Failure, Fast); }
        var snapshot = budget.Snapshot("PC-B");
        Check.Equal("site:?", snapshot.Group, "inconnu commun, aucune résolution DNS");
        Check.Equal(0, snapshot.RememberedHosts, "les adresses non qualifiées ne créent aucune preuve");
        Check.Equal("closed", snapshot.State, "inconnu jamais suspendu"); Check.Equal(1, snapshot.Limit, "ralentissement seulement");
        lease.Dispose(); using var next = budget.Acquire("PC-B"); next.RequireContinuation();
        using var unknownDc = budget.Acquire(null, controller: true);
        for (var i = 0; i < 3; i++) unknownDc.Report(false, Fast);
        Check.Equal("closed", budget.Snapshot(null, controller: true).State, "contrôleur inconnu jamais suspendu");
    }

    [Test]
    public static void Adaptive_three_failures_suspend_and_late_answers_neither_reopen_nor_extend_the_pause()
    {
        var clock = new Clock(); var budget = Known(clock);
        using var failing = budget.Acquire("PC-A"); using var late = budget.Acquire("PC-B");
        failing.Report(false, Fast); Check.Equal(2, budget.Snapshot("PC-A").Limit, "baisse de moitié immédiate");
        failing.Report(false, Fast); Check.Equal("closed", budget.Snapshot("PC-A").State, "deux échecs ne suspendent pas");
        failing.Report(AdaptiveReadOutcome.Timeout, Fast);
        Check.Equal(TimeSpan.FromSeconds(60), budget.Snapshot("PC-A").SuspendedFor, "première suspension");
        clock.Advance(TimeSpan.FromSeconds(15)); clock.RewindUtc(TimeSpan.FromDays(2));
        late.Report(true, Fast); late.Report(false, Fast);
        Check.Equal(TimeSpan.FromSeconds(45), budget.Snapshot("PC-A").SuspendedFor, "réponses tardives sans extension ; horloge monotone");
        Check.Equal(2, budget.Snapshot("PC-A").Active, "le résultat n’a pas libéré la place physique");
        Check.Throws<DomeniaOperationException>(() => failing.RequireContinuation(), "nouvel appel refusé dans un enfant conservé");
        Check.Throws<DomeniaOperationException>(() => budget.Acquire("PC-B"), "nouvelle lecture refusée pendant suspension");
    }

    [Test]
    public static void Adaptive_one_recovery_trial_doubles_bounded_pause_then_grows_one_step_at_a_time()
    {
        var clock = new Clock(); var budget = Known(clock);
        using (var failed = budget.Acquire("PC-A")) for (var i = 0; i < 3; i++) failed.Report(false, Fast);
        foreach (var expected in new[] { 120, 240, 480, 900, 900 })
        {
            clock.Advance(budget.Snapshot("PC-A").SuspendedFor);
            using var trial = budget.Acquire("PC-A");
            Check.Equal("halfOpen", budget.Snapshot("PC-A").State, "un essai explicite après attente");
            Check.Throws<DomeniaOperationException>(() => budget.Acquire("PC-B"), "aucun second essai de reprise");
            trial.Report(false, Fast);
            Check.Equal(TimeSpan.FromSeconds(expected), budget.Snapshot("PC-A").SuspendedFor, "doublement borné");
        }
        clock.Advance(budget.Snapshot("PC-A").SuspendedFor);
        using var recovered = budget.Acquire("PC-A"); recovered.Report(true, Fast);
        Check.Equal("closed", budget.Snapshot("PC-A").State, "succès de l’essai"); Check.Equal(1, budget.Snapshot("PC-A").Limit, "reprise à une place");
        recovered.Report(true, Fast); Check.Equal(2, budget.Snapshot("PC-A").Limit, "une réponse suivante donne une place");
        recovered.Report(true, Fast); Check.Equal(2, budget.Snapshot("PC-A").Limit, "pas de croissance prématurée");
        recovered.Report(true, Fast); Check.Equal(3, budget.Snapshot("PC-A").Limit, "hausse additive");
        for (var i = 0; i < 20; i++) recovered.Report(true, Fast);
        Check.Equal(4, budget.Snapshot("PC-A").Limit, "plafond choisi respecté");
    }

    [Test]
    public static void Adaptive_slow_answers_halve_with_cooldown_without_suspension_and_neutral_results_do_not_heal()
    {
        var clock = new Clock(); var budget = Known(clock);
        using var lease = budget.Acquire("PC-A");
        for (var i = 0; i < 3; i++) lease.Report(true, Fast);
        lease.Report(true, TimeSpan.FromMilliseconds(900)); Check.Equal(2, budget.Snapshot("PC-A").Limit, "lenteur par rapport à trois mesures");
        lease.Report(true, TimeSpan.FromMilliseconds(900)); Check.Equal(2, budget.Snapshot("PC-A").Limit, "cooldown évite des divisions en rafale");
        clock.Advance(TimeSpan.FromSeconds(10)); lease.Report(true, TimeSpan.FromMilliseconds(900));
        Check.Equal(1, budget.Snapshot("PC-A").Limit, "nouvelle baisse après cooldown"); Check.Equal("closed", budget.Snapshot("PC-A").State, "une réponse lente ne suspend pas");
        lease.Report(false, Fast); var before = budget.Snapshot("PC-A");
        lease.Report(AdaptiveReadOutcome.Neutral, Fast); lease.Report(AdaptiveReadOutcome.Cancelled, Fast);
        Check.Equal(before, budget.Snapshot("PC-A"), "refus et annulation ne guérissent ni ne pénalisent");
        lease.Dispose(); lease.Report(true, Fast); Check.Equal(1, budget.Snapshot("PC-A").Limit, "callback après libération ignoré");
    }

    [Test]
    public static async Task Adaptive_waiting_is_cancellable_counts_no_place_and_wakes_only_for_admission()
    {
        var budget = new AdaptiveReadBudget(TimeProvider.System, 1); using var held = budget.Acquire("PC-A");
        using var stop = new CancellationTokenSource();
        var cancelled = budget.AcquireAsync("PC-B", TimeSpan.FromSeconds(20), stop.Token).AsTask();
        Check.False(cancelled.IsCompleted, "attente de place sans envoi"); Check.Equal(1, budget.Snapshot("PC-A").Active, "attente non comptée comme travail physique");
        stop.Cancel(); await Check.ThrowsAsync<OperationCanceledException>(() => cancelled, "annulation de l’attente");
        var waiting = budget.AcquireAsync("PC-B", TimeSpan.FromSeconds(20), default).AsTask(); held.Dispose();
        using var admitted = await waiting;
        Check.Equal(1, budget.Snapshot("PC-B").Active, "une seule place restituée puis acquise"); Check.Equal(0, budget.Snapshot("PC-B").Failures, "aucune mesure inventée en attente");
    }

    [Test]
    public static async Task Adaptive_paused_source_refuses_without_wait_and_cancelled_half_open_trial_changes_no_health()
    {
        var clock = new Clock(); var budget = Known(clock);
        using (var failed = budget.Acquire("PC-A")) for (var i = 0; i < 3; i++) failed.Report(false, Fast);
        var refused = budget.AcquireAsync("PC-B", TimeSpan.FromSeconds(30), default).AsTask();
        Check.True(refused.IsCompleted, "pas d’attente ni de minuterie de redémarrage en suspension");
        await Check.ThrowsAsync<DomeniaOperationException>(() => refused, "suspension signalée");
        clock.Advance(TimeSpan.FromSeconds(60));
        using (var cancelled = budget.Acquire("PC-A")) cancelled.Report(AdaptiveReadOutcome.Cancelled, Fast);
        Check.Equal("halfOpen", budget.Snapshot("PC-A").State, "annulation ne vaut pas reprise réussie");
        using var next = budget.Acquire("PC-B"); next.Report(true, Fast);
        Check.Equal(1, budget.Snapshot("PC-A").Limit, "nouvel essai explicitement acquis");
    }

    [Test]
    public static void Adaptive_classifies_actual_partial_answers_and_keeps_rights_accounts_and_offline_neutral()
    {
        foreach (var status in new[] { SourceStatus.Ok, SourceStatus.Empty, SourceStatus.Partial }) Check.Equal(AdaptiveReadOutcome.Success, AdaptiveReadBudget.Classify(status), "réponse effective");
        foreach (var status in new[] { SourceStatus.Skipped, SourceStatus.Refused, SourceStatus.Unreachable, SourceStatus.Unavailable }) Check.Equal(AdaptiveReadOutcome.Neutral, AdaptiveReadBudget.Classify(status), "ne juge pas le site");
        Check.Equal(AdaptiveReadOutcome.Timeout, AdaptiveReadBudget.Classify(SourceStatus.Interrupted), "budget natif expiré");
        Check.Equal(AdaptiveReadOutcome.Failure, AdaptiveReadBudget.Classify(SourceStatus.Error), "fournisseur en erreur");
        foreach (var category in new[] { "Disabled", "CredentialsRejected", "CredentialMissing", "AccountState", "AccessDenied", "Target", "Network" })
            Check.Equal(AdaptiveReadOutcome.Neutral, NativeReadClient.TrialOutcome(new("Failed", null, category, null)), "échec d’essai sans pénalité de site");
        Check.Equal(AdaptiveReadOutcome.Success, NativeReadClient.TrialOutcome(new("Observed", null, null, "Windows")), "essai observé");
        foreach (var code in new[] { 49, 50, 19, 21, 32, 53, 68 }) Check.Equal(AdaptiveReadOutcome.Neutral, AdConnection.AdaptiveOutcome(new LdapException(code)), "refus LDAP ou cible sans résultat");
        Check.Equal(AdaptiveReadOutcome.Timeout, AdConnection.AdaptiveOutcome(new LdapException(85)), "délai LDAP");
        Check.Equal(AdaptiveReadOutcome.Failure, AdConnection.AdaptiveOutcome(new LdapException(81)), "contrôleur indisponible");
    }

    [Test]
    public static void Adaptive_address_memory_is_bounded_and_an_eviction_does_not_move_an_existing_lease()
    {
        var clock = new Clock(); var budget = Known(clock); using var existing = budget.Acquire("PC-A");
        for (var i = 0; i < AdaptiveReadBudget.MaximumHosts; i++) budget.ObserveAddress("PC-" + i, IPAddress.Parse("198.51.100.1"));
        Check.Equal(AdaptiveReadBudget.MaximumHosts, budget.Snapshot("PC-B").RememberedHosts, "vingt mille noms au plus");
        Check.Equal("site:?", budget.Snapshot("PC-A").Group, "ancienne observation évincée");
        Check.Equal("site:192.0.2.0/24", existing.GroupName, "place active encore liée à son observation d’admission");
        Check.Equal(1, budget.Snapshot("192.0.2.10").Active, "éviction de nom sans libération anticipée");
    }

    private sealed class Clock : TimeProvider
    {
        private readonly object gate = new();
        private readonly List<Timer> timers = [];
        private long ticks; private DateTimeOffset utc = DateTimeOffset.Parse("2026-10-25T10:00:00Z", global::System.Globalization.CultureInfo.InvariantCulture);
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() { lock (gate) return ticks; }
        public override DateTimeOffset GetUtcNow() { lock (gate) return utc; }
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new Timer(this, callback, state);
            lock (gate) { timers.Add(timer); timer.Change(dueTime, period); }
            return timer;
        }
        internal void Advance(TimeSpan elapsed)
        {
            Timer[] copy; lock (gate) { ticks += elapsed.Ticks; utc += elapsed; copy = [.. timers]; }
            foreach (var timer in copy) timer.Fire();
        }
        internal void RewindUtc(TimeSpan elapsed) { lock (gate) utc -= elapsed; }
        private sealed class Timer(Clock owner, TimerCallback callback, object? state) : ITimer
        {
            private long due = long.MaxValue;
            private bool disposed;
            public bool Change(TimeSpan delay, TimeSpan period)
            {
                lock (owner.gate)
                { if (disposed) return false; due = delay == Timeout.InfiniteTimeSpan ? long.MaxValue : owner.ticks + delay.Ticks; return true; }
            }
            internal void Fire()
            {
                lock (owner.gate) { if (disposed || due > owner.ticks) return; due = long.MaxValue; }
                callback(state);
            }
            public void Dispose() { lock (owner.gate) { disposed = true; due = long.MaxValue; } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }

    [Test]
    public static async Task Adaptive_campaign_waits_during_network_pause_then_allows_only_one_trial_and_keeps_cancellation()
    {
        var clock = new Clock(); var budget = Known(clock);
        using (var failed = budget.Acquire("PC-A")) for (var i = 0; i < 3; i++) failed.Report(false, Fast);
        using var stop = new CancellationTokenSource();
        var cancelled = budget.AcquireAsync("PC-A", stop.Token).AsTask();
        var first = budget.AcquireAsync("PC-A", CancellationToken.None).AsTask();
        var second = budget.AcquireAsync("PC-B", CancellationToken.None).AsTask();
        Check.False(first.IsCompleted || second.IsCompleted, "suspension sans échec de tous les postes restants");
        Check.Equal(0, budget.Snapshot("PC-A").Active, "attente sans ressource native");
        stop.Cancel(); await Check.ThrowsAsync<OperationCanceledException>(() => cancelled, "arrêt immédiat pendant la pause");
        clock.Advance(TimeSpan.FromSeconds(59));
        Check.False(first.IsCompleted || second.IsCompleted, "aucune reprise prématurée");
        clock.Advance(TimeSpan.FromSeconds(1));
        var winner = await Task.WhenAny(first, second).WaitAsync(TimeSpan.FromSeconds(5));
        using var trial = await winner;
        var waiting = ReferenceEquals(winner, first) ? second : first;
        Check.Equal("halfOpen", budget.Snapshot("PC-A").State, "un essai à la fin du délai");
        Check.False(waiting.IsCompleted, "aucune rafale de reprise");
        trial.Report(true, Fast); trial.Dispose();
        using var admitted = await waiting.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal("closed", budget.Snapshot("PC-A").State, "succès réellement observé");
        Check.Equal(1, budget.Snapshot("PC-A").Active, "un seul travail suivant");
    }

    [Test]
    public static void Adaptive_address_index_handles_100000_hosts_with_bounded_lru_memory_and_recency()
    {
        var budget = new AdaptiveReadBudget(new Clock());
        var address = IPAddress.Parse("198.51.100.10");
        budget.ObserveAddress("KEEP", address);
        for (var i = 0; i < 100_000; i++)
        {
            budget.ObserveAddress("PC-" + i, address);
            if (i % 1000 == 0) _ = budget.Snapshot("KEEP");
        }
        Check.Equal(AdaptiveReadBudget.MaximumHosts, budget.Snapshot("KEEP").RememberedHosts, "mémoire bornée indépendamment de la taille du parc");
        Check.Equal("site:198.51.100.0/24", budget.Snapshot("KEEP").Group, "une adresse encore utilisée n’est pas évincée");
        Check.Equal("site:?", budget.Snapshot("PC-0").Group, "la plus ancienne adresse est évincée");
        Check.Equal("site:198.51.100.0/24", budget.Snapshot("PC-99999").Group, "la dernière adresse est disponible");
    }
}
