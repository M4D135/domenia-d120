using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using ProbeCatalog = Domenia.Core.Accueil.ProbeCatalog;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

internal static class AdAccueilTests
{
    private static readonly ScopeSelection Scope = new(Fixtures.Postes, "Postes", true);
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));

    [Test]
    public static async Task Home_facts_history_and_probes_are_local_without_an_implicit_connection()
    {
        var computer = Fixtures.Computer("PC1");
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var cache = new FleetCache(Fixtures.Snapshot(computers: [computer]));
        cache.Fleet = cache.Fleet.Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(computer, Fixtures.Presence(true, TimeSpan.Zero))]) });
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdAccueilReader(source);
        Check.Equal("memory", (await reader.FactsAsync(CancellationToken.None)).StoreId, "base locale");
        await reader.HistoryAsync(Scope, CancellationToken.None);
        await reader.StoredProbesAsync(CancellationToken.None);
        Check.Equal(1, source.CurrentObservations.Workstations.Length, "mesure restaurée");
        Check.Equal(0, ldap.Calls, "aucun LDAP pour les vues locales");
    }

    [Test]
    public static async Task A_failed_backup_prevents_the_directory_object_read()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var cache = new FleetCache(Fixtures.Snapshot()) { FailBackup = true };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => source.RefreshAsync(MeasureFamily.Directory, Scope, CancellationToken.None), "sauvegarde refusée");
        Check.False(ldap.Searches.Any(q => q.Filter is AdDirectoryMapper.UserFilter or AdDirectoryMapper.ComputerFilter or AdDirectoryMapper.OuFilter or AdDirectoryMapper.GroupFilter), "aucune lecture d’objets sans sauvegarde");
        Check.Equal(0, cache.DirectoryWrites, "aucun enregistrement de faux relevé");
    }

    [Test]
    public static async Task BitLocker_counts_only_metadata_and_respects_the_direct_children_scope()
    {
        var computer = Fixtures.Computer("PC1");
        var child = Fixtures.Computer("PC2", "OU=Enfants," + Fixtures.Postes);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        ldap.SearchAnswer = q => q.Filter.Contains("classSchema", StringComparison.Ordinal)
            ? [new("CN=BitLocker," + ldap.SchemaContext, new Dictionary<string, IReadOnlyList<object>> { ["lDAPDisplayName"] = ["msFVE-RecoveryInformation"] })]
            : q.Filter == "(objectClass=msFVE-RecoveryInformation)"
                ? [new("CN=Recovery," + computer.DistinguishedName, new Dictionary<string, IReadOnlyList<object>> { ["whenCreated"] = ["20261020100000.0Z"] })] : [];
        var cache = new FleetCache(Fixtures.Snapshot(computers: [computer, child]));
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: cache);
        var result = await new AdAccueilReader(source).ReadBitLockerAsync(Scope with { Subtree = false }, CancellationToken.None);
        Check.Equal(1, result.Machines[computer.ObjectGuid].Keys, "une métadonnée de récupération");
        Check.False(result.Truncated, "réponse entière");
        var request = ldap.Searches.Single(q => q.Filter == "(objectClass=msFVE-RecoveryInformation)");
        Check.Equal(computer.DistinguishedName, request.BaseDn, "seul poste enfant direct");
        Check.Equal(AdSearchScope.OneLevel, request.Scope, "enfants du poste");
        Check.True(request.Attributes.SequenceEqual(new[] { "distinguishedName", "whenCreated" }), "jamais de clé ni de paquet secret");
        Check.Equal(1, cache.Fleet.Facts.BitLocker.Length, "relevé conservé");
    }

    [Test]
    public static async Task BitLocker_root_is_refused_before_any_network_read_and_missing_schema_is_explicit()
    {
        var computer = Fixtures.Computer("PC1");
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var cache = new FleetCache(Fixtures.Snapshot(computers: [computer]));
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdAccueilReader(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadBitLockerAsync(new(Fixtures.Root, "Tout", true), CancellationToken.None), "domaine interdit");
        Check.Equal(0, ldap.Calls, "aucun réseau sur une portée interdite");
        var absent = await reader.ReadBitLockerAsync(Scope, CancellationToken.None);
        Check.False(absent.ClassPresent, "classe absente signalée");
        Check.False(ldap.Searches.Any(q => q.Filter == "(objectClass=msFVE-RecoveryInformation)"), "pas de requête de récupération si classe absente");
    }

    [Test]
    public static async Task Inventory_contacts_only_requested_enabled_online_computers_without_another_ping()
    {
        var online = Fixtures.Computer("ONLINE");
        var offline = Fixtures.Computer("OFFLINE");
        var disabled = Fixtures.Computer("DISABLED") with { UserAccountControl = AdValues.WorkstationTrustAccount | AdValues.AccountDisabled };
        var outside = Fixtures.Computer("OUTSIDE", Fixtures.People);
        var all = new[] { online, offline, disabled, outside };
        var cache = new FleetCache(Fixtures.Snapshot(computers: all));
        cache.Fleet = cache.Fleet.Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [.. all.Select(c => Fixtures.Observe(c, Fixtures.Presence(c != offline, TimeSpan.Zero)))]) });
        var probe = new CountingProbe();
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), probe, ldap, cache);
        await source.ReadLocalAsync(CancellationToken.None);
        await new AdAccueilReader(source).ReadInventoryAsync(Scope, all.Select(c => c.ObjectGuid).ToHashSet(), CancellationToken.None);
        Check.True(probe.Inventory.SequenceEqual(new[] { online.DnsHostName! }), "cible précise");
        Check.Equal(0, probe.Pings, "aucun second ping");
        Check.True(cache.Fleet.Observations.Workstations.Single(o => o.ComputerGuid == online.ObjectGuid).Inventory.HasReading, "inventaire durable avant publication");
    }

    [Test]
    public static async Task Failed_fleet_storage_leaves_the_previous_state_visible()
    {
        var computer = Fixtures.Computer("PC1");
        var cache = new FleetCache(Fixtures.Snapshot(computers: [computer])) { FailFleet = true };
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), new CountingProbe(), ldap, cache);
        await source.ReadLocalAsync(CancellationToken.None);
        await Check.ThrowsAsync<IOException>(() => source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None), "reçu local indispensable");
        Check.True(source.CurrentObservations.Workstations.IsEmpty, "résultat non enregistré non publié");
    }

    [Test]
    public static async Task Catalog_probe_skip_on_DC_is_applied_before_transport()
    {
        var calls = 0;
        var clock = TestClock.Fixed();
        var reader = new WmiFleetProbeReader(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token) { ReadOverride = (_, _, _) => { calls++; return []; } },
        };
        var dc = Fixtures.Computer("DC1") with { UserAccountControl = 8192 };
        var result = await reader.ReadAsync(dc, ["sec.localusers", "hw.model"], CancellationToken.None);
        Check.Equal(MeasureState.NotRead, result["sec.localusers"].State, "sonde interdite sur DC");
        Check.Equal(1, calls, "seule la sonde matérielle contacte le poste");
    }

    [Test]
    public static void Probe_empty_count_partial_result_and_missing_value_remain_distinct()
    {
        var count = ProbeCatalog.Find("disk.count")!;
        var empty = WmiFleetProbeReader.Project(count, new("Disques", SourceStatus.Empty, "vide", 1, []), Fixtures.Now);
        Check.Equal("0", empty.Values.Single(), "zéro seulement si lecture entière vide");
        var partial = WmiFleetProbeReader.Project(count, new("Disques", SourceStatus.Partial, "plafond", 1, [Row(("DeviceID", "C:"))]), Fixtures.Now);
        Check.Equal(MeasureState.Incomplete, partial.State, "nombre partiel non présenté comme un total");
        Check.True(partial.Values.IsEmpty, "pas de faux total");
        var missing = WmiFleetProbeReader.Project(ProbeCatalog.Find("hw.ram")!, new("Mémoire", SourceStatus.Ok, "lu", 1, [Row(("TotalPhysicalMemory", null))]), Fixtures.Now);
        Check.True(missing.Values.IsEmpty, "mémoire manquante non remplacée par zéro");
        var disk = WmiFleetProbeReader.Project(ProbeCatalog.Find("disk.cfree")!, new("Disque", SourceStatus.Ok, "lu", 1, [Row(("FreeSpace", 30L), ("Size", 100L))]), Fixtures.Now);
        Check.Equal("30", ProbeCatalog.Values(ProbeCatalog.Find("disk.cfree")!, disk, Fixtures.Now).Single(), "projection multi-champs et pourcentage");
    }

    [Test]
    public static void Recent_success_survives_a_failed_attempt_without_hiding_the_attempt()
    {
        var computer = Fixtures.Computer("PC1");
        var old = Fixtures.Observe(computer, Fixtures.Presence(true, TimeSpan.FromMinutes(5)), Fixtures.Disk(100, 40, TimeSpan.FromMinutes(5)));
        var fleet = CachedFleet.Empty("memory").Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now.AddMinutes(-5), [old]) });
        var failed = InventoryMeasure.Unread with { State = MeasureState.Refused, CheckedAt = Fixtures.Now };
        var next = fleet.Merge(FleetCachePatch.Empty with
        {
            Observations = new(Fixtures.Now, [old with { Inventory = failed }]),
            Machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(computer.ObjectGuid, new(null, null, null, null, MeasureState.Refused, Fixtures.Now, "Accès refusé")),
        });
        Check.Equal(old.Inventory, next.Observations.Workstations.Single().Inventory, "succès récent préservé");
        Check.Equal(MeasureState.Refused, next.Facts.Machines[computer.ObjectGuid].WmiState, "refus daté visible");
    }

    [Test]
    public static async Task Cancelled_presence_keeps_completed_readings_and_starts_no_later_targets()
    {
        var first = Fixtures.Computer("PC1");
        var second = Fixtures.Computer("PC2");
        using var stop = new CancellationTokenSource();
        var probe = new CancellingProbe(stop);
        var cache = new FleetCache(Fixtures.Snapshot(computers: [first, second, Fixtures.Computer("PC3")]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), probe, ldap, cache);
        await Check.ThrowsAsync<OperationCanceledException>(() => source.RefreshAsync(MeasureFamily.Presence, Scope, stop.Token), "annulation remontée");
        Check.Equal(2, probe.Calls, "aucune troisième mesure après arrêt");
        Check.Equal(first.ObjectGuid, cache.Fleet.Observations.Workstations.Single().ComputerGuid, "premier relevé enregistré");
        Check.Equal(first.ObjectGuid, source.CurrentObservations.Workstations.Single().ComputerGuid, "relevé terminé visible");
    }

    private sealed class CancellingProbe(CancellationTokenSource stop) : IWorkstationProbe
    {
        public int Calls { get; private set; }
        public Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken)
        {
            Calls++;
            if (Calls == 2) { stop.Cancel(); cancellationToken.ThrowIfCancellationRequested(); }
            return Task.FromResult(true);
        }
        public Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) => throw new InvalidOperationException("Aucun inventaire demandé.");
    }

    private sealed class CountingProbe : IWorkstationProbe
    {
        public int Pings { get; private set; }
        public List<string> Inventory { get; } = [];
        public Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) { Pings++; return Task.FromResult(true); }
        public Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) { Inventory.Add(host); return Task.FromResult(Fixtures.Disk(100, 50, TimeSpan.Zero)); }
    }

    private sealed class FleetCache(DirectorySnapshot snapshot) : IPreparedDirectoryCache, IAccueilCache
    {
        public CachedFleet Fleet { get; set; } = CachedFleet.Empty("memory");
        public bool FailBackup { get; init; }
        public bool FailFleet { get; init; }
        public int DirectoryWrites { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult<DirectorySnapshot?>(snapshot);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) { DirectoryWrites++; return Task.CompletedTask; }
        public Task<DirectoryBackupReceipt> PrepareAsync(CancellationToken cancellationToken) => FailBackup ? throw new IOException("backup") : Task.FromResult(new DirectoryBackupReceipt("memory", "verified", Fixtures.Now));
        public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) => Task.FromResult(Fleet);
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken)
        { if (FailFleet) { throw new IOException("commit"); } Fleet = Fleet.Merge(patch); return Task.FromResult(Fleet); }
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    }
}
