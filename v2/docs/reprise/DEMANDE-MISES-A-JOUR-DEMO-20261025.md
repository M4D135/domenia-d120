# Extension autorisée par David le 25 octobre 2026

La pièce jointe ci-dessous a été explicitement adoptée pour Domenia v2 après clarification : « L’intégrer à Domenia v2 maintenant ». Elle étend la livraison en cours. Adapter aux objets Active Directory et à l’exécutable unique existants ; aucun second lanceur ni métier de tickets n’est déduit des exemples conditionnels. Les validations restent dans les VM et après le développement.

PROMPT — MISES À JOUR DU PRODUIT ET DÉMONSTRATION COMPLÈTE

Tu reprends le projet ouvert dans cet espace de travail. Intègre réellement les deux ensembles décrits ci-dessous : un système de mise à jour du produit et un mode démonstration complet sur données fictives. Va jusqu’aux tests, aux packs et à la documentation. Ce texte définit la cible : ne suppose pas que ces fonctions existent déjà dans GLPI Pilot ou dans le projet cible sans vérifier le code et les preuves.

CONTEXTE À COMPLÉTER OU À DÉDUIRE DU PROJET
- Projet et dépôt officiel : [NOM / URL]
- Exécutable Standard : [Projet.exe]
- Exécutable Admin, si le projet en possède un : [Projet-Admin.exe]
- Dossier des ressources livrées : [wad ou équivalent]
- Profil et données des utilisateurs : [emplacement existant]
- Données métier diffusables séparément : [sites, référentiels, modèles…]
- Partage de diffusion : [\\serveur\partage\Projet]
- Objets métier à démontrer : [tickets, dossiers, clients, interventions, commandes…]
- Utilisateurs et rôles de démonstration : [agents, techniciens, responsables…]
- Parcours clés : [tableau de bord, fiche complète, calendrier, traitement, recherche…]
Conserver le langage, l’architecture, les conventions, l’installation et les mécanismes éprouvés du projet. Ne pas créer une réécriture complète pour ajouter la mise à jour.

1. PRENDRE CONNAISSANCE ET AVANCER
Lire les consignes applicables, inspecter Git, les fichiers modifiés, le système de construction, les versions et la mise à jour existante. Préserver les changements locaux et les données. Identifier les fonctions déjà présentes et compléter les manques. Proposer les choix qui nécessitent réellement une décision ; réaliser de façon autonome les travaux autorisés et réversibles. Ne pas attendre une confirmation à chaque étape. Ne pas effacer ou réinitialiser une base réelle pour tester.

2. TROIS SOURCES DE MISE À JOUR
A. GitHub officiel : lire les Releases du dépôt attendu, retenir une publication stable compatible, sélectionner son ZIP PROD et son empreinte SHA-256. Vérifier les domaines et redirections attendus. Pas de téléchargement exécuté silencieusement.
B. Dossier réseau partagé : permettre de configurer un chemin UNC ou un dossier local accessible, puis mémoriser ce choix. Utiliser les droits de la session Windows ; ne pas demander ni enregistrer un mot de passe SMB. Le partage contient le ZIP PROD complet et SHA256SUMS.txt. L’application lit le partage, copie le pack dans un dossier temporaire local, contrôle sa copie et prépare l’installation locale. Elle n’exécute pas l’application depuis le partage et n’y écrit pas.
C. ZIP local : conserver ou ajouter la sélection manuelle d’un pack avec les éléments de provenance nécessaires. Ne pas contourner la vérification parce que le ZIP est local.

Afficher clairement la source choisie, la version installée, la version proposée, la taille et le résultat des contrôles. Une coupure réseau, un accès refusé, une archive incomplète ou un manifeste incohérent donne une erreur compréhensible et une possibilité de réessayer. Le logiciel installé reste utilisable. Ne pas basculer silencieusement vers une autre source.

Pour un partage contenant plusieurs versions, comparer les versions correctement, choisir la plus récente compatible et refuser les ambiguïtés. Ignorer les fichiers temporaires et les packs DEV. Le diffuseur doit copier sous un nom temporaire puis renommer après transfert, et publier le manifeste en dernier ; le client vérifie de toute façon les octets reçus. Aucune installation automatique au seul motif qu’un nouveau ZIP apparaît.

3. CONTRAT DU PACK
Convention proposée, à adapter aux conventions déjà établies :
  Projet_1.2.3_PROD_Windows-x64.zip
  Projet_1.2.3_DEV_Windows-x64.zip
  SHA256SUMS.txt

