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

    /// <summary>WebView2 profile of the mode: the simulation never shares web storage or cache with the directory mode.</summary>
    public static string? WebViewUserData(AppMode mode) =>
        UserData is null ? null : Path.Combine(UserData, mode == AppMode.Simulation ? "WebView2-Simulation" : "WebView2");

    private static string? ResolveUserData()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create);
        return Path.IsPathFullyQualified(root) ? Path.Combine(root, "Domenia") : null;
    }
}
