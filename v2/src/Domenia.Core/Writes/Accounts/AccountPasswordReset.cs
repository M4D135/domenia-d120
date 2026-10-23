using System.Collections.Immutable;
using System.Globalization;
using System.Security;

namespace Domenia.Core;

/// <summary>Options of a password reset chosen by the operator (Domenia 1 FIC-014: ChkMustChangeAtLogon, ChkUnlockAfterReset).</summary>
public sealed record PasswordResetOptions(bool MustChange, bool Unlock);

/// <summary>
/// Executor of the password reset of a user account (Domenia 1 FIC-014, Reset-UserPassword). The new password never enters a
/// plan, a receipt or a journal: the module hands it as a <see cref="SecureString"/> for one sealed plan
/// (<see cref="Hold"/>), the executor takes it once, at the execution of that plan, and disposes it; the Active Directory
/// executor (wave 3) keeps it as a SecureString up to the Windows API.
/// </summary>
public interface IAccountPasswordResetExecutor : IWriteExecutor
{
    /// <summary>
    /// Reads the account, checks the typed password against the domain policy (accounts.passwordPolicy, the password is never
    /// quoted) and drafts the reset. Errors: write.targetUnknown, accounts.protectedAccount, accounts.passwordPolicy.
    /// </summary>
    Task<WritePlanDraft> PlanAsync(string dn, PasswordResetOptions options, SecureString password, CancellationToken cancellationToken);

    /// <summary>Keeps the new password of one sealed plan until it runs or expires; the executor owns it from now on.</summary>
    void Hold(string planId, DateTimeOffset expiresAt, SecureString password);
}

/// <summary>One rule of the password policy and whether the typed password meets it (the password itself is never returned).</summary>
public sealed record PasswordRuleCheck(string Id, string Label, bool Met);

/// <summary>
/// Rules of the password reset (pure). Changes: unicodePwd « reset » (no value in the plan: « nouvelle valeur saisie, ni
/// affichée ni conservée »), pwdLastSet (always in the plan with its raw value before: to 0 when the change is required at the
/// next logon, otherwise set by the controller at the write), lockoutTime to 0 when « unlock after » is chosen and the account
/// is locked. Never reversible: the former password is never kept. The policy check follows the domain: minimum length, three
/// character classes only when pwdProperties asks for complexity; the controller still decides (history, custom filters).
/// </summary>
public static class AccountPasswordReset
{
    public const string Kind = "account.resetPassword";
    public const string Title = "Réinitialiser le mot de passe";
    public const string Label = "Réinitialisation du mot de passe";

    public const string PasswordAttribute = "unicodePwd";
    public const string LastSetAttribute = "pwdLastSet";
    public const string LockoutAttribute = "lockoutTime";

    /// <summary>Longest password accepted (Active Directory accepts 256 characters).</summary>
    public const int MaxLength = 256;

    private static readonly char[] NameDelimiters = [',', '.', '-', '_', ' ', '#', '\t', '\''];

    /// <summary>Refusal of a password that does not meet the policy (nothing prepared, the password is never quoted).</summary>
    public const string PolicyRefused = "accounts.passwordPolicy";

    /// <summary>Refusal of the execution when the password of the plan is no longer in memory.</summary>
    public const string SecretGoneMessage = "Le nouveau mot de passe n’est plus en mémoire (plan expiré ou Domenia relancé)\u00A0: préparez de nouveau la réinitialisation. Rien n’a été envoyé.";

