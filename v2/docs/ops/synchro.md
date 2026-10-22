# Domenia 2 — écran « Synchronisation et base autonome » (`synchro`)

Contrat des opérations de l’écran `#/synchro` : la base locale autonome de Domenia (copie de l’annuaire consultable sans
réseau), ses mises à jour par lecture de l’annuaire, ses contrôles (recensement, objets manquants, disparitions), ses
relevés datés et le relevé du parc (fonctions SYN-001 à SYN-030 de Domenia 1). Les règles communes du pont (enveloppe,
JSON, classes, admission, erreurs) sont celles d’[`OPERATIONS.md`](../OPERATIONS.md) § 1 ; le circuit des écritures est
celui de [`WRITES.md`](../WRITES.md). Mis en place le 22 octobre 2026 (vague 2), compilé dans la VM (0 avertissement),
tests écrits et non exécutés (décision de David du 21/10 : à la toute fin).

## 1. Principes

| Règle de Domenia 1 | Dans Domenia 2 |
|---|---|
| Lecture seule par défaut, aucune lecture réseau sans geste | Les lectures locales (`synchro.overview`, `synchro.index.search`, `synchro.controls`, `synchro.park.state`, comparaisons) ne touchent jamais le réseau. Chaque lecture de l’annuaire part d’un geste : estimation confirmée (`synchro.read.*`), confirmation dans la page (`synchro.absences.check`, `synchro.gaps.read`, `synchro.park.shared.read`). |
| Jamais tout le domaine sans garde | La mise à jour par OU refuse la racine (`synchro.scopeRoot`) ; les changements du domaine ont leur propre geste, estimé, avec la raison d’une relecture complète et un bouton de confirmation dédié (« Relire tout le domaine »). Une lecture de vérification lit 200 identités au plus par geste. |
| Toute opération longue passe par estimation et confirmation | `synchro.read.estimate` (rien n’est lu) : objets attendus, déjà connus, durée estimée, budget, quota, sauvegarde, avertissements ; l’estimation vaut 15 min et ne sert qu’une fois. |
| La base n’est modifiée qu’avec une sauvegarde vérifiée et un reçu de stockage | Une lecture garde son résultat (« lot ») en mémoire, empreinte SHA-256 comprise ; **rien n’est écrit sans son plan** (`synchro.store.plan` puis `write.execute`) : aperçu exact (ajouts, mises à jour, non revus, repère), préconditions relues (lot intact, base inchangée depuis le plan), reçu avant l’écriture, relecture de la base (reçu de stockage, nombre et empreinte). Jamais rejoué. |
| Une absence n’est jamais une suppression | Les objets d’un périmètre qu’une lecture **complète** ne revoit pas quittent la copie et sont notés « non revus » ; seule une entrée `isDeleted` lue par GUID prouve une suppression (`SyncAbsences.Resolve`). Une lecture partielle ou différentielle ne déduit aucune absence. |
| Le repère n’avance qu’avec les données qu’il décrit | `SyncCoverageRules.CheckCheckpoint` (même contrôleur, même instance, USN validé, base intacte, date non future) ; `SyncReconcile.Incremental` (le repère avance seulement avec une réponse complète d’une instance connue) ; une lecture d’OU a sa propre date de couverture. |
| Aucun secret | Seules des dates d’expiration LAPS circulent ; un relevé ne contient ni mot de passe, ni droit, ni appartenance. Le journal technique reçoit des codes et des nombres, jamais un DN ni un nom. |

## 2. Récapitulatif des opérations

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `synchro.overview` | `LocalRead` | `{ dn? }` (OU du périmètre ; défaut : OU de travail) | `SyncOverview` |
| `synchro.index.search` | `LocalRead` | `{ text, dn?, sort?, descending?, offset?, limit? }` | `IndexSearchPage` |
| `synchro.index.export` | `LocalWrite` | `{ text, dn?, sort?, descending? }` | `SyncExport` |
| `synchro.controls` | `LocalRead` | `{ dn? }` | `SyncControls` |
| `synchro.read.estimate` | `LocalRead` | `{ target: "ou"\|"domain", dn?, maxObjects? (0..10 000 000), budgetSeconds? (30..7 200), rebuild? (true seulement avec "domain") }` | `SyncEstimate` |
| `synchro.read.run` | `NetworkRead` (servie en simulation) | `{ estimateId }` | `SyncReadResult` ; événements `synchro.read.run:progress` (`SyncProgress`) |
| `synchro.read.stop` | `Local` | `{ runId }` | `SyncStop` |
| `synchro.read.discard` | `Local` | `{ batchId }` | `SyncDiscard` (`discarded`, `message`) : le lot (lecture, vérification, objets manquants, partage) n’est plus proposé à l’enregistrement ; rien n’est écrit |
| `synchro.absences.check` | `NetworkRead` (servie) | aucun | `AbsenceCheckResult` ; événements `synchro.absences.check:progress` |
| `synchro.gaps.read` | `NetworkRead` (servie) | aucun | `GapReadResult` ; événements `synchro.gaps.read:progress` |
| `synchro.snapshot.compare` | `LocalRead` | `{ before, after }` | `SnapshotComparison` |
| `synchro.snapshot.export` | `LocalWrite` | `{ before, after }` | `SyncExport` |
| `synchro.park.state` | `LocalRead` | aucun | `ParkState` |
| `synchro.park.shared.read` | `NetworkRead` (servie) | aucun | `ParkSharedRead` |
| `synchro.store.plan` | `LocalRead` | `{ batchId }` | `{ plan, token }` (§ 12.1 d’OPERATIONS.md) |
| `synchro.snapshot.plan` | `LocalRead` | `{ label? (120 caractères), dn? }` | `{ plan, token }` |
| `synchro.snapshot.delete.plan` | `LocalRead` | `{ id }` | `{ plan, token }` |
| `synchro.park.reset.plan` | `LocalRead` | aucun | `{ plan, token }` |

