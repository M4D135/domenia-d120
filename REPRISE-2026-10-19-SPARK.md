# Domenia — reprise du 19/10/2026 (session Spark / Qwen Code)

**Aucun code modifié.** Le seul dépôt de cette session est ce document, committé sur la branche
`fix/domenia-postes-rc1735` ; `master` n'est pas touché. La session a servi à (1) rétablir le bon
référentiel — David corrige « rc1.17.34, daté d'une heure » alors que le clone du Mac était à
RC1.17.12 — et (2) localiser les 5 points demandés dans le code RC1.17.34 réel. Tout ce qui suit
a été **lu et vérifié** ; les lignes citées l'ont été dans l'arbre RC1.17.34.

---

## 1. Référentiel : où est la vérité

| Endroit | État | Verdict |
|---|---|---|
| GitHub `https://github.com/M4D135/domenia-d120.git` (privé) | `master` = **`37ca891740986fa6d307aafb8088124ab1cbb033`** — « feat: one ping wave, then WMI only on responders (RC1.17.34) », 2026-10-19 11:58:33 +0000 | **Source de vérité** |
| Mac `~/Documents/Projets/Domenia-D120` | HEAD `60ec25a` = RC1.17.12 (16/10). **Dirty : 25 fichiers modifiés** (`Domenia-Core.ps1`, `Domenia-Main.xaml`, `Domenia-Modules.ps1`, modules Storage*, UX, 4 tests, DLL Native/Query…) + untracked `validation/2026-10-16/rc13-corrections/`. Son `origin/master` local était **périmé** (`60ec25a`) jusqu'à mon `git fetch` | **Ne pas toucher, ne pas reset** (travail d'autrui). En retard de 22 RC |
| Spark `/home/m4d135/domenia/autonomy-20261017-rc14/repo` | `4a4fb41` RC1.17.14 | Périmé |
| Spark `/home/m4d135/domenia/health-fix-20261018` | RC1.17.14 | Périmé |

