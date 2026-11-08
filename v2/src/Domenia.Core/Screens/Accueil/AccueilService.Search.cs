using System.Collections.Immutable;

namespace Domenia.Core.Accueil;

internal sealed record HomeSearchSelection(string Revision, string Label, ImmutableArray<Guid> Guids, DateTimeOffset At,
    ScopeSelection Scope, string DomainDn)
{
    public string Account { get; init; } = "";
}

public sealed partial class AccueilService
{
    private sealed record BoardOwner(long Epoch, string Login, long AccountSelection, long ScopeVersion, string DomainDn, string StoreId, ScopeSelection Scope);

    private async Task<BoardOwner> BoardOwnerAsync(CancellationToken token)
    {
        var (session, scope, domain) = await ScopeAsync(token).ConfigureAwait(false);
        var selected = AccountAccess.From(context).SelectionVersion;
        var facts = await Reader.FactsAsync(token).ConfigureAwait(false);
        return new(session.Epoch, session.Account.Login, selected, workingScope.SelectionVersion, domain, facts.StoreId, scope);
    }

    internal async Task<HomeSearchSelection> SearchSelectionAsync(string revision, string key, CancellationToken token)
    {
        var owner = await BoardOwnerAsync(token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (boardComputations != 0 || latest is not { } computation || latestOwner != owner || computation.Board.Revision != revision)
                throw new DomeniaOperationException(BoardReplaced, BoardReplacedMessage);
            if (ScopeRules.IsDomainRoot(owner.Scope, owner.DomainDn))
                throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, "Choisissez une OU de travail avant d’ouvrir les postes du calcul.");
            var guids = computation.Targets.GetValueOrDefault(key);
            if (guids.IsDefault)
                guids = pivots.Values.Select(t => t.Targets.GetValueOrDefault(key)).FirstOrDefault(ids => !ids.IsDefault);
            if (guids.IsDefault) throw new DomeniaOperationException(TargetsUnknown, TargetsUnknownMessage);
            if (guids.Length > OperationsPersistence.MaxTargets)
                throw new DomeniaOperationException("targets.tooMany", "Ensemble supérieur à 100 000 postes ; choisissez une OU plus précise. Aucune liste tronquée.");
            return new(revision, computation.TargetLabels.GetValueOrDefault(key) ?? LabelOf(computation, key), guids,
                computation.Board.ComputedAt, owner.Scope, owner.DomainDn) { Account = owner.Login };
        }
    }
}
