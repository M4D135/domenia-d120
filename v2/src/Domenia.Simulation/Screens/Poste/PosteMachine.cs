using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Simulation.Poste;

/// <summary>Why a fictitious workstation is slow, when it is (one cause each, chosen by the seed).</summary>
internal enum SlowCause
{
    None,
    Memory,
    Cpu,
    Disk,
    Hdd,
    Startup,
}

/// <summary>
/// One fictitious workstation, derived once from the generated directory, its stored observation and the screen sub-stream
/// « screen/poste/&lt;guid&gt; » (docs/PLATFORM.md § 4): hardware, system, software, services and the points it carries. Pure
/// data; <see cref="Snapshot"/> turns it into what an inventory would read at a given time.
/// </summary>
internal sealed record PosteMachine
{
    public required DirectoryComputer Computer { get; init; }
    public required string Site { get; init; }
    public required string SiteCode { get; init; }
    public required bool Laptop { get; init; }
    public required SimModel Model { get; init; }
    public required string Serial { get; init; }
    public required long MemoryBytes { get; init; }
    public required ImmutableArray<MemoryModule> Modules { get; init; }
    public required int Slots { get; init; }
    public required long DiskSize { get; init; }
    public required long DiskFree { get; init; }
    public required int MediaType { get; init; }
    public required int BusType { get; init; }
    public required string DiskName { get; init; }
    public required int? DiskHealth { get; init; }
    public required double? Wear { get; init; }
    public required double Temperature { get; init; }
    public required long PowerOnHours { get; init; }
    public required long Uncorrected { get; init; }
    public required (long Size, long Free)? DataVolume { get; init; }
    public required string BiosVersion { get; init; }
    public required DateTimeOffset BiosDate { get; init; }
    public required bool? SecureBoot { get; init; }
    public required int BitLockerProtection { get; init; }
    public required int BitLockerConversion { get; init; }
    public required string Mac { get; init; }
    public required string Ip { get; init; }
    public required int Prefix { get; init; }
    public required string Gateway { get; init; }
    public required long LinkSpeed { get; init; }
    public required bool FirewallPublicOff { get; init; }
    public required int SignatureAge { get; init; }
    public required ImmutableArray<Hotfix> Hotfixes { get; init; }
    public required bool Wapt { get; init; }
    public required DateTimeOffset WaptLast { get; init; }
    public required ImmutableArray<SoftwareEntry> Software { get; init; }
    public required ImmutableArray<StartupEntry> Startup { get; init; }
    public required ImmutableArray<ServiceEntry> Services { get; init; }
    public required ImmutableArray<DeviceError> Devices { get; init; }
    public required ImmutableArray<DisplayInfo> Displays { get; init; }
    public required BatteryInfo? Battery { get; init; }
    public required ImmutableArray<DriverInfo> UnsignedDrivers { get; init; }
    public required ImmutableArray<ShareInfo> Shares { get; init; }
    public required ImmutableArray<PrinterInfo> Printers { get; init; }
    public required PendingReboot Reboot { get; init; }
    public required int ClockSkew { get; init; }
    public required string? Proxy { get; init; }
    public required ImmutableArray<EventEntry> Events { get; init; }
    public required ImmutableArray<TaskEntry> Tasks { get; init; }
    public required ImmutableArray<CertificateEntry> Certificates { get; init; }
    public required DateTimeOffset LastBoot { get; init; }
    public required DateTimeOffset InstallDate { get; init; }
    public required string Caption { get; init; }
    public required string Build { get; init; }
    public required int Revision { get; init; }
    public required SlowCause Slow { get; init; }
    public required double BaseMemoryUse { get; init; }
    public required UserRef? User { get; init; }
    public required AssociationBadge Badge { get; init; }
    public required string Department { get; init; }
    public required ImmutableArray<string> RefusedSources { get; init; }
    public required ImmutableArray<MonitorChange> MonitorHistory { get; init; }
    public required ImmutableArray<VolumeSample> VolumeHistory { get; init; }
    public required ImmutableArray<string> DockHints { get; init; }
    public required ulong Seed { get; init; }

