using System.Collections.Concurrent;
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
/// folder lists 500 entries at most, folders first. Read only: nothing is created, nothing is written (the save mode writes
/// through <see cref="LocalFileWriter"/>). A network share is listed only on an explicit request of the operator
/// (<see cref="BrowseShareAsync"/>, 15 s at most), and a file of a share is read only from a folder listed that way.
/// </summary>
public sealed class LocalFileBrowser
{
    /// <summary>Entries of a folder at most.</summary>
    public const int MaxEntries = 500;

    /// <summary>Largest file read for an import.</summary>
    public const int MaxFileBytes = 1_048_576;

    /// <summary>Longest wait for a network share (Domenia 1: 15 s).</summary>
    public static readonly TimeSpan ShareTimeout = TimeSpan.FromSeconds(15);

    private readonly ImmutableArray<ShellFileRoot> roots;
    private readonly Func<string, DriveType> driveType;
    private readonly ConcurrentDictionary<string, byte> grantedShares = new(StringComparer.OrdinalIgnoreCase);

    public LocalFileBrowser(IEnumerable<ShellFileRoot> roots) : this(roots, DriveTypeOf)
    {
    }

    /// <summary>
    /// Starting places kept: absolute, not a network path, and on a fixed or removable local drive. The type of the drive is
    /// asked here, once (a mapped drive is filtered before any listing could touch the network); tests inject it.
    /// </summary>
    public LocalFileBrowser(IEnumerable<ShellFileRoot> roots, Func<string, DriveType> driveType)
    {
        ArgumentNullException.ThrowIfNull(roots);
        ArgumentNullException.ThrowIfNull(driveType);
        this.driveType = driveType;
        this.roots = [.. roots.Where(r => Path.IsPathFullyQualified(r.Path) && !IsNetworkPath(r.Path) && IsLocalDrive(r.Path))];
    }

    private bool IsLocalDrive(string path)
    {
        var root = Path.GetPathRoot(path);
        return root is not null && driveType(root) is DriveType.Fixed or DriveType.Removable or DriveType.Ram or DriveType.CDRom;
    }

    private static DriveType DriveTypeOf(string root)
    {
        try
        {
            return new DriveInfo(root).DriveType;
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException)
        {
            return DriveType.NoRootDirectory;
        }
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
            var all = Entries(info, filter).Take(MaxEntries + 1).ToList();
            var parent = string.Equals(full.TrimEnd('\\'), root.Path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ? null : Path.GetDirectoryName(full);
            return new ShellFolderListing(full, Label(full, root), parent, [.. all.Take(MaxEntries)], all.Count > MaxEntries, null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new DomeniaOperationException(ShellErrors.FolderUnavailable, ShellErrors.FolderUnavailableMessage);
        }
    }

    /// <summary>
    /// Readable place of a folder below a starting place (« Documents › Rapports »): never the full path, which holds the user
    /// name. « Emplacement choisi » for a folder outside the starting places.
    /// </summary>
    public string LabelOf(string folder)
    {
        ArgumentNullException.ThrowIfNull(folder);
        return Resolve(folder) is { } found ? Label(found.Full, found.Root) : "Emplacement choisi";
    }

    private static string Label(string full, ShellFileRoot root) =>
        string.Equals(full.TrimEnd('\\'), root.Path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)
            ? root.Label
            : root.Label + FrenchText.PathSeparator + Path.GetRelativePath(root.Path, full).Replace("\\", FrenchText.PathSeparator, StringComparison.Ordinal);

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
        return ReadFile(full, kind);
    }

