using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Inventory;

/// <summary>Domenia 1-compatible generic credentials in the desktop user's local Windows profile; never roaming or enumerated.</summary>
public sealed class WindowsCredentialVault(IDirectorySource source) : IAccountsCredentialVault
{
    public bool Available => source.Kind == DirectorySourceKind.ActiveDirectory && OperatingSystem.IsWindows();

    public SecureString? Read(CredentialVaultTarget target)
    {
        RequireAvailable();
        var key = target.Key;
        var pointer = IntPtr.Zero;
        NativeCredential credential = default;
        SecureString? password = null;
        try
        {
            if (!CredReadW(key, 1, 0, out pointer))
            {
                var code = Marshal.GetLastWin32Error();
                if (code == 1168) { return null; }
                throw Failure("lecture", code);
            }
            if (pointer == IntPtr.Zero) { throw Invalid(); }
            credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            Validate(credential, key, target.Account.Trim());
            password = new SecureString();
            for (var index = 0; index < credential.BlobSize; index += 2)
            { password.AppendChar((char)(ushort)Marshal.ReadInt16(credential.Blob, index)); }
            password.MakeReadOnly();
            var result = password; password = null; return result;
        }
        finally
        {
            password?.Dispose();
            if (pointer != IntPtr.Zero)
            {
                // Only the documented bounded credential blob is touched; never follow arbitrary lengths on malformed data.
                if (credential.BlobSize <= CredentialVaultRules.MaxSecretBytes) { Clear(credential.Blob, credential.BlobSize); }
                CredFree(pointer);
            }
        }
    }

    public void Write(CredentialVaultTarget target, SecureString password)
    {
        ArgumentNullException.ThrowIfNull(password);
        RequireAvailable();
        var key = target.Key;
        using var snapshot = password.Copy();
        var bytes = checked((uint)snapshot.Length * 2);
        if (bytes is 0 or > CredentialVaultRules.MaxSecretBytes) { throw new ArgumentException("Secret absent ou hors limite du coffre."); }
        var blob = Marshal.SecureStringToCoTaskMemUnicode(snapshot);
        try
        {
            var credential = new NativeCredential { Type = 1, Target = key, UserName = target.Account.Trim(), Blob = blob, BlobSize = bytes, Persist = 2 };
            if (!CredWriteW(ref credential, 0)) { throw Failure("enregistrement", Marshal.GetLastWin32Error()); }
        }
        finally
        {
            Clear(blob, bytes); // explicit length also wipes characters after an embedded NUL
            Marshal.ZeroFreeCoTaskMemUnicode(blob);
        }
    }

    public bool Delete(CredentialVaultTarget target)
    {
        RequireAvailable();
        if (CredDeleteW(target.Key, 1, 0)) { return true; }
        var code = Marshal.GetLastWin32Error();
        if (code == 1168) { return false; }
        throw Failure("suppression", code);
    }

    private void RequireAvailable()
    {
        if (!Available) { throw new DomeniaOperationException(CredentialVaultRules.Unavailable, "Coffre Windows indisponible dans ce mode ; aucun accès effectué."); }
        using var impersonated = WindowsIdentity.GetCurrent(ifImpersonating: true);
        if (impersonated is not null)
        { throw new DomeniaOperationException(CredentialVaultRules.Unavailable, "Le coffre doit être utilisé dans le profil Windows du bureau, sans usurpation d’identité."); }
    }

    internal static void Validate(NativeCredential value, string target, string account)
    {
        if (value.Type != 1 || value.Target != target || !string.Equals(value.UserName, account, StringComparison.OrdinalIgnoreCase)
            || value.Blob == IntPtr.Zero || value.BlobSize is 0 or > CredentialVaultRules.MaxSecretBytes || value.BlobSize % 2 != 0)
        { throw Invalid(); }
    }
    private static DomeniaOperationException Invalid() => new(CredentialVaultRules.Failed, "Réponse du coffre incohérente ou hors limites ; aucune valeur utilisée.");
    private static DomeniaOperationException Failure(string operation, int code) => new(CredentialVaultRules.Failed, "Coffre Windows : " + operation + " refusée (code " + code + ").");
    private static void Clear(IntPtr pointer, uint bytes)
    { if (pointer != IntPtr.Zero) { for (var index = 0; index < bytes; index++) { Marshal.WriteByte(pointer, index, 0); } } }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NativeCredential
    {
        internal uint Flags;
        internal uint Type;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? Target;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? Comment;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        internal uint BlobSize;
        internal IntPtr Blob;
        internal uint Persist;
        internal uint AttributeCount;
        internal IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? UserName;
    }

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CredWriteW(ref NativeCredential credential, uint flags);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CredDeleteW(string target, uint type, uint flags);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("advapi32.dll", ExactSpelling = true)] private static extern void CredFree(IntPtr buffer);
}
