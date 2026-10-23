# Domenia 2 — écran « Utilisateurs et postes » (`relations`)

Contrat des opérations de l’écran `#/relations` : associations entre utilisateurs et postes dans les deux sens (fonctions
REL-001 à REL-052 de Domenia 1), et comparaison des groupes de deux utilisateurs (lot R40 « userdiff », FIC-004 à FIC-006).
Les règles communes du pont (enveloppe, JSON, classes, admission, erreurs) sont celles d’[`OPERATIONS.md`](../OPERATIONS.md)
§ 1 ; le circuit des écritures est celui de [`WRITES.md`](../WRITES.md). Mis en place le 22 octobre 2026 (vague 2),
compilé dans la VM (0 avertissement), tests écrits et non exécutés (décision de David du 21/10 : à la toute fin).

## 1. Principes

| Règle de Domenia 1 | Dans Domenia 2 |
|---|---|
| Une association est locale à Domenia (« AD jamais modifié ») | Magasin local des associations : mémoire de la simulation aujourd’hui, base locale en vague 3. Aucune opération de cet écran n’écrit Active Directory. |
| Une relation = un utilisateur, un poste, une nature de preuve | `RelationRules.Key` et `Same` (GUID décisif des deux côtés, sinon identifiant et premier label DNS). La limite d’une ligne par poste de Domenia 1 est levée : plusieurs relations par poste coexistent (amélioration de REL-024). |
| Une observation ne devient jamais une affectation | Natures distinctes (`assignment`, `console`, `remoteSession`, `history`, `imported`, `hint`, `unknown`) ; une affectation déclarée n’est jamais remplacée, l’historique ne contredit jamais une affectation. |
| Badges explicables, jamais de pourcentage | `RelationRules.BadgeOf` : Déclaré, Observé, Historique, Importé, Indice, À vérifier, chacun avec sa règle et sa provenance. Une association contredite **garde sa nature** et porte en plus la marque « Contradiction » (`contradicted`, règle ajoutée à `rule`) : amélioration de Domenia 1, où la nature disparaissait derrière « Contradictoire ». La facette « Contradictoire » compte les associations contredites, à part des natures (dont la somme reste le total). |
| Identité par GUID (point 9) | Un lien porteur de GUID n’appartient qu’à cet objet ; même nom autre GUID ou lien antérieur à la création = autre détenteur ; sans GUID = « identité non vérifiable ». |
| Aucune sonde sans geste explicite | Chaque lecture réseau part d’un clic ; la détection montre la liste exacte des postes avant tout contact (D047) ; le domaine entier n’est jamais substitué. |
| Écritures confirmées, journalisées, restaurables | Toute modification du magasin est un **plan** (`relations.*.plan`, une lecture) exécuté par `write.execute` : préconditions relues (empreinte de chaque association, contrôle optimiste REL-012), reçu avant l’envoi, relecture, journal local. Jamais rejoué. |
| 64 changements par enregistrement (REL-011, REL-014) | `WritePlans.MaxChanges` = 64 ; au-delà, refus `relation.tooMany` avant tout plan. Un seul enregistrement à la fois : le canal unique du circuit. Les observations (détection, lecture de session, relevé, moisson, observation versée par un autre écran) sont **mémorisées automatiquement** dans la base locale, **par lots de 64**, sans confirmation (choix du 22/10, comme Domenia 1 ; `DECISIONS.md`) : `relations.observations.save` (`LocalWrite`), appelée par le moteur à la fin de `relations.detect.run`, `relations.computer.read` et `relations.harvest.run`, et par la page après 1,5 s de calme pour les observations versées par un autre écran. Chaque lot est scellé et appliqué avec les règles d’un plan (une affectation déclarée n’est jamais remplacée, une association modifiée ailleurs n’est jamais écrasée : le lot refusé s’arrête et le reste demeure « Session uniquement ») ; une ligne du journal des associations par changement (« Mémorisation automatique, lot n »), une ligne au journal technique. Active Directory n’est jamais écrit. `relations.observations.plan` reste disponible pour une observation choisie (circuit des écritures, § 1.1). |
| Identité revérifiée (REL-002, REL-019) | La page envoie le GUID qu’elle a affiché : `relations.associate.plan` (`subjectGuid`, `targetGuid`) refuse un objet dont le GUID a changé (`write.targetUnknown`), `relations.detect.collect` (`guid`, `login`) s’arrête sur un compte recréé ou renommé (`relation.identityChanged`). |
| Sources protégées (REL-043) | `Manual`, `Saisie manuelle`, `Import CSV`, `Import GLPI`, `Import osquery` : jamais proposées par le contrôle des orphelines, jamais remplacées par une détection. |

### 1.1 Mémorisation automatique de Domenia 1 et circuit des écritures

Dans Domenia 1, le compte console d’un relevé (REL-018), d’une console en direct (REL-017) ou d’une moisson (REL-030) devenait
une association enregistrée automatiquement, en arrière-plan, par lots de 64 (REL-014). Domenia 2 garde la mémoire et les
lots, mais **chaque lot est un plan** du circuit des écritures : les règles de la plateforme n’admettent aucune écriture hors
de `write.execute` (`PLATFORM.md` § 3.2, `AdmissionGuards`, décision du 22/10 « Écritures en simulation » et consigne
« écritures toujours planifiées, confirmées, tracées par un reçu »), et la classe `LocalWrite` est réservée aux préférences.
Rien n’est perdu : les observations sont visibles tout de suite (« Session uniquement »), comptées dans le bandeau
« Observations en mémoire » de l’écran, et « Tout enregistrer, lot par lot » enchaîne les plans sans autre saisie qu’une
confirmation par lot. **Écart à faire valider par David** : une mémorisation sans confirmation exigerait une décision écrite
dans `DECISIONS.md` (question posée dans `REPRISE.md` § 4). En attendant, REL-014, REL-017, REL-018 et REL-030 restent
« partiels » dans `docs/status/relations.json`.

**Classes des exports (question posée à David, `REPRISE.md` § 4).** `relations.export.save` est déclarée `LocalWrite` alors
que `PLATFORM.md` § 3.2 réserve cette classe aux préférences : elle écrit un fichier CSV dans le dossier des exports de
l’opérateur (`%LOCALAPPDATA%\Domenia\Exports`), sans toucher à l’annuaire ni aux associations. `relations.export.open` est
déclarée `Local` alors qu’elle ouvre ce fichier par l’association de Windows (`Process.Start`, `UseShellExecute`) : elle ne
lit ni n’écrit rien elle-même, et n’ouvre qu’un fichier écrit pendant la session. Les deux classes restent telles quelles
jusqu’à la décision (ou une classe dédiée aux fichiers d’export dans `PLATFORM.md`).

