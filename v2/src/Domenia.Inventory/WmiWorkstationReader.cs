using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>
/// What one read of a workstation covers. Each scope has the budget the operator is told before it starts
/// (docs/ops/poste.md § 8.3) and reads only the sources of that scope; the others stay « non lus », never empty.
/// </summary>
public enum WorkstationReading
{
    /// <summary>Live state (10 s): uptime, console account, sessions.</summary>
    Live,

    /// <summary>Quick inventory (55 s): system, hardware, disks, BitLocker, TPM, network, protection, updates, services.</summary>
    Quick,

    /// <summary>Full inventory (150 s): the quick one plus processes and system events.</summary>
    Full,

    /// <summary>Services alone (90 s, 500 instances at most).</summary>
    Services,

    /// <summary>Processes alone (two reads of Win32_Process spaced by 1 s, 20 s).</summary>
    Processes,

    /// <summary>System events alone (30 s).</summary>
    Events,

    /// <summary>Windows Update alone (correctifs and the state of the update source).</summary>
    Updates,
}

/// <summary>
/// Real workstation readings of the directory mode (docs/ops/poste.md § 8.2): the CIM classes of the workstation read by
/// projections only, turned into the one typed model of the console, <see cref="InventorySnapshot"/>. The workstation
/// console and the relations screen both use it: the console for its inventories, services, processes, sessions and events,
/// the relations screen for the account at the console of a workstation.
/// <para>
/// Read only by construction. No method of any CIM class is invoked — not <c>StartService</c>, not <c>ChangeStartMode</c>,
/// not <c>Reboot</c>: a service is read, never started, and the remote actions of the console belong to the write circuit
/// (docs/WRITES.md). Every source is bounded by its own delay inside the budget of the reading, answers with a
/// <see cref="SourceStatus"/>, and is emptied when it did not answer, so nothing unread is ever displayed.
/// </para>
/// <para>
/// The registry sources of § 8.2 (Secure Boot, WSUS, keys of reboot pending) go through <c>StdRegProv</c>, which is a method
/// call: they are not part of this reader yet, and the categories they feed stay « non lues » rather than guessed.
/// </para>
/// </summary>
public sealed class WmiWorkstationReader
{
    private const string Cimv2 = @"root\cimv2";
    private const string StorageNamespace = @"root\Microsoft\Windows\Storage";
    private const string BitLockerNamespace = @"root\cimv2\Security\MicrosoftVolumeEncryption";
    private const string TpmNamespace = @"root\cimv2\Security\MicrosoftTpm";
    private const string SecurityCenter = @"root\SecurityCenter2";

    private const string OperatingSystemQuery =
        "SELECT Caption, Version, BuildNumber, OSLanguage, OSArchitecture, InstallDate, LastBootUpTime, LocalDateTime FROM Win32_OperatingSystem";

    private const string ComputerSystemQuery =
        "SELECT Name, Domain, Manufacturer, Model, TotalPhysicalMemory, NumberOfLogicalProcessors, UserName, DomainRole, SystemType FROM Win32_ComputerSystem";

    private const string EnclosureQuery = "SELECT SerialNumber, ChassisTypes FROM Win32_SystemEnclosure";

    private const string ProcessQuery =
        "SELECT ProcessId, Name, CreationDate, KernelModeTime, UserModeTime, WorkingSetSize FROM Win32_Process WHERE ProcessId <> 0";

    private readonly TimeProvider clock;
    private readonly ITechnicalJournal? journal;

    /// <summary>Contacts nothing: a workstation is only reached by an explicit read.</summary>
    public WmiWorkstationReader(TimeProvider clock, ITechnicalJournal? journal = null)
    {
        ArgumentNullException.ThrowIfNull(clock);
        this.clock = clock;
        this.journal = journal;
    }

