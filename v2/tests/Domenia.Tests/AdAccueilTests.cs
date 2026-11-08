using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using QueryComputerIdentity = Domenia.Core.Queries.QueryComputerIdentity;
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
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
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
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.ReadLocalAsync(CancellationToken.None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => source.RefreshAsync(MeasureFamily.Directory, Scope, CancellationToken.None), "sauvegarde refusée");
        Check.False(ldap.Searches.Any(q => q.Filter is AdDirectoryMapper.UserFilter or AdDirectoryMapper.ComputerFilter or AdDirectoryMapper.OuFilter or AdDirectoryMapper.GroupFilter), "aucune lecture d’objets sans sauvegarde");
        Check.Equal(0, cache.DirectoryWrites, "aucun enregistrement de faux relevé");
    }

    [Test]
    public static async Task A_range_failure_after_backup_preserves_the_previous_cache_and_stops_the_snapshot()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var previous = Fixtures.Snapshot(computers: [Fixtures.Computer("PC-conservé")]) with { Coverage = Scope };
        var cache = new FleetCache(previous);
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.ReadLocalAsync(CancellationToken.None);
        await source.DomainAsync(CancellationToken.None);
        ldap.Searches.Clear();
        ldap.SearchAnswer = q => q.Filter == AdDirectoryMapper.ComputerFilter
            ? throw AdReadDiagnostics.Refuse("objet-modifié", "memberOf", 1500, 49999, total: 1500, maximum: 50000)
            : [];
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => source.RefreshAsync(MeasureFamily.Directory, Scope, CancellationToken.None), "échec après sauvegarde");
        Check.Contains("étape=snapshot-postes", refused.Message, "classe d’objet en échec connue");
        Check.Equal(1, cache.BackupCalls, "sauvegarde vérifiée acquise");
        Check.Equal(0, cache.DirectoryWrites, "aucun snapshot incomplet enregistré après exception");
        Check.Equal(previous, (await source.ReadLocalAsync(CancellationToken.None)).Directory, "base précédente conservée");
        Check.Equal(3, ldap.Searches.Count, "OU et utilisateurs avant échec postes ; ni groupes ni contacts ni réessai");
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
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
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
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
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
        ldap.SearchAnswer = q => q.Filter == "(objectClass=computer)" && all.FirstOrDefault(c => DistinguishedName.AreEqual(c.DistinguishedName, q.BaseDn)) is { } pc
            ? [AdPosteNetworkTests.Entry(pc)] : [];
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.ReadLocalAsync(CancellationToken.None);
        await new AdAccueilReader(source).ReadInventoryAsync(Scope, all.Select(c => c.ObjectGuid).ToHashSet(), CancellationToken.None);
        Check.True(probe.Inventory.SequenceEqual(new[] { online.DnsHostName! }), "cible précise");
        Check.Equal(0, probe.Pings, "aucun second ping");
        Check.True(cache.Fleet.Observations.Workstations.Single(o => o.ComputerGuid == online.ObjectGuid).Inventory.HasReading, "inventaire durable avant publication");
    }

    [Test]
    public static async Task An_explicit_no_echo_policy_reads_inventory_without_fabricating_presence()
    {
        var pc = Fixtures.Computer("FILTERED");
        var noReply = Fixtures.Presence(false, TimeSpan.Zero) with { Diagnostic = new(PresenceReadOutcome.NoReply, "icmp") };
        var cache = new FleetCache(Fixtures.Snapshot(computers: [pc]));
        cache.Fleet = cache.Fleet.Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(pc, noReply)]) });
        var probe = new CountingProbe();
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        ldap.SearchAnswer = q => q.Filter == "(objectClass=computer)" && DistinguishedName.AreEqual(q.BaseDn, pc.DistinguishedName)
            ? [AdPosteNetworkTests.Entry(pc)] : [];
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.ReadLocalAsync(CancellationToken.None);
        var reader = new AdAccueilReader(source);
        await reader.ReadInventoryAsync(Scope, new HashSet<Guid> { pc.ObjectGuid }, CancellationToken.None);
        Check.Equal(0, probe.Inventory.Count, "politique normale ne tente pas CIM");
        using (CollectionNetworkPolicy.Enter(true))
        { await reader.ReadInventoryAsync(Scope, new HashSet<Guid> { pc.ObjectGuid }, CancellationToken.None); }
        Check.Equal(1, probe.Inventory.Count, "un seul inventaire après activation explicite");
        Check.Equal(0, probe.Pings, "aucun nouveau ping");
        var read = cache.Fleet.Observations.Workstations.Single();
        Check.True(read.Inventory.HasReading, "inventaire reçu conservé");
        Check.False(read.Presence.Answered == true, "WMI ne fabrique pas une réponse ICMP");
    }

    [Test]
    public static async Task Frozen_presence_includes_a_never_probed_target_and_rejects_identity_drift_before_ICMP()
    {
        var selected = Fixtures.Computer("NEVER"); var added = Fixtures.Computer("NEW");
        var cache = new FleetCache(Fixtures.Snapshot(computers: [selected, added]));
        var probe = new CountingProbe();
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        DirectoryComputer live = selected;
        ldap.SearchAnswer = q => q.Filter == "(objectClass=computer)" && DistinguishedName.AreEqual(q.BaseDn, selected.DistinguishedName) ? [AdPosteNetworkTests.Entry(live)] : [];
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.ReadLocalAsync(CancellationToken.None);
        await source.DomainAsync(CancellationToken.None);
        var epoch = source.Epoch;
        var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(selected.ObjectGuid, QueryComputerIdentity.Of(selected));
        var reader = new AdAccueilReader(source);
        await reader.ReadPresenceAsync(Scope, identities, epoch, CancellationToken.None);
        Check.Equal(1, probe.Pings, "un poste jamais pingé est éligible, le nouveau poste non sélectionné est exclu");
        Check.Equal(0, probe.Inventory.Count, "le ping seul ne lit pas CIM");
        Check.True(cache.Fleet.Observations.Workstations.Single(o => o.ComputerGuid == selected.ObjectGuid).Presence.HasReading, "ping enregistré après qualification finale");
        live = selected with { DnsHostName = "autre.test.local" };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadPresenceAsync(Scope, identities, epoch, CancellationToken.None), "changement DNS réel après préparation refuse le contact");
        Check.Equal(1, probe.Pings, "aucun second ICMP après substitution");
        var replaced = identities.SetItem(selected.ObjectGuid, identities[selected.ObjectGuid] with { Created = selected.WhenCreated.AddSeconds(1) });
        var beforeLdap = ldap.Searches.Count;
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadPresenceAsync(Scope, replaced, epoch, CancellationToken.None), "réincarnation locale refuse avant la qualification réseau");
        Check.Equal(beforeLdap, ldap.Searches.Count, "aucun LDAP si le plan ne correspond plus à la base");
    }

    [Test]
    public static async Task Frozen_probe_selection_refuses_changed_identity_or_epoch_before_the_native_reader()
    {
        var selected = Fixtures.Computer("SELECTED"); var added = Fixtures.Computer("ADDED");
        var cache = new FleetCache(Fixtures.Snapshot(computers: [selected, added]));
        cache.Fleet = cache.Fleet.Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now,
            [Fixtures.Observe(selected, Fixtures.Presence(true, TimeSpan.Zero)), Fixtures.Observe(added, Fixtures.Presence(true, TimeSpan.Zero))]) });
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.ReadLocalAsync(CancellationToken.None);
        var epoch = source.Epoch; var called = new List<Guid>();
        var reader = new AdAccueilReader(source)
        {
            ProbeOverride = (computer, _, _) =>
            {
                called.Add(computer.ObjectGuid);
                return Task.FromResult(ImmutableDictionary<string, ProbeReading>.Empty.Add("hw.model", new(MeasureState.Known, Fixtures.Now, ["Modèle"], null)));
            },
        };
        var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(selected.ObjectGuid, QueryComputerIdentity.Of(selected));
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectProbesAsync(["hw.model"], Scope,
            identities.SetItem(selected.ObjectGuid, identities[selected.ObjectGuid] with { Host = "another.test.local" }), epoch, CancellationToken.None), "hôte réaffecté");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectProbesAsync(["hw.model"], Scope, identities, epoch - 1, CancellationToken.None), "ancienne génération");
        Check.Equal(0, called.Count, "aucune sonde envoyée sur un plan changé");
        Check.Equal(0, ldap.Calls, "refus local avant qualification réseau");
        await reader.CollectProbesAsync(["hw.model"], Scope, identities, epoch, CancellationToken.None);
        Check.True(called.SequenceEqual([selected.ObjectGuid]), "seule l’identité approuvée atteint le lecteur");
        Check.False(cache.Fleet.Probes.ByProbe["hw.model"].ContainsKey(added.ObjectGuid), "le nouveau poste n’élargit pas la sonde");
    }

    [Test]
    public static async Task Failed_fleet_storage_leaves_the_previous_state_visible()
    {
        var computer = Fixtures.Computer("PC1");
        var cache = new FleetCache(Fixtures.Snapshot(computers: [computer])) { FailFleet = true };
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), new CountingProbe(), ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
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
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token) { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) => { calls++; return query == "SELECT Name, DNSHostName, Domain FROM Win32_ComputerSystem" ? [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "DC1", ["DNSHostName"] = "DC1", ["Domain"] = "test.local" })] : []; } },
        };
        var dc = Fixtures.Computer("DC1") with { UserAccountControl = 8192 };
        var result = await reader.ReadAsync(dc, ["sec.localusers", "hw.model"], CancellationToken.None);
        Check.Equal(MeasureState.NotRead, result["sec.localusers"].State, "sonde interdite sur DC");
        Check.Equal(2, calls, "identité puis sonde matérielle seulement");
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
        Check.Equal(old.Inventory, next.Observations.Workstations.Single().Inventory.LastSuccessful, "succès conservé séparément de la dernière tentative");
        Check.Equal(MeasureState.Refused, next.Observations.Workstations.Single().Inventory.State, "refus courant conservé dans l’observation");
        Check.Equal(MeasureState.Refused, next.Facts.Machines[computer.ObjectGuid].WmiState, "refus daté visible");
    }

    [Test]
    public static async Task Cancelled_presence_keeps_completed_readings_and_starts_no_later_targets()
    {
        var first = Fixtures.Computer("PC1");
        var second = Fixtures.Computer("PC2");
        using var stop = new CancellationTokenSource();
        var probe = new CancellingProbe(stop, first.DnsHostName!, second.DnsHostName!);
        var cache = new FleetCache(Fixtures.Snapshot(computers: [first, second, Fixtures.Computer("PC3")]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await Check.ThrowsAsync<OperationCanceledException>(() => source.RefreshAsync(MeasureFamily.Presence, Scope, stop.Token), "annulation remontée");
        Check.Equal(2, probe.Calls, "aucune troisième mesure après arrêt");
        Check.Equal(first.ObjectGuid, cache.Fleet.Observations.Workstations.Single().ComputerGuid, "premier relevé enregistré");
        Check.Equal(first.ObjectGuid, source.CurrentObservations.Workstations.Single().ComputerGuid, "relevé terminé visible");
    }

    [Test]
    public static async Task Presence_budget_refusal_preserves_completed_measures_without_inventing_an_offline_or_WMI_result()
    {
        foreach (var code in new[] { "operation.siteBusy", "operation.physicalBusy" })
        {
            var answered = Fixtures.Computer("PC1"); var waiting = Fixtures.Computer("PC2");
            var probe = new BusyProbe(waiting.DnsHostName!, code);
            var cache = new FleetCache(Fixtures.Snapshot(computers: [answered, waiting]));
            using var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
            var state = await source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None);
            Check.Equal(1, probe.Sent, "seule la lecture admise a été envoyée");
            var complete = cache.Fleet.Observations.Workstations.Single(o => o.ComputerGuid == answered.ObjectGuid);
            Check.Equal(true, complete.Presence.Answered, "réponse achevée enregistrée malgré le refus voisin");
            var refused = cache.Fleet.Observations.Workstations.Single(o => o.ComputerGuid == waiting.ObjectGuid);
            Check.Null(refused.Presence.Answered, "absence d’admission ne signifie pas poste hors ligne");
            Check.False(refused.Presence.HasReading, "pas de mesure de présence inventée");
            Check.Equal(InventoryMeasure.Unread, refused.Inventory, "aucun inventaire demandé, donc aucun échec WMI");
            Check.False(cache.Fleet.Facts.Machines.ContainsKey(waiting.ObjectGuid), "aucune fausse observation WMI");
            Check.True(state.Journal.Any(j => j.Label.Contains("lectures non envoyées", StringComparison.Ordinal)), "attente refusée expliquée dans le relevé");
        }
    }

    [Test]
    public static async Task Presence_flushes_completed_batches_before_the_last_host_finishes()
    {
        var computers = Enumerable.Range(0, 65).Select(i => Fixtures.Computer("PC" + i)).ToArray();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var probe = new ScriptedProbe(async (host, token) =>
        {
            if (host == computers[^1].DnsHostName) { entered.TrySetResult(); await release.Task.WaitAsync(token); }
            return true;
        });
        var cache = new FleetCache(Fixtures.Snapshot(computers: computers));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", new BatchClock(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var running = source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(running.IsCompleted, "dernier hôte encore actif");
            // 32 is the flush threshold, not a partition size: concurrent completions can
            // join the same persisted batch. The last host must remain absent either way.
            Check.True(cache.Fleet.Observations.Workstations.Length is >= 32 and <= 64, "un lot au moins durable avant fin physique");
            Check.True(source.CurrentObservations.Workstations.Length is >= 32 and <= 64, "résultats progressivement visibles");
            Check.False(cache.Fleet.Observations.Workstations.Any(o => o.ComputerGuid == computers[^1].ObjectGuid), "aucun résultat anticipé pour le lecteur actif");
            Check.True(cache.FleetWrites is >= 1 and <= 2, "écritures intermédiaires regroupées");
        }
        finally { release.TrySetResult(); await running; }
        Check.Equal(65, cache.Fleet.Observations.Workstations.Length, "dernier petit lot confirmé");
        Check.Equal(65, source.CurrentObservations.Workstations.Length, "tous les résultats confirmés sont publiés");
        Check.True(cache.FleetWrites is >= 2 and <= 3, "lots regroupés et solde, pas une écriture par poste");
    }

    [Test]
    public static async Task A_host_fault_does_not_discard_other_completed_presence_or_probe_values()
    {
        var computers = new[] { Fixtures.Computer("GOOD"), Fixtures.Computer("FAULT"), Fixtures.Computer("AFTER") };
        var cache = new FleetCache(Fixtures.Snapshot(computers: computers));
        var allEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var entered = 0;
        var probe = new ScriptedProbe(async (host, _) =>
        {
            if (Interlocked.Increment(ref entered) == computers.Length) allEntered.TrySetResult();
            await allEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            if (host == computers[1].DnsHostName) throw new IOException("provider failed");
            return true;
        });
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await Check.ThrowsAsync<IOException>(() => source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None), "cause technique conservée");
        Check.Equal(2, cache.Fleet.Observations.Workstations.Length, "voisins réellement achevés enregistrés malgré faute du fournisseur");
        Check.False(cache.Fleet.Observations.Workstations.Any(o => o.ComputerGuid == computers[1].ObjectGuid), "aucun faux résultat pour le poste en faute");
        var probesEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var probeCalls = 0;
        var reader = new AdAccueilReader(source) { ProbeOverride = async (pc, _, _) =>
        {
            if (Interlocked.Increment(ref probeCalls) == 2) probesEntered.TrySetResult();
            await probesEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            if (pc.ObjectGuid == computers[2].ObjectGuid) throw new IOException("probe failed");
            return ImmutableDictionary<string, ProbeReading>.Empty.Add("hw.model", new(MeasureState.Known, Fixtures.Now, ["Model"], null));
        } };
        await Check.ThrowsAsync<IOException>(() => reader.CollectProbesAsync(["hw.model"], Scope, computers.Select(c => c.ObjectGuid).ToArray(), CancellationToken.None), "erreur de sonde conservée");
        Check.True(cache.Fleet.Probes.ByProbe["hw.model"].ContainsKey(computers[0].ObjectGuid), "sonde achevée enregistrée malgré faute du voisin");
    }

    [Test]
    public static async Task A_3500_workstation_presence_campaign_uses_batched_commits()
    {
        var computers = Enumerable.Range(0, 3500).Select(i => Fixtures.Computer("PC" + i)).ToArray();
        var cache = new FleetCache(Fixtures.Snapshot(computers: computers));
        var calls = 0;
        var probe = new ScriptedProbe((_, _) => { Interlocked.Increment(ref calls); return Task.FromResult(true); });
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", new BatchClock(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None);
        Check.Equal(3500, calls, "chaque poste visé une fois, aucun arrêt au dixième");
        Check.Equal(3500, cache.Fleet.Observations.Workstations.Length, "tous les résultats confirmés");
        Check.True(cache.FleetWrites <= 110, "au plus un commit par lot de 32 et solde");
    }

    [Test]
    public static async Task A_failed_batch_writer_stops_new_admissions_and_is_not_retried_for_every_workstation()
    {
        var computers = Enumerable.Range(0, 3500).Select(i => Fixtures.Computer("PC" + i)).ToArray();
        var cache = new FleetCache(Fixtures.Snapshot(computers: computers)) { FailFleet = true };
        var sent = 0;
        var probe = new ScriptedProbe((_, _) => { Interlocked.Increment(ref sent); return Task.FromResult(true); });
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await Check.ThrowsAsync<IOException>(() => source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None), "échec du reçu local remonté");
        Check.Equal(1, cache.FleetWriteAttempts, "aucune boucle de réessais disque pour les 3 500 postes");
        Check.True(sent < 3500, "admission arrêtée dès l’échec de stockage");
        Check.True(source.CurrentObservations.Workstations.IsEmpty, "pas de résultat publié sans reçu local");
    }

    // These count-based batching tests must not become time-based batching tests when a busy CI runner pauses.
    private sealed class BatchClock : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => Fixtures.Now;
        public override TimeZoneInfo LocalTimeZone => TestClock.Paris;
        public override long GetTimestamp() => 0;
    }

    private sealed class ScriptedProbe(Func<string, CancellationToken, Task<bool>> ping) : IWorkstationProbe
    {
        public Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken token) => ping(host, token);
        public Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken token) => throw new InvalidOperationException("Unexpected inventory");
    }

    private sealed class BusyProbe(string refusedHost, string code) : IWorkstationProbe
    {
        public int Sent { get; private set; }
        public Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken)
        {
            if (host == refusedHost) throw new DomeniaOperationException(code, "Budget indisponible ; aucun envoi.");
            Sent++; return Task.FromResult(true);
        }
        public Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) => throw new InvalidOperationException("Aucun inventaire demandé.");
    }

    private sealed class CancellingProbe(CancellationTokenSource stop, string completedHost, string cancellingHost) : IWorkstationProbe
    {
        private readonly TaskCompletionSource firstCompleted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int calls;
        public int Calls => Volatile.Read(ref calls);
        public async Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (host == completedHost)
            { Interlocked.Increment(ref calls); firstCompleted.TrySetResult(); return true; }
            await firstCompleted.Task.WaitAsync(cancellationToken);
            if (host == cancellingHost)
            { Interlocked.Increment(ref calls); stop.Cancel(); cancellationToken.ThrowIfCancellationRequested(); }
            // A later admitted worker is still waiting at the fake transport gate when cancellation arrives.
            // Its native send must never start; the fixture does not rely on thread scheduling or a racy Calls++.
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("Lecture envoyée après annulation.");
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

    internal sealed class FleetCache(DirectorySnapshot snapshot) : IPreparedDirectoryCache, IAccueilCache
    {
        public CachedFleet Fleet { get; set; } = CachedFleet.Empty("memory");
        public bool FailBackup { get; init; }
        public bool FailFleet { get; init; }
        public int DirectoryWrites { get; private set; }
        public int FleetWrites { get; private set; }
        public int FleetWriteAttempts { get; private set; }
        public int BackupCalls { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult<DirectorySnapshot?>(snapshot);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) { DirectoryWrites++; return Task.CompletedTask; }
        public Task<DirectoryBackupReceipt> PrepareAsync(CancellationToken cancellationToken)
        { if (FailBackup) { throw new IOException("backup"); } BackupCalls++; return Task.FromResult(new DirectoryBackupReceipt("memory", "verified", Fixtures.Now)); }
        public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) => Task.FromResult(Fleet);
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken)
        { FleetWriteAttempts++; if (FailFleet) { throw new IOException("commit"); } FleetWrites++; Fleet = Fleet.Merge(patch); return Task.FromResult(Fleet); }
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    }
}