## 2. Récapitulatif des opérations

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `relations.overview` | `LocalRead` | aucun | `RelationsOverview` |
| `relations.list` | `LocalRead` | aucun | `RelationList` |
| `relations.subject` | `LocalRead` | `{ ref }` (DN, identifiant ou nom de poste, 2 048 caractères au plus) | `RelationSubjectView` |
| `relations.subjects.search` | `LocalRead` | `{ text }` (100 caractères au plus ; vide = suggestions) | `RelationSubjectMatches` |
| `relations.targets.search` | `NetworkRead` (servie en simulation) | `{ dn, text }` (2 caractères au moins) | `RelationTargetSearch` |
| `relations.detect.collect` | `NetworkRead` (servie) | `{ dn, guid, login, scope, ouDn, computers, limit, kerberos }` (`guid` au format D, `login` affiché ; `computers` : 50 noms de postes ou DN au plus) | `RelationDetection` (phase `collect`, avec `plan`) |
| `relations.detect.run` | `NetworkRead` (servie) | `{ planId }` | `RelationDetection` (phase `probe` ou `sweep`) ; événements `relations.detect.run:progress` |
| `relations.detect.stop` | `Local` | `{ planId }` | `{ stopping, message }` |
| `relations.computer.read` | `NetworkRead` (servie) | `{ dn }` | `RelationComputerReading` |
| `relations.harvest.estimate` | `LocalRead` | `{ days (1..30), maxEvents (200..20 000) }` | `RelationHarvestEstimate` |
| `relations.harvest.run` | `NetworkRead` (servie) | `{ estimateId }` | `RelationHarvest` |
| `relations.journal` | `LocalRead` | aucun | `RelationJournal` |
| `relations.import.stage` | `Local` | `{ id, part, parts, text }` | `RelationImportStaged` |
| `relations.import.preview` | `LocalRead` | `{ id, adapter (csv, glpi, osquery), fileName }` | `RelationImportPreview` |
| `relations.orphans.check` | `NetworkRead` (servie) | aucun | `RelationOrphanCheck` |
| `relations.compare` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ dn, other }` | `UserGroupComparison` |
| `relations.sweep.plan` | `LocalRead` | `{ limit (1..50), computers? }` (sans liste : file de l’OU de travail ; avec : 50 noms ou DN d’une liste chargée) | `RelationDetectionPlan` (périmètre `sweep` ou `loaded`) |
| `relations.sweep.forget.plan` | `LocalRead` | aucun | `{ plan, token }` (type `relations.sweepReset`) |
| `relations.observations.pending` | `LocalRead` | aucun | `RelationPendingObservations` |
| `relations.observations.save` | `LocalWrite` | aucun | `RelationAutoSave` (`saved`, `batches`, `remaining`, `text`) ; mémorisation automatique par lots de 64, sans confirmation ; refus tracé au journal technique, `write.stale` |
| `relations.export.save` | `LocalWrite` | `{ id, part, parts, subject, text }` (`subject` : `toutes`, `sujet`, `selection`, `moisson`, `orphelines`, `import` ; parties de 600 000 caractères, 64 au plus, 16 Mo en tout) | `RelationExportAnswer` |
| `relations.export.open` | `Local` | `{ fileName }` (export de cette session) | `{ opened, message }` |
| `relations.associate.plan` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ dn, subjectGuid, target, targetGuid }` (GUID affichés, format D) | `{ plan, token }` (§ 12.1 d’OPERATIONS.md) |
| `relations.remove.plan` | `LocalRead` | `{ key, fingerprint }` | `{ plan, token }` |
| `relations.restore.plan` | `LocalRead` | `{ entry }` (32 hexadécimaux ou `null` = la plus récente) | `{ plan, token }` |
| `relations.import.plan` | `LocalRead` | `{ previewId }` | `{ plan, token }` |
| `relations.import.undo.plan` | `LocalRead` | `{ batch }` (identifiant de lot ou `null` = le plus récent) | `{ plan, token }` |
| `relations.orphans.plan` | `LocalRead` | `{ checkId, keys }` (1 à 64 clés) | `{ plan, token }` |
| `relations.observations.plan` | `LocalRead` | `{ resultId, keys }` (0 à 64 clés ; 0 = les 64 suivantes non enregistrées, le reste annoncé dans les risques) | `{ plan, token }` |

Identifiants (`planId`, `estimateId`, `id`, `previewId`, `checkId`, `resultId`, `entry`) : 32 caractères hexadécimaux
minuscules ; sinon `arguments.invalid` (« « planId » doit être un identifiant de 32 caractères hexadécimaux. »).
`resultId` = 32 zéros désigne les observations de la session non encore enregistrées (lignes « Session uniquement »).
Les résultats gardés par le moteur (périmètres, observations, aperçus, contrôles, estimations) valent 15 minutes ; au-delà
`relation.expired` ou `relation.planExpired`.

**Cible des plans d’association.** Les écritures de relations visent le magasin local entier, pas un objet de l’annuaire :
le champ « DN » du plan et des détails techniques porte la désignation du magasin (« Mémoire de la simulation ·
associations utilisateurs-postes », ou le magasin local en mode annuaire), et toutes ces écritures partagent la même cible
(GUID du magasin). Conséquence du circuit : un reçu à l’issue incertaine bloque toute nouvelle écriture d’association
(`write.targetPending`) jusqu’à sa relecture (« Relire l’objet » du reçu, `write.receipts.verify`) ; rien n’est jamais rejoué.

Le type d’écriture de tous les plans est **`relations.change`** (`RelationChange.Kind`) ; la cible est le magasin local
(`WriteTarget.Kind` = `relations`, GUID fixe `6d1b0c2e-5a47-4f3b-9e21-8c0a7d4f2b19`), nommée d’après ce que le plan change
(« j.martin → PC-PAR-0042 », « Lot 20261016T…-5eedb47c »). Chaque changement est l’attribut `association`, de nature
`add`, `remove` ou `replace`, avec en valeurs brutes « empreinte|clé » de l’association avant et après. Confirmation
simple (changement local, journalisé, réversible) ; réversibilité déclarée par plan.

## 3. Formes des résultats

Les noms sont exactement ceux des records de `Domenia.Core/Screens/Relations/RelationModels.cs` en camelCase ; les champs
nuls sont écrits. Énumérations : `kind` ∈ `assignment|console|remoteSession|history|imported|hint|unknown` ; `badge` ∈
`declared|observed|history|imported|hint|contradictory|toCheck` ; `persistence` ∈ `stored|session` ; `identity` ∈
`same|different|unknown` ; `action` du journal ∈ `added|removed|restored|refreshed|conflict`.

### 3.1 `RelationRow`

`key`, `fingerprint` (SHA-256 de l’association, contrôle optimiste), `userLogin`, `userName`, `userDn`, `userGuid`,
`computer`, `computerDn`, `computerGuid`, `kind`, `badge`, `badgeLabel`, `tone`, `rule` (règle + « Provenance : … »),
`source`, `when` (UTC), `whenText` (« 08/10 09:15 », année si différente), `details`, `persistence`, `persistenceLabel`
(« Enregistrée », « Session uniquement »), `identity`, `identityNote`, `verifiedInAd`, `protected`, `batchId`,
`contradicted`, `declarant`.

### 3.2 `relations.overview`

`storeLabel` (« Mémoire de la simulation » / « Base locale »), `simulated`, `total`, `users`, `computers`, `badges`
(sept compteurs dans l’ordre des facettes, zéros compris), `contradictions` (postes), `unverified`, `sessionOnly`,
`lastImport` (`batchId`, `fileName`, `source`, `importedAt`, `count`, `tip`) ou `null`, `restore` (`entryId`, `label`
« Restaurer jdupont → PC01 », `tip`, `removedAt`, `userLogin`, `computer`) ou `null`, `activity` (14 jours :
`date`, `label`, `observed`, `history`), `journalEntries`, `summary`, `pending` (`RelationPendingObservations`, § 3.6).
Les six natures de `badges` totalisent `total` ; l’entrée `contradictory` compte les associations contredites (qui gardent
leur nature) et `contradictions` les postes concernés.