    public string Dn => Computer.DistinguishedName;

    public string DnsName => Computer.DnsHostName ?? Computer.Name.ToLowerInvariant() + "." + SimulationProfile.DnsName;

    /// <summary>
    /// What an inventory reads at <paramref name="at"/>: the fixed data, the live values drawn from <paramref name="live"/>
    /// (memory, processor load, processes), the session overrides (service states, last boot), quick or full.
    /// </summary>
    public InventorySnapshot Snapshot(DateTimeOffset at, bool deep, SeededRandom live, IReadOnlyDictionary<string, string> serviceStates, DateTimeOffset? bootOverride, bool sessionsOpen)
    {
        var boot = bootOverride ?? LastBoot;
        var used = Math.Clamp(BaseMemoryUse + (live.NextDouble() - 0.5) * 8, 18, 99);
        var visibleKb = MemoryBytes / 1024 - 196_608;
        var freeKb = (long)(visibleKb * (100 - used) / 100);
        var cpuLoad = Slow == SlowCause.Cpu ? live.Next(88, 100) : live.Next(2, 38);
        var access = ImmutableArray.CreateBuilder<SourceAccess>();
        var categories = deep ? InventoryCategories.Quick.AddRange(InventoryCategories.DeepOnly) : InventoryCategories.Quick;
        var services = Services.Select(s => serviceStates.TryGetValue(s.Name, out var state) ? s with { State = state, ProcessId = state == "Running" ? s.ProcessId ?? 4000 + live.Next(1, 9000) : null } : s).ToImmutableArray();
        var processes = deep ? Processes(live, sessionsOpen) : [];
        var events = deep ? Events.Where(e => e.At >= at.AddDays(-14) && e.At <= at).ToImmutableArray() : [];
        foreach (var category in categories)
        {
            var refused = RefusedSources.Contains(category);
            var items = refused ? 0 : CountOf(category, services, processes, events);
            var status = refused ? SourceStatus.Refused : items == 0 ? SourceStatus.Empty : SourceStatus.Ok;
            var detail = refused ? "Accès refusé (0x80070005) pour ce compte" : status == SourceStatus.Empty ? "Lu, rien trouvé" : FrenchText.Count(items, "élément", "éléments");
            access.Add(new SourceAccess(category, status, detail, live.Next(40, refused ? 400 : 2400), items, InventoryTransport.Dcom));
        }
        bool Read(string category) => !RefusedSources.Contains(category);
        var adapters = Laptop
            ? ImmutableArray.Create(
                new NetworkAdapter("Intel(R) Wi-Fi 6E AX211 160MHz", 2, 866_700_000, Mac, true, true, [Ip], Prefix, Gateway, ["10.10.0.10", "10.20.0.10"], true, "DomainAuthenticated"),
                new NetworkAdapter("Intel(R) Ethernet Connection (16) I219-LM", 7, null, AlterMac(Mac, 1), true, false, [], null, null, [], true, null),
                new NetworkAdapter("Bluetooth Device (Personal Area Network)", 7, null, AlterMac(Mac, 2), true, true, [], null, null, [], true, null))
            : ImmutableArray.Create(
                new NetworkAdapter("Intel(R) Ethernet Connection (17) I219-LM", 2, LinkSpeed, Mac, true, false, [Ip], Prefix, Gateway, ["10.10.0.10", "10.20.0.10"], true, "DomainAuthenticated"),
                new NetworkAdapter("WAN Miniport (IP)", 2, null, null, false, false, [], null, null, [], null, null));
        var console = sessionsOpen && User is not null ? SimulationProfile.NetbiosName + "\\" + User.Login : null;
        return new InventorySnapshot(
            Computer.Name,
            at,
            deep,
            deep ? live.Next(96_000, 148_000) : live.Next(31_000, 54_000),
            InventoryTransport.Dcom,
            access.ToImmutable(),
            new OsInfo(Caption, "10.0." + Build, Build, Revision, "64 bits", 1036, InstallDate, boot, 1, SimulationProfile.DnsName, at.AddSeconds(ClockSkew)),
            new SystemInfo(Model.Maker, Model.Model, Serial, [Model.Chassis], Laptop ? 2 : 1, MemoryBytes - 268_435_456, Model.Threads, null, console),
            new BiosInfo(BiosVersion, BiosDate, "3.5", Model.Firmware, Model.Maker),
            [new CpuInfo(Model.Cpu, Model.Cores, Model.Threads, Model.MaxMhz, cpuLoad, "x64", true, true)],
            Modules,
            new MemoryArrayInfo(Slots, Laptop ? 64L * 1024 * 1024 * 1024 : 128L * 1024 * 1024 * 1024),
            new MemoryUsage(visibleKb, freeKb),
            DataVolume is { } data
                ? [new LogicalDisk("C:", "Windows", "NTFS", DiskSize, DiskFree), new LogicalDisk("D:", "Données", "NTFS", data.Size, data.Free)]
                : [new LogicalDisk("C:", "Windows", "NTFS", DiskSize, DiskFree)],
            [new PhysicalDisk("0", DiskName, MediaType, BusType, DiskSize + 1_000_000_000, DiskHealth, Wear, Temperature, PowerOnHours, Uncorrected, DiskHealth switch { 0 => "OK", 1 => "Pred Fail", 2 => "Bad", _ => "Unknown" })],
            Read(InventoryCategories.BitLocker) ? [new BitLockerVolume("C:", BitLockerProtection, BitLockerConversion, BitLockerConversion == 1 ? 7 : 0, BitLockerConversion == 1 ? 100 : 0, BitLockerConversion == 1 ? 2 : 0)] : [],
            new TpmInfo("2.0, 0, 1.59", true, true, true),
            new SecureBootInfo(SecureBoot, Model.Firmware, SecureBoot == true, false),
            adapters,
            Read(InventoryCategories.Firewall)
                ? [
                    new FirewallProfile("Domaine", true, true, ["Réseau du domaine " + SimulationProfile.DnsName]),
                    new FirewallProfile("Privé", true, true, []),
                    new FirewallProfile("Public", true, FirewallPublicOff ? false : true, []),
                ]
                : [],
            Read(InventoryCategories.Antivirus) ? [new AntivirusProduct("Microsoft Defender Antivirus", SignatureAge > 7 ? 397584 : 397568, at.AddHours(-live.Next(1, 30)))] : [],
            Read(InventoryCategories.Antivirus) ? new DefenderStatus(true, true, true, SignatureAge, live.Next(0, 6), live.Next(4, 30), "4.18.25090.3009", false, Slow == SlowCause.Cpu) : null,
            Hotfixes,
            new UpdateConfig("http://wsus.example.local:8530", true, "WSUS (stratégie de groupe)", Hotfixes.IsEmpty ? null : Hotfixes.Max(h => h.InstalledOn), "Succeeded", Wapt, Wapt ? WaptLast : null, Wapt ? "OK" : null),
            [.. Software.Where(s => s.Scope == "Machine").Select(s => s with { Publisher = null, InstallDate = null, SizeBytes = null, Location = null, Uninstall = null, Source = "Inventaire rapide" })],
            Startup,
            services,
            Devices,
            Displays,
            Battery is null ? [] : [Battery with { ChargePercent = Math.Clamp((Battery.ChargePercent ?? 80) + live.Next(-6, 7), 4, 100) }],
            UnsignedDrivers,
            sessionsOpen && User is not null
                ? [new LocalSession("1", "Console", User.Login, SimulationProfile.NetbiosName, "Active", "Console", boot.AddMinutes(live.Next(2, 40)), TimeSpan.FromMinutes(live.Next(0, 25)), null)]
                : [],
            ["Administrateur", SimulationProfile.NetbiosName + "\\Admins du domaine", SimulationProfile.NetbiosName + "\\GG-Admins-Postes"],
            Shares,
            Printers,
            Reboot,
            ClockSkew,
            true,
            Site,
            Proxy,
            processes,
            events,
            deep ? Tasks : [],
            deep ? Certificates : [],
            deep
                ? [
                    new ConnectionEntry("TCP", Ip + ":49812", "10.10.0.21:445", "Établie", "System"),
                    new ConnectionEntry("TCP", Ip + ":49820", "10.10.0.10:389", "Établie", "lsass.exe"),
                    new ConnectionEntry("TCP", Ip + ":50311", "10.0.0.40:443", "Établie", "ms-teams.exe"),
                    new ConnectionEntry("TCP", "0.0.0.0:3389", "0.0.0.0:0", "Écoute", "svchost.exe"),
                ]
                : []);
    }

