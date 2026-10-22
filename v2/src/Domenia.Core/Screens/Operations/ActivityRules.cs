using System.Collections.Immutable;
using System.Globalization;
using System.Text;

namespace Domenia.Core;

/// <summary>
/// Pure rules of the Opérations screen (Domenia 1 Domenia-Observability.Model.ps1, Domenia-Engine.Model.ps1 and
/// Domenia-Experience.Model.ps1): outcome catalogue, phases, durations and volumes in French, which tasks are listed, which leave
/// a full ring first, advice after the end, cancellation texts, summaries, latency summaries, slowness verdicts and paused
/// sources. No clock, culture or time zone is read inside: they are inputs.
/// </summary>
public static class ActivityRules
{
    /// <summary>Bounds of the observability state kept in memory for one session (Domenia 1 Get-DomeniaTraceLimits).</summary>
    public const int MaxTraces = 64;
    public const int MaxEvents = 32;
    public const int MaxSlowEvents = 16;
    public const int NameLength = 80;
    public const int DetailLength = 120;

    /// <summary>Measures kept per response time category and per operation (Domenia 1: 512 last measures).</summary>
    public const int SamplesPerSeries = 512;

    /// <summary>A 95th percentile is stated from 20 measures on (Domenia 1 Get-DomeniaLatencySummary).</summary>
    public const int MinimumForP95 = 20;

    /// <summary>An operation longer than this enters the slowness list (Domenia 1 OPE-034: more than 5 s).</summary>
    public static readonly TimeSpan SlowTotal = TimeSpan.FromSeconds(5);

    private static readonly OutcomeInfo[] Outcomes =
    [
        new(TaskOutcome.Succeeded, "Terminée", Tone.Ok, "check", 0),
        new(TaskOutcome.Superseded, "Remplacée par une demande plus récente", Tone.Info, "refresh", 1),
        new(TaskOutcome.Withdrawn, "Retirée de la file avant envoi", Tone.Info, "x", 1),
        new(TaskOutcome.Stopped, "Arrêtée", Tone.Warn, "pause", 2),
        new(TaskOutcome.TimedOut, "Délai dépassé", Tone.Warn, "clock", 3),
        new(TaskOutcome.Refused, "Refusée avant envoi", Tone.Alert, "lock", 4),
        new(TaskOutcome.Failed, "Échec", Tone.Alert, "alert", 5),
        new(TaskOutcome.Unknown, "Résultat inconnu" + FrenchText.Colon + "relire avant toute nouvelle tentative", Tone.Warn, "eye", 6),
    ];

    /// <summary>The catalogue, best end first.</summary>
    public static ImmutableArray<OutcomeInfo> Catalogue => [.. Outcomes];

    public static OutcomeInfo Outcome(TaskOutcome code) => Outcomes.First(o => o.Code == code);

    /// <summary>The worse of two ends (the end of a task is the worst end of its steps).</summary>
    public static TaskOutcome Worst(TaskOutcome? current, TaskOutcome next) =>
        current is TaskOutcome known && Outcome(known).Rank > Outcome(next).Rank ? known : next;

    /// <summary>« Lecture locale », « Lecture réseau », « Écriture »…</summary>
    public static string KindLabel(TaskKind kind, bool simulation) => kind switch
    {
        TaskKind.Local => "Calcul local",
        TaskKind.LocalRead => "Lecture locale",
        TaskKind.NetworkRead => simulation ? "Lecture (annuaire fictif)" : "Lecture réseau",
        TaskKind.LocalWrite => "Écriture locale",
        TaskKind.Write => simulation ? "Écriture simulée" : "Écriture",
        _ => "Lot de collecte",
    };

