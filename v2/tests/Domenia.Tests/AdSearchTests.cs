using System.Collections.Immutable;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdSearchTests
{
    [Test]
    public static async Task Search_local_operations_never_connect_without_a_cache()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdSearchReader(source);
        Check.Equal(0, (await reader.SuggestAsync("poste", SearchTypeFilter.All, 8, CancellationToken.None)).Length, "suggestions locales");
        Check.Null(await reader.PreviewAsync(Fixtures.IdOf("absent"), CancellationToken.None), "aperçu absent");
        Check.Equal(0, (await reader.CachedAsync(Query(), CancellationToken.None)).Rows.Length, "cache absent");
        Check.Equal(0, (await reader.LocalRowsAsync([Fixtures.IdOf("absent")], CancellationToken.None)).Length, "sélection absente");
        Check.Equal(0, ldap.Calls, "aucun accès réseau implicite");
    }

    [Test]
    public static async Task Search_pagination_preserves_equal_names_and_the_raw_AD_sort_key()
    {
        var entries = Enumerable.Range(0, 3).Select(i => Entry(i, "Équipe")).ToArray();
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.SortAttribute is not null ? entries.Take(q.SizeLimit).ToArray() : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdSearchReader(source);
        var query = Query() with { Take = 1 };
        var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < 3; i++)
        {
            var page = await reader.FindAsync(query, CancellationToken.None);
            Check.Equal(1, page.Rows.Length, "un objet par page");
            Check.True(known.Add(page.Rows[0].Id), "aucun doublon ni omission de nom identique");
            Check.Equal(i < 2, page.More, "suite prouvée par une sentinelle");
            Check.Equal("p:Équipe", page.LastKey, "clé LDAP non repliée");
            query = query with { After = page.LastKey, Known = known };
        }
        Check.True(ldap.Searches.Where(q => q.SortAttribute is not null).All(q => q.SortAttribute == "name" && q.PageSize == 500), "tri serveur exigé");
        Check.True(ldap.Searches.Any(q => q.Filter.Contains("(name>=Équipe)", StringComparison.Ordinal)), "reprise sur le nom AD exact");
        Check.Equal(3, (await reader.LocalRowsAsync(known.Select(Guid.Parse).ToArray(), CancellationToken.None)).Length, "objets conservés localement");
    }

    [Test]
    public static async Task Exact_identity_precedes_prefix_and_ANR_without_duplicate_rows()
    {
        var exact = Entry(0, "alice");
        var prefix = Entry(1, "alice2");
        var anr = Entry(2, "Martine alice");
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.SortAttribute is null ? [] : q.Filter.Contains("(anr=", StringComparison.Ordinal) ? [anr]
                : q.Filter.Contains("(name=alice)", StringComparison.Ordinal) ? [exact] : [exact, prefix],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var page = await new AdSearchReader(source).FindAsync(Query() with { Kind = SearchListKind.Search, Plan = SearchText.Plan("alice", SearchTypeFilter.Computers, SearchMatchMode.Prefix) }, CancellationToken.None);
        Check.True(page.Rows.Select(r => r.Name).SequenceEqual(new[] { "alice", "alice2", "Martine alice" }), "identité exacte puis préfixe puis ANR");
        Check.False(page.More, "toutes les passes épuisées");
    }

    [Test]
    public static async Task A_missing_identity_on_revalidation_is_not_returned_from_old_cache()
    {
        var computer = Fixtures.Computer("OLD");
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        await source.DomainAsync(CancellationToken.None);
        await source.RememberObjectsAsync(Fixtures.Snapshot(computers: [computer]) with { Complete = false }, source.Epoch, CancellationToken.None);
        var reader = new AdSearchReader(source);
        Check.Equal(1, (await reader.LocalRowsAsync([computer.ObjectGuid], CancellationToken.None)).Length, "ancienne fiche conservée");
        Check.Equal(0, (await reader.RereadAsync([computer.ObjectGuid], CancellationToken.None)).Length, "absence réelle non masquée par le cache");
    }

    [Test]
    public static async Task An_uncommitted_search_is_never_published_as_a_cached_success()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.SortAttribute is not null ? [Entry(0, "PC")] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: new RefusedCache());
        await Check.ThrowsAsync<IOException>(() => new AdSearchReader(source).FindAsync(Query(), CancellationToken.None), "stockage refusé");
        Check.True(source.CurrentDirectory is null || source.CurrentDirectory.ObjectCount == 0, "pas de résultat seulement en mémoire");
    }

    [Test]
    public static void Search_surveys_are_limited_and_never_read_processes_or_MSI()
    {
        Check.Equal(TimeSpan.FromSeconds(15), WmiWorkstationReader.Budget(WorkstationReading.Survey), "analyse bornée");
        Check.Equal(TimeSpan.FromSeconds(30), WmiWorkstationReader.Budget(WorkstationReading.SurveyComplete), "relevé complet borné");
        var categories = WmiWorkstationReader.Categories(WorkstationReading.SurveyComplete);
        Check.True(categories.Contains(InventoryCategories.Tpm) && categories.Contains(InventoryCategories.Hotfixes), "compléments demandés");
        Check.False(categories.Contains(InventoryCategories.Processes) || categories.Contains(InventoryCategories.Software), "pas de processus ni MSI");
    }

    [Test]
    public static async Task Partial_object_cache_preserves_the_census_scope_and_newer_values()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("search.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db);
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", false);
        var old = Fixtures.Computer("PC");
        var complete = Fixtures.Snapshot(computers: [old]) with { Coverage = scope };
        await cache.SaveAsync(complete, scope, "dc", CancellationToken.None);
        var newer = complete with { ReadAt = complete.ReadAt.AddMinutes(1), Complete = false, Computers = [old with { Description = "nouveau" }] };
        await cache.SaveObjectsAsync(newer, "dc", CancellationToken.None);
        await cache.SaveObjectsAsync(complete with { Complete = false }, "dc", CancellationToken.None);
        var local = (await cache.ReadKnownAsync(CancellationToken.None))!;
        Check.Equal(scope, local.Coverage, "le point de contrôle du census n’est pas remplacé par la racine");
        Check.Equal("nouveau", local.Computers.Single().Description, "un résultat tardif n’efface pas la valeur plus récente");
        Check.False(local.Complete, "union conservatrice annoncée partielle");
        Check.Equal(newer.ReadAt, new SearchRowFactory(local, [], null, Fixtures.Now).Computer(local.Computers.Single()).ReadAt, "date propre à l’objet conservée");
    }

    [Test]
    public static void Legacy_search_import_preserves_depth_type_and_unicode_and_rejects_foreign_domains()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("Domenia.settings.json");
        File.WriteAllText(path, """
            { "SavedSearches": [
              { "SearchMode": "OU", "DN": "OU=Postes,DC=test,DC=local", "Name": "Équipe", "Subtree": false, "Type": "Machines", "Query": "PC" },
              { "DN": "OU=Postes,DC=elsewhere,DC=local" }
            ] }
            """);
        var saved = LegacySearchFile.Read([path], Fixtures.Root, CancellationToken.None).Single();
        Check.Equal("Équipe", saved.Name, "nom préservé");
        Check.False(saved.Subtree, "profondeur directe préservée");
        Check.Equal(SearchTypeFilter.Computers, saved.Type, "type historique");
        Check.Equal("PC", saved.Query, "texte historique");
    }

    [Test]
    public static async Task Survey_projection_uses_the_actual_system_drive_and_keeps_dated_IPv4_addresses()
    {
        var reading = await InventoryAsync();
        var id = Fixtures.IdOf("PC");
        var patch = AdSearchReader.MapInventory(id, reading);
        var measure = patch.Observations.Workstations.Single().Inventory;
        Check.Equal<long?>(2048, measure.SystemDiskSizeBytes, "D: est le disque système, pas C:");
        Check.Equal("PC", reading.ReportedName, "identité retournée par CIM");
        Check.Equal<int?>(24, reading.Network.Single().PrefixLength, "masque IPv4 pointé converti");
        Check.True(reading.Network.Single().Ipv4.SequenceEqual(new[] { "10.1.2.3" }), "IPv6 exclue des adresses IPv4");
        Check.Equal("10.1.2.3", patch.Addresses[id].Single().Ip, "adresse observée");
        Check.Equal(Fixtures.Now, patch.Addresses[id].Single().ObservedAt, "date de l’observation");
        Check.Null(WmiWorkstationReader.Ipv4Prefix("255.0.255.0"), "masque discontinu refusé");
    }

    [Test]
    public static async Task Survey_addresses_and_inventory_round_trip_without_overwriting_newer_observations()
    {
        using var folder = new TemporaryFolder();
        var db = new DomeniaDatabase(folder.File("readings.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db);
        var pc = Fixtures.Computer("PC");
        await cache.SaveAsync(Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "dc", CancellationToken.None);
        var inventory = await InventoryAsync();
        await cache.SaveFleetAsync(AdSearchReader.MapInventory(pc.ObjectGuid, inventory), CancellationToken.None);
        var older = inventory with { CollectedAt = Fixtures.Now.AddHours(-1), System = inventory.System! with { Model = "ancien" } };
        await cache.SaveFleetAsync(AdSearchReader.MapInventory(pc.ObjectGuid, older), CancellationToken.None);
        var saved = await cache.ReadFleetAsync(CancellationToken.None);
        Check.Equal(Fixtures.Now, saved.Inventories[pc.ObjectGuid].CollectedAt, "pas de régression de l’inventaire");
        Check.Equal(Fixtures.Now, saved.Addresses[pc.ObjectGuid].Single().ObservedAt, "pas de régression des adresses");
        Check.Equal("PC", saved.Inventories[pc.ObjectGuid].ReportedName, "identité conservée");
    }

    [Test]
    public static async Task A_CIM_identity_mismatch_preserves_the_echo_but_publishes_no_inventory()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        await source.DomainAsync(CancellationToken.None);
        var pc = Fixtures.Computer("PC");
        await source.RememberObjectsAsync(Fixtures.Snapshot(computers: [pc]) with { Complete = false }, source.Epoch, CancellationToken.None);
        var wrong = (await InventoryAsync()) with { ReportedName = "ANOTHER" };
        var reader = new AdSearchReader(source)
        {
            EchoOverride = (_, _) => Task.FromResult(new PresenceMeasure(MeasureState.Known, true, Fixtures.Now, Fixtures.Now)),
            InventoryOverride = (_, _) => Task.FromResult(wrong),
        };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProbeAsync(pc.ObjectGuid, SurveyMode.Complete, 1, TimeSpan.Zero, CancellationToken.None), "identité incohérente");
        Check.True(source.CurrentObservations.Workstations.Single().Presence.Answered == true, "ping terminé conservé");
        Check.False(source.FleetDetails.Inventories.ContainsKey(pc.ObjectGuid), "aucune donnée d’une autre machine");
    }

    private static Task<InventorySnapshot> InventoryAsync()
    {
        static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
        var clock = TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new CimSession(host, budget, clock, cancellationToken: token)
            {
                RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) => query.Contains("FROM Win32_OperatingSystem", StringComparison.Ordinal)
                    ? [Row(("Caption", "Windows"), ("BuildNumber", "26100"), ("SystemDrive", "D:"))]
                    : query.Contains("FROM Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC"), ("Model", "modèle"))]
                    : query.Contains("FROM Win32_LogicalDisk", StringComparison.Ordinal) ? [Row(("DeviceID", "C:"), ("Size", 100L), ("FreeSpace", 5L)), Row(("DeviceID", "D:"), ("Size", 2048L), ("FreeSpace", 1024L))]
                    : query.Contains("FROM Win32_NetworkAdapterConfiguration", StringComparison.Ordinal) ? [Row(("MACAddress", "00-11-22-33-44-55"), ("IPAddress", new[] { "fe80::1", "10.1.2.3" }), ("IPSubnet", new[] { "64", "255.255.255.0" }))]
                    : query.Contains("FROM Win32_NetworkAdapter", StringComparison.Ordinal) ? [Row(("Name", "Ethernet"), ("MACAddress", "00-11-22-33-44-55"))] : [],
            },
        };
        return reader.ReadAsync("PC", WorkstationReading.Survey, null, CancellationToken.None);
    }

    private static SearchQuery Query() => new(SearchListKind.Browse, SearchText.BrowsePlan(SearchTypeFilter.Computers), SearchTypeFilter.Computers,
        Fixtures.Postes, true, null, null, new HashSet<string>(), 10);

    private static AdEntry Entry(int n, string name)
    {
        var sid = new SecurityIdentifier("S-1-5-21-1-2-3-99");
        var bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        return new("CN=" + name + ",OU=Branch" + n.ToString(System.Globalization.CultureInfo.InvariantCulture) + "," + Fixtures.Postes,
            new Dictionary<string, IReadOnlyList<object>>
            {
                ["objectGUID"] = [Fixtures.IdOf("search-" + n.ToString(System.Globalization.CultureInfo.InvariantCulture)).ToByteArray()],
                ["objectSid"] = [bytes], ["objectClass"] = ["top", "user", "computer"], ["name"] = [name], ["sAMAccountName"] = [name + "$"],
                ["dNSHostName"] = ["pc.test.local"], ["userAccountControl"] = ["4096"],
            });
    }

    private sealed class RefusedCache : IObjectDirectoryCache
    {
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult<DirectorySnapshot?>(null);
        public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken cancellationToken) => ReadAsync(cancellationToken);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) => throw new IOException("refus");
        public Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken cancellationToken) => throw new IOException("refus");
    }
}