### 3.3 `relations.subject`

`subject` (`kind`, `dn`, `guid`, `name`, `login`, `detail`, `path`, `enabled`, `lastLogon`, `created`), `direction`
(libellés D041 : « Associer ce poste », « Détecter les postes » / « Lire la session de ce poste »…), `overview` (lignes
« Affectation déclarée », « Dernière session observée », « Historique », « Autres indices » avec badge), `primary`
(poste ou utilisateur principal : affectation déclarée, sinon relation la plus récente, avec sa raison) ou `null`,
`associations` (`RelationRow`, liens de son GUID ou liens hérités de son nom non antérieurs à sa création),
`logons` (30 au plus : sessions observées, à distance, relevés d’historique et `lastLogonTimestamp`), `graph`
(`nodes` : `id`, `kind`, `label`, `sub`, `dn`, `depth` 0 à 2, `primary`, `exists`, `tone`, `links` ; `edges` : `from`, `to`,
`badge` le plus fort, `count`, `when`, `contradicted`, `label` ; `truncated` quand le deuxième cercle est borné à
24 nœuds, 5 par nœud), `counts`, `context`, `restore` (la dernière suppression **de ce sujet** seulement ; celle du magasin entier reste dans
`relations.overview`). Erreur propre : `relation.unknown`.

### 3.4 Détection (`relations.detect.*`)

1. `collect` (geste « Lire l’annuaire ») : compte relu (même GUID et même identifiant que le sujet affiché, sinon
   `relation.identityChanged` avant toute autre lecture), associations connues (50 au plus), postes dont il est `managedBy`,
   postes qui le mentionnent (description, emplacement), indices Kerberos 4768 sur 7 jours si `kerberos` (adresses,
   jamais associées). Périmètre `scope` : `candidates` (postes connus et candidats AD), `ou` (`ouDn`, l’OU de travail par
   défaut ou une OU choisie dans l’arborescence, jamais la racine), `loaded` (`computers` : 50 noms de postes ou DN au plus,
   liste chargée : postes affichés dans « Toutes les associations » ou liste reçue d’un autre écran par l’adresse
   `#/relations?…&liste=PC-PAR-0042,PC-PAR-0043`, résolus dans l’index local seulement). Réponse : `attempts`
   (`method`, `status` OK/VIDE/A_REVOIR/CONFIRME/LU/REFUSE/AUTH_REJETEE/DELAI/ERREUR/NON_DEMANDE…, `statusLabel`, `tone`,
   `target`, `detail`, `durationMs`, `resource`), `candidates` (`origins`, `why`, `associable`, `blocker` : une adresse ou
   un nom partiel n’est jamais associable), `hints`, `plan` (`id`, `allowed`, `scopeLabel`, `limit`, `eligible`,
   `truncated`, `targets`, `text`, `reason`, `zeroMeaning`). Aucun poste contacté.
2. `run` (geste « Lancer la détection ») : lecture de la console (Win32_ComputerSystem, CIM/DCOM, 4 s) des **seules** cibles
   du plan confirmé, une détection à la fois (`relation.probeBusy`), **une seule fois par périmètre** (le relancer répond
   `relation.planExpired`), arrêt au **premier refus d’identifiants** (`AUTH_REJETEE` : aucun autre poste contacté avec ce
   compte). La boucle est une règle de Core partagée par les sources (`RelationProbeLoop`) ; un relevé fait d’abord un **ping
   groupé par lots de 8** et ne demande la session qu’aux postes qui répondent. Chaque poste pousse `relations.detect.run:progress`
   (`planId`, `counters`, `computer`, `status`, `statusLabel`, `tone`, `currentUser`). Le résultat dit `within` (liste
   sondée incluse dans le plan), `complete`, `counters` (`planned`, `queried`, `confirmed`, `noSession`, `refused`,
   `unreachable`, `stopped`, `text`), `savable` et `resultId` (observations de cette lecture). Les consoles confirmées
   sont mémorisées automatiquement dans la base locale à la fin de l’opération, par lots de 64 (§ 1).
3. `stop` : arrêt demandé, pas une annulation confirmée ; le poste en cours se termine, résultat partiel déclaré.

### 3.5 Autres lectures

- `relations.computer.read` : `observed` (`account`, `login`, `userDn`, `userGuid`, `userName`, `match`, `certain`,
  `reason` du contrôle d’identité D049, `source`, `kind`, `badge`, `observedAt`) ou `null`, `savable`, `resultId`.
- `relations.harvest.estimate` puis `relations.harvest.run` : couples (`key`, `userLogin`, `computer`, `firstSeen`,
  `lastSeen`, `events`, `eventIds`, `known`), `events`, `truncated`, `machineAccountsIgnored`, `unresolved`, `resultId`.
  Les couples **absents** du magasin rejoignent les observations de la session (Domenia 1 Add-UserMachineLinkIfMissing, un
  couple connu n’est jamais écrasé) ; la mémoire des relevés apprend la dernière ouverture de chaque poste (ParkState).
- `relations.journal` : `entries` (500 au plus, plus récentes d’abord : `action`, `actionLabel`, `tone`, `at`,
  `declarant`, `note`, `userLogin`, `computer`, `kind`, `badgeLabel`, `source`, `restorable`, `restoredBy`),
  `restorable` (toutes les suppressions encore restaurables), `note`.
- `relations.import.stage` : parties de 600 000 caractères au plus, 64 parties, 8 Mio en tout, 4 fichiers à la fois,
  mémoire seulement (10 minutes) ; `relations.import.preview` lit le texte rassemblé (`relation.importIncomplete` sinon) :
  `total`, `shown` (1 000 au plus), `ready`, `counts` (`valid`, `conflict`, `reject`, `duplicate`, `known`, `unknown`,
  `deferred`), `indexState`, `notes`, `summary`, `rows` (`record`, `user`, `computer`, `status`, `category`, `reason`,
  `import`), `batchId`.
- `relations.orphans.check` : `rows` (`key`, `userLogin`, `computer`, `source`, `reason`, `when`, `selected` pour les 64
  premières), `checked`, `protected`, `summary`.
- `relations.compare` : `left`, `right` (`dn`, `name`, `login`, `label`, `title`, `department`, `office`, `manager`,
  `groups`), `attributes` (Service, Fonction, Bureau, Responsable : `left`, `right`, `same`), `groups` (`dn`, `name`,
  `category` `onlyLeft|onlyRight|common`, `categoryLabel`, `leftOrigin`/`rightOrigin` `none|direct|nested|primary`, `path`,
  `depth`, `primary`, `privileged`, `alert`), `counts`, `limits`, `summary`, `note`, `ticket` (texte prêt à coller),
  `readAt`. Attributs comparés : Service, Fonction, **Société** (`company`), Bureau, Responsable. Erreurs :
  `relation.notAUser`, `relation.compareUnresolved` (second compte introuvable, d’un autre domaine ou ambigu, avec la raison).

### 3.6 Observations en mémoire, exports, service partagé

