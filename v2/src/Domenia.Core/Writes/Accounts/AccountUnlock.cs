using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Executor of the unlock of a user account (Domenia 1 FIC-012, Unlock-UserAccount and its postcondition « lockoutTime à 0 »),
/// served by the source of the mode: Domenia.Simulation writes to the in-memory overlay, Domenia.Ad will clear lockoutTime
/// on the controller (wave 3). The rules themselves are pure and shared: <see cref="AccountUnlock"/>.
/// </summary>
public interface IAccountUnlockExecutor : IWriteExecutor
{
    /// <summary>
    /// Reads the account by its DN (memory in simulation; a fresh read on the controller in directory mode, after the operator's
    /// gesture) and drafts its unlock. Never writes. Errors: write.targetUnknown (no user at this DN), write.nothingToDo (not
    /// locked).
    /// </summary>
    Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>
/// Rules of the unlock of a user account (pure, reusable with Active Directory): the plan, the preconditions read again just
/// before sending, the change itself (for the simulated overlay) and the postcondition. Domenia 1 cleared lockoutTime even
/// when the lockout had already expired, and wrote nothing when it was already 0 (« Compte déjà déverrouillé ») : same here.
/// The typed name is asked for protected accounts (adminCount = 1), the improvement of TRV-186.
/// </summary>
public static class AccountUnlock
{
    public const string Kind = "account.unlock";
    public const string Title = "Déverrouiller le compte";
    public const string Label = "Déverrouillage du compte";
    public const string Attribute = "lockoutTime";

    public const string NotLockedMessage = "Ce compte n’est pas verrouillé : aucune écriture à préparer.";

