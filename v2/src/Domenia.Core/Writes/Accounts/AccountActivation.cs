using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Executor of the enable of a user account (Domenia 1 FIC-013, Set-AccountDisabled $false).</summary>
public interface IAccountEnableExecutor : IWriteExecutor
{
    /// <summary>Reads the account and drafts its enable. Errors: write.targetUnknown, write.nothingToDo, accounts.protectedAccount.</summary>
    Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>Executor of the disable of a user account (Domenia 1 FIC-013, Set-AccountDisabled $true).</summary>
public interface IAccountDisableExecutor : IWriteExecutor
{
    /// <summary>
    /// Reads the account and drafts its disable. Errors: write.targetUnknown, write.nothingToDo, accounts.protectedAccount (krbtgt,
    /// own session account).
    /// </summary>
    Task<WritePlanDraft> PlanAsync(string dn, string? operatorDn, CancellationToken cancellationToken);
}

/// <summary>
/// Rules of the enable and disable of a user account (pure, reusable with Active Directory): bit 0x2 of userAccountControl,
/// only this bit changes. The disable is a « danger » write (Domenia 1: confirmation renforcée): its risks are said, the
/// typed name is asked for protected accounts, and the session account itself is never disabled (the operator would lose
/// his access). Both are reversible by a new plan in the other direction, never automatically.
/// </summary>
public static class AccountActivation
{
    public const string EnableKind = "account.enable";
    public const string DisableKind = "account.disable";
    public const string Attribute = "userAccountControl";

    public static string KindOf(bool enable) => enable ? EnableKind : DisableKind;

