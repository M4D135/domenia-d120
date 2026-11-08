namespace Domenia.Core.Queries;

/// <summary>Operational questions with actual catalog fields. Collection criteria apply to the same instance.</summary>
public static partial class QueryTemplates
{
    private static QueryClause I(string probe, string property, QueryOperator op, QueryValue value) => C("instance:" + probe + ":" + property, op, value);
    private static QueryNode Any(string probe, params QueryClause[] clauses) => QueryNode.Collection("probe:" + probe, CollectionQuantifier.Any,
        clauses.Length == 1 ? QueryNode.Leaf(clauses[0]) : QueryNode.Group(QueryNodeKind.All, clauses.Select(QueryNode.Leaf)));

    private static void Operational(Builder b)
    {
        const QueryTarget pc = QueryTarget.Computer;
        const string bitlocker = "BitLocker · volumes et méthodes";
        const string volumes = "sec.bitlockervolumes";
        b.Add(pc, "ops.bitlocker.methods.c", "BitLocker C: · répartition des méthodes de chiffrement", bitlocker,
            "Une part par méthode du volume C: : XTS-AES 128, XTS-AES 256, autres méthodes et valeurs inconnues. Une méthode ne prouve pas que la protection est active.", groupBy: "probe:sec.bitlockermethodc");
        foreach (var method in new[] { (Code: 6, Name: "XTS-AES 128"), (Code: 7, Name: "XTS-AES 256") })
        {
            b.Add(pc, "ops.bitlocker.any.method" + method.Code, "BitLocker · au moins un volume en " + method.Name, bitlocker,
                "Compte les postes, une seule fois même si plusieurs volumes correspondent. L’algorithme et la protection active restent deux informations distinctes.",
                expression: Any(volumes, I(volumes, "EncryptionMethod", QueryOperator.Equal, N(method.Code))));
            b.Add(pc, "ops.bitlocker.c.method" + method.Code, "BitLocker C: · " + method.Name + " avec protection active", bitlocker,
                "La lettre C:, la méthode et la protection doivent être observées sur le même volume ; une clé visible dans AD ne remplace pas cette preuve.",
                expression: Any(volumes, I(volumes, "DriveLetter", QueryOperator.Equal, T("C:")), I(volumes, "EncryptionMethod", QueryOperator.Equal, N(method.Code)), I(volumes, "ProtectionStatus", QueryOperator.Equal, N(1))));
        }
        b.Add(pc, "ops.bitlocker.c.suspended", "BitLocker C: · volume chiffré, protection suspendue", bitlocker,
            "Volume C: entièrement chiffré (ConversionStatus=1) avec protection désactivée (ProtectionStatus=0), sans assimiler cela à un volume déchiffré.",
            expression: Any(volumes, I(volumes, "DriveLetter", QueryOperator.Equal, T("C:")), I(volumes, "ConversionStatus", QueryOperator.Equal, N(1)), I(volumes, "ProtectionStatus", QueryOperator.Equal, N(0))));
        b.Add(pc, "ops.bitlocker.c.method.parameter", "BitLocker · méthode et lettre de volume à choisir", bitlocker,
            "Recherche corrélée sur un même volume ; C: et XTS-AES 128 sont proposés et peuvent être modifiés.",
            parameters: [P("Volume", "instance:" + volumes + ":DriveLetter", T("C:"), "Lettre du volume"), P("Methode", "instance:" + volumes + ":EncryptionMethod", N(6), "Méthode de chiffrement", 0, 7)],
            expression: Any(volumes, I(volumes, "DriveLetter", QueryOperator.Equal, QueryValue.FromParameter("Volume")), I(volumes, "EncryptionMethod", QueryOperator.Equal, QueryValue.FromParameter("Methode"))));
        foreach (var state in new[] { (Code: 2, Name: "chiffrement en cours"), (Code: 3, Name: "déchiffrement en cours"), (Code: 4, Name: "chiffrement en pause"), (Code: 5, Name: "déchiffrement en pause") })
        {
            b.Add(pc, "ops.bitlocker.conversion" + state.Code, "BitLocker · au moins un volume avec " + state.Name, bitlocker,
                "État de conversion déclaré par Windows pour un volume visible, sans déduire l’achèvement à partir d’un pourcentage arrondi.", expression: Any(volumes, I(volumes, "ConversionStatus", QueryOperator.Equal, N(state.Code))));
        }
        b.Add(pc, "ops.bitlocker.ad.key.protectionoff", "BitLocker · clé AD visible et protection C: désactivée", bitlocker,
            "Croise la présence d’un objet de récupération visible dans AD avec l’état du disque ; ne lit aucun secret et ne conclut pas à un disque déchiffré.",
            [C("bitlocker", QueryOperator.Equal, T("K")), C("probe:sec.bitlocker", QueryOperator.Equal, T("Non protégé"))]);
        b.Add(pc, "ops.bitlocker.ad.nokey.protected", "BitLocker · C: protégé, aucune clé visible dans AD", bitlocker,
            "Signale une différence entre deux sources ; aucune clé visible ne prouve pas qu’aucune sauvegarde existe ailleurs.",
            [C("bitlocker", QueryOperator.Equal, T("N")), C("probe:sec.bitlocker", QueryOperator.Equal, T("Protégé"))]);

        OperationalServices(b);
        OperationalHardware(b);
        OperationalAccounts(b);

        const string apps = "soft.installed";
        b.Add(pc, "ops.software.name.vendor", "Applications · nom et éditeur à choisir", "Applications et démarrage",
            "Nom et éditeur doivent correspondre à la même application. Le fournisseur d’inventaire Windows peut ne pas couvrir toutes les installations par utilisateur ; aucun appel MSI.",
            parameters: [P("Application", "instance:" + apps + ":Name", T("Firefox"), "Partie du nom de l’application"), P("Editeur", "instance:" + apps + ":Vendor", T("Mozilla"), "Partie du nom de l’éditeur")],
            expression: Any(apps, I(apps, "Name", QueryOperator.Contains, QueryValue.FromParameter("Application")), I(apps, "Vendor", QueryOperator.Contains, QueryValue.FromParameter("Editeur"))));
        b.Add(pc, "ops.software.version", "Applications · nom et version exacte à choisir", "Applications et démarrage",
            "Compare la version textuelle exacte sur la même application, sans classement numérique trompeur des versions.",
            parameters: [P("Application", "instance:" + apps + ":Name", T("Votre application"), "Partie du nom de l’application"), P("Version", "instance:" + apps + ":Version", T("1.0"), "Version exacte à rechercher")],
            expression: Any(apps, I(apps, "Name", QueryOperator.Contains, QueryValue.FromParameter("Application")), I(apps, "Version", QueryOperator.Equal, QueryValue.FromParameter("Version"))));
        b.Add(pc, "ops.process.memory", "Processus · exécutable dépassant une mémoire à choisir", "Applications et démarrage",
            "Photographie du working set d’un exécutable précis, sans ligne de commande ni arguments ; ce n’est pas une mesure de fuite mémoire.",
            parameters: [P("Processus", "instance:soft.processdetails:Name", T("msedge.exe"), "Nom de l’exécutable"), P("Octets", "instance:soft.processdetails:WorkingSetSize", N(1073741824), "Mémoire résidente minimale en octets", 0)],
            expression: Any("soft.processdetails", I("soft.processdetails", "Name", QueryOperator.Equal, QueryValue.FromParameter("Processus")), I("soft.processdetails", "WorkingSetSize", QueryOperator.GreaterOrEqual, QueryValue.FromParameter("Octets"))));
        b.Add(pc, "ops.startup.name", "Démarrage · entrée contenant un nom à choisir", "Applications et démarrage", "Recherche le nom d’une entrée de démarrage visible, sans conserver commande ni arguments.",
            parameters: [P("Nom", "instance:soft.startupdetails:Name", T("Votre application"), "Nom d’entrée à rechercher")],
            expression: Any("soft.startupdetails", I("soft.startupdetails", "Name", QueryOperator.Contains, QueryValue.FromParameter("Nom"))));
        b.Add(pc, "ops.tasks.path", "Tâches planifiées · dossier à choisir", "Applications et démarrage", "Présence d’au moins une tâche visible dans un dossier choisi ; aucune action ni compte enregistré n’est lu, aucun résultat d’exécution n’est déduit.",
            parameters: [P("Dossier", "instance:soft.scheduledtasks:TaskPath", T("\\Microsoft\\Windows\\"), "Préfixe du dossier de tâches")],
            expression: Any("soft.scheduledtasks", I("soft.scheduledtasks", "TaskPath", QueryOperator.StartsWith, QueryValue.FromParameter("Dossier"))));
        b.Add(pc, "ops.hotfix.id", "Correctifs CBS · identifiant exact à choisir", "Windows et correctifs", "Présence du correctif choisi dans Win32_QuickFixEngineering ; cette liste ne constitue pas l’inventaire exhaustif des mises à jour.",
            parameters: [P("Correctif", "instance:soft.hotfixdetails:HotFixID", T("KB0000000"), "Identifiant KB à remplacer")],
            expression: Any("soft.hotfixdetails", I("soft.hotfixdetails", "HotFixID", QueryOperator.Equal, QueryValue.FromParameter("Correctif"))));
        b.Add(pc, "ops.sessions.noresponse", "Sessions · console connue après un ping sans réponse", "Sessions et présence", "Deux relevés datés différents : le nom de console antérieur ne prouve pas une présence actuelle et l’ICMP peut être filtré.",
            [C("user", QueryOperator.IsPresent, QueryValue.None), C("presence", QueryOperator.Equal, T("Sans réponse"))]);
        b.Add(pc, "ops.sessions.disabled", "Sessions · console connue sur un compte ordinateur désactivé", "Sessions et présence", "Rapproche l’état AD du compte ordinateur et un relevé console disponible ; examinez leurs dates avant toute conclusion.",
            [C("active", QueryOperator.Equal, B(false)), C("user", QueryOperator.IsPresent, QueryValue.None)]);
        b.Add(pc, "ops.windows.missinginventory", "Windows · comptes actifs sans version relevée sur le poste", "Windows et correctifs", "Distingue le système déclaré dans AD d’une version réellement lue sur le poste.",
            [C("active", QueryOperator.Equal, B(true)), C("observedRelease", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(pc, "ops.windows.version.models", "Windows · modèles matériels pour une version à choisir", "Windows et correctifs", "Répartit les modèles des postes possédant la version Windows relevée choisie ; les modèles inconnus restent visibles.",
            [C("observedRelease", QueryOperator.Contains, QueryValue.FromParameter("Version"))], groupBy: "model", parameters: [P("Version", "observedRelease", T("24H2"), "Version Windows relevée")]);
    }

    private static void OperationalServices(Builder b)
    {
        const string probe = "soft.servicedetails";
        const string category = "Services Windows";
        b.Add(QueryTarget.Computer, "ops.services.auto.stopped", "Services · démarrage automatique mais service arrêté", category,
            "Au moins un même service est déclaré Auto et Stopped. Un démarrage différé ou déclenché peut expliquer cet état ; aucun incident n’est affirmé.",
            expression: Any(probe, I(probe, "StartMode", QueryOperator.Equal, T("Auto")), I(probe, "State", QueryOperator.Equal, T("Stopped"))));
        b.Add(QueryTarget.Computer, "ops.services.named.state", "Services · nom et état à choisir", category,
            "Recherche un état sur le service exact ; les critères ne peuvent pas provenir de deux services différents.",
            parameters: [P("Service", "instance:" + probe + ":Name", T("Spooler"), "Nom court du service"), P("Etat", "instance:" + probe + ":State", T("Stopped"), "État Windows (Running, Stopped…)")],
            expression: Any(probe, I(probe, "Name", QueryOperator.Equal, QueryValue.FromParameter("Service")), I(probe, "State", QueryOperator.Equal, QueryValue.FromParameter("Etat"))));
        foreach (var service in new[] { (Name: "Spooler", Label: "Spouleur d’impression"), (Name: "W32Time", Label: "Heure Windows"), (Name: "MpsSvc", Label: "Pare-feu Windows"), (Name: "Dnscache", Label: "Client DNS"), (Name: "WinRM", Label: "Gestion distante WinRM"), (Name: "BITS", Label: "Transfert BITS") })
        {
            b.Add(QueryTarget.Computer, "ops.services.disabled." + service.Name.ToLowerInvariant(), service.Label + " · démarrage désactivé", category,
                "Mode Disabled du service nommé, distinct d’un simple arrêt ; vérifiez le besoin du poste et la stratégie appliquée.",
                expression: Any(probe, I(probe, "Name", QueryOperator.Equal, T(service.Name)), I(probe, "StartMode", QueryOperator.Equal, T("Disabled"))));
        }
    }

    private static void OperationalHardware(Builder b)
    {
        const QueryTarget pc = QueryTarget.Computer;
        b.Add(pc, "ops.disks.volume.free", "Volumes · lettre et espace libre minimal à choisir", "Stockage et matériel", "Espace libre en octets pour une lettre précise du même volume ; C: avec moins de 10 Gio libres proposé.",
            parameters: [P("Volume", "instance:disk.volumes:DeviceID", T("C:"), "Lettre du volume"), P("Octets", "instance:disk.volumes:FreeSpace", N(10737418240), "Seuil d’espace libre en octets", 0)],
            expression: Any("disk.volumes", I("disk.volumes", "DeviceID", QueryOperator.Equal, QueryValue.FromParameter("Volume")), I("disk.volumes", "FreeSpace", QueryOperator.Less, QueryValue.FromParameter("Octets"))));
        b.Add(pc, "ops.disks.uncorrected", "Stockage · erreurs de lecture non corrigées rapportées", "Stockage et matériel", "Au moins un compteur de lecture non corrigée est positif ; un compteur absent n’est pas assimilé à zéro et le relevé seul ne prédit pas une panne.",
            expression: Any("disk.reliability", I("disk.reliability", "ReadErrorsUncorrected", QueryOperator.Greater, N(0))));
        b.Add(pc, "ops.disks.writeerrors", "Stockage · erreurs d’écriture non corrigées rapportées", "Stockage et matériel", "Au moins un compteur d’écriture non corrigée est positif ; le matériel qui n’expose pas ce compteur reste inconnu.",
            expression: Any("disk.reliability", I("disk.reliability", "WriteErrorsUncorrected", QueryOperator.Greater, N(0))));
        b.Add(pc, "ops.hardware.model.ram", "Matériel · modèle à choisir avec mémoire insuffisante", "Stockage et matériel", "Rapproche un modèle matériel et un seuil de RAM pour préparer une revue de capacité, sans verdict automatique de compatibilité.",
            [C("model", QueryOperator.Contains, QueryValue.FromParameter("Modele")), C("ramGB", QueryOperator.Less, QueryValue.FromParameter("Memoire"))],
            parameters: [P("Modele", "model", T("Votre modèle"), "Partie du modèle"), P("Memoire", "ramGB", N(16), "Mémoire minimale en Go", 0, 4096)]);
        b.Add(pc, "ops.hardware.model.disks", "Matériel · répartition des modèles avec peu d’espace sur C:", "Stockage et matériel", "Aide à repérer les modèles représentés parmi les postes sous le seuil de 10 % libres ; cela ne prouve pas un défaut propre au modèle.",
            [C("diskFreePercent", QueryOperator.Less, N(10))], groupBy: "model");
        b.Add(pc, "ops.hardware.device.class", "Périphériques · erreur dans une classe à choisir", "Stockage et matériel", "La sonde ne conserve que les périphériques déclarant une erreur. Une classe Display est proposée ; une liste non lue reste inconnue.",
            parameters: [P("Classe", "instance:hw.deviceerrors:PNPClass", T("Display"), "Classe Plug and Play")],
            expression: Any("hw.deviceerrors", I("hw.deviceerrors", "PNPClass", QueryOperator.Equal, QueryValue.FromParameter("Classe"))));
        b.Add(pc, "ops.printers.driver", "Impression · pilote à choisir", "Stockage et matériel", "Recherche au moins une imprimante utilisant un pilote dont le nom contient le texte choisi ; aucune impression n’est lancée.",
            parameters: [P("Pilote", "instance:soft.printerdetails:DriverName", T("Universal"), "Partie du nom du pilote")],
            expression: Any("soft.printerdetails", I("soft.printerdetails", "DriverName", QueryOperator.Contains, QueryValue.FromParameter("Pilote"))));
        b.Add(pc, "ops.security.defender.gap", "Defender · antivirus actif mais temps réel inactif", "Sécurité du poste", "Croise deux états déclarés du même fournisseur ; à interpréter selon le mode de fonctionnement et les autres produits installés.",
            [C("probe:sec.defender", QueryOperator.Equal, T("Oui")), C("probe:sec.realtime", QueryOperator.Equal, T("Non"))]);
        b.Add(pc, "ops.security.defender.age", "Defender · protection active et signatures anciennes", "Sécurité du poste", "Priorise les postes où Defender est déclaré actif avec des signatures de plus de trois jours ; un âge absent reste inconnu.",
            [C("probe:sec.defender", QueryOperator.Equal, T("Oui")), C("probe:sec.signatures", QueryOperator.Greater, N(3))]);
        b.Add(pc, "ops.network.interface", "Réseau · interface contenant un nom à choisir", "Réseau et connectivité", "Recherche dans les interfaces recensées, physiques et virtuelles ; le nom seul ne prouve pas qu’un VPN est connecté.",
            parameters: [P("Interface", "instance:net.interfaces:Name", T("Ethernet"), "Partie du nom d’interface")],
            expression: Any("net.interfaces", I("net.interfaces", "Name", QueryOperator.Contains, QueryValue.FromParameter("Interface"))));
    }

    private static void OperationalAccounts(Builder b)
    {
        const QueryTarget u = QueryTarget.User;
        const string category = "Comptes · revues ciblées";
        b.Add(u, "ops.users.privileged.disabled", "Comptes · désactivés avec appartenance privilégiée", category, "Appartenance directe ou indirecte issue de la copie AD ; désactiver un compte ne retire pas ses appartenances.", [C("active", QueryOperator.Equal, B(false)), C("privileged", QueryOperator.Equal, B(true))]);
        b.Add(u, "ops.users.privileged.nonexpiring", "Comptes · privilégiés avec mot de passe sans expiration", category, "Repère les exceptions à documenter, sans déduire la robustesse du mot de passe.", [C("privileged", QueryOperator.Equal, B(true)), C("passwordNeverExpires", QueryOperator.Equal, B(true))]);
        b.Add(u, "ops.users.active.locked", "Comptes · actifs et verrouillés", category, "Croise l’activation et l’état calculé du verrouillage, distinct du seul attribut lockoutTime.", [C("active", QueryOperator.Equal, B(true)), C("lockState", QueryOperator.Equal, T("Verrouillé"))]);
        b.Add(u, "ops.users.active.expired", "Comptes · actifs avec mot de passe expiré", category, "Compte activé dont l’expiration de mot de passe est prouvée dans les données disponibles.", [C("active", QueryOperator.Equal, B(true)), C("passwordState", QueryOperator.Equal, T("Expiré"))]);
        b.Add(u, "ops.users.old.nologon", "Comptes · créés depuis plus de 30 jours sans date AD de connexion", category, "Date répliquée absente sur un compte ancien ; cela ne prouve pas que le compte n’a jamais été utilisé.", [C("createdDays", QueryOperator.Greater, N(30)), C("logonDays", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(u, "ops.users.department.inactive", "Comptes · inactivité AD dans un service à choisir", category, "Période approximative sur lastLogonTimestamp des comptes actifs du service choisi.",
            [C("active", QueryOperator.Equal, B(true)), C("department", QueryOperator.Equal, QueryValue.FromParameter("Service")), C("logonDays", QueryOperator.GreaterOrEqual, QueryValue.FromParameter("Jours"))],
            parameters: [P("Service", "department", T("Votre service"), "Service"), P("Jours", "logonDays", N(90), "Ancienneté en jours", 1, 3650)]);
        b.Add(u, "ops.users.active.noidentity", "Comptes · actifs sans courriel ni identifiant salarié", category, "Qualité des attributs AD, à interpréter selon les conventions des comptes humains et techniques.", [C("active", QueryOperator.Equal, B(true)), C("mail", QueryOperator.IsMissing, QueryValue.None), C("employeeId", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(u, "ops.users.password.bydepartment", "Comptes · service des mots de passe sans expiration", category, "Répartition par service des comptes actifs portant l’exception sans expiration ; les services non renseignés restent visibles.", [C("active", QueryOperator.Equal, B(true)), C("passwordNeverExpires", QueryOperator.Equal, B(true))], groupBy: "department");
        b.Add(QueryTarget.Group, "ops.groups.empty.unmanaged", "Groupes · vides et sans responsable", "Groupes · revue des usages", "Croise une absence de membres prouvée avec managedBy absent ; ne propose aucune suppression automatique.", [C("empty", QueryOperator.Equal, B(true)), C("managedBy", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(QueryTarget.Group, "ops.groups.security.undocumented", "Groupes · sécurité sans description", "Groupes · revue des usages", "Groupes portant le bit de sécurité sans description disponible dans l’annuaire.", [C("groupKind", QueryOperator.Equal, T("Sécurité")), C("description", QueryOperator.IsMissing, QueryValue.None)]);
        b.Add(QueryTarget.Group, "ops.groups.size.parameter", "Groupes · taille minimale et portée à choisir", "Groupes · revue des usages", "Nombre de membres directs, pas de personnes uniques par expansion transitive ; la portée vient de groupType.",
            [C("members", QueryOperator.GreaterOrEqual, QueryValue.FromParameter("Membres")), C("scope", QueryOperator.Equal, QueryValue.FromParameter("Portee"))],
            parameters: [P("Membres", "members", N(50), "Membres directs minimum", 0, 1000000), P("Portee", "scope", T("Universel"), "Étendue du groupe")]);
    }
}
