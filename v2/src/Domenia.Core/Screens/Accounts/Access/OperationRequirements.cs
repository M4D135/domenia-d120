using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>One operation of Domenia and what it needs: resource, account, right and network access (CPT-019).</summary>
public sealed record OperationRequirement(
    string Id,
    string Label,
    string Family,
    string Provider,
    string Effect,
    string EffectLabel,
    string Resource,
    string ResourceLabel,
    string Account,
    string Right,
    string Access,
    bool Known);

/// <summary>Result of accounts.requirements: the reference table and its families.</summary>
public sealed record OperationRequirementTable(ImmutableArray<OperationRequirement> Rows, ImmutableArray<string> Families, string UnknownText);

/// <summary>
/// Rights, accounts and ports required by each operation (Domenia 1 point 46, Get-DomeniaOperationRequirement, over the single
/// classification of the operations, Get-DomeniaOperationTable): stated before any call and quoted after a failure. An
/// operation outside the table says its right is not documented; a right is never guessed. Pure, constant.
/// </summary>
public static class OperationRequirements
{
    public const string UnknownText = "Droit non documenté pour cette opération\u00A0: lisez le code d’erreur natif.";

    private const string Ldap = "LDAP 389/TCP vers le contrôleur de domaine (signature et scellement).";
    private const string Cim = "CIM/DCOM\u00A0: 135/TCP puis ports RPC dynamiques du poste\u00A0; WSMan 5985/5986 seulement s’il est déjà en service.";
    private const string EventLog = "Journal d’événements à distance\u00A0: 135/TCP puis ports RPC dynamiques du contrôleur.";
    private const string Connection = "Compte de connexion";
    private const string Machine = "Compte poste, sinon compte de connexion";
    private const string Secrets = "Compte secrets, sinon compte de connexion";
    private const string DirectoryRead = "Lecture de l’annuaire\u00A0: tout compte authentifié du domaine lit les attributs ordinaires\u00A0; un attribut confidentiel exige un droit délégué.";
    private const string WorkstationRead = "Administrateur local du poste, ou droits WMI délégués (activation DCOM à distance et lecture de root\\cimv2).";

