using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Domenia.App;

internal sealed record PackageSignatureVerdict(string Signature, bool WindowsAccepted, bool Pinned, bool Trusted,
    string? CertificateSha256, string? Publisher, string ExecutableSha256, string Policy, string PolicyIdentity, string Notice, int NativeStatus)
{
    internal void RequireAllowed(PackagePublisherPolicy policy)
    {
        if (PolicyIdentity != policy.Identity || policy.Problem is not null || Signature is not ("validLocal" or "unsigned") || policy.RequirePinnedPublisher && !Trusted)
            throw new InvalidDataException("DOMENIA_HOST_SIGNATURE : " + (policy.Problem ?? Notice));
    }
}
internal sealed record PackageNativeSignature(int Status, string? CertificateSha256, string? Publisher);

/// <summary>The handle remains read-locked from hashing through Authenticode and signer extraction. No manifest supplies trust.</summary>
internal static partial class PackagePublisherTrust
{
    internal const int NoSignature = unchecked((int)0x800B0100);
    internal const uint OfflineFlags = 0x1000 | 0x10 | 0x2000; // cache-only, no online revocation, reject MD2/MD4
    internal static PackageSignatureVerdict Verify(string executable, PackagePublisherPolicy policy,
        Func<FileStream, PackageNativeSignature>? verifier = null)
    {
        PackageLifecycleFiles.Check(executable);
        using var file = new FileStream(executable, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
        return Verify(file, policy, verifier);
    }
    internal static PackageSignatureVerdict Verify(FileStream file, PackagePublisherPolicy policy,
        Func<FileStream, PackageNativeSignature>? verifier = null)
    {
        if (!file.CanRead || file.Length is <= 0 or > 2L * 1024 * 1024 * 1024) throw new InvalidDataException("Exécutable hors limites de signature.");
        var position = file.Position;
        try
        {
            file.Position = 0; var hash = Convert.ToHexStringLower(SHA256.HashData(file)); file.Position = 0;
            var native = (verifier ?? WindowsSignature)(file);
            var accepted = native.Status == 0 && native.CertificateSha256 is { Length: 64 } sha && sha.All(char.IsAsciiHexDigit);
            var pinned = accepted && policy.CertificateSha256.Contains(native.CertificateSha256!, StringComparer.OrdinalIgnoreCase);
            var trusted = pinned && policy.Problem is null;
            var state = accepted ? "validLocal" : native.Status == NoSignature ? "unsigned" : "rejected";
            var text = state == "unsigned" ? "Exécutable non signé ; éditeur non certifié."
                : trusted ? "Signature Windows locale valide et certificat signataire épinglé par la politique machine."
                : accepted ? "Signature Windows locale valide ; éditeur non épinglé, confiance non établie."
                : "Signature non validée localement (0x" + native.Status.ToString("X8", System.Globalization.CultureInfo.InvariantCulture) + ").";
            return new(state, accepted, pinned, trusted, accepted ? native.CertificateSha256 : null, accepted ? native.Publisher : null, hash,
                policy.Problem is not null ? "invalid" : policy.RequirePinnedPublisher ? "required" : policy.CertificateSha256.IsEmpty ? "unconfigured" : "optional",
                policy.Identity, text + " Révocation en ligne non interrogée ; l’intégrité SHA-256 est un verdict séparé.", native.Status);
        }
        finally { file.Position = position; }
    }
    internal static unsafe PackageNativeSignature WindowsSignature(FileStream file)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Authenticode exige Windows.");
        var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
        fixed (char* path = file.Name)
        {
            var info = new TrustFile { Size = (uint)sizeof(TrustFile), Path = path, File = file.SafeFileHandle.DangerousGetHandle() };
            var data = new TrustData { Size = (uint)sizeof(TrustData), Ui = 2, Choice = 1, File = &info, Action = 1, Flags = OfflineFlags };
            try
            {
                var status = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                if (status != 0) return new(status, null, null);
                var provider = WTHelperProvDataFromStateData(data.State);
                var signer = provider == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvSignerFromChain(provider, 0, 0, 0);
                var cert = signer == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvCertFromChain(signer, 0);
                if (cert == IntPtr.Zero) return new(unchecked((int)0x800B0004), null, null);
                var head = Marshal.PtrToStructure<ProviderCertificate>(cert);
                if (head.Size < (uint)Marshal.SizeOf<ProviderCertificate>() || head.Certificate == IntPtr.Zero) return new(unchecked((int)0x800B0004), null, null);
                var encoded = Marshal.PtrToStructure<CertificateContext>(head.Certificate);
                if (encoded.Bytes is 0 or > 1_048_576 || encoded.Encoded == IntPtr.Zero) return new(unchecked((int)0x800B0004), null, null);
                var bytes = new byte[encoded.Bytes]; Marshal.Copy(encoded.Encoded, bytes, 0, bytes.Length);
                using var certificate = X509CertificateLoader.LoadCertificate(bytes);
                var subject = certificate.GetNameInfo(X509NameType.SimpleName, false);
                if (subject.Length > 256) subject = subject[..256];
                subject = string.Concat(subject.Where(c => !char.IsControl(c)));
                return new(0, Convert.ToHexString(SHA256.HashData(bytes)), subject);
            }
            finally { data.Action = 2; _ = WinVerifyTrust(new IntPtr(-1), ref action, ref data); }
        }
    }
    [StructLayout(LayoutKind.Sequential)] private unsafe struct TrustFile { internal uint Size; internal char* Path; internal IntPtr File; internal IntPtr Subject; }
    [StructLayout(LayoutKind.Sequential)] private unsafe struct TrustData
    {
        internal uint Size; internal IntPtr Policy; internal IntPtr Sip; internal uint Ui; internal uint Revocation;
        internal uint Choice; internal TrustFile* File; internal uint Action; internal IntPtr State; internal IntPtr Url;
        internal uint Flags; internal uint Context; internal IntPtr Signature;
    }
    // Only documented leading fields are read; the native size is checked before dereferencing the certificate.
    [StructLayout(LayoutKind.Sequential)] private struct ProviderCertificate { internal uint Size; internal IntPtr Certificate; }
    [StructLayout(LayoutKind.Sequential)] private struct CertificateContext { internal uint Encoding; internal IntPtr Encoded; internal uint Bytes; internal IntPtr Info; internal IntPtr Store; }
    [LibraryImport("wintrust.dll")] private static partial int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
    [LibraryImport("wintrust.dll")] private static partial IntPtr WTHelperProvDataFromStateData(IntPtr state);
    [LibraryImport("wintrust.dll")] private static partial IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint signer, int counter, uint counterIndex);
    [LibraryImport("wintrust.dll")] private static partial IntPtr WTHelperGetProvCertFromChain(IntPtr signer, uint index);
}
