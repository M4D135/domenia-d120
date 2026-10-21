using System.Collections.Immutable;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.App.Capture;

/// <summary>
/// The --capture &lt;folder&gt; option and its companions --capture-routes and --capture-themes (docs/CAPTURE.md). They
/// are taken out of the command line before the mode is resolved, so the mode resolver neither sees them nor reports them
/// as ignored arguments.
/// </summary>
internal sealed record CaptureArguments(
    bool Requested,
    string? Folder,
    string? Error,
    IReadOnlyList<string> Remaining,
    ImmutableArray<CaptureRoute> Routes,
    ImmutableArray<CaptureTheme> Themes)
{
    public const string Option = "--capture";
    public const string RoutesOption = "--capture-routes";
    public const string ThemesOption = "--capture-themes";

    /// <summary>Most screens per run (each brings up to two images per theme).</summary>
    public const int MaxRoutes = 12;

    private static readonly string[] Options = [Option, RoutesOption, ThemesOption];

    /// <summary>Same matching as --simulation: exact value, any case, no « = » form. Each option is admitted once.</summary>
    public static CaptureArguments Parse(IReadOnlyList<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var remaining = new List<string>(arguments.Count);
        var found = new Dictionary<string, int>(StringComparer.Ordinal);
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        string? error = null;
        for (var n = 0; n < arguments.Count; n++)
        {
            var option = Options.FirstOrDefault(o => string.Equals(arguments[n], o, StringComparison.OrdinalIgnoreCase));
            if (option is null)
            {
                remaining.Add(arguments[n]);
                continue;
            }
            found[option] = found.GetValueOrDefault(option) + 1;
            var next = n + 1 < arguments.Count ? arguments[n + 1] : null;
            // « --capture --simulation »: the value was forgotten; the next option is left in place.
            if (string.IsNullOrWhiteSpace(next) || next.StartsWith("--", StringComparison.Ordinal))
            {
                error ??= CaptureTexts.ValueMissing(option);
                if (next is not null && string.IsNullOrWhiteSpace(next))
                {
                    n++;
                }
                continue;
            }
            values[option] = next;
            n++;
        }
        var requested = found.Count > 0;
        // A repeated option is the first thing to fix, whatever else is wrong.
        if (Options.FirstOrDefault(o => found.GetValueOrDefault(o) > 1) is string repeated)
        {
            error = CaptureTexts.Repeated(repeated);
        }
        ImmutableArray<CaptureRoute> routes = [];
        ImmutableArray<CaptureTheme> themes = [];
        if (error is null && values.TryGetValue(RoutesOption, out var routeList))
        {
            routes = CaptureRoute.ParseList(routeList, out var routesError);
            error = routesError;
        }
        if (error is null && values.TryGetValue(ThemesOption, out var themeList))
        {
            themes = CaptureThemes.ParseList(themeList, out var themesError);
            error = themesError ?? (routes.IsDefaultOrEmpty ? CaptureTexts.ThemesWithoutRoutes : null);
        }
        if (error is null && !found.ContainsKey(Option))
        {
            // Screens or themes without a folder: nothing would know where to write.
            error = CaptureTexts.FolderMissing;
        }
        if (error is null && !routes.IsDefaultOrEmpty && themes.IsDefaultOrEmpty)
        {
            themes = [CaptureTheme.Dark];
        }
        return error is null
            ? new CaptureArguments(requested, values.GetValueOrDefault(Option), null, remaining, routes.IsDefault ? [] : routes, themes.IsDefault ? [] : themes)
            : new CaptureArguments(requested, null, error, remaining, [], []);
    }
}

/// <summary>Theme of an image of the extra screens; option values dark, light, contrast.</summary>
internal enum CaptureTheme
{
    Dark,
    Light,
    Contrast,
}

internal static class CaptureThemes
{
    /// <summary>Value of the option and of the page's theme switch (data-set, data-theme).</summary>
    public static string Id(CaptureTheme theme) => theme switch
    {
        CaptureTheme.Light => "light",
        CaptureTheme.Contrast => "contrast",
        _ => "dark",
    };

