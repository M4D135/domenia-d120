using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Pure rules of the Comptes screen (docs/ops/comptes.md): the row of an account, the counts of a scope, the support band
/// (Domenia 1 FIC-048, Update-DomeniaUserSupportBand), the detail and the availability of each action. Same account state
/// rules as Domenia 1 (Get-DomeniaAccountState, <see cref="AccountState"/>): a lockoutTime alone never proves a lockout. No
/// clock nor culture is read here: « now » and the time zone are inputs.
/// </summary>
public static class AccountsRules
{
    /// <summary>A password expiring within this window is « expiring » (support band of Domenia 1: 14 days).</summary>
    public static readonly TimeSpan ExpiringWindow = TimeSpan.FromDays(14);

    /// <summary>An account expiring within this window is « expiring ».</summary>
    public static readonly TimeSpan AccountExpiringWindow = TimeSpan.FromDays(30);

    /// <summary>No logon for longer than this: inactive (same threshold as the workstations, 90 days).</summary>
    public static readonly TimeSpan StaleAfter = TimeSpan.FromDays(90);

    /// <summary>Most rows of one list read (the grid stays fluid far beyond; a larger OU is said truncated).</summary>
    public const int ListLimit = 5000;

    /// <summary>No user account at this DN (detail, lockouts).</summary>
    public const string UnknownAccount = "accounts.unknown";

    /// <summary>The SID of the account cannot filter the security log: nothing is read.</summary>
    public const string SidInvalid = "accounts.sidInvalid";
    public const string SidInvalidMessage = "SID de compte invalide\u00A0: aucune lecture du journal.";

    /// <summary>Well-known relative identifiers of the domain accounts.</summary>
    public const string AdministratorRid = "-500";
    public const string GuestRid = "-501";
    public const string KrbtgtRid = "-502";

    /// <summary>Lock situation: computed state first, then « to check » for a lone lockoutTime, then an elapsed lockout.</summary>
    public static AccountLock LockOf(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        return state.Lock switch
        {
            LockState.Locked => AccountLock.Locked,
            LockState.ToCheck => AccountLock.ToCheck,
            _ => user.LockoutTime is > 0 ? AccountLock.Expired : AccountLock.Unlocked,
        };
    }

