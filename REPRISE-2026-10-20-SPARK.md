# Reprise Domenia — Spark, 20 octobre 2026

**Complément RC1.17.37 du 20 octobre :** calcul du dashboard optimisé, 40.40 s → 10.42 s (médianes, −74.2 %)
sur 5 000 postes synthétiques. Santé, projections et parité des lectures Fleet/Park
vérifiées sous Windows 5.1 ; packs DEV/PROD régénérés et contrôlés. VM conservée.
[Preuves et limites](validation/2026-10-20/rc37-dashboard/README.md). Aucun nouveau test de démarrage.


**Complément RC1.17.36 du 20 octobre :** qualifications fonctionnelles ciblées terminées,
Boards 66/66, WiringCache 190 cas couverts après reprise ciblée des deux derniers,
santé 37 cas, stockage 10 cas et AD/WMI réels. Quatre corrections applicatives et
packs DEV/PROD régénérés. Réouverture après restauration et Premiers pas réels
validés sur le pack final ; préférences 7/7. [Preuves, portée exacte et limites](validation/2026-10-20/rc35-qualification/README.md).
VM DOMENIA-FIRSTRUN-20261020 conservée. Les états ci-dessous sont historiques.


**Complément Codex du 20 octobre :** passation intégrée et complétée en RC1.17.35,
tests Windows ciblés et fabrication native vérifiés. Voir le [suivi et les limites](validation/2026-10-20/first-run/README.md).
Le compte rendu d’origine est conservé ci-dessous.

Chantier : trois pannes de la carte « Premiers pas » à la première initialisation, puis build DEV et **surtout PROD** sur GitHub.
Ce document remplace `REPRISE-2026-10-19-SPARK.md` (sa branche `fix/domenia-postes-rc1735` a disparu du Mac).

**À lire avant tout : la section « Ce qui n'est PAS prouvé ».** Le correctif est écrit, il n'a **jamais été exécuté**.

---

## 1. Base de travail — l'unique base qui fait foi

| | |
|---|---|
| Dépôt | `https://github.com/M4D135/domenia-d120.git` |
| Base du correctif | `origin/master` = **`83b7795`** — « fix: fold search actions, filters and views by default » (20/10/2026) |
| Arbre de travail Spark | `/home/m4d135/domenia/master-83b7795/` |
| Archive d'origine | `/home/m4d135/domenia/master-83b7795.tar.gz` (52 630 200 o, `git archive origin/master`) |
| Clone de référence | Mac `david@192.168.1.128` → `~/Documents/Projets/Domenia-rc1734` |

**Codex pousse en continu sur master.** Avant toute écriture : `git fetch origin` puis relire `git log origin/master`.
Au 20/10 mesuré : `origin/master` = `83b7795`, `master` local du Mac = `60ec25a` (périmé), HEAD détaché sur `7296698`, `git status --porcelain` = 0.

**Arbres à ne plus utiliser** (bases périmées, vérifiées par empreinte) : `fix-rc1736`, `fix-rc1735`, `rc1734-analysis`.

Le Spark n'a **aucune** authentification GitHub (ni `gh`, ni jeton, 0 entrée github dans `~/.git-credentials`). Tout Git passe par le Mac.

---

## 2. Les trois symptômes signalés par David

1. Étape 2 « Choisir une OU » ne se valide jamais, même l'OU sélectionnée **et** confirmée dans le sélecteur.
2. Elle se valide bien après un clic sur « Actualiser ».
3. Et cette actualisation échoue alors : « aucun poste dans l'OU ».

---

## 3. Diagnostic — établi sur `83b7795`, lignes vérifiées sur l'archive intacte

Trois causes distinctes. Les deux premières expliquent (1) et (2), la troisième explique (3).

### 3.1 L'acceptation de l'OU ne redessine pas la carte → symptôme 1

Chaîne réelle : `Open-DomeniaFirstStep -Step 'Ou'` (`modules/Domenia-Dashboard.UI.ps1:1075`) → `Show-DomeniaRootOuSource` → `Save-DomeniaRootOuChoice` (`:303`) → `Publish-DomeniaRootOuChoice` (`:264`).

