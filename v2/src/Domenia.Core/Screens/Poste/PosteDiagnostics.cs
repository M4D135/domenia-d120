using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>Severity of a diagnostic line: a missing optional transport or a closed WinRM is information, not a failure.</summary>
public enum DiagSeverity
{
    Passed,
    Failed,
    Information,
    NotTried,
    Inconclusive,
}

/// <summary>State of a network layer of the diagnosis (Domenia 1 point 90).</summary>
public enum LayerState
{
    Passed,
    Failed,
    Partial,
    NotTried,
    Inconclusive,
}

/// <summary>One raw check of the worker: name, code (OK, ERREUR, REFUSE, INJOIGNABLE, INDISPONIBLE, IGNORE), method, duration, detail.</summary>
public sealed record DiagCheck(string Check, string Status, string Method, int DurationMs, string Detail);

/// <summary>One line as the page shows it: the raw code stays beside its label (the copied report keeps it).</summary>
public sealed record DiagRow(string Check, string Label, string Status, string StatusLabel, DiagSeverity Severity, string Method, int DurationMs, string Detail, string? Remedy);

public sealed record DiagLayer(int Step, string Label, LayerState State, string Detail);

/// <summary>Result of poste.diagnostic: verdict sentence, counters, layers with the blocking step, rows and the report to copy.</summary>
public sealed record DiagnosticResult(
    string Computer,
    DateTimeOffset At,
    string Verdict,
    int Passed,
    int Failed,
    int Information,
    int NotTried,
    int BlockingStep,
    bool Reachable,
    ImmutableArray<DiagLayer> Layers,
    ImmutableArray<DiagRow> Rows,
    string Report,
    int DurationMs,
    int BudgetSeconds)
{
    public int Inconclusive { get; init; }
    public string? Notice { get; init; }
    public string? NoticeAction { get; init; }
}

/// <summary>One planned check of the quick diagnosis, with its source and its own time-out.</summary>
public sealed record QuickCheckPlan(string Id, string Label, string Source, int TimeoutSeconds);

/// <summary>Result of poste.quickDiag: five facts, a summary, the announced budget and whether it was exceeded.</summary>
public sealed record QuickDiagResult(string Computer, DateTimeOffset At, ImmutableArray<PosteFact> Facts, string Summary, bool Complete, bool Overrun, string DurationText, string CostText, string Fallback);

/// <summary>Raw answer of one quick check: status (Ok, Refused, Unreachable, Skipped…) and its values.</summary>
public sealed record QuickRaw(SourceStatus Status, string? Detail);

/// <summary>Raw answers of the quick diagnosis; a check absent (null) was not run.</summary>
public sealed record QuickDiagRaw(
    int? ElapsedMs,
    QuickRaw? System,
    string? Caption,
    string? Version,
    QuickRaw? LastBoot,
    DateTimeOffset? LastBootAt,
    QuickRaw? DiskC,
    long? FreeBytes,
    long? SizeBytes,
    QuickRaw? Ports,
    ImmutableArray<(int Port, bool? Open)> PortResults,
    QuickRaw? Services,
    ImmutableArray<(string Name, bool Present, string? State, string? StartMode)> ServiceResults);

/// <summary>
/// Rules of the workstation diagnosis (Domenia 1 UX-17, point 90 and D071): one verdict rather than a count of failures, the
/// first network layer that blocks, and the bounded quick diagnosis. Pure.
/// </summary>
public static class PosteDiagnostics
{
    /// <summary>Budget of the full diagnosis (tests slow on closed ports are skipped).</summary>
    public const int BudgetSeconds = 45;

