using System.Collections.Immutable;
using System.Globalization;
using System.Text;

namespace Domenia.Core;

/// <summary>One dated fact with its source and its limit (Domenia 1 New-DomeniaFact): an unknown value stays unknown.</summary>
public sealed record FicheFact(string Group, string Label, string Value, string State, string Source, string? Limit, string? Hypothesis);

/// <summary>Approximate logon activity from lastLogonTimestamp alone (FIC-041): never a presence measure.</summary>
public sealed record FicheLogonActivity(string State, DateTimeOffset? Approx, int? AgeDays, string Text, string? Badge, string? BadgeTone);

/// <summary>msDS-LogonTimeSyncInterval of the domain head (Get-DomeniaLogonSyncInterval).</summary>
public sealed record FicheLogonInterval(int Days, string State, string Text);

/// <summary>lastLogon of one controller, read on demand (reader output of fiche.logonByDc).</summary>
public sealed record FicheLogonReading(string Controller, string Type, string State, DateTimeOffset? LastLogon, int? LogonCount, string? Error);

/// <summary>Readings of every controller listed when the read started.</summary>
public sealed record FicheLogonReadings(ImmutableArray<FicheLogonReading> Readings, int KnownCount, bool ListTruncated, FicheLogonInterval Interval, DateTimeOffset ReadAt);

/// <summary>One row of the per-controller table (improvement: sortable table, logonCount shown).</summary>
public sealed record FicheLogonRow(string Controller, string Type, string State, string Value, DateTimeOffset? At, int? LogonCount);

/// <summary>Result of fiche.logonByDc (Merge-DomeniaLogonReadings).</summary>
public sealed record FicheLogonResult(
    ImmutableArray<FicheLogonRow> Rows,
    DateTimeOffset? MostRecent,
    string? MostRecentController,
    int ReadCount,
    int KnownCount,
    bool Complete,
    ImmutableArray<string> Missing,
    int? LogonCount,
    string Text,
    FicheLogonInterval Interval,
    DateTimeOffset ReadAt);

/// <summary>One 4740 event of the account (reader output).</summary>
public sealed record FicheLockoutEvent(DateTimeOffset At, string? CallerComputer, string Controller);

/// <summary>Read of the Security journal of the PDC emulator for one SID (reader output of fiche.lockouts).</summary>
public sealed record FicheLockoutRead(string State, string Controller, string ControllerRole, int Hours, int MaxEvents, bool Truncated, ImmutableArray<FicheLockoutEvent> Events, DateTimeOffset ReadAt, string? Error);

/// <summary>An authentication refusal recorded by Domenia itself (credential guard), for the lockout timeline.</summary>
public sealed record FicheDomeniaRefusal(DateTimeOffset At, string? Key, string Kind);

/// <summary>One lockout of the timeline, beside the refusals of Domenia just before (Get-DomeniaLockoutTimeline).</summary>
public sealed record FicheLockoutRow(DateTimeOffset At, string Local, string Computer, string Controller, string Domenia, bool DomeniaNear);

/// <summary>Result of fiche.lockouts (Get-DomeniaLockoutDiagnosis and Format-DomeniaLockoutReport).</summary>
public sealed record FicheLockoutDiagnosis(
    string Verdict,
    int Recurrence,
    ImmutableArray<string> Origins,
    ImmutableArray<FicheFact> Facts,
    ImmutableArray<FicheLockoutRow> Rows,
    int NearCount,
    string State,
    string Controller,
    int Hours,
    bool Truncated,
    DateTimeOffset ReadAt,
    string Report);

/// <summary>Password policy read for one account (reader output): fine-grained policy, domain policy, or unreadable.</summary>
public sealed record FichePolicyReading(
    string State,
    string? PsoName,
    TimeSpan? MaxAge,
    bool MaxAgeNever,
    int? MinLength,
    int? History,
    bool? Complexity,
    int? LockoutThreshold,
    TimeSpan? LockoutDuration,
    bool LockoutNever,
    string Controller,
    DateTimeOffset ReadAt);

/// <summary>Resolved password policy and expiry (Resolve-DomeniaPasswordPolicy).</summary>
public sealed record FichePolicyView(bool Known, string Source, DateTimeOffset? Expires, string ExpiryState, string Summary, ImmutableArray<FicheFact> Facts);

/// <summary>One access control entry of the object that matches the session token (simulated or read).</summary>
public sealed record FicheAce(bool Deny, string Trustee, long Rights, bool ResetPassword, string? InheritedFrom);

/// <summary>Security descriptor read for the rights estimate (reader output of fiche.rights).</summary>
public sealed record FicheSecurityReading(bool Available, string? Error, string Owner, int TokenSids, ImmutableArray<FicheAce> Aces, DateTimeOffset ReadAt);

/// <summary>One capability of the estimate (Start-PermissionAnalysis), with the entry that decides it (improvement of FIC-003).</summary>
public sealed record FicheCapability(string Id, string Capability, string State, string StateLabel, string Source, string Detail, string? Ace);

/// <summary>Result of fiche.rights.</summary>
public sealed record FicheRights(bool Available, string? Reason, string Owner, int MatchingAces, int TokenSids, ImmutableArray<FicheCapability> Rows, string Note, string Report, DateTimeOffset ReadAt);

/// <summary>Freshness of one nature of data (Get-DomeniaFreshness, FIC-036).</summary>
public sealed record FicheFreshness(string Nature, string Label, string State, DateTimeOffset? ObservedAt, long? AgeSeconds, string Text);

/// <summary>Support band of a user fiche (Update-DomeniaUserSupportBand, FIC-048): only what the controller answered.</summary>
public sealed record FicheBand(string Tone, ImmutableArray<string> Alerts, string? Limits, bool Unlock, bool Lockouts);