Identifiants (`estimateId`, `runId`, `batchId`, `before`, `after`, `id`) : 32 caractères hexadécimaux minuscules, sinon
`arguments.invalid` (« « batchId » doit être un identifiant de 32 caractères hexadécimaux. »). `sort` ∈ `relevance`,
`type`, `name`, `login`, `upn`, `state`, `description`, `score`, `reason`, `lastLogon`, `whenChanged` (expressions figées,
Domenia 1 point 39). `text` : 100 caractères au plus ; vide = tout le périmètre ; un seul caractère = aucune ligne et le
message « Saisissez au moins deux caractères… ». `limit` : 1 à 500 (200 par défaut) ; `offset` : 0 à 1 000 000 (au-delà du
total, retour à la première page). Le DN est vérifié dans l’index local des OU (`IOrganizationalUnitIndex`), jamais par le
réseau : OU absente → `ou.unknown`.

Les résultats gardés par le moteur (estimations, lots de lecture, préparations de relevé) valent 15 minutes. Une nouvelle
lecture de l’annuaire remplace un lot de lecture non enregistré (l’estimation le dit) ; un plan préparé sur le lot remplacé
est alors refusé à l’exécution (`write.stale`).

## 3. Formes des résultats

Les noms sont exactement ceux des records de `Domenia.Core/Screens/Sync/SyncModels.cs` en camelCase ; les champs nuls
sont écrits ; dates UTC à la seconde ; énumérations en camelCase.

- **`SyncOverview`** : `scope` (`dn`, `label`, `path`, `subtree`, `isDomain`, `source` ∈ `working|chosen|domain`),
  `storeLabel`, `simulated`, `generation` (avance à chaque enregistrement), `objects`, `tiles` (4 : `accounts`,
  `computers`, `links`, `updated` ; `number` nul quand inconnu, jamais 0 ; base illisible → « — »), `coverage`
  (`status` ∈ `complete|partial|unknownDepth|missing`, `at`, `sourceDn`, `sourceLabel`, `depth`, `attemptAt`, `partial`,
  `clockInvalid`, `text`), `freshness` (lignes de Domenia 1 LblIndexFreshness), `census` (`state` ∈
  `recent|due|partial|absent|clock|gap`, `due`, `ageDays`, `maxAgeDays`, `gapCount`, `text`, `tone`), `checkpoint`
  (`controller`, `invocationId`, `usn`, `at`, `count`, `scopeDn`) ou `null`, `scopes` (lignes de couverture : `key`,
  `label`, `dn`, `path`, `depth`, `at`, `attempt`, `partial`, `items`, `controller`, `state` ∈
  `complete|partial|stale|clock`, `stateLabel`, `tone`, `detail`), `notices` (avis de démarrage : âge de la base,
  première construction, passe incomplète), `partial` (texte Index.Partial ou `null`), `limits` (`maxObjects`,
  `budgetMs`, `budgetText`, `timeoutSeconds`, `fullRebuildDays`, `startupDeltaMaxAgeMinutes`, `pageSize`, `maxPageSize`,
  `checkLimit`, `snapshotLimit`, `snapshotMaxObjects`), `readiness` (`ready`, `reason`), `running` (lecture en cours :
  `runId`, `target`, `scopeLabel`, `phase`, `phaseLabel`, `startedAt`, `stopping`) ou `null`, `pending` (lot de lecture en
  attente : `batchId`, `kind`, `label`, `count`, `readAt`, `expiresAt`) ou `null`, `receipts` (6 derniers reçus de
  stockage : `batchId`, `kind`, `label`, `at`, `count`, `sha256`, `verified`, `text`), `backup` (`lastAt`, `due`, `text`),
  `park` (`ParkCoverage`), `details`, `lead` (phrase du héros : base et périmètre ; l’âge du repère n’est dit que par son
  avis), `now` (heure du moteur : **seule source** des âges affichés par la page), `counts` (`objects`, `scopes`,
  `absences`, `absencesPending`, `gaps`, `snapshots`, `park` : compteurs des onglets), `storage` (`spaceState` ∈
  `unknown|ok|low|suspend|critical`, `freeBytes`, `spaceText`, `maintenance`, `writerSuspended`, `refusal` : garde des
  nouvelles collectes, Domenia 1 Get-DomeniaStorageCollectionRefusal), `lapsSchema` ∈ `present|absent|unknown`. Chaque
  tuile porte un pied de même nature : `parts` (deux parts `key`, `label`, `count`, `tone` : comptes activés et désactivés,
  postes actifs et désactivés, postes avec et sans utilisateur) ou `gauge` (0 à 1, fraîcheur du périmètre rapportée au seuil
  de recensement) et `gaugeText`. `census.gapText` donne les identités recensées absentes à part du conseil (`text`).
  `limits.source` dit d’où viennent les limites (« Réglages par défaut » ou les clés lues dans `Domenia.config.json`).
