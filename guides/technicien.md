# 1 Trouver une personne ou un poste

Quand : avant toute intervention, vous devez retrouver un poste, un utilisateur ou un groupe du domaine.

## Ouvrir Domenia

1. **Lancer Domenia.** Double-cliquez sur Domenia.exe. La fenêtre « Domenia · Connexion » s'ouvre.
2. **Saisir le compte.** Dans « Compte Windows », tapez votre compte du domaine (DOMAINE\identifiant ou identifiant@domaine), puis le « Mot de passe ».
3. **Se connecter.** Cliquez sur « Se connecter » ou appuyez sur Entrée. Si votre session Windows est ouverte avec votre compte du domaine, cliquez plutôt sur « Utiliser mon compte Windows ».
4. **Attendre l'ouverture.** « Vérification du compte… » s'affiche, puis la fenêtre principale s'ouvre. Sous le titre de la page, le badge « Connecté à … » donne le nom du domaine ; le pied du menu rappelle le compte et le domaine utilisés.

![Fenêtre « Connexion à Domenia » : compte, mot de passe, « Se connecter » et « Utiliser mon compte Windows »](fig:connexion)

> [!NOTE] Cochez « Mémoriser uniquement l’identifiant » pour retrouver votre identifiant la fois suivante. Le mot de passe n'est jamais enregistré.

> [!RESULTAT] Domenia est ouvert avec l'interrupteur sur « Lecture seule » : vous consultez sans rien modifier.

## Rechercher dans tout le domaine

1. **Placer le curseur.** Cliquez dans la barre du haut « Personne, poste ou groupe, dans tout le domaine… », ou appuyez sur Ctrl+F. Vos dernières recherches et fiches s'affichent sous la barre ; pendant la frappe, des suggestions viennent de la base locale. La saisie seule n'interroge pas l'annuaire.
2. **Taper le nom.** Saisissez au moins deux caractères : nom, identifiant, adresse mail ou nom de poste. Appuyez sur Entrée ou cliquez sur « Rechercher ». La page « Rechercher » affiche la liste « Résultats ».
3. **Lire la liste.** Chaque ligne donne le « Type », le « Nom », l'« Utilisateur connecté (console) », l'« Association mémorisée » et la « Présence réseau ».
4. **Affiner sans relancer.** Tapez quelques lettres dans « Dans les résultats » : seules les lignes qui les contiennent restent. « Effacer le filtre » réaffiche tout.
5. **Vérifier un poste.** Cliquez une fois sur la ligne d'un poste. Domenia le pingue et lit l'utilisateur ouvert sur son écran : « Présence réseau » et « Utilisateur connecté (console) » se mettent à jour.
6. **Ouvrir la fiche.** Double-cliquez sur la ligne, ou appuyez sur Entrée. La page « Fiche » s'ouvre sur l'onglet « Resume ».

![Page « Rechercher » après la recherche « compta » : postes, utilisateurs et groupe ; PC-COMPTA-014 est en ligne et cmartin y est connecté](fig:recherche)

> [!ASTUCE] Pour ne chercher qu'un type d'objet, commencez par un préfixe : utilisateur: (ou u:), poste: (ou pc:), groupe: (ou g:), mail:. Exemple : poste:compta.

> [!RESULTAT] L'objet cherché est dans la liste ; sa fiche s'ouvre d'un double-clic.

## Trouver le poste d'un utilisateur

1. **Rechercher l'utilisateur.** Tapez son nom ou son identifiant dans la barre du haut. Sur sa ligne, « Association mémorisée » indique déjà le poste lié, s'il est connu.
2. **Ouvrir sa fiche.** Double-cliquez sur la ligne, puis cliquez sur l'onglet « Utilisateur ».
3. **Lire ses postes.** « Postes associes » liste les postes liés à ce compte. Sélectionnez-en un et cliquez sur « Ouvrir le poste ».

