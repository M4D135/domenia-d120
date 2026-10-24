using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FilePreferenceStore
{
    /// <summary>Imports a missing choice and its evidence together. No optimistic memory update: refusal or failure changes neither.</summary>
    public async Task<bool> TryAddWithEvidenceAsync(string key, JsonElement value, string evidenceKey, JsonElement evidence, CancellationToken token)
    {
        PreferenceKeys.Require(key);
        PreferenceKeys.Require(evidenceKey);
        if (key == evidenceKey) { throw new ArgumentException("Les clés de préférence et de provenance doivent être distinctes."); }
        token.ThrowIfCancellationRequested();
        var incoming = value.Clone();
        var proof = evidence.Clone();
        await writeGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() => ImportIfAbsent(key, incoming, evidenceKey, proof, token), token).ConfigureAwait(false);
        }
        finally { writeGate.Release(); }
    }

    private bool ImportIfAbsent(string key, JsonElement value, string evidenceKey, JsonElement evidence, CancellationToken token)
    {
        using var machineLock = new Mutex(false, lockName);
        var acquired = false;
        try
        {
            try
            {
                var result = WaitHandle.WaitAny([machineLock, token.WaitHandle], LockTimeout);
                acquired = result == 0;
                if (!acquired) { token.ThrowIfCancellationRequested(); throw new IOException("Préférences occupées par une autre instance ; migration non appliquée."); }
            }
            catch (AbandonedMutexException) { acquired = true; }
            token.ThrowIfCancellationRequested();
            var merged = ReadForImport(token);
            lock (gate)
            {
                // A pending change (even a removal) is an explicit D2 choice. Another process's latest value wins too.
                if (pending.ContainsKey(key) || pending.ContainsKey(evidenceKey) || merged.ContainsKey(key) || merged.ContainsKey(evidenceKey))
                {
                    disk = merged;
                    return false;
                }
                merged.Add(key, value);
                merged.Add(evidenceKey, evidence);
                var bytes = Serialize(merged);
                if (bytes.Length > MaxBytes) { throw new InvalidDataException("Préférences D2 trop volumineuses après migration ; aucun changement."); }
                token.ThrowIfCancellationRequested();
                Write(bytes, token);
                disk = merged;
                unavailableTraced = false;
            }
            token.ThrowIfCancellationRequested();
            return true;
        }
        finally { if (acquired) { machineLock.ReleaseMutex(); } }
    }

    private Dictionary<string, JsonElement> ReadForImport(CancellationToken token)
    {
        var result = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        var bytes = LegacyBoardLayoutFile.ReadBounded(path, MaxBytes, token);
        if (bytes is null) { return result; }
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 3
            || root.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() != 3
            || !root.TryGetProperty("format", out var format) || format.ValueKind != JsonValueKind.String || format.GetString() != Format
            || !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != Version
            || !root.TryGetProperty("values", out var values) || values.ValueKind != JsonValueKind.Object)
        { throw new InvalidDataException("Préférences D2 incompatibles ; document conservé, migration refusée."); }
        foreach (var property in values.EnumerateObject())
        {
            token.ThrowIfCancellationRequested();
            if (!PreferenceKeys.IsValid(property.Name) || !result.TryAdd(property.Name, property.Value.Clone()))
            { throw new InvalidDataException("Préférences D2 ambiguës ; document conservé, migration refusée."); }
        }
        return result;
    }
}
