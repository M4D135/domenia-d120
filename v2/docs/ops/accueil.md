# Accueil — opérations `accueil.*`

Contrat des opérations propres à l’écran Accueil (lot `accueil`, fonctions ACC-001 à ACC-064 de
[`FEATURES.md`](../FEATURES.md)). Il complète [`OPERATIONS.md`](../OPERATIONS.md), qui garde les opérations communes
(`app.info`, `session.info`, `dashboard.*`, `directory.ou.*`, `session.setScope`) et les règles de l’enveloppe, du JSON,
des classes d’opération et de l’admission (§ 1). L’état de chaque fonction est dans
[`status/accueil.json`](../status/accueil.json).

| Élément | Emplacement |
|---|---|
| Modèles et calculs purs | `src/Domenia.Core/Screens/Accueil/` (`FleetCatalog`, `FleetBoardCalculator`, `HealthPolicy`, `CollectionClocks`, `ProbeCatalog`, `FleetAnalysis`, `WindowsLifecycle`) |
| Service de l’écran | `AccueilService` (partagé par contexte, `AccueilService.From(context)`), `AccueilRefresh.cs` (actualisation de l’OU) |
| Interface de lecture | `IAccueilReader` (`FactsAsync`, `HistoryAsync`, `ReadBitLockerAsync`, `CollectProbesAsync`, `ReadInventoryAsync`) |
| Règles de l’actualisation | `RefreshRules` (refus d’une nouvelle collecte, « collecter seulement ce qui manque ») |
| Simulation | `src/Domenia.Simulation/Screens/Accueil/` (`SimulatedAccueilReader`, `SimulatedProbeValues`) |
| Module du pont | `src/Domenia.Bridge/Operations/AccueilOperations.cs` (36 opérations) ; `src/Domenia.App/AccueilJournalOperations.cs` (`accueil.log.tail`, journal technique de l’hôte ; mesure de l’espace libre du volume des données) et `AccueilHostFiles.cs` (lecture du journal, espace libre ; compilé aussi dans les tests) |
| Page | `web/js/pages/accueil.js` et `web/js/pages/accueil/*.js` ; `web/css/pages/accueil.css` ; aperçu du navigateur `web/js/mock-accueil.js` |
| Tests | `tests/Domenia.Tests/AccueilTests.cs` ; scénarios `tests/e2e/accueil/*.json` |

En mode annuaire, tant que `Domenia.Ad`, `Domenia.Inventory` et `Domenia.Store` ne servent pas `IAccueilReader`, toute
opération qui en a besoin répond `source.unavailable` (§ 16 pour ce qu’il faudra brancher, vague 3).

---

## 1. Conventions

- JSON : règles de `OPERATIONS.md` § 1.2 (camelCase, énumérations en camelCase, dates `yyyy-MM-ddTHH:mm:ssZ`, dates
  seules `yyyy-MM-dd`, champs nuls écrits, clés de dictionnaire gardées telles quelles).
- Arguments : objet ; tout champ inconnu est refusé (`arguments.invalid`). Les textes sont bornés et sans caractère de
  contrôle.
- **Préférences** (`LocalWrite`, jamais l’annuaire) : préfixe `accueil.` ; une préférence qui ne peut pas être écrite ne
  fait jamais échouer l’opération (avertissement dans le journal technique). En capture et en E2E, les préférences restent
  en mémoire.

| Clé | Contenu |
|---|---|
| `accueil.layout` | disposition du tableau du parc (`{ v: 1, items: [...] }`) |
| `accueil.firstSteps` | `{ dashboardSeen, dismissed, finished }` (`finished` : les quatre étapes faites une fois, Home.FirstStepsDone) |
| `accueil.helpSeen` | `true` une fois l’aide ouverte |
| `accueil.health.<sha>` | carnet des règles de santé du domaine (`<sha>` : SHA-256 du DN de la racine) |
| `accueil.favorites.<sha>` | OU favorites du domaine (12 au plus) |
| `accueil.lastView.<sha>` | résumé de la dernière vue par base et par OU (comptes et date, jamais un nom) ; réécrit seulement quand ses comptes changent, ou une fois par minute au plus |
| `accueil.runs.<sha>` | relevés de la session (horloges, ACC-022) : 300 au plus, relus au démarrage et réadmis par `CollectionClocks.Create` (date future ou hors du domaine écartées) ; remplacés par `Domenia.Store` en vague 3 |
| `accueil.snapshots.<sha>` | instantanés quotidiens (35 jours des quatre OU les plus récentes) et manuels (20) de l’OU : comptes et empreintes seulement, jamais un nom (ACC-040) |

- **Erreurs propres** (en plus de `OPERATIONS.md` § 1.4) :

