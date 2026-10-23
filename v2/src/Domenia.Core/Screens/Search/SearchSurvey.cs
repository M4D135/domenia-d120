using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Graduated readings of « Vérifier la liste ▾ » (Domenia 1 Get-DomeniaParkVerifyModes, UI-23), plus the complete survey.</summary>
public enum SurveyMode
{
    Ping,
    Console,
    Analyse,
    Complete,
    Unaddressed,
}

/// <summary>Perimeter of a survey: the displayed list, its selection, or the OU.</summary>
public enum SurveyScope
{
    Results,
    Selection,
    Scope,
}

/// <summary>Admission of a survey (Domenia 1 Test-DomeniaParkTargetAdmission, SE-05).</summary>
public sealed record SurveyAdmission(bool Allowed, string Code, string Reason, int Maximum);

/// <summary>A workstation the survey reads, or a row set aside with its reason.</summary>
public sealed record SurveyTarget(string Id, string Name, string Dn, string? Address);

public sealed record SurveyExcluded(string Name, string Reason);

/// <summary>
/// The confirmation shown before any read: three lines, the details of the collection (profile, CIM grouping, budgets,
/// window, interrupted plan replaced), exact targets, excluded rows, numbered button. <see cref="PlanId"/> binds the run
/// to this very plan: single use, valid ten minutes, the typed count checked again by the engine.
/// </summary>
public sealed record SurveyPlan(
    string PlanId,
    SurveyMode Mode,
    string ModeLabel,
    SurveyAdmission Admission,
    string Title,
    string Target,
    ImmutableArray<string> Lines,
    ImmutableArray<string> Details,
    bool OutsideWindow,
    string ConfirmText,
    int EstimateSeconds,
    string Estimate,
    ImmutableArray<SurveyTarget> Targets,
    ImmutableArray<SurveyExcluded> Excluded,
    bool TypedCountRequired,
    bool Resume,
    DateTimeOffset ExpiresAt);

/// <summary>Remaining targets of a survey stopped by the operator (plan de reprise), kept for the session only.</summary>
public sealed record SurveyResume(string ListId, SurveyMode Mode, string ModeLabel, int Remaining, int Total, DateTimeOffset StoppedAt, string Text);

/// <summary>
/// Detailed state of a survey (RCH-099): results validated and real wait, slowed or suspended sources, retries, capabilities
/// remembered, CIM requests avoided, resume plan. <see cref="Lines"/> are the sentences the page shows under « Détails ».
/// </summary>
public sealed record SurveyStatus(int Validated, int Total, int ElapsedSeconds, int Slow, int Suspended, int Retries, int CimReachable, int CimAvoided, int Remaining,
    ImmutableArray<string> Lines);

/// <summary>Collection profile of the surveys (Domenia 1 Get-DomeniaCollectionProfiles, point 11 and 159).</summary>
public sealed record SurveyProfile(string Id, string Label, int InventorySeconds, int StaticProbeSeconds, bool Windowed);

/// <summary>
/// Result of one workstation of a survey. <see cref="InventoryReused"/>: a light inventory younger than the profile was kept
/// (no CIM request); <see cref="Denied"/>: the remote account was rejected by the workstation (selection checks suspended).
/// </summary>
public sealed record SurveyOutcome(string Id, string Name, string Kind, SearchPresence Presence, SearchConsole? Console, string? Detail, bool InventoryReused = false, bool Denied = false)
{
    public bool? Confirmed { get; init; }
}

/// <summary>Progress of a running survey (event « search.survey.run:progress »).</summary>
public sealed record SurveyProgress(string RunId, int Done, int Total, int Online, int NoReply, int Errors, string Text, ImmutableArray<SurveyOutcome> Batch, SurveyStatus Status);

/// <summary>End of a survey: counters, short text, the rows read again and whether the operator stopped it.</summary>
public sealed record SurveyResult(string RunId, SurveyMode Mode, int Done, int Total, int Online, int NoReply, int Errors, bool Stopped, string Text, string Detail,
    ImmutableArray<SearchRow> Rows, DateTimeOffset StartedAt, DateTimeOffset EndedAt, SurveyStatus Status, SurveyResume? Resume);

