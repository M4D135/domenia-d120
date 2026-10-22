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
| Badges explicables, jamais de pourcentage | `RelationRules.BadgeOf` : Déclaré, Observé, Historique, Importé, Indice, Contradictoire, À vérifier, chacun avec sa règle et sa provenance. |
| Identité par GUID (point 9) | Un lien porteur de GUID n’appartient qu’à cet objet ; même nom autre GUID ou lien antérieur à la création = autre détenteur ; sans GUID = « identité non vérifiable ». |
| Aucune sonde sans geste explicite | Chaque lecture réseau part d’un clic ; la détection montre la liste exacte des postes avant tout contact (D047) ; le domaine entier n’est jamais substitué. |
| Écritures confirmées, journalisées, restaurables | Toute modification du magasin est un **plan** (`relations.*.plan`, une lecture) exécuté par `write.execute` : préconditions relues (empreinte de chaque association, contrôle optimiste REL-012), reçu avant l’envoi, relecture, journal local. Jamais rejoué. |
| 64 changements par enregistrement (REL-011, REL-014) | `WritePlans.MaxChanges` = 64 ; au-delà, refus `relation.tooMany` avant tout plan. Un seul enregistrement à la fois : le canal unique du circuit. |
| Sources protégées (REL-043) | `Manual`, `Saisie manuelle`, `Import CSV`, `Import GLPI`, `Import osquery` : jamais proposées par le contrôle des orphelines, jamais remplacées par une détection. |

