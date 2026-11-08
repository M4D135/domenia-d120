using System.Collections.Immutable;
using System.Security;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

/// <summary>Exercises the real Search/Accueil/console consumers; only the credential validator and native transports are fixtures.</summary>
internal static class CollectionOneShotAccessTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly ScopeSelection Scope = new(Fixtures.Postes, "Postes", true);
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));

    [Test]
    public static async Task Search_inventory_reaches_native_with_the_shared_one_shot_and_keeps_it_after_passive_UI_polling()
    {
        using var fixture = await Fixture.Create(); await fixture.InstallAsync(shared: true);
        var calls = 0; var session = await fixture.Source.GetSessionAsync(None);
        var reader = fixture.Search(query =>
        {
            calls++;
            Check.True(SecureCredentialCopies.Contains(fixture.Once), "copie du compte temporaire détenue pendant le fournisseur natif");
            _ = fixture.Machine.Resolve(session, fixture.Computer.DnsHostName);
            return InventoryRows(query);
        });
        var result = await reader.ProbeAsync(fixture.Computer.ObjectGuid, SurveyMode.Analyse, 1, TimeSpan.Zero, None).WaitAsync(Guard);
        Check.True(calls > 0, "la première admission ne consomme pas le compte une deuxième fois avant CIM");
        Check.False(result.Denied, "pas de refus artificiel dû au retrait du bail consommé");
        Check.Equal("One-shot model", fixture.Cache.Fleet.Observations.Workstations.Single().Inventory.Model, "donnée native qualifiée par le vrai consommateur Recherche");
        Check.Equal(MachineAccountSource.Remote, fixture.Machine.Resolve(session, fixture.Computer.DnsHostName).Source, "le bail n’est plus disponible pour un nouveau geste");
        Check.False(SecureCredentialCopies.Contains(fixture.Once), "copie libérée à la fin du geste réel");
    }

    [Test]
    public static async Task Console_retry_borrows_the_local_one_shot_without_a_second_selection()
    {
        using var fixture = await Fixture.Create(); await fixture.InstallAsync(shared: false);
        var calls = 0;
        var reader = fixture.Search(_ =>
        {
            Check.True(SecureCredentialCopies.Contains(fixture.Once), "même secret temporaire encore détenu");
            if (++calls == 1) { throw new TimeoutException(); }
            return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("UserName", null))];
        });
        var work = reader.ProbeAsync(fixture.Computer.ObjectGuid, SurveyMode.Console, 1, TimeSpan.Zero, None);
        await fixture.Clock.RetryScheduled.Task.WaitAsync(Guard);
        var session = await fixture.Source.GetSessionAsync(None);
        _ = fixture.Machine.Resolve(session, fixture.Computer.DnsHostName);
        await AccountAccess.From(fixture.Context).OverviewAsync(None);
        Check.Equal(1, calls, "la première tentative est réellement terminée avant la pause");
        Check.True(SecureCredentialCopies.Contains(fixture.Once), "la pause de reprise conserve le bail détenu");
        fixture.Clock.Advance(TimeSpan.FromSeconds(30));
        var result = await work.WaitAsync(Guard);
        Check.Equal(2, calls, "une seule reprise sous le compte déjà admis");
        Check.True(result.Confirmed == true, "console vide native qualifiée, distincte d’une lecture non faite");
        Check.False(SecureCredentialCopies.Contains(fixture.Once), "aucun secret détenu après la qualification finale");
    }

    [Test]
    public static async Task Home_light_inventory_retries_with_the_identical_credential_for_local_and_shared_one_shots()
    {
        foreach (var shared in new[] { false, true })
        {
            var calls = 0; RemoteProbeCredential? first = null;
            using var fixture = await Fixture.Create((owner, credential) =>
            {
                Check.Equal(@"TEST\once", credential!.Account, "compte du premier départ et de sa reprise");
                if (first is null) { first = credential; }
                else { Check.True(ReferenceEquals(first, credential), "aucune nouvelle copie ni sélection sur le deuxième essai"); }
                return Reading(owner.Clock.GetUtcNow(), ++calls == 1);
            });
            await fixture.InstallAsync(shared);
            var work = fixture.HomeInventory();
            await fixture.Clock.RetryScheduled.Task.WaitAsync(Guard);
            var session = await fixture.Source.GetSessionAsync(None);
            _ = fixture.Machine.Resolve(session, fixture.Computer.DnsHostName);
            await AccountAccess.From(fixture.Context).OverviewAsync(None);
            Check.True(SecureCredentialCopies.Contains(fixture.Once), "compte encore détenu malgré le balayage de l’UI");
            fixture.Clock.Advance(TimeSpan.FromSeconds(30));
            await work.WaitAsync(Guard);
            Check.Equal(2, calls, "premier envoi puis reprise unique dans le consommateur Accueil");
            var value = fixture.Cache.Fleet.Observations.Workstations.Single().Inventory;
            Check.Equal(MeasureState.Known, value.State, "réponse finale qualifiée");
            Check.Equal("One-shot model", value.Model, "mesure du fournisseur conservée");
            Check.False(SecureCredentialCopies.Contains(fixture.Once), "détention terminée après le consommateur");
        }
    }

    [Test]
    public static async Task A_pause_between_Home_attempts_stops_the_retained_account_without_fallback()
    {
        var calls = 0;
        using var fixture = await Fixture.Create((owner, credential) =>
        {
            Check.Equal(@"TEST\once", credential!.Account, "aucun compte secondaire essayé");
            calls++; return Reading(owner.Clock.GetUtcNow(), true);
        });
        await fixture.InstallAsync(shared: true);
        var work = fixture.HomeInventory();
        await fixture.Clock.RetryScheduled.Task.WaitAsync(Guard);
        var key = CredentialRules.AccountKey(@"TEST\once", Fixtures.Domain.DnsName, Fixtures.Domain.NetbiosName, fixture.Computer.DnsHostName);
        AccountAccess.From(fixture.Context).RegisterRefusal(CredentialRules.Remote, "Refus concurrent", fixture.Computer.DnsHostName, "badCredentials", key, true);
        fixture.Clock.Advance(TimeSpan.FromSeconds(30));
        await work.WaitAsync(Guard);
        Check.Equal(1, calls, "pause détectée avant le nouvel envoi natif");
        Check.Equal(MeasureState.Refused, fixture.Cache.Fleet.Observations.Workstations.Single().Inventory.State, "refus conservé comme refus, sans réussite ni délai artificiel");
    }

    [Test]
    public static async Task Account_transport_and_expiry_changes_refuse_Home_retry_and_preserve_the_dated_first_answer()
    {
        foreach (var change in new[] { "account", "transport", "expiry" })
        {
            var calls = 0;
            using var fixture = await Fixture.Create((owner, credential) =>
            {
                Check.Equal(@"TEST\once", credential!.Account, "pas de repli pendant la reprise");
                calls++; return Reading(owner.Clock.GetUtcNow(), true);
            });
            await fixture.InstallAsync(shared: false, inactivity: change == "expiry");
            var work = fixture.HomeInventory();
            await fixture.Clock.RetryScheduled.Task.WaitAsync(Guard);
            if (change == "account") { fixture.Machine.UseRemote(@"TEST\replacement", fixture.Fallback.Copy()); }
            if (change == "transport") { fixture.Settings.Value = fixture.Settings.Value with { UseCim = false }; }
            fixture.Clock.Advance(TimeSpan.FromSeconds(change == "expiry" ? 61 : 30));
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => work.WaitAsync(Guard), "sélection périmée refusée avant reprise");
            Check.Equal(AccountAccess.EpochChanged, error.Code, "garde de compte/configuration conservée");
            Check.Equal(1, calls, "aucun nouvel envoi ni autre compte sélectionné");
            var saved = fixture.Cache.Fleet.Observations.Workstations.Single().Inventory;
            Check.Equal(Fixtures.Now, saved.CheckedAt, "date de la réponse terminée non rajeunie par la reprise refusée");
            Check.Equal("One-shot model", saved.Model, "mesure déjà reçue conservée");
        }
    }

    [Test]
    public static async Task A_cancelled_Search_inventory_holds_the_one_shot_until_the_native_worker_really_finishes()
    {
        using var fixture = await Fixture.Create(); await fixture.InstallAsync(shared: true);
        using var release = new ManualResetEventSlim(); using var stop = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reader = fixture.Search(query =>
        {
            entered.TrySetResult(); Check.True(release.Wait(Guard), "fournisseur natif libéré par le test");
            return InventoryRows(query);
        });
        var work = reader.ProbeAsync(fixture.Computer.ObjectGuid, SurveyMode.Analyse, 1, TimeSpan.Zero, stop.Token);
        try
        {
            await entered.Task.WaitAsync(Guard); await stop.CancelAsync();
            var session = await fixture.Source.GetSessionAsync(None); _ = fixture.Machine.Resolve(session, fixture.Computer.DnsHostName);
            var early = await Task.WhenAny(work, Task.Delay(TimeSpan.FromMilliseconds(75)));
            Check.False(ReferenceEquals(work, early), "le consommateur attend la fin physique sans réutiliser sa place");
            Check.True(SecureCredentialCopies.Contains(fixture.Once), "copie détenue tant que le worker vit après l’arrêt logique");
        }
        finally { release.Set(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => work.WaitAsync(Guard), "arrêt propagé seulement après libération réelle");
        Check.False(SecureCredentialCopies.Contains(fixture.Once), "copie libérée après la fin native et du consommateur");
    }

    private static WorkstationInventoryRead Reading(DateTimeOffset at, bool transient) => new(
        new(transient ? MeasureState.Incomplete : MeasureState.Known, at, 100, 50, at.AddDays(-1), "One-shot model", 16L << 30, "Windows", "26100"),
        new(null, null, null, null, transient ? MeasureState.Incomplete : MeasureState.Known, at, transient ? "Source transitoire" : null))
        { ReportedName = "PC1", HostIdentity = new("PC1.test.local", "PC1", "PC1", "test.local"), RetryFailure = transient ? CollectionReadFailure.Transient : CollectionReadFailure.Success, ReadPhysicallyCompleted = true };

    private static IReadOnlyList<WmiInstance> InventoryRows(string query) => query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
        ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Model", "One-shot model"), ("UserName", null), ("TotalPhysicalMemory", 16L << 30))]
        : query.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"), ("SystemDrive", "C:"), ("BuildNumber", "26100"))]
        : query.Contains("Win32_LogicalDisk", StringComparison.Ordinal) ? [Row(("DeviceID", "C:"), ("Size", 100UL), ("FreeSpace", 50UL))] : [];

    private sealed class Fixture : IDisposable
    {
        internal Clock Clock { get; } = new();
        internal DirectoryComputer Computer { get; } = Fixtures.Computer("PC1");
        internal AdPosteNetworkTests.Cache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal EngineContext Context { get; }
        internal MachineAccountService Machine => MachineAccountService.From(Context);
        internal CollectionSettingsReader Settings => (CollectionSettingsReader)Context.Readers.Require<IPosteSettingsReader>();
        internal SecureString Once { get; } = PasswordSecrets.FromText("once-fixture-" + Guid.NewGuid().ToString("N"));
        internal SecureString Fallback { get; } = PasswordSecrets.FromText("fallback-fixture-" + Guid.NewGuid().ToString("N"));
        private Fixture(Func<Fixture, RemoteProbeCredential?, WorkstationInventoryRead>? read)
        {
            Cache = new(Fixtures.Snapshot(computers: [Computer]));
            var ldap = new AdBoundaryTests.RecordingAdConnection
            { SearchAnswer = request => request.BaseDn == Computer.DistinguishedName ? [AdPosteNetworkTests.Entry(Computer)] : [] };
            Source = new("test.local", () => @"TEST\operator", Clock,
                read is null ? null : new FactsProbe(credential => read(this, credential)), new AdBoundaryTests.RecordingAdConnection(), Cache)
            { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
            Source.AdoptConnection(ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), Source.Epoch, false);
            Context = new(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), Source,
                new MemoryPreferenceStore(), Clock, new RecordingJournal(), ScreenReaders.Discover(Source, [typeof(CollectionSettingsReader).Assembly]));
            _ = Context.Shared(c => new AccountAccess(c.Directory, new AcceptedAccounts(), c.Preferences, c.Journal, c.Clock, c.Log, c.Mode, _ => Task.FromResult(0)));
            Machine.UseRemote(@"TEST\fallback", Fallback.Copy());
        }
        internal static async Task<Fixture> Create(Func<Fixture, RemoteProbeCredential?, WorkstationInventoryRead>? read = null)
        {
            var fixture = new Fixture(read);
            await fixture.Cache.SaveFleetAsync(FleetCachePatch.Empty with
            { Observations = new(Fixtures.Now, [Fixtures.Observe(fixture.Computer, Fixtures.Presence(true, TimeSpan.Zero))]) }, None);
            await fixture.Source.ReadLocalAsync(None); return fixture;
        }
        internal async Task InstallAsync(bool shared, bool inactivity = false)
        {
            var session = await Source.GetSessionAsync(None);
            if (!shared)
            {
                Machine.AcceptTemporary(session, null, @"TEST\once", Once.Copy(), inactivity ? MachineLeaseMode.Inactivity : MachineLeaseMode.OneShot, 1);
                Clock.WatchRetry(); return;
            }
            var accounts = AccountAccess.From(Context); await accounts.OverviewAsync(None);
            accounts.RegisterRefusal(CredentialRules.Remote, "Inventaire de fixture", Computer.DnsHostName, "accessDenied", null, true);
            var request = (await accounts.OverviewAsync(None)).Pending.First(p => p.Scope == CredentialRules.Remote);
            Check.True((await accounts.RecoverAsync(request.Id, @"TEST\once", Once, LeaseMode.OneShot, 30, Computer.DnsHostName, None)).Result.Success,
                "le magasin partagé accepte le compte de fixture avant le vrai consommateur");
            Clock.WatchRetry();
        }
        internal Task<DirectoryState> HomeInventory() => new AdAccueilReader(Source).ReadInventoryAsync(Scope,
            ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(Computer.ObjectGuid, QueryComputerIdentity.Of(Computer)), Source.Epoch, None);
        internal AdSearchReader Search(Func<string, IReadOnlyList<WmiInstance>> answer) => new(Source)
        {
            EchoOverride = (_, _) => Task.FromResult(Fixtures.Presence(true, TimeSpan.Zero)),
            ConsoleReaderOverride = settings => new WmiWorkstationReader(Clock, configuration: settings)
            {
                SessionFactory = (host, budget, token) => new(host, budget, Clock, cancellationToken: token)
                { ReadOverride = (_, query, _) => answer(query), RegistryOverride = (_, _) => new(2, null) },
            },
        };
        public void Dispose() { Context.Dispose(); Source.Dispose(); Once.Dispose(); Fallback.Dispose(); }
    }

    private sealed class FactsProbe(Func<RemoteProbeCredential?, WorkstationInventoryRead> read) : IConfiguredWorkstationFactsProbe
    {
        public Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken token) => throw new TestFailureException("La présence exacte était déjà confirmée.");
        public Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken token) => throw new TestFailureException("Le consommateur doit conserver la sélection authentifiée.");
        public Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken token) => throw new TestFailureException("Aucun repli sans compte.");
        public Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken token, RemoteProbeCredential? credential) => ReadFactsAsync(host, timeout, token, credential, null);
        public Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken token, RemoteProbeCredential? credential, PosteConfiguration? configuration)
        { token.ThrowIfCancellationRequested(); return Task.FromResult(read(credential)); }
    }

    private sealed class AcceptedAccounts : IAccountsAccessReader
    {
        public Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken token)
        { token.ThrowIfCancellationRequested(); return Task.FromResult(new CredentialAnswer(true, "ok", request.Login, null, "Validation mémoire de fixture.")); }
        public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken token) => Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty);
        public Task<string?> SessionSidAsync(CancellationToken token) => Task.FromResult<string?>(Fixtures.Domain.DomainSid + "-1001");
        public Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken token) => throw new TestFailureException("Aucun essai implicite du compte.");
        public Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken token) => throw new TestFailureException("Aucun changement de session.");
        public Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken token) => throw new TestFailureException("Aucune correction du secret.");
        public bool SessionSwitchAvailable => false;
        public bool Simulated => true;
        public DateTimeOffset? SessionStartedAt => null;
    }

    private sealed class Clock : TimeProvider
    {
        private readonly object gate = new();
        private readonly List<Timer> timers = [];
        private long ticks;
        internal TaskCompletionSource RetryScheduled { get; private set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal void WatchRetry() { lock (gate) { RetryScheduled = new(TaskCreationOptions.RunContinuationsAsynchronously); } }
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() { lock (gate) { return ticks; } }
        public override DateTimeOffset GetUtcNow() { lock (gate) { return Fixtures.Now + TimeSpan.FromTicks(ticks); } }
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
                    period = repeat; due = delay == Timeout.InfiniteTimeSpan ? long.MaxValue : owner.ticks + delay.Ticks;
                    if (delay == TimeSpan.FromSeconds(30)) { owner.RetryScheduled.TrySetResult(); }
                    return true;
                }
            }
            internal void Fire()
            {
                lock (owner.gate)
                {
                    if (disposed || owner.ticks < due) { return; }
                    due = period == Timeout.InfiniteTimeSpan ? long.MaxValue : owner.ticks + period.Ticks;
                }
                callback(state);
            }
            public void Dispose() { lock (owner.gate) { disposed = true; } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}

/// <summary>Discoverable fixture settings; it never opens a file or a transport.</summary>
public sealed class CollectionSettingsReader(AdDirectorySource source) : IPosteSettingsReader
{
    internal PosteConfiguration Value { get; set; } = PosteConfiguration.Defaults;
    public Task<PosteConfiguration> CurrentAsync(CancellationToken token)
    { token.ThrowIfCancellationRequested(); _ = source.Epoch; return Task.FromResult(Value); }
}
