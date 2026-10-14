# Brief Codex — Domenia D120, reprise après la pause du 13/10

**Destinataire : Codex.** Rédigé par Qwen (Spark) le 14/10/2026, à la suite d'un audit **en lecture seule** de 8 passes. **Aucune écriture, aucun commit, aucun build, aucun test n'a été lancé par cet audit.** Le clone n'a pas été modifié.

Règles rappelées : Domenia = Codex (notes KBZA `domenia-codex-only-2026-10-04` et `-retour-2026-10-04`). Le Spark n'intervient qu'en inspection sur demande de David. Pause « économie de tokens » en vigueur : ne pas relancer d'agents ni de LLM au seul motif de lire ce document.

---

## 1. État vérifié

| Objet | Fait mesuré |
|---|---|
| Clone | `/Users/david/Documents/Projets/Domenia-D120`, `master` = `42e87e6` = `origin/master` (0/0) |
| GitHub | privé, **1 seule branche distante** (`master`), 0 PR, 0 issue, 0 run Actions, 0 release |
| Dernier push | 13/10 18:38 UTC — `42e87e6` ne contient **que** `dev/engineering/d120/programme-2026-10-13/FEUILLE-DE-ROUTE.md` |
| Packs publiés | `packs/Domenia_PROD.zip` 2 100 479 o `9cc5dfc5…`, `packs/Domenia_DEV.zip` 4 403 845 o `fcb09dfc…`, 94 fichiers runtime identiques, publiés à `fb03e2b` (RC1.17.6) |
| Qualification du pack publié | `packs/manifest.json` → `qualification.status = LOCAL_CHECKS_PASSED_WINDOWS_NOT_RUN` |
| Travail local | **72 fichiers modifiés** (+6009 / −1508) + **65 entrées non suivies** (dont 25 nouveaux modules et 26 nouveaux bancs) |
| Stabilité | **0 fichier modifié après le relais** (seuil 13/10 21:41) — l'arbre est figé tel que décrit par `RELAIS-PROJET.md` |
| Inventaire | `relais-technique/ETAT-FICHIERS.json` couvre **132/132** fichiers de travail |

**Risque n°1 — sauvegarde.** Tout le travail applicatif est sur une seule machine, non commité, non poussé. `RELAIS-PROJET.md` : « Un nouveau clone GitHub ne les récupérera pas. » Au moment de l'audit : pas de `caffeinate` sur le Mac, pas de socket de relais labo. **Premier geste recommandé : branche WIP poussée ou archive + SHA-256 vérifiée, avant toute autre opération.**

---

## 2. Le défaut n°1, reformulé (le relais était imprécis)

`Get-DomeniaLogonHarvestWorkerCode` — `dev/wad/Domenia-Core.ps1:16718`.

- `Get-WinEvent` appelé **L16737** : `try { $events = @(Get-WinEvent @params) }`
- **`catch` interne L16738-16743** : classe l'erreur en `REFUSE`/`ERREUR` et **`return`** un objet statut.

Le mécanisme réel de la garde (à connaître avant toute correction statique) :

- `Domenia-Core.ps1:23908` expédie dans le runspace 8 fonctions — `Get-DomeniaStructuredError`, `Get-DomeniaCredentialAccountKey`, `Set-WCredentialAttemptIdentity`, `Get-WCredentialGuardKeys`, `Assert-WCredentialAllowed`, `Enter-WCredentialAttempt`, `Exit-WCredentialAttempt`, `Register-WCredentialFailure` — **toutes définies dans `dev/wad/modules/Domenia-Guard.Model.ps1`, aucune dans le Core**.
- `Domenia-Core.ps1:23914` enveloppe le métier : `try { Assert-WCredentialAllowed -Context $Context ; <métier> } catch { Register-WCredentialFailure … ; throw }`.

**Conséquence : le `return` du catch interne L16738 empêche le `catch` du wrapper L23914 de s'exécuter. `Register-WCredentialFailure` n'est jamais appelé sur ce chemin** — la protection anti-verrouillage de compte n'apprend rien des refus de ce diagnostic. Le défaut n'est pas « appel de garde manquant », c'est **évasion du wrapper**. Corriger en relançant (`throw`) ou en appelant explicitement `Register-WCredentialFailure` avant le `return`, pas en ajoutant un `Enter-` décoratif.

**Contre-exemple sain, à ne pas « corriger »** : second site `Get-WinEvent` **L19053** (journal Security 4624). Son `catch` **L19055** appelle bien `Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote`. Il est gardé.

**Écart à trancher (non concluante en statique)** : `Enter-WCredentialAttempt` / `Exit-WCredentialAttempt` sont expédiées aux workers mais **jamais appelées** dans les ~1 700 lignes de `Get-DomeniaIndexWorkerCode` ni dans le harvest. Leur rôle (`Domenia-Guard.Model.ps1:117-128`) est de **sérialiser l'authentification** (`Monitor::Enter`, file d'attente, `WaitSeconds=120`). Sans elles, `Assert-WCredentialAllowed` refuse si c'est déjà bloqué, mais rien n'empêche N workers de frapper le DC en parallèle. À départager : conception assumée ou oubli.

