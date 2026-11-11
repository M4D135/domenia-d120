using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FilePreferenceStore
{
    public async Task<ConfigurationSnapshot> ReadConfigurationAsync(CancellationToken token)
    {
        await writeGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                PersistPendingFirst(token);
                return WithConfigurationLock(token, () => ReadConfigurationLocked(token).State);
            }, token).ConfigureAwait(false);
        }
        finally { writeGate.Release(); }
    }

    public async Task<ConfigurationApplied> CommitConfigurationAsync(ConfigurationCommit request, CancellationToken token, Func<CancellationToken, IDisposable>? qualifySource = null)
    {
        await writeGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                PersistPendingFirst(token);
                return WithConfigurationLock(token, () =>
                {
                    var original = ReadConfigurationLocked(token);
                    // Validate the complete patch before creating a backup; no failed preview creates a replacement.
                    _ = ConfigurationChanges.Apply(original.State, request, null, null);
                    using var held = qualifySource?.Invoke(token);
                    token.ThrowIfCancellationRequested();
                    string? backup = null; string? backupSha = null;
                    if (request.Document is not null && original.Bytes is { } bytes)
                    {
                        backup = "preferences.before-configuration-" + Guid.NewGuid().ToString("N") + ".json";
                        backupSha = Convert.ToHexStringLower(SHA256.HashData(bytes));
                        using var saved = new FileStream(Path.Combine(Path.GetDirectoryName(path)!, backup), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough);
                        saved.Write(bytes); saved.Flush(true);
                        saved.Position = 0;
                        if (saved.Length != bytes.Length || Convert.ToHexStringLower(SHA256.HashData(saved)) != backupSha)
                            throw new IOException("Sauvegarde de configuration non vérifiée ; original non remplacé.");
                        token.ThrowIfCancellationRequested();
                    }
                    var patch = ConfigurationChanges.Apply(original.State, request, backup, backupSha);
                    var next = Serialize(patch.Values);
                    if (next.Length > MaxBytes) throw new InvalidDataException("Configuration trop volumineuse ; original et sauvegarde conservés.");
                    Write(next, token);
                    disk = patch.Values;
                    unavailableTraced = false;
                    return patch.Result;
                });
            }, token).ConfigureAwait(false);
        }
        finally { writeGate.Release(); }
    }

    /// <summary>A choice that <see cref="SetAsync"/> has put in memory waits for the write gate this caller holds: it is written
    /// first, on this thread, so the configuration is read from a document that carries it. Bench of 11/11/2026: at startup
    /// the interface read lost that race and was refused (« Des préférences attendent leur enregistrement »), and the pack's
    /// configuration was not proposed. A write that fails keeps the choice pending, is recorded, and the read still refuses.</summary>
    private void PersistPendingFirst(CancellationToken token)
    {
        bool waiting;
        lock (gate) { waiting = pending.Count != 0; }
        if (!waiting) { return; }
        try { Persist(token); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException) { RememberWriteFailure(ex); }
    }

    private (ConfigurationSnapshot State, byte[]? Bytes) ReadConfigurationLocked(CancellationToken token)
    {
        // The mutex and gate are held. Reject pending writes rather than silently choosing a disk-only configuration.
        if (pending.Count != 0) throw new IOException("Des préférences attendent leur enregistrement ; reprenez l’aperçu ensuite.");
        var bytes = LegacyBoardLayoutFile.ReadBounded(path, MaxBytes, token);
        var current = bytes is null ? new Dictionary<string, JsonElement>(StringComparer.Ordinal) : ParseForImport(bytes, token);
        var fingerprint = bytes is null ? PortableConfiguration.Hash("preferences:absent") : Convert.ToHexStringLower(SHA256.HashData(bytes));
        return (new(bytes is not null, fingerprint, current.ToImmutableDictionary(StringComparer.Ordinal)), bytes);
    }

    private T WithConfigurationLock<T>(CancellationToken token, Func<T> action)
    {
        using var mutex = new Mutex(false, lockName); var acquired = false;
        try
        {
            try { acquired = WaitHandle.WaitAny([mutex, token.WaitHandle], LockTimeout) == 0; }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) { token.ThrowIfCancellationRequested(); throw new IOException("Préférences occupées ; configuration non modifiée."); }
            token.ThrowIfCancellationRequested();
            lock (gate) return action();
        }
        finally { if (acquired) mutex.ReleaseMutex(); }
    }
}
