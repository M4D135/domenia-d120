using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>How a collection window reads: always open, never open, rules, or invalid (background work suspended).</summary>
public enum CollectionWindowMode
{
    Always,
    Never,
    Rules,
    Invalid,
}

/// <summary>One rule of a window: days (0 = Sunday … 6 = Saturday), start and end minute, and whether it ends the next day.</summary>
public sealed record CollectionWindowRule(ImmutableArray<int> Days, int StartMinute, int EndMinute, bool Overnight);

/// <summary>A parsed window (Domenia 1 ConvertFrom-DomeniaCollectionWindowText).</summary>
public sealed record CollectionWindow(bool Valid, CollectionWindowMode Mode, ImmutableArray<CollectionWindowRule> Rules, ImmutableArray<string> Errors, string Text);

/// <summary>State of a window at an instant: open or closed, and the next change within eight days (local time).</summary>
public sealed record CollectionWindowState(bool Open, CollectionWindowMode Mode, DateTimeOffset? NextChange);

/// <summary>
/// Collection windows (Domenia 1 point 159, PAR-040), pure: « lun-ven 07:30-12:00 13:30-18:00; sam », « toujours » or
/// « jamais ». Background work that reads the network on its own (reconciliation, object changes, fleet, index) only runs
/// while the window is open; an explicit campaign stays possible and its confirmation says the window is closed. An invalid
/// window suspends the background work until it is corrected; it is never stored.
/// </summary>
public static partial class CollectionWindowRules
{
    /// <summary>Longest window text accepted.</summary>
    public const int MaxLength = 400;

    /// <summary>Background sources held by a window (the others are operator gestures or local work).</summary>
    public static ImmutableArray<string> Sources { get; } = ["Réconciliation des listes", "Changements d’objets", "Relevés du parc", "Mise à jour de l’index"];

    private static readonly Dictionary<string, int> DayMap = new(StringComparer.Ordinal)
    {
        ["lun"] = 1, ["lundi"] = 1, ["mar"] = 2, ["mardi"] = 2, ["mer"] = 3, ["mercredi"] = 3, ["jeu"] = 4, ["jeudi"] = 4,
        ["ven"] = 5, ["vendredi"] = 5, ["sam"] = 6, ["samedi"] = 6, ["dim"] = 0, ["dimanche"] = 0,
    };

    private static readonly string[] DayNames = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"];

    [GeneratedRegex(@"^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$", RegexOptions.CultureInvariant, matchTimeoutMilliseconds: 200)]
    private static partial Regex RangePattern();