/// <summary>
/// Pure diagnostics of the fiche: logon activity and per-controller readings (Domenia-LogonActivity.Model), lockout
/// diagnosis and timeline (Domenia-Directory.Model), password policy, rights estimate (Start-PermissionAnalysis),
/// freshness per nature (Domenia-Cache.Model) and the support band. No clock read: « now » and the zone are inputs.
/// </summary>
public static class FicheDiagnostics
{
    private static readonly string C = FrenchText.Colon;

    /// <summary>Interval of the domain head (Get-DomeniaLogonSyncInterval): read, default when absent, or 14 days assumed.</summary>
    public static FicheLogonInterval Interval(int? days, string readState)
    {
        if (readState == "read" && days is int value and >= 0 and <= 100000)
        {
            return new FicheLogonInterval(value, "read", value == 0
                ? "msDS-LogonTimeSyncInterval vaut 0 sur ce domaine" + C + "Domenia n’en déduit aucun délai."
                : "Intervalle de mise à jour lu sur le domaine" + C + FrenchText.Count(value, "jour", "jours") + ".");
        }
        return readState switch
        {
            "absent" => new FicheLogonInterval(14, "default", "Intervalle de mise à jour non défini sur le domaine" + C + "14 jours par défaut."),
            "refused" => new FicheLogonInterval(14, "refused", "Intervalle de mise à jour non lisible avec ce compte" + C + "14 jours par défaut supposés."),
            _ => new FicheLogonInterval(14, "notRead", "Intervalle de mise à jour non lu" + C + "14 jours par défaut supposés."),
        };
    }

    /// <summary>How late lastLogonTimestamp may be (Get-DomeniaLogonLagText).</summary>
    public static string LagText(int days) =>
        days <= 0 ? "un délai que Domenia ne détermine pas"
        : days > 5 ? FrenchText.Integer(days - 5) + " à " + FrenchText.Integer(days) + " jours"
        : "au plus " + FrenchText.Count(days, "jour", "jours");

    /// <summary>
    /// Approximate activity from lastLogonTimestamp (Get-DomeniaLogonActivitySummary): an empty value proves nothing, a future
    /// date asks for a clock check; badge « inactif depuis N jours » beyond 90 days (improvement, same threshold as the queries).
    /// </summary>
    public static FicheLogonActivity Activity(DateTimeOffset? lastLogonTimestamp, FicheLogonInterval interval, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(interval);
        ArgumentNullException.ThrowIfNull(zone);
        if (lastLogonTimestamp is not DateTimeOffset at)
        {
            return new FicheLogonActivity("empty", null, null,
                "Activité approximative" + C + "lastLogonTimestamp est vide. Cela ne prouve pas qu’aucune connexion n’a eu lieu ; la lecture par contrôleur donne la valeur exacte de chacun.",
                "Aucune connexion répliquée", "off");
        }
        if (at > now.AddMinutes(5))
        {
            return new FicheLogonActivity("future", at, null,
                "Activité approximative" + C + "date de connexion dans le futur (" + FicheValues.LocalDateTime(at, zone) + ") ; vérifiez l’horloge avant de vous y fier.",
                "Horloge à vérifier", "warn");
        }
        var age = (int)Math.Floor((now - at).TotalDays);
        var text = "Activité approximative" + C + "dernière connexion connue vers le " + FicheValues.LocalDate(at, zone)
            + " (lastLogonTimestamp, répliqué). Cette date n’est actualisée que lorsqu’elle a plus de " + LagText(interval.Days)
            + " : une connexion plus récente peut ne pas y figurer. Elle ne prouve pas une présence actuelle.";
        if (interval.State is not ("read" or "default"))
        {
            text += " Délai calculé sur l’intervalle par défaut de 14 jours" + C + "celui du domaine n’a pas été lu.";
        }
        string? badge = null;
        string? tone = null;
        if (age > 90)
        {
            badge = "Inactif depuis " + FrenchText.Count(age, "jour", "jours");
            tone = "warn";
        }
        else if (age <= interval.Days)
        {
            badge = "Actif ces " + FrenchText.Count(interval.Days, "jour", "jours");
            tone = "ok";
        }
        return new FicheLogonActivity("approx", at, age, text, badge, tone);
    }

