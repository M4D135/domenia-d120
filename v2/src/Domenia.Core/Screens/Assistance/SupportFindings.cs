using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Level of a finding (Domenia 1: Attention, A verifier, Non determine, Information).</summary>
public enum FindingLevel
{
    Attention,
    ToCheck,
    Undetermined,
    Information,
}

/// <summary>Nature of a finding (Domenia 1: Observation, Couverture, Limite).</summary>
public enum FindingBasis
{
    Observation,
    Coverage,
    Limit,
}

/// <summary>One finding of the local analysis: level, title, the clue that triggered it, the check proposed and its nature.</summary>
public sealed record SupportFinding(
    string Code,
    FindingLevel Level,
    string LevelLabel,
    Tone Tone,
    string Title,
    string Evidence,
    string Next,
    FindingBasis Basis,
    string BasisLabel);

/// <summary>
/// Facts about a workstation known to Domenia besides its capture (LAPS expiry date, last presence and inventory readings,
/// last logon). They feed the machine rules added by Domenia 2 and are never written into a capture or an export: no LAPS
/// password exists anywhere, only its expiry date.
/// </summary>
public sealed record MachineSignals(
    LapsKind Laps,
    DateTimeOffset? LapsExpiration,
    bool? LastPresenceAnswered,
    DateTimeOffset? LastPresenceAt,
    double? SystemDiskFreePercent,
    DateTimeOffset? LastBootAt,
    DateTimeOffset? LastLogonAt);

/// <summary>
/// Local analysis of one capture (Domenia 1 Get-DomeniaSupportFindings): no directory access, a missing value stays
/// undetermined, nothing is repaired. Domenia 2 adds machine rules (LAPS absent or expired, no answer at the last presence
/// check, system disk nearly full, long uptime, inactive computer account) from <see cref="MachineSignals"/>.
/// </summary>
public static class SupportFindings
{
    public const int FreshMinutes = 15;
    public const int ExpiringDays = 7;

    public static string LevelLabel(FindingLevel level) => level switch
    {
        FindingLevel.Attention => "Attention",
        FindingLevel.ToCheck => "À vérifier",
        FindingLevel.Undetermined => "Non déterminé",
        _ => "Information",
    };

    public static Tone LevelTone(FindingLevel level) => level switch
    {
        FindingLevel.Attention => Tone.Alert,
        FindingLevel.ToCheck => Tone.Warn,
        FindingLevel.Undetermined => Tone.Off,
        _ => Tone.Info,
    };

    public static string BasisLabel(FindingBasis basis) => basis switch
    {
        FindingBasis.Coverage => "Couverture",
        FindingBasis.Limit => "Limite",
        _ => "Observation",
    };

    private static SupportFinding Finding(string code, FindingLevel level, string title, string evidence, string next, FindingBasis basis = FindingBasis.Observation) =>
        new(code, level, LevelLabel(level), LevelTone(level), title, evidence, next, basis, BasisLabel(basis));

    private static string Date(DateTimeOffset at, TimeZoneInfo zone) =>
        TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy' à 'HH':'mm", CultureInfo.InvariantCulture);

