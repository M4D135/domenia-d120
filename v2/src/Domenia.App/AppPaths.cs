using Domenia.Core;
using Microsoft.Web.WebView2.Core;

namespace Domenia.App;

/// <summary>Locations used by the portable application: everything next to the exe, user data under LOCALAPPDATA.</summary>
internal static class AppPaths
{
    public static string AppDirectory { get; } = AppContext.BaseDirectory;

    public static string WebRoot { get; } = Path.Combine(AppDirectory, "web");

    /// <summary>Exact engine selected during local package/host admission, kept pinned until shutdown.</summary>
    public static string? WebViewRuntime { get; private set; }
    internal static bool IsLight { get; private set; }
    internal static BrowserSource Browser { get; private set; }
    internal static bool UsesInstalledWebView => WebViewRuntime is null || Browser == BrowserSource.Evergreen;

    internal static void AdmitBrowser(PackageIntegrity package)
    {
        WebViewRuntime = package.AdmitBrowser(PackageLayout.ApplicationRoot, InstalledBrowserVersion);
        IsLight = package.IsLight;
        Browser = package.Browser;
    }

    internal static CoreWebView2EnvironmentOptions BrowserOptions(bool evergreen)
    {
        var options = new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = false };
        if (evergreen)
        {
            options.TargetCompatibleBrowserVersion = PackageIntegrity.LightBrowserBaseline;
            options.ReleaseChannels = CoreWebView2ReleaseChannels.Stable;
        }
        return options;
    }

    internal static string InstalledBrowserVersion()
    {
        try { return CoreWebView2Environment.GetAvailableBrowserVersionString(null, BrowserOptions(evergreen: true)); }
        catch (Exception error) when (error is WebView2RuntimeNotFoundException or System.Runtime.InteropServices.COMException)
        { throw new InvalidDataException("Le chargeur Windows n’a pas trouvé le moteur Evergreen stable.", error); }
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
        if (DemoSessionProcess.Active) return Path.Combine(UserData, "Profiles", DemoSessionProcess.Generation);
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

    /// <summary>
    /// Documents of the operator (LocalWrite, docs/PLATFORM.md § 3.3): Exports, or Exports-simulation in simulation; null when
    /// there is no data folder (the documents then stay in memory).
    /// </summary>
    public static string? Exports(AppMode mode) =>
        UserData is null ? null : Path.Combine(UserData, Domenia.Store.FileDocumentStore.FolderNameFor(mode));

    private static string? ResolveUserData()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create);
        if (!Path.IsPathFullyQualified(root)) return null;
        return DemoSessionProcess.Active ? Path.Combine(root, "Domenia", "Demonstrations", DemoSessionProcess.SessionId) : Path.Combine(root, "Domenia");
    }
}
