using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

public sealed record TechnicalJournalStatus(string State, string? Path, int Pending, long Dropped, string? Problem);

/// <summary>One bounded, secret-masked physical line; an untrusted newline can never forge another record.</summary>
public static class TechnicalJournalRecord
{
    public const int MaximumInput = 65_536;
    public const int MaximumLine = 16_384;
    public static string Format(DateTimeOffset at, string level, string? text)
    {
        var input = text ?? "";
        string masked;
        if (input.Length > MaximumInput) { masked = "Message hors limites ; contenu non journalisé."; }
        else
        {
            try { masked = SupportSecretMask.Protect(input); }
            catch (RegexMatchTimeoutException) { masked = "Message non journalisé : masquage hors délai."; }
        }
        var value = new StringBuilder(Math.Min(masked.Length, MaximumLine));
        foreach (var c in masked)
        {
            value.Append(c switch { '\r' => "\\r", '\n' => "\\n", '\t' => "\\t", '\u2028' => "\\u2028", '\u2029' => "\\u2029",
                _ when char.IsControl(c) => "\\u" + ((int)c).ToString("x4", CultureInfo.InvariantCulture), _ => c.ToString() });
            if (value.Length >= MaximumLine) { value.Append("… [message borné]"); break; }
        }
        var kind = level is "INFO" or "ATTENTION" or "ERREUR" or "TRACE" ? level : "INFO";
        return at.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture) + " [" + kind + "] " + value + Environment.NewLine;
    }
}
