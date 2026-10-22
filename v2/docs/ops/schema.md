# Domenia 2 — écrans « Schéma de l’annuaire » (`schema`) et « Comptes machine » (`machine`)

Ce document fixe le contrat des opérations des deux écrans, leur simulation et ce que la vague 3 branchera sur Active
Directory (§ 17, « Mode annuaire »). Il complète [`OPERATIONS.md`](../OPERATIONS.md) : enveloppe, règles JSON, classes
d’opération et codes communs y sont définis et ne sont pas répétés ici.

Fonctions de Domenia 1 portées : SCH-001 à SCH-008 (points 28 et 29, `Domenia-DirectorySchema.*`) et MAC-001 à MAC-003
(UX-15, UI-27, FO-19, SE-16, `Domenia-Accounts.*`, `Domenia-MachineAccount.xaml`). Statut : [`../status/schema.json`](../status/schema.json).

## 1. Principes

- **Lecture seule par construction.** Aucune opération de ces écrans n’écrit dans l’annuaire ni sur un poste : le schéma
  n’est jamais modifié, aucune valeur d’objet n’est lue ; les comptes poste vivent dans la mémoire du moteur pour la
  session. Aucune écriture, donc aucun plan ni `write.execute` : le circuit de [`WRITES.md`](../WRITES.md) ne s’applique pas.
- **Aucune lecture réseau sans geste.** Seules `schema.read` (lecture bornée du schéma) et `machine.account.trial` (une
  lecture légère d’un seul poste) sont des `NetworkRead` ; toutes deux partent d’un clic. Les adresses `#/schema?lire=1` et
  `#/machine?…&essai=1` ne déclenchent la lecture qu’en simulation (captures, scénarios) ; en mode annuaire, la page affiche
  « cliquez … pour la lancer ».
- **Jamais une autre session ni un autre domaine.** Le schéma lu est gardé avec l’identité de la session (racine du domaine,
  compte et méthode de connexion : `SessionIdentity`) et n’est jamais utilisé pour une autre (Domenia 1
  `Get-DomeniaAdSchemaCatalogForAnalysis`, qui compare `SessionEpoch` et le domaine). Les baux des comptes temporaires suivent
  la même règle (§ 10).
- **Aucun secret.** Aucune réponse ne porte de mot de passe ; aucun nom de propriété JSON ne contient `password`, `pwd` ni
  `secret` (le mot de passe est « credential », la cascade des secrets « confidentialReads »). Le journal technique ne reçoit
  que des codes et des nombres.
- **Transit du mot de passe, dit honnêtement.** Dans WebView2, le mot de passe saisi ne peut pas être une `SecureString` de
  bout en bout : il existe un instant en clair dans la valeur du champ, puis dans le message JSON envoyé au moteur
  (`chrome.webview.postMessage`), puis dans la chaîne .NET immuable désérialisée par `BridgeDispatcher`. Ce qui est garanti :
  la page vide le champ dès que le compte est utilisé ou oublié, à la fermeture du panneau, sur Échap ou un clic à côté (il
  reste dans le champ entre « Valider sur ce poste » et « Utiliser ce compte », le temps du geste), ne garde le texte dans
  aucune variable ni aucun stockage, et ne l’affiche que 5 secondes dans un calque en lecture seule ; le moteur
  ne trace jamais le contenu d’un message (`BridgeDispatcher` ne trace que codes et noms d’opération), copie le texte dans une
  `SecureString` en lecture seule dès l’entrée du gestionnaire (`MachineOperations.Secret`), ne le garde pas et ne le renvoie
  jamais ; la chaîne et le message deviennent inaccessibles à la fin de la requête (le ramasse-miettes .NET ne promet pas leur
  effacement immédiat). Ensuite, et jusqu’à l’API Windows, le mot de passe n’existe qu’en `SecureString`.

## 2. Récapitulatif

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `schema.status` | `Local` | aucun | `SchemaStatus` (§ 3) |
| `schema.read` | `NetworkRead` (servie en simulation) | aucun | `SchemaStatus` ; événements `schema.read:stage` |
| `schema.list` | `Local` | `{ kind, text?, limit? }` | `SchemaListResult` (§ 4) |
| `schema.class` | `Local` | `{ name }` | `SchemaClassDetail` (§ 5) |
| `schema.attribute` | `Local` | `{ name }` | `SchemaAttributeDetail` (§ 6) |
| `schema.filter.analyze` | `Local` | `{ filter }` | `LdapFilterAnalysis` (§ 7) |
| `schema.filter.insert` | `Local` | `{ filter, attribute }` | `SchemaFilterInsertResult` (§ 8) |
| `machine.account.state` | `LocalRead` | `{ target? }` | `MachineAccountState` (§ 11) |
| `machine.account.use` | `Local` | `{ account, password, target? }` | `MachineAccountState` |
| `machine.account.forget` | `Local` | `{ target? }` | `MachineAccountState` |
| `machine.account.trial` | `NetworkRead` (servie en simulation) | `{ target, account?, password? }` | `{ trial, state }` (§ 13) |
| `machine.account.watch` | `Local` | `{ since, target? }` | `MachineAccountWatch` (§ 13 bis) |
| `machine.workstations.search` | `LocalRead` | `{ text }` | tableau de `MachineWorkstation` (§ 14) |