    public static ImmutableArray<QuickCheckPlan> QuickPlan { get; } =
    [
        new("System", "Système", "CIM Win32_OperatingSystem (Caption, Version)", 4),
        new("LastBoot", "Dernier démarrage", "CIM Win32_OperatingSystem (LastBootUpTime)", 2),
        new("DiskC", "Disque C:", "CIM Win32_LogicalDisk (C:)", 4),
        new("Ports", "Ports 135/445/5985", "Ouverture de connexion TCP, sans envoi de données", 6),
        new("Services", "Services de gestion", "CIM Win32_Service (lecture seule)", 4),
    ];

    /// <summary>Services read by the quick diagnosis.</summary>
    public static ImmutableArray<string> QuickServices { get; } = ["Winmgmt", "RpcSs", "WinRM", "LanmanServer"];

    public static int QuickBudgetSeconds => QuickPlan.Sum(c => c.TimeoutSeconds);

    public static string QuickCostText => FrenchText.Count(QuickPlan.Length, "contrôle", "contrôles") + ", " + FrenchText.Integer(QuickBudgetSeconds) + " s au plus";

    public const string QuickFallback = "Aucun repli : ni PsExec, ni tâche planifiée, ni modification du poste.";

    /// <summary>Label shown for a check: the keys of Domenia 1 stay unaccented (reports, remedies), the page shows French.</summary>
    public static string CheckLabel(string? check) => (check ?? "").Trim() switch
    {
        "Resolution DNS" => "Résolution DNS",
        "Systeme" => "Système",
        "Disque systeme" => "Disque système",
        "Redemarrage en attente" => "Redémarrage en attente",
        "Transport Task Scheduler" => "Transport par tâche planifiée",
        "Transport PsExec" => "Transport par PsExec",
        "Ping" => "Ping (ICMP)",
        var other => other,
    };

    /// <summary>Short name of a fallback transport inside a sentence (« PsExec », « tâche planifiée »).</summary>
    public static string FallbackLabel(string? check) => (check ?? "").Trim() switch
    {
        "Transport PsExec" => "PsExec",
        "Transport Task Scheduler" => "tâche planifiée",
        var other => CheckLabel(other),
    };

    /// <summary>Label of a code (Get-DomeniaDiagStatusLabel); an unknown code comes back as it is.</summary>
    public static string StatusLabel(string? status)
    {
        var code = (status ?? "").Trim().ToUpperInvariant();
        return code switch
        {
            "OK" => "Réussi",
            "ERREUR" => "Erreur",
            "REFUSE" => "Refusé",
            "INJOIGNABLE" => "Injoignable",
            "INDISPONIBLE" => "Non installé",
            "IGNORE" => "Non tenté",
            "INFO" => "Information",
            "INCONNU" => "Non concluant",
            _ => code,
        };
    }

    /// <summary>
    /// Severity (Get-DomeniaDiagSeverity): the fallback transports and WinRM are optional — Domenia reads by CIM — so their
    /// absence is information; a failure of anything else is a failure.
    /// </summary>
    public static DiagSeverity Severity(string check, string status)
    {
        ArgumentNullException.ThrowIfNull(check);
        var code = (status ?? "").Trim().ToUpperInvariant();
        if (code == "OK")
        {
            return DiagSeverity.Passed;
        }
        if (code == "IGNORE")
        {
            return DiagSeverity.NotTried;
        }
        if (code == "INCONNU") { return DiagSeverity.Inconclusive; }
        var name = check.Trim();
        foreach (var prefix in new[] { "WinRM", "Transport PsExec", "Transport Task Scheduler" })
        {
            if (name.Equals(prefix, StringComparison.OrdinalIgnoreCase) || name.StartsWith(prefix + " ", StringComparison.OrdinalIgnoreCase))
            {
                return DiagSeverity.Information;
            }
        }
        if (name.StartsWith("TCP 5985", StringComparison.OrdinalIgnoreCase) || name.StartsWith("TCP 5986", StringComparison.OrdinalIgnoreCase))
        {
            return DiagSeverity.Information;
        }
        return DiagSeverity.Failed;
    }

