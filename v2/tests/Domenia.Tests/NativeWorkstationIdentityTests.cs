using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class NativeWorkstationIdentityTests
{
    [Test]
    public static void Native_identity_keeps_all_names_distinct_and_never_accepts_a_prefix_without_DNS()
    {
        const string longName = "ABCDEFGHIJKLMNO-extra";
        var pc = Fixtures.Computer("PC1") with { Name = "CN différent", SamAccountName = "ABCDEFGHIJKLMNO$", DnsHostName = longName + ".test.local" };
        var valid = new NativeWorkstationIdentity(pc.DnsHostName!, "ABCDEFGHIJKLMNO", longName, "test.local");
        Check.Equal(NativeIdentityState.Confirmed, valid.State, "DNS natif et cible concordent avec le nom NetBIOS à 15 caractères");
        Check.True(WorkstationIdentity.Matches(pc, valid.Name, valid), "SAM AD court, DNS complet concordant");
        Check.False(WorkstationIdentity.Matches(pc, "OTHER", valid), "le nom brut ne peut contredire la preuve jointe");
        Check.False(WorkstationIdentity.Matches(pc, valid.Name), "ancien Name seul ne confirme aucune lecture fraîche");
        Check.Equal(NativeIdentityState.Unconfirmed, (valid with { DnsHostName = null }).State, "DNS absent non inventé depuis AD");
        Check.Equal(NativeIdentityState.Inconsistent, (valid with { RequestedHost = "ABCDEFGHIJKLMNO-other.test.local" }).State, "même préfixe n’est pas même poste");
        Check.False((valid with { DnsHostName = longName + ".test.local", Domain = "foreign.local" }).Matches(pc), "domaine d’appartenance différent du DN AD, même avec DNS concordant");
        Check.False((valid with { Domain = "foreign.local", RequestedHost = longName + ".foreign.local" }).Matches(pc), "cible et natif cohérents mais domaine AD différent");
        Check.Equal("Incohérente", (valid with { Name = "OTHER" }).Label, "état affichable distinct");
        Check.True(WorkstationIdentity.MatchesHistorical(Fixtures.Computer("PC1"), "PC1"), "ancien relevé reste consultable sous sa provenance GUID");
    }

    [Test]
    public static void Disjoint_DNS_and_AD_namespaces_are_qualified_without_inventing_a_native_FQDN()
    {
        var pc = Fixtures.Computer("PC1") with { DnsHostName = "PC1.corp.example", DistinguishedName = "CN=PC1,OU=Postes,DC=ad,DC=example" };
        var identity = new NativeWorkstationIdentity("PC1.corp.example", "PC1", "PC1", "ad.example");
        Check.Equal(NativeIdentityState.Confirmed, identity.State, "preuves natives compatibles avec namespace disjoint");
        Check.Equal<string?>(null, identity.FullyQualifiedDns, "un label court et un domaine AD ne prouvent pas le suffixe DNS primaire");
        Check.True(identity.Matches(pc), "preuves natives composées avec DNS et appartenance AD");
        Check.True((identity with { DnsHostName = "PC1.corp.example" }).Matches(pc), "DNS natif réellement complet comparé sans recomposition");
        Check.False((identity with { Domain = "foreign.example" }).Matches(pc), "mauvais domaine d’appartenance refusé");
        Check.False((identity with { RequestedHost = "PC1.foreign.example" }).Matches(pc), "même nom court mais mauvaise cible DNS refusée");
        Check.False((identity with { DnsHostName = "PC1.foreign.example" }).Matches(pc), "DNS natif complet contradictoire refusé");
        var registry = identity with { Domain = "corp.example", DomainKind = NativeIdentityDomainKind.PrimaryDnsSuffix };
        Check.True(registry.Matches(pc), "Tcpip.Domain est explicitement le suffixe DNS, pas une appartenance AD inventée");
        Check.Equal("PC1.corp.example", registry.FullyQualifiedDns!, "suffixe effectivement lu dans le registre");
        Check.False((registry with { Domain = "foreign.example" }).Matches(pc), "suffixe registre étranger refusé");
    }

    [Test]
    public static void Actual_CIM_session_blocks_dependent_queries_and_registry_when_identity_is_missing_or_inconsistent()
    {
        foreach (var dns in new string?[] { null, "OTHER", "PC1" })
        {
            var calls = 0; var registry = 0;
            using var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(10), TestClock.Fixed())
            {
                ReadOverride = (_, _, _) => { calls++; return [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1", ["DNSHostName"] = dns, ["Domain"] = "test.local" })]; },
                RegistryOverride = (_, _) => { registry++; return new(0, 1); },
            };
            var first = session.Read("identity", @"root\cimv2", "SELECT Name, DNSHostName, Domain FROM Win32_ComputerSystem", 1);
            Check.NotNull(first.HostIdentity, "même les valeurs manquantes ont un verdict explicite");
            if (dns == "PC1")
            { Check.Equal(SourceStatus.Ok, first.Status, "preuve complète"); Check.True(WorkstationIdentity.Matches(Fixtures.Computer("PC1"), "PC1", first.HostIdentity), "liaison réelle AD"); }
            else
            {
                Check.Equal(SourceStatus.Unavailable, first.Status, "aucun succès fabriqué"); Check.Equal(0, first.Items, "pas de lignes exploitables sans identité");
                session.Read("os", @"root\cimv2", "SELECT Caption FROM Win32_OperatingSystem", 1);
                session.ReadRegistry(new(InventoryRegistry.Machine, InventoryRegistry.WindowsVersion, "UBR", RegistryMethod.Dword), TimeSpan.FromSeconds(1));
                Check.Equal(1, calls, "pas de seconde requête"); Check.Equal(0, registry, "pas de registre après refus d’identité");
            }
        }
    }

    [Test]
    public static void Old_WinRM_identity_report_is_unconfirmed_and_does_not_reconstruct_a_machine_from_the_requested_host()
    {
        var old = JsonSerializer.Serialize(new { Format = "Domenia.UserIdentityRead/1", Computer = "PC1", Code = 0, Truncated = false, Rows = Array.Empty<object>() });
        var missing = CimSession.ParseUserIdentity(old, "PC1.test.local", Fixtures.Now);
        Check.Equal(SourceStatus.Unavailable, missing.Access.Status, "ancien rapport non promu"); Check.Equal(0, missing.Candidates.Length, "aucun utilisateur associé");
        var current = JsonSerializer.Serialize(new { Format = "Domenia.UserIdentityRead/1", Computer = "PC1", DNSHostName = "PC1", Domain = "test.local", Code = 0, Truncated = false, Rows = Array.Empty<object>() });
        var valid = CimSession.ParseUserIdentity(current, "PC1.test.local", Fixtures.Now);
        Check.Equal(SourceStatus.Empty, valid.Access.Status, "console vide effectivement lue");
        Check.True(WorkstationIdentity.Matches(Fixtures.Computer("PC1"), valid.ReportedName, valid.HostIdentity), "trois valeurs natives conservées");
    }
}
