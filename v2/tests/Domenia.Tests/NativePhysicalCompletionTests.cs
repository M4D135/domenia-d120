using System.Collections.Immutable;
using System.Security;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

/// <summary>Logical stop must not release a campaign while a synchronous native provider is still running.</summary>
internal static class NativePhysicalCompletionTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);
    private static readonly ScopeSelection Scope = new(Fixtures.Postes, "Postes", true);
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));

    [Test]
    public static async Task Inventory_outer_deadline_waits_for_native_disposal_and_retains_values_after_a_late_fault()
    {
        var clock = new Clock(); var calls = 0; CancellationToken native = default;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim();
        var reader = Inventory(clock, entered, release, () => calls++, token => native = token, lateFault: true);
        var work = reader.ReadFactsAsync("PC1", TimeSpan.FromSeconds(1), CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(Guard);
            clock.Advance(TimeSpan.FromSeconds(4));
            Check.True(native.IsCancellationRequested, "deadline transmise au fournisseur bloqué");
            await StillOwned(work);
        }
        finally { release.Set(); }
        var result = await work.WaitAsync(Guard);
        Check.True(result.ReadPhysicallyCompleted, "la faute tardive est observée avant restitution du bail");
        Check.Equal(3, calls, "aucun BIOS après arrêt du disque");
        Check.Equal("PC1", result.ReportedName, "identité déjà reçue conservée");
        Check.Equal("Windows", result.Inventory.OsCaption, "mesure terminée conservée malgré la faute tardive");
        Check.Equal(MeasureState.Incomplete, result.Inventory.State, "pas de réussite inventée");
        Check.Equal(CollectionReadFailure.Unknown, result.RetryFailure, "deadline enveloppe non convertie en incident transitoire");
    }

    [Test]
    public static async Task Fleet_cancellation_propagates_only_after_the_native_worker_terminates()
    {
        var clock = new Clock(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim(); using var stop = new CancellationTokenSource();
        var reader = Probes(clock, entered, release);
        var work = reader.ReadAsync(Fixtures.Computer("PC1"), ["hw.model", "hw.cpuload", "disk.cfree"], stop.Token);
        try
        {
            await entered.Task.WaitAsync(Guard); await stop.CancelAsync(); await StillOwned(work);
        }
        finally { release.Set(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => work.WaitAsync(Guard), "arrêt propagé après la fin réelle");
    }

    [Test]
    public static async Task Console_outer_deadline_waits_and_cannot_qualify_an_account_or_retry()
    {
        var clock = new Clock(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim();
        var reader = Console(clock, entered, release);
        var work = reader.ReadConsoleAccountAsync("PC1", CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(Guard); clock.Advance(CimBudgets.ConsoleSession + TimeSpan.FromSeconds(1)); await StillOwned(work);
        }
        finally { release.Set(); }
        var result = await work.WaitAsync(Guard);
        Check.NotNull(result, "état d’arrêt explicite");
        Check.True(result!.ReadPhysicallyCompleted, "worker fermé avant retour");
        Check.Equal(SourceStatus.Interrupted, result.Status, "réponse tardive non qualifiée");
        Check.Null(result.ConsoleUser, "aucun compte associé après expiration");
        Check.Null(result.ObservedAt, "aucune date de console qualifiée");
        Check.Equal(CollectionReadFailure.Unknown, result.RetryFailure, "pas de reprise provoquée par un délai logique");
    }

    [Test]
    public static async Task Console_user_cancellation_waits_before_throwing_and_observes_a_late_worker_fault()
    {
        var clock = new Clock(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim(); using var stop = new CancellationTokenSource();
        var reader = Console(clock, entered, release, lateFault: true);
        var work = reader.ReadConsoleAccountAsync("PC1", stop.Token);
        try
        {
            await entered.Task.WaitAsync(Guard); await stop.CancelAsync(); await StillOwned(work);
        }
        finally { release.Set(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => work.WaitAsync(Guard), "arrêt distinct d’une lecture de console réussie");
    }

    [Test]
    public static async Task Home_inventory_stop_commits_received_values_after_native_termination_before_propagating()
    {
        var clock = new Clock(); var computer = Fixtures.Computer("PC1");
        var cache = await Cache(computer); var beforeWrites = cache.FleetWrites;
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        { SearchAnswer = request => request.BaseDn == computer.DistinguishedName ? [AdPosteNetworkTests.Entry(computer)] : [] };
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim(); using var stop = new CancellationTokenSource();
        var probe = Inventory(clock, entered, release);
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, probe, new AdBoundaryTests.RecordingAdConnection(), cache)
        { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        source.AdoptConnection(ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
            Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), source.Epoch, false);
        using var context = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal());
        using var password = new SecureString();
        foreach (var character in "fixture-only") { password.AppendChar(character); }
        // The recording LDAP transport cannot copy a Windows/connection secret. Exercise the real remote-account
        // admission with an in-memory fixture credential; the injected CIM provider never authenticates it.
        MachineAccountService.From(context).UseRemote(@"TEST\probe", password.Copy());
        await source.ReadLocalAsync(CancellationToken.None);
        var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(computer.ObjectGuid, QueryComputerIdentity.Of(computer));
        var work = new AdAccueilReader(source).ReadInventoryAsync(Scope, identities, source.Epoch, stop.Token);
        var ldapBeforeStop = 0;
        try
        {
            await entered.Task.WaitAsync(Guard); ldapBeforeStop = ldap.Calls;
            await stop.CancelAsync(); await StillOwned(work);
            Check.Equal(beforeWrites, cache.FleetWrites, "aucun faux reçu pendant le worker vivant");
        }
        finally { release.Set(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => work.WaitAsync(Guard), "arrêt publié après la sauvegarde locale");
        Check.Equal(ldapBeforeStop, ldap.Calls, "aucune qualification LDAP ni reprise après arrêt");
        Check.Equal(beforeWrites + 1, cache.FleetWrites, "reçu partiel durable avant exception");
        var inventory = cache.Fleet.Observations.Workstations.Single().Inventory;
        Check.Equal("Windows", inventory.OsCaption, "système reçu conservé dans le vrai consommateur");
        Check.Equal(MeasureState.Incomplete, inventory.State, "AD final non relu : résultat explicitement incomplet");
        var facts = cache.Fleet.Facts.Machines[computer.ObjectGuid];
        Check.Null(facts.ConsoleAt, "la console interrompue ne devient pas une association");
        Check.Null(facts.ConsoleUser, "aucun compte de console non qualifié persisté");
    }

    [Test]
    public static async Task Home_probe_stop_waits_and_commits_values_as_incomplete_before_cancellation()
    {
        var clock = new Clock(); var computer = Fixtures.Computer("PC1");
        var cache = await Cache(computer); var beforeWrites = cache.FleetWrites;
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim(); using var stop = new CancellationTokenSource();
        var probes = Probes(clock, entered, release);
        var reader = new AdAccueilReader(source)
        {
            ProbeOverride = (target, ids, token) => probes.ReadAsync(target, ids, token, retainPartialOnCancellation: true),
        };
        var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(computer.ObjectGuid, QueryComputerIdentity.Of(computer));
        var work = reader.CollectProbesAsync(["hw.model", "hw.cpuload", "disk.cfree"], Scope, identities, source.Epoch, stop.Token);
        try
        {
            await entered.Task.WaitAsync(Guard); await stop.CancelAsync(); await StillOwned(work);
            Check.Equal(beforeWrites, cache.FleetWrites, "pas de validation tant que le fournisseur reste vivant");
        }
        finally { release.Set(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => work.WaitAsync(Guard), "annulation propagée après reçu local");
        var model = cache.Fleet.Probes.ByProbe["hw.model"][computer.ObjectGuid];
        Check.Equal("Model", model.Values.Single(), "première sonde terminée conservée");
        Check.Equal(MeasureState.Incomplete, model.State, "pas de sondes qualifiées sans contrôle AD final");
        Check.Equal(MeasureState.NotRead, cache.Fleet.Probes.ByProbe["disk.cfree"][computer.ObjectGuid].State, "sonde non envoyée explicitement inconnue");
        Check.Equal(beforeWrites + 1, cache.FleetWrites, "une sauvegarde locale avant propagation");
        Check.Equal(0, ldap.Calls, "aucun LDAP déclenché après annulation par le consommateur");
    }

    private static async Task StillOwned(Task work)
    {
        var observed = await Task.WhenAny(work, Task.Delay(TimeSpan.FromMilliseconds(75)));
        Check.False(ReferenceEquals(work, observed), "arrêt logique sans restitution prématurée du bail physique");
    }

    private static WmiWorkstationProbe Inventory(TimeProvider clock, TaskCompletionSource entered, ManualResetEventSlim release,
        Action? called = null, Action<CancellationToken>? tokenSeen = null, bool lateFault = false) => new(clock)
    {
        SessionFactory = (host, budget, token) =>
        {
            tokenSeen?.Invoke(token);
            return new(host, budget, clock, cancellationToken: token)
            {
                ReadOverride = (_, query, _) =>
                {
                    called?.Invoke();
                    if (query.Contains("Win32_OperatingSystem", StringComparison.Ordinal)) { return [Row(("Caption", "Windows"), ("SystemDrive", "C:"))]; }
                    if (query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)) { return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Model", "Model"), ("UserName", @"TEST\alice"))]; }
                    entered.TrySetResult(); Check.True(release.Wait(Guard), "barrière native libérée");
                    if (lateFault) { throw new InvalidOperationException("native late failure"); }
                    return [];
                },
            };
        },
    };

    private static WmiFleetProbeReader Probes(TimeProvider clock, TaskCompletionSource entered, ManualResetEventSlim release)
    {
        var calls = 0;
        return new(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            {
                ReadOverride = (_, _, _) =>
                {
                    if (++calls == 1) { return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))]; }
                    if (calls == 2) { return [Row(("Model", "Model"))]; }
                    entered.TrySetResult(); Check.True(release.Wait(Guard), "barrière native libérée"); return [];
                },
            },
        };
    }

    private static WmiWorkstationReader Console(TimeProvider clock, TaskCompletionSource entered, ManualResetEventSlim release, bool lateFault = false) => new(clock)
    {
        SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        {
            ReadOverride = (_, _, _) =>
            {
                entered.TrySetResult(); Check.True(release.Wait(Guard), "barrière native libérée");
                if (lateFault) { throw new InvalidOperationException("native late failure"); }
                return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("UserName", @"TEST\alice"))];
            },
        },
    };

    private static async Task<AdPosteNetworkTests.Cache> Cache(DirectoryComputer computer)
    {
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [computer]));
        await cache.SaveFleetAsync(FleetCachePatch.Empty with
        { Observations = new(Fixtures.Now, [Fixtures.Observe(computer, Fixtures.Presence(true, TimeSpan.Zero))]) }, CancellationToken.None);
        return cache;
    }

    private sealed class Clock : TimeProvider
    {
        private readonly object gate = new();
        private readonly List<Timer> timers = [];
        private long ticks;
        public override DateTimeOffset GetUtcNow() { lock (gate) { return Fixtures.Now + TimeSpan.FromTicks(ticks); } }
        public override long GetTimestamp() { lock (gate) { return ticks; } }
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new Timer(this, callback, state);
            lock (gate) { timers.Add(timer); timer.Change(dueTime, period); }
            return timer;
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
            public bool Change(TimeSpan delay, TimeSpan repeat)
            {
                lock (owner.gate)
                {
                    if (disposed) { return false; }
                    due = delay == Timeout.InfiniteTimeSpan ? long.MaxValue : owner.ticks + delay.Ticks; period = repeat; return true;
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
