using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Exact preview of a collective action on accounts (Domenia 1 TRV-229, New-DomeniaCollectivePreview): the exact targets and
/// what each one receives, the exclusions with their reason (DN unknown, duplicate, protected account, nothing to do, beyond
/// the limit), the impact and a confirmation in proportion: the number of targets is typed from two targets on. Pure: nothing
/// is read or sent here. Each target then gets its own plan, read again just before sending, with its receipt and its re-read
/// (the page runs them one after the other and stops at the first uncertain outcome; nothing is ever replayed).
/// </summary>
public static class AccountsBatch
{
    /// <summary>Most targets of one collective action (Domenia 1: 20 000).</summary>
    public const int Limit = 20000;

    /// <summary>Lines shown in the preview before « … et N autres ».</summary>
    public const int ShownLines = 12;

    /// <summary>Candidates named beyond the limit before they are only counted.</summary>
    public const int NamedBeyond = 100;

    public static string ActionId(AccountsBatchAction action) => action switch
    {
        AccountsBatchAction.Unlock => "unlock",
        AccountsBatchAction.Enable => "enable",
        AccountsBatchAction.Disable => "disable",
        AccountsBatchAction.MustChange => "mustChange",
        _ => "expiration",
    };

    public static bool TryParse(string? value, out AccountsBatchAction action)
    {
        action = value switch
        {
            "unlock" => AccountsBatchAction.Unlock,
            "enable" => AccountsBatchAction.Enable,
            "disable" => AccountsBatchAction.Disable,
            "mustChange" => AccountsBatchAction.MustChange,
            "expiration" => AccountsBatchAction.Expiration,
            _ => (AccountsBatchAction)(-1),
        };
        return Enum.IsDefined(action);
    }

    public static string PlanOperation(AccountsBatchAction action) => action switch
    {
        AccountsBatchAction.Unlock => "accounts.unlock.plan",
        AccountsBatchAction.Enable => "accounts.enable.plan",
        AccountsBatchAction.Disable => "accounts.disable.plan",
        AccountsBatchAction.MustChange => "accounts.mustChange.plan",
        _ => "accounts.expiration.plan",
    };

    public static string Kind(AccountsBatchAction action) => action switch
    {
        AccountsBatchAction.Unlock => AccountUnlock.Kind,
        AccountsBatchAction.Enable => AccountActivation.EnableKind,
        AccountsBatchAction.Disable => AccountActivation.DisableKind,
        AccountsBatchAction.MustChange => AccountMustChangePassword.Kind,
        _ => AccountExpiration.Kind,
    };

    public static string ActionLabel(AccountsBatchAction action, DateOnly? date) => action switch
    {
        AccountsBatchAction.Unlock => "Déverrouiller",
        AccountsBatchAction.Enable => "Activer",
        AccountsBatchAction.Disable => "Désactiver",
        AccountsBatchAction.MustChange => "Imposer un nouveau mot de passe",
        _ => date is null ? "Supprimer l’expiration" : "Fixer l’expiration",
    };

