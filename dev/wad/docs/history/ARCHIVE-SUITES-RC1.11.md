# Suites historiques : remise à niveau et archivage (RC1.11.0, lot D120 « suites »)

Date : 2026-10-02. Rédigé à partir de la lecture du code, des rapports de la ligne de base Windows PowerShell 5.1
(`engineering/d120/lab/baseline-5.1-r1-summary.json`, `baseline-5.1-r3.txt`, `baseline-5.1-vm.txt`) et de la carte
`engineering/d120/raccordement/carte-historic-suites.json`.

**Rien n'a été exécuté par ce lot** (décision de l'utilisateur : « finis tous les points de modifs avant les tests »).
Seuls des contrôles statiques ont tourné (analyse syntaxique 5.1 et garde-fou de compatibilité dans la VM, contrôle
statique Python sur le Mac). Aucun cas ci-dessous n'est annoncé réussi : la campagne Windows reste à faire.

## 1. Classement des 63 échecs de la ligne de base (8 suites)

| Suite | Échecs | Classement | Correction appliquée |
|---|---|---|---|
| `Test-DomeniaAccounts` | 20 | RESYNC_TEST (17 réécrits vers le contrat asynchrone M15, 3 par chargement d'Access.UI) | Import du plan fermé réel (`Domenia-Modules.ps1`), `Set-ControlsBusy` réel, doublures `Show-DomeniaOperationError`, `Update-DomeniaSecretActionUi`, champs mot de passe avec `Clear()`. Chaque cas déclenche lui-même `Complete-DomeniaAccountValidation` (le minuteur n'est jamais pompé). Le double `WaitOne` lève une exception : tout retour à une attente bloquante fait échouer la suite. |
| `Test-DomeniaRelease` | 20 | 18 RESYNC_TEST, 2 REAL_DEFECT (lot accès) | Plan fermé réel (Guard.Model, Sessions.UI), état d'accès construit par le vrai `Initialize-DomeniaAccess` (champ `Expires` et suivants), registre comparé au contrat DEV. |
| `Test-DomeniaRemote` | 14 | 12 RESYNC_TEST, 2 ARCHIVE | Paramètre de libellé `$CaseLabel` (le paramètre `$Name` masquait `$name`), consentement explicite dans le contexte, plan fermé réel, doublures `Get-WRemoteWindowsDirectory` et `Set-Acl`, disposition `Temp\DOMENIA_<id>\run.ps1`, filtre LogonUI sur Method et Status. |
| `Test-DomeniaLastUser` | 2 | RESYNC_TEST | Plan fermé réel (Selection.UI, Access.UI) ; la purge est mesurée par `SelectedObjectGeneration` et `SelectedObject` (Enter-DomeniaSelectionContext), plus par un double qui n'est plus appelé. |
| `Test-DomeniaStartupLogin` | 3 | RESYNC_TEST (défaut du test propre à 5.1) | `ConvertFrom-Json` affecté puis énuméré par `@()` ; les deux cas qui épinglaient « 57 » (réussis) deviennent contractuels. |
| `Test-DomeniaStreaming` | 2 | RESYNC_TEST | Registre comparé au contrat ; la vérification part de l'intention de sélection (RC1.10.7 : « limité au seul poste sélectionné »). |
| `Test-Domenia` | 2 | 1 RESYNC_TEST, 1 NON_DETERMINE | Registre : corps cherchés dans tous les fichiers du contrat. CSV : instrumenté (voir §4). |
| `Test-DomeniaModules` | arrêt l.105, pas de rapport | RESYNC_TEST (harnais) | Seules les erreurs non interceptées arrêtent la sonde (`Streams.Error`), fixtures avec `*.cs`, totaux tirés du plan, invariant plan = définitions par fichier. |

Aucun corps de worker épinglé n'est modifié par ce lot : aucune empreinte d'opération ne change.

## 2. Cas archivés (retirés de la suite active, remplacés par la preuve du comportement voulu)