/// <summary>One port of the network diagnostic of a workstation.</summary>
public sealed record NetworkPort(int Port, string Service, string State, string Label, Tone Tone);

/// <summary>Network diagnostic of one workstation: an echo then TCP ports 445, 135, 5985, 5986 (RCH-131).</summary>
public sealed record NetworkDiagnosticLine(string Id, string Name, string? Address, SearchPresence Ping, ImmutableArray<NetworkPort> Ports, string Summary, Tone Tone);

public sealed record NetworkDiagnostic(ImmutableArray<NetworkDiagnosticLine> Lines, ImmutableArray<SurveyExcluded> Excluded, string Summary, string Report, DateTimeOffset At);

/// <summary>
/// Rules of the surveys of the list, ported from Domenia 1 (Domenia-Park.Model.ps1): admission, three-line confirmation,
/// duration estimate, short progress text, outcome classes. Pure.
/// </summary>
public static class SearchSurvey
{
    /// <summary>Ceiling of one survey (Park.MaxTargets: 500 by default, 5 000 at most).</summary>
    public const int MaxTargets = 500;

    /// <summary>Above this count the number must be typed before the survey starts (Domenia 1 UX-24).</summary>
    public const int TypedCountThreshold = 100;

    /// <summary>Workstations of one network diagnostic at most (RCH-131).</summary>
    public const int MaxDiagnostic = 50;

    /// <summary>Ports read by the network diagnostic: SMB, RPC, WinRM HTTP and HTTPS.</summary>
    public static readonly ImmutableArray<(int Port, string Service)> DiagnosticPorts = [(445, "SMB"), (135, "RPC"), (5985, "WinRM"), (5986, "WinRM HTTPS")];

    public static string ModeLabel(SurveyMode mode) => mode switch
    {
        SurveyMode.Ping => "Qui répond ?",
        SurveyMode.Console => "Qui est connecté ?",
        SurveyMode.Analyse => "Matériel et widgets",
        SurveyMode.Complete => "Relevé complet",
        _ => "Postes sans adresse",
    };

    public static string ModeDetail(SurveyMode mode) => mode switch
    {
        SurveyMode.Ping => "Un ping par poste, échos envoyés en parallèle. Aucune lecture de session.",
        SurveyMode.Console => "Ping puis utilisateur connecté à la console (CIM), quatre postes à la fois.",
        SurveyMode.Analyse => "Ping, utilisateur connecté, relevé WMI léger et requêtes des widgets des tableaux de bord.",
        SurveyMode.Complete => "Relevé léger plus correctifs, démarrage, services automatiques arrêtés, TPM, BIOS et numéro de série ; jamais Win32_Product ni la liste des processus.",
        _ => "Seulement les postes sans adresse connue, laissés après les autres dans un relevé normal.",
    };

