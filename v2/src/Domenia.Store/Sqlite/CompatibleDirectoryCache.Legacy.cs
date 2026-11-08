using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStorageLegacy
{
    private string[] LegacyRoots(DomeniaDatabase database)
    {
        var parent = System.IO.Path.GetDirectoryName(database.Path)!;
        if (isolated) { return [parent]; }
        var data = string.Equals(System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(parent)), "Domains", StringComparison.OrdinalIgnoreCase)
            ? System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(parent))! : parent;
        return new[] { data, userFolder }.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }
    private async Task<LocalStoreSnapshot> WithLegacySourcesAsync(LocalStoreSnapshot snapshot, CancellationToken token)
    {
        var database = await DatabaseAsync(token).ConfigureAwait(false);
        return await database.InspectLegacySourcesAsync(snapshot, LegacyRoots(database), token).ConfigureAwait(false);
    }
    public async Task<WritePlanDraft> PrepareStorageLegacyAsync(string domain, string previewFingerprint, CancellationToken cancellationToken)
    {
        var database = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        return await database.PrepareStorageLegacyAsync(LegacyRoots(database), domain, previewFingerprint, cancellationToken).ConfigureAwait(false);
    }
    public async Task<WritePrecheck> CheckStorageLegacyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var database = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        return await database.CheckStorageLegacyAsync(LegacyRoots(database), plan, cancellationToken).ConfigureAwait(false);
    }
    public async Task<WriteOutcome> ApplyStorageLegacyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var database = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        return await database.ApplyStorageLegacyAsync(LegacyRoots(database), plan, cancellationToken).ConfigureAwait(false);
    }
    public async Task<WriteVerification> VerifyStorageLegacyAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).VerifyStorageLegacyAsync(plan, cancellationToken).ConfigureAwait(false);
}