PROD contient l’application immédiatement utilisable, les ressources, les dépendances nécessaires, les licences et un guide. DEV utilise les mêmes exécutables de livraison et ajoute les sources, tests, scripts et instructions de reconstruction. Ne pas livrer des sources seules sous le nom PROD. Les exécutables et le dossier de ressources doivent se trouver directement à la racine du ZIP, sans niveau de dossier inutile.

Inclure des métadonnées de version : projet, version, architecture, type PROD/DEV, commit source, empreintes des exécutables et versions utiles des dépendances. Inclure un inventaire SHA-256 des fichiers du pack. Vérifier la couverture exacte, les doublons, la casse Windows, les chemins absolus et traversées, les noms réservés, liens/jonctions, tailles et ratios de décompression excessifs. Ne pas livrer secrets, profils SSO, données personnelles, bases actives, clés ou journaux privés.

Distinguer intégrité et authenticité : un SHA-256 placé à côté du ZIP détecte une incohérence, mais ne protège pas contre un acteur capable de remplacer les deux. Utiliser le dépôt officiel ou un partage administré avec des droits d’écriture restreints ; appliquer la politique de signature de l’éditeur lorsqu’elle existe. Ne pas inventer de certificat ni annoncer une signature absente. Ne jamais désactiver TLS pour faciliter une connexion.

4. INSTALLATION ET RETOUR ARRIÈRE
Réutiliser le mécanisme transactionnel existant si possible :
- préparer et vérifier l’intégralité du nouveau pack localement ;
- conserver l’ancienne installation et un journal de transaction durable ;
- terminer les écritures en cours et fermer proprement l’application ;
- utiliser un assistant séparé si le système empêche de remplacer l’EXE actif ;
- remplacer uniquement les fichiers gérés, sans toucher aux données personnelles ;
- lancer la version installée et vérifier sa santé par un accusé lié à cette transaction ;
- considérer la mise à jour comme réussie seulement après cette vérification ;
- restaurer l’ancienne version si le remplacement ou le démarrage échoue ;
- conserver les preuves et sauvegardes si la restauration elle-même est empêchée.
Prévoir une reprise après interruption. Ne pas tuer arbitrairement les processus d’un autre utilisateur. Ne pas remplacer un pack encore utilisé par un second lanceur Admin. Le retour arrière explicite suit aussi les vérifications d’intégrité et de compatibilité.

Ne pas confondre retour arrière des binaires et restauration d’une base. Une migration de données doit disposer de son propre contrat de compatibilité et de sauvegarde ; ne pas restaurer aveuglément un ancien schéma sous un binaire récent, ou l’inverse.

5. STANDARD ET ADMIN, SI APPLICABLE
Si deux lanceurs sont demandés, conserver un code commun et produire :
  Projet.exe
  Projet-Admin.exe
  wad/ (ou dossier de ressources commun)

Le distributeur peut retirer Projet-Admin.exe avant de fournir le pack aux agents. L’exécutable Standard doit refuser les commandes d’administration dans le moteur ; masquer un bouton ne suffit pas. Ne pas déduire l’autorité d’un nom de fichier, d’une requête de l’interface, d’une variable utilisateur ou d’un flag que la Standard pourrait créer. Une capacité fixée à la compilation convient.

La mise à jour d’une installation sans lanceur Admin ne doit pas réintroduire ce lanceur. Lorsqu’il est installé, son remplacement et son retour arrière sont vérifiés avec le reste du pack. Vérifier le premier passage depuis une ancienne version : si son vérificateur refuse le nouveau contrat à deux EXE, documenter une migration manuelle par extraction complète dans un nouveau dossier, sans contourner les contrôles.

Ne pas stocker des identifiants administrateur dans la connexion de travail des agents. Les droits réels du serveur restent contrôlés côté serveur ; deux EXE ne remplacent pas cette séparation.

6. PATCHES DE RÉFÉRENTIELS INDÉPENDANTS
Permettre de diffuser les sites ou autres référentiels sans reconstruire l’application. Préférer l’import/export métier existant. Définir et documenter un format versionné, borné, sans code exécutable, accompagné de son empreinte. L’application doit pouvoir trouver ce patch sur le même partage que les ZIP.

Avant application, montrer la version ou l’empreinte, les ajouts, modifications, éléments identiques et conflits. Garder les identifiants métier stables pour préserver les liens des tickets, interventions et tournées. Ne pas supprimer les éléments absents du patch par défaut. Une suppression ou un renommage ambigu exige une décision explicite et une vérification des références. Protéger les corrections locales ; les conflits ne doivent pas être écrasés silencieusement.