    /// <summary>Operation table of Domenia 1: identifier, provider, effect, resource and French label.</summary>
    private static readonly (string Id, string Provider, string Effect, string Resource, string Label)[] Table =
    [
        ("AccountAliasRead", "Directory", "Read", "Directory", "Autres noms d’un compte (même SID)"),
        ("AdConsistencyScan", "Directory", "Read", "Directory", "Contrôle de cohérence de l’annuaire"),
        ("AdHealthRead", "Directory", "Read", "Directory", "Santé de l’annuaire"),
        ("AdSchemaRead", "Directory", "Read", "Directory", "Lecture du schéma"),
        ("BatchNetworkDiag", "Cim", "Read", "Remote", "Diagnostic réseau d’une liste de postes"),
        ("BitLockerPresence", "Directory", "Read", "BitLocker", "Présence des clés BitLocker d’une OU"),
        ("CmdletHelp", "Local", "Read", "Local", "Aide des commandes"),
        ("CmdletInventory", "Local", "Read", "Local", "Inventaire des commandes"),
        ("ComputerAdminShare", "Network", "Read", "Remote", "Partage administratif C$ d’un poste"),
        ("ComputerDiagnostics", "Cim", "Read", "Remote", "Diagnostic d’un poste"),
        ("ComputerGpUpdate", "Cim", "RemoteMutation", "Remote", "Mise à jour des stratégies d’un poste"),
        ("ComputerInventory", "Cim", "Read", "Remote", "Inventaire d’un poste"),
        ("ComputerLastUser", "Cim", "Read", "Remote", "Dernier utilisateur d’un poste"),
        ("ComputerPing", "Network", "Read", "Remote", "Ping d’un poste"),
        ("ComputerRestart", "Cim", "RemoteMutation", "Remote", "Redémarrage d’un poste"),
        ("ComputerServiceControl", "Cim", "RemoteMutation", "Remote", "Démarrage ou redémarrage d’un service"),
        ("DcServicesRead", "Cim", "Read", "Remote", "Services d’un contrôleur"),
        ("DnsReverseLookup", "Network", "Read", "Network", "Recherche inverse dans le DNS"),
        ("DelegationRead", "Directory", "Read", "Directory", "Délégations de l’annuaire"),
        ("DemoDirectory", "Local", "Read", "Local", "Annuaire de démonstration"),
        ("DirectoryAbsenceCheck", "Directory", "Read", "Directory", "Vérification d’absence dans l’annuaire"),
        ("DocumentStore", "Storage", "LocalWrite", "Local", "Enregistrement d’un document"),
        ("DomainOverview", "Directory", "Read", "Directory", "Vue du domaine"),
        ("EmbeddedDirectoryLookup", "Directory", "Read", "Directory", "Recherche intégrée dans l’annuaire"),
        ("EmbeddedPathBrowse", "Local", "Read", "Local", "Parcours de dossiers locaux"),
        ("EngineSelfTest", "Local", "Read", "Local", "Autotest du moteur"),
        ("GlobalSearch", "Directory", "Read", "Directory", "Recherche dans l’annuaire"),
        ("GpoAppliedRead", "Cim", "Read", "Remote", "Stratégies appliquées à un poste"),
        ("GpoLinksRead", "Directory", "Read", "Directory", "Liens des stratégies de groupe"),
        ("GroupPathRead", "Directory", "Read", "Directory", "Chemin d’appartenance aux groupes"),
        ("IndexBuild", "Directory", "LocalWrite", "Directory", "Copie locale de l’annuaire"),
        ("IndexOuList", "Directory", "Read", "Directory", "Liste des OU"),
        ("IsolatedRead", "Local", "Unknown", "Local", "Lecture isolée hors processus"),
        ("LegacyMigration", "Storage", "LocalWrite", "Local", "Migration d’une ancienne base"),
        ("LiveCache", "Storage", "LocalWrite", "Local", "Cache des consoles"),
        ("LiveConsole", "Cim", "Read", "Remote", "Console en direct d’un poste"),
        ("LiveDirectoryCheck", "Directory", "Read", "Directory", "Vérification en direct dans l’annuaire"),
        ("LiveSelectedPing", "Network", "Read", "Network", "Ping de la sélection"),
        ("LocalIndexRead", "Storage", "Read", "Local", "Lecture de la base locale"),
        ("LocalQuery", "Storage", "Read", "Local", "Requête sur la base locale"),
        ("LocalStore", "Storage", "LocalWrite", "Local", "Écriture dans la base locale"),
        ("LockoutDiagnosis", "Directory", "Read", "Directory", "Lecture des verrouillages (4740)"),
        ("LogonByDcRead", "Directory", "Read", "Directory", "Dernières connexions par contrôleur"),
        ("LogonHarvest", "Directory", "Read", "Directory", "Collecte des ouvertures de session"),
        ("MachineIdentityRead", "Cim", "Read", "Remote", "Identité d’un poste"),
        ("OfflineDossier", "Local", "LocalWrite", "Local", "Dossier hors ligne"),
        ("OpenAdObject", "Directory", "Read", "Directory", "Lecture d’une fiche"),
        ("OpenLinkedObject", "Directory", "Read", "Directory", "Lecture d’un objet lié"),
        ("ParkPing", "Network", "Read", "Network", "Ping d’une liste de postes"),
        ("ParkSharedSync", "Network", "RemoteMutation", "Network", "Synchronisation du parc partagé"),
        ("ParkSweep", "Cim", "Read", "Remote", "Relevé du parc"),
        ("PasswordPolicyRead", "Directory", "Read", "Directory", "Stratégie de mot de passe"),
        ("PermissionAnalysis", "Directory", "Read", "Directory", "Analyse des autorisations d’un objet"),
        ("PresenceScan", "Network", "Read", "Network", "Relevé de présence"),
        ("PruneLinks", "Directory", "Read", "Directory", "Nettoyage des associations"),
        ("QueryExport", "Storage", "LocalWrite", "Local", "Export d’une requête"),
        ("QueryLibrary", "Storage", "Read", "Local", "Bibliothèque de requêtes"),
        ("QueryTransfer", "Storage", "LocalWrite", "Local", "Import ou export de requêtes"),
        ("ReadBitLocker", "Directory", "Read", "BitLocker", "Lecture des clés BitLocker"),
        ("ReadBitLockerKey", "Directory", "Read", "BitLocker", "Lecture d’une clé BitLocker"),
        ("ReadBitLockerList", "Directory", "Read", "BitLocker", "Liste des clés BitLocker"),
        ("ReadLaps", "Directory", "Read", "Laps", "Lecture du mot de passe LAPS"),
        ("ReceiptStore", "Storage", "LocalWrite", "Local", "Reçus d’écriture"),
        ("RelationHistoryRead", "Storage", "Read", "Local", "Historique des associations"),
        ("RemoteCredentialCheck", "Cim", "Read", "Remote", "Vérification d’un compte sur un poste"),
        ("RimotteRun", "Cim", "RemoteMutation", "Remote", "Intervention scriptée sur un poste"),
        ("ScopeReconcile", "Directory", "Read", "Directory", "Rapprochement du périmètre"),
        ("SelectedPresence", "Network", "Read", "Network", "Présence de la sélection"),
        ("SelfCheck", "Directory", "Read", "Directory", "Vérification de l’application"),
        ("SessionsList", "Wts", "Read", "Remote", "Sessions Windows d’un poste"),
        ("SoftwareInventory", "Cim", "Read", "Remote", "Logiciels d’un poste"),
        ("StartupWarmCache", "Directory", "Read", "Directory", "Préchargement au démarrage"),
        ("StorageBackup", "Storage", "LocalWrite", "Local", "Sauvegarde de la base"),
        ("StorageIntegrity", "Storage", "Read", "Local", "Intégrité de la base"),
        ("StorageMaintenance", "Storage", "LocalWrite", "Local", "Maintenance de la base"),
        ("StoragePurge", "Storage", "LocalWrite", "Local", "Purge de la base"),
        ("StorageUsage", "Storage", "Read", "Local", "Occupation de la base"),
        ("TreeChildren", "Directory", "Read", "Directory", "Arborescence des OU"),
        ("UserComputerProbe", "Cim", "Read", "Remote", "Postes d’un utilisateur"),
        ("WmiClasses", "Cim", "Read", "Remote", "Classes WMI d’un poste"),
        ("WmiNamespaces", "Cim", "Read", "Remote", "Espaces de noms WMI d’un poste"),
        ("WmiQuery", "Cim", "Read", "Remote", "Requête WMI sur un poste"),
        ("WriteAccountDisabled", "Directory", "DirectoryWrite", "Directory", "Activer ou désactiver un compte"),
        ("WriteAccountOptions", "Directory", "DirectoryWrite", "Directory", "Options de sécurité d’un compte"),
        ("WriteAttributes", "Directory", "DirectoryWrite", "Directory", "Modification d’attributs"),
        ("WriteCreateOu", "Directory", "DirectoryWrite", "Directory", "Création d’une OU"),
        ("WriteDeleteObject", "Directory", "DirectoryWrite", "Directory", "Suppression d’un objet"),
        ("WriteExpiration", "Directory", "DirectoryWrite", "Directory", "Expiration d’un compte"),
        ("WriteExpirePassword", "Directory", "DirectoryWrite", "Directory", "Imposer un nouveau mot de passe"),
        ("WriteGroupMember", "Directory", "DirectoryWrite", "Directory", "Membres d’un groupe"),
        ("WriteMoveObject", "Directory", "DirectoryWrite", "Directory", "Déplacement d’un objet"),
        ("WriteObjectGroup", "Directory", "DirectoryWrite", "Directory", "Groupes d’un objet"),
        ("WriteRenameComputer", "Directory", "DirectoryWrite", "Directory", "Renommage d’un ordinateur"),
        ("WriteResetPassword", "Directory", "DirectoryWrite", "Directory", "Réinitialisation d’un mot de passe"),
        ("WriteUnlock", "Directory", "DirectoryWrite", "Directory", "Déverrouillage d’un compte"),
        ("ComputerEventsRead", "Cim", "Read", "Directory", "Événements d’un poste"),
        ("ComputerQuickDiag", "Cim", "Read", "Directory", "Diagnostic rapide d’un poste"),
        ("ConnectorRead", "Network", "Read", "Network", "Lecture d’un connecteur"),
        ("DcCompareRead", "Directory", "Read", "Directory", "Comparaison des contrôleurs"),
        ("IndexRefresh", "Directory", "LocalWrite", "Directory", "Actualisation de la copie locale"),
        ("JoinStateRead", "Cim", "Read", "Directory", "État de jonction d’un poste"),
        ("LinkHistoryStore", "Storage", "LocalWrite", "Directory", "Historique des liens"),
        ("LocalAssistant", "Local", "Unknown", "Directory", "Assistant local"),
        ("ObjectChanges", "Directory", "Read", "Directory", "Changements d’un objet"),
        ("QuerySchema", "Cim", "Read", "Remote", "Schéma d’une requête WMI"),
        ("WidgetWmiDetail", "Cim", "Read", "Remote", "Détail WMI d’un widget"),
        ("ReconcileScope", "Directory", "Read", "Directory", "Rapprochement d’une OU"),
        ("StartupWarmup", "Directory", "Read", "Directory", "Préparation au démarrage"),
        ("StorageRetention", "Storage", "LocalWrite", "Local", "Conservation des données"),
        ("UpdateStateRead", "Cim", "Read", "Directory", "État des mises à jour d’un poste"),
        ("WakeOnLanSend", "Network", "RemoteMutation", "Network", "Réveil d’un poste par le réseau"),
    ];

