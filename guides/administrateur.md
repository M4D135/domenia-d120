# 1 Ce qui change dans cette édition

Cette édition du 8 octobre 2026 est la première des guides de Domenia 1.0. Elle décrit le code du 8 octobre et place en tête les changements des lots des 7 et 8 octobre, livrés en RC1.13.0 après la version candidate RC1.11.0 du 5 octobre (RC1.12.0, livrée le matin du 8 octobre, est remplacée le jour même : la vue d'ensemble du parc suit désormais l'OU de Rechercher). Le guide technicien donne les gestes du quotidien ; ce guide en donne les règles, les raisons, l'architecture et l'exploitation.

| Changement | Ce que l'administrateur doit faire ou savoir |
|---|---|
| Tableaux de bord en widgets (08/10) | Les tableaux du poste, du parc et des logiciels sont entièrement faits de widgets. Chaque tuile ou graphique se modifie, se déplace, change de taille ou se retire, avec un retour arrière par « Annuler ». Le catalogue intégré compte 67 widgets ; les requêtes WMI s'y ajoutent (chapitre 9). |
| Vue d'ensemble du parc (07 et 08/10) | La carte « Vue d ensemble du parc » de l'Accueil suit l'OU choisie dans l'arbre de « Rechercher » : un seul filtre OU pour toute l'application. Elle ne fait qu'afficher ; son calcul part en arrière-plan, sur l'OU seulement (chapitre 8). |
| Requêtes WMI prêtes à l'emploi (07/10) | 52 requêtes en lecture seule, réparties en 8 catégories, deviennent des widgets des tableaux du poste et du parc. Elles partent après confirmation : « Actualiser les requetes » pour le poste, « Analyser la liste » dans « Rechercher » pour le parc (chapitre 10). |
| Pinger, Détecter et Analyser la liste (05 au 08/10) | Dans « Rechercher », le ping, la lecture de l'utilisateur console et le relevé WMI léger visent les seuls postes affichés, après confirmation. La détection sur tout le parc est retirée (chapitre 3). |
| Ouvrir C$ et consoles (07 et 08/10) | « Ouvrir C$ » ouvre le partage avec le compte des opérations poste. Le contrôle du port 445 et la connexion SMB passent par le worker ComputerAdminShare, hors du fil de l'interface (chapitre 5). |
| Base autonome (07 et 08/10) | L'encadré « Emplacement et sauvegarde » montre le fichier de la base et propose « Ouvrir l emplacement », « Sauvegarder maintenant » et « Copier une sauvegarde vers... ». La copie à chaud passe par le worker StorageBackup (chapitre 18). |
| Retraits (07/10) | La rubrique « Atelier support » du menu est retirée. Les onglets « Fiabilité », « Opérations et confort » et « Commandes » de la page Outils sont masqués, y compris en profil Expert. |
| Barre d'actions compacte (08/10) | Dans une fenêtre étroite, la barre des résultats tient sur une ligne : « Console au clic », « Revérifier », « Pinger » et « Détecter » remplacent « Utilisateur au clic » et les libellés longs. |
| Registre des workers (07 et 08/10) | 68 opérations au lieu de 66 : ComputerAdminShare et StorageBackup sont ajoutées ; ComputerDiagnostics, ComputerInventory, DomainOverview, LiveConsole, LiveSelectedPing, LocalIndexRead, LocalStore et SoftwareInventory sont modifiées (chapitre 15). |
| Corrections (08/10) | Dispositions des tableaux et OU du parc conservées au redémarrage ; Windows Server 2025 n'est plus pris pour Windows 11 24H2 ; redémarrage en attente et BitLocker lus correctement ; mémoire totale des machines virtuelles ; profils de pare-feu désactivés signalés ; périmètre des requêtes revérifié après une reconnexion. |
| Nouvelle identité de livraison | Le contrat porte RC1.13.0 et le Build 2026.10.08-DOMENIA-1.0-RC1.13.0-D120 : l'installateur accepte la mise à jour d'un poste en RC1.11.0 ou RC1.12.0 ; il refuse seulement un Build déjà actif (chapitre 16). |

> [!ATTENTION] Version candidate. Les lots des 7 et 8 octobre ont passé des tests d'intégration dans une VM de test, mais aucun point du suivi n'est encore clôturé. Une livraison n'est qualifiée qu'avec un rapport Windows PowerShell 5.1 lié à l'empreinte de ses ZIP (chapitre 21).

> [!NOTE] Captures. Les figures de ce guide sont des rendus hors écran de la vraie fenêtre WPF de Domenia, chargée dans une VM Windows de test, avec des valeurs fictives : domaine example.local, postes PC-COMPTA-014, PC-ACCUEIL-002 et PC-RH-031, utilisatrice Camille Martin (cmartin). Aucun annuaire ni poste distant n'a été contacté pour les produire. Elles montrent l'écran ; elles ne prouvent pas une action réelle.

# 2 Démarrage rapide

Ces étapes mettent Domenia 1.0 en service sur un poste d'administration. Chaque ligne renvoie au chapitre qui la détaille. Ne sautez pas l'étape 1 : la qualification se fait dans une VM de test, jamais sur un poste de production.

| Étape | Action | Chapitre |
|---|---|---|
| 1 | Qualifier la livraison dans une VM Windows de test. | 21 |
| 2 | Vérifier les prérequis : Windows PowerShell 5.1 x64, WPF, module Active Directory ou DLL livrées, dossier local non redirigé. | 16 |
| 3 | Préparer les comptes : lecture de l'annuaire, administration des postes, lecture LAPS et BitLocker, délégations AD pour les écritures. | 13 |
| 4 | Extraire tout le ZIP PROD dans un dossier local ; si Windows bloque les fichiers, lancer wad\Support\DEBLOQUER_TOUT.cmd. | 16 |
| 5 | Contrôler le paquet sans démarrer l'interface : Domenia.exe --check. | 15 et 20 |
| 6 | Relire wad\Domenia.config.json : Auth.DemoProvider absent ou faux, connexion Standard, aucun marqueur wad\Domenia.login.debug. | 14 et 17 |
| 7 | Choisir l'emplacement des données (LocalStore.Mode) : UserLocal dans le profil de l'utilisateur, ou Portable réservé à un support personnel. | 18 |
| 8 | Lancer Domenia.exe, se connecter et vérifier que la case « Lecture seule » est cochée. | 13 et 14 |
| 9 | Remplir la base autonome : Outils, onglet « Base autonome », « Mettre a jour tout ». | 18 |
| 10 | Choisir une OU pilote dans « Rechercher », afficher ses postes et lancer « Analyser la liste » ; vérifier la vue d'ensemble de l'Accueil. | 3 et 8 |
| 11 | Faire une première sauvegarde de la base : « Sauvegarder maintenant ». | 18 |
| 12 | Remettre aux techniciens le guide technicien et le profil « Essentiel ». | 13 |

# 3 Rechercher : fonctionnement et règles

La page « Rechercher » lit l'annuaire à la demande ; elle ne sonde aucun poste avant un geste explicite. Deux modes coexistent : la recherche globale du bandeau, qui ignore l'OU et les filtres, et le contenu d'une OU choisie dans l'arbre, avec ses filtres. Les relevés sur une liste partent après confirmation, quatre postes au plus à la fois.

![Page Rechercher : l'arbre des OU à gauche, le périmètre et les filtres, puis la liste des postes et des utilisateurs avec leur présence réseau et l'utilisateur console](fig:recherche)

## Recherche globale

La barre du haut cherche dans tout le domaine, tous types d'objets, sans filtre d'OU, de présence ni de liste. Entrée ou le bouton « Rechercher » la lancent. Aucun poste n'est sondé avant une sélection.

- Minimum de caractères : Browser.GlobalSearchMinChars (2). En dessous, Domenia affiche « Saisis au moins » suivi du minimum et de « caracteres, ou * pour un apercu. ».
- Limite : celle du champ « Limite » (100 par défaut), retenue d'une session à l'autre dans la préférence SearchLimit. « Charger la suite » relit la même recherche avec une limite doublée, jusqu'à 20 000 lignes.
- Délais : Browser.SearchServerTimeLimitSeconds (8 s, côté contrôleur) et Browser.SearchClientTimeoutSeconds (12 s, côté poste).
- Recherche à la frappe : désactivée par défaut (Browser.LiveGlobalSearch et Browser.AllowLiveGlobalSearch à faux).
- Pendant une écriture, la recherche attend : « Recherche différée : écriture active ou à vérifier. ».
- Classement : Features.SearchRanking (vrai) ordonne les résultats d'une recherche globale ; sans lui, ils restent dans l'ordre d'arrivée.

Des préfixes facultatifs limitent la recherche à un type (Features.SearchSyntax, vrai par défaut). Un préfixe inconnu est cherché comme du texte.

| Préfixe | Variantes | Effet |
|---|---|---|
| utilisateur: | user:, u: | Utilisateurs seulement. |
| poste: | pc:, machine:, ordinateur: | Postes seulement. |
| groupe: | group:, g: | Groupes seulement. |
| mail: | email:, courriel: | Recherche sur l'adresse mail. |

## Arbre des OU et filtres

L'arbre « Parcourir les OU » affiche le contenu d'une OU. La case « Inclure les sous-OU » est cochée par défaut ; décochée, seuls les enfants directs sont lus. Le menu clic droit de l'arbre propose aussi « Analyser les droits sur cette branche » et « Nouveau dans cette branche » (écriture, grisé en lecture seule).

| Filtre | Valeurs | Remarque |
|---|---|---|
| Type d'objet | Tous, Utilisateurs, Machines, Groupes, OU et conteneurs | Grisé pendant une recherche globale. |
| Présence réseau | Tous, En ligne, Sans réponse au ping, Non vérifié, Erreur de ping | Filtre les observations mémorisées ; aucun ping collectif. |
| Limite | 100 par défaut | 20 000 lignes au plus. |
| Vue de travail | Comptes expirant sous 30 jours, Comptes desactives, Objets modifies depuis 7 jours, Postes de cette OU, Postes sans connexion depuis 90 jours | « Postes de cette OU » exige une OU choisie dans l'arbre. |

Le champ « Dans les résultats » filtre la liste déjà chargée, sans appel AD : nom, login, type, présence et association. La limite LDAP ne change pas.

> [!NOTE] « Sans réponse au ping » ne prouve pas qu'un poste est éteint : l'ICMP peut être filtré. Une liste vide ne prouve pas non plus une absence dans AD.

## Vérification au clic

Un clic sur un poste lance un ping unique et, si « Utilisateur au clic » est cochée, la lecture de l'utilisateur console. L'état initial de la case vient de Streaming.VerifyUserOnSelection (vrai dans la configuration livrée). Deux lectures au plus tournent en même temps (Streaming.MaxUserProbes, borné de 1 à 3). « Revérifier ce poste » relance la même vérification sur le seul poste sélectionné.

La lecture de la console passe par CIM en DCOM, avec le compte des opérations poste (chapitre 5). Si Remote.UseCim est faux, Domenia se limite au ping : « Contrôle réseau uniquement. Aucune lecture du compte console. ». Les sessions RDP ne sont pas recensées.

| Colonne | Valeurs possibles |
|---|---|
| Utilisateur connecté (console) | Le compte, Aucun compte console, Non déterminé, ou le compte suivi de (cache) pour une observation ancienne. |
| Vérification utilisateur | Console observée, Lecture réussie, Accès refusé, Compte distant refusé, Délai dépassé, Non confirmé, Utilisateur non vérifié, Vérification en cours, À vérifier. |
| Présence réseau | En ligne, Sans réponse au ping, Non vérifié, Erreur de ping, Vérification en cours, avec (cache) pour une observation ancienne. |

## Pinger, Détecter et Analyser la liste

Ces trois boutons agissent sur les seuls postes affichés, après tous les filtres : OU, recherche, présence et filtre local. Ils sont grisés si la liste ne contient aucun poste. Ce sont les seules analyses de postes en nombre : la vue d'ensemble de l'Accueil n'en lance aucune.

