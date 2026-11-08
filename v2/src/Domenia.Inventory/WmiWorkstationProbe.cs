using System.Globalization;
using System.Management;
using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>
/// Light measures of a workstation in directory mode (Domenia 1 ParkPing and ParkSweep, docs/ops/accueil.md § 16): one ICMP
/// echo, then a light inventory read by WMI (CIM over DCOM, Windows session, Kerberos, packet privacy): Win32_OperatingSystem,
/// Win32_ComputerSystem and the system disk of Win32_LogicalDisk. Read only: only SELECT queries, never a method call, never a
/// change. Every read is bounded (connection, each query and the whole read); a refusal is told apart from an error, and an
/// unanswered read is « not read », never a verdict. Never called on the UI thread (the source measures off it).
/// </summary>
public sealed class WmiWorkstationProbe : IConfiguredWorkstationFactsProbe, IWorkstationPresenceProbe
{
    private static readonly TimeSpan MinTimeout = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan MaxPingTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan MaxInventoryTimeout = TimeSpan.FromSeconds(150);

    /// <summary>Extra time before requesting cancellation; physical completion is still awaited afterwards.</summary>
    private static readonly TimeSpan GiveUpMargin = TimeSpan.FromSeconds(2);

    // HRESULTs of DCOM that mean « refused » (E_ACCESSDENIED) rather than « not reached ».
    private const int AccessDeniedHResult = unchecked((int)0x80070005);

    private readonly TimeProvider clock;
    private readonly ITechnicalJournal? journal;
    private readonly AdaptiveReadBudget adaptive;

    /// <summary>Contacts nothing; every measure starts on an explicit request of the source.</summary>
    public WmiWorkstationProbe(TimeProvider clock, ITechnicalJournal? journal = null, AdaptiveReadBudget? adaptive = null)
    {
        ArgumentNullException.ThrowIfNull(clock);
        this.clock = clock;
        this.journal = journal;
        this.adaptive = adaptive ?? AdaptiveReadBudget.Presence;
    }

