using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : IQueryResultsDeltaStore, IQueryLibraryStore
{
    public bool Persistent => true;
    public async Task<QueryStoredReadings> ReadQueryResultsAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadQueryResultsAsync(cancellationToken).ConfigureAwait(false);
    public async Task<QueryStoredReadings> SaveQueryResultsAsync(QueryComputerReadings readings, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveQueryResultsAsync(readings, cancellationToken).ConfigureAwait(false);
    public async Task<QueryComputerReadings> SaveQueryResultAsync(QueryComputerReadings readings, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveQueryResultAsync(readings, cancellationToken).ConfigureAwait(false);
    async Task<byte[]?> IQueryLibraryStore.ReadAsync(string rootKey, CancellationToken cancellationToken)
    {
        var current = await CacheAsync(cancellationToken).ConfigureAwait(false);
        CheckQueryStorageState(current);
        var bytes = await ((IQueryLibraryStore)current).ReadAsync(rootKey, cancellationToken).ConfigureAwait(false);
        CheckQueryStorageState(current);
        return bytes;
    }

    private void CheckQueryStorageState(SqliteDirectoryCache current)
    {
        var switching = ReadSwitchState();
        if (switching is { Stage: not ("committed" or "rolledBack") }
            || switching is not null && !string.Equals(switching.ActivePath, current.Database.Path, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Bascule de base en cours ou base active modifiée : bibliothèque différée ; relisez après la maintenance, ou rouvrez Domenia après une bascule externe.");
    }
    async Task<QueryStoreWrite?> IQueryLibraryStore.UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
    {
        var current = await CacheAsync(cancellationToken).ConfigureAwait(false);
        await loading.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ValidateLocalPath(SwitchFile);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(SwitchFile)!);
            using var fence = StorageWriteFence.Writer(SwitchFile, cancellationToken);
            CheckQueryStorageState(current);
            return await ((IQueryLibraryStore)current).UpdateAsync(rootKey, update, cancellationToken).ConfigureAwait(false);
        }
        finally { loading.Release(); }
    }

    async Task<string?> IQueryLibraryStore.ReadLegacyAsync(string rootKey, CancellationToken cancellationToken)
    {
        if (isolated) return null;
        var db = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        if (rootKey != QueryLibrary.RootKey(db.DomainDn)) throw new InvalidDataException("Ancienne bibliothèque d’un autre domaine.");
        var parent = System.IO.Path.GetDirectoryName(db.Path)!;
        var data = string.Equals(System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(parent)), "Domains", StringComparison.OrdinalIgnoreCase)
            ? System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(parent))! : parent;
        return await Task.Run(() => LegacyQueryFile.Read([
            System.IO.Path.Combine(data, "Preferences", "Domenia.settings.json"), System.IO.Path.Combine(data, "Domenia.settings.json"),
            System.IO.Path.Combine(appFolder, "Domenia.settings.json"), System.IO.Path.Combine(data, "ADCC.settings.json"),
            System.IO.Path.Combine(appFolder, "ADCC.settings.json")], cancellationToken), cancellationToken).ConfigureAwait(false);
    }
}
