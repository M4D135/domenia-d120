using System.Collections.Immutable;
using System.Globalization;
using System.Security;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>Save the editable fields of a fiche (FIC-010, FIC-049, FIC-029, FIC-011, FIC-009): « object.update ».</summary>
public interface IObjectUpdateExecutor : IWriteExecutor
{
    /// <summary>Reads the object and drafts the change of the requested fields (null or empty: explicit clear). Never writes.</summary>
    Task<WritePlanDraft> PlanAsync(string dn, IReadOnlyDictionary<string, string?> fields, CancellationToken cancellationToken);
}

/// <summary>Enable or disable a user or computer account (FIC-013): « account.enabled ».</summary>
public interface IAccountEnabledExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, bool enabled, CancellationToken cancellationToken);
}

// Expiry of a user account (FIC-016, « account.expiration »): one contract for Fiche and Comptes since the integration,
// IAccountExpirationExecutor in Writes/Accounts/AccountExpiration.cs (a kind is served by a single executor).

/// <summary>Force a new password at next logon, pwdLastSet = 0 (FIC-017): « password.expire ».</summary>
public interface IPasswordExpireExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>Security options of userAccountControl, changed bits only (FIC-015): « account.options ».</summary>
public interface IAccountOptionsExecutor : IWriteExecutor
{
    /// <summary>Drafts the changed bits; <paramref name="policy"/> says whether a high-risk option asks for the typed name.</summary>
    Task<WritePlanDraft> PlanAsync(string dn, IReadOnlyDictionary<string, bool> options, FicheSecurityPolicy policy, CancellationToken cancellationToken);
}

/// <summary>Raw attribute write under the SE-02 rule (FIC-001): « attribute.raw ».</summary>
public interface IRawAttributeExecutor : IWriteExecutor
{
    /// <summary>Drafts the write under the SE-02 rule of <paramref name="policy"/> (Security.* of Domenia.config.json).</summary>
    Task<WritePlanDraft> PlanAsync(string dn, string attribute, string? value, FicheSecurityPolicy policy, CancellationToken cancellationToken);

    /// <summary>
    /// Keeps the policy a sealed plan was drafted with, until it runs or expires: the executor applies the SE-02 rule again with it
    /// just before sending (Domenia 1 Test-WRawAttributeAllowed, « double check »). A plan without one is refused.
    /// </summary>
    void Remember(string planId, DateTimeOffset expiresAt, FicheSecurityPolicy policy);
}

/// <summary>Move an object to an OU or a container of the domain (FIC-018): « object.move ».</summary>
public interface IObjectMoveExecutor : IWriteExecutor
{
    /// <summary>
    /// Drafts the move; <paramref name="expectedGuid"/> is the GUID captured when the picker opened (FIC-018): an object that
    /// changed meanwhile (another GUID at this DN) is refused instead of moving whatever the DN names now.
    /// </summary>
    Task<WritePlanDraft> PlanAsync(string dn, string targetDn, Guid? expectedGuid, CancellationToken cancellationToken);
}

/// <summary>Add or remove one direct member of one group (FIC-019, FIC-029, FIC-022): « group.member ».</summary>
public interface IGroupMemberExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string groupDn, string memberDn, bool add, CancellationToken cancellationToken);
}

/// <summary>Delete one object, never recursively (FIC-008): « object.delete ».</summary>
public interface IObjectDeleteExecutor : IWriteExecutor
{
    /// <summary>Drafts the deletion under Security.AllowContainerDelete and RequireTypedDeleteConfirmation of <paramref name="policy"/>.</summary>
    Task<WritePlanDraft> PlanAsync(string dn, FicheSecurityPolicy policy, CancellationToken cancellationToken);
}

/// <summary>Create an organizational unit under an OU or a container (FIC-020): « ou.create ».</summary>
public interface IOuCreateExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string parentDn, string name, CancellationToken cancellationToken);
}

/// <summary>
/// Reset the password of a user (FIC-014, FIC-050): « password.reset ». The plan never holds a secret: the new password, typed or
/// generated in the secure window of the host (<see cref="IFichePasswordWindow"/>), is handed as a SecureString for one sealed
/// plan (<see cref="Hold"/>); the executor takes it once, at the execution of that plan, and disposes it. It never reaches the
/// page, a plan, a receipt, a journal nor a command line, and stays a SecureString up to the Windows API.
/// </summary>
public interface IPasswordResetExecutor : IWriteExecutor
{
    /// <summary>Drafts the reset (<paramref name="generated"/>: the password comes from the generator of the window, read once).</summary>
    Task<WritePlanDraft> PlanAsync(string dn, bool mustChange, bool unlock, bool generated, int length, FicheSecurityPolicy policy, CancellationToken cancellationToken);

    /// <summary>Keeps the new password of one sealed plan until it runs or expires; the executor owns (and disposes) it from now on.</summary>
    void Hold(string planId, DateTimeOffset expiresAt, SecureString password);
}

/// <summary>What the secure window asks for (no secret: the target and the rules only).</summary>
public sealed record FichePasswordRequest(string TargetName, string TargetLogin, bool Protected, bool Generate, int GeneratedLength, int ClipboardSeconds, string Theme);

/// <summary>The password given by the operator in the secure window (typed twice, or generated and read once). Owns the SecureString.</summary>
public sealed class FichePasswordEntry(SecureString password, bool generated) : IDisposable
{
    public SecureString Password { get; } = password ?? throw new ArgumentNullException(nameof(password));

    public bool Generated { get; } = generated;

    public void Dispose() => Password.Dispose();
}

/// <summary>
/// Secure window of the host (Domenia 1 PwdUserNew, PwdUserConfirm, BtnUserGenPassword): a native modal window of the application,
/// outside the web page, where the operator types the new password twice (each field can be revealed) or generates one that is
/// shown once to be read. The password exists only as a SecureString; the page receives nothing but the outcome of the plan.
/// Served by Domenia.App (discovered like a screen reader); absent in the tests and in the headless runs.
/// </summary>
public interface IFichePasswordWindow : IScreenReader
{
    /// <summary>Local: asks the operator; null when the window is cancelled or closed. Runs the window on the UI thread.</summary>
    Task<FichePasswordEntry?> AskAsync(FichePasswordRequest request, CancellationToken cancellationToken);
}

/// <summary>
/// Pure rules of the writes of the fiche (Domenia 1 Save-UserProfile, Set-AccountDisabled, Set-UserExpiration,
/// Expire-UserPasswordNow, Apply-UserAccountOptions, Set-OrClearRawAttribute, Move-SelectedObject, AddOrRemoveObjectGroup,
/// Delete-SelectedObject, Create-OuUnderSelected, Reset-UserPassword): one draft per kind, then one generic precondition, one
/// generic application for the simulated overlay and one generic postcondition, all on the attribute bag of the object
/// (<see cref="FicheEntry"/>). Only the changed attributes are written; an empty field is an explicit clear. No clock read.
/// </summary>
public static partial class ObjectWrites
{
    public const string UpdateKind = "object.update";
    public const string EnabledKind = "account.enabled";
    public const string ExpirationKind = "account.expiration";
    public const string ExpirePasswordKind = "password.expire";
    public const string OptionsKind = "account.options";
    public const string RawKind = "attribute.raw";
    public const string MoveKind = "object.move";
    public const string MemberKind = "group.member";
    public const string DeleteKind = "object.delete";
    public const string CreateOuKind = "ou.create";
    public const string ResetPasswordKind = "password.reset";

