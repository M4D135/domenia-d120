using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>
/// Read status of one inventory source (Domenia 1 Add-Access: OK, VIDE, PARTIEL, REFUSE, INDISPONIBLE, INJOIGNABLE, IGNORE,
/// ERREUR). A refusal on one source never prevents the others; an empty answer is a reading, a refused one is not.
/// </summary>
public enum SourceStatus
{
    Ok,
    Empty,
    Partial,
    Refused,
    Unavailable,
    Unreachable,
    Skipped,
    Error,
}

/// <summary>Transport that answered a source (DCOM first; WinRM, PsExec and the scheduled task are fallbacks).</summary>
public enum InventoryTransport
{
    Dcom,
    WinRm,
    PsExec,
    ScheduledTask,
    Local,
}

/// <summary>Access report line of one source (Domenia 1 DgInventoryAccess).</summary>
public sealed record SourceAccess(string Category, SourceStatus Status, string Detail, int DurationMs, int Items, InventoryTransport Transport);

public sealed record OsInfo(string Caption, string Version, string Build, int? Revision, string Architecture, int? Language, DateTimeOffset? InstallDate, DateTimeOffset? LastBoot, int? DomainRole, string? Domain, DateTimeOffset? LocalClock);

public sealed record SystemInfo(string Manufacturer, string Model, string? SerialNumber, ImmutableArray<int> ChassisTypes, int? PcSystemType, long? TotalPhysicalMemory, int? LogicalProcessors, string? Hypervisor, string? UserName);

public sealed record BiosInfo(string Version, DateTimeOffset? ReleaseDate, string? SmbiosVersion, string? Firmware, string? Manufacturer);

public sealed record CpuInfo(string Name, int? Cores, int? LogicalProcessors, int? MaxClockMhz, int? LoadPercent, string? Architecture, bool? VirtualizationFirmware, bool? Slat);

public sealed record MemoryModule(string Slot, long? CapacityBytes, int? SpeedMhz, string? Manufacturer, string? PartNumber);

public sealed record MemoryArrayInfo(int? Slots, long? MaxCapacityBytes);

/// <summary>Memory seen by Windows at the reading, in kilobytes as Win32_OperatingSystem gives it.</summary>
public sealed record MemoryUsage(long? VisibleKb, long? FreeKb);

public sealed record LogicalDisk(string Id, string? Label, string? FileSystem, long? SizeBytes, long? FreeBytes);

/// <summary>Physical disk (MSFT_PhysicalDisk) with its reliability counters when exposed.</summary>
public sealed record PhysicalDisk(string Id, string Name, int? MediaType, int? BusType, long? SizeBytes, int? Health, double? WearPercent, double? TemperatureCelsius, long? PowerOnHours, long? UncorrectedErrors, string? SmartStatus);

/// <summary>BitLocker state of one volume (Win32_EncryptableVolume): ProtectionStatus 0/1/2, ConversionStatus, method code.</summary>
public sealed record BitLockerVolume(string Drive, int? Protection, int? Conversion, int? Method, double? EncryptedPercent, int? ProtectorCount);

public sealed record TpmInfo(string? Specification, bool? Enabled, bool? Activated, bool? Owned);

/// <summary>Secure Boot as read in the registry, and the firmware type (UEFI or legacy BIOS).</summary>
public sealed record SecureBootInfo(bool? Enabled, string? Firmware, bool? VbsRunning, bool? CredentialGuard);

public sealed record NetworkAdapter(string Name, int? Status, long? SpeedBitsPerSecond, string? Mac, bool Physical, bool Wireless, ImmutableArray<string> Ipv4, int? PrefixLength, string? Gateway, ImmutableArray<string> Dns, bool? Dhcp, string? Profile);

/// <summary>One firewall profile: local value and policy value (the policy wins), with the active connections it applies to.</summary>
public sealed record FirewallProfile(string Name, bool? LocalEnabled, bool? PolicyEnabled, ImmutableArray<string> Connections);

public sealed record AntivirusProduct(string Name, int? ProductState, DateTimeOffset? Timestamp);