    /// <summary>
    /// Guard of a survey of the displayed list or of its selection, never a disguised whole-domain survey: refused above the
    /// ceiling, for a list of the domain root without any other filter, for a global search without a term, for a view
    /// listed on the whole domain. A selection that leaves rows out is its own filter (ceiling only).
    /// </summary>
    public static SurveyAdmission Admit(int count, int maximum, bool global, bool hasSearchTerm, bool wholeDomain, bool hasFilter, bool selection, bool selectionCoversList)
    {
        var max = Math.Min(5000, maximum < 1 ? MaxTargets : maximum);
        if (count <= 0)
        {
            return new SurveyAdmission(false, "empty", selection ? "Aucun poste dans la sélection." : "Aucun poste dans les résultats affichés.", max);
        }
        if (count > max)
        {
            return new SurveyAdmission(false, "ceiling", selection
                ? FrenchText.Count(count, "poste sélectionné", "postes sélectionnés") + FrenchText.Colon + "plafond " + FrenchText.Integer(max) + ". Réduisez la sélection."
                : FrenchText.Count(count, "poste affiché", "postes affichés") + FrenchText.Colon + "plafond " + FrenchText.Integer(max) + ". Filtrez la liste.", max);
        }
        if (!selection || selectionCoversList)
        {
            var whole = selection ? "Toute la liste est sélectionnée. " : "";
            if (global && !hasSearchTerm)
            {
                return new SurveyAdmission(false, "globalWithoutTerm", whole + "Recherche globale sans terme" + FrenchText.Colon + "aucun relevé de tout le domaine. Saisissez un nom ou choisissez une OU.", max);
            }
            if (!global && wholeDomain && !hasFilter)
            {
                return new SurveyAdmission(false, "domainRoot", whole + "Liste de la racine du domaine sans autre filtre" + FrenchText.Colon + "aucun relevé de tout le domaine. Choisissez une OU ou filtrez la liste.", max);
            }
        }
        return new SurveyAdmission(true, "allowed", "", max);
    }

    /// <summary>
    /// Plausible upper duration in seconds: echoes by batches of 32 (about 2 s each), a console read about 4 s, the light
    /// inventory about 4 s more, several workstations at a time (Domenia 1 Get-DomeniaParkDurationEstimate).
    /// </summary>
    public static int Estimate(int count, SurveyMode mode, int concurrency = 4)
    {
        var n = Math.Max(0, count);
        if (n == 0)
        {
            return 0;
        }
        if (mode == SurveyMode.Ping)
        {
            return (int)Math.Ceiling(n / 32.0) * 2;
        }
        var per = 4.0;
        if (mode is SurveyMode.Analyse or SurveyMode.Complete)
        {
            per += 4.0;
        }
        if (mode == SurveyMode.Analyse)
        {
            per += 2.0 * 6;
        }
        if (mode == SurveyMode.Complete)
        {
            per += 2.0 * 4;
        }
        var parallel = Math.Clamp(concurrency, 1, 8);
        return (int)Math.Ceiling(Math.Ceiling(n / (double)parallel) * per);
    }

    /// <summary>« moins d’une minute », « environ 3 min », « environ 1,5 h ».</summary>
    public static string Duration(int seconds)
    {
        if (seconds < 60)
        {
            return "moins d’une minute";
        }
        if (seconds < 3600)
        {
            return "environ " + FrenchText.Integer((long)Math.Ceiling(seconds / 60.0)) + FrenchText.Nbsp + "min";
        }
        return "environ " + FrenchText.Decimal(Math.Round(seconds / 3600.0, 1)) + FrenchText.Nbsp + "h";
    }

