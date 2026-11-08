using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Result of a merge of two park surveys (Domenia 1 Merge-DomeniaParkState).</summary>
public sealed record ParkMerge(ImmutableDictionary<string, ParkEntry> State, int Added, int Replaced, int Total);

/// <summary>One workstation result of a park probe (session seen, no session, unreachable…), as a probe delivers it.</summary>
public sealed record ParkProbe(string Computer, DateTimeOffset At, ParkStatus Status, string? User, string? ProbedBy);

/// <summary>The park state after a reload of the stored survey and the results that waited for it (Domenia 1 ParkStateReload).</summary>
public sealed record ParkReload(ImmutableDictionary<string, ParkEntry> State, int Applied, string? Text);

/// <summary>What became of a synchronisation of the shared survey (Domenia 1 ParkSharedSync).</summary>
public enum SharedSyncOutcome
{
    /// <summary>Lock obtained, file read and merged in memory.</summary>
    Merged,

    /// <summary>Lock held by another console for every attempt: work in local, new attempt later.</summary>
    LockBusy,

    /// <summary>Share out of reach: work in local, noted in the Parc journal.</summary>
    Unreachable,
}

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

    /// <summary>Prefix that marks a stored line as an observation of another console (shared survey), never an AD identity.</summary>
    public const string SharedPrefix = "PARTAGE_";

    /// <summary>
    /// Status of a stored line (Domenia 1 park_state.status and its shared TSV): the words of the engine are French, the English
    /// spellings stay understood. Case and surrounding spaces are ignored; one <see cref="SharedPrefix"/> is removed only at the
    /// start, so a repeated or misplaced prefix never becomes a certain status. An empty, null or unknown value is an error.
    /// </summary>
    public static ParkStatus StoredStatus(string? value)
    {
        var token = value?.Trim();
        if (string.IsNullOrEmpty(token))
        {
            return ParkStatus.Error;
        }
        if (token.StartsWith(SharedPrefix, StringComparison.OrdinalIgnoreCase))
        {
            token = token[SharedPrefix.Length..].Trim();
        }
        return token.ToUpperInvariant() switch
        {
            "CONFIRME" or "CONFIRMED" or "SESSION" => ParkStatus.Session,
            "LU" or "EMPTY" => ParkStatus.Empty,
            "PING_MUET" or "UNREACHABLE" => ParkStatus.Unreachable,
            "REFUSE" or "AUTH_REJETEE" or "REFUSED" => ParkStatus.Refused,
            "DELAI" or "ERREUR" => ParkStatus.Error,
            _ => ParkStatus.Error,
        };
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
            // Under one day, the words of the engine (« il y a 3 min », « il y a 2 h »): never « il y a 0 h ».
            text += span.TotalDays >= 1
                ? ", dernier passage il y a " + FrenchText.Count((long)span.TotalDays, "jour", "jours")
                : ", dernier passage " + SyncText.Elapsed(last, now);
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

    /// <summary>Results kept while the stored survey is read again (Domenia 1: 16 at most, the oldest dropped first).</summary>
    public const int DeferredLimit = 16;

    /// <summary>Delay before the new attempt when the lock of the shared survey was not obtained.</summary>
    public static readonly TimeSpan LockRetryDelay = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Applies one probe result (Domenia 1 Complete-DomeniaParkSweepUi): the attempt counter builds on the stored one (+1), so a
    /// result applied before the stored survey is loaded would restart from zero: such a result waits (<see cref="Defer"/>).
    /// </summary>
    public static ParkEntry Apply(IReadOnlyDictionary<string, ParkEntry> state, ParkProbe probe)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(probe);
        var attempts = state.TryGetValue(Key(probe.Computer), out var old) ? Math.Max(0, old.Attempts) + 1 : 1;
        return new ParkEntry(probe.Computer, probe.At, probe.Status, probe.Status == ParkStatus.Session ? probe.User : null, attempts, probe.ProbedBy);
    }

    /// <summary>Keeps a result that arrived during the reload of the stored survey; the oldest leaves beyond <see cref="DeferredLimit"/>.</summary>
    public static ImmutableArray<ParkProbe> Defer(ImmutableArray<ParkProbe> waiting, ParkProbe probe)
    {
        ArgumentNullException.ThrowIfNull(probe);
        ImmutableArray<ParkProbe> list = waiting.IsDefault ? [] : waiting;
        list = list.Add(probe);
        return list.Length > DeferredLimit ? list.RemoveRange(0, list.Length - DeferredLimit) : list;
    }

    /// <summary>
    /// End of a reload (Domenia 1 Complete-DomeniaParkStateReloadUi): the stored rows are the base, what this session saw since
    /// wins when more recent, then the waiting results are applied in their order of arrival on top of the stored counters.
    /// </summary>
    public static ParkReload Reload(IReadOnlyDictionary<string, ParkEntry> stored, IReadOnlyDictionary<string, ParkEntry> session, IReadOnlyList<ParkProbe> waiting)
    {
        ArgumentNullException.ThrowIfNull(stored);
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(waiting);
        var state = Merge(stored, session).State.ToBuilder();
        foreach (var probe in waiting)
        {
            state[Key(probe.Computer)] = Apply(state, probe);
        }
        var text = waiting.Count == 0 ? null
            : FrenchText.Count(waiting.Count, "résultat de poste arrivé pendant la relecture du relevé a été appliqué", "résultats de poste arrivés pendant la relecture du relevé ont été appliqués")
                + " ensuite" + SyncText.C + "les tentatives partent des compteurs enregistrés.";
        return new ParkReload(state.ToImmutable(), waiting.Count, text);
    }

    /// <summary>
    /// What a synchronisation of the shared survey tells the operator (Domenia 1 Start-DomeniaParkSharedSync and its worker):
    /// a lock not obtained or a share out of reach never blocks the console, the work goes on in local.
    /// </summary>
    public static string SharedText(SharedSyncOutcome outcome, string path, int lockAttempts, DateTimeOffset? retryAt, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(zone);
        var c = SyncText.C;
        return outcome switch
        {
            SharedSyncOutcome.LockBusy => "Verrou du relevé partagé non obtenu après " + FrenchText.Count(lockAttempts, "essai", "essais") + c + "une autre console l’écrit. Domenia travaille en local"
                + (retryAt is { } at ? SyncText.Semi + " nouvel essai à " + TimeZoneInfo.ConvertTime(at, zone).ToString("HH':'mm':'ss", System.Globalization.CultureInfo.InvariantCulture) + "." : "."),
            SharedSyncOutcome.Unreachable => "Partage inaccessible (" + path + ")" + c + "Domenia travaille en local, noté dans le journal Parc. Rien n’a été lu ni écrit.",
            _ => "Verrou obtenu au " + (lockAttempts <= 1 ? "1ᵉʳ" : FrenchText.Integer(lockAttempts) + "ᵉ") + " essai sur " + FrenchText.Integer(LockAttempts) + ".",
        };
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
