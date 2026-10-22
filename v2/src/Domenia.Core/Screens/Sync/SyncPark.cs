using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Result of a merge of two park surveys (Domenia 1 Merge-DomeniaParkState).</summary>
public sealed record ParkMerge(ImmutableDictionary<string, ParkEntry> State, int Added, int Replaced, int Total);

/// <summary>
/// Pure rules of the park survey kept by the base (Domenia 1 points 28 to 30 and FI-13): coverage of the stored survey, merge
/// by workstation where the most recent line wins (two consoles never destroy each other's readings), labels. No network.
/// </summary>
public static class SyncPark
{
    /// <summary>Attempts to take the lock file of the shared survey (Domenia 1: 12).</summary>
    public const int LockAttempts = 12;

    public static string Key(string computer)
    {
        ArgumentNullException.ThrowIfNull(computer);
        return computer.Trim().ToUpperInvariant();
    }

    public static string StatusLabel(ParkStatus status) => status switch
    {
        ParkStatus.Session => "Session ouverte",
        ParkStatus.Empty => "Aucune session",
        ParkStatus.Unreachable => "Injoignable",
        ParkStatus.Refused => "Accès refusé",
        _ => "Erreur de relevé",
    };

    public static Tone StatusTone(ParkStatus status) => status switch
    {
        ParkStatus.Session => Tone.Ok,
        ParkStatus.Empty => Tone.Info,
        ParkStatus.Unreachable => Tone.Warn,
        _ => Tone.Alert,
    };

    /// <summary>
    /// Coverage of the stored survey (Domenia 1 Get-DomeniaParkCoverageFigures and Get-DomeniaParkCoverageText): active
    /// workstations of the base (-1 while unknown), workstations surveyed, with a known user, set aside for inactivity, latest pass.
    /// </summary>
    public static ParkCoverage Coverage(IReadOnlyCollection<ParkEntry> entries, int activeMachines, int dormants, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(entries);
        var surveyed = entries.Count;
        var withSession = entries.Count(e => e.Status == ParkStatus.Session);
        DateTimeOffset? latest = entries.Count == 0 ? null : entries.Max(e => e.LastProbe);
        var c = SyncText.C;
        if (activeMachines < 0)
        {
            return new ParkCoverage(-1, surveyed, withSession, dormants, null, latest,
                FrenchText.Count(surveyed, "poste relevé", "postes relevés") + " en mémoire. La couverture du parc s’affiche dès que l’état de la base locale est lu.");
        }
        if (activeMachines == 0)
        {
            return new ParkCoverage(0, surveyed, withSession, dormants, null, latest, "Aucun poste indexé" + c + "construisez d’abord la base.");
        }
        var percent = Math.Round(100.0 * surveyed / activeMachines, 1);
        var text = FrenchText.Count(activeMachines, "poste actif", "postes actifs") + ", " + FrenchText.Count(surveyed, "relevé", "relevés") + " soit "
            + FrenchText.Percent(Math.Round(100.0 * surveyed / activeMachines, 0), 0) + ", " + FrenchText.Count(withSession, "avec un utilisateur connu", "avec un utilisateur connu");
        if (dormants > 0)
        {
            text += ", " + FrenchText.Count(dormants, "écarté", "écartés") + " faute d’activité depuis le dernier relevé";
        }
        if (latest is { } last)
        {
            var span = now - last;
            text += span.TotalDays >= 1
                ? ", dernier passage il y a " + FrenchText.Count((long)span.TotalDays, "jour", "jours")
                : ", dernier passage il y a " + FrenchText.Integer(Math.Max(0, (long)span.TotalHours)) + " h";
        }
        return new ParkCoverage(activeMachines, surveyed, withSession, dormants, percent, latest, text + ".");
    }

    /// <summary>Merge by workstation: the most recent probe wins; a line without a readable date never replaces a dated one.</summary>
    public static ParkMerge Merge(IReadOnlyDictionary<string, ParkEntry> baseState, IReadOnlyDictionary<string, ParkEntry> incoming)
    {
        ArgumentNullException.ThrowIfNull(baseState);
        ArgumentNullException.ThrowIfNull(incoming);
        var merged = ImmutableDictionary.CreateBuilder<string, ParkEntry>(StringComparer.Ordinal);
        foreach (var (key, entry) in baseState)
        {
            merged[Key(key)] = entry;
        }
        int added = 0, replaced = 0;
        foreach (var (key, entry) in incoming)
        {
            var k = Key(key);
            if (!merged.TryGetValue(k, out var old))
            {
                merged[k] = entry;
                added++;
            }
            else if (entry.LastProbe > old.LastProbe)
            {
                merged[k] = entry;
                replaced++;
            }
        }
        return new ParkMerge(merged.ToImmutable(), added, replaced, merged.Count);
    }

    public static ParkRow Row(ParkEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        return new ParkRow(Key(entry.Computer), entry.Computer, entry.LastProbe, entry.Status, StatusLabel(entry.Status), StatusTone(entry.Status), entry.User, entry.Attempts, entry.ProbedBy);
    }

    /// <summary>The lines where the shared survey and the local one differ, and which one wins (the most recent).</summary>
    public static ImmutableArray<ParkMergeRow> Differences(IReadOnlyDictionary<string, ParkEntry> local, IReadOnlyDictionary<string, ParkEntry> shared, int max = 200)
    {
        ArgumentNullException.ThrowIfNull(local);
        ArgumentNullException.ThrowIfNull(shared);
        var rows = new List<ParkMergeRow>();
        foreach (var key in local.Keys.Concat(shared.Keys).Select(Key).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
        {
            local.TryGetValue(key, out var mine);
            shared.TryGetValue(key, out var theirs);
            if (mine is not null && theirs is not null && mine.LastProbe == theirs.LastProbe)
            {
                continue;
            }
            var c = SyncText.C;
            if (mine is null)
            {
                rows.Add(new ParkMergeRow(theirs!.Computer, null, theirs.LastProbe, "shared", "Relevé d’une autre console" + c + StatusLabel(theirs.Status) + (theirs.ProbedBy is { Length: > 0 } by ? " (" + by + ")" : "")));
            }
            else if (theirs is null)
            {
                rows.Add(new ParkMergeRow(mine.Computer, mine.LastProbe, null, "local", "Relevé de cette console, ajouté au partage" + c + StatusLabel(mine.Status)));
            }
            else
            {
                var sharedWins = theirs.LastProbe > mine.LastProbe;
                rows.Add(new ParkMergeRow(mine.Computer, mine.LastProbe, theirs.LastProbe, sharedWins ? "shared" : "local",
                    sharedWins ? "Le partage est plus récent" + c + StatusLabel(theirs.Status) : "Cette console est plus récente" + c + StatusLabel(mine.Status)));
            }
            if (rows.Count >= max)
            {
                break;
            }
        }
        return [.. rows];
    }
}
