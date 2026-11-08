using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FilePreferenceStore
{
    public async Task<JsonElement?> ReadLatestAsync(string key, CancellationToken token)
    {
        PreferenceKeys.Require(key);
        await writeGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                lock (gate)
                {
                    var current = ReadForImport(token);
                    token.ThrowIfCancellationRequested();
                    disk = current;
                    unavailableTraced = false;
                    if (pending.TryGetValue(key, out var change)) return change.Value?.Clone();
                    return current.TryGetValue(key, out var value) ? (JsonElement?)value.Clone() : null;
                }
            }, token).ConfigureAwait(false);
        }
        finally { writeGate.Release(); }
    }

    public async Task<JsonElement?> UpdateAsync(string key, Func<JsonElement?, JsonElement?> update, CancellationToken token)
    {
        PreferenceKeys.Require(key);
        ArgumentNullException.ThrowIfNull(update);
        await writeGate.WaitAsync(token).ConfigureAwait(false);
        try { return await Task.Run(() => UpdateLatest(key, update, token), token).ConfigureAwait(false); }
        finally { writeGate.Release(); }
    }

    private JsonElement? UpdateLatest(string key, Func<JsonElement?, JsonElement?> update, CancellationToken token)
    {
        using var mutex = new Mutex(false, lockName);
        var acquired = false;
        try
        {
            try
            {
                acquired = WaitHandle.WaitAny([mutex, token.WaitHandle], LockTimeout) == 0;
                if (!acquired) { token.ThrowIfCancellationRequested(); throw new IOException("Préférences occupées ; disposition non modifiée."); }
            }
            catch (AbandonedMutexException) { acquired = true; }
            token.ThrowIfCancellationRequested();
            var merged = ReadForImport(token); // Strict, bounded; never replace an unknown/unreadable document with defaults.
            lock (gate)
            {
                if (pending.ContainsKey(key)) throw new IOException("Un choix local attend son enregistrement ; disposition conservée.");
                var next = update(merged.TryGetValue(key, out var current) ? current.Clone() : null)?.Clone();
                token.ThrowIfCancellationRequested();
                if (next?.GetRawText() == (merged.TryGetValue(key, out var previous) ? previous.GetRawText() : null))
                {
                    disk = merged;
                    unavailableTraced = false;
                    return next;
                }
                if (next is { } value) merged[key] = value;
                else merged.Remove(key);
                var bytes = Serialize(merged);
                if (bytes.Length > MaxBytes) throw new InvalidDataException("Préférences trop volumineuses ; disposition conservée.");
                Write(bytes, token);
                disk = merged;
                unavailableTraced = false;
                // Unrelated pending choices remain pending, and keep their usual precedence over disk.
                return next;
            }
        }
        finally { if (acquired) mutex.ReleaseMutex(); }
    }
}
