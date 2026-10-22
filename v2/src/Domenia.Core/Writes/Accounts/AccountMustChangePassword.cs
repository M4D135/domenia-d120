namespace Domenia.Core;

/// <summary>Executor of « imposer un nouveau mot de passe » (Domenia 1 FIC-017, Expire-UserPasswordNow: pwdLastSet = 0).</summary>
public interface IAccountMustChangePasswordExecutor : IWriteExecutor
{
    /// <summary>Reads the account and drafts the change. Errors: write.targetUnknown, write.nothingToDo, accounts.protectedAccount.</summary>
    Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>
/// Rules of the forced password change (pure): pwdLastSet set to 0, the current password is not modified; the user chooses a
/// new one at the next logon. Refused when it would have no effect (password that never expires) or is already required.
/// </summary>
public static class AccountMustChangePassword
{
    public const string Kind = "account.mustChangePassword";
    public const string Title = "Imposer un nouveau mot de passe";
    public const string Label = "Changement de mot de passe imposé";
    public const string Attribute = "pwdLastSet";

    public static WritePlanDraft Draft(DirectoryUser user, string? controller, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        AccountWrites.EnsureNotSystem(user);
        var lastSet = user.PasswordLastSet ?? 0;
        if (lastSet == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le changement de mot de passe est déjà imposé à ce compte" + c + "aucune écriture à préparer.");
        }
        if (AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword))
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le mot de passe de ce compte n’expire jamais" + c + "un changement imposé resterait sans effet. Aucune écriture préparée.");
        }
        var name = AccountsRules.NameOf(user);
        var before = AdValues.FromFileTime(lastSet) is DateTimeOffset set ? "Changé le " + WritePlans.LocalTime(set, zone) : "Inconnu";
        var risks = new List<WriteRisk>();
        AccountWrites.AddPrivilegedRisk(user, risks);
        risks.Add(new WriteRisk(Tone.Info, name + " devra choisir un nouveau mot de passe à sa prochaine ouverture de session" + c + "l’actuel reste valable jusque-là."));
        if (AdValues.IsDisabled(user.UserAccountControl))
        {
            risks.Add(new WriteRisk(Tone.Warn, "Ce compte est désactivé" + c + "le changement ne sera demandé qu’après sa réactivation."));
        }
        if (user.SamAccountName.StartsWith("svc-", StringComparison.OrdinalIgnoreCase))
        {
            risks.Add(new WriteRisk(Tone.Alert, "Compte de service" + c + "les services qui l’utilisent ne pourront plus s’authentifier tant que le mot de passe n’est pas changé."));
        }
        if (AdValues.FromFileTime(user.LastLogonTimestamp) is null)
        {
            risks.Add(new WriteRisk(Tone.Info, "Aucune connexion enregistrée pour ce compte."));
        }
        return new WritePlanDraft(
            Kind,
            Title,
            Label,
            name + " devra choisir un nouveau mot de passe à sa prochaine connexion" + c + "pwdLastSet remis à 0" + AccountWrites.On(controller) + ", l’actuel n’est pas modifié.",
            AccountWrites.Target(user),
            [new WriteChange(Attribute, "Changement à la prochaine connexion", WriteChangeKind.Replace, before, "Exigé (pwdLastSet = 0)", AccountWrites.Raw(lastSet), "0")],
            [.. risks],
            AccountWrites.Confirmation(user, "Confirmation simple" + c + "compte standard, le mot de passe actuel n’est pas modifié."),
            new WriteReversibility(false, "Sans retour arrière automatique", "Le changement reste exigé jusqu’à ce que l’utilisateur choisisse un nouveau mot de passe. Aucune compensation n’est proposée, comme dans Domenia 1."),
            controller);
    }

    public static WritePrecheck Check(WritePlan plan, DirectoryUser? user)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var c = FrenchText.Colon;
        if (AccountWrites.CheckIdentity(plan, user) is WritePrecheck stale)
        {
            return stale;
        }
        var current = user!.PasswordLastSet ?? 0;
        if (current == 0)
        {
            return WritePrecheck.Valid("Compte relu" + c + "changement déjà exigé, rien ne sera écrit.");
        }
        if (!string.Equals(AccountWrites.Raw(current), AccountWrites.PlannedBefore(plan, Attribute), StringComparison.Ordinal))
        {
            return WritePrecheck.Stale("Le mot de passe a été changé depuis le plan" + c + "relisez le compte puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Compte relu" + AccountWrites.On(plan.Controller) + c + "pwdLastSet inchangé, DN et GUID inchangés.");
    }

    public static bool IsDone(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        return (user.PasswordLastSet ?? 0) == 0;
    }

    public static DirectoryUser Apply(DirectoryUser user, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(user);
        return user with { PasswordLastSet = 0, PasswordExpiryComputed = 0, WhenChanged = now, UsnChanged = usn };
    }

    public static WriteVerification Verify(DirectoryUser? user, string? controller)
    {
        var c = FrenchText.Colon;
        if (user is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Compte introuvable à la relecture" + c + "vérifiez-le dans l’annuaire.");
        }
        var value = user.PasswordLastSet ?? 0;
        return value == 0
            ? new WriteVerification(VerificationState.Verified, "pwdLastSet = 0 relu" + AccountWrites.On(controller) + c + "changement exigé à la prochaine connexion.")
            : new WriteVerification(VerificationState.Mismatch, "pwdLastSet = " + AccountWrites.Raw(value) + " relu" + AccountWrites.On(controller) + c + "le changement n’est pas exigé.");
    }
}