    /// <summary>Rows whose right differs from their family (resource, account, right, access).</summary>
    private static readonly FrozenDictionary<string, (string Resource, string Account, string Right, string Access)> Specific = new Dictionary<string, (string, string, string, string)>(StringComparer.Ordinal)
    {
        ["PermissionAnalysis"] = ("Directory", Connection, "Lecture du descripteur de sécurité de l’objet (Lire les autorisations).", Ldap),
        ["LogonHarvest"] = ("Directory", Connection, "Lecture du journal Sécurité du contrôleur\u00A0: membre du groupe Lecteurs des journaux d’événements du contrôleur, ou administrateur du domaine.", EventLog),
        ["LockoutDiagnosis"] = ("Directory", Connection, "Lecture du journal Sécurité de l’émulateur PDC\u00A0: membre du groupe Lecteurs des journaux d’événements du contrôleur, ou administrateur du domaine.", EventLog),
        ["ReadLaps"] = ("Laps", Secrets, "Lecture de l’attribut du mot de passe LAPS de l’ordinateur (ms-LAPS-Password ou ms-Mcs-AdmPwd)\u00A0; pour Windows LAPS chiffré, membre des déchiffreurs autorisés.", Ldap),
        ["ReadBitLocker"] = ("BitLocker", Secrets, "Lecture des objets de récupération BitLocker sous l’ordinateur (droit délégué\u00A0; réservé par défaut aux administrateurs du domaine).", Ldap),
        ["ReadBitLockerList"] = ("BitLocker", Secrets, "Lecture des objets de récupération BitLocker sous l’ordinateur (droit délégué\u00A0; réservé par défaut aux administrateurs du domaine).", Ldap),
        ["BitLockerPresence"] = ("BitLocker", Secrets, "Lecture des objets de récupération BitLocker de l’OU (droit délégué\u00A0; réservé par défaut aux administrateurs du domaine).", Ldap),
        ["ReadBitLockerKey"] = ("BitLocker", Secrets, "Lecture de l’attribut confidentiel msFVE-RecoveryPassword de la clé choisie (droit de contrôle d’accès étendu).", Ldap),
        ["UserComputerProbe"] = ("Remote", Machine, "Annuaire lu avec le compte de connexion\u00A0; consoles des postes\u00A0: administrateur local ou droits WMI délégués\u00A0; journal Sécurité du contrôleur, sur demande\u00A0: Lecteurs des journaux d’événements.", Cim),
        ["RemoteCredentialCheck"] = ("Remote", "Compte proposé", "Ouverture d’une session CIM/DCOM sur le poste avec le compte proposé\u00A0: administrateur local ou droits WMI délégués.", Cim),
        ["SessionsList"] = ("Remote", Machine, "Énumération des sessions Windows du poste\u00A0: administrateur local.", "RPC et SMB 445/TCP vers le poste."),
        ["ComputerAdminShare"] = ("Remote", Machine, "Accès au partage administratif du poste\u00A0: administrateur local.", "SMB 445/TCP vers le poste."),
        ["ComputerGpUpdate"] = ("Remote", Machine, "Exécution distante sur le poste\u00A0: administrateur local, WinRM déjà en service sur le poste.", "WinRM 5985/TCP ou 5986/TCP vers le poste."),
        ["ComputerRestart"] = ("Remote", Machine, "Redémarrage à distance\u00A0: administrateur local du poste (privilège Forcer l’arrêt à partir d’un système distant).", Cim),
        ["ComputerServiceControl"] = ("Remote", Machine, "Démarrage ou redémarrage d’un service du poste par CIM (Win32_Service)\u00A0: administrateur local du poste, droit de contrôle du service.", Cim),
        ["RimotteRun"] = ("Remote", Machine, "Intervention scriptée\u00A0: administrateur local du poste et autorisation explicite et temporaire dans Domenia (Assistance poste, Intervenir).", "SMB 445/TCP (ADMIN$) et Planificateur de tâches par RPC."),
        ["BatchNetworkDiag"] = ("Network", "Aucun compte", "Aucun droit\u00A0: écho ICMP puis tentative de connexion TCP sur les ports 445, 135, 5985 et 5986\u00A0; le pare-feu du poste doit les laisser passer.", "ICMP écho et TCP 445, 135, 5985, 5986 vers chaque poste."),
        ["WakeOnLanSend"] = ("Network", "Aucun compte", "Aucun droit\u00A0: paquet de réveil diffusé sur le réseau local\u00A0; la carte réseau du poste doit accepter le réveil.", "Diffusion UDP sur le réseau local."),
        ["ParkSharedSync"] = ("Network", "Session Windows", "Lecture et écriture du fichier partagé configuré (droits NTFS et de partage de votre session Windows).", "SMB 445/TCP vers le partage, ou disque local."),
        ["ConnectorRead"] = ("Network", "Session Windows", "Lecture du connecteur configuré avec votre session Windows.", "Selon le connecteur configuré."),
        ["ReceiptStore"] = ("Local", "Aucun compte distant", "Reçus locaux d’écriture dans votre profil Windows\u00A0: aucun droit dans l’annuaire ni sur les postes.", "Aucun accès réseau."),
        ["WriteAttributes"] = ("Directory", Connection, "Écriture de chaque attribut modifié sur l’objet (Écrire la propriété, délégué ou hérité).", Ldap),
        ["WriteResetPassword"] = ("Directory", Connection, "Droit étendu Réinitialiser le mot de passe sur l’objet\u00A0; écriture de pwdLastSet quand le changement est imposé.", Ldap),
        ["WriteUnlock"] = ("Directory", Connection, "Écriture de lockoutTime sur le compte (droit délégué de déverrouillage).", Ldap),
        ["WriteAccountDisabled"] = ("Directory", Connection, "Écriture de userAccountControl sur le compte.", Ldap),
        ["WriteAccountOptions"] = ("Directory", Connection, "Écriture de userAccountControl sur le compte.", Ldap),
        ["WriteExpiration"] = ("Directory", Connection, "Écriture de accountExpires sur le compte.", Ldap),
        ["WriteExpirePassword"] = ("Directory", Connection, "Écriture de pwdLastSet sur le compte.", Ldap),
        ["WriteGroupMember"] = ("Directory", Connection, "Écriture de l’attribut member du groupe (Écrire les membres).", Ldap),
        ["WriteObjectGroup"] = ("Directory", Connection, "Écriture de l’attribut member de chaque groupe modifié (Écrire les membres).", Ldap),
        ["WriteMoveObject"] = ("Directory", Connection, "Supprimer l’objet dans son OU d’origine et créer ce type d’objet dans l’OU cible.", Ldap),
        ["WriteRenameComputer"] = ("Directory", Connection, "Renommer l’objet ordinateur (écriture de son nom) dans son OU.", Ldap),
        ["WriteCreateOu"] = ("Directory", Connection, "Créer des objets unité d’organisation dans l’OU parente.", Ldap),
        ["WriteDeleteObject"] = ("Directory", Connection, "Supprimer l’objet (droit Supprimer sur l’objet, ou Supprimer l’enfant sur l’OU parente).", Ldap),
    }.ToFrozenDictionary(StringComparer.Ordinal);