### `Test-DomeniaRemote` « PsExec: compte poste explicite prioritaire, mot de passe preserve »

- Ce que le cas affirmait : `-u <compte>` et `-p <mot de passe>` présents dans les arguments de PsExec.
- Pourquoi c'est retiré : le transport par mot de passe en ligne de commande a été supprimé volontairement.
  Preuves : `Invoke-WRemotePsExecScript` (code commun des workers, `wad/Domenia-Core.ps1`) lève
  « Ce transport ne prend pas de mot de passe en ligne de commande. Utilisez CIM/DCOM ou une session Windows
  autorisee. » dès qu'un compte machine est fourni ; `Invoke-WQuietProcess` refuse `-p`, `/p` et `/rp` ;
  `CLAUDE.md` règle 3 : aucun secret « dans un argument de processus ».
- Remplacé par : « PsExec: compte explicite refuse, aucun mot de passe en ligne de commande » (exception attendue,
  aucun processus lancé) et « Depot distant refuse sans consentement explicite ».

### `Test-DomeniaRemote` « schtasks: meme compte poste et tableau arguments conserve »

- Ce que le cas affirmait : `schtasks.exe /s <poste> /u <compte> ...` avec le tableau d'arguments conservé.
- Pourquoi c'est retiré : `Invoke-WSchtasksRemote` passe par l'API COM du Planificateur (commentaire « Historical entry
  point, now using the Task Scheduler COM API instead of CLI credentials ») et interdit `/u`, `/p`, `/rp`. Le cas
  ouvrait en plus une vraie connexion `Schedule.Service.Connect('TESTPC')` (HRESULT 0x80070032 dans la ligne de base),
  contraire à l'en-tête de la suite (« aucune connexion »).
- Remplacé par : « Planificateur: identifiants en argument refuses » et « Planificateur: seules les taches propres a
  l operation » ; les deux gardes s'appliquent avant toute création d'objet COM.

## 3. Cas renommés (la comparaison `compare_runs.py` les voit comme retirés puis ajoutés)

| Suite | Ancien nom | Nouveau nom | État à la ligne de base |
|---|---|---|---|
| StartupLogin | Remplacer une operation en conservant 57 entrees est refuse | Remplacer une operation en conservant le nombre d entrees est refuse | réussi (même assertion ; le nombre 57 devenait faux avec les nouvelles opérations D120) |
| Modules | 22 modules verifies, sans scanner les scripts supplementaires | Modules du plan ferme verifies, sans scanner les scripts supplementaires | jamais mesuré (arrêt l.105) |
| Modules | 255 fonctions disponibles dans la portee appelante | Fonctions du plan ferme disponibles dans la portee appelante | jamais mesuré |
| Release | Registre de 48 operations ferme | Registre ferme conforme au contrat DEV | échec |
| Streaming | Registre fermé de 48 opérations | Registre fermé conforme au contrat DEV | échec |
| Test-Domenia | Registre ferme : 47 corps et rejet d un corps modifie | Registre ferme : corps du contrat DEV et rejet d un corps modifie | échec |

Règle appliquée partout : aucun nombre d'opérations, de modules ou de fonctions n'est écrit en dur. Il est dérivé de
`tools/operation-contracts.json` (lu en deux temps à cause de `ConvertFrom-Json` sous 5.1) ou du plan fermé
(`Get-DomeniaRuntimeModulePlan`, lu par AST).

## 4. Restes connus, non masqués

- **REAL_DEFECT, lot accès** — `Test-DomeniaRelease` « Rejet global du canal AD renvoie au login principal » :
  `Request-DomeniaAccessRecovery` (`Domenia-Access.UI.ps1`) ne classe pas le message « Canal Active Directory
  suspendu… » ; la reconnexion guidée n'est jamais proposée. Correctif local proposé par la carte : après le calcul de
  `$kind`, `if(-not $kind -and [string]$ErrorValue -match '(?i)Canal Active Directory suspendu'){$kind='LogonFailure'}`.
  Hors du périmètre de fichiers de ce lot : demandé au lot accès. Le cas reste en échec jusque-là.