- **`IndexSearchPage`** : `term`, `browse`, `scope`, `sort`, `descending`, `sortLabel`, `offset`, `limit`, `page`,
  `pages`, `total`, `hasMore`, `busy` (base tenue par un enregistrement : jamais un résultat vide, la page réessaie une
  fois), `generation`, `rows` (`IndexHit` : `guid`, `type` ∈ `user|computer`, `typeLabel`, `name`, `login`, `upn`,
  `displayName`, `description`, `extra`, `enabled`, `stateLabel`, `dn`, `location`, `association`, `score` 100/90/70/0,
  `reason`, `whenChanged`, `lastLogon`, `lapsExpiration`, `observedAt`, `lapsState` ∈
  `windows|legacy|none|noSchema|unknown` (nul pour un compte) et `lapsText` : la fiche locale distingue « absent du schéma du
  domaine » de « non visible avec ce compte »), `message`.
- **`SyncControls`** : `scope`, `census`, `gaps` (`total`, `shown`, `canRead`, `summary`, `rows` : `guid`, `dn`, `name`,
  `location`, `seenAt`), `absences` (`total`, `counts` par état, `pending`, `shown`, `canCheck`, `summary`, `rows` :
  `guid`, `status` ∈ `notSeen|visible|moved|deleted|notFound|invisible|unconfirmed`, `label`, `tone`, `name`, `type`,
  `typeLabel`, `lastDn`, `foundDn`, `location`, `noticedAt`, `checkedAt`, `detail`, `scopeDn`, `server`, `inScope` : vu
  pour la dernière fois, ou retrouvé, dans le périmètre de l’écran), `inScope` (leur nombre), `snapshots`
  (`count`, `max` 50, `maxObjects` 300 000, `text`, `notice`, `rows` : `id`, `label`, `domainDn`, `scopeDn`, `subtree`,
  `scopeText`, `capturedAt`, `objectCount`, `coverageState` ∈ `complete|partial|unknown|missing`, `coverageAt`,
  `coverageText`, `rowsSha256`, `display`), `generation`, `now`.
- **`SyncEstimate`** : `id`, `target`, `scope`, `mode` ∈ `ou|incremental|full`, `modeLabel`, `checkpointReason` (raison
  d’une relecture complète), `expectedObjects`, `knownObjects`, `estimatedMs`, `estimateText`, `maxObjects`, `budgetMs`,
  `timeoutSeconds`, `backup`, `warnings`, `confirmTitle`, `confirmLabel`, `confirmText`, `ready`, `refusal`, `expiresAt`,
  `rebuild` (reconstruction explicite demandée), `canRebuild` (cible domaine). Sans argument, quota et budget viennent de
  `Domenia.config.json` (§ 9.5).
- **`SyncProgress`** (événement) : `runId`, `phase` ∈ `backup|reading|census|fingerprint|validation|done`, `phaseLabel`,
  `count`, `total` (nul tant qu’inconnu), `rate` (objets/s), `elapsedMs`, `percent`, `text`.
- **`SyncReadResult`** : `runId`, `batchId`, `target`, `scope`, `mode`, `modeLabel`, `complete`, `cut` (`reason` ∈
  `volume|temps|serveur|arret|erreur|vide`, `limit`, `text`) ou `null`, `controller`, `invocationId`, `highestUsn`, `readAt`,
  `durationMs`, `read`, `users`, `computers`, `reconcile` (`added`, `updated`, `moved`, `renamed`, `changed`,
  `unchanged`, `unseen`, `conflicts`, `totalAfter`), `samples` (exemples par catégorie : `category`, `name`, `type`,
  `detail`), `lapsSchema` ∈ `present|absent|unknown` (lecture du schéma, jamais déduite des lignes), `lapsText`,
  `checkpointAdvances`, `checkpointText`, `censusGaps`, `sha256`, `rowCount`, `summary`, `notes`, `storable`, `expiresAt`,
  `rebuild`.
- **`AbsenceCheckResult`** : `batchId`, `checked`, `counts`, `deletedProbe` ∈ `read|empty|refused|unavailable|notRequested`,
  `deletedProbeText`, `server`, `observedAt`, `rows` (`guid`, `name`, `status`, `label`, `tone`, `foundDn`, `location`,
  `proof`, `text`), `summary`, `storable`, `expiresAt`. **`GapReadResult`** : `batchId`, `asked`, `added`, `gone`, `unread`,
  `rows` (`guid`, `name`, `status` ∈ `visible|notFound|unconfirmed`, `label`, `tone`, `foundDn`, `location`, `text`),
  `summary`, `storable`, `expiresAt`.
- **`SnapshotComparison`** : `before`, `after` (`SnapshotRow`), `comparable`, `reasons`, `warnings`, `counts` (`added`,
  `disappeared`, `common`, `differing`, `unchanged`, `moved`, `renamed`, `changed`, `distinct` = communs + ajouts +
  disparitions), `limit` (500), `truncated`, `rows` (`nature` ∈ `added|disappeared|moved|renamed|changed`, `natureLabel`,
  `name`, `guid`, `detail`, `before` et `after` lisibles : emplacement pour un ajout, une disparition ou un déplacement, nom
  pour un renommage, valeur pour un champ modifié ; `beforeDn`, `afterDn`), `summary`, `notice`, `headline` (objets avant,
  après, distincts), `overlap` (objets communs qui diffèrent, par nature ; un objet déplacé et modifié compte dans les deux,
  ce que la phrase dit).
