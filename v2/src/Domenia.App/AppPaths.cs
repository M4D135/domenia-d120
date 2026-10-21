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

    public static string UserData { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Domenia");

    public static string WebViewUserData { get; } = Path.Combine(UserData, "WebView2");
}
