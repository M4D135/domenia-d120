using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Ad;

/// <summary>Allowlisted WinError subcodes of LDAP 49. The server diagnostic itself is never retained or shown.</summary>
internal static class AdAuthenticationErrors
{
    internal static string Kind(string? diagnostic)
    {
        if (string.IsNullOrEmpty(diagnostic) || diagnostic.Length > 8192) { return "badCredentials"; }
        var match = Regex.Match(diagnostic, @"(?:^|[,;]\s*)data\s+([0-9a-f]{1,8})(?:[,\s]|$)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(50));
        if (!match.Success || !int.TryParse(match.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var code)) { return "badCredentials"; }
        return code switch
        {
            0x525 => "unknownAccount", 0x532 => "passwordExpired", 0x533 => "disabled", 0x701 => "accountExpired",
            0x773 => "mustChange", 0x775 => "locked", 0x52f or 0x530 or 0x531 => "restricted", _ => "badCredentials",
        };
    }
}
