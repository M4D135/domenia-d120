# Domenia 2 — écran Assistance : opérations du pont

Écran `assistance` (`#/assistance`), lot VM `assistance`. Il porte les **parcours d’assistance guidés** de Domenia 1
(`Domenia-Assistance.Model.ps1`, `.UI.ps1`, `.xaml`) et l’**atelier de support** (`Domenia-Support.*`, `Domenia-Insight`,
`Domenia-Dossier`, `Domenia-Automation` pour le dossier hors ligne), avec des améliorations. Rédigé le 22 octobre 2026, repris le même jour après la critique (tour 1) ;
tests écrits, non exécutés (décision de David du 21/10 : à la toute fin) ; compilation Debug vérifiée dans la VM,
0 avertissement.

Le contrat commun (enveloppe, règles JSON, classes, admission) est celui de [`OPERATIONS.md`](../OPERATIONS.md) § 1 ;
l’organisation du moteur est dans [`PLATFORM.md`](../PLATFORM.md). Toutes les opérations de ce document sont dans le module
`Domenia.Bridge/Operations/AssistanceOperations.cs` ; les règles pures et les services de l’écran (atelier, ordonnanceur,
documents, dossier hors ligne) dans `Domenia.Core/Screens/Assistance/` ; la simulation dans
`Domenia.Simulation/Screens/SimulatedAssistanceReader.cs` et `SimulatedAssistanceSteps.cs` ; les fichiers par
`EngineContext.Documents` (`Domenia.Store/Documents/FileDocumentStore.cs`) ; la commande en ligne dans
`Domenia.App/DossierCommandLine.cs`.

## 1. Fonctions couvertes

| Id | Fonction de Domenia 1 | Dans Domenia 2 |
|---|---|---|
| ASS-013 | Recettes guidées (4 parcours, plan avant le premier clic) | 7 recettes (4 de Domenia 1 + impression, lecteur réseau, accès distant), plan au pluriel juste, contrat validé (`AssistanceRecipes`) |
| ASS-014 | Grille des étapes (N°, étape, pour, lu, pourquoi, coût, état) | stepper animé ; **résultat résumé de la lecture dans la ligne** (amélioration demandée) |
| ASS-015 | Lancer une étape (liste fermée, marquée seulement si la lecture part) | `assistance.step.run` ; lot des lectures sans droits d’administration, avec budget confirmé (amélioration demandée) |
| ASS-016 | Ouvrir la vue d’une étape | contrat d’adresse écrit ([`KIT.md`](../KIT.md) § 3.1) : Fiche `tab=compte`, Poste `onglet=…`, Audit AD `tab=objet&vue=motdepasse|poste|groupes|gpo` (les onglets internes que Domenia 1 ouvrait) ; une vue absente de la version est dite, jamais devinée |
| ASS-003 | Comprendre la fiche (constats) | `assistance.subject.read` / `analyse` ; règles machines ajoutées (LAPS absent ou expiré, poste muet, disque, démarrage, compte inactif) |
| ASS-004 | Capture filtrée et masquée (liste blanche) | `SupportSnapshots` (29 attributs, comme le code de Domenia 1 ; le catalogue en annonce 30) |
| ASS-005 | Comparer A et B | `assistance.capture.*`, comparaison toujours recalculée ; vue « Différences et inconnues » |
| ASS-001 | Captures historiques : enregistrer, charger | `assistance.capture.export` (fichier daté, jamais remplacé), `assistance.capture.import` (fichier choisi dans la page, contrôlé par le moteur) ; fichiers interchangeables avec Domenia 1 |
| ASS-006 | Incidents expliqués de la session | journal des opérations de la session + incidents de la source, règles fixes (10 dont « lecture refusée », ajoutée), lien vers l’écran concerné |
| ASS-007 | Repères de session (24 fiches) | `assistance.pin.*` ; **retrouvés par GUID** même déplacés (amélioration demandée) ; « Ouvrir la fiche » (bouton ou double clic) ouvre l’écran Fiche avec ses lectures habituelles, « Reprendre ici » en fait le sujet de l’assistance ; repère d’un autre périmètre refusé |
| ASS-008 | Dossier support et ticket | `assistance.report.preview` ; gabarits GLPI et ServiceNow, pseudonymes à clé (améliorations demandées) |
| ASS-009 | Export HTML autonome | `assistance.report.export` ; style épinglé par son SHA-256 (plus de `unsafe-inline`), empreinte du texte en pied (amélioration) |
| ASS-002 | Compte rendu de ticket pseudonymisé (sans appelant en Domenia 1) | **câblé** : `assistance.ticket.preview` / `export`, alimenté par les étapes lancées et les reçus d’écriture de l’objet |
| ASS-010 | Raccourcis (comptes, état du moteur) | rail : « État du moteur » (`assistance.engine.state`, sans sonde : lectures de l’Assistance en cours et en attente par l’ordonnanceur, mêmes incidents que la vue Incidents, capacités dites en français), « Voir les comptes » ; lectures en cours aussi dans le rail |
| ASS-011 | Vider l’atelier | `assistance.workshop.reset`, après confirmation |
| ASS-012 | Dossier de diagnostic hors ligne | `assistance.dossier.prepare` (manifeste et SHA-256), cinq périmètres (poste, OU de travail, **OU choisie dans l’arborescence**, postes épinglés, **liste de postes** collée, 500 au plus), confirmation avant l’écriture, « Ouvrir le dossier » ensuite, réponse d’une autre session ignorée, nom daté à l’heure locale, tailles en octets ; **commande en ligne** `Domenia.exe dossier` (§ 6.1) et son équivalent affiché sur l’écran |
| TRV-184 | Contrat de validation des recettes | `AssistanceRecipes.Validate`, appliqué au premier usage (refus `assistance.recipesInvalid`) |
| TRV-185 | Isolation de l’atelier par session | clé domaine + compte + **génération de connexion** (`SessionSnapshot.Epoch`, [`PLATFORM.md`](../PLATFORM.md) § 3.3 bis) : une reconnexion avec le même compte vide aussi l’atelier ; empreinte `session` donnée à la page, qui oublie alors sa propre mémoire ; relevé de l’atelier chaque seconde tant que l’écran est affiché (`assistance.workshop.poll`) |

