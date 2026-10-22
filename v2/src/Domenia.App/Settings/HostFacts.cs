using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using Domenia.Core;
using Microsoft.Win32;

namespace Domenia.App.Settings;

/// <summary>
/// Local facts of the workstation and of the delivered files, read by the host for Paramètres (À propos, compatibility,
/// inventory, locations, journal). Local reads only: registry of this machine, process, file metadata and the SHA-256 of the
/// binaries of Domenia. No network, no WMI, no administrator right. Read off the UI thread, once per process where the
/// files cannot change.
/// </summary>
internal static class HostFacts
{
    private static readonly Lazy<ComponentInventoryView> Inventory = new(ReadInventory, LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>True when the process runs a capture (--capture) or an E2E run (--e2e-port): no window may be opened.</summary>
    public static bool Unattended { get; } = System.Environment.GetCommandLineArgs().Any(a =>
        string.Equals(a, "--capture", StringComparison.OrdinalIgnoreCase) || string.Equals(a, "--e2e-port", StringComparison.OrdinalIgnoreCase));

    private static bool Capture { get; } = System.Environment.GetCommandLineArgs().Any(a => string.Equals(a, "--capture", StringComparison.OrdinalIgnoreCase));

    private static bool E2e { get; } = System.Environment.GetCommandLineArgs().Any(a => string.Equals(a, "--e2e-port", StringComparison.OrdinalIgnoreCase));

    /// <summary>Facts for the compatibility matrix; every value that cannot be read stays unknown.</summary>
    public static EnvironmentFacts ReadEnvironment()
    {
        const string windowsKey = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
        var installation = RegistryText(windowsKey, "InstallationType");
        string? product = installation is null ? null
            : string.Equals(installation, "Client", StringComparison.OrdinalIgnoreCase) ? "Client"
            : installation.StartsWith("Server", StringComparison.OrdinalIgnoreCase) ? "Server" : null;
        int? build = int.TryParse(RegistryText(windowsKey, "CurrentBuild"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var b) && b > 0 ? b : null;
        bool? sqlite = null;
        string? sqliteVersion = null;
        try
        {
            var path = Path.Combine(System.Environment.SystemDirectory, "winsqlite3.dll");
            sqlite = System.IO.File.Exists(path);
            if (sqlite == true)
            {
                sqliteVersion = FileVersionInfo.GetVersionInfo(path).ProductVersion;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            sqlite = null;
        }
        var (mode, version) = WebView();
        return new EnvironmentFacts(product, build, RegistryText(windowsKey, "DisplayVersion"), System.Environment.Is64BitProcess,
            System.Environment.Version.ToString(), mode, version, sqlite, sqliteVersion);
    }

    /// <summary>Mode of the web engine (« embarque » or « windows ») and its version, read locally.</summary>
    public static (string Mode, string? Version) WebView()
    {
        if (AppPaths.WebViewRuntime is string folder)
        {
            try
            {
                return ("embarque", FileVersionInfo.GetVersionInfo(Path.Combine(folder, "msedgewebview2.exe")).FileVersion);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return ("embarque", null);
            }
        }
        try
        {
            return ("windows", Microsoft.Web.WebView2.Core.CoreWebView2Environment.GetAvailableBrowserVersionString());
        }
#pragma warning disable CA1031 // The loader raises several types when no runtime is installed: the version simply stays unknown.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            TechnicalLog.Warning($"Version du moteur WebView2 illisible ({ex.GetType().Name}).");
            return ("windows", null);
        }
    }

    private static string? RegistryText(string key, string name)
    {
        try
        {
            using var opened = Registry.LocalMachine.OpenSubKey(key, writable: false);
            return opened?.GetValue(name) is { } value ? Convert.ToString(value, CultureInfo.InvariantCulture)?.Trim() : null;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    /// <summary>Inventory of the delivered files (hashed once per process).</summary>
    public static ComponentInventoryView Components() => Inventory.Value;

    private static ComponentInventoryView ReadInventory()
    {
        var root = AppPaths.AppDirectory;
        var hashed = new List<ComponentFile>();
        var hashedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var path in Directory.EnumerateFiles(root, "*", SearchOption.TopDirectoryOnly))
            {
                var name = Path.GetFileName(path);
                var mine = name.StartsWith("Domenia", StringComparison.OrdinalIgnoreCase) && (name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
                var webView = (name.StartsWith("Microsoft.Web.WebView2", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)) || name.Equals("WebView2Loader.dll", StringComparison.OrdinalIgnoreCase);
                if (mine || webView)
                {
                    hashed.Add(HashFile(root, path));
                    hashedPaths.Add(path);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Warning($"Inventaire des composants incomplet ({ex.GetType().Name}).");
        }
        var folders = new List<ComponentFolder>
        {
            Folder("web", AppPaths.WebRoot, null, SearchOption.AllDirectories, null),
            Folder("runtime", root, Path.Combine(root, "coreclr.dll"), SearchOption.TopDirectoryOnly, hashedPaths),
        };
        if (AppPaths.WebViewRuntime is string engine)
        {
            folders.Add(Folder("webview", engine, Path.Combine(engine, "msedgewebview2.exe"), SearchOption.AllDirectories, null));
        }
        return ComponentInventory.Build(hashed, folders);
    }

    private static ComponentFile HashFile(string root, string path)
    {
        var info = new FileInfo(path);
        string? sha = null;
        string? fileVersion = null;
        string? productVersion = null;
        try
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
            {
                sha = Convert.ToHexStringLower(SHA256.HashData(stream));
            }
            var version = FileVersionInfo.GetVersionInfo(path);
            fileVersion = version.FileVersion;
            productVersion = version.ProductVersion;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Warning($"Empreinte d’un composant non calculée ({ex.GetType().Name}).");
        }
        return new ComponentFile(Path.GetRelativePath(root, path).Replace('\\', '/'), info.Exists ? info.Length : 0, sha, fileVersion, productVersion);
    }

    private static ComponentFolder Folder(string id, string folder, string? reference, SearchOption depth, HashSet<string>? excluded)
    {
        var files = 0;
        long bytes = 0;
        try
        {
            if (Directory.Exists(folder))
            {
                foreach (var path in Directory.EnumerateFiles(folder, "*", depth))
                {
                    if (excluded?.Contains(path) == true)
                    {
                        continue;
                    }
                    files++;
                    bytes += new FileInfo(path).Length;
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Warning($"Dossier {id} compté en partie ({ex.GetType().Name}).");
        }
        var referenceFile = reference is not null && System.IO.File.Exists(reference) ? HashFile(AppPaths.AppDirectory, reference) : null;
        return new ComponentFolder(id, files, bytes, referenceFile);
    }

    /// <summary>« %LOCALAPPDATA%\Domenia\… » for display: the profile path (which names the Windows account) stays out of the text.</summary>
    public static string Display(string? path)
    {
        if (path is null)
        {
            return "non déterminé";
        }
        var local = System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData);
        return local.Length > 0 && path.StartsWith(local, StringComparison.OrdinalIgnoreCase) ? "%LOCALAPPDATA%" + path[local.Length..] : path;
    }

    /// <summary>Local folders and files of the application, with « Ouvrir » for those that exist.</summary>
    public static ImmutableArray<AppLocation> Locations(AppMode mode, bool memoryPreferences)
    {
        var data = AppPaths.UserData;
        var logs = TechnicalLog.FilePath is string log ? Path.GetDirectoryName(log) : null;
        var profile = AppPaths.WebViewUserData(mode, Capture, E2e);
        AppLocation Item(string id, string label, string? path, bool folder)
        {
            var exists = path is not null && (folder ? Directory.Exists(path) : System.IO.File.Exists(path));
            return new AppLocation(id, label, Display(path), path, exists, exists && !Unattended);
        }
        return
        [
            Item("app", "Dossier de l’application", AppPaths.AppDirectory.TrimEnd('\\'), folder: true),
            Item("data", "Données de l’utilisateur", data, folder: true),
            Item("preferences", memoryPreferences ? "Préférences (en mémoire pour cette session)" : "Préférences", memoryPreferences ? null : AppPaths.Preferences(mode), folder: false),
            Item("receipts", Capture || E2e ? "Reçus d’écriture (en mémoire pour cette session)" : "Reçus d’écriture", Capture || E2e ? null : AppPaths.Receipts(mode), folder: false),
            Item("logs", "Journal technique", logs, folder: true),
            Item("profile", "Profil du moteur web", profile, folder: true),
        ];
    }

    /// <summary>Version of Domenia read from the executable itself (informational version, source revision cut).</summary>
    public static string? InformationalVersion()
    {
        var text = Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (text is null)
        {
            return null;
        }
        var plus = text.IndexOf('+', StringComparison.Ordinal);
        return plus > 0 ? text[..plus] : text;
    }

    /// <summary>Opens the Explorer on a folder, or on the folder of a file with the file selected. No window in capture or E2E.</summary>
    public static void Open(string path, bool file)
    {
        // The path comes from the host (AppPaths), never from the page; a Windows path holds no quote.
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.Windows), "explorer.exe"),
            Arguments = (file ? "/select,\"" : "\"") + path + "\"",
            UseShellExecute = false,
        };
        using var process = Process.Start(start);
    }
}