- `RelationPendingObservations` : `total` (observations de la session pas encore enregistrées), `batches` (plans de 64
  nécessaires), `sets` (`resultId` — 32 zéros pour la session entière —, `origin`, `total`, `remaining`, `batches`,
  `sources` : `source`, `count`, `expiresAt`), `text`. Un résultat dont on enregistre les lots voit sa durée de vie prolongée.
- `RelationExportAnswer` : `id`, `received`, `parts`, `complete`, `result` (avec la dernière partie : `saved`, `fileName`
  « Domenia-Relations-<liste>-AAAAMMJJ-HHmmss.csv », `folder`, `rows`, `bytes`, `sha256`, `message`, `at`). Pour « Toutes »,
  la sélection et le sujet, le CSV est le **fichier d’échange de Domenia 1** (Export-DomeniaLinksCsv, CO-04), construit à
  partir des lignes et non des colonnes affichées : `UserLogin;UserName;Computer;Kind;Source;VerifiedInAD;When;Details;UserGuid;ComputerGuid;UserDn;ComputerDn;BatchId;Persistence`,
  dates ISO UTC, formules neutralisées, séparateur « ; » ; l’import le relit (« Déjà connue »). Les autres listes (moisson,
  orphelines, aperçu d’import) exportent les colonnes de leur grille (formules neutralisées, colonnes d’action et secrètes
  exclues). Le fichier est écrit en UTF-8 avec BOM dans
  `%LOCALAPPDATA%\Domenia\Exports` (`Exports-simulation` en simulation), jamais écrasé ; en capture et en E2E, rien n’est
  écrit (`saved` = `false`). `relations.export.open` n’ouvre qu’un fichier écrit pendant la session (Domenia 1
  BtnOpenLinksCsv).
- **Service partagé** `IRelationsReader.ObserveAsync(RelationObservationRequest)` (REL-017, Domenia 1
  Merge-DomeniaLiveLinkMemory) : un autre module du moteur (console en direct de l’écran Poste) y verse le compte console
  qu’il a lu (`computer`, `account` « DOMAINE\compte », `source`, `observedAt`, `detail`). Accepté seulement pour un compte
  de l’annuaire du domaine, qualifié par son domaine, sur un poste connu ; un compte local, d’un autre domaine ou un nom nu est
  refusé avec la raison. L’observation reste « Session uniquement » jusqu’à son plan. Aucune opération du pont ne l’expose :
  une page ne peut pas fabriquer une observation.

## 4. Erreurs propres

| Code | Cause |
|---|---|
| `relation.unknown` | Sujet ou objet introuvable dans l’index local. |
| `relation.subjectKind` | Détection demandée pour un poste, lecture de session pour un utilisateur. |
| `relation.term` | Recherche de cible de moins de deux caractères. |
| `relation.sameKind` | Association de deux objets du même type. |
| `relation.tooMany` | Plus de 64 changements dans une demande. |
| `relation.expired`, `relation.planExpired` | Résultat ou périmètre gardé inconnu, expiré ou d’une autre session. |
| `relation.planRefused` | Périmètre refusé (OU absente, racine, aucun candidat). |
| `relation.probeBusy` | Une détection est déjà en cours. |
| `relation.importTooLarge`, `relation.importIncomplete`, `relation.importEmpty` | Fichier d’import trop gros, incomplet, vide ou illisible. |
| `relation.nothingToRestore`, `relation.alreadyExists`, `relation.noBatch` | Rien à restaurer, association déjà présente, aucun lot d’import. |
| `relation.notAUser`, `relation.compareUnresolved` | Comparaison sur un objet qui n’est pas un utilisateur ; second compte non résolu. |
| `relation.identityChanged` | Le compte relu n’est plus celui affiché (GUID différent : recréé ; identifiant différent : renommé). |
| `relations.exportFailed`, `relations.exportTooLarge` | CSV non écrit (droits, disque, lien), ou plus de 16 Mo. |
| `write.targetUnknown`, `write.stale`, `write.nothingToDo` | Codes du circuit : association introuvable, modifiée ailleurs depuis son affichage, rien à écrire. |

## 5. Simulation

`SimulatedRelationsReader` et `SimulatedRelationChangeExecutor` partagent `SimulatedRelationState` (un par source simulée,
mémoire seulement). Le magasin initial est dérivé du monde généré par le sous-flux `screen/relations`
(`SimulatedRelationSeed`) : environ 45 % des postes actifs avec une affectation déclarée, 58 % avec une console observée
dans les 14 derniers jours dont **exactement 9 postes contradictoires** (Camille Bernard comprise), 48 % avec un relevé
d’historique, un lot d’import GLPI de 24 lignes daté de six jours (« Annuler l’import »), 10 indices d’inventaire du poste, 12 sessions
distantes de comptes d’administration sur les serveurs, 14 lignes héritées sans GUID (2 pour un nom de poste recyclé),
11 associations orphelines et 3 affectations déclarées sans objet (protégées). Julien Martin (`j.martin`, compte de la
session) a un poste principal déclaré observé il y a 47 minutes, un portable observé hier, des relevés anciens et un
collègue relevé sur son poste. Le journal contient l’import, des déclarations récentes, une suppression restaurable et une
suppression déjà restaurée. Les lectures réseau répondent de façon déterministe : consoles d’après la présence relevée et le
magasin (refus 5 %, aucun compte 19 %), indices Kerberos par utilisateur, couples de moisson par poste. Délais
`latency/screen/relations/…` et `latency/screen/write/relations/…`, aucun avec `SimulationLatency.None`. La moisson voit
aussi les postes actifs sans association (utilisateur habituel du même site, parfois un collègue : sous-suite
`harvest/<jours>/free`), ce qui donne plus de 64 nouveaux couples sur 7 jours et rend visibles les lots successifs. Le ping
d’un relevé répond d’après la présence relevée du poste. « Oublier les relevés » (`SimulatedRelationSweepResetExecutor`) vide
la mémoire des relevés de la session.

## 6. Mode annuaire (vague 3)

La vague 3 branche les mêmes interfaces (`IRelationsReader`, `IRelationChangeExecutor`) sur la base locale et
l’annuaire. Le module du pont et les règles de Core ne changent pas ; seules les implémentations s’ajoutent
(`Domenia.Store` pour le magasin, `Domenia.Ad` et `Domenia.Inventory` pour les lectures réseau).

### 6.1 Magasin local

- Table SQLite `user_machine_links` de Domenia 1 (schéma 11) lue et migrée sans perte : clé `computer_key` gardée pour la
  première relation d’un poste, clé propre pour les suivantes (`Get-DomeniaRelationStorageKey`), dates sans décalage lues en
  heure locale (TRV-091), colonne `batch_id` ajoutée et remplie depuis le jeton « Lot d’import … » des détails.
- Lecture au premier usage, hors du fil de l’interface (`LocalIndexRead`), attente de verrou bornée (OPE-032) ; écriture
  par `IRelationChangeExecutor` seulement : sauvegarde vérifiée de la base avant un import ou un nettoyage (FI-13,
  `StorageBackup`), transaction unique par plan, relecture des empreintes avant l’écriture (`RelationChange.Check`) et
  après (`RelationChange.Verify`).
