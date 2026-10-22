using System.Diagnostics;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Documents written in one folder of the user data (docs/PLATFORM.md § 3.3): %LOCALAPPDATA%\Domenia\Exports, or
/// Exports-simulation in simulation (never shared with the directory mode); the offline dossier command writes in the folder
/// the operator names. Operation class LocalWrite: never the directory, never a workstation.
/// <para>
/// Every document is new: a name already taken gets « -2 », « -3 »… (99 tries), nothing is ever overwritten. A file is written
/// beside its target in a temporary file (write-through, flushed to the disk) then renamed without replacement; a folder is
/// written in a temporary folder then renamed, so a stop never leaves half a document under its final name, and the temporary
/// copy is removed on any failure. A link (reparse point) in place of the folder is refused. Failures raise
/// <see cref="DocumentStoreException"/> with a French reason; the technical journal keeps the exception type only.
/// </para>
/// </summary>
public sealed class FileDocumentStore : IDocumentStore
{
    public const string DirectoryFolderName = "Exports";
    public const string SimulationFolderName = "Exports-simulation";

    /// <summary>Largest document (a file, or the files of a folder together).</summary>
    public const long MaxDocumentBytes = 128L * 1024 * 1024;

    private const string LinkMessage = "Exports folder is a link.";
    private readonly string folder;
    private readonly ITechnicalJournal log;
    private readonly Action<string, bool> reveal;

    /// <param name="folder">Absolute folder of the documents (created at the first write).</param>
    /// <param name="reveal">Shows a written document (path, is a folder); Windows Explorer by default. Tests pass their own.</param>
    public FileDocumentStore(string folder, ITechnicalJournal log, Action<string, bool>? reveal = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        ArgumentNullException.ThrowIfNull(log);
        if (!Path.IsPathFullyQualified(folder))
        {
            // Never relative to the current folder, which may be the share or key the pack runs from.
            throw new ArgumentException("The documents folder must be absolute.", nameof(folder));
        }
        this.folder = Path.GetFullPath(folder);
        this.log = log;
        this.reveal = reveal ?? ShowInExplorer;
    }

    /// <summary>Name of the exports folder of a mode, under the user data folder.</summary>
    public static string FolderNameFor(AppMode mode) => mode == AppMode.Simulation ? SimulationFolderName : DirectoryFolderName;

    public bool Persistent => true;

    public string? Folder => folder;

    public async Task<SavedDocument> SaveFileAsync(string name, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken)
    {
        RequireName(name);
        if (bytes.Length > MaxDocumentBytes)
        {
            throw new DocumentStoreException("document trop volumineux.");
        }
        var temporary = "";
        try
        {
            PrepareFolder();
            var target = Unique(name, isFolder: false);
            temporary = TemporaryPath();
            await WriteAsync(temporary, bytes, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, target, overwrite: false);
            temporary = "";
            return new SavedDocument(true, target, Path.GetFileName(target), folder);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            log.Warning($"Document non enregistré ({ex.GetType().Name}).");
            throw new DocumentStoreException(Reason(ex), ex);
        }
        finally
        {
            Discard(temporary, isFolder: false);
        }
    }

    public async Task<SavedDocument> SaveFolderAsync(string name, IReadOnlyList<DocumentFile> files, CancellationToken cancellationToken)
    {
        RequireName(name);
        ArgumentNullException.ThrowIfNull(files);
        if (files.Sum(f => (long)f.Bytes.Length) > MaxDocumentBytes)
        {
            throw new DocumentStoreException("dossier trop volumineux.");
        }
        foreach (var file in files)
        {
            RequireName(file.Name);
        }
        var temporary = "";
        try
        {
            PrepareFolder();
            var target = Unique(name, isFolder: true);
            temporary = TemporaryPath();
            Directory.CreateDirectory(temporary);
            foreach (var file in files)
            {
                await WriteAsync(Path.Combine(temporary, file.Name), file.Bytes, cancellationToken).ConfigureAwait(false);
            }
            Directory.Move(temporary, target);
            temporary = "";
            return new SavedDocument(true, target, Path.GetFileName(target), folder);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            log.Warning($"Dossier non enregistré ({ex.GetType().Name}).");
            throw new DocumentStoreException(Reason(ex), ex);
        }
        finally
        {
            Discard(temporary, isFolder: true);
        }
    }

