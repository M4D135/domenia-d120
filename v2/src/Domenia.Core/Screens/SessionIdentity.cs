namespace Domenia.Core;

/// <summary>
/// Identity of the directory session for the state a screen keeps in memory (Domenia 1 SessionEpoch and BaseDn): the domain
/// root, the account and the way of connecting. The schema read and the leases of the temporary accounts are bound to it: another
/// domain, another account or another way of connecting makes them unusable.
/// </summary>
public static class SessionIdentity
{
    /// <summary>The key of <paramref name="session"/>, lower case (DN and account names ignore case).</summary>
    public static string Key(SessionSnapshot session)
    {
        ArgumentNullException.ThrowIfNull(session);
        return ((session.Domain?.RootDn ?? "") + "|" + session.Account.Login + "|" + session.Authentication.Method).ToLowerInvariant();
    }
}