- **`ParkState`** : `coverage` (`machines` −1 tant qu’inconnu, `surveyed`, `withSession`, `dormants`, `percent`,
  `latestAt`, `text`), `rows` (`key`, `computer`, `lastProbe`, `status` ∈ `session|empty|unreachable|refused|error`,
  `statusLabel`, `tone`, `user`, `attempts`, `probedBy`), `shared` (`configured`, `path`, `lastSyncAt`, `text`, `canSync`),
  `generation`, `deferred` (résultats de poste arrivés pendant la relecture du relevé, appliqués ensuite sur les compteurs
  enregistrés), `deferredText`, `now`. **`ParkSharedRead`** : `batchId` (vide quand rien n’est enregistrable), `path`,
  `received`, `added`, `updated`, `kept`, `total`, `locked`, `lockAttempts`, `rows` (`computer`, `local`, `shared`, `winner`
  ∈ `local|shared`, `detail`), `text`, `storable`, `expiresAt`, `outcome` ∈ `merged|lockBusy|unreachable`, `reachable`,
  `queued` (demande arrivée pendant une autre synchronisation, faite à la suite), `retryAt` (nouvel essai après un verrou
  non obtenu).
- **`SyncExport`** : `written`, `path`, `fileName` (`Domenia-base-locale-AAAAMMJJ-HHmmss.csv`,
  `Domenia-comparaison-releves-…csv`), `rows`, `sha256`, `text`.

## 4. Erreurs propres

| Code | Cause |
|---|---|
| `synchro.scopeRoot` | Mise à jour par OU demandée sur la racine du domaine. |
| `synchro.estimateUnknown` | Estimation inconnue, déjà utilisée ou expirée (15 min). |
| `synchro.busy` | Une lecture de l’annuaire (ou une vérification) est déjà en cours. |
| `synchro.notReady` | Enregistrement en cours, maintenance de la base, rédacteur suspendu ou disque presque plein : nouvelle passe refusée (Domenia 1 Test-DomeniaIndexWriteReady). |
| `synchro.batchUnknown` | Lot inconnu, déjà enregistré, remplacé ou expiré. |
| `synchro.nothingToCheck`, `synchro.nothingToRead` | Rien à vérifier, aucun objet manquant à lire. |
| `synchro.snapshotUnknown`, `synchro.snapshotLimit`, `synchro.snapshotTooLarge` | Relevé introuvable ; 50 relevés par domaine ; plus de 300 000 objets. |
| `synchro.parkEmpty` | Aucun relevé du parc à oublier. |
| `synchro.sharedNotConfigured` | Aucun relevé partagé configuré (ParkSweep.SharedPath). |
| `synchro.exportTooLarge`, `synchro.exportFailed`, `synchro.exportRefused` | Export de plus de 16 Mo ; disque, droits ou verrou ; dossier remplacé par un lien. |
| `synchro.noDomain`, `synchro.outsideDomain` | Relevé sans domaine connecté ou hors du domaine. |

## 5. Écritures de la base locale (`synchro.store`)

Un seul type d’écriture, **`synchro.store`** (`SyncStoreChange.Kind`), un seul exécuteur par source
(`ISyncStoreExecutor` : `SimulatedSyncStoreExecutor` aujourd’hui, base SQLite de `Domenia.Store` en vague 3). Aucun plan
n’écrit Active Directory : la confirmation est simple (changement local, tracé, relu). La cible est un magasin de la base,
d’identité fixe, pour qu’un reçu incertain ne bloque que son magasin :

| Magasin | `target.kindLabel` | GUID fixe |
|---|---|---|
| Index (lectures, vérifications, objets manquants) | Base locale | `5e0c1a7b-2f4d-4c8e-9a61-3b7d2e9f4a10` |
| Relevés datés | Relevés de l’annuaire | `8a3f6d21-7c4b-4e19-b0d2-6f1e9c3a5b77` |
| Relevé du parc | Relevé du parc | `c4e9b2a0-1d3f-4a6c-8e57-2b9f0d6a1c38` |

Le **premier changement** nomme toujours l’opération et ce que l’opérateur a vu, en valeur brute
`« type:id|sha256|nombre »` : `batch` (lots `index`, `absences`, `gaps`, `park`), `snapshot.capture`, `snapshot.delete`,
`park.reset`. Les suivants décrivent les effets : `index.added` (`added=N`), `index.updated` (`updated=N`, dont
déplacés, renommés, valeurs modifiées), `index.unseen` (`unseen=N`), `index.kept` (observations locales plus récentes
conservées), `coverage` (date de couverture de l’OU, ou tentative incomplète notée), `checkpoint` (`usn=…` avant et
après), `census` (`gaps=…`), `absence.results`, `snapshot.count`, `park.local`, `park.shared`.

| Opération | Préconditions relues juste avant l’écriture (`write.stale` sinon) | Écriture | Relecture (`VerifyAsync`) |
|---|---|---|---|
| Lot `index` | lot présent et non expiré, même nombre de lignes et même empreinte ; aperçu recalculé identique à celui du plan : mêmes nombres **et même empreinte d’aperçu** (GUID et catégorie de chaque objet, `SyncReconcile.PreviewFingerprint`, portée par le premier changement du plan), sinon « La base locale a changé depuis le plan » ; recensement vide d’une passe complète du domaine refusé hors reconstruction explicite (`SyncReconcile.StorageRefusal`) | sauvegarde vérifiée si due ; réconciliation en une transaction : lignes écrites sous leur GUID, observation locale plus récente conservée, non revus retirés et notés « non revus », couverture (`ou:<dn>` ou `attempt:…`), repère du domaine (lecture complète du domaine), identités du recensement, marqueur de passe incomplète (posé ou effacé quand une lecture complète couvre la branche) ; reçu de stockage | reçu de stockage relu (lot, nombre, empreinte) → `verified` ; lot toujours en mémoire → `mismatch` |
| Lot `absences` | chaque objet est toujours « non revu » ou « vérification impossible » | statuts, emplacement trouvé, détail, date ; objets retrouvés remis dans la base sous le même GUID | reçu de stockage relu |
| Lot `gaps` | chaque identité manque toujours | objets lus ajoutés ; identités retrouvées ou disparues retirées de la liste | reçu de stockage relu |
| Lot `park` | relevé local et fichier partagé inchangés (empreintes) | fusion (la ligne la plus récente gagne) écrite dans la base et dans le fichier partagé sous verrou | reçu de stockage relu |
| `snapshot.capture` | préparation non expirée, moins de 50 relevés, lignes du périmètre identiques (empreinte) | relevé daté : lignes (identité, emplacement, quelques attributs), empreinte SHA-256, preuve de couverture | relevé relu (nombre, empreinte) |
| `snapshot.delete` | relevé présent, même empreinte | suppression | relevé absent de la base relue |
| `park.reset` | relevé du parc inchangé (empreinte) | sauvegarde vérifiée si due, puis état de balayage effacé (associations, observations, historique conservés) | relevé vide |

