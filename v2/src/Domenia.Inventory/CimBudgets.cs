namespace Domenia.Inventory;

/// <summary>
/// Bounded durations and volumes of the workstation reads, taken from docs/ops/poste.md § 8.3 and
/// docs/ops/relations.md § 6.3. Nothing here contacts a workstation: these are the ceilings the readers apply, and the
/// numbers the operator is told before a read starts. A read never exceeds its budget silently — what was read is kept
/// and the rest is said (« Interrompu »).
/// </summary>
public static class CimBudgets
{
    /// <summary>Smallest budget admitted: a shorter one would make every query fail before it starts.</summary>
    public static readonly TimeSpan Minimum = TimeSpan.FromMilliseconds(500);

    /// <summary>Largest budget admitted, whatever the caller asks for.</summary>
    public static readonly TimeSpan Maximum = TimeSpan.FromMinutes(5);

    /// <summary>Ping: one echo, 1 000 ms (docs/ops/poste.md § 8.3).</summary>
    public static readonly TimeSpan Ping = TimeSpan.FromMilliseconds(1_000);

    /// <summary>Live state: 10 s.</summary>
    public static readonly TimeSpan Live = TimeSpan.FromSeconds(10);

    /// <summary>Quick inventory: 55 s, partial result beyond.</summary>
    public static readonly TimeSpan QuickInventory = TimeSpan.FromSeconds(55);

    /// <summary>Full inventory: 150 s, partial result beyond.</summary>
    public static readonly TimeSpan FullInventory = TimeSpan.FromSeconds(150);

    /// <summary>Installed software: 130 s (200 s with the loaded profiles).</summary>
    public static readonly TimeSpan Software = TimeSpan.FromSeconds(130);

    /// <summary>Software with the users' hives read as well.</summary>
    public static readonly TimeSpan SoftwareWithProfiles = TimeSpan.FromSeconds(200);

    /// <summary>Services: 90 s.</summary>
    public static readonly TimeSpan Services = TimeSpan.FromSeconds(90);

    /// <summary>Processes: two reads spaced by 1 s, 20 s in all.</summary>
    public static readonly TimeSpan Processes = TimeSpan.FromSeconds(20);

    /// <summary>Interval between the two reads of Win32_Process.</summary>
    public static readonly TimeSpan ProcessInterval = TimeSpan.FromSeconds(1);

    /// <summary>Events: 30 s.</summary>
    public static readonly TimeSpan Events = TimeSpan.FromSeconds(30);

    /// <summary>Full diagnosis: 45 s.</summary>
    public static readonly TimeSpan FullDiagnostic = TimeSpan.FromSeconds(45);

    /// <summary>Quick diagnosis: 20 s.</summary>
    public static readonly TimeSpan QuickDiagnostic = TimeSpan.FromSeconds(20);

    /// <summary>Detection of the last user: 25 s.</summary>
    public static readonly TimeSpan LastUser = TimeSpan.FromSeconds(25);

    /// <summary>All the probes of the board together: 60 s.</summary>
    public static readonly TimeSpan Probes = TimeSpan.FromSeconds(60);

    /// <summary>One controller for lastLogon: 5 s each.</summary>
    public static readonly TimeSpan PerController = TimeSpan.FromSeconds(5);

    /// <summary>Revelation of one secret: 15 s.</summary>
    public static readonly TimeSpan SecretReveal = TimeSpan.FromSeconds(15);

    /// <summary>Console account of one workstation (relations, REL-021): 4 s.</summary>
    public static readonly TimeSpan ConsoleSession = TimeSpan.FromSeconds(4);

    /// <summary>All the console reads of one detection or one relevé: 120 s.</summary>
    public static readonly TimeSpan RelationsReading = TimeSpan.FromSeconds(120);

    /// <summary>Delay of the CIM bind itself, kept well under every read budget.</summary>
    public static readonly TimeSpan Connect = TimeSpan.FromSeconds(8);

    /// <summary>Delay of one query when the caller does not name one.</summary>
    public static readonly TimeSpan Query = TimeSpan.FromSeconds(10);

    /// <summary>Extra time granted to a WMI call to end by its own delay before the read is given up.</summary>
    public static readonly TimeSpan GiveUpMargin = TimeSpan.FromSeconds(2);

    /// <summary>Win32_Service is read once, 500 instances at most (docs/ops/poste.md § 8.2).</summary>
    public const int ServicesCap = 500;

    /// <summary>Win32_Process instances kept between the two reads.</summary>
    public const int ProcessesCap = 600;

    /// <summary>Events kept for one preset.</summary>
    public const int EventsCap = 200;

    /// <summary>Workstations contacted by one console reading, one harvest or one relevé (REL-021, REL-030, REL-031).</summary>
    public const int WorkstationsPerReading = 50;

    /// <summary>ICMP echoes in flight before the next batch (REL-031, RelationProbeLoop).</summary>
    public const int PingBatch = 8;

    /// <summary>Kerberos clues read on one controller (REL-022).</summary>
    public const int KerberosEvents = 100;

    /// <summary>Harvest of the controller journal (REL-030): 1 to 30 days, 7 by default.</summary>
    public const int HarvestMinDays = 1;

    public const int HarvestMaxDays = 30;

    public const int HarvestDefaultDays = 7;

    /// <summary>Harvest of the controller journal (REL-030): 200 to 20 000 events, 5 000 by default.</summary>
    public const int HarvestMinEvents = 200;

    public const int HarvestMaxEvents = 20_000;

    public const int HarvestDefaultEvents = 5_000;

    /// <summary>Bounded clamp of a caller-supplied budget.</summary>
    public static TimeSpan Bound(TimeSpan requested) => requested < Minimum ? Minimum : requested > Maximum ? Maximum : requested;
}
