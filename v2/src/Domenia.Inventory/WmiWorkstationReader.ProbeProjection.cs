using System.Collections.Immutable;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class WmiWorkstationReader
{
    /// <summary>Pure projection of stored columns. Never performs a secondary query to fill a missing property.</summary>
    public static ProbeStore ProjectProbes(ProbeStore store)
    {
        WmiInstance[] Rows(string id)
        {
            if (store.Probes.FirstOrDefault(p => p.ProbeId == id)?.State is not (ProbeState.Read or ProbeState.Partial)
                || !store.Values.TryGetValue(id, out var values)) { return []; }
            var columns = ProbeCatalog.Find(id)!.Properties;
            return values.Rows.Select(row => new WmiInstance(columns.Select((p, n) => (p, Value(row[n]))).ToDictionary(p => p.p, p => p.Item2))).ToArray();
        }
        WmiInstance? One(string id) { var rows = Rows(id); return rows.Length == 1 ? rows[0] : null; }
        WmiInstance? Match(string id, string key, string? value)
        { var rows = value is null ? [] : Rows(id).Where(r => string.Equals(r.Text(key), value, StringComparison.OrdinalIgnoreCase)).ToArray(); return rows.Length == 1 ? rows[0] : null; }
        var access = new List<SourceAccess>();
        void Access(string category, params string[] ids)
        {
            var states = ids.Select(id => store.Probes.FirstOrDefault(p => p.ProbeId == id)?.State ?? ProbeState.NotRead).ToArray();
            var state = states.All(s => s == ProbeState.Read) ? SourceStatus.Ok : states.Any(s => s is ProbeState.Read or ProbeState.Partial) ? SourceStatus.Partial
                : states.Any(s => s == ProbeState.Refused) ? SourceStatus.Refused : SourceStatus.Skipped;
            access.Add(new(category, state, "Sondes locales datées ; aucune autre source sollicitée.", 0, ids.Sum(id => Rows(id).Length), InventoryTransport.Local));
        }
        static long? Capacity(long? n) => n is > 0 and < uint.MaxValue ? n : null;
        static long? Sum(IEnumerable<long?> numbers, long factor = 1)
        { decimal total = 0; foreach (var n in numbers) { if (n is null or < 0) { return null; } total += n.Value; } return total * factor <= long.MaxValue ? (long)(total * factor) : null; }
        var data = Empty(store.Computer, store.CollectedAt ?? DateTimeOffset.MinValue, false, InventoryTransport.Local) with { ReportedName = store.ReportedName };
        Access(InventoryCategories.System, "hw.computersystem");
        var system = One("hw.computersystem"); var bios = One("hw.biosdetails");
        data = data with
        {
            System = system is null ? null : new(system.Text("Manufacturer") ?? "", system.Text("Model") ?? "", bios?.Text("SerialNumber"), [], system.Int("PCSystemTypeEx"),
                system.Number("TotalPhysicalMemory"), system.Int("NumberOfLogicalProcessors"), system.Bool("HypervisorPresent") == true ? "Hyperviseur signalé par Windows" : null, null),
            Bios = bios is null ? null : new(bios.Text("SMBIOSBIOSVersion") ?? "", bios.Dmtf("ReleaseDate"),
                bios.Int("SMBIOSMajorVersion") is { } major && bios.Int("SMBIOSMinorVersion") is { } minor ? major + "." + minor : null, null, bios.Text("Manufacturer")),
        };
        Access(InventoryCategories.Bios, "hw.biosdetails"); Access(InventoryCategories.Memory, "hw.memorymodules", "hw.memoryarrays", "hw.memoryusage");
        var arrays = Rows("hw.memoryarrays").Where(r => r.Int("Use") == 3).ToArray(); var memory = One("hw.memoryusage");
        var slots = Sum(arrays.Select(r => r.Number("MemoryDevices")));
        data = data with
        {
            MemoryModules = [.. Rows("hw.memorymodules").Select(r => new MemoryModule(r.Text("DeviceLocator") ?? "Emplacement non déclaré", r.Number("Capacity"), r.Int("ConfiguredClockSpeed"), r.Text("Manufacturer"), r.Text("PartNumber")))],
            MemoryArray = arrays.Length == 0 ? null : new(slots is > 0 and <= int.MaxValue ? (int)slots : null, Sum(arrays.Select(r => r.Number("MaxCapacityEx")), 1024)),
            Memory = memory is null ? null : new(memory.Number("TotalVisibleMemorySize"), memory.Number("FreePhysicalMemory")),
            Processors = [.. Rows("hw.processors").Select(r => new CpuInfo(r.Text("Name") ?? "Processeur non identifié", r.Int("NumberOfCores"), r.Int("NumberOfLogicalProcessors"),
                r.Int("MaxClockSpeed"), r.Int("LoadPercentage") is >= 0 and <= 100 and var load ? load : null, r.Int("Architecture")?.ToString(CultureInfo.InvariantCulture),
                r.Bool("VirtualizationFirmwareEnabled"), r.Bool("SecondLevelAddressTranslationExtensions")))],
            Volumes = [.. Rows("disk.volumes").Select(r => new LogicalDisk(r.Text("DeviceID") ?? "Volume non identifié", r.Text("VolumeName"), r.Text("FileSystem"), r.Number("Size"), r.Number("FreeSpace")))],
        };
        Access(InventoryCategories.Processor, "hw.processors"); Access(InventoryCategories.Volumes, "disk.volumes"); Access(InventoryCategories.PhysicalDisks, "disk.physical", "disk.reliability");
        data = data with { PhysicalDisks = [.. Rows("disk.physical").Select(r =>
        {
            var counter = Match("disk.reliability", "DeviceId", r.Text("DeviceId"));
            return new PhysicalDisk(r.Text("DeviceId") ?? "", r.Text("FriendlyName") ?? "Disque non identifié", r.Int("MediaType"), r.Int("BusType"), r.Number("Size"), r.Int("HealthStatus"),
                counter?.Number("Wear") is >= 0 and <= 100 and var wear ? wear : null, counter?.Number("Temperature"), counter?.Number("PowerOnHours"),
                counter is null ? null : Sum([counter.Number("ReadErrorsUncorrected"), counter.Number("WriteErrorsUncorrected")]), null);
        })] };
        Access(InventoryCategories.Batteries, "hw.batteries", "hw.batterystatic", "hw.batteryfullcharge", "hw.batterycycles");
        // Win32_Battery.DeviceID is not a PNP identity. Never join it to root\wmi by position or suffix.
        var batteries = Rows("hw.batteries").Select(r => new BatteryInfo(r.Text("Name") ?? "Batterie non identifiée",
            r.Int("EstimatedChargeRemaining") is >= 0 and <= 100 and var charge ? charge : null, r.Int("BatteryStatus"), Capacity(r.Number("DesignCapacity")), Capacity(r.Number("FullChargeCapacity")), null)).ToList();
        foreach (var r in Rows("hw.batterystatic"))
        {
            var key = r.Text("InstanceName"); var full = Match("hw.batteryfullcharge", "InstanceName", key); var cycles = Match("hw.batterycycles", "InstanceName", key)?.Int("CycleCount");
            batteries.Add(new((r.Text("DeviceName") ?? key ?? "Batterie non identifiée") + " (capacité du pilote, lien à la charge non établi)", null, null,
                Capacity(r.Number("DesignedCapacity")), Capacity(full?.Number("FullChargedCapacity")), cycles is > 0 ? cycles : null));
        }
        Access(InventoryCategories.Displays, "hw.monitors", "hw.monitorconnections");
        data = data with { Batteries = [.. batteries], Displays = [.. Rows("hw.monitors").Where(r => r.Bool("Active") == true).Select(r =>
        {
            var link = Match("hw.monitorconnections", "InstanceName", r.Text("InstanceName"));
            var (connection, internalDisplay) = VideoOutput(link?.Bool("Active") == true ? link.Number("VideoOutputTechnology") : null);
            var year = r.Int("YearOfManufacture");
            return new DisplayInfo(Edid(r, "UserFriendlyName") ?? "Écran non identifié", Edid(r, "ManufacturerName"), Edid(r, "ProductCodeID"), Edid(r, "SerialNumberID"),
                year is >= 1990 and <= 2200 ? year : null, connection, internalDisplay);
        })] };
        Access(InventoryCategories.Network, "net.interfaces", "net.configurations");
        data = data with { Network = [.. Rows("net.interfaces").Select(r =>
        {
            var config = Match("net.configurations", "Index", r.Text("DeviceID"));
            // Both providers expose the adapter index, sometimes as numeric and sometimes as text.
            var candidates = Rows("net.configurations").Where(c => c.Number("Index") is { } index && index == r.Number("DeviceID")).ToArray();
            config = candidates.Length == 1 ? candidates[0] : config;
            var ips = config?.Strings("IPAddress") ?? []; var masks = config?.Strings("IPSubnet") ?? [];
            var first = Array.FindIndex(ips, ip => IPAddress.TryParse(ip, out var address) && address.AddressFamily == AddressFamily.InterNetwork);
            return new NetworkAdapter(r.Text("Name") ?? "Interface non identifiée", r.Int("NetConnectionStatus"), r.Number("Speed"), r.Text("MACAddress"),
                r.Bool("PhysicalAdapter") == true, false, [.. ips.Where(ip => IPAddress.TryParse(ip, out var address) && address.AddressFamily == AddressFamily.InterNetwork)],
                first >= 0 && first < masks.Length ? Ipv4Prefix(masks[first]) : null, config?.Strings("DefaultIPGateway").FirstOrDefault(), [.. config?.Strings("DNSServerSearchOrder") ?? []], config?.Bool("DHCPEnabled"), null);
        })] };
        Access(InventoryCategories.Devices, "hw.deviceerrors"); Access(InventoryCategories.Printers, "soft.printerdetails"); Access(InventoryCategories.Services, "soft.servicedetails");
        var devices = Rows("hw.deviceerrors"); var services = Rows("soft.servicedetails");
        if (devices.Any(r => r.Int("ConfigManagerErrorCode") is not > 0)) { Partial(InventoryCategories.Devices); }
        if (services.Any(r => r.Text("Name") is null || r.Text("State") is null || r.Text("StartMode") is null)) { Partial(InventoryCategories.Services); }
        data = data with
        {
            Devices = [.. devices.Where(r => r.Int("ConfigManagerErrorCode") > 0).Select(r => new DeviceError(r.Text("Name") ?? "Périphérique non identifié", r.Int("ConfigManagerErrorCode")!.Value, r.Text("PNPClass")))],
            Printers = [.. Rows("soft.printerdetails").Select(r => new PrinterInfo(r.Text("Name") ?? "Imprimante non identifiée", r.Text("DriverName"), r.Text("PortName"), r.Bool("Network"), r.Bool("Default"), r.Bool("WorkOffline"),
                r.Int("ExtendedPrinterStatus") is >= 1 and <= 18 and var state ? state is 7 or 9 or 11 or 12 or 15 or 16 or 17 or 18 : null))],
            Services = [.. services.Select(r => new ServiceEntry(r.Text("Name") ?? "", r.Text("DisplayName") ?? "", r.Text("State") ?? "Non lu", r.Text("StartMode") ?? "Non lu", null, r.Int("ProcessId"), null, r.Int("ExitCode"), [], null))],
        };
        Access(InventoryCategories.Tasks, "soft.scheduledtasks"); Access(InventoryCategories.Startup, "soft.startupdetails"); Access(InventoryCategories.Processes, "soft.processdetails");
        data = data with
        {
            Tasks = [.. Rows("soft.scheduledtasks").Select(r => new TaskEntry(r.Text("TaskName") ?? "", r.Text("TaskPath") ?? "", r.Text("Author"), TaskState(r.Int("State")), null, null, null,
                r.Text("TaskPath")?.StartsWith(@"\Microsoft\", StringComparison.OrdinalIgnoreCase) == true))],
            Startup = [.. Rows("soft.startupdetails").Select(r => new StartupEntry(r.Text("Name") ?? "", "Exécutable non lu", r.Text("Location") ?? "", r.Text("User"), null))],
            Processes = [.. Rows("soft.processdetails").Where(r => r.Int("ProcessId") is >= 0).Select(r => new ProcessEntry(r.Int("ProcessId")!.Value, r.Text("Name") ?? "", r.Number("WorkingSetSize"), null, null, r.Dmtf("CreationDate")))],
        };
        Access(InventoryCategories.Antivirus, "sec.avproducts", "sec.defenderdetails"); var defender = One("sec.defenderdetails");
        data = data with
        {
            Antivirus = [.. Rows("sec.avproducts").Select(r => new AntivirusProduct(r.Text("displayName") ?? "Produit non identifié", r.Int("productState"), r.Dmtf("timestamp")))],
            Defender = defender is null ? null : new(defender.Bool("AntivirusEnabled"), defender.Bool("RealTimeProtectionEnabled"), defender.Bool("BehaviorMonitorEnabled"),
                defender.Int("AntivirusSignatureAge"), defender.Int("QuickScanAge"), defender.Int("FullScanAge"), defender.Text("AMProductVersion"), null, null),
        };
        Access(InventoryCategories.Firewall, "sec.firewallprofiles", "net.connectionprofiles");
        data = data with { Firewall = [.. Rows("sec.firewallprofiles").Select(r => new FirewallProfile(r.Text("Name") ?? "Profil non identifié", r.Bool("Enabled"), null, [])
            { Source = "MSFT_NetFirewallProfile : configuration déclarée", PolicyRead = false, ConnectionsRead = false })] };
        Access(InventoryCategories.BitLocker, "sec.bitlockervolumes"); Access(InventoryCategories.Tpm, "sec.tpmdetails");
        var tpm = One("sec.tpmdetails"); var guard = One("sec.deviceguard");
        data = data with
        {
            BitLocker = [.. Rows("sec.bitlockervolumes").Select(r => new BitLockerVolume(r.Text("DriveLetter") ?? r.Text("DeviceID") ?? "Volume non identifié", r.Int("ProtectionStatus"), r.Int("ConversionStatus"), r.Int("EncryptionMethod"), null, null))],
            Tpm = tpm is null ? null : new(tpm.Text("SpecVersion"), tpm.Bool("IsEnabled_InitialValue"), tpm.Bool("IsActivated_InitialValue"), tpm.Bool("IsOwned_InitialValue")),
            SecureBoot = guard is null ? null : new(null, null, guard.Int("VirtualizationBasedSecurityStatus") is >= 0 and <= 2 and var vbs ? vbs == 2 : null,
                guard.Has("SecurityServicesRunning") ? guard.Ints("SecurityServicesRunning").Contains(1) : null),
            Access = [.. access],
        };
        return store with { Data = data, DockHints = [.. Rows("hw.dockhints").Select(r => r.Text("Name")).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).Take(100)] };

        void Partial(string category)
        { var index = access.FindIndex(a => a.Category == category); if (index >= 0) { access[index] = access[index] with { Status = SourceStatus.Partial, Detail = "Certaines valeurs ne permettent pas une interprétation complète." }; } }
    }

    private static object? Value(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Null => null, JsonValueKind.String => value.GetString(), JsonValueKind.True => true, JsonValueKind.False => false,
        JsonValueKind.Number => value.TryGetInt64(out var signed) ? (object)signed : value.TryGetUInt64(out var unsigned) ? (object)unsigned : value.GetDouble(),
        JsonValueKind.Array => value.EnumerateArray().Select(Value).ToArray(), _ => null,
    };
}