Les opérations `Local` du schéma travaillent sur le catalogue gardé en mémoire (`SchemaService`) : elles ne lisent rien.
`machine.account.state` et `machine.workstations.search` lisent la base locale en mode annuaire (le poste choisi), jamais le
réseau.

## 3. `schema.status` et `schema.read`

`schema.read` lit une fois, sur geste, les définitions `attributeSchema` et `classSchema` du contrôleur de la session :
8 000 attributs, 3 000 classes et 90 secondes au plus (une entrée de plus que la limite prouve la limite et marque la lecture
incomplète). Le budget de 90 secondes est donné au lecteur ; le service arrête de lui-même une lecture qui le dépasse
(arrêt à 150 secondes, comme la tâche de Domenia 1 : `schema.readFailed`, « Lecture du schéma impossible : lecture
interrompue au-delà de 150 secondes (budget de 90 secondes dépassé). »). Une seule lecture à la fois : une seconde demande
pendant la première est **refusée** (`schema.readBusy`), jamais mise en attente. Une lecture pour un autre domaine ou dans un
contexte de schéma inattendu est refusée ; un échec garde le schéma lu avant (« Le schéma lu précédemment reste affiché. »). Le journal des opérations reçoit
« Schéma lu sur DC01.example.local : 47 classes, 244 attributs ».

Événements `schema.read:stage` : `{ "stage": "context" | "attributes" | "classes", "label": "…" }`, dans cet ordre.

| Champ | Type | Contenu |
|---|---|---|
| `read` | booléen | Un schéma de ce domaine est lu dans cette session. |
| `server` | texte ou `null` | Contrôleur qui a répondu. |
| `readAt` | date-heure ou `null` | Date de la lecture. |
| `classes`, `attributes` | entiers | Définitions gardées (noms invalides écartés). |
| `truncated` | booléen | Lecture arrêtée à une limite : un attribut absent de la liste peut exister. |
| `durationMs` | entier ou `null` | Durée de la lecture sur le contrôleur. |
| `text` | texte | Phrase de Domenia 1 : « Schéma lu le 21/10/2026 à 18:26 sur DC01.example.local : 47 classes, 244 attributs. » (+ « Lecture incomplète (limite atteinte) : … »), ou « Schéma non lu dans cette session. La lecture est explicite et ne modifie rien. » |
| `tone` | ton | `ok`, `warn` (incomplète), `off` (non lu), `alert` (dernier essai en échec). |
| `lastError` | texte ou `null` | Message du dernier échec, effacé par une lecture réussie. |
| `simulated` | booléen | Annuaire fictif. |
| `limits` | objet | `{ attributes: 8000, classes: 3000, seconds: 90 }`. |
| `statistics` | objet ou `null` | `indexed`, `tupleIndexed`, `inGlobalCatalog`, `confidential`, `constructed`, `linked`, `defunct` (attributs et classes), `singleValued`, `indexedPercent` (dixième), `syntaxes` et `categories` : `[{ id, label, count }]`. |

Erreurs de `schema.read` : `source.unavailable` (mode annuaire tant que `Domenia.Ad` n’est pas branché), `schema.readFailed`,
`schema.readBusy`, `operation.cancelled`.

## 4. `schema.list`

Classes ou attributs dont le **nom ou la description** contient le texte, casse ignorée (Domenia 1
`Find-DomeniaAdSchemaEntries`) ; chaque correspondance est comptée, les premières deviennent des lignes ; ordre alphabétique.

- Arguments : `kind` = `classes` | `attributes` (obligatoire) ; `text` texte ou `null` (128 caractères au plus) ; `limit`
  entier de 1 à 5 000 (500 par défaut, comme Domenia 1).
