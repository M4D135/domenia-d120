using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded explicit reads of account lists, details, batch candidates and lockout events.</summary>
public sealed class AdAccountsReader(AdDirectorySource source) : IAccountsReader
{
    public (DateTimeOffset Now, TimeZoneInfo Zone, bool Simulated) Clock => (source.Clock.GetUtcNow(), source.Zone, false);

    internal Func<DirectoryUser, DomainInfo, int, CancellationToken, Task<LockoutEventsRead>>? LockoutsOverride { get; init; }

    public async Task<AccountsList> ListAsync(AccountsScope scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        AdFicheObjects.ValidateDn(scope.Dn);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(30), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        var generation = source.Epoch;
        AdFicheObjects.EnsureDomain(scope.Dn, domain.RootDn);
        var tooWide = FicheValues.SameDn(scope.Dn, domain.RootDn);
        var at = source.Clock.GetUtcNow();
        var truncated = false;
        string? note = null;
        var users = ImmutableArray<DirectoryUser>.Empty;
        if (!tooWide)
        {
            var entries = await source.Connection.SearchAsync(new(scope.Dn, AdDirectoryMapper.UserFilter,
                scope.Subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel, AdDirectoryMapper.UserAttributes)
            { PageSize = 1000, SizeLimit = AccountsRules.ListLimit + 1, Timeout = TimeSpan.FromSeconds(30), Budget = TimeSpan.FromSeconds(30) }, budget.Token).ConfigureAwait(false);
            if (entries.Count > AccountsRules.ListLimit + 1 || entries.Any(e => !ScopeRules.Contains(new(scope.Dn, "", scope.Subtree), e.DistinguishedName)))
            { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Réponse de comptes hors du périmètre demandé."); }
            var mapped = entries.Take(AccountsRules.ListLimit).Select(MapUser).ToArray();
            users = [.. mapped.OfType<DirectoryUser>().OrderBy(u => FrenchText.Fold(AccountsRules.NameOf(u)), StringComparer.Ordinal).ThenBy(u => u.SamAccountName, StringComparer.OrdinalIgnoreCase)];
            if (users.Select(u => u.ObjectGuid).Distinct().Count() != users.Length) { throw AdAttributeRange.Incomplete(); }
            truncated = entries.Count > AccountsRules.ListLimit || mapped.Any(u => u is null);
            if (truncated)
            {
                var reasons = new List<string>();
                if (entries.Count > AccountsRules.ListLimit) { reasons.Add("limite de 5 000 comptes atteinte"); }
                if (mapped.Any(u => u is null)) { reasons.Add("identité ou état illisible pour certains objets"); }
                note = "Lecture partielle : " + string.Join(" ; ", reasons) + ". Les compteurs portent seulement sur les comptes lisibles affichés.";
            }
            if (users.Length > 0) { await RememberAsync(domain, users, at, generation, budget.Token).ConfigureAwait(false); }
        }
        EnsureEpoch(generation);
        var rows = users.Select(u => AccountsRules.Row(u, domain, at)).ToImmutableArray();
        var local = source.CurrentDirectory;
        var suggestions = rows.IsEmpty && local is not null ? AccountsRules.Suggestions(local, OrganizationalUnitTree.Build(local)) : [];
        return new(scope, tooWide, at, source.ControllerName, false, AccountsRules.Policy(domain.PasswordPolicy), AccountsRules.Counts(rows, at),
            rows, truncated, AccountsRules.ListLimit, suggestions) { Note = note };
    }

    public async Task<AccountsDetail> DetailAsync(string dn, string? operatorDn, CancellationToken cancellationToken)
    {
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        AdFicheObjects.ValidateDn(dn);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        var generation = source.Epoch;
        var at = source.Clock.GetUtcNow();
        var user = await RequireAsync(dn, budget.Token).ConfigureAwait(false);
        var users = ImmutableArray.Create(user);
        if (user.ManagerDn is { } managerDn)
        {
            // Only the explicitly referenced manager, never a name search across the domain.
            try
            {
                AdFicheObjects.EnsureDomain(managerDn, domain.RootDn);
                var manager = await new AdFicheObjects(source).UserAsync(managerDn, budget.Token).ConfigureAwait(false);
                if (manager is not null && manager.ObjectGuid != user.ObjectGuid) { users = users.Add(manager); }
            }
            catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.NoSuchObject or DomeniaErrors.ScopeOutsideDomain)
            { /* Keep the manager DN visible when its display name could not be read. */ }
        }
        await RememberAsync(domain, users, at, generation, budget.Token).ConfigureAwait(false);
        var session = await source.GetSessionAsync(budget.Token).ConfigureAwait(false);
        return AccountsRules.Detail(user, new(domain, at, false, [], users, [], []), source.ControllerName,
            session.Account.Dn ?? operatorDn, at, source.Zone, false);
    }