    /// <summary>
    /// One bounded reading of one workstation, off the UI thread. A stop or the budget gives a partial result (the sources
    /// not reached are « Interrompu »), never a loss; a workstation that refuses answers « Refusé », which is not an error.
    /// </summary>
    public async Task<InventorySnapshot> ReadAsync(string host, WorkstationReading reading, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (!CimQuery.IsHostName(host))
        {
            journal?.Warning("Lecture du poste non faite : nom de poste invalide.");
            return Unread(host, reading, "nom de poste invalide");
        }

        var budget = Budget(reading);
        var work = Task.Run(() => Read(host, reading, progress, cancellationToken), cancellationToken);
        try
        {
            return await work.WaitAsync(budget + CimBudgets.GiveUpMargin, clock, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // The WMI calls end by their own delays; the outcome of the abandoned read is observed here, never left unseen.
            _ = work.ContinueWith(
                static completed => _ = completed.Exception,
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
            journal?.Info("Lecture de " + host + " abandonnée : budget dépassé (" + reading + ").");
            return Unread(host, reading, "budget de la lecture dépassé");
        }
    }

    /// <summary>
    /// The account at the console of one workstation (REL-021, « Lire la session de ce poste »): one instance of
    /// <c>Win32_ComputerSystem</c>, read once, in 4 s, with no fallback and no scheduled task. Null when the name cannot
    /// even be used; otherwise the status says whether the workstation answered, refused or stayed silent. The name the
    /// workstation calls itself is returned with the account: the caller refuses the reading when it differs from the
    /// name of the directory.
    /// </summary>
    public async Task<ConsoleAccountReading?> ReadConsoleAccountAsync(string host, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (!CimQuery.IsHostName(host))
        {
            return null;
        }

        var work = Task.Run(() =>
        {
            var session = new CimSession(host, CimBudgets.ConsoleSession, clock, journal);
            var reading = session.Read(InventoryCategories.System, Cimv2, "SELECT Name, UserName FROM Win32_ComputerSystem", 1, CimBudgets.ConsoleSession);
            var instance = reading.Instances.FirstOrDefault();
            return new ConsoleAccountReading(host, reading.Status, instance?.Text("UserName"), instance?.Text("Name"));
        }, cancellationToken);
        try
        {
            return await work.WaitAsync(CimBudgets.ConsoleSession + CimBudgets.GiveUpMargin, clock, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            journal?.Info("Session de " + host + " non lue : délai dépassé.");
            return new ConsoleAccountReading(host, SourceStatus.Interrupted, null, null);
        }
    }

    /// <summary>Budget announced to the operator for one scope (docs/ops/poste.md § 8.3).</summary>
    public static TimeSpan Budget(WorkstationReading reading) => reading switch
    {
        WorkstationReading.Live => CimBudgets.Live,
        WorkstationReading.Quick => CimBudgets.QuickInventory,
        WorkstationReading.Full => CimBudgets.FullInventory,
        WorkstationReading.Services => CimBudgets.Services,
        WorkstationReading.Processes => CimBudgets.Processes,
        WorkstationReading.Events => CimBudgets.Events,
        _ => CimBudgets.QuickInventory,
    };

    /// <summary>Sources this scope reads, in reading order; the others are said « non lues », never left blank.</summary>
    public static IReadOnlyList<string> Categories(WorkstationReading reading)
    {
        var categories = new List<string>();
        foreach (var step in Steps(reading))
        {
            if (!categories.Contains(step.Category, StringComparer.Ordinal))
            {
                categories.Add(step.Category);
            }
        }

        return categories;
    }

    /// <summary>Everything not read by this scope, said as such (the workstation was never reached).</summary>
    private InventorySnapshot Unread(string host, WorkstationReading reading, string detail)
    {
        var access = Categories(reading)
            .Select(category => new SourceAccess(category, SourceStatus.Unreachable, detail, 0, 0, InventoryTransport.Dcom))
            .ToImmutableArray();
        return Empty(host, clock.GetUtcNow(), reading == WorkstationReading.Full, InventoryTransport.Dcom) with { Access = access };
    }

    private InventorySnapshot Read(string host, WorkstationReading reading, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        var started = clock.GetTimestamp();
        var session = new CimSession(host, Budget(reading), clock, journal);
        var access = new List<SourceAccess>();
        var snapshot = Empty(host, clock.GetUtcNow(), reading == WorkstationReading.Full, session.Transport);
        var plan = Steps(reading);
        for (var index = 0; index < plan.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            progress?.Report(new PosteProgress(index, plan.Count, plan[index].Label));
            snapshot = plan[index].Run(session, snapshot, access, cancellationToken);
        }

        progress?.Report(new PosteProgress(plan.Count, plan.Count, "Lecture terminée"));
        return snapshot with { DurationMs = (int)clock.GetElapsedTime(started).TotalMilliseconds, Access = [.. access] };
    }

    /// <summary>The sources of one scope, in reading order (Domenia 1 worker order, quick first and deep last).</summary>
    private static List<Step> Steps(WorkstationReading reading) => reading switch
    {
        WorkstationReading.Live =>
        [
            new(InventoryCategories.System, "Système", static (session, current, access, token) => ReadSystem(session, current, access, token)),
            new(InventoryCategories.Sessions, "Sessions", static (session, current, access, token) => ReadSessions(session, current, access, token)),
        ],
        WorkstationReading.Services => [new(InventoryCategories.Services, "Services", static (session, current, access, token) => ReadServices(session, current, access, token))],
        WorkstationReading.Processes => [new(InventoryCategories.Processes, "Processus", static (session, current, access, token) => ReadProcesses(session, current, access, token))],
        WorkstationReading.Events => [new(InventoryCategories.Events, "Événements système", static (session, current, access, token) => ReadEvents(session, current, access, token))],
        WorkstationReading.Updates =>
        [
            new(InventoryCategories.Hotfixes, "Correctifs", static (session, current, access, token) => ReadHotfixes(session, current, access, token)),
            new(InventoryCategories.Updates, "Mises à jour", static (session, current, access, token) => ReadUpdateSource(session, current, access, token)),
        ],
        _ =>
        [
            new(InventoryCategories.System, "Système", static (session, current, access, token) => ReadSystem(session, current, access, token)),
            new(InventoryCategories.Bios, "BIOS et démarrage", static (session, current, access, token) => ReadBios(session, current, access, token)),
            new(InventoryCategories.Processor, "Processeur", static (session, current, access, token) => ReadProcessors(session, current, access, token)),
            new(InventoryCategories.Memory, "Mémoire", static (session, current, access, token) => ReadMemory(session, current, access, token)),
            new(InventoryCategories.Volumes, "Disques logiques", static (session, current, access, token) => ReadVolumes(session, current, access, token)),
            new(InventoryCategories.PhysicalDisks, "Disques physiques", static (session, current, access, token) => ReadPhysicalDisks(session, current, access, token)),
            new(InventoryCategories.BitLocker, "BitLocker", static (session, current, access, token) => ReadBitLocker(session, current, access, token)),
            new(InventoryCategories.Tpm, "TPM", static (session, current, access, token) => ReadTpm(session, current, access, token)),
            new(InventoryCategories.Network, "Cartes réseau", static (session, current, access, token) => ReadNetwork(session, current, access, token)),
            new(InventoryCategories.Antivirus, "Antivirus", static (session, current, access, token) => ReadAntivirus(session, current, access, token)),
            new(InventoryCategories.Hotfixes, "Correctifs", static (session, current, access, token) => ReadHotfixes(session, current, access, token)),
            new(InventoryCategories.Updates, "Mises à jour", static (session, current, access, token) => ReadUpdateSource(session, current, access, token)),
            new(InventoryCategories.Services, "Services", static (session, current, access, token) => ReadServices(session, current, access, token)),
            new(InventoryCategories.Sessions, "Sessions", static (session, current, access, token) => ReadSessions(session, current, access, token)),
            .. reading == WorkstationReading.Full
                ? new[]
                {
                    new Step(InventoryCategories.Processes, "Processus", static (session, current, access, token) => ReadProcesses(session, current, access, token)),
                    new Step(InventoryCategories.Events, "Événements système", static (session, current, access, token) => ReadEvents(session, current, access, token)),
                }
                : [],
        ],
    };

    /// <summary>
    /// One line of the access report for one category, whatever the number of queries it took: the category answered when
    /// at least one of its queries answered, and the worst outcome of its queries is the one the operator is told.
    /// </summary>
    private static void AddAccess(List<SourceAccess> access, CimSession session, string category, params CimReading[] readings)
    {
        ArgumentNullException.ThrowIfNull(readings);
        if (readings.Length == 0)
        {
            access.Add(new SourceAccess(category, SourceStatus.Skipped, "source non demandée", 0, 0, session.Transport));
            return;
        }

        var duration = readings.Sum(r => r.DurationMs);
        var items = readings.Sum(r => r.Items);
        var answered = readings.Count(r => r.Answered);
        var status = answered switch
        {
            0 => Worst(readings),
            var count when count < readings.Length => SourceStatus.Partial,
            var count when count == readings.Length && readings.Any(r => r.Status == SourceStatus.Partial) => SourceStatus.Partial,
            _ => items == 0 ? SourceStatus.Empty : SourceStatus.Ok,
        };
        var detail = answered == 0
            ? readings[0].Detail
            : answered + " requête(s) sur " + readings.Length + ", " + FrenchText.Integer(items) + " instance(s)";
        access.Add(new SourceAccess(category, status, detail, duration, items, session.Transport));
    }

    private static SourceStatus Worst(CimReading[] readings)
    {
        foreach (var status in new[] { SourceStatus.Refused, SourceStatus.Unreachable, SourceStatus.Interrupted, SourceStatus.Error })
        {
            if (readings.Any(r => r.Status == status))
            {
                return status;
            }
        }

        return readings[0].Status;
    }

    // ------------------------------------------------------------------ collectors

    private static InventorySnapshot ReadSystem(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var operating = session.Read(InventoryCategories.System, Cimv2, OperatingSystemQuery, 1, CimBudgets.Query);
        var computer = session.Read(InventoryCategories.System, Cimv2, ComputerSystemQuery, 1, CimBudgets.Query);
        var enclosure = session.Read(InventoryCategories.System, Cimv2, EnclosureQuery, 4, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.System, operating, computer, enclosure);
        if (!operating.Answered && !computer.Answered)
        {
            return current with { Os = null, System = null, Memory = null };
        }

        var os = operating.Instances.FirstOrDefault();
        var cs = computer.Instances.FirstOrDefault();
        var chassis = enclosure.Answered ? enclosure.Instances.SelectMany(i => i.Ints("ChassisTypes")).ToArray() : [];
        var serial = enclosure.Instances.FirstOrDefault()?.Text("SerialNumber");
        token.ThrowIfCancellationRequested();
        return current with
        {
            Os = os is null && cs is null
                ? null
                : new OsInfo(
                    os?.Text("Caption") ?? "",
                    os?.Text("Version") ?? "",
                    os?.Text("BuildNumber") ?? "",
                    null,
                    os?.Text("OSArchitecture") ?? cs?.Text("SystemType") ?? "",
                    os?.Int("OSLanguage"),
                    os?.Dmtf("InstallDate"),
                    os?.Dmtf("LastBootUpTime"),
                    cs?.Int("DomainRole"),
                    cs?.Text("Domain"),
                    os?.Dmtf("LocalDateTime")),
            System = cs is null && chassis.Length == 0
                ? null
                : new SystemInfo(
                    cs?.Text("Manufacturer") ?? "",
                    cs?.Text("Model") ?? "",
                    serial,
                    [.. chassis],
                    cs?.Int("DomainRole"),
                    cs?.Number("TotalPhysicalMemory"),
                    cs?.Int("NumberOfLogicalProcessors"),
                    null,
                    cs?.Text("UserName")),
            Memory = os is null ? null : new MemoryUsage(os.Number("TotalVisibleMemorySize"), os.Number("FreePhysicalMemory")),
        };
    }

    private static InventorySnapshot ReadBios(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var reading = session.Read(InventoryCategories.Bios, Cimv2, "SELECT Manufacturer, BIOSVersion, SMBIOSBIOSVersion, ReleaseDate FROM Win32_BIOS", 1, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Bios, reading);
        if (!reading.Answered)
        {
            return current with { Bios = null };
        }

        var bios = reading.Instances.FirstOrDefault();
        token.ThrowIfCancellationRequested();
        return current with
        {
            Bios = new BiosInfo(
                bios is null ? "" : string.Join(" / ", bios.Strings("BIOSVersion")),
                bios?.Dmtf("ReleaseDate"),
                bios?.Text("SMBIOSBIOSVersion"),
                null,
                bios?.Text("Manufacturer")),
            // Secure Boot and the firmware type live in the registry (StdRegProv): not read here, so not shown.
            SecureBoot = null,
        };
    }

    private static InventorySnapshot ReadProcessors(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var reading = session.Read(InventoryCategories.Processor, Cimv2, "SELECT Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, LoadPercentage, Architecture, VirtualizationFirmwareEnabled FROM Win32_Processor", 16, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Processor, reading);
        if (!reading.Answered)
        {
            return current with { Processors = [] };
        }

        token.ThrowIfCancellationRequested();
        return current with
        {
            Processors = [.. reading.Instances.Select(i => new CpuInfo(
                i.Text("Name") ?? "",
                i.Int("NumberOfCores"),
                i.Int("NumberOfLogicalProcessors"),
                i.Int("MaxClockSpeed"),
                i.Int("LoadPercentage"),
                i.Text("Architecture"),
                i.Bool("VirtualizationFirmwareEnabled"),
                null))],
        };
    }

    private static InventorySnapshot ReadMemory(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var modules = session.Read(InventoryCategories.Memory, Cimv2, "SELECT DeviceLocator, Capacity, Speed, Manufacturer, PartNumber FROM Win32_PhysicalMemory", 64, CimBudgets.Query);
        var arrays = session.Read(InventoryCategories.Memory, Cimv2, "SELECT Use, MemoryDevices, MaxCapacityEx FROM Win32_PhysicalMemoryArray", 8, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Memory, modules, arrays);
        if (!modules.Answered && !arrays.Answered)
        {
            return current with { MemoryModules = [], MemoryArray = null };
        }

        // Only system memory arrays count (Use 3): a video, flash or NVRAM array declares no RAM slot (Domenia 1 point 81).
        var system = arrays.Answered ? arrays.Instances.Where(a => a.Int("Use") is null or 3).ToList() : [];
        var slots = system.Count > 0 && system.All(a => a.Int("MemoryDevices") > 0) ? system.Sum(a => a.Int("MemoryDevices") ?? 0) : (int?)null;
        var maximum = system.Count > 0 && system.All(a => a.Number("MaxCapacityEx") > 0) ? system.Sum(a => a.Number("MaxCapacityEx") ?? 0) * 1024L : (long?)null;
        token.ThrowIfCancellationRequested();
        return current with
        {
            MemoryModules = [.. modules.Answered
                ? modules.Instances.Select(m => new MemoryModule(m.Text("DeviceLocator") ?? "", m.Number("Capacity"), m.Int("Speed"), m.Text("Manufacturer"), m.Text("PartNumber")))
                : []],
            MemoryArray = system.Count == 0 ? null : new MemoryArrayInfo(slots, maximum),
        };
    }

    private static InventorySnapshot ReadVolumes(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var reading = session.Read(InventoryCategories.Volumes, Cimv2, "SELECT DeviceID, VolumeName, FileSystem, Size, FreeSpace FROM Win32_LogicalDisk WHERE DriveType=3", 32, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Volumes, reading);
        if (!reading.Answered)
        {
            return current with { Volumes = [] };
        }

        token.ThrowIfCancellationRequested();
        // A size of 0 or unreadable is « no reading », never a full disk.
        return current with
        {
            Volumes = [.. reading.Instances
                .Where(d => d.Number("Size") > 0)
                .Select(d => new LogicalDisk(d.Text("DeviceID") ?? "", d.Text("VolumeName"), d.Text("FileSystem"), d.Number("Size"), d.Number("FreeSpace")))],
        };
    }

    private static InventorySnapshot ReadPhysicalDisks(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var physical = session.Read(InventoryCategories.PhysicalDisks, StorageNamespace, "SELECT DeviceId, FriendlyName, MediaType, HealthStatus, Size FROM MSFT_PhysicalDisk", 32, CimBudgets.Query);
        var counters = session.Read(InventoryCategories.PhysicalDisks, StorageNamespace, "SELECT DeviceId, Temperature, PowerOnHours, Wear, ReadErrorsUncorrected, WriteErrorsUncorrected FROM MSFT_StorageReliabilityCounter", 32, CimBudgets.Query);
        var smart = session.Read(InventoryCategories.PhysicalDisks, Cimv2, "SELECT DeviceID, Model, Size, InterfaceType, Status FROM Win32_DiskDrive", 32, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.PhysicalDisks, physical, counters, smart);
        if (!physical.Answered && !smart.Answered)
        {
            return current with { PhysicalDisks = [] };
        }

        token.ThrowIfCancellationRequested();
        if (physical.Answered)
        {
            var byId = counters.Answered
                ? counters.Instances.GroupBy(c => c.Text("DeviceId") ?? "").ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, WmiInstance>(StringComparer.OrdinalIgnoreCase);
            return current with
            {
                PhysicalDisks = [.. physical.Instances.Select(d =>
                {
                    var id = d.Text("DeviceId") ?? "";
                    byId.TryGetValue(id, out var counter);
                    return new PhysicalDisk(
                        id,
                        d.Text("FriendlyName") ?? "",
                        d.Int("MediaType"),
                        null,
                        d.Number("Size"),
                        d.Int("HealthStatus"),
                        counter?.Number("Wear") is long wear ? wear : null,
                        counter?.Number("Temperature") is long temperature ? temperature : null,
                        counter?.Number("PowerOnHours"),
                        (counter?.Number("ReadErrorsUncorrected") ?? 0) + (counter?.Number("WriteErrorsUncorrected") ?? 0),
                        null);
                })],
            };
        }

        // Without the Storage provider, the SMART status of Win32_DiskDrive is all the workstation gives.
        return current with
        {
            PhysicalDisks = [.. smart.Instances.Select(d => new PhysicalDisk(
                d.Text("DeviceID") ?? "",
                d.Text("Model") ?? "",
                null,
                null,
                d.Number("Size"),
                null,
                null,
                null,
                null,
                null,
                d.Text("Status")))],
        };
    }

    private static InventorySnapshot ReadBitLocker(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        // Properties only: the encrypted percentage and the protector count would need a method call, which this reader never makes.
        var reading = session.Read(InventoryCategories.BitLocker, BitLockerNamespace, "SELECT DriveLetter, ProtectionStatus, ConversionStatus, EncryptionMethod FROM Win32_EncryptableVolume", 32, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.BitLocker, reading);
        if (!reading.Answered)
        {
            return current with { BitLocker = [] };
        }

        token.ThrowIfCancellationRequested();
        return current with
        {
            BitLocker = [.. reading.Instances.Select(v => new BitLockerVolume(
                v.Text("DriveLetter") ?? "",
                v.Int("ProtectionStatus"),
                v.Int("ConversionStatus"),
                v.Int("EncryptionMethod"),
                null,
                null))],
        };
    }

    private static InventorySnapshot ReadTpm(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var reading = session.Read(InventoryCategories.Tpm, TpmNamespace, "SELECT IsEnabled_InitialValue, IsActivated_InitialValue, IsOwned_InitialValue, SpecVersion FROM Win32_Tpm", 1, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Tpm, reading);
        if (!reading.Answered)
        {
            return current with { Tpm = null };
        }

        token.ThrowIfCancellationRequested();
        var tpm = reading.Instances.FirstOrDefault();
        return current with
        {
            Tpm = tpm is null ? null : new TpmInfo(tpm.Text("SpecVersion"), tpm.Bool("IsEnabled_InitialValue"), tpm.Bool("IsActivated_InitialValue"), tpm.Bool("IsOwned_InitialValue")),
        };
    }

    private static InventorySnapshot ReadNetwork(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var adapters = session.Read(InventoryCategories.Network, Cimv2, "SELECT Name, NetConnectionStatus, Speed, MACAddress FROM Win32_NetworkAdapter WHERE PhysicalAdapter=True", 32, CimBudgets.Query);
        var configurations = session.Read(InventoryCategories.Network, Cimv2, "SELECT Description, MACAddress, IPAddress, IPSubnet, DefaultIPGateway, DNSServerSearchOrder, DHCPEnabled FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=True", 32, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Network, adapters, configurations);
        if (!adapters.Answered && !configurations.Answered)
        {
            return current with { Network = [] };
        }

        var byMac = new Dictionary<string, WmiInstance>(StringComparer.OrdinalIgnoreCase);
        if (configurations.Answered)
        {
            foreach (var configuration in configurations.Instances)
            {
                if (configuration.Text("MACAddress") is { Length: > 0 } mac)
                {
                    byMac[mac] = configuration;
                }
            }
        }

        var rows = new List<NetworkAdapter>();
        if (adapters.Answered)
        {
            foreach (var adapter in adapters.Instances)
            {
                var mac = adapter.Text("MACAddress");
                var configuration = mac is null ? null : byMac.GetValueOrDefault(mac);
                int? prefix = null;
                if (configuration?.Strings("IPSubnet").FirstOrDefault() is { Length: > 0 } mask && int.TryParse(mask, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
                {
                    prefix = parsed;
                }

                rows.Add(new NetworkAdapter(
                    adapter.Text("Name") ?? "",
                    adapter.Int("NetConnectionStatus"),
                    adapter.Number("Speed"),
                    mac,
                    true,
                    false,
                    [.. configuration?.Strings("IPAddress") ?? Array.Empty<string>()],
                    prefix,
                    configuration?.Strings("DefaultIPGateway").FirstOrDefault(),
                    [.. configuration?.Strings("DNSServerSearchOrder") ?? Array.Empty<string>()],
                    configuration?.Bool("DHCPEnabled"),
                    null));
            }
        }

        token.ThrowIfCancellationRequested();
        return current with { Network = [.. rows] };
    }

    private static InventorySnapshot ReadAntivirus(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var reading = session.Read(InventoryCategories.Antivirus, SecurityCenter, "SELECT displayName, productState FROM AntiVirusProduct", 8, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Antivirus, reading);
        if (!reading.Answered)
        {
            return current with { Antivirus = [] };
        }

        token.ThrowIfCancellationRequested();
        return current with
        {
            Antivirus = [.. reading.Instances.Select(a => new AntivirusProduct(a.Text("displayName") ?? "", a.Int("productState"), null))],
        };
    }

    private static InventorySnapshot ReadHotfixes(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var reading = session.Read(InventoryCategories.Hotfixes, Cimv2, "SELECT HotFixID, Description, InstalledOn FROM Win32_QuickFixEngineering", 500, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Hotfixes, reading);
        if (!reading.Answered)
        {
            return current with { Hotfixes = [] };
        }

        token.ThrowIfCancellationRequested();
        return current with
        {
            Hotfixes = [.. reading.Instances
                .Where(h => h.Text("HotFixID") is not null)
                .Select(h => new Hotfix(h.Text("HotFixID")!, h.Text("Description"), ParseInstalledOn(h.Text("InstalledOn"))))
                .OrderByDescending(h => h.InstalledOn ?? DateTimeOffset.MinValue)
                .ThenBy(h => h.Id, StringComparer.Ordinal)],
        };
    }

    private static InventorySnapshot ReadUpdateSource(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        // The WSUS address, the applied policy and the last CBS result live in the registry (StdRegProv): not read here.
        // The provider of update facts is Windows Update alone (docs/DECISIONS.md, WAPT abandoned), so the source is said
        // « not read » rather than answered by anything else.
        _ = token;
        access.Add(new SourceAccess(InventoryCategories.Updates, SourceStatus.Skipped, "source des mises à jour dans le registre : non branchée dans cette version", 0, 0, session.Transport));
        return current with { Updates = null };
    }

    private static InventorySnapshot ReadServices(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var reading = session.Read(InventoryCategories.Services, Cimv2, "SELECT Name, DisplayName, State, StartMode, DelayedAutoStart, ProcessId, StartName, ExitCode, ServiceDependencies, Description FROM Win32_Service", CimBudgets.ServicesCap, CimBudgets.Services);
        AddAccess(access, session, InventoryCategories.Services, reading);
        if (!reading.Answered)
        {
            return current with { Services = [] };
        }

        token.ThrowIfCancellationRequested();
        return current with
        {
            Services = [.. reading.Instances
                .Where(s => s.Text("Name") is not null)
                .Select(s => new ServiceEntry(
                    s.Text("Name")!,
                    s.Text("DisplayName") ?? s.Text("Name")!,
                    s.Text("State") ?? "",
                    s.Text("StartMode") ?? "",
                    s.Bool("DelayedAutoStart") ?? false,
                    s.Int("ProcessId"),
                    s.Text("StartName"),
                    s.Int("ExitCode"),
                    [.. s.Strings("ServiceDependencies")],
                    s.Text("Description")))
                .OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase)],
        };
    }

    private static InventorySnapshot ReadProcesses(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var first = session.Read(InventoryCategories.Processes, Cimv2, ProcessQuery, CimBudgets.ProcessesCap, CimBudgets.Processes);
        if (!first.Answered)
        {
            AddAccess(access, session, InventoryCategories.Processes, first);
            return current with { Processes = [] };
        }

        try
        {
            // Two reads of the same class over a bounded interval give the processor time used meanwhile.
            Task.Delay(CimBudgets.ProcessInterval, token).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            AddAccess(access, session, InventoryCategories.Processes, first);
            return current with { Processes = [] };
        }

        var second = session.Read(InventoryCategories.Processes, Cimv2, ProcessQuery, CimBudgets.ProcessesCap, CimBudgets.Processes);
        AddAccess(access, session, InventoryCategories.Processes, first, second);
        if (!second.Answered)
        {
            return current with { Processes = [] };
        }

        var before = first.Instances.GroupBy(p => p.Int("ProcessId") ?? -1).Where(g => g.Count() == 1).ToDictionary(g => g.Key, g => g.Single());
        var rows = new List<ProcessEntry>();
        foreach (var process in second.Instances)
        {
            var id = process.Int("ProcessId") ?? 0;
            if (id == 0)
            {
                // The idle pseudo-process holds the unused processor time: it is never sampled as a consumer.
                continue;
            }

            // A process started, ended, or whose identifier was reused between the two reads gets no processor share.
            var share = before.TryGetValue(id, out var old)
                && string.Equals(old.Text("Name"), process.Text("Name"), StringComparison.OrdinalIgnoreCase)
                && old.Text("CreationDate") == process.Text("CreationDate")
                ? TotalSeconds(process)
                : null;
            rows.Add(new ProcessEntry(id, process.Text("Name") ?? "", process.Number("WorkingSetSize"), share, null, process.Dmtf("CreationDate")));
        }

        return current with { Processes = [.. rows.OrderByDescending(r => r.CpuSeconds ?? -1).ThenBy(r => r.Name, StringComparer.Ordinal)] };
    }

    private static InventorySnapshot ReadEvents(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        // Same window as Domenia 1: three days of the System log, errors only, bounded count.
        var stamp = session.Clock.GetUtcNow().UtcDateTime.AddDays(-3).ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture) + ".000000+000";
        var reading = session.Read(
            InventoryCategories.Events,
            Cimv2,
            "SELECT Logfile, SourceName, EventCode, EventType, TimeGenerated, Message FROM Win32_NTLogEvent WHERE Logfile=\"System\" AND EventType=1 AND TimeGenerated>=\"" + stamp + "\"",
            CimBudgets.EventsCap,
            CimBudgets.Events);
        AddAccess(access, session, InventoryCategories.Events, reading);
        if (!reading.Answered)
        {
            return current with { SystemEvents = [] };
        }

        token.ThrowIfCancellationRequested();
        var now = session.Clock.GetUtcNow();
        return current with
        {
            SystemEvents = [.. reading.Instances
                .Select(e => new EventEntry(
                    e.Int("EventCode") ?? 0,
                    e.Text("SourceName") ?? "",
                    e.Text("Logfile") ?? "System",
                    "Erreur",
                    e.Dmtf("TimeGenerated") ?? now,
                    null,
                    null,
                    Trim(e.Text("Message")) ?? ""))
                .OrderByDescending(e => e.At)],
        };
    }

    private static InventorySnapshot ReadSessions(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        // Interactive and remote-desktop sessions. The account name of a session comes from the WTS API
        // (docs/ops/poste.md § 8.2), which this reader does not call yet: it stays null, which the console shows « non lu ».
        var reading = session.Read(InventoryCategories.Sessions, Cimv2, "SELECT LogonId, LogonType, StartTime FROM Win32_LogonSession WHERE LogonType=2 OR LogonType=10", 64, CimBudgets.Query);
        AddAccess(access, session, InventoryCategories.Sessions, reading);
        if (!reading.Answered)
        {
            return current with { Sessions = [] };
        }

        token.ThrowIfCancellationRequested();
        return current with
        {
            Sessions = [.. reading.Instances
                .Select(s => new LocalSession(
                    s.Text("LogonId") ?? "",
                    null,
                    null,
                    null,
                    CimQuery.LogonType(s.Int("LogonType")),
                    CimQuery.LogonType(s.Int("LogonType")),
                    s.Dmtf("StartTime"),
                    null,
                    null))
                .OrderBy(s => s.Id, StringComparer.Ordinal)],
        };
    }

    private static double? TotalSeconds(WmiInstance process)
    {
        var kernel = process.Number("KernelModeTime");
        var user = process.Number("UserModeTime");
        return kernel is long k && user is long u ? (k + u) / 10_000_000d : null;
    }

    /// <summary>InstalledOn of Win32_QuickFixEngineering: a plain date in practice, a DMTF date on some builds.</summary>
    internal static DateTimeOffset? ParseInstalledOn(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        if (CimQuery.ParseDmtf(text) is DateTimeOffset dmtf)
        {
            return dmtf;
        }

        return DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal | DateTimeStyles.AdjustToUniversal, out var parsed)
            ? new DateTimeOffset(parsed, TimeSpan.Zero)
            : null;
    }

    private static string? Trim(string? message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return null;
        }

        var text = message.Trim();
        return text.Length <= 220 ? text : text[..220] + "…";
    }

    private static InventorySnapshot Empty(string host, DateTimeOffset now, bool deep, InventoryTransport transport) => new(
        Computer: host,
        CollectedAt: now,
        Deep: deep,
        DurationMs: 0,
        Transport: transport,
        Access: [],
        Os: null,
        System: null,
        Bios: null,
        Processors: [],
        MemoryModules: [],
        MemoryArray: null,
        Memory: null,
        Volumes: [],
        PhysicalDisks: [],
        BitLocker: [],
        Tpm: null,
        SecureBoot: null,
        Network: [],
        Firewall: [],
        Antivirus: [],
        Defender: null,
        Hotfixes: [],
        Updates: null,
        Software: [],
        Startup: [],
        Services: [],
        Devices: [],
        Displays: [],
        Batteries: [],
        UnsignedDrivers: [],
        Sessions: [],
        LocalAdmins: [],
        Shares: [],
        Printers: [],
        PendingReboot: null,
        ClockSkewSeconds: null,
        ClockAgainstController: false,
        Site: null,
        Proxy: null,
        Processes: [],
        SystemEvents: [],
        Tasks: [],
        Certificates: [],
        Connections: []);

    /// <summary>One source of a reading: its label for the progress bar and its collector.</summary>
    private sealed record Step(string Category, string Label, Collect Run);

    private delegate InventorySnapshot Collect(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token);
}

/// <summary>
/// Account read at the console of one workstation (REL-021). The name the workstation calls itself comes back with it: the
/// caller must check it against the name of the directory and refuse the reading when they differ.
/// </summary>
public sealed record ConsoleAccountReading(string Host, SourceStatus Status, string? ConsoleUser, string? ReportedName)
{
    /// <summary>True when the workstation answered with a console account.</summary>
    public bool Answered => (Status is SourceStatus.Ok or SourceStatus.Partial) && !string.IsNullOrWhiteSpace(ConsoleUser);
}
