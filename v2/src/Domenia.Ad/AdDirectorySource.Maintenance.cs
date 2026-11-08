using Domenia.Core;
using Domenia.Core.Accueil;
using System.Diagnostics;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    private bool localMaintenance;
    private bool localMaintenanceRequested;
    private bool localMaintenanceDraining;
    private string? localMaintenanceJob;
    internal TimeSpan MaintenanceDrainBudget { get; set; } = TimeSpan.FromSeconds(120);
    internal bool MaintenanceRequested { get { lock (gate) return localMaintenanceRequested || localMaintenance; } }

    internal LocalStoreSnapshot WithMaintenanceState(LocalStoreSnapshot snapshot)
    {
        lock (gate) return snapshot with { Maintenance = snapshot.Maintenance with
            { Draining = snapshot.Maintenance.Draining || localMaintenanceDraining, Job = localMaintenanceJob ?? snapshot.Maintenance.Job } };
    }

    internal async Task RequireWritableLocalStoreAsync(CancellationToken token)
    {
        if (LocalStore is not ILocalStoreInspection inspection) return;
        var snapshot = WithMaintenanceState(await inspection.InspectLocalStoreAsync(false, false, token).ConfigureAwait(false));
        StorageWritePlans.EnsureWritable(snapshot);
        if (snapshot.Maintenance.Locked || snapshot.Writer.Unavailable || snapshot.Writer.Suspended)
            throw new DomeniaOperationException("storage.busy", "Stockage en maintenance ou en échec : aucune modification préparée. Consultez les données locales avant de réessayer.");
    }

    /// <summary>Serializes destructive local storage work with publication and replaces every cached projection afterwards.</summary>
    internal Task<T> RunLocalMaintenanceAsync<T>(Func<CancellationToken, Task<T>> mutation, CancellationToken cancellationToken, long? expectedEpoch = null)
        => RunLocalMaintenanceCoreAsync((_, token) => mutation(token), cancellationToken, expectedEpoch, null);

    /// <summary>A backup reserves storage without invalidating readings already in flight: it never replaces the base.</summary>
    internal Task<T> RunLocalCopyAsync<T>(Func<CancellationToken, Task<T>> copy, CancellationToken token)
        => RunLocalMaintenanceCoreAsync((_, current) => copy(current), token, null, null, invalidate: false);

    internal Task<T> RunQualifiedLocalMaintenanceAsync<T>(WritePlanOrigin origin,
        Func<Action, CancellationToken, Task<T>> mutation, CancellationToken cancellationToken)
        => RunLocalMaintenanceCoreAsync(mutation, cancellationToken, origin.Epoch, origin);

    /// <summary>Only an explicitly confirmed writer-resume plan can inspect/release retained batches under the same reservation.</summary>
    internal Task<T> RunLocalWriterResumeAsync<T>(Func<CancellationToken, Task<T>> resume, CancellationToken token)
        => RunLocalMaintenanceCoreAsync((_, current) => resume(current), token, null, null, allowRetained: true);

    private async Task<T> RunLocalMaintenanceCoreAsync<T>(Func<Action, CancellationToken, Task<T>> mutation,
        CancellationToken cancellationToken, long? expectedEpoch, WritePlanOrigin? origin, bool invalidate = true, bool allowRetained = false)
    {
        ArgumentNullException.ThrowIfNull(mutation);
        if (LocalStore is null) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Stockage local indisponible."); }
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (localMaintenanceRequested || localMaintenance)
                throw new DomeniaOperationException("storage.busy", "Une maintenance est déjà demandée ; aucun second geste engagé.");
            localMaintenanceRequested = true; localMaintenanceDraining = true; writeLeases++;
        }
        var started = Stopwatch.GetTimestamp();
        var budget = TimeSpan.FromMilliseconds(Math.Clamp(MaintenanceDrainBudget.TotalMilliseconds, 1, 120000));
        var reservations = new List<SemaphoreSlim>();
        // Refresh may itself save fleet data: never acquire savingFleet ahead of refreshing.
        try
        {
            foreach (var semaphore in new[] { refreshing, loadingLocal, savingFleet })
            {
                var remaining = budget - Stopwatch.GetElapsedTime(started);
                if (remaining <= TimeSpan.Zero || !await semaphore.WaitAsync(remaining, cancellationToken).ConfigureAwait(false))
                    throw new DomeniaOperationException("storage.busy", "La file n’a pas terminé dans le délai de 120 s : aucune maintenance effectuée, résultats conservés. Relancez après la fin des enregistrements.");
                reservations.Add(semaphore);
            }
            if (!allowRetained && LocalStore is ICollectionStorage storage)
            {
                var pendingBytes = await storage.PendingStorageBytesAsync(cancellationToken).ConfigureAwait(false);
                if (pendingBytes > 0)
                    throw new DomeniaOperationException("storage.busy", "Des résultats restent en attente d’enregistrement : aucune maintenance ni reprise automatique. Consultez l’écrivain local.");
            }
            long generation;
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (expectedEpoch is { } expected && epoch != expected)
                { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant l’attente de maintenance ; aucune mutation locale."); }
                if (origin is not null && !origin.Matches(SessionSnapshotLocked()))
                { throw WriteErrors.Refusal(WriteErrors.Stale, "Identité de session modifiée avant la maintenance ; aucune publication."); }
                localMaintenance = true; localMaintenanceDraining = false; localMaintenanceJob = invalidate ? "Maintenance locale" : "Copie de sauvegarde";
                generation = invalidate ? ++epoch : epoch;
                if (invalidate) { localLoaded = false; state = null; fleet = CachedFleet.Empty("session"); }
            }
            void ValidateReservedSource()
            {
                lock (gate)
                {
                    ObjectDisposedException.ThrowIf(disposed, this);
                    if (!localMaintenance || epoch != generation)
                    { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la maintenance ; publication refusée."); }
                }
            }
            ValidateReservedSource();
            var result = await mutation(ValidateReservedSource, cancellationToken).ConfigureAwait(false);
            if (!invalidate) return result;
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
                    state = Empty(domain ?? directory.Domain) with
                    { Directory = domain is null ? directory : directory with { Domain = domain }, Observations = readings.Observations };
                else if (domain is not null) state = Empty(domain) with { Observations = readings.Observations };
                localLoaded = true;
            }
            return result;
        }
        finally
        {
            for (var n = reservations.Count - 1; n >= 0; n--) reservations[n].Release();
            lock (gate) { localMaintenance = false; localMaintenanceRequested = false; localMaintenanceDraining = false; localMaintenanceJob = null; writeLeases--; }
        }
    }
}
