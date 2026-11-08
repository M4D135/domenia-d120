namespace Domenia.Core;

/// <summary>One file of a folder document (an offline dossier): its name inside the folder and its bytes.</summary>
public sealed record DocumentFile(string Name, byte[] Bytes);

/// <summary>
/// Where a document went: written (<see cref="Saved"/>, full path and folder) or kept in memory only (capture, E2E, no data
/// folder), with the name it would have had.
/// </summary>
public sealed record SavedDocument(bool Saved, string? Path, string Name, string? Folder);

/// <summary>
/// A document could not be written: <see cref="Reason"/> is a short French sentence for the operator (access refused, link,
/// full disk…). Nothing was replaced and no partial document is left under its final name.
/// </summary>
public sealed class DocumentStoreException : IOException
{
    public DocumentStoreException()
        : this("le disque a refusé l’écriture.")
    {
    }

    public DocumentStoreException(string reason)
        : this(reason, null)
    {
    }

    public DocumentStoreException(string reason, Exception? innerException)
        : base(reason, innerException) => Reason = reason;

    public string Reason { get; }
}

/// <summary>
/// Documents the operator asks a screen to write (exports, reports, offline dossiers), in the exports folder of the mode
/// (docs/PLATFORM.md § 3.3): %LOCALAPPDATA%\Domenia\Exports, or Exports-simulation in simulation, never shared. Every document
/// is new and dated by its caller: a name already taken gets « -2 », « -3 »…, nothing is ever overwritten. Writes are atomic
/// (temporary file or folder beside the target, flushed, then renamed). In capture mode, in E2E mode or without a data folder,
/// nothing is written (<see cref="Persistent"/> false): the result says so. Never the directory, never a workstation.
/// </summary>
public interface IDocumentStore
{
    /// <summary>True when documents are written on the disk; false in capture or E2E mode, or without a data folder.</summary>
    bool Persistent { get; }

    /// <summary>Folder of the documents, for the operator; null when nothing is written.</summary>
    string? Folder { get; }

    /// <summary>Writes a new file; <see cref="DocumentStoreException"/> when the disk refuses (nothing replaced).</summary>
    Task<SavedDocument> SaveFileAsync(string name, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken);

    /// <summary>Writes a new folder with its files (temporary folder renamed at the end); the same refusals.</summary>
    Task<SavedDocument> SaveFolderAsync(string name, IReadOnlyList<DocumentFile> files, CancellationToken cancellationToken);

    /// <summary>
    /// Shows a document written in the folder (Windows Explorer opened on it). False when the name is not a document of the
    /// folder (absent, a link, a path) or when nothing is written in this mode.
    /// </summary>
    Task<bool> RevealAsync(string name, CancellationToken cancellationToken);
}

/// <summary>Nothing is written (capture mode, E2E mode, no data folder, tests): every document stays in memory.</summary>
public sealed class MemoryDocumentStore : IDocumentStore
{
    public bool Persistent => false;

    public string? Folder => null;

    public Task<SavedDocument> SaveFileAsync(string name, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new SavedDocument(false, null, name, null));
    }

    public Task<SavedDocument> SaveFolderAsync(string name, IReadOnlyList<DocumentFile> files, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new SavedDocument(false, null, name, null));
    }

    public Task<bool> RevealAsync(string name, CancellationToken cancellationToken) => Task.FromResult(false);
}
