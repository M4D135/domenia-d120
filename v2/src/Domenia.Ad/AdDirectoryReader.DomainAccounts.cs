using Domenia.Core;

namespace Domenia.Ad;

public static partial class AdDirectoryReader
{
    private static readonly string[] DomainAccountAttributes =
    [
        "objectGUID", "objectSid", "name", "userAccountControl", "msDS-User-Account-Control-Computed",
        "lockoutTime", "pwdLastSet", "msDS-UserPasswordExpiryTimeComputed",
    ];

    /// <summary>Explicit domain account census. Reads users only, with the same paging and truncation guard as OU reads.</summary>
    public static async Task<DomainAccountMeasure> ReadDomainAccountsAsync(IAdConnection connection, DomainInfo domain,
        int maxUsers, TimeProvider clock, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxUsers);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(maxUsers, MaxObjectsPerKindLimit);
        var scope = new ScopeSelection(domain.RootDn, domain.DnsName, true);
        var at = clock.GetUtcNow();
        var users = await ReadKindAsync(connection, scope, AdDirectoryMapper.UserFilter,
            DomainAccountAttributes, maxUsers,
            entry => entry.Int("userAccountControl") is >= 0 ? AdDirectoryMapper.User(entry) : null, token).ConfigureAwait(false);
        if (users.Items.Any(u => u.ObjectGuid == Guid.Empty || !ScopeRules.Contains(scope, u.DistinguishedName))
            || users.Items.Select(u => u.ObjectGuid).Distinct().Count() != users.Items.Length)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Réponse utilisateurs incohérente : aucun compteur publié."); }
        return DomainAccountMeasure.Compute(domain, users.Items, at, users.Complete, DashboardPolicy.Default.PasswordExpiringWindow);
    }
}