- La page filtre **toujours par le moteur** (mêmes règles que Domenia 1 : nom ou description, sous-chaîne, casse ignorée), après
  une pause de 250 ms, avec `limit` = 5 000, et affiche le résumé du moteur (« 12 classes trouvées. »). Le filtre rapide de la
  grille, qui cherche dans toutes les colonnes visibles, n’est pas proposé (« top » ne doit pas lister toutes les classes qui
  héritent de top) ; les filtres par colonne restent, explicites et propres à une colonne. Le champ refuse plus de
  128 caractères.
- Résultat : `{ kind, text, total, shown, limit, summary, rows }` ; `summary` : « 12 classes trouvées. » ou
  « 1 234 attributs trouvés, 500 affichés : précisez le filtre. ».
- Ligne : `name`, `kind` (`class`|`attribute`), `nature` (catégorie ou syntaxe en clair, « Obsolète » pour une entrée
  désactivée), `detail` (« Hérite de top » ; « Une valeur · Indexé »), `description`, `defunct`, puis selon le type
  `category`, `subClassOf` ou `syntaxLabel`, `indexText`, `singleValued`, `indexed`, `inGlobalCatalog`, `confidential`,
  `constructed` (les champs de l’autre type valent `null`).

## 5. `schema.class`

Détail d’une classe (SCH-003, Domenia 1 `Get-DomeniaAdClassAttributes`) : ses `mustContain` et `mayContain`, ceux de ses
superclasses jusqu’à `top` et de ses classes auxiliaires, **obligatoires d’abord** puis par nom ; parcours borné à 256
classes (une boucle du schéma n’arrête jamais le moteur) ; un attribut cité mais absent du schéma lu est listé dans `missing`.

| Champ | Contenu |
|---|---|
| `name`, `oid`, `description`, `category`, `categoryLabel`, `defunct`, `subClassOf`, `auxiliary` | La classe. |
| `chain` | Classes parcourues, dans l’ordre de Domenia 1 (largeur d’abord). |
| `superclasses` | La classe et ses parentes jusqu’à `top`. |
| `lineage` | `{ name, relation (self|parent|auxiliary), via, categoryLabel, known, depth }`. |
| `subclasses` | Classes dérivées directes (amélioration). |
| `attributes` | `{ name, required, origin, syntaxLabel, kind, singleValued, values, indexText, indexed, inGlobalCatalog, confidential, constructed, defunct, description }`. |
| `missing`, `requiredCount`, `optionalCount`, `walkTruncated` | Absents, nombres, parcours arrêté. |
| `summary` | « user · classe structurelle · chaîne : user → … · 145 attributs possibles. » |
| `filter`, `recommendedFilter`, `filterAdvice` | « (objectClass=user) », « (&(objectCategory=person)(objectClass=user)) », conseil objectClass ou objectCategory. |
| `recommendedNote` | Ce que le filtre recommandé écarte quand la catégorie ne couvre pas toutes les classes dérivées, ou `null` : « Le filtre recommandé écarte computer, msDS-GroupManagedServiceAccount et msDS-ManagedServiceAccount, qui dérivent de user avec une autre catégorie : gardez (objectClass=user) pour les inclure. » (classes structurelles dérivées, parcours borné à 256 classes ; sans schéma lu, schéma de base). |

## 6. `schema.attribute`

Détail d’un attribut (SCH-002 et SCH-004) : `name`, `oid`, `description`, `syntax` (OID 2.5.5.x), `syntaxLabel`, `kind`,
`omSyntax`, `singleValued`, `valuesLabel`, `indexText` (« Indexé », « Indexé, sous-chaîne comprise », « Non indexé »,
« Calculé, non filtrable »), `inGlobalCatalog`, `defunct`, `constructed`, `flags` (`{ id, label, on, tone, tip }` : indexé,
sous-chaîne, ANR, catalogue global, une seule valeur, confidentiel, calculé, non répliqué, lié, filtré des RODC, obsolète),
`linkId`, `linkLabel`, `linkPartner` (attribut du lien associé, amélioration), `rangeLower`, `rangeUpper`, `rangeLabel`,
`summary` (première ligne de Domenia 1), `hint` (`{ example, notes }`, Domenia 1 `Get-DomeniaAdAttributeQueryHint`),
`insertable` et `insertReason` (jamais pour un attribut calculé ou obsolète), `usedBy` (60 classes au plus qui le déclarent,
`{ name, required }`) et `usedByTotal`.

## 7. `schema.filter.analyze`

Analyse locale d’un filtre RFC 4515 (SCH-006, Domenia 1 `Get-DomeniaLdapFilterAnalysis`) : 32 768 caractères, 64 niveaux et
2 000 éléments au plus ; un filtre tapé sans ses parenthèses extérieures est complété ; une erreur ne lève jamais
d’exception : elle est rendue avec sa position. Fonctionne sans schéma lu (index inconnus, et la page le dit).

