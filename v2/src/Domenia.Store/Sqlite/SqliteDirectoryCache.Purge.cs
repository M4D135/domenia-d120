using Domenia.Core;

namespace Domenia.Store;

public sealed partial class SqliteDirectoryCache : ILocalStoragePurge
{
    public Task<WritePlanDraft> PrepareStoragePurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string previewFingerprint, CancellationToken cancellationToken) =>
        Database.PrepareStoragePurgeAsync(categories, historyDays, previewFingerprint, cancellationToken);
    public Task<WritePrecheck> CheckStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        Database.CheckStoragePurgeAsync(plan, cancellationToken);
    public Task<WriteOutcome> ApplyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        Database.ApplyStoragePurgeAsync(plan, cancellationToken);
    public Task<WriteVerification> VerifyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        Database.VerifyStoragePurgeAsync(plan, cancellationToken);
}
