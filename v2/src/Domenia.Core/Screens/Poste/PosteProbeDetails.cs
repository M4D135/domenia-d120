using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>
/// Details of one probe of a workstation (Domenia 1 Show-DomeniaProbeDetails, improved as a side panel): only the stored
/// families of the probe for the computer, its contract (catalog), the raw values of the last success, 100 rows a page and
/// the provenance. Never queries the workstation. An old row without a known column keeps « Valeur n ». Pure.
/// </summary>
public static class PosteProbeDetails
{
    public const int PageSize = 100;

    public static ProbeDetailsResult Build(ProbeStore store, ProbeInfo probe, int page, TimeZoneInfo zone, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(probe);
        ArgumentNullException.ThrowIfNull(zone);
        var status = store.Probes.FirstOrDefault(p => p.ProbeId == probe.Id) ?? new ProbeStatus(probe.Id, ProbeState.NotRead, null, null, null, 0);
        var columns = probe.Properties;
        var exact = store.Values.GetValueOrDefault(probe.Id);
        var all = exact is not null ? exact.Rows.Select(row => row.Select(PosteProbeCache.Display).ToArray()).ToList()
            : store.Data is null || status.State is not (ProbeState.Read or ProbeState.Partial) ? [] : Rows(probe, store.Data, columns).ToList();
        var pages = Math.Max(1, (int)Math.Ceiling(all.Count / (double)PageSize));
        var current = Math.Clamp(page, 1, pages);
        var shown = all.Skip((current - 1) * PageSize).Take(PageSize).Select(r => r.ToImmutableArray()).ToImmutableArray();
        var provenance = status.LastSuccess is DateTimeOffset at
            ? "Dernière réussite le " + PosteText.LocalDateTime(at, zone) + " (" + PosteText.Age(at, now) + ")" + (status.LastAttempt is DateTimeOffset attempt && attempt > at ? " · dernière tentative le " + PosteText.LocalDateTime(attempt, zone) : "") + " · " + probe.Namespace + "\\" + probe.Class
            : status.LastAttempt is DateTimeOffset tried ? "Dernière tentative le " + PosteText.LocalDateTime(tried, zone) + " sans réussite · " + probe.Namespace + "\\" + probe.Class : "Jamais relevée pour ce poste";
        if (exact is not null)
        { provenance = "Données " + (exact.Complete ? "complètes" : "partielles") + " du " + PosteText.LocalDateTime(exact.At, zone) + " · " + provenance; }
        var reading = PosteReadings.Catalog.FirstOrDefault(r => r.Probes.Contains(probe.Id)).Id;
        var interpreted = reading is null
            ? ImmutableArray<PosteFact>.Empty
            : PosteReadings.Build(store with { Probes = [.. store.Probes.Where(p => p.ProbeId == probe.Id)] }, PosteHealthPolicy.Default, [], now, zone).Readings.First(r => r.Id == reading).Facts;
        return new ProbeDetailsResult(probe, status, PosteReadings.ProbeStateLabel(status.State), columns, shown, current, pages, all.Count, provenance, interpreted);
    }

    private static string? N(long? v) => v?.ToString(CultureInfo.InvariantCulture);

    private static string? N(int? v) => v?.ToString(CultureInfo.InvariantCulture);

    private static string? N(double? v) => v?.ToString(CultureInfo.InvariantCulture);

    private static string? B(bool? v) => v switch { true => "True", false => "False", _ => null };

