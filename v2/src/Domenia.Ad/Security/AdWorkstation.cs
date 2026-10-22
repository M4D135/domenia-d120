using System.Management;
using System.Security;
using Domenia.Core;
using WmiEnumerationOptions = System.Management.EnumerationOptions;

namespace Domenia.Ad;

/// <summary>
/// One light read of a workstation with the account the operator gave (docs/ops/comptes.md § 7.4): a CIM session over DCOM to
/// <c>\\&lt;poste&gt;\root\cimv2</c> (Kerberos, packet privacy), one SELECT on <c>Win32_OperatingSystem</c> for its caption, a
/// method delay of 6 s and 30 s for the whole trial. Read only: never a method call, never a change. A refusal is told apart
/// from an unreachable workstation, and only an explicit success says « observed » (CPT-015).
/// </summary>
internal static class AdWorkstation
{
    private const int AccessDeniedHResult = unchecked((int)0x80070005);
    private const int LogonFailureHResult = unchecked((int)0x80070569);
    private const int RpcServerUnavailable = unchecked((int)0x800706BA);
    private const int RpcCallFailed = unchecked((int)0x800706BE);

    /// <summary>The caption of Win32_OperatingSystem, with the credential of the workstations (or the session itself).</summary>
    public static async Task<RemoteProbeAnswer> ProbeAsync(string computer, string account, SecureString? password, bool useSession, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(computer);
        if (!useSession && string.IsNullOrWhiteSpace(account))
        {
            return new RemoteProbeAnswer("authRejected", "credentialsRejected", null, null);
        }

        try
        {
            return await Task.Run(() => Read(computer, account, password, useSession), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new RemoteProbeAnswer("cancelled", "timeout", null, null);
        }
#pragma warning disable CA1031 // A trial that fails is an answer with its category, never an exception thrown at the page.
        catch (Exception ex)
        {
            return Classify(ex);
        }
#pragma warning restore CA1031
    }

    /// <summary>Name a local account of this workstation reports for the machine (Win32_ComputerSystem.Name), or null.</summary>
    public static async Task<string?> ReadMachineNameAsync(string computer, string account, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(computer);
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        ArgumentNullException.ThrowIfNull(password);
        try
        {
            return await Task.Run(() =>
            {
                using var scope = Connect(computer, account, password, TimeSpan.FromSeconds(5));
                var values = QueryOne(scope, "SELECT Name FROM Win32_ComputerSystem", TimeSpan.FromSeconds(5));
                return values is not null && values.TryGetValue("Name", out var name) && name is string text && !string.IsNullOrWhiteSpace(text)
                    ? text.Trim()
                    : null;
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
#pragma warning disable CA1031 // An unreadable workstation simply confirms nothing.
        catch (Exception)
        {
            return null;
        }
#pragma warning restore CA1031
    }

    private static RemoteProbeAnswer Read(string computer, string account, SecureString? password, bool useSession)
    {
        using var scope = useSession
            ? Connect(computer, null, null, TimeSpan.FromSeconds(6))
            : Connect(computer, account, password, TimeSpan.FromSeconds(6));
        var values = QueryOne(scope, "SELECT Caption FROM Win32_OperatingSystem", TimeSpan.FromSeconds(6));
        var caption = values is not null && values.TryGetValue("Caption", out var captionValue) && captionValue is string text && !string.IsNullOrWhiteSpace(text)
            ? text.Trim()
            : null;
        return new RemoteProbeAnswer("observed", null, caption, null);
    }

    private static ManagementScope Connect(string computer, string? account, SecureString? password, TimeSpan timeout)
    {
        var options = new ConnectionOptions
        {
            Impersonation = ImpersonationLevel.Impersonate,
            Authentication = AuthenticationLevel.PacketPrivacy,
            EnablePrivileges = false,
            Timeout = timeout,
        };
        if (!string.IsNullOrWhiteSpace(account) && password is not null)
        {
            var separator = account.IndexOf('\\', StringComparison.Ordinal);
            if (separator > 0)
            {
                options.Username = account[(separator + 1)..];
                options.Domain = account[..separator];
            }
            else
            {
                options.Username = account;
            }

            options.SecurePassword = password;
        }

        var scope = new ManagementScope(@"\\" + computer + @"\root\cimv2", options);
        scope.Connect();
        return scope;
    }

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

    private static RemoteProbeAnswer Classify(Exception ex)
    {
        for (Exception? current = ex; current is not null; current = current.InnerException)
        {
            var hresult = current switch
            {
                System.Runtime.InteropServices.COMException com => com.HResult,
                ManagementException management when management.ErrorCode is ManagementStatus status => unchecked((int)(uint)status),
                _ => 0,
            };
            switch (hresult)
            {
                case AccessDeniedHResult:
                    return new RemoteProbeAnswer("denied", "accessDenied", null, null);
                case LogonFailureHResult:
                    return new RemoteProbeAnswer("authRejected", "credentialsRejected", null, null);
                case RpcServerUnavailable or RpcCallFailed:
                    return new RemoteProbeAnswer("timeout", "network", null, null);
            }

            if (current is UnauthorizedAccessException)
            {
                return new RemoteProbeAnswer("denied", "accessDenied", null, null);
            }

            if (current is System.TimeoutException)
            {
                return new RemoteProbeAnswer("timeout", "timeout", null, null);
            }
        }

        var text = (ex.InnerException ?? ex).Message;
        return new RemoteProbeAnswer("error", "network", null, Shorten(text));
    }

    private static string? Shorten(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Length > 200 ? text[..200] : text;

}
