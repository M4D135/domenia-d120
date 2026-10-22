using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>A fixed event preset: log, providers and identifiers, with their meaning (Domenia 1 Get-DomeniaEventPresets).</summary>
public sealed record EventPreset(string Id, string Label, ImmutableArray<string> Logs, ImmutableArray<string> Providers, ImmutableArray<int> EventIds, string Meaning);

/// <summary>Bounded query of one preset: window 1 to 720 hours, 1 to 200 events; <see cref="Clamped"/> says a bound was applied.</summary>
public sealed record EventQuery(string PresetId, string Label, int WindowHours, int MaxEvents, bool Clamped, DateTimeOffset Start, DateTimeOffset End);

/// <summary>One event of the result, attributed to the workstation or left general, with the noise level of MO-06.</summary>
public sealed record EventRow(DateTimeOffset At, int Id, string Provider, string Level, string Attribution, string Reason, string Message, AttentionLevel Noise, string? NoiseReason);

/// <summary>Result of poste.events: rows, facts that never turn a refusal or a partial read into « aucun événement ».</summary>
public sealed record EventsResult(
    string Computer,
    EventQuery Query,
    FactState ReadState,
    bool Partial,
    bool NoEventsConfirmed,
    int Attributed,
    int General,
    ImmutableArray<EventRow> Rows,
    ImmutableArray<PosteFact> Facts,
    ImmutableArray<EventPreset> Presets);

/// <summary>Noise rule of the System log of the workstation board (decision David 2026-10-08, MO-06).</summary>
public sealed record EventNoiseRule(string Level, ImmutableArray<string> Sources, ImmutableArray<string> Ids, string Reason);

/// <summary>Rules of the event log reads (Domenia 1 D076 and MO-06). Pure.</summary>
public static class PosteEvents
{
    public const int MinWindowHours = 1;
    public const int MaxWindowHours = 720;
    public const int MinEvents = 1;
    public const int MaxEvents = 200;

    public static ImmutableArray<EventPreset> Presets { get; } =
    [
        new("Startup", "Démarrage et arrêt", ["System"], ["EventLog", "Microsoft-Windows-Kernel-Power", "User32"], [6005, 6006, 6008, 41, 1074],
            "6005 et 6006 journal démarré ou arrêté, 6008 arrêt inattendu, 41 redémarrage sans arrêt propre, 1074 arrêt demandé par un processus ou un compte"),
        new("Crash", "Plantages", ["Application"], ["Application Error", "Windows Error Reporting"], [1000, 1001],
            "1000 erreur d’application, 1001 rapport d’erreur Windows"),
        new("Disk", "Disque", ["System"], ["disk"], [7, 11, 51, 153],
            "7 bloc défectueux, 11 erreur de contrôleur, 51 erreur pendant une pagination, 153 opération d’entrée-sortie relancée"),
        new("Policy", "Stratégie de groupe", ["System", "Microsoft-Windows-GroupPolicy/Operational"], ["Microsoft-Windows-GroupPolicy"], [1085, 1125, 7016],
            "1085 extension non appliquée, 1125 échec interne du traitement, 7016 fin du traitement d’une extension avec son code"),
        new("Updates", "Mises à jour", ["System"], ["Microsoft-Windows-WindowsUpdateClient"], [19, 20, 43],
            "19 installation signalée réussie par Windows Update, 20 échec d’installation, 43 installation démarrée"),
    ];

    /// <summary>Exclusions of the workstation board, kept as data: Ignore leaves the error out, Warn makes it a point to watch.</summary>
    public static ImmutableArray<EventNoiseRule> NoiseRules { get; } =
    [
        new("Ignore", ["dcom", "distributedcom", "microsoft-windows-distributedcom"], ["10016"], "Autorisations DCOM par défaut des composants Windows"),
        new("Warn", ["disk"], ["*"], "Erreur du disque"),
        new("Warn", ["ntfs", "microsoft-windows-ntfs"], ["*"], "Système de fichiers NTFS"),
        new("Warn", ["microsoft-windows-kernel-power", "kernel-power"], ["41"], "Arrêt inattendu (Kernel-Power 41)"),
    ];

