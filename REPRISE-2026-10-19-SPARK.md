# Domenia — reprise du 19/10/2026 (session Spark / Qwen Code)

**Aucun code modifié.** Le seul dépôt de cette session est ce document, committé sur la branche
`fix/domenia-postes-rc1735` ; `master` n'est pas touché.

**Ce que David demande au prochain LLM** (les 5 points du 19/10) a été **traité à 4,5/5 par le
commit `ab129c6`**, poussé sur `master` pendant cette session. Ce document a été réécrit une
première fois pour cette raison : sa version initiale, établie sur `37ca891` (RC1.17.34), annonçait
« à faire » du code déjà écrit. **Ne pas repartir de la version `37ca891` de ce fichier.**

Reste **une seule correction sûre et non faite** : les boutons d'inventaire du tableau de bord ne se
désactivent pas pendant une exécution (§3, P5). Et **une couverture manquante** à trancher : la garde
ping ne couvre pas l'explorateur WMI solo (§3, P2).

---

## 1. Référentiel : où est la vérité

| Endroit | État | Verdict |
|---|---|---|
| GitHub `https://github.com/M4D135/domenia-d120.git` (privé) | `master` = **`ab129c67962ec993a772efe271a64ffc8368434f`** — « feat: remember dashboard OU, ping before solo and widget WMI », 19/10 (après-midi). Parent : `37ca891` = « one ping wave, then WMI only on responders (**RC1.17.34**) », 19/10 11:58 UTC | **Source de vérité** |
| Mac `~/Documents/Projets/Domenia-D120` | HEAD `60ec25a` = RC1.17.12 (16/10). **Dirty : ~26 entrées** (`Domenia-Core.ps1`, `Domenia-Main.xaml`, `Domenia-Modules.ps1`, modules Storage*/UX, 4 tests, DLL Native/Query…) + untracked `validation/2026-10-16/rc13-corrections/`. Son `origin/master` local était **périmé** jusqu'à mon `git fetch` | **Ne pas toucher, ne pas reset** (travail d'autrui). En retard de 23 RC |
| Spark `/home/m4d135/domenia/autonomy-20261017-rc14/repo`, `health-fix-20261018` | RC1.17.14 | Périmés |

**Le clone du Mac n'est pas un point de départ fiable** : il est à la fois très en retard et sale.
`ab129c6` a été poussé **pendant** cette session, ~1 h après `37ca891`. Conclusion opérationnelle :
**toujours faire `git fetch` et relire `git log` avant de conclure qu'un point est à faire.** C'est
exactement ce qui a rendu ce doc faux à sa première version.