- **REAL_DEFECT (durcissement), lot accès** — `Test-DomeniaRelease` « Refus de dechiffrement LAPS reconnu » : le texte
  brut du worker ReadLaps n'est reconnu par aucun motif de `Get-DomeniaStructuredError`. La carte accès (site D052)
  prévoit le motif `droit de d[eé]chiffrement`. Assertion conservée telle quelle (non affaiblie).
- **NON_DETERMINE** — `Test-Domenia` « CSV : formules, separateurs, textes et nombres » : aucune cause trouvée par lecture.
  Chaque assertion porte maintenant son propre message (valeur, type, culture, CSV brut). La règle de neutralisation
  n'est pas modifiée avant le rapport Windows qui nommera l'assertion fautive.
- **REAL_DEFECT probable, lot interface (D006)** — lu dans le XAML principal, non exécuté : `LblLiveState`,
  `LblSuiteResultCount` et `LblBranchCount` passent à la ligne (`TextWrapping="Wrap"`) sans hauteur réservée au-dessus
  de `DgObjects`. Quand une recherche met ces textes à jour, la grille et ses boutons descendent aux largeurs étroites.
  La fenêtre principale a `MinHeight="640"` : plus haute que la zone de travail à 1366×768 125 %, 1920×1080 175 % et
  200 %. `Test-DomeniaGeometry` le mesurera ; la correction relève de D082/D090.
- **Audits Python périmés hors du périmètre de fichiers du lot** : `wad/tests/audit_accounts.py` (attend encore le
  `WaitOne` synchrone de R1.4 dans le cœur), `wad/tests/audit_lastuser.py`, `wad/tests/audit_remote.py`,
  `wad/tests/audit_streaming.py`. Aucun n'est lancé par `build_packages.py`. À archiver par l'intégrateur de la même façon
  que les audits de `tools/` (§5).

## 5. Audits Python historiques archivés (`legacy-audits/`)

Ces scripts vérifiaient chacun **une livraison passée** par rapport à une archive ou à une référence figée. Aucun n'est
lancé par `tools/build_packages.py`, qui n'utilise que `release_contract.py`, `audit_function_names.py`,
`validate_powershell_static.py`, `audit_preload.py`, `update_worker_contracts.py` et `release_guard.py`. Les mettre « à
jour » reviendrait à réécrire leur référence, ce qui leur ôterait leur sens. Ils sont conservés tels quels pour
l'historique ; ils ne s'exécutent plus depuis ce dossier (imports relatifs à `tools/` et `wad/tests/`).

| Audit | Livraison | Fait figé devenu faux ou invérifiable |
|---|---|---|
| `audit_acl_hotfix.py` | RC1.1-ACL | exige `--baseline-dev` (ZIP RC1 absent du dépôt) |
| `audit_activity_layout.py` | RC1.7 | « Exactly the 577 existing core functions » (579 dans `tools/preload-baseline.json`) |
| `audit_candidate.py` | RC1.9 | « 57 closed operations » et schéma SQLite « 11 » épinglés ; contrôles repris par `update_worker_contracts.py` et `audit_preload.py` |
| `audit_integrated.py` | RC1.9 | référence `RC1.9-source-baseline.json`, « exactly twenty unique functions », quatre `ShowDialog` |
| `audit_module_hotfix.py` | RC1.2 | exige `--baseline-dev` ; « 20 declared script modules », « 209 function exports » (30 entrées et 445 fonctions déclarées au plan à cette date) ; réécrit `wad/docs/RC1.2-Modules.patch` |
| `audit_relations_alignment.py` | RC1.8 | « Registry remains 55 operations » |
| `audit_release.py` | RC1 | « 48 pinned operations », exactement 43 cas dans `Test-DomeniaRelease` |
| `audit_search_presence.py` | RC1.4 | « 55 registered workers », « 20 explicit module plans » |
| `audit_selection.py` | RC1.3 | exige `--baseline-dev` (ZIP RC1.2 absent) |
| `audit_stable_ui.py` | RC1.6 | « Exactly same 55 reviewed worker operations », « Only four presentation-related core functions modified » |
| `audit_startup_login.py` | RC1.5 | « Exactly 55 reviewed operations », exactement 44 cas dans `Test-DomeniaStartupLogin` |