Pendant l’écriture, la base est tenue (compteur d’écritures en cours : deux écritures qui se chevauchent ne la libèrent jamais trop tôt) : une recherche concurrente attend 50 ms puis répond `busy` (la page réessaie une
fois après 600 ms, puis le dit). Réversibilité déclarée : « Point de retour : sauvegarde vérifiée » (index, parc), relevé
supprimable (capture), définitif (suppression d’un relevé, fusion du partage).

## 6. Exports (`LocalWrite`)

Classe : `LocalWrite` (données locales de l’application, jamais l’annuaire ni un poste) ; `OPERATIONS.md` § 1.3 réserve
cette classe aux préférences et aux reçus : l’usage pour un export demandé par l’opérateur (un fichier neuf, jamais un
remplacement, comme le prévoit le kit pour `onExport`, `KIT.md` § 4.1) y est ajouté **à faire acter par David**.

`synchro.index.export` (toutes les lignes de la recherche, 20 000 au plus, triées) et `synchro.snapshot.export` (rapport
de comparaison) écrivent un CSV neuf dans `%LOCALAPPDATA%\Domenia\Exports` (`Exports-simulation` en simulation) :
point-virgule, en-têtes français, UTF-8 avec BOM, cellules commençant par `= + - @` neutralisées, fichier temporaire du même
dossier écrit en `WriteThrough` puis renommé, jamais un fichier remplacé (« -2 », « -3 »…), dossier remplacé par un lien
refusé. En mode capture, E2E ou sans dossier de données, rien n’est écrit : `written` = `false` et le message le dit.

## 7. Simulation

`SimulatedSyncReader`, `SimulatedSyncStoreExecutor` et l’état partagé `SimulatedSyncState` (un par source, jamais
enregistré) dérivent la base du monde généré avec le sous-flux `screen/synchro` (`SimulatedSyncSeed`), sans toucher au
générateur central :

- vérité du contrôleur : `source.CurrentDirectory` (écritures de la session comprises) ; la base contient ce que les
  lectures précédentes en ont gardé : **OU Postes** lue complètement 12 minutes avant la référence (la date du cache de la
  session) ; **changements du domaine** lus 3 jours et 4 heures avant (repère : USN au-dessous duquel 48 objets ont changé,
  invocationID tiré du flux) ; Paris lue il y a 26 h, Lyon il y a 9 jours (ancienne), Serveurs : tentative coupée par le
  contrôleur il y a 2 jours (ServerTimeLimit 120 s, 9 objets) ;
- objets changés depuis le repère (hors Postes) : versions plus anciennes dans la base (5 déplacés, 3 renommés, 8
  descriptions, 3 états), objets créés depuis absents ; 11 identités du dernier recensement absentes de la base (plus une
  supprimée depuis) ; 4 comptes supprimés depuis le repère encore présents (non revus par la prochaine lecture complète) ;
- disparitions enregistrées : 6 postes de Postes (4 avec entrée `isDeleted`, dont un recyclé), 2 postes réinstallés
  retrouvés dans `CN=Computers`, 3 comptes de nouveau visibles, 4 comptes supprimés, et 5 vérifications plus anciennes
  (2 suppressions, 1 déplacement, 1 introuvable, 1 contrôleur indisponible) ;
- 3 relevés : Postes il y a 21 jours (« Avant la migration Windows 11 », 20 postes encore en Windows 10) et il y a 7 jours,
  domaine entier il y a 26 jours (couverture incomplète) ;
- relevé du parc : 70 % des postes actifs de Postes (ceux sans connexion depuis 90 jours écartés), statuts session, aucune
  session, injoignable, refus ; relevé partagé fictif `\\SRV-FIC-01.example.local\Domenia$\releve-parc.json` de deux autres
  consoles (12 lignes plus récentes, 18 postes en plus), verrou obtenu au deuxième essai puis au premier (l’autre console
  a fini) ; une demande arrivée pendant une synchronisation attend et se fait à la suite ; partage injoignable et verrou
  gardé 12 essais sont modélisés (`SharedReachable`, `SharedLockHeldFor`) ; un résultat de poste en route (un poste
  injoignable qui répond enfin) arrive pendant la première relecture du relevé et s’applique ensuite, ses tentatives
  partant du compteur enregistré ;
- schéma LAPS du domaine fictif : présent (Windows LAPS), lu avec chaque passe ; postes sans expiration : « non visible avec
  ce compte » ; espace disque jamais mesuré (aucun disque), maintenance pendant la sauvegarde vérifiée d’une lecture ;
