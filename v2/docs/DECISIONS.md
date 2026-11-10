# Décisions de David pour Domenia 2

Chaque décision est datée. Une décision plus récente remplace une décision antérieure sur le même sujet.

## 10 novembre 2026 — lectures distantes avec le compte choisi

Après un blocage d’inventaire avant WMI avec un compte saisi qui fonctionnait dans Domenia 1, David confirme :
« Oui, laisser le poste décider pour les lectures ». Cette décision étend celle du 9 novembre : les lectures
avec compte de connexion explicite, compte saisi, compte temporaire ou local sont tentées avec cette seule identité.
Le poste accepte ou refuse ; aucune appartenance à Domain Admins ni preuve locale préalable n’est exigée pour lire.
Les secrets absents, comptes suspendus, changements de session et de sélection restent bloquants ; aucun repli
vers un autre compte. Les écritures distantes conservent leur validation d’administration et leurs plans confirmés.
Application préparée en 2.1.4 ; qualification sur domaine réel à faire.

## 10 novembre 2026 — version lisible dans l’interface

David demande une version courte, par exemple « 2.1.3 », sans la longue identité de compilation.
L’affichage utilise désormais la version produit. L’identifiant complet reste utilisé pour vérifier les packs,
les contrats de livraison et les journaux, et reste disponible dans la copie des informations techniques.

## 9 novembre 2026 — le poste décide, pas le groupe Domain Admins

David, en production avec un compte hors Domain Admins : « juste voulu mesurer les postes en ligne ! c quoi ce relogin
qui marche meme pas en plus ». En 2.1.0, le relevé de présence de l’Accueil, le ping de la fiche, celui du poste et
l’écho de Rechercher exigeaient le même rôle d’administration que la lecture WMI, puis proposaient « Utiliser un autre
compte » validé sur le premier poste de l’OU, souvent éteint. L’inventaire s’arrêtait au premier poste sans
validation explicite, une validation par poste.

À partir de 2.1.1 :

- ping et DNS ne demandent aucun compte d’administration : ils n’envoient aucun identifiant au poste ;
- choix de David (« Laisser essayer ») : une lecture distante faite avec l’identité de la session Windows (inventaire,
  console, sondes, journaux, logiciels, sessions, fiche, Rechercher, requêtes, relations, audit) est tentée sans
  contrôle préalable de Domain Admins. Domenia ne manipule aucun mot de passe ; le poste accepte si le compte y est
  administrateur, sinon le refus est compté pour ce poste et la campagne continue ;
- un compte saisi (connexion par compte explicite, compte temporaire ou local) garde sa validation, comme toute
  écriture distante (exécution, tâches planifiées, nettoyage des tâches de lecture).

## 8 novembre 2026 — plus de GitHub dans les mises à jour

David : « et aussi tu va virer github pour la maj dans le logiciel ». À partir de 2.1.0, **Paramètres → Mises à jour** ne
propose plus que le dossier de diffusion et le ZIP local, chacun avec `SHA256SUMS.txt`. Le client HTTP, la lecture des
releases GitHub et leurs tests sont retirés ; la préparation refuse toute autre source. Le lien vers le pack WebView2 du
Socle, affiché quand aucun moteur n’est trouvé, reste : il n’est pas une mise à jour et rien n’est téléchargé.

## 8 novembre 2026 — seuls les packs PROD-LIGHT sont publiés

Décision de David relayée par la session GLPI, appliquée dans le candidat en cours (« Dans ce candidat ») : on ne publie
plus que le pack **PROD-LIGHT**. Pour la livraison, elle remplace la décision du 21/10 « Pack PROD autonome ».

- Moteur WebView2, dans cet ordre : Evergreen installé ; sinon `wad\runtime\webview2` extrait du pack commun du Socle
  (M4D135/socle-windows, release `webview2-156.0.4314.42`), comparé fichier par fichier à l’index épinglé dans Domenia ;
  sinon un message clair propose Evergreen ou l’extraction du Socle, avec le lien. Aucun téléchargement.
