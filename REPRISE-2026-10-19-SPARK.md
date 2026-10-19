# Domenia — passation du 19/10/2026

## Intégration sur master (après la passation Spark)

Travail fait dans un clone propre de `origin/master` (`ab129c6`), pas dans
`~/Documents/Projets/Domenia-D120` (HEAD `60ec25a`, arbre sale, non reset).
Le patch `CORRECTIFS-partiels.patch` n'a pas été appliqué : il ne couvre qu'un worker
sur trois, ajoute des sondes TCP 1200 ms, et n'est pas re-épinglé. La garde retenue
est le ping ICMP 900 ms de l'inventaire, sur les trois workers.

| Point | Fait | Où |
|---|---|---|
| Maj rapide / Maj complet | Les deux boutons du tableau de bord sont désactivés pendant l'inventaire, avec les boutons de la fiche. | `Domenia-Core.ps1:10976` |
| Ping avant WMI solo | Garde ICMP 900 ms dans le corps de `WmiNamespaces`, `WmiClasses`, `WmiQuery`, avant `Enter-WCredentialAttempt`. Échec : `Access` Ping = `INJOIGNABLE`, `FailureReason` nommé, pas de CIM ni de repli tâche. Contrats re-épinglés par `update_worker_contracts.py --apply`. | `Domenia-Core.ps1:12613`, `12648`, `12690` |
| Vue d'ensemble | Plus de calcul au démarrage (`Initialize-Window` `24686`), au changement d'onglet (`19080`), ni quand la carte Premiers pas est dessinée (`Domenia-Dashboard.UI.ps1:992`). Le clic « Recalculer la vue » et le clic de l'étape Tableau de bord lancent le calcul. `Test-DomeniaFleetAwaitingScope` reste `$false`. | `Show-DomeniaFleetOverviewIdle` `Domenia-Dashboard.UI.ps1:366` |
| OU racine | Clé `Directory.RootOu.<64 hex>` (`Domenia-Experience.Model.ps1:27`), JSON `{Dn,Subtree}`. Même enregistrement : Premiers pas étape Ou et Outils (`Domenia-Main.xaml:3447`, `Save-DomeniaRootOuChoice` `272`). Défaut si la section n'a pas son choix. Reset du tableau de bord : `Reset-DomeniaFleetScopeToRoot` `346`. Aucune lecture AD ni ping à l'enregistrement. | |

**Non exécuté, donc non qualifiant :** aucun parseur PowerShell 5.1, aucune suite, aucune VM,
aucun `Parser::ParseFile`, aucun appel au laboratoire `degun@192.168.1.173`.
Contrôles Python seulement : contrats worker appliqués, `audit_preload.py --rebaseline`
(0 échec, non Windows), `build_packages.py --manifest-only` (runtime 172, dev 646).
`packs/Domenia_PROD.zip` et `Domenia_DEV.zip` non reconstruits. `packs/manifest.json`
reste `source_base_commit` `a62c3ded`. Spark `/home/m4d135/domenia/fix-rc1735` relu
(cœur `ed832a8c…`, `reachDetail` = 0) et non recopié.

Le texte ci-dessous est la passation Spark, figée avant cette intégration.
Elle décrit l'état *avant* les correctifs. Ne pas réappliquer son patch.

---

# Passation Spark / Qwen Code (historique)

**Session interrompue par David sur « passe le relais, on continue sur un autre LLM cloud ».**
Aucun code de production n'avait été commité par cette session au moment de l'écriture.
Le dépôt documentaire était ce fichier et `CORRECTIFS-partiels.patch`, sur
`fix/domenia-postes-rc1735`.

**À lire avant de coder : §3. Un patch partiel dort sur le Spark et il est capable de casser
l'application au démarrage s'il est appliqué tel quel.**

---

## 1. Référentiel — où est la vérité