## 2. Récapitulatif

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `assistance.overview` | `Local` | aucun | recettes (sans sujet), atelier, limites, lecteur disponible, documents persistants |
| `assistance.recipes` | `Local` | `{ user, computer }` (DN ou `null`) | recettes avec l’état de chaque étape |
| `assistance.subjects.search` | `LocalRead` | `{ text }` (100 caractères au plus) | 20 comptes ou postes au plus |
| `assistance.subjects.suggest` | `LocalRead` | aucun | comptes et postes à examiner, avec la raison |
| `assistance.computers.resolve` | `LocalRead` | `{ names }` (500 au plus) | postes nommés exactement, noms inconnus |
| `assistance.subject.read` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ dn }` | carte, capture, constats, couverture |
| `assistance.subject.analyse` | `Local` | `{ dn }` | constats recalculés sur la dernière lecture |
| `assistance.step.run` | `NetworkRead`, servie en simulation | `{ recipe, step, dn }` | l’étape après sa lecture, progression |
| `assistance.workshop.get` | `Local` | aucun | atelier (captures, comparaison, repères, incidents) |
| `assistance.workshop.poll` | `Local` | aucun | `{ revision, session, incidents, running, queued }` |
| `assistance.workshop.reset` | `Local` | aucun | atelier vidé |
| `assistance.capture.take` | `Local` | `{ slot, dn }` | atelier |
| `assistance.capture.swap` | `Local` | aucun | atelier |
| `assistance.capture.clear` | `Local` | `{ slot }` (`a`, `b` ou `null`) | atelier |
| `assistance.capture.export` | `LocalWrite` | `{ slot }` | document enregistré (ou gardé en mémoire) |
| `assistance.capture.import` | `Local` | `{ slot, content }` | atelier |
| `assistance.pin.add` | `Local` | `{ dn }` | atelier |
| `assistance.pin.remove` | `Local` | `{ identity }` | atelier |
| `assistance.pin.locate` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ identity }` | DN actuel, déplacé ou non |
| `assistance.incidents.clear` | `Local` | aucun | atelier |
| `assistance.report.preview` | `Local` | `{ dn, ticket, template, incident, pseudonymize, key }` | aperçu du dossier support |
| `assistance.report.export` | `LocalWrite` | idem | document HTML |
| `assistance.ticket.preview` | `Local` | `{ dn, sections, pseudonymize, key }` | aperçu du compte rendu |
| `assistance.ticket.export` | `LocalWrite` | idem | document texte |
| `assistance.dossier.prepare` | `LocalWrite` | `{ scope, dn, ou, names, sections }` | dossier hors ligne |
| `assistance.document.reveal` | `LocalRead` | `{ name }` | `true` : document de la session montré dans l’Explorateur |
| `assistance.engine.state` | `Local` | aucun | état du moteur, sans sonde |

27 opérations, aucune de classe `Write` : l’écran n’écrit jamais dans l’annuaire. Les seules écritures sont les documents
demandés par l’opérateur, dans le dossier des exports de l’application (§ 7, classe `LocalWrite` des données locales,
[`OPERATIONS.md`](../OPERATIONS.md) § 1.3).

## 3. Recettes et étapes

### 3.1 Recette (`RecipeView`)

| Champ | Contenu |
|---|---|
| `id`, `title`, `symptom`, `icon` | identifiant stable (`logon`, `slow`, `disk`, `software`, `printer`, `drive`, `remote`), titre, symptôme, icône |
| `added` | `true` pour les recettes ajoutées par Domenia 2 |
| `plan` | ce que la recette lirait en entier, dit avant le premier clic sous le titre « Avant le premier clic » (« 6 étapes, dont 2 lectures pour le compte, 3 pour le poste et 1 sans lecture. 2 demandent les droits d’administration du poste. 1 étape facultative. Aucune étape ne part seule ; aucune n’écrit. ») ; un seul deux-points, chaque nombre lié à son nom par une espace insécable |
| `steps`, `userReads`, `computerReads`, `privileged`, `optional`, `done` | nombres ; `done` = étapes lues pour les sujets donnés |
| `stepList` | étapes (§ 3.2) |

### 3.2 Étape (`StepView`)

`order`, `id`, `title`, `subject` (`user` ou `computer`), `subjectLabel` (« Utilisateur », « Poste »), `action` (identifiant de la
liste fermée, ou `null` : étape sans lecture), `actionLabel`, `operation` (opération épinglée de Domenia 1 :
`LockoutDiagnosis`, `PasswordPolicyRead`, `GroupPathRead`, `GpoLinksRead`, `GpoAppliedRead`, `MachineIdentityRead`,
`ComputerDiagnostics`, `ComputerInventory`, `SoftwareInventory`, `SessionsList`), `view` (`screen`, `section`, `label`),
`reads`, `why`, `cost`, `optional`, `privileged`, `state`, `reading`, `error`.

`state` : `phase` (`needSubject`, `viewOnly`, `ready`, `read`, `refused`, `failed`), `canRun`, `canOpen`, `text`, `tone`, `at`.

| Phase | Texte |
|---|---|
| `needSubject` | « Sélectionnez le compte concerné. » / « Sélectionnez le poste concerné. » |
| `viewOnly` | « Sans lecture : ouvrir la vue » |
| `ready` | « À lancer » |
| `read` | « Lue à HH:mm : résultat ci-dessous » (ton `info` : une lecture n’est jamais un succès) |
| `refused` | « Refusée à HH:mm : rien n’a été lu » |
| `failed` | « Échec à HH:mm : rien n’est relancé seul » |

