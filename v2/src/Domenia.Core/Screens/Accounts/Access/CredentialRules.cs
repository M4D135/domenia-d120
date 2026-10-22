using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Pure access rules of the Comptes page (Domenia 1 Domenia-Access.Model.ps1, Domenia-Accounts.Model.ps1): account names,
/// context of a proposed account (CPT-003), leases of the temporary accounts (CPT-004), resource labels, refusal wording
/// (Get-DomeniaLoginFailureText) and the verdict of a trial on a workstation (CPT-015). No credential, no secret, no clock
/// read here.
/// </summary>
public static class CredentialRules
{
    /// <summary>Resource keys of Domenia 1 (D051): one account context per resource and target.</summary>
    public const string Directory = "Directory";
    public const string Remote = "Remote";
    public const string Laps = "ReadLaps";
    public const string BitLocker = "ReadBitLocker";
    public const string RemoteLocalPrefix = "RemoteLocal|";
    public const string DirectoryOperationPrefix = "AD:";

    /// <summary>Lease of a temporary account (Security.AlternateCredentialIdleMinutes).</summary>
    public const int DefaultLeaseMinutes = 30;
    public const int MinLeaseMinutes = 1;
    public const int MaxLeaseMinutes = 480;

    /// <summary>Most access requests kept waiting (one per resource and target).</summary>
    public const int PendingLimit = 16;

    /// <summary>Longest account name accepted (DOMAINE\compte or compte@domaine.dns).</summary>
    public const int MaxLoginLength = 260;

    /// <summary>Longest password accepted from the page.</summary>
    public const int MaxPasswordLength = 256;

    /// <summary>Splits a typed account name: DOMAINE\compte, compte@domaine, or a bare name.</summary>
    public static AccountName Parse(string login)
    {
        ArgumentNullException.ThrowIfNull(login);
        var text = login.Trim();
        var slash = text.IndexOf('\\', StringComparison.Ordinal);
        if (slash > 0 && slash < text.Length - 1)
        {
            return new AccountName(AccountNameForm.DownLevel, text[..slash], text[(slash + 1)..]);
        }
        var at = text.LastIndexOf('@');
        if (at > 0 && at < text.Length - 1)
        {
            return new AccountName(AccountNameForm.Upn, text[(at + 1)..], text[..at]);
        }
        return new AccountName(AccountNameForm.Bare, "", text);
    }

    /// <summary>
    /// A well-formed account name: one form, no control character, a name part without « \ » nor « @ ». Never quoted back in
    /// a message.
    /// </summary>
    public static bool IsWellFormed(string? login)
    {
        if (string.IsNullOrWhiteSpace(login) || login.Length > MaxLoginLength || login.Any(char.IsControl))
        {
            return false;
        }
        var name = Parse(login);
        return name.Form != AccountNameForm.Bare && name.Name.Length > 0 && name.Name.Length <= 104
            && !name.Name.Contains('\\', StringComparison.Ordinal) && !name.Name.Contains('@', StringComparison.Ordinal)
            && name.Authority.Length is > 0 and <= 255 && !name.Authority.Contains('\\', StringComparison.Ordinal);
    }

    /// <summary>One key per workstation: first DNS label in lower case (PC-01 and pc-01.example.local are the same); an IP stays whole.</summary>
    public static string MachineKey(string? target)
    {
        var value = (target ?? "").Trim().TrimEnd('.');
        if (value.Length == 0)
        {
            return "";
        }
        if (value.Contains(':', StringComparison.Ordinal) || IsIpv4(value))
        {
            return value.ToLowerInvariant();
        }
        return value.Split('.')[0].ToLowerInvariant();
    }

