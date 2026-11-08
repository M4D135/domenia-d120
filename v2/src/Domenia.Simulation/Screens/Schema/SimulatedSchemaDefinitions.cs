using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Schema of the fictitious directory (docs/ops/schema.md § 14): a representative subset of the Active Directory base schema
/// (real lDAPDisplayName, syntax, cardinality, indexes, global catalog, links and constructed attributes), the LAPS, BitLocker
/// and RFC 2307 extensions, and a small company extension « Example » with one deactivated attribute and one deactivated
/// class. Descriptions are written in French for the operator. Same for every seed: a schema does not depend on the people of
/// the directory. Nothing here is read from a real controller.
/// </summary>
internal static class SimulatedSchemaDefinitions
{
    // attributeSyntax
    private const string Dn = "2.5.5.1";
    private const string ObjectId = "2.5.5.2";
    private const string Ia5 = "2.5.5.5";
    private const string DnBinary = "2.5.5.7";
    private const string Boolean = "2.5.5.8";
    private const string Integer = "2.5.5.9";
    private const string Octets = "2.5.5.10";
    private const string Time = "2.5.5.11";
    private const string Unicode = "2.5.5.12";
    private const string SecurityDescriptor = "2.5.5.15";
    private const string Large = "2.5.5.16";
    private const string Sid = "2.5.5.17";

    // searchFlags
    private const long Index = 1;
    private const long Anr = 4;
    private const long Keep = 8;
    private const long Copy = 16;
    private const long Tuple = 32;
    private const long Confidential = 128;
    private const long NeverAudit = 256;
    private const long RodcFiltered = 512;

    // systemFlags
    private const long NotReplicated = 1;
    private const long Constructed = 4;
    private const long BaseSchema = 16;