| Champ | Contenu |
|---|---|
| `valid`, `error`, `errorPosition`, `normalized` | Validité, message de Domenia 1 (« Parenthèse fermante attendue, position 12. »), position dans le texte normalisé. |
| `level`, `levelLabel`, `tone` | `targeted` Ciblé (ok), `broad` Large (warn), `unknown` Inconnu (info), `invalid` Invalide (alert). |
| `indexUse`, `schemaUsed` | `yes`, `no`, `unknown` ; schéma de la session utilisé. |
| `attributes`, `notIndexed`, `unknown`, `leadingWildcards`, `constructed`, `confidential`, `negations`, `extensible` | Constat. |
| `advice`, `text` | Conseils de Domenia 1, texte complet « Coût LDAP : Ciblé. … ». |
| `tree` | Structure du filtre : `{ kind, label, text, attribute, value, rule, negated, leadingWildcard, indexUse, indexLabel, children }` (300 éléments au plus, sinon `null`) — amélioration. |
| `suggestion` | Réécriture suggérée `{ filter, reasons }` ou `null` — amélioration : objectCategory ajouté à côté d’objectClass, équivalent stocké exact d’un attribut calculé (`createTimeStamp` → `whenCreated`, `modifyTimeStamp` → `whenChanged`), joker en tête retiré sur un attribut texte indexé sans index de sous-chaîne ; une réécriture n’est proposée que si elle se relit valide, sinon les raisons restent des conseils. objectCategory est proposé quand aucun index ne sert le filtre, ou quand la catégorie écarte des classes dérivées ; la raison le dit alors toujours (« (objectCategory=person) cible la catégorie, indexée, mais écarte computer…, qui dérivent de person avec une autre catégorie : gardez objectClass seul pour les inclure. ») : une réécriture ne change jamais le sens du filtre sans le dire. Sans classe écartée, la raison dit « sans changer le résultat ». |

## 8. `schema.filter.insert`

Ajoute l’exemple de critère de l’attribut au brouillon (SCH-005, Domenia 1 `Add-DomeniaAdSchemaAttributeToFilter`) : filtre
vide → l’exemple ; filtre ET valide → dans le ET ; sinon un ET est créé autour. L’opérateur complète la valeur ; **rien n’est
exécuté**. Refusé (filtre inchangé, `changed` = `false`, message) pour un attribut calculé ou obsolète. Résultat :
`{ filter, changed, message, analysis }`. La page propose ensuite « Atelier de requêtes » : `#/requetes?filtre=<filtre>`
(brouillon, rien n’est exécuté).

## 9. Erreurs propres du schéma

| Code | Message |
|---|---|
| `schema.notRead` | Schéma non lu dans cette session : lisez-le d’abord (lecture explicite, rien n’est modifié). |
| `schema.unknownClass` | Classe inconnue du schéma lu : rien n’a été affiché. |
| `schema.unknownAttribute` | Attribut inconnu du schéma lu : rien n’a été affiché. |
| `schema.readFailed` | Lecture du schéma impossible : *raison*. (+ « Le schéma lu précédemment reste affiché. ») |
| `schema.readBusy` | Une lecture du schéma est déjà en cours : attendez sa fin (une seule lecture à la fois). |

Précisions de `arguments.invalid` : « « kind » vaut classes ou attributes. », « « text » doit faire au plus 128 caractères. »,
« « limit » doit être un entier de 1 à 5 000. », « « name » doit être un nom LDAP (lettres, chiffres et tirets, 128 au
plus). » (de même pour « attribute »).

## 10. Comptes machine : la règle

Le compte que prend la prochaine opération sur un poste (C$, consoles, inventaire, diagnostic, sessions) est choisi par une
règle unique, identique au contexte des opérations (MAC-001, Domenia 1 `Get-DomeniaMachineAccountInUse`) ; le premier niveau
configuré sert :

1. compte local temporaire accepté pour **ce** poste (après un refus, bail en mémoire) — seulement quand un poste est choisi ;
2. compte temporaire Postes accepté après un refus ;
3. compte poste saisi dans le panneau « Compte poste » (en mémoire seulement) ;
4. compte Postes de la page Comptes ;
5. compte de connexion (identifiants explicites) ;
6. session Windows (toujours disponible ; en simulation, le compte de la session fictive, jamais le compte Windows réel).

