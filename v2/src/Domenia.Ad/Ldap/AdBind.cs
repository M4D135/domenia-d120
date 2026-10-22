using System.DirectoryServices.Protocols;
using System.Globalization;
using System.Net;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Ad;

/// <summary>
/// Outcome of one explicit authentication (CPT-021): the kind of the answer, the identity that really bound and the controller
/// that answered. Kinds are the ones the Comptes screen words out (<c>CredentialRules.FailureText</c>).
/// </summary>
internal sealed record AdBindAnswer(bool Success, string Kind, string? BindUser, string? Controller, string? Detail);

/// <summary>
/// One explicit authentication against the directory (docs/ops/comptes.md § 7.4): a short-lived connection to the controller of
/// the session, a <see cref="NetworkCredential"/> built on the <see cref="SecureString"/> given by the caller, Negotiate, signed
/// and sealed, ONE bind, 12 s. The identity that bound is read back with the extended « whoami » request
/// (OID 1.3.6.1.4.1.4203.1.11.3) and its domain must be the domain of the session, otherwise the answer is « identityMismatch »:
/// a success is never claimed on an unconfirmed identity. A refused bind is classified with the sub-code the controller puts in
/// its server-diagnostic message (« data 775 », the rule of Domenia 1 <c>Get-DomeniaLoginFailureText</c>). Nothing is retried and
/// no variant of the identity is tried silently; the password never leaves the credential it was given in and is never traced.
/// </summary>
internal static partial class AdBind
{
    /// <summary>Extended request that answers who bound (RFC 4532, « whoami »; Active Directory answers « u:DOMAINE\compte »).</summary>
    public const string WhoAmIOid = "1.3.6.1.4.1.4203.1.11.3";

    /// <summary>Longest wait for one bind and its read-back (docs/ops/comptes.md § 5.2: 12 s).</summary>
    public static readonly TimeSpan BindTimeout = TimeSpan.FromSeconds(12);

    private const int InvalidCredentials = 49;
    private const int ServerUnavailable = 81;
    private const int LocalError = 82;
    private const int Timeout = 85;

    [GeneratedRegex(@"data\s+([0-9a-fA-F]{3,4})", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 200)]
    private static partial Regex SubCode();

    /// <summary>
    /// Binds once with <paramref name="password"/> and reads back the identity. <paramref name="server"/> null: the domain locator
    /// of <paramref name="domainDnsName"/>. <paramref name="expectedAuthority"/> is the NetBIOS or DNS name of the domain the
    /// identity must belong to (case ignored); null skips that check (a workstation trial).
    /// </summary>
    public static async Task<AdBindAnswer> ValidateAsync(
        string? server,
        string? domainDnsName,
        string login,
        SecureString password,
        string? expectedAuthority,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(login);
        ArgumentNullException.ThrowIfNull(password);
        if (password.Length == 0)
        {
            return new AdBindAnswer(false, "input", null, server, null);
        }

        cancellationToken.ThrowIfCancellationRequested();
        var target = string.IsNullOrWhiteSpace(server) ? domainDnsName : server;
        LdapConnection? connection = null;
        try
        {
            connection = CreateConnection(target);
            var credential = new NetworkCredential(login, password);
            await Task.Run(() => connection.Bind(credential), cancellationToken).ConfigureAwait(false);
            var who = await Task.Run(() => WhoBound(connection), cancellationToken).ConfigureAwait(false);
            if (who is null)
            {
                return new AdBindAnswer(false, "identityMismatch", null, connection.Server, "L’annuaire n’a pas répondu à la demande d’identité.");
            }

            if (expectedAuthority is not null && !SameAuthority(who, expectedAuthority))
            {
                return new AdBindAnswer(false, "identityMismatch", who, connection.Server, "Identité hors du domaine de la session.");
            }

            return new AdBindAnswer(true, "ok", who, connection.Server, null);
        }
        catch (OperationCanceledException)
        {
            return new AdBindAnswer(false, "cancelled", null, server, null);
        }
#pragma warning disable CA1031 // A failed validation is an answer with its kind, never an exception thrown at the page.
        catch (Exception ex)
        {
            return Classify(ex, server);
        }
#pragma warning restore CA1031
        finally
        {
            connection?.Dispose();
        }
    }