    /// <summary>Draft of the unlock of <paramref name="user"/> as read now; write.nothingToDo when lockoutTime is empty or 0.</summary>
    public static WritePlanDraft Draft(DirectoryUser user, DomainInfo domain, string? controller, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(zone);
        if (user.LockoutTime is not long lockout || lockout <= 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, NotLockedMessage);
        }
        var c = FrenchText.Colon;
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        var name = user.DisplayName ?? user.Cn;
        var lockedAt = AdValues.FromFileTime(lockout);
        var before = state.Lock switch
        {
            LockState.Locked => lockedAt is DateTimeOffset at ? "Verrouillé depuis le " + WritePlans.LocalTime(at, zone) : "Verrouillé",
            LockState.ToCheck => "Verrouillage à vérifier (lockoutTime renseigné)",
            _ => "Verrouillage expiré (lockoutTime encore renseigné)",
        };
        var privileged = user.AdminCount == 1;
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        if (privileged)
        {
            risks.Add(new WriteRisk(Tone.Alert, "Compte à privilèges (adminCount = 1)" + c + "confirmez l’identité du demandeur par un autre canal\u00A0; la saisie du nom est exigée."));
        }
        switch (state.Lock)
        {
            case LockState.Locked:
                var attempts = user.BadPasswordCount is int count and > 0 ? " (" + FrenchText.Count(count, "essai erroné", "essais erronés") + ")" : "";
                risks.Add(new WriteRisk(Tone.Warn, "Vérifiez l’identité du demandeur" + c + "un verrouillage" + attempts + " peut aussi venir d’une tentative d’intrusion ou d’un ancien mot de passe enregistré sur un poste."));
                break;
            case LockState.ToCheck:
                risks.Add(new WriteRisk(Tone.Info, "Le contrôleur n’a pas confirmé le verrouillage (calcul illisible)" + c + "le déverrouillage remet seulement lockoutTime à zéro."));
                break;
            default:
                var duration = domain.PasswordPolicy.LockoutDuration;
                var minutes = duration > TimeSpan.Zero ? " (durée de " + FrenchText.Integer((long)duration.TotalMinutes) + " min)" : "";
                risks.Add(new WriteRisk(Tone.Info, "Le verrouillage a déjà expiré" + minutes + c + "le déverrouillage efface seulement son horodatage."));
                break;
        }
        if (state.Disabled)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Ce compte est désactivé" + c + "même déverrouillé, il ne pourra pas ouvrir de session."));
        }
        if (user.BadPasswordCount is int bad and > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, "Le contrôleur remet aussi à zéro le compteur d’essais erronés (" + FrenchText.Integer(bad) + ")."));
        }
        if (state.PasswordExpired || user.PasswordLastSet == 0)
        {
            risks.Add(new WriteRisk(Tone.Info, "Mot de passe à changer" + c + "l’utilisateur devra le modifier à sa prochaine connexion."));
        }
        var where = controller is null ? "" : " sur " + controller;
        var summary = state.Disabled
            ? "Le verrouillage de " + name + " sera levé (lockoutTime remis à zéro" + where + ")" + c + "le compte reste désactivé."
            : name + " pourra de nouveau ouvrir une session" + c + "lockoutTime remis à zéro" + where + ".";
        return new WritePlanDraft(
            Kind,
            Title,
            Label,
            summary,
            new WriteTarget("user", "Compte utilisateur", name, user.DistinguishedName, user.ObjectGuid.ToString("D"), user.SamAccountName),
            [
                new WriteChange(Attribute, "Verrouillage", WriteChangeKind.Clear, before, "Déverrouillé",
                    lockout.ToString(CultureInfo.InvariantCulture), "0"),
            ],
            risks.ToImmutable(),
            privileged
                ? new WriteConfirmation(true, user.SamAccountName, "Saisie du nom exigée" + c + "compte à privilèges.")
                : new WriteConfirmation(false, null, "Confirmation simple" + c + "compte standard\u00A0; ni droit ni mot de passe modifié."),
            new WriteReversibility(false, "Sans retour arrière",
                "Un déverrouillage ne se défait pas" + c + "le compte ne se verrouille de nouveau qu’après de nouveaux essais erronés. Aucune compensation n’est proposée, comme dans Domenia 1."),
            controller);
    }

    /// <summary>
    /// Preconditions read again just before sending: same object at the same place, lockoutTime unchanged since the plan. An
    /// account already unlocked meanwhile stays valid: nothing will be written (result « already done »).
    /// </summary>
    public static WritePrecheck Check(WritePlan plan, DirectoryUser? user, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        if (user is null)
        {
            return WritePrecheck.Stale("Le compte n’existe plus dans l’annuaire" + c + "rien n’a été envoyé.");
        }
        if (!string.Equals(user.ObjectGuid.ToString("D"), plan.Target.ObjectGuid, StringComparison.OrdinalIgnoreCase) || !SameDn(user.DistinguishedName, plan.Target.Dn))
        {
            return WritePrecheck.Stale("Le compte a été déplacé ou renommé depuis le plan" + c + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        var current = user.LockoutTime ?? 0;
        if (current == 0)
        {
            return WritePrecheck.Valid("Compte relu" + c + "déjà déverrouillé, rien ne sera écrit.");
        }
        var planned = plan.Changes.FirstOrDefault(change => change.Attribute == Attribute)?.BeforeValue;
        if (!string.Equals(current.ToString(CultureInfo.InvariantCulture), planned, StringComparison.Ordinal))
        {
            var when = AdValues.FromFileTime(current) is DateTimeOffset at ? " le " + WritePlans.LocalTime(at, zone) : "";
            return WritePrecheck.Stale("Le compte a été verrouillé de nouveau depuis le plan" + when + c + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Compte relu" + (plan.Controller is null ? "" : " sur " + plan.Controller) + c + "toujours verrouillé, DN et GUID inchangés.");
    }

    /// <summary>The account after the unlock, as the controller leaves it: lockoutTime 0, lockout bit and bad password count cleared.</summary>
    public static DirectoryUser Apply(DirectoryUser user, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(user);
        return user with
        {
            LockoutTime = 0,
            ComputedAccountControl = user.ComputedAccountControl & ~AdValues.LockedOut,
            BadPasswordCount = user.BadPasswordCount is null ? null : 0,
            WhenChanged = now,
            UsnChanged = usn,
        };
    }

    /// <summary>True when nothing is to be written: lockoutTime already empty or 0.</summary>
    public static bool IsUnlocked(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        return user.LockoutTime is null or <= 0;
    }

    /// <summary>Postcondition (OPE-009): lockoutTime 0 and no lockout computed by the controller.</summary>
    public static WriteVerification Verify(DirectoryUser? user, string? controller)
    {
        var c = FrenchText.Colon;
        if (user is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Compte introuvable à la relecture" + c + "vérifiez-le dans l’annuaire.");
        }
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        var where = controller is null ? "" : " sur " + controller;
        if (IsUnlocked(user) && state.Lock == LockState.Unlocked)
        {
            return new WriteVerification(VerificationState.Verified, "lockoutTime = 0 relu" + where + c + "compte déverrouillé.");
        }
        var value = (user.LockoutTime ?? 0).ToString(CultureInfo.InvariantCulture);
        return new WriteVerification(VerificationState.Mismatch,
            "Le compte est encore verrouillé à la relecture" + where + " (lockoutTime = " + value + ")" + c + "de nouveaux essais erronés ont pu le verrouiller de nouveau.");
    }

    private static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
