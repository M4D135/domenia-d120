using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>Answer of the raw attribute rule: allowed, or why not (Domenia 1 Test-DomeniaRawAttributeAllowed).</summary>
public sealed record RawAttributeDecision(bool Allowed, string Attribute, string Reason);

/// <summary>One row of the raw attributes grid (Domenia 1 Entry-ToRawAttributes, FIC-002, with the syntax of each value).</summary>
public sealed record FicheRawAttribute(
    string Name,
    ImmutableArray<string> Values,
    string Display,
    string Syntax,
    bool Multi,
    bool Writable,
    string? Blocked);

/// <summary>Result of fiche.attributes.</summary>
public sealed record FicheRawAttributes(
    string Dn,
    int Total,
    int Sensitive,
    ImmutableArray<FicheRawAttribute> Rows,
    FicheRawWrite RawWrite,
    string Note);

/// <summary>
/// Whether the raw editor is open, why not, the block list in force and where each setting comes from (improvement of FIC-001:
/// Domenia.config.json, default of Domenia 1 or simulation).
/// </summary>
public sealed record FicheRawWrite(bool Allowed, string? Reason, bool BlockSensitive, ImmutableArray<string> BlockList, ImmutableArray<FicheSettingView> Settings, string FileText);

/// <summary>
/// Pure rules about attribute names and raw values: sensitive attributes never shown (Test-DomeniaSensitiveAttributeName), the
/// raw write block list ($script:RawAttributeBlockList), the raw write rule (SE-02, applied by the module before the plan and
/// again by the executor), the grid of raw attributes and the readable options of userAccountControl (Get-UacFlagsLabel).
/// </summary>
public static partial class FicheAttributeRules
{
    private static readonly FrozenSet<string> Sensitive = new[]
    {
        "unicodePwd", "userPassword", "unixUserPassword", "clearTextPassword", "dBCSPwd", "supplementalCredentials", "ntPwdHistory",
        "lmPwdHistory", "currentValue", "priorValue", "pekList", "trustAuthIncoming", "trustAuthOutgoing", "ms-Mcs-AdmPwd",
        "msLAPS-Password", "msLAPS-EncryptedPassword", "msLAPS-EncryptedPasswordHistory", "msLAPS-EncryptedDSRMPassword",
        "msLAPS-EncryptedDSRMPasswordHistory", "msFVE-RecoveryPassword", "msFVE-KeyPackage", "msDS-ManagedPassword",
        "msDS-ManagedPasswordId", "msDS-ManagedPasswordPreviousId", "msDS-KeyCredentialLink",
    }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    /// <summary>Attributes a raw write never touches when BlockSensitiveRawAttributes is on (Domenia 1 list, same order).</summary>
    public static ImmutableArray<string> BlockList { get; } =
    [
        "objectGUID", "objectSid", "sIDHistory", "nTSecurityDescriptor", "unicodePwd", "dBCSPwd", "supplementalCredentials", "ntPwdHistory",
        "lmPwdHistory", "userPassword", "unixUserPassword", "clearTextPassword", "currentValue", "priorValue", "pekList", "trustAuthIncoming",
        "trustAuthOutgoing", "userAccountControl", "adminCount", "isCriticalSystemObject", "msDS-KeyCredentialLink", "msDS-ManagedPassword",
        "msDS-ManagedPasswordId", "msDS-ManagedPasswordPreviousId", "ms-Mcs-AdmPwd", "ms-Mcs-AdmPwdExpirationTime", "msLAPS-Password",
        "msLAPS-EncryptedPassword", "msLAPS-EncryptedPasswordHistory", "msLAPS-EncryptedDSRMPassword", "msLAPS-EncryptedDSRMPasswordHistory",
        "msLAPS-PasswordExpirationTime", "msFVE-RecoveryPassword", "msFVE-KeyPackage", "member", "memberOf", "primaryGroupID",
        "distinguishedName", "objectClass", "objectCategory", "uSNChanged", "uSNCreated", "whenCreated", "whenChanged",
    ];

