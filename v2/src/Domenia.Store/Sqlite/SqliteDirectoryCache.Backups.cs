using Domenia.Core;

namespace Domenia.Store;

public sealed partial class SqliteDirectoryCache : ILocalStorageBackup
{
    public Task<WritePlanDraft> PrepareStorageBackupAsync(StoragePolicy policy, string annex, string series, string? destination, CancellationToken cancellationToken) =>
        Database.PrepareStorageBackupAsync(policy, annex, series, destination, cancellationToken);
    public Task<WritePrecheck> CheckStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) => Database.CheckStorageBackupAsync(plan, cancellationToken);
    public Task<WriteOutcome> ApplyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) => Database.ApplyStorageBackupAsync(plan, cancellationToken);
    public Task<WriteVerification> VerifyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) => Database.VerifyStorageBackupAsync(plan, cancellationToken);
}