    /// <summary>Part of the image name, in French like the default sequence (accueil-sombre.png).</summary>
    public static string FileSuffix(CaptureTheme theme) => theme switch
    {
        CaptureTheme.Light => "clair",
        CaptureTheme.Contrast => "contraste",
        _ => "sombre",
    };

    public static string Label(CaptureTheme theme) => theme switch
    {
        CaptureTheme.Light => "thème clair",
        CaptureTheme.Contrast => "contraste élevé",
        _ => "thème sombre",
    };

    /// <summary>« dark,light,contrast » in any order; duplicates are kept once; anything else refuses the run.</summary>
    public static ImmutableArray<CaptureTheme> ParseList(string value, out string? error)
    {
        ArgumentNullException.ThrowIfNull(value);
        var result = ImmutableArray.CreateBuilder<CaptureTheme>();
        foreach (var part in value.Split(','))
        {
            CaptureTheme? theme = part switch
            {
                "dark" => CaptureTheme.Dark,
                "light" => CaptureTheme.Light,
                "contrast" => CaptureTheme.Contrast,
                _ => null,
            };
            if (theme is not CaptureTheme known)
            {
                error = CaptureTexts.ThemesInvalid;
                return [];
            }
            if (!result.Contains(known))
            {
                result.Add(known);
            }
        }
        error = null;
        return result.ToImmutable();
    }
}

/// <summary>
/// One extra screen to capture: its route in the hash router (« rechercher » or « rechercher?q=dupont »), the screen name
/// awaited in data-ready, and a safe file stem. Routes come from the command line: they are checked by a strict expression
/// and only ever reach a script as a JSON string argument of a constant function, never concatenated into its text.
/// </summary>
internal sealed partial record CaptureRoute(string Value, string Name, string FileStem)
{
    /// <summary>Strict form of a route; the query part admits only URL-safe characters.</summary>
    public const string Pattern = @"\A[a-z][a-z0-9-]{1,30}(\?[A-Za-z0-9=&%._,-]{0,200})?\z";

    /// <summary>
    /// « accueil,rechercher?q=a,b » : commas separate routes; inside a query, a comma followed by something that does not
    /// start a route belongs to the query (write %2C before a token that would). Duplicates are kept once.
    /// </summary>
    public static ImmutableArray<CaptureRoute> ParseList(string value, out string? error)
    {
        ArgumentNullException.ThrowIfNull(value);
        var tokens = new List<string>();
        foreach (var part in value.Split(','))
        {
            if (tokens.Count > 0 && tokens[^1].Contains('?', StringComparison.Ordinal) && !RouteStart().IsMatch(part))
            {
                tokens[^1] += "," + part;
                continue;
            }
            tokens.Add(part);
        }
        var result = ImmutableArray.CreateBuilder<CaptureRoute>();
        foreach (var token in tokens)
        {
            if (!Strict().IsMatch(token))
            {
                error = CaptureTexts.RoutesInvalid;
                return [];
            }
            if (result.Any(r => r.Value == token))
            {
                continue;
            }
            result.Add(Create(token));
        }
        if (result.Count > CaptureArguments.MaxRoutes)
        {
            error = CaptureTexts.RoutesInvalid;
            return [];
        }
        error = null;
        return result.ToImmutable();
    }

    private static CaptureRoute Create(string value)
    {
        var mark = value.IndexOf('?', StringComparison.Ordinal);
        if (mark < 0)
        {
            return new CaptureRoute(value, value, value);
        }
        var name = value[..mark];
        var query = value[(mark + 1)..];
        // Readable part of the query, then a short hash so two queries never share a file name.
        var slug = Slug().Replace(query.ToLowerInvariant(), "-").Trim('-');
        if (slug.Length > 40)
        {
            slug = slug[..40].TrimEnd('-');
        }
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(query)))[..6];
        return new CaptureRoute(value, name, name + (slug.Length > 0 ? "-" + slug : "") + "-" + hash);
    }

    [GeneratedRegex(Pattern, RegexOptions.CultureInvariant)]
    private static partial Regex Strict();

    [GeneratedRegex(@"\A[a-z][a-z0-9-]{1,30}(\?|\z)", RegexOptions.CultureInvariant)]
    private static partial Regex RouteStart();

    [GeneratedRegex("[^a-z0-9]+", RegexOptions.CultureInvariant)]
    private static partial Regex Slug();
}