Faire une sauvegarde, vérifier que le contexte n’a pas changé depuis l’aperçu, appliquer de manière atomique et enregistrer l’empreinte appliquée. Rejouer le même patch doit être sans effet supplémentaire. Un patch invalide, périmé, trop volumineux, modifié pendant la lecture ou destiné à une autre application doit être refusé sans modification partielle. Aucun script, formule ou macro n’est exécuté. Garantir un aller-retour exact des valeurs : téléphones +33, apostrophes, coordonnées négatives et alias contenant | ou ; ne doivent pas être altérés par l’échappement CSV. Utiliser un encodage versionné réversible et testé si nécessaire, distinct d’un export générique pour tableur.

L’Admin peut préparer le patch validé pour diffusion. La Standard peut appliquer un patch de référence approuvé sans obtenir les pouvoirs d’administration du serveur. Une modification du référentiel ne doit pas déclencher une modification distante des tickets.

7. MODE DÉMONSTRATION COMPLET, ISOLÉ ET CRÉDIBLE
Ajouter une entrée visible « Ouvrir la démonstration ». Son but est de faire découvrir et essayer tout le produit, avec les mêmes écrans, calculs et règles métier que le fonctionnement normal. Une bannière persistante « Démonstration — données fictives » doit rester visible. Ne pas se limiter à quelques cartes statiques, captures ou chiffres codés en dur.

Préparer une vraie base locale isolée ou un espace de stockage dédié à la session de démonstration. Créer des données cohérentes, entièrement inventées, sans reprendre les vrais utilisateurs, tickets, textes, pièces jointes, secrets ou historiques du poste. Utiliser des noms explicitement fictifs et des domaines réservés tels que example.invalid ; aucune personne réelle ne doit être contactée.

Jeu de données de référence à adapter au métier :
- environ 60 objets principaux complets (quelques dizaines au minimum), répartis entre plusieurs statuts, priorités, catégories et périodes ;
- environ six utilisateurs fictifs avec des rôles, affectations et disponibilités distincts ;
- quatre sites, services ou équipes fictifs, avec relations, contacts et horaires cohérents ;
- des fiches détaillées avec description, historique, commentaires, tâches, documents synthétiques si le produit les gère, et solution ou compte rendu pour les objets terminés ;
- un calendrier déjà rempli : activités passées terminées, activités du jour, rendez-vous futurs, indisponibilité et série récurrente ;
- des tournées, lots ou projets selon le métier : au moins un terminé, un prêt et un en préparation, liés aux objets et personnes du jeu de données ;
- quelques notes personnelles, listes de contrôle, favoris, éléments en attente et rappels pour montrer les usages quotidiens.

Les relations doivent être valides : identifiants stables, références existantes, états et dates compatibles, durées plausibles. Les tableaux de bord doivent être calculés à partir de ces données et se mettre à jour quand une action modifie la démo. Prévoir des cas utiles : affectation manquante, retard, absence d’information, conflit de planning, activité clôturée. Une donnée volontairement manquante reste signalée comme telle.

Ancrer les dates autour du jour d’ouverture pour que le calendrier ne paraisse pas vide dans six mois. Prévoir une horloge et une graine contrôlables dans les tests pour rendre les scénarios reproductibles. Le réensemencement doit être idempotent ou recréer proprement un espace neuf ; il ne doit jamais accumuler les mêmes tickets ou rendez-vous à chaque ouverture.

Permettre les actions métier dans cet espace : modifier une affectation, ajouter un commentaire, créer une intervention, déplacer un rendez-vous, terminer une tâche, préparer une tournée ou exercer les autres parcours du produit. Les mutations doivent passer par les moteurs et validations normaux, en écrivant uniquement dans les données de démonstration. Les calculs, filtres, recherches, fiches et historiques suivent ces modifications réelles de la base fictive.

Remplacer les intégrations externes par des adaptateurs locaux de démonstration. Une collecte navigateur, synchronisation serveur, écriture distante, notification, envoi de message ou mise à jour de logiciel doit produire un résultat fictif explicite, sans atteindre le vrai service. La simulation d’une mise à jour peut changer la version affichée dans l’espace de démo et permettre un retour arrière fictif ; elle ne doit jamais remplacer les binaires du produit. Bloquer côté moteur la préparation d’une base distante réelle, les partages de diffusion réels et l’application d’un patch au référentiel réel depuis la démo. Masquer les boutons ne suffit pas.

Par défaut, la démo doit fonctionner hors ligne avec ses ressources locales. Si une ressource facultative, comme un fond de carte, utilise un service externe, le signaler et demander l’accord propre à cette fonction ; conserver une alternative locale et ne transmettre aucune donnée du poste. Aucun cookie, profil SSO, identifiant ou mot de passe réel ne doit être copié dans la démo.