**Arbre de travail créé pour ce lot** (additif, l'arbre dirty est intact) :

```
Mac:   ~/Documents/Projets/Domenia-rc1734      # worktree propre, 89 Mo
       branche fix/domenia-postes-rc1735 (partie de 37ca891)
       déclaré dans .git/worktrees du clone Domenia-D120
       -> git worktree remove ../Domenia-rc1734 && git branch -D fix/domenia-postes-rc1735 pour annuler
Spark: /home/m4d135/domenia/rc1734-analysis    # copie d'analyse SANS .git (rsync du worktree)
```

`rc1734-analysis` est figé sur **RC1.17.34** : il ne contient **pas** `ab129c6`. Pour lire le code
réel d'aujourd'hui, utiliser `git show ab129c6:<chemin>` depuis le clone du Mac, ou refaire un rsync.

**Accès Mac** : passer par l'alias ssh `mac`. L'IP DHCP du Mac bouge ; les adresses directes testées
cet après-midi tombaient en `No route to host` ou `Permission denied`.

---

## 2. Ce que `ab129c6` a réellement fait (religne par religne, pas le message du commit)

Fichiers touchés : `Domenia-Core.ps1` (+73), `Domenia-Main.xaml`, `Domenia-Modules.ps1`,
`Domenia-Dashboard.UI.ps1` (+41), `Domenia-Park.UI.ps1`, `Domenia-Widgets.UI.ps1`,
`Domenia-Live.Model.ps1`, `Domenia-Experience.Model.ps1`, `Domenia-UX.UI.ps1`,
`dev/tools/operation-contracts.json`, `tests/Test-DomeniaBoards.ps1`, `tests/Test-DomeniaStoragePreferences.ps1`.

### P1 — Se souvenir des OU choisies : **fait**
`dev/wad/modules/Domenia-Dashboard.UI.ps1`
- `Get-DomeniaFleetScopeSettingKey` → clé **`'Fleet.Scope.' + $hex`** (hashée par contexte, pas une clé globale)
- `Save-DomeniaFleetScopeChoice` **L90** · `Restore-DomeniaFleetScopeChoice` **L98** (garde `Write-DomeniaSwallowed` L114)
- restauration au premier rendu **L59** (`if (-not $script:FleetScopeRestored)`) ; sauvegarde **L363** et **L372**
- déclarées dans la liste fermée `dev/wad/modules/Domenia-Modules.ps1` **L2697-2698** (sinon fonction non chargée)
- câblage `BtnFleetScopeReset` : `Domenia-Core.ps1:18983` — réinitialise désormais `FleetScopeSubtree` aussi

**Point important pour qui voudra « corriger » le test** : `dev/wad/tests/Test-DomeniaBoards.ps1:197`
`Expect (-not $defaults.Contains('FleetScopeDn')) 'Un perimetre de session est persiste entre connexions'`
est **resté intact et n'a pas eu à être inversé**. Il n'interdit que la clé **littérale** `FleetScopeDn`
dans `Get-DomeniaDefaultSettings` ; la persistance passe par une clé contextuelle `Fleet.Scope.<hex>`,
donc la règle est respectée. **Ne pas inverser ce test** : la version initiale de ce doc conseillait de
le faire, c'était une erreur d'analyse.

Le souvenir des OU de l'arbre (signets) est un mécanisme distinct, déjà en place dans
`dev/wad/modules/Domenia-Continuity.UI.ps1` : `Save-DomeniaTreeBookmark` L157,
`Start-DomeniaTreeBookmarkRestore` L170, `Invoke-DomeniaTreeBookmarkRestore` L184, réglage
`OuBookmarksJson`, clé `Get-DomeniaTreeContextKey` (hash `BaseDn|BindUser`), max 12 signets.

### P2 — Ping avant WMI : **fait pour l'inventaire d'un poste et le widget, PAS pour l'explorateur WMI**
- **Inventaire d'un poste seul** : garde ICMP insérée dans le **corps du worker** d'inventaire
  (hunk `@@ -9889,6 +9896,52 @@ function Test-RegKey` — le bloc est dans le here-string du worker, après
  `Test-RegKey` L9889, **pas** dans une fonction de premier niveau). `System.Net.NetworkInformation.Ping`,
  `Send($address[0],900)`, puis **`Add-Access 'Ping' 'INJOIGNABLE' $pingDetail …` L9929** et retour anticipé :
  `FailureReason = 'Poste sans reponse au ping : inventaire WMI non lance. Les dernieres donnees valides sont conservees.'`
- **Parc** : nouveau commutateur `-PingBeforeWmi` sur `Start-DomeniaOnlinePark`
  (`Domenia-Park.UI.ps1` **L503** signature, **L507** garde `if($PingOnly -and $PingBeforeWmi){throw}`,
  **L598** propagation de la note, **L1067** nom de tâche). Le message d'échec n'est plus figé :
  il reprend `FailureReason`, sinon le `Detail` du premier accès en échec, sinon le texte historique
  « Lecture distante non confirmee ; les dernieres donnees valides sont conservees. »
- **Widget WMI mémorisé** : `Domenia-Widgets.UI.ps1:2349` — `$arguments.WmiOnly = $true` a été
  **remplacé** par `$arguments.PingBeforeWmi = $true`. Le banc suit :
  `Test-DomeniaBoards.ps1:1241` attend désormais `$call.PingBeforeWmi -and (-not $call.WmiOnly)`
  (et le stub `Start-DomeniaOnlinePark` du même test, L48-49, a reçu le paramètre).
- **Contrats retouchés** : `dev/tools/operation-contracts.json` + deux empreintes dans
  `Get-DomeniaWorkerOperationHashes` (hunks `@@ -20292` et `@@ -20319`) et `Assert-DomeniaWorkerRegistry`
  (`@@ -20367`). Toute retouche du corps du worker d'inventaire exige
  `dev/tools/update_worker_contracts.py --apply`.

**RESTE À FAIRE — la couverture manquante, mesurée, pas devinée.** L'explorateur WMI solo n'a
**aucune** garde ping. Mesure sur le corps complet de chaque fonction (déclaration → fonction suivante),
nombre d'occurrences de « ping » :

| Fonction | Lignes @ `ab129c6` | occurrences « ping » |
|---|---|---|
| `Start-DomeniaWmiNamespaces` | 12773 → 12800 | **0** |
| `Start-DomeniaWmiClasses` | 12800 → 12823 | **0** |
| `Start-DomeniaWmiQuery` | 12823 → 12855 | **0** |

Donc `BtnWmiNamespaces` / `BtnWmiClasses` / `BtnWmiQuery` (wiring `Domenia-Core.ps1:18874-18876`)
partent toujours en CIM à l'aveugle sur un poste éteint. Le message de `ab129c6` (« ping before solo
and widget WMI ») désigne le poste **seul** (inventaire) et le widget — pas l'explorateur WMI.
Coût observé dans le journal du 19/10 : **≈11 s par sonde** sur un poste éteint
(15:14:19→15:14:30, 15:15:01→15:15:12, 15:15:14→15:15:25).