- Le runtime .NET privé reste embarqué dans le pack.
- La CI de livraison ne construit, ne teste et ne conserve que le ZIP PROD-LIGHT ; ses contrôles navigateur utilisent
  l’Evergreen installé du runner. `tools/build-vm.ps1` garde seulement un pack PROD interne de labo, jamais zippé.
- La suppression des anciens ZIP PROD et DEV publiés revient à la session GLPI.
- Une mise à jour conserve l’édition installée : un poste en PROD 2.0.8 doit réextraire le ZIP PROD-LIGHT à la main.

## 26 octobre 2026 — carte de connexion en 2.0.3

David demande de publier le resserrement de la carte du compte, icône centrée avec la légende et l’identité. La version est **2.0.3**. Les packs, le tag et les preuves 2.0.2 restent immuables. Ce changement de présentation ne relance ni la collecte AD ni le ping. Le [guide 2.0.3](RECETTE-MANUELLE-V2.0.3.md) décrit les observations sans résultat prérempli. Une qualification 2.0.2 ne couvre pas les octets 2.0.3.

## 26 octobre 2026 — second retour, collecte et connexion

Après réception des packs 2.0.1, David signale que plusieurs parcours restent défaillants et transmet son journal. La tuile « Comptes actifs » est un exemple, pas une limitation du périmètre. Les corrections suivent l’ordre demandé : code complet, contrôles GitHub, VM en mode domaine à la toute fin. Son autorisation d’intégrer la v2 sur la branche principale demeure ; la v1 reste dans l’historique.

Le lot correctif porte la version **2.0.2**, pour conserver immuables les publications précédentes. Les vérifications de paquets préparent des artefacts et ne prouvent ni recette humaine ni validation du domaine. Le [rapport de ce lot](reprise/rapports/RAPPORT-CORRECTIFS-COLLECTE-LOGIN-20261026.md) sépare développement et preuves réellement acquises ; le [guide de recette 2.0.2](RECETTE-MANUELLE-V2.0.2.md) accompagne les packs sans préremplir les résultats. Aucune dérogation historique de recette VM ne vaut succès pour ce lot.

## 26 octobre 2026 — correctifs de recette Windows, équipe Codex

David demande une reprise directe de `codex/v2-finalisation-20261025` depuis GitHub et autorise explicitement les agents Codex. La branche dédiée est `codex/v2-correctifs-recette-20261026`. Les anciens modes Spark/OpenCode ne s’appliquent pas à cette reprise.

L’interface doit être stable et lisible : les pictogrammes fonctionnels, logos et formulaires restent en place, y compris avec les animations normales. Cette décision remplace les demandes antérieures d’animations permanentes. Après un échec de lecture AD préalable, aucune nouvelle collecte dépendante ne part ; l’ancien repli automatique sur le cache pour ping/WMI est retiré.

Les packs correctifs PROD/DEV **2.0.1** sont préparés pour une nouvelle recette manuelle, avec contrôles Windows critiques réellement exécutés après commit/push, manifestes et empreintes des archives exactes. La release 2.0.0 et son tag sont conservés. Les deux VM et le domaine réel indisponibles ne bloquent pas ces corrections ni la livraison manuelle ; leurs validations restent `not-run`. Cette autorisation ne modifie pas la garde stricte `release-guard.py` et ne constitue aucun succès métier. Voir [recette ciblée 2.0.1](RECETTE-MANUELLE-V2.0.1.md).

Les contraintes de sécurité, d’isolation, d’intégrité, de dépendances déjà présentes, de `dev/` en lecture seule et d’écriture dans la seule OU de test demeurent applicables.