    public static EventPreset? Preset(string? id) => Presets.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.Ordinal));

    /// <summary>Bounded query (New-DomeniaEventQuery): the window and the volume are clamped and the clamp is said.</summary>
    public static EventQuery Query(EventPreset preset, int windowHours, int maxEvents, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(preset);
        var window = Math.Clamp(windowHours, MinWindowHours, MaxWindowHours);
        var volume = Math.Clamp(maxEvents, MinEvents, MaxEvents);
        return new EventQuery(preset.Id, preset.Label, window, volume, window != windowHours || volume != maxEvents, now.AddHours(-window), now);
    }

    /// <summary>Level of one System error on the board: Ignore (excluded), Warn (critical source) or Info.</summary>
    public static (string Level, string? Reason) SystemEventLevel(string? source, int id)
    {
        var name = (source ?? "").Trim().ToLowerInvariant();
        var code = id.ToString(CultureInfo.InvariantCulture);
        foreach (var rule in NoiseRules)
        {
            if (rule.Sources.Contains(name) && (rule.Ids.Contains("*") || rule.Ids.Contains(code)))
            {
                return (rule.Level, rule.Reason);
            }
        }
        return ("Info", null);
    }

    /// <summary>
    /// Facts and rows of a read (ConvertTo-DomeniaEventFacts). Attribution is explicit: only the events emitted by the
    /// queried workstation concern it. Exactly <see cref="EventQuery.MaxEvents"/> rows means the list may be partial.
    /// </summary>
    public static EventsResult Interpret(string computer, EventQuery query, SourceStatus status, IReadOnlyList<EventEntry>? events, bool truncated, string reader, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(zone);
        var preset = Preset(query.PresetId);
        var label = "Événements" + FrenchText.Colon + query.Label;
        var source = "Journal " + string.Join(", ", preset?.Logs ?? []) + " de " + computer + (string.IsNullOrWhiteSpace(reader) ? "" : ", lu par " + reader);
        var facts = ImmutableArray.CreateBuilder<PosteFact>();
        var rows = ImmutableArray.CreateBuilder<EventRow>();
        var partial = status == SourceStatus.Partial || truncated;
        var state = status switch
        {
            SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial => FactState.Observed,
            SourceStatus.Refused => FactState.Refused,
            SourceStatus.Unreachable or SourceStatus.Unavailable or SourceStatus.Error => FactState.Unavailable,
            _ => FactState.Unknown,
        };
        var attributed = 0;
        var general = 0;
        var none = false;
        if (state == FactState.Observed && events is null)
        {
            state = FactState.Unknown;
            facts.Add(PosteText.Fact(label, "Réponse sans liste d’événements", FactState.Unknown, source, "Réponse incomplète : aucune conclusion sur la période.", at: query.End));
        }
        else if (state == FactState.Observed)
        {
            var target = PosteText.ShortName(computer);
            foreach (var record in events!.OrderByDescending(e => e.At))
            {
                if (preset is null || !preset.EventIds.Contains(record.Id))
                {
                    continue;
                }
                if (rows.Count >= query.MaxEvents)
                {
                    partial = true;
                    break;
                }
                var mine = PosteText.ShortName(record.Machine) == target;
                if (mine)
                {
                    attributed++;
                }
                else
                {
                    general++;
                }
                var (level, why) = SystemEventLevel(record.Provider, record.Id);
                rows.Add(new EventRow(record.At, record.Id, record.Provider, record.Level, mine ? "Poste" : "Général",
                    mine ? "Émis par le poste interrogé." : "Poste émetteur absent ou différent : non attribué au poste interrogé.",
                    PosteText.Flat(record.Message, 300), level switch { "Warn" => AttentionLevel.Warn, "Ignore" => AttentionLevel.Info, _ => AttentionLevel.Info }, why));
            }
            if (rows.Count >= query.MaxEvents)
            {
                partial = true;
            }
            if (rows.Count == 0)
            {
                if (partial)
                {
                    facts.Add(PosteText.Fact(label, "Lecture partielle sans événement retenu", FactState.Unknown, source,
                        status == SourceStatus.Partial ? "Lecture partielle du journal : aucune conclusion sur la période." : "Volume plafonné : aucune conclusion sur la période.", at: query.End));
                }
                else
                {
                    none = true;
                    facts.Add(PosteText.Fact(label, "Aucun événement correspondant dans les " + FrenchText.Count(query.WindowHours, "dernière heure", "dernières heures"), FactState.Observed, source,
                        "Absence constatée dans le journal et la fenêtre lus seulement ; un journal recyclé peut ne plus contenir les événements anciens.", at: query.End));
                }
            }
            else
            {
                var limit = status == SourceStatus.Partial ? "Lecture partielle du journal : liste incomplète."
                    : partial ? "Volume plafonné à " + FrenchText.Integer(query.MaxEvents) + " événements : liste partielle."
                    : "Fenêtre de " + FrenchText.Integer(query.WindowHours) + " h.";
                facts.Add(PosteText.Fact(label, FrenchText.Count(rows.Count, "événement", "événements") + FrenchText.Colon + FrenchText.Count(attributed, "attribué", "attribués") + " au poste, " + FrenchText.Integer(general) + " général(aux)",
                    FactState.Observed, source, limit, at: query.End, tone: rows.Any(r => r.Noise == AttentionLevel.Warn) ? Tone.Warn : Tone.Info));
            }
        }
        else if (state == FactState.Refused)
        {
            facts.Add(PosteText.Fact(label, "Lecture refusée", FactState.Refused, source, "Un refus de lecture ne signifie pas qu’aucun événement n’a eu lieu : aucun constat sain.", at: query.End));
        }
        else if (state == FactState.Unavailable)
        {
            facts.Add(PosteText.Fact(label, "Journal injoignable", FactState.Unavailable, source, "Aucune conclusion sur les événements de la période.", at: query.End));
        }
        else
        {
            facts.Add(PosteText.Fact(label, "Non demandés", FactState.Unknown, source, "La lecture du journal se demande explicitement.", at: query.End));
        }
        if (query.Clamped)
        {
            facts.Add(PosteText.Fact("Bornes appliquées", "Fenêtre de " + FrenchText.Integer(query.WindowHours) + " h, " + FrenchText.Integer(query.MaxEvents) + " événements au plus", FactState.Observed, "Domenia",
                "Fenêtre de 1 à 720 h et 1 à 200 événements.", at: query.End, tone: Tone.Info));
        }
        return new EventsResult(computer, query, state, partial, none, attributed, general, rows.ToImmutable(), facts.ToImmutable(), Presets);
    }
}