Préserver exactement le contexte normal : préférences, identité choisie, source active, relevé chargé, notes, base locale, file de synchronisation et données du serveur. Terminer ou annuler proprement les opérations en cours avant la bascule ; une réponse tardive ne doit pas s’appliquer dans le nouvel espace. « Quitter la démonstration » retrouve le contexte précédent. « Réinitialiser la démonstration » recrée uniquement ses données fictives. Les exports explicitement demandés par l’utilisateur peuvent être conservés à l’emplacement choisi et doivent porter clairement leur caractère fictif. Aucun transfert implicite de données de démo vers la production.

Respecter les pouvoirs des lanceurs : la Standard reste Standard en démonstration, elle ne devient pas Admin. L’Admin peut exercer les parcours administratifs sur les seules données fictives quand un scénario local existe ; les opérations réelles restent interdites depuis cet espace.

Si le produit importe des CSV ou Excel de travail, distinguer ces imports du mode démonstration. Un fichier réel est une source de données ordinaire ou de secours. Les fonctions nécessitant des détails absents de l’export sont désactivées avec une explication, aussi dans le moteur ; ne pas inventer ces détails. L’import d’un fichier réel depuis la démo doit basculer explicitement vers le contexte normal approprié, sans mélanger les bases. Une sélection annulée ou un fichier refusé conserve le contexte courant.

8. VALIDATION À RÉALISER
Adapter les tests au comportement et aux risques, pas à la seule structure du code. Couvrir au minimum :
- publication officielle valide, absence de nouvelle version et mauvais dépôt ;
- partage valide, indisponible, refusé et interrompu pendant la copie ;
- ZIP altéré, hash incorrect, doublons, traversée de chemin, architecture ou version incompatible ;
- sélection du PROD quand un DEV et plusieurs versions sont présents ;
- installation complète, échec de démarrage, rollback et reprise après interruption ;
- préservation des réglages, notes, bases et profils ;
- Standard refusant une commande Admin appelée directement ;
- mise à jour Standard sans réinstallation de l’EXE Admin et mise à jour Admin cohérente ;
- patch métier ajouté/modifié, conflit, identifiants conservés, annulation et application répétée ;
- démonstration complète : fiches, calendrier, utilisateurs, activités terminées et indicateurs réellement alimentés ;
- action métier dans la démo modifiant uniquement la base fictive et les indicateurs associés ;
- absence d’appel aux services réels, y compris par commande directe du pont ou API interne ;
- entrée/sortie/réinitialisation de démo, conservation octet pour octet des données réelles pertinentes, absence de doublons ;
- bascule pendant une sauvegarde, requête tardive, annulation d’import et redémarrage ;
- maintien des droits Standard/Admin dans la démo ;
- calendrier de démo utile après changement de date et scénarios de tests reproductibles ;
- reconstruction à partir du DEV exporté ;
- concordance du commit, des métadonnées et des empreintes des fichiers réellement publiés.

Utiliser une base et des données fictives isolées. Les tests locaux ne prouvent pas une exécution Windows native ni un accès SMB réel : qualifier sur la cible disponible et indiquer exactement ce qui reste non vérifié. Ne pas relancer des suites longues déjà passées sans changement ou nouvelle raison.

9. DOCUMENTATION ET LIVRAISON
Fournir un guide utilisateur court : choisir GitHub ou le partage, vérifier la version, installer, retrouver le bilan et revenir à la version précédente. Fournir un guide de diffusion : fichiers exacts à déposer, ordre de copie/renommage, permissions attendues, retrait éventuel du lanceur Admin et publication d’un patch de référentiel. Inclure un exemple d’arborescence et un exemple de manifeste sans données privées. Documenter aussi l’ouverture, la sortie, la réinitialisation et les limites de la démo, ainsi qu’un petit parcours de présentation de cinq minutes.

Le rapport final doit dire précisément : changements réalisés, versions et commit, tests réellement exécutés, publication effectuée ou non, limitations restantes et liens vers les packs réellement disponibles. Ne pas annoncer un pack prêt tant que les archives exactes diffusées n’ont pas été contrôlées. Respecter les autorisations de publication propres au projet.

Commence par l’audit du projet et poursuis les deux ensembles, mises à jour et démonstration, jusqu’à une livraison vérifiable. Ce travail inclut le code, les tests appropriés, les packs et les guides ; ne t’arrête pas à une proposition d’architecture.