    /// <summary>A workstation name Domenia accepts as a target (letters, digits, dots, dashes; 253 characters at most).</summary>
    public static bool IsComputerName(string? value) =>
        !string.IsNullOrEmpty(value) && value.Length <= 253 && char.IsAsciiLetterOrDigit(value[0])
        && value.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '.' or '-' or '_');

    /// <summary>A local account of the target workstation: .\compte or POSTE\compte with POSTE = the target.</summary>
    public static bool IsLocalAccount(string login, string? target)
    {
        ArgumentNullException.ThrowIfNull(login);
        var name = Parse(login);
        if (name.Form != AccountNameForm.DownLevel)
        {
            return false;
        }
        if (name.Authority == ".")
        {
            return true;
        }
        var machine = MachineKey(target);
        return machine.Length > 0 && string.Equals(name.Authority, machine, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Context of an account proposed for a resource (CPT-003, Test-DomeniaCredentialContext): a local account only for its own
    /// workstation, never for the directory, LAPS or BitLocker; a down-level account of another workstation or of an unknown
    /// domain is refused before any call. A trusted domain other than the session one is written compte@domaine.
    /// </summary>
    public static CredentialContextCheck CheckContext(string scope, string login, string? target, IReadOnlyCollection<string> knownDomains)
    {
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(knownDomains);
        if (string.IsNullOrWhiteSpace(login))
        {
            return new CredentialContextCheck(false, "Compte absent.");
        }
        var name = Parse(login);
        var machine = MachineKey(target);
        var localForm = name.Form == AccountNameForm.DownLevel && (name.Authority == "." || (machine.Length > 0 && string.Equals(name.Authority, machine, StringComparison.OrdinalIgnoreCase)));
        var remote = scope.StartsWith(Remote, StringComparison.Ordinal);
        if (localForm)
        {
            if (!remote)
            {
                return new CredentialContextCheck(false, "Un compte local ne peut pas lire l’annuaire, LAPS ou BitLocker.");
            }
            if (machine.Length == 0)
            {
                return new CredentialContextCheck(false, "Un compte local exige de désigner le poste cible.");
            }
            return new CredentialContextCheck(true, "");
        }
        if (name.Form == AccountNameForm.Bare)
        {
            return new CredentialContextCheck(false, "Saisissez DOMAINE\\compte ou compte@domaine (ou POSTE\\compte pour un poste).");
        }
        if (name.Form == AccountNameForm.DownLevel && knownDomains.Count > 0)
        {
            var known = knownDomains.Where(d => !string.IsNullOrWhiteSpace(d)).Any(d =>
                string.Equals(name.Authority, d.Trim(), StringComparison.OrdinalIgnoreCase) || string.Equals(name.Authority, d.Trim().Split('.')[0], StringComparison.OrdinalIgnoreCase));
            if (!known)
            {
                return new CredentialContextCheck(false, remote
                    ? "Ce compte appartient à un autre poste ou à un domaine inconnu de cette session. Pour un compte d’un autre domaine approuvé, saisissez compte@domaine."
                    : "Domaine inconnu de cette session. Pour un compte d’un autre domaine approuvé, saisissez compte@domaine.");
            }
        }
        return new CredentialContextCheck(true, "");
    }

    /// <summary>Key of an account for the guard and the aliases: « netbios\nom » in lower case (target workstation for a local account).</summary>
    public static string AccountKey(string login, string? dnsDomain, string? netbios, string? target)
    {
        ArgumentNullException.ThrowIfNull(login);
        var name = Parse(login);
        var authority = name.Authority;
        if (name.Form == AccountNameForm.DownLevel && name.Authority == ".")
        {
            authority = MachineKey(target);
        }
        else if (name.Form == AccountNameForm.Upn && dnsDomain is not null && string.Equals(name.Authority, dnsDomain, StringComparison.OrdinalIgnoreCase) && netbios is not null)
        {
            authority = netbios;
        }
        else if (name.Form == AccountNameForm.DownLevel && dnsDomain is not null && netbios is not null && string.Equals(name.Authority, dnsDomain, StringComparison.OrdinalIgnoreCase))
        {
            authority = netbios;
        }
        return (authority + "\\" + name.Name).ToLowerInvariant();
    }

    /// <summary>Plain name of a resource (Get-DomeniaAccessScopeLabel), never the internal key.</summary>
    public static string ScopeLabel(string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (key.StartsWith(RemoteLocalPrefix, StringComparison.Ordinal))
        {
            return "Poste " + key[RemoteLocalPrefix.Length..] + " (compte local)";
        }
        return key switch
        {
            Remote => "Postes",
            Laps => "Secrets" + FrenchText.Colon + "LAPS",
            BitLocker => "Secrets" + FrenchText.Colon + "BitLocker",
            Directory => "Annuaire",
            "AD:GlobalSearch" => "Annuaire" + FrenchText.Colon + "recherche",
            "AD:UserComputerProbe" => "Annuaire" + FrenchText.Colon + "postes d’un utilisateur",
            "AD:OpenAdObject" => "Annuaire" + FrenchText.Colon + "lecture des fiches",
            "AD:TreeChildren" => "Annuaire" + FrenchText.Colon + "arborescence",
            "Presence" => "Présence des postes",
            "LocalFile" => "Fichiers locaux",
            _ when key.StartsWith(DirectoryOperationPrefix, StringComparison.Ordinal) => "Annuaire" + FrenchText.Colon + "opération " + key[DirectoryOperationPrefix.Length..],
            _ => "Autre ressource",
        };
    }

    /// <summary>A new temporary lease (bounded minutes: 1 to 480).</summary>
    public static CredentialLease NewLease(string scope, string account, LeaseMode mode, int minutes, long epoch, DateTimeOffset now) =>
        new(scope, account, mode, Math.Clamp(minutes, MinLeaseMinutes, MaxLeaseMinutes), epoch, now, now, 0, false);

    /// <summary>Verdict of a lease for a new use (Test-DomeniaCredentialLease): an operation already sent keeps running anyway.</summary>
    public static LeaseCheck CheckLease(CredentialLease? lease, long epoch, DateTimeOffset now)
    {
        if (lease is null)
        {
            return new LeaseCheck(false, "Aucun compte pour cette ressource.");
        }
        if (lease.Forgotten)
        {
            return new LeaseCheck(false, "Compte oublié à la demande de l’opérateur.");
        }
        if (lease.Epoch != epoch)
        {
            return new LeaseCheck(false, "Compte fourni dans une session précédente.");
        }
        if (lease.Mode == LeaseMode.OneShot && lease.Uses >= 1)
        {
            return new LeaseCheck(false, "Compte à usage unique déjà utilisé.");
        }
        if (lease.Mode == LeaseMode.Inactivity && (now - lease.LastUsedAt).TotalMinutes > lease.InactivityMinutes)
        {
            return new LeaseCheck(false, "Compte expiré après " + FrenchText.Integer(lease.InactivityMinutes) + " min sans utilisation.");
        }
        return new LeaseCheck(true, "");
    }

    /// <summary>One use of the lease (a worker leaves with the account): uses + 1, last use now.</summary>
    public static CredentialLease Use(CredentialLease lease, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(lease);
        return lease with { Uses = lease.Uses + 1, LastUsedAt = now };
    }

    /// <summary>Remaining life in words (Get-DomeniaLeaseRemainingText): whole minutes rounded up.</summary>
    public static LeaseRemaining Remaining(CredentialLease? lease, long epoch, DateTimeOffset now)
    {
        if (lease is null)
        {
            return new LeaseRemaining(true, -1, "jusqu’à la fin de la session");
        }
        if (!CheckLease(lease, epoch, now).Usable)
        {
            return new LeaseRemaining(false, 0, "expiré" + FrenchText.Colon + "oublié au prochain contrôle");
        }
        switch (lease.Mode)
        {
            case LeaseMode.OneShot:
                return new LeaseRemaining(true, -1, "une seule utilisation");
            case LeaseMode.Session:
                return new LeaseRemaining(true, -1, "jusqu’à la fin de la session");
        }
        var left = lease.InactivityMinutes - (now - lease.LastUsedAt).TotalMinutes;
        var minutes = Math.Max(1, (int)Math.Ceiling(Math.Max(0, left)));
        return new LeaseRemaining(true, minutes, "encore " + FrenchText.Integer(minutes) + " min sans utilisation");
    }

    /// <summary>
    /// Wording of a refused validation (Get-DomeniaLoginFailureText): a short sentence and the next step; the technical code
    /// stays out of the sentence.
    /// </summary>
    public static (string Message, string Hint) FailureText(string kind)
    {
        const string Change = "Changez-le (Ctrl Alt Suppr, Modifier un mot de passe) puis réessayez.";
        return kind switch
        {
            "unknownAccount" => ("Compte inconnu de l’annuaire.", "Vérifiez l’identifiant et son domaine (DOMAINE\\identifiant ou identifiant@domaine)."),
            "badCredentials" => ("Identifiant ou mot de passe refusé.", "Vérifiez la saisie avant un nouvel essai."),
            "passwordExpired" => ("Mot de passe expiré.", Change),
            "mustChange" => ("Mot de passe à changer avant la connexion.", Change),
            "disabled" => ("Compte désactivé.", "Demandez sa réactivation puis réessayez."),
            "accountExpired" => ("Compte expiré.", "Demandez la prolongation de sa date d’expiration puis réessayez."),
            "locked" => ("Compte verrouillé.", "Demandez son déverrouillage puis réessayez."),
            "unreachable" => ("Contrôleur de domaine injoignable.", "Vérifiez le réseau, le DNS ou le VPN, puis réessayez."),
            "workstationUnreachable" => ("Poste injoignable.", "Vérifiez que le poste est allumé et répond, puis réessayez."),
            "timeout" => ("Délai dépassé pendant la validation.", "Vérifiez le réseau, le DNS ou le VPN, puis réessayez."),
            "cancelled" => ("Validation annulée.", "Aucun compte n’a été changé."),
            "identityMismatch" => ("Identité AD non confirmée.", "L’annuaire n’a pas confirmé une authentification explicite de ce compte dans ce domaine."),
            "input" => ("Informations de connexion incomplètes.", "Complétez les champs demandés."),
            _ => ("Échec de validation du compte.", "Copiez le diagnostic ou ouvrez le journal pour voir l’étape en échec."),
        };
    }

    /// <summary>
    /// What one light CIM read on one workstation proves about the workstation account (Get-DomeniaRemoteAccessTrialVerdict):
    /// only an explicit success says « Accès administrateur OK ».
    /// </summary>
    public static (string Verdict, bool Success, string Text) TrialVerdict(RemoteProbeAnswer answer, string computer, string account)
    {
        ArgumentNullException.ThrowIfNull(answer);
        var target = string.IsNullOrWhiteSpace(computer) ? "ce poste" : computer;
        var who = string.IsNullOrWhiteSpace(account) ? "le compte utilisé pour les postes" : account;
        var c = FrenchText.Colon;
        string verdict;
        if (answer.Outcome == "authRejected" || answer.Category == "credentialsRejected")
        {
            verdict = "rejected";
        }
        else if (answer.Category == "accountState")
        {
            verdict = "accountState";
        }
        else if (answer.Outcome == "denied" || answer.Category == "accessDenied")
        {
            verdict = "denied";
        }
        else if (answer.Outcome == "timeout" || answer.Category is "timeout" or "network")
        {
            verdict = "unreachable";
        }
        else if (string.IsNullOrEmpty(answer.Error) && answer.Outcome == "observed")
        {
            verdict = "adminOk";
        }
        else
        {
            verdict = "unknown";
        }
        var text = verdict switch
        {
            "adminOk" => "Accès administrateur OK sur " + target + " avec " + who + "." + (string.IsNullOrWhiteSpace(answer.Caption) ? "" : " Système" + c + answer.Caption + "."),
            "denied" => "Accès refusé sur " + target + " avec " + who + c + "droit administrateur requis sur ce poste.",
            "rejected" => "Identifiants refusés par " + target + " pour " + who + c + "vérifiez le compte et son mot de passe.",
            "accountState" => "Compte verrouillé, expiré ou restreint (" + who + ")" + c + "vérifiez son état avant un nouvel essai.",
            "unreachable" => "Poste " + target + " injoignable (réseau, nom ou service WMI)" + c + "aucun droit n’a pu être vérifié.",
            _ => "Essai non concluant sur " + target + (string.IsNullOrEmpty(answer.Error) ? "." : c + Shorten(answer.Error, 160)),
        };
        return (verdict, verdict == "adminOk", text);
    }

    /// <summary>Tone of a trial verdict.</summary>
    public static Tone TrialTone(string verdict) => verdict switch
    {
        "adminOk" => Tone.Ok,
        "unreachable" or "unknown" => Tone.Warn,
        _ => Tone.Alert,
    };

    /// <summary>The single place where a paused account is fixed, by origin (point 44 of Domenia 1).</summary>
    public static string FixFor(string origin) => origin switch
    {
        "compte de connexion" => "«\u00A0Corriger le mot de passe\u00A0» dans la carte Annuaire, ou «\u00A0Changer de compte\u00A0»",
        "session Windows" => "corrigez le mot de passe dans Windows, puis «\u00A0Changer de compte\u00A0»",
        "compte Postes de la page Comptes" => "ressaisissez son mot de passe puis «\u00A0Activer\u00A0» dans Comptes secondaires",
        "compte Secrets de la page Comptes" => "ressaisissez son mot de passe puis «\u00A0Activer\u00A0» dans Comptes secondaires",
        "compte temporaire accepté après un refus" => "relancez l’action pour ressaisir son mot de passe, ou «\u00A0Oublier\u00A0» ce compte",
        "compte local temporaire de ce poste" => "relancez l’action pour ressaisir son mot de passe, ou «\u00A0Oublier\u00A0» ce compte",
        _ => "corrigez-le dans cette page ou «\u00A0Changer de compte\u00A0»",
    };

    /// <summary>Resource keys replaced by the activation of a secondary account (D051).</summary>
    public static ImmutableArray<string> ResourcesOf(AccessUsage usage) => usage == AccessUsage.Remote ? [Remote] : [Laps, BitLocker];

    public static string UsageLabel(AccessUsage usage) => usage == AccessUsage.Remote ? "Compte Postes" : "Compte Secrets";

    public static string UsageId(AccessUsage usage) => usage == AccessUsage.Remote ? "remote" : "secrets";

    public static bool TryParseUsage(string? value, out AccessUsage usage)
    {
        switch (value)
        {
            case "remote":
                usage = AccessUsage.Remote;
                return true;
            case "secrets":
                usage = AccessUsage.Secrets;
                return true;
            default:
                usage = AccessUsage.Remote;
                return false;
        }
    }

    public static bool TryParseLease(string? value, out LeaseMode mode)
    {
        switch (value)
        {
            case "inactivity":
                mode = LeaseMode.Inactivity;
                return true;
            case "session":
                mode = LeaseMode.Session;
                return true;
            case "once":
                mode = LeaseMode.OneShot;
                return true;
            default:
                mode = LeaseMode.Inactivity;
                return false;
        }
    }

    /// <summary>Plain label of a refusal kind of an access request.</summary>
    public static string KindLabel(string kind) => kind switch
    {
        "accessDenied" => "Accès refusé",
        "logonFailure" => "Identifiants refusés",
        "unconfirmed" => "Aucune valeur visible, publication ou droits à vérifier",
        _ => "Refus",
    };

    private static bool IsIpv4(string value)
    {
        var parts = value.Split('.');
        return parts.Length == 4 && parts.All(p => p.Length is > 0 and <= 3 && p.All(char.IsAsciiDigit));
    }

    private static string Shorten(string text, int max) => text.Length <= max ? text : text[..max] + "…";
}