| Code | Message (extrait) | Quand |
|---|---|---|
| `board.replaced` | Ce chiffre vient d’un calcul remplacé… | `accueil.targets` avec une révision qui n’est plus la dernière |
| `targets.unknown` | Ensemble de postes introuvable dans ce calcul… | clé inconnue du calcul |
| `probe.unknown` | Sonde inconnue du catalogue… | `accueil.probe` |
| `layout.preset` | Disposition prédéfinie inconnue… | `accueil.layout.reset` |
| `refresh.running` | Une actualisation de l’OU est déjà en cours… | plan ou exécution pendant une autre |
| `refresh.planUnknown` | Plan d’actualisation inconnu ou déjà utilisé… | plan rejoué ou inventé |
| `refresh.planExpired` | Plan d’actualisation expiré (plus de 5 min)… | plan trop ancien |
| `refresh.scopeChanged` | L’OU de travail a changé depuis le plan… | OU changée entre plan et exécution |
| `refresh.queryMissing` | Un widget de requête est absent de la bibliothèque… | relevé WMI avec un widget de requête actif |
| `refresh.refused` | Une mesure de widget est en cours… / Une lecture AD de la présence BitLocker est en cours… / Enregistrement local suspendu… / Espace disque insuffisant (ou critique)… | nouvelle collecte refusée (ACC-001) : mesure ou lecture en cours, trois échecs d’écriture locale, moins de 512 Mio libres sur le volume des données (mode annuaire seulement) ; vérifié au plan puis à la confirmation |
| `refresh.backupUnavailable` | Sauvegarde vérifiée de la base locale indisponible dans cette version… | relecture AD demandée en mode annuaire tant que la sauvegarde vérifiée de `Domenia.Store` n’existe pas (aucune lecture AD sans sauvegarde, Domenia 1 FI-13) |
| `refresh.nothingToResume` | Aucune actualisation interrompue à reprendre pour cette OU… | `mode: "resume"` sans actualisation interrompue de la même OU |
| `scope.tooWide` | (commun) | actualisation ou BitLocker demandés sur la racine du domaine |
| `snapshot.unknown`, `snapshot.same`, `snapshot.label` | Relevé introuvable… / deux relevés différents / nom invalide | analyse |
| `pivot.unknown` | Tableau croisé inconnu… | `accueil.analysis.pivots` |
| `health.invalid` | Seuil, contrôle, alerte ou suspension invalide (message précis) | `accueil.health.save` |
| `favorite.invalid`, `favorite.full`, `favorite.unknown` | nom invalide / douze au plus / introuvable | favorites |

## 2. Récapitulatif

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `accueil.board` | `LocalRead` | aucun | tableau du parc de l’OU de travail (§ 3) |
| `accueil.targets` | `LocalRead` | `{ revision, key }` | postes exacts d’un chiffre (§ 4) |
| `accueil.layout` | `LocalRead` | aucun | disposition (§ 5) |
| `accueil.layout.save` | `LocalWrite` | `{ items }` | disposition nettoyée et mémorisée |
| `accueil.layout.reset` | `LocalWrite` | `{ preset? }` | disposition livrée ou prédéfinie |
| `accueil.widgets.catalog` | `Local` | aucun | widgets, représentations, tailles, sondes (§ 6) |
| `accueil.probe` | `Local` | `{ id }` | contrat d’une sonde |
| `accueil.refresh.plan` | `LocalRead` | `{ mode }` | plan figé (§ 7) |
| `accueil.refresh.run` | `NetworkRead` (servie en simulation) | `{ planId, force? }` | compte rendu ; événements `accueil.refresh.run:progress` |
| `accueil.refresh.stop` | `Local` | aucun | arrêt demandé |
| `accueil.refresh.state` | `Local` | aucun | actualisation en cours et dernier compte rendu |
| `accueil.provenance` | `LocalRead` | aucun | fraîcheur, mesures, horloges (§ 8) |
| `accueil.collections` | `LocalRead` | aucun | relevés par OU (300 au plus) |
| `accueil.analysis.snapshots` | `LocalRead` | aucun | relevés et tableaux croisés (§ 9) |
| `accueil.analysis.compare` | `LocalRead` | `{ before, after }` | comparaison |
| `accueil.analysis.pivots` | `LocalRead` | `{ table, filter? }` | matrice et clés des cellules |
| `accueil.snapshot.take` | `LocalWrite` | `{ label? }` | instantané manuel (gardé dans les préférences locales) |
| `accueil.health.policy` | `LocalRead` | `{ dn? }` | règles d’une portée (§ 10) |
| `accueil.health.save` | `LocalWrite` | `{ dn?, policy }` | règles enregistrées |
| `accueil.health.revert` | `LocalWrite` | `{ dn }` | retour aux règles héritées |
| `accueil.health.exceptions` | `LocalRead` | aucun | exceptions par OU |
| `accueil.health.explain` | `LocalRead` | aucun | « Comprendre le score » |
| `accueil.bitlocker.read` | `NetworkRead` (servie en simulation) | aucun | présence des clés de l’OU (§ 11) |
| `accueil.scope.reset` | `LocalWrite` | aucun | `session.info` sur l’OU par défaut (§ 12) |
| `accueil.favorites` | `LocalRead` | aucun | OU favorites |
| `accueil.favorite.save` | `LocalWrite` | `{ name, dn, subtree }` | favorites |
| `accueil.favorite.drop` | `LocalWrite` | `{ id }` | favorites |
| `accueil.firstSteps` | `LocalRead` | aucun | premiers pas (§ 13) |
| `accueil.firstSteps.dismiss` | `LocalWrite` | `{ dismissed }` | premiers pas |
| `accueil.help.seen` | `LocalWrite` | aucun | `{ helpSeen: true }` |
| `accueil.lastView` | `LocalRead` | aucun | dernière vue de la même base et OU |
| `accueil.lastView.save` | `LocalWrite` | `{ revision }` | dernière vue |
| `accueil.selfCheck` | `LocalRead` | aucun | « Vérifier l’application » (§ 14) |
| `accueil.session.details` | `LocalRead` | aucun | détails de la session (§ 14) |
| `accueil.cache.clear` | `Local` | aucun | caches vidés |
| `accueil.journal` | `LocalRead` | aucun | journal des opérations |
| `accueil.log.tail` | `LocalRead` | aucun | dernières lignes du journal technique |

