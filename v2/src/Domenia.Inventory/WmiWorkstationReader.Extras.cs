using System.Collections.Immutable;
using System.Globalization;
using System.Net;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class WmiWorkstationReader
{
    private static InventorySnapshot ReadStartup(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var read = session.Read(InventoryCategories.Startup, Cimv2, "SELECT Name, User, Location, Command FROM Win32_StartupCommand", 200);
        AddAccess(access, session, InventoryCategories.Startup, read);
        token.ThrowIfCancellationRequested();
        // Only the executable leaves this collector. Neither arguments nor an inferred publisher enter the snapshot.
        return current with { Startup = [.. read.Instances.Select(r => new StartupEntry(r.Text("Name") ?? "Entrée sans nom",
            PosteLabels.CommandExecutable(r.Text("Command")), r.Text("Location") ?? "Emplacement non lu", r.Text("User"), null))] };
    }

    private static InventorySnapshot ReadDevices(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var read = session.Read(InventoryCategories.Devices, Cimv2, "SELECT Name, DeviceID, PNPClass, ConfigManagerErrorCode FROM Win32_PnPEntity WHERE ConfigManagerErrorCode<>0", 200);
        AddAccess(access, session, InventoryCategories.Devices, read);
        token.ThrowIfCancellationRequested();
        var rows = read.Instances.Where(r => r.Int("ConfigManagerErrorCode") is > 0).ToArray();
        if (rows.Length != read.Items) { Incomplete(access, InventoryCategories.Devices, "Code de périphérique illisible ; lignes non qualifiées écartées."); }
        return current with { Devices = [.. rows.Select(r => new DeviceError(r.Text("Name") ?? r.Text("DeviceID") ?? "Périphérique non identifié", r.Int("ConfigManagerErrorCode")!.Value, r.Text("PNPClass")))] };
    }

    private static InventorySnapshot ReadDisplays(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var ids = session.Read(InventoryCategories.Displays, @"root\wmi", "SELECT InstanceName, UserFriendlyName, ManufacturerName, ProductCodeID, SerialNumberID, YearOfManufacture FROM WmiMonitorID WHERE Active=TRUE", 32);
        var links = session.Read(InventoryCategories.Displays, @"root\wmi", "SELECT InstanceName, VideoOutputTechnology FROM WmiMonitorConnectionParams WHERE Active=TRUE", 32);
        AddAccess(access, session, InventoryCategories.Displays, ids, links);
        token.ThrowIfCancellationRequested();
        var rows = ImmutableArray.CreateBuilder<DisplayInfo>();
        foreach (var row in ids.Instances)
        {
            var key = row.Text("InstanceName");
            var matches = key is null ? [] : links.Instances.Where(r => string.Equals(r.Text("InstanceName"), key, StringComparison.OrdinalIgnoreCase)).ToArray();
            var (connection, internalDisplay) = VideoOutput(matches.Length == 1 ? matches[0].Number("VideoOutputTechnology") : null);
            var name = Edid(row, "UserFriendlyName"); var year = row.Int("YearOfManufacture");
            rows.Add(new(name ?? "Écran non identifié", Edid(row, "ManufacturerName"), Edid(row, "ProductCodeID"), Edid(row, "SerialNumberID"),
                year is >= 1990 and <= 2200 ? year : null, connection, internalDisplay));
            if (matches.Length != 1 || name is null || internalDisplay is null) { Incomplete(access, InventoryCategories.Displays, "Certaines identités ou connexions d’écran ne sont pas déterminées."); }
        }
        return current with { Displays = rows.ToImmutable() };
    }

    internal static string? Edid(WmiInstance row, string field)
    {
        var codes = row.Ints(field);
        if (codes.Length > 256) { return null; }
        var text = new string(codes.TakeWhile(c => c != 0).Where(c => c is >= 32 and <= 126).Select(c => (char)c).ToArray()).Trim();
        return text.Length == 0 ? null : text;
    }

    internal static (string Text, bool? Internal) VideoOutput(long? code) => code switch
    {
        0 => ("VGA", false), 1 => ("S-Vidéo", false), 2 => ("Composite", false), 3 => ("Composantes", false),
        4 => ("DVI", false), 5 => ("HDMI", false), 6 => ("LVDS", true), 8 => ("D-JPN", false), 9 => ("SDI", false),
        10 => ("DisplayPort externe", false), 11 => ("DisplayPort intégré", true), 12 => ("UDI externe", false), 13 => ("UDI intégré", true),
        14 => ("SDTV", false), 15 => ("Miracast", false), 16 => ("Indirect filaire", false), 17 => ("Indirect virtuel", null),
        2147483648 => ("Écran interne", true), 4294967295 => ("Autre", null),
        null => ("Type de connexion non lu", null), _ => ("Type " + code.Value.ToString(CultureInfo.InvariantCulture), null),
    };

    private static InventorySnapshot ReadBatteries(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var batteries = session.Read(InventoryCategories.Batteries, Cimv2, "SELECT Name, PNPDeviceID, EstimatedChargeRemaining, BatteryStatus, DesignCapacity, FullChargeCapacity FROM Win32_Battery", 16);
        if (!batteries.Answered || batteries.Status == SourceStatus.Empty)
        { AddAccess(access, session, InventoryCategories.Batteries, batteries); return current with { Batteries = [] }; }
        var design = session.Read(InventoryCategories.Batteries, @"root\wmi", "SELECT InstanceName, DesignedCapacity FROM BatteryStaticData", 16);
        var full = session.Read(InventoryCategories.Batteries, @"root\wmi", "SELECT InstanceName, FullChargedCapacity FROM BatteryFullChargedCapacity", 16);
        var cycles = session.Read(InventoryCategories.Batteries, @"root\wmi", "SELECT InstanceName, CycleCount FROM BatteryCycleCount", 16);
        AddAccess(access, session, InventoryCategories.Batteries, batteries, design, full, cycles);
        token.ThrowIfCancellationRequested();
        long? Supplement(WmiInstance battery, CimReading supplement, string field)
        {
            var id = battery.Text("PNPDeviceID");
            if (id is null) { return null; }
            var candidates = supplement.Instances.Where(r => BatteryIdentity(r.Text("InstanceName"), id)).ToArray();
            return candidates.Length == 1 ? candidates[0].Number(field) : null;
        }
        static long? Capacity(long? value) => value is > 0 and < uint.MaxValue ? value : null;
        return current with { Batteries = [.. batteries.Instances.Select(b =>
        {
            var charge = b.Int("EstimatedChargeRemaining"); var count = Supplement(b, cycles, "CycleCount");
            return new BatteryInfo(b.Text("Name") ?? "Batterie", charge is >= 0 and <= 100 ? charge : null, b.Int("BatteryStatus"),
                Capacity(Supplement(b, design, "DesignedCapacity")) ?? Capacity(b.Number("DesignCapacity")),
                Capacity(Supplement(b, full, "FullChargedCapacity")) ?? Capacity(b.Number("FullChargeCapacity")),
                count is >= 0 and < int.MaxValue ? (int)count : null);
        })] };
    }

    internal static bool BatteryIdentity(string? instance, string pnpId)
    {
        if (string.Equals(instance, pnpId, StringComparison.OrdinalIgnoreCase)) { return true; }
        return instance is not null && instance.StartsWith(pnpId + "_", StringComparison.OrdinalIgnoreCase)
            && instance.Length > pnpId.Length + 1 && instance.AsSpan(pnpId.Length + 1).IndexOfAnyExceptInRange('0', '9') < 0;
    }

    private static InventorySnapshot ReadDrivers(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var read = session.Read(InventoryCategories.Drivers, Cimv2, "SELECT DeviceName, DriverProviderName, DriverVersion FROM Win32_PnPSignedDriver WHERE IsSigned=False", 200);
        AddAccess(access, session, InventoryCategories.Drivers, read); token.ThrowIfCancellationRequested();
        return current with { UnsignedDrivers = [.. read.Instances.Select(r => new DriverInfo(r.Text("DeviceName") ?? "Pilote non identifié", r.Text("DriverProviderName"), r.Text("DriverVersion")))] };
    }

    private static InventorySnapshot ReadShares(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var read = session.Read(InventoryCategories.Shares, Cimv2, "SELECT Name, Path, Description FROM Win32_Share", 200);
        AddAccess(access, session, InventoryCategories.Shares, read); token.ThrowIfCancellationRequested();
        return current with { Shares = [.. read.Instances.Select(r => new ShareInfo(r.Text("Name") ?? "Partage non identifié", r.Text("Path") ?? "Chemin non lu", r.Text("Description")))] };
    }

    private static InventorySnapshot ReadPrinters(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var read = session.Read(InventoryCategories.Printers, Cimv2, "SELECT Name, DriverName, PortName, Network, Default, WorkOffline, DetectedErrorState FROM Win32_Printer", 200);
        AddAccess(access, session, InventoryCategories.Printers, read); token.ThrowIfCancellationRequested();
        var printers = read.Instances.Select(r => new PrinterInfo(r.Text("Name") ?? "Imprimante non identifiée", r.Text("DriverName"), r.Text("PortName"),
            r.Bool("Network"), r.Bool("Default"), r.Bool("WorkOffline"), r.Int("DetectedErrorState") switch { 2 => false, >= 3 and <= 11 => true, _ => null })).ToImmutableArray();
        if (printers.Any(p => p.Network is null || p.Offline is null || p.Error is null))
        { Incomplete(access, InventoryCategories.Printers, "Certains états d’imprimante ne sont pas fournis par le pilote."); }
        return current with { Printers = printers };
    }

    private static InventorySnapshot ReadTasks(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var read = session.Read(InventoryCategories.Tasks, @"root\Microsoft\Windows\TaskScheduler", "SELECT TaskName, TaskPath, Author, State FROM MSFT_ScheduledTask", 1000);
        AddAccess(access, session, InventoryCategories.Tasks, read); token.ThrowIfCancellationRequested();
        if (read.Items > 0) { Incomplete(access, InventoryCategories.Tasks, "Définitions et états lus ; dernier résultat et dates d’exécution non fournis par cette projection."); }
        return current with { Tasks = [.. read.Instances.Select(r => new TaskEntry(r.Text("TaskName") ?? "Tâche non identifiée", r.Text("TaskPath") ?? "Chemin non lu", r.Text("Author"),
            r.Int("State") switch { 1 => "Désactivée", 2 => "En attente", 3 => "Prête", 4 => "En cours", _ => "État non lu" }, null, null, null,
            r.Text("TaskPath")?.StartsWith(@"\Microsoft\", StringComparison.OrdinalIgnoreCase) == true))] };
    }

    private static InventorySnapshot ReadConnections(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        const string ns = @"root\StandardCimv2";
        var tcp = session.Read(InventoryCategories.Connections, ns, "SELECT LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess FROM MSFT_NetTCPConnection", 500);
        var udp = session.Read(InventoryCategories.Connections, ns, "SELECT LocalAddress, LocalPort, OwningProcess FROM MSFT_NetUDPEndpoint", 500);
        AddAccess(access, session, InventoryCategories.Connections, tcp, udp); token.ThrowIfCancellationRequested();
        static string Endpoint(WmiInstance r, string prefix) => IPAddress.TryParse(r.Text(prefix + "Address"), out var address) && r.Int(prefix + "Port") is >= 0 and <= 65535
            ? (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 ? "[" + address + "]" : address.ToString()) + ":" + r.Int(prefix + "Port")!.Value.ToString(CultureInfo.InvariantCulture)
            : "Adresse non lue";
        static string? Process(WmiInstance r) => r.Int("OwningProcess") is int id and >= 0 ? "PID " + id.ToString(CultureInfo.InvariantCulture) : null;
        return current with { Connections = [.. tcp.Instances.Select(r => new ConnectionEntry("TCP", Endpoint(r, "Local"), Endpoint(r, "Remote"),
            r.Int("State") switch { 1 => "Closed", 2 => "Listen", 3 => "SynSent", 4 => "SynReceived", 5 => "Established", 6 => "FinWait1", 7 => "FinWait2", 8 => "CloseWait", 9 => "Closing", 10 => "LastAck", 11 => "TimeWait", 12 => "DeleteTCB", _ => "Unknown" }, Process(r))),
            .. udp.Instances.Select(r => new ConnectionEntry("UDP", Endpoint(r, "Local"), "Sans connexion", "Endpoint", Process(r)))] };
    }

    private static void Incomplete(List<SourceAccess> access, string category, string detail)
    {
        var index = access.FindLastIndex(a => a.Category == category);
        if (index >= 0 && access[index].Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial)
        { access[index] = access[index] with { Status = SourceStatus.Partial, Detail = detail }; }
    }
}
