using System.Security.Cryptography;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FilePreferenceStore : IBackupPreferenceStore
{
    public async Task ApplyBackupPreferencesAsync(string annex, string expectedFingerprint, CancellationToken token)
    {
        var approved = BackupPreferencesRules.ReadStrict(annex);
        await writeGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            await Task.Run(() => WithConfigurationLock(token, () =>
            {
                var original = ReadConfigurationLocked(token);
                if (original.State.Fingerprint != expectedFingerprint)
                    throw new InvalidDataException("Préférences modifiées depuis la lecture ; aucune réapplication.");
                var merged = original.State.Values.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal);
                foreach (var (key, value) in approved) merged[key] = value.Clone();
                var next = Serialize(merged);
                if (next.Length > MaxBytes) throw new InvalidDataException("Préférences restaurées trop volumineuses ; choix précédent conservé.");
                if (original.Bytes is { } bytes)
                {
                    var backup = path + ".before-restore-" + Guid.NewGuid().ToString("N") + ".bak";
                    using var saved = new FileStream(backup, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough);
                    saved.Write(bytes); saved.Flush(true); saved.Position = 0;
                    if (saved.Length != bytes.Length || !SHA256.HashData(saved).AsSpan().SequenceEqual(SHA256.HashData(bytes)))
                        throw new IOException("Copie préalable des préférences non vérifiée ; original conservé.");
                }
                token.ThrowIfCancellationRequested();
                Write(next, token);
                disk = merged;
                unavailableTraced = false;
                return true;
            }), token).ConfigureAwait(false);
        }
        finally { writeGate.Release(); }
    }
}
