using System.Collections.Immutable;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Poste;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Inventory;

public sealed record WindowsSessionsRead(SourceStatus Status, ImmutableArray<LocalSession> Sessions, int Unread, DateTimeOffset At, string? Detail);

/// <summary>Read-only WTS enumeration. No logoff, disconnect, message or desktop change is exposed.</summary>
public sealed class WindowsSessionsReader(TimeProvider clock)
{
    private static readonly SemaphoreSlim Workers = new(4);
    internal const int ProtocolClass = 16;
    internal const int SessionInfoClass = 24;

    public async Task<WindowsSessionsRead> ReadAsync(string host, string? user, string? domain, SecureString? password, CancellationToken cancellationToken)
    {
        if (!CimQuery.IsHostName(host) || (user is null) != (password is null)) { throw new ArgumentException("Cible ou compte des sessions invalide."); }
        cancellationToken.ThrowIfCancellationRequested();
        if (!await Workers.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        { return new(SourceStatus.Unavailable, [], 0, clock.GetUtcNow(), "Lectures WTS précédentes encore en cours."); }
        SecureString? secret;
        try { secret = password?.Copy(); }
        catch { Workers.Release(); throw; }
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = stop.Token;
        var worker = Task.Run(() =>
        {
            try
            {
                using (secret)
                {
                    if (secret is null) { return Read(host, token); }
                    var pointer = Marshal.SecureStringToGlobalAllocUnicode(secret);
                    SafeAccessTokenHandle identity;
                    try
                    {
                        if (!LogonUserW(user!, string.IsNullOrEmpty(domain) ? null : domain, pointer, 9, 3, out identity))
                        { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    }
                    finally { Marshal.ZeroFreeGlobalAllocUnicode(pointer); }
                    using (identity) { return WindowsIdentity.RunImpersonated(identity, () => Read(host, token)); }
                }
            }
            catch (Win32Exception ex)
            { return new WindowsSessionsRead(ex.NativeErrorCode is 5 or 1314 or 1326 ? SourceStatus.Refused : SourceStatus.Unavailable, [], 0, clock.GetUtcNow(), "Lecture WTS refusée ou indisponible (code " + ex.NativeErrorCode + ")."); }
            catch (InvalidDataException) { return new WindowsSessionsRead(SourceStatus.Error, [], 0, clock.GetUtcNow(), "Réponse WTS hors limites."); }
            finally { Workers.Release(); }
        }, CancellationToken.None);
        try { return await worker.WaitAsync(TimeSpan.FromSeconds(5), clock, cancellationToken).ConfigureAwait(false); }
        catch (TimeoutException) { stop.Cancel(); return new(SourceStatus.Interrupted, [], 0, clock.GetUtcNow(), "Budget WTS de 5 s atteint."); }
        catch (OperationCanceledException) { stop.Cancel(); throw; }
        finally
        {
            // WTS has no cancellation API. Only the worker closes its handles after the native call returns.
            _ = worker.ContinueWith(t => { _ = t.Exception; stop.Dispose(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    private WindowsSessionsRead Read(string host, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var server = WTSOpenServerW(host);
        if (server == IntPtr.Zero || server == new IntPtr(-1)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        var buffer = IntPtr.Zero;
        try
        {
            token.ThrowIfCancellationRequested();
            if (!WTSEnumerateSessionsW(server, 0, 1, out buffer, out var count)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            if (count is < 0 or > 512 || count > 0 && buffer == IntPtr.Zero) { throw new InvalidDataException(); }
            var sessions = ImmutableArray.CreateBuilder<LocalSession>();
            var unread = 0;
            for (var i = 0; i < count; i++)
            {
                token.ThrowIfCancellationRequested();
                var item = Marshal.PtrToStructure<NativeSession>(IntPtr.Add(buffer, checked(i * Marshal.SizeOf<NativeSession>())));
                var user = QueryText(server, item.Id, 5, token);
                var domain = QueryText(server, item.Id, 7, token);
                var station = QueryText(server, item.Id, 6, token);
                var protocol = Query(server, item.Id, ProtocolClass, token);
                var info = Query(server, item.Id, SessionInfoClass, token);
                var (logon, idle) = Clocks(info, item.Id);
                var partial = user is null || domain is null;
                if (partial) { unread++; }
                sessions.Add(new(item.Id.ToString(System.Globalization.CultureInfo.InvariantCulture), station, user, domain,
                    partial ? "Information partielle" : State(item.State), Protocol(protocol), logon, idle, null));
            }
            return new(unread > 0 ? SourceStatus.Partial : count == 0 ? SourceStatus.Empty : SourceStatus.Ok, sessions.ToImmutable(), unread, clock.GetUtcNow(), unread > 0 ? "Certains comptes de session n’ont pas été lus." : null);
        }
        finally { if (buffer != IntPtr.Zero) { WTSFreeMemory(buffer); } WTSCloseServer(server); }
    }

    private static byte[]? Query(IntPtr server, int id, int kind, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var buffer = IntPtr.Zero;
        try
        {
            if (!WTSQuerySessionInformationW(server, id, kind, out buffer, out var size)) { return null; }
            if (size is < 0 or > 32768 || size > 0 && buffer == IntPtr.Zero) { throw new InvalidDataException(); }
            var bytes = new byte[size];
            if (size > 0) { Marshal.Copy(buffer, bytes, 0, size); }
            return bytes;
        }
        finally { if (buffer != IntPtr.Zero) { WTSFreeMemory(buffer); } }
    }

    private static string? QueryText(IntPtr server, int id, int kind, CancellationToken token)
    {
        var bytes = Query(server, id, kind, token);
        if (bytes is null) { return null; }
        if (bytes.Length % 2 != 0) { throw new InvalidDataException(); }
        return System.Text.Encoding.Unicode.GetString(bytes).TrimEnd('\0');
    }

    internal static string Protocol(byte[]? bytes) => bytes is { Length: >= 2 } ? BitConverter.ToUInt16(bytes) switch { 0 => "Console", 2 => "RDP", _ => "Autre" } : "Non lu";
    internal static string State(int value) => value switch { 0 => "Active", 1 => "Connectée", 2 => "Connexion", 3 => "Miroir", 4 => "Déconnectée", 5 => "Inactive", 6 => "Écoute", 7 => "Réinitialisation", 8 => "Arrêtée", 9 => "Initialisation", _ => "Non lu" };

    internal static (DateTimeOffset? Logon, TimeSpan? Idle) Clocks(byte[]? bytes, int sessionId)
    {
        // WTSINFOW: 8 DWORDs, WCHAR[32], WCHAR[17], WCHAR[21], padding to 8, 5 LARGE_INTEGERs.
        if (bytes is not { Length: >= 216 } || BitConverter.ToInt32(bytes, 4) != sessionId) { return (null, null); }
        var input = BitConverter.ToInt64(bytes, 192);
        var logon = AdValues.FromFileTime(BitConverter.ToInt64(bytes, 200));
        var now = BitConverter.ToInt64(bytes, 208);
        return (logon, input > 0 && now >= input && AdValues.FromFileTime(now) is not null ? TimeSpan.FromTicks(now - input) : null);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSession { public int Id; public IntPtr Name; public int State; }

    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr WTSOpenServerW(string server);
    [DllImport("wtsapi32.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern void WTSCloseServer(IntPtr server);
    [DllImport("wtsapi32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr buffer, out int count);
    [DllImport("wtsapi32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int info, out IntPtr buffer, out int size);
    [DllImport("wtsapi32.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern void WTSFreeMemory(IntPtr memory);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LogonUserW(string user, string? domain, IntPtr password, int type, int provider, out SafeAccessTokenHandle token);
}