**Comment faire** : ne pas écrire une seconde garde. Réutiliser le bloc ICMP déjà dans le worker
d'inventaire (L9896-9935) — l'extraire en fonction partagée, l'appeler depuis les trois entrées WMI,
et rendre le même état `INJOIGNABLE` + `FailureReason` nommé. Attention : ces trois fonctions sont des
**workers**, donc leur corps est épinglé ⇒ `update_worker_contracts.py --apply` obligatoire.

### P3 — « Actions, filtres et vues » replié par défaut : **fait**
`dev/wad/Domenia-Main.xaml:1564` — `UxResultToolsExpander` (Header « Actions, filtres et vues »)
passé de `IsExpanded="True"` à `IsExpanded="False"`. Le chevauchement signalé avec le tableau est ainsi
contourné par le repli. Si un chevauchement persiste une fois déplié, les suspects restent
`PnlSearchFilterChips` L1656 et `LblSearchFilterSummary` L1657 (`MaxHeight="36"`) sous
`UxSearchFilterCard` L1470 — **non mesuré en VM**, à ne pas affirmé comme réglé.

### P4 — Temps total de la file d'opérations : **fait**
`Update-TaskUi` (`Domenia-Core.ps1`, hunk `@@ -7394,11 +7394,18 @@`) calcule désormais le temps d'attente :
recherche de `$oldest` sur les tâches `foregroundJobs` en prenant `QueuedAt` quand `State -eq 'Queued'`
(sinon `Started`), puis `$queueSeconds = [int]((Get-Date) - $oldest).TotalSeconds`, affiché dans
`LblTaskElapsed` sous la forme « · file depuis … · ». Le panneau reste
`dev/wad/modules/Domenia-Operations.xaml` + `Domenia-Experience.UI.ps1`
(`Initialize-DomeniaOperationsPanel` L40+, timer `Timer:Operations` 1000 ms).

### P5 — Boutons « Maj rapide » / « Maj complet » du dashboard : **le seul défaut encore ouvert**
Boutons : `Domenia-Main.xaml:2866-2867` → `BtnDashboardInventory` / `BtnDashboardInventoryDeep`,
câblés `Domenia-Core.ps1:18960-18961` sur `Start-DomeniaComputerInventory [-Deep]`
(jumeaux de la fiche poste : XAML L3038-3039, câblage L18924-18925).

`ab129c6` a supprimé la cause du blocage de ~11 s (la garde ping, P2). **Mais** :

```
Domenia-Core.ps1:10975   -DisableControls @("BtnRunInventory","BtnRunInventoryDeep")
```

dans `Start-DomeniaComputerInventory` (déplacée de L10894 à **L10947** par `ab129c6`). Les deux boutons
**du dashboard** ne sont pas dans la liste : ils restent cliquables pendant l'exécution → double
lancement, séparés seulement par `ReplaceKey "inventory"`. **Correctif = ajouter les deux noms.**
C'est la correction à faire en premier : deux lignes, défaut certain, aucun risque.

À vérifier sur poste réel après ce correctif (journaux du 19/10, non élucidés) :
- `15:10:02.733 [DEBUG] Erreur ignorée [Core] Complete-UiTasks : MethodInvocationException … « Le pipeline a été arrêté. »`
  sur `EndInvoke` — disposal de tâche du pool (cf. RC1.17.30 « quiet pooled task disposal »), à confirmer bénin.
- `15:13:08.026 [WARN] Localisation du favori non confirmée dans le délai` (volet Continuity, P1).
- `15:11:59.417 Relevé arrêté : 69/3081 postes lus · 69 lectures non confirmées · 69 poste(s) sans réponse
  après 1 essai(s)` — le relevé s'est arrêté après **1 seul essai** par poste.

---

## 3. Par où reprendre (ordre conseillé)

1. **P5** — ajouter `BtnDashboardInventory` et `BtnDashboardInventoryDeep` au `-DisableControls`
   (`Domenia-Core.ps1:10975`). Défaut sûr, 2 lignes.
2. **P2 (reste)** — garde ping sur `Start-DomeniaWmiNamespaces`/`Classes`/`Query` en réutilisant le bloc
   L9896-9935 ; puis `update_worker_contracts.py --apply` + `build_packages.py --manifest-only`.
