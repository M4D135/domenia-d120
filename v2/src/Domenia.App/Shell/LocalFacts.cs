using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using Domenia.Core;
using Microsoft.Win32;

namespace Domenia.App;

/// <summary>
/// « À propos de Domenia » (Domenia 1 TRV-052, Update-DomeniaAboutCompatibility): local facts only, read once per session —
/// the version keys of the registry and the version of winsqlite3.dll. Nothing is read on the network.
/// </summary>
internal static class LocalFacts
{
    /// <summary>Oldest Windows build supported by .NET 10 and the fixed WebView2 engine (Windows 10 20H1).</summary>
    public const int MinimumBuild = 19041;

    public static ShellAbout Read(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var info = AppInfoBuilder.Build(context.Decision, Environment.Version.ToString(), AppPaths.WebViewRuntime is null ? "windows" : "embarque");
        var (product, display, build, revision) = WindowsVersion();
        var sqlite = SqliteVersion();
        var facts = ImmutableArray.CreateBuilder<ShellFact>();
        facts.Add(new ShellFact("Version de Domenia", info.Version, Tone.Info));
        facts.Add(new ShellFact(".NET embarqué", info.Runtime, Tone.Info));
        facts.Add(new ShellFact("Moteur d’affichage", info.WebViewRuntime == "embarque" ? "WebView2 fixe, livré dans le pack" : "WebView2 installé dans Windows", Tone.Info));
        var buildText = build is int b ? b.ToString(CultureInfo.InvariantCulture) + (revision is int r ? "." + r.ToString(CultureInfo.InvariantCulture) : "") : "illisible";
        var system = (product ?? "Windows") + (display is null ? "" : " " + display) + " (build " + buildText + ")";
        var systemTone = build is null ? Tone.Off : build < MinimumBuild ? Tone.Warn : Tone.Ok;
        facts.Add(new ShellFact("Système", system, systemTone));
        var architecture = RuntimeInformation.OSArchitecture switch { Architecture.X64 => "x64", Architecture.Arm64 => "arm64", Architecture.X86 => "x86", _ => "autre" } + (Environment.Is64BitProcess ? ", processus 64 bits" : ", processus 32 bits");
        facts.Add(new ShellFact("Architecture", architecture, Environment.Is64BitProcess ? Tone.Ok : Tone.Warn));
        facts.Add(new ShellFact("SQLite de Windows (winsqlite3.dll)", sqlite ?? "absent", sqlite is null ? Tone.Warn : Tone.Ok));
        facts.Add(new ShellFact("Dossier de données", AppPaths.UserData is null ? "aucun : rien n’est écrit sur le disque" : "%LOCALAPPDATA%\\Domenia", AppPaths.UserData is null ? Tone.Warn : Tone.Ok));
        facts.Add(new ShellFact("Mode", info.ModeLabel + " · " + info.ModeDetail, info.Mode == AppInfoBuilder.SimulationModeText ? Tone.Info : Tone.Ok));
        var (verdict, tone) = (build, sqlite, Environment.Is64BitProcess) switch
        {
            (null, _, _) => ("Compatibilité du poste non évaluée" + FrenchText.Colon + "version de Windows illisible.", Tone.Off),
            (int value, _, _) when value < MinimumBuild => ("Windows trop ancien pour cette version" + FrenchText.Colon + "build " + value.ToString(CultureInfo.InvariantCulture) + ", " + MinimumBuild.ToString(CultureInfo.InvariantCulture) + " au moins attendu.", Tone.Warn),
            (_, null, _) => ("Poste compatible, sans SQLite de Windows" + FrenchText.Colon + "la base locale ne pourra pas être ouverte.", Tone.Warn),
            (_, _, false) => ("Processus 32 bits" + FrenchText.Colon + "Domenia attend Windows 64 bits.", Tone.Warn),
            _ => ("Poste compatible" + FrenchText.Colon + "Windows, .NET, moteur d’affichage et SQLite présents.", Tone.Ok),
        };
        return new ShellAbout(info.Name, info.Version, info.Runtime, info.WebViewRuntime, info.Mode, info.ModeLabel, verdict, tone, facts.ToImmutable());
    }

    /// <summary>Product name, display version, build and revision from the registry; Windows 11 named from its build.</summary>
    private static (string? Product, string? Display, int? Build, int? Revision) WindowsVersion()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            if (key is null)
            {
                return (null, null, Environment.OSVersion.Version.Build, null);
            }
            var product = key.GetValue("ProductName") as string;
            var display = key.GetValue("DisplayVersion") as string;
            int? build = int.TryParse(key.GetValue("CurrentBuildNumber") as string, NumberStyles.Integer, CultureInfo.InvariantCulture, out var b) ? b : Environment.OSVersion.Version.Build;
            int? revision = key.GetValue("UBR") is int ubr ? ubr : null;
            // ProductName still reads « Windows 10 » on Windows 11: the build tells them apart.
            if (build >= 22000 && product is not null && product.StartsWith("Windows 10", StringComparison.Ordinal))
            {
                product = "Windows 11" + product["Windows 10".Length..];
            }
            return (product, display, build, revision);
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            TechnicalLog.Warning($"À propos : version de Windows illisible ({ex.GetType().Name}).");
            return (null, null, null, null);
        }
    }

    private static string? SqliteVersion()
    {
        try
        {
            var path = Path.Combine(Environment.SystemDirectory, "winsqlite3.dll");
            return File.Exists(path) ? FileVersionInfo.GetVersionInfo(path).FileVersion ?? "présent" : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Warning($"À propos : version de winsqlite3.dll illisible ({ex.GetType().Name}).");
            return null;
        }
    }
}