    private static ShellFileContent ReadFile(string full, string kind)
    {
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
            if (!IsLocalDrive(full) || CrossesLink(top, full))
            {
                return null;
            }
            return (full, root);
        }
        return null;
    }

    /// <summary>
    /// « \\serveur\partage » or a folder below it: a server name and a share name of letters, digits, dots, dashes, underscores
    /// or « $ », then plain folder names. Device paths (« \\?\ », « \\.\ »), « .. » segments and the characters Windows
    /// refuses are not shares.
    /// </summary>
    public static bool IsShareFolder(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 1024 || !path.StartsWith(@"\\", StringComparison.Ordinal))
        {
            return false;
        }
        var parts = path[2..].TrimEnd('\\').Split('\\');
        if (parts.Length < 2 || parts[0] is "?" or ".")
        {
            return false;
        }
        static bool Name(string p, bool server) => p.Length is > 0 and <= 255 && p is not ("." or "..") && !p.EndsWith(' ') && !p.EndsWith('.')
            && p.All(c => server ? char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_' : !char.IsControl(c) && c is not ('/' or ':' or '*' or '?' or '"' or '<' or '>' or '|'));
        return Name(parts[0], true) && parts.Skip(1).All(p => Name(p, false));
    }

    /// <summary>
    /// Lists a network share on the explicit request of the operator (Domenia 1 TRV-244: « un partage réseau n’est interrogé
    /// qu’à la demande »): 15 s at most, 500 entries, no link, nothing created. The folder is then admitted for the reading of
    /// one of its files during this session.
    /// </summary>
    public async Task<ShellFolderListing> BrowseShareAsync(string folder, string filter, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);
        if (!IsShareFolder(folder))
        {
            throw new DomeniaOperationException(ShellErrors.ShareRefused, ShellErrors.ShareRefusedMessage);
        }
        var clean = folder.TrimEnd('\\');
        var listing = await WithTimeoutAsync(() => ListShare(clean, filter), cancellationToken).ConfigureAwait(false);
        grantedShares[clean] = 0;
        return listing;
    }

    /// <summary>Reads a file of a share folder listed during this session (same bounds as a local file), 15 s at most.</summary>
    public async Task<ShellFileContent> ReadShareAsync(string path, string kind, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(kind);
        var folder = IsShareFolder(path) ? Path.GetDirectoryName(path) : null;
        if (folder is null || !grantedShares.ContainsKey(folder.TrimEnd('\\')) || !Accepts(path, kind))
        {
            throw new DomeniaOperationException(ShellErrors.ShareRefused, ShellErrors.ShareRefusedMessage);
        }
        return await WithTimeoutAsync(() => ReadFile(path, kind), cancellationToken).ConfigureAwait(false);
    }

    private static async Task<T> WithTimeoutAsync<T>(Func<T> work, CancellationToken cancellationToken)
    {
        try
        {
            return await Task.Run(work, cancellationToken).WaitAsync(ShareTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            throw new DomeniaOperationException(ShellErrors.ShareTimeout, ShellErrors.ShareTimeoutMessage);
        }
    }

    private static ShellFolderListing ListShare(string folder, string filter)
    {
        var info = new DirectoryInfo(folder);
        try
        {
            if (!info.Exists)
            {
                throw new DomeniaOperationException(ShellErrors.FolderUnavailable, ShellErrors.FolderUnavailableMessage);
            }
            var all = Entries(info, filter).Take(MaxEntries + 1).ToList();
            var parts = folder[2..].Split('\\');
            var parent = parts.Length > 2 ? Path.GetDirectoryName(folder) : null;
            var label = string.Join(FrenchText.PathSeparator, parts);
            return new ShellFolderListing(folder, label, parent, [.. all.Take(MaxEntries)], all.Count > MaxEntries, "Partage réseau interrogé à votre demande.", Share: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            throw new DomeniaOperationException(ShellErrors.FolderUnavailable, ShellErrors.FolderUnavailableMessage);
        }
    }

    private static IEnumerable<ShellFileEntry> Entries(DirectoryInfo info, string filter)
    {
        var directories = info.EnumerateDirectories()
            .Where(d => !d.Attributes.HasFlag(FileAttributes.ReparsePoint) && !d.Attributes.HasFlag(FileAttributes.Hidden) && !d.Attributes.HasFlag(FileAttributes.System))
            .OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase)
            .Select(d => new ShellFileEntry(d.Name, d.FullName, "folder", null, new DateTimeOffset(d.LastWriteTimeUtc, TimeSpan.Zero)));
        var files = info.EnumerateFiles()
            .Where(f => !f.Attributes.HasFlag(FileAttributes.ReparsePoint) && !f.Attributes.HasFlag(FileAttributes.Hidden) && Accepts(f.Name, filter))
            .OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase)
            .Select(f => new ShellFileEntry(f.Name, f.FullName, "file", f.Length, new DateTimeOffset(f.LastWriteTimeUtc, TimeSpan.Zero)));
        return directories.Concat(files);
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

/// <summary>
/// Guides delivered next to the pack (TRV-005): a DOC folder beside Domenia, its parent or the delivery folder. The network
/// is tested first: when the application runs from a share or a mapped drive, the folders are looked at once and the answer
/// is kept for the session (no network access at each change of screen while the help panel is open). On a local disk a
/// found guide is kept, an absent one is looked for again (« placez le PDF, puis réessayez »).
/// </summary>
public sealed class GuideLocator
{
    private readonly string appDirectory;
    private readonly bool remote;
    private readonly ConcurrentDictionary<string, string?> cache = new(StringComparer.Ordinal);

    public GuideLocator(string appDirectory) : this(appDirectory, root => new DriveInfo(root).DriveType)
    {
    }

    /// <summary>Tests inject the type of the drive.</summary>
    public GuideLocator(string appDirectory, Func<string, DriveType> driveType)
    {
        ArgumentException.ThrowIfNullOrEmpty(appDirectory);
        ArgumentNullException.ThrowIfNull(driveType);
        this.appDirectory = appDirectory;
        remote = LocalFileBrowser.IsNetworkPath(appDirectory) || IsRemoteDrive(appDirectory, driveType);
    }

    /// <summary>True when the application folder is on a network share or a mapped drive.</summary>
    public bool Remote => remote;

    /// <summary>The first existing file of the chapter's guide, or null.</summary>
    public string? Find(GuideChapter chapter)
    {
        ArgumentNullException.ThrowIfNull(chapter);
        if (cache.TryGetValue(chapter.Guide, out var known) && (known is not null || remote))
        {
            return known;
        }
        var found = Look(chapter);
        if (found is not null || remote)
        {
            cache[chapter.Guide] = found;
        }
        return found;
    }

    private string? Look(GuideChapter chapter)
    {
        foreach (var folder in Folders(appDirectory))
        {
            foreach (var file in chapter.Files)
            {
                var path = Path.Combine(folder, "DOC", file);
                try
                {
                    var info = new FileInfo(path);
                    if (info.Exists && !info.Attributes.HasFlag(FileAttributes.ReparsePoint))
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

    private static bool IsRemoteDrive(string folder, Func<string, DriveType> driveType)
    {
        try
        {
            var root = Path.GetPathRoot(folder);
            return root is null || driveType(root) is DriveType.Network or DriveType.NoRootDirectory;
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException)
        {
            return true;
        }
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

/// <summary>
/// Save mode of the embedded file picker (Domenia 1 TRV-244): writes a file the operator placed in a folder of the starting
/// places (local only, no link), next to its final name then moved; an existing file is replaced only on « Remplacer », and
/// only while it keeps the size and date the picker listed. Nothing partial ever stays under the final name.
/// </summary>
public sealed class LocalFileWriter(LocalFileBrowser browser)
{
    private readonly LocalFileBrowser browser = browser ?? throw new ArgumentNullException(nameof(browser));

    /// <summary>Readable place of a folder (see <see cref="LocalFileBrowser.LabelOf"/>).</summary>
    public string LabelOf(string folder) => browser.LabelOf(folder);

    /// <summary>Writes the content; returns the full path written.</summary>
    public async Task<string> SaveAsync(ShellSaveTarget target, string kind, ReadOnlyMemory<byte> content, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(kind);
        var resolved = ShellFileNames.IsSafe(target.FileName, kind) ? browser.Resolve(target.Folder) : null;
        if (resolved is null || !Directory.Exists(resolved.Value.Full))
        {
            throw new DomeniaOperationException(ShellErrors.FileRefused, ShellErrors.FileRefusedMessage);
        }
        var folder = resolved.Value.Full;
        var path = Path.Combine(folder, target.FileName);
        if (!string.Equals(Path.GetDirectoryName(path)?.TrimEnd('\\'), folder.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
        {
            throw new DomeniaOperationException(ShellErrors.FileRefused, ShellErrors.FileRefusedMessage);
        }
        CheckTarget(path, target.Replace);
        var temporary = Path.Combine(folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough))
            {
                await stream.WriteAsync(content, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            // Checked again at the last moment: another program may have written the file meanwhile.
            CheckTarget(path, target.Replace);
            try
            {
                File.Move(temporary, path, overwrite: target.Replace is not null);
            }
            catch (IOException) when (target.Replace is null && File.Exists(path))
            {
                throw new DomeniaOperationException(ShellErrors.FileExists, ShellErrors.FileExistsMessage);
            }
            return path;
        }
        finally
        {
            try
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // A temporary file still held is hidden and never listed; it is left for later.
            }
        }
    }

    private static void CheckTarget(string path, ShellFileSignature? replace)
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            if (replace is not null)
            {
                throw new DomeniaOperationException(ShellErrors.FileChanged, ShellErrors.FileChangedMessage);
            }
            return;
        }
        if (replace is null)
        {
            throw new DomeniaOperationException(ShellErrors.FileExists, ShellErrors.FileExistsMessage);
        }
        if (info.Attributes.HasFlag(FileAttributes.ReparsePoint) || info.Attributes.HasFlag(FileAttributes.ReadOnly)
            || !replace.Matches(info.Length, new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero)))
        {
            throw new DomeniaOperationException(ShellErrors.FileChanged, ShellErrors.FileChangedMessage);
        }
    }
}

/// <summary>Interface policy of Domenia.config.json next to the executable (UI.AllowExpertProfile), read on demand, never written.</summary>
public static class ShellPolicyFile
{
    public static ShellPolicy Read(string folder)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        var file = Path.Combine(folder, LegacyConfiguration.FileName);
        try
        {
            var info = new FileInfo(file);
            if (!info.Exists)
            {
                return ShellPolicies.Default;
            }
            if (info.Length > LegacyConfiguration.MaxBytes)
            {
                return ShellPolicies.Default with { Problem = "fichier de plus de 1 Mo" };
            }
            return ShellPolicies.Parse(File.ReadAllBytes(file));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return ShellPolicies.Default with { Problem = "lecture impossible, " + ex.GetType().Name };
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
