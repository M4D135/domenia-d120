namespace Domenia.Core.Queries;

// Delivered model tables carried over from Domenia 1 (Get-DomeniaQueryTemplates): one line per model, coded values written
// in proper French. Format of a filter line: id|category|title|field|operator|typed value|description, typed value b: (Oui/Non),
// n: (number), t: (text) or z: (no value).
public static partial class QueryTemplates
{
    private const string ComputerRows = """
active|Comptes et activité AD|Comptes actifs|active|Equal|b:true|Comptes ordinateurs activés dans la copie AD du périmètre.
disabled|Comptes et activité AD|Comptes désactivés|active|Equal|b:false|Comptes désactivés, conservés dans le recensement ; ce modèle ne lance aucune collecte.
never|Qualité des données|Date de connexion AD non renseignée|logonDays|IsMissing|z:|Date AD absente ou non exploitable ; cela ne prouve pas que le poste n’a jamais été utilisé.
created|Comptes et activité AD|Créés depuis 30 jours|createdRecent|Equal|b:true|Comptes créés dans les trente derniers jours, utiles au suivi des nouveaux équipements.
password|Comptes et activité AD|Mot de passe machine ancien|passwordOld|Equal|b:true|Mot de passe du compte machine âgé de plus de soixante jours ; vérifier la relation au domaine.
laps|Protection AD|Expiration LAPS dépassée|laps|Equal|t:E|Expiration LAPS dépassée d’après les attributs visibles, sans lire le secret.
nolaps|Protection AD|Aucun attribut LAPS lu|laps|Equal|t:N|Aucun attribut LAPS utilisable lu ; vérifier le déploiement et les droits avant de conclure.
nokey|Protection AD|Aucune clé BitLocker visible dans AD|bitlocker|Equal|t:N|Aucune clé de récupération visible dans AD ; cela ne mesure pas le chiffrement du disque.
servers|Système et cycle Windows|Système AD contenant Server|os|Contains|t:Server|Comptes dont le système déclaré dans AD contient Server.
unchecked|Qualité des données|Sans relevé utilisable|checkedDays|IsMissing|z:|Aucun relevé exploitable dans la durée de conservation ; préparer une collecte ciblée.
oldcheck|Qualité des données|Relevé de plus de 7 jours|checkedDays|Greater|n:7|Relevé encore disponible mais vieux de plus d’une semaine ; les relevés expirés restent inconnus.
lowdisk|Disques et capacité|C: moins de 10 % libre|diskFreePercent|Less|n:10|Seuil de triage pour l’espace libre de C: ; l’urgence dépend aussi du volume et de l’usage.
ram|Matériel|Moins de 8 Go de RAM|ramGB|Less|n:8|Mémoire installée inférieure à 8 Go dans le dernier inventaire ; seuil à adapter aux usages.
uptime|Système et cycle Windows|Sans redémarrage depuis plus de 30 jours|uptimeDays|Greater|n:30|Démarrage relevé il y a plus de trente jours ; préparer une vérification des maintenances.
cpu|Matériel|Charge CPU supérieure à 80 %|probe:hw.cpuload|Greater|n:80|Charge instantanée du premier processeur supérieure à 80 %, sans présumer d’une saturation durable.
services|Services et processus|Services automatiques arrêtés|probe:soft.stoppedauto|Greater|n:0|Au moins un service automatique arrêté ; certains services restent volontairement à l’arrêt.
syserrors|Événements|Erreurs système depuis 24 h|probe:evt.syserrors|Greater|n:0|Au moins une erreur du journal Système sur vingt-quatre heures ; lecture potentiellement lente.
ad.recentlogon|Comptes et activité AD|Connexion AD depuis moins de 7 jours|logonDays|Less|n:7|Date répliquée lastLogonTimestamp récente ; cette mesure est approximative, ce n’est pas une présence réseau.
ad.logon30|Comptes et activité AD|Connexion AD de plus de 30 jours|logonDays|Greater|n:30|Premier tri des dates AD anciennes, à rapprocher du rôle du poste et de ses derniers relevés.
ad.logon180|Comptes et activité AD|Connexion AD de plus de 180 jours|logonDays|GreaterOrEqual|n:180|Comptes à examiner pour un inventaire de longue inactivité ; aucune suppression proposée automatiquement.
ad.existing|Comptes et activité AD|Comptes créés depuis plus de 30 jours|createdRecent|Equal|b:false|Écarte les créations récentes dans une revue du parc installé.
ad.passwordcurrent|Comptes et activité AD|Mot de passe machine de 60 jours au plus|passwordOld|Equal|b:false|Complément des comptes au mot de passe ancien, limité aux dates connues.
ad.nameexample|Comptes et activité AD|Postes dont le nom commence par PC-|name|StartsWith|t:PC-|Exemple de convention de nommage ; adaptez le préfixe à votre annuaire.
ad.ouexample|Comptes et activité AD|Chemin AD contenant OU=Support|dn|Contains|t:OU=Support|Exemple de filtre textuel de chemin ; utilisez le sélecteur OU pour borner précisément le périmètre.
os.win11|Système et cycle Windows|Windows 11 déclaré dans AD|os|Contains|t:Windows 11|Recense les systèmes Windows 11 déclarés ; la version relevée sur le poste peut différer.
os.win10|Système et cycle Windows|Windows 10 hors éditions longue durée|win10|Equal|b:true|Windows 10 hors LTSC, LTSB et IoT selon le libellé AD.
os.workstations|Système et cycle Windows|Famille postes de travail|osFamily|Equal|t:Postes de travail|Même regroupement de famille que le tableau de bord, établi à partir du système AD.
os.server2022|Système et cycle Windows|Windows Server 2022 déclaré|os|Contains|t:Server 2022|Inventaire d’une génération serveur à partir de l’attribut AD.
os.server2025|Système et cycle Windows|Windows Server 2025 déclaré|os|Contains|t:Server 2025|Inventaire d’une génération serveur à partir de l’attribut AD.
os.ltsc|Système et cycle Windows|Éditions LTSC déclarées|os|Contains|t:LTSC|Repère les éditions longue durée nommées LTSC ; leur support dépend de l’édition exacte.
os.ended|Système et cycle Windows|Fin de support connue dépassée|lifeStatus|Equal|t:Ended|Fin de support dépassée selon le référentiel Windows livré et l’édition reconnue.
os.soon|Système et cycle Windows|Fin de support dans les 90 jours|lifeStatus|Equal|t:Soon|Version dont le référentiel local annonce une fin de support proche.
os.supported|Système et cycle Windows|Support connu au-delà de 90 jours|lifeStatus|Equal|t:Ok|Cycle connu et hors de la fenêtre d’alerte ; ce n’est pas une preuve de niveau de correctifs.
os.lifecycleunknown|Qualité des données|Cycle de vie Windows non déterminé|lifeStatus|Equal|t:Unknown|Référentiel ou version insuffisant pour déterminer une date de fin de support.
os.observed11|Système et cycle Windows|Windows 11 relevé sur le poste|observedRelease|Contains|t:Windows 11|Filtre la version issue de l’inventaire, distincte du système déclaré dans AD.
os.observed24h2|Système et cycle Windows|Version 24H2 relevée|observedRelease|Contains|t:24H2|Version commerciale déduite du build de l’inventaire léger.
os.32bit|Système et cycle Windows|Architecture Windows 32 bits|probe:os.arch|Contains|t:32|Architecture retournée par Windows ; utile au repérage des systèmes à moderniser.
os.dc|Système et cycle Windows|Rôle contrôleur de domaine relevé|probe:os.producttype|Equal|t:Contrôleur de domaine|Rôle Windows lu sur le poste ; les sondes interdites sur un contrôleur restent exclues.
os.reboot7|Système et cycle Windows|Redémarré depuis moins de 7 jours|uptimeDays|Less|n:7|Dernier démarrage inférieur à une semaine, d’après le dernier inventaire utilisable.
os.multiusers|Présence et utilisateurs|Plusieurs utilisateurs déclarés par Windows|probe:os.users|Greater|n:1|Compteur NumberOfUsers supérieur à un ; il ne fournit pas l’identité de chaque session.
os.freeramlow|Matériel|Mémoire physique libre inférieure à 1 Go|probe:os.freeram|Less|n:1|Mesure instantanée de mémoire libre ; seuil de triage à confirmer sur le poste.
os.virtualfreelow|Matériel|Mémoire virtuelle libre inférieure à 2 Go|probe:os.virtualfree|Less|n:2|Faible mémoire virtuelle libre au relevé ; comparer avec la charge et le fichier d’échange.
os.oldinstall|Système et cycle Windows|Windows installé avant 2020|probe:os.installyear|Less|n:2020|Année d’installation Windows ancienne ; indicateur d’inventaire, pas une preuve de vétusté du matériel.
hw.ram16|Matériel|Au moins 16 Go de RAM|ramGB|GreaterOrEqual|n:16|Postes dont l’inventaire confirme au moins 16 Go de mémoire installée.
hw.twocores|Matériel|Moins de 2 cœurs sur le premier processeur|probe:hw.cores|Less|n:2|Capacité faible du premier processeur ; ce seul critère ne détermine pas une compatibilité Windows.
hw.threads|Matériel|Au moins 8 processeurs logiques|probe:hw.threads|GreaterOrEqual|n:8|Repère une capacité de calcul déclarée, sans mesurer les performances applicatives.
hw.virtualizationoff|Matériel|Virtualisation désactivée dans le firmware|probe:hw.virtualization|Equal|t:Non|Virtualisation déclarée désactivée sur le premier processeur ; vérifier les réglages et le matériel.
hw.slatabsent|Matériel|SLAT non déclaré par le processeur|probe:hw.slat|Equal|t:Non|Capacité de traduction de second niveau non déclarée ; utile avant un projet de virtualisation.
hw.lowbattery|Matériel|Première batterie à moins de 20 %|probe:hw.batterylevel|Less|n:20|Charge instantanée de la première batterie ; les postes sans batterie ne sont pas assimilés à zéro.
hw.batterypresent|Matériel|Batterie présente|probe:hw.battery|NotEqual|t:Non|Au moins une batterie reconnue, y compris lorsque le fournisseur recense plus de deux instances.
hw.portable|Matériel|Type de système portable|probe:hw.chassis|Equal|t:Portable|Type PCSystemTypeEx déclaré Portable ; la classification dépend du constructeur.
hw.tablet|Matériel|Type de système tablette|probe:hw.chassis|Equal|t:Tablette|Type PCSystemTypeEx déclaré Tablette.
hw.multiscreen|Matériel|Au moins deux écrans recensés|probe:hw.screens|GreaterOrEqual|n:2|Nombre d’instances WmiMonitorID lues ; ne garantit pas que chaque écran est actuellement allumé.
hw.oldbios|Matériel|BIOS daté avant 2020|probe:hw.biosyear|Less|n:2020|Date de publication BIOS ancienne ; vérifier la politique du constructeur avant une mise à jour.
hw.serialplaceholder|Qualité des données|Numéro de série générique constructeur|probe:hw.serialmissing|Contains|t:To Be Filled|Exemple de numéro de série générique à examiner dans l’inventaire matériel.
hw.dell|Matériel|Fabricant contenant Dell|probe:hw.maker|Contains|t:Dell|Exemple de segmentation constructeur, modifiable dans Composer.
hw.lenovo|Matériel|Fabricant contenant Lenovo|probe:hw.maker|Contains|t:Lenovo|Exemple de segmentation constructeur pour un lot de maintenance.
disk.low20|Disques et capacité|C: moins de 20 % libre|diskFreePercent|Less|n:20|Seuil de prévention plus large que le triage à 10 %, à adapter à la taille du volume.
disk.small|Disques et capacité|C: de moins de 128 Go|probe:disk.csize|Less|n:128|Capacité du volume système faible pour certains usages ; ce seuil n’est pas une exigence universelle.
disk.multivolume|Disques et capacité|Plusieurs volumes locaux|probe:disk.count|Greater|n:1|Recense les postes ayant plusieurs volumes de type disque local.
disk.ssd|Disques et capacité|Premier disque physique déclaré SSD|probe:disk.media|Equal|t:SSD|Type du premier disque physique renvoyé par le fournisseur Storage.
disk.hdd|Disques et capacité|Premier disque physique déclaré disque dur|probe:disk.media|Equal|t:Disque dur|Repère les disques mécaniques déclarés pour préparer une étude de remplacement.
disk.warning|Disques et capacité|Premier disque en avertissement|probe:disk.health|Equal|t:Avertissement|État HealthStatus de la première instance ; vérifier l’ensemble des disques dans la fiche.
disk.failed|Disques et capacité|Premier disque déclaré défaillant|probe:disk.health|Equal|t:Défaillant|État de défaillance signalé par le fournisseur Storage, à confirmer rapidement.
disk.removable|Disques et capacité|Volume amovible présent au relevé|probe:disk.removable|Greater|n:0|Au moins un volume de type amovible ; cette mesure ne couvre pas tous les périphériques USB.
disk.zero|Disques et capacité|C: à zéro pour cent libre|diskFreePercent|Equal|n:0|Zéro est une mesure connue ; une valeur absente ne correspond pas à ce modèle.
sec.lapsvalid|Protection AD|Expiration LAPS encore valide|laps|Equal|t:O|Expiration LAPS visible et non dépassée ; aucun secret n’est lu par la requête.
sec.lapsnoschema|Protection AD|Schéma LAPS indisponible|laps|Equal|t:X|Le schéma LAPS n’est pas disponible pour cette lecture.
sec.recoveryvisible|Protection AD|Clé de récupération visible dans AD|bitlocker|Equal|t:K|Présence d’une clé visible dans l’annuaire, indépendamment de l’état actuel du disque.
sec.recoveryunavailable|Protection AD|Lecture BitLocker AD indisponible|bitlocker|Equal|t:X|Lecture des objets de récupération indisponible ; ne pas assimiler à une absence de clé.
sec.unencrypted|Sécurité du poste|Protection BitLocker C: désactivée|probe:sec.bitlocker|Equal|t:Non protégé|ProtectionStatus non protégé pour C: ; lecture locale distante distincte de la clé AD.
sec.encrypted|Sécurité du poste|Protection BitLocker C: active|probe:sec.bitlocker|Equal|t:Protégé|ProtectionStatus actif pour C: au dernier relevé.
sec.defenderoff|Sécurité du poste|Antivirus Defender déclaré inactif|probe:sec.defender|Equal|t:Non|Defender peut être désactivé au profit d’un autre antivirus ; vérifier le produit en place.
sec.realtimeoff|Sécurité du poste|Protection temps réel Defender inactive|probe:sec.realtime|Equal|t:Non|État de protection temps réel au relevé, selon la disponibilité du fournisseur Defender.
sec.behavioroff|Sécurité du poste|Surveillance comportementale Defender inactive|probe:sec.behavior|Equal|t:Non|Surveillance comportementale déclarée inactive, à comparer à la stratégie de protection.
sec.signaturesold|Sécurité du poste|Signatures Defender de plus de 3 jours|probe:sec.signatures|Greater|n:3|Seuil de revue opérationnelle ; la valeur spéciale 65535 signifie jamais selon le fournisseur.
sec.quickscanold|Sécurité du poste|Analyse rapide Defender de plus de 7 jours|probe:sec.quickscan|Greater|n:7|Ancienneté de l’analyse rapide ; adapter à la politique du parc, 65535 signifie jamais.
sec.fullscannever|Sécurité du poste|Aucune analyse complète Defender déclarée|probe:sec.fullscan|Equal|n:65535|Valeur spéciale du fournisseur ; ce constat ne suffit pas à juger la protection globale.
sec.tpm2|Sécurité du poste|Spécification TPM contenant 2.0|probe:sec.tpmversion|Contains|t:2.0|Version TPM déclarée ; ne valide pas à elle seule une compatibilité Windows 11.
sec.tpmoff|Sécurité du poste|TPM déclaré désactivé|probe:sec.tpmenabled|Equal|t:Non|État initial du TPM déclaré désactivé au relevé.
sec.tpmnotactivated|Sécurité du poste|TPM déclaré non opérationnel|probe:sec.tpmactivated|Equal|t:Non|État d’activation initial du TPM ; vérifier le firmware et la stratégie.
sec.localmany|Sécurité du poste|Plus de 3 comptes locaux activés|probe:sec.localusers|Greater|n:3|Seuil d’examen des comptes locaux ; la sonde est exclue des contrôleurs de domaine.
sec.shares|Sécurité du poste|Partages de type disque recensés|probe:sec.shares|Greater|n:0|Partages retournés par la requête Type=0 ; leur présence ne prouve pas une exposition anormale.
net.slow|Réseau|Premier lien réseau inférieur à 100 Mbit/s|probe:net.speed|Less|n:100|Vitesse déclarée du premier adaptateur physique connecté, différente du débit réellement disponible.
net.gigabit|Réseau|Premier lien réseau à au moins 1 Gbit/s|probe:net.speed|GreaterOrEqual|n:1000|Capacité déclarée du lien, sans test de débit réseau.
net.fixed|Réseau|Configuration IP déclarée fixe|probe:net.dhcp|Equal|t:Fixe|DHCP désactivé sur la première configuration IP lue.
net.dhcp|Réseau|Configuration IP via DHCP|probe:net.dhcp|Equal|t:DHCP|DHCP déclaré actif sur la première configuration IP lue.
net.wifi|Réseau|Wi-Fi connecté au relevé|probe:net.wifi|NotEqual|t:Non|Au moins une interface Wi-Fi connectée, y compris lorsque le fournisseur recense plus de deux instances.
net.vpnexample|Réseau|Adaptateur contenant Ethernet|probe:net.adapter|Contains|t:Ethernet|Exemple de filtre sur les noms d’adaptateurs physiques connectés ; modifiez le terme si nécessaire.
soft.printersmany|Services et processus|Au moins 5 imprimantes installées|probe:soft.printers|GreaterOrEqual|n:5|Nombre d’instances d’imprimantes, y compris les imprimantes virtuelles.
soft.startupmany|Services et processus|Au moins 10 entrées de démarrage|probe:soft.startup|GreaterOrEqual|n:10|Seuil de revue du démarrage ; le nombre d’entrées ne mesure pas à lui seul leur impact.
soft.processmany|Services et processus|Plus de 200 processus au relevé|probe:soft.processes|Greater|n:200|Photographie du nombre de processus, utile pour comparer des postes de même usage.
soft.spoolerstopped|Services et processus|Spouleur d’impression arrêté|probe:soft.spooler|Equal|t:Stopped|Service Spooler arrêté ; peut être volontaire sur un serveur ou un poste sans impression.
soft.updatestopped|Services et processus|Service Windows Update arrêté|probe:soft.wuauserv|Equal|t:Stopped|État du service à la lecture ; un service à démarrage déclenché peut être arrêté normalement.
soft.winrmrunning|Services et processus|Service WinRM en cours|probe:soft.winrm|Equal|t:Running|Service WinRM démarré ; ne garantit ni l’ouverture du transport ni les droits d’accès.
soft.bitsstopped|Services et processus|Service BITS arrêté|probe:soft.bits|Equal|t:Stopped|État instantané de BITS, à interpréter selon le mode de démarrage configuré.
soft.timestopped|Services et processus|Service Heure Windows arrêté|probe:soft.w32time|Equal|t:Stopped|À rapprocher de la stratégie de synchronisation horaire et du rôle du système.
soft.rdprunning|Services et processus|Service Bureau à distance en cours|probe:soft.rdp|Equal|t:Running|Service TermService en cours ; ce n’est pas une preuve de session RDP ouverte.
soft.firewallstopped|Services et processus|Service Pare-feu Windows arrêté|probe:soft.firewall|Equal|t:Stopped|État MpsSvc arrêté ; vérifier la stratégie et le dispositif de protection utilisé.
soft.defenderstopped|Services et processus|Service Defender arrêté|probe:soft.defender|Equal|t:Stopped|Peut correspondre à un autre produit antivirus ; comparer aux données de protection.
soft.dnsstopped|Services et processus|Service Client DNS arrêté|probe:soft.dnsclient|Equal|t:Stopped|État du cache client DNS, à examiner dans le contexte du poste.
user.manyprofiles|Présence et utilisateurs|Plus de 10 profils non spéciaux|probe:user.profiles|Greater|n:10|Profils stockés sur le poste ; ce n’est ni un nombre d’utilisateurs actifs ni une autorisation de suppression.
user.multisessions|Présence et utilisateurs|Plusieurs sessions interactives recensées|probe:user.sessions|Greater|n:1|Compte les sessions répondant au filtre WMI de la sonde, sans liste nominative exhaustive.
user.online|Présence et utilisateurs|Postes ayant répondu au dernier relevé|presence|Equal|t:En ligne|Présence observée dans les données disponibles ; ce résultat n’est pas un ping en temps réel.
user.noresponse|Présence et utilisateurs|Dernier relevé sans réponse|presenceBucket|Equal|t:Sans réponse|Absence de réponse au dernier relevé ; cela ne prouve pas que le poste est éteint.
user.consoleknown|Présence et utilisateurs|Utilisateur console résolu|user|IsPresent|z:|Utilisateur de console résolu dans AD et encore exploitable ; les sessions RDP ne sont pas recensées ici.
evt.unexpected|Événements|Arrêt inattendu depuis 7 jours|probe:evt.unexpected|Greater|n:0|Événement 6008 du journal Système dans les sept jours ; lecture potentiellement lente.
evt.manyerrors|Événements|Au moins 10 erreurs système en 24 h|probe:evt.syserrors|GreaterOrEqual|n:10|Seuil de triage des volumes d’erreurs, sans diagnostic automatique de cause.
quality.os|Qualité des données|Système AD non renseigné|os|IsMissing|z:|Attribut système absent de la copie locale ; actualiser l’OU si la couverture est incomplète.
quality.version|Qualité des données|Version AD non renseignée|version|IsMissing|z:|Version système absente ou non lue dans AD.
quality.inventory|Qualité des données|Aucun inventaire léger exploitable|inventoryDays|IsMissing|z:|Inventaire absent ou expiré ; un ping seul ne le rafraîchit pas.
quality.inventoryold|Qualité des données|Inventaire de plus de 7 jours|inventoryDays|Greater|n:7|Dernière lecture d’inventaire réussie de plus d’une semaine, encore dans la durée utilisable.
quality.disk|Qualité des données|Espace disque inconnu|diskFreePercent|IsMissing|z:|Pas de mesure exploitable pour C: ; ne pas assimiler à un disque plein.
quality.ram|Qualité des données|Mémoire installée inconnue|ramGB|IsMissing|z:|Aucune valeur RAM exploitable dans l’inventaire disponible.
quality.console|Qualité des données|Utilisateur console non résolu|user|IsMissing|z:|Identité console absente, non résolue ou expirée ; cela ne prouve pas l’absence d’utilisateur.
quality.defender|Qualité des données|État Defender inconnu|probe:sec.defender|IsMissing|z:|Sonde absente, fournisseur indisponible, refus ou mesure expirée.
quality.bitlocker|Qualité des données|Protection BitLocker du disque inconnue|probe:sec.bitlocker|IsMissing|z:|Aucune valeur WMI exploitable pour C:, distincte de la présence d’une clé AD.
quality.tpm|Qualité des données|Spécification TPM inconnue|probe:sec.tpmversion|IsMissing|z:|Aucune spécification TPM exploitable ; distinguer absence matérielle et impossibilité de lecture.
quality.events|Qualité des données|Journal Système non collecté ou expiré|probe:evt.syserrors|IsMissing|z:|Le nombre d’erreurs est inconnu tant que la sonde n’a pas fourni un relevé utilisable.
quality.network|Qualité des données|Vitesse réseau inconnue|probe:net.speed|IsMissing|z:|Absence de mesure de lien utilisable ; ce n’est pas un débit nul.
quality.presence|Qualité des données|Présence non vérifiée|presenceBucket|Equal|t:Non vérifié|Aucun constat de présence utilisable dans le regroupement du tableau de bord.
""";