    /// <summary>
    /// Three short lines (which workstations and why the count differs, what is read, how long) and the numbered button
    /// (« Pinger 48 postes ») (Domenia 1 New-DomeniaParkConfirmationText, UX-24).
    /// </summary>
    public static (string Title, string Target, ImmutableArray<string> Lines, string Confirm, int Seconds) Confirmation(SurveyMode mode, int count, SurveyScope scope,
        string? scopeLabel, bool subtree, int skipped, int listLimit, int concurrency = 4)
    {
        var postes = FrenchText.Count(count, "poste", "postes");
        var line1 = scope switch
        {
            SurveyScope.Selection => postes + " " + (count > 1 ? "sélectionnés" : "sélectionné"),
            SurveyScope.Scope => postes + (string.IsNullOrEmpty(scopeLabel) ? " du périmètre choisi" : " de " + scopeLabel),
            _ => postes + " " + (count > 1 ? "affichés" : "affiché") + (string.IsNullOrEmpty(scopeLabel) ? "" : " (" + scopeLabel + (subtree ? ", sous-OU" : "") + ")"),
        };
        if (skipped > 0)
        {
            line1 += " · " + FrenchText.Count(skipped, "ligne écartée", "lignes écartées") + " (sans identifiant AD, autre type ou poste désactivé)";
        }
        if (listLimit > 0)
        {
            line1 += " · liste limitée à " + FrenchText.Integer(listLimit) + " lignes" + FrenchText.Colon + "les autres postes ne sont pas concernés";
        }
        var read = new List<string> { "présence" };
        if (mode != SurveyMode.Ping)
        {
            read.Add("utilisateur connecté");
        }
        if (mode is SurveyMode.Analyse or SurveyMode.Complete)
        {
            read.Add("matériel");
        }
        if (mode == SurveyMode.Analyse)
        {
            read.Add("6 requêtes des widgets");
        }
        if (mode == SurveyMode.Complete)
        {
            read.Add("correctifs, démarrage, services, TPM, BIOS et numéro de série");
        }
        var line2 = "Ce qui sera lu" + FrenchText.Colon + string.Join(" · ", read) + ", en lecture seule.";
        var parallel = Math.Clamp(concurrency, 1, 8);
        var seconds = Estimate(count, mode, parallel);
        var line3 = "Durée estimée" + FrenchText.Colon + Duration(seconds)
            + (mode == SurveyMode.Ping ? ", échos envoyés par lots de 32" : ", " + FrenchText.Count(parallel, "poste", "postes") + " à la fois")
            + " ; arrêt possible à tout moment.";
        var verb = mode switch
        {
            SurveyMode.Ping => "Pinger",
            SurveyMode.Analyse or SurveyMode.Complete => "Analyser",
            _ => "Vérifier",
        };
        var title = scope switch
        {
            SurveyScope.Selection => "Vérifier la sélection" + FrenchText.Colon + ModeLabel(mode),
            SurveyScope.Scope => "Relevé des postes" + FrenchText.Colon + ModeLabel(mode),
            _ => "Vérifier la liste" + FrenchText.Colon + ModeLabel(mode),
        };
        var target = scope == SurveyScope.Selection ? "la sélection" : string.IsNullOrEmpty(scopeLabel) ? "les résultats affichés" : scopeLabel;
        return (title, target, [line1, line2, line3], verb + " " + postes, seconds);
    }

    /// <summary>« 12/48 · 9 joignables » while it runs, then « 48/48 · 30 en ligne · 15 sans réponse · 3 erreurs » (CO-19).</summary>
    public static string Progress(int done, int total, int online, int noReply, int errors, bool completed, bool stopped)
    {
        var text = FrenchText.Integer(done) + "/" + FrenchText.Integer(total);
        text += completed
            ? " · " + FrenchText.Integer(online) + " en ligne · " + FrenchText.Integer(noReply) + " sans réponse · " + FrenchText.Count(errors, "erreur", "erreurs")
            : " · " + FrenchText.Count(online, "joignable", "joignables");
        return completed && stopped ? "Arrêté à " + text : text;
    }

    /// <summary>Class of a presence for the counters: online, noReply or error (no measure, name not resolved).</summary>
    public static string OutcomeKind(SearchPresenceState state) => state switch
    {
        SearchPresenceState.Online => "online",
        SearchPresenceState.NoReply => "noReply",
        _ => "error",
    };

    /// <summary>Delay in seconds after which a probe counts as slowed in the detail of a survey.</summary>
    public const int SlowProbeSeconds = 2;

    /// <summary>Most seconds one workstation of a survey may take (budget of the confirmation).</summary>
    public const int ProbeBudgetSeconds = 15;

    /// <summary>The three collection profiles of Domenia 1; an unknown or empty identifier falls back to Standard.</summary>
    public static SurveyProfile Profile(string? id) => (id ?? "").Trim().ToUpperInvariant() switch
    {
        "SLOWNETWORK" => new SurveyProfile("SlowNetwork", "Réseau lent ou site distant", 3600, 14400, true),
        "TROUBLESHOOTING" => new SurveyProfile("Troubleshooting", "Dépannage en direct", 120, 300, false),
        _ => new SurveyProfile("Standard", "Standard", 300, 900, false),
    };

