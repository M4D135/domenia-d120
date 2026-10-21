using System.Security;

namespace Domenia.App.Capture;

/// <summary>
/// The --capture &lt;folder&gt; option (docs/CAPTURE.md). It is taken out of the command line before the mode is
/// resolved, so the mode resolver neither sees it nor reports it as an ignored argument.
/// </summary>
internal sealed record CaptureArguments(bool Requested, string? Folder, string? Error, IReadOnlyList<string> Remaining)
{
    public const string Option = "--capture";

    /// <summary>Same matching as --simulation: exact value, any case, no « = » form.</summary>
    public static CaptureArguments Parse(IReadOnlyList<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var remaining = new List<string>(arguments.Count);
        var found = 0;
        string? folder = null;
        string? error = null;
        for (var n = 0; n < arguments.Count; n++)
        {
            if (!string.Equals(arguments[n], Option, StringComparison.OrdinalIgnoreCase))
            {
                remaining.Add(arguments[n]);
                continue;
            }
            found++;
            var next = n + 1 < arguments.Count ? arguments[n + 1] : null;
            // « --capture --simulation »: the folder was forgotten; the next option is left in place.
            if (string.IsNullOrWhiteSpace(next) || next.StartsWith("--", StringComparison.Ordinal))
            {
                error ??= CaptureTexts.FolderMissing;
                if (next is not null && string.IsNullOrWhiteSpace(next))
                {
                    n++;
                }
                continue;
            }
            folder = next;
            n++;
        }
        if (found > 1)
        {
            error = CaptureTexts.OptionRepeated;
        }
        return new CaptureArguments(found > 0, error is null ? folder : null, error, remaining);
    }
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
    public const string FolderNetwork = "Capture refusée : les chemins réseau (\\\\serveur\\partage) et de périphérique ne sont pas admis. Choisissez un dossier local.";
    public const string FolderNetworkDrive = "Capture refusée : ce dossier est sur un lecteur réseau. Choisissez un dossier local.";
    public const string FolderNoDrive = "Capture refusée : le lecteur de ce dossier n’existe pas.";
    public const string FolderUnreadable = "Capture refusée : le chemin du dossier est illisible.";
    public const string FolderNotCreated = "Capture refusée : le dossier n’a pas pu être créé ou n’est pas accessible en écriture.";
    public const string LogNotCreated = "Capture refusée : le journal capture.log n’a pas pu être créé dans le dossier.";
    public const string SimulationOnly = "Capture refusée : le mode capture n’est admis qu’en simulation (--simulation).";
    public const string StartFailed = "Capture impossible : Domenia n’a pas pu démarrer. Le détail technique est dans le journal de l’application.";
}
