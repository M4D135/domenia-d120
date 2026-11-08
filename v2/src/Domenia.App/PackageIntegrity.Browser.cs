using System.Diagnostics;
using System.Reflection.PortableExecutable;
using Microsoft.Win32;

namespace Domenia.App;

/// <summary>Origin of the admitted WebView2 engine: the developer machine, the pack itself, Evergreen or the Socle beside a PROD-LIGHT pack.</summary>
internal enum BrowserSource { Windows, Pack, Evergreen, Socle }

internal sealed partial class PackageIntegrity
{
    internal const string LightBrowserBaseline = "140.0.3485.54";
    private const string MissingBrowser = "DOMENIA_WEBVIEW2_ABSENT : PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 préinstallé (" + LightBrowserBaseline
        + " ou ultérieur), sinon le pack WebView2 du Socle extrait dans le dossier wad (" + SocleWebView.ReleaseUrl + "). ";
    private const string SocleFailure = "DOMENIA_WEBVIEW2_SOCLE : le pack WebView2 du Socle extrait dans wad n’a pas satisfait les contrôles locaux (moteur Microsoft x64 "
        + SocleWebView.PinnedVersion + ", sans redirection par variable ou stratégie). Réextrayez " + SocleWebView.Archive + " depuis " + SocleWebView.ReleaseUrl + ". ";
    private static readonly Version MinimumBrowser = Version.Parse(LightBrowserBaseline);

    internal BrowserSource Browser { get; private set; }
    /// <summary>Version of the admitted PROD-LIGHT engine, which the Windows loader must report unchanged.</summary>
    internal string? BrowserVersion { get; private set; }
    /// <summary>Why the installed Evergreen engine was not used when the Socle engine was admitted instead.</summary>
    internal string? EvergreenSkipped { get; private set; }

    internal string? AdmitBrowser(string root, Func<string> installedVersion)
    {
        if (!IsLight)
        {
            var folder = PackageLayout.At(root, "runtime/webview2");
            // An unpackaged developer build may use its Windows development runtime.
            if (!Packaged && !File.Exists(Path.Combine(folder, "msedgewebview2.exe"))) { Browser = BrowserSource.Windows; return null; }
            RequireBrowserLocationPolicy();
            Browser = BrowserSource.Pack;
            return folder;
        }
        var runtimePath = "wad/runtime/dotnet/shared/Microsoft.NETCore.App/" + Environment.Version + "/System.Private.CoreLib.dll";
        if (!Components.Any(c => c.Path == runtimePath) || !string.Equals(typeof(object).Assembly.Location,
            Path.Combine(root, runtimePath.Replace('/', Path.DirectorySeparatorChar)), StringComparison.OrdinalIgnoreCase))
            throw Invalid("PROD-LIGHT exige le runtime .NET privé de cette installation.");
        try
        {
            RequireBrowserLocationPolicy();
            var roots = new[] { Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.ProgramFiles }
                .Select(f => Environment.GetFolderPath(f)).Where(p => !string.IsNullOrEmpty(p)).Distinct(StringComparer.OrdinalIgnoreCase)
                .Select(p => Path.Combine(p, "Microsoft", "EdgeWebView", "Application"));
            // Discover the registered stable version, then pin its verified machine folder for the loader and PID check.
            var (folder, version) = FindEvergreen(roots, installedVersion());
            foreach (var name in new[] { "msedgewebview2.exe", "msedge.dll" }) RequireMicrosoftBinary(version, Hold(Path.Combine(folder, name)));
            Browser = BrowserSource.Evergreen; BrowserVersion = version.ToString();
            return folder;
        }
        catch (Exception failure) when (EngineFailure(failure) && Socle is null)
        {
            throw new InvalidDataException(MissingBrowser + "Le moteur installé est absent ou n’a pas satisfait les contrôles locaux, et le pack du Socle n’est pas extrait. Aucun téléchargement tenté.", failure);
        }
        catch (Exception failure) when (EngineFailure(failure)) { EvergreenSkipped = failure.Message; }
        // Evergreen first, as every Socle application does; the Socle engine was already verified byte for byte with the pack.
        try
        {
            RequireBrowserLocationPolicy();
            var folder = PackageLayout.At(root, SocleWebView.Folder);
            var version = Version.Parse(Socle!.Version);
            foreach (var name in new[] { "msedgewebview2.exe", "msedge.dll" }) RequireMicrosoftBinary(version, Hold(Path.Combine(folder, name)));
            Browser = BrowserSource.Socle; BrowserVersion = Socle.Version;
            return folder;
        }
        catch (Exception failure) when (EngineFailure(failure))
        { throw new InvalidDataException(SocleFailure + "WebView2 Evergreen non retenu : " + EvergreenSkipped, failure); }
    }

