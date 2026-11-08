using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStoreInspection, ISyncLocalStore
{
    public async Task<WriteVerification> VerifySyncChangeAsync(WritePlan plan, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).VerifySyncChangeAsync(plan, cancellationToken).ConfigureAwait(false);
    public async Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken cancellationToken)
    {
        // An invalid redirect cannot choose a database or hide the recovery explanation behind an operation error.
        try { _ = ReadSwitchState(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidDataException or ArgumentException or System.Security.SecurityException)
        { return InvalidSwitchSnapshot(ex); }
        var snapshot = await (await CacheAsync(cancellationToken).ConfigureAwait(false)).InspectLocalStoreAsync(measure, integrity, cancellationToken).ConfigureAwait(false);
        try { snapshot = WithSwitchState(snapshot); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidDataException or ArgumentException or System.Security.SecurityException)
        { return InvalidSwitchSnapshot(ex); }
        return await WithLegacySourcesAsync(snapshot, cancellationToken).ConfigureAwait(false);
    }

    private LocalStoreSnapshot InvalidSwitchSnapshot(Exception error)
    {
        var now = clock.GetUtcNow();
        var detail = "Marqueur de stockage non vérifiable (" + error.GetType().Name + ") : fichiers conservés, aucune base sélectionnée et collectes suspendues. Faites vérifier le marqueur et l’identité des copies avant toute reprise ; aucun retour ou remplacement automatique.";
        return new(false, false, SwitchDomain, "", "", 0, "Non vérifié", 0, 0, null,
            new(null, null, null, null, null, null), [], [], [], [], new(null, null, 0),
            new(true, true, false, 0, 0, 0, 0, 0, null, detail), new(true, false, null, false, false, null, false, null),
            null, new(now, 0, false, [new("open", "failed", "Aucune base ouverte."), new("redirect", "failed", detail)]), [],
            new(false, "", SwitchDomain, null, null, [], [], System.Collections.Immutable.ImmutableDictionary<string, long>.Empty, "", null, null), [], detail, now);
    }
    public async Task<SyncLocalState> ReadSyncStateAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
    public async Task<IndexSearchPage> SearchSyncIndexAsync(IndexQuery query, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SearchSyncIndexAsync(query, cancellationToken).ConfigureAwait(false);
    public async Task<WritePrecheck> CheckSyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).CheckSyncChangeAsync(change, cancellationToken).ConfigureAwait(false);
    public async Task<SyncStorageReceipt> ApplySyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ApplySyncChangeAsync(change, cancellationToken).ConfigureAwait(false);
}
