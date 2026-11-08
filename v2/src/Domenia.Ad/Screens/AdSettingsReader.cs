using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Settings use the actual configured database; inspection never creates it.</summary>
public sealed class AdSettingsReader(AdDirectorySource source) : ISettingsReader, ISettingsStorageLocation
{
    public async Task<LocalStorageLocation> LocationAsync(CancellationToken cancellationToken)
    {
        var epoch = source.Epoch;
        var result = source.LocalStore is ILocalStorageLocation location ? await location.LocationAsync(cancellationToken).ConfigureAwait(false)
            : new LocalStorageLocation(null, "Non déterminé", "Indisponible", "Ce stockage ne fournit pas d’emplacement vérifiable.");
        cancellationToken.ThrowIfCancellationRequested();
        if (source.Epoch != epoch) throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Session ou base modifiée ; relisez son emplacement.");
        var previous = Volatile.Read(ref lastInspection);
        // Only the inspected source may be announced. Do not read legacy tables or invent a folder to draw this page.
        var legacy = previous is { } inspected && inspected.Epoch == epoch && inspected.Snapshot.PathLabel.Equals(result.Path, StringComparison.OrdinalIgnoreCase)
            ? inspected.Snapshot.Legacy : null;
        return result with
        {
            LegacyLocation = legacy is { Found: true, ReadProblem: null } && !string.IsNullOrWhiteSpace(legacy.Location) ? legacy.Location : null,
            LegacyReason = legacy is { ReadProblem: not null } ? "Dernière lecture des anciennes données en échec ; aucun emplacement confirmé."
                : legacy is { Found: false } ? "Aucune ancienne donnée trouvée lors de la dernière consultation locale."
                : "Emplacement non déterminé ; il sera confirmé par la consultation locale des anciennes données.",
        };
    }
    private sealed record Inspection(long Epoch, LocalStoreSnapshot Snapshot);
    private Inspection? lastInspection;
    private ILocalStoreInspection Store => source.LocalStore as ILocalStoreInspection
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Inspection de la base locale indisponible pour ce stockage.");

    private async Task<LocalStoreSnapshot> Inspect(bool measure, bool integrity, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var epoch = source.Epoch;
        if (source.MaintenanceRequested)
        {
            if (measure || integrity) throw new DomeniaOperationException("settings.diagnosticBusy", "Maintenance en cours : relancez le diagnostic après sa fin.");
            // Maintenance itself increments the epoch before the replacement and keeps the store locked.
            // Display its prior snapshot with the current job flags; never re-enter that locked store.
            // LocationAsync separately requires the exact epoch before exposing legacy provenance.
            if (Volatile.Read(ref lastInspection) is { } previous) return source.WithMaintenanceState(previous.Snapshot);
        }
        var current = await Store.InspectLocalStoreAsync(measure, integrity, token).ConfigureAwait(false);
        if (source.Epoch != epoch) throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Session ou base modifiée ; relisez son état.");
        Volatile.Write(ref lastInspection, new(epoch, current));
        return source.WithMaintenanceState(current);
    }
    public Task<LocalStoreSnapshot> LocalStoreAsync(CancellationToken cancellationToken) => Inspect(false, false, cancellationToken);
    public Task<LocalStoreSnapshot> MeasureAsync(CancellationToken cancellationToken) => Inspect(true, false, cancellationToken);
    public Task<LocalStoreSnapshot> CheckIntegrityAsync(CancellationToken cancellationToken) => Inspect(false, true, cancellationToken);
    public Task<SimulationFacts?> SimulationAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<SimulationFacts?>(null);
    }
}
