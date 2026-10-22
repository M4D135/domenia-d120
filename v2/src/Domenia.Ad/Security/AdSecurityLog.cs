using System.Collections.Immutable;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Security;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// What one read of the security log gave: the state (« read », « refused » or « unavailable », the three of Domenia 1), the
/// controller that was read and whether it really is the PDC emulator, the events, and the reason of a failure without any
/// technical text. A refused or unavailable read never means « no lockout ».
/// </summary>
internal sealed record AdLockoutRead(
    string State,
    string Server,
    bool ServerIsPdc,
    ImmutableArray<LockoutEventRead> Events,
    bool Truncated,
    string? Error);

/// <summary>
/// 4740 events of one account (Domenia 1 <c>Domenia-Lockout.Worker.ps1</c>, docs/ops/comptes.md § 7.2): the SID is checked
/// before anything is read, the PDC emulator is resolved through <c>fSMORoleOwner</c> of the head of the domain (the bound
/// controller is read when it cannot be resolved, and the answer says so), then the Security log of that controller is read with
/// one XPath query bound to the event 4740 and to that single SID, at most 200 events within 30 s. In event 4740 the field
/// <c>TargetDomainName</c> carries the computer at the origin (the rule of Domenia 1). Read only: nothing is written, nothing is
/// retried, and a refusal is told apart from an unreachable controller.
/// </summary>
internal static partial class AdSecurityLog
{
    /// <summary>SID of an account of this domain, the only one a log read is launched for (Domenia 1: same shape).</summary>
    [GeneratedRegex(@"^S-1-5-21(-\d{1,10}){4}$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex AccountSid();

    [GeneratedRegex(@"^CN=NTDS Settings,(CN=[^,]+,CN=Servers,.+)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 200)]
    private static partial Regex NtdsSettings();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex HostName();

    private const int TimeoutSeconds = 30;
    private const int MaxCallerLength = 255;

    /// <summary>
    /// Reads the 4740 events of <paramref name="sid"/> on the PDC emulator of <paramref name="domain"/>.
    /// <paramref name="fallbackServer"/> is the controller of the session, used when the emulator cannot be resolved.
    /// </summary>
    public static async Task<AdLockoutRead> ReadLockoutsAsync(
        IAdConnection connection,
        DomainInfo domain,
        string sid,
        int hours,
        int maxEvents,
        string? fallbackServer,
        string? account,
        SecureString? password,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(domain);
        if (!AccountSid().IsMatch(sid ?? ""))
        {
            throw new DomeniaOperationException(AccountsRules.SidInvalid, AccountsRules.SidInvalidMessage);
        }

        var window = Math.Clamp(hours, AccountsLockouts.MinHours, AccountsLockouts.MaxHours);
        var bound = Math.Clamp(maxEvents, 1, AccountsLockouts.MaxEvents);
        var (server, isPdc) = await ResolvePdcAsync(connection, domain, fallbackServer, cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(server))
        {
            return new AdLockoutRead("unavailable", "aucun contrôleur", false, [], false, "Aucun contrôleur à interroger.");
        }

        try
        {
            var events = await Task.Run(() => ReadEvents(server, sid, window, bound, account, password), cancellationToken).ConfigureAwait(false);
            var truncated = events.Count >= bound;
            return new AdLockoutRead("read", server, isPdc, [.. events.Take(bound)], truncated, null);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
#pragma warning disable CA1031 // A log that cannot be read is a state in the report, never an exception thrown at the page.
        catch (Exception ex)
        {
            var state = IsAccessRefused(ex) ? "refused" : "unavailable";
            var text = (ex.InnerException ?? ex).Message;
            return new AdLockoutRead(state, server, isPdc, [], false, text.Length > 400 ? text[..400] : text);
        }
#pragma warning restore CA1031
    }

    /// <summary>
    /// The PDC emulator: <c>fSMORoleOwner</c> of the head of the domain names the server object, whose <c>dNSHostName</c> is the
    /// controller to read. Without that chain the bound controller is used, and the caller says so.
    /// </summary>
    public static async Task<(string? Server, bool IsPdc)> ResolvePdcAsync(IAdConnection connection, DomainInfo domain, string? fallbackServer, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(domain);
        try
        {
            var head = await connection.ReadAsync(domain.RootDn, ["fSMORoleOwner"], cancellationToken).ConfigureAwait(false);
            if (head?.String("fSMORoleOwner") is string owner && NtdsSettings().Match(owner) is { Success: true } match)
            {
                var serverObject = await connection.ReadAsync(match.Groups[1].Value, ["dNSHostName"], cancellationToken).ConfigureAwait(false);
                if (serverObject?.String("dNSHostName") is string host && HostName().IsMatch(host))
                {
                    return (host, true);
                }
            }
        }
        catch (DomeniaOperationException)
        {
            // No answer for the role: the bound controller is read, and the report says it is not the emulator.
        }

        return (string.IsNullOrWhiteSpace(fallbackServer) ? null : fallbackServer, false);
    }

    private static List<LockoutEventRead> ReadEvents(string server, string sid, int hours, int maxEvents, string? account, SecureString? password)
    {
        var window = (long)TimeSpan.FromHours(hours).TotalMilliseconds;
        var xpath = "*[System[EventID=4740 and TimeCreated[timediff(@SystemTime) <= " + window.ToString(CultureInfo.InvariantCulture) + "]]]"
            + " and *[EventData[Data[@Name='TargetSid']='" + sid + "']]";
        using var session = string.IsNullOrEmpty(account) || password is null
            ? new EventLogSession(server, "Security")
            : new EventLogSession(server, "Security", account, null, password, LogSessionType.EventLog);
        var query = new EventLogQuery("Security", PathType.LogName, xpath)
        {
            Session = session,
            ReverseDirection = true,
            ReadExistingOnly = true,
        };

        var events = new List<LockoutEventRead>(maxEvents);
        using var reader = new EventLogReader(query);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(TimeoutSeconds));
        for (EventRecord? record = reader.ReadEvent(); record is not null; record = reader.ReadEvent())
        {
            using (record)
            {
                if (timeout.IsCancellationRequested)
                {
                    break;
                }

                if (record.Properties.TryGetValue("TargetSid", out var target) && target?.Value is string read && !string.Equals(read, sid, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var caller = Property(record, "TargetDomainName");
                if (caller.Length > MaxCallerLength)
                {
                    caller = caller[..MaxCallerLength];
                }

                events.Add(new LockoutEventRead(
                    record.TimeCreated is DateTimeOffset at ? at.ToUniversalTime() : DateTimeOffset.MinValue,
                    caller.Length == 0 ? "non renseigné" : caller,
                    record.MachineName ?? server));
                if (events.Count >= maxEvents)
                {
                    return events;
                }
            }
        }

        return events;
    }

    private static string Property(EventRecord record, string name) =>
        record.Properties.TryGetValue(name, out var value) && value?.Value is string text ? text.Trim() : "";

    /// <summary>« Access denied » is a refusal (the operator lacks the right), anything else leaves the controller unreachable.</summary>
    private static bool IsAccessRefused(Exception ex)
    {
        for (Exception? current = ex; current is not null; current = current.InnerException)
        {
            if (current is UnauthorizedAccessException)
            {
                return true;
            }

            if (current is EventLogException eventLog && eventLog.NativeErrorCode is 5 or 1312)
            {
                return true;
            }
        }

        return false;
    }
}
