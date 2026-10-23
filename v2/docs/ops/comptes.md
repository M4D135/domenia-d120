# Domenia 2 — écran Comptes : opérations du pont

Contrat des opérations de l’écran **Comptes** (`web/js/pages/comptes.js`, route `#/comptes`), au même format que
[`../OPERATIONS.md`](../OPERATIONS.md) : conventions communes (§ 1), enveloppe, règles JSON, classes, codes d’erreur et
admission y sont définis et valent ici. Les écritures suivent le circuit de [`../WRITES.md`](../WRITES.md) : l’écran ne
déclare que des **plans** (des lectures) et l’exécution passe toujours par `write.execute`. Réalisé le 22 octobre 2026
(lot `comptes`, branche `v2-page/comptes`), repris le même jour après la critique indépendante (`CRITIQUE-1.md`) : aperçu
collectif scellé par le moteur, pauses par clé de compte, « Changer de compte », réglages de `Domenia.config.json`, onglet des
accès relu sans jamais effacer une saisie. Tests écrits, non exécutés (décisions de David du 21/10 et du 22/10 : à la toute
fin) ; la VM ne sert qu’à compiler.

## 1. Fonctions couvertes

| Domenia 1 | Fonction | Où dans Domenia 2 |
|---|---|---|
| CPT-001 à CPT-021 | Comptes utilisés par Domenia : accès à revoir (pastille de l’en-tête de l’écran), autre compte après un refus, contexte, baux, comptes en service et en mémoire, comptes secondaires Postes et Secrets, essai sur un poste, identifiants mémorisés, coffre, changer de compte, droits et transports, validation | onglets « Accès de Domenia » et « Droits et transports » ; `accounts.access.*`, `accounts.connection.correct`, `accounts.connection.switch`, `accounts.remembered.forget`, `accounts.requirements`, `accounts.transports` |
| FIC-012 | Déverrouiller | `accounts.unlock.plan` (circuit de référence, inchangé), depuis le détail, le menu d’une ligne ou un lot |
| FIC-013 | Activer ou désactiver (utilisateurs) | `accounts.enable.plan`, `accounts.disable.plan` |
| FIC-014 | Réinitialiser le mot de passe | `accounts.password.plan` (mot de passe en `SecureString`, § 6) |
| FIC-016 | Expiration du compte | `accounts.expiration.plan` |
| FIC-017 | Imposer un nouveau mot de passe | `accounts.mustChange.plan` |
| FIC-040, FIC-045 | Lire les verrouillages (4740) et refus de Domenia juste avant | `accounts.lockouts` |
| FIC-043, FIC-048 | État calculé, bandeau support | `accounts.detail` (`state`, `band`) |
| TRV-229 | Aperçu exact d’une opération collective (comptes), scellé par le moteur ; cibles décochables, copie en CSV | `accounts.batch.preview`, `accounts.batch.confirm`, puis `accounts.batch.plan` par cible |

## 2. Récapitulatif

| Opération | Classe (simulation · annuaire) | Arguments | Résultat |
|---|---|---|---|
| `accounts.list` | `LocalRead` · `NetworkRead` | aucun | comptes du périmètre de la section (§ 3.1) |
| `accounts.scope.get` | `LocalRead` | aucun | périmètre de la section ou `null` (§ 3.2) |
| `accounts.scope.set` | `LocalWrite` | `{ dn, subtree }` | périmètre choisi (§ 3.2) |
| `accounts.scope.reset` | `LocalWrite` | aucun | périmètre après retour à l’OU de travail |
| `accounts.detail` | `LocalRead` · `NetworkRead` | `{ dn }` | détail d’un compte (§ 3.3) |
| `accounts.lockouts` | `NetworkRead`, servie en simulation | `{ dn, hours? }` | rapport des verrouillages (§ 3.4) |
| `accounts.batch.preview` | `LocalRead` · `NetworkRead` | `{ action, dns, date?, ticket? }` | aperçu exact et scellé d’une action par lot (§ 3.5) |
| `accounts.batch.cancel` | `Local` | `{ ticket }` | `{ cancelled }` : arrête la lecture d’un aperçu (panneau fermé) |
| `accounts.batch.confirm` | `Local` | `{ id, typedCount? }` | lot scellé confirmé (nombre revérifié) |
| `accounts.batch.plan` | `LocalRead` · `NetworkRead` | `{ id, index }` | `{ plan, token }` d’une cible scellée, une seule fois |
| `accounts.enable.plan` | `LocalRead` · `NetworkRead` | `{ dn }` | `{ plan, token }` (§ 4) |
| `accounts.disable.plan` | `LocalRead` · `NetworkRead` | `{ dn }` | `{ plan, token }` |
| `accounts.mustChange.plan` | `LocalRead` · `NetworkRead` | `{ dn }` | `{ plan, token }` |
| `accounts.expiration.plan` | `LocalRead` · `NetworkRead` | `{ dn, date }` | `{ plan, token }` |
| `accounts.password.plan` | `LocalRead` · `NetworkRead` | `{ dn, password, mustChange, unlock }` | `{ plan, token }` |
| `accounts.access.state` | `LocalRead` | aucun | comptes de Domenia (§ 5.1) |
| `accounts.access.revision` | `Local` | aucun | révision de l’état et compteurs de la pastille (§ 5.1) |
| `accounts.access.test` | `NetworkRead`, servie | `{ usage, login, password }` | validation (§ 5.2) |
| `accounts.access.activate` | `NetworkRead`, servie | `{ usage, login, password }` | `{ result, state }` |
| `accounts.access.clear` | `LocalRead` | `{ usage }` | état |
| `accounts.access.recover` | `NetworkRead`, servie | `{ id, login, password, lease, minutes?, target? }` | `{ result, state }` |
| `accounts.access.dismiss` | `Local` | `{ id }` | état |
| `accounts.access.forget` | `LocalRead` | `{ key }` | état |
| `accounts.access.forgetAll` | `LocalRead` | aucun | état |
| `accounts.access.cancel` | `Local` | aucun | `{ cancelled }` |
| `accounts.access.tryRemote` | `NetworkRead`, servie | `{ computer }` | essai (§ 5.3) |
| `accounts.connection.correct` | `NetworkRead`, servie | `{ password }` | validation |
| `accounts.connection.switch` | `NetworkRead`, servie | `{ login, password }` | `{ result, identity, epoch }` (§ 5.2) |
| `accounts.remembered.forget` | `LocalWrite` | `{ usage }` | état |
| `accounts.requirements` | `Local` | aucun | table des droits (§ 5.4) |
| `accounts.transports` | `LocalRead` | aucun | politique de transport (§ 5.5) |