    private const string ComputerGroups = """
by.state|Comptes actifs et désactivés|active|Répartition des états AD connus et inconnus.
by.ou|Postes par OU du périmètre|site|Même regroupement par OU que le tableau de bord ; le résultat dépend du périmètre choisi.
by.os|Systèmes déclarés dans AD|os|Répartition des libellés bruts du système déclaré dans l’annuaire.
by.release|Versions Windows du référentiel|release|Versions déduites du build AD, avec la catégorie inconnue lorsque nécessaire.
by.lifecycle|États du cycle Windows|lifeStatus|Répartition Ended, Soon, Ok et Unknown du référentiel local.
by.logon|Tranches de connexion AD|logonBucket|Tranches 0–6, 7–29, 30–89, 90–179, 180 jours et plus, puis date non renseignée.
by.presence|Dernière présence par état|presenceBucket|Photographie locale des derniers résultats de présence, sans nouveau ping.
by.user|Utilisateurs console résolus|user|Répartition des utilisateurs de console connus ; les sessions RDP ne sont pas recensées.
by.model|Modèles de l’inventaire léger|model|Regroupement par modèle des inventaires encore exploitables.
by.observedrelease|Versions Windows relevées|observedRelease|Versions issues des relevés des postes, distinctes des attributs AD.
by.maker|Constructeurs matériels|probe:hw.maker|Regrouper les postes par fabricant relevé.
by.cpu|Modèles du premier processeur|probe:hw.cpu|Première instance de processeur renvoyée par chaque poste.
by.bios|Versions BIOS déclarées|probe:hw.bios|Inventaire des versions, sans comparaison automatique aux versions recommandées.
by.gpu|Premières cartes graphiques|probe:hw.gpu|Première carte vidéo renvoyée par poste, sans inventaire exhaustif multi-GPU.
by.chassis|Types de systèmes matériels|probe:hw.chassis|Répartition des catégories PCSystemTypeEx déclarées par Windows.
by.arch|Architectures Windows|probe:os.arch|Répartition de l’architecture du système d’exploitation.
by.language|Langues Windows|probe:os.lang|Langue Windows convertie depuis le code de langue fourni.
by.timezone|Fuseaux horaires Windows|probe:os.tz|Libellé du fuseau horaire relevé sur chaque poste.
by.diskmedia|Types du premier disque physique|probe:disk.media|Répartition des types déclarés par le fournisseur Storage.
by.diskhealth|Santé du premier disque physique|probe:disk.health|Répartition des états connus ; ce n’est pas un test physique du support.
by.encryption|Protection BitLocker C:|probe:sec.bitlocker|État de protection du volume C:, indépendamment de la clé enregistrée dans AD.
by.defender|État de l’antivirus Defender|probe:sec.defender|Comparer les états connus et les données manquantes, sans assimiler inactif à absence d’antivirus.
by.dhcp|DHCP et configurations fixes|probe:net.dhcp|Première configuration IP lue par poste.
by.defaultprinter|Imprimantes par défaut|probe:soft.defaultprinter|Regroupe les noms d’imprimantes par défaut disponibles au relevé.
by.laps|États LAPS visibles|laps|Codes d’expiration LAPS visibles dans AD ; aucun secret n’est exposé.
""";

    private const string ComputerThresholds = """
ramGB|8,16,32
diskFreePercent|5,10,20
uptimeDays|7,30,90
checkedDays|1,7,14
inventoryDays|1,7,14
logonDays|30,90,180
probe:hw.ram|4,8,16,32
probe:hw.cores|2,4,8
probe:hw.threads|4,8,16
probe:hw.cpuload|80,90
probe:hw.batterylevel|20,50
probe:os.uptime|7,30,90
probe:os.freeram|1,2,4
probe:disk.cfree|5,10,20
probe:disk.csize|128,256,512
probe:sec.signatures|1,3,7
probe:sec.quickscan|7,14,30
probe:sec.fullscan|7,30,90
probe:net.speed|100,1000
""";
}