---

## 3. `accueil.board`

Calcule le tableau du parc de l’OU de travail depuis la base locale (l’annuaire fictif en simulation) : aucune lecture
réseau. Le calcul est gardé tant que la base, l’OU, les règles, les relevés et la disposition ne changent pas ; le premier
calcul du jour d’une OU garde son instantané quotidien (ACC-040).

```json
{
  "revision": "0000000c",
  "computedAt": "2026-10-21T16:26:00Z",
  "scope": { "dn": "OU=Postes,DC=example,DC=local", "label": "Postes", "subtree": true },
  "scopeLabel": "OU Postes",
  "population": { "machines": 431, "enabled": 412, "disabled": 19, "unknown": 0, "criteria": "…", "storeId": "simulation:…" },
  "entries": { "fleet.machines": { … }, "probe:<id>": { … }, "query:<id>": { … } },
  "health": { … },
  "hints": [ { "group": "Relevés des postes", "text": "…", "action": { "id": "collect", "label": "Relever ce périmètre", "tip": "…" } } ],
  "summary": "…",
  "snapshot": { "id": "actuel", "kind": "current", "label": "Vue actuelle · 21/10/2026 18:26", "day": "2026-10-21", "computedAt": "…", "figures": { … } }
}
```

- `entries` : une entrée par widget de la disposition, clé = clé du widget intégré, `probe:<id>` ou `query:<id>`.
  Champs : `key`, `title`, `group`, `kind` (`value`, `distribution`, `series`, `timeline`, `health`, `list`), `value`
  (texte affiché), `number` (chiffre ou `null`), `unit`, `detail`, `tone` (`ok`, `warn`, `alert`, `info`, `off` ou `null` ;
  `off` = mesure ancienne ou couverture partielle), `centerText`, `subtitle` (couverture), `items`
  (`[{ label, value, tone, targetsKey, targets }]`), `points` (`[{ date, label, value }]`, jours manquants absents, jamais 0),
  `targets` et `targetsKey` (ensemble exact du chiffre), `action` (`collect` ou `bitlocker`, lancée seulement au clic),
  `measured`.
- `health` : `score` (`null` sous 50 % de couverture), `verdict` (Bon état ≥ 90 %, À surveiller ≥ 75 %, Dégradé, Critique
  dès un point critique, Évaluation partielle), `tone`, `detail`, `badge`, `pointsTitle`, `alerts`, `warnings`,
  `information`, `points` (`[{ id, rule, level, text, count, targetsKey }]`, du plus grave au moins grave), `masked`,
  `total`, `assessed`, `healthy`, `problems`, `unassessed`, et les clés `healthyKey`, `problemsKey`, `unknownKey`.
  Un poste dont une donnée exigée par un contrôle actif manque n’est jamais compté sain (ACC-029, ACC-052).
- Les 34 widgets intégrés (`FleetCatalog.All`) : santé (`fleet.health`, `fleet.attention`), inventaire du périmètre
  (`fleet.machines`, `fleet.enabled`, `fleet.accountunknown`, `fleet.accountstatus`, `fleet.stale`, `fleet.disabled`,
  `fleet.created`, `fleet.pwdold`, `fleet.servers`), sécurité (`fleet.laps`, `fleet.bitlocker`), versions de Windows
  (`fleet.versions`, `fleet.eos`, `fleet.win10`), répartition (`fleet.os`, `fleet.lastlogon`, `fleet.ou`), relevés des
  postes (`fleet.presence`, `fleet.wmi`, `fleet.reach`, `fleet.users`, `fleet.lastcheck`, `fleet.models`,
  `fleet.releases`, `fleet.ram`, `fleet.diskfree`, `fleet.lowdisk`, `fleet.uptime`), évolution (`fleet.trend`,
  `fleet.trend.win10`, `fleet.trend.stale`, `fleet.trend.lowdisk`).
- Fin de service : table `WindowsLifecycle.Entries` (45 lignes de Domenia 1), dépassée = critique, à 90 jours ou moins =
  à surveiller ; une version non lue d’une famille entièrement terminée est « au plus tard » dépassée.

## 4. `accueil.targets`

