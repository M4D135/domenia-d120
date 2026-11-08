using System.Text.Json;

namespace Domenia.Core;

/// <summary>One all-or-nothing restoration of approved preferences; unrelated values and local identity stay untouched.</summary>
public interface IBackupPreferenceStore : IConfigurationPreferenceStore
{
    Task ApplyBackupPreferencesAsync(string annex, string expectedFingerprint, CancellationToken token);
}

public sealed partial class MemoryPreferenceStore : IBackupPreferenceStore
{
    public Task ApplyBackupPreferencesAsync(string annex, string expectedFingerprint, CancellationToken token)
    {
        var approved = BackupPreferencesRules.ReadStrict(annex);
        lock (gate)
        {
            token.ThrowIfCancellationRequested();
            if (ConfigurationChanges.MemorySnapshot(values).Fingerprint != expectedFingerprint)
                throw new InvalidDataException("Préférences modifiées depuis la lecture ; aucune réapplication.");
            var next = new Dictionary<string, JsonElement>(values, StringComparer.Ordinal);
            foreach (var (key, value) in approved) next[key] = value.Clone();
            _ = PreferenceDocumentLimits.Encode(next);
            values.Clear();
            foreach (var pair in next) values.Add(pair.Key, pair.Value);
            Writes++;
        }
        return Task.CompletedTask;
    }
}
