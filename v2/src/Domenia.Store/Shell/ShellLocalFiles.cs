using System.Collections.Immutable;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Exports folder of the data folder (TRV-054): « %LOCALAPPDATA%\Domenia\Exports », « Exports-Simulation » in simulation.
/// Created at the first export; a file is written next to its final name then moved without overwrite (another file of the
/// same name gets a numbered name), so nothing partial ever stays under a final name.
/// </summary>
public sealed class FileExportStore : IShellExportStore, IDisposable
{
    private readonly string folder;
    private readonly SemaphoreSlim gate = new(1, 1);

    public FileExportStore(string folder, string folderLabel)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        ArgumentException.ThrowIfNullOrEmpty(folderLabel);
        if (!Path.IsPathFullyQualified(folder))
        {
            throw new ArgumentException("The exports folder must be absolute.", nameof(folder));
        }
        this.folder = folder;
        FolderLabel = folderLabel;
    }

    /// <summary>Folder name of the mode: the simulation never mixes its exports with those of the directory mode.</summary>
    public static string FolderNameFor(AppMode mode) => mode == AppMode.Simulation ? "Exports-Simulation" : "Exports";

    public bool Persistent => true;

    public string FolderLabel { get; }

    /// <summary>Full path of an export of this folder, or null when the name is not an export name or the file is absent.</summary>
    public string? PathOf(string? fileName)
    {
        if (!ShellExportNames.IsExportName(fileName))
        {
            return null;
        }
        var path = Path.Combine(folder, fileName!);
        return File.Exists(path) ? path : null;
    }

    /// <summary>The folder, created if needed (null when it cannot be).</summary>
    public string? EnsureFolder()
    {
        try
        {
            Directory.CreateDirectory(folder);
            return folder;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public async Task<string> SaveAsync(string fileName, ReadOnlyMemory<byte> content, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(fileName);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(folder);
            var temporary = Path.Combine(folder, "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough))
                {
                    await stream.WriteAsync(content, cancellationToken).ConfigureAwait(false);
                    await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                }
                for (var attempt = 0; ; attempt++)
                {
                    var name = ShellExportNames.Free(fileName, n => File.Exists(Path.Combine(folder, n)));
                    try
                    {
                        File.Move(temporary, Path.Combine(folder, name), overwrite: false);
                        return name;
                    }
                    catch (IOException) when (attempt < 5 && File.Exists(Path.Combine(folder, name)))
                    {
                        // Another export took this name in between: the next free name is tried.
                    }
                }
            }
            finally
            {
                DeleteQuietly(temporary);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public void Dispose() => gate.Dispose();

    /// <summary>Removes a temporary file left by a failed write; a file still held is left for the next start.</summary>
    private static void DeleteQuietly(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The hidden temporary name is never shown nor listed (only « Domenia-* » files are).
        }
    }

    public ImmutableArray<ShellExportEntry> List(int max)
    {
        try
        {
            var info = new DirectoryInfo(folder);
            if (!info.Exists)
            {
                return [];
            }
            return [.. info.EnumerateFiles("Domenia-*")
                .Where(f => ShellExportNames.IsExportName(f.Name) && !f.Attributes.HasFlag(FileAttributes.ReparsePoint))
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .Take(Math.Max(0, max))
                .Select(f => new ShellExportEntry(f.Name, f.Length, new DateTimeOffset(f.LastWriteTimeUtc, TimeSpan.Zero), ShellExportNames.KindOf(f.Name)))];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }
}

/// <summary>A starting place of the embedded file picker.</summary>
public sealed record ShellFileRoot(string Label, string Path);

/// <summary>
/// Embedded file picker (TRV-244): local folders below fixed starting places only (Documents, Bureau, Téléchargements, the
/// exports folder; the exports of the simulation only in simulation). Network paths, mapped drives and links are refused; a
/// folder lists 500 entries at most, folders first. Read only: nothing is created, nothing is written.
/// </summary>
public sealed class LocalFileBrowser
{
    /// <summary>Entries of a folder at most.</summary>
    public const int MaxEntries = 500;

    /// <summary>Largest file read for an import.</summary>
    public const int MaxFileBytes = 1_048_576;

    private readonly ImmutableArray<ShellFileRoot> roots;

    public LocalFileBrowser(IEnumerable<ShellFileRoot> roots)
    {
        ArgumentNullException.ThrowIfNull(roots);
        this.roots = [.. roots.Where(r => Path.IsPathFullyQualified(r.Path) && !IsNetworkPath(r.Path))];
    }

    public ImmutableArray<ShellFileRoot> Roots => roots;

    /// <summary>Starting places (folder null), or the entries of a folder below one of them.</summary>
    public ShellFolderListing Browse(string? folder, string filter)
    {
        ArgumentNullException.ThrowIfNull(filter);
        if (string.IsNullOrWhiteSpace(folder))
        {
            var places = roots
                .Where(r => Directory.Exists(r.Path))
                .Select(r => new ShellFileEntry(r.Label, r.Path, "root", null, null))
                .ToImmutableArray();
            var note = places.IsEmpty ? "Aucun dossier de départ disponible sur ce poste." : null;
            return new ShellFolderListing(null, "Emplacements", null, places, false, note);
        }
        var (full, root) = Resolve(folder) ?? throw new DomeniaOperationException(ShellErrors.FileRefused, ShellErrors.FileRefusedMessage);
        var info = new DirectoryInfo(full);
        if (!info.Exists)
        {
            throw new DomeniaOperationException(ShellErrors.FolderUnavailable, ShellErrors.FolderUnavailableMessage);
        }
        try
        {
            var directories = info.EnumerateDirectories()
                .Where(d => !d.Attributes.HasFlag(FileAttributes.ReparsePoint) && !d.Attributes.HasFlag(FileAttributes.Hidden) && !d.Attributes.HasFlag(FileAttributes.System))
                .OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase)
                .Select(d => new ShellFileEntry(d.Name, d.FullName, "folder", null, new DateTimeOffset(d.LastWriteTimeUtc, TimeSpan.Zero)));
            var files = info.EnumerateFiles()
                .Where(f => !f.Attributes.HasFlag(FileAttributes.ReparsePoint) && !f.Attributes.HasFlag(FileAttributes.Hidden) && Accepts(f.Name, filter))
                .OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase)
                .Select(f => new ShellFileEntry(f.Name, f.FullName, "file", f.Length, new DateTimeOffset(f.LastWriteTimeUtc, TimeSpan.Zero)));
            var all = directories.Concat(files).Take(MaxEntries + 1).ToList();
            var parent = string.Equals(full.TrimEnd('\\'), root.Path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ? null : Path.GetDirectoryName(full);
            var label = string.Equals(full.TrimEnd('\\'), root.Path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ? root.Label : root.Label + FrenchText.PathSeparator + Path.GetRelativePath(root.Path, full).Replace("\\", FrenchText.PathSeparator, StringComparison.Ordinal);
            return new ShellFolderListing(full, label, parent, [.. all.Take(MaxEntries)], all.Count > MaxEntries, null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new DomeniaOperationException(ShellErrors.FolderUnavailable, ShellErrors.FolderUnavailableMessage);
        }
    }

    /// <summary>Reads a file chosen in the picker (CSV with its delimiter, or JSON text), 1 MB at most.</summary>
    public ShellFileContent Read(string path, string kind)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(kind);
        var (full, _) = Resolve(path) ?? throw new DomeniaOperationException(ShellErrors.FileRefused, ShellErrors.FileRefusedMessage);
        if (!Accepts(full, kind))
        {
            throw new DomeniaOperationException(ShellErrors.FileRefused, ShellErrors.FileRefusedMessage);
        }
        try
        {
            var info = new FileInfo(full);
            if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint) || info.Length > MaxFileBytes)
            {
                throw new DomeniaOperationException(ShellErrors.FileUnreadable, ShellErrors.FileUnreadableMessage);
            }
            var bytes = File.ReadAllBytes(full);
            var text = new UTF8Encoding(false, false).GetString(bytes);
            if (text.Length > 0 && text[0] == '\uFEFF')
            {
                text = text[1..];
            }
            if (string.Equals(kind, "json", StringComparison.Ordinal))
            {
                return new ShellFileContent(info.Name, "json", null, [], [], 0, false, text);
            }
            var table = ShellCsv.Parse(text);
            return new ShellFileContent(info.Name, "csv", new string(table.Delimiter, 1), table.Headers, table.Rows, table.Total, table.Truncated, null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new DomeniaOperationException(ShellErrors.FileUnreadable, ShellErrors.FileUnreadableMessage);
        }
    }

    /// <summary>The full path and its starting place when <paramref name="path"/> lies below one, through no link; null otherwise.</summary>
    public (string Full, ShellFileRoot Root)? Resolve(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 1024 || IsNetworkPath(path) || !Path.IsPathFullyQualified(path))
        {
            return null;
        }
        string full;
        try
        {
            full = Path.GetFullPath(path);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
        foreach (var root in roots)
        {
            var top = Path.GetFullPath(root.Path).TrimEnd('\\');
            if (!string.Equals(full.TrimEnd('\\'), top, StringComparison.OrdinalIgnoreCase)
                && !full.StartsWith(top + "\\", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (IsNetworkDrive(full) || CrossesLink(top, full))
            {
                return null;
            }
            return (full, root);
        }
        return null;
    }

    private static bool Accepts(string name, string filter) => filter switch
    {
        "csv" => name.EndsWith(".csv", StringComparison.OrdinalIgnoreCase),
        "json" => name.EndsWith(".json", StringComparison.OrdinalIgnoreCase),
        _ => name.EndsWith(".csv", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".json", StringComparison.OrdinalIgnoreCase),
    };

    /// <summary>« \\serveur\partage », « //serveur », « \\?\… » and « \\.\… » are never local.</summary>
    public static bool IsNetworkPath(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        var text = path.Trim();
        return text.StartsWith(@"\\", StringComparison.Ordinal) || text.StartsWith("//", StringComparison.Ordinal);
    }

    private static bool IsNetworkDrive(string full)
    {
        try
        {
            var drive = Path.GetPathRoot(full);
            return drive is null || new DriveInfo(drive).DriveType is DriveType.Network or DriveType.NoRootDirectory;
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }

    /// <summary>True when a folder between the starting place and the target (included) is a link or a junction.</summary>
    private static bool CrossesLink(string top, string full)
    {
        try
        {
            var current = new DirectoryInfo(full);
            if (!current.Exists && File.Exists(full))
            {
                if (new FileInfo(full).Attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    return true;
                }
                current = current.Parent!;
            }
            while (current is not null && current.FullName.TrimEnd('\\').Length >= top.Length)
            {
                if (current.Exists && current.Attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    return true;
                }
                current = current.Parent;
            }
            return false;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }
}

/// <summary>Guides delivered next to the pack (TRV-005): a DOC folder beside Domenia, its parent or the delivery folder.</summary>
public static class GuideLocator
{
    /// <summary>The first existing file of the chapter's guide, or null.</summary>
    public static string? Find(GuideChapter chapter, string appDirectory)
    {
        ArgumentNullException.ThrowIfNull(chapter);
        ArgumentException.ThrowIfNullOrEmpty(appDirectory);
        foreach (var folder in Folders(appDirectory))
        {
            foreach (var file in chapter.Files)
            {
                var path = Path.Combine(folder, "DOC", file);
                try
                {
                    var info = new FileInfo(path);
                    if (info.Exists && !info.Attributes.HasFlag(FileAttributes.ReparsePoint) && !LocalFileBrowser.IsNetworkPath(path))
                    {
                        return info.FullName;
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
                {
                    // An unreadable candidate is skipped; the next one is tried.
                }
            }
        }
        return null;
    }

    private static IEnumerable<string> Folders(string appDirectory)
    {
        var current = new DirectoryInfo(appDirectory);
        for (var level = 0; level < 3 && current is not null; level++)
        {
            yield return current.FullName;
            current = current.Parent;
        }
    }
}

/// <summary>Team layouts of Domenia.config.json next to the executable (TRV-311), read on demand, never written.</summary>
public static class TeamLayoutFile
{
    public static ShellTeamLayout Read(string folder, string board)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        ArgumentException.ThrowIfNullOrEmpty(board);
        var file = Path.Combine(folder, LegacyConfiguration.FileName);
        try
        {
            var info = new FileInfo(file);
            if (!info.Exists)
            {
                return new ShellTeamLayout(board, "Dashboard.DefaultLayout" + board, null, null);
            }
            if (info.Length > LegacyConfiguration.MaxBytes)
            {
                return new ShellTeamLayout(board, "Dashboard.DefaultLayout" + board, null, "fichier de plus de 1 Mo");
            }
            return TeamLayouts.Parse(File.ReadAllBytes(file), board);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new ShellTeamLayout(board, "Dashboard.DefaultLayout" + board, null, "lecture impossible, " + ex.GetType().Name);
        }
    }
}