`reading` (`StepReading`) : `action`, `operation`, `label`, `readAt`, `tone`, `summary` (une phrase), `facts`
(`label`, `value`, `tone`), `items` (`title`, `detail`, `tone`, 8 à 12 affichés), `more` (éléments non affichés), `limit`
(ce que la lecture ne prouve pas).

### 3.3 `assistance.step.run`

- Contrôles, dans l’ordre : recette connue (`assistance.recipeUnknown`), étape connue de cette recette
  (`assistance.stepUnknown`), étape avec lecture (`assistance.stepWithoutRead`), DN valide, lecteur du mode
  (`source.unavailable`), objet trouvé (`assistance.subjectUnknown`), type d’objet admis par l’étape et par la lecture
  (`assistance.subjectMismatch`). **La lecture vient de la liste fermée de la recette, jamais de la page.**
- La lecture se termine par `read`, `refused` (`assistance.readRefused` : la cible refuse le compte de la session) ou
  `failed` (`assistance.readFailed` : cible muette, RPC, DNS, délai). Un refus ou un échec est enregistré dans l’étape, écrit au
  journal des opérations (ton `warn`, donc expliqué dans les incidents) et **jamais relancé** ; l’opérateur peut relancer
  d’un nouveau clic. Une annulation (fermeture) ne marque rien.
- Résultat : `{ recipe, step, done, total }` (`done` et `total` : lectures de ce type d’objet dans la recette).
- Les marques sont propres à la session et au DN de l’objet (Domenia 1 : session, DN, recette, étape).

## 4. Sujets de l’assistance

- `assistance.subjects.search { text }` : comptes et postes dont l’identifiant, le nom, le nom affiché, l’UPN, l’adresse ou le
  nom DNS contient le texte (accents et casse ignorés) ; identifiant exact d’abord, puis début de nom, puis ailleurs ;
  20 au plus. Ligne : `dn`, `kind`, `name`, `login`, `detail`, `path`, `tone`, `stateLabel`.
- `assistance.subjects.suggest` : comptes verrouillés, mot de passe expiré, changement exigé ; postes de l’OU de travail au
  disque presque plein, muets au dernier relevé ou sans redémarrage depuis plus de 30 jours (`subject`, `reason`).
- `assistance.subject.read { dn }` : lecture fraîche (geste de l’opérateur), mémorisée par l’atelier pour les captures et les
  repères. Résultat `SubjectView` :
  - `card` : `dn`, `guid`, `kind`, `kindLabel`, `name`, `login`, `path`, `facts` (état, mot de passe, dernière connexion,
    échecs, service, fonction ; ou présence, système, modèle, disque, LAPS — date seulement —, dernier démarrage), `pills`,
    `related` (poste dont le compte est responsable, ou responsable du poste : `managedBy`), `relatedLabel`, `readAt` ;
  - `snapshot` : la capture (§ 5.1) ; `findings` : constats (§ 5.2) ; `coverage` : fournis, partiels, non fournis, total,
    source, date de lecture, phrase.
- `assistance.subject.analyse { dn }` : mêmes champs, constats recalculés à l’heure actuelle sur la même lecture
  (`assistance.notRead` si l’objet n’a pas été lu dans l’Assistance).

## 5. Atelier

### 5.1 Capture (`SupportSnapshot`, format 1)

`format`, `id`, `identity` (`guid:…` ou `dn:…`), `scope` (racine du domaine en minuscules), `dn`, `name`, `kind`, `kindLabel`,
`source` (`live`, `cache`, `unknown`), `observedAt`, `capturedAt`, `fields` (`name`, `coverage` `provided|partial|notProvided`,
`values`), `fieldCount`. Liste blanche positive de 29 attributs (code de Domenia 1) ; valeur bornée à 1 024 caractères,
128 valeurs au plus ; mots de passe, jetons, `Bearer` et clés de récupération masqués ; `memberOf` découpé ou incomplet :
partiel.

### 5.2 Constats

`code`, `level` (`attention`, `toCheck`, `undetermined`, `information`), `levelLabel`, `tone`, `title`, `evidence`, `next`,
`basis` (`observation`, `coverage`, `limit`), `basisLabel`. Règles de Domenia 1 (`DATA_NOT_LIVE`, `DATA_OLD`, `UAC_UNKNOWN`,
`ACCOUNT_DISABLED`, `ACCOUNT_LOCKED`, `PASSWORD_EXPIRED`, `LOCKOUT_HISTORY`, `PASSWORD_CHANGE_REQUIRED`,
`PASSWORD_STATE_REVIEW`, `PASSWORD_NO_EXPIRY`, `ACCOUNT_EXPIRED`, `ACCOUNT_EXPIRING`, `EXPIRY_INVALID`, `DNS_NOT_PROVIDED`,
`ADMINCOUNT`, `PARTIAL_CAPTURE`, `NO_FINDING`) et règles machines de Domenia 2 (`LAPS_ABSENT`, `LAPS_EXPIRED`, `NO_ANSWER`,
`DISK_LOW`, `DISK_TIGHT`, `UPTIME_LONG`, `COMPUTER_STALE`), calculées sur des signaux tenus hors de la capture (aucune donnée
LAPS ne part dans un export, seule la conclusion).

### 5.3 Atelier (`WorkshopView`)

