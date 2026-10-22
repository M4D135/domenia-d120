using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// French wording shared by the Paramètres rules (pure, independent of the workstation culture): sizes, elapsed times,
/// local dates and durations, as Domenia 1 wrote them (Format-DomeniaSize, Get-DomeniaElapsedText,
/// Format-DomeniaStorageDate, Format-DomeniaCollectionDuration).
/// </summary>
public static class SettingsFormat
{
    private static readonly string[] Units = ["Ko", "Mo", "Go", "To"];

    /// <summary>« 512 o », « 4,2 Mo », « 61,4 Go »; « inconnu » for a negative (unknown) size. One decimal at most.</summary>
    public static string Size(long bytes)
    {
        if (bytes < 0)
        {
            return "inconnu";
        }
        if (bytes < 1024)
        {
            return FrenchText.Integer(bytes) + FrenchText.Nbsp + "o";
        }
        var value = (double)bytes;
        var unit = "o";
        foreach (var candidate in Units)
        {
            value /= 1024;
            unit = candidate;
            if (value < 1024)
            {
                break;
            }
        }
        var rounded = Math.Round(value, 1, MidpointRounding.AwayFromZero);
        var text = rounded == Math.Floor(rounded) ? FrenchText.Integer((long)rounded) : FrenchText.Decimal(rounded, 1);
        return text + FrenchText.Nbsp + unit;
    }

    /// <summary>Optional size: « inconnu » when null.</summary>
    public static string Size(long? bytes) => bytes is long value ? Size(value) : "inconnu";

    /// <summary>
    /// « à l’instant », « il y a 5 min », « il y a 2 h », « il y a 3 j » between two instants; a date more than five minutes
    /// in the future is named as such (clock to check), never as a recent one.
    /// </summary>
    public static string Elapsed(DateTimeOffset from, DateTimeOffset now)
    {
        var span = now - from;
        if (span.TotalMinutes < -5)
        {
            return "à une date future (horloge à vérifier)";
        }
        if (span.TotalMinutes < 1)
        {
            return "à l’instant";
        }
        if (span.TotalHours < 1)
        {
            return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalMinutes)) + FrenchText.Nbsp + "min";
        }
        if (span.TotalDays < 1)
        {
            return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalHours)) + FrenchText.Nbsp + "h";
        }
        return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalDays)) + FrenchText.Nbsp + "j";
    }

    /// <summary>« 21/10/2026 18:26 » (or with seconds) in the given zone, independent of the culture.</summary>
    public static string LocalDate(DateTimeOffset at, TimeZoneInfo zone, bool seconds = false)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var local = TimeZoneInfo.ConvertTime(at, zone);
        return local.ToString(seconds ? "dd'/'MM'/'yyyy HH':'mm':'ss" : "dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>« 18:26 » in the given zone.</summary>
    public static string LocalTime(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Short duration (Domenia 1 Format-DomeniaCollectionDuration): « 30 s », « 5 min », « 1 h 30 min », « 2 j 4 h »; zero
    /// means the value is always read again.
    /// </summary>
    public static string Duration(long seconds)
    {
        static string N(long v) => FrenchText.Integer(v) + FrenchText.Nbsp;
        if (seconds <= 0)
        {
            return "0" + FrenchText.Nbsp + "s (toujours relire)";
        }
        if (seconds < 60)
        {
            return N(seconds) + "s";
        }
        if (seconds < 3600)
        {
            var minutes = seconds / 60;
            var rest = seconds % 60;
            return rest > 0 ? N(minutes) + "min " + N(rest) + "s" : N(minutes) + "min";
        }
        if (seconds < 86400)
        {
            var hours = seconds / 3600;
            var minutes = seconds % 3600 / 60;
            return minutes > 0 ? N(hours) + "h " + N(minutes) + "min" : N(hours) + "h";
        }
        var days = seconds / 86400;
        var remaining = seconds % 86400 / 3600;
        return remaining > 0 ? N(days) + "j " + N(remaining) + "h" : N(days) + "j";
    }

    /// <summary>« 30 jours », « 1 jour », « sans limite » (0).</summary>
    public static string Days(int days) => days <= 0 ? "sans limite" : FrenchText.Count(days, "jour", "jours");

    /// <summary>Lower-case SHA-256 text of 64 hexadecimal characters, or null.</summary>
    public static string? Sha256Text(string? value)
    {
        if (value is null)
        {
            return null;
        }
        var text = value.Trim().ToLowerInvariant();
        return text.Length == 64 && text.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')) ? text : null;
    }

    /// <summary>First twelve characters of a SHA-256, followed by « … ».</summary>
    public static string ShortSha(string sha256)
    {
        ArgumentNullException.ThrowIfNull(sha256);
        return sha256.Length > 12 ? sha256[..12] + "…" : sha256;
    }
}
