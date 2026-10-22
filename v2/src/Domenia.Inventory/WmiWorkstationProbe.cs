using System.Globalization;
using System.Management;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Domenia.Core;
using WmiEnumerationOptions = System.Management.EnumerationOptions;

namespace Domenia.Inventory;

/// <summary>
/// Light measures of a workstation in directory mode (Domenia 1 ParkPing and ParkSweep, docs/ops/accueil.md § 16): one ICMP
/// echo, then a light inventory read by WMI (CIM over DCOM, Windows session, Kerberos, packet privacy): Win32_OperatingSystem,
/// Win32_ComputerSystem and the system disk of Win32_LogicalDisk. Read only: only SELECT queries, never a method call, never a
/// change. Every read is bounded (connection, each query and the whole read); a refusal is told apart from an error, and an
/// unanswered read is « not read », never a verdict. Never called on the UI thread (the source measures off it).
/// </summary>
public sealed class WmiWorkstationProbe : IWorkstationProbe
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

    public async Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (!IsHostName(host))
        {
            journal?.Warning("Inventaire non lu : nom de poste invalide.");
            return Failed(MeasureState.NotRead);
        }
        var bound = Bound(timeout, MaxInventoryTimeout);
        var reading = Task.Run(() => Read(host, bound, cancellationToken), cancellationToken);
        try
        {
            return await reading.WaitAsync(bound + GiveUpMargin, clock, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // The WMI calls end by their own delays; their outcome is still traced, never left unobserved.
            _ = reading.ContinueWith(
                t => journal?.Info("Inventaire de " + host + " abandonné, fin tardive : " + t.Exception?.GetBaseException().GetType().Name + "."),
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
            journal?.Info("Inventaire de " + host + " : délai dépassé.");
            return Failed(MeasureState.NotRead);
        }
        catch (Exception ex) when (Classify(ex) is MeasureState state)
        {
            journal?.Info("Inventaire de " + host + " : " + (state == MeasureState.Refused ? "accès refusé" : state == MeasureState.NotRead ? "poste injoignable par WMI" : "erreur WMI") + " (" + ex.GetType().Name + ", 0x" + ex.HResult.ToString("X8", CultureInfo.InvariantCulture) + ").");
            return Failed(state);
        }
    }

    /// <summary>A host name or an IPv4 address: letters, digits, « - » and « . » only (nothing that changes the WMI path).</summary>
    internal static bool IsHostName(string host) =>
        host.Length is > 0 and <= 255 && host.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.');

    /// <summary>A DMTF date (« 20261021162600.500000+120 ») in UTC, or null when it cannot be read.</summary>
    internal static DateTimeOffset? ParseDmtf(string? text)
    {
        if (text is null || text.Length < 25
            || !DateTime.TryParseExact(text[..14], "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var local)
            || !int.TryParse(text.AsSpan(15, 6), NumberStyles.None, CultureInfo.InvariantCulture, out var microseconds)
            || text[21] is not ('+' or '-')
            || !int.TryParse(text.AsSpan(22, 3), NumberStyles.None, CultureInfo.InvariantCulture, out var minutes)
            || minutes > 14 * 60)
        {
            return null;
        }
        var offset = TimeSpan.FromMinutes(text[21] == '-' ? -minutes : minutes);
        return new DateTimeOffset(local.AddTicks(microseconds * 10L), offset).ToUniversalTime();
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

    /// <summary>The synchronous WMI read (off the UI thread): one connection, three SELECT queries, each with its delay.</summary>
    private InventoryMeasure Read(string host, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var options = new ConnectionOptions
        {
            Impersonation = ImpersonationLevel.Impersonate,
            Authentication = AuthenticationLevel.PacketPrivacy,
            EnablePrivileges = false,
            Timeout = timeout,
        };
        var scope = new ManagementScope(@"\\" + host + @"\root\cimv2", options);
        scope.Connect();
        cancellationToken.ThrowIfCancellationRequested();
        var system = QueryOne(scope, "SELECT Caption, BuildNumber, LastBootUpTime, SystemDrive FROM Win32_OperatingSystem", timeout);
        cancellationToken.ThrowIfCancellationRequested();
        var computer = QueryOne(scope, "SELECT Model, TotalPhysicalMemory FROM Win32_ComputerSystem", timeout);
        cancellationToken.ThrowIfCancellationRequested();
        var drive = Text(system, "SystemDrive") is { Length: 2 } letter && char.IsAsciiLetter(letter[0]) && letter[1] == ':' ? letter : "C:";
        var disk = QueryOne(scope, "SELECT Size, FreeSpace FROM Win32_LogicalDisk WHERE DeviceID='" + drive + "'", timeout);
        var size = Number(disk, "Size");
        // A size of 0 or unreadable is « no reading », never a full disk.
        var (diskSize, diskFree) = size is > 0 ? (size, Number(disk, "FreeSpace")) : ((long?)null, (long?)null);
        return new InventoryMeasure(
            system is null ? MeasureState.Incomplete : MeasureState.Known,
            clock.GetUtcNow(),
            diskSize,
            diskFree,
            ParseDmtf(Text(system, "LastBootUpTime")),
            Text(computer, "Model"),
            Number(computer, "TotalPhysicalMemory"),
            Text(system, "Caption"),
            Text(system, "BuildNumber"));
    }

    /// <summary>The properties of the first instance of a SELECT query, copied out of the WMI objects (all disposed here).</summary>
    private static Dictionary<string, object?>? QueryOne(ManagementScope scope, string query, TimeSpan timeout)
    {
        var enumeration = new WmiEnumerationOptions { Timeout = timeout, ReturnImmediately = true, Rewindable = false };
        using var searcher = new ManagementObjectSearcher(scope, new ObjectQuery(query), enumeration);
        using var results = searcher.Get();
        foreach (var item in results)
        {
            using (item)
            {
                var values = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                foreach (var property in item.Properties)
                {
                    values[property.Name] = property.Value;
                }
                return values;
            }
        }
        return null;
    }

    private static string? Text(Dictionary<string, object?>? values, string name) =>
        values is not null && values.TryGetValue(name, out var value) && value is string text && !string.IsNullOrWhiteSpace(text) ? text.Trim() : null;

    private static long? Number(Dictionary<string, object?>? values, string name) =>
        values is null || !values.TryGetValue(name, out var value) ? null : value switch
        {
            ulong u when u <= long.MaxValue => (long)u,
            long l when l >= 0 => l,
            uint u => u,
            int i when i >= 0 => i,
            string s when long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) => parsed,
            _ => null,
        };
}
