using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    private bool localMaintenance;

    /// <summary>Serializes destructive local storage work with publication and replaces every cached projection afterwards.</summary>
    internal async Task<T> RunLocalMaintenanceAsync<T>(Func<CancellationToken, Task<T>> mutation, CancellationToken cancellationToken, long? expectedEpoch = null)
    {
        ArgumentNullException.ThrowIfNull(mutation);
        if (LocalStore is null) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Stockage local indisponible."); }
        // Refresh may itself save fleet data: never acquire savingFleet ahead of refreshing.
        await ReserveMaintenanceAsync(refreshing, cancellationToken).ConfigureAwait(false);
        try
        {
            await ReserveMaintenanceAsync(loadingLocal, cancellationToken).ConfigureAwait(false);
            try
            {
                await ReserveMaintenanceAsync(savingFleet, cancellationToken).ConfigureAwait(false);
                try
                {
                    long generation;
                    lock (gate)
                    {
                        ObjectDisposedException.ThrowIf(disposed, this);
                        if (expectedEpoch is { } expected && epoch != expected)
                        { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant l’attente de maintenance ; aucune mutation locale."); }
                        localMaintenance = true; writeLeases++;
                        generation = ++epoch;
                        localLoaded = false; state = null; fleet = CachedFleet.Empty("session");
                    }
                    try
                    {
                        var result = await mutation(cancellationToken).ConfigureAwait(false);
                        // Cancellation after commit must not leave the old cache visible. A failed reload leaves it invalidated.
                        using var reload = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                        var directory = LocalStore is IObjectDirectoryCache objects
                            ? await objects.ReadKnownAsync(reload.Token).ConfigureAwait(false)
                            : await LocalStore.ReadAsync(reload.Token).ConfigureAwait(false);
                        var readings = LocalStore is IAccueilCache cache
                            ? await cache.ReadFleetAsync(reload.Token).ConfigureAwait(false) : CachedFleet.Empty("session");
                        lock (gate)
                        {
                            if (disposed || epoch != generation)
                            { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la maintenance ; cache invalidé."); }
                            fleet = readings;
                            if (directory is not null)
                            {
                                state = Empty(domain ?? directory.Domain) with
                                { Directory = domain is null ? directory : directory with { Domain = domain }, Observations = readings.Observations };
                            }
                            else if (domain is not null) { state = Empty(domain) with { Observations = readings.Observations }; }
                            localLoaded = true;
                        }
                        return result;
                    }
                    finally { lock (gate) { localMaintenance = false; writeLeases--; } }
                }
                finally { savingFleet.Release(); }
            }
            finally { loadingLocal.Release(); }
        }
        finally { refreshing.Release(); }
    }

    private static async Task ReserveMaintenanceAsync(SemaphoreSlim semaphore, CancellationToken token)
    {
        if (!await semaphore.WaitAsync(TimeSpan.FromSeconds(10), token).ConfigureAwait(false))
        { throw new DomeniaOperationException("storage.busy", "Une lecture ou un enregistrement est encore en cours ; aucune maintenance effectuée."); }
    }
}