    /// <summary>Access the task needs, so that a refusal reads against it (Domenia 1 point 46, Get-DomeniaOperationRequirement).</summary>
    public static string Access(TaskKind kind, bool simulation) => kind switch
    {
        TaskKind.Local => "Aucun accès" + FrenchText.Colon + "calcul en mémoire, ni disque ni réseau.",
        TaskKind.LocalRead => simulation
            ? "Lecture locale" + FrenchText.Colon + "annuaire fictif en mémoire, reçus ou préférences de la simulation."
            : "Lecture locale" + FrenchText.Colon + "base locale, reçus ou préférences de l’application.",
        TaskKind.NetworkRead => simulation
            ? "Lecture de l’annuaire fictif" + FrenchText.Colon + "aucune requête ne part."
            : "Lecture de l’annuaire ou des postes avec le compte de la session, après votre geste.",
        TaskKind.LocalWrite => "Écriture des données locales de l’application seulement (préférences, reçus, documents exportés).",
        TaskKind.Write => simulation
            ? "Écriture sur l’annuaire fictif en mémoire, sans aucun effet réel."
            : "Écriture dans l’annuaire" + FrenchText.Colon + "droits du compte de la session sur l’objet.",
        _ => simulation ? "Relevé fictif des postes" + FrenchText.Colon + "aucune sonde ne part." : "Relevé des postes (ping, WMI) après confirmation.",
    };

    /// <summary>True when the kind can be stopped: reads and batches only, never a write (Domenia 1 Test-DomeniaExperienceCanCancel).</summary>
    public static bool IsStoppable(TaskKind kind) => kind is TaskKind.Local or TaskKind.LocalRead or TaskKind.NetworkRead or TaskKind.Batch;

    /// <summary>
    /// A request of the operator: a network read (always after a gesture), a local or directory write, or a write plan. Local
    /// reads and computations may be automatic (screen loads, refreshes).
    /// </summary>
    public static bool IsForeground(string operation, TaskKind kind)
    {
        ArgumentNullException.ThrowIfNull(operation);
        return kind is TaskKind.NetworkRead or TaskKind.LocalWrite or TaskKind.Write or TaskKind.Batch
            || operation.EndsWith(".plan", StringComparison.Ordinal);
    }

    /// <summary>
    /// « Dernières opérations » lists the requests of the operator and, among the automatic ones, only those that did not end
    /// well (out of time, refused, failed, unknown): a burst of automatic reads never hides a write (Domenia 1 Test-DomeniaTraceListed).
    /// </summary>
    public static bool IsListed(bool foreground, TaskKind kind, bool open, TaskOutcome? outcome)
    {
        if (foreground || kind == TaskKind.Write)
        {
            return true;
        }
        return !open && outcome is TaskOutcome end && Outcome(end).Rank >= 3;
    }

    /// <summary>
    /// Which tasks leave a full ring (Domenia 1 Select-DomeniaTraceEviction): finished automatic ones first, then finished operator
    /// requests, oldest first; an open one only as a last resort.
    /// </summary>
    public static ImmutableArray<string> Eviction(IEnumerable<(string Id, bool Open, bool Listed, DateTimeOffset StartedAt, DateTimeOffset LastAt)> tasks, int maximum = MaxTraces)
    {
        ArgumentNullException.ThrowIfNull(tasks);
        var all = tasks.ToList();
        var excess = all.Count - Math.Max(1, maximum);
        if (excess <= 0)
        {
            return [];
        }
        var background = all.Where(t => !t.Open && !t.Listed).OrderBy(t => t.LastAt);
        var finished = all.Where(t => !t.Open && t.Listed).OrderBy(t => t.LastAt);
        var open = all.Where(t => t.Open).OrderBy(t => t.StartedAt);
        return [.. background.Concat(finished).Concat(open).Take(excess).Select(t => t.Id)];
    }

    /// <summary>Short reference read on a screen and searched in the technical journal: the first eight characters of the identifier.</summary>
    public static string Reference(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        var compact = new string([.. id.Where(char.IsAsciiLetterOrDigit)]).ToLowerInvariant();
        return compact.Length < 8 ? "" : compact[..8];
    }

    /// <summary>French duration for an operator: « &lt; 1 ms », « 850 ms », « 2,3 s », « 1 min 05 s »; a negative value was not measured.</summary>
    public static string Duration(double milliseconds)
    {
        if (double.IsNaN(milliseconds) || milliseconds < 0)
        {
            return "non mesurée";
        }
        if (milliseconds < 1)
        {
            return "<" + FrenchText.Nbsp + "1" + FrenchText.Nbsp + "ms";
        }
        if (milliseconds < 1000)
        {
            return FrenchText.Integer((long)Math.Round(milliseconds, MidpointRounding.AwayFromZero)) + FrenchText.Nbsp + "ms";
        }
        if (milliseconds < 60_000)
        {
            return FrenchText.Decimal(milliseconds / 1000.0, 1) + FrenchText.Nbsp + "s";
        }
        var whole = (long)Math.Round(milliseconds / 1000.0, MidpointRounding.AwayFromZero);
        return FrenchText.Integer(whole / 60) + FrenchText.Nbsp + "min " + (whole % 60).ToString("00", CultureInfo.InvariantCulture) + FrenchText.Nbsp + "s";
    }