    public static ImmutableArray<SupportFinding> Analyse(SupportSnapshot snapshot, DateTimeOffset now, TimeZoneInfo zone, MachineSignals? signals = null)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var rows = ImmutableArray.CreateBuilder<SupportFinding>();
        if (snapshot.Source != SnapshotSource.Live)
        {
            var origin = snapshot.Source == SnapshotSource.Cache ? "cache local" : "inconnue";
            rows.Add(Finding("DATA_NOT_LIVE", FindingLevel.ToCheck, "Lecture fraîche de l’annuaire non établie",
                "Source" + c + origin + ". Âge réel des données de l’annuaire non établi.",
                "Relisez la fiche avant une décision. L’heure de capture ne rajeunit pas le cache.", FindingBasis.Coverage));
        }
        else if ((now - snapshot.ObservedAt).TotalMinutes > FreshMinutes)
        {
            rows.Add(Finding("DATA_OLD", FindingLevel.ToCheck, "Lecture de plus de 15 minutes",
                "Dernière lecture" + c + Date(snapshot.ObservedAt, zone) + ".",
                "Relisez pour confirmer les valeurs. Le seuil de 15 minutes est un repère local, pas une règle de l’annuaire.", FindingBasis.Coverage));
        }
        var uac = snapshot.Int64("userAccountControl");
        var computed = snapshot.Int64("msDS-User-Account-Control-Computed");
        var account = snapshot.Kind is "user" or "computer";
        if (account && uac is null)
        {
            rows.Add(Finding("UAC_UNKNOWN", FindingLevel.Undetermined, "État du compte non déterminé", "userAccountControl absent, partiel ou illisible.",
                "Relisez les propriétés de la fiche. Une absence de valeur ne signifie pas un compte actif.", FindingBasis.Coverage));
        }
        if (uac is long u && (u & AdValues.AccountDisabled) != 0)
        {
            rows.Add(Finding("ACCOUNT_DISABLED", FindingLevel.Attention, "Compte désactivé dans la lecture",
                "userAccountControl=" + u.ToString(CultureInfo.InvariantCulture) + FrenchText.Nbsp + "; bit ACCOUNTDISABLE présent.",
                "Confirmez le motif de la désactivation avant toute intervention. Aucune réactivation automatique."));
        }
        if (snapshot.Kind == "user")
        {
            AnalyseUser(snapshot, now, zone, uac, computed, rows);
        }
        if (snapshot.Kind == "computer")
        {
            if (string.IsNullOrWhiteSpace(snapshot.Text("dNSHostName")))
            {
                rows.Add(Finding("DNS_NOT_PROVIDED", FindingLevel.ToCheck, "Nom DNS complet non fourni", "dNSHostName absent ou vide dans la capture.",
                    "Vérifiez la fiche et la résolution DNS. Ceci ne prouve ni une panne DNS ni un poste hors ligne.", FindingBasis.Coverage));
            }
            if (signals is not null)
            {
                AnalyseMachine(signals, now, zone, rows);
            }
        }
        if (snapshot.Int64("adminCount") == 1)
        {
            rows.Add(Finding("ADMINCOUNT", FindingLevel.Information, "Marqueur de protection à examiner", "adminCount=1.",
                "N’en déduisez pas les droits actuels. Vérifiez les appartenances et les ACL effectives.", FindingBasis.Limit));
        }
        if (snapshot.Fields.Any(f => f.Coverage == FieldCoverage.Partial))
        {
            rows.Add(Finding("PARTIAL_CAPTURE", FindingLevel.ToCheck, "Capture partielle", "Au moins un attribut est borné, découpé (range) ou non pris en charge.",
                "Les comparaisons de ces attributs restent indéterminées.", FindingBasis.Coverage));
        }
        if (rows.Count == 0)
        {
            rows.Add(Finding("NO_FINDING", FindingLevel.Information, "Aucun signal dans les règles appliquées",
                "Analyse locale de " + FrenchText.Count(snapshot.FieldCount, "attribut fourni", "attributs fournis") + ".",
                "Ce résultat ne valide ni la santé du poste, ni les droits effectifs, ni une session distante.", FindingBasis.Limit));
        }
        return rows.ToImmutable();
    }

    private static void AnalyseUser(SupportSnapshot snapshot, DateTimeOffset now, TimeZoneInfo zone, long? uac, long? computed, ImmutableArray<SupportFinding>.Builder rows)
    {
        var c = FrenchText.Colon;
        if (computed is long flags)
        {
            if ((flags & AdValues.LockedOut) != 0)
            {
                rows.Add(Finding("ACCOUNT_LOCKED", FindingLevel.Attention, "Verrouillage indiqué par le contrôleur",
                    "msDS-User-Account-Control-Computed" + c + "bit LOCKOUT présent dans la lecture.",
                    "Confirmez par une relecture, puis cherchez l’origine des essais (recette « Connexion impossible »)."));
            }
            if ((flags & AdValues.PasswordExpired) != 0)
            {
                rows.Add(Finding("PASSWORD_EXPIRED", FindingLevel.Attention, "Expiration du mot de passe indiquée par le contrôleur",
                    "msDS-User-Account-Control-Computed" + c + "bit PASSWORD_EXPIRED présent.",
                    "Vérifiez avec l’utilisateur les modalités de changement du mot de passe."));
            }
        }
        else if (snapshot.Int64("lockoutTime") is long lockout && lockout > 0)
        {
            rows.Add(Finding("LOCKOUT_HISTORY", FindingLevel.ToCheck, "Trace de verrouillage, état actuel non confirmé",
                "lockoutTime=" + lockout.ToString(CultureInfo.InvariantCulture) + FrenchText.Nbsp + "; attribut calculé non fourni.",
                "Cette trace seule ne prouve pas un verrouillage actuel. Vérifiez la durée de verrouillage et l’état calculé par le contrôleur.", FindingBasis.Limit));
        }
        if (snapshot.Int64("pwdLastSet") == 0)
        {
            if (uac is long u && (u & AdValues.DontExpirePassword) == 0)
            {
                rows.Add(Finding("PASSWORD_CHANGE_REQUIRED", FindingLevel.Attention, "Changement du mot de passe demandé", "pwdLastSet=0 et DONT_EXPIRE_PASSWORD absent.",
                    "Prévoyez un parcours qui permet le changement à la prochaine ouverture de session. Ne concluez pas à un mauvais mot de passe."));
            }
            else
            {
                rows.Add(Finding("PASSWORD_STATE_REVIEW", FindingLevel.ToCheck, "pwdLastSet à zéro" + c + "options à vérifier",
                    "pwdLastSet=0" + FrenchText.Nbsp + "; options du compte absentes ou DONT_EXPIRE_PASSWORD présent.",
                    "Vérifiez ensemble les options et la stratégie du compte avant de conclure.", FindingBasis.Limit));
            }
        }
        if (uac is long options && (options & AdValues.DontExpirePassword) != 0)
        {
            rows.Add(Finding("PASSWORD_NO_EXPIRY", FindingLevel.Information, "Option de non-expiration du mot de passe", "Bit DONT_EXPIRE_PASSWORD présent.",
                "Vérifiez que cette option correspond à la stratégie et à la fonction du compte."));
        }
        if (snapshot.Int64("accountExpires") is long expires && expires > 0 && expires != AdValues.Never)
        {
            if (AdValues.FromFileTime(expires) is not DateTimeOffset date)
            {
                rows.Add(Finding("EXPIRY_INVALID", FindingLevel.Undetermined, "Date d’expiration illisible", "accountExpires hors de la plage de dates exploitable.",
                    "Relisez la valeur brute avant de conclure.", FindingBasis.Coverage));
            }
            else if (date <= now)
            {
                rows.Add(Finding("ACCOUNT_EXPIRED", FindingLevel.Attention, "Date d’expiration du compte dépassée", "accountExpires" + c + Date(date, zone) + ".",
                    "Confirmez le besoin et les autorisations avant de prolonger le compte."));
            }
            else if ((date - now).TotalDays <= ExpiringDays)
            {
                rows.Add(Finding("ACCOUNT_EXPIRING", FindingLevel.ToCheck, "Compte expirant dans moins de 7 jours", "accountExpires" + c + Date(date, zone) + ".",
                    "Anticipez avec le responsable. Le seuil de 7 jours est un repère local."));
            }
        }
    }

    private static void AnalyseMachine(MachineSignals signals, DateTimeOffset now, TimeZoneInfo zone, ImmutableArray<SupportFinding>.Builder rows)
    {
        var c = FrenchText.Colon;
        if (signals.Laps == LapsKind.None)
        {
            rows.Add(Finding("LAPS_ABSENT", FindingLevel.ToCheck, "Aucun mot de passe LAPS géré pour ce poste",
                "Aucune date d’expiration LAPS dans l’annuaire (ni LAPS Windows, ni LAPS hérité).",
                "Vérifiez le déploiement de LAPS sur ce poste. Domenia ne lit jamais le mot de passe."));
        }
        else if (signals.LapsExpiration is DateTimeOffset lapsExpiry && lapsExpiry <= now)
        {
            rows.Add(Finding("LAPS_EXPIRED", FindingLevel.Attention, "Mot de passe LAPS expiré",
                "Date d’expiration LAPS dépassée (relevée dans l’annuaire, sans le mot de passe).",
                "Le poste n’a pas renouvelé son mot de passe" + c + "vérifiez qu’il joint le contrôleur et que la stratégie LAPS s’applique."));
        }
        if (signals.LastPresenceAnswered == false && signals.LastPresenceAt is DateTimeOffset checkedAt)
        {
            rows.Add(Finding("NO_ANSWER", FindingLevel.ToCheck, "Aucune réponse au dernier relevé de présence",
                "Relevé du " + Date(checkedAt, zone) + c + "pas de réponse au ping.",
                "Le ping peut être filtré" + c + "une absence de réponse n’est jamais un verdict d’arrêt. Lancez « Poste joignable ».", FindingBasis.Limit));
        }
        if (signals.SystemDiskFreePercent is double free)
        {
            if (free < 10)
            {
                rows.Add(Finding("DISK_LOW", FindingLevel.Attention, "Disque système presque plein",
                    FrenchText.Percent(free) + " d’espace libre sur C: au dernier inventaire.", "Suivez la recette « Manque d’espace » avant toute action."));
            }
            else if (free < 20)
            {
                rows.Add(Finding("DISK_TIGHT", FindingLevel.ToCheck, "Peu d’espace sur le disque système",
                    FrenchText.Percent(free) + " d’espace libre sur C: au dernier inventaire.", "Surveillez l’espace libre ; la recette « Manque d’espace » aide à le mesurer."));
            }
        }
        if (signals.LastBootAt is DateTimeOffset boot && (now - boot).TotalDays > 30)
        {
            rows.Add(Finding("UPTIME_LONG", FindingLevel.ToCheck, "Sans redémarrage depuis " + FrenchText.Count((long)(now - boot).TotalDays, "jour", "jours"),
                "Dernier démarrage relevé le " + Date(boot, zone) + ".", "Un redémarrage planifié règle souvent la lenteur" + FrenchText.Nbsp + "; prévenez l’utilisateur avant."));
        }
        if (signals.LastLogonAt is DateTimeOffset logon && (now - logon).TotalDays > 90)
        {
            rows.Add(Finding("COMPUTER_STALE", FindingLevel.ToCheck, "Compte ordinateur inactif depuis plus de 90 jours",
                "Dernière connexion au domaine" + c + Date(logon, zone) + " (lastLogonTimestamp, répliqué avec retard).",
                "Vérifiez que le poste est encore en service avant d’intervenir."));
        }
    }
}

