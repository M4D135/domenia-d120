using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// French texts of the Assistance screen and of its documents. A number stays on the line of its noun (no-break space, so a
/// line never ends with « 1 » and starts with « facultative »), and every document gives its dates the same way: local date
/// and time with the offset from UTC (« 22/10/2026 03:19:12 (UTC+02:00) »).
/// </summary>
public static class AssistanceText
{
    /// <summary>Number and noun joined by a no-break space, French plural rule (0 and 1 take the singular).</summary>
    public static string Count(long value, string singular, string plural) =>
        FrenchText.Integer(value) + FrenchText.Nbsp + (value >= 2 || value <= -2 ? plural : singular);

    /// <summary>Local date and time of a document line, with its UTC offset: « 22/10/2026 03:19:12 (UTC+02:00) ».</summary>
    public static string Stamp(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var local = TimeZoneInfo.ConvertTime(at, zone);
        return local.ToString("dd'/'MM'/'yyyy' 'HH':'mm':'ss", CultureInfo.InvariantCulture) + " (" + Offset(local.Offset) + ")";
    }

    /// <summary>Local date and time to the minute with the UTC offset: « 22/10/2026 03:19 (UTC+02:00) ».</summary>
    public static string StampMinutes(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var local = TimeZoneInfo.ConvertTime(at, zone);
        return local.ToString("dd'/'MM'/'yyyy' 'HH':'mm", CultureInfo.InvariantCulture) + " (" + Offset(local.Offset) + ")";
    }

    /// <summary>Local date and time for a file name: « 20261022-031912 ».</summary>
    public static string FileStamp(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("yyyyMMdd'-'HHmmss", CultureInfo.InvariantCulture);
    }

    /// <summary>« UTC+02:00 », « UTC−03:30 », « UTC ».</summary>
    public static string Offset(TimeSpan offset)
    {
        if (offset == TimeSpan.Zero)
        {
            return "UTC";
        }
        var sign = offset < TimeSpan.Zero ? FrenchText.Minus : "+";
        var value = offset.Duration();
        return "UTC" + sign + value.Hours.ToString("00", CultureInfo.InvariantCulture) + ":" + value.Minutes.ToString("00", CultureInfo.InvariantCulture);
    }

    /// <summary>Size in bytes for the operator: « 834 octets », « 12,4 Kio », « 3,2 Mio » (the unit Get-FileHash users reason in).</summary>
    public static string Bytes(long bytes)
    {
        if (bytes < 1024)
        {
            return Count(bytes, "octet", "octets");
        }
        if (bytes < 1024 * 1024)
        {
            return FrenchText.Decimal(bytes / 1024.0, 1) + FrenchText.Nbsp + "Kio";
        }
        return FrenchText.Decimal(bytes / (1024.0 * 1024), 1) + FrenchText.Nbsp + "Mio";
    }

    /// <summary>French list: « a », « a et b », « a, b et c ».</summary>
    public static string List(IReadOnlyList<string> parts)
    {
        ArgumentNullException.ThrowIfNull(parts);
        return parts.Count switch
        {
            0 => "",
            1 => parts[0],
            _ => string.Join(", ", parts.Take(parts.Count - 1)) + " et " + parts[^1],
        };
    }
}
