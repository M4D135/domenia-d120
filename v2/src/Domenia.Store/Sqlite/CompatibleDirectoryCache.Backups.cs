using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStorageBackup
{
    private int backupTimeoutSeconds = 30;
    private IConfigurationPreferenceStore? backupPreferences;
    public void ConfigureBackupPreferences(IConfigurationPreferenceStore preferences)
    {
        backupPreferences = preferences ?? throw new ArgumentNullException(nameof(preferences));
        cache?.Database.ConfigureBackupPreferences(preferences);
    }
    public void ConfigureBackupTimeout(int seconds)
    {
        backupTimeoutSeconds = Math.Clamp(seconds, 5, 600);
        cache?.Database.ConfigureBackupTimeout(backupTimeoutSeconds);
    }

    public async Task<WritePlanDraft> PrepareStorageBackupAsync(StoragePolicy policy, string annex, string series, string? destination, CancellationToken cancellationToken) =>
        await (await BackupDatabaseAsync(cancellationToken).ConfigureAwait(false)).PrepareStorageBackupAsync(policy, annex, series, destination, cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await BackupDatabaseAsync(cancellationToken).ConfigureAwait(false)).CheckStorageBackupAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<WriteOutcome> ApplyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await BackupDatabaseAsync(cancellationToken).ConfigureAwait(false)).ApplyStorageBackupAsync(plan, cancellationToken).ConfigureAwait(false);
    private async Task<DomeniaDatabase> BackupDatabaseAsync(CancellationToken token)
    {
        var snapshot = await InspectLocalStoreAsync(false, false, token).ConfigureAwait(false);
        StorageWritePlans.EnsureWritable(snapshot);
        if (snapshot.Maintenance.Locked)
            throw new DomeniaOperationException(StorageWritePlans.StoreUnavailable, "Bascule à terminer : aucune nouvelle sauvegarde avant reprise ou retour explicite.");
        var database = await DatabaseAsync(token).ConfigureAwait(false);
        if (database.StoreId != snapshot.StoreId)
            throw WriteErrors.Refusal(WriteErrors.Stale, "Base modifiée pendant l’inspection ; préparez une nouvelle sauvegarde.");
        return database;
    }

    public async Task<WriteVerification> VerifyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).VerifyStorageBackupAsync(plan, cancellationToken).ConfigureAwait(false);
}
