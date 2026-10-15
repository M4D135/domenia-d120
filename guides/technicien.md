# 1 Trouver une personne ou un poste

Quand : avant toute intervention, vous devez retrouver un poste, un utilisateur ou un groupe du domaine.

## Ouvrir Domenia

1. **Lancer Domenia.** Double-cliquez sur Domenia.exe. La fenêtre « Connexion à Domenia » s'ouvre.
2. **Saisir le compte.** Dans « Compte Windows », tapez votre compte du domaine (DOMAINE\identifiant ou identifiant@domaine), puis le « Mot de passe ».
3. **Se connecter.** Cliquez sur « Se connecter » ou appuyez sur Entrée. Si votre session Windows est ouverte avec votre compte du domaine, cliquez plutôt sur « Utiliser mon compte Windows ».
4. **Attendre l'ouverture.** « Vérification du compte… » s'affiche, puis la fenêtre principale s'ouvre. Sous le titre de la page, le badge « Connecté à … » donne le nom du domaine ; le pied du menu rappelle le compte et le domaine utilisés.

![Fenêtre « Connexion à Domenia » : compte, mot de passe, « Se connecter » et « Utiliser mon compte Windows »](fig:connexion)

> [!NOTE] Cochez « Mémoriser uniquement l’identifiant » pour retrouver votre identifiant la fois suivante. Le mot de passe n'est jamais enregistré.

> [!RESULTAT] Domenia est ouvert avec l'interrupteur sur « Lecture seule » : vous consultez sans rien modifier.

## Rechercher dans tout le domaine

1. **Placer le curseur.** Cliquez dans la barre du haut « Personne, poste ou groupe, dans tout le domaine… », ou appuyez sur Ctrl+F. Vos dernières recherches et fiches s'affichent sous la barre ; pendant la frappe, des suggestions viennent de la base locale. La saisie seule n'interroge pas l'annuaire.
2. **Taper le nom.** Saisissez au moins deux caractères : nom, identifiant, adresse mail ou nom de poste. Appuyez sur Entrée ou cliquez sur « Rechercher ». La page « Rechercher » affiche la liste « Résultats ».
3. **Choisir où et quoi chercher.** Sous la barre, la puce « Partout » cherche dans tout le domaine ; « Dans « Postes » » limite la recherche à l’OU choisie dans l’arbre de Rechercher, sous-OU incluses. Les choix « Tout », « Personnes », « Postes » et « Groupes » restreignent le type. Le texte gris de la barre rappelle ces choix ; changer une puce ne lance rien avant Entrée.
4. **Lire la liste.** Le compteur indique les lignes visibles parmi les objets chargés, pas le total du domaine. La barre cherche les noms qui **commencent** par votre texte : si elle trouve peu de noms ou aucun, la puce « Chercher aussi les noms qui contiennent « compta » » apparaît sous le compteur. Un clic relance la même recherche (même périmètre, même type, même limite) sur les noms qui contiennent ce texte, par exemple « PC-COMPTA-014 » ; cette lecture est plus longue. « Liste partielle » signale une lecture incomplète : même 746/746 ne garantit pas que tout a été reçu.
5. **Affiner sans relancer.** Tapez quelques lettres dans « Filtrer la liste » : seules les lignes chargées qui les contiennent restent, aussi après une recherche globale, sans requête AD. « Effacer le filtre » réaffiche tout. Une nouvelle recherche repart avec un filtre vide.
6. **Choisir les colonnes.** La liste montre six colonnes : Type, Nom, Utilisateur connecté, Association mémorisée, Présence réseau et État. L’association affiche l’utilisateur ou les postes liés suivis de la qualification du lien (par exemple « Camille Martin · Observé ») ; son infobulle donne la source. Clic droit sur un en-tête de colonne, ou menu « ⋯ » puis « Colonnes… » : cochez ou décochez une colonne ; « Colonnes par défaut » revient aux six colonnes. Le choix est gardé d’une session à l’autre ; les colonnes propres aux postes n’apparaissent que si la liste contient un poste.
7. **Vérifier un poste.** Cliquez une fois sur la ligne d'un poste. Domenia le pingue et lit l'utilisateur ouvert sur son écran : « Présence réseau » et « Utilisateur connecté (console) » se mettent à jour.
8. **Ouvrir la fiche.** Double-cliquez sur la ligne, ou appuyez sur Entrée. La page « Fiche » s'ouvre sur l'onglet « Resume ».

| Zone de Rechercher | Utilisation |
|---|---|
| Arbre des OU | Choisissez la branche à parcourir et relisez son chemin. |
| Données de l’OU, sous l’arbre | Base locale, Postes (ping/WMI) et Les deux actualisent toute l’OU choisie et ses sous-OU. |
| Périmètre et Requêtes | Choisissez une source, des filtres ou une recette, puis lancez la recherche. |
| Résultats | Triez, filtrez et ouvrez les objets affichés. Les actions de liste concernent cette liste. « Actualiser » et « Exporter CSV » sont dans le menu « ⋯ ». |

> [!ASTUCE] Pour ne chercher qu'un type d'objet, commencez par un préfixe : utilisateur: (ou u:), poste: (ou pc:), groupe: (ou g:), mail:. Exemple : poste:compta.

> [!RESULTAT] L'objet cherché est dans la liste ; sa fiche s'ouvre d'un double-clic.

## Trouver le poste associé à une personne

1. **Rechercher l'utilisateur.** Tapez son nom ou son identifiant dans la barre du haut. Sur sa ligne, « Association mémorisée » indique déjà le poste lié, s'il est connu.
2. **Ouvrir sa fiche.** Double-cliquez sur la ligne, puis cliquez sur l'onglet « Utilisateur ».
3. **Lire ses postes.** « Postes associes » liste les postes liés à ce compte. Sélectionnez-en un et cliquez sur « Ouvrir le poste ».

> [!ASTUCE] Plus court : clic droit sur la ligne de l'utilisateur dans les résultats, puis « Rechercher le poste associe ».

> [!RESULTAT] La fiche du poste de l'utilisateur est ouverte.

## Parcourir une OU

Quand : vous voulez voir tous les postes ou tous les utilisateurs d'un site ou d'un service. Une OU est une unité organisationnelle : elle regroupe des objets dans l’annuaire.

1. **Choisir l'OU.** À gauche de la page « Rechercher », dans « Parcourir les OU », dépliez l'arbre et cliquez sur une OU. Son contenu s'affiche dans la liste.
2. **Régler la portée.** Ouvrez le menu « ⋯ » près de « Parcourir les OU ». Décochez « Inclure les sous-OU » pour ne voir que le premier niveau.
3. **Filtrer.** Dans la liste « Tous les types », choisissez par exemple « Machines ». Dans « Toute présence », choisissez « En ligne » ou « Sans réponse au ping ». « 100 lignes max » borne la lecture de la liste. La présence repart sur « Toute présence » à chaque lancement de Domenia : au démarrage, aucun poste nʼest encore vérifié. Si le filtre masque toutes les lignes chargées, la liste lʼindique (« Le filtre masque 48 lignes ») avec un bouton « Effacer le filtre ».
4. **Compléter la liste.** Si le compteur indique une liste limitée, cliquez sur « Charger la suite » : seules les lignes suivantes sont lues, celles déjà affichées restent en place avec votre sélection. Pour aller plus vite, « Charger jusqu’à 1 000 » complète la liste jusqu’à ce palier en un clic (puis 5 000, puis 20 000).
5. **Changer de périmètre.** Choisissez une autre OU dans l’arbre. Pour chercher un objet par son nom dans le domaine, utilisez la barre du haut.