`{ "revision": "0000000c", "key": "fleet.disabled" }` → `{ key, label, total, truncated, rows, revision }` ; `rows` :
`[{ name, dn, guid, ou, state, system, lastLogon, presence, diskFree, uptimeDays, model, user, score, alerts, warnings }]`,
2 000 lignes au plus (`truncated`). `score` est le score du poste (ACC-029, Get-DomeniaBoardHealth) : 100 − 25 par point
critique − 10 par point à surveiller, jamais sous 0, `null` pour un poste non évalué ; `alerts` et `warnings` comptent ses
points. Les clés valent pour le calcul qui les a produites : un widget (`fleet.x`), une part (`fleet.x|<libellé>`),
un point (`point:<id>`), une règle (`rule:<id>`), des postes masqués (`masked:<id>`), les postes sans la donnée d’un contrôle
(`missing:<id>`, « Voir la collecte manquante »), une cellule de tableau croisé
(`pivot:<table>:cell:<ligne>|<colonne>`, `:row:`, `:column:`, `:all`, avec la révision de la matrice). Une révision
remplacée répond `board.replaced` : la page recalcule et l’opérateur clique de nouveau (jamais une liste d’un autre calcul).

**Transmission à Rechercher** (ACC-031). « Ouvrir l’OU dans Rechercher » n’est jamais proposé pour le domaine entier ; la page
navigue vers `#/rechercher?ou=<DN>&subtree=1|0&source=accueil&revision=<révision>&cle=<clé>`. Rechercher (autre lot) pourra
relire la liste exacte avec `accueil.targets { revision, key }` et la refuser si le calcul a été remplacé (`board.replaced`) ;
tant qu’il ne le fait pas, il s’ouvre sur l’OU et le libellé du bouton le dit.

**Objet choisi depuis l’Accueil** (« Objet sélectionné », ACC-019 ; « Consulter », ACC-018). Ouvrir un poste (liste
« Postes à surveiller », double clic dans « Postes concernés ») le garde pour la fenêtre : `sessionStorage`
`domenia.selection.v1` = `{ dn, name, kind, at }` (jamais un secret), et l’événement `domenia:object-selected` le signale aux
autres écrans. Un stockage indisponible n’empêche rien.

## 5. Disposition

`accueil.layout` → `{ items, customized, max }` ; un élément : `{ id, source: "builtin"|"probe"|"query", key, visual,
size: "S"|"M"|"L", title, paused, group }`.

`accueil.layout.save` `{ items }` (64 au plus) nettoie avant de mémoriser : widget inconnu retiré, doublon retiré,
représentation non admise pour la donnée remplacée par la première admise (`FleetCatalog.VisualsFor`), taille inconnue →
`M`, titre de 80 caractères au plus (vide = titre d’origine), identifiant attribué aux nouveaux éléments, section
recalculée. `accueil.layout.reset` `{}` rétablit la disposition livrée ; `{ "preset": "support"|"inventory"|"health" }`
met en tête les widgets de la disposition prédéfinie (ajoutés s’ils manquent).

## 6. Catalogue et sondes

`accueil.widgets.catalog` → `{ groups: [{ name, widgets: [{ key, title, group, kind, visual, visuals, size, description,
default }] }], visualNames, sizeNames, presets, probes: [{ name, probes: [{ id, name, category, mode, transform, visuals,
visual, slow, skipOnDc, origin, summary }] }], probeCount, queriesAvailable, queriesText }`. Les sondes viennent du
catalogue de Domenia 1 (intégrées et détaillées), avec leurs représentations admises (ACC-060, ACC-061).

`accueil.probe` `{ id }` → `{ id, name, origin, summary, privilegeLevel, costLevel, valid, lines: [{ section, value }],
warnings, errors }` (droits, coût, comportement, entrées, types, limites, sources, tests : ACC-063).

## 7. Actualisation de l’OU (« Tout actualiser » et son menu, dans l’en-tête)

`accueil.refresh.plan` `{ mode }` — `directory` (base locale de l’OU), `presence` (ping), `inventory` (ping puis WMI),
`all` (tout), `resume` (les étapes qu’une actualisation interrompue de la même OU n’a pas terminées, amélioration
d’ACC-001). Rien n’est contacté : le plan est figé au clic, valable cinq minutes, utilisable une seule fois.

```json
{
  "id": "<32 caractères hexadécimaux>", "mode": "all", "title": "Tout actualiser", "summary": "…",
  "scope": { "dn": "OU=Postes,DC=example,DC=local", "label": "Postes", "subtree": true }, "targets": 412,
  "stages": [ { "id": "backup", "label": "Sauvegarde vérifiée de la base locale", "detail": "…" }, { "id": "directory", … },
              { "id": "commit", … }, { "id": "presence", … }, { "id": "inventory", … } ],
  "probes": ["…"], "probeNames": ["…"], "estimateSeconds": 155, "estimateText": "Durée estimée en mode annuaire : …",
  "warnings": ["…"], "confirm": "Tout actualiser", "createdAt": "…", "expiresAt": "…",
  "online": 314, "reused": 287, "reuseDays": 30, "reuseSince": "…", "resumeOf": null, "onlineSince": null
}
```