/// <summary>Validation and creation of the capture folder: local folders only, never a share or a device path.</summary>
internal static class CaptureFolder
{
    /// <summary>Links followed through a chain (link to a link…) before the folder is refused as unreadable.</summary>
    private const int MaxLinkDepth = 8;

    /// <summary>Returns null and the absolute folder when it is usable, or the French reason of the refusal.</summary>
    public static string? Prepare(string value, out string folder)
    {
        ArgumentNullException.ThrowIfNull(value);
        folder = string.Empty;
        var raw = value.Trim();
        if (raw.Length == 0)
        {
            return CaptureTexts.FolderMissing;
        }
        if (StartsWithTwoSeparators(raw))
        {
            return CaptureTexts.FolderNetwork;
        }
        string full;
        try
        {
            full = Path.GetFullPath(raw);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException or SecurityException)
        {
            return CaptureTexts.FolderUnreadable;
        }
        // A relative path is resolved against the current folder, which may itself be a share. A symbolic link or a
        // junction on a local disk may lead to a share too: every existing component is checked, link data only.
        var refusal = CheckPath(full, 0);
        if (refusal is not null)
        {
            return refusal;
        }
        try
        {
            Directory.CreateDirectory(full);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return CaptureTexts.FolderNotCreated;
        }
        // Checked again once created: a link put in place meanwhile is refused as well.
        refusal = CheckPath(full, 0);
        if (refusal is not null)
        {
            return refusal;
        }
        folder = full;
        return null;
    }