    /// <summary>Password expiry: computed by the controller, else estimated from the domain maximum age (marked estimated).</summary>
    public static (DateTimeOffset? At, bool Estimated) PasswordExpiry(DirectoryUser user, TimeSpan maxPasswordAge)
    {
        ArgumentNullException.ThrowIfNull(user);
        if (user.PasswordLastSet == 0 || AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword) || user.PasswordExpiryComputed == AdValues.Never)
        {
            return (null, false);
        }
        if (AdValues.FromFileTime(user.PasswordExpiryComputed) is DateTimeOffset computed)
        {
            return (computed, false);
        }
        if (user.PasswordExpiryComputed is null && maxPasswordAge > TimeSpan.Zero && AdValues.FromFileTime(user.PasswordLastSet) is DateTimeOffset set)
        {
            return (set + maxPasswordAge, true);
        }
        return (null, false);
    }

    /// <summary>Expiry date of the account (accountExpires), or null when it never expires (0 and the maximum value).</summary>
    public static DateTimeOffset? AccountExpiry(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        return AdValues.FromFileTime(user.AccountExpires);
    }

    /// <summary>True when the SID ends with the given relative identifier (« -500 »).</summary>
    public static bool HasRid(DirectoryUser user, string rid)
    {
        ArgumentNullException.ThrowIfNull(user);
        return user.Sid.EndsWith(rid, StringComparison.Ordinal);
    }

    /// <summary>Readable name of an account: display name, else its CN.</summary>
    public static string NameOf(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        return string.IsNullOrWhiteSpace(user.DisplayName) ? user.Cn : user.DisplayName;
    }

    /// <summary>Name of the container of a DN (« Commercial » for CN=…,OU=Commercial,OU=Lyon,…).</summary>
    public static string ContainerName(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        try
        {
            var names = DistinguishedName.Parse(dn);
            return names.Length >= 2 ? names[1].Value : dn;
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    /// <summary>One row of the list, computed at <paramref name="now"/>.</summary>
    public static AccountsRow Row(DirectoryUser user, DomainInfo domain, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        var maxAge = domain.PasswordPolicy.MaxPasswordAge;
        var lockState = LockOf(user);
        var password = AccountState.ClassifyPassword(user, maxAge, now, ExpiringWindow);
        var (expiresAt, estimated) = PasswordExpiry(user, maxAge);
        var accountExpires = AccountExpiry(user);
        var accountExpired = accountExpires is DateTimeOffset at && at <= now;
        var enabled = !AdValues.IsDisabled(user.UserAccountControl);
        var status = StatusOf(enabled, lockState, accountExpired, password);
        return new AccountsRow(
            user.DistinguishedName,
            user.ObjectGuid.ToString("D"),
            user.SamAccountName,
            NameOf(user),
            user.UserPrincipalName,
            user.Title,
            user.Department,
            user.Office,
            ContainerName(user.DistinguishedName),
            enabled,
            lockState,
            lockState is AccountLock.Unlocked ? null : AdValues.FromFileTime(user.LockoutTime),
            user.BadPasswordCount,
            password,
            AdValues.FromFileTime(user.PasswordLastSet),
            expiresAt,
            estimated,
            accountExpires,
            accountExpired,
            AdValues.FromFileTime(user.LastLogonTimestamp),
            user.AdminCount == 1,
            status,
            StatusLabel(status),
            StatusTone(status));
    }

    /// <summary>Main status, most urgent first: a disabled account cannot sign in whatever else is true.</summary>
    public static AccountStatus StatusOf(bool enabled, AccountLock lockState, bool accountExpired, PasswordClass password)
    {
        if (!enabled)
        {
            return AccountStatus.Disabled;
        }
        if (lockState == AccountLock.Locked)
        {
            return AccountStatus.Locked;
        }
        if (lockState == AccountLock.ToCheck)
        {
            return AccountStatus.LockToCheck;
        }
        if (accountExpired)
        {
            return AccountStatus.AccountExpired;
        }
        return password switch
        {
            PasswordClass.Expired => AccountStatus.PasswordExpired,
            PasswordClass.MustChange => AccountStatus.MustChange,
            PasswordClass.Expiring => AccountStatus.Expiring,
            _ => AccountStatus.Ok,
        };
    }

    public static string StatusLabel(AccountStatus status) => status switch
    {
        AccountStatus.Locked => "Verrouillé",
        AccountStatus.LockToCheck => "Verrouillage à vérifier",
        AccountStatus.Disabled => "Désactivé",
        AccountStatus.AccountExpired => "Compte expiré",
        AccountStatus.PasswordExpired => "Mot de passe expiré",
        AccountStatus.MustChange => "Mot de passe à changer",
        AccountStatus.Expiring => "Expire bientôt",
        _ => "Actif",
    };

    public static Tone StatusTone(AccountStatus status) => status switch
    {
        AccountStatus.Locked or AccountStatus.AccountExpired or AccountStatus.PasswordExpired => Tone.Alert,
        AccountStatus.LockToCheck or AccountStatus.Expiring => Tone.Warn,
        AccountStatus.MustChange => Tone.Info,
        AccountStatus.Disabled => Tone.Off,
        _ => Tone.Ok,
    };

    public static string PasswordLabel(PasswordClass password) => password switch
    {
        PasswordClass.MustChange => "À changer à la prochaine connexion",
        PasswordClass.NeverExpires => "N’expire jamais",
        PasswordClass.Expired => "Expiré",
        PasswordClass.Expiring => "Expire bientôt",
        _ => "Valide",
    };

    /// <summary>Counts of a scope from its rows (exact: the same rules as the rows).</summary>
    public static AccountsCounts Counts(IReadOnlyCollection<AccountsRow> rows, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(rows);
        int enabled = 0, locked = 0, toCheck = 0, lockExpired = 0, expired = 0, expiring = 0, mustChange = 0, never = 0;
        int accountExpired = 0, accountExpiring = 0, privileged = 0, neverLogged = 0, stale = 0;
        foreach (var row in rows)
        {
            if (row.Privileged)
            {
                privileged++;
            }
            if (!row.Enabled)
            {
                continue;
            }
            enabled++;
            switch (row.Lock)
            {
                case AccountLock.Locked: locked++; break;
                case AccountLock.ToCheck: toCheck++; break;
                case AccountLock.Expired: lockExpired++; break;
            }
            switch (row.Password)
            {
                case PasswordClass.Expired: expired++; break;
                case PasswordClass.Expiring: expiring++; break;
                case PasswordClass.MustChange: mustChange++; break;
                case PasswordClass.NeverExpires: never++; break;
            }
            if (row.AccountExpired)
            {
                accountExpired++;
            }
            else if (row.AccountExpiresAt is DateTimeOffset at && at - now <= AccountExpiringWindow)
            {
                accountExpiring++;
            }
            if (row.LastLogon is null)
            {
                neverLogged++;
            }
            else if (now - row.LastLogon.Value > StaleAfter)
            {
                stale++;
            }
        }
        return new AccountsCounts(rows.Count, enabled, rows.Count - enabled, locked, toCheck, lockExpired, expired, expiring, mustChange, never,
            accountExpired, accountExpiring, privileged, neverLogged, stale);
    }

    /// <summary>Domain policy in plain numbers, with a one-line label.</summary>
    public static AccountsPolicy Policy(DomainPasswordPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var maxAge = (int)Math.Round(policy.MaxPasswordAge.TotalDays);
        var lockMinutes = (int)Math.Round(policy.LockoutDuration.TotalMinutes);
        var observe = (int)Math.Round(policy.LockoutObservationWindow.TotalMinutes);
        var parts = new List<string>
        {
            maxAge > 0 ? "Mot de passe valable " + FrenchText.Count(maxAge, "jour", "jours") : "Mot de passe sans durée maximale",
            FrenchText.Count(policy.MinPasswordLength, "caractère", "caractères") + " au moins" + (policy.ComplexityRequired ? ", complexité exigée" : ", sans complexité exigée"),
        };
        parts.Add(policy.LockoutThreshold > 0
            ? "verrouillage après " + FrenchText.Count(policy.LockoutThreshold, "essai erroné", "essais erronés") + (lockMinutes > 0 ? " pendant " + FrenchText.Integer(lockMinutes) + " min" : " jusqu’au déverrouillage")
            : "aucun verrouillage");
        return new AccountsPolicy(maxAge, policy.MinPasswordLength, policy.PasswordHistoryLength, policy.LockoutThreshold, lockMinutes, observe, string.Join(" · ", parts), policy.ComplexityRequired);
    }

    /// <summary>Password block of the detail.</summary>
    public static AccountsPassword PasswordBlock(DirectoryUser user, DomainInfo domain, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        var maxAge = domain.PasswordPolicy.MaxPasswordAge;
        var password = AccountState.ClassifyPassword(user, maxAge, now, ExpiringWindow);
        var (expiresAt, estimated) = PasswordExpiry(user, maxAge);
        var lastSet = AdValues.FromFileTime(user.PasswordLastSet);
        int? age = lastSet is DateTimeOffset set ? Math.Max(0, (int)Math.Floor((now - set).TotalDays)) : null;
        var maxDays = (int)Math.Round(maxAge.TotalDays);
        double? percent = null;
        if (password is not (PasswordClass.NeverExpires or PasswordClass.MustChange) && lastSet is DateTimeOffset from && expiresAt is DateTimeOffset to && to > from)
        {
            percent = Math.Round(Math.Clamp((now - from).TotalSeconds / (to - from).TotalSeconds * 100, 0, 100), 1);
        }
        var tone = password switch
        {
            PasswordClass.Expired => Tone.Alert,
            PasswordClass.Expiring => Tone.Warn,
            PasswordClass.MustChange => Tone.Info,
            PasswordClass.NeverExpires => Tone.Off,
            _ => Tone.Ok,
        };
        return new AccountsPassword(lastSet, expiresAt, estimated, password, PasswordLabel(password), age, maxDays, percent, tone);
    }

    /// <summary>Computed state block (FIC-043).</summary>
    public static AccountsState StateBlock(DirectoryUser user, DomainInfo domain, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        var lockState = LockOf(user);
        var lockedAt = lockState is AccountLock.Unlocked ? null : AdValues.FromFileTime(user.LockoutTime);
        var duration = domain.PasswordPolicy.LockoutDuration;
        DateTimeOffset? endsAt = lockState == AccountLock.Locked && lockedAt is DateTimeOffset at && duration > TimeSpan.Zero ? at + duration : null;
        var accountExpires = AccountExpiry(user);
        return new AccountsState(
            state.Disabled,
            lockState,
            lockedAt,
            endsAt,
            user.BadPasswordCount,
            state.PasswordExpired,
            state.PasswordNeverExpires,
            state.PasswordNotRequired,
            state.SmartCardRequired,
            user.AdminCount == 1,
            accountExpires,
            accountExpires is DateTimeOffset expiry && expiry <= now,
            AdValues.FromFileTime(user.LastLogonTimestamp));
    }

    /// <summary>
    /// Support band (FIC-048): announces only what the controller answered (locked since, state not confirmed, password expired
    /// or expiring within 14 days, bad passwords, recent lockout lifted), with its limits (counter not replicated). Null when
    /// nothing is worth saying.
    /// </summary>
    public static AccountsBand? Band(DirectoryUser user, DomainInfo domain, string? controller, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var where = controller is null ? "le contrôleur" : controller;
        var facts = ImmutableArray.CreateBuilder<AccountsFact>();
        var state = StateBlock(user, domain, now);
        var password = PasswordBlock(user, domain, now);
        var threshold = domain.PasswordPolicy.LockoutThreshold;
        var bad = user.BadPasswordCount ?? 0;
        var badFact = bad > 0
            ? new AccountsFact("Essais erronés", FrenchText.Integer(bad) + (threshold > 0 ? " sur " + FrenchText.Integer(threshold) : ""), bad >= threshold && threshold > 0 ? Tone.Alert : Tone.Warn,
                "Contrôleur " + where, "Compteur propre à ce contrôleur" + c + "il n’est pas répliqué.", null)
            : null;
        Tone tone;
        string title;
        string detail;
        var actions = ImmutableArray.CreateBuilder<string>();
        switch (state.Lock)
        {
            case AccountLock.Locked:
                tone = Tone.Alert;
                title = state.LockedAt is DateTimeOffset at ? "Compte verrouillé depuis " + WritePlans.LocalTime(at, zone, timeOnly: SameDay(at, now, zone)) + " (" + Ago(now - at) + ")" : "Compte verrouillé";
                detail = state.LockEndsAt is DateTimeOffset end
                    ? "Déverrouillage automatique vers " + WritePlans.LocalTime(end, zone, timeOnly: SameDay(end, now, zone)) + " selon la stratégie du domaine, ou tout de suite par un déverrouillage."
                    : "Le compte reste verrouillé jusqu’à un déverrouillage par un administrateur.";
                actions.Add("unlock");
                actions.Add("lockouts");
                break;
            case AccountLock.ToCheck:
                tone = Tone.Warn;
                title = "Verrouillage à vérifier";
                detail = "lockoutTime est renseigné mais le contrôleur n’a pas calculé l’état du compte" + c + "ce n’est pas la preuve d’un verrouillage actuel.";
                actions.Add("lockouts");
                actions.Add("unlock");
                break;
            default:
                tone = Tone.Ok;
                title = "";
                detail = "";
                break;
        }
        if (title.Length == 0)
        {
            if (state.Disabled)
            {
                tone = Tone.Off;
                title = "Compte désactivé";
                detail = "Il ne peut pas ouvrir de session tant qu’il n’est pas réactivé.";
            }
            else if (state.AccountExpired && state.AccountExpiresAt is DateTimeOffset expired)
            {
                tone = Tone.Alert;
                title = "Compte expiré le " + DateText(expired, zone);
                detail = "L’expiration bloque l’ouverture de session sans désactiver le compte" + c + "repoussez ou supprimez la date d’expiration.";
            }
            else if (password.Class == PasswordClass.Expired)
            {
                tone = Tone.Alert;
                title = password.ExpiresAt is DateTimeOffset was ? "Mot de passe expiré depuis le " + DateText(was, zone) : "Mot de passe expiré";
                detail = "L’utilisateur doit le changer à sa prochaine connexion, ou un administrateur le réinitialise.";
                actions.Add("reset");
            }
            else if (password.Class == PasswordClass.MustChange)
            {
                tone = Tone.Info;
                title = "Mot de passe à changer à la prochaine connexion";
                detail = "pwdLastSet vaut 0" + c + "un nouveau mot de passe sera demandé à l’ouverture de session.";
            }
            else if (password.Class == PasswordClass.Expiring && password.ExpiresAt is DateTimeOffset soon)
            {
                tone = Tone.Warn;
                title = "Mot de passe expirant " + InText(soon - now) + " (le " + DateText(soon, zone) + ")";
                detail = password.Estimated ? "Date estimée d’après la stratégie du domaine (" + FrenchText.Count(password.MaxAgeDays, "jour", "jours") + ")." : "Date calculée par le contrôleur.";
                actions.Add("reset");
            }
            else if (state.Lock == AccountLock.Expired && state.LockedAt is DateTimeOffset lifted)
            {
                tone = Tone.Info;
                title = "Verrouillage récent levé";
                detail = "Verrouillé le " + WritePlans.LocalTime(lifted, zone) + c + "la durée de verrouillage est écoulée, lockoutTime reste renseigné.";
                actions.Add("lockouts");
            }
            else if (badFact is not null)
            {
                tone = Tone.Warn;
                title = FrenchText.Count(bad, "essai erroné récent", "essais erronés récents");
                detail = threshold > 0 ? "Le compte se verrouille au " + FrenchText.Integer(threshold) + "e essai erroné dans la fenêtre d’observation." : "Aucun seuil de verrouillage dans la stratégie du domaine.";
                actions.Add("lockouts");
            }
            else
            {
                return null;
            }
        }
        if (badFact is not null)
        {
            facts.Add(badFact);
        }
        if (state.Lock == AccountLock.Locked && state.LockedAt is DateTimeOffset since)
        {
            facts.Add(new AccountsFact("Dernier verrouillage", WritePlans.LocalTime(since, zone), Tone.Alert, "Contrôleur " + where, "Date du dernier verrouillage enregistré.", null));
        }
        if (password.Class is PasswordClass.Expired or PasswordClass.Expiring && password.ExpiresAt is DateTimeOffset pwd && !(title.StartsWith("Mot de passe", StringComparison.Ordinal)))
        {
            facts.Add(new AccountsFact("Mot de passe", (password.Class == PasswordClass.Expired ? "expiré depuis le " : "expire le ") + DateText(pwd, zone), password.Tone, password.Estimated ? "Stratégie du domaine" : "Contrôleur " + where, password.Estimated ? "Date estimée." : null, null));
        }
        if (state.Disabled && title != "Compte désactivé")
        {
            facts.Add(new AccountsFact("Compte", "désactivé", Tone.Off, "Contrôleur " + where, null, null));
        }
        if (state.Privileged)
        {
            facts.Add(new AccountsFact("Compte à privilèges", "adminCount = 1", Tone.Warn, "Contrôleur " + where, "Toute écriture demande la saisie du nom du compte.", null));
        }
        return new AccountsBand(tone, title, detail, facts.ToImmutable(), actions.ToImmutable());
    }

    /// <summary>
    /// Availability of each action with its reason. <paramref name="operatorDn"/> is the DN of the session account: an operator
    /// never disables the account he works with (he would lose his access).
    /// </summary>
    public static AccountsActions Actions(DirectoryUser user, string? operatorDn)
    {
        ArgumentNullException.ThrowIfNull(user);
        var c = FrenchText.Colon;
        var krbtgt = HasRid(user, KrbtgtRid);
        var disabled = AdValues.IsDisabled(user.UserAccountControl);
        var self = operatorDn is not null && SameDn(user.DistinguishedName, operatorDn);
        var system = new AccountsAction(false, "krbtgt est un compte système géré par le domaine" + c + "aucune écriture depuis Domenia.");
        var unlock = user.LockoutTime is > 0 ? new AccountsAction(true, null) : new AccountsAction(false, "Ce compte n’est pas verrouillé.");
        AccountsAction enable;
        AccountsAction disable;
        if (krbtgt)
        {
            enable = system;
            disable = system;
        }
        else
        {
            enable = disabled ? new AccountsAction(true, null) : new AccountsAction(false, "Le compte est déjà activé.");
            disable = !disabled
                ? self ? new AccountsAction(false, "C’est votre compte de session" + c + "le désactiver vous retirerait l’accès à l’annuaire.") : new AccountsAction(true, null)
                : new AccountsAction(false, "Le compte est déjà désactivé.");
        }
        var reset = krbtgt ? system : new AccountsAction(true, null);
        AccountsAction mustChange;
        if (krbtgt)
        {
            mustChange = system;
        }
        else if (AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword))
        {
            mustChange = new AccountsAction(false, "Le mot de passe de ce compte n’expire jamais" + c + "un changement imposé resterait sans effet.");
        }
        else if (user.PasswordLastSet == 0)
        {
            mustChange = new AccountsAction(false, "Le changement est déjà imposé (pwdLastSet = 0).");
        }
        else
        {
            mustChange = new AccountsAction(true, null);
        }
        var expiration = krbtgt ? system : new AccountsAction(true, null);
        var lockouts = IsDomainSid(user.Sid)
            ? new AccountsAction(true, null)
            : new AccountsAction(false, "SID de compte illisible" + c + "le journal ne peut pas être filtré sur ce compte.");
        return new AccountsActions(unlock, enable, disable, reset, mustChange, expiration, lockouts);
    }

    /// <summary>A domain account SID (S-1-5-21 and four sub-authorities): the only filter the security log is read with.</summary>
    public static bool IsDomainSid(string? sid)
    {
        if (string.IsNullOrEmpty(sid) || !sid.StartsWith("S-1-5-21-", StringComparison.Ordinal))
        {
            return false;
        }
        var parts = sid.Split('-');
        return parts.Length == 8 && parts.Skip(3).All(p => p.Length is > 0 and <= 10 && p.All(char.IsAsciiDigit));
    }

    /// <summary>Privileged groups among the memberships (adminCount and well-known administrator groups).</summary>
    public static AccountsGroups Groups(DirectoryUser user, DirectorySnapshot directory)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(directory);
        var privileged = new List<string>();
        foreach (var dn in user.MemberOf)
        {
            var group = directory.Groups.FirstOrDefault(g => string.Equals(g.DistinguishedName, dn, StringComparison.OrdinalIgnoreCase));
            if (group is not null && (group.AdminCount == 1 || group.Sid.EndsWith("-512", StringComparison.Ordinal) || group.Sid.EndsWith("-519", StringComparison.Ordinal)
                || group.Sid.EndsWith("-518", StringComparison.Ordinal) || group.Sid == "S-1-5-32-544"))
            {
                privileged.Add(group.Name);
            }
        }
        privileged.Sort(StringComparer.Ordinal);
        return new AccountsGroups(user.MemberOf.Length, user.PrimaryGroupId, [.. privileged]);
    }

    /// <summary>Full detail of one account.</summary>
    public static AccountsDetail Detail(DirectoryUser user, DirectorySnapshot directory, string? controller, string? operatorDn, DateTimeOffset now, TimeZoneInfo zone, bool simulated)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(zone);
        AccountsLink? manager = null;
        if (user.ManagerDn is string managerDn)
        {
            var found = directory.Users.FirstOrDefault(u => string.Equals(u.DistinguishedName, managerDn, StringComparison.OrdinalIgnoreCase));
            manager = new AccountsLink(managerDn, found is null ? ContainerNameOrSelf(managerDn) : NameOf(found));
        }
        var identity = new AccountsIdentity(user.Cn, user.DisplayName, user.GivenName, user.Surname, user.Mail, user.TelephoneNumber, user.EmployeeId, manager,
            user.Description, user.Sid, user.WhenCreated == DateTimeOffset.MinValue ? null : user.WhenCreated,
            user.WhenChanged == DateTimeOffset.MinValue ? null : user.WhenChanged, user.UsnChanged);
        return new AccountsDetail(
            Row(user, directory.Domain, now),
            identity,
            StateBlock(user, directory.Domain, now),
            PasswordBlock(user, directory.Domain, now),
            Band(user, directory.Domain, controller, now, zone),
            Actions(user, operatorDn),
            Groups(user, directory),
            Policy(directory.Domain.PasswordPolicy),
            controller,
            directory.ReadAt,
            simulated);
    }

    /// <summary>The users of a scope, sorted by name (culture independent), at most <see cref="ListLimit"/>.</summary>
    public static (ImmutableArray<DirectoryUser> Users, bool Truncated) UsersIn(DirectorySnapshot directory, ScopeSelection scope)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(scope);
        var all = directory.Users.Where(u => ScopeRules.Contains(scope, u.DistinguishedName))
            .OrderBy(u => FrenchText.Fold(NameOf(u)), StringComparer.Ordinal)
            .ThenBy(u => u.SamAccountName, StringComparer.OrdinalIgnoreCase)
            .ToList();
        return all.Count > ListLimit ? ([.. all.Take(ListLimit)], true) : ([.. all], false);
    }

    /// <summary>OUs that directly hold user accounts, with their counts (sub-OUs included), largest first, at most 6.</summary>
    public static ImmutableArray<AccountsScopeSuggestion> Suggestions(DirectorySnapshot directory, OrganizationalUnitTree tree)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(tree);
        var parents = directory.Users.Select(u => DistinguishedName.Parent(u.DistinguishedName)).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var tops = new Dictionary<string, OuEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (var parent in parents)
        {
            // The top OU under the domain root that holds this container: « Utilisateurs », « Comptes de service »…
            var entry = TopOu(parent, tree);
            if (entry is not null && entry.Counts.Users > 0)
            {
                tops[entry.Dn] = entry;
            }
        }
        return [.. tops.Values.OrderByDescending(e => e.Counts.Users).ThenBy(e => e.Path, StringComparer.Ordinal).Take(6)
            .Select(e => new AccountsScopeSuggestion(e.Dn, e.Name, e.Path, e.Counts.Users!.Value))];
    }

    private static OuEntry? TopOu(string dn, OrganizationalUnitTree tree)
    {
        OuEntry? top = null;
        var current = dn;
        while (current is not null && !tree.IsRoot(current))
        {
            if (tree.Find(current) is OuEntry entry)
            {
                top = entry;
            }
            current = DistinguishedName.Parent(current);
        }
        return top;
    }

    /// <summary>Local date « 21/10/2026 ».</summary>
    public static string DateText(DateTimeOffset at, TimeZoneInfo zone) => FrenchText.ShortDate(LocalDays.DateOf(at, zone));

    /// <summary>« il y a 14 min », « il y a 3 h », « il y a 2 jours ».</summary>
    public static string Ago(TimeSpan span)
    {
        if (span < TimeSpan.FromMinutes(1))
        {
            return "à l’instant";
        }
        if (span < TimeSpan.FromHours(1))
        {
            return "il y a " + FrenchText.Integer((long)span.TotalMinutes) + " min";
        }
        if (span < TimeSpan.FromDays(1))
        {
            return "il y a " + FrenchText.Integer((long)span.TotalHours) + " h";
        }
        return "il y a " + FrenchText.Count((long)span.TotalDays, "jour", "jours");
    }

    /// <summary>« dans 5 jours », « dans 3 h ».</summary>
    public static string InText(TimeSpan span)
    {
        if (span < TimeSpan.FromHours(1))
        {
            return "dans moins d’une heure";
        }
        if (span < TimeSpan.FromDays(1))
        {
            return "dans " + FrenchText.Integer((long)span.TotalHours) + " h";
        }
        return "dans " + FrenchText.Count((long)Math.Ceiling(span.TotalDays), "jour", "jours");
    }

    private static bool SameDay(DateTimeOffset a, DateTimeOffset b, TimeZoneInfo zone) => LocalDays.DateOf(a, zone) == LocalDays.DateOf(b, zone);

    private static string ContainerNameOrSelf(string dn)
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

    internal static bool SameDn(string left, string right)
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

    /// <summary>Invariant text of a FILETIME (raw value of a plan).</summary>
    public static string Raw(long? value) => (value ?? 0).ToString(CultureInfo.InvariantCulture);
}