    private static bool EngineFailure(Exception failure) => failure is IOException or InvalidDataException or UnauthorizedAccessException or BadImageFormatException
        or System.Security.SecurityException or System.Security.Cryptography.CryptographicException or ArgumentException;

    private static void RequireMicrosoftBinary(Version version, FileStream file)
    {
        if (file.Length is <= 0 or > 2L * 1024 * 1024 * 1024) throw Invalid("Taille de composant du moteur WebView2 invalide.");
        using var image = new PEReader(file, PEStreamOptions.LeaveOpen);
        var signature = PackagePublisherTrust.WindowsSignature(file);
        RequireEvergreenBinary(version, FileVersionInfo.GetVersionInfo(file.Name).ProductVersion, image.PEHeaders.CoffHeader.Machine,
            signature.Status == 0 && signature.CertificateSha256 is { Length: 64 }, signature.Publisher);
    }

    internal static (string Folder, Version Version) FindEvergreen(IEnumerable<string> roots, string? registeredVersion)
    {
        if (!Version.TryParse(registeredVersion, out var version) || version.Revision < 0
            || version.ToString() != registeredVersion || version < MinimumBrowser)
            throw Invalid("La version enregistrée de WebView2 Evergreen est absente ou incompatible.");
        foreach (var root in roots)
        {
            if (!Path.IsPathFullyQualified(root) || root.Length < 3 || root[1] != ':' || new DriveInfo(Path.GetPathRoot(root)!).DriveType != DriveType.Fixed)
                throw Invalid("Le moteur Windows exige un disque local fixe.");
            if (!Directory.Exists(root)) continue;
            CheckPath(root);
            var folder = Path.Combine(root, version.ToString());
            if (!Directory.Exists(folder)) continue;
            CheckPath(folder);
            return (folder, version);
        }
        throw Invalid("Le runtime Evergreen enregistré est absent des dossiers système.");
    }

    internal static void RequireEvergreenBinary(Version folderVersion, string? productVersion, Machine machine, bool accepted, string? publisher)
    {
        if (folderVersion < MinimumBrowser || folderVersion.Revision < 0 || folderVersion.ToString() != productVersion || machine != Machine.Amd64
            || !accepted || publisher != "Microsoft Corporation") throw Invalid("Éditeur, architecture ou version du moteur installé non qualifiés.");
    }

    // The WebView2 loader gives environment and machine/user policies precedence over its explicit folder parameter.
    internal static void RequireBrowserLocationPolicy()
    {
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBVIEW2_BROWSER_EXECUTABLE_FOLDER")))
            throw Invalid("Chemin du moteur WebView2 redirigé par une variable du processus.");
        foreach (var hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var registry = RegistryKey.OpenBaseKey(hive, view);
            using var policy = registry.OpenSubKey(@"SOFTWARE\Policies\Microsoft\Edge\WebView2\BrowserExecutableFolder");
            if (policy is not null && new[] { "*", "Domenia.exe" }.Any(name => policy.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not null))
                throw Invalid("Chemin du moteur WebView2 redirigé par une stratégie Windows.");
        }
    }

    internal static void ConfirmBrowserProcess(string? folder, int processId)
    {
        if (folder is null) return;
        using var browser = Process.GetProcessById(processId);
        var expected = Path.Combine(folder, "msedgewebview2.exe");
        if (!string.Equals(browser.MainModule?.FileName, expected, StringComparison.OrdinalIgnoreCase))
            throw Invalid("Processus WebView2 différent du moteur qualifié ; aucun contenu Domenia ouvert.");
    }
}
