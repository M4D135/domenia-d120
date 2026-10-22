namespace Domenia.Core;

/// <summary>Durable local projection. A read never creates a base or reaches the network.</summary>
public interface IDirectoryCache
{
    Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken);
    Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken);
}

/// <summary>A verified local backup made before the directory object read.</summary>
public sealed record DirectoryBackupReceipt(string StoreId, string Sha256, DateTimeOffset At);

public interface IPreparedDirectoryCache : IDirectoryCache
{
    Task<DirectoryBackupReceipt> PrepareAsync(CancellationToken cancellationToken);
}

/// <summary>Capability checked while planning; preparation itself runs only after confirmation.</summary>
public interface IDirectoryRefreshPreparation
{
    bool CanPrepareDirectoryRefresh { get; }
    Task<DirectoryBackupReceipt> PrepareDirectoryRefreshAsync(CancellationToken cancellationToken);
}

/// <summary>Partial object reads never replace a census checkpoint or remove unseen identities.</summary>
public interface IObjectDirectoryCache : IDirectoryCache
{
    Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken cancellationToken);
    Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken cancellationToken);
}

public interface ILegacySearchCache
{
    Task<System.Collections.Immutable.ImmutableArray<SearchLegacySaved>> ReadLegacySearchesAsync(CancellationToken cancellationToken);
}