---

## 3. Raccordements manquants — confirmés dans le code

**8 modules non déclarés** dans `dev/wad/Domenia-Modules.ps1` (le registre est obligatoire : « ajouter un fichier ne suffit pas ») :

```
Domenia-QueryDetails.UI      Domenia-QuerySchema.Model    Domenia-QuerySchema.UI
Domenia-QuerySchema.Worker   Domenia-QueryTransfer.UI     Domenia-QueryTransfer.Worker
Domenia-SearchWorkspace.Model  Domenia-SearchWorkspace.UI
```

- `SearchWorkspace` : **0 occurrence dans tout le XAML**. Non livrable en l'état, comme l'annonçait le relais.
- Ancre d'intégration des résultats (du relais) : `</Grid></StackPanel><Grid Grid.Row="1">`, puis ligne vide, puis `DgObjects`.
- `Domenia-CredentialVault.Native.cs` absent du registre : **normal**, les `.cs` n'y figurent pas (`Clipboard.Native.cs`, `Sessions.Native.cs` non plus). Ne pas « corriger ».

**Contrats d'opérations** (`dev/tools/operation-contracts.json`, 74 entrées) :

- `StorageMaintenance` → **`Sha256` entièrement à zéro** (placeholder confirmé).
- **Aucune entrée** pour `QuerySchema`, `QueryDetails`, `QueryTransfer`, `StoreRead`, `FleetStats`.
- L'UI invoque `-OperationId 'StorageRetention'` (dans `Domenia-Storage.UI.ps1`) **absent des contrats**.
- `QueryExport` et `QueryLibrary` **sont** déclarés — à conserver tels quels.
- ⚠️ Le générateur `dev/tools/update_worker_contracts.py` n'a **pas de mode `--check`** (seulement `--apply`, `--add`, `--remove`, `--file`, `--literal-index`). Les 73 autres empreintes n'ont donc **pas** pu être vérifiées en lecture seule : à valider par un run dédié, pas au jugé.

**DLL antérieures aux sources** (rebuild obligatoire après gel) :

| DLL | mtime | sources plus récentes |
|---|---|---|
| `dev/wad/modules/Domenia.Native.dll` | 13/10 20:50 | `dev/native/ObservationReader.cs` 21:29, `dev/vendor/m4d-admin-common/src/Query/QueryEngine.cs` 21:27 |
| `dev/wad/modules/M4D.Admin.Common.Query.dll` | 13/10 20:40 | idem |

**`domenia_domain_metadata`** : `CREATE TABLE` présent à `Domenia-Core.ps1:23268`, et **une seule occurrence dans tout `dev/wad`** — ni writer, ni reader, ni validation. Le relais était exact. Contrat envisagé par le relais : `DomainDn`, `Family=AdSchema`, `RequestKey`, `Data`, statut et dates séparées.

**`StorageContext.UI`** : le relais a raison. `dev/wad/modules/Domenia-StorageContext.UI.ps1:18` exécute un `Invoke-DomeniaDbQuery 'SELECT store_id,domain_dn,revision FROM domenia_store_state WHERE id=1;' $db` sur le fil appelant, et `:54-55` rappelle `Initialize-DomeniaDatabase` + `Initialize-DomeniaQueryLibraryStore -Force` dans `Resume-DomeniaDatabaseViews`. Le déplacement vers un worker Maintenance (`SchemaReady` / `TargetWritable`) reste à faire.

---

## 4. Deux points où la documentation est en retard sur le code

1. **Export complet — déjà implémenté.** `FEUILLE-DE-ROUTE.md` point 8 dit l'export total « nécessaire ». Il existe dans l'arbre de travail : `Domenia-Query.UI.ps1:537` `Start-DomeniaQueryExport`, `:554` `Start-UiTask -Name 'Exporter tous les résultats de la requête' -OperationId 'QueryExport'`, `:564` contrôle `if($null -eq $result -or -not $result.Complete){Fail-DomeniaQueryExport …}`, et l'opération est dans les contrats. **Ne pas la réécrire** — la qualifier.
2. **Les limites de l'atelier ont déménagé.** `FEUILLE-DE-ROUTE.md` cite `Domenia-Query.Model.ps1` pour « 100 recettes et 1 Mio ». Ces constantes vivent désormais dans **`Domenia-QueryLibrary.Model.ps1`** (`Limit=100`, `1048576` ×2). `CountBy` à 10 000 catégories est confirmé dans `QueryEngine.cs:35`, `:122`, `:356`. Pour `Domenia-Live.Model.ps1:46`, le `20` est **`MaxQueries=20`** (nombre de requêtes), avec `MaxRows=20000` — la formulation « vingt éléments de détail » de la feuille de route est imprécise.