/// <summary>Result of one attribute in a comparison of two captures (Domenia 1: Identique, Different, Indetermine).</summary>
public enum CompareStatus
{
    Identical,
    Different,
    Undetermined,
}

public sealed record ComparisonRow(
    string Attribute,
    CompareStatus Status,
    string StatusLabel,
    Tone Tone,
    string Before,
    string After,
    ImmutableArray<string> Added,
    ImmutableArray<string> Removed);

/// <summary>
/// Comparison of the captures A and B. <see cref="Ready"/> is false while a slot is empty or when the comparison is refused
/// (<see cref="Refusal"/>: other domain, other kind of object); <see cref="SameObject"/> says whether it is the same object
/// before and after, or two objects compared as a reference (never a history).
/// </summary>
public sealed record SnapshotComparison(
    bool Ready,
    bool SameObject,
    string Summary,
    string? Refusal,
    int Different,
    int Undetermined,
    int Identical,
    ImmutableArray<ComparisonRow> Rows);

/// <summary>Domenia 1 Compare-DomeniaSupportSnapshots: attribute by attribute, a missing attribute is never a deletion.</summary>
public static class SupportComparison
{
    public const string NotProvided = "[non fourni]";
    public const string Partial = " [partiel]";

    public static string StatusLabel(CompareStatus status) => status switch
    {
        CompareStatus.Identical => "Identique",
        CompareStatus.Different => "Différent",
        _ => "Indéterminé",
    };