Pour les secrets (LAPS, BitLocker) : compte temporaire Secrets, compte Secrets de la page Comptes, sinon compte de
l’annuaire. `MachineAccountService` (Core, service partagé du contexte) garde ces comptes ; l’écran Comptes machine règle le
niveau 3, la page Comptes et la reprise après refus régleront les autres par `UseRemote`, `UseSecrets`, `AcceptTemporary`,
`AcceptSecretsTemporary` (et leurs retraits). Chaque changement ouvre une nouvelle **génération** (point 44).

**Baux des comptes temporaires** (niveaux 1 et 2, compte temporaire Secrets ; Domenia 1 D054, `Test-DomeniaAccessLeaseUsable`,
`Get-DomeniaLeaseRemainingText`) : `AcceptTemporary(session, poste, compte, mot de passe, mode, minutes)` crée un bail
`OneShot` (une seule utilisation), `Session` (jusqu’à la fin de la session) ou `Inactivity` (30 minutes sans utilisation par
défaut, de 1 à 480), lié à l’identité de la session et au domaine (`SessionIdentity`). Seule une utilisation par une opération
(`CredentialFor`) le prolonge ; une lecture de l’état ne le prolonge jamais. Un bail qui ne permet plus une nouvelle
utilisation (autre session ou domaine, usage unique dépensé, délai dépassé) est oublié au contrôle suivant, comme
`Get-DomeniaRetryCredential` : le compte est libéré, la génération avance, le journal des opérations dit « Compte temporaire
oublié : *raison* » sans le nom. Le niveau affiche le temps restant (« Bail : encore 27 min sans utilisation. »).

**Pauses par place** : un refus d’identifiants ou de compte met en pause **une place** de la règle (sa source et la génération du
compte qui l’occupe, jamais tous les comptes d’un même nom : deux places peuvent porter le même nom avec deux mots de passe).
Pastille ambre et glyphe pause (amélioration de MAC-002) jusqu’à un essai réussi de cette place. Un compte **à valider**
(panneau, « Valider sur ce poste ») n’a pas de place : son verdict ne met jamais en pause et ne libère jamais le compte en
service, même de même nom. Un nouveau compte saisi est une nouvelle place, sans pause. `CredentialFor(session, target)`
donne aux opérations de la vague 3 la source, le nom, une copie en lecture seule de la `SecureString` (que l’appelant libère)
et la place (`MachineOperationCredential`) ; il **refuse** un compte en pause (`machine.accountPaused`) sauf pour l’essai
d’accès (`forTrial`), qui est le moyen de le valider. `RecordRefusal(place, compte, raison)` et `ClearPause(place)` servent à la
garde d’authentification.

## 11. `machine.account.state`

Arguments : aucun, `{}` ou `{ "target": "PC-PAR-0042" }` (nom de poste, nom DNS ou nom avec le domaine). Résultat :

| Champ | Contenu |
|---|---|
| `inUse` | `{ source, account, origin, short, long, pill, tip, rank, paused, pauseReason, tone }` : `pill` = « Compte poste : session Windows ▾ », `tip` = infobulle de Domenia 1. |
| `sentence` | « Opérations poste : session Windows (EXAMPLE\j.martin). » |
| `targetName`, `target` | Nom demandé et poste trouvé : `{ id, name, dnsHostName, dn, path, operatingSystem, enabled, presence: { state, label, tone, checkedAt } }` ou `null`. |
| `levels` | Six niveaux `{ rank, source, title, origin, account, state (active|available|empty|notApplicable), stateLabel, tone, detail, paused, pauseReason }`. |
| `confidentialReads` | Compte des secrets : `{ account, origin, long, levels }` (trois niveaux). |
| `typed` | `{ account, since, withCredential }` ou `null`. |
| `credentialRequired`, `credentialNote` | Mot de passe exigé (mode annuaire) ou non (simulation) et phrase d’explication. |
| `generation`, `version`, `simulated`, `trials` (huit derniers essais), `safeguards` (précautions de Domenia 1) | `version` : compteur de changements (comptes, baux, pauses, essais), point de départ de `machine.account.watch`. |

## 12. `machine.account.use` et `machine.account.forget`

- `use` (`Local`) : `{ "account": "EXAMPLE\\adm-j.martin", "password": "…" | null, "target": null }`. Formes admises :
  `DOMAINE\nom`, `POSTE\nom`, `.\nom` (compte local du poste choisi), `nom@domaine` (256 caractères au plus). En mode annuaire le
  mot de passe est exigé (256 caractères au plus) et devient aussitôt une `SecureString` en lecture seule ; en simulation
  aucun mot de passe n’est admis (`SIMULATION.md` § 1, point 5) et le compte est gardé par son nom. Journal des opérations :
  « Compte poste saisi pour la session (en mémoire seulement) », sans le nom. Résultat : l’état du § 11.