    public static AccountsBatchPreview Preview(
        AccountsBatchAction action,
        IReadOnlyList<AccountsBatchCandidate> candidates,
        string? operatorDn,
        DateOnly? date,
        DateTimeOffset now,
        TimeZoneInfo zone,
        bool simulated)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var targets = new List<AccountsBatchTarget>();
        var excluded = new List<AccountsBatchExclusion>();
        var seen = new HashSet<Guid>();
        var beyondReason = "Au-delà de la limite de " + FrenchText.Integer(Limit) + " comptes";
        var examinedBeyond = 0;
        var uncounted = 0;
        for (var index = 0; index < candidates.Count; index++)
        {
            var candidate = candidates[index];
            if (targets.Count >= Limit)
            {
                if (examinedBeyond >= NamedBeyond)
                {
                    uncounted = candidates.Count - index;
                    break;
                }
                examinedBeyond++;
            }
            var user = candidate.User;
            if (user is null)
            {
                excluded.Add(new AccountsBatchExclusion(candidate.Dn, FirstValue(candidate.Dn), "Compte introuvable dans l’annuaire" + c + "relisez la liste"));
                continue;
            }
            var name = AccountsRules.NameOf(user);
            string? reason = null;
            if (!seen.Add(user.ObjectGuid))
            {
                reason = "Doublon d’un compte déjà listé";
            }
            else if (AccountsRules.HasRid(user, AccountsRules.KrbtgtRid))
            {
                reason = "Compte système (krbtgt)" + c + "jamais écrit";
            }
            else if (user.AdminCount == 1)
            {
                reason = "Compte à privilèges" + c + "à traiter seul, avec la saisie de son nom";
            }
            else
            {
                reason = NothingToDo(action, user, operatorDn, date, zone);
            }
            if (reason is null && targets.Count >= Limit)
            {
                reason = beyondReason;
            }
            if (reason is not null)
            {
                excluded.Add(new AccountsBatchExclusion(user.DistinguishedName, name, reason));
                continue;
            }
            var (before, after) = Change(action, user, date, zone);
            targets.Add(new AccountsBatchTarget(user.DistinguishedName, user.ObjectGuid.ToString("D"), name, user.SamAccountName, before + " → " + after, before, after, index));
        }
        var count = targets.Count;
        var confirmation = count == 0 ? "none" : count >= 2 ? "typed" : "simple";
        var typed = count >= 2 ? count.ToString(CultureInfo.InvariantCulture) : null;
        var groups = excluded.GroupBy(e => e.Reason, StringComparer.Ordinal)
            .Select(g => new AccountsBatchGroup(g.Key, g.Count()))
            .ToList();
        if (uncounted > 0)
        {
            var existing = groups.FindIndex(g => g.Reason == beyondReason);
            if (existing >= 0)
            {
                groups[existing] = groups[existing] with { Count = groups[existing].Count + uncounted };
            }
            else
            {
                groups.Add(new AccountsBatchGroup(beyondReason, uncounted));
            }
        }
        var orderedGroups = groups.OrderByDescending(g => g.Count).ThenBy(g => g.Reason, StringComparer.Ordinal).ToImmutableArray();
        var excludedCount = excluded.Count + uncounted;
        var impact = Impact(action, count, date);
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        if (action == AccountsBatchAction.Disable && count > 0)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Ces comptes ne pourront plus ouvrir de session" + c + "les sessions déjà ouvertes restent valables jusqu’à leur fin."));
        }
        if (action == AccountsBatchAction.Expiration && date is DateOnly day && day <= LocalDays.DateOf(now, zone))
        {
            risks.Add(new WriteRisk(Tone.Alert, "Date passée ou d’aujourd’hui" + c + "ces comptes seront expirés dès l’écriture."));
        }
        if (action == AccountsBatchAction.Unlock && count > 0)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Plusieurs verrouillages en même temps peuvent signaler une attaque par essais de mots de passe" + c + "lisez leurs verrouillages avant de tout lever."));
        }
        if (count > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, "Chaque compte reçoit son propre plan, relu juste avant l’envoi, avec son reçu et sa relecture" + c + "une issue incertaine arrête la suite, rien n’est rejoué."));
        }
        var lines = new List<string>
        {
            count == 1 ? "1 compte exact, et seulement lui." : FrenchText.Integer(count) + " comptes exacts, et seulement eux" + c + "liste complète dans le détail.",
        };
        foreach (var target in targets.Take(ShownLines))
        {
            lines.Add(target.Name + c + target.Change);
        }
        if (count > ShownLines)
        {
            lines.Add("… et " + FrenchText.Count(count - ShownLines, "autre", "autres") + ".");
        }
        if (excludedCount > 0)
        {
            lines.Add(FrenchText.Count(excludedCount, "compte exclu", "comptes exclus") + c + string.Join(" ; ", orderedGroups.Select(g => g.Reason + " (" + FrenchText.Integer(g.Count) + ")")) + ".");
        }
        lines.Add("Impact" + c + impact);
        if (typed is not null)
        {
            lines.Add("Confirmation renforcée" + c + "saisissez le nombre de comptes (" + typed + ").");
        }
        var details = new List<string> { "Comptes (" + FrenchText.Integer(count) + ")" + c };
        details.AddRange(targets.Select(t => t.Name + " — " + t.Dn + " — " + t.Change));
        if (excludedCount > 0)
        {
            details.Add("");
            details.Add("Exclus (" + FrenchText.Integer(excludedCount) + ")" + c);
            details.AddRange(excluded.Select(e => e.Name + " — " + e.Reason));
            if (uncounted > 0)
            {
                details.Add("… et " + FrenchText.Count(uncounted, "autre, non détaillé", "autres, non détaillés") + " — " + beyondReason);
            }
        }
        return new AccountsBatchPreview(
            action,
            ActionLabel(action, date),
            ActionLabel(action, date) + " " + (count == 1 ? "1 compte" : FrenchText.Integer(count) + " comptes"),
            Kind(action),
            PlanOperation(action),
            count,
            confirmation,
            typed,
            [.. targets],
            Math.Min(ShownLines, count),
            [.. excluded],
            orderedGroups,
            excludedCount,
            impact,
            risks.ToImmutable(),
            [.. lines],
            string.Join('\n', details),
            Limit,
            date,
            simulated);
    }

    /// <summary>Why nothing is to be done on this account for this action, or null when it is a target.</summary>
    public static string? NothingToDo(AccountsBatchAction action, DirectoryUser user, string? operatorDn, DateOnly? date, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var disabled = AdValues.IsDisabled(user.UserAccountControl);
        return action switch
        {
            AccountsBatchAction.Unlock when user.LockoutTime is null or <= 0 => "Pas verrouillé" + c + "rien à faire",
            AccountsBatchAction.Enable when !disabled => "Déjà activé" + c + "rien à faire",
            AccountsBatchAction.Disable when disabled => "Déjà désactivé" + c + "rien à faire",
            AccountsBatchAction.Disable when operatorDn is not null && AccountsRules.SameDn(user.DistinguishedName, operatorDn) => "Votre compte de session" + c + "jamais désactivé depuis Domenia",
            AccountsBatchAction.MustChange when (user.PasswordLastSet ?? 0) == 0 => "Changement déjà exigé" + c + "rien à faire",
            AccountsBatchAction.MustChange when AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword) => "Mot de passe sans expiration" + c + "changement sans effet",
            AccountsBatchAction.Expiration when AccountExpiration.DayOf(user.AccountExpires, zone) == date => "Déjà à cette expiration" + c + "rien à faire",
            _ => null,
        };
    }

    private static (string Before, string After) Change(AccountsBatchAction action, DirectoryUser user, DateOnly? date, TimeZoneInfo zone)
    {
        switch (action)
        {
            case AccountsBatchAction.Unlock:
                var state = AccountsRules.LockOf(user);
                return (state == AccountLock.Locked ? "Verrouillé" : state == AccountLock.ToCheck ? "Verrouillage à vérifier" : "Verrouillage échu", "Déverrouillé");
            case AccountsBatchAction.Enable:
                return ("Désactivé", "Activé");
            case AccountsBatchAction.Disable:
                return ("Activé", "Désactivé");
            case AccountsBatchAction.MustChange:
                return (AdValues.FromFileTime(user.PasswordLastSet) is DateTimeOffset set ? "Changé le " + AccountsRules.DateText(set, zone) : "Inconnu", "Changement exigé");
            default:
                return (AccountExpiration.Text(AccountExpiration.DayOf(user.AccountExpires, zone)), AccountExpiration.Text(date));
        }
    }

    private static string Impact(AccountsBatchAction action, int count, DateOnly? date)
    {
        if (count == 0)
        {
            return "aucun compte ne change.";
        }
        var accounts = count == 1 ? "1 compte" : FrenchText.Integer(count) + " comptes";
        return action switch
        {
            AccountsBatchAction.Unlock => accounts + (count == 1 ? " pourra" : " pourront") + " de nouveau ouvrir une session.",
            AccountsBatchAction.Enable => accounts + (count == 1 ? " pourra" : " pourront") + " de nouveau ouvrir une session.",
            AccountsBatchAction.Disable => accounts + (count == 1 ? " ne pourra" : " ne pourront") + " plus ouvrir de session.",
            AccountsBatchAction.MustChange => (count == 1 ? "1 utilisateur devra" : FrenchText.Integer(count) + " utilisateurs devront") + " choisir un nouveau mot de passe à la prochaine connexion.",
            _ => date is DateOnly d
                ? accounts + (count == 1 ? " expirera" : " expireront") + " le " + FrenchText.ShortDate(d) + " à 0 h."
                : accounts + (count == 1 ? " n’expirera" : " n’expireront") + " plus.",
        };
    }

    private static string FirstValue(string dn)
    {
        try
        {
            var names = DistinguishedName.Parse(dn);
            return names.Length > 0 ? names[0].Value : dn;
        }
        catch (FormatException)
        {
            return dn;
        }
    }
}
