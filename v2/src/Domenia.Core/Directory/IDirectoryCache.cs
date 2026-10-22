namespace Domenia.Core;

/// <summary>Durable local projection. A read never creates a base or reaches the network.</summary>
public interface IDirectoryCache
{
    Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken);
    Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken);
}
