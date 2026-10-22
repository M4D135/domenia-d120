using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Core.Queries.Ldap;

/// <summary>Matching syntax of an attribute (subset of the Active Directory syntaxes that filters meet).</summary>
public enum LdapSyntax
{
    /// <summary>Directory string, case-insensitive (equality, ordering, substrings).</summary>
    CaseIgnore,

    /// <summary>32 or 64-bit integer, FILETIME large integers included (equality, ordering, bitwise rules).</summary>
    Integer,

    Boolean,

    /// <summary>Generalized time « 20261021162600.0Z » (equality, ordering).</summary>
    Time,

    /// <summary>Distinguished name (equality, in-chain rule); no substring matching in Active Directory.</summary>
    Dn,

    /// <summary>Object identifier or class name (objectClass), case-insensitive equality.</summary>
    ObjectClass,

    /// <summary>objectCategory: a DN, compared also with the short class name (« computer »), as Active Directory does.</summary>
    ObjectCategory,

    /// <summary>Binary GUID (objectGUID): escaped octets or a GUID text.</summary>
    Guid,

    /// <summary>Binary SID (objectSid): escaped octets or the S-1-5-… form.</summary>
    Sid,
}

/// <summary>
/// One attribute an LDAP filter may name. <see cref="ReadByDomenia"/> is false for attributes the local base does not keep:
/// locally their condition is Undefined (unknown), the controller evaluates them in directory mode.
/// </summary>
public sealed record LdapAttribute(string Name, LdapSyntax Syntax, bool MultiValued, bool ReadByDomenia, string Description, string Example)
{
    public string SyntaxLabel => Syntax switch
    {
        LdapSyntax.Integer => "Entier",
        LdapSyntax.Boolean => "Booléen (TRUE ou FALSE)",
        LdapSyntax.Time => "Date généralisée (AAAAMMJJhhmmss.0Z)",
        LdapSyntax.Dn => "Nom distinctif",
        LdapSyntax.ObjectClass => "Classe d’objet",
        LdapSyntax.ObjectCategory => "Catégorie d’objet",
        LdapSyntax.Guid => "GUID binaire",
        LdapSyntax.Sid => "SID binaire",
        _ => "Chaîne, sans casse",
    };

    public bool Ordered => Syntax is LdapSyntax.CaseIgnore or LdapSyntax.Integer or LdapSyntax.Time;

    public bool Substrings => Syntax is LdapSyntax.CaseIgnore;
}

/// <summary>Attributes known to the filter evaluator (names are case-insensitive, the canonical case is kept).</summary>
public static class LdapSchema
{
    // Matching rules of Active Directory.
    public const string BitAnd = "1.2.840.113556.1.4.803";
    public const string BitOr = "1.2.840.113556.1.4.804";
    public const string InChain = "1.2.840.113556.1.4.1941";