    /// <summary>Remedy proposed per failed check (improvement: guided diagnosis); never an action, only a lead.</summary>
    public static string? Remedy(string check, DiagSeverity severity)
    {
        if (severity != DiagSeverity.Failed)
        {
            return null;
        }
        return check switch
        {
            "Resolution DNS" => "Vérifiez l’enregistrement DNS du poste (dNSHostName, zone de recherche directe) ou attendez son renouvellement DHCP.",
            "Ping" => "ICMP peut être filtré : un port de gestion ouvert suffit à joindre le poste.",
            "Session CIM" => "Vérifiez le pare-feu (règle « Infrastructure de gestion Windows (WMI) ») et les droits DCOM du compte utilisé.",
            "Partage C$" => "Vérifiez le service Serveur (LanmanServer) et la règle « Partage de fichiers et d’imprimantes » du pare-feu.",
            "TCP 135" => "Port RPC fermé ou filtré : la lecture CIM par DCOM échouera.",
            "TCP 445" => "Port SMB fermé ou filtré : ni C$, ni ADMIN$, ni PsExec.",
            "TCP 3389" => "Bureau à distance fermé : service TermService arrêté ou règle de pare-feu absente.",
            "Redemarrage en attente" => "Un redémarrage est attendu par le système : proposez-le à l’utilisateur.",
            "Disque systeme" => "Vérifiez l’espace libre du volume système indiqué dans le contrôle.",
            _ => "Relisez le détail de la ligne et le journal technique avant de conclure.",
        };
    }