## 6. Nouvelles suites du lot (écrites, non exécutées)

- `wad/tests/Test-DomeniaRegressions.ps1` (D005) : chaque scénario exécute la même vérification sur la version fautive
  (fixture historique, ou garde retirée quand la version d'origine n'existe plus que dans les notes) puis sur le code
  livré : dépendances non chargées (RC1.1), compteur 55/54 (RC1.4), expression invalide après `-or` (RC1.10.x),
  concaténation PsExec (R1.2), tableau d'octets déroulé, préchargement débranché (RC1.10.6), retour tardif (RC1.3,
  RC1.10.7), lecture JSON sous 5.1 et masquage de `$name` (harnais). Un catalogue vérifie que les reproductions déjà
  présentes dans les autres suites et leurs fixtures restent en place.
- `wad/tests/Test-DomeniaGeometry.ps1` (D006) : neuf configurations (bureau, 125 à 200 %, portable 1366×768, RDP
  1024×768), thèmes clair et sombre, fenêtre réelle à la taille de la zone de travail en unités WPF. Champs essentiels
  visibles et atteignables ; positions de la recherche, des résultats et de leurs boutons inchangées pendant une
  opération, l'arrivée des résultats, la mise à jour des compteurs et le mode écriture. Les fenêtres plus grandes que
  l'écran sont listées dans `Observations`.
- `wad/tests/Test-DomeniaFaults.ps1` (D007) : DNS lent, refus AD, déchiffrement LAPS refusé, disque plein, SQLite
  verrouillé (verrou réel winsqlite3), coupure après envoi (enveloppe d'écriture réelle de `New-DomeniaWorkerRunspace`
  et reçus réels). Corps de worker épinglés vérifiés par leur empreinte avant exécution.
- `wad/tests/Test-DomeniaWiringSuites.ps1` (D004, D008 et raccordement des suites) avec la bibliothèque
  `wad/tests/fixtures/Domenia-AdFixtures.ps1` ; règles de courses générées (graine fixe) dans
  `wad/tests/rules/Races.Tests.ps1`, chargées par `Test-DomeniaRules.ps1`.

## 7. Intégration du 2026-10-02 (branche `claude/epic-newton-j5ir1w`)

Suites des « Restes connus » (§4) après la fusion des lots :

- `Request-DomeniaAccessRecovery` classe désormais « Canal Active Directory suspendu » en `LogonFailure` et
  `Get-DomeniaStructuredError` reconnaît « droit de déchiffrement » (lot accès). Les deux cas de `Test-DomeniaRelease`
  restent à confirmer sous Windows PowerShell 5.1.
- `LblLiveState`, `LblSuiteResultCount` et `LblBranchCount` ne passent plus à la ligne : hauteur réservée (18 unités),
  texte tronqué avec infobulle complète (D082). `MinHeight="640"` de la fenêtre principale n'est pas modifié : décision
  d'interface à prendre avec la mesure de `Test-DomeniaGeometry`.
- Archivés dans `legacy-audits/` comme ceux de `tools/` : `audit_accounts.py`, `audit_lastuser.py`, `audit_remote.py`,
  `audit_streaming.py` (motifs du §4) et `audit_experience.py` (exige l'ancien littéral
  `Update-DomeniaExperienceActivity -Force:$Force` du lot moteur et une référence `experience-baseline-r110.json` absente
  du dépôt : il ne s'exécutait déjà plus). Aucun n'était lancé par `build_packages.py`.
