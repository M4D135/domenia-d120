using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Masking of what looks like a secret before a text reaches an export, a support copy or a journal (Domenia 1
/// Protect-DomeniaSecretText, Test-DomeniaSecretAttribute, Test-DomeniaShellSensitiveOption). Pure.
/// </summary>
public static partial class ShellSecrets
{
    /// <summary>Text put in place of a value of a secret column.</summary>
    public const string WithheldValue = "[valeur secrète non exportée]";

    /// <summary>
    /// The text with every known form of secret masked: BitLocker recovery passwords, Bearer and Basic authorizations, JSON
    /// members, « clé=valeur » and « clé : valeur » forms in French and English, and password switches of command lines.
    /// </summary>
    public static string Protect(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var masked = RecoveryPassword().Replace(text, "[clé de récupération masquée]");
        masked = Authorization().Replace(masked, "$1 ***");
        masked = JsonMember().Replace(masked, "$1\"***\"");
        masked = KeyValue().Replace(masked, "$1$2***");
        masked = Switch().Replace(masked, "$1$2 ***");
        return masked;
    }

    /// <summary>Cheap test that every form masked by <see cref="Protect"/> satisfies (bulk exports run the full rule on these only).</summary>
    public static bool MayHoldSecret(string? text) => !string.IsNullOrEmpty(text) && Hint().IsMatch(text);

    /// <summary>Directory attributes that carry a secret: never a value in an export, a plan, a receipt or a summary.</summary>
    public static bool IsSecretAttribute(string? name) => !string.IsNullOrWhiteSpace(name) && SecretAttribute().IsMatch(name.Trim());

    /// <summary>
    /// An option of an operation whose value must not be shown (Domenia 1 Test-DomeniaShellSensitiveOption): flagged by the
    /// caller, or named or labelled like a secret (fail closed). A yes/no or date value carries no secret and stays visible.
    /// </summary>
    public static bool IsSensitiveOption(string? name, string? label, bool flagged, bool valueIsBooleanOrDate)
    {
        if (flagged)
        {
            return true;
        }
        if (valueIsBooleanOrDate)
        {
            return false;
        }
        var words = CamelCase().Replace((name ?? "") + " " + (label ?? ""), "$1 $2");
        words = Separators().Replace(words, " ");
        return SensitiveWords().IsMatch(words) || IsSecretAttribute(name);
    }

    [GeneratedRegex(@"(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)")]
    private static partial Regex RecoveryPassword();

    [GeneratedRegex(@"\b(Bearer|Basic)\s+[A-Za-z0-9_.~+/=-]+", RegexOptions.IgnoreCase)]
    private static partial Regex Authorization();

    [GeneratedRegex("(\"(?:password|passwd|pwd|pass|p|motdepasse|secret|token|api[_-]?key|apikey|client[_-]?secret)\"\\s*:\\s*)(\"(?:\\\\.|[^\"\\\\])*\"|[^,}\\s]+)", RegexOptions.IgnoreCase)]
    private static partial Regex JsonMember();

    [GeneratedRegex(@"\b(password|passwd|pwd|pass|motdepasse|mot\s+de\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)(\s*[=:]\s*)(""[^""]*""|'[^']*'|[^\s;,]+)", RegexOptions.IgnoreCase)]
    private static partial Regex KeyValue();

    [GeneratedRegex(@"(^|\s)([-/](?:p|rp|pass|password|pwd))(?:\s+|[:=])(""[^""]*""|'[^']*'|\S+)", RegexOptions.IgnoreCase)]
    private static partial Regex Switch();

    [GeneratedRegex(@"\d{6}-\d{6}|bearer|basic|pass|pwd|secret|token|authori|api[_-]?key|""\s*:|(?:^|\s)[-/]r?p", RegexOptions.IgnoreCase)]
    private static partial Regex Hint();

    [GeneratedRegex(@"^(?i:unicodePwd|userPassword|unixUserPassword|clearTextPassword|dBCSPwd|supplementalCredentials|ntPwdHistory|lmPwdHistory|currentValue|priorValue|pekList|trustAuthIncoming|trustAuthOutgoing|ms-Mcs-AdmPwd|msLAPS-.+|msFVE-RecoveryPassword|msFVE-KeyPackage|msDS-ManagedPassword.*|msDS-KeyCredentialLink)$")]
    private static partial Regex SecretAttribute();

    [GeneratedRegex("([a-z0-9])([A-Z])")]
    private static partial Regex CamelCase();

    [GeneratedRegex(@"[_\-.:/]")]
    private static partial Regex Separators();

    [GeneratedRegex(@"\b(pass|passe|password|passwd|passphrase|pwd|motdepasse|secrets?|tokens?|jetons?|apikey|credentials?|cl(e|é)s?|pin|laps|recovery|r(e|é)cup(e|é)ration)\b|\bmot\s+de\s+passe\b|\bapi\s+key\b|\bbit\s*locker\b", RegexOptions.IgnoreCase)]
    private static partial Regex SensitiveWords();
}
