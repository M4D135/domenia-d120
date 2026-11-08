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
| Interface de lecture | `IAccueilReader` (`FactsAsync`, `StoredProbesAsync`, `HistoryAsync`, `ReadBitLockerAsync`, `CollectFrozenProbesAsync`, `ReadInventoryAsync`) |
| Règles de l’actualisation | `RefreshRules` (refus d’une nouvelle collecte, « collecter seulement ce qui manque ») |
| Simulation | `src/Domenia.Simulation/Screens/Accueil/` (`SimulatedAccueilReader`, `SimulatedProbeValues`) |
| Module du pont | `src/Domenia.Bridge/Operations/AccueilOperations.cs`, `PersonalProbeOperations.cs` ; `src/Domenia.App/AccueilJournalOperations.cs` (`accueil.log.tail`, journal technique de l’hôte ; mesure de l’espace libre du volume des données) et `AccueilHostFiles.cs` (lecture du journal, espace libre ; compilé aussi dans les tests) |
| Page | `web/js/pages/accueil.js` et `web/js/pages/accueil/*.js` ; `web/css/pages/accueil.css` ; aperçu du navigateur `web/js/mock-accueil.js` |
| Tests | `tests/Domenia.Tests/AccueilTests.cs` ; scénarios `tests/e2e/accueil/*.json` |

En mode annuaire, `AdAccueilReader`, `WmiFleetProbeReader` et le cache SQLite servent les collectes et les vues locales.
Une interface absente reste un refus `source.unavailable`. La présence du raccordement ne prouve pas une recette native réussie.

---

## 1. Conventions

- JSON : règles de `OPERATIONS.md` § 1.2 (camelCase, énumérations en camelCase, dates `yyyy-MM-ddTHH:mm:ssZ`, dates
  seules `yyyy-MM-dd`, champs nuls écrits, clés de dictionnaire gardées telles quelles).
- Arguments : objet ; tout champ inconnu est refusé (`arguments.invalid`). Les textes sont bornés et sans caractère de
  contrôle.
- **Préférences** (`LocalWrite`, jamais l’annuaire) : préfixe `accueil.`. La disposition et le catalogue personnel exigent
  un enregistrement atomique et une relecture ; un échec conserve le document précédent et refuse d’annoncer un succès.
  Les préférences de présentation secondaires signalent leur indisponibilité dans le journal. En capture et en E2E, les préférences restent en mémoire.

| Clé | Contenu |
|---|---|
| `accueil.layout` | disposition du tableau du parc (`{ v: 1, items: [...] }`) |
| `accueil.personalProbes` | catalogue de profil `Domenia.PersonalProbeCatalog/1`, versions immuables conservées (§ 6.1) |
| `accueil.firstSteps` | `{ dashboardSeen, dismissed, finished }` (`finished` : les quatre étapes faites une fois, Home.FirstStepsDone) |
| `accueil.helpSeen` | `true` une fois l’aide ouverte |
| `accueil.health.<sha>` | carnet des règles de santé du domaine (`<sha>` : SHA-256 du DN de la racine) |
| `accueil.favorites.<sha>` | OU favorites du domaine (12 au plus) |
| `accueil.lastView.<sha>` | résumé de la dernière vue par base et par OU (comptes et date, jamais un nom) ; réécrit seulement quand ses comptes changent, ou une fois par minute au plus |
| `accueil.runs.<sha>` | relevés de la session (horloges, ACC-022) : 300 au plus, relus au démarrage et réadmis par `CollectionClocks.Create` (date future ou hors du domaine écartées) ; remplacés par `Domenia.Store` en vague 3 |
| `accueil.snapshots.<sha>` | instantanés quotidiens (90 jours des quatre OU les plus récentes, environ 200 Kio) et manuels (20) de l’OU : comptes et empreintes seulement, jamais un nom (ACC-040) |

- **Erreurs propres** (en plus de `OPERATIONS.md` § 1.4) :

