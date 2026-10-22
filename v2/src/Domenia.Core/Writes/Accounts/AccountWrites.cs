using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Pieces shared by the account writes of the Comptes screen (enable, disable, password reset, forced change, expiration):
/// the exact target, the confirmation by typed name for protected accounts (TRV-186 improved: elevation per write), the
/// refusals of protected accounts and the identity check of the preconditions. Pure.
/// </summary>
public static class AccountWrites
{
    /// <summary>Refusal of a write on an account Domenia never writes (krbtgt, own session account for a disable).</summary>
    public const string ProtectedAccount = "accounts.protectedAccount";

    /// <summary>The account as the target of a plan.</summary>
    public static WriteTarget Target(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        return new WriteTarget("user", "Compte utilisateur", AccountsRules.NameOf(user), user.DistinguishedName, user.ObjectGuid.ToString("D"), user.SamAccountName);
    }

    /// <summary>Typed name for a protected account (adminCount = 1), simple confirmation otherwise.</summary>
    public static WriteConfirmation Confirmation(DirectoryUser user, string simpleReason)
    {
        ArgumentNullException.ThrowIfNull(user);
        return user.AdminCount == 1
            ? new WriteConfirmation(true, user.SamAccountName, "Saisie du nom exigée" + FrenchText.Colon + "compte à privilèges.")
            : new WriteConfirmation(false, null, simpleReason);
    }

    /// <summary>The risk line of a protected account, when it is one.</summary>
    public static void AddPrivilegedRisk(DirectoryUser user, ICollection<WriteRisk> risks)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(risks);
        if (user.AdminCount == 1)
        {
            risks.Add(new WriteRisk(Tone.Alert, "Compte à privilèges (adminCount = 1)" + FrenchText.Colon + "confirmez la demande par un autre canal ; la saisie du nom est exigée."));
        }
    }

    /// <summary>krbtgt is never written from Domenia.</summary>
    public static void EnsureNotSystem(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        if (AccountsRules.HasRid(user, AccountsRules.KrbtgtRid))
        {
            throw WriteErrors.Refusal(ProtectedAccount, "krbtgt est un compte système géré par le domaine" + FrenchText.Colon + "aucune écriture n’est préparée.");
        }
    }

    /// <summary>Same object at the same place as in the plan, or the stale reason (nothing was sent).</summary>
    public static WritePrecheck? CheckIdentity(WritePlan plan, DirectoryUser? user)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var c = FrenchText.Colon;
        if (user is null)
        {
            return WritePrecheck.Stale("Le compte n’existe plus dans l’annuaire" + c + "rien n’a été envoyé.");
        }
        if (!string.Equals(user.ObjectGuid.ToString("D"), plan.Target.ObjectGuid, StringComparison.OrdinalIgnoreCase) || !AccountsRules.SameDn(user.DistinguishedName, plan.Target.Dn))
        {
            return WritePrecheck.Stale("Le compte a été déplacé ou renommé depuis le plan" + c + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        return null;
    }

    /// <summary>Raw « before » value of a change of the plan.</summary>
    public static string? PlannedBefore(WritePlan plan, string attribute)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return plan.Changes.FirstOrDefault(change => change.Attribute == attribute)?.BeforeValue;
    }

    /// <summary>True when the plan holds a change of this attribute.</summary>
    public static bool Changes(WritePlan plan, string attribute)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return plan.Changes.Any(change => change.Attribute == attribute);
    }

    /// <summary>Invariant text of an integer value of the directory.</summary>
    public static string Raw(long value) => value.ToString(CultureInfo.InvariantCulture);

    /// <summary>« sur DC01.example.local » or nothing.</summary>
    public static string On(string? controller) => controller is null ? "" : " sur " + controller;
}