> [!RESULTAT] La liste montre les objets de l'OU choisie.

Sous l’arbre, « Données de l’OU » propose « Base locale », « Postes (ping/WMI) » et « Les deux ». Ces commandes portent toujours sur l’OU choisie et ses sous-OU, même si la liste est filtrée, limitée ou réglée au premier niveau. Elles utilisent l’OU de cet arbre, y compris pendant une recherche globale ; relisez le chemin indiqué. Le chapitre 5 explique quelle commande choisir.

Dans une petite fenêtre, le panneau sous l’arbre se compacte : le titre « Données de l’OU » se masque et « Postes (ping/WMI) » devient « Ping/WMI ». Les commandes gardent le même périmètre et le même effet.

## Exécuter une requête prête à l’emploi

La zone « Requêtes » de Rechercher propose les vues de l’annuaire, les modèles locaux et vos requêtes enregistrées. Le champ de cette zone filtre les noms de requêtes ; il ne recherche pas directement un poste.

1. **Choisir l’OU.** Sélectionnez l’OU dans l’arbre de Rechercher et vérifiez « Inclure les sous-OU » dans son menu « ⋯ ». Ce périmètre est indépendant de celui du tableau de bord.
2. **Trouver une requête.** Saisissez un sujet, par exemple disque, puis choisissez une ligne. Lisez la source et le périmètre sous la liste.
3. **Reconnaître la source.** « Annuaire » lit AD au lancement. « Données locales » utilise les postes déjà recensés et leurs relevés datés, sans ping ni inventaire automatique.
4. **Garder un favori.** Cliquez sur l’étoile. La case « Favoris » retrouve vos requêtes épinglées ; elle filtre seulement le catalogue.
5. **Exécuter.** Cliquez sur « Exécuter ». Les filtres précédents de la liste sont retirés pour afficher la nouvelle requête. Lisez le nombre de lignes affichées et le total.

![Barre Requêtes : recherche locale du modèle, favoris, source et commande Exécuter ; données fictives](fig:recherche-requetes)

Pour une requête locale, choisissez « Correspondants », « Inconnus » ou « Non correspondants », puis cliquez sur « Exécuter ». Un poste inconnu manque d’une information nécessaire ; une mesure absente ou périmée ne devient pas zéro. Pour une liste locale limitée, augmentez la limite puis réexécutez, jusqu’à 20 000 lignes au maximum. Pour une requête Annuaire, utilisez « Charger la suite » lorsqu’il est disponible.

![Requête locale : sélection des postes dont les données nécessaires restent inconnues ; données fictives](fig:recherche-inconnus)

« Effacer la requête » annule la requête et efface ses résultats. Sur une liste de recherche ordinaire, il retire seulement le filtre de requête supplémentaire et conserve la liste. Aucune lecture ne se relance. Choisissez ensuite une OU, une autre requête ou la recherche de nom du bandeau. Le petit crayon ouvre Outils → Atelier de requêtes ; une recette locale sélectionnée se retrouve dans « Composer la requête ».

Dans une fenêtre étroite ou basse, la barre peut se replier : « Options de requête » regroupe le filtre de modèles, les favoris, la source et le choix des résultats. Le bouton rappelle le choix, par exemple « Inconnus », et « Effacer » reste directement accessible. Ouvrez ou repliez ces options selon la place nécessaire ; vos choix sont conservés et aucune recherche ne se lance. Échap referme le volet.

> [!NOTE] Trois dates ont des rôles différents : la base AD indique quand les objets ont été recensés, les mesures indiquent quand les postes ont été interrogés, le calcul indique quand la vue a été préparée. Une couverture AD absente ou partielle appelle « Base locale » ou « Les deux » dans « Données de l’OU ». Un inventaire ancien appelle « Postes (ping/WMI) ». Réexécuter une requête locale ne rajeunit aucune de ces données.

## Si ça ne se passe pas comme prévu

La recherche globale peut continuer tant que de nouveaux objets AD arrivent, pendant 15 minutes au plus par défaut. Elle s’arrête après 2 minutes sans nouvel objet ; vous pouvez l’annuler. Le badge orange « Dernière requête AD : délai dépassé » ne prouve pas une panne réseau. Affinez la recherche puis relancez-la. Une lecture AD réussie rétablit le badge normal. « AD injoignable » en rouge correspond à une erreur réseau ; vérifiez alors la connexion au domaine.

| Vous voyez | Que faire |
|---|---|
| « Saisissez au moins 2 caractères… » | Tapez au moins deux caractères ; les étoiles ne comptent pas. |
| « Saisissez au moins un caractère en plus de * » | Une étoile seule listerait tout le domaine : ajoutez une partie du nom, par exemple « compta* ». |
| « Aucun résultat affiché » | Vérifiez l’orthographe, l’OU et les filtres, ou cherchez le nom dans la barre du haut. Une liste vide ne prouve pas l'absence de l'objet. |
| « La liste affichée nʼest plus la recherche courante : relancez la recherche. » | Relancez la recherche, puis cliquez de nouveau sur « Charger la suite ». |
| « Fiche » est grisé dans le menu | Sélectionnez d'abord une ligne dans les résultats. |

# 2 Ouvrir la fiche du poste et agir dessus

Quand : un utilisateur signale un problème sur son poste et vous devez l'examiner ou intervenir à distance.

Avant de commencer :

- Le poste est trouvé dans « Rechercher » (chapitre 1).
- Pour C$ et les consoles, le compte utilisé a des droits d'administration sur le poste.

## Ouvrir la fiche du poste

1. **Ouvrir le poste.** Double-cliquez sur le poste dans les résultats. La page « Fiche » s'ouvre.
2. **Passer à l'assistance.** Cliquez sur « Poste » dans le menu de gauche. Sans poste sélectionné, la page « Aucun poste ouvert » propose un champ de recherche et les derniers postes consultés.
3. **Lire la fiche.** L'onglet « Machine » affiche la carte « Fiche du poste » : « Nom », « DNS », « Presence », « OS », « Etat », « Derniere connexion » et « Utilisateur associe ».
4. **Trouver l'utilisateur.** Cliquez sur « Detecter l utilisateur » pour chercher le dernier utilisateur connu du poste, puis sur « Ouvrir l utilisateur » pour ouvrir sa fiche.

![Onglet « Machine » de PC-COMPTA-014 : système, présence en ligne et utilisateur associé Camille Martin](fig:fiche-poste)

> [!RESULTAT] La fiche du poste est affichée dans « Poste ». Le titre de la page et la puce « Poste · nom » à côté du badge rappellent le poste ; ✕ le désélectionne.

## Utiliser les outils du poste

Quand : vous voulez tester le poste, ouvrir son disque, une console d'administration ou une session à distance.

1. **Ouvrir l'onglet.** Cliquez sur l'onglet « Actions ». La carte « Actions sur le poste » regroupe les outils.
2. **Tester le réseau.** Cliquez sur « Ping ». Le résultat (état, temps de réponse, adresse) s'inscrit dans le « Journal de session », en bas de la fenêtre.
3. **Ouvrir le disque.** Cliquez sur « Ouvrir C$ ». L'Explorateur Windows s'ouvre sur le disque C du poste. Si vous vous êtes connecté avec un mot de passe, ou si vous avez saisi un compte pour les postes, le « Journal de session » indique le compte utilisé : « C$ de … ouvert avec … ».
4. **Ouvrir une console.** Cliquez sur « Gestion de l ordinateur » ou sur « Journaux » : la console Windows s'ouvre sur ce poste. Si « Services » montre votre propre ordinateur, connectez la console au poste par son menu Action.
5. **Prendre la main.** Cliquez sur « Bureau à distance ». La connexion Bureau à distance de Windows s'ouvre vers ce poste ; saisissez votre compte si Windows le demande.
6. **Préparer PowerShell.** « Commande PowerShell » copie la commande de connexion à distance : collez-la dans votre console PowerShell.