`a`, `b` (`slot`, `name`, `kind`, `kindLabel`, `dn`, `identity`, `source`, `sourceLabel`, `observedAt`, `capturedAt`,
`fieldCount`, `historical`), `comparison` (`ready`, `sameObject`, `summary`, `refusal`, `different`, `undetermined`,
`identical`, `rows` : `attribute`, `status`, `statusLabel`, `tone`, `before`, `after`, `added`, `removed`), `pins`
(`identity`, `name`, `kind`, `kindLabel`, `dn`, `scope`, `pinnedAt`), `pinLimit` (24), `incidents` (`total`, `limit` 200,
`summary`, `items` du plus récent au plus ancien : `id`, `at`, `level`, `levelLabel`, `tone`, `area`, `title`, `codes`,
`hints` — `code`, `title`, `evidence`, `next`, `route`, `routeLabel` —, `detail`, `source`), `revision`, `summary`,
`session` (empreinte de la session de l’atelier : 16 hexadécimaux, rien de lisible ; la page oublie sa mémoire quand elle
change).

- `capture.take` fige la **dernière lecture** de l’objet (aucune nouvelle lecture) ; `notRead` sinon.
- Comparaison refusée (dite dans `refusal`) si le domaine ou le type d’objet diffère ; un attribut absent ou partiel est
  `undetermined`, jamais une suppression ; `memberOf` : groupes directs, casse et ordre ignorés.
- `capture.import { slot, content }` : contenu d’un fichier choisi par l’opérateur (lu localement par la page), contrôlé par
  le moteur : format `Domenia.Capture.1`, capture de format 1, **même domaine**, dates lisibles et non futures (5 min de
  tolérance), liste blanche, 128 valeurs ; couverture non fournie = partielle ; source `cache` (`historical` = `true`). Refus
  `assistance.captureInvalid` avec une raison fixe, sans jamais recopier le fichier.
- Repères : 24 au plus (`assistance.pinsFull`), sans doublon d’identité (un nouvel épinglage remplace l’ancien), refus d’un
  repère d’un autre périmètre (`assistance.pinOtherScope`) ; `pin.locate` retrouve l’objet par son GUID et dit s’il a été
  déplacé (`moved`, `message`).
- Incidents : avertissements et erreurs du journal des opérations de la session, et une fois ceux que la source a enregistrés
  (simulation : journal fictif et incidents réalistes). Expressions fixes, délai de 100 ms, texte borné à 8 192 caractères,
  doublon adjacent de moins de 2 s ignoré, 200 au plus. `detail` (message local nettoyé) n’est jamais repris dans un document.

## 6. Documents

- `report.preview` / `report.export` : `dn` (fiche du dossier, lue dans l’Assistance, ou `null`), `ticket` (référence,
  filtrée et bornée à 80 caractères), `template` (`text`, `glpi`, `servicenow`), `incident` (identifiant d’un incident de
  l’atelier : seules ses explications sont reprises), `pseudonymize` et `key`. La comparaison A / B est incluse dès que A et B
  sont capturés. Aperçu : `kind` (`support`), `ready`, `reason`, `text`, `sha256` (du texte), `lines`, `characters`,
  `pseudonymized`, `map` (table de correspondance, **jamais dans le texte**), `counts`, `excluded`.
- `ticket.preview` / `ticket.export` : compte rendu `DomeniaTicket/1` d’un objet identifié par son GUID : étapes des recettes
  lancées pour lui (`Confirmé` pour une lecture aboutie, `Refusé`, `Tenté` avec issue pour un échec), étapes non lancées de ces
  recettes (`Non testé`), reçus d’écriture de l’objet (vérifié = confirmé ; envoyé ou issue inconnue = tenté, « Envoyé, issue
  non confirmée » ; non appliqué = refusé). Sections au choix (`context`, `attempted`, `confirmed`, `refused`, `notTested`,
  `limits`). Refusé sans GUID, ou avec pseudonymisation sans clé de 8 caractères : **aucun aperçu en clair à la place**.
- Pseudonymes : HMAC-SHA256 sous la clé de l’opérateur, famille + 8 hexadécimaux (`Utilisateur-1A2B3C4D`), casse ignorée ; la
  clé n’est ni gardée, ni journalisée, ni renvoyée (`assistance.keyMissing` si elle manque). Sont remplacés : le sujet et les
  captures (nom, identifiant, UPN, adresse, nom DNS, GUID, compte machine avec et sans `$`), les objets que leurs DN citent
  (manager et responsable `managedBy` : famille Utilisateur ; groupes de `memberOf` : famille Groupe), les postes, contrôleurs,
  groupes et comptes cités par les lectures d’étapes (compte rendu), puis, en dernier filet, toute valeur `CN=…` restée en
  clair (famille Objet, `Pseudonyms.MaskRemainingNames`). Les incidents ne citent que leurs règles fixes : leur message brut
  n’entre jamais dans un document.
- `dossier.prepare { scope, dn, ou, names, sections }` : `scope` = `subject` (poste de la session, `dn`), `workingOu` (OU de
  travail, jamais la racine), `branch` (`ou` : une OU choisie dans l’arborescence, connue de l’index local des OU, jamais la
  racine ni une OU d’un autre domaine — Domenia 1 « OU sélectionnée »), `pins` (postes épinglés) ou `list` (`names` : noms
  de postes collés, correspondance exacte du nom, du compte avec ou sans `$` ou du nom DNS, jamais partielle — Domenia 1
  « postes des résultats affichés ») ; 500 postes au plus ; sections facultatives `observations`, `associations`,
  `requetes` (`etat` et `postes` toujours). Un dossier à la fois (`assistance.dossierBusy`), 300 s au plus
  (`assistance.dossierTimeout`), 64 Mio de texte au plus (`assistance.dossierTooLarge`). Si la session change pendant la
  préparation, la réponse est ignorée et rien n’est écrit (`assistance.sessionChanged`, Domenia 1
  `Test-DomeniaOfflineDossierState`). Fichiers : une enveloppe `Domenia.Automation/1` par section, `LISEZMOI.txt`,
  `manifeste.json` (`Domenia.OfflineDossier/1`, tailles en caractères et en octets), `SHA256SUMS.txt` (empreintes des octets
  UTF-8 sans BOM, celles de `Get-FileHash`) ; champs nommés comme des secrets retirés et listés. Dossier nommé
  `Domenia-Diagnostic-<poste|OU|N-postes>-AAAAMMJJ-HHmm` à l’heure locale. Résultat : `saved`, `path`, `name`, `perimeter`,
  `truncated`, `unresolved` (noms inconnus ignorés), `sections`, `files` (`name`, `sha256`, `bytes`, `size` lisible :
  « 834 octets », « 12,4 Kio »), `excluded`, `message`, `createdAt`. La page demande une confirmation (périmètre, sections,
  exclusions, destination) puis propose « Ouvrir le dossier » (`document.reveal`).