- Journal : en mémoire (500 lignes) et, pour les retraits et restaurations, `%LOCALAPPDATA%\Domenia\relations-journal.jsonl`
  (une ligne JSON par entrée, domaine de la session, ajout atomique sous verrou commun aux instances, 400 dernières lignes
  relues) ; un échec disque est dit et l’entrée gardée pour la session.
- Index local des noms (`ResolveNames`) pour l’aperçu d’import : 1 000 identifiants et 1 000 postes au plus, par paquets
  de 200, jamais le réseau.

### 6.2 Requêtes LDAP (System.DirectoryServices.Protocols, contrôleur de la session, pages de 40)

| Usage | Base, portée, filtre | Attributs | Bornes |
|---|---|---|---|
| Recherche de cible, poste (REL-001) | racine du domaine, sous-arbre, `(&(objectCategory=computer)(\|(name=*t*)(dNSHostName=*t*)(sAMAccountName=t$)))` | `name`, `dNSHostName`, `distinguishedName`, `objectGUID`, `operatingSystem`, `location`, `userAccountControl` | 51 résultats (50 + détection de la limite), 8 s serveur, 10 s client, terme échappé (RFC 4515) |
| Recherche de cible, utilisateur | racine, sous-arbre, `(&(objectCategory=person)(objectClass=user)(\|(sAMAccountName=*t*)(displayName=*t*)(userPrincipalName=t*)))` | `sAMAccountName`, `displayName`, `userPrincipalName`, `distinguishedName`, `objectGUID`, `title`, `department`, `physicalDeliveryOfficeName`, `userAccountControl` | idem |
| Compte relu (REL-019) | DN du sujet, base, `(&(objectCategory=person)(objectClass=user))` | `sAMAccountName`, `userPrincipalName`, `objectGUID`, `objectSid` | 1 ; GUID différent = compte recréé, identifiant différent = renommé : arrêt |
| Associations connues | racine, sous-arbre, `(&(objectCategory=computer)(\|(name=n)(dNSHostName=n)(sAMAccountName=n$)))` | ordinateur | 2 par lien, 50 liens |
| Responsable déclaré | racine, sous-arbre, `(&(objectCategory=computer)(managedBy=<DN échappé>))` | `name`, `dNSHostName`, `distinguishedName`, `objectGUID`, `description`, `managedBy` | 100 |
| Mention du compte | racine, sous-arbre, `(&(objectCategory=computer)(\|(description=*login*)(location=*login*)))` | idem | 100 |
| Périmètre OU | OU choisie (jamais la racine), sous-arbre, `(objectCategory=computer)` | idem | limite du plan (1 à 50) |
| Vérification de cible avant plan (REL-002) | DN de la cible, base | type, `objectGUID`, `sAMAccountName` | 1 ; GUID et DN comparés à ceux du choix |
| Contrôle des orphelines (REL-052) | par GUID (`<GUID=…>`) puis par nom pour les liens hérités | `objectGUID`, `distinguishedName` | 64 associations par paquet, budget 60 s |
| Comparaison des groupes (R40) | `GroupPathRead` de Domenia 1 : `memberOf` en largeur, groupe principal (`primaryGroupID` → RID du domaine) | `memberOf`, `objectSid`, `adminCount`, `name` | 16 niveaux, 2 000 groupes, 10 s par compte, deux lectures successives |

Un refus d’identifiants (`AUTH_REJETEE` : 0x8007052E, 0x8009030C…) suspend le canal annuaire du compte (garde
d’authentification, TRV-206) : aucune nouvelle requête, demande d’un autre compte dans Accès (REL-029), aucun rejeu.

### 6.3 Postes et journaux (Domenia.Inventory)

| Usage | Méthode | Bornes |
|---|---|---|
| Console d’un poste (REL-021, « Lire la session ») | CIM sur DCOM : `Win32_ComputerSystem` (`UserName`, `Name`), une session par poste, pas de repli WinRM, ni tâche, ni registre | 4 s par poste, 50 postes, budget 120 s, nom reçu différent du nom AD = rejeté, arrêt au premier rejet d’identifiants |
| Indices Kerberos (REL-022) | `Get-WinEvent` équivalent (EventLog API) sur le contrôleur de la session, XPath `EventID=4768`, `TargetSid`, `Status=0x0`, 7 jours | 100 événements, un seul contrôleur, bail d’authentification |
| Moisson (REL-030) | Journal Sécurité du contrôleur : 4768, 4769, 4624 ; comptes machines (`$`) ignorés | 1 à 30 jours (7), 200 à 20 000 événements (5 000), estimation confirmée avant |
| Relevé incrémentiel (REL-031) | Console des postes de l’OU de travail (ou d’une liste chargée), jamais relevés puis plus anciens ; poste non réauthentifié (`lastLogonTimestamp`) depuis son relevé non redemandé ; ping ICMP par lots de 8 avant la session (`RelationProbeLoop`) | 50 postes par relevé, budget, report au relevé suivant ; « Oublier les relevés » après sauvegarde vérifiée de la base (`RelationSweepReset`, FI-13) |

### 6.4 Budgets et classes

`relations.targets.search`, `relations.detect.collect`, `relations.orphans.check`, `relations.compare` et
`relations.associate.plan` sont des lectures réseau après un geste ; `relations.detect.run`, `relations.computer.read`,
`relations.harvest.run` contactent des postes ou le journal du contrôleur, bornés comme ci-dessus. Aucune n’est lancée par
l’affichage d’une page, un défilement ou un rendu (D048). Les durées et volumes sont tracés dans le journal technique
(codes et nombres seulement, jamais un nom, un DN ou une adresse).

## 7. Page

`web/js/pages/relations.js` et `web/js/pages/relations/*.js` (`model`, `graph`, `subject`, `all`, `compare`, `journal`,
`panels`), feuille `web/css/pages/relations.css` (toutes les règles sous `[data-page="relations"]`, y compris le contenu
des panneaux, qui porte `data-page="relations"`). Paramètres d’adresse : `onglet`, `sujet`, `vue`, `panneau`, `a`, `b`,
`filtre=contradictoire`, `liste` (en-tête de `relations.js`). Les écritures passent toutes par `runWrite`
(`web/js/write-flow.js`) ; les panneaux de travail sont **ancrés** (non modaux) : le panneau du plan s’ouvre par-dessus et
le panneau de travail continue après le reçu (association enregistrée ou refusée, lot suivant, orphelines retirées). Les
étapes de l’association suivent `associationStep` (`model.js`, miroir de `RelationRules.Step` et `Refusal`) : un geste refusé
est dit en une phrase. Les dates de preuve sont relatives sur deux jours, absolues au-delà. L’aperçu dans un navigateur
(`mock.js`, fichier partagé) ne sert pas encore ces opérations : la page y affiche ses erreurs (demande au propriétaire du
fichier). Changement de session (REL-047) : la session de Domenia 2 ne change pas pendant l’exécution (un compte par
processus) et le moteur garde un état par source ; la page écoute l’événement `session.changed` (quand le pont le publiera)
et compare `session.info` à chaque retour au premier plan : sujet, panneau, recherches, comparaison et observations de
l’ancienne session sont écartés avec un message, rien n’est enregistré ni retiré.

### 7.1 Reste à faire (statut `docs/status/relations.json`)

- REL-013 : lecture et migration de la table SQLite `user_machine_links` de Domenia 1 (mode annuaire, § 6.1, avec
  `Domenia.Store`).