    /// <summary>Directory reads whose right is the plain directory read.</summary>
    private static readonly FrozenSet<string> DirectoryReads = new[]
    {
        "GlobalSearch", "TreeChildren", "OpenAdObject", "OpenLinkedObject", "LiveDirectoryCheck", "ScopeReconcile", "ReconcileScope", "IndexBuild", "IndexRefresh", "IndexOuList",
        "DomainOverview", "SelfCheck", "EmbeddedDirectoryLookup", "StartupWarmCache", "StartupWarmup", "PruneLinks", "ObjectChanges", "PasswordPolicyRead", "GroupPathRead",
        "GpoLinksRead", "DcCompareRead", "AdConsistencyScan", "AccountAliasRead",
    }.ToFrozenSet(StringComparer.Ordinal);

    /// <summary>Requirement of one operation (case sensitive identifier, like the table of Domenia 1); unknown: right not documented.</summary>
    public static OperationRequirement For(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        var row = Table.FirstOrDefault(r => string.Equals(r.Id, id.Trim(), StringComparison.Ordinal));
        if (row.Id is null)
        {
            return new OperationRequirement(id.Trim(), id.Trim(), "Autre", "", "Unknown", EffectLabel("Unknown"), "", "", "", UnknownText, "", false);
        }
        (string Resource, string Account, string Right, string Access)? found = null;
        if (Specific.TryGetValue(row.Id, out var specific))
        {
            found = specific;
        }
        else if (DirectoryReads.Contains(row.Id))
        {
            found = ("Directory", Connection, DirectoryRead, Ldap);
        }
        else if (row.Provider is "Cim" or "Wts")
        {
            found = ("Remote", Machine, WorkstationRead, Cim);
        }
        else if (row.Provider == "Network")
        {
            found = ("Network", "Aucun compte", "Aucun droit\u00A0: écho ICMP vers le poste\u00A0; son pare-feu doit le laisser passer.", "ICMP écho vers le poste.");
        }
        else if (row.Provider is "Storage" or "Local")
        {
            found = ("Local", "Aucun compte distant", "Fichiers locaux de votre profil Windows\u00A0: aucun droit dans l’annuaire ni sur les postes.", "Aucun accès réseau.");
        }
        else if (row.Effect == "Read")
        {
            found = ("Directory", Connection, DirectoryRead, Ldap);
        }
        else if (row.Effect == "DirectoryWrite")
        {
            found = ("Directory", Connection, "Écriture sur l’objet\u00A0: droit délégué correspondant à chaque attribut modifié.", Ldap);
        }
        if (found is not { } f)
        {
            return new OperationRequirement(row.Id, row.Label, Family(row.Provider), row.Provider, row.Effect, EffectLabel(row.Effect), "", "", "", UnknownText, "", false);
        }
        return new OperationRequirement(row.Id, row.Label, Family(row.Provider), row.Provider, row.Effect, EffectLabel(row.Effect), f.Resource, ResourceLabel(f.Resource), f.Account, f.Right, f.Access, true);
    }