| Endroit | État | Verdict |
|---|---|---|
| GitHub `M4D135/domenia-d120` (privé) | `master` = **`ab129c67962ec993a772efe271a64ffc8368434f`** — « remember dashboard OU, ping before solo and widget WMI ». Parent `37ca891` = **RC1.17.34** | **Vérité** |
| Mac `~/Documents/Projets/Domenia-D120` | HEAD `60ec25a` = RC1.17.12, **dirty ~26 entrées**, `origin/master` local périmé | **Jamais reset ni clean** (travail d'autrui). En retard de 23 RC |
| Mac `~/Documents/Projets/Domenia-rc1734` | worktree propre, branche `fix/domenia-postes-rc1735` = `3e7a537` (merge de `origin/master` dans la branche des docs) | **Arbre de travail à réutiliser** |
| Spark `/home/m4d135/domenia/fix-rc1735` | copie d'édition **remise à l'identique du dépôt** (`ed832a8c…`), + `CORRECTIFS-partiels.patch`, + `hwin.sh` | Sain, mais voir §3 |
| Spark `/home/m4d135/domenia/rc1734-analysis` | rsync **sans `.git`**, figé sur RC1.17.34 : **ne contient pas `ab129c6`** | Périmé, ne pas s'en servir pour lire le code actuel |

**Leçon de cette session, deux fois vérifiée :** `ab129c6` a été poussé sur `master` **pendant**
l'investigation. La première version de ce document, figée sur `37ca891`, annonçait « à faire » du
code déjà écrit. **`git fetch` + relire `git log` avant d'affirmer qu'un point reste à faire.**

```
Mac:  git -C ~/Documents/Projets/Domenia-rc1734 fetch origin && git log --oneline -3 origin/master
```

---

## 2. Les cinq points demandés par David

`ab129c6` (poussé par un autre agent pendant la session) en traite quatre.

| # | Demande | État | Preuve |
|---|---|---|---|
| P1 | Se souvenir des OU choisies | **Fait** | `Domenia-Dashboard.UI.ps1` : `Get-DomeniaFleetScopeSettingKey` → clé **contextuelle** `'Fleet.Scope.' + $hex`, `Save-` L90 / `Restore-` L98, restauration L59, sauvegarde L363/L372, déclarées `Domenia-Modules.ps1:2697-2698` |
| P2 | Ping avant chaque sondage WMI | **2/3 fait** | Garde ICMP dans le worker d'inventaire (`Add-Access 'Ping' 'INJOIGNABLE'` L9929) et `-PingBeforeWmi` côté parc (`Domenia-Park.UI.ps1:503,507,598,1067`) + widget (`Domenia-Widgets.UI.ps1:2349`). **Explorateur WMI solo non couvert → §4.2** |
| P3 | « Actions, filtres et vues » replié | **Fait** | `Domenia-Main.xaml:1564` `UxResultToolsExpander` `IsExpanded="False"` |
| P4 | Temps total de la file d'actions | **Fait** | `Update-TaskUi`, hunk `@@ -7394,11 +7394,18 @@` : `$oldest`/`$queueSeconds` → « · file depuis … · » |
| P5 | Boutons « Maj rapide »/« Maj complet » du dashboard | **Ouvert → §4.1** | `Domenia-Core.ps1:10975` |

**Ne pas inverser `Test-DomeniaBoards.ps1:197`.** Il n'interdit que la clé **littérale**
`FleetScopeDn` dans `Get-DomeniaDefaultSettings` ; la persistance passe par `Fleet.Scope.<hex>` et le
laisse vert. Ma première version conseillait de l'inverser : **c'était faux**, retiré.

---

## 3. ⚠️ Le patch partiel — le seul piège capable de casser le démarrage

`/home/m4d135/domenia/fix-rc1735/CORRECTIFS-partiels.patch` (22 lignes, 4 401 o) contient **deux**
éditions que j'avais appliquées à une copie locale. Elles ne sont **nulle part ailleurs**.

```
@@ -10972,7 +10972,7 @@   -DisableControls += BtnDashboardInventory, BtnDashboardInventoryDeep
@@ -12609,6 +12609,10 @@  garde ping insérée dans Get-DomeniaWmiNamespacesWorkerCode SEULEMENT
```

**Trois raisons pour lesquelles ce patch n'est PAS applicable en l'état :**

1. **Incomplet** : la garde ping est sur **1 worker sur 3**. Mesuré : `Namespaces` = 4 occurrences de
   `reachDetail`, `Classes` = **0**, `Query` = **0**.
2. **Contrats non re-épinglés** : `dev/tools/operation-contracts.json` n'a **pas** été régénéré
   (0 occurrence). Le corps de `Get-DomeniaWmiNamespacesWorkerCode` est épinglé SHA-256 ⇒
   **`Assert-DomeniaWorkerRegistry` refusera l'opération `WmiNamespaces` au démarrage.** C'est le mode
   de défaillance, pas un avertissement cosmétique.
3. **Jamais parsé** : j'ai confirmé l'existence d'un parseur PS 5.1 (§5) mais **je n'ai jamais lancé
   `Parser::ParseFile` sur le fichier modifié**. Le code du patch n'est pas validé syntaxiquement.

**La copie de travail a été remise à l'identique du dépôt** (`sha256 ed832a8c…` des deux côtés,
`reachDetail` = 0) pour qu'aucun demi-état ne soit pris pour du fini. **Ne rsync jamais le worktree
Mac depuis `/home/m4d135/domenia/fix-rc1735`** : récupère le patch, applique-le, finis le travail.