- **Collecter seulement ce qui manque** (ACC-038, décision du 14/10/2026) : `online` compte les postes actifs en ligne au
  dernier relevé, `reused` ceux dont l’inventaire et chaque sonde du plan ont une lecture utilisable (ni erreur ni refus, pas
  dans le futur) datée depuis `reuseSince` (30 jours) : ils ne sont pas contactés (« déjà à jour, non contactés »). Les
  erreurs sont toujours relues. `accueil.refresh.run { planId, force: true }` (« Tout relire » dans la confirmation) relit
  aussi les postes à jour.
- **Reprise** (`resume`) : `resumeOf` est l’actualisation reprise ; ses étapes non terminées seulement ; si elle ne repingue
  pas, le WMI s’appuie sur le ping de l’actualisation interrompue (`onlineSince`). Une actualisation forcée reste forcée
  (rien de plus ancien que son début n’est réutilisé).
- **Sauvegarde** : en simulation l’étape `backup` dit « sans objet » dès le plan (aucune base ouverte) et finit à l’état
  `na` ; en mode annuaire, toute relecture AD est refusée (`refresh.backupUnavailable`) tant que la sauvegarde vérifiée de
  `Domenia.Store` n’existe pas.

- Refus : racine du domaine (`scope.tooWide`), actualisation en cours (`refresh.running`), widget de requête actif pour un
  relevé WMI (`refresh.queryMissing`), nouvelle collecte non admise (`refresh.refused` : mesure de widget ou lecture BitLocker
  en cours, trois échecs d’écriture locale, moins de 512 Mio libres sur le volume des données en mode annuaire ; vérifié au
  plan puis de nouveau à la confirmation), relecture AD sans sauvegarde (`refresh.backupUnavailable`).
- Sondes : celles des widgets de sonde actifs (non en pause) de la disposition, figées dans le plan (ACC-007).
- Estimation (amélioration d’ACC-001) : budgets de Domenia 1 — ping par lots de 64 (800 ms), WMI `Async.MaxThreads` (6)
  à la fois, environ 3 s par poste et 1 s par sonde ; lecture AD selon le nombre d’objets.

`accueil.refresh.run` `{ planId, force? }` exécute le plan une fois, étape par étape, et publie `accueil.refresh.run:progress` :
`{ runId, stage, state: "running"|"done"|"na"|"failed"|"skipped"|"stopped", label, detail, index, count, percent }`.
Règles : sauvegarde vérifiée avant la relecture AD (en simulation : « sans objet », état `na`) ; la collecte attend le reçu
d’enregistrement (`commit`) ; WMI seulement sur les postes qui ont répondu au ping **de ce relevé** (ACC-004 : la liste des
postes en ligne est passée à `IAccueilReader.ReadInventoryAsync`, les autres gardent leur lecture et sa date), sans nouvel
écho, et seulement ce qui manque (ACC-038) ; si la
lecture AD échoue en mode `all`, ping et WMI partent sur les postes déjà connus (`partial`) ; un changement d’OU arrête
l’actualisation entre deux étapes. Résultat : `{ id, mode, status: "success"|"partial"|"cancelled"|"error", label, scope,
startedAt, finishedAt, stages: [{ id, label, state, detail, startedAt, finishedAt }], runs, stopping, forced, resumable }` ;
`resumable` : actualisation interrompue dont une étape n’est pas terminée (« Reprendre »). Les relevés vraiment lancés sont
enregistrés (horloges, § 8, gardés dans les préférences locales) ; le journal des opérations reçoit une ligne. Un arrêt
entre deux étapes marque les suivantes `skipped` et le compte rendu `cancelled`.

`accueil.refresh.stop` → `{ stopping, label }` : l’étape en cours se termine sans lancer de nouvelle collecte ; les mesures
déjà enregistrées sont gardées. `accueil.refresh.state` → `{ running, current, last }` (reprise de l’affichage au retour sur
l’écran). Pendant un relevé, la page recalcule le tableau toutes les 15 s au plus (ACC-037).

## 8. Provenance et relevés

`accueil.provenance` → `{ scope, scopeText, directory: { status, at, sourceDn, attemptAt, partial, clockInvalid, text },
ping, console, inventory: { count, total, missing, oldest, newest, states, text }, clocks: [ { family, label, state:
"success"|"successThenFailure"|"failureOnly"|"incoherent"|"neverRecorded", success, attempt, attemptFailedAfterSuccess,
coherent, text, detail, warning } ], computedAt, computedText, observationsText, runsText, runsWarning, bitLockerAt }`.
`states` compte les mesures par état (`known`, `absent`, `notRead`, `refused`, `expired`, `incomplete`, `error`). Un relevé
d’une OU englobante en sous-arbre date la vue (`inherited`) ; une date future est signalée, jamais corrigée.

`accueil.collections` → `{ total, rows: [{ at, ou, ouDn, subtree, type, family, status, stateLabel, postes, success,
reason }] }`, 300 lignes au plus, la plus récente d’abord (ACC-022).

