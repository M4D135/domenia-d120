using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Domenia.App;

/// <summary>No global hooks, foreground loops or TopMost. Windows remains the final foreground arbiter.</summary>
internal sealed partial class NativeWindowActivation : IDisposable
{
    private readonly Form form;
    private readonly string purpose;
    private readonly StartupActivation guard = new();
    private bool watching;
    internal NativeWindowActivation(Form form, string purpose)
    {
        this.form = form; this.purpose = purpose;
        try { SystemEvents.SessionSwitch += SessionChanged; watching = true; }
        catch (InvalidOperationException) { guard.UserSwitchedAway(); }
        catch (ExternalException) { guard.UserSwitchedAway(); }
        form.Disposed += Disposed;
    }
    private void SessionChanged(object sender, SessionSwitchEventArgs args)
    {
        if (args.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff
            or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect) guard.UserSwitchedAway();
    }
    internal void Request()
    {
        if (form.IsDisposed || !form.IsHandleCreated) return;
        var foreground = GetForegroundWindow();
        _ = GetWindowThreadProcessId(foreground, out var process);
        var result = guard.TryActivate(foreground != IntPtr.Zero && process == (uint)Environment.ProcessId, () =>
        {
            form.Activate();
            return GetForegroundWindow() == form.Handle;
        });
        TechnicalLog.Info("Activation/" + purpose + " : " + result + ".");
    }
    private void Disposed(object? sender, EventArgs args) => Dispose();
    public void Dispose()
    {
        form.Disposed -= Disposed;
        if (watching) { SystemEvents.SessionSwitch -= SessionChanged; watching = false; }
    }
    [LibraryImport("user32.dll")] private static partial IntPtr GetForegroundWindow();
    [LibraryImport("user32.dll")] private static partial uint GetWindowThreadProcessId(IntPtr window, out uint process);
}