    private int CountOf(string category, ImmutableArray<ServiceEntry> services, ImmutableArray<ProcessEntry> processes, ImmutableArray<EventEntry> events) => category switch
    {
        InventoryCategories.Software => Software.Count(s => s.Scope == "Machine"),
        InventoryCategories.Startup => Startup.Length,
        InventoryCategories.Services => services.Length,
        InventoryCategories.Devices => Devices.Length,
        InventoryCategories.Displays => Displays.Length,
        InventoryCategories.Batteries => Battery is null ? 0 : 1,
        InventoryCategories.Drivers => UnsignedDrivers.Length,
        InventoryCategories.Shares => Shares.Length,
        InventoryCategories.Printers => Printers.Length,
        InventoryCategories.Hotfixes => Hotfixes.Length,
        InventoryCategories.Processes => processes.Length,
        InventoryCategories.Events => events.Length,
        InventoryCategories.Tasks => Tasks.Length,
        InventoryCategories.Certificates => Certificates.Length,
        InventoryCategories.Memory => Modules.Length,
        InventoryCategories.Volumes => DataVolume is null ? 1 : 2,
        InventoryCategories.Reboot => Reboot.Confirmed.Length + Reboot.Partial.Length,
        InventoryCategories.Admins => 3,
        InventoryCategories.Network => Laptop ? 3 : 2,
        InventoryCategories.Firewall => 3,
        _ => 1,
    };

