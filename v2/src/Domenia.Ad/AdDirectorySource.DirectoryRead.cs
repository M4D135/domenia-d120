using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    private long? reloadDirectoryAtEpoch;
    private async Task<(DirectorySnapshot Snapshot, DirectoryRefreshCommit? Commit)> ReadStoredDirectoryAsync(
        DomainInfo known, ScopeSelection scope, long generation, string readLogin, CancellationToken token)
    {
        var cache = LocalStore;
        // A campaign may already pin this exact store's verified backup. Reuse only that proof; this does not
        // grant collection rights. Standalone census reads retain their own lease through the last readback.
        using var collectionLease = cache is IOperationsLocalStore operations && !await operations.HasOperationsLeaseAsync(token).ConfigureAwait(false)
            ? await operations.AcquireOperationsLeaseAsync(token).ConfigureAwait(false) : null;
        var preparation = CanPrepareDirectoryRefresh ? await PrepareDirectoryRefreshAsync(token).ConfigureAwait(false) : null;
        void EnsureOwner()
        {
            if (Epoch != generation || !ReferenceEquals(cache, LocalStore))
                throw new DomeniaOperationException(AdErrors.NotConnected, "Session ou base modifiée pendant la lecture : publication annulée.");
        }
        EnsureOwner();
        var acknowledged = 0;
        async Task<(DirectorySnapshot Snapshot, DirectoryStorageReceipt Receipt)> Store(DirectorySnapshot submitted, CancellationToken ct)
        {
            EnsureOwner();
            var durable = (IReceiptedDirectoryCache)cache!;
            var receipt = await durable.SaveWithReceiptAsync(submitted, scope, ControllerName, ct).ConfigureAwait(false);
            EnsureOwner();
            if (!receipt.MatchesWrite(preparation?.StoreId ?? receipt.StoreId, known.RootDn, scope, submitted, Clock.GetUtcNow()))
                throw new InvalidDataException("Reçu local incohérent : le relevé n’est pas publié.");
            var stored = cache is IReadBackDirectoryCache readback
                ? await readback.ReadStoredAsync(submitted, receipt, ct).ConfigureAwait(false)
                : DirectoryReadback.Select(submitted, await cache.ReadAsync(ct).ConfigureAwait(false));
            EnsureOwner();
            return (stored, receipt);
        }
        async Task StorePage(DirectorySnapshot page, CancellationToken ct)
        {
            _ = await Store(page with { ReaderLogin = readLogin }, ct).ConfigureAwait(false);
            acknowledged++;
        }
        try
        {
            var snapshot = await AdDirectoryReader.ReadSnapshotAsync(Connection, known, scope, MaxObjectsPerKind, Clock, token,
                cache is IReadBackDirectoryCache ? StorePage : null).ConfigureAwait(false);
            EnsureOwner();
            snapshot = snapshot with { ReaderLogin = readLogin };
            if (cache is IReceiptedDirectoryCache)
            {
                var stored = await Store(snapshot, token).ConfigureAwait(false);
                if (!snapshot.Complete)
                {
                    var retained = cache is IObjectDirectoryCache objects ? await objects.ReadKnownAsync(token).ConfigureAwait(false)
                        : await cache.ReadAsync(token).ConfigureAwait(false);
                    EnsureOwner();
                    if (retained is null) throw new InvalidDataException("Projection durable absente après lecture partielle.");
                    return (DirectoryReadback.Retained(retained, scope, snapshot.ReadAt), null);
                }
                return (stored.Snapshot, new(stored.Receipt, generation));
            }
            if (cache is not null)
            {
                await cache.SaveAsync(snapshot, scope, ControllerName, token).ConfigureAwait(false);
                snapshot = DirectoryReadback.Select(snapshot, await cache.ReadAsync(token).ConfigureAwait(false));
                EnsureOwner();
            }
            // In-memory test/simulation providers do not acquire a fabricated durable receipt.
            return (snapshot, null);
        }
        catch
        {
            // A subsequent local read reloads the already acknowledged slices. Never call them a complete census,
            // never replay an interrupted page automatically, and do not replace the original failure by a reload error.
            if (acknowledged != 0) lock (gate) { if (epoch == generation) { localLoaded = false; reloadDirectoryAtEpoch = generation; } }
            throw;
        }
    }
}