- `computers.resolve { names }` : les postes que l’index local connaît exactement pour ces noms, une fois chacun, et les noms
  inconnus (`found`, `unknown`, `names`, `truncated`) ; aucune lecture réseau.

### 6.1 Commande en ligne (`Domenia.exe dossier`)

Équivalent de `Domenia-Automate.ps1 dossier` de Domenia 1 : écrit le même dossier sans ouvrir la fenêtre ni WebView2.

```text
Domenia.exe dossier --sortie <dossier local> (--ou <DN> | --postes PC-01,PC-02 | --guids <GUID>,…) [--sections observations,associations,requetes] [--simulation]
```

- Noms de Domenia 1 acceptés : `-OutputPath`, `-OrganizationalUnit`, `-Computers`, `-Guids`, `-Sections` ; `-DatabasePath`
  (base de Domenia 1) est refusé (code 3).
- Un seul périmètre, jamais tout le domaine, 500 postes au plus ; sans `--sections`, toutes les sections facultatives
  (`--sections etat,postes` n’en écrit aucune). Noms de postes nettoyés (domaine et `$` retirés), GUID vérifiés.
- Le dossier de sortie doit exister, être local et sans lien : partage UNC, lecteur réseau ou lien refusés
  (`FileDocumentStore.CheckLocalFolder`, Domenia 1 `Test-DomeniaAutomationLocalPath`).
- Lecture de l’index local du mode seulement (`IAssistanceIndex`), comme l’écran ; en mode annuaire, tant que la base locale
  n’est pas branchée : code 3.
- Résumé en UTF-8 sur la sortie standard (message, chemin, empreinte et taille de chaque fichier). Codes de sortie de
  Domenia 1 : 0 réussi, 2 commande ou paramètre invalide, 3 base locale indisponible, 4 refus (périmètre), 5 non écrit.
- L’écran « Dossier hors ligne » affiche la commande équivalente au périmètre choisi, prête à copier.

## 7. Dossier des exports

- Service de la plateforme `EngineContext.Documents` (`IDocumentStore`, [`PLATFORM.md`](../PLATFORM.md) § 3.3) :
  `FileDocumentStore` (`Domenia.Store`) sur `%LOCALAPPDATA%\Domenia\Exports` (mode annuaire) ou `Exports-simulation`
  (simulation), chemin donné par `AppPaths.Exports` et la composition, jamais partagés ; `MemoryDocumentStore` en capture, en
  E2E ou sans dossier de données. Le pont ne touche jamais le disque : `AssistanceDocuments` (Core) garde les règles de
  l’écran.