- avis de démarrage : au démarrage, le module lit une fois la base, en tâche de fond (jamais sur le fil de l’interface), et
  inscrit ses avis dans le journal des opérations affiché par l’Accueil (« Base locale · Changements du domaine lus il y a
  3 jours… », « Base locale · À vérifier : la dernière mise à jour était incomplète… ») ; rien n’est lancé ;
- associations : postes et utilisateur de leur `managedBy` ; dernière sauvegarde vérifiée 47 minutes avant la référence.

Délais réalistes et annulables (`latency/screen/synchro/…` : vue 80–160 ms, recherche 40–120, contrôles 80–180,
comparaison 200–420, lecture : sauvegarde 300–550, 8 à 13 lots de 110–210, recensement 250–450, empreinte 200–380,
validation 150–260 ; écriture : plan 60–140, contrôle 60–140, exécution 320–700, relecture 70–160) ; aucun avec
`SimulationLatency.None`. Durées affichées : modèle de Domenia 1 (≈ 18 ms par objet d’une OU, 12 ms par objet changé,
22 ms par objet d’une relecture complète).

## 8. Page `#/synchro`

- Héros : titre, phrase de synthèse, puces sur une ligne (base, contrôleur, USN, génération), gestes « Mettre à jour l’OU … »
  (avec le domaine pour périmètre : le choix de l’OU s’ouvre d’abord, puis son estimation) et « Changements du domaine »,
  menu « Autres gestes » (dont « Reconstruire la base depuis le domaine… »), cadran de fraîcheur du périmètre (jauge du
  moteur : âge de la dernière lecture complète rapporté au seuil de recensement), périmètre (OU de travail, ou OU choisie
  ici, mémorisée dans l’adresse `?ou=`).
- Titres de section comme l’Accueil (« Indicateurs de la base », « Espaces de travail ») ; quatre tuiles au pied de même
  nature (répartition en deux parts ou jauge de fraîcheur, légende), avis de démarrage. Tous les âges sont mesurés sur
  l’heure du moteur (`now`), une seule forme de date (« 22/10/2026 05:16 »).
- Panneau de lecture : estimation (panneau latéral : déroulement phase par phase, reconstruction explicite pour le domaine,
  limites de la passe modifiables), étapes animées, compteurs, arrêt, aperçu exact de l’enregistrement (barre des
  changements, exemples par catégorie, faits), enregistrement par le circuit d’écriture ; « Ignorer cette lecture » écarte
  le lot du moteur (`synchro.read.discard`) ; une lecture en attente est rappelée au retour sur l’écran.
- Espaces (compteurs sur les onglets) : **Mise à jour** (couverture par périmètre sur un axe de 14 jours, repère, limites et
  leur source, sauvegarde et stockage, reçus de stockage), **Données** (recherche, tri par l’en-tête ou la liste sur toute la
  population dans le moteur, « Pertinence », pages, fiche locale avec l’état LAPS, export), **Contrôles** (recensement,
  objets manquants, disparitions du périmètre ou de tout le domaine, filtrées par état, vérification), **Relevés** (nouveau
  relevé, liste ajustée à ses lignes, menu de la ligne : comparer, prendre comme avant ou après, supprimer ; comparaison
  lisible, filtrable par nature, export de la comparaison affichée), **Parc** (couverture, résultats appliqués après la
  relecture, partage entre consoles en trois étapes, verrou non obtenu : un nouvel essai annoncé et annulable, postes
  relevés, oubli).
- Réponses périmées écartées : chaque lecture de la page porte un numéro de demande et la génération de la base ; une
  réponse plus ancienne ne repeint jamais un état plus récent (Domenia 1 : lecture écartée par génération).
- Adresse : `onglet=mise-a-jour|donnees|controles|releves|parc`, `ou=<DN>`, `q=<terme>`, `objet=<GUID>`, `comparer=1`
  (compare les deux relevés proposés, lecture locale), `lecture=ou|domaine` (ouvre l’estimation, rien n’est lu),
  `choisir=1` (ouvre le choix de l’OU), `apercu=lecture` (**simulation seulement** : lance la lecture de l’OU sans
  confirmation, pour les captures ; aucun effet en mode annuaire).

## 9. Mode annuaire (vague 3)

Ce que `Domenia.Ad` (lecteur `AdSyncReader`) et `Domenia.Store` (exécuteur `StoreSyncExecutor`, base SQLite) devront faire
pour servir les mêmes interfaces. Classes : `synchro.read.run`, `synchro.absences.check`, `synchro.gaps.read`,
`synchro.park.shared.read` sont `NetworkRead` (après le geste) ; tout le reste lit ou planifie la base locale
(`LocalRead`), les exports sont `LocalWrite`. Toute lecture réseau tourne hors du fil de l’interface, passe par la garde
d’authentification (un refus d’identifiants suspend le compte concerné, Domenia 1 Register-WCredentialFailure) et
n’envoie jamais une saisie de la page dans un filtre (GUID et DN échappés, terme jamais inséré dans le SQL).

### 9.1 Base locale (SQLite, `winsqlite3`)

| Table (Domenia 1, schéma 11) | Usage |
|---|---|
| `ad_objects` (`object_guid`, `object_type` Utilisateur/Machine, `name`, `login`, `upn`, `display_name`, `description`, `extra`, `state`, `distinguished_name`, `when_changed`, `usn_changed`, `last_logon`, `search_key`, faits des postes et expiration LAPS) | index, recherche (exacte `=` NOCASE, préfixe `LIKE ?2 ESCAPE '!'`, contenu `search_key LIKE ?3`), paramètres liés (`?1`, `?2`, `?3`), tri par expressions figées (dates françaises ou ISO comparées par `julianday`), `count(*)` et page dans la même transaction (`BEGIN … COMMIT`) |
| `sync_state` (`scope` : `directory`, `ou:<dn>`, `ou:onelevel:<dn>`, `attempt:…` ; `base_dn`, `last_sync`, `details` : `depth=Subtree`, `partial`, `inv=<invocationID>` ; `item_count`, `server`, `highest_usn`) | couverture, repère, tentatives coupées |
| `directory_absence`, recensement du domaine (identités GUID et DN), `directory_snapshot` et ses lignes, `park_state` (`computer_key`, `computer`, `last_probe`, `status`, `user_login`, `attempts`) | contrôles, relevés, parc |