3. Recetter en VM les trois points déjà livrés par `ab129c6` (P1 mémoire d'OU, P2 ping inventaire/widget,
   P3 repli, P4 temps de file) — **rien de tout cela n'a été exécuté** : aucun banc, aucune VM pendant
   cette session. Le code est écrit, pas validé sur poste.
4. P3 : mesurer le chevauchement **déplié** en VM si David le redemande.

Contrôle d'état avant de coder : `git -C ~/Documents/Projets/Domenia-D120 fetch origin` puis
`git log --oneline -3 origin/master`. **Ne pas se fier au HEAD local du clone, ni à son
`origin/master` affiché** — c'est ce qui a fait travailler cette session sur une base de 23 RC trop vieille.

---

## 4. Contraintes techniques (les pièges qui coûtent une campagne)

- **Encodage** : `.ps1` commités **UTF-8 avec BOM + LF**. Lire en `utf-8-sig`, réécrire `BOM + utf-8`.
  Contrôler avec `/home/m4d135/.qwen/tmp/verif-encodage.py <fichiers>` **avant tout sync**.
  Faux positif connu : `dev/wad/tests/fixtures/RC1.1-ModuleImports.ps1` est CRLF **volontairement**.
- **Workers épinglés SHA-256** : `dev/tools/operation-contracts.json`,
  `Get-DomeniaWorkerOperationHashes` (cœur ~L20345), `Assert-DomeniaWorkerRegistry` (~L20420).
  Toute retouche d'un corps de worker ⇒ `dev/tools/update_worker_contracts.py --apply`
  (ou `--add OP FUNCTION`). Ne jamais éditer les empreintes à la main.
- **Liste fermée des modules** : une fonction publique ajoutée à un module doit être déclarée dans
  `dev/wad/modules/Domenia-Modules.ps1` (cf. `Save-DomeniaFleetScopeChoice` L2697) sinon elle n'est pas chargée.
- **Manifestes** : `build_packages.py --manifest-only` se lance **depuis `dev/`** avec `--output`
  (obligatoire) et réécrit **en place** `dev/wad/package-manifest.json` **et** `dev/tools/prod-manifest.json`
  ⇒ à committer quand un fichier **runtime** change (un module), pas quand seul un test change.
- **Banc `Test-Domenia.ps1`** : n'injecte du cœur que les fonctions listées dans `$wanted` (~L52) ;
  ne définit que `Assert-True`. Un oubli = `The term 'X' is not recognized`, pas une règle fausse.
- **`Test-DomeniaWiringInterface.ps1`** compte ses cas dans `$expected` (~L811) et sort en 1 si le compte
  diverge, même à zéro échec.
- **Rien de comportemental hors VM** CNAMTS-W11-01 (`dev/engineering/d120/lab/`) : ni PowerShell sur le Mac
  ni sur le Spark. Lanceur d'une suite = `powershell -STA -File <suite> -ReportPath <rapport>`,
  **un processus par suite** (`Invoke-LabRun.ps1:22`) ; sinon `PushFrame` invente des échecs.
  La chaîne de labo exige un socket de relais SSH **sur le Mac** vers `degun@192.168.1.173`
  (`lab.sh: no relay socket` sinon).
- **Consigne David du 16/10** : limiter les essais VM aux corrections indispensables, **aucune nouvelle
  campagne générale**. Arbre propre et committé **avant** de lancer une campagne.
- **Fusion** : commit de fusion (`merge: …`), jamais de fast-forward — convention du dépôt.
- **Règle d'équipe** : Domenia = **Codex par défaut** (notes KBZA `domenia-codex-only-2026-10-04`).
  Levée ponctuelle accordée le 19/10 par David pour ces 5 points.
- **Mac** : pas de `timeout` en zsh non interactif ; PATH SSH sans `/opt/homebrew/bin` ; pas de
  `pwsh`/`powershell` ; avertissements trousseau `-25308` sur un push = **bénins** (vérifier par
  `git ls-remote`) ; le Mac s'endort → relancer `caffeinate -is -t 14400`.

---

## 5. Traçabilité de cette session

- Aucun fichier de production modifié, aucun commit hors `REPRISE-2026-10-19-SPARK.md` sur
  `fix/domenia-postes-rc1735`. `master` n'est pas touché par cette session.
- **Aucun banc lancé, aucune VM contactée** : les points P1-P4 sont du code **poussé par d'autres**,
  lu et vérifié statiquement, **jamais exécuté** ici.
- Erreur corrigée dans ce fichier : la version initiale (base `37ca891`) présentait P1, P2, P3, P4 comme
  à faire et conseillait d'inverser `Test-DomeniaBoards.ps1:197`. `ab129c6` a été poussé pendant
  l'investigation et les traite ; la règle de test n'avait pas à être touchée.
