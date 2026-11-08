using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;

namespace Domenia.App;

/// <summary>OS-only bootstrap window: no WinForms, WebView or other packaged module is loaded by this presentation.</summary>
internal sealed class StartupWindow : IDisposable
{
    private readonly CancellationTokenSource stop = new();
    private readonly ManualResetEventSlim ready = new();
    private readonly Thread thread;
    private readonly Stopwatch elapsed = Stopwatch.StartNew();
    private readonly WindowProcedure procedure;
    private readonly StartupMonitor monitor = new(TimeProvider.System);
    private nint window;
    private nint status;
    private nint cancel;
    private nint diagnostic;
    private nint detail;
    private bool detailsVisible;
    private Exception? failure;
    private int disposed;
    private int hidden;
    internal CancellationToken Token => stop.Token;
    internal double VisibleMilliseconds { get; private set; }

    internal StartupWindow()
    {
        procedure = Dispatch;
        thread = new Thread(Run) { IsBackground = true, Name = "Domenia démarrage natif" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        ready.Wait();
        if (failure is not null) { Dispose(); throw new InvalidOperationException("La fenêtre de démarrage n’a pas pu être affichée.", failure); }
    }
    internal static void ShowFailure(string message) => _ = MessageBoxW(0, message, "Domenia | Démarrage", 0x10);
    internal void Phase(string value) => monitor.Phase(value);
    private void Run()
    {
        string className = "DomeniaStartup" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture);
        try
        {
            _ = SetThreadDpiAwarenessContext(-4); // Only this thread; the verified WinForms host configures its own DPI.
            var module = GetModuleHandleW(null);
            var cls = new WindowClass { Procedure = Marshal.GetFunctionPointerForDelegate(procedure), Instance = module, Background = 6, ClassName = className };
            if (RegisterClassW(ref cls) == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            var scale = Math.Max(1d, GetDpiForSystem() / 96d);
            int S(int n) => (int)Math.Round(n * scale);
            window = CreateWindowExW(0, className, "Domenia — Démarrage", 0x00C80000, (GetSystemMetrics(0) - S(640)) / 2,
                (GetSystemMetrics(1) - S(235)) / 2, S(640), S(235), 0, 0, module, 0);
            if (window == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            status = CreateWindowExW(0, "STATIC", monitor.Describe(false, 8), 0x50000000, S(24), S(25), S(580), S(95), window, 0, module, 0);
            cancel = CreateWindowExW(0, "BUTTON", "Annuler le démarrage", 0x50010000, S(24), S(135), S(230), S(32), window, 1, module, 0);
            diagnostic = CreateWindowExW(0, "BUTTON", "Diagnostic du démarrage", 0x50010000, S(280), S(135), S(290), S(32), window, 2, module, 0);
            // Read-only multiline edit in this same window: no modal dialog can hold up the handoff to login.
            detail = CreateWindowExW(0, "EDIT", "", 0x40210844, S(24), S(25), S(580), S(95), window, 3, module, 0);
            if (status == 0 || cancel == 0 || diagnostic == 0 || detail == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            var font = GetStockObject(17);
            _ = SendMessageW(status, 0x0030, font, 1); _ = SendMessageW(cancel, 0x0030, font, 1); _ = SendMessageW(diagnostic, 0x0030, font, 1);
            _ = SendMessageW(detail, 0x0030, font, 1);
            _ = SetTimer(window, 1, 250, 0);
            _ = ShowWindow(window, 5); _ = UpdateWindow(window);
            VisibleMilliseconds = elapsed.Elapsed.TotalMilliseconds;
            ready.Set();
            while (GetMessageW(out var message, 0, 0, 0) > 0)
            {
                _ = TranslateMessage(ref message); _ = DispatchMessageW(ref message);
            }
        }
#pragma warning disable CA1031 // The bootstrap reports failure to Main without trying another unverified UI framework.
        catch (Exception error) { failure = error; ready.Set(); }
#pragma warning restore CA1031
        finally
        {
            if (window != 0) { _ = DestroyWindow(window); window = 0; }
            _ = UnregisterClassW(className, GetModuleHandleW(null));
        }
    }
    private nint Dispatch(nint handle, uint message, nuint wParam, nint lParam)
    {
        switch (message)
        {
            case 0x0010: // WM_CLOSE requests cancellation; it does not claim that the active read already stopped.
            case 0x0111 when (wParam & 0xffff) == 1:
                stop.Cancel(); _ = EnableWindow(cancel, false); Paint(); return 0;
            case 0x0111 when (wParam & 0xffff) == 2:
                detailsVisible = !detailsVisible;
                if (detailsVisible) _ = SetWindowTextW(detail, monitor.Diagnostic);
                _ = ShowWindow(status, detailsVisible ? 0 : 5); _ = ShowWindow(detail, detailsVisible ? 5 : 0);
                _ = SetWindowTextW(diagnostic, detailsVisible ? "Revenir à l’étape en cours" : "Diagnostic du démarrage");
                return 0;
            case 0x0113: Paint(); return 0;
            case 0x8001: _ = DestroyWindow(handle); return 0;
            case 0x0002: PostQuitMessage(0); return 0;
            default: return DefWindowProcW(handle, message, wParam, lParam);
        }
    }
    private void Paint()
    {
        _ = SetWindowTextW(status, monitor.Describe(stop.IsCancellationRequested, 8));
    }
    internal void Hide()
    {
        if (Interlocked.Exchange(ref hidden, 1) != 0) return;
        if (window != 0) _ = PostMessageW(window, 0x8001, 0, 0);
        thread.Join();
        GC.KeepAlive(procedure);
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        Hide(); ready.Dispose(); stop.Dispose();
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint WindowProcedure(nint handle, uint message, nuint wParam, nint lParam);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint Style; public nint Procedure; public int ClassExtra; public int WindowExtra; public nint Instance;
        public nint Icon; public nint Cursor; public nint Background; public string? MenuName; public string ClassName;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Message { public nint Window; public uint Id; public nuint WParam; public nint LParam; public uint Time; public int X; public int Y; public uint Private; }
#pragma warning disable SYSLIB1054 // Callback-bearing bootstrap signatures intentionally use the classic marshaler.
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern nint GetModuleHandleW(string? name);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] private static extern ushort RegisterClassW(ref WindowClass value);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterClassW(string name, nint instance);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] private static extern nint CreateWindowExW(uint extended, string cls, string title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern nint DefWindowProcW(nint handle, uint message, nuint wParam, nint lParam);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern int GetMessageW(out Message message, nint handle, uint first, uint last);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TranslateMessage(ref Message message);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern nint DispatchMessageW(ref Message message);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern nint SetThreadDpiAwarenessContext(nint context);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern uint GetDpiForSystem();
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern int GetSystemMetrics(int index);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern nuint SetTimer(nint handle, nuint id, uint milliseconds, nint callback);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindow(nint handle, int command);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UpdateWindow(nint handle);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(nint handle);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern void PostQuitMessage(int code);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessageW(nint handle, uint message, nuint wParam, nint lParam);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] private static extern nint SendMessageW(nint handle, uint message, nint wParam, nint lParam);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowTextW(nint handle, string value);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnableWindow(nint handle, [MarshalAs(UnmanagedType.Bool)] bool enabled);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("gdi32.dll", ExactSpelling = true)] private static extern nint GetStockObject(int index);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern int MessageBoxW(nint owner, string text, string caption, uint type);
#pragma warning restore SYSLIB1054
}