Aucune opération de l’écran n’est de classe `Write` (un test le vérifie). `LocalRead` des opérations `accounts.access.clear`,
`forget` et `forgetAll` : elles lisent les reçus pour refuser tout changement de compte pendant une écriture à vérifier ;
`accounts.transports` lit `Domenia.config.json` à côté de l’exécutable (une fois) et l’autorisation d’intervention en mémoire.

## 3. Lectures des comptes

### 3.1 `accounts.list`

Comptes utilisateurs du périmètre de la section (§ 3.2), triés par nom (sans accent ni casse), **5 000 au plus**
(`truncated`). **Jamais tout le domaine** : un périmètre égal à la racine ne lit rien (`tooWide` = `true`, `rows` vide) et
propose les OU qui contiennent des comptes (`suggestions`). Une OU sans utilisateur (l’OU de travail par défaut est `Postes`)
répond de même avec ses suggestions.

| Champ | Contenu |
|---|---|
| `scope` | `{ dn, label, path, subtree, origin }`, `origin` = `section` (choix de l’écran) ou `working` (OU de travail) |
| `tooWide` | `true` si le périmètre est la racine du domaine : rien n’est lu |
| `readAt`, `controller`, `simulated` | instant de la lecture, contrôleur lu, données fictives |
| `policy` | `{ maxPasswordAgeDays, minPasswordLength, passwordHistory, lockoutThreshold, lockoutMinutes, observationMinutes, label }` |
| `counts` | `{ total, enabled, disabled, locked, lockToCheck, lockExpired, passwordExpired, passwordExpiring, mustChange, neverExpires, accountExpired, accountExpiring, privileged, neverLoggedOn, stale }` : les états ne comptent que les comptes activés |
| `rows` | lignes (ci-dessous) |
| `truncated`, `limit` | liste coupée à `limit` (5 000) |
| `suggestions` | `[{ dn, name, path, users }]`, 6 au plus, quand aucune ligne |

Ligne : `dn`, `guid`, `sam`, `name`, `upn`, `title`, `department`, `office`, `ou` (OU parente), `enabled`, `lock`
(`unlocked`, `locked`, `toCheck`, `expired`), `lockedAt`, `badPasswordCount`, `password` (`valid`, `mustChange`,
`neverExpires`, `expired`, `expiring` : sous 14 jours), `passwordLastSet`, `passwordExpiresAt`, `passwordEstimated`,
`accountExpiresAt`, `accountExpired`, `lastLogon`, `privileged` (`adminCount` = 1), `status`, `statusLabel`, `tone`.

Règles de Domenia 1 (`Get-DomeniaAccountState`) : verrouillé seulement si le bit 0x10 de
`msDS-User-Account-Control-Computed` le dit ; un `lockoutTime` seul donne `toCheck`, jamais `locked` ; échu (`expired`)
quand le contrôleur dit déverrouillé et que `lockoutTime` reste renseigné. Expiration du mot de passe :
`msDS-UserPasswordExpiryTimeComputed`, sinon estimée par `maxPwdAge` (`passwordEstimated`). État principal, du plus urgent :
désactivé, verrouillé, à vérifier, compte expiré, mot de passe expiré, à changer, expire bientôt, actif.

Erreurs : `arguments.invalid`, `source.unavailable`, `operation.cancelled`. Simulation : 140 à 360 ms
(`latency/screen/accounts/list`).

### 3.2 Périmètre de la section

Décision de David du 21/10 : l’OU de travail est le défaut des sections sans choix propre, « surcharge par section prévue
ensuite ». Comptes la réalise : `accounts.scope.set { dn, subtree }` vérifie l’OU dans l’**index local** (jamais le réseau),
refuse la racine (`scope.tooWide` : « Choisissez une OU : la liste des comptes n’est jamais lue sur tout le domaine. »), un
autre domaine (`scope.outsideDomain`) ou une OU inconnue (`scope.unknown`), garde le choix pour la session et le mémorise par
domaine dans les préférences locales (`accounts.scope.<SHA-256 de la racine>` = `{ dn, subtree }`). `accounts.scope.get`
relit ce choix (vérifié dans l’index local), sinon l’OU de travail ; `accounts.scope.reset` l’oublie. Journal des opérations :
« Périmètre des comptes : *chemin* ». Une préférence illisible ou une OU disparue retombe sur l’OU de travail (tracé).

### 3.3 `accounts.detail`

`{ dn }` → `account` (une ligne du § 3.1), `identity` (`cn`, `displayName`, `givenName`, `surname`, `mail`, `telephone`,
`employeeId`, `manager { dn, name }`, `description`, `sid`, `created`, `changed`, `usn`), `state` (`disabled`, `lock`,
`lockedAt`, `lockEndsAt`, `badPasswordCount`, `passwordExpired`, `passwordNeverExpires`, `passwordNotRequired`,
`smartCardRequired`, `privileged`, `accountExpiresAt`, `accountExpired`, `lastLogon`), `passwordInfo` (`lastSet`, `expiresAt`,
`estimated`, `class`, `label`, `ageDays`, `maxAgeDays`, `percent` de la validité écoulée, `tone`), `band` (ou `null`),
`actions`, `groups` (`count`, `primaryGroupId`, `privileged` par nom), `policy` (avec `complexityRequired`, bit 0x1 de
`pwdProperties`), `controller`, `readAt`, `simulated`, `resetDefaults` (`mustChange` lu dans `Security.ForcePasswordChangeOnReset`
de `Domenia.config.json`, vrai par défaut comme Domenia 1 ; `source` ; `revealSeconds` = 5 : un mot de passe affiché se masque
de lui-même, TRV-219).