## 9. Analyse

`accueil.analysis.snapshots` → `{ items: [{ id, kind: "daily"|"manual"|"current", label, day, computedAt }], tables:
[{ id, title, rowTitle, columnTitle }] }` ; tables `ouWindows`, `modelRam`, `siteCoverage`, `modelBios`.

`accueil.analysis.compare` `{ before, after }` → `{ comparable, category: "Stable"|"Réel"|"Périmètre"|"Couverture"|
"Règles"|"Mixte"|"Limitée", summary, factors: [{ factor, status: "Inchangé"|"Modifié"|"Inconnu", text }], limits, rows:
[{ measure, before, after, delta }], swapped, beforeLabel, afterLabel }`. Les empreintes (population, évalués, couverture,
règles) séparent un changement réel d’un changement de périmètre ou de couverture (ACC-009).

`accueil.analysis.pivots` `{ table, filter? }` → `{ table, title, rowTitle, columnTitle, columns, rows: [{ label, counts,
keys, total, totalKey }], columnTotals, columnKeys, grandTotal, grandKey, folded, cells, total, filtered, revision }` :
chaque poste est dans une seule cellule ; chaque clé ouvre ses postes avec `accueil.targets` et `revision`.

`accueil.snapshot.take` `{ label? }` (80 caractères) → `{ id, kind: "manual", label, day, computedAt }` : instantané daté
de la vue actuelle, gardé dans les préférences locales (20 au plus ; la base locale le conservera en vague 3).

## 10. Règles de santé

`accueil.health.policy` `{ dn? }` (sans `dn` : règles du domaine) → `{ scopeDn, scopeLabel, local, policy, origins,
scopes, rules: [{ id, name, fleet, state: "on"|"disabled"|"suspended", origin, suspension }], thresholds: [{ id, name,
default, minimum, maximum }], suspensionHours: [1, 24, 168, 720], maxCustomRules: 32, queryAlertsAvailable }`.

`policy` : `{ thresholds: { staleDays, passwordDays, uptimeDays, diskFreeAlert, diskFreeWarn, memoryUsedWarn,
batteryWarn }, disabledRules: [...], customRules: [{ id, name, measure: "DiskFree"|"UptimeDays"|"MemoryUsed", operator:
"LessThan"|"GreaterThan", threshold, severity: "Warn"|"Alert", enabled }], suspensions: [{ ruleId, reason, untilUtc }] }`.

`accueil.health.save` `{ dn?, policy }` lit strictement la politique : seuils dans leurs bornes (disque critique ≤ disque à
surveiller), contrôles connus, 32 alertes au plus (une alerte sur requête est refusée tant que l’atelier n’est pas porté),
suspension `{ ruleId, reason (3 à 240 caractères), hours: 1|24|168|720 }` ou `{ ruleId, reason, untilUtc }`, et
`endNow: true` pour « Réactiver maintenant » (le motif reste listé). Pour une OU, seule la différence avec la parente est
gardée ; les suspensions échues depuis plus de 30 jours sont retirées. `accueil.health.revert` `{ dn }` supprime
l’exception d’une OU. `accueil.health.exceptions` → `{ rows: [{ scopeDn, label, changes, count }] }`.
`accueil.health.explain` → `{ summary, activeRules, disabledRules, suspendedRules, maskedMachines, population, unknown,
assessed, rows: [{ id, rule, status, machines, effect, eligible, eligibleCount, exclusive, masked, consequence,
observationState, missingData, evidence: { source, observed, value, rule, collection }, targetsKey, maskedKey, missingKey,
missing }], policies, scope, revision }`. `revision` est le calcul expliqué : la page ouvre les ensembles avec elle, si bien
qu’une vue recalculée pendant la consultation refuse l’action (`board.replaced`). `missingKey` ouvre les postes sans la
donnée du contrôle (« Voir la collecte manquante », ACC-030) : aucune collecte n’est lancée.

## 11. `accueil.bitlocker.read`

Sur geste explicite seulement : compte, poste par poste, les objets de récupération BitLocker de l’OU de travail et la date
du plus récent ; jamais une clé. Refusé à la racine du domaine (`scope.tooWide`). Résultat : `{ scopeLabel, read, withKey,
withoutKey, at, truncated, classPresent, text }` ; le tableau suivant porte la tuile `fleet.bitlocker` et le contrôle
`bitlocker.none`. Une lecture tronquée n’écrit jamais « pas de clé ».

## 12. OU de travail : retour au défaut et favorites

`accueil.scope.reset` remet l’OU de travail par défaut de la source (`session.setScope` sur l’OU racine des postes) et
renvoie `session.info`. `accueil.favorites` → `{ items: [{ id, name, dn, subtree, path, exists }], max: 12 }` ;
`accueil.favorite.save` `{ name (1 à 60), dn, subtree }` ajoute ou renomme ; `accueil.favorite.drop` `{ id }`. Une favorite
absente de l’index local des OU reste listée (`exists: false`) et ne s’applique pas. Choisir tout le domaine reste possible
par `session.setScope` (choix explicite confirmé dans la page, ACC-012) ; aucune mesure réseau n’y part.