    private static readonly Lazy<ImmutableArray<SchemaAttributeDefinition>> AttributeList = new(BuildAttributes, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<ImmutableArray<SchemaClassDefinition>> ClassList = new(BuildClasses, LazyThreadSafetyMode.ExecutionAndPublication);

    public static ImmutableArray<SchemaAttributeDefinition> Attributes => AttributeList.Value;

    public static ImmutableArray<SchemaClassDefinition> Classes => ClassList.Value;

    private static SchemaAttributeDefinition A(
        string name, string syntax, bool single, long search, long system, bool gc, string description,
        long? lower = null, long? upper = null, long? link = null, bool defunct = false, string? oid = null) =>
        new(name, description, oid, syntax, OmSyntax(syntax), single, search, system, gc, lower, upper, link, defunct);

    private static int OmSyntax(string syntax) => syntax switch
    {
        Dn or DnBinary => 127,
        ObjectId => 6,
        Ia5 => 22,
        Boolean => 1,
        Integer => 2,
        Octets or Sid => 4,
        Time => 24,
        Unicode => 64,
        SecurityDescriptor => 66,
        Large => 65,
        _ => 0,
    };

    private static ImmutableArray<SchemaAttributeDefinition> BuildAttributes()
    {
        var list = new List<SchemaAttributeDefinition>
        {
            // ---------------------------------------------------------------- naming and identity
            A("cn", Unicode, true, Index, BaseSchema, true, "Nom commun : RDN de la plupart des objets.", 1, 64, oid: "2.5.4.3"),
            A("name", Unicode, true, Index | Anr | Keep, BaseSchema, true, "Nom relatif de l’objet (RDN), quelle que soit sa classe.", 1, 255, oid: "1.2.840.113556.1.4.1"),
            A("displayName", Unicode, true, Index | Anr | Tuple, 0, true, "Nom affiché dans les listes, la messagerie et les fiches.", 0, 256, oid: "1.2.840.113556.1.2.13"),
            A("givenName", Unicode, true, Index | Anr, 0, true, "Prénom.", 1, 64, oid: "2.5.4.42"),
            A("sn", Unicode, true, Index | Anr, 0, true, "Nom de famille.", 1, 64, oid: "2.5.4.4"),
            A("initials", Unicode, true, 0, 0, false, "Initiales.", 1, 6),
            A("sAMAccountName", Unicode, true, Index | Anr | Keep, BaseSchema, true, "Nom d’ouverture de session antérieur à Windows 2000.", 0, 256, oid: "1.2.840.113556.1.4.221"),
            A("userPrincipalName", Unicode, true, Index, 0, true, "Nom d’utilisateur principal (UPN), de la forme nom@domaine.", 1, 1024, oid: "1.2.840.113556.1.4.656"),
            A("mail", Unicode, true, Index | Tuple, 0, true, "Adresse de messagerie principale.", 0, 256, oid: "0.9.2342.19200300.100.1.3"),
            A("proxyAddresses", Unicode, false, Index | Anr, 0, true, "Adresses de messagerie secondaires (smtp:, SMTP:, x500:…).", 1, 1123),
            A("legacyExchangeDN", Unicode, true, Index | Anr, 0, true, "Ancien nom distinctif Exchange, gardé pour la messagerie.", 1, 2048),
            A("description", Unicode, false, 0, BaseSchema, true, "Description libre de l’objet.", 0, 1024, oid: "2.5.4.13"),
            A("info", Unicode, true, 0, 0, false, "Remarques (onglet Téléphones).", 1, 1024),
            A("title", Unicode, true, 0, 0, false, "Fonction.", 1, 128, oid: "2.5.4.12"),
            A("department", Unicode, true, 0, 0, false, "Service.", 1, 64, oid: "1.2.840.113556.1.2.141"),
            A("company", Unicode, true, 0, 0, false, "Société.", 1, 64, oid: "1.2.840.113556.1.2.146"),
            A("physicalDeliveryOfficeName", Unicode, true, Index | Anr, 0, true, "Bureau.", 1, 128, oid: "2.5.4.19"),
            A("telephoneNumber", Unicode, true, 0, 0, true, "Numéro de téléphone principal.", 1, 64, oid: "2.5.4.20"),
            A("otherTelephone", Unicode, false, 0, 0, false, "Autres numéros de téléphone.", 1, 64),
            A("mobile", Unicode, true, 0, 0, false, "Téléphone portable.", 1, 64),
            A("ipPhone", Unicode, true, 0, 0, false, "Téléphone IP.", 1, 64),
            A("facsimileTelephoneNumber", Unicode, true, 0, 0, false, "Télécopie.", 1, 64),
            A("streetAddress", Unicode, true, 0, 0, false, "Adresse (rue).", 1, 1024),
            A("l", Unicode, true, Index, 0, true, "Localité.", 1, 128, oid: "2.5.4.7"),
            A("st", Unicode, true, Index, 0, true, "Département ou région.", 1, 128),
            A("postalCode", Unicode, true, 0, 0, false, "Code postal.", 1, 40),
            A("c", Unicode, true, 0, 0, true, "Pays (code ISO à deux lettres).", 2, 2),
            A("co", Unicode, true, 0, 0, false, "Pays en toutes lettres.", 0, 128),
            A("countryCode", Integer, true, 0, 0, true, "Pays (code numérique ISO 3166).", 0, 65535),
            A("employeeID", Unicode, true, 0, 0, false, "Matricule.", 0, 16, oid: "1.2.840.113556.1.4.35"),
            A("employeeNumber", Unicode, true, 0, 0, false, "Numéro d’employé.", 1, 512),
            A("employeeType", Unicode, true, 0, 0, false, "Type de contrat ou de personne.", 1, 256),
            A("thumbnailPhoto", Octets, true, 0, 0, true, "Photo de la personne (100 ko au plus).", 0, 102400),
            A("jpegPhoto", Octets, false, 0, 0, false, "Photos au format JPEG (inetOrgPerson)."),
            A("seeAlso", Dn, false, 0, 0, false, "Objets associés."),

            // ---------------------------------------------------------------- links
            A("manager", Dn, true, 0, 0, true, "Responsable hiérarchique.", link: 42, oid: "0.9.2342.19200300.100.1.10"),
            A("directReports", Dn, false, 0, NotReplicated | BaseSchema, true, "Collaborateurs directs (lien retour de manager).", link: 43, oid: "1.2.840.113556.1.2.436"),
            A("member", Dn, false, 0, BaseSchema, true, "Membres du groupe.", link: 2, oid: "2.5.4.31"),
            A("memberOf", Dn, false, 0, NotReplicated | BaseSchema, true, "Groupes dont l’objet est membre direct (lien retour de member).", link: 3, oid: "1.2.840.113556.1.2.102"),
            A("managedBy", Dn, true, 0, BaseSchema, true, "Responsable de l’objet (groupe, ordinateur, OU).", link: 72, oid: "1.2.840.113556.1.4.653"),
            A("managedObjects", Dn, false, 0, NotReplicated | BaseSchema, true, "Objets dont ce compte est responsable (lien retour de managedBy).", link: 73),
            A("msDS-KeyCredentialLink", DnBinary, false, 0, 0, false, "Clés d’authentification sans mot de passe (Windows Hello Entreprise).", link: 2220),
            A("msDS-PSOAppliesTo", Dn, false, 0, 0, false, "Utilisateurs et groupes concernés par la stratégie de mots de passe.", link: 2118),
            A("msDS-PSOApplied", Dn, false, 0, NotReplicated, false, "Stratégies de mots de passe affinées appliquées (lien retour).", link: 2119),
            A("msDS-HostServiceAccount", Dn, false, 0, 0, false, "Comptes de service gérés hébergés par cet ordinateur.", link: 2160),
            A("msDS-HostServiceAccountBL", Dn, false, 0, NotReplicated, false, "Ordinateurs qui hébergent ce compte de service (lien retour).", link: 2161),
            A("siteObject", Dn, true, 0, 0, false, "Site auquel le sous-réseau est rattaché.", link: 46),
            A("siteObjectBL", Dn, false, 0, NotReplicated, false, "Sous-réseaux rattachés au site (lien retour).", link: 47),
            A("serverReference", Dn, true, 0, 0, false, "Objet ordinateur du contrôleur.", link: 94),
            A("serverReferenceBL", Dn, false, 0, NotReplicated, false, "Serveur de site qui désigne cet ordinateur (lien retour).", link: 95),

            // ---------------------------------------------------------------- directory bookkeeping
            A("distinguishedName", Dn, true, 0, BaseSchema, true, "Chemin LDAP complet de l’objet (DN).", oid: "2.5.4.49"),
            A("objectClass", ObjectId, false, Index, BaseSchema, true, "Classes de l’objet, de la plus générale à la plus précise.", oid: "2.5.4.0"),
            A("objectCategory", Dn, true, Index, BaseSchema, true, "Catégorie de l’objet : indexée, à préférer pour cibler une classe.", oid: "1.2.840.113556.1.4.782"),
            A("objectGUID", Octets, true, Index | Keep, BaseSchema, true, "Identifiant unique et permanent de l’objet.", 16, 16, oid: "1.2.840.113556.1.4.2"),
            A("objectSid", Sid, true, Index | Keep, BaseSchema, true, "Identifiant de sécurité (SID) du compte.", 0, 28, oid: "1.2.840.113556.1.4.146"),
            A("sIDHistory", Sid, false, Index, BaseSchema, true, "SID précédents, gardés après une migration."),
            A("nTSecurityDescriptor", SecurityDescriptor, true, Keep, BaseSchema, true, "Descripteur de sécurité : propriétaire et listes de contrôle d’accès.", 0, 132096),
            A("instanceType", Integer, true, 0, BaseSchema, true, "Type d’instance de l’objet dans sa partition."),
            A("whenCreated", Time, true, 0, BaseSchema, true, "Date de création de l’objet.", oid: "1.2.840.113556.1.2.2"),
            A("whenChanged", Time, true, 0, BaseSchema, true, "Date de la dernière modification, sur ce contrôleur.", oid: "1.2.840.113556.1.2.3"),
            A("uSNCreated", Large, true, Index, BaseSchema, true, "Numéro de séquence de la création.", oid: "1.2.840.113556.1.2.19"),
            A("uSNChanged", Large, true, Index, NotReplicated | BaseSchema, true, "Numéro de séquence de la dernière modification, sur ce contrôleur.", oid: "1.2.840.113556.1.2.120"),
            A("isCriticalSystemObject", Boolean, true, 0, BaseSchema, true, "Objet système essentiel au fonctionnement du domaine."),
            A("showInAdvancedViewOnly", Boolean, true, 0, BaseSchema, true, "Visible seulement en affichage avancé."),
            A("systemFlags", Integer, true, 0, BaseSchema, true, "Indicateurs système de l’objet."),
            A("adminCount", Integer, true, 0, 0, false, "Marque des comptes protégés par AdminSDHolder (1)."),
            A("wellKnownObjects", DnBinary, false, 0, BaseSchema, false, "Conteneurs connus du domaine (Users, Computers…)."),
            A("fSMORoleOwner", Dn, true, 0, BaseSchema, false, "Paramètres NTDS du contrôleur détenteur du rôle."),
            A("gPLink", Unicode, true, 0, 0, false, "Stratégies de groupe liées au conteneur."),
            A("gPOptions", Integer, true, 0, 0, false, "Blocage de l’héritage des stratégies (1)."),
            A("options", Integer, true, 0, 0, false, "Options d’un objet de configuration."),
            A("flags", Integer, true, 0, 0, false, "Indicateurs propres à la classe de l’objet."),
            A("versionNumber", Integer, true, 0, 0, false, "Numéro de version."),
            A("keywords", Unicode, false, Index, 0, true, "Mots-clés de recherche d’un objet publié.", 0, 256),
            A("location", Unicode, true, Index, 0, true, "Emplacement physique.", 0, 1024),

            // ---------------------------------------------------------------- constructed
            A("canonicalName", Unicode, false, 0, Constructed | BaseSchema, false, "Chemin canonique (domaine/OU/nom), calculé par le contrôleur."),
            A("createTimeStamp", Time, true, 0, Constructed | BaseSchema, false, "Date de création, calculée (même valeur que whenCreated)."),
            A("modifyTimeStamp", Time, true, 0, Constructed | BaseSchema, false, "Date de modification, calculée (même valeur que whenChanged)."),
            A("tokenGroups", Sid, false, 0, Constructed | BaseSchema, false, "Groupes du jeton, appartenances imbriquées comprises, calculés."),
            A("allowedAttributes", ObjectId, false, 0, Constructed | BaseSchema, false, "Attributs que l’objet peut porter, calculés."),
            A("allowedChildClasses", ObjectId, false, 0, Constructed | BaseSchema, false, "Classes possibles sous cet objet, calculées."),
            A("msDS-PrincipalName", Unicode, true, 0, Constructed, false, "Nom du principal (DOMAINE\\nom), calculé."),
            A("msDS-ReplAttributeMetaData", Unicode, false, 0, Constructed, false, "Métadonnées de réplication des attributs, calculées."),
            A("msDS-parentdistname", Dn, true, 0, Constructed, false, "DN du conteneur parent, calculé."),
            A("msDS-User-Account-Control-Computed", Integer, true, 0, Constructed | BaseSchema, false, "Indicateurs calculés : verrouillage et expiration du mot de passe."),
            A("msDS-UserPasswordExpiryTimeComputed", Large, true, 0, Constructed | BaseSchema, false, "Date d’expiration du mot de passe, calculée selon la stratégie effective."),
            A("msDS-ResultantPSO", Dn, true, 0, Constructed, false, "Stratégie de mots de passe effective, calculée."),
            A("primaryGroupToken", Integer, true, 0, Constructed | BaseSchema, false, "RID du groupe, calculé (valeur à mettre dans primaryGroupID)."),
            A("entryTTL", Integer, true, 0, Constructed, false, "Durée de vie restante d’un objet dynamique (secondes), calculée."),
            A("msDS-ManagedPassword", Octets, true, 0, Constructed, false, "Mot de passe géré d’un gMSA, calculé et lisible par les seuls principaux autorisés."),

            // ---------------------------------------------------------------- accounts
            A("userAccountControl", Integer, true, Index | Keep | Copy, BaseSchema, true, "Indicateurs du compte : désactivé, mot de passe sans expiration…", oid: "1.2.840.113556.1.4.8"),
            A("sAMAccountType", Integer, true, Index, BaseSchema, true, "Type de compte SAM, déduit de la classe (805306368 : utilisateur)."),
            A("primaryGroupID", Integer, true, Index, BaseSchema, true, "RID du groupe principal (513 : Utilisateurs du domaine).", oid: "1.2.840.113556.1.4.98"),
            A("groupType", Integer, true, Index, BaseSchema, true, "Type et étendue du groupe (bits).", oid: "1.2.840.113556.1.4.750"),
            A("pwdLastSet", Large, true, 0, BaseSchema, false, "Date du dernier changement de mot de passe (FILETIME).", oid: "1.2.840.113556.1.4.96"),
            A("accountExpires", Large, true, 0, BaseSchema, true, "Expiration du compte (FILETIME ; 0 ou 9223372036854775807 : jamais).", oid: "1.2.840.113556.1.4.159"),
            A("lastLogon", Large, true, 0, NotReplicated | BaseSchema, false, "Dernière ouverture de session sur ce contrôleur (non répliqué).", oid: "1.2.840.113556.1.4.52"),
            A("lastLogonTimestamp", Large, true, Index, 0, false, "Dernière ouverture de session répliquée (précision de 9 à 14 jours).", oid: "1.2.840.113556.1.4.1696"),
            A("lastLogoff", Large, true, 0, NotReplicated | BaseSchema, false, "Dernière fermeture de session (rarement tenue à jour)."),
            A("logonCount", Integer, true, 0, NotReplicated | BaseSchema, false, "Ouvertures de session sur ce contrôleur."),
            A("badPwdCount", Integer, true, 0, NotReplicated | BaseSchema, false, "Essais de mot de passe erronés sur ce contrôleur.", oid: "1.2.840.113556.1.4.12"),
            A("badPasswordTime", Large, true, 0, NotReplicated | BaseSchema, false, "Date du dernier essai erroné sur ce contrôleur."),
            A("lockoutTime", Large, true, 0, BaseSchema, false, "Date du verrouillage du compte (0 : déverrouillé).", oid: "1.2.840.113556.1.4.662"),
            A("logonHours", Octets, true, 0, BaseSchema, false, "Heures d’ouverture de session autorisées (168 bits)."),
            A("userWorkstations", Unicode, true, 0, BaseSchema, false, "Postes autorisés pour l’ouverture de session.", 0, 1024),
            A("scriptPath", Unicode, true, 0, 0, false, "Script d’ouverture de session.", 0, 260),
            A("profilePath", Unicode, true, 0, 0, false, "Profil itinérant.", 0, 260),
            A("homeDirectory", Unicode, true, 0, 0, false, "Dossier personnel.", 0, 260),
            A("homeDrive", Unicode, true, 0, 0, false, "Lettre du dossier personnel.", 0, 3),
            A("unicodePwd", Octets, true, 0, BaseSchema, false, "Mot de passe, en écriture seulement : jamais lisible."),
            A("userCertificate", Octets, false, 0, 0, true, "Certificats X.509 du compte.", 0, 32768),
            A("servicePrincipalName", Unicode, false, Index, 0, true, "Noms de principal de service (SPN) pour Kerberos.", 0, 2048, oid: "1.2.840.113556.1.4.771"),
            A("msDS-SupportedEncryptionTypes", Integer, true, 0, 0, false, "Types de chiffrement Kerberos pris en charge."),
            A("msDS-AllowedToDelegateTo", Unicode, false, 0, 0, false, "Services vers lesquels la délégation contrainte est permise."),
            A("msDS-AllowedToActOnBehalfOfOtherIdentity", SecurityDescriptor, true, 0, 0, false, "Délégation contrainte basée sur la ressource.", 0, 132096),

            // ---------------------------------------------------------------- computers
            A("dNSHostName", Unicode, true, Index, 0, true, "Nom DNS complet de l’ordinateur.", 0, 2048, oid: "1.2.840.113556.1.4.619"),
            A("operatingSystem", Unicode, true, 0, 0, false, "Système d’exploitation.", 0, 64, oid: "1.2.840.113556.1.4.363"),
            A("operatingSystemVersion", Unicode, true, 0, 0, false, "Version du système, par exemple 10.0 (26100).", 0, 64, oid: "1.2.840.113556.1.4.365"),
            A("operatingSystemServicePack", Unicode, true, 0, 0, false, "Service pack du système.", 0, 64),
            A("operatingSystemHotfix", Unicode, true, 0, 0, false, "Correctifs du système.", 0, 64),
            A("networkAddress", Unicode, false, 0, 0, false, "Adresses réseau.", 0, 256),
            A("ipHostNumber", Ia5, false, 0, 0, false, "Adresses IP de l’hôte (RFC 2307).", 0, 128),
            A("ms-Mcs-AdmPwd", Unicode, true, Keep | Confidential | NeverAudit | RodcFiltered, 0, false, "Mot de passe LAPS hérité : confidentiel, jamais lu par Domenia."),
            A("ms-Mcs-AdmPwdExpirationTime", Large, true, 0, 0, false, "Expiration du mot de passe LAPS hérité (FILETIME)."),
            A("msLAPS-Password", Unicode, true, Keep | Confidential | NeverAudit | RodcFiltered, 0, false, "Mot de passe Windows LAPS en clair : confidentiel, jamais lu par Domenia."),
            A("msLAPS-EncryptedPassword", Octets, true, Keep | Confidential | NeverAudit | RodcFiltered, 0, false, "Mot de passe Windows LAPS chiffré : confidentiel."),
            A("msLAPS-EncryptedPasswordHistory", Octets, false, Keep | Confidential | NeverAudit | RodcFiltered, 0, false, "Historique chiffré des mots de passe Windows LAPS : confidentiel."),
            A("msLAPS-PasswordExpirationTime", Large, true, Index, 0, false, "Expiration du mot de passe Windows LAPS (FILETIME).", oid: "1.2.840.113556.1.6.44.1.1"),
            A("msFVE-RecoveryPassword", Unicode, true, Keep | Copy | Confidential, 0, false, "Mot de passe de récupération BitLocker : confidentiel, jamais lu par Domenia."),
            A("msFVE-RecoveryGuid", Octets, true, Index | Keep | Copy, 0, false, "Identifiant du mot de passe de récupération BitLocker."),
            A("msFVE-VolumeGuid", Octets, true, Index | Keep | Copy, 0, false, "Identifiant du volume chiffré."),
            A("msFVE-KeyPackage", Octets, true, Keep | Copy | Confidential, 0, false, "Paquet de clés BitLocker : confidentiel."),
            A("msTPM-OwnerInformation", Unicode, true, Keep | Copy | Confidential, 0, false, "Information du propriétaire de la puce TPM : confidentielle."),
            A("msTPM-TpmInformationForComputer", Dn, true, 0, 0, false, "Objet TPM de l’ordinateur.", link: 2182),
            A("msTPM-TpmInformationForComputerBL", Dn, false, 0, NotReplicated, false, "Ordinateurs liés à cet objet TPM (lien retour).", link: 2183),

            // ---------------------------------------------------------------- service accounts and password policies
            A("msDS-ManagedPasswordInterval", Integer, true, 0, 0, false, "Renouvellement du mot de passe géré (jours)."),
            A("msDS-GroupMSAMembership", SecurityDescriptor, true, 0, 0, false, "Principaux autorisés à lire le mot de passe géré.", 0, 132096),
            A("msDS-PasswordSettingsPrecedence", Integer, true, 0, 0, false, "Priorité de la stratégie de mots de passe (la plus faible gagne).", 1),
            A("msDS-MinimumPasswordLength", Integer, true, 0, 0, false, "Longueur minimale du mot de passe.", 0, 255),
            A("msDS-PasswordHistoryLength", Integer, true, 0, 0, false, "Mots de passe gardés en historique.", 0, 1024),
            A("msDS-LockoutThreshold", Integer, true, 0, 0, false, "Essais erronés avant verrouillage.", 0, 65535),
            A("msDS-MaximumPasswordAge", Large, true, 0, 0, false, "Durée de vie maximale du mot de passe (intervalle négatif)."),
            A("maxPwdAge", Large, true, 0, BaseSchema, false, "Durée de vie maximale du mot de passe du domaine."),
            A("minPwdLength", Integer, true, 0, BaseSchema, false, "Longueur minimale du mot de passe du domaine.", 0, 255),
            A("pwdHistoryLength", Integer, true, 0, BaseSchema, false, "Historique des mots de passe du domaine.", 0, 65535),
            A("pwdProperties", Integer, true, 0, BaseSchema, false, "Exigences de complexité du domaine (bits)."),
            A("lockoutThreshold", Integer, true, 0, BaseSchema, false, "Seuil de verrouillage du domaine.", 0, 65535),
            A("lockoutDuration", Large, true, 0, BaseSchema, false, "Durée du verrouillage du domaine (intervalle négatif)."),
            A("lockOutObservationWindow", Large, true, 0, BaseSchema, false, "Fenêtre d’observation des essais erronés."),
            A("msDS-Behavior-Version", Integer, true, 0, BaseSchema, false, "Niveau fonctionnel du domaine ou de la forêt."),

            // ---------------------------------------------------------------- containers, sites and policies
            A("ou", Unicode, false, Index, BaseSchema, true, "Nom de l’unité d’organisation.", 1, 64, oid: "2.5.4.11"),
            A("dc", Unicode, true, Index, BaseSchema, true, "Composant de domaine.", 1, 255, oid: "0.9.2342.19200300.100.1.25"),
            A("gPCFileSysPath", Unicode, true, 0, 0, false, "Dossier de la stratégie dans SYSVOL."),
            A("gPCMachineExtensionNames", Unicode, true, 0, 0, false, "Extensions de stratégie de la partie ordinateur."),
            A("gPCUserExtensionNames", Unicode, true, 0, 0, false, "Extensions de stratégie de la partie utilisateur."),
            A("gPCFunctionalityVersion", Integer, true, 0, 0, false, "Version fonctionnelle de la stratégie."),
            A("printerName", Unicode, true, Index, 0, true, "Nom de l’imprimante.", 1, 256),
            A("serverName", Unicode, true, Index, 0, true, "Serveur d’impression.", 1, 256),
            A("uNCName", Unicode, true, Index, 0, true, "Chemin réseau (UNC) de l’objet publié.", 1, 2048),
            A("driverName", Unicode, true, 0, 0, false, "Pilote de l’imprimante.", 1, 256),
            A("serviceBindingInformation", Unicode, false, 0, 0, false, "Informations de connexion au service publié."),
            A("serviceDNSName", Unicode, true, 0, 0, false, "Nom DNS du service publié."),
            A("trustPartner", Unicode, true, Index, 0, false, "Domaine approuvé ou approbateur.", 1, 1024),
            A("trustDirection", Integer, true, 0, 0, false, "Sens de l’approbation (1 entrant, 2 sortant, 3 bidirectionnel)."),
            A("trustType", Integer, true, 0, 0, false, "Type de l’approbation."),
            A("trustAttributes", Integer, true, 0, 0, false, "Attributs de l’approbation (transitivité, filtrage…)."),
            A("flatName", Unicode, true, Index, 0, false, "Nom NetBIOS du domaine approuvé.", 1, 15),
            A("dnsRoot", Unicode, false, 0, 0, false, "Nom DNS d’une partition."),
            A("nETBIOSName", Unicode, true, 0, 0, false, "Nom NetBIOS d’un domaine.", 1, 16),
            A("nCName", Dn, true, 0, BaseSchema, false, "Partition désignée par une référence croisée."),
            A("msDS-Entry-Time-To-Die", Time, true, Index, 0, false, "Date de disparition d’un objet dynamique."),

            // ---------------------------------------------------------------- RFC 2307 (identité Unix)
            A("uid", Unicode, false, Index, 0, true, "Identifiant Unix de connexion.", 1, 256, oid: "0.9.2342.19200300.100.1.1"),
            A("uidNumber", Integer, true, Index, 0, false, "Numéro d’utilisateur Unix."),
            A("gidNumber", Integer, true, Index, 0, false, "Numéro de groupe Unix."),
            A("unixHomeDirectory", Ia5, true, 0, 0, false, "Dossier personnel Unix.", 1, 2048),
            A("loginShell", Ia5, true, 0, 0, false, "Interpréteur de commandes Unix.", 1, 1024),
            A("memberUid", Ia5, false, 0, 0, false, "Membres d’un groupe Unix (identifiants).", 1, 256),
            A("unixUserPassword", Octets, false, Confidential, 0, false, "Mot de passe Unix hérité : confidentiel.", 1, 128),

            // ---------------------------------------------------------------- schema definitions (attributeSchema, classSchema)
            A("lDAPDisplayName", Unicode, true, Index, BaseSchema, true, "Nom LDAP d’un attribut ou d’une classe.", 1, 256),
            A("attributeID", ObjectId, true, Index, BaseSchema, true, "OID d’un attribut."),
            A("attributeSyntax", ObjectId, true, 0, BaseSchema, false, "Syntaxe d’un attribut (OID 2.5.5.x)."),
            A("oMSyntax", Integer, true, 0, BaseSchema, false, "Syntaxe XOM d’un attribut."),
            A("isSingleValued", Boolean, true, 0, BaseSchema, false, "L’attribut n’accepte qu’une valeur."),
            A("searchFlags", Integer, true, 0, BaseSchema, false, "Indicateurs de recherche : index, ANR, confidentiel…"),
            A("isMemberOfPartialAttributeSet", Boolean, true, 0, BaseSchema, false, "L’attribut est répliqué dans le catalogue global."),
            A("linkID", Integer, true, 0, BaseSchema, false, "Numéro de lien : pair pour le lien direct, impair pour le lien retour."),
            A("rangeLower", Integer, true, 0, BaseSchema, false, "Borne basse des valeurs ou des longueurs."),
            A("rangeUpper", Integer, true, 0, BaseSchema, false, "Borne haute des valeurs ou des longueurs."),
            A("isDefunct", Boolean, true, 0, BaseSchema, false, "Définition désactivée : elle ne sert plus à de nouveaux objets."),
            A("adminDescription", Unicode, true, 0, BaseSchema, false, "Description d’administration.", 0, 1024),
            A("schemaIDGUID", Octets, true, Index, BaseSchema, false, "GUID d’une définition du schéma, utilisé par les ACL.", 16, 16),
            A("governsID", ObjectId, true, Index, BaseSchema, true, "OID d’une classe."),
            A("subClassOf", ObjectId, true, 0, BaseSchema, false, "Classe parente."),
            A("mustContain", ObjectId, false, 0, BaseSchema, false, "Attributs obligatoires ajoutés à la classe."),
            A("mayContain", ObjectId, false, 0, BaseSchema, false, "Attributs facultatifs ajoutés à la classe."),
            A("systemMustContain", ObjectId, false, 0, BaseSchema, false, "Attributs obligatoires d’origine."),
            A("systemMayContain", ObjectId, false, 0, BaseSchema, false, "Attributs facultatifs d’origine."),
            A("auxiliaryClass", ObjectId, false, 0, BaseSchema, false, "Classes auxiliaires ajoutées."),
            A("systemAuxiliaryClass", ObjectId, false, 0, BaseSchema, false, "Classes auxiliaires d’origine."),
            A("possSuperiors", ObjectId, false, 0, BaseSchema, false, "Classes sous lesquelles l’objet peut être créé."),
            A("systemPossSuperiors", ObjectId, false, 0, BaseSchema, false, "Classes supérieures d’origine."),
            A("objectClassCategory", Integer, true, 0, BaseSchema, false, "Catégorie de la classe : structurelle, abstraite, auxiliaire ou 88."),
            A("defaultObjectCategory", Dn, true, 0, BaseSchema, false, "Catégorie donnée aux objets de la classe."),

            // ---------------------------------------------------------------- company extension « Example »
            A("exampleBadgeId", Unicode, true, Index, 0, false, "Numéro de badge d’accès (extension Example).", 1, 32),
            A("exampleCostCenter", Unicode, true, 0, 0, false, "Centre de coût (extension Example).", 1, 16),
            A("exampleSiteCode", Unicode, true, Index, 0, false, "Code du site de rattachement (extension Example).", 3, 8),
            A("exampleContractEnd", Time, true, 0, 0, false, "Fin de contrat (extension Example)."),
            A("exampleAssetTag", Unicode, true, Index | Tuple, 0, false, "Numéro d’inventaire du matériel (extension Example).", 1, 32),
            A("exampleLegacyHrId", Unicode, true, 0, 0, false, "Ancien identifiant RH, désactivé en 2024 (extension Example).", 1, 16, defunct: true),
        };
        for (var i = 1; i <= 15; i++)
        {
            var n = i.ToString(CultureInfo.InvariantCulture);
            list.Add(A("extensionAttribute" + n, Unicode, true, 0, 0, true, "Attribut personnalisé n° " + n + " (Exchange).", 1, 1024));
        }
        for (var i = 1; i <= 20; i++)
        {
            var n = i.ToString(CultureInfo.InvariantCulture);
            list.Add(A("msDS-cloudExtensionAttribute" + n, Unicode, true, 0, 0, false, "Attribut d’extension infonuagique n° " + n + ".", 1, 1024));
        }
        return [.. list];
    }

    private static SchemaClassDefinition C(
        string name, int category, string subClassOf, string description, string[]? must = null, string[]? may = null, string[]? auxiliary = null,
        bool defunct = false, string? oid = null) =>
        new(name, description, oid, subClassOf, [.. auxiliary ?? []], [.. must ?? []], [.. may ?? []], category, defunct);

    private static ImmutableArray<SchemaClassDefinition> BuildClasses()
    {
        string[] extensionAttributes = [.. Enumerable.Range(1, 15).Select(i => "extensionAttribute" + i.ToString(CultureInfo.InvariantCulture))];
        string[] cloudAttributes = [.. Enumerable.Range(1, 20).Select(i => "msDS-cloudExtensionAttribute" + i.ToString(CultureInfo.InvariantCulture))];
        return
        [
            C("top", 2, "top", "Classe racine : tout objet en hérite.",
                ["objectClass", "objectCategory", "nTSecurityDescriptor", "instanceType"],
                ["name", "cn", "description", "distinguishedName", "whenCreated", "whenChanged", "uSNCreated", "uSNChanged", "objectGUID", "showInAdvancedViewOnly",
                 "isCriticalSystemObject", "systemFlags", "canonicalName", "createTimeStamp", "modifyTimeStamp", "allowedAttributes", "allowedChildClasses",
                 "msDS-ReplAttributeMetaData", "msDS-parentdistname", "memberOf", "managedObjects", "adminDescription", "wellKnownObjects", "fSMORoleOwner",
                 "msDS-HostServiceAccountBL", "serverReferenceBL", "siteObjectBL", "msTPM-TpmInformationForComputerBL", "msDS-PSOApplied", "directReports"],
                oid: "2.5.6.0"),
            C("person", 0, "top", "Personne (X.500, 1988) : nom commun et téléphone.", ["cn"], ["sn", "telephoneNumber", "seeAlso"], oid: "2.5.6.6"),
            C("organizationalPerson", 0, "person", "Personne d’une organisation : fonction, service, adresse, responsable.", null,
                ["givenName", "initials", "displayName", "title", "department", "company", "physicalDeliveryOfficeName", "streetAddress", "l", "st", "postalCode",
                 "c", "co", "countryCode", "mobile", "ipPhone", "otherTelephone", "facsimileTelephoneNumber", "manager", "mail", "thumbnailPhoto"],
                oid: "2.5.6.7"),
            C("user", 1, "organizationalPerson", "Compte d’utilisateur du domaine.", null,
                ["userPrincipalName", "userAccountControl", "pwdLastSet", "accountExpires", "lastLogon", "lastLogonTimestamp", "lastLogoff", "logonCount", "badPwdCount",
                 "badPasswordTime", "lockoutTime", "logonHours", "userWorkstations", "scriptPath", "profilePath", "homeDirectory", "homeDrive", "primaryGroupID",
                 "employeeID", "employeeNumber", "employeeType", "unicodePwd", "userCertificate", "servicePrincipalName", "msDS-SupportedEncryptionTypes",
                 "msDS-AllowedToDelegateTo", "msDS-AllowedToActOnBehalfOfOtherIdentity", "msDS-KeyCredentialLink", "msDS-User-Account-Control-Computed",
                 "msDS-UserPasswordExpiryTimeComputed", "msDS-ResultantPSO", "adminCount", "info", .. cloudAttributes],
                ["securityPrincipal", "mailRecipient", "posixAccount", "examplePersonExt"], oid: "1.2.840.113556.1.5.9"),
            C("inetOrgPerson", 1, "user", "Personne au format inetOrgPerson (RFC 2798).", null, ["jpegPhoto", "uid"], oid: "2.16.840.1.113730.3.2.2"),
            C("computer", 1, "user", "Compte d’ordinateur : poste, serveur ou contrôleur.", null,
                ["dNSHostName", "operatingSystem", "operatingSystemVersion", "operatingSystemServicePack", "operatingSystemHotfix", "location", "networkAddress",
                 "managedBy", "ms-Mcs-AdmPwd", "ms-Mcs-AdmPwdExpirationTime", "msLAPS-Password", "msLAPS-EncryptedPassword", "msLAPS-EncryptedPasswordHistory",
                 "msLAPS-PasswordExpirationTime", "msTPM-OwnerInformation", "msTPM-TpmInformationForComputer", "msDS-HostServiceAccount"],
                ["ipHost", "exampleAssetExt"], oid: "1.2.840.113556.1.3.30"),
            C("msDS-ManagedServiceAccount", 1, "computer", "Compte de service géré, propre à un serveur.", null, ["msDS-ManagedPasswordInterval"]),
            C("msDS-GroupManagedServiceAccount", 1, "computer", "Compte de service géré de groupe (gMSA).", ["msDS-ManagedPasswordInterval"],
                ["msDS-ManagedPassword", "msDS-GroupMSAMembership"]),
            C("contact", 1, "organizationalPerson", "Contact de messagerie, sans compte ni mot de passe.", ["cn"], ["info"], ["mailRecipient"], oid: "1.2.840.113556.1.5.15"),
            C("group", 1, "top", "Groupe de sécurité ou de distribution.", ["groupType"],
                ["member", "managedBy", "mail", "info", "displayName", "primaryGroupToken", "adminCount"], ["securityPrincipal", "mailRecipient", "posixGroup"],
                oid: "1.2.840.113556.1.5.8"),
            C("securityPrincipal", 3, "top", "Principal de sécurité : SID et nom de compte.", ["objectSid", "sAMAccountName"],
                ["sIDHistory", "tokenGroups", "sAMAccountType", "msDS-PrincipalName"], oid: "1.2.840.113556.1.5.6"),
            C("mailRecipient", 3, "top", "Destinataire de messagerie.", ["cn"],
                ["proxyAddresses", "legacyExchangeDN", "info", "userCertificate", "telephoneNumber", .. extensionAttributes], oid: "1.2.840.113556.1.3.46"),
            C("posixAccount", 3, "top", "Identité Unix d’un compte (RFC 2307).", null, ["uid", "uidNumber", "gidNumber", "unixHomeDirectory", "loginShell", "unixUserPassword"]),
            C("posixGroup", 3, "top", "Identité Unix d’un groupe (RFC 2307).", null, ["gidNumber", "memberUid", "unixUserPassword"]),
            C("ipHost", 3, "top", "Hôte IP (RFC 2307).", null, ["ipHostNumber"]),
            C("examplePersonExt", 3, "top", "Extension Example des personnes : badge, centre de coût, site, fin de contrat.", null,
                ["exampleBadgeId", "exampleCostCenter", "exampleSiteCode", "exampleContractEnd", "exampleLegacyHrId"]),
            C("exampleAssetExt", 3, "top", "Extension Example des ordinateurs : inventaire et site.", null, ["exampleAssetTag", "exampleSiteCode"]),
            C("exampleLegacyAsset", 1, "top", "Ancien matériel de l’extension Example, désactivé en 2024.", ["cn"], ["exampleAssetTag"], defunct: true),
            C("organizationalUnit", 1, "top", "Unité d’organisation : délégation d’administration et stratégies.", ["ou"],
                ["managedBy", "gPLink", "gPOptions", "l", "st", "postalCode", "c", "co", "countryCode", "seeAlso", "telephoneNumber"], oid: "2.5.6.5"),
            C("container", 1, "top", "Conteneur générique (CN=Users, CN=Computers…).", ["cn"], null, oid: "1.2.840.113556.1.3.23"),
            C("builtinDomain", 1, "top", "Domaine intégré (CN=Builtin) : groupes locaux du domaine.", null, null, ["samDomainBase"]),
            C("domain", 2, "top", "Domaine (classe abstraite).", ["dc"]),
            C("domainDNS", 1, "domain", "Racine d’un domaine Active Directory.", null,
                ["msDS-Behavior-Version", "gPLink", "gPOptions", "managedBy"], ["samDomain"], oid: "1.2.840.113556.1.5.67"),
            C("samDomain", 3, "top", "Paramètres SAM d’un domaine.", null, null, ["samDomainBase"]),
            C("samDomainBase", 3, "top", "Stratégie de mots de passe et de verrouillage du domaine.", null,
                ["maxPwdAge", "minPwdLength", "pwdHistoryLength", "pwdProperties", "lockoutThreshold", "lockoutDuration", "lockOutObservationWindow", "objectSid"]),
            C("foreignSecurityPrincipal", 1, "top", "Principal d’un domaine approuvé, membre d’un groupe local.", ["objectSid"]),
            C("groupPolicyContainer", 1, "container", "Objet de stratégie de groupe.", null,
                ["displayName", "gPCFileSysPath", "flags", "versionNumber", "gPCMachineExtensionNames", "gPCUserExtensionNames", "gPCFunctionalityVersion"]),
            C("msDS-PasswordSettings", 1, "top", "Stratégie de mots de passe affinée (PSO).",
                ["msDS-PasswordSettingsPrecedence", "msDS-MinimumPasswordLength", "msDS-PasswordHistoryLength", "msDS-LockoutThreshold", "msDS-MaximumPasswordAge"],
                ["msDS-PSOAppliesTo"]),
            C("msDS-PasswordSettingsContainer", 1, "top", "Conteneur des stratégies de mots de passe affinées."),
            C("leaf", 2, "top", "Objet feuille (classe abstraite)."),
            C("connectionPoint", 2, "leaf", "Point de connexion publié (classe abstraite).", ["cn"], ["keywords"]),
            C("serviceConnectionPoint", 1, "connectionPoint", "Point de connexion d’un service publié dans l’annuaire.", null, ["serviceBindingInformation", "serviceDNSName"]),
            C("printQueue", 1, "connectionPoint", "File d’impression publiée.", ["printerName", "serverName", "uNCName", "versionNumber"], ["driverName", "location"]),
            C("volume", 1, "connectionPoint", "Dossier partagé publié.", ["uNCName"]),
            C("msFVE-RecoveryInformation", 1, "top", "Informations de récupération BitLocker, sous l’objet ordinateur.", ["msFVE-RecoveryPassword", "msFVE-RecoveryGuid"],
                ["msFVE-VolumeGuid", "msFVE-KeyPackage"]),
            C("msTPM-InformationObject", 1, "top", "Informations de la puce TPM d’un ordinateur.", null, ["msTPM-OwnerInformation"]),
            C("site", 1, "top", "Site Active Directory.", null, ["location", "gPLink", "gPOptions"]),
            C("subnet", 1, "top", "Sous-réseau IP rattaché à un site.", null, ["location", "siteObject"]),
            C("server", 1, "top", "Serveur d’un site (contrôleur de domaine).", null, ["dNSHostName", "serverReference"]),
            C("applicationSettings", 2, "top", "Paramètres d’application (classe abstraite)."),
            C("nTDSDSA", 1, "applicationSettings", "Paramètres NTDS d’un contrôleur de domaine.", null, ["options"]),
            C("trustedDomain", 1, "leaf", "Relation d’approbation avec un autre domaine.", null,
                ["trustPartner", "trustDirection", "trustType", "trustAttributes", "flatName"]),
            C("crossRef", 1, "top", "Référence croisée d’une partition de la forêt.", ["nCName"], ["dnsRoot", "nETBIOSName"]),
            C("dynamicObject", 3, "top", "Objet à durée de vie limitée.", null, ["entryTTL", "msDS-Entry-Time-To-Die"]),
            C("dMD", 1, "top", "Conteneur du schéma (CN=Schema).", null, null),
            C("classSchema", 1, "top", "Définition d’une classe du schéma.", ["cn", "governsID", "subClassOf", "objectClassCategory", "defaultObjectCategory"],
                ["lDAPDisplayName", "mustContain", "mayContain", "systemMustContain", "systemMayContain", "auxiliaryClass", "systemAuxiliaryClass", "possSuperiors",
                 "systemPossSuperiors", "isDefunct", "schemaIDGUID"]),
            C("attributeSchema", 1, "top", "Définition d’un attribut du schéma.", ["cn", "attributeID", "attributeSyntax", "oMSyntax", "isSingleValued"],
                ["lDAPDisplayName", "searchFlags", "isMemberOfPartialAttributeSet", "linkID", "rangeLower", "rangeUpper", "isDefunct", "schemaIDGUID"]),
        ];
    }
}
