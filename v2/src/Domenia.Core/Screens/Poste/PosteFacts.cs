using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>
/// How much a fact of a workstation is worth (Domenia 1 New-DomeniaFact: Constaté, Estimé, Refusé, Indisponible, Inconnu).
/// A refusal or an unavailable source never proves anything about the workstation; an estimate is never a proof.
/// </summary>
public enum FactState
{
    Observed,
    Estimated,
    Refused,
    Unavailable,
    Unknown,
}

/// <summary>
/// One explainable fact: what was reported, how sure it is, by which source, what it does not prove (<see cref="Limit"/>),
/// what it suggests (<see cref="Hint"/>), and when it was read. Texts are French operator texts, shown as they are.
/// </summary>
public sealed record PosteFact(string Label, string Value, FactState State, string Source, string? Limit, string? Hint, DateTimeOffset? At, Tone Tone);

/// <summary>Progress pushed to the page during a long read (event « &lt;operation&gt;:progress »).</summary>
public sealed record PosteProgress(int Done, int Total, string Label);

/// <summary>Error codes and fixed messages of the workstation screen (docs/ops/poste.md).</summary>
public static class PosteErrors
{
    public const string ComputerUnknown = "poste.unknown";
    public const string ComputerUnknownMessage = "Ce nom distinctif ne désigne aucun poste de l’annuaire : rien n’a été lu.";

    public const string Unreachable = "poste.unreachable";

    public const string ConsentRequired = "poste.consentRequired";
    public const string ConsentRequiredMessage = "Autorisation d’intervention requise pour ce poste : accordez-la (5 min) dans la vue Intervenir. Rien n’a été préparé.";

    public const string Refused = "poste.refused";

    public const string QueryRefused = "poste.queryRefused";

    public const string KeyNotChild = "poste.keyNotChild";
    public const string KeyNotChildMessage = "Cette clé n’est pas un enfant direct du poste ouvert : aucune valeur n’est lue.";

    public const string Disabled = "poste.disabled";

    public const string Cancelled = "poste.cancelled";
    public const string CancelledMessage = "Relevé arrêté à votre demande : les valeurs déjà lues sont conservées, rien n’est relancé.";
}

/// <summary>French texts shared by the rules of the workstation screen; never culture dependent.</summary>
public static class PosteText
{
    public const string C = FrenchText.Colon;

    /// <summary>French ordering of names, case insensitive, independent of the culture of the workstation.</summary>
    public static StringComparer French { get; } = StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), CompareOptions.IgnoreCase);

    /// <summary>Size in the units of Domenia 1 (Format-DomeniaDashboardSize): « 238,5 Go », « 1,2 To », « 512 Mo ».</summary>
    public static string Size(double bytes)
    {
        const double Mb = 1024d * 1024d;
        const double Gb = Mb * 1024d;
        const double Tb = Gb * 1024d;
        if (bytes >= Tb)
        {
            return FrenchText.Decimal(bytes / Tb, 1) + " To";
        }
        if (bytes >= Gb)
        {
            return FrenchText.Decimal(bytes / Gb, 1) + " Go";
        }
        return FrenchText.Integer((long)Math.Round(bytes / Mb)) + " Mo";
    }

    /// <summary>Duration as Domenia 1 wrote it (Get-DomeniaWorkstationDurationText): « 12 j 4 h ».</summary>
    public static string Duration(TimeSpan span)
    {
        if (span < TimeSpan.Zero)
        {
            span = TimeSpan.Zero;
        }
        var days = (int)Math.Floor(span.TotalDays);
        return days > 0
            ? FrenchText.Integer(days) + " j " + span.Hours.ToString(CultureInfo.InvariantCulture) + " h"
            : span.Hours.ToString(CultureInfo.InvariantCulture) + " h " + span.Minutes.ToString(CultureInfo.InvariantCulture) + " min";
    }

    /// <summary>Local date and time « 21/10/2026 18:08 » in the zone of the session.</summary>
    public static string LocalDateTime(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>Local date « 21/10/2026 ».</summary>
    public static string LocalDate(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy", CultureInfo.InvariantCulture);
    }

    /// <summary>Local time « 14:32 ».</summary>
    public static string LocalTime(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>Age in plain words: « il y a 3 min », « il y a 2 h », « il y a 4 j ».</summary>
    public static string Age(DateTimeOffset at, DateTimeOffset now)
    {
        var span = now - at;
        if (span < TimeSpan.FromMinutes(1))
        {
            return "à l’instant";
        }
        if (span < TimeSpan.FromHours(1))
        {
            return "il y a " + FrenchText.Integer((long)span.TotalMinutes) + " min";
        }
        if (span < TimeSpan.FromDays(1))
        {
            return "il y a " + FrenchText.Integer((long)span.TotalHours) + " h";
        }
        return "il y a " + FrenchText.Count((long)span.TotalDays, "jour", "jours");
    }

    /// <summary>One line, control characters removed, at most <paramref name="max"/> characters (ConvertTo-DomeniaFlatText).</summary>
    public static string Flat(string? text, int max)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var builder = new System.Text.StringBuilder(Math.Min(text.Length, max + 1));
        var space = false;
        foreach (var c in text)
        {
            if (char.IsControl(c) || char.IsWhiteSpace(c))
            {
                space = builder.Length > 0;
                continue;
            }
            if (space)
            {
                builder.Append(' ');
                space = false;
            }
            builder.Append(c);
            if (builder.Length >= max)
            {
                break;
            }
        }
        return builder.ToString();
    }

    /// <summary>Tone of a fact state when nothing more precise is known.</summary>
    public static Tone ToneOf(FactState state) => state switch
    {
        FactState.Observed => Tone.Ok,
        FactState.Estimated => Tone.Info,
        FactState.Refused => Tone.Alert,
        FactState.Unavailable => Tone.Warn,
        _ => Tone.Off,
    };

    /// <summary>A fact with its usual tone.</summary>
    public static PosteFact Fact(string label, string value, FactState state, string source, string? limit = null, string? hint = null, DateTimeOffset? at = null, Tone? tone = null) =>
        new(label, value, state, source, string.IsNullOrEmpty(limit) ? null : limit, string.IsNullOrEmpty(hint) ? null : hint, at, tone ?? (string.IsNullOrEmpty(hint) ? ToneOf(state) : Tone.Warn));

    /// <summary>Maker and model as one label, the maker written once when the model already starts with it (« HP EliteDesk »).</summary>
    public static string Model(string? manufacturer, string? model)
    {
        var maker = (manufacturer ?? "").Trim();
        var name = (model ?? "").Trim();
        if (maker.Length == 0)
        {
            return name;
        }
        var brand = maker.Split(' ', 2)[0].TrimEnd(',', '.');
        return name.StartsWith(brand, StringComparison.OrdinalIgnoreCase) ? name : (maker + " " + name).Trim();
    }

    /// <summary>Short name of a workstation (NetBIOS part of a DNS name), upper case; empty for an empty text.</summary>
    public static string ShortName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return "";
        }
        var text = name.Trim();
        var dot = text.IndexOf('.', StringComparison.Ordinal);
        return (dot > 0 ? text[..dot] : text).ToUpperInvariant();
    }
}