![Actions du poste : état du compte, Ping, Bureau à distance, Ouvrir C$, consoles, journaux et services ; données fictives](fig:actions-poste)

![Autres actions : commande PowerShell, programme, stratégies et redémarrage ; données fictives](fig:actions-poste-avancees)

> [!RESULTAT] L'outil choisi est ouvert sur le poste, sans rien modifier sur le poste ni dans l'annuaire.

> [!ATTENTION] Les actions qui modifient le poste ou l'annuaire, comme « Redemarrer » ou « Renommer dans AD », restent bloquées en « Lecture seule ». Si votre intervention en a besoin, prévenez l'administrateur.

## Utiliser le compte fourni pour les postes

Quand : l'administrateur vous a donné un compte réservé aux postes, ou « Ouvrir C$ » est refusé avec votre compte habituel.

1. **Saisir le compte.** Dans l'onglet « Diagnostic », carte « Diagnostic du poste », remplissez « Compte poste » et « Mot de passe ».
2. **Valider.** Cliquez sur « Utiliser ce compte ». La ligne sous les champs commence par « Operations poste : compte saisi ».
3. **Relancer l'outil.** Revenez à l'onglet « Actions » et cliquez de nouveau sur l'outil voulu.

> [!RESULTAT] « Ouvrir C$ » et les consoles utilisent ce compte, jamais enregistré sur le disque. « Compte de connexion » revient au compte de départ.

## Lancer un inventaire

Quand : vous avez besoin du matériel, du système, des disques ou de la configuration du poste.

1. **Ouvrir l'onglet.** Cliquez sur l'onglet « Inventaire ». La carte « Inventaire du poste » s'affiche.
2. **Choisir l'inventaire.** Cliquez sur « Rapide » (matériel, système, disques, réseau, sécurité, logiciels, services) ou sur « Complet », plus long, qui ajoute les processus, les tâches planifiées, les certificats et les erreurs récentes.
3. **Attendre la fin.** Sur la ligne de « Categorie », un résumé donne ensuite le nombre d'éléments lus et le nombre de sources accessibles ou refusées.
4. **Lire le résultat.** Chaque ligne donne la « Categorie », l'« Element », la « Valeur » et la « Source ». Choisissez une catégorie dans « Categorie » pour n'afficher qu'elle.
5. **Transmettre.** Cliquez sur « Copier » ou sur « Exporter CSV » pour joindre l'inventaire au ticket. « Exporter CSV » enregistre le fichier sans rien demander : son chemin s'affiche dans une fenêtre et dans le « Journal de session » (« Inventaire exporte : … »). Le volet « Detail par source » indique ce qui a été lu ou refusé.

> [!RESULTAT] L'inventaire est affiché, et l'onglet « Tableau de bord » se remplit avec les mêmes données (chapitre 3).

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Poste » affiche « Aucun poste ouvert » | L'objet sélectionné n'est pas un poste. Sélectionnez un poste dans « Rechercher » ou dans « Derniers postes consultés ». |
| Une erreur qui commence par « Ouvrir C$ de » | Lisez le motif. Poste injoignable : vérifiez-le avec « Ping ». Accès refusé : utilisez le compte fourni pour les postes. Sinon, prévenez l'administrateur. |
| « Console ouverte avec la session Windows : » suivi d'un motif | La console utilise votre session Windows et peut être refusée par le poste. Saisissez le compte fourni pour les postes, puis rouvrez la console. |
| « Inventaire impossible : » suivi d'un motif | Lancez « Ping ». Si le poste répond, prévenez l'administrateur (chapitre 8). |

# 3 Lire le tableau de bord du poste

Quand : vous voulez voir d'un coup d'œil l'état d'un poste et ses points à vérifier.

1. **Ouvrir l'onglet.** Dans « Poste », cliquez sur l'onglet « Tableau de bord ». La carte « Tableau de bord du poste » s'affiche.
2. **Remplir le tableau.** Cliquez sur « Inventaire rapide ». Pour les processus les plus gourmands et les erreurs du journal Système, cliquez sur « Inventaire complet », plus long. Un inventaire de l'onglet « Inventaire » remplit aussi ce tableau.
3. **Lire l'état général.** En haut, « Etat general » donne un score sur 100 et un verdict : « Bon etat », « A surveiller », « Degrade » ou « Critique ».
4. **Lire les points d'attention.** « Points d attention » liste les problèmes trouvés, du plus grave au moins grave. « Rien a signaler » : aucun point à vérifier.
5. **Parcourir les sections.** Descendez dans la page pour lire chaque section.

