using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
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
    public const int MaxDocumentFiles = 4096;
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase)
        { ".json", ".html", ".htm", ".txt", ".csv", ".tsv", ".md", ".xml", ".log", ".png", ".svg", ".sha256" };

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
        RequireFileName(name);
        if (bytes.Length > MaxDocumentBytes)
        {
            throw new DocumentStoreException("document trop volumineux.");
        }
        var temporary = "";
        SharedParkPublicationFile.PathPins? parents = null;
        try
        {
            parents = PrepareFolder(cancellationToken);
            var target = Unique(name, isFolder: false);
            temporary = TemporaryPath();
            var expected = SHA256.HashData(bytes.Span);
            await WriteAsync(temporary, bytes, cancellationToken).ConfigureAwait(false);
            VerifyFile(temporary, bytes.Length, expected, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporary, target, overwrite: false);
            temporary = "";
            VerifyFile(target, bytes.Length, expected, CancellationToken.None);
            return new SavedDocument(true, target, Path.GetFileName(target), folder);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or NotSupportedException)
        {
            log.Warning($"Document non enregistré ({ex.GetType().Name}).");
            throw new DocumentStoreException(Reason(ex), ex);
        }
        finally
        {
            Discard(temporary, isFolder: false);
            parents?.Dispose();
        }
    }

    public async Task<SavedDocument> SaveFolderAsync(string name, IReadOnlyList<DocumentFile> files, CancellationToken cancellationToken)
    {
        RequireName(name);
        ArgumentNullException.ThrowIfNull(files);
        if (files.Count > MaxDocumentFiles || files.Sum(f => (long)f.Bytes.Length) > MaxDocumentBytes)
        {
            throw new DocumentStoreException("dossier trop volumineux.");
        }
        foreach (var file in files)
        {
            RequireFileName(file.Name);
        }
        if (files.Select(f => f.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != files.Count)
            throw new ArgumentException("Noms de documents en double : aucun dossier publié.", nameof(files));
        var temporary = "";
        SharedParkPublicationFile.PathPins? parents = null;
        try
        {
            parents = PrepareFolder(cancellationToken);
            var target = Unique(name, isFolder: true);
            temporary = TemporaryPath();
            Directory.CreateDirectory(temporary);
            var proofs = new List<(string Name, int Bytes, byte[] Hash)>();
            using (var staged = new SharedParkPublicationFile.PathPins(temporary, cancellationToken))
            {
                foreach (var file in files)
                {
                    var hash = SHA256.HashData(file.Bytes);
                    await WriteAsync(Path.Combine(temporary, file.Name), file.Bytes, cancellationToken).ConfigureAwait(false);
                    VerifyFile(Path.Combine(temporary, file.Name), file.Bytes.Length, hash, cancellationToken);
                    proofs.Add((file.Name, file.Bytes.Length, hash));
                }
            }
            cancellationToken.ThrowIfCancellationRequested();
            Directory.Move(temporary, target);
            temporary = "";
            using var published = new SharedParkPublicationFile.PathPins(target, CancellationToken.None);
            foreach (var proof in proofs) VerifyFile(Path.Combine(target, proof.Name), proof.Bytes, proof.Hash, CancellationToken.None);
            return new SavedDocument(true, target, Path.GetFileName(target), folder);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or NotSupportedException)
        {
            log.Warning($"Dossier non enregistré ({ex.GetType().Name}).");
            throw new DocumentStoreException(Reason(ex), ex);
        }
        finally
        {
            Discard(temporary, isFolder: true);
            parents?.Dispose();
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
            if (CheckLocalFolder(folder) is not null) return Task.FromResult(false);
            using var parents = new SharedParkPublicationFile.PathPins(folder, cancellationToken);
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
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
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
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
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

    private static void RequireFileName(string name)
    {
        RequireName(name);
        if (!Extensions.Contains(Path.GetExtension(name))) throw new ArgumentException("Type de document non autorisé.", nameof(name));
    }

    /// <summary>A plain name of this folder: no separator, no « .. », no invalid character, 200 characters at most.</summary>
    private static bool IsPlainName(string? name) =>
        !string.IsNullOrWhiteSpace(name) && name.Length <= 200 && name != "." && name != ".." && !name.StartsWith('.')
        && !name.EndsWith(' ') && !name.EndsWith('.') && !ReservedName(name)
        && name.IndexOfAny(Path.GetInvalidFileNameChars()) < 0 && name.IndexOfAny(['/', '\\', ':']) < 0;

    private static bool ReservedName(string name)
    {
        var stem = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        return stem is "CON" or "PRN" or "AUX" or "NUL" || stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && (stem[3] is >= '1' and <= '9' or '¹' or '²' or '³');
    }

    private string TemporaryPath() => Path.Combine(folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");

    private SharedParkPublicationFile.PathPins PrepareFolder(CancellationToken token)
    {
        for (var at = new DirectoryInfo(folder); at is not null; at = at.Parent)
            if (at.Exists && at.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException(LinkMessage);
        CompatibleDirectoryCache.ValidateLocalPath(Path.Combine(folder, "document.json"));
        var root = Path.GetPathRoot(folder)!;
        var pins = new SharedParkPublicationFile.PathPins(root, token);
        try
        {
            var parts = new Stack<DirectoryInfo>();
            for (var at = new DirectoryInfo(folder); at.Parent is not null; at = at.Parent) parts.Push(at);
            foreach (var part in parts)
            {
                token.ThrowIfCancellationRequested();
                if (part.Exists && part.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException(LinkMessage);
                part.Create();
                pins.Add(part.FullName);
            }
            return pins;
        }
        catch { pins.Dispose(); throw; }
    }

    private static void VerifyFile(string path, int bytes, byte[] expected, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var read = SharedParkPublicationFile.BoundFile.Open(path, MaxDocumentBytes, token, allowDelete: false);
        if (read.Length != bytes || !Convert.FromHexString(read.Sha256).AsSpan().SequenceEqual(expected))
            throw new IOException("Document relu différent des octets demandés ; enregistrement non confirmé.");
        token.ThrowIfCancellationRequested();
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
        InvalidDataException => "emplacement local non vérifiable ou redirigé ; aucun enregistrement confirmé.",
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