- REL-029 : la demande d’un autre compte suppose un canal d’identifiants commun à tous les écrans (invite Windows,
  `SecureString` jusqu’à l’API), qui n’existe pas encore dans Domenia 2. Fait ici : arrêt au premier refus d’identifiants,
  ressources refusées nommées et copiables dans la carte « Reprise d’accès », jamais rejouées.

## 8. Tests écrits (exécutés à la fin, dans la VM)

`tests/Domenia.Tests/RelationsTests.cs` : boucle de sonde (arrêt au premier refus d’identifiants, ping par lots, arrêt
demandé), application défensive (`write.stale`), nature gardée des lignes contredites, bornes de la mise en attente de
l’import (64 parties, 600 000 caractères, 4 fichiers, 10 minutes), lots de 64 des observations de la session, service
partagé d’observation, file du relevé (non réauthentifié écarté, racine refusée, liste chargée) et « Oublier les relevés »,
exports par parties, société et ticket complet de la comparaison, annulation d’import et restauration sur un magasin
modifié, GUID revérifiés (association, détection), périmètre sondé une fois ; règles (nature, clés, égalité, upsert, principal, badges, contradictions,
synthèse, identité, sources protégées, orphelines, filtre, états de l’association, identité de compte, candidats,
périmètre, compteurs), import (CSV, GLPI, osquery, identité, dates, priorité, lot, statuts), comparaison (groupes directs,
imbriqués, principal, boucles, privilèges, ticket), projection, pont (formes JSON, arguments, admission, classes), circuit
(association, retrait, restauration, import et annulation, orphelines, observations : reçu `applied`/`verified`, journal,
contrôle optimiste, plan exécuté une fois). Scénarios E2E : `tests/e2e/relations/*.json` (sujet et vues, association avec
l’état « Enregistrée », retrait depuis la liste, détection, lecture de session, moisson et lots, relevé et effacement,
orphelines, import et annulation, comparaison, journal).

## 9. Lecture compatible de la table D1 (23/10/2026)

`IRelationLocalCache` fournit les relations de la base avec leur clé physique originale, l’empreinte SHA-256 de leur projection bornée, leur nature et leurs GUID. La lecture respecte l’identité de la base et du domaine ; elle ne crée pas de fichier, n’ajoute pas de colonne et ne réécrit aucun lien. Plusieurs lignes d’un même poste, avec les clés secondaires de D1, restent distinctes. Le jeton « Lot dʼimport … » est reconnu quand aucune colonne batch_id n’est renseignée. La migration additive de cette colonne et les écritures transactionnelles restent à raccorder.

Pagination de 512 lignes sous une même transaction de lecture, plafonds 50 000 lignes et 32 Mio, cellules bornées dans la projection SQL avant allocation managée. Les lignes trop grandes, GUID malformés ou DN étrangers sont écartés de la vue avec un compteur ; leurs originaux restent en base. Une date sans décalage suit le fuseau local ; heure ambiguë/inexistante au changement d’heure, date future ou illisible donnent une date inconnue signalée, jamais une heure inventée.

La console Poste utilise déjà ce lecteur local sans contacter l’annuaire. Les affectations déclarées sont conservées, les noms sans GUID ne sont pas transformés en identités actuelles. Six tests écrits et compilés seulement ; Debug/Release sans avertissement. Le journal historique, les modifications de relations, leur mémorisation automatique autorisée le 22/10 et l’écran Relations réel restent à terminer. Le §1.1 historique décrivant une attente d’autorisation est antérieur à cette décision : il n’impose pas de nouvelle demande d’accord.

## 10. Journal historique D1 en lecture (23/10/2026)

Le chemin réel de D1 est le chemin complet de la base suivi de `.relations-journal.jsonl`. Le lecteur accepte les champs historiques et leurs variantes de casse, conserve UUID et références de restauration, recalcule la clé sémantique et exige le domaine courant. Les propriétés JSON en double, UUID contradictoires, dates futures et restaurations sans référence sont écartés avec un compteur ; aucune ligne originale n’est modifiée.

La lecture porte sur les 400 dernières lignes dans une fenêtre maximale de 8 Mio ; toute coupure est annoncée comme historique partiel. Chaque ligne est limitée à 64 Kio et décodée en UTF-8 strict. Une répétition exactement identique est regroupée, mais deux contenus différents sous un même UUID sont tous deux exclus. Les entrées lisibles restent disponibles malgré les lignes invalides. Cinq tests couvrent ces reprises et limites ; ils sont compilés seulement, avant la recette finale. Les écritures et restaurations restent à raccorder au circuit transactionnel.

## 11. Transactions locales et reprise du journal (23/10/2026)

`IRelationLocalWriter` reçoit un plan scellé et les lignes préparées, liées au StoreId. Les données doivent correspondre exactement aux changements du plan, dans le domaine courant ; simulation, plan expiré/altéré, lot de plus de 64 et identité étrangère sont refusés. Les colonnes kind, batch_id et declarant sont ajoutées dans la première transaction d’écriture après sauvegarde. Les lectures seules continuent de ne rien migrer.

Chaque lot relit la base sous BEGIN IMMEDIATE, contrôle les empreintes physiques des lignes touchées puis applique les règles communes. La comparaison inclut les colonnes supplémentaires D1 (32 au plus, 64 Kio au total par ligne) et les anciens champs de confiance/date ; elle n’invalide pas un plan pour une modification d’une autre association. Une ambiguïté sur une clé sémantique touchée, une ligne non lisible ou une lecture tronquée empêche l’écriture. Les mises à jour utilisent les clés physiques d’origine et des colonnes nommées, sans remplacement global de ligne. Un ajout conserve la convention D1 : clé du poste libre, sinon clé secondaire. Les anciennes colonnes supplémentaires restent intactes lors d’une mise à jour ; la sauvegarde conserve aussi les originaux complets avant retrait.

Lignes, entrées de journal et identifiant de lot sont validés ensemble, après relecture exacte. Un déclencheur produisant un résultat différent fait annuler la transaction. Le reçu durable empêche le rejeu après redémarrage, y compris si une autre action a supprimé depuis le résultat du premier lot. Une réutilisation du même identifiant avec un contenu différent est refusée.

SQLite conserve le journal faisant foi pour les nouveaux lots. La copie au format historique adjacent à la base suit une file persistante : append, vidage disque, puis acquittement SQLite, 256 entrées au plus par passage. Une interruption avant acquittement peut répéter un UUID identique ; le lecteur regroupe ces répétitions. Si le fichier D1 est occupé, l’état signale la copie en attente et le journal SQLite reste lisible ; une écriture suivante reprend la file. Une restauration exige en plus de relire le retrait sous un accès fichier excluant les écrivains concurrents, compare le contenu et interdit de consommer deux fois la même entrée. Aucune restauration n’est lancée implicitement.

Neuf tests couvrent notamment la concurrence D1, le rollback au milieu d’un lot, les clés/colonnes historiques, la restauration, le rejeu, le fichier verrouillé, les doublons, les déclencheurs et les mauvaises destinations. Ils sont écrits et compilés, pas encore exécutés. Ce socle doit encore être raccordé aux gestes réels de l’écran et au service partagé d’observation.

## 12. Observations natives partagées et mémorisation (23/10/2026)