**Bandeau support** (FIC-048) : seulement ce que le contrôleur a répondu, le plus urgent en titre — verrouillé depuis
(heure, durée écoulée, fin prévue selon la stratégie), verrouillage à vérifier, désactivé, compte expiré, mot de passe expiré,
à changer, expirant sous 14 jours (date calculée ou estimée), verrouillage récent levé, essais erronés récents — avec ses
faits (`label`, `value`, `tone`, `source`, `limit` : « Compteur propre à ce contrôleur : il n’est pas répliqué. ») et ses
actions (`unlock`, `lockouts`, `reset`). `null` quand il n’y a rien à dire.

**Actions** : `{ unlock, enable, disable, resetPassword, mustChange, expiration, lockouts }`, chacune `{ available, reason }` :
pas verrouillé ; déjà activé ou désactivé ; **jamais le compte de session** (« C’est votre compte de session : le désactiver
vous retirerait l’accès à l’annuaire. ») ; `krbtgt` jamais écrit ; changement imposé sans effet pour un mot de passe qui
n’expire jamais ; SID illisible pour le journal.

Erreurs : `arguments.invalid`, `accounts.unknown` (« Ce nom distinctif ne désigne aucun compte utilisateur… : rien n’a
été lu. »), `source.unavailable`.

### 3.4 `accounts.lockouts`

FIC-040 et FIC-045 : sur geste explicite, les événements **4740** du journal Sécurité de l’**émulateur PDC** (résolu par
`fSMORoleOwner`, sinon le contrôleur lié, ce qui est dit) pour le **seul SID** du compte, fenêtre `hours` de 1 à 720
(168 par défaut), **200 événements** au plus (troncature signalée), puis le rapprochement de chaque verrouillage avec les
refus d’authentification que Domenia a enregistrés (120 s avant, 5 s de décalage toléré, compte non attribué signalé) : une
**piste**, jamais une preuve.

Résultat : `account { dn, name, sam, sid }`, `server`, `serverSource` (`pdc`, `bound`), `serverLabel`, `hours`, `from`, `to`,
`maxEvents`, `truncated`, `state` (`read`, `refused`, `unavailable`), `events [{ at, callerComputer, controller, domenia { near,
seconds, ambiguous, label } }]` (du plus récent), `origins [{ computer, count, share }]`, `facts` (état calculé, dernier
verrouillage, échecs, verrouillages journalisés, postes à l’origine avec l’hypothèse « un poste récurrent suggère une session,
un lecteur réseau ou un service qui utilise encore un ancien mot de passe », refus de Domenia), `verdict`, `summary`,
`simulated`. **Un refus ou un journal injoignable ne signifie jamais « aucun verrouillage »** (le fait le dit, avec le droit
« Lecteurs des journaux d’événements »).

Erreurs : `arguments.invalid` (fenêtre hors de 1 à 720), `accounts.unknown`, `accounts.sidInvalid` (« SID de compte invalide :
aucune lecture du journal. », vérifié **avant** toute lecture), `source.unavailable`. Simulation : événements tirés de la
sous-suite `screen/accounts/lockouts/<GUID>` (déterministes), poste de l’utilisateur (`managedBy`) puis postes de son site
(un portable s’il y en a) ; 450 à 1 100 ms.

### 3.5 `accounts.batch.preview`

TRV-229 : `{ action, dns, date? }`, `action` ∈ `unlock`, `enable`, `disable`, `mustChange`, `expiration` ; `dns` 1 à
5 000 DN valides ; `date` (`AAAA-MM-JJ` ou `null`) seulement pour `expiration`. Relit chaque candidat et répond :

`action`, `actionLabel`, `title`, `kind` (type d’écriture), `planOperation` (type de plan de chaque cible), `count`,
`confirmation` (`none`, `simple` pour une cible, `typed` dès deux : saisir le nombre), `typedCount`, `targets [{ dn, guid, name,
sam, change, before, after, index }]` (position conservée), `shown` (12), `excluded [{ dn, name, reason }]`, `excludedGroups
[{ reason, count }]` (plus grand d’abord), `excludedCount`, `impact`, `risks`, `lines`, `details` (liste complète), `limit`
(20 000), `date`, `simulated`, et `batch` : le **plan collectif scellé** par le moteur (`AccountsBatchSeals`) `{ id (32
hexadécimaux), fingerprint (SHA-256 de « action|date|nombre|guid,guid,… », GUID dans l’ordre), count, typedRequired,
expiresAt (10 min, glissant), confirmed }` (WRITES.md § 1 : « une écriture collective aura son propre plan avec un aperçu
exact »). `ticket` (8 à 40 lettres, chiffres ou tirets) nomme la lecture : `accounts.batch.cancel { ticket }` l’arrête quand
la page ferme le panneau (`operation.cancelled`, rien n’a été préparé). Exclusions : compte introuvable, doublon, `krbtgt`, **compte à privilèges** (à traiter seul,
avec la saisie de son nom), rien à faire (pas verrouillé, déjà activé…), **compte de session** pour une désactivation,
changement sans effet, au-delà de la limite (nommés jusqu’à 100 puis comptés). Rien n’est écrit.

`accounts.batch.confirm { id, typedCount }` : le moteur **revérifie le nombre saisi** quand le lot l’exige ; un nombre faux
dépense le lot (`accounts.batchCountMismatch`, l’aperçu est à relire). `accounts.batch.plan { id, index }` ne rend le plan
d’une cible que pour un lot confirmé (`accounts.batchUnconfirmed`), **une seule fois par cible** (`accounts.batchIssued`), après
avoir relu l’objet et comparé son GUID à celui du sceau (`accounts.batchTargetChanged`) ; un compte qui exigerait la saisie de
son nom est refusé (`accounts.batchTypedName`, à traiter seul). Autres refus : `accounts.batchUnknown`, `accounts.batchExpired`,
`arguments.invalid` (identifiant, rang). L’exécution reste `write.execute`, avec le jeton du plan de la cible, son reçu et sa
relecture.

