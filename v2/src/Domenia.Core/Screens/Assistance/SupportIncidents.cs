using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>One track of a classified incident: the rule that matched, its clue, the check it proposes and the screen to open.</summary>
public sealed record IncidentHint(string Code, string Title, string Evidence, string Next, string Route, string RouteLabel);

/// <summary>
/// One warning or error of the session, classified by fixed rules (Domenia 1 New-DomeniaSupportIncident). <see cref="Detail"/>
/// is the cleaned local message, shown on this screen only and never written into a report or an export.
/// </summary>
public sealed record SupportIncident(
    string Id,
    DateTimeOffset At,
    string Level,
    string LevelLabel,
    Tone Tone,
    string Area,
    string Title,
    string Codes,
    ImmutableArray<IncidentHint> Hints,
    string Detail,
    string Source);

/// <summary>A raw message to classify: where it was seen, when, how severe (warn or alert) and its text.</summary>
public sealed record RawIncident(string Key, DateTimeOffset At, Tone Level, string Area, string Text, string Source);

/// <summary>
/// Explained incidents of the session (Domenia 1 Get-DomeniaSupportIncidentRules and the bounded list): fixed regular
/// expressions with a 100 ms limit on a text bounded to 8 192 characters, never a pattern from the operator; 200 incidents
/// at most; an identical adjacent message within 2 seconds is ignored; the filter is literal (title, codes, area).
/// </summary>
public static partial class SupportIncidents
{
    public const int Limit = 200;
    public const int MaxText = 8192;

    private sealed record Rule(string Code, Func<Regex> Pattern, string Title, string Evidence, string Next, string Route);

    private static readonly ImmutableArray<Rule> Rules =
    [
        new("SMB_SESSION_CONFLICT", SmbConflict, "Conflit de sessions SMB", "Code 1219 ou message de connexions multiples.",
            "Vérifiez les sessions SMB vers cette cible et le compte choisi. Ne déconnectez pas globalement les lecteurs de l’utilisateur.", "accounts"),
        new("CANCELLED", Cancelled, "Opération interrompue ou remplacée", "Le message mentionne une annulation ou un remplacement.",
            "Attendez la fin du nettoyage puis relancez une seule fois sur la cible. Une interruption ne signifie pas utilisateur absent.", "health"),
        new("AUTH_CONTEXT", AuthContext, "Authentification refusée dans ce contexte", "Le message contient un refus d’authentification.",
            "Vérifiez l’identité complète, le domaine, la cible et le compte effectif. Une connexion à l’annuaire réussie ne valide pas WMI ni SMB. Ne multipliez pas les essais.", "accounts"),
        new("ACCESS_DENIED", AccessDenied, "Accès refusé à la ressource", "Refus d’accès signalé par une méthode ou une ressource.",
            "Vérifiez le compte de la méthode concernée, les droits et la cible. Ne concluez pas à un mauvais mot de passe.", "accounts"),
        new("RPC_UNAVAILABLE", RpcUnavailable, "Transport RPC indisponible", "Code ou message RPC indisponible.",
            "Vérifiez la résolution, le chemin réseau, les services et le filtrage RPC. Un ping seul ne valide pas RPC.", "computer"),
        new("TIMEOUT", Expired, "Délai de lecture dépassé", "Le message signale une attente expirée.",
            "Identifiez la méthode et le temps écoulé. Une absence de réponse ne prouve ni un compte invalide ni l’absence de session.", "health"),
        new("DNS_NETWORK", DnsNetwork, "Nom ou chemin réseau non résolu", "Le message mentionne un nom ou un chemin introuvable.",
            "Vérifiez le nom complet et le chemin sur la cible concernée. Ne modifiez pas automatiquement le DNS ni le pare-feu.", "computer"),
        new("ENGINE_BUSY", EngineBusy, "Moteur occupé ou lectures en nettoyage", "Le moteur signale sa limite de lectures simultanées.",
            "Attendez la fin des lectures et consultez l’état du moteur. N’augmentez pas les limites pour masquer une lecture bloquée.", "health"),
        new("PSEXEC_LICENSE", PsExec, "Échec de lancement PsExec à examiner", "Licence PsExec ou code 1 mentionné.",
            "Vérifiez les arguments, la version exécutée et la sortie. Le code 1 seul ne permet pas d’attribuer la cause à la licence.", "computer"),
        new("READ_REFUSED", ReadRefused, "Lecture refusée par la cible", "Le message signale une lecture ou une sonde refusée.",
            "Vérifiez les droits du compte de la méthode sur la cible concernée. Un refus n’est pas une absence de données.", "health"),
    ];

    private static readonly IncidentHint Unclassified = new("UNCLASSIFIED", "Message non classé", "Aucune règle locale ne correspond.",
        "Consultez le détail et sa source. Aucune cause automatique n’est proposée.", "operations", "Voir le journal des opérations");

    public static string RouteLabel(string route) => route switch
    {
        "accounts" => "Ouvrir Comptes",
        "computer" => "Ouvrir Poste",
        _ => "Ouvrir Opérations",
    };