![Barre d'actions des résultats : case Utilisateur au clic, Revérifier ce poste, Pinger la liste, Détecter la liste, Analyser la liste et Arrêter](fig:recherche-actions)

| Bouton | Ce qui part | Confirmation |
|---|---|---|
| « Pinger la liste » | Ping ICMP seul, quatre postes au maximum à la fois. Met à jour la présence réseau, sans lecture de session ni association. | Nombre de postes, puis « Pinger » ou « Annuler ». |
| « Détecter la liste » | Ping puis lecture légère de la console Windows (CIM/DCOM), quatre postes au maximum à la fois. Seuls les comptes nouveaux ou modifiés sont résolus dans AD. Associations et cache conservés. | Nombre de postes, puis « Verifier les sessions » ou « Annuler ». |
| « Analyser la liste » | Comme « Détecter la liste », plus le relevé WMI léger (modèle, mémoire, disque C:, build, démarrage) et les requêtes WMI des widgets placés sur les tableaux du poste et du parc. Les résultats remplissent les tableaux de bord. | « Analyser les postes affiches », nombre de postes et de requêtes, puis « Analyser » ou « Annuler ». |
| « Arrêter » | Arrête les nouvelles lectures ; les résultats déjà obtenus restent. | Aucune. |

Les confirmations s'affichent dans la page, sans nouvelle fenêtre ; Échap choisit la réponse sûre. Un relevé s'arrête de lui-même sur des identifiants rejetés, après trois échecs d'enregistrement local, sur un conflit d'enregistrement, ou si une lecture est annulée ou ne correspond pas au poste attendu. Une lecture de poste en échec ne l'arrête pas : elle compte dans les « lectures non confirmees ». Il se met en pause tant que 64 enregistrements locaux attendent.

> [!ATTENTION] La détection sur tout le parc est retirée (décision du 5 octobre). Toute demande aboutit à « Releve impossible : » suivi de « detection sur tout le parc retiree. Filtrez la liste dans Rechercher puis Detecter la liste. ». Filtrez d'abord, puis détectez.

## Export et menu clic droit

« Exporter CSV » enregistre les lignes affichées, ou seulement les lignes sélectionnées. Le menu clic droit d'une ligne regroupe l'ouverture de la fiche, les outils du poste (sous-menus « Poste distant » et « Collecte »), « Analyser », « Copier », « Exporter la liste en CSV » et « Modifier ». Les entrées de « Modifier » sont des écritures : elles restent bloquées tant que la lecture seule est active (chapitre 14).

# 4 Fiches des objets

La fiche d'un objet se prépare en arrière-plan dès le clic, et s'ouvre au double-clic ou avec Entrée. Ses onglets dépendent du type d'objet et du profil d'interface. Tous les boutons qui écrivent dans AD sont grisés tant que la lecture seule est active.

## Onglets selon le type

| Type | Onglets |
|---|---|
| Tous | « Resume », « Appartenances » ; en profil Expert, « Attributs » et « Droits effectifs ». |
| Utilisateur | « Utilisateur », « Coordonnees », « Compte ». |
| Groupe | « Groupe ». |
| OU ou conteneur | « Unite d organisation ». |
| Poste | La page « Poste » montre ce poste (chapitre 5). |

L'onglet « Resume » donne le type, le nom, la classe, le GUID, les dates de création et de modification, le chemin complet et la présence. Pour un utilisateur, la présence est celle du poste qui lui est associé.

## Lecture et estimation des droits

À l'ouverture d'un objet, Domenia estime les droits du compte sur cet objet (Security.EvaluateRightsOnObjectOpen, vrai). Cette estimation ne bloque rien par défaut (Security.BlockOnAclEstimate et Security.DisableIndeterminateControls à faux) : Windows et AD décident au moment de l'écriture. L'onglet « Droits effectifs », en profil Expert, analyse les droits sur l'objet.

## Écritures sur une fiche

| Onglet | Écritures proposées |
|---|---|
| Utilisateur et Coordonnees | « Enregistrer » les champs modifiés. |
| Compte | « Déverrouiller le compte », « Activer », « Desactiver », « Reinitialiser le mot de passe », « Options de compte » puis « Appliquer », « Fixer » ou « Jamais » pour l'expiration, « Expirer le mot de passe », « Deplacer », ajout ou retrait de groupe. |
| Groupe | « Enregistrer », « Ajouter membre », « Retirer membre ». |
| Resume | « Supprimer » : deux confirmations sont demandées. |

> [!ATTENTION] Options de compte à haut risque. Pour mot de passe non requis, chiffrement réversible, pré-authentification Kerberos désactivée, DES seul ou délégation, Domenia exige la saisie du mot RISQUE (Security.RequireTypedHighRiskConfirmation). Ne désactivez pas ce contrôle.

Les règles communes à toutes les écritures (objet relu récemment, objets protégés, canal unique, reçus) sont au chapitre 14.

# 5 Outils du poste et compte des opérations poste

La page « Poste » montre le poste sélectionné ; sans poste, elle affiche « Aucun poste ouvert ». Ses outils ouvrent les consoles Windows sur ce poste avec le compte des opérations poste ; ceux qui modifient le poste sont bloqués en lecture seule. Domenia ne change aucun réglage Windows du poste ni du poste d'administration.

Onglets, dans l'ordre : « Machine », « Tableau de bord », « Actions », « Sessions Windows », « Diagnostic », « Inventaire », « Logiciels », « WMI » (profil Expert) et « Secrets ».

![Onglet Machine de la page Poste : carte Fiche du poste avec le DNS, la présence, le système, l'utilisateur associé et sa source](fig:fiche-poste)

L'onglet « Machine » lit le compte ordinateur dans AD. « Detecter l utilisateur » recherche le dernier utilisateur connu ; un lien déjà enregistré n'est pas remplacé.

## Onglet Actions

![Onglet Actions du poste : Ping, Bureau à distance, Ouvrir C$, consoles Windows, Commande PowerShell, puis les actions qui modifient le poste](fig:actions-poste)

| Bouton | Ce que fait Domenia | En lecture seule |
|---|---|---|
| « Ping » | Ping ICMP du poste ; résultat dans la barre d'état. | Disponible. |
| « Bureau à distance » | Lance mstsc.exe vers le poste, avec la session Windows. | Disponible. |
| « Ouvrir C$ » | Ouvre le partage administratif C$ avec le compte des opérations poste, puis l'Explorateur. | Disponible. |
| « Gestion de l ordinateur », « Journaux », « Services » | Ouvre d'abord IPC$ avec le compte des opérations poste, puis compmgmt.msc, eventvwr.exe ou services.msc sur le poste. | Disponibles. |
| « Commande PowerShell » | Copie Enter-PSSession pour ce poste dans le presse-papiers ; aucun second interpréteur n'est lancé, pour limiter les faux positifs antivirus. | Disponible. |
| « Exécuter un programme » | Lance un programme par une tâche planifiée unique, auto-supprimée. | Bloqué au clic. |
| « Actualiser les stratégies », « Redemarrer » | GPUpdate ou redémarrage distant, après confirmation « Oui » ou « Non ». | Grisés. |
| « Activer », « Desactiver » | Active ou désactive le compte ordinateur dans AD. | Grisés. |
| « Renommer dans AD » | Renomme le compte ordinateur dans l'annuaire, pas Windows sur le poste. | Grisé. |
| « Ajouter », « Retirer » (Groupe) | Ajoute ou retire le poste d'un groupe. | Grisés. |

> [!NOTE] « Exécuter un programme » exige aussi, pour ce poste, l'autorisation de 5 minutes « Autoriser une intervention sur cette machine » (onglet « Fiabilité », chapitre 18). Sans elle, Domenia refuse : « Transport avec depot/service/tache non autorise pour cette cible (desactive par defaut). Autorisez-le explicitement dans Outils > Fiabilite, puis relancez votre action. ».

## Ouvrir C$ et les consoles

Depuis le 8 octobre, le contrôle du port 445 et l'ouverture SMB se font dans le worker ComputerAdminShare, hors du fil de l'interface : la fenêtre ne se fige plus pendant l'attente. L'Explorateur ou la console s'ouvre quand le partage répond.

1. **Compte.** Domenia prend le compte des opérations poste (section suivante).
2. **Port.** Il vérifie que le port 445 du poste répond. Sinon : « le partage du poste ne repond pas (port 445). ».
3. **Connexion.** Il ouvre le partage avec ce compte. Un refus affiche le motif Windows après « refuse pour ».
4. **Outil.** Il lance l'Explorateur sur le partage, ou la console demandée. Succès : « C$ de » suivi du poste, de « ouvert avec » et du compte.

Pour les consoles, si l'ouverture préalable échoue, la console s'ouvre quand même avec la session Windows : « Console ouverte avec la session Windows : » suivi du motif. Si le technicien s'est connecté avec « Utiliser mon compte Windows », sans mot de passe, il n'y a pas d'ouverture préalable.

> [!NOTE] Sous les boutons, l'onglet rappelle : « Ouvrir C$ et les consoles utilisent le compte des operations poste : compte poste saisi dans Diagnostic, sinon compte admin distant, sinon compte de connexion. Le bureau a distance passe par Windows. »

## Compte des opérations poste

C'est le compte qui interroge les postes : WMI et CIM, C$, consoles, inventaire, détection et requêtes des widgets. Il peut différer du compte de connexion et n'est jamais enregistré sur le disque. Il se règle dans l'onglet « Diagnostic » : « Compte poste », « Mot de passe », « Utiliser ce compte » et « Compte de connexion » (oublie le compte saisi).

Ordre de choix pour une opération sur un poste :

1. **Compte poste saisi.** Celui de l'onglet « Diagnostic », en mémoire seulement.
2. **Compte distant.** Celui de la zone « POSTES / WMI / DISTANT » de la page « Comptes » (chapitre 13).
3. **Compte de connexion.** Le compte saisi dans la fenêtre de connexion de Domenia.
4. **Session Windows.** La session qui exécute Domenia.

Le libellé sous les champs dit le compte en service : « Operations poste : compte saisi », « Operations poste : compte de connexion Domenia » ou « Operations poste : session Windows ».

## Diagnostic, sessions et secrets

- « Diagnostic » : « Lancer le diagnostic » contrôle le DNS, la joignabilité, les ports, SMB, WinRM, WMI, le système, le disque et la session. « Copier le rapport » copie le résultat pour un ticket.
- « Sessions Windows » : « Lire les sessions » consulte les sessions par WTS, sans déconnexion. Un accès refusé ne signifie pas l'absence de session.
- « Secrets » : lecture de BitLocker et de LAPS avec le compte des secrets, même en lecture seule. « Une valeur a la fois, affichee brievement, jamais journalisee ni mise en cache. ». Le presse-papiers est vidé après Security.AutoClearSecretClipboardSeconds (30 s).

## Transports utilisés

La page « Comptes » affiche ce tableau sous « TRANSPORTS UTILISES ». Domenia l'applique ainsi : « Domenia ne modifie aucun reglage Windows : ni certificat, ni WinRM, ni pare-feu, ni antivirus, ni strategie. ».

| Transport | Usage | Ports | Règle |
|---|---|---|---|
| LDAP | Lectures et écritures de l'annuaire | 389/TCP, signature et scellement Kerberos ou NTLM | Aucun certificat accepté à l'aveugle. |
| CIM / DCOM | Lectures sur les postes | 135/TCP puis ports RPC dynamiques | Lecture seule ; désactivable par Remote.UseCim. |
| CIM / WSMan | Repli des lectures CIM | 5985 ou 5986/TCP | Seulement si WinRM est déjà en service ; jamais activé par Domenia. |
| WTS | Lecture des sessions | RPC, 445/TCP | Consultation seulement. |
| Partage ADMIN$ | Dépôt temporaire d'un script d'intervention | 445/TCP | Inactif sans autorisation explicite pour le poste. |
| Planificateur (COM) | Exécution ponctuelle d'une intervention | RPC | Autorisation explicite ; désactivable par Remote.UseTaskFallback. |
| PsExec | Exécution ponctuelle d'une intervention | 445/TCP | Autorisation explicite ; désactivable par Remote.UsePsExecFallback. |

> [!ATTENTION] Les transports intrusifs (ADMIN$, Planificateur, PsExec) restent inactifs sans autorisation explicite pour le poste. « Autoriser une intervention sur cette machine » (onglet « Fiabilité », chapitre 18) vaut 5 minutes pour la machine sélectionnée et ne couvre que les interventions : une lecture n'y bascule jamais seule. Quand CIM échoue, l'inventaire, la lecture des logiciels, l'explorateur WMI, le diagnostic et « Detecter l utilisateur » rendent un « non lu » et nomment la demande à faire, pour cette lecture seule : « Lire ce poste par tâche planifiée » (même onglet). Ce n'est qu'après cette demande que PsExec puis la tâche planifiée interviennent (Remote.UsePsExecFallback, Remote.UseTaskFallback). PsExec.exe est un composant tiers : faites revoir sa licence avant diffusion.

# 6 Inventaire du poste

L'onglet « Inventaire » lit le poste par CIM, avec le compte des opérations poste, et ne modifie rien. Le même inventaire remplit l'onglet « Tableau de bord ». Le résultat dit source par source ce qui a été lu, refusé ou indisponible.

## Rapide ou complet

| Bouton | Ce qui est lu |
|---|---|
| « Rapide » | Matériel, système, disques, réseau, sécurité, correctifs, logiciels, services, comptes, partages et imprimantes. |
| « Complet » | Tout le rapide, plus les processus, les tâches planifiées, les certificats, les connexions réseau et les erreurs récentes. Plus long. |

L'onglet « Tableau de bord » propose les mêmes lectures avec « Inventaire rapide » et « Inventaire complet ». Délai maximal, fixé dans le code : 110 s pour le rapide, 260 s pour le complet.

## Lire le résultat

- Le message de fin donne le nombre d'éléments et le nombre de sources accessibles, refusées, indisponibles ou autres, avec la durée.
- Le volet « Detail par source » donne pour chaque catégorie l'accès, le nombre d'éléments, la durée et le détail. Une source refusée signale un manque de droits du compte des opérations poste sur cette partie, pas une panne du poste.
- « Copier » et « Exporter CSV » servent au ticket.

| Vous voyez | Que faire |
|---|---|
| « Selectionne une machine avant de lancer l inventaire. » | Choisir un poste dans « Rechercher ». |
| « Inventaire impossible : » suivi d'un détail | Vérifier la présence réseau et le compte des opérations poste, puis relancer une fois. |
| Beaucoup de sources refusées | Vérifier que le compte des opérations poste est administrateur des postes (chapitre 13). |
| Sur l'onglet « Tableau de bord » : « Mesures chiffrees indisponibles (inventaire par tache distante) : seules les tuiles sont remplies. » | L'inventaire a été lu par le repli PsExec ou tâche planifiée, possible seulement après « Autoriser une intervention sur cette machine » (chapitre 5) ; jauges et graphiques restent vides. Vérifier CIM/DCOM sur le poste. |

# 7 Tableau de bord du poste

Le tableau du poste résume le dernier inventaire et les attributs du compte ordinateur lus avec la fiche. Il n'envoie aucune requête de plus, sauf les widgets de requêtes WMI qu'on actualise explicitement. Un score de santé et une liste de points d'attention en donnent la lecture rapide.

![Tableau de bord du poste PC-COMPTA-014 : score État général, points d'attention, identité du poste, compte machine dans AD et ressources mesurées](fig:tableau-poste)

## D'où viennent les données

| Section | Source | Si vide |
|---|---|---|
| Vue d ensemble | Calculée sur toutes les vérifications ci-dessous. | — |
| Identite du poste | Inventaire rapide ou complet. | « Lancez un inventaire (Rapide ou Complet) pour remplir cette section. » |
| Compte machine dans Active Directory | Attributs lus avec la fiche du poste. | « Ouvrez la fiche du poste dans l annuaire pour lire son compte machine. » |
| Ressources | Mesures de l'inventaire par CIM. | « Lancez un inventaire pour mesurer la memoire, le processeur et les disques. » |
| Activite | Inventaire complet. | « Inventaire complet requis : correctifs, processus et evenements. » |
| Securite et etat | Inventaire complet. | « Inventaire complet requis : protection, correctifs et configuration. » |

Quand on sélectionne un autre objet, les tableaux du poste et des logiciels oublient leurs données et leur annulation.

## Score de santé

- Score = 100 − 25 par point critique − 10 par point à surveiller, jamais sous 0. Les informations ne comptent pas.
- Verdict : au moins un point critique donne « Critique » ; sinon 85 et plus « Bon etat », 60 et plus « A surveiller », en dessous « Degrade ».
- Exemples : un point à surveiller donne 90 « Bon etat » ; un point critique donne 75 « Critique ».
- Le score et la liste portent sur toutes les vérifications, que leur widget soit affiché ou non. La liste est triée : critiques, à surveiller, puis informations.

## Règles du poste

| Vérification | Seuil | Niveau | Message (N = valeur lue) |
|---|---|---|---|
| Mot de passe du compte ordinateur (pwdLastSet) | Plus de 45 jours | À surveiller | Mot de passe machine renouvele il y a N jours : relation d approbation a verifier. |
| Dernière connexion au domaine (lastLogonTimestamp) | Plus de 90 jours | À surveiller | Aucune connexion au domaine depuis N jours. |
| Compte ordinateur | Désactivé | Critique | Compte ordinateur desactive dans AD. |
| Mot de passe LAPS | Expiration passée | À surveiller | Mot de passe LAPS expire (rotation en attente). |
| Horloge du poste | Plus de 300 s d'écart | Critique | Horloge decalee de N s : Kerberos refusera l authentification. |
| Horloge du poste | Plus de 60 s d'écart | À surveiller | Horloge decalee de N s. |
| Windows 10 (builds 19043 à 19045) | Toujours | Critique | Version suivie de : fin de support depuis le 14/10/2025, poste a migrer. |
| Durée de fonctionnement | Plus de 30 jours | À surveiller | Pas de redemarrage depuis N jours. |
| Mémoire utilisée | Plus de 90 % | À surveiller | Memoire utilisee a plus de 90 %. |
| Batterie | Moins de 20 % | À surveiller | Batterie a N %. |
| Disque système | Moins de 10 % libre | Critique | Disque C: presque plein : N % libre. |
| Disque système | Moins de 20 % libre | À surveiller | Disque C: : N % libre. |
| Autres volumes | Moins de 10 % libre | Critique | Volume X: presque plein : N % libre. |
| Journal Système (3 jours) | Au moins une erreur | À surveiller | N erreur(s) dans le journal Systeme sur 3 jours. |
| Pare-feu | Un profil désactivé | À surveiller | Pare-feu : N profil(s) desactive(s). |
| BitLocker (C: d'abord) | Volume non protégé | À surveiller | BitLocker : suivi de l'état lu. |
| Redémarrage en attente | Demandé | À surveiller | Redemarrage en attente. |
| Services automatiques arrêtés, périphériques en erreur, pilotes non signés | Au moins un | À surveiller | N services automatiques arretes. (et équivalents) |
| Dernier correctif installé | Plus de 60 jours | À surveiller | Dernier correctif installe il y a N jours. |

Les widgets « Administrateurs locaux », « Sessions et comptes locaux », « Demarrage automatique », « Partages », « Imprimantes » et « Certificats machine » comptent sans lever de point d'attention. L'horloge est comparée à celle du poste d'administration qui exécute Domenia.

## Versions de Windows reconnues

| Build | Poste | Serveur |
|---|---|---|
| 26200 | Windows 11 25H2 | — |
| 26100 | Windows 11 24H2 | Windows Server 2025 |
| 22631 | Windows 11 23H2 | — |
| 22621 | Windows 11 22H2 | — |
| 22000 | Windows 11 21H2 | — |
| 20348 | — | Windows Server 2022 |
| 19045, 19044, 19043 | Windows 10 22H2, 21H2, 21H1 | — |
| 17763 | — | Windows Server 2019 |
| 14393 | — | Windows Server 2016 |

Un autre build s'affiche « Build » suivi du numéro. Le serveur est reconnu par le mot server dans la légende du système.

# 8 Vue d'ensemble du parc

La carte « Vue d ensemble du parc » de l'Accueil se calcule depuis la base autonome locale et les derniers relevés, sans requête AD ni poste. Elle suit l'OU choisie dans l'arbre de « Rechercher » et ne lance aucune analyse : les pings, détections et analyses partent de « Rechercher », sur la liste affichée (chapitre 3).

![Accueil : périmètre suivi depuis Rechercher, bouton Changer dʼOU, rappel des analyses de Rechercher, puis les widgets du parc](fig:accueil)

## Périmètre

- La vue reprend l'OU sélectionnée dans l'arbre de « Rechercher » et la case « Inclure les sous-OU » : cochée, l'OU et ses sous-OU ; décochée, ses postes directs seulement. Aucune préférence propre à l'Accueil n'est enregistrée ; l'OU est celle que « Rechercher » mémorise pour le domaine et le compte.
- La ligne « Périmètre » affiche le nom de l'OU, suivi de « et ses sous-OU » ou de « (sans les sous-OU) » ; l'info-bulle donne le DN complet. Avec la racine du domaine : « Tout le domaine indexe (consultation) ».
- « Changer dʼOU » ouvre « Rechercher » et place le focus sur l'arbre des OU.
- « Actualiser » recalcule la vue depuis la base locale. Sans ce bouton, la vue se recalcule d'elle-même quand l'Accueil s'affiche et que l'OU ou les données ont changé : autre OU dans « Rechercher », fin d'un relevé, mise à jour de la base autonome une fois enregistrée, purge des observations, nouvelle session.

> [!NOTE] La vue n'est complète que si la base autonome l'est. Après l'installation, remplissez-la avec « Mettre a jour tout » (chapitre 18) ; le sous-titre de la carte le rappelle.

## Calcul en arrière-plan

1. **Lecture.** Le worker LocalIndexRead (action FleetStats) lit la base locale en lecture seule. Il garde les comptes ordinateur actifs de l'OU, selon la profondeur choisie, et décode lui-même les observations enregistrées : présence, utilisateur console, relevé WMI et résultats des requêtes. Une observation de plus de 256 Ko est ignorée.
2. **Un seul calcul à la fois.** Pour la même OU, Domenia attend la fin du calcul en cours ; pour une autre OU, le nouveau calcul remplace l'ancien, dont le résultat n'est pas affiché. Au démarrage, la vue attend que « Rechercher » ait retrouvé son OU mémorisée : « En attente de l OU memorisee dans Rechercher... ».
3. **Affichage.** Le fil de l'interface ne fait que regrouper les postes de l'OU et dessiner les widgets.

Les observations de tous les postes restent en mémoire après le calcul : le tableau d'un poste affiche ses résultats de requêtes même s'il est hors de l'OU. Une observation lue depuis le dernier enregistrement l'emporte sur celle de la base, plus ancienne.

## Remplir la vue

| Section | Source | Comment la remplir |
|---|---|---|
| « Vue d ensemble », « Inventaire du perimetre », « Repartition » | Base autonome locale | « Mettre a jour tout » ou « Mettre a jour les changements » (chapitre 18). |
| Présence, « Utilisateurs detectes », « Derniere analyse » | Observations des relevés | « Pinger la liste » ou « Détecter la liste » dans « Rechercher ». |
| « Releves WMI » et widgets de requête du parc | Relevé WMI léger et requêtes | « Analyser la liste » dans « Rechercher ». |

Le relevé WMI léger lit Win32_OperatingSystem (Caption, BuildNumber, LastBootUpTime), Win32_ComputerSystem (Manufacturer, Model, TotalPhysicalMemory) et Win32_LogicalDisk filtré sur C: (Size, FreeSpace).

## Ce que fait Domenia sur chaque poste

1. **Nom.** Il contrôle le nom du poste : 253 caractères au plus, lettres, chiffres, point, tiret et tiret bas.
2. **Ping.** Un seul ping ICMP de 900 ms, adresse IPv4 préférée.
3. **Session CIM.** Il ouvre une session CIM en DCOM avec le compte des opérations poste, délai de 4 s, et lit Win32_ComputerSystem.UserName.
4. **Lectures.** Seulement si la console a été lue : relevé WMI léger et requêtes des widgets pour « Analyser la liste », requêtes seules pour « Actualiser les requetes » du tableau du poste (chapitre 10).
5. **Enregistrement.** L'observation est fusionnée avec la précédente et enregistrée dans la base locale.

Le suivi s'affiche sous les boutons de « Rechercher » : « Ping en cours » ou « Releve en cours », avec les postes vérifiés, joignables, les identités en cache, les associations actualisées et les lectures non confirmées. En fin de relevé, la vue d'ensemble se recalcule seule. Si le stockage local est indisponible : « Observation en memoire seulement : stockage local indisponible. ».

## Refus

| Vous voyez | Cause | Que faire |
|---|---|---|
| « Releve impossible : » puis « Un releve est deja en cours. » | Un relevé tourne déjà. | Attendre ou « Arrêter ». |
| « Releve impossible : » puis « Attendez la confirmation des enregistrements locaux avant un nouveau releve. » | Enregistrements locaux en attente. | Attendre quelques secondes. |
| « Vue d ensemble non calculee : » puis « base occupee, reessayez dans un instant. » | Base locale occupée. | « Actualiser » un peu plus tard. |
| « Aucune base autonome active : vue d ensemble indisponible. » | Pas de base pour ce domaine. | Chapitre 18. |

## Règles du parc

| Vérification | Seuil | Niveau | Message (N = nombre de postes) |
|---|---|---|---|
| Système déclaré dans l'annuaire | Au moins un Windows 10 | Critique | N poste(s) sous Windows 10, fin de support depuis le 14/10/2025. |
| Dernière connexion au domaine | 90 jours ou plus | À surveiller | N poste(s) sans connexion au domaine depuis 90 jours ou plus : a verifier ou nettoyer. |
| Comptes jamais connectés | Au moins un | À surveiller | N compte(s) ordinateur jamais connecte(s). |
| Présence au dernier relevé | Au moins un sans réponse | Information | N poste(s) sans reponse au dernier releve. |
| Disque C: (relevé WMI) | Moins de 10 % libre | Critique | N poste(s) avec moins de 10 % libre sur C:. |
| Démarrage (relevé WMI) | Plus de 30 jours | À surveiller | N poste(s) non redemarre(s) depuis plus de 30 jours. |

Le score du parc suit la formule du chapitre 7. Les informations ne baissent pas le score.

## Calculs des répartitions

- Dernière connexion : tranches « <7j », « 7-30j », « 30-90j », « 90-180j », « >180j » et « Jamais », toutes gardées même vides.
- Systèmes : préfixe Microsoft retiré, Professionnel abrégé en Pro ; six premiers, puis « Autres ».
- Postes par OU : avec une OU choisie, regroupement par sous-OU directe ; dix premières, puis « Autres ».
- Présence : « En ligne », « Sans reponse » ou « Non verifie », y compris les postes jamais observés.
- Mémoire : 4 Go et moins, 8, 16, 32, puis plus de 32 Go. Espace libre sur C: : moins de 10 %, 10 à 25 %, 25 à 50 %, plus de 50 %.

## Détails de la session

La carte repliée « Détails de la session et outils de vérification » donne le domaine, le serveur, le compte d'exécution AD, le mode, la base DN et l'état des composants. Elle propose « Verifier l application », « Vider le cache » et « Ouvrir le journal » (chapitre 20).

# 9 Widgets : fonctionnement et catalogue complet

Les trois tableaux de bord sont faits de widgets : chaque tuile ou graphique se modifie, se déplace, se redimensionne et se retire. On ajoute un widget depuis le catalogue intégré ou, pour le poste et le parc, depuis les requêtes WMI prêtes à l'emploi. Chaque utilisateur garde sa disposition dans ses préférences.

| Tableau | Où | Données |
|---|---|---|
| Parc | Accueil, sous les boutons d'analyse. | Agrégats de la base autonome et observations en cache. |
| Poste | Poste, onglet « Tableau de bord ». | Dernier inventaire et attributs du compte ordinateur. |
| Logiciels | Poste, onglet « Logiciels », volet « Synthese en graphiques ». | Liste des logiciels chargée. |

## Barre d'outils

| Bouton | Quand | Effet |
|---|---|---|
| « Actualiser les requetes » | Tableau du poste, si au moins un widget de requête est présent. | Exécute les requêtes WMI des widgets sur le poste sélectionné, en lecture seule, après confirmation (chapitre 10). Sur le parc, les requêtes partent avec « Analyser la liste » dans « Rechercher ». |
| « Ajouter un widget » | Toujours. | Ouvre l'éditeur. |
| « Personnaliser » | Hors personnalisation. | Passe en mode personnalisation. |
| « Par defaut » | En personnalisation. | Revient à la disposition livrée, sans confirmation mais annulable. |
| « Terminer » | En personnalisation. | Quitte la personnalisation. |
| « Annuler » | Après une modification. | Revient à la disposition précédente. |

L'annulation n'a qu'un niveau. Elle est perdue quand de nouvelles données arrivent et, pour le poste et les logiciels, quand on sélectionne un autre objet. « Retirer » ne demande pas de confirmation : « Annuler » sert de filet.

## Personnaliser, menu et glisser-déposer

![Tableau du poste en mode Personnaliser : boutons Modifier et Retirer sur chaque widget, tuiles Ajouter ici en fin de section, boutons Par defaut et Terminer](fig:personnaliser)

- En personnalisation, chaque section se termine par une tuile en pointillés « Ajouter ici », qui ouvre l'éditeur avec la section choisie. Les boutons ronds de modification et de retrait restent visibles ; hors personnalisation, ils apparaissent au survol ou au clavier.
- Les widgets sans donnée restent visibles en personnalisation (« Aucune donnee pour le moment »). Hors personnalisation, un widget intégré sans donnée est masqué.
- Le menu clic droit d'un widget, toujours disponible, propose « Modifier... », « Representation », « Taille » (« Compacte », « Moyenne », « Large »), « Deplacer » et « Retirer du tableau de bord ». Les déplacements du menu restent dans la section.
- Le glisser-déposer est toujours actif. Lâché sur un autre widget, le widget prend sa place et sa section ; lâché dans une section hors d'un widget, il va à la fin de cette section. La page défile près des bords.

## Éditeur de widget

![Panneau Ajouter un widget : recherche, liste des informations disponibles, puis titre, représentation, taille, section et aperçu en direct](fig:editeur-widget)

- À gauche, en ajout seulement : la recherche (« Rechercher : disque, utilisateur, BitLocker... ») et la liste des informations disponibles, groupée en « Tableau de bord » puis en « Requetes WMI » par catégorie. Le badge « affiche » marque ce qui est déjà sur le tableau.
- La recherche ignore accents et casse ; tous les mots tapés doivent se trouver dans le nom, la description ou la section (pour une requête : le nom, la catégorie ou la classe).
- À droite : « Titre », « Representation », « Taille », « Section » et l'aperçu. La liste « Section » propose les sections du tableau, puis « + Nouvelle section... », qui affiche un champ pour taper son nom ; laissé vide, ce nom devient « Mes widgets ».
- L'aperçu montre les vraies données si le tableau en a, sinon un exemple de même nature.
- Un widget ajouté va à la fin de sa section. Sans donnée encore lue : « Widget enregistre : il s affichera des que ses donnees seront lues. ».

## Natures, représentations et tailles

Chaque widget porte une nature de donnée. Elle fixe les représentations permises ; le sous-menu « Representation » n'apparaît que s'il y en a plusieurs. Une représentation enregistrée qui n'est plus permise est remplacée par la préférée.

| Nature | Représentations permises, la préférée d'abord |
|---|---|
| Valeur (Value) | Chiffre cle, Liste |
| Mesure avec maximum (Number) | Jauge, Chiffre cle, Liste |
| Mesure sans maximum (Number) | Chiffre cle, Liste |
| Répartition (Distribution) | Anneau, Barres, Histogramme, Liste, Chiffre cle |
| Valeurs numériques (Measure) | Histogramme, Barres, Courbe, Chiffre cle, Liste |
| Série ordonnée (Series) | Histogramme, Courbe, Barres, Liste, Chiffre cle |
| Liste de points (List) | Liste de points |
| Score (Health) | Score, Chiffre cle |

| Représentation | Compacte | Moyenne | Large |
|---|---|---|---|
| Chiffre cle | 230 × 118 | 345 × 118 | 475 × 118 |
| Liste | 300 × auto | 420 × auto | 560 × auto |
| Anneau | 310 × 250 | 390 × 250 | 490 × 250 |
| Barres, Histogramme, Courbe | 320 × 250 | 440 × 250 | 600 × 250 |
| Jauge, Score | 230 × 250 | 300 × 250 | 380 × 250 |
| Liste de points | 380 × auto | 500 × auto | 660 × auto |

Dimensions en pixels, largeur × hauteur ; auto suit le contenu. Limites d'affichage : un anneau montre 8 parts au plus, les plus petites regroupées en « Autres » ; une liste montre 10 lignes, la liste de points 9. Une jauge passe à l'orange au-delà de 80 % et au rouge au-delà de 90 %, sens inversé pour la batterie.

## Enregistrement de la disposition

- Une clé par tableau dans les préférences de l'utilisateur : Dashboard.Computer.Layout, Dashboard.Fleet.Layout et Dashboard.Software.Layout. Chaque élément garde son identifiant, sa source (Builtin pour le catalogue, Probe pour une requête), sa clé, sa représentation, son titre, sa taille et sa section.
- Rien d'enregistré donne la disposition livrée, c'est-à-dire tout le catalogue dans son ordre. Une liste vide enregistrée est un tableau vidé volontairement et reste vide.
- À la lecture, un widget inconnu du catalogue est écarté, les identifiants sont rendus uniques, représentation et taille sont corrigées.
- Les anciennes clés Widgets.Computer et Widgets.Fleet (première version des widgets de requête) sont reprises dans la disposition, puis vidées au premier enregistrement.
- L'écriture est différée de 1,5 s pour regrouper les changements ; un changement sans effet n'est ni enregistré ni proposé à l'annulation.

## Animation

À chaque nouvelle lecture, les cartes apparaissent l'une après l'autre, puis anneaux et barres se dessinent et les chiffres comptent depuis zéro. L'animation est coupée quand l'animation Windows est désactivée, par exemple pour l'accessibilité ou une session à distance. Aucun réglage Domenia ne la coupe.

## Catalogue du tableau du poste (42 widgets)

| Titre | Clé | Section | Par défaut | Description |
|---|---|---|---|---|
| Etat general | computer.health | Vue d ensemble | Score, Compacte | Score calcule a partir des points d attention |
| Points d attention | computer.attention | Vue d ensemble | Liste de points, Large | Problemes detectes, du plus grave au moins grave |
| Systeme | computer.os | Identite du poste | Chiffre cle, Compacte | Version commerciale de Windows et build |
| Modele | computer.model | Identite du poste | Chiffre cle, Compacte | Fabricant, modele et numero de serie |
| Processeur | computer.cpu | Identite du poste | Chiffre cle, Compacte | Modele, coeurs et threads |
| Memoire installee | computer.memory | Identite du poste | Chiffre cle, Compacte | Memoire physique et barrettes |
| En service depuis | computer.uptime | Identite du poste | Chiffre cle, Compacte | Duree depuis le dernier demarrage |
| Utilisateur connecte | computer.user | Identite du poste | Chiffre cle, Compacte | Session console au moment de l inventaire |
| Adresse IP | computer.ip | Identite du poste | Chiffre cle, Compacte | Adresse IPv4 et passerelle |
| Domaine | computer.domain | Identite du poste | Chiffre cle, Compacte | Domaine et role du poste |
| Mot de passe machine | computer.ad.password | Compte machine dans Active Directory | Chiffre cle, Compacte | Age du mot de passe du compte ordinateur |
| Derniere connexion au domaine | computer.ad.lastlogon | Compte machine dans Active Directory | Chiffre cle, Compacte | Attribut lastLogonTimestamp |
| Compte ordinateur | computer.ad.account | Compte machine dans Active Directory | Chiffre cle, Compacte | Actif ou desactive, date de creation |
| Unite d organisation | computer.ad.ou | Compte machine dans Active Directory | Chiffre cle, Compacte | OU qui contient le poste |
| Mot de passe LAPS | computer.ad.laps | Compte machine dans Active Directory | Chiffre cle, Compacte | Expiration du mot de passe administrateur local |
| Gere par | computer.ad.managedby | Compte machine dans Active Directory | Chiffre cle, Compacte | Attribut managedBy |
| Horloge du poste | computer.ad.clock | Compte machine dans Active Directory | Chiffre cle, Compacte | Ecart avec le poste d administration |
| Memoire utilisee | computer.memory.usage | Ressources | Jauge, Compacte | Memoire occupee au moment de l inventaire |
| Charge du processeur | computer.cpu.load | Ressources | Jauge, Compacte | Charge du processeur au moment de l inventaire |
| Batterie | computer.battery | Ressources | Jauge, Compacte | Charge restante des postes portables |
| Disque systeme | computer.disk.system | Ressources | Anneau, Moyenne | Espace utilise et libre sur C: |
| Autres volumes | computer.disk.volumes | Ressources | Barres, Moyenne | Espace libre des autres volumes, en pourcentage |
| Services Windows | computer.services | Activite | Anneau, Moyenne | Services en cours, arretes et desactives |
| Processus les plus gourmands | computer.processes | Activite | Barres, Large | Memoire utilisee par processus, en Mo |
| Erreurs systeme par source | computer.events | Activite | Barres, Moyenne | Journal Systeme des 3 derniers jours |
| Antivirus | computer.antivirus | Securite et etat | Chiffre cle, Compacte | Produit antivirus declare a Windows |
| Pare-feu | computer.firewall | Securite et etat | Chiffre cle, Compacte | Profils du pare-feu actifs |
| BitLocker | computer.bitlocker | Securite et etat | Chiffre cle, Compacte | Protection du volume systeme |
| Windows Update | computer.wsus | Securite et etat | Chiffre cle, Compacte | Serveur WSUS configure |
| Redemarrage en attente | computer.reboot | Securite et etat | Chiffre cle, Compacte | Redemarrage demande par une installation |
| Services automatiques arretes | computer.services.stopped | Securite et etat | Chiffre cle, Compacte | Services automatiques a l arret |
| Peripheriques en erreur | computer.devices | Securite et etat | Chiffre cle, Compacte | Peripheriques signales en erreur |
| Pilotes non signes | computer.drivers | Securite et etat | Chiffre cle, Compacte | Pilotes sans signature numerique |
| Administrateurs locaux | computer.admins | Securite et etat | Chiffre cle, Compacte | Membres du groupe Administrateurs |
| Sessions et comptes locaux | computer.sessions | Securite et etat | Chiffre cle, Compacte | Comptes et sessions du poste |
| Demarrage automatique | computer.autostart | Securite et etat | Chiffre cle, Compacte | Programmes lances au demarrage |
| Partages | computer.shares | Securite et etat | Chiffre cle, Compacte | Dossiers partages par le poste |
| Imprimantes | computer.printers | Securite et etat | Chiffre cle, Compacte | Imprimantes installees |
| Affichage | computer.display | Securite et etat | Chiffre cle, Compacte | Carte graphique et resolution |
| Disque physique | computer.physicaldisk | Securite et etat | Chiffre cle, Compacte | Modele et interface du disque |
| Certificats machine | computer.certificates | Securite et etat | Chiffre cle, Compacte | Certificats du magasin ordinateur |
| Dernier correctif | computer.hotfix | Securite et etat | Chiffre cle, Compacte | Date du dernier correctif installe |

## Catalogue du tableau du parc (17 widgets)

| Titre | Clé | Section | Par défaut | Description |
|---|---|---|---|---|
| Etat du parc | fleet.health | Vue d ensemble | Score, Compacte | Score calcule a partir des points d attention |
| Points d attention | fleet.attention | Vue d ensemble | Liste de points, Large | Problemes detectes sur le perimetre |
| Postes actifs | fleet.machines | Inventaire du perimetre | Chiffre cle, Compacte | Comptes ordinateur actifs du perimetre |
| Postes inactifs (90 j et plus) | fleet.stale | Inventaire du perimetre | Chiffre cle, Compacte | Sans connexion au domaine depuis 90 jours |
| Postes sous Windows 10 | fleet.win10 | Inventaire du perimetre | Chiffre cle, Compacte | Fin de support le 14/10/2025 |
| Utilisateurs detectes | fleet.users | Inventaire du perimetre | Chiffre cle, Compacte | Utilisateurs vus sur les postes |
| Derniere analyse | fleet.lastcheck | Inventaire du perimetre | Chiffre cle, Compacte | Date du dernier releve des postes |
| Systemes d exploitation | fleet.os | Repartition | Anneau, Moyenne | Systemes declares dans l annuaire |
| Derniere connexion au domaine | fleet.lastlogon | Repartition | Histogramme, Moyenne | Anciennete de la derniere connexion |
| Postes par unite d organisation | fleet.ou | Repartition | Barres, Moyenne | Postes par OU ou sous-OU |
| Presence reseau | fleet.presence | Repartition | Anneau, Moyenne | Resultat des derniers releves |
| Modeles | fleet.models | Releves WMI | Barres, Moyenne | Modeles des postes analyses |
| Versions de Windows | fleet.releases | Releves WMI | Anneau, Moyenne | Versions commerciales relevees |
| Memoire installee | fleet.ram | Releves WMI | Histogramme, Moyenne | Postes par quantite de memoire |
| Espace libre sur C: | fleet.diskfree | Releves WMI | Histogramme, Moyenne | Postes par espace libre du disque systeme |
| Disque C: presque plein | fleet.lowdisk | Releves WMI | Chiffre cle, Compacte | Postes avec moins de 10 % libre |
| Non redemarres depuis 30 j | fleet.uptime | Releves WMI | Chiffre cle, Compacte | Postes a redemarrer |

Les sections « Vue d ensemble », « Inventaire du perimetre » et « Repartition » viennent de la base autonome ; la section « Releves WMI » se remplit avec « Analyser la liste » dans « Rechercher ».

## Catalogue du tableau des logiciels (11 widgets)

| Titre | Clé | Section | Par défaut | Description |
|---|---|---|---|---|
| Logiciels | software.count | Synthese | Chiffre cle, Compacte | Nombre de logiciels et d editeurs |
| Taille declaree | software.size | Synthese | Chiffre cle, Compacte | Somme des tailles connues |
| Installés ces 30 derniers jours | software.recent | Synthese | Chiffre cle, Compacte | Date dʼinstallation déclarée par le logiciel, lue dans la liste |
| Installes en plusieurs versions | software.multiversion | Synthese | Chiffre cle, Compacte | Logiciels presents en plusieurs versions |
| Sans editeur declare | software.nopublisher | Synthese | Chiffre cle, Compacte | Logiciels sans editeur renseigne |
| Composants dʼexécution | software.runtime | Synthese | Chiffre cle, Compacte | Socles Visual C++, .NET et WebView2 déclarés dans la liste |
| Navigateurs et versions | software.browsers | Synthese | Chiffre cle, Compacte | Navigateurs détectés dans la liste, avec leur version |
| Editeurs | software.publishers | Repartition | Anneau, Moyenne | Principaux editeurs |
| Architecture | software.architecture | Repartition | Anneau, Moyenne | Logiciels 32 et 64 bits |
| Portee d installation | software.scope | Repartition | Anneau, Moyenne | Installation machine ou utilisateur |
| Plus gros logiciels | software.largest | Repartition | Barres, Large | Taille declaree, en Mo |

# 10 Requêtes WMI prêtes à l'emploi

Le catalogue propose 52 requêtes WMI en lecture seule, en 8 catégories. On les ajoute comme widgets aux tableaux du poste et du parc depuis l'éditeur. Elles partent après confirmation, jamais sur le domaine entier : « Actualiser les requetes » sur le tableau du poste interroge le poste sélectionné ; « Analyser la liste » dans « Rechercher » interroge les postes affichés avec les requêtes des tableaux du poste et du parc.

## Pourquoi c'est sûr

- Le worker ne reçoit jamais un texte de requête libre : seulement l'identifiant, l'espace de noms, la classe, les propriétés, le filtre et le mode, tirés du catalogue.
- Avant l'appel, la classe et l'espace de noms sont contrôlés ; un nom non conforme donne « Requete refusee. » et une propriété non conforme est ignorée.
- L'appel est une lecture d'instances par Get-CimInstance ; aucune méthode WMI n'est invoquée par ce chemin.
- Les requêtes passent dans la session CIM de la détection, seulement si la lecture de la console a réussi.
- Une erreur est notée pour sa requête sans arrêter les autres.

## Exécution

1. **Lancer.** Poste : cliquez « Actualiser les requetes » sur son tableau ; il faut un poste sélectionné. Parc : dans « Rechercher », affichez les postes puis cliquez « Analyser la liste ». Les requêtes des widgets présents sont regroupées, sans doublon.
2. **Confirmer.** Poste : confirmation « Sonder pour les widgets », bouton « Verifier les sessions ». Parc : confirmation « Analyser les postes affiches », bouton « Analyser ». Les deux donnent le nombre de postes et de requêtes ; « Annuler » ne lance rien.
3. **Suivre.** Quatre postes au plus à la fois. Délai par poste : 20 s plus 8 s par requête, plafonné à 150 s.
4. **Lire.** En fin de relevé, les widgets se remplissent et la vue du parc se recalcule.

| Vous voyez | Que faire |
|---|---|
| « Aucune requete WMI sur ce tableau de bord : ajoutez un widget de requete. » | Ajouter un widget de requête avec « Ajouter un widget ». |
| « Requetes du parc : dans Rechercher, affichez les postes puis Analyser la liste. » | Le parc n'a pas de bouton de requête : utiliser « Analyser la liste ». |
| « Aucun poste selectionne. » | Choisir un poste dans « Rechercher ». |

## Lecture des résultats

- Résultats par poste : 20 instances au plus, textes coupés à 200 caractères, dates en UTC. Le dernier résultat de chaque requête est gardé dans l'observation du poste.
- Tableau du poste : toujours une valeur (chiffre clé ou liste), avec la catégorie et le nom de la requête.
- Tableau du parc : une requête de comptage ou à transformation numérique devient une mesure (moyenne, minimum, maximum, histogramme par tranches) ; les autres deviennent une répartition (valeur la plus fréquente, nombre de postes).
- Sans résultat, le widget affiche « En attente » et, sur le poste, « Actualiser les requetes pour remplir ce widget » ; sur le parc, « Dans Rechercher, Analyser la liste remplit ce widget ».

Modes : First lit la première instance, Count compte les instances, All lit toutes les instances. Transformations : Text, GB (octets en Go), GBfromKB (Ko en Go), MB, Mbps, Number, DaysSince (jours écoulés), Year, PercentFree (pourcentage libre), Release (build en nom de version) et Map (table de correspondance). Dans les filtres, {SINCE_24H} et {SINCE_7D} sont remplacés par la date UTC d'il y a 24 heures ou 7 jours.

> [!NOTE] La requête « Contrôle de compte (EnableLUA) » figure dans le code du catalogue mais en est retirée à la lecture : elle n'est pas proposée. Le catalogue compte donc 52 requêtes, pas 53.

## Catalogue : Materiel (13)

Toutes ces classes sont dans root\cimv2.

| Nom | Classe et propriété | Filtre | Mode | Transformation |
|---|---|---|---|---|
| Fabricant | Win32_ComputerSystem.Manufacturer | — | First | Text |
| Modele | Win32_ComputerSystem.Model | — | First | Text |
| Memoire installee | Win32_ComputerSystem.TotalPhysicalMemory | — | First | GB |
| Processeur | Win32_Processor.Name | — | First | Text |
| Coeurs du processeur | Win32_Processor.NumberOfCores | — | First | Number |
| Processeurs logiques | Win32_ComputerSystem.NumberOfLogicalProcessors | — | First | Number |
| Version du BIOS | Win32_BIOS.SMBIOSBIOSVersion | — | First | Text |
| Annee du BIOS | Win32_BIOS.ReleaseDate | — | First | Year |
| Carte graphique | Win32_VideoController.Name | — | First | Text |
| Nombre d ecrans | Win32_DesktopMonitor.Name | — | Count | Number |
| Batterie presente | Win32_Battery.Name | — | Count | Map:0=Non;1=Oui;2=Oui |
| Type de systeme | Win32_ComputerSystem.PCSystemType | — | First | Map:1=Bureau;2=Portable;3=Station;4=Serveur;5=Serveur;8=Tablette |
| Numero de serie | Win32_BIOS.SerialNumber | — | First | Text |

## Catalogue : Systeme (9)

| Nom | Classe et propriété | Filtre | Mode | Transformation |
|---|---|---|---|---|
| Edition de Windows | Win32_OperatingSystem.Caption | — | First | Text |
| Version de Windows | Win32_OperatingSystem.BuildNumber, ProductType | — | First | Release |
| Architecture | Win32_OperatingSystem.OSArchitecture | — | First | Text |
| Jours depuis le dernier demarrage | Win32_OperatingSystem.LastBootUpTime | — | First | DaysSince |
| Annee d installation de Windows | Win32_OperatingSystem.InstallDate | — | First | Year |
| Langue du systeme | Win32_OperatingSystem.OSLanguage | — | First | Map:1036=Francais;1033=Anglais (US);2057=Anglais (UK);1031=Allemand;1034=Espagnol;1040=Italien |
| Fuseau horaire | Win32_TimeZone.Caption | — | First | Text |
| Fichier d echange (Mo) | Win32_PageFileUsage.AllocatedBaseSize | — | First | Number |
| Memoire libre (Go) | Win32_OperatingSystem.FreePhysicalMemory | — | First | GBfromKB |

## Catalogue : Disques (6)

| Nom | Classe et propriété | Filtre | Mode | Transformation |
|---|---|---|---|---|
| Espace libre sur C: (%) | Win32_LogicalDisk.FreeSpace, Size | DeviceID='C:' | First | PercentFree |
| Taille de C: (Go) | Win32_LogicalDisk.Size | DeviceID='C:' | First | GB |
| Nombre de volumes locaux | Win32_LogicalDisk.DeviceID | DriveType=3 | Count | Number |
| Type de disque physique | MSFT_PhysicalDisk.MediaType (root\Microsoft\Windows\Storage) | — | First | Map:3=Disque dur;4=SSD;5=SCM;0=Non precise |
| Sante du disque physique | MSFT_PhysicalDisk.HealthStatus (root\Microsoft\Windows\Storage) | — | First | Map:0=Sain;1=Avertissement;2=Defaillant;5=Inconnu |
| Supports amovibles connectes | Win32_LogicalDisk.DeviceID | DriveType=2 | Count | Number |

## Catalogue : Securite (4)

| Nom | Classe et propriété | Filtre | Mode | Transformation |
|---|---|---|---|---|
| Chiffrement BitLocker de C: | Win32_EncryptableVolume.ProtectionStatus (root\cimv2\Security\MicrosoftVolumeEncryption) | DriveLetter='C:' | First | Map:0=Non protege;1=Protege;2=Inconnu |
| Antivirus declare | AntiVirusProduct.displayName (root\SecurityCenter2) | — | All | Text |
| Comptes locaux actives | Win32_UserAccount.Name | LocalAccount=TRUE AND Disabled=FALSE | Count | Number |
| Partages hors administratifs | Win32_Share.Name | Type=0 | Count | Number |

## Catalogue : Reseau (6)

| Nom | Classe et propriété | Filtre | Mode | Transformation |
|---|---|---|---|---|
| Carte reseau connectee | Win32_NetworkAdapter.Name | NetConnectionStatus=2 | All | Text |
| Vitesse du lien (Mbit/s) | Win32_NetworkAdapter.Speed | NetConnectionStatus=2 | First | Mbps |
| Adresse DHCP | Win32_NetworkAdapterConfiguration.DHCPEnabled | IPEnabled=TRUE | First | Map:True=DHCP;False=Fixe |
| Premier serveur DNS | Win32_NetworkAdapterConfiguration.DNSServerSearchOrder | IPEnabled=TRUE | First | Text |
| Passerelle | Win32_NetworkAdapterConfiguration.DefaultIPGateway | IPEnabled=TRUE | First | Text |
| Wi-Fi connecte | Win32_NetworkAdapter.Name | NetConnectionStatus=2 AND Name LIKE '%Wi%Fi%' | Count | Map:0=Non;1=Oui;2=Oui |

## Catalogue : Logiciels et services (9)

| Nom | Classe et propriété | Filtre | Mode | Transformation |
|---|---|---|---|---|
| Nombre d imprimantes | Win32_Printer.Name | — | Count | Number |
| Imprimante par defaut | Win32_Printer.Name | Default=TRUE | First | Text |
| Programmes au demarrage | Win32_StartupCommand.Name | — | Count | Number |
| Services automatiques arretes | Win32_Service.Name | StartMode='Auto' AND State='Stopped' | Count | Number |
| Services en cours d execution | Win32_Service.Name | State='Running' | Count | Number |
| Service Spouleur d impression | Win32_Service.State | Name='Spooler' | First | Text |
| Service Windows Update | Win32_Service.State | Name='wuauserv' | First | Text |
| Nombre de correctifs installes | Win32_QuickFixEngineering.HotFixID | — | Count | Number |
| Processus en cours | Win32_Process.Name | — | Count | Number |

## Catalogue : Utilisateurs (3) et Evenements (2)

| Nom | Classe et propriété | Filtre | Mode | Transformation |
|---|---|---|---|---|
| Utilisateur de la console | Win32_ComputerSystem.UserName | — | First | Text |
| Profils utilisateurs sur le poste | Win32_UserProfile.LocalPath | Special=FALSE | Count | Number |
| Sessions ouvertes | Win32_LogonSession.LogonId | LogonType=2 OR LogonType=10 | Count | Number |
| Erreurs systeme (24 h) | Win32_NTLogEvent.EventCode | Logfile='System' AND EventType=1 AND TimeGenerated>='{SINCE_24H}' | Count | Number |
| Arrets inattendus (7 j) | Win32_NTLogEvent.EventCode | Logfile='System' AND EventCode=6008 AND TimeGenerated>='{SINCE_7D}' | Count | Number |

> [!ASTUCE] Essayez une nouvelle requête sur un poste, puis sur une petite OU, avant une grande OU.

# 11 Tableau des logiciels

L'onglet « Logiciels » de la page « Poste » lit la liste des logiciels installés sur le poste, à la demande. Le volet « Synthese en graphiques » résume la liste chargée en 8 widgets. Ce tableau ne lève aucun point d'attention et n'accepte pas de requêtes WMI.

![Onglet Logiciels : options de lecture, volet Synthese en graphiques avec éditeurs, architecture, portée d'installation et plus gros logiciels, puis la liste](fig:logiciels)

## Lecture

- « Charger les logiciels » lance le worker SoftwareInventory sur le poste sélectionné, avec le compte des opérations poste. Délai maximal : 130 s, 200 s avec les applications Store.
- Options : « Par utilisateur » (logiciels installés dans le profil de chaque utilisateur), « Applications Store » (plus long) et « Mises a jour ». Leurs états se mémorisent dans les préférences SoftwarePerUser (vrai), SoftwareStore (faux) et SoftwareUpdates (faux).
- Le filtre « Portee » propose « Toutes », « Machine », « Utilisateur » et « Store » (préférence SoftwareScope).
- « Copier » et « Exporter CSV » servent au ticket. Le clic droit copie un nom ou une commande de désinstallation ; Domenia ne désinstalle rien.

## Synthèse

- La synthèse est calculée sur la liste chargée : nombre de logiciels et d'éditeurs, somme des tailles connues, logiciels en plusieurs versions, logiciels sans éditeur.
- Trois tuiles répondent à « qu'est-ce qui a changé sur ce poste » : « Installés ces 30 derniers jours » (la date que la liste affiche déjà), « Composants dʼexécution » (Visual C++, .NET, WebView2) et « Navigateurs et versions ». Une tuile à zéro n'est plus un chiffre perdu : elle prend la coche verte quand vérifier était le but, et reste grise quand le poste ne déclare pas la donnée.
- L'anneau « Editeurs » montre les six premiers éditeurs, puis « Autres ». « Architecture » et « Portee d installation » répartissent la liste. « Plus gros logiciels » montre les huit plus gros, en Mo.
- Quand la liste est vide : « Aucun logiciel lu. ».


# 12 Relations utilisateur et poste

Les associations entre utilisateurs et postes sont conservées dans la base autonome locale, pas dans AD. Les liens manuels restent distincts des observations automatiques. Une association mémorisée n'est pas la preuve d'une session ouverte ; la détection réseau reste volontaire.

La page « Utilisateurs et postes » a deux zones dans l'onglet « Associations » : à gauche, les associations de l'utilisateur ou du poste choisi dans « Rechercher » ; à droite, le panneau « Ajouter une association » avec « Détecter » et « Rechercher ». L'en-tête garde un seul statut ; le bouton « ? » affiche ou masque les précautions de la page et l'état de la détection du parc.

## Sources d'une association

| Source | Comment elle arrive |
|---|---|
| Lien manuel | Panneau « Ajouter une association », « Rechercher », « Associer ce poste », puis « Associer » dans « Confirmer l'association ». |
| Console observée | « Détecter la liste » et « Analyser la liste » lisent l'utilisateur console ; l'association est actualisée si elle change. |
| Détection ciblée | Panneau « Ajouter une association », « Détecter » : « Détecter les postes » propose des postes ; « Associer ce poste » prépare le lien, puis « Associer » dans « Confirmer l'association » l'enregistre. |
| Import CSV | « Toutes les associations », « Importer » : aperçu dans la page, puis « Importer ». La source est toujours « Import CSV » (Importé). |

## Détection ciblée

Le panneau « Ajouter une association » part d'un utilisateur ou d'un poste choisi dans « Rechercher ». Les « Options de détection » règlent la lecture :

- Le volet rappelle : « Détecter vérifie réellement les consoles du périmètre choisi. Lecture CIM/DCOM bornée, sans script distant. »
- « Périmètre » : « Postes connus et candidats AD », « Machines de la liste chargée » ou « OU sélectionnée dans Rechercher ».
- « Maximum de postes (1 à 50) » : 20 par défaut.
- « Lire aussi les indices Kerberos du contrôleur (7 jours) ».

Rien ne part avant la confirmation « Périmètre à confirmer avant toute lecture des postes », bouton « Lancer la détection ». Depuis la version 1.0 RC1.14, cet aperçu du périmètre est toujours montré : les anciennes clés Features.RelationsSymmetry et Features.DetectionPreview n'existent plus.

## Journal du contrôleur

« Lire le journal du controleur » (Outils, « Base autonome ») interroge une seule fois le journal Sécurité du contrôleur de domaine (événements 4768, 4769 et 4624) et en tire des couples utilisateur et poste pour le relevé du parc, sans contacter aucun poste. Une confirmation d'impact précède la lecture.

- Période : ParkSweep.HarvestDays (7 jours, borné de 1 à 30).
- Volume : ParkSweep.HarvestMaxEvents (5 000 événements, borné de 200 à 20 000).
- Le compte AD doit pouvoir lire le journal Sécurité du contrôleur ; sinon : « Lecture du journal de securite du controleur refusee. ».
- « Oublier les releves » efface l'état du parc : le prochain relevé repart de zéro.

> [!NOTE] La case « Releve manuel uniquement » existe dans le code mais reste masquée. Aucun relevé n'est lancé au démarrage : si l'ancienne préférence ParkSweepEnabled est vraie, Domenia l'écrit seulement dans le journal.

## Gestion des associations

- Onglet « Associations » : « Supprimer l'association », « Restaurer … », « Exporter ». Colonnes « Utilisateur », « Machine », « Qualification », « Date », « Source », « Conservation » et « Détails ».
- Onglet « Toutes les associations » : « Importer », « Annuler l'import » (après un import), « Restaurer … », « Nettoyer », « Exporter tout ». Un champ filtre l'utilisateur, le poste, la source ou les détails ; les puces « Déclaré », « Observé » et « Contradictoire » filtrent la qualification ; un compteur donne le nombre affiché. Double-clic : fiche de l'utilisateur ou du poste cliqué ; clic droit : « Ouvrir l'utilisateur » ou « Ouvrir le poste ».
- « Qualification » est une puce : Déclaré (bleu), Observé (vert), Importé ou Indice (gris), Contradictoire (orange). L'infobulle donne la règle et la provenance. « Date » est affichée en heure locale (« 08/10 09:15 », avec l'année si elle diffère) et le tri suit l'instant réel.
- Les associations sont locales : la case « Lecture seule » ne les bloque pas. Elles sont perdues avec la base si aucune sauvegarde n'existe (chapitre 18).

**Suppression et restauration**

Une suppression est confirmée dans la page, journalisée et restaurable. Le bouton « Restaurer » nomme l'association qu'il remet (par exemple « Restaurer jdupont → PC01 ») et reste grisé quand rien n'est à restaurer. Il remet une association par clic, la plus récente d'abord ; il est présent dans « Associations » et dans « Toutes les associations ».

**Import CSV**

« Importer » lit le fichier et l'affiche dans un aperçu, sans rien enregistrer. Chaque enregistrement est numéroté (« N° » : les lignes vides du fichier ne comptent pas) et reçoit un résultat : « À importer », « Ignorée » (compte ou poste manquant, poste en double, association déjà connue, poste déjà associé à un autre compte) ou « Inconnue » (compte ou poste absent de l'index local). Les comptes et les postes sont vérifiés dans l'index local de l'annuaire, sans accès réseau ; tant que la vérification n'est pas finie, « Importer » reste grisé. Si l'index est vide ou illisible, l'aperçu le dit et la présence dans Active Directory n'est pas vérifiée.

- La source est toujours « Import CSV » (Importé), quelle que soit la colonne Source du fichier ; aucun score n'est repris ; une date ISO du fichier est gardée, sinon la date de l'import.
- Un import ajoute 64 associations au plus. Les suivantes sont marquées « Ignorée » : importez à nouveau le même fichier, les lignes déjà importées sont reconnues.
- « Annuler l'import » retire les associations du dernier import après une confirmation dans la page qui en donne le nombre. Chaque retrait est journalisé et restaurable.

**Associations orphelines**

« Nettoyer » vérifie en lecture seule que les comptes et les postes des associations automatiques existent encore dans Active Directory. Les orphelines sont listées dans la page avec leur motif (« Compte absent d'Active Directory (supprimé ou renommé). », etc.) et une case à cocher. Les associations déclarées et importées ne sont jamais proposées. « Retirer la sélection » demande une confirmation dans le panneau ; chaque retrait est journalisé et restaurable. Un retrait porte sur 64 associations au plus : les 64 premières sont cochées, puis les suivantes après le retrait.

**Dates enregistrées**

Depuis la version 1.0 RC1.14, chaque date d'association est enregistrée en UTC (« 2026-10-08T07:15:00.0000000Z ») et affichée en heure locale. Une ancienne date « 2026-10-08 09:15:00 » est lue comme une heure locale ; elle prend la forme UTC quand l'association est actualisée par une nouvelle observation ou restaurée. Les autres lignes gardent leur texte : le stockage ne réécrit pas toutes les lignes d'un coup (64 modifications au plus par enregistrement).

| Vous voyez | Sens |
|---|---|
| « Association introuvable : déjà retirée ou rechargée. Aucune modification. » | La ligne a changé entre-temps ; rien n'a été modifié. |
| « Suppression annulée : aucune association modifiée. » | La suppression n'a pas été confirmée. |
| « Aucune suppression locale à restaurer. » | Rien à restaurer. |
| « … l'enregistrement précédent des associations est encore en cours ; réessayez dans quelques secondes. » | Une écriture locale est en cours ; rien n'a été modifié. Recommencez dans un instant. |
| « … 64 au plus par enregistrement. » | Trop de lignes à la fois ; décochez-en ou importez en deux fois. |
| « Session ou domaine modifié : aperçu d'import, « Annuler l'import » et liste des orphelines fermés. » | Changement de compte ou de domaine : rien n'a été enregistré ni retiré. |

# 13 Comptes et droits

Domenia peut utiliser trois identités indépendantes : l'annuaire, les postes et les secrets. Les mots de passe restent en mémoire et sont effacés à la fermeture. Choisir une identité ne donne aucun droit : Windows et AD décident.

## Connexion

![Fenêtre de connexion : Compte Windows, Mot de passe, Mémoriser uniquement l'identifiant, Se connecter et Utiliser mon compte Windows](fig:connexion)

- Le champ « Compte Windows » accepte DOMAINE\identifiant, identifiant@domaine ou le format habituel. Un identifiant nu est complété par Conf.NETBIOS ou Conf.DOMAINE s'ils sont renseignés.
- Un compte ordinateur est refusé comme identité interactive.
- « Mémoriser uniquement l’identifiant » garde l'identifiant dans HKCU:\Software\DOMENIA (valeurs RememberLogin et LastLogin). Le mot de passe n'est jamais mémorisé.
- « Utiliser mon compte Windows » s'appuie sur la session Windows courante, sans mot de passe. Il n'apparaît que si Auth.AllowWindowsSession est vrai (défaut), et reste grisé hors d'une session de domaine.
- Découverte : avec Conf.AutoDiscover vrai (défaut), domaine et contrôleur sont découverts ; avec faux, Conf.DOMAINE, Conf.NETBIOS, Conf.SearchBase et Conf.Server s'appliquent.
- Délais : Auth.LoginTimeoutSeconds (30 s, borné de 8 à 45), Auth.PerServerTimeoutSeconds (6 s par contrôleur), Auth.MaxServerCandidates (4 contrôleurs essayés).

| Vous voyez | Ce que cela veut dire | Que faire |
|---|---|---|
| « Identifiant ou mot de passe incorrect. » | Refus d'authentification. | Vérifier les identifiants avant tout nouvel essai. |
| « Ce compte est verrouille. » ou « Ce compte est desactive. » | Restriction AD. | Lever la restriction ; ne pas multiplier les tentatives. |
| « Le mot de passe de ce compte a expire. » | Mot de passe expiré. | Le changer par Ctrl+Alt+Suppr, puis réessayer. |
| « Acces refuse par AD. Consulte le diagnostic. » | Droits ou restrictions du compte. | Lire le journal de connexion. |
| « Delai depasse. La validation a ete arretee sans bloquer l interface. » | Contrôleur injoignable ou lent. | Vérifier réseau, DNS ou VPN. |
| « Erreur interne pendant la connexion. Consulte le diagnostic. » | Défaut de Domenia, pas un mauvais mot de passe. | « Copier le diagnostic » et le journal de connexion. |

Les boutons « Ouvrir le journal » et « Copier le diagnostic » de la fenêtre donnent la trace de connexion (chapitre 20).

## Les trois identités

La page « Comptes » applique la règle affichée sous « Regle d execution » : « Annuaire : compte AD courant. Postes : compte distant s il existe, sinon compte AD. Secrets : compte secrets s il existe, sinon compte AD. Les trois scopes sont independants. ».

| Zone | Usage | Boutons |
|---|---|---|
| « ANNUAIRE AD » | Utilisateurs, groupes, OU, attributs, recherche et écritures AD. | « Changer de compte », « Tester la connexion », « Se connecter ». |
| « POSTES / WMI / DISTANT » | WMI, WinRM, SMB, inventaire, diagnostics et actions distantes. | « Tester », « Activer », « Effacer ». |
| « SECRETS AD » | Lecture LAPS et BitLocker. | « Tester », « Activer », « Effacer ». |

- Le compte des opérations poste saisi dans l'onglet « Diagnostic » d'un poste passe avant le compte « POSTES / WMI / DISTANT » (chapitre 5).
- Un compte temporaire accepté après un refus ne sert qu'à sa ressource et à son poste. Il est oublié après Security.AlternateCredentialIdleMinutes (30 min) sans usage, à la fin de la session ou sur demande.
- Si le périmètre AD change, les comptes secondaires sont retirés de la mémoire, pour ne pas les envoyer dans un autre domaine.

## Droits à prévoir

| Ressource | Droit nécessaire |
|---|---|
| Annuaire, lecture | Un compte AD capable de lire les utilisateurs, groupes, postes et OU. |
| Annuaire, écriture | Les délégations AD correspondant à chaque écriture permise : déverrouillage, réinitialisation, déplacement, groupes. |
| Postes | « Identifiant ayant les droits administrateur sur les postes. » pour WMI et CIM, C$ et les consoles. |
| Secrets | « Identifiant autorise a lire LAPS et BitLocker dans Active Directory. » |
| Journal du contrôleur | Lecture du journal Sécurité du contrôleur de domaine. |

> [!NOTE] Non vérifié. Les droits AD exacts de chaque écriture et l'absence de besoin d'administrateur local pour lancer Domenia en mode UserLocal n'ont pas été qualifiés. Validez-les dans votre domaine de test.

## Profils Essentiel et Expert

Le choix « Essentiel | Expert » du pied du menu propose « Essentiel » (livré, valeur Tech) et « Expert » (valeur Admin). Ce choix ne donne aucun droit supplémentaire. Le profil Essentiel masque « Attributs », « Droits effectifs », « WMI », « Verification », « Journal » et « Commandes ». Aucun raccourci, menu ou palette ne change le profil : en Essentiel, Ctrl+L déplie le journal de session, et une vue Expert demandée par un menu (« Explorateur WMI ») ou par la palette s'affiche seule, pour cette consultation. Remettez le profil Essentiel aux techniciens. Pour masquer le profil Expert, réglez UI.AllowExpertProfile à false dans wad\Domenia.config.json : l'entrée « Expert » disparaît et ces vues sont refusées avec leur raison.

# 14 Lecture seule, démonstration et protection des écritures

Domenia démarre toujours en lecture seule, y compris après un changement de compte. Passer en écriture demande une confirmation dans la page, reste signalé en rouge et revient seul en lecture seule après 15 minutes sans écriture. Même en écriture, des garde-fous de configuration protègent l'annuaire et chaque action sensible demande une confirmation.

## Lecture seule

L'interrupteur « Lecture seule » de l'en-tête de page est actif au démarrage et à chaque changement de compte. Il n'est jamais mémorisé dans les préférences. Actif, il bloque :

- toutes les écritures AD des fiches : enregistrements, attributs, déverrouillage, activation, désactivation, options de compte, expiration, mots de passe, groupes, déplacement, renommage, suppression, création d'OU ;
- les actions distantes qui modifient un poste : « Actualiser les stratégies » et « Redemarrer » sont grisés, « Exécuter un programme » s'arrête au clic.

Restent disponibles : lectures, recherches, inventaires, détection, requêtes des widgets, lecture des secrets et associations locales.

## Passer en écriture

1. **Cliquer.** Cliquez sur l'interrupteur « Lecture seule ». Un panneau « Autoriser les modifications ? » s'ouvre sous l'en-tête, dans la page : aucune fenêtre.
2. **Confirmer.** « Autoriser les modifications » active l'écriture ; « Rester en lecture seule » (ou Échap) la garde : « Lecture seule conservée. ».
3. **Constater.** L'interrupteur passe au rouge « Écriture active · 15 min », un cadre rouge plein entoure la fenêtre, « Repasser en lecture » apparaît dans l'en-tête et le titre de la fenêtre se termine par « [ÉCRITURE AD ACTIVE] ».
4. **Revenir.** Cliquez sur « Repasser en lecture » (ou sur l'interrupteur) dès la fin de l'intervention : « Lecture seule active : écritures AD, GPUpdate et redémarrage distant bloqués. ». Sinon, la lecture seule revient seule après 15 minutes sans écriture ; une écriture en cours n'est jamais interrompue et repousse ce retour à sa fin.

> [!ATTENTION] Décocher ne donne aucun droit supplémentaire. Les confirmations de chaque action restent nécessaires.

## Garde-fous des écritures

| Clé | Défaut | Effet |
|---|---|---|
| Security.RequireFreshObject et MaxObjectAgeMinutes | vrai, 15 | L'objet doit avoir été relu depuis moins de 15 minutes avant une écriture. |
| Security.BlockProtectedObjects | vrai | Les objets protégés sont bloqués. |
| Security.ReadOnlyReturnMinutes | 15 | Retour automatique en lecture seule après ce nombre de minutes sans écriture (5 à 120). |
| Security.AllowProtectedObjectWrites | faux | Aucune écriture sur un objet protégé. |
| Security.AllowContainerDelete | faux | Aucune suppression de conteneur. |
| Security.AllowRawAttributeWrite | faux | Aucune écriture d'attribut brut. |
| Security.BlockSensitiveRawAttributes | vrai | Attributs sensibles bloqués. |
| Security.SingleWriteChannel | vrai | Une seule écriture à la fois. |
| Security.RequireTypedHighRiskConfirmation | vrai | Saisie du mot RISQUE pour les options à haut risque. |

## Reçus et non-rejeu

Chaque écriture laisse un reçu dans %LOCALAPPDATA%\Domenia\Receipts. Une écriture n'est jamais rejouée automatiquement. Après un résultat incertain, Domenia affiche : « Une operation precedente reste a verifier. Consultez les recus, pas une relance automatique. ». Relisez l'objet dans AD avant toute nouvelle action. Les reçus se consultent dans l'onglet « Fiabilité » (chapitre 18).

## Démonstration pour la formation

La démonstration montre l'interface sans aucune connexion AD, avec des données fictives. Elle sert à la formation, jamais au service.

- Elle s'active seulement si Auth.DemoProvider vaut le booléen JSON true dans wad\Domenia.config.json. Le choix est fait une fois par session.
- Le bandeau affiche « DÉMONSTRATION — aucune connexion AD » ; l'identité est Demo.Identity (DEMO\demo.operateur par défaut) dans un domaine fictif.
- La connexion se fait par « Entrer en démonstration », sans mot de passe. La lecture seule est verrouillée ; les relevés distants, la mesure et la purge du stockage sont désactivés.
- Demo.LatencyMs (0) ajoute un délai simulé aux réponses.

## Fenêtre de connexion Debug

Le mode Debug affiche une trace technique de la connexion en direct (titre « Domenia 1.0  Connexion », bandeau « MODE DEBUG  diagnostic de connexion en direct »). Domenia choisit le mode dans cet ordre :

1. **Marqueur.** Un fichier wad\Domenia.login.debug présent impose Debug.
2. **Fichier de mode.** wad\Domenia.login-mode.cfg contient Standard ou Debug.
3. **Configuration.** Auth.LoginWindowMode de Domenia.config.json (Standard par défaut).

> [!ATTENTION] Avant la mise en service : Auth.DemoProvider absent ou faux, Domenia.login-mode.cfg à Standard, aucun fichier Domenia.login.debug. La construction des paquets refuse déjà une configuration qui active la démonstration, mais un fichier conservé sur un poste peut l'avoir réactivée.

# 15 Architecture

Domenia est une application Windows PowerShell 5.1 et WPF, lancée par un exécutable natif. Chaque démarrage vérifie l'empreinte de tous les composants, charge une liste fermée de modules et n'admet en arrière-plan que 68 opérations dont le code est épinglé. Un composant modifié, ajouté ou manquant arrête le démarrage.

| Couche | Rôle |
|---|---|
| Domenia.exe | Lanceur natif : contrôle le verrou de cycle de vie et le marqueur de mise à jour, puis démarre Windows PowerShell 5.1 x64 en STA. |
| wad\Domenia-Start.ps1 | Contrôle du manifeste : empreinte SHA-256 de chaque fichier runtime, composants obligatoires, dossiers redirigés. |
| wad\Domenia-Modules.ps1 | Chargeur fermé : liste exacte des modules et de leurs fonctions. |
| wad\Domenia-Core.ps1 | Cœur : configuration, base locale, fenêtre de connexion, fenêtre principale (XAML) et moteur des tâches. |
| wad\modules | Règles pures (Model), interface (UI), code d'arrière-plan (Worker), types C#, vues XAML. |
| Workers | Opérations exécutées hors du fil de l'interface, chacune épinglée par SHA-256. |

## Lanceur Domenia.exe

Le lanceur n'accepte que trois formes : sans argument (lancement normal, console cachée), --check (contrôle sans démarrage) et --diagnostic (console visible). Il lance powershell.exe du système avec -NoLogo -NoProfile -STA, sans -ExecutionPolicy : la stratégie d'exécution de la machine s'applique. Ses refus s'affichent dans la fenêtre « DOMENIA | Demarrage ».

| Code | Message | Cause |
|---|---|---|
| 2 | « Chemin du lanceur introuvable ou trop long. », « Dossier du lanceur introuvable. », « Chemin trop long. » ou « Chemin de verrou trop long. » | Dossier d'installation introuvable ou chemin trop long. |
| 3 | « wad\Domenia-Start.ps1 est absent. Extraire tout le dossier prod ou dev. » | Paquet incomplet. |
| 4 | « Windows PowerShell introuvable. » ou « Windows PowerShell 5.1 x64 est requis. » | PowerShell absent. |
| 5 | « Arguments acceptes : --check ou --diagnostic. Le lancement normal ne prend aucun argument. » | Argument inconnu. |
| 6 | « Commande trop longue. » | Chemin d'installation trop long. |
| 7 | « Paquet absent, mise a jour en cours ou dossier inaccessible. Ne pas supprimer les verrous. Utiliser l installateur DEV. » | Verrou wad\Support\.lifecycle.lock inaccessible. Le lanceur est conservé à l'octet (F8) : l'installateur visé est wad\Support\INSTALLER-MISE-A-JOUR.ps1, livré dans PROD et DEV. |
| 8 | « Une installation interrompue doit etre restauree ou terminee avant de lancer Domenia. » | Marqueur wad\Support\.update.pending présent. |
| Code d'erreur Windows | « Windows a refuse le lancement. Conserver les politiques de securite et faire verifier le paquet. » | Windows a refusé de démarrer powershell.exe ; le code de sortie est l'erreur Windows. N'assouplissez pas les stratégies : faites vérifier le paquet. |

Après un arrêt sur erreur en lancement normal, une fenêtre « DOMENIA » affiche : « DOMENIA s'est arrete sur une erreur. Lancer Domenia.exe --diagnostic pour la voir. Les journaux restent sous wad\data\Logs ou le dossier utilisateur. ».

## Contrôle au démarrage

Domenia-Start.ps1 exige Windows PowerShell 5.1 Desktop, 64 bits, en STA. Il lit wad\package-manifest.json (83 fichiers runtime avec l'installateur, plafond RuntimeFileLimit du contrat de release, 250) et recalcule l'empreinte SHA-256 de chaque fichier à chaque démarrage. Les fichiers conservés (configuration et préférences du dossier wad) ne sont pas comparés.

| Message | Cause |
|---|---|
| « Windows PowerShell 5.1 x64 STA requis. Lancez Domenia.exe. » | Mauvais moteur PowerShell. |
| « Dossier du logiciel redirige. Utilisez une copie locale validee. » | Jonction ou lien sur le dossier ou un parent. |
| « Mise à jour incomplète. Restaurez le code avant le lancement, dans Windows PowerShell : » suivi de la commande complète | Marqueur de mise à jour présent. La commande donnée lance le RESTAURER-CODE.ps1 de la sauvegarde concernée avec -RestoreBackup, ou wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination avec le dossier d'installation. |
| « Composant modifie ou versions melangees : » suivi du chemin | Fichier différent du manifeste. |
| « Composant manquant : » suivi du chemin | Fichier absent. |
| « Manifeste incomplet : » suivi du chemin | Composant obligatoire absent du manifeste. |

Avec --check, Domenia analyse aussi chaque script avec le vrai parseur, importe les modules dans une portée jetable, puis affiche le nombre de fichiers vérifiés et de modules chargés, avec « Aucun acces AD. ». Une erreur est écrite dans %TEMP%\Domenia-startup-error.log.

## Chargeur fermé et modules

Domenia-Modules.ps1 déclare 58 modules et la liste exacte de leurs fonctions. Un script ajouté dans wad\modules n'est jamais chargé. Au démarrage, le chargeur vérifie l'existence et la syntaxe de chaque fichier, compile les types C#, contrôle le plan (phases, dépendances, cycles, doublons), importe les modules dans l'ordre, puis vérifie que chaque fonction existe et vient du bon fichier.

| Code d'erreur | Sens |
|---|---|
| DOMENIA_MODULE_MISSING | Fichier de module absent ; réinstaller le paquet complet. |
| DOMENIA_MODULE_PARSE | Erreur de syntaxe dans un module. |
| DOMENIA_MODULE_TYPES | Échec de compilation des types C#. |
| DOMENIA_MODULE_IMPORT | Échec d'import d'un module. |
| DOMENIA_MODULE_PLAN | Plan de chargement incohérent. |
| DOMENIA_MODULE_EXPORT | Fonction déclarée introuvable. |
| DOMENIA_MODULE_ORIGIN | Fonction venue d'un autre fichier que prévu. |

Organisation : un domaine fonctionnel donne un fichier Model (règles pures, sans WPF, réseau ni disque), un fichier UI et un fichier Worker. Les parcours métier restent dans la fenêtre principale : composants dans la page, jamais de nouvelle fenêtre.

## Workers épinglés et registre des 68 opérations

Tout travail d'arrière-plan passe par un seul point d'entrée, Start-UiTask. Il n'admet que les opérations du registre fermé, chacune avec l'empreinte SHA-256 de son code exact.

1. **Au démarrage.** Chaque fichier runtime est comparé au manifeste.
2. **À l'initialisation du moteur.** L'empreinte de la table entière est recalculée. Un écart donne « Registre worker non conforme » et demande de réinstaller un paquet cohérent.
3. **Avant chaque tâche.** Le code de l'opération est recontrôlé : « Operation worker non autorisee : » ou « Integrite worker refusee pour » suivi de l'opération.

Les 68 opérations : BatchNetworkDiag, CmdletHelp, CmdletInventory, ComputerAdminShare, ComputerDiagnostics, ComputerGpUpdate, ComputerInventory, ComputerLastUser, ComputerPing, ComputerRestart, DemoDirectory, DocumentStore, DomainOverview, EmbeddedDirectoryLookup, EmbeddedPathBrowse, EngineSelfTest, GlobalSearch, IndexBuild, IsolatedRead, LegacyMigration, LiveCache, LiveConsole, LiveDirectoryCheck, LiveSelectedPing, LocalIndexRead, LocalStore, LogonHarvest, OpenAdObject, OpenLinkedObject, ParkSharedSync, ParkSweep, PermissionAnalysis, PresenceScan, PruneLinks, ReadBitLocker, ReadBitLockerKey, ReadBitLockerList, ReadLaps, ReceiptStore, RemoteCredentialCheck, RimotteRun, ScopeReconcile, SelectedPresence, SelfCheck, SessionsList, SoftwareInventory, StartupWarmCache, StorageBackup, StoragePurge, StorageUsage, TreeChildren, UserComputerProbe, WmiClasses, WmiNamespaces, WmiQuery, WriteAccountDisabled, WriteAccountOptions, WriteAttributes, WriteCreateOu, WriteDeleteObject, WriteExpiration, WriteExpirePassword, WriteGroupMember, WriteMoveObject, WriteObjectGroup, WriteRenameComputer, WriteResetPassword, WriteUnlock.

Limites du moteur : Async.MaxThreads (6 threads), Async.MaxOutstandingWorkers (12 tâches en cours), file d'attente Async.MaxQueued (32, dont 2 places réservées aux actions de premier plan), attente maximale de 120 s. Les écritures passent par un canal dédié. Si Async.Enabled est faux, aucune tâche ne part : « Moteur multithread desactive dans la configuration. ».

> [!ATTENTION] Une modification d'un worker se fait seulement en développement : relecture, puis python tools/update_worker_contracts.py --apply, puis python tools/build_packages.py pour régénérer les manifestes. L'application n'appelle jamais cet outil ; il ne sert pas à faire accepter un paquet téléchargé douteux.

# 16 Installation et mise à jour

Domenia s'installe dans un dossier local, par extraction du ZIP ou par l'installateur. L'installateur est livré dans les deux paquets (wad\Support\INSTALLER-MISE-A-JOUR.ps1) : il contrôle tout avant de copier, garde l'ancien code et sait le restaurer. Il ne lance aucune suite de tests sur le poste. Les données et les préférences ne sont jamais touchées.

## Prérequis

- Windows PowerShell 5.1 Desktop, processus 64 bits, thread STA, et WPF.
- winsqlite3.dll fourni par Windows, pour la base locale.
- Module Active Directory des outils RSAT, ou les deux DLL Microsoft livrées dans wad ; à défaut, Domenia lit l'annuaire en LDAP.
- Un dossier local, sans jonction ni lien symbolique sur lui ou ses parents.
- Les ports du chapitre 5 ouverts entre le poste d'administration, les contrôleurs et les postes.

> [!NOTE] Non vérifié. Les versions de Windows prises en charge ne sont pas écrites dans le code ; les campagnes de test ont tourné sous Windows 11. L'effet de la stratégie d'exécution PowerShell sur le lanceur et sur l'installateur n'a pas été qualifié.

## Paquets PROD et DEV

| Paquet | Contenu |
|---|---|
| Domenia_1.0_RC1.13.0_PROD.zip | Domenia.exe et le dossier wad, installateur compris (wad\Support) : 83 fichiers runtime. À installer sur les postes. |
| Domenia_1.0_RC1.13.0_DEV.zip | Le même runtime à l'octet, plus les sources, les outils, les tests et le suivi. Les outils du labo (engineering\d120\lab) et l'historique (wad\docs\history) restent dans le dépôt. Pour l'administrateur et la qualification. |

Fichiers conservés par l'installateur, jamais remplacés : wad\Domenia.config.json, wad\Domenia.login-mode.cfg, wad\Domenia.theme.cfg et wad\Domenia.ui-profile.cfg. Configuration livrée : connexion Standard, vérification au clic active, thème clair, profil Essentiel.

## Première installation

Avec l'installateur, depuis le dossier où le ZIP PROD a été extrait (il contient Domenia.exe et wad) :

~~~
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Install -Destination 'C:\Domenia'
~~~

La destination doit être vide ou absente. L'installateur vérifie l'empreinte et la syntaxe de chaque fichier, demande « Installer ces N fichiers ? (O/N) », copie, débloque les fichiers copiés et lance le contrôle de démarrage (-CheckOnly). En cas d'échec, les fichiers copiés sont retirés. Il propose ensuite un raccourci sur le Bureau et un dans le menu Démarrer ; aucun n'est créé sans réponse O. -Shortcuts Oui ou Non répond d'avance ; avec -Confirm:$false, aucune question n'est posée et aucun raccourci n'est créé sans -Shortcuts Oui. Un raccourci qui ne peut pas être créé donne un avertissement ; l'installation reste faite.

À la main :

1. **Extraire.** Extrayez le ZIP PROD entier. L'archive contient un dossier prod : copiez tout son contenu dans un dossier local, par exemple C:\Domenia, qui contient alors Domenia.exe et wad. C'est le dossier d'installation. Ne déplacez jamais le cœur sans les modules et leur manifeste.
2. **Débloquer si besoin.** Si Windows bloque les fichiers téléchargés, lancez wad\Support\DEBLOQUER_TOUT.cmd. Il vérifie l'empreinte de chaque fichier runtime et ne retire la marque de téléchargement que si tout est conforme.
3. **Contrôler.** Lancez Domenia.exe --check (chapitre 20).
4. **Configurer.** Relisez wad\Domenia.config.json (chapitre 17).
5. **Lancer.** Lancez Domenia.exe et connectez-vous.

> [!RESULTAT] « Runtime debloque. » puis « Aucune politique PowerShell, GPO, AppLocker/WDAC ou protection antivirus modifiee. Le manifeste ne vaut pas signature. ». En cas d'écart : « Aucun deblocage en masse effectue. ».

## Mettre à jour

Fermez Domenia dans le dossier à mettre à jour, extrayez le ZIP PROD (ou DEV) dans un dossier distinct, puis, depuis le dossier extrait (celui qui contient Domenia.exe et wad), dans Windows PowerShell 5.1 :

~~~
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia' -WhatIf
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia'
~~~

Dans le paquet DEV, .\INSTALLER-MISE-A-JOUR.ps1 à la racine transmet les mêmes paramètres et le même code de sortie. Les chemins relatifs partent du dossier courant de PowerShell.

1. **Contrôles de départ.** Source et destination distinctes et non imbriquées ; destination contenant wad\Domenia-Core.ps1 ; aucun Domenia ouvert depuis ce dossier.
2. **Contrôle de la source.** Seuls les fichiers runtime du manifeste PROD sont pris, empreinte et syntaxe vérifiées. Les chemins de données et de sauvegardes sont refusés.
3. **Rapport de qualification.** Avec -Package (le ZIP livré) et -QualificationReport (le rapport release_guard de la campagne Windows), l'installateur vérifie hors ligne : Windows PowerShell 5.1, campagne réussie, même Build, scénarios requis exécutés, horodatés et liés aux archives du rapport, ZIP dont chaque fichier porte l'empreinte de son manifeste et dont le manifeste porte celles du paquet installé. Un rapport fourni et refusé arrête tout avant écriture, avec la raison. Sans rapport : avertissement, installation non qualifiante ; -RequireQualification refuse alors.
4. **Liste et question.** L'installateur affiche les versions active et préparée, « Fichiers à installer : » et la liste. Avec -WhatIf, il s'arrête là. Sinon il demande « Installer ces N fichiers ? (O/N) » ; -Confirm:$false supprime la question.
5. **Copie préparée.** Il prépare une copie complète dans wad\maintenance\backups\DATE-ID\prepared et la démarre avec Domenia-Start.ps1 -CheckOnly (empreintes, syntaxe, chargement des modules, sans AD). Si elle ne démarre pas, le code actif reste inchangé. Aucune suite de tests n'est lancée sur le poste.
6. **Remplacement.** Il prend le verrou wad\Support\.lifecycle.lock, sauvegarde tout l'ancien code, écrit le journal transaction.json et une copie RESTAURER-CODE.ps1 de l'installateur, pose le marqueur wad\Support\.update.pending, remplace les fichiers un à un en les vérifiant, contrôle l'ensemble, puis retire le marqueur.
7. **Nettoyage.** La copie préparée est supprimée. Les cinq dernières sauvegardes complètes sont gardées ; les plus anciennes, et les copies prepared laissées par les anciens installateurs dans les sauvegardes gardées, sont retirées. Une sauvegarde d'installation inachevée n'est jamais touchée.

> [!RESULTAT] « Mise à jour installée. Version avant : … ; version après : … », le dossier de sauvegarde, puis la commande de retour arrière.

Codes de sortie : 0 installation faite (ou -WhatIf), 1 erreur, 2 rien n'a été installé (réponse N ou aucune réponse).

| Vous voyez | Que faire |
|---|---|
| « Destination incorrecte : choisissez le dossier Domenia contenant wad\Domenia-Core.ps1. » | Désigner le dossier d'installation, ou ajouter -Install pour un dossier vide. |
| « Fermez Domenia dans le dossier à mettre à jour ou à restaurer. » | Fermer Domenia sans interrompre une écriture AD, puis relancer. |
| « Cette version est déjà active. Utilisez une livraison portant un nouveau Build. » | La livraison porte le même Build que l'installé (section suivante). |
| « Rapport de qualification fourni refusé : » suivi de la raison | Rien n'a été modifié. Corriger le rapport ou le ZIP, ou relancer sans -QualificationReport. |
| « La version préparée ne peut pas démarrer. Le code actif est inchangé. » | Paquet incohérent ; ne pas forcer. |
| « Installation en échec : ancien code restauré. » | La restauration automatique a fonctionné ; lire la cause. |
| « Installation précédente incomplète. » | Restaurer avec -RestoreLatest (ci-dessous). |

## Revenir au code précédent

~~~
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination 'C:\Domenia'
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Domenia\wad\maintenance\backups\DOSSIER'
~~~

-RestoreLatest choisit la sauvegarde de l'installation interrompue s'il y en a une, sinon la dernière installation terminée de ce dossier.

La restauration relit la transaction, vérifie tout sans écrire, refuse d'écraser un fichier modifié depuis la mise à jour, puis remet l'ancien code. Message de fin : « Code precedent restaure. wad\data et les preferences conservees n ont pas ete modifies. ».

> [!ATTENTION] Ne supprimez jamais wad\Support\.lifecycle.lock ni wad\Support\.update.pending à la main. Le marqueur bloque le lancement tant qu'une installation n'est ni terminée ni restaurée ; c'est voulu.

## Identité de livraison et nouveau Build

L'identité tient dans un seul fichier, dev\tools\release-contract.json : produit, version 1.0, release RC1.13.0, Build 2026.10.08-DOMENIA-1.0-RC1.13.0-D120, schéma de données 11. Le pied du menu affiche « DOMENIA 1.0 · RC1.13.0 ».

L'installateur refuse de mettre à jour un poste qui porte déjà le même Build. Pour chaque nouvelle livraison, changez la release et le Build dans le contrat, puis :

~~~
python tools/release_contract.py --stamp
python tools/release_contract.py --check
python tools/build_packages.py --output C:\Livraisons\Domenia
~~~

La construction refuse un dossier de sortie dans l'arbre du code, et une configuration qui active la démonstration. Domenia.exe est conservé à l'octet : il n'est ni recompilé ni signé.

# 17 Réglages et configuration

La configuration de l'application tient dans wad\Domenia.config.json ; les choix de chaque utilisateur vont dans ses préférences. Toute section connue est complétée clé par clé avec les valeurs par défaut du code. Seules les clés listées ici ont un effet.

## Fichiers

| Fichier | Rôle |
|---|---|
| wad\Domenia.config.json | Configuration de l'application, lue au démarrage ; conservée par l'installateur. |
| DOSSIER_DONNEES\Preferences\Domenia.settings.json | Préférences de l'utilisateur, avec une copie .bak ; écriture atomique différée de 1,5 s. |
| wad\Domenia.login-mode.cfg | Mode de la fenêtre de connexion : Standard ou Debug. |
| wad\Domenia.theme.cfg | Thème Light ou Dark, lu seulement sans choix valide dans les préférences. |
| wad\Domenia.ui-profile.cfg | Profil ancien (Tech ou Admin), lu seulement sans choix valide dans les préférences. |
| HKCU:\Software\DOMENIA | Identifiant mémorisé (RememberLogin, LastLogin). |

> [!ATTENTION] Un Domenia.config.json illisible n'arrête pas Domenia : les valeurs par défaut s'appliquent sans message. Validez le JSON après chaque modification, puis contrôlez le comportement attendu.

Une clé absente, nulle ou vide prend la valeur par défaut du code. Une section inconnue est conservée telle quelle. Browser.DefaultLimit n'a pas d'effet : la limite de départ vient toujours du paramètre du cœur (100). Les clés Features acceptent un booléen ou un texte : true, 1, oui, yes, on, ou false, 0, non, no, off.

## Connexion et démonstration

| Clé | Défaut | Rôle |
|---|---|---|
| Conf.AutoDiscover | true | Découvre le domaine et le contrôleur ; à false, les quatre clés suivantes s'appliquent. |
| Conf.DOMAINE, Conf.NETBIOS | vide | Nom DNS et NetBIOS du domaine ; complètent aussi un identifiant nu. |
| Conf.SearchBase, Conf.Server | vide | Base DN et contrôleur imposés. |
| Conf.ADM | vide | Identifiant proposé si aucun n'est mémorisé. |
| Auth.RememberLogin | true | État initial de « Mémoriser uniquement l’identifiant ». Valeur du fichier remplacée par RememberLogin de HKCU:\Software\DOMENIA dès que celle-ci existe. |
| Auth.LastLogin | vide | Identifiant proposé à l'ouverture. Valeur du fichier remplacée par LastLogin de HKCU:\Software\DOMENIA dès que celle-ci existe. |
| Auth.LoginWindowMode | Standard | Mode de la fenêtre de connexion. |
| Auth.AllowWindowsSession | true | Affiche « Utiliser mon compte Windows ». |
| Auth.LoginTimeoutSeconds | 30 | Délai total de connexion (8 à 45 s). |
| Auth.PerServerTimeoutSeconds | 6 | Délai par contrôleur. |
| Auth.MaxServerCandidates | 4 | Contrôleurs essayés. |
| Auth.DemoProvider | false | Démonstration ; doit rester false en service. |
| Demo.Identity | DEMO\demo.operateur | Identité affichée en démonstration. |
| Demo.LatencyMs | 0 | Délai simulé en démonstration. |

## Fonctions

| Clé | Défaut | Rôle |
|---|---|---|
| Features.Scheduler | true | Ordonnanceur des tâches du moteur. |
| Features.IdlePolicy | true | Politique d'inactivité du moteur. |
| Features.BitLockerKeySelection | true | BitLocker : métadonnées d'abord, puis une seule clé choisie. |
| Features.SecretSingleCopy | true | Un seul secret révélé à la fois, sans copie groupée. |
| Features.SearchSyntax | true | Préfixes de recherche (chapitre 3). |
| Features.SearchRanking | true | Classement des résultats de la recherche globale. |
| Features.InlineConfirm | true | Confirmation dans la page avant de supprimer une association. |
| Features.IsolatedReads | false | Lectures isolées, désactivées. |

## Recherche, liste et interface

| Clé | Défaut | Rôle |
|---|---|---|
| Streaming.VerifyUserOnSelection | true | État initial de « Utilisateur au clic ». |
| Streaming.MaxUserProbes | 2 | Vérifications au clic simultanées (1 à 3). |
| Streaming.RevalidateListedObjects | true | Relecture périodique des objets affichés. |
| Streaming.RevalidateIntervalSeconds | 60 | Intervalle de cette relecture (30 à 600 s). |
| Streaming.ReconcileSeconds | 180 | Relecture de fond du périmètre d'une liste de 500 lignes au plus (120 à 900 s). |
| Browser.GlobalSearchLimit | 100 | Valeur initiale du champ « Limite », aussitôt remplacée par la préférence SearchLimit (100 par défaut) ; ne sert que si ce champ n'est pas un nombre. |
| Browser.GlobalSearchMinChars | 2 | Caractères minimum. |
| Browser.MaxPageSize | 300 | Taille de page LDAP. |
| Browser.LiveGlobalSearch, AllowLiveGlobalSearch | false | Recherche à la frappe. |
| Browser.LiveSearchDelayMs | 900 | Attente avant une recherche à la frappe. |
| Browser.SelectionDebounceMs | 180 | Attente avant le préchargement de la fiche après une sélection (80 à 500 ms). |
| Browser.SearchServerTimeLimitSeconds | 8 | Délai côté contrôleur. |
| Browser.SearchClientTimeoutSeconds | 12 | Délai côté poste. |
| UI.TreeRenderBatchSize, TreeRenderIntervalMs | 16, 20 | Affichage progressif de l'arbre. |
| UI.AllowExpertProfile | true | false masque le profil Expert du pied du menu ; Ctrl+L reste sur le journal de session. |
| Startup.ShowMonitor | true | Fenêtre « Domenia 1.0  Initialisation » pendant le chargement. |
| SelfCheck.FullBenchmarkIterations | 3 | Répétitions de la vérification complète. |

## Moteur et cache

| Clé | Défaut | Rôle |
|---|---|---|
| Async.Enabled | true | Moteur des tâches ; à false, aucune tâche ne part. |
| Async.MaxThreads | 6 | Threads du moteur. |
| Async.MaxOutstandingWorkers | 12 | Tâches en cours au plus. |
| Async.MaxQueued, ReservedForeground, MaxQueueWaitSeconds | 32, 2, 120 | File d'attente, places de premier plan, attente maximale. |
| Async.PollIntervalMs, UiRefreshIntervalMs | 250, 500 | Rythme de suivi des tâches. |
| Async.DefaultTimeoutSeconds | 60 | Délai par défaut d'une tâche. |
| Async.SearchTimeoutSeconds, ObjectTimeoutSeconds, TreeTimeoutSeconds | 45, 35, 30 | Délais des recherches, fiches et arbre. |
| Async.RemoteTimeoutSeconds | 45 | Délai des opérations distantes. |
| Async.ComputerTimeoutSeconds | 90 | Délai du diagnostic réseau groupé. |
| Async.SelfCheckTimeoutSeconds | 120 | Délai de la vérification de l'application. |
| Async.WriteSoftTimeoutSeconds, WriteHardTimeoutSeconds | 90, 300 | Délais d'une écriture. |
| Cache.Enabled, TtlSeconds, ObjectTtlSeconds, MaxEntries | true, 90, 45, 400 | Cache des lectures en mémoire. |
| Cache.WarmRootTree, WarmRootObjects, WarmRootObjectLimit | true, true, 100 | Préchargement de la racine du domaine. |
| Cache.WarmupTimeoutSeconds, WarmupRetries, WarmupRetryDelayMs | 45, 2, 1200 | Délais et reprises de ce préchargement. |

## Sécurité

| Clé | Défaut | Rôle |
|---|---|---|
| Security.EvaluateRightsOnObjectOpen | true | Estime les droits à l'ouverture d'un objet. |
| Security.BlockOnAclEstimate, DisableIndeterminateControls | false, false | Ne bloque pas sur une estimation. |
| Security.AutoClearSecretClipboardSeconds | 30 | Vidage du presse-papiers après un secret. |
| Security.SecretMemorySeconds | 300 | Durée de vie d'un secret en mémoire (30 à 1 800 s). |
| Security.AlternateCredentialIdleMinutes | 30 | Oubli d'un compte temporaire inutilisé. |
| Autres clés Security | voir chapitre 14 | Garde-fous des écritures. |

## Postes distants et associations

| Clé | Défaut | Rôle |
|---|---|---|
| Remote.UseCim, UseWinRM | true, true | Lectures CIM, et repli WSMan si déjà en service. |
| Remote.PortTimeoutMs, CommandTimeoutSeconds | 1200, 10 | Délai d'un test de port et d'une commande. |
| Remote.UsePsExecFallback, UseTaskFallback, TaskFallbackTimeoutSeconds | true, true, 75 | PsExec puis tâche planifiée : pour les interventions avec l'autorisation de 5 minutes, et pour une lecture seulement après « Lire ce poste par tâche planifiée » (chapitre 5). |
| Remote.UseRemoteRegistry, UseProfilesShare, UseSecurityLog | true, true, false | Sources de la détection du dernier utilisateur : registre distant, partage des profils, journal Sécurité du poste. |
| Remote.AllowUnboundedFallbacks | false | Replis sans limite, interdits. |
| Inventory.PreferWinrm | false | Préférence WinRM pour l'inventaire. |
| WAPT.Enabled, WaptGetPath, ServerUrl | false, vide, vide | Intégration WAPT, désactivée. |
| UserMachineLink.MinimumConfidence | 60 | Score minimal d'une association. |
| UserMachineLink.ObjectRefreshHours | 4 | Âge en heures sous lequel une association existante reste fraîche. |
| UserMachineLink.ClassicProbeTimeoutSeconds, TaskFallbackProbeTimeoutSeconds, ProbeMethodTimeoutMs | 8, 30, 3000 | Délais des sondes de détection. |
| ParkSweep.HarvestDays, HarvestMaxEvents | 7, 5000 | Lecture du journal du contrôleur (chapitre 12). |
| ParkSweep.RefreshDays, RetryDays, SharedPath | 14, 2, vide | Relevés du parc. |
| Modules.AutoLoad, PreferActiveDirectoryModule, UseCredential | true, true, true | Chargement du module Active Directory. |

## Base locale et index

| Clé | Défaut | Rôle |
|---|---|---|
| LocalStore.Mode | Compatible | Compatible, UserLocal ou Portable (chapitre 18). |
| LocalStore.DatabaseFile | Domenia.db | Nom du fichier, sans chemin. |
| LocalStore.DatabaseBackupCount | 7 | Sauvegardes gardées (2 à 30). |
| LocalStore.BackupTimeoutSeconds | 30 | Budget d'une sauvegarde (5 à 120 s). |
| LocalStore.DatabaseBusyTimeoutMs, MutexTimeoutMilliseconds | 2500, 350 | Attente d'une base occupée. |
| Index.StartupDeltaMaxAgeMinutes | 5 | Âge au-delà duquel le journal recommande une mise à jour. |
| Index.MaxObjects, BudgetMs, ComputerFirst | 200000, 1200000, true | Taille, budget et ordre de la reconstruction de l'index. `Index.MaxObjects` est accepté jusqu'à 5 000 000 d'objets. Une passe qui l'atteint, ou le budget, s'arrête là, avertit sur l'accueil et ne déplace pas le repère de suivi : la passe suivante relit tout. L'application estime elle-même 1 800 octets par objet lu, et chaque objet relu repasse par l'interface : ne relevez ces clés que pour la taille réelle de votre domaine, OU par OU quand c'est possible. Le bouton « Tout relire (OU par OU) » relit le domaine en une passe par OU : la limite ne porte alors plus que sur une seule OU, les OU déjà lues sont conservées, et le marqueur d'incomplétude s'efface quand aucune OU n'a été coupée. |

## Clés sans effet

Ces clés figurent dans les valeurs par défaut ou dans le fichier livré, mais aucun code ne les lit. Ne les présentez pas comme réglables : Conf.UsersBase, Conf.ComputersBase, Auth.DetailedLoginTrace, Features.ScopedLocks, Features.ColumnProfiles, Features.WakeOnLan, Features.LocalAssistant, Features.ReadTrace, Browser.IncludeContainers, Browser.DefaultObjectFilter, Browser.DefaultScope, Dashboard.Enabled, UI.WindowWidth, UI.ReadOnlyDefault, Async.MinThreads, Security.MaskSecretsByDefault, Security.NeverLogSecretValues, Remote.AllowRemoteArtifacts, UserMachineLink.AutoProbeOnComputerSelect, Index.FullRebuildDays, LocalStore.KeepBackup et Streaming.AutoDetectLoggedUser, entre autres : 61 clés des valeurs par défaut, plus cette dernière clé du fichier livré.

## Préférences de l'utilisateur

Seules ces clés survivent à un redémarrage ; la lecture seule n'en fait volontairement pas partie.

| Domaine | Clés |
|---|---|
| Recherche | SavedSearches, OuBookmarksJson, PresenceFilter, SearchType, SearchLimit (100), GridLayoutsJson |
| Interface | Theme (Light), UiProfile (Tech), Workspace, UxDensity (Confort), UxNavCollapsed, UxHelpVisible, UxHelpCompactOpen, UxLogCollapsed, UxLogExpandedHeight, UxLogWrap, UxLogFontSize |
| Fenêtre | WindowWidth, WindowHeight, WindowLeft, WindowTop, WindowMaximized, TreeWidth, LogHeight |
| Tableaux de bord | Dashboard.Computer.Layout, Dashboard.Fleet.Layout, Dashboard.Software.Layout, Widgets.Computer, Widgets.Fleet. Le périmètre du parc n'a plus de clé : c'est l'OU de « Rechercher ». |
| Comptes | RemoteCredentialUser, SecretsCredentialUser : noms des comptes « POSTES / WMI / DISTANT » et « SECRETS AD », jamais de mot de passe. |
| Poste | InventoryScope, SoftwareScope, SoftwarePerUser, SoftwareStore, SoftwareUpdates, WmiLimit (25) |
| Parc | IndexAutoBuild, ParkSweepEnabled, ParkHarvestEnabled |

# 18 Base autonome

La base autonome est une copie locale des utilisateurs et des postes, suivie par GUID, avec les associations utilisateur et poste et les derniers relevés. Elle alimente la vue du parc et les recherches locales, sans requête AD. Les associations et les relevés n'existent que là : sauvegardez la base.

![Outils, Base autonome : boutons de mise à jour, encadré Emplacement et sauvegarde avec le chemin du fichier, Ouvrir l emplacement, Sauvegarder maintenant et Copier une sauvegarde vers](fig:base-autonome)

## Emplacement

| LocalStore.Mode | Dossier des données | Protection |
|---|---|---|
| UserLocal | %LOCALAPPDATA%\Domenia\Data | Droits limités à l'utilisateur, à SYSTEM et aux administrateurs. |
| Portable | wad\data dans le dossier d'installation | Aucun droit posé ; réservé à un support personnel. |
| Compatible (défaut) | Portable si wad\data contient déjà des données, sinon UserLocal. | Celle du mode retenu, annoncé dans la trace de démarrage. |

- La base d'un domaine est DOSSIER_DONNEES\Domains\CLE\Domenia.db, où CLE est tirée de l'empreinte SHA-256 de la base DN. Chaque domaine a donc sa base. Le journal SQLite est en mode WAL : fichiers -wal et -shm à côté.
- Sous-dossiers du dossier des données : Logs, Backups, Diagnostics, Exports, Legacy, Domains et Preferences.
- La base doit être locale, sans repli silencieux. Chemin réseau : « Une base active SQLite doit etre locale. Choisissez UserLocal ; les sources existantes seront conservees. ». Dossier redirigé : « Stockage redirige par un lien : choisissez un dossier local non redirige. ». Dossier non inscriptible : « Stockage non inscriptible : » suivi du chemin et de « Aucun repli silencieux. Configurez UserLocal. ».
- Une ancienne base à la racine du dossier n'est adoptée que si sa base DN correspond ; elle n'est jamais déplacée ni fusionnée.

Le chemin exact s'affiche dans l'encadré « Emplacement et sauvegarde ». « Ouvrir l emplacement » ouvre l'Explorateur sur le fichier.

## Mettre à jour la base

| Bouton | Effet | Quand |
|---|---|---|
| « Mettre a jour tout » | Relit tous les utilisateurs et postes, reconstruit la base et resynchronise les associations connues. Peut durer plusieurs minutes. | Après l'installation, puis de temps en temps. |
| « Mettre a jour les changements » | Ne relit que les objets modifiés depuis la dernière passe (uSNChanged et whenChanged). Beaucoup plus rapide. | Au quotidien. |

La mise à jour n'est jamais automatique. Si la base est plus ancienne que Index.StartupDeltaMaxAgeMinutes, Domenia écrit seulement une recommandation dans le journal.

## Sauvegarder

1. **Lancer.** Cliquez « Sauvegarder maintenant ». La barre d'état affiche « Sauvegarde de la base en cours... ».
2. **Copie à chaud.** Le worker StorageBackup copie la base par l'API de sauvegarde SQLite. L'original reste ouvert en lecture seule et n'est pas modifié.
3. **Contrôle.** La copie est vérifiée (PRAGMA quick_check) dans le budget LocalStore.BackupTimeoutSeconds (30 s). Une copie partielle est supprimée.
4. **Rotation.** Le fichier va dans le dossier Backups de la base, nommé Domenia-DATE-HEURE-ID.db. Seules les LocalStore.DatabaseBackupCount (7) plus récentes sont gardées.

> [!RESULTAT] « Sauvegarde de la base enregistree : » suivi du chemin. Sous l'encadré : « Sauvegardes : » avec le dossier et la date de la dernière.

« Copier une sauvegarde vers... » fait la même sauvegarde puis la copie vers le fichier choisi (clé USB, partage), nom proposé Domenia-DATE-HEURE.db : « Sauvegarde de la base copiee : » suivi du chemin. Échec : « Sauvegarde de la base impossible : » suivi du motif.

> [!ATTENTION] Il n'existe pas de sauvegarde périodique automatique. Seule une migration de schéma déclenche une sauvegarde d'elle-même, dans Backups\migrations, hors rotation. Planifiez une sauvegarde manuelle régulière et gardez-en une copie hors du poste.

Hors de l'application, le paquet DEV fournit wad\maintenance\Sauvegarder-Cache.ps1 : sauvegarde cohérente d'un fichier .db, de préférence Domenia fermé, 7 copies au plus dans Backups, avec le chemin et l'empreinte SHA-256. Il refuse PowerShell 7 et les processus 32 bits.

~~~
powershell -NoProfile -STA -File wad\maintenance\Sauvegarder-Cache.ps1 -DatabasePath "C:\CHEMIN\Domenia.db"
~~~

## Restaurer une sauvegarde

Aucun outil de restauration n'est livré : la restauration est manuelle. Si la base est illisible, Domenia ne déplace et n'écrase rien ; il affiche « Le cache SQLite est illisible. Aucune base ni sauvegarde n'a ete deplacee ou ecrasee. » et demande de restaurer une sauvegarde vérifiée.

1. **Fermer Domenia.** Fermez toutes les fenêtres Domenia qui utilisent ce dossier de données.
2. **Mettre de côté.** Copiez dans un dossier à part le fichier Domenia.db actuel et ses fichiers -wal et -shm. Ne supprimez rien.
3. **Choisir.** Prenez la sauvegarde la plus récente dans le dossier Backups de la base.
4. **Remplacer.** Retirez du dossier de la base les anciens Domenia.db, -wal et -shm (déjà mis de côté), puis copiez la sauvegarde sous le nom Domenia.db.
5. **Relancer.** Lancez Domenia, ouvrez Outils, « Base autonome », et vérifiez le chemin et le contenu.
6. **Rattraper.** Cliquez « Mettre a jour les changements » pour relire ce qui a changé dans AD depuis la sauvegarde.

> [!ATTENTION] Non vérifié. Procédure déduite du message de Domenia, non outillée et non jouée : répétez-la d'abord dans une VM de test. Ne copiez jamais une sauvegarde à côté d'anciens fichiers -wal et -shm. Les associations et relevés postérieurs à la sauvegarde sont perdus ; les objets AD se relisent.

## Schéma et migrations

Le schéma de données est en version 11. Les migrations ne vont que vers l'avant ; une base plus récente, illisible ou ambiguë est refusée intacte. Avant une migration, une sauvegarde obligatoire est écrite dans Backups\migrations.

## Mesure et purge

Les outils « Mesurer » et « Purge volontaire » existent dans l'onglet « Fiabilité », masqué depuis le 7 octobre. Cet onglet regroupe aussi les reçus, « Autoriser une intervention sur cette machine » et « Reprendre les sauvegardes ». Il ne s'affiche que lorsque Domenia y conduit : en usage normal, seul le bouton « Ouvrir : Outils > Fiabilite » de l'onglet « Secrets » du poste le fait, quand une écriture est en cours ou à vérifier. Les messages qui citent « Outils > Fiabilite » n'ouvrent pas l'onglet. Une purge garderait toujours les associations, l'historique protégé, les secrets, la configuration, les préférences, les journaux et les reçus, et ne compacterait pas le fichier.

# 19 Règles de sécurité

Domenia lit par défaut, n'envoie rien sur le réseau sans geste explicite et ne garde aucun secret sur le disque. Son intégrité est contrôlée à chaque démarrage. Ces règles sont dans le code ; ne les contournez pas par la configuration.

| Règle | Comment Domenia l'applique |
|---|---|
| Lecture par défaut | Démarrage toujours en lecture seule ; passage en écriture confirmé et signalé en rouge (chapitre 14). |
| Aucune sonde sans geste | Pas de mise à jour de la base à l'ouverture, pas de relevé au démarrage, pas de détection sur tout le parc, pas d'analyse sur le domaine entier. Chaque relevé passe par une confirmation et lit quatre postes au plus à la fois. |
| Pas de rejeu | Une écriture n'est jamais rejouée automatiquement ; les reçus servent à vérifier. |
| Secrets en mémoire | Mots de passe jamais enregistrés, effacés à la fermeture ; seul l'identifiant peut être mémorisé. LAPS et BitLocker : une valeur à la fois, jamais journalisée ni mise en cache, presse-papiers vidé après 30 s. |
| Windows intact | Aucun certificat accepté à l'aveugle ; WinRM, pare-feu, antivirus et stratégies jamais modifiés. Le déblocage du paquet ne change aucune stratégie. |
| Transports intrusifs | ADMIN$, Planificateur et PsExec inactifs sans l'autorisation de 5 minutes pour le poste ; avec elle, ils servent aussi de repli à certaines lectures quand CIM échoue (chapitre 5). |
| Intégrité | Manifeste vérifié à chaque démarrage, chargeur fermé, registre des workers épinglé. |
| Données locales | Base obligatoirement locale ; dossier protégé en mode UserLocal ; dossiers redirigés refusés. |
| Journaux masqués | Mots de passe, jetons, en-têtes d'authentification et clés de récupération masqués avant écriture. |

> [!ATTENTION] Le manifeste n'est pas une signature. Domenia.exe et le runtime livrés ne sont pas signés. Pour une diffusion qui exige une signature : tools\Signer-Distribution.ps1 signe les scripts de la copie préparée (build_packages.py --stage-dir) avec un certificat de signature de code approuvé, puis, après la construction, le catalogue du manifeste livré (-ManifestCatalog). Domenia.exe (F8) et les composants tiers ne sont pas re-signés : tools\Test-DomeniaSignature.ps1 les accepte pour leur empreinte épinglée dans tools\release-contract.json. Ce contrôle est hors ligne et rend séparément l'intégrité et l'éditeur ; -RequireSignature exige les scripts signés et les binaires épinglés, -RequireSignedManifest exige aussi le catalogue signé, seul à couvrir les fichiers non signables (.json, .xaml, .cs, .cmd, .ico, verrou).

> [!NOTE] Données réelles. Les journaux, exports et diagnostics contiennent des noms de comptes, de postes, de domaines et des chemins internes : ils ne sont pas anonymisés. Relisez-les avant tout partage.

# 20 Journaux et diagnostic

Domenia écrit un journal applicatif, une trace de démarrage et une trace de connexion dans le dossier des données. Les contrôles --check et « Verification » se font sans écrire dans AD. Pour un incident, rassemblez la trace utile et le diagnostic exporté, puis relisez-les avant de les transmettre.

## Fichiers journaux

| Fichier | Contenu |
|---|---|
| DOSSIER_DONNEES\Logs\Domenia.log | Journal applicatif : date, niveau, compte AD, identité Windows et texte masqué. Rotation au-delà de 5 Mio vers Domenia.log.1. |
| DOSSIER_DONNEES\Logs\Domenia-startup.log | Étapes du démarrage. |
| DOSSIER_DONNEES\Logs\Domenia-login.log | Trace de connexion ; à défaut, %LOCALAPPDATA%\DOMENIA\Logs puis %TEMP%\DOMENIA\Logs. |
| %TEMP%\Domenia-startup-error.log | Erreurs du contrôle de démarrage, avant le cœur. |
| %TEMP%\Domenia-pack-ID.json | Rapport de VERIFIER-PACK.cmd. |
| %LOCALAPPDATA%\Domenia\Receipts | Reçus des opérations. |

## Dans l'interface

- « Journal de session », en bas de la fenêtre : événements et erreurs de la session ; « Copier » ne masque pas les noms internes.
- Accueil, « Détails de la session et outils de vérification », « Ouvrir le journal » : ouvre Domenia.log dans le Bloc-notes.
- Outils, onglet « Journal » (profil Expert) : journal détaillé de l'application.
- Outils, onglet « Charge & stats » : durée, volume réseau estimé, replis distants et taux de réussite des opérations.
- Outils, onglet « Domaine » : rôles FSMO, niveaux fonctionnels, contrôleurs et stratégie du domaine.

## Vérification de l'application

Outils, onglet « Verification » (profil Expert) : « Verification rapide » contrôle la connexion et les composants ; « Verification complete » ajoute des mesures de performance. Aucune modification d'Active Directory.

« Exporter le diagnostic » produit Domenia-Diagnostic-DATE.zip : runtime.json, configuration-sanitized.json (valeurs sensibles masquées), self-check.csv et README.txt. Ce dernier rappelle : « Journaux bruts exclus. Les identites, noms de machines, domaines et chemins ne sont pas anonymises. Relire avant partage. ».

## Contrôler le paquet sans démarrer

~~~
Domenia.exe --check
powershell -NoProfile -STA -File wad\Domenia-Start.ps1 -CheckOnly
~~~

La seconde forme, lancée depuis une console Windows PowerShell 5.1 x64 dans le dossier d'installation, garde le message à l'écran. Dans le paquet DEV, VERIFIER-PACK.cmd contrôle les empreintes et la syntaxe de tous les fichiers du manifeste et écrit un rapport JSON ; les fichiers conservés y sont notés LOCAL.

> [!NOTE] Avec Domenia.exe --check, la console peut se fermer dès la fin du contrôle : préférez la seconde forme ou VERIFIER-PACK.cmd, qui se termine par une pause.

## Démarrage en diagnostic

Domenia.exe --diagnostic, ou LANCER-Domenia.cmd du paquet DEV, démarre Domenia avec une console visible. Une erreur fatale du cœur affiche « DOMENIA na pas pu terminer son initialisation. » avec les chemins des journaux de démarrage et de connexion.

Pour une connexion qui échoue sans cause claire, passez temporairement la fenêtre de connexion en Debug (chapitre 14), reproduisez, puis remettez Standard.

## Collecter un incident

1. **Relever le contexte.** Notez l'heure, la version affichée dans le pied du menu, le compte, le poste ou l'objet concerné et le message exact.
2. **Rassembler.** Copiez le journal de session, Domenia.log et, selon le cas, Domenia-login.log ou le rapport du diagnostic du poste. Exportez le diagnostic depuis l'onglet « Verification ».
3. **Vérifier avant d'agir.** Après une écriture au résultat incertain, relisez l'objet dans AD et consultez les reçus ; ne relancez rien à l'aveugle.
4. **Partager le nécessaire.** Relisez les fichiers : aucun mot de passe, aucune clé ; les noms internes restent des données internes.

# 21 Tests et qualification

Les tests se jouent dans une VM Windows de test, jamais sur un poste de production ni sur la machine qui héberge les VM. Les contrôles faits hors Windows ne qualifient rien. Une livraison n'est qualifiée qu'avec un rapport Windows PowerShell 5.1 lié à l'empreinte de ses ZIP.

> [!ATTENTION] N'exécutez jamais une suite de tests, un aperçu ou Domenia lui-même pour un essai sur un poste de production ou sur l'hôte des VM. Certaines suites chargent la vraie fenêtre et le moteur complet.

## Contrôles hors Windows

Depuis le dossier dev du dépôt, avec Python. Ils sont utiles avant d'aller en VM, mais ne prouvent rien sous Windows PowerShell 5.1.

~~~
python tools/release_contract.py --check
python tools/validate_powershell_static.py
python tools/audit_preload.py
python tools/update_worker_contracts.py
python tools/build_packages.py --output DOSSIER_HORS_DU_DEPOT
~~~

Relevé du 8 octobre sur l'arbre courant : contrat conforme, 139 fichiers PowerShell analysés sans erreur, 168 contrôles de préchargement réussis, 68 opérations sans écart, 435 empreintes du manifeste DEV conformes.

## Suites Windows

Les suites sont dans wad\tests du paquet DEV. Chacune accepte -ReportPath pour un rapport JSON.

| Suite | Objet |
|---|---|
| Test-DomeniaRules.ps1 | Règles pures des modules, sans WPF ni réseau ; option -Filter. |
| Test-DomeniaModules.ps1 | Chargeur fermé et modules. |
| Test-DomeniaPreload.ps1 | Préchargement des modules et du XAML (n'est plus lancée par l'installateur). |
| Test-DomeniaBoards.ps1 | Tableaux de bord en widgets dans la vraie fenêtre, données fictives. |
| Test-DomeniaGeometry.ps1 | Géométrie de la vraie fenêtre : thèmes, petit écran, session RDP 1024 × 768, échelles de 100 à 200 % simulées. |
| Test-DomeniaParkDetection.ps1 | Relevés du parc et détection. |
| Test-DomeniaInstaller.ps1 | Installation, restauration, interruption, verrouillage, corruption, modifications concurrentes. |
| Test-DomeniaFaults.ps1 | Pannes injectées : DNS lent, refus AD, LAPS refusé, disque plein, base verrouillée, coupure après envoi. |
| Test-DomeniaCandidate.ps1 | Contrôles de la version candidate (option -Wpf). |
| Suites Test-DomeniaWiring | Preuves de raccordement par lot : accès, cache, écritures, confirmations, interface, moteur, recherche, relations, suites. |

## Jouer les suites dans une VM de test

1. **Préparer la VM.** Une VM Windows 11 jointe à un domaine de test, avec Windows PowerShell 5.1. Aucune donnée de production.
2. **Copier le paquet.** Extrayez le ZIP DEV dans un dossier local de la VM.
3. **Lancer.** Depuis le dossier dev, dans Windows PowerShell 5.1, lancez les contrôles ci-dessous.
4. **Comparer.** Comparez les résultats à la référence : aucun test qui passait ne doit échouer sans décision écrite.
5. **Conserver.** Gardez les rapports JSON avec la date, le commit et l'empreinte du ZIP testé.

~~~
powershell -NoProfile -STA -ExecutionPolicy Bypass -File wad\tests\Test-DomeniaRules.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-DomeniaPs51Compat.ps1 -Root .
powershell -NoProfile -ExecutionPolicy Bypass -File engineering\d120\Test-NativeParser.ps1 -SourceRoot . -ReportPath $env:TEMP\parser.json -RequireWindows51
powershell -NoProfile -ExecutionPolicy Bypass -File engineering\d120\lab\Invoke-LabRun.ps1 -DevRoot . -OutDir $env:TEMP\domenia-out
~~~

Invoke-LabRun.ps1 lance chaque suite dans son propre processus Windows PowerShell 5.1 en STA et écrit, par suite, un rapport JSON, les sorties et le code de retour, plus un résumé _summary.json.

> [!NOTE] -ExecutionPolicy Bypass ne vaut que pour le processus lancé : il ne change pas la stratégie de la machine. Réservez-le à la VM de test.

## Scripts du paquet DEV

| Script | Effet |
|---|---|
| VERIFIER-PACK.cmd | Empreintes et syntaxe de tout le manifeste, sans démarrage ni AD, puis rapport de signature hors ligne (outil pris dans l'arbre du vérificateur, lancé seulement sans fichier en erreur). |
| TESTER-DOMENIA.cmd | Test-DomeniaModules.ps1, puis Test-DomeniaCandidate.ps1 -Wpf si le premier réussit. |
| TESTER-PRECHARGEMENT.cmd | Test-DomeniaPreload.ps1, sur un poste de test. |
| TESTER-MODULES.cmd, TESTER-DEMARRAGE-LOGIN.cmd, TESTER-SELECTION.cmd, TESTER-ACL.cmd | Suites ciblées correspondantes. |
| APERCU-CONNEXION.cmd | Vraie fenêtre de connexion, sans authentification, identité fictive. |
| APERCU-INTERFACE.cmd | Aperçu hors ligne de la vraie fenêtre principale, sans AD. |
| APERCU-PROGRESSIF.cmd | Même aperçu avec 40 postes fictifs. |

> [!NOTE] Les scripts TESTER et APERCU datent du 2 octobre ; leur résultat sur le code du 8 octobre n'a pas été rejoué. Certaines anciennes attentes d'interface ne sont plus des critères de livraison.

## Qualification d'une livraison

- Le suivi dev\engineering\d120\Suivi_D001_D120.json compte 120 points ; aucun n'est encore accepté.
- Un point n'est accepté que sur un rapport Windows PowerShell 5.1 lié à l'empreinte SHA-256 des deux ZIP (release_guard.py --require-windows).
- Derniers résultats déclarés : 2 365 réussites et 0 échec sur la campagne du 5 octobre ; pour le lot du 8 octobre, 495 règles des tableaux de bord sur 495, Test-DomeniaBoards 19 sur 19, Test-DomeniaModules 110 sur 110, Test-DomeniaGeometry 42 sur 42 en 960 × 516.
- Ces résultats viennent de campagnes d'intégration dans une VM de test : ce ne sont pas des rapports qualifiants.

> [!ATTENTION] Restent à qualifier avant un déploiement : la livraison avec un nouveau Build, la mise à jour par l'installateur sur ce Build, les droits AD exacts de chaque écriture, les versions de Windows du parc et la signature si elle est exigée.

# 22 Maintenance et sources

Le comportement décrit ici vient du code de la branche de travail au 8 octobre 2026. Les documents historiques du paquet peuvent être en retard ; en cas de doute, le code fait foi. Ce chapitre indique où lire la source et liste les écarts connus.

## Sources du comportement

| Domaine | Fichiers |
|---|---|
| Lanceur | tools\launcher\launcher.c, Domenia.exe |
| Démarrage et chargeur | wad\Domenia-Start.ps1, wad\Domenia-Modules.ps1 |
| Cœur, fenêtres, configuration, workers du cœur | wad\Domenia-Core.ps1 |
| Tableaux de bord et widgets | modules Domenia-Boards.Model, Domenia-Widgets.UI, Domenia-BoardComputer.UI, Domenia-BoardFleet.Model, Domenia-BoardSoftware.Model, Domenia-Charts.UI, Domenia-Dashboard.UI |
| Requêtes WMI | module Domenia-Probes.Model |
| Parc et relevés | modules Domenia-Park.UI, Domenia-Park.Model, Domenia-Live.UI, Domenia-Live.Model |
| Base autonome | module Domenia-Storage.UI et son worker |
| Comptes et transports | modules Domenia-Access.Model et Domenia-Access.UI |
| Livraison | tools\release-contract.json, tools\build_packages.py, wad\Support\INSTALLER-MISE-A-JOUR.ps1, tools\Test-DomeniaSignature.ps1, tools\operation-contracts.json |

## Règles de maintenance

- Cible unique : Windows PowerShell 5.1 x64 STA. Le garde-fou tools\Test-DomeniaPs51Compat.ps1 doit rester à zéro erreur.
- Scripts en UTF-8 avec BOM ; sans BOM, Windows PowerShell 5.1 casse les accents.
- Après une modification d'un fichier runtime, régénérez les manifestes avec tools\build_packages.py, sinon Domenia-Start.ps1 refuse le démarrage.
- Après une modification d'un worker, mettez à jour le registre (chapitre 15) et listez les opérations modifiées dans les notes de version.
- Chaque nouvelle livraison change le Build du contrat (chapitre 16).

## Écarts connus au 8 octobre

| Écart | Conséquence |
|---|---|
| Le suivi d'un relevé peut afficher « Stockage a verifier dans Fiabilite. ». | L'onglet « Fiabilité » est masqué ; il ne s'ouvre que par le renvoi décrit au chapitre 18. |
| 61 clés de configuration et Streaming.AutoDetectLoggedUser ne sont lues par aucun code. | Sans effet (chapitre 17). |

## Documents du paquet DEV

| Fichier | Contenu |
|---|---|
| LIRE-MOI.md | Lancement, paquets, installateur ; en retard sur la détection du parc. |
| CORRECTIF-*.md | Notes des correctifs des versions RC1.5 à RC1.10.5. |
| engineering\d120\Suivi_D001_D120.json | Suivi des 120 points du lot et de leur statut. |
| engineering\d120\README.md | Reprise des points D001 à D120 : garde de livraison et outils du lot. |
| tools\release-contract.json | Identité de la livraison et empreintes des composants épinglés. |

# 23 Mots à connaître

| Terme | En clair |
|---|---|
| AD | Active Directory, l'annuaire du domaine : utilisateurs, groupes, postes et OU. |
| OU, DN | Unité d'organisation, et son chemin LDAP exact (Distinguished Name). |
| Base autonome | Copie locale SQLite de l'annuaire, avec les associations et les relevés ; une par domaine. |
| Association | Lien mémorisé entre un utilisateur et un poste ; ce n'est pas la preuve d'une session ouverte. |
| Utilisateur console | Compte ouvert sur l'écran physique du poste, lu par CIM ; les sessions RDP ne sont pas comptées. |
| CIM, WMI | Interfaces Windows de lecture à distance de l'état d'un poste. |
| DCOM, WinRM | Transports de CIM : DCOM par défaut, WinRM seulement s'il est déjà en service. |
| Compte des opérations poste | Compte qui interroge les postes : CIM, C$, consoles, inventaire et requêtes. |
| Lecture seule | État de départ : aucune écriture AD ni action modificatrice sur un poste. |
| Relevé | Lecture de plusieurs postes après confirmation, quatre à la fois au plus. |
| Widget | Tuile ou graphique d'un tableau de bord, modifiable, déplaçable et retirable. |
| Requête WMI prête à l'emploi | Lecture d'une classe WMI tirée du catalogue, ajoutée comme widget. |
| Score de santé | Note de 0 à 100 calculée sur les points d'attention. |
| Worker | Code exécuté en arrière-plan, hors du fil de l'interface. |
| Registre des opérations | Liste fermée des 68 opérations admises en arrière-plan, chacune épinglée par SHA-256. |
| Manifeste, empreinte | Liste des fichiers runtime avec leur SHA-256, contrôlée à chaque démarrage ; ce n'est pas une signature. |
| Chargeur fermé | Liste exacte des modules et de leurs fonctions ; un script ajouté n'est jamais chargé. |
| Paquet PROD, paquet DEV | Runtime seul à installer ; runtime plus installateur, sources, outils et tests. |
| Build | Identifiant unique d'une livraison ; l'installateur refuse un Build déjà actif. |
| Reçu | Trace locale d'une opération, utilisée pour vérifier sans rejouer. |
| LAPS | Mot de passe administrateur local géré par AD. |
| Profil Essentiel, Expert | Niveau de détail de l'interface ; aucun effet sur les droits. |
| Démonstration | Mode de formation sans AD, avec des données fictives ; désactivé en service. |
| VM de test | Machine virtuelle Windows réservée aux essais ; jamais de test en production. |
