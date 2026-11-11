using System.Runtime.InteropServices;
using System.Xml;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CimInventoryTests
{
    private const string Query = "SELECT Name FROM Win32_ComputerSystem";
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));

    [Test]
    public static void Cim_rejects_MSI_secrets_domain_scans_and_malformed_targets_before_transport()
    {
        var calls = 0;
        var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(10), TestClock.Fixed())
        {
            RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, _, _) => { calls++; return []; },
        };
        foreach (var query in new[] { "SELECTX Name FROM Win32_ComputerSystem", "SELECT Name FROM Win32_Product", "SELECT Password FROM Win32_ComputerSystem", "SELECT Name FROM Win32_UserAccount", "SELECT Name FROM __Namespace", Query + "; DELETE" })
        {
            Check.Equal(SourceStatus.Error, session.Read("Système", @"root\cimv2", query, 1).Status, query);
        }
        Check.Equal(SourceStatus.Error, session.Read("Système", @"root\..\cimv2", Query, 1).Status, "espace de noms invalide");
        Check.Equal(0, calls, "aucun appel interdit");
        Check.True(CimQuery.IsReadOnlySelect("SELECT Name FROM Win32_UserAccount WHERE LocalAccount=True"), "comptes locaux bornés");
        foreach (var host in new[] { "..", "PC..local", "-PC", "PC-", "PC/other", "PC\\root", "PC:445" })
        {
            Check.False(CimQuery.IsHostName(host), host);
        }
        Check.True(CimQuery.IsHostName("PC-1.test.local"), "nom DNS valide");
    }

    [Test]
    public static void Cim_exact_limit_is_complete_and_extra_instance_marks_truncation()
    {
        var row = Row(("Name", "PC1"));
        var session = new CimSession("PC1", TimeSpan.FromSeconds(10), TestClock.Fixed()) { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, _, _) => [row] };
        Check.Equal(SourceStatus.Ok, session.Read("Système", @"root\cimv2", Query, 1).Status, "une instance demandée et reçue");
        session = new CimSession("PC1", TimeSpan.FromSeconds(10), TestClock.Fixed()) { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, _, _) => [row, row] };
        var partial = session.Read("Système", @"root\cimv2", Query, 1);
        Check.Equal(SourceStatus.Partial, partial.Status, "instance sentinelle");
        Check.Equal(1, partial.Items, "sentinelle non conservée");
    }

    [Test]
    public static void Cim_keeps_rows_observed_before_a_provider_timeout()
    {
        static IEnumerable<WmiInstance> Failing()
        {
            yield return Row(("Name", "PC1"));
            throw new TimeoutException();
        }
        var session = new CimSession("PC1", TimeSpan.FromSeconds(10), TestClock.Fixed()) { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, _, _) => Failing() };
        var result = session.Read("Système", @"root\cimv2", Query, 10);
        Check.Equal(SourceStatus.Partial, result.Status, "erreur après une observation");
        Check.Equal("PC1", result.Instances.Single().Text("Name"), "donnée conservée");
    }

    [Test]
    public static void Cim_uses_the_remaining_monotonic_budget_and_stops_after_cancellation()
    {
        var clock = new MonotonicClock();
        using var stop = new CancellationTokenSource();
        var calls = 0;
        var timeout = TimeSpan.Zero;
        var session = new CimSession("PC1", TimeSpan.FromSeconds(5), clock, cancellationToken: stop.Token)
        {
            RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, _, allowed) => { calls++; timeout = allowed; return []; },
        };
        clock.Advance(TimeSpan.FromSeconds(4));
        session.Read("Système", @"root\cimv2", Query, 10, TimeSpan.FromSeconds(90));
        Check.Equal(TimeSpan.FromSeconds(1), timeout, "budget restant seulement");
        stop.Cancel();
        Check.Equal(SourceStatus.Interrupted, session.Read("Système", @"root\cimv2", Query, 10).Status, "arrêt");
        clock.Advance(TimeSpan.FromSeconds(2));
        Check.True(session.OutOfBudget, "budget expiré");
        Check.Equal(1, calls, "aucun nouvel appel après arrêt");
    }

    [Test]
    public static void Cim_refusal_and_network_failure_are_distinct()
    {
        Check.Equal<SourceStatus?>(SourceStatus.Refused, CimSession.Classify(new COMException("hidden", unchecked((int)0x80070005))), "accès refusé");
        Check.Equal<SourceStatus?>(SourceStatus.Refused, CimSession.Classify(new COMException("hidden", unchecked((int)0x8007052E))), "authentification refusée");
        Check.Equal<SourceStatus?>(SourceStatus.Unreachable, CimSession.Classify(new COMException("hidden", unchecked((int)0x800706BA))), "RPC indisponible");
        Check.Equal<SourceStatus?>(SourceStatus.Unreachable, CimSession.Classify(new COMException("hidden", unchecked((int)0x80338012))), "WinRM sans écouteur");
        Check.Equal<SourceStatus?>(SourceStatus.Unreachable, CimSession.Classify(new COMException("hidden", unchecked((int)0x80338126))), "WinRM ne peut pas joindre le poste");
        Check.Equal(" 0x80070057", CimSession.Code(new COMException("hidden", unchecked((int)0x80070057))), "code COM gardé sans texte");
        Check.Equal("", CimSession.Code(new InvalidOperationException("hidden")), "aucun code inventé");
        Check.Equal("poste injoignable par CIM (0x80338012)", CimSession.Detail(new COMException("hidden", unchecked((int)0x80338012)), SourceStatus.Unreachable), "code WinRM affiché");
        Check.Equal("poste injoignable par CIM (0x800706BA)", CimSession.Detail(new COMException("hidden", unchecked((int)0x800706BA)), SourceStatus.Unreachable), "code RPC affiché");
        Check.Equal("poste injoignable par CIM", CimSession.Detail(new InvalidOperationException("hidden"), SourceStatus.Unreachable), "aucun code inventé pour un poste injoignable");
        Check.Equal<SourceStatus?>(SourceStatus.Error, CimSession.Classify(new COMException("hidden", unchecked((int)0x80004005))), "autre erreur");
        Check.Null(CimSession.Classify(new InvalidOperationException()), "erreur de programmation propagée");
    }

    [Test]
    public static void WinRm_com_failure_keeps_its_code_whatever_managed_type_carries_it()
    {
        // Bench of 11/11/2026: an E_INVALIDARG of WSMan.Automation surfaced as an ArgumentException and stopped the reader.
        Check.Equal<int?>(unchecked((int)0x80070057), WsmanReadChannel.ComFailure(new ArgumentException("hidden"))?.HResult, "E_INVALIDARG qualifié");
        var denied = WsmanReadChannel.ComFailure(new UnauthorizedAccessException("hidden"));
        Check.Equal<int?>(unchecked((int)0x80070005), denied?.HResult, "E_ACCESSDENIED qualifié");
        Check.Equal<SourceStatus?>(SourceStatus.Refused, CimSession.Classify(denied!), "un accès refusé reste un refus");
        var native = new COMException("hidden", unchecked((int)0x80338012));
        Check.True(ReferenceEquals(native, WsmanReadChannel.ComFailure(native)), "COMException conservée telle quelle");
        Check.Null(WsmanReadChannel.ComFailure(new TimeoutException()), "un délai n’est pas un échec COM");
        Check.Null(WsmanReadChannel.ComFailure(new OperationCanceledException()), "un arrêt n’est pas un échec COM");
        Check.Null(WsmanReadChannel.ComFailure(new XmlException("hidden")), "une réponse illisible garde son propre traitement");
    }

    [Test]
    public static async Task Inventory_projects_memory_and_chassis_without_inventing_disk_counters()
    {
        var clock = TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new CimSession(host, budget, clock, cancellationToken: token)
            {
                LocalAdminsOverride = _ => new(InventoryCategories.Admins, SourceStatus.Empty, "Aucun membre local dans la simulation.", 0, []),
                RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) => query.Contains("FROM Win32_OperatingSystem", StringComparison.Ordinal)
                    ? [Row(("Caption", "Windows"), ("TotalVisibleMemorySize", 1000UL), ("FreePhysicalMemory", 500UL))]
                    : query.Contains("FROM Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("PCSystemType", 2), ("DomainRole", 1), ("Model", "Portable"))]
                    : query.Contains("FROM Win32_Group", StringComparison.Ordinal) ? [Row(("Name", "Administrateurs"), ("SID", "S-1-5-32-544"), ("LocalAccount", true))]
                    : query.Contains("FROM MSFT_PhysicalDisk", StringComparison.Ordinal) ? [Row(("DeviceId", "0"), ("FriendlyName", "SSD"))] : [],
            },
        };
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.Equal<long?>(1000, result.Memory?.VisibleKb, "projection de mémoire Windows");
        Check.Equal<int?>(2, result.System?.PcSystemType, "type système indépendant du rôle de domaine");
        Check.Null(result.PhysicalDisks.Single().UncorrectedErrors, "compteur absent reste inconnu");
        Check.True(result.Access.Any(a => a.Category == InventoryCategories.Board && a.Status == SourceStatus.Ok), "carte mère consultable");
        Check.Equal(SourceStatus.Empty, result.StatusOf(InventoryCategories.Admins), "groupe local qualifié puis membres simulés, sans NetAPI réel");
        Check.Equal(SourceStatus.Empty, result.StatusOf(InventoryCategories.Sessions), "identité qualifiée puis sessions simulées absentes");
        Check.False(result.Access.Any(a => a.Status == SourceStatus.Error), "aucune projection en erreur : "
            + string.Join(" ; ", result.Access.Where(a => a.Status == SourceStatus.Error).Select(a => a.Category + " : " + a.Detail)));
    }

    [Test]
    public static async Task Inventory_stop_preserves_completed_sources_and_marks_pending_ones()
    {
        var clock = TestClock.Fixed();
        using var stop = new CancellationTokenSource();
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new CimSession(host, budget, clock, cancellationToken: token)
            {
                RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) =>
                {
                    if (query.Contains("FROM Win32_BIOS", StringComparison.Ordinal)) { stop.Cancel(); }
                    return query.Contains("FROM Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"))] : [];
                },
            },
        };
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, stop.Token);
        Check.Equal("Windows", result.Os?.Caption, "source achevée conservée");
        Check.True(result.Access.Any(a => a.Category == InventoryCategories.Processor && a.Status == SourceStatus.Interrupted), "source non lue signalée");
    }

    [Test]
    public static void Wmi_unknown_flags_dates_and_session_types_are_not_guessed()
    {
        Check.Null(Row(("Flag", 2)).Bool("Flag"), "drapeau non booléen");
        Check.Null(CimQuery.ParseDmtf("00010101000000.000000+840"), "date hors plage");
        Check.Equal("authentification réseau", CimQuery.LogonType(3), "type 3");
        Check.Equal("service", CimQuery.LogonType(5), "type 5");
        Check.True(CimQuery.IsReadOnlySelect("SELECT Name FROM Win32_ComputerSystem WHERE Name=" + CimQuery.Literal("l'ordinateur")), "littéral échappé");
    }

    private sealed class MonotonicClock : TimeProvider
    {
        private long ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => ticks;
        public void Advance(TimeSpan by) => ticks += by.Ticks;
    }
}