- `forget` (`Local`) : oublie le compte saisi (Domenia 1 `Clear-MachineCredential`) ; le niveau suivant reprend. Oublier
  deux fois ne change rien.
- Erreurs : `machine.accountEmpty`, `machine.accountInvalid`, `machine.passwordMissing` (mode annuaire),
  `machine.passwordRefused` (simulation), `arguments.invalid`.

## 13. `machine.account.trial`

Essai d’accès sur **un seul** poste (CPT-015 / FO-19, et l’amélioration de MAC-003 « Valider ce compte sur ce poste ») : une
lecture légère du système, avec le compte en service (même en pause : l’essai est le moyen de le valider), ou avec un compte
**à valider** (`account`, et `password` en mode annuaire) qui n’entre pas en service. Verdicts de Domenia 1 (`Get-DomeniaRemoteAccessTrialVerdict`) : `adminOk` (« Accès
administrateur OK sur … Système : … »), `denied`, `rejected`, `accountState`, `unreachable`, `unknown`. Avec le compte en service, un `rejected` ou un `accountState` met sa place en
pause et un `adminOk` lève cette pause ; avec un compte à valider, rien n’est mis en pause ni levé. Journal des opérations : « Essai du compte poste sur
SRV-FIC-01 : accès refusé (simulation) ». Résultat : `{ trial: { verdict, success, text, tone, computer, account, origin,
caption, candidate, simulated, at }, state }`.

Erreurs : `machine.targetMissing`, `machine.targetUnknown`, `machine.accountInvalid`, `machine.passwordRefused`,
`machine.passwordMissing`, `source.unavailable` (mode annuaire tant que `Domenia.Inventory` n’est pas branché),
`operation.cancelled`.

## 13 bis. `machine.account.watch`

Veille du compte des opérations poste (équivalent de `Timer:Accounts` de Domenia 1, « mise à jour quand le texte change ») :
`{ "since": 12, "target": "PC-PAR-0042" }` répond dès que le compteur de changements diffère de `since`, 25 secondes au plus
(alors `changed` = `false`) ; `since` = `null` répond tout de suite. Un bail d’inactivité qui expire pendant la veille compte
comme un changement. Mémoire seulement (`Local`) : aucune lecture, ni annuaire, ni base, ni réseau. Résultat :
`{ version, changed, inUse, sentence, generation }` (`inUse` et `sentence` du § 11). La page enchaîne les veilles sans passer
par le compteur d’activité des écrans (`trackedCall`) : une veille ne retient jamais le signal `data-ready` d’une capture. Elle
s’arrête quand l’écran se démonte (la veille en cours se termine d’elle-même au plus tard 25 secondes après). Erreur :
`arguments.invalid` (« « since » doit être un entier positif ou null. »).

## 14. `machine.workstations.search`

`{ "text": "pc-par" }` (64 caractères au plus) : douze postes au plus dont le nom contient le texte (sans accent ni casse),
ceux qui commencent par le texte d’abord. Texte vide : `[]`. Sert au choix du poste et aux « postes proches » quand le poste
de l’adresse est introuvable.

## 15. Simulation

- **Schéma fictif** (`Screens/Schema/SimulatedSchemaDefinitions.cs`) : 47 classes et 244 attributs, sous-ensemble représentatif
  du schéma de base (noms LDAP, syntaxes, cardinalité, index, catalogue global, liens, attributs calculés réels), extensions
  LAPS, BitLocker, TPM et RFC 2307, et une extension d’entreprise « Example » avec un attribut et une classe désactivés.
  Descriptions en français. Identique pour toutes les graines. Délais réalistes et annulables : contexte 80 à 200 ms,
  attributs 420 à 900 ms, classes 220 à 560 ms (`latency/screen/schema/…`) ; durée annoncée tirée du sous-flux
  `screen/schema/duration`.
- **Essai simulé** (`Screens/Machine/SimulatedMachineAccountReader.cs`) : poste de l’annuaire fictif (écritures de la session
  comprises) ; injoignable s’il est désactivé ou sans réponse au relevé initial ; compte local de ce poste accepté, compte
  local d’un autre poste ou compte inconnu refusés ; compte désactivé, verrouillé ou expiré « restreint » ; administrateur par
  les groupes du type d’ordinateur (imbrications comprises) : GG-Admins-Postes pour un poste, GG-Admins-Serveurs pour un
  serveur d’OU=Serveurs, Admins du domaine ou Administrateurs partout (et Administrateurs de l’entreprise pour un contrôleur).
  Aucun mot de passe n’est demandé ni vérifié ; délai 600 à 1 400 ms (`latency/screen/machine/trial`).

