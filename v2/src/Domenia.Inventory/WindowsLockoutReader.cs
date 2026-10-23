using System.Collections.Immutable;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Inventory;

/// <summary>One bounded, SID-filtered read of Security/4740 through the native Windows Event Log API.</summary>
public sealed class WindowsLockoutReader(TimeProvider clock)
{
    private static readonly SemaphoreSlim Workers = new(4, 4);

    public async Task<LockoutEventsRead> ReadAsync(string server, string sid, bool pdc, DateTimeOffset from, DateTimeOffset to,
        int maximum, string? user, string? domain, SecureString? password, CancellationToken cancellationToken)
    {
        var xpath = Query(sid, from, to);
        if (!CimQuery.IsHostName(server) || maximum is < 1 or > 500 || (user is null) != (password is null))
        { throw new ArgumentException("Cible, limite ou compte du journal invalide."); }
        if (!await Workers.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        { return new(LockoutReadState.Unavailable, server, pdc, [], false); }
        SecureString? secret;
        try { secret = password?.Copy(); }
        catch { Workers.Release(); throw; }
        var tracked = SecureCredentialCopies.Track(secret);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = stop.Token;
        var worker = Task.Run(() =>
        {
            using (secret)
            using (tracked)
            {
                try { return Read(server, sid, pdc, from, to, maximum, xpath, user, domain, secret, token); }
                catch (Win32Exception ex)
                {
                    token.ThrowIfCancellationRequested();
                    return new LockoutEventsRead(ex.NativeErrorCode is 5 or 1314 or 1326 ? LockoutReadState.Refused : LockoutReadState.Unavailable, server, pdc, [], false);
                }
                catch (Exception ex) when (ex is XmlException or InvalidDataException or FormatException)
                { return new LockoutEventsRead(LockoutReadState.Unavailable, server, pdc, [], false); }
            }
        }, CancellationToken.None);
        try { return await worker.WaitAsync(TimeSpan.FromSeconds(25), clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            stop.Cancel();
            if (ex is OperationCanceledException) { throw; }
            return new(LockoutReadState.Unavailable, server, pdc, [], false);
        }
        finally
        {
            // The worker owns handles and its secure copy until the native call actually returns.
            _ = worker.ContinueWith(t => { _ = t.Exception; stop.Dispose(); Workers.Release(); }, CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    internal static string Query(string sid, DateTimeOffset from, DateTimeOffset to)
    {
        if (!AccountsRules.IsDomainSid(sid) || from >= to || to - from > TimeSpan.FromHours(AccountsLockouts.MaxHours))
        { throw new ArgumentException("SID ou fenêtre du journal invalide."); }
        static string Stamp(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
        return "*[System[Provider[@Name='Microsoft-Windows-Security-Auditing'] and EventID=4740 and TimeCreated[@SystemTime >= '"
            + Stamp(from) + "' and @SystemTime <= '" + Stamp(to) + "']]] and *[EventData[Data[@Name='TargetSid']='" + sid + "']]";
    }

    internal static LockoutEventRead Parse(string xml, string sid, DateTimeOffset from, DateTimeOffset to)
    {
        using var input = new StringReader(xml);
        using var reader = XmlReader.Create(input, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_048_576 });
        var root = XDocument.Load(reader).Root ?? throw new InvalidDataException();
        XNamespace ns = "http://schemas.microsoft.com/win/2004/08/events/event";
        var system = root.Element(ns + "System") ?? throw new InvalidDataException();
        var fields = root.Element(ns + "EventData")?.Elements(ns + "Data").ToArray() ?? [];
        string? Field(string name)
        {
            var matches = fields.Where(e => (string?)e.Attribute("Name") == name).ToArray();
            if (matches.Length > 1) { throw new InvalidDataException(); }
            return matches.SingleOrDefault()?.Value;
        }
        if (root.Name != ns + "Event" || system.Element(ns + "EventID")?.Value != "4740"
            || (string?)system.Element(ns + "Provider")?.Attribute("Name") != "Microsoft-Windows-Security-Auditing"
            || system.Element(ns + "Channel")?.Value != "Security" || Field("TargetSid") != sid
            || !DateTimeOffset.TryParse((string?)system.Element(ns + "TimeCreated")?.Attribute("SystemTime"), CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var at) || at < from || at > to)
        { throw new InvalidDataException("Événement hors de la sélection demandée."); }
        // In version 0 of 4740, TargetDomainName carries Caller Computer Name (Microsoft event schema).
        var caller = Field("CallerComputerName") ?? Field("TargetDomainName") ?? "";
        return new(at, caller, system.Element(ns + "Computer")?.Value ?? "");
    }

    private static LockoutEventsRead Read(string server, string sid, bool pdc, DateTimeOffset from, DateTimeOffset to, int maximum,
        string xpath, string? user, string? domain, SecureString? password, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var pointer = password is null ? IntPtr.Zero : Marshal.SecureStringToGlobalAllocUnicode(password);
        EventHandle session;
        try
        {
            var login = new RpcLogin { Server = server, User = user, Domain = domain, Password = pointer, Flags = 1 };
            session = Handle(Native.EvtOpenSession(1, ref login, 0, 0));
        }
        finally { if (pointer != IntPtr.Zero) { Marshal.ZeroFreeGlobalAllocUnicode(pointer); } }
        using (session)
        using (token.Register(() => Native.EvtCancel(session)))
        {
            token.ThrowIfCancellationRequested();
            using var query = Handle(Native.EvtQuery(session, "Security", xpath, 0x201));
            using var cancel = token.Register(() => Native.EvtCancel(query));
            var events = ImmutableArray.CreateBuilder<LockoutEventRead>();
            while (true)
            {
                token.ThrowIfCancellationRequested();
                if (!Native.EvtNext(query, 1, out var item, 1000, 0, out var returned))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error == 259) { return new(LockoutReadState.Read, server, pdc, events.ToImmutable(), false); }
                    throw new Win32Exception(error);
                }
                using var record = Handle(item);
                if (returned != 1) { throw new InvalidDataException(); }
                var parsed = Parse(Render(record), sid, from, to);
                if (events.Count == maximum) { return new(LockoutReadState.Read, server, pdc, events.ToImmutable(), true); }
                events.Add(parsed);
            }
        }
    }

    private static string Render(EventHandle record)
    {
        if (Native.EvtRender(IntPtr.Zero, record, 1, 0, IntPtr.Zero, out var needed, out _)) { throw new InvalidDataException(); }
        var error = Marshal.GetLastWin32Error();
        if (error != 122) { throw new Win32Exception(error); }
        if (needed is < 2 or > 1_048_576 || needed % 2 != 0) { throw new InvalidDataException(); }
        var buffer = Marshal.AllocHGlobal(needed);
        try
        {
            if (!Native.EvtRender(IntPtr.Zero, record, 1, needed, buffer, out var used, out _)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            if (used < 2 || used > needed || used % 2 != 0) { throw new InvalidDataException(); }
            return Marshal.PtrToStringUni(buffer, used / 2 - 1) ?? throw new InvalidDataException();
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static EventHandle Handle(IntPtr value) => value == IntPtr.Zero ? throw new Win32Exception(Marshal.GetLastWin32Error()) : new(value);

    private sealed class EventHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal EventHandle(IntPtr value) : base(true) => SetHandle(value);
        protected override bool ReleaseHandle() => Native.EvtClose(handle);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RpcLogin
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string Server;
        [MarshalAs(UnmanagedType.LPWStr)] public string? User;
        [MarshalAs(UnmanagedType.LPWStr)] public string? Domain;
        public IntPtr Password;
        public int Flags;
    }

    private static class Native
    {
        private const string Library = "wevtapi.dll";
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, SetLastError = true)] internal static extern IntPtr EvtOpenSession(int loginClass, ref RpcLogin login, int timeout, int flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr EvtQuery(EventHandle session, string path, string query, int flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EvtNext(EventHandle query, int size, out IntPtr item, int timeout, int flags, out int returned);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EvtRender(IntPtr context, EventHandle record, int flags, int size, IntPtr buffer, out int used, out int properties);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EvtCancel(EventHandle handle);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EvtClose(IntPtr handle);
    }
}