    /// <summary>Screen of the application a route of the rules opens.</summary>
    public static string RouteScreen(string route) => route switch
    {
        "accounts" => "comptes",
        "computer" => "poste",
        _ => "operations",
    };

    /// <summary>Every rule that matches the bounded text; « non classé » when none does.</summary>
    public static ImmutableArray<IncidentHint> Hints(string? text)
    {
        var bounded = text ?? "";
        if (bounded.Length > MaxText)
        {
            bounded = bounded[..MaxText];
        }
        var found = ImmutableArray.CreateBuilder<IncidentHint>();
        foreach (var rule in Rules)
        {
            bool matched;
            try
            {
                matched = rule.Pattern().IsMatch(bounded);
            }
            catch (RegexMatchTimeoutException)
            {
                // A rule that cannot decide within its limit does not match: no cause is guessed.
                matched = false;
            }
            if (matched)
            {
                found.Add(new IncidentHint(rule.Code, rule.Title, rule.Evidence, rule.Next, RouteScreen(rule.Route), RouteLabel(rule.Route)));
            }
        }
        if (found.Count == 0)
        {
            found.Add(Unclassified);
        }
        return found.ToImmutable();
    }

    public static SupportIncident Create(RawIncident raw, string id)
    {
        ArgumentNullException.ThrowIfNull(raw);
        var hints = Hints(raw.Text);
        var alert = raw.Level == Tone.Alert;
        return new SupportIncident(
            id,
            raw.At,
            alert ? "alert" : "warn",
            alert ? "Erreur" : "Avertissement",
            alert ? Tone.Alert : Tone.Warn,
            SupportText.Clean(raw.Area, 64),
            string.Join(" / ", hints.Select(h => h.Title)),
            string.Join(", ", hints.Select(h => h.Code)),
            hints,
            SupportText.Clean(raw.Text, 4096),
            raw.Source);
    }

    /// <summary>Identical adjacent message (same text, area and level) less than 2 seconds after the previous one.</summary>
    public static bool IsAdjacentDuplicate(SupportIncident? last, SupportIncident next)
    {
        ArgumentNullException.ThrowIfNull(next);
        return last is not null && string.Equals(last.Detail, next.Detail, StringComparison.Ordinal)
            && string.Equals(last.Area, next.Area, StringComparison.Ordinal) && string.Equals(last.Level, next.Level, StringComparison.Ordinal)
            && (next.At - last.At).Duration() < TimeSpan.FromSeconds(2);
    }

    /// <summary>Literal filter on the title, the codes and the area, without case (Domenia 1 Test-DomeniaSupportLiteralMatch).</summary>
    public static bool Matches(SupportIncident incident, string? query)
    {
        ArgumentNullException.ThrowIfNull(incident);
        if (string.IsNullOrWhiteSpace(query))
        {
            return true;
        }
        var text = incident.Title + " " + incident.Codes + " " + incident.Area;
        return text.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase);
    }

    private const RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

    [GeneratedRegex(@"(\b1219\b|multiple connections|connexions multiples)", Options, 100)]
    private static partial Regex SmbConflict();

    [GeneratedRegex(@"(annul|superseded|beginstop|cancel|d[eé]tach[eé]e du GUI)", Options, 100)]
    private static partial Regex Cancelled();

    [GeneratedRegex(@"(0x8007052e|\b1326\b|invalid credentials|identification fournies ne sont pas valides|identifiants? (non valides|invalides)|logon failure|[eé]chec.*ouverture de session)", Options, 100)]
    private static partial Regex AuthContext();

    [GeneratedRegex(@"(0x80070005|0x80041003|access.*denied|acc[eè]s.*refus|unauthorized)", Options, 100)]
    private static partial Regex AccessDenied();

    [GeneratedRegex(@"(0x800706ba|\b1722\b|rpc.*(unavailable|indisponible|n.est pas disponible))", Options, 100)]
    private static partial Regex RpcUnavailable();

    [GeneratedRegex(@"(timeout|timed out|d[eé]lai.*(d[eé]pass|expir))", Options, 100)]
    private static partial Regex Expired();

    [GeneratedRegex(@"(no such host|h[oô]te inconnu|name.*resolv|network path.*not found|chemin r[eé]seau.*introuvable|0x80070035)", Options, 100)]
    private static partial Regex DnsNetwork();

    [GeneratedRegex(@"(limite physique|workers.*annulation|ex[eé]cute d[eé]j[aà].*t[aâ]che)", Options, 100)]
    private static partial Regex EngineBusy();

    [GeneratedRegex(@"(SYSINTERNALS SOFTWARE LICENSE|PsExec.*code 1)", Options, 100)]
    private static partial Regex PsExec();

    [GeneratedRegex(@"(lecture\b.*\brefus|sondes? refus|refus[eé]es? pour)", Options, 100)]
    private static partial Regex ReadRefused();
}