    /// <summary>Layer by layer (Get-DomeniaNetworkLayerDiagnosis): ICMP alone never blocks; a layer not tried proves nothing.</summary>
    public static (ImmutableArray<DiagLayer> Layers, int Blocking, bool Reachable, string Sentence) Layers(IReadOnlyList<DiagCheck> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        LayerState StateOf(DiagCheck? found)
        {
            if (found is null)
            {
                return LayerState.NotTried;
            }
            var code = found.Status.Trim().ToUpperInvariant();
            return code == "OK" ? LayerState.Passed : code is "IGNORE" or "INDISPONIBLE" or "" ? LayerState.NotTried : code == "INCONNU" ? LayerState.Inconclusive : LayerState.Failed;
        }
        DiagCheck? Find(string name) => rows.FirstOrDefault(r => string.Equals(r.Check, name, StringComparison.Ordinal));
        var dns = Find("Resolution DNS");
        var ping = Find("Ping");
        var tcp = rows.Where(r => r.Check.StartsWith("TCP ", StringComparison.OrdinalIgnoreCase)).ToList();
        var open = tcp.Where(r => r.Status.Trim().Equals("OK", StringComparison.OrdinalIgnoreCase)).Select(r => r.Check.Split(' ')[1]).ToList();
        var cim = Find("Session CIM");
        var share = Find("Partage C$");
        var dnsState = StateOf(dns);
        var pingState = StateOf(ping);
        var tcpState = tcp.Count == 0 || tcp.All(r => StateOf(r) == LayerState.NotTried) ? LayerState.NotTried : open.Count > 0 ? LayerState.Passed
            : tcp.Any(r => StateOf(r) == LayerState.Failed) ? LayerState.Failed : LayerState.Inconclusive;
        var cimState = StateOf(cim);
        var shareState = StateOf(share);
        var protocol = cimState switch
        {
            LayerState.Passed => LayerState.Passed,
            LayerState.Failed => LayerState.Failed,
            _ => shareState == LayerState.Passed ? LayerState.Partial : shareState == LayerState.Failed ? LayerState.Failed
                : cimState == LayerState.Inconclusive || shareState == LayerState.Inconclusive ? LayerState.Inconclusive : LayerState.NotTried,
        };
        string DetailOf(DiagCheck? r) => r is null ? "" : PosteText.Flat(r.Detail, 120);
        var layers = ImmutableArray.Create(
            new DiagLayer(1, "Résolution du nom", dnsState, DetailOf(dns)),
            new DiagLayer(2, "Réponse ICMP (ping)", pingState, DetailOf(ping)),
            new DiagLayer(3, "Transport TCP", tcpState, open.Count > 0 ? "ports ouverts : " + string.Join(", ", open) : tcpState == LayerState.Failed ? "aucune connexion TCP établie dans les contrôles exécutés" : "Aucune ouverture de port confirmée."),
            new DiagLayer(4, "Protocole utile (CIM, C$)", protocol, cim is not null ? DetailOf(cim) : DetailOf(share)));
        var reachable = tcpState == LayerState.Passed || protocol is LayerState.Passed or LayerState.Partial;
        var blocking = 0;
        var sentence = "";
        if (dnsState == LayerState.Failed && !reachable)
        {
            blocking = 1;
            sentence = "La connexion échoue à la résolution du nom : aucune adresse n’est connue pour ce poste.";
        }
        else if (tcpState == LayerState.Failed)
        {
            blocking = 3;
            sentence = "La connexion échoue au transport : aucun port de gestion ne répond"
                + (pingState == LayerState.Passed ? " alors que le poste répond au ping (pare-feu probable)." : pingState == LayerState.Failed ? " ni au ping (poste éteint, hors réseau ou filtré)." : ".");
        }
        else if (protocol == LayerState.Failed)
        {
            blocking = 4;
            var code = cim?.Status.Trim().ToUpperInvariant() ?? "";
            sentence = code == "REFUSE" ? "La connexion échoue au protocole : la session CIM est refusée au compte utilisé."
                : code == "INJOIGNABLE" && open.Contains("135") ? "La connexion échoue au protocole : le port 135 répond mais la session CIM n’aboutit pas (ports RPC dynamiques filtrés ?)."
                : cim is not null ? "La connexion échoue au protocole : la session CIM n’aboutit pas."
                : "La connexion échoue au protocole : le partage C$ n’est pas accessible.";
        }
        else if (pingState == LayerState.Failed && reachable)
        {
            sentence = "Pas de réponse au ping, mais le poste est joignable par TCP : ICMP est probablement filtré.";
        }
        else if (dnsState == LayerState.Passed && tcpState == LayerState.Passed && protocol == LayerState.Passed)
        {
            sentence = "Toutes les étapes utiles réussissent : nom résolu, " + (open.Count > 0 ? "ports " + string.Join(", ", open) + " ouverts, " : "") + "session CIM ouverte.";
        }
        else if (!reachable)
        {
            sentence = "Étape bloquante inconnue : aucune lecture de port ou de protocole concluante.";
        }
        return (layers, blocking, reachable, sentence);
    }