Déroulé dans la page (`web/js/pages/comptes/batch.js`, composant local) : aperçu scellé (empreinte affichée), cibles
**décochables** (un compte retiré rend le sceau caduc : « Calculer le nouvel aperçu » scelle la liste des comptes gardés),
**copie en CSV** de l’aperçu (cibles et exclusions, cellules `= + - @` neutralisées), confirmation du kit (`confirmWrite`,
saisie du nombre de comptes dès deux) puis `accounts.batch.confirm`, puis pour chaque cible `accounts.batch.plan` et **une**
exécution `write.execute`, l’une après l’autre ; un plan refusé (« rien à faire », préconditions changées) passe à la suivante,
**une issue incertaine arrête la suite**, un lot expiré aussi ; « Arrêter après le compte en cours » n’interrompt jamais
l’écriture en cours ; bilan avec un lien vers chaque reçu. Rien n’est rejoué. La date d’une expiration par lot se saisit en
JJ/MM/AAAA (champ français et calendrier de l’écran), une date passée reste admise avec son risque.

## 4. Écritures (plans)

Résultat commun `{ plan, token }` (`OPERATIONS.md` § 12.1), exécution par `write.execute`, reçus par `write.receipts.*`.
Refus communs : `source.unavailable`, `write.targetPending`, `receipt.unavailable`, `write.targetUnknown` (« Ce nom distinctif
ne désigne aucun compte utilisateur de l’annuaire fictif : aucune écriture préparée. »), `accounts.protectedAccount`
(`krbtgt`, compte de session pour une désactivation). Saisie du nom (`sAMAccountName`) exigée pour un compte à privilèges
(`adminCount` = 1), confirmation simple sinon.

| Plan | Type | Changements | Préconditions relues | Relecture | Retour arrière |
|---|---|---|---|---|---|
| `accounts.unlock.plan` | `account.unlock` | `lockoutTime` → 0 | `OPERATIONS.md` § 12.2 | `lockoutTime` = 0 et bit 0x10 absent | non |
| `accounts.enable.plan` | `account.enable` | `userAccountControl` : bit 0x2 retiré | même GUID et DN, UAC inchangé ; déjà activé : rien d’écrit | bit 0x2 absent | nouveau plan « Désactiver » |
| `accounts.disable.plan` | `account.disable` | `userAccountControl` : bit 0x2 ajouté | idem | bit 0x2 présent | nouveau plan « Activer » |
| `accounts.mustChange.plan` | `account.mustChangePassword` | `pwdLastSet` → 0 | `pwdLastSet` inchangé ; déjà 0 : rien d’écrit | `pwdLastSet` = 0 | non |
| `accounts.expiration.plan` | `account.expiration` | `accountExpires` → 0 h locale du jour choisi (FILETIME), ou 0 (jamais) | jour d’expiration inchangé | jour local relu = jour demandé | nouveau plan avec l’ancienne valeur |
| `accounts.password.plan` | `account.resetPassword` | `unicodePwd` (réinitialisation, **aucune valeur dans le plan**), `pwdLastSet` (toujours, avec sa valeur brute « avant ») → 0 si changement exigé, sinon posé par le contrôleur, `lockoutTime` → 0 si « Déverrouiller ensuite » et verrouillé | `pwdLastSet` inchangé (toute réinitialisation), **mot de passe encore en mémoire** pour ce plan | `pwdLastSet` = 0 (exigé) ou **postérieur à sa valeur « avant »** relue sur le contrôleur (jamais l’horloge du poste), `lockoutTime` = 0 si demandé | non |

Erreurs propres : `write.nothingToDo` (« Ce compte est déjà activé : aucune écriture à préparer. », « Le changement de mot de
passe est déjà imposé… », « Le mot de passe de ce compte n’expire jamais : un changement imposé resterait sans effet. »,
« Ce compte expire déjà à cette date… »), `arguments.invalid` (« « date » doit être une date AAAA-MM-JJ (au plus dans
50 ans) ou null. » ; mot de passe de 1 à 256 caractères sans caractère de contrôle), `accounts.passwordPolicy` (§ 6).

Risques dits : identité du demandeur et canal sûr (mot de passe), compte désactivé, verrouillé (avec ou sans
« Déverrouiller ensuite »), compte de service (`svc-`), administrateur intégré (RID 500), Invité (RID 501), connexion récente,
date passée (« le compte sera expiré dès l’écriture »), historique vérifié par le contrôleur, carte à puce exigée.

## 5. Comptes de Domenia (CPT)

### 5.1 `accounts.access.state`

`connection` (CPT-006 : `connected`, `identity`, `displayName`, `mode` = `demo|windows|explicit`, `modeLabel`, `controller`,
`site`, `domain`, `netbios`, `since`, `authentication`, `detail`, `correction { available, reason }`, `relogin { available,
reason }`), `identities` (CPT-012 : annuaire, postes, secrets), `pending` (CPT-001 : `[{ id, scope, scopeLabel, operation,
target, kind, kindLabel, at, interactive, remembered }]`, 16 au plus, un par ressource et cible ; le plus ancien avis
d’arrière-plan part d’abord ; `remembered` : identifiant mémorisé pour cette ressource, proposé dans « Utiliser un autre
compte »), `pendingLimit`, `inUse` (CPT-010 : `[{ resource, resourceKey, account, origin, state, stateTone, action { id, label,
argument } }]` ; « Aucun refus enregistré. », « En pause après un refus : *où le corriger*. » ou « Même compte que … (SID
confirmé par l’annuaire). », jamais « valide » ; les pauses sont rangées **par clé de compte**, comme Domenia 1 : un refus
d’authentification met en pause toutes les ressources qui utilisent ce compte), `memory`
(CPT-011 : `[{ key, resource, account, origin, remaining, minutes, usable, state, stateTone }]`), `remote` et `secrets`
(CPT-013, CPT-014 : `usage`, `label`, `account`, `active`, `activatedAt`, `controller`, `status`, `statusTone`, `remembered
{ account, lastUsedAt }`, `resources`), `validation` (CPT-021 : `busy`, `usage`, `label`, `startedAt`, `timeoutSeconds`),
`lastTrial`, `lease` (`defaultMinutes` 30, `minMinutes` 1, `maxMinutes` 480), `vault { available, reason }`, `refusals`,
`generation`, `summary`, `simulated`, `revision` (change à chaque changement d’état), `epoch` (époque de session : une nouvelle
avec « Changer de compte »), `revealSeconds` (5). Les comptes temporaires expirés sont oubliés à chaque lecture (balayage,
journal).

