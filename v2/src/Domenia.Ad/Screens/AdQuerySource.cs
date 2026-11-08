using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource : IQueryLocalSource
{
    public IQueryLibraryStore? QueryLibraryStore => LocalStore is IQueryLibraryStore store ? new SessionQueryStore(this, store) : null;

    private sealed class SessionQueryStore(AdDirectorySource source, IQueryLibraryStore store) : IQueryLibraryStore
    {
        public bool Persistent => store.Persistent;
        public Task<string?> ReadLegacyAsync(string key, CancellationToken token) => Reserved(t => store.ReadLegacyAsync(key, t), token);
        public Task<byte[]?> ReadAsync(string key, CancellationToken token) => Reserved(t => store.ReadAsync(key, t), token);
        public Task<byte[]?> ReadReferenceAsync(string key, CancellationToken token) => Reserved(t => store.ReadReferenceAsync(key, t), token);
        public Task<QueryStoreWrite?> UpdateAsync(string key, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken token) =>
            Reserved(t => store.UpdateAsync(key, update, t), token, writing: true);

        private async Task<T> Reserved<T>(Func<CancellationToken, Task<T>> action, CancellationToken token, bool writing = false)
        {
            SessionSnapshot expected;
            lock (source.gate) expected = source.SessionSnapshotLocked();
            using var lease = source.AcquireWriteLease(expected);
            // Maintenance drains this same gate. An already admitted write finishes before a switch/copy;
            // one waiting behind a newly requested maintenance is refused rather than replayed afterwards.
            await source.savingFleet.WaitAsync(token).ConfigureAwait(false);
            try
            {
                lock (source.gate)
                {
                    if (source.localMaintenanceRequested || source.localMaintenance || source.epoch != expected.Epoch)
                        throw new DomeniaOperationException("storage.busy", "Maintenance locale en cours : bibliothèque différée, brouillon conservé. Relisez après sa fin.");
                }
                if (writing) await source.RequireWritableLocalStoreAsync(token).ConfigureAwait(false);
                return await action(token).ConfigureAwait(false);
            }
            finally { source.savingFleet.Release(); }
        }
    }
}