    private static LdapConnection CreateConnection(string? target)
    {
        var identifier = new LdapDirectoryIdentifier(
            string.IsNullOrWhiteSpace(target) ? null : target,
            389,
            fullyQualifiedDnsHostName: !string.IsNullOrWhiteSpace(target),
            connectionless: false);
        var connection = new LdapConnection(identifier, null, AuthType.Negotiate) { Timeout = BindTimeout };
        var session = connection.SessionOptions;
        session.ProtocolVersion = 3;
        session.Signing = true;
        session.Sealing = true;
        session.ReferralChasing = ReferralChasingOptions.None;
        return connection;
    }

    /// <summary>The identity the controller says bound (« DOMAINE\compte »), or null when the answer is missing or empty.</summary>
    private static string? WhoBound(LdapConnection connection)
    {
        var response = (ExtendedResponse?)connection.SendRequest(new ExtendedRequest(WhoAmIOid), BindTimeout);
        var bytes = response?.ResponseData;
        if (bytes is null || bytes.Length < 3)
        {
            return null;
        }

        var text = Encoding.UTF8.GetString(bytes);
        // The answer is « u:DOMAINE\compte » for a user, « p:DOMAINE\poste$ » for a computer.
        var colon = text.IndexOf(':', StringComparison.Ordinal);
        var who = colon >= 0 ? text[(colon + 1)..] : text;
        return who.Trim().Length == 0 ? null : who.Trim();
    }

    private static bool SameAuthority(string bindUser, string expectedAuthority)
    {
        var separator = bindUser.IndexOf('\\', StringComparison.Ordinal);
        var authority = separator > 0 ? bindUser[..separator] : bindUser;
        if (string.Equals(authority, expectedAuthority, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        // The controller may answer with the DNS name instead of the NetBIOS name.
        var dot = expectedAuthority.IndexOf('.', StringComparison.Ordinal);
        return dot > 0 && string.Equals(authority, expectedAuthority[..dot], StringComparison.OrdinalIgnoreCase);
    }

    private static AdBindAnswer Classify(Exception ex, string? server)
    {
        var response = (ex as DirectoryOperationException)?.Response;
        var code = response is not null ? (int)response.ResultCode : (ex as LdapException)?.ErrorCode ?? -1;
        var detail = Diagnostic(ex, response);
        if (code == InvalidCredentials)
        {
            return new AdBindAnswer(false, SubCodeKind(detail), null, server ?? response?.Message, null);
        }

        if (code == Timeout)
        {
            return new AdBindAnswer(false, "timeout", null, server, null);
        }

        if (code is ServerUnavailable or LocalError)
        {
            return new AdBindAnswer(false, "unreachable", null, server, null);
        }

        return new AdBindAnswer(false, "unreachable", null, server, null);
    }

    /// <summary>Server-diagnostic message and exception texts, joined the way Domenia 1 joins them before matching « data 775 ».</summary>
    private static string Diagnostic(Exception ex, DirectoryResponse? response)
    {
        var builder = new StringBuilder();
        Append(builder, response?.ServerDiagnosticMessage);
        for (Exception? current = ex; current is not null; current = current.InnerException)
        {
            Append(builder, current.Message);
            if (current is LdapException ldap)
            {
                Append(builder, ldap.ServerDiagnosticMessage);
            }
        }

        return builder.ToString();
    }

    private static void Append(StringBuilder builder, string? text)
    {
        if (!string.IsNullOrWhiteSpace(text))
        {
            if (builder.Length > 0)
            {
                builder.Append(" | ");
            }

            builder.Append(text);
        }
    }

    /// <summary>Sub-code of the controller (MS-ADTS), read like Domenia 1: « data 775 ». Unknown sub-codes stay a plain refusal.</summary>
    private static string SubCodeKind(string diagnostic)
    {
        var match = SubCode().Match(diagnostic);
        var sub = match.Success ? match.Groups[1].Value.ToLower(CultureInfo.InvariantCulture) : "";
        return sub switch
        {
            "525" => "unknownAccount",
            "532" => "passwordExpired",
            "533" => "disabled",
            "701" => "accountExpired",
            "773" => "mustChange",
            "775" => "locked",
            "52e" => "badCredentials",
            _ => "logonFailure",
        };
    }
}