## 2. Récapitulatif des opérations

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `relations.overview` | `LocalRead` | aucun | `RelationsOverview` |
| `relations.list` | `LocalRead` | aucun | `RelationList` |
| `relations.subject` | `LocalRead` | `{ ref }` (DN, identifiant ou nom de poste, 2 048 caractères au plus) | `RelationSubjectView` |
| `relations.subjects.search` | `LocalRead` | `{ text }` (100 caractères au plus ; vide = suggestions) | `RelationSubjectMatches` |
| `relations.targets.search` | `NetworkRead` (servie en simulation) | `{ dn, text }` (2 caractères au moins) | `RelationTargetSearch` |
| `relations.detect.collect` | `NetworkRead` (servie) | `{ dn, scope, ouDn, computers, limit, kerberos }` | `RelationDetection` (phase `collect`, avec `plan`) |
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
| `relations.sweep.plan` | `LocalRead` | `{ limit (1..50) }` | `RelationDetectionPlan` (périmètre « sweep ») |
| `relations.associate.plan` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ dn, target }` | `{ plan, token }` (§ 12.1 d’OPERATIONS.md) |
| `relations.remove.plan` | `LocalRead` | `{ key, fingerprint }` | `{ plan, token }` |
| `relations.restore.plan` | `LocalRead` | `{ entry }` (32 hexadécimaux ou `null` = la plus récente) | `{ plan, token }` |
| `relations.import.plan` | `LocalRead` | `{ previewId }` | `{ plan, token }` |
| `relations.import.undo.plan` | `LocalRead` | `{ batch }` (identifiant de lot ou `null` = le plus récent) | `{ plan, token }` |
| `relations.orphans.plan` | `LocalRead` | `{ checkId, keys }` (1 à 64 clés) | `{ plan, token }` |
| `relations.observations.plan` | `LocalRead` | `{ resultId, keys }` (0 à 64 clés ; 0 = toutes, 64 au plus) | `{ plan, token }` |

Identifiants (`planId`, `estimateId`, `id`, `previewId`, `checkId`, `resultId`, `entry`) : 32 caractères hexadécimaux
minuscules ; sinon `arguments.invalid` (« « planId » doit être un identifiant de 32 caractères hexadécimaux. »).
`resultId` = 32 zéros désigne les observations de la session non encore enregistrées (lignes « Session uniquement »).
Les résultats gardés par le moteur (périmètres, observations, aperçus, contrôles, estimations) valent 15 minutes ; au-delà
`relation.expired` ou `relation.planExpired`.

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
`date`, `label`, `observed`, `history`), `journalEntries`, `summary`.

### 3.3 `relations.subject`

`subject` (`kind`, `dn`, `guid`, `name`, `login`, `detail`, `path`, `enabled`, `lastLogon`, `created`), `direction`
(libellés D041 : « Associer ce poste », « Détecter les postes » / « Lire la session de ce poste »…), `overview` (lignes
« Affectation déclarée », « Dernière session observée », « Historique », « Autres indices » avec badge), `primary`
(poste ou utilisateur principal : affectation déclarée, sinon relation la plus récente, avec sa raison) ou `null`,
`associations` (`RelationRow`, liens de son GUID ou liens hérités de son nom non antérieurs à sa création),
`logons` (30 au plus : sessions observées, à distance, relevés d’historique et `lastLogonTimestamp`), `graph`
(`nodes` : `id`, `kind`, `label`, `sub`, `dn`, `depth` 0 à 2, `primary`, `exists`, `tone`, `links` ; `edges` : `from`, `to`,
`badge` le plus fort, `count`, `when`, `contradicted`, `label` ; `truncated` quand le deuxième cercle est borné à
24 nœuds, 5 par nœud), `counts`, `context`, `restore`. Erreur propre : `relation.unknown`.

### 3.4 Détection (`relations.detect.*`)

1. `collect` (geste « Lire l’annuaire ») : compte relu, associations connues (50 au plus), postes dont il est `managedBy`,
   postes qui le mentionnent (description, emplacement), indices Kerberos 4768 sur 7 jours si `kerberos` (adresses,
   jamais associées). Périmètre `scope` : `candidates` (postes connus et candidats AD), `ou` (`ouDn`, l’OU de travail par
   défaut, jamais la racine), `loaded` (`computers` : 50 DN au plus, liste chargée d’un autre écran). Réponse : `attempts`
   (`method`, `status` OK/VIDE/A_REVOIR/CONFIRME/LU/REFUSE/AUTH_REJETEE/DELAI/ERREUR/NON_DEMANDE…, `statusLabel`, `tone`,
   `target`, `detail`, `durationMs`, `resource`), `candidates` (`origins`, `why`, `associable`, `blocker` : une adresse ou
   un nom partiel n’est jamais associable), `hints`, `plan` (`id`, `allowed`, `scopeLabel`, `limit`, `eligible`,
   `truncated`, `targets`, `text`, `reason`, `zeroMeaning`). Aucun poste contacté.
2. `run` (geste « Lancer la détection ») : lecture de la console (Win32_ComputerSystem, CIM/DCOM, 4 s) des **seules** cibles
   du plan confirmé, une détection à la fois (`relation.probeBusy`). Chaque poste pousse `relations.detect.run:progress`
   (`planId`, `counters`, `computer`, `status`, `statusLabel`, `tone`, `currentUser`). Le résultat dit `within` (liste
   sondée incluse dans le plan), `complete`, `counters` (`planned`, `queried`, `confirmed`, `noSession`, `refused`,
   `unreachable`, `stopped`, `text`), `savable` et `resultId` (observations gardées pour
   `relations.observations.plan`). Les consoles confirmées sont visibles « Session uniquement » jusqu’à leur plan.
3. `stop` : arrêt demandé, pas une annulation confirmée ; le poste en cours se termine, résultat partiel déclaré.

### 3.5 Autres lectures

- `relations.computer.read` : `observed` (`account`, `login`, `userDn`, `userGuid`, `userName`, `match`, `certain`,
  `reason` du contrôle d’identité D049, `source`, `kind`, `badge`, `observedAt`) ou `null`, `savable`, `resultId`.
- `relations.harvest.estimate` puis `relations.harvest.run` : couples (`key`, `userLogin`, `computer`, `firstSeen`,
  `lastSeen`, `events`, `eventIds`, `known`), `events`, `truncated`, `machineAccountsIgnored`, `unresolved`, `resultId`.
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
  `readAt`. Erreurs : `relation.notAUser`, `relation.compareUnresolved` (second compte introuvable, d’un autre domaine ou
  ambigu, avec la raison).

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
| `write.targetUnknown`, `write.stale`, `write.nothingToDo` | Codes du circuit : association introuvable, modifiée ailleurs depuis son affichage, rien à écrire. |

## 5. Simulation

`SimulatedRelationsReader` et `SimulatedRelationChangeExecutor` partagent `SimulatedRelationState` (un par source simulée,
mémoire seulement). Le magasin initial est dérivé du monde généré par le sous-flux `screen/relations`
(`SimulatedRelationSeed`) : environ 45 % des postes actifs avec une affectation déclarée, 58 % avec une console observée
dans les 14 derniers jours dont **exactement 9 postes contradictoires** (Camille Bernard comprise), 48 % avec un relevé
d’historique, un lot d’import GLPI de 24 lignes daté de six jours (« Annuler l’import »), 10 indices WAPT, 12 sessions
distantes de comptes d’administration sur les serveurs, 14 lignes héritées sans GUID (2 pour un nom de poste recyclé),
11 associations orphelines et 3 affectations déclarées sans objet (protégées). Julien Martin (`j.martin`, compte de la
session) a un poste principal déclaré observé il y a 47 minutes, un portable observé hier, des relevés anciens et un
collègue relevé sur son poste. Le journal contient l’import, des déclarations récentes, une suppression restaurable et une
suppression déjà restaurée. Les lectures réseau répondent de façon déterministe : consoles d’après la présence relevée et le
magasin (refus 5 %, aucun compte 19 %), indices Kerberos par utilisateur, couples de moisson par poste. Délais
`latency/screen/relations/…` et `latency/screen/write/relations/…`, aucun avec `SimulationLatency.None`.

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
| Relevé incrémentiel (REL-031) | Console des postes de l’OU de travail, jamais relevés puis plus anciens ; poste non réauthentifié (`lastLogonTimestamp`) depuis son relevé non redemandé ; ping par lots avant la session | 50 postes par relevé, budget, report au relevé suivant |

### 6.4 Budgets et classes

`relations.targets.search`, `relations.detect.collect`, `relations.orphans.check`, `relations.compare` et
`relations.associate.plan` sont des lectures réseau après un geste ; `relations.detect.run`, `relations.computer.read`,
`relations.harvest.run` contactent des postes ou le journal du contrôleur, bornés comme ci-dessus. Aucune n’est lancée par
l’affichage d’une page, un défilement ou un rendu (D048). Les durées et volumes sont tracés dans le journal technique
(codes et nombres seulement, jamais un nom, un DN ou une adresse).

## 7. Page

`web/js/pages/relations.js` et `web/js/pages/relations/*.js` (`model`, `graph`, `subject`, `all`, `compare`, `journal`,
`panels`), feuille `web/css/pages/relations.css` (toutes les règles sous `[data-page="relations"]`, y compris le contenu
des panneaux, qui porte `data-page="relations"`). Paramètres d’adresse : `onglet`, `sujet`, `vue`, `panneau`, `a`, `b`
(en-tête de `relations.js`). Les écritures passent toutes par `runWrite` (`web/js/write-flow.js`). L’aperçu dans un
navigateur (`mock.js`) ne sert pas encore ces opérations (fichier partagé non modifié) : la page y affiche ses erreurs.

### 7.1 Reste à faire (statut `docs/status/relations.json`)

- REL-013 : lecture et migration de la table SQLite `user_machine_links` de Domenia 1 (mode annuaire, § 6.1).
- REL-029 : demande d’un autre compte pour la ressource refusée ; l’écran Accès n’existe pas encore. La détection
  et le relevé comptent et disent les refus, sans jamais les rejouer.
- REL-031 : « Oublier les relevés » après sauvegarde vérifiée, ping par lots avant session (mode annuaire).
- REL-047 : réinitialisation pendant l’affichage sur un changement de session (événement du pont à venir).
- FIC-004 : attribut `company` (Société), absent du modèle d’annuaire de Domenia 2.

## 8. Tests écrits (exécutés à la fin, dans la VM)

`tests/Domenia.Tests/RelationsTests.cs` : règles (nature, clés, égalité, upsert, principal, badges, contradictions,
synthèse, identité, sources protégées, orphelines, filtre, états de l’association, identité de compte, candidats,
périmètre, compteurs), import (CSV, GLPI, osquery, identité, dates, priorité, lot, statuts), comparaison (groupes directs,
imbriqués, principal, boucles, privilèges, ticket), projection, pont (formes JSON, arguments, admission, classes), circuit
(association, retrait, restauration, import et annulation, orphelines, observations : reçu `applied`/`verified`, journal,
contrôle optimiste, plan exécuté une fois). Scénarios E2E : `tests/e2e/relations/*.json`.