`Publish-DomeniaRootOuChoice` rappelle `Update-DomeniaRootOuTools`, `Update-DomeniaOuRefreshUi`, `Update-DomeniaQueryScopeLabel` — **jamais `Update-DomeniaFirstSteps`**. L'état sous-jacent est pourtant correct dès le choix : `Get-DomeniaFleetScope` (`:56`) retombe sur `Get-DomeniaRootOuChoice` (`:148`) quand `FleetScopeDn` est vide. **Le défaut est un manque de redessin, pas le sélecteur.**

> Deux hypothèses héritées de la séance du 19/10 sont **fausses sur master** et ont été écartées après relecture :
> `Test-DomeniaFleetAwaitingScope` (`:480`) renvoie `$false` sans condition (décision David du 19/10) ; et sur Accueil `Test-DomeniaFleetDashboardShown` est vrai, donc `Request-DomeniaFleetRefresh` (`:486`) atteint bien `Update-DomeniaFirstSteps`. C'est précisément ce qui explique le symptôme 2 : un rafraîchissement unrelated repeint la carte, ce qui prouve qu'il ne manquait que le rappel.
> Le point 2 appelle `Show-DomeniaRootOuSource`, **pas** `Show-DomeniaFleetScopeSource`.

### 3.2 La première lecture est déduite d'un compteur GLOBAL → symptôme 3

`Get-DomeniaFirstStepsState` (`:1025`) faisait :

```powershell
$indexed = [long]$script:IndexDbCount
```

Or `$script:IndexDbCount` est posé par `Complete-DomeniaIndexMetadataUi` (`modules/Domenia-Engine.UI.ps1:1299`) à partir de `$metadata.Counts.Total` : **le total de la base, sans filtre sur l'OU**. Une base déjà remplie par une autre OU, ou par le domaine précédent, marquait l'étape 3 faite et déverrouillait l'étape 4. La lecture locale filtrée sur l'OU, elle, renvoyait légitimement 0 → `Complete-DomeniaFirstDashboard` (`:1017`) rendait cela en **échec** (`:1022`, « Aucun poste dans cette OU dans la base locale… »).

### 3.3 Oracle de couverture retenu

`Get-DomeniaFleetFreshness` (`modules/Domenia-BoardFleet.Model.ps1:712`), `.Status` ∈ `Complete|Partial|UnknownDepth|Missing`. Il ne lit que `$script:IndexSyncStates` en mémoire — ni disque, ni réseau : conforme au contrat de la carte (« aucun appel, aucun balayage », commenté en `:1027`). Marqueurs indexés `ou:<dn>`, `ou:onelevel:<dn>`, `directory`, `details='complete;depth=Subtree'`.

---

## 4. Correctifs appliqués (3 fichiers, non exécutés)

Empreintes contrôlées, BOM `efbbbf` vérifié intact sur les trois.

| Fichier | Avant | Après |
|---|---|---|
| `dev/wad/modules/Domenia-FirstRun.Model.ps1` | `5c6bbf1b…` 2 897 o / 50 l. | `33176c58…` 3 175 o / 53 l. |
| `dev/wad/modules/Domenia-Dashboard.UI.ps1` | `1fb5d270…` 86 970 o / 1 188 l. | `dacc615c…` 88 189 o / 1 201 l. |
| `dev/wad/tests/Test-DomeniaBoards.ps1` | `e60c75bb…` 189 044 o / 1 848 l. | `d8bf4c26…` 193 838 o / 1 893 l. |

Sha256 complets : `33176c5802ff3471181826731736e5ad9e1a2d0388a5e6c43fc75797d6f723c7`, `dacc615c15210f4f5d0dff217d967352fa009374fca15f4128c36f6cb49b6752`, `d8bf4c26ae22b7391e6c38627c350066d3a65ca3eaf2e6640d884746b42f7ed7`.

### A. `Domenia-FirstRun.Model.ps1` — paramètre `-ScopeRead`

Règle pure (ni WPF, ni réseau, ni disque). Défaut **`$true`** : les 7 appels Pester de `tests/rules/Delivery.Tests.ps1:186-216` (FRN-001..003, mesurés `grep -n` le 20/10) n'en passent aucun — `grep -c 'Get-DomeniaFirstRunPlan.*ScopeRead'` = **0** — et restent donc verts.