    /// <summary>The verdict of the diagnosis (ConvertTo-DomeniaDiagVerdict): an unreachable workstation is said first.</summary>
    public static DiagnosticResult Verdict(string computer, IReadOnlyList<DiagCheck> checks, DateTimeOffset at, int durationMs, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(checks);
        ArgumentNullException.ThrowIfNull(zone);
        var rows = checks.Select(c =>
        {
            var severity = Severity(c.Check, c.Status);
            return new DiagRow(c.Check, CheckLabel(c.Check), c.Status, StatusLabel(c.Status), severity, c.Method, c.DurationMs, c.Detail, Remedy(c.Check, severity));
        }).ToImmutableArray();
        var (layers, blocking, reachable, sentence) = Layers(checks);
        if (rows.IsEmpty)
        {
            return new DiagnosticResult(computer, at, "Aucun contrôle exécuté : lancez « Lancer le diagnostic » pour lire le poste.", 0, 0, 0, 0, 0, false, layers, rows, "", durationMs, BudgetSeconds);
        }
        var subject = string.IsNullOrWhiteSpace(computer) ? "Le poste" : computer.Trim();
        var failed = rows.Where(r => r.Severity == DiagSeverity.Failed).ToList();
        var points = new List<string>();
        var dnsFailed = failed.Any(r => r.Check == "Resolution DNS");
        if (!reachable && dnsFailed)
        {
            points.Add("Disponibilité de " + subject + " non établie : résolution du nom en échec.");
        }
        else if (reachable || rows.Any(r => r.Check == "Ping" && r.Severity == DiagSeverity.Passed))
        {
            var positives = new List<string>();
            if (rows.Any(r => r.Check == "Partage C$" && r.Severity == DiagSeverity.Passed))
            {
                positives.Add("C$ accessible");
            }
            if (rows.Any(r => r.Check == "Session CIM" && r.Severity == DiagSeverity.Passed))
            {
                positives.Add("WMI lu");
            }
            if (rows.Any(r => r.Check.StartsWith("TCP 3389", StringComparison.Ordinal) && r.Severity == DiagSeverity.Passed))
            {
                positives.Add("port 3389 ouvert");
            }
            var head = subject + " répond" + (failed.Any(r => r.Check == "Ping") ? " sans ping (ICMP filtré)" : "") + (positives.Count > 0 ? FrenchText.Colon + string.Join(", ", positives) : "");
            points.Add(head + ".");
        }
        else { points.Add("Disponibilité de " + subject + " non établie par les contrôles reçus."); }
        if (sentence.Length > 0)
        {
            points.Add(sentence);
        }
        if (failed.Count > 0)
        {
            var names = string.Join(", ", failed.Take(3).Select(r => r.Check));
            points.Add(FrenchText.Count(failed.Count, "contrôle en échec", "contrôles en échec") + FrenchText.Colon + names + (failed.Count > 3 ? " (et " + FrenchText.Count(failed.Count - 3, "autre", "autres") + ")." : "."));
        }
        var optional = rows.Where(r => r.Severity == DiagSeverity.Information).ToList();
        if (optional.Count > 0)
        {
            var winrm = optional.Where(r => r.Check.StartsWith("TCP 5985", StringComparison.Ordinal) || r.Check.StartsWith("TCP 5986", StringComparison.Ordinal) || r.Check == "WinRM").ToList();
            var fallbacks = optional.Except(winrm).ToList();
            if (winrm.Any(r => !r.Check.StartsWith("TCP 5986", StringComparison.Ordinal)))
            {
                points.Add("Au moins un contrôle WinRM n’a pas abouti ; voir son statut de transport ou d’accès.");
            }
            else if (winrm.Count > 0)
            {
                points.Add("Le port WinRM HTTPS (5986) n’a pas répondu au contrôle.");
            }
            if (fallbacks.Count > 0)
            {
                points.Add("Contrôles de repli non concluants : " + string.Join(", ", fallbacks.Take(3).Select(r => FallbackLabel(r.Check))) + ".");
            }
        }
        var verdict = string.Join(" ", points);
        var report = "Diagnostic de " + subject + " · " + PosteText.LocalDateTime(at, zone) + Environment.NewLine + verdict + Environment.NewLine
            + string.Join(Environment.NewLine, rows.Select(r => r.Check + "\t" + r.Status + "\t" + r.StatusLabel + "\t" + r.Method + "\t" + r.DurationMs.ToString(System.Globalization.CultureInfo.InvariantCulture) + " ms\t" + PosteText.Flat(r.Detail, 200)));
        return new DiagnosticResult(computer, at, verdict,
            rows.Count(r => r.Severity == DiagSeverity.Passed), failed.Count, optional.Count, rows.Count(r => r.Severity == DiagSeverity.NotTried),
            blocking, reachable, layers, rows, report, durationMs, BudgetSeconds) { Inconclusive = rows.Count(r => r.Severity == DiagSeverity.Inconclusive) };
    }

