using System.Runtime.InteropServices;
using Domenia.Core;

namespace Domenia.App;

/// <summary>
/// Local join state of the workstation. NetGetJoinInformation and DsRoleGetPrimaryDomainInformation with a null server
/// read the local LSA state and contact no domain controller. No network at all.
/// </summary>
internal static partial class DomainJoin
{
    private const int NetSetupUnjoined = 1;
    private const int NetSetupWorkgroupName = 2;
    private const int NetSetupDomainName = 3;
    private const int DsRolePrimaryDomainInfoBasic = 1;

    /// <summary>Probe given to <see cref="ModeResolver"/>; any failure gives the « unknown » state.</summary>
    public static DomainJoinInfo Read()
    {
        try
        {
            var status = NetGetJoinInformation(null, out var buffer, out var joinStatus);
            string? name = null;
            try
            {
                if (status == 0 && buffer != IntPtr.Zero)
                {
                    name = Marshal.PtrToStringUni(buffer);
                }
            }
            finally
            {
                if (buffer != IntPtr.Zero)
                {
                    _ = NetApiBufferFree(buffer);
                }
            }
            if (status != 0)
            {
                TechnicalLog.Warning($"État de jonction illisible (NetGetJoinInformation : code {status}).");
                return new DomainJoinInfo(DomainJoinState.Unknown, null);
            }
            return joinStatus switch
            {
                // DNS name of the joined domain; the NetBIOS name of NetGetJoinInformation as a fallback.
                NetSetupDomainName => new DomainJoinInfo(DomainJoinState.Joined, ReadDomainDnsName() ?? name),
                NetSetupWorkgroupName => new DomainJoinInfo(DomainJoinState.Workgroup, null),
                NetSetupUnjoined => new DomainJoinInfo(DomainJoinState.Unjoined, null),
                _ => new DomainJoinInfo(DomainJoinState.Unknown, null),
            };
        }
        catch (DllNotFoundException ex)
        {
            TechnicalLog.Error("État de jonction illisible : netapi32 introuvable.", ex);
            return new DomainJoinInfo(DomainJoinState.Unknown, null);
        }
        catch (EntryPointNotFoundException ex)
        {
            TechnicalLog.Error("État de jonction illisible : fonction absente.", ex);
            return new DomainJoinInfo(DomainJoinState.Unknown, null);
        }
    }

    /// <summary>
    /// DNS name of the AD domain the computer is joined to, from the local LSA (not the primary DNS suffix, which may
    /// differ in a disjoint namespace), or null.
    /// </summary>
    private static string? ReadDomainDnsName()
    {
        try
        {
            var status = DsRoleGetPrimaryDomainInformation(IntPtr.Zero, DsRolePrimaryDomainInfoBasic, out var buffer);
            try
            {
                if (status != 0 || buffer == IntPtr.Zero)
                {
                    TechnicalLog.Warning($"Nom DNS du domaine illisible (DsRoleGetPrimaryDomainInformation : code {status}).");
                    return null;
                }
                // DSROLE_PRIMARY_DOMAIN_INFO_BASIC: MachineRole (4 bytes), Flags (4 bytes), then the DomainNameFlat and
                // DomainNameDns pointers.
                var dns = Marshal.ReadIntPtr(buffer, 8 + IntPtr.Size);
                var text = dns == IntPtr.Zero ? null : Marshal.PtrToStringUni(dns)?.Trim().TrimEnd('.');
                return string.IsNullOrEmpty(text) ? null : text;
            }
            finally
            {
                if (buffer != IntPtr.Zero)
                {
                    DsRoleFreeMemory(buffer);
                }
            }
        }
        catch (EntryPointNotFoundException ex)
        {
            TechnicalLog.Error("Nom DNS du domaine illisible : fonction absente.", ex);
            return null;
        }
    }

    [LibraryImport("netapi32.dll", StringMarshalling = StringMarshalling.Utf16)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static partial int NetGetJoinInformation(string? server, out IntPtr nameBuffer, out int status);

    [LibraryImport("netapi32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static partial int NetApiBufferFree(IntPtr buffer);

    [LibraryImport("netapi32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static partial int DsRoleGetPrimaryDomainInformation(IntPtr server, int infoLevel, out IntPtr buffer);

    [LibraryImport("netapi32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static partial void DsRoleFreeMemory(IntPtr buffer);
}