---

## 5. Pièges d'outillage (coût déjà payé, ne pas le repayer)

- **Encodage** : `Domenia-Core.ps1` et les `.ps1` de bancs sont commités **UTF-8 avec BOM**. Lire en `utf-8-sig`, réécrire `BOM + texte.encode('utf-8')` ; comparer avec `git show HEAD:<fichier>`. BOM perdu → `Unexpected token 'aucune'…` ; BOM double → `Unexpected attribute 'CmdletBinding'`. Deux campagnes perdues le 11/10 pour ça.
- **Portée de fonction en statique** : ne **jamais** délimiter une fonction de `Domenia-Core.ps1` par regex `^function` — les here-strings `@' … '@` contiennent des `function` en colonne 0. Mesure d'erreur : « `Get-DomeniaIndexWorkerCode` : 8 lignes » alors qu'il en fait ~1 700.
- **Banc `Test-Domenia.ps1`** : n'injecte que les fonctions de `$wanted` (30 noms) et ne définit que `Assert-True`. Les 26 nouveaux bancs sont **autonomes** (26/26 avec leur propre `Assert`/`Case` ou extraction AST) — ils ne passent pas par `$wanted`.
- **Bancs** : un script qui se rattache à `$PSScriptRoot` valide l'arbre où il est rangé, jamais l'arbre synthétique du banc — `Copy-Item` le script sous test dans l'arbre synthétique avant de l'invoquer.
- **Lanceur de suite** : `powershell -STA -File <suite> -ReportPath <rapport>`, un processus par suite (`Invoke-LabRun.ps1:22`). Lancer plusieurs suites dans le même processus invente des échecs de résolution de noms.
- **Verdict** : `PASS -> None` = test disparu (renommé/supprimé), pas une régression ; seule `PASS -> FAIL` en est une. Rapports de suite en **UTF-8 BOM**, compteurs sous `Tests` ou `Results`, détail sous `Detail` **ou** `Error`.
- **Empreinte/verdict** : arbre propre et commité **avant** de lancer une campagne, sinon « Campagne non liee a l arbre local ».
- **`acceptance_passed`** n'est jamais posé par une campagne : seul `release_guard.py --require-windows` le fait, sur le ZIP.
- **Manifestes** : `build_packages.py --manifest-only` se lance depuis `dev/` avec `--output` ; réécrit en place `dev/wad/package-manifest.json` **et** `dev/tools/prod-manifest.json` — à committer quand un fichier **runtime** change, pas quand seul un test change.

---

## 6. Ordre de reprise proposé

1. **Sauvegarder** le travail non commité (branche WIP poussée ou archive + SHA-256). Préserver les non-suivis.
2. **Garde de compte** : corriger l'évasion du wrapper L16738 ; trancher `Enter-/Exit-WCredentialAttempt` dans les workers ; exercer le chemin réel depuis `Test-DomeniaCredentialGuard.ps1` (241 lignes, 14 références à la garde, **ne redéfinit pas** les fonctions de garde — il doit donc les recevoir du produit).
3. **Raccordements** : déclarer les 8 modules orphelins, câbler `SearchWorkspace` au XAML et au registre, finir `StorageContext.UI` → worker Maintenance, raccorder `ObservationProjection=Summary` à Fleet/Park, écrire `domenia_domain_metadata`.
4. **Geler les sources**, puis régénérer dans l'ordre : contrats (`update_worker_contracts.py --apply`, y compris le SHA `StorageMaintenance`), migration, baselines de préchargement, manifests, limites de distribution ; **reconstruire Native et Query** et leurs empreintes.
5. **Puis seulement** : parsing, contrats, modèles purs, scénarios de panne, qualification native PS 5.1 / net472, charge 10 000 / 20 000, parcours graphiques (≥ 1080p, sans infobulles).
6. Guides DOCX/PDF v1.0 alignés sur le pack, deux packs cohérents, commit/push et **vérification distante**.

Cible : **10 000 postes minimum**, qualification recommandée **20 000**. Les mesures antérieures à 5 000 postes ne valident pas ce seuil, et le `work-ledger` conserve encore une cible 5 000 à réconcilier.

---

## 7. Ce que cet audit n'a pas pu établir

- Les 73 empreintes de contrats non nulles (aucun mode `--check` côté générateur).
- Le comportement d'exécution réel des workers en runspace — tout ce qui précède est de l'analyse statique.
- Toute qualification Windows : PC de test éteint, pas de socket de relais labo (`/tmp/domenia-lab-*.sock` absent), `caffeinate` non relancé.
- La disponibilité du Mac graphique et de VirtualBox n'a pas été vérifiée ; ne pas réutiliser un ancien résultat de disponibilité comme preuve.