    /// <summary>Draft of the reset of <paramref name="user"/> with <paramref name="options"/>.</summary>
    public static WritePlanDraft Draft(DirectoryUser user, PasswordResetOptions options, DomainInfo domain, string? controller, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        AccountWrites.EnsureNotSystem(user);
        var name = AccountsRules.NameOf(user);
        var lockState = AccountsRules.LockOf(user);
        var unlock = options.Unlock && user.LockoutTime is > 0;
        var lastSet = user.PasswordLastSet ?? 0;
        var changes = ImmutableArray.CreateBuilder<WriteChange>();
        changes.Add(new WriteChange(PasswordAttribute, "Mot de passe", WriteChangeKind.Reset, "Mot de passe actuel (jamais lu)", "Nouvelle valeur saisie, ni affichée ni conservée", null, null));
        // pwdLastSet is always in the plan with its raw value before (Domenia 1 PreviousUtc): the precondition and the re-read
        // compare the controller with the controller, never with the clock of this workstation.
        var lastSetBefore = lastSet == 0 ? "Déjà à changer (0)" : AdValues.FromFileTime(lastSet) is DateTimeOffset set ? "Changé le " + WritePlans.LocalTime(set, zone) : "Inconnu";
        changes.Add(options.MustChange
            ? new WriteChange(LastSetAttribute, "Changement à la prochaine connexion", WriteChangeKind.Replace, lastSetBefore, "Exigé (pwdLastSet = 0)", AccountWrites.Raw(lastSet), "0")
            : new WriteChange(LastSetAttribute, "Date du dernier changement", WriteChangeKind.Replace, lastSetBefore, "Date de l’écriture, posée par le contrôleur", AccountWrites.Raw(lastSet), null));
        if (unlock)
        {
            var lockedAt = AdValues.FromFileTime(user.LockoutTime);
            var before = lockState == AccountLock.Locked && lockedAt is DateTimeOffset at ? "Verrouillé depuis le " + WritePlans.LocalTime(at, zone) : "Verrouillage enregistré (lockoutTime renseigné)";
            changes.Add(new WriteChange(LockoutAttribute, "Verrouillage", WriteChangeKind.Clear, before, "Déverrouillé", AccountWrites.Raw(user.LockoutTime ?? 0), "0"));
        }
        var risks = new List<WriteRisk>();
        AccountWrites.AddPrivilegedRisk(user, risks);
        risks.Add(new WriteRisk(Tone.Warn, "Vérifiez l’identité du demandeur et transmettez le mot de passe par un canal sûr (jamais par courriel en clair)."));
        if (lockState == AccountLock.Locked && !unlock)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Le compte est verrouillé et le restera" + c + "cochez «\u00A0Déverrouiller ensuite\u00A0» pour lever le verrouillage dans la même écriture."));
        }
        if (AdValues.IsDisabled(user.UserAccountControl))
        {
            risks.Add(new WriteRisk(Tone.Warn, "Ce compte est désactivé" + c + "le nouveau mot de passe ne servira qu’après sa réactivation."));
        }
        if (options.MustChange && AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword))
        {
            risks.Add(new WriteRisk(Tone.Info, "Le mot de passe de ce compte n’expire jamais" + c + "le changement exigé à la prochaine connexion restera sans effet."));
        }
        if (!options.MustChange)
        {
            risks.Add(new WriteRisk(Tone.Info, "Aucun changement exigé" + c + "l’utilisateur gardera ce mot de passe jusqu’à son expiration (" + FrenchText.Count((long)Math.Round(domain.PasswordPolicy.MaxPasswordAge.TotalDays), "jour", "jours") + ")."));
        }
        if (AdValues.HasFlag(user.UserAccountControl, AdValues.SmartCardRequired))
        {
            risks.Add(new WriteRisk(Tone.Info, "Carte à puce exigée pour l’ouverture de session" + c + "le mot de passe ne sert qu’aux accès qui l’acceptent encore."));
        }
        if (domain.PasswordPolicy.PasswordHistoryLength > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, "Le contrôleur vérifie l’historique (" + FrenchText.Count(domain.PasswordPolicy.PasswordHistoryLength, "mot de passe", "mots de passe") + ")" + c + "il peut refuser la valeur, rien ne sera alors modifié."));
        }
        var extra = new List<string>();
        if (options.MustChange)
        {
            extra.Add("changement exigé à la prochaine connexion");
        }
        if (unlock)
        {
            extra.Add("compte déverrouillé");
        }
        var summary = "Le mot de passe de " + name + " sera remplacé par la valeur saisie" + AccountWrites.On(controller) + (extra.Count > 0 ? " (" + string.Join(", ", extra) + ")" : "") + ".";
        return new WritePlanDraft(
            Kind,
            Title,
            Label,
            summary,
            AccountWrites.Target(user),
            changes.ToImmutable(),
            [.. risks],
            AccountWrites.Confirmation(user, "Confirmation simple" + c + "compte standard ; le mot de passe saisi n’apparaît nulle part."),
            new WriteReversibility(false, "Sans retour arrière", "L’ancien mot de passe n’est jamais lu ni conservé" + c + "il ne peut pas être rétabli."),
            controller);
    }

    /// <summary>True when the plan requires the change at the next logon (pwdLastSet written to 0).</summary>
    public static bool RequiresChange(WritePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return plan.Changes.Any(change => change.Attribute == LastSetAttribute && change.AfterValue == "0");
    }

    /// <summary>
    /// Preconditions: same object, pwdLastSet unchanged since the plan for every reset (somebody changed the password meanwhile
    /// otherwise), and the password of the plan still in memory.
    /// </summary>
    public static WritePrecheck Check(WritePlan plan, DirectoryUser? user, bool secretHeld)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var c = FrenchText.Colon;
        if (AccountWrites.CheckIdentity(plan, user) is WritePrecheck stale)
        {
            return stale;
        }
        if (!secretHeld)
        {
            return WritePrecheck.Stale(SecretGoneMessage);
        }
        if (AccountWrites.PlannedBefore(plan, LastSetAttribute) is string planned
            && !string.Equals(AccountWrites.Raw(user!.PasswordLastSet ?? 0), planned, StringComparison.Ordinal))
        {
            return WritePrecheck.Stale("Le mot de passe a été changé depuis le plan" + c + "relisez le compte puis préparez de nouveau la réinitialisation. Rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Compte relu" + AccountWrites.On(plan.Controller) + c + "DN et GUID inchangés, mot de passe saisi en mémoire protégée.");
    }

    /// <summary>The account after the reset (simulation): password dates of the controller, flags cleared as AD does.</summary>
    public static DirectoryUser Apply(DirectoryUser user, WritePlan plan, TimeSpan maxPasswordAge, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(plan);
        var mustChange = RequiresChange(plan);
        var unlock = AccountWrites.Changes(plan, LockoutAttribute);
        long? expiry = mustChange ? 0
            : AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword) || maxPasswordAge <= TimeSpan.Zero ? AdValues.Never
            : AdValues.ToFileTime(now + maxPasswordAge);
        var computed = user.ComputedAccountControl is int value ? value & ~AdValues.PasswordExpired : (int?)null;
        if (unlock && computed is int locked)
        {
            computed = locked & ~AdValues.LockedOut;
        }
        return user with
        {
            PasswordLastSet = mustChange ? 0 : AdValues.ToFileTime(now),
            PasswordExpiryComputed = expiry,
            ComputedAccountControl = computed,
            LockoutTime = unlock ? 0 : user.LockoutTime,
            BadPasswordCount = unlock && user.BadPasswordCount is not null ? 0 : user.BadPasswordCount,
            WhenChanged = now,
            UsnChanged = usn,
        };
    }

    /// <summary>
    /// Postcondition (OPE-009): pwdLastSet read again (0 when the change is required, otherwise later than its raw value before,
    /// as the controller wrote it: no clock of this workstation involved), and lockoutTime 0 when the unlock was asked.
    /// </summary>
    public static WriteVerification Verify(DirectoryUser? user, WritePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var c = FrenchText.Colon;
        var where = AccountWrites.On(plan.Controller);
        if (user is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Compte introuvable à la relecture" + c + "vérifiez-le dans l’annuaire.");
        }
        var mustChange = RequiresChange(plan);
        var unlock = AccountWrites.Changes(plan, LockoutAttribute);
        var lastSet = user.PasswordLastSet ?? 0;
        bool passwordOk;
        string passwordText;
        if (mustChange)
        {
            passwordOk = lastSet == 0;
            passwordText = "pwdLastSet = " + AccountWrites.Raw(lastSet) + (passwordOk ? " (changement exigé)" : "");
        }
        else
        {
            var before = long.TryParse(AccountWrites.PlannedBefore(plan, LastSetAttribute), NumberStyles.Integer, CultureInfo.InvariantCulture, out var raw) ? raw : (long?)null;
            var set = AdValues.FromFileTime(lastSet);
            passwordOk = before is long previous && lastSet > previous && set is not null;
            passwordText = set is DateTimeOffset changedAt ? "mot de passe changé le " + changedAt.UtcDateTime.ToString("dd'/'MM'/'yyyy HH':'mm':'ss", CultureInfo.InvariantCulture) + " UTC" : "pwdLastSet illisible";
        }
        var unlockOk = !unlock || user.LockoutTime is null or 0;
        if (passwordOk && unlockOk)
        {
            return new WriteVerification(VerificationState.Verified, passwordText + " relu" + where + (unlock ? ", lockoutTime = 0" : "") + c + "réinitialisation confirmée.");
        }
        return new WriteVerification(VerificationState.Mismatch,
            (passwordOk ? "" : "Le mot de passe ne paraît pas changé (" + passwordText + ")") + (passwordOk || unlockOk ? "" : " ; ") + (unlockOk ? "" : "le compte est encore verrouillé") + " à la relecture" + where + ".");
    }

    /// <summary>
    /// Policy check of a typed password: minimum length of the domain; when the domain asks for complexity (pwdProperties), three
    /// character classes out of four and no account name nor part of the display name of three characters or more. Never
    /// returns the password. Without complexity the controller alone decides beyond the length.
    /// </summary>
    public static ImmutableArray<PasswordRuleCheck> CheckPolicy(ReadOnlySpan<char> password, DirectoryUser user, int minLength, bool complexity = true)
    {
        ArgumentNullException.ThrowIfNull(user);
        var upper = false;
        var lower = false;
        var digit = false;
        var other = false;
        foreach (var ch in password)
        {
            if (char.IsUpper(ch))
            {
                upper = true;
            }
            else if (char.IsLower(ch))
            {
                lower = true;
            }
            else if (char.IsDigit(ch))
            {
                digit = true;
            }
            else
            {
                other = true;
            }
        }
        var classes = (upper ? 1 : 0) + (lower ? 1 : 0) + (digit ? 1 : 0) + (other ? 1 : 0);
        var min = Math.Max(1, minLength);
        var rules = ImmutableArray.CreateBuilder<PasswordRuleCheck>();
        rules.Add(new PasswordRuleCheck("length", FrenchText.Count(min, "caractère", "caractères") + " au moins", password.Length >= min && password.Length <= MaxLength));
        if (complexity)
        {
            rules.Add(new PasswordRuleCheck("classes", "Trois types parmi majuscules, minuscules, chiffres et symboles", classes >= 3));
            rules.Add(new PasswordRuleCheck("name", "Ni le nom du compte ni une partie du nom affiché", !ContainsName(password, user)));
        }
        return rules.ToImmutable();
    }

    /// <summary>
    /// Refuses a password that does not meet the policy (accounts.passwordPolicy): the message lists the unmet rules, never the
    /// password. The characters are copied out of the SecureString into a buffer cleared at once.
    /// </summary>
    public static void EnsurePolicy(SecureString password, DirectoryUser user, DomainInfo domain)
    {
        ArgumentNullException.ThrowIfNull(password);
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        var checks = PasswordSecrets.Inspect(password, chars => CheckPolicy(chars, user, domain.PasswordPolicy.MinPasswordLength, domain.PasswordPolicy.ComplexityRequired));
        var unmet = checks.Where(r => !r.Met).Select(r => r.Label).ToList();
        if (unmet.Count > 0)
        {
            throw WriteErrors.Refusal(PolicyRefused, "Mot de passe refusé par la stratégie du domaine" + FrenchText.Colon + string.Join("\u00A0; ", unmet).ToLowerInvariant() + ". Aucune écriture préparée.");
        }
    }

    /// <summary>True when the password holds the sAMAccountName (3 characters or more) or a token of 3+ characters of the display name.</summary>
    public static bool ContainsName(ReadOnlySpan<char> password, DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        if (user.SamAccountName.Length >= 3 && password.Contains(user.SamAccountName.AsSpan(), StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        var display = user.DisplayName ?? user.Cn;
        foreach (var token in display.Split(NameDelimiters, StringSplitOptions.RemoveEmptyEntries))
        {
            if (token.Length >= 3 && password.Contains(token.AsSpan(), StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }
}

/// <summary>
/// New passwords held for their sealed plan only (one entry per plan, five minutes at most): taken once by the execution,
/// disposed when taken, when replaced or when their plan expires. A timer of the clock disposes an expired entry at its
/// expiry, even when nothing asks for it any more. Never enumerated, never logged. Thread safe.
/// </summary>
public sealed class PasswordSecrets : IDisposable
{
    private readonly Lock gate = new();
    private readonly Dictionary<string, (DateTimeOffset ExpiresAt, SecureString Secret)> held = new(StringComparer.Ordinal);
    private readonly TimeProvider clock;
    private readonly ITimer timer;
    private bool disposed;

    public PasswordSecrets(TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        this.clock = clock;
        timer = clock.CreateTimer(static state => ((PasswordSecrets)state!).OnTimer(), this, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Number of passwords held (tests).</summary>
    public int Count
    {
        get
        {
            lock (gate)
            {
                Purge(clock.GetUtcNow());
                return held.Count;
            }
        }
    }

    /// <summary>Keeps the password of a plan; the store owns it (a read-only copy is made, the caller disposes its own).</summary>
    public void Hold(string planId, DateTimeOffset expiresAt, SecureString password)
    {
        ArgumentException.ThrowIfNullOrEmpty(planId);
        ArgumentNullException.ThrowIfNull(password);
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var now = clock.GetUtcNow();
            Purge(now);
            if (expiresAt <= now) { return; }
            if (held.Count >= 64 && !held.ContainsKey(planId))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Trop de mots de passe préparés ; laissez expirer les anciens plans."); }
            var copy = password.Copy();
            copy.MakeReadOnly();
            if (held.Remove(planId, out var previous)) { previous.Secret.Dispose(); }
            var maximum = now + WritePlans.Lifetime;
            held[planId] = (expiresAt < maximum ? expiresAt : maximum, copy);
            ScheduleLocked(now);
        }
    }

    /// <summary>Disposes the password of a plan now (plan refused or replaced before its execution); false when none was held.</summary>
    public bool Drop(string planId)
    {
        lock (gate)
        {
            if (!held.Remove(planId, out var gone))
            {
                return false;
            }
            gone.Secret.Dispose();
            ScheduleLocked(clock.GetUtcNow());
            return true;
        }
    }

    /// <summary>True while the password of the plan is held and its plan not expired.</summary>
    public bool Contains(string planId)
    {
        lock (gate)
        {
            Purge(clock.GetUtcNow());
            return held.ContainsKey(planId);
        }
    }

    /// <summary>Takes the password of a plan (once); the caller disposes it after use. Null when gone.</summary>
    public SecureString? Take(string planId)
    {
        lock (gate)
        {
            Purge(clock.GetUtcNow());
            return held.Remove(planId, out var entry) ? entry.Secret : null;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            foreach (var entry in held.Values)
            {
                entry.Secret.Dispose();
            }
            held.Clear();
        }
        timer.Dispose();
    }

    private void OnTimer()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            var now = clock.GetUtcNow();
            Purge(now);
            ScheduleLocked(now);
        }
    }

    /// <summary>Arms the timer for the earliest expiry (stopped when nothing is held).</summary>
    private void ScheduleLocked(DateTimeOffset now)
    {
        if (disposed)
        {
            return;
        }
        if (held.Count == 0)
        {
            timer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            return;
        }
        var next = held.Values.Min(e => e.ExpiresAt) - now;
        timer.Change(next < TimeSpan.Zero ? TimeSpan.Zero : next + TimeSpan.FromMilliseconds(50), Timeout.InfiniteTimeSpan);
    }

    private void Purge(DateTimeOffset now)
    {
        foreach (var id in held.Where(p => p.Value.ExpiresAt <= now).Select(p => p.Key).ToList())
        {
            if (held.Remove(id, out var gone))
            {
                gone.Secret.Dispose();
            }
        }
    }

    /// <summary>
    /// Runs <paramref name="reader"/> over the characters of a SecureString: copied into a buffer of the managed heap for the
    /// call only, then cleared; the unmanaged copy is zeroed and freed. Never returns or logs the characters.
    /// </summary>
    public static T Inspect<T>(SecureString secret, SecretReader<T> reader)
    {
        ArgumentNullException.ThrowIfNull(secret);
        ArgumentNullException.ThrowIfNull(reader);
        var length = secret.Length;
        var buffer = new char[length];
        var pointer = System.Runtime.InteropServices.Marshal.SecureStringToGlobalAllocUnicode(secret);
        try
        {
            System.Runtime.InteropServices.Marshal.Copy(pointer, buffer, 0, length);
            return reader(buffer);
        }
        finally
        {
            Array.Clear(buffer);
            System.Runtime.InteropServices.Marshal.ZeroFreeGlobalAllocUnicode(pointer);
        }
    }

    /// <summary>A read-only secure copy of a text received from the page; the caller drops its reference to the text at once.</summary>
    public static SecureString FromText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var secure = new SecureString();
        foreach (var ch in text)
        {
            secure.AppendChar(ch);
        }
        secure.MakeReadOnly();
        return secure;
    }
}

/// <summary>Reads the characters of a secret for the duration of one call (<see cref="PasswordSecrets.Inspect"/>).</summary>
public delegate T SecretReader<out T>(ReadOnlySpan<char> characters);