---

## 4. Le travail restant, précisément

### 4.1 P5 — désactiver les boutons du dashboard (1 ligne, défaut certain)

`Domenia-Core.ps1:10975`, dans `Start-DomeniaComputerInventory` (L10947) :

```powershell
-DisableControls @("BtnRunInventory","BtnRunInventoryDeep") `
```

Les deux boutons du dashboard restent cliquables pendant l'exécution → double lancement, séparés
seulement par `ReplaceKey "inventory"`. Noms vérifiés dans le XAML (`Domenia-Main.xaml:2866-2867`) et
le câblage (`Domenia-Core.ps1:19013-19014`) : `BtnDashboardInventory`, `BtnDashboardInventoryDeep`.
**Hors corps de worker ⇒ aucun contrat à re-épingler.** C'est le correctif à faire en premier.

### 4.2 P2 — garde ping sur l'explorateur WMI solo (les trois quarts du travail)

Mesuré sur le corps complet de chaque fonction : **0 occurrence de « ping »** dans
`Get-DomeniaWmiNamespacesWorkerCode` (L12607), `Get-DomeniaWmiClassesWorkerCode` (L12626),
`Get-DomeniaWmiQueryWorkerCode` (L12641). Le message de `ab129c6` (« ping before solo and widget WMI »)
désigne le poste **seul** (inventaire) et le widget — pas l'explorateur.

Coût sur poste éteint, dans le journal du 19/10 : **≈11 s par sonde** (15:14:19→30, 15:15:01→12,
15:15:14→25). Ce n'est pas 12 s mais **12 s de session CIM + le délai du repli
`Invoke-WRemoteTaskScript`** — d'où la garde placée **avant `Enter-WCredentialAttempt`**, sinon un poste
éteint est compté comme échec d'identifiants par `Register-WCredentialFailure` (pollue le garde-compte
anti-verrouillage).

**Le contrat de rendu existe déjà, ne pas l'inventer.** `Complete-DomeniaClassicCollected`
(`Domenia-Park.UI.ps1:1760`) lit `Success` et `FailureReason` puis appelle
`Submit-DomeniaRemoteDetail -Succeeded $false -ErrorText $reason` → `Fail-DomeniaWmiUi` (L12726) rend
« Echec : … » dans `LblWmiStatus`. Un worker qui rend `Success=$false` + `FailureReason` est donc
correctement affiché, **données valides conservées**.

**Trois contraintes d'écriture**, toutes vérifiées :
- `Add-Access` est défini **en local dans le here-string de chaque worker** (L9603, L11885) : les
  workers WMI ne le connaissent **pas**. L'appeler lèverait une exception dans le runspace.
- `Test-WTcpPort` (L7284) est de **portée hôte**, pas injectée dans le runspace : faire les sondes TCP
  en interne (`Net.Sockets.TcpClient`), comme le fait déjà le bloc ping de l'inventaire.
- **Ne pas refuser un poste vivant qui filtre ICMP** — le pare-feu Windows bloque ICMP par défaut (le
  un ping **et** les ports WMI 135/5985/5986 sont muets. Le patch fait déjà ainsi ; le reproduire à
  l'identique sur les deux autres workers.

**Attention à la mesure** : ne jamais délimiter une fonction par regex `^function` dans ce fichier —
les here-strings contiennent des `function` en colonne 0 (piège documenté, mesuré faux sur
`Get-DomeniaIndexWorkerCode`).

---

## 5. Comment vérifier — le levier découvert en fin de session

**Ni le Spark ni le Mac n'ont de PowerShell.** Mais l'hôte de labo Windows est joignable **par clé
SSH depuis le Mac**, et c'est un **PowerShell 5.1.26100.9711 64 bits** — la cible réelle du produit,
pas PS 7.

```
Spark: bash /home/m4d135/domenia/fix-rc1735/hwin.sh <script.ps1>   # -> Mac -> degun@192.168.1.173
```

Testé et fonctionnel : `PS=5.1.26100.9711 · HOST=DESKTOP-285EKHU · EXE=True`. Le script est transmis
en UTF-16LE base64 (`-EncodedCommand`), seule voie qui ne casse pas les quotes à travers
bash→ssh→cmd→powershell. **Aucun mot de passe n'est nécessaire ni consigné.**

Utiliser cet accès pour **parser**, pas pour exécuter : la doctrine interdit le comportemental hors de
la VM `CNAMTS-W11-01`, `[System.Management.Automation.Language.Parser]::ParseFile` n'exécute rien.

**Les cinq étapes obligatoires avant tout commit** (dans l'ordre) :

1. Appliquer le patch, **compléter les workers `Classes` et `Query`**.
2. `dev/tools/update_worker_contracts.py --apply` — **non négociable**, sinon `Assert-DomeniaWorkerRegistry`
   refuse l'opération au démarrage. Ne jamais éditer les empreintes à la main.
3. `build_packages.py --manifest-only` **depuis `dev/`** avec `--output` (obligatoire) : réécrit en place
   `dev/wad/package-manifest.json` **et** `dev/tools/prod-manifest.json` ⇒ à committer (fichier runtime).
4. Contrôle **UTF-8 BOM + LF** : `/home/m4d135/.qwen/tmp/verif-encodage.py <fichiers>`. Faux positif
   connu : `dev/wad/tests/fixtures/RC1.1-ModuleImports.ps1` est CRLF volontairement.
5. `Parser::ParseFile` via `hwin.sh` sur le cœur modifié ⇒ **0 erreur**.

**Rien de comportemental hors VM** `CNAMTS-W11-01`. Une suite = `powershell -STA -File <suite>
-ReportPath <rapport>`, **un processus par suite** (`Invoke-LabRun.ps1:22`). Chaîne de labo exige un
socket de relais SSH sur le Mac vers `degun@192.168.1.173`. Consigne David du 16/10 : essais VM
limités au strict indispensable, **aucune nouvelle campagne générale**.

---

## 6. Ce que je n'ai PAS vérifié — à ne pas prendre pour acquis

- **Aucun banc lancé, aucune VM contactée, aucun parseur exécuté** pendant cette session. P1-P4 sont du
  code poussé par d'autres, lu statiquement : **écrit, pas validé sur poste**.
- Le correctif P5 est certain par lecture (noms vérifiés dans le XAML et le câblage) mais **jamais
  exécuté**.
- La garde du patch est **ma** conception (ping **ou** ports 135/5985/5986), pas celle de `ab129c6` :
  son comportement sur poste réel n'a jamais été observé.
- Trois anomalies du journal du 19/10 restent **non élucidées** :
  `15:10:02.733 Complete-UiTasks : MethodInvocationException « Le pipeline a été arrêté. »` (bénin ?
  cf. RC1.17.30 « quiet pooled task disposal »), `15:13:08.026 Localisation du favori non confirmée
  dans le délai`, et `15:11:59.417 Relevé arrêté : 69/3081 postes lus · 69 poste(s) sans réponse après
  1 essai(s)` — **un seul essai par poste**.
- P3 : le chevauchement **déplié** n'a jamais été mesuré en VM (viewport 1024×768, fenêtre bornée
  1044×788 — imposer la taille du contrôle mesuré, ne jamais couper la virtualisation pour faire
  passer une assertion).

**Règle d'équipe** : Domenia = **Codex par défaut** (notes KBZA `domenia-codex-only-2026-10-04`) ;
levée ponctuelle accordée par David le 19/10 pour ces cinq points. **Fusion par commit de fusion
(`merge: …`), jamais de fast-forward.**
