using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Settings use the actual configured database; inspection never creates it.</summary>
public sealed class AdSettingsReader(AdDirectorySource source) : ISettingsReader
{
    private ILocalStoreInspection Store => source.LocalStore as ILocalStoreInspection
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Inspection de la base locale indisponible pour ce stockage.");

    public Task<LocalStoreSnapshot> LocalStoreAsync(CancellationToken cancellationToken) => Store.InspectLocalStoreAsync(false, false, cancellationToken);
    public Task<LocalStoreSnapshot> MeasureAsync(CancellationToken cancellationToken) => Store.InspectLocalStoreAsync(true, false, cancellationToken);
    public Task<LocalStoreSnapshot> CheckIntegrityAsync(CancellationToken cancellationToken) => Store.InspectLocalStoreAsync(false, true, cancellationToken);
    public Task<SimulationFacts?> SimulationAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<SimulationFacts?>(null);
    }
}