Attente de verrou : 50 ms pour la recherche (puis `busy`), `LocalStore.DatabaseBusyTimeoutMs` (100 à 5 000 ms, 2 500 par
défaut) pour les autres lectures ; une base illisible n’affiche jamais de zéros. Écriture par le rédacteur unique, en une
transaction, après la sauvegarde vérifiée du geste (réutilisée si elle a moins de 30 min) ; lot de lecture transféré sur
disque en `.jsonl` haché, relu et vérifié (nombre de lignes et d’identités) avant la transaction, sinon annulée.

### 9.2 Lecture d’une OU ou du domaine (`IndexBuild`)

- Liaison sur le contrôleur de la session ; RootDSE : `highestCommittedUSN`, `schemaNamingContext`, `dsServiceName`
  (objet NTDS Settings → `invocationId`).
- Recherche paginée (`PageSize` 1 000), portée `Subtree` depuis l’OU choisie (jamais la racine pour une OU),
  `ServerTimeLimit` borné par le budget restant, `SizeLimit` = `Index.MaxObjects` quand il est positif ; postes d’abord
  (`Index.ComputerFirst`).
  - Utilisateurs : `(&(objectCategory=person)(objectClass=user))`, attributs `name`, `sAMAccountName`,
    `userPrincipalName`, `displayName`, `description`, `department`, `title`, `mail`, `distinguishedName`, `objectGUID`,
    `userAccountControl`, `whenChanged`, `uSNChanged`, `lastLogonTimestamp`.
  - Postes : `(objectCategory=computer)`, attributs `name`, `sAMAccountName`, `dNSHostName`, `description`,
    `operatingSystem`, `location`, `distinguishedName`, `objectGUID`, `userAccountControl`, `whenChanged`, `uSNChanged`,
    `lastLogonTimestamp`, `operatingSystemVersion`, `whenCreated`, `pwdLastSet`, `ms-Mcs-AdmPwdExpirationTime`,
    `msLAPS-PasswordExpirationTime` (dates seulement ; jamais `ms-Mcs-AdmPwd`, `msLAPS-Password`,
    `msLAPS-EncryptedPassword`).
  - Schéma LAPS : une lecture de `schemaNamingContext` (`(|(lDAPDisplayName=ms-Mcs-AdmPwdExpirationTime)(lDAPDisplayName=msLAPS-PasswordExpirationTime))`)
    distingue « absent du domaine » de « non visible avec ce compte ».
- Changements du domaine : même filtre avec `(uSNChanged>=<USN+1>)` sur le même contrôleur et la même instance
  (`CheckCheckpoint`), sinon relecture complète estimée et confirmée ; un repère au-delà de `highestCommittedUSN` donne une
  relecture complète (aucun USN extrapolé). Recensement des identités :
  `(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer))`, attributs `objectGUID`, `distinguishedName`,
  `uSNChanged`, `PageSize` 1 000.
- Progression poussée toutes les 500 ms (objets reçus, débit, durée ; total inconnu avant la fin) ; arrêt demandé entre deux
  pages ; une passe coupée par volume, temps ou `ServerTimeLimit` reste partielle (aucune absence, repère inchangé,
  marqueur Index.Partial nommant la limite).

### 9.3 Vérifications par GUID (`DirectoryAbsenceCheck`)

200 identités au plus, lots de 24 : `(|(objectGUID=\xx…)…)` depuis la racine, portée `Subtree`, `PageSize` 24,
`ServerTimeLimit` 15 s, `ClientTimeout` 20 s, budget de 60 s (au-delà : « vérification impossible », jamais « introuvable »).
Disparitions seulement : sonde de visibilité des objets supprimés `(&(isDeleted=TRUE)(isCriticalSystemObject=TRUE))` en
`OneLevel` avec le contrôle *show deleted* (`1.2.840.113556.1.4.417`), puis lecture par GUID avec `isDeleted=TRUE`
(`whenChanged`, `lastKnownParent`, `isRecycled`). Objets manquants du recensement : même lecture du domaine, sans les
objets supprimés.

### 9.4 Relevé partagé (`ParkSharedSync`)

Chemin `ParkSweep.SharedPath` (UNC possible) ; rien sans chemin configuré. Verrou `<chemin>.lock` créé en `CreateNew`,
12 essais espacés de 250 ms, retiré dans le `finally` ; verrou non obtenu : rien n’est écrit, Domenia travaille en local et
le dit. Lecture du JSON, fusion par poste (la ligne la plus récente gagne), écriture d’un fichier temporaire du même dossier
puis remplacement, sous le verrou, après la confirmation du plan.

### 9.5 Réglages repris de `Domenia.config.json`

