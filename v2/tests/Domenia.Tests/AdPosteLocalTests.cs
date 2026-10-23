using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdPosteLocalTests
{
    private static ConsentState NoConsent => new(new(false, null, 0, "Non accordée", null), new(false, null, 0, "Non accordée", null));
    private sealed class Cache(DirectorySnapshot directory, CachedFleet fleet) : IDirectoryCache, IAccueilCache
    {
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult<DirectorySnapshot?>(directory);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) => throw new InvalidOperationException("Aucune écriture locale attendue");
        public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) => Task.FromResult(fleet);
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken) => throw new InvalidOperationException("Aucune écriture locale attendue");
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    }

    private static async Task<InventorySnapshot> Inventory(string host)
    {
        var clock = TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock) { SessionFactory = (h, budget, token) => new(h, budget, clock, cancellationToken: token)
        {
            ReadOverride = (_, query, _) => query.Contains("FROM Win32_ComputerSystem", StringComparison.Ordinal)
                ? [new WmiInstance(new Dictionary<string, object?> { ["Name"] = host })] : [],
            RegistryOverride = (_, _) => new(2, null),
        } };
        return await reader.ReadAsync(host, WorkstationReading.Quick, null, CancellationToken.None);
    }

    [Test]
    public static void Native_machine_identity_uses_SAM_and_DNS_and_survives_a_CN_only_rename()
    {
        var pc = Fixtures.Computer("PC1") with { Name = "Ordinateur du bureau", DistinguishedName = "CN=Ordinateur du bureau," + Fixtures.Postes };
        Check.True(WorkstationIdentity.Matches(pc, "pc1"), "CN d’affichage indépendant du nom Windows");
        Check.False(WorkstationIdentity.Matches(pc, pc.Name), "CN seul n’est pas une preuve native");
        Check.False(WorkstationIdentity.Matches(pc with { DnsHostName = "OTHER.test.local" }, "PC1"), "DNS et compte incohérents refusés");
        Check.False(WorkstationIdentity.Matches(pc with { SamAccountName = "PC1" }, "PC1"), "compte machine requis");
        Check.False(WorkstationIdentity.Matches(pc with { ObjectGuid = Guid.Empty }, "PC1"), "GUID requis");
    }

    [Test]
    public static async Task Workstation_local_console_and_lists_never_contact_LDAP_or_invent_inventory_site_or_LAPS_absence()
    {
        var pc = Fixtures.Computer("PC1", "OU=Paris,OU=Postes," + Fixtures.Root);
        var user = Fixtures.User("elodie");
        var snapshot = Fixtures.Snapshot(users: [user], computers: [pc]) with { Complete = false };
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "TEST\\operator", TestClock.Fixed(), connection: ldap, localStore: new Cache(snapshot, CachedFleet.Empty("test")));
        var reader = new AdPosteReader(source);
        var console = await reader.OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, NoConsent, CancellationToken.None);
        Check.Null(console.Inventory, "aucun inventaire fabriqué depuis la fiche AD");
        Check.Null(console.Computer.Site, "OU Paris ne prouve pas le site AD Paris");
        Check.Equal("LAPS non déterminé", console.Computer.LapsKind, "absence de métadonnées distincte de l’absence de LAPS");
        Check.Null(console.Association.User, "aucun utilisateur inventé");
        Check.Null(await reader.CachedInventoryAsync(pc.DistinguishedName, PosteHealthPolicy.Default, CancellationToken.None), "cache absent");
        var software = await reader.CachedSoftwareAsync(pc.DistinguishedName, CancellationToken.None);
        Check.False(software.Complete, "zéro ligne non assimilé à un relevé complet");
        Check.Equal(SourceStatus.Skipped, software.Access[0].Status, "portée non lue explicite");
        var list = await reader.ListAsync(null, "PC1", 20, PosteHealthPolicy.Default, CancellationToken.None);
        Check.Equal(1, list.Total, "liste du cache"); Check.True(list.Summary.Contains("partielle", StringComparison.Ordinal), "couverture partielle annoncée");
        Check.Equal(0, ldap.Calls, "navigation sans LDAP");
    }

    [Test]
    public static async Task Native_inventory_cache_keeps_the_same_GUID_after_CN_rename_but_rejects_a_foreign_reported_name()
    {
        var pc = Fixtures.Computer("PC1") with { Name = "Nouveau libellé", DistinguishedName = "CN=Nouveau libellé," + Fixtures.Postes };
        var inv = await Inventory("PC1");
        foreach (var good in new[] { true, false })
        {
            var fleet = CachedFleet.Empty("test") with { Inventories = ImmutableDictionary<Guid, InventorySnapshot>.Empty.Add(pc.ObjectGuid, inv with { ReportedName = good ? "PC1" : "OTHER" }) };
            using var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new AdDirectorySource("test.local", () => "TEST\\operator", TestClock.Fixed(), connection: ldap, localStore: new Cache(Fixtures.Snapshot(computers: [pc]), fleet));
            var reader = new AdPosteReader(source);
            var console = await reader.OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, NoConsent, CancellationToken.None);
            Check.Equal(good, console.Inventory is not null, "cache arbitré sur l’identité Windows, pas sur le CN");
            Check.Equal(!good, console.Notes.Any(n => n.Label == "Inventaire écarté"), "rejet visible");
            Check.Equal(0, ldap.Calls, "arbitrage local");
        }
    }

    [Test]
    public static async Task Session_login_lookup_refuses_foreign_authorities_and_raw_console_names_do_not_gain_a_GUID()
    {
        var pc = Fixtures.Computer("PC1"); var user = Fixtures.User("elodie");
        var fleet = CachedFleet.Empty("test") with { Facts = AccueilFacts.Empty("test") with
        { Machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(pc.ObjectGuid, new(@"OTHER\elodie", Fixtures.Now, null, null, MeasureState.Known, Fixtures.Now, null)) } };
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "TEST\\operator", TestClock.Fixed(), connection: ldap, localStore: new Cache(Fixtures.Snapshot(users: [user], computers: [pc]), fleet));
        var reader = new AdPosteReader(source);
        Check.Null(await reader.FindAccountAsync(@"OTHER\elodie", CancellationToken.None), "compte étranger non rabattu sur le SAM local");
        Check.Equal(user.ObjectGuid, (await reader.FindAccountAsync(Fixtures.Domain.NetbiosName + @"\elodie", CancellationToken.None))!.Guid!.Value, "autorité connue exacte");
        var console = await reader.OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, NoConsent, CancellationToken.None);
        Check.Null(console.Association.User!.Guid, "observation non vérifiée sans GUID ajouté");
        Check.Null(console.Association.User.Dn, "pas de lien vers l’homonyme courant");
        Check.False(console.Association.IdentityProven, "identité non prouvée dite");
        Check.Equal(0, ldap.Calls, "lecture locale seulement");
    }
}
