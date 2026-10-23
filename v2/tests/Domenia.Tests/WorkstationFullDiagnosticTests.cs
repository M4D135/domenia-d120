using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Xml;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WorkstationFullDiagnosticTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
    private static WmiWorkstationReader Native(Func<string, IReadOnlyList<WmiInstance>> query, Func<DiagnosticTransport, CimReading>? transport = null)
    {
        var clock = TestClock.Fixed();
        return new(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        { ReadOverride = (_, sql, _) => query(sql), RegistryOverride = (_, _) => new(2, null), DiagnosticOverride = transport } };
    }

    private static IReadOnlyList<WmiInstance> Healthy(string sql) => sql.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"))]
        : sql.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"), ("Version", "10"), ("SystemDrive", "D:"))]
        : sql.Contains("Win32_LogicalDisk", StringComparison.Ordinal) ? [Row(("DeviceID", "D:"), ("Size", 1000L), ("FreeSpace", 200L))] : [];

    [Test]
    public static async Task Full_diagnostic_uses_the_declared_system_volume_and_stops_on_foreign_identity()
    {
        var queries = new List<string>();
        var read = await Native(q => { queries.Add(q); return Healthy(q); }).ReadAsync("PC1", WorkstationReading.Diagnostic, null, CancellationToken.None);
        Check.Equal("D:", read.Volumes.Single().Id, "lettre déclarée par Windows");
        Check.True(queries.Any(q => q.Contains("DeviceID='D:'", StringComparison.Ordinal)), "filtre exact de la lettre validée");
        Check.False(queries.Any(q => q.Contains("DeviceID='C:'", StringComparison.Ordinal)), "aucun C: supposé");
        Check.True(read.PendingReboot?.Complete == true, "trois indicateurs réellement lus");
        queries.Clear();
        var foreign = await Native(q => { queries.Add(q); return [Row(("Name", "OTHER"))]; }).ReadAsync("PC1", WorkstationReading.Diagnostic, null, CancellationToken.None);
        Check.Equal(1, queries.Count, "aucune autre source après l’identité étrangère"); Check.Null(foreign.Os, "aucun système attribué au mauvais poste");
    }

    [Test]
    public static async Task Unread_or_invalid_system_drive_never_becomes_C_by_default()
    {
        foreach (var drive in new string?[] { null, "", @"C:\", "C:' OR TRUE", "XX:" })
        {
            var diskQueries = 0;
            var reader = Native(q =>
            {
                if (q.Contains("Win32_LogicalDisk", StringComparison.Ordinal)) { diskQueries++; }
                return q.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"), ("Version", "10"), ("SystemDrive", drive))] : Healthy(q);
            });
            var read = await reader.ReadAsync("PC1", WorkstationReading.Diagnostic, null, CancellationToken.None);
            Check.Equal(0, diskQueries, "aucun filtre envoyé depuis une lettre invalide");
            Check.Equal(SourceStatus.Unavailable, read.StatusOf(InventoryCategories.Volumes), "volume inconnu explicite");
        }
    }

    [Test]
    public static async Task Full_diagnostic_keeps_the_same_account_and_distinguishes_network_from_protocol_access()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var checks = new List<DiagnosticTransport>();
        var reader = new AdPosteReader(source)
        {
            DiagnosticNetworkOverride = (_, _) => Task.FromResult<ImmutableArray<DiagCheck>>([new("Resolution DNS", "OK", "DNS", 1, "Adresse reçue"), new("Ping", "INJOIGNABLE", "ICMP", 1, "Silence"), new("TCP 445", "OK", "TCP", 1, "Port ouvert")]),
            InventoryReaderOverride = _ => Native(Healthy, kind => { checks.Add(kind); return new(kind.ToString(), kind == DiagnosticTransport.Smb ? SourceStatus.Refused : SourceStatus.Ok, "Contrôle simulé", 1, []); }),
        };
        var result = await reader.DiagnosticAsync(pc.DistinguishedName, null, CancellationToken.None);
        Check.Equal(3, checks.Count, "contrôles indépendants après identité CIM validée");
        Check.Equal("REFUSE", result.Rows.Single(r => r.Check == "Partage C$").Status, "port SMB ouvert ne prouve pas le droit C$");
        Check.True(result.Rows.Single(r => r.Check == "Disque systeme").Detail.Contains("D:", StringComparison.Ordinal), "volume réel nommé");
        Check.Equal(0, cache.FleetWrites, "diagnostic ne remplace pas l’inventaire conservé");
    }

    [Test]
    public static async Task Rejected_CIM_credentials_stop_other_authenticated_diagnostic_transports()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var contacts = 0;
        var reader = new AdPosteReader(source)
        {
            DiagnosticNetworkOverride = (_, _) => Task.FromResult<ImmutableArray<DiagCheck>>([]),
            InventoryReaderOverride = _ => Native(_ => throw new COMException("Rejet simulé", unchecked((int)0x8007052E)), kind => { contacts++; return new(kind.ToString(), SourceStatus.Ok, "Ne doit pas être envoyé", 0, []); }),
        };
        var result = await reader.DiagnosticAsync(pc.DistinguishedName, null, CancellationToken.None);
        Check.Equal(0, contacts, "aucun nouvel essai authentifié après rejet");
        Check.Equal("REFUSE", result.Rows.Single(r => r.Check == "Session CIM").Status, "cause conservée");
        Check.True(result.Rows.Where(r => r.Check is "WinRM" or "Partage C$" or "Transport Task Scheduler").All(r => r.Status == "IGNORE"), "suite suspendue");
    }

    [Test]
    public static async Task Stopping_after_network_keeps_checks_without_claiming_the_workstation_responds()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        using var stop = new CancellationTokenSource(); var contacts = 0;
        var reader = new AdPosteReader(source)
        {
            DiagnosticNetworkOverride = (_, _) => { stop.Cancel(); return Task.FromResult<ImmutableArray<DiagCheck>>([new("Resolution DNS", "OK", "DNS", 1, "Adresse reçue")]); },
            InventoryReaderOverride = _ => Native(_ => { contacts++; return []; }),
        };
        var result = await reader.DiagnosticAsync(pc.DistinguishedName, null, stop.Token);
        Check.Equal(0, contacts, "sources non contactées après arrêt"); Check.False(result.Reachable, "DNS seul ne prouve pas une réponse du poste");
        Check.True(result.Verdict.Contains("non établie", StringComparison.Ordinal), "résumé sans faux succès");
        Check.Equal("OK", result.Rows[0].Status, "résolution déjà reçue conservée");
    }

    [Test]
    public static void Inconclusive_and_skipped_checks_are_not_failed_network_layers_or_closed_WinRM_claims()
    {
        var result = PosteDiagnostics.Verdict("PC1", [new("TCP 135", "IGNORE", "TCP", 0, "Arrêt"), new("WinRM", "INCONNU", "WSMan", 0, "Délai")], Fixtures.Now, 1, TimeZoneInfo.Utc);
        Check.Equal(LayerState.NotTried, result.Layers[2].State, "TCP non tenté distinct d’un échec");
        Check.Equal(1, result.Inconclusive, "compteur de lecture non concluante"); Check.Equal(0, result.Failed, "aucun faux contrôle en échec");
        Check.False(result.Verdict.Contains("WinRM fermé", StringComparison.Ordinal), "un délai ne prouve pas une configuration absente");
        const string ns = "http://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd";
        var valid = "<IdentifyResponse xmlns='" + ns + "'><ProtocolVersion>http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd</ProtocolVersion></IdentifyResponse>";
        WsmanReadChannel.CheckIdentify(valid);
        Check.Throws<XmlException>(() => WsmanReadChannel.CheckIdentify(valid.Replace("IdentifyResponse", "Other", StringComparison.Ordinal)), "réponse étrangère rejetée");
        Check.Throws<XmlException>(() => WsmanReadChannel.CheckIdentify("<!DOCTYPE a [<!ENTITY b SYSTEM 'file:///never'>]>" + valid), "DTD interdite");
    }

    [Test]
    public static void Native_task_scheduler_connects_to_local_VM_with_current_token_without_creating_a_task()
    {
        object? service = null; object? folder = null;
        try
        {
            service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", throwOnError: true)!)!;
            TaskSchedulerConnection.Connect(service, Environment.MachineName, null);
            folder = ((dynamic)service).GetFolder(@"\");
            Check.Equal(@"\", (string)((dynamic)folder).Path, "racine du service local lue uniquement");
        }
        finally
        {
            if (folder is not null && Marshal.IsComObject(folder)) { Marshal.FinalReleaseComObject(folder); }
            if (service is not null && Marshal.IsComObject(service)) { Marshal.FinalReleaseComObject(service); }
        }
    }
}