- Noms datés à l’heure locale : `Domenia-Capture-A-AAAAMMJJ-HHmmss.json`, `Domenia-Support-AAAAMMJJ-HHmmss.html`,
  `Domenia-Ticket-…txt`, `Domenia-Diagnostic-<sujet>-AAAAMMJJ-HHmm\`. **Rien n’est jamais remplacé** : un nom pris reçoit
  `-2`, `-3`… Les dates écrites dans les documents ont toutes la même forme : « 22/10/2026 03:19:12 (UTC+02:00) ».
- Écriture atomique : fichier temporaire du même dossier (écriture directe, vidé sur le disque) puis renommage ; dossier
  temporaire puis renommage ; un dossier des exports qui est un lien est refusé ; un échec ne laisse ni fichier partiel ni
  dossier final (`assistance.exportFailed`). 1 Mio au plus par document (`assistance.exportTooLarge`).
- **Un document à la fois** (`assistance.documentBusy`, Domenia 1 ASS-001), **30 s au plus** par écriture
  (`assistance.documentTimeout`) ; le dossier hors ligne a sa propre garde (un à la fois, 300 s).
- Mode capture, mode E2E ou pas de dossier de données : **rien n’est écrit**, le résultat le dit (`saved` = `false`) et garde
  l’empreinte.
- `document.reveal { name }` montre dans l’Explorateur Windows un document **écrit pendant cette session** (fichier
  sélectionné ou dossier ouvert, sans shell) ; tout autre nom, un document disparu ou un lien : `assistance.exportMissing`.

## 8. Simulation

`SimulatedAssistanceReader` lit l’annuaire tel que la session le voit (`CurrentDirectory`, écritures de la surcouche
comprises) et les relevés (`ReadLocalAsync`). Ce que le monde généré ne contient pas vient du sous-flux
`screen/assistance`, une branche par lecture et par objet (`step/<action>/<guid>`) : mêmes réponses pour la même graine.

| Lecture | Données |
|---|---|
| verrouillages | 3 à 6 événements pour un compte verrouillé (le plus récent à son `lockoutTime`), postes de son site, émulateur PDC |
| stratégie | stratégie du domaine, ou PSO fictive des comptes à privilèges (60 jours, 16 caractères) ; échéance calculée |
| groupes | appartenances réelles de l’annuaire fictif, imbrications parcourues (2 000 au plus), groupes à privilèges |
| liens GPO | stratégies fictives stables par niveau (domaine, Postes, site, Utilisateurs, service), un lien désactivé |
| GPO appliquées | stratégies côté ordinateur des liens, filtre WMI des portables, date d’application (parfois ancienne) |
| identité | adresse résolue du site, nom renvoyé par le poste (rarement différent), âge de l’enregistrement DNS |
| diagnostic | ping et ports d’après la présence relevée ; poste muet ou désactivé : sans réponse |
| inventaire | relevé d’inventaire du monde, ou tirage ; écart d’horloge (parfois plus de 5 min) |
| logiciels, sessions | listes réalistes stables (pilotes d’impression, session console du responsable, session RDP déconnectée) |

Refus et échecs réalistes : sondes en erreur du monde → `readRefused` (0x80070005) ; poste muet → `readFailed` (RPC
0x800706BA) ; poste désactivé → `readFailed` (hôte inconnu). Délais : `latency/screen/assistance/{search,read,step,incidents,dossier}`.
Huit incidents de session réalistes (délai WMI, accès refusé, RPC, 1219, DNS, moteur occupé, ouverture de session, PsExec).

## 9. Codes d’erreur

| Code | Message (extrait) |
|---|---|
| `assistance.recipesInvalid` | Recettes d’assistance invalides : … |
| `assistance.recipeUnknown` / `stepUnknown` | Recette inconnue / Étape inconnue dans cette recette : rien n’a été lancé. |
| `assistance.stepWithoutRead` | Cette étape ne lit rien : ouvrez sa vue. |
| `assistance.subjectMismatch` | Cette étape concerne un poste (un compte) : choisissez … Rien n’a été lancé. |
| `assistance.subjectUnknown` | Objet introuvable dans l’annuaire : rien n’a été lu. |
| `assistance.readRefused` / `readFailed` | message de la cible (jamais un secret) — enregistrés dans l’étape, pas renvoyés en erreur |
| `assistance.notRead` | Lisez d’abord la fiche de cet objet dans l’Assistance … |
| `assistance.slotEmpty` | Cet emplacement est vide : capturez d’abord une fiche. |
| `assistance.pinsFull` / `pinUnknown` / `pinOtherScope` | 24 repères … / Repère introuvable … / Repère d’un autre périmètre refusé … |
| `assistance.captureInvalid` | Capture refusée : *raison fixe*. Rien n’a été chargé. |
| `assistance.incidentUnknown` | Incident introuvable … |
| `assistance.keyMissing` | Clé de pseudonymisation absente ou trop courte (8 caractères au moins) … |
| `assistance.dossierBusy` / `dossierPerimeter` / `dossierTooLarge` / `dossierTimeout` | voir § 6 |
| `assistance.exportFailed` / `exportTooLarge` | Document non enregistré : *raison*. Rien n’a été remplacé. |
| `assistance.documentBusy` / `documentTimeout` | Un document est déjà en cours d’enregistrement… / l’écriture a dépassé 30 secondes… |
| `assistance.exportMissing` | Document introuvable dans le dossier des exports : seuls les documents enregistrés pendant cette session s’ouvrent ici. |
| `assistance.ticketRefused` | raison du refus du compte rendu (objet sans GUID…) ; `keyMissing` reste le code d’une clé absente |
| `assistance.engineBusy` | Moteur occupé : *n* lectures en cours et *m* en attente. Rien n’a été lancé ; réessayez après la fin des lectures. |
| `assistance.sessionChanged` | Réponse d’une autre session ignorée : la session a changé pendant la lecture (la préparation). Rien n’a été gardé. |

Plus les codes communs (`arguments.invalid`, `source.unavailable`…) d’`OPERATIONS.md` § 1.4.

## 10. Mode annuaire (vague 3)

Deux interfaces, comme l’arbre des OU ([`PLATFORM.md`](../PLATFORM.md) § 4) : **`IAssistanceIndex`** (base locale, jamais
le réseau ni une liaison à l’annuaire : recherche, suggestions, liste de postes, incidents de la source, lignes du dossier
hors ligne — opérations `LocalRead`, permises au chargement de la page) et **`IAssistanceReader`** (lecture d’un sujet, repère
retrouvé par GUID, lecture d’une étape — après un geste, `NetworkRead` en mode annuaire). Aucune implémentation n’existe
encore pour Active Directory : ces opérations répondent `source.unavailable` ; recettes, atelier (captures chargées),
incidents (journal de la session), documents et état du moteur restent servis. `Domenia.Ad` fournira `AdAssistanceIndex`
(SQLite) et `AdAssistanceReader`, découverts tout seuls. Règles communes : lecture après un geste explicite, sur le contrôleur
de la session, sans identifiant transmis (identité de la session ou compte explicite en `SecureString` du moteur), annulable,
**ordonnanceur de l’écran** (`AssistanceScheduler` : une lecture à la fois par objet, 3 en parallèle, 12 en attente au plus ;
au-delà « moteur occupé, rien n’a été lancé » ; compteurs montrés dans l’état du moteur ; relais vers l’ordonnanceur de
`Domenia.Engine` quand il existera), aucune nouvelle tentative, réponse d’une autre session ignorée ; refus de droits (`UnauthorizedAccessException`, `0x80070005`, `0x80041003`) → `readRefused` ;
RPC (`0x800706BA`), DNS, délai → `readFailed` ; un refus d’identifiants suspend le compte concerné (garde d’authentification).

| Lecture | Requêtes | Attributs, classes | Budget |
|---|---|---|---|
| `subjects.search` | base locale (SQLite, `Domenia.Store`) : objets par nom, identifiant, UPN, adresse, nom DNS, texte replié | — | aucune requête réseau, 20 lignes |
| `subjects.suggest` | base locale : comptes `lockoutTime` > 0 et état calculé, échéances ; observations de l’OU de travail | — | aucune requête réseau |
| `subject.read` | LDAP, recherche **Base** sur le DN (`(objectClass=*)`), puis `memberOf` par plages (`memberOf;range=…`) | les 29 de la liste blanche, `msDS-User-Account-Control-Computed`, `msDS-UserPasswordExpiryTimeComputed`, `lastLogonTimestamp`, `badPwdCount`, `msLAPS-PasswordExpirationTime` / `ms-Mcs-AdmPwdExpirationTime` (dates seulement, **jamais** `msLAPS-Password` ni `ms-Mcs-AdmPwd`) ; postes associés : `(&(objectCategory=computer)(managedBy=<dn>))` sous l’OU de travail | 1 à 3 requêtes, 5 s, 10 postes associés |
| `pin.locate` | LDAP Base sur `<GUID=…>` | `distinguishedName`, `objectClass` | 1 requête, 5 s |
| verrouillages (`LockoutDiagnosis`) | émulateur PDC (`fSMORoleOwner` de la racine), journal Sécurité par `EventLogSession` : XPath `*[System[EventID=4740 and TimeCreated[timediff(@SystemTime) <= 604800000]] and EventData[Data[@Name='TargetUserName']='<sam>']]` | `CallerComputerName`, date | 200 événements, 15 s ; droit « Lecteurs des journaux d’événements » |
| stratégie (`PasswordPolicyRead`) | LDAP Base sur l’utilisateur (`msDS-ResultantPSO`), puis l’objet PSO, puis la racine | PSO : `msDS-MaximumPasswordAge`, `msDS-MinimumPasswordLength`, `msDS-PasswordHistoryLength`, `msDS-LockoutThreshold`, `msDS-LockoutDuration` ; racine : `maxPwdAge`, `minPwdLength`, `pwdHistoryLength`, `lockoutThreshold`, `lockoutDuration` ; `msDS-UserPasswordExpiryTimeComputed` | 3 à 5 requêtes |
| groupes (`GroupPathRead`) | LDAP Base `tokenGroups` (attribut construit), noms par `<SID=…>` regroupés ; groupe principal par RID | `name`, `adminCount`, `description` | 2 000 groupes, 10 s |
| liens GPO (`GpoLinksRead`) | LDAP Base sur chaque conteneur, de l’objet à la racine | `gPLink` (liens et options désactivé / appliqué), `gPOptions` (héritage bloqué) ; noms : `displayName` de `CN={GUID},CN=Policies,CN=System,<racine>` | 1 requête par niveau + 1 pour les noms |
| GPO appliquées (`GpoAppliedRead`) | CIM DCOM sur le poste, `root\rsop\computer` : `RSOP_GPO` (nom, actif, filtre) ; dernière application par `StdRegProv` (`…\Group Policy\State\Machine\Extension-List`) | — | 30 s ; droits d’administration du poste |
| identité (`MachineIdentityRead`) | résolution DNS du `dNSHostName` depuis ce poste ; CIM `Win32_ComputerSystem` | `Name`, `Domain`, `PartOfDomain` | 10 s ; droits d’administration |
| diagnostic (`ComputerDiagnostics`) | ping ICMP (2 × 1 s) ; connexion TCP 135, 445, 3389, 5985 (1 s chacune, sans ouvrir de session) | — | 6 s |
| inventaire (`ComputerInventory`) | CIM `Win32_OperatingSystem` (`Caption`, `BuildNumber`, `LastBootUpTime`, `LocalDateTime`, mémoire libre et totale), `Win32_ComputerSystem` (`Model`), `Win32_LogicalDisk` (`DriveType=3`) ; heure du contrôleur : `currentTime` du rootDSE | — | 60 s ; droits d’administration |
| inventaire complet | + `Win32_Processor`, `Win32_BIOS`, `Win32_NetworkAdapterConfiguration` (`IPEnabled`), `Win32_Process` (mémoire, 10 premiers), redémarrage en attente (`StdRegProv`) | — | 120 s |
| logiciels (`SoftwareInventory`) | `StdRegProv` sur `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` et `WOW6432Node` ; **jamais** `Win32_Product` (réparation MSI) | `DisplayName`, `Publisher`, `DisplayVersion`, `InstallDate`, `EstimatedSize` | 60 s ; droits d’administration |
| sessions (`SessionsList`) | `WTSEnumerateSessions` sur le poste (ou CIM `Win32_LogonSession` + `Win32_LoggedOnUser`), sans rien fermer | — | 15 s |
| dossier hors ligne | base locale en lecture seule : mêmes requêtes que `Get-DomeniaAutomationQuery` (postes par GUID ou préfixe d’OU, dernières observations par famille, associations, requêtes non archivées) ; tables `secret_state` et `domenia_details` jamais lues | — | 1 000 lignes par section, 64 Mio, 300 s, aucun réseau |
| incidents | journal des opérations de la session et refus du pont (codes) ; `SessionIncidentsAsync` renvoie une liste vide | — | — |

## 11. Page

- `web/js/pages/assistance.js` et `web/js/pages/assistance/{format,common,subjects,recipes,workshop,documents}.js` ;
  `web/css/pages/assistance.css` (règles sous `.main[data-page="assistance"]`). `format.js` ne contient que des fonctions
  pures (comptes en français, chemins de DN, valeurs lisibles), testées dans `tests/web/assistance-format.test.mjs`.
- Héros : à l’arrivée, titre, phrase d’accroche et session d’assistance (compte et poste, recherche avec suggestions, poste
  associé `managedBy`) ; **dès qu’un sujet est choisi ou qu’une autre vue est ouverte, il se replie en barre de session
  compacte** (titre, mode, les deux sujets avec leur premier état). Le rail vertical est la seule navigation de l’écran :
  Guider (parcours), Comprendre (constats, A / B, incidents), Garder (repères), Transmettre (dossier et ticket, hors ligne),
  puis lectures en cours, état du moteur, comptes, vider l’atelier.
- Composants du kit : pastilles (`pill`), onglets (`createTabs` : fiche analysée, document), vues maître-détail
  (`createSplit` : constats, incidents), champs (`field`), fraîcheur (`freshness`, mise à jour toute seule), arbre
  (`createTree`, choix de l’OU du dossier). Une action grisée reste atteignable et dit pourquoi (`aria-disabled`, info-bulle).
- Valeurs lisibles : dates FILETIME et dates généralisées à l’heure locale (valeur brute en info-bulle), « aucun
  verrouillage », « jamais », nom seul pour `manager`, `managedBy` et `memberOf` (DN complet en info-bulle), DN coupés à leurs
  virgules, identifiants sur une ligne.
- Adresse : `#/assistance?vue=parcours|constats|comparer|incidents|reperes|dossier|horsligne&recette=<id>` ;
  `compte=<identifiant, nom ou DN>` et `poste=<nom ou DN>` (navigation depuis un autre écran) sont lus **seulement s’ils
  désignent exactement un objet** de l’index local, sinon les correspondances sont proposées dans la session et rien n’est
  lu ; puis ils sont retirés de l’adresse, et la page ne les y écrit jamais : un rechargement ne relit rien. `etat=moteur`
  ouvre l’état du moteur ; `document=ticket` ouvre le compte rendu.
