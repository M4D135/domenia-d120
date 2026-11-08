using System.Security.Cryptography;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private int backupTimeoutSeconds = 30;
    private IConfigurationPreferenceStore? backupPreferences;
    public void ConfigureBackupPreferences(IConfigurationPreferenceStore preferences) => backupPreferences = preferences ?? throw new ArgumentNullException(nameof(preferences));
    internal Action<string>? BackupStageReached { get; set; }
    public void ConfigureBackupTimeout(int seconds) => backupTimeoutSeconds = Math.Clamp(seconds, 5, 600);

    private async Task<WriteOutcome> ApplyStorageBackupWithinBudgetAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var seconds = backupTimeoutSeconds;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds), clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            return await ObserveWriteAsync("ApplyStorageBackup", plan, false,
                ct => ApplyStorageBackupCoreAsync(plan, ct), linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new IOException($"Budget de sauvegarde dépassé ({seconds} s). La base et toute copie locale déjà vérifiée sont conservées ; aucun rejeu automatique.", ex);
        }
    }

    private void BackupStage(string stage, CancellationToken token)
    {
        BackupStageReached?.Invoke(stage);
        token.ThrowIfCancellationRequested();
    }

    private static void CopyBackupFile(string source, string target, BackupTemporaryFiles temporary, CancellationToken token)
    {
        CompatibleDirectoryCache.ValidateLocalPath(source); CompatibleDirectoryCache.ValidateLocalPath(target);
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        temporary.Add(target);
        var buffer = new byte[128 * 1024];
        int read;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            read = input.Read(buffer);
            if (read == 0) break;
            output.Write(buffer, 0, read);
        }
        output.Flush(flushToDisk: true);
        token.ThrowIfCancellationRequested();
    }

    private static void WriteBackupMetadata(string target, byte[] bytes, string planId, BackupTemporaryFiles temporary, CancellationToken token)
    {
        var staged = target + ".partial-" + planId;
        WriteNewBackupFile(staged, bytes, temporary, token);
        token.ThrowIfCancellationRequested();
        CompatibleDirectoryCache.ValidateLocalPath(target);
        File.Move(staged, target, overwrite: false);
        temporary.Forget(staged);
    }

    private static string BackupFileHash(string path, CancellationToken token = default)
    {
        CompatibleDirectoryCache.ValidateLocalPath(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[128 * 1024];
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var read = stream.Read(buffer);
            if (read == 0) break;
            hash.AppendData(buffer, 0, read);
        }
        return Convert.ToHexStringLower(hash.GetHashAndReset());
    }

    // Only paths created by this execution are eligible. A verified copy and the anti-replay intent are never removed.
    private sealed class BackupTemporaryFiles : IDisposable
    {
        private readonly HashSet<string> files = new(StringComparer.OrdinalIgnoreCase);
        internal void Add(string path) => files.Add(path);
        internal void Forget(string path) => files.Remove(path);
        public void Dispose()
        {
            var errors = new List<Exception>();
            foreach (var path in files)
            {
                foreach (var candidate in new[] { path, path + "-journal", path + "-wal", path + "-shm" })
                {
                    try { CompatibleDirectoryCache.ValidateLocalPath(candidate); File.Delete(candidate); }
                    catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or System.Security.SecurityException)
                    { errors.Add(ex); }
                }
            }
            files.Clear();
            if (errors.Count > 0) throw new IOException("Des fichiers temporaires de sauvegarde n’ont pas pu être nettoyés ; aucune copie incomplète n’est certifiée.", new AggregateException(errors));
        }
    }
}
