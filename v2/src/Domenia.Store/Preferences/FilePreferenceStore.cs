using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Local preferences in one JSON document of the user data folder: %LOCALAPPDATA%\Domenia\preferences.json, or
/// preferences-simulation.json in simulation (never shared with the directory mode). Operation class LocalWrite: the
/// directory is never written.
/// <para>
/// Reads: the document is read at the first use (off the UI thread) and kept; a read that fails (file locked by an
/// antivirus or a backup, access denied) is not kept, so the next use reads again. Writes: each change is kept in memory
/// first (it holds for the session whatever the disk says), then, under a lock shared by every Domenia process of the
/// machine, the document is read again, this session's changes are applied to it and it is replaced atomically
/// (temporary file of the same folder, flushed, then moved over the document). Two instances therefore never erase each
/// other's values, and a document that cannot be read is never replaced: the write fails (IOException), the changes stay
/// pending for the next write. A document that is unreadable for good (bad JSON, unknown format, too large) never blocks
/// anything: it is traced, its values are ignored and it is kept aside (« .illisible ») before being replaced.
/// </para>
/// </summary>
public sealed class FilePreferenceStore : IPreferenceStore, IDisposable
{
    public const string DirectoryFileName = "preferences.json";
    public const string SimulationFileName = "preferences-simulation.json";
    public const string Format = "domenia.preferences";
    public const int Version = 1;

    /// <summary>Larger documents are not read (and not overwritten before being kept aside).</summary>
    public const int MaxBytes = 1_048_576;

    /// <summary>Longest wait for the lock held by another instance writing the same document.</summary>
    public static readonly TimeSpan LockTimeout = TimeSpan.FromSeconds(5);

    private static readonly JsonWriterOptions WriterOptions = new() { Indented = true };

    private readonly string path;
    private readonly string lockName;
    private readonly ITechnicalJournal log;
    private readonly Lock gate = new();
    private readonly SemaphoreSlim writeGate = new(1, 1);
    // Changes of this session not yet on disk (null value: removal). The version tells a change made during a write
    // from the one that was written.
    private readonly Dictionary<string, PendingChange> pending = new(StringComparer.Ordinal);
    // Last document read or written by this instance; null until a read succeeds.
    private Dictionary<string, JsonElement>? disk;
    private long changes;
    private bool unavailableTraced;

