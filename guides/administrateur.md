# 1 Administrer Domenia

Domenia réunit la recherche Active Directory, l'assistance sur les postes Windows, une base locale du parc et des tableaux de bord. Ce guide s'adresse aux administrateurs qui préparent les comptes, installent l'application, règlent la collecte et entretiennent les données. Le guide technicien décrit les gestes du quotidien.

La base locale et les dernières observations permettent de consulter le parc sans relancer une lecture distante. Les compteurs doivent toujours se lire avec leur périmètre, leur source et leur date. Une donnée absente ou trop ancienne reste inconnue ; elle ne doit pas être assimilée à un poste sain.

## Organiser le travail

- Utilisez l'Accueil pour suivre une OU (unité organisationnelle de l’annuaire) avec son propre sélecteur, consulter les widgets et ouvrir les postes qui composent un chiffre.
- Utilisez l'Atelier de requêtes pour parcourir tous les postes recensés, affiner les conditions, sauvegarder une recherche et en faire un widget.
- Utilisez Rechercher pour retrouver directement un objet de l'annuaire et ouvrir sa fiche.
- Utilisez Outils puis Base autonome pour voir la fraîcheur, suivre une mise à jour, parcourir le contenu et sauvegarder les données.
- Gardez la lecture seule pour la consultation. Une opération qui modifie le poste ou l'annuaire exige les droits nécessaires et sa confirmation.

## Préparer une exploitation fiable

Commencez par une lecture complète d’une OU pilote et de ses sous-OU, puis contrôlez son contenu. Vérifiez que les comptes actifs et désactivés attendus figurent dans la base, que les résultats détaillés correspondent aux widgets et que les relevés disposent des droits distants. Ajustez ensuite le parallélisme à la capacité du réseau.

Les packs PROD et DEV utilisent tous deux des fichiers ordinaires : Domenia.exe et un dossier wad. Le DEV contient aussi les sources, les tests et les outils de reconstruction. La configuration et les préférences restent des fichiers JSON.

Les captures utilisent des données fictives dans l’interface Windows. Elles servent de repères visuels ; les noms de comptes, de domaines et de postes sont des exemples.

# 2 Démarrage rapide

Ces étapes mettent Domenia 1.0 en service sur un poste d'administration. Chaque ligne renvoie au chapitre qui la détaille. Validez les parcours utilisés sur un poste Windows de test autorisé avant de déployer largement.

| Étape | Action | Chapitre |
|---|---|---|
| 1 | Contrôler la livraison et valider les parcours nécessaires sur Windows. | 21 |
| 2 | Vérifier les prérequis : Windows PowerShell 5.1 x64, WPF, module Active Directory ou DLL livrées, dossier local non redirigé. | 16 |
| 3 | Préparer les comptes : lecture de l'annuaire, administration des postes, lecture LAPS et BitLocker, délégations AD pour les écritures. | 13 |
| 4 | Extraire tout le ZIP PROD dans un dossier local ; si Windows bloque les fichiers, lancer wad\Support\DEBLOQUER_TOUT.cmd. | 16 |
| 5 | Contrôler le paquet sans démarrer l'interface : Domenia.exe --check. | 15 et 20 |
| 6 | Relire wad\Domenia.config.json : Auth.DemoProvider absent ou faux, connexion Standard, aucun marqueur wad\Domenia.login.debug. | 14 et 17 |
| 7 | Choisir l'emplacement des données (LocalStore.Mode) : UserLocal dans le profil de l'utilisateur, ou Portable réservé à un support personnel. | 18 |
| 8 | Lancer Domenia.exe, se connecter et vérifier que la case « Lecture seule » est cochée. | 13 et 14 |
| 9 | Remplir la base autonome : Outils, « Base autonome », choisir une OU, puis « Mise à jour » et « Mettre à jour lʼOU choisie ». | 18 |
| 10 | Choisir une OU pilote dans l’Accueil, vérifier ses postes dans l’Atelier de requêtes et lancer une collecte après confirmation. | 3 et 8 |
| 11 | Faire une première sauvegarde de la base : « Sauvegarder maintenant ». | 18 |
| 12 | Remettre aux techniciens le guide technicien et le profil « Essentiel ». | 13 |

# 3 Rechercher fonctionnement et règles

La page « Rechercher » lit l'annuaire à la demande ; elle ne sonde aucun poste avant un geste explicite. Deux modes coexistent : la recherche globale du bandeau, qui ignore l'OU et les filtres, et le contenu d'une OU choisie dans l'arbre, avec ses filtres. Les relevés sur une liste partent après confirmation, avec 1 à 8 postes en parallèle selon le réglage.

| Zone de Rechercher | Utilisation |
|---|---|
| Arbre des OU | Choisissez la branche à parcourir et relisez son chemin. |
| Données de l’OU, sous l’arbre | Base locale, Postes (ping/WMI) et Les deux actualisent toute l’OU choisie et ses sous-OU. |
| Périmètre et Requêtes | Choisissez une source, des filtres ou une recette, puis lancez la recherche. |
| Résultats | Triez, filtrez et ouvrez les objets affichés. Les actions de liste concernent cette liste. |

## Recherche globale

La barre du haut cherche dans tout le domaine, tous types d'objets, sans filtre d'OU, de présence ni de liste. Entrée ou le bouton « Rechercher » la lancent. Aucun poste n'est sondé avant une sélection.

- Minimum de caractères : Browser.GlobalSearchMinChars (2). En dessous, Domenia affiche « Saisis au moins » suivi du minimum et de « caracteres, ou * pour un apercu. ».
- Limite : celle du champ « Limite » (100 par défaut), retenue d'une session à l'autre dans la préférence SearchLimit. « Charger la suite » relit la même recherche avec une limite doublée, jusqu'à 20 000 lignes.
- Recherche globale : 120 s sans nouvel objet AD, 900 s au total ; annulation possible. Délais LDAP : 60/90 s, pages de 250 objets. Réglages et bornes au chapitre 17.
- Recherche à la frappe : désactivée par défaut (Browser.LiveGlobalSearch et Browser.AllowLiveGlobalSearch à faux).
- Pendant une écriture, la recherche attend : « Recherche différée : écriture active ou à vérifier. ».
- Classement : Features.SearchRanking (vrai) ordonne les résultats d'une recherche globale ; sans lui, ils restent dans l'ordre d'arrivée.

Le badge orange « Dernière requête AD : délai dépassé » signale une requête trop longue, sans établir une panne réseau. Affinez la recherche et consultez le journal. « AD injoignable » en rouge correspond à une erreur réseau. La prochaine lecture AD réussie rétablit le badge normal.

Des préfixes facultatifs limitent la recherche à un type (Features.SearchSyntax, vrai par défaut). Un préfixe inconnu est cherché comme du texte.

| Préfixe | Variantes | Effet |
|---|---|---|
| utilisateur: | user:, u: | Utilisateurs seulement. |
| poste: | pc:, machine:, ordinateur: | Postes seulement. |
| groupe: | group:, g: | Groupes seulement. |
| mail: | email:, courriel: | Recherche sur l'adresse mail. |

## Arbre des OU et filtres

L'arbre « Parcourir les OU » affiche le contenu d'une OU. Le menu « ⋯ » près du titre de l’arbre contient la case « Inclure les sous-OU », cochée par défaut ; décochée, seuls les enfants directs sont lus. Le menu clic droit de l'arbre propose aussi « Analyser les droits sur cette branche » et « Nouveau dans cette branche » (écriture, grisé en lecture seule).

| Filtre | Valeurs | Remarque |
|---|---|---|
| Type d'objet | Tous, Utilisateurs, Machines, Groupes, OU et conteneurs | Grisé pendant une recherche globale. |
| Présence réseau | Tous, En ligne, Sans réponse au ping, Non vérifié, Erreur de ping | Filtre les observations mémorisées ; aucun ping collectif. |
| Limite | 100 par défaut | 20 000 lignes au plus. |
| Requêtes | Vues Annuaire, modèles locaux et recettes personnelles | Choisissez une OU, vérifiez la source, puis cliquez sur « Exécuter » ; voir la section Requêtes Annuaire et données locales. |

« Dans les résultats » filtre les objets déjà chargés, sans appel AD ni changement de limite LDAP. Le compteur rapporte les lignes visibles aux objets chargés, pas au total du domaine. « Liste partielle » signale une lecture incomplète ou en erreur : même 746/746 ne certifie pas son exhaustivité.

> [!NOTE] « Sans réponse au ping » ne prouve pas qu'un poste est éteint : l'ICMP peut être filtré. Une liste vide ne prouve pas non plus une absence dans AD.

## Vérification au clic

Un clic sur un poste lance un ping unique et, si « Utilisateur au clic » est cochée, la lecture de l'utilisateur console. L'état initial de la case vient de Streaming.VerifyUserOnSelection (vrai dans la configuration livrée). Deux lectures au plus tournent en même temps (Streaming.MaxUserProbes, borné de 1 à 3). « Revérifier ce poste » relance la même vérification sur le seul poste sélectionné.

La lecture de la console passe par CIM en DCOM, avec le compte des opérations poste (chapitre 5). Si Remote.UseCim est faux, Domenia se limite au ping : « Contrôle réseau uniquement. Aucune lecture du compte console. ». Les sessions RDP ne sont pas recensées.

| Colonne | Valeurs possibles |
|---|---|
| Utilisateur connecté (console) | Le compte, Aucun compte console, Non déterminé, ou le compte suivi de (cache) pour une observation ancienne. |
| Vérification utilisateur | Console observée, Lecture réussie, Accès refusé, Compte distant refusé, Délai dépassé, Non confirmé, Utilisateur non vérifié, Vérification en cours, À vérifier. |
| Présence réseau | En ligne, Sans réponse au ping, Non vérifié, Erreur de ping, Vérification en cours, avec (cache) pour une observation ancienne. |

## Pinger Détecter et Analyser la liste

Ces trois boutons agissent sur les seuls postes affichés, après tous les filtres : OU, recherche, présence et filtre local. Ils sont grisés si la liste ne contient aucun poste. L’Atelier de requêtes, ouvert par son icône depuis l’Accueil, propose également une collecte sur un périmètre explicite (chapitre 8).