    /// <summary>Processes at one reading: the usual ones, heavier on a workstation slowed by its memory or processor.</summary>
    public ImmutableArray<ProcessEntry> Processes(SeededRandom live, bool sessionsOpen)
    {
        var list = ImmutableArray.CreateBuilder<ProcessEntry>();
        var pid = 4;
        var heavy = Slow == SlowCause.Memory ? 2.6 : 1.0;
        foreach (var p in PosteCatalogs.Processes)
        {
            if (p.User && !sessionsOpen)
            {
                continue;
            }
            if (p.Name is "chrome.exe" && !Software.Any(s => s.Name.StartsWith("Google Chrome", StringComparison.Ordinal)))
            {
                continue;
            }
            var mb = live.Next(p.MinMb, p.MaxMb + 1) * (p.User && p.CpuWeight >= 4 ? heavy : 1.0);
            var cpu = live.Next(1, 40) * p.CpuWeight * 0.9 + (Slow == SlowCause.Cpu && p.Name == "MsMpEng.exe" ? 9000 : 0);
            list.Add(new ProcessEntry(pid, p.Name, (long)(mb * 1048576), Math.Round(cpu, 2), p.User ? User?.Login : "SYSTEM", LastBoot.AddMinutes(p.User ? live.Next(3, 300) : live.Next(0, 3))));
            pid += live.Next(4, 900) * 4;
        }
        if (Slow == SlowCause.Cpu)
        {
            list.Add(new ProcessEntry(pid + 8, "TiWorker.exe", 260L * 1048576, 4200, "SYSTEM", LastBoot.AddHours(2)));
        }
        return list.ToImmutable();
    }

    private static string AlterMac(string mac, int delta)
    {
        var last = Convert.ToInt32(mac[^2..], 16);
        return mac[..^2] + ((last + delta) % 256).ToString("X2", CultureInfo.InvariantCulture);
    }
}