## 16. Erreurs propres des comptes machine

| Code | Message |
|---|---|
| `machine.accountEmpty` | Compte poste vide : rien n’a changé. |
| `machine.accountInvalid` | Identifiant non reconnu : écrivez DOMAINE\nom, POSTE\nom, .\nom ou nom@domaine. Rien n’a changé. |
| `machine.passwordMissing` | Mot de passe du compte poste vide : rien n’a changé. |
| `machine.passwordRefused` | Simulation : aucun mot de passe n’est demandé ni gardé. Laissez le champ vide. |
| `machine.targetMissing` | Choisissez d’abord un poste : l’essai porte sur un seul poste, jamais sur une liste. |
| `machine.targetUnknown` | Poste introuvable dans l’annuaire : aucun essai n’est parti. |
| `machine.accountPaused` | Compte poste en pause après un refus : aucune opération n’est partie. Validez-le par un essai d’accès réussi, ou utilisez un autre compte. (`CredentialFor`, opérations de la vague 3) |

## 17. Mode annuaire (vague 3)

### 17.1 Lecture du schéma (`ISchemaReader` dans `Domenia.Ad`)

Implémentation réelle ajoutée le 23/10/2026 : `Domenia.Ad/Screens/AdSchemaReader.cs`, découverte par la composition.
Elle applique les bornes et projections ci-dessous, conserve les définitions déjà lues si le budget expire en signalant
`Truncated`, et propage les refus d’accès. Tests sans annuaire : `AdSchemaReaderTests` (écrits et compilés ; exécution
prévue à la recette). Le cache disque du schéma reste à brancher avec le stockage ; aucune validation AD réelle annoncée.


Port du worker `AdSchemaRead` de Domenia 1 (`Domenia-DirectorySchema.Worker.ps1`), sur `System.DirectoryServices.Protocols`
(`LdapConnection` vers le contrôleur de la session, Negotiate, signature et chiffrement), avec la garde d’authentification
(un refus suspend le compte de la ressource Annuaire, jamais un second contrôleur après l’envoi du mot de passe).

1. RootDSE : `schemaNamingContext` (lecture de la seule valeur). Refus si le contexte ne commence pas par
   `CN=Schema,CN=Configuration,DC=` (« contexte de schéma inattendu, lecture refusée »).
2. Attributs : base = contexte du schéma, portée `OneLevel`, filtre `(objectClass=attributeSchema)`, attributs
   `lDAPDisplayName`, `adminDescription`, `attributeID`, `attributeSyntax`, `oMSyntax`, `isSingleValued`, `searchFlags`,
   `systemFlags`, `isMemberOfPartialAttributeSet`, `rangeLower`, `rangeUpper`, `linkID`, `isDefunct`.
3. Classes : même base et portée, filtre `(objectClass=classSchema)`, attributs `lDAPDisplayName`, `adminDescription`,
   `governsID`, `subClassOf`, `auxiliaryClass`, `systemAuxiliaryClass`, `mayContain`, `systemMayContain`, `mustContain`,
   `systemMustContain`, `objectClassCategory`, `isDefunct`.
4. Bornes : `SizeLimit` = limite + 1 (8 001, 3 001), pages de 500 (`PageResultRequestControl`), `TimeLimit` serveur 60 s,
   délai client 75 s, budget total 90 s (chronomètre) ; arrêt à la limite ou au budget : `Truncated` = vrai. Noms hors
   `[A-Za-z0-9-]{1,128}` écartés, descriptions aplaties à 500 caractères, booléens « TRUE ».
5. `Server` : nom DNS du contrôleur qui a répondu (`dnsHostName` du RootDSE) ; `ObservedAt` : horloge du moteur ;
   `DomainDn` : racine de la session.
6. Budget : une lecture par geste, jamais automatique, une à la fois (`SchemaService`), classe `NetworkRead` ; environ 1 Mo
   pour un schéma de 8 000 attributs. Le catalogue reste en mémoire pour la session, lié à sa racine ; un changement de
   session ou de domaine le rend inutilisable (et `schema.status` dit « non lu »). Amélioration à brancher avec la
   composition : cache disque du schéma par domaine, daté (dossier de données du mode), relu seulement pour le même domaine.

### 17.2 Comptes machine

- **Poste choisi** (`machine.account.state`, `machine.workstations.search`) : base locale (table des ordinateurs : nom,
  `dNSHostName`, DN, système, `userAccountControl`, derniers relevés de présence) ; préfixe d’abord, puis « contient » ; douze
  lignes ; jamais le réseau.