Le service `AdRelationSession` reçoit uniquement des observations internes déjà qualifiées par les lecteurs natifs, avec les deux GUID, DN du domaine et l’époque courante. Il n’effectue aucun rapprochement par nom et n’accepte ni affectation ni import dans la file automatique. Console/session exigent une date ; l’historique peut rester non daté. La file est limitée à 4 096 associations et refuse un dépassement sans évincer silencieusement les précédentes. Un changement de session l’invalide.

Les observations rejoignent SQLite par lots scellés de 64 (64 lots au plus par passage), sous un bail empêchant la bascule de session pendant l’écriture. Les préconditions et transactions du §11 s’appliquent. Seule une clé exacte avec GUID peut être rafraîchie ; les déclarations et liens historiques sans GUID restent séparés. Une observation plus ancienne ou non datée ne remplace pas un constat daté plus récent. Les champs de lot/déclarant déjà enregistrés sont conservés.

Un échec interrompt la passe et garde les observations sans relance immédiate. Un retour perdu après commit se résout au passage suivant par une relecture : aucun second envoi ni nouveau journal si la donnée est déjà enregistrée. Les observations acquittées, déjà connues ou dépassées sont libérées de la file. Les opérations restent locales et ne déclenchent aucune lecture ou écriture LDAP.

Le dernier utilisateur de Poste verse désormais son résultat après les contrôles finaux. Sa date vient de la source ; une entrée LogonUI sans date reste un historique non daté. L’affectation déclarée garde sa priorité. Sept tests supplémentaires sont écrits et compilés seulement, dont le raccordement de la détection à SQLite, les lots 64+1, les échecs et la perte de retour. Les autres producteurs et l’écran Relations restent à raccorder.

## 13. Identité locale et destinations de navigation (23/10/2026)

Un GUID enregistré dont l’objet n’est pas retrouvé dans l’index produit une identité non vérifiée, pas une suppression AD ni une identité confirmée. Les DN historiques des lignes restent disponibles pour copie/export. Deux champs distincts portent les destinations de navigation : seulement le DN actuel de l’objet retrouvé avec le même GUID. Cela suit les renommages/déplacements et empêche un ancien DN réattribué de conduire à un homonyme.

Les destinations de la relation principale, des connexions récentes et du graphe suivent la même règle. Les menus, boutons et doubles clics ne retombent pas sur le nom quand un GUID connu n’est pas retrouvé. Les associations héritées sans GUID conservent une recherche explicite par nom, annoncée comme historique et non vérifiée ; le nom affiché d’un tiers n’est pas prêté à la ligne. Les lignes du volet du graphe sont reliées par GUID même si leur DN historique diffère désormais.

Trois tests couvrent les identités manquantes, le renommage et les noms réattribués ; compilés uniquement. La compilation C# Debug/Release est sans avertissement ; le parcours visuel et E2E de ces actions reste à exécuter en fin de développement.

## 14. Vues natives locales et index d’identités (23/10/2026)

Le lecteur natif fournit la synthèse, toutes les lignes lues, le sujet, les suggestions/recherches dans l’index, le journal et les observations en attente. Il ne contacte pas LDAP, n’initialise pas la base et ne crée pas de journal à l’ouverture. Les vues disent qu’elles proviennent de la base et de l’index locaux, avec les limites, dates incertaines et lignes écartées du lecteur. Une base d’un autre domaine est refusée avant lecture de son journal. La liste affiche une notice dédiée ; le contexte du sujet conserve cette provenance.

L’index local réutilisé pour un même instantané exclut les GUID/DN dupliqués et les identités hors domaine. Une recherche par GUID manquant ne retombe jamais sur le nom. Les noms ambigus ne choisissent pas arbitrairement le premier compte. Une autorité étrangère et un FQDN non enregistré ne sont pas raccourcis en nom local ; pour les machines, le nom Windows/SAM/DNS prévaut sur un CN de classement.

Plusieurs lignes physiques d’une même association restent visibles, avec des identifiants distincts de grille. Elles sont signalées comme ambiguës et les gestes d’enregistrement/retrait sont désactivés ; le stockage transactionnel les refuse aussi. Le graphe contient au plus 128 voisins directs et 24 du second cercle, avec un avis de vue partielle ; la liste conserve les associations lues. Les observations en attente sont seulement lues, jamais sauvegardées par l’ouverture d’une vue.

Sept tests supplémentaires couvrent l’absence de réseau/écriture, les identités, les doublons, le journal inaccessible, la file, les domaines étrangers et la borne du graphe. Ils sont compilés, pas exécutés. L’interface IRelationsReader n’est pas encore exposée : les lectures réseau explicites, imports et autres méthodes doivent être terminés avant activation de l’écran réel.

## 15. Plans natifs de modification locale (23/10/2026)

Retrait par clé et empreinte affichées, restauration depuis le journal relu et annulation d’un lot importé sont préparés depuis la base locale. Les retraits de lot sont limités à 64 lignes et annoncent le reliquat. Les autres lots et les affectations déclarées sont conservés. Une restauration préserve identités, date et source d’origine ; le stockage verrouillé vérifie encore son droit avant application. Un journal D1 inaccessible empêche la préparation de restauration.

Le circuit appelle une liaison locale facultative après scellement et avant émission du jeton. Le brouillon exact, détenu en mémoire, est associé à l’identifiant et à l’empreinte du plan, avec ses lignes physiques et leurs empreintes brutes. Préparer de nouveau une même modification ne remplace donc pas les préconditions d’une confirmation plus ancienne. Les préparations sont bornées à 64, expirent et sont effacées au changement de session. Aucun champ n’est ajouté au format JSON durable des plans.

La cible technique scelle le domaine et l’identifiant de la base. Une relecture de reçu après redémarrage ne nécessite pas les brouillons et ne peut conclure depuis une autre base. Un retrait ne devient conforme que si la clé est absente, y compris lorsqu’une autre version serait revenue. La voie d’exécution exige toujours la préparation liée et la session correspondante, en plus du jeton à usage unique du circuit. Aucun geste de ce lot ne contacte LDAP.

Sept tests ajoutés : circuit complet avec reçu, concurrence sur colonne D1 invisible, plans non liés/copiés/expirés/ancienne session, relecture sans mémoire et autre base, restauration, lots bornés et doublons. Compilés seulement ; exécution réservée à la recette finale. L’exécuteur ne déclare pas encore le contrat complet IRelationChangeExecutor avant implémentation de ses autres gestes.

## 16. Import natif depuis les fichiers d’inventaire (23/10/2026)

Les trois adaptateurs CSV, GLPI et osquery préparent leur aperçu depuis le fichier choisi et l’index local, sans LDAP. Les limites existantes restent appliquées : texte 8 Mio CSV / 2 Mio JSON, 20 000 enregistrements lus, 1 000 affichés, 64 importables par confirmation. Une base partiellement lisible ne permet pas d’établir les conflits et bloque l’aperçu. L’index peut être incomplet : les identités inconnues ou ambiguës ne sont pas importées, sans les présenter comme supprimées d’AD.

Les identités qualifiées sont résolues intégralement avant normalisation : préfixe UPN différent du SAM accepté seulement par l’UPN exact, DNS par le nom réellement indexé, autorité étrangère refusée. La priorité des lignes utilise ensuite les GUID lorsqu’ils sont connus. Une ancienne association d’un autre GUID utilisateur n’est pas déclarée connue sur le seul login réattribué. La source du format prime toujours sur une colonne Source et les ajouts restent des liens importés, jamais des affectations déclarées.