    public FilePreferenceStore(string path, ITechnicalJournal log)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(log);
        if (!Path.IsPathFullyQualified(path))
        {
            // Never relative to the current folder, which may be the share or key the pack runs from.
            throw new ArgumentException("The preferences path must be absolute.", nameof(path));
        }
        this.path = path;
        this.log = log;
        lockName = LockNameFor(path);
    }

    /// <summary>File name of the mode: the simulation never reads nor writes the preferences of the directory mode.</summary>
    public static string FileNameFor(AppMode mode) => mode == AppMode.Simulation ? SimulationFileName : DirectoryFileName;

    /// <summary>
    /// Name of the machine-wide lock of a document: every session and every instance writing the same file shares it.
    /// Hash of the full path, case ignored (NTFS), so the name holds no user data.
    /// </summary>
    public static string LockNameFor(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        var full = Path.GetFullPath(path).ToUpperInvariant();
        return @"Global\Domenia.Preferences." + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(full)))[..32];
    }

    public bool Persistent => true;

    public bool TryGet(string key, out JsonElement value)
    {
        PreferenceKeys.Require(key);
        lock (gate)
        {
            if (pending.TryGetValue(key, out var change))
            {
                value = change.Value.GetValueOrDefault();
                return change.Value.HasValue;
            }
            if (LoadLocked() is { } loaded && loaded.TryGetValue(key, out value))
            {
                return true;
            }
            value = default;
            return false;
        }
    }

    public async Task SetAsync(string key, JsonElement? value, CancellationToken cancellationToken)
    {
        PreferenceKeys.Require(key);
        lock (gate)
        {
            // Memory first: the value holds for the session even if the disk refuses it.
            pending[key] = new PendingChange(value?.Clone(), ++changes);
        }
        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // One thread from start to end (the machine-wide lock belongs to the thread that took it), never the caller's.
            await Task.Run(() => Persist(cancellationToken), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            writeGate.Release();
        }
    }

    public void Dispose() => writeGate.Dispose();

    /// <summary>The document as last read or written; read now if it never was. Null when it cannot be read for now.</summary>
    private Dictionary<string, JsonElement>? LoadLocked()
    {
        if (disk is not null)
        {
            return disk;
        }
        var read = Read(trace: true);
        if (read.Values is null)
        {
            // Not kept: the file may be fine and only locked for now. The next use reads it again.
            if (!unavailableTraced)
            {
                unavailableTraced = true;
                log.Warning($"Préférences {Path.GetFileName(path)} non lues ({read.Failure?.GetType().Name}) : valeurs par défaut pour l’instant ; le document sera relu avant toute écriture, jamais remplacé sans l’avoir été.");
            }
            return null;
        }
        unavailableTraced = false;
        disk = read.Values;
        return disk;
    }

    private void Persist(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var machineLock = new Mutex(initiallyOwned: false, lockName);
        if (!Acquire(machineLock))
        {
            throw new IOException("The preferences document is being written by another instance of Domenia.");
        }
        try
        {
            // Read again under the lock: what another instance wrote meanwhile is kept, only this session's changes apply.
            var current = Read(trace: false);
            if (current.Values is not { } merged)
            {
                // Locked or refused for now: never replaced unread. The changes stay pending for the next write.
                throw new IOException("The preferences document could not be read again before being written.", current.Failure);
            }
            Dictionary<string, long> written;
            lock (gate)
            {
                if (pending.Count == 0)
                {
                    // An earlier write of this session already carried every change.
                    disk = merged;
                    return;
                }
                foreach (var (key, change) in pending)
                {
                    if (change.Value is JsonElement element)
                    {
                        merged[key] = element;
                    }
                    else
                    {
                        merged.Remove(key);
                    }
                }
                written = pending.ToDictionary(p => p.Key, p => p.Value.Version, StringComparer.Ordinal);
            }
            var document = Serialize(merged);
            if (current.Unreadable)
            {
                KeepAside();
            }
            Write(document, cancellationToken);
            lock (gate)
            {
                disk = merged;
                unavailableTraced = false;
                foreach (var (key, version) in written)
                {
                    if (pending.TryGetValue(key, out var change) && change.Version == version)
                    {
                        pending.Remove(key);
                    }
                }
            }
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
            // The previous holder ended without releasing it: the lock is now ours. Its write was atomic, so the document
            // is either the old or the new one, never half of it.
            log.Warning("Verrou des préférences abandonné par une autre instance : repris.");
            return true;
        }
    }

    /// <summary>
    /// The document on disk. Values null: it cannot be read for now (locked, access denied), Failure says why. Unreadable:
    /// it can be read but not used (bad JSON, unknown format or version, too large); its values are then empty.
    /// </summary>
    private DiskRead Read(bool trace)
    {
        var empty = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        byte[] bytes;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                return new DiskRead(empty, false, null);
            }
            if (info.Length > MaxBytes)
            {
                return Unreadable(empty, "document de plus de 1 Mo", trace);
            }
            bytes = File.ReadAllBytes(path);
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        {
            // Removed between the check and the read: nothing to keep, nothing to lose.
            return new DiskRead(empty, false, null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new DiskRead(null, false, ex);
        }
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { AllowTrailingCommas = false, CommentHandling = JsonCommentHandling.Disallow });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("format", out var format) || format.ValueKind != JsonValueKind.String || format.GetString() != Format
                || !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != Version
                || !root.TryGetProperty("values", out var stored) || stored.ValueKind != JsonValueKind.Object)
            {
                return Unreadable(empty, "format ou version inconnus", trace);
            }
            foreach (var property in stored.EnumerateObject())
            {
                // Unknown but well-formed keys are kept as they are (written by a later version of a screen).
                if (PreferenceKeys.IsValid(property.Name))
                {
                    empty[property.Name] = property.Value.Clone();
                }
            }
            return new DiskRead(empty, false, null);
        }
        catch (JsonException)
        {
            // The parser message may quote the document: a fixed reason only.
            return Unreadable(empty, "JSON illisible", trace);
        }
    }

    private DiskRead Unreadable(Dictionary<string, JsonElement> empty, string reason, bool trace)
    {
        if (trace)
        {
            log.Warning($"Préférences {Path.GetFileName(path)} illisibles ({reason}) : valeurs par défaut ; le fichier sera mis de côté avant la prochaine écriture.");
        }
        return new DiskRead(empty, true, null);
    }

    /// <summary>The unreadable document is copied next to the new one before being replaced, never silently lost.</summary>
    private void KeepAside()
    {
        var aside = path + ".illisible";
        try
        {
            File.Copy(path, aside, overwrite: true);
            log.Warning($"Préférences illisibles mises de côté : {Path.GetFileName(aside)}.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Préférences illisibles non mises de côté ({ex.GetType().Name}) : elles seront remplacées.");
        }
    }

    private static byte[] Serialize(Dictionary<string, JsonElement> values)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            writer.WriteStartObject();
            writer.WriteString("format", Format);
            writer.WriteNumber("version", Version);
            writer.WriteStartObject("values");
            foreach (var (key, value) in values.OrderBy(p => p.Key, StringComparer.Ordinal))
            {
                writer.WritePropertyName(key);
                value.WriteTo(writer);
            }
            writer.WriteEndObject();
            writer.WriteEndObject();
        }
        return buffer.ToArray();
    }

    private void Write(byte[] document, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        // A name of this process: two instances never share a temporary file, even if the lock was lost.
        var temporary = $"{path}.{Environment.ProcessId}.tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(document);
                stream.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            // Same folder, same volume: the replacement is atomic, a reader sees the old or the new document, never half.
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            TryDelete(temporary);
            throw;
        }
    }

    private void TryDelete(string file)
    {
        try
        {
            File.Delete(file);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Fichier temporaire de préférences non supprimé ({ex.GetType().Name}).");
        }
    }

    private readonly record struct PendingChange(JsonElement? Value, long Version);

    private readonly record struct DiskRead(Dictionary<string, JsonElement>? Values, bool Unreadable, Exception? Failure);
}