    private static string? D(DateTimeOffset? v) => v?.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);

    /// <summary>Raw values of the stored data, in the order of the catalog properties; a property not kept stays null.</summary>
    private static IEnumerable<string?[]> Rows(ProbeInfo probe, InventorySnapshot d, ImmutableArray<string> columns)
    {
        IEnumerable<Dictionary<string, string?>> bags = probe.Id switch
        {
            "hw.memorymodules" => d.MemoryModules.Select(m => new Dictionary<string, string?> { ["DeviceLocator"] = m.Slot, ["Capacity"] = N(m.CapacityBytes), ["Manufacturer"] = m.Manufacturer, ["PartNumber"] = m.PartNumber, ["ConfiguredClockSpeed"] = N(m.SpeedMhz) }),
            "hw.memoryarrays" => d.MemoryArray is { } a ? [new() { ["MemoryDevices"] = N(a.Slots), ["MaxCapacityEx"] = N(a.MaxCapacityBytes / 1024), ["Use"] = "3" }] : [],
            "hw.memoryusage" => d.Memory is { } u ? [new() { ["TotalVisibleMemorySize"] = N(u.VisibleKb), ["FreePhysicalMemory"] = N(u.FreeKb) }] : [],
            "disk.volumes" => d.Volumes.Select(v => new Dictionary<string, string?> { ["DeviceID"] = v.Id, ["VolumeName"] = v.Label, ["FileSystem"] = v.FileSystem, ["Size"] = N(v.SizeBytes), ["FreeSpace"] = N(v.FreeBytes) }),
            "disk.physical" => d.PhysicalDisks.Select(p => new Dictionary<string, string?> { ["FriendlyName"] = p.Name, ["DeviceId"] = p.Id, ["MediaType"] = N(p.MediaType), ["BusType"] = N(p.BusType), ["HealthStatus"] = N(p.Health), ["Size"] = N(p.SizeBytes) }),
            "disk.reliability" => d.PhysicalDisks.Select(p => new Dictionary<string, string?> { ["DeviceId"] = p.Id, ["Temperature"] = N(p.TemperatureCelsius), ["Wear"] = N(p.WearPercent), ["PowerOnHours"] = N(p.PowerOnHours), ["ReadErrorsUncorrected"] = N(p.UncorrectedErrors) }),
            "hw.batteries" => d.Batteries.Select(b => new Dictionary<string, string?> { ["Name"] = b.Name, ["EstimatedChargeRemaining"] = N(b.ChargePercent), ["BatteryStatus"] = N(b.Status) }),
            "hw.batterystatic" => d.Batteries.Select(b => new Dictionary<string, string?> { ["DeviceName"] = b.Name, ["DesignedCapacity"] = N(b.DesignedCapacity) }),
            "hw.batteryfullcharge" => d.Batteries.Select(b => new Dictionary<string, string?> { ["FullChargedCapacity"] = N(b.FullChargeCapacity) }),
            "hw.batterycycles" => d.Batteries.Select(b => new Dictionary<string, string?> { ["CycleCount"] = N(b.Cycles) }),
            "hw.biosdetails" => d.Bios is { } bios ? [new() { ["SMBIOSBIOSVersion"] = bios.Version, ["Manufacturer"] = bios.Manufacturer, ["ReleaseDate"] = D(bios.ReleaseDate), ["SerialNumber"] = d.System?.SerialNumber }] : [],
            "hw.computersystem" => d.System is { } s ? [new() { ["Model"] = s.Model, ["Manufacturer"] = s.Manufacturer, ["NumberOfLogicalProcessors"] = N(s.LogicalProcessors), ["TotalPhysicalMemory"] = N(s.TotalPhysicalMemory), ["PCSystemTypeEx"] = N(s.PcSystemType), ["HypervisorPresent"] = B(s.Hypervisor is null ? null : true) }] : [],
            "hw.processors" => d.Processors.Select((p, i) => new Dictionary<string, string?> { ["Name"] = p.Name, ["NumberOfCores"] = N(p.Cores), ["NumberOfLogicalProcessors"] = N(p.LogicalProcessors), ["MaxClockSpeed"] = N(p.MaxClockMhz), ["VirtualizationFirmwareEnabled"] = B(p.VirtualizationFirmware), ["LoadPercentage"] = N(p.LoadPercent) }),
            "hw.monitors" => d.Displays.Select(m => new Dictionary<string, string?> { ["UserFriendlyName"] = m.Name, ["ManufacturerName"] = m.Manufacturer, ["ProductCodeID"] = m.Product, ["SerialNumberID"] = m.Serial, ["YearOfManufacture"] = N(m.Year) }),
            "hw.monitorconnections" => d.Displays.Select(m => new Dictionary<string, string?> { ["VideoOutputTechnology"] = m.Connection }),
            "net.interfaces" => d.Network.Select(n => new Dictionary<string, string?> { ["Name"] = n.Name, ["NetConnectionStatus"] = N(n.Status), ["PhysicalAdapter"] = B(n.Physical), ["MACAddress"] = n.Mac, ["Speed"] = N(n.SpeedBitsPerSecond) }),
            "net.configurations" => d.Network.Where(n => n.Ipv4.Length > 0).Select(n => new Dictionary<string, string?> { ["Description"] = n.Name, ["MACAddress"] = n.Mac, ["IPAddress"] = string.Join(", ", n.Ipv4), ["DefaultIPGateway"] = n.Gateway, ["DNSServerSearchOrder"] = string.Join(", ", n.Dns), ["DHCPEnabled"] = B(n.Dhcp) }),
            "soft.printerdetails" => d.Printers.Select(p => new Dictionary<string, string?> { ["Name"] = p.Name, ["DriverName"] = p.Driver, ["PortName"] = p.Port, ["WorkOffline"] = B(p.Offline), ["Default"] = B(p.Default), ["Network"] = B(p.Network) }),
            "hw.deviceerrors" => d.Devices.Select(x => new Dictionary<string, string?> { ["Name"] = x.Name, ["PNPClass"] = x.Class, ["ConfigManagerErrorCode"] = N(x.Code) }),
            "soft.servicedetails" => d.Services.Select(s => new Dictionary<string, string?> { ["Name"] = s.Name, ["DisplayName"] = s.DisplayName, ["State"] = s.State, ["StartMode"] = s.StartMode, ["ExitCode"] = N(s.ExitCode), ["ProcessId"] = N(s.ProcessId) }),
            "soft.hotfixdetails" => d.Hotfixes.Select(h => new Dictionary<string, string?> { ["HotFixID"] = h.Id, ["Description"] = h.Description, ["InstalledOn"] = h.InstalledOn?.ToString("M'/'d'/'yyyy", CultureInfo.InvariantCulture) }),
            "soft.processdetails" => d.Processes.Select(p => new Dictionary<string, string?> { ["Name"] = p.Name, ["ProcessId"] = N(p.Id), ["WorkingSetSize"] = N(p.WorkingSetBytes), ["CreationDate"] = D(p.StartedAt) }),
            "soft.scheduledtasks" => d.Tasks.Select(t => new Dictionary<string, string?> { ["TaskName"] = t.Name, ["TaskPath"] = t.Path, ["State"] = t.State, ["Author"] = t.Author }),
            "soft.startupdetails" => d.Startup.Select(s => new Dictionary<string, string?> { ["Name"] = s.Name, ["Location"] = s.Location, ["User"] = s.User }),
            "soft.installed" => d.Software.Select(s => new Dictionary<string, string?> { ["Name"] = s.Name, ["Vendor"] = s.Publisher, ["Version"] = s.Version }),
            "sec.defenderdetails" => d.Defender is { } def ? [new() { ["AMProductVersion"] = def.Version, ["AntivirusEnabled"] = B(def.AntivirusEnabled), ["RealTimeProtectionEnabled"] = B(def.RealTime), ["BehaviorMonitorEnabled"] = B(def.Behavior) }] : [],
            "sec.firewallprofiles" => d.Firewall.Select(p => new Dictionary<string, string?> { ["Name"] = p.Name, ["Enabled"] = B(p.EffectiveEnabled) }),
            "sec.deviceguard" => d.SecureBoot is { } sb ? [new() { ["VirtualizationBasedSecurityStatus"] = sb.VbsRunning switch { true => "2", false => "0", _ => null } }] : [],
            "sec.bitlockervolumes" => d.BitLocker.Select(v => new Dictionary<string, string?> { ["DriveLetter"] = v.Drive, ["ProtectionStatus"] = N(v.Protection), ["ConversionStatus"] = N(v.Conversion), ["EncryptionMethod"] = N(v.Method) }),
            "sec.tpmdetails" => d.Tpm is { } tpm ? [new() { ["SpecVersion"] = tpm.Specification, ["IsEnabled_InitialValue"] = B(tpm.Enabled), ["IsActivated_InitialValue"] = B(tpm.Activated), ["IsOwned_InitialValue"] = B(tpm.Owned) }] : [],
            "net.connectionprofiles" => d.Network.Where(n => n.Profile is not null).Select(n => new Dictionary<string, string?> { ["InterfaceAlias"] = n.Name, ["NetworkCategory"] = n.Profile }),
            "sec.avproducts" => d.Antivirus.Select(a => new Dictionary<string, string?> { ["displayName"] = a.Name, ["productState"] = N(a.ProductState), ["timestamp"] = D(a.Timestamp) }),
            _ => [],
        };
        foreach (var bag in bags)
        {
            yield return [.. columns.Select(c => bag.TryGetValue(c, out var v) ? v : null)];
        }
    }
}