    public const string DnAttribute = "distinguishedName";
    public const string MemberAttribute = "member";
    public const string OuAttribute = "ou";
    public const string PasswordAttribute = "unicodePwd";

    private static readonly string C = FrenchText.Colon;

    [GeneratedRegex("^[^@\\s]+@[^@\\s]+$", RegexOptions.CultureInvariant)]
    private static partial Regex Upn();

    [GeneratedRegex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", RegexOptions.CultureInvariant)]
    private static partial Regex Mail();

    [GeneratedRegex("^[A-Za-z]:$", RegexOptions.CultureInvariant)]
    private static partial Regex Drive();

    [GeneratedRegex("^[A-Za-z0-9._-]{1,15}$", RegexOptions.CultureInvariant)]
    private static partial Regex NetbiosName();

    /// <summary>The exact target of a plan: kind, label, name, DN, GUID and account.</summary>
    public static WriteTarget Target(FicheEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        var name = entry.Kind is FicheKind.User or FicheKind.Contact ? entry.First("displayName") ?? entry.Name : entry.Name;
        return new WriteTarget(FicheSheets.KindId(entry.Kind), FicheSheets.KindLabel(entry), name, entry.Dn, entry.ObjectGuid.ToString("D"), entry.First("sAMAccountName"));
    }

    /// <summary>The name to type when a plan asks for it: the account for users and groups, the name otherwise.</summary>
    public static string TypedName(FicheEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        return entry.Kind is FicheKind.User or FicheKind.Group ? entry.First("sAMAccountName") ?? entry.Name : entry.Name;
    }

    private static bool IsProtected(FicheEntry entry) => entry.Int32("adminCount") == 1;

    private static bool IsCritical(FicheEntry entry) => string.Equals(entry.First("isCriticalSystemObject"), "TRUE", StringComparison.OrdinalIgnoreCase);

    private static WriteConfirmation Typed(FicheEntry entry, string reason) => new(true, TypedName(entry), "Saisie du nom exigée" + C + reason);

    private static WriteConfirmation Simple(string reason) => new(false, null, "Confirmation simple" + C + reason);

    private static WriteChangeKind KindOf(string? before, string? after) =>
        string.IsNullOrEmpty(after) ? WriteChangeKind.Clear : string.IsNullOrEmpty(before) ? WriteChangeKind.Add : WriteChangeKind.Replace;

    /// <summary>
    /// Draft of the save of the editable fields (Save-UserProfile and its kin): only fields that differ (case sensitive) are
    /// written; a field emptied is an explicit clear. Values are checked (length, UPN, mail, drive, workstations, DN of a known
    /// manager). write.nothingToDo when nothing changed.
    /// </summary>
    public static WritePlanDraft Update(FicheEntry entry, IReadOnlyDictionary<string, string?> fields, IReadOnlyDictionary<string, FicheSummary> names, string? controller)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(fields);
        ArgumentNullException.ThrowIfNull(names);
        if (entry.Kind == FicheKind.Container)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Les conteneurs par défaut ne se modifient pas depuis la fiche" + C + "aucune écriture préparée.");
        }
        var editable = FicheSheets.EditableAttributes(entry.Kind);
        var changes = new List<WriteChange>();
        var risks = new List<WriteRisk>();
        foreach (var (attribute, requested) in fields)
        {
            if (!editable.TryGetValue(attribute, out var max))
            {
                throw FicheErrors.Error(FicheErrors.Invalid, "Champ non modifiable depuis la fiche" + C + attribute + ". Aucune écriture préparée.");
            }
            var canonical = editable.Keys.First(k => string.Equals(k, attribute, StringComparison.OrdinalIgnoreCase));
            var label = FicheSheets.FieldLabel(entry.Kind, canonical);
            var after = string.IsNullOrWhiteSpace(requested) ? null : requested.Trim();
            var before = entry.First(canonical);
            if (string.Equals(before ?? "", after ?? "", StringComparison.Ordinal))
            {
                continue;
            }
            if (after is not null)
            {
                Validate(entry, canonical, label, after, max, names);
            }
            var beforeText = before;
            var afterText = after;
            if (canonical is "manager" or "managedBy")
            {
                beforeText = before is null ? null : names.TryGetValue(before, out var b) ? b.Name : FicheValues.DisplayName(before);
                afterText = after is null ? null : names.TryGetValue(after, out var a) ? a.Name : FicheValues.DisplayName(after);
            }
            changes.Add(new WriteChange(canonical, label, KindOf(before, after), beforeText, afterText, before, after));
            if (canonical == "userPrincipalName")
            {
                risks.Add(new WriteRisk(Tone.Warn, "Le nom de connexion change" + C + "l’utilisateur devra se connecter avec le nouveau, et les applications qui gardent l’ancien le refuseront."));
            }
            else if (canonical == "mail")
            {
                risks.Add(new WriteRisk(Tone.Info, "L’adresse de messagerie annoncée par l’annuaire change ; la boîte aux lettres elle-même n’est pas modifiée."));
            }
            else if (canonical is "homeDirectory" or "profilePath")
            {
                risks.Add(new WriteRisk(Tone.Info, label + C + "le dossier n’est ni créé ni déplacé, seul le chemin enregistré change."));
            }
            else if (canonical == "userWorkstations" && after is not null)
            {
                risks.Add(new WriteRisk(Tone.Warn, "L’ouverture de session sera refusée sur tout poste absent de la liste."));
            }
        }
        if (changes.Count == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucun champ modifié" + C + "aucune écriture à préparer.");
        }
        if (changes.Count > WritePlans.MaxChanges)
        {
            throw FicheErrors.Error(FicheErrors.Invalid, "Trop de champs dans un même enregistrement" + C + "aucune écriture préparée.");
        }
        var target = Target(entry);
        var protectedAccount = IsProtected(entry);
        if (protectedAccount)
        {
            risks.Insert(0, new WriteRisk(Tone.Alert, "Objet protégé (adminCount = 1)" + C + "vérifiez la demande par un autre canal ; la saisie du nom est exigée."));
        }
        var summary = FrenchText.Count(changes.Count, "champ", "champs") + " de " + target.Name + " enregistré" + (changes.Count > 1 ? "s" : "")
            + (controller is null ? "" : " sur " + controller) + " ; seuls les champs modifiés partent.";
        return new WritePlanDraft(UpdateKind, "Enregistrer la fiche", "Enregistrement de la fiche", summary, target, [.. changes], [.. risks],
            protectedAccount ? Typed(entry, "objet protégé.") : Simple("champs d’information, ni droit ni mot de passe modifié."),
            new WriteReversibility(true, "Réversible", "Les valeurs précédentes sont gardées dans le reçu" + C + "un nouveau plan peut les rétablir (jamais automatiquement)."),
            controller);
    }

    private static void Validate(FicheEntry entry, string attribute, string label, string value, int max, IReadOnlyDictionary<string, FicheSummary> names)
    {
        string? problem = null;
        if (value.Length > max)
        {
            problem = "au plus " + FrenchText.Count(max, "caractère", "caractères");
        }
        else if (value.Any(char.IsControl) && attribute is not ("description" or "streetAddress"))
        {
            problem = "caractère de contrôle non admis";
        }
        else
        {
            switch (attribute)
            {
                case "userPrincipalName" when !Upn().IsMatch(value):
                    problem = "forme identifiant@domaine attendue";
                    break;
                case "mail" when !Mail().IsMatch(value):
                    problem = "adresse de messagerie invalide";
                    break;
                case "homeDrive" when !Drive().IsMatch(value):
                    problem = "une lettre suivie de deux-points (H:)";
                    break;
                case "userWorkstations" when value.Split(',', StringSplitOptions.TrimEntries).Any(n => !NetbiosName().IsMatch(n)):
                    problem = "noms NetBIOS de 15 caractères au plus, séparés par des virgules";
                    break;
                case "manager" or "managedBy":
                    if (!names.TryGetValue(value, out var known))
                    {
                        problem = "objet inconnu de l’annuaire ; choisissez-le dans le sélecteur";
                    }
                    else if (attribute == "manager" && known.Kind is not (FicheKind.User or FicheKind.Contact))
                    {
                        problem = "un responsable est un utilisateur ou un contact";
                    }
                    else if (attribute == "managedBy" && known.Kind is not (FicheKind.User or FicheKind.Group or FicheKind.Contact))
                    {
                        problem = "un gestionnaire est un utilisateur, un groupe ou un contact";
                    }
                    else if (FicheValues.SameDn(value, entry.Dn))
                    {
                        problem = "un objet ne peut pas être son propre responsable";
                    }
                    break;
            }
        }
        if (problem is not null)
        {
            throw FicheErrors.Error(FicheErrors.Invalid, label + C + problem + ". Aucune écriture préparée.");
        }
    }

    /// <summary>Draft of the activation or deactivation (Set-AccountDisabled): typed name for a deactivation, protected objects refused.</summary>
    public static WritePlanDraft Enabled(FicheEntry entry, bool enabled, string? controller)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Kind is not (FicheKind.User or FicheKind.Computer))
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Seuls les comptes utilisateur et ordinateur s’activent ou se désactivent" + C + "aucune écriture préparée.");
        }
        var uac = entry.Int32("userAccountControl") ?? throw FicheErrors.Error(FicheErrors.Refused, "userAccountControl non lu" + C + "état du compte inconnu, aucune écriture préparée.");
        var disabled = AdValues.IsDisabled(uac);
        if (disabled != enabled)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, enabled ? "Ce compte est déjà activé" + C + "aucune écriture à préparer." : "Ce compte est déjà désactivé" + C + "aucune écriture à préparer.");
        }
        if (!enabled && (IsCritical(entry) || (entry.Kind == FicheKind.Computer && AdValues.HasFlag(uac, AdValues.ServerTrustAccount))))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Objet système" + C + "jamais désactivé depuis Domenia. Aucune écriture préparée.");
        }
        if (!enabled && IsProtected(entry))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Objet protégé (adminCount = 1)" + C + "désactivation bloquée, comme dans Domenia 1. Aucune écriture préparée.");
        }
        var after = enabled ? uac & ~AdValues.AccountDisabled : uac | AdValues.AccountDisabled;
        var target = Target(entry);
        var risks = new List<WriteRisk>();
        if (!enabled)
        {
            risks.Add(new WriteRisk(Tone.Alert, entry.Kind == FicheKind.Computer
                ? "Le poste perdra sa relation avec le domaine : plus aucune ouverture de session de domaine n’y sera possible."
                : "Le compte ne pourra plus ouvrir de session ni accéder aux ressources du domaine."));
        }
        else if (entry.FileTime("accountExpires") is not null)
        {
            risks.Add(new WriteRisk(Tone.Info, "Le compte reste soumis à son expiration (accountExpires)."));
        }
        var change = new WriteChange("userAccountControl", "État du compte", WriteChangeKind.Replace, disabled ? "Désactivé" : "Activé", enabled ? "Activé" : "Désactivé",
            uac.ToString(CultureInfo.InvariantCulture), after.ToString(CultureInfo.InvariantCulture));
        return new WritePlanDraft(EnabledKind, enabled ? "Activer le compte" : "Désactiver le compte", enabled ? "Activation du compte" : "Désactivation du compte",
            target.Name + (enabled ? " pourra de nouveau ouvrir une session" : " ne pourra plus ouvrir de session") + C + "bit ACCOUNTDISABLE de userAccountControl" + (controller is null ? "." : " sur " + controller + "."),
            target, [change], [.. risks],
            enabled ? Simple("réactivation d’un compte existant.") : Typed(entry, "désactivation (risque élevé)."),
            new WriteReversibility(true, "Réversible", enabled ? "Une désactivation par un nouveau plan rétablit l’état précédent." : "Une activation par un nouveau plan rétablit l’état précédent ; le mot de passe n’est pas modifié."),
            controller);
    }

    /// <summary>Draft of the expiry of an account (Set-UserExpiration): a local day (start of that day) or never (0).</summary>
    public static WritePlanDraft Expiration(FicheEntry entry, DateOnly? day, string? controller, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(zone);
        if (entry.Kind != FicheKind.User)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "L’expiration se fixe sur un compte utilisateur" + C + "aucune écriture préparée.");
        }
        var beforeRaw = entry.First("accountExpires");
        var beforeAt = entry.FileTime("accountExpires");
        var beforeText = beforeAt is DateTimeOffset b ? FicheValues.LocalDate(b, zone) : "Aucune expiration";
        string afterRaw;
        string afterText;
        if (day is DateOnly d)
        {
            var start = LocalDays.StartOf(d, zone);
            afterRaw = AdValues.ToFileTime(start).ToString(CultureInfo.InvariantCulture);
            afterText = FrenchText.ShortDate(d);
        }
        else
        {
            afterRaw = "0";
            afterText = "Aucune expiration";
        }
        var alreadyNever = day is null && beforeAt is null;
        var sameDay = day is DateOnly wanted && beforeAt is DateTimeOffset current && FicheValues.LocalDay(current, zone) == wanted;
        if (alreadyNever || sameDay)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le compte a déjà cette expiration" + C + "aucune écriture à préparer.");
        }
        var target = Target(entry);
        var risks = new List<WriteRisk>();
        if (day is DateOnly chosen && LocalDays.StartOf(chosen, zone) <= now)
        {
            risks.Add(new WriteRisk(Tone.Alert, "Date passée" + C + "le compte sera expiré dès l’écriture et ne pourra plus ouvrir de session."));
        }
        return new WritePlanDraft(ExpirationKind, day is null ? "Supprimer l’expiration du compte" : "Définir l’expiration du compte", "Expiration du compte",
            day is null ? "Le compte " + FrenchText.Quote(target.Name) + " n’expirera plus." : "Le compte " + FrenchText.Quote(target.Name) + " expirera le " + afterText + ".",
            target, [new WriteChange("accountExpires", "Expiration du compte", WriteChangeKind.Replace, beforeText, afterText, beforeRaw, afterRaw)], [.. risks],
            IsProtected(entry) ? Typed(entry, "objet protégé.") : Simple("date d’expiration seulement."),
            new WriteReversibility(true, "Réversible", "Un nouveau plan peut rétablir l’expiration précédente (" + beforeText + ")."), controller);
    }

    /// <summary>Draft of « Expirer le mot de passe » (Expire-UserPasswordNow): pwdLastSet = 0, the current password is not changed.</summary>
    public static WritePlanDraft ExpirePassword(FicheEntry entry, string? controller, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(zone);
        if (entry.Kind != FicheKind.User)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Seul un compte utilisateur doit changer son mot de passe" + C + "aucune écriture préparée.");
        }
        var before = entry.First("pwdLastSet");
        if (entry.Int64("pwdLastSet") == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le mot de passe est déjà à changer à la prochaine ouverture de session" + C + "aucune écriture à préparer.");
        }
        var target = Target(entry);
        var risks = new List<WriteRisk>();
        if (entry.Int32("userAccountControl") is int uac && AdValues.HasFlag(uac, AdValues.DontExpirePassword))
        {
            risks.Add(new WriteRisk(Tone.Warn, "Option « Le mot de passe n’expire jamais » active" + C + "le contrôleur peut ignorer l’obligation tant qu’elle reste cochée."));
        }
        risks.Add(new WriteRisk(Tone.Info, "Le mot de passe actuel reste valable jusqu’à la prochaine ouverture de session ; une session ouverte n’est pas fermée."));
        var beforeText = entry.FileTime("pwdLastSet") is DateTimeOffset set ? "Changé le " + FicheValues.LocalDateTime(set, zone) : "Date non lue";
        return new WritePlanDraft(ExpirePasswordKind, "Imposer un nouveau mot de passe", "Mot de passe à changer",
            target.Name + " devra choisir un nouveau mot de passe à sa prochaine ouverture de session" + C + "pwdLastSet remis à zéro.",
            target, [new WriteChange("pwdLastSet", "Mot de passe", WriteChangeKind.Clear, beforeText, "À changer à la prochaine ouverture de session", before, "0")], [.. risks],
            IsProtected(entry) ? Typed(entry, "compte à privilèges.") : Simple("le mot de passe lui-même n’est pas modifié."),
            new WriteReversibility(false, "Sans retour arrière dans Domenia", "L’obligation disparaît au prochain changement de mot de passe de l’utilisateur."), controller);
    }

    /// <summary>
    /// Draft of the security options (Apply-UserAccountOptions): only the changed bits; turning on a high-risk option asks for the
    /// typed name (RequireTypedHighRiskConfirmation).
    /// </summary>
    public static WritePlanDraft Options(FicheEntry entry, IReadOnlyDictionary<string, bool> options, FicheSecurityPolicy policy, string? controller)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(policy);
        if (entry.Kind != FicheKind.User)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Les options de sécurité se règlent sur un compte utilisateur" + C + "aucune écriture préparée.");
        }
        var uac = entry.Int32("userAccountControl") ?? throw FicheErrors.Error(FicheErrors.Refused, "userAccountControl non lu" + C + "aucune écriture préparée.");
        var after = uac;
        var changed = new List<string>();
        var risks = new List<WriteRisk>();
        var highRisk = false;
        foreach (var (id, on) in options)
        {
            var option = FicheSheets.OptionFlags.FirstOrDefault(o => o.Id == id);
            if (option.Id is null)
            {
                throw FicheErrors.Error(FicheErrors.Invalid, "Option inconnue" + C + "aucune écriture préparée.");
            }
            var current = AdValues.HasFlag(uac, option.Flag);
            if (current == on)
            {
                continue;
            }
            after = on ? after | option.Flag : after & ~option.Flag;
            changed.Add((on ? "+ " : "− ") + option.Label);
            if (on && option.HighRisk)
            {
                highRisk = true;
                risks.Add(new WriteRisk(Tone.Alert, option.Label + C + "option à haut risque pour la sécurité du domaine."));
            }
        }
        if (after == uac)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune option modifiée" + C + "aucune écriture à préparer.");
        }
        var target = Target(entry);
        var typed = (highRisk && policy.RequireTypedHighRiskConfirmation) || IsProtected(entry);
        return new WritePlanDraft(OptionsKind, "Options de sécurité du compte", "Options de sécurité du compte",
            FrenchText.Count(changed.Count, "option changée", "options changées") + " sur " + target.Name + C + string.Join(", ", changed) + ".",
            target, [new WriteChange("userAccountControl", "Options du compte", WriteChangeKind.Replace, FicheAttributeRules.UacFlagsLabel(uac), FicheAttributeRules.UacFlagsLabel(after),
                uac.ToString(CultureInfo.InvariantCulture), after.ToString(CultureInfo.InvariantCulture))], [.. risks],
            typed ? Typed(entry, highRisk ? "option à haut risque." : "compte à privilèges.") : Simple("seuls les bits changés partent."),
            new WriteReversibility(true, "Réversible", "Un nouveau plan rétablit les options précédentes, gardées dans le reçu."), controller);
    }

    /// <summary>Draft of a raw attribute write (Set-OrClearRawAttribute): the SE-02 rule first, then the change; typed name always.</summary>
    public static WritePlanDraft Raw(FicheEntry entry, string attribute, string? value, FicheSecurityPolicy policy, string? controller)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(policy);
        var decision = FicheAttributeRules.RawWriteAllowed(attribute, policy);
        if (!decision.Allowed)
        {
            throw FicheErrors.Error(FicheErrors.Refused, decision.Reason + " Aucune écriture préparée.");
        }
        var name = entry.Attributes.Keys.FirstOrDefault(k => string.Equals(k, decision.Attribute, StringComparison.OrdinalIgnoreCase)) ?? decision.Attribute;
        var values = entry.All(name);
        if (values.Length > 1)
        {
            throw FicheErrors.Error(FicheErrors.Refused, "Attribut à plusieurs valeurs" + C + "l’écriture brute ne remplace qu’une valeur unique. Aucune écriture préparée.");
        }
        var before = values.Length == 1 ? values[0] : null;
        var after = string.IsNullOrEmpty(value) ? null : value;
        if (after is not null && after.Length > 4096)
        {
            throw FicheErrors.Error(FicheErrors.Invalid, "Valeur de plus de 4 096 caractères" + C + "aucune écriture préparée.");
        }
        if (string.Equals(before ?? "", after ?? "", StringComparison.Ordinal))
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "L’attribut a déjà cette valeur" + C + "aucune écriture à préparer.");
        }
        var target = Target(entry);
        return new WritePlanDraft(RawKind, after is null ? "Effacer un attribut" : "Écrire un attribut", "Écriture brute d’attribut",
            (after is null ? "Effacement de " : "Écriture de ") + name + " sur " + target.Name + (controller is null ? "." : " (" + controller + ")."),
            target, [new WriteChange(name, name, KindOf(before, after), before, after, before, after)],
            [new WriteRisk(Tone.Warn, "Écriture brute" + C + "aucun contrôle métier sur la valeur ; la règle de sécurité est revérifiée par le moteur avant l’envoi.")],
            Typed(entry, "écriture brute d’attribut."),
            new WriteReversibility(true, "Réversible", "La valeur précédente est gardée dans le reçu" + C + "un nouveau plan peut la rétablir."), controller);
    }

    /// <summary>
    /// Draft of a move (Move-SelectedObject): target OU or container of the connected domain, identity (DN + GUID) captured now and
    /// checked again before sending; configuration and DNS partitions refused.
    /// </summary>
    public static WritePlanDraft Move(FicheEntry entry, FicheSummary destination, string rootDn, bool nameTaken, string? controller)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(rootDn);
        if (entry.Kind is FicheKind.Ou or FicheKind.Container)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Une branche ne se déplace pas depuis la fiche" + C + "aucune écriture préparée.");
        }
        if (IsCritical(entry))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Objet système" + C + "jamais déplacé depuis Domenia. Aucune écriture préparée.");
        }
        if (destination.Kind is not (FicheKind.Ou or FicheKind.Container) || !IsInDomain(destination.Dn, rootDn) || destination.Dn.Contains("CN=Configuration", StringComparison.OrdinalIgnoreCase)
            || destination.Dn.Contains("DnsZones", StringComparison.OrdinalIgnoreCase))
        {
            throw FicheErrors.Error(FicheErrors.Invalid, "Destination invalide" + C + "une OU ou un conteneur du domaine connecté est attendu. Aucune écriture préparée.");
        }
        var parent = DistinguishedName.Parent(entry.Dn) ?? "";
        if (FicheValues.SameDn(parent, destination.Dn))
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "L’objet est déjà dans cette OU" + C + "aucune écriture à préparer.");
        }
        if (nameTaken)
        {
            throw FicheErrors.Error(FicheErrors.Refused, "Un objet de même nom existe déjà dans " + destination.Name + C + "aucune écriture préparée.");
        }
        var target = Target(entry);
        var risks = new List<WriteRisk>
        {
            new(Tone.Info, "Les stratégies de groupe et les délégations de l’OU de destination s’appliqueront à l’objet."),
        };
        if (entry.Kind == FicheKind.Computer)
        {
            risks.Add(new WriteRisk(Tone.Info, "Le poste prendra les stratégies de sa nouvelle OU à son prochain rafraîchissement."));
        }
        return new WritePlanDraft(MoveKind, "Déplacer l’objet", "Déplacement d’objet",
            target.Name + " sera déplacé vers " + FicheValues.ReadablePath(destination.Dn, includeSelf: true) + " ; son GUID ne change pas.",
            target, [new WriteChange(DnAttribute, "Emplacement", WriteChangeKind.Move, FicheValues.ReadablePath(parent, includeSelf: true), FicheValues.ReadablePath(destination.Dn, includeSelf: true), parent, destination.Dn)],
            [.. risks],
            IsProtected(entry) ? Typed(entry, "objet protégé.") : Simple("le DN et le GUID sont revérifiés avant l’envoi."),
            new WriteReversibility(true, "Réversible", "Un nouveau déplacement vers " + FicheValues.ReadablePath(parent, includeSelf: true) + " rétablit l’emplacement précédent."), controller);
    }

    private static bool IsInDomain(string dn, string rootDn)
    {
        try
        {
            return DistinguishedName.AreEqual(dn, rootDn) || DistinguishedName.IsWithin(dn, rootDn, true);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>
    /// Draft of one membership change (AddOrRemoveObjectGroup, AddOrRemoveGroupMember): one group, one member; protected groups
    /// refused; the removal asks for the typed name (risk « Danger » of Domenia 1).
    /// </summary>
    public static WritePlanDraft Member(FicheEntry group, FicheSummary member, bool add, string rootDn, string? controller)
    {
        ArgumentNullException.ThrowIfNull(group);
        ArgumentNullException.ThrowIfNull(member);
        ArgumentNullException.ThrowIfNull(rootDn);
        if (group.Kind != FicheKind.Group)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "La cible doit être un groupe" + C + "aucune écriture préparée.");
        }
        if (IsProtected(group) || FicheMemberships.IsPrivileged(group.Name, group.First("objectSid"), group.Int32("adminCount")))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Groupe protégé ou à privilèges" + C + "modification bloquée, comme dans Domenia 1. Aucune écriture préparée.");
        }
        if (!IsInDomain(member.Dn, rootDn))
        {
            throw FicheErrors.Error(FicheErrors.Invalid, "Le membre doit appartenir au domaine connecté" + C + "aucune écriture préparée.");
        }
        if (FicheValues.SameDn(member.Dn, group.Dn))
        {
            throw FicheErrors.Error(FicheErrors.Invalid, "Un groupe ne peut pas être membre de lui-même" + C + "aucune écriture préparée.");
        }
        var current = group.All(MemberAttribute).Any(d => FicheValues.SameDn(d, member.Dn));
        if (add == current)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, add ? member.Name + " est déjà membre direct de " + group.Name + C + "aucune écriture à préparer."
                : member.Name + " n’est pas membre direct de " + group.Name + C + "aucune écriture à préparer.");
        }
        var target = Target(group);
        var risks = new List<WriteRisk>();
        if (!add)
        {
            risks.Add(new WriteRisk(Tone.Alert, member.Name + " perdra les accès accordés par ce groupe (et par les groupes qui le contiennent) à sa prochaine ouverture de session."));
        }
        else
        {
            risks.Add(new WriteRisk(Tone.Info, member.Name + " obtiendra les accès de ce groupe à sa prochaine ouverture de session (nouveau jeton)."));
        }
        var typeLabel = FicheMemberships.KindLabel(member.Kind, member.GroupType);
        return new WritePlanDraft(MemberKind, add ? "Ajouter au groupe" : "Retirer du groupe", add ? "Ajout d’un membre" : "Retrait d’un membre",
            (add ? member.Name + " deviendra membre direct de " : member.Name + " ne sera plus membre direct de ") + group.Name + C + "seul ce membre change, jamais la liste complète.",
            target, [new WriteChange(MemberAttribute, "Membre (" + typeLabel + ")", add ? WriteChangeKind.Add : WriteChangeKind.Remove, add ? null : member.Name, add ? member.Name : null,
                add ? null : member.Dn, add ? member.Dn : null)], [.. risks],
            add ? Simple("un membre ajouté, vérifié après l’écriture.") : Typed(group, "retrait d’un membre (risque élevé)."),
            new WriteReversibility(true, "Réversible", add ? "Un retrait par un nouveau plan rétablit la liste précédente." : "Un ajout par un nouveau plan rétablit l’appartenance."), controller);
    }

    /// <summary>
    /// Draft of a deletion (Delete-SelectedObject): never recursive, never the root, OUs and containers refused unless
    /// Security.AllowContainerDelete (with the exact number of children), protected and system objects refused; typed name.
    /// </summary>
    public static WritePlanDraft Delete(FicheEntry entry, int children, FicheSecurityPolicy policy, string? controller, int associations = 0)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(policy);
        if (entry.Kind == FicheKind.Container || entry.Dn.StartsWith("DC=", StringComparison.OrdinalIgnoreCase))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Conteneur par défaut ou racine du domaine" + C + "suppression interdite. Aucune écriture préparée.");
        }
        if (IsCritical(entry))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Objet système" + C + "suppression interdite. Aucune écriture préparée.");
        }
        if (IsProtected(entry))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Objet protégé (adminCount = 1)" + C + "suppression bloquée. Aucune écriture préparée.");
        }
        if (entry.Kind == FicheKind.Ou && !policy.AllowContainerDelete)
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Suppression des OU interdite par la configuration (Security.AllowContainerDelete)" + (children > 0 ? " ; cette OU contient " + FrenchText.Count(children, "objet direct", "objets directs") : "") + ". Aucune écriture préparée.");
        }
        if (children > 0)
        {
            throw FicheErrors.Error(FicheErrors.Refused, "Suppression non récursive" + C + "l’objet contient " + FrenchText.Count(children, "objet enfant", "objets enfants") + ". Aucune écriture préparée.");
        }
        var target = Target(entry);
        var risks = new List<WriteRisk>
        {
            new(Tone.Alert, "Suppression définitive" + C + "l’objet, son SID et ses appartenances disparaissent. Un objet recréé sous le même nom n’hérite d’aucun droit."),
        };
        if (entry.Kind == FicheKind.Group && entry.All(MemberAttribute).Length > 0)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Le groupe a " + FrenchText.Count(entry.All(MemberAttribute).Length, "membre direct", "membres directs") + C + "ils perdront les accès qu’il accordait."));
        }
        if (entry.Kind == FicheKind.User && entry.All("memberOf").Length > 0)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Le compte est membre de " + FrenchText.Count(entry.All("memberOf").Length, "groupe", "groupes") + C + "un compte désactivé puis déplacé dans Départs est souvent préférable."));
        }
        risks.Add(new WriteRisk(Tone.Info, associations > 0
            ? FrenchText.Count(associations, "association locale", "associations locales") + " de l’objet (postes ou comptes associés) " + (associations > 1 ? "seront retirées" : "sera retirée") + " de la base locale après la suppression."
            : "Aucune association locale à retirer de la base après la suppression."));
        risks.Add(new WriteRisk(Tone.Warn, "Deux confirmations" + C + "le mot SUPPRIMER dans la page, puis le nom exact de l’objet avant l’envoi."));
        return new WritePlanDraft(DeleteKind, "Supprimer l’objet", "Suppression d’objet",
            target.Name + " sera supprimé de l’annuaire (non récursif)" + (controller is null ? "." : " sur " + controller + "."),
            target, [new WriteChange(DnAttribute, "Objet", WriteChangeKind.Remove, FicheValues.ReadablePath(entry.Dn, includeSelf: true), null, entry.Dn, null)], [.. risks],
            policy.RequireTypedDeleteConfirmation ? Typed(entry, "suppression définitive.") : Simple("suppression non récursive."),
            new WriteReversibility(false, "Sans retour arrière", "Domenia n’utilise pas la corbeille Active Directory ; une restauration passe par la corbeille ou une sauvegarde de l’annuaire."), controller);
    }

    /// <summary>Draft of the creation of an OU (Create-OuUnderSelected): parent fixed now and checked again at sending, name valid and unique.</summary>
    public static WritePlanDraft CreateOu(FicheEntry parent, string name, bool exists, string? controller)
    {
        ArgumentNullException.ThrowIfNull(parent);
        ArgumentNullException.ThrowIfNull(name);
        if (parent.Kind is not (FicheKind.Ou or FicheKind.Container) || parent.Dn.StartsWith("CN=Builtin", StringComparison.OrdinalIgnoreCase))
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Une OU se crée sous une OU ou un conteneur du domaine" + C + "aucune écriture préparée.");
        }
        var clean = name.Trim();
        if (clean.Length is 0 or > 64 || clean.Any(char.IsControl) || clean.StartsWith('#'))
        {
            throw FicheErrors.Error(FicheErrors.Invalid, "Nom de l’OU" + C + "de 1 à 64 caractères, sans caractère de contrôle ni « # » initial. Aucune écriture préparée.");
        }
        if (exists)
        {
            throw FicheErrors.Error(FicheErrors.Refused, "Une OU " + FrenchText.Quote(clean) + " existe déjà sous " + parent.Name + C + "aucune écriture préparée.");
        }
        var childDn = DistinguishedName.Child("OU", clean, parent.Dn);
        var target = Target(parent);
        return new WritePlanDraft(CreateOuKind, "Créer une unité d’organisation", "Création d’OU",
            "Nouvelle OU " + FrenchText.Quote(clean) + " sous " + FicheValues.ReadablePath(parent.Dn, includeSelf: true) + " ; elle hérite des stratégies et délégations de sa branche.",
            target, [new WriteChange(OuAttribute, "Nouvelle OU", WriteChangeKind.Add, null, FicheValues.ReadablePath(childDn, includeSelf: true), null, childDn)],
            [new WriteRisk(Tone.Info, "La protection contre la suppression accidentelle n’est pas posée par Domenia ; posez-la depuis la console si besoin.")],
            Simple("création d’une branche vide."),
            new WriteReversibility(true, "Réversible sous condition", "Une OU vide peut être supprimée ensuite si la configuration (Security.AllowContainerDelete) l’autorise."), controller);
    }

    /// <summary>
    /// Draft of a password reset (Reset-UserPassword): the new password, typed twice or generated (FIC-050) in the secure window of
    /// the host, is never in the plan; « Changement obligatoire » follows Security.ForcePasswordChangeOnReset by default;
    /// « Déverrouiller ensuite ». A protected account (adminCount = 1) is allowed, as in Domenia 1, with the typed name.
    /// </summary>
    public static WritePlanDraft ResetPassword(FicheEntry entry, bool mustChange, bool unlock, bool generated, int length, FicheSecurityPolicy policy, string? controller)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(policy);
        if (entry.Kind != FicheKind.User)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Seul un compte utilisateur a un mot de passe à réinitialiser ici" + C + "aucune écriture préparée.");
        }
        if (IsCritical(entry))
        {
            throw FicheErrors.Error(FicheErrors.Protected, "Objet système" + C + "jamais réinitialisé depuis Domenia. Aucune écriture préparée.");
        }
        var target = Target(entry);
        var origin = generated
            ? "Mot de passe généré (" + FrenchText.Count(length, "caractère", "caractères") + ", quatre classes) dans la fenêtre sécurisée, lu une fois, ni conservé ni journalisé"
            : "Mot de passe saisi deux fois dans la fenêtre sécurisée (" + FrenchText.Count(length, "caractère", "caractères") + "), ni affiché ni conservé";
        var changes = new List<WriteChange>
        {
            new(PasswordAttribute, "Mot de passe", WriteChangeKind.Reset, "Mot de passe actuel (jamais lu)", origin, null, null),
        };
        if (mustChange)
        {
            changes.Add(new WriteChange("pwdLastSet", "Changement à la prochaine ouverture de session", WriteChangeKind.Clear, null, "Exigé", entry.First("pwdLastSet"), "0"));
        }
        if (unlock && entry.Int64("lockoutTime") is > 0)
        {
            changes.Add(new WriteChange("lockoutTime", "Verrouillage", WriteChangeKind.Clear, "Verrouillé", "Déverrouillé", entry.First("lockoutTime"), "0"));
        }
        return new WritePlanDraft(ResetPasswordKind, "Réinitialiser le mot de passe", "Réinitialisation du mot de passe",
            "Nouveau mot de passe temporaire pour " + target.Name + (mustChange ? ", à changer à la prochaine ouverture de session" : "") + (unlock ? ", compte déverrouillé ensuite" : "") + ".",
            target, [.. changes],
            ResetRisks(entry, mustChange, unlock),
            Typed(entry, IsProtected(entry) ? "compte à privilèges (adminCount = 1)." : "réinitialisation de mot de passe."),
            new WriteReversibility(false, "Sans retour arrière", "L’ancien mot de passe ne peut pas être rétabli."), controller);
    }

    private static ImmutableArray<WriteRisk> ResetRisks(FicheEntry entry, bool mustChange, bool unlock)
    {
        var risks = new List<WriteRisk>
        {
            new(Tone.Warn, "Vérifiez l’identité du demandeur et transmettez le mot de passe par un canal sûr (jamais par courriel en clair)."),
            new(Tone.Info, "Le mot de passe reste une SecureString jusqu’à l’API Windows" + C + "il n’apparaît ni dans la page, ni dans le plan, ni dans le reçu, ni dans le journal."),
        };
        if (IsProtected(entry))
        {
            risks.Insert(0, new WriteRisk(Tone.Alert, "Compte à privilèges (adminCount = 1)" + C + "assurez-vous que la demande vient bien de son titulaire."));
        }
        if (entry.Int64("lockoutTime") is > 0 && !unlock)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Le compte est verrouillé et le restera" + C + "cochez " + FrenchText.Quote("Déverrouiller ensuite") + " pour lever le verrouillage dans la même écriture."));
        }
        if (entry.Int32("userAccountControl") is int uac && AdValues.IsDisabled(uac))
        {
            risks.Add(new WriteRisk(Tone.Warn, "Ce compte est désactivé" + C + "le nouveau mot de passe ne servira qu’après sa réactivation."));
        }
        if (mustChange && entry.Int32("userAccountControl") is int flags && AdValues.HasFlag(flags, AdValues.DontExpirePassword))
        {
            risks.Add(new WriteRisk(Tone.Info, "Le mot de passe de ce compte n’expire jamais" + C + "le changement exigé à la prochaine ouverture de session restera sans effet."));
        }
        return [.. risks];
    }

    /// <summary>Attributes the plan writes as plain values (special changes — move, delete, OU creation, members, password — excepted).</summary>
    public static IReadOnlyDictionary<string, ImmutableArray<string>> PlainChanges(WritePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var result = new Dictionary<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var change in plan.Changes.Where(IsPlain))
        {
            result[change.Attribute] = change.AfterValue is null ? [] : [change.AfterValue];
        }
        return result;
    }

    private static bool IsPlain(WriteChange change) =>
        change.Kind is WriteChangeKind.Replace or WriteChangeKind.Clear or WriteChangeKind.Add
        && change.Attribute is not (MemberAttribute or OuAttribute or DnAttribute or PasswordAttribute);

    /// <summary>
    /// Preconditions read again just before sending (TRV-228, TRV-235): same object (GUID), same place (DN, except the move
    /// itself), same values « before » for every change. A change already in its « after » state is valid and will not be written.
    /// <paramref name="exists"/> tells whether a DN exists (OU creation, move destination).
    /// </summary>
    public static WritePrecheck Check(WritePlan plan, FicheEntry? current, Func<string, bool> exists)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(exists);
        if (current is null)
        {
            return plan.Kind == DeleteKind
                ? WritePrecheck.Valid("Objet relu" + C + "déjà absent de l’annuaire, rien ne sera supprimé.")
                : WritePrecheck.Stale("L’objet n’existe plus dans l’annuaire" + C + "rien n’a été envoyé.");
        }
        if (!string.Equals(current.ObjectGuid.ToString("D"), plan.Target.ObjectGuid, StringComparison.OrdinalIgnoreCase))
        {
            return WritePrecheck.Stale("L’objet relu n’a plus le même GUID" + C + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        var moved = !FicheValues.SameDn(current.Dn, plan.Target.Dn);
        var done = 0;
        foreach (var change in plan.Changes)
        {
            var state = StateOf(change, current, exists);
            if (change.Kind == WriteChangeKind.Move)
            {
                if (state == ChangeState.Done)
                {
                    done++;
                    continue;
                }
                if (moved || state != ChangeState.Before)
                {
                    return WritePrecheck.Stale("L’objet a été déplacé ou renommé depuis le plan" + C + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
                }
                if (change.AfterValue is string destination && !exists(destination))
                {
                    return WritePrecheck.Stale("L’OU de destination n’existe plus" + C + "rien n’a été envoyé.");
                }
                continue;
            }
            if (moved)
            {
                return WritePrecheck.Stale("L’objet a été déplacé ou renommé depuis le plan" + C + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
            }
            switch (state)
            {
                case ChangeState.Done:
                    done++;
                    break;
                case ChangeState.Changed:
                    return WritePrecheck.Stale(change.Label + " a changé depuis le plan" + C + "relisez l’objet puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
            }
        }
        var where = plan.Controller is null ? "" : " sur " + plan.Controller;
        if (done == plan.Changes.Length && plan.Kind != ResetPasswordKind)
        {
            return WritePrecheck.Valid("Objet relu" + where + C + "déjà dans l’état demandé, rien ne sera écrit.");
        }
        return WritePrecheck.Valid("Objet relu" + where + C + "DN et GUID inchangés, valeurs « avant » conformes au plan.");
    }

    private enum ChangeState
    {
        Before,
        Done,
        Changed,
    }

    private static ChangeState StateOf(WriteChange change, FicheEntry current, Func<string, bool> exists)
    {
        switch (change.Attribute)
        {
            case PasswordAttribute when change.Kind == WriteChangeKind.Reset:
                return ChangeState.Before;
            case MemberAttribute:
                var dn = change.AfterValue ?? change.BeforeValue ?? "";
                var present = current.All(MemberAttribute).Any(d => FicheValues.SameDn(d, dn));
                var wanted = change.Kind == WriteChangeKind.Add;
                return present == wanted ? ChangeState.Done : ChangeState.Before;
            case OuAttribute when change.Kind == WriteChangeKind.Add:
                return change.AfterValue is string child && exists(child) ? ChangeState.Changed : ChangeState.Before;
            case DnAttribute when change.Kind == WriteChangeKind.Move:
                var parent = DistinguishedName.Parent(current.Dn);
                return FicheValues.SameDn(parent, change.AfterValue) ? ChangeState.Done : FicheValues.SameDn(parent, change.BeforeValue) ? ChangeState.Before : ChangeState.Changed;
            case DnAttribute when change.Kind == WriteChangeKind.Remove:
                return ChangeState.Before;
        }
        var value = current.All(change.Attribute) is { Length: > 0 } values ? string.Join(";", values) : null;
        if (string.Equals(value ?? "", change.BeforeValue ?? "", StringComparison.Ordinal))
        {
            return string.Equals(value ?? "", change.AfterValue ?? "", StringComparison.Ordinal) ? ChangeState.Done : ChangeState.Before;
        }
        // 0 and « never » are the same expiry.
        if (change.Attribute == "accountExpires" && IsNever(value) && IsNever(change.BeforeValue))
        {
            return IsNever(change.AfterValue) ? ChangeState.Done : ChangeState.Before;
        }
        if (string.Equals(value ?? "", change.AfterValue ?? "", StringComparison.Ordinal))
        {
            return ChangeState.Done;
        }
        return ChangeState.Changed;
    }

    private static bool IsNever(string? value) => string.IsNullOrEmpty(value) || value == "0" || value == AdValues.Never.ToString(CultureInfo.InvariantCulture);

    /// <summary>True when every change of the plan is already in its « after » state (nothing to send).</summary>
    public static bool AlreadyApplied(WritePlan plan, FicheEntry? current, Func<string, bool> exists)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(exists);
        if (plan.Kind == DeleteKind)
        {
            return current is null;
        }
        if (plan.Kind == ResetPasswordKind || current is null)
        {
            return false;
        }
        return plan.Changes.All(change => change.Attribute == OuAttribute
            ? change.AfterValue is string child && exists(child)
            : StateOf(change, current, exists) == ChangeState.Done);
    }

    /// <summary>
    /// Postcondition by re-read (OPE-009): every change observed in its « after » state; the deletion observed as an absence; the
    /// password reset observed through pwdLastSet (the password itself is never read).
    /// </summary>
    public static WriteVerification Verify(WritePlan plan, FicheEntry? current, Func<string, bool> exists)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(exists);
        var where = plan.Controller is null ? "" : " sur " + plan.Controller;
        if (plan.Kind == DeleteKind)
        {
            return current is null
                ? new WriteVerification(VerificationState.Verified, "Objet relu absent" + where + C + "suppression constatée.")
                : new WriteVerification(VerificationState.Mismatch, "L’objet existe encore à la relecture" + where + ".");
        }
        if (current is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Objet introuvable à la relecture" + C + "vérifiez-le dans l’annuaire.");
        }
        var missing = new List<string>();
        foreach (var change in plan.Changes)
        {
            switch (change.Attribute)
            {
                case PasswordAttribute when change.Kind == WriteChangeKind.Reset:
                    break;
                case OuAttribute when change.Kind == WriteChangeKind.Add:
                    if (change.AfterValue is not string child || !exists(child))
                    {
                        missing.Add(change.Label);
                    }
                    break;
                default:
                    if (StateOf(change, current, exists) != ChangeState.Done)
                    {
                        missing.Add(change.Label);
                    }
                    break;
            }
        }
        if (plan.Kind == ResetPasswordKind)
        {
            var before = plan.Changes.FirstOrDefault(c => c.Attribute == "pwdLastSet")?.BeforeValue;
            var changedStamp = current.First("pwdLastSet") is string now && !string.Equals(now, before, StringComparison.Ordinal);
            if (missing.Count == 0 && (changedStamp || plan.Changes.Any(c => c.Attribute == "pwdLastSet")))
            {
                return new WriteVerification(VerificationState.Verified, "pwdLastSet relu" + where + C + "nouveau mot de passe constaté (le mot de passe lui-même n’est jamais relu).");
            }
        }
        if (missing.Count == 0)
        {
            var text = plan.Changes.Length == 1 ? plan.Changes[0].Label + " relu" : FrenchText.Count(plan.Changes.Length, "changement relu", "changements relus");
            return new WriteVerification(VerificationState.Verified, text + where + C + "état attendu constaté.");
        }
        return new WriteVerification(VerificationState.Mismatch, "Écart à la relecture" + where + C + string.Join(", ", missing) + ".");
    }
}

/// <summary>
/// Temporary password (Domenia 1 New-DomeniaTemporaryPassword, FIC-050): 14 to 64 characters from a cryptographic generator,
/// the four classes always present, no ambiguous character (0/O, 1/l/I), shuffled. Returned as a SecureString: it never becomes
/// a managed string, so it never reaches a log, a reply or the page.
/// </summary>
public static class TemporaryPassword
{
    private static readonly string[] Classes = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz", "23456789", "!@#$%^&*()-_=+"];

    public static System.Security.SecureString Generate(int length = 16)
    {
        var size = Math.Clamp(length, 14, 64);
        var alphabet = string.Concat(Classes);
        var chosen = new char[size];
        try
        {
            for (var i = 0; i < Classes.Length; i++)
            {
                chosen[i] = Classes[i][System.Security.Cryptography.RandomNumberGenerator.GetInt32(Classes[i].Length)];
            }
            for (var i = Classes.Length; i < size; i++)
            {
                chosen[i] = alphabet[System.Security.Cryptography.RandomNumberGenerator.GetInt32(alphabet.Length)];
            }
            for (var i = size - 1; i > 0; i--)
            {
                var j = System.Security.Cryptography.RandomNumberGenerator.GetInt32(i + 1);
                (chosen[i], chosen[j]) = (chosen[j], chosen[i]);
            }
            var secure = new System.Security.SecureString();
            foreach (var c in chosen)
            {
                secure.AppendChar(c);
            }
            secure.MakeReadOnly();
            return secure;
        }
        finally
        {
            Array.Clear(chosen);
        }
    }

    /// <summary>Checks the rules on a generated password without exposing it (tests): length, four classes, no ambiguous character.</summary>
    public static bool Complies(System.Security.SecureString password, int expectedLength)
    {
        ArgumentNullException.ThrowIfNull(password);
        if (password.Length != Math.Clamp(expectedLength, 14, 64))
        {
            return false;
        }
        var pointer = System.Runtime.InteropServices.Marshal.SecureStringToGlobalAllocUnicode(password);
        try
        {
            var classes = new bool[4];
            for (var i = 0; i < password.Length; i++)
            {
                var c = (char)System.Runtime.InteropServices.Marshal.ReadInt16(pointer, i * 2);
                if ("0O1lI".Contains(c, StringComparison.Ordinal))
                {
                    return false;
                }
                for (var k = 0; k < Classes.Length; k++)
                {
                    if (Classes[k].Contains(c, StringComparison.Ordinal))
                    {
                        classes[k] = true;
                    }
                }
            }
            return classes.All(x => x);
        }
        finally
        {
            System.Runtime.InteropServices.Marshal.ZeroFreeGlobalAllocUnicode(pointer);
        }
    }
}
