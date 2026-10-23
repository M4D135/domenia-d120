namespace Domenia.Core.Poste;

/// <summary>
/// Read interface of the workstation console (screen « poste », docs/ops/poste.md). Served by the simulated directory now
/// (Domenia.Simulation, Screens/Poste/SimulatedPosteReader.cs), by Active Directory and WMI/CIM later (wave 3). Local reads
/// (list, console, stored readings, cached software) never touch the network; every other method is a network read made
/// only after an explicit gesture of the operator, on one workstation, bounded in time. Read only by design: no write.
/// </summary>
public interface IPosteReader : IScreenReader
{
    /// <summary>Remote settings of the mode (WinRM, Wake-on-LAN, restart delay, operations account, suite tools).</summary>
    PosteOptions Options { get; }

    /// <summary>Workstations of the working OU, filtered locally by a text (name, user, OS, site); local base only.</summary>
    Task<PosteList> ListAsync(ScopeSelection? scope, string? text, int limit, PosteHealthPolicy policy, CancellationToken cancellationToken);

    /// <summary>The console of one workstation from the object card and the stored observations; no network read.</summary>
    Task<PosteConsole> OpenAsync(string dn, PosteHealthPolicy policy, ConsentState consent, CancellationToken cancellationToken);

    /// <summary>One ICMP echo, recorded before it is shown (PST-050).</summary>
    Task<PresenceReading> PingAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Live state: presence, uptime, console user and sessions count (one gesture, one bounded read).</summary>
    Task<PosteLive> LiveAsync(string dn, CancellationToken cancellationToken);

    /// <summary>
    /// Quick (about 1 min, 55 s budget) or full (about 3 min, 150 s budget) inventory, recorded as the last one. A stop or the
    /// budget gives a partial result (sources not reached « Interrompu »), never a loss; a workstation whose CIM refuses is
    /// read once by the fallback transport only with the fallback authorization of the session, otherwise « non lu ».
    /// </summary>
    Task<InventoryResult> InventoryAsync(string dn, bool deep, PosteHealthPolicy policy, IProgress<PosteProgress>? progress, CancellationToken cancellationToken);

    /// <summary>
    /// The last inventory of the workstation as rows (the reading of this session first, else the last one validated in the
    /// local base), with its date and provenance (PST-029, PST-036); null without any. No network read.
    /// </summary>
    Task<InventoryResult?> CachedInventoryAsync(string dn, PosteHealthPolicy policy, CancellationToken cancellationToken);

    /// <summary>Installed software of the workstation (registry Uninstall, SCCM, user hives, Appx), never Win32_Product.</summary>
    Task<SoftwareResult> SoftwareAsync(string dn, SoftwareRequest request, CancellationToken cancellationToken);

    /// <summary>Software already read by the last inventory (PST-025): no network read.</summary>
    Task<SoftwareResult> CachedSoftwareAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Win32_Service read once, capped at 500 instances.</summary>
    Task<ServicesResult> ServicesAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Two reads of Win32_Process spaced by a short interval, to measure the processor share.</summary>
    Task<ProcessesResult> ProcessesAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Events of one preset in a bounded window (1 to 720 h, 1 to 200 events).</summary>
    Task<EventsResult> EventsAsync(string dn, string preset, int hours, int maxEvents, CancellationToken cancellationToken);

    /// <summary>Windows sessions by the WTS API (consultation only).</summary>
    Task<SessionsResult> SessionsAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Full diagnosis: DNS, ping, TCP ports, transports, CIM, C$, WinRM, system and disk.</summary>
    Task<DiagnosticResult> DiagnosticAsync(string dn, IProgress<PosteProgress>? progress, CancellationToken cancellationToken);

    /// <summary>Bounded quick diagnosis: five read-only checks, 20 s announced, no fallback.</summary>
    Task<QuickDiagResult> QuickDiagnosticAsync(string dn, CancellationToken cancellationToken);

    Task<WmiNamespaces> WmiNamespacesAsync(string dn, string? parent, CancellationToken cancellationToken);

    Task<WmiClasses> WmiClassesAsync(string dn, string ns, CancellationToken cancellationToken);

    /// <summary>A validated SELECT on one class (no method invoked, MSI provider classes blocked).</summary>
    Task<WmiQueryResult> WmiQueryAsync(string dn, WmiRequest request, CancellationToken cancellationToken);

    /// <summary>Probe readings stored for the workstation (local base); no network read.</summary>
    Task<ProbeStore> ProbeStoreAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Collects once the given probes of the board for this workstation (PST-110: only the fields the board needs), then stores them.</summary>
    Task<ProbeStore> CollectProbesAsync(string dn, System.Collections.Immutable.ImmutableArray<string> probes, IProgress<PosteProgress>? progress, CancellationToken cancellationToken);

    /// <summary>Quick reading for the triage of a slow workstation.</summary>
    Task<SlowTriage> SlowTriageAsync(string dn, PosteHealthPolicy policy, CancellationToken cancellationToken);

    /// <summary>lastLogon of the computer account on every controller (PST-114).</summary>
    Task<LogonActivity> LogonByControllerAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Detection of the last user (PST-117); an existing association is never overwritten.</summary>
    Task<LastUserDetection> DetectLastUserAsync(string dn, IProgress<PosteProgress>? progress, CancellationToken cancellationToken);

    /// <summary>LAPS metadata of the workstation; the password is not part of it.</summary>
    Task<LapsView> LapsAsync(string dn, CancellationToken cancellationToken);

    /// <summary>The LAPS password, read on an explicit gesture for one reveal of 30 s in the secure window of the host.</summary>
    Task<SecretReading> RevealLapsAsync(string dn, CancellationToken cancellationToken);

    /// <summary>BitLocker recovery objects under the computer: metadata only.</summary>
    Task<BitLockerList> BitLockerListAsync(string dn, CancellationToken cancellationToken);

    /// <summary>
    /// One recovery key, a direct child of the computer, read by a Base search on its DN; the recovery identifier read with it
    /// must be <paramref name="expectedId"/> (Domenia 1 Mismatch), otherwise no value (poste.keyMismatch).
    /// </summary>
    Task<SecretReading> RevealBitLockerAsync(string dn, string keyDn, string expectedId, CancellationToken cancellationToken);

    /// <summary>
    /// Proposes another account for a refused secret resource (« laps » or « bitlocker », PST-060, PST-062): accepted, the
    /// refusal remembered for the workstation is lifted for that resource. Simulation: a fictitious account, no password.
    /// </summary>
    Task<OtherAccountResult> UseOtherAccountAsync(string dn, string resource, CancellationToken cancellationToken, string theme = "dark");

    /// <summary>
    /// Non-secret index of the secrets of the working OU (PST-066): BitLocker presence (number of recovery objects, never a key)
    /// and LAPS expiration of each workstation, 50 000 at most, bounded to the OU, on an explicit gesture.
    /// </summary>
    Task<SecretsIndex> SecretsIndexAsync(ScopeSelection scope, IProgress<PosteProgress>? progress, CancellationToken cancellationToken);

    /// <summary>The user account of a session login (sAMAccountName, domain removed) to open its card (PST-073); null when none.</summary>
    Task<UserRef?> FindAccountAsync(string login, CancellationToken cancellationToken);

    /// <summary>Groups of the directory whose name holds the text (50 at most), to choose a membership; local base only.</summary>
    Task<System.Collections.Immutable.ImmutableArray<DnRef>> GroupsAsync(string? text, CancellationToken cancellationToken);
}
