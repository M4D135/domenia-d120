using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core.Queries;

/// <summary>Result of the live check of a typed number: the converted value with its unit, or the reason it is refused.</summary>
public sealed record QueryNumberPreview(bool Valid, decimal? Value, string Text);

/// <summary>
/// Typed values, units and French labels (Domenia 1 ConvertTo-DomeniaQueryNumber, Format-DomeniaQueryValueLabel,
/// Get-DomeniaQueryClauseLabel). Pure, independent of the workstation culture.
/// </summary>
public static partial class QueryFormat
{
    [GeneratedRegex(@"^(?<n>[+-]?(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)(?:[eE][+-]?[0-9]+)?)\s*(?<u>[%\p{L}/]+)?$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex NumberPattern();

    /// <summary>
    /// Number typed for a numeric information, with an optional unit (Go/Mo/To/Ko, jours/heures/minutes, %, Mbit/s,
    /// Gbit/s, kbit/s, MHz/GHz) and a decimal comma. Divides the exact decimal: 48 h is exactly 2 days.
    /// </summary>
    public static decimal ParseNumber(string text, QueryField field)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(field);
        if (field.Kind != QueryFieldKind.Number)
        {
            throw new QueryDefinitionException("Cette information ne reçoit pas de valeur numérique.");
        }
        var match = NumberPattern().Match(text.Trim());
        if (!match.Success || !decimal.TryParse(match.Groups["n"].Value.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
        {
            throw new QueryDefinitionException("Saisissez un nombre fini, par exemple 8 Go ou 10,5.");
        }
        var suffix = match.Groups["u"].Value.ToLowerInvariant();
        if (suffix.Length == 0)
        {
            return number;
        }
        var unit = field.Unit;
        decimal? scale = unit switch
        {
            "Go" => suffix switch
            {
                "go" or "gb" or "gio" or "gib" => 1m,
                "mo" or "mb" or "mio" or "mib" => 1m / 1024m,
                "to" or "tb" or "tio" or "tib" => 1024m,
                _ => null,
            },
            "Mo" => suffix switch
            {
                "mo" or "mb" or "mio" or "mib" => 1m,
                "go" or "gb" or "gio" or "gib" => 1024m,
                "ko" or "kb" or "kio" or "kib" => 1m / 1024m,
                _ => null,
            },
            "Jours" => suffix switch
            {
                "j" or "jour" or "jours" or "d" or "day" or "days" => 1m,
                _ => null,
            },
            "%" => suffix is "%" or "pourcent" ? 1m : null,
            "Mbit/s" => suffix switch
            {
                "mbit/s" or "mbps" => 1m,
                "gbit/s" or "gbps" => 1000m,
                "kbit/s" or "kbps" => 1m / 1000m,
                _ => null,
            },
            "MHz" => suffix switch
            {
                "mhz" => 1m,
                "ghz" => 1000m,
                _ => null,
            },
            _ => null,
        };
        // Hours and minutes divide the original decimal, never a rounded reciprocal.
        if (unit == "Jours" && suffix is "h" or "heure" or "heures")
        {
            return number / 24m;
        }
        if (unit == "Jours" && suffix is "min" or "minute" or "minutes")
        {
            return number / 1440m;
        }
        return scale is decimal factor
            ? number * factor
            : throw new QueryDefinitionException("Unité incompatible" + FrenchText.Colon + suffix + ". Unité attendue" + FrenchText.Colon + unit + ".");
    }

    /// <summary>Live preview of a typed number (Domenia 1 Get-DomeniaQueryNumberPreview).</summary>
    public static QueryNumberPreview PreviewNumber(string? text, QueryField field)
    {
        ArgumentNullException.ThrowIfNull(field);
        var typed = (text ?? "").Trim();
        if (typed.Length == 0)
        {
            return new QueryNumberPreview(false, null, "");
        }
        try
        {
            var value = ParseNumber(typed, field);
            var shown = Value(QueryValue.FromNumber(value), field);
            var message = char.IsLetter(typed[^1]) || typed[^1] is '%' or '/' ? (typed != shown ? typed + " = " + shown : "Valeur retenue" + FrenchText.Colon + shown) : "Valeur retenue" + FrenchText.Colon + shown;
            return new QueryNumberPreview(true, value, message);
        }
        catch (QueryDefinitionException ex)
        {
            return new QueryNumberPreview(false, null, ex.Message);
        }
    }

    /// <summary>
    /// Readable typed value: Oui/Non, French decimal with its unit, coded choice name, parameter reference or text between
    /// French quotes (<paramref name="bare"/> omits the quotes: observed values in a grid).
    /// </summary>
    public static string Value(QueryValue value, QueryField? field, bool bare = false)
    {
        switch (value.Kind)
        {
            case QueryValueKind.None:
                return "";
            case QueryValueKind.Parameter:
                return "paramètre " + value.Text;
            case QueryValueKind.Boolean:
                return value.Flag ? "Oui" : "Non";
        }
        if (field is not null)
        {
            foreach (var choice in field.Choices)
            {
                if (choice.Value.Kind == value.Kind && choice.Value.Invariant == value.Invariant)
                {
                    return choice.Name;
                }
            }
        }
        if (value.Kind == QueryValueKind.Number)
        {
            var text = Number(value.Number);
            var unit = field?.Unit switch
            {
                "Go" => "Go",
                "Mo" => "Mo",
                "Jours" => "j",
                "%" => "%",
                "Mbit/s" => "Mbit/s",
                "MHz" => "MHz",
                _ => null,
            };
            return unit is null ? text : text + FrenchText.Nbsp + unit;
        }
        return bare ? value.Text ?? "" : FrenchText.Quote(value.Text ?? "");
    }

    /// <summary>Record value (string, decimal, bool) shown bare.</summary>
    public static string Raw(object? raw, QueryField? field) => raw is null ? "" : Value(QueryValue.FromRaw(raw), field, bare: true);

    /// <summary>French decimal without trailing zeros (12 decimals at most): « 8 », « 10,5 », « 1 234,25 ».</summary>
    public static string Number(decimal value)
    {
        var rounded = Math.Round(value, 12, MidpointRounding.AwayFromZero);
        var text = Math.Abs(rounded).ToString("0.############", CultureInfo.InvariantCulture);
        var dot = text.IndexOf('.', StringComparison.Ordinal);
        var integer = dot < 0 ? text : text[..dot];
        var grouped = long.TryParse(integer, NumberStyles.None, CultureInfo.InvariantCulture, out var whole) ? FrenchText.Integer(whole) : integer;
        var result = grouped + (dot < 0 ? "" : "," + text[(dot + 1)..]);
        return rounded < 0 ? FrenchText.Minus + result : result;
    }

    /// <summary>One French sentence per condition (« Mémoire relevée en Go est inférieur à 8 Go »).</summary>
    public static string Clause(QueryClause clause, QueryTarget target, WmiReadDefinition? read = null)
    {
        ArgumentNullException.ThrowIfNull(clause);
        var field = QueryCatalog.Find(target, clause.Field, read);
        var name = field?.Name ?? clause.Field;
        if (clause.Field == QueryCatalog.LdapFilterField)
        {
            return "Filtre LDAP " + (clause.Value.Text ?? "");
        }
        var verb = QueryTexts.OperatorLabel(clause.Operator);
        return clause.Operator is QueryOperator.IsMissing or QueryOperator.IsPresent ? name + " " + verb : name + " " + verb + " " + Value(clause.Value, field);
    }

    /// <summary>« 12 h », « 48 h (2 jours) » (Domenia 1 Format-DomeniaQueryHours).</summary>
    public static string Hours(decimal hours)
    {
        var text = Number(Math.Round(hours, 2)) + FrenchText.Nbsp + "h";
        if (hours >= 48 && hours % 24 == 0)
        {
            text += " (" + FrenchText.Integer((long)(hours / 24)) + " jours)";
        }
        return text;
    }

    /// <summary>Local date and time « 21/10/2026 18:26 » in the given zone.</summary>
    public static string LocalDate(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>Text check shared by names, categories and labels: length and no control character.</summary>
    public static bool CleanText(string? text, int maxLength, bool allowEmpty = false) =>
        text is not null && text.Length <= maxLength && (allowEmpty || text.Trim().Length > 0) && !text.Any(char.IsControl);
}
