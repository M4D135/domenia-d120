using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Bridge.Operations.Requetes;

/// <summary>
/// Shared services of the query workshop for every module of the screen (and later the Accueil and the Fiche, which read the
/// widgets): one library per engine context, on its own file when the preferences of the mode are persistent, in memory
/// otherwise (capture, E2E, tests).
/// </summary>
public static class RequetesServices
{
    public static QueryLibrary Library(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new QueryLibrary(QueryLibraryFiles.For(c), c.Journal, c.Clock, c.Log));
    }
}

/// <summary>
/// Library documents of the query workshop in the user data folder (LocalWrite, never the directory):
/// %LOCALAPPDATA%\Domenia\Requetes\bibliotheque-&lt;domaine&gt;.json, or bibliotheque-simulation-&lt;domaine&gt;.json in simulation
/// (never shared with the directory mode). One file per domain, apart from the preferences document: its size never threatens
/// the preferences of the other screens. Every write takes a lock shared by every Domenia process of the machine, reads the
/// file again, lets the library check its revisions against it, writes a temporary file of the same folder (flushed to disk)
/// and moves it over the document, then reads the document back and compares it byte for byte. A document that cannot be
/// used is kept aside (« .illisible-AAAAMMJJ-HHmmss ») before it is replaced, never silently lost.
/// </summary>
public sealed class QueryLibraryFiles : IQueryLibraryStore
{
    /// <summary>Larger files are refused (the library keeps its documents under 16 Mio).</summary>
    public const long MaxFileBytes = 24L * 1024 * 1024;

    private static readonly TimeSpan LockTimeout = TimeSpan.FromSeconds(5);
    private readonly string folder;
    private readonly bool simulation;
    private readonly ITechnicalJournal log;

    public QueryLibraryFiles(string folder, bool simulation, ITechnicalJournal log)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        ArgumentNullException.ThrowIfNull(log);
        if (!Path.IsPathFullyQualified(folder))
        {
            // Never relative to the current folder, which may be the share or key the pack runs from.
            throw new ArgumentException("The library folder must be absolute.", nameof(folder));
        }
        this.folder = folder;
        this.simulation = simulation;
        this.log = log;
    }

    /// <summary>The medium of the mode: its own file when the preferences are persistent, memory otherwise.</summary>
    public static IQueryLibraryStore For(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (!context.Preferences.Persistent)
        {
            return new MemoryQueryLibraryStore();
        }
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify);
        if (!Path.IsPathFullyQualified(root))
        {
            return new MemoryQueryLibraryStore();
        }
        return new QueryLibraryFiles(Path.Combine(root, "Domenia", "Requetes"), context.Mode == AppMode.Simulation, context.Log);
    }

    public bool Persistent => true;

    /// <summary>File of a domain (the key is the SHA-256 of its root: no domain name in the file name).</summary>
    public string PathOf(string rootKey)
    {
        ArgumentException.ThrowIfNullOrEmpty(rootKey);
        if (rootKey.Length != 64 || !rootKey.All(char.IsAsciiHexDigitLower))
        {
            throw new ArgumentException("Invalid domain key.", nameof(rootKey));
        }
        return Path.Combine(folder, (simulation ? "bibliotheque-simulation-" : "bibliotheque-") + rootKey[..32] + ".json");
    }

    public Task<byte[]?> ReadAsync(string rootKey, CancellationToken cancellationToken)
    {
        var path = PathOf(rootKey);
        return Task.Run(() => Read(path), cancellationToken);
    }

    public async Task<QueryStoreWrite?> UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(update);
        var path = PathOf(rootKey);
        // One thread from start to end: the machine-wide lock belongs to the thread that took it.
        return await Task.Run(() => Update(path, update, cancellationToken), cancellationToken).ConfigureAwait(false);
    }

    private static byte[]? Read(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                return null;
            }
            if (info.Length > MaxFileBytes)
            {
                throw new IOException("The query library document is too large.");
            }
            return File.ReadAllBytes(path);
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
    }

    private QueryStoreWrite? Update(string path, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var machineLock = new Mutex(initiallyOwned: false, LockName(path));
        if (!Acquire(machineLock))
        {
            throw new IOException("The query library is being written by another instance of Domenia.");
        }
        try
        {
            // Read again under the lock: what another instance wrote meanwhile is the base of this write.
            var current = Read(path);
            if (update(current) is not { } next)
            {
                return null;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (next.KeepPrevious && current is not null)
            {
                KeepAside(path);
            }
            var temporary = path + "." + Environment.ProcessId.ToString(CultureInfo.InvariantCulture) + ".tmp";
            try
            {
                using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    stream.Write(next.Document);
                    stream.Flush(flushToDisk: true);
                }
                // Same folder, same volume: a reader sees the old or the new document, never half of it.
                File.Move(temporary, path, overwrite: true);
            }
            finally
            {
                TryDelete(temporary);
            }
            var stored = Read(path);
            var readBack = stored is not null && stored.AsSpan().SequenceEqual(next.Document);
            if (!readBack)
            {
                log.Warning("Bibliothèque de requêtes : la relecture du fichier diffère du document écrit.");
            }
            return new QueryStoreWrite(true, readBack);
        }
        finally
        {
            machineLock.ReleaseMutex();
        }
    }

    private bool Acquire(Mutex machineLock)
    {
        try
        {
            return machineLock.WaitOne(LockTimeout);
        }
        catch (AbandonedMutexException)
        {
            // The previous holder ended without releasing it: the lock is ours, its write was atomic.
            log.Warning("Verrou de la bibliothèque de requêtes abandonné par une autre instance : repris.");
            return true;
        }
    }

    private static string LockName(string path)
    {
        var full = Path.GetFullPath(path).ToUpperInvariant();
        return @"Global\Domenia.Requetes." + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(full)))[..32];
    }

    private void KeepAside(string path)
    {
        var aside = path + ".illisible-" + DateTime.UtcNow.ToString("yyyyMMdd'-'HHmmss", CultureInfo.InvariantCulture);
        try
        {
            File.Copy(path, aside, overwrite: false);
            log.Warning($"Bibliothèque de requêtes illisible mise de côté : {Path.GetFileName(aside)}.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Never replaced unsaved: the write stops, the unreadable document stays as it is.
            log.Warning($"Bibliothèque de requêtes illisible non mise de côté ({ex.GetType().Name}) : elle n’est pas remplacée.");
            throw;
        }
    }

    private void TryDelete(string file)
    {
        try
        {
            if (File.Exists(file))
            {
                File.Delete(file);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Fichier temporaire de la bibliothèque non supprimé ({ex.GetType().Name}).");
        }
    }
}
