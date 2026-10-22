using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// One line of the call sheet (Domenia 1 New-DomeniaCallSheetFact): a value with its measure state, source and date. An empty
/// value is written as its state, never left blank.
/// </summary>
public sealed record FicheCallFact(
    string Section,
    string Label,
    string Value,
    string State,
    string StateLabel,
    string Source,
    DateTimeOffset? ObservedAt,
    string DateText,
    string Detail,
    bool Attention);

/// <summary>The account of the sheet.</summary>
public sealed record FicheCallSubject(string DisplayName, string Login, string? Upn, string Dn);

/// <summary>One usual workstation of the account, with its presence, console account and sessions (ConvertTo-DomeniaCallSheetComputerRows).</summary>
public sealed record FicheCallComputer(
    string Computer,
    string Dn,
    bool Primary,
    string Qualification,
    string AssociatedText,
    string Rule,
    string PresenceValue,
    string PresenceState,
    string PresenceStateLabel,
    string PresenceDate,
    string ConsoleValue,
    string ConsoleState,
    string ConsoleStateLabel,
    string SessionValue,
    string SessionState,
    string SessionStateLabel,
    string SessionDate,
    string Detail);

/// <summary>One direct group of the sheet, privileged ones first, with the change seen in this session.</summary>
public sealed record FicheCallGroup(string Name, string Dn, string Nature, string Change, bool Privileged, bool Removed);

/// <summary>One receipt of Domenia whose target is this account.</summary>
public sealed record FicheCallReceipt(string Id, string Date, string Operation, string Stage, bool Pending, string Explanation);

/// <summary>Which explicit reads of the sheet were done in this session (each has its own button).</summary>
public sealed record FicheCallReads(bool Lockouts, bool Policy, bool Presence, bool Sessions, bool Triage);

/// <summary>Result of fiche.callSheet and fiche.callSheet.read: the call sheet of one user (Domenia 1 lot R40).</summary>
public sealed record FicheCallSheet(
    FicheCallSubject Subject,
    string Origin,
    string OriginState,
    ImmutableArray<string> Attention,
    ImmutableArray<FicheCallFact> Account,
    ImmutableArray<FicheCallComputer> Computers,
    string ComputersText,
    ImmutableArray<FicheCallFact> GroupFacts,
    ImmutableArray<FicheCallGroup> Groups,
    FicheCallFact Operations,
    ImmutableArray<FicheCallReceipt> Receipts,
    string? TriageComputer,
    string? TriageComputerDn,
    ImmutableArray<FicheCallFact> Triage,
    string Ticket,
    bool TicketMasked,
    bool TicketTruncated,
    string TemplateSource,
    FicheCallReads Reads,
    DateTimeOffset BuiltAt,
    string? TemplateWarning = null);

/// <summary>Ticket template in force (Resolve-DomeniaCallSheetTemplate): its text, « Défaut » or « Configuration », and why a configured one was refused.</summary>
public sealed record FicheCallTemplate(string Text, string Source, string? Warning);

/// <summary>What the sheet is built from: everything already read plus the explicit reads of the session.</summary>
public sealed record FicheCallInput(
    FicheEntry User,
    string Origin,
    DateTimeOffset? ObservedAt,
    string? Server,
    FichePolicyView? Policy,
    DateTimeOffset? PolicyAt,
    string? PolicyServer,
    FicheLockoutDiagnosis? Lockouts,
    ImmutableArray<FicheAssociation> Associations,
    IReadOnlyDictionary<string, FicheObservation> Observations,
    IReadOnlyDictionary<string, FicheSessionsReading> Sessions,
    FicheGroupBaseline? Baseline,
    IReadOnlyDictionary<string, FicheSummary> Groups,
    IReadOnlyList<ReceiptRow>? Receipts,
    DateTimeOffset? ReceiptsAt,
    string? TriageComputerDn,
    FicheInventoryReading? Inventory,
    FicheObservation? TriageObservation,
    bool PresenceRead);

/// <summary>
/// Call sheet of a user account (Domenia 1 Domenia-CallSheet.Model.ps1, lot R40): what a technician needs during a phone call,
/// built from data already read and from the explicit reads started from the sheet. Every fact carries its source, its date and
/// a state of the measure vocabulary: an unknown value stays unknown, a stale one says so. Pure: « now » and the zone are inputs.
/// </summary>
public static partial class FicheCallSheets
{
    public const int FreshMinutes = 15;
    public const int InstantMinutes = 15;
    public const int TriageInstantMinutes = 60;
    public const int MaxTicketLength = 8000;

    private static readonly string C = FrenchText.Colon;

    /// <summary>Label of a measure state (Get-DomeniaMeasureStateLabel).</summary>
    public static string StateLabel(string state) => state switch
    {
        "known" => "Mesure valide",
        "absent" => "Jamais relevé",
        "notRead" => "Non lu",
        "refused" => "Refusé",
        "expired" => "Périmé",
        "incomplete" => "Incomplet",
        _ => "En erreur",
    };

    private static FicheCallFact Fact(string section, string label, string? value, string state, string source, DateTimeOffset? at, string? detail, bool attention, TimeZoneInfo zone)
    {
        var text = (value ?? "").Trim();
        if (text.Length == 0)
        {
            text = state == "known" ? "Non renseigné" : StateLabel(state);
        }
        return new FicheCallFact(section, label, text, state, StateLabel(state), source, at, at is DateTimeOffset d ? FicheValues.LocalDateTime(d, zone) : "", (detail ?? "").Trim(), attention);
    }

    /// <summary>How the fiche was obtained (Get-DomeniaCallSheetOrigin): live read, recent local base, or stale.</summary>
    public static (bool Live, string State, string Source, string Text) Origin(string origin, DateTimeOffset? observed, string? server, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var dateText = observed is DateTimeOffset at ? FicheValues.LocalDateTime(at, zone) : "";
        if (origin == "live")
        {
            var source = "Fiche lue dans l’annuaire" + (string.IsNullOrEmpty(server) ? "" : " (" + server + ")");
            return (true, "known", source, observed is null ? source + ", date de lecture non conservée." : source + " le " + dateText + ".");
        }
        var cacheSource = origin == "cache" ? "Fiche de la base locale" : "Fiche d’origine non confirmée";
        if (observed is not DateTimeOffset seen || seen > now.AddMinutes(5))
        {
            return (false, "expired", cacheSource, cacheSource + C + "date de lecture inconnue ou future, relisez la fiche depuis l’annuaire.");
        }
        if (origin == "cache" && (now - seen).TotalMinutes <= FreshMinutes)
        {
            return (false, "known", cacheSource, cacheSource + " du " + dateText + " ; la lecture de l’annuaire la remplace dès son arrivée.");
        }
        return (false, "expired", cacheSource, cacheSource + " du " + dateText + ", plus de " + FrenchText.Integer(FreshMinutes) + " min" + C + "relisez la fiche depuis l’annuaire.");
    }

    private static string DayName(int day) => (((day % 7) + 7) % 7) switch
    {
        0 => "dimanche",
        1 => "lundi",
        2 => "mardi",
        3 => "mercredi",
        4 => "jeudi",
        5 => "vendredi",
        _ => "samedi",
    };

    /// <summary>« UTC+02:00 ».</summary>
    public static string UtcOffset(int minutes)
    {
        var sign = minutes < 0 ? "-" : "+";
        var abs = Math.Abs(minutes);
        return "UTC" + sign + (abs / 60).ToString("00", CultureInfo.InvariantCulture) + ":" + (abs % 60).ToString("00", CultureInfo.InvariantCulture);
    }

