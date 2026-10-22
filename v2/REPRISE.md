# Domenia 2 — document de reprise

Ce document permet de reprendre le chantier si Claude Code n'est plus disponible (panne de jetons), par exemple avec
OpenCode et une clé de l'API Claude. Il est tenu à jour à chaque étape importante. Dernière mise à jour : **22/10/2026 vers 15 h 10, relève OpenCode : vague 2 intégrée dans `v2` (`c7b9d09`), Debug et Release sans erreur ni avertissement**.

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
| Vague 3 : vrai moteur (LDAP lecture et écriture, inventaire WMI/CIM/ping, base SQLite compatible Domenia 1, ordonnanceur à budgets, garde d'authentification, journal technique, démarrage) | à faire |
| Vague 4 : tests complets en VM (suites C#, scénarios E2E sur la session de bureau visible, vrai AD du labo, écritures dans `OU=Domenia-Tests`), corrections | à faire |
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
