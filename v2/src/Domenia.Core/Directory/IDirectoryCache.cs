namespace Domenia.Core;

/// <summary>Durable local projection. A read never creates a base or reaches the network.</summary>
public interface IDirectoryCache
{
    Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken);
    Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken);
}

/// <summary>The receipt actually reread after the local transaction, with the submitted census identity.
/// A complete in-memory directory alone is never evidence of a committed batch.</summary>
public sealed record DirectoryStorageReceipt(string StoreId, string DomainDn, ScopeSelection Scope,
    DateTimeOffset ReadAt, bool Complete, string BatchId, string Sha256, long Revision, int Items, DateTimeOffset CommittedAt)
{
    public bool Matches(string storeId, string domainDn, ScopeSelection scope, DirectorySnapshot snapshot, DateTimeOffset now) =>
        Complete && snapshot.Complete && MatchesWrite(storeId, domainDn, scope, snapshot, now);

    /// <summary>Validates a stored partial or complete batch without promoting a partial read to a census.</summary>
    public bool MatchesWrite(string storeId, string domainDn, ScopeSelection scope, DirectorySnapshot snapshot, DateTimeOffset now)
    {
        try
        {
            return !string.IsNullOrWhiteSpace(StoreId) && StoreId == storeId
                && DistinguishedName.AreEqual(DomainDn, domainDn) && DistinguishedName.AreEqual(snapshot.Domain.RootDn, domainDn)
                && ScopeRules.SameScope(Scope, scope) && (snapshot.Coverage is null || ScopeRules.SameScope(snapshot.Coverage, scope))
                && (DistinguishedName.AreEqual(scope.Dn, domainDn) || ScopeRules.Contains(new(domainDn, "", true), scope.Dn))
                && ReadAt != DateTimeOffset.MinValue && ReadAt == snapshot.ReadAt && ReadAt <= now.AddMinutes(2)
                && Complete == snapshot.Complete && Revision > 0 && Items == snapshot.ObjectCount
                && Guid.TryParseExact(BatchId, "D", out var id) && id != Guid.Empty && Sha256 is { Length: 64 } && Sha256.All(char.IsAsciiHexDigit)
                && CommittedAt != DateTimeOffset.MinValue && CommittedAt <= now.AddMinutes(2)
                // Keep the actual timestamp. The same two-minute clock skew as Store also admits second-precision providers.
                && ReadAt - CommittedAt <= TimeSpan.FromMinutes(2);
        }
        catch (FormatException) { return false; }
    }
}

public interface IReceiptedDirectoryCache : IDirectoryCache
{
    Task<DirectoryStorageReceipt> SaveWithReceiptAsync(DirectorySnapshot snapshot, ScopeSelection scope,
        string? controller, CancellationToken cancellationToken);
}

public sealed record DirectoryRefreshCommit(DirectoryStorageReceipt Receipt, long SessionEpoch);

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
    Task<System.Text.Json.JsonElement?> ReadLegacyWorkspacesAsync(CancellationToken cancellationToken) => Task.FromResult<System.Text.Json.JsonElement?>(null);
}

/// <summary>Reads the submitted identities from the committed store, never from the LDAP response or staging file.</summary>
public interface IReadBackDirectoryCache : IReceiptedDirectoryCache
{
    Task<DirectorySnapshot> ReadStoredAsync(DirectorySnapshot submitted, DirectoryStorageReceipt receipt, CancellationToken token);
}
