using System.Globalization;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>Exact domain/usage/account identity, compatible with the optional Domenia 1 vault.</summary>
public sealed record CredentialVaultTarget(string DomainDn, string Scope, string Account)
{
    public string Key => CredentialVaultRules.Key(DomainDn, Scope, Account);
}

public static class CredentialVaultRules
{
    public const string Prefix = "Domenia:v1:";
    public const int MaxSecretBytes = 2560;
    public const string Unavailable = "accounts.vaultUnavailable";
    public const string Failed = "accounts.vaultFailed";

    public static string Key(string domainDn, string scope, string account)
    {
        ArgumentNullException.ThrowIfNull(domainDn); ArgumentNullException.ThrowIfNull(scope); ArgumentNullException.ThrowIfNull(account);
        var domain = domainDn.Trim(); var usage = scope.Trim(); var login = account.Trim();
        if (domain.Length is 0 or > 2048 || domain.Any(char.IsControl) || login.Length is 0 or > 256 || login.Any(char.IsControl))
        { throw new ArgumentException("Domaine ou identifiant du coffre invalide."); }
        var normal = new[] { "Directory", "Remote", "Laps", "BitLocker" }.Contains(usage, StringComparer.OrdinalIgnoreCase);
        var operation = Regex.IsMatch(usage, @"\AAD:[A-Za-z][A-Za-z0-9_.-]{0,63}\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
        var local = Regex.IsMatch(usage, @"\ARemoteLocal:[a-z0-9][a-z0-9._-]{0,252}\z", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
        if (!normal && !operation && !local) { throw new ArgumentException("Usage du coffre inconnu."); }
        if (local)
        {
            var name = CredentialRules.Parse(login);
            if (name.Form != AccountNameForm.DownLevel || !CredentialRules.IsWellFormed(login)
                || name.Authority != "." && !name.Authority.Equals(usage[12..], StringComparison.OrdinalIgnoreCase))
            { throw new ArgumentException("Ce coffre local exige le compte du poste exact."); }
        }
        else if (login.StartsWith(".\\", StringComparison.Ordinal)) { throw new ArgumentException("Un compte local exige un poste précis."); }
        var builder = new StringBuilder();
        foreach (var part in new[] { "DomeniaCredentialVault/v1", domain.ToLowerInvariant(), usage.ToLowerInvariant(), login.ToLowerInvariant() })
        { builder.Append(part.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(part); }
        return Prefix + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())));
    }
}

/// <summary>Local Credential Manager access only. Reading does not authenticate or clear a refusal.</summary>
public interface IAccountsCredentialVault : IScreenReader
{
    bool Available { get; }
    SecureString? Read(CredentialVaultTarget target);
    /// <summary>Only called after explicit opt-in and successful manual authentication of this exact target.</summary>
    void Write(CredentialVaultTarget target, SecureString password);
    bool Delete(CredentialVaultTarget target);
}
