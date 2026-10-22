using System.Security;
using Domenia.Core;

namespace Domenia.App.Settings;

/// <summary>
/// Local folders for the destination of a copy or a move of the base (Domenia 1 « Enregistrer sous »): the local fixed drives,
/// the sub-folders of a folder (500 at most, hidden and system folders, links and junctions left out), and the facts of a
/// destination (folder, drive, link, existing file, free space). Read only: nothing is created, opened for writing nor
/// written; never a share, a removable drive nor a device path.
/// </summary>
internal static class LocalFolders
{
    /// <summary>True for an existing folder of a local fixed drive that is no link or junction.</summary>
    public static bool IsLocalFolder(string path)
    {
        try
        {
            if (!IsDrivePath(path) || !IsFixedDrive(path))
            {
                return false;
            }
            var info = new DirectoryInfo(path);
            return info.Exists && !info.Attributes.HasFlag(FileAttributes.ReparsePoint);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SecurityException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    private static bool IsDrivePath(string? path) =>
        path is { Length: >= 3 } && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\' && !path.StartsWith(@"\\", StringComparison.Ordinal)
        && path.IndexOfAny(['<', '>', '"', '|', '?', '*']) < 0 && !path[2..].Contains(':', StringComparison.Ordinal);

    private static bool IsFixedDrive(string path)
    {
        var drive = new DriveInfo(path[..1]);
        return drive.DriveType == DriveType.Fixed && drive.IsReady;
    }

    /// <summary>The local fixed drives (no path), or the sub-folders of a local folder.</summary>
    public static FolderListing Browse(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            var drives = new List<FolderEntry>();
            foreach (var drive in DriveInfo.GetDrives())
            {
                try
                {
                    if (drive.DriveType == DriveType.Fixed && drive.IsReady)
                    {
                        var label = string.IsNullOrWhiteSpace(drive.VolumeLabel) ? "Disque local" : drive.VolumeLabel;
                        drives.Add(new FolderEntry(drive.Name.TrimEnd('\\') + " · " + label + " · " + SettingsFormat.Size(drive.AvailableFreeSpace) + " libres", drive.RootDirectory.FullName));
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    TechnicalLog.Warning($"Disque illisible pour le choix d’une destination ({ex.GetType().Name}).");
                }
            }
            return new FolderListing(null, null, [.. drives], false, drives.Count == 0 ? "Aucun disque local fixe lisible." : FrenchText.Count(drives.Count, "disque local", "disques locaux") + ".");
        }
        var folder = path.Trim();
        if (!folder.EndsWith('\\'))
        {
            folder += "\\";
        }
        if (!IsDrivePath(folder) || folder.Contains(@"\..\", StringComparison.Ordinal) || folder.Contains(@"\.\", StringComparison.Ordinal))
        {
            throw new DomeniaOperationException(StorageWritePlans.DestinationRefused, "Chemin complet attendu, sur un lecteur local (par exemple D:\\Domenia).");
        }
        try
        {
            if (!IsFixedDrive(folder))
            {
                throw new DomeniaOperationException(StorageWritePlans.DestinationRefused, "Lecteur refusé" + FrenchText.Colon + "un disque local fixe est exigé.");
            }
            var info = new DirectoryInfo(folder);
            if (!info.Exists)
            {
                throw new DomeniaOperationException(StorageWritePlans.DestinationRefused, "Dossier absent" + FrenchText.Colon + "rien à parcourir.");
            }
            var entries = new List<FolderEntry>();
            var truncated = false;
            foreach (var child in info.EnumerateDirectories("*", new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint, RecurseSubdirectories = false })
                .OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase))
            {
                if (entries.Count >= SettingsHostOperations.MaxFolders)
                {
                    truncated = true;
                    break;
                }
                entries.Add(new FolderEntry(child.Name, child.FullName));
            }
            var parent = info.Parent?.FullName;
            return new FolderListing(info.FullName, parent, [.. entries], truncated,
                entries.Count == 0 ? "Aucun sous-dossier." : FrenchText.Count(entries.Count, "sous-dossier", "sous-dossiers") + (truncated ? " (500 premiers)" : "") + ".");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SecurityException or ArgumentException)
        {
            TechnicalLog.Warning($"Dossier illisible pour le choix d’une destination ({ex.GetType().Name}).");
            throw new DomeniaOperationException(StorageWritePlans.DestinationRefused, "Dossier illisible pour l’instant" + FrenchText.Colon + "choisissez-en un autre.");
        }
    }

    /// <summary>What can be read of a destination without touching it.</summary>
    public static DestinationFacts Facts(string? destination)
    {
        var path = (destination ?? "").Trim();
        if (!IsDrivePath(path))
        {
            return new DestinationFacts(false, false, false, false, null);
        }
        try
        {
            var folder = Path.GetDirectoryName(path);
            var fixedDrive = IsFixedDrive(path);
            var info = folder is null ? null : new DirectoryInfo(folder);
            var exists = info?.Exists == true;
            var reparse = exists && info!.Attributes.HasFlag(FileAttributes.ReparsePoint);
            var file = File.Exists(path);
            long? free = fixedDrive ? new DriveInfo(path[..1]).AvailableFreeSpace : null;
            return new DestinationFacts(exists, fixedDrive, reparse, file, free);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SecurityException or ArgumentException or NotSupportedException)
        {
            TechnicalLog.Warning($"Destination illisible ({ex.GetType().Name}).");
            return new DestinationFacts(false, false, false, false, null);
        }
    }
}