```powershell
        [bool]$DashboardSeen = $false,
        [bool]$ScopeRead = $true
    )
    $connected = [bool]$Domain.Trim()
    $scoped = [bool]$ScopeDn.Trim()
    # The first read is the read of THIS OU: a base already filled by another OU or by a previous domain does not
    # cover it, and unlocking the overview on such an OU answered « Aucun poste dans cette OU » as a failure.
    $read = (($IndexedObjects -gt 0) -and $ScopeRead)
```

### B. `Domenia-Dashboard.UI.ps1` — redessin dans `Publish-DomeniaRootOuChoice`

```powershell
    try { Update-DomeniaQueryScopeLabel } catch { Write-DomeniaSwallowed 'Dashboard' 'Publish-DomeniaRootOuChoice' $_ }
    # The card of the first steps reads its OU through Get-DomeniaFleetScope, which now falls back on this choice.
    # Without this redraw the accepted OU stayed on « 2 » until an unrelated refresh made « Actualiser » repaint it.
    try { Update-DomeniaFirstSteps } catch { Write-DomeniaSwallowed 'Dashboard' 'Publish-DomeniaRootOuChoice' $_ }
```

### C. `Domenia-Dashboard.UI.ps1` — garde de couverture dans `Get-DomeniaFirstStepsState`

```powershell
    $scopeDn = ''; $scopeName = ''; $scopeSubtree = $true
    try { $scope = Get-DomeniaFleetScope; if ($null -ne $scope) { $scopeDn = [string]$scope.Dn; $scopeName = [string]$scope.Name; $scopeSubtree = [bool]$scope.Subtree } } catch { $scopeDn = '' }
    $indexed = 0L
    try { $indexed = [long]$script:IndexDbCount } catch { $indexed = 0L }
    # The counters of the base are global: a base already filled by another OU, or by the previous domain, must not
    # mark this OU as read. Only the committed coverage of the chosen scope proves its first read. No marker at all
    # means the state was never read (unknown), not an OU never read: the guide is never locked on a missing signal.
    $scopeRead = $true
    if (($indexed -gt 0) -and ($null -ne $script:IndexSyncStates) -and (@($script:IndexSyncStates.Keys).Count -gt 0)) {
        try {
            $coverage = Get-DomeniaFleetFreshness -ScopeDn $scopeDn -DomainDn ([string]$script:Conn.BaseDn) -SyncStates $script:IndexSyncStates -Subtree $scopeSubtree
            $scopeRead = ([string]$coverage.Status -ine 'Missing')
        } catch { $scopeRead = $true }
    }
    $seen = $false
    try { $seen = [bool][string](Get-DomeniaSetting -Name 'Home.DashboardSeen' -Default '') } catch { $seen = $false }
    return Get-DomeniaFirstRunPlan -Domain $domain -Account $account -ScopeDn $scopeDn -ScopeName $scopeName -IndexedObjects $indexed -DashboardSeen $seen -ScopeRead $scopeRead
```

**Le choix du « pas de marqueur du tout ⇒ inconnu ⇒ on ne verrouille pas » est délibéré.** `Reset-DomeniaIndexMetadataState` (`Domenia-Engine.UI.ps1:1241`) met `IndexSyncStates=@{}` et `IndexDbCount=-1` : un tableau vide signifie « jamais lu », pas « OU jamais lue ». Verrouiller le guide sur ce signal absent serait un nouveau bug. À discuter si David veut au contraire une étape 3 strictement prouvée.

### D. `Test-DomeniaBoards.ps1` — nouveau banc + compteur

- `$script:ExpectedCases` : **64 → 65** (ligne 17). Sans ça le harnais rend `Complete=False`.
- Nouveau cas inséré après « Premiers pas : le calcul de la vue part au clic… » et avant « Anciens widgets repris une fois dans la disposition » :
  `Premiers pas : l OU acceptee redessine la carte et une base remplie par une autre OU ne fait pas la premiere lecture`
- Il enchaîne les trois assertions qui manquaient : la carte doit se repeindre **sans** appel explicite à `Update-DomeniaFirstSteps` après l'acceptation de l'OU ; une base à 12 objets dont le seul marqueur concerne `OU=Autres` doit laisser l'étape 3 à « 3 » et l'étape 4 désactivée ; l'ajout du marqueur `OU=Postes` doit les passer toutes deux à ✓.

---

## 5. Ce qui est PROUVÉ / ce qui ne l'est PAS

