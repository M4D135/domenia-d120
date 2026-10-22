namespace Domenia.Core.Queries;

/// <summary>New content of a library document; <see cref="KeepPrevious"/> asks the store to keep the replaced one aside.</summary>
public sealed record QueryStoreUpdate(byte[] Document, bool KeepPrevious);

/// <summary>Outcome of one write: stored on a durable medium or for the session only, and read back identical from it.</summary>
public sealed record QueryStoreWrite(bool Persisted, bool ReadBack);

/// <summary>
/// Medium of the query library: one document per domain (key: hash of the domain root), written atomically under an
/// exclusive lock shared by every Domenia process of the machine. Every write is a read-modify-write of the document as
/// it is on the medium at that instant, so two instances never erase each other's revisions; the written document is read
/// back from the medium before the receipt says « relue ». A file of its own in the user data folder in directory and
/// simulation modes (never the shared preferences document), memory only in capture and E2E modes.
/// </summary>
public interface IQueryLibraryStore
{
    /// <summary>False when the documents live in memory only (capture, E2E, no data folder, tests).</summary>
    bool Persistent { get; }

    /// <summary>The document of a domain as stored now, or null when there is none. IOException when it cannot be read.</summary>
    Task<byte[]?> ReadAsync(string rootKey, CancellationToken cancellationToken);

    /// <summary>
    /// Exclusive read-modify-write: <paramref name="update"/> receives the document read from the medium under the lock and
    /// returns the new one (null: nothing to write, the result is then null). An exception thrown by <paramref name="update"/>
    /// writes nothing. IOException or UnauthorizedAccessException when the medium refuses the write: nothing is changed.
    /// </summary>
    Task<QueryStoreWrite?> UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken);
}

/// <summary>Library documents kept in memory only: nothing is read or written on disk.</summary>
public sealed class MemoryQueryLibraryStore : IQueryLibraryStore, IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, byte[]> documents = new(StringComparer.Ordinal);

    public bool Persistent => false;

    /// <summary>Number of documents replaced aside (tests).</summary>
    public int KeptAside { get; private set; }

    public async Task<byte[]?> ReadAsync(string rootKey, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(rootKey);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return documents.TryGetValue(rootKey, out var document) ? document : null;
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<QueryStoreWrite?> UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(rootKey);
        ArgumentNullException.ThrowIfNull(update);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var current = documents.TryGetValue(rootKey, out var document) ? document : null;
            if (update(current) is not { } next)
            {
                return null;
            }
            if (next.KeepPrevious && current is not null)
            {
                KeptAside++;
            }
            var copy = next.Document.ToArray();
            documents[rootKey] = copy;
            return new QueryStoreWrite(false, documents[rootKey].AsSpan().SequenceEqual(next.Document));
        }
        finally
        {
            gate.Release();
        }
    }

    public void Dispose() => gate.Dispose();
}