    /// <summary>
    /// Facts of the quick diagnosis (ConvertTo-DomeniaQuickDiagFacts): only the planned checks become facts; a refused or
    /// unavailable check concludes nothing; a budget overrun is said.
    /// </summary>
    public static QuickDiagResult QuickFacts(string computer, QuickDiagRaw raw, DateTimeOffset now, TimeZoneInfo zone, string reader)
    {
        ArgumentNullException.ThrowIfNull(raw);
        ArgumentNullException.ThrowIfNull(zone);
        var facts = ImmutableArray.CreateBuilder<PosteFact>();
        var counts = new Dictionary<FactState, int>();
        foreach (var plan in QuickPlan)
        {
            var entry = plan.Id switch
            {
                "System" => raw.System,
                "LastBoot" => raw.LastBoot,
                "DiskC" => raw.DiskC,
                "Ports" => raw.Ports,
                _ => raw.Services,
            };
            var state = FactState.Unknown;
            var value = "Non exécuté";
            string? hint = null;
            var limit = "Contrôle non tenté (budget épuisé ou diagnostic interrompu)\u00A0: aucune conclusion.";
            if (entry is not null)
            {
                state = entry.Status switch
                {
                    SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial => FactState.Observed,
                    SourceStatus.Refused => FactState.Refused,
                    SourceStatus.Unreachable or SourceStatus.Unavailable or SourceStatus.Error => FactState.Unavailable,
                    _ => FactState.Unknown,
                };
                if (state == FactState.Refused)
                {
                    value = "Lecture refusée";
                    limit = "Un refus ne dit rien de l’état du poste.";
                }
                else if (state == FactState.Unavailable)
                {
                    value = "Lecture impossible";
                    limit = "Aucune conclusion sur ce contrôle.";
                }
                else if (state == FactState.Unknown)
                {
                    value = "Non tenté";
                    limit = "Contrôle non tenté\u00A0: aucune conclusion.";
                }
                else if (plan.Id == "System")
                {
                    value = ((raw.Caption ?? "") + " " + (raw.Version ?? "")).Trim();
                    limit = "Lu au moment du diagnostic.";
                    if (value.Length == 0)
                    {
                        state = FactState.Unknown;
                        value = "Valeurs absentes de la réponse";
                    }
                }
                else if (plan.Id == "LastBoot")
                {
                    limit = "Heure déclarée par le poste.";
                    if (raw.LastBootAt is not DateTimeOffset boot)
                    {
                        state = FactState.Unknown;
                        value = "Date absente de la réponse";
                    }
                    else if (boot > now)
                    {
                        state = FactState.Estimated;
                        value = PosteText.LocalDateTime(boot, zone) + " (postérieure à la lecture\u00A0: horloge à vérifier)";
                    }
                    else
                    {
                        value = "Démarré le " + PosteText.LocalDateTime(boot, zone) + ", en service depuis " + PosteText.Duration(now - boot);
                    }
                }
                else if (plan.Id == "DiskC")
                {
                    limit = "Volume C: uniquement.";
                    if (raw.FreeBytes is not long free || raw.SizeBytes is not long size || size <= 0 || free < 0 || free > size)
                    {
                        state = FactState.Unknown;
                        value = "Taille ou espace libre absent ou incohérent dans la réponse";
                    }
                    else
                    {
                        var percent = Math.Round(100d * free / size);
                        value = PosteText.Size(free) + " libres sur " + PosteText.Size(size) + " (" + FrenchText.Percent(percent, 0) + ")";
                        if (percent < 10)
                        {
                            hint = "Moins de 10\u00A0% libres\u00A0: les mises à jour peuvent échouer.";
                        }
                    }
                }
                else if (plan.Id == "Ports")
                {
                    var tested = 0;
                    var parts = new List<string>();
                    foreach (var port in new[] { 135, 445, 5985 })
                    {
                        var found = raw.PortResults.FirstOrDefault(p => p.Port == port);
                        var text = "non testé";
                        if (found.Port == port && found.Open is bool open)
                        {
                            tested++;
                            text = open ? "ouvert" : "fermé ou filtré";
                        }
                        parts.Add(port.ToString(System.Globalization.CultureInfo.InvariantCulture) + " " + text);
                    }
                    value = string.Join(", ", parts);
                    limit = "Un port fermé ou filtré ne prouve pas que le poste est éteint.";
                    if (tested == 0)
                    {
                        state = FactState.Unknown;
                        limit = "Aucun port testé\u00A0: aucune conclusion.";
                    }
                }
                else
                {
                    var read = 0;
                    var parts = new List<string>();
                    foreach (var name in QuickServices)
                    {
                        var found = raw.ServiceResults.FirstOrDefault(r => string.Equals(r.Name, name, StringComparison.OrdinalIgnoreCase));
                        if (found.Name is null)
                        {
                            parts.Add(name + FrenchText.Colon + "non lu");
                            continue;
                        }
                        read++;
                        if (!found.Present)
                        {
                            parts.Add(name + FrenchText.Colon + "non installé");
                            continue;
                        }
                        var running = found.State switch { "Running" => "démarré", "Stopped" => "arrêté", _ => found.State ?? "" };
                        var mode = found.StartMode switch { "Auto" => "automatique", "Manual" => "manuel", "Disabled" => "désactivé", _ => found.StartMode ?? "" };
                        parts.Add(name + FrenchText.Colon + running + (mode.Length > 0 ? " (" + mode + ")" : ""));
                    }
                    value = string.Join("\u00A0; ", parts);
                    limit = "Lecture de l’état uniquement\u00A0: aucun service n’est démarré ni modifié.";
                    if (read == 0)
                    {
                        state = FactState.Unknown;
                        limit = "Aucun service lu\u00A0: aucune conclusion.";
                    }
                }
                if (!string.IsNullOrWhiteSpace(entry.Detail) && state is FactState.Refused or FactState.Unavailable or FactState.Unknown)
                {
                    value += FrenchText.Colon + PosteText.Flat(entry.Detail, 160);
                }
            }
            if (entry?.Status == SourceStatus.Partial) { limit += " Lecture partielle : les éléments manquants restent inconnus."; }
            counts[state] = counts.GetValueOrDefault(state) + 1;
            facts.Add(PosteText.Fact(plan.Label, value, state, plan.Source + (reader.Length > 0 ? ", lu par " + reader : ""), limit, hint, now));
        }
        var overrun = raw.ElapsedMs is int ms && ms > QuickBudgetSeconds * 1000;
        var duration = raw.ElapsedMs is int elapsed
            ? FrenchText.Decimal(elapsed / 1000d, 1) + "\u00A0s pour un budget de " + FrenchText.Integer(QuickBudgetSeconds) + "\u00A0s." + (overrun ? " Budget dépassé\u00A0: les contrôles en retard doivent être interrompus." : "")
            : "Durée non mesurée.";
        var summary = FrenchText.Count(counts.GetValueOrDefault(FactState.Observed), "constaté", "constatés") + ", " + FrenchText.Count(counts.GetValueOrDefault(FactState.Refused), "refusé", "refusés") + ", "
            + FrenchText.Count(counts.GetValueOrDefault(FactState.Unavailable), "indisponible", "indisponibles") + ", " + FrenchText.Count(counts.GetValueOrDefault(FactState.Unknown) + counts.GetValueOrDefault(FactState.Estimated), "non concluant", "non concluants")
            + " sur " + FrenchText.Integer(QuickPlan.Length) + " contrôles.";
        return new QuickDiagResult(computer, now, facts.ToImmutable(), summary, counts.GetValueOrDefault(FactState.Observed) == QuickPlan.Length
            && new[] { raw.System, raw.LastBoot, raw.DiskC, raw.Ports, raw.Services }.All(r => r?.Status is SourceStatus.Ok or SourceStatus.Empty), overrun, duration, QuickCostText, QuickFallback);
    }
}
