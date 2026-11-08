using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class AdPosteLogonTests
{
    private static AdBoundaryTests.RecordingAdConnection Directory(DirectoryComputer pc, int count = 1) => new()
    {
        ConfigurationContext = "CN=Configuration," + Fixtures.Root,
        SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)]
            : q.Filter == "(objectClass=server)" ? Enumerable.Range(1, count).Select(n => new AdEntry("CN=DC" + n + ",CN=Servers,CN=Paris,CN=Sites,CN=Configuration," + Fixtures.Root,
                new Dictionary<string, IReadOnlyList<object>> { ["dNSHostName"] = ["DC" + n + ".test.local"], ["serverReference"] = ["CN=DC" + n + ",OU=Domain Controllers," + Fixtures.Root] })).ToArray() : [],
    };

    private static AdEntry Logon(DirectoryComputer pc, long? value, Guid? id = null) => new(pc.DistinguishedName,
        new Dictionary<string, IReadOnlyList<object>> { ["objectGUID"] = [(id ?? pc.ObjectGuid).ToByteArray()], ["objectClass"] = ["computer"], ["lastLogon"] = value is { } n ? [n] : [] });

    [Test]
    public static async Task Computer_logon_reads_are_AD_only_and_distinguish_zero_missing_foreign_and_future_values()
    {
        var pc = Fixtures.Computer("PC1") with { DnsHostName = null };
        foreach (var mode in new[] { "read", "zero", "missing", "foreign", "future" })
        {
            using var ldap = Directory(pc);
            var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
            long? value = mode switch { "zero" => 0, "missing" => null, "future" => Fixtures.Now.AddDays(1).ToFileTime(), _ => Fixtures.Now.AddDays(-1).ToFileTime() };
            var reader = new AdPosteReader(source)
            {
                InventoryReaderOverride = _ => throw new InvalidOperationException("Aucun contact machine"),
                ControllerConnection = _ => new AdBoundaryTests.RecordingAdConnection { SearchAnswer = query =>
                {
                    Check.Equal(AdObjectAccess.GuidFilter(pc.ObjectGuid), query.Filter, "GUID exact sur chaque contrôleur");
                    Check.Equal(TimeSpan.FromSeconds(5), query.Budget, "budget de chaque contrôleur");
                    return [Logon(pc, value, mode == "foreign" ? Guid.NewGuid() : null)];
                } },
            };
            var result = await reader.LogonByControllerAsync(pc.DistinguishedName, CancellationToken.None);
            Check.Equal(mode is "read" or "zero" ? FactState.Observed : FactState.Unknown, result.Controllers.Single().State, "statut de " + mode);
            Check.Equal(mode == "read", result.Latest is not null, "date qualifiée uniquement pour le même compte");
            Check.Equal(0, cache.FleetWrites, "historique AD ne fabrique pas de présence machine");
        }
    }

    [Test]
    public static async Task Computer_logon_scan_caps_controllers_and_keeps_partial_coverage_visible()
    {
        var pc = Fixtures.Computer("PC1"); using var ldap = Directory(pc, 60);
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var contacts = 0;
        var reader = new AdPosteReader(source) { ControllerConnection = _ =>
        {
            Interlocked.Increment(ref contacts);
            return new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [Logon(pc, 0)] };
        } };
        var result = await reader.LogonByControllerAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(50, contacts, "volume de contacts borné"); Check.Equal(50, result.Controllers.Length, "cinquante lignes");
        Check.True(result.Coverage.Contains("sur 60", StringComparison.Ordinal), "dénominateur complet conservé");
        Check.True(result.Text.Contains("non lu", StringComparison.Ordinal), "plafond ne prouve pas l’absence sur le domaine");
        Check.Equal(FactState.Estimated, result.Facts[1].State, "couverture partielle explicitée");
    }

    [Test]
    public static async Task Authentication_rejection_stops_pending_controller_contacts_without_trying_other_accounts()
    {
        var pc = Fixtures.Computer("PC1"); using var ldap = Directory(pc, 10);
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var contacts = 0;
        var reader = new AdPosteReader(source) { ControllerConnection = _ =>
        {
            Interlocked.Increment(ref contacts);
            throw new DomeniaOperationException(AdErrors.Credentials, "Refus simulé sans secret");
        } };
        var result = await reader.LogonByControllerAsync(pc.DistinguishedName, CancellationToken.None);
        Check.True(contacts is >= 1 and <= 4, "aucun nouveau groupe après le rejet ; au plus les quatre contacts en vol");
        Check.True(result.Controllers.Any(c => c.State == FactState.Refused), "rejet présent");
        Check.True(result.Controllers.Any(c => c.State == FactState.Unknown), "contrôleurs non essayés distincts du refus");
        Check.Null(result.Latest, "aucune dernière connexion inventée");
    }

    [Test]
    public static async Task Stopping_controller_scan_preserves_the_date_already_received()
    {
        var pc = Fixtures.Computer("PC1"); using var ldap = Directory(pc, 10);
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        using var stop = new CancellationTokenSource();
        var reader = new AdPosteReader(source) { ControllerConnection = _ => new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ =>
        {
            stop.Cancel(); return [Logon(pc, Fixtures.Now.AddHours(-1).ToFileTime())];
        } } };
        var result = await reader.LogonByControllerAsync(pc.DistinguishedName, stop.Token);
        Check.Equal(Fixtures.Now.AddHours(-1), result.Latest!.Value, "lecture terminée conservée");
        Check.True(result.Controllers.Any(c => c.State == FactState.Unknown), "suite interrompue inconnue");
    }
}
