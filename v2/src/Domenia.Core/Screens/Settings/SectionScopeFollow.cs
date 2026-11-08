using System.Collections.Immutable;
using System.Security.Cryptography;

namespace Domenia.Core;

/// <summary>Local, explicit replacement only. Reading a proposal never changes an independent scope or bookmark.</summary>
public sealed class SectionScopeFollow(EngineContext context)
{
    private sealed record Proposal(SessionSnapshot Session, ScopeSelection Working, long WorkingVersion, AccountsScope Accounts,
        long AccountsVersion, DateTimeOffset Expires);
    private readonly Lock gate = new();
    private readonly Dictionary<string, Proposal> proposals = new(StringComparer.Ordinal);
    public static SectionScopeFollow From(EngineContext context) => context.Shared(static c => new SectionScopeFollow(c));

    public async Task<ImmutableArray<SectionScopeView>> SectionsAsync(SessionSnapshot session, ScopeSelection? scope, CancellationToken token)
    {
        var sections = SettingsViewRules.Sections(scope);
        var accounts = AccountsSectionScope.From(context);
        var own = await accounts.CurrentAsync(session, token).ConfigureAwait(false);
        var follows = own?.Origin != AccountsScopeOrigin.Section;
        var allowed = !follows && scope is not null && session.Domain?.RootDn is { } root && !ScopeRules.IsDomainRoot(scope, root)
            && context.Readers.Find<IOrganizationalUnitIndex>() is { } index && await index.FindLocalAsync(scope.Dn, token).ConfigureAwait(false) is not null;
        string? id = null;
        if (allowed && own is not null && scope is not null)
        {
            var work = WorkingScope.From(context);
            var proposal = new Proposal(session, scope, work.SelectionVersion, own, accounts.SelectionVersion, context.Clock.GetUtcNow().AddMinutes(10));
            id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
            lock (gate)
            {
                foreach (var expired in proposals.Where(p => p.Value.Expires < context.Clock.GetUtcNow()).Select(p => p.Key).ToArray()) proposals.Remove(expired);
                while (proposals.Count >= 32) proposals.Remove(proposals.First().Key);
                proposals[id] = proposal;
            }
        }
        return sections.Add(new("accounts", "Comptes", follows, own?.Label ?? "Aucune OU admise",
            follows ? "Suit l’OU de travail ; la lecture de tout le domaine reste refusée."
                : allowed ? "OU propre conservée. La remplacer par l’OU de travail exige votre confirmation."
                    : "OU propre conservée : choisissez une OU de travail valide, distincte de tout le domaine, avant de proposer son remplacement.")
        { CanFollow = allowed, FollowToken = id, ScopeDn = own?.Dn, Subtree = own?.Subtree ?? false });
    }

    public async Task FollowAsync(string section, string id, bool confirmed, CancellationToken token)
    {
        if (section != "accounts" || !confirmed) throw new DomeniaOperationException("scope.confirmationRequired", "Confirmez explicitement le remplacement ; l’OU propre est conservée.");
        Proposal? proposal;
        lock (gate) proposals.Remove(id, out proposal);
        if (proposal is null || proposal.Expires < context.Clock.GetUtcNow()) throw Stale();
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        if (!SameSession(proposal.Session, session)) throw Stale();
        var working = WorkingScope.From(context);
        _ = await working.CurrentAsync(session, token).ConfigureAwait(false);
        await working.WithSelectionAsync(session, proposal.WorkingVersion, proposal.Working, async ct =>
        {
            if (!SameSession(proposal.Session, await context.Directory.GetSessionAsync(ct).ConfigureAwait(false))) throw Stale();
            if (context.Readers.Find<IOrganizationalUnitIndex>() is not { } index
                || await index.FindLocalAsync(proposal.Working.Dn, ct).ConfigureAwait(false) is null) throw Stale();
            await AccountsSectionScope.From(context).FollowConfirmedAsync(session, proposal.Accounts, proposal.AccountsVersion, ct).ConfigureAwait(false);
        }, token).ConfigureAwait(false);
    }

    private static bool SameSession(SessionSnapshot a, SessionSnapshot b) => a.Epoch == b.Epoch && a.StoreId == b.StoreId
        && a.Account == b.Account && a.Domain == b.Domain;
    private static DomeniaOperationException Stale() => new("scope.confirmationStale", "Session ou périmètre modifié depuis la proposition ; l’OU propre est conservée. Relisez la page.");
}