    /// <summary>The whole reference table, ordered by family then label.</summary>
    public static OperationRequirementTable All()
    {
        var rows = Table.Select(r => For(r.Id))
            .OrderBy(r => FamilyOrder(r.Family)).ThenBy(r => FrenchText.Fold(r.Label), StringComparer.Ordinal)
            .ToImmutableArray();
        return new OperationRequirementTable(rows, [.. rows.Select(r => r.Family).Distinct(StringComparer.Ordinal)], UnknownText);
    }

    public static string EffectLabel(string effect) => effect switch
    {
        "Read" => "Lecture",
        "LocalWrite" => "Écriture locale",
        "DirectoryWrite" => "Écriture dans l’annuaire",
        "RemoteMutation" => "Action sur un poste",
        _ => "Effet inconnu (jamais traité comme une lecture)",
    };

    public static string ResourceLabel(string resource) => resource switch
    {
        "Directory" => "Annuaire",
        "Laps" => "Secrets LAPS",
        "BitLocker" => "Secrets BitLocker",
        "Remote" => "Postes",
        "Network" => "Réseau",
        "Local" => "Local",
        _ => resource,
    };

    private static string Family(string provider) => provider switch
    {
        "Directory" => "Annuaire",
        "Cim" or "Wts" => "Postes",
        "Network" => "Réseau",
        _ => "Local",
    };

    private static int FamilyOrder(string family) => family switch
    {
        "Annuaire" => 0,
        "Postes" => 1,
        "Réseau" => 2,
        "Local" => 3,
        _ => 4,
    };
}