> [!ASTUCE] Plus court : clic droit sur la ligne de l'utilisateur dans les résultats, puis « Rechercher le poste associe ».

> [!RESULTAT] La fiche du poste de l'utilisateur est ouverte.

## Parcourir une OU

Quand : vous voulez voir tous les postes ou tous les utilisateurs d'un site ou d'un service.

1. **Choisir l'OU.** À gauche de la page « Rechercher », dans « Parcourir les OU », dépliez l'arbre et cliquez sur une OU. Son contenu s'affiche dans la liste.
2. **Régler la portée.** Décochez « Inclure les sous-OU » pour ne voir que le premier niveau.
3. **Filtrer.** Dans « Type d’objet », choisissez par exemple « Machines ». Dans « Présence réseau », choisissez « En ligne » ou « Sans réponse au ping ».
4. **Compléter la liste.** Si le compteur indique une liste limitée, cliquez sur « Charger la suite ».
5. **Revenir au domaine entier.** Cliquez sur « Tout le domaine ».

> [!RESULTAT] La liste montre les objets de l'OU choisie.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Saisis au moins … caracteres, ou * pour un apercu. » | Tapez au moins deux caractères. |
| « Aucun résultat affiché » | Vérifiez l'orthographe et les filtres, ou cliquez sur « Tout le domaine ». Une liste vide ne prouve pas l'absence de l'objet. |
| « La liste affichée nʼest plus la recherche courante : relancez la recherche. » | Relancez la recherche, puis cliquez de nouveau sur « Charger la suite ». |
| « Fiche » est grisé dans le menu | Sélectionnez d'abord une ligne dans les résultats. |

# 2 Ouvrir la fiche d'un poste et agir dessus

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

![Onglet « Actions » du poste : « Ping », « Bureau à distance », « Ouvrir C$ », consoles et « Commande PowerShell »](fig:actions-poste)

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

## Que faire d'un point d'attention

| Point d'attention | Que faire |
|---|---|
| Pas de redémarrage depuis plus de 30 jours, ou redémarrage en attente | Convenez d'un redémarrage avec l'utilisateur. |
| Disque système presque plein | Libérez de la place avec l'utilisateur (« Ouvrir C$ », chapitre 2). Sinon, prévenez l'administrateur. |
| Horloge décalée, mot de passe machine ancien, compte ordinateur désactivé | Prévenez l'administrateur. |
| Poste sous Windows 10 | Le poste est à migrer. Prévenez l'administrateur. |

> [!RESULTAT] Vous savez si le poste est sain et quels points traiter en premier.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Pas encore de donnees » | Cliquez sur « Inventaire rapide ». |
| Une section indique « Inventaire complet requis : » | Cliquez sur « Inventaire complet ». |
| Un widget affiche « Non lu » | L'information n'a pas pu être lue. Relancez l'inventaire. Si elle reste absente, prévenez l'administrateur. |
| Le tableau se vide quand vous choisissez un autre objet | C'est normal : il montre toujours le poste sélectionné. Relancez l'inventaire sur le nouveau poste. |

# 4 Savoir qui est connecté sur une liste de postes

Quand : vous cherchez sur quel poste travaille un utilisateur, ou quels postes d'un service sont allumés.

1. **Préparer la liste.** Affichez les postes voulus dans « Rechercher » : OU, recherche ou « Dans les résultats » (chapitre 1). Seuls les postes affichés sont interrogés : une liste courte va plus vite.
2. **Pinger la liste.** Pour savoir seulement quels postes répondent, cliquez sur « Pinger la liste ». La demande « Pinger les postes affiches » donne le nombre de postes. Cliquez sur « Pinger ».
3. **Ou détecter les utilisateurs.** Pour savoir aussi qui est connecté, cliquez sur « Détecter la liste ». La demande « Detecter sur les resultats affiches » donne le nombre de postes. Cliquez sur « Verifier les sessions ».
4. **Ou analyser les postes.** Pour connaître aussi leur matériel, cliquez sur « Analyser la liste ». La demande « Analyser les postes affiches » donne le nombre de postes. Cliquez sur « Analyser ». En plus de l'utilisateur, Domenia lit le modèle, la mémoire, le disque C:, la version de Windows et la date de démarrage de chaque poste.
5. **Suivre l'avancement.** La ligne sous les boutons suit l'avancement, quatre postes au plus à la fois, jusqu'à « Ping termine » ou « Releve termine ».
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