## 13. Premiers pas, aide, dernière vue

`accueil.firstSteps` → `{ steps: [{ id: "connect"|"scope"|"firstRead"|"dashboard"|"rights", number, label, text, done,
enabled, current, actionLabel }], next, done, deferred, dismissed, helpSeen, readInterrupted, offline, completed, total,
finished }`. `rights` (« Vérifier l’application ») est facultative et hors du compte (lien à côté des quatre étapes). Une fois
les quatre étapes faites, `finished` est mémorisé et la carte disparaît pour de bon (Home.FirstStepsDone) ; l’aide la
réaffiche pour la visite. La dernière étape suit le premier calcul (ACC-016 : « Calcul en cours… », « Prête · N postes »,
« Erreur · Réessayer »). `accueil.firstSteps.dismiss` `{ dismissed }` masque ou réaffiche la carte ; `accueil.help.seen`
retire la pastille « Nouveau » du « ? » de l’Accueil.

`accueil.lastView` → `{ available, text, computedAt, machines, problems, scopeLabel }` pour la même base et la même OU ;
pendant le premier calcul, la page en montre les chiffres dans des tuiles grises « non recalculées », retirées à l’arrivée du
tableau. `accueil.lastView.save` `{ revision }` mémorise le calcul affiché (comptes et date seulement, ACC-035) quand ses
comptes changent, ou une fois par minute au plus.

## 14. Outils de session

- `accueil.selfCheck` → `{ checkedAt, ok, warnings, failures, summary, checks: [{ id, label, tone, detail }] }` : mode,
  source de l’annuaire, lecture locale, horloge, OU de travail, préférences, reçus d’écriture, lecteurs d’écran,
  exécuteurs d’écriture, catalogue des sondes. Lecture locale uniquement.
- `accueil.cache.clear` → `{ cleared: [{ label, count }], text }` : calcul du tableau, ensembles exacts, tableaux croisés,
  historique relu, disposition et règles relues ; aucune mesure perdue.
- `accueil.journal` → `{ total, rows: [{ at, label, tone }] }` (session et source, le plus récent d’abord).
- `accueil.log.tail` → `{ path: "%LOCALAPPDATA%\\Domenia\\logs\\domenia.log", available, lines: [{ at, level, text }],
  truncated, summary }` : 256 Kio et 200 lignes au plus, le plus récent d’abord ; le journal ne contient ni saisie ni secret.
- `accueil.session.details` → `{ associations, associationsText, lastCheck: { checkedAt, summary, tone } | null,
  calculations: [{ at, milliseconds }], localWriteFailures, runs, snapshots }` : ce que l’onglet « Session » ajoute à
  `session.info` (ACC-019 : liens utilisateur–poste, dernier résultat de la vérification, cinq derniers calculs, écritures
  locales en échec). La page y joint ce qu’elle affiche déjà : résultats affichés et statistiques de la liste (tableau du
  parc), objet sélectionné (ci-dessus, § 4). Lu quand la carte de la session s’affiche, puis après une vérification.

## 14 bis. Adresses de l’écran

Liens des guides, des autres écrans et des captures (une fois par visite, l’écran affiché) :

| Adresse | Effet |
|---|---|
| `#/accueil?ou=choisir` | ouvre « Choisir l’OU » |
| `#/accueil?outil=widgets\|sante\|score\|analyse\|provenance\|journal\|verifier\|aide` | ouvre l’outil (catalogue, règles de santé, comprendre le score, analyse, provenance, journal, vérification, aide) |
| `#/accueil?outil=actualiser\|base\|wmi\|ping\|reprendre` | prépare le plan de « Tout actualiser », de la base locale, de ping et WMI, du ping seul ou de la reprise, et ouvre sa confirmation : rien ne part sans le clic de confirmation |
| `#/accueil?postes=<clé>` | ouvre « Postes concernés » sur un ensemble du calcul affiché |
| `#/accueil?personnaliser=1` | mode Personnaliser du tableau du parc |
| `#/accueil?section=indicateurs\|activite\|tableau\|suivi\|session` | montre cette section seule sous l’en-tête ; « Tout afficher » rend les autres (captures d’une section en haut d’écran) |

## 15. Simulation

- Faits des postes (`SimulatedAccueilReader.FactsAsync`) dérivés du monde fictif (graine) : utilisateur en session
  (`managedBy` ou personne du même site), version de BIOS par modèle (86 % lus), état WMI repris de l’inventaire, deux
  refus d’accès WMI, deux relevés rejetés, onze relevés d’OU datés avant la référence (jamais dans le futur), `storeId`
  `simulation:<graine>:<référence>`.
- Historique : 30 instantanés quotidiens calculés avec `FleetBoardCalculator` sur les états passés du monde fictif.
- BitLocker : 8 % des postes sans clé, délai de 350 à 800 ms ; sondes : valeurs générées par sonde, délai de 400 à 1 100 ms,
  3 % de refus sur les espaces de noms de sécurité.