- Session (TRV-185) : la page garde sa mémoire (sujets, choix des documents) pour la même session seulement ; quand
  l’empreinte `session` de l’atelier change, elle l’oublie et le dit. Tant que l’écran est affiché, `workshop.poll` compare
  l’atelier chaque seconde (appel de fond, sans ligne d’activité) : nouveaux incidents et lectures en cours apparaissent sans
  clic ; la vue Incidents ne se repeint pas pendant la saisie du filtre.
- **Paramètres de démonstration, honorés en simulation seulement** (captures) et ignorés en mode annuaire : `lancer=<étapes>`
  (`%2C` entre deux étapes), `a=` et `b=` (captures, nom exact d’un compte ou d’un poste), `epingler=1`, `preparer=1` (prépare
  directement si rien n’est écrit dans ce mode, sinon ouvre la confirmation).
- Ouverture d’une vue d’étape (contrat [`KIT.md`](../KIT.md) § 3.1) : `#/fiche?dn=…&tab=compte`,
  `#/poste?dn=…&onglet=reseau|materiel|logiciels|sessions`, `#/audit?tab=objet&dn=…&vue=motdepasse|poste|groupes|gpo` ;
  une vue dont le module n’existe pas encore est signalée, rien n’est deviné. Un repère ouvre `#/fiche?dn=…` après l’avoir
  retrouvé par son GUID.
