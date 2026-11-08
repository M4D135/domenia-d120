using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Lockout diagnosis of one account (Domenia 1 FIC-040, FIC-045: Get-DomeniaLockoutDiagnosis, Get-DomeniaLockoutTimeline):
/// the 4740 events of the security log of the PDC emulator for the SID of the account only, the computers at their origin,
/// and the refusals Domenia itself recorded just before each lockout. A refusal near a lockout is a lead to check, never a
/// proof; a refused or unavailable read never means « no lockout ». Pure.
/// </summary>
public static class AccountsLockouts
{
    /// <summary>Default window of the read (Domenia 1: 168 h, 1 to 720).</summary>
    public const int DefaultHours = 168;
    public const int MinHours = 1;
    public const int MaxHours = 720;

    /// <summary>Most events read (Domenia 1: 200 by default, 500 at most).</summary>
    public const int MaxEvents = 200;

    /// <summary>A Domenia refusal at most this long before a lockout is « near » (Domenia 1: 120 s).</summary>
    public const int ToleranceSeconds = 120;

    /// <summary>Clock skew tolerated between this computer and the controller (a refusal may look 5 s after the event).</summary>
    public const int SkewSeconds = 5;

    /// <summary>The report of one read: events matched with the refusals, origins, facts and a summary.</summary>
    public static LockoutReport Report(
        DirectoryUser user,
        DomainInfo domain,
        LockoutEventsRead read,
        IEnumerable<DomeniaRefusal> refusals,
        IReadOnlyCollection<string> accountKeys,
        int hours,
        DateTimeOffset now,
        TimeZoneInfo zone,
        bool simulated)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(refusals);
        ArgumentNullException.ThrowIfNull(accountKeys);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var source = "Journal Sécurité de " + read.Server;
        var keys = new HashSet<string>(accountKeys.Where(k => !string.IsNullOrWhiteSpace(k)), StringComparer.OrdinalIgnoreCase);
        // A refusal whose account could not be attributed stays a lead, flagged as such.
        var own = refusals.Where(r => r.AccountKey is null || keys.Contains(r.AccountKey)).ToList();
        var events = read.Events.OrderByDescending(e => e.At).Select(e => new LockoutEvent(e.At, string.IsNullOrWhiteSpace(e.CallerComputer) ? "non renseigné" : e.CallerComputer, e.Controller, Match(e.At, own))).ToImmutableArray();
        var origins = events.GroupBy(e => e.CallerComputer, StringComparer.OrdinalIgnoreCase)
            .Select(g => new LockoutOrigin(g.First().CallerComputer, g.Count(), events.Length == 0 ? 0 : Math.Round(g.Count() * 100.0 / events.Length, 1)))
            .OrderByDescending(o => o.Count).ThenBy(o => o.Computer, StringComparer.OrdinalIgnoreCase)
            .ToImmutableArray();
        var verdict = AccountsRules.LockOf(user);
        var facts = ImmutableArray.CreateBuilder<AccountsFact>();
        var controller = "Contrôleur " + read.Server;
        facts.Add(verdict switch
        {
            AccountLock.Locked => new AccountsFact("État calculé par le contrôleur", "Verrouillé", Tone.Alert, controller, null, null),
            AccountLock.ToCheck => new AccountsFact("État calculé par le contrôleur", "Non lu", Tone.Warn, controller, "Sans cet état, un lockoutTime non nul ne prouve pas un verrouillage actuel.", null),
            _ => new AccountsFact("État calculé par le contrôleur", "Non verrouillé", Tone.Ok, controller, null, null),
        });
        if (AdValues.FromFileTime(user.LockoutTime) is DateTimeOffset last)
        {
            var text = WritePlans.LocalTime(last, zone);
            if (verdict == AccountLock.Expired)
            {
                text += " (durée de verrouillage écoulée)";
            }
            facts.Add(new AccountsFact("Dernier verrouillage", text, verdict == AccountLock.Locked ? Tone.Alert : Tone.Info, controller, "Date du dernier verrouillage enregistré, pas son état actuel.", null));
        }
        if (user.BadPasswordCount is int bad)
        {
            facts.Add(new AccountsFact("Échecs de mot de passe", FrenchText.Integer(bad), bad > 0 ? Tone.Warn : Tone.Ok, controller, "Compteur propre à ce contrôleur" + c + "il n’est pas répliqué.", null));
        }
        string summary;
        switch (read.State)
        {
            case LockoutReadState.Read when events.Length > 0:
                facts.Add(new AccountsFact("Verrouillages journalisés", FrenchText.Count(events.Length, "événement 4740", "événements 4740") + (read.Truncated ? " (lecture tronquée)" : ""), Tone.Warn, source,
                    "Fenêtre et volume bornés" + c + "un journal recyclé peut ne plus contenir les événements anciens.", null));
                facts.Add(new AccountsFact("Postes à l’origine", string.Join(", ", origins.Select(o => o.Computer + " (" + FrenchText.Integer(o.Count) + ")")), Tone.Info, source, null,
                    "Un poste récurrent suggère une session, un lecteur réseau ou un service qui utilise encore un ancien mot de passe."));
                var near = events.Count(e => e.Domenia.Near);
                facts.Add(near > 0
                    ? new AccountsFact("Refus de Domenia avant un verrouillage", FrenchText.Integer(near) + " sur " + FrenchText.Integer(events.Length), Tone.Warn, "Protection des comptes de Domenia",
                        "Rapprochement horaire à " + FrenchText.Integer(ToleranceSeconds) + " s, horloges du poste et du contrôleur non comparées.",
                        "Domenia a essuyé un refus d’authentification pour ce compte juste avant" + c + "vérifiez d’abord le mot de passe saisi dans Domenia.")
                    : new AccountsFact("Refus de Domenia avant un verrouillage", "Aucun", Tone.Ok, "Protection des comptes de Domenia", "Refus enregistrés pendant cette session de Domenia seulement.", null));
                var top = origins[0];
                summary = FrenchText.Count(events.Length, "verrouillage", "verrouillages") + " en " + HoursText(hours) + (top.Count > 1 || origins.Length == 1 ? ", surtout depuis " + top.Computer : ", depuis " + FrenchText.Count(origins.Length, "poste", "postes")) + ".";
                break;
            case LockoutReadState.Read:
                facts.Add(new AccountsFact("Verrouillages journalisés", "Aucun dans la fenêtre lue", Tone.Ok, source, "Absence dans la fenêtre lue seulement.", null));
                summary = "Aucun verrouillage journalisé en " + HoursText(hours) + ".";
                break;
            case LockoutReadState.Refused:
                facts.Add(new AccountsFact("Verrouillages journalisés", "Lecture refusée", Tone.Alert, source,
                    "Un refus de lecture ne signifie pas qu’aucun verrouillage n’a eu lieu (droit «\u00A0Lecteurs des journaux d’événements\u00A0» du contrôleur).", null));
                summary = "Lecture du journal refusée" + c + "aucune conclusion sur les verrouillages.";
                break;
            default:
                facts.Add(new AccountsFact("Verrouillages journalisés", "Journal injoignable", Tone.Warn, source, "Aucune conclusion sur les verrouillages passés.", null));
                summary = "Journal injoignable" + c + "aucune conclusion sur les verrouillages.";
                break;
        }
        var serverSource = read.PdcEmulator ? "pdc" : "bound";
        var serverLabel = read.PdcEmulator
            ? "Émulateur PDC " + read.Server + " (il reçoit tous les verrouillages du domaine)"
            : "Contrôleur lié " + read.Server + " (émulateur PDC non résolu" + c + "des verrouillages d’autres contrôleurs peuvent manquer)";
        return new LockoutReport(
            new LockoutAccount(user.DistinguishedName, AccountsRules.NameOf(user), user.SamAccountName, user.Sid),
            read.Server,
            serverSource,
            serverLabel,
            hours,
            now - TimeSpan.FromHours(hours),
            now,
            MaxEvents,
            read.Truncated,
            read.State,
            events,
            origins,
            facts.ToImmutable(),
            verdict,
            summary,
            simulated);
    }

    /// <summary>The nearest Domenia refusal before the event (5 s of skew tolerated, 120 s at most), or none.</summary>
    public static LockoutDomeniaMatch Match(DateTimeOffset at, IReadOnlyCollection<DomeniaRefusal> refusals)
    {
        ArgumentNullException.ThrowIfNull(refusals);
        DomeniaRefusal? best = null;
        var bestDelta = double.MaxValue;
        foreach (var refusal in refusals)
        {
            var delta = (at - refusal.At).TotalSeconds;
            if (delta >= -SkewSeconds && delta <= ToleranceSeconds && Math.Abs(delta) < Math.Abs(bestDelta))
            {
                best = refusal;
                bestDelta = delta;
            }
        }
        if (best is null)
        {
            return new LockoutDomeniaMatch(false, null, false, "aucun refus Domenia à " + FrenchText.Integer(ToleranceSeconds) + " s");
        }
        var seconds = (int)Math.Round(Math.Max(0, bestDelta));
        var ambiguous = best.AccountKey is null;
        return new LockoutDomeniaMatch(true, seconds, ambiguous, "refus Domenia " + FrenchText.Integer(seconds) + " s avant" + (ambiguous ? " (compte non attribué)" : ""));
    }

    /// <summary>Window as read: 1 to 720 hours; anything else falls back to the default (Domenia 1).</summary>
    public static int ClampHours(int hours) => hours is < MinHours or > MaxHours ? DefaultHours : hours;

    /// <summary>« 7 jours », « 24 h ».</summary>
    public static string HoursText(int hours) =>
        hours % 24 == 0 ? FrenchText.Count(hours / 24, "jour", "jours") : FrenchText.Integer(hours) + " h";
}
