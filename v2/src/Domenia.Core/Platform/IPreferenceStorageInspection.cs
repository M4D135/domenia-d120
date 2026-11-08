namespace Domenia.Core;

/// <summary>Observed access only. Persistence describes a backing store, never permission to replace it.</summary>
public sealed record PreferenceStorageAccess(string? Path, string State, string Reason, int PendingChanges);
public interface IPreferenceStorageInspection
{
    Task<PreferenceStorageAccess> InspectAccessAsync(CancellationToken cancellationToken);
}
