# Domenia 2 — document de reprise

Ce document permet de reprendre le chantier si Claude Code n'est plus disponible (panne de jetons), par exemple avec
OpenCode et une clé de l'API Claude. Il est tenu à jour à chaque étape importante. Dernière mise à jour : **23/10/2026, Codex : reprise active, lecteur Fiche, accès et coffre raccordés, transports et écritures en cours**.

## 0. Reprise active — Codex, 23/10/2026

- Demande actuelle : exécuter `docs/reprise/PROMPT-CODEX.md` jusqu’à la release `v2.0.0` ; aucune release finale publiée à ce stade.
- Démon `_pilotage/spark/auto.py`, processus OpenCode Domenia et vérifications automatiques résiduelles arrêtés. Aucun service LLM du Spark arrêté ou installé.
- Inventaire : six branches `spark/*` existent, la tâche 07 n’a pas commencé. Seuls 03 (comptes/LDAP, 1 142 lignes applicatives environ) et 04 (CIM, 1 547 lignes environ) ont du code. 01/02 : notes ; 05/06 : aucun code. Aucune fusion globale : les brouillons ne sont pas qualifiés.
- Sauvegarde Git autonome vérifiée des six branches et de `v2-spark` : `/Users/david/Documents/Codex/2026-10-23/go-x20/work/domenia-reprise-20261023/spark.bundle`. Tous ces arbres étaient propres après arrêt. Ne pas les supprimer.
- VM vérifiée : alias `domenia-vm`, invité `FILPRO-W11B`, console Administrateur active, 17,6 Gio libres. Session conservée.
- Première correction du socle : relecture LDAP limitée au DN et à la profondeur choisis ; refus racine/hors domaine/DN invalide ; `session.info`, lecture locale et index local d’OU sans réseau ; index d’OU indépendant de l’image de la branche et invalidé au changement de session ; SID et date WMI mal formés traités comme illisibles.
- Validation de ce lot : `vm.sh main build --config both`, Debug et Release **0 erreur, 0 avertissement**. Dix tests `AdBoundaryTests` ajoutés et compilés, **pas encore exécutés** (recette après développement). Aucune écriture AD effectuée.
- Deuxième lot : `session.connect` (`NetworkRead`, geste explicite dans Comptes) et lecteur réel du schéma `AdSchemaReader` ; partition contrôlée, projections sans valeurs d’objet, pagination, sentinelle de troncature, budget total, catalogue incomplet explicite. Cinq tests supplémentaires écrits et compilés. Debug/Release **0 erreur, 0 avertissement** ; tests et recette AD non exécutés à ce stade.
- David autorise la poursuite directe avec Codex après interruption du transport Spark (synthèse documentaire sans réponse finale validée), puis demande explicitement une finition détaillée et une recette sur les VM domaine et Domenia.
- Branche 03 relue : non fusionnée (identité Windows conservée après changement de compte LDAP, mappage SID incomplet, appels Windows incorrects, journal de sécurité non implémenté). Branche 04 : compilation du brouillon réussie dans un lot VM isolé ; récupération sélective des collecteurs CIM, avec correction de la garde WQL/MSI, des plafonds, budgets, annulations, résultats partiels et données absentes. Ce collecteur n’est pas encore branché à tous les lecteurs d’écran ; les sources de registre/WTS restent à développer. Aucun statut du catalogue promu pour ce brouillon.
- Troisième lot compilé : collecteurs CIM récupérés et corrigés, sélecteur local `AdMachineAccountReader` et essai unique `WmiMachineAccessProbe` branchés par découverte. Mot de passe gardé en `SecureString`, refus du secret absent pour un compte explicite, erreurs d’authentification distinctes. Dix nouveaux tests écrits et compilés (garde WQL/MSI, budgets/annulation, données partielles, provenance locale, compte explicite). `vm.sh main build --config both` : **0 erreur, 0 avertissement**. Tests non exécutés à ce stade ; pas de validation AD réelle revendiquée.
- Quatrième lot : `winsqlite3.dll`, paramètres liés, transactions, sauvegarde SQLite incluant le WAL et empreinte SHA-256, schéma **11/1** repris des sources Domenia 1 (tables de bibliothèque et tables additives comprises), refus des bases futures/étrangères, migration additive après sauvegarde. Relectures AD mises en JSONL haché, vérifiées puis commises avec reçu idempotent ; aucune suppression sur résultat partiel. Projections historiques `ad_objects`/`domenia_directory_data` conservées et mises à jour ; lecture d’index local (dates françaises, profondeur directe et accents). Choix du stockage historique (Compatible/UserLocal/Portable, préférences et dossiers de domaine) repris ; cache de recette isolé. Le démarrage relit le cache sans LDAP et ne prétend pas être connecté ; la relecture annuaire est publiée après stockage. **14 nouveaux tests écrits et compilés**, non exécutés ; Debug/Release **0 erreur, 0 avertissement**. Restent notamment l’import des projections historiques vers tous les lecteurs, les observations et recettes, les plans de maintenance et l’écran Synchronisation complet.
- Cinquième lot : `AdAccueilReader` raccordé ; faits locaux et sondes restaurés, historique quotidien Domenia 1 avec profondeur conservée, présence BitLocker sans secret (100 000 objets/180 s, profondeur directe respectée), inventaire ciblé sans second ping et sondes du catalogue (6 postes simultanés, 60 s par poste, exclusions DC). Sauvegarde native vérifiée avant relecture AD ; refus si moins de 512 Mio libres. Présence/inventaire/console/BIOS/sondes/BitLocker enregistrés transactionnellement dans la projection additive v2, puis publiés ; mesures terminées conservées après annulation, dernière lecture réussie préservée 15 minutes lors d’un refus tout en gardant l’échec daté. Les comptes de collecte partielle ne sont plus annoncés réussis. **14 tests ajoutés, écrits et compilés seulement** ; Debug et Release **0 erreur, 0 avertissement** (preuve `docs/reprise/rapports/build-codex-accueil-2026-10-23.txt`). L’import des observations D1 et leur projection complète restent à faire ; aucun test exécuté ni validation AD réelle revendiqués.
- Sixième lot de socle : `AdObjectAccess` pour les relectures exactes (500 GUID au plus, paquets de 40, 90 s), refus des identités imprévues/dupliquées/hors domaine et des SID illisibles ; contrôle de tri LDAP demandé et réponse de tri vérifiée. Les dates absentes des résultats de recherche restent nulles. **5 tests ajoutés et compilés seulement** ; Debug/Release **0 erreur, 0 avertissement** (preuve `docs/reprise/rapports/build-codex-identites-2026-10-23.txt`). Ce socle est prêt pour Rechercher/Fiche ; ces lecteurs ne sont pas encore raccordés.
- Septième lot : périmètre explicite des relevés ; un census d’OU ne fournit plus de faux totaux de comptes du domaine, les widgets d’une autre OU restent non mesurés, un relevé partiel ne donne plus un bilan sain. Les compteurs de l’arbre de navigation restent inconnus tant que les objets n’ont pas été lus. Quatre tests de couverture ajoutés et un test LDAP renforcé, compilés seulement. Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-couverture-2026-10-23.txt`.
- Huitième lot : `AdSearchReader` découvert automatiquement ; recherches LDAP texte/identité/syntaxe/contient, listes et vues, tri serveur obligatoire, reprise par nom AD brut avec gestion des homonymes et passes exact/préfixe/ANR. Conteneurs directs et compteurs bornés sur demande, relecture par GUID sans ressusciter les objets absents depuis le cache. Suggestions/aperçus/comparaisons/requêtes d’observations/adresses en lecture locale ; reprise des recherches enregistrées D1. Lectures ciblées stockées après sauvegarde sans remplacer le repère de census ; dates conservées par objet et résultats tardifs écartés. Ping unique, DNS inverse 15 s, diagnostic TCP sans authentification ; inventaires de recherche 15/30 s (sans processus/MSI), identité CIM vérifiée, disque système réel, IPv4 et masque, adresses et inventaire typé persistés. **11 tests ajoutés et compilés seulement** ; Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-rechercher-2026-10-23.txt`. La qualification sur AD réel, les repères invocationId/USN de réconciliation, le compte secondaire/WSMan partagé et l’import des anciennes observations D1 restent à vérifier/raccorder avec les lots concernés. Aucun statut du catalogue promu.
- Contrôle direct de l’infrastructure : depuis `FILPRO-W11B`, découverte de `dc01.cnamts.local` (`10.77.0.10`) et canal sécurisé `cnamts.local` réussis (`NERR_Success`), console Administrateur toujours active. Cela ne remplace pas la recette fonctionnelle AD, encore à faire.
- Neuvième lot : contacts AD conservés sans SID ni compte inventé ; recherches mixtes, filtre Contacts, aperçu local, relecture GUID et stockage SQLite daté. Le relevé d’une OU inclut désormais cette cinquième classe et reste incomplet si elle est tronquée ou illisible. Quatre tests supplémentaires écrits et compilés, deux gardes de périmètre étendues à la cinquième requête. Debug/Release **0 erreur, 0 avertissement** ; tests toujours réservés à la recette finale.
- Dixième lot : correction de l’énumération réelle des attributs LDAP (`SearchResultAttributeCollection.Values`, la collection directe énumère des entrées de dictionnaire). Liste explicite d’attributs exigée, secrets et jokers refusés avant connexion ; budget global de requête ; tranches limitées à 50 000 valeurs, continuité et GUID/USN contrôlés, aucune liste tronquée présentée complète. Option de tranches explicites pour la Fiche et contrôle owner/DACL sans SACL. Quatre tests écrits et compilés, dont la vraie collection .NET ; Debug/Release **0 erreur, 0 avertissement**, exécution différée à la recette finale.
- Onzième lot : lecture exacte commune Fiche/Comptes/préconditions (`AdFicheObjects`) : DN contrôlé, base unique, attributs permis par l’objet puis noms sensibles exclus avant demande, stabilité GUID/USN entre les deux lectures, budget de 10 s, projection binaire GUID/SID/hexadécimal et première tranche d’appartenances explicitement incomplète. Lecture de compte refusée sans UAC lisible, aucun recours au cache pour une précondition. Métadonnées internes masquées de la grille brute. Cinq tests supplémentaires écrits et compilés ; Debug/Release **0 erreur, 0 avertissement**. Ce socle n’est pas encore un lecteur Fiche complet ; raccordement des écrans en cours.
- Douzième lot : `AdAccountsReader` découvert en mode annuaire : listes à 5 000 comptes + sentinelle, DN/profondeur préservés, détail et candidats par lectures exactes, stockage avant publication, absence d’UAC jamais convertie en compte actif. Journal 4740 réel par `wevtapi.dll` (aucune dépendance téléchargée), PDC contrôlé ou contrôleur lié annoncé, SID/fenêtre exacts, 200 événements + sentinelle, budget 30 s, poignées libérées après fin réelle, compte de connexion copié en `SecureString` sans repli silencieux. Liste partielle expliquée durablement dans la page et dates absentes nulles. **Neuf tests supplémentaires écrits et compilés**, Debug/Release **0 erreur, 0 avertissement**. Tests et recette native/AD toujours non exécutés ; accès secondaires/coffre/bascule et écritures restent à développer.
- Treizième lot : cache brut de Fiche SQLite sous GUID, résumé indexé, dates par objet, empreintes du contenu et de l’index contrôlées ; migration additive après sauvegarde, aucune création de base sur lecture locale. Une lecture ancienne ne rétablit pas un ancien DN après déplacement ; secrets, identités incohérentes et fiches hors domaine refusés. Quatre tests écrits et compilés, Debug/Release **0 erreur, 0 avertissement** (preuve `docs/reprise/rapports/build-codex-fiche-cache-2026-10-23.txt`). Le lecteur Fiche complet reste à raccorder ; aucun test exécuté à ce stade.
- Quatorzième lot : `AdFicheReader` raccordé (aperçu/index locaux, lecture exacte et GUID, enfants, membres par tranches, graphe borné, PSO, connexions par DC, ACL owner/DACL et historique de réplication, 4740 partagé). Lecteur WTS natif en consultation seule ; protocole et horloges corrigés selon le SDK, session de bureau jamais modifiée. Tri CIM 10 s avec échantillon CPU daté et disque système réel ; cache arbitré par date/GUID, groupes partiels sans faux retraits, refus de sessions sans fausse absence. **Treize tests ajoutés et compilés seulement**, Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-fiche-lecteur-2026-10-23.txt`. Restent dans les prochains lots : associations D1, repli WTS/CIM, comptes secondaires/WSMan/registre, écritures et recette native/AD. Aucun test exécuté ni statut du catalogue promu.
- **Quinzième lot Codex : identité de connexion** : le compte explicite est résolu par UPN exact ou domaine/SAM vérifié, jamais par le SID du bureau. Une identité étrangère ou ambiguë ne devient pas un homonyme local. Les groupes ne prouvent plus une délégation et le protocole Kerberos n’est plus annoncé sans mesure. Chaque connexion et chaque contrôleur possède sa copie sécurisée indépendante ; un compte explicite incomplet est refusé sans repli Windows. Réinitialiser la session écarte les résultats de connexion tardifs. **Cinq tests ajoutés et compilés seulement** ; Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-identite-2026-10-23.txt`. Bascule effective et coffre dans le lot suivant.
- **Seizième lot Codex : accès réels et bascule** : `AdAccountsAccessReader` valide une seule connexion, identifie le domaine et le compte, puis adopte la connexion vérifiée atomiquement. Échec, annulation, domaine étranger ou résultat périmé préservent l’ancienne session. La correction consomme une preuve du même secret, valable 30 s, sans second bind. Les copies encore détenues par des comptes secondaires, des contrôleurs ou des lectures natives maintiennent la pause après correction. Validation LDAP, essai CIM, WTS et journal natif limitent leurs travailleurs ; les secrets et poignées restent détenus jusqu’au retour réel. Compte local lié au poste dont le nom a été relu ; aucun FQDN étranger ne retombe sur un homonyme local. Sous-codes d’authentification traduits sans exposer le diagnostic serveur. **Onze tests ajoutés et compilés seulement** ; Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-acces-2026-10-23.txt`. Restent le coffre, la saisie native des mots de passe, la propagation des comptes à tous les transports et les écritures.
- **Dix-septième lot Codex : saisie native et coffre** : les cinq gestes d’identification de Comptes passent en fenêtre native en mode annuaire ; le pont refuse leur champ JSON `password`. Simulation conservée. Coffre Windows compatible avec les clés D1, aucune lecture automatique, choix de mémorisation décoché, authentification réussie puis preuve de 60 s à usage unique et opérations `LocalWrite` séparées. Retrait explicite par compte/usage, retour partiel si plusieurs usages ne peuvent pas tous être traités. Fermeture LDAP à la sortie de l’application. Corrigé aussi le passage du secret de réinitialisation Fiche : il était effacé par `FormClosed` avant `TakeEntry` ; la copie acceptée est désormais prise avant fermeture, puis transférée une fois ou libérée. Fenêtres modales sérialisées, annulation et fin du propriétaire gérées. **Huit tests ajoutés et compilés seulement** ; Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-coffre-saisie-2026-10-23.txt`. Restent la recette native (fenêtres/coffre), les saisies de réinitialisation Comptes et des autres modules, les transports explicites/secondaires, puis les écritures.
- **Dix-huitième lot Codex : dernières saisies natives** : réinitialisation Comptes et compte poste passent eux aussi par les fenêtres natives en mode annuaire. Le pont refuse même un champ JSON `password: null`, avant tout lecteur ou exécuteur ; une saisie devenue caduque après changement de session est écartée. La simulation conserve son contrat. Un test supplémentaire couvre les six refus (trois opérations, secret nul ou fourni), compilé seulement. Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-saisies-restantes-2026-10-23.txt`. Recette native et raccordement unifié des comptes aux transports encore à faire.
- **Dix-neuvième lot Codex : compte des transports** : Comptes et Compte poste partagent désormais les comptes secondaires et temporaires, leurs baux et leurs pauses ; priorité au compte saisi après les temporaires. Les essais et les libellés utilisent cette même cascade. Copie du compte de connexion atomique avec contrôle de session ; aucun repli Windows si un secret explicite manque. Fiche (WTS et CIM), Rechercher, inventaire léger et sondes Accueil transmettent le compte choisi, conservent leur copie jusqu’au retour natif et écartent les résultats si le compte change. Six travailleurs CIM communs au plus, sans file d’attente illimitée ; codes d’authentification natifs distincts des droits refusés, pause partagée et pas de répétition du secret rejeté. Sondes liées au nom de poste confirmé ; disque système inconnu sans supposition de `C:`. **Huit tests ajoutés et compilés seulement**, Debug/Release **0 erreur, 0 avertissement**, preuve `docs/reprise/rapports/build-codex-comptes-transports-2026-10-23.txt`. Restent notamment le repli WTS/CIM, WSMan/registre, les lecteurs réels restants, les écritures et la recette complète.
- Catalogue constaté : **993 entrées : 483 faites, 216 améliorées, 69 partielles, 224 à faire, 1 abandonnée**. Aucun statut requalifié sur la seule base d’une compilation.
- Suite : terminer la revue des deux brouillons, brancher les lecteurs/écritures réels et SQLite, traiter les branchements et le catalogue ; ensuite tests C#, E2E simulation et labo limité à `OU=Domenia-Tests`, puis packs, SHA-256 et release.

### Historique de la relève du 22/10 (conservé ; les constats ci-dessus priment)


- **Étape 3 en cours (22/10 au soir, Claude Code) : E2E simulation 71 → 80 → 124 réussis sur 137** (2e passe : 12 échecs,
  1 ignoré ; rapport local du Mac seulement). Corrigé, commité, poussé :
  - harnais : casse imposée par le CSS ignorée (texte du document exigé avec sa casse), texte SVG et `textarea` lus,
    U+2011 lu « - », départ sans `hashchange` (script `Start`), démarrage sans élément racine ; `E2E.md` à jour ;
  - produit : focus du catalogue et des poignées (Accueil), refus de contexte sans erreur de console (Comptes), profil
    de collecte envoyé par erreur à chaque clic (Paramètres), arbre du kit défilé (clic perdu), menus qui suivent leur
    bouton au défilement, notifications au-dessus du pied des panneaux, requête locale de l’adresse sur l’OU de travail
    et phrase de sélection après un filtre (Rechercher), lignes du journal technique de Requêtes (comptes et
    identifiants seulement) ;
  - scénarios périmés : libellés, confirmation « Confirmer (simulation) », `adm-j.martin`, éléments masqués vérifiés
    par `absent`, grilles virtualisées.
  - Restent (2e passe, avant les derniers commits) : comptes/droits-detail (étape 4), comptes/perimetre (étape 7),
    fiche/deplacer-et-relire, fiche/historique-recu, synchro/controles-verifier (étape 11) ; les autres échecs de la
    2e passe sont corrigés après elle, à relancer.

- **Étape 2 faite (22/10 au soir, Claude Code)** : suite C# en VM **791 réussis sur 791**, 0 avertissement (Debug et Release).
  - Requêtes (2 tests) : ils prenaient la première OU par ordre alphabétique (« Comptes de service », sans poste) ; ils
    prennent l’OU Postes (`RequetesOperationsTests.WorkstationsOuAsync`).
  - Relations (2 tests) : la graine couvrait presque tous les postes ; 30 % des postes restent sans association semée
    (`SimulatedRelationSeed.UnassignedShare`), pour l’import et la moisson.
  - **Choix de la relève appliqué (point 2 ci-dessous)** : mémorisation automatique des observations dans la base locale,
    par lots de 64, sans confirmation, avec les règles d’un plan (`SaveObservationsAsync`, opération
    `relations.observations.save` en `LocalWrite`, appelée à la fin de `relations.detect.run`, `relations.computer.read`
    et `relations.harvest.run`, et par la page après 1,5 s de calme) ; une ligne du journal des associations par
    changement, une au journal des opérations. `DECISIONS.md`, `ops/relations.md`, `OPERATIONS.md` à jour ; REL-014,
    017, 018 et 030 à « fait ». `apply_status.py` ne double plus la ligne « partiel » de la légende.
  - E2E simulation `relations/*` : 9 réussis sur 12 (moisson-enregistrer, releve-ou et parcours-captures passent) ;
    restent ajouter-association (étape 19), comparer-groupes (étape 2) et session-poste (étape 5), déjà en échec avant.
  - Commits `a2e8330`, `024adf8`, `8d13e8a` (poussés). Les autres E2E de `docs/reprise/e2e-sim-1-echecs.txt` ne sont pas
    relancés.
  - Reste de l’ordre ci-dessous : fin du point 2 (échecs E2E de simulation), puis points 3 à 5. Tests unitaires à écrire :
    `AdDirectoryMapper`, `AdDirectoryReader.Interval`, `WmiWorkstationProbe.ParseDmtf` et `Classify`.

- **Étape 1 faite (22/10 au soir, Claude Code)** : `v2-wip-annuaire` terminée, compilée et fusionnée dans `v2`.
  - Ajouts : `Domenia.Ad/AdDirectoryReader.cs` (domaine : RootDSE, objet domaine, crossRef, contrôleurs des sites,
    conteneurs ; image de l’annuaire : 4 recherches paginées par 1 000, bornées à 50 000 par type, image incomplète
    signalée), `Domenia.Ad/AdDirectoryMapper.cs` (attributs de `SIMULATION.md` § 3.3 vers `Domenia.Core`, LAPS : dates
    seulement), `Domenia.Inventory/WmiWorkstationProbe.cs` (ping, inventaire léger WMI en lecture : OS, ordinateur,
    disque système ; délais bornés ; refus distingué de l’erreur ; traces au journal).
  - `AdConnection.TechnicalTrace` branché sur `TechnicalLog.Warning` dans `Program.Main` ; jet Spark s2 corrigé
    (`Controls`, `connection.Timeout`, ordre du constructeur de `SearchRequest`, `Aliases`, `DirectoryAttributeOperation`).
  - Compilation VM : lot `v3-annuaire` Debug et Release, puis `main` Debug et Release : 0 erreur, 0 avertissement.
    Aucun test exécuté ; aucun essai réel sur `cnamts.local`. Simulation non modifiée.
  - Reste de l’ordre ci-dessous : points 2 à 5.

- **Spark autonome (22/10, 20 h 15)** : le démon `../Domenia-D120-team/_pilotage/spark/auto.py` tourne sur le Mac.
  - Il fait passer les tâches `_pilotage/spark/tasks/*.md` par OpenCode et le modèle local, deux à la fois, avec vérification automatique (`verify.sh`) et une relance après échec.
  - Les tâches validées sont fusionnées dans la branche **`v2-spark`**, recompilées et retestées, puis poussées.
  - **Suivi de relève : `v2/docs/reprise/SUIVI-SPARK.md` sur `v2-spark`**, plus `v2/docs/reprise/spark/<tâche>.md` sur chaque branche `spark/<tâche>`.
  - Pour reprendre, relire `git log origin/v2..origin/v2-spark`, puis fusionner `v2-spark` dans `v2`.
  - Pour relancer le démon : `cd ../Domenia-D120-team/_pilotage/spark && nohup python3 auto.py &`. Son état est dans `state.json`, son journal dans `auto.log`.
- **Spark arrêté** : les 14 tâches `ask.sh` lancées par la relève sont stoppées (17 h 55).
  - Neuf attendaient depuis 30 à 80 minutes sans rien recevoir.
  - s1-sqlite, s3-reader et s4-adwrites tournaient en boucle de raisonnement (135 000 à 167 000 jetons, aucune sortie), s6-probe aussi sans sortie.
  - Seule s2-ldap avait répondu (déjà intégrée dans `v2-wip-annuaire`), copie dans `../Domenia-D120-team/_pilotage/s2-ldap.out`.
  - **Ne pas relancer de tâches Spark de cette taille.** Faire rédiger directement par le modèle de la relève (API Claude), une tâche à la fois.
- **Choix faits par Claude sur les 4 questions de la relève**, à appliquer sauf avis contraire de David :
  1. **CPT-017, coffre Windows** : oui, comme Domenia 1 (CredRead, CredWrite, CredDelete), par gestes explicites seulement, indisponible en simulation.
  2. **Relations, mémorisation** : c'est la base locale, pas l'AD. Mémorisation automatique par lots de 64, comme Domenia 1, sans confirmation, tracée au journal. La tâche s5-relbatch (plan scellé) n'est plus nécessaire. **Appliqué le 22/10 au soir (étape 2).**
  3. **Exports de fichiers** : on garde la décision déjà inscrite dans `DECISIONS.md` (22/10) : écrire est `LocalWrite`, ouvrir est `Local`. Pas de classe `LocalFile`.
  4. **Statut `partiel`** : on le garde. L'ajouter à `v2/CLAUDE.md` (cinq statuts).
- **État Git** :
  - `v2` = fusion de `v2-wip-annuaire` (poussé, compile) ;
  - `v2-wip-annuaire` = `705db1f` (poussé, compile, fusionnée ; arbre `../Domenia-D120-team/v3-annuaire`) ;
  - VM : 20 Go libres, `out\\plateforme` supprimé.
- **Ordre de reprise conseillé** : § 4 bis « Suite, dans l'ordre », sans le Spark.
  1. ~~Terminer `AdDirectoryReader`, `AdDirectoryMapper` et `WmiWorkstationProbe` dans `v2-wip-annuaire`, compiler, fusionner.~~ Fait.
  2. ~~Corriger les 4 tests C# restants~~ (fait : 791/791), puis les échecs E2E de simulation (`docs/reprise/e2e-sim-1-echecs.txt` ; Relations : 3 restants).
  3. Vrai moteur écran par écran, avec les écritures de Comptes et de la Fiche et la base SQLite.
  4. E2E en mode annuaire sur `cnamts.local` (`OU=Domenia-Tests`).
  5. `vm.sh main publish`, ZIP, release GitHub.

## 1. Ce qu'est le projet

- **Domenia 1** (`dev/`, branche `master`) : outil d'administration Active Directory en Windows PowerShell 5.1 et WPF, livré et figé
  (RC1.17.39, lots R40 intégrés).
- **Domenia 2** (`v2/`, branche **`v2`**) : réécriture complète en **C# .NET 10 LTS autonome** avec une interface **HTML dans
  WebView2** (moteur fixe embarqué) et un pack « dézipper et lancer ».
- À lire avant toute chose :
  - `v2/ARCHITECTURE.md`, `v2/CLAUDE.md` ;
  - `v2/docs/DECISIONS.md` : toutes les décisions datées de David, à respecter ;
  - `v2/docs/PLATFORM.md` (ajouter un écran côté C#), `v2/docs/KIT.md` (composants web), `v2/docs/WRITES.md` (circuit des écritures) ;
  - `v2/docs/OPERATIONS.md` (contrat du pont), `v2/docs/SIMULATION.md`, `v2/docs/CAPTURE.md`, `v2/docs/E2E.md` ;
  - `v2/docs/FEATURES.md` et `v2/docs/features.json` : catalogue des 993 fonctions de Domenia 1, avec leur statut dans Domenia 2.

## 2. Exigences de David (à ne jamais perdre)

1. **Autant de fonctions que Domenia 1, voire plus.** Rien ne disparaît sans décision écrite (statut `abandonne`, une
   seule à ce jour : PST-001 WAPT, le 22/10).
2. **Interface superbe** : « web 4.0 », très animée, propre, bien organisée et bien disposée. L'Accueil sert de modèle
   (David l'a aimé). Thèmes clair, sombre et contraste élevé ; réglage des animations.
3. **Tout autonome et portable** : pack ZIP à dézipper et lancer, runtime .NET et WebView2 embarqués, sans rien à installer.
4. **Mode simulation** sans AD (`--simulation`, `DOMENIA_SIMULATION=1`, poste hors domaine, `Auth.DemoProvider=true`) :
   annuaire fictif `example.local`, écritures appliquées en mémoire seulement.
5. **Ordre de travail** : on code d'abord ; **les tests en VM se font à la toute fin** (décision du 22/10). Pendant le
   développement, la VM ne sert qu'à **compiler**.
6. **Labo** : écritures AD réelles autorisées dans `cnamts.local`, regroupées dans une OU de test dédiée `OU=Domenia-Tests`.
7. **Livraison finale** : pack Windows prêt à l'emploi publié en release GitHub.
8. Pas de salutation par prénom à l'Accueil (comptes d'administration) ; WAPT retiré.

## 3. Où en est le chantier

| Étape | État |
|---|---|
| Socle C# + WebView2, pont, mode simulation, Accueil, option `--capture` | fait (`aa7112c`, `b0bef24`) |
| Catalogue des 993 fonctions | fait (`6fc1c37`) |
| Vague 1 : kit de composants, plateforme (modules auto-découverts, préférences, OU de travail, compilation par lot) | fait (`47acdf9`) |
| Vague 2, socle : circuit des écritures, harnais E2E, capture en session de bureau | fait (`84a7ebf`) |
| **Vague 2, écrans** : 14 branches `v2-page/<écran>` (poussées sur GitHub) | **terminés** (§ 4) : les 14 écrans |
| Vague 2, intégration : fusion des 14 branches dans `v2`, statuts du catalogue | **fait** (`c7b9d09`, § 4) : 14 fusions `--no-ff`, collisions de noms résolues, statuts appliqués (462 faites, 216 améliorées, 90 partielles, 224 à faire, 1 abandonnée), Debug et Release : 0 erreur, 0 avertissement ; branchements de la coque restants (§ 4) |
| Vague 3 : vrai moteur (LDAP lecture et écriture, inventaire WMI/CIM/ping, base SQLite compatible Domenia 1, ordonnanceur à budgets, garde d'authentification, journal technique, démarrage) | **en cours** (§ 4 bis) : source du mode annuaire, connexion LDAP, lecteurs et écritures des comptes, base SQLite (winsqlite3), mesures des postes |
| Vague 4 : tests complets en VM (suites C#, scénarios E2E sur la session de bureau visible, vrai AD du labo, écritures dans `OU=Domenia-Tests`), corrections | **en cours** (§ 4 bis) : suite C# 786/791, E2E simulation 71/137 |
| Pack final et release GitHub | à faire |

## 4. Vague 2 : état des écrans

Chaque écran a sa branche `v2-page/<id>` et, sur le Mac, un arbre de travail `../Domenia-D120-team/v2-<id>`. Les rapports
des critiques indépendants sont archivés dans `v2/docs/reprise/critiques/<id>-tour<N>.md`.

| Écran (id) | Situation au 22/10 (branches poussées sur GitHub, intégrées dans `v2`) | Suite |
|---|---|---|
| shell | **Terminé** (`f4a0c5d`, relève OpenCode) : `wip` compilé, tour 1 vérifié point par point, parité refaite, moteur de tableaux complété (TRV-286, 288, 303, 314, 315, 316) ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| accueil | **Terminé** (`82087a5`, relève OpenCode) : tour 2 traité (ACC-055, 033, 026, 023, 020, 031, 039, barre du kit, une seule action principale, titres, aperçu), tests et E2E écrits ; partiels restants : vague 3 (Domenia.Store) et atelier de requêtes ; TRV-290 à 292 (collecte par widget) à faire avec l’ordonnanceur | Intégré |
| rechercher | **Terminé** (`4d6f395`, relève OpenCode) : tour 2 traité (RCH-005, 097, 126, 127, 020, réglages de l’administrateur et de Paramètres par `search.policy`, conteneurs de la racine, notices, une seule action principale), tests et E2E écrits ; partiels : vague 3 (base locale, enregistrement en fichier) et atelier de requêtes | Intégré |
| fiche | **Terminé** (`4cceb1a`, relève OpenCode) : tour 2 traité (FIC-033 état bloquant, FIC-018 nouveau DN relu par GUID, FIC-007 brouillon Compte et discard, FIC-046 et FIC-037 session par GUID, FIC-048 bandeau, Historique, concurrence de l’aperçu), défauts de design corrigés (une action principale, colonnes des groupes, exemples de la page vide, racine du domaine, couleur des OU, présence propagée, champ DN, sélecteur, insécables) ; `app.js` et `kit/glyphs.js` remis à `84a7ebf` (palette par `ctx.commands.set` du shell) ; tests et E2E écrits ; Debug et Release : 0 erreur, 0 avertissement | Intégré (surcouche de simulation fusionnée avec celle du Poste) |
| comptes | **Terminé** (`2c6fc68`, relève OpenCode) : critique du tour 1 (traitée par `9dedf45`) vérifiée dans le code, parité refaite sur CPT-001 à 021 ; compteur « Accès » de la barre du haut par `ctx.access.report` ; partiels : vague 3 (Domenia.Ad : CPT-007, 008), shell à l’intégration (CPT-001 relecture hors écran, CPT-012 panneau d’aide), coffre Windows (CPT-017, question ci-dessous) ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| relations | **Terminé** (`d13f98b`, relève OpenCode) : tour 2 traité (WAPT retiré, REL-050 export d’échange relu par l’import, aperçu d’import, relevé d’une liste sans OU, observations conservées, détection annulable, journal complet, barre de commandes du kit, une seule action principale, vue mise à jour sur place, transitions) ; tests écrits ; partiels : REL-013 (Domenia.Store), REL-029 (brancher sur les demandes d’accès de Comptes à l’intégration), REL-014, 017, 018, 030 (décision ci-dessous) ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| poste | **Terminé** (`bc97977`, relève OpenCode) : `wip(poste)` compilé (une correction), tour 1 vérifié dans le code (secrets par fenêtre native, relevés par type, inventaire partiel et réaffiché, renommage du CN seul, redémarrage sans « Maintenant » par défaut, protection « Non lu », BitLocker par GUID complet), WAPT absent de `src` et `web` ; partiels : PST-023 et 066 (vague 3), PST-111 et 113 (écran Requêtes, à brancher à l’intégration) ; Debug et Release : 0 erreur, 0 avertissement | Intégré (surcouche fusionnée avec celle de la Fiche) ; PST-111 et 113 à brancher |
| assistance | **Terminé** (`fd4c205`, relève OpenCode) : tour 2 traité (refus de l’écran expliqués dans Incidents, commande `Domenia.exe dossier` attachée à la console, contrat d’arrivée `postes=`, capture refusée pendant une lecture, suivi arrêté après trois échecs, bandeau sans lecteur, vues mises à jour sur place, CSS des panneaux préfixée) ; tests et E2E écrits ; partiels : ASS-006 (refus des autres écrans : `BridgeDispatcher` à l’intégration), ASS-012 (lien à poser dans les écrans de liste) ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| requetes | **Terminé** (`64b8228`, relève OpenCode) : `wip(requetes)` compilé sans correction, tour 1 vérifié par sondage (bibliothèque en fichier atomique par domaine, widget après revue d’impact, brouillon repris, négations LDAP, exports par le moteur, confirmations WMI, aperçu sur les correspondants, h1), journaux `.tmp-oc` retirés ; partiels déclarés : REQ-034, 039, 048 (stockage Domenia.Store, écrans Accueil/Fiche/Rechercher à brancher) ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| audit | **Terminé** (`b64ac93`, relève OpenCode) : `wip(audit)` et la revue de l’agent Spark (`5250fc2`, teinte du critique) compilés, tour 1 vérifié par sondage (garde limitée à l’objet, contrôleurs bornés, « lancer » retiré avant la lecture, CSS conforme) ; réserve : l’agent Spark a lancé une capture dans la VM ; `mock.js` et `PlatformTests` complétés à la fusion ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| schema | **Terminé** (`49c3642`, relève OpenCode) : tour 1 (traité par `c592077`) vérifié, transitions mises en conformité ; partiel : MAC-002 (pastille « Compte poste » à poser dans Poste et Intervenir à l’intégration) ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| synchro | **Terminé** (`70d8306`, relève OpenCode) : tour 1 (traité par `0ceac1d`) vérifié, une seule action principale ; fichiers partagés `kit/grid.js` et `write-flow.js` à revoir à l’intégration ; Debug et Release : 0 erreur, 0 avertissement | Intégré |
| operations | **Terminé** (`cacc514`, relève OpenCode) : tour 1 (traité par `e0385ab` : blocage global des écritures, suivi des lectures, battement de toute l’interface, pseudonymes, classes) vérifié, transitions et typographie corrigées ; partiels déclarés (ordonnanceur, collecte, annulation pré-remplie, coque) ; Debug et Release : 0 erreur, 0 avertissement | Intégré ; Ctrl L et panneau de la coque à raccorder à `operations.center` |
| parametres | **Terminé** (`c9a12ce`, relève OpenCode) : `wip(parametres)` compilé sans correction, tour 1 vérifié par sondage (app.js rendu au shell, alias des sections, journal, « ouvrir= » consommé, typographie, statuts requalifiés), règles des panneaux préfixées ; 39 partiels (base locale SQLite en vague 3, coque, réglages lus par les autres écrans) ; Debug et Release : 0 erreur, 0 avertissement | Intégré |

Questions pour David (la relève ne tranche pas, elle continue) :
- **CPT-017, coffre Windows** : brancher le Gestionnaire d’identification de Windows (CredRead, CredWrite, CredDelete) pour
  les comptes Postes et Secrets, comme Domenia 1 (« Mémoriser sur ce PC », « Utiliser le coffre », « Oublier le mot de
  passe », gestes explicites seulement, indisponible en simulation) ? En attendant, la case reste grisée avec sa raison.
- **Relations, mémorisation automatique** (REL-014, 017, 018, 030) : Domenia 1 enregistrait les consoles relevées et la
  moisson sans confirmation, par lots de 64. Domenia 2 fait un plan confirmé par lot (circuit des écritures). Garder ce
  plan par lot, autoriser une mémorisation sans confirmation (à écrire dans `DECISIONS.md`), ou un plan collectif scellé ?
- **Relations, classe des exports de fichiers** : `relations.export.save` est `LocalWrite` (réservée aux préférences par
  `PLATFORM.md` § 3.2) et `relations.export.open` est `Local` alors qu’elle ouvre le CSV par l’association de Windows.
  Créer une classe pour les fichiers d’export, ou admettre ces deux usages ?
- **Catalogue, statut `partiel`** : les fichiers `docs/status/*.json` des écrans classent 90 fonctions en « partiel » (avec
  ce qui reste à faire). L’intégration a gardé ce statut dans `features.json` et `FEATURES.md` (légende, colonne de la
  synthèse, « Reste à faire » sous chaque fonction) ; `CLAUDE.md` cite encore quatre statuts et n’a pas été modifié.
  Garder `partiel` (et l’ajouter à `CLAUDE.md`), ou le ramener à `a-faire` ?

**Intégration (22/10, relève OpenCode, `c7b9d09`).** Fusions `--no-ff` dans l’ordre prévu (`9ead13b` à `95b0128`), puis :
- conflits résolus sans rien perdre : listes de `PlatformTests.cs` (union, 22 modules, 438 opérations avec celles de
  Rechercher), en-têtes et branchements de `mock.js` (`WRITES` d’Opérations et `WRITE_OPERATIONS` de Comptes),
  `NOTHING_SENT` exporté avec `write.receiptsPending` (`write-flow.js`), surcouche de simulation (Fiche + `UpdateComputer`
  et `UpdateGroup` du Poste), `WriteCircuitTests.cs`, définition de `LocalWrite` (`OPERATIONS.md`, `PLATFORM.md` : préférences,
  reçus, documents de l’opérateur, fichiers propres d’un écran, exports CSV) ;
- collisions de types entre écrans dans `Domenia.Core` (chaque branche compilait seule) : `ExportResult` partagé
  (`Platform/ExportResult.cs`) et `PosteExportResult` ; `SupportSecretMask`, `DiagnosticDossierFile`, `AuditRelationKind`,
  `AuditFactState`, `SyncSnapshotComparison`, `SyncSnapshotList`, `OperationsCollectionRun` (et `RunRow`, `Family`,
  `Status`), `OperationsJournalView`, `LdapFilterAnalyzer` (Schéma ; masquait le `LdapFilter` de l’atelier de requêtes) ;
- « account.expiration » (FIC-016) : un seul exécuteur (celui de Comptes), utilisé aussi par la Fiche ;
  `WriteExecutors.Discover` refuse deux exécuteurs pour un même type ;
- `PlatformTests` aligné sur le code (`shell.metric`, `shell.ou.resolve`, `accueil.session.details` ; `accueil.board` et
  `accueil.firstSteps` en `LocalWrite`) ;
- statuts : le fichier de la page propriétaire l’emporte quand deux écrans citent la même fonction (FIC-004, 013, 016,
  048) ; PAR-006 et PAR-008 restent `fait` (le reste déclaré par Paramètres est fait par la coque fusionnée) ; PST-001
  reste `abandonne` ; aucune mention de WAPT dans `v2/src` ni `v2/web`.

Suites de l’intégration (non faites ; branchements dans des fichiers partagés, à faire puis à tester en VM) :
- coque (`app.js`) : relire `accounts.access.revision` (local, 2 s) pour
  l’emplacement « Accès » hors de l’écran Comptes (CPT-001) ; montrer les trois identités (`accounts.access.state`) dans
  le panneau d’aide avec le raccourci vers Comptes (CPT-012). Relations : brancher les refus de la détection sur les
  demandes d’accès de Comptes (REL-029). Assistance : journaliser les refus de tous les écrans dans `BridgeDispatcher`
  (ASS-006) ; lien « Dossier hors ligne de ces postes » (`#/assistance?postes=…`) dans Rechercher (ASS-012). Comptes machine :
  `mountMachineAccount` dans l’en-tête de Poste et la carte « Se connecter » d’Intervenir (MAC-002). Opérations : Ctrl L
  et panneau « Opérations de la session » de la coque vers `operations.center` (OPE-014, OPE-015). Poste : widgets et
  atelier de l’écran Requêtes (PST-111, PST-113).
- réévaluer les partiels dont le reste relevait d’un autre lot désormais fusionné (coque : PAR-004, 005, 007 ; CPT-001,
  CPT-012 ; OPE-014, 015).
- doublons fonctionnels Fiche et Comptes (même effet LDAP, deux types d’écriture) : `account.enabled` et
  `account.enable`/`account.disable`, `password.expire` et `account.mustChangePassword`, `password.reset` et
  `account.resetPassword` ; `ObjectWrites.Expiration` (Fiche) n’est plus appelée. À unifier après revue.
- arbres de travail `../Domenia-D120-team/v2-<id>` : propres et poussés ; non retirés, car ils gardent des fichiers ignorés
  (`CRITIQUE-N.md`, copies des critiques archivées, et `v2-audit/RAPPORT-OC.md`, rapport de l’agent Spark non archivé).

Fichiers partagés modifiés par des branches d’écran, fusionnés (conflits résolus ci-dessus), dont la relecture fonctionnelle
reste à faire avec les tests en VM :
`tokens.css` (shell : jetons de contraste WCAG demandés par sa critique), `app.js` (shell ; la fiche n’y touche plus),
`kit.css`, `kit/menu.js`, `router.js` (fiche : marques de menu et garde de sortie ; `kit/glyphs.js` remis à `84a7ebf`), `Composition.cs`, `Program.cs` (assistance), `kit/grid.js`
(synchro), `write-flow.js` (comptes, synchro, opérations), `mock.js` et `mock-writes.js` (plusieurs écrans). La relève
n’en modifie aucun depuis un écran.

Agent Spark actif au début de la relève (22/10, 12 h 04) : `_pilotage/oc-v2/run.sh` (OpenCode, modèle local) a travaillé
sur `v2-audit` et s’est arrêté à 12 h 59 (« ALL DONE », 2 commits) ; l’écran audit est repris à son tour, en gardant ce qu’il a laissé de bon.

Pour chaque écran, le travail suit la même boucle :
1. Lire le rapport critique.
2. Implémenter chaque fonction manquante fidèlement à Domenia 1, en lisant les `d1_refs` dans `dev/wad`.
3. Corriger les défauts.
4. Mettre à jour `v2/docs/status/<id>.json`.
5. Compiler avec `bash v2/tools/vm.sh <id> build` jusqu'à 0 avertissement.
6. Commiter sur la branche.

Une nouvelle critique suit : on boucle jusqu'à ce qu'il ne manque plus rien.

**Intégration** (faite le 22/10, voir plus haut) : fusion dans `v2` dans l’ordre shell, accueil, rechercher, fiche,
comptes, relations, poste, assistance, requetes, audit, schema, synchro, operations, parametres ; statuts appliqués à
`features.json` et `FEATURES.md` ; `vm.sh main build` Debug et Release ; commit et push. Reste : retirer les arbres de
travail (après accord, voir les suites).

## 4 bis. Vague 3 et tests en VM : état au passage de relais (OpenCode, 22/10, fin de session)

Demandes de David (22/10) : « finis tout le code et tout le dev entièrement, commit, push, puis test VM » et « fais bosser le
Spark pour économiser tes tokens, tâches multiples ». Le Spark rédige des premiers jets ; la relève fixe les contrats,
relit, compile et vérifie (un jet du Spark n’est jamais une preuve).

**Branche `v2` (compile, poussée)**
- Suite C# en VM (lot `vtest`, arbre détaché `../Domenia-D120-team/vtest`) : 739 → 786 réussis sur 791 (`015dfaa`).
  Corrigé depuis, dans le dernier commit : test intermittent du journal (avis de démarrage de la base locale ajoutés en
  tâche de fond). Restent 4 échecs, diagnostic confié au Spark (tâches t-rel, t-req) :
  `RelationsTests.Import_preview_plan_and_undo` et `Session_observations_are_saved_by_batches_of_64` (aucun poste « libre »
  trouvé dans le monde simulé : vérifier `relations.list` et la graine), `RequetesOperationsTests.Collection_needs_a_plan_bounded_to_an_OU_and_runs_it_once`
  et `RequetesRound2Tests.The_collection_plan_rereads_the_saved_SELECT_and_counts_its_cost` (toutes les mesures jugées fraîches).
- E2E simulation (137 scénarios, `015dfaa`) : 71 réussis, 65 en échec, 1 ignoré ; liste : `docs/reprise/e2e-sim-1-echecs.txt`.
  Cause n° 1 corrigée dans le dernier commit : `rechercher.js` masquait l’élément `work` par `const work = workingOu()`
  (« reading 'toggle' » dans les 12 scénarios de Rechercher et `shell/vue-experte-ponctuelle`). Pistes pour la suite :
  `comptes/changer-de-compte` attend encore `EXAMPLE\j.martin` (la session signe `adm-j.martin`) ; « Vérifiée par
  relecture » et « Confirmer l’écriture » introuvables (Fiche ×4, Synchro ×2 : dialogue du circuit après la fusion de la
  coque ?) ; journal technique non trouvé par le harnais (Requêtes ×3) ; libellés changés par les tours de critique.
  Relancer : `bash v2/tools/vm.sh vtest e2e --mode simulation --out DIR` (filtre : `--scenarios 'rechercher/*'`).

**Branche `v2-wip-annuaire` (brouillons du mode annuaire, ne compile pas encore ; ne pas fusionner avant)**
- `Domenia.Ad/Ldap/AdContracts.cs` (contrat `IAdConnection`, `AdEntry`, `AdErrors`), `Ldap/AdConnection.cs` et
  `AdConnectionFactory.cs` (jet Spark s2 relu et corrigé : `using` sur des types non jetables, constructeurs de
  `PageResultRequestControl` et `ModifyDNRequest`, `SendRequest` sans jeton, attribut `supportedControl`, aucune limite de
  taille côté serveur, localisateur de domaine quand seul le domaine est connu), `AdDirectorySource.cs` (une connexion,
  aucun nouvel essai pendant 30 s après un échec, la session ne réessaie jamais seule), `Screens/AdDirectoryTreeReader.cs`,
  et `Composition.cs`, `DossierCommandLine.cs` qui créent `AdDirectorySource(…, new WmiWorkstationProbe())`.
- Manquent pour compiler : `AdDirectoryReader` et `AdDirectoryMapper` (Spark s3), `WmiWorkstationProbe` (Spark s6).

**Spark** : outils et prompts dans `docs/reprise/spark/` (`ask.sh <tâche>` assemble `common.md`, `<tâche>.md` et les
fichiers de `<tâche>.files`, puis écrit `<tâche>.out` dans `$TMPDIR/opencode/spark/` ; `extract.py <tâche>` extrait les
blocs FILE ; `apply_patch.py <tâche> [--apply]` applique les blocs PATCH). Seule s2-ldap a rendu sa réponse (intégrée). **Toutes les autres tâches ont été interrompues (SIGTERM) à la fin de la
session, sans réponse : les relancer** avec `ask.sh`, une tâche par appel en arrière-plan, dans cet ordre : s3-reader,
s6-probe (nécessaires à la compilation), t-rel, t-req, s4-adwrites, p-accueil, p-accounts, p-search, p-fiche, s1-sqlite,
s5-relbatch, p-schema, p-machine. Chaque tâche raisonne 40 à 80 k jetons, soit environ une heure ; le Spark en traite
environ quatre à la fois.

**Suite, dans l’ordre**
1. Intégrer s3 et s6, compiler (`vm.sh main build --config Debug`, puis Release), fusionner `v2-wip-annuaire` dans `v2` ;
   brancher `AdConnection.TechnicalTrace` sur le journal technique.
2. Appliquer t-rel et t-req (relire chaque bloc), relancer la suite C# jusqu’à 791/791 ; relancer l’E2E simulation et
   corriger écran par écran.
3. Intégrer s4 (écritures des comptes), les lecteurs portés (Accueil, Comptes, Rechercher, Fiche), puis s1 (base locale).
4. s5-relbatch : `saveSealed` à la place de `saveBatches(all)` dans relations.js, les 3 opérations dans `PlatformTests`,
   REL-014, 017, 018 et 030 à « fait » (`docs/reprise/apply_status.py`).
5. Restent ensuite : lecteurs Audit, Relations, Synchronisation, Poste (WMI complet), Requêtes (collecte), Assistance,
   Opérations, Paramètres, Schéma, Comptes machine ; écritures de la Fiche et du Poste ; persistance de l’image de
   l’annuaire ; E2E en mode annuaire sur `cnamts.local` (`OU=Domenia-Tests`).

## 5. Règles techniques

- C# : `Nullable`, avertissements traités comme erreurs, `AnalysisLevel latest`, **0 avertissement**.
- Commentaires en anglais ; textes d'interface et docs en français soigné.
- Web :
  - CSP stricte : aucun `style="…"`, aucun script inline, `connect-src 'none'`, aucune ressource externe ;
  - modules ES natifs, sans chaîne de compilation ;
  - un écran = `web/js/pages/<id>.js` et `web/css/pages/<id>.css`, avec règles préfixées `[data-page="<id>"]` ;
  - le routeur charge l'écran tout seul.
- C# d'un écran :
  - `src/Domenia.Core/Screens/<Écran>/` : modèles et interface de lecture ;
  - `src/Domenia.Simulation/Screens/<Écran>/` : données dérivées déterministes ;
  - `src/Domenia.Bridge/Operations/` : module `IOperationModule` auto-découvert, opérations `<écran>.<verbe>`.
- Écritures : uniquement `<écran>.<verbe>.plan`, puis `write.execute` (jeton à usage unique, saisie du nom), reçu, relecture. Jamais de rejeu.
- Sécurité de Domenia 1 :
  - lecture seule par défaut ;
  - aucun accès réseau sans geste explicite ;
  - jamais tout le domaine sans garde ;
  - aucun secret dans le dépôt, les journaux ou une ligne de commande.
- Fichiers partagés à ne pas toucher depuis un écran : `tokens.css`, `base.css`, `components.css`, `web/js/kit/*`, `router.js`, `bridge.js`, `index.html`, `Composition.cs`, `Program.cs`, `MainForm.cs`, `BridgeDispatcher.cs`, `features.json`, `FEATURES.md`.

## 6. Machines et commandes

- **VM de développement** : `DOMENIA-FIRSTRUN-20261020` (Windows 11 joint à `cnamts.local`), 4 vCPU / 8 Go.
  - Ne pas dépasser 4 vCPU : à 6, le démarrage EFI se fige.
  - Accès SSH par l'alias `domenia-vm` (ProxyJump via l'hôte 192.168.1.173, port 2225, compte `Administrateur`, clé).
  - SDK .NET hors ligne dans `C:\DomeniaDev\dotnet`.
  - Une session de bureau `CNAMTS\Administrateur` est ouverte sur la console : ne pas la fermer.
  - 22/10 : le relais SSH 192.168.1.173 refuse les connexions en rafale (« Exceeded MaxStartups ») ; la connexion vers la
    VM est mutualisée (`ControlMaster auto`, `ControlPath ~/.ssh/cm/%C`, `ControlPersist 30m` dans le bloc `domenia-vm` de
    `~/.ssh/config`, sauvegarde `config.bak-20261022-domenia-mux`) : une seule négociation avec le relais, puis `vm.sh`
    passe par cette connexion.
- **Ne jamais compiler ni lancer sur le Mac ni sur l'hôte.**
- **Commandes** (depuis un arbre de travail, verrou exclusif de la VM) :
  - `bash v2/tools/vm.sh <lot> build` : synchronise vers `C:\DomeniaDev\src\<lot>` et compile ;
  - `bash v2/tools/vm.sh <lot> publish` : pack autonome (environ 780 Mo, ZIP d'environ 340 Mo) ;
  - `bash v2/tools/vm.sh <lot> capture --routes a,b --themes dark,light --out <dossier>` : captures réelles (fin de chantier) ;
  - `bash v2/tools/vm.sh <lot> e2e --mode simulation|annuaire --out <dossier>` : tests de bout en bout (fin de chantier).
- **Paquets** : hors ligne seulement (`v2/vendor/nuget`, `C:\DomeniaDev\cache\nuget`).

## 7. Reprendre avec OpenCode et l'API Claude

1. Configurer le fournisseur Anthropic dans OpenCode avec la clé d'API de David (hors dépôt), puis vérifier avec `opencode models`.
2. Depuis le dépôt `~/Documents/Projets/Domenia-D120` (branche `v2` à jour), lancer la relève complète : les 14 écrans un par un, puis l'intégration.

```bash
MODEL=anthropic/<modèle> bash v2/tools/releve.sh
```

   Ou seulement certains écrans, sans l'intégration :

```bash
MODEL=anthropic/<modèle> bash v2/tools/releve.sh poste requetes
```

   - Journaux : `../Domenia-D120-team/_releve/` (`releve.log`, un journal par écran).
   - Chaque écran suit `v2/docs/reprise/PROMPT-ECRAN.md` ; l'intégration suit `v2/docs/reprise/PROMPT-INTEGRATION.md`.
3. Ensuite, les vagues 3 et 4 (§ 3), en suivant `DECISIONS.md` et ce document.
4. Mettre à jour ce document (§ 3 et § 4) à chaque étape, puis le pousser.
