namespace Domenia.Core;

/// <summary>
/// Directory mode while Domenia.Ad is not wired: the session answers « not connected » from local facts only (join domain,
/// account of the process token); every read is refused with source.unavailable.
/// </summary>
public sealed class UnavailableDirectorySource(string? joinedDomain, Func<string> accountLogin) : IDirectorySource
{
    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;

    public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(accountLogin);
        var session = new SessionSnapshot(
            ConnectionState.Disconnected,
            joinedDomain is null ? null : new DomainIdentity(joinedDomain, null, null),
            null,
            new AccountIdentity(accountLogin(), null, null, null),
            new AuthenticationInfo(AuthenticationMethod.WindowsSession, null, "Session Windows"),
            null,
            new RightsInfo(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, "Droits évalués à la connexion à l’annuaire."),
            true,
            new StoreStatus(null, 0, false));
        return Task.FromResult(session);
    }

    public Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken) =>
        Task.FromException<DirectoryState>(new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage));

    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken) =>
        Task.FromException<DirectoryState>(new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage));
}