    /// <summary>logonHours as 21 bytes from « FF-FF-… », plain hexadecimal or 21 numbers; null when unreadable.</summary>
    public static byte[]? ParseLogonHours(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }
        var text = Regex.Replace(value, "[\\s:-]", "");
        if (!Regex.IsMatch(text, "^[0-9A-Fa-f]{42}$"))
        {
            return null;
        }
        var bytes = new byte[21];
        for (var i = 0; i < 21; i++)
        {
            bytes[i] = byte.Parse(text.AsSpan(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        }
        return bytes;
    }

    /// <summary>
    /// Logon hours (Get-DomeniaLogonHoursView): one bit per hour of the week in UTC from Sunday, written in local time at the
    /// offset, consecutive days with the same slots grouped (« Du lundi au vendredi : 08:00–18:00 »). <paramref name="read"/>:
    /// whether the fiche could hold the attribute (absent from a directory read: no restriction).
    /// </summary>
    public static (string State, string Summary, bool Unrestricted, bool Never, bool? AllowedNow, string Offset) LogonHours(string? value, bool read, int offsetMinutes, DateTimeOffset now)
    {
        var offset = UtcOffset(offsetMinutes);
        if (string.IsNullOrWhiteSpace(value))
        {
            return read
                ? ("known", "Aucune restriction horaire", true, false, true, offset)
                : ("notRead", "Non lu" + C + "la fiche affichée ne contient pas les heures d’ouverture de session.", false, false, null, offset);
        }
        var bytes = ParseLogonHours(value);
        if (bytes is null)
        {
            return ("error", "Valeur de logonHours illisible" + C + "21 octets attendus.", false, false, null, offset);
        }
        var allowed = new List<int>();
        for (var hour = 0; hour < 168; hour++)
        {
            if ((bytes[hour / 8] & (1 << (hour % 8))) != 0)
            {
                allowed.Add(hour);
            }
        }
        var utcNow = now.UtcDateTime;
        bool? allowedNow = allowed.Contains(((int)utcNow.DayOfWeek * 24) + utcNow.Hour);
        if (allowed.Count == 168)
        {
            return ("known", "Toutes les heures sont autorisées", true, false, true, offset);
        }
        if (allowed.Count == 0)
        {
            return ("known", "Aucune heure autorisée" + C + "ouverture de session refusée à toute heure", false, true, false, offset);
        }
        var segments = new List<(int Start, int End)>();
        foreach (var hour in allowed)
        {
            var start = ((hour * 60 + offsetMinutes) % 10080 + 10080) % 10080;
            var end = start + 60;
            if (end <= 10080)
            {
                segments.Add((start, end));
            }
            else
            {
                segments.Add((start, 10080));
                segments.Add((0, end - 10080));
            }
        }
        segments.Sort((a, b) => a.Start.CompareTo(b.Start));
        static string Clock(int minute) => (minute / 60).ToString("00", CultureInfo.InvariantCulture) + ":" + (minute % 60).ToString("00", CultureInfo.InvariantCulture);
        var dayTexts = new string[7];
        for (var day = 0; day < 7; day++)
        {
            var from = day * 1440;
            var to = from + 1440;
            var parts = new List<(int Start, int End)>();
            foreach (var (segStart, segEnd) in segments)
            {
                var s = Math.Max(from, segStart);
                var e = Math.Min(to, segEnd);
                if (e <= s)
                {
                    continue;
                }
                if (parts.Count > 0 && parts[^1].End >= s)
                {
                    parts[^1] = (parts[^1].Start, Math.Max(parts[^1].End, e));
                }
                else
                {
                    parts.Add((s, e));
                }
            }
            dayTexts[day] = string.Join(", ", parts.Select(p => Clock(p.Start - from) + "–" + Clock(p.End - from)));
        }
        var groups = new List<(string Text, List<int> Days)>();
        foreach (var day in new[] { 1, 2, 3, 4, 5, 6, 0 })
        {
            var text = dayTexts[day];
            if (groups.Count > 0 && groups[^1].Text == text)
            {
                groups[^1].Days.Add(day);
            }
            else
            {
                groups.Add((text, [day]));
            }
        }
        var phrases = groups.Select(g =>
        {
            var names = g.Days.Select(DayName).ToList();
            var label = names.Count >= 3 ? "du " + names[0] + " au " + names[^1] : names.Count == 2 ? names[0] + " et " + names[1] : names[0];
            return label + C + (g.Text.Length == 0 ? "aucune heure" : g.Text);
        });
        var summary = string.Join(" ; ", phrases);
        summary = char.ToUpperInvariant(summary[0]) + summary[1..];
        return ("known", summary, false, false, allowedNow, offset);
    }

    private static string ShortName(string? name)
    {
        var text = (name ?? "").Trim().TrimEnd('$');
        var dot = text.IndexOf('.', StringComparison.Ordinal);
        if (dot > 0)
        {
            text = text[..dot];
        }
        return text.ToUpperInvariant();
    }

    /// <summary>
    /// Allowed workstations (Get-DomeniaUserWorkstationsView): absent from a directory read means every workstation; the associated
    /// workstations outside the list are named, the logon would be refused there.
    /// </summary>
    public static (string State, string Summary, bool Unrestricted, bool Attention, string Detail) Workstations(string? value, bool read, IReadOnlyCollection<string> linked)
    {
        ArgumentNullException.ThrowIfNull(linked);
        var names = (value ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (names.Count == 0)
        {
            return read
                ? ("known", "Tous les postes", true, false, "Attribut userWorkstations non renseigné" + C + "aucune limite de poste.")
                : ("notRead", "Non lu" + C + "la fiche affichée ne contient pas la liste des postes autorisés.", false, false, "");
        }
        var allowed = new HashSet<string>(names.Select(ShortName), StringComparer.OrdinalIgnoreCase);
        var associated = linked.Select(ShortName).Where(n => n.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var outside = associated.Where(n => !allowed.Contains(n)).ToList();
        var attention = false;
        var detail = "Liste lue dans userWorkstations.";
        if (associated.Count > 0)
        {
            if (outside.Count == associated.Count)
            {
                attention = true;
                detail = "Aucun poste associé à ce compte n’est dans cette liste" + C + "l’ouverture de session y sera refusée.";
            }
            else if (outside.Count > 0)
            {
                detail = "Postes associés hors de la liste, où l’ouverture de session sera refusée" + C + string.Join(", ", outside) + ".";
            }
        }
        return ("known", FrenchText.Count(names.Count, "poste autorisé", "postes autorisés") + C + string.Join(", ", names), false, attention, detail);
    }

    /// <summary>The account facts of the sheet, sections Compte and Restrictions (Get-DomeniaCallSheetAccountFacts).</summary>
    public static ImmutableArray<FicheCallFact> AccountFacts(FicheCallInput input, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(zone);
        var user = input.User;
        var origin = Origin(input.Origin, input.ObservedAt, input.Server, now, zone);
        var live = origin.Live;
        var baseState = origin.State;
        var source = origin.Source;
        var at = input.ObservedAt;
        var stale = baseState == "known" ? "" : " " + origin.Text;
        var facts = new List<FicheCallFact>();
        FicheCallFact Missing(string section, string label, string attribute) =>
            Fact(section, label, "Non lu", "notRead", source, at, attribute + " absent de la fiche affichée" + (live ? C + "le contrôleur ne l’a pas renvoyé (droit de lecture ?)." : C + "relisez la fiche depuis l’annuaire."), false, zone);
        FicheCallFact Known(string section, string label, string value, string detail = "", bool attention = false) =>
            Fact(section, label, value, baseState, source, at, (detail + stale).Trim(), attention, zone);

        var uac = user.Int32("userAccountControl");
        var computed = user.Int32("msDS-User-Account-Control-Computed");
        var state = AccountState.Evaluate(uac ?? 0, computed, user.Int64("lockoutTime"));
        if (uac is null)
        {
            facts.Add(Missing("Compte", "État du compte", "userAccountControl"));
        }
        else
        {
            facts.Add(state.Disabled ? Known("Compte", "État du compte", "Désactivé", "Lu dans userAccountControl.", true) : Known("Compte", "État du compte", "Activé", "Lu dans userAccountControl."));
        }

        var lockedAt = user.FileTime("lockoutTime");
        if (computed is null)
        {
            facts.Add(Fact("Compte", "Verrouillage", "Inconnu", "notRead", source, at, "État calculé du contrôleur (msDS-User-Account-Control-Computed) non lu" + C + "un lockoutTime non nul ne prouve pas un verrouillage actuel.", false, zone));
        }
        else if (state.Lock == LockState.Locked)
        {
            facts.Add(Known("Compte", "Verrouillage", "Verrouillé" + (lockedAt is DateTimeOffset l ? " depuis le " + FicheValues.LocalDateTime(l, zone) : ""), "État calculé par le contrôleur. Le journal 4740 dit quel poste a provoqué le verrouillage.", true));
        }
        else
        {
            var value = "Non verrouillé";
            if (lockedAt is DateTimeOffset l && l > now.AddDays(-7))
            {
                value += " (verrouillé le " + FicheValues.LocalDateTime(l, zone) + ", libéré depuis)";
            }
            facts.Add(Known("Compte", "Verrouillage", value, "État calculé par le contrôleur."));
        }

        var badText = user.First("badPwdCount");
        if (badText is null)
        {
            facts.Add(Missing("Compte", "Échecs de mot de passe", "badPwdCount"));
        }
        else if (!long.TryParse(badText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var badCount))
        {
            facts.Add(Fact("Compte", "Échecs de mot de passe", "Illisible", "error", source, at, "Valeur de badPwdCount non numérique.", false, zone));
        }
        else
        {
            var value = FrenchText.Integer(badCount);
            if (badCount > 0 && user.FileTime("badPasswordTime") is DateTimeOffset badAt)
            {
                value += " (dernier échec le " + FicheValues.LocalDateTime(badAt, zone) + ")";
            }
            facts.Add(Known("Compte", "Échecs de mot de passe", value, "Compteur propre au contrôleur interrogé" + C + "il n’est pas répliqué entre contrôleurs.", badCount > 0));
        }

        var pwdRaw = user.Int64("pwdLastSet");
        var mustChange = pwdRaw == 0;
        if (!user.Has("pwdLastSet"))
        {
            facts.Add(Missing("Compte", "Mot de passe changé", "pwdLastSet"));
        }
        else if (mustChange)
        {
            facts.Add(Known("Compte", "Mot de passe changé", "À changer à la prochaine ouverture de session", "pwdLastSet vaut 0.", true));
        }
        else if (user.FileTime("pwdLastSet") is DateTimeOffset pwd)
        {
            facts.Add(Known("Compte", "Mot de passe changé", "Le " + FicheValues.LocalDateTime(pwd, zone), "Lu dans pwdLastSet."));
        }
        else
        {
            facts.Add(Fact("Compte", "Mot de passe changé", "Illisible", "error", source, at, "Valeur de pwdLastSet illisible.", false, zone));
        }

        // Expiry of the password: the controller's value first, then the policy read from the sheet.
        var expSource = source;
        var expAt = at;
        var expBase = baseState;
        var expStale = stale;
        DateTimeOffset? expires;
        string expiryState;
        if (input.Policy is not null)
        {
            expires = input.Policy.Expires;
            expiryState = input.Policy.ExpiryState;
            expSource = "Stratégie de mot de passe lue" + (string.IsNullOrEmpty(input.PolicyServer) ? "" : " sur " + input.PolicyServer);
            expAt = input.PolicyAt;
            expBase = "known";
            expStale = "";
        }
        else
        {
            expires = FicheDiagnostics.PasswordExpiry(user);
            expiryState = expires is null ? "unknown" : "known";
        }
        var computedExpiry = user.Int64("msDS-UserPasswordExpiryTimeComputed");
        (string Value, string How, bool Attention)? expiry = null;
        if (uac is not null && state.PasswordNeverExpires)
        {
            expiry = ("N’expire jamais (option du compte)", "Option « Le mot de passe n’expire jamais » de userAccountControl.", false);
        }
        else if (mustChange)
        {
            expiry = ("À changer à la prochaine ouverture de session", "pwdLastSet vaut 0" + C + "le point est déjà signalé par « Mot de passe changé ».", false);
        }
        else if (expires is DateTimeOffset e)
        {
            var days = (e - now).TotalDays;
            var how = expiryState == "estimated"
                ? "Estimée à partir de la stratégie lue" + C + "valeur calculée par le contrôleur non disponible."
                : "Calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed).";
            expiry = days <= 0
                ? ("Expiré depuis le " + FicheValues.LocalDateTime(e, zone), how, true)
                : ("Expire le " + FicheValues.LocalDateTime(e, zone) + " (dans " + FrenchText.Integer((long)Math.Ceiling(days)) + " j)", how, days <= 7);
        }
        else if (computedExpiry == AdValues.Never)
        {
            expiry = ("N’expire pas", "Valeur calculée par le contrôleur" + C + "aucune échéance.", false);
        }
        if (expiry is { } x)
        {
            facts.Add(Fact("Compte", "Expiration du mot de passe", x.Value, expBase, expSource, expAt, (x.How + expStale).Trim(), x.Attention, zone));
        }
        else
        {
            var why = input.Policy is null
                ? "Échéance non calculée par le contrôleur" + C + "lisez la stratégie applicable (« Lire la stratégie de mot de passe »)."
                : input.Policy.Summary;
            facts.Add(Fact("Compte", "Expiration du mot de passe", "Inconnue", "notRead", expSource, expAt, why, false, zone));
        }

        var accountRaw = user.Int64("accountExpires");
        if (accountRaw is null)
        {
            facts.Add(live ? Known("Compte", "Expiration du compte", "N’expire jamais", "Attribut accountExpires non renseigné.") : Missing("Compte", "Expiration du compte", "accountExpires"));
        }
        else if (accountRaw is 0 or AdValues.Never)
        {
            facts.Add(Known("Compte", "Expiration du compte", "N’expire jamais", "accountExpires sans échéance."));
        }
        else if (user.FileTime("accountExpires") is DateTimeOffset accountAt)
        {
            facts.Add(accountAt <= now
                ? Known("Compte", "Expiration du compte", "Expiré depuis le " + FicheValues.LocalDateTime(accountAt, zone), "Un compte expiré ne peut plus ouvrir de session.", true)
                : Known("Compte", "Expiration du compte", "Expire le " + FicheValues.LocalDateTime(accountAt, zone), "Lu dans accountExpires.", (accountAt - now).TotalDays <= 7));
        }
        else
        {
            facts.Add(Fact("Compte", "Expiration du compte", "Illisible", "error", source, at, "Valeur de accountExpires illisible.", false, zone));
        }

        if (user.FileTime("lastLogonTimestamp") is DateTimeOffset logon)
        {
            facts.Add(Known("Compte", "Dernière ouverture de session", "Vers le " + FicheValues.LocalDate(logon, zone), "Valeur répliquée avec un retard pouvant atteindre 14 jours."));
        }
        else
        {
            facts.Add(live ? Known("Compte", "Dernière ouverture de session", "Aucune enregistrée", "lastLogonTimestamp non renseigné" + C + "aucune ouverture répliquée.") : Missing("Compte", "Dernière ouverture de session", "lastLogonTimestamp"));
        }

        if (input.Lockouts is not null)
        {
            facts.Add(LockoutFact(input.Lockouts, zone));
        }
        else
        {
            facts.Add(Fact("Compte", "Verrouillages des 7 derniers jours", "Non demandés", "notRead", "Journal Sécurité", null, "La lecture du journal 4740 se demande explicitement" + C + "« Lire les verrouillages (4740) ».", false, zone));
        }

        var offset = (int)zone.GetUtcOffset(now).TotalMinutes;
        var hours = LogonHours(user.First("logonHours"), live || user.Has("logonHours"), offset, now);
        if (hours.State != "known")
        {
            facts.Add(Fact("Restrictions", "Heures d’ouverture de session", hours.Summary, hours.State, source, at, "Attribut logonHours.", false, zone));
        }
        else
        {
            var value = hours.Summary;
            var outsideNow = hours.AllowedNow == false && !hours.Never;
            if (outsideNow)
            {
                value += " · en ce moment" + C + "hors des heures autorisées";
            }
            var detail = hours.Unrestricted
                ? user.Has("logonHours") ? "Les 168 heures de la semaine sont autorisées dans logonHours." : "Attribut logonHours non renseigné" + C + "toutes les heures."
                : "Heure locale de ce poste (" + hours.Offset + ") ; l’annuaire enregistre ces plages en UTC.";
            facts.Add(Known("Restrictions", "Heures d’ouverture de session", value, detail, hours.Never || outsideNow));
        }
        var linkedNames = input.Associations.Select(a => a.Name).ToList();
        var workstations = Workstations(user.First("userWorkstations"), live || user.Has("userWorkstations"), linkedNames);
        facts.Add(workstations.State != "known"
            ? Fact("Restrictions", "Postes autorisés", workstations.Summary, workstations.State, source, at, "Attribut userWorkstations.", false, zone)
            : Known("Restrictions", "Postes autorisés", workstations.Summary, workstations.Detail, workstations.Attention));
        if (uac is not null)
        {
            facts.Add(state.SmartCardRequired
                ? Known("Restrictions", "Carte à puce", "Exigée" + C + "le mot de passe ne permet pas d’ouvrir une session interactive", "Option SMARTCARD_REQUIRED de userAccountControl.", true)
                : Known("Restrictions", "Carte à puce", "Non exigée", "Lu dans userAccountControl."));
            facts.Add(state.PasswordNotRequired
                ? Known("Restrictions", "Mot de passe non requis", "Oui (PASSWD_NOTREQD)" + C + "à revoir", "Option de userAccountControl" + C + "un mot de passe vide peut être accepté.", true)
                : Known("Restrictions", "Mot de passe non requis", "Non", "Lu dans userAccountControl."));
        }
        else
        {
            facts.Add(Missing("Restrictions", "Carte à puce", "userAccountControl"));
            facts.Add(Missing("Restrictions", "Mot de passe non requis", "userAccountControl"));
        }
        return [.. facts];
    }

    /// <summary>The 4740 read as one fact (Get-DomeniaCallSheetLockoutFact): a refusal or an unreachable journal concludes nothing.</summary>
    public static FicheCallFact LockoutFact(FicheLockoutDiagnosis read, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(read);
        const string label = "Verrouillages des 7 derniers jours";
        var source = "Journal Sécurité de " + read.Controller;
        switch (read.State)
        {
            case "refused":
                return Fact("Compte", label, "Lecture refusée", "refused", source, read.ReadAt, "Un refus ne prouve pas l’absence de verrouillage" + C + "le compte doit pouvoir lire le journal Sécurité du contrôleur.", false, zone);
            case "unavailable":
                return Fact("Compte", label, "Journal injoignable", "error", source, read.ReadAt, "Aucune conclusion sur les verrouillages passés.", false, zone);
        }
        if (read.Recurrence == 0)
        {
            return Fact("Compte", label, "Aucun dans la fenêtre lue", "known", source, read.ReadAt, "Absence dans la fenêtre lue seulement" + C + "un journal recyclé peut ne plus contenir les événements anciens.", false, zone);
        }
        var value = FrenchText.Count(read.Recurrence, "verrouillage", "verrouillages");
        if (read.Origins.Length > 0)
        {
            value += " · postes" + C + string.Join(", ", read.Origins);
        }
        return Fact("Compte", label, value, read.Truncated ? "incomplete" : "known", source, read.ReadAt,
            "Le poste indiqué est celui que le contrôleur a noté" + C + "une session, un lecteur réseau ou un service peut y garder un ancien mot de passe.", true, zone);
    }

    /// <summary>Sessions of this account on one workstation (Get-DomeniaCallSheetSessionSummary): a failed read says nothing.</summary>
    public static (string State, string Value, DateTimeOffset? At, int Mine) SessionSummary(FicheSessionsReading? reading, string login)
    {
        if (reading is null)
        {
            return ("notRead", "Non lues", null, 0);
        }
        if (reading.State == "failed")
        {
            var refused = reading.Error is not null && Regex.IsMatch(reading.Error, "(?i)acc[eè]s\\s+refus|access\\s+(is\\s+)?denied|refus[eé]");
            return (refused ? "refused" : "error", "Lecture non confirmée" + C + (reading.Error ?? "erreur inconnue"), reading.ReadAt, 0);
        }
        var name = login.Contains('\\', StringComparison.Ordinal) ? login[(login.LastIndexOf('\\') + 1)..] : login;
        var mine = reading.Rows.Where(r => string.Equals(r.User, name, StringComparison.OrdinalIgnoreCase)).ToList();
        var others = reading.Rows.Count(r => r.User.Length > 0 && !string.Equals(r.User, name, StringComparison.OrdinalIgnoreCase));
        var state = reading.Unread > 0 || reading.State == "incomplete" ? "incomplete" : "known";
        string value;
        if (mine.Count > 0)
        {
            value = "Session de ce compte" + C + string.Join(" ; ", mine.Select(r =>
                r.State + " (" + r.Protocol + ")" + (r.Opened is null ? "" : " ouverte à " + r.Opened) + (r.Idle is null ? "" : ", inactive " + r.Idle)));
        }
        else
        {
            value = "Aucune session de ce compte" + (others > 0 ? " ; " + FrenchText.Count(others, "autre session avec compte", "autres sessions avec compte") : "");
        }
        if (reading.Unread > 0)
        {
            value += " ; " + FrenchText.Count(reading.Unread, "session dont le compte n’a pas pu être lu", "sessions dont le compte n’a pas pu être lu");
        }
        return (state, value, reading.ReadAt, mine.Count);
    }

    /// <summary>The usual workstations of the account (ConvertTo-DomeniaCallSheetComputerRows): instant facts older than 15 min are stale.</summary>
    public static ImmutableArray<FicheCallComputer> Computers(FicheCallInput input, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(zone);
        var login = input.User.First("sAMAccountName") ?? "";
        var rows = new List<FicheCallComputer>();
        foreach (var link in input.Associations)
        {
            input.Observations.TryGetValue(link.Dn, out var observation);
            var qualification = link.EvidenceLabel + (link.Primary ? " · principal" : "");
            var (presenceState, presenceValue, presenceDate, presenceReason) = Instant(observation?.PresenceState ?? MeasureState.Absent, observation?.PresenceAt,
                observation?.Answered switch { true => "En ligne", false => "Sans réponse au ping", _ => "" }, now, zone);
            var current = (observation?.ConsoleUser ?? "").Trim();
            var currentName = current.Contains('\\', StringComparison.Ordinal) ? current[(current.LastIndexOf('\\') + 1)..] : current;
            var consoleText = current.Length > 0 && login.Length > 0 && string.Equals(currentName, login, StringComparison.OrdinalIgnoreCase) ? "Ce compte est en console"
                : current.Length > 0 ? "Autre compte en console" + C + current : "Aucun compte en console";
            var consoleMeasure = observation?.ConsoleAt is null ? MeasureState.NotRead : MeasureState.Known;
            var (consoleState, consoleValue, _, consoleReason) = Instant(consoleMeasure, observation?.ConsoleAt, consoleText, now, zone);
            input.Sessions.TryGetValue(link.Dn, out var sessions);
            var session = SessionSummary(sessions, login);
            var detail = link.Rule;
            if (presenceState != "known")
            {
                detail += " Présence" + C + presenceReason;
            }
            if (consoleState != "known")
            {
                detail += " Console" + C + consoleReason;
            }
            rows.Add(new FicheCallComputer(link.Name, link.Dn, link.Primary, qualification, link.When is DateTimeOffset w ? FicheValues.LocalDateTime(w, zone) : "", link.Rule,
                presenceValue, presenceState, StateLabel(presenceState), presenceDate, consoleValue, consoleState, StateLabel(consoleState),
                session.Value, session.State, StateLabel(session.State), session.At is DateTimeOffset s ? FicheValues.LocalDateTime(s, zone) : "", detail.Trim()));
        }
        return [.. rows];
    }

    private static (string State, string Value, string Date, string Reason) Instant(MeasureState measure, DateTimeOffset? at, string knownValue, DateTimeOffset now, TimeZoneInfo zone)
    {
        var state = measure switch
        {
            MeasureState.Known => "known",
            MeasureState.Absent => "absent",
            MeasureState.NotRead => "notRead",
            MeasureState.Refused => "refused",
            MeasureState.Expired => "expired",
            MeasureState.Incomplete => "incomplete",
            _ => "error",
        };
        var value = StateLabel(state);
        var reason = state switch
        {
            "absent" => "jamais relevée pour ce poste.",
            "notRead" => "non lue.",
            "refused" => "accès refusé.",
            _ => "mesure inutilisable.",
        };
        if (state == "known")
        {
            value = knownValue;
            if (at is DateTimeOffset taken && (now - taken).TotalMinutes > InstantMinutes)
            {
                state = "expired";
                reason = "mesure instantanée de plus de " + FrenchText.Integer(InstantMinutes) + " min.";
            }
        }
        return (state, value, at is DateTimeOffset d ? FicheValues.LocalDateTime(d, zone) : "", reason);
    }

    /// <summary>Direct groups, privileged ones named, and the changes seen in this session (Get-DomeniaCallSheetGroupSummary).</summary>
    public static (ImmutableArray<FicheCallFact> Facts, ImmutableArray<FicheCallGroup> Rows) GroupSummary(FicheCallInput input, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(zone);
        var user = input.User;
        var origin = Origin(input.Origin, input.ObservedAt, input.Server, now, zone);
        var source = origin.Source;
        var at = input.ObservedAt;
        var current = user.All("memberOf").Select(d => d.Trim()).Where(d => d.Length > 0).ToList();
        var state = origin.State;
        var detail = "Groupes directs seulement" + C + "les groupes imbriqués et les droits effectifs se lisent dans l’onglet Groupes.";
        if (!user.Has("memberOf") && !origin.Live)
        {
            state = "notRead";
            detail = "memberOf absent de la fiche affichée" + C + "relisez la fiche depuis l’annuaire.";
        }
        var rows = new List<FicheCallGroup>();
        var privileged = new List<string>();
        var baseline = input.Baseline;
        var baselineSet = baseline is null ? null : new HashSet<string>(baseline.Groups, StringComparer.OrdinalIgnoreCase);
        var since = baseline is null ? "" : FicheValues.LocalDateTime(baseline.At, zone);
        var added = 0;
        foreach (var dn in current)
        {
            input.Groups.TryGetValue(dn, out var known);
            var name = known?.Name ?? FicheValues.DisplayName(dn);
            var isPrivileged = FicheMemberships.IsPrivileged(name, known?.Sid, known?.AdminCount);
            if (isPrivileged)
            {
                privileged.Add(name);
            }
            var change = "";
            if (baselineSet is not null && !baselineSet.Contains(dn))
            {
                change = "Ajouté depuis " + since;
                added++;
            }
            rows.Add(new FicheCallGroup(name, dn, isPrivileged ? "Privilégié" : "Standard", change, isPrivileged, false));
        }
        var removed = 0;
        if (baseline is not null)
        {
            var currentSet = new HashSet<string>(current, StringComparer.OrdinalIgnoreCase);
            foreach (var dn in baseline.Groups.Where(d => !currentSet.Contains(d)))
            {
                removed++;
                rows.Add(new FicheCallGroup(FicheValues.DisplayName(dn), dn, "", "Retiré depuis " + since, false, true));
            }
        }
        var facts = new List<FicheCallFact>();
        var countText = FrenchText.Count(current.Count, "groupe direct", "groupes directs");
        if (privileged.Count > 0)
        {
            countText += ", dont " + FrenchText.Count(privileged.Count, "privilégié", "privilégiés") + C + string.Join(", ", privileged);
        }
        facts.Add(Fact("Groupes", "Groupes directs", countText, state, source, at, detail, false, zone));
        if (user.Int32("primaryGroupID") is int rid)
        {
            var primary = FicheMemberships.PrimaryGroup(rid, null, null)!;
            facts.Add(Fact("Groupes", "Groupe principal", primary.Label, origin.State, source, at, "primaryGroupID" + C + "ce groupe n’apparaît pas dans memberOf.", rid == 512, zone));
        }
        const string history = "Aucun historique local des appartenances" + " : les relevés de l’annuaire ne contiennent pas les groupes.";
        if (baseline is null)
        {
            facts.Add(Fact("Groupes", "Changements récents", "Première fiche de ce compte dans la session" + C + "rien à comparer", "notRead", "Fiches de cette session", null, history, false, zone));
        }
        else if (added == 0 && removed == 0)
        {
            facts.Add(Fact("Groupes", "Changements récents", "Aucun depuis " + since, state, "Fiches de cette session", at, history, false, zone));
        }
        else
        {
            facts.Add(Fact("Groupes", "Changements récents", FrenchText.Count(added, "ajout", "ajouts") + ", " + FrenchText.Count(removed, "retrait", "retraits") + " depuis " + since,
                state, "Fiches de cette session", at, history, true, zone));
        }
        var sorted = rows.OrderBy(r => r.Removed).ThenByDescending(r => r.Privileged).ThenBy(r => r.Name, StringComparer.Ordinal).ToImmutableArray();
        return ([.. facts], sorted);
    }

    /// <summary>Receipts of Domenia whose target is this account (ConvertTo-DomeniaCallSheetReceiptSummary), newest first, 10 at most.</summary>
    public static (FicheCallFact Fact, ImmutableArray<FicheCallReceipt> Rows) Receipts(FicheEntry user, IReadOnlyList<ReceiptRow>? receipts, DateTimeOffset? readAt, TimeZoneInfo zone, int limit = 10)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(zone);
        const string source = "Reçus durables de Domenia";
        if (receipts is null)
        {
            return (Fact("Opérations", "Opérations Domenia", "Reçus non lus", "notRead", source, null, "Les reçus se relisent depuis le disque local.", false, zone), []);
        }
        var guid = user.ObjectGuid.ToString("D");
        var mine = receipts.Where(r => string.Equals(r.Target.ObjectGuid, guid, StringComparison.OrdinalIgnoreCase) || FicheValues.SameDn(r.Target.Dn, user.Dn))
            .OrderByDescending(r => r.At).ToList();
        var pending = mine.Count(r => r.Pending);
        var rows = mine.Take(Math.Max(1, limit)).Select(r => new FicheCallReceipt(r.Id, FicheValues.LocalDateTime(r.At, zone), r.Label, r.ResultLabel + " · " + r.VerificationLabel, r.Pending, r.Summary)).ToImmutableArray();
        var value = mine.Count == 0 ? "Aucun reçu sur ce compte" : FrenchText.Count(mine.Count, "reçu", "reçus") + " sur ce compte" + (pending > 0 ? ", dont " + FrenchText.Integer(pending) + " à vérifier" : "");
        var detail = "Opérations dont la cible est ce compte ; une opération sur un groupe porte le nom du groupe.";
        if (mine.Count > rows.Length)
        {
            detail += " Les " + FrenchText.Integer(rows.Length) + " plus récentes sont listées.";
        }
        return (Fact("Opérations", "Opérations Domenia", value, "known", source, readAt, detail, pending > 0, zone), rows);
    }

    /// <summary>
    /// Quick triage of a slow workstation from its last quick inventory (Get-DomeniaCallSheetTriageFacts): processor, memory,
    /// disks, processes, start and pending restart, each dated; instant values older than 60 min are stale.
    /// </summary>
    public static ImmutableArray<FicheCallFact> Triage(string? computer, FicheInventoryReading? inventory, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        string[] labels = ["Processeur", "Mémoire", "Disque système", "Autres volumes", "Processus les plus actifs", "Démarrage", "Redémarrage en attente"];
        var source = "Inventaire rapide" + (string.IsNullOrEmpty(computer) ? "" : " de " + computer);
        var facts = new List<FicheCallFact>();
        if (inventory is null)
        {
            facts.AddRange(labels.Select(l => Fact("Poste", l, "Aucun inventaire enregistré", "absent", source, null, "« Trier la lenteur du poste » lance l’inventaire rapide de ce poste.", false, zone)));
            return [.. facts];
        }
        if (inventory.State == "failed")
        {
            facts.AddRange(labels.Select(l => Fact("Poste", l, "Inventaire non confirmé", "error", source, inventory.ReadAt, inventory.Error ?? "Aucune lecture réussie enregistrée pour ce poste.", false, zone)));
            return [.. facts];
        }
        var observed = inventory.ReadAt;
        var age = (now - observed).TotalMinutes;
        var instantState = age > TriageInstantMinutes ? "expired" : "known";
        var durableState = age > 30 * 1440 ? "expired" : "known";
        var staleInstant = instantState == "known" ? "" : " Mesure instantanée de plus de " + FrenchText.Integer(TriageInstantMinutes) + " min" + C + "relancez le tri pour l’état actuel.";
        const int diskAlert = 10, diskWarn = 20, memoryWarn = 90, uptimeDays = 30;
        static string Size(double bytes) =>
            bytes >= 1099511627776d ? FrenchText.Decimal(bytes / 1099511627776d, 1) + " To"
            : bytes >= 1073741824d ? FrenchText.Decimal(bytes / 1073741824d, 1) + " Go"
            : FrenchText.Integer((long)Math.Round(bytes / 1048576d)) + " Mo";
        FicheCallFact NotMeasured(string label, string what) => Fact("Poste", label, "Non mesuré", "notRead", source, observed, what + " absent de cet inventaire.", false, zone);

        facts.Add(inventory.CpuLoad is double cpu && cpu >= 0
            ? Fact("Poste", "Processeur", FrenchText.Integer((long)Math.Round(cpu)) + " % de charge", instantState, source, observed, "Charge au moment de l’inventaire." + staleInstant, instantState == "known" && cpu >= 90, zone)
            : NotMeasured("Processeur", "La charge du processeur est"));
        if (inventory.MemoryTotal is long total && total > 0 && inventory.MemoryFree is long free)
        {
            var used = Math.Max(0, total - free);
            var percent = 100d * used / total;
            facts.Add(Fact("Poste", "Mémoire", FrenchText.Integer((long)Math.Round(percent)) + " % utilisés (" + Size(used) + " sur " + Size(total) + ")", instantState, source, observed,
                "Seuil de surveillance" + C + FrenchText.Integer(memoryWarn) + " %." + staleInstant, instantState == "known" && percent > memoryWarn, zone));
        }
        else
        {
            facts.Add(NotMeasured("Mémoire", "La mémoire libre est"));
        }
        var disks = inventory.Disks.Where(d => d.Size > 0).ToList();
        var system = disks.FirstOrDefault(d => string.Equals(d.Name, "C:", StringComparison.OrdinalIgnoreCase)) ?? disks.FirstOrDefault();
        if (system is not null)
        {
            var freePercent = 100d * system.Free / system.Size;
            var text = system.Name + C + FrenchText.Integer((long)Math.Round(freePercent)) + " % libres (" + Size(system.Free) + " sur " + Size(system.Size) + ")" + (freePercent < diskAlert ? ", presque plein" : "");
            facts.Add(Fact("Poste", "Disque système", text, durableState, source, observed, "Seuils" + C + "critique sous " + FrenchText.Integer(diskAlert) + " %, à surveiller sous " + FrenchText.Integer(diskWarn) + " %.", freePercent < diskWarn, zone));
            var others = disks.Where(d => !ReferenceEquals(d, system)).ToList();
            if (others.Count > 0)
            {
                var worst = others.OrderBy(d => (double)d.Free / d.Size).First();
                var worstPercent = 100d * worst.Free / worst.Size;
                facts.Add(Fact("Poste", "Autres volumes", FrenchText.Count(others.Count, "volume", "volumes") + ", le moins libre " + worst.Name + C + FrenchText.Integer((long)Math.Round(worstPercent)) + " % libres",
                    durableState, source, observed, "Volumes logiques locaux lus pendant l’inventaire.", worstPercent < diskAlert, zone));
            }
            else
            {
                facts.Add(Fact("Poste", "Autres volumes", "Aucun autre volume", durableState, source, observed, "Seul le disque système est monté, selon l’inventaire.", false, zone));
            }
        }
        else
        {
            facts.Add(NotMeasured("Disque système", "L’espace des disques est"));
            facts.Add(NotMeasured("Autres volumes", "L’espace des disques est"));
        }
        if (inventory.Processes.Length > 0)
        {
            var top = inventory.Processes.GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
                .Select(g => (Name: g.Key, Cpu: g.Sum(p => p.CpuPercent)))
                .OrderByDescending(p => p.Cpu).ThenBy(p => p.Name, StringComparer.Ordinal).Take(5)
                .Select(p => p.Name + " " + FrenchText.Decimal(p.Cpu, 1) + " %");
            var interval = inventory.SampleSeconds is double seconds ? " sur " + FrenchText.Decimal(seconds, 1) + " s" : "";
            facts.Add(Fact("Poste", "Processus les plus actifs", string.Join(" · ", top), instantState, source, observed,
                "Part du processeur" + interval + ", total mesuré " + FrenchText.Decimal(inventory.Processes.Sum(p => p.CpuPercent), 1) + " %." + staleInstant, false, zone));
        }
        else
        {
            facts.Add(NotMeasured("Processus les plus actifs", "La liste des processus est"));
        }
        if (inventory.LastBoot is DateTimeOffset boot)
        {
            var upDays = (int)Math.Floor((observed - boot).TotalDays);
            var longRun = upDays > uptimeDays;
            facts.Add(Fact("Poste", "Démarrage", "Démarré le " + FicheValues.LocalDateTime(boot, zone) + " (depuis " + FrenchText.Count(upDays, "jour", "jours") + " au moment de l’inventaire)", durableState, source, observed,
                longRun ? "Plus de " + FrenchText.Integer(uptimeDays) + " jours sans redémarrage" + C + "un redémarrage est conseillé." : "Seuil de redémarrage ancien" + C + FrenchText.Integer(uptimeDays) + " jours.", longRun, zone));
        }
        else
        {
            facts.Add(NotMeasured("Démarrage", "Le dernier démarrage est"));
        }
        facts.Add(inventory.PendingReboot switch
        {
            "required" => Fact("Poste", "Redémarrage en attente", "Oui" + C + string.Join(", ", inventory.RebootReasons), durableState, source, observed, "Indices confirmés dans le registre du poste.", true, zone),
            "partial" => Fact("Poste", "Redémarrage en attente", "Indices partiels" + C + string.Join(", ", inventory.RebootReasons), durableState, source, observed, "Certains indices seulement ont pu être lus.", false, zone),
            "none" => Fact("Poste", "Redémarrage en attente", "Non", durableState, source, observed, "Aucun indice de redémarrage en attente.", false, zone),
            _ => NotMeasured("Redémarrage en attente", "L’état de redémarrage est"),
        });
        return [.. facts];
    }

    /// <summary>Default text of « Copier pour le ticket » (Get-DomeniaCallSheetDefaultTemplate).</summary>
    public static string DefaultTemplate { get; } = string.Join("\n",
        "Fiche d’appel Domenia du {Date}",
        "Compte" + C + "{NomAffiche} ({Identifiant}, {UPN})",
        "À noter" + C + "{PointsAttention}",
        "",
        "Compte",
        "{Compte}",
        "",
        "Restrictions d’ouverture de session",
        "{Restrictions}",
        "",
        "Postes et sessions",
        "{Postes}",
        "",
        "Groupes",
        "{Groupes}",
        "",
        "Opérations Domenia sur ce compte",
        "{Operations}",
        "",
        "Poste lent" + C + "tri rapide",
        "{Triage}",
        "",
        "Faits relevés par Domenia, chacun avec sa source et sa date ; une valeur inconnue reste inconnue.");

    /// <summary>
    /// One plain-text line of a fact; a state other than known is written between brackets (ConvertTo-DomeniaCallSheetFactLine).
    /// The value is masked by the secret rule of the journal; the label is Domenia’s own text and is never masked (« Échecs de
    /// mot de passe : 5 » stays readable, unlike Domenia 1 which masked the whole text).
    /// </summary>
    public static string FactLine(FicheCallFact fact)
    {
        ArgumentNullException.ThrowIfNull(fact);
        var line = "- " + fact.Label + C + SecretMask.Protect(fact.Value);
        if (fact.State != "known")
        {
            line += " [" + fact.StateLabel + "]";
        }
        var origin = new[] { fact.Source, fact.DateText }.Where(s => !string.IsNullOrEmpty(s)).ToList();
        if (origin.Count > 0)
        {
            line += " (" + string.Join(", ", origin) + ")";
        }
        return line;
    }

    /// <summary>The facts that explain a call at first glance (Get-DomeniaCallSheetAttention).</summary>
    public static ImmutableArray<string> Attention(IEnumerable<FicheCallFact> facts) =>
        [.. facts.Where(f => f.Attention).Select(f => f.Label + C + SecretMask.Protect(f.Value))];

    /// <summary>True when a value of the sheet holds something that looks like a secret (it is masked in the ticket).</summary>
    private static bool Masks(string? value) => !string.IsNullOrEmpty(value) && !string.Equals(SecretMask.Protect(value), value, StringComparison.Ordinal);

    /// <summary>Placeholders a ticket template may use (Get-DomeniaCallSheetTemplatePlaceholders).</summary>
    public static ImmutableArray<string> Placeholders { get; } = ["Date", "NomAffiche", "Identifiant", "UPN", "PointsAttention", "Compte", "Restrictions", "Postes", "Groupes", "Operations", "Triage"];

    /// <summary>
    /// The template in force (Resolve-DomeniaCallSheetTemplate): CallSheet.TicketTemplate of Domenia.config.json when it is usable,
    /// else the default one with the reason. Refused: more than 4 000 characters, control characters other than line breaks and
    /// tabs, or no known placeholder at all (a fixed text would hide every fact). An empty or blank text keeps the default silently.
    /// </summary>
    public static FicheCallTemplate ResolveTemplate(string? configured)
    {
        if (configured is null)
        {
            return new FicheCallTemplate(DefaultTemplate, "Défaut", null);
        }
        var text = configured.Replace("\r\n", "\n", StringComparison.Ordinal);
        if (string.IsNullOrWhiteSpace(text))
        {
            return new FicheCallTemplate(DefaultTemplate, "Défaut", null);
        }
        string? reason = null;
        if (text.Length > 4000)
        {
            reason = "modèle de plus de " + FrenchText.Integer(4000) + " caractères";
        }
        else if (text.Any(ch => ch < 0x20 && ch is not ('\n' or '\t' or '\r')))
        {
            reason = "caractères de contrôle dans le modèle";
        }
        else if (!Placeholder().Matches(text).Any(m => Placeholders.Contains(m.Groups[1].Value, StringComparer.Ordinal)))
        {
            reason = "aucun champ connu entre accolades";
        }
        return reason is null
            ? new FicheCallTemplate(text, "Configuration", null)
            : new FicheCallTemplate(DefaultTemplate, "Défaut", "Modèle CallSheet.TicketTemplate ignoré (" + reason + ")" + C + "modèle par défaut.");
    }

    /// <summary>Builds the whole sheet and its ticket text (Get-DomeniaCallSheetTicketValues, ConvertTo-DomeniaCallSheetTicket).</summary>
    public static FicheCallSheet Build(FicheCallInput input, DateTimeOffset now, TimeZoneInfo zone, FicheCallTemplate? template = null)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(zone);
        var user = input.User;
        var subject = new FicheCallSubject(user.First("displayName") ?? user.Name, user.First("sAMAccountName") ?? "", user.First("userPrincipalName"), user.Dn);
        var origin = Origin(input.Origin, input.ObservedAt, input.Server, now, zone);
        var account = AccountFacts(input, now, zone);
        var computers = Computers(input, now, zone);
        var (groupFacts, groupRows) = GroupSummary(input, now, zone);
        var (operations, receiptRows) = Receipts(user, input.Receipts, input.ReceiptsAt, zone);
        var triageComputer = input.Associations.FirstOrDefault(a => FicheValues.SameDn(a.Dn, input.TriageComputerDn)) ?? input.Associations.FirstOrDefault();
        var triage = triageComputer is null ? ImmutableArray<FicheCallFact>.Empty : Triage(triageComputer.Name, input.Inventory, now, zone);
        var attention = Attention(account.Concat(groupFacts).Append(operations).Concat(triage));
        var computersText = computers.Length == 0
            ? "Aucun poste associé à ce compte dans Domenia" + C + "la présence et le tri ne sont pas disponibles."
            : FrenchText.Count(computers.Length, "poste associé", "postes associés") + ". Le premier est la relation déclarée, sinon la plus récente.";
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["Date"] = FicheValues.LocalDateTime(now, zone),
            ["NomAffiche"] = subject.DisplayName,
            ["Identifiant"] = subject.Login,
            ["UPN"] = subject.Upn ?? "",
            ["PointsAttention"] = attention.Length == 0 ? "rien de particulier relevé" : string.Join(" · ", attention),
            ["Compte"] = Lines(account.Where(f => f.Section == "Compte")),
            ["Restrictions"] = Lines(account.Where(f => f.Section == "Restrictions")),
            ["Postes"] = computers.Length == 0 ? "- Aucun poste associé à ce compte." : string.Join("\n", computers.Select(ComputerLine)),
            ["Groupes"] = Lines(groupFacts) + (groupRows.Any(r => r.Change.Length > 0) ? "\n" + string.Join("\n", groupRows.Where(r => r.Change.Length > 0).Select(r => "  " + r.Name + C + r.Change)) : ""),
            ["Operations"] = Lines([operations]) + (receiptRows.Length > 0 ? "\n" + string.Join("\n", receiptRows.Take(5).Select(r => "  " + r.Date + " · " + r.Operation + " · " + r.Stage)) : ""),
            ["Triage"] = triageComputer is null ? "- Aucun poste associé" + C + "tri non disponible." : "Poste " + triageComputer.Name + "\n" + Lines(triage),
        };
        var resolved = template ?? ResolveTemplate(null);
        var (ticket, truncated) = Ticket(resolved.Text, values);
        var masked = account.Concat(groupFacts).Append(operations).Concat(triage).Any(f => Masks(f.Value))
            || computers.Any(c => Masks(c.SessionValue) || Masks(c.ConsoleValue) || Masks(c.PresenceValue));
        var reads = new FicheCallReads(input.Lockouts is not null, input.Policy is not null, input.PresenceRead, input.Sessions.Count > 0, input.Inventory is not null);
        return new FicheCallSheet(subject, origin.Text, origin.State, attention, account, computers, computersText, groupFacts, groupRows, operations, receiptRows,
            triageComputer?.Name, triageComputer?.Dn, triage, ticket, masked, truncated, resolved.Source, reads, now, resolved.Warning);
    }

