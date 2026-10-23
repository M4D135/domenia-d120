using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Poste;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Ad;

/// <summary>Native DPAPI-NG, one selected identity. Timed-out native work retains and clears its own resources.</summary>
internal static class LapsDecryptor
{
    private static readonly SemaphoreSlim Workers = new(2, 2);
    internal const string Denied = "poste.lapsDecryptDenied";
    internal const string Failed = "poste.lapsDecryptFailed";

    internal static async Task<LapsPassword> ReadAsync(byte[] blob, RemoteProbeCredential credential, CancellationToken token)
    {
        var timestamp = LapsPassword.CheckEnvelope(blob);
        token.ThrowIfCancellationRequested();
        if (!Workers.Wait(0)) { throw new DomeniaOperationException(PosteErrors.Busy, "Deux déchiffrements Windows sont encore en cours ; aucun nouveau travail lancé."); }
        RemoteProbeCredential? owned = null; byte[]? encrypted = null;
        Task<LapsPassword> work;
        try
        {
            owned = new(credential.Account, credential.Password?.Copy(), credential.Session);
            encrypted = blob.AsSpan(16).ToArray();
            var identity = owned; var input = encrypted;
            work = Task.Run(() =>
            {
                using (identity)
                {
                    try
                    {
                        token.ThrowIfCancellationRequested();
                        var value = UnderIdentity(identity, () => Decode(input, timestamp));
                        if (token.IsCancellationRequested) { value.Dispose(); token.ThrowIfCancellationRequested(); }
                        return value;
                    }
                    finally { CryptographicOperations.ZeroMemory(input); Workers.Release(); }
                }
            }, CancellationToken.None);
        }
        catch { owned?.Dispose(); if (encrypted is not null) { CryptographicOperations.ZeroMemory(encrypted); } Workers.Release(); throw; }
        try { return await work.WaitAsync(TimeSpan.FromSeconds(15), token).ConfigureAwait(false); }
        catch (Exception failure)
        {
            // The underlying API has no cancellation. Dispose a late plaintext result and observe a late fault.
            _ = work.ContinueWith(t => { if (t.Status == TaskStatus.RanToCompletion) { t.Result.Dispose(); } else { _ = t.Exception; } },
                CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            if (failure is TimeoutException)
            { throw new DomeniaOperationException(Failed, "Déchiffrement Windows sans réponse dans le délai ; aucune valeur affichée."); }
            throw;
        }
    }

    private static T UnderIdentity<T>(RemoteProbeCredential credential, Func<T> action)
    {
        if (credential.Session) { return action(); }
        if (credential.Password is null || !CredentialRules.IsWellFormed(credential.Account))
        { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Identité de déchiffrement incomplète ; aucun repli Windows."); }
        var name = CredentialRules.Parse(credential.Account!);
        var password = Marshal.SecureStringToGlobalAllocUnicode(credential.Password);
        SafeAccessTokenHandle identity;
        try
        {
            // NETWORK_CLEARTEXT validates the selected user and preserves outbound credentials for GKDI.
            // NEW_CREDENTIALS would retain the caller's local identity, which is not the requested decryption identity.
            if (!LogonUserW(name.Form == AccountNameForm.Upn ? credential.Account! : name.Name,
                name.Form == AccountNameForm.Upn ? null : name.Authority, password, 8, 3, out identity))
            { var error = Marshal.GetLastWin32Error(); identity?.Dispose(); throw Status(error, login: true); }
        }
        finally { Marshal.ZeroFreeGlobalAllocUnicode(password); }
        using (identity) { return WindowsIdentity.RunImpersonated(identity, action); }
    }

    private static LapsPassword Decode(byte[] blob, long timestamp)
    {
        IntPtr plaintext = IntPtr.Zero; uint count = 0; byte[]? bytes = null;
        try
        {
            // NCRYPT_SILENT_FLAG: no provider UI and no alternative identity prompt in a native worker.
            var status = NCryptUnprotectSecret(IntPtr.Zero, 0x40, blob, (uint)blob.Length, IntPtr.Zero, IntPtr.Zero, out plaintext, out count);
            if (status != 0) { throw Status(status); }
            if (plaintext == IntPtr.Zero || count is < 2 or > LapsPassword.MaxJsonBytes) { throw LapsPassword.Invalid(); }
            bytes = new byte[count]; Marshal.Copy(plaintext, bytes, 0, bytes.Length);
            return LapsPassword.ParseUtf16(bytes, timestamp);
        }
        catch (DllNotFoundException) { throw new DomeniaOperationException(Failed, "DPAPI-NG indisponible sur ce poste d’administration."); }
        catch (EntryPointNotFoundException) { throw new DomeniaOperationException(Failed, "Déchiffrement DPAPI-NG non pris en charge par Windows."); }
        finally
        {
            if (bytes is not null) { CryptographicOperations.ZeroMemory(bytes); }
            if (plaintext != IntPtr.Zero)
            {
                // Windows allocated this buffer with LocalAlloc. Clear before LocalFree, including malformed output.
                var zeros = new byte[4096];
                for (long offset = 0; offset < count; offset += zeros.Length)
                { Marshal.Copy(zeros, 0, new IntPtr(plaintext.ToInt64() + offset), (int)Math.Min(zeros.Length, count - offset)); }
                LocalFree(plaintext);
            }
        }
    }

    internal static DomeniaOperationException Status(int status, bool login = false)
    {
        if (WindowsAuthenticationErrors.IsRejected(status))
        { return new(AdErrors.Credentials, "Identifiants ou ouverture de session du compte LAPS refusés ; aucun autre compte essayé."); }
        if (status is 5 or unchecked((int)0x80070005) or unchecked((int)0x80090010) or unchecked((int)0xC0000022))
        { return new(Denied, login ? "Ouverture de session du compte sélectionné refusée ; aucun déchiffrement tenté." : "Valeur LAPS lue, mais déchiffrement refusé à ce compte."); }
        return new(Failed, "Déchiffrement LAPS non abouti (code Windows " + ((uint)status).ToString("X8", System.Globalization.CultureInfo.InvariantCulture) + ") ; aucun constat d’absence de mot de passe.");
    }

    [DllImport("ncrypt.dll")]
    private static extern int NCryptUnprotectSecret(IntPtr descriptor, uint flags, byte[] blob, uint size, IntPtr allocator, IntPtr window, out IntPtr plaintext, out uint length);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LogonUserW(string user, string? domain, IntPtr password, int logonType, int provider, out SafeAccessTokenHandle token);
}
