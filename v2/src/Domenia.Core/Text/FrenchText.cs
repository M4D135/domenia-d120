using System.Globalization;

namespace Domenia.Core;

/// <summary>French operator texts, independent of the workstation culture (docs/OPERATIONS.md § 1.2).</summary>
public static class FrenchText
{
    /// <summary>No-break space, before « : », « % » and inside « ».</summary>
    public const string Nbsp = " ";

    /// <summary>Narrow no-break space, thousands separator.</summary>
    public const string ThousandsSeparator = " ";

    /// <summary>Minus sign U+2212.</summary>
    public const string Minus = "−";

    /// <summary>« : » with its no-break space.</summary>
    public const string Colon = " : ";

    public static string Integer(long value)
    {
        var magnitude = value < 0 ? (ulong)(-(value + 1)) + 1 : (ulong)value;
        var grouped = Group(magnitude.ToString(CultureInfo.InvariantCulture));
        return value < 0 ? Minus + grouped : grouped;
    }

    /// <summary>Decimal number with a comma, e.g. 3,1 or 1 234,5.</summary>
    public static string Decimal(double value, int decimals = 1)
    {
        var rounded = Math.Round(value, decimals, MidpointRounding.AwayFromZero);
        var text = Math.Abs(rounded).ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
        var dot = text.IndexOf('.', StringComparison.Ordinal);
        var integerPart = dot < 0 ? text : text[..dot];
        var result = Group(integerPart) + (dot < 0 ? "" : "," + text[(dot + 1)..]);
        return rounded < 0 ? Minus + result : result;
    }

    /// <summary>Percentage such as « 3,1 % ».</summary>
    public static string Percent(double value, int decimals = 1) => Decimal(value, decimals) + Nbsp + "%";

    /// <summary>Signed integer: +9, −1, 0.</summary>
    public static string Signed(long value) => value > 0 ? "+" + Integer(value) : Integer(value);

    /// <summary>Delta label of a KPI: « +9 sur 7 jours », « −1 sur 7 jours », « Stable sur 7 jours ».</summary>
    public static string DeltaLabel(long delta, int days) =>
        delta == 0 ? $"Stable sur {Count(days, "jour", "jours")}" : $"{Signed(delta)} sur {Count(days, "jour", "jours")}";

    /// <summary>Number and noun with the French plural rule (0 and 1 take the singular).</summary>
    public static string Count(long value, string singular, string plural) =>
        Integer(value) + " " + (value >= 2 || value <= -2 ? plural : singular);

    /// <summary>Fixed abbreviated day names, independent of the culture.</summary>
    public static string DayAbbreviation(DayOfWeek day) => day switch
    {
        DayOfWeek.Monday => "lun.",
        DayOfWeek.Tuesday => "mar.",
        DayOfWeek.Wednesday => "mer.",
        DayOfWeek.Thursday => "jeu.",
        DayOfWeek.Friday => "ven.",
        DayOfWeek.Saturday => "sam.",
        _ => "dim.",
    };

    /// <summary>Date as jj/mm/aaaa.</summary>
    public static string ShortDate(DateOnly date) => date.ToString("dd'/'MM'/'yyyy", CultureInfo.InvariantCulture);

    /// <summary>Text between French quotes with no-break spaces: « texte ».</summary>
    public static string Quote(string text) => "«" + Nbsp + text + Nbsp + "»";

    private static string Group(string digits)
    {
        if (digits.Length <= 3)
        {
            return digits;
        }
        var builder = new System.Text.StringBuilder(digits.Length + digits.Length / 3);
        var head = digits.Length % 3;
        if (head > 0)
        {
            builder.Append(digits, 0, head);
        }
        for (var i = head; i < digits.Length; i += 3)
        {
            if (builder.Length > 0)
            {
                builder.Append(ThousandsSeparator);
            }
            builder.Append(digits, i, 3);
        }
        return builder.ToString();
    }
}
