namespace Domenia.Core;

/// <summary>Login entry may omit the domain; authentication always receives an explicit identity.</summary>
public static class DirectoryLogin
{
    public static bool IsValidInput(string? login)
    {
        if (CredentialRules.IsWellFormed(login)) return true;
        if (string.IsNullOrWhiteSpace(login) || login.Length > CredentialRules.MaxLoginLength || login.Any(char.IsControl)) return false;
        var name = login.Trim();
        return name.Length <= 104 && !name.Any(ch => char.IsWhiteSpace(ch) || ch is '\\' or '@');
    }

    public static string? DomainName(DomainIdentity? domain) =>
        !string.IsNullOrWhiteSpace(domain?.NetbiosName) ? domain.NetbiosName.Trim()
            : !string.IsNullOrWhiteSpace(domain?.DnsName) ? domain.DnsName.Trim() : null;

    public static string? Resolve(string? login, DomainIdentity? domain)
    {
        if (!IsValidInput(login)) return null;
        var name = login!.Trim();
        if (CredentialRules.IsWellFormed(name)) return name;
        // A DNS domain is a Windows credential authority too. Do not invent a UPN suffix for a sAMAccountName.
        var authority = DomainName(domain);
        var qualified = authority is null ? null : authority + "\\" + name;
        return CredentialRules.IsWellFormed(qualified) ? qualified : null;
    }

    public static string Hint(string? login, DomainIdentity? domain)
    {
        if (!string.IsNullOrWhiteSpace(login) && !IsValidInput(login))
            return "Vérifiez le compte : nom simple, DOMAINE\\compte ou compte@domaine.";
        return DomainName(domain) is { } name
            ? "Domaine : " + name + ". Le nom du compte suffit."
            : "Domaine non détecté : indiquez DOMAINE\\compte ou compte@domaine.";
    }
}