![Tableau de bord de PC-COMPTA-014 après un inventaire : état général, points d'attention, identité du poste et ressources](fig:tableau-poste)

| Section | Ce que vous y lisez |
|---|---|
| « Identite du poste » | Système, modèle, mémoire, démarrage, utilisateur connecté, adresse IP. |
| « Compte machine dans Active Directory » | Mot de passe machine, dernière connexion au domaine, état du compte, LAPS. |
| « Ressources » | Mémoire, processeur, batterie, espace disque. |
| « Activite » | Services Windows ; avec l'inventaire complet, processus les plus gourmands et erreurs du journal Système sur 3 jours. |
| « Securite et etat » | Antivirus, pare-feu, BitLocker, mises à jour, redémarrage en attente, administrateurs locaux. |

> [!NOTE] Vert : rien à signaler ; orange : à surveiller ; rouge : critique. Une section vide indique ce qu'il faut lancer pour la remplir.

## Traiter un point nécessitant une attention

| Point d'attention | Que faire |
|---|---|
| Pas de redémarrage depuis plus de 30 jours, ou redémarrage en attente | Convenez d'un redémarrage avec l'utilisateur. |
| Disque système presque plein | Libérez de la place avec l'utilisateur (« Ouvrir C$ », chapitre 2). Sinon, prévenez l'administrateur. |
| Horloge décalée, mot de passe machine ancien, compte ordinateur désactivé | Prévenez l'administrateur. |
| Version de Windows signalée | Faites vérifier l’édition, son cycle de support et les dispositions de maintenance du parc par l’administrateur. |

> [!RESULTAT] Vous savez si le poste est sain et quels points traiter en premier.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Pas encore de donnees » | Cliquez sur « Inventaire rapide ». |
| Une section indique « Inventaire complet requis : » | Cliquez sur « Inventaire complet ». |
| Un widget affiche « Non lu » | L'information n'a pas pu être lue. Relancez l'inventaire. Si elle reste absente, prévenez l'administrateur. |
| Le tableau se vide quand vous choisissez un autre objet | Le tableau suit le poste sélectionné. Un ancien inventaire peut réapparaître dans l’onglet « Inventaire » avec sa date ; relancez l’inventaire pour remplir le tableau du poste. |

# 4 Savoir qui est connecté sur une liste de postes

Quand : vous cherchez sur quel poste travaille un utilisateur, ou quels postes d'un service sont allumés.

1. **Préparer la liste.** Affichez les postes voulus dans « Rechercher » : OU, recherche ou « Filtrer la liste » (chapitre 1). Seuls les postes affichés sont interrogés : une liste courte va plus vite.
2. **Pinger la liste.** Pour savoir seulement quels postes répondent, cliquez sur « Pinger la liste ». La demande « Pinger les postes affiches » donne le nombre de postes. Cliquez sur « Pinger ».
3. **Ou détecter les utilisateurs.** Pour savoir aussi qui est connecté, cliquez sur « Détecter la liste ». La demande « Detecter sur les resultats affiches » donne le nombre de postes. Cliquez sur « Verifier les sessions ».
4. **Ou analyser les postes.** Pour connaître aussi leur matériel, cliquez sur « Analyser la liste ». La demande « Analyser les postes affiches » donne le nombre de postes. Cliquez sur « Analyser ». En plus de l'utilisateur, Domenia lit le modèle, la mémoire, le disque C:, la version de Windows et la date de démarrage de chaque poste.
5. **Suivre l'avancement.** La ligne sous les boutons suit l'avancement, avec 1 à 8 postes en parallèle selon le réglage, jusqu'à « Ping termine » ou « Releve termine ».
6. **Lire le résultat.** Après « Pinger la liste », seule « Présence réseau » est mise à jour ; après « Détecter la liste » ou « Analyser la liste », « Utilisateur connecté (console) » et « Vérification utilisateur » le sont aussi. Le matériel lu par « Analyser la liste » s'affiche dans la vue d'ensemble de l'Accueil (chapitre 5).
7. **Arrêter si besoin.** Cliquez sur « Arrêter » : aucune nouvelle lecture ne démarre et les résultats déjà obtenus restent affichés.

![Ligne d'actions sous les résultats : « Utilisateur au clic », « Revérifier ce poste », « Pinger la liste », « Détecter la liste », « Analyser la liste » et « Arrêter »](fig:recherche-actions)

> [!ASTUCE] Pour un seul poste, cliquez sur sa ligne, ou sur « Revérifier ce poste » pour recommencer. Décochez « Utilisateur au clic » pour un ping seul.

> [!NOTE] Les sessions Bureau à distance ne sont pas recensées : utilisez l'onglet « Sessions Windows » de « Poste », bouton « Lire les sessions ».

> [!RESULTAT] Pour chaque poste affiché, vous savez s'il répond et qui est connecté sur son écran.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Pinger la liste », « Détecter la liste » et « Analyser la liste » sont grisés | La liste ne contient aucun poste. Affichez des postes, par exemple avec « Type d’objet » sur « Machines ». |
| « Releve impossible : Un releve est deja en cours. » | Attendez la fin du relevé en cours, ou cliquez sur « Arrêter ». |
| « Releve impossible : Attendez la confirmation des enregistrements locaux avant un nouveau releve. » | Attendez quelques secondes, puis relancez. |
| « Releve impossible : Aucune base autonome active. » | Prévenez l'administrateur. |
| « Aucun compte console » | Personne n'est connecté sur l'écran du poste. |
| « Accès refusé » ou « Compte distant refusé » | Le compte n'a pas les droits sur ce poste. Utilisez le compte fourni pour les postes (chapitre 2). Sinon, prévenez l'administrateur. |
| « Délai dépassé » | Le poste a répondu trop lentement. Revérifiez-le plus tard avec « Revérifier ce poste ». |

# 5 Voir et explorer le parc depuis Accueil

L'Accueil présente les postes de la base locale et leurs derniers relevés. Son choix d'OU est indépendant de Rechercher : vous pouvez suivre un service dans le tableau de bord tout en cherchant un autre objet dans l'annuaire.

## Choisir le périmètre

1. **Ouvrir l'Accueil.** Cliquez sur Accueil ou appuyez sur Ctrl+D.
2. **Choisir une OU (unité organisationnelle de l’annuaire).** Utilisez le sélecteur du parc. L’OU choisie inclut ses sous-OU. Le chemin cliquable permet de remonter vers une OU parente.
3. **Vérifier les dates.** Distinguez la lecture AD, les mesures des postes et le calcul de la vue. Un total local ne prouve pas que tous les objets du domaine ont été lus.
4. **Recalculer l’affichage.** Le bouton « Recalculer la vue » utilise les données déjà enregistrées. Les dates AD, ping et WMI restent celles de leur lecture.

« Ouvrir dans Rechercher » transmet les postes recensés du périmètre, y compris les comptes désactivés, et retire les anciens filtres de cette liste. Cette action facultative donne accès aux commandes Pinger, Détecter et Analyser la liste.


Le sélecteur présente un arbre des OU, avec les branches classées par nom dans l’ordre alphabétique français. Dépliez une branche ou utilisez le champ de recherche, puis relisez le site et le chemin avant de choisir. Plusieurs OU peuvent porter le même nom.

![Sélecteur intégré : arbre des OU, recherche et chemin de la sélection ; données fictives](fig:selecteur-ou)

## Choisir quoi actualiser

Les mêmes trois commandes sont disponibles près du choix d’OU dans Accueil et sous l’arbre de Rechercher, dans « Données de l’OU ».

| Votre besoin | Commande | Ce qui est lu |
|---|---|---|
| Retrouver les objets ajoutés, déplacés ou supprimés de l’annuaire | Base locale | Active Directory, puis enregistrement de sa copie locale. Aucun ping ni inventaire. |
| Connaître la présence et l’état actuel des postes déjà recensés | Postes (ping/WMI) | Ping, utilisateur console, inventaire léger (modèle, mémoire, disque C:, version Windows, démarrage) et sondes des widgets configurés. |
| Actualiser le recensement puis l’état des postes | Les deux | Lecture AD et stockage terminé, puis relevé des postes. |

Relisez le chemin de l’OU et la mention des sous-OU. Les commandes portent sur toute cette branche ; les filtres, la limite et la case « Inclure les sous-OU » de la liste de Recherche ne réduisent pas leur cible. Les choix d’OU d’Accueil, de Rechercher et de Base autonome restent indépendants. Choisissez une OU avant de lancer : la racine du domaine n’est pas une cible de ces commandes.

« Postes (ping/WMI) » interroge les comptes ordinateur actifs connus dans la base de cette branche. Le nombre de postes est confirmé avant la collecte. Les mesures demandées sont relues, même si une ancienne mesure est encore récente. Les comptes désactivés restent dans le recensement et ne sont pas sondés. Les sondes WMI des widgets configurés sur les tableaux Général et Poste sont aussi incluses. Leur liste est fixée au clic de lancement ; modifier ensuite un widget ne change pas l’opération en cours.

Avec « Les deux », le relevé commence seulement après une lecture AD complète et son enregistrement confirmé. Une erreur, une lecture partielle ou une annulation empêche la phase suivante. « Arrêter » interdit les nouveaux départs et conserve les données déjà enregistrées. Attendez la fin indiquée avant de fermer Domenia.

| Date affichée | Comment la lire |
|---|---|
| Base locale / AD | Dernière lecture complète couvrant cette OU, éventuellement celle d’une OU parente. Une tentative incomplète reste signalée. |
| Mesures des postes | Dates des relevés de présence, de console et d’inventaire. Un poste peut avoir une mesure récente et une autre ancienne ou en échec. |
| Calcul de la vue | Moment où Domenia a préparé l’affichage à partir des données disponibles. Cette date n’atteste aucune nouvelle lecture AD ni WMI. |

La ligne « Postes actifs » présente séparément le ping et l’inventaire WMI : N/M indique combien de postes disposent d’une mesure utilisable parmi les comptes actifs recensés. « Du… au… » montre les dates de ces mesures ; ce n’est pas la date d’une lecture commune à tous les postes.

La date associée au ping est celle du relevé de présence qui le comprend ; elle ne mesure pas l’instant exact de la réponse réseau.

Un échec de lecture conserve les dernières valeurs réussies avec leur date. La date d’un autre poste ou celle d’un ping réussi ne les rend pas récentes.

## Afficher les postes derrière un chiffre

1. **Ouvrir le détail.** Survolez le widget ou donnez-lui le focus avec le clavier, puis cliquez sur la petite icône de détail près du crayon. L’Atelier de requêtes s’ouvre dans Outils, avec le périmètre du tableau de bord. Un clic sur la carte ou sur un segment de graphique laisse le tableau affiché.
2. **Lire la liste.** L’onglet « Résultats » affiche les postes correspondants. Le compteur porte sur le résultat complet. La table affiche 200 postes par page ; utilisez les commandes de page pour parcourir la suite.
3. **Examiner un poste.** Sélectionnez sa ligne, ouvrez sa fiche ou les actions du poste. Vérifiez le nom et l'identité affichés avant une intervention.
4. **Préciser ou revenir.** Dans « Composer la requête », ajoutez une condition, puis cliquez sur « Exécuter » pour revenir aux résultats. Le bouton « Retour » revient à l’écran précédent.

![Détail local du poste sélectionné dans l’Atelier ; données fictives](fig:atelier-fiche-locale)

Pour un point d'attention, le premier aperçu est volontairement court. « Détailler les postes » ouvre la sélection complète dans l'Atelier. La mention « Sélection figée » signifie que la liste conserve les identifiants des postes concernés au moment du clic ; elle ne découvre pas les nouvelles alertes apparues ensuite. Ouvrez à nouveau le point d'attention pour obtenir une nouvelle sélection.

![Détail d’un point d’attention dans l’Atelier : mention Sélection figée et liste des postes concernés ; données fictives](fig:alerte-selection)

## Trouver tous les postes recensés

Ouvrez Outils → Atelier de requêtes, ou utilisez la petite icône de la barre du parc. Le petit crayon de Rechercher ouvre également l’Atelier ; une recette locale sélectionnée y est préparée pour modification. Dans l’Atelier, relisez le périmètre du parc affiché en haut : il peut différer de l’OU de Rechercher. Choisissez « Tous les postes recensés », cliquez sur « Charger », puis sur « Exécuter ». Elle inclut les comptes actifs et désactivés du périmètre. Une recherche textuelle dans Rechercher peut donner moins de lignes à cause de sa limite et de ses filtres ; la base et l'Atelier servent à examiner le recensement complet.

Dans « Composer la requête », ajoutez une condition en choisissant une information, un opérateur et une valeur. « Toutes les conditions » impose leur réunion ; « Au moins une condition » accepte un poste qui en remplit une. Pour repérer des mesures manquantes, utilisez « est absent ».

Vous pouvez sauvegarder la requête sous un nom clair, la retrouver dans la liste des requêtes et l'ajouter au tableau de bord. Une répartition par système, modèle ou autre champ donne les principaux groupes ; « Autres » rassemble les groupes restants et « Inconnu » les données non renseignées.

![Atelier de requêtes : onglet Résultats et liste paginée des postes recensés ; données fictives](fig:atelier-requetes)

Pour vérifier les comptes désactivés, choisissez leur état dans le filtre de la table. L’exemple ci-dessous retrouve trois postes désactivés dans le même recensement. Remettez ensuite le filtre sur tous les états.

![Comptes désactivés : trois postes restent visibles dans l’Atelier ; données fictives](fig:atelier-desactives)

## Partir d’un modèle prêt à utiliser

L’onglet « Bibliothèque » présente 152 modèles livrés dans 14 catégories, ainsi que vos requêtes personnelles. Recherchez un sujet, filtrez par catégorie ou par source (« Modèles livrés » ou « Mes requêtes »), puis sélectionnez une ligne. Lisez sa description et les informations nécessaires avant de cliquer sur « Utiliser cette requête ». Ajustez les conditions dans « Composer la requête », puis cliquez sur « Exécuter » pour consulter les résultats locaux. Le sélecteur rapide et « Charger », en haut de l’Atelier, restent disponibles.

Un modèle peut servir au parc ou au tableau d’un poste. Donnez un nom clair à votre adaptation pour l’enregistrer comme requête personnelle. Le modèle décrit les conditions ; les données nécessaires doivent déjà avoir été relevées ou faire l’objet d’une collecte explicite.

Deux points de départ : « Comptes désactivés » utilise la copie AD de l’OU ; « C: moins de 20 % libre » utilise l’espace disque relevé dans l’inventaire léger. Une donnée manquante reste inconnue, même si le modèle est prêt à utiliser.

![Bibliothèque : recherche d’un modèle, informations nécessaires et description avant utilisation ; données fictives](fig:atelier-modeles)

## Choisir une information dans le catalogue

L’onglet « Catalogue des informations » aide à trouver le champ utile : nom, matériel, sécurité, réseau ou autre information. Saisissez un mot et limitez au besoin la source ou la catégorie. La fiche explique l’usage, le type de valeur et la manière d’obtenir la donnée.

Cliquez sur « Utiliser cette information » pour retrouver le champ dans « Composer la requête ». Choisissez ensuite l’opérateur et la valeur, puis cliquez sur « Ajouter ». Ouvrir le catalogue ou sélectionner un champ ne lance aucune collecte.

![Catalogue des informations : recherche d’un champ et explication de sa source ; données fictives](fig:atelier-catalogue)

## Exemple : suivre les disques peu disponibles

1. **Choisir l’information.** Ouvrez « Composer la requête » et sélectionnez l’espace libre du disque système en pourcentage.
2. **Définir le seuil.** Choisissez l’opérateur inférieur à, saisissez 20 puis ajoutez la condition.
3. **Lire le résultat.** Cliquez sur « Exécuter » : l’onglet « Résultats » s’ouvre. Contrôlez le total et la date des mesures. Une valeur absente ne signifie pas que le disque est plein.

![Condition numérique : espace libre du disque système inférieur à 20 % ; données fictives](fig:atelier-condition)

4. **Nommer et enregistrer.** Revenez dans « Composer la requête », donnez un nom explicite à la requête puis cliquez sur « Enregistrer ». Retrouvez-la dans la liste pour la réutiliser.

![Requête nommée enregistrée dans la bibliothèque de l’Atelier ; données fictives](fig:atelier-bibliotheque)

5. **Ajouter au tableau.** Dans « Composer la requête », choisissez la destination « Tableau de bord général », puis une présentation : Indicateur, Texte, Barres, Camembert ou Colonnes. Cliquez sur « Créer une sonde dashboard ». Le widget reprend la requête ; sa petite icône de détail permet de revenir aux postes concernés.

![Sonde du tableau de bord créée depuis la requête sur les disques ; données fictives](fig:accueil-sonde-requete)

6. **Filtrer Rechercher.** Dans « Composer la requête », cliquez sur « Appliquer aux résultats de Recherche ». Le filtre utilise les identités des postes trouvés ; relisez la restriction affichée et effacez-la pour revenir à la liste habituelle.

![Rechercher filtré par les postes trouvés dans l’Atelier ; données fictives](fig:recherche-requete)

## Réutiliser une requête sur un poste

Le bouton « Atelier » du tableau de bord du poste ouvre la même bibliothèque de requêtes. Dans « Composer la requête », choisissez « Tableau de bord du poste » et la présentation souhaitée, puis « Créer une sonde dashboard ». Le widget applique la recette au poste actuellement sélectionné ; il sera réévalué lorsque vous changerez de poste.

« Tester sur le poste sélectionné » indique s’il correspond, ne correspond pas ou si le résultat reste inconnu. Ce test lit les données locales déjà disponibles, sans lancer de collecte. La grande liste « Résultats » de l’Atelier continue à afficher les postes de l’OU indiquée en haut ; elle ne se transforme pas en liste d’un seul poste.

![Atelier : destination Poste et aperçu local de la requête sur le poste sélectionné ; données fictives](fig:atelier-poste)

![Tableau du poste : widget créé depuis la même bibliothèque de requêtes ; données fictives](fig:poste-sonde-requete)

## Mettre à jour les relevés

Pour un relevé général de l’OU, utilisez « Postes (ping/WMI) » ; si le recensement doit aussi être relu, choisissez « Les deux ». La procédure suivante concerne les seules informations demandées par une requête dans l’Atelier et permet de régler leur réutilisation.

1. **Choisir le périmètre.** La collecte de l’Atelier concerne tous les comptes actifs de l’OU affichée et de ses sous-OU, même si une condition réduit la table. Pour cibler un seul poste, utilisez l’action de sa fiche locale. Les comptes désactivés restent consultables et sont exclus de la collecte du parc.
2. **Régler la collecte.** Dans « Composer la requête », dépliez « Réglages de collecte ». Commencez par 4 postes en parallèle. Le réglage propose 1, 2, 4, 6 ou 8 ; réduisez-le si le réseau ou les postes répondent mal.
3. **Choisir la fraîcheur.** Réutilisez les mesures de moins de 5, 15 ou 60 minutes, ou forcez une relecture. Certaines données volatiles restent soumises à un délai plus court.
4. **Lancer et confirmer.** Cliquez sur « Collecter les données requises… » et relisez le nombre de cibles avant confirmation. Suivez les réussites, les refus et les enregistrements en attente.

![Réglages de la collecte : parallélisme et durée de réutilisation des mesures ; données fictives](fig:atelier-collecte)
5. **Arrêter si besoin.** Arrêter empêche de nouvelles lectures ; les résultats déjà obtenus sont conservés. Attendez la confirmation du stockage avant de quitter.

La collecte lit les informations requises par la requête : présence, utilisateur console, inventaire léger ou sondes WMI. Si la recette utilise uniquement des données AD, Domenia invite à mettre à jour la base de l’OU. « Actualiser ce poste… » dans la fiche locale reste une demande d’inventaire léger sur ce seul poste. La commande « Postes (ping/WMI) » de l’OU relit le ping, la console, l’inventaire léger et les sondes des widgets configurés, indépendamment du brouillon de l’Atelier. Pour collecter seulement les informations d’une requête, utilisez la procédure sélective décrite ici.

## Mettre à jour la base du parc

Pour relire AD sans quitter Accueil ou Rechercher, utilisez « Base locale » auprès de l’OU visée. Pour parcourir le contenu ou gérer les sauvegardes, ouvrez Outils puis Base autonome. Le choix d’OU, visible au-dessus des onglets, règle « Mise à jour » et « Données ». « Stockage » agit sur la base locale entière. Cliquez sur « Choisir une OU », sélectionnez son unité organisationnelle, puis relisez le chemin affiché. Ce choix est indépendant de Rechercher.

| Votre besoin | Onglet et commande |
|---|---|
| Relire les objets du service et de ses sous-OU | Mise à jour → « Mettre à jour lʼOU choisie » ; une OU doit être sélectionnée |
| Suivre la lecture et la fraîcheur | Mise à jour → « État de la copie locale » et progression |
| Parcourir les utilisateurs et postes enregistrés | Données → « Afficher / actualiser les objets » |
| Trouver la base ou en faire une copie | Stockage → « Emplacement et sauvegarde » |

![Mise à jour de la base : OU choisie et commande de relecture ciblée ; données fictives](fig:base-commandes)

La mise à jour inclut les sous-OU et conserve les autres branches. Suivez séparément la lecture de l’annuaire et l’enregistrement local. Une passe partielle ne vaut pas un recensement terminé : la date de la dernière lecture complète reste visible avec la tentative partielle. Une lecture complète d’une OU parente peut couvrir l’OU affichée ; le chemin de cette couverture est indiqué.

Dans l’onglet « Données », « Afficher / actualiser les objets » recharge la liste. Sans texte de recherche, elle montre les objets du périmètre par pages de 200, avec le total correspondant. Comparez le même périmètre et les mêmes types d’objets avant de comparer deux compteurs.

Cliquez sur un en-tête pour trier le résultat complet, sur toutes les pages ; cliquez de nouveau pour inverser le sens. « Tri par pertinence » rétablit le classement initial. Les dates inconnues restent en fin de liste. La colonne Association ne se trie pas.

![Base autonome : onglet Données et liste des objets du périmètre ; données fictives](fig:base-autonome)

Dans l’onglet « Mise à jour », dépliez « Détails du stockage et de la synchronisation » pour retrouver le fichier, le contrôleur et les informations du dernier suivi.

| Information de la base locale | Ce qu’il faut vérifier |
|---|---|
| Nombre d’objets | Utilisateurs et postes recensés dans le périmètre annoncé, y compris les comptes désactivés. |
| Lecture complète AD | Date d’une lecture réussie couvrant l’OU et ses sous-OU. Une date d’OU parente peut couvrir ce périmètre. |
| Tentative incomplète | L’avertissement reste distinct de la dernière date complète. Relisez le bilan avant de relancer. |
| Détails du stockage | Fichier local et contrôleur utilisés ; ces repères ne décrivent pas l’âge des mesures des postes. |

| Phase affichée | Ce qui se passe |
|---|---|
| Lecture AD | Les objets arrivent depuis l’annuaire ; le total définitif peut être encore inconnu. |
| Enregistrement local | Les lots sont écrits dans la base. Recevoir un objet ne prouve pas encore son stockage. |
| Terminé | Le bilan confirme les écritures. Avec Les deux, le relevé des postes peut ensuite être préparé. |
| Partiel, interrompu ou erreur | La phase suivante ne démarre pas. Les données déjà enregistrées sont conservées. |

L’onglet « Stockage » rassemble le chemin de la base et les sauvegardes. La sauvegarde porte sur la base entière ; la purge efface les catégories de données choisies dans toute cette base, après simulation et confirmation. Le guide administrateur décrit cette opération.

![Stockage : emplacement, sauvegarde et maintenance locale ; données fictives](fig:base-stockage)

## Comprendre une différence

| Vous voyez | Que faire |
|---|---|
| Un widget compte plus de postes que Rechercher | Vérifiez l'OU, les sous-OU, les comptes désactivés, le filtre et la limite de Rechercher. Ouvrez sa petite icône de détail pour consulter la liste exacte. |
| Une mesure est inconnue ou ancienne | Pour le ping et l’inventaire léger de l’OU, utilisez « Postes (ping/WMI) ». Pour une sonde précise, collectez depuis l’Atelier. Un ping récent ne rafraîchit pas un ancien inventaire. |
| Le calcul est récent mais la base ou les mesures sont anciennes | Le calcul prépare l’affichage. Choisissez « Base locale », « Postes (ping/WMI) » ou « Les deux » selon la source à relire. |
| Une actualisation vise plus de postes que la liste n’en montre | Les commandes « Données de l’OU » couvrent toute l’OU et ses sous-OU. Pinger, Détecter et Analyser la liste restent limités aux lignes affichées. |
| Un inventaire échoue mais des valeurs restent affichées | Ce sont les dernières valeurs réussies, avec leur date. Consultez l’erreur et relancez une collecte adaptée ; leur présence ne signifie pas que le dernier essai a réussi. |
| La base est partielle | Relancez la mise à jour selon le message affiché. Ne concluez pas à une suppression à partir d'une passe incomplète. |
| La base est occupée | Attendez la fin de l'enregistrement, puis actualisez. |
| Aucun poste n'apparaît | Effacez les conditions et le segment, puis vérifiez le périmètre et la couverture de la base. |

# 6 Personnaliser un tableau de bord

Quand : vous voulez garder sous les yeux les informations utiles. Chaque tuile ou graphique d'un tableau de bord (poste, Accueil, logiciels) est un widget ; Domenia garde votre disposition.

## Ajouter un widget

1. **Ouvrir le panneau.** Cliquez sur « Ajouter un widget » dans la barre du tableau. Le panneau de réglage s’ouvre dans la fenêtre.
2. **Chercher l'information.** Tapez un mot dans la recherche (disque, utilisateur, BitLocker…) : la liste des informations se réduit. Le badge « affiche » signale une information déjà sur le tableau.
3. **Choisir.** Cliquez sur une ligne. L'« Apercu » montre le widget.
4. **Régler.** Modifiez au besoin le « Titre », la « Représentation » (« Chiffre cle », « Jauge », « Anneau », « Barres »…), la « Taille » et la « Section ». Pour une nouvelle section, choisissez « + Nouvelle section... » et tapez son nom dans le champ qui apparaît.
5. **Ajouter.** Cliquez sur « Ajouter » : le widget apparaît à la fin de sa section. Hors personnalisation, un widget encore sans données reste masqué et la barre affiche « Widget enregistre : il s affichera des que ses donnees seront lues. ». « Annuler » ne change rien.

![Panneau « Ajouter un widget » : recherche, liste des informations, réglages à droite et aperçu du widget « Disque systeme »](fig:editeur-widget)

> [!NOTE] Une ligne « Requetes WMI · » interroge les postes. Sur le tableau du poste, cliquez sur « Actualiser les requetes », puis sur « Verifier les sessions » : le widget se remplit. Sur l’Accueil, ouvrez le détail de la sonde, puis collectez ses données dans l’Atelier.

> [!RESULTAT] Le widget est enregistré sur le tableau, dans la section choisie.

## Déplacer, redimensionner ou retirer

1. **Passer en personnalisation.** Cliquez sur « Personnaliser ». Chaque widget porte les boutons ronds modifier et retirer ; une tuile « Ajouter ici » termine chaque section.
2. **Déplacer.** Glissez un widget et lâchez-le sur un autre : il prend sa place, même dans une autre section. Le clic droit propose aussi « Déplacer ».
3. **Changer la taille.** Clic droit sur le widget, « Taille », puis « Compacte », « Moyenne » ou « Large ». Le sous-menu « Représentation » change le type de graphique.
4. **Retirer.** Cliquez sur le bouton rond dont l'infobulle commence par « Retirer : », ou faites un clic droit, « Retirer du tableau de bord ». Aucune confirmation n'est demandée.
5. **Terminer.** Cliquez sur « Terminer ».

![Tableau du poste en personnalisation : boutons ronds sur chaque widget et tuiles « Ajouter ici » au bout des sections](fig:personnaliser)

> [!ASTUCE] Hors personnalisation, le clic droit reste disponible et les boutons ronds apparaissent au survol ou au focus clavier. Pour déplacer une carte à la souris, activez « Personnaliser ».

## Revenir en arrière

1. **Annuler la dernière modification.** Après un changement, la barre du tableau le rappelle, par exemple « Widget retire », avec le bouton « Annuler ». Cliquez dessus : la disposition précédente revient.
2. **Revenir à la disposition d'origine.** En personnalisation, cliquez sur « Par defaut ». Ce retour s'annule lui aussi avec « Annuler ».

> [!ATTENTION] « Annuler » ne revient qu'une étape en arrière et disparaît dès que de nouvelles données arrivent ou que vous choisissez un autre objet. Vérifiez le tableau avant de passer à autre chose.

> [!RESULTAT] Le tableau affiche vos widgets, dans l'ordre et à la taille choisis.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Aucun widget » | Tous les widgets ont été retirés. Cliquez sur « Ajouter un widget », ou sur « Personnaliser » puis « Par defaut ». |
| Un widget affiche « En attente » | Sur le tableau du poste, cliquez sur « Actualiser les requetes ». Sur l’Accueil, ouvrez le détail de la sonde, puis collectez ses données dans l’Atelier. |
| Un widget vide n'apparaît plus | Il réapparaît quand ses données sont lues ; « Personnaliser » le montre. |

# 7 Consulter les logiciels du poste

Quand : vous devez savoir si un logiciel est installé sur un poste, dans quelle version et pour qui.

1. **Ouvrir l'onglet.** Dans « Poste », cliquez sur l'onglet « Logiciels ». La carte « Logiciels installes » s'affiche.
2. **Choisir l'étendue.** « Par utilisateur », cochée par défaut, ajoute les logiciels de chaque profil. Cochez « Applications Store » pour le Microsoft Store (plus long), « Mises a jour » pour les correctifs et composants système.
3. **Charger.** Cliquez sur « Charger les logiciels ». Chaque ligne donne le « Nom », la « Version », l'« Editeur », « Installe le », la « Taille » et la « Portee ».
4. **Chercher un logiciel.** Tapez une partie du nom, de l'éditeur ou de la version dans « Filtre ». « Portee » limite la liste à « Machine », « Utilisateur » ou « Store ».
5. **Lire la synthèse.** Dans « Affichage », choisissez « Synthèse ». Les graphiques résument la liste chargée : nombre, éditeurs, versions multiples, architecture, portée et plus gros logiciels, plus « Installés ces 30 derniers jours », « Composants dʼexécution » (Visual C++, .NET, WebView2) et « Navigateurs et versions ». Une tuile à zéro prend la coche verte plutôt qu'un chiffre, et « Sans date » signale qu'aucun logiciel lu ne déclare sa date.
6. **Transmettre.** « Copier » copie la liste complète ; « Exporter CSV » l'enregistre dans un fichier dont le chemin s'affiche dans le « Journal de session » (« Logiciels exportes : … »).

![Onglet Logiciels, affichage Synthèse : indicateurs et graphiques calculés sur les logiciels chargés ; données fictives](fig:logiciels)

> [!RESULTAT] Vous savez si le logiciel est présent, dans quelle version et s'il est installé pour tous ou pour un seul utilisateur.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Selectionne un poste, puis charge la liste. » | Sélectionnez un poste dans « Rechercher », puis cliquez sur « Charger les logiciels ». |
| « Lecture impossible : » suivi d'un motif | Vérifiez le poste avec « Ping ». S'il répond, prévenez l'administrateur. |
| Un logiciel attendu n'apparaît pas | Videz « Filtre », remettez « Portee » sur « Toutes ». Cochez « Par utilisateur » ou « Applications Store », puis rechargez. |
| « Chargez les logiciels pour afficher la synthese. » | Cliquez sur « Charger les logiciels ». |

# 8 En cas de problème

Quand une opération échoue, Domenia écrit un message dans le « Journal de session » et ouvre parfois une fenêtre d'erreur.

## Messages fréquents

| Vous voyez | Que faire |
|---|---|
| « Identifiant ou mot de passe incorrect. » | Vérifiez l'identifiant et le mot de passe, puis réessayez une fois. |
| « Ce compte est verrouille. » ou « Ce compte est desactive. » | Ne multipliez pas les essais. Prévenez l'administrateur. |
| « Le mot de passe de ce compte a expire. » | Changez-le (Ctrl+Alt+Suppr, Modifier un mot de passe), puis reconnectez-vous. |
| Un message qui se termine par « le compte utilise ne possede pas les droits necessaires. » | Prévenez l'administrateur. |
| « les identifiants ont ete refuses. » | Vérifiez le compte utilisé pour les postes (chapitre 2). Sinon, prévenez l'administrateur. |
| « le controleur de domaine ou le poste distant est indisponible. » | Vérifiez avec « Ping » que le poste est allumé et sur le réseau. |
| « En memoire uniquement : » sur la ligne d'état, sous « Pinger la liste » et « Détecter la liste » | Les observations ne sont plus enregistrées. Prévenez l'administrateur. |
| Un bouton grisé | Survolez-le : l'infobulle dit ce qui manque, par exemple « Desactive : mode lecture seule actif. ». |

## Lire l’état du moteur

Cliquez sur « Opérations » dans le bandeau, ou sur « État du moteur » dans le Journal de session déplié. Le panneau indique les tâches, la mémoire utilisée, la réactivité de l’interface et la dernière sauvegarde locale. La ligne « Traitement des résultats dans l’interface » montre la durée des retours traités pendant cette session, si des mesures sont disponibles.

![Panneau des opérations et santé du moteur ; valeurs de démonstration](fig:etat-moteur)

Ces mesures sont locales à Domenia. Elles ne testent ni le réseau ni les postes. Pour signaler un ralentissement, relevez l’heure, l’action et les valeurs affichées ; fermez le panneau avec son bouton ou Échap.

## Contacter votre administrateur

Donnez-lui ces éléments :

- le message exact, copié avec « Copier » dans le « Journal de session » ;
- pour un problème de connexion, le texte obtenu avec « Copier le diagnostic » dans la fenêtre de connexion ;
- pour un poste, le rapport de l'onglet « Diagnostic » : « Lancer le diagnostic », puis « Copier le rapport » ;
- le nom du poste ou de l'utilisateur, l'heure et ce que vous avez fait juste avant.

> [!ATTENTION] Ne relancez pas en boucle une action qui échoue. Ne collez jamais de mot de passe dans un ticket, et relisez le texte copié : il contient les noms des postes et des comptes.

# 9 Repères

## La fenêtre de Domenia

- **Menu de gauche** : en haut « Accueil », « Rechercher », « Fiche », « Poste », « Utilisateurs et postes » (associations utilisateur et poste) ; en bas « Comptes », « Outils », le choix « Essentiel | Expert », le compte et le domaine connectés (menu « Changer de compte », « À propos ») et la petite icône qui replie le menu. Sous 1280 de large, le menu se replie seul sans changer votre choix.
- **Bandeau** : barre « Personne, poste ou groupe, dans tout le domaine… » avec sa loupe, ✕ pour la vider et l'indication « Ctrl K » pour la palette des actions ; boutons-icônes « Accès » et « Opérations » (pastille au-dessus de zéro), thème (l'icône montre le thème obtenu), « ? » pour l'aide. Les flèches Précédent et Suivant sont à gauche du titre de la page.
- **Interrupteur « Lecture seule »** : actif à chaque démarrage. Les actions qui modifient l'annuaire ou les postes restent bloquées.
- **Aide** : « ? » ouvre l'« Aide contextuelle » à droite. Survolez un contrôle, ou passez dessus avec Tab, pour lire son rôle.
- **Zoom** : les boutons − et + en bas de la fenêtre règlent la taille de l’interface de 80 à 150 %, par pas de 10. Cliquez sur le pourcentage pour revenir à 100 %. Votre choix est conservé. Le menu et les espacements s’adaptent à la place restante après zoom ; les barres de défilement donnent accès aux zones qui dépassent.
- **Journal de session** : en bas de la fenêtre, messages, résultats et erreurs de la session ; « Copier » le copie.

> [!ATTENTION] L'interrupteur rouge « Écriture active · 12 min » et le cadre rouge de la fenêtre signalent que les modifications sont autorisées. Cliquez sur « Repasser en lecture » si aucune intervention en écriture n'est prévue ; sinon la lecture seule revient seule après 15 minutes sans écriture.

## Raccourcis clavier

| Raccourci | Effet |
|---|---|
| Ctrl+F | Ouvrir « Rechercher », curseur dans la barre de recherche |
| Entrée | Dans la barre : lancer la recherche. Sur une ligne de résultat : ouvrir la fiche. |
| Échap | Dans la barre : vider le texte et les résultats. Dans une demande de confirmation : répondre « Annuler ». |
| Ctrl+D | Ouvrir l'« Accueil » |
| Ctrl+K | Ouvrir la palette des actions |
| Ctrl+L | Déplier le journal de session (profil Essentiel) ; ouvrir « Outils », onglet « Journal » (profil Expert). Le profil ne change jamais. |
| Ctrl+I | Ouvrir « Outils », onglet « Base autonome » |

## Avant une intervention

- Notez le nom du poste, l'utilisateur concerné et la référence du ticket.
- Vérifiez le badge « Connecté à … » : c'est le bon domaine.
- Vérifiez que le poste répond (« Ping ») avant d'ouvrir C$ ou une console.
- Prévenez l'utilisateur avant de prendre la main en Bureau à distance.

# 10 Mots à connaître

| Terme | En clair |
|---|---|
| AD (Active Directory) | Annuaire de l'entreprise : comptes des utilisateurs, postes et groupes. |
| OU | Unité d’organisation, dossier de l'AD qui range les postes ou les comptes, par exemple par site ou par service. |
| Périmètre | Zone de l’annuaire retenue dans une page. Accueil inclut les sous-OU ; Rechercher et Base autonome conservent leurs propres périmètres. |
| Base autonome | Copie locale de l’annuaire, gardée par Domenia ; « Base locale » la met à jour pour l’OU. Outils permet aussi de la parcourir et de la sauvegarder. |
| Fraîcheur | Âge de la lecture de la source : AD, ping, console ou inventaire. La date de calcul d’une vue n’est pas la date de ses données. |
| Ping | Test réseau : le poste répond-il ? Une absence de réponse ne prouve pas qu'il est éteint. |
| Utilisateur console | Personne connectée sur l'écran du poste, hors Bureau à distance. |
| Association | Lien mémorisé entre un utilisateur et un poste. Ce n'est pas la preuve d'une session ouverte. |
| WMI | Interface de Windows qui permet de lire à distance les informations d'un poste. |
| Widget | Tuile ou graphique d'un tableau de bord (poste, parc ou logiciels), que vous pouvez ajouter, déplacer ou retirer. |
| Lecture seule | Mode de départ de Domenia : consultation, sans modification de l'annuaire ni des postes. |

## À propos de ce guide

Ce guide accompagne Domenia 1.0 pour les gestes du support quotidien. Le guide administrateur détaille l'installation, les droits, les données, les limites et les contrôles de livraison. Les noms visibles dans les figures sont fictifs.