    /// <summary>
    /// Null when the absolute path stays on local disks, link by link; otherwise the French refusal. Only the local
    /// mount state and the link data are read: a target found on the network is refused before anything opens it.
    /// </summary>
    private static string? CheckPath(string path, int depth)
    {
        if (StartsWithTwoSeparators(path) || !Path.IsPathFullyQualified(path))
        {
            return CaptureTexts.FolderNetwork;
        }
        var root = Path.GetPathRoot(path);
        if (string.IsNullOrEmpty(root))
        {
            return CaptureTexts.FolderUnreadable;
        }
        var refusal = CheckDrive(root);
        if (refusal is not null)
        {
            return refusal;
        }
        var current = root;
        foreach (var part in path[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            FileAttributes attributes;
            try
            {
                // Attributes of the component itself: a link is not followed.
                attributes = File.GetAttributes(current);
            }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
            {
                // The rest of the path does not exist yet: it will be created as plain folders.
                return null;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return CaptureTexts.FolderUnreadable;
            }
            if ((attributes & FileAttributes.ReparsePoint) == 0)
            {
                continue;
            }
            string? target;
            try
            {
                // Reads the link data only; the target is never opened.
                target = new DirectoryInfo(current).LinkTarget;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return CaptureTexts.FolderUnreadable;
            }
            // Null: another kind of reparse point (cloud file, deduplication…), not a link. Empty: volume mount point,
            // always a local volume.
            if (string.IsNullOrEmpty(target))
            {
                continue;
            }
            refusal = CheckTarget(target, current, depth);
            if (refusal is not null)
            {
                return refusal;
            }
        }
        return null;
    }

    /// <summary>Target of a symbolic link or junction: refused if it is a share or a device, else checked in turn.</summary>
    private static string? CheckTarget(string target, string link, int depth)
    {
        if (depth >= MaxLinkDepth)
        {
            return CaptureTexts.FolderUnreadable;
        }
        var path = target;
        // NT and extended forms, as they may be stored in the link data (\??\C:\x, \??\UNC\server\share, \\?\Volume{…}).
        if (path.StartsWith(@"\??\", StringComparison.Ordinal) || path.StartsWith(@"\\?\", StringComparison.Ordinal))
        {
            path = path[4..];
            if (path.StartsWith(@"UNC\", StringComparison.OrdinalIgnoreCase))
            {
                return CaptureTexts.FolderNetwork;
            }
            if (path.StartsWith("Volume{", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
        }
        if (StartsWithTwoSeparators(path))
        {
            return CaptureTexts.FolderNetwork;
        }
        string full;
        try
        {
            // A relative symbolic link starts from the folder that holds it.
            full = Path.GetFullPath(path, Path.GetDirectoryName(link) ?? link);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return CaptureTexts.FolderUnreadable;
        }
        return CheckPath(full, depth + 1);
    }

    /// <summary>GetDriveType reads the local mount state: no network access, even for a mapped drive.</summary>
    private static string? CheckDrive(string root)
    {
        DriveType kind;
        try
        {
            kind = new DriveInfo(root).DriveType;
        }
        catch (ArgumentException)
        {
            return CaptureTexts.FolderUnreadable;
        }
        return kind switch
        {
            DriveType.Network => CaptureTexts.FolderNetworkDrive,
            DriveType.NoRootDirectory => CaptureTexts.FolderNoDrive,
            _ => null,
        };
    }

    // UNC (\\server\share), extended (\\?\) and device (\\.\) paths, in either separator.
    private static bool StartsWithTwoSeparators(string path) =>
        path.Length >= 2 && (path[0] is '\\' or '/') && (path[1] is '\\' or '/');
}

/// <summary>Operator texts of the capture mode. None of them ever repeats the command line.</summary>
internal static class CaptureTexts
{
    public const string FolderMissing = "Capture refusée : indiquez le dossier des images après --capture.";
    public const string OptionRepeated = "Capture refusée : l’option --capture n’est admise qu’une fois.";
    public const string RoutesMissing = "Capture refusée : indiquez les écrans après --capture-routes (par exemple accueil,rechercher).";
    public const string ThemesMissing = "Capture refusée : indiquez les thèmes après --capture-themes (dark, light, contrast).";
    public const string RoutesInvalid = "Capture refusée : liste d’écrans invalide après --capture-routes (12 au plus ; noms en minuscules, chiffres et tirets, requête facultative après « ? », séparés par des virgules).";
    public const string ThemesInvalid = "Capture refusée : liste de thèmes invalide après --capture-themes (dark, light, contrast, séparés par des virgules).";
    public const string ThemesWithoutRoutes = "Capture refusée : --capture-themes s’applique aux écrans de --capture-routes.";
    public const string FolderNetwork = "Capture refusée : les chemins réseau (\\\\serveur\\partage) et de périphérique ne sont pas admis. Choisissez un dossier local.";
    public const string FolderNetworkDrive = "Capture refusée : ce dossier est sur un lecteur réseau. Choisissez un dossier local.";
    public const string FolderNoDrive = "Capture refusée : le lecteur de ce dossier n’existe pas.";
    public const string FolderUnreadable = "Capture refusée : le chemin du dossier est illisible.";
    public const string FolderNotCreated = "Capture refusée : le dossier n’a pas pu être créé ou n’est pas accessible en écriture.";
    public const string LogNotCreated = "Capture refusée : le journal capture.log n’a pas pu être créé dans le dossier.";
    public const string SimulationOnly = "Capture refusée : le mode capture n’est admis qu’en simulation (--simulation).";
    public const string StartFailed = "Capture impossible : Domenia n’a pas pu démarrer. Le détail technique est dans le journal de l’application.";

    public static string ValueMissing(string option) => option switch
    {
        CaptureArguments.RoutesOption => RoutesMissing,
        CaptureArguments.ThemesOption => ThemesMissing,
        _ => FolderMissing,
    };

    public static string Repeated(string option) => option == CaptureArguments.Option
        ? OptionRepeated
        : $"Capture refusée : l’option {option} n’est admise qu’une fois.";
}
