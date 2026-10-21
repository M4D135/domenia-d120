namespace Domenia.Core;

public enum LockState
{
    Unlocked,
    Locked,

    /// <summary>lockoutTime is set but the controller's computed state is unreadable: never reported as locked.</summary>
    ToCheck,
}

/// <summary>Password situation of an account, in the order the rules are applied.</summary>
public enum PasswordClass
{
    Valid,
    MustChange,
    NeverExpires,
    Expired,
    Expiring,
}

/// <summary>Account state rules of Domenia 1 (Get-DomeniaAccountState, Domenia-Directory.Model.ps1).</summary>
public sealed record AccountState(
    bool Disabled,
    LockState Lock,
    bool PasswordExpired,
    bool PasswordNeverExpires,
    bool PasswordNotRequired,
    bool SmartCardRequired)
{
    public static AccountState Evaluate(int userAccountControl, int? computedAccountControl, long? lockoutTime)
    {
        var lockState = computedAccountControl is int computed
            ? AdValues.HasFlag(computed, AdValues.LockedOut) ? LockState.Locked : LockState.Unlocked
            : lockoutTime is > 0 ? LockState.ToCheck : LockState.Unlocked;
        return new AccountState(
            AdValues.IsDisabled(userAccountControl),
            lockState,
            computedAccountControl is int c && AdValues.HasFlag(c, AdValues.PasswordExpired),
            AdValues.HasFlag(userAccountControl, AdValues.DontExpirePassword),
            AdValues.HasFlag(userAccountControl, AdValues.PasswordNotRequired),
            AdValues.HasFlag(userAccountControl, AdValues.SmartCardRequired));
    }

    /// <summary>
    /// Password class of one account at <paramref name="now"/>: « must change » first (pwdLastSet = 0), then « never expires »,
    /// then expired (computed bit or date reached), then expiring within ]now ; now + window]. Without the computed expiry,
    /// the date is estimated from the domain maxPwdAge.
    /// </summary>
    public static PasswordClass ClassifyPassword(DirectoryUser user, TimeSpan maxPasswordAge, DateTimeOffset now, TimeSpan window)
    {
        ArgumentNullException.ThrowIfNull(user);
        if (user.PasswordLastSet == 0)
        {
            return PasswordClass.MustChange;
        }
        if (AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword) || user.PasswordExpiryComputed == AdValues.Never)
        {
            return PasswordClass.NeverExpires;
        }
        if (user.ComputedAccountControl is int computed && AdValues.HasFlag(computed, AdValues.PasswordExpired))
        {
            return PasswordClass.Expired;
        }
        var expiry = AdValues.FromFileTime(user.PasswordExpiryComputed);
        if (expiry is null && user.PasswordExpiryComputed is null && maxPasswordAge > TimeSpan.Zero && AdValues.FromFileTime(user.PasswordLastSet) is DateTimeOffset lastSet)
        {
            expiry = lastSet + maxPasswordAge;
        }
        if (expiry is not DateTimeOffset date)
        {
            return PasswordClass.Valid;
        }
        if (date <= now)
        {
            return PasswordClass.Expired;
        }
        return date <= now + window ? PasswordClass.Expiring : PasswordClass.Valid;
    }
}
