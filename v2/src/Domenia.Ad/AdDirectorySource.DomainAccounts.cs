using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    private async Task<DirectoryState> RefreshDomainAccountsAsync(CancellationToken token)
    {
        _ = await DomainAsync(token).ConfigureAwait(false);
        DomainInfo known;
        long generation;
        lock (gate)
        {
            known = domain ?? throw new DomeniaOperationException(AdErrors.NotConnected, "Session non connectée.");
            generation = epoch;
        }
        await LoadLocalAsync(token).ConfigureAwait(false);
        await refreshing.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant l’attente de la lecture des comptes."); }
            if (LocalStore is not null && LocalStore is not IDomainAccountCache)
            { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Cette base locale ne peut pas conserver les compteurs du domaine."); }
            if (CanPrepareDirectoryRefresh) { await PrepareDirectoryRefreshAsync(token).ConfigureAwait(false); }
            if (Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée avant la lecture des comptes."); }
            var measure = await AdDirectoryReader.ReadDomainAccountsAsync(Connection, known, MaxObjectsPerKind, Clock, token).ConfigureAwait(false);
            if (Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture des comptes."); }
            if (LocalStore is IDomainAccountCache cache)
            { measure = await cache.SaveDomainAccountsAsync(measure, token).ConfigureAwait(false); }
            lock (gate)
            {
                if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée avant la publication des compteurs."); }
                return state = (state ?? Empty(known)) with { DomainAccounts = measure };
            }
        }
        finally { refreshing.Release(); }
    }
}