    public static SnapshotComparison Compare(SupportSnapshot? before, SupportSnapshot? after)
    {
        if (before is null || after is null)
        {
            return new SnapshotComparison(false, false, "Capturez A, relisez ou ouvrez une autre fiche du même type, puis capturez B.", null, 0, 0, 0, []);
        }
        if (!string.Equals(before.Scope, after.Scope, StringComparison.OrdinalIgnoreCase))
        {
            const string refusal = "Comparaison refusée" + FrenchText.Nbsp + ": périmètres d’annuaire différents.";
            return new SnapshotComparison(false, false, refusal, refusal, 0, 0, 0, []);
        }
        if (!string.Equals(before.Kind, after.Kind, StringComparison.OrdinalIgnoreCase))
        {
            const string refusal = "Comparaison refusée" + FrenchText.Nbsp + ": types d’objets différents.";
            return new SnapshotComparison(false, false, refusal, refusal, 0, 0, 0, []);
        }
        var rows = ImmutableArray.CreateBuilder<ComparisonRow>();
        foreach (var field in SupportSnapshots.FieldNames)
        {
            var leftState = before.Coverage(field);
            var rightState = after.Coverage(field);
            if (leftState == FieldCoverage.NotProvided && rightState == FieldCoverage.NotProvided)
            {
                continue;
            }
            var left = before.Text(field);
            var right = after.Text(field);
            var status = CompareStatus.Identical;
            ImmutableArray<string> added = [];
            ImmutableArray<string> removed = [];
            if (leftState != FieldCoverage.Provided || rightState != FieldCoverage.Provided)
            {
                status = CompareStatus.Undetermined;
                left = leftState == FieldCoverage.NotProvided ? NotProvided : leftState == FieldCoverage.Partial ? left + Partial : left;
                right = rightState == FieldCoverage.NotProvided ? NotProvided : rightState == FieldCoverage.Partial ? right + Partial : right;
            }
            else if (field == "memberOf")
            {
                // Direct memberships only. Case and returned order are not a change.
                var a = new HashSet<string>(before.Field(field)!.Values, StringComparer.OrdinalIgnoreCase);
                var b = new HashSet<string>(after.Field(field)!.Values, StringComparer.OrdinalIgnoreCase);
                added = [.. b.Where(v => !a.Contains(v)).Order(StringComparer.OrdinalIgnoreCase)];
                removed = [.. a.Where(v => !b.Contains(v)).Order(StringComparer.OrdinalIgnoreCase)];
                if (added.Length > 0 || removed.Length > 0)
                {
                    status = CompareStatus.Different;
                }
            }
            else if (!string.Equals(left, right, StringComparison.Ordinal))
            {
                status = CompareStatus.Different;
            }
            var tone = status switch { CompareStatus.Different => Tone.Warn, CompareStatus.Undetermined => Tone.Off, _ => Tone.Ok };
            rows.Add(new ComparisonRow(field, status, StatusLabel(status), tone, left, right, added, removed));
        }
        var all = rows.ToImmutable();
        var same = string.Equals(before.Identity, after.Identity, StringComparison.OrdinalIgnoreCase);
        var different = all.Count(r => r.Status == CompareStatus.Different);
        var undetermined = all.Count(r => r.Status == CompareStatus.Undetermined);
        var identical = all.Count(r => r.Status == CompareStatus.Identical);
        var mode = same ? "Même objet" + FrenchText.Colon + "avant et après capture." : "Objets différents" + FrenchText.Colon + "comparaison de référence, pas un historique.";
        var summary = mode + " " + FrenchText.Count(different, "différence", "différences") + ", " + FrenchText.Count(undetermined, "indéterminé", "indéterminés") + ".";
        return new SnapshotComparison(true, same, summary, null, different, undetermined, identical, all);
    }
}
