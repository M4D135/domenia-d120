using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;

namespace Domenia.Security
{
    // Windows Credential Manager, generic credentials, current Windows user only.
    // No password is converted to a managed String or byte[] by this implementation.
    public static class CredentialVault
    {
        private const uint GenericCredential = 1;
        private const uint PersistLocalMachine = 2;
        private const int NotFound = 1168;
        public const int MaxSecretBytes = 2560;
        public const int MaxUserNameChars = 256;
        private const string TargetPrefix = "Domenia:v1:";

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Credential
        {
            public uint Flags;
            public uint Type;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredWrite(ref Credential credential, uint flags);
        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredDelete(string target, uint type, uint flags);
        [DllImport("advapi32.dll")]
        private static extern void CredFree(IntPtr buffer);

        private static void ValidateTarget(string target)
        {
            if (target == null || target.Length != TargetPrefix.Length + 64 ||
                !target.StartsWith(TargetPrefix, StringComparison.Ordinal))
                throw new ArgumentException("Cible du coffre Domenia invalide.", "target");
            for (int i = TargetPrefix.Length; i < target.Length; i++)
                if (!((target[i] >= '0' && target[i] <= '9') || (target[i] >= 'a' && target[i] <= 'f')))
                    throw new ArgumentException("Empreinte du coffre Domenia invalide.", "target");
        }
        private static void ValidateUserName(string userName)
        {
            if (String.IsNullOrWhiteSpace(userName) || userName.Length > MaxUserNameChars ||
                !String.Equals(userName, userName.Trim(), StringComparison.Ordinal))
                throw new ArgumentException("Identifiant absent ou hors limite.", "userName");
            foreach (char c in userName)
                if (Char.IsControl(c)) throw new ArgumentException("Identifiant invalide.", "userName");
        }
        private static void RequireWindows()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("Le coffre est disponible uniquement sous Windows.");
        }
        private static Win32Exception Failure(string operation, int code)
        {
            // Do not include a target, account or native memory content in diagnostic output.
            return new Win32Exception(code, "Coffre Windows : " + operation + " impossible (code " + code + ").");
        }
        private static void ClearBlob(IntPtr blob, uint size)
        {
            if (blob == IntPtr.Zero || size > MaxSecretBytes) return;
            for (int i = 0; i < (int)size; i++) Marshal.WriteByte(blob, i, 0);
        }

        public static void Write(string target, string userName, SecureString password)
        {
            ValidateTarget(target);
            ValidateUserName(userName);
            if (password == null || password.Length == 0 || password.Length > MaxSecretBytes / 2)
                throw new ArgumentException("Secret absent ou hors limite du coffre Windows.", "password");
            RequireWindows();
            // Copy first: caller changes cannot make the byte length differ from the marshalled snapshot.
            using (SecureString snapshot = password.Copy())
            {
                snapshot.MakeReadOnly();
                uint byteCount = checked((uint)(snapshot.Length * 2));
                if (byteCount == 0 || byteCount > MaxSecretBytes)
                    throw new ArgumentException("Secret absent ou hors limite du coffre Windows.", "password");
                IntPtr blob = IntPtr.Zero;
                try
                {
                    blob = Marshal.SecureStringToCoTaskMemUnicode(snapshot);
                    Credential credential = new Credential();
                    credential.Type = GenericCredential;
                    credential.TargetName = target;
                    credential.UserName = userName;
                    credential.CredentialBlob = blob;
                    credential.CredentialBlobSize = byteCount;
                    credential.Persist = PersistLocalMachine;
                    if (!CredWrite(ref credential, 0)) throw Failure("enregistrement", Marshal.GetLastWin32Error());
                }
                finally
                {
                    if (blob != IntPtr.Zero)
                    {
                        // Explicit byte length also clears any content beyond an embedded NUL character.
                        ClearBlob(blob, byteCount);
                        Marshal.ZeroFreeCoTaskMemUnicode(blob);
                    }
                }
            }
        }

        // A missing credential is an ordinary null result. Every other native error is surfaced.
        // Caller owns the returned SecureString and must dispose it at the end of the credential lifetime.
        public static SecureString Read(string target, string expectedUserName)
        {
            ValidateTarget(target);
            ValidateUserName(expectedUserName);
            RequireWindows();
            IntPtr native = IntPtr.Zero;
            Credential credential = new Credential();
            SecureString password = null;
            try
            {
                if (!CredRead(target, GenericCredential, 0, out native))
                {
                    int code = Marshal.GetLastWin32Error();
                    if (code == NotFound) return null;
                    throw Failure("lecture", code);
                }
                if (native == IntPtr.Zero) throw new InvalidOperationException("Reponse vide du coffre Windows.");
                credential = (Credential)Marshal.PtrToStructure(native, typeof(Credential));
                if (credential.Type != GenericCredential ||
                    !String.Equals(credential.TargetName, target, StringComparison.Ordinal) ||
                    !String.Equals(credential.UserName, expectedUserName, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Identite incoherente dans le coffre Windows.");
                if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0 ||
                    credential.CredentialBlobSize > MaxSecretBytes || (credential.CredentialBlobSize & 1) != 0)
                    throw new InvalidOperationException("Secret du coffre Windows absent ou de taille invalide.");
                password = new SecureString();
                for (int i = 0; i < (int)credential.CredentialBlobSize; i += 2)
                    password.AppendChar((char)(ushort)Marshal.ReadInt16(credential.CredentialBlob, i));
                password.MakeReadOnly();
                SecureString result = password;
                password = null;
                return result;
            }
            finally
            {
                if (password != null) password.Dispose();
                if (native != IntPtr.Zero)
                {
                    ClearBlob(credential.CredentialBlob, credential.CredentialBlobSize);
                    CredFree(native);
                }
            }
        }

        public static bool Delete(string target)
        {
            ValidateTarget(target);
            RequireWindows();
            if (CredDelete(target, GenericCredential, 0)) return true;
            int code = Marshal.GetLastWin32Error();
            if (code == NotFound) return false;
            throw Failure("suppression", code);
        }
    }
}