public sealed record DefenderStatus(bool? AntivirusEnabled, bool? RealTime, bool? Behavior, int? SignatureAgeDays, int? QuickScanAgeDays, int? FullScanAgeDays, string? Version, bool? Passive, bool? ScanRunning);

public sealed record Hotfix(string Id, string? Description, DateTimeOffset? InstalledOn);

/// <summary>Windows Update configuration: WSUS address and whether it is really used (UseWUServer = 1), last CBS update.</summary>
public sealed record UpdateConfig(string? WsusServer, bool? UseWsus, string? Source, DateTimeOffset? LastSuccess, string? LastResult, bool? WaptAgent, DateTimeOffset? WaptLastUpdate, string? WaptResult);

/// <summary>One software entry as an uninstall key, SCCM, a user hive or an Appx package declares it.</summary>
public sealed record SoftwareEntry(
    string Name,
    string? Version,
    string? Publisher,
    DateOnly? InstallDate,
    long? SizeBytes,
    string Architecture,
    string Scope,
    string? Profile,
    string? Location,
    string? Uninstall,
    string Source);

/// <summary>Startup entry: the executable only, never its arguments (Get-DomeniaCommandExecutable).</summary>
public sealed record StartupEntry(string Name, string Executable, string Location, string? User, bool Microsoft);

public sealed record ServiceEntry(string Name, string DisplayName, string State, string StartMode, bool Delayed, int? ProcessId, string? Account, int? ExitCode, ImmutableArray<string> DependsOn, string? Description);

public sealed record DeviceError(string Name, int Code, string? Class);

public sealed record DisplayInfo(string Name, string? Manufacturer, string? Product, string? Serial, int? Year, string Connection, bool Internal);

public sealed record BatteryInfo(string Name, int? ChargePercent, int? Status, long? DesignedCapacity, long? FullChargeCapacity, int? Cycles);

public sealed record DriverInfo(string Name, string? Provider, string? Version);

public sealed record LocalSession(string Id, string? Station, string? User, string? Domain, string State, string Protocol, DateTimeOffset? LogonAt, TimeSpan? Idle, string? ClientName);

public sealed record ShareInfo(string Name, string Path, string? Description);

public sealed record PrinterInfo(string Name, string? Driver, string? Port, bool Network, bool Default, bool Offline, bool Error);

/// <summary>Pending reboot indicators of the registry: confirmed obligations and partial hints are kept apart.</summary>
public sealed record PendingReboot(ImmutableArray<string> Confirmed, ImmutableArray<string> Partial);

public sealed record ProcessEntry(int Id, string Name, long? WorkingSetBytes, double? CpuSeconds, string? User, DateTimeOffset? StartedAt);

public sealed record EventEntry(int Id, string Provider, string Log, string Level, DateTimeOffset At, string? Machine, string? UserSid, string Message);

public sealed record TaskEntry(string Name, string Path, string? Author, string State, string? LastResult, DateTimeOffset? LastRun, DateTimeOffset? NextRun, bool Microsoft);

public sealed record CertificateEntry(string Subject, string Issuer, DateTimeOffset NotAfter, ImmutableArray<string> Usages, string Thumbprint);

public sealed record ConnectionEntry(string Protocol, string Local, string Remote, string State, string? Process);