| Date | Sujet | Décision | Mise en œuvre |
|---|---|---|---|
| 21/10 | Interface | WebView2 seule, « master site » très animé, « web 4.0 », propre et soigné ; rien perdu, tout amélioré | `web/`, animations riches par défaut, réglage riches / réduites / suivre Windows |
| 21/10 | Langage | Réécriture complète en C# (.NET 10 LTS autonome) | `src/` |
| 21/10 | Portabilité | Pack PROD autonome : dézipper et lancer, rien à installer (runtime .NET et WebView2 fixe embarqués) | `tools/build-vm.ps1 -Publish` |
| 21/10 | Tests | Écrits au fil du code, exécutés à la toute fin ; compilation permise à tout moment | `tests/` |
| 21/10 | Poste de travail | Développement et compilation dans la VM Windows ; en cas d'échec de la VM, lancement en simulation sans AD autorisé directement sur le PC de test | `docs/SIMULATION.md` |
| 21/10 | Mesure active | « Fais au plus intelligent » : l'état de chaque widget est mémorisé dans les préférences locales de l'application (nouvelle classe d'opération `LocalWrite`, jamais d'écriture AD), avec un fichier de préférences séparé en simulation | en place, tests écrits non exécutés : `dashboard.widget.setEnabled` (`LocalWrite`), `preferences.json` / `preferences-simulation.json` (`FilePreferenceStore`, écriture atomique), interrupteur « Mesure active » de l’Accueil |
| 21/10 | Auth.DemoProvider | « Ok, fais au mieux » : `Auth.DemoProvider=true` dans `Domenia.config.json` démarre aussi en simulation (raison « configuration ») | en place, tests écrits non exécutés : `ModeResolver`, après `--simulation` et `DOMENIA_SIMULATION`, avant l’appartenance au domaine |
| 21/10 | Fin de support Windows | Non retenue (« balec ») | — |
| 21/10 | OU de travail | « Au plus pratique et logique » : OU de travail globale, choisie dans un panneau d'arborescence avec recherche, mémorisée ; elle sert de défaut aux sections sans choix propre (comme Domenia 1) ; surcharge par section prévue ensuite | en place, tests écrits non exécutés : panneau « Choisir l’OU » de l’Accueil (`#/accueil?ou=choisir`), `directory.ou.children` / `search`, `session.setScope` mémorisé par domaine ; surcharge par section à faire |
| 21/10 | Catalogue | Construire `docs/FEATURES.md` à partir de tout Domenia 1 | en cours |
| 21/10 | Livraison | Une fois tout terminé : pack Windows prêt à l'emploi (ZIP à dézipper et lancer, simulation incluse), publié en release GitHub | à faire en fin de chantier |
| 21/10 | Labo | « Tu peux faire ce que tu veux sur les labos » : écritures AD réelles autorisées dans le labo `cnamts.local`, regroupées dans une OU de test dédiée (`OU=Domenia-Tests`) pour ne pas gêner les autres projets qui partagent ce domaine | vague 4 |
| 21/10 | Accueil | Pas de salutation par prénom (« Bonjour Julien ») : l'opérateur se connecte avec un compte d'administration, pas à son nom. Le titre devient le périmètre (ex. « Vue d'ensemble · OU Postes ») et le compte (ex. `EXAMPLE\\adm-jmartin`) apparaît en puce ; la simulation utilise un compte de type admin | en place : titre « Vue d’ensemble · OU … » ou « · Domaine … », puce du compte, `account.givenName` plus utilisé ; compte de la session simulée `EXAMPLE\adm-j.martin` (générateur, `session.info`, `OPERATIONS.md`, `SIMULATION.md`, aperçu du navigateur, tests écrits non exécutés) |
| 21/10 | Écritures en simulation | Écritures testables en simulation, sans effet réel : elles s’appliquent à une surcouche en mémoire de l’annuaire fictif, vue par toutes les lectures, jamais enregistrée ; reçus marqués « simulé ». Le garde d’admission admet la classe `Write` en simulation (surcouche seulement) et en mode annuaire (circuit complet : plan, confirmation, reçu avant l’envoi, relecture), pour la seule opération `write.execute` | en place le 22/10, tests écrits non exécutés : `docs/WRITES.md`, `OPERATIONS.md` § 12 (`accounts.unlock.plan`, `write.execute`, `write.receipts.*`), `SimulatedDirectoryOverlay`, `receipts-simulation.jsonl` ; `session.info.readOnly` vaut `false` en simulation et la bannière le dit |
| 22/10 | WAPT | « Vire cette histoire de WAPT » : le connecteur WAPT (PST-001) est abandonné, ainsi que toute mention de WAPT (service WAPTService des sondes, fournisseur WAPT des faits de mise à jour PST-034 : Windows Update seul) | fait |
| 22/10 | Catalogue, statut `partiel` | « Fais au mieux, prends les meilleures décisions et avance un maximum » (décisions de la relève sur cette délégation) : le statut `partiel` est gardé, en plus de `a-faire`, `fait`, `ameliore` et `abandonne` : la fonction est commencée et ce qui reste à faire est écrit sous elle | `FEATURES.md` (légende, synthèse), `features.json`, `CLAUDE.md` |
| 22/10 | Coffre Windows (CPT-017) | « Fais au mieux, prends les meilleures décisions et avance un maximum » (décisions de la relève sur cette délégation) : parité avec Domenia 1, Gestionnaire d’identification de Windows pour les comptes Postes et Secrets, sur geste explicite seulement (« Mémoriser sur ce PC », « Utiliser le coffre », « Oublier le mot de passe »), jamais en simulation ni au démarrage | avec la garde d’authentification de la vague 3 ; d’ici là, case grisée avec sa raison |
| 22/10 | Mémorisation des relations (REL-014, 017, 018, 030) | « Fais au mieux, prends les meilleures décisions et avance un maximum » (décisions de la relève sur cette délégation) : pas de mémorisation sans confirmation ; un plan collectif scellé par le moteur (TRV-229, comme les lots de Comptes) : une seule confirmation pour les observations en attente, puis un plan par lot de 64 exécuté à la suite, un reçu par lot | écran Utilisateurs et postes |
| 22/10 (soir) | Mémorisation des relations (REL-014, 017, 018, 030), remplace la ligne précédente | Choix de la relève du 22/10 au soir (`REPRISE.md` § 0), sur la même délégation (« Fais au mieux, prends les meilleures décisions et avance un maximum »), à appliquer sauf avis contraire de David : c’est la base locale, pas l’AD ; mémorisation automatique par lots de 64, comme Domenia 1, sans confirmation, tracée au journal | fait le 22/10 : `relations.observations.save` (`LocalWrite`), appelée à la fin de la détection, de la lecture de session, du relevé et de la moisson, et par la page après 1,5 s de calme ; chaque lot appliqué avec les règles d’un plan, une ligne du journal des associations par changement ; suite C# 791/791 en VM |
| 22/10 | Exports et ouverture de documents | « Fais au mieux, prends les meilleures décisions et avance un maximum » (décisions de la relève sur cette délégation) : écrire un fichier demandé par l’opérateur (export, document, dossier) est `LocalWrite` ; l’ouvrir ou le montrer (association de Windows, Explorateur) est `Local` | `OPERATIONS.md` § 1, `PLATFORM.md` § 3.2 |
| 25/10/2026 | Livraison PROD/DEV v2.0.0 et recette manuelle | David autorise la préparation et la livraison de v2.0.0 sans attendre la recette critique domaine/UI/native dans les deux VM indisponibles ; il effectuera la recette à la main. Cette dérogation ne constitue aucune validation des parcours non exécutés. | Décision détaillée ci-dessous ; [livraison finale](LIVRAISON-FINALE.md), [recette manuelle v2.0.0](RECETTE-MANUELLE-V2.0.0.md). |

## 25 octobre 2026 — livraison v2.0.0 avec recette manuelle par David

Décision explicite de David : « si go sans ces tests vm, on peut pas, je testerai a la main du coup ».

Pour **PROD/DEV v2.0.0**, David autorise la préparation et la livraison manuelles sans attendre les validations critiques domaine/UI/native dans les deux VM. Il prend en charge la recette manuelle du pack livré. Cette décision remplace, pour cette livraison, leur caractère bloquant avant publication ; les consignes et rapports antérieurs restent l’historique de la décision précédente.

La preuve acquise reste liée au SHA `1e877d650df71b37716b0b0840726238f632db7d` : [job GitHub Actions 121263620296 du run 40224745081](https://github.com/M4D135/domenia-d120/actions/runs/40224745081/job/121263620296), compilations Windows Debug/Release sans erreur ni avertissement, **587 tests C# critiques réussis sur 587** et **15 contrôles Python critiques réussis sur 15**, code de sortie `0`. Les états `domain`, `ui` et `twoVM` restent **`not-run`** ; aucune recette manuelle n’est déclarée réussie à la date de cette décision.

La dérogation ne modifie ni `release-guard.py`, ni son contrat strict, ni ses preuves. Sans dossier conforme des deux VM, l’outil doit continuer à refuser `eligible:true`. L’autorisation humaine est consignée séparément ; aucun reçu, rapport ou statut de test n’est fabriqué pour la représenter.

Les exigences d’intégrité des archives, de provenance du commit et de SHA256 restent applicables, ainsi que l’isolation de la démonstration et des profils, les plans/confirmations/reçus, l’absence de rejeu des écritures, l’exclusion de WAPT et `dev/` en lecture seule. Aucune dépendance téléchargée, aucun changement de service/runtime/réseau, aucun reboot ou logoff n’est autorisé par cette décision. Toute écriture AD reste limitée à `OU=Domenia-Tests,DC=cnamts,DC=local`.


## 01/11/2026 — L18, adaptation du démarrage D1 à Domenia 2

Dans le périmètre de la reprise des lots, le chargeur de scripts est remplacé par un plan d’assemblages et de modules
compilé, fermé et vérifié avant composition. Chaque module déclare ses exports dans son assemblage. Les vérifications
portent sur les versions, identités et origines réellement chargées ; aucune compilation ou relance PowerShell n’est
réintroduite. TRV-034 devient le contrôle des bibliothèques livrées, selon l’arbitrage déjà retenu pour Domenia 2.

Le SHA du pack reste strict, fins de ligne comprises ; la limite de 4096 fichiers reste nécessaire aux runtimes privés.
La racine vient seulement de la base compilée (exe et wad en production), jamais de CWD, HKCU ou des anciens alias ROOT.
L’icône est embarquée. `--check-only` rend 0/1 ; les refus interactifs gardent 2. La signature Windows est contrôlée
localement sans réseau : absence de signature explicitement admise pour les packs actuels, autres échecs bloquants.

Les journaux BCL de démarrage sont distincts du journal applicatif, locaux et bornés. Ils ne couvrent pas les pannes du
chargeur natif/CLR avant Main. L’activation est consommée une fois par fenêtre et respecte le premier plan extérieur et
les changements de session. Les tests écrits et limites de validation sont détaillés dans
[le rapport L18](reprise/LOTS-CODEX-20261101/L18.md) ; aucune recette VM ni certification éditeur n’est impliquée.

## 01/11/2026 — L19, présentation et fermeture

Les adaptations de démarrage V2 sont précisées dans [L19](reprise/LOTS-CODEX-20261101/L19.md) : précontrôle WebView2,
inventaire des contrôles essentiels, préparation différée locale sans collecte, disponibilité après rendu réel. Le format
de connexion validé 1024 × 660 est conservé avec bornage DPI. La démonstration reste un contexte fictif isolé permettant
les parcours complets ; les descriptions D1 incompatibles sont reformulées, les références historiques conservées.
La fermeture a des délais d’attente indépendants de la coopération des travailleurs et ne dispose pas leurs ressources
avant leur fin réelle. Une donnée non committée n’est jamais déclarée sauvegardée. Qualification Windows en attente.
