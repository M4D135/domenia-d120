using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Domenia.Core;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Inventory;

internal static class RemoteNetworkIdentity
{
    internal static T Run<T>(RemoteProbeCredential? credential, Func<T> action)
    {
        if (credential is null or { Session: true }) { return action(); }
        if (credential.Password is null || !CredentialRules.IsWellFormed(credential.Account))
        { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Compte distant incomplet ; aucun repli Windows."); }
        var name = CredentialRules.Parse(credential.Account!);
        var pointer = Marshal.SecureStringToGlobalAllocUnicode(credential.Password);
        SafeAccessTokenHandle identity;
        try
        {
            if (!LogonUserW(name.Form == AccountNameForm.Upn ? credential.Account! : name.Name,
                name.Form == AccountNameForm.Upn || name.Authority.Length == 0 ? null : name.Authority, pointer, 9, 3, out identity))
            { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
        finally { Marshal.ZeroFreeGlobalAllocUnicode(pointer); }
        using (identity) { return WindowsIdentity.RunImpersonated(identity, action); }
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LogonUserW(string user, string? domain, IntPtr password, int logonType, int provider, out SafeAccessTokenHandle token);
}