| Code | Message (extrait) | Quand |
|---|---|---|
| `board.replaced` | Ce chiffre vient d’un calcul remplacé… | `accueil.targets` avec une révision qui n’est plus la dernière |
| `targets.unknown` | Ensemble de postes introuvable dans ce calcul… | clé inconnue du calcul |
| `probe.unknown` | Sonde inconnue du catalogue… | `accueil.probe` |
| `probes.invalid` | Document, déclaration ou catalogue personnel invalide… | import entier refusé avant collecte |
| `probes.changed` | Catalogue/document modifié ou définition exacte absente… | aperçu périmé, disposition ou reprise sans sa définition |
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
| `accueil.board` | `LocalWrite` | aucun | tableau du parc de l’OU de travail (§ 3) ; calculé depuis la base locale, sans réseau : `LocalWrite` parce que le premier calcul du jour garde l’instantané quotidien et marque le tableau vu dans les préférences locales |
| `accueil.targets` | `LocalRead` | `{ revision, key }` | postes exacts d’un chiffre (§ 4) |
| `accueil.layout` | `LocalRead` | aucun | disposition (§ 5) |
| `accueil.layout.save` | `LocalWrite` | `{ items }` | disposition nettoyée et mémorisée |
| `accueil.layout.reset` | `LocalWrite` | `{ preset? }` | disposition livrée ou prédéfinie |
| `accueil.widgets.catalog` | `LocalRead` | aucun | widgets, représentations, tailles, sondes embarquées et personnelles (§ 6) |
| `accueil.probe` | `LocalRead` | `{ id }` | contrat de la définition exacte du profil ou du catalogue embarqué |
| `accueil.probes.personal` | `LocalRead` | aucun | catalogue personnel, jeton de choix, documents canoniques et contrats |
| `accueil.probes.preview` | `LocalRead` | `{ document, expectedChoiceToken }` | candidats, ajouts/versions existantes, empreinte du texte et avertissements |
| `accueil.probes.apply` | `LocalWrite` | `{ document, expectedChoiceToken, expectedDocumentSha256 }` | catalogue enregistré/relu et reçu local ; aucune collecte |
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
| `accueil.firstSteps` | `LocalWrite` | aucun | premiers pas (§ 13) ; `LocalWrite` parce qu’il mémorise une fois « premiers pas terminés » dans les préférences locales |
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
  "snapshot": { "id": "actuel", "kind": "current", "label": "Vue actuelle · 21/10/2026 18:26", "day": "2026-10-21", "computedAt": "…", "figures": { … } },
  "directory": { "status": "complete", "at": "2026-10-21T16:14:00Z", "sourceDn": "OU=Postes,DC=example,DC=local", "attemptAt": null, "partial": false, "clockInvalid": false, "text": "…" }
}
```

- `directory` : fraîcheur de la branche (ACC-020, `CollectionClocks.Directory`) : dernière lecture AD **complète** qui couvre
  l’OU de travail (`at`, `sourceDn` : l’OU lue, elle-même ou une ancêtre), tentative partielle plus récente (`attemptAt`,
  `partial`), date dans le futur ou profondeur inconnue (`clockInvalid`) et la phrase `text`. La puce « Annuaire lu… » de
  l’en-tête et la ligne de population s’en servent (ton `warn` si partielle, `alert` si date future) ; une lecture partielle
  ne remplace jamais la date.

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

`accueil.layout` → `{ items, customized, max, choiceToken, history, valid, reason }` ; un élément :
`{ id, source: "builtin"|"probe"|"query", key, visual, size: "S"|"M"|"L", height?: "S"|"M"|"L", hidden?: boolean, title, paused, group, queryBinding? }`.

`size` règle la largeur dans la grille responsive ; `height`, indépendant, règle la hauteur minimale. Hauteur absente
ou `null` = automatique. `hidden` masque la présentation seulement : il ne change pas `paused` et réafficher ne lance
pas de collecte. Les valeurs par défaut de ces deux champs sont omises à l’écriture pour préserver les empreintes
historiques. Une hauteur inconnue ou un masque non booléen est refusé.

`group` est le nom de la section choisi par l’utilisateur, conservé indépendamment de la catégorie du catalogue.
Une section est créée en y plaçant son premier widget ; une section sans widget disparaît. L’ordre des premières
occurrences de `group` définit l’ordre des sections, et l’ordre des éléments définit celui des widgets dans chaque
section. Renommer, déplacer ou masquer une section modifie ses éléments dans la même sauvegarde atomique.

`accueil.layout.save` `{ items, expectedChoiceToken }` (64 au plus) qualifie la disposition entière avant de mémoriser :
un widget sans représentation, une liaison illisible ou un texte hors limites refuse l’écriture sans remplacement partiel.
Les représentations admises et les largeurs sont normalisées, les titres sont limités à 80 caractères (vide = titre d’origine),
et les nouveaux éléments reçoivent un identifiant unique. Le jeton protège les changements concurrents ; cinq choix précédents
restent restaurables. Import, export et historique conservent l’ordre, les sections, les dimensions, la visibilité et les liaisons.
`accueil.layout.reset` `{}` rétablit la disposition livrée ; `{ "preset": "support"|"inventory"|"health" }`
met en tête les widgets de la disposition prédéfinie (ajoutés s’ils manquent).

## 6. Catalogue et sondes

`accueil.widgets.catalog` → `{ groups: [{ name, widgets: [{ key, title, group, kind, visual, visuals, size, description,
default }] }], visualNames, sizeNames, presets, probes: [{ name, probes: [{ id, name, category, mode, transform, visuals,
visual, slow, skipOnDc, origin, summary }] }], probeCount, queriesAvailable, queriesText }`. Les sondes viennent du
catalogue de Domenia 1 (intégrées et détaillées) et du catalogue personnel validé de ce profil, avec leurs représentations admises (ACC-060, ACC-061).

`accueil.probe` `{ id }` → `{ id, name, origin, summary, privilegeLevel, costLevel, valid, lines: [{ section, value }],
warnings, errors }` (droits, coût, comportement, entrées, types, limites, sources, tests : ACC-063).

### 6.1. Sondes personnelles déclaratives (TRV-191)

Le tiroir **Ajouter un widget → Sondes WMI** réutilise le parcours existant. Le panneau personnel propose un modèle,
l’import de JSON ou l’édition d’une version enregistrée, l’aperçu des contrats, puis une confirmation locale. L’import
n’ajoute pas de widget et ne collecte rien. Après enregistrement, la nouvelle version apparaît dans le catalogue ;
son ajout passe par la préparation et la confirmation de collecte du widget. Le coût reste celui déclaré ; l’exigence
de collecte explicite ne transforme pas artificiellement un coût `Léger` en coût lourd.

Le document d’échange est `{ "SchemaVersion": 1, "Probes": [...] }`. Il contient de 1 à 64 déclarations et au plus
256 Kio UTF-8. Chaque entrée déclare explicitement `Origin: "Personnalisée"`, `Behavior`, `Privilege`, `Cost`,
`Slow: true`, `SkipOnDc: true`, les champs/types, la source documentaire et la signification d’une valeur inconnue.
Écritures, code et méthodes WMI sont refusés. La paire espace de noms/classe doit déjà appartenir au catalogue livré,
la projection SELECT est limitée aux 4 000 caractères du transport et passe sa grammaire/son garde MSI commun.
Les métadonnées `Qualification` à la racine et `DocumentationReviewedUtc`, qui ne sont pas conservées par le modèle
personnel, sont refusées explicitement ; une qualification déclarée se place dans `ProviderQualification`.

`personal` retourne `{ choiceToken, capacity: 64, persistent, entries: [{ key, id, name, category, fingerprint, document, contract }] }`.
`document` est une représentation canonique réimportable, pas une prétendue conservation des espaces du fichier initial.
`preview` retourne `{ choiceToken, documentSha256, addedCount, existingCount, totalCount, capacity, candidates, warnings }` ;
chaque candidat porte sa clé, son alias, son nom, sa catégorie, son empreinte, `existing` et son contrat. Le SHA du texte
de l’aperçu porte sur les octets UTF-8 exacts. `apply` vérifie ce SHA et le jeton de catalogue dans l’écriture atomique,
puis retourne `{ catalog, addedCount, receipt: { readBack, persistent, text } }`. Un refus garde le texte édité dans l’UI.
Une entrée invalide refuse le document entier. Un profil illisible reste intact et apparaît en échec dans l’auto-vérification.

La clé d’exécution est `custom.` suivi de 64 chiffres hexadécimaux minuscules : **71 caractères**. Elle est calculée
depuis `Domenia.CustomProbe/1\n` et la déclaration canonique complète. Modifier projection ou métadonnées crée une
nouvelle clé ; l’alias `id` ne réattribue jamais des valeurs ou widgets existants. Le catalogue conserve toutes les
versions antérieures (64 au plus, 256 Kio au total) ; aucun import ne supprime une définition. Ces empreintes établissent
la cohérence du contenu et ne sont pas des signatures d’éditeur.

Le plan transmet `FrozenProbe` jusqu’au lecteur AD/CIM ou simulé. Les valeurs `First`, `All`, `Count` et les transformations
du parc sont conservées. La cible et la génération sont qualifiées avant/après lecture ; les budgets, exclusions MSI,
annulation et attente de la fin physique sont ceux des lecteurs existants. Les contrôleurs AD sont exclus avant admission ;
une sonde personnelle exige aussi un `DomainRole` CIM connu de 0 à 3, dans la même lecture d’identité, avant sa projection.
Une exclusion ne crée ni mesure ni compteur « déjà à jour ». Les widgets et reprises refusent une définition absente ou
altérée ; aucune recherche par alias ni définition issue du cache n’est exécutée.

SQLite conserve les observations sous la clé immuable et le GUID du poste. Les checkpoints conservent cette même clé ;
la reprise résout sa définition exacte dans le profil avant tout contact. Un ancien widget dont la définition manque reste
visible pour diagnostic. L’import ou la restauration d’une disposition portant une telle clé est refusé jusqu’à import de
la définition exacte. La configuration de diffusion générale ne sélectionne actuellement ni `accueil.layout` ni ce catalogue :
les documents personnels s’échangent explicitement depuis ce tiroir. Poste et l’Atelier partagent ce même catalogue de
profil ; les recettes personnelles de l’Atelier conservent leurs déclarations immuables en format Query/4
([contrat Requêtes](requetes.md#21-sondes-personnelles-du-profil-et-recettes-4)). La CLI reste locale en lecture seule :
elle exporte les observations et déclarations conservées, sans collecte ni import implicite.

Tests du raccordement : `PersonalProbeTests`, `PersonalProbeNativeTests` et `tests/web/personal-probes.test.mjs`.
**Écrits, non exécutés à la reprise du 25/10/2026 ; aucune recette UI/native des deux VM déduite de ces fichiers.**

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
`{ runId, stage, state: "running"|"done"|"na"|"failed"|"partial"|"skipped"|"stopped", label, detail, index, count, percent }`.
`failed` (« Échec ») est réservé à une étape qui n’a pas pu s’exécuter (refus, erreur, reçu absent) ; `partial`
(« Incomplète ») désigne une étape de collecte exécutée dont des postes restent à lire (cause transitoire du ping, ou lecture
WMI incomplète ou refusée) : le compte rendu est alors `partial` et « Reprendre » ne relance que ces postes. Le relevé de
présence suit le classement commun de [PRESENCE-DIAGNOSTICS.md](../PRESENCE-DIAGNOSTICS.md) : son détail compte les postes
en ligne, sans réponse, les réponses définitives sur le nom (« 1 nom absent du DNS », « 1 nom de poste invalide ») et les
postes non vérifiés avec leur cause (« 2 non vérifiés (DNS indisponible, délai DNS dépassé) ») ; une réponse définitive ne
rend l’étape ni incomplète ni en échec et n’est jamais redemandée par « Reprendre ». Les cartes d’étape d’un succès se
replient : le libellé d’un compte rendu `success` ou `partial` reprend donc les réponses définitives et, s’il en reste, les
postes à mesurer avec leur cause (« Actualisation partielle : OU Paris · 1 nom absent du DNS · 1 poste non vérifié (délai DNS
dépassé) »). Garde-fou : quand aucun nom du périmètre n’est résolu (aucun poste en ligne ni sans réponse, aucun poste à
reprendre) et qu’au moins deux noms sont absents ou sans adresse dans le DNS (un nom de poste invalide ne compte pas), le
détail de l’étape et le libellé ajoutent « aucun nom résolu : vérifiez le DNS de ce poste », ce poste étant celui de
l’opérateur. L’étape reste terminée, le compte rendu `success` et sans reprise ; seule la ligne du journal des opérations
passe en avertissement. Une nouvelle actualisation pingue de nouveau tous les postes (seul « Reprendre » saute ceux déjà
réglés) : corriger le DNS de ce poste puis relancer « Tout actualiser » est le remède.
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
`states` compte les mesures par état (`known`, `absent`, `notRead`, `refused`, `expired`, `incomplete`, `error`) ; pour le
ping, une réponse définitive sur le nom a sa propre clé au lieu de `error` (`dnsAbsent`, `dnsNoAddress`, `invalidName`,
[PRESENCE-DIAGNOSTICS.md](../PRESENCE-DIAGNOSTICS.md)). Un relevé
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
l’exception d’une OU. `accueil.health.exceptions` → `{ rows: [{ scopeDn, label, changes, count, missing }] }` ; `missing`
vaut `true` quand l’OU n’est plus connue de l’index local des OU (supprimée, déplacée ou renommée : « OU introuvable »,
jamais ouverte comme si elle existait ; vérifié localement, jamais par le réseau).
`accueil.health.explain` → `{ summary, activeRules, disabledRules, suspendedRules, maskedMachines, population, unknown,
assessed, rows: [{ id, rule, status, machines, effect, eligible, eligibleCount, exclusive, masked, consequence,
observationState, missingData, evidence: { source, observed, value, rule, collection }, targetsKey, maskedKey, missingKey,
missing }], policies, scope, revision }`. `revision` est le calcul expliqué : la page ouvre les ensembles avec elle, si bien
qu’une vue recalculée pendant la consultation refuse l’action (`board.replaced`). `missingKey` ouvre les postes sans la
donnée du contrôle (« Voir la collecte manquante », ACC-030) : aucune collecte n’est lancée.

**ACC-027 — mémoire utilisée.** Le pourcentage est `(visible − libre) / visible × 100`, avec
`TotalVisibleMemorySize` et `FreePhysicalMemory` du même relevé `Win32_OperatingSystem`.
Ces deux champs sont exprimés en kilooctets selon la
[documentation Microsoft](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem).
La RAM installée n’entre pas dans le calcul. L’inventaire léger ajoute les deux champs à sa requête OS
existante, sans appel réseau supplémentaire. Le cache garde la paire et sa date ensemble ; une tentative
refusée ou incomplète ne l’efface pas et ne la rajeunit pas. L’inventaire complet peut aussi alimenter
la mesure, datée prudemment au début du relevé, seulement si sa source système est qualifiée.
Un total nul, une valeur absente/incohérente, une date trop ancienne ou future restent inconnus et
sortent du dénominateur des postes sains. Le contrôle applique strictement le seuil inférieur ou supérieur,
compte les postes éligibles et propose les listes exactes des alertes et des mesures manquantes.
L’explication rappelle qu’il s’agit d’une mesure instantanée, pas d’un usage moyen. Aucune lecture réseau
n’est déclenchée par le calcul du score ou l’ouverture de son explication.

## 11. `accueil.bitlocker.read`

Sur geste explicite seulement : compte, poste par poste, les objets de récupération BitLocker de l’OU de travail et la date
du plus récent ; jamais une clé. Refusé à la racine du domaine (`scope.tooWide`). Résultat : `{ scopeLabel, read, withKey,
withoutKey, at, truncated, classPresent, text }` ; le tableau suivant porte la tuile `fleet.bitlocker` et le contrôle
`bitlocker.none`. Une lecture tronquée n’écrit jamais « pas de clé ». Une seule lecture à la fois : une seconde demande
pendant la première (double clic, deux pages) est refusée (`bitlocker.running`, « Une lecture de la présence BitLocker est
déjà en cours : attendez sa fin. Rien n’a été relancé. ») ; la page désactive le bouton pendant la lecture.

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


## Reprise du mode annuaire — 23 octobre 2026

`AdAccueilReader` sert désormais les faits locaux, les instantanés quotidiens Domenia 1, les sondes du catalogue,
la lecture d’inventaire ciblée et la présence BitLocker. `IPreparedDirectoryCache` fournit la sauvegarde vérifiée
avant la lecture des objets AD : une base sans cette capacité reste refusée. Le reçu local précède la publication.
Les mesures sont conservées dans la projection additive v2 de SQLite, sans modifier les anciennes observations
Domenia 1 ; leur import et leur projection historique complète restent à terminer. Les instantanés sans couverture
historique gardent un score inconnu. Les comptes de lecture refusés ou incomplets ne deviennent pas des succès.

Les sondes WMI partagent un budget de 60 secondes par poste (6 postes en parallèle) ; l’inventaire léger partage son
budget entre système, ordinateur, disque système et BIOS. Aucun nouveau ping dans l’étape d’inventaire du plan.
Une interruption conserve les mesures des postes déjà terminés. La présence BitLocker lit uniquement le DN et la date
de création des objets de récupération, avec une borne de 100 000 objets et 180 secondes. La profondeur directe est
respectée en lisant les enfants des seuls ordinateurs directement rattachés à l’OU.

État de validation : code et tests compilés dans la VM ; exécution fonctionnelle réservée à la recette finale.

### Reprise L21 — plan, mémoire et ensemble affiché

Le plan d’inventaire fige les sondes et révisions de requêtes actives des tableaux
Parc et Poste. Une pause n’ajoute aucune sonde. Une règle mémoire active fige
également les OU concernées et leurs exceptions : un inventaire récent sans le
couple mémoire visible/libre sera relu. Ce couple volatile possède sa propre
fraîcheur ; ni les disques récents ni un refus WMI ultérieur ne le rajeunissent.
La reprise durable conserve ces dépendances et ne coche pas un relevé mémoire
manquant comme terminé. Les anciens plans sans dépendance mémoire ne sont pas
élargis rétroactivement.

« Ouvrir dans Rechercher » transmet la révision du calcul et la clé de son
ensemble. Le moteur résout les GUID complets puis lit leurs lignes locales,
indépendamment des 2 000 lignes du tiroir ou des pages de recherche ordinaires.
La limite explicite est de 100 000 cibles. Une ligne disparue est comptée et
signalée ; aucun parcours d’OU de remplacement. Un calcul, compte, génération
connexion, périmètre ou identifiant de base modifié invalide cette ouverture.
La couverture automatisée inclut le vrai calcul et service Rechercher sur
100 000 postes, ainsi que les changements de contexte pendant la lecture locale ;
leur résultat Windows est consigné dans le rapport de lot, pas présumé ici.

Pour TRV-313, la source D1 vérifiée est `Domenia.settings.json`/`ADCC.settings.json` :
`Domenia-Widgets.UI.ps1:Get-DomeniaBoardLayout` et `Get-DomeniaWidgetList` appellent
`Get-DomeniaSetting`, chargé par `Domenia-Core.ps1:Load-DomeniaSettings` via
`Read-DomeniaPreference`. Le schéma 11 D1 ne contient aucune table de dispositions
ou `settings`. Le constat SQLite de l’audit du 31/10 était donc une hypothèse de
format erronée, conservée dans l’archive d’audit. La reprise couvre maintenant
également `app/data/ADCC.settings.json` en mode UserLocal et
`LOCALAPPDATA/ADCC.settings.json`, dans l’ordre D1 après les préférences Domenia,
avec leurs `.bak`. L’hôte passe explicitement cet emplacement : la bibliothèque
ne lit pas le profil réel lors des tests. Une liste vide arrête la recherche,
le choix D2 existant reste prioritaire et les sources sont relues/verrouillées
avant l’écriture atomique de la disposition et de sa provenance.