# 5 Voir l'état du parc depuis l'Accueil

Quand : vous voulez une vue d'ensemble des postes d'un site ou d'un service.

La vue d'ensemble suit l'OU choisie dans « Rechercher » : il n'y a qu'un seul choix d'OU dans Domenia. Elle ne fait qu'afficher ; les pings, détections et analyses se lancent dans « Rechercher », sur la liste affichée.

## Lire la vue d'ensemble

1. **Choisir l'OU.** Dans « Rechercher », cliquez sur l'OU de votre site ou de votre service dans l'arbre (chapitre 1). Depuis l'Accueil, le bouton « Changer dʼOU » ouvre directement cet arbre.
2. **Ouvrir l'Accueil.** Cliquez sur « Accueil » dans le menu, ou appuyez sur Ctrl+D. La carte « Vue d ensemble du parc » se recalcule pour l'OU choisie, sans interroger les postes.
3. **Vérifier le périmètre.** La ligne « Périmètre » affiche le nom de l'OU, avec ses sous-OU si la case « Inclure les sous-OU » est cochée dans « Rechercher ». Avec « Tout le domaine », elle affiche « Tout le domaine indexe (consultation) ».
4. **Lire les widgets.** « Actualiser » recalcule la vue à la demande, toujours sans interroger les postes.

![Accueil : vue d'ensemble du parc pour l'OU Postes de Lyon, choisie dans Rechercher, et widgets du parc](fig:accueil)

| Section | Ce que vous y lisez |
|---|---|
| « Inventaire du perimetre » | « Postes actifs », « Postes inactifs (90 j et plus) », « Postes sous Windows 10 », « Utilisateurs detectes », « Derniere analyse ». |
| « Repartition » | Systèmes, ancienneté de la dernière connexion au domaine, postes par OU, présence réseau. |
| « Releves WMI » | Modèles, versions de Windows, mémoire installée, espace libre sur C:, postes non redémarrés depuis 30 jours. |

> [!RESULTAT] La vue d'ensemble montre les postes de l'OU choisie dans « Rechercher ».

## Mettre à jour les chiffres des postes

Quand : vous voulez des chiffres à jour sur la présence, les utilisateurs et le matériel des postes de l'OU.

1. **Afficher les postes.** Dans « Rechercher », choisissez l'OU et affichez ses postes, par exemple avec « Type d’objet » sur « Machines ».
2. **Lancer.** Cliquez sur « Pinger la liste », « Détecter la liste » ou « Analyser la liste », puis confirmez (chapitre 4). « Analyser la liste » remplit aussi la section « Releves WMI ».
3. **Revenir à l'Accueil.** À la fin du relevé, la vue d'ensemble se recalcule d'elle-même.

> [!RESULTAT] Les widgets du parc montrent l'état des postes analysés de l'OU.

## Mettre à jour la base du parc

Quand : la vue d'ensemble semble incomplète, ou des postes récents n'y figurent pas.

1. **Ouvrir la base.** Cliquez sur « Outils » dans le menu, puis sur l'onglet « Base autonome », ou appuyez sur Ctrl+I. La carte « Base autonome DOMENIA » s'affiche.
2. **Mettre à jour.** « Mettre a jour les changements » relit seulement les objets modifiés : c'est rapide. « Mettre a jour tout » relit tous les utilisateurs et les postes, parfois en plusieurs minutes.
3. **Revenir à l'Accueil.** La vue d'ensemble se recalcule d'elle-même avec la base à jour.