**Prouvé** (mesures de cette séance) :
- base `83b7795` acquise et **vérifiée identique à `origin/master`** par empreinte ;
- arbre déployé dans l'invité PESTO identique à master sur tous les fichiers contrôlés, sauf `Domenia-Main.xaml` ;
- BOM `efbbbf` conservé sur les trois fichiers modifiés ;
- les 7 appels Pester de `Get-DomeniaFirstRunPlan` ne passent pas `-ScopeRead` → le défaut `$true` les préserve ;
- `Get-DomeniaFleetFreshness` n'appelle que `$script:IndexSyncStates` : aucun appel réseau dans la carte.

**NON prouvé — à faire en premier :**
- **Aucune exécution PowerShell du correctif n'a eu lieu.** Le banc nouveau n'a jamais tourné, ni en rouge, ni en vert.
- Le banc n'a pas été écrit **contre le code non corrigé** : on ignore encore s'il échoue bien sur `Etape 2 non redessinee apres le choix de l OU`. **Commencer par là** (rouge), sinon le banc peut passer pour la mauvaise raison.
- Suites de non-régression jamais relancées après ces modifications.
- Builds DEV et PROD : non tentés.

---

## 6. Laboratoire d'exécution

`pwsh` et `powershell` sont absents du Spark **et** du Mac. Le seul endroit où exécuter est l'invité VirtualBox.