    /// <summary>
    /// Exact lastLogon of each controller (Merge-DomeniaLogonReadings): the most recent value is the last logon known to the
    /// domain only when every listed controller answered. logonCount is shown (read but never shown by Domenia 1).
    /// </summary>
    public static FicheLogonResult MergeReadings(FicheLogonReadings readings, DateTimeOffset? lastLogonTimestamp, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(readings);
        ArgumentNullException.ThrowIfNull(zone);
        var rows = new List<FicheLogonRow>();
        var missing = new List<string>();
        var read = 0;
        DateTimeOffset? best = null;
        string? bestDc = null;
        int? logonCount = null;
        foreach (var reading in readings.Readings)
        {
            string value;
            switch (reading.State)
            {
                case "read":
                    read++;
                    if (reading.LogonCount is int count)
                    {
                        logonCount = Math.Max(logonCount ?? 0, count);
                    }
                    if (reading.LastLogon is DateTimeOffset at)
                    {
                        value = TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy HH':'mm':'ss", CultureInfo.InvariantCulture);
                        if (best is null || at > best)
                        {
                            best = at;
                            bestDc = reading.Controller;
                        }
                    }
                    else
                    {
                        value = "Aucune connexion enregistrée par ce contrôleur";
                    }
                    break;
                case "absent":
                    missing.Add(reading.Controller);
                    value = "Objet absent de ce contrôleur (réplication en cours ou droits)";
                    break;
                case "refused":
                    missing.Add(reading.Controller);
                    value = "Lecture refusée pour ce compte";
                    break;
                case "unavailable":
                    missing.Add(reading.Controller);
                    value = "Contrôleur non joint" + (string.IsNullOrEmpty(reading.Error) ? "" : C + reading.Error);
                    break;
                default:
                    missing.Add(reading.Controller);
                    value = "Non lu" + C + "budget de temps atteint";
                    break;
            }
            rows.Add(new FicheLogonRow(reading.Controller, reading.Type, reading.State, value, reading.LastLogon, reading.LogonCount));
        }
        var known = Math.Max(readings.KnownCount, rows.Count);
        var complete = known > 0 && read == known && !readings.ListTruncated;
        var lines = new List<string>();
        if (best is DateTimeOffset mostRecent)
        {
            lines.Add("Connexion la plus récente lue" + C + TimeZoneInfo.ConvertTime(mostRecent, zone).ToString("dd'/'MM'/'yyyy HH':'mm':'ss", CultureInfo.InvariantCulture) + " sur " + bestDc + ".");
        }
        else if (read > 0)
        {
            lines.Add("Aucune connexion enregistrée par les contrôleurs qui ont répondu.");
        }
        else
        {
            lines.Add("Aucun contrôleur n’a répondu" + C + "aucune valeur exacte.");
        }
        var coverage = "Couverture" + C + FrenchText.Integer(read) + " contrôleur(s) lu(s) sur " + FrenchText.Integer(known) + " recensé(s)";
        if (readings.ListTruncated)
        {
            coverage += ", liste des contrôleurs tronquée";
        }
        lines.Add(coverage + ".");
        if (complete)
        {
            lines.Add("Tous les contrôleurs recensés ont répondu" + C + "la date la plus récente est la dernière connexion connue du domaine au moment de la lecture.");
        }
        else if (missing.Count > 0)
        {
            lines.Add("Une connexion plus récente peut avoir été validée par un contrôleur non lu" + C + string.Join(", ", missing.Take(10)) + (missing.Count > 10 ? "…" : "") + ".");
        }
        if (best is DateTimeOffset b && lastLogonTimestamp is DateTimeOffset stamp && b > stamp)
        {
            var lag = (int)Math.Floor((b - stamp).TotalDays);
            if (lag >= 1)
            {
                lines.Add("lastLogonTimestamp a " + FrenchText.Count(lag, "jour", "jours") + " de retard sur cette date" + C + "écart attendu de sa mise à jour espacée.");
            }
        }
        lines.Add("lastLogon n’est pas répliqué" + C + "chaque contrôleur ne connaît que les connexions qu’il a validées. Une connexion ne prouve pas une présence actuelle.");
        var ordered = rows.OrderByDescending(r => r.At ?? DateTimeOffset.MinValue).ThenBy(r => r.Controller, StringComparer.Ordinal).ToImmutableArray();
        return new FicheLogonResult(ordered, best, bestDc, read, known, complete, [.. missing], logonCount, string.Join(" ", lines), readings.Interval, readings.ReadAt);
    }