    private static readonly ImmutableArray<LdapAttribute> All_ =
    [
        new("objectClass", LdapSyntax.ObjectClass, true, true, "Classes de l’objet (top, person, user, computer, group…).", "computer"),
        new("objectCategory", LdapSyntax.ObjectCategory, false, true, "Catégorie de l’objet ; le nom court (computer, person, group) est admis.", "computer"),
        new("cn", LdapSyntax.CaseIgnore, false, true, "Nom commun.", "PC-PAR-0042"),
        new("name", LdapSyntax.CaseIgnore, false, true, "Nom de l’objet (RDN).", "PC-PAR-0042"),
        new("distinguishedName", LdapSyntax.Dn, false, true, "Nom distinctif complet.", "CN=PC-PAR-0042,OU=Paris,OU=Postes,DC=example,DC=local"),
        new("sAMAccountName", LdapSyntax.CaseIgnore, false, true, "Nom de compte pré-Windows 2000.", "c.bernard"),
        new("userPrincipalName", LdapSyntax.CaseIgnore, false, true, "Nom d’utilisateur principal.", "c.bernard@example.local"),
        new("displayName", LdapSyntax.CaseIgnore, false, true, "Nom affiché.", "Camille Bernard"),
        new("givenName", LdapSyntax.CaseIgnore, false, true, "Prénom.", "Camille"),
        new("sn", LdapSyntax.CaseIgnore, false, true, "Nom de famille.", "Bernard"),
        new("mail", LdapSyntax.CaseIgnore, false, true, "Adresse de messagerie.", "camille.bernard@example.local"),
        new("title", LdapSyntax.CaseIgnore, false, true, "Fonction.", "Chargée de clientèle"),
        new("department", LdapSyntax.CaseIgnore, false, true, "Service.", "Commercial"),
        new("company", LdapSyntax.CaseIgnore, false, false, "Société (non conservée par Domenia : indéfinie en local).", "Example"),
        new("physicalDeliveryOfficeName", LdapSyntax.CaseIgnore, false, true, "Bureau.", "Lyon"),
        new("telephoneNumber", LdapSyntax.CaseIgnore, false, true, "Téléphone.", "+33 4 65 71 00 00"),
        new("manager", LdapSyntax.Dn, false, true, "Responsable hiérarchique.", "CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,DC=example,DC=local"),
        new("description", LdapSyntax.CaseIgnore, false, true, "Description.", "Poste de Camille Bernard"),
        new("employeeID", LdapSyntax.CaseIgnore, false, true, "Matricule.", "104512"),
        new("userAccountControl", LdapSyntax.Integer, false, true, "Indicateurs du compte (2 = désactivé, 65536 = mot de passe sans expiration…).", "4096"),
        new("msDS-User-Account-Control-Computed", LdapSyntax.Integer, false, true, "Indicateurs calculés par le contrôleur (16 = verrouillé, 8388608 = mot de passe expiré).", "16"),
        new("lockoutTime", LdapSyntax.Integer, false, true, "Date du verrouillage (FILETIME) ; 0 = déverrouillé.", "0"),
        new("badPwdCount", LdapSyntax.Integer, false, true, "Essais erronés (non répliqué).", "3"),
        new("pwdLastSet", LdapSyntax.Integer, false, true, "Dernier changement de mot de passe (FILETIME) ; 0 = à changer.", "134000000000000000"),
        new("msDS-UserPasswordExpiryTimeComputed", LdapSyntax.Integer, false, true, "Expiration calculée du mot de passe (FILETIME).", "134100000000000000"),
        new("lastLogonTimestamp", LdapSyntax.Integer, false, true, "Dernière connexion répliquée (FILETIME, retard de 9 à 14 jours).", "134050000000000000"),
        new("accountExpires", LdapSyntax.Integer, false, true, "Expiration du compte (FILETIME) ; 0 ou 9223372036854775807 = jamais.", "9223372036854775807"),
        new("whenCreated", LdapSyntax.Time, false, true, "Date de création.", "20250101000000.0Z"),
        new("whenChanged", LdapSyntax.Time, false, true, "Date de dernière modification.", "20261021000000.0Z"),
        new("uSNChanged", LdapSyntax.Integer, false, true, "Numéro de séquence de la dernière modification.", "123456"),
        new("adminCount", LdapSyntax.Integer, false, true, "1 pour un objet protégé par AdminSDHolder.", "1"),
        new("primaryGroupID", LdapSyntax.Integer, false, true, "RID du groupe principal (513, 515, 516).", "513"),
        new("memberOf", LdapSyntax.Dn, true, true, "Groupes directs ; la règle 1.2.840.113556.1.4.1941 suit la chaîne.", "CN=GG-Support-N2,OU=Sécurité,OU=Groupes,DC=example,DC=local"),
        new("member", LdapSyntax.Dn, true, true, "Membres directs d’un groupe.", "CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,DC=example,DC=local"),
        new("objectGUID", LdapSyntax.Guid, false, true, "Identifiant unique (octets échappés \\xx ou GUID).", "6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3"),
        new("objectSid", LdapSyntax.Sid, false, true, "Identifiant de sécurité (octets échappés ou S-1-5-…).", "S-1-5-21-1-2-3-1105"),
        new("dNSHostName", LdapSyntax.CaseIgnore, false, true, "Nom DNS du poste.", "pc-par-0042.example.local"),
        new("operatingSystem", LdapSyntax.CaseIgnore, false, true, "Système déclaré.", "Windows 11 Entreprise"),
        new("operatingSystemVersion", LdapSyntax.CaseIgnore, false, true, "Version déclarée.", "10.0 (26100)"),
        new("location", LdapSyntax.CaseIgnore, false, true, "Emplacement.", "Paris – bâtiment A, étage 2"),
        new("managedBy", LdapSyntax.Dn, false, true, "Responsable de l’objet.", "CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local"),
        new("msLAPS-PasswordExpirationTime", LdapSyntax.Integer, false, true, "Expiration du mot de passe LAPS Windows (FILETIME) ; jamais le secret.", "134060000000000000"),
        new("ms-Mcs-AdmPwdExpirationTime", LdapSyntax.Integer, false, true, "Expiration du mot de passe LAPS hérité (FILETIME) ; jamais le secret.", "134060000000000000"),
        new("groupType", LdapSyntax.Integer, false, true, "Type et étendue du groupe (bit 2147483648 = sécurité).", "-2147483646"),
        new("ou", LdapSyntax.CaseIgnore, false, true, "Nom d’une unité d’organisation.", "Postes"),
        new("info", LdapSyntax.CaseIgnore, false, false, "Notes du compte.", "Prêt de matériel"),
        new("streetAddress", LdapSyntax.CaseIgnore, false, false, "Adresse postale.", "1 rue de l’Exemple"),
        new("l", LdapSyntax.CaseIgnore, false, false, "Ville.", "Lyon"),
        new("st", LdapSyntax.CaseIgnore, false, false, "Région ou département.", "Rhône"),
        new("postalCode", LdapSyntax.CaseIgnore, false, false, "Code postal.", "69000"),
        new("co", LdapSyntax.CaseIgnore, false, false, "Pays.", "France"),
        new("mobile", LdapSyntax.CaseIgnore, false, false, "Téléphone mobile.", "+33 6 00 00 00 00"),
        new("homeDirectory", LdapSyntax.CaseIgnore, false, false, "Dossier de base.", "\\\\srv-fic-01\\home\\c.bernard"),
        new("scriptPath", LdapSyntax.CaseIgnore, false, false, "Script d’ouverture de session.", "logon.cmd"),
        new("profilePath", LdapSyntax.CaseIgnore, false, false, "Profil itinérant.", "\\\\srv-fic-01\\profils\\c.bernard"),
        new("servicePrincipalName", LdapSyntax.CaseIgnore, true, false, "Noms de principal de service.", "HOST/pc-par-0042"),
        new("lastLogon", LdapSyntax.Integer, false, false, "Dernière connexion sur un contrôleur (non répliqué).", "134050000000000000"),
        new("logonCount", LdapSyntax.Integer, false, false, "Nombre de connexions (non répliqué).", "120"),
        new("userWorkstations", LdapSyntax.CaseIgnore, false, false, "Postes autorisés.", "PC-PAR-0042"),
        new("msDS-SupportedEncryptionTypes", LdapSyntax.Integer, false, false, "Types de chiffrement Kerberos pris en charge.", "28"),
        new("operatingSystemServicePack", LdapSyntax.CaseIgnore, false, false, "Service pack déclaré.", "Service Pack 1"),
        new("isCriticalSystemObject", LdapSyntax.Boolean, false, false, "Objet système critique.", "TRUE"),
        new("showInAdvancedViewOnly", LdapSyntax.Boolean, false, false, "Visible seulement en vue avancée.", "TRUE"),
    ];

    private static readonly FrozenDictionary<string, LdapAttribute> ByName = All_.ToFrozenDictionary(a => a.Name, StringComparer.OrdinalIgnoreCase);

    public static ImmutableArray<LdapAttribute> All => All_;

    /// <summary>Attribute by name, ignoring case and a « ;binary » option; null when unknown (the filter item is then Undefined).</summary>
    public static LdapAttribute? Find(string? name)
    {
        if (string.IsNullOrEmpty(name))
        {
            return null;
        }
        var semicolon = name.IndexOf(';', StringComparison.Ordinal);
        var bare = semicolon >= 0 ? name[..semicolon] : name;
        return ByName.TryGetValue(bare, out var attribute) ? attribute : null;
    }
}