| | |
|---|---|
| Hôte | `degun@192.168.1.173` (Windows 11 26200, VirtualBox 7.2.20) |
| VM | **`PESTO-W11-TEST`** `9b2ad4f0-0506-4f58-aed2-c43ac1973516` (il n'y a plus de VM Domenia) — en marche au 20/10, avec `CNAMTS-DC01` |
| Invité | `labadmin@127.0.0.1` port NAT **2223** sur l'hôte ; PowerShell **5.1.26100.6584** |
| Arbre testé | `C:\DomeniaLab\wad\` — **à plat, sans niveau `dev/`** : `Domenia-Core.ps1`, `modules\*.ps1` (130), `tests\Test-DomeniaBoards.ps1` |
| Invité au 20/10 | empreintes **identiques à master** sur les 6 fichiers contrôlés → invité vierge de tout correctif, idéal pour le rouge. `Domenia-Main.xaml` diffère (`53364970…` contre `ab16ce00…` master) : à resynchroniser |
| L'invité n'a **ni git ni pwsh** → on déploie des fichiers, on ne clone pas |

### Voies d'accès depuis le Spark (sans le Mac)
Scripts dans `/home/m4d135/dav/tmp/pesto/` : `mac.sh` (bash sur le Mac, clé `~/.ssh/spark_access`), `guestps.sh` (PowerShell sur stdin dans l'invité), `hostps.sh` (PowerShell sur l'hôte), `jssh2.exp` (saut imbriqué, `HOSTPASS`/`GUESTPASS`). Les `.exp` **ne sont pas `+x`** : les lancer par `expect <fichier>`.

### Le plafond qui bloque le déploiement — problème ouvert
La commande traverse `bash → ssh → cmd.exe (hôte) → ssh → cmd.exe (invité)`. **cmd.exe plafonne sa ligne à 8191 caractères.** Mesuré le 20/10 : une charge utile de **2 500** caractères passe, **4 000 sont perdus sans aucune erreur**. Comme `guestps.sh` encode en UTF-16LE puis base64, le grossissement est d'environ ×2,7.

- `guestpush.sh` (base64 fragmenté, morceaux de 8 000) : **échoue silencieusement**. Recalculer à ≤ 2 500 par morceau si on reprend cette voie — soit ~25 allers-retours pour le fichier de test de 193 838 o.
- `guestcopy.sh` (scp sur l'hôte puis `VBoxManage guestcontrol copyto`, sans plafond) : **n'a pas fonctionné** au premier essai (`INSTALLE_ABSENT`). Syntaxe pourtant vérifiée sur l'hôte : `copyto` prend un **`--target-directory`**, pas un fichier cible. À reprendre — c'est la voie propre.
- `lab.sh` (`dev/engineering/d120/lab/`) est la voie prévue mais elle exige le socket de relais ouvert par le Mac (`~/Downloads/Domenia-lab/relais.sh`) et cible `CNAMTS-W11-01` par défaut (`DOMENIA_VM=PESTO-W11-TEST`).

### Lancement du banc
```powershell
# dans C:\DomeniaLab : harnais Boards, 65 cas, fixtures fictives example.invalid, aucun réseau
& 'C:\DomeniaLab\wad\tests\Test-DomeniaBoards.ps1' -Filter 'Premiers pas : l OU acceptee'
```
`Complete` exige `$script:Results.Count -eq $script:ExpectedCases` sauf avec `-Filter`.

---

## 7. À faire, dans l'ordre

1. **Rouge.** Déployer le seul `Test-DomeniaBoards.ps1` modifié sur l'invité encore intact, lancer avec `-Filter`. Le nouveau cas **doit échouer** sur `Etape 2 non redessinee apres le choix de l OU`. S'il passe, le banc est faux : le corriger avant d'aller plus loin.
2. **Vert.** Déployer les deux modules corrigés (+ `Domenia-Main.xaml` de master) et relancer.
3. **Non-régression.** Suites complètes : `Test-DomeniaBoards.ps1` (65), `Test-DomeniaFreshness.ps1`, `Test-DomeniaWiringCache.ps1`, `Test-DomeniaOuRefresh.ps1`, et Pester `tests/rules/Delivery.Tests.ps1` (FRN-001..003) — la signature de `Get-DomeniaFirstRunPlan` a changé.
4. **Build DEV puis PROD** (demande explicite de David, **PROD prioritaire**) via `dev/tools/Fabriquer-Prod.ps1` sous PowerShell 5.1 : `#requires -Version 5.1`, `param([string]$SourceWad='',[string]$OutputDirectory='',[string]$LauncherPath='')`, `Set-StrictMode -Version 2`, dot-source `Production.Source.ps1` (24 779 o, `New-DomeniaProductionPayload` en `:259`), copie le lanceur en `Domenia.exe` (`:290`) et écrit `wad/package-manifest.json` (`:331`). Défauts : `SourceWad=<dev>/wad`, `LauncherPath=<dev>/Domenia.exe`. **Les DLL du dossier wad doivent déjà être compilées ; l'outil ne télécharge rien, ne compile rien, ne lance jamais l'application.**
5. **Pousser** sur GitHub — Git uniquement via le Mac.

---

## 8. Pièges (coûteux, déjà payés)

- **BOM UTF-8 obligatoire** sur les `.ps1` (`efbbbf`). Vérificateur : `/home/m4d135/.qwen/tmp/verif-encodage.py`.
- **`ExpectedCases`** : tout `Case` ajouté impose d'incrémenter la ligne 17, sinon `Complete=False`.
- **Vue WPF en VM** : écran 1024×768 en session 0 non interactive, fenêtre bornée 1044×788, `DgObjects` écrasé 294×0. Un banc qui mesure du rendu doit imposer son viewport ; sans rapport avec les assertions d'état.
- **`$script:IndexDbCount` est global** (`Counts.Total`) : ne jamais en déduire l'état d'une OU. C'est la cause du symptôme 3.
- **Ne pas réutiliser les hypothèses de la séance précédente** : deux des trois étaient fausses sur master. Toujours re-dériver les lignes sur la base autoritaire avant d'affirmer une cause.
- **Anti-boucle** (leçon du 16/08) : ne jamais relancer une commande déjà exécutée à l'identique. Après deux appels identiques, s'arrêter et demander.
- **`failed to get: -25308` / `failed to store: -25308`** sur les opérations Git du Mac : bruit macOS Keychain sans effet. Vérifier par `ls-remote`, pas par le code de retour.
- Le Mac dort en pleine opération : `caffeinate` actif (pid 89893, `192.168.1.128`). Le PATH SSH non interactif n'a pas Homebrew et `timeout` n'existe pas.

## 9. Interdits (doctrine David)

Ne jamais redémarrer vLLM, les conteneurs ou la machine sans accord. Un seul grand modèle servi à la fois, bascule uniquement par `~/ai/spark-llm/deploy/switch-model.sh`. **Ne jamais réinitialiser ni nettoyer le clone du Mac** ; ne jamais rsync Spark→Mac ; préserver les travaux concurrents de Codex. Aucun nouveau réseau, DNS ou daemon. Aucun secret dans les notes ni le dépôt. Rester sur `spark-local` (économiser les tokens distants). Après chaque étape, actualiser le reçu et le point de reprise.