    /// <summary>
    /// Lockout diagnosis (Get-DomeniaLockoutDiagnosis) with the timeline of the refusals of Domenia (Get-DomeniaLockoutTimeline,
    /// 120 s, 5 s of skew). A refusal or an unreachable journal concludes nothing.
    /// </summary>
    public static FicheLockoutDiagnosis Lockouts(FicheEntry user, FicheLockoutRead read, IReadOnlyList<FicheDomeniaRefusal> refusals, IReadOnlyCollection<string> accountKeys, TimeSpan lockoutDuration, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(refusals);
        ArgumentNullException.ThrowIfNull(accountKeys);
        ArgumentNullException.ThrowIfNull(zone);
        var facts = new List<FicheFact>();
        var source = "Contrôleur " + read.Controller;
        var state = AccountState.Evaluate(user.Int32("userAccountControl") ?? 0, user.Int32("msDS-User-Account-Control-Computed"), user.Int64("lockoutTime"));
        var computedKnown = user.Has("msDS-User-Account-Control-Computed");
        var verdict = "unknown";
        if (computedKnown && state.Lock == LockState.Locked)
        {
            verdict = "locked";
            facts.Add(new FicheFact("Compte", "État calculé par le contrôleur", "Verrouillé", "known", source, null, null));
        }
        else if (computedKnown)
        {
            verdict = "unlocked";
            facts.Add(new FicheFact("Compte", "État calculé par le contrôleur", "Non verrouillé", "known", source, null, null));
        }
        else
        {
            facts.Add(new FicheFact("Compte", "État calculé par le contrôleur", "Non lu", "unknown", source, "Sans cet état, un lockoutTime non nul ne prouve pas un verrouillage actuel.", null));
        }
        if (user.FileTime("lockoutTime") is DateTimeOffset lockedAt)
        {
            var text = TimeZoneInfo.ConvertTime(lockedAt, zone).ToString("dd'/'MM'/'yyyy HH':'mm':'ss", CultureInfo.InvariantCulture);
            if (lockoutDuration > TimeSpan.Zero && verdict != "locked" && lockedAt + lockoutDuration < now)
            {
                text += " (durée de verrouillage écoulée)";
            }
            facts.Add(new FicheFact("Compte", "Dernier verrouillage", text, "known", source, "Date du dernier verrouillage enregistré, pas son état actuel.", null));
        }
        if (user.First("badPwdCount") is string bad)
        {
            facts.Add(new FicheFact("Compte", "Échecs de mot de passe", bad, "known", source, "Compteur propre à ce contrôleur" + C + "il n’est pas répliqué.", null));
        }
        if (user.FileTime("badPasswordTime") is DateTimeOffset badAt)
        {
            facts.Add(new FicheFact("Compte", "Dernier échec", TimeZoneInfo.ConvertTime(badAt, zone).ToString("dd'/'MM'/'yyyy HH':'mm':'ss", CultureInfo.InvariantCulture), "known", source, "Valeur propre à ce contrôleur.", null));
        }
        var journal = "Journal Sécurité de " + read.Controller;
        var rows = ImmutableArray<FicheLockoutRow>.Empty;
        var origins = ImmutableArray<string>.Empty;
        var near = 0;
        switch (read.State)
        {
            case "read":
                var list = read.Events;
                origins = [.. list.Select(e => e.CallerComputer).Where(n => !string.IsNullOrEmpty(n)).GroupBy(n => n!, StringComparer.OrdinalIgnoreCase)
                    .OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).Select(g => g.Key + " (" + FrenchText.Integer(g.Count()) + ")")];
                if (list.Length > 0)
                {
                    facts.Add(new FicheFact("Journal", "Verrouillages journalisés", FrenchText.Count(list.Length, "événement 4740", "événements 4740"), read.Truncated ? "incomplete" : "known", journal,
                        "Fenêtre et volume bornés ; un journal recyclé peut ne plus contenir les événements anciens.", null));
                    if (origins.Length > 0)
                    {
                        facts.Add(new FicheFact("Journal", "Postes à l’origine", string.Join(", ", origins), "known", journal, null,
                            "Un poste récurrent suggère une session, un lecteur réseau ou un service utilisant un ancien mot de passe."));
                    }
                    (rows, near) = Timeline(list, refusals, accountKeys, zone);
                    facts.Add(near > 0
                        ? new FicheFact("Journal", "Refus de Domenia avant un verrouillage", FrenchText.Integer(near) + " sur " + FrenchText.Integer(list.Length), "known", "Protection des comptes de Domenia",
                            "Rapprochement horaire à 120 s, horloges du poste et du contrôleur non comparées.",
                            "Domenia a essuyé un refus d’authentification pour ce compte juste avant" + C + "vérifier d’abord le mot de passe saisi dans Domenia.")
                        : new FicheFact("Journal", "Refus de Domenia avant un verrouillage", "Aucun", "known", "Protection des comptes de Domenia", "Refus enregistrés pendant cette exécution de Domenia seulement.", null));
                }
                else
                {
                    facts.Add(new FicheFact("Journal", "Verrouillages journalisés", "Aucun dans la fenêtre lue", "known", journal, "Absence dans la fenêtre lue seulement.", null));
                }
                break;
            case "refused":
                facts.Add(new FicheFact("Journal", "Verrouillages journalisés", "Lecture refusée", "refused", journal,
                    "Un refus de lecture ne signifie pas qu’aucun verrouillage n’a eu lieu : le compte doit être membre de « Lecteurs des journaux d’événements » du contrôleur.", null));
                break;
            default:
                facts.Add(new FicheFact("Journal", "Verrouillages journalisés", "Journal injoignable", "unavailable", journal, "Aucune conclusion sur les verrouillages passés.", null));
                break;
        }
        var report = LockoutReport(user, read, facts, rows, zone);
        return new FicheLockoutDiagnosis(verdict, read.State == "read" ? read.Events.Length : 0, origins, [.. facts], rows, near, read.State, read.Controller, read.Hours, read.Truncated, read.ReadAt, report);
    }

    private static (ImmutableArray<FicheLockoutRow> Rows, int Near) Timeline(ImmutableArray<FicheLockoutEvent> events, IReadOnlyList<FicheDomeniaRefusal> refusals, IReadOnlyCollection<string> accountKeys, TimeZoneInfo zone)
    {
        const int tolerance = 120;
        var keys = new HashSet<string>(accountKeys.Where(k => !string.IsNullOrWhiteSpace(k)).Select(k => k.Trim()), StringComparer.OrdinalIgnoreCase);
        var own = refusals.Where(r => string.IsNullOrEmpty(r.Key) || keys.Contains(r.Key!)).ToList();
        var rows = new List<FicheLockoutRow>();
        var near = 0;
        foreach (var e in events.OrderByDescending(e => e.At))
        {
            FicheDomeniaRefusal? best = null;
            double bestDelta = 0;
            foreach (var f in own)
            {
                var delta = (e.At - f.At).TotalSeconds;
                if (delta >= -5 && delta <= tolerance && (best is null || Math.Abs(delta) < Math.Abs(bestDelta)))
                {
                    best = f;
                    bestDelta = delta;
                }
            }
            var domenia = "aucun refus Domenia à " + FrenchText.Integer(tolerance) + " s";
            if (best is not null)
            {
                near++;
                domenia = "refus Domenia " + FrenchText.Integer((long)Math.Round(Math.Max(0, bestDelta))) + " s avant" + (string.IsNullOrEmpty(best.Key) ? " (compte non attribué)" : "");
            }
            rows.Add(new FicheLockoutRow(e.At, TimeZoneInfo.ConvertTime(e.At, zone).ToString("dd'/'MM'/'yyyy HH':'mm':'ss", CultureInfo.InvariantCulture),
                string.IsNullOrEmpty(e.CallerComputer) ? "non renseigné" : e.CallerComputer!, e.Controller, domenia, best is not null));
        }
        return ([.. rows], near);
    }

    private static string LockoutReport(FicheEntry user, FicheLockoutRead read, List<FicheFact> facts, ImmutableArray<FicheLockoutRow> rows, TimeZoneInfo zone)
    {
        var builder = new StringBuilder();
        builder.Append("Verrouillages du compte ").Append(user.First("sAMAccountName") ?? user.Name).Append(" (lecture seule)").Append("\r\n");
        builder.Append("Journal Sécurité de ").Append(read.Controller).Append(" (").Append(read.ControllerRole).Append("), fenêtre de ")
            .Append(FrenchText.Count(read.Hours, "heure", "heures")).Append(", lu le ").Append(FicheValues.LocalDateTime(read.ReadAt, zone)).Append("\r\n\r\n");
        foreach (var fact in facts)
        {
            builder.Append("- ").Append(fact.Label).Append(C).Append(fact.Value);
            if (fact.Limit is not null)
            {
                builder.Append(" (").Append(fact.Limit).Append(')');
            }
            builder.Append("\r\n");
        }
        if (rows.Length > 0)
        {
            builder.Append("\r\nÉvénements 4740\r\n");
            foreach (var row in rows)
            {
                builder.Append("- ").Append(row.Local).Append(" · poste ").Append(row.Computer).Append(" · ").Append(row.Controller).Append(" · ").Append(row.Domenia).Append("\r\n");
            }
        }
        if (read.Truncated)
        {
            builder.Append("\r\nLecture tronquée à ").Append(FrenchText.Integer(read.MaxEvents)).Append(" événements.\r\n");
        }
        builder.Append("\r\nUn poste indiqué est celui que le contrôleur a noté : une session, un lecteur réseau ou un service peut y garder un ancien mot de passe.");
        return builder.ToString();
    }

    /// <summary>
    /// Effective password policy and expiry (Resolve-DomeniaPasswordPolicy): the controller’s computed expiry first; otherwise an
    /// estimate only when the policy is known. An absent duration is never « no limit ».
    /// </summary>
    public static FichePolicyView Policy(FicheEntry user, FichePolicyReading? reading, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(zone);
        var facts = new List<FicheFact>();
        var known = reading is { State: "applies" or "none" };
        var source = reading switch
        {
            { State: "applies" } fine => "Stratégie fine" + C + (fine.PsoName ?? "sans nom"),
            { State: "none" } => "Stratégie du domaine",
            _ => "",
        };
        if (!known)
        {
            facts.Add(new FicheFact("Stratégie", "Stratégie applicable", "Inconnue", "unknown", "msDS-ResultantPSO", "Stratégie non lue ou non lisible avec ce compte" + C + "aucune valeur n’est déduite de la stratégie du domaine.", null));
        }
        else
        {
            facts.Add(new FicheFact("Stratégie", "Stratégie applicable", source, "known", "msDS-ResultantPSO", null, null));
            if (reading!.MinLength is int min)
            {
                facts.Add(new FicheFact("Stratégie", "Longueur minimale", FrenchText.Count(min, "caractère", "caractères"), "known", source, null, null));
            }
            if (reading.Complexity is bool complex)
            {
                facts.Add(new FicheFact("Stratégie", "Complexité exigée", complex ? "Oui" : "Non", "known", source, null, null));
            }
            if (reading.History is int history)
            {
                facts.Add(new FicheFact("Stratégie", "Historique", FrenchText.Count(history, "mot de passe", "mots de passe"), "known", source, null, null));
            }
            facts.Add(reading.MaxAgeNever
                ? new FicheFact("Stratégie", "Durée de validité", "Sans limite", "known", source, null, null)
                : reading.MaxAge is TimeSpan age
                    ? new FicheFact("Stratégie", "Durée de validité", FrenchText.Count((long)age.TotalDays, "jour", "jours"), "known", source, null, null)
                    : new FicheFact("Stratégie", "Durée de validité", "Non lue", "unknown", source, "Durée absente de la lecture ou illisible" + C + "aucune absence de limite n’est déduite.", null));
            if (reading.LockoutThreshold is int threshold)
            {
                var text = threshold == 0 ? "Aucun verrouillage" : FrenchText.Count(threshold, "échec", "échecs");
                var lockState = "known";
                string? limit = null;
                if (threshold != 0)
                {
                    if (reading.LockoutNever)
                    {
                        text += ", déverrouillage par un administrateur";
                    }
                    else if (reading.LockoutDuration is TimeSpan duration)
                    {
                        text += ", durée " + FrenchText.Integer((long)duration.TotalMinutes) + " min";
                    }
                    else
                    {
                        text += ", durée de verrouillage non lue";
                        lockState = "unknown";
                        limit = "lockoutDuration absent de la lecture ou illisible.";
                    }
                }
                facts.Add(new FicheFact("Stratégie", "Verrouillage", text, lockState, source, limit, null));
            }
        }
        var uac = user.Int32("userAccountControl");
        var neverExpires = uac is int u && AdValues.HasFlag(u, AdValues.DontExpirePassword);
        var computed = user.Int64("msDS-UserPasswordExpiryTimeComputed");
        var pwdLastSet = user.Int64("pwdLastSet");
        DateTimeOffset? expires = null;
        var expiryText = "";
        var expiryState = "known";
        string? expiryLimit = null;
        if (neverExpires)
        {
            expiryText = "N’expire jamais (option du compte)";
        }
        else if (pwdLastSet == 0)
        {
            expiryText = "À changer à la prochaine ouverture de session";
        }
        else if (computed is long value && value != 0)
        {
            if (value == AdValues.Never)
            {
                expiryText = "N’expire pas";
            }
            else if (AdValues.FromFileTime(value) is DateTimeOffset at)
            {
                expires = at;
                expiryText = FicheValues.LocalDateTime(at, zone);
            }
        }
        else if (known)
        {
            if (reading!.MaxAgeNever)
            {
                expiryText = "N’expire pas (stratégie sans limite)";
            }
            else if (reading.MaxAge is TimeSpan maxAge && AdValues.FromFileTime(pwdLastSet) is DateTimeOffset lastSet)
            {
                expires = lastSet + maxAge;
                expiryText = FicheValues.LocalDateTime(expires.Value, zone);
                expiryState = "estimated";
                expiryLimit = "Calculé à partir de la stratégie lue ; valeur du contrôleur non disponible.";
            }
        }
        if (expiryText.Length == 0)
        {
            expiryText = "Inconnue";
            expiryState = "unknown";
            expiryLimit = "Stratégie ou date de changement non lisible.";
        }
        else if (expires is DateTimeOffset e && e < now)
        {
            expiryText += " (échu)";
        }
        facts.Add(new FicheFact("Compte", "Expiration du mot de passe", expiryText, expiryState, "Compte utilisateur", expiryLimit, null));
        if (uac is int flags)
        {
            if (AdValues.HasFlag(flags, AdValues.SmartCardRequired))
            {
                facts.Add(new FicheFact("Compte", "Restriction", "Carte à puce exigée" + C + "le mot de passe n’est pas utilisable pour ouvrir une session interactive.", "known", "userAccountControl", null, null));
            }
            if (AdValues.HasFlag(flags, AdValues.PasswordNotRequired))
            {
                facts.Add(new FicheFact("Compte", "Restriction", "Mot de passe non requis (PASSWD_NOTREQD)" + C + "à revoir.", "known", "userAccountControl", null, null));
            }
            if (AdValues.IsDisabled(flags))
            {
                facts.Add(new FicheFact("Compte", "Restriction", "Compte désactivé.", "known", "userAccountControl", null, null));
            }
        }
        var summary = known ? source + (reading is null ? "" : ", lue sur " + reading.Controller + " le " + FicheValues.LocalDateTime(reading.ReadAt, zone)) + "." : "Stratégie applicable non lue.";
        return new FichePolicyView(known, source, expires, expiryState, summary, [.. facts]);
    }

    // Rights masks of System.DirectoryServices.ActiveDirectoryRights, as Domenia 1 combined them.
    private const long CreateChild = 0x1;
    private const long ListChildren = 0x4;
    private const long Self = 0x8;
    private const long ReadProperty = 0x10;
    private const long WriteProperty = 0x20;
    private const long DeleteTree = 0x40;
    private const long ListObject = 0x80;
    private const long ExtendedRight = 0x100;
    private const long Delete = 0x10000;
    private const long WriteDacl = 0x40000;
    private const long WriteOwner = 0x80000;
    private const long GenericAll = 0xF01FF;

    private static readonly (string Id, string Label, long Mask, string Detail)[] Capabilities =
    [
        // Masks without ReadControl (0x20000, shared by GenericRead and GenericWrite): Domenia 1 combined the generic masks whole,
        // so a mere GenericRead entry read as « Modifier : autorisé ». Only the specific bits decide here (GenericRead = 0x94 +
        // ReadControl, GenericWrite = 0x28 + ReadControl).
        ("read", "Lecture de l’objet", ReadProperty | ListObject | ListChildren, "Lecture des propriétés, liste et accès générique"),
        ("edit", "Modifier les attributs", WriteProperty | Self, "WriteProperty ou GenericWrite"),
        ("account", "Gestion du compte", WriteProperty | Self | ExtendedRight, "Activation, verrouillage, expiration et options"),
        ("password", "Réinitialiser le mot de passe", 0, "Droit étendu « Réinitialiser le mot de passe »"),
        ("group", "Gestion des groupes", WriteProperty | Self, "Modification de member / memberOf"),
        // Moving or renaming removes the object from its parent: WriteProperty alone never allows it (Domenia 1 counted it).
        ("move", "Déplacer ou renommer", Delete | DeleteTree, "Delete sur l’objet ; nécessite aussi CreateChild sur la cible"),
        ("delete", "Supprimer l’objet", Delete | DeleteTree, "Delete ou DeleteTree"),
        ("create", "Créer un objet enfant", CreateChild, "CreateChild sur le conteneur"),
        ("secrets", "Lire les secrets", 0, "BitLocker et LAPS utilisent des attributs confidentiels"),
        ("acl", "Modifier les autorisations", WriteDacl | WriteOwner, "WriteDacl ou WriteOwner"),
    ];

    /// <summary>
    /// Rights estimate (Start-PermissionAnalysis): the DACL entries that match the session token decide each of ten capabilities,
    /// a deny winning over an allow; « Indéterminé » when none decides. The entry that decides is named (improvement of FIC-003).
    /// An estimate only: the controller stays the final authority.
    /// </summary>
    public static FicheRights Rights(FicheSecurityReading reading, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(reading);
        ArgumentNullException.ThrowIfNull(zone);
        const string note = "Estimation seulement : le contrôleur de domaine reste l’autorité finale ; seul un refus réel du contrôleur verrouille une action.";
        if (!reading.Available)
        {
            var reason = reading.Error ?? "Le descripteur de sécurité n’a pas été retourné par le contrôleur de domaine.";
            var unknown = Capabilities.Select(c => new FicheCapability(c.Id, c.Label, "unknown", "Indéterminé", "ACL indisponible", reason, null)).ToImmutableArray();
            return new FicheRights(false, reason, "Non lu", 0, reading.TokenSids, unknown, note, RightsReport(unknown, "Non lu", 0, reading.ReadAt, zone), reading.ReadAt);
        }
        long allow = 0, deny = 0;
        bool genericAllow = false, genericDeny = false, resetAllow = false, resetDeny = false;
        foreach (var ace in reading.Aces)
        {
            if (ace.Deny)
            {
                deny |= ace.Rights;
            }
            else
            {
                allow |= ace.Rights;
            }
            if ((ace.Rights & GenericAll) == GenericAll)
            {
                if (ace.Deny)
                {
                    genericDeny = true;
                }
                else
                {
                    genericAllow = true;
                }
            }
            if (ace.ResetPassword || ((ace.Rights & ExtendedRight) != 0 && (ace.Rights & GenericAll) == GenericAll))
            {
                if (ace.Deny)
                {
                    resetDeny = true;
                }
                else
                {
                    resetAllow = true;
                }
            }
        }
        var rows = new List<FicheCapability>();
        foreach (var (id, label, mask, detail) in Capabilities)
        {
            string state;
            FicheAce? decisive;
            if (id == "password")
            {
                state = genericDeny || resetDeny ? "denied" : genericAllow || resetAllow ? "allowed" : "unknown";
                decisive = reading.Aces.FirstOrDefault(a => a.Deny && (a.ResetPassword || (a.Rights & GenericAll) == GenericAll))
                    ?? reading.Aces.FirstOrDefault(a => !a.Deny && (a.ResetPassword || (a.Rights & GenericAll) == GenericAll));
            }
            else if (id == "secrets")
            {
                state = genericDeny ? "denied" : genericAllow ? "allowed" : "unknown";
                decisive = reading.Aces.FirstOrDefault(a => (a.Rights & GenericAll) == GenericAll);
            }
            else
            {
                state = genericDeny || (deny & mask) != 0 ? "denied" : genericAllow || (allow & mask) != 0 ? "allowed" : "unknown";
                decisive = reading.Aces.FirstOrDefault(a => a.Deny && ((a.Rights & mask) != 0 || (a.Rights & GenericAll) == GenericAll))
                    ?? reading.Aces.FirstOrDefault(a => !a.Deny && ((a.Rights & mask) != 0 || (a.Rights & GenericAll) == GenericAll));
            }
            var stateLabel = state switch { "allowed" => "Autorisé", "denied" => "Refusé", _ => "Indéterminé" };
            rows.Add(new FicheCapability(id, label, state, stateLabel, "DACL", detail, state == "unknown" || decisive is null ? null : AceText(decisive)));
        }
        var result = rows.ToImmutableArray();
        return new FicheRights(true, null, reading.Owner, reading.Aces.Length, reading.TokenSids, result, note, RightsReport(result, reading.Owner, reading.Aces.Length, reading.ReadAt, zone), reading.ReadAt);
    }

    private static string AceText(FicheAce ace) =>
        (ace.Deny ? "Refuser" : "Autoriser") + " · " + ace.Trustee + " · " + RightsText(ace) + (ace.InheritedFrom is null ? " · défini sur l’objet" : " · hérité de " + ace.InheritedFrom);

    private static string RightsText(FicheAce ace)
    {
        if ((ace.Rights & GenericAll) == GenericAll)
        {
            return "Contrôle total";
        }
        var parts = new List<string>();
        if (ace.ResetPassword)
        {
            parts.Add("Réinitialiser le mot de passe");
        }
        if ((ace.Rights & (WriteProperty | Self)) != 0)
        {
            parts.Add("Écrire les propriétés");
        }
        if ((ace.Rights & (ReadProperty | ListChildren | ListObject)) != 0)
        {
            parts.Add("Lire les propriétés");
        }
        if ((ace.Rights & CreateChild) != 0)
        {
            parts.Add("Créer des objets enfants");
        }
        if ((ace.Rights & (Delete | DeleteTree)) != 0)
        {
            parts.Add("Supprimer");
        }
        if ((ace.Rights & (WriteDacl | WriteOwner)) != 0)
        {
            parts.Add("Modifier les autorisations");
        }
        if ((ace.Rights & ExtendedRight) != 0 && !ace.ResetPassword)
        {
            parts.Add("Droits étendus");
        }
        return parts.Count == 0 ? "Droits particuliers" : string.Join(", ", parts);
    }

    private static string RightsReport(ImmutableArray<FicheCapability> rows, string owner, int matching, DateTimeOffset at, TimeZoneInfo zone)
    {
        var builder = new StringBuilder();
        builder.Append("Estimation des droits effectifs (lecture seule), le ").Append(FicheValues.LocalDateTime(at, zone)).Append("\r\n");
        builder.Append("Propriétaire").Append(C).Append(owner).Append(" · entrées correspondant au jeton").Append(C).Append(FrenchText.Integer(matching)).Append("\r\n");
        foreach (var row in rows)
        {
            builder.Append(row.Capability).Append(" | ").Append(row.StateLabel).Append(" | ").Append(row.Source).Append(" | ").Append(row.Detail);
            if (row.Ace is not null)
            {
                builder.Append(" | ").Append(row.Ace);
            }
            builder.Append("\r\n");
        }
        builder.Append("Le contrôleur de domaine reste l’autorité finale.");
        return builder.ToString();
    }

    /// <summary>Freshness of one nature (Get-DomeniaFreshness): identity 24 h, attributes 15 min, presence 2 min, console 5 min, history never stale.</summary>
    public static FicheFreshness Freshness(string nature, DateTimeOffset? observed, DateTimeOffset? lastAttempt, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(nature);
        ArgumentNullException.ThrowIfNull(zone);
        var (label, seconds) = nature switch
        {
            "identity" => ("Identité AD", 86400L),
            "attributes" => ("Attributs AD", 900L),
            "presence" => ("Présence réseau", 120L),
            "console" => ("Session console", 300L),
            _ => ("Historique", 0L),
        };
        if (observed is not DateTimeOffset at)
        {
            var never = lastAttempt is DateTimeOffset attempt
                ? label + C + "tentative sans résultat le " + FicheValues.ShortDateTime(attempt, zone)
                : label + C + "jamais observé";
            return new FicheFreshness(nature, label, "unknown", null, null, never);
        }
        var age = Math.Max(0, (long)(now - at).TotalSeconds);
        var state = nature == "history" ? "historical" : age <= seconds ? "fresh" : "stale";
        var text = label + C + FicheValues.LocalDateTime(at, zone);
        if (state == "stale")
        {
            text += " (à relire)";
        }
        if (state == "historical")
        {
            text += " (historique)";
        }
        if (lastAttempt is DateTimeOffset tried && tried > at)
        {
            text += " · dernière tentative " + FicheValues.ShortDateTime(tried, zone);
        }
        return new FicheFreshness(nature, label, state, at, age, text);
    }

    /// <summary>
    /// Support band (Update-DomeniaUserSupportBand): locked since, state not confirmed, password expired or expiring within 14
    /// days, bad passwords, recent lockout lifted; nothing when the controller said nothing worth it.
    /// </summary>
    public static FicheBand? Band(FicheEntry user, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(zone);
        if (user.Kind != FicheKind.User)
        {
            return null;
        }
        var alerts = new List<string>();
        var limits = new List<string>();
        var uac = user.Int32("userAccountControl");
        var computed = user.Int32("msDS-User-Account-Control-Computed");
        var lockoutTime = user.Int64("lockoutTime");
        var state = AccountState.Evaluate(uac ?? 0, computed, lockoutTime);
        var locked = computed is not null && state.Lock == LockState.Locked;
        var tone = "warn";
        if (locked)
        {
            alerts.Add(user.FileTime("lockoutTime") is DateTimeOffset at ? "Verrouillé depuis le " + FicheValues.ShortDateTime(at, zone) : "Verrouillé");
            limits.Add("Heure du dernier verrouillage relevée sur le contrôleur interrogé.");
            tone = "alert";
        }
        if (uac is not null && computed is null)
        {
            alerts.Add("État du compte non confirmé par le contrôleur");
            limits.Add("Sans l’état calculé par le contrôleur, un verrouillage ne peut être ni affirmé ni nié.");
        }
        var expiry = PasswordExpiry(user);
        if (expiry is DateTimeOffset expires)
        {
            var days = (int)Math.Ceiling((expires - now).TotalDays);
            if (days <= 0)
            {
                alerts.Add("Mot de passe expiré depuis le " + FicheValues.ShortDateTime(expires, zone));
                tone = "alert";
                limits.Add("Échéance calculée par le contrôleur" + C + "la stratégie du domaine n’est pas lue avec ce compte.");
            }
            else if (days <= 14)
            {
                alerts.Add("Mot de passe expire dans " + FrenchText.Integer(days) + " j");
                limits.Add("Échéance calculée par le contrôleur" + C + "la stratégie du domaine n’est pas lue avec ce compte.");
            }
        }
        var bad = user.Int64("badPwdCount") ?? 0;
        if (bad > 0)
        {
            alerts.Add(FrenchText.Count(bad, "mauvais mot de passe", "mauvais mots de passe"));
            limits.Add("Compteur d’échecs propre au contrôleur interrogé" + C + "il n’est pas répliqué.");
        }
        var recent = !locked && user.FileTime("lockoutTime") is DateTimeOffset last && last > now.AddDays(-7);
        if (recent)
        {
            alerts.Add("Verrouillé le " + FicheValues.ShortDateTime(user.FileTime("lockoutTime")!.Value, zone) + ", plus maintenant");
            limits.Add("Le contrôleur a levé ce verrouillage ; le journal 4740 dit quel poste l’a provoqué.");
        }
        if (alerts.Count == 0)
        {
            return null;
        }
        var hasSid = !string.IsNullOrEmpty(user.First("objectSid"));
        return new FicheBand(tone, [.. alerts], limits.Count == 0 ? null : string.Join(" ", limits), locked, (locked || recent || bad > 0) && hasSid);
    }

    /// <summary>Expiry computed by the controller (msDS-UserPasswordExpiryTimeComputed), null when absent, never or not applicable.</summary>
    public static DateTimeOffset? PasswordExpiry(FicheEntry user)
    {
        ArgumentNullException.ThrowIfNull(user);
        if (user.Int32("userAccountControl") is int uac && AdValues.HasFlag(uac, AdValues.DontExpirePassword))
        {
            return null;
        }
        if (user.Int64("pwdLastSet") == 0)
        {
            return null;
        }
        return user.FileTime("msDS-UserPasswordExpiryTimeComputed");
    }

    /// <summary>Support summary of a user (Get-DomeniaUserSupportSummary): dated facts by rubric, each with its source and limit.</summary>
    public static ImmutableArray<FicheFact> Support(FicheEntry user, string source, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(zone);
        var facts = new List<FicheFact>();
        void Add(string group, string label, string? value, string? limit = null)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                facts.Add(new FicheFact(group, label, value, "known", source, limit, null));
            }
        }
        Add("Identité", "Nom affiché", user.First("displayName") ?? user.Name);
        Add("Identité", "Identifiant", user.First("sAMAccountName"));
        Add("Identité", "Nom de connexion", user.First("userPrincipalName"));
        Add("Service", "Service", user.First("department"));
        Add("Service", "Fonction", user.First("title"));
        Add("Service", "Société", user.First("company"));
        Add("Service", "Bureau", user.First("physicalDeliveryOfficeName"));
        Add("Service", "Responsable", user.First("manager") is string manager ? FicheValues.DisplayName(manager) : null);
        Add("Contact", "Messagerie", user.First("mail"));
        Add("Contact", "Téléphone", user.First("telephoneNumber"));
        Add("Contact", "Mobile", user.First("mobile"));
        var computed = user.Int32("msDS-User-Account-Control-Computed");
        Add("Compte", "État du compte", FicheAttributeRules.UacStatusLabel(user.Int32("userAccountControl"), computed, user.Int64("lockoutTime")),
            computed is null ? "État calculé du contrôleur non lu" + C + "verrouillage et expiration non confirmés." : null);
        if (user.FileTime("accountExpires") is DateTimeOffset expires)
        {
            Add("Compte", "Expiration du compte", FicheValues.LocalDate(expires, zone) + (expires < now ? " (échu)" : ""));
        }
        if (user.Generalized("whenCreated") is DateTimeOffset created)
        {
            Add("Dates", "Créé le", FicheValues.LocalDate(created, zone));
        }
        if (user.FileTime("pwdLastSet") is DateTimeOffset pwd)
        {
            Add("Dates", "Mot de passe changé le", FicheValues.LocalDateTime(pwd, zone));
        }
        else if (user.Int64("pwdLastSet") == 0)
        {
            Add("Dates", "Mot de passe", "À changer à la prochaine ouverture de session");
        }
        if (user.FileTime("lastLogonTimestamp") is DateTimeOffset logon)
        {
            Add("Dates", "Dernière ouverture de session (approx.)", FicheValues.LocalDate(logon, zone), "Valeur répliquée avec un retard pouvant atteindre 14 jours.");
        }
        return [.. facts];
    }
}