    public async Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) =>
        (await ReadPresenceAsync(host, timeout, null, cancellationToken).ConfigureAwait(false)).Answered == true;

    internal WorkstationPresenceReader? PresenceReaderOverride { get; init; }

    public async Task<PresenceMeasure> ReadPresenceAsync(string host, TimeSpan timeout, DateTimeOffset? lastOnlineAt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(host);
        var reader = PresenceReaderOverride ?? new WorkstationPresenceReader(clock, journal, adaptive);
        var total = Bound(timeout, MaxPingTimeout);
        return await reader.ReadAsync(host, total, total, lastOnlineAt, cancellationToken).ConfigureAwait(false);
    }

    internal Func<string, TimeSpan, CancellationToken, CimSession>? SessionFactory { get; init; }

    public async Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) =>
        (await ReadFactsAsync(host, timeout, cancellationToken).ConfigureAwait(false)).Inventory;

    public Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) => ReadFactsAsync(host, timeout, cancellationToken, null);

    public Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken, RemoteProbeCredential? credential) => ReadFactsAsync(host, timeout, cancellationToken, credential, null);

    public Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken, RemoteProbeCredential? credential, PosteConfiguration? configuration) =>
        ReadFactsAsync(host, timeout, cancellationToken, credential, configuration, retainPartialOnCancellation: false);

    public async Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken,
        RemoteProbeCredential? credential, PosteConfiguration? configuration, bool retainPartialOnCancellation)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (configuration is { UseCim: false }) { return Unread("Lecture CIM désactivée par Remote.UseCim ; aucun contact."); }
        if (!IsHostName(host)) { return Unread("Nom de poste invalide."); }
        using var phase = OperationPhases.Measure(OperationPhase.Collection);
        var budget = Bound(timeout, MaxInventoryTimeout);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var gate = new object();
        var snapshot = Unread("Inventaire non lu.");
        NativeReadProgress? progressState = null;
        var reading = await WmiReadWorkers.StartAsync(host, credential, owned =>
        {
            using var advancing = new NativeReadProgress(clock, budget, inventory: true, stop.Token);
            Volatile.Write(ref progressState, advancing);
            using var session = SessionFactory?.Invoke(host, budget, advancing.Token) ?? new CimSession(host, budget, clock, journal, advancing.Token, owned,
                configuration?.SelectedCimTransport ?? InventoryTransport.Dcom);
            session.QueryCompleted = advancing.Completed;
            var readings = new Dictionary<string, CimReading>(StringComparer.Ordinal);
            DateTimeOffset? memoryAt = null;
            void Read(string id, string query)
            {
                if (advancing.Token.IsCancellationRequested || session.OutOfBudget) { return; }
                readings[id] = session.Read(id, @"root\cimv2", query, 1, TimeSpan.FromSeconds(12));
                if (id == "system") { memoryAt = clock.GetUtcNow(); }
                lock (gate) { snapshot = Project(readings, clock.GetUtcNow(), memoryAt); }
            }
            Read("system", "SELECT Caption, BuildNumber, LastBootUpTime, SystemDrive, TotalVisibleMemorySize, FreePhysicalMemory FROM Win32_OperatingSystem");
            Read("computer", "SELECT Name, Model, Manufacturer, TotalPhysicalMemory, UserName, DNSHostName, Domain FROM Win32_ComputerSystem");
            var drive = readings.GetValueOrDefault("system")?.Instances.FirstOrDefault()?.Text("SystemDrive");
            if (drive is { Length: 2 } && char.IsAsciiLetter(drive[0]) && drive[1] == ':')
            { Read("disk", "SELECT Size, FreeSpace FROM Win32_LogicalDisk WHERE DeviceID=" + CimQuery.Literal(drive)); }
            else
            {
                // This dependent source was not sent. Preserve its prerequisite's retry cause, not a second
                // invented timeout or a fictitious disk reading.
                readings["disk"] = new("disk", SourceStatus.Skipped, "Disque système non identifié ; aucune lettre supposée.", 0, [])
                    { RetryFailure = readings.GetValueOrDefault("system")?.RetryFailure ?? CollectionReadFailure.Unknown };
            }
            Read("bios", "SELECT SMBIOSBIOSVersion FROM Win32_BIOS");
            lock (gate)
            {
                if (advancing.Token.IsCancellationRequested || session.OutOfBudget)
                { snapshot = snapshot with { Facts = snapshot.Facts with { WmiError = NativeReadProgress.Stopped(advancing, "Lecture arrêtée ou budget atteint.") } }; }
                return snapshot;
            }
        }, cancellationToken).ConfigureAwait(false);
        WorkstationInventoryRead Partial() { lock (gate) { return snapshot; } }
        var completed = await NativeReadCompletion.AwaitAsync(reading, stop, budget + GiveUpMargin, clock, cancellationToken, Partial).ConfigureAwait(false);
        var result = completed.Value with { ReadPhysicallyCompleted = true };
        if (completed.Stop != NativeReadStop.None)
        {
            var error = completed.Stop == NativeReadStop.Cancelled ? "Lecture arrêtée ; mesures terminées conservées."
                : "Budget de lecture atteint ; mesures terminées conservées.";
            error = NativeReadProgress.Stopped(Volatile.Read(ref progressState), error);
            if (completed.Failure is not null) { journal?.Info("Fin de lecture CIM interrompue : " + completed.Failure.GetType().Name + "."); }
            result = result with
            {
                Inventory = result.Inventory with { State = MeasureState.Incomplete },
                Facts = result.Facts with { WmiState = MeasureState.Incomplete, WmiError = error },
                // An envelope deadline is not a native per-source transient failure and must never cause a retry.
                RetryFailure = completed.Stop == NativeReadStop.Cancelled ? CollectionReadFailure.Cancelled : CollectionReadFailure.Unknown,
            };
        }
        if (!retainPartialOnCancellation) { cancellationToken.ThrowIfCancellationRequested(); }
        return result;
    }

    private WorkstationInventoryRead Unread(string error) => new(Failed(MeasureState.NotRead), new(null, null, null, null, MeasureState.NotRead, clock.GetUtcNow(), error));

    internal static WorkstationInventoryRead Project(IReadOnlyDictionary<string, CimReading> readings, DateTimeOffset at, DateTimeOffset? memoryAt = null)
    {
        WmiInstance? Row(string key) => readings.GetValueOrDefault(key)?.Instances.FirstOrDefault();
        var system = Row("system");
        var computer = Row("computer");
        var disk = Row("disk");
        var bios = Row("bios");
        var failures = readings.Values.Where(r => r.Status is not SourceStatus.Ok and not SourceStatus.Empty).ToArray();
        var state = failures.Any(r => r.Status == SourceStatus.Refused) ? MeasureState.Refused
            : readings.Values.Any(r => r.Status == SourceStatus.Error) ? MeasureState.Error
            : readings.Count < 4 || failures.Length > 0 || system is null || computer is null ? MeasureState.Incomplete : MeasureState.Known;
        var size = disk?.Number("Size");
        var free = disk?.Number("FreeSpace");
        if (size is not > 0) { size = null; free = null; }
        if (free < 0 || free > size) { free = null; }
        var inventory = new InventoryMeasure(state, at, size, free, system?.Dmtf("LastBootUpTime"), computer?.Text("Model"), computer?.Number("TotalPhysicalMemory"), system?.Text("Caption"), system?.Text("BuildNumber"));
        var consoleKnown = readings.GetValueOrDefault("computer")?.Status == SourceStatus.Ok && computer is not null;
        var biosText = bios?.Text("SMBIOSBIOSVersion");
        var error = failures.Length > 0 ? string.Join(" ; ", failures.Select(f => f.Category + " : " + f.Detail)) : state == MeasureState.Known ? null : "Inventaire incomplet.";
        var memory = readings.GetValueOrDefault("system") is { Status: SourceStatus.Ok, Items: 1 }
            ? MemoryUsageFact.Read(system?.Number("TotalVisibleMemorySize"), system?.Number("FreePhysicalMemory"), memoryAt ?? at) : null;
        return new(inventory, new(computer?.Text("UserName"), consoleKnown ? at : null, biosText, biosText is null ? null : at, state, at, error) { Memory = memory })
            { ReportedName = computer?.Text("Name"), HostIdentity = readings.GetValueOrDefault("computer")?.HostIdentity, AuthenticationRejected = readings.Values.Any(r => r.AuthenticationRejected),
                RetryFailure = CollectionReadRetry.Combine(readings.Values.Select(r => r.AuthenticationRejected
                    ? CollectionReadFailure.CredentialRejected : r.Status == SourceStatus.Refused ? CollectionReadFailure.AccessDenied : r.RetryFailure)) };
    }

    /// <summary>A host name or an IPv4 address: letters, digits, « - » and « . » only (nothing that changes the WMI path).</summary>
    internal static bool IsHostName(string host) => CimQuery.IsHostName(host);

    /// <summary>A DMTF date (« 20261021162600.500000+120 ») in UTC, or null when it cannot be read.</summary>
    internal static DateTimeOffset? ParseDmtf(string? text)
    {
        if (text is null || text.Length != 25 || text[14] != '.'
            || !DateTime.TryParseExact(text[..14], "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var local)
            || !int.TryParse(text.AsSpan(15, 6), NumberStyles.None, CultureInfo.InvariantCulture, out var microseconds)
            || text[21] is not ('+' or '-')
            || !int.TryParse(text.AsSpan(22, 3), NumberStyles.None, CultureInfo.InvariantCulture, out var minutes)
            || minutes > 14 * 60)
        {
            return null;
        }
        var offset = TimeSpan.FromMinutes(text[21] == '-' ? -minutes : minutes);
        try
        {
            return new DateTimeOffset(local.AddTicks(microseconds * 10L), offset).ToUniversalTime();
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>Which measure state an exception of a WMI read means; null for an exception that is not a WMI outcome.</summary>
    internal static MeasureState? Classify(Exception exception) => exception switch
    {
        UnauthorizedAccessException => MeasureState.Refused,
        ManagementException { ErrorCode: ManagementStatus.AccessDenied } => MeasureState.Refused,
        ManagementException { ErrorCode: ManagementStatus.Timedout } => MeasureState.NotRead,
        ManagementException => MeasureState.Error,
        COMException { HResult: AccessDeniedHResult } => MeasureState.Refused,
        // RPC server unavailable, call failed, network errors: the workstation is not reachable by WMI.
        COMException => MeasureState.NotRead,
        _ => null,
    };

    private static TimeSpan Bound(TimeSpan value, TimeSpan max) => value < MinTimeout ? MinTimeout : value > max ? max : value;

    private InventoryMeasure Failed(MeasureState state) => new(state, clock.GetUtcNow(), null, null, null, null, null, null, null);

}