    /// <summary>
    /// Parses a window. Days: lun mar mer jeu ven sam dim (full names accepted, accents of « fold » ignored), lists
    /// « lun,mer », ranges « lun-ven » or « ven-lun », « tous ». A day without range is open all day; a range whose end
    /// precedes its start continues the next day. Errors name the faulty token, never guess.
    /// </summary>
    public static CollectionWindow Parse(string? text)
    {
        var clean = (text ?? "").Trim();
        if (clean.Length > MaxLength)
        {
            return new CollectionWindow(false, CollectionWindowMode.Invalid, [], ["Fenêtre trop longue" + FrenchText.Colon + FrenchText.Integer(MaxLength) + " caractères au plus."], clean[..MaxLength]);
        }
        var folded = FrenchText.Fold(clean);
        if (folded.Length == 0 || folded == "toujours")
        {
            return new CollectionWindow(true, CollectionWindowMode.Always, [], [], "");
        }
        if (folded == "jamais")
        {
            return new CollectionWindow(true, CollectionWindowMode.Never, [], [], "jamais");
        }
        var errors = new List<string>();
        var rules = new List<CollectionWindowRule>();
        foreach (var clause in folded.Split(';'))
        {
            var part = clause.Trim();
            if (part.Length == 0)
            {
                continue;
            }
            var tokens = part.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            var days = ParseDays(tokens[0]);
            if (days is null || days.Count == 0)
            {
                errors.Add("Jours non reconnus" + FrenchText.Colon + FrenchText.Quote(tokens[0]) + " (exemple" + FrenchText.Colon + "lun-ven).");
                continue;
            }
            var dayArray = days.ToImmutableArray();
            if (tokens.Length == 1)
            {
                rules.Add(new CollectionWindowRule(dayArray, 0, 1440, false));
                continue;
            }
            foreach (var range in tokens.Skip(1))
            {
                Match match;
                try
                {
                    match = RangePattern().Match(range);
                }
                catch (RegexMatchTimeoutException)
                {
                    match = Match.Empty;
                }
                if (!match.Success)
                {
                    errors.Add("Plage horaire non reconnue" + FrenchText.Colon + FrenchText.Quote(range) + " (exemple" + FrenchText.Colon + "07:30-12:00).");
                    continue;
                }
                var sh = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
                var sm = int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture);
                var eh = int.Parse(match.Groups[3].Value, CultureInfo.InvariantCulture);
                var em = int.Parse(match.Groups[4].Value, CultureInfo.InvariantCulture);
                if (sh > 23 || sm > 59 || em > 59 || eh > 24 || (eh == 24 && em != 0))
                {
                    errors.Add("Heure invalide" + FrenchText.Colon + FrenchText.Quote(range) + ".");
                    continue;
                }
                var start = sh * 60 + sm;
                var end = eh * 60 + em;
                if (start == end)
                {
                    errors.Add("Plage vide" + FrenchText.Colon + FrenchText.Quote(range) + ".");
                    continue;
                }
                rules.Add(new CollectionWindowRule(dayArray, start, end, end < start));
            }
        }
        if (errors.Count > 0)
        {
            return new CollectionWindow(false, CollectionWindowMode.Invalid, [], [.. errors], clean);
        }
        if (rules.Count == 0)
        {
            return new CollectionWindow(false, CollectionWindowMode.Invalid, [], ["Aucune plage reconnue."], clean);
        }
        return new CollectionWindow(true, CollectionWindowMode.Rules, [.. rules], [], clean);
    }

    private static List<int>? ParseDays(string token)
    {
        var days = new List<int>();
        if (token is "tous" or "tlj")
        {
            days.AddRange([0, 1, 2, 3, 4, 5, 6]);
            return days;
        }
        foreach (var item in token.Split(','))
        {
            if (item.Length == 0)
            {
                return null;
            }
            var bounds = item.Split('-');
            if (bounds.Length == 1)
            {
                if (!DayMap.TryGetValue(bounds[0], out var day))
                {
                    return null;
                }
                if (!days.Contains(day))
                {
                    days.Add(day);
                }
                continue;
            }
            if (bounds.Length != 2 || !DayMap.TryGetValue(bounds[0], out var first) || !DayMap.TryGetValue(bounds[1], out var last))
            {
                return null;
            }
            // Monday-based walk, so that « ven-lun » covers vendredi, samedi, dimanche and lundi.
            var index = (first + 6) % 7;
            var end = (last + 6) % 7;
            for (var guard = 0; guard < 7; guard++)
            {
                var current = (index + 1) % 7;
                if (!days.Contains(current))
                {
                    days.Add(current);
                }
                if (index == end)
                {
                    break;
                }
                index = (index + 1) % 7;
            }
        }
        return days;
    }

    /// <summary>True when the rule covers the local minute <paramref name="minute"/> of <paramref name="day"/>.</summary>
    public static bool Covers(CollectionWindowRule rule, DayOfWeek day, int minute)
    {
        ArgumentNullException.ThrowIfNull(rule);
        var d = (int)day;
        if (!rule.Overnight)
        {
            return rule.Days.Contains(d) && minute >= rule.StartMinute && minute < rule.EndMinute;
        }
        var previous = (d + 6) % 7;
        return (rule.Days.Contains(d) && minute >= rule.StartMinute) || (rule.Days.Contains(previous) && minute < rule.EndMinute);
    }

    private static bool IsOpenAt(CollectionWindow window, DateTime local) =>
        window.Rules.Any(r => Covers(r, local.DayOfWeek, local.Hour * 60 + local.Minute));

    /// <summary>State of a window at <paramref name="now"/> (local time of <paramref name="zone"/>), with its next change.</summary>
    public static CollectionWindowState StateAt(CollectionWindow window, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(zone);
        switch (window.Mode)
        {
            case CollectionWindowMode.Always:
                return new CollectionWindowState(true, window.Mode, null);
            case CollectionWindowMode.Never:
            case CollectionWindowMode.Invalid:
                return new CollectionWindowState(false, window.Mode, null);
        }
        var local = TimeZoneInfo.ConvertTime(now, zone).DateTime;
        var at = local.Date.AddHours(local.Hour).AddMinutes(local.Minute);
        var open = IsOpenAt(window, at);
        // The state can only change at a rule boundary: rule starts and ends over the coming eight days.
        var boundaries = new SortedSet<DateTime>();
        for (var offset = -1; offset <= 8; offset++)
        {
            var day = at.Date.AddDays(offset);
            foreach (var rule in window.Rules.Where(r => r.Days.Contains((int)day.DayOfWeek)))
            {
                boundaries.Add(day.AddMinutes(rule.StartMinute));
                boundaries.Add((rule.Overnight ? day.AddDays(1) : day).AddMinutes(rule.EndMinute));
            }
        }
        foreach (var moment in boundaries.Where(b => b > at))
        {
            if (IsOpenAt(window, moment) != open)
            {
                var offsetAt = zone.GetUtcOffset(moment);
                return new CollectionWindowState(open, window.Mode, new DateTimeOffset(moment, offsetAt).ToUniversalTime());
            }
        }
        return new CollectionWindowState(open, window.Mode, null);
    }

    /// <summary>One sentence for the settings view and the campaign confirmation (Format-DomeniaCollectionWindowState).</summary>
    public static string Sentence(CollectionWindowState state, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(zone);
        switch (state.Mode)
        {
            case CollectionWindowMode.Always:
                return "Travaux de fond permis à tout moment (aucune fenêtre de collecte).";
            case CollectionWindowMode.Never:
                return "Travaux de fond suspendus" + FrenchText.Colon + "aucune fenêtre de collecte. Les actions explicites restent possibles.";
            case CollectionWindowMode.Invalid:
                return "Fenêtre de collecte invalide" + FrenchText.Colon + "travaux de fond suspendus jusqu’à correction.";
        }
        var day = "";
        var time = "";
        if (state.NextChange is DateTimeOffset next)
        {
            var moment = TimeZoneInfo.ConvertTime(next, zone);
            var today = TimeZoneInfo.ConvertTime(now, zone).Date;
            time = moment.ToString("HH':'mm", CultureInfo.InvariantCulture);
            if (moment.Date == today.AddDays(1))
            {
                day = "demain";
            }
            else if (moment.Date != today)
            {
                day = DayNames[(int)moment.DayOfWeek];
            }
        }
        if (state.Open)
        {
            if (time.Length == 0)
            {
                return "Fenêtre de collecte ouverte.";
            }
            return day.Length > 0 ? "Fenêtre de collecte ouverte jusqu’à " + day + " " + time + "." : "Fenêtre de collecte ouverte jusqu’à " + time + ".";
        }
        if (time.Length == 0)
        {
            return "Fenêtre de collecte fermée" + FrenchText.Colon + "travaux de fond en pause.";
        }
        return day.Length > 0
            ? "Fenêtre de collecte fermée" + FrenchText.Colon + "travaux de fond en pause, reprise " + day + " à " + time + "."
            : "Fenêtre de collecte fermée" + FrenchText.Colon + "travaux de fond en pause, reprise à " + time + ".";
    }

    /// <summary>
    /// Week grid of a window (improvement of PAR-040: visual weekly editor): seven rows from Monday to Sunday, 48 half-hours
    /// each, true when the window is open at the start of the half-hour.
    /// </summary>
    public static ImmutableArray<ImmutableArray<bool>> WeekGrid(CollectionWindow window)
    {
        ArgumentNullException.ThrowIfNull(window);
        var rows = ImmutableArray.CreateBuilder<ImmutableArray<bool>>(7);
        DayOfWeek[] order = [DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday, DayOfWeek.Thursday, DayOfWeek.Friday, DayOfWeek.Saturday, DayOfWeek.Sunday];
        foreach (var day in order)
        {
            var cells = ImmutableArray.CreateBuilder<bool>(48);
            for (var half = 0; half < 48; half++)
            {
                cells.Add(window.Mode switch
                {
                    CollectionWindowMode.Always => true,
                    CollectionWindowMode.Rules => window.Rules.Any(r => Covers(r, day, half * 30)),
                    _ => false,
                });
            }
            rows.Add(cells.MoveToImmutable());
        }
        return rows.MoveToImmutable();
    }

    /// <summary>
    /// Text of a week grid (inverse of <see cref="WeekGrid"/>): days with the same open half-hours are grouped
    /// (« lun-ven 07:30-12:00 13:30-18:00; sam 08:00-12:00 »); a fully open week gives « toujours », an empty one « jamais ».
    /// </summary>
    public static string FromWeekGrid(IReadOnlyList<IReadOnlyList<bool>> grid)
    {
        ArgumentNullException.ThrowIfNull(grid);
        if (grid.Count != 7 || grid.Any(r => r is null || r.Count != 48))
        {
            throw new ArgumentException("A week grid has 7 rows of 48 half-hours.", nameof(grid));
        }
        if (grid.All(r => r.All(c => c)))
        {
            return "toujours";
        }
        if (grid.All(r => r.All(c => !c)))
        {
            return "jamais";
        }
        string[] names = ["lun", "mar", "mer", "jeu", "ven", "sam", "dim"];
        var signatures = grid.Select(Ranges).ToArray();
        var clauses = new List<string>();
        var index = 0;
        while (index < 7)
        {
            if (signatures[index].Length == 0)
            {
                index++;
                continue;
            }
            var end = index;
            while (end + 1 < 7 && signatures[end + 1] == signatures[index])
            {
                end++;
            }
            var days = end == index ? names[index] : names[index] + "-" + names[end];
            clauses.Add(signatures[index] == "00:00-24:00" ? days : days + " " + signatures[index]);
            index = end + 1;
        }
        return string.Join("; ", clauses);
    }

    private static string Ranges(IReadOnlyList<bool> cells)
    {
        var parts = new List<string>();
        var half = 0;
        while (half < 48)
        {
            if (!cells[half])
            {
                half++;
                continue;
            }
            var start = half;
            while (half < 48 && cells[half])
            {
                half++;
            }
            parts.Add(Clock(start * 30) + "-" + Clock(half * 30));
        }
        return string.Join(' ', parts);
    }

    private static string Clock(int minutes) =>
        (minutes / 60).ToString("00", CultureInfo.InvariantCulture) + ":" + (minutes % 60).ToString("00", CultureInfo.InvariantCulture);
}