![Outils, onglet « Base autonome » : boutons de mise à jour et cadre « Emplacement et sauvegarde »](fig:base-autonome)

> [!RESULTAT] La vue d'ensemble compte tous les postes actifs du périmètre.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| La vue ne montre pas la bonne OU | Choisissez l'OU dans l'arbre de « Rechercher », ou cliquez sur « Changer dʼOU ». |
| « Vue d ensemble non calculee : base occupee, reessayez dans un instant. » | Attendez quelques secondes, puis cliquez sur « Actualiser ». |
| « Aucune base autonome active : vue d ensemble indisponible. » | Prévenez l'administrateur. |
| La section « Releves WMI » est vide | Dans « Rechercher », affichez les postes de l'OU, puis cliquez sur « Analyser la liste ». |

# 6 Personnaliser un tableau de bord

Quand : vous voulez garder sous les yeux les informations utiles. Chaque tuile ou graphique d'un tableau de bord (poste, Accueil, logiciels) est un widget ; Domenia garde votre disposition.

## Ajouter un widget

1. **Ouvrir la fenêtre.** Cliquez sur « Ajouter un widget » dans la barre du tableau. La fenêtre « Ajouter un widget » s'ouvre.
2. **Chercher l'information.** Tapez un mot dans la recherche (disque, utilisateur, BitLocker…) : la liste des informations se réduit. Le badge « affiche » signale une information déjà sur le tableau.
3. **Choisir.** Cliquez sur une ligne. L'« Apercu » montre le widget.
4. **Régler.** Modifiez au besoin le « Titre », la « Representation » (« Chiffre cle », « Jauge », « Anneau », « Barres »…), la « Taille » et la « Section ». Pour une nouvelle section, choisissez « + Nouvelle section... » et tapez son nom dans le champ qui apparaît.
5. **Ajouter.** Cliquez sur « Ajouter » : le widget apparaît à la fin de sa section. Hors personnalisation, un widget encore sans données reste masqué et la barre affiche « Widget enregistre : il s affichera des que ses donnees seront lues. ». « Annuler » ne change rien.

![Fenêtre « Ajouter un widget » : recherche, liste des informations, réglages à droite et aperçu du widget « Disque systeme »](fig:editeur-widget)

> [!NOTE] Une ligne « Requetes WMI · » interroge les postes. Sur le tableau du poste, cliquez sur « Actualiser les requetes », puis sur « Verifier les sessions » : le widget se remplit. Sur l'Accueil, ces requêtes partent avec « Analyser la liste » dans « Rechercher ».

> [!RESULTAT] Le widget est enregistré sur le tableau, dans la section choisie.

## Déplacer, redimensionner ou retirer

1. **Passer en personnalisation.** Cliquez sur « Personnaliser ». Chaque widget porte deux boutons ronds, modifier et retirer ; une tuile « Ajouter ici » termine chaque section.
2. **Déplacer.** Glissez un widget et lâchez-le sur un autre : il prend sa place, même dans une autre section. Le clic droit propose aussi « Deplacer ».
3. **Changer la taille.** Clic droit sur le widget, « Taille », puis « Compacte », « Moyenne » ou « Large ». Le sous-menu « Representation » change le type de graphique.
4. **Retirer.** Cliquez sur le bouton rond dont l'infobulle commence par « Retirer : », ou faites un clic droit, « Retirer du tableau de bord ». Aucune confirmation n'est demandée.
5. **Terminer.** Cliquez sur « Terminer ».

![Tableau du poste en personnalisation : boutons ronds sur chaque widget et tuiles « Ajouter ici » au bout des sections](fig:personnaliser)

> [!ASTUCE] Le clic droit et le glisser-déposer marchent aussi hors personnalisation ; les boutons ronds apparaissent alors au survol.

## Revenir en arrière

1. **Annuler la dernière modification.** Après un changement, la barre du tableau le rappelle, par exemple « Widget retire », avec le bouton « Annuler ». Cliquez dessus : la disposition précédente revient.
2. **Revenir à la disposition d'origine.** En personnalisation, cliquez sur « Par defaut ». Ce retour s'annule lui aussi avec « Annuler ».