![Barre d'actions des résultats : case Utilisateur au clic, Revérifier ce poste, Pinger la liste, Détecter la liste, Analyser la liste et Arrêter](fig:recherche-actions)

| Bouton | Ce qui part | Confirmation |
|---|---|---|
| « Pinger la liste » | Ping ICMP seul, de 1 à 8 postes en parallèle selon le réglage. Met à jour la présence réseau, sans lecture de session ni association. | Nombre de postes, puis « Pinger » ou « Annuler ». |
| « Détecter la liste » | Ping puis lecture légère de la console Windows (CIM/DCOM), de 1 à 8 postes en parallèle selon le réglage. L’identité AD du compte peut être réutilisée pendant cinq minutes au plus ; un compte changé, absent de la base ou une relecture forcée exige une vérification. Associations protégées conservées. | Nombre de postes, puis « Verifier les sessions » ou « Annuler ». |
| « Analyser la liste » | Comme « Détecter la liste », plus le relevé WMI léger (modèle, mémoire, disque C:, build, démarrage) et les requêtes WMI des widgets placés sur les tableaux du poste et du parc. Les résultats remplissent les tableaux de bord. | « Analyser les postes affiches », nombre de postes et de requêtes, puis « Analyser » ou « Annuler ». |
| « Arrêter » | Arrête les nouvelles lectures ; les résultats déjà obtenus restent. | Aucune. |

Les confirmations s'affichent dans la page, sans nouvelle fenêtre ; Échap choisit la réponse sûre. Un relevé s'arrête de lui-même sur des identifiants rejetés, après trois échecs d'enregistrement local, sur un conflit d'enregistrement, ou si une lecture est annulée ou ne correspond pas au poste attendu. Une lecture de poste en échec ne l'arrête pas : elle compte dans les « lectures non confirmees ». Il se met en pause tant que 64 enregistrements locaux attendent.

> [!ATTENTION] Préparez un périmètre explicite et relisez le nombre de cibles avant chaque collecte.

## Actualiser les données de l’OU

Sous l’arbre de Rechercher, « Données de l’OU » reprend l’unité choisie dans cet arbre, même lorsque la liste montre une recherche globale. « Base locale », « Postes (ping/WMI) » et « Les deux » portent toujours sur cette OU et ses sous-OU. Les filtres, la limite de lignes et le réglage de profondeur de la liste ne changent pas leur cible. Le chemin annoncé fait foi ; sans OU explicite, aucune de ces actions ne démarre. Le chapitre 8 décrit leur enchaînement et les trois dates à distinguer.

Dans une petite fenêtre, le panneau sous l’arbre se compacte : le titre « Données de l’OU » se masque et « Postes (ping/WMI) » devient « Ping/WMI ». Les commandes gardent le même périmètre et le même effet.

Pinger, Détecter et Analyser la liste gardent leur cible propre : les postes affichés après filtrage. « Actualiser » dans les résultats relance leur lecture ; cette commande ne remplace pas une mise à jour de la base ou un relevé WMI de toute l’OU.

## Requêtes Annuaire et données locales

La zone « Requêtes » réunit les vues LDAP de l’annuaire, les 152 modèles locaux et les recettes personnelles. Le champ de recherche ignore les accents et la casse. L’étoile épingle la sélection ; « Favoris » filtre le catalogue. Jusqu’à 200 favoris sont conservés dans les préférences personnelles. Choisir une ligne, filtrer le catalogue ou changer l’état proposé ne lance aucune lecture : cliquez sur « Exécuter ».

| Source annoncée | Population et lecture | Points à vérifier |
|---|---|---|
| Annuaire en direct | Vues LDAP sur les types indiqués : utilisateurs, postes ou objets AD. | OU de Rechercher, niveau direct ou sous-OU, limite et droits de lecture. |
| Base locale et relevés datés | Postes déjà recensés dans la base du domaine ; calcul des conditions sur les attributs AD copiés et les observations disponibles. | Couverture du recensement, fraîcheur propre à chaque mesure, état choisi et limite d’affichage. |

Les deux sources utilisent l’OU choisie dans l’arbre de Rechercher et la profondeur affichée. Elles ne reprennent pas implicitement le périmètre du tableau de bord. L’exécution retire les anciennes intersections de la liste — type, présence, texte local et sélection de GUID — pour éviter qu’un filtre précédent ne masque le nouveau résultat.

![Barre Requêtes : recherche locale du modèle, favoris, source et commande Exécuter ; données fictives](fig:recherche-requetes)

Pour une requête locale, choisissez l’état puis cliquez sur « Exécuter » :

| État | Interprétation |
|---|---|
| Correspondants — Match | Les données disponibles satisfont la requête. |
| Inconnus — Unknown | Les données ne suffisent pas à trancher ; une mesure manquante ou expirée reste inconnue. |
| Non correspondants — NoMatch | Les données permettent d’écarter le poste pour cette requête. |

![Sélection Inconnus dans Rechercher : les postes sans mesure exploitable restent consultables ; données fictives](fig:recherche-inconnus)

Le compteur sépare les lignes affichées, le total de l’état choisi et les trois états. La limite est de 20 000 lignes au maximum. Une limite atteinte n’est pas un recensement complet : pour une requête locale, augmentez-la puis réexécutez. « Charger la suite » concerne les lectures Annuaire lorsque ce bouton est disponible. Le changement de session, de base ou d’OU invalide un ancien retour ; aucune ligne ne s’ouvre et aucune collecte ne part automatiquement à la réception du résultat.

La date « calcul local » décrit l’évaluation. La « dernière lecture complète couvrante » décrit la copie AD de l’OU, éventuellement assurée par la lecture complète d’une OU parente. La mention d’une tentative incomplète reste visible. Ces dates ne rajeunissent pas les mesures des postes ; une couverture absente n’empêche pas le calcul sur les objets déjà connus, mais ne permet pas de conclure à leur exhaustivité.

« Effacer la requête » annule la requête et efface ses résultats. Sur une liste de recherche ordinaire, il retire seulement le filtre de requête supplémentaire, dont une ancienne sélection de GUID, et conserve la liste sans relancer de lecture. Le crayon ouvre Outils → Atelier de requêtes. Une recette locale est chargée dans Composer ; une vue Annuaire conserve son filtre LDAP et ouvre la Bibliothèque, car le compositeur sert aux recettes locales des postes.

Dans une fenêtre étroite ou basse, la barre peut se replier : « Options de requête » regroupe le filtre de modèles, les favoris, la source et le choix des résultats. Le bouton rappelle le choix, par exemple « Inconnus », et « Effacer » reste directement accessible. Ouvrez ou repliez ces options selon la place nécessaire ; vos choix sont conservés et aucune recherche ne se lance. Échap referme le volet.

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
| Compte | « Déverrouiller le compte », « Activer », « Desactiver », « Reinitialiser le mot de passe », « Options de compte » puis « Appliquer », « Fixer » ou « Jamais » pour l'expiration, « Expirer le mot de passe », « Déplacer », ajout ou retrait de groupe. |
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

![Actions du poste : état du compte, Ping, Bureau à distance, Ouvrir C$, consoles, journaux et services ; données fictives](fig:actions-poste)

![Autres actions : commande PowerShell, programme, stratégies et redémarrage ; données fictives](fig:actions-poste-avancees)

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

## Ouvrir le partage administratif et les consoles

Le contrôle du port 445 et l'ouverture SMB se font dans le worker ComputerAdminShare, hors du fil de l'interface : la fenêtre reste disponible pendant l’attente. L'Explorateur ou la console s'ouvre quand le partage répond.

1. **Compte.** Domenia prend le compte des opérations poste (section suivante).
2. **Port.** Il vérifie que le port 445 du poste répond. Sinon : « le partage du poste ne repond pas (port 445). ».
3. **Connexion.** Il ouvre le partage avec ce compte. Un refus affiche le motif Windows après « refuse pour ».
4. **Outil.** Il lance l'Explorateur sur le partage, ou la console demandée. Succès : « C$ de » suivi du poste, de « ouvert avec » et du compte.

Pour les consoles, si l'ouverture préalable échoue, la console s'ouvre quand même avec la session Windows : « Console ouverte avec la session Windows : » suivi du motif. Si le technicien s'est connecté avec « Utiliser mon compte Windows », sans mot de passe, il n'y a pas d'ouverture préalable.

> [!NOTE] Le compte en service est toujours affiché dans la pastille « Compte poste » en haut d'Assistance poste (section suivante). Le bureau à distance passe par Windows.

## Compte des opérations poste

C'est le compte qui interroge les postes : WMI et CIM, C$, consoles, inventaire, détection et requêtes des widgets. Il peut différer du compte de connexion et n'est jamais enregistré sur le disque. La pastille « Compte poste : … ▾ », en haut d'Assistance poste et visible dans tous ses onglets, nomme le compte en service. Un clic ouvre un panneau latéral dans la page : « Identifiant », « Mot de passe », « Utiliser ce compte » et « Revenir au compte de connexion » (oublie le compte saisi). Fermer le panneau, par « Fermer », Échap ou un clic à côté, ne change pas le compte et efface un mot de passe tapé sans « Utiliser ce compte ».

Ordre de choix pour une opération sur un poste :

1. **Compte local temporaire.** Un compte local de ce poste accepté après un refus, pour ce poste seulement.
2. **Compte temporaire.** Un compte accepté après un refus pour les postes, oublié après une période sans utilisation.
3. **Compte poste saisi.** Celui du panneau « Compte poste », en mémoire seulement.
4. **Compte Postes.** Celui de la zone « POSTES / WMI / DISTANT » de la page « Comptes » (chapitre 13).
5. **Compte de connexion.** Le compte saisi dans la fenêtre de connexion de Domenia.
6. **Session Windows.** La session qui exécute Domenia.

Le panneau dit le compte en service et son origine, par exemple « Opérations poste : DOMAINE\adm-poste (compte poste saisi, en mémoire seulement). » ou « Opérations poste : session Windows (DOMAINE\technicien). ».

## Diagnostic sessions et secrets

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

## Sources des données

| Section | Source | Si vide |
|---|---|---|
| Vue d ensemble | Calculée sur toutes les vérifications ci-dessous. | — |
| Identite du poste | Inventaire rapide ou complet. | « Lancez un inventaire (Rapide ou Complet) pour remplir cette section. » |
| Compte machine dans Active Directory | Attributs lus avec la fiche du poste. | « Ouvrez la fiche du poste dans l annuaire pour lire son compte machine. » |
| Ressources | Mesures de l'inventaire par CIM. | « Lancez un inventaire pour mesurer la memoire, le processeur et les disques. » |
| Activite | Inventaire complet. | « Inventaire complet requis : correctifs, processus et evenements. » |
| Securite et etat | Inventaire complet. | « Inventaire complet requis : protection, correctifs et configuration. » |

Quand on sélectionne un autre objet, les tableaux du poste et des logiciels sont réinitialisés, ainsi que leur annulation. La liste de l'onglet Inventaire peut être reprise du cache de la session avec son âge ; cette reprise ne rejoue pas le tableau de bord et ne lance aucune lecture.

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
| Horloge du poste | Plus de 300 s avec le contrôleur | Critique | Écart avec le contrôleur : risque d’échec de l’authentification Kerberos. |
| Horloge du poste | Plus de 60 s ; référence contrôleur ou poste d’administration | À surveiller | Écart mesuré. Si le contrôleur n’a pas été lu, vérifier la synchronisation des deux postes. |
| Version de Windows | Date de fin de service dépassée | Critique | Version et date de fin de service : poste à migrer. |
| Version de Windows | Fin de service dans 90 jours ou moins | À surveiller | Version et date de fin de service à préparer. |
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

Les widgets « Administrateurs locaux », « Sessions et comptes locaux », « Demarrage automatique », « Partages », « Imprimantes » et « Certificats machine » comptent sans lever de point d'attention. L'horloge est comparée à celle du contrôleur de domaine lorsque cette référence peut être lue ; sinon Domenia utilise celle du poste d'administration. Relisez la référence indiquée avec le résultat.

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

Les dates viennent du fichier livré Domenia-WindowsLifecycle.json, selon le build et la famille (Pro, Entreprise, LTSC, LTSB, IoT ou Serveur). Sans date correspondante, la fin de service reste inconnue et ne crée pas d’alerte critique. Gardez cette table à jour et vérifiez les dispositions de maintenance applicables à votre parc.

# 8 Tableau de bord et Atelier de requêtes

La vue du parc se calcule depuis la base SQLite et les observations enregistrées. Elle ne nécessite pas une recherche préalable dans l'annuaire. Le sélecteur de l'Accueil, celui de Rechercher et celui de la Base autonome sont indépendants : chacun conserve son usage et son périmètre explicite.

## Périmètre et couverture

Une OU est une unité organisationnelle de l’annuaire, utilisée pour organiser les objets par site, service ou usage.

L’OU choisie et ses sous-OU limitent la vue. Le chemin cliquable permet de remonter vers une OU parente. Les comptes actifs et désactivés sont présents dans le recensement ; les indicateurs qui ne portent que sur les actifs le précisent. La collecte du périmètre depuis l’Atelier retient ses comptes actifs ; les commandes de liste de Rechercher suivent les postes affichés annoncés à la confirmation.

Vérifiez la couverture de la base, le nombre d'objets, la date de mise à jour et le statut complet ou partiel. L'absence d'un objet dans une liste limitée n'est pas une preuve de son absence de la base. La table locale présente 200 postes par page avec un total calculé sur tous les résultats.


Le sélecteur intégré présente un arbre des OU et un champ de recherche. Les branches sont classées par nom dans l’ordre alphabétique français ; la barre verticale permet de les parcourir. Dépliez les branches ou recherchez un nom, puis distinguez les homonymes par leur chemin avant de confirmer.

![Choix du périmètre : arbre des OU, recherche et chemin de la sélection ; données fictives](fig:selecteur-ou)

« Ouvrir dans Rechercher » transmet les postes recensés du périmètre, y compris les comptes désactivés. Cette action retire les filtres résiduels de la liste de recherche, notamment une ancienne sélection de requête ; elle permet ensuite d’utiliser les commandes de liste sur la cible annoncée.

## Trois commandes pour actualiser l’OU

Accueil et Rechercher proposent les mêmes actions. Elles utilisent le choix d’OU de leur écran sans modifier les choix des autres pages. Chaque action couvre cette OU et ses sous-OU ; la profondeur et les filtres de la liste de Recherche restent inchangés. Une OU explicite est obligatoire : aucune expansion silencieuse à tout le domaine.

| Commande | Population | Travail effectué |
|---|---|---|
| Base locale | Objets AD de l’OU et de ses sous-OU | Lecture de l’annuaire puis enregistrement local. Une lecture complète rapproche les absences uniquement dans ce sous-arbre ; les autres branches sont conservées. |
| Postes (ping/WMI) | Comptes ordinateur actifs déjà recensés dans cette branche | Ping, console, inventaire léger et sondes WMI des widgets Général/Poste forcés, après confirmation du nombre de cibles. |
| Les deux | Branche AD, puis comptes ordinateur actifs du recensement obtenu | Même mise à jour de la base, puis même relevé des postes après confirmation du stockage réussi. |

Le relevé des postes ignore les filtres et limites de résultats. Il conserve le parallélisme borné configuré pour la collecte, mais relit les mesures demandées au lieu de les réutiliser à cause de leur âge. Les sondes des widgets configurés sur les tableaux Général et Poste sont dédoublonnées ; leur plan est fixé au clic initial, avant la phase AD et la confirmation. Modifier un widget pendant la passe ne change pas les lectures déjà préparées. Les comptes désactivés restent consultables et ne sont pas sondés. Si le recensement est ancien ou incomplet, « Les deux » permet de le relire avant de préparer les cibles.

L’enchaînement de « Les deux » attend le reçu d’enregistrement complet de sa propre lecture AD. Un résultat LDAP reçu ne suffit pas. Une passe partielle, un échec de stockage, un arrêt ou un changement de session, de base ou d’OU cible empêche le lancement de la phase suivante. Une nouvelle tentative d’enregistrement automatique ne doit pas relancer la collecte annulée. Les données déjà validées restent conservées ; un échec de mesure conserve les dernières valeurs réussies et leur date, avec un état d’échec distinct.

« Arrêter » coupe les nouveaux départs et l’enchaînement. La progression distingue la lecture AD, l’enregistrement et le relevé des postes. Relisez son bilan et les erreurs par poste avant de conclure que toute la branche est à jour.

Le bouton « Recalculer la vue » prépare uniquement l’affichage depuis les données locales. Il ne contacte ni AD ni les postes et ne modifie aucune date de lecture.

## Calculs en arrière plan

Les workers lisent SQLite dans une transaction cohérente, projettent les données nécessaires et préparent les regroupements hors du fil WPF. Les bibliothèques C# réduisent le coût du décodage JSON, des sélections et des agrégations. Le résultat est appliqué seulement s'il correspond encore à la session, au périmètre et à la demande affichée.

Les observations détaillées restent dans SQLite. La préparation d'une collecte conserve le JSON et une identité légère ; le décodage complet est limité aux postes admis dans les créneaux d'exécution. Le nombre de créneaux est borné, même si le parc contient plusieurs milliers de postes.

## Chiffres et fraîcheur

| Source | Informations | Actualisation |
|---|---|---|
| Annuaire indexé | Identité, OU, compte actif, système déclaré, dates AD | « Base locale », « Les deux » ou « Mettre à jour lʼOU choisie » dans Base autonome. |
| Présence et console | Ping, utilisateur ouvert sur l'écran physique | « Postes (ping/WMI) », « Les deux », collecte ciblée ou vérification du poste. |
| Inventaire | Modèle, mémoire, disque C, système mesuré, démarrage | « Postes (ping/WMI) », « Les deux » ou analyse ciblée. |
| Sondes | Informations du catalogue WMI | Postes (ping/WMI) pour les sondes des widgets configurés, ou collecte ciblée. |

Trois horloges restent distinctes : la dernière lecture complète AD couvrant l’OU, les dates réelles des mesures de chaque poste, et l’heure du calcul local de la vue. La date d’un calcul ou d’une mesure récente sur un seul poste ne décrit pas la fraîcheur de toute la branche. Une lecture AD partielle garde la date complète précédente et affiche séparément la tentative.

Le bandeau « Postes actifs : ping N/M (du… au…) · inventaire WMI N/M (du… au…) » rapporte les observations utilisables au nombre de comptes actifs recensés. Chaque intervalle va de la plus ancienne à la plus récente des mesures utilisables de cette famille. Une mesure absente, expirée ou sans date exploitable ne reçoit pas la date AD ou celle du ping en remplacement. Une profondeur de couverture non attestée ou une date future reste signalée au lieu de faire paraître la base récente.

Pour le ping, la date affichée correspond au relevé de présence qui comprend cette vérification. Le lecteur natif ne fournit pas d’horodatage séparé de la réponse ICMP ; cette date ne doit pas servir à mesurer cet instant précis.

Chaque famille conserve sa propre date. Un ping réussi ne rend pas frais l'inventaire matériel ; une erreur de console ne remplace pas une mesure par zéro. Une absence confirmée de session efface l'utilisateur courant, tandis qu'un échec de lecture garde l'observation précédente avec son contexte.

L'inactivité AD est approximative car lastLogonTimestamp est répliqué avec retard. Les classes sont 0 à 6 jours, 7 à 29, 30 à 89, 90 à 179, 180 et plus, puis non renseigné. « Sans connexion depuis 90 j » porte sur les comptes actifs ayant une date connue âgée d'au moins 90 jours. Une date absente ne prouve pas que le poste ne s'est jamais connecté.

## Du widget à la liste exacte

La petite icône de détail près du crayon d’un indicateur apparaît au survol ou au focus clavier ; elle ouvre sa requête dans une page dédiée de l’Atelier. L’icône affiche directement l’onglet « Résultats ». Le corps de la carte et les segments des graphiques ne changent pas de page. Le périmètre du tableau de bord reste visible dans l’Atelier ; les conditions permettent de préciser la sélection. « Retour » revient à l’écran précédent. Les listes, exports et actions s’appuient sur les identifiants des objets, avec contrôle de l’identité au moment d’ouvrir ou d’agir.

Pour les sondes comportant plusieurs valeurs par poste, un poste peut appartenir à plusieurs catégories. Chaque catégorie compte ce poste une seule fois ; la somme des catégories peut donc dépasser le total de postes. « Autres » regroupe les valeurs hors des catégories affichées.

« Détailler les postes » d'un point d'attention ouvre une sélection figée des GUID concernés. L'aperçu initial de 20 noms n'est pas la limite du détail : celui-ci est paginé. Une sélection admet 20 000 identités au maximum et reste bornée au périmètre courant. La mention « Sélection figée » reste visible ; effacer le segment retire cette restriction. Une requête sauvegardée à partir de cette sélection garde les mêmes GUID, pas la règle d'alerte évolutive.

![Détail d’une alerte dans l’Atelier : sélection figée par GUID, périmètre explicite et résultats ; données fictives](fig:alerte-selection)

Sélectionnez une ligne pour consulter son détail local. Relisez l’identité, la provenance et la fraîcheur avant d’utiliser les actions disponibles.

![Fiche locale du poste sélectionné dans l’Atelier ; données fictives](fig:atelier-fiche-locale)

## Construire une requête

L’Atelier se trouve dans Outils → Atelier de requêtes. La petite icône de la barre du parc y ouvre le brouillon ; le crayon de Rechercher prépare la recette locale sélectionnée. L’Atelier utilise le périmètre du tableau de bord, indiqué en haut de sa page : relisez-le, car il peut différer de l’OU de Rechercher. « Résultats » réserve la place au tableau et à la fiche locale ; « Composer la requête » regroupe les conditions, les sauvegardes, les sondes et les réglages de collecte. « Bibliothèque » présente les modèles et vos requêtes personnelles. « Catalogue des informations » aide à choisir un champ et à comprendre sa source.

1. **Choisir une base.** Sélectionnez Tous les postes recensés ou un modèle adapté, puis « Charger ». « Nouvelle » prépare une requête vide. Ces deux commandes ouvrent « Composer la requête ».
2. **Ajouter les conditions.** Choisissez le champ, l'opérateur proposé et la valeur. Les opérateurs sont adaptés au type texte, nombre ou booléen.
3. **Choisir la combinaison.** Toutes les conditions correspond à ET ; Au moins une condition correspond à OU. Une restriction de détail ou une sélection figée s’applique en plus lorsqu’elle est affichée.
4. **Exécuter.** Cliquez sur « Exécuter » pour afficher « Résultats ». Lisez le total, le périmètre et les données absentes avant d’examiner les pages.
5. **Regrouper si utile.** Dans « Composer la requête », choisissez un champ de répartition. Les dix principaux groupes s'affichent, complétés par Autres et Inconnu lorsque nécessaire.
6. **Conserver.** Dans « Composer la requête », enregistrez la recette, créez une sonde dashboard ou appliquez-la aux résultats de Recherche.

Le moteur est un langage de filtres typés ; la recette ne contient ni PowerShell ni SQL libre. Une requête admet 64 conditions en comptant ses raffinements. Les requêtes personnelles enregistrées sont limitées à 100 recettes dans une enveloppe de 1 Mio ; les modèles livrés sont distincts. Les données des postes ne sont pas copiées dans chaque recette. Une sauvegarde refusée est signalée et ne doit pas être considérée comme enregistrée.

![Atelier de requêtes : onglet Résultats et postes recensés paginés ; données fictives](fig:atelier-requetes)

Le filtre d’état conserve l’accès aux comptes désactivés : ils appartiennent au recensement même si la collecte du périmètre dans l’Atelier les exclut.

![Les trois comptes désactivés du périmètre restent consultables ; données fictives](fig:atelier-desactives)

## Bibliothèque de modèles

L’onglet « Bibliothèque » propose 152 modèles livrés dans 14 catégories, accompagnés d’une description. La recherche textuelle et les filtres de catégorie et de source (« Modèles livrés » ou « Mes requêtes ») réduisent la liste. Celle-ci indique le nom, la catégorie et les informations nécessaires. Sélectionnez une ligne, relisez sa description puis cliquez sur « Utiliser cette requête » pour ouvrir « Composer la requête ». Le sélecteur rapide et « Charger » restent disponibles en haut de l’Atelier. Les modèles partagent le même moteur et les mêmes champs que vos requêtes personnelles ; ils peuvent alimenter le tableau général ou celui du poste.

| Catégories | Exemples d’usage |
|---|---|
| Inventaire général ; Comptes et activité AD | Recensement, comptes actifs ou désactivés, dates de connexion. |
| Système et cycle Windows ; Protection AD | Versions, cycle de support, états LAPS et présence de clés AD. |
| Matériel ; Disques et capacité | Mémoire, processeur, batterie, capacité et espace libre. |
| Sécurité du poste ; Réseau | Protection relevée sur le poste, TPM, adaptateurs et configuration IP. |
| Services et processus ; Présence et utilisateurs | Services, démarrage, profils et observations de console. |
| Événements ; Qualité des données | Erreurs relevées, informations absentes ou anciennes. |
| Répartitions ; Vérifications croisées | Regroupements et combinaisons de plusieurs critères. |

Deux exemples : « Comptes désactivés » se calcule depuis la copie AD de l’OU ; « C: moins de 20 % libre » exige un inventaire léger exploitable. Le second seuil est modifiable dans Composer et n’assimile jamais une donnée absente à zéro.

Le nombre de modèles est distinct des 105 champs du catalogue : un modèle combine des conditions sur ces champs. Les valeurs inconnues restent inconnues ; ouvrir ou exécuter un modèle calcule les données locales sans déclencher de collecte réseau. Nommez et enregistrez votre adaptation pour la conserver dans la bibliothèque personnelle.

![Bibliothèque de modèles : recherche locale, informations nécessaires et description de la sélection ; données fictives](fig:atelier-modeles)

## Catalogue des informations

Le catalogue contient les 105 champs acceptés par le moteur : 27 informations du parc et 78 sondes WMI. La recherche ignore les accents et la casse ; elle porte sur le nom, l’usage et les détails techniques, dont les classes et propriétés. Les filtres Source et Catégorie réduisent la liste.

La fiche précise l’usage, le type, l’unité, un exemple de valeur, la collecte nécessaire et les conditions de disponibilité. « Détails techniques » déplie les identifiants, classes et propriétés utiles au diagnostic. Une information présente au catalogue n’est pas une preuve de disponibilité sur tous les postes : les fournisseurs Windows et les droits peuvent varier.

« Utiliser cette information » prépare le champ dans « Composer la requête ». L’opérateur, la valeur et le bouton « Ajouter » restent à choisir explicitement ; cette commande n’ajoute pas de condition et ne lance aucune collecte.

![Catalogue des informations : champ sélectionné, usage, source et disponibilité ; données fictives](fig:atelier-catalogue)

## Exemple de requête réutilisable

Dans « Composer la requête », choisissez l’espace libre du disque système en pourcentage, l’opérateur inférieur à et la valeur 20. Ajoutez la condition puis cliquez sur « Exécuter ». Les mesures absentes ne sont pas assimilées à zéro.

![Requête numérique sur les disques ayant moins de 20 % d’espace libre ; données fictives](fig:atelier-condition)

Revenez dans « Composer la requête », nommez la recette, enregistrez-la puis sélectionnez-la dans la bibliothèque. Son nom doit décrire le critère et rester compréhensible hors du contexte de création.

![Bibliothèque : requête nommée sauvegardée et réutilisable ; données fictives](fig:atelier-bibliotheque)

Dans « Composer la requête », choisissez « Tableau de bord général » et une présentation (Indicateur, Texte, Barres, Camembert ou Colonnes), puis « Créer une sonde dashboard » pour suivre le résultat dans le tableau de bord. Le widget conserve les conditions ; sa petite icône de détail ouvre les postes concernés.

![Widget du parc créé à partir de la requête enregistrée ; données fictives](fig:accueil-sonde-requete)

Dans « Composer la requête », « Appliquer aux résultats de Recherche » transmet les GUID des postes trouvés. Le résultat affiché dans Rechercher garde cette restriction tant qu’elle n’est pas effacée ; un nouveau nom ou un changement d’OU ne substitue pas un autre objet à cette identité.

![Filtre de l’Atelier appliqué à la liste Rechercher ; données fictives](fig:recherche-requete)

## Réutiliser la recette sur le tableau du poste

La bibliothèque est commune à l’Atelier, aux widgets du parc, aux widgets du poste et au filtre de Rechercher. Depuis le tableau du poste, le bouton « Atelier » ouvre « Composer la requête » avec la destination « Tableau de bord du poste ». Vous pouvez aussi choisir cette destination depuis une autre entrée de l’Atelier, puis la présentation et « Créer une sonde dashboard ».

Le widget du poste évalue la recette sur l’objet sélectionné et ses données locales, avec ses états correspondant, inconnu ou non correspondant. Il utilise les mêmes conditions que le widget général, mais son périmètre est un seul poste. Changer de poste réévalue le widget. « Tester sur le poste sélectionné » fournit cet aperçu sans lecture réseau. La liste « Résultats » de l’Atelier garde le périmètre OU affiché dans son en-tête.

Une nouvelle création avec la même recette et la même destination met à jour le widget existant. La disposition est conservée dans les préférences. L’enregistrement, la création du widget et l’aperçu n’exécutent pas les sondes : une collecte reste un geste distinct, avec confirmation.

![Atelier : aperçu local sur le poste et destination du widget ; données fictives](fig:atelier-poste)

![Tableau de bord du poste : requête réutilisable évaluée sur l’objet sélectionné ; données fictives](fig:poste-sonde-requete)

## Régler et suivre la collecte

Les réglages ci-dessous concernent la collecte sélective d’une requête. Les commandes générales « Postes (ping/WMI) » et « Les deux » forcent le ping, la console, l’inventaire léger de l’OU et les sondes des widgets configurés sans leur appliquer cette réutilisation des mesures.

Dans « Composer la requête », « Collecter les données requises… » confirme le nombre de postes et utilise le compte des opérations poste. La collecte traite tous les comptes actifs du périmètre, indépendamment des conditions qui réduisent les résultats de la requête. Pour limiter la collecte, choisissez une OU plus précise ou l’action d’un seul poste dans sa fiche locale. L’encadré « Réglages de collecte » propose 1, 2, 4, 6 ou 8 postes simultanés, avec 4 par défaut. La réutilisation des mesures propose une ancienneté maximale de 5, 15 ou 60 minutes, ou une relecture forcée. Les mesures volatiles conservent leur délai propre ; le choix d'une heure n'impose pas une heure de cache à toutes les sondes.

Le plan de collecte est calculé à partir des conditions, des restrictions et du champ de regroupement. « Collecter les données requises… » et l’actualisation des requêtes des widgets partagent ce plan.

| Informations demandées | Lecture préparée |
|---|---|
| Attributs AD et calculs fondés seulement sur ces attributs | Invitation à mettre à jour la base de l’OU ; aucune sonde WMI. |
| Présence, utilisateur console ou âge du relevé | Contrôle de présence et de console sans inventaire. |
| Modèle, mémoire, disque C:, durée depuis le démarrage, âge de l’inventaire ou version Windows relevée | Inventaire léger. |
| Sondes du catalogue | Union des sondes demandées, sans doublon. |

« Actualiser ce poste… » dans la fiche locale d’un résultat reste une action distincte qui prépare un inventaire léger de ce poste après confirmation. « Postes (ping/WMI) » relit le ping, la console et l’inventaire léger des comptes actifs de l’OU et de ses sous-OU, ainsi que les sondes des widgets configurés. Son plan est figé au clic et ne dépend pas du brouillon de l’Atelier. Les collectes du parc nécessitent une OU explicitement choisie et une vue locale correspondant à ce périmètre.

Le moteur regroupe les sondes WMI d’un poste par classe et filtre, puis demande l’union de leurs propriétés pour réutiliser la lecture. Les filtres restent distincts. Un comptage porte sur toutes les instances lues même si le détail conservé est limité à vingt lignes ; l’inventaire et la lecture de la console conservent leurs lectures propres. Une lecture lente ou refusée n'empêche pas les autres créneaux d'avancer. L'arrêt interdit les nouveaux départs et conserve les résultats déjà obtenus. La progression distingue la collecte du stockage local : attendez les enregistrements avant de conclure que la passe est terminée.

Un inventaire en échec conserve les dernières valeurs réussies avec leur date d’origine. L’échec et la date de tentative sont enregistrés séparément et comptés dans le bilan ; la prochaine collecte demandant un inventaire retente sa lecture.

L’identité AD de l’utilisateur observé peut être réutilisée pendant cinq minutes au plus, avec une date propre à sa vérification. Un nouveau ping ne rajeunit pas cette identité. Un compte absent de la base exige une nouvelle vérification ; « Forcer la relecture » désactive aussi ce cache d’identité.

![Réglages de la collecte dans l’Atelier : parallélisme et réutilisation des observations ; données fictives](fig:atelier-collecte)

## Interpréter les erreurs

Une base occupée appelle un nouvel essai après la fin de l'opération en cours. Une base absente doit être initialisée. Une donnée périmée nécessite la lecture de sa source. Un accès distant refusé nécessite de vérifier le compte et le transport ; aucun champ inconnu ne doit être transformé en succès par défaut.

# 9 Widgets fonctionnement et catalogue complet

Les trois tableaux de bord sont faits de widgets : chaque tuile ou graphique se modifie, se déplace, se redimensionne et se retire. On ajoute un widget depuis le catalogue intégré ou, pour le poste et le parc, depuis les requêtes WMI prêtes à l'emploi. Chaque utilisateur garde sa disposition dans ses préférences.

| Tableau | Où | Données |
|---|---|---|
| Parc | Accueil, sous les boutons d'analyse. | Agrégats de la base autonome et observations en cache. |
| Poste | Poste, onglet « Tableau de bord ». | Dernier inventaire et attributs du compte ordinateur. |
| Logiciels | Poste, onglet « Logiciels », choix « Affichage » puis « Synthèse ». | Liste des logiciels chargée. |

## Commandes du tableau

| Bouton | Quand | Effet |
|---|---|---|
| « Actualiser les requetes » | Tableau du poste, si au moins un widget de requête est présent. | Prépare les lectures requises par les widgets pour le poste sélectionné, en lecture seule et après confirmation. Une recette fondée uniquement sur AD renvoie vers la mise à jour de la base. Sur le parc, ouvrez le détail de la sonde puis collectez depuis l’Atelier, ou utilisez Analyser la liste. |
| « Recalculer la vue » | Tableau du parc. | Relit les données locales et recalcule les widgets ; aucune nouvelle lecture AD, ping ou WMI. |
| « Base locale », « Postes (ping/WMI) », « Les deux » | Tableau du parc ou Données de l’OU dans Rechercher. | Actualisent la source choisie pour l’OU et ses sous-OU, selon le parcours du chapitre 8. |
| « Ajouter un widget » | Toujours. | Ouvre l'éditeur. |
| « Personnaliser » | Hors personnalisation. | Passe en mode personnalisation. |
| « Par defaut » | En personnalisation. | Revient à la disposition livrée, sans confirmation mais annulable. |
| « Terminer » | En personnalisation. | Quitte la personnalisation. |
| « Annuler » | Après une modification. | Revient à la disposition précédente. |

L'annulation n'a qu'un niveau. Elle est perdue quand de nouvelles données arrivent et, pour le poste et les logiciels, quand on sélectionne un autre objet. « Retirer » ne demande pas de confirmation : « Annuler » sert de filet.

## Personnaliser menu et glisser déposer

![Tableau du poste en mode Personnaliser : boutons Modifier et Retirer sur chaque widget, tuiles Ajouter ici en fin de section, boutons Par defaut et Terminer](fig:personnaliser)

- En personnalisation, chaque section se termine par une tuile en pointillés « Ajouter ici », qui ouvre l'éditeur avec la section choisie. Les boutons ronds de modification et de retrait restent visibles ; hors personnalisation, ils apparaissent au survol ou au clavier.
- Les widgets sans donnée restent visibles en personnalisation (« Aucune donnee pour le moment »). Hors personnalisation, un widget intégré sans donnée est masqué.
- Le menu clic droit d'un widget, toujours disponible, propose « Modifier... », « Représentation », « Taille » (« Compacte », « Moyenne », « Large »), « Déplacer » et « Retirer du tableau de bord ». Les déplacements du menu restent dans la section.
- Le glisser-déposer est actif en mode « Personnaliser ». Lâché sur un autre widget, le widget prend sa place et sa section ; lâché dans une section hors d'un widget, il va à la fin de cette section. La page défile près des bords.

## Éditeur de widget

![Panneau Ajouter un widget : recherche, liste des informations disponibles, puis titre, représentation, taille, section et aperçu en direct](fig:editeur-widget)

- À gauche, en ajout seulement : la recherche (« Rechercher : disque, utilisateur, BitLocker... ») et la liste des informations disponibles, groupée en « Tableau de bord » puis en « Requetes WMI » par catégorie. Le badge « affiche » marque ce qui est déjà sur le tableau.
- La recherche ignore accents et casse ; tous les mots tapés doivent se trouver dans le nom, la description ou la section (pour une requête : le nom, la catégorie ou la classe).
- À droite : « Titre », « Représentation », « Taille », « Section » et l'aperçu. La liste « Section » propose les sections du tableau, puis « + Nouvelle section... », qui affiche un champ pour taper son nom ; laissé vide, ce nom devient « Mes widgets ».
- L'aperçu montre les vraies données si le tableau en a, sinon un exemple de même nature.
- Un widget ajouté va à la fin de sa section. Sans donnée encore lue : « Widget enregistre : il s affichera des que ses donnees seront lues. ».

## Natures représentations et tailles

Chaque widget porte une nature de donnée. Elle fixe les représentations permises ; le sous-menu « Représentation » n'apparaît que s'il y en a plusieurs. Une représentation enregistrée qui n'est plus permise est remplacée par la préférée.

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
- L'écriture est différée de 1,5 s pour regrouper les changements ; un changement sans effet n'est ni enregistré ni proposé à l'annulation.

## Animation

À chaque nouvelle lecture, les cartes apparaissent l'une après l'autre, puis anneaux et barres se dessinent et les chiffres comptent depuis zéro. L'animation est coupée quand l'animation Windows est désactivée, par exemple pour l'accessibilité ou une session à distance. Aucun réglage Domenia ne la coupe.

## Catalogue du tableau du poste

| Widget | Groupe | Affichage initial | Information |
|---|---|---|---|
| Etat general | Vue d ensemble | Oui | Score calcule a partir des points d attention |
| Points d attention | Vue d ensemble | Oui | Problemes detectes, du plus grave au moins grave |
| Systeme | Identite du poste | Oui | Version commerciale de Windows et build |
| Modele | Identite du poste | Oui | Fabricant, modele et numero de serie |
| Processeur | Identite du poste | Oui | Modele, coeurs et threads |
| Memoire installee | Identite du poste | Oui | Memoire physique et barrettes |
| En service depuis | Identite du poste | Oui | Duree depuis le dernier demarrage |
| Utilisateur connecte | Identite du poste | Oui | Session console au moment de l inventaire |
| Adresse IP | Identite du poste | Oui | Adresse IPv4 et passerelle |
| Domaine | Identite du poste | Oui | Domaine et role du poste |
| Mot de passe machine | Compte machine dans Active Directory | Oui | Age du mot de passe du compte ordinateur |
| Derniere connexion au domaine | Compte machine dans Active Directory | Oui | Attribut lastLogonTimestamp |
| Compte ordinateur | Compte machine dans Active Directory | Oui | Actif ou desactive, date de creation |
| Unite d organisation | Compte machine dans Active Directory | Oui | OU qui contient le poste |
| Mot de passe LAPS | Compte machine dans Active Directory | Oui | Expiration du mot de passe administrateur local |
| Gere par | Compte machine dans Active Directory | Oui | Attribut managedBy |
| Horloge du poste | Compte machine dans Active Directory | Oui | Écart avec la référence disponible : contrôleur ou poste d’administration |
| Memoire utilisee | Ressources | Oui | Memoire occupee au moment de l inventaire |
| Charge du processeur | Ressources | Oui | Charge du processeur au moment de l inventaire |
| Batterie | Ressources | Oui | Charge restante des postes portables |
| Disque systeme | Ressources | Oui | Espace utilise et libre sur C: |
| Autres volumes | Ressources | Oui | Espace libre des autres volumes, en pourcentage |
| Services Windows | Activite | Oui | Services en cours, arretes et desactives |
| Processus les plus gourmands | Activite | Oui | Memoire utilisee par processus, en Mo |
| Erreurs systeme par source | Activite | Oui | Journal Systeme des 3 derniers jours |
| Antivirus | Securite et etat | Oui | Produit antivirus declare a Windows |
| Pare-feu | Securite et etat | Oui | Profils du pare-feu actifs |
| BitLocker | Securite et etat | Oui | Protection du volume systeme |
| Windows Update | Securite et etat | Oui | Serveur WSUS configure |
| Redemarrage en attente | Securite et etat | Oui | Redemarrage demande par une installation |
| Services automatiques arretes | Securite et etat | Oui | Services automatiques a l arret |
| Peripheriques en erreur | Securite et etat | Oui | Peripheriques signales en erreur |
| Pilotes non signes | Securite et etat | Oui | Pilotes sans signature numerique |
| Administrateurs locaux | Securite et etat | Oui | Membres du groupe Administrateurs |
| Sessions et comptes locaux | Securite et etat | Oui | Comptes et sessions du poste |
| Demarrage automatique | Securite et etat | Oui | Programmes lances au demarrage |
| Partages | Securite et etat | Oui | Dossiers partages par le poste |
| Imprimantes | Securite et etat | Oui | Imprimantes installees |
| Affichage | Securite et etat | Oui | Carte graphique et resolution |
| Disque physique | Securite et etat | Oui | Modele et interface du disque |
| Certificats machine | Securite et etat | Oui | Certificats du magasin ordinateur |
| Dernier correctif | Securite et etat | Oui | Date du dernier correctif installe |

## Catalogue du tableau du parc

Le catalogue contient 29 widgets de parc. Les requêtes personnelles et les 78 sondes peuvent s’y ajouter.

| Groupe | Widget | Information |
|---|---|---|
| Santé | État du parc | Part des postes sans point critique ni à surveiller |
| Santé | Points dʼattention | Problèmes détectés sur le périmètre ; l’action de détail ouvre les postes concernés |
| Inventaire du périmètre | Postes | Tous les comptes ordinateur recensés du périmètre, actifs et désactivés. |
| Inventaire du périmètre | Sans connexion depuis 90 j | Attribut lastLogonTimestamp, à 14 jours près |
| Inventaire du périmètre | Comptes désactivés encore dans lʼOU | Comptes ordinateur désactivés à déplacer ou supprimer |
| Inventaire du périmètre | Créés ces 30 jours | Attribut whenCreated |
| Inventaire du périmètre | Mot de passe machine de plus de 60 j | Attribut pwdLastSet |
| Inventaire du périmètre | Serveurs / postes | Attribut operatingSystem : serveurs et postes de travail |
| Sécurité | Sans LAPS | Expiration LAPS lue avec la base autonome, jamais le mot de passe |
| Sécurité | Sans clé BitLocker | Présence des clés de récupération, lue sur demande pour lʼOU affichée |
| Versions de Windows | Versions de Windows | Attribut operatingSystemVersion de tout le périmètre |
| Versions de Windows | Fin de service | Versions plus maintenues ou bientôt (90 jours avant la date) |
| Versions de Windows | Postes sous Windows 10 | Hors LTSC, LTSB et IoT |
| Répartition | Systèmes dʼexploitation | Systèmes déclarés dans lʼannuaire |
| Répartition | Dernière connexion au domaine | Ancienneté de la dernière connexion |
| Répartition | Postes par unité dʼorganisation | Postes par OU ou sous-OU |
| Relevés des postes | Présence réseau | Derniers relevés de moins de 30 jours |
| Relevés des postes | Utilisateurs détectés | Utilisateurs distincts vus en session sur les postes |
| Relevés des postes | Dernière analyse | Date du dernier relevé des postes |
| Relevés des postes | Modèles | Modèles des postes analysés |
| Relevés des postes | Versions relevées | Versions commerciales relevées par WMI |
| Relevés des postes | Mémoire installée | Postes par quantité de mémoire |
| Relevés des postes | Espace libre sur C: | Postes par espace libre du disque système |
| Relevés des postes | Disque C: presque plein | Postes avec moins de 10 % libre |
| Relevés des postes | Non redémarrés depuis 30 j | Postes à redémarrer |
| Évolution | Postes à traiter sur 90 jours | Instantanés quotidiens locaux de lʼOU affichée |
| Évolution | Windows 10 sur 90 jours | Postes sous Windows 10 hors LTSC, LTSB et IoT, instantanés quotidiens |
| Évolution | Inactifs sur 90 jours | Postes sans connexion depuis 90 j, instantanés quotidiens |
| Évolution | Disques C: presque pleins sur 90 jours | Postes analysés avec moins de 10 % libre, instantanés quotidiens |

## Catalogue du tableau des logiciels

| Widget | Groupe | Affichage initial | Information |
|---|---|---|---|
| Logiciels | Synthese | Oui | Nombre de logiciels et d editeurs |
| Taille declaree | Synthese | Oui | Somme des tailles connues |
| Installés ces 30 derniers jours | Synthese | Oui | Date dʼinstallation déclarée par le logiciel, lue dans la liste |
| Installes en plusieurs versions | Synthese | Oui | Logiciels presents en plusieurs versions |
| Sans editeur declare | Synthese | Oui | Logiciels sans editeur renseigne |
| Composants dʼexécution | Synthese | Oui | Socles Visual C++, .NET et WebView2 déclarés dans la liste |
| Navigateurs et versions | Synthese | Oui | Navigateurs détectés dans la liste, avec leur version |
| Editeurs | Repartition | Oui | Principaux editeurs |
| Architecture | Repartition | Oui | Logiciels 32 et 64 bits |
| Portee d installation | Repartition | Oui | Installation machine ou utilisateur |
| Plus gros logiciels | Repartition | Oui | Taille declaree, en Mo |

# 10 Requêtes WMI du catalogue

Le catalogue propose 78 sondes WMI en lecture seule, en 8 catégories. On les ajoute comme widgets aux tableaux du poste et du parc depuis l'éditeur. Elles partent après confirmation sur le périmètre annoncé : « Actualiser les requetes » sur le tableau du poste interroge le poste sélectionné ; « Analyser la liste » dans « Rechercher » interroge les postes affichés avec les requêtes des tableaux du poste et du parc.

## Protection des requêtes

- Le worker ne reçoit jamais un texte de requête libre : seulement l'identifiant, l'espace de noms, la classe, les propriétés, le filtre et le mode, tirés du catalogue.
- Avant l'appel, la classe et l'espace de noms sont contrôlés ; un nom non conforme donne « Requete refusee. » et une propriété non conforme est ignorée.
- L'appel est une lecture d'instances par Get-CimInstance ; aucune méthode WMI n'est invoquée par ce chemin.
- Les requêtes passent dans la session CIM de la détection, seulement si la lecture de la console a réussi.
- Une erreur est notée pour sa requête sans arrêter les autres.

## Exécution

1. **Lancer.** Poste : cliquez « Actualiser les requetes » sur son tableau ; il faut un poste sélectionné. Parc : préparez les postes dans l’Atelier et lancez la collecte, ou utilisez Analyser la liste dans Rechercher. Les requêtes des widgets présents sont regroupées, sans doublon.
2. **Confirmer.** Poste : confirmation « Sonder pour les widgets », bouton « Verifier les sessions ». Parc : confirmation « Analyser les postes affiches », bouton « Analyser ». Les deux donnent le nombre de postes et de requêtes ; « Annuler » ne lance rien.
3. **Suivre.** De 1 à 8 postes en parallèle selon le réglage. Délai par poste : 20 s plus 8 s par requête, plafonné à 150 s.
4. **Lire.** En fin de relevé, les widgets se remplissent et la vue du parc se recalcule.

| Vous voyez | Que faire |
|---|---|
| « Aucune requete WMI sur ce tableau de bord : ajoutez un widget de requete. » | Ajouter un widget de requête avec « Ajouter un widget ». |
| « Aucun poste selectionne. » | Choisir un poste dans « Rechercher ». |

## Lecture des résultats

- Résultats par poste : valeurs bornées, textes limités et dates en UTC. Une lecture tronquée est signalée et ne devient pas une mesure complète. Le dernier résultat de chaque requête est gardé dans l'observation du poste.
- Tableau du poste : toujours une valeur (chiffre clé ou liste), avec la catégorie et le nom de la requête.
- Tableau du parc : une requête de comptage ou à transformation numérique devient une mesure (moyenne, minimum, maximum, histogramme par tranches) ; les autres deviennent une répartition (valeur la plus fréquente, nombre de postes).
- Sans résultat, le widget affiche « En attente » et, sur le poste, « Actualiser les requetes pour remplir ce widget » ; sur le parc, collectez les mesures demandées depuis l’Atelier.

Modes : First lit la première instance, Count compte les instances, All lit toutes les instances. Transformations : Text, GB (octets en Go), GBfromKB (Ko en Go), MB, Mbps, Number, DaysSince (jours écoulés), Year, PercentFree (pourcentage libre), Release (build en nom de version) et Map (table de correspondance). Dans les filtres, {SINCE_24H} et {SINCE_7D} sont remplacés par la date UTC d'il y a 24 heures ou 7 jours.

> [!NOTE] La requête « Contrôle de compte (EnableLUA) » figure dans le code du catalogue mais en est retirée à la lecture : elle n'est pas proposée. Le catalogue exploitable compte 78 sondes.

## Sondes matériel

| Information | Classe | Propriétés |
|---|---|---|
| Fabricant | Win32_ComputerSystem | Manufacturer |
| Modele | Win32_ComputerSystem | Model |
| Memoire installee | Win32_ComputerSystem | TotalPhysicalMemory |
| Processeur | Win32_Processor | Name |
| Charge CPU du premier processeur (%) | Win32_Processor | LoadPercentage |
| Frequence maximale CPU (MHz) | Win32_Processor | MaxClockSpeed |
| Virtualisation activee dans le firmware | Win32_Processor | VirtualizationFirmwareEnabled |
| Traduction SLAT du processeur | Win32_Processor | SecondLevelAddressTranslationExtensions |
| Charge restante de la premiere batterie (%) | Win32_Battery | EstimatedChargeRemaining |
| Coeurs du processeur | Win32_Processor | NumberOfCores |
| Processeurs logiques | Win32_ComputerSystem | NumberOfLogicalProcessors |
| Version du BIOS | Win32_BIOS | SMBIOSBIOSVersion |
| Annee du BIOS | Win32_BIOS | ReleaseDate |
| Carte graphique | Win32_VideoController | Name |
| Nombre d ecrans | WmiMonitorID | InstanceName |
| Batterie presente | Win32_Battery | Name |
| Type de systeme | Win32_ComputerSystem | PCSystemTypeEx |
| Numero de serie | Win32_BIOS | SerialNumber |

## Sondes système

| Information | Classe | Propriétés |
|---|---|---|
| Edition de Windows | Win32_OperatingSystem | Caption |
| Version de Windows | Win32_OperatingSystem | BuildNumber, ProductType |
| Architecture | Win32_OperatingSystem | OSArchitecture |
| Jours depuis le dernier demarrage | Win32_OperatingSystem | LastBootUpTime |
| Annee d installation de Windows | Win32_OperatingSystem | InstallDate |
| Langue du systeme | Win32_OperatingSystem | OSLanguage |
| Fuseau horaire | Win32_TimeZone | Caption |
| Fichier d echange (Mo) | Win32_PageFileUsage | AllocatedBaseSize |
| Memoire libre (Go) | Win32_OperatingSystem | FreePhysicalMemory |
| Memoire virtuelle libre (Go) | Win32_OperatingSystem | FreeVirtualMemory |
| Memoire visible par Windows (Go) | Win32_OperatingSystem | TotalVisibleMemorySize |
| Utilisateurs declares connectes par Windows | Win32_OperatingSystem | NumberOfUsers |
| Role Windows | Win32_OperatingSystem | ProductType |

## Sondes Disques

| Information | Classe | Propriétés |
|---|---|---|
| Espace libre sur C: (%) | Win32_LogicalDisk | FreeSpace, Size |
| Taille de C: (Go) | Win32_LogicalDisk | Size |
| Nombre de volumes locaux | Win32_LogicalDisk | DeviceID |
| Type de disque physique | MSFT_PhysicalDisk | MediaType |
| Sante du disque physique | MSFT_PhysicalDisk | HealthStatus |
| Supports amovibles connectes | Win32_LogicalDisk | DeviceID |

## Sondes sécurité

| Information | Classe | Propriétés |
|---|---|---|
| Chiffrement BitLocker de C: | Win32_EncryptableVolume | ProtectionStatus |
| Antivirus declare | AntiVirusProduct | displayName |
| Comptes locaux actives | Win32_UserAccount | Name |
| Partages hors administratifs | Win32_Share | Name |
| Antivirus Defender actif | MSFT_MpComputerStatus | AntivirusEnabled |
| Protection temps reel Defender | MSFT_MpComputerStatus | RealTimeProtectionEnabled |
| Surveillance comportementale Defender | MSFT_MpComputerStatus | BehaviorMonitorEnabled |
| Age signatures Defender (j, 65535 jamais) | MSFT_MpComputerStatus | AntivirusSignatureAge |
| Age analyse rapide Defender (j, 65535 jamais) | MSFT_MpComputerStatus | QuickScanAge |
| Age analyse complete Defender (j, 65535 jamais) | MSFT_MpComputerStatus | FullScanAge |
| Version du produit Defender | MSFT_MpComputerStatus | AMProductVersion |
| Specification TPM | Win32_Tpm | SpecVersion |
| TPM active au releve | Win32_Tpm | IsEnabled_InitialValue |
| TPM operationnel au releve | Win32_Tpm | IsActivated_InitialValue |

## Sondes réseau

| Information | Classe | Propriétés |
|---|---|---|
| Carte reseau connectee | Win32_NetworkAdapter | Name |
| Vitesse du lien (Mbit/s) | Win32_NetworkAdapter | Speed |
| Adresse DHCP | Win32_NetworkAdapterConfiguration | DHCPEnabled |
| Premier serveur DNS | Win32_NetworkAdapterConfiguration | DNSServerSearchOrder |
| Passerelle | Win32_NetworkAdapterConfiguration | DefaultIPGateway |
| Wi-Fi connecte | MSFT_NetAdapter | Name |

## Sondes Logiciels et services

| Information | Classe | Propriétés |
|---|---|---|
| Nombre d imprimantes | Win32_Printer | Name |
| Imprimante par defaut | Win32_Printer | Name |
| Programmes au demarrage | Win32_StartupCommand | Name |
| Services automatiques arretes | Win32_Service | Name |
| Services en cours d execution | Win32_Service | Name |
| Service Spouleur d impression | Win32_Service | State |
| Service Windows Update | Win32_Service | State |
| Service WinRM | Win32_Service | State |
| Service BITS | Win32_Service | State |
| Service Heure Windows | Win32_Service | State |
| Service Bureau a distance | Win32_Service | State |
| Service Pare-feu Windows | Win32_Service | State |
| Service Antivirus Defender | Win32_Service | State |
| Service Client DNS | Win32_Service | State |
| Nombre de correctifs installes | Win32_QuickFixEngineering | HotFixID |
| Processus en cours | Win32_Process | Name |

## Sondes Utilisateurs

| Information | Classe | Propriétés |
|---|---|---|
| Utilisateur de la console | Win32_ComputerSystem | UserName |
| Profils utilisateurs sur le poste | Win32_UserProfile | LocalPath |
| Sessions ouvertes | Win32_LogonSession | LogonId |

## Sondes événements

| Information | Classe | Propriétés |
|---|---|---|
| Erreurs systeme (24 h) | Win32_NTLogEvent | EventCode |
| Arrets inattendus (7 j) | Win32_NTLogEvent | EventCode |

# 11 Tableau des logiciels

L'onglet « Logiciels » de la page « Poste » lit la liste des logiciels installés sur le poste, à la demande. Le sélecteur « Affichage » bascule entre « Liste » et « Synthèse ». La synthèse résume la liste chargée avec son catalogue de 11 widgets. Ce tableau ne lève aucun point d'attention et n'accepte pas de requêtes WMI.

![Onglet Logiciels, affichage Synthèse : indicateurs, éditeurs, architecture et portée d’installation ; données fictives](fig:logiciels)

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

## Sources des associations

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

Rien ne part avant la confirmation « Périmètre à confirmer avant toute lecture des postes », bouton « Lancer la détection ». Cet aperçu du périmètre est toujours présenté avant la lecture.

## Journal du contrôleur

« Lire le journal du controleur » (Outils, « Base autonome », « Mise à jour », puis « Relevé du parc ») interroge une seule fois le journal Sécurité du contrôleur de domaine (événements 4768, 4769 et 4624) et en tire des couples utilisateur et poste pour le relevé du parc, sans contacter aucun poste. Une confirmation d'impact précède la lecture.

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

Chaque date d’association est enregistrée en UTC (« 2026-10-08T07:15:00.0000000Z ») et affichée en heure locale. Une ancienne date « 2026-10-08 09:15:00 » est lue comme une heure locale ; elle prend la forme UTC quand l'association est actualisée par une nouvelle observation ou restaurée. Les autres lignes gardent leur texte : le stockage ne réécrit pas toutes les lignes d'un coup (64 modifications au plus par enregistrement).

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

![Fenêtre de connexion : Compte Windows, Mot de passe, Se souvenir de mon identifiant, Se connecter et Continuer en tant que …](fig:connexion)

- En session Windows de domaine, l'action principale est « Continuer en tant que DOMAINE\nom » (bouton par défaut, Entrée) et le formulaire est replié sous « Utiliser un autre compte ». Ailleurs, ou après « Changer de compte » dans la page « Comptes », le formulaire s'affiche d'abord et la session Windows reste proposée dessous.

- Le champ « Compte Windows » accepte DOMAINE\identifiant, identifiant@domaine ou le format habituel. Un identifiant nu est complété par Conf.NETBIOS ou Conf.DOMAINE s'ils sont renseignés.
- Un compte ordinateur est refusé comme identité interactive.
- « Afficher », à droite du mot de passe, le montre pendant 5 secondes dans une zone en lecture seule, sans copie possible ; il se masque aussi au second clic ou dès que la saisie change.
- « Se souvenir de mon identifiant », décochée par défaut, garde l'identifiant dans HKCU:\Software\DOMENIA (valeurs RememberLogin et LastLogin) après une connexion réussie. Le mot de passe n'est jamais mémorisé par cette case.
- « Continuer en tant que DOMAINE\nom » s'appuie sur la session Windows courante, sans mot de passe. Il n'apparaît que si Auth.AllowWindowsSession est vrai (défaut) ; hors session de domaine (SYSTEM, compte local ou compte d'ordinateur), il devient « Utiliser mon compte Windows », grisé.
- Découverte : avec Conf.AutoDiscover vrai (défaut), domaine et contrôleur sont découverts ; avec faux, Conf.DOMAINE, Conf.NETBIOS, Conf.SearchBase et Conf.Server s'appliquent.
- Délais : Auth.LoginTimeoutSeconds (30 s, borné de 8 à 45), Auth.PerServerTimeoutSeconds (6 s par contrôleur), Auth.MaxServerCandidates (4 contrôleurs essayés).

Chaque refus s'affiche en une phrase suivie de l'action à mener. Le code Active Directory (52e, 775, 0x80070775…) ne s'affiche pas : il figure dans le texte de « Copier le diagnostic » et dans le journal de connexion.

| Vous voyez | Ce que cela veut dire | Code AD dans le diagnostic |
|---|---|---|
| « Identifiant ou mot de passe refusé. Vérifiez la saisie avant un nouvel essai. » | Refus d'authentification. | 52e, 0x8007052E |
| « Compte inconnu de lʼannuaire. … » | Identifiant ou domaine erroné. | 525 |
| « Compte verrouillé. Demandez son déverrouillage puis réessayez. » | Compte verrouillé dans AD. | 775, 0x80070775 |
| « Compte désactivé. Demandez sa réactivation puis réessayez. » | Compte désactivé. | 533 |
| « Mot de passe expiré. Changez-le (Ctrl+Alt+Suppr, Modifier un mot de passe) puis réessayez. » | Mot de passe expiré. | 532 |
| « Mot de passe à changer avant la connexion. … » | Changement imposé à la prochaine ouverture de session. | 773 |
| « Connexion refusée par une restriction du compte. … » | Le plus souvent un mot de passe expiré ; sinon postes ou horaires autorisés. | 52f |
| « Connexion interdite à cette heure pour ce compte. … » ou « Connexion interdite depuis ce poste pour ce compte. … » | Horaires ou postes autorisés du compte. | 530, 531 |
| « Compte expiré. … » | Date d'expiration du compte dépassée. | 701 |
| « Accès refusé par lʼannuaire pendant la connexion. … » | Droits ou restrictions du compte pendant la lecture du domaine. | 0x80070005 |
| « Contrôleur de domaine injoignable. … » ou « Délai dépassé pendant la connexion. … » | Réseau, DNS ou VPN. | — |
| « Erreur interne pendant la connexion. Elle ne prouve pas un mauvais mot de passe. … » | Défaut de Domenia. | — |

Les boutons « Ouvrir le journal » et « Copier le diagnostic » de la fenêtre donnent la trace de connexion (chapitre 20).

## Les trois identités

La page « Comptes : identités de connexion » s'ouvre par le menu « Comptes » ou par la carte « Identités de connexion » de l'accueil. Elle applique la règle affichée sous « Règle dʼexécution » : « Annuaire : compte de connexion. Postes : compte poste saisi dans Assistance poste sʼil existe, sinon compte Postes, sinon compte de connexion. Secrets : compte Secrets sʼil existe, sinon compte de connexion. Les trois ressources sont indépendantes. ».

| Zone | Usage | Boutons |
|---|---|---|
| « ANNUAIRE AD » | Utilisateurs, groupes, OU, attributs, recherche et écritures AD. Carte en lecture seule : compte réellement lié, mode de connexion (session Windows ou compte saisi), contrôleur et domaine. | « Changer de compte » : connexion préremplie avec le compte saisi pour la session, formulaire d'abord ; « Annuler » garde la session en cours. Rien n'est écrit dans les préférences. |
| « EN CE MOMENT » | Compte réellement utilisé par chaque ressource (annuaire, postes, LAPS, BitLocker) et son origine, puis les comptes gardés en mémoire avec leur durée restante. Aucun mot de passe n'est affiché. | « Oublier » sur chaque compte gardé en mémoire. |
| « POSTES / WMI / DISTANT » | WMI, WinRM, SMB, inventaire, diagnostics et actions distantes. | « Activer », « Essayer sur le poste sélectionné », « Effacer ». |
| « SECRETS AD » | Lecture LAPS et BitLocker. | « Tester », « Activer », « Effacer ». |

- Le compte poste saisi dans le panneau « Compte poste » d'Assistance poste passe avant le compte « POSTES / WMI / DISTANT » (chapitre 5).
- « Essayer sur le poste sélectionné », grisé sans poste ouvert dans Assistance poste, fait au clic une seule lecture WMI légère (Win32_OperatingSystem) du poste ouvert avec le compte utilisé pour les postes. Réponses : « Accès administrateur OK sur … », « Accès refusé sur … : droit administrateur requis sur ce poste. », « Identifiants refusés par … », « Poste … injoignable (réseau, nom ou service WMI) ». Aucun relevé, aucun autre poste, aucun repli intrusif.
- Un compte temporaire accepté après un refus passe avant, pour sa seule ressource et son poste. Il est oublié après Security.AlternateCredentialIdleMinutes (30 min) sans usage, à la fin de la session, par la fenêtre du bouton d'accès ou par « Oublier » dans « En ce moment ». « Oublier » est refusé tant qu'une écriture reste active ou à vérifier ; une opération déjà envoyée garde sa copie du compte.
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

# 14 Lecture seule démonstration et protection des écritures

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

## Protection des écritures

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

## Reçus et non rejeu

Chaque écriture laisse un reçu dans %LOCALAPPDATA%\Domenia\Receipts. Une écriture n'est jamais rejouée automatiquement. Après un résultat incertain, Domenia affiche : « Une operation precedente reste a verifier. Consultez les recus, pas une relance automatique. ». Relisez l'objet dans AD avant toute nouvelle action. Les reçus se consultent dans l'onglet « Fiabilité » (chapitre 18).

## Démonstration pour la formation

La démonstration montre l'interface sans aucune connexion AD, avec des données fictives. Elle sert à la formation, jamais au service.

- Elle s'active seulement si Auth.DemoProvider vaut le booléen JSON true dans wad\Domenia.config.json. Le choix est fait une fois par session.
- Le bandeau affiche « DÉMONSTRATION — aucune connexion AD » ; l'identité est Demo.Identity (DEMO\demo.operateur par défaut) dans un domaine fictif.
- La connexion se fait par « Entrer en démonstration », sans mot de passe. La lecture seule est verrouillée ; les relevés distants, la mesure et la purge du stockage sont désactivés.
- Demo.LatencyMs (0) ajoute un délai simulé aux réponses.

## Fenêtre de connexion Debug

Le mode Debug est la fenêtre de connexion standard à laquelle s'ajoute, sous le formulaire, le volet « Diagnostic de connexion » : l'étape en cours et la trace technique, en direct (titre « Domenia · Connexion · diagnostic »). Le reste de la fenêtre est identique ; la trace est celle que copie « Copier le diagnostic ». Domenia choisit le mode dans cet ordre :

1. **Marqueur.** Un fichier wad\Domenia.login.debug présent impose Debug.
2. **Fichier de mode.** wad\Domenia.login-mode.cfg contient Standard ou Debug.
3. **Configuration.** Auth.LoginWindowMode de Domenia.config.json (Standard par défaut).

> [!ATTENTION] Avant la mise en service : Auth.DemoProvider absent ou faux, Domenia.login-mode.cfg à Standard, aucun fichier Domenia.login.debug. La construction des paquets refuse déjà une configuration qui active la démonstration, mais un fichier conservé sur un poste peut l'avoir réactivée.

# 15 Architecture

Domenia est une application Windows PowerShell 5.1 et WPF, lancée par un exécutable natif. Chaque démarrage vérifie l'empreinte de tous les composants, charge une liste fermée de modules et n'admet en arrière-plan que 71 opérations dont le code est épinglé. Un composant modifié, ajouté ou manquant arrête le démarrage.

| Couche | Rôle |
|---|---|
| Domenia.exe | Lanceur natif : contrôle le verrou de cycle de vie et le marqueur de mise à jour, puis démarre Windows PowerShell 5.1 x64 en STA. |
| wad\Domenia-Start.ps1 | Contrôle du manifeste : empreinte SHA-256 de chaque fichier runtime, composants obligatoires, dossiers redirigés. |
| wad\Domenia-Modules.ps1 | Chargeur fermé : liste exacte des modules et de leurs fonctions. |
| wad\Domenia-Core.ps1 | Cœur : configuration, base locale, fenêtre de connexion, fenêtre principale (XAML) et moteur des tâches. |
| wad\modules | Règles pures (Model), interface (UI), code d'arrière-plan (Worker), types C#, vues XAML. |
| Workers | Opérations exécutées hors du fil de l'interface, chacune épinglée par SHA-256. |

## Lanceur de Domenia

Le lanceur n'accepte que trois formes : sans argument (lancement normal, console cachée), --check (contrôle sans démarrage) et --diagnostic (console visible). Il lance powershell.exe du système avec -NoLogo -NoProfile -STA, sans -ExecutionPolicy : la stratégie d'exécution de la machine s'applique. Ses refus s'affichent dans la fenêtre « DOMENIA | Demarrage ».

| Code | Message | Cause |
|---|---|---|
| 2 | « Chemin du lanceur introuvable ou trop long. », « Dossier du lanceur introuvable. », « Chemin trop long. » ou « Chemin de verrou trop long. » | Dossier d'installation introuvable ou chemin trop long. |
| 3 | « wad\Domenia-Start.ps1 est absent. Extraire tout le dossier prod ou dev. » | Paquet incomplet. |
| 4 | « Windows PowerShell introuvable. » ou « Windows PowerShell 5.1 x64 est requis. » | PowerShell absent. |
| 5 | « Arguments acceptes : --check ou --diagnostic. Le lancement normal ne prend aucun argument. » | Argument inconnu. |
| 6 | « Commande trop longue. » | Chemin d'installation trop long. |
| 7 | « Paquet absent, mise a jour en cours ou dossier inaccessible. Ne pas supprimer les verrous. Utiliser l installateur DEV. » | Verrou wad\Support\.lifecycle.lock inaccessible. L’installateur visé par ce message est wad\Support\INSTALLER-MISE-A-JOUR.ps1, livré dans PROD et DEV. |
| 8 | « Une installation interrompue doit etre restauree ou terminee avant de lancer Domenia. » | Marqueur wad\Support\.update.pending présent. |
| Autre | « Windows a refuse le lancement. Conserver les politiques de securite et faire verifier le paquet. » | Windows a refusé de démarrer powershell.exe ; le code de sortie est l'erreur Windows. N'assouplissez pas les stratégies : faites vérifier le paquet. |

Après un arrêt sur erreur en lancement normal, une fenêtre « DOMENIA » affiche : « DOMENIA s'est arrete sur une erreur. Lancer Domenia.exe --diagnostic pour la voir. Les journaux restent sous wad\data\Logs ou le dossier utilisateur. ».

## Contrôle au démarrage

Domenia-Start.ps1 exige Windows PowerShell 5.1 Desktop, 64 bits, en STA. Il lit wad\package-manifest.json (fichiers runtime de la livraison, avec un plafond RuntimeFileLimit de 250) et recalcule l'empreinte SHA-256 de chaque fichier à chaque démarrage. Les fichiers conservés (configuration et préférences du dossier wad) ne sont pas comparés.

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

Domenia-Modules.ps1 déclare les modules autorisés et la liste exacte de leurs fonctions. Un script ajouté dans wad\modules n'est jamais chargé. Au démarrage, le chargeur vérifie l'existence et la syntaxe de chaque fichier, charge les bibliothèques C# épinglées et les types déclarés, contrôle le plan (phases, dépendances, cycles, doublons), importe les modules dans l'ordre, puis vérifie que chaque fonction existe et vient du bon fichier.

| Code d'erreur | Sens |
|---|---|
| DOMENIA_MODULE_MISSING | Fichier de module absent ; réinstaller le paquet complet. |
| DOMENIA_MODULE_PARSE | Erreur de syntaxe dans un module. |
| DOMENIA_MODULE_TYPES | Échec de compilation des types C#. |
| DOMENIA_MODULE_IMPORT | Échec d'import d'un module. |
| DOMENIA_MODULE_PLAN | Plan de chargement incohérent. |
| DOMENIA_MODULE_EXPORT | Fonction déclarée introuvable. |
| DOMENIA_MODULE_ORIGIN | Fonction venue d'un autre fichier que prévu. |

Domenia.Native porte les projections et les agrégations adaptées au parc. M4D.Admin.Common.Query fournit le moteur commun de filtres typés. Ces deux bibliothèques sont chargées depuis le paquet ; leurs empreintes sont épinglées dans le registre des modules.

Organisation : un domaine fonctionnel donne un fichier Model (règles pures, sans WPF, réseau ni disque), un fichier UI et un fichier Worker. Les parcours métier restent dans la fenêtre principale : composants dans la page, jamais de nouvelle fenêtre.

## Workers épinglés et registre des 71 opérations

Tout travail d'arrière-plan passe par un seul point d'entrée, Start-UiTask. Il n'admet que les opérations du registre fermé, chacune avec l'empreinte SHA-256 de son code exact.

1. **Au démarrage.** Chaque fichier runtime est comparé au manifeste.
2. **À l'initialisation du moteur.** L'empreinte de la table entière est recalculée. Un écart donne « Registre worker non conforme » et demande de réinstaller un paquet cohérent.
3. **Avant chaque tâche.** Le code de l'opération est recontrôlé : « Operation worker non autorisee : » ou « Integrite worker refusee pour » suivi de l'opération.

Les opérations admises sont déclarées dans tools\operation-contracts.json. Le registre couvre 71 opérations et se reconstruit avec les outils de développement.

Limites du moteur : Async.MaxThreads (6 threads), Async.MaxOutstandingWorkers (12 tâches en cours), file d'attente Async.MaxQueued (32, dont 2 places réservées aux actions de premier plan), attente maximale de 120 s. Les écritures passent par un canal dédié. Si Async.Enabled est faux, aucune tâche ne part : « Moteur multithread desactive dans la configuration. ».

> [!ATTENTION] Une modification d'un worker se fait seulement en développement : relecture, puis python tools/update_worker_contracts.py --apply, puis python tools/build_packages.py pour régénérer les manifestes. L'application n'appelle jamais cet outil ; il ne sert pas à faire accepter un paquet téléchargé douteux.

# 16 Installation et mise à jour

Domenia s'installe dans un dossier local, par extraction du ZIP ou par l'installateur. L'installateur est livré dans les deux paquets (wad\Support\INSTALLER-MISE-A-JOUR.ps1) : il contrôle tout avant de copier, garde l'ancien code et sait le restaurer. Il ne lance aucune suite de tests sur le poste. Les données et les préférences ne sont jamais touchées.

## Prérequis

- Windows PowerShell 5.1 Desktop, processus 64 bits, thread STA, et WPF.
- .NET Framework 4.7.2 ou version compatible plus récente, et winsqlite3.dll fourni par Windows pour la base locale.
- Module Active Directory des outils RSAT, ou les deux DLL Microsoft livrées dans wad ; à défaut, Domenia lit l'annuaire en LDAP.
- Un dossier local, sans jonction ni lien symbolique sur lui ou ses parents.
- Les ports du chapitre 5 ouverts entre le poste d'administration, les contrôleurs et les postes.

La compatibilité doit être vérifiée sur les versions de Windows, les stratégies PowerShell et les outils RSAT réellement utilisés dans le parc. Un contrôle de syntaxe sur un autre système ne remplace pas cette validation.

## Paquets PROD et DEV

| Paquet | Contenu |
|---|---|
| Pack PROD | Domenia.exe et le dossier wad, installateur compris dans wad\Support. Runtime à distribuer. |
| Pack DEV | Le même runtime, plus les sources, les outils de reconstruction, les tests et la documentation. |

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
7. **Nettoyage.** La copie préparée est supprimée. Les cinq dernières sauvegardes complètes sont gardées ; les plus anciennes, et les copies prepared restantes dans les sauvegardes gardées, sont retirées. Une sauvegarde d'installation inachevée n'est jamais touchée.

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

## Reconstruire un pack PROD

Le pack DEV contient FABRIQUER_PROD.cmd et tools\Fabriquer-Prod.ps1. Ils construisent un dossier PROD normal à partir d'un dossier wad complet. Le résultat contient Domenia.exe et le dossier wad avec ses fichiers runtime et ses manifestes. Le lanceur est repris du pack DEV ; le script ne télécharge rien et ne lance pas l’application. Le parcours FABRIQUER_PROD fonctionne sous Windows PowerShell 5.1 et ne demande ni Python ni Roslyn. Il ne compile pas : les DLL du dossier wad doivent déjà être prêtes.

1. **Conserver une source complète.** Gardez le pack DEV et modifiez votre copie du dossier wad. N'ajoutez jamais des données réelles, des mots de passe, la base ou les journaux au contenu à distribuer.
2. **Construire.** Lancez FABRIQUER_PROD.cmd pour le parcours prévu, ou appelez le script avec les chemins explicites ci-dessous.
3. **Choisir une sortie neuve.** Le dossier de destination doit être absent et situé hors du dossier DEV et des sources wad. Une installation utilisée n'est pas une destination de construction.
4. **Lire le bilan.** Le script prépare les contrats et empreintes dans une copie de travail. Un échec laisse la source disponible pour correction.
5. **Contrôler la livraison.** Vérifiez le manifeste, puis testez les parcours concernés sur Windows avant de distribuer. La réussite de la construction ne prouve ni les droits AD ni les transports du parc.

~~~
powershell -NoProfile -File .\tools\Fabriquer-Prod.ps1 `
  -SourceWad 'C:\Sources\Domenia\wad' `
  -OutputDirectory 'C:\Livraisons\Domenia-prod'
~~~

Si vous modifiez les sources C#, reconstruisez d’abord les DLL avec tools\build_native.ps1. Cette étape utilise PowerShell 7.4 ou plus récent avec son compilateur Roslyn, ou un dossier Roslyn compatible fourni explicitement par -CompilerDirectory sous PowerShell 5.1. Les références ciblent .NET Framework 4.7.2. Reprenez ensuite le parcours FABRIQUER_PROD.

L'identité de livraison est déclarée dans tools\release-contract.json. Chaque livraison à installer doit avoir son propre Build : l'installateur refuse un Build déjà actif. La version destinée aux utilisateurs reste Domenia 1.0.

Pour la construction de référence du dépôt, tools\release_contract.py et tools\build_packages.py contrôlent le contrat et produisent les ZIP DEV et PROD. La configuration de démonstration est refusée dans une livraison destinée à l'exploitation.

# 17 Réglages et configuration

La configuration de l'application tient dans wad\Domenia.config.json ; les choix de chaque utilisateur vont dans ses préférences. Toute section connue est complétée clé par clé avec les valeurs par défaut du code. Seules les clés listées ici ont un effet.

## Fichiers

| Fichier | Rôle |
|---|---|
| wad\Domenia.config.json | Configuration de l'application, lue au démarrage ; conservée par l'installateur. |
| DOSSIER_DONNEES\Preferences\Domenia.settings.json | Préférences de l'utilisateur, avec une copie .bak ; écriture atomique différée de 1,5 s. |
| wad\Domenia.login-mode.cfg | Mode de la fenêtre de connexion : Standard ou Debug. |
| wad\Domenia.theme.cfg | Thème Light ou Dark, lu seulement sans choix valide dans les préférences. |
| wad\Domenia.ui-profile.cfg | Profil de repli (Tech ou Admin), lu seulement sans choix valide dans les préférences. |
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
| Auth.RememberLogin | false | État initial de « Se souvenir de mon identifiant ». Valeur du fichier remplacée par RememberLogin de HKCU:\Software\DOMENIA dès que celle-ci existe. |
| Auth.LastLogin | vide | Identifiant proposé à l'ouverture. Valeur du fichier remplacée par LastLogin de HKCU:\Software\DOMENIA dès que celle-ci existe. |
| Auth.LoginWindowMode | Standard | Mode de la fenêtre de connexion. |
| Auth.AllowWindowsSession | true | Propose la session Windows : « Continuer en tant que DOMAINE\nom » en action principale dans une session de domaine. |
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

## Recherche liste et interface

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
| Browser.SearchPageSize | 250 | Objets par page de recherche LDAP (100 à 1 000). |
| Browser.SearchServerTimeLimitSeconds, SearchClientTimeoutSeconds | 60, 90 | LDAP : serveur de 60 à 300 s ; client ≥ serveur + 30 s, jusqu’à 600 s. |
| UI.TreeRenderBatchSize, TreeRenderIntervalMs | 16, 20 | Affichage progressif de l'arbre. |
| UI.AllowExpertProfile | true | false masque le profil Expert du pied du menu ; Ctrl+L reste sur le journal de session. |
| Startup.ShowMonitor | true | Fenêtre « Domenia 1.0  Initialisation » pendant le chargement. |
| SelfCheck.FullBenchmarkIterations | 3 | Répétitions de la vérification complète. |

## Moteur et cache

Pour la recherche globale, seuls les nouveaux objets reçus d’AD relancent le délai d’inactivité ; les lignes du cache et leur affichage ne comptent pas. Le plafond total reste fixe et la file d’attente est exclue. La taille de page LDAP ne change ni le périmètre ni la limite de résultats.

| Clé | Défaut | Rôle |
|---|---|---|
| Async.Enabled | true | Moteur des tâches ; à false, aucune tâche ne part. |
| Async.MaxThreads | 6 | Threads du moteur. |
| Async.MaxOutstandingWorkers | 12 | Tâches en cours au plus. |
| Async.MaxQueued, ReservedForeground, MaxQueueWaitSeconds | 32, 2, 120 | File d'attente, places de premier plan, attente maximale. |
| Async.PollIntervalMs, UiRefreshIntervalMs | 250, 500 | Rythme de suivi des tâches. |
| Async.DefaultTimeoutSeconds | 60 | Délai par défaut d'une tâche. |
| Async.SearchTimeoutSeconds, SearchMaxDurationSeconds | 120, 900 | Recherche globale : inactivité AD de 120 à 600 s (plancher automatique) ; durée totale ≥ inactivité, jusqu’à 3 600 s, hors attente. |
| Async.ObjectTimeoutSeconds, TreeTimeoutSeconds | 35, 30 | Délais des fiches et de l’arbre. |
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
| Index.MaxObjects, BudgetMs, ComputerFirst | 0, 1200000, true | 0 désactive le quota d’objets de l’index ; le budget par passe reste de 20 minutes. Une limite positive ou un budget atteint rend la passe partielle : elle ne remplace pas une base complète et ne déplace pas le repère de suivi. La lecture est acheminée vers SQLite par lots de 256 objets. |

## Clés sans effet

Ces clés figurent dans les valeurs par défaut ou dans le fichier livré, mais aucun code ne les lit. Ne les présentez pas comme réglables : Conf.UsersBase, Conf.ComputersBase, Auth.DetailedLoginTrace, Features.ScopedLocks, Features.ColumnProfiles, Features.WakeOnLan, Features.LocalAssistant, Features.ReadTrace, Browser.IncludeContainers, Browser.DefaultObjectFilter, Browser.DefaultScope, Dashboard.Enabled, UI.WindowWidth, UI.ReadOnlyDefault, Async.MinThreads, Security.MaskSecretsByDefault, Security.NeverLogSecretValues, Remote.AllowRemoteArtifacts, UserMachineLink.AutoProbeOnComputerSelect, Index.FullRebuildDays, LocalStore.KeepBackup et Streaming.AutoDetectLoggedUser, entre autres : 61 clés des valeurs par défaut, plus cette dernière clé du fichier livré.

## Préférences personnelles

Les préférences ci-dessous sont conservées au redémarrage ; la lecture seule n’en fait volontairement pas partie.

| Domaine | Clés |
|---|---|
| Recherche | SavedSearches, OuBookmarksJson, PresenceFilter, SearchType, SearchLimit (100), GridLayoutsJson |
| Interface | Theme (Light), UiProfile (Tech), Workspace, UxDensity (Confort), UxNavCollapsed, UxHelpVisible, UxHelpCompactOpen, UxLogCollapsed, UxLogExpandedHeight, UxLogWrap, UxLogFontSize, Ui.ZoomPercent (100) |
| Fenêtre | WindowWidth, WindowHeight, WindowLeft, WindowTop, WindowMaximized, TreeWidth, LogHeight |
| Tableaux de bord | Dashboard.Computer.Layout, Dashboard.Fleet.Layout, Dashboard.Software.Layout, Widgets.Computer, Widgets.Fleet. Le périmètre du parc et celui de la Base autonome sont indépendants de Rechercher. |
| Comptes | RemoteCredentialUser, SecretsCredentialUser : noms des comptes « POSTES / WMI / DISTANT » et « SECRETS AD », jamais de mot de passe. |
| Poste | InventoryScope, SoftwareScope, SoftwarePerUser, SoftwareStore, SoftwareUpdates, WmiLimit (25) |
| Parc | IndexAutoBuild, ParkSweepEnabled, ParkHarvestEnabled, Collection.Concurrency (4), Collection.CacheMinutes (15) |
| Requêtes | Query.Library : recettes personnelles sauvegardées, dans la limite de 100 recettes et 1 Mio ; modèles livrés distincts. Search.QueryFavorites : jusqu’à 200 favoris de la barre Requêtes. |

Le zoom reste accessible en bas de la fenêtre : − et + règlent l’interface de 80 à 150 %, par pas de 10. Le bouton affichant le pourcentage rétablit 100 %. Le réglage est conservé dans les préférences personnelles. La disposition utilise la place disponible après application du zoom : menu, aide et espacements se compactent lorsque cette place diminue. Les barres de défilement gardent accessibles les zones qui dépassent les dimensions minimales.

# 18 Base autonome

La base autonome est une copie locale des utilisateurs et des postes, suivie par GUID, avec les associations utilisateur et poste et les derniers relevés. Elle alimente la vue du parc et les recherches locales, sans requête AD. Les associations et les relevés n'existent que là : sauvegardez la base.


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

Dans l’onglet « Stockage », dépliez « Emplacement et sauvegarde » pour afficher le chemin exact et les commandes de sauvegarde. « Ouvrir l emplacement » ouvre l’Explorateur sur le fichier.

## Mettre à jour la base

La même lecture AD peut être lancée avec « Base locale » depuis Accueil ou Rechercher pour l’OU annoncée sur cet écran. Elle ne relève ni le ping ni WMI. Dans Base autonome, le choix d’OU, placé au-dessus des onglets, règle « Mise à jour » et « Données ». « Stockage » agit sur la base locale entière : les sauvegardes et purges ne sont pas limitées à cette OU. Utilisez « Choisir une OU », puis « Mettre à jour lʼOU choisie » dans l’onglet « Mise à jour ». Une unité organisationnelle doit être choisie ; ses sous-OU sont incluses. La cible est propre à cet outil et ne modifie pas Rechercher. Relisez le chemin affiché avant de lancer une opération.

| Onglet | Usage |
|---|---|
| Mise à jour | Relire l’OU choisie, suivre la progression et la fraîcheur de la copie locale. |
| Données | Chercher et parcourir les objets enregistrés dans le périmètre choisi, ouvrir leur fiche ou exporter la page. |
| Stockage | Afficher l’emplacement, sauvegarder ou mesurer toute la base, puis préparer une purge par catégories sur cette base. |

![Mise à jour de la base : OU choisie et commande de relecture ciblée ; données fictives](fig:base-commandes)

La mise à jour n’est jamais automatique. Si la base est plus ancienne que Index.StartupDeltaMaxAgeMinutes, Domenia écrit seulement une recommandation dans le journal. Pour recenser plusieurs branches, choisissez et mettez à jour leurs OU successivement.

![Base autonome : onglet Données et navigateur local ; données fictives](fig:base-autonome)

Dans « Mise à jour », dépliez « Détails du stockage et de la synchronisation » pour relire le fichier local, le contrôleur et le repère de suivi.

| Information de la base locale | Ce qu’il faut vérifier |
|---|---|
| Nombre d’objets | Utilisateurs et postes recensés dans le périmètre annoncé, y compris les comptes désactivés. |
| Lecture complète AD | Date d’une lecture réussie couvrant l’OU et ses sous-OU. Une date d’OU parente peut couvrir ce périmètre. |
| Tentative incomplète | L’avertissement reste distinct de la dernière date complète. Relisez le bilan avant de relancer. |
| Détails du stockage | Fichier local et contrôleur utilisés ; ces repères ne décrivent pas l’âge des mesures des postes. |

## Suivre la progression et la fraîcheur

L’onglet « Mise à jour » regroupe la commande, « État de la copie locale », les dates et la progression. L’onglet « Données » réserve la place aux résultats, avec ses filtres et boutons de pagination. Les sauvegardes et la maintenance sont accessibles dans « Stockage ».

La lecture de l’annuaire et l’enregistrement dans SQLite sont deux phases distinctes. Les compteurs affichent les objets lus, les lots écrits et les éventuels refus ou délais dépassés. La fraîcheur AD du périmètre repose sur sa dernière lecture complète ou celle d’une OU parente qui le couvre ; le chemin couvert reste indiqué. Une tentative partielle ne remplace pas cette date et demeure signalée. Attendez la confirmation finale du stockage avant de considérer la base à jour. Cette date ne décrit ni le ping ni WMI ; « Les deux » attend précisément ce stockage avant de préparer le relevé des postes.

La lecture est transférée dans un flux local contrôlé, puis intégrée par transactions de 256 objets. Les objets sont suivis par GUID : un renommage ou un déplacement conserve l’identité. Une lecture complète d’OU rapproche les absences uniquement dans son sous-arbre ; les autres OU restent intactes. Si la lecture ou le recensement est partiel, les objets effectivement lus sont fusionnés, mais aucun absent n’est retiré et ni le repère ni la date complète ne progressent. Les fiches et mesures enregistrées plus récemment pendant la lecture sont préservées lors de la fusion. Ces retraits concernent l’index local : ils ne suppriment rien dans AD, ni les associations manuelles ou les relevés conservés.

L’onglet « Données » utilise l’OU choisie en haut de l’outil, un filtre et des pages de 200 objets. « Afficher / actualiser les objets » recharge sa liste. Une recherche vide parcourt le périmètre complet. Vérifiez le total d’utilisateurs et de postes, les comptes actifs ou désactivés et les filtres avant d’interpréter l’absence d’une ligne.

Un clic sur un en-tête trie tous les résultats du périmètre filtré avant la pagination ; un second clic inverse le sens. « Tri par pertinence » revient au classement initial. Les colonnes « Connexion AD » et « Modifié dans AD » suivent l’ordre chronologique, avec les dates inconnues en fin de liste. La colonne Association, calculée à l’affichage, ne se trie pas.

| Phase affichée | Ce qui se passe |
|---|---|
| Lecture AD | Les objets arrivent depuis l’annuaire ; le total définitif peut être encore inconnu. |
| Enregistrement local | Les lots sont écrits dans la base. Recevoir un objet ne prouve pas encore son stockage. |
| Terminé | Le bilan confirme les écritures. Avec Les deux, le relevé des postes peut ensuite être préparé. |
| Partiel, interrompu ou erreur | La phase suivante ne démarre pas. Les données déjà enregistrées sont conservées. |

## Limites des caches et de la base

| Stockage | Limite | Conséquence |
|---|---|---|
| Index SQLite des objets | Pas de quota d'objets avec Index.MaxObjects à 0 | Capacité déterminée par l'espace disque, les temps de traitement et le budget de lecture. Ce n'est pas une mémoire infinie. |
| Cache des recherches en mémoire | 20 requêtes et 20 000 lignes cumulées | Les instantanés anciens sont évincés ; la liste courante et l’index ne sont pas tronqués par cette éviction. |
| Recherches persistées | 20 instantanés par périmètre ; 20 000 lignes et 32 Mio par instantané | Ce plafond porte sur chaque instantané JSON, pas sur la taille de toute la base. |
| Cache des observations courtes | 20 000 entrées par périmètre | Conserve un ensemble borné de dernières observations. |
| Identité AD de la console observée | Moins de 5 minutes après sa vérification | Date indépendante du ping ; relecture si le compte change, manque dans la base ou si la relecture est forcée. |
| Rétention des caches persistés | 30 jours | Une entrée hors délai ne constitue pas une mesure actuelle. |
| Recettes personnelles de l'Atelier | 100 recettes, 1 Mio | Les conditions sont conservées, sans recopier tous les résultats. |
| Sélection figée d'alerte | 20 000 GUID | Le détail est paginé ; la sélection reste explicite et bornée au périmètre. |

Le panneau de cache affiche notamment les entrées fraîches ou expirées, le délai de validité, la réutilisation, les évictions et les erreurs. Ce cache de navigation est distinct de la base du parc. Purger un cache n'est pas la même opération que supprimer une base ; conservez une sauvegarde des associations et observations utiles.

Pour un parc de 5 000 postes ou plus, gardez les listes paginées, commencez avec 4 collectes simultanées et surveillez le temps d'enregistrement. Une donnée absente reste affichée comme telle ; augmenter une limite de cache ne résout pas un refus distant.

## Sauvegarder

1. **Lancer.** Ouvrez « Stockage », dépliez « Emplacement et sauvegarde », puis cliquez « Sauvegarder maintenant ». La barre d'état affiche « Sauvegarde de la base en cours... ».
2. **Copie à chaud.** Le worker StorageBackup copie la base par l'API de sauvegarde SQLite. L'original reste ouvert en lecture seule et n'est pas modifié.
3. **Contrôle.** La copie est vérifiée (PRAGMA quick_check) dans le budget LocalStore.BackupTimeoutSeconds (30 s). Une copie partielle est supprimée.
4. **Rotation.** Le fichier va dans le dossier Backups de la base, nommé Domenia-DATE-HEURE-ID.db. Seules les LocalStore.DatabaseBackupCount (7) plus récentes sont gardées.

> [!RESULTAT] « Sauvegarde de la base enregistree : » suivi du chemin. Sous l'encadré : « Sauvegardes : » avec le dossier et la date de la dernière.

« Copier une sauvegarde vers... » fait la même sauvegarde puis la copie vers le fichier choisi (clé USB, partage), nom proposé Domenia-DATE-HEURE.db : « Sauvegarde de la base copiee : » suivi du chemin. La base active et ses journaux ne peuvent pas servir de destination. Un fichier temporaire précède le remplacement de l’export choisi pour préserver l’export existant si la copie échoue. Échec : « Sauvegarde de la base impossible : » suivi du motif.

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
6. **Rattraper.** Choisissez l’OU utilisée, puis « Mise à jour » et « Mettre à jour lʼOU choisie » pour relire ses objets AD. Répétez pour les autres branches suivies.

> [!ATTENTION] Validez cette procédure sur une copie avant de remplacer la base utilisée. Ne copiez jamais une sauvegarde à côté d'anciens fichiers -wal et -shm. Les associations et relevés postérieurs à la sauvegarde sont perdus ; les objets AD se relisent.

## Schéma et migrations

Le schéma de données est en version 11. Les migrations ne vont que vers l'avant ; une base plus récente, illisible ou ambiguë est refusée intacte. Avant une migration, une sauvegarde obligatoire est écrite dans Backups\migrations.

## Mesure et purge

Dans Outils → Base autonome → Stockage, « Mesurer » compte les lignes et le volume de la base, en lecture seule. Dans « Purge volontaire », choisissez les données reconstructibles à oublier dans toute la base, indépendamment de l’OU affichée : observations, instantanés de recherche, index local ou anciennes traces selon l’âge indiqué. « Simuler la purge » compte les lignes concernées ; « Purger… » demande ensuite confirmation de cette sélection.

La purge conserve toujours les associations et leurs traces protégées, les secrets, la configuration, les préférences, les journaux et les reçus. Elle ne compacte pas le fichier SQLite. Purger l’index impose une nouvelle mise à jour explicite des OU utiles pour retrouver leurs objets locaux.

Les reçus d’écriture et les autorisations d’intervention restent dans « Fiabilité », lorsque Domenia y conduit. Les opérations de stockage se consultent dans la Base autonome.

![Stockage : sauvegardes et préparation d’une purge locale ; données fictives](fig:base-stockage)

# 19 Règles de sécurité

Domenia lit par défaut, n'envoie rien sur le réseau sans geste explicite et ne garde aucun secret sur le disque. Son intégrité est contrôlée à chaque démarrage. Ces règles sont dans le code ; ne les contournez pas par la configuration.

| Règle | Comment Domenia l'applique |
|---|---|
| Lecture par défaut | Démarrage toujours en lecture seule ; passage en écriture confirmé et signalé en rouge (chapitre 14). |
| Aucune sonde sans geste | Pas de mise à jour de la base ni de relevé au démarrage. Un relevé exige un périmètre explicite et une confirmation du nombre de cibles ; il lit de 1 à 8 postes en parallèle selon le réglage. Dans l’Atelier, le périmètre est l’OU affichée avec ses sous-OU. |
| Pas de rejeu | Une écriture n'est jamais rejouée automatiquement ; les reçus servent à vérifier. |
| Secrets en mémoire | Mots de passe jamais enregistrés, effacés à la fermeture ; seul l'identifiant peut être mémorisé. Un mot de passe saisi est lu en SecureString et n'est jamais recopié dans un champ modifiable ; « Afficher » le montre 5 s en lecture seule. LAPS et BitLocker : une valeur à la fois, jamais journalisée ni mise en cache, presse-papiers vidé après 30 s. |
| Windows intact | Aucun certificat accepté à l'aveugle ; WinRM, pare-feu, antivirus et stratégies jamais modifiés. Le déblocage du paquet ne change aucune stratégie. |
| Transports intrusifs | ADMIN$, Planificateur et PsExec inactifs sans l'autorisation de 5 minutes pour le poste ; avec elle, ils servent aussi de repli à certaines lectures quand CIM échoue (chapitre 5). |
| Intégrité | Manifeste vérifié à chaque démarrage, chargeur fermé, registre des workers épinglé. |
| Données locales | Base obligatoirement locale ; dossier protégé en mode UserLocal ; dossiers redirigés refusés. |
| Journaux masqués | Mots de passe, jetons, en-têtes d'authentification et clés de récupération masqués avant écriture. |

> [!ATTENTION] Le manifeste n'est pas une signature. Domenia.exe et le runtime livrés ne sont pas signés. Pour une diffusion qui exige une signature : tools\Signer-Distribution.ps1 signe les scripts de la copie préparée (build_packages.py --stage-dir) avec un certificat de signature de code approuvé, puis, après la construction, le catalogue du manifeste livré (-ManifestCatalog). Domenia.exe et les composants tiers ne sont pas re-signés : tools\Test-DomeniaSignature.ps1 les accepte pour leur empreinte épinglée dans tools\release-contract.json. Ce contrôle est hors ligne et rend séparément l'intégrité et l'éditeur ; -RequireSignature exige les scripts signés et les binaires épinglés, -RequireSignedManifest exige aussi le catalogue signé, seul à couvrir les fichiers non signables (.json, .xaml, .cs, .cmd, .ico, verrou).

> [!NOTE] Données réelles. Les journaux, exports et diagnostics contiennent des noms de comptes, de postes, de domaines et des chemins internes : ils ne sont pas anonymisés. Relisez-les avant tout partage.

> [!NOTE] Limite de Windows PowerShell 5.1. L'API DirectoryEntry n'accepte le mot de passe que sous forme de chaîne. Au moment de chaque liaison à l'annuaire, Domenia en tire une copie depuis la SecureString et la remet aussitôt à Windows, sans la conserver, la journaliser ni l'afficher. Cette copie est immuable : aucune instruction ne peut l'effacer, elle disparaît quand le ramasse-miettes .NET libère la mémoire. Les variables vidées dans le code ne constituent donc pas un effacement.

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

## Dans les pages de Domenia

- « Journal de session », en bas de la fenêtre : événements et erreurs de la session ; « Copier » ne masque pas les noms internes.
- Accueil, « Détails de la session et outils de vérification », « Ouvrir le journal » : ouvre Domenia.log dans le Bloc-notes.
- Outils, onglet « Journal » (profil Expert) : journal détaillé de l'application.
- Outils, onglet « Charge & stats » : durée, volume réseau estimé, replis distants et taux de réussite des opérations.
- Outils, onglet « Domaine » : rôles FSMO, niveaux fonctionnels, contrôleurs et stratégie du domaine.

## Santé du moteur et réactivité de l’interface

Ouvrez le panneau « Opérations » depuis le bandeau, ou « État du moteur » depuis le Journal de session déplié. Il présente les opérations actives, en attente ou en nettoyage, la mémoire privée du processus et la dernière sauvegarde locale.

Deux mesures de session sont distinctes. « Réactivité de l’interface » indique le retard des impulsions du fil d’interface. « Traitement des résultats dans l’interface » indique la durée de traitement des retours de workers sur ce fil : médiane, seuil sous lequel se trouvent 95 % des mesures et maximum des mesures conservées. Cette seconde ligne apparaît lorsque des retours ont été mesurés.

![État du moteur : tâches, réactivité, durées des retours et sauvegarde locale ; valeurs de démonstration](fig:etat-moteur)

Ces valeurs décrivent l’activité locale de la session et ne sont pas une mesure du temps réseau ou une qualification de tout le parc. Un retour long peut signaler un rendu coûteux ; corrélez l’heure avec l’opération et le journal. Une interface momentanément disponible ne prouve pas qu’une écriture ou une sauvegarde est terminée. Le panneau se ferme avec son bouton ou Échap.

## Vérification de Domenia

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

# 21 Contrôles et qualification

Une construction réussie vérifie la cohérence des fichiers ; elle ne prouve pas le comportement de WPF, de Windows PowerShell 5.1 ou des accès du domaine. Validez les fonctions utilisées sur un poste Windows de test autorisé, avec des objets de test et les comptes représentatifs. Les opérations d'écriture demandent une vérification distincte de leurs délégations.

## Contrôles locaux

Les contrôles statiques vérifient la syntaxe, les contrats du chargeur, les workers et les empreintes. Les tests de règles et de base synthétique vérifient les filtres, la pagination, la persistance et les agrégations sans interroger de domaine réel.

~~~
python tools/release_contract.py --check
python tools/validate_powershell_static.py
python tools/audit_preload.py
python tools/update_worker_contracts.py
~~~

Les tests de charge utilisent des données synthétiques à 5 000 et 10 000 postes. Ils servent à détecter des omissions, des doublons et des coûts excessifs. Le temps réel dépend des contrôleurs, de SQLite, des droits distants et de la latence des postes ; ces mesures ne constituent pas un engagement de débit sur le parc.

## Suites du pack DEV

| Suite | Objet |
|---|---|
| Test-DomeniaRules.ps1 | Règles des modules et conversions, sans WPF ni réseau. |
| Test-DomeniaNative.ps1 | Projections C#, observations et agrégations des sondes. |
| Test-DomeniaQuery.ps1 | Recettes, types, conditions, sélections et sauvegarde. |
| Test-DomeniaIndexPersistence.ps1 | Enregistrement, identité des objets et préparation des collectes. |
| Test-DomeniaModules.ps1 | Plan de chargement et origine des fonctions. |
| Test-DomeniaBoards.ps1 | Widgets et raccordement de l'interface avec des données fictives. |
| Test-DomeniaGeometry.ps1 | Géométrie WPF, tailles d'écran et échelles. |
| Test-DomeniaParkDetection.ps1 | Collecte, détection et orchestration. |
| Test-DomeniaInstaller.ps1 | Mise à jour, restauration, verrouillage et interruptions. |
| Test-DomeniaFaults.ps1 | Réaction aux refus, lenteurs et défauts de stockage. |

Les suites qui chargent WPF ou les API Windows doivent être exécutées sous Windows. Conservez les rapports, l'identité exacte du code et les empreintes des paquets. Une suite inapplicable à la plateforme doit être signalée comme non exécutée, jamais comptée comme une réussite.

## Parcours à valider sur Windows

1. **Démarrer.** Contrôler le paquet puis ouvrir Domenia en lecture seule, sans modifier les stratégies de sécurité du poste.
2. **Comparer les objets.** Sur une OU connue, rapprocher le total de la base, les widgets et leur détail, y compris les comptes désactivés et les données absentes.
3. **Mettre à jour.** Vérifier une lecture complète, une mise à jour des changements et une interruption ; une passe partielle doit rester explicitement partielle.
4. **Collecter.** Vérifier succès, refus, délai dépassé et arrêt, avec le parallélisme adapté.
5. **Parcourir.** Tester les pages de résultats, les filtres, les recettes sauvegardées, les graphiques et l'ouverture des fiches.
6. **Maintenir.** Vérifier une sauvegarde, une restauration sur copie et une mise à jour du code avec retour arrière.
7. **Écrire si nécessaire.** Utiliser des objets de test pour les actions autorisées ; vérifier les confirmations, les reçus et l'état final dans l'annuaire.

## Qualification du paquet

La garde de livraison sépare l'intégrité et la qualification Windows. Le mode release_guard.py --require-windows exige un rapport Windows PowerShell 5.1 lié aux empreintes des ZIP. L'installateur peut exiger ce rapport avec -RequireQualification.

Un rapport doit décrire ce qui a été exécuté, la plateforme, les scénarios et leur résultat. Les contrôles locaux sur macOS, les analyses statiques et les bases synthétiques restent des preuves complémentaires ; ils ne constituent pas une qualification du logiciel sur Windows.

# 22 Maintenance et sources

Ce chapitre donne les sources utiles pour maintenir Domenia 1.0 et reconstruire un paquet cohérent.

## Sources du comportement

| Domaine | Fichiers |
|---|---|
| Lanceur | tools\launcher\launcher.c, Domenia.exe |
| Démarrage et chargeur | wad\Domenia-Start.ps1, wad\Domenia-Modules.ps1 |
| Cœur, fenêtres, configuration, workers du cœur | wad\Domenia-Core.ps1 |
| Tableaux de bord et widgets | modules Domenia-Boards.Model, Domenia-Widgets.UI, Domenia-BoardComputer.UI, Domenia-BoardFleet.Model, Domenia-BoardSoftware.Model, Domenia-Charts.UI, Domenia-Dashboard.UI |
| Requêtes WMI | module Domenia-Probes.Model |
| Atelier de requêtes | modules Domenia-Query.Model, Domenia-Query.UI, Domenia-Query.Worker, Domenia-QueryTargets.UI ; vue Domenia-Query.xaml ; moteur partagé vendor\m4d-admin-common\src\Query |
| Agrégations natives | native\ProbeAggregation.cs, native\ObservationReader.cs, tools\build_native.ps1 |
| Parc et relevés | modules Domenia-Park.UI, Domenia-Park.Model, Domenia-Live.UI, Domenia-Live.Model |
| Base autonome | module Domenia-Storage.UI et son worker |
| Comptes et transports | modules Domenia-Access.Model et Domenia-Access.UI |
| Livraison | tools\release-contract.json, tools\build_packages.py, wad\Support\INSTALLER-MISE-A-JOUR.ps1, tools\Test-DomeniaSignature.ps1, tools\operation-contracts.json |

## Règles de maintenance

- Cible unique : Windows PowerShell 5.1 x64 STA. Le garde-fou tools\Test-DomeniaPs51Compat.ps1 doit rester à zéro erreur.
- Scripts en UTF-8 avec BOM ; sans BOM, Windows PowerShell 5.1 casse les accents.
- Après une modification d’un fichier runtime, reconstruisez le PROD avec tools\Fabriquer-Prod.ps1, ou régénérez les paquets de référence avec tools\build_packages.py. Sans manifestes à jour, Domenia-Start.ps1 refuse le démarrage.
- Après une modification d'un worker, mettez à jour le registre (chapitre 15) et vérifiez les opérations concernées avec les suites du pack DEV.
- Chaque nouvelle livraison change le Build du contrat (chapitre 16).


## Documents du dépôt et du pack DEV

| Fichier | Contenu |
|---|---|
| LIRE-MOI.md | Démarrage, installation et repères du paquet. |
| tools\release-contract.json | Identité de la livraison et empreintes des composants épinglés. |
| tools\operation-contracts.json | Contrats des opérations exécutées en arrière-plan. |
| guides | Dans le dépôt source : sources des guides technicien et administrateur, au format Markdown et JSON. |
| engineering\d120 | Garde de livraison, suivi technique et outils de vérification. |

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
| Relevé | Lecture de plusieurs postes après confirmation, de 1 à 8 à la fois. |
| Widget | Tuile ou graphique d'un tableau de bord, modifiable, déplaçable et retirable. |
| Requête WMI prête à l'emploi | Lecture d'une classe WMI tirée du catalogue, ajoutée comme widget. |
| Score de santé | Note de 0 à 100 calculée sur les points d'attention. |
| Worker | Code exécuté en arrière-plan, hors du fil de l'interface. |
| Registre des opérations | Liste fermée des 71 opérations admises en arrière-plan, chacune épinglée par SHA-256. |
| Manifeste, empreinte | Liste des fichiers runtime avec leur SHA-256, contrôlée à chaque démarrage ; ce n'est pas une signature. |
| Chargeur fermé | Liste exacte des modules et de leurs fonctions ; un script ajouté n'est jamais chargé. |
| Paquet PROD, paquet DEV | PROD contient le runtime et l'installateur ; DEV ajoute les sources, les outils, les tests et la documentation. |
| Build | Identifiant unique d'une livraison ; l'installateur refuse un Build déjà actif. |
| Reçu | Trace locale d'une opération, utilisée pour vérifier sans rejouer. |
| LAPS | Mot de passe administrateur local géré par AD. |
| Profil Essentiel, Expert | Niveau de détail de l'interface ; aucun effet sur les droits. |
| Démonstration | Mode de formation sans AD, avec des données fictives ; désactivé en service. |
| Poste Windows de test autorisé | Machine réservée aux essais, avec des données et des objets de test. |