    public Task<bool> RevealAsync(string name, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsPlainName(name))
        {
            return Task.FromResult(false);
        }
        var path = Path.Combine(folder, name);
        try
        {
            var root = new DirectoryInfo(folder);
            if (!root.Exists || root.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                return Task.FromResult(false);
            }
            FileSystemInfo item = Directory.Exists(path) ? new DirectoryInfo(path) : new FileInfo(path);
            if (!item.Exists || item.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                return Task.FromResult(false);
            }
            reveal(item.FullName, item is DirectoryInfo);
            return Task.FromResult(true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            log.Warning($"Document non affiché dans l’Explorateur ({ex.GetType().Name}).");
            return Task.FromResult(false);
        }
    }

    /// <summary>
    /// A folder the operator names for a document (offline dossier command): absolute, local, existing, never redirected. A
    /// network share (UNC path or network drive) or a link anywhere on the path is refused (Domenia 1
    /// Test-DomeniaAutomationLocalPath): the reason in French, or null when the folder may be used.
    /// </summary>
    public static string? CheckLocalFolder(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return "Dossier de destination requis.";
        }
        string full;
        try
        {
            full = Path.GetFullPath(path.Trim());
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return "Dossier de destination illisible.";
        }
        if (full.StartsWith(@"\\", StringComparison.Ordinal) || Path.GetPathRoot(full) is not { Length: > 0 } root)
        {
            return "Dossier de destination sur un partage réseau" + FrenchText.Colon + "refusé.";
        }
        try
        {
            if (new DriveInfo(root).DriveType == DriveType.Network)
            {
                return "Dossier de destination sur un lecteur réseau" + FrenchText.Colon + "refusé.";
            }
            var cursor = new DirectoryInfo(full);
            if (!cursor.Exists)
            {
                return "Dossier de destination absent.";
            }
            for (var item = cursor; item is not null; item = item.Parent)
            {
                if (item.Attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    return "Dossier de destination redirigé (lien)" + FrenchText.Colon + "refusé.";
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return "Dossier de destination inaccessible.";
        }
        return null;
    }

    private static void RequireName(string name)
    {
        if (!IsPlainName(name))
        {
            throw new ArgumentException("A document name is a plain file name.", nameof(name));
        }
    }

    /// <summary>A plain name of this folder: no separator, no « .. », no invalid character, 200 characters at most.</summary>
    private static bool IsPlainName(string? name) =>
        !string.IsNullOrWhiteSpace(name) && name.Length <= 200 && name != "." && name != ".." && !name.StartsWith('.')
        && name.IndexOfAny(Path.GetInvalidFileNameChars()) < 0 && name.IndexOfAny(['/', '\\', ':']) < 0;

    private string TemporaryPath() => Path.Combine(folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");

    private void PrepareFolder()
    {
        var info = new DirectoryInfo(folder);
        if (info.Exists && info.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new IOException(LinkMessage);
        }
        info.Create();
    }

    private string Unique(string name, bool isFolder)
    {
        var stem = isFolder ? name : Path.GetFileNameWithoutExtension(name);
        var extension = isFolder ? "" : Path.GetExtension(name);
        for (var n = 1; n < 100; n++)
        {
            var candidate = Path.Combine(folder, stem + (n == 1 ? "" : "-" + n.ToString(CultureInfo.InvariantCulture)) + extension);
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }
        throw new IOException("No free name.");
    }

    private static async Task WriteAsync(string path, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken)
    {
        var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough | FileOptions.Asynchronous);
        await using (stream.ConfigureAwait(false))
        {
            await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            stream.Flush(flushToDisk: true);
        }
    }

    private void Discard(string path, bool isFolder)
    {
        if (path.Length == 0)
        {
            return;
        }
        try
        {
            if (isFolder && Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
            else if (!isFolder && File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Fichier temporaire d’un document non supprimé ({ex.GetType().Name}).");
        }
    }

    private static string Reason(Exception ex) => ex switch
    {
        UnauthorizedAccessException => "accès refusé au dossier des documents.",
        PathTooLongException => "chemin trop long.",
        _ when ex.Message == LinkMessage => "le dossier des documents est un lien, refusé.",
        _ => "le disque a refusé l’écriture (plein, verrouillé ou indisponible).",
    };

    /// <summary>Windows Explorer on the document: the folder opened, or the file selected in its folder. No shell, no secret.</summary>
    private static void ShowInExplorer(string path, bool isFolder)
    {
        var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        if (isFolder)
        {
            start.ArgumentList.Add(path);
        }
        else
        {
            // « explorer /select, "<path>" »: the path stays one argument, spaces included.
            start.ArgumentList.Add("/select,");
            start.ArgumentList.Add(path);
        }
        using var process = Process.Start(start);
    }
}