Le moteur conserve les lignes importables, identifiées par un résultat aléatoire, avec la base précise et la session ; 16 résultats au plus, durée 15 minutes. Le navigateur transmet uniquement cet identifiant au plan. Les identités locales sont relues ; les postes associés depuis l’aperçu sont laissés de côté avec une note. Le stockage revérifie dans sa transaction qu’aucune autre association du poste n’est apparue après le plan. Les restaurations historiques restent distinctes de cette règle d’import.

Une date sans décalage au passage d’heure ambigu ou inexistant ne reçoit plus un instant arbitraire. Les dates futures non admises sont écartées avant sélection du dernier relevé osquery ; une date réelle n’est donc pas supplantée par une date future invalidée ensuite. La date d’import, lorsqu’utilisée, est explicitée dans les détails.

Six tests ajoutés couvrent les identités/alias, les sources, import et annulation, conflits concurrents, expiration/session, limites, dates et trois adaptateurs. Compilés uniquement. La recette native et l’exposition du lecteur complet restent à faire.

## 17. Recherche AD et déclarations natives (23/10/2026)

La recherche manuelle relit le sujet puis interroge le type opposé sur le domaine explicitement choisi : terme de 2 à 128 caractères, métacaractères LDAP échappés, 51 réponses au plus pour afficher 50 et annoncer la limite. Les projections de recherche excluent les appartenances et les secrets. GUID/DN dupliqués, type incorrect, SID étranger, UAC ou identité illisible ne deviennent pas des cibles admissibles. Un contrôleur d’un autre domaine est refusé au RootDSE avant requête d’objet. Le compte sélectionné passe par la même garde de refus d’authentification que les autres lectures LDAP.

La déclaration exige les deux GUID affichés, relit exactement les deux DN et leurs types, puis conserve leurs projections complètes dans l’index ciblé. Une affectation GUID déjà déclarée actualise sa date et son déclarant ; une ligne historique sans GUID reste indépendante. Les autres affectations et observations contradictoires sont conservées et annoncées. Les deux identités sont encore relues au précontrôle et avant l’application locale ; compte renommé, objet déplacé/remplacé ou ancien GUID interdisent l’ajout. Budgets communs de 25 secondes pour recherche/contrôle, 30 secondes pour préparation. Le nom machine provient du SAM/DNS, jamais d’un CN de classement.

Ces gestes lisent AD mais n’y écrivent jamais. Une restauration de journal reste une opération historique locale : pas de réidentification réseau implicite de ses anciens objets. Six tests couvrent préservation/actualisation, GUID remplacés, domaines, filtres et bornes, réponses incohérentes et restauration sans LDAP. Compilés seulement ; recette réelle toujours différée à la fin du développement.

## 18. Contrôle natif des liens non retrouvés et exécuteur complet (23/10/2026)

Le contrôle ignore les affectations déclarées, les imports et les sources protégées avant tout réseau. Les lignes physiques ambiguës sont écartées. Les autres associations sont parcourues par paquets de 64, avec deux recherches filtrées par type : GUID exacts lorsqu’ils existent ; SAM, UPN ou DNS complet pour les liens hérités, sans interpréter une autorité étrangère ni utiliser un CN de classement. Chaque réponse est limitée à 129 objets avec contrôle de cohérence et d’identité ; le budget commun est de 60 secondes. Une réponse tronquée, incohérente ou ambiguë ne prouve aucune absence. Un refus d’authentification arrête la lecture.

Au plus 512 lignes sont proposées à l’examen, sans présélection ; tout reliquat ou délai atteint est annoncé. Les textes distinguent objet non retrouvé avec ce compte, invisibilité possible liée aux droits et renommage possible des anciens liens. Aucun objet n’est déclaré supprimé. Une base partiellement illisible bloque les modifications.

Le plan accepte uniquement des clés présentes dans le contrôle conservé par le moteur, avec empreinte identique et source toujours non protégée. Il relit AD, comme le précontrôle et l’application. Si les objets sont retrouvés ou le contrôle devient non concluant, rien n’est retiré. La suppression reste locale, journalisée et restaurable ; aucune suppression AD.

Les observations de session ou d’un résultat natif conservé peuvent être enregistrées avec le circuit commun : identités qualifiées seulement, 64 par confirmation, aucune ancienne date remplaçant une lecture récente, aucun remplacement des déclarations. Un identifiant ou une clé transmis seul par la page ne fournit jamais de données à écrire. Résultats d’observations bornés à 4 096 lignes et deux millions de caractères, parmi les 16 résultats maximum. Les préparations exécutées sont consommées et libérées, y compris en cas d’échec ; la relecture ultérieure du reçu reste indépendante.

Le contrat natif IRelationChangeExecutor couvre désormais tous ses gestes et participe à la découverte des exécuteurs. Le lecteur IRelationsReader attend encore ses autres méthodes réseau avant exposition complète. Cinq tests de contrôle/nettoyage et trois tests d’observations/découverte ajoutés, compilés uniquement ; recette finale à exécuter après le développement.

## 19. Comparaison native des appartenances visibles (23/10/2026)

Le second compte est résolu exactement par SAM, UPN ou DN dans le domaine courant, avec deux réponses au plus ; une autorité étrangère est refusée avant le premier contact. Les comptes sont relus par identité, sans importer un préfixe UPN comme SAM. Le compte de lecture sélectionné et ses gardes d’authentification servent tout le parcours.

Pour chaque compte, le parcours en largeur lit memberOf et le groupe principal réellement identifié par primaryGroupID et SID du domaine : 10 secondes, 16 niveaux et 2 000 groupes au plus. Un primaryGroupID absent ne devient jamais le RID 513. Les groupes d’autres domaines ne sont pas interrogés. Les recherches groupées contiennent au plus 40 DN et 30 000 octets UTF-8 de clauses, avec une sentinelle ; elles ne demandent jamais les membres des groupes. Les références sont limitées à 10 000 et 4 194 304 caractères normalisés par parcours.

Les plages memberOf sont lues jusqu’à 2 000 valeurs, avec continuité, même GUID et même USN. Une version manquante interdit de réunir une suite de plage non vérifiable ; une version changée refuse la comparaison. Le compte est revérifié après le parcours lorsque son USN est disponible. Un groupe commun déplacé, recréé ou de versions différentes entre les deux lectures n’est pas fusionné. Le même compte relu dans deux versions n’est pas présenté comme deux personnes comparables.

Les appartenances retournées restent des lectures successives, pas une preuve de permissions effectives. Délais, références non lues, limites de volume et groupes principaux inconnus sont conservés dans les limites du résultat et son ticket. Un refus d’accès arrête la comparaison ; il ne devient pas une liste vide. Aucun de ces instantanés partiels n’écrase l’index SQLite. La société réelle est comparée. Les responsables de même libellé sont comparés par DN et départagés visuellement quand leurs noms coïncident.

Six tests couvrent parcours et société, identités, limites de nombre/profondeur/filtres Unicode, versions, plages et délais/refus. Compilés uniquement, sans exécution ni recette AD à ce stade.
