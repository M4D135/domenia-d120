namespace Domenia.Core;

/// <summary>Read-only inspection of the configured local database. No migration, repair or network access.</summary>
public interface ILocalStoreInspection
{
    Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken cancellationToken);
}