    /// <summary>
    /// Collection window of a profile at a local time (Domenia 1 point 159): always open for Standard and Troubleshooting;
    /// « Réseau lent » opens on weekdays 00:00-08:00, 12:00-14:00, 18:00-24:00 and all weekend. An explicit survey stays
    /// possible outside the window: its confirmation says so.
    /// </summary>
    public static bool WindowOpen(SurveyProfile profile, DateTime local)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (!profile.Windowed || local.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday)
        {
            return true;
        }
        var hour = local.Hour;
        return hour < 8 || hour is >= 12 and < 14 || hour >= 18;
    }

    /// <summary>
    /// Details of the confirmation (RCH-091): profile and reuse, CIM grouping, budgets, collection window, interrupted plan
    /// replaced. Pure.
    /// </summary>
    public static ImmutableArray<string> Details(SurveyMode mode, SurveyProfile profile, bool windowOpen, SurveyResume? replaced, bool resuming, int concurrency = 4)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var lines = new List<string>();
        var reuse = mode is SurveyMode.Analyse or SurveyMode.Complete
            ? "inventaire léger de moins de " + Seconds(profile.InventorySeconds) + " et sondes stables de moins de " + Seconds(profile.StaticProbeSeconds) + " réutilisés ; l’utilisateur console est toujours relu"
            : mode == SurveyMode.Ping ? "chaque poste reçoit un nouvel écho" : "l’utilisateur console est toujours relu";
        lines.Add("Profil de collecte " + FrenchText.Quote(profile.Label) + FrenchText.Colon + reuse + ".");
        if (mode != SurveyMode.Ping)
        {
            lines.Add("Requêtes CIM regroupées par poste" + FrenchText.Colon + "une seule connexion DCOM par poste pour l’utilisateur console"
                + (mode is SurveyMode.Analyse or SurveyMode.Complete ? " et le matériel" : "") + ".");
        }
        var parallel = Math.Clamp(concurrency, 1, 8);
        lines.Add("Budget" + FrenchText.Colon + (mode == SurveyMode.Ping ? "échos par lots de 32" : FrenchText.Count(parallel, "poste", "postes") + " à la fois")
            + ", " + FrenchText.Integer(ProbeBudgetSeconds) + FrenchText.Nbsp + "s au plus par poste ; une seule tentative, rien n’est rejoué.");
        lines.Add(windowOpen
            ? "Fenêtre de collecte" + FrenchText.Colon + (profile.Windowed ? "ouverte" : "permise à tout moment") + " (profil " + FrenchText.Quote(profile.Label) + ")."
            : "Hors fenêtre de collecte du profil " + FrenchText.Quote(profile.Label) + FrenchText.Colon + "ce relevé part seulement parce que vous le confirmez, sur le périmètre indiqué.");
        if (resuming && replaced is not null)
        {
            lines.Add("Reprise du relevé interrompu le " + replaced.StoppedAt.ToString("dd/MM", System.Globalization.CultureInfo.InvariantCulture) + FrenchText.Colon
                + FrenchText.Count(replaced.Remaining, "poste restant", "postes restants") + ", les mesures déjà validées sont gardées.");
        }
        else if (replaced is not null)
        {
            lines.Add("Le plan de reprise du relevé interrompu (" + FrenchText.Quote(replaced.ModeLabel) + ", " + FrenchText.Count(replaced.Remaining, "poste restant", "postes restants")
                + ") sera remplacé par ce relevé.");
        }
        return [.. lines];
    }

    /// <summary>Sentences of the detailed state of a survey (RCH-099). Pure.</summary>
    public static SurveyStatus Status(SurveyMode mode, int validated, int total, int elapsedSeconds, int slow, int suspended, int cimReachable, int cimAvoided, int remaining,
        SurveyProfile profile, bool finished)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var lines = ImmutableArray.CreateBuilder<string>();
        lines.Add("Résultats validés" + FrenchText.Colon + FrenchText.Integer(validated) + " sur " + FrenchText.Integer(total) + " · attente réelle " + Seconds(Math.Max(0, elapsedSeconds)) + ".");
        lines.Add(slow > 0
            ? "Sources ralenties" + FrenchText.Colon + FrenchText.Count(slow, "poste a", "postes ont") + " répondu en plus de " + FrenchText.Integer(SlowProbeSeconds) + FrenchText.Nbsp + "s."
            : "Sources ralenties" + FrenchText.Colon + "aucune.");
        lines.Add(suspended > 0
            ? "Sources suspendues" + FrenchText.Colon + FrenchText.Count(suspended, "poste a", "postes ont") + " rejeté le compte distant ; les vérifications sur sélection sont suspendues."
            : "Sources suspendues" + FrenchText.Colon + "aucune.");
        lines.Add("Nouveaux essais" + FrenchText.Colon + "aucun (une seule tentative par poste, rien n’est rejoué).");
        lines.Add(mode == SurveyMode.Ping
            ? "Capacités mémorisées" + FrenchText.Colon + "sans objet (ping seul)."
            : "Capacités mémorisées" + FrenchText.Colon + "CIM DCOM joignable sur " + FrenchText.Count(cimReachable, "poste", "postes") + ".");
        lines.Add(mode is SurveyMode.Analyse or SurveyMode.Complete
            ? "Requêtes CIM évitées" + FrenchText.Colon + FrenchText.Integer(cimAvoided) + " (inventaire de moins de " + Seconds(profile.InventorySeconds) + " réutilisé)."
            : "Requêtes CIM évitées" + FrenchText.Colon + "sans objet pour ce relevé.");
        lines.Add(remaining > 0
            ? "Plan de reprise" + FrenchText.Colon + FrenchText.Count(remaining, "poste restant", "postes restants") + (finished ? ", gardé pour cette session (« Reprendre »)." : ".")
            : "Plan de reprise" + FrenchText.Colon + (finished ? "aucun, tous les postes visés ont été lus." : "aucun pour l’instant."));
        return new SurveyStatus(validated, total, elapsedSeconds, slow, suspended, 0, cimReachable, cimAvoided, remaining, lines.ToImmutable());
    }

    /// <summary>« 30 s », « 5 min », « 1 h », « 4 h ».</summary>
    public static string Seconds(int seconds)
    {
        if (seconds < 60)
        {
            return FrenchText.Integer(seconds) + FrenchText.Nbsp + "s";
        }
        if (seconds < 3600)
        {
            return FrenchText.Integer(seconds / 60) + FrenchText.Nbsp + "min";
        }
        return FrenchText.Integer(seconds / 3600) + FrenchText.Nbsp + "h";
    }

    /// <summary>Parses a mode name of the contract (« ping », « console », « analyse », « complete », « unaddressed »).</summary>
    public static bool TryParseMode(string? text, out SurveyMode mode)
    {
        switch (text)
        {
            case "ping":
                mode = SurveyMode.Ping;
                return true;
            case "console":
                mode = SurveyMode.Console;
                return true;
            case "analyse":
                mode = SurveyMode.Analyse;
                return true;
            case "complete":
                mode = SurveyMode.Complete;
                return true;
            case "unaddressed":
                mode = SurveyMode.Unaddressed;
                return true;
            default:
                mode = SurveyMode.Ping;
                return false;
        }
    }

    /// <summary>Tab separated report of a network diagnostic, one line per workstation (copied on request).</summary>
    public static string Report(IEnumerable<NetworkDiagnosticLine> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);
        var header = "Poste\tAdresse\tPing\t" + string.Join('\t', DiagnosticPorts.Select(p => p.Port.ToString(CultureInfo.InvariantCulture) + " " + p.Service)) + "\tSynthèse";
        var rows = lines.Select(l => string.Join('\t', new[] { l.Name, l.Address ?? "", l.Ping.Label }.Concat(l.Ports.Select(p => p.Label)).Append(l.Summary)));
        return string.Join("\r\n", new[] { header }.Concat(rows));
    }
}
