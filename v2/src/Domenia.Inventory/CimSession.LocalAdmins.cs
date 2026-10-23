using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Poste;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    internal Func<string, CimReading>? LocalAdminsOverride { get; init; }

    internal CimReading ReadLocalAdmins()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        const string category = InventoryCategories.Admins;
        var begin = clock.GetTimestamp();
        var identity = Read(category, @"root\cimv2", "SELECT Name, DomainRole FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3));
        if (identity.Status != SourceStatus.Ok) { return identity; }
        var computer = identity.Instances.Single();
        if (!string.Equals(computer.Text("Name"), CredentialRules.MachineKey(Host), StringComparison.OrdinalIgnoreCase))
        { return new(category, SourceStatus.Error, "Identité du poste non confirmée ; aucun groupe local interrogé.", identity.DurationMs, []); }
        if (computer.Int("DomainRole") is 4 or 5)
        { return new(category, SourceStatus.Skipped, "Contrôleur de domaine : aucun groupe du domaine assimilé à un groupe local.", identity.DurationMs, []); }
        if (computer.Int("DomainRole") is not (>= 0 and <= 3))
        { return new(category, SourceStatus.Unavailable, "Rôle du poste non établi ; aucun groupe local interrogé.", identity.DurationMs, []); }
        var group = Read(category, @"root\cimv2", "SELECT Name, SID, LocalAccount FROM Win32_Group WHERE LocalAccount=True AND SID='S-1-5-32-544'", 2, TimeSpan.FromSeconds(3));
        if (!group.Answered) { return group; }
        if (group.Status != SourceStatus.Ok || group.Items != 1 || group.Instances[0].Text("SID") != "S-1-5-32-544"
            || group.Instances[0].Bool("LocalAccount") != true || group.Instances[0].Text("Name") is not { Length: > 0 and <= 256 } name || name.Any(char.IsControl))
        { return new(category, SourceStatus.Error, "Groupe intégré des administrateurs non identifié sans ambiguïté.", identity.DurationMs + group.DurationMs, []); }
        if (OutOfBudget || cancellationToken.IsCancellationRequested)
        { return new(category, SourceStatus.Interrupted, "Budget atteint avant la lecture des membres locaux.", (int)clock.GetElapsedTime(begin).TotalMilliseconds, []); }
        try
        {
            var result = LocalAdminsOverride?.Invoke(name) ?? WithNetworkIdentity(() => NativeLocalAdmins(name));
            authenticationRefused |= result.AuthenticationRejected;
            return result with { DurationMs = (int)clock.GetElapsedTime(begin).TotalMilliseconds };
        }
        catch (Win32Exception ex)
        {
            authenticationRefused |= WindowsAuthenticationErrors.IsRejected(ex.NativeErrorCode);
            return new(category, ex.NativeErrorCode is 5 or 1314 || authenticationRefused ? SourceStatus.Refused : SourceStatus.Unavailable,
                "Lecture NetAPI refusée ou indisponible (code " + ex.NativeErrorCode + ").", (int)clock.GetElapsedTime(begin).TotalMilliseconds, []) { AuthenticationRejected = authenticationRefused };
        }
    }

    private T WithNetworkIdentity<T>(Func<T> read)
    {
        if (credential is null or { Session: true }) { return read(); }
        var name = CredentialRules.Parse(credential.Account!);
        var pointer = Marshal.SecureStringToGlobalAllocUnicode(credential.Password!);
        SafeAccessTokenHandle identity;
        try
        {
            if (!LogonUserW(name.Form == AccountNameForm.Upn ? credential.Account! : name.Name,
                name.Form == AccountNameForm.Upn || name.Authority.Length == 0 ? null : name.Authority, pointer, 9, 3, out identity))
            { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
        finally { Marshal.ZeroFreeGlobalAllocUnicode(pointer); }
        using (identity) { return WindowsIdentity.RunImpersonated(identity, read); }
    }

    private CimReading NativeLocalAdmins(string group)
    {
        var rows = new List<WmiInstance>();
        nuint resume = 0;
        uint code;
        var incomplete = false;
        do
        {
            var buffer = IntPtr.Zero;
            try
            {
                // Drain ERROR_MORE_DATA even after cancellation: Microsoft requires this to release the RPC enumeration.
                // Only this bounded worker keeps the credential/handle; the UI can stop waiting independently.
                code = NetLocalGroupGetMembers(@"\\" + Host, group, 3, out buffer, uint.MaxValue, out var count, out _, ref resume);
                if (code is not (0 or 234)) { break; }
                if (count > 0 && buffer == IntPtr.Zero) { incomplete = true; continue; }
                if (cancellationToken.IsCancellationRequested || OutOfBudget || count > 500 - rows.Count) { incomplete = true; }
                var take = Math.Min(count, (uint)(500 - rows.Count));
                for (var i = 0; i < take; i++)
                {
                    if (cancellationToken.IsCancellationRequested || OutOfBudget) { break; }
                    var pointer = Marshal.ReadIntPtr(buffer, checked((int)i * IntPtr.Size));
                    var account = BoundedNativeName(pointer);
                    if (account is null) { incomplete = true; continue; }
                    rows.Add(new(new Dictionary<string, object?> { ["Name"] = account }));
                }
            }
            finally { if (buffer != IntPtr.Zero) { NetApiBufferFree(buffer); } }
        } while (code == 234);
        var rejected = WindowsAuthenticationErrors.IsRejected(unchecked((int)code));
        var status = code != 0 ? rows.Count > 0 ? SourceStatus.Partial : code == 5 || rejected ? SourceStatus.Refused : SourceStatus.Unavailable
            : incomplete ? SourceStatus.Partial : rows.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok;
        return new(InventoryCategories.Admins, status, "NetAPI, membres directs du groupe intégré S-1-5-32-544."
            + (status == SourceStatus.Partial ? " Liste incomplète : plafond de 500, interruption ou réponse partielle." : ""), 0, rows) { AuthenticationRejected = rejected };
    }

    private static string? BoundedNativeName(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) { return null; }
        for (var length = 0; length <= 512; length++)
        {
            var c = (char)Marshal.ReadInt16(pointer, length * 2);
            if (c == '\0') { return length > 0 ? Marshal.PtrToStringUni(pointer, length) : null; }
            if (char.IsControl(c)) { return null; }
        }
        return null;
    }

    [DllImport("Netapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint NetLocalGroupGetMembers(string server, string group, uint level, out IntPtr buffer, uint preferred,
        out uint count, out uint total, ref nuint resume);
    [DllImport("Netapi32.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint NetApiBufferFree(IntPtr buffer);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LogonUserW(string user, string? domain, IntPtr password, int logonType, int provider, out SafeAccessTokenHandle token);
}