    /// <summary>Draft of the change of state of <paramref name="user"/>; write.nothingToDo when it is already in that state.</summary>
    public static WritePlanDraft Draft(DirectoryUser user, bool enable, string? operatorDn, DomainInfo domain, string? controller, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        AccountWrites.EnsureNotSystem(user);
        var disabled = AdValues.IsDisabled(user.UserAccountControl);
        if (enable && !disabled)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Ce compte est déjà activé" + c + "aucune écriture à préparer.");
        }
        if (!enable && disabled)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Ce compte est déjà désactivé" + c + "aucune écriture à préparer.");
        }
        if (!enable && operatorDn is not null && AccountsRules.SameDn(user.DistinguishedName, operatorDn))
        {
            throw WriteErrors.Refusal(AccountWrites.ProtectedAccount, "C’est votre compte de session" + c + "le désactiver vous retirerait l’accès à l’annuaire. Aucune écriture n’est préparée.");
        }
        var name = AccountsRules.NameOf(user);
        var before = user.UserAccountControl;
        var after = enable ? before & ~AdValues.AccountDisabled : before | AdValues.AccountDisabled;
        var risks = new List<WriteRisk>();
        AccountWrites.AddPrivilegedRisk(user, risks);
        if (enable)
        {
            if (AccountsRules.HasRid(user, AccountsRules.GuestRid))
            {
                risks.Add(new WriteRisk(Tone.Alert, "Compte Invité intégré" + c + "l’activer ouvre une session sans identité nominative. À éviter, sauf décision écrite."));
            }
            var lockState = AccountsRules.LockOf(user);
            if (lockState == AccountLock.Locked)
            {
                risks.Add(new WriteRisk(Tone.Warn, "Le compte est aussi verrouillé" + c + "même activé, il ne pourra ouvrir de session qu’après un déverrouillage."));
            }
            var password = AccountState.ClassifyPassword(user, domain.PasswordPolicy.MaxPasswordAge, now, AccountsRules.ExpiringWindow);
            if (password == PasswordClass.Expired)
            {
                risks.Add(new WriteRisk(Tone.Info, "Mot de passe expiré" + c + "l’utilisateur devra le changer, ou un administrateur le réinitialiser."));
            }
            else if (password == PasswordClass.MustChange)
            {
                risks.Add(new WriteRisk(Tone.Info, "Mot de passe à changer à la prochaine connexion."));
            }
            if (AccountsRules.AccountExpiry(user) is DateTimeOffset expires && expires <= now)
            {
                risks.Add(new WriteRisk(Tone.Warn, "Compte expiré le " + AccountsRules.DateText(expires, zone) + c + "activé, il reste bloqué tant que l’expiration n’est pas repoussée."));
            }
            if (user.Description is string description && description.StartsWith("Départ", StringComparison.OrdinalIgnoreCase))
            {
                risks.Add(new WriteRisk(Tone.Warn, "Description " + FrenchText.Quote(description) + c + "vérifiez que ce retour est bien prévu."));
            }
        }
        else
        {
            risks.Add(new WriteRisk(Tone.Warn, name + " ne pourra plus ouvrir de session" + c + "les sessions déjà ouvertes et leurs tickets Kerberos restent valables jusqu’à leur fin."));
            if (user.SamAccountName.StartsWith("svc-", StringComparison.OrdinalIgnoreCase))
            {
                risks.Add(new WriteRisk(Tone.Alert, "Compte de service" + c + "les services et tâches qui l’utilisent cesseront de s’authentifier."));
            }
            if (AccountsRules.HasRid(user, AccountsRules.AdministratorRid))
            {
                risks.Add(new WriteRisk(Tone.Alert, "Administrateur intégré du domaine (RID 500)" + c + "gardez au moins un autre compte d’administration actif."));
            }
            if (AdValues.FromFileTime(user.LastLogonTimestamp) is DateTimeOffset seen && now - seen < TimeSpan.FromDays(14))
            {
                risks.Add(new WriteRisk(Tone.Info, "Dernière connexion " + AccountsRules.Ago(now - seen) + " (à 14 jours près)" + c + "le compte est en service."));
            }
        }
        var summary = enable
            ? name + " pourra de nouveau ouvrir une session" + c + "bit «\u00A0compte désactivé\u00A0» retiré de userAccountControl" + AccountWrites.On(controller) + "."
            : name + " ne pourra plus ouvrir de session" + c + "bit «\u00A0compte désactivé\u00A0» ajouté à userAccountControl" + AccountWrites.On(controller) + ".";
        return new WritePlanDraft(
            KindOf(enable),
            enable ? "Activer le compte" : "Désactiver le compte",
            enable ? "Activation du compte" : "Désactivation du compte",
            summary,
            AccountWrites.Target(user),
            [
                new WriteChange(Attribute, "État du compte", WriteChangeKind.Replace, disabled ? "Désactivé" : "Activé", enable ? "Activé" : "Désactivé",
                    before.ToString(CultureInfo.InvariantCulture), after.ToString(CultureInfo.InvariantCulture)),
            ],
            [.. risks],
            enable
                ? AccountWrites.Confirmation(user, "Confirmation simple" + c + "compte standard réactivé, aucun droit ni mot de passe modifié.")
                : AccountWrites.Confirmation(user, "Confirmation renforcée dans le dialogue" + c + "désactivation d’un compte standard."),
            new WriteReversibility(true, "Réversible par un nouveau plan",
                enable
                    ? "«\u00A0Désactiver\u00A0» le compte de nouveau, par un nouveau plan confirmé." + " Rien n’est défait automatiquement."
                    : "«\u00A0Activer\u00A0» rétablit l’accès, par un nouveau plan confirmé. Les groupes et le mot de passe ne changent pas. Rien n’est défait automatiquement."),
            controller);
    }

    /// <summary>
    /// Preconditions: same object at the same place, userAccountControl unchanged since the plan. Already in the requested
    /// state meanwhile: valid, nothing will be written.
    /// </summary>
    public static WritePrecheck Check(WritePlan plan, DirectoryUser? user, bool enable)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var c = FrenchText.Colon;
        if (AccountWrites.CheckIdentity(plan, user) is WritePrecheck stale)
        {
            return stale;
        }
        var current = user!.UserAccountControl;
        if (AdValues.IsDisabled(current) != enable)
        {
            return WritePrecheck.Valid("Compte relu" + c + (enable ? "déjà activé" : "déjà désactivé") + ", rien ne sera écrit.");
        }
        if (!string.Equals(current.ToString(CultureInfo.InvariantCulture), AccountWrites.PlannedBefore(plan, Attribute), StringComparison.Ordinal))
        {
            return WritePrecheck.Stale("Les options du compte (userAccountControl) ont changé depuis le plan" + c + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Compte relu" + AccountWrites.On(plan.Controller) + c + (enable ? "toujours désactivé" : "toujours activé") + ", DN et GUID inchangés.");
    }

    /// <summary>True when nothing is to be written.</summary>
    public static bool IsDone(DirectoryUser user, bool enable)
    {
        ArgumentNullException.ThrowIfNull(user);
        return AdValues.IsDisabled(user.UserAccountControl) != enable;
    }

    /// <summary>The account after the write (simulation): only bit 0x2 changes.</summary>
    public static DirectoryUser Apply(DirectoryUser user, bool enable, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(user);
        var uac = enable ? user.UserAccountControl & ~AdValues.AccountDisabled : user.UserAccountControl | AdValues.AccountDisabled;
        return user with { UserAccountControl = uac, WhenChanged = now, UsnChanged = usn };
    }

    /// <summary>Postcondition (OPE-009): bit 0x2 read again as requested.</summary>
    public static WriteVerification Verify(DirectoryUser? user, bool enable, string? controller)
    {
        var c = FrenchText.Colon;
        if (user is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Compte introuvable à la relecture" + c + "vérifiez-le dans l’annuaire.");
        }
        var disabled = AdValues.IsDisabled(user.UserAccountControl);
        var uac = user.UserAccountControl.ToString(CultureInfo.InvariantCulture);
        return disabled != enable
            ? new WriteVerification(VerificationState.Verified, "userAccountControl = " + uac + " relu" + AccountWrites.On(controller) + c + (enable ? "compte activé." : "compte désactivé."))
            : new WriteVerification(VerificationState.Mismatch, "userAccountControl = " + uac + " relu" + AccountWrites.On(controller) + c + (enable ? "le compte est encore désactivé." : "le compte est encore activé."));
    }

    /// <summary>Change text of a collective preview (« Activé → Désactivé »).</summary>
    public static ImmutableArray<string> Texts(bool enable) => enable ? ["Désactivé", "Activé"] : ["Activé", "Désactivé"];
}
