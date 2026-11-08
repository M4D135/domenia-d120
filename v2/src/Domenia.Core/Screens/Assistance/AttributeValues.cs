using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Readable form of a captured attribute value for the documents (the page has its own, the same rules): FILETIME large
/// integers and generalized times become a local date with its UTC offset, special values say what they mean. The raw value is
/// always kept beside it; nothing here changes a capture.
/// </summary>
public static class AttributeValues
{
    private static readonly HashSet<string> FileTimes = new(StringComparer.OrdinalIgnoreCase)
    {
        "lockoutTime", "pwdLastSet", "accountExpires", "lastLogonTimestamp", "lastLogon", "badPasswordTime", "msDS-UserPasswordExpiryTimeComputed",
    };

    private static readonly HashSet<string> GeneralizedTimes = new(StringComparer.OrdinalIgnoreCase) { "whenCreated", "whenChanged" };

    /// <summary>True for the attributes whose value is a date (FILETIME or generalized time).</summary>
    public static bool IsDate(string? name) => name is not null && (FileTimes.Contains(name) || GeneralizedTimes.Contains(name));

    /// <summary>The readable form of one value, or null when the attribute is not a date or the value cannot be read.</summary>
    public static string? Readable(string? name, string? value, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (name is null || string.IsNullOrWhiteSpace(value))
        {
            return null;
        }
        if (FileTimes.Contains(name))
        {
            if (!long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var raw))
            {
                return null;
            }
            if (raw == 0 || raw == AdValues.Never)
            {
                return name.ToUpperInvariant() switch
                {
                    "LOCKOUTTIME" => "aucun verrouillage",
                    "PWDLASTSET" => raw == 0 ? "changement exigé à la prochaine ouverture de session" : null,
                    "ACCOUNTEXPIRES" or "MSDS-USERPASSWORDEXPIRYTIMECOMPUTED" => "jamais",
                    _ => "jamais",
                };
            }
            return AdValues.FromFileTime(raw) is DateTimeOffset at ? AssistanceText.Stamp(at, zone) : null;
        }
        if (GeneralizedTimes.Contains(name)
            && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var date))
        {
            return AssistanceText.Stamp(date, zone);
        }
        return null;
    }
}