`accounts.access.revision` (classe `Local`, noms et nombres seulement) : `{ revision, leaseMinute, pending, oldestPendingId,
oldestPendingLabel, temporaries, paused, validating, epoch }`. La page la lit **chaque seconde** quand l’onglet est affiché et
ne relit l’état que s’il a changé (CPT-010) ; l’en-tête de l’écran la lit toutes les 2 s pour sa pastille « N accès à revoir »
(CPT-001 : info-bulle avec la plus ancienne demande, clic qui l’ouvre). L’onglet est construit une fois ; seules ses zones
d’état sont repeintes, **jamais un formulaire** : un identifiant ou un mot de passe en cours de saisie n’est jamais effacé
(CPT-006, CPT-016), un champ tapé n’est plus prérempli.

### 5.2 Validations

Une seule à la fois (`accounts.validationBusy`), **12 s** au plus (`timeout`), annulable (`accounts.access.cancel` : le compte
précédent est conservé), refusée pendant une écriture à vérifier (`accounts.writePending`). Le **contexte** est contrôlé avant
tout appel (CPT-003, `accounts.credentialContext`) : un compte local (`POSTE\compte`, `.\compte`) seulement pour son poste,
jamais pour l’annuaire, LAPS ou BitLocker ; `POSTE\compte` d’un autre poste ou d’un domaine inconnu refusé (« pour un compte
d’un autre domaine approuvé, saisissez compte@domaine ») ; un nom sans domaine refusé. Résultat (`AccessValidation`) :
`success`, `kind` (`ok`, `unknownAccount`, `badCredentials`, `disabled`, `locked`, `accountExpired`, `passwordExpired`,
`mustChange`, `workstationUnreachable`, `timeout`, `cancelled`, `identityMismatch`, `input`), `message` et `hint` (textes de
`Get-DomeniaLoginFailureText`), `identity` (compte réellement lié), `controller`, `tone`, `rightsNote` (« Droits sur la
ressource non certifiés par ce test : seule l’identité est vérifiée »), `simulated`, `at`. Un refus d’identifiants est gardé
(64 au plus) pour le diagnostic des verrouillages.

- `accounts.access.test` : valide sans activer. `accounts.access.activate` : valide puis remplace **seulement** les comptes
  temporaires de ses ressources (`Remote`, ou `ReadLaps` et `ReadBitLocker`) et leurs refus ; l’identifiant (jamais le mot de
  passe) est mémorisé par domaine (`accounts.remembered.<usage>.<16 hex>` = `{ account, lastUsedAt }`).
- `accounts.access.recover` (CPT-002) : autre compte pour la ressource d’un accès à revoir, avec son **bail** (`inactivity` :
  1 à 480 min, `Security.AlternateCredentialIdleMinutes` ou 30 par défaut ; `session` ; `once`), gardé pour cette ressource (et
  ce poste : clé `RemoteLocal|POSTE` pour un compte local, complété par le nom du poste) ; les accès de la même ressource sont
  clos ; **rien n’est rejoué**. L’identifiant est mémorisé par usage (`laps`, `bitlocker`, `remote`, `directory`,
  `operation.<empreinte>`, `remoteLocal.<empreinte du poste>`) : LAPS et BitLocker préremplissent le compte Secrets, un compte
  local d’un poste ne préremplit **jamais** le compte Postes (CPT-016).
- `accounts.access.forget` (CPT-011) rend la main au compte configuré **et efface les refus liés** ; `accounts.access.forgetAll`
  (CPT-005) est précédé d’une confirmation dans la page. Une opération déjà partie garde sa copie et n’est pas interrompue.
- `accounts.connection.switch` (CPT-007, « Changer de compte » sans fermer Domenia) : refusé pendant une écriture à vérifier ;
  contexte contrôlé (jamais un compte local), **une** authentification du compte proposé qui ouvre la nouvelle session (même
  domaine), puis une **nouvelle époque** : comptes Postes, Secrets et temporaires, accès à revoir, pauses, refus et dernier essai
  de la session précédente sont oubliés, tout résultat d’une époque antérieure est écarté (`accounts.epochChanged`).
  Le formulaire s’ouvre prérempli avec le compte courant (`#/comptes?vue=acces&compte-connexion=changer`) ; la page émet
  `domenia:session-changed` et relit son en-tête et sa liste. Simulation : la session fictive prend ce compte (mémoire
  seulement, droits estimés par `adminCount`) ; mode annuaire : `IAccountsAccessReader.OpenSessionAsync` (vague 3) ;
  `accounts.reloginUnavailable` sans lecteur.
- `accounts.connection.correct` (CPT-008) : même identité seulement (clé de compte) ; puis
  `IAccountsAccessReader.SwapConnectionPasswordAsync` remplace le secret de la session (`SecureString` jusqu’à l’API Windows),
  arrête les lectures parties avec l’ancien et dit si une autre copie du mot de passe refusé subsiste (la pause est alors
  conservée) ; la pause de ce seul compte est levée. Refusé en simulation (« la session n’utilise aucun mot de passe ») et pour
  une session Windows (`accounts.correctionUnavailable`).
- Simulation : l’annuaire fictif ne contient **aucun mot de passe** : seuls le compte et son état sont vérifiés (inconnu,
  désactivé, verrouillé, expiré, mot de passe expiré ou à changer), et la réponse le dit ; 700 à 1 500 ms.

### 5.3 `accounts.access.tryRemote`

CPT-015 : une lecture CIM légère (`Win32_OperatingSystem.Caption`) d’**un** poste, avec le compte que prendront les opérations
sur les postes (compte local temporaire de ce poste, compte temporaire, compte Postes, sinon compte de connexion), passé à la
lecture comme **copie `SecureString` en lecture seule** (`RemoteProbeCredential`, détruite après l’essai ; le bail d’un compte
temporaire compte cette utilisation, CPT-004) ; ni balayage, ni ping, ni console, aucun repli intrusif ; un essai à la fois
(`accounts.trialBusy`), 30 s au plus ; un compte que l’annuaire ne connaît pas est refusé (`authRejected`), jamais « OK ». Verdicts
(`Get-DomeniaRemoteAccessTrialVerdict`) : `adminOk` (seul un succès explicite dit « Accès administrateur OK », avec le système),
`denied`, `rejected`, `accountState`, `unreachable`, `unknown`. Journal des opérations : « Essai du compte poste sur *poste* ».