**Arbre de travail créé pour ce lot** (additif, l'arbre dirty est intact) :

```
Mac: ~/Documents/Projets/Domenia-rc1734      # worktree propre, 89 Mo
     branche fix/domenia-postes-rc1735 @ 37ca891
     (déclaré dans .git/worktrees du clone Domenia-D120 — git worktree remove pour annuler)
Spark: /home/m4d135/domenia/rc1734-analysis   # copie d'analyse sans .git, rsync du worktree
```

`git worktree add` a été lancé depuis le clone sale : c'est réversible par
`git worktree remove ../Domenia-rc1734` + `git branch -D fix/domenia-postes-rc1735`.

**Accès Mac** : passer par l'alias ssh `mac`. L'IP DHCP du Mac bouge ; les adresses directes testées
cet après-midi tombaient en `No route to host` ou `Permission denied`.
Aucune activité git Domenia sur le Mac ni le Spark dans les 6 h précédentes : RC1.17.34 a été
poussé depuis ailleurs (Claude/Codex, voir `Co-Authored-By` + `Claude-Session` du commit).

---

## 2. Les 5 points demandés par David, et ce que j'ai trouvé

### P1 — Se souvenir des OU choisies pour le prochain démarrage
**Mécanisme existant** : `dev/wad/modules/Domenia-Continuity.UI.ps1`
- `Save-DomeniaTreeBookmark` L157 · `Start-DomeniaTreeBookmarkRestore` L170 · `Invoke-DomeniaTreeBookmarkRestore` L184
- réglage `OuBookmarksJson`, clé = `Get-DomeniaTreeContextKey` (hash `BaseDn|BindUser`), max 12 signets
- timer + `Add_ContentRendered` L490-493 ; sauvegarde seulement si `$script:Continuity.Dirty` (L484)

**Ce qui cloche** (à confirmer sur poste réel) :
1. Le journal du 19/10 14:58:30 montre la restauration de la **racine** (`DC=cnamts,DC=local`,
   `portée=OneLevel`), alors que l'OU réellement choisie à 15:00:14 était
   `OU=111301-CPAM Marseille,OU=Assurance Maladie,DC=cnamts,DC=local`. La signature « OU restaurée :
   racine du domaine rouverte sur un seul niveau » vient du commentaire **décision David
   2026-10-19** vers L470 de `Domenia-Continuity.UI.ps1` (la racine mémorisée avec sa subtree et
   sans texte de recherche se rouvre d'un seul niveau). Ce cas précis écrase le souvenir utile.
2. **Le périmètre du tableau de bord n'est pas persisté, et c'est voulu par un test** :
   `dev/wad/tests/Test-DomeniaBoards.ps1:197`
   `Expect (-not $defaults.Contains('FleetScopeDn')) 'Un perimetre de session est persiste entre connexions'`.
   La demande de David **invalide cette règle** : il faut inverser le test (précédent du même type :
   renversement volontaire UX-09, commit `af875ca`) et persister `FleetScopeDn` (+ `FleetScopeSubtree`)
   comme `IndexScopeDn`. Écrire la décision dans le message de commit.
3. `SelectedBranchDn` est posé en 3 endroits du cœur : `Domenia-Core.ps1` L4687, L4718, L4874 (et L1785, L11605).

### P2 — Ping avant chaque sondage WMI (bouton solo + widget), sinon timeout WMI
**RC1.17.34 n'a traité que le parc** (« Tout actualiser » + bouton WMI du parc) : une seule vague de
192 echoes (`ParkPing` clamp 256), WMI réservé aux répondants, horloges ping/WMI séparées.
Contrats retouchés dans ce commit : `ParkPing = F889C57CB5FBB9B1DBBA87D0E55C37FE471B69DA8A9DFFAAE6C3662D11D11C74`
et empreinte du registre `128496F28561D6DF5E6E57340CDCA14F824CCE08CA51426F004B1A72FF283451`.

**Non couvert — c'est la demande de David** :
| Entrée | Fichier:ligne | Ping ? |
|---|---|---|
| `Start-DomeniaComputerInventory` (rapide/complet d'**un** poste) | `Domenia-Core.ps1:10894` (budget 55 s / 150 s, timeout 110 s / 260 s) | **non** |
| Explorateur WMI : `BtnWmiNamespaces` / `BtnWmiClasses` / `BtnWmiQuery` | wiring `Domenia-Core.ps1:18874-18876` → `Start-DomeniaWmiNamespaces`/`Classes`/`Query`, tâches ~L12738 / L12761 / L12793 | **non** |
| Widget WMI mémorisé (`OperationId = WidgetWmiDetail`) | voir `dev/wad/tests/Test-DomeniaWidgetDetailRefresh.ps1` (L106, L187) | **non** |

Le message d'erreur vient de `dev/wad/modules/Domenia-Park.UI.ps1:1715, 1765, 1766`
(« Lecture distante non confirmee ; les dernieres donnees valides sont conservees. »).
Coût mesuré dans le journal : **≈11 s par sonde** sur un poste éteint (15:14:19 → 15:14:30,
15:15:01 → 15:15:12, 15:15:14 → 15:15:25). Un ping préalable doit ramener ça à ~1 s et rendre un
état « poste injoignable » plutôt qu'un échec WMI.
**À faire** : une seule fonction de garde d'accessibilité (TCP 135/445 ou echo, réutilisable, avec
budget court) appelée par les **trois** entrées, + un état distinct « injoignable » vs « non confirmé »,
+ dates ping et WMI séparées (déjà la règle depuis RC1.17.34 pour le parc).

### P3 — « action filtre et vue » vs tableau : ça se chevauche, à replier par défaut
Zone concernée, page **Rechercher** (`dev/wad/Domenia-Main.xaml`) :
- `UxSearchFilterCard` **L1470** (Border `Grid.Row="0"`, `Padding="16"`, bordure basse)
- `UxSearchFilterQueryLayout` L1487 (3 lignes × 2 colonnes, dont une `Width="0"`)
- `UxSearchFilters` (WrapPanel) L1488 · `CmbPresenceFilter` L1500 · `TxtSearchQueryFilter` L1520 · `CmbObjectFilter` L1544
- `TxtSuiteResultFilter` L1595 · `PnlSearchFilterChips` **L1656** · `LblSearchFilterSummary` **L1657** (`MaxHeight="36"`, trim)

**Non tranché** : je n'ai pas encore identifié l'élément qui mord sur `DgObjects` (le WrapPanel des
chips + le résumé des critères en L1656-1657 sont les suspects n°1). Prochaine étape : lire la
grille de résultats sous L1657 et mesurer en VM (attention au piège viewport de la VM de labo, §4).
Demande explicite : **replié par défaut** + bouton pour déplier ; mémoriser l'état (réglage).

### P4 — File d'actions : afficher le temps total de la file en cours
Panneau « Opérations » : `dev/wad/modules/Domenia-Operations.xaml` +
`dev/wad/modules/Domenia-Experience.UI.ps1`
- `Initialize-DomeniaOperationsPanel` L40+ (charge le XAML au 1er opening, `DomeniaDialogLayer`)
- lignes `DgSuiteActivity`, timer `Timer:Operations` 1000 ms → `Update-DomeniaExperienceActivity` (PF-12 : durées rafraîchies en place)
- `Set-DomeniaOperationsPanelPosition` (largeur 620 max, sous `BtnSuiteActivity`)

**À faire** : un en-tête « N opération(s) · total estimé X · écoulé Y » — somme des durées des lignes
en file + temps déjà écoulé de la ligne courante. Ne pas inventer l'estimation : la déduire des
budgets déjà passés à `Start-UiTask` (`-TimeoutSeconds`, budgets 55 s / 150 s de l'inventaire).
Tests à mettre à jour : `dev/wad/tests/Test-DomeniaOperationTrace.ps1` (L227, L252 lisent le XAML) et
`dev/wad/tests/Test-DomeniaUxQualification.ps1` (L81, L303-311 — attend un `ScrollViewer` enfant).

### P5 — Dashboard poste : boutons « Maj rapide » / « Maj complet » HS
Boutons réels : `Domenia-Main.xaml:2866-2867` → `BtnDashboardInventory` (« Inventaire rapide ») et
`BtnDashboardInventoryDeep` (« Inventaire complet »), câblés `Domenia-Core.ps1:18960-18961` sur
`Start-DomeniaComputerInventory [-Deep]`. (Les jumeaux de la fiche poste sont L3038-3039 / L18924-18925.)

**Défauts visibles dans le journal du 19/10** :
1. **Même cause que P2** : pas de ping → chaque bouton brûle ~11 s puis échoue
   (« Inventaire impossible : Lecture distante non confirmee », ×4 sur 2 postes).
2. **Les boutons du dashboard ne se désactivent pas** : `Start-DomeniaComputerInventory` ne passe que
   `-DisableControls @("BtnRunInventory","BtnRunInventoryDeep")` (`Domenia-Core.ps1:10922`). Les
   boutons `BtnDashboardInventory*` restent cliquables → double lancement, seul `ReplaceKey "inventory"`
   les sépare. Corriger en ajoutant les deux noms.
3. `15:10:02.733 [DEBUG] Erreur ignorée [Core] Complete-UiTasks : MethodInvocationException …
   « Le pipeline a été arrêté. »` sur `EndInvoke` — disposal de tâche du pool (cf. RC1.17.30
   « quiet pooled task disposal »). À confirmer comme bénin ou non.
4. Deux autres anomalies du même journal, à ne pas perdre :
   `15:13:08.026 [WARN] Localisation du favori non confirmée dans le délai` (lié à P1) et
   `15:11:59.417 Relevé arrêté : 69/3081 postes lus · 69 lectures non confirmées · 69 poste(s) sans
   réponse après 1 essai(s)` (le relevé s'est arrêté, 1 seul essai par poste — lié à P2).

---

## 3. Contraintes techniques (les pièges qui coûtent une campagne)

- **Encodage** : `.ps1` commités **UTF-8 avec BOM + LF**. Lire en `utf-8-sig`, réécrire `BOM + utf-8`.
  Contrôler avec `/home/m4d135/.qwen/tmp/verif-encodage.py <fichiers>` **avant tout sync**.
  Faux positif connu : `dev/wad/tests/fixtures/RC1.1-ModuleImports.ps1` est CRLF **volontairement**.
- **Workers épinglés SHA-256** : `dev/tools/operation-contracts.json`,
  `Get-DomeniaWorkerOperationHashes` (cœur ~L20337), `Assert-DomeniaWorkerRegistry` (~L20367).
  Toute retouche d'un corps de worker ⇒ `dev/tools/update_worker_contracts.py --apply`
  (ou `--add OP FUNCTION` pour une opération nouvelle). Ne pas éditer les empreintes à la main.
- **Manifestes** : `build_packages.py --manifest-only` se lance **depuis `dev/`** avec `--output`
  (obligatoire) et réécrit **en place** `dev/wad/package-manifest.json` **et**
  `dev/tools/prod-manifest.json` → à committer quand un fichier **runtime** change (un module),
  pas quand seul un test change.
- **Banc `Test-Domenia.ps1`** : n'injecte du cœur que les fonctions listées dans `$wanted` (~L52) ;
  ne définit que `Assert-True` (pas d'`Assert-False`). Un oubli = `The term 'X' is not recognized`,
  pas une règle fausse.
- **`Test-DomeniaWiringInterface.ps1`** compte ses cas dans `$expected` (~L811) et sort en 1 si le
  compte diverge, même à zéro échec.
- **Rien de comportemental hors VM** CNAMTS-W11-01 (`dev/engineering/d120/lab/`) : ni PowerShell sur
  le Mac ni sur le Spark. Lanceur d'une suite = `powershell -STA -File <suite> -ReportPath <rapport>`,
  **un processus par suite** (`Invoke-LabRun.ps1:22`) ; sinon `PushFrame` invente des échecs.
  La chaîne de labo exige un socket de relais SSH **sur le Mac** vers `degun@192.168.1.173`
  (`lab.sh: no relay socket` sinon).
- **Consigne David du 16/10** : limiter les essais VM aux corrections indispensables, **aucune
  nouvelle campagne générale**. Arbre propre et committé **avant** de lancer une campagne.
- **Fusion** : commit de fusion (`merge: …`), jamais de fast-forward — convention du dépôt.
- **Règle d'équipe** : Domenia = **Codex par défaut** (notes KBZA `domenia-codex-only-2026-10-04`).
  Levée ponctuelle accordée aujourd'hui par David pour ces 5 points.
- **Mac** : pas de `timeout` en zsh non interactif ; PATH SSH sans `/opt/homebrew/bin` ; pas de
  `pwsh`/`powershell` ; avertissements trousseau `-25308` sur un push = bénins (vérifier par
  `git ls-remote`) ; le Mac s'endort → relancer `caffeinate -is -t 14400`.

---

## 4. Par où reprendre (ordre conseillé)

1. **P5.2** (désactiver les 2 boutons du dashboard) — 2 lignes, défaut sûr, aucun risque.
2. **P2** — la garde d'accessibilité unique, branchée sur les 3 entrées ; c'est aussi ce qui fait
   basculer P5.1. Vérifier d'abord ce que RC1.17.34 a posé côté parc pour **réutiliser** la même
   fonction plutôt qu'en écrire une seconde.
3. **P1** — persister `FleetScopeDn`/`FleetScopeSubtree` (inverser `Test-DomeniaBoards.ps1:197` en
   assumant le renversement) puis corriger la restauration qui retombe sur la racine.
4. **P4** — en-tête de temps total du panneau Opérations.
5. **P3** — repli par défaut de la barre filtre/vue ; à mesurer en VM (viewport 1024×768, fenêtre
   bornée 1044×788 : imposer la taille du contrôle mesuré, ne jamais couper la virtualisation pour
   faire passer une assertion).

Contrôle rapide de l'état : `git -C ~/Documents/Projets/Domenia-rc1734 log --oneline -1` doit rendre
`37ca891 … (RC1.17.34)` tant que rien n'est committé sur `fix/domenia-postes-rc1735`.
