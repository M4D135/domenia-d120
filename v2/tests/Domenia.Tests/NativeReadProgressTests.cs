using System.Runtime.InteropServices;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class NativeReadProgressTests
{
    private const string Query = "SELECT Name FROM Win32_ComputerSystem";
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));

    [Test]
    public static void Native_idle_is_twenty_for_probes_twenty_five_for_inventory_and_capped_by_total()
    {
        foreach (var (inventory, total, idle) in new[] { (false, 60, 20), (true, 150, 25), (true, 15, 15) })
        {
            var clock = new Clock();
            using var progress = new NativeReadProgress(clock, TimeSpan.FromSeconds(total), inventory, CancellationToken.None);
            clock.Advance(TimeSpan.FromSeconds(idle - 1));
            Check.False(progress.Token.IsCancellationRequested, "avant la borne annoncée");
            clock.Advance(TimeSpan.FromSeconds(1));
            Check.True(progress.Token.IsCancellationRequested, "timer sans nouvelle source, sans appel Snapshot pour provoquer l’arrêt");
            Check.Equal(0L, progress.Snapshot().Received, "aucun heartbeat crédité");
        }
    }

    [Test]
    public static void Completed_work_never_extends_existing_campaign_total_budgets()
    {
        foreach (var seconds in new[] { 15, 30, 55, 60, 150 })
        {
            var clock = new Clock();
            using var progress = new NativeReadProgress(clock, TimeSpan.FromSeconds(seconds), seconds != 60, CancellationToken.None);
            for (var elapsed = 5; elapsed < seconds; elapsed += 5)
            { clock.Advance(TimeSpan.FromSeconds(5)); progress.Completed(); Check.False(progress.Token.IsCancellationRequested, "progression avant total"); }
            var count = progress.Snapshot().Received;
            clock.Advance(TimeSpan.FromSeconds(5)); progress.Completed();
            Check.True(progress.Token.IsCancellationRequested, "total inchangé : " + seconds);
            Check.Equal("Plafond total atteint", progress.Snapshot().StopReason, "borne totale indépendante de l’inactivité");
            Check.Equal(count, progress.Snapshot().Received, "fin tardive non créditée");
        }
    }

    [Test]
    public static void Only_completed_CIM_answers_refresh_inactivity_and_no_rows_are_required()
    {
        var clock = new Clock();
        using var progress = new NativeReadProgress(clock, CimBudgets.FullInventory, true, CancellationToken.None);
        var calls = 0;
        using var session = new CimSession("PC1", CimBudgets.FullInventory, clock, cancellationToken: progress.Token)
        { ReadOverride = (_, _, _) => ++calls == 1 ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))] : [], QueryCompleted = progress.Completed };
        clock.Advance(TimeSpan.FromSeconds(17));
        Check.Equal(SourceStatus.Ok, session.Read("identity", @"root\cimv2", Query, 1).Status, "setup source positive");
        clock.Advance(TimeSpan.FromSeconds(17));
        Check.Equal(SourceStatus.Empty, session.Read("empty", @"root\cimv2", Query, 1).Status, "absence réellement lue");
        Check.Equal(2L, progress.Snapshot().Received, "deux opérations achevées, pas deux notifications UI");
        clock.Advance(TimeSpan.FromSeconds(24));
        Check.False(progress.Token.IsCancellationRequested, "dernière réponse vide renouvelle l’inactivité");
        clock.Advance(TimeSpan.FromSeconds(1));
        Check.True(progress.Token.IsCancellationRequested, "25 secondes après la dernière source achevée");
    }

    [Test]
    public static void Guarded_disabled_refused_and_partial_timeout_reads_do_not_credit_progress()
    {
        var clock = new Clock();
        using var progress = new NativeReadProgress(clock, CimBudgets.FullInventory, true, CancellationToken.None);
        var calls = 0;
        using var refused = new CimSession("PC1", CimBudgets.FullInventory, clock, cancellationToken: progress.Token)
        { ReadOverride = (_, _, _) => { calls++; throw new COMException("refused", unchecked((int)0x8007052E)); }, QueryCompleted = progress.Completed };
        Check.Equal(SourceStatus.Error, refused.Read("guard", @"root\cimv2", "DELETE FROM Win32_ComputerSystem", 1).Status, "garde avant contact");
        Check.Equal(0, calls, "la garde ne touche pas le fournisseur");
        Check.Equal(SourceStatus.Refused, refused.Read("refusal", @"root\cimv2", Query, 1).Status, "refus réel");
        Check.Equal(SourceStatus.Refused, refused.Read("cached-refusal", @"root\cimv2", Query, 1).Status, "refus mémorisé");
        Check.Equal(1, calls, "pas de nouvelle tentative après refus");
        using var disabled = new CimSession("PC1", CimBudgets.FullInventory, clock, cancellationToken: progress.Token)
        { ReadsEnabled = false, ReadOverride = (_, _, _) => throw new InvalidOperationException("must not contact"), QueryCompleted = progress.Completed };
        Check.Equal(SourceStatus.Skipped, disabled.Read("disabled", @"root\cimv2", Query, 1).Status, "source désactivée");
        IEnumerable<WmiInstance> Partial() { yield return Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local")); throw new TimeoutException(); }
        using var partial = new CimSession("PC1", CimBudgets.FullInventory, clock, cancellationToken: progress.Token)
        { ReadOverride = (_, _, _) => Partial(), QueryCompleted = progress.Completed };
        var answer = partial.Read("partial", @"root\cimv2", Query, 2);
        Check.Equal(SourceStatus.Partial, answer.Status, "donnée partielle conservée sans réussite totale");
        Check.Equal("PC1", answer.Instances.Single().Text("Name"), "source observée conservée");
        Check.Equal(0L, progress.Snapshot().Received, "aucun chemin de refus/cache/timeout ne renouvelle la lecture");
        clock.Advance(TimeSpan.FromSeconds(25));
        Check.True(progress.Token.IsCancellationRequested, "inactivité effective");
    }

    [Test]
    public static void Cancellation_and_disposal_close_the_completion_channel_permanently()
    {
        var clock = new Clock(); using var stop = new CancellationTokenSource();
        using var progress = new NativeReadProgress(clock, CimBudgets.FullInventory, true, stop.Token);
        progress.Completed(); Check.Equal(1L, progress.Snapshot().Received, "setup du canal actif");
        stop.Cancel(); clock.Advance(TimeSpan.FromSeconds(1)); progress.Completed();
        Check.True(progress.Token.IsCancellationRequested, "annulation externe terminale");
        Check.Equal(1L, progress.Snapshot().Received, "aucune fin reçue après l’annulation ne compte");
        progress.Dispose(); progress.Completed();
        Check.True(progress.Token.IsCancellationRequested, "callback tardif après nettoyage sans réouverture");
    }

    [Test]
    public static async Task Inventory_facts_real_source_completions_keep_an_active_read_past_twenty_five_seconds()
    {
        var clock = new Clock(); var calls = 0;
        var reader = new WmiWorkstationProbe(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            {
                ReadOverride = (_, query, _) =>
                {
                    calls++; clock.Advance(TimeSpan.FromSeconds(8));
                    return query.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"), ("SystemDrive", "C:"))]
                        : query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Model", "Model"))]
                        : query.Contains("Win32_LogicalDisk", StringComparison.Ordinal) ? [Row(("Size", 100L), ("FreeSpace", 30L))]
                        : [Row(("SMBIOSBIOSVersion", "version"))];
                },
            },
        };
        var result = await reader.ReadFactsAsync("PC1", CimBudgets.FullInventory, CancellationToken.None);
        Check.Equal(4, calls, "quatre sources réelles, dont deux au-delà de 25 secondes initiales");
        Check.Equal(TimeSpan.FromSeconds(32), clock.Elapsed, "pas de sommeil réel");
        Check.Equal(MeasureState.Known, result.Inventory.State, "inventaire entièrement reçu");
        Check.Equal("PC1", result.ReportedName, "identité issue de la source");
    }

    [Test]
    public static async Task Inventory_idle_cancellation_retains_completed_sources_and_waits_for_the_blocked_worker()
    {
        var clock = new Clock(); var calls = 0; CancellationToken native = default;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim();
        var reader = new WmiWorkstationProbe(clock)
        {
            SessionFactory = (host, budget, token) =>
            {
                native = token;
                return new(host, budget, clock, cancellationToken: token)
                {
                    ReadOverride = (_, query, _) =>
                    {
                        calls++;
                        if (query.Contains("Win32_OperatingSystem", StringComparison.Ordinal)) { return [Row(("Caption", "Windows"), ("SystemDrive", "C:"))]; }
                        if (query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)) { return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Model", "Model"))]; }
                        entered.TrySetResult(); Check.True(release.Wait(Guard), "barrière du fournisseur libérée"); return [];
                    },
                };
            },
        };
        var work = reader.ReadFactsAsync("PC1", CimBudgets.FullInventory, CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(Guard); clock.Advance(TimeSpan.FromSeconds(25));
            Check.True(native.IsCancellationRequested, "annulation transmise à la source bloquée");
            Check.False(work.IsCompleted, "expiration ne fabrique pas une fin physique");
        }
        finally { release.Set(); await work.WaitAsync(Guard); }
        var result = await work.WaitAsync(Guard);
        Check.Equal(3, calls, "aucune source BIOS démarrée après arrêt");
        Check.Equal("PC1", result.ReportedName, "identité terminée conservée");
        Check.Equal("Windows", result.Inventory.OsCaption, "système terminé conservé");
        Check.Equal(MeasureState.Incomplete, result.Inventory.State, "aucune complétude inventée");
    }

    [Test]
    public static async Task Fleet_idle_keeps_known_results_and_explicitly_marks_every_pending_probe_unread()
    {
        var clock = new Clock(); var calls = 0;
        var reader = new WmiFleetProbeReader(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            {
                ReadOverride = (_, _, _) =>
                {
                    calls++;
                    if (calls == 1) { return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))]; }
                    if (calls == 2) { return [Row(("Model", "Model"))]; }
                    clock.Advance(TimeSpan.FromSeconds(20)); return [];
                },
            },
        };
        var result = await reader.ReadAsync(Fixtures.Computer("PC1"), ["hw.model", "hw.cpuload", "disk.cfree"], CancellationToken.None);
        Check.Equal(3, calls, "identité, première sonde, puis sonde interrompue seulement");
        Check.Equal(3, result.Count, "aucune sonde demandée ne disparaît");
        Check.Equal(MeasureState.Known, result["hw.model"].State, "vraie lecture initiale");
        Check.Equal("Model", result["hw.model"].Values.Single(), "mesure achevée conservée");
        Check.Equal(MeasureState.NotRead, result["hw.cpuload"].State, "sonde en cours interrompue, pas une absence");
        Check.Equal(MeasureState.NotRead, result["disk.cfree"].State, "sonde jamais lancée explicitement inconnue");
    }

    [Test]
    public static async Task Complete_survey_credits_sources_but_still_stops_at_its_thirty_second_total()
    {
        var clock = new Clock(); var calls = 0; var finished = false;
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            {
                RegistryOverride = (_, _) => new(2, null),
                ReadOverride = (_, query, _) =>
                {
                    calls++; clock.Advance(TimeSpan.FromSeconds(6));
                    return query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))]
                        : query.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"))] : [];
                },
            },
        };
        var result = await reader.ReadSharedAsync("PC1", WorkstationReading.SurveyComplete,
            new SynchronousProgress(value => finished |= value.Label == "Lecture terminée"), CancellationToken.None);
        Check.Equal(5, calls, "projections achevées puis projection interrompue à 30 secondes ; aucun BIOS");
        Check.Equal(TimeSpan.FromSeconds(30), clock.Elapsed, "budget total réel de SurveyComplete");
        Check.Equal("PC1", result.ReportedName, "identité achevée conservée");
        Check.Equal("Windows", result.Os?.Caption, "système achevé conservé");
        Check.Equal(SourceStatus.Interrupted, result.Access.Single(a => a.Category == InventoryCategories.Bios).Status, "BIOS jamais lancé explicitement interrompu");
        Check.False(finished, "aucune notification de réussite complète après expiration");
    }

    [Test]
    public static async Task UI_step_notifications_do_not_credit_or_start_a_probe_after_idle_expiry()
    {
        var clock = new Clock(); var calls = 0; var notifications = 0;
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { ReadOverride = (_, _, _) => { calls++; return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))]; } },
        };
        var result = await reader.ReadProbesAsync("PC1", ["disk.volumes", "hw.memoryusage"],
            new SynchronousProgress(_ => { notifications++; clock.Advance(TimeSpan.FromSeconds(20)); }), CancellationToken.None);
        Check.Equal(1, notifications, "notification d’étape avant son contact");
        Check.Equal(1, calls, "identité positive seulement ; aucun contact après expiration");
        Check.Equal("PC1", result.ReportedName, "identité confirmée au départ");
        Check.Equal(0, result.Values.Count, "aucune valeur de sonde inventée");
        Check.True(result.Access.Length == 2 && result.Access.All(a => a.Status == SourceStatus.Interrupted), "deux sondes explicitement interrompues");
    }

    [Test]
    public static async Task Shared_inventory_deadline_belongs_to_the_worker_and_survives_one_subscriber_leaving()
    {
        var clock = new Clock(); var calls = 0; CancellationToken native = default;
        using var stop = new CancellationTokenSource(); using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) =>
            {
                native = token;
                return new(host, budget, clock, cancellationToken: token)
                { ReadOverride = (_, _, _) => { if (Interlocked.Increment(ref calls) == 1) { entered.TrySetResult(); Check.True(release.Wait(Guard), "fournisseur libéré"); } return []; } };
            },
        };
        var key = new InventoryReadKey(Guid.NewGuid(), "CN=PC1,DC=test,DC=local", TestClock.Reference, "PC1", WorkstationReading.SurveyComplete, "session", true, false, false);
        var shared = new SharedInventoryReads();
        Task<InventorySnapshot> Read(IProgress<PosteProgress> progress, CancellationToken token) => reader.ReadSharedAsync("PC1", WorkstationReading.SurveyComplete, progress, token);
        var first = shared.ReadAsync(key, Read, null, stop.Token);
        var second = shared.ReadAsync(key, Read, null, CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(Guard); stop.Cancel();
            await Check.ThrowsAsync<OperationCanceledException>(() => first, "un seul abonné quitte la lecture");
            Check.False(native.IsCancellationRequested, "le worker reste demandé par le second");
            clock.Advance(TimeSpan.FromSeconds(25));
            Check.True(native.IsCancellationRequested, "le vrai worker conserve son échéance après le départ du premier");
            Check.False(second.IsCompleted, "le groupe attend encore la fin physique");
        }
        finally { release.Set(); await second.WaitAsync(Guard); }
        var result = await second.WaitAsync(Guard);
        Check.True(result.Shared, "un seul worker partagé");
        Check.Equal(1, calls, "aucune projection lancée après expiration");
        Check.True(result.Value.Access.Any(a => a.Status == SourceStatus.Interrupted), "résultat incomplet déclaré");
    }

    [Test]
    public static async Task Idle_expiry_never_releases_a_worker_slot_while_source_work_is_blocked()
    {
        var clock = new Clock(); using var entered = new CountdownEvent(6); using var release = new ManualResetEventSlim();
        var work = new List<Task<int>>(); var tokens = new CancellationToken[6];
        try
        {
            for (var index = 0; index < 6; index++)
            {
                var slot = index;
                work.Add(WmiReadWorkers.Start<int>(null, _ =>
                {
                    using var progress = new NativeReadProgress(clock, CimBudgets.Probes, false, CancellationToken.None);
                    tokens[slot] = progress.Token; entered.Signal(); Check.True(release.Wait(Guard), "fin physique libérée"); return slot;
                }, CancellationToken.None));
            }
            Check.True(entered.Wait(Guard), "six workers effectivement entrés");
            clock.Advance(TimeSpan.FromSeconds(20));
            Check.True(tokens.All(t => t.IsCancellationRequested), "six délais expirés");
            Check.True(work.All(t => !t.IsCompleted), "six propriétaires encore vivants");
            var refused = Check.Throws<DomeniaOperationException>(() => WmiReadWorkers.Start<int>(null, _ => 7, CancellationToken.None), "aucun septième worker pendant la fin physique");
            Check.Equal("machine.busy", refused.Code, "refus de capacité précis");
        }
        finally { release.Set(); await Task.WhenAll(work).WaitAsync(Guard); }
        Check.Equal(7, await WmiReadWorkers.Start<int>(null, _ => 7, CancellationToken.None), "quota restitué après sortie physique");
    }

    private sealed class SynchronousProgress(Action<PosteProgress> report) : IProgress<PosteProgress>
    { public void Report(PosteProgress value) => report(value); }

    private sealed class Clock : TimeProvider
    {
        private readonly object gate = new();
        private readonly List<Timer> timers = [];
        private long ticks;
        internal TimeSpan Elapsed { get { lock (gate) { return TimeSpan.FromTicks(ticks); } } }
        public override DateTimeOffset GetUtcNow() => TestClock.Reference + Elapsed;
        public override long GetTimestamp() { lock (gate) { return ticks; } }
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new Timer(this, callback, state);
            lock (gate) { timers.Add(timer); timer.Change(dueTime, period); } return timer;
        }
        internal void Advance(TimeSpan by)
        {
            Timer[] copy; lock (gate) { ticks += by.Ticks; copy = [.. timers]; }
            foreach (var timer in copy) { timer.Fire(); }
        }
        private sealed class Timer(Clock owner, TimerCallback callback, object? state) : ITimer
        {
            private long due = long.MaxValue;
            private TimeSpan period;
            private bool disposed;
            public bool Change(TimeSpan dueTime, TimeSpan repeat)
            {
                lock (owner.gate)
                {
                    if (disposed) { return false; }
                    due = dueTime == Timeout.InfiniteTimeSpan ? long.MaxValue : owner.ticks + dueTime.Ticks; period = repeat; return true;
                }
            }
            internal void Fire()
            {
                lock (owner.gate)
                {
                    if (disposed || due > owner.ticks) { return; }
                    due = period > TimeSpan.Zero ? owner.ticks + period.Ticks : long.MaxValue;
                }
                callback(state);
            }
            public void Dispose() { lock (owner.gate) { disposed = true; due = long.MaxValue; } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