- Aperçu dans un navigateur : `web/js/mock-assistance.js`, branché dans `mock.js` (objets fictifs, atelier en mémoire de la
  page, documents jamais écrits).

## 12. Tests écrits (exécutés à la fin, dans la VM)

| Fichier | Couvre |
|---|---|
| `AssistanceRulesTests` | contrat des recettes et refus, plan, états, nettoyage et masques, capture (liste blanche, partiel, identité), constats de Domenia 1 et règles machines, comparaison, incidents (10 règles, bornes, doublons, filtre), pseudonymes, compte rendu, fichiers de capture, dossier hors ligne (périmètres, secrets, empreintes), dossier support (sections, gabarits, HTML strict) |
| `AssistanceOperationsTests` | formes JSON, recherche et suggestions, lecture et constats, étape lue / refusée / en échec, journal et incidents, captures et fichiers, repères (24, GUID), documents et clé, dossier hors ligne en mémoire, état du moteur sans jargon, mode annuaire sans lecteur |
| `AssistanceSessionTests` | isolation par session (domaine, compte, reconnexion avec le même compte), réponse tardive ignorée, repère d’un autre périmètre, ordonnanceur (un objet à la fois, saturation, compteurs), état du moteur pendant une lecture et incidents identiques à la vue, documents réels sur un dossier temporaire (nom unique sans remplacement, aucun temporaire laissé, chemin refusé, lien refusé), un document à la fois et délai, `document.reveal`, périmètres OU choisie et liste de postes, `computers.resolve`, commande en ligne (codes de Domenia 1), noms datés et tailles, pseudonymes exhaustifs (aucun « CN=… » en clair, manager, groupes, postes cités par les lectures) |
| `PlatformTests` (mis à jour) | module `AssistanceOperations` et ses 27 opérations dans le registre réel |
| `tests/web/assistance-format.test.mjs` | aides pures de la page : pluriels avec espace insécable, initiales, chemins et noms de DN, FILETIME et dates généralisées, valeurs spéciales, identifiants |
| `tests/e2e/assistance/*.json` | parcours « Connexion impossible », capture et comparaison, dossier et compte rendu pseudonymisé |

## 13. Reste à faire

- `AdAssistanceIndex` et `AdAssistanceReader` (vague 3, § 10), génération de connexion incrémentée par `Domenia.Ad`, et
  essais réels dans `OU=Domenia-Tests` (vague 4).
- Envoi d’une sélection depuis les écrans de liste vers « Liste de postes » (aujourd’hui : coller les noms) ; boîte
  « Enregistrer sous » de l’hôte.
- Export PDF du dossier support (`PrintToPdfAsync` de l’hôte, hors de ce lot) ; le HTML exporté s’imprime en PDF.
- Chiffrement facultatif des captures et du dossier hors ligne (amélioration listée, demande une décision sur la méthode).
- Recettes déclaratives signées (JSON) : le catalogue est aujourd’hui du code validé au démarrage.
