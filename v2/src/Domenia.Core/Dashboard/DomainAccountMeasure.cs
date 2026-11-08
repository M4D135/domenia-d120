namespace Domenia.Core;

/// <summary>A bounded census of users only; never certifies coverage of computers, groups or OUs.</summary>
public sealed record DomainAccountMeasure(DomainInfo Domain, DateTimeOffset ReadAt, bool Complete,
    int Active, int Disabled, int Locked, int LockUnknown, int Expiring, int Expired, int MustChange,
    int NeverExpires, int PasswordWindowDays, int PasswordUnknown = 0)
{
    public static DomainAccountMeasure Compute(DomainInfo domain, IEnumerable<DirectoryUser> users,
        DateTimeOffset readAt, bool complete, TimeSpan passwordWindow)
    {
        int active = 0, disabled = 0, locked = 0, unknown = 0, expiring = 0, expired = 0, change = 0, never = 0, passwordUnknown = 0;
        foreach (var user in users)
        {
            if (user.LegacyIndexOnly) complete = false;
            if (AdValues.IsDisabled(user.UserAccountControl)) { disabled++; continue; }
            active++;
            if (user.LegacyIndexOnly) { unknown++; passwordUnknown++; continue; }
            switch (user.ComputedAccountControl is null && user.LockoutTime is null ? LockState.ToCheck
                : AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime).Lock)
            {
                case LockState.Locked: locked++; break;
                case LockState.ToCheck: unknown++; break;
            }
            var passwordKnown = user.PasswordLastSet == 0 || AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword)
                || user.PasswordExpiryComputed == AdValues.Never || AdValues.FromFileTime(user.PasswordExpiryComputed) is not null
                || user.ComputedAccountControl is int computed && AdValues.HasFlag(computed, AdValues.PasswordExpired)
                || user.PasswordExpiryComputed is null && AdValues.FromFileTime(user.PasswordLastSet) is not null;
            if (!passwordKnown) { passwordUnknown++; continue; }
            switch (AccountState.ClassifyPassword(user, domain.PasswordPolicy.MaxPasswordAge, readAt, passwordWindow))
            {
                case PasswordClass.Expiring: expiring++; break;
                case PasswordClass.Expired: expired++; break;
                case PasswordClass.MustChange: change++; break;
                case PasswordClass.NeverExpires: never++; break;
            }
        }
        return new(domain, readAt, complete, active, disabled, locked, unknown, expiring, expired, change, never, passwordWindow.Days, passwordUnknown);
    }
}

/// <summary>Small, durable aggregate separate from the selected OU's retained directory objects.</summary>
public interface IDomainAccountCache
{
    Task<DomainAccountMeasure?> ReadDomainAccountsAsync(CancellationToken token);
    Task<DomainAccountMeasure> SaveDomainAccountsAsync(DomainAccountMeasure measure, CancellationToken token);
}