### 5.4 `accounts.requirements`

CPT-019 (point 46 de Domenia 1, `Get-DomeniaOperationRequirement` sur la table unique des opérations) : `rows [{ id, label,
family, provider, effect, effectLabel, resource, resourceLabel, account, right, access, known }]`, `families`,
`unknownText`. Une opération hors de la table dit « Droit non documenté pour cette opération : lisez le code d’erreur natif. » ;
un droit n’est jamais deviné. Filtrable par famille, exportable en CSV dans la page.

### 5.5 `accounts.transports`

CPT-020 (`Get-DomeniaTransportPolicy`) : `rows [{ id, transport, usage, ports, state, stateTone, rule, intrusive }]` pour LDAP,
CIM/DCOM, CIM/WSMan, WTS, partage ADMIN$, Planificateur, PsExec, selon les réglages `Remote.UseCim`, `Remote.UseWinRM`,
`Remote.UsePsExecFallback`, `Remote.UseTaskFallback` de `Domenia.config.json` (`AccountsConfigurationFile`, Domenia.Store, lu une
fois hors du fil de l’interface ; fichier absent ou inutilisable : défauts de Domenia 1, dits dans `settingsSource`, jamais le
contenu du fichier) ; `consentActive`, `consentText` (l’autorisation d’intervention en cours, publiée par l’écran qui l’accorde
dans `InterventionConsentBoard` : un poste, 5 min, avec son heure de fin) ; `settingsSource` ; `note`. Rien ici ne modifie un
réglage de Windows.

## 6. Mots de passe et secrets

- La page n’envoie un mot de passe qu’au geste « Préparer » (réinitialisation) ou « Activer / Tester / Valider » (comptes) ;
  les champs sont vidés aussitôt. Le moteur le convertit en **`SecureString` en lecture seule** dès la lecture des arguments
  (`AccountsArguments.GetPassword`) ; la chaîne JSON du message reste en mémoire gérée jusqu’au ramasse-miettes (comme le
  champ texte de Domenia 1, SE-16) : elle n’est **ni journalisée, ni copiée, ni renvoyée**.
- Réinitialisation : la stratégie est vérifiée sur une copie temporaire des caractères, effacée aussitôt
  (`PasswordSecrets.Inspect`) — longueur minimale du domaine (1 au moins) ; trois classes sur quatre, ni le compte ni une partie
  du nom affiché **seulement si le domaine exige la complexité** (`pwdProperties`, sinon le contrôleur tranche, comme Domenia 1)
  — refus `accounts.passwordPolicy` qui cite les règles, **jamais le mot de passe**. La page applique les mêmes règles en direct
  (`web/js/pages/comptes/rules.js`). Le plan dit « Nouvelle valeur
  saisie, ni affichée ni conservée » (aucune valeur brute) ; le secret est gardé **pour ce seul plan** (`PasswordSecrets`,
  5 minutes, une seule prise, détruit à la prise, au remplacement, à l’expiration — une minuterie l’efface à son échéance même si
  rien ne le demande — et avec l’exécuteur, libéré par `EngineContext.Dispose` via `WriteExecutors.Dispose`). Sans lui,
  l’exécution est refusée avant tout envoi (« Le nouveau mot de passe n’est plus en mémoire… Rien n’a été envoyé. »).
- Un mot de passe affiché (œil, mot de passe généré) se masque de lui-même au bout de 5 s ; une frappe ou un second clic le
  masque aussitôt (Domenia 1 TRV-219).
- Comptes secondaires et temporaires : copies `SecureString` en lecture seule, détruites quand elles sont remplacées, oubliées
  ou expirées ; seuls les **noms** atteignent la page et les préférences. Coffre Windows : non branché (§ 9).

## 7. Mode annuaire (vague 3)

Lecteur `AdAccountsReader` (`IAccountsReader`, `IAccountsAccessReader`) et exécuteurs `AdAccount*Executor` dans
`Domenia.Ad`, sur la session et le contrôleur de l’annuaire (canal LDAP signé et scellé, Kerberos ou NTLM, aucun certificat
accepté à l’aveugle). Tout part du contrôleur de la session, sur geste de l’opérateur, borné à l’OU ; rien ne lit le domaine
entier.

### 7.1 Lectures

| Lecture | Base, portée, filtre | Attributs | Budget |
|---|---|---|---|
| Liste (`accounts.list`) | base = DN du périmètre, `OneLevel` ou `Subtree` ; `(&(objectCategory=person)(objectClass=user))` | `distinguishedName`, `objectGUID`, `objectSid`, `sAMAccountName`, `userPrincipalName`, `displayName`, `cn`, `title`, `department`, `physicalDeliveryOfficeName`, `userAccountControl`, `msDS-User-Account-Control-Computed`, `lockoutTime`, `badPwdCount`, `pwdLastSet`, `msDS-UserPasswordExpiryTimeComputed`, `lastLogonTimestamp`, `accountExpires`, `adminCount` | pages de 1 000, 5 000 objets au plus (`truncated`), 30 s ; attributs construits demandés objet par objet si le contrôleur refuse de les calculer en recherche étendue (repli : `toCheck`, jamais `locked`) |
| Stratégie | base = racine, `Base`, `(objectClass=domainDNS)` | `maxPwdAge`, `minPwdLength`, `pwdHistoryLength`, `lockoutThreshold`, `lockoutDuration`, `lockOutObservationWindow`, `pwdProperties` (complexité) | une lecture par session, gardée en mémoire |
| Détail (`accounts.detail`) | base = DN, `Base` | ceux de la liste + `givenName`, `sn`, `mail`, `telephoneNumber`, `employeeID`, `manager`, `description`, `whenCreated`, `whenChanged`, `uSNChanged`, `memberOf`, `primaryGroupID` ; nom du responsable : base = DN du `manager`, `displayName` | 10 s |
| Candidats d’un lot | une lecture `Base` par DN, en série | ceux de la liste | 5 000 DN au plus, 200 ms par DN au plus en moyenne attendue ; annulable |
| Index des OU (`accounts.scope.*`) | base locale (`IOrganizationalUnitIndex`) | — | jamais le réseau |