    private static string Lines(IEnumerable<FicheCallFact> facts)
    {
        var lines = facts.Select(FactLine).ToList();
        return lines.Count == 0 ? "- Aucun fait relevé." : string.Join("\n", lines);
    }

    private static string ComputerLine(FicheCallComputer row)
    {
        var text = "- " + row.Computer + " (" + row.Qualification + (row.AssociatedText.Length > 0 ? ", associé le " + row.AssociatedText : "") + ")" + C + "présence " + row.PresenceValue;
        if (row.PresenceState != "known")
        {
            text += " [" + row.PresenceStateLabel + "]";
        }
        if (row.PresenceDate.Length > 0)
        {
            text += " (" + row.PresenceDate + ")";
        }
        text += " ; console" + C + SecretMask.Protect(row.ConsoleValue);
        if (row.ConsoleState != "known")
        {
            text += " [" + row.ConsoleStateLabel + "]";
        }
        text += " ; sessions" + C + SecretMask.Protect(row.SessionValue);
        if (row.SessionDate.Length > 0)
        {
            text += " (" + row.SessionDate + ")";
        }
        return text;
    }

    [GeneratedRegex("\\{([A-Za-z]+)\\}", RegexOptions.CultureInvariant)]
    private static partial Regex Placeholder();

    /// <summary>
    /// Template with its placeholders replaced, CRLF line ends, bounded to 8 000 characters (ConvertTo-DomeniaCallSheetTicket).
    /// The values are masked one by one when they are built (<see cref="FactLine"/>); an unknown placeholder is left as written.
    /// </summary>
    public static (string Text, bool Truncated) Ticket(string template, IReadOnlyDictionary<string, string> values)
    {
        ArgumentNullException.ThrowIfNull(template);
        ArgumentNullException.ThrowIfNull(values);
        var replaced = Placeholder().Replace(template, m => values.TryGetValue(m.Groups[1].Value, out var v) ? v : m.Value);
        var protectedText = replaced.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').TrimEnd();
        var truncated = false;
        if (protectedText.Length > MaxTicketLength)
        {
            protectedText = protectedText[..MaxTicketLength] + "\n[…] Texte tronqué à " + FrenchText.Integer(MaxTicketLength) + " caractères.";
            truncated = true;
        }
        return (protectedText.Replace("\n", "\r\n", StringComparison.Ordinal), truncated);
    }
}