/// <summary>
/// What a quick or full inventory read (Domenia 1 ComputerInventory worker), normalised and typed: the same shape whatever
/// the source (simulation today, WMI/CIM by DCOM in directory mode). Arrays are empty, never null; a source that was not
/// read is said by <see cref="Access"/>, never by an empty array alone. Command arguments are never kept.
/// </summary>
public sealed record InventorySnapshot(
    string Computer,
    DateTimeOffset CollectedAt,
    bool Deep,
    int DurationMs,
    InventoryTransport Transport,
    ImmutableArray<SourceAccess> Access,
    OsInfo? Os,
    SystemInfo? System,
    BiosInfo? Bios,
    ImmutableArray<CpuInfo> Processors,
    ImmutableArray<MemoryModule> MemoryModules,
    MemoryArrayInfo? MemoryArray,
    MemoryUsage? Memory,
    ImmutableArray<LogicalDisk> Volumes,
    ImmutableArray<PhysicalDisk> PhysicalDisks,
    ImmutableArray<BitLockerVolume> BitLocker,
    TpmInfo? Tpm,
    SecureBootInfo? SecureBoot,
    ImmutableArray<NetworkAdapter> Network,
    ImmutableArray<FirewallProfile> Firewall,
    ImmutableArray<AntivirusProduct> Antivirus,
    DefenderStatus? Defender,
    ImmutableArray<Hotfix> Hotfixes,
    UpdateConfig? Updates,
    ImmutableArray<SoftwareEntry> Software,
    ImmutableArray<StartupEntry> Startup,
    ImmutableArray<ServiceEntry> Services,
    ImmutableArray<DeviceError> Devices,
    ImmutableArray<DisplayInfo> Displays,
    ImmutableArray<BatteryInfo> Batteries,
    ImmutableArray<DriverInfo> UnsignedDrivers,
    ImmutableArray<LocalSession> Sessions,
    ImmutableArray<string> LocalAdmins,
    ImmutableArray<ShareInfo> Shares,
    ImmutableArray<PrinterInfo> Printers,
    PendingReboot? PendingReboot,
    int? ClockSkewSeconds,
    bool ClockAgainstController,
    string? Site,
    string? Proxy,
    ImmutableArray<ProcessEntry> Processes,
    ImmutableArray<EventEntry> SystemEvents,
    ImmutableArray<TaskEntry> Tasks,
    ImmutableArray<CertificateEntry> Certificates,
    ImmutableArray<ConnectionEntry> Connections)
{
    /// <summary>Status of one category of the access report (Skipped when the category was not part of this reading).</summary>
    public SourceStatus StatusOf(string category) =>
        Access.FirstOrDefault(a => string.Equals(a.Category, category, StringComparison.Ordinal))?.Status ?? SourceStatus.Skipped;

    /// <summary>True when a category answered (OK, empty or partial): its arrays then describe the workstation.</summary>
    public bool Read(string category) => StatusOf(category) is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial;
}

/// <summary>Category names of the access report, shared by the collector, the board and the inventory grid.</summary>
public static class InventoryCategories
{
    public const string System = "Système";
    public const string Bios = "BIOS et démarrage";
    public const string Board = "Carte mère";
    public const string Processor = "Processeur";
    public const string Memory = "Mémoire";
    public const string Volumes = "Disques logiques";
    public const string PhysicalDisks = "Disques physiques";
    public const string BitLocker = "BitLocker";
    public const string Tpm = "TPM";
    public const string Network = "Cartes réseau";
    public const string Firewall = "Pare-feu";
    public const string Antivirus = "Antivirus";
    public const string Hotfixes = "Correctifs";
    public const string Updates = "Mises à jour";
    public const string Software = "Logiciels installés";
    public const string Startup = "Démarrage automatique";
    public const string Services = "Services";
    public const string Devices = "Périphériques en erreur";
    public const string Displays = "Affichage";
    public const string Batteries = "Batterie";
    public const string Drivers = "Pilotes non signés";
    public const string Sessions = "Sessions";
    public const string Admins = "Administrateurs locaux";
    public const string Shares = "Partages";
    public const string Printers = "Imprimantes";
    public const string Reboot = "Redémarrage en attente";
    public const string Site = "Site AD et proxy";
    public const string Processes = "Processus";
    public const string Events = "Événements système";
    public const string Tasks = "Tâches planifiées";
    public const string Certificates = "Certificats machine";
    public const string Connections = "Connexions réseau";

    /// <summary>Sources of the quick inventory, in reading order (Domenia 1 worker).</summary>
    public static ImmutableArray<string> Quick { get; } =
    [
        System, Bios, Board, Processor, Memory, Volumes, PhysicalDisks, BitLocker, Tpm, Network, Firewall, Antivirus, Hotfixes,
        Updates, Software, Startup, Services, Devices, Displays, Batteries, Drivers, Sessions, Admins, Shares, Printers, Reboot, Site,
    ];

    /// <summary>Sources only the full inventory reads (Test-DomeniaComputerInventoryDeep).</summary>
    public static ImmutableArray<string> DeepOnly { get; } = [Processes, Events, Tasks, Certificates, Connections];
}
