namespace Domenia.Core;

/// <summary>Current links attributable to an identity, and old name-only links that require review.</summary>
public sealed record DirectoryDeletionLinks(int Identified, int Unresolved);

/// <summary>Local cleanup only after the directory reader confirms that this GUID is absent.</summary>
public interface IDirectoryDeletionCache
{
    Task<DirectoryDeletionLinks> CountDeletionLinksAsync(WriteTarget target, CancellationToken cancellationToken);
    Task<DirectoryDeletionLinks> ApplyDeletionAsync(WriteTarget target, DateTimeOffset observedAt, CancellationToken cancellationToken);
}