/// <summary>Masks what looks like a secret before a text leaves Domenia (Domenia 1 Protect-DomeniaSecretText).</summary>
public static partial class SecretMask
{
    [GeneratedRegex("(?<!\\d)(?:\\d{6}-){7}\\d{6}(?!\\d)", RegexOptions.CultureInvariant)]
    private static partial Regex BitLocker();

    [GeneratedRegex("\\b(Bearer|Basic)\\s+[A-Za-z0-9_.~+/=-]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Authorization();

    [GeneratedRegex("(\"(?:password|passwd|pwd|pass|p|motdepasse|secret|token|api[_-]?key|apikey|client[_-]?secret)\"\\s*:\\s*)(\"(?:\\\\.|[^\"\\\\])*\"|[^,}\\s]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex JsonMember();

    [GeneratedRegex("\\b(password|passwd|pwd|pass|motdepasse|mot\\s+de\\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)(\\s*[=:]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s;,]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex KeyValue();

    [GeneratedRegex("(^|\\s)([-/](?:p|rp|pass|password|pwd))(?:\\s+|[:=])(\"[^\"]*\"|'[^']*'|\\S+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Switch();

    public static string Protect(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var masked = BitLocker().Replace(text, "[clé de récupération masquée]");
        masked = Authorization().Replace(masked, "$1 ***");
        masked = JsonMember().Replace(masked, "$1\"***\"");
        masked = KeyValue().Replace(masked, "$1$2***");
        masked = Switch().Replace(masked, "$1$2 ***");
        return masked;
    }
}
