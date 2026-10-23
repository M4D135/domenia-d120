using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Native exact purge counts; history ages are measured independently for each table.</summary>
public sealed record LocalStorePurgeTarget(string Category, string Table, string Action, string Label, long Rows, ImmutableArray<int> DayCounts);

public interface ILocalStoragePurge
{
    Task<WritePlanDraft> PrepareStoragePurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string previewFingerprint, CancellationToken cancellationToken);
    Task<WritePrecheck> CheckStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteOutcome> ApplyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken);
    Task<WriteVerification> VerifyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken);
}
