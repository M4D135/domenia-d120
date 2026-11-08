using System.Globalization;

namespace Domenia.Core;

/// <summary>Executor of the expiration date of a user account (Domenia 1 FIC-016, Set-UserExpiration).</summary>
public interface IAccountExpirationExecutor : IWriteExecutor
{
    /// <summary>
    /// Reads the account and drafts the new expiration: <paramref name="date"/> is the local day the account expires at 0:00,
    /// null for « never ». Errors: write.targetUnknown, write.nothingToDo, accounts.protectedAccount.
    /// </summary>
    Task<WritePlanDraft> PlanAsync(string dn, DateOnly? date, CancellationToken cancellationToken);
}

/// <summary>
/// Rules of the account expiration (pure). Same encoding as Domenia 1: the chosen local day at 0:00, as a FILETIME in
/// accountExpires, or 0 for « never » (0 and the maximum value both mean never); the date read again is compared by local day.
/// The expiration blocks the logon without disabling the account (Domenia 1 RCH-106). Reversible by a new plan.
/// </summary>
public static class AccountExpiration
{
    public const string Kind = "account.expiration";
    public const string Attribute = "accountExpires";

    /// <summary>Furthest date accepted (beyond it, a date is a typing mistake rather than a decision).</summary>
    public const int MaxYearsAhead = 50;

    /// <summary>Raw value of accountExpires for a local day (0:00 of that day) or for « never ».</summary>
    public static long RawValue(DateOnly? date, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return date is DateOnly day ? AdValues.ToFileTime(LocalDays.StartOf(day, zone)) : 0;
    }

    /// <summary>Local expiry day of the account, or null when it never expires.</summary>
    public static DateOnly? DayOf(long? accountExpires, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return AdValues.FromFileTime(accountExpires) is DateTimeOffset at ? LocalDays.DateOf(at, zone) : null;
    }

    /// <summary>« Expire le 15/11/2026 à 0 h (dernier jour : 14/11/2026) » or « Aucune expiration ».</summary>
    public static string Text(DateOnly? day) => day is DateOnly d
        ? "Expire le " + FrenchText.ShortDate(d) + " à 0 h (dernier jour" + FrenchText.Colon + FrenchText.ShortDate(d.AddDays(-1)) + ")"
        : "Aucune expiration";

    public static WritePlanDraft Draft(DirectoryUser user, DateOnly? date, string? controller, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        AccountWrites.EnsureNotSystem(user);
        var current = DayOf(user.AccountExpires, zone);
        if (current == date)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, (date is null ? "Ce compte n’a déjà aucune expiration" : "Ce compte expire déjà à cette date") + c + "aucune écriture à préparer.");
        }
        var name = AccountsRules.NameOf(user);
        var today = LocalDays.DateOf(now, zone);
        var risks = new List<WriteRisk>();
        AccountWrites.AddPrivilegedRisk(user, risks);
        if (date is DateOnly day)
        {
            if (day <= today)
            {
                risks.Add(new WriteRisk(Tone.Alert, "Date passée ou d’aujourd’hui" + c + "le compte sera expiré dès l’écriture et ne pourra plus ouvrir de session."));
            }
            else if (day.DayNumber - today.DayNumber <= 7)
            {
                risks.Add(new WriteRisk(Tone.Warn, "Expiration proche (" + FrenchText.Count(day.DayNumber - today.DayNumber, "jour", "jours") + ")" + c + "prévenez l’utilisateur."));
            }
            risks.Add(new WriteRisk(Tone.Info, "L’expiration bloque l’ouverture de session sans désactiver le compte" + c + "ses groupes et son mot de passe ne changent pas."));
        }
        else
        {
            risks.Add(new WriteRisk(Tone.Info, "Le compte n’expirera plus" + c + "pensez aux comptes temporaires (stagiaires, prestataires)."));
        }
        if (AdValues.IsDisabled(user.UserAccountControl))
        {
            risks.Add(new WriteRisk(Tone.Info, "Ce compte est désactivé" + c + "l’expiration ne compte qu’après sa réactivation."));
        }
        var target = RawValue(date, zone);
        var summary = date is DateOnly d2
            ? "Le compte de " + name + " expirera le " + FrenchText.ShortDate(d2) + " à 0 h" + c + "accountExpires écrit" + AccountWrites.On(controller) + "."
            : "Le compte de " + name + " n’expirera plus" + c + "accountExpires remis à 0" + AccountWrites.On(controller) + ".";
        return new WritePlanDraft(
            Kind,
            date is null ? "Supprimer l’expiration du compte" : "Définir l’expiration du compte",
            date is null ? "Suppression de l’expiration du compte" : "Expiration du compte",
            summary,
            AccountWrites.Target(user),
            [new WriteChange(Attribute, "Expiration du compte", WriteChangeKind.Replace, Text(current), Text(date),
                (user.AccountExpires ?? 0).ToString(CultureInfo.InvariantCulture), target.ToString(CultureInfo.InvariantCulture))],
            [.. risks],
            AccountWrites.Confirmation(user, "Confirmation simple" + c + "compte standard, réversible par un nouveau plan."),
            new WriteReversibility(true, "Réversible par un nouveau plan", "Ancienne valeur" + c + Text(current) + ". Un nouveau plan confirmé la rétablit ; rien n’est défait automatiquement."),
            controller);
    }

    public static WritePrecheck Check(WritePlan plan, DirectoryUser? user, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        if (AccountWrites.CheckIdentity(plan, user) is WritePrecheck stale)
        {
            return stale;
        }
        var change = plan.Changes.First(x => x.Attribute == Attribute);
        var currentDay = DayOf(user!.AccountExpires, zone);
        var targetDay = DayOf(ParseRaw(change.AfterValue), zone);
        if (currentDay == targetDay)
        {
            return WritePrecheck.Valid("Compte relu" + c + "expiration déjà à la valeur demandée, rien ne sera écrit.");
        }
        if (currentDay != DayOf(ParseRaw(change.BeforeValue), zone))
        {
            return WritePrecheck.Stale("L’expiration du compte a changé depuis le plan" + c + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Compte relu" + AccountWrites.On(plan.Controller) + c + "expiration inchangée, DN et GUID inchangés.");
    }

    public static bool IsDone(DirectoryUser user, WritePlan plan, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(plan);
        return DayOf(user.AccountExpires, zone) == DayOf(ParseRaw(plan.Changes.First(x => x.Attribute == Attribute).AfterValue), zone);
    }

    public static DirectoryUser Apply(DirectoryUser user, WritePlan plan, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(plan);
        return user with { AccountExpires = ParseRaw(plan.Changes.First(x => x.Attribute == Attribute).AfterValue) ?? 0, WhenChanged = now, UsnChanged = usn };
    }

    public static WriteVerification Verify(DirectoryUser? user, WritePlan plan, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        if (user is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Compte introuvable à la relecture" + c + "vérifiez-le dans l’annuaire.");
        }
        var expected = DayOf(ParseRaw(plan.Changes.First(x => x.Attribute == Attribute).AfterValue), zone);
        var read = DayOf(user.AccountExpires, zone);
        var text = read is DateOnly d ? "expiration relue au " + FrenchText.ShortDate(d) : "aucune expiration relue";
        return read == expected
            ? new WriteVerification(VerificationState.Verified, text + AccountWrites.On(plan.Controller) + c + "valeur conforme au plan.")
            : new WriteVerification(VerificationState.Mismatch, text + AccountWrites.On(plan.Controller) + c + "valeur différente du plan (" + Text(expected) + ").");
    }

    private static long? ParseRaw(string? value) =>
        long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
}