`objectGUID` et `objectSid` lus en binaire et convertis ; dates FILETIME (`pwdLastSet` = 0 : à changer ; `accountExpires` 0 ou
`0x7FFFFFFFFFFFFFFF` : jamais). Le compteur `badPwdCount` est propre au contrôleur lu (dit dans le bandeau).

### 7.2 Verrouillages (`accounts.lockouts`)

1. SID vérifié `S-1-5-21-…` (quatre sous-autorités) **avant** toute lecture.
2. Émulateur PDC : `fSMORoleOwner` de la racine du domaine → `CN=NTDS Settings,CN=<serveur>,CN=Servers,…` → `dNSHostName` du
   serveur ; sinon le contrôleur lié, dit dans `serverLabel`.
3. Journal `Security` du PDC par `System.Diagnostics.Eventing.Reader.EventLogReader` (`EventLogSession` avec le compte de
   connexion en `SecureString`), requête XPath
   `*[System[EventID=4740 and TimeCreated[timediff(@SystemTime) <= <fenêtre ms>]]] and *[EventData[Data[@Name='TargetSid']='<SID>']]`,
   200 événements au plus (≤ 500), le plus récent d’abord ; `TargetDomainName` porte le poste à l’origine.
4. `UnauthorizedAccessException` ou `EventLogException` d’accès refusé → `state` = `refused` ; RPC injoignable →
   `unavailable` ; aucune conclusion dans les deux cas. Accès réseau : 135/TCP puis RPC dynamiques du contrôleur ; droit :
   « Lecteurs des journaux d’événements » (`OperationRequirements` : `LockoutDiagnosis`). 30 s au plus.

### 7.3 Écritures

Une seule requête LDAP par écriture, sur le **même contrôleur** que la relecture des préconditions, écriture conditionnelle
quand c’est possible (`WRITES.md` § 6, étape 9) : codes 16, 19, 20 → `write.conflict` (non appliquée) ; refus de droits avant
tout changement → non appliquée ; toute autre issue après l’envoi → inconnue (jamais renvoyée).

| Type | Requête | Relecture |
|---|---|---|
| `account.unlock` | `ModifyRequest` : `lockoutTime` remplacé par 0 | `lockoutTime`, `msDS-User-Account-Control-Computed` |
| `account.enable`, `account.disable` | `ModifyRequest` conditionnelle : suppression de l’ancienne valeur de `userAccountControl` et ajout de la nouvelle (bit 0x2 seul changé) | `userAccountControl` |
| `account.mustChangePassword` | `pwdLastSet` remplacé par 0 | `pwdLastSet` |
| `account.expiration` | `accountExpires` remplacé (FILETIME du jour à 0 h locale, ou 0) | `accountExpires`, comparé par jour local |
| `account.resetPassword` | `ModifyRequest` : `unicodePwd` remplacé par la valeur `"<mot de passe>"` en UTF-16LE, construite depuis la `SecureString` dans un tableau d’octets effacé aussitôt après l’envoi (canal scellé obligatoire), puis `pwdLastSet` = 0 si exigé et `lockoutTime` = 0 si demandé, dans la **même** requête | `pwdLastSet` (0, ou postérieur au plan), `lockoutTime` |

Droits requis (`OperationRequirements`) : `WriteUnlock`, `WriteAccountDisabled`, `WriteExpirePassword`, `WriteExpiration`,
`WriteResetPassword` (droit étendu « Réinitialiser le mot de passe »). Labo : écritures réelles seulement dans
`OU=Domenia-Tests` de `cnamts.local` (décision du 21/10, vague 4).

### 7.4 Comptes de Domenia

- Validation (`ValidateAsync`) : `LdapConnection` vers le contrôleur de la session, `NetworkCredential(login, SecureString)`,
  `AuthType.Negotiate`, signature et scellement, **un seul** bind, 12 s ; `BindUser` = identité relue (`whoami` étendu, OID
  1.3.6.1.4.1.4203.1.11.3) et même domaine exigés, sinon « Identité AD non confirmée ». Aucune variante d’identité silencieuse.
  Compte local d’un poste : session CIM/DCOM (`System.Management.ConnectionOptions` avec `SecurePassword`, 5 s) et lecture de
  `Win32_ComputerSystem.Name`.
- Essai sur un poste (`ProbeAsync`) : `ManagementScope \\<poste>\root\cimv2` avec le compte des postes, `Win32_OperatingSystem`
  (`Caption`), délai de méthode 6 s, total 30 s ; codes d’erreur classés comme Domenia 1 (`Get-DomeniaErrorDecision`).
- Refus réels : les lectures de la vague 3 appellent `AccountAccess.RegisterRefusal(ressource, opération, cible, nature, clé de
  compte, interactif)` ; leurs comptes temporaires viennent de `AccountAccess` (bail prolongé au départ de chaque lecture).
- Correction du compte de connexion : même identité (clé de compte), remplacement du secret de la session, levée de la pause
  du seul compte (TRV-221).

## 8. Tests écrits (exécutés à la fin, dans la VM)

