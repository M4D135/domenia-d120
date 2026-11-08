using System.Collections.Immutable;
using System.Security;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CampaignQueryPhysicalCompletionTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);
    private const string Namespace = @"root\cimv2";
    private const string ModelQuery = "SELECT Model FROM Win32_ComputerSystem";
    private const string LoadQuery = "SELECT LoadPercentage FROM Win32_Processor";

    [Test]
    public static async Task Real_workshop_shares_declared_class_projections_while_rechecking_identity_for_each_consumer()
    {
        using var fixture = new Fixture(blockAt: int.MaxValue);
        var reader = new AdQueryWorkshopReader(fixture.Source) { InventoryReaderOverride = settings => fixture.Native.Reader(settings) };
        await reader.MeasureAsync(fixture.Request(probe: true, twoSources: true) with { Probes = ["hw.model", "hw.ram"] }, CancellationToken.None);
        var stored = (await reader.DatasetAsync(CancellationToken.None)).Probes[fixture.Computer.ObjectGuid];
        Check.Equal("Portable", stored.Single(p => p.ProbeId == "hw.model").Instances.Single().Values["Model"] as string, "modèle qualifié et durable");
        Check.Equal(17_179_869_184L, Convert.ToInt64(stored.Single(p => p.ProbeId == "hw.ram").Instances.Single().Values["TotalPhysicalMemory"], System.Globalization.CultureInfo.InvariantCulture), "deuxième projection durable");
        Check.Equal(1, fixture.Native.SelectedCalls, "un seul SELECT métier effectivement envoyé");
        Check.Equal(2, fixture.Native.MetadataCalls, "les deux lectures de schéma utilisent la doublure native du transport sélectionné");
        Check.Equal(4, fixture.Native.IdentityCalls, "identité CIM avant et après chacun des deux consommateurs");
        Check.Equal(2, fixture.Cache.Writes.Count, "deux publications qualifiées séparées conservées");
        Check.Equal(1L, OperationActivity.From(fixture.Context).GroupedCimQueriesAvoided, "synthèse de session raccordée au vrai parcours");
    }

    [Test]
    public static async Task Home_query_selects_and_probes_hold_admission_until_native_stop_then_invalidate_without_followup()
    {
        foreach (var probe in new[] { false, true })
        {
            using var fixture = new Fixture(); using var stop = new CancellationTokenSource();
            var reader = new AdQueryWorkshopReader(fixture.Source) { InventoryReaderOverride = settings => fixture.Native.Reader(settings) };
            var pending = reader.MeasureAsync(fixture.Request(probe, twoSources: false), stop.Token);
            var writesBefore = 0; var ldapBefore = 0;
            try
            {
                await fixture.Native.Entered.Task.WaitAsync(Guard);
                writesBefore = fixture.Cache.Writes.Count; ldapBefore = fixture.Ldap.Calls;
                await stop.CancelAsync(); await StillOwned(pending);
                Check.True(fixture.Native.Token.IsCancellationRequested, "arrêt transmis au SELECT natif");
                Check.Equal(writesBefore, fixture.Cache.Writes.Count, "aucun reçu prématuré pendant le SELECT bloqué");
            }
            finally { fixture.Native.Release.Set(); await Drain(pending); }
            await Check.ThrowsAsync<OperationCanceledException>(() => pending.WaitAsync(Guard), "arrêt de campagne conservé après la fin physique");
            Check.Equal(ldapBefore, fixture.Ldap.Calls, "aucune qualification LDAP après arrêt");
            Check.Equal(1, fixture.Native.SelectedCalls, "aucune reprise ni deuxième SELECT après arrêt");
            Check.True(fixture.Cache.Writes.Count > writesBefore, "échec persisté après la fin physique");
            var data = await reader.DatasetAsync(CancellationToken.None);
            if (probe)
            {
                var failed = data.Probes[fixture.Computer.ObjectGuid].Single();
                Check.NotNull(failed.Error, "sonde arrêtée explicitement inconnue");
                Check.False(failed.CountComplete, "pas de compte complet fabriqué");
                Check.Equal(0, failed.Instances.Length, "aucune instance sans qualification finale");
            }
            else
            {
                var failed = data.Details[fixture.Computer.ObjectGuid].Single();
                Check.False(failed.Success, "SELECT arrêté non réussi");
                Check.False(failed.CountComplete, "aucune absence confirmée par un zéro d’arrêt");
            }
        }
    }

    [Test]
    public static async Task Campaign_select_deadline_waits_and_observes_late_fault_without_publishing_instances()
    {
        foreach (var lateFault in new[] { false, true })
        {
            using var fixture = new NativeFixture(lateFault: lateFault);
            var pending = fixture.Reader().ReadWorkshopSelectAsync("PC1", Namespace, WqlRules.Parse(ModelQuery), 10,
                CancellationToken.None, awaitPhysicalCompletion: true);
            try
            {
                await fixture.Entered.Task.WaitAsync(Guard);
                fixture.Clock.Advance(TimeSpan.FromSeconds(45));
                await StillOwned(pending);
                Check.True(fixture.Token.IsCancellationRequested, "deadline logique transmise au fournisseur");
            }
            finally { fixture.Release.Set(); await Drain(pending); }
            var result = await pending.WaitAsync(Guard);
            Check.Equal(SourceStatus.Interrupted, result.Status, "deadline ou faute tardive non convertie en succès");
            Check.Equal(0, result.Rows.Length, "aucune instance non qualifiée publiée après la deadline");
            Check.Equal(1, fixture.SelectedCalls, "aucun nouvel essai automatique");
            Check.Equal(lateFault ? 1 : 0, fixture.LateFaults, "faute du worker effectivement produite et observée");
        }
    }

    [Test]
    public static async Task Later_stopped_source_preserves_previously_qualified_probe_and_select_with_original_date()
    {
        foreach (var probe in new[] { false, true })
        {
            using var fixture = new Fixture(blockAt: 2); using var stop = new CancellationTokenSource();
            var reader = new AdQueryWorkshopReader(fixture.Source) { InventoryReaderOverride = settings => fixture.Native.Reader(settings) };
            var pending = reader.MeasureAsync(fixture.Request(probe, twoSources: true), stop.Token);
            var ldapBefore = 0;
            try
            {
                await fixture.Native.Entered.Task.WaitAsync(Guard);
                Check.Equal(1, fixture.Cache.Writes.Count, "première source qualifiée et persistée avant la suivante");
                ldapBefore = fixture.Ldap.Calls;
                fixture.Native.Clock.Advance(TimeSpan.FromSeconds(2));
                await stop.CancelAsync(); await StillOwned(pending);
                Check.Equal(1, fixture.Cache.Writes.Count, "premier reçu conservé pendant la source suivante encore vivante");
            }
            finally { fixture.Native.Release.Set(); await Drain(pending); }
            await Check.ThrowsAsync<OperationCanceledException>(() => pending.WaitAsync(Guard), "arrêt propagé après le deuxième worker");
            Check.Equal(ldapBefore, fixture.Ldap.Calls, "aucune qualification LDAP supplémentaire après arrêt");
            var data = await reader.DatasetAsync(CancellationToken.None);
            if (probe)
            {
                var values = data.Probes[fixture.Computer.ObjectGuid];
                var first = values.Single(p => p.ProbeId == "hw.model");
                Check.Null(first.Error, "première sonde réussie non invalidée par l’arrêt de la suivante");
                Check.Equal(Fixtures.Now, first.CheckedAt, "date native conservée sans rajeunissement");
                Check.Equal("Portable", first.Instances.Single().Values["Model"] as string, "mesure qualifiée réellement conservée");
                Check.NotNull(values.Single(p => p.ProbeId == "hw.cpuload").Error, "seule la sonde inachevée est invalidée");
            }
            else
            {
                var values = data.Details[fixture.Computer.ObjectGuid];
                var first = values.Single(d => d.RequestKey == WqlRules.RequestKey(Namespace, WqlRules.Parse(ModelQuery).CanonicalQuery));
                Check.True(first.Success && first.CountComplete, "premier SELECT qualifié conserve son compte complet");
                Check.Equal(Fixtures.Now, first.At, "date du premier compte conservée");
                Check.Equal(1L, first.StoredCount, "compte natif conservé");
                Check.False(values.Single(d => d.RequestKey == WqlRules.RequestKey(Namespace, WqlRules.Parse(LoadQuery).CanonicalQuery)).Success,
                    "seul le SELECT inachevé est invalidé");
            }
        }
    }

    [Test]
    public static async Task Ordinary_workshop_select_retains_prompt_ui_detachment()
    {
        using var fixture = new NativeFixture(); using var stop = new CancellationTokenSource();
        var pending = fixture.Reader().ReadWorkshopSelectAsync("PC1", Namespace, WqlRules.Parse(ModelQuery), 10, stop.Token);
        try
        {
            await fixture.Entered.Task.WaitAsync(Guard); await stop.CancelAsync();
            var result = await pending.WaitAsync(Guard);
            Check.Equal(SourceStatus.Interrupted, result.Status, "arrêt UI immédiat maintenu hors campagne");
            Check.False(fixture.Returned.Task.IsCompleted, "fournisseur encore vivant pendant le détachement UI");
            Check.Equal(0, result.Rows.Length, "détachement ne publie aucune instance non qualifiée");
        }
        finally { fixture.Release.Set(); await fixture.Returned.Task.WaitAsync(Guard); await Drain(pending); }
    }

    private static async Task StillOwned(Task pending)
    {
        var observed = await Task.WhenAny(pending, Task.Delay(TimeSpan.FromMilliseconds(75)));
        Check.False(ReferenceEquals(pending, observed), "annulation logique sans restitution prématurée du bail de campagne");
    }

    private static async Task Drain(Task task)
    {
        try { await task.WaitAsync(Guard); }
        catch (Exception) { /* Cleanup observes failures; assertions separately verify the expected outcome. */ }
    }

    private sealed class Fixture : IDisposable
    {
        internal DirectoryComputer Computer { get; } = Fixtures.Computer("PC1");
        internal QueryCache Cache { get; }
        internal AdBoundaryTests.RecordingAdConnection Ldap { get; } = new();
        internal AdDirectorySource Source { get; }
        internal EngineContext Context { get; }
        internal NativeFixture Native { get; }

        internal Fixture(int blockAt = 1)
        {
            Native = new(blockAt); Cache = new(Fixtures.Snapshot(computers: [Computer]));
            Ldap.SearchAnswer = request => request.BaseDn == Computer.DistinguishedName ? [AdPosteNetworkTests.Entry(Computer)] : [];
            Source = new("test.local", () => @"TEST\operator", Native.Clock,
                connection: new AdBoundaryTests.RecordingAdConnection(), localStore: Cache)
            { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
            Source.AdoptConnection(Ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), Source.Epoch, false);
            Context = new(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), Source,
                new MemoryPreferenceStore(), Native.Clock, new RecordingJournal());
            using var password = new SecureString(); foreach (var c in "fixture-only") { password.AppendChar(c); }
            MachineAccountService.From(Context).UseRemote(@"TEST\probe", password.Copy());
            Native.Credential = new(@"TEST\probe", password.Copy(), false);
        }

        internal QueryMeasureRequest Request(bool probe, bool twoSources) => new([Computer.ObjectGuid], false, false, false,
            probe ? twoSources ? ["hw.model", "hw.cpuload"] : ["hw.model"] : [],
            probe ? [] : twoSources ? [WqlRules.NewReadDefinition(Namespace, ModelQuery, 10), WqlRules.NewReadDefinition(Namespace, LoadQuery, 10)]
                : [WqlRules.NewReadDefinition(Namespace, ModelQuery, 10)])
        {
            ExpectedEpoch = Source.Epoch,
            ExpectedIdentities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(Computer.ObjectGuid, QueryComputerIdentity.Of(Computer)),
        };

        public void Dispose() { Native.Release.Set(); Context.Dispose(); Source.Dispose(); Native.Dispose(); }
    }

    private sealed class QueryCache(DirectorySnapshot directory) : IObjectDirectoryCache, IQueryResultsStore
    {
        internal QueryStoredReadings Stored { get; private set; } = QueryStoredReadings.Empty;
        internal List<QueryComputerReadings> Writes { get; } = [];
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => Task.FromResult<DirectorySnapshot?>(directory);
        public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken token) => ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot value, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Pas de recensement.");
        public Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot value, string? controller, CancellationToken token) => throw new InvalidOperationException("Pas de modification d’identité.");
        public Task<QueryStoredReadings> ReadQueryResultsAsync(CancellationToken token) => Task.FromResult(Stored);
        public Task<QueryStoredReadings> SaveQueryResultsAsync(QueryComputerReadings value, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            var expected = directory.Computers.Single(c => c.ObjectGuid == value.Computer);
            Check.True(expected.WhenCreated == value.Created && DistinguishedName.AreEqual(expected.DistinguishedName, value.Dn), "reçu lié à l’identité exacte");
            QueryReadingRules.Validate(value, Fixtures.Now.AddMinutes(1));
            Writes.Add(value);
            var next = QueryReadingRules.Merge(Stored.Computers.SingleOrDefault(c => c.Computer == value.Computer), value);
            return Task.FromResult(Stored = new(Stored.Revision + 1, [.. Stored.Computers.Where(c => c.Computer != value.Computer), next]));
        }
    }

    private sealed class NativeFixture(int blockAt = 1, bool lateFault = false) : IDisposable
    {
        internal Clock Clock { get; } = new();
        internal TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Returned { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal ManualResetEventSlim Release { get; } = new();
        internal CancellationToken Token;
        internal int SelectedCalls;
        internal int IdentityCalls;
        internal int MetadataCalls;
        internal int LateFaults;
        internal RemoteProbeCredential? Credential { get; set; }

        internal WmiWorkstationReader Reader(PosteConfiguration? settings = null) => new(Clock, configuration: settings)
        {
            SessionFactory = (host, budget, token) =>
            {
                Token = token;
                return new(host, budget, Clock, cancellationToken: token, credential: Credential, transport: settings?.SelectedCimTransport ?? InventoryTransport.Dcom)
                {
                    MetadataOverride = (_, _, _, _) => { Interlocked.Increment(ref MetadataCalls); return [Property("Name", true), Property("Model"), Property("TotalPhysicalMemory"), Property("LoadPercentage")]; },
                    MetadataShellOverride = (kind, ns, className, _) =>
                    {
                        Interlocked.Increment(ref MetadataCalls);
                        return new(SourceStatus.Ok, JsonSerializer.Serialize(new
                        {
                            Format = "Domenia.WmiMetadata/1", Kind = kind.ToString(), Computer = "PC1", Namespace = ns,
                            Class = className, Code = 0, Partial = false,
                            Rows = new[] { "Name", "Model", "TotalPhysicalMemory", "LoadPercentage" }.Select(name =>
                                new { Name = name, Type = "String", Key = name == "Name", Qualifiers = "" }).ToArray(),
                        }), false, true);
                    },
                    ReadOverride = (_, query, _) =>
                    {
                        if (query.StartsWith("SELECT Name, DNSHostName, Domain FROM", StringComparison.Ordinal)) { Interlocked.Increment(ref IdentityCalls); return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))]; }
                        if (Interlocked.Increment(ref SelectedCalls) == blockAt)
                        {
                            Entered.TrySetResult();
                            try
                            {
                                Check.True(Release.Wait(Guard), "barrière du fournisseur libérée");
                                if (lateFault) { LateFaults++; throw new InvalidOperationException("native fixture failure after stop"); }
                            }
                            finally { Returned.TrySetResult(); }
                        }
                        return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Model", "Portable"), ("TotalPhysicalMemory", 17_179_869_184L), ("LoadPercentage", 20))];
                    },
                };
            },
        };
        private static WmiInstance Property(string name, bool key = false) => Row(("Name", name), ("Type", "String"), ("Key", key));
        private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(p => p.Key, p => p.Value));
        public void Dispose() { Release.Set(); Release.Dispose(); Credential?.Dispose(); }
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
            private bool disposed;
            public bool Change(TimeSpan delay, TimeSpan period)
            {
                lock (owner.gate)
                { if (disposed) { return false; } due = delay == Timeout.InfiniteTimeSpan ? long.MaxValue : owner.ticks + delay.Ticks; return true; }
            }
            internal void Fire()
            {
                lock (owner.gate) { if (disposed || due > owner.ticks) { return; } due = long.MaxValue; }
                callback(state);
            }
            public void Dispose() { lock (owner.gate) { disposed = true; due = long.MaxValue; } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