    /// <summary>Number of items handled; an incomplete count says « au moins »; a negative one was not measured.</summary>
    public static string Volume(long volume, bool complete = true)
    {
        if (volume < 0)
        {
            return "volume non mesuré";
        }
        var text = FrenchText.Count(volume, "élément", "éléments");
        return complete ? text : "au moins " + text;
    }

    /// <summary>Single-line, bounded text for status lines and tips (Domenia 1 ConvertTo-DomeniaFlatText).</summary>
    public static string Flat(string? text, int maximum)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var builder = new StringBuilder(text.Length);
        var space = false;
        foreach (var c in text.Trim())
        {
            if (char.IsWhiteSpace(c) && c != ' ' && c != ' ')
            {
                space = true;
                continue;
            }
            if (space && builder.Length > 0)
            {
                builder.Append(' ');
            }
            space = false;
            builder.Append(c);
        }
        var flat = builder.ToString();
        return maximum > 3 && flat.Length > maximum ? flat[..(maximum - 1)] + "…" : flat;
    }

    /// <summary>« Terminée », « En cours », « Arrêt demandé »… for the state column.</summary>
    public static string StateLabel(TaskState state, TaskOutcome? outcome) => state switch
    {
        TaskState.Queued => "En attente",
        TaskState.Running => "En cours",
        TaskState.StopRequested => "Arrêt demandé",
        TaskState.Cleanup => "Nettoyage",
        _ => outcome is TaskOutcome end ? Outcome(end).Label : "Terminée",
    };

    /// <summary>Sentence of an open task (Domenia 1 Get-DomeniaExperienceTaskRow), access required included.</summary>
    public static string OpenDetail(TaskKind kind, TaskState state, bool simulation)
    {
        var head = state switch
        {
            TaskState.Queued => "Demande en file" + FrenchText.Colon + "rien n’est encore envoyé.",
            TaskState.StopRequested => "Arrêt demandé" + FrenchText.Colon + "la fin de la lecture n’est pas encore confirmée.",
            TaskState.Cleanup => "Lecture détachée de l’interface" + FrenchText.Colon + "son appel est encore en cours de nettoyage.",
            _ when kind == TaskKind.Write => "Écriture en cours" + FrenchText.Colon + "elle va jusqu’au bout puis l’objet est relu. Aucun rejeu automatique.",
            _ when kind == TaskKind.LocalWrite => "Écriture locale en cours" + FrenchText.Colon + "elle se termine d’elle-même, sans arrêt possible.",
            _ => "Traitement actif. Aucun résultat final annoncé.",
        };
        return head + " Accès requis" + FrenchText.Colon + LowerFirst(Access(kind, simulation));
    }

    /// <summary>Fixed cancellation texts (Domenia 1 Get-DomeniaCancelStatusText, OPE-018).</summary>
    public static string CancelText(string label, TaskState state, TaskKind kind)
    {
        ArgumentNullException.ThrowIfNull(label);
        var name = FrenchText.Quote(label);
        if (kind == TaskKind.Write)
        {
            return "Écriture " + name + FrenchText.Colon + "non annulable après envoi. Attente de la relecture de vérification.";
        }
        if (kind == TaskKind.LocalWrite)
        {
            return "Écriture locale " + name + FrenchText.Colon + "non annulable ; elle se termine d’elle-même.";
        }
        return state switch
        {
            TaskState.Queued => "Demande retirée de la file avant tout envoi" + FrenchText.Colon + label + ".",
            TaskState.StopRequested => "Arrêt demandé" + FrenchText.Colon + label + ". La lecture est encore active.",
            TaskState.Cleanup => "Lecture détachée de l’interface" + FrenchText.Colon + label + ". Son appel reste compté jusqu’à sa fin réelle.",
            TaskState.Completed => "Lecture arrêtée" + FrenchText.Colon + label + ".",
            _ => "Lecture en cours" + FrenchText.Colon + label + ".",
        };
    }

    /// <summary>
    /// What the operator can do after the end of a task (Domenia 1 Get-DomeniaTraceAdvice): never an automatic retry, and a write is
    /// never replayed. The reference ties the advice to the line of the technical journal. Empty for a success.
    /// </summary>
    public static string? Advice(TaskOutcome? outcome, TaskKind kind, string? category, string reference)
    {
        var refText = reference.Length == 8 && reference.All(char.IsAsciiLetterOrDigit)
            ? " Référence " + reference + " dans le journal technique."
            : "";
        const string Receipt = " Son reçu, s’il attend une vérification, s’ouvre dans l’onglet Reçus d’écriture (filtre « À vérifier »).";
        var isWrite = kind == TaskKind.Write;
        var write = "Écriture non confirmée" + FrenchText.Colon + "relisez l’objet avant toute nouvelle tentative ; Domenia ne rejoue jamais une écriture." + Receipt;
        switch (outcome)
        {
            case null:
            case TaskOutcome.Succeeded:
                return null;
            case TaskOutcome.Superseded:
                return "Une demande plus récente a pris sa place" + FrenchText.Colon + "rien à faire.";
            case TaskOutcome.Withdrawn:
                return "Retirée de la file avant tout envoi" + FrenchText.Colon + "aucun appel n’a été fait.";
            case TaskOutcome.Refused:
                return "Refusée avant envoi" + FrenchText.Colon + "rien n’a été fait. " + RefusalHint(category) + refText;
            case TaskOutcome.Unknown:
                return "Résultat inconnu" + FrenchText.Colon + "relisez l’objet avant toute nouvelle tentative ; Domenia ne rejoue jamais une écriture." + Receipt + refText;
            case TaskOutcome.Stopped:
                return isWrite
                    ? write + refText
                    : "Arrêtée sur demande" + FrenchText.Colon + "ce qui était déjà lu est conservé. Relancez l’action depuis son écran si besoin.";
            case TaskOutcome.TimedOut:
                return isWrite
                    ? write + refText
                    : "Délai dépassé" + FrenchText.Colon + "la cible ou le réseau n’a pas répondu à temps. Aucune relance automatique ; relancez quand la cible est joignable." + refText;
            default:
                var text = category switch
                {
                    "account.rejected" or "account.locked" or "account.paused" =>
                        "Compte refusé ou suspendu" + FrenchText.Colon + "vérifiez-le avant de relancer. Aucune nouvelle tentative n’est faite automatiquement (protection contre le verrouillage).",
                    "access.denied" => "Droit insuffisant pour ce compte sur cette ressource" + FrenchText.Colon + "utilisez un compte autorisé, puis relancez l’action.",
                    "network.timeout" or "network.unavailable" => "Cible ou réseau indisponible" + FrenchText.Colon + "relancez quand la cible est joignable.",
                    _ => "Échec imprévu" + FrenchText.Colon + "le détail technique est dans le journal. Relancez l’action depuis son écran après sa lecture.",
                };
                return (isWrite ? write + " " : "") + text + refText;
        }
    }

    /// <summary>What a refusal code means for the operator (fixed texts, never the message of the refusal).</summary>
    public static string RefusalHint(string? category) => category switch
    {
        DomeniaErrors.SourceUnavailable => "La lecture de l’annuaire arrive avec Domenia.Ad (vague 3)" + FrenchText.Colon + "essayez en simulation.",
        DomeniaErrors.SimulationUnavailable => "Non disponible en simulation" + FrenchText.Colon + "aucune connexion au poste ni à l’annuaire.",
        DomeniaErrors.SimulationReadOnly or DomeniaErrors.WriteUnavailable => "Seule la porte du circuit d’écriture écrit" + FrenchText.Colon + "plan, confirmation, reçu et relecture.",
        DomeniaErrors.ArgumentsInvalid => "Demande mal formée par l’interface" + FrenchText.Colon + "signalez-la avec sa référence.",
        DomeniaErrors.ScopeTooWide => "Choisissez une OU de travail" + FrenchText.Colon + "la mesure des postes ne vise jamais tout le domaine.",
        WriteErrors.TargetPending => "Une écriture précédente sur cet objet reste à vérifier" + FrenchText.Colon + "relisez son reçu ou consignez une revue.",
        WriteErrors.ReceiptUnavailable => "Reçus d’écriture illisibles" + FrenchText.Colon + "aucune écriture n’est admise tant qu’ils ne sont pas relus.",
        WriteErrors.NothingToDo => "L’objet était déjà dans l’état demandé" + FrenchText.Colon + "aucune écriture n’était nécessaire.",
        string code when code.StartsWith("write.", StringComparison.Ordinal) => "Préparez de nouveau l’écriture depuis son écran" + FrenchText.Colon + "l’objet sera relu.",
        _ => "Relancez l’action depuis son écran une fois la cause levée.",
    };

    /// <summary>
    /// End of a task from the code of an expected refusal of the engine: « …Failed » codes are failures, an outcome kept unknown is
    /// unknown, every other code is a refusal before anything was done.
    /// </summary>
    public static TaskOutcome OutcomeOfCode(string? code)
    {
        if (string.IsNullOrEmpty(code))
        {
            return TaskOutcome.Failed;
        }
        if (code.EndsWith("Failed", StringComparison.Ordinal) || code.EndsWith(".failed", StringComparison.Ordinal))
        {
            return TaskOutcome.Failed;
        }
        return code.EndsWith("outcomeUnknown", StringComparison.Ordinal) ? TaskOutcome.Unknown : TaskOutcome.Refused;
    }

    /// <summary>« 2 en cours · 1 arrêt demandé » or « Aucune tâche », with the resources held (Domenia 1 OPE-021).</summary>
    public static TaskSummary Summary(int running, int queued, int stopRequested, int cleanup, int resources)
    {
        var active = running + stopRequested + cleanup;
        var parts = new List<string>();
        if (running > 0)
        {
            parts.Add(FrenchText.Integer(running) + " en cours");
        }
        if (queued > 0)
        {
            parts.Add(FrenchText.Integer(queued) + " en attente");
        }
        if (stopRequested > 0)
        {
            parts.Add(FrenchText.Integer(stopRequested) + " arrêt demandé");
        }
        if (cleanup > 0)
        {
            parts.Add(FrenchText.Integer(cleanup) + " nettoyage");
        }
        var resourcesText = resources > 0
            ? "Ressources détenues" + FrenchText.Colon + FrenchText.Count(resources, "jeton d’arrêt", "jetons d’arrêt") + " (un par lecture en cours)"
            : "Aucune ressource détenue";
        return new TaskSummary(running, queued, stopRequested, cleanup, active, active + queued, parts.Count == 0 ? "Aucune tâche" : string.Join(" · ", parts), resources, resourcesText);
    }

    /// <summary>Median, 95th percentile and maximum, nearest rank; below <paramref name="minimumForP95"/> measures the 95th percentile is not stated.</summary>
    public static LatencySummary Latency(IEnumerable<double> samples, int minimumForP95 = MinimumForP95)
    {
        ArgumentNullException.ThrowIfNull(samples);
        var kept = samples.Where(v => !double.IsNaN(v) && !double.IsInfinity(v) && v >= 0).Order().ToArray();
        if (kept.Length == 0)
        {
            return new LatencySummary(0, null, null, null, false, minimumForP95);
        }
        var n = kept.Length;
        static int Rank(double p, int n) => Math.Min(n - 1, Math.Max(0, (int)Math.Ceiling(p * n) - 1));
        var stated = n >= minimumForP95;
        return new LatencySummary(n, Math.Round(kept[Rank(0.50, n)], 2), stated ? Math.Round(kept[Rank(0.95, n)], 2) : null, Math.Round(kept[n - 1], 2), stated, minimumForP95);
    }

    /// <summary>One sentence per category (Domenia 1 Format-DomeniaLatencySummaryText); an unmeasured category stays unmeasured.</summary>
    public static string LatencyText(string label, LatencySummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        if (summary.Count <= 0)
        {
            return label + FrenchText.Colon + "aucune mesure dans cette session.";
        }
        var count = FrenchText.Count(summary.Count, "mesure", "mesures");
        var median = Duration(summary.P50 ?? -1);
        var max = Duration(summary.Max ?? -1);
        return summary.P95Stated
            ? label + FrenchText.Colon + "médiane " + median + " ; 95" + FrenchText.Nbsp + "% sous " + Duration(summary.P95 ?? -1) + " ; maximum " + max + " (" + count + ")."
            : label + FrenchText.Colon + "médiane " + median + " ; maximum " + max + " (" + count + ", trop peu pour un 95e centile).";
    }

    /// <summary>Upper bounds (ms) of the 8 bins of a response time histogram: 10 ms, 50 ms, 100 ms, 250 ms, 500 ms, 1 s, 5 s, beyond.</summary>
    public static ImmutableArray<double> HistogramBounds { get; } = [10, 50, 100, 250, 500, 1000, 5000, double.PositiveInfinity];

    public static ImmutableArray<string> HistogramLabels { get; } =
        ["≤\u00A010\u00A0ms", "≤\u00A050\u00A0ms", "≤\u00A0100\u00A0ms", "≤\u00A0250\u00A0ms", "≤\u00A0500\u00A0ms", "≤\u00A01\u00A0s", "≤\u00A05\u00A0s", ">\u00A05\u00A0s"];

    public static ImmutableArray<int> Histogram(IEnumerable<double> samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        var bins = new int[HistogramBounds.Length];
        foreach (var value in samples)
        {
            if (double.IsNaN(value) || value < 0)
            {
                continue;
            }
            for (var i = 0; i < HistogramBounds.Length; i++)
            {
                if (value <= HistogramBounds[i])
                {
                    bins[i]++;
                    break;
                }
            }
        }
        return [.. bins];
    }

    /// <summary>
    /// Explains a slowness by the operation, its phases and its volume (Domenia 1 Get-DomeniaSlownessVerdict). A phase that was not
    /// measured is said so, never counted as zero. Slow: the measured phases together exceed <paramref name="totalThresholdMs"/>.
    /// </summary>
    public static (bool Slow, string Phase, double DurationMs, double TotalMs, string Text) Slowness(
        string name, double queueMs, double engineMs, long volume, double totalThresholdMs = 5000)
    {
        (string Code, string Label, double Value)[] segments =
        [
            ("queue", "l’attente du canal d’écriture", queueMs),
            ("engine", "le traitement dans le moteur", engineMs),
        ];
        double total = 0;
        var count = 0;
        var phase = "";
        var label = "";
        double max = -1;
        foreach (var (code, segmentLabel, value) in segments)
        {
            if (value < 0)
            {
                continue;
            }
            total += value;
            count++;
            if (value > max)
            {
                max = value;
                phase = code;
                label = segmentLabel;
            }
        }
        var title = string.IsNullOrWhiteSpace(name) ? "Opération" : Flat(name, NameLength);
        if (count == 0)
        {
            return (false, "", -1, -1, title + FrenchText.Colon + "durée non mesurée.");
        }
        var text = title + FrenchText.Colon + Duration(total) + ", surtout " + label + " (" + Duration(max) + ")";
        text += volume >= 0 ? " pour " + Volume(volume) : " ; volume non mesuré";
        text += " (file " + Duration(queueMs) + ", moteur " + Duration(engineMs) + ", interface non mesurée).";
        return (total > totalThresholdMs, phase, max, total, text);
    }

    /// <summary>
    /// Plain lines for the paused or recovering sources (Domenia 1 Get-DomeniaProviderStateSummary, point 160): healthy sources are
    /// not listed and no line ever says the whole directory is unreachable. Sites and whole providers get one line each; single
    /// workstations are counted per provider and state, with a few names.
    /// </summary>
    public static ImmutableArray<string> ProviderLines(IEnumerable<ProviderState> states, DateTimeOffset now, TimeZoneInfo zone, int maxNames = 3)
    {
        ArgumentNullException.ThrowIfNull(states);
        ArgumentNullException.ThrowIfNull(zone);
        var lines = new List<string>();
        var groups = new List<(string Label, ProviderStateKind Kind, List<string> Names, DateTimeOffset? Until, int Limit)>();
        foreach (var state in states.OrderBy(s => s.Provider, StringComparer.Ordinal).ThenBy(s => s.Target ?? "", StringComparer.Ordinal))
        {
            var label = ProviderLabel(state.Provider);
            var kind = state.Kind;
            if (kind == ProviderStateKind.Paused && (state.Until is not DateTimeOffset until || until <= now))
            {
                // A pause that is over is healthy again.
                continue;
            }
            if (state.Target is string target && !target.StartsWith("group:", StringComparison.Ordinal))
            {
                var index = groups.FindIndex(g => g.Label == label && g.Kind == kind);
                if (index < 0)
                {
                    groups.Add((label, kind, [target], state.Until, Math.Max(1, state.RecoveryLimit)));
                }
                else
                {
                    var group = groups[index];
                    group.Names.Add(target);
                    var later = group.Until is DateTimeOffset a && state.Until is DateTimeOffset b ? (a > b ? a : b) : group.Until ?? state.Until;
                    groups[index] = (group.Label, group.Kind, group.Names, later, Math.Max(1, state.RecoveryLimit));
                }
                continue;
            }
            var where = state.Target is string site ? "site " + site["group:".Length..] : "toutes cibles";
            lines.Add(label + " · " + where + FrenchText.Colon + ProviderSentence(kind, state.Until, state.RecoveryLimit, zone, single: true));
        }
        foreach (var (label, kind, names, until, limit) in groups)
        {
            if (names.Count == 1)
            {
                lines.Add(label + " · " + names[0] + FrenchText.Colon + ProviderSentence(kind, until, limit, zone, single: true));
                continue;
            }
            var shown = names.Take(Math.Max(1, maxNames)).ToList();
            var list = string.Join(", ", shown) + (names.Count > shown.Count ? " et " + FrenchText.Integer(names.Count - shown.Count) + " autre(s)" : "");
            lines.Add(label + " · " + FrenchText.Integer(names.Count) + " cibles (" + list + ")" + FrenchText.Colon + ProviderSentence(kind, until, limit, zone, single: false));
        }
        return [.. lines];
    }

    private static string ProviderLabel(string provider) => provider switch
    {
        "Directory" => "annuaire",
        "Cim" => "WMI",
        "Wts" => "sessions",
        "Network" => "réseau",
        "Storage" => "base locale",
        "Local" => "local",
        _ => provider,
    };

    private static string ProviderSentence(ProviderStateKind kind, DateTimeOffset? until, int limit, TimeZoneInfo zone, bool single)
    {
        var time = until is DateTimeOffset at ? TimeZoneInfo.ConvertTime(at, zone).ToString("HH':'mm':'ss", CultureInfo.InvariantCulture) : "—";
        return kind switch
        {
            ProviderStateKind.Blocked => "identifiants rejetés, reprise après un changement de compte explicite.",
            ProviderStateKind.Paused => single ? "lectures de fond suspendues jusqu’à " + time + "." : "lectures de fond suspendues, au plus tard jusqu’à " + time + ".",
            _ => single
                ? "reprise progressive (" + FrenchText.Integer(Math.Max(1, limit)) + " lecture(s) de fond à la fois)."
                : "reprise progressive, une lecture de fond de plus à chaque réponse.",
        };
    }

    /// <summary>
    /// One sentence for the local save state, never claiming a save that did not happen (Domenia 1 Get-DomeniaPersistenceLabel,
    /// OPE-033). Priority: storage unavailable, suspended, conflicts, failures, pending, saved.
    /// </summary>
    public static string PersistenceLabel(int pending, int failed, bool suspended, bool unavailable, int conflicts, string? savedAt = null)
    {
        if (unavailable)
        {
            return "En mémoire uniquement" + FrenchText.Colon + "stockage local indisponible ou désactivé dans ce mode, rien n’est enregistré sur le disque.";
        }
        if (suspended)
        {
            return "En mémoire uniquement" + FrenchText.Colon + "enregistrement suspendu après des échecs.";
        }
        if (conflicts > 0)
        {
            return "En mémoire" + FrenchText.Colon + FrenchText.Integer(conflicts) + " modification(s) faite(s) ailleurs, non enregistrée(s).";
        }
        if (failed > 0)
        {
            return "En mémoire" + FrenchText.Colon + FrenchText.Integer(failed) + " enregistrement(s) en échec dans cette session" + FrenchText.Colon + "la valeur vaut pour la session.";
        }
        if (pending > 0)
        {
            return "En mémoire" + FrenchText.Colon + FrenchText.Integer(pending) + " modification(s) à enregistrer.";
        }
        return savedAt is null ? "Enregistré." : "Enregistré (dernière écriture locale à " + savedAt + ").";
    }

    /// <summary>SQLite lock wait (Domenia 1 Get-DomeniaSqliteBusyTimeoutMs): 2 500 ms by default, clamped to 100..5 000 ms.</summary>
    public static int SqliteBusyTimeout(string? value) =>
        value is not null && int.TryParse(value.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var number)
            ? Math.Clamp(number, 100, 5000)
            : 2500;

    /// <summary>One line for the SQLite lock waits that ran out in this session (Domenia 1 Format-DomeniaSqliteBusySummary, OPE-032).</summary>
    public static string SqliteBusySummary(int count, DateTimeOffset? last, int timeoutMs, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var timeout = FrenchText.Integer(Math.Clamp(timeoutMs, 100, 5000)) + FrenchText.Nbsp + "ms";
        if (count <= 0)
        {
            return "Base locale" + FrenchText.Colon + "aucune attente de verrou SQLite dépassée dans cette session (délai " + timeout + ").";
        }
        var text = "Base locale occupée" + FrenchText.Colon + FrenchText.Integer(count) + " attente(s) de verrou SQLite dépassée(s) dans cette session";
        if (last is DateTimeOffset at)
        {
            text += ", la dernière à " + TimeZoneInfo.ConvertTime(at, zone).ToString("HH':'mm':'ss", CultureInfo.InvariantCulture);
        }
        return text + " (délai " + timeout + ").";
    }

    /// <summary>A short label for a known operation; otherwise the first clause of its description (80 characters at most).</summary>
    public static string LabelOf(string operation, string? description)
    {
        ArgumentNullException.ThrowIfNull(operation);
        if (KnownLabels.TryGetValue(operation, out var label))
        {
            return label;
        }
        var text = Flat(description, 200);
        var cut = text.IndexOfAny([',', ';', '.', ':']);
        var clause = (cut > 8 ? text[..cut] : text).TrimEnd(' ', ' ');
        return clause.Length == 0 ? operation : Flat(clause, NameLength);
    }

    private static readonly Dictionary<string, string> KnownLabels = new(StringComparer.Ordinal)
    {
        ["app.info"] = "Informations de l’application",
        ["session.info"] = "État de la session",
        ["session.setScope"] = "Choix de l’OU de travail",
        ["dashboard.summary"] = "Tableau de bord",
        ["dashboard.widget.refresh"] = "Actualisation d’un widget",
        ["dashboard.widget.setEnabled"] = "Mesure active d’un widget",
        ["directory.ou.children"] = "Lecture d’une branche d’OU",
        ["directory.ou.search"] = "Recherche d’OU",
        ["accounts.unlock.plan"] = "Plan de déverrouillage",
        ["write.execute"] = "Exécution d’une écriture",
        ["write.receipts.list"] = "Liste des reçus d’écriture",
        ["write.receipts.get"] = "Lecture d’un reçu",
        ["write.receipts.verify"] = "Relecture d’un reçu",
        ["operations.receipts.review"] = "Revue manuelle d’un reçu",
        ["operations.check.run"] = "Vérification de l’application",
        ["operations.diagnostic.save"] = "Enregistrement du diagnostic expurgé",
        ["operations.dossier.save"] = "Export du dossier de diagnostic",
        ["operations.export.save"] = "Export CSV",
        ["operations.survey.resume"] = "Reprise d’un relevé interrompu",
        ["operations.survey.forget"] = "Abandon d’un relevé interrompu",
    };

    private static string LowerFirst(string text) =>
        text.Length > 0 && char.IsUpper(text[0]) && !(text.Length > 1 && char.IsUpper(text[1])) ? char.ToLowerInvariant(text[0]) + text[1..] : text;
}