    private static readonly FrozenSet<string> Blocked = BlockList.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    // Attributes kept by the directory itself or computed: never writable, even outside the block list.
    private static readonly FrozenSet<string> Operational = new[]
    {
        "name", "cn", "ou", "sAMAccountType", "instanceType", "objectGUID", "objectSid", "whenCreated", "whenChanged", "uSNCreated",
        "uSNChanged", "msDS-User-Account-Control-Computed", "msDS-UserPasswordExpiryTimeComputed", "lastLogon", "lastLogonTimestamp",
        "logonCount", "badPwdCount", "badPasswordTime", "lockoutTime", "pwdLastSet", "directReports", "memberOf", "member",
        "distinguishedName", "primaryGroupID", "isCriticalSystemObject", "groupType", "dSCorePropagationData", "objectCategory", "objectClass",
    }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    private static readonly FrozenSet<string> FileTimes = new[]
    {
        "lastLogon", "lastLogonTimestamp", "pwdLastSet", "accountExpires", "badPasswordTime", "lockoutTime", "lastLogoff",
        "msDS-UserPasswordExpiryTimeComputed", "ms-Mcs-AdmPwdExpirationTime", "msLAPS-PasswordExpirationTime",
    }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    private static readonly FrozenSet<string> DnValued = new[]
    {
        "manager", "managedBy", "member", "memberOf", "directReports", "distinguishedName", "objectCategory", "secretary", "seeAlso",
    }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    private static readonly FrozenSet<string> Flags = new[]
    {
        "userAccountControl", "msDS-User-Account-Control-Computed", "groupType", "sAMAccountType", "instanceType", "msDS-SupportedEncryptionTypes", "systemFlags",
    }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    private static readonly FrozenSet<string> Generalized = new[] { "whenCreated", "whenChanged", "dSCorePropagationData" }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9-]{0,126}$", RegexOptions.CultureInvariant)]
    private static partial Regex AttributeName();

    /// <summary>Passwords, LAPS and BitLocker secrets, keys: never read into a fiche, never shown, never copied.</summary>
    public static bool IsSensitive(string? name) => !string.IsNullOrWhiteSpace(name) && Sensitive.Contains(name.Trim());

    /// <summary>A valid LDAP attribute name (letter first, letters, digits and dashes, 127 characters at most).</summary>
    public static bool IsValidName(string? name) => name is not null && AttributeName().IsMatch(name);

    /// <summary>
    /// The raw write rule (SE-02), the same in the module and in the executor: a valid name, Security.AllowRawAttributeWrite,
    /// and with Security.BlockSensitiveRawAttributes an attribute outside the block list. Operational attributes kept by the
    /// directory are refused too (improvement: their write would always fail).
    /// </summary>
    public static RawAttributeDecision RawWriteAllowed(string? attribute, FicheSecurityPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var name = (attribute ?? "").Trim();
        var c = FrenchText.Colon;
        if (!IsValidName(name))
        {
            return new RawAttributeDecision(false, name, "Nom d’attribut invalide.");
        }
        if (!policy.AllowRawAttributeWrite)
        {
            return new RawAttributeDecision(false, name, "Écriture brute désactivée par la configuration de sécurité (Security.AllowRawAttributeWrite).");
        }
        if (IsSensitive(name) || (policy.BlockSensitiveRawAttributes && Blocked.Contains(name)))
        {
            return new RawAttributeDecision(false, name, "Attribut sensible, modification bloquée" + c + name + ".");
        }
        if (Operational.Contains(name))
        {
            return new RawAttributeDecision(false, name, "Attribut tenu par l’annuaire" + c + name + " ne s’écrit pas directement.");
        }
        return new RawAttributeDecision(true, name, "");
    }

    /// <summary>Syntax of an attribute for the grid and the typed editor: dn, date, flags, guid, sid, int, bool, binary or text.</summary>
    public static string SyntaxOf(string name, string? sample)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (FileTimes.Contains(name) || Generalized.Contains(name))
        {
            return "date";
        }
        if (DnValued.Contains(name))
        {
            return "dn";
        }
        if (Flags.Contains(name))
        {
            return "flags";
        }
        if (name.Equals("objectGUID", StringComparison.OrdinalIgnoreCase))
        {
            return "guid";
        }
        if (name.Equals("objectSid", StringComparison.OrdinalIgnoreCase) || name.Equals("sIDHistory", StringComparison.OrdinalIgnoreCase))
        {
            return "sid";
        }
        if (sample is "TRUE" or "FALSE")
        {
            return "bool";
        }
        if (sample is not null && sample.Length > 0 && sample.All(char.IsAsciiDigit) && sample.Length < 20)
        {
            return "int";
        }
        if (name.Equals("userCertificate", StringComparison.OrdinalIgnoreCase) || name.Equals("logonHours", StringComparison.OrdinalIgnoreCase)
            || name.Equals("thumbnailPhoto", StringComparison.OrdinalIgnoreCase))
        {
            return "binary";
        }
        return "text";
    }

    /// <summary>
    /// Raw attributes of an entry, sorted by name (Entry-ToRawAttributes): dates converted beside their raw value, binary
    /// values in hexadecimal, flags with their readable names, sensitive attributes excluded (and counted).
    /// </summary>
    public static FicheRawAttributes Rows(FicheEntry entry, FicheSecurityPolicy policy, TimeZoneInfo zone, int hiddenSensitive, ImmutableArray<FicheSettingView> settings = default, string fileText = "")
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(zone);
        var rows = entry.Attributes
            .Where(p => !IsSensitive(p.Key) && !p.Key.StartsWith("__", StringComparison.Ordinal))
            .OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase)
            .Select(p =>
            {
                var syntax = SyntaxOf(p.Key, p.Value.FirstOrDefault());
                var decision = RawWriteAllowed(p.Key, policy with { AllowRawAttributeWrite = true });
                return new FicheRawAttribute(p.Key, p.Value, string.Join(" ; ", p.Value.Select(v => Display(p.Key, v, syntax, zone))), syntax,
                    p.Value.Length > 1, decision.Allowed, decision.Allowed ? null : decision.Reason);
            })
            .ToImmutableArray();
        var write = RawWriteAllowed("description", policy);
        var rawWrite = new FicheRawWrite(policy.AllowRawAttributeWrite, policy.AllowRawAttributeWrite ? null : write.Reason, policy.BlockSensitiveRawAttributes, BlockList,
            settings.IsDefault ? [] : settings, fileText);
        var note = hiddenSensitive > 0
            ? FrenchText.Count(hiddenSensitive, "attribut sensible exclu", "attributs sensibles exclus") + " (mots de passe, LAPS, BitLocker, clés)" + FrenchText.Colon + "jamais lus ni affichés."
            : "Attributs sensibles (mots de passe, LAPS, BitLocker, clés) jamais lus ni affichés.";
        return new FicheRawAttributes(entry.Dn, rows.Length, hiddenSensitive, rows, rawWrite, note);
    }

    /// <summary>Display of one raw value: dates in local time beside the raw number, flags named, binary in hexadecimal.</summary>
    public static string Display(string name, string value, string syntax, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(value);
        ArgumentNullException.ThrowIfNull(zone);
        switch (syntax)
        {
            case "date" when Generalized.Contains(name):
                return FicheValues.ParseGeneralizedTime(value) is DateTimeOffset at ? FicheValues.LocalDateTime(at, zone) + " (" + value + ")" : value;
            case "date":
                if (!long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number))
                {
                    return value;
                }
                if (number == 0)
                {
                    return "0 (jamais)";
                }
                if (number == AdValues.Never)
                {
                    return value + " (jamais)";
                }
                return AdValues.FromFileTime(number) is DateTimeOffset date ? FicheValues.LocalDateTime(date, zone) + " (" + value + ")" : value;
            case "flags" when name.Equals("userAccountControl", StringComparison.OrdinalIgnoreCase)
                || name.Equals("msDS-User-Account-Control-Computed", StringComparison.OrdinalIgnoreCase):
                return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var uac) ? value + " (" + UacFlagsLabel(uac) + ")" : value;
            case "flags" when name.Equals("groupType", StringComparison.OrdinalIgnoreCase):
                return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var groupType) ? value + " (" + FicheMemberships.GroupTypeLabel(groupType) + ")" : value;
            default:
                return value;
        }
    }

    private static readonly (int Flag, string Label)[] UacMarks =
    [
        (0x1, "Script de connexion"), (0x2, "Compte désactivé"), (0x8, "Répertoire personnel requis"), (0x10, "Compte verrouillé"),
        (0x20, "Mot de passe non requis"), (0x40, "Mot de passe non modifiable"), (0x80, "Mot de passe stocké en clair"),
        (0x100, "Compte temporaire"), (0x200, "Compte normal"), (0x800, "Approbation entre forêts"), (0x1000, "Compte ordinateur"),
        (0x2000, "Contrôleur de domaine"), (0x10000, "Mot de passe jamais expiré"), (0x20000, "Compte de messagerie"),
        (0x40000, "Carte à puce obligatoire"), (0x80000, "Authentification déléguée"), (0x100000, "Authentification non déléguable"),
        (0x200000, "Chiffrement DES uniquement"), (0x400000, "Pré-authentification Kerberos facultative"), (0x800000, "Mot de passe expiré"),
        (0x1000000, "Authentification déléguée vers un service"), (0x4000000, "Contrôleur de domaine en lecture seule"),
    ];

    /// <summary>Readable options of userAccountControl; unknown bits stay visible in hexadecimal (Get-UacFlagsLabel).</summary>
    public static string UacFlagsLabel(int uac)
    {
        var items = new List<string>();
        var known = 0;
        foreach (var (flag, label) in UacMarks)
        {
            if ((uac & flag) != 0)
            {
                items.Add(label);
                known |= flag;
            }
        }
        var rest = uac & ~known;
        if (rest != 0)
        {
            items.Add("Bits non reconnus 0x" + rest.ToString("X", CultureInfo.InvariantCulture));
        }
        return items.Count == 0 ? "Aucune option marquée" : string.Join(", ", items);
    }

    /// <summary>State text of an account (Get-UacStatusLabel, accents restored): « Actif / Verrouillé / Mot de passe expiré ».</summary>
    public static string UacStatusLabel(int? uac, int? computed, long? lockoutTime)
    {
        if (uac is not int value)
        {
            return "État non déterminé";
        }
        var items = new List<string> { AdValues.IsDisabled(value) ? "Désactivé" : "Actif" };
        if (computed is int c)
        {
            if (AdValues.HasFlag(c, AdValues.LockedOut))
            {
                items.Add("Verrouillé");
            }
            if (AdValues.HasFlag(c, AdValues.PasswordExpired))
            {
                items.Add("Mot de passe expiré");
            }
        }
        else if (lockoutTime is > 0)
        {
            items.Add("Verrouillage à vérifier");
        }
        if (AdValues.HasFlag(value, AdValues.DontExpirePassword))
        {
            items.Add("Mot de passe jamais expiré");
        }
        if (AdValues.HasFlag(value, AdValues.PasswordNotRequired))
        {
            items.Add("Mot de passe non requis");
        }
        return string.Join(" / ", items);
    }
}
