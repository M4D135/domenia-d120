using Domenia.Core;

namespace Domenia.App;

/// <summary>Locations used by the portable application: everything next to the exe, user data under LOCALAPPDATA.</summary>
internal static class AppPaths
{
    public static string AppDirectory { get; } = AppContext.BaseDirectory;

    public static string WebRoot { get; } = Path.Combine(AppDirectory, "web");

    /// <summary>Fixed WebView2 runtime shipped in the pack; null when absent so WebView2 uses the Windows runtime.</summary>
    public static string? WebViewRuntime
    {
        get
        {
            var folder = Path.Combine(AppDirectory, "runtime", "webview2");
            return File.Exists(Path.Combine(folder, "msedgewebview2.exe")) ? folder : null;
        }
    }

    /// <summary>
    /// %LOCALAPPDATA%\Domenia, or null when Windows gives no absolute local application data folder: nothing is then
    /// written at all (never a path relative to the current folder, which may be the share or key the pack runs from).
    /// </summary>
    public static string? UserData { get; } = ResolveUserData();

    /// <summary>
    /// WebView2 profile of the mode: the simulation never shares web storage or cache with the directory mode. The
    /// capture mode (--capture) and the E2E mode (--e2e-port) have their own profiles, so their forced preferences and
    /// test sessions never reach the operator's.
    /// </summary>
    public static string? WebViewUserData(AppMode mode, bool capture = false, bool e2e = false)
    {
        if (UserData is null)
        {
            return null;
        }
        var name = (capture ? "WebView2-Capture" : e2e ? "WebView2-E2E" : "WebView2") + (mode == AppMode.Simulation ? "-Simulation" : "");
        return Path.Combine(UserData, name);
    }

    /// <summary>
    /// Local preferences of the mode (LocalWrite): preferences.json, or preferences-simulation.json in simulation; null when
    /// there is no data folder (the preferences then last for the session only).
    /// </summary>
    public static string? Preferences(AppMode mode) =>
        UserData is null ? null : Path.Combine(UserData, Domenia.Store.FilePreferenceStore.FileNameFor(mode));

    /// <summary>
    /// Durable write receipts of the mode (LocalWrite, docs/WRITES.md § 4): receipts.jsonl, or receipts-simulation.jsonl in
    /// simulation; null when there is no data folder (the receipts then last for the session only).
    /// </summary>
    public static string? Receipts(AppMode mode) =>
        UserData is null ? null : Path.Combine(UserData, Domenia.Store.FileReceiptStore.FileNameFor(mode));

    private static string? ResolveUserData()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create);
        return Path.IsPathFullyQualified(root) ? Path.Combine(root, "Domenia") : null;
    }
}
