# Domenia 2 — document de reprise

Ce document permet de reprendre le chantier si Claude Code n'est plus disponible (panne de jetons), par exemple avec
OpenCode et une clé de l'API Claude. Il est tenu à jour à chaque étape importante. Dernière mise à jour : **22/10/2026 vers 14 h 20, relève OpenCode en cours (vague 2, écrans un par un : shell, accueil, rechercher et fiche terminés)**.

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
| **Vague 2, écrans** : 14 branches `v2-page/<écran>` (poussées sur GitHub) | **en cours** (§ 4) : shell, accueil, rechercher et fiche terminés |
| Vague 2, intégration : fusion des 14 branches dans `v2`, statuts du catalogue | à faire |
| Vague 3 : vrai moteur (LDAP lecture et écriture, inventaire WMI/CIM/ping, base SQLite compatible Domenia 1, ordonnanceur à budgets, garde d'authentification, journal technique, démarrage) | à faire |
| Vague 4 : tests complets en VM (suites C#, scénarios E2E sur la session de bureau visible, vrai AD du labo, écritures dans `OU=Domenia-Tests`), corrections | à faire |
| Pack final et release GitHub | à faire |

## 4. Vague 2 : état des écrans

Chaque écran a sa branche `v2-page/<id>` et, sur le Mac, un arbre de travail `../Domenia-D120-team/v2-<id>`. Les rapports
des critiques indépendants sont archivés dans `v2/docs/reprise/critiques/<id>-tour<N>.md`.

| Écran (id) | Situation au 22/10, 12 h 10 (branches poussées sur GitHub) | À faire en premier |
|---|---|---|
| shell | **Terminé** (`f4a0c5d`, relève OpenCode) : `wip` compilé, tour 1 vérifié point par point, parité refaite, moteur de tableaux complété (TRV-286, 288, 303, 314, 315, 316) ; Debug et Release : 0 erreur, 0 avertissement | Intégration |
| accueil | **Terminé** (`82087a5`, relève OpenCode) : tour 2 traité (ACC-055, 033, 026, 023, 020, 031, 039, barre du kit, une seule action principale, titres, aperçu), tests et E2E écrits ; partiels restants : vague 3 (Domenia.Store) et atelier de requêtes ; TRV-290 à 292 (collecte par widget) à faire avec l’ordonnanceur | Intégration |
| rechercher | **Terminé** (`4d6f395`, relève OpenCode) : tour 2 traité (RCH-005, 097, 126, 127, 020, réglages de l’administrateur et de Paramètres par `search.policy`, conteneurs de la racine, notices, une seule action principale), tests et E2E écrits ; partiels : vague 3 (base locale, enregistrement en fichier) et atelier de requêtes | Intégration |
| fiche | **Terminé** (`4cceb1a`, relève OpenCode) : tour 2 traité (FIC-033 état bloquant, FIC-018 nouveau DN relu par GUID, FIC-007 brouillon Compte et discard, FIC-046 et FIC-037 session par GUID, FIC-048 bandeau, Historique, concurrence de l’aperçu), défauts de design corrigés (une action principale, colonnes des groupes, exemples de la page vide, racine du domaine, couleur des OU, présence propagée, champ DN, sélecteur, insécables) ; `app.js` et `kit/glyphs.js` remis à `84a7ebf` (palette par `ctx.commands.set` du shell) ; tests et E2E écrits ; Debug et Release : 0 erreur, 0 avertissement | Intégration (surcouche de simulation à fusionner avec poste) |
| comptes | Complété (24/31 selon l'agent) | Critique complète puis compléments |
| relations | Complété une fois ; critique du tour 2 rendue | Traiter `relations-tour2.md` (3, 7, 12) |
| poste | Complément du tour 1 interrompu : commit `wip(poste)` ; WAPT à retirer entièrement | Compiler, terminer `poste-tour1.md`, retirer WAPT, critique complète |
| assistance | Complété une fois ; critique du tour 2 rendue | Traiter `assistance-tour2.md` (2, 7, 8) |
| requetes | Complément du tour 1 interrompu : commit `wip(requetes)` | Compiler, terminer `requetes-tour1.md`, critique complète |
| audit | Complément du tour 1 interrompu : commit `wip(audit)` | Compiler, terminer `audit-tour1.md`, critique complète |
| schema | Complété (10/11 selon l'agent) | Critique complète puis compléments |
| synchro | Complété (30/30 selon l'agent) | Critique complète puis compléments |
| operations | Complément du tour 1 commité en partie (`e0385ab`) | Terminer `operations-tour1.md`, critique complète |
| parametres | Complément du tour 1 interrompu : commit `wip(parametres)` | Compiler, terminer `parametres-tour1.md`, critique complète |

Fichiers partagés déjà modifiés par des branches d’écran (avant la relève OpenCode), à revoir à l’intégration :
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

**Intégration** : fusionner les branches dans `v2` dans cet ordre :
shell, accueil, rechercher, fiche, comptes, relations, poste, assistance, requetes, audit, schema, synchro, operations, parametres.
Ensuite :
- appliquer `docs/status/*.json` à `features.json` (format à garder : indentation d'un espace, modifications ciblées) et à `FEATURES.md` ;
- compiler `vm.sh main build` (Debug et Release) ;
- commiter et pousser ;
- retirer les arbres de travail.

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
