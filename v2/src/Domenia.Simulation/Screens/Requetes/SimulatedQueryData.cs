using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.CompilerServices;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Simulation;

/// <summary>
/// State of the query workshop for one simulated source, shared by its two readers (probes, collections, WMI): the probe
/// readings derived from the generated world (sub-stream « screen/requetes »), the readings renewed by an explicit collection
/// of this session, and the advanced SELECT results stored. Memory only; never written anywhere.
/// </summary>
internal sealed class SimulatedQueryState
{
    private static readonly ConditionalWeakTable<SimulatedDirectorySource, SimulatedQueryState> States = new();

    private readonly SimulatedDirectorySource source;
    private readonly Lazy<Derived> derived;
    private readonly Lock gate = new();
    private readonly Dictionary<Guid, Dictionary<string, ProbeReading>> collected = new();
    private readonly Dictionary<Guid, PresenceMeasure> presence = new();
    private readonly Dictionary<Guid, InventoryMeasure> inventory = new();
    private readonly Dictionary<Guid, ConsoleReading> console = new();
    private readonly Dictionary<Guid, List<StoredWmiResult>> details = new();
    private long version;
    private int rounds;

    private SimulatedQueryState(SimulatedDirectorySource source)
    {
        this.source = source;
        derived = new Lazy<Derived>(() => Derive(source), LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public static SimulatedQueryState For(SimulatedDirectorySource source) => States.GetValue(source, static s => new SimulatedQueryState(s));

    internal sealed record Derived(
        ImmutableDictionary<Guid, ImmutableArray<ProbeReading>> Probes,
        ImmutableDictionary<Guid, ConsoleReading> Console,
        ImmutableDictionary<Guid, char> BitLocker,
        ImmutableDictionary<Guid, ComputerProfile> Profiles);

    /// <summary>Hardware and software picture of one computer, from which every probe value and WMI instance is drawn.</summary>
    internal sealed record ComputerProfile(Guid Id, string Name, bool Laptop, bool Server, string Maker, string Model, long Memory, string Os, string Build, int ProductType, long DiskSize,
        long DiskFree, DateTimeOffset? Boot, int Cores, string Cpu, string Gpu, string User, bool Online, ulong Seed);

    public long Version
    {
        get
        {
            lock (gate)
            {
                return version;
            }
        }
    }

    public Derived Data => derived.Value;

    /// <summary>The dataset as the workshop reads it: base readings, then those renewed by the collections of the session.</summary>
    public QueryDataset Dataset()
    {
        var world = source.World;
        var data = derived.Value;
        lock (gate)
        {
            var probes = data.Probes;
            if (collected.Count > 0)
            {
                var builder = probes.ToBuilder();
                foreach (var (id, renewed) in collected)
                {
                    var merged = (probes.TryGetValue(id, out var existing) ? existing : []).ToDictionary(r => r.ProbeId, StringComparer.Ordinal);
                    foreach (var (probe, reading) in renewed)
                    {
                        merged[probe] = reading;
                    }
                    builder[id] = [.. merged.Values.OrderBy(r => r.ProbeId, StringComparer.Ordinal)];
                }
                probes = builder.ToImmutable();
            }
            var observations = world.Observations;
            if (presence.Count > 0 || inventory.Count > 0)
            {
                observations = observations with
                {
                    Workstations = [.. observations.Workstations.Select(o => o with
                    {
                        Presence = presence.GetValueOrDefault(o.ComputerGuid, o.Presence),
                        Inventory = inventory.GetValueOrDefault(o.ComputerGuid, o.Inventory),
                    })],
                };
            }
            var consoles = console.Count == 0 ? data.Console : data.Console.SetItems(console);
            var stored = details.ToImmutableDictionary(p => p.Key, p => p.Value.ToImmutableArray());
            return new QueryDataset(source.CurrentDirectory, observations, probes, consoles, data.BitLocker, stored, source.Overlay.Version * 1_000_000 + version,
                "Annuaire fictif de la simulation (aucune lecture réseau)", true);
        }
    }

    /// <summary>
    /// Explicit collection of the session: every planned enabled workstation is read again; the ones that never answer
    /// (inactive, ICMP filtered) or whose probes are always in error fail, and keep their earlier readings.
    /// </summary>
    public QueryMeasureResult Measure(QueryMeasureRequest request, DateTimeOffset now)
    {
        var world = source.World;
        var directory = source.CurrentDirectory;
        var data = derived.Value;
        int answered = 0, failed = 0, disabled = 0;
        lock (gate)
        {
            rounds++;
            var random = source.ScreenStream("requetes").Fork("measure/" + rounds.ToString(CultureInfo.InvariantCulture));
            var observations = world.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
            foreach (var id in request.Computers.Distinct())
            {
                var computer = directory.Computers.FirstOrDefault(c => c.ObjectGuid == id);
                if (computer is null)
                {
                    failed++;
                    continue;
                }
                if (AdValues.IsDisabled(computer.UserAccountControl))
                {
                    disabled++;
                    continue;
                }
                var reachable = !world.Presence.NeverAnswer.Contains(id) && !world.Presence.ErrorProbes.Contains(id) && random.Chance(88);
                if (request.Presence || request.Inventory || request.Probes.Length > 0 || request.Console || request.DetailReads.Length > 0)
                {
                    presence[id] = new PresenceMeasure(MeasureState.Known, reachable, now, reachable ? now : observations.GetValueOrDefault(id)?.Presence.LastOnlineAt);
                }
                if (!reachable)
                {
                    failed++;
                    if (request.Probes.Length > 0 && data.Profiles.ContainsKey(id))
                    {
                        var errors = collected.TryGetValue(id, out var existing) ? existing : collected[id] = new Dictionary<string, ProbeReading>(StringComparer.Ordinal);
                        foreach (var probe in request.Probes)
                        {
                            // The earlier reading stays usable; the failed attempt is only kept when nothing was ever read.
                            if (!errors.ContainsKey(probe) && !(data.Probes.TryGetValue(id, out var known) && known.Any(r => r.ProbeId == probe)))
                            {
                                errors[probe] = new ProbeReading(probe, now, "Poste injoignable au relevé", false, false, null, false, []);
                            }
                        }
                    }
                    continue;
                }
                answered++;
                if (!data.Profiles.TryGetValue(id, out var profile))
                {
                    profile = SimulatedQueryProbes.Profile(computer, observations.GetValueOrDefault(id), world, source.ScreenStream("requetes"));
                }
                if (request.Inventory && observations.TryGetValue(id, out var observation))
                {
                    var before = inventory.GetValueOrDefault(id, observation.Inventory);
                    inventory[id] = before.HasReading
                        ? before with { CheckedAt = now }
                        : new InventoryMeasure(MeasureState.Known, now, profile.DiskSize, profile.DiskFree, profile.Boot ?? now.AddDays(-2), profile.Model, profile.Memory, "Microsoft " + profile.Os, profile.Build);
                }
                if (request.Console)
                {
                    console[id] = new ConsoleReading(profile.User.Length > 0 ? profile.User : null, now, null);
                }
                if (request.Probes.Length > 0)
                {
                    var renewed = collected.TryGetValue(id, out var existing) ? existing : collected[id] = new Dictionary<string, ProbeReading>(StringComparer.Ordinal);
                    foreach (var probeId in request.Probes)
                    {
                        if (QueryProbeCatalog.Find(probeId) is { } probe)
                        {
                            renewed[probeId] = SimulatedQueryProbes.Reading(probe, profile, now, random.Fork(probeId), fresh: true);
                        }
                    }
                }
                foreach (var detail in request.DetailReads)
                {
                    // The SELECT saved with the recipe, read again on this workstation only (never an arbitrary WQL).
                    StoreLocked(id, ReadDetail(id, detail, now));
                }
            }
            version++;
            return new QueryMeasureResult(request.Computers.Length, answered, failed, disabled, source.Overlay.Version * 1_000_000 + version, now);
        }
    }

    /// <summary>Keeps the counts of an advanced SELECT run on a workstation (rows stay with the result shown).</summary>
    public void Store(Guid computer, StoredWmiResult result)
    {
        lock (gate)
        {
            StoreLocked(computer, result);
            version++;
        }
    }

    private void StoreLocked(Guid computer, StoredWmiResult result)
    {
        if (!details.TryGetValue(computer, out var list))
        {
            details[computer] = list = [];
        }
        list.RemoveAll(r => r.RequestKey == result.RequestKey);
        list.Add(result);
    }

    /// <summary>Stored counts of one saved SELECT on one simulated workstation (an absent class gives a failed reading).</summary>
    private StoredWmiResult ReadDetail(Guid computer, WmiReadDefinition detail, DateTimeOffset now)
    {
        var definition = SimulatedWmiCatalog.Find(detail.Namespace, detail.ClassName);
        if (definition is null)
        {
            return new StoredWmiResult(detail.RequestKey, now, false, 0, false, false);
        }
        WqlSelect select;
        try
        {
            select = WqlRules.Parse(detail.CanonicalQuery);
        }
        catch (QueryDefinitionException)
        {
            return new StoredWmiResult(detail.RequestKey, now, false, 0, false, false);
        }
        var count = SimulatedWmiCatalog.Instances(source, computer, definition).Count(i => WqlRules.Matches(select.Where, i));
        return new StoredWmiResult(detail.RequestKey, now, true, Math.Min(count, detail.Limit), count <= detail.Limit, count > detail.Limit);
    }

    public ComputerProfile? Profile(Guid id)
    {
        var data = derived.Value;
        if (data.Profiles.TryGetValue(id, out var profile))
        {
            return profile;
        }
        var computer = source.CurrentDirectory.Computers.FirstOrDefault(c => c.ObjectGuid == id);
        return computer is null ? null : SimulatedQueryProbes.Profile(computer, null, source.World, source.ScreenStream("requetes"));
    }

    private static Derived Derive(SimulatedDirectorySource source)
    {
        var world = source.World;
        var random = source.ScreenStream("requetes");
        var observations = world.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var probes = ImmutableDictionary.CreateBuilder<Guid, ImmutableArray<ProbeReading>>();
        var consoles = ImmutableDictionary.CreateBuilder<Guid, ConsoleReading>();
        var keys = ImmutableDictionary.CreateBuilder<Guid, char>();
        var profiles = ImmutableDictionary.CreateBuilder<Guid, ComputerProfile>();
        var keyStream = random.Fork("bitlocker");
        foreach (var computer in world.Directory.Computers)
        {
            observations.TryGetValue(computer.ObjectGuid, out var observation);
            var profile = SimulatedQueryProbes.Profile(computer, observation, world, random);
            profiles[computer.ObjectGuid] = profile;
            var draw = keyStream.Next(100);
            keys[computer.ObjectGuid] = draw < 86 ? 'K' : draw < 97 ? 'N' : 'X';
            if (observation?.Inventory.HasReading != true)
            {
                continue;
            }
            var stream = random.Fork("probes/" + computer.ObjectGuid.ToString("N"));
            var readAt = world.Reference - stream.Between(TimeSpan.FromHours(3), TimeSpan.FromDays(18));
            var readings = ImmutableArray.CreateBuilder<ProbeReading>();
            foreach (var probe in QueryProbeCatalog.All)
            {
                var p = stream.Fork(probe.Id);
                // About one probe in six was never collected on a workstation, and the event log probes on four in ten.
                if (p.Chance(probe.Id.StartsWith("evt.", StringComparison.Ordinal) ? 60 : 15))
                {
                    continue;
                }
                var at = readAt - p.Between(TimeSpan.Zero, TimeSpan.FromHours(probe.Slow ? 30 : 6));
                if (p.Chance(2))
                {
                    readings.Add(new ProbeReading(probe.Id, at, "Accès refusé par le fournisseur WMI", false, false, null, false, []));
                    continue;
                }
                readings.Add(SimulatedQueryProbes.Reading(probe, profile, at, p, fresh: false));
            }
            probes[computer.ObjectGuid] = readings.ToImmutable();
            if (observation.Presence.Answered == true && profile.User.Length > 0)
            {
                consoles[computer.ObjectGuid] = new ConsoleReading(profile.User, observation.Presence.CheckedAt, null);
            }
        }
        return new Derived(probes.ToImmutable(), consoles.ToImmutable(), keys.ToImmutable(), profiles.ToImmutable());
    }
}

/// <summary>Deterministic probe values and instances of a simulated computer (plausible raw provider values).</summary>
internal static class SimulatedQueryProbes
{
    private static readonly string[] Services = ["Spooler", "wuauserv", "WinRM", "BITS", "W32Time", "TermService", "MpsSvc", "WinDefend", "Dnscache", "LanmanWorkstation", "EventLog", "Schedule", "CryptSvc", "Netlogon"];
    private static readonly string[] ServiceNames = ["Spouleur d’impression", "Windows Update", "Gestion à distance de Windows (WinRM)", "Service de transfert intelligent en arrière-plan", "Temps Windows",
        "Services Bureau à distance", "Pare-feu Windows Defender", "Service antivirus Microsoft Defender", "Client DNS", "Station de travail", "Journal d’événements Windows", "Planificateur de tâches",
        "Services de chiffrement", "Accès réseau"];
    private static readonly string[] Programs = ["Microsoft Edge", "Microsoft 365 Apps for enterprise", "7-Zip 24.08 (x64)", "Adobe Acrobat Reader", "Google Chrome", "VLC media player", "Microsoft Teams", "Notepad++ (64-bit x64)"];
    private static readonly string[] Processes = ["System", "smss.exe", "csrss.exe", "wininit.exe", "services.exe", "lsass.exe", "svchost.exe", "explorer.exe", "msedge.exe", "MsMpEng.exe", "spoolsv.exe", "OUTLOOK.EXE"];

    public static SimulatedQueryState.ComputerProfile Profile(DirectoryComputer computer, WorkstationObservation? observation, SimulatedWorld world, SeededRandom stream)
    {
        var random = stream.Fork("profile/" + computer.ObjectGuid.ToString("N"));
        var server = (computer.OperatingSystem ?? "").Contains("Server", StringComparison.OrdinalIgnoreCase);
        var laptop = computer.Name.StartsWith("PT-", StringComparison.OrdinalIgnoreCase);
        var model = observation?.Inventory.Model ?? (server ? "VMware Virtual Platform" : random.Pick(laptop ? SimulationProfile.LaptopModels : SimulationProfile.DesktopModels));
        var maker = model.StartsWith("Dell", StringComparison.Ordinal) ? "Dell Inc." : model.StartsWith("HP", StringComparison.Ordinal) ? "HP" : model.StartsWith("Lenovo", StringComparison.Ordinal) ? "LENOVO" : "VMware, Inc.";
        var memory = observation?.Inventory.MemoryBytes ?? (server ? 32L << 30 : 16L << 30);
        var build = WindowsRelease.ParseBuild(computer.OperatingSystemVersion)?.ToString(CultureInfo.InvariantCulture) ?? "26100";
        var cores = server ? random.Pick(new[] { 4, 8, 16 }) : random.Pick(new[] { 4, 6, 8, 10, 12 });
        var cpu = server ? "Intel(R) Xeon(R) Silver 4314 CPU @ 2.40GHz"
            : maker == "LENOVO" ? random.Pick(new[] { "AMD Ryzen 5 PRO 7540U w/ Radeon 740M Graphics", "Intel(R) Core(TM) i5-1345U" })
            : random.Pick(new[] { "Intel(R) Core(TM) i5-1345U", "Intel(R) Core(TM) i7-1365U", "Intel(R) Core(TM) i5-13500" });
        var gpu = server ? "Carte vidéo de base Microsoft" : cpu.StartsWith("AMD", StringComparison.Ordinal) ? "AMD Radeon(TM) 740M Graphics" : laptop ? "Intel(R) Iris(R) Xe Graphics" : "Intel(R) UHD Graphics 770";
        var owner = computer.ManagedByDn is { } dn ? world.Directory.Users.FirstOrDefault(u => string.Equals(u.DistinguishedName, dn, StringComparison.OrdinalIgnoreCase))?.SamAccountName : null;
        var user = owner ?? (random.Chance(70) ? random.Pick(world.Directory.Users.Where(u => u.DistinguishedName.Contains("OU=Utilisateurs", StringComparison.Ordinal)).Select(u => u.SamAccountName).ToList()) : "");
        var size = observation?.Inventory.SystemDiskSizeBytes ?? 255_000_000_000L;
        var free = observation?.Inventory.SystemDiskFreeBytes ?? size / 2;
        var dc = computer.DistinguishedName.Contains("OU=Domain Controllers", StringComparison.OrdinalIgnoreCase);
        return new SimulatedQueryState.ComputerProfile(computer.ObjectGuid, computer.Name, laptop, server, maker, model, memory, computer.OperatingSystem ?? "Windows", build,
            dc ? 2 : server ? 3 : 1, size, free, observation?.Inventory.LastBootAt, cores, cpu, gpu, user.Length > 0 ? world.Directory.Domain.NetbiosName + "\\" + user : "",
            observation?.Presence.Answered == true, random.Seed);
    }

    private static string Cim(DateTimeOffset at) => at.UtcDateTime.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture) + ".000000+000";

    private static ProbeInstance Row(string probe, int index, params (string Name, object? Value)[] values) =>
        new(probe + ":" + index.ToString(CultureInfo.InvariantCulture), values.ToImmutableDictionary(v => v.Name, v => v.Value, StringComparer.OrdinalIgnoreCase), []);

    private static ProbeReading Count(QueryProbe probe, DateTimeOffset at, int count, Func<int, ProbeInstance>? row = null)
    {
        var rows = Enumerable.Range(0, Math.Min(count, 20)).Select(i => row?.Invoke(i) ?? Row(probe.Id, i, (probe.Properties[0], "Instance " + (i + 1).ToString(CultureInfo.InvariantCulture)))).ToImmutableArray();
        return new ProbeReading(probe.Id, at, null, false, count > 20, count, true, rows);
    }

    private static ProbeReading First(QueryProbe probe, DateTimeOffset at, params (string Name, object? Value)[] values) =>
        new(probe.Id, at, null, false, false, 1, true, [Row(probe.Id, 0, values)]);

    private static ProbeReading Many(QueryProbe probe, DateTimeOffset at, IReadOnlyList<ProbeInstance> rows) =>
        new(probe.Id, at, null, false, false, rows.Count, true, [.. rows]);

    private static ProbeReading None(QueryProbe probe, DateTimeOffset at) => new(probe.Id, at, null, false, false, 0, true, []);

    /// <summary>One reading of one probe on one computer at <paramref name="at"/>.</summary>
    public static ProbeReading Reading(QueryProbe probe, SimulatedQueryState.ComputerProfile c, DateTimeOffset at, SeededRandom r, bool fresh)
    {
        if (probe.SkipOnDc && c.ProductType == 2)
        {
            return new ProbeReading(probe.Id, at, null, true, false, null, false, []);
        }
        _ = fresh;
        var services = Services.Select((name, i) => (Name: name, Display: ServiceNames[i], Running: !(name == "Spooler" && c.Server) && !(name == "TermService" && !c.Server && r.Fork(name).Chance(60)) && !r.Fork("svc/" + name).Chance(4))).ToList();
        string Service(string name) => services.First(s => s.Name == name).Running ? "Running" : "Stopped";
        switch (probe.Id)
        {
            case "hw.maker": return First(probe, at, ("Manufacturer", c.Maker));
            case "hw.model": return First(probe, at, ("Model", c.Model));
            case "hw.ram": return First(probe, at, ("TotalPhysicalMemory", (decimal)(c.Memory - r.Next(200, 900) * 1048576L)));
            case "hw.cpu": return First(probe, at, ("Name", c.Cpu));
            case "hw.cpuload": return First(probe, at, ("LoadPercentage", (decimal)(r.Chance(5) ? r.Next(81, 100) : r.Next(1, 45))));
            case "hw.cpumhz": return First(probe, at, ("MaxClockSpeed", (decimal)(c.Server ? 2400 : r.Pick(new[] { 1600, 1700, 2500, 3300 }))));
            case "hw.virtualization": return First(probe, at, ("VirtualizationFirmwareEnabled", !r.Chance(8)));
            case "hw.slat": return First(probe, at, ("SecondLevelAddressTranslationExtensions", !r.Chance(4)));
            case "hw.batterylevel": return c.Laptop ? First(probe, at, ("EstimatedChargeRemaining", (decimal)(r.Chance(10) ? r.Next(3, 20) : r.Next(35, 101)))) : None(probe, at);
            case "hw.cores": return First(probe, at, ("NumberOfCores", (decimal)c.Cores));
            case "hw.threads": return First(probe, at, ("NumberOfLogicalProcessors", (decimal)(c.Cores * 2)));
            case "hw.bios": return First(probe, at, ("SMBIOSBIOSVersion", c.Maker == "Dell Inc." ? "1." + r.Next(8, 25).ToString(CultureInfo.InvariantCulture) + ".0" : "N3" + r.Next(10, 99).ToString(CultureInfo.InvariantCulture) + "ET" + r.Next(40, 80).ToString(CultureInfo.InvariantCulture) + "W"));
            case "hw.biosyear": return First(probe, at, ("ReleaseDate", Cim(new DateTimeOffset(r.Next(2018, 2026), r.Next(1, 13), r.Next(1, 28), 0, 0, 0, TimeSpan.Zero))));
            case "hw.gpu": return First(probe, at, ("Name", c.Gpu));
            case "hw.screens": return Count(probe, at, c.Server ? 0 : c.Laptop ? r.Next(1, 3) : r.Next(1, 4), i => Row(probe.Id, i, ("InstanceName", "DISPLAY\\DEL41" + i.ToString(CultureInfo.InvariantCulture) + "A\\5&1a2b3c&0&UID" + i.ToString(CultureInfo.InvariantCulture))));
            case "hw.battery": return Count(probe, at, c.Laptop ? 1 : 0, i => Row(probe.Id, i, ("Name", "Batterie principale")));
            case "hw.chassis": return First(probe, at, ("PCSystemTypeEx", (decimal)(c.Server ? 4 : c.Laptop ? 2 : 1)));
            case "hw.serialmissing": return First(probe, at, ("SerialNumber", r.Chance(2) ? "To Be Filled By O.E.M." : "5CG" + r.Next(1000000, 9999999).ToString(CultureInfo.InvariantCulture)));
            case "os.caption": return First(probe, at, ("Caption", "Microsoft " + c.Os));
            case "os.release": return First(probe, at, ("BuildNumber", c.Build), ("ProductType", (decimal)c.ProductType));
            case "os.arch": return First(probe, at, ("OSArchitecture", r.Chance(1) ? "32 bits" : "64 bits"));
            case "os.uptime": return c.Boot is DateTimeOffset boot ? First(probe, at, ("LastBootUpTime", Cim(boot))) : First(probe, at, ("LastBootUpTime", Cim(at.AddDays(-r.Next(1, 9)))));
            case "os.installyear": return First(probe, at, ("InstallDate", Cim(new DateTimeOffset(r.Next(2019, 2026), r.Next(1, 13), r.Next(1, 28), 9, 0, 0, TimeSpan.Zero))));
            case "os.lang": return First(probe, at, ("OSLanguage", (decimal)(r.Chance(5) ? 1033 : 1036)));
            case "os.tz": return First(probe, at, ("Caption", "(UTC+01:00) Bruxelles, Copenhague, Madrid, Paris"));
            case "os.pagefile": return First(probe, at, ("AllocatedBaseSize", (decimal)r.Pick(new[] { 2048, 4096, 8192, 16384 })));
            case "os.freeram": return First(probe, at, ("FreePhysicalMemory", (decimal)(c.Memory / 1024 * r.Next(8, 60) / 100)));
            case "os.virtualfree": return First(probe, at, ("FreeVirtualMemory", (decimal)(c.Memory / 1024 * r.Next(20, 90) / 100)));
            case "os.visiblememory": return First(probe, at, ("TotalVisibleMemorySize", (decimal)(c.Memory / 1024 - r.Next(100000, 400000))));
            case "os.users": return First(probe, at, ("NumberOfUsers", (decimal)(c.Server ? r.Next(0, 4) : r.Next(0, 3))));
            case "os.producttype": return First(probe, at, ("ProductType", (decimal)c.ProductType));
            case "disk.cfree": return First(probe, at, ("FreeSpace", (decimal)c.DiskFree), ("Size", (decimal)c.DiskSize));
            case "disk.csize": return First(probe, at, ("Size", (decimal)c.DiskSize));
            case "disk.count": return Count(probe, at, r.Chance(80) ? 1 : 2, i => Row(probe.Id, i, ("DeviceID", i == 0 ? "C:" : "D:")));
            case "disk.media": return First(probe, at, ("MediaType", (decimal)(c.Server ? 0 : r.Chance(87) ? 4 : 3)));
            case "disk.health": return First(probe, at, ("HealthStatus", (decimal)(r.Chance(96) ? 0 : r.Chance(70) ? 1 : 2)));
            case "disk.removable": return Count(probe, at, r.Chance(90) ? 0 : 1, i => Row(probe.Id, i, ("DeviceID", "E:")));
            case "sec.bitlocker": return First(probe, at, ("ProtectionStatus", (decimal)(c.Server ? 0 : r.Chance(86) ? 1 : r.Chance(85) ? 0 : 2)));
            case "sec.av": return Many(probe, at, [Row(probe.Id, 0, ("displayName", "Microsoft Defender Antivirus"))]);
            case "sec.localusers": return Count(probe, at, r.Chance(85) ? r.Next(1, 3) : r.Next(4, 7), i => Row(probe.Id, i, ("Name", i == 0 ? "Administrateur" : "support" + i.ToString(CultureInfo.InvariantCulture))));
            case "sec.shares": return Count(probe, at, c.Server ? r.Next(1, 6) : r.Chance(85) ? 0 : 1, i => Row(probe.Id, i, ("Name", "Partage" + i.ToString(CultureInfo.InvariantCulture))));
            case "sec.defender": return First(probe, at, ("AntivirusEnabled", !r.Chance(4)));
            case "sec.realtime": return First(probe, at, ("RealTimeProtectionEnabled", !r.Chance(4)));
            case "sec.behavior": return First(probe, at, ("BehaviorMonitorEnabled", !r.Chance(5)));
            case "sec.signatures": return First(probe, at, ("AntivirusSignatureAge", (decimal)(r.Chance(6) ? r.Next(4, 20) : r.Next(0, 3))));
            case "sec.quickscan": return First(probe, at, ("QuickScanAge", (decimal)(r.Chance(10) ? r.Next(8, 40) : r.Next(0, 7))));
            case "sec.fullscan": return First(probe, at, ("FullScanAge", (decimal)(r.Chance(55) ? 65535 : r.Next(0, 120))));
            case "sec.defenderversion": return First(probe, at, ("AMProductVersion", "4.18.25070." + r.Next(1, 9).ToString(CultureInfo.InvariantCulture)));
            case "sec.tpmversion": return First(probe, at, ("SpecVersion", r.Chance(3) ? "1.2, 2, 3" : "2.0, 0, 1.59"));
            case "sec.tpmenabled": return First(probe, at, ("IsEnabled_InitialValue", !r.Chance(2)));
            case "sec.tpmactivated": return First(probe, at, ("IsActivated_InitialValue", !r.Chance(3)));
            case "net.adapter": return Many(probe, at, [Row(probe.Id, 0, ("Name", c.Laptop && r.Chance(40) ? "Intel(R) Wi-Fi 6E AX211 160MHz" : "Intel(R) Ethernet Connection (17) I219-LM"))]);
            case "net.speed": return First(probe, at, ("Speed", (decimal)(r.Chance(5) ? 100_000_000L : c.Server ? 10_000_000_000L : 1_000_000_000L)));
            case "net.dhcp": return First(probe, at, ("DHCPEnabled", !c.Server && !r.Chance(4)));
            case "net.dns": return First(probe, at, ("DNSServerSearchOrder", "10.10.0.10"));
            case "net.gateway": return First(probe, at, ("DefaultIPGateway", "10.10." + r.Next(1, 30).ToString(CultureInfo.InvariantCulture) + ".1"));
            case "net.wifi": return Count(probe, at, c.Laptop && r.Chance(45) ? 1 : 0, i => Row(probe.Id, i, ("Name", "Wi-Fi")));
            case "soft.printers": return Count(probe, at, r.Next(2, 9), i => Row(probe.Id, i, ("Name", i == 0 ? "Microsoft Print to PDF" : "IMP-" + r.Next(1, 40).ToString("00", CultureInfo.InvariantCulture))));
            case "soft.defaultprinter": return First(probe, at, ("Name", "IMP-" + c.Name.Split('-').Skip(1).FirstOrDefault() + "-0" + r.Next(1, 6).ToString(CultureInfo.InvariantCulture)));
            case "soft.startup": return Count(probe, at, r.Next(3, 15));
            case "soft.stoppedauto": return Count(probe, at, services.Count(s => !s.Running && s.Name is not ("Spooler" or "TermService")) + (r.Chance(15) ? 1 : 0));
            case "soft.running": return Count(probe, at, r.Next(80, 141));
            case "soft.spooler": return First(probe, at, ("State", Service("Spooler")));
            case "soft.wuauserv": return First(probe, at, ("State", Service("wuauserv")));
            case "soft.winrm": return First(probe, at, ("State", Service("WinRM")));
            case "soft.bits": return First(probe, at, ("State", Service("BITS")));
            case "soft.w32time": return First(probe, at, ("State", Service("W32Time")));
            case "soft.rdp": return First(probe, at, ("State", Service("TermService")));
            case "soft.firewall": return First(probe, at, ("State", Service("MpsSvc")));
            case "soft.defender": return First(probe, at, ("State", Service("WinDefend")));
            case "soft.dnsclient": return First(probe, at, ("State", Service("Dnscache")));
            case "soft.hotfixcount": return Count(probe, at, r.Next(5, 31));
            case "soft.processes": return Count(probe, at, r.Chance(4) ? r.Next(201, 260) : r.Next(110, 200));
            case "user.console": return c.User.Length > 0 ? First(probe, at, ("UserName", c.User)) : None(probe, at);
            case "user.profiles": return Count(probe, at, r.Chance(8) ? r.Next(11, 18) : r.Next(1, 8));
            case "user.sessions": return Count(probe, at, c.Online ? r.Next(1, 3) : 0);
            case "evt.syserrors": return Count(probe, at, r.Chance(65) ? 0 : r.Next(1, 16));
            case "evt.unexpected": return Count(probe, at, r.Chance(90) ? 0 : 1);
            case "soft.servicedetails":
                return Many(probe, at, [.. services.Select((s, i) => Row(probe.Id, i, ("Name", s.Name), ("DisplayName", s.Display), ("State", s.Running ? "Running" : "Stopped"),
                    ("StartMode", s.Name is "BITS" or "TermService" ? "Manual" : "Auto"), ("ExitCode", 0m), ("ProcessId", s.Running ? (decimal)(1000 + i * 37) : 0m)))]);
            case "disk.volumes":
                return Many(probe, at, [Row(probe.Id, 0, ("DeviceID", "C:"), ("VolumeName", "Windows"), ("FileSystem", "NTFS"), ("Size", (decimal)c.DiskSize), ("FreeSpace", (decimal)c.DiskFree))]);
            case "soft.installed":
                return Many(probe, at, [.. Programs.Where((_, i) => i < 3 || r.Fork("program/" + i.ToString(CultureInfo.InvariantCulture)).Chance(55)).Select((name, i) => Row(probe.Id, i, ("ProgramId", "{" + Guid.Empty.ToString("D")[..^2] + i.ToString("00", CultureInfo.InvariantCulture) + "}"), ("Name", name), ("Vendor", name.Split(' ')[0]), ("Version", r.Next(1, 130).ToString(CultureInfo.InvariantCulture) + ".0")))]);
            case "soft.processdetails":
                return Many(probe, at, [.. Processes.Select((name, i) => Row(probe.Id, i, ("Name", name), ("ProcessId", (decimal)(i == 0 ? 4 : 400 + i * 52)), ("ParentProcessId", (decimal)(i < 2 ? 0 : 4)),
                    ("WorkingSetSize", (decimal)(r.Next(2, 400) * 1048576L)), ("ThreadCount", (decimal)r.Next(2, 60)), ("HandleCount", (decimal)r.Next(50, 3000)), ("CreationDate", Cim(c.Boot ?? at.AddDays(-1)))))]);
            case "hw.processors":
                return Many(probe, at, [Row(probe.Id, 0, ("Name", c.Cpu), ("DeviceID", "CPU0"), ("Manufacturer", c.Cpu.StartsWith("AMD", StringComparison.Ordinal) ? "AuthenticAMD" : "GenuineIntel"), ("Architecture", 9m),
                    ("NumberOfCores", (decimal)c.Cores), ("NumberOfLogicalProcessors", (decimal)(c.Cores * 2)), ("MaxClockSpeed", 2500m), ("VirtualizationFirmwareEnabled", true), ("SecondLevelAddressTranslationExtensions", true), ("LoadPercentage", (decimal)r.Next(1, 40)))]);
            case "sec.bitlockervolumes":
                return Many(probe, at, [Row(probe.Id, 0, ("DriveLetter", "C:"), ("DeviceID", "\\\\?\\Volume{" + c.Id.ToString("D") + "}\\"), ("PersistentVolumeID", ""), ("ProtectionStatus", c.Server ? 0m : 1m), ("ConversionStatus", c.Server ? 0m : 1m), ("EncryptionMethod", c.Server ? 0m : 7m))]);
        }
        // Other catalog probes: plausible values drawn from the declared CIM type of each property.
        var count = probe.Mode == "First" ? 1 : probe.Mode == "Count" ? r.Next(0, 6) : r.Next(1, 4);
        var rows = Enumerable.Range(0, count).Select(i => new ProbeInstance(probe.Id + ":" + i.ToString(CultureInfo.InvariantCulture),
            probe.Fields.Where(f => probe.Properties.Contains(f.Name)).ToImmutableDictionary(f => f.Name, f => Value(f, i, r.Fork(f.Name + "/" + i.ToString(CultureInfo.InvariantCulture)), at), StringComparer.OrdinalIgnoreCase), [])).ToImmutableArray();
        return new ProbeReading(probe.Id, at, null, false, false, count, true, rows);
    }

    private static object? Value(QueryProbeField field, int index, SeededRandom r, DateTimeOffset at)
    {
        if (field.IsArray)
        {
            return field.CimType.StartsWith("string", StringComparison.Ordinal) ? "10.10." + r.Next(1, 30).ToString(CultureInfo.InvariantCulture) + "." + r.Next(2, 250).ToString(CultureInfo.InvariantCulture) : r.Next(0, 4).ToString(CultureInfo.InvariantCulture);
        }
        return field.CimType switch
        {
            "boolean" => !r.Chance(10),
            "datetime" => Cim(at.AddDays(-r.Next(1, 400))),
            "string" => field.Name switch
            {
                "Name" or "FriendlyName" or "DeviceName" => field.Name + " " + (index + 1).ToString(CultureInfo.InvariantCulture),
                "DeviceID" or "DeviceId" or "InstanceName" or "Tag" => "ID" + index.ToString(CultureInfo.InvariantCulture),
                "Manufacturer" or "ManufactureName" or "Vendor" => r.Pick(new[] { "Samsung", "SK hynix", "Kingston", "Micron" }),
                "SerialNumber" => r.Next(10000000, 99999999).ToString(CultureInfo.InvariantCulture),
                "Status" => "OK",
                _ => field.Name + " " + (index + 1).ToString(CultureInfo.InvariantCulture),
            },
            _ => (decimal)r.Next(0, field.Unit is "octets" ? int.MaxValue : 100),
        };
    }
}