| Fichier | Couvre |
|---|---|
| `AccountsRulesTests` | verrouillage (`toCheck`, échu), ordre des états, dates calculées ou estimées, compteurs exacts, bandeau support, actions et raisons (compte de session, `krbtgt`), rapprochement des refus (120 s, 5 s), rapport des verrouillages (origines, lecture refusée), aperçu d’un lot (cibles, exclusions, saisie du nombre), stratégie du mot de passe sans le citer, plan de réinitialisation sans secret, secrets à usage unique et expirés, activation et désactivation, changement imposé, expiration (0 h locale, jamais = 0), contexte d’un compte proposé, baux, droits jamais devinés, transports |
| `AccountsBatchSealTests` | empreinte (ordre, action, date, nombre), confirmation par le nombre exact revérifiée et lot dépensé sur un nombre faux, une cible confirmée une seule fois, rang hors de l’aperçu, expiration et délai glissant, 16 lots au plus, ticket d’une lecture d’aperçu ; de bout en bout par le pont (plan refusé avant confirmation, trois écritures relues, jamais deux plans) ; bornes de l’aperçu (5 000 DN, doublon, `krbtgt`, compte à privilèges, DN inconnu) |
| `AccountsAccessTests` | pause par clé de compte sur toutes les ressources, « Oublier » efface les refus liés, identifiants mémorisés par usage (LAPS relu pour Secrets, compte local jamais pour Postes), essai sur un poste (inconnu refusé), refus pendant une écriture à vérifier, une validation et un essai à la fois avec annulation, changer de compte (nouvelle époque, session suivie, rien de la session précédente), correction refusée en simulation, révision, `Domenia.config.json` (défauts, bornes, doublon, BOM, JSON illisible jamais cité), défauts du formulaire et autorisation d’intervention, complexité du domaine, `pwdLastSet` comparé au contrôleur, purge des secrets et secret disparu avant l’envoi |
| `AccountsRefusalsTests` | périmètre d’un autre domaine ou inconnu, `krbtgt` jamais écrit, saisie du nom revérifiée pour un compte à privilèges et plan dépensé, préconditions changées (changement imposé, réinitialisation, expiration), contrôle de `userAccountControl`, mode annuaire sans lecteur ni exécuteur (`source.unavailable`), SID de domaine |
| `tests/web/comptes/rules.test.mjs` | règles de mot de passe de la page (avec et sans complexité, longueur 1 au moins), force, générateur, raisons des actions grisées, CSV de l’aperçu, dates JJ/MM/AAAA (31/02 refusé, ordre américain jamais lu), saisie jamais préremplie |
| `AccountsOperationsTests` | forme de `accounts.list`, OU de travail sans comptes et suggestions, périmètre jamais racine, compteurs de l’OU Utilisateurs (7 verrouillés, 2 échus), détail et bandeau de Camille Bernard, compte inconnu, verrouillages déterministes et fenêtre bornée, désactivation puis activation sur la surcouche, compte de session protégé, réinitialisation : stratégie, secret absent du plan, du reçu et du journal, jamais rejouée ; changement imposé et expiration, date obligatoire ; aperçu d’un lot sans écriture ; état des accès, accès fictif, contexte refusé, autre compte validé et oublié ; comptes secondaires, identifiant mémorisé, essai sur un poste ; références locales ; aucune opération `Write` dans l’écran |
| mis à jour | `PlatformTests` (modules et opérations du pont) |
| E2E | `tests/e2e/comptes/*.json` (non exécutés) : déverrouiller, mot de passe, mot de passe masqué au bout de 5 s, verrouillages, périmètre, lot, lot décoché et scellé de nouveau, accès (« Tout oublier » confirmé), saisie préservée et pastille, changer de compte, date d’expiration en français, droits lisibles en entier |

## 9. Reste à faire

- Mode annuaire (§ 7) : `Domenia.Ad` (vague 3), puis essais réels dans `OU=Domenia-Tests` (vague 4).
- Coffre Windows des comptes Postes et Secrets (CPT-017) : décision de David attendue (« Décider de l’activer en D2 ») et
  branchement natif (`CredRead`, `CredWrite`, `CredDelete`) ; indisponible en simulation comme dans Domenia 1.
- Shell (`app.js`, hors de cet écran) : pastille des accès à revoir dans la barre supérieure, visible de tous les écrans
  (CPT-001 : lire `accounts.access.revision` et écouter `domenia:access-changed` ; clic vers
  `#/comptes?vue=acces&acces=<oldestPendingId>`), rappel des trois identités dans le panneau d’aide avec le raccourci vers
  Comptes (CPT-012 : `accounts.access.state.identities`), relecture de la barre supérieure sur `domenia:session-changed`
  (CPT-007).
- Écran Assistance poste : publier l’autorisation d’intervention dans `InterventionConsentBoard` (CPT-020).
- Activation et désactivation des comptes **ordinateur** (FIC-013, écran Poste) ; aperçu collectif des autres opérations
  (TRV-229 : diagnostic réseau d’une liste, relevé du parc).

### Raccordement des lectures du 23/10/2026

`AdAccountsReader` sert les listes, détails, candidats d’un lot et verrouillages. Les listes gardent le DN et la profondeur, avec une sentinelle au-delà de 5 000 comptes. Une identité ou un UAC illisible rend la liste partielle ; `note` explique la cause et la page conserve cet avertissement à côté des compteurs. L’absence de résultat ne prouve pas que l’OU ne contient que des postes ou des groupes. Les dates AD absentes restent nulles.

Le détail et les candidats utilisent les mêmes lectures exactes que la Fiche, sans retour au cache pour une revalidation. Les objets lisibles sont commis avant publication. Les appartenances de groupes restent bornées par le transport LDAP.

Le journal 4740 passe par `wevtapi.dll` de Windows, sans dépendance ajoutée : PDC résolu par le rôle du domaine et contrôlé dans la liste des DC, sinon contrôleur lié annoncé ; SID exact, canal Sécurité, fournisseur Microsoft, fenêtre fermée de 1 à 720 heures, 200 événements et une sentinelle. Le budget global de résolution et lecture est de 30 secondes. Les poignées et la copie du mot de passe appartiennent au travailleur jusqu’à sa fin réelle ; l’annulation utilise `EvtCancel`, sans relance. Le compte explicite de connexion, lorsqu’il existe, est transmis en copie `SecureString` ; aucun repli vers le compte Windows.

Sources Windows : [schéma 4740](https://learn.microsoft.com/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4740), [session distante](https://learn.microsoft.com/en-us/windows/win32/api/winevt/nf-winevt-evtopensession), [annulation](https://learn.microsoft.com/en-us/windows/win32/api/winevt/nf-winevt-evtcancel). Le schéma 4740 version 0 place bien le poste à l’origine dans `TargetDomainName` ; un champ `CallerComputerName` explicite est prioritaire s’il existe.

Les comptes secondaires, la bascule de session, le coffre, les écritures LDAP et le lecteur Fiche complet restent à raccorder ; cette étape ne les déclare pas terminés. La recette native du journal sur la VM domaine reste à exécuter lors de la validation finale.