`Index.MaxObjects` (0 = sans quota), `Index.BudgetMs` (1 200 000 ; l’ancien défaut 240 000 est relevé ; 30 000 au moins ;
délai = budget + 120 s, 300 s au moins), `Index.FullRebuildDays` (7, borné de 1 à 90), `Index.StartupDeltaMaxAgeMinutes`
(30), `Index.ComputerFirst`, `ParkSweep.SharedPath`, `LocalStore.DatabaseBusyTimeoutMs`. Le module lit la section
`Index` de `Domenia.config.json` (à côté de l’exe) au premier usage, hors du fil de l’interface (`SyncSettings.Parse` :
noms insensibles à la casse, nom en double = fichier ignoré, entier JSON ou texte de chiffres comme le cast `[int]` de
Domenia 1, valeur hors bornes = défaut ; le journal technique ne reçoit que les clés lues ou la raison, jamais le contenu) :
`MaxObjects`, `BudgetMs`, `FullRebuildDays`, `StartupDeltaMaxAgeMinutes`. L’estimation permet encore de changer quota et
budget pour une passe. `Index.ComputerFirst`, `ParkSweep.SharedPath` et `LocalStore.DatabaseBusyTimeoutMs` suivront avec
le mode annuaire.

### 9.6 Lectures vides, classes en échec, reconstruction

Une classe dont la lecture échoue rend la passe incomplète (motif `erreur`), jamais un annuaire vide ; une lecture complète
qui ne rend aucun objet alors que la base en contient dans le périmètre, ou un recensement vide du domaine, rend la passe
incomplète (motif `vide`) : aucune absence, repère et date de couverture inchangés (`SyncReconcile.EmptyReadCut`). Seule
une **reconstruction explicite** (`rebuild: true`, Domenia 1 ReplaceAll) confirme un domaine vide après un repère.
L’enregistrement refuse encore un recensement vide hors reconstruction (`SyncReconcile.StorageRefusal`).

### 9.7 Garde d’écriture avant une passe

`SyncCoverageRules.Storage` : maintenance de la base, rédacteur suspendu après 3 échecs d’écriture, espace libre du volume
de la base sous 512 Mio (critique sous 32 Mio), seuils relevés de quatre fois ce qui attend ; sans mesure, rien n’est
bloqué. `Domenia.Store` fournira la mesure et les états en vague 3 ; la simulation n’a pas de disque (« non mesuré »).

## 10. Tests écrits (exécutés à la fin, dans la VM)

| Fichier | Couvre |
|---|---|
| `SyncRulesTests` | appartenance par frontière de RDN et profondeurs ; emplacements lisibles ; classement des déplacements ; résolution des disparitions (preuve `isDeleted`, retrouvé, déplacé, introuvable, invisible, contrôleur indisponible, fiche d’un autre GUID jamais gardée) ; sélection bornée ; résumés ; objets manquants ; couverture (ancêtre, niveau direct, tentative, date future, profondeur inconnue, autre domaine) ; conseil de recensement ; repère (11 codes) ; limites, coupures, avertissement de l’Accueil ; tuiles (base illisible), avis, sauvegarde ; normalisation et score ; tri de la population avant la page, vides en fin ; réconciliation (ajout, déplacement, renommage, valeur, conflit, non revu dans le périmètre seulement) ; empreintes ; repère incrémentiel ; relevés (domaine, nom par défaut, comparaison exacte et bornée, périmètres différents, avertissements) ; fusion du parc ; plans scellés et décodés | ; lectures vides, classes en échec, recensement vide et reconstruction explicite ; empreinte d’aperçu ; garde du stockage (maintenance, rédacteur suspendu, espace disque) ; état LAPS (schéma absent ou valeur non visible) ; résultats du parc différés pendant la relecture ; issues du relevé partagé ; réglages `Index` ; disparitions du périmètre ; comparaisons lisibles et recouvrements expliqués ; tuiles (parts et jauge)
| `SyncOperationsTests` | vue et périmètre ; arguments ; recherche paginée et triée ; export préparé sans écriture ; lecture d’OU gardée puis plan, exécution unique, reçu `applied`/`verified`, base relue, non revus notés, journal ; plan d’un lot remplacé refusé (`write.stale`) ; changements du domaine et repère ; lecture arrêtée partielle ; vérifications et objets manquants enregistrés ; relevés (comparaison, capture, suppression) ; parc (partage fusionné, oubli) ; mode annuaire sans lecteur et aucune opération `Write` | ; lecture écartée (`synchro.read.discard`) ; reconstruction demandée pour le domaine seulement ; heure du moteur, compteurs, stockage, schéma LAPS ; avis de démarrage dans le journal ; exports neutralisés (cellules, en-têtes) ; relevé partagé une fois à la fois (demande faite à la suite) et résultat différé du parc
| `PlatformTests` (mis à jour) | module `SyncOperations` trouvé, 17 opérations et leurs classes |
| `tests/e2e/synchro/*.json` | lecture puis enregistrement, recherche, vérification des disparitions, comparaison et nouveau relevé, partage du parc |

## 11. Reste à faire

- Vague 3 : `AdSyncReader` et `StoreSyncExecutor` (§ 9) : mesure réelle de l’espace libre et compteur d’échecs du
  rédacteur (la règle `SyncCoverageRules.Storage` est en place), classes en échec signalées par la lecture LDAP (la règle
  `SyncReconcile.EmptyReadCut` est en place), lecture de `ParkSweep.SharedPath` et `LocalStore.DatabaseBusyTimeoutMs`.
- L’Accueil reçoit les avis de démarrage par le journal des opérations ; son tableau du parc pourrait aussi reprendre
  `synchro.overview.partial` (décision de l’équipe de l’Accueil).
- Améliorations proposées par le catalogue et non faites : restauration depuis la corbeille AD (écriture AD avec son
  propre plan), synchronisation DirSync côté serveur, relevés programmés, partage par un service central.