- Actualisation : l’annuaire fictif est relu en mémoire, les postes répondent selon des manches déterministes ; la
  sauvegarde de la base est « sans objet » (aucune base ouverte) ; aucune connexion réelle. L’inventaire relu
  (`SimulatedDirectorySource.RefreshInventoryAsync`, par `ReadInventoryAsync`) ne redate que les postes passés par le moteur :
  ceux qui ont répondu au ping de ce relevé et dont une mesure manque.
- Préférences : `preferences-simulation.json` reçoit aussi les relevés et instantanés de l’Accueil (§ 1), jamais le fichier
  du mode annuaire ; en capture et en E2E, tout reste en mémoire.
- Compte de la session : compte d’administration `EXAMPLE\adm-j.martin` (décision de David du 21/10). **À reporter à la
  fusion** : ce lot a changé dans les fichiers partagés le compte de la session simulée (`j.martin` → `adm-j.martin`, droits
  « Administration » au lieu de « Lecture », `SimulatedWorldGenerator`, `SimulationProfile`), ajouté
  `DashboardService.MeasureAsync` (deux surcharges) et le compteur `Measuring`, et
  `SimulatedDirectorySource.RefreshInventoryAsync` : les lots qui vérifient `j.martin`, `RightsLevel.Read` ou l’opérateur des
  plans d’écriture sont à relire avant la fusion.

## 16. Mode annuaire (vague 3)

Ce que `Domenia.Ad`, `Domenia.Inventory` et `Domenia.Store` devront servir à `IAccueilReader` et à `DashboardService` :

| Famille | Source et requête | Attributs ou classes | Budgets et gardes |
|---|---|---|---|
| Base locale de l’OU | LDAP, base = DN de l’OU, sous-arbre, `(objectCategory=computer)` puis utilisateurs, groupes et OU de la branche ; écriture dans la base après sauvegarde vérifiée, reçu `IndexBulk` (OU, base, session, complétude) | `objectGUID`, `distinguishedName`, `name`, `dNSHostName`, `operatingSystem`, `operatingSystemVersion`, `userAccountControl`, `lastLogonTimestamp`, `pwdLastSet`, `whenCreated`, `managedBy`, `msLAPS-PasswordExpirationTime` ou `ms-Mcs-AdmPwdExpirationTime` (jamais un mot de passe) | pages de 1 000, lecture paginée jusqu’au bout ou arrêt signalé (« base incomplète », point `index.partial`) ; OU explicite, jamais la racine ; refus si maintenance, disque presque plein ou écritures locales en attente |
| Présence (ping) | ICMP, un écho par poste actif (`dNSHostName`) | réponse, date | lots de 64, 800 ms (Get-ReachableSet de Domenia 1) ; une absence de réponse n’est jamais un arrêt |
| Inventaire WMI | CIM (DCOM/WSMan) sur les seuls postes qui ont répondu | `Win32_ComputerSystem` (Model, Manufacturer, TotalPhysicalMemory, UserName), `Win32_OperatingSystem` (Caption, Version, BuildNumber, LastBootUpTime), `Win32_LogicalDisk` `DeviceID='C:'` (Size, FreeSpace), `Win32_BIOS` (SMBIOSBIOSVersion), puis les classes des sondes figées dans le plan | `Async.MaxThreads` (6) à la fois, `OperationTimeoutSec` 12 ; sondes `skipOnDc` jamais lues sur un contrôleur ; refus distingué de l’erreur ; échec dans les 15 min d’un succès = même collecte |
| Présence BitLocker | LDAP, base = DN de l’OU, sous-arbre, `(objectClass=msFVE-RecoveryInformation)` ; présence de la classe lue dans le schéma | `distinguishedName` (le parent est l’ordinateur), `whenCreated` ; jamais `msFVE-RecoveryPassword` ni `msFVE-KeyPackage` | pages de 500, 100 000 objets au plus (troncature signalée), 180 s ; refus attribué à la ressource BitLocker |
| Relevés (horloges) | `Domenia.Store` | `CollectionRun` : famille, OU, sous-arbre, statut, début, fin, erreur, comptes, contrôleur | refus ou annulation avant toute action réseau = rien d’enregistré ; date future refusée |
| Instantanés | `Domenia.Store` | `FleetSnapshot` quotidiens et manuels de l’OU | un par jour et par OU (premier calcul) ; 90 jours affichés |

Les calculs (`FleetBoardCalculator`, `HealthRules`, `CollectionClocks`, `FleetAnalysis`, `ProbeCatalog`) restent les
mêmes : seules les sources changent. « Collecter seulement ce qui manque » (ACC-038) est une règle pure (`RefreshRules.Missing`) :
`Domenia.Inventory` lui fournira les mesures relues par tranches avant tout réseau.

## 17. Sécurité

Lecture seule par défaut ; aucune lecture réseau sans geste explicite (actualisation confirmée, lecture BitLocker) ;
jamais tout le domaine (`scope.tooWide`) ; plan figé, utilisé une fois, jamais rejoué ; aucune écriture dans l’annuaire
(préférences locales seulement) ; aucune clé BitLocker ni mot de passe LAPS lus ; aucun secret dans le journal.