- **Essai d’accès** (`IMachineAccountReader.ProbeAccessAsync`, `Domenia.Inventory`) : une session CIM sur DCOM vers le poste
  (`DComSessionOptions`), avec le compte de `CredentialFor` (`CimCredential` construit depuis la `SecureString`), requête
  `SELECT Caption FROM Win32_OperatingSystem` (une instance), 6 s par méthode, 30 s au plus pour l’essai ; ni ping, ni WinRM,
  ni console, ni repli. Correspondances : 0x80070005 → `Denied` / `AccessDenied` ; 0x8007052E → `AuthRejected` /
  `CredentialsRejected` ; 0x80070532, 0x80070533, 0x80070701, 0x80070775 (mot de passe expiré, compte désactivé, expiré,
  verrouillé) → `AccountState` ; 0x800706BA, délai → `Timeout` / `Network` ; succès → `Observed` avec la légende. Un seul
  essai à la fois par poste ; classe `NetworkRead`, après le clic.
- **Mot de passe** : `SecureString` en lecture seule jusqu’à l’appel Windows (`WNetAddConnection2`, `CimCredential`,
  `LogonUser`), jamais en ligne de commande ni dans un journal. Un refus d’identifiants enregistré par la garde
  d’authentification appelle `RecordRefusal`.

## 18. Page

- `web/js/pages/schema.js` (+ `schema/model.js`, `catalog.js`, `detail.js`, `workbench.js`), `web/css/pages/schema.css` :
  héros (statut, contrôleur, date, vue d’ensemble : anneau des familles de syntaxe, classes, indexés, catalogue global,
  sensibles ; classes courantes), catalogue maître-détail (grille virtuelle du kit, bascule Classes / Attributs avec nombres,
  détail redimensionnable), analyseur de filtre (coloration, verdict et échelle, conseils, attributs, structure, réécriture,
  exemples, ajout de l’attribut choisi, envoi vers l’atelier). Paramètres : `vue=classes|attributs`, `classe=`, `attribut=`,
  `filtre=`, `lire=1` (simulation).
- `web/js/pages/machine.js` (+ `machine/cascade.js`, `machine/panel.js`), `web/css/pages/machine.css` : héros et compte en
  service (avatar, pastille, pause), règle en six niveaux, poste précis (recherche, poste, postes proches), compte des secrets,
  essai d’accès et essais de la session, précautions ; panneau « Compte poste ». Paramètres : `poste=`, `panneau=compte`,
  `essai=1` (simulation).
- Pastille, phrase et panneau réutilisables par l’écran Poste (en-tête) et par la carte « Se connecter » d’Intervenir :
  `import { mountMachineAccount } from './machine/panel.js'` puis `mountMachineAccount(hôte, ctx, { target, show:
  'pill' | 'sentence' | 'both', size })` ; le composant suit `machine.account.watch`, ne repeint que si le texte change, ouvre
  le panneau au clic et rend `{ setTarget, destroy }`. `machinePill`, `openMachineAccountPanel` et `watchMachineAccount` restent
  exportés. Le panneau et le composant chargent leur feuille si besoin ; toutes leurs règles portent `[data-page="machine"]`
  sur leur racine. Les champs portent `data-policy` avec les noms de contrôles de Domenia 1 (`TxtMachineAdminUser`, `PwdMachineAdmin`,
  `BtnSetMachineCredential`, `BtnClearMachineCredential`, `BtnRevealMachineAdmin`) pour la politique centrale des éléments
  d’interface (PAR-044) quand elle existera.

## 19. Tests écrits (exécutés à la fin, dans la VM)

`tests/Domenia.Tests/SchemaTests.cs` (statut, refus avant lecture, lecture et étapes, liste, filtre nom ou description
seulement, classe et note du filtre recommandé, attribut, insertion, arguments, mode annuaire, seconde lecture refusée, arrêt
au-delà du budget, schéma lié à la session, règles, boucle bornée), `LdapFilterTests.cs` (erreurs et positions, assertions,
index, analyse, réécriture, classes écartées par objectCategory, insertion), `MachineAccountTests.cs` (libellés, formes,
verdicts, cascades, pause par place, baux, secrets, état, compte saisi, essai, candidat sans effet sur la pause, opération
refusée pendant la pause, veille, recherche, service et `SecureString`, mode annuaire), `PlatformTests.cs` (registre).
Scénarios E2E : `tests/e2e/schema/` (lecture, filtre du catalogue, analyse, compte poste, panneau en mode annuaire qui
efface le mot de passe).
