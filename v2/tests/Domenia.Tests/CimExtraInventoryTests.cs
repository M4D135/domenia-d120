using System.Text.Json;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CimExtraInventoryTests
{
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));
    private static WmiWorkstationReader Reader(Func<string, IEnumerable<WmiInstance>> read)
    {
        var clock = TestClock.Fixed();
        return new(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) => read(query) },
        };
    }

    [Test]
    public static async Task Extra_inventory_drops_command_arguments_and_keeps_unknown_device_states_unknown()
    {
        var reader = Reader(q => q.Contains("FROM Win32_StartupCommand", StringComparison.Ordinal)
            ? [Row(("Name", "Agent"), ("Command", "\"C:\\Program Files\\Agent\\agent.exe\" --password NEVER-PUBLISH-THIS"))]
            : q.Contains("FROM WmiMonitorID", StringComparison.Ordinal)
                ? [Row(("InstanceName", "DISPLAY1"), ("UserFriendlyName", new ushort[] { 69, 99, 114, 97, 110, 0 }), ("YearOfManufacture", 2022))]
            : q.Contains("FROM WmiMonitorConnectionParams", StringComparison.Ordinal)
                ? [Row(("InstanceName", "OTHER"), ("VideoOutputTechnology", 5U))]
            : q.Contains("FROM Win32_Printer", StringComparison.Ordinal) ? [Row(("Name", "Imprimante"), ("DetectedErrorState", 0))]
            : q.Contains("FROM Win32_PnPEntity", StringComparison.Ordinal) ? [Row(("Name", "Périphérique"), ("ConfigManagerErrorCode", "illisible"))]
            : []);
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.Equal(@"C:\Program Files\Agent\agent.exe", result.Startup.Single().Executable, "programme seul");
        Check.Null(result.Startup.Single().Microsoft, "éditeur inconnu, jamais déduit du nom");
        Check.False(JsonSerializer.Serialize(result).Contains("NEVER-PUBLISH-THIS", StringComparison.Ordinal), "arguments absents de toute la projection");
        Check.Null(result.Displays.Single().Internal, "aucun raccordement pris sur un autre écran");
        Check.Equal(SourceStatus.Partial, result.StatusOf(InventoryCategories.Displays), "identité partiellement lue");
        Check.Null(result.Printers.Single().Error, "code 0 signifie inconnu, jamais sain");
        Check.Null(result.Printers.Single().Network, "portée non lue");
        Check.Equal(SourceStatus.Partial, result.StatusOf(InventoryCategories.Printers), "états inconnus déclarés");
        Check.Equal(0, result.Devices.Length, "code illisible non transformé en zéro");
        Check.Equal(SourceStatus.Partial, result.StatusOf(InventoryCategories.Devices), "aucune fausse absence d’erreur");
    }

    [Test]
    public static async Task Battery_supplements_follow_exact_device_identity_and_preserve_unknown_capacities()
    {
        var reader = Reader(q => q.Contains("FROM Win32_Battery", StringComparison.Ordinal)
            ? [Row(("Name", "A"), ("PNPDeviceID", "ACPI\\BAT\\A"), ("EstimatedChargeRemaining", 255), ("DesignCapacity", 0)),
               Row(("Name", "B"), ("PNPDeviceID", "ACPI\\BAT\\B"), ("EstimatedChargeRemaining", 50), ("DesignCapacity", 60000U))]
            : q.Contains("FROM BatteryStaticData", StringComparison.Ordinal) ? [Row(("InstanceName", "ACPI\\BAT\\A_0"), ("DesignedCapacity", 50000U))]
            : q.Contains("FROM BatteryFullChargedCapacity", StringComparison.Ordinal) ? [Row(("InstanceName", "ACPI\\BAT\\B_0"), ("FullChargedCapacity", 45000U))]
            : q.Contains("FROM BatteryCycleCount", StringComparison.Ordinal) ? [Row(("InstanceName", "ACPI\\BAT\\A_0"), ("CycleCount", 0U))] : []);
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        var a = result.Batteries.Single(b => b.Name == "A"); var b = result.Batteries.Single(b => b.Name == "B");
        Check.Equal<long?>(50000, a.DesignedCapacity, "capacité nominale de A");
        Check.Null(a.FullChargeCapacity, "aucune capacité empruntée à B");
        Check.Null(a.ChargePercent, "charge hors plage inconnue");
        Check.Equal<int?>(0, a.Cycles, "zéro cycle lu reste zéro");
        Check.Equal<long?>(60000, b.DesignedCapacity, "capacité Win32 de B");
        Check.Equal<long?>(45000, b.FullChargeCapacity, "capacité actuelle de B");
        Check.False(WmiWorkstationReader.BatteryIdentity("ACPI\\BAT\\AB_0", "ACPI\\BAT\\A"), "préfixe homonyme refusé");
        Check.False(WmiWorkstationReader.BatteryIdentity("ACPI\\BAT\\A_OTHER", "ACPI\\BAT\\A"), "suffixe non numérique refusé");
    }

    [Test]
    public static async Task Full_inventory_limits_tasks_to_non_secret_metadata_and_formats_IPv6_endpoints()
    {
        var queries = new List<string>();
        var reader = Reader(q =>
        {
            queries.Add(q);
            return q.Contains("FROM MSFT_ScheduledTask", StringComparison.Ordinal)
                ? [Row(("TaskName", "Maintenance"), ("TaskPath", "\\Entreprise\\"), ("Author", "Support"), ("State", 3))]
                : q.Contains("FROM MSFT_NetTCPConnection", StringComparison.Ordinal)
                    ? [Row(("LocalAddress", "::1"), ("LocalPort", 445U), ("RemoteAddress", "::1"), ("RemotePort", 12345U), ("State", 5U), ("OwningProcess", 4U))]
                : q.Contains("FROM MSFT_NetUDPEndpoint", StringComparison.Ordinal)
                    ? [Row(("LocalAddress", "0.0.0.0"), ("LocalPort", 53U), ("OwningProcess", 42U))] : [];
        });
        var result = await reader.ReadAsync("PC1", WorkstationReading.Full, null, CancellationToken.None);
        var task = result.Tasks.Single();
        Check.Equal("Prête", task.State, "état lu, traduit");
        Check.Null(task.LastResult, "aucune réussite d’exécution inventée");
        Check.Equal(SourceStatus.Partial, result.StatusOf(InventoryCategories.Tasks), "limites de la projection dites");
        Check.Equal("[::1]:445", result.Connections.Single(c => c.Protocol == "TCP").Local, "IPv6 non ambigu");
        Check.Equal("Sans connexion", result.Connections.Single(c => c.Protocol == "UDP").Remote, "UDP sans pair inventé");
        Check.True(queries.Where(q => q.Contains("MSFT_ScheduledTask", StringComparison.Ordinal)).All(q => !q.Contains("Actions", StringComparison.Ordinal)
            && !q.Contains("Principal", StringComparison.Ordinal) && !q.Contains("*", StringComparison.Ordinal)), "aucune action, aucun argument ni compte principal collecté");
        Check.False(result.Access.Any(a => a.Status == SourceStatus.Error), "projections admises par la garde WQL");
    }

    [Test]
    public static void Monitor_unknown_connection_codes_remain_unknown_and_unsigned_internal_flag_is_supported()
    {
        Check.Equal<bool?>(true, WmiWorkstationReader.VideoOutput(2147483648).Internal, "drapeau interne non signé");
        Check.Equal<bool?>(false, WmiWorkstationReader.VideoOutput(5).Internal, "HDMI externe");
        Check.Null(WmiWorkstationReader.VideoOutput(17).Internal, "adaptateur virtuel non classé physique");
        Check.Null(WmiWorkstationReader.VideoOutput(null).Internal, "absence de lecture");
        Check.Equal("AB", WmiWorkstationReader.Edid(Row(("Name", new ushort[] { 65, 66, 0, 67 })), "Name"), "EDID arrêté au terminateur");
    }
}