> [!ATTENTION] « Annuler » ne revient qu'une étape en arrière et disparaît dès que de nouvelles données arrivent ou que vous choisissez un autre objet. Vérifiez le tableau avant de passer à autre chose.

> [!RESULTAT] Le tableau affiche vos widgets, dans l'ordre et à la taille choisis.

## Si ça ne se passe pas comme prévu

| Vous voyez | Que faire |
|---|---|
| « Aucun widget » | Tous les widgets ont été retirés. Cliquez sur « Ajouter un widget », ou sur « Personnaliser » puis « Par defaut ». |
| Un widget affiche « En attente » | Sur le tableau du poste, cliquez sur « Actualiser les requetes ». Sur l'Accueil, lancez « Analyser la liste » dans « Rechercher ». |
| « Requetes du parc : dans Rechercher, affichez les postes puis Analyser la liste. » | Les requêtes de l'Accueil partent de « Rechercher » : affichez les postes de l'OU, puis cliquez sur « Analyser la liste ». |
| Un widget vide n'apparaît plus | Il réapparaît quand ses données sont lues ; « Personnaliser » le montre. |

# 7 Consulter les logiciels d'un poste

Quand : vous devez savoir si un logiciel est installé sur un poste, dans quelle version et pour qui.

1. **Ouvrir l'onglet.** Dans « Poste », cliquez sur l'onglet « Logiciels ». La carte « Logiciels installes » s'affiche.
2. **Choisir l'étendue.** « Par utilisateur », cochée par défaut, ajoute les logiciels de chaque profil. Cochez « Applications Store » pour le Microsoft Store (plus long), « Mises a jour » pour les correctifs et composants système.
3. **Charger.** Cliquez sur « Charger les logiciels ». Chaque ligne donne le « Nom », la « Version », l'« Editeur », « Installe le », la « Taille » et la « Portee ».
4. **Chercher un logiciel.** Tapez une partie du nom, de l'éditeur ou de la version dans « Filtre ». « Portee » limite la liste à « Machine », « Utilisateur » ou « Store ».
5. **Lire la synthèse.** Le volet « Synthese en graphiques » résume la liste : nombre, éditeurs, versions multiples, architecture, portée et plus gros logiciels.
6. **Transmettre.** « Copier » copie la liste complète ; « Exporter CSV » l'enregistre dans un fichier dont le chemin s'affiche dans le « Journal de session » (« Logiciels exportes : … »).

![Onglet « Logiciels » : liste des logiciels du poste et volet « Synthese en graphiques » déplié](fig:logiciels)

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

## Prévenir l'administrateur

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
| OU (unité d'organisation) | Dossier de l'AD qui range les postes ou les comptes, par exemple par site ou par service. |
| Périmètre | OU choisie dans l'arbre de « Rechercher » ; la vue d'ensemble du parc la suit. |
| Base autonome | Copie locale de l'annuaire, gardée par Domenia ; elle sert à la vue du parc et se met à jour depuis « Outils ». |
| Ping | Test réseau : le poste répond-il ? Une absence de réponse ne prouve pas qu'il est éteint. |
| Utilisateur console | Personne connectée sur l'écran du poste, hors Bureau à distance. |
| Association | Lien mémorisé entre un utilisateur et un poste. Ce n'est pas la preuve d'une session ouverte. |
| WMI | Interface de Windows qui permet de lire à distance les informations d'un poste. |
| Widget | Tuile ou graphique d'un tableau de bord (poste, parc ou logiciels), que vous pouvez ajouter, déplacer ou retirer. |
| Lecture seule | Mode de départ de Domenia : consultation, sans modification de l'annuaire ni des postes. |

## À propos de ce guide

Le guide administrateur décrit l'installation, les comptes, la configuration, la base autonome et les cas particuliers.