    public async Task<ImmutableArray<AccountsBatchCandidate>> CandidatesAsync(IReadOnlyList<string> dns, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dns);
        if (dns.Count is < 1 or > 5000) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Un aperçu collectif contient de 1 à 5 000 comptes."); }
        foreach (var dn in dns) { AdFicheObjects.ValidateDn(dn); }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromMinutes(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        foreach (var dn in dns) { AdFicheObjects.EnsureDomain(dn, domain.RootDn); }
        var generation = source.Epoch;
        var at = source.Clock.GetUtcNow();
        var objects = new AdFicheObjects(source);
        var rows = ImmutableArray.CreateBuilder<AccountsBatchCandidate>(dns.Count);
        foreach (var dn in dns)
        {
            budget.Token.ThrowIfCancellationRequested();
            rows.Add(new(dn, await objects.UserAsync(dn, budget.Token).ConfigureAwait(false)));
        }
        var users = rows.Where(r => r.User is not null).Select(r => r.User!).GroupBy(u => u.ObjectGuid).Select(g => g.Last()).ToImmutableArray();
        if (!users.IsEmpty) { await RememberAsync(domain, users, at, generation, budget.Token).ConfigureAwait(false); }
        EnsureEpoch(generation);
        return rows.MoveToImmutable();
    }

    public async Task<(DirectoryUser User, DomainInfo Domain, LockoutEventsRead Read)> LockoutEventsAsync(string dn, int hours, CancellationToken cancellationToken)
    {
        if (hours is < 1 or > 720) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Fenêtre du journal limitée à 1–720 heures."); }
        AdFicheObjects.ValidateDn(dn);
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var generation = source.Epoch;
        var user = await RequireAsync(dn, cancellationToken).ConfigureAwait(false);
        if (!AccountsRules.IsDomainSid(user.Sid)) { throw new DomeniaOperationException(AccountsRules.SidInvalid, AccountsRules.SidInvalidMessage); }
        var read = LockoutsOverride is { } replacement ? await replacement(user, domain, hours, cancellationToken).ConfigureAwait(false)
            : await new AdAccountLockouts(source).ReadAsync(user, domain, hours, AccountsLockouts.MaxEvents, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(generation);
        return (user, domain, read);
    }

    private async Task<DirectoryUser> RequireAsync(string dn, CancellationToken token) =>
        await new AdFicheObjects(source).UserAsync(dn, token).ConfigureAwait(false)
        ?? throw new DomeniaOperationException(AccountsRules.UnknownAccount, "Ce nom distinctif ne désigne aucun compte utilisateur lisible.");

    private Task RememberAsync(DomainInfo domain, ImmutableArray<DirectoryUser> users, DateTimeOffset at, long generation, CancellationToken token) =>
        source.RememberObjectsAsync(new(domain, at, false, [], users, [], []), generation, token);

    internal static DirectoryUser? MapUser(AdEntry entry)
    {
        var classes = entry.Strings("objectClass");
        return classes.Contains("user", StringComparer.OrdinalIgnoreCase) && !classes.Contains("computer", StringComparer.OrdinalIgnoreCase)
            && !classes.Contains("msDS-ManagedServiceAccount", StringComparer.OrdinalIgnoreCase) && !classes.Contains("msDS-GroupManagedServiceAccount", StringComparer.OrdinalIgnoreCase)
            && entry.Int("userAccountControl") is not null && entry.Guid("objectGUID") is { } id && id != Guid.Empty
            ? AdDirectoryMapper.User(entry) : null;
    }

    private void EnsureEpoch(long generation)
    {
        if (source.Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture des comptes."); }
    }
}
