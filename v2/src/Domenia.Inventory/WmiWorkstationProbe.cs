using System.Globalization;
using System.Management;
using System.Net.NetworkInformation;
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
public sealed class WmiWorkstationProbe : IWorkstationFactsProbe
{
    private static readonly TimeSpan MinTimeout = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan MaxPingTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan MaxInventoryTimeout = TimeSpan.FromSeconds(150);

    /// <summary>Extra time given to the WMI calls to end by their own delays before the read is given up.</summary>
    private static readonly TimeSpan GiveUpMargin = TimeSpan.FromSeconds(2);

    // HRESULTs of DCOM that mean « refused » (E_ACCESSDENIED) rather than « not reached ».
    private const int AccessDeniedHResult = unchecked((int)0x80070005);

    private readonly TimeProvider clock;
    private readonly ITechnicalJournal? journal;

    /// <summary>Contacts nothing; every measure starts on an explicit request of the source.</summary>
    public WmiWorkstationProbe(TimeProvider clock, ITechnicalJournal? journal = null)
    {
        ArgumentNullException.ThrowIfNull(clock);
        this.clock = clock;
        this.journal = journal;
    }

    public async Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (!IsHostName(host))
        {
            journal?.Warning("Présence non mesurée : nom de poste invalide.");
            return false;
        }
        using var ping = new Ping();
        try
        {
            var reply = await ping.SendPingAsync(host, Bound(timeout, MaxPingTimeout), null, null, cancellationToken).ConfigureAwait(false);
            return reply.Status == IPStatus.Success;
        }
        catch (PingException ex)
        {
            // Name not resolved or network unreachable: no answer, which is never a verdict on the workstation.
            journal?.Info("Présence de " + host + " : pas de réponse (" + (ex.InnerException ?? ex).GetType().Name + ").");
            return false;
        }
    }

    internal Func<string, TimeSpan, CancellationToken, CimSession>? SessionFactory { get; init; }

    public async Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) =>
        (await ReadFactsAsync(host, timeout, cancellationToken).ConfigureAwait(false)).Inventory;

    public async Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsHostName(host)) { return Unread("Nom de poste invalide."); }
        var budget = Bound(timeout, MaxInventoryTimeout);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var gate = new object();
        var snapshot = Unread("Inventaire non lu.");
        var reading = Task.Run(() =>
        {
            var session = SessionFactory?.Invoke(host, budget, stop.Token) ?? new CimSession(host, budget, clock, journal, stop.Token);
            var readings = new Dictionary<string, CimReading>(StringComparer.Ordinal);
            void Read(string id, string query)
            {
                if (stop.IsCancellationRequested) { return; }
                readings[id] = session.Read(id, @"root\cimv2", query, 1, TimeSpan.FromSeconds(12));
                lock (gate) { snapshot = Project(readings, clock.GetUtcNow()); }
            }
            Read("system", "SELECT Caption, BuildNumber, LastBootUpTime, SystemDrive FROM Win32_OperatingSystem");
            Read("computer", "SELECT Model, Manufacturer, TotalPhysicalMemory, UserName FROM Win32_ComputerSystem");
            var drive = readings.GetValueOrDefault("system")?.Instances.FirstOrDefault()?.Text("SystemDrive");
            drive = drive is { Length: 2 } && char.IsAsciiLetter(drive[0]) && drive[1] == ':' ? drive : "C:";
            Read("disk", "SELECT Size, FreeSpace FROM Win32_LogicalDisk WHERE DeviceID=" + CimQuery.Literal(drive));
            Read("bios", "SELECT SMBIOSBIOSVersion FROM Win32_BIOS");
            lock (gate) { return snapshot; }
        }, CancellationToken.None);
        try { return await reading.WaitAsync(budget + GiveUpMargin, clock, cancellationToken).ConfigureAwait(false); }
        catch (TimeoutException)
        {
            stop.Cancel();
            lock (gate)
            {
                return snapshot with { Inventory = snapshot.Inventory with { State = MeasureState.Incomplete }, Facts = snapshot.Facts with { WmiState = MeasureState.Incomplete, WmiError = "Budget de lecture atteint ; mesures terminées conservées." } };
            }
        }
        catch (OperationCanceledException) { stop.Cancel(); throw; }
        finally
        {
            if (reading.IsCompleted) { stop.Dispose(); }
            else { _ = reading.ContinueWith(t => { _ = t.Exception; stop.Dispose(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default); }
        }
    }

    private WorkstationInventoryRead Unread(string error) => new(Failed(MeasureState.NotRead), new(null, null, null, null, MeasureState.NotRead, clock.GetUtcNow(), error));

    internal static WorkstationInventoryRead Project(IReadOnlyDictionary<string, CimReading> readings, DateTimeOffset at)
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
        return new(inventory, new(computer?.Text("UserName"), consoleKnown ? at : null, biosText, biosText is null ? null : at, state, at, error));
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
