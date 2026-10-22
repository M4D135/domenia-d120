using System.Collections.Immutable;
using System.Security;
using System.Text.RegularExpressions;
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
/// before anything is read and the PDC emulator is resolved through <c>fSMORoleOwner</c> of the head of the domain (the bound
/// controller is read when it cannot be resolved, and the answer says so). The Security log of that controller is the only
/// source of the 4740 events; reading it needs the <c>System.Diagnostics.EventLog</c> library, which this wave is not allowed
/// to add as a new dependency, so the events are reported « unavailable » and never invented. The lockout state itself is read
/// from the directory attributes by the screen reader, not here. Read only: nothing is written and nothing is retried.
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

    /// <summary>Reason the 4740 events cannot be read in this version: the library is not allowed as a new dependency.</summary>
    private const string EventsUnavailableReason =
        "La lecture du journal Sécurité du contrôleur n’est pas disponible dans cette version : elle demande la bibliothèque "
        + "System.Diagnostics.EventLog, non autorisée comme nouvelle dépendance. L’état de verrouillage reste lu dans l’annuaire ; "
        + "l’origine des événements 4740 n’est pas établie.";

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

        var (server, isPdc) = await ResolvePdcAsync(connection, domain, fallbackServer, cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(server))
        {
            return new AdLockoutRead("unavailable", "aucun contrôleur", false, [], false, "Aucun contrôleur à interroger.");
        }

        // The events themselves need System.Diagnostics.EventLog (forbidden as a new dependency here): the read is reported
        // « unavailable », never « no lockout ». hours, maxEvents, account and password are kept for the day the library is
        // approved; they bound the query and carry the credential that would open the remote session.
        _ = hours;
        _ = maxEvents;
        _ = account;
        _ = password;
        return new AdLockoutRead("unavailable", server, isPdc, [], false, EventsUnavailableReason);
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
}
