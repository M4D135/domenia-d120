namespace Domenia.Core;

/// <summary>Selected location, not a guessed template and not a claim that the next write will succeed.</summary>
public sealed record LocalStorageLocation(string? Path, string Mode, string State, string? Reason)
{
    public string? LegacyLocation { get; init; }
    public string? LegacyReason { get; init; }
}

public interface ILocalStorageLocation
{
    Task<LocalStorageLocation> LocationAsync(CancellationToken cancellationToken);
}

public interface ISettingsStorageLocation
{
    Task<LocalStorageLocation> LocationAsync(CancellationToken cancellationToken);
}
