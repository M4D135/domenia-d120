using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Exact authenticated principal and transitive LDAP groups for one explicit target trial.
/// Not an authorization: the target must independently show membership of its local Administrators group.</summary>
public sealed record MachineAdministrationPrincipal(string Account, string AccountSid, ImmutableArray<string> GroupSids)
{
    public const int MaxGroups = 1024;
    public const int MaxSidCharacters = 48_000;

    public bool IsBounded => CredentialRules.IsWellFormed(Account) && AccountsRules.IsDomainSid(AccountSid)
        && !GroupSids.IsDefault && GroupSids.Length <= MaxGroups
        && GroupSids.All(IsSid) && AccountSid.Length + GroupSids.Sum(s => s.Length) <= MaxSidCharacters;

    private static bool IsSid(string? sid)
    {
        if (sid is null || sid.Length is < 5 or > 184 || !sid.StartsWith("S-1-", StringComparison.Ordinal)) return false;
        var parts = sid.Split('-');
        return parts.Length is >= 4 and <= 18 && parts.Skip(2).All(p => p.Length is > 0 and <= 15 && p.All(char.IsAsciiDigit));
    }
}
